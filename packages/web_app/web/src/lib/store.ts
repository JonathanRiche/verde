import { batch, createMemo, createRoot, createSignal, onCleanup } from 'solid-js'

import {
  acceleratorMatches,
  DEFAULT_WEB_KEYBINDS,
  findPrefixBinding,
  matchKeyAction,
  parseWebKeybindConfig,
  type KeyAction,
  type PrefixTarget,
  type WebKeybindConfig,
} from './keybinds'
import { dynamicModelOptions, type DynamicModelRow, type ModelOption } from './models'
import { writePane } from './pty'
import { createApprovalTracker } from './approvals'
import { createFollowupApi, followupKind, followupRpcError, FollowupRejectedError } from './followups'
import { watchNotifications } from './notify'
import { createChatCwdApi, chatCwdLocked, chatCwdTurnParams } from './chat_cwd'
import { createProviderReadinessApi, runtimeBlocker } from './provider_readiness'
import { latestPaneUsage } from './usage'
import { createTranscriptHistory, mergeTranscriptPage, type TranscriptContext, type TranscriptPage } from './transcript_history'
import { dispatchWebCommand, openChatCommandPicker, sidebarActionUnavailableReason, requestSidebarThreadSync, type ChatPickerCommand } from './commands'
import { archiveCommand, requestNewThread, requestWorkspaceCommand } from './command_requests'
import { createHistoryApi, groupHistory, reconcileHistoryArchives, registerHistoryClient } from './history'
import { createComposerCommands, parseSlashCommand, classifyBangCommand, repositoryCommandPath, type SlashCommandResult } from './composer_commands'
import { isPlaceholderThreadTitle, makeThreadTitle } from './thread_title'
import {
  LiveClient,
  deleteChatImage,
  fetchRpc,
  unwrapList,
  unwrapResult,
  uploadChatImage,
  type EventHandler,
} from './live'
import { connectionRpc, effectiveConnection, fetchConnections, type ConnectionCatalog } from './connections'
import {
  owningWorkspaceId,
  reconcileViewSelection,
  resolveWorkspaceId,
} from './selection'
import { linuxWorkspaceId } from './wyhash'
import { DEFAULT_UI_CONFIG, parseUiConfig, type UiConfig } from './ui_config'
import {
  adjacentPaneInGroups,
  paneIsActive,
  paneKey,
  paneTitle,
  isSubagentThreadId,
  parseLayoutNode,
  synthesizeSplit,
  workspacePaneGroups,
  type FollowupKind,
  type ApprovalDecision,
  type PendingApproval,
  type Attachment,
  type FavoriteModel,
  type LayoutNode,
  type LivePane,
  type Message,
  type RpcEnvelope,
  type Source,
  type Thread,
  type Workspace,
} from './types'

const SNAPSHOT_SCOPES = ['workspaces', 'registry', 'sessions', 'turns', 'config'] as const
/// Fallback pane cap for daemons without the `workspaces` snapshot scope.
const MAX_OPEN_THREADS = 16
/// Thread metadata rows are small; fetch enough that persisted layout pane
/// indexes (thread sort_index) always resolve.
const THREAD_LIST_LIMIT = 100
/// Backward pages stay inside the gateway RPC frame. A 1 MiB command card in
/// Workspace 8 overflowed a single `chat.thread.get` and left the phone empty.
const TRANSCRIPT_PAGE_LIMIT = 40
const TRANSCRIPT_PAGE_LIMIT_MIN = 1

interface SnapshotSession {
  session_id?: string
  id?: string
  workspace_id?: string
  workspace_path?: string
  cwd?: string
  label?: string
  command?: string
  pane_id?: number
  dock_id?: number
  running?: boolean
  status?: string
}

export interface SnapshotTurn {
  /// Client route for remote discoveries; daemon summaries are local.
  profile_id?: string
  turn_id?: string
  workspace_id?: string
  local_thread_id?: string
  provider_thread_id?: string | null
  status?: string
  pending_approval?: { call_id: string; title: string; body: string } | null
  next_seq?: number
  /// Daemon acceptance timestamp; absent on daemons predating the field.
  started_at_ms?: number
}

interface SnapshotPayload {
  snapshot?: {
    workspaces?: Workspace[]
    selected_workspace_index?: number
  }
  workspaces?: Workspace[]
  selected_workspace_index?: number
  sessions?: SnapshotSession[]
  turns?: SnapshotTurn[]
  config?: unknown
}

type TranscriptMap = Record<string, Message[]>
type DraftMap = Record<string, string>
type DraftAttachmentMap = Record<string, Attachment[]>
type AttachmentUploadMap = Record<string, number>

export type SidebarContextAction =
  | 'workspace-new-chat'
  | 'workspace-open-codex-tui'
  | 'workspace-open-terminal'
  | 'workspace-herdr-handoff'
  | 'workspace-herdr-focus-terminal'
  | 'workspace-herdr-unlink'
  | 'workspace-rename'
  | 'workspace-import-codex'
  | 'workspace-import-opencode'
  | 'workspace-import-claude'
  | 'workspace-close'
  | 'thread-rename'
  | 'thread-regenerate-title'
  | 'thread-sync'
  | 'thread-handoff'
  | 'thread-open-tui'
  | 'thread-open-chat'
  | 'thread-archive'
  | 'pane-zoom'
  | 'pane-split-chat-right'
  | 'pane-split-chat-down'
  | 'pane-split-terminal-right'
  | 'pane-split-terminal-down'
  | 'pane-close'

export interface SidebarContextActionRequest {
  action: SidebarContextAction
  workspace: Workspace
  pane?: LivePane
  value?: string
}

const MAX_CHAT_IMAGE_BYTES = 10 * 1024 * 1024

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' ? (value as Record<string, unknown>) : null
}

export function favoriteModelKey(provider: string, model: string): string {
  return `${provider}\u0000${model}`
}

export function setFavoriteModelInList(
  favorites: FavoriteModel[],
  provider: string,
  model: string,
  favorite: boolean,
): FavoriteModel[] {
  const key = favoriteModelKey(provider, model)
  const exists = favorites.some((entry) => favoriteModelKey(entry.provider, entry.model) === key)
  if (exists === favorite) return favorites
  if (!favorite) return favorites.filter((entry) => favoriteModelKey(entry.provider, entry.model) !== key)
  return [...favorites, { provider, model }]
}

export function parseFavoriteModels(config: unknown): FavoriteModel[] {
  const chat = asRecord(asRecord(config)?.chat)
  const rows = Array.isArray(chat?.favorite_models) ? chat.favorite_models : []
  const favorites: FavoriteModel[] = []
  const seen = new Set<string>()
  for (const value of rows) {
    const row = asRecord(value)
    const provider = typeof row?.provider === 'string' ? row.provider.trim() : ''
    const model = typeof row?.model === 'string' ? row.model.trim() : ''
    if (!provider || !model) continue
    const key = favoriteModelKey(provider, model)
    if (seen.has(key)) continue
    seen.add(key)
    favorites.push({ provider, model })
  }
  return favorites
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

function mintId(prefix: string): string {
  const bytes = new Uint8Array(4)
  crypto.getRandomValues(bytes)
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('')
  return `${prefix}${Date.now()}-${hex}`
}

function isOpeningThread(thread: Thread | null, title: string): boolean {
  if ((thread?.messages?.length ?? 0) > 0) return false
  if (thread?.provider_thread_id) return false
  if (thread?.committed === true) return false
  return thread?.committed === false || isPlaceholderThreadTitle(title)
}

function methodUnavailable(response: { error?: { code: string } }): boolean {
  const code = response.error?.code
  return code === 'unknown_method' || code === 'method_not_found' || code === 'capability_unavailable'
}

/// GUI threads from `chat.open` are absent from the daemon store until the
/// first turn commits. A not-found get is that opening case, not a failed send.
export function isAbsentDaemonThread(response: { error?: { code?: string }; ok?: boolean }): boolean {
  if (!(response.error || response.ok === false)) return false
  const code = response.error?.code
  return code === 'resource_not_found' || code === 'not_found'
}

export function threadFromDaemonGet(response: RpcEnvelope): Thread | null {
  if (response.error || response.ok === false) return null
  const thread_root = unwrapResult<{ thread?: Thread } & Thread>(response)
  const thread = thread_root?.thread ?? (thread_root as Thread | null)
  return thread?.local_thread_id ? thread : null
}

/// `chat.thread.upsert` overwrites metadata. Never copy transcript bodies into
/// that write: a 1 MiB command card makes `chat.thread.get` exceed the
/// transport limit, which is what blocked send on this Workspace 8 thread.
export function mergeThreadMetadata(existing: Thread, patch: Partial<Thread> = {}): Thread {
  const base = { ...existing }
  delete base.messages
  const rest = { ...patch }
  delete rest.messages
  return {
    ...base,
    committed: existing.committed ?? false,
    ...rest,
  }
}

function openingThreadFromPane(pane: LivePane): Thread {
  return {
    local_thread_id: pane.thread_id ?? '',
    title: pane.thread_title ?? 'New Chat',
    committed: pane.committed ?? false,
    last_activity_at: Date.now(),
    provider: pane.provider ?? 'codex',
    harness: 'local_cli',
    model_ref: pane.model ?? null,
    reasoning_effort: pane.reasoning_effort ?? null,
    reasoning_variant: pane.reasoning_variant ?? null,
    fast_mode: pane.fast_mode ? 'on' : 'off',
    access_mode: pane.access_mode ?? 'supervised',
    archived: false,
    draft: '',
    provider_thread_id: pane.provider_thread_id ?? null,
    profile_id: pane.profile_id,
    runtime_id: pane.runtime_id,
    repository_id: pane.repository_id,
    repository_cwd: pane.repository_cwd,
  }
}

/// User-initiated RPCs ride HTTP instead of the shared websocket. The gateway
/// answers websocket RPCs serially in its read loop, so a click issued while
/// the routine projection sweep is in flight would queue behind a dozen
/// polling calls and feel seconds slow. Each HTTP request gets its own
/// gateway connection task with the same daemon→Live→mock routing, so
/// interactive latency is one round-trip regardless of polling load.
async function interactiveCall(method: string, params: unknown = {}): Promise<RpcEnvelope> {
  try {
    return await fetchRpc(method, params)
  } catch (err) {
    return {
      ok: false,
      error: {
        code: 'network',
        message: err instanceof Error ? err.message : 'request failed',
      },
    }
  }
}

export async function requestTerminalOpen(
  call: (method: string, params: unknown) => Promise<RpcEnvelope>,
  workspace: Pick<Workspace, 'workspace_id' | 'path'>,
  session_id: string,
): Promise<{ response: RpcEnvelope; native: boolean }> {
  const opened = await call('terminal.open', { workspace_id: workspace.workspace_id })
  if (!(opened.error || opened.ok === false) || !methodUnavailable(opened)) {
    return { response: opened, native: true }
  }
  return {
    response: await call('session.create', {
      id: session_id,
      cwd: workspace.path,
      workspace_path: workspace.path,
      workspace_id: workspace.workspace_id,
      label: 'Terminal',
    }),
    native: false,
  }
}

export async function requestPaneClose(
  call: (method: string, params: unknown) => Promise<RpcEnvelope>,
  _workspace_id: string,
  pane: Pick<LivePane, 'kind' | 'native_pane_id' | 'session_id'>,
): Promise<RpcEnvelope> {
  if (pane.kind === 'terminal' && pane.session_id) {
    return call('session.kill', { id: pane.session_id })
  }
  return {
    ok: false,
    error: {
      code: 'capability_unavailable',
      message: 'Available in the desktop app',
    },
  }
}

function stablePaneId(kind: 'chat' | 'term' | 'browser', key: string): number {
  let hash = 2166136261
  const input = `${kind}:${key}`
  for (let index = 0; index < input.length; index++) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0) % 0x7fffffff || 1
}

function sameMessage(a: Message, b: Message): boolean {
  return (
    a.message_id === b.message_id &&
    a.role === b.role &&
    a.author === b.author &&
    a.body === b.body &&
    JSON.stringify(a.images ?? []) === JSON.stringify(b.images ?? [])
  )
}

function mergeMessages(previous: Message[] | undefined, next: Message[]): Message[] {
  if (!previous) return next
  if (previous.length === next.length && previous.every((row, index) => sameMessage(row, next[index]!))) {
    return previous
  }
  const byId = new Map(previous.map(row => [row.message_id, row]))
  return next.map((row) => {
    const old = byId.get(row.message_id)
    return old && sameMessage(old, row) ? old : row
  })
}

function threadListFrom(raw: unknown): Thread[] {
  const result = unwrapResult<Record<string, unknown>>(raw) ?? asRecord(raw)
  const listed = unwrapList<Thread>(result, 'threads')
  if (listed.length > 0) return listed
  if (Array.isArray(result)) return result as Thread[]
  return []
}

const THREAD_SETTING_KEYS = [
  'reasoning_effort',
  'reasoning_variant',
  'fast_mode',
  'access_mode',
] as const satisfies ReadonlyArray<keyof Thread>
const THREAD_SETTINGS_CACHE_KEY = 'verde:web:thread-settings:v1'
const LAST_CHAT_PANE_CACHE_KEY = 'verde:web:last-chat-pane:v1'
const COMPOSER_CACHE_KEY = 'verde:web:composer:v1'

type CachedThreadSettings = Pick<Thread, (typeof THREAD_SETTING_KEYS)[number]>
type ThreadSettingsCache = Record<string, Record<string, CachedThreadSettings>>
interface ComposerCache {
  drafts: DraftMap
  attachments: DraftAttachmentMap
}

export interface LastChatPaneLocation {
  workspace_id: string
  pane_id: number
  thread_id?: string
  thread_index?: number
  thread_title?: string
}

function readLastChatPaneLocation(): LastChatPaneLocation | null {
  try {
    const parsed = asRecord(JSON.parse(localStorage.getItem(LAST_CHAT_PANE_CACHE_KEY) ?? 'null'))
    if (
      !parsed ||
      typeof parsed.workspace_id !== 'string' ||
      typeof parsed.pane_id !== 'number' ||
      !Number.isFinite(parsed.pane_id)
    ) return null
    return {
      workspace_id: parsed.workspace_id,
      pane_id: parsed.pane_id,
      ...(typeof parsed.thread_id === 'string' ? { thread_id: parsed.thread_id } : {}),
      ...(typeof parsed.thread_index === 'number' ? { thread_index: parsed.thread_index } : {}),
      ...(typeof parsed.thread_title === 'string' ? { thread_title: parsed.thread_title } : {}),
    }
  } catch {
    return null
  }
}

function writeLastChatPaneLocation(pane: LivePane): void {
  if (pane.kind !== 'chat') return
  const location: LastChatPaneLocation = {
    workspace_id: pane.workspace_id,
    pane_id: pane.pane_id,
    ...(pane.thread_id ? { thread_id: pane.thread_id } : {}),
    ...(pane.thread_index !== undefined ? { thread_index: pane.thread_index } : {}),
    ...(pane.thread_title ? { thread_title: pane.thread_title } : {}),
  }
  try {
    localStorage.setItem(LAST_CHAT_PANE_CACHE_KEY, JSON.stringify(location))
  } catch {
    // Storage can be unavailable in hardened/private browser contexts.
  }
}

function readComposerCache(): ComposerCache {
  const empty: ComposerCache = { drafts: {}, attachments: {} }
  try {
    const parsed = asRecord(JSON.parse(localStorage.getItem(COMPOSER_CACHE_KEY) ?? 'null'))
    if (!parsed) return empty
    const drafts: DraftMap = {}
    const raw_drafts = asRecord(parsed.drafts)
    for (const [key, value] of Object.entries(raw_drafts ?? {})) {
      if (typeof value === 'string' && value.length > 0) drafts[key] = value
    }
    const attachments: DraftAttachmentMap = {}
    const raw_attachments = asRecord(parsed.attachments)
    for (const [key, value] of Object.entries(raw_attachments ?? {})) {
      if (!Array.isArray(value)) continue
      const rows = value.filter(
        (item): item is Attachment =>
          Boolean(item) &&
          typeof item === 'object' &&
          typeof (item as Attachment).path === 'string' &&
          typeof (item as Attachment).mime === 'string',
      )
      if (rows.length > 0) attachments[key] = rows
    }
    return { drafts, attachments }
  } catch {
    return empty
  }
}

function writeComposerCache(drafts: DraftMap, attachments: DraftAttachmentMap): void {
  try {
    const non_empty_drafts = Object.fromEntries(
      Object.entries(drafts).filter(([, value]) => value.length > 0),
    )
    const non_empty_attachments = Object.fromEntries(
      Object.entries(attachments).filter(([, value]) => value.length > 0),
    )
    localStorage.setItem(COMPOSER_CACHE_KEY, JSON.stringify({
      drafts: non_empty_drafts,
      attachments: non_empty_attachments,
    }))
  } catch {
    // Storage can be unavailable or full in hardened/private contexts.
  }
}

/// Resolves a persisted chat semantically because live-layout placeholders
/// can receive a stable thread-derived pane id after the catalog loads.
export function findLastChatPane(
  panes: readonly LivePane[],
  location: LastChatPaneLocation,
): LivePane | null {
  const chats = panes.filter(
    (pane) => pane.kind === 'chat' && pane.workspace_id === location.workspace_id,
  )
  if (location.thread_id) {
    const thread = chats.find((pane) => pane.thread_id === location.thread_id)
    if (thread) return thread
    const exact = chats.find((pane) => pane.pane_id === location.pane_id)
    if (exact) return exact
    if (location.thread_index !== undefined && location.thread_title) {
      return chats.find(
        (pane) =>
          pane.thread_index === location.thread_index && pane.thread_title === location.thread_title,
      ) ?? null
    }
    return null
  }
  const exact = chats.find((pane) => pane.pane_id === location.pane_id)
  if (exact) return exact
  if (location.thread_index !== undefined && location.thread_title) {
    const indexed = chats.find(
      (pane) =>
        pane.thread_index === location.thread_index && pane.thread_title === location.thread_title,
    )
    if (indexed) return indexed
  }
  if (location.thread_title) {
    const titled = chats.filter((pane) => pane.thread_title === location.thread_title)
    return titled.length === 1 ? titled[0]! : null
  }
  return null
}

function readThreadSettingsCache(): ThreadSettingsCache {
  try {
    const raw = localStorage.getItem(THREAD_SETTINGS_CACHE_KEY)
    return raw ? (JSON.parse(raw) as ThreadSettingsCache) : {}
  } catch {
    return {}
  }
}

function cachedThreadSettings(workspaceId: string, threadId: string): CachedThreadSettings | undefined {
  return readThreadSettingsCache()[workspaceId]?.[threadId]
}

function rememberThreadSettings(workspaceId: string, threadId: string, settings: CachedThreadSettings) {
  try {
    const cache = readThreadSettingsCache()
    cache[workspaceId] = { ...(cache[workspaceId] ?? {}), [threadId]: settings }
    localStorage.setItem(THREAD_SETTINGS_CACHE_KEY, JSON.stringify(cache))
  } catch {
    // Storage can be unavailable in hardened/private browser contexts.
  }
}

/// Older daemons persisted run controls but omitted them from chat.thread.list.
/// Keep the values from the preceding core.snapshot (or an optimistic click)
/// when enriching that snapshot with the bounded thread catalog.
export function mergeThreadCatalogSettings(
  workspaceId: string,
  listed: Thread[],
  snapshot: Thread[] | undefined,
  previous: Thread[] | undefined,
  retainedIds?: ReadonlySet<string>,
): Thread[] {
  const merged = listed.map((thread) => {
    const source =
      snapshot?.find((row) => row.local_thread_id === thread.local_thread_id) ??
      previous?.find((row) => row.local_thread_id === thread.local_thread_id)
    const cached = cachedThreadSettings(workspaceId, thread.local_thread_id)
    if (!source && !cached) return thread
    const merged = { ...thread }
    for (const key of THREAD_SETTING_KEYS) {
      if (Object.prototype.hasOwnProperty.call(thread, key)) continue
      if (source && Object.prototype.hasOwnProperty.call(source, key)) merged[key] = source[key] as never
      else if (cached && Object.prototype.hasOwnProperty.call(cached, key)) merged[key] = cached[key] as never
    }
    return merged
  })
  // Fresh GUI threads are intentionally absent from chat.thread.list until
  // their first turn commits. Keep the stable row returned by chat.open so
  // the web composer retains its local_thread_id during that opening turn.
  const retained = previous?.filter(
    (thread) =>
      retainedIds?.has(thread.local_thread_id) &&
      !merged.some((listed_thread) => listed_thread.local_thread_id === thread.local_thread_id),
  ) ?? []
  return retained.length > 0 ? [...retained, ...merged] : merged
}

/// Formats the new-file line ranges touched by a unified-diff patch, e.g.
/// "lines 12-18, 40", so a diff comment names the exact edit (desktop
/// diffCommentLineSummary parity). Lists at most four hunks and rolls the
/// rest up as "+N more". Returns null when no `@@` hunk headers parse.
export function diffCommentLineSummary(patch: string): string | null {
  // Beyond this many ranges the prefix stops reading as a pointer and starts
  // crowding out the user's actual comment.
  const MAX_LISTED_HUNKS = 4
  const pieces: string[] = []
  let hunk_count = 0
  for (const line of patch.split('\n')) {
    if (!line.startsWith('@@')) continue
    // The first '+' in a valid header starts the new-side "+start,count".
    const match = /\+(\d+)(?:,(\d+))?/.exec(line)
    if (!match) continue
    const start = Number(match[1])
    const count = match[2] === undefined ? 1 : Number(match[2])
    hunk_count += 1
    if (hunk_count > MAX_LISTED_HUNKS) continue
    pieces.push(count <= 1 ? `${start}` : `${start}-${start + count - 1}`)
  }
  if (hunk_count === 0) return null
  const more = hunk_count > MAX_LISTED_HUNKS ? `, +${hunk_count - MAX_LISTED_HUNKS} more` : ''
  return `lines ${pieces.join(', ')}${more}`
}

function rpcFailed(response: RpcEnvelope): boolean {
  return Boolean(response.error) || response.ok === false
}

/// Oldest-to-newest merge of one `chat.message.list` backward page onto the
/// messages already collected from newer pages.
export function prependTranscriptPage(page: Message[], existing: Message[]): Message[] {
  if (page.length === 0) return existing
  if (existing.length === 0) return page
  const seen = new Set(existing.map((row) => row.message_id))
  return [...page.filter((row) => !seen.has(row.message_id)), ...existing]
}

function messageListCursor(response: RpcEnvelope): string | undefined {
  const result = unwrapResult<{ next_cursor?: string | null }>(response)
  const cursor = result?.next_cursor
  return typeof cursor === 'string' && cursor.length > 0 ? cursor : undefined
}

/// Fetch only the newest page (or one requested older page), reducing the
/// size when a large command card exceeds the gateway response limit.
export async function fetchTranscriptPage(
  call: (method: string, params: unknown) => Promise<RpcEnvelope>,
  args: { workspace_id: string; local_thread_id: string },
  cursor?: string,
): Promise<TranscriptPage> {
  let limit = TRANSCRIPT_PAGE_LIMIT
  for (;;) {
    const response = await call('chat.message.list', {
      ...args, direction: 'backward', limit, ...(cursor ? { cursor } : {}),
    })
    if (!rpcFailed(response)) {
      const messages = mapTranscriptRows(response, args.local_thread_id)
      return { messages, cursor: messages.length ? messageListCursor(response) ?? null : null }
    }
    if (methodUnavailable(response) && !cursor) {
      // Compatibility only: older daemons have no paginated endpoint.
      const legacy = await call('chat.thread.get', args)
      if (rpcFailed(legacy)) throw new Error(legacy.error?.message ?? 'Could not load messages.')
      return { messages: mapTranscriptRows(legacy, args.local_thread_id), cursor: null }
    }
    if (limit <= TRANSCRIPT_PAGE_LIMIT_MIN || methodUnavailable(response)) {
      throw new Error(response.error?.message ?? 'Could not load messages.')
    }
    limit = Math.max(TRANSCRIPT_PAGE_LIMIT_MIN, Math.floor(limit / 2))
  }
}

export function mapTranscriptRows(raw: unknown, fallbackId: string): Message[] {
  const root = unwrapResult<Record<string, unknown>>(raw) ?? asRecord(raw)
  const thread = (root?.thread && typeof root.thread === 'object' ? root.thread : root) as
    | { messages?: Message[] }
    | null
  const rows = thread?.messages ?? unwrapList<Record<string, unknown>>(root, 'messages')
  return rows.map((row, index) => {
    const record = row as Record<string, unknown>
    const body = record.body ?? record.content ?? record.text ?? record.prompt ?? ''
    const images = transcriptAttachments(record)
    return {
      message_id: typeof record.message_id === 'string' && record.message_id.length > 0 ? record.message_id : `${fallbackId}-${record.sort_index ?? index}`,
      role: String(record.role ?? 'assistant'),
      author: String(record.author ?? ''),
      body: typeof body === 'string' ? body : JSON.stringify(body),
      ...(images.length > 0 ? { images } : {}),
      tool_call_id: typeof record.tool_call_id === 'string' ? record.tool_call_id : null,
      tool_call_kind: typeof record.tool_call_kind === 'string' ? record.tool_call_kind : null,
      tool_call_status: typeof record.tool_call_status === 'string' ? record.tool_call_status : null,
      created_at_ms: typeof record.created_at_ms === 'number' ? record.created_at_ms : null,
    }
  })
}

function transcriptAttachments(record: Record<string, unknown>): Attachment[] {
  const out: Attachment[] = []
  const append = (raw: unknown) => {
    const value = asRecord(raw)
    if (!value || typeof value.path !== 'string' || !value.path) return
    const attachment: Attachment = {
      path: value.path,
      mime: typeof value.mime === 'string' ? value.mime : '',
      byte_size: typeof value.byte_size === 'number' ? value.byte_size : undefined,
      attachment_id: typeof value.attachment_id === 'string' ? value.attachment_id : null,
    }
    if (!out.some((existing) => existing.path === attachment.path)) out.push(attachment)
  }
  append(record.image)
  if (Array.isArray(record.images)) for (const image of record.images) append(image)
  return out
}

function imageMimeForFile(file: File): string | null {
  const declared = file.type.toLowerCase()
  if (['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/bmp'].includes(declared)) {
    return declared
  }
  const extension = file.name.split('.').at(-1)?.toLowerCase()
  if (extension === 'png') return 'image/png'
  if (extension === 'jpg' || extension === 'jpeg') return 'image/jpeg'
  if (extension === 'webp') return 'image/webp'
  if (extension === 'gif') return 'image/gif'
  if (extension === 'bmp') return 'image/bmp'
  return null
}

/// Return supported image files from a clipboard paste. Prefer DataTransfer
/// items because browsers can omit pasted screenshots from `files`, then use
/// the file list as a compatibility fallback.
export function clipboardImageFiles(data: Pick<DataTransfer, 'items' | 'files'> | null): File[] {
  if (!data) return []
  const from_items = Array.from(data.items)
    .filter((item) => item.kind === 'file')
    .map((item) => item.getAsFile())
    .filter((file): file is File => file !== null && imageMimeForFile(file) !== null)
  if (from_items.length > 0) return from_items
  return Array.from(data.files).filter((file) => imageMimeForFile(file) !== null)
}

function turnIsActive(status: string | undefined): boolean {
  return status === 'working' || status === 'waiting' || status === 'accepted' || status === 'running' || status === 'waiting_approval'
}

/// Summaries and tail responses carry the current approval independently of
/// paginated events (approval_requested itself contains only the call id).
export function approvalFromTurn(turn: SnapshotTurn): PendingApproval | null {
  const approval = turn.pending_approval
  if (!turn.turn_id || !turnIsActive(turn.status) || !approval ||
      typeof approval.call_id !== 'string' || !approval.call_id ||
      typeof approval.title !== 'string' || typeof approval.body !== 'string') return null
  return { turn_id: turn.turn_id, call_id: approval.call_id, title: approval.title, body: approval.body }
}

export function pendingApprovalForPane(
  pane: LivePane,
  turns: SnapshotTurn[],
  tails: Record<string, PendingApproval | null>,
): PendingApproval | null {
  if (pane.kind !== 'chat' || !pane.thread_id) return null
  const turn = turns.filter((item) => item.workspace_id === pane.workspace_id &&
    item.local_thread_id === pane.thread_id).at(-1)
  if (!turn?.turn_id || !turnIsActive(turn.status)) return null
  return Object.hasOwn(tails, turn.turn_id) ? tails[turn.turn_id] : approvalFromTurn(turn)
}

export function mergeLocalTurnSnapshot(previous: SnapshotTurn[], local: SnapshotTurn[]): SnapshotTurn[] {
  const remote = previous.filter((turn) => turn.profile_id && turn.profile_id !== 'local')
  return [...local.filter((turn) => !remote.some((item) =>
    item.workspace_id === turn.workspace_id && item.local_thread_id === turn.local_thread_id)), ...remote]
}

/// A turn discovered on this daemon needs no owner-only connection catalog.
export function isLocalTurnRequest(pane: LivePane, turns: SnapshotTurn[], params: unknown): boolean {
  const turn_id = asRecord(params)?.turn_id
  return typeof turn_id === 'string' && turns.some((turn) =>
    turn.turn_id === turn_id && turn.workspace_id === pane.workspace_id &&
    turn.local_thread_id === pane.thread_id && (!turn.profile_id || turn.profile_id === 'local'))
}

export async function requestApprovalResolution(
  approval: PendingApproval,
  decision: ApprovalDecision,
  call: (method: string, params: unknown) => Promise<RpcEnvelope>,
): Promise<void> {
  const response = await call('chat.turn.approve', {
    turn_id: approval.turn_id, call_id: approval.call_id, decision,
  })
  if (response.error || response.ok === false) {
    throw new Error(response.error?.message ?? 'Could not resolve the approval')
  }
}

/// Completion-pending is an unread/acknowledgement state, not live work. The
/// composer only shows Stop while a turn is actually in flight or its local
/// streaming overlay is still present.
export function chatPaneHasLiveTurn(
  pane: LivePane | null | undefined,
  has_streaming_overlay: boolean,
): boolean {
  return Boolean(pane?.kind === 'chat' && (has_streaming_overlay || pane.send_pending))
}

/// Returns the last event sequence that a tail response actually delivered.
/// `next_seq` is the daemon's next unused sequence and must never be used as
/// an `after_seq` cursor because doing so skips the event assigned that value.
export function lastDeliveredTailSeq(
  current: number,
  events: ReadonlyArray<{ seq?: number }>,
  page_last_seq?: number,
): number {
  let last = current
  for (const event of events) {
    if (typeof event.seq === 'number' && Number.isSafeInteger(event.seq) && event.seq > last) {
      last = event.seq
    }
  }
  if (
    typeof page_last_seq === 'number' &&
    Number.isSafeInteger(page_last_seq) &&
    page_last_seq > last
  ) {
    last = page_last_seq
  }
  return last
}

function sessionKey(session: SnapshotSession): string {
  return session.session_id ?? session.id ?? ''
}

function storeIdForPath(path: string | undefined): string | null {
  if (!path) return null
  if (!path.startsWith('/')) return path
  return linuxWorkspaceId(path)
}

function sessionStoreId(session: SnapshotSession): string | null {
  const path = session.workspace_path ?? session.cwd ?? session.workspace_id
  if (path && path.startsWith('/')) return linuxWorkspaceId(path)
  if (session.workspace_id && !session.workspace_id.startsWith('/')) return session.workspace_id
  return storeIdForPath(path)
}

function sessionMatchesWorkspace(session: SnapshotSession, workspace: Workspace): boolean {
  const store_id = sessionStoreId(session)
  if (store_id && store_id === workspace.workspace_id) return true
  const path = session.workspace_path ?? session.cwd
  return Boolean(path && path === workspace.path)
}

function sessionIsLive(session: SnapshotSession): boolean {
  return session.running === true || session.status === 'working'
}

function sessionTitle(session: SnapshotSession): string {
  const label = session.label?.trim()
  const command = session.command?.trim() ?? ''
  const binary = command.split(/\s+/)[0]?.split('/').filter(Boolean).at(-1)
  if (label && label !== 'Shell' && label !== 'Terminal') return label
  if (binary && binary !== 'fish' && binary !== 'bash' && binary !== 'zsh' && binary !== 'sh') return binary
  if (label) return label
  return binary || 'Terminal'
}

function labelFromPath(path: string): string {
  return path.split('/').filter(Boolean).at(-1) || path
}

/// One pane entry of the desktop-persisted workspace layout
/// (workspace_layout.zig persistedWorkspaceJson, v2).
interface PersistedPaneRow {
  id?: number
  scroll_group?: number
  kind?: string
  minimized?: boolean
  thread?: number
  dock?: number
  purpose?: string
  tabs?: unknown[]
  active_tab?: number
  /// Live pane rows report a count rather than the tab array.
  tab_count?: number
  /// Live pane rows carry the resolved title; persisted layout does not.
  title?: string
  /// Live chat rows carry the provider so the sidebar can show its logo.
  provider?: string
  /// Durable thread identity from the desktop `panes` listing / `chat.status`.
  /// Title and sort_index drift; this is what the transcript fetch keys on.
  local_thread_id?: string
  /// Live chat enrichment from `chat.status`: the provider-side thread id is
  /// a rename-proof key into the store thread catalog when local_thread_id is
  /// absent (older desktops).
  provider_thread_id?: string
  model?: string
  reasoning_effort?: string | null
  reasoning_variant?: string | null
  fast_mode?: boolean
  /// Live activity flags from the desktop; absent in persisted layouts. They
  /// override the store-derived guesses so the ACTIVE cluster matches the
  /// desktop exactly.
  send_pending?: boolean
  completion_pending?: boolean
  pending_approval?: boolean
  attention?: boolean
  working?: boolean
}

interface PersistedWorkspaceLayout {
  v?: number
  focused?: number | null
  maximized?: number | null
  panes?: PersistedPaneRow[]
  root?: LayoutNode | null
}

export function parseWorkspaceLayout(json: string | null | undefined): PersistedWorkspaceLayout | null {
  if (!json) return null
  try {
    const parsed: unknown = JSON.parse(json)
    const record = asRecord(parsed)
    if (!record || !Array.isArray(record.panes)) return null
    return {
      ...(record as PersistedWorkspaceLayout),
      root: parseLayoutNode(record.root),
    }
  } catch {
    return null
  }
}

/// Desktop live `panes` response mapped onto the persisted-layout shape so
/// one projection path serves both sources. Live data is authoritative while
/// the desktop app runs; the store layout only covers detached operation.
export function layoutFromLivePanes(response: unknown): PersistedWorkspaceLayout | null {
  const result = unwrapResult<{
    focused_pane_id?: number | null
    root?: unknown
    panes?: Array<{
      pane_id?: number
      scroll_group?: number
      kind?: string
      thread_index?: number
      thread_title?: string
      local_thread_id?: string
      provider_thread_id?: string | null
      provider?: string
      model?: string | null
      dock_id?: number
      tab_count?: number
      title?: string
      agent_provider?: string | null
      send_pending?: boolean
      completion_pending?: boolean
      pending_approval?: boolean
      attention?: boolean
      working?: boolean
    }>
  }>(response)
  if (!result || !Array.isArray(result.panes)) return null
  const panes: PersistedPaneRow[] = []
  for (const row of result.panes) {
    if (row.kind === 'chat' && typeof row.thread_index === 'number') {
      panes.push({
        id: row.pane_id,
        kind: 'chat',
        thread: row.thread_index,
        title: row.thread_title,
        local_thread_id: typeof row.local_thread_id === 'string' ? row.local_thread_id : undefined,
        provider_thread_id: typeof row.provider_thread_id === 'string' ? row.provider_thread_id : undefined,
        provider: row.provider,
        model: typeof row.model === 'string' ? row.model : undefined,
        send_pending: row.send_pending ?? false,
        completion_pending: row.completion_pending ?? false,
        pending_approval: row.pending_approval ?? false,
        attention: row.attention ?? false,
      })
    } else if (row.kind === 'terminal') {
      panes.push({
        id: row.pane_id,
        kind: 'terminal',
        dock: row.dock_id,
        title: row.title,
        provider: row.agent_provider ?? undefined,
        working: row.working ?? false,
        attention: row.attention ?? false,
      })
    } else if (row.kind === 'browser') {
      panes.push({ id: row.pane_id, kind: 'browser', tab_count: row.tab_count })
    }
  }
  for (const pane of panes) {
    const live_row = result.panes.find((row) => row.pane_id === pane.id)
    pane.scroll_group = live_row?.scroll_group
  }
  return {
    v: 2,
    focused: result.focused_pane_id ?? null,
    panes,
    root: parseLayoutNode(result.root),
  }
}

/// Keep durable chat identity when a live `panes` tick omits thread ids
/// (`enrich_chat_status: false`, older desktops). Otherwise the next
/// projection turns a real chat into a title-only placeholder and the web
/// transcript goes blank while the desktop still has the thread.
export function carryLiveChatIdentity(
  previous: PersistedPaneRow[] | undefined,
  next: PersistedPaneRow[],
): PersistedPaneRow[] {
  if (!previous?.length) return next
  return next.map((pane) => {
    if (pane.kind !== 'chat' || pane.id == null) return pane
    const prior = previous.find((row) => row.kind === 'chat' && row.id === pane.id)
    if (!prior) return pane
    return {
      ...pane,
      local_thread_id: pane.local_thread_id || prior.local_thread_id,
      provider_thread_id: pane.provider_thread_id || prior.provider_thread_id,
    }
  })
}

/// Desktop live `workspaces` listing: the set of workspaces actually open in
/// the desktop app, with human labels. Store workspace rows can be stale
/// (they only update when the desktop flushes state), so when the desktop is
/// reachable this listing decides what the sidebar shows.
export function workspacesFromLiveListing(response: unknown): Workspace[] | null {
  const result = unwrapResult<{
    workspaces?: Array<{ id?: string; label?: string; path?: string; archived?: boolean }>
  }>(response)
  if (!result || !Array.isArray(result.workspaces)) return null
  const rows: Workspace[] = []
  for (const row of result.workspaces) {
    if (!row.id || row.archived) continue
    rows.push({
      workspace_id: row.id,
      label: row.label || (row.path ? labelFromPath(row.path) : row.id),
      path: row.path ?? '',
      threads: [],
    })
  }
  return rows
}

function chatPane(workspace: Workspace, thread: Thread, turns: SnapshotTurn[]): LivePane {
  const active = turns.some(
    (turn) =>
      turn.workspace_id === workspace.workspace_id &&
      turn.local_thread_id === thread.local_thread_id &&
      turnIsActive(turn.status),
  )
  return {
    pane_id: stablePaneId('chat', thread.local_thread_id),
    workspace_id: workspace.workspace_id,
    kind: 'chat',
    thread_id: thread.local_thread_id,
    provider_thread_id: thread.provider_thread_id,
    profile_id: thread.profile_id,
    runtime_id: thread.runtime_id,
    repository_id: thread.repository_id,
    repository_cwd: thread.repository_cwd,
    committed: thread.committed,
    thread_title: thread.title || 'Chat',
    provider: thread.provider ?? workspace.provider,
    model: thread.model_ref ?? null,
    reasoning_effort: thread.reasoning_effort ?? null,
    reasoning_variant: thread.reasoning_variant ?? null,
    fast_mode: thread.fast_mode === 'on',
    access_mode: thread.access_mode ?? 'supervised',
    send_pending: active,
    completion_pending: active,
  }
}

function termPane(workspace: Workspace, session: SnapshotSession): LivePane {
  return {
    pane_id: stablePaneId('term', sessionKey(session)),
    workspace_id: workspace.workspace_id,
    kind: 'terminal',
    session_id: sessionKey(session),
    thread_title: sessionTitle(session),
    dock_id: session.dock_id,
    running: session.running ?? session.status === 'working',
    // Detached fallback: without the desktop's surface status, a session the
    // daemon reports as working is the closest activity signal available.
    working: session.status === 'working',
    cwd: session.cwd ?? workspace.path,
    attention: session.status === 'working',
  }
}

/// Panes actually open in a workspace. The desktop-persisted layout in the
/// daemon store is the source of truth; the old N-most-recent-threads
/// heuristic remains only as a fallback for daemons that cannot serve the
/// `workspaces` snapshot scope.
export function panesForWorkspace(
  workspace: Workspace,
  sessions: SnapshotSession[],
  turns: SnapshotTurn[],
  localThreadIds: ReadonlySet<string>,
  live_layout?: PersistedWorkspaceLayout | null,
): LivePane[] {
  const threads = workspace.threads ?? []
  const workspace_sessions = sessions.filter(
    (session) => sessionKey(session) && sessionMatchesWorkspace(session, workspace),
  )
  const has_live_layout = live_layout != null
  const layout = live_layout ?? parseWorkspaceLayout(workspace.workspace_layout_json)
  const rows: LivePane[] = []
  const used_threads = new Set<string>()
  const used_sessions = new Set<string>()
  if (layout) {
    for (const pane of layout.panes ?? []) {
      const focused = layout.focused != null && layout.focused === pane.id
      if (pane.kind === 'chat' && typeof pane.thread === 'number') {
        // Layout references chat panes by position in the desktop thread
        // array, which the store mirrors as thread sort_index — but store
        // rows lag the desktop, so index and title both drift. Binding order:
        // provider thread id (rename-proof), exact title + sort index, then
        // title/index fallbacks only for persisted layouts. A live pane whose
        // thread is absent from the bounded catalog must stay a placeholder;
        // binding it by a shared title can make two panes project one thread.
        const titled = pane.title ? threads.filter((item) => item.title === pane.title) : []
        // A thread opened by this web client can be auto-titled in the store
        // before the desktop pane consumes the terminal tail. Its placeholder
        // no longer matches by title, so use the known local identity's index
        // only for that narrow transition.
        const placeholder_indexed = pane.title && isPlaceholderThreadTitle(pane.title)
          ? threads.find(
              (item) => item.sort_index === pane.thread && localThreadIds.has(item.local_thread_id),
            )
          : undefined
        const thread =
          (pane.local_thread_id
            ? threads.find((item) => item.local_thread_id === pane.local_thread_id)
            : undefined) ??
          (pane.provider_thread_id
            ? threads.find((item) => item.provider_thread_id === pane.provider_thread_id)
            : undefined) ??
          titled.find((item) => item.sort_index === pane.thread) ??
          placeholder_indexed ??
          (has_live_layout ? undefined : titled[0]) ??
          (has_live_layout || pane.title
            ? undefined
            : threads.find((item) => item.sort_index === pane.thread))
        if (thread && (!thread.archived || pane.title)) {
          // The daemon thread is the authority for the next turn's settings.
          // Desktop chat.status can lag a web click by several projection
          // cycles, so letting the live pane win here makes every picker look
          // inert until the desktop catches up (and can revert optimistic
          // values on each poll). Preserve explicit nulls because they select
          // provider defaults rather than meaning "missing".
          const model = Object.prototype.hasOwnProperty.call(thread, 'model_ref')
            ? thread.model_ref ?? null
            : pane.model ?? null
          const reasoning_effort = Object.prototype.hasOwnProperty.call(thread, 'reasoning_effort')
            ? thread.reasoning_effort ?? null
            : pane.reasoning_effort ?? null
          const reasoning_variant = Object.prototype.hasOwnProperty.call(thread, 'reasoning_variant')
            ? thread.reasoning_variant ?? null
            : pane.reasoning_variant ?? null
          const fast_mode = Object.prototype.hasOwnProperty.call(thread, 'fast_mode')
            ? thread.fast_mode === 'on'
            : pane.fast_mode ?? false
          const thread_title =
            pane.title && !(isPlaceholderThreadTitle(pane.title) && !isPlaceholderThreadTitle(thread.title))
              ? pane.title
              : thread.title || pane.title || 'Chat'
          used_threads.add(thread.local_thread_id)
          const projected: LivePane = {
            ...chatPane(workspace, thread, turns),
            native_pane_id: pane.id,
            focused,
            thread_index: pane.thread,
            thread_title,
            provider: thread.provider ?? pane.provider ?? workspace.provider,
            model,
            reasoning_effort,
            reasoning_variant,
            fast_mode,
            access_mode: thread.access_mode ?? 'supervised',
            // Live desktop activity beats the store-turn heuristic, which can
            // report long-finished turns as active while the flush lags.
            ...(pane.send_pending !== undefined
              ? {
                  send_pending: pane.send_pending,
                  completion_pending: pane.completion_pending ?? false,
                  pending_approval: pane.pending_approval ?? false,
                  attention: pane.attention ?? false,
                }
              : {}),
          }
          const duplicate_index = rows.findIndex(
            (row) => row.kind === 'chat' && row.thread_id === thread.local_thread_id,
          )
          if (duplicate_index < 0) {
            rows.push(projected)
          } else {
            // A stale desktop layout can contain multiple pane rows for one
            // thread. They all receive the same stable web pane id and turn
            // activity, so rendering each row duplicates the chat in both the
            // workspace and ACTIVE lists. Keep one row, preferring the native
            // pane the desktop currently focuses for subsequent pane actions.
            const previous = rows[duplicate_index]!
            const preferred = projected.focused && !previous.focused ? projected : previous
            rows[duplicate_index] = {
              ...preferred,
              focused: Boolean(previous.focused || projected.focused),
              send_pending: Boolean(previous.send_pending || projected.send_pending),
              completion_pending: Boolean(previous.completion_pending || projected.completion_pending),
              pending_approval: Boolean(previous.pending_approval || projected.pending_approval),
              attention: Boolean(previous.attention || projected.attention),
            }
          }
        } else if (pane.title) {
          // Open on the desktop but its thread has not reached the store yet;
          // show it so the sidebar mirrors the desktop, transcript loads once
          // the store catches up and the title resolves.
          rows.push({
            pane_id: stablePaneId('chat', `${workspace.workspace_id}:live-pane:${pane.id ?? 0}`),
            native_pane_id: pane.id,
            workspace_id: workspace.workspace_id,
            kind: 'chat',
            thread_title: pane.title,
            provider: pane.provider,
            model: pane.model ?? null,
            reasoning_effort: pane.reasoning_effort ?? null,
            fast_mode: pane.fast_mode ?? null,
            focused,
            thread_index: pane.thread,
            send_pending: pane.send_pending ?? false,
            completion_pending: pane.completion_pending ?? false,
            pending_approval: pane.pending_approval ?? false,
            attention: pane.attention ?? false,
          })
        }
      } else if (pane.kind === 'terminal' && typeof pane.dock === 'number') {
        const session = workspace_sessions.find((item) => item.dock_id === pane.dock)
        if (session) {
          used_sessions.add(sessionKey(session))
          rows.push({
            ...termPane(workspace, session),
            native_pane_id: pane.id,
            focused,
            // Live rows carry the desktop's resolved terminal title (surface
            // title -> process label) and the TUI-agent provider; both beat
            // the daemon session-label heuristic.
            ...(pane.title ? { thread_title: pane.title } : {}),
            ...(pane.provider ? { provider: pane.provider } : {}),
            // Same for activity: the desktop only marks a terminal active
            // while its surface is working, never merely because the shell
            // process is alive.
            ...(pane.working !== undefined
              ? { working: pane.working, attention: pane.attention ?? false }
              : {}),
          })
        } else {
          // Pane is open on the desktop but its shell is not running.
          rows.push({
            pane_id: stablePaneId('term', `${workspace.workspace_id}:dock:${pane.dock}`),
            native_pane_id: pane.id,
            workspace_id: workspace.workspace_id,
            kind: 'terminal',
            thread_title: pane.title || pane.purpose || 'Terminal',
            provider: pane.provider,
            dock_id: pane.dock,
            running: false,
            working: pane.working ?? false,
            attention: pane.attention ?? false,
            cwd: workspace.path,
            focused,
          })
        }
      } else if (pane.kind === 'browser') {
        rows.push({
          pane_id: stablePaneId('browser', `${workspace.workspace_id}:browser:${pane.id ?? 0}`),
          native_pane_id: pane.id,
          workspace_id: workspace.workspace_id,
          kind: 'browser',
          thread_title: 'Browser',
          tab_count: Array.isArray(pane.tabs) ? pane.tabs.length : pane.tab_count,
          focused,
        })
      }
    }
    // Threads this client opened that the desktop layout does not know about.
    for (const thread of threads) {
      if (thread.archived || used_threads.has(thread.local_thread_id)) continue
      if (isSubagentThreadId(thread.local_thread_id)) continue
      if (!localThreadIds.has(thread.local_thread_id)) continue
      rows.push(chatPane(workspace, thread, turns))
    }
  } else {
    const recent = [...threads]
      .filter((thread) => !thread.archived && !isSubagentThreadId(thread.local_thread_id))
      .sort((left, right) => (right.last_activity_at ?? 0) - (left.last_activity_at ?? 0))
      .slice(0, MAX_OPEN_THREADS)
    for (const thread of recent) {
      used_threads.add(thread.local_thread_id)
      rows.push(chatPane(workspace, thread, turns))
    }
  }
  // Live sessions with no layout pane: web-created shells, or a desktop
  // layout that lags behind reality between persistence flushes.
  for (const session of workspace_sessions) {
    if (used_sessions.has(sessionKey(session)) || !sessionIsLive(session)) continue
    rows.push(termPane(workspace, session))
  }
  if (layout) {
    const group_by_native = new Map(
      (layout.panes ?? [])
        .filter((pane): pane is PersistedPaneRow & { id: number } => typeof pane.id === 'number')
        .map((pane) => [pane.id, pane.scroll_group] as const),
    )
    for (const pane of rows) {
      if (pane.native_pane_id == null) continue
      pane.scroll_group_id = group_by_native.get(pane.native_pane_id)
    }
  }
  return rows
}

function projectPanes(
  workspaces: Workspace[],
  sessions: SnapshotSession[],
  turns: SnapshotTurn[],
  localThreadIds: ReadonlySet<string>,
  liveLayouts: Record<string, PersistedWorkspaceLayout | null | undefined>,
): Record<string, LivePane[]> {
  const next: Record<string, LivePane[]> = {}
  for (const workspace of workspaces) {
    next[workspace.workspace_id] = panesForWorkspace(
      workspace,
      sessions,
      turns,
      localThreadIds,
      liveLayouts[workspace.workspace_id],
    )
  }
  return next
}

export function createAppStore() {
  const client = new LiveClient()
  const composerCache = readComposerCache()
  const [source, setSource] = createSignal<Source>('mock')
  const [connected, setConnected] = createSignal(false)
  const [workspaces, setWorkspaces] = createSignal<Workspace[]>([])
  const [threadsByWorkspace, setThreadsByWorkspace] = createSignal<Record<string, Thread[]>>({})
  const [panesByWorkspace, setPanesByWorkspace] = createSignal<Record<string, LivePane[]>>({})
  const [workspaceId, setWorkspaceId] = createSignal<string | null>(null)
  const [focusedPaneId, setFocusedPaneId] = createSignal<number | null>(null)
  const [maximizedPaneId, setMaximizedPaneId] = createSignal<number | null>(null)
  const [transcripts, setTranscripts] = createSignal<TranscriptMap>({})
  const [drafts, setDrafts] = createSignal<DraftMap>(composerCache.drafts)
  const [draftAttachments, setDraftAttachments] =
    createSignal<DraftAttachmentMap>(composerCache.attachments)
  const [attachmentUploads, setAttachmentUploads] = createSignal<AttachmentUploadMap>({})
  const [paletteOpen, setPaletteOpen] = createSignal(false)
  const [settingsOpen, setSettingsOpen] = createSignal(false)
  const [workspaceDialogOpen, setWorkspaceDialogOpen] = createSignal(false)
  const [drawerOpen, setDrawerOpen] = createSignal(false)
  const [sidebarCollapsed, setSidebarCollapsed] = createSignal(false)
  const [sending, setSending] = createSignal(false)
  const [notice, setNotice] = createSignal<string | null>(null)
  const [composerNonce, setComposerNonce] = createSignal(0)
  const [explicitComposerNonce, setExplicitComposerNonce] = createSignal(-1)
  const composerFocusExplicit = () => explicitComposerNonce() === composerNonce()
  const requestComposerFocus = () => batch(() => {
    const nonce = composerNonce() + 1
    setExplicitComposerNonce(nonce)
    setComposerNonce(nonce)
  })
  const [compact, setCompact] = createSignal(
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia('(max-width: 1023px)').matches
      : false,
  )
  const [uiConfig, setUiConfig] = createSignal<UiConfig>(DEFAULT_UI_CONFIG)
  const [keybindConfig, setKeybindConfig] = createSignal<WebKeybindConfig>(DEFAULT_WEB_KEYBINDS)
  const [prefixMode, setPrefixMode] = createSignal<'armed' | 'navigate' | null>(null)
  const [prefixHelpVisible, setPrefixHelpVisible] = createSignal(false)
  const [favoriteModels, setFavoriteModels] = createSignal<FavoriteModel[]>([])
  // Snapshot polling can race a user click. Keep the requested final state
  // authoritative until its idempotent config RPC settles.
  const pendingFavoriteModels = new Map<string, boolean>()
  let favoriteModelUpdateQueue: Promise<void> = Promise.resolve()
  let composerCacheTimer: number | null = null
  const persistComposerState = () => {
    if (composerCacheTimer !== null) window.clearTimeout(composerCacheTimer)
    composerCacheTimer = null
    writeComposerCache(drafts(), draftAttachments())
  }
  const scheduleComposerCacheWrite = () => {
    if (composerCacheTimer !== null) window.clearTimeout(composerCacheTimer)
    composerCacheTimer = window.setTimeout(persistComposerState, 300)
  }
  const startupLastChatPane = readLastChatPaneLocation()
  const restoreLastChatOnStartup = startupLastChatPane != null
  const [initialViewReady, setInitialViewReady] = createSignal(!restoreLastChatOnStartup)
  let pendingLastChatPane = startupLastChatPane
  let instantFocusPaneId: number | null = null
  let storeClientId: string | null = null
  let lastSessions: SnapshotSession[] = []
  const [lastTurns, setLastTurns] = createSignal<SnapshotTurn[]>([])
  /// Desktop live-IPC mirrors. Non-null only while the desktop app is
  /// reachable; they then override the (possibly stale) store projection.
  let liveWorkspaces: Workspace[] | null = null
  let liveLayouts: Record<string, PersistedWorkspaceLayout | null> = {}
  // Threads opened from this web client stay visible even though the
  // desktop-persisted layout has no pane for them.
  const localThreadIds = new Set<string>()

  const workspace = createMemo(() => {
    const id = workspaceId()
    if (id) return workspaces().find((item) => item.workspace_id === id) ?? null
    return workspaces()[0] ?? null
  })
  const openPanes = createMemo(() => {
    const id = workspaceId() ?? workspace()?.workspace_id
    if (!id) return []
    return panesByWorkspace()[id] ?? []
  })
  const paneGroups = createMemo(() => {
    const id = workspaceId() ?? workspace()?.workspace_id
    if (!id) return []
    const current = workspace()
    const layout = liveLayouts[id] ?? (current ? parseWorkspaceLayout(current.workspace_layout_json) : null)
    return workspacePaneGroups(openPanes(), layout?.root ?? null)
  })
  const focusedPane = createMemo(() => {
    const id = focusedPaneId()
    const current = openPanes()
    if (id != null) {
      const local = current.find((pane) => pane.pane_id === id)
      if (local) return local
      for (const panes of Object.values(panesByWorkspace())) {
        const pane = panes.find((item) => item.pane_id === id)
        if (pane) return pane
      }
    }
    return current[0] ?? null
  })
  const canvasLayout = createMemo((): LayoutNode | null => {
    const panes = openPanes()
    if (panes.length === 0) return null
    if (compact()) {
      const focus = focusedPane() ?? panes[0]
      return focus ? { leaf: focus.pane_id } : null
    }
    const maximized = maximizedPaneId()
    if (maximized != null && panes.some((pane) => pane.pane_id === maximized)) {
      return { leaf: maximized }
    }
    const focus = focusedPane() ?? panes[0]
    if (!focus) return null
    if (focus.kind === 'chat') {
      const term = panes.find((pane) => pane.kind === 'terminal')
      return synthesizeSplit(focus.pane_id, term?.pane_id ?? null)
    }
    const chat = panes.find((pane) => pane.kind === 'chat')
    return chat ? synthesizeSplit(chat.pane_id, focus.pane_id) : { leaf: focus.pane_id }
  })
  const visiblePanes = createMemo(() => {
    const layout = canvasLayout()
    if (!layout) return []
    const wanted = new Set<number>()
    const collect = (node: LayoutNode) => {
      if ('leaf' in node) {
        wanted.add(node.leaf)
        return
      }
      collect(node.split.first)
      collect(node.split.second)
    }
    collect(layout)
    return openPanes().filter((pane) => wanted.has(pane.pane_id))
  })
  const activePanes = createMemo(() => {
    const rows: LivePane[] = []
    for (const [wsId, panes] of Object.entries(panesByWorkspace())) {
      for (const pane of panes) {
        if (!paneIsActive(pane)) continue
        rows.push({ ...pane, workspace_id: pane.workspace_id || wsId })
      }
    }
    return rows
  })
  const focusedChat = createMemo(() => {
    const pane = focusedPane()
    return pane?.kind === 'chat' ? pane : visiblePanes().find((item) => item.kind === 'chat') ?? null
  })

  const workspacesFromVolatile = (root: SnapshotPayload, listed: Workspace[]): Workspace[] => {
    if (listed.length > 0) return listed.filter((item) => item.workspace_id)
    const by_id = new Map<string, Workspace>()
    const upsert = (workspace_id: string, path: string, label?: string) => {
      if (!workspace_id) return
      const existing = by_id.get(workspace_id)
      if (existing) {
        if (!existing.path && path) existing.path = path
        if ((!existing.label || existing.label === existing.workspace_id) && label) existing.label = label
        return
      }
      by_id.set(workspace_id, {
        workspace_id,
        path,
        label: label || (path ? labelFromPath(path) : workspace_id),
        threads: [],
      })
    }
    for (const session of root.sessions ?? []) {
      const path = session.workspace_path ?? session.cwd ?? ''
      const id = sessionStoreId(session)
      if (id) upsert(id, path.startsWith('/') ? path : '', path ? labelFromPath(path) : session.label)
    }
    for (const turn of root.turns ?? []) {
      if (turn.workspace_id) upsert(turn.workspace_id, '', turn.workspace_id)
    }
    return [...by_id.values()]
  }

  const workspacesWithThreads = (list: Workspace[]): Workspace[] => {
    const catalogs = threadsByWorkspace()
    return list.map((item) => ({
      ...item,
      threads: catalogs[item.workspace_id] ?? item.threads ?? [],
    }))
  }

  const archivedHistoryThreads = new Map<string, number>()

  const publishPanes = (list: Workspace[]) => {
    const panes = projectPanes(workspacesWithThreads(list), lastSessions, lastTurns(), localThreadIds, liveLayouts)
    for (const [id, rows] of Object.entries(panes)) {
      panes[id] = rows.filter((pane) => !pane.thread_id || !archivedHistoryThreads.has(`${id}\u0000${pane.thread_id}`))
    }
    setPanesByWorkspace((prev) => (sameJson(prev, panes) ? prev : panes))
    const restored = pendingLastChatPane
      ? findLastChatPane(panes[pendingLastChatPane.workspace_id] ?? [], pendingLastChatPane)
      : null
    const next = reconcileViewSelection({
      workspace_id: restored?.workspace_id ?? workspaceId(),
      pane_id: restored?.pane_id ?? focusedPaneId(),
      panes_by_workspace: panes,
      workspace_ids: list.map((item) => item.workspace_id),
    })
    if (next.workspace_id && next.workspace_id !== workspaceId()) setWorkspaceId(next.workspace_id)
    if (next.pane_id !== focusedPaneId()) {
      if (typeof next.pane_id === 'number' && (restored || !initialViewReady())) {
        instantFocusPaneId = next.pane_id
      }
      setFocusedPaneId(next.pane_id)
    }
    if (restored) {
      if (restored.thread_id) writeLastChatPaneLocation(restored)
      pendingLastChatPane = null
    }
    const current_panes = next.workspace_id ? panes[next.workspace_id] ?? [] : []
    if (maximizedPaneId() != null && !current_panes.some((pane) => pane.pane_id === maximizedPaneId())) {
      setMaximizedPaneId(null)
    }
  }

  const applySnapshot = (params: unknown, preferId?: string | null) => {
    const unwrapped = unwrapResult<SnapshotPayload>(params)
    const root = unwrapped ?? (asRecord(params) as SnapshotPayload | null)
    if (!root) return
    const snapshot = root.snapshot ?? root
    if (root.sessions) lastSessions = root.sessions
    if (root.turns) {
      // Local snapshots cannot observe turns running on a saved connection.
      batch(() => {
        const turns = root.turns!.map((turn) => approvalTracker.reconcile(turn, 'snapshot'))
        setLastTurns((previous) => mergeLocalTurnSnapshot(previous, turns))
        setTailApprovals((previous) => {
          const next = { ...previous }
          for (const turn of turns) {
            if (turn.turn_id) next[turn.turn_id] = approvalFromTurn(turn)
          }
          return next
        })
      })
    }
    if (root.config !== undefined) {
      const next = parseUiConfig(root.config)
      setUiConfig((prev) => (sameJson(prev, next) ? prev : next))
      const next_keybinds = parseWebKeybindConfig(root.config)
      setKeybindConfig((prev) => (sameJson(prev, next_keybinds) ? prev : next_keybinds))
      if (!next_keybinds.prefix.enabled) {
        setPrefixMode(null)
        setPrefixHelpVisible(false)
      }
      let next_favorites = parseFavoriteModels(root.config)
      for (const [key, favorite] of pendingFavoriteModels) {
        const separator = key.indexOf('\u0000')
        const provider = key.slice(0, separator)
        const model = key.slice(separator + 1)
        next_favorites = setFavoriteModelInList(next_favorites, provider, model, favorite)
      }
      setFavoriteModels((prev) => (sameJson(prev, next_favorites) ? prev : next_favorites))
    }
    const stored = snapshot.workspaces ?? root.workspaces ?? []
    // The desktop live listing decides which workspaces are open whenever the
    // desktop app is reachable; store rows only contribute their persisted
    // layout as the detached fallback. Store rows alone can be stale because
    // the desktop flushes them lazily.
    const listed = liveWorkspaces
      ? liveWorkspaces.map((item) => {
          const row = stored.find((entry) => entry.workspace_id === item.workspace_id)
          // Keep the desktop listing's current label/path while retaining
          // store-only metadata (notably Herdr linkage) used by web menus.
          return row ? { ...row, ...item, workspace_layout_json: row.workspace_layout_json } : item
        })
      : workspacesFromVolatile(root, stored)
    const list = listed.filter((item) => item.workspace_id && !item.archived)
    if (list.length === 0 && lastSessions.length === 0) return
    setWorkspaces((prev) => (sameJson(prev, list) ? prev : list))

    const selectedIndex = typeof snapshot.selected_workspace_index === 'number' ? snapshot.selected_workspace_index : 0
    const keep = resolveWorkspaceId({
      workspace_ids: list.map((item) => item.workspace_id),
      focused_workspace_id: focusedPane()?.workspace_id ?? null,
      current_workspace_id: preferId ?? workspaceId(),
      restore_workspace_id: pendingLastChatPane?.workspace_id,
      snapshot_selected_index: selectedIndex,
    })
    if (keep && keep !== workspaceId()) setWorkspaceId(keep)
    publishPanes(list)

    setTranscripts((prev) => {
      let changed = false
      const next = { ...prev }
      for (const workspace of workspacesWithThreads(list)) {
        for (const thread of workspace.threads ?? []) {
          if (!thread.messages?.length) continue
          const pane_id = stablePaneId('chat', thread.local_thread_id)
          const key = paneKey(workspace.workspace_id, pane_id)
          // Use the same normalizer as an explicit thread fetch. Snapshot
          // refreshes can land immediately after an optimistic send, and
          // narrowing the row here used to replace its persisted images with
          // an otherwise-identical image-less message.
          const mapped = mapTranscriptRows({ thread }, thread.local_thread_id)
          const merged = mergeMessages(prev[key], mergeTranscriptPage(prev[key] ?? [], mapped))
          if (merged !== prev[key]) {
            next[key] = merged
            changed = true
          }
        }
      }
      return changed ? next : prev
    })
  }

  const applyChanges = (params: unknown) => {
    const root = params as {
      result?: { entries?: Array<{ topic: string }>; heartbeat?: boolean }
      entries?: Array<{ topic: string }>
      heartbeat?: boolean
    }
    const result = root.result ?? root
    if (result.heartbeat && !(result.entries && result.entries.length > 0)) return
    void refreshProjection()
  }

  const onEvent: EventHandler = (message) => {
    if (message.method === 'core.hello') {
      const params = message.params as { source?: Source } | undefined
      if (params?.source) setSource(params.source)
      setConnected(true)
      return
    }
    if (message.method === 'core.snapshot') {
      // The pushed startup snapshot has no thread catalog and can therefore
      // project a terminal-only workspace. The explicit initial refresh below
      // builds the remembered chat first; ignore this incomplete preview.
      if (restoreLastChatOnStartup && !initialViewReady()) return
      applySnapshot(message.params, workspaceId())
      return
    }
    if (message.method === 'core.changes') {
      applyChanges(message.params)
    }
  }

  /// Mirror the desktop's live workspace/pane state through verde-web's
  /// Live-socket fallback. Both calls fail cleanly (null) when the desktop
  /// app is closed, which flips the projection to the store/recency paths.
  /// `only_workspace_id` scopes the expensive per-workspace pane/chat.status
  /// enrichment to one workspace. The gateway answers websocket RPCs
  /// serially, so enriching every workspace on every tick queued dozens of
  /// round-trips and made the whole UI feel seconds behind; the routine tick
  /// now enriches only the selected workspace and a periodic full sweep
  /// keeps the background ones fresh.
  const refreshLive = async (
    only_workspace_id: string | null = null,
    enrich_chat_status = true,
  ) => {
    try {
      const listing = await client.call('workspaces', {})
      const rows = workspacesFromLiveListing(listing)
      if (!rows) {
        liveWorkspaces = null
        liveLayouts = {}
        return
      }
      const targets = only_workspace_id
        ? rows.filter((row) => row.workspace_id === only_workspace_id)
        : rows
      const layouts: Record<string, PersistedWorkspaceLayout | null> = {}
      await Promise.all(
        targets.map(async (row) => {
          const panes = await client.call('panes', { workspace: row.workspace_id })
          const layout = layoutFromLivePanes(panes)
          if (layout?.panes) {
            layout.panes = carryLiveChatIdentity(liveLayouts[row.workspace_id]?.panes, layout.panes)
          }
          layouts[row.workspace_id] = layout
          if (!layout?.panes || !enrich_chat_status) return
          // The pane listing on older desktops has no thread ids; chat.status
          // carries local and provider ids so a pane can bind even when the
          // store's title and sort_index are stale.
          await Promise.all(
            layout.panes.map(async (pane) => {
              if (pane.kind !== 'chat' || pane.id == null) return
              const status = await client.call('chat.status', {
                workspace: row.workspace_id,
                pane: pane.id,
              })
              const thread = unwrapResult<{
                thread?: {
                  local_thread_id?: string
                  provider_thread_id?: string | null
                  model?: string | null
                  reasoning_effort?: string | null
                  reasoning_variant?: string | null
                  fast_mode?: boolean | null
                }
              }>(status)?.thread
              if (!thread) return
              if (thread.local_thread_id) pane.local_thread_id = thread.local_thread_id
              if (thread.provider_thread_id) pane.provider_thread_id = thread.provider_thread_id
              if (typeof thread.model === 'string') pane.model = thread.model
              if (thread.reasoning_effort !== undefined) pane.reasoning_effort = thread.reasoning_effort
              if (thread.reasoning_variant !== undefined) pane.reasoning_variant = thread.reasoning_variant
              if (typeof thread.fast_mode === 'boolean') pane.fast_mode = thread.fast_mode
            }),
          )
        }),
      )
      liveWorkspaces = rows
      // Scoped refreshes keep the other workspaces' last-known layouts so
      // their sidebar/ACTIVE rows do not flicker between sweeps.
      liveLayouts = only_workspace_id ? { ...liveLayouts, ...layouts } : layouts
    } catch {
      liveWorkspaces = null
      liveLayouts = {}
    }
  }

  /// Serialize projection refreshes: the routine tick, daemon change events,
  /// and user actions all call this, and letting runs overlap grew unbounded
  /// RPC queues on the gateway's serial websocket loop (the app got slower
  /// the longer it ran). A run requested while one is in flight coalesces
  /// into a single follow-up.
  let projectionInFlight = false
  let projectionQueued = false
  let projectionTick = 0
  /// Every Nth routine refresh enriches all workspaces instead of just the
  /// selected one, bounding staleness of background workspaces to ~20s.
  const PROJECTION_FULL_SWEEP_EVERY = 5

  const refreshProjection = async (
    opts: { scope?: 'selected' | 'full'; workspace_id?: string; enrich_chat_status?: boolean } = {},
  ) => {
    if (projectionInFlight) {
      projectionQueued = true
      return
    }
    projectionInFlight = true
    try {
      // An explicit workspace_id reconciles exactly that workspace (sidebar
      // actions can target a pane outside the selected one) without paying
      // for a full sweep.
      const scope = opts.workspace_id
        ? 'selected'
        : opts.scope ?? (projectionTick++ % PROJECTION_FULL_SWEEP_EVERY === 0 ? 'full' : 'selected')
      const only = opts.workspace_id ??
        (scope === 'selected'
          ? workspaceId() ?? pendingLastChatPane?.workspace_id ?? null
          : null)
      await refreshLive(only, opts.enrich_chat_status ?? true)
      const response = await client.call('core.snapshot', { scopes: SNAPSHOT_SCOPES })
      if (response.error || response.ok === false) return
      applySnapshot(response, opts.workspace_id ?? workspaceId())
      const listed = workspaces()
      if (listed.length === 0) return
      const scoped = only ? listed.filter((item) => item.workspace_id === only) : listed
      const targets = scoped.length > 0 ? scoped : listed
      const catalogs = await Promise.all(
        targets.map(async (item) => {
          const threads = await client.call('chat.thread.list', {
            workspace_id: item.workspace_id,
            limit: THREAD_LIST_LIMIT,
          })
          const fresh = unwrapResult<{ store_revision: number }>(threads)
          if (!threads.error && threads.ok !== false && fresh) {
            reconcileHistoryArchives(archivedHistoryThreads, item.workspace_id, threadListFrom(threads), fresh.store_revision)
          }
          return {
            workspace_id: item.workspace_id,
            threads: threadListFrom(threads),
          }
        }),
      )
      setThreadsByWorkspace((prev) => {
        const next = { ...prev }
        const snapshots = workspaces()
        for (const catalog of catalogs) {
          const snapshot = snapshots.find((item) => item.workspace_id === catalog.workspace_id)?.threads
          next[catalog.workspace_id] = mergeThreadCatalogSettings(
            catalog.workspace_id,
            catalog.threads,
            snapshot,
            prev[catalog.workspace_id],
            localThreadIds,
          )
          catalog.threads = next[catalog.workspace_id]
        }
        return sameJson(prev, next) ? prev : next
      })
      setWorkspaces((prev) => {
        const next = prev.map((item) => {
          const catalog = catalogs.find((row) => row.workspace_id === item.workspace_id)
          if (!catalog) return item
          return { ...item, threads: catalog.threads, thread_count: catalog.threads.length }
        })
        return sameJson(prev, next) ? prev : next
      })
      publishPanes(workspaces())
    } finally {
      projectionInFlight = false
      if (projectionQueued) {
        projectionQueued = false
        void refreshProjection({ scope: 'selected', workspace_id: workspaceId() ?? undefined })
      }
    }
  }

  /// Build the remembered startup pane without waiting for the desktop Live
  /// bridge. The durable snapshot and lightweight catalog are independent, so
  /// fetching them in parallel removes several sequential round-trips from
  /// the first useful paint. Live pane/status reconciliation follows in the
  /// background after the restored pane is visible.
  const restoreInitialProjection = async () => {
    const location = startupLastChatPane
    if (!location) return
    const [snapshot_response, catalog_response] = await Promise.all([
      fetchRpc('core.snapshot', { scopes: SNAPSHOT_SCOPES }),
      fetchRpc('chat.thread.list', {
        workspace_id: location.workspace_id,
        limit: THREAD_LIST_LIMIT,
      }),
    ])
    if (
      snapshot_response.error ||
      snapshot_response.ok === false ||
      catalog_response.error ||
      catalog_response.ok === false
    ) {
      await refreshProjection({
        scope: 'selected',
        workspace_id: location.workspace_id,
        enrich_chat_status: false,
      })
      return
    }
    const listed = threadListFrom(catalog_response)
    setThreadsByWorkspace((prev) => ({
      ...prev,
      [location.workspace_id]: mergeThreadCatalogSettings(
        location.workspace_id,
        listed,
        undefined,
        prev[location.workspace_id],
        localThreadIds,
      ),
    }))
    applySnapshot(snapshot_response, location.workspace_id)
    if (pendingLastChatPane) {
      // The persisted layout can lag a newly opened pane; fall back to the
      // live listing only when the durable projection cannot resolve it.
      await refreshProjection({
        scope: 'selected',
        workspace_id: location.workspace_id,
        enrich_chat_status: false,
      })
    }
  }

  const storeTranscript = (key: string, messages: Message[]) => {
    setTranscripts((prev) => {
      const merged = mergeMessages(prev[key], messages)
      if (merged === prev[key]) return prev
      return { ...prev, [key]: merged }
    })
  }

  const [connections, setConnections] = createSignal<ConnectionCatalog | null>(null)
  const [connectionError, setConnectionError] = createSignal<string | null>(null)
  let connectionRefresh: Promise<void> | null = null
  const refreshConnections = (): Promise<void> => {
    if (connectionRefresh) return connectionRefresh
    connectionRefresh = fetchConnections().then((catalog) => {
      setConnections(catalog)
      setConnectionError(null)
    }).catch((error) => { setConnectionError(error instanceof Error ? error.message : 'Connections unavailable') })
      .finally(() => { connectionRefresh = null })
    return connectionRefresh
  }
  const paneOwningWorkspaceId = (pane: LivePane): string =>
    owningWorkspaceId(pane, threadsByWorkspace())
  const routeThread = (pane: LivePane): Thread => {
    const workspace_id = paneOwningWorkspaceId(pane)
    return threadsByWorkspace()[workspace_id]?.find((thread) => thread.local_thread_id === pane.thread_id)
      ?? { ...openingThreadFromPane(pane), profile_id: pane.profile_id, runtime_id: pane.runtime_id, repository_id: pane.repository_id, repository_cwd: pane.repository_cwd, committed: pane.committed }
  }
  const connectionFor = (pane: LivePane): string =>
    effectiveConnection(routeThread(pane), paneOwningWorkspaceId(pane), connections() ?? { connections: [], defaults: [] })
  const knownLocalConnection = (pane: LivePane): boolean => {
    const thread = routeThread(pane)
    return thread.profile_id === 'local' || (!thread.profile_id && Boolean(thread.committed || thread.provider_thread_id))
  }
  const paneRpc = async (pane: LivePane, method: string, params: unknown): Promise<RpcEnvelope> => {
    if (isLocalTurnRequest(pane, lastTurns(), params) || knownLocalConnection(pane)) return interactiveCall(method, params)
    if (!connections()) await refreshConnections()
    const catalog = connections()
    if (!catalog) throw new Error(connectionError() ?? 'Connections are loading')
    const profile = connectionFor(pane)
    if (profile === 'local') return interactiveCall(method, params)
    const connection = catalog.connections.find((row) => row.profile_id === profile)
    if (!connection) throw new Error('The saved connection for this chat is unavailable')
    return connectionRpc(connection, routeThread(pane).runtime_id, method, params)
  }
  const readiness = createProviderReadinessApi(interactiveCall)
  const chatRuntimeBlocker = (pane: LivePane) => runtimeBlocker(connectionFor(pane), routeThread(pane).runtime_id, connections())
  const providerReadiness = (pane: LivePane, provider = routeThread(pane).provider ?? pane.provider ?? 'codex') =>
    readiness.providerReadiness(provider, connectionFor(pane) !== 'local')
  const recheckProviderReadiness = async (pane: LivePane, options: { silent?: boolean } = {}): Promise<void> => {
    await refreshConnections()
    if (connectionFor(pane) !== 'local') {
      if (!options.silent) setNotice('Provider checks on remote connections are not exposed by the web bridge. Connection status was refreshed.')
      return
    }
    await readiness.recheckProviderReadiness()
  }
  const cwdKey = (pane: LivePane) => JSON.stringify([paneOwningWorkspaceId(pane), connectionFor(pane), routeThread(pane).runtime_id ?? null, connectionFor(pane) === 'local' ? readiness.providerRuntimeId() : connections()?.connections.find((row) => row.profile_id === connectionFor(pane))?.runtime_id ?? null])
  const chatCwdIsLocked = (pane: LivePane) => chatCwdLocked(routeThread(pane), paneWorking(pane))
  const cwdApi = createChatCwdApi<LivePane>({
    locked: chatCwdIsLocked, call: paneRpc, notice: setNotice,
    context: async (pane) => {
      if (pane.kind !== 'chat' || !pane.thread_id) throw new Error('Select a chat first.')
      if (!knownLocalConnection(pane) && !connections()) await refreshConnections()
      if (!knownLocalConnection(pane) && !connections()) throw new Error('Connections are unavailable.')
      const ws = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(pane))
      if (!ws) throw new Error('Workspace is unavailable.')
      const profile = connectionFor(pane)
      const local = profile === 'local'
      if (local && !readiness.providerRuntimeId()) await readiness.recheckProviderReadiness()
      const runtimeId = local ? readiness.providerRuntimeId() : connections()!.connections.find((row) => row.profile_id === profile)?.runtime_id ?? null
      return {
        key: cwdKey(pane), workspace: ws, runtimeId, local,
        known: (threadsByWorkspace()[ws.workspace_id] ?? []).filter((thread) => effectiveConnection(thread, ws.workspace_id, connections() ?? { connections: [], defaults: [] }) === profile),
      }
    },
    save: async (pane, choice) => {
      const ws = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(pane))
      if (!ws || chatCwdIsLocked(pane)) { setNotice('The chat route is locked or unavailable.'); return false }
      const patch = { repository_id: choice.repository_id, repository_cwd: choice.relative_cwd }
      const updated = mergeThreadMetadata(routeThread(pane), patch)
      const response = await upsertThreadMetadata(ws, pane, patch)
      if (!response || response.error || response.ok === false) { setNotice(response?.error?.message ?? 'Could not save the working directory.'); return false }
      setThreadsByWorkspace((previous) => ({ ...previous, [ws.workspace_id]: [updated, ...(previous[ws.workspace_id] ?? []).filter((row) => row.local_thread_id !== updated.local_thread_id)] }))
      publishPanes(workspaces())
      return true
    },
  })
  const setChatCwd = async (pane: LivePane, choiceId: string): Promise<boolean> => {
    if (sending()) { setNotice('Wait for the current operation before changing the working directory.'); return false }
    setSending(true)
    try {
      const pending = settingsUpdateQueues.get(paneKey(pane.workspace_id, pane.pane_id))
      if (pending) await pending
      return await cwdApi.setChatCwd(pane, choiceId)
    } catch { setNotice('Could not change the working directory.'); return false }
    finally { setSending(false) }
  }
  const composerRouteKey = (pane: LivePane): string => {
    const thread = routeThread(pane)
    const workspace = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(pane))
    return JSON.stringify([workspace?.workspace_id, workspace?.path, pane.thread_id, connectionFor(pane),
      thread.provider, thread.provider_thread_id, thread.harness, thread.runtime_id, thread.repository_id, thread.repository_cwd])
  }
  const composerCommands = createComposerCommands<LivePane>({
    key: (pane) => paneKey(pane.workspace_id, pane.pane_id),
    notice: setNotice,
    call: paneRpc,
    context: async (pane) => {
      if (pane.kind !== 'chat') throw new Error('Slash commands require a chat pane.')
      const ws = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(pane))
      if (!ws) throw new Error('The chat workspace is unavailable.')
      if (!knownLocalConnection(pane) && !connections()) await refreshConnections()
      if (!knownLocalConnection(pane) && !connections()) throw new Error('Connections are unavailable.')
      const thread = routeThread(pane)
      const routeKey = composerRouteKey(pane)
      if (thread.harness && thread.harness !== 'local_cli') throw new Error('Slash commands are unsupported by this harness.')
      if (connectionFor(pane) !== 'local') throw new Error('Slash commands are unavailable for saved remote connections in the web app.')
      if (!readiness.providerRuntimeId()) await readiness.recheckProviderReadiness()
      const runtime = readiness.providerRuntimeId()
      if (!runtime || (thread.runtime_id && thread.runtime_id !== runtime)) throw new Error('The chat runtime is unavailable or changed.')
      const response = await interactiveCall('workspace.repository.manifest.get', { workspace_id: ws.workspace_id })
      if (response.error || response.ok === false) throw new Error(response.error?.message ?? 'Could not resolve the repository.')
      const manifest = unwrapResult<Parameters<typeof repositoryCommandPath>[0] & { workspace_id: string }>(response)
      if (!manifest || manifest.workspace_id !== ws.workspace_id) throw new Error('The repository manifest is unavailable.')
      const project_path = repositoryCommandPath(manifest, thread.repository_id ?? 'primary', runtime, thread.repository_cwd)
      if (project_path !== ws.path) throw new Error('The workspace repository root changed. Reload the workspace before running commands.')
      if (routeKey !== composerRouteKey(pane) || runtime !== readiness.providerRuntimeId()) throw new Error('The chat route changed. Select the command again.')
      return { provider: thread.provider ?? pane.provider ?? 'codex', project_path, thread_id: thread.provider_thread_id ?? pane.provider_thread_id ?? null }
    },
  })
  const [slashStates, setSlashStates] = createSignal<Record<string, { pending: boolean; result: SlashCommandResult | null }>>({})
  const slashCommandState = (pane: LivePane) => slashStates()[paneKey(pane.workspace_id, pane.pane_id)] ?? { pending: false, result: null }
  const submitSlashCommand = async (pane: LivePane, draft = draftFor(pane)): Promise<SlashCommandResult | null> => {
    if (slashCommandState(pane).pending || sending() || paneWorking(pane) || activeFollowupTurn(pane)) {
      setNotice('Wait for the current operation before running a slash command.')
      return null
    }
    if (attachmentsFor(pane).length || uploadingAttachmentsFor(pane)) {
      setNotice('Slash commands do not accept attachments. Remove them or send a chat message.')
      return null
    }
    const key = paneKey(pane.workspace_id, pane.pane_id)
    setSlashStates((previous) => ({ ...previous, [key]: { pending: true, result: null } }))
    setSending(true)
    let result: SlashCommandResult | null = null
    try {
      const pendingSettings = settingsUpdateQueues.get(key)
      if (pendingSettings) await pendingSettings
      result = await composerCommands.submitSlashCommand(pane, draft)
      if (result?.handled && draftFor(pane) === draft) setDraftFor(pane, '')
      return result
    } finally {
      setSending(false)
      setSlashStates((previous) => ({ ...previous, [key]: { pending: false, result } }))
    }
  }
  onCleanup(composerCommands.cancelAllFileSearches)

  const setChatConnection = async (pane: LivePane, profile: string | null): Promise<boolean> => {
    if (sending()) return false
    setSending(true)
    try {
      if (paneWorking(pane) || routeThread(pane).committed || routeThread(pane).provider_thread_id) {
        setNotice('Start a new chat to change its connection.')
        return false
      }
      const ws = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(pane))
      if (!ws) return false
      const patch = { profile_id: profile, runtime_id: null, repository_id: 'primary', repository_cwd: null }
      const response = await upsertThreadMetadata(ws, pane, patch)
      if (!response || response.error || response.ok === false) {
        setNotice(response?.error?.message ?? 'Could not save this chat connection')
        return false
      }
      setThreadsByWorkspace((prev) => ({ ...prev, [ws.workspace_id]: (prev[ws.workspace_id] ?? []).map((row) => row.local_thread_id === pane.thread_id ? { ...row, ...patch } : row) }))
      publishPanes(workspaces())
      return true
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Could not save this chat connection')
      return false
    } finally {
      setSending(false)
    }
  }

  const transcriptHistory = createTranscriptHistory({
    read: key => transcripts()[key] ?? [],
    write: storeTranscript,
  })
  const requestedTranscripts = new Set<string>()
  const transcriptIdentity = (pane: LivePane): string => {
    const thread = routeThread(pane)
    const profile = connectionFor(pane)
    const runtime = profile === 'local' ? null : connections()?.connections.find(row => row.profile_id === profile)?.runtime_id ?? null
    return JSON.stringify([paneOwningWorkspaceId(pane), pane.thread_id, profile, thread.runtime_id ?? null, runtime])
  }
  const transcriptState = (pane: LivePane) => transcriptHistory.state(paneKey(pane.workspace_id, pane.pane_id), transcriptIdentity(pane))
  const transcriptContext = (pane: LivePane): TranscriptContext => {
    const identity = transcriptIdentity(pane)
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const current = () => {
      const latest = panesByWorkspace()[pane.workspace_id]?.find(row => row.pane_id === pane.pane_id) ?? pane
      return latest.thread_id === pane.thread_id && transcriptIdentity(latest) === identity
    }
    return {
      key, identity, current,
      fetch: cursor => {
        if (!current()) return Promise.reject(new Error('Chat connection changed.'))
        return fetchTranscriptPage((method, params) => {
          if (!current()) return Promise.reject(new Error('Chat connection changed.'))
          return paneRpc(pane, method, params)
        }, { workspace_id: paneOwningWorkspaceId(pane), local_thread_id: pane.thread_id! }, cursor)
      },
    }
  }
  const loadTranscript = async (pane: LivePane, force = false) => {
    if (pane.kind !== 'chat' || !pane.thread_id) return
    // Resolve inherited routes before capturing the cache/request identity.
    if (!connections() && !knownLocalConnection(pane)) await refreshConnections()
    await transcriptHistory.load(transcriptContext(pane), force)
  }
  const loadOlderTranscript = async (pane: LivePane) => {
    if (pane.kind !== 'chat' || !pane.thread_id) return
    await transcriptHistory.loadOlder(transcriptContext(pane))
  }
  const retryTranscript = (pane: LivePane) => loadTranscript(pane, true)

  // ---- Live turn streaming ------------------------------------------------
  // The daemon executes every chat turn (desktop-started ones included) and
  // buffers its stream as seq-numbered events. Tailing `chat.turn.tail` with
  // a cursor mirrors the stream the same way the desktop renders it, so the
  // committed transcript stays the durable base and the tail is an overlay
  // appended on top until the turn commits.
  interface TurnTail {
    turn_id: string
    last_seq: number
    parts: Message[]
    tool_rows: Map<string, Message>
    stream: string
    /// Daemon acceptance time driving the working timer (desktop parity).
    started_at_ms: number
    /// Reasoning liveness: last event was an in-progress `think` call, so the
    /// working label swaps its verb the way the desktop does.
    thinking: boolean
    /// Live diff aggregation, mirroring transcript_apply: one "Changed files"
    /// row upserted in place, per-path merge, snapshot scope replaces.
    diff_files: Map<string, { path: string; additions: number; deletions: number; patch: string }>
    diff_row: Message | null
    has_diff_snapshot: boolean
    /// Author for flushed assistant segments, matching the committed rows'
    /// provider label so live and durable transcripts read identically.
    author_label: string
  }
  const [tailApprovals, setTailApprovals] = createSignal<Record<string, PendingApproval | null>>({})
  const approvalTracker = createApprovalTracker()
  const pendingApproval = (pane: LivePane): PendingApproval | null => {
    const approval = pendingApprovalForPane(pane, lastTurns(), tailApprovals())
    return approval && !approvalTracker.isSubmitted(approval) ? approval : null
  }
  const resolveApproval = async (pane: LivePane, decision: ApprovalDecision): Promise<boolean> => {
    const approval = pendingApproval(pane)
    if (!approval) {
      setNotice('This chat has no pending approval.')
      return false
    }
    try {
      return await approvalTracker.resolve(approval, () =>
        requestApprovalResolution(approval, decision, (method, params) => paneRpc(pane, method, params)))
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Could not resolve the approval')
      return false
    }
  }
  const turnTails = new Map<string, TurnTail>()
  const [overlays, setOverlays] = createSignal<TranscriptMap>({})

  const clearOverlay = (key: string) => {
    const turn_id = turnTails.get(key)?.turn_id
    if (turn_id) setTailApprovals((prev) => ({ ...prev, [turn_id]: null }))
    turnTails.delete(key)
    setOverlays((prev) => {
      if (!(key in prev)) return prev
      const next = { ...prev }
      delete next[key]
      return next
    })
  }

  const overlayMessages = (pane: LivePane, tail: TurnTail): Message[] => {
    void pane
    const rows = [...tail.parts]
    // Desktop parity: the streaming bubble is always present while a turn
    // works — its author slot carries the ticking Working/Thinking timer and
    // an empty stream shows the waiting placeholder. ChatPane renders the
    // timer from `created_at_ms` (daemon acceptance time).
    rows.push({
      message_id: `${tail.turn_id}-stream`,
      role: 'assistant',
      author: tail.thinking ? 'Thinking' : 'Working',
      body: tail.stream,
      created_at_ms: tail.started_at_ms,
    })
    return rows
  }

  // Desktop parity (transcript_apply.flushAssistant): streamed text flushes
  // into an ordered assistant row whenever a renderable event lands, so the
  // agent's narration interleaves with tool/diff cards instead of pooling in
  // the trailing working bubble.
  const flushStreamPart = (tail: TurnTail) => {
    if (tail.stream.length === 0) return
    const body = tail.stream
    tail.stream = ''
    if (body.trim().length === 0) return
    tail.parts.push({
      message_id: `${tail.turn_id}-part-${tail.parts.length}`,
      role: 'assistant',
      author: tail.author_label,
      body,
    })
  }

  // The daemon's committed "Changed files" body format (diffBodyAlloc):
  // VERDE_DIFF_V2\nFILE\t<path_bytes>\t<add>\t<del>\t<patch_bytes>\n<path><patch>
  // Byte lengths on purpose — the committed rows use them, so live overlay
  // rows encode identically and one parser renders both.
  const encodeDiffBody = (
    files: Iterable<{ path: string; additions: number; deletions: number; patch: string }>,
  ): string => {
    const chunks: string[] = ['VERDE_DIFF_V2\n']
    const encoder = new TextEncoder()
    for (const file of files) {
      const path_bytes = encoder.encode(file.path).length
      const patch_bytes = encoder.encode(file.patch).length
      chunks.push(
        `FILE\t${path_bytes}\t${file.additions}\t${file.deletions}\t${patch_bytes}\n${file.path}${file.patch}`,
      )
    }
    return chunks.join('')
  }

  const applyDiffTailEvent = (tail: TurnTail, payload: Record<string, unknown>) => {
    const files = Array.isArray(payload.files) ? payload.files : null
    if (!files) return
    const snapshot = payload.scope === 'turn_snapshot'
    if (!snapshot && tail.has_diff_snapshot) return
    if (snapshot) {
      tail.diff_files.clear()
      tail.has_diff_snapshot = true
    }
    for (const value of files) {
      if (!value || typeof value !== 'object') continue
      const file = value as Record<string, unknown>
      if (typeof file.path !== 'string') continue
      tail.diff_files.set(file.path, {
        path: file.path,
        additions: typeof file.additions === 'number' ? file.additions : 0,
        deletions: typeof file.deletions === 'number' ? file.deletions : 0,
        patch: typeof file.patch === 'string' ? file.patch : '',
      })
    }
    if (tail.diff_files.size === 0) return
    flushStreamPart(tail)
    const row: Message = {
      message_id: `${tail.turn_id}-diff`,
      role: 'system',
      author: 'Changed files',
      body: encodeDiffBody(tail.diff_files.values()),
    }
    if (tail.diff_row) {
      const index = tail.parts.indexOf(tail.diff_row)
      if (index >= 0) tail.parts[index] = row
      else tail.parts.push(row)
    } else {
      tail.parts.push(row)
    }
    tail.diff_row = row
  }

  const applyTailEvent = (tail: TurnTail, kind: string, payload: Record<string, unknown>) => {
    if (kind === 'steer') {
      flushStreamPart(tail)
      const message_id = typeof payload.message_id === 'string' ? payload.message_id : `${tail.turn_id}-steer-${payload.steer_id}`
      if (!tail.parts.some((row) => row.message_id === message_id)) tail.parts.push({
        message_id, role: 'user', author: 'You', body: typeof payload.body === 'string' ? payload.body : '',
        images: Array.isArray(payload.images) ? payload.images as Attachment[] : [],
      })
      return
    }
    if (kind === 'assistant_delta') {
      if (typeof payload.text === 'string') tail.stream += payload.text
      tail.thinking = false
      return
    }
    if (kind === 'diff') {
      applyDiffTailEvent(tail, payload)
      return
    }
    if (kind === 'message') {
      flushStreamPart(tail)
      tail.parts.push({
        message_id: `${tail.turn_id}-part-${tail.parts.length}`,
        role: 'system',
        author: typeof payload.title === 'string' ? payload.title : '',
        body: typeof payload.body === 'string' ? payload.body : '',
      })
      return
    }
    if (kind === 'tool_call') {
      const tool_kind = typeof payload.kind === 'string' ? payload.kind : 'tool'
      // Reasoning lifecycle events carry no renderable content; the desktop
      // aggregates them into a counter chip rather than transcript rows. They
      // do drive the Working→Thinking verb swap while in progress.
      if (tool_kind === 'think') {
        tail.thinking = payload.status === 'in_progress' || payload.status === 'pending'
        return
      }
      tail.thinking = false
      flushStreamPart(tail)
      const call_id = typeof payload.call_id === 'string' ? payload.call_id : ''
      const status = typeof payload.status === 'string' ? payload.status : null
      const input = typeof payload.input === 'string' ? payload.input : null
      const output = typeof payload.output === 'string' ? payload.output : null
      const error_text = typeof payload.error_text === 'string' ? payload.error_text : null
      const title = typeof payload.title === 'string' && payload.title.length > 0 ? payload.title : null
      // Canonical command authoring drives the web's compact command rows and
      // failure styling, same contract as committed transcript rows.
      const author =
        tool_kind === 'subagent'
          ? 'Subagent'
          : title ?? (tool_kind === 'execute' ? (status === 'failed' ? 'Command failed' : 'Ran command') : tool_kind)
      const body =
        [
          title && tool_kind === 'subagent' ? `Tool:\n${title}` : null,
          input && `Input:\n${input}`,
          output && `Output:\n${output}`,
          error_text,
        ]
          .filter(Boolean)
          .join('\n\n') || author
      const row: Message = {
        message_id: `${tail.turn_id}-tool-${call_id}`,
        role: 'system',
        author,
        body,
        tool_call_id: call_id || null,
        tool_call_kind: tool_kind,
        tool_call_status: status,
      }
      // Lifecycle updates reuse the call id; update the row in place so a
      // started call flips to completed/failed instead of duplicating.
      const existing = call_id ? tail.tool_rows.get(call_id) : undefined
      if (existing) {
        const index = tail.parts.indexOf(existing)
        if (index >= 0) tail.parts[index] = row
      } else {
        tail.parts.push(row)
      }
      if (call_id) tail.tool_rows.set(call_id, row)
    }
    // Approval details come from the tail response, not the call-id-only event.
    // Other bookkeeping events carry no transcript row; failures surface
    // through the committed transcript on finalize.
  }

  const turnIsTerminal = (status: string | undefined) =>
    status === 'completed' || status === 'failed' || status === 'aborted'

  // Mirror of the desktop's providerLabel so live flushed segments carry the
  // same author the daemon writes into the committed transcript.
  const providerAuthorLabel = (provider: string | undefined): string => {
    switch (provider) {
      case 'opencode':
        return 'OpenCode'
      case 'codex':
        return 'Codex'
      case 'claude':
        return 'Claude'
      case 'cursor':
        return 'Cursor'
      case 'pi':
        return 'Pi'
      case 'fx':
        return 'FX'
      case 'grok':
        return 'Grok'
      case 'muse':
        return 'Muse'
      default:
        return provider ? provider.charAt(0).toUpperCase() + provider.slice(1) : 'Assistant'
    }
  }

  // Desktop turn ids end in `:<accept-ms>`; parse it as the timer fallback
  // when the daemon predates the started_at_ms field.
  const startedAtFromTurnId = (turn_id: string): number | null => {
    const last = turn_id.split(':').at(-1) ?? ''
    if (!/^\d{13}$/.test(last)) return null
    const value = Number(last)
    return Number.isFinite(value) ? value : null
  }

  // Push-per-delta long-poll pacing. The daemon parks `chat.turn.tail` up to
  // `wait_ms` and answers the instant an event lands, so the loop below
  // re-polls immediately. A fast empty response means the running daemon
  // predates `wait_ms` (unknown params are ignored) or its parked-waiter cap
  // degraded the wait — fall back to interval pacing instead of hot-looping.
  const TAIL_WAIT_MS = 20_000
  const TAIL_FAST_EMPTY_MS = 1_000
  const TAIL_FALLBACK_DELAY_MS = 1_500
  const sleep = (ms: number) => new Promise<void>((resolve) => window.setTimeout(resolve, ms))
  // Loops already driving a tail object; replaced tails simply orphan the old
  // loop, which exits at its next identity check.
  const runningTails = new Set<TurnTail>()
  // Turns observed terminal by a loop; discovery skips them while lastTurns
  // still lists them as working (projection lag).
  const finishedTurns = new Set<string>()

  const runTailLoop = async (pane: LivePane, key: string, tail: TurnTail) => {
    while (turnTails.get(key) === tail) {
      const started = Date.now()
      let response
      try {
        // HTTP on purpose: the gateway handles websocket RPCs synchronously
        // in its read loop, so a parked long-poll over the socket would stall
        // pings and every other in-flight call. Each HTTP request rides its
        // own gateway connection task and may hang safely.
        response = await paneRpc(pane, 'chat.turn.tail', {
          turn_id: tail.turn_id,
          after_seq: tail.last_seq,
          wait_ms: connectionFor(pane) === 'local' ? TAIL_WAIT_MS : 0,
        })
      } catch {
        // A mobile page freeze commonly terminates the parked HTTP request.
        // Keep the cursor and visible overlay so foreground recovery can
        // restart from the next missing daemon event instead of flashing an
        // empty turn.
        return
      }
      if (turnTails.get(key) !== tail) return
      if (response.error || response.ok === false) {
        // Stale turn record (daemon restarted, turn consumed): drop the
        // overlay rather than replaying a cursor against a missing turn.
        clearOverlay(key)
        return
      }
      const result = unwrapResult<{
        status?: string
        provider_thread_id?: string | null
        pending_approval?: SnapshotTurn['pending_approval']
        next_seq?: number
        started_at_ms?: number
        page_last_seq?: number
        events?: Array<{ seq?: number; kind?: string; payload_json?: string }>
      }>(response)
      if (!result) {
        clearOverlay(key)
        return
      }
      // Prefer the daemon's acceptance clock over any local estimate.
      if (typeof result.started_at_ms === 'number' && result.started_at_ms > 0) {
        tail.started_at_ms = result.started_at_ms
      }
      const cursor_before = tail.last_seq
      const events = result.events ?? []
      for (const event of events) {
        if (!event.kind) continue
        let payload: Record<string, unknown> = {}
        try {
          payload = (JSON.parse(event.payload_json ?? '{}') as Record<string, unknown>) ?? {}
        } catch {
          continue
        }
        if (event.kind === 'steer') followups.observeSteer(pane, tail.turn_id, payload, event.seq)
        applyTailEvent(tail, event.kind, payload)
      }
      batch(() => {
        const observed = approvalTracker.reconcile({
          turn_id: tail.turn_id, status: result.status,
          ...(result.provider_thread_id ? { provider_thread_id: result.provider_thread_id } : {}),
          pending_approval: result.pending_approval, next_seq: result.next_seq,
        }, 'tail')
        setLastTurns((turns) => turns.map((turn) => turn.turn_id === tail.turn_id ? { ...turn, ...observed } : turn))
        setTailApprovals((prev) => ({ ...prev, [tail.turn_id]: approvalFromTurn(observed) }))
      })
      tail.last_seq = lastDeliveredTailSeq(tail.last_seq, events, result.page_last_seq)
      if (turnIsTerminal(result.status)) {
        // Durable-first: a terminal status is published only after the turn's
        // messages commit, so the committed transcript fetched here already
        // contains everything the overlay showed.
        followups.observeTurn(pane, tail.turn_id, result.status)
        await loadTranscript(pane, true)
        if (turnTails.get(key) !== tail) return
        if (transcriptState(pane).error) {
          await sleep(TAIL_FALLBACK_DELAY_MS)
          continue
        }
        finishedTurns.add(tail.turn_id)
        await refreshProjection({ scope: 'selected' })
        clearOverlay(key)
        await followups.flushReady()
        return
      }
      setOverlays((prev) => ({ ...prev, [key]: overlayMessages(pane, tail) }))
      if (tail.last_seq === cursor_before && Date.now() - started < TAIL_FAST_EMPTY_MS) {
        await sleep(TAIL_FALLBACK_DELAY_MS)
      }
    }
  }

  // Ensure a long-poll loop is streaming the pane's newest active turn.
  const tailActiveTurn = (pane: LivePane) => {
    if (pane.kind !== 'chat' || !pane.thread_id) return
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const turn = lastTurns()
      .filter(
        (item) =>
          item.turn_id &&
          item.workspace_id === pane.workspace_id &&
          item.local_thread_id === pane.thread_id &&
          turnIsActive(item.status),
      )
      .at(-1)
    if (!turn?.turn_id || finishedTurns.has(turn.turn_id)) {
      const existing = turnTails.get(key)
      if (existing && runningTails.has(existing)) return
      if (turnTails.has(key)) clearOverlay(key)
      return
    }
    let tail = turnTails.get(key)
    if (!tail || tail.turn_id !== turn.turn_id) {
      tail = {
        turn_id: turn.turn_id,
        last_seq: 0,
        parts: [],
        tool_rows: new Map(),
        stream: '',
        started_at_ms: turn.started_at_ms ?? startedAtFromTurnId(turn.turn_id) ?? Date.now(),
        thinking: false,
        diff_files: new Map(),
        diff_row: null,
        has_diff_snapshot: false,
        author_label: providerAuthorLabel(pane.provider),
      }
      turnTails.set(key, tail)
      // Show the working bubble immediately; events stream into it after.
      setOverlays((prev) => ({ ...prev, [key]: overlayMessages(pane, tail!) }))
    }
    if (runningTails.has(tail)) return
    runningTails.add(tail)
    void runTailLoop(pane, key, tail).finally(() => runningTails.delete(tail!))
  }

  const refreshTranscripts = async () => {
    const jobs: LivePane[] = []
    const seen = new Set<string>()
    const consider = (pane: LivePane | null | undefined) => {
      if (!pane || pane.kind !== 'chat') return
      const key = paneKey(pane.workspace_id, pane.pane_id)
      if (seen.has(key)) return
      seen.add(key)
      jobs.push(pane)
    }
    // Focused/followup history is needed immediately; other panes request
    // their first page when they approach the viewport.
    consider(focusedPane())
    for (const pane of followups.panes()) consider(pane)
    const eager = new Set(seen)
    for (const pane of openPanes()) {
      if (!compact() || requestedTranscripts.has(paneKey(pane.workspace_id, pane.pane_id))) consider(pane)
    }
    for (const pane of jobs) {
      // Streaming rides its own long-poll loop; this tick only (re)starts
      // loops after turn discovery. The committed base re-downloads only
      // when missing — a finished turn's tail loop reloads it once on
      // commit. Refetching while a turn was live shipped multi-megabyte
      // threads through JSON parse/merge every 1.5s (this chat's ~1 MiB
      // command card included) and froze the composer on phones. Loading
      // uncached panes sequentially keeps each parse/merge in its own
      // frame budget.
      if (connections() && connectionFor(pane) !== 'local' && !turnTails.has(paneKey(pane.workspace_id, pane.pane_id))) {
        try {
          const response = await paneRpc(pane, 'chat.turn.list', { workspace_id: pane.workspace_id })
          const remote_turns = unwrapResult<{ turns?: SnapshotTurn[] }>(response)?.turns ?? []
          batch(() => {
            const matching = remote_turns
              .filter((turn) => turn.workspace_id === pane.workspace_id && turn.local_thread_id === pane.thread_id)
              .map((turn) => ({ ...turn, profile_id: connectionFor(pane) }))
              .map((turn) => approvalTracker.reconcile(turn, 'snapshot'))
            setLastTurns((turns) => [...turns.filter((turn) => !(turn.workspace_id === pane.workspace_id && turn.local_thread_id === pane.thread_id)), ...matching])
            setTailApprovals((previous) => {
              const next = { ...previous }
              for (const turn of matching) {
                if (turn.turn_id) next[turn.turn_id] = approvalFromTurn(turn)
              }
              return next
            })
          })
        } catch { /* Keep the current view until the connection recovers. */ }
      }
      const pending = followups.pendingFollowup(pane)
      if (pending) {
        const turn = lastTurns().find((turn) => turn.turn_id === pending.turn_id)
        followups.observeTurn(pane, pending.turn_id, turn?.status)
      }
      tailActiveTurn(pane)
      const history = transcriptState(pane)
      const key = paneKey(pane.workspace_id, pane.pane_id)
      if ((eager.has(key) || requestedTranscripts.has(key)) && !history.loaded && !history.error) await loadTranscript(pane)
    }
    await followups.flushReady()
  }

  const ensureTranscript = (pane: LivePane | null | undefined) => {
    if (!pane || pane.kind !== 'chat') return
    requestedTranscripts.add(paneKey(pane.workspace_id, pane.pane_id))
    const history = transcriptState(pane)
    if (history.loaded || history.loading || history.error) return
    void loadTranscript(pane)
  }

  /// Reactive "this pane has a live turn": an overlay is streaming, or the
  /// projection still reports a pending send. Drives the composer's
  /// stop-instead-of-send affordance (desktop parity).
  const paneWorking = (pane: LivePane | null | undefined): boolean => {
    if (!pane || pane.kind !== 'chat') return false
    const key = paneKey(pane.workspace_id, pane.pane_id)
    return chatPaneHasLiveTurn(pane, Boolean(overlays()[key]?.length))
  }

  /// Abort the pane's active turn, mirroring the desktop's composer stop
  /// button. The daemon flips the turn to aborted and appends an "aborted"
  /// event; the tail loop observes the terminal status and swaps the overlay
  /// for the committed transcript.
  const stopTurn = async (pane: LivePane | null | undefined) => {
    if (!pane || pane.kind !== 'chat' || !pane.thread_id) return
    // Pause queued work before looking up the turn: completion may race Stop.
    followups.inhibit(pane)
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const turn_id =
      turnTails.get(key)?.turn_id ??
      lastTurns()
        .filter(
          (item) =>
            item.turn_id &&
            item.workspace_id === pane.workspace_id &&
            item.local_thread_id === pane.thread_id &&
            turnIsActive(item.status),
        )
        .at(-1)?.turn_id
    if (!turn_id) return
    const response = await paneRpc(pane, 'chat.turn.cancel', { turn_id })
    if (response.error || response.ok === false) {
      setNotice(response.error?.message ?? 'could not stop the turn')
    }
  }

  const ensureClientId = async (): Promise<string> => {
    if (storeClientId) return storeClientId
    storeClientId = await registerHistoryClient(interactiveCall)
    return storeClientId
  }

  const selectWorkspace = (id: string) => {
    pendingLastChatPane = null
    setWorkspaceId(id)
    setDrawerOpen(false)
    const first = panesByWorkspace()[id]?.[0]
    setFocusedPaneId(first?.pane_id ?? null)
    if (first?.kind === 'chat') writeLastChatPaneLocation(first)
    // The switch itself renders instantly from cached panes/transcripts; the
    // scoped refresh only reconciles this workspace in the background.
    void refreshProjection({ scope: 'selected', workspace_id: id }).then(() => refreshTranscripts())
  }

  const focusPane = (pane: LivePane) => {
    pendingLastChatPane = null
    setWorkspaceId(pane.workspace_id)
    setFocusedPaneId(pane.pane_id)
    writeLastChatPaneLocation(pane)
    // Zoom follows focus like the desktop: pane navigation while zoomed keeps
    // the zoom and shows the newly focused pane instead of pinning the old one.
    if (maximizedPaneId() != null) setMaximizedPaneId(pane.pane_id)
    setDrawerOpen(false)
    void loadTranscript(pane)
  }

  const takeInstantFocus = (pane_id: number): boolean => {
    if (instantFocusPaneId !== pane_id) return false
    instantFocusPaneId = null
    return true
  }

  const draftFor = (pane: LivePane | null | undefined) => {
    if (!pane) return ''
    return drafts()[paneKey(pane.workspace_id, pane.pane_id)] ?? ''
  }

  const setDraftFor = (pane: LivePane, text: string) => {
    const key = paneKey(pane.workspace_id, pane.pane_id)
    setDrafts((prev) => ({ ...prev, [key]: text }))
    scheduleComposerCacheWrite()
  }

  /// Prefills the pane's composer with an @-mention of a diff-card file plus
  /// its +/- counts and edited line ranges so the user can steer the agent on
  /// that specific edit (desktop beginDiffCommentDraft parity). Appends to an
  /// in-progress draft instead of replacing it.
  const beginDiffComment = (
    pane: LivePane,
    file: { path: string; additions: number; deletions: number; patch: string },
  ) => {
    // Diff cards carry absolute paths; mentions use workspace-relative ones.
    let mention = file.path
    const root = workspaces().find((item) => item.workspace_id === pane.workspace_id)?.path ?? ''
    if (root && mention.startsWith(`${root}/`)) mention = mention.slice(root.length + 1)
    const ranges = diffCommentLineSummary(file.patch)
    const draft = draftFor(pane)
    const separator = draft.length === 0 || draft.endsWith('\n') ? '' : '\n'
    const lines = ranges ? `, ${ranges}` : ''
    setDraftFor(
      pane,
      `${draft}${separator}About your edit to @${mention} (+${file.additions}/-${file.deletions}${lines}): `,
    )
    focusPane(pane)
    setComposerNonce((value) => value + 1)
  }

  const attachmentsFor = (pane: LivePane | null | undefined) => {
    if (!pane) return []
    return draftAttachments()[paneKey(pane.workspace_id, pane.pane_id)] ?? []
  }

  const uploadingAttachmentsFor = (pane: LivePane | null | undefined) => {
    if (!pane) return false
    return (attachmentUploads()[paneKey(pane.workspace_id, pane.pane_id)] ?? 0) > 0
  }

  const attachFiles = async (pane: LivePane, selected: File[]) => {
    if (selected.length === 0) return
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const accepted: Array<{ file: File; mime: string }> = []
    for (const file of selected) {
      const mime = imageMimeForFile(file)
      if (!mime) {
        setNotice(`${file.name || 'That file'} is not a supported image.`)
        continue
      }
      if (file.size > MAX_CHAT_IMAGE_BYTES) {
        setNotice(`${file.name || 'That image'} is larger than 10 MB.`)
        continue
      }
      accepted.push({ file, mime })
    }
    if (accepted.length === 0) return
    setAttachmentUploads((prev) => ({ ...prev, [key]: (prev[key] ?? 0) + accepted.length }))
    setNotice(null)
    try {
      const results = await Promise.allSettled(
        accepted.map(({ file, mime }) => uploadChatImage(file, mime)),
      )
      const uploaded: Attachment[] = []
      let failure: string | null = null
      for (const result of results) {
        if (result.status === 'fulfilled') uploaded.push(result.value)
        else failure ??= result.reason instanceof Error ? result.reason.message : 'image upload failed'
      }
      if (uploaded.length > 0) {
        setDraftAttachments((prev) => ({ ...prev, [key]: [...(prev[key] ?? []), ...uploaded] }))
        scheduleComposerCacheWrite()
      }
      if (failure) setNotice(failure)
    } finally {
      setAttachmentUploads((prev) => {
        const next = { ...prev }
        delete next[key]
        return next
      })
    }
  }

  const removeAttachment = (pane: LivePane, attachment: Attachment) => {
    const key = paneKey(pane.workspace_id, pane.pane_id)
    setDraftAttachments((prev) => ({
      ...prev,
      [key]: (prev[key] ?? []).filter((item) => item.path !== attachment.path),
    }))
    scheduleComposerCacheWrite()
    if (!followups.ownsAttachment(attachment.path) &&
        !Object.values(draftAttachments()).some((images) => images.some((image) => image.path === attachment.path))) {
      void deleteChatImage(attachment).catch(() => {})
    }
  }

  const messagesFor = (pane: LivePane | null | undefined) => {
    if (!pane) return []
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const committed = transcriptHistory.matches(key, transcriptIdentity(pane)) ? transcripts()[key] ?? [] : []
    const overlay = overlays()[key]
    return overlay?.length ? [...committed, ...overlay] : committed
  }

  const activeFollowupTurn = (pane: LivePane): string | null => lastTurns()
    .filter((turn) => turn.workspace_id === pane.workspace_id && turn.local_thread_id === pane.thread_id &&
      turn.turn_id && turnIsActive(turn.status) && !finishedTurns.has(turn.turn_id))
    .at(-1)?.turn_id ?? null

  const followups = createFollowupApi({
    storage: { getItem: (key) => sessionStorage.getItem(key), setItem: (key, value) => sessionStorage.setItem(key, value) },
    route: (pane) => {
      const thread = routeThread(pane)
      const profile = connectionFor(pane)
      const runtime = profile === 'local' ? readiness.providerRuntimeId() : connections()?.connections.find((row) => row.profile_id === profile)?.runtime_id
      return JSON.stringify([paneOwningWorkspaceId(pane), profile, thread.runtime_id ?? null, runtime ?? null, thread.repository_id ?? 'primary', thread.repository_cwd ?? null])
    },
    staged: (pane, value) => {
      // The durable receipt now owns these uploads before the RPC can yield.
      setDraftFor(pane, '')
      const key = paneKey(pane.workspace_id, pane.pane_id)
      setDraftAttachments((prev) => ({ ...prev, [key]: (prev[key] ?? []).filter((image) => !value.images.some((owned) => owned.path === image.path)) }))
      persistComposerState()
      setComposerNonce((value) => value + 1)
    },
    discard: (images) => {
      for (const image of images) {
        if (!followups.ownsAttachment(image.path) && !Object.values(draftAttachments()).some((draft) => draft.some((item) => item.path === image.path))) {
          void deleteChatImage(image).catch(() => {})
        }
      }
    },
    activeTurn: activeFollowupTurn,
    kind: (pane) => followupKind(routeThread(pane).provider ?? pane.provider, routeThread(pane).harness),
    remote: (pane) => connectionFor(pane) !== 'local',
    rpc: paneRpc,
    busy: sending,
    notice: setNotice,
    id: () => mintId('web-followup-'),
    restore: (pane, text, images) => {
      const draft = draftFor(pane)
      setDraftFor(pane, draft ? `${draft}\n\n${text}` : text)
      const key = paneKey(pane.workspace_id, pane.pane_id)
      setDraftAttachments((prev) => ({ ...prev, [key]: [...(prev[key] ?? []), ...images] }))
      scheduleComposerCacheWrite()
      setComposerNonce((value) => value + 1)
    },
    start: async (pane, followup) => {
      const ws = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(pane))
      if (!ws || !pane.thread_id) throw new FollowupRejectedError('The follow-up workspace or thread is unavailable')
      if (!followupImagesSupported(pane, followup.images)) throw new FollowupRejectedError('The follow-up image route is unsupported')
      setSending(true)
      try {
        const thread = routeThread(pane)
        const remote = connectionFor(pane) !== 'local'
        const params = {
          turn_id: followup.next_turn_id, workspace_id: ws.workspace_id, local_thread_id: pane.thread_id,
          ...chatCwdTurnParams(thread, remote, ws.path),
          prompt: followup.text,
          image_paths: followup.images.map((image) => image.path),
          images: followup.images.map((image) => ({ path: image.path, mime: image.mime, byte_size: image.byte_size ?? 0 })),
          thread_title: thread.title, provider: thread.provider ?? pane.provider ?? 'codex',
          harness: thread.harness ?? 'local_cli',
          provider_thread_id: lastTurns().find((turn) => turn.turn_id === followup.turn_id)?.provider_thread_id ?? thread.provider_thread_id,
          model_ref: thread.model_ref ?? pane.model, reasoning_effort: thread.reasoning_effort ?? pane.reasoning_effort,
          opencode_reasoning_variant: thread.reasoning_variant ?? pane.reasoning_variant,
          fast_mode: (thread.fast_mode ?? (pane.fast_mode ? 'on' : 'off')) === 'on',
          access_mode: thread.access_mode ?? pane.access_mode,
        }
        const response = remote ? await paneRpc(pane, 'chat.turn.start', params) : await interactiveCall('chat.turn.start', params)
        if (response.error || response.ok === false) throw followupRpcError(response)
        if (!unwrapResult<{ turn_id?: string }>(response)?.turn_id) throw new Error('Follow-up acceptance was not confirmed')
        setLastTurns((turns) => [...turns.filter((turn) => turn.turn_id !== followup.next_turn_id), {
          turn_id: followup.next_turn_id, workspace_id: pane.workspace_id, local_thread_id: pane.thread_id,
          status: 'working', profile_id: connectionFor(pane), started_at_ms: Date.now(),
        }])
        tailActiveTurn(pane)
        void loadTranscript(pane)
      } finally {
        setSending(false)
      }
    },
  })

  const followupImagesSupported = (pane: LivePane, images: Attachment[]): boolean => {
    if (!images.length) return true
    const thread = routeThread(pane)
    if (connectionFor(pane) === 'local' && !thread.repository_cwd && (!thread.repository_id || thread.repository_id === 'primary')) return true
    setNotice('Images are not supported for remote or repository-routed chats. Your draft and attachments are kept.')
    return false
  }

  const submitFollowup = async (pane: LivePane, kind?: FollowupKind): Promise<boolean> => {
    if (pane.kind !== 'chat' || !pane.thread_id || isSubagentThreadId(pane.thread_id) ||
        sending() || uploadingAttachmentsFor(pane)) return false
    const text = draftFor(pane)
    const slash = parseSlashCommand(text)
    const bang = classifyBangCommand(text)
    if (slash.kind === 'local' || slash.kind === 'provider' || slash.kind === 'unknown' || bang.kind === 'shell') {
      setNotice('Slash commands and shell commands cannot be submitted as follow-ups.')
      return false
    }
    const images = [...attachmentsFor(pane)]
    if (!followupImagesSupported(pane, images)) return false
    return followups.submit(pane, slash.kind === 'literal' ? slash.text : bang.text, images, kind)
  }

  const sendDraft = async (pane = focusedChat()) => {
    const current = pane
    if (!current || current.kind !== 'chat') return
    const ws = workspaces().find((row) => row.workspace_id === paneOwningWorkspaceId(current))
    if (!ws) return
    if (isSubagentThreadId(current.thread_id)) return
    if (!current.thread_id) {
      setNotice('thread is not ready yet')
      return
    }
    const pending = followups.pendingFollowup(current)
    if (pending && pending.state !== 'sent_inline') {
      setNotice('Resolve the pending follow-up with Retry, Pull back, or Cancel before sending another message.')
      return
    }
    if (uploadingAttachmentsFor(current) || sending()) return
    const rawDraft = draftFor(current)
    const slash = parseSlashCommand(rawDraft)
    if (slash.kind === 'local' || slash.kind === 'provider' || slash.kind === 'unknown') {
      await submitSlashCommand(current, rawDraft)
      return
    }
    const bang = classifyBangCommand(rawDraft)
    if (bang.kind === 'shell') {
      setNotice('Composer shell mode is unavailable in the web app; no supported command-result RPC exists.')
      return
    }
    if (activeFollowupTurn(current) || paneWorking(current)) {
      await submitFollowup(current)
      return
    }
    const text = (slash.kind === 'literal' ? slash.text : bang.text).trim()
    const images = [...attachmentsFor(current)]
    if (!followupImagesSupported(current, images)) return
    if (!text && images.length === 0) return
    setSending(true)
    // Optimistic send: clear the store draft immediately. The textarea is
    // uncontrolled, so ChatPane also blanks the DOM node at click time;
    // waiting for turn.start on this large thread left the prompt visible
    // for seconds.
    const key = paneKey(current.workspace_id, current.pane_id)
    const local_message_id = mintId('local-user-')
    setDraftFor(current, '')
    setDraftAttachments((prev) => ({ ...prev, [key]: [] }))
    scheduleComposerCacheWrite()
    setTranscripts((prev) => ({
      ...prev,
      [key]: [
        ...(prev[key] ?? []),
        {
          message_id: local_message_id,
          role: 'user',
          author: 'You',
          body: text,
          images,
          created_at_ms: Date.now(),
        },
      ],
    }))
    const rollback = () => {
      setTranscripts((prev) => ({
        ...prev,
        [key]: (prev[key] ?? []).filter((row) => row.message_id !== local_message_id),
      }))
      // Only restore if the user has not started typing a new draft.
      if (!draftFor(current)) setDraftFor(current, text)
      if (attachmentsFor(current).length === 0) {
        setDraftAttachments((prev) => ({ ...prev, [key]: images }))
        scheduleComposerCacheWrite()
      }
    }
    try {
      await refreshConnections()
      if (!connections()) {
        rollback()
        setNotice(connectionError() ?? 'Connections unavailable')
        return
      }
      const profile = connectionFor(current)
      const remote = profile !== 'local'
      const connection = connections()!.connections.find((row) => row.profile_id === profile)
      if (remote && (!connection?.ready || !connection.runtime_id)) {
        rollback()
        setNotice(`${connection?.label ?? profile}: ${connection?.failure ?? connection?.phase ?? 'unavailable'}`)
        return
      }
      if (remote && images.length) {
        rollback()
        setNotice('Remote chat attachments are not supported by the web connection bridge yet. Your attachments are kept.')
        return
      }
      setNotice(null)
      // A model click persists asynchronously. Keep the optimistic submit
      // immediate, but read/start only after that queued write has landed so
      // a quick mobile tap cannot race the selected settings.
      const pending_settings = settingsUpdateQueues.get(key)
      if (pending_settings) await pending_settings
      const route = routeThread(current)
      if (route.runtime_id && remote && route.runtime_id !== connection!.runtime_id) throw new Error('This chat belongs to a different runtime')
      // A committed thread's pinned runtime_id is immutable in the store; a
      // local chat that already carries one must keep it or the upsert is
      // rejected with invalid_params.
      const route_patch = { profile_id: profile, runtime_id: remote ? connection!.runtime_id : route.runtime_id ?? null, repository_id: route.repository_id ?? 'primary', repository_cwd: route.repository_cwd ?? null }
      const saved_route = await upsertThreadMetadata(ws, current, route_patch)
      if (!saved_route || saved_route.error || saved_route.ok === false) throw new Error(saved_route?.error?.message ?? 'Could not save the chat connection')
      setThreadsByWorkspace((prev) => ({ ...prev, [ws.workspace_id]: (prev[ws.workspace_id] ?? []).map((row) => row.local_thread_id === current.thread_id ? { ...row, ...route_patch } : row) }))
      const thread = mergeThreadMetadata(routeThread(current), route_patch)
      // Opening GUI threads are not in the daemon yet. chat.turn.start creates
      // that row, so a missing catalog row must not roll the optimistic submit back.
      if (!thread.local_thread_id) {
        rollback()
        setNotice('thread is not on the daemon')
        return
      }
      const execution_thread = thread
      const stored_title = thread?.title ?? current.thread_title ?? 'New Chat'
      const fallback_prompt = text || (images.length > 0 ? 'Image' : '')
      const thread_title = isOpeningThread(thread, stored_title)
        ? makeThreadTitle(fallback_prompt)
        : stored_title
      const turn_id = mintId('web-turn-')
      const sent = await paneRpc(current, 'chat.turn.start', {
        turn_id,
        workspace_id: ws.workspace_id,
        local_thread_id: current.thread_id,
        ...chatCwdTurnParams(route_patch, remote, ws.path),
        prompt: text,
        image_paths: images.map((image) => image.path),
        images: images.map((image) => ({
          path: image.path,
          mime: image.mime,
          byte_size: image.byte_size ?? 0,
        })),
        thread_title,
        provider: thread?.provider ?? current.provider ?? 'codex',
        harness: thread?.harness ?? 'local_cli',
        model_ref: thread?.model_ref ?? current.model,
        reasoning_effort: thread?.reasoning_effort ?? current.reasoning_effort,
        opencode_reasoning_variant: thread?.reasoning_variant ?? current.reasoning_variant,
        fast_mode: (thread?.fast_mode ?? (current.fast_mode ? 'on' : 'off')) === 'on',
        provider_thread_id: execution_thread?.provider_thread_id,
        access_mode: thread?.access_mode ?? current.access_mode,
      })
      if (sent.error || sent.ok === false) {
        rollback()
        setNotice(sent.error?.message ?? 'send did not apply')
        return
      }
      if (remote) {
        const committed = await upsertThreadMetadata(ws, current, { ...route_patch, title: thread_title, committed: true })
        if (committed?.error || committed?.ok === false) setNotice('Remote turn started, but saving its local metadata failed.')
      }
      if (thread_title !== stored_title || remote) {
        setThreadsByWorkspace((prev) => ({
          ...prev,
          [ws.workspace_id]: (prev[ws.workspace_id] ?? []).map((row) =>
            row.local_thread_id === current.thread_id ? { ...row, title: thread_title, committed: true } : row,
          ),
        }))
        publishPanes(workspaces())
      }
      // Register the turn locally and start its streaming loop right away
      // instead of waiting for the projection poll to surface its record.
      setLastTurns((turns) => [
        ...turns,
        {
          turn_id,
          workspace_id: ws.workspace_id,
          local_thread_id: current.thread_id,
          status: 'working',
          profile_id: connectionFor(current),
          started_at_ms: Date.now(),
        },
      ])
      tailActiveTurn(current)
      // The optimistic user row plus the tail overlay cover the in-flight
      // turn. Reloading the committed transcript here raced the 1.5s poll
      // and re-parsed multi-megabyte threads on every send; commit reloads
      // once when the tail loop sees a terminal status.
      void refreshProjection({
        scope: 'selected',
        workspace_id: ws.workspace_id,
        enrich_chat_status: false,
      })
    } catch (err) {
      rollback()
      setNotice(err instanceof Error ? err.message : 'send failed')
    } finally {
      setSending(false)
    }
  }

  /// Dynamic provider model catalogs from the daemon's provider.models.list.
  /// Null while unfetched/unavailable; callers fall back to the static tables
  /// in lib/models.ts. Failures cache as unavailable for the page lifetime so
  /// an offline provider is probed once, not per picker open.
  const [providerCatalogs, setProviderCatalogs] = createSignal<Record<string, ModelOption[] | null>>({})
  const catalogRequested = new Set<string>()

  const providerModels = (provider: string | null | undefined): ModelOption[] | null => {
    if (!provider) return null
    return providerCatalogs()[provider] ?? null
  }

  const ensureProviderModels = (provider: string | null | undefined) => {
    const ws = workspace()
    if (!provider || !ws?.path || catalogRequested.has(provider)) return
    catalogRequested.add(provider)
    void (async () => {
      try {
        const raw = await client.call('provider.models.list', {
          provider,
          project_path: ws.path,
        })
        if (raw.error || raw.ok === false) return
        const result = unwrapResult<{ models?: DynamicModelRow[] }>(raw)
        const options = dynamicModelOptions(provider, result?.models ?? [])
        if (options.length === 0) return
        setProviderCatalogs((prev) => ({ ...prev, [provider]: options }))
      } catch {
        // Unreachable daemon/provider: keep the static fallback.
      }
    })()
  }

  const isFavoriteModel = (provider: string, model: string): boolean =>
    favoriteModels().some(
      (entry) => entry.provider === provider && entry.model === model,
    )

  const toggleFavoriteModel = (provider: string, model: string) => {
    const favorite = !isFavoriteModel(provider, model)
    const key = favoriteModelKey(provider, model)
    pendingFavoriteModels.set(key, favorite)
    setFavoriteModels((prev) => setFavoriteModelInList(prev, provider, model, favorite))
    setNotice(null)
    const update = favoriteModelUpdateQueue.then(async () => {
      const response = await interactiveCall('config.favoriteModel.set', {
        provider,
        model,
        favorite,
      })
      if (pendingFavoriteModels.get(key) === favorite) pendingFavoriteModels.delete(key)
      if (response.error || response.ok === false) {
        setNotice(response.error?.message ?? 'favorite change did not apply')
      }
      // Reconcile failures and desktop-side edits through the shared config
      // snapshot after this key's newest requested state has settled.
      void refreshProjection({ scope: 'selected', enrich_chat_status: false })
    })
    favoriteModelUpdateQueue = update.catch((err) => {
      if (pendingFavoriteModels.get(key) === favorite) pendingFavoriteModels.delete(key)
      setNotice(err instanceof Error ? err.message : 'favorite change failed')
      void refreshProjection({ scope: 'selected', enrich_chat_status: false })
    })
  }

  /// Persist model/effort/variant changes onto the daemon thread record.
  /// The daemon's chat.thread.upsert is a full metadata overwrite, so this
  /// merges the patch over the catalog row (never a full transcript get).
  /// The next chat.turn.start re-reads the thread, so the change applies to
  /// the next send — same contract as the desktop composer pickers.
  const settingsUpdateQueues = new Map<string, Promise<void>>()

  const persistThreadSettings = async (
    pane: LivePane,
    patch: {
      provider?: string
      model_ref?: string | null
      reasoning_effort?: string | null
      reasoning_variant?: string | null
      fast_mode?: string | null
      access_mode?: string | null
    },
  ) => {
    if (pane.kind !== 'chat' || !pane.thread_id) return
    setNotice(null)
    try {
      const loaded = routeThread(pane)
      const thread = loaded.local_thread_id ? loaded : openingThreadFromPane(pane)
      if (!thread.local_thread_id) {
        setNotice('thread is not on the daemon')
        return
      }
      const provider = patch.provider ?? thread.provider ?? pane.provider ?? 'codex'
      const provider_changed = provider !== (thread.provider ?? pane.provider ?? 'codex')
      const merged = {
        provider,
        model_ref: patch.model_ref !== undefined ? patch.model_ref : thread.model_ref ?? null,
        reasoning_effort:
          patch.reasoning_effort !== undefined ? patch.reasoning_effort : thread.reasoning_effort ?? null,
        reasoning_variant:
          patch.reasoning_variant !== undefined ? patch.reasoning_variant : thread.reasoning_variant ?? null,
        fast_mode:
          patch.fast_mode !== undefined ? patch.fast_mode : provider_changed ? 'off' : thread.fast_mode ?? 'off',
        access_mode: patch.access_mode !== undefined ? patch.access_mode : thread.access_mode ?? 'supervised',
      }
      const client_id = await ensureClientId()
      const saved = await interactiveCall('chat.thread.upsert', {
        mutation: {
          request_key: `web:chat.settings:${pane.thread_id}:${mintId('')}`,
          client_id,
        },
        workspace_id: pane.workspace_id,
        thread: {
          local_thread_id: pane.thread_id,
          title: thread.title ?? pane.thread_title ?? 'Chat',
          archived: thread.archived ?? false,
          last_activity_at: thread.last_activity_at ?? Date.now(),
          provider_thread_id: provider_changed ? null : thread.provider_thread_id ?? null,
          harness: thread.harness ?? 'local_cli',
          draft: thread.draft ?? '',
          profile_id: thread.profile_id,
          runtime_id: thread.runtime_id,
          repository_id: thread.repository_id,
          repository_cwd: thread.repository_cwd,
          committed: thread.committed,
          ...merged,
        },
      })
      if (saved.error || saved.ok === false) {
        setNotice(saved.error?.message ?? 'model change did not apply')
        void refreshProjection()
        return
      }
      rememberThreadSettings(pane.workspace_id, pane.thread_id, {
        reasoning_effort: merged.reasoning_effort,
        reasoning_variant: merged.reasoning_variant,
        fast_mode: merged.fast_mode,
        access_mode: merged.access_mode,
      })
      setThreadsByWorkspace((prev) => ({
        ...prev,
        [pane.workspace_id]: (prev[pane.workspace_id] ?? []).map((row) =>
          row.local_thread_id === pane.thread_id ? { ...row, ...merged } : row,
        ),
      }))
      void refreshProjection()
    } catch (err) {
      setNotice(err instanceof Error ? err.message : 'model change failed')
      void refreshProjection()
    }
  }

  /// Model, provider, and run-control clicks can happen faster than their
  /// durable round trips. Serialize per thread so every merge reads the row
  /// committed by the preceding click instead of restoring stale defaults.
  const updateThreadSettings = (
    pane: LivePane,
    patch: {
      provider?: string
      model_ref?: string | null
      reasoning_effort?: string | null
      reasoning_variant?: string | null
      fast_mode?: string | null
      access_mode?: string | null
    },
  ): Promise<void> => {
    if (slashCommandState(pane).pending) {
      setNotice('Wait for the slash command before changing chat settings.')
      return Promise.resolve()
    }
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const optimistic_patch: Partial<Thread> = {
      ...patch,
      ...(patch.provider && patch.provider !== pane.provider ? { provider_thread_id: null } : {}),
    }
    setThreadsByWorkspace((prev) => ({
      ...prev,
      [pane.workspace_id]: (prev[pane.workspace_id] ?? []).map((row) =>
        row.local_thread_id === pane.thread_id ? { ...row, ...optimistic_patch } : row,
      ),
    }))
    publishPanes(workspaces())
    const previous = settingsUpdateQueues.get(key) ?? Promise.resolve()
    const next = previous.catch(() => {}).then(() => persistThreadSettings(pane, patch))
    settingsUpdateQueues.set(key, next)
    void next.finally(() => {
      if (settingsUpdateQueues.get(key) === next) settingsUpdateQueues.delete(key)
    })
    return next
  }

  const createWorkspace = async (path: string): Promise<boolean> => {
    const trimmed_path = path.trim()
    if (!trimmed_path) {
      setNotice('enter a workspace path')
      return false
    }
    setNotice(null)
    try {
      const created = await interactiveCall('workspace.create', { path: trimmed_path })
      let workspace_id: string | undefined
      if (created.error || created.ok === false) {
        if (!methodUnavailable(created)) {
          setNotice(created.error?.message ?? 'could not add workspace')
          return false
        }
        workspace_id = linuxWorkspaceId(trimmed_path)
        const client_id = await ensureClientId()
        const saved = await interactiveCall('workspace.upsert', {
          mutation: {
            request_key: `web:workspace.add:${workspace_id}`,
            client_id,
          },
          workspace: {
            workspace_id,
            label: labelFromPath(trimmed_path),
            path: trimmed_path,
          },
        })
        if (saved.error || saved.ok === false) {
          setNotice(saved.error?.message ?? 'could not add workspace')
          return false
        }
      } else {
        const rows = workspacesFromLiveListing(created)
        workspace_id = rows?.find((item) => item.path === trimmed_path)?.workspace_id ?? rows?.at(-1)?.workspace_id
      }
      liveWorkspaces = null
      liveLayouts = {}
      if (workspace_id) setWorkspaceId(workspace_id)
      await refreshProjection({ workspace_id })
      if (workspace_id) selectWorkspace(workspace_id)
      setWorkspaceDialogOpen(false)
      return true
    } catch (err) {
      setNotice(err instanceof Error ? err.message : 'could not add workspace')
      return false
    }
  }

  const createHeadlessThread = async (current: Workspace, provider: string): Promise<number | null> => {
    const client_id = await ensureClientId()
    const local_thread_id = mintId('web-thread-')
    // The daemon rejects a partial route: a profile_id must travel with its
    // repository_id, or chat.thread.upsert fails with invalid_params.
    const profile_id = connections()?.defaults.find((row) => row.workspace_id === current.workspace_id)?.profile_id ?? 'local'
    const repository_id = 'primary'
    const opened = await requestNewThread(interactiveCall, async () => ({
      request_key: `web:chat.open:${local_thread_id}`,
      client_id,
    }), current, {
      local_thread_id,
      title: 'New Chat',
      committed: false,
      profile_id,
      repository_id,
      provider,
      harness: 'local_cli',
      last_activity_at: Date.now(),
    })
    if (opened.error || opened.ok === false) {
      setNotice(opened.error?.message ?? 'could not open chat')
      return null
    }
    localThreadIds.add(local_thread_id)
    const created: Thread = {
      local_thread_id,
      title: 'New Chat',
      committed: false,
      profile_id,
      repository_id,
      provider,
      last_activity_at: Date.now(),
    }
    setThreadsByWorkspace((prev) => ({
      ...prev,
      [current.workspace_id]: [created, ...(prev[current.workspace_id] ?? [])],
    }))
    return stablePaneId('chat', local_thread_id)
  }

  const newThread = async (workspace_id?: string) => {
    await refreshConnections()
    if (!connections()) { setNotice(connectionError() ?? 'Connections unavailable'); return }
    pendingLastChatPane = null
    const current = workspace_id
      ? workspaces().find((item) => item.workspace_id === workspace_id)
      : workspace()
    if (!current) return
    const provider =
      (current.workspace_id === workspace()?.workspace_id ? focusedChat()?.provider : undefined) ??
      (panesByWorkspace()[current.workspace_id] ?? []).find((pane) => pane.kind === 'chat')?.provider ??
      current.provider ??
      'codex'
    setNotice(null)
    const focused_id = await createHeadlessThread(current, provider)
    if (focused_id == null) return
    setWorkspaceId(current.workspace_id)
    setFocusedPaneId(focused_id)
    // Instant transition: the optimistic thread row above already projects a
    // pane through localThreadIds, so publish and focus it now. The live
    // pane/layout reconciliation lands in the background and rebinds the
    // pane to the desktop layout entry once it appears.
    publishPanes(workspaces())
    const focused = (panesByWorkspace()[current.workspace_id] ?? []).find(
      (pane) => pane.pane_id === focused_id,
    )
    if (focused) writeLastChatPaneLocation(focused)
    setComposerNonce((value) => value + 1)
    void refreshProjection({ workspace_id: current.workspace_id })
  }

  const newTerminal = async (workspace_id?: string) => {
    const ws = workspace_id
      ? workspaces().find((item) => item.workspace_id === workspace_id)
      : workspace()
    if (!ws) return
    const session_id = mintId('web-sess-')
    const opened = await requestTerminalOpen(interactiveCall, ws, session_id)
    if (opened.response.error || opened.response.ok === false) {
      setNotice(opened.response.error?.message ?? 'could not create session')
      return
    }
    if (opened.native) {
      setWorkspaceId(ws.workspace_id)
      const layout = layoutFromLivePanes(opened.response)
      if (layout) {
        liveLayouts = { ...liveLayouts, [ws.workspace_id]: layout }
        // Let the desktop-focused pane from the terminal.open response win
        // instead of retaining the web pane that was focused before creation.
        setFocusedPaneId(null)
        publishPanes(workspaces())
      }
      void refreshProjection({ workspace_id: ws.workspace_id })
      return
    }
    // Instant transition: project the created daemon session as a live pane
    // now; the background snapshot refresh confirms (or corrects) it.
    lastSessions = [
      ...lastSessions,
      {
        session_id,
        workspace_id: ws.workspace_id,
        workspace_path: ws.path,
        cwd: ws.path,
        label: 'Terminal',
        running: true,
      },
    ]
    setWorkspaceId(ws.workspace_id)
    setFocusedPaneId(stablePaneId('term', session_id))
    publishPanes(workspaces())
    void refreshProjection({ workspace_id: ws.workspace_id })
  }

  const historyApi = createHistoryApi({
    call: interactiveCall,
    mutation: async () => ({ client_id: await ensureClientId(), request_key: mintId('web:history:') }),
    notice: setNotice,
    threadChanged: (workspaceId, thread, revision) => {
      const key = `${workspaceId}\u0000${thread.local_thread_id}`
      if (thread.archived) {
        localThreadIds.delete(thread.local_thread_id)
        archivedHistoryThreads.set(key, revision)
      } else {
        archivedHistoryThreads.delete(key)
        localThreadIds.add(thread.local_thread_id)
        setWorkspaceId(workspaceId)
        setFocusedPaneId(stablePaneId('chat', thread.local_thread_id))
      }
      setThreadsByWorkspace((previous) => ({
        ...previous,
        [workspaceId]: [
          { title: 'Chat', ...previous[workspaceId]?.find((row) => row.local_thread_id === thread.local_thread_id), ...thread },
          ...(previous[workspaceId] ?? []).filter((row) => row.local_thread_id !== thread.local_thread_id),
        ],
      }))
      publishPanes(workspaces())
      if (!thread.archived) {
        const pane = (panesByWorkspace()[workspaceId] ?? []).find((row) => row.thread_id === thread.local_thread_id)
        if (pane) {
          focusPane(pane)
          ensureTranscript(pane)
        }
      }
      void refreshProjection({ workspace_id: workspaceId })
    },
    workspaceReopened: (reopened) => {
      setWorkspaces((previous) => [...previous.filter((row) => row.workspace_id !== reopened.workspace_id), reopened])
      setWorkspaceId(reopened.workspace_id)
      publishPanes(workspaces())
      void refreshProjection({ workspace_id: reopened.workspace_id })
    },
  })

  const callSucceeded = (response: RpcEnvelope, fallback: string): boolean => {
    if (!(response.error || response.ok === false)) return true
    setNotice(response.error?.message ?? fallback)
    return false
  }

  const workspaceCommand = (current: Workspace, patch: { label: string } | { archived: true }) =>
    requestWorkspaceCommand(interactiveCall, async () => ({
      client_id: await ensureClientId(),
      request_key: `web:workspace.context:${current.workspace_id}:${mintId('')}`,
    }), current, patch)

  const upsertThreadMetadata = async (
    current_workspace: Workspace,
    pane: LivePane,
    patch: Partial<Thread>,
  ) => {
    if (!pane.thread_id) return null
    const existing = routeThread(pane)
    if (!existing.local_thread_id) return null
    const thread = mergeThreadMetadata(existing, patch)
    const client_id = await ensureClientId()
    return interactiveCall('chat.thread.upsert', {
      mutation: {
        request_key: `web:thread.context:${pane.thread_id}:${mintId('')}`,
        client_id,
      },
      workspace_id: current_workspace.workspace_id,
      thread,
    })
  }

  const closePane = async (target?: LivePane) => {
    const pane = target ?? focusedPane()
    const unavailable = sidebarActionUnavailableReason('pane-close', pane ?? undefined)
    if (unavailable) { setNotice(unavailable); return }
    const ws = pane
      ? workspaces().find((item) => item.workspace_id === pane.workspace_id)
      : workspace()
    if (!pane || !ws) {
      // Prefix x / Close pane on an empty workspace archives it, matching
      // desktop and tmux. A targeted close (header/menu) no-ops.
      if (target != null) return
      const current = workspace()
      if (!current || openPanes().length !== 0) return
      void runSidebarContextAction({ action: 'workspace-close', workspace: current })
      return
    }
    // Optimistic close: drop the pane from every local projection source so
    // the strip updates immediately. The scoped refresh after the close RPC
    // reconciles — and restores the pane if the close was rejected.
    if (pane.kind === 'chat' && pane.thread_id) localThreadIds.delete(pane.thread_id)
    const layout = liveLayouts[ws.workspace_id]
    if (pane.native_pane_id != null && layout?.panes) {
      liveLayouts = {
        ...liveLayouts,
        [ws.workspace_id]: {
          ...layout,
          panes: layout.panes.filter((row) => row.id !== pane.native_pane_id),
        },
      }
    }
    if (pane.kind === 'terminal' && pane.session_id) {
      lastSessions = lastSessions.filter((row) => sessionKey(row) !== pane.session_id)
    }
    if (maximizedPaneId() === pane.pane_id) setMaximizedPaneId(null)
    publishPanes(workspaces())
    // A web-local chat pane has nothing to close on the daemon or desktop;
    // removing it from the projection above is the whole operation.
    if (pane.kind === 'chat' && pane.native_pane_id == null && !pane.session_id) return
    const response = await requestPaneClose(interactiveCall, ws.workspace_id, pane)
    callSucceeded(response, 'could not close pane')
    // Scoped: only this pane's workspace changed (the target can live in the
    // cross-workspace ACTIVE list, so scope to it rather than the selection).
    await refreshProjection({ workspace_id: ws.workspace_id })
  }

  // Toggle zoom for a specific pane (header/menu) or the focused pane
  // (Alt+Z). Web zoom is local because this client renders its own strip.
  const maximizePane = async (target?: LivePane) => {
    const pane = target ?? focusedPane()
    if (!pane) return
    // Decide before focusPane: zoom-follows-focus would otherwise mark the
    // target as already zoomed and turn every icon click into an unzoom.
    const unzoom = maximizedPaneId() === pane.pane_id
    if (target) focusPane(target)
    setMaximizedPaneId(unzoom ? null : pane.pane_id)
  }

  const openSubagent = async (pane: LivePane, message: Message) => {
    const current_workspace = workspaces().find((item) => item.workspace_id === paneOwningWorkspaceId(pane))
    if (!current_workspace) return
    if (pane.native_pane_id == null) {
      setNotice('Opening a subagent pane requires the desktop runtime.')
      return
    }
    setNotice(null)
    const response = await interactiveCall('chat.open_subagent', {
      workspace_id: current_workspace.workspace_id,
      parent_local_thread_id: pane.thread_id,
      tool_call_id: message.tool_call_id ?? undefined,
      message_id: message.message_id,
      axis: 'vertical',
      focus: true,
      target_pane_id: pane.native_pane_id,
    })
    if (callSucceeded(response, 'could not open subagent')) {
      await refreshProjection({ workspace_id: current_workspace.workspace_id })
    }
  }

  const splitFocusedPane = async (_kind: 'chat' | 'terminal', _axis: 'vertical' | 'horizontal') => {
    setNotice(sidebarActionUnavailableReason('pane-split-chat-right'))
  }

  const resizePaneSplit = async (
    first_pane_id: number,
    second_pane_id: number,
    axis: 'vertical' | 'horizontal',
    ratio: number,
  ) => {
    const first = openPanes().find((pane) => pane.pane_id === first_pane_id)
    const second = openPanes().find((pane) => pane.pane_id === second_pane_id)
    const current_workspace = first
      ? workspaces().find((item) => item.workspace_id === first.workspace_id)
      : workspace()
    if (first?.native_pane_id == null || second?.native_pane_id == null || !current_workspace) return
    const response = await interactiveCall('pane.resize', {
      workspace: current_workspace.workspace_id,
      pane: first.native_pane_id,
      first: first.native_pane_id,
      second: second.native_pane_id,
      axis,
      ratio: Math.min(0.78, Math.max(0.22, ratio)),
    })
    if (callSucceeded(response, 'could not resize pane split')) {
      await refreshProjection({ workspace_id: current_workspace.workspace_id })
    }
  }

  const runSidebarContextAction = async (request: SidebarContextActionRequest) => {
    const { action, pane, value } = request
    const unavailable = sidebarActionUnavailableReason(action, pane)
    if (unavailable) { setNotice(unavailable); return }
    let { workspace: current_workspace } = request
    if (pane && (action.startsWith('thread-') || action.startsWith('pane-'))) {
      current_workspace = workspaces().find((item) => item.workspace_id === paneOwningWorkspaceId(pane))
        ?? current_workspace
    }
    setNotice(null)
    try {
      switch (action) {
        case 'workspace-new-chat':
          await newThread(current_workspace.workspace_id)
          return
        case 'workspace-open-terminal':
          await newTerminal(current_workspace.workspace_id)
          return
        case 'workspace-rename': {
          const label = value?.trim()
          if (!label) return
          const response = await workspaceCommand(current_workspace, { label })
          if (callSucceeded(response, 'could not rename workspace')) {
            setWorkspaces((prev) => prev.map((row) =>
              row.workspace_id === current_workspace.workspace_id ? { ...row, label } : row,
            ))
            liveWorkspaces = null
            await refreshProjection()
          }
          return
        }
        case 'workspace-close': {
          const response = await workspaceCommand(current_workspace, { archived: true })
          if (callSucceeded(response, 'could not close workspace')) {
            const closing_current = workspaceId() === current_workspace.workspace_id
            liveWorkspaces = null
            setWorkspaces((prev) => prev.filter((row) => row.workspace_id !== current_workspace.workspace_id))
            if (closing_current) {
              const next = workspaces()[0]
              setWorkspaceId(next?.workspace_id ?? null)
              setFocusedPaneId(null)
            }
            await refreshProjection()
          }
          return
        }
        case 'thread-rename': {
          const title = value?.trim()
          if (!pane || !title) return
          const response = await upsertThreadMetadata(current_workspace, pane, { title })
          if (!response || !callSucceeded(response, 'could not rename chat')) return
          setThreadsByWorkspace((prev) => ({
            ...prev,
            [current_workspace.workspace_id]: (prev[current_workspace.workspace_id] ?? []).map((thread) =>
              thread.local_thread_id === pane.thread_id ? { ...thread, title } : thread,
            ),
          }))
          publishPanes(workspaces())
          await refreshProjection({ workspace_id: current_workspace.workspace_id })
          return
        }
        case 'thread-sync': {
          if (!pane) { setNotice('Focus a chat first.'); return }
          const response = await requestSidebarThreadSync(
            interactiveCall, paneOwningWorkspaceId(pane), routeThread(pane), paneWorking(pane),
          )
          if (callSucceeded(response, 'Could not sync thread')) {
            await loadTranscript(pane)
            await refreshProjection({ workspace_id: paneOwningWorkspaceId(pane) })
          }
          return
        }
        case 'thread-archive':
          if (pane) await archiveCommand(pane, paneOwningWorkspaceId, historyApi.archiveThread)
          return
        case 'pane-zoom':
          if (pane) await maximizePane(pane)
          return
        case 'pane-close':
          if (pane) await closePane(pane)
          return
      }
    } catch (err) {
      setNotice(err instanceof Error ? err.message : 'sidebar action failed')
    }
  }

  const selectPaneAt = (index: number, list: LivePane[] = openPanes()) => {
    const pane = list[index]
    if (pane) focusPane(pane)
  }

  const stepPane = (delta: number) => {
    const panes = openPanes()
    if (panes.length === 0) return
    const current = panes.findIndex((pane) => pane.pane_id === focusedPaneId())
    const next = (current + delta + panes.length) % panes.length
    focusPane(panes[next]!)
  }

  const stepPaneDirection = (direction: 'left' | 'right' | 'up' | 'down') => {
    const current = focusedPaneId()
    if (current == null) return
    const next_id = adjacentPaneInGroups(paneGroups(), current, direction)
    const next = openPanes().find((pane) => pane.pane_id === next_id)
    if (next) focusPane(next)
  }

  const stepWorkspace = (delta: number) => {
    const list = workspaces()
    if (list.length === 0) return
    const current = list.findIndex((item) => item.workspace_id === workspace()?.workspace_id)
    const next = list[(current + delta + list.length) % list.length]
    if (next) selectWorkspace(next.workspace_id)
  }

  const dispatchAction = (action: KeyAction) => {
    if (typeof action === 'object') {
      if (action.kind === 'pane_select') selectPaneAt(action.index)
      if (action.kind === 'workspace_select') {
        const next = workspaces()[action.index]
        if (next) selectWorkspace(next.workspace_id)
      }
      if (action.kind === 'active_select') selectPaneAt(action.index, activePanes())
      return
    }
    switch (action) {
      case 'command_palette':
        setPaletteOpen(true)
        break
      case 'toggle_sidebar':
      case 'toggle_sidebar_hidden':
        if (window.matchMedia('(min-width: 1024px)').matches) setSidebarCollapsed((value) => !value)
        else setDrawerOpen((open) => !open)
        break
      case 'new_thread':
        void newThread()
        break
      case 'new_terminal':
        void newTerminal()
        break
      case 'close_pane':
        void closePane()
        break
      case 'focus_prompt':
        requestComposerFocus()
        break
      case 'workspace_previous':
        stepWorkspace(-1)
        break
      case 'workspace_next':
        stepWorkspace(1)
        break
      case 'pane_previous':
        stepPane(-1)
        break
      case 'pane_next':
        stepPane(1)
        break
      case 'focus_left':
        stepPaneDirection('left')
        break
      case 'focus_right':
        stepPaneDirection('right')
        break
      case 'focus_up':
        stepPaneDirection('up')
        break
      case 'focus_down':
        stepPaneDirection('down')
        break
      case 'maximize':
        void maximizePane()
        break
      case 'settings':
        setSettingsOpen(true)
        break
      case 'escape':
        setPaletteOpen(false)
        setSettingsOpen(false)
        setDrawerOpen(false)
        break
    }
  }

  const dispatchPrefixTarget = (target: PrefixTarget) => {
    if ('command' in target) {
      setNotice(target.in
        ? 'Custom prefix pane commands run from the desktop app only.'
        : 'Custom prefix shell commands run from the desktop app only.')
      return
    }
    const action = target.action
    const ordinal = /^workspace\.(pane_select|active_select|select)\.(\d+)$/.exec(action)
    if (ordinal) {
      const index = Number(ordinal[2]) - 1
      if (ordinal[1] === 'select') {
        const next = workspaces()[index]
        if (next) selectWorkspace(next.workspace_id)
      } else selectPaneAt(index, ordinal[1] === 'active_select' ? activePanes() : openPanes())
      return
    }
    const simple: Partial<Record<string, KeyAction>> = {
      command_palette: 'command_palette', new_thread: 'new_thread', new_terminal: 'new_terminal',
      'workspace.add_tab': 'new_thread', 'workspace.add_tab_terminal': 'new_terminal',
      sidebar: 'toggle_sidebar',
      sidebar_hidden: 'toggle_sidebar_hidden', 'workspace.close': 'close_pane',
      'workspace.toggle_maximize': 'maximize', 'workspace.focus_prompt': 'focus_prompt',
      'workspace.previous': 'workspace_previous', 'workspace.next': 'workspace_next',
      'workspace.active_previous': 'pane_previous', 'workspace.active_next': 'pane_next',
      'workspace.pane_previous': 'pane_previous', 'workspace.pane_next': 'pane_next',
      'workspace.focus_left': 'focus_left', 'workspace.focus_right': 'focus_right',
      'workspace.focus_up': 'focus_up', 'workspace.focus_down': 'focus_down',
    }
    if (simple[action]) {
      dispatchAction(simple[action]!)
      return
    }
    if (action === 'refresh') {
      window.location.reload()
      return
    }
    if (action === 'workspace.close_current') {
      const current = workspace()
      if (current) void runSidebarContextAction({ action: 'workspace-close', workspace: current })
      return
    }
    const split = /^workspace\.split_(chat|terminal)_(vertical|horizontal)$/.exec(action)
    if (split) {
      void splitFocusedPane(split[1] as 'chat' | 'terminal', split[2] as 'vertical' | 'horizontal')
      return
    }
    const dynamic_split = /^workspace\.split_(default|alternate)_(vertical|horizontal)$/.exec(action)
    if (dynamic_split) {
      const configured = uiConfig().workspace_split_default_pane
      const kind = dynamic_split[1] === 'default' ? configured : configured === 'chat' ? 'terminal' : 'chat'
      void splitFocusedPane(kind, dynamic_split[2] as 'vertical' | 'horizontal')
      return
    }
    const move = /^workspace\.move_(left|right|up|down)$/.exec(action)
    const pane = focusedPane()
    const current = pane
      ? workspaces().find((item) => item.workspace_id === pane.workspace_id)
      : workspace()
    if (move && pane?.native_pane_id != null && current) {
      void interactiveCall('pane.move', {
        workspace: current.workspace_id,
        pane: pane.native_pane_id,
        direction: move[1],
      }).then(() => refreshProjection({ workspace_id: current.workspace_id }))
      return
    }
    const paletteCommands: Record<string, string> = {
      browser: 'pane.browser', 'terminal.toggle': 'pane.terminal',
      'workspace.toggle_quick_pane': 'pane.quick_toggle', 'chat.model_picker': 'thread.choose_model',
      'chat.run_config': 'thread.run_config', open: 'workspace.add', 'workspace.add': 'workspace.add', open_editor: 'workspace.open_editor',
    }
    const command = paletteCommands[action]
    void runCommand(command ?? action)
  }

  const sendPrefix = (event: KeyboardEvent) => {
    const pane = focusedPane()
    if (!pane || pane.kind !== 'terminal') return
    if (pane.session_id && event.key.length === 1) {
      const code = event.ctrlKey ? event.key.toLowerCase().charCodeAt(0) - 96 : 0
      const bytes = code >= 1 && code <= 26 ? String.fromCharCode(code) : `${event.altKey ? '\x1b' : ''}${event.key}`
      void writePane(client, pane.workspace_id, pane.pane_id, bytes, pane.session_id)
    } else if (pane.native_pane_id != null) {
      void client.call('terminal.key', {
        workspace_id: pane.workspace_id,
        pane: pane.native_pane_id,
        key: event.key.toLowerCase(),
        ctrl: event.ctrlKey,
        alt: event.altKey,
        shift: event.shiftKey,
        super: event.metaKey,
      })
    }
  }

  const isPrefixKey = (event: KeyboardEvent) =>
    keybindConfig().prefix.enabled && keybindConfig().prefix.keys.some((key) => acceleratorMatches(key, event))

  const shouldHandleKey = (event: KeyboardEvent): boolean => {
    if (prefixMode()) return true
    return isPrefixKey(event) || matchKeyAction(event, keybindConfig()) != null
  }

  const handleKey = (event: KeyboardEvent) => {
    const mode = prefixMode()
    if (mode) {
      event.preventDefault()
      event.stopPropagation()
      if (['Control', 'Shift', 'Alt', 'Meta'].includes(event.key)) return
      if (event.key === 'Escape') {
        setPrefixMode(null)
        setPrefixHelpVisible(false)
        return
      }
      if (isPrefixKey(event)) {
        if (mode === 'armed') sendPrefix(event)
        setPrefixMode(mode === 'navigate' ? 'armed' : null)
        setPrefixHelpVisible(false)
        return
      }
      const table = mode === 'navigate' ? keybindConfig().prefix.navigate : keybindConfig().prefix.bindings
      const binding = findPrefixBinding(table, event)
      if (!binding) {
        if (mode === 'armed') {
          setPrefixMode(null)
          setPrefixHelpVisible(false)
        }
        return
      }
      if ('action' in binding.target && binding.target.action === 'prefix.keybinds') {
        setPrefixHelpVisible((visible) => !visible)
        return
      }
      if ('action' in binding.target && binding.target.action === 'prefix.navigate') {
        setPrefixMode('navigate')
        setPrefixHelpVisible(false)
        return
      }
      setPrefixMode(null)
      setPrefixHelpVisible(false)
      dispatchPrefixTarget(binding.target)
      return
    }
    if (isPrefixKey(event)) {
      event.preventDefault()
      event.stopPropagation()
      setPrefixMode('armed')
      setPrefixHelpVisible(false)
      return
    }
    const action = matchKeyAction(event, keybindConfig())
    if (!action) return
    event.preventDefault()
    event.stopPropagation()
    dispatchAction(action)
  }

  const runCommand = async (id: string, workspace_id?: string) => {
    const current = workspace_id
      ? workspaces().find((row) => row.workspace_id === workspace_id)
      : workspace()
    const pane = focusedPane()
    const openPicker = (command: ChatPickerCommand) => {
      if (!openChatCommandPicker(pane!, command)) setNotice('The chat picker is not mounted. Open the chat and try again.')
    }
    const rename = async (chat: boolean) => {
      const value = window.prompt(chat ? 'Chat title' : 'Workspace name', chat ? paneTitle(pane!) : current!.label)
      if (value == null) return
      if (!value.trim()) { setNotice('Enter a non-empty name.'); return }
      await runSidebarContextAction({
        action: chat ? 'thread-rename' : 'workspace-rename', workspace: current!,
        ...(chat ? { pane: pane! } : {}), value,
      })
    }
    await dispatchWebCommand(id, {
      workspace: current, pane, notice: setNotice,
      accepted: () => setPaletteOpen(false),
      handlers: {
        'thread.new': () => newThread(current!.workspace_id),
        'thread.rename_current': () => rename(true),
        'thread.choose_model': () => openPicker('model'),
        'thread.run_config': () => openPicker('run_config'),
        'thread.archive_current': () => archiveCommand(pane!, paneOwningWorkspaceId, historyApi.archiveThread),
        'pane.terminal': () => newTerminal(current!.workspace_id),
        'pane.close': () => closePane(pane!),
        'pane.zoom': () => maximizePane(pane!),
        'pane.previous': () => stepPane(-1),
        'pane.next': () => stepPane(1),
        'pane.focus_left': () => stepPaneDirection('left'),
        'pane.focus_right': () => stepPaneDirection('right'),
        'pane.focus_up': () => stepPaneDirection('up'),
        'pane.focus_down': () => stepPaneDirection('down'),
        'pane.focus_prompt': requestComposerFocus,
        'workspace.add': () => setWorkspaceDialogOpen(true),
        'workspace.rename': () => rename(false),
        'workspace.close': () => runSidebarContextAction({ action: 'workspace-close', workspace: current! }),
        'workspace.previous': () => stepWorkspace(-1),
        'workspace.next': () => stepWorkspace(1),
        'app.settings': () => setSettingsOpen(true),
        'app.sidebar': () => dispatchAction('toggle_sidebar'),
      },
    })
  }

  const start = () => {
    watchNotifications({ panes: panesByWorkspace, workspaces, focused: focusedPane, turns: lastTurns, approval: pendingApproval, focus: focusPane })
    const removeClientListener = client.onEvent(onEvent)
    client.connect()
    const media = window.matchMedia('(max-width: 1023px)')
    const syncCompact = () => setCompact(media.matches)
    syncCompact()
    media.addEventListener('change', syncCompact)
    let backgrounded = document.visibilityState === 'hidden'
    let foregroundRecoveryRunning = false
    const recoverForeground = () => {
      if (document.visibilityState === 'hidden' || foregroundRecoveryRunning) return
      foregroundRecoveryRunning = true
      setConnected(false)
      client.reconnect()
      void refreshProjection({
        scope: 'selected',
        workspace_id: workspaceId() ?? pendingLastChatPane?.workspace_id ?? undefined,
        enrich_chat_status: false,
      })
        .then(() => refreshTranscripts())
        .catch(() => {})
        .finally(() => {
          setConnected(client.connected)
          foregroundRecoveryRunning = false
        })
    }
    const markBackgrounded = () => {
      backgrounded = true
      persistComposerState()
    }
    const resumeFromBackground = () => {
      if (!backgrounded) return
      backgrounded = false
      recoverForeground()
    }
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'hidden') markBackgrounded()
      else resumeFromBackground()
    }
    const handleFreeze = () => {
      markBackgrounded()
      client.disconnect()
      setConnected(false)
    }
    const handlePageHide = (event: PageTransitionEvent) => {
      markBackgrounded()
      // A page kept in the back/forward cache must release its live socket.
      if (event.persisted) {
        client.disconnect()
        setConnected(false)
      }
    }
    const handlePageShow = (event: PageTransitionEvent) => {
      if (event.persisted) backgrounded = true
      resumeFromBackground()
    }
    document.addEventListener('visibilitychange', handleVisibilityChange)
    document.addEventListener('freeze', handleFreeze)
    document.addEventListener('resume', resumeFromBackground)
    window.addEventListener('pagehide', handlePageHide)
    window.addEventListener('pageshow', handlePageShow)
    window.addEventListener('online', recoverForeground)
    void refreshConnections()
    const connectionTick = window.setInterval(() => { void refreshConnections() }, 5000)
    const tick = window.setInterval(() => setConnected(client.connected), 1000)
    const transcriptsTick = window.setInterval(() => {
      if (client.connected) void refreshTranscripts()
    }, 1500)
    // Desktop pane opens/closes do not emit daemon change events, so the live
    // pane mirror needs its own cadence.
    const projectionTick = window.setInterval(() => {
      if (client.connected) void refreshProjection()
    }, 4000)
    const initial_projection = restoreLastChatOnStartup
      ? restoreInitialProjection()
      : refreshProjection()
    void initial_projection
      .catch(() => {})
      .finally(() => {
        // Pane identity/layout is ready. Reveal it now; the potentially large
        // transcript continues loading without holding the first useful paint.
        setInitialViewReady(true)
        void refreshTranscripts()
        if (restoreLastChatOnStartup) void refreshProjection({ scope: 'selected' })
      })
    onCleanup(() => {
      window.clearInterval(connectionTick)
      persistComposerState()
      window.clearInterval(tick)
      window.clearInterval(transcriptsTick)
      window.clearInterval(projectionTick)
      media.removeEventListener('change', syncCompact)
      document.removeEventListener('visibilitychange', handleVisibilityChange)
      document.removeEventListener('freeze', handleFreeze)
      document.removeEventListener('resume', resumeFromBackground)
      window.removeEventListener('pagehide', handlePageHide)
      window.removeEventListener('pageshow', handlePageShow)
      window.removeEventListener('online', recoverForeground)
      removeClientListener()
      client.disconnect()
    })
  }

  return {
    connections, connectionError, refreshConnections, connectionFor, setChatConnection, newThread,
    listChatCwdChoices: cwdApi.listChatCwdChoices,
    chatCwdChoices: (pane: LivePane) => cwdApi.chatCwdChoices(cwdKey(pane)),
    chatCwdIsLocked, setChatCwd,
    usageFor: (pane: LivePane) => latestPaneUsage(messagesFor(pane), slashCommandState(pane).result),
    providerReadiness, recheckProviderReadiness, chatRuntimeBlocker,
    ...historyApi,
    listSlashCommands: composerCommands.listSlashCommands,
    searchFiles: composerCommands.searchFiles,
    cancelFileSearch: composerCommands.cancelFileSearch,
    submitSlashCommand,
    slashCommandState,
    groupHistory,
    owningWorkspaceId: paneOwningWorkspaceId,
    inheritsConnection: (pane: LivePane) => !routeThread(pane).profile_id && !routeThread(pane).committed && !routeThread(pane).provider_thread_id,
    client,
    source,
    connected,
    initialViewReady,
    workspaces,
    workspace,
    workspaceId,
    openPanes,
    paneGroups,
    visiblePanes,
    canvasLayout,
    activePanes,
    focusedPane,
    focusedPaneId,
    focusedChat,
    maximizedPaneId,
    maximizePane,
    resizePaneSplit,
    paletteOpen,
    setPaletteOpen,
    settingsOpen,
    setSettingsOpen,
    workspaceDialogOpen,
    setWorkspaceDialogOpen,
    drawerOpen,
    setDrawerOpen,
    sidebarCollapsed,
    setSidebarCollapsed,
    sending,
    notice,
    setNotice,
    composerNonce,
    composerFocusExplicit,
    compact,
    uiConfig,
    keybindConfig,
    prefixMode,
    prefixHelpVisible,
    favoriteModels,
    isFavoriteModel,
    toggleFavoriteModel,
    draftFor,
    setDraftFor,
    beginDiffComment,
    attachmentsFor,
    uploadingAttachmentsFor,
    attachFiles,
    removeAttachment,
    messagesFor, transcriptState, loadOlderTranscript, retryTranscript,
    ensureTranscript,
    selectWorkspace,
    focusPane,
    takeInstantFocus,
    sendDraft,
    submitFollowup,
    followupKindFor: (pane: LivePane) => followupKind(routeThread(pane).provider ?? pane.provider, routeThread(pane).harness),
    pendingFollowup: followups.pendingFollowup,
    pendingFollowupHint: followups.pendingFollowupHint,
    pullBackFollowup: followups.pullBackFollowup,
    cancelFollowup: followups.cancelFollowup,
    retryFollowup: followups.retryFollowup,
    stopTurn,
    pendingApproval,
    resolveApproval,
    paneWorking,
    updateThreadSettings,
    createWorkspace,
    providerModels,
    ensureProviderModels,
    runSidebarContextAction,
    runCommand,
    shouldHandleKey,
    handleKey,
    start,
    paneTitle,
    openSubagent,
  }
}

export const store = createRoot(createAppStore)
export type AppStore = typeof store

// Debug handle for driving/inspecting the live store from the console.
if (typeof window !== 'undefined') {
  ;(window as unknown as { __verde_store?: AppStore }).__verde_store = store
}

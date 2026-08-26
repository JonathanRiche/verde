import { createMemo, createRoot, createSignal, onCleanup } from 'solid-js'

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
import { linuxWorkspaceId } from './wyhash'
import { DEFAULT_UI_CONFIG, parseUiConfig, type UiConfig } from './ui_config'
import {
  adjacentPaneInGroups,
  paneIsActive,
  paneKey,
  paneTitle,
  parseLayoutNode,
  synthesizeSplit,
  workspacePaneGroups,
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

interface SnapshotTurn {
  turn_id?: string
  workspace_id?: string
  local_thread_id?: string
  status?: string
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
  | 'workspace-herdr-handoff-remote'
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
  return thread?.committed === false || isPlaceholderThreadTitle(title)
}

function methodUnavailable(response: { error?: { code: string } }): boolean {
  const code = response.error?.code
  return code === 'unknown_method' || code === 'method_not_found' || code === 'capability_unavailable'
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
  workspace_id: string,
  pane: Pick<LivePane, 'kind' | 'native_pane_id' | 'session_id'>,
): Promise<RpcEnvelope> {
  if (pane.native_pane_id != null) {
    return call('pane.close', { workspace: workspace_id, pane: pane.native_pane_id })
  }
  if (pane.kind === 'terminal' && pane.session_id) {
    return call('session.kill', { id: pane.session_id })
  }
  return {
    ok: false,
    error: {
      code: 'capability_unavailable',
      message: 'This pane is not open in the desktop runtime.',
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
  return next.map((row, index) => {
    const old = previous[index]
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
      message_id: String(record.message_id ?? `${fallbackId}-${index}`),
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
  return status === 'working' || status === 'waiting' || status === 'accepted' || status === 'running'
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
  /// Live chat enrichment from `chat.status`: the provider-side thread id is
  /// the only rename-proof key into the store thread catalog.
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
      if (!localThreadIds.has(thread.local_thread_id)) continue
      rows.push(chatPane(workspace, thread, turns))
    }
  } else {
    const recent = [...threads]
      .filter((thread) => !thread.archived)
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

function createAppStore() {
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
  const [compact, setCompact] = createSignal(false)
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
  let pinnedWorkspaceId: string | null = null
  let storeClientId: string | null = null
  let lastSessions: SnapshotSession[] = []
  let lastTurns: SnapshotTurn[] = []
  /// Desktop live-IPC mirrors. Non-null only while the desktop app is
  /// reachable; they then override the (possibly stale) store projection.
  let liveWorkspaces: Workspace[] | null = null
  let liveLayouts: Record<string, PersistedWorkspaceLayout | null> = {}
  const pendingTranscript = new Set<string>()
  // Threads opened from this web client stay visible even though the
  // desktop-persisted layout has no pane for them.
  const localThreadIds = new Set<string>()

  const workspace = createMemo(
    () => workspaces().find((item) => item.workspace_id === workspaceId()) ?? workspaces()[0],
  )
  const openPanes = createMemo(() => {
    const id = workspace()?.workspace_id
    if (!id) return []
    return panesByWorkspace()[id] ?? []
  })
  const paneGroups = createMemo(() => {
    const current = workspace()
    if (!current) return []
    const layout = liveLayouts[current.workspace_id] ?? parseWorkspaceLayout(current.workspace_layout_json)
    return workspacePaneGroups(openPanes(), layout?.root ?? null)
  })
  const focusedPane = createMemo(() => {
    const id = focusedPaneId()
    return openPanes().find((pane) => pane.pane_id === id) ?? openPanes()[0] ?? null
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

  const publishPanes = (list: Workspace[]) => {
    const panes = projectPanes(workspacesWithThreads(list), lastSessions, lastTurns, localThreadIds, liveLayouts)
    setPanesByWorkspace((prev) => (sameJson(prev, panes) ? prev : panes))
    const keep = workspaceId() ?? list[0]?.workspace_id ?? null
    const current_panes = keep ? panes[keep] ?? [] : []
    const restored = pendingLastChatPane && keep === pendingLastChatPane.workspace_id
      ? findLastChatPane(current_panes, pendingLastChatPane)
      : null
    if (restored) {
      // Startup restoration should place the strip before paint, not animate
      // across every pane between the default and the persisted chat.
      instantFocusPaneId = restored.pane_id
      setFocusedPaneId(restored.pane_id)
      // A live-layout placeholder has no durable thread id yet. Keep the
      // stronger persisted identity until the catalog resolves it.
      if (restored.thread_id) writeLastChatPaneLocation(restored)
      pendingLastChatPane = null
    } else if (focusedPaneId() == null || !current_panes.some((pane) => pane.pane_id === focusedPaneId())) {
      const preferred =
        current_panes.find((pane) => pane.focused) ??
        current_panes.find((pane) => pane.kind === 'chat') ??
        current_panes[0]
      if (!initialViewReady() && preferred) instantFocusPaneId = preferred.pane_id
      setFocusedPaneId(preferred?.pane_id ?? null)
    }
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
    if (root.turns) lastTurns = root.turns
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
    const restore_workspace_id = pendingLastChatPane?.workspace_id
    const keep =
      (pinnedWorkspaceId && list.some((item) => item.workspace_id === pinnedWorkspaceId) && pinnedWorkspaceId) ||
      (preferId && list.some((item) => item.workspace_id === preferId) && preferId) ||
      (restore_workspace_id &&
        list.some((item) => item.workspace_id === restore_workspace_id) &&
        restore_workspace_id) ||
      (workspaceId() && list.some((item) => item.workspace_id === workspaceId()) && workspaceId()) ||
      list[selectedIndex]?.workspace_id ||
      list[0]?.workspace_id ||
      null
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
          const merged = mergeMessages(prev[key], mapped)
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
          layouts[row.workspace_id] = layout
          if (!layout?.panes || !enrich_chat_status) return
          // The pane listing has no thread ids; chat.status carries the
          // provider-side thread id plus the model/effort controls, which is
          // what lets a pane bind to the right store thread even when the
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
                  provider_thread_id?: string | null
                  model?: string | null
                  reasoning_effort?: string | null
                  reasoning_variant?: string | null
                  fast_mode?: boolean | null
                }
              }>(status)?.thread
              if (!thread) return
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
      applySnapshot(response, workspaceId())
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
        void refreshProjection({ scope: 'selected' })
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
      await refreshProjection({ scope: 'selected', enrich_chat_status: false })
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
      await refreshProjection({ scope: 'selected', enrich_chat_status: false })
    }
  }

  const storeTranscript = (key: string, messages: Message[]) => {
    setTranscripts((prev) => {
      const merged = mergeMessages(prev[key], messages)
      if (merged === prev[key]) return prev
      return { ...prev, [key]: merged }
    })
  }

  const loadTranscript = async (pane: LivePane) => {
    if (pane.kind !== 'chat' || !pane.thread_id) return
    const key = paneKey(pane.workspace_id, pane.pane_id)
    if (pendingTranscript.has(key)) return
    pendingTranscript.add(key)
    try {
      // HTTP on purpose: a focused pane's first transcript is user-visible
      // latency, and multi-megabyte thread bodies would otherwise queue
      // behind the projection sweep on the serial websocket loop.
      const response = await interactiveCall('chat.thread.get', {
        workspace_id: pane.workspace_id,
        local_thread_id: pane.thread_id,
      })
      if (response.error || response.ok === false) return
      const messages = mapTranscriptRows(response, pane.thread_id)
      if (messages.length === 0 && transcripts()[key]?.length) return
      storeTranscript(key, messages)
    } finally {
      pendingTranscript.delete(key)
    }
  }

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
  const turnTails = new Map<string, TurnTail>()
  const [overlays, setOverlays] = createSignal<TranscriptMap>({})

  const clearOverlay = (key: string) => {
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
        title ?? (tool_kind === 'execute' ? (status === 'failed' ? 'Command failed' : 'Ran command') : tool_kind)
      const body =
        [input && `Input:\n${input}`, output && `Output:\n${output}`, error_text]
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
    // thread_id/turn_id/diff/approval bookkeeping events carry no transcript
    // row; failures surface through the committed transcript on finalize.
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
        response = await fetchRpc('chat.turn.tail', {
          turn_id: tail.turn_id,
          after_seq: tail.last_seq,
          wait_ms: TAIL_WAIT_MS,
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
        applyTailEvent(tail, event.kind, payload)
      }
      tail.last_seq = lastDeliveredTailSeq(tail.last_seq, events, result.page_last_seq)
      if (turnIsTerminal(result.status)) {
        // Durable-first: a terminal status is published only after the turn's
        // messages commit, so the committed transcript fetched here already
        // contains everything the overlay showed.
        finishedTurns.add(tail.turn_id)
        await loadTranscript(pane)
        await refreshProjection({ scope: 'selected' })
        clearOverlay(key)
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
    const turn = lastTurns
      .filter(
        (item) =>
          item.turn_id &&
          item.workspace_id === pane.workspace_id &&
          item.local_thread_id === pane.thread_id &&
          turnIsActive(item.status),
      )
      .at(-1)
    if (!turn?.turn_id || finishedTurns.has(turn.turn_id)) {
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
    // Focused pane first: on initial open it must paint before background
    // panes queue their multi-megabyte transcript downloads/parses.
    consider(focusedPane())
    for (const pane of openPanes()) consider(pane)
    for (const pane of jobs) {
      // Streaming rides its own long-poll loop; this tick only (re)starts
      // loops after turn discovery. The committed base re-downloads only
      // when missing or while a turn is live — a finished turn's tail loop
      // reloads it once on commit. Unconditionally refetching every open
      // transcript each tick shipped multi-megabyte threads through JSON
      // parse/merge over and over and made typing lag; loading them
      // sequentially keeps each JSON parse/merge in its own frame budget.
      tailActiveTurn(pane)
      const key = paneKey(pane.workspace_id, pane.pane_id)
      const uncached = !transcripts()[key]?.length
      const live = turnTails.has(key) || Boolean(pane.send_pending)
      if (uncached || live) await loadTranscript(pane)
    }
  }

  const ensureTranscript = (pane: LivePane | null | undefined) => {
    if (!pane || pane.kind !== 'chat') return
    const key = paneKey(pane.workspace_id, pane.pane_id)
    if (transcripts()[key]) return
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
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const turn_id =
      turnTails.get(key)?.turn_id ??
      lastTurns
        .filter(
          (item) =>
            item.turn_id &&
            item.workspace_id === pane.workspace_id &&
            item.local_thread_id === pane.thread_id &&
            turnIsActive(item.status),
        )
        .at(-1)?.turn_id
    if (!turn_id) return
    const response = await interactiveCall('chat.turn.cancel', { turn_id })
    if (response.error || response.ok === false) {
      setNotice(response.error?.message ?? 'could not stop the turn')
    }
  }

  const ensureClientId = async (): Promise<string> => {
    if (storeClientId) return storeClientId
    const registered = await interactiveCall('daemon.client.register', { persistent: false })
    const result = unwrapResult<{ client_id?: string }>(registered)
    storeClientId = result?.client_id ?? mintId('web-client-')
    return storeClientId
  }

  const selectWorkspace = (id: string) => {
    pendingLastChatPane = null
    pinnedWorkspaceId = id
    setWorkspaceId(id)
    setDrawerOpen(false)
    const first = panesByWorkspace()[id]?.[0]
    setFocusedPaneId(first?.pane_id ?? null)
    if (first?.kind === 'chat') writeLastChatPaneLocation(first)
    // The switch itself renders instantly from cached panes/transcripts; the
    // scoped refresh only reconciles this workspace in the background.
    void refreshProjection({ scope: 'selected' }).then(() => refreshTranscripts())
  }

  const focusPane = (pane: LivePane) => {
    pendingLastChatPane = null
    pinnedWorkspaceId = pane.workspace_id
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
    void deleteChatImage(attachment).catch(() => {})
  }

  const messagesFor = (pane: LivePane | null | undefined) => {
    if (!pane) return []
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const committed = transcripts()[key] ?? []
    const overlay = overlays()[key]
    return overlay?.length ? [...committed, ...overlay] : committed
  }

  const sendDraft = async (pane = focusedChat()) => {
    const current = pane
    const ws = workspace()
    if (!current || current.kind !== 'chat' || !current.thread_id || !ws) return
    if (uploadingAttachmentsFor(current) || sending()) return
    const text = draftFor(current).trim()
    const images = [...attachmentsFor(current)]
    if (!text && images.length === 0) return
    setSending(true)
    setNotice(null)
    // Optimistic send: clear the box and show the user row before any RPC.
    // The pre-send thread fetch plus turn.start round-trips took seconds on
    // large threads, and holding the draft hostage made Enter feel broken.
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
      // A model click persists asynchronously. Keep the optimistic submit
      // immediate, but read/start only after that queued write has landed so
      // a quick mobile tap cannot race the selected settings.
      const pending_settings = settingsUpdateQueues.get(key)
      if (pending_settings) await pending_settings
      const got = await interactiveCall('chat.thread.get', {
        workspace_id: current.workspace_id,
        local_thread_id: current.thread_id,
      })
      if (got.error || got.ok === false) {
        rollback()
        setNotice(got.error?.message ?? 'thread is not on the daemon')
        return
      }
      const thread_root = unwrapResult<{ thread?: Thread } & Thread>(got)
      const thread = thread_root?.thread ?? (thread_root as Thread | null)
      const stored_title = thread?.title ?? current.thread_title ?? 'New Chat'
      const fallback_prompt = text || (images.length > 0 ? 'Image' : '')
      const thread_title = isOpeningThread(thread, stored_title)
        ? makeThreadTitle(fallback_prompt)
        : stored_title
      const turn_id = mintId('web-turn-')
      const sent = await interactiveCall('chat.turn.start', {
        turn_id,
        workspace_id: current.workspace_id,
        local_thread_id: current.thread_id,
        project_path: ws.path,
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
        provider_thread_id: thread?.provider_thread_id,
        access_mode: thread?.access_mode ?? current.access_mode,
      })
      if (sent.error || sent.ok === false) {
        rollback()
        setNotice(sent.error?.message ?? 'send did not apply')
        return
      }
      if (thread_title !== stored_title) {
        setThreadsByWorkspace((prev) => ({
          ...prev,
          [current.workspace_id]: (prev[current.workspace_id] ?? []).map((row) =>
            row.local_thread_id === current.thread_id ? { ...row, title: thread_title, committed: true } : row,
          ),
        }))
        publishPanes(workspaces())
      }
      // Register the turn locally and start its streaming loop right away
      // instead of waiting for the projection poll to surface its record.
      lastTurns = [
        ...lastTurns,
        {
          turn_id,
          workspace_id: current.workspace_id,
          local_thread_id: current.thread_id,
          status: 'working',
          started_at_ms: Date.now(),
        },
      ]
      tailActiveTurn(current)
      window.setTimeout(() => {
        void loadTranscript(current)
        void refreshProjection()
      }, 400)
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
  /// merges the patch over a fresh chat.thread.get before writing. The next
  /// chat.turn.start re-reads the thread, so the change applies to the next
  /// send — same contract as the desktop composer pickers.
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
      const got = await interactiveCall('chat.thread.get', {
        workspace_id: pane.workspace_id,
        local_thread_id: pane.thread_id,
      })
      if (got.error || got.ok === false) {
        setNotice(got.error?.message ?? 'thread is not on the daemon')
        void refreshProjection()
        return
      }
      const thread_root = unwrapResult<{ thread?: Thread } & Thread>(got)
      const thread = thread_root?.thread ?? (thread_root as Thread | null)
      if (!thread?.local_thread_id) {
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
      pinnedWorkspaceId = workspace_id ?? null
      await refreshProjection()
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
    const opened = await interactiveCall('chat.thread.upsert', {
      mutation: {
        request_key: `web:chat.open:${local_thread_id}`,
        client_id,
      },
      workspace_id: current.workspace_id,
      thread: {
        local_thread_id,
        title: 'New Chat',
        provider,
        harness: 'local_cli',
        last_activity_at: Date.now(),
      },
    })
    if (opened.error || opened.ok === false) {
      setNotice(opened.error?.message ?? 'could not open chat')
      return null
    }
    localThreadIds.add(local_thread_id)
    const created: Thread = {
      local_thread_id,
      title: 'New Chat',
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
    pendingLastChatPane = null
    const current = workspaces().find((item) => item.workspace_id === workspace_id) ?? workspace()
    if (!current) return
    const provider =
      (current.workspace_id === workspace()?.workspace_id ? focusedChat()?.provider : undefined) ??
      (panesByWorkspace()[current.workspace_id] ?? []).find((pane) => pane.kind === 'chat')?.provider ??
      current.provider ??
      'codex'
    setNotice(null)
    const opened = await interactiveCall('chat.open', {
      workspace_id: current.workspace_id,
      provider,
      focus: true,
    })
    if ((opened.error || opened.ok === false) && !methodUnavailable(opened)) {
      setNotice(opened.error?.message ?? 'could not open chat')
      return
    }
    let opened_thread_id: string | null = null
    let pane_id: number | null
    if (opened.error || opened.ok === false) {
      pane_id = await createHeadlessThread(current, provider)
    } else {
      const result = unwrapResult<{
        pane_id?: number
        thread_id?: string
        local_thread_id?: string
        thread_index?: number
        provider?: string
        model?: string | null
        reasoning_effort?: string | null
        reasoning_variant?: string | null
        fast_mode?: boolean | null
      }>(opened)
      pane_id = result?.pane_id ?? null
      opened_thread_id = result?.local_thread_id ?? result?.thread_id ?? null
      if (opened_thread_id) {
        localThreadIds.add(opened_thread_id)
        const created: Thread = {
          local_thread_id: opened_thread_id,
          title: 'New thread',
          sort_index: result?.thread_index,
          committed: false,
          last_activity_at: null,
          provider: result?.provider ?? provider,
          harness: 'local_cli',
          model_ref: result?.model ?? null,
          reasoning_effort: result?.reasoning_effort ?? null,
          reasoning_variant: result?.reasoning_variant ?? null,
          fast_mode: result?.fast_mode ? 'on' : 'off',
        }
        setThreadsByWorkspace((prev) => ({
          ...prev,
          [current.workspace_id]: [
            created,
            ...(prev[current.workspace_id] ?? []).filter(
              (thread) => thread.local_thread_id !== opened_thread_id,
            ),
          ],
        }))
      }
    }
    if (pane_id == null) return
    pinnedWorkspaceId = current.workspace_id
    setWorkspaceId(current.workspace_id)
    // Instant transition: the optimistic thread row above already projects a
    // pane through localThreadIds, so publish and focus it now. The live
    // pane/layout reconciliation lands in the background and rebinds the
    // pane to the desktop layout entry once it appears.
    publishPanes(workspaces())
    const focused_id = opened_thread_id ? stablePaneId('chat', opened_thread_id) : pane_id
    setFocusedPaneId(focused_id)
    const focused = (panesByWorkspace()[current.workspace_id] ?? []).find(
      (pane) => pane.pane_id === focused_id,
    )
    if (focused) writeLastChatPaneLocation(focused)
    setComposerNonce((value) => value + 1)
    void refreshProjection({ workspace_id: current.workspace_id })
  }

  const newTerminal = async (workspace_id?: string) => {
    const ws = workspaces().find((item) => item.workspace_id === workspace_id) ?? workspace()
    if (!ws) return
    const session_id = mintId('web-sess-')
    const opened = await requestTerminalOpen(interactiveCall, ws, session_id)
    if (opened.response.error || opened.response.ok === false) {
      setNotice(opened.response.error?.message ?? 'could not create session')
      return
    }
    if (opened.native) {
      pinnedWorkspaceId = ws.workspace_id
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
    pinnedWorkspaceId = ws.workspace_id
    setWorkspaceId(ws.workspace_id)
    publishPanes(workspaces())
    setFocusedPaneId(stablePaneId('term', session_id))
    void refreshProjection({ workspace_id: ws.workspace_id })
  }

  const callSucceeded = (response: RpcEnvelope, fallback: string): boolean => {
    if (!(response.error || response.ok === false)) return true
    setNotice(response.error?.message ?? fallback)
    return false
  }

  const upsertWorkspaceMetadata = async (current: Workspace, patch: Partial<Workspace>) => {
    const metadata = { ...current, ...patch }
    delete metadata.threads
    delete metadata.messages
    const client_id = await ensureClientId()
    return interactiveCall('workspace.upsert', {
      mutation: {
        request_key: `web:workspace.context:${current.workspace_id}:${mintId('')}`,
        client_id,
      },
      workspace: metadata,
    })
  }

  const upsertThreadMetadata = async (
    current_workspace: Workspace,
    pane: LivePane,
    patch: Partial<Thread>,
  ) => {
    if (!pane.thread_id) return null
    const got = await interactiveCall('chat.thread.get', {
      workspace_id: current_workspace.workspace_id,
      local_thread_id: pane.thread_id,
    })
    if (got.error || got.ok === false) return got
    const thread_root = unwrapResult<{ thread?: Thread } & Thread>(got)
    const existing = thread_root?.thread ?? (thread_root as Thread | null)
    if (!existing?.local_thread_id) return got
    const thread = { ...existing, ...patch }
    delete thread.messages
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

  /// Run a command which is implemented by the native desktop UI. The web
  /// gateway automatically falls through to Live for methods the detached
  /// daemon does not implement. Workspace and pane travel with palette.run so
  /// Live applies the target before checking whether the command is enabled.
  const runDesktopSidebarCommand = async (
    current_workspace: Workspace,
    command: string,
    pane?: LivePane,
  ): Promise<boolean> => {
    const response = await interactiveCall('palette.run', {
      command,
      workspace: current_workspace.workspace_id,
      ...(pane?.native_pane_id != null ? { pane: pane.native_pane_id } : {}),
    })
    return callSucceeded(response, 'desktop command did not run')
  }

  const closePane = async (target?: LivePane) => {
    const pane = target ?? focusedPane()
    const ws = pane
      ? workspaces().find((item) => item.workspace_id === pane.workspace_id)
      : workspace()
    if (!pane || !ws) return
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

  const splitFocusedPane = async (kind: 'chat' | 'terminal', axis: 'vertical' | 'horizontal') => {
    const pane = focusedPane()
    const current_workspace = workspace()
    if (!pane || !current_workspace || pane.native_pane_id == null) {
      setNotice('Pane splitting requires the desktop runtime.')
      return
    }
    const response = await interactiveCall('pane.split', {
      workspace: current_workspace.workspace_id,
      pane: pane.native_pane_id,
      kind,
      axis,
    })
    if (callSucceeded(response, `could not split ${kind} pane`)) {
      await refreshProjection({ workspace_id: current_workspace.workspace_id })
    }
  }

  const resizePaneSplit = async (
    first_pane_id: number,
    second_pane_id: number,
    axis: 'vertical' | 'horizontal',
    ratio: number,
  ) => {
    const first = openPanes().find((pane) => pane.pane_id === first_pane_id)
    const second = openPanes().find((pane) => pane.pane_id === second_pane_id)
    const current_workspace = workspace()
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
    const { action, workspace: current_workspace, pane, value } = request
    setNotice(null)
    try {
      switch (action) {
        case 'workspace-new-chat':
          await newThread(current_workspace.workspace_id)
          return
        case 'workspace-open-codex-tui': {
          const response = await interactiveCall('agent.open', {
            workspace: current_workspace.workspace_id,
            provider: 'codex',
          })
          if (callSucceeded(response, 'could not open Codex TUI')) {
            await refreshProjection({ workspace_id: current_workspace.workspace_id })
          }
          return
        }
        case 'workspace-open-terminal':
          await newTerminal(current_workspace.workspace_id)
          return
        case 'workspace-herdr-handoff': {
          const response = await interactiveCall('herdr.handoff', { workspace: current_workspace.workspace_id })
          callSucceeded(response, 'Herdr handoff failed')
          return
        }
        case 'workspace-herdr-handoff-remote': {
          if (!value?.trim()) return
          const response = await interactiveCall('herdr.handoff', {
            workspace: current_workspace.workspace_id,
            remote: value.trim(),
          })
          callSucceeded(response, 'remote Herdr handoff failed')
          return
        }
        case 'workspace-herdr-focus-terminal': {
          const native_pane_id = current_workspace.herdr_link?.attach_pane_id
          if (native_pane_id != null) {
            const response = await interactiveCall('pane.focus', {
              workspace: current_workspace.workspace_id,
              pane: native_pane_id,
            })
            callSucceeded(response, 'could not focus Herdr terminal')
          } else {
            await runDesktopSidebarCommand(current_workspace, 'workspace.herdr_focus_terminal')
          }
          return
        }
        case 'workspace-herdr-unlink': {
          const response = await interactiveCall('herdr.unlink', { workspace: current_workspace.workspace_id })
          if (callSucceeded(response, 'could not unlink Herdr')) await refreshProjection()
          return
        }
        case 'workspace-rename': {
          const label = value?.trim()
          if (!label) return
          let response = await interactiveCall('workspace.rename', {
            workspace: current_workspace.workspace_id,
            label,
          })
          if (methodUnavailable(response)) response = await upsertWorkspaceMetadata(current_workspace, { label })
          if (callSucceeded(response, 'could not rename workspace')) {
            setWorkspaces((prev) => prev.map((row) =>
              row.workspace_id === current_workspace.workspace_id ? { ...row, label } : row,
            ))
            liveWorkspaces = null
            await refreshProjection()
          }
          return
        }
        case 'workspace-import-codex':
          await runDesktopSidebarCommand(current_workspace, 'thread.import_codex')
          return
        case 'workspace-import-opencode':
          await runDesktopSidebarCommand(current_workspace, 'thread.import_opencode')
          return
        case 'workspace-import-claude':
          await runDesktopSidebarCommand(current_workspace, 'thread.import_claude')
          return
        case 'workspace-close': {
          let response = await interactiveCall('workspace.close', { workspace: current_workspace.workspace_id })
          if (methodUnavailable(response)) response = await upsertWorkspaceMetadata(current_workspace, { archived: true })
          if (callSucceeded(response, 'could not close workspace')) {
            pinnedWorkspaceId = null
            liveWorkspaces = null
            setWorkspaces((prev) => prev.filter((row) => row.workspace_id !== current_workspace.workspace_id))
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
          await refreshProjection({ scope: 'selected' })
          return
        }
        case 'thread-regenerate-title':
          if (pane) await runDesktopSidebarCommand(current_workspace, 'thread.regenerate_title', pane)
          return
        case 'thread-sync':
          if (pane) await runDesktopSidebarCommand(current_workspace, 'thread.sync_current', pane)
          return
        case 'thread-handoff':
          if (pane) await runDesktopSidebarCommand(current_workspace, 'thread.handoff_current', pane)
          return
        case 'thread-open-tui':
          if (pane) {
            const command = pane.provider === 'codex'
              ? 'thread.open_current_codex_tui'
              : 'thread.open_current_tui'
            await runDesktopSidebarCommand(current_workspace, command, pane)
          }
          return
        case 'thread-open-chat':
          setNotice('Open as chat is available from the linked TUI row in the desktop app.')
          return
        case 'thread-archive': {
          if (!pane) return
          if (pane.native_pane_id != null) {
            const ran = await runDesktopSidebarCommand(current_workspace, 'thread.archive_current', pane)
            if (ran) await refreshProjection()
            return
          }
          const response = await upsertThreadMetadata(current_workspace, pane, { archived: true })
          if (!response || !callSucceeded(response, 'could not archive thread')) return
          setThreadsByWorkspace((prev) => ({
            ...prev,
            [current_workspace.workspace_id]: (prev[current_workspace.workspace_id] ?? []).filter(
              (thread) => thread.local_thread_id !== pane.thread_id,
            ),
          }))
          publishPanes(workspaces())
          await refreshProjection({ scope: 'selected' })
          return
        }
        case 'pane-zoom':
          if (pane) await maximizePane(pane)
          return
        case 'pane-split-chat-right':
        case 'pane-split-chat-down':
        case 'pane-split-terminal-right':
        case 'pane-split-terminal-down': {
          if (pane?.native_pane_id == null) return
          const kind = action === 'pane-split-chat-right' || action === 'pane-split-chat-down'
            ? 'chat'
            : 'terminal'
          const axis = action === 'pane-split-chat-right' || action === 'pane-split-terminal-right'
            ? 'vertical'
            : 'horizontal'
          const response = await interactiveCall('pane.split', {
            workspace: current_workspace.workspace_id,
            pane: pane.native_pane_id,
            kind,
            axis,
          })
          if (callSucceeded(response, `could not split ${kind} pane`)) {
            // Scoped: only this workspace's pane listing can have changed.
            await refreshProjection({ workspace_id: current_workspace.workspace_id })
          }
          return
        }
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
        setComposerNonce((value) => value + 1)
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
      command_palette: 'command_palette', new_thread: 'new_thread', sidebar: 'toggle_sidebar',
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
    const current = workspace()
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
      'chat.run_config': 'thread.run_config', open: 'workspace.add', open_editor: 'workspace.open_editor',
    }
    const command = paletteCommands[action]
    if (command && current) {
      void runDesktopSidebarCommand(current, command, pane ?? undefined)
      return
    }
    setNotice(`${action} is not available in the web client.`)
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
    setPaletteOpen(false)
    switch (id) {
      case 'new-thread':
        await newThread(workspace_id)
        break
      case 'new-terminal':
        await newTerminal(workspace_id)
        break
      case 'toggle-sidebar':
        dispatchAction('toggle_sidebar')
        break
      case 'settings':
        setSettingsOpen(true)
        break
      case 'maximize':
        await maximizePane()
        break
      default:
        break
    }
  }

  const start = () => {
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
      void refreshProjection({ scope: 'selected', enrich_chat_status: false })
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
    messagesFor,
    ensureTranscript,
    selectWorkspace,
    focusPane,
    takeInstantFocus,
    sendDraft,
    stopTurn,
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
  }
}

export const store = createRoot(createAppStore)
export type AppStore = typeof store

// Debug handle for driving/inspecting the live store from the console.
if (typeof window !== 'undefined') {
  ;(window as unknown as { __verde_store?: AppStore }).__verde_store = store
}

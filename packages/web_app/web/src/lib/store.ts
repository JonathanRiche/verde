import { createMemo, createRoot, createSignal, onCleanup } from 'solid-js'

import { matchKeyAction, type KeyAction } from './keybinds'
import { dynamicModelOptions, type DynamicModelRow, type ModelOption } from './models'
import { LiveClient, fetchRpc, unwrapList, unwrapResult, type EventHandler } from './live'
import { linuxWorkspaceId } from './wyhash'
import {
  paneIsActive,
  paneKey,
  paneTitle,
  synthesizeSplit,
  type LayoutNode,
  type LivePane,
  type Message,
  type Source,
  type Thread,
  type Workspace,
} from './types'

const SNAPSHOT_SCOPES = ['workspaces', 'registry', 'sessions', 'turns'] as const
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
}

type TranscriptMap = Record<string, Message[]>
type DraftMap = Record<string, string>

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' ? (value as Record<string, unknown>) : null
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
  return a.role === b.role && a.author === b.author && a.body === b.body
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

function mapTranscriptRows(raw: unknown, fallbackId: string): Message[] {
  const root = unwrapResult<Record<string, unknown>>(raw) ?? asRecord(raw)
  const thread = (root?.thread && typeof root.thread === 'object' ? root.thread : root) as
    | { messages?: Message[] }
    | null
  const rows = thread?.messages ?? unwrapList<Record<string, unknown>>(root, 'messages')
  return rows.map((row, index) => {
    const record = row as Record<string, unknown>
    const body = record.body ?? record.content ?? record.text ?? record.prompt ?? ''
    return {
      message_id: String(record.message_id ?? `${fallbackId}-${index}`),
      role: String(record.role ?? 'assistant'),
      author: String(record.author ?? ''),
      body: typeof body === 'string' ? body : JSON.stringify(body),
      tool_call_kind: typeof record.tool_call_kind === 'string' ? record.tool_call_kind : null,
      tool_call_status: typeof record.tool_call_status === 'string' ? record.tool_call_status : null,
    }
  })
}

function turnIsActive(status: string | undefined): boolean {
  return status === 'working' || status === 'waiting' || status === 'accepted' || status === 'running'
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
}

export function parseWorkspaceLayout(json: string | null | undefined): PersistedWorkspaceLayout | null {
  if (!json) return null
  try {
    const parsed: unknown = JSON.parse(json)
    const record = asRecord(parsed)
    if (!record || !Array.isArray(record.panes)) return null
    return record as PersistedWorkspaceLayout
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
    panes?: Array<{
      pane_id?: number
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
  return { v: 2, focused: result.focused_pane_id ?? null, panes }
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
    thread_title: thread.title || 'Chat',
    provider: thread.provider ?? workspace.provider,
    model: thread.model_ref ?? null,
    reasoning_effort: thread.reasoning_effort ?? null,
    reasoning_variant: thread.reasoning_variant ?? null,
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
        // provider thread id (rename-proof), exact title, and bare sort_index
        // only for persisted layouts, where index and rows are one snapshot.
        const titled = pane.title ? threads.filter((item) => item.title === pane.title) : []
        const thread =
          (pane.provider_thread_id
            ? threads.find((item) => item.provider_thread_id === pane.provider_thread_id)
            : undefined) ??
          titled.find((item) => item.sort_index === pane.thread) ??
          titled[0] ??
          (pane.title ? undefined : threads.find((item) => item.sort_index === pane.thread))
        if (thread && (!thread.archived || pane.title)) {
          used_threads.add(thread.local_thread_id)
          rows.push({
            ...chatPane(workspace, thread, turns),
            focused,
            thread_index: pane.thread,
            thread_title: pane.title || thread.title || 'Chat',
            provider: pane.provider ?? thread.provider ?? workspace.provider,
            model: pane.model ?? thread.model_ref ?? null,
            reasoning_effort: pane.reasoning_effort ?? thread.reasoning_effort ?? null,
            reasoning_variant: thread.reasoning_variant ?? null,
            fast_mode: pane.fast_mode ?? null,
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
          })
        } else if (pane.title) {
          // Open on the desktop but its thread has not reached the store yet;
          // show it so the sidebar mirrors the desktop, transcript loads once
          // the store catches up and the title resolves.
          rows.push({
            pane_id: stablePaneId('chat', `${workspace.workspace_id}:live-pane:${pane.id ?? 0}`),
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
  const [source, setSource] = createSignal<Source>('mock')
  const [connected, setConnected] = createSignal(false)
  const [workspaces, setWorkspaces] = createSignal<Workspace[]>([])
  const [threadsByWorkspace, setThreadsByWorkspace] = createSignal<Record<string, Thread[]>>({})
  const [panesByWorkspace, setPanesByWorkspace] = createSignal<Record<string, LivePane[]>>({})
  const [workspaceId, setWorkspaceId] = createSignal<string | null>(null)
  const [focusedPaneId, setFocusedPaneId] = createSignal<number | null>(null)
  const [maximizedPaneId, setMaximizedPaneId] = createSignal<number | null>(null)
  const [transcripts, setTranscripts] = createSignal<TranscriptMap>({})
  const [drafts, setDrafts] = createSignal<DraftMap>({})
  const [paletteOpen, setPaletteOpen] = createSignal(false)
  const [settingsOpen, setSettingsOpen] = createSignal(false)
  const [drawerOpen, setDrawerOpen] = createSignal(false)
  const [sidebarCollapsed, setSidebarCollapsed] = createSignal(false)
  const [sending, setSending] = createSignal(false)
  const [notice, setNotice] = createSignal<string | null>(null)
  const [composerNonce, setComposerNonce] = createSignal(0)
  const [compact, setCompact] = createSignal(false)
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
    if (focusedPaneId() == null || !current_panes.some((pane) => pane.pane_id === focusedPaneId())) {
      const preferred =
        current_panes.find((pane) => pane.focused) ??
        current_panes.find((pane) => pane.kind === 'chat') ??
        current_panes[0]
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
    const stored = snapshot.workspaces ?? root.workspaces ?? []
    // The desktop live listing decides which workspaces are open whenever the
    // desktop app is reachable; store rows only contribute their persisted
    // layout as the detached fallback. Store rows alone can be stale because
    // the desktop flushes them lazily.
    const listed = liveWorkspaces
      ? liveWorkspaces.map((item) => {
          const row = stored.find((entry) => entry.workspace_id === item.workspace_id)
          return row ? { ...item, workspace_layout_json: row.workspace_layout_json } : item
        })
      : workspacesFromVolatile(root, stored)
    const list = listed.filter((item) => item.workspace_id && !item.archived)
    if (list.length === 0 && lastSessions.length === 0) return
    setWorkspaces((prev) => (sameJson(prev, list) ? prev : list))

    const selectedIndex = typeof snapshot.selected_workspace_index === 'number' ? snapshot.selected_workspace_index : 0
    const keep =
      (pinnedWorkspaceId && list.some((item) => item.workspace_id === pinnedWorkspaceId) && pinnedWorkspaceId) ||
      (preferId && list.some((item) => item.workspace_id === preferId) && preferId) ||
      workspaceId() ||
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
          const mapped = thread.messages.map((row, index) => ({
            message_id: row.message_id || `${thread.local_thread_id}-${index}`,
            role: row.role,
            author: row.author,
            body: row.body,
            tool_call_kind: row.tool_call_kind,
            tool_call_status: row.tool_call_status,
            created_at_ms: row.created_at_ms,
          }))
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
  const refreshLive = async (only_workspace_id: string | null = null) => {
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
          if (!layout?.panes) return
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
                  fast_mode?: boolean | null
                }
              }>(status)?.thread
              if (!thread) return
              if (thread.provider_thread_id) pane.provider_thread_id = thread.provider_thread_id
              if (typeof thread.model === 'string') pane.model = thread.model
              if (thread.reasoning_effort !== undefined) pane.reasoning_effort = thread.reasoning_effort
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

  const refreshProjection = async (opts: { scope?: 'selected' | 'full' } = {}) => {
    if (projectionInFlight) {
      projectionQueued = true
      return
    }
    projectionInFlight = true
    try {
      const scope = opts.scope ?? (projectionTick++ % PROJECTION_FULL_SWEEP_EVERY === 0 ? 'full' : 'selected')
      const only = scope === 'selected' ? workspaceId() : null
      await refreshLive(only)
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
        for (const catalog of catalogs) next[catalog.workspace_id] = catalog.threads
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
      const response = await client.call('chat.thread.get', {
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
    next_seq: number
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
  const runningTails = new WeakSet<TurnTail>()
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
          after_seq: tail.next_seq,
          wait_ms: TAIL_WAIT_MS,
        })
      } catch {
        // Gateway unreachable: drop the overlay; discovery retries next tick.
        clearOverlay(key)
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
        next_seq?: number
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
      const cursor_before = tail.next_seq
      for (const event of result.events ?? []) {
        if (!event.kind) continue
        let payload: Record<string, unknown> = {}
        try {
          payload = (JSON.parse(event.payload_json ?? '{}') as Record<string, unknown>) ?? {}
        } catch {
          continue
        }
        applyTailEvent(tail, event.kind, payload)
      }
      tail.next_seq = result.next_seq ?? tail.next_seq
      if (turnIsTerminal(result.status)) {
        // Durable-first: a terminal status is published only after the turn's
        // messages commit, so the committed transcript fetched here already
        // contains everything the overlay showed.
        finishedTurns.add(tail.turn_id)
        await loadTranscript(pane)
        clearOverlay(key)
        return
      }
      setOverlays((prev) => ({ ...prev, [key]: overlayMessages(pane, tail) }))
      if (tail.next_seq === cursor_before && Date.now() - started < TAIL_FAST_EMPTY_MS) {
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
        next_seq: 0,
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
    void runTailLoop(pane, key, tail)
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
      const live = turnTails.has(key) || Boolean(pane.send_pending || pane.completion_pending)
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
    if (overlays()[key]?.length) return true
    return Boolean(pane.send_pending || pane.completion_pending)
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
    const response = await client.call('chat.turn.cancel', { turn_id })
    if (response.error || response.ok === false) {
      setNotice(response.error?.message ?? 'could not stop the turn')
    }
  }

  const ensureClientId = async (): Promise<string> => {
    if (storeClientId) return storeClientId
    const registered = await client.call('daemon.client.register', { persistent: false })
    const result = unwrapResult<{ client_id?: string }>(registered)
    storeClientId = result?.client_id ?? mintId('web-client-')
    return storeClientId
  }

  const selectWorkspace = (id: string) => {
    pinnedWorkspaceId = id
    setWorkspaceId(id)
    setDrawerOpen(false)
    const first = panesByWorkspace()[id]?.[0]
    setFocusedPaneId(first?.pane_id ?? null)
    // The switch itself renders instantly from cached panes/transcripts; the
    // scoped refresh only reconciles this workspace in the background.
    void refreshProjection({ scope: 'selected' }).then(() => refreshTranscripts())
  }

  const focusPane = (pane: LivePane) => {
    pinnedWorkspaceId = pane.workspace_id
    setWorkspaceId(pane.workspace_id)
    setFocusedPaneId(pane.pane_id)
    setDrawerOpen(false)
    void loadTranscript(pane)
  }

  const draftFor = (pane: LivePane | null | undefined) => {
    if (!pane) return ''
    return drafts()[paneKey(pane.workspace_id, pane.pane_id)] ?? ''
  }

  const setDraftFor = (pane: LivePane, text: string) => {
    const key = paneKey(pane.workspace_id, pane.pane_id)
    setDrafts((prev) => ({ ...prev, [key]: text }))
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
    const text = draftFor(current).trim()
    if (!text) return
    setSending(true)
    setNotice(null)
    // Optimistic send: clear the box and show the user row before any RPC.
    // The pre-send thread fetch plus turn.start round-trips took seconds on
    // large threads, and holding the draft hostage made Enter feel broken.
    const key = paneKey(current.workspace_id, current.pane_id)
    const local_message_id = mintId('local-user-')
    setDraftFor(current, '')
    setTranscripts((prev) => ({
      ...prev,
      [key]: [
        ...(prev[key] ?? []),
        {
          message_id: local_message_id,
          role: 'user',
          author: 'You',
          body: text,
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
    }
    try {
      const got = await client.call('chat.thread.get', {
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
      const turn_id = mintId('web-turn-')
      const sent = await client.call('chat.turn.start', {
        turn_id,
        workspace_id: current.workspace_id,
        local_thread_id: current.thread_id,
        project_path: ws.path,
        prompt: text,
        thread_title: thread?.title ?? current.thread_title ?? 'Chat',
        provider: thread?.provider ?? current.provider ?? 'codex',
        harness: thread?.harness ?? 'local_cli',
        model_ref: thread?.model_ref ?? current.model,
        reasoning_effort: thread?.reasoning_effort,
        opencode_reasoning_variant: thread?.reasoning_variant,
        fast_mode: thread?.fast_mode === 'on',
        provider_thread_id: thread?.provider_thread_id,
        access_mode: thread?.access_mode,
      })
      if (sent.error || sent.ok === false) {
        rollback()
        setNotice(sent.error?.message ?? 'send did not apply')
        return
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

  /// Persist model/effort/variant changes onto the daemon thread record.
  /// The daemon's chat.thread.upsert is a full metadata overwrite, so this
  /// merges the patch over a fresh chat.thread.get before writing. The next
  /// chat.turn.start re-reads the thread, so the change applies to the next
  /// send — same contract as the desktop composer pickers.
  const updateThreadSettings = async (
    pane: LivePane,
    patch: { model_ref?: string | null; reasoning_effort?: string | null; reasoning_variant?: string | null },
  ) => {
    if (pane.kind !== 'chat' || !pane.thread_id) return
    setNotice(null)
    try {
      const got = await client.call('chat.thread.get', {
        workspace_id: pane.workspace_id,
        local_thread_id: pane.thread_id,
      })
      if (got.error || got.ok === false) {
        setNotice(got.error?.message ?? 'thread is not on the daemon')
        return
      }
      const thread_root = unwrapResult<{ thread?: Thread } & Thread>(got)
      const thread = thread_root?.thread ?? (thread_root as Thread | null)
      if (!thread?.local_thread_id) {
        setNotice('thread is not on the daemon')
        return
      }
      const merged = {
        model_ref: patch.model_ref !== undefined ? patch.model_ref : thread.model_ref ?? null,
        reasoning_effort:
          patch.reasoning_effort !== undefined ? patch.reasoning_effort : thread.reasoning_effort ?? null,
        reasoning_variant:
          patch.reasoning_variant !== undefined ? patch.reasoning_variant : thread.reasoning_variant ?? null,
      }
      const client_id = await ensureClientId()
      const saved = await client.call('chat.thread.upsert', {
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
          provider_thread_id: thread.provider_thread_id ?? null,
          provider: thread.provider ?? pane.provider ?? 'codex',
          harness: thread.harness ?? 'local_cli',
          fast_mode: thread.fast_mode ?? null,
          access_mode: thread.access_mode ?? null,
          draft: thread.draft ?? '',
          ...merged,
        },
      })
      if (saved.error || saved.ok === false) {
        setNotice(saved.error?.message ?? 'model change did not apply')
        return
      }
      setThreadsByWorkspace((prev) => ({
        ...prev,
        [pane.workspace_id]: (prev[pane.workspace_id] ?? []).map((row) =>
          row.local_thread_id === pane.thread_id ? { ...row, ...merged } : row,
        ),
      }))
      void refreshProjection()
    } catch (err) {
      setNotice(err instanceof Error ? err.message : 'model change failed')
    }
  }

  const newThread = async () => {
    const current = workspace()
    if (!current) return
    const provider =
      focusedChat()?.provider ?? openPanes().find((pane) => pane.kind === 'chat')?.provider ?? current.provider ?? 'codex'
    const client_id = await ensureClientId()
    const local_thread_id = mintId('web-thread-')
    const opened = await client.call('chat.thread.upsert', {
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
      return
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
    await refreshProjection()
    setFocusedPaneId(stablePaneId('chat', local_thread_id))
    setComposerNonce((value) => value + 1)
  }

  const newTerminal = async () => {
    const ws = workspace()
    if (!ws) return
    const session_id = mintId('web-sess-')
    const created = await client.call('session.create', {
      id: session_id,
      cwd: ws.path,
      workspace_path: ws.path,
      workspace_id: ws.workspace_id,
      label: 'Terminal',
    })
    if (created.error || created.ok === false) {
      setNotice(created.error?.message ?? 'could not create session')
      return
    }
    await refreshProjection()
    setFocusedPaneId(stablePaneId('term', session_id))
  }

  const closePane = async () => {
    const pane = focusedPane()
    const ws = workspace()
    if (!pane || !ws) return
    if (pane.kind === 'terminal' && pane.session_id) {
      await client.call('session.kill', { id: pane.session_id })
    }
    await refreshProjection()
  }

  const maximizePane = async () => {
    const pane = focusedPane()
    if (!pane) return
    setMaximizedPaneId((current) => (current === pane.pane_id ? null : pane.pane_id))
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
      case 'focus_up':
        stepPane(-1)
        break
      case 'focus_right':
      case 'focus_down':
        stepPane(1)
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

  const handleKey = (event: KeyboardEvent) => {
    const action = matchKeyAction(event)
    if (!action) return
    event.preventDefault()
    event.stopPropagation()
    dispatchAction(action)
  }

  const runCommand = async (id: string) => {
    setPaletteOpen(false)
    switch (id) {
      case 'new-thread':
        await newThread()
        break
      case 'new-terminal':
        await newTerminal()
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
    client.onEvent(onEvent)
    client.connect()
    const media = window.matchMedia('(max-width: 1023px)')
    const syncCompact = () => setCompact(media.matches)
    syncCompact()
    media.addEventListener('change', syncCompact)
    const tick = window.setInterval(() => setConnected(client.connected), 1000)
    const transcriptsTick = window.setInterval(() => {
      if (client.connected) void refreshTranscripts()
    }, 1500)
    // Desktop pane opens/closes do not emit daemon change events, so the live
    // pane mirror needs its own cadence.
    const projectionTick = window.setInterval(() => {
      if (client.connected) void refreshProjection()
    }, 4000)
    void refreshProjection().then(() => refreshTranscripts())
    onCleanup(() => {
      window.clearInterval(tick)
      window.clearInterval(transcriptsTick)
      window.clearInterval(projectionTick)
      media.removeEventListener('change', syncCompact)
      client.disconnect()
    })
  }

  return {
    client,
    source,
    connected,
    workspaces,
    workspace,
    workspaceId,
    openPanes,
    visiblePanes,
    canvasLayout,
    activePanes,
    focusedPane,
    focusedPaneId,
    focusedChat,
    maximizedPaneId,
    paletteOpen,
    setPaletteOpen,
    settingsOpen,
    setSettingsOpen,
    drawerOpen,
    setDrawerOpen,
    sidebarCollapsed,
    setSidebarCollapsed,
    sending,
    notice,
    setNotice,
    composerNonce,
    compact,
    draftFor,
    setDraftFor,
    messagesFor,
    ensureTranscript,
    selectWorkspace,
    focusPane,
    sendDraft,
    stopTurn,
    paneWorking,
    updateThreadSettings,
    providerModels,
    ensureProviderModels,
    runCommand,
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

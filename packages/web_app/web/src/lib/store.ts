import { createMemo, createRoot, createSignal, onCleanup } from 'solid-js'

import { matchKeyAction, type KeyAction } from './keybinds'
import { LiveClient, unwrapList, unwrapResult, type EventHandler } from './live'
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

const SNAPSHOT_SCOPES = ['registry', 'sessions', 'turns'] as const
const MAX_OPEN_THREADS = 16

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

function stablePaneId(kind: 'chat' | 'term', key: string): number {
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

function projectPanes(
  workspaces: Workspace[],
  sessions: SnapshotSession[],
  turns: SnapshotTurn[],
): Record<string, LivePane[]> {
  const next: Record<string, LivePane[]> = {}
  for (const workspace of workspaces) {
    const threads = [...(workspace.threads ?? [])]
      .filter((thread) => !thread.archived)
      .sort((left, right) => (right.last_activity_at ?? 0) - (left.last_activity_at ?? 0))
      .slice(0, MAX_OPEN_THREADS)
    const chats: LivePane[] = threads.map((thread) => {
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
        send_pending: active,
        completion_pending: active,
      }
    })
    const terms: LivePane[] = sessions
      .filter((session) => sessionKey(session) && sessionIsLive(session) && sessionMatchesWorkspace(session, workspace))
      .map((session) => ({
        pane_id: stablePaneId('term', sessionKey(session)),
        workspace_id: workspace.workspace_id,
        kind: 'terminal',
        session_id: sessionKey(session),
        thread_title: sessionTitle(session),
        dock_id: session.dock_id,
        running: session.running ?? session.status === 'working',
        cwd: session.cwd ?? workspace.path,
        attention: session.status === 'working',
      }))
    next[workspace.workspace_id] = [...chats, ...terms]
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
  const pendingTranscript = new Set<string>()

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
    const panes = projectPanes(workspacesWithThreads(list), lastSessions, lastTurns)
    setPanesByWorkspace((prev) => (sameJson(prev, panes) ? prev : panes))
    const keep = workspaceId() ?? list[0]?.workspace_id ?? null
    const current_panes = keep ? panes[keep] ?? [] : []
    if (focusedPaneId() == null || !current_panes.some((pane) => pane.pane_id === focusedPaneId())) {
      const preferred = current_panes.find((pane) => pane.kind === 'chat') ?? current_panes[0]
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
    const listed = workspacesFromVolatile(root, snapshot.workspaces ?? root.workspaces ?? [])
    const list = listed.filter((item) => item.workspace_id)
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

  const refreshProjection = async () => {
    const response = await client.call('core.snapshot', { scopes: SNAPSHOT_SCOPES })
    if (response.error || response.ok === false) return
    applySnapshot(response, workspaceId())
    const listed = workspaces()
    if (listed.length === 0) return
    const catalogs = await Promise.all(
      listed.map(async (item) => {
        const threads = await client.call('chat.thread.list', {
          workspace_id: item.workspace_id,
          limit: MAX_OPEN_THREADS,
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
      setTranscripts((prev) => {
        const merged = mergeMessages(prev[key], messages)
        if (merged === prev[key]) return prev
        return { ...prev, [key]: merged }
      })
    } finally {
      pendingTranscript.delete(key)
    }
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
    for (const pane of openPanes()) consider(pane)
    consider(focusedPane())
    await Promise.all(jobs.map((pane) => loadTranscript(pane)))
  }

  const ensureTranscript = (pane: LivePane | null | undefined) => {
    if (!pane || pane.kind !== 'chat') return
    const key = paneKey(pane.workspace_id, pane.pane_id)
    if (transcripts()[key]) return
    void loadTranscript(pane)
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
    void refreshProjection().then(() => refreshTranscripts())
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
    return transcripts()[paneKey(pane.workspace_id, pane.pane_id)] ?? []
  }

  const sendDraft = async (pane = focusedChat()) => {
    const current = pane
    const ws = workspace()
    if (!current || current.kind !== 'chat' || !current.thread_id || !ws) return
    const text = draftFor(current).trim()
    if (!text) return
    setSending(true)
    setNotice(null)
    try {
      const got = await client.call('chat.thread.get', {
        workspace_id: current.workspace_id,
        local_thread_id: current.thread_id,
      })
      if (got.error || got.ok === false) {
        setNotice(got.error?.message ?? 'thread is not on the daemon')
        return
      }
      const thread_root = unwrapResult<{ thread?: Thread } & Thread>(got)
      const thread = thread_root?.thread ?? (thread_root as Thread | null)
      const sent = await client.call('chat.turn.start', {
        turn_id: mintId('web-turn-'),
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
        setNotice(sent.error?.message ?? 'send did not apply')
        return
      }
      setDraftFor(current, '')
      const key = paneKey(current.workspace_id, current.pane_id)
      setTranscripts((prev) => ({
        ...prev,
        [key]: [
          ...(prev[key] ?? []),
          {
            message_id: `local-${Date.now()}`,
            role: 'user',
            author: 'You',
            body: text,
            created_at_ms: Date.now(),
          },
        ],
      }))
      window.setTimeout(() => {
        void loadTranscript(current)
        void refreshProjection()
      }, 400)
    } catch (err) {
      setNotice(err instanceof Error ? err.message : 'send failed')
    } finally {
      setSending(false)
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
    void refreshProjection().then(() => refreshTranscripts())
    onCleanup(() => {
      window.clearInterval(tick)
      window.clearInterval(transcriptsTick)
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
    runCommand,
    handleKey,
    start,
    paneTitle,
  }
}

export const store = createRoot(createAppStore)
export type AppStore = typeof store

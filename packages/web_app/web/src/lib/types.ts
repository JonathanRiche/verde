export type Source = 'daemon' | 'live' | 'mock'

export type Surface = 'chat' | 'terminals' | 'more'

export type PaneKind = 'chat' | 'terminal' | 'browser'

export interface Attachment {
  path: string
  mime: string
  byte_size?: number
  attachment_id?: string | null
}

export interface Message {
  message_id: string
  role: string
  author: string
  body: string
  images?: Attachment[]
  tool_call_id?: string | null
  tool_call_kind?: string | null
  tool_call_status?: string | null
  created_at_ms?: number | null
}

export interface Thread {
  local_thread_id: string
  title: string
  /// Stable position in the workspace thread array; persisted workspace
  /// layout JSON references chat panes by this index.
  sort_index?: number
  archived?: boolean
  last_activity_at?: number | null
  model_ref?: string | null
  access_mode?: string | null
  provider?: string
  harness?: string
  draft?: string
  messages?: Message[]
  reasoning_effort?: string | null
  reasoning_variant?: string | null
  fast_mode?: string | null
  provider_thread_id?: string | null
}

export interface Workspace {
  workspace_id: string
  label: string
  path: string
  archived?: boolean
  unread_count?: number
  /// Desktop-persisted open-pane layout (workspace_layout.zig v2 JSON).
  workspace_layout_json?: string | null
  selected_thread_index?: number
  provider?: string
  harness?: string
  draft?: string
  threads?: Thread[]
  messages?: Message[]
  pane_count?: number
  thread_count?: number
}

export interface LivePane {
  pane_id: number
  workspace_id: string
  focused?: boolean
  maximized?: boolean
  kind: PaneKind
  thread_id?: string
  provider_thread_id?: string | null
  session_id?: string
  thread_index?: number
  thread_title?: string
  provider?: string
  model?: string | null
  reasoning_effort?: string | null
  reasoning_variant?: string | null
  fast_mode?: boolean | null
  access_mode?: string | null
  send_pending?: boolean
  completion_pending?: boolean
  completed_at_ms?: number | null
  pending_approval?: boolean
  attention?: boolean
  attention_reasons?: string[]
  dock_id?: number
  running?: boolean
  /// Desktop-surface work status for terminals: the agent inside the pane is
  /// actively working. Distinct from `running`, which only means the shell
  /// process is alive.
  working?: boolean
  cwd?: string | null
  tab_count?: number
  active_tab_index?: number
}

export interface LiveActive {
  workspace_index?: number
  workspace_id?: string
  focused_pane_id?: number | null
  maximized_pane_id?: number | null
}

export type LayoutNode =
  | { leaf: number }
  | { split: { axis: 'horizontal' | 'vertical'; ratio: number; first: LayoutNode; second: LayoutNode } }

export function parseLayoutNode(raw: unknown): LayoutNode | null {
  if (!raw || typeof raw !== 'object') return null
  const rec = raw as Record<string, unknown>
  if (typeof rec.leaf === 'number') return { leaf: rec.leaf }
  const split = rec.split
  if (!split || typeof split !== 'object') return null
  const body = split as Record<string, unknown>
  const first = parseLayoutNode(body.first)
  const second = parseLayoutNode(body.second)
  if (!first || !second) return null
  return {
    split: {
      axis: body.axis === 'vertical' ? 'vertical' : 'horizontal',
      ratio: typeof body.ratio === 'number' ? Math.min(0.82, Math.max(0.18, body.ratio)) : 0.5,
      first,
      second,
    },
  }
}

export function layoutContains(node: LayoutNode, paneId: number): boolean {
  if ('leaf' in node) return node.leaf === paneId
  return layoutContains(node.split.first, paneId) || layoutContains(node.split.second, paneId)
}

export function layoutLeafCount(node: LayoutNode): number {
  if ('leaf' in node) return 1
  return layoutLeafCount(node.split.first) + layoutLeafCount(node.split.second)
}

/// Desktop never paints every open pane. Collapse a large tree to the
/// focused leaf and its nearest sibling split (the on-screen neighborhood).
export function layoutNeighborhood(node: LayoutNode, focusedId: number | null): LayoutNode {
  if (layoutLeafCount(node) <= 2) return node
  if (focusedId == null || !layoutContains(node, focusedId) || 'leaf' in node) return node
  const inFirst = layoutContains(node.split.first, focusedId)
  const child = inFirst ? node.split.first : node.split.second
  const other = inFirst ? node.split.second : node.split.first
  if (layoutLeafCount(child) === 1) {
    return layoutLeafCount(other) === 1 ? node : child
  }
  if (layoutLeafCount(child) <= 2) return child
  return layoutNeighborhood(child, focusedId)
}

export function synthesizeSplit(first: number, second: number | null): LayoutNode {
  if (second == null || second === first) return { leaf: first }
  return {
    split: {
      axis: 'vertical',
      ratio: 0.58,
      first: { leaf: first },
      second: { leaf: second },
    },
  }
}

export interface SessionSummary {
  session_id: string
  workspace_id?: string
  label?: string
  command?: string
  running?: boolean
  status?: string
}

export interface TurnRecord {
  turn_id: string
  workspace_id: string
  local_thread_id: string
  status: string
  provider: string
  /// Daemon acceptance timestamp — the clock the desktop's working timer
  /// counts from. Absent on daemons predating the field.
  started_at_ms?: number
}

export interface Snapshot {
  schema_version?: number
  store_revision?: number
  selected_workspace_index?: number
  workspaces?: Workspace[]
  surface_states?: Array<{ session_id: string; title?: string; status?: string }>
}

export interface SnapshotResult {
  snapshot: Snapshot
  store_revision?: number
  change_cursor?: number | null
  sessions?: SessionSummary[]
  turns?: TurnRecord[]
}

export interface RpcError {
  code: string
  message: string
}

export interface RpcEnvelope {
  jsonrpc?: string
  id?: number | null
  ok?: boolean
  method?: string
  params?: unknown
  result?: unknown
  error?: RpcError
}

export interface HelloParams {
  source: Source
  status_envelope?: RpcEnvelope
}

export function workspaceThreads(workspace: Workspace | undefined): Thread[] {
  return workspace?.threads ?? []
}

export function threadMessages(thread: Thread | undefined): Message[] {
  return thread?.messages ?? []
}

export function isCommandRow(message: Message): boolean {
  return message.role === 'system' || Boolean(message.tool_call_kind)
}

export function isWorking(status: string | undefined): boolean {
  return status === 'working' || status === 'waiting'
}

export function paneIsActive(pane: LivePane): boolean {
  // `running` (shell alive) deliberately does not count: the desktop only
  // marks a terminal active while its surface reports work in progress.
  return Boolean(
    pane.send_pending ||
      pane.completion_pending ||
      pane.pending_approval ||
      pane.attention ||
      pane.working,
  )
}

export function paneTitle(pane: LivePane): string {
  if (pane.thread_title) return pane.thread_title
  if (pane.kind === 'chat') return 'Chat'
  if (pane.kind === 'terminal') return 'Terminal'
  return 'Browser'
}

export function paneKey(workspaceId: string, paneId: number): string {
  return `${workspaceId}:${paneId}`
}

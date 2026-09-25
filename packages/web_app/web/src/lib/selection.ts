/** View selection: one workspace + pane pair. Readers derive from this. */

export interface ViewSelection {
  workspace_id: string | null
  pane_id: number | null
}

export interface SelectionPane {
  pane_id: number
  workspace_id: string
  kind?: string
  focused?: boolean
}

function listed(id: string | null | undefined, ids: readonly string[]): id is string {
  return typeof id === 'string' && ids.includes(id)
}

/**
 * Pick the web client's workspace. An open thread, current selection, or
 * last-chat restore always beats the daemon/desktop snapshot index.
 */
export function resolveWorkspaceId(args: {
  workspace_ids: readonly string[]
  focused_workspace_id?: string | null
  current_workspace_id?: string | null
  restore_workspace_id?: string | null
  snapshot_selected_index?: number
}): string | null {
  const ids = args.workspace_ids
  const pick = (id: string | null | undefined) => (listed(id, ids) ? id : null)
  const current =
    pick(args.focused_workspace_id) ??
    pick(args.current_workspace_id) ??
    pick(args.restore_workspace_id)
  if (current) return current
  if (ids.length === 0) return null
  const index = args.snapshot_selected_index
  if (typeof index === 'number' && index >= 0 && index < ids.length) return ids[index] ?? ids[0] ?? null
  return ids[0] ?? null
}

/** Chat actions follow the thread catalog, not the globally selected workspace. */
export function owningWorkspaceId(
  pane: Pick<SelectionPane, 'workspace_id'> & { thread_id?: string },
  threads_by_workspace: Record<string, ReadonlyArray<{ local_thread_id: string }>>,
): string {
  if (!pane.thread_id) return pane.workspace_id
  const owners = Object.entries(threads_by_workspace)
    .filter(([, threads]) => threads.some((thread) => thread.local_thread_id === pane.thread_id))
    .map(([workspace_id]) => workspace_id)
  if (owners.length === 0) return pane.workspace_id
  if (owners.includes(pane.workspace_id)) return pane.workspace_id
  return owners[0] ?? pane.workspace_id
}

export type WorkspaceSelectIntent =
  | { kind: 'keep' }
  | { kind: 'open-new-chat'; workspace_id: string }

/**
 * Changing the sheet's workspace opens a new chat there. The current thread
 * is left untouched — including its workspace_id and connection.
 */
export function workspaceSelectIntent(
  owning_workspace_id: string,
  selected_workspace_id: string,
): WorkspaceSelectIntent {
  if (!selected_workspace_id || selected_workspace_id === owning_workspace_id) return { kind: 'keep' }
  return { kind: 'open-new-chat', workspace_id: selected_workspace_id }
}

/**
 * After a snapshot/reconnect, keep the open pane's workspace. The desktop
 * selected-workspace index is used only when nothing is focused or restorable.
 */
export function reconcileViewSelection(args: {
  workspace_id: string | null
  pane_id: number | null
  panes_by_workspace: Record<string, readonly SelectionPane[]>
  workspace_ids: readonly string[]
  snapshot_selected_index?: number
}): ViewSelection {
  if (args.pane_id != null) {
    const local = args.workspace_id
      ? (args.panes_by_workspace[args.workspace_id] ?? []).find((pane) => pane.pane_id === args.pane_id)
      : undefined
    if (local) return { workspace_id: local.workspace_id, pane_id: local.pane_id }
    for (const panes of Object.values(args.panes_by_workspace)) {
      const pane = panes.find((item) => item.pane_id === args.pane_id)
      if (pane) return { workspace_id: pane.workspace_id, pane_id: pane.pane_id }
    }
  }
  const workspace_id = resolveWorkspaceId({
    workspace_ids: args.workspace_ids,
    current_workspace_id: args.workspace_id,
    snapshot_selected_index: args.snapshot_selected_index,
  })
  const panes = workspace_id ? args.panes_by_workspace[workspace_id] ?? [] : []
  const preferred =
    panes.find((pane) => pane.focused) ??
    panes.find((pane) => pane.kind === 'chat') ??
    panes[0] ??
    null
  return { workspace_id, pane_id: preferred?.pane_id ?? null }
}

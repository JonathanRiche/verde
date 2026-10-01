import type { Workspace } from './types'

/// Move `id` so it lands immediately before `before_id` (null = end), like the
/// desktop sidebar drop. Returns null when the order would not change.
export function moveWorkspaceBefore(ids: readonly string[], id: string, before_id: string | null): string[] | null {
  const from = ids.indexOf(id)
  if (from < 0 || before_id === id) return null
  const rest = ids.filter((row) => row !== id)
  const at = before_id === null ? rest.length : rest.indexOf(before_id)
  if (at < 0) return null
  const next = [...rest.slice(0, at), id, ...rest.slice(at)]
  return next.every((row, index) => row === ids[index]) ? null : next
}

/// Keep a just-submitted order until the daemon echoes it, so a projection
/// refresh racing the `workspace.reorder` call cannot flash the old order.
/// Rows missing from `order` keep their relative order after the listed ones.
export function applyWorkspaceOrder<T extends { workspace_id: string }>(rows: readonly T[], order: readonly string[] | null): T[] {
  if (!order) return [...rows]
  const rank = new Map(order.map((id, index) => [id, index] as const))
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => (rank.get(a.row.workspace_id) ?? order.length + a.index) - (rank.get(b.row.workspace_id) ?? order.length + b.index))
    .map(({ row }) => row)
}

/// Closed (archived) store rows, most recently closed first. The desktop
/// persists closed workspaces after the open ones in close order.
export function closedWorkspacesFrom(stored: readonly Workspace[]): Workspace[] {
  return stored
    .filter((row) => row.workspace_id && row.archived)
    .map(({ workspace_id, label, path }) => ({ workspace_id, label: label || workspace_id, path: path ?? '', archived: true }))
    .reverse()
}

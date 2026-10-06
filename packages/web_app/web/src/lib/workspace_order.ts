import type { Workspace } from './types'

/// Closed (archived) store rows, most recently closed first. The desktop
/// persists closed workspaces after the open ones in close order.
export function closedWorkspacesFrom(stored: readonly Workspace[]): Workspace[] {
  return stored
    .filter((row) => row.workspace_id && row.archived)
    .map(({ workspace_id, label, path }) => ({ workspace_id, label: label || workspace_id, path: path ?? '', archived: true }))
    .reverse()
}

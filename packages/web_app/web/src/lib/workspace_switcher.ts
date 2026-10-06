//! Pure helpers for the sidebar workspace switcher: recency ordering and the
//! popover's label filter. Contract: docs/workspace-switcher-sidebar.md.

import type { Thread, Workspace } from './types'

/// Sidebar list scope: every open workspace, or one workspace id.
export type SidebarScope = 'all' | string

export interface SwitcherRow {
  workspace: Workspace
  closed: boolean
}

/// Thread activity arrives as epoch seconds from the daemon but as epoch
/// milliseconds from optimistic local rows; compare everything in ms.
export function activityMs(value: number | null | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return 0
  return value < 1e12 ? value * 1000 : value
}

/// max(last client-side selection, newest thread activity), in ms.
export function workspaceRecency(
  workspace: Workspace,
  threads: readonly Thread[] | undefined,
  selected_at: Readonly<Record<string, number>>,
): number {
  let newest = selected_at[workspace.workspace_id] ?? 0
  for (const thread of threads ?? workspace.threads ?? []) {
    newest = Math.max(newest, activityMs(thread.last_activity_at))
  }
  return newest
}

/// Open workspaces most-recent first, then closed ones. Ties (and rows with no
/// timestamps) keep their incoming order, so closed rows without timestamps
/// stay in most-recently-closed order.
export function orderSwitcherRows(
  open: readonly Workspace[],
  closed: readonly Workspace[],
  recency: (workspace: Workspace) => number,
): SwitcherRow[] {
  const ranked = (rows: readonly Workspace[]) => rows
    .map((workspace, index) => ({ workspace, index, at: recency(workspace) }))
    .sort((a, b) => b.at - a.at || a.index - b.index)
    .map(({ workspace }) => workspace)
  const open_ids = new Set(open.map((row) => row.workspace_id))
  return [
    ...ranked(open).map((workspace) => ({ workspace, closed: false })),
    ...ranked(closed.filter((row) => !open_ids.has(row.workspace_id))).map((workspace) => ({ workspace, closed: true })),
  ]
}

/// Case-insensitive subsequence match ("vrd" matches "verde").
export function fuzzyMatches(label: string, query: string): boolean {
  const needle = query.trim().toLowerCase()
  if (!needle) return true
  const haystack = label.toLowerCase()
  let at = 0
  for (const ch of needle) {
    if (ch === ' ') continue
    at = haystack.indexOf(ch, at)
    if (at < 0) return false
    at += 1
  }
  return true
}

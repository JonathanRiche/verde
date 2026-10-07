//! Pure helpers for the sidebar workspace switcher: recency ordering and the
//! popover's label filter. Contract: docs/workspace-switcher-sidebar.md.

import type { Thread, Workspace } from './types'

/// Sidebar list scope: every open workspace, or one workspace id.
export type SidebarScope = 'all' | string

/// Sidebar body sections. Active is global (every open workspace, always
/// chipped); Open follows the scope and carries chips only under All. Under
/// All, Open interleaves every workspace newest activity first
/// (`orderByActivity`); a single-workspace scope keeps layout order.
export function sidebarSections<T extends SidebarOpenRow>(
  active: readonly T[],
  inactive: readonly T[],
  scope: SidebarScope,
  activity: (pane: T) => number = () => 0,
): { active: T[]; open: T[]; open_chips: boolean } {
  return {
    active: [...active],
    open: scope === 'all' ? orderByActivity(inactive, activity) : inactive.filter((pane) => pane.workspace_id === scope),
    open_chips: scope === 'all',
  }
}

/// Pane fields the Open ordering reads.
export interface SidebarOpenRow {
  workspace_id: string
  /// Native scrolling-tile identity; panes sharing it (within a workspace)
  /// are one split tile.
  scroll_group_id?: number
}

/// Newest activity first, a split tile moving as one unit ranked by its
/// newest pane (members stay adjacent, in incoming order). Stable: ties and
/// rows without activity (0) keep incoming order, i.e. workspace order then
/// layout order, so untimed panes sort last in that order.
export function orderByActivity<T extends SidebarOpenRow>(
  rows: readonly T[],
  activity: (pane: T) => number,
): T[] {
  const units: { members: T[]; index: number; at: number }[] = []
  const by_tile = new Map<string, (typeof units)[number]>()
  rows.forEach((pane, index) => {
    const at = activity(pane) || 0
    const tile = pane.scroll_group_id != null ? `${pane.workspace_id}\u0000${pane.scroll_group_id}` : null
    const unit = tile ? by_tile.get(tile) : undefined
    if (unit) {
      unit.members.push(pane)
      unit.at = Math.max(unit.at, at)
      return
    }
    const next = { members: [pane], index, at }
    units.push(next)
    if (tile) by_tile.set(tile, next)
  })
  return units
    .sort((a, b) => b.at - a.at || a.index - b.index)
    .flatMap((unit) => unit.members)
}

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

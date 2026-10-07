import { describe, expect, test } from 'bun:test'
import { activityMs, fuzzyMatches, orderByActivity, orderSwitcherRows, sidebarSections, workspaceRecency } from './workspace_switcher'

const ws = (workspace_id, threads = []) => ({ workspace_id, label: workspace_id, path: '', threads })

describe('workspace switcher', () => {
  test('normalizes second and millisecond activity stamps', () => {
    expect(activityMs(1_700_000_000)).toBe(1_700_000_000_000)
    expect(activityMs(1_700_000_000_000)).toBe(1_700_000_000_000)
    expect(activityMs(null)).toBe(0)
  })

  test('recency is max(selection, newest thread activity)', () => {
    const row = ws('a', [{ local_thread_id: 't', title: '', last_activity_at: 1_700_000_000 }])
    expect(workspaceRecency(row, undefined, {})).toBe(1_700_000_000_000)
    expect(workspaceRecency(row, undefined, { a: 1_800_000_000_000 })).toBe(1_800_000_000_000)
  })

  test('orders open by recency, then closed in incoming order', () => {
    const at = { a: 1, b: 3, c: 2 }
    const rows = orderSwitcherRows([ws('a'), ws('b'), ws('c')], [ws('x'), ws('y'), ws('b')], (row) => at[row.workspace_id] ?? 0)
    expect(rows.map((row) => `${row.workspace.workspace_id}${row.closed ? '*' : ''}`)).toEqual(['b', 'c', 'a', 'x*', 'y*'])
  })

  test('fuzzy-matches labels as subsequences', () => {
    expect(fuzzyMatches('verde', 'vrd')).toBe(true)
    expect(fuzzyMatches('verde', 'VE')).toBe(true)
    expect(fuzzyMatches('verde', 'dv')).toBe(false)
    expect(fuzzyMatches('anything', '  ')).toBe(true)
  })
})

describe('sidebar sections', () => {
  const active = [{ workspace_id: 'b', pane_id: 'b1' }, { workspace_id: 'a', pane_id: 'a1' }]
  const open = [{ workspace_id: 'a', pane_id: 'a2' }, { workspace_id: 'b', pane_id: 'b2' }]

  test('Active spans every workspace in its own order regardless of scope', () => {
    for (const scope of ['all', 'a', 'b', 'missing']) {
      expect(sidebarSections(active, open, scope).active).toEqual(active)
    }
  })

  test('Open follows the scope and carries chips only under All', () => {
    expect(sidebarSections(active, open, 'all')).toMatchObject({ open, open_chips: true })
    expect(sidebarSections(active, open, 'a')).toMatchObject({ open: [open[0]], open_chips: false })
    expect(sidebarSections(active, open, 'missing').open).toEqual([])
  })
})

describe('Open recency under All Workspaces', () => {
  const ids = (rows) => rows.map((row) => row.pane_id)
  const pane = (workspace_id, pane_id, at, scroll_group_id) =>
    ({ workspace_id, pane_id, at, ...(scroll_group_id != null ? { scroll_group_id } : {}) })
  const at = (row) => row.at

  test('interleaves workspaces newest activity first', () => {
    const rows = [pane('a', 'a1', 10), pane('a', 'a2', 30), pane('b', 'b1', 20), pane('b', 'b2', 40)]
    expect(ids(sidebarSections([], rows, 'all', at).open)).toEqual(['b2', 'a2', 'b1', 'a1'])
  })

  test('ties and untimed panes keep workspace then layout order, untimed last', () => {
    const rows = [pane('a', 'a1', 0), pane('a', 'a2', 5), pane('b', 'b1', 5), pane('b', 'b2', 0), pane('c', 'c1', 9)]
    expect(ids(orderByActivity(rows, at))).toEqual(['c1', 'a2', 'b1', 'a1', 'b2'])
  })

  test('a split tile moves as one unit ranked by its newest pane', () => {
    const rows = [pane('a', 'a1', 1, 7), pane('a', 'a2', 3), pane('a', 'a3', 50, 7), pane('b', 'b1', 2, 7)]
    // Tile a:7 ranks at 50 and keeps a1 before a3; b's group 7 is a different tile.
    expect(ids(orderByActivity(rows, at))).toEqual(['a1', 'a3', 'a2', 'b1'])
  })

  test('a single-workspace scope keeps layout order', () => {
    const rows = [pane('a', 'a1', 1), pane('b', 'b1', 99), pane('a', 'a2', 50)]
    expect(ids(sidebarSections([], rows, 'a', at).open)).toEqual(['a1', 'a2'])
  })

  test('without an activity source All keeps incoming order', () => {
    const rows = [pane('a', 'a1', 1), pane('b', 'b1', 99)]
    expect(ids(sidebarSections([], rows, 'all').open)).toEqual(['a1', 'b1'])
  })
})

import { describe, expect, test } from 'bun:test'
import { activityMs, fuzzyMatches, orderSwitcherRows, sidebarSections, workspaceRecency } from './workspace_switcher'

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

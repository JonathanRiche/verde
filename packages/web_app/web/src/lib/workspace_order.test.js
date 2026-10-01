import { describe, expect, test } from 'bun:test'
import { applyWorkspaceOrder, closedWorkspacesFrom, moveWorkspaceBefore } from './workspace_order'

describe('workspace order', () => {
  test('moves a workspace before a target or to the end', () => {
    const ids = ['a', 'b', 'c', 'd']
    expect(moveWorkspaceBefore(ids, 'd', 'a')).toEqual(['d', 'a', 'b', 'c'])
    expect(moveWorkspaceBefore(ids, 'a', 'c')).toEqual(['b', 'a', 'c', 'd'])
    expect(moveWorkspaceBefore(ids, 'b', null)).toEqual(['a', 'c', 'd', 'b'])
  })

  test('reports no-op drops', () => {
    const ids = ['a', 'b', 'c']
    expect(moveWorkspaceBefore(ids, 'b', 'b')).toBeNull()
    expect(moveWorkspaceBefore(ids, 'b', 'c')).toBeNull()
    expect(moveWorkspaceBefore(ids, 'c', null)).toBeNull()
    expect(moveWorkspaceBefore(ids, 'missing', 'a')).toBeNull()
    expect(moveWorkspaceBefore(ids, 'a', 'missing')).toBeNull()
  })

  test('applies a pending order and keeps unlisted rows after it', () => {
    const rows = ['a', 'b', 'c', 'new'].map((workspace_id) => ({ workspace_id }))
    expect(applyWorkspaceOrder(rows, ['c', 'a', 'b']).map((row) => row.workspace_id)).toEqual(['c', 'a', 'b', 'new'])
    expect(applyWorkspaceOrder(rows, null).map((row) => row.workspace_id)).toEqual(['a', 'b', 'c', 'new'])
  })

  test('lists closed workspaces newest first', () => {
    const stored = [
      { workspace_id: 'open', label: 'Open', path: '/open' },
      { workspace_id: 'old', label: 'Old', path: '/old', archived: true, threads: [{}] },
      { workspace_id: 'recent', label: '', path: '/recent', archived: true },
    ]
    expect(closedWorkspacesFrom(stored)).toEqual([
      { workspace_id: 'recent', label: 'recent', path: '/recent', archived: true },
      { workspace_id: 'old', label: 'Old', path: '/old', archived: true },
    ])
  })
})

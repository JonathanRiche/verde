import { describe, expect, test } from 'bun:test'
import { closedWorkspacesFrom } from './workspace_order'

describe('workspace order', () => {
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

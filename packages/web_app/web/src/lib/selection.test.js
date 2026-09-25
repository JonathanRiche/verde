import { describe, expect, test } from 'bun:test'

import {
  owningWorkspaceId,
  reconcileViewSelection,
  resolveWorkspaceId,
  workspaceSelectIntent,
} from './selection'

const catalogs = {
  mirage: [{ local_thread_id: 'mirage-thread' }],
  verde: [{ local_thread_id: 'verde-thread' }],
}

test('actions sheet uses the thread owning workspace, falling back to the pane workspace', () => {
  expect(owningWorkspaceId({ workspace_id: 'mirage', thread_id: 'verde-thread' }, catalogs)).toBe('verde')
  expect(owningWorkspaceId({ workspace_id: 'verde', thread_id: 'verde-thread' }, catalogs)).toBe('verde')
  expect(owningWorkspaceId({ workspace_id: 'verde', thread_id: 'opening' }, catalogs)).toBe('verde')
})

test('selecting another workspace requests a new chat; reselecting the owner is a no-op', () => {
  expect(workspaceSelectIntent('verde', 'mirage')).toEqual({ kind: 'open-new-chat', workspace_id: 'mirage' })
  expect(workspaceSelectIntent('verde', 'verde')).toEqual({ kind: 'keep' })
})

describe('reconnect preserves selection', () => {
  const panes = {
    mirage: [{ pane_id: 1, workspace_id: 'mirage', kind: 'chat' }],
    verde: [{ pane_id: 7, workspace_id: 'verde', kind: 'chat' }],
  }

  test('an open thread keeps its workspace over the snapshot default', () => {
    expect(reconcileViewSelection({
      workspace_id: 'verde',
      pane_id: 7,
      panes_by_workspace: panes,
      workspace_ids: ['mirage', 'verde'],
      snapshot_selected_index: 0,
    })).toEqual({ workspace_id: 'verde', pane_id: 7 })
  })

  test('a focused pane still wins after the selected-workspace id is reset', () => {
    expect(reconcileViewSelection({
      workspace_id: null,
      pane_id: 7,
      panes_by_workspace: panes,
      workspace_ids: ['mirage', 'verde'],
      snapshot_selected_index: 0,
    })).toEqual({ workspace_id: 'verde', pane_id: 7 })
  })

  test('snapshot index is used only when nothing is selected or restorable', () => {
    expect(resolveWorkspaceId({
      workspace_ids: ['mirage', 'verde'],
      snapshot_selected_index: 0,
    })).toBe('mirage')
    expect(resolveWorkspaceId({
      workspace_ids: ['mirage', 'verde'],
      current_workspace_id: 'verde',
      restore_workspace_id: 'verde',
      snapshot_selected_index: 0,
    })).toBe('verde')
  })
})

import { describe, expect, test } from 'bun:test'

import {
  owningWorkspaceId,
  reconcileViewSelection,
  resolveWorkspaceId,
  threadAfterWorkspaceSelect,
  workspaceSelectIntent,
} from './selection'

const catalogs = {
  mirage: [{ local_thread_id: 'mirage-thread' }],
  verde: [{ local_thread_id: 'verde-thread' }],
}

describe('actions sheet uses the thread owning workspace', () => {
  test('ignores the globally selected workspace when the thread lives elsewhere', () => {
    expect(owningWorkspaceId(
      { workspace_id: 'mirage', thread_id: 'verde-thread' },
      catalogs,
    )).toBe('verde')
  })

  test('keeps the pane workspace when it matches the thread catalog', () => {
    expect(owningWorkspaceId(
      { workspace_id: 'verde', thread_id: 'verde-thread' },
      catalogs,
    )).toBe('verde')
  })

  test('falls back to the pane workspace for an opening chat with no catalog row', () => {
    expect(owningWorkspaceId(
      { workspace_id: 'verde', thread_id: 'opening' },
      catalogs,
    )).toBe('verde')
  })
})

describe('workspace switch does not mutate the current thread', () => {
  const thread = {
    workspace_id: 'verde',
    local_thread_id: 'verde-thread',
    title: 'Existing chat',
    profile_id: 'local',
  }

  test('selecting another workspace only requests a new chat', () => {
    expect(workspaceSelectIntent(thread.workspace_id, 'mirage')).toEqual({
      kind: 'open-new-chat',
      workspace_id: 'mirage',
    })
    expect(threadAfterWorkspaceSelect(thread)).toEqual(thread)
  })

  test('reselecting the owning workspace is a no-op', () => {
    expect(workspaceSelectIntent(thread.workspace_id, 'verde')).toEqual({ kind: 'keep' })
    expect(threadAfterWorkspaceSelect(thread)).toEqual(thread)
  })
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

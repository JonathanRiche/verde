import { describe, expect, test } from 'bun:test'

import {
  chatPaneHasLiveTurn,
  findLastChatPane,
  mergeThreadCatalogSettings,
  panesForWorkspace,
  requestTerminalOpen,
} from './store.ts'

describe('findLastChatPane', () => {
  const chats = [
    {
      pane_id: 101,
      workspace_id: 'workspace-1',
      kind: 'chat',
      thread_id: 'thread-1',
      thread_index: 2,
      thread_title: 'First chat',
    },
    {
      pane_id: 202,
      workspace_id: 'workspace-1',
      kind: 'chat',
      thread_id: 'thread-2',
      thread_index: 5,
      thread_title: 'Last chat',
    },
  ]

  test('restores the thread instead of the desktop-focused chat', () => {
    expect(findLastChatPane(chats, {
      workspace_id: 'workspace-1',
      pane_id: 202,
      thread_id: 'thread-2',
    })).toBe(chats[1])
  })

  test('survives a placeholder pane id changing when its thread resolves', () => {
    expect(findLastChatPane(chats, {
      workspace_id: 'workspace-1',
      pane_id: 999,
      thread_index: 5,
      thread_title: 'Last chat',
    })).toBe(chats[1])
  })

  test('resolves the live placeholder before the thread catalog arrives', () => {
    const placeholder = {
      pane_id: 999,
      workspace_id: 'workspace-1',
      kind: 'chat',
      thread_index: 5,
      thread_title: 'Last chat',
    }
    expect(findLastChatPane([placeholder], {
      workspace_id: 'workspace-1',
      pane_id: 202,
      thread_id: 'thread-2',
      thread_index: 5,
      thread_title: 'Last chat',
    })).toBe(placeholder)
  })

  test('does not restore a same-named pane from another workspace', () => {
    expect(findLastChatPane(chats, {
      workspace_id: 'workspace-2',
      pane_id: 202,
      thread_id: 'thread-2',
      thread_title: 'Last chat',
    })).toBeNull()
  })

  test('does not guess between duplicate placeholder titles', () => {
    expect(findLastChatPane([
      ...chats,
      { ...chats[1], pane_id: 303, thread_id: undefined, thread_index: 8 },
    ], {
      workspace_id: 'workspace-1',
      pane_id: 999,
      thread_title: 'Last chat',
    })).toBeNull()
  })
})

describe('chatPaneHasLiveTurn', () => {
  const pane = {
    pane_id: 1,
    workspace_id: 'workspace-1',
    kind: 'chat',
    thread_id: 'thread-1',
  }

  test('does not treat an unacknowledged completion as live work', () => {
    expect(chatPaneHasLiveTurn({ ...pane, completion_pending: true }, false)).toBe(false)
  })

  test('keeps the turn live for a pending send or streaming overlay', () => {
    expect(chatPaneHasLiveTurn({ ...pane, send_pending: true }, false)).toBe(true)
    expect(chatPaneHasLiveTurn(pane, true)).toBe(true)
  })
})

describe('panesForWorkspace', () => {
  test('keeps daemon thread settings ahead of a stale live pane', () => {
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [
        {
          local_thread_id: 'thread-1',
          title: 'New thread',
          sort_index: 0,
          provider: 'codex',
          model_ref: 'gpt-current',
          reasoning_effort: null,
          reasoning_variant: 'max',
          fast_mode: 'on',
        },
      ],
    }
    const stale_live_layout = {
      panes: [
        {
          id: 7,
          kind: 'chat',
          thread: 0,
          title: 'New thread',
          provider: 'claude',
          model: 'old-model',
          reasoning_effort: 'low',
          reasoning_variant: null,
          fast_mode: false,
          send_pending: true,
        },
      ],
    }

    const [pane] = panesForWorkspace(workspace, [], [], new Set(), stale_live_layout)

    expect(pane).toMatchObject({
      provider: 'codex',
      model: 'gpt-current',
      reasoning_effort: null,
      reasoning_variant: 'max',
      fast_mode: true,
      send_pending: true,
    })
  })

  test('keeps an unmatched same-title live pane separate from the current thread', () => {
    const current_thread = {
      local_thread_id: 'thread-current',
      provider_thread_id: 'provider-current',
      title: 'New thread',
      sort_index: 250,
      provider: 'codex',
    }
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [current_thread],
    }
    const live_layout = {
      focused: 901,
      panes: [
        { id: 897, kind: 'chat', thread: 246, title: 'New thread', provider: 'codex' },
        {
          id: 901,
          kind: 'chat',
          thread: 250,
          title: 'New thread',
          provider: 'codex',
          provider_thread_id: 'provider-current',
        },
      ],
    }

    const panes = panesForWorkspace(workspace, [], [], new Set(), live_layout)

    expect(panes).toHaveLength(2)
    expect(panes[0].thread_id).toBeUndefined()
    expect(panes[0].focused).toBe(false)
    expect(panes[1]).toMatchObject({ thread_id: 'thread-current', focused: true })
    expect(panes[0].pane_id).not.toBe(panes[1].pane_id)
  })
})

describe('mergeThreadCatalogSettings', () => {
  test('retains a locally opened thread until it appears in the daemon catalog', () => {
    const existing = { local_thread_id: 'thread-1', title: 'Existing thread' }
    const opening = {
      local_thread_id: 'thread-opening',
      title: 'New thread',
      sort_index: 2,
      committed: false,
      model_ref: 'gpt-selected',
    }

    const merged = mergeThreadCatalogSettings(
      'workspace-1',
      [existing],
      undefined,
      [opening, existing],
      new Set([opening.local_thread_id]),
    )

    expect(merged).toEqual([opening, existing])
  })
})

describe('requestTerminalOpen', () => {
  const workspace = { workspace_id: 'workspace-1', path: '/workspace' }

  test('uses the native desktop terminal operation when available', async () => {
    const calls = []
    const result = await requestTerminalOpen(async (method, params) => {
      calls.push({ method, params })
      return { id: 1, result: { panes: [] } }
    }, workspace, 'fallback-session')

    expect(result.native).toBe(true)
    expect(calls).toEqual([
      { method: 'terminal.open', params: { workspace_id: 'workspace-1' } },
    ])
  })

  test('falls back to a daemon session only when terminal.open is unavailable', async () => {
    const calls = []
    const result = await requestTerminalOpen(async (method, params) => {
      calls.push({ method, params })
      if (method === 'terminal.open') {
        return { id: 1, error: { code: 'method_not_found', message: method } }
      }
      return { id: 2, result: { created: true } }
    }, workspace, 'fallback-session')

    expect(result.native).toBe(false)
    expect(calls).toEqual([
      { method: 'terminal.open', params: { workspace_id: 'workspace-1' } },
      {
        method: 'session.create',
        params: {
          id: 'fallback-session',
          cwd: '/workspace',
          workspace_path: '/workspace',
          workspace_id: 'workspace-1',
          label: 'Terminal',
        },
      },
    ])
  })

  test('does not hide a native terminal rejection behind the headless fallback', async () => {
    const calls = []
    const result = await requestTerminalOpen(async (method, params) => {
      calls.push({ method, params })
      return { id: 1, error: { code: 'rejected', message: 'could not open terminal' } }
    }, workspace, 'fallback-session')

    expect(result.native).toBe(true)
    expect(result.response.error?.code).toBe('rejected')
    expect(calls).toHaveLength(1)
  })
})

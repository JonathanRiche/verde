import { describe, expect, test } from 'bun:test'

import { findLastChatPane, lastDeliveredTailSeq, mapTranscriptRows, fetchTranscriptPage, prependTranscriptPage, mergeThreadCatalogSettings, panesForWorkspace, requestPaneClose, requestTerminalOpen } from './store.ts'

describe('fetchTranscriptPage', () => {
  test('falls back to a legacy full get only when pagination is unsupported', async () => {
    const page = await fetchTranscriptPage(async method => method === 'chat.message.list'
      ? { error: { code: 'method_not_found', message: 'unknown' } }
      : { result: { thread: { messages: [{ message_id: 'legacy', body: 'from get' }] } } },
    { workspace_id: 'ws', local_thread_id: 'thread' })
    expect(page.messages).toMatchObject([{ message_id: 'legacy', body: 'from get' }])
    expect(page.cursor).toBeNull()
  })
  test('persistent page failure remains retryable without silently returning an empty transcript', async () => {
    await expect(fetchTranscriptPage(async method => {
      expect(method).toBe('chat.message.list')
      return { error: { code: 'unavailable', message: 'offline' } }
    }, { workspace_id: 'ws', local_thread_id: 'thread' })).rejects.toThrow('offline')
  })
  test('blank legacy IDs use stable sort indexes across pages', () => {
    const older = mapTranscriptRows({ messages: [{ message_id: '', sort_index: 1, body: 'same' }] }, 'thread')
    const newer = mapTranscriptRows({ messages: [{ message_id: '', sort_index: 2, body: 'same' }] }, 'thread')
    expect(prependTranscriptPage(older, newer).map(row => row.message_id)).toEqual(['thread-1', 'thread-2'])
  })
})

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

  test('does not restore a same-named pane from another workspace', () => {
    expect(findLastChatPane(chats, {
      workspace_id: 'workspace-2',
      pane_id: 202,
      thread_id: 'thread-2',
      thread_title: 'Last chat',
    })).toBeNull()
  })

})

test('lastDeliveredTailSeq never advances to the daemon next unused sequence', () => {
  expect(lastDeliveredTailSeq(5, [{ seq: 6 }], 6)).toBe(6)
  // Older daemons without page_last_seq: greatest delivered event.
  expect(lastDeliveredTailSeq(5, [{ seq: 6 }, { seq: 7 }])).toBe(7)
  expect(lastDeliveredTailSeq(7, [])).toBe(7)
})

describe('panesForWorkspace', () => {
  test('binds layout panes to visible ordinals across sort_index gaps', () => {
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [
        { local_thread_id: 'a', title: 'A', sort_index: 0, open: true },
        { local_thread_id: 'b', title: 'B', sort_index: 3, open: true },
        { local_thread_id: 'closed', title: 'Closed', sort_index: 4, open: false },
        { local_thread_id: 'busy', title: 'Busy', sort_index: 5, open: false },
        { local_thread_id: 'pm', title: 'Project Manager', sort_index: 7, open: true },
        { local_thread_id: 'late', title: 'Late', sort_index: 18, open: true },
      ],
      workspace_layout_json: JSON.stringify({
        panes: [0, 1, 2, 3, 4].map((thread) => ({ id: thread + 1, kind: 'chat', thread })),
      }),
    }
    const turns = [{ workspace_id: 'workspace-1', local_thread_id: 'busy', status: 'running' }]

    const titles = panesForWorkspace(workspace, [], turns, new Set()).map((pane) => pane.thread_title)

    expect(titles).toEqual(['A', 'B', 'Busy', 'Project Manager', 'Late'])
  })

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

  test('projects duplicate live panes for one thread as a single chat', () => {
    const thread = {
      local_thread_id: 'thread-current',
      provider_thread_id: 'provider-current',
      title: 'Current thread',
      sort_index: 250,
      provider: 'codex',
    }
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [thread],
    }
    const live_layout = {
      focused: 901,
      panes: [
        {
          id: 897,
          kind: 'chat',
          thread: 250,
          title: 'Current thread',
          provider_thread_id: 'provider-current',
          send_pending: true,
        },
        {
          id: 901,
          kind: 'chat',
          thread: 250,
          title: 'Current thread',
          provider_thread_id: 'provider-current',
          send_pending: false,
          completion_pending: true,
        },
      ],
    }

    const panes = panesForWorkspace(workspace, [], [], new Set(), live_layout)

    expect(panes).toHaveLength(1)
    expect(panes[0]).toMatchObject({
      thread_id: 'thread-current',
      native_pane_id: 901,
      focused: true,
      send_pending: true,
      completion_pending: true,
    })
  })

  test('binds a live pane by local_thread_id when title and index have drifted', () => {
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [
        {
          local_thread_id: 'thread-1',
          title: 'Automatic Title',
          sort_index: 12,
          provider: 'codex',
        },
      ],
    }
    const live_layout = {
      panes: [{
        id: 7,
        kind: 'chat',
        thread: 0,
        title: 'New thread',
        local_thread_id: 'thread-1',
        provider: 'codex',
      }],
    }

    const [pane] = panesForWorkspace(workspace, [], [], new Set(), live_layout)

    expect(pane).toMatchObject({ thread_id: 'thread-1', thread_title: 'Automatic Title' })
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

describe('requestPaneClose', () => {
  test('native pane identity cannot create a desktop transport route', async () => {
    const response = await requestPaneClose(async () => { throw new Error('unexpected RPC') },
      'workspace-1', { kind: 'chat', native_pane_id: 42 })
    expect(response.error?.message).toBe('This pane has no running session to close.')
  })

  test('reports unavailable instead of archiving a detached chat', async () => {
    const response = await requestPaneClose(async () => {
      throw new Error('unexpected call')
    }, 'workspace-1', { kind: 'chat' })

    expect(response.error?.code).toBe('capability_unavailable')
  })
})

import { describe, expect, test } from 'bun:test'

import {
  chatPaneHasLiveTurn,
  clipboardImageFiles,
  findLastChatPane,
  isAbsentDaemonThread,
  lastDeliveredTailSeq,
  layoutFromLivePanes,
  carryLiveChatIdentity,
  mapTranscriptRows,
  fetchTranscriptPage,
  prependTranscriptPage,
  mergeThreadCatalogSettings,
  panesForWorkspace,
  parseFavoriteModels,
  requestPaneClose,
  requestTerminalOpen,
  setFavoriteModelInList,
  threadFromDaemonGet,
  mergeThreadMetadata,
} from './store.ts'
import { adjacentPaneInGroups, workspacePaneGroups } from './types.ts'

describe('scrolling tile groups', () => {
  const panes = [
    { pane_id: 101, native_pane_id: 1, scroll_group_id: 1, workspace_id: 'w', kind: 'chat' },
    { pane_id: 102, native_pane_id: 2, scroll_group_id: 1, workspace_id: 'w', kind: 'terminal' },
    { pane_id: 103, native_pane_id: 3, workspace_id: 'w', kind: 'chat' },
  ]
  const root = {
    split: {
      axis: 'vertical',
      ratio: 0.6,
      first: {
        split: {
          axis: 'horizontal',
          ratio: 0.4,
          first: { leaf: 1 },
          second: { leaf: 2 },
        },
      },
      second: { leaf: 3 },
    },
  }

  test('preserves live root and scrolling group ids', () => {
    const layout = layoutFromLivePanes({ result: {
      focused_pane_id: 2,
      panes: [
        { pane_id: 1, kind: 'chat', thread_index: 0, scroll_group: 1 },
        { pane_id: 2, kind: 'terminal', dock_id: 7, scroll_group: 1 },
      ],
      root,
    } })

    expect(layout).toMatchObject({
      focused: 2,
      panes: [{ id: 1, scroll_group: 1 }, { id: 2, scroll_group: 1 }],
      root,
    })
  })

  test('renders a nested group as one strip item and keeps the standalone pane separate', () => {
    const groups = workspacePaneGroups(panes, root)

    expect(groups).toHaveLength(2)
    expect(groups[0].panes.map((pane) => pane.pane_id)).toEqual([101, 102])
    expect(groups[0].layout).toEqual({
      split: {
        axis: 'horizontal',
        ratio: 0.4,
        first: { leaf: 101 },
        second: { leaf: 102 },
      },
    })
    expect(groups[1].layout).toEqual({ leaf: 103 })
  })

  test('directional focus follows inner split geometry before the scrolling strip', () => {
    const groups = workspacePaneGroups(panes, root)

    expect(adjacentPaneInGroups(groups, 101, 'down')).toBe(102)
    expect(adjacentPaneInGroups(groups, 102, 'up')).toBe(101)
    expect(adjacentPaneInGroups(groups, 101, 'right')).toBe(103)
  })
})

describe('shared model favorites', () => {
  test('parses, trims, and deduplicates the config snapshot', () => {
    expect(parseFavoriteModels({
      chat: {
        favorite_models: [
          { provider: 'codex', model: 'gpt-5.6-sol' },
          { provider: ' codex ', model: ' gpt-5.6-sol ' },
          { provider: 'claude', model: 'opus' },
          { provider: '', model: 'ignored' },
        ],
      },
    })).toEqual([
      { provider: 'codex', model: 'gpt-5.6-sol' },
      { provider: 'claude', model: 'opus' },
    ])
  })

  test('applies an idempotent requested favorite state', () => {
    const original = [{ provider: 'codex', model: 'gpt-5.6-sol' }]
    expect(setFavoriteModelInList(original, 'codex', 'gpt-5.6-sol', true)).toBe(original)
    expect(setFavoriteModelInList(original, 'codex', 'gpt-5.6-sol', false)).toEqual([])
    expect(setFavoriteModelInList(original, 'claude', 'opus', true)).toEqual([
      ...original,
      { provider: 'claude', model: 'opus' },
    ])
  })
})

describe('clipboardImageFiles', () => {
  test('returns every supported clipboard image and ignores text items', () => {
    const png = new File(['png'], 'screenshot.png', { type: 'image/png' })
    const webp = new File(['webp'], 'second.webp', { type: 'image/webp' })
    const data = {
      items: [
        { kind: 'string', getAsFile: () => null },
        { kind: 'file', getAsFile: () => png },
        { kind: 'file', getAsFile: () => webp },
      ],
      files: [png, webp],
    }

    expect(clipboardImageFiles(data)).toEqual([png, webp])
  })

  test('falls back to the clipboard file list', () => {
    const jpeg = new File(['jpeg'], 'clipboard.jpg', { type: 'image/jpeg' })
    const text = new File(['text'], 'notes.txt', { type: 'text/plain' })

    expect(clipboardImageFiles({ items: [], files: [jpeg, text] })).toEqual([jpeg])
  })
})

describe('mapTranscriptRows', () => {
  test('preserves every image when normalizing a snapshot thread', () => {
    const images = [
      { path: '/tmp/first.png', mime: 'image/png', byte_size: 101 },
      { path: '/tmp/second.webp', mime: 'image/webp', byte_size: 202 },
    ]

    const [message] = mapTranscriptRows({
      thread: {
        messages: [{
          message_id: 'message-1',
          role: 'user',
          author: 'You',
          body: 'Compare these',
          images,
          created_at_ms: 1234,
        }],
      },
    }, 'thread-1')

    expect(message.images).toEqual(images.map((image) => ({ ...image, attachment_id: null })))
    expect(message.created_at_ms).toBe(1234)
  })

  test('preserves a legacy single image attachment', () => {
    const image = { path: '/tmp/legacy.jpg', mime: 'image/jpeg', byte_size: 303 }
    const [message] = mapTranscriptRows({
      thread: {
        messages: [{ role: 'user', author: 'You', body: '', image }],
      },
    }, 'thread-legacy')

    expect(message.images).toEqual([{ ...image, attachment_id: null }])
  })

  test('reads a chat.message.list page the same way as thread.get', () => {
    const [message] = mapTranscriptRows({
      result: {
        messages: [{ message_id: 'm1', role: 'user', author: 'You', body: 'Hi' }],
        next_cursor: 'b:1',
      },
    }, 'thread-1')
    expect(message).toMatchObject({ message_id: 'm1', body: 'Hi' })
  })
})

describe('fetchTranscriptPage', () => {
  test('returns the recent tail after one request and leaves the older cursor lazy', async () => {
    const calls = []
    const page = await fetchTranscriptPage(async (method, params) => {
      calls.push({ method, params })
      return { result: { messages: [{ message_id: 'new', body: 'recent' }], next_cursor: 'b:2' } }
    }, { workspace_id: 'ws', local_thread_id: 'thread' })
    expect(calls).toEqual([{ method: 'chat.message.list', params: { workspace_id: 'ws', local_thread_id: 'thread', direction: 'backward', limit: 40 } }])
    expect(page.messages.map(row => row.message_id)).toEqual(['new'])
    expect(page.cursor).toBe('b:2')
  })
  test('falls back to a legacy full get only when pagination is unsupported', async () => {
    const page = await fetchTranscriptPage(async method => method === 'chat.message.list'
      ? { error: { code: 'method_not_found', message: 'unknown' } }
      : { result: { thread: { messages: [{ message_id: 'legacy', body: 'from get' }] } } },
    { workspace_id: 'ws', local_thread_id: 'thread' })
    expect(page.messages).toMatchObject([{ message_id: 'legacy', body: 'from get' }])
    expect(page.cursor).toBeNull()
  })
  test('shrinks oversized pages, and restores the limit for an explicit older request', async () => {
    const limits = []
    const call = async (method, params) => {
      expect(method).toBe('chat.message.list')
      limits.push(params.limit)
      if (!params.cursor && params.limit > 1) return { ok: false, error: { code: 'unavailable' } }
      return { result: { messages: [{ message_id: params.cursor ? 'old' : 'huge', body: 'fits' }], next_cursor: params.cursor ? null : 'b:older' } }
    }
    const args = { workspace_id: 'ws', local_thread_id: 'thread' }
    const first = await fetchTranscriptPage(call, args)
    expect(limits).toEqual([40, 20, 10, 5, 2, 1])
    expect(first.cursor).toBe('b:older')
    const older = await fetchTranscriptPage(call, args, first.cursor)
    expect(limits.at(-1)).toBe(40)
    expect(older.messages[0].message_id).toBe('old')
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

describe('lastDeliveredTailSeq', () => {
  test('does not advance to the daemon next unused sequence', () => {
    const response = {
      events: [{ seq: 6 }],
      page_last_seq: 6,
      next_seq: 7,
    }

    expect(lastDeliveredTailSeq(5, response.events, response.page_last_seq)).toBe(6)
  })

  test('falls back to the greatest delivered event for older daemons', () => {
    expect(lastDeliveredTailSeq(5, [{ seq: 6 }, { seq: 7 }])).toBe(7)
    expect(lastDeliveredTailSeq(7, [])).toBe(7)
  })
})

describe('panesForWorkspace', () => {
  test('shows open committed chats started by another web client', () => {
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [
        { local_thread_id: 'desktop-thread', title: 'Desktop', sort_index: 0, open: true },
        { local_thread_id: 'web-thread-other', title: 'Other browser', sort_index: 1, open: true, committed: true },
        { local_thread_id: 'web-thread-closed', title: 'Closed', sort_index: 2, open: false, committed: true },
        { local_thread_id: 'web-thread-draft', title: 'New Chat', sort_index: 3, open: true, committed: false },
        { local_thread_id: 'cli-thread-stale', title: 'Stale MCP child', sort_index: 4, open: true, committed: true },
      ],
    }
    const layout = { panes: [{ id: 1, kind: 'chat', thread: 0, title: 'Desktop' }] }

    const titles = panesForWorkspace(workspace, [], [], new Set(), layout).map((pane) => pane.thread_title)

    expect(titles).toEqual(['Desktop', 'Other browser'])
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

  test('projects an automatic title over a stale live placeholder', () => {
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [
        {
          local_thread_id: 'thread-1',
          title: 'Automatic Thread Title',
          sort_index: 0,
          provider: 'codex',
        },
      ],
    }
    const stale_live_layout = {
      panes: [{ id: 7, kind: 'chat', thread: 0, title: 'New thread', provider: 'codex' }],
    }

    const [pane] = panesForWorkspace(
      workspace,
      [],
      [],
      new Set(['thread-1']),
      stale_live_layout,
    )

    expect(pane).toMatchObject({
      thread_id: 'thread-1',
      thread_title: 'Automatic Thread Title',
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

describe('carryLiveChatIdentity', () => {
  test('keeps thread ids when a later live tick omits them', () => {
    const previous = [{
      id: 7,
      kind: 'chat',
      thread: 0,
      title: 'New thread',
      local_thread_id: 'thread-1',
      provider_thread_id: 'provider-1',
    }]
    const next = [{
      id: 7,
      kind: 'chat',
      thread: 0,
      title: 'New thread',
    }]

    expect(carryLiveChatIdentity(previous, next)).toEqual([{
      id: 7,
      kind: 'chat',
      thread: 0,
      title: 'New thread',
      local_thread_id: 'thread-1',
      provider_thread_id: 'provider-1',
    }])
  })

  test('does not invent identity for a different native pane', () => {
    const previous = [{ id: 7, kind: 'chat', local_thread_id: 'thread-1' }]
    const next = [{ id: 8, kind: 'chat', title: 'New thread' }]
    expect(carryLiveChatIdentity(previous, next)[0].local_thread_id).toBeUndefined()
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

describe('opening-thread daemon get', () => {
  test('treats a missing daemon row as the opening-thread case', () => {
    expect(isAbsentDaemonThread({
      ok: false,
      error: { code: 'resource_not_found', message: 'resource not found' },
    })).toBe(true)
    expect(isAbsentDaemonThread({
      error: { code: 'not_found', message: 'thread is not on the daemon' },
    })).toBe(true)
    expect(isAbsentDaemonThread({
      ok: false,
      error: { code: 'store_unavailable', message: 'store is unavailable' },
    })).toBe(false)
    expect(isAbsentDaemonThread({ result: { thread: { local_thread_id: 't1' } } })).toBe(false)
  })

  test('does not invent a thread from a failed get', () => {
    expect(threadFromDaemonGet({
      ok: false,
      error: { code: 'resource_not_found', message: 'resource not found' },
    })).toBeNull()
    expect(threadFromDaemonGet({
      result: { thread: { local_thread_id: 'thread-1', title: 'New thread', committed: false } },
    })).toMatchObject({ local_thread_id: 'thread-1', committed: false })
  })
})

describe('mergeThreadMetadata', () => {
  test('keeps catalog fields and drops transcript bodies', () => {
    const merged = mergeThreadMetadata(
      {
        local_thread_id: 'chat-1',
        title: "I'm starting a new venture with my family.",
        committed: true,
        provider: 'codex',
        provider_thread_id: 'thr_abc',
        messages: [{ message_id: 'huge', role: 'assistant', author: 'Codex', body: 'x'.repeat(100) }],
      },
      { profile_id: 'local' },
    )
    expect(merged).toMatchObject({
      local_thread_id: 'chat-1',
      title: "I'm starting a new venture with my family.",
      committed: true,
      provider: 'codex',
      provider_thread_id: 'thr_abc',
      profile_id: 'local',
    })
    expect(merged.messages).toBeUndefined()
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

describe('requestPaneClose', () => {
  test('native pane identity cannot create a desktop transport route', async () => {
    const response = await requestPaneClose(async () => { throw new Error('unexpected RPC') },
      'workspace-1', { kind: 'chat', native_pane_id: 42 })
    expect(response.error?.message).toBe('Available in the desktop app')
  })

  test('a daemon terminal session can close even with a native pane identity', async () => {
    const calls = []
    await requestPaneClose(async (method, params) => {
      calls.push({ method, params })
      return { result: { stopped: true } }
    }, 'workspace-1', { kind: 'terminal', native_pane_id: 42, session_id: 'session-1' })
    expect(calls).toEqual([{ method: 'session.kill', params: { id: 'session-1' } }])
  })

  test('falls back to killing a detached terminal session', async () => {
    const calls = []
    await requestPaneClose(async (method, params) => {
      calls.push({ method, params })
      return { id: 1, result: { stopped: true } }
    }, 'workspace-1', { kind: 'terminal', session_id: 'session-1' })

    expect(calls).toEqual([
      { method: 'session.kill', params: { id: 'session-1' } },
    ])
  })

  test('reports unavailable instead of archiving a detached chat', async () => {
    const response = await requestPaneClose(async () => {
      throw new Error('unexpected call')
    }, 'workspace-1', { kind: 'chat' })

    expect(response.error?.code).toBe('capability_unavailable')
  })
})

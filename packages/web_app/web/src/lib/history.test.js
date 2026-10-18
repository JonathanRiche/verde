import { expect, test } from 'bun:test'
import { createHistoryApi } from './history'

const now = 2_000_000
const thread = (id, at) => ({ local_thread_id: id, workspace_id: 'ws', title: id, open: false, last_activity_at: at })

function fixture(responses) {
  const calls = [], notices = [], changed = [], reopened = []
  const api = createHistoryApi({
    call: async (method, params) => {
      calls.push({ method, params })
      const response = responses.shift()
      if (response instanceof Error) throw response
      if (!response) throw new Error('Unexpected RPC')
      return response
    },
    mutation: async () => ({ client_id: 'client', request_key: 'request' }),
    notice: (value) => notices.push(value),
    threadChanged: (...args) => changed.push(args),
    workspaceReopened: (value) => reopened.push(value),
  })
  return { api, calls, notices, changed, reopened }
}
const ok = (result) => ({ result })

test('pagination failure does not return a misleading partial history', async () => {
  const f = fixture([ok({ threads: [], next_cursor: 'same' }), ok({ threads: [], next_cursor: 'same' })])
  expect(await f.api.loadHistory('ws')).toBeNull()
  expect(f.notices.at(-1)).toContain('cursor')
})

for (const archived of [false, true]) {
  test(`${archived ? 'archive' : 'reopen'} uses a guarded bounded mutation without reading or writing metadata`, async () => {
    const f = fixture([ok({ store_revision: 42 }), ok({ applied: true, store_revision: 43 })])
    expect(await f.api[archived ? 'archiveThread' : 'openHistoryThread']('ws', 'a')).toBe(true)
    expect(f.calls).toEqual([
      { method: 'daemon.storeStatus', params: {} },
      { method: 'chat.thread.archive.set', params: {
        mutation: { client_id: 'client', request_key: 'request', expected_store_revision: 42 },
        workspace_id: 'ws', local_thread_id: 'a', archived,
      } },
    ])
    expect(f.changed).toEqual([['ws', { local_thread_id: 'a', archived }, 43]])
  })
}

test('workspace reopen reads full metadata instead of upserting a list summary', async () => {
  const saved = { workspace_id: 'ws', archived: true, label: 'Saved', path: '/repo', workspace_layout_json: 'layout', herdr_link: { session_name: 'saved' }, threads: [], messages: [] }
  const f = fixture([ok({ snapshot: { workspaces: [saved] }, store_revision: 9 }), ok({ applied: true })])
  expect(await f.api.reopenWorkspace('ws')).toBe(true)
  expect(f.calls[0]).toEqual({ method: 'core.snapshot', params: { workspace_id: 'ws', scopes: ['workspaces'] } })
  expect(f.calls[1].params.workspace).toEqual({ workspace_id: 'ws', archived: false, label: 'Saved', path: '/repo', workspace_layout_json: 'layout', herdr_link: { session_name: 'saved' } })
  expect(f.calls[1].params.mutation.expected_store_revision).toBe(9)
  expect(f.reopened).toHaveLength(1)
})

test('missing identities cannot create replacement records', async () => {
  const f = fixture([
    ok({ store_revision: 1 }), { error: { code: 'resource_not_found', message: 'Saved thread not found' } },
    ok({ snapshot: { workspaces: [] } }),
  ])
  expect(await f.api.openHistoryThread('ws', 'a')).toBe(false)
  expect(await f.api.reopenWorkspace('ws')).toBe(false)
  expect(f.calls).toHaveLength(3)
  expect(f.changed).toEqual([])
  expect(f.reopened).toEqual([])
})

test('empty workspace scope cannot become a cross-workspace history query', async () => {
  const f = fixture([])
  expect(await f.api.loadHistory('')).toBeNull()
  expect(await f.api.openHistoryThread('', 'a')).toBe(false)
  expect(await f.api.reopenWorkspace('')).toBe(false)
  expect(f.calls).toEqual([])
})

test('missing revision refuses an unguarded metadata write', async () => {
  const f = fixture([ok({ thread: thread('a', now) })])
  expect(await f.api.archiveThread('ws', 'a')).toBe(false)
  expect(f.calls).toHaveLength(1)
  expect(f.notices.at(-1)).toBe('Missing thread store revision')
})

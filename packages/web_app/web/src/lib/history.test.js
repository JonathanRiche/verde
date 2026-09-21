import { describe, expect, test } from 'bun:test'
import { createHistoryApi, groupHistory, reconcileHistoryArchives, registerHistoryClient } from './history'

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

describe('history grouping', () => {
  test('uses desktop rolling boundaries, seconds, descending order, and no mutation', () => {
    const rows = [thread('older', now - 604800), thread('week', now - 86400), thread('today', now - 86399), thread('future', now + 1), thread('unknown', null)]
    const original = [...rows]
    expect(groupHistory(rows, now).map((group) => [group.label, group.threads.map((row) => row.local_thread_id)]))
      .toEqual([['Today', ['future', 'today']], ['This week', ['week']], ['Older', ['older', 'unknown']]])
    expect(rows).toEqual(original)
    expect(groupHistory([], now)).toEqual([])
  })
})

test('closed history follows opaque cursors with the same query', async () => {
  const f = fixture([ok({ threads: [thread('a', now)], next_cursor: 'opaque' }), ok({ threads: [thread('b', now)], next_cursor: null })])
  expect((await f.api.loadHistory('ws')).map((row) => row.local_thread_id)).toEqual(['a', 'b'])
  expect(f.calls[1]).toEqual({ method: 'chat.thread.list', params: { workspace_id: 'ws', open: false, recent_first: true, limit: 100, cursor: 'opaque' } })
})

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

test('RPC and transport errors go through notices without publishing changes', async () => {
  const f = fixture([ok({ store_revision: 1 }), { error: { message: 'revision conflict' } }, new Error('offline')])
  expect(await f.api.archiveThread('ws', 'a')).toBe(false)
  expect(f.notices.at(-1)).toBe('revision conflict')
  expect(f.changed).toEqual([])
  expect(await f.api.listArchivedWorkspaces()).toBeNull()
  expect(f.notices.at(-1)).toBe('offline')
})

test('older daemons get an update notice with no lossy fallback', async () => {
  const f = fixture([ok({ store_revision: 1 }), { error: { code: 'method_not_found' } }])
  expect(await f.api.archiveThread('ws', 'a')).toBe(false)
  expect(f.notices.at(-1)).toBe('update Verde to archive from the web')
  expect(f.calls).toHaveLength(2)
  expect(f.changed).toEqual([])
})

test('archived workspace listing paginates before filtering', async () => {
  const f = fixture([ok({ workspaces: [{ workspace_id: 'active', archived: false }], next_cursor: 'next' }), ok({ workspaces: [{ workspace_id: 'closed', archived: true }] })])
  expect(await f.api.listArchivedWorkspaces()).toEqual([{ workspace_id: 'closed', archived: true }])
  expect(f.calls[1].params).toMatchObject({ include_archived: true, cursor: 'next' })
})

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

test('another client reopening a thread clears suppression only from a newer successful read', () => {
  const pending = new Map([['ws\u0000a', 42], ['other\u0000a', 42]])
  const reopened = [{ ...thread('a', now), archived: false, open: true }]
  reconcileHistoryArchives(pending, 'ws', reopened, 41)
  reconcileHistoryArchives(pending, 'ws', reopened, 42)
  reconcileHistoryArchives(pending, 'ws', reopened, undefined)
  expect(pending.size).toBe(2)
  reconcileHistoryArchives(pending, 'ws', [{ ...reopened[0], archived: true }], 43)
  reconcileHistoryArchives(pending, 'ws', [{ ...reopened[0], open: false }], 43)
  expect(pending.size).toBe(2)
  reconcileHistoryArchives(pending, 'ws', reopened, 44)
  expect([...pending.keys()]).toEqual(['other\u0000a'])
})

test('client registration propagates rejection and never fabricates an identity', async () => {
  for (const response of [{ error: { message: 'forbidden' } }, { ok: false }, ok({}), ok({ client_id: 7 })]) {
    await expect(registerHistoryClient(async () => response)).rejects.toThrow()
  }
  await expect(registerHistoryClient(async () => { throw new Error('offline') })).rejects.toThrow('offline')
  expect(await registerHistoryClient(async () => ok({ client_id: 'registered' }))).toBe('registered')
})

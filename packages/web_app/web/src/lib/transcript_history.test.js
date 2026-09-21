import { expect, test } from 'bun:test'
import { createTranscriptHistory, mergeTranscriptPage, reconcileOptimisticMessages } from './transcript_history'
const message = (id, body = id) => ({ message_id: id, role: 'assistant', author: 'Codex', body })
const page = (ids, cursor = null) => ({ messages: ids.map(id => message(id)), cursor })
function fixture(fetch) {
  let messages = [], identity = 'a'
  const api = createTranscriptHistory({ read: () => messages, write: (_, value) => { messages = value } })
  const context = (id = identity) => ({ key: 'pane', identity: id, current: () => identity === id, fetch })
  return { api, context, messages: () => messages, setMessages: value => { messages = value }, route: value => { identity = value }, state: () => api.state('pane', identity) }
}
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }

test('initial load publishes only recent messages; older history is explicitly requested and retains objects', async () => {
  const calls = []
  const f = fixture(async cursor => { calls.push(cursor); return cursor ? page(['old', 'recent']) : page(['recent'], 'older') })
  await f.api.load(f.context())
  expect(calls).toEqual([undefined])
  expect(f.state()).toMatchObject({ loaded: true, hasOlder: true, loading: false })
  const recent = f.messages()[0]
  await f.api.loadOlder(f.context())
  expect(calls).toEqual([undefined, 'older'])
  expect(f.messages().map(row => row.message_id)).toEqual(['old', 'recent'])
  expect(f.messages()[1]).toBe(recent)
  expect(f.state().hasOlder).toBe(false)
})

test('failed older request preserves the cursor and loaded history for retry', async () => {
  let failing = true
  const f = fixture(async cursor => { if (cursor && failing) throw new Error('offline'); return cursor ? page(['old']) : page(['new'], 'older') })
  await f.api.load(f.context())
  await f.api.loadOlder(f.context())
  expect(f.state()).toMatchObject({ hasOlder: true, loadingOlder: false, olderError: 'offline' })
  expect(f.messages().map(row => row.message_id)).toEqual(['new'])
  failing = false
  await f.api.loadOlder(f.context())
  expect(f.state()).toMatchObject({ hasOlder: false, olderError: null })
  expect(f.messages().map(row => row.message_id)).toEqual(['old', 'new'])
})

test('refresh preserves expanded history and its oldest cursor', async () => {
  let refreshed = false
  const calls = []
  const f = fixture(async cursor => {
    calls.push(cursor)
    if (cursor === 'oldest') return page(['oldest'])
    if (cursor) return page(['older'], 'oldest')
    return refreshed ? page(['recent', 'latest'], 'wrong-new-cursor') : page(['recent'], 'older')
  })
  await f.api.load(f.context()); await f.api.loadOlder(f.context())
  refreshed = true
  await f.api.load(f.context()); await f.api.loadOlder(f.context())
  expect(calls.at(-1)).toBe('oldest')
  expect(f.messages().map(row => row.message_id)).toEqual(['oldest', 'older', 'recent', 'latest'])
})

test('refresh bridges new-page gaps to the cached tail without losing older history', async () => {
  let refreshing = false
  const f = fixture(async cursor => !refreshing ? page(['m0'], 'older')
    : cursor === 'gap' ? page(['m0', 'm1'], 'older') : page(['m2'], 'gap'))
  await f.api.load(f.context())
  refreshing = true
  await f.api.load(f.context())
  expect(f.messages().map(row => row.message_id)).toEqual(['m0', 'm1', 'm2'])
  expect(f.state().hasOlder).toBe(true)
})

test('failed gap catch-up leaves the cache intact and retries the whole refresh', async () => {
  let refreshing = false, failing = true
  const f = fixture(async cursor => {
    if (!refreshing) return page(['m0'])
    if (cursor && failing) throw new Error('offline')
    return cursor ? page(['m0', 'm1']) : page(['m2'], 'gap')
  })
  await f.api.load(f.context()); refreshing = true
  await f.api.load(f.context())
  expect(f.messages().map(row => row.message_id)).toEqual(['m0'])
  expect(f.state().error).toBe('offline')
  failing = false
  await f.api.load(f.context())
  expect(f.messages().map(row => row.message_id)).toEqual(['m0', 'm1', 'm2'])
})

test('a previously empty transcript acquires a cursor when a long turn commits', async () => {
  let initial = true
  const f = fixture(async () => initial ? page([]) : page(['tail'], 'older'))
  await f.api.load(f.context()); initial = false; await f.api.load(f.context())
  expect(f.state().hasOlder).toBe(true)
})

test('route changes discard stale responses and scope errors/loading independently', async () => {
  const old = deferred()
  const f = fixture(async () => old.promise)
  const pending = f.api.load(f.context())
  f.route('b')
  await f.api.load({ ...f.context(), fetch: async () => page(['route-b']) })
  old.resolve(page(['route-a'], 'old-cursor')); await pending
  expect(f.messages().map(row => row.message_id)).toEqual(['route-b'])
  expect(f.state()).toMatchObject({ loading: false, hasOlder: false, error: null })
})

test('forced terminal refresh waits for an in-flight initial fetch then requests committed rows', async () => {
  const first = deferred()
  let calls = 0
  const f = fixture(async () => ++calls === 1 ? first.promise : page(['before', 'committed']))
  const initial = f.api.load(f.context())
  const terminal = f.api.load(f.context(), true)
  first.resolve(page(['before']))
  await Promise.all([initial, terminal])
  expect(calls).toBe(2)
  expect(f.messages().map(row => row.message_id)).toEqual(['before', 'committed'])
})

test('durable refresh reconciles only captured optimistic sends confirmed by new user rows', () => {
  const optimistic = { message_id: 'local-user-one', role: 'user', body: 'same', created_at_ms: 5000 }
  const newer = { ...optimistic, message_id: 'local-user-two' }
  const durable = { ...optimistic, message_id: 'durable' }
  expect(reconcileOptimisticMessages([optimistic, newer], [durable], [optimistic])).toEqual([newer])
  expect(reconcileOptimisticMessages([optimistic], [{ ...durable, created_at_ms: 100 }], [optimistic])).toEqual([optimistic])
})

test('image send confirmation ignores upload UI fields and recognizes a snapshot-confirmed row', () => {
  const optimistic = { message_id: 'local-user-image', role: 'user', body: 'look', created_at_ms: 5000,
    images: [{ path: '/upload/image.png', mime: 'image/png', byte_size: 100, name: 'Screenshot.png', attachment_id: 'upload-id' }] }
  const durable = { ...optimistic, message_id: 'durable-image', images: [{ path: '/upload/image.png', mime: 'image/png', byte_size: 100 }] }
  expect(reconcileOptimisticMessages([optimistic], [durable], [optimistic])).toEqual([])
  expect(reconcileOptimisticMessages([optimistic, durable], [durable], [optimistic, durable])).toEqual([durable])
  expect(reconcileOptimisticMessages([durable, optimistic], [durable], [durable, optimistic])).toEqual([durable, optimistic])
})

test('identical bodies at different IDs survive prepend without borrowing the wrong identity', () => {
  const newer = message('new', 'same')
  const merged = mergeTranscriptPage([newer], [message('old', 'same')], 'new')
  expect(merged.map(row => row.message_id)).toEqual(['old', 'new'])
  expect(merged[1]).toBe(newer)
})

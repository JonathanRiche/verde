import { describe, expect, test } from 'bun:test'
import { FOLLOWUP_CACHE_KEY, followupImages, createFollowupApi, followupKind, steerCanFallback, followupRpcError, FollowupRejectedError } from './followups'

const pane = { kind: 'chat', workspace_id: 'w', thread_id: 't', pane_id: 1 }
const image = { path: '/tmp/image.png', mime: 'image/png' }
function fixture(overrides = {}) {
  const calls = [], starts = [], notices = [], restored = []
  let active = 'turn-1', busy = false, id = 0
  const api = createFollowupApi({
    activeTurn: () => active, kind: () => 'steer', remote: () => false,
    rpc: async (...args) => { calls.push(args); return { ok: true, result: { accepted: true } } },
    start: async (...args) => { starts.push(args) }, busy: () => busy,
    notice: (text) => notices.push(text), id: () => `id-${++id}`,
    restore: (...args) => restored.push(args), ...overrides,
  })
  return { ...api, calls, starts, notices, restored,
    finish: (status = 'completed') => { active = null; api.observeTurn(pane, 'turn-1', status) },
    active: (value) => { active = value }, busy: (value) => { busy = value },
  }
}

describe('follow-up contract', () => {
  test('bridge error envelopes cannot be mistaken for definite rejections', () => {
    expect(followupRpcError({ error: { message: 'RemoteRequestTimedOut' } })).not.toBeInstanceOf(FollowupRejectedError)
    expect(followupRpcError({ error: { code: 'insufficient_scope', message: 'Denied' } })).toBeInstanceOf(FollowupRejectedError)
  })
  test('only supported local CLI providers steer', () => {
    for (const provider of ['codex', 'claude', 'pi']) expect(followupKind(provider)).toBe('steer')
    for (const provider of ['opencode', 'cursor', 'fx', 'grok', 'muse', undefined]) expect(followupKind(provider)).toBe('queue')
    expect(followupKind('codex', 'api')).toBe('queue')
  })
  test('steering uses stable identity and supports local images', async () => {
    const f = fixture()
    expect(await f.submit(pane, 'change direction', [image])).toBe(true)
    expect(f.calls[0]).toEqual([pane, 'chat.turn.steer', { turn_id: 'turn-1', steer_id: 'id-1', prompt: 'change direction', image_paths: [image.path] }])
    expect(f.pendingFollowup(pane)).toMatchObject({ kind: 'steer', state: 'sent_inline', text: 'change direction' })
    expect(f.pendingFollowupHint(pane)).toContain('applied')
    expect(f.cancelFollowup(pane)).toBe(false)
    f.finish()
    expect(f.pendingFollowup(pane)).toBeNull()
  })
  test('queues send exactly once after completion and leave the composer alone', async () => {
    const f = fixture({ kind: () => 'queue' })
    await f.submit(pane, 'next', [image])
    await f.flushReady()
    expect(f.starts).toHaveLength(0)
    f.finish()
    await Promise.all([f.flushReady(), f.flushReady()])
    expect(f.starts).toHaveLength(1)
    expect(f.starts[0][1]).toMatchObject({ text: 'next', images: [image], next_turn_id: 'id-2' })
    expect(f.restored).toHaveLength(0)
    expect(f.pendingFollowup(pane)).toBeNull()
  })
  test('busy sends defer queues; another active turn prevents overlapping execution', async () => {
    const f = fixture({ kind: () => 'queue' })
    await f.submit(pane, 'next', [])
    f.finish(); f.busy(true)
    await f.flushReady()
    expect(f.starts).toHaveLength(0)
    f.busy(false); f.active('external-turn')
    await f.flushReady()
    expect(f.starts).toHaveLength(0)
    f.active(null)
    await f.flushReady()
    expect(f.starts).toHaveLength(1)
  })
  test('pull-back restores text and images; cancellation discards only the pending entry', async () => {
    const f = fixture({ kind: () => 'queue' })
    await f.submit(pane, 'next', [image])
    expect(f.pullBackFollowup(pane)).toBe(true)
    expect(f.restored).toEqual([[pane, 'next', [image]]])
    expect(f.pendingFollowup(pane)).toBeNull()
    await f.submit(pane, 'cancel me', [])
    expect(f.cancelFollowup(pane)).toBe(true)
    f.finish(); await f.flushReady()
    expect(f.starts).toHaveLength(0)
  })
  test('identity follows the thread, not a reused pane number', async () => {
    const f = fixture({ kind: () => 'queue' })
    await f.submit(pane, 'next', [])
    expect(f.pendingFollowup({ ...pane, pane_id: 22 })?.text).toBe('next')
    expect(f.pendingFollowup({ ...pane, thread_id: 'other' })).toBeNull()
    expect(f.pendingFollowup({ ...pane, workspace_id: 'other' })).toBeNull()
  })
  test('failed and aborted parents retain an editable queue without sending it', async () => {
    for (const status of ['failed', 'aborted']) {
      const f = fixture({ kind: () => 'queue' })
      await f.submit(pane, 'next', [])
      f.finish(status); await f.flushReady()
      expect(f.starts).toHaveLength(0)
      expect(f.pendingFollowupHint(pane)).toContain('stopped')
      expect(f.pullBackFollowup(pane)).toBe(true)
    }
  })
  test('explicit provider rejection falls back, while in-flight errors do not', async () => {
    const response = { error: { code: 'invalid_state', message: 'turn cannot accept steering now' } }
    const f = fixture({ rpc: async () => response })
    await f.submit(pane, 'next', [])
    expect(f.pendingFollowup(pane)?.state).toBe('fallback_next_turn')
    f.finish(); await f.flushReady()
    expect(f.starts).toHaveLength(1)
    expect(steerCanFallback({ error: { code: 'invalid_state', message: 'steer request is still in progress' } })).toBe(false)
  })
  test('ambiguous steer reconciles recorded delivery without resending to the provider', async () => {
    const calls = []
    const f = fixture({ rpc: async (_pane, method, params) => {
      calls.push({ method, params })
      if (calls.length === 1) throw new Error('connection lost')
      return { result: { events: [{ seq: 1, kind: 'steer', payload_json: JSON.stringify({ steer_id: 'id-1', body: 'next' }) }] } }
    } })
    await f.submit(pane, 'next', [])
    expect(f.pendingFollowup(pane)?.delivery).toBe('uncertain')
    expect(f.cancelFollowup(pane)).toBe(false)
    expect(f.pullBackFollowup(pane)).toBe(false)
    expect(await f.retryFollowup(pane)).toBe(true)
    expect(calls.map((call) => call.method)).toEqual(['chat.turn.steer', 'chat.turn.tail'])
    f.finish(); await f.flushReady()
    expect(f.starts).toHaveLength(0)
  })
  test('queued-start ambiguity preserves the next turn ID for explicit retry', async () => {
    const ids = []
    const f = fixture({ kind: () => 'queue', start: async (_pane, value) => {
      ids.push(value.next_turn_id)
      if (ids.length === 1) throw new Error('timeout')
    } })
    await f.submit(pane, 'next', []); f.finish()
    await f.flushReady(); await f.flushReady()
    expect(ids).toEqual(['id-2'])
    expect(f.pendingFollowup(pane)?.delivery).toBe('uncertain')
    await f.retryFollowup(pane)
    expect(ids).toEqual(['id-2', 'id-2'])
  })
  test('definite rejections allow pull-back instead of trapping the draft', async () => {
    const f = fixture({ rpc: async () => ({ error: { code: 'insufficient_scope', message: 'chat.write required' } }) })
    await f.submit(pane, 'next', [])
    expect(f.pullBackFollowup(pane)).toBe(true)
    const queued = fixture({ kind: () => 'queue', start: async () => { throw new FollowupRejectedError('rejected') } })
    await queued.submit(pane, 'next', []); queued.finish(); await queued.flushReady()
    expect(queued.cancelFollowup(pane)).toBe(true)
  })
  test('tail replay recovers accepted steering and preserves a newer queued follow-up', async () => {
    const f = fixture()
    f.observeSteer(pane, 'turn-1', { steer_id: 'old', body: 'already sent' })
    expect(f.pendingFollowup(pane)).toMatchObject({ state: 'sent_inline', text: 'already sent' })
    await f.submit(pane, 'next', [], 'queue')
    f.observeSteer(pane, 'turn-1', { steer_id: 'old', body: 'already sent' })
    expect(f.pendingFollowup(pane)?.text).toBe('next')
  })
  test('tail recovery selects the newest accepted steer and ignores older pages', () => {
    const f = fixture()
    f.observeSteer(pane, 'turn-1', { steer_id: 'first', body: 'first' }, 2)
    f.observeSteer(pane, 'turn-1', { steer_id: 'second', body: 'second' }, 8)
    f.observeSteer(pane, 'turn-1', { steer_id: 'first', body: 'first' }, 2)
    expect(f.pendingFollowup(pane)?.text).toBe('second')
  })
  test('remote images, empty submissions, and replacement cannot lose an existing draft', async () => {
    const remote = fixture({ remote: () => true })
    expect(await remote.submit(pane, 'image', [image])).toBe(false)
    expect(remote.calls).toHaveLength(0)
    expect(remote.notices[0]).toContain('images are not supported')
    const f = fixture({ kind: () => 'queue' })
    expect(await f.submit(pane, ' ', [])).toBe(false)
    await f.submit(pane, 'first', [])
    expect(await f.submit(pane, 'second', [])).toBe(false)
    expect(f.pendingFollowup(pane)?.text).toBe('first')
  })
})

function memoryStorage() {
  const data = new Map()
  return { getItem: (key) => data.get(key) ?? null, setItem: (key, value) => { data.set(key, value) } }
}

test('provider acknowledgement failures retain uncertainty through completion and explicit reconciliation', async () => {
  const methods = []
  const f = fixture({ rpc: async (_pane, method) => {
    methods.push(method)
    return method === 'chat.turn.steer'
      ? { error: { code: 'invalid_state', message: 'provider could not accept steering for this turn' } }
      : { result: { events: [] } }
  } })
  await f.submit(pane, 'ambiguous', [image])
  f.finish(); await f.flushReady()
  expect(await f.retryFollowup(pane)).toBe(false)
  expect(f.pendingFollowup(pane)?.delivery).toBe('uncertain')
  expect(f.starts).toHaveLength(0)
  expect(methods).toEqual(['chat.turn.steer', 'chat.turn.tail'])
})

test('receipt is durable before RPC and staging; reload keeps identity and never dispatches uncertain work', async () => {
  const storage = memoryStorage()
  let release
  let staged = false
  const f = fixture({ storage, staged: () => {
    expect(JSON.parse(storage.getItem(FOLLOWUP_CACHE_KEY))[0].value.steer_id).toBe('id-1')
    staged = true
  }, rpc: async () => {
    expect(staged).toBe(true)
    return new Promise((resolve) => { release = resolve })
  } })
  const sending = f.submit(pane, 'saved', [image])
  const calls = []
  const reloaded = fixture({ storage, rpc: async (_pane, method) => { calls.push(method); return { error: { code: 'not_found', message: 'daemon restarted' } } } })
  expect(reloaded.pendingFollowup(pane)).toMatchObject({ steer_id: 'id-1', text: 'saved', images: [image], delivery: 'uncertain' })
  reloaded.finish(); await reloaded.flushReady()
  expect(reloaded.starts).toHaveLength(0)
  expect(await reloaded.submit(pane, 'duplicate', [])).toBe(false)
  expect(await reloaded.retryFollowup(pane)).toBe(false)
  expect(calls).toEqual(['chat.turn.tail'])
  expect(reloaded.pendingFollowup(pane)?.delivery).toBe('uncertain')
  release({ result: { accepted: true } }); await sending
})

test('receipt storage failure preserves composer and never starts delivery', async () => {
  let staged = false
  const f = fixture({ storage: { getItem: () => null, setItem: () => { throw new Error('quota') } }, staged: () => { staged = true } })
  expect(await f.submit(pane, 'keep', [image])).toBe(false)
  expect(staged).toBe(false)
  expect(f.calls).toHaveLength(0)
  expect(f.pendingFollowup(pane)).toBeNull()
})

test('stop inhibits completion dispatch synchronously and leaves queue available for recall', async () => {
  const f = fixture({ kind: () => 'queue' })
  await f.submit(pane, 'next', [image])
  f.inhibit(pane)
  f.finish(); await f.flushReady()
  expect(f.starts).toHaveLength(0)
  expect(f.pullBackFollowup(pane)).toBe(true)
  expect(f.restored[0][2]).toEqual([image])
})

test('restored unsent queues are paused even if their parent completed', async () => {
  const storage = memoryStorage()
  const f = fixture({ storage, kind: () => 'queue' })
  await f.submit(pane, 'next', [])
  const reloaded = fixture({ storage, kind: () => 'queue' })
  reloaded.finish(); await reloaded.flushReady()
  expect(reloaded.starts).toHaveLength(0)
  expect(reloaded.pendingFollowupHint(pane)).toContain('paused')
  expect(await reloaded.retryFollowup(pane)).toBe(true)
  expect(reloaded.starts).toHaveLength(1)
})

test('tail images follow their own steer identity and validate daemon empty mime contract', async () => {
  const f = fixture()
  await f.submit(pane, 'first', [image])
  f.observeSteer(pane, 'turn-1', { steer_id: 'second', body: 'second' }, 2)
  expect(f.pendingFollowup(pane)?.images).toEqual([])
  const tailImage = { path: '/tmp/second.png', mime: '', byte_size: 0 }
  f.observeSteer(pane, 'turn-1', { steer_id: 'third', body: 'third', images: [tailImage, null, { path: 5 }, { path: '/x', mime: 'text/html' }] }, 3)
  expect(f.pendingFollowup(pane)?.images).toEqual([tailImage])
  expect(followupImages({ path: '/tmp/no-array.png' })).toEqual([])
})

test('attachment ownership spans RPC and only unsent cancellation discards uploads', async () => {
  let release
  const discarded = []
  const f = fixture({ rpc: () => new Promise((resolve) => { release = resolve }), discard: (images) => discarded.push(...images) })
  const sending = f.submit(pane, 'next', [image])
  expect(f.ownsAttachment(image.path)).toBe(true)
  expect(f.cancelFollowup(pane)).toBe(false)
  release({ result: { accepted: true } }); await sending
  expect(discarded).toEqual([])
  const queued = fixture({ kind: () => 'queue', discard: (images) => discarded.push(...images) })
  await queued.submit(pane, 'next', [image]); queued.cancelFollowup(pane)
  expect(queued.ownsAttachment(image.path)).toBe(false)
  expect(discarded).toEqual([image])
})

test('failure persisting the sending transition prevents both steer and queued RPCs', async () => {
  for (const kind of ['steer', 'queue']) {
    const memory = memoryStorage()
    let writes = 0
    const storage = { getItem: memory.getItem, setItem: (key, value) => {
      if (++writes > 1) throw new Error('storage full')
      memory.setItem(key, value)
    } }
    const f = fixture({ storage, kind: () => kind })
    await f.submit(pane, 'not delivered', [image])
    if (kind === 'queue') { f.finish(); await f.flushReady() }
    expect(f.calls).toHaveLength(0)
    expect(f.starts).toHaveLength(0)
    expect(f.pendingFollowup(pane)?.delivery).toBe('unsent')
    expect(JSON.parse(memory.getItem(FOLLOWUP_CACHE_KEY))[0].value.delivery).toBe('unsent')
  }
})

test('real store preserves pending upload ownership on remove and cleans cancelled unreferenced uploads', async () => {
  const { createAppStore } = await import('./store')
  const previousSessionStorage = globalThis.sessionStorage
  const previousStorage = globalThis.localStorage
  const previousWindow = globalThis.window
  const previousFetch = globalThis.fetch
  try {
    const upload = { ...image, attachment_id: 'web-test-followup' }
    const deletes = []
    globalThis.fetch = async (url, init) => { deletes.push({ url, method: init.method }); return new Response('{}') }
    globalThis.window = { setTimeout: () => 1, clearTimeout: () => {} }
    for (const delivery of ['unsent', 'uncertain']) {
      const storage = memoryStorage()
      storage.setItem(FOLLOWUP_CACHE_KEY, JSON.stringify([{ pane, value: {
        kind: 'queue', state: 'pending', delivery, text: 'pending', images: [upload], turn_id: 'turn-1', steer_id: 's', next_turn_id: 'n',
      } }]))
      storage.setItem('verde:web:composer:v1', JSON.stringify({ drafts: {}, attachments: { 'w:1': [upload] } }))
      globalThis.sessionStorage = storage
      globalThis.localStorage = storage
      const store = createAppStore()
      store.removeAttachment(pane, upload)
      expect(store.attachmentsFor(pane)).toEqual([])
      expect(deletes).toHaveLength(delivery === 'unsent' ? 0 : 1)
      expect(store.cancelFollowup(pane)).toBe(delivery === 'unsent')
      expect(deletes).toHaveLength(1)
    }
    expect(deletes[0]).toEqual({ url: '/api/attachment?id=web-test-followup', method: 'DELETE' })
  } finally {
    globalThis.sessionStorage = previousSessionStorage
    globalThis.localStorage = previousStorage
    globalThis.window = previousWindow
    globalThis.fetch = previousFetch
  }
})

test('real store cancellation retains uploads still owned by a composer', async () => {
  const { createAppStore } = await import('./store')
  const previousSessionStorage = globalThis.sessionStorage
  const previousStorage = globalThis.localStorage
  const previousFetch = globalThis.fetch
  try {
    const upload = { ...image, attachment_id: 'web-test-shared' }
    const storage = memoryStorage()
    storage.setItem(FOLLOWUP_CACHE_KEY, JSON.stringify([{ pane, value: {
      kind: 'queue', state: 'pending', delivery: 'unsent', text: 'pending', images: [upload], turn_id: 'turn-1', steer_id: 's', next_turn_id: 'n',
    } }]))
    storage.setItem('verde:web:composer:v1', JSON.stringify({ drafts: {}, attachments: { 'w:2': [upload] } }))
    globalThis.sessionStorage = storage
    globalThis.localStorage = storage
    let deletes = 0
    globalThis.fetch = async () => { deletes++; return new Response('{}') }
    const store = createAppStore()
    expect(store.cancelFollowup(pane)).toBe(true)
    expect(deletes).toBe(0)
    expect(store.attachmentsFor({ ...pane, pane_id: 2 })).toEqual([upload])
  } finally {
    globalThis.sessionStorage = previousSessionStorage
    globalThis.localStorage = previousStorage
    globalThis.fetch = previousFetch
  }
})


test('persisted follow-ups fail closed when their runtime or cwd route changes', async () => {
  const storage = memoryStorage()
  let route = 'local:runtime-a:primary'
  const f = fixture({ storage, route: () => route, kind: () => 'queue' })
  await f.submit(pane, 'original route', [image])
  route = 'local:runtime-b:primary'
  const reloaded = fixture({ storage, route: () => route, kind: () => 'queue' })
  reloaded.finish()
  expect(await reloaded.retryFollowup(pane)).toBe(false)
  expect(reloaded.starts).toHaveLength(0)
  expect(reloaded.pendingFollowup(pane)?.text).toBe('original route')
  route = 'local:runtime-a:primary'
  expect(await reloaded.retryFollowup(pane)).toBe(true)
  expect(reloaded.starts).toHaveLength(1)
})

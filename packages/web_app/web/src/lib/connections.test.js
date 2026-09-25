import { afterEach, describe, expect, test } from 'bun:test'
import { connectionRpc, effectiveConnection, fetchConnections } from './connections'

const catalog = {
  connections: [],
  defaults: [{ workspace_id: 'mirage', profile_id: 'zod' }],
}

test('workspace connection defaults apply only to new chats; explicit choices win', () => {
  expect(effectiveConnection({ committed: false }, 'mirage', catalog)).toBe('zod')
  expect(effectiveConnection({ committed: false }, 'other', catalog)).toBe('local')
  expect(effectiveConnection({ profile_id: 'local' }, 'mirage', catalog)).toBe('local')
  expect(effectiveConnection({ profile_id: 'another' }, 'mirage', catalog)).toBe('another')
  // Committed legacy conversations do not move with defaults.
  expect(effectiveConnection({ committed: true }, 'mirage', catalog)).toBe('local')
  expect(effectiveConnection({ provider_thread_id: 'existing' }, 'mirage', catalog)).toBe('local')
})

const originalFetch = globalThis.fetch
afterEach(() => { globalThis.fetch = originalFetch })

describe('remote chat transport', () => {
  const connection = { profile_id: 'zod', label: 'Zod', ready: true, runtime_id: 'runtime-a', phase: 'ready', failure: null }
  test('never falls back to local for unavailable or changed identities', async () => {
    let calls = 0
    globalThis.fetch = async () => { calls++; throw new Error('must not call') }
    await expect(connectionRpc({ ...connection, ready: false }, null, 'chat.turn.start', {})).rejects.toThrow('Zod')
    await expect(connectionRpc(connection, 'runtime-b', 'chat.turn.start', {})).rejects.toThrow('different runtime')
    expect(calls).toBe(0)
  })
  test('sends only the selected profile and pinned identity to the same-origin gateway', async () => {
    let sent
    globalThis.fetch = async (url, options) => {
      sent = { url, ...options, body: JSON.parse(options.body) }
      return Response.json({ ok: true, result: { turn_id: 'turn' } })
    }
    const result = await connectionRpc(connection, 'runtime-a', 'chat.turn.start', { workspace_id: 'mirage', repository_id: 'primary' })
    expect(result.ok).toBe(true)
    expect(sent.url).toBe('/api/chat-connection-rpc')
    expect(sent.credentials).toBe('same-origin')
    expect(sent.body).toEqual({ profile_id: 'zod', runtime_id: 'runtime-a', method: 'chat.turn.start', params: { workspace_id: 'mirage', repository_id: 'primary' } })
    expect(sent.headers.Authorization).toBeUndefined()
  })
  test('paired catalog denial leaves local chat available', async () => {
    globalThis.fetch = async () => Response.json({ error: { message: 'Owner login required for saved connections' } }, { status: 403 })
    expect(await fetchConnections()).toEqual({ connections: [], defaults: [] })
  })
  test('authentication and service failures do not become local defaults', async () => {
    for (const status of [401, 500]) {
      globalThis.fetch = async () => Response.json({ error: { message: 'unavailable' } }, { status })
      await expect(fetchConnections()).rejects.toThrow('unavailable')
    }
  })
})

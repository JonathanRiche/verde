import { afterEach, describe, expect, test } from 'bun:test'
import { connectionRpc, fetchConnections } from './connections'

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
  test('authentication and service failures do not become local defaults', async () => {
    for (const status of [401, 500]) {
      globalThis.fetch = async () => Response.json({ error: { message: 'unavailable' } }, { status })
      await expect(fetchConnections()).rejects.toThrow('unavailable')
    }
  })
})

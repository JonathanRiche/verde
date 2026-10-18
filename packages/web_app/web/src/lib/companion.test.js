import { describe, expect, test } from 'bun:test'
import { patchCompanion, saveRoster } from './companion'

const companion = (id, extra = {}) => ({
  id, name: id.toUpperCase(), character: 'moss', home_workspace_id: 'home', thread_id: `t-${id}`,
  provider: 'claude', model: 'opus', orders: '', ...extra,
})
const roster = (companions, active_id = companions[0]?.id ?? '') => ({ version: 1, active_id, companions })
const ok = (result) => ({ id: 1, ok: true, result })
const conflict = { id: 1, error: { code: 'conflict', message: 'companion roster changed; re-read and retry' } }

describe('saveRoster conflict handling', () => {

  test('re-reads and re-applies the edit after a conflict', async () => {
    const theirs = roster([companion('a'), companion('b', { name: 'Theirs' })])
    const calls = []
    const call = async (method, params) => {
      calls.push({ method, params })
      if (method === 'companion.roster.get') return ok({ revision: 7, roster: theirs })
      return params.expected_revision === 7 ? ok({ revision: 8 }) : conflict
    }
    const saved = await saveRoster(call, { revision: 6, roster: roster([companion('a')]) },
      (current) => patchCompanion(current, 'a', { name: 'Mine' }))
    expect(calls.map((row) => row.method)).toEqual(['companion.roster.put', 'companion.roster.get', 'companion.roster.put'])
    // The other client's companion survives; ours is renamed.
    expect(saved.roster.companions.map((row) => row.name)).toEqual(['Mine', 'Theirs'])
    expect(saved.revision).toBe(8)
  })

  test('an edit that no longer applies after a conflict is a no-op', async () => {
    const call = async (method) => method === 'companion.roster.get'
      ? ok({ revision: 2, roster: roster([companion('b')]) })
      : conflict
    const saved = await saveRoster(call, { revision: 1, roster: roster([companion('a'), companion('b')]) },
      (current) => patchCompanion(current, 'a', { name: 'Gone' }))
    expect(saved.revision).toBe(2)
    expect(saved.roster.companions.map((row) => row.id)).toEqual(['b'])
  })

  test('gives up after repeated conflicts and surfaces other errors', async () => {
    const racing = async (method) => method === 'companion.roster.get' ? ok({ revision: 1, roster: roster([companion('a')]) }) : conflict
    await expect(saveRoster(racing, { revision: 0, roster: roster([companion('a')]) }, (r) => r)).rejects.toThrow(/kept changing/)
    const invalid = async () => ({ error: { code: 'invalid_params', message: 'invalid companion roster' } })
    await expect(saveRoster(invalid, { revision: 0, roster: roster([companion('a')]) }, (r) => r)).rejects.toThrow('invalid companion roster')
  })
})

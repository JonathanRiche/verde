import { describe, expect, test } from 'bun:test'
import {
  activeCompanion, addCompanion, cleanCompanionName, companionPose, companionStatusLine, crewStatusPill,
  parseCrewLinks, parseRoster, parseRosterSnapshot, patchCompanion, removeCompanion, saveRoster,
  selectCompanion, withDefaultCompanion, MAX_COMPANIONS,
} from './companion'

const companion = (id, extra = {}) => ({
  id, name: id.toUpperCase(), character: 'moss', home_workspace_id: 'home', thread_id: `t-${id}`,
  provider: 'claude', model: 'opus', orders: '', ...extra,
})
const roster = (companions, active_id = companions[0]?.id ?? '') => ({ version: 1, active_id, companions })
const ok = (result) => ({ id: 1, ok: true, result })
const conflict = { id: 1, error: { code: 'conflict', message: 'companion roster changed; re-read and retry' } }

describe('roster parsing', () => {
  test('revision 0 is an empty roster', () => {
    const snapshot = parseRosterSnapshot(ok({ revision: 0, roster: { version: 1, active_id: '', companions: [] } }))
    expect(snapshot).toEqual({ revision: 0, roster: { version: 1, active_id: '', companions: [] } })
  })

  test('normalizes fields like the daemon parser', () => {
    const parsed = parseRoster({
      active_id: 'b',
      companions: [
        { id: 'a', name: '  ', character: 'dragon' },
        { id: 'b', name: 'Wren\u0007', character: 'vireo', thread_id: 'chat-1', orders: 'Never push to main.' },
        null,
        { name: 'No id', character: 'moss' },
      ],
    })
    expect(parsed.active_id).toBe('b')
    expect(parsed.companions.map((row) => [row.id, row.name, row.character])).toEqual([
      ['a', 'Sprout', 'sprout'],
      ['b', 'Wren', 'vireo'],
      ['cmp-restored-2', 'No id', 'moss'],
    ])
    expect(parsed.companions[1]).toMatchObject({ thread_id: 'chat-1', orders: 'Never push to main.', provider: '', model: '' })
  })

  test('unknown active id falls back to the first companion and caps at the roster size', () => {
    const many = Array.from({ length: MAX_COMPANIONS + 3 }, (_, index) => ({ id: `c${index}`, name: `C${index}` }))
    const parsed = parseRoster({ active_id: 'gone', companions: many })
    expect(parsed.companions).toHaveLength(MAX_COMPANIONS)
    expect(parsed.active_id).toBe('c0')
    expect(activeCompanion(parsed).id).toBe('c0')
  })

  test('failed envelopes parse as null', () => {
    expect(parseRosterSnapshot(conflict)).toBeNull()
    expect(parseRosterSnapshot({ ok: false })).toBeNull()
  })

  test('names clip to 32 UTF-8 bytes without splitting a code point', () => {
    const name = cleanCompanionName('🌱'.repeat(10))
    expect(new TextEncoder().encode(name).length).toBeLessThanOrEqual(32)
    expect(name).toBe('🌱'.repeat(8))
  })
})

describe('roster edits', () => {
  test('first use creates a default Sprout', () => {
    const next = withDefaultCompanion(roster([]), 'ws-1')
    expect(next.companions).toHaveLength(1)
    expect(next.companions[0]).toMatchObject({ name: 'Sprout', character: 'sprout', home_workspace_id: 'ws-1', thread_id: '' })
    expect(next.active_id).toBe(next.companions[0].id)
    expect(withDefaultCompanion(next)).toBeNull()
  })

  test('add makes the new companion active with a unique name', () => {
    const base = roster([companion('a', { name: 'Moss' })])
    const next = addCompanion(base, 'moss', { now: 5 })
    expect(next.companions.at(-1).name).toBe('Moss 2')
    expect(next.active_id).toBe(next.companions.at(-1).id)
    const full = roster(Array.from({ length: MAX_COMPANIONS }, (_, index) => companion(`c${index}`)))
    expect(addCompanion(full, 'sprout')).toBeNull()
  })

  test('remove keeps at least one companion and moves the active one', () => {
    const base = roster([companion('a'), companion('b')], 'b')
    const next = removeCompanion(base, 'b')
    expect(next.companions.map((row) => row.id)).toEqual(['a'])
    expect(next.active_id).toBe('a')
    expect(removeCompanion(next, 'a')).toBeNull()
  })

  test('patch rejects empty names and trims orders', () => {
    const base = roster([companion('a'), companion('b')])
    expect(patchCompanion(base, 'a', { name: '   ' })).toBeNull()
    expect(patchCompanion(base, 'missing', { name: 'X' })).toBeNull()
    const next = patchCompanion(base, 'a', { name: 'B', orders: '  run tests  \n', character: 'vireo' })
    expect(next.companions[0]).toMatchObject({ name: 'B 2', orders: 'run tests', character: 'vireo' })
    expect(selectCompanion(base, 'a')).toBeNull()
    expect(selectCompanion(base, 'b').active_id).toBe('b')
  })
})

describe('saveRoster conflict handling', () => {
  test('puts with the expected revision', async () => {
    const calls = []
    const call = async (method, params) => { calls.push({ method, params }); return ok({ revision: 4 }) }
    const saved = await saveRoster(call, { revision: 3, roster: roster([companion('a')]) },
      (current) => patchCompanion(current, 'a', { orders: 'be brief' }))
    expect(calls).toHaveLength(1)
    expect(calls[0].method).toBe('companion.roster.put')
    expect(calls[0].params.expected_revision).toBe(3)
    expect(calls[0].params.roster.companions[0].orders).toBe('be brief')
    expect(saved.revision).toBe(4)
  })

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

describe('crew', () => {
  test('status pills map every daemon link status', () => {
    expect(crewStatusPill('running')).toMatchObject({ label: 'Running', tone: 'accent', live: true })
    expect(crewStatusPill('waiting_approval')).toMatchObject({ label: 'Needs approval', tone: 'warning' })
    expect(crewStatusPill('blocked')).toMatchObject({ label: 'Blocked', tone: 'warning' })
    expect(crewStatusPill('completed')).toMatchObject({ label: 'Done', tone: 'done', live: false })
    expect(crewStatusPill('failed')).toMatchObject({ label: 'Failed', tone: 'danger' })
    expect(crewStatusPill('aborted')).toMatchObject({ label: 'Stopped', tone: 'muted' })
    expect(crewStatusPill('interrupted')).toMatchObject({ label: 'Interrupted', tone: 'danger' })
    expect(crewStatusPill('idle')).toMatchObject({ label: 'Idle', tone: 'muted' })
    expect(crewStatusPill('some_new_state')).toMatchObject({ label: 'Some new state', tone: 'muted' })
    expect(crewStatusPill(undefined).label).toBe('Unknown')
  })

  test('links parse, drop hidden rows, and sort urgent first', () => {
    const links = parseCrewLinks(ok({
      links: [
        { link_id: 'l1', workspace_id: 'w2', local_thread_id: 'c1', title: 'Old done', status: 'completed', updated_at_ms: 5 },
        { link_id: 'l2', workspace_id: 'w2', local_thread_id: 'c2', title: 'Approve me', status: 'waiting_approval', updated_at_ms: 1 },
        { link_id: 'l3', workspace_id: 'w3', local_thread_id: 'c3', title: 'Hidden', status: 'running', hidden: true },
        { link_id: 'l4', workspace_id: 'w3', local_thread_id: 'c4', title: '', status: 'running', updated_at_ms: 9 },
        { link_id: 'l5', workspace_id: '', local_thread_id: 'c5', status: 'running' },
      ],
      parents: [],
    }))
    expect(links.map((row) => row.link_id)).toEqual(['l2', 'l4', 'l1'])
    expect(links[1]).toMatchObject({ workspace_id: 'w3', title: 'Chat' })
    expect(parseCrewLinks(conflict)).toEqual([])
  })
})

describe('presence', () => {
  test('status line', () => {
    expect(companionStatusLine({ needs: 0, running: 0 })).toBe('Ready when you are')
    expect(companionStatusLine({ needs: 0, running: 1 })).toBe('1 chat running')
    expect(companionStatusLine({ needs: 0, running: 3 })).toBe('3 chats running')
    expect(companionStatusLine({ needs: 1, running: 3 })).toBe('1 thing needs you')
    expect(companionStatusLine({ needs: 2, running: 0 })).toBe('2 things need you')
  })

  test('pose follows real state', () => {
    expect(companionPose({ connected: false, needs: 2, working: true })).toBe('paused')
    expect(companionPose({ connected: true, needs: 1, working: true })).toBe('approval')
    expect(companionPose({ connected: true, needs: 0, working: true })).toBe('working')
    expect(companionPose({ connected: true, needs: 0, working: false })).toBe('idle')
  })
})

import { describe, expect, test } from 'bun:test'
import { createApprovalTracker } from './approvals'
import { approvalFromTurn, pendingApprovalForPane, requestApprovalResolution, mergeLocalTurnSnapshot, isLocalTurnRequest } from './store'

const details = { call_id: 'call-1', title: 'Run command?', body: 'Permission to run the command' }
const turn = { turn_id: 'turn-1', workspace_id: 'w', local_thread_id: 'thread-1', status: 'waiting_approval', pending_approval: details }
const pane = { kind: 'chat', workspace_id: 'w', pane_id: 1, thread_id: 'thread-1' }
const approval = { turn_id: 'turn-1', ...details }

// Use the same reconciliation and pane selection path as snapshot/tail delivery.
function approvalHarness() {
  const tracker = createApprovalTracker()
  let turns = []
  const tails = {}
  return {
    tracker,
    deliver(value, source) {
      const observed = tracker.reconcile(value, source)
      turns = [{ ...turn, ...observed }]
      tails[observed.turn_id] = approvalFromTurn(observed)
    },
    pending() {
      const pending = pendingApprovalForPane(pane, turns, tails)
      return pending && !tracker.isSubmitted(pending) ? pending : null
    },
    status: () => turns[0]?.status,
  }
}

describe('approval response races', () => {
  test('success suppresses repeats until authoritative state advances', async () => {
    const state = approvalHarness()
    state.deliver({ ...turn, next_seq: 2 }, 'snapshot')
    let calls = 0
    const send = async () => { calls++ }
    expect(await state.tracker.resolve(approval, send)).toBe(true)
    expect(state.pending()).toBeNull()
    expect(await state.tracker.resolve(approval, send)).toBe(false)
    state.deliver({ ...turn, next_seq: 2 }, 'tail')
    expect(state.pending()).toBeNull()
    expect(calls).toBe(1)
    state.deliver({ ...turn, next_seq: 3, pending_approval: { ...details, call_id: 'call-2' } }, 'tail')
    expect(state.pending()?.call_id).toBe('call-2')
    expect(state.tracker.isSubmitted(approval)).toBe(false)
    expect(await state.tracker.resolve(state.pending(), send)).toBe(true)
    expect(calls).toBe(2)
  })
  test('concurrent resolves are blocked and failed requests can be retried', async () => {
    const tracker = createApprovalTracker()
    tracker.reconcile(turn, 'snapshot')
    let reject
    const first = tracker.resolve(approval, () => new Promise((_, fail) => { reject = fail }))
    expect(await tracker.resolve(approval, async () => { throw new Error('duplicate') })).toBe(false)
    reject(new Error('offline'))
    await expect(first).rejects.toThrow('offline')
    expect(tracker.isSubmitted(approval)).toBe(false)
    expect(await tracker.resolve(approval, async () => {})).toBe(true)
  })
  test('advancing during a resolve does not suppress the next approval', async () => {
    const state = approvalHarness()
    state.deliver({ ...turn, next_seq: 2 }, 'snapshot')
    let finish
    const result = state.tracker.resolve(approval, () => new Promise((resolve) => { finish = resolve }))
    state.deliver({ ...turn, next_seq: 3, pending_approval: { ...details, call_id: 'call-2' } }, 'tail')
    finish()
    await result
    expect(state.pending()?.call_id).toBe('call-2')
    expect(state.tracker.isSubmitted(approval)).toBe(false)
  })
  test('delayed snapshots cannot replace or hide newer tail approvals', () => {
    const state = approvalHarness()
    state.deliver({ ...turn, next_seq: 3, pending_approval: { ...details, call_id: 'call-2' } }, 'tail')
    for (const pending_approval of [details, null]) {
      state.deliver({ ...turn, next_seq: 2, pending_approval }, 'snapshot')
      expect(state.pending()?.call_id).toBe('call-2')
    }
    // A genuinely newer snapshot must still be accepted.
    state.deliver({ ...turn, next_seq: 4, pending_approval: { ...details, call_id: 'call-3' } }, 'snapshot')
    expect(state.pending()?.call_id).toBe('call-3')
    state.deliver({ ...turn, next_seq: 3 }, 'tail')
    expect(state.pending()?.call_id).toBe('call-3')
  })
  test('resolution at the same sequence cannot be undone by either transport', () => {
    for (const source of ['snapshot', 'tail']) {
      const state = approvalHarness()
      state.deliver({ ...turn, next_seq: 2 }, 'snapshot')
      state.deliver({ ...turn, next_seq: 2, status: 'running', pending_approval: null }, 'tail')
      state.deliver({ ...turn, next_seq: 2 }, source)
      expect(state.pending()).toBeNull()
      expect(state.status()).toBe('running')
    }
  })
  test('completed, failed and cancelled turns cannot be resurrected', () => {
    for (const status of ['completed', 'failed', 'aborted']) {
      const state = approvalHarness()
      state.deliver({ ...turn, next_seq: 3, status }, 'tail')
      state.deliver({ ...turn, next_seq: 2 }, 'snapshot')
      expect(state.pending()).toBeNull()
      expect(state.status()).toBe(status)
    }
  })
})

describe('approval recovery and tail state', () => {
  test('restores full details from a snapshot before tailing', () => {
    expect(pendingApprovalForPane(pane, [turn], {})).toEqual(approval)
    expect(approvalFromTurn(turn)).toEqual(approval)
  })
  test('tail details supersede snapshots and null clears on resume', () => {
    const next = { ...approval, call_id: 'call-2' }
    expect(pendingApprovalForPane(pane, [turn], { 'turn-1': next })).toEqual(next)
    expect(pendingApprovalForPane(pane, [turn], { 'turn-1': null })).toBeNull()
    expect(approvalFromTurn({ ...turn, status: 'running', pending_approval: null })).toBeNull()
  })
  test('terminal turns clear even if approval details linger', () => {
    for (const status of ['completed', 'failed', 'aborted']) {
      expect(approvalFromTurn({ ...turn, status })).toBeNull()
      expect(pendingApprovalForPane(pane, [{ ...turn, status }], { 'turn-1': approval })).toBeNull()
    }
  })
  test('isolates threads, workspaces, and reused pane ids', () => {
    for (const patch of [{ thread_id: 'other' }, { workspace_id: 'other' }, { kind: 'terminal' }]) {
      expect(pendingApprovalForPane({ ...pane, ...patch }, [turn], { 'turn-1': approval })).toBeNull()
    }
    expect(pendingApprovalForPane(pane, [turn, { ...turn, turn_id: 'turn-2', pending_approval: null }], { 'turn-1': approval })).toBeNull()
  })
  test('local recovery preserves remote approvals without resurrecting local turns', () => {
    const remote = { ...turn, profile_id: 'remote' }
    const recovered = mergeLocalTurnSnapshot([remote], [{ ...turn, turn_id: 'old-local' }])
    expect(recovered).toEqual([remote])
    expect(pendingApprovalForPane(pane, recovered, {})).toEqual(approval)
    expect(mergeLocalTurnSnapshot([turn], [])).toEqual([])
  })
  test('a call-id-only bookkeeping event cannot fabricate approval details', () => {
    for (const pending_approval of [null, true, { call_id: 'call-1' }, { ...details, call_id: '' }]) {
      expect(approvalFromTurn({ ...turn, pending_approval })).toBeNull()
    }
  })
})

describe('approval RPC', () => {
  test('paired local turns do not require the owner-only catalog; remote turns never fall back', () => {
    expect(isLocalTurnRequest(pane, [turn], { turn_id: 'turn-1' })).toBe(true)
    expect(isLocalTurnRequest(pane, [{ ...turn, profile_id: 'remote' }], { turn_id: 'turn-1' })).toBe(false)
    expect(isLocalTurnRequest({ ...pane, thread_id: 'other' }, [turn], { turn_id: 'turn-1' })).toBe(false)
    expect(isLocalTurnRequest(pane, [turn], {})).toBe(false)
  })
  test('sends the exact decision and identity using the supplied pane route', async () => {
    for (const decision of ['approve', 'deny']) {
      const calls = []
      await requestApprovalResolution(approval, decision, async (...args) => {
        calls.push(args)
        return { ok: true, result: { accepted: true } }
      })
      expect(calls).toEqual([['chat.turn.approve', { turn_id: 'turn-1', call_id: 'call-1', decision }]])
    }
  })
  test('preserves server, scope, and connection errors for the notice mechanism', async () => {
    await expect(requestApprovalResolution(approval, 'deny', async () => ({ error: { message: 'approval not found' } }))).rejects.toThrow('approval not found')
    await expect(requestApprovalResolution(approval, 'approve', async () => ({ ok: false }))).rejects.toThrow('Could not resolve')
    await expect(requestApprovalResolution(approval, 'approve', async () => { throw new Error('Owner login required for saved connections') })).rejects.toThrow('Owner login required')
  })
})

import { createSignal } from 'solid-js'
import type { SnapshotTurn } from './store'
import type { PendingApproval } from './types'

const terminal = (turn: SnapshotTurn) => ['completed', 'failed', 'aborted'].includes(turn.status ?? '')
const identity = (approval: PendingApproval) => JSON.stringify([approval.turn_id, approval.call_id])

/** Reconcile full turn observations, independently of paginated event cursors. */
export function createApprovalTracker() {
  const observations = new Map<string, { turn: SnapshotTurn; source: 'snapshot' | 'tail' }>()
  const inFlight = new Set<string>()
  const [submitted, setSubmitted] = createSignal<ReadonlySet<string>>(new Set())
  const reconcile = (incoming: SnapshotTurn, source: 'snapshot' | 'tail'): SnapshotTurn => {
    if (!incoming.turn_id) return incoming
    const previous = observations.get(incoming.turn_id)
    const old = previous?.turn
    // Terminal state is irreversible. At equal sequence numbers, resolution
    // wins: the daemon clears pending_approval without appending an event.
    const older = old && (terminal(old) || (!terminal(incoming) && (
      (old.next_seq !== undefined && incoming.next_seq !== undefined
        ? incoming.next_seq < old.next_seq || (incoming.next_seq === old.next_seq &&
          old.pending_approval === null && Boolean(incoming.pending_approval))
        : previous.source === 'tail' && source === 'snapshot')
    )))
    const turn = older ? { ...incoming, ...old } : { ...old, ...incoming }
    observations.set(incoming.turn_id, { turn, source: older ? previous!.source : source })
    setSubmitted((keys) => {
      const next = new Set(keys)
      for (const key of keys) {
        const [turn_id, call_id] = JSON.parse(key) as [string, string]
        if (turn_id === turn.turn_id && (terminal(turn) || turn.pending_approval?.call_id !== call_id)) next.delete(key)
      }
      return next.size === keys.size ? keys : next
    })
    return turn
  }
  return {
    reconcile,
    isSubmitted: (approval: PendingApproval) => submitted().has(identity(approval)),
    async resolve(approval: PendingApproval, send: () => Promise<void>): Promise<boolean> {
      const key = identity(approval)
      if (inFlight.has(key) || submitted().has(key)) return false
      inFlight.add(key)
      try {
        await send()
        const current = observations.get(approval.turn_id)?.turn
        // A newer request may arrive while the RPC is in flight.
        if (!current || (!terminal(current) && current.pending_approval?.call_id === approval.call_id)) {
          setSubmitted((keys) => new Set([...keys, key]))
        }
        return true
      } finally {
        // Failed requests remain retryable; successful ones stay suppressed.
        inFlight.delete(key)
      }
    },
  }
}

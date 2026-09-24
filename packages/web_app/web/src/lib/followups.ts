import { createSignal } from 'solid-js'
import { unwrapResult } from './live'
import type { Attachment, FollowupKind, LivePane, PendingFollowup, RpcEnvelope } from './types'

export function followupKind(provider?: string, harness = 'local_cli'): FollowupKind {
  return harness === 'local_cli' && ['codex', 'claude', 'pi'].includes(provider ?? '') ? 'steer' : 'queue'
}

export function followupKey(pane: LivePane): string {
  return JSON.stringify([pane.workspace_id, pane.thread_id])
}

export function followupHint(pending: PendingFollowup | null, kind: FollowupKind): string {
  if (pending?.delivery === 'uncertain') return 'Delivery is unconfirmed. Retry to check recorded delivery.'
  if (pending?.delivery === 'sending') return 'Sending follow-up…'
  if (pending?.state === 'sent_inline') return 'Steer applied to the current reply.'
  if (pending) return pending.state === 'fallback_next_turn'
    ? 'Steering unavailable. Queued for the next turn.'
    : 'Queued. Sends after the current reply.'
  return kind === 'steer' ? 'Send to steer the current reply.' : 'Send to queue after the current reply.'
}

// Only explicit pre-acceptance rejections can safely become a new turn.
export function steerCanFallback(response: RpcEnvelope): boolean {
  return response.error?.code === 'invalid_state' && [
    'provider does not support daemon steering', 'turn cannot accept steering now',
    'provider thread is not ready', 'Codex active turn is not ready',
  ].includes(response.error.message)
}

export class FollowupRejectedError extends Error {}

export function followupRpcError(response: RpcEnvelope): Error {
  const message = response.error?.message ?? 'Follow-up request failed'
  // Bridge timeouts have a message but no daemon rejection code: acceptance
  // may already have happened, so only known rejections permit recall.
  const rejected = ['forbidden', 'insufficient_scope', 'invalid_params', 'not_found'].includes(response.error?.code ?? '')
  return rejected ? new FollowupRejectedError(message) : new Error(message)
}

interface FollowupDependencies {
  activeTurn: (pane: LivePane) => string | null
  kind: (pane: LivePane) => FollowupKind
  remote: (pane: LivePane) => boolean
  rpc: (pane: LivePane, method: string, params: unknown) => Promise<RpcEnvelope>
  start: (pane: LivePane, followup: PendingFollowup) => Promise<void>
  busy: () => boolean
  notice: (text: string) => void
  id: () => string
  route?: (pane: LivePane) => string
  storage?: Pick<Storage, 'getItem' | 'setItem'>
  staged?: (pane: LivePane, value: PendingFollowup) => void
  discard?: (images: Attachment[]) => void
  restore: (pane: LivePane, text: string, images: Attachment[]) => void
}

export const FOLLOWUP_CACHE_KEY = 'verde.web.followups.v1'

export function followupImages(value: unknown): Attachment[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((image) => {
    if (!image || typeof image !== 'object' || typeof image.path !== 'string' || !image.path ||
        typeof image.mime !== 'string' || (image.mime !== '' && !image.mime.startsWith('image/'))) return []
    return [{ path: image.path, mime: image.mime,
      ...(typeof image.byte_size === 'number' && Number.isFinite(image.byte_size) && image.byte_size >= 0 ? { byte_size: image.byte_size } : {}),
      ...(typeof image.attachment_id === 'string' ? { attachment_id: image.attachment_id } : {}),
    }]
  })
}

/// The daemon has no queue/pull-back RPC. Unsent follow-ups belong to this
/// browser tab and persist across reloads in a paused state; accepted steers
/// can be recovered from the daemon tail.
export function createFollowupApi(deps: FollowupDependencies) {
  const [entries, setEntries] = createSignal<Record<string, PendingFollowup>>({})
  const targets = new Map<string, LivePane>()
  const outcomes = new Map<string, string>()
  const routes = new Map<string, string>()
  const attempted = new Set<string>()
  const inhibited = new Set<string>()
  let storageFailed = false
  try {
    const saved = JSON.parse(deps.storage?.getItem(FOLLOWUP_CACHE_KEY) ?? '[]')
    if (!Array.isArray(saved)) throw new Error('Invalid follow-up receipts')
    for (const row of saved) {
      const pane = row?.pane, value = row?.value
      if (!pane || pane.kind !== 'chat' || typeof pane.workspace_id !== 'string' || typeof pane.thread_id !== 'string' ||
          !value || !['queue', 'steer'].includes(value.kind) || !['pending', 'sent_inline', 'fallback_next_turn'].includes(value.state) ||
          !['unsent', 'sending', 'uncertain', 'accepted'].includes(value.delivery) ||
          !['turn_id', 'steer_id', 'next_turn_id', 'text'].every((key) => typeof value[key] === 'string')) throw new Error('Invalid follow-up receipt')
      const key = followupKey(pane)
      targets.set(key, pane)
      if (typeof row.route === 'string') routes.set(key, row.route)
      // Reload never automatically dispatches saved work, even if the parent
      // completed while this client was disconnected.
      inhibited.add(key)
      setEntries((prev) => ({ ...prev, [key]: { ...value, images: followupImages(value.images),
        delivery: value.delivery === 'sending' ? 'uncertain' : value.delivery } }))
    }
  } catch { storageFailed = true }
  const persist = () => {
    deps.storage?.setItem(FOLLOWUP_CACHE_KEY, JSON.stringify([...targets].map(([key, pane]) => ({ pane, value: entries()[key], route: routes.get(key) }))))
  }
  const pendingFollowup = (pane: LivePane): PendingFollowup | null => entries()[followupKey(pane)] ?? null
  const put = (pane: LivePane, value: PendingFollowup | null, required = false) => {
    const key = followupKey(pane)
    if (value) targets.set(key, { ...pane })
    else targets.delete(key)
    setEntries((prev) => {
      const next = { ...prev }
      if (value) next[key] = value
      else delete next[key]
      return next
    })
    try { persist() } catch (error) {
      if (required) throw error
      deps.notice('Follow-up receipt could not be updated in browser storage. Reload may require reconciling delivery.')
    }
  }
  const update = (pane: LivePane, value: PendingFollowup, patch: Partial<PendingFollowup>) => {
    if (pendingFollowup(pane)?.steer_id === value.steer_id) put(pane, { ...value, ...patch })
  }
  const routeMatches = (pane: LivePane): boolean => {
    if (!deps.route || routes.get(followupKey(pane)) === deps.route(pane)) return true
    deps.notice('The follow-up connection or working directory changed. Restore its original route before retrying, or recall unsent work.')
    return false
  }
  const beginDelivery = (pane: LivePane, value: PendingFollowup): boolean => {
    try { put(pane, { ...value, delivery: 'sending' }, true); return true } catch {
      put(pane, value)
      deps.notice('Follow-up delivery could not be saved. No request was sent; the follow-up is kept.')
      return false
    }
  }
  const steer = async (pane: LivePane, value: PendingFollowup): Promise<boolean> => {
    if (!beginDelivery(pane, value)) return false
    try {
      const response = await deps.rpc(pane, 'chat.turn.steer', {
        turn_id: value.turn_id, steer_id: value.steer_id, prompt: value.text,
        image_paths: value.images.map((image) => image.path),
      })
      if (value.delivery !== 'uncertain' && steerCanFallback(response)) {
        update(pane, value, { state: 'fallback_next_turn', delivery: 'unsent' })
        deps.notice('Steering unavailable. Queued for the next turn.')
        return true
      }
      if (response.error || response.ok === false) {
        throw followupRpcError(response)
      }
      const result = unwrapResult<{ accepted?: boolean; event_seq?: number }>(response)
      if (!result?.accepted) throw new Error('Steer acceptance was not confirmed')
      update(pane, value, { state: 'sent_inline', delivery: 'accepted', event_seq: result.event_seq })
      if (outcomes.has(value.turn_id) && pendingFollowup(pane)?.steer_id === value.steer_id) put(pane, null)
      return true
    } catch (error) {
      // A timeout may follow provider acceptance. Never silently queue it again.
      if (pendingFollowup(pane)?.state !== 'sent_inline') update(pane, value, { delivery: value.delivery !== 'uncertain' && error instanceof FollowupRejectedError ? 'unsent' : 'uncertain' })
      deps.notice(`${error instanceof Error ? error.message : 'Steer failed'}. Retry the pending follow-up to confirm delivery.`)
      return false
    }
  }
  const submit = async (pane: LivePane, text: string, images: Attachment[], kind = deps.kind(pane)): Promise<boolean> => {
    const turn_id = deps.activeTurn(pane)
    if (!turn_id) { deps.notice('The running turn is not ready for a follow-up.'); return false }
    if (!text.trim() && !images.length) return false
    const previous = pendingFollowup(pane)
    if (previous && previous.state !== 'sent_inline') {
      deps.notice('Pull back or cancel the pending follow-up before replacing it.')
      return false
    }
    // Remote steer cannot carry images (gateway paths do not exist on the
    // remote runtime). Like desktop, queue it as the next turn, which stages
    // the image bytes on the remote daemon.
    if (images.length && deps.remote(pane)) kind = 'queue'
    const value: PendingFollowup = {
      kind, state: 'pending', text, images: [...images], turn_id,
      steer_id: deps.id(), next_turn_id: deps.id(), delivery: 'unsent',
    }
    if (deps.route) routes.set(followupKey(pane), deps.route(pane))
    if (storageFailed) { deps.notice('Follow-up receipts could not be loaded. Reload after restoring browser storage.'); return false }
    try { put(pane, value, true) } catch {
      deps.notice('Follow-up could not be saved. Your draft is kept; no request was sent.')
      setEntries((prev) => { const next = { ...prev }; delete next[followupKey(pane)]; return next })
      targets.delete(followupKey(pane))
      return false
    }
    inhibited.delete(followupKey(pane))
    deps.staged?.(pane, value)
    if (kind === 'queue') return true
    // Submission is staged even on an ambiguous response; its stable ID is
    // retained for explicit retry rather than duplicated from the composer.
    await steer(pane, value)
    return true
  }
  const removable = (pane: LivePane): PendingFollowup | null => {
    const value = pendingFollowup(pane)
    if (!value) return null
    if (value.delivery !== 'unsent') {
      deps.notice(value.state === 'sent_inline' ? 'This steer was already delivered and cannot be recalled.' : 'Confirm delivery with Retry before pulling back or cancelling this follow-up.')
      return null
    }
    return value
  }
  const cancelFollowup = (pane: LivePane): boolean => {
    const value = removable(pane)
    if (!value) return false
    put(pane, null)
    deps.discard?.(value.images)
    return true
  }
  const pullBackFollowup = (pane: LivePane): boolean => {
    const value = removable(pane)
    if (!value) return false
    deps.restore(pane, value.text, value.images)
    put(pane, null)
    return true
  }
  const observeSteer = (pane: LivePane, turn_id: string, payload: Record<string, unknown>, event_seq?: number) => {
    if (typeof payload.steer_id !== 'string' || typeof payload.body !== 'string') return
    const current = pendingFollowup(pane)
    if (current && current.steer_id !== payload.steer_id && current.state !== 'sent_inline') return
    if (current?.turn_id === turn_id && current.event_seq !== undefined &&
        event_seq !== undefined && current.event_seq > event_seq) return
    put(pane, {
      kind: 'steer', state: 'sent_inline', delivery: 'accepted', turn_id,
      steer_id: payload.steer_id, next_turn_id: '', text: payload.body, event_seq,
      images: Array.isArray(payload.images) ? followupImages(payload.images) : current?.steer_id === payload.steer_id ? current.images : [],
    })
  }
  const observeTurn = (pane: LivePane, turn_id: string, status?: string) => {
    if (!status || !['completed', 'failed', 'aborted'].includes(status)) return
    outcomes.set(turn_id, status)
    const current = pendingFollowup(pane)
    if (current?.turn_id !== turn_id) return
    if (current.state === 'sent_inline') put(pane, null)
    else if (status !== 'completed') {
      update(pane, current, {})
      deps.notice('The turn stopped before the queued follow-up was sent. Pull it back or cancel it.')
    }
  }
  const dispatch = async (pane: LivePane, value: PendingFollowup): Promise<boolean> => {
    if (!routeMatches(pane)) return false
    const active = deps.activeTurn(pane)
    if (deps.busy() || value.delivery === 'sending' || (active && active !== value.next_turn_id)) return false
    attempted.add(value.next_turn_id)
    if (!beginDelivery(pane, value)) return false
    try {
      await deps.start(pane, value)
      if (pendingFollowup(pane)?.steer_id === value.steer_id) put(pane, null)
      return true
    } catch (error) {
      update(pane, value, { delivery: value.delivery !== 'uncertain' && error instanceof FollowupRejectedError ? 'unsent' : 'uncertain' })
      deps.notice(`${error instanceof Error ? error.message : 'Follow-up failed'}. Retry uses the same turn ID.`)
      return false
    }
  }
  const retryFollowup = async (pane: LivePane): Promise<boolean> => {
    const value = pendingFollowup(pane)
    if (!value || value.delivery === 'sending' || value.state === 'sent_inline' || !routeMatches(pane)) return false
    if (value.kind === 'steer' && value.state === 'pending') {
      if (value.delivery !== 'uncertain') return steer(pane, value)
      // A refreshed browser may be talking to a restarted daemon whose in-memory
      // deduplication record is gone. Recover evidence; never re-invoke an
      // uncertain steer merely because that record is absent.
      try {
        let after_seq = 0
        for (let page = 0; page < 100; page++) {
          const response = await deps.rpc(pane, 'chat.turn.tail', { turn_id: value.turn_id, after_seq, wait_ms: 0 })
          if (response.error || response.ok === false) throw followupRpcError(response)
          const result = unwrapResult<{ events?: Array<{ kind?: string; seq?: number; payload_json?: string }> }>(response)
          const events = result?.events ?? []
          let newest = after_seq
          for (const event of events) {
            if (typeof event.seq === 'number') newest = Math.max(newest, event.seq)
            if (event.kind !== 'steer' || !event.payload_json) continue
            const payload = JSON.parse(event.payload_json)
            if (payload?.steer_id === value.steer_id) {
              observeSteer(pane, value.turn_id, payload, event.seq)
              return pendingFollowup(pane)?.delivery === 'accepted'
            }
          }
          if (!events.length || newest <= after_seq) break
          after_seq = newest
        }
        deps.notice('Delivery remains unconfirmed. The follow-up is retained and has not been resent.')
      } catch (error) { deps.notice(error instanceof Error ? error.message : 'Could not check follow-up delivery') }
      return false
    }
    if (outcomes.get(value.turn_id) !== 'completed') return false
    return dispatch(pane, value)
  }
  const flushReady = async () => {
    for (const pane of targets.values()) {
      const value = pendingFollowup(pane)
      if (inhibited.has(followupKey(pane)) || !value || value.delivery !== 'unsent' || attempted.has(value.next_turn_id) ||
          outcomes.get(value.turn_id) !== 'completed' ||
          (value.kind === 'steer' && value.state !== 'fallback_next_turn')) continue
      await dispatch(pane, value)
    }
  }
  return {
    inhibit: (pane: LivePane) => { inhibited.add(followupKey(pane)) },
    ownsAttachment: (path: string) => Object.values(entries()).some((entry) => entry.images.some((image) => image.path === path)),
    pendingFollowup, cancelFollowup, pullBackFollowup, retryFollowup, submit,
    pendingFollowupHint: (pane: LivePane): string | null => {
      const pending = pendingFollowup(pane)
      const outcome = pending && outcomes.get(pending.turn_id)
      if (pending?.delivery === 'unsent' && inhibited.has(followupKey(pane))) return 'Follow-up paused. Pull back, cancel, or explicitly retry it.'
      if (pending?.delivery === 'unsent' && outcome && outcome !== 'completed') return 'The turn stopped. Pull back or cancel the queued follow-up.'
      return pending || deps.activeTurn(pane) ? followupHint(pending, deps.kind(pane)) : null
    },
    observeSteer, observeTurn, flushReady, panes: () => [...targets.values()],
  }
}

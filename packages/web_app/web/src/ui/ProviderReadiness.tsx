import { Show, createSignal, onMount } from 'solid-js'
import { store } from '../lib/store'
import { providerReadinessNoticeVisible } from '../lib/provider_readiness'
import type { LivePane } from '../lib/types'

export function ProviderReadiness(props: { pane: LivePane }) {
  const [busy, setBusy] = createSignal(false)
  const [dismissed, setDismissed] = createSignal<string | null>(null)
  const check = async (silent = false) => { if (busy()) return; setBusy(true); try { await store.recheckProviderReadiness(props.pane, { silent }) } finally { setBusy(false) } }
  const status = () => store.providerReadiness(props.pane)
  const blocker = () => store.chatRuntimeBlocker(props.pane)
  const noticeKey = () => JSON.stringify([props.pane.pane_id, props.pane.thread_id, props.pane.runtime_id, store.connectionFor(props.pane), status().provider, status().state, status().detail])
  const canDismiss = () => !blocker() && status().state === 'unavailable'
  onMount(() => { if (store.connectionFor(props.pane) === 'local') void check(true); else void store.refreshConnections() })
  return <Show when={providerReadinessNoticeVisible(status(), blocker(), dismissed() === noticeKey())}><aside class="composer-readiness composer-surface" aria-label="Provider status">
    <div><strong>{blocker() ? 'Connection unavailable' : status().label}</strong><p class="composer-detail" role="status">{blocker()?.detail ?? status().detail}</p></div>
    <Show when={canDismiss()} fallback={<button type="button" disabled={busy() || status().state === 'checking'} onClick={() => void check()}>{busy() || status().state === 'checking' ? 'Checking…' : 'Check again'}</button>}>
      <button type="button" onClick={() => setDismissed(noticeKey())}>Dismiss</button>
    </Show>
  </aside></Show>
}

import { Show, createSignal, onMount } from 'solid-js'
import { store } from '../lib/store'
import type { LivePane } from '../lib/types'

export function ProviderReadiness(props: { pane: LivePane }) {
  const [busy, setBusy] = createSignal(false)
  const check = async () => { if (busy()) return; setBusy(true); try { await store.recheckProviderReadiness(props.pane) } finally { setBusy(false) } }
  const status = () => store.providerReadiness(props.pane)
  const blocker = () => store.chatRuntimeBlocker(props.pane)
  onMount(() => { void check() })
  return <Show when={blocker() || status().state !== 'ready'}><aside class="composer-readiness composer-surface" aria-label="Provider status">
    <div><strong>{blocker() ? 'Connection unavailable' : status().label}</strong><p class="composer-detail" role="status">{blocker()?.detail ?? status().detail}</p></div>
    <button type="button" disabled={busy() || status().state === 'checking'} onClick={() => void check()}>{busy() || status().state === 'checking' ? 'Checking…' : 'Check again'}</button>
  </aside></Show>
}

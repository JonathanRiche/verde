import { For, Show, createSignal } from 'solid-js'
import { store } from '../lib/store'
import { chatImageUrl } from '../lib/live'
import type { LivePane } from '../lib/types'

const DELIVERY_LABELS = { unsent: 'Not sent', sending: 'Sending', uncertain: 'Unconfirmed', accepted: 'Delivered' } as const

/** Only unsent browser-owned work can be edited or removed. */
export function ComposerFollowup(props: { pane: LivePane }) {
  const pending = () => store.pendingFollowup(props.pane)
  const [retrying, setRetrying] = createSignal(false)
  return <Show when={pending()}>{(entry) => <aside class="composer-followup composer-surface" aria-label="Follow-up">
    <div class="composer-surface-heading"><strong>{entry().state === 'sent_inline' ? 'Steer delivered' : entry().state === 'fallback_next_turn' || entry().kind === 'queue' ? 'Queued follow-up' : 'Steer follow-up'}</strong><span>{DELIVERY_LABELS[entry().delivery]}</span></div>
    <Show when={entry().text}><p class="composer-followup-text">{entry().text}</p></Show>
    <Show when={entry().images.length}><div class="composer-followup-images"><For each={entry().images}>{image => <img src={chatImageUrl(image) ?? ''} alt={image.name ?? 'Follow-up image'} />}</For></div></Show>
    <p class="composer-detail" role="status">{store.pendingFollowupHint(props.pane)}</p>
    <Show when={entry().delivery === 'uncertain' || entry().delivery === 'accepted'}><p class="composer-detail">This follow-up cannot be recalled while delivery is unconfirmed or already accepted.</p></Show>
    <div class="composer-surface-actions">
      <Show when={entry().delivery === 'unsent'}>
        <button type="button" onClick={() => { store.focusPane(props.pane); store.pullBackFollowup(props.pane) }}>Pull back to edit</button>
        <button type="button" onClick={() => store.cancelFollowup(props.pane)}>Remove</button>
      </Show>
      <Show when={entry().delivery === 'unsent' || entry().delivery === 'uncertain'}><button type="button" disabled={retrying()} onClick={async () => { setRetrying(true); try { await store.retryFollowup(props.pane) } finally { setRetrying(false) } }}>{retrying() ? 'Checking…' : 'Retry'}</button></Show>
    </div>
  </aside>}</Show>
}

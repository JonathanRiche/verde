import { For, Show, createSignal } from 'solid-js'
import { store } from '../lib/store'
import type { LivePane } from '../lib/types'

export function ChatCwdPicker(props: { pane: LivePane }) {
  const [open, setOpen] = createSignal(false), [busy, setBusy] = createSignal(false)
  const locked = () => store.chatCwdIsLocked(props.pane)
  const selected = () => JSON.stringify([props.pane.repository_id ?? 'primary', props.pane.repository_cwd ?? null])
  const label = () => props.pane.repository_cwd || (props.pane.repository_id && props.pane.repository_id !== 'primary' ? props.pane.repository_id : 'Workspace root')
  const inspect = async () => { setOpen(!open()); if (!open() || locked()) return; setBusy(true); try { await store.listChatCwdChoices(props.pane) } finally { setBusy(false) } }
  return <div class="chat-cwd-picker">
    <button type="button" class="chat-cwd-trigger" aria-expanded={open()} onClick={() => void inspect()} title="Chat working directory"><span>Directory</span><strong>{label()}</strong><span aria-hidden="true">{locked() ? '· locked' : '⌄'}</span></button>
    <Show when={open()}><div class="chat-cwd-options">
      <Show when={locked()} fallback={<>
        <Show when={busy()}><p class="composer-detail" role="status">Loading validated directories…</p></Show>
        <Show when={!busy() && !store.chatCwdChoices(props.pane).length}><p class="composer-detail">No validated working directories are available. Close and reopen to check again.</p></Show>
        <For each={store.chatCwdChoices(props.pane)}>{choice => <button type="button" disabled={busy()} aria-pressed={selected() === choice.id} onClick={async () => { setBusy(true); try { if (await store.setChatCwd(props.pane, choice.id)) setOpen(false) } finally { setBusy(false) } }}><strong>{choice.label}</strong><span>{choice.path}</span></button>}</For>
      </>}><p class="composer-detail">This conversation keeps its working directory after work begins. Start a new chat to change it.</p></Show>
    </div></Show>
  </div>
}

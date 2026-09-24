import { For, Show, createEffect, createMemo, createSignal, createUniqueId, onCleanup, onMount } from 'solid-js'
import { acceptFileMention, acceptSlashCommand, fileMentionAtCaret, slashTokenAtCaret, type ComposerReplacement, type FileMatch, type SlashCommand } from '../lib/composer_commands'
import { store } from '../lib/store'
import { parseUsageSummary } from '../lib/usage'
import type { LivePane } from '../lib/types'
import { UsageCard } from './UsageCard'

export interface ComposerSuggestControls {
  keydown: (event: KeyboardEvent) => boolean
  close: () => void
  expanded: () => boolean
  activeId: () => string | undefined
  listId: string
}

/** Suggestions never take ownership of the native textarea or IME selection. */
export function ComposerSuggest(props: {
  pane: LivePane; draft: string; caret: number; composing: boolean
  accept: (replacement: ComposerReplacement) => void
  controls: (controls: ComposerSuggestControls) => void
}) {
  const id = createUniqueId()
  const [maxHeight, setMaxHeight] = createSignal(260)
  onMount(() => {
    const viewport = window.visualViewport
    const measure = () => setMaxHeight(Math.max(80, Math.min(320, (viewport?.height ?? window.innerHeight) * .38)))
    measure()
    viewport?.addEventListener('resize', measure)
    window.addEventListener('resize', measure)
    onCleanup(() => { viewport?.removeEventListener('resize', measure); window.removeEventListener('resize', measure) })
  })
  const [commands, setCommands] = createSignal<SlashCommand[]>([])
  const [files, setFiles] = createSignal<FileMatch[]>([])
  const [busy, setBusy] = createSignal(false), [message, setMessage] = createSignal('')
  const [selected, setSelected] = createSignal(0), [dismissed, setDismissed] = createSignal(false)
  const token = createMemo(() => props.composing ? null : slashTokenAtCaret(props.draft, props.caret) ?? fileMentionAtCaret(props.draft, props.caret))
  const slash = () => Boolean(token() && props.draft[token()!.start] === '/')
  type Option = { key: string; title: string; detail: string; badge?: string; accept: () => ComposerReplacement | null }
  const matches = (): Option[] => slash()
    ? commands().filter(command => command.name.slice(1).toLowerCase().includes(token()?.query.toLowerCase() ?? '')).map(command => ({
      key: command.name, title: command.name, detail: command.summary,
      badge: command.availability && command.availability !== 'available' ? command.availability : undefined,
      accept: () => acceptSlashCommand(props.draft, props.caret, command.name),
    }))
    : files().map(file => {
      const slashAt = file.path.lastIndexOf('/')
      return { key: file.path, title: file.file_name, detail: slashAt > 0 ? file.path.slice(0, slashAt) : '', accept: () => acceptFileMention(props.draft, props.caret, file.path) }
    })
  let generation = 0
  createEffect(() => {
    const current = token()
    const request = ++generation
    setDismissed(false); setSelected(0); setCommands([]); setMessage('')
    // Keep the previous file list while the next query loads to avoid flicker.
    if (!current || slash()) setFiles([])
    if (!current) { setBusy(false); return }
    const isSlash = slash()
    setBusy(true)
    const abort = new AbortController()
    const timer = setTimeout(async () => {
      try {
        if (isSlash) {
          const result = await store.listSlashCommands(props.pane)
          if (generation !== request) return
          setCommands(result ?? [])
          if (!result) setMessage('Slash commands are unavailable for this chat. See the status below.')
        } else {
          const result = await store.searchFiles(props.pane, current.query, abort.signal)
          if (generation !== request) return
          if (result.status === 'ok') setFiles(result.files)
          else if (result.status === 'error') { setFiles([]); setMessage(result.message ?? 'File search failed.') }
        }
      } finally { if (generation === request) setBusy(false) }
    }, 100)
    onCleanup(() => { clearTimeout(timer); abort.abort() })
  })
  const expanded = () => Boolean(token()) && !dismissed()
  const accept = (option: Option) => {
    const replacement = option.accept()
    if (replacement) props.accept(replacement)
    setDismissed(true)
  }
  const close = () => setDismissed(true)
  const keydown = (event: KeyboardEvent) => {
    if (!expanded() || props.composing || event.isComposing || event.keyCode === 229) return false
    if (event.key === 'Escape') { event.preventDefault(); close(); return true }
    if (!matches().length) return false
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      setSelected((index) => (index + (event.key === 'ArrowDown' ? 1 : -1) + matches().length) % matches().length)
      document.getElementById(`${id}-${selected()}`)?.scrollIntoView({ block: 'nearest' })
      return true
    }
    if ((event.key === 'Enter' || event.key === 'Tab') && !event.shiftKey) {
      event.preventDefault(); accept(matches()[selected()]!); return true
    }
    return false
  }
  props.controls({ keydown, close, expanded, activeId: () => expanded() && matches().length ? `${id}-${selected()}` : undefined, listId: id })
  return <Show when={expanded()}><div class="composer-suggest" style={{ "max-height": `${maxHeight()}px` }} aria-label={slash() ? 'Slash command suggestions' : 'File suggestions'}>
    <div class="composer-surface-heading"><strong>{slash() ? 'Commands' : 'Files'}</strong><button type="button" onPointerDown={event => event.preventDefault()} onClick={close} aria-label="Dismiss suggestions">×</button></div>
    <Show when={busy()}><p class="composer-detail" role="status">Loading…</p></Show>
    <Show when={message()}><p class="composer-detail" role="status">{message()}</p></Show>
    <Show when={!busy() && !message() && !matches().length}><p class="composer-detail">{slash() ? 'No matching commands.' : 'No matching files.'}</p></Show>
    <div id={id} role="listbox" aria-label={slash() ? 'Commands' : 'Files'}><For each={matches()}>{(option, index) => <button type="button" role="option" id={`${id}-${index()}`} aria-selected={selected() === index()} class="composer-suggestion" onPointerDown={event => event.preventDefault()} onClick={() => accept(option)}>
      <strong>{option.title}<Show when={option.badge}><small> · {option.badge}</small></Show></strong><span>{option.detail}</span>
    </button>}</For></div>
  </div></Show>
}

export function ComposerCommandStatus(props: { pane: LivePane }) {
  const state = () => store.slashCommandState(props.pane)
  const [seconds, setSeconds] = createSignal(0)
  const [dismissed, setDismissed] = createSignal(false)
  createEffect(() => {
    const pending = state().pending
    setDismissed(false); setSeconds(0)
    if (!pending) return
    const started = Date.now()
    const timer = setInterval(() => setSeconds(Math.floor((Date.now() - started) / 1000)), 1000)
    onCleanup(() => clearInterval(timer))
  })
  const usage = () => {
    const parsed = parseUsageSummary(state().result?.transcript_title ?? undefined, state().result?.transcript_body ?? '')
    return parsed && (parsed.limits.length || parsed.stats.length || parsed.recent.length) ? parsed : null
  }
  return <Show when={state().pending || (!dismissed() && state().result?.transcript_body)}><div class="composer-command-status composer-surface">
    <Show when={state().pending} fallback={<>
      <button type="button" class="composer-result-dismiss" onClick={() => setDismissed(true)} aria-label="Dismiss command result">×</button>
      <Show when={usage()} fallback={<><strong>{state().result?.transcript_title ?? 'Command result'}</strong><pre>{state().result?.transcript_body}</pre></>}>{value => <UsageCard usage={value()} />}</Show>
    </>}><p role="status">Running slash command… <span>{seconds()}s</span></p></Show>
  </div></Show>
}

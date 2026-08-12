import { For, Show, createEffect, createMemo } from 'solid-js'
import { marked } from 'marked'

import { store } from '../lib/store'
import { isCommandRow, type LivePane, type Message } from '../lib/types'
import { Icon, ProviderGlyph } from './Icons'

marked.setOptions({ gfm: true, breaks: true })

export function ChatPane(props: { pane: LivePane }) {
  let scroller: HTMLDivElement | undefined
  let pinToBottom = true
  let savedTop = 0
  const messages = createMemo(() => store.messagesFor(props.pane))
  const focused = () => store.focusedPaneId() === props.pane.pane_id

  createEffect(() => {
    store.ensureTranscript(props.pane)
  })

  createEffect(() => {
    messages()
    const node = scroller
    if (!node) return
    const top = savedTop
    const pin = pinToBottom
    queueMicrotask(() => {
      if (!scroller) return
      scroller.scrollTop = pin ? scroller.scrollHeight : top
    })
  })

  const onScroll = () => {
    const node = scroller
    if (!node) return
    savedTop = node.scrollTop
    pinToBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 96
  }

  return (
    <section class="flex min-h-0 flex-1 flex-col bg-[var(--chat-black)]">
      <header
        class="hidden h-10 shrink-0 items-center gap-2 border-b border-[var(--border-muted)] px-3 lg:flex"
        onMouseDown={() => store.focusPane(props.pane)}
      >
        <ProviderGlyph provider={props.pane.provider} />
        <div class="min-w-0 flex-1 truncate text-[14px] font-medium">{store.paneTitle(props.pane)}</div>
        <Show when={props.pane.send_pending}>
          <span class="text-[11px] tracking-wide text-[var(--accent)]">Working</span>
        </Show>
      </header>
      <div
        class="min-h-0 flex-1 overflow-y-auto px-3 py-3 scrollbar-thin lg:px-5 lg:py-5"
        ref={(node) => { scroller = node }}
        onScroll={onScroll}
        onMouseDown={() => store.focusPane(props.pane)}
      >
        <div class="mx-auto flex w-full max-w-[900px] flex-col gap-3">
          <For each={messages()}>
            {(message) => <TranscriptRow message={message} />}
          </For>
          <Show when={messages().length === 0}>
            <EmptyTranscript />
          </Show>
        </div>
      </div>
      <Composer pane={props.pane} focused={focused()} />
    </section>
  )
}

function EmptyTranscript() {
  return (
    <div class="px-2 py-16 text-[var(--text-subtle)]">
      <div class="wordmark text-[28px] text-[var(--text)]">Ask anything</div>
      <p class="mt-2 max-w-md text-[15px]">or use / to show available commands</p>
    </div>
  )
}

function TranscriptRow(props: { message: Message }) {
  if (isCommandRow(props.message) || props.message.author === 'Ran command' || props.message.body.startsWith('Command failed')) {
    const failed = props.message.tool_call_status === 'failed' || props.message.body.startsWith('Command failed')
    const title = failed ? 'Command failed' : 'Ran command'
    return (
      <div class={`flex min-w-0 items-center gap-2 rounded-[8px] border px-3 py-1.5 text-[13px] ${failed ? 'border-[rgba(255,100,100,0.35)] text-[var(--danger)]' : 'border-[var(--border-muted)] text-[var(--text-muted)]'}`}>
        <span class="shrink-0 text-[11px] tracking-wide text-[var(--text-subtle)] uppercase">{title}</span>
        <span class="mono min-w-0 truncate text-[12px]">{oneLine(props.message.body)}</span>
      </div>
    )
  }

  const mine = props.message.role === 'user'
  const html = () => marked.parse(props.message.body, { async: false }) as string

  if (mine) {
    return (
      <article class="flex justify-center">
        <div class="w-full max-w-full rounded-[10px] bg-[var(--user-bubble)] px-3 py-2 text-[15px] leading-[21px] break-words [overflow-wrap:anywhere] text-[var(--text)] lg:max-w-[36rem] lg:px-4 lg:py-2.5">
          <div class="mb-1 text-[11px] text-[var(--time)]">You</div>
          <div class="whitespace-pre-wrap break-words [overflow-wrap:anywhere]">{props.message.body}</div>
        </div>
      </article>
    )
  }

  return (
    <article class="min-w-0 rounded-[10px] border border-[var(--border-muted)] bg-[var(--assistant-card)] px-3 py-3 lg:px-4">
      <div class="mb-1.5 text-[12px] text-[var(--text-subtle)]">{props.message.author || 'Assistant'}</div>
      <div class="markdown" innerHTML={html()} />
    </article>
  )
}

function Composer(props: { pane: LivePane; focused: boolean }) {
  let field: HTMLTextAreaElement | undefined

  createEffect(() => {
    if (props.focused && store.composerNonce() > 0) field?.focus()
  })

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      void store.sendDraft(props.pane)
    }
  }

  return (
    <form
      class="min-w-0 bg-[var(--chat-black)] px-3 pb-[max(12px,var(--safe-bottom))] lg:px-5 lg:pb-[max(16px,var(--safe-bottom))]"
      onSubmit={(event) => {
        event.preventDefault()
        void store.sendDraft(props.pane)
      }}
    >
      <Show when={props.focused && store.notice()}>
        <p class="mx-auto mb-2 max-w-[900px] text-right text-xs text-[var(--warning)]">{store.notice()}</p>
      </Show>
      <div class="mx-auto w-full max-w-[900px] rounded-[14px] bg-[var(--panel)] px-4 pt-3 pb-3">
        <textarea
          ref={(node) => { field = node }}
          class="min-h-[52px] w-full bg-transparent text-[16px] leading-[21px] outline-none placeholder:text-[var(--text-subtle)] lg:min-h-[88px] lg:text-[18px] lg:leading-[22px]"
          placeholder="Ask anything…"
          value={store.draftFor(props.pane)}
          onInput={(event) => store.setDraftFor(props.pane, event.currentTarget.value)}
          onKeyDown={onKeyDown}
          onFocus={() => store.focusPane(props.pane)}
        />
        <div class="mt-1 flex flex-wrap items-center gap-1.5">
          <span class="flex items-center gap-1.5 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]">
            <ProviderGlyph provider={props.pane.provider} class="h-4 w-4 object-contain" />
            <span class="max-w-[9rem] truncate">{shortModel(props.pane.model)}</span>
          </span>
          <span class="rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]">Medium</span>
          <span class="rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]">Fast</span>
          <span class="flex items-center gap-1 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]">
            <Icon name="lock" class="h-3 w-3" />
            Supervised
          </span>
          <div class="flex-1" />
          <button
            type="submit"
            class="grid h-8 w-8 place-items-center rounded-full bg-[var(--accent)] text-[#06210f] disabled:opacity-35"
            disabled={store.sending() || store.draftFor(props.pane).trim().length === 0}
            aria-label="Send"
          >
            <svg class="h-4 w-4" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 6l-6 7h4v5h4v-5h4z" fill="currentColor" />
            </svg>
          </button>
        </div>
      </div>
    </form>
  )
}

function shortModel(ref: string | null | undefined): string {
  if (!ref) return 'Model'
  const tail = ref.split('/').at(-1) ?? ref
  return tail.replace(/^gpt-/, 'GPT-').replace(/claude-/, 'Claude ')
}

function oneLine(value: string): string {
  const lines = value.split('\n').map((part) => part.trim()).filter((part) => part.length > 0)
  const body = lines.find((part) => !/^input:?$/i.test(part) && !/^output:?$/i.test(part)) ?? lines[0] ?? value
  return body.replace(/^Input:\s*/i, '').trim()
}

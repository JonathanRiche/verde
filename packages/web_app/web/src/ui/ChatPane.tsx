import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from 'solid-js'

import { composerEnterShouldSubmit } from '../lib/composer_input'
import { registerChatCommandPickers } from '../lib/commands'
import { focusChatPrompt } from '../lib/command_requests'
import { chatImageUrl } from '../lib/live'
import { renderMarkdown as renderSafeMarkdown } from '../lib/markdown'
import { clipboardImageFiles, store } from '../lib/store'
import { type Attachment, type LivePane, type Message, isSubagentThreadId } from '../lib/types'
import { effortLabel, effortOptionsIn, modelOptionsFor, modelSupportsFast, variantOptionsIn } from '../lib/models'
import type { ModelOption } from '../lib/models'
import { handleFileCitationClick, openFileViewer } from './FileViewer'
import { Icon, ProviderGlyph, ZoomButton } from './Icons'
import { PaneActionsButton } from './Sidebar'

import { ComposerFollowup } from './ComposerFollowup'
import { ComposerSuggest, ComposerCommandStatus, type ComposerSuggestControls } from './ComposerSuggest'
import { ProviderReadiness } from './ProviderReadiness'
import { UsageCard } from './UsageCard'
import { parseUsageSummary } from '../lib/usage'
import { copyText, decorateCodeBlocks, emphasisSpans } from '../lib/highlight'

// Shared 1s ticker driving working timers and group elapsed labels.
const [nowMs, setNowMs] = createSignal(Date.now())
window.setInterval(() => setNowMs(Date.now()), 1000)

// Card expand/collapse survives row remounts (live overlay rows are rebuilt
// on every streamed event), mirroring the desktop's per-card state keys.
const cardExpanded = new Map<string, boolean>()

// Focus requests are events, not durable state. Remember the last one handled
// across composer remounts so an old request can never refocus a replacement
// textarea. Compact/mobile layouts intentionally never focus programmatically:
// the user alone controls whether the on-screen keyboard is open.
let handledComposerFocusNonce = 0

// Desktop shows up to this many output lines before "Show more".
const TOOL_OUTPUT_COLLAPSED_LINES = 18

// Transcript window: render only the newest rows and expand on demand.
// Mounting a full multi-hundred-row thread parsed megabytes of markdown on
// the main thread in one go and froze typing for seconds on open/switch.
const TRANSCRIPT_WINDOW_ROWS = 60
const TRANSCRIPT_WINDOW_STEP = 200

// Parse-once markdown cache shared across rows/panes. Bodies are immutable
// once committed, so re-mounts (workspace switches, merge-refreshed arrays)
// must not re-parse them. Bounded so abandoned threads do not pin memory.
const MARKDOWN_CACHE_MAX = 600
const markdownCache = new Map<string, string>()
function renderMarkdown(body: string): string {
  const cached = markdownCache.get(body)
  if (cached !== undefined) {
    // Refresh recency so the active thread's rows stay resident.
    markdownCache.delete(body)
    markdownCache.set(body, cached)
    return cached
  }
  const html = renderSafeMarkdown(body, { fileCitations: true })
  markdownCache.set(body, html)
  if (markdownCache.size > MARKDOWN_CACHE_MAX) {
    const oldest = markdownCache.keys().next().value
    if (oldest !== undefined) markdownCache.delete(oldest)
  }
  return html
}

export function ChatPane(props: { pane: LivePane }) {
  let scroller: HTMLDivElement | undefined
  let pinToBottom = true
  let initial_jump = true
  const messages = createMemo(() => store.messagesFor(props.pane))
  const focused = () => store.focusedPaneId() === props.pane.pane_id

  // Load only the viewport and its immediate neighbors, independent of focus.
  // Swiping the strip must not require a second tap to attach a transcript.
  let section: HTMLElement | undefined
  const [nearViewport, setNearViewport] = createSignal(false)
  const [revealed, setRevealed] = createSignal(focused())
  const transcript = () => store.transcriptState(props.pane)
  createEffect(() => {
    if (focused()) setRevealed(true)
    if (focused() || nearViewport()) store.ensureTranscript(props.pane)
  })
  onMount(() => {
    if (!section || typeof IntersectionObserver === 'undefined') return
    const root = section.closest('.niri-strip')
    const preload = new IntersectionObserver(([entry]) => {
      setNearViewport(entry.isIntersecting && entry.intersectionRect.width > 0 && entry.intersectionRect.height > 0)
    }, { root, rootMargin: '0px 100% 0px 100%' })
    const visible = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting && entry.intersectionRect.width > 0 && entry.intersectionRect.height > 0) setRevealed(true)
    }, { root })
    preload.observe(section)
    visible.observe(section)
    onCleanup(() => { preload.disconnect(); visible.disconnect() })
  })

  createEffect(() => {
    const row_count = messages().length
    const rendered = revealed()
    const loaded = transcript().loaded
    const node = scroller
    if (!node) return
    queueMicrotask(() => {
      const el = scroller
      if (!el || !pinToBottom) return
      if (initial_jump) {
        // Don't spend the one-shot jump while the transcript is still empty
        // or unrevealed — a PWA relaunch runs this effect before the rows
        // exist and used to leave the view stuck at the top of the thread.
        if (row_count === 0 || !rendered || !loaded) return
        initial_jump = false
        el.scrollTop = el.scrollHeight
        return
      }
      // Live-DOM guard: while a turn streams, a just-issued user scroll may
      // not have dispatched its scroll event yet, so the cached pin flag
      // alone would snap the view back to the bottom and eat the scroll.
      // The slack still absorbs the height a freshly appended delta adds.
      const distance = el.scrollHeight - el.scrollTop - el.clientHeight
      if (distance < 400) el.scrollTop = el.scrollHeight
    })
  })

  let readIntentUntil = 0
  let lastScrollTop = 0
  let touchY: number | null = null
  const markReadIntent = () => { readIntentUntil = performance.now() + 1200 }
  const onScroll = () => {
    const node = scroller
    if (!node) return
    pinToBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 96
    const movingUp = node.scrollTop < lastScrollTop
    lastScrollTop = node.scrollTop
    if (movingUp && node.scrollTop < 160 && performance.now() < readIntentUntil) {
      readIntentUntil = 0
      void showEarlier()
    }
  }

  // Desktop parity: consecutive command/tool rows collapse into one grouped
  // card with a summary header; a lone row renders as a single command card.
  //
  // Wrapper identity matters: <For> keys by reference, so a wrapper whose
  // underlying message refs are unchanged must be reused verbatim — otherwise
  // every streamed delta remounts (and re-markdown-parses) the whole
  // transcript, which livelocks large threads.
  type RenderItem =
    | { kind: 'row'; message: Message }
    | { kind: 'group'; items: Message[]; groupKind: 'tool' | 'subagent' }
  const itemKey = (item: RenderItem) =>
    item.kind === 'row' ? `r:${item.message.message_id}` : `g:${item.groupKind}:${item.items[0]?.message_id ?? ''}`
  const allItems = createMemo<RenderItem[]>((prev) => {
    const out: RenderItem[] = []
    let run: Message[] = []
    let runKind: 'tool' | 'subagent' | null = null
    const flush = () => {
      if (runKind === 'subagent' && run.length >= 1) {
        out.push({ kind: 'group', items: run, groupKind: 'subagent' })
      } else if (run.length >= 2) {
        out.push({ kind: 'group', items: run, groupKind: 'tool' })
      } else {
        for (const message of run) out.push({ kind: 'row', message })
      }
      run = []
      runKind = null
    }
    for (const message of messages()) {
      // Internal Codex resume metadata is persisted for the daemon, but it is
      // not part of the user-facing web transcript.
      if (message.author === '__verde_codex_background_snapshot') continue
      if (isCommandCardRow(message)) {
        const nextKind: 'tool' | 'subagent' = isSubagentCardRow(message) ? 'subagent' : 'tool'
        if (runKind != null && runKind !== nextKind) flush()
        runKind = nextKind
        run.push(message)
        continue
      }
      flush()
      out.push({ kind: 'row', message })
    }
    flush()
    if (!prev?.length) return out
    const prevByKey = new Map<string, RenderItem>()
    const prevGroupByMessage = new Map<string, Extract<RenderItem, { kind: 'group' }>>()
    for (const item of prev) {
      prevByKey.set(itemKey(item), item)
      if (item.kind === 'group') for (const message of item.items) prevGroupByMessage.set(message.message_id, item)
    }
    return out.map((item) => {
      const old = prevByKey.get(itemKey(item))
      if (!old && item.kind === 'group') {
        // Earlier pages can extend the first group. Keep an expanded group
        // expanded so its existing child remains available as a scroll anchor.
        const prior = item.items.map((message) => prevGroupByMessage.get(message.message_id)).find(Boolean)
        if (prior && prior.groupKind === item.groupKind) {
          const expanded = cardExpanded.get(`group:${prior.groupKind}:${prior.items[0]?.message_id ?? ''}`) ?? prior.items.some(commandFailed)
          cardExpanded.set(`group:${item.groupKind}:${item.items[0]?.message_id ?? ''}`, expanded)
        }
      }
      if (!old || old.kind !== item.kind) return item
      if (old.kind === 'row' && item.kind === 'row') {
        return old.message === item.message ? old : item
      }
      if (old.kind === 'group' && item.kind === 'group') {
        const same =
          old.items.length === item.items.length && old.items.every((m, i) => m === item.items[i])
        if (same) return old
      }
      return item
    })
  }, [])

  // Mount only the newest window of rows; "Show earlier" expands on demand.
  //
  // Mounting is time-budgeted: materializing the whole 60-row window in one
  // task (megabytes of markdown parse + layout across every open pane)
  // blocked the main thread for multiple seconds on cold load, so the user's
  // first tap — typically opening a menu, worst on mobile CPUs — sat behind
  // it. Instead mount the newest few rows immediately and prepend the rest
  // one row at a time in short slices with a yielded timer gap in between,
  // anchoring scroll so the view never visibly shifts.
  const INITIAL_MOUNT_ROWS = 8
  const UNFOCUSED_WINDOW_ROWS = 16
  const MOUNT_SLICE_BUDGET_MS = 30
  const [windowTarget, setWindowTarget] = createSignal(TRANSCRIPT_WINDOW_ROWS)
  const [rowLimit, setRowLimit] = createSignal(INITIAL_MOUNT_ROWS)
  // Panes that were never focused stop at a short tail: cold loads reveal
  // several large transcripts and the unread remainder can mount when the
  // pane is first focused instead of competing with the user's first input.
  const [everFocused, setEverFocused] = createSignal(focused())
  createEffect(() => {
    if (focused()) setEverFocused(true)
  })
  const paneTarget = () =>
    everFocused() ? windowTarget() : Math.min(UNFOCUSED_WINDOW_ROWS, windowTarget())
  const hiddenCount = createMemo(() => Math.max(0, allItems().length - rowLimit()))
  const items = createMemo(() => {
    const all = allItems()
    return hiddenCount() > 0 ? all.slice(all.length - rowLimit()) : all
  })
  let mount_slice_timer = 0
  const mountSlice = () => {
    mount_slice_timer = 0
    const el = scroller
    // Keep the viewport anchored on the rows the user was reading while
    // older rows mount above them.
    const before = el ? el.scrollHeight - el.scrollTop : 0
    const start = performance.now()
    // Each increment synchronously prepends exactly one older row; stop the
    // slice once the budget is spent so queued input can run in between.
    while (
      rowLimit() < paneTarget() &&
      hiddenCount() > 0 &&
      performance.now() - start < MOUNT_SLICE_BUDGET_MS
    ) {
      setRowLimit((limit) => limit + 1)
    }
    if (el) el.scrollTop = el.scrollHeight - before
  }
  createEffect(() => {
    if (!revealed()) return
    if (rowLimit() >= paneTarget() || hiddenCount() <= 0) return
    if (mount_slice_timer !== 0) return
    mount_slice_timer = window.setTimeout(mountSlice, 16)
  })
  onCleanup(() => window.clearTimeout(mount_slice_timer))
  // Growing the target alone mounts nothing; the budgeted slices above
  // prepend the extra rows, so a 200-row expansion no longer freezes input.
  // Expanding is explicit read intent, so it also lifts the unfocused cap.
  const showEarlier = async () => {
    if (transcript().loadingOlder) return
    pinToBottom = false
    setEverFocused(true)
    if (hiddenCount() > 0) {
      setWindowTarget((target) => Math.max(target, rowLimit()) + TRANSCRIPT_WINDOW_STEP)
      return
    }
    if (!transcript().hasOlder) return
    const route = JSON.stringify([props.pane.thread_id, props.pane.runtime_id, store.connectionFor(props.pane)])
    const node = scroller
    const previousTop = node?.scrollTop
    const viewportTop = node?.getBoundingClientRect().top ?? 0
    const anchor = node && [...node.querySelectorAll<HTMLElement>('[data-transcript-item]')]
      .find((row) => !row.querySelector('[data-transcript-item]') && row.getBoundingClientRect().bottom > viewportTop)
    const anchorKey = anchor?.dataset.transcriptItem
    const anchorTop = anchor?.getBoundingClientRect().top
    await store.loadOlderTranscript(props.pane)
    if (route !== JSON.stringify([props.pane.thread_id, props.pane.runtime_id, store.connectionFor(props.pane)])) return
    // A page boundary can merge into an already visible tool group before
    // row slices run. Preserve its viewport offset without counting unrelated
    // appended live rows; later slices anchor only their own DOM changes.
    if (node && node.scrollTop === previousTop && anchorKey && anchorTop !== undefined) {
      const current = [...node.querySelectorAll<HTMLElement>('[data-transcript-item]')]
        .find((row) => row.dataset.transcriptItem === anchorKey)
      if (current) node.scrollTop += current.getBoundingClientRect().top - anchorTop
    }
    // Budgeted mount slices preserve the position for newly revealed rows.
    setWindowTarget((target) => Math.max(target, rowLimit()) + TRANSCRIPT_WINDOW_STEP)
  }

  // Turn acceptance time while streaming — drives live group elapsed labels.
  const workingSince = createMemo(
    () => messages().find((m) => m.message_id.endsWith('-stream'))?.created_at_ms ?? null,
  )
  const subagent = () => isSubagentThreadId(props.pane.thread_id)

  return (
    <section ref={section} class={`flex min-h-0 flex-1 flex-col ${subagent() ? 'bg-[color-mix(in_srgb,var(--accent)_8%,var(--chat-black))]' : 'bg-[var(--chat-black)]'}`}>
      <header
        class={`hidden h-10 shrink-0 items-center gap-2 border-b px-3 lg:flex ${
          subagent() ? 'border-[color-mix(in_srgb,var(--accent)_55%,var(--border-muted))]' : 'border-[var(--border-muted)]'
        }`}
        onMouseDown={() => store.focusPane(props.pane)}
      >
        <Show when={subagent()}>
          <span class="shrink-0 rounded-full bg-[color-mix(in_srgb,var(--accent)_18%,transparent)] px-2 py-0.5 text-[11px] font-medium tracking-wide text-[var(--accent)]">
            Subagent
          </span>
        </Show>
        <ProviderGlyph provider={props.pane.provider} />
        <div class="min-w-0 flex-1 truncate text-[14px] font-medium">{store.paneTitle(props.pane)}</div>
        <Show when={props.pane.send_pending}>
          <Show
            when={store.pendingApproval(props.pane)}
            fallback={<span class="shrink-0 whitespace-nowrap text-[11px] tracking-wide text-[var(--accent)]">Working</span>}
          >
            <span class="shrink-0 whitespace-nowrap text-[11px] tracking-wide text-[var(--warning)]">
              <span class="lg:hidden">Needs approval</span>
              <span class="hidden lg:inline">Waiting for approval</span>
            </span>
          </Show>
        </Show>
        <ZoomButton pane={props.pane} />
        <PaneActionsButton pane={props.pane} />
      </header>
      {/* [overflow-anchor:none]: the browser's own scroll anchoring repositions
          the viewport a frame late when a tall card collapses (visible jitter)
          and would double-compensate the manual anchoring in showEarlier and
          DiffFileRow, so all anchoring here is done by hand. */}
      <div
        class="min-h-0 flex-1 overflow-y-auto px-3 py-3 scrollbar-thin lg:px-5 lg:py-5 [overflow-anchor:none]"
        data-chat-scroller
        ref={(node) => { scroller = node }}
        onScroll={onScroll}
        tabIndex={0}
        onWheel={(event) => { if (event.deltaY < 0) markReadIntent() }}
        onTouchStart={(event) => { touchY = event.touches[0]?.clientY ?? null }}
        onTouchMove={(event) => {
          const y = event.touches[0]?.clientY
          if (y !== undefined && touchY !== null && y > touchY) markReadIntent()
          touchY = y ?? null
        }}
        onKeyDown={(event) => {
          if (event.target === event.currentTarget && ['ArrowUp', 'PageUp', 'Home'].includes(event.key)) markReadIntent()
        }}
        onMouseDown={() => store.focusPane(props.pane)}
      >
        <div class="mx-auto flex w-full max-w-[900px] flex-col gap-3">
          <Show when={revealed()}>
          <Show when={messages().length > 0 && !transcript().loaded}>
            <div class="text-center text-[12px] text-[var(--text-muted)]" role="status">
              <Show when={transcript().error} fallback="Loading conversation…">
                <button type="button" class="rounded-full bg-[var(--panel-alt)] px-3 py-1.5" onClick={() => void store.retryTranscript(props.pane)}>Retry loading conversation</button>
              </Show>
            </div>
          </Show>
          <Show when={hiddenCount() > 0 || transcript().hasOlder}>
            <button
              type="button"
              class="mx-auto rounded-full bg-[var(--panel-alt)] px-3 py-1.5 text-[12px] text-[var(--text-muted)] hover:text-[var(--text)]"
              disabled={transcript().loadingOlder}
              onClick={() => void showEarlier()}
            >
              {transcript().loadingOlder ? 'Loading earlier messages…' : transcript().olderError ? 'Retry earlier messages' : 'Show earlier messages'}
            </button>
          </Show>
          <Show when={transcript().olderError}>
            <p class="text-center text-[12px] text-[var(--text-muted)]" role="status">{transcript().olderError}</p>
          </Show>
          <For each={items()}>
            {(item) => <div data-transcript-item={itemKey(item)}>
              {item.kind === 'group'
                ? <ToolCallGroup items={item.items} workingSince={workingSince()} groupKind={item.groupKind} pane={props.pane} />
                : <TranscriptRow message={item.message} pane={props.pane} />}
            </div>}
          </For>
          <Show when={messages().length === 0}>
            <Show when={!props.pane.thread_id || transcript().loaded} fallback={
              <div class="px-2 py-16 text-[var(--text-muted)]" role="status">
                <p>{transcript().error ? 'Could not load this conversation.' : 'Loading conversation…'}</p>
                <Show when={transcript().error}>
                  <button type="button" class="mt-3 rounded-full bg-[var(--panel-alt)] px-3 py-1.5 text-[13px]" onClick={() => void store.retryTranscript(props.pane)}>Retry loading conversation</button>
                </Show>
              </div>
            }>
              <EmptyTranscript pending={!props.pane.thread_id} />
            </Show>
          </Show>
          </Show>
        </div>
      </div>
      <ApprovalCard pane={props.pane} />
      <Show when={!subagent()}><ComposerFollowup pane={props.pane} /></Show>
      <Show when={!subagent()} fallback={<SubagentComposerBanner />}>
        <Composer pane={props.pane} focused={focused()} />
      </Show>
    </section>
  )
}

function EmptyTranscript(props: { pending?: boolean }) {
  return (
    <div class="px-2 py-16 text-[var(--text-subtle)]">
      <div class="wordmark text-[28px] text-[var(--text)]">
        {props.pending ? 'Opening conversation' : 'Ask anything'}
      </div>
      <p class="mt-2 max-w-md text-[15px]">
        {props.pending
          ? 'This chat is open on the desktop; its transcript is still attaching.'
          : 'or use / to show available commands'}
      </p>
    </div>
  )
}

function SubagentComposerBanner() {
  return (
    <div class="min-w-0 bg-[var(--chat-black)] px-3 pb-[max(12px,var(--safe-bottom))] lg:px-5 lg:pb-[max(16px,var(--safe-bottom))]">
      <div class="mx-auto w-full max-w-[900px] rounded-[14px] border border-[color-mix(in_srgb,var(--accent)_40%,var(--panel-muted))] bg-[color-mix(in_srgb,var(--accent)_8%,var(--panel))] px-4 py-3">
        <div class="text-[14px] font-medium text-[var(--accent)]">Read-only subagent</div>
        <p class="mt-1 text-[13px] text-[var(--text-muted)]">
          This pane shows a child agent from the parent chat. Continue the work there.
        </p>
      </div>
    </div>
  )
}

// ---- Command cards (desktop chat_panel renderCommandEventRow parity) -------

function isShellLikeBody(body: string): boolean {
  const t = body.trim()
  if (t.length < 8) return false
  return (
    t.startsWith('/usr/bin/bash') ||
    t.startsWith('/bin/bash') ||
    t.startsWith('bash -lc') ||
    t.startsWith('/usr/bin/env bash') ||
    t.startsWith('/bin/sh -lc') ||
    t.startsWith('/usr/bin/sh')
  )
}

function isCommandCardRow(message: Message): boolean {
  if (message.role !== 'system') return false
  if (message.tool_call_kind === 'subagent' || message.author === 'Subagent') return true
  if (message.tool_call_kind && message.tool_call_kind !== 'think') return true
  return (
    message.author === 'Ran command' ||
    message.author === 'Command failed' ||
    isShellLikeBody(message.body)
  )
}

function isSubagentCardRow(message: Message): boolean {
  if (message.tool_call_kind === 'subagent' || message.author === 'Subagent') return true
  // Shell/command cards are never subagents; skip scanning a megabyte of
  // output for Tool/Input/Output labels on every header paint.
  if (message.author === 'Ran command' || message.author === 'Command failed') return false
  const tool = toolBodyField(message.body, 'Tool')
  if (tool && /^(task|agent|subagent|taskexecute|spawnagent|spawn_agent)$/i.test(tool.trim())) return true
  const input = toolBodyField(message.body, 'Input') ?? ''
  if (input.includes('"subagent_type"')) return true
  const output = toolBodyField(message.body, 'Output') ?? ''
  return output.includes('<task id="')
}

function toolBodyField(body: string, label: string): string | null {
  const prefix = `${label}:\n`
  const start = body.startsWith(prefix)
    ? prefix.length
    : (() => {
        const wrapped = `\n\n${prefix}`
        const idx = body.indexOf(wrapped)
        return idx >= 0 ? idx + wrapped.length : -1
      })()
  if (start < 0) return null
  const rest = body.slice(start)
  const end = rest.indexOf('\n\n')
  const value = (end >= 0 ? rest.slice(0, end) : rest).trim()
  return value.length > 0 ? value : null
}

function commandFailed(message: Message): boolean {
  return (
    message.tool_call_status === 'failed' ||
    message.author === 'Command failed' ||
    message.body.startsWith('Command failed')
  )
}

function commandRunning(message: Message): boolean {
  return message.tool_call_status === 'in_progress' || message.tool_call_status === 'pending'
}

/// Whitespace-collapsed single-line preview, exactly like the desktop's
/// commandRowPreviewAlloc (labels like "Input:" are kept, runs collapse).
/// Only the leading slice is scanned: a 1 MiB command card would otherwise
/// run a global whitespace regex on every header paint.
const COMMAND_PREVIEW_CHARS = 400
function commandPreview(body: string): string {
  const sample = body.length > COMMAND_PREVIEW_CHARS ? body.slice(0, COMMAND_PREVIEW_CHARS) : body
  return sample.replace(/[\s\r\n\t]+/g, ' ').trim()
}

/// First `max` lines without splitting the rest of a huge tool body into an
/// array of strings (the 1 MiB Workspace 8 command card froze phones).
function takeLeadingLines(body: string, max: number): { text: string; truncated: boolean } {
  const text = body.trim()
  if (text.length === 0 || max <= 0) return { text: '', truncated: false }
  let from = 0
  for (let n = 0; n < max; n++) {
    const nl = text.indexOf('\n', from)
    if (nl < 0) return { text, truncated: false }
    from = nl + 1
  }
  return { text: text.slice(0, from - 1), truncated: from < text.length }
}

function countLines(body: string): number {
  const text = body.trim()
  if (text.length === 0) return 0
  let lines = 1
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10) lines += 1
  }
  return lines
}

function formatElapsed(startedAtMs: number, now: number): string {
  const total = Math.max(0, Math.floor((now - Math.max(startedAtMs, 0)) / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor(total / 60) % 60
  const seconds = total % 60
  const mm = String(minutes).padStart(2, '0')
  const ss = String(seconds).padStart(2, '0')
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${minutes}:${ss}`
}

function usePersistedFlag(key: () => string, fallback: () => boolean) {
  const [value, setValue] = createSignal(cardExpanded.get(key()) ?? fallback())
  const toggle = () => {
    const next = !value()
    setValue(next)
    cardExpanded.set(key(), next)
  }
  return [value, toggle] as const
}

function Chevron(props: { open: boolean }) {
  return (
    <svg
      class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)] transition-transform"
      style={{ transform: props.open ? 'rotate(180deg)' : 'rotate(0deg)' }}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  )
}

function CopyPill(props: { payload: string; label?: string; class?: string }) {
  const [status, setStatus] = createSignal('')
  let timer: ReturnType<typeof setTimeout> | undefined
  onCleanup(() => clearTimeout(timer))
  return (
    <span class="copy-control">
      <button
        type="button"
        class={props.class ?? 'copy-pill'}
        aria-label={props.label ?? 'Copy output'}
        title={props.label ?? 'Copy output'}
        onClick={async (event) => {
          event.stopPropagation()
          clearTimeout(timer)
          try {
            await copyText(props.payload)
            setStatus('Copied')
            timer = setTimeout(() => setStatus(''), 1800)
          } catch { setStatus('Copy failed. Select and copy manually.') }
        }}
      >Copy</button>
      <span class="copy-status" role="status" aria-live="polite">{status()}</span>
    </span>
  )
}

function CommandCard(props: { message: Message; child?: boolean; pane?: LivePane }) {
  const failed = () => commandFailed(props.message)
  const running = () => commandRunning(props.message)
  const subagent = createMemo(() => isSubagentCardRow(props.message))
  const [expanded, toggleExpanded] = usePersistedFlag(
    () => `cmd:${props.message.message_id}`,
    failed,
  )
  const [showAll, toggleShowAll] = usePersistedFlag(
    () => `cmd-more:${props.message.message_id}`,
    () => false,
  )
  const label = () => props.message.author || 'Ran command'
  const preview = createMemo(() => commandPreview(props.message.body))
  const leading = createMemo(() => takeLeadingLines(props.message.body, TOOL_OUTPUT_COLLAPSED_LINES))
  const truncated = () => !showAll() && leading().truncated
  const visibleBody = () => (showAll() ? props.message.body.trim() : leading().text)
  const lineCount = createMemo(() => {
    if (!expanded() || !truncated()) return 0
    return countLines(props.message.body)
  })
  const textColor = () => (failed() ? 'text-[var(--danger)]' : 'text-[var(--text-muted)]')
  const openSubagent = (event: MouseEvent) => {
    event.stopPropagation()
    const pane = props.pane
    if (!pane) return
    void store.openSubagent(pane, props.message)
  }

  return (
    <div
      class={`min-w-0 border ${props.child ? 'rounded-[8px] bg-[#0b0f10] border-[rgba(60,71,76,0.73)]' : 'rounded-[10px] bg-[var(--panel-alt)] border-[var(--border-muted)]'} ${failed() ? '!border-[var(--danger)]' : ''} ${subagent() ? '!border-[color-mix(in_srgb,var(--accent)_45%,var(--border-muted))]' : ''}`}
    >
      <button
        type="button"
        class="flex w-full min-w-0 items-center gap-2 px-3.5 py-[8px] text-left"
        onClick={toggleExpanded}
      >
        <span
          class={`h-2 w-2 shrink-0 rounded-full ${running() ? 'cmd-dot-pulse' : ''}`}
          style={{ background: failed() ? 'var(--danger)' : 'var(--accent)' }}
        />
        <span class={`mono shrink-0 text-[13px] ${textColor()}`}>{props.child ? '$' : '>_'}</span>
        <span class={`mono shrink-0 text-[13px] ${textColor()}`}>{label()}</span>
        <Show when={preview().length > 0}>
          <span class={`mono shrink-0 text-[13px] ${textColor()}`}>-</span>
          <span class={`mono min-w-0 flex-1 truncate text-[13px] ${textColor()}`}>{preview()}</span>
        </Show>
        <Show when={preview().length === 0}>
          <span class="min-w-0 flex-1" />
        </Show>
        <Show when={subagent() && props.pane}>
          <button
            type="button"
            class="shrink-0 rounded-[5px] bg-[color-mix(in_srgb,var(--accent)_16%,transparent)] px-2.5 py-1 text-[11px] text-[var(--accent)] hover:bg-[color-mix(in_srgb,var(--accent)_28%,transparent)] hover:text-white"
            onClick={openSubagent}
          >
            Open
          </button>
        </Show>
        <CopyPill payload={props.message.body} />
        <Chevron open={expanded()} />
      </button>
      <Show when={expanded()}>
        <div class="px-3.5 pb-2.5">
          <pre class={`mono max-w-full overflow-x-auto text-[12.5px] leading-[1.45] whitespace-pre-wrap break-words ${textColor()}`}>{visibleBody()}</pre>
          <Show when={truncated()}>
            <button
              type="button"
              class="mt-1.5 rounded-[5px] bg-[rgba(56,57,62,0.34)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] hover:text-white"
              onClick={toggleShowAll}
            >
              Show all {lineCount()} lines
            </button>
          </Show>
        </div>
      </Show>
    </div>
  )
}

// Grouped card: "N tool calls  ·  X completed  ·  Y failed  ·  Z running  ·  m:ss"
function ToolCallGroup(props: { items: Message[]; workingSince: number | null; groupKind: 'tool' | 'subagent'; pane: LivePane }) {
  const counts = createMemo(() => {
    let failed = 0
    let running = 0
    for (const message of props.items) {
      if (commandFailed(message)) failed += 1
      else if (commandRunning(message)) running += 1
    }
    return { count: props.items.length, failed, running, completed: props.items.length - failed - running }
  })
  const [expanded, toggleExpanded] = usePersistedFlag(
    () => `group:${props.groupKind}:${props.items[0]?.message_id ?? ''}`,
    () => counts().failed > 0,
  )
  const summary = () => {
    const { count, failed, running, completed } = counts()
    const noun =
      props.groupKind === 'subagent'
        ? count === 1
          ? 'subagent'
          : 'subagents'
        : count === 1
          ? 'tool call'
          : 'tool calls'
    const parts = [`${count} ${noun}`, `${completed} completed`]
    if (failed > 0) parts.push(`${failed} failed`)
    if (running > 0) parts.push(`${running} running`)
    if (running > 0 && props.workingSince != null) parts.push(formatElapsed(props.workingSince, nowMs()))
    // Non-breaking spaces: HTML would collapse the desktop's "  ·  " gaps.
    return parts.join('  ·  ')
  }
  const dotStyle = () => {
    const { count, failed, running } = counts()
    const base = running > 0 ? 'var(--accent)' : 'var(--text-muted)'
    if (failed >= count && count > 0) return { background: 'var(--danger)' }
    if (failed > 0) {
      // Partial failure: red pie slice proportional to failures (desktop parity).
      const frac = Math.round((failed / count) * 100)
      return { background: `conic-gradient(var(--danger) ${frac}%, ${base} 0)` }
    }
    return { background: base }
  }
  return (
    <div
      class="min-w-0 rounded-[10px] border bg-[rgba(40,41,46,0.92)]"
      style={{
        'border-color':
          counts().running > 0 && counts().failed === 0 ? 'var(--accent)' : 'var(--border-muted)',
      }}
    >
      <button
        type="button"
        class="flex h-11 w-full min-w-0 items-center gap-2.5 px-3.5 text-left"
        onClick={toggleExpanded}
      >
        <span class="h-[9px] w-[9px] shrink-0 rounded-full" style={dotStyle()} />
        <span class="min-w-0 flex-1 truncate text-[13px] text-[var(--text-muted)]">{summary()}</span>
        <Chevron open={expanded()} />
      </button>
      <Show when={expanded()}>
        <div class="flex flex-col gap-2 px-2.5 pb-2.5">
          <For each={props.items}>{(message) => <div data-transcript-item={`r:${message.message_id}`}><CommandCard message={message} child pane={props.pane} /></div>}</For>
        </div>
      </Show>
    </div>
  )
}

// ---- Changed-files diff card (desktop renderDiffSummaryCard parity) --------

interface DiffFileEntry {
  path: string
  additions: number
  deletions: number
  patch: string
}

const DIFF_MARKER_V2 = 'VERDE_DIFF_V2\n'
const DIFF_MARKER_V1 = 'EDITORTS_DIFF_V1\n'

function isDiffSummaryRow(message: Message): boolean {
  return (
    message.role === 'system' &&
    message.author === 'Changed files' &&
    (message.body.startsWith(DIFF_MARKER_V2) || message.body.startsWith(DIFF_MARKER_V1))
  )
}

/// V2 bodies length-prefix path and patch in BYTES (the daemon writes byte
/// counts), so parsing walks the UTF-8 encoding, not JS string indices.
function parseDiffV2(rest: string): DiffFileEntry[] | null {
  const bytes = new TextEncoder().encode(rest)
  const decoder = new TextDecoder()
  const files: DiffFileEntry[] = []
  let offset = 0
  while (offset < bytes.length) {
    const nl = bytes.indexOf(0x0a, offset)
    if (nl < 0) return null
    const header = decoder.decode(bytes.subarray(offset, nl))
    offset = nl + 1
    if (!header.startsWith('FILE\t')) return null
    const fields = header.slice('FILE\t'.length).split('\t')
    if (fields.length !== 4) return null
    const [path_len, additions, deletions, patch_len] = fields.map(Number)
    if (![path_len, additions, deletions, patch_len].every((value) => Number.isSafeInteger(value) && value >= 0)) return null
    if (path_len > bytes.length - offset || patch_len > bytes.length - offset - path_len) return null
    const path = decoder.decode(bytes.subarray(offset, offset + path_len))
    offset += path_len
    const patch = decoder.decode(bytes.subarray(offset, offset + patch_len))
    offset += patch_len
    files.push({ path, additions, deletions, patch })
  }
  return files
}

function parseDiffV1(rest: string): DiffFileEntry[] | null {
  const bytes = new TextEncoder().encode(rest)
  const decoder = new TextDecoder()
  const files: DiffFileEntry[] = []
  let offset = 0
  while (offset < bytes.length) {
    const nl = bytes.indexOf(0x0a, offset)
    if (nl < 0) break
    const header = decoder.decode(bytes.subarray(offset, nl))
    offset = nl + 1
    if (header.length === 0) continue
    if (!header.startsWith('FILE\t')) continue
    const fields = header.slice('FILE\t'.length).split('\t')
    const path = fields[0] ?? ''
    const additions = Number(fields[1] ?? '0') || 0
    const deletions = Number(fields[2] ?? '0') || 0
    const patch_len = Number(fields[3] ?? '0') || 0
    if (![additions, deletions, patch_len].every((value) => Number.isSafeInteger(value) && value >= 0)) return null
    if (patch_len > bytes.length - offset) break
    const patch = decoder.decode(bytes.subarray(offset, offset + patch_len))
    offset += patch_len
    if (offset < bytes.length && bytes[offset] === 0x0a) offset += 1
    files.push({ path, additions, deletions, patch })
  }
  return files
}

function parseDiffSummary(body: string): DiffFileEntry[] | null {
  if (body.startsWith(DIFF_MARKER_V2)) return parseDiffV2(body.slice(DIFF_MARKER_V2.length))
  if (body.startsWith(DIFF_MARKER_V1)) return parseDiffV1(body.slice(DIFF_MARKER_V1.length))
  return null
}

type DiffLayout = 'stacked' | 'split'
const DIFF_LAYOUT_KEY = 'verde.web.diff_layout'
function readDiffLayout(): DiffLayout {
  try {
    return localStorage.getItem(DIFF_LAYOUT_KEY) === 'split' ? 'split' : 'stacked'
  } catch {
    return 'stacked'
  }
}
// One preference for every diff card (desktop parity), so it is module state.
const [diffLayout, setDiffLayoutSignal] = createSignal<DiffLayout>(readDiffLayout())
function setDiffLayout(layout: DiffLayout) {
  setDiffLayoutSignal(layout)
  try {
    localStorage.setItem(DIFF_LAYOUT_KEY, layout)
  } catch {
    // Private mode: the preference just lasts for this page.
  }
}
// Split needs two readable columns; below lg it always renders stacked.
const wideQuery = typeof matchMedia === 'function' ? matchMedia('(min-width: 1024px)') : null
const [wideScreen, setWideScreen] = createSignal(wideQuery?.matches ?? false)
wideQuery?.addEventListener('change', (event) => setWideScreen(event.matches))

type DiffLineKind = 'meta' | 'hunk' | 'add' | 'del' | 'ctx'
interface DiffLine {
  kind: DiffLineKind
  text: string
  old_no: number | null
  new_no: number | null
  // [start, end) of the changed span within text, for paired -/+ lines.
  emph?: [number, number]
}
interface DiffSplitRow {
  full?: DiffLine
  left?: DiffLine
  right?: DiffLine
}

function parsePatchLines(patch: string): DiffLine[] {
  const lines: DiffLine[] = []
  let old_no = 0
  let new_no = 0
  let in_hunk = false
  for (const raw of patch.split('\n')) {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw)
    if (hunk) {
      old_no = Number(hunk[1])
      new_no = Number(hunk[2])
      in_hunk = true
      lines.push({ kind: 'hunk', text: raw, old_no: null, new_no: null })
    } else if (!in_hunk || raw.startsWith('\\')) {
      lines.push({ kind: 'meta', text: raw, old_no: null, new_no: null })
    } else if (raw.startsWith('+')) {
      lines.push({ kind: 'add', text: raw.slice(1), old_no: null, new_no: new_no++ })
    } else if (raw.startsWith('-')) {
      lines.push({ kind: 'del', text: raw.slice(1), old_no: old_no++, new_no: null })
    } else if (raw.startsWith('diff ') || raw.startsWith('index ')) {
      in_hunk = false
      lines.push({ kind: 'meta', text: raw, old_no: null, new_no: null })
    } else {
      lines.push({ kind: 'ctx', text: raw.slice(1), old_no: old_no++, new_no: new_no++ })
    }
  }
  if (lines.at(-1)?.kind === 'ctx' && lines.at(-1)?.text === '') lines.pop()
  markWordEmphasis(lines)
  return lines
}

/// Pairs each run of deletions with the additions that follow it and marks the
/// span between their common prefix and suffix (desktop word-level emphasis).
function markWordEmphasis(lines: DiffLine[]) {
  let i = 0
  while (i < lines.length) {
    if (lines[i].kind !== 'del') { i += 1; continue }
    let adds = i
    while (adds < lines.length && lines[adds].kind === 'del') adds += 1
    let end = adds
    while (end < lines.length && lines[end].kind === 'add') end += 1
    const pairs = Math.min(adds - i, end - adds)
    for (let k = 0; k < pairs; k += 1) {
      const a = lines[i + k]
      const b = lines[adds + k]
      const spans = emphasisSpans(a.text, b.text)
      if (!spans) continue
      a.emph = spans.a
      b.emph = spans.b
    }
    i = end
  }
}

function splitRows(lines: DiffLine[]): DiffSplitRow[] {
  const rows: DiffSplitRow[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    if (line.kind === 'meta' || line.kind === 'hunk') { rows.push({ full: line }); i += 1; continue }
    if (line.kind === 'ctx') { rows.push({ left: line, right: line }); i += 1; continue }
    let adds = i
    while (adds < lines.length && lines[adds].kind === 'del') adds += 1
    let end = adds
    while (end < lines.length && lines[end].kind === 'add') end += 1
    const count = Math.max(adds - i, end - adds)
    for (let k = 0; k < count; k += 1) {
      rows.push({
        left: i + k < adds ? lines[i + k] : undefined,
        right: adds + k < end ? lines[adds + k] : undefined,
      })
    }
    i = end
  }
  return rows
}

function diffTextClass(kind: DiffLineKind): string {
  if (kind === 'add') return 'text-[var(--diff-add)]'
  if (kind === 'del') return 'text-[var(--danger)]'
  if (kind === 'ctx') return 'text-[var(--text-muted)]'
  return 'text-[var(--text-subtle)]'
}

function DiffText(props: { line: DiffLine }) {
  const emph = () => props.line.emph
  return (
    <Show when={emph() && emph()![1] > emph()![0]} fallback={<>{props.line.text.length > 0 ? props.line.text : ' '}</>}>
      {props.line.text.slice(0, emph()![0])}
      <span class={props.line.kind === 'add' ? 'diff-emph-add' : 'diff-emph-del'}>
        {props.line.text.slice(emph()![0], emph()![1])}
      </span>
      {props.line.text.slice(emph()![1])}
    </Show>
  )
}

function DiffCell(props: { line?: DiffLine; side: 'old' | 'new' }) {
  return (
    <Show when={props.line} fallback={<><span class="diff-no" aria-hidden="true" /><span class="diff-blank" aria-hidden="true" /></>}>
      {(line) => (
        <>
          <span class="diff-no">{(props.side === 'old' ? line().old_no : line().new_no) ?? ''}</span>
          <span class={`diff-text diff-bg-${line().kind} ${diffTextClass(line().kind)}`}>
            <span class="diff-sign">{line().kind === 'add' ? '+' : line().kind === 'del' ? '−' : ' '}</span>
            <DiffText line={line()} />
          </span>
        </>
      )}
    </Show>
  )
}

function DiffPatch(props: { patch: string; path: string }) {
  const [showAll, setShowAll] = createSignal(false)
  const allLines = createMemo(() => parsePatchLines(props.patch))
  const lines = createMemo(() => showAll() ? allLines() : allLines().slice(0, 2000))
  const split = () => diffLayout() === 'split' && wideScreen()
  return (
    <div class="mono diff-patch mb-2 max-w-full overflow-x-auto text-[12.5px] leading-[1.45] scrollbar-thin">
      <Show
        when={split()}
        fallback={
          <div class="diff-grid diff-grid-stacked">
            <For each={lines()}>
              {(line) => (
                <Show
                  when={line.kind !== 'meta' && line.kind !== 'hunk'}
                  fallback={<span class={`diff-full ${diffTextClass(line.kind)}`}>{line.text.length > 0 ? line.text : ' '}</span>}
                >
                  <span class="diff-no">{line.new_no ?? line.old_no ?? ''}</span>
                  <span class={`diff-text diff-bg-${line.kind} ${diffTextClass(line.kind)}`}>
                    <span class="diff-sign">{line.kind === 'add' ? '+' : line.kind === 'del' ? '-' : ' '}</span>
                    <DiffText line={line} />
                  </span>
                </Show>
              )}
            </For>
          </div>
        }
      >
        <div class="diff-grid diff-grid-split">
          <For each={splitRows(lines())}>
            {(row) => (
              <Show
                when={!row.full}
                fallback={<span class={`diff-full ${diffTextClass(row.full!.kind)}`}>{row.full!.text.length > 0 ? row.full!.text : ' '}</span>}
              >
                <DiffCell line={row.left} side="old" />
                <DiffCell line={row.right} side="new" />
              </Show>
            )}
          </For>
        </div>
      </Show>
      <Show when={!showAll() && allLines().length > 2000}>
        <button type="button" class="diff-show-all" aria-label={`Show all ${allLines().length} patch lines for ${props.path}`} onClick={() => setShowAll(true)}>
          Showing 2,000 of {allLines().length.toLocaleString()} lines · Show all
        </button>
      </Show>
    </div>
  )
}

function DiffFileRow(props: { file: DiffFileEntry; cardId: string; pane: LivePane }) {
  const [expanded, toggleExpanded] = usePersistedFlag(
    () => `diff:${props.cardId}:${props.file.path}`,
    () => false,
  )
  let row_el: HTMLDivElement | undefined
  // Toggling a tall patch changes the transcript height by hundreds of pixels;
  // Solid updates the DOM synchronously, so measuring the row before and after
  // and re-adjusting scrollTop in the same task keeps this header stationary
  // in the viewport with no intermediate paint (no collapse jitter).
  const toggleAnchored = () => {
    const scroll_host = row_el?.closest<HTMLElement>('[data-chat-scroller]') ?? null
    const top_before = row_el?.getBoundingClientRect().top
    toggleExpanded()
    if (row_el && scroll_host && top_before !== undefined) {
      const drift = row_el.getBoundingClientRect().top - top_before
      if (drift !== 0) scroll_host.scrollTop += drift
    }
  }
  return (
    <div ref={(node) => { row_el = node }}>
      <button
        type="button"
        class="diff-file-toggle"
        aria-expanded={expanded()}
        aria-label={`${expanded() ? 'Collapse' : 'Expand'} patch for ${props.file.path}`}
        title={props.file.path}
        onClick={toggleAnchored}
      >
        <Chevron open={expanded()} />
        <span class="mono min-w-0 flex-1 truncate text-[13px] text-[var(--text)]">{props.file.path}</span>
        <span class="mono shrink-0 text-[12px] text-[var(--diff-add)]">+{props.file.additions}</span>
        <span class="mono shrink-0 text-[12px] text-[var(--danger)]">−{props.file.deletions}</span>
      </button>
      <Show when={expanded()}>
        <div class="diff-file-actions" role="group" aria-label={`Actions for ${props.file.path}`}>
          <button type="button" class="diff-action" aria-label={`Comment on ${props.file.path}`}
            onClick={() => store.beginDiffComment(props.pane, props.file)}>Comment</button>
          <button type="button" class="diff-action" aria-label={`Open ${props.file.path}`}
            onClick={() => openFileViewer(props.file.path)}>Open</button>
          <CopyPill payload={props.file.patch} label={`Copy patch for ${props.file.path}`} class="diff-action" />
        </div>
        <DiffPatch patch={props.file.patch} path={props.file.path} />
      </Show>
    </div>
  )
}

function DiffCard(props: { message: Message; pane: LivePane }) {
  const files = createMemo(() => parseDiffSummary(props.message.body))
  const totals = createMemo(() => {
    let additions = 0
    let deletions = 0
    for (const file of files() ?? []) {
      additions += file.additions
      deletions += file.deletions
    }
    return { additions, deletions }
  })
  return (
    <Show
      when={files()}
      fallback={
        <div class="rounded-[10px] border border-[var(--danger)] bg-[var(--panel-alt)] px-3.5 py-3">
          <div class="text-[14px] text-[var(--text)]">Diff could not be decoded</div>
          <div class="mt-1 text-[12px] text-[var(--text-muted)]">
            The provider payload was incomplete or malformed.
          </div>
        </div>
      }
    >
      {(parsed) => (
        <div class="min-w-0 rounded-[10px] border border-[var(--panel-muted)] bg-[var(--panel-alt)] px-3.5 pt-3 pb-1">
          <div class="flex h-[26px] items-center gap-2">
            <div class="min-w-0 flex-1 truncate text-[14px] text-[var(--text)]">
              Changed files — {parsed().length} {parsed().length === 1 ? 'file' : 'files'}
            </div>
            <div role="group" aria-label="Diff layout" class="hidden shrink-0 overflow-hidden rounded-[6px] bg-[var(--panel-muted)] text-[11px] lg:flex">
              <For each={['stacked', 'split'] as const}>
                {(layout) => (
                  <button
                    type="button"
                    aria-pressed={diffLayout() === layout}
                    class={`px-2.5 py-1 capitalize ${diffLayout() === layout ? 'bg-[var(--accent-wash)] text-[var(--text)]' : 'text-[var(--text-muted)] hover:text-[var(--text)]'}`}
                    onClick={() => setDiffLayout(layout)}
                  >
                    {layout}
                  </button>
                )}
              </For>
            </div>
            <div class="mono flex shrink-0 gap-2 text-[13px] text-[var(--text-muted)]">
              <span>+{totals().additions}</span>
              <span>-{totals().deletions}</span>
            </div>
          </div>
          <div class="mt-2 border-t border-[var(--panel-muted)]" />
          <Show when={parsed().length === 0}>
            <div class="py-3 text-[13px] text-[var(--text-muted)]">
              Diff data is empty or could not be restored.
            </div>
          </Show>
          <For each={parsed()}>
            {(file) => <DiffFileRow file={file} cardId={props.message.message_id} pane={props.pane} />}
          </For>
        </div>
      )}
    </Show>
  )
}

// ---- Code blocks -----------------------------------------------------------

/// Sanitized markdown body plus code-block decoration.
function MarkdownBody(props: { html: string; highlight: boolean }) {
  let el: HTMLDivElement | undefined
  createEffect(() => {
    void props.html
    if (el) decorateCodeBlocks(el, props.highlight)
  })
  return <div class="markdown" ref={(node) => { el = node }} innerHTML={props.html} onClick={handleFileCitationClick} />
}

// ---- Rows ------------------------------------------------------------------

function TranscriptRow(props: { message: Message; pane: LivePane }) {
  if (props.message.message_id.endsWith('-stream')) {
    return <WorkingRow message={props.message} pane={props.pane} />
  }
  if (isDiffSummaryRow(props.message)) {
    return <DiffCard message={props.message} pane={props.pane} />
  }
  if (isCommandCardRow(props.message)) {
    return <CommandCard message={props.message} pane={props.pane} />
  }

  const usage = props.message.role === 'system' ? parseUsageSummary(props.message.author, props.message.body) : null
  if (usage && (usage.limits.length || usage.stats.length || usage.recent.length)) return <UsageCard usage={usage} />

  const mine = props.message.role === 'user'
  const html = () => renderMarkdown(props.message.body)

  if (mine) {
    return (
      <article class="flex justify-center">
        <div class="w-full max-w-full rounded-[10px] bg-[var(--user-bubble)] px-3 py-2 text-[15px] leading-[21px] break-words [overflow-wrap:anywhere] text-[var(--text)] lg:max-w-[36rem] lg:px-4 lg:py-2.5">
          <div class="mb-1 text-[11px] text-[var(--time)]">You</div>
          <MessageAttachments images={props.message.images ?? []} />
          <Show when={props.message.body.length > 0}>
            <div class="whitespace-pre-wrap break-words [overflow-wrap:anywhere]">{props.message.body}</div>
          </Show>
        </div>
      </article>
    )
  }

  return (
    <article class="min-w-0 rounded-[10px] border border-[var(--border-muted)] bg-[var(--assistant-card)] px-3 py-3 lg:px-4">
          <div class="mb-1.5 text-[12px] text-[var(--text-subtle)]">{props.message.author || 'Assistant'}</div>
          <MarkdownBody html={html()} highlight />
    </article>
  )
}

function MessageAttachments(props: { images: Attachment[] }) {
  return (
    <Show when={props.images.length > 0}>
      <div class="mb-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
        <For each={props.images}>
          {(image) => {
            const src = chatImageUrl(image)
            return (
              <Show
                when={src}
                fallback={
                  <div class="flex min-h-16 items-center gap-2 rounded-[8px] bg-black/15 px-3 text-[12px] text-[var(--text-muted)]">
                    <Icon name="paperclip" class="h-4 w-4 shrink-0" />
                    <span class="truncate">{attachmentLabel(image)}</span>
                  </div>
                }
              >
                <img
                  src={src!}
                  alt={attachmentLabel(image)}
                  class="max-h-48 w-full rounded-[8px] bg-black/20 object-contain"
                  loading="lazy"
                />
              </Show>
            )
          }}
        </For>
      </div>
    </Show>
  )
}

function attachmentLabel(attachment: Attachment): string {
  return attachment.name || attachment.path.split(/[\\/]/).filter(Boolean).at(-1) || 'Image attachment'
}

/// The streaming assistant bubble: author slot carries the desktop's ticking
/// Pending tool approval, pinned between transcript and composer so the
/// decision is reachable without scrolling; long bodies scroll inside the card.
function ApprovalCard(props: { pane: LivePane }) {
  const approval = () => store.pendingApproval(props.pane)
  // Busy is keyed to the call so a follow-up approval starts enabled.
  const callKey = () => {
    const current = approval()
    return current ? current.call_id || current.turn_id : undefined
  }
  const [busyCall, setBusyCall] = createSignal<string | null>(null)
  const [sent, setSent] = createSignal<'approve' | 'deny' | null>(null)
  let release: ReturnType<typeof setTimeout> | undefined
  onCleanup(() => clearTimeout(release))
  const resolve = async (decision: 'approve' | 'deny') => {
    const key = callKey()
    if (!key || busyCall() === key) return
    setBusyCall(key)
    setSent(decision)
    const ok = await store.resolveApproval(props.pane, decision).catch(() => false)
    // Success keeps the buttons disabled until the card leaves (the key
    // changes); only a failure hands them back. The timer is a safety net for
    // a resolution the daemon accepted but never reflected.
    clearTimeout(release)
    if (!ok) setBusyCall(null)
    else release = setTimeout(() => setBusyCall((held) => (held === key ? null : held)), 15000)
  }
  const busy = () => busyCall() != null && busyCall() === callKey()
  // Keyboard-open phones: the body collapses so the transcript keeps some room.
  const viewHeight = () => window.visualViewport?.height ?? window.innerHeight
  const [short, setShort] = createSignal(viewHeight() < 420)
  const [details, setDetails] = createSignal(false)
  const onViewport = () => setShort(viewHeight() < 420)
  const viewport: EventTarget = window.visualViewport ?? window
  viewport.addEventListener('resize', onViewport)
  onCleanup(() => viewport.removeEventListener('resize', onViewport))
  const button = 'min-h-[44px] min-w-[88px] rounded-[8px] px-4 text-[13px] font-medium disabled:cursor-default focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)] lg:min-h-[32px]'
  const dimmed = (decision: 'approve' | 'deny') => (busy() && sent() !== decision ? 'opacity-40' : busy() ? 'opacity-80' : '')
  return (
    // Keyed by call id (turn id when the provider sends none): snapshot polls
    // hand back fresh objects, which must not remount (and re-animate) the card.
    <Show when={callKey()} keyed>
      {(_key) => { const current = approval()!; return (
        <div class="flex min-h-0 shrink flex-col px-3 pb-2 lg:px-5">
          <span class="sr-only" aria-live="polite">{`Approval required: ${current.title}`}</span>
          <section
            role="group"
            aria-label={`Approval required: ${current.title}`}
            aria-busy={busy()}
            class="anim-pop mx-auto flex min-h-0 w-full max-w-[900px] flex-col gap-2 rounded-[10px] border border-[color-mix(in_srgb,var(--warning)_55%,var(--border-muted))] bg-[var(--assistant-card)] px-3 py-2.5 lg:px-4"
          >
            <div class="flex shrink-0 items-center gap-2">
              <span aria-hidden="true" class="cmd-dot-pulse h-2 w-2 shrink-0 rounded-full bg-[var(--warning)]" />
              <div class="min-w-0 flex-1">
                <div class="text-[11px] tracking-wide text-[var(--warning)]">Approval required</div>
                <div class="line-clamp-2 text-[14px] font-medium lg:line-clamp-none lg:truncate" title={current.title}>{current.title}</div>
              </div>
              <CopyPill payload={current.body} />
            </div>
            <Show when={current.body.length > 0}>
              <Show
                when={!short() || details()}
                fallback={
                  <button
                    type="button"
                    class="min-h-[40px] shrink-0 self-start rounded-[6px] px-2 text-[12px] text-[var(--text-muted)] hover:bg-[var(--panel-muted)] hover:text-[var(--text)]"
                    aria-expanded="false"
                    onClick={() => setDetails(true)}
                  >
                    Show details
                  </button>
                }
              >
                <pre
                  tabindex="0"
                  role="region"
                  aria-label="Approval details"
                  class="max-h-[calc(var(--app-height,100dvh)*0.22)] min-h-[3.5em] flex-1 overflow-auto overscroll-contain whitespace-pre-wrap break-words rounded-[6px] bg-[var(--chat-black)] px-2.5 py-2 font-mono text-[12px] leading-[1.45] text-[var(--text-muted)] scrollbar-thin lg:max-h-[calc(var(--app-height,100dvh)*0.3)]"
                >{current.body}</pre>
              </Show>
            </Show>
            <div class="flex shrink-0 justify-end gap-2">
              <button
                type="button"
                class={`${button} border border-[var(--border-muted)] bg-[var(--panel-muted)] text-[var(--text)] enabled:hover:bg-[var(--border-muted)] ${dimmed('deny')}`}
                disabled={busy()}
                onClick={() => void resolve('deny')}
              >
                {busy() && sent() === 'deny' ? 'Sending…' : 'Decline'}
              </button>
              <button
                type="button"
                class={`${button} bg-[var(--accent)] text-[var(--chat-black)] enabled:hover:bg-[var(--accent-hi)] ${dimmed('approve')}`}
                disabled={busy()}
                onClick={() => void resolve('approve')}
              >
                {busy() && sent() === 'approve' ? 'Sending…' : 'Allow'}
              </button>
            </div>
          </section>
        </div>
      ) }}
    </Show>
  )
}

/// "Working - m:ss" / "Thinking - m:ss" label; an empty stream shows the
/// waiting placeholder.
function WorkingRow(props: { message: Message; pane: LivePane }) {
  const label = () => {
    const started = props.message.created_at_ms
    const verb = store.pendingApproval(props.pane) ? 'Waiting for approval' : props.message.author || 'Working'
    return started ? `${verb} - ${formatElapsed(started, nowMs())}` : verb
  }
  // Every streamed delta re-renders this row with a longer body, and each
  // body is unique so the parse cache cannot help. Parsing the entire
  // accumulated stream per delta blocked the main thread (and typing) on
  // long turns, so parse only a bounded tail; the viewer is pinned to the
  // bottom while streaming, and commit swaps in the fully parsed row.
  const STREAM_PARSE_MAX = 16_000
  const html = () => {
    const body = props.message.body
    if (body.length <= STREAM_PARSE_MAX) return renderSafeMarkdown(body, { fileCitations: true })
    const cut = body.indexOf('\n', body.length - STREAM_PARSE_MAX)
    const tail = cut >= 0 ? body.slice(cut + 1) : body.slice(body.length - STREAM_PARSE_MAX)
    return renderSafeMarkdown(tail, { fileCitations: true })
  }
  return (
    <article class="min-w-0 rounded-[10px] border border-[var(--border-muted)] bg-[var(--assistant-card)] px-3 py-3 lg:px-4">
      <div class="mb-1.5 flex items-center gap-2 text-[12px] text-[var(--text-subtle)]">
        <span class="cmd-dot-pulse h-2 w-2 rounded-full bg-[var(--accent)]" />
        {label()}
      </div>
      <Show
        when={props.message.body.length > 0}
        fallback={<div class="text-[14px] italic text-[var(--text-subtle)]">Waiting for streamed output...</div>}
      >
        {/* No highlighting while streaming: re-tokenizing per delta stalls input. */}
        <MarkdownBody html={html()} highlight={false} />
      </Show>
    </article>
  )
}

function Composer(props: { pane: LivePane; focused: boolean }) {
  let field: HTMLTextAreaElement | undefined
  let filePicker: HTMLInputElement | undefined
  const [suggestions, setSuggestions] = createSignal<ComposerSuggestControls>()
  const [suggestDraft, setSuggestDraft] = createSignal('')
  const [caret, setCaret] = createSignal(0), [composing, setComposing] = createSignal(false)
  const updateSuggestions = () => { if (field) { setSuggestDraft(field.value); setCaret(field.selectionStart) } }
  const running = () => store.paneWorking(props.pane)
  const sendLabel = () => running() ? (store.followupKindFor(props.pane) === 'steer' ? 'Steer' : 'Queue') : 'Send'


  // Draft cache key is captured at mount. The textarea itself is
  // uncontrolled: the browser owns the caret/IME until submit, so snapshot
  // refreshes and per-keystroke store writes cannot assign `value` mid-edit
  // (that path ate Android/iOS composition and made Return feel like Send).
  const composer_pane = props.pane

  const attachments = () => store.attachmentsFor(composer_pane)
  const uploading = () => store.uploadingAttachmentsFor(composer_pane)
  const [blank, setBlank] = createSignal(store.draftFor(composer_pane).trim().length === 0)

  const persistDraft = () => {
    // While send owns the draft (optimistic clear / rollback), a remount
    // must not write the textarea back over that store state.
    if (store.sending()) return
    if (field) store.setDraftFor(composer_pane, field.value)
  }

  const syncFieldFromStore = () => {
    if (!field) return
    field.value = store.draftFor(composer_pane)
    setBlank(field.value.trim().length === 0)
  }

  const submitDraft = () => {
    if (uploading() || store.sending()) return
    persistDraft()
    suggestions()?.close()
    if (field) {
      field.value = ''
      setBlank(true)
    }
    void store.sendDraft(props.pane).then(syncFieldFromStore)
  }

  onCleanup(persistDraft)

  createEffect(() => {
    const nonce = store.composerNonce()
    if (!props.focused || nonce <= handledComposerFocusNonce) return
    handledComposerFocusNonce = nonce
    // Diff-comment prefills (and focus_prompt) land in the store; copy once.
    syncFieldFromStore()
    focusChatPrompt(field, store.compact(), store.composerFocusExplicit())
  })

  const onKeyDown = (event: KeyboardEvent) => {
    if (composing()) return
    if (suggestions()?.keydown(event)) { event.stopPropagation(); return }
    if (!composerEnterShouldSubmit(event, {
      compact: store.compact(),
      coarsePointer: window.matchMedia('(pointer: coarse)').matches,
    })) return
    event.preventDefault()
    submitDraft()
  }

  // Mobile composer resize: height is view state for this composer only.
  const COMPOSER_MIN_HEIGHT = 52
  const [composerHeight, setComposerHeight] = createSignal<number | null>(null)
  let composerDrag: { pointer_id: number; start_y: number; start_height: number } | null = null
  // A pending approval card shares the column, so the composer yields room.
  const composerMaxHeight = () =>
    Math.max(
      COMPOSER_MIN_HEIGHT,
      Math.round((window.visualViewport?.height ?? window.innerHeight) * (store.pendingApproval(props.pane) ? 0.35 : 0.6)),
    )
  const startComposerDrag = (event: PointerEvent) => {
    if (!field) return
    event.preventDefault()
    ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)
    composerDrag = { pointer_id: event.pointerId, start_y: event.clientY, start_height: field.getBoundingClientRect().height }
  }
  const moveComposerDrag = (event: PointerEvent) => {
    if (!composerDrag || event.pointerId !== composerDrag.pointer_id) return
    // Dragging up (smaller clientY) grows the box.
    const next = composerDrag.start_height + (composerDrag.start_y - event.clientY)
    setComposerHeight(Math.min(composerMaxHeight(), Math.max(COMPOSER_MIN_HEIGHT, Math.round(next))))
  }
  const endComposerDrag = (event: PointerEvent) => {
    if (composerDrag?.pointer_id === event.pointerId) composerDrag = null
  }

  return (
    <form
      class="min-w-0 bg-[var(--chat-black)] px-3 pb-[max(12px,var(--safe-bottom))] lg:px-5 lg:pb-[max(16px,var(--safe-bottom))]"
      onSubmit={(event) => event.preventDefault()}
    >
      <Show when={props.focused && store.notice()}>
        <p class="anim-reveal mx-auto mb-2 max-w-[900px] text-right text-xs text-[var(--warning)]">{store.notice()}</p>
      </Show>
      <ProviderReadiness pane={props.pane} />
      <ComposerCommandStatus pane={props.pane} />
      {/* Desktop prompt-box parity (state.zig paletteComposerStyle): panel-
          muted 1px border at rest, 1.5px accent border while focused — the
          extra 0.5px focus weight comes from a ring shadow so the border
          swap never shifts layout. @container lets the toolbar shrink the
          model label in a split column instead of wrapping a second row and
          making side-by-side composers different heights. */}
      <div class="@container relative mx-auto w-full max-w-[900px] rounded-[14px] border border-[var(--panel-muted)] bg-[var(--panel)] px-4 pt-3 pb-3 transition-colors focus-within:border-[var(--accent)] focus-within:shadow-[0_0_0_0.5px_var(--accent)]">
        <ComposerSuggest pane={props.pane} draft={suggestDraft()} caret={caret()} composing={composing()} controls={setSuggestions} accept={replacement => {
          if (!field) return
          field.value = replacement.draft
          field.setSelectionRange(replacement.caret, replacement.caret)
          setBlank(field.value.trim().length === 0)
          persistDraft(); updateSuggestions()
        }} />
        <Show when={attachments().length > 0}>
          <div class="mb-2 flex gap-2 overflow-x-auto pb-1">
            <For each={attachments()}>
              {(attachment) => (
                <div class="group relative h-20 w-24 shrink-0 overflow-hidden rounded-[8px] border border-[var(--border-muted)] bg-[var(--panel-alt)]">
                  <img
                    src={chatImageUrl(attachment) ?? ''}
                    alt={attachmentLabel(attachment)}
                    class="h-full w-full object-cover"
                  />
                  <button
                    type="button"
                    class="absolute right-1 top-1 grid h-6 w-6 place-items-center rounded-full bg-black/75 text-white hover:bg-black"
                    onClick={() => store.removeAttachment(composer_pane, attachment)}
                    aria-label={`Remove ${attachmentLabel(attachment)}`}
                    title="Remove attachment"
                  >
                    <Icon name="close" class="h-3.5 w-3.5" />
                  </button>
                  <div class="absolute inset-x-0 bottom-0 truncate bg-black/70 px-1.5 py-1 text-[10px] text-white">
                    {attachmentLabel(attachment)}
                  </div>
                </div>
              )}
            </For>
          </div>
        </Show>
        {/* Touch-only grip: long prompts are unreadable in the two-line mobile
            box, so the user can drag the composer taller (up to ~60% of the
            visible viewport, which already excludes the on-screen keyboard).
            Double-tap restores the compact height. */}
        <div
          class="-mt-2 mb-1 flex h-5 cursor-ns-resize touch-none items-center justify-center lg:hidden"
          role="separator"
          aria-orientation="horizontal"
          aria-label="Drag to resize the prompt box"
          onPointerDown={startComposerDrag}
          onPointerMove={moveComposerDrag}
          onPointerUp={endComposerDrag}
          onPointerCancel={endComposerDrag}
          onDblClick={() => setComposerHeight(null)}
        >
          <span class="h-1 w-10 rounded-full bg-[var(--border-muted)]" />
        </div>
        <textarea
          ref={(node) => {
            field = node
            if (node) node.value = store.draftFor(composer_pane)
          }}
          style={composerHeight() != null ? { height: `${Math.min(composerHeight()!, composerMaxHeight())}px` } : undefined}
          class="min-h-[52px] w-full resize-none lg:resize-y bg-transparent text-[16px] leading-[21px] outline-none placeholder:text-[var(--text-subtle)] lg:min-h-[88px] lg:text-[18px] lg:leading-[22px]"
          placeholder="Ask anything…"
          enterkeyhint="enter"
          aria-label="Message"
          aria-autocomplete="list"
          aria-controls={suggestions()?.listId}
          aria-expanded={suggestions()?.expanded() ?? false}
          aria-activedescendant={suggestions()?.activeId()}
          onInput={(event) => { setBlank(event.currentTarget.value.trim().length === 0); updateSuggestions() }}
          onClick={updateSuggestions}
          onSelect={updateSuggestions}
          onCompositionStart={() => setComposing(true)}
          onCompositionEnd={() => { setComposing(false); updateSuggestions() }}
          onBlur={() => { persistDraft(); suggestions()?.close() }}
          onKeyDown={onKeyDown}
          onPaste={(event) => {
            const files = clipboardImageFiles(event.clipboardData)
            if (files.length === 0) return
            // Image clipboard content is an attachment, matching the picker;
            // suppress the browser's fallback filename/text insertion.
            event.preventDefault()
            if (uploading() || store.sending()) return
            void store.attachFiles(composer_pane, files)
          }}
          onFocus={() => store.focusPane(props.pane)}
        />
        <div class="mt-1 flex min-w-0 flex-wrap items-center gap-1.5 lg:h-8 lg:flex-nowrap">
          <input
            ref={(node) => { filePicker = node }}
            type="file"
            class="hidden"
            accept="image/png,image/jpeg,image/webp,image/gif,image/bmp"
            multiple
            onChange={(event) => {
              const files = Array.from(event.currentTarget.files ?? [])
              event.currentTarget.value = ''
              void store.attachFiles(composer_pane, files)
            }}
          />
          <button
            type="button"
            class="grid h-8 w-8 shrink-0 place-items-center rounded-full text-[var(--text-muted)] hover:bg-[var(--panel-alt)] hover:text-[var(--text)] disabled:opacity-35"
            disabled={uploading() || store.sending()}
            onClick={() => filePicker?.click()}
            aria-label="Attach image"
            title="Attach image (PNG, JPEG, WebP, GIF, or BMP; up to 10 MB)"
          >
            <Show
              when={!uploading()}
              fallback={<span class="cmd-dot-pulse h-2.5 w-2.5 rounded-full bg-[var(--accent)]" />}
            >
              <Icon name="paperclip" class="h-[18px] w-[18px]" />
            </Show>
          </button>
          {/* Compact composers let controls wrap as direct toolbar children;
              keeping them inside a shrinking row made the permission chip
              overlap the send target on narrow phones. */}
          <div class="contents lg:flex lg:min-w-0 lg:flex-1 lg:items-center lg:gap-1.5">
            <ComposerPickers pane={props.pane} />
          </div>
          <div class="min-w-0 flex-1 lg:hidden" />
          <Show when={running()}>
            <button type="button" class="composer-stop grid h-8 w-8 shrink-0 place-items-center rounded-full bg-[var(--warning)]" onClick={() => void store.stopTurn(props.pane)} aria-label="Stop" title="Stop this turn"><span class="h-[9px] w-[9px] rounded-[2px] bg-[rgba(13,18,19,0.9)]" /></button>
          </Show>
            <button
              type="button"
              class="composer-send grid h-8 w-8 shrink-0 place-items-center rounded-full bg-[var(--accent)] text-[#06210f] disabled:opacity-35"
              disabled={
                store.sending() ||
                uploading() ||
                (blank() && attachments().length === 0)
              }
              onClick={submitDraft}
              aria-label={sendLabel()}
              title={sendLabel()}
            >
              <svg class="h-4 w-4" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 6l-6 7h4v5h4v-5h4z" fill="currentColor" />
              </svg>
            </button>
          <Show when={running()}><span class="composer-send-label">{sendLabel()}</span></Show>
        </div>
        <Show when={running() && !store.pendingFollowup(props.pane)}><p class="composer-detail composer-followup-hint">{store.pendingFollowupHint(props.pane)}</p></Show>
      </div>
    </form>
  )
}

/// Composer model + reasoning pickers: desktop-parity dropdowns over the
/// static provider tables in lib/models.ts. Selecting persists onto the
/// daemon thread and applies from the next turn.
const PROVIDER_OPTIONS = [
  { value: 'codex', label: 'Codex' },
  { value: 'claude', label: 'Claude' },
  { value: 'cursor', label: 'Cursor' },
  { value: 'opencode', label: 'OpenCode' },
  { value: 'pi', label: 'Pi' },
  { value: 'fx', label: 'FX' },
  { value: 'grok', label: 'Grok' },
  { value: 'muse', label: 'Muse' },
] as const

type PickerProvider = typeof PROVIDER_OPTIONS[number]['value'] | 'favorites'

interface PanePickerSnapshot {
  provider: string
  model: string | null
  effort: string | null
  variant: string | null
  fast: boolean
  access: string
}

function panePickerSnapshot(pane: LivePane): PanePickerSnapshot {
  return {
    provider: pane.provider ?? 'codex',
    model: pane.model ?? null,
    effort: pane.reasoning_effort ?? null,
    variant: pane.reasoning_variant ?? null,
    fast: pane.fast_mode === true,
    access: pane.access_mode ?? 'full_access',
  }
}

function pickerSnapshotsEqual(a: PanePickerSnapshot, b: PanePickerSnapshot): boolean {
  return a.provider === b.provider
    && a.model === b.model
    && a.effort === b.effort
    && a.variant === b.variant
    && a.fast === b.fast
    && a.access === b.access
}

function FavoriteStar(props: { active: boolean }) {
  return (
    <svg class="h-4 w-4 shrink-0" viewBox="0 0 24 24" aria-hidden="true">
      <path
        d="M12 3.7l2.55 5.17 5.7.83-4.13 4.02.98 5.68L12 16.72 6.9 19.4l.98-5.68L3.75 9.7l5.7-.83z"
        fill={props.active ? 'currentColor' : 'none'}
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linejoin="round"
      />
    </svg>
  )
}

function ComposerPickers(props: { pane: LivePane }) {
  let modelTrigger: HTMLButtonElement | undefined
  const [open, setOpen] = createSignal<'model' | 'effort' | 'variant' | 'fast' | 'access' | null>(null)
  const [selectedProvider, setSelectedProvider] = createSignal(props.pane.provider ?? 'codex')
  const [selectedModel, setSelectedModel] = createSignal<string | null>(props.pane.model ?? null)
  const [selectedEffort, setSelectedEffort] = createSignal<string | null>(props.pane.reasoning_effort ?? null)
  const [selectedVariant, setSelectedVariant] = createSignal<string | null>(props.pane.reasoning_variant ?? null)
  const [selectedFast, setSelectedFast] = createSignal(props.pane.fast_mode === true)
  const [selectedAccess, setSelectedAccess] = createSignal(props.pane.access_mode ?? 'full_access')
  const [pickerProvider, setPickerProvider] = createSignal<PickerProvider>(selectedProvider() as PickerProvider)
  const [modelMenuStyle, setModelMenuStyle] = createSignal('left:12px;bottom:64px;width:calc(100vw - 24px);max-height:55vh')
  // Picker feedback is local and synchronous. Only copy pane → local when the
  // projection itself changed, so a stale snapshot cannot rewind a click.
  let appliedPane = panePickerSnapshot(props.pane)
  createEffect(() => {
    const next = panePickerSnapshot(props.pane)
    if (pickerSnapshotsEqual(appliedPane, next)) return
    appliedPane = next
    setSelectedProvider(next.provider)
    setSelectedModel(next.model)
    setSelectedEffort(next.effort)
    setSelectedVariant(next.variant)
    setSelectedFast(next.fast)
    setSelectedAccess(next.access)
  })
  // Daemon catalog (provider.models.list) when the provider is reachable,
  // otherwise the static desktop-parity tables.
  createEffect(() => store.ensureProviderModels(selectedProvider()))
  createEffect(() => {
    const provider = pickerProvider()
    if (provider !== 'favorites') store.ensureProviderModels(provider)
  })
  const modelsFor = (provider: string | null | undefined) =>
    store.providerModels(provider) ?? modelOptionsFor(provider)
  const models = () => modelsFor(selectedProvider())
  const efforts = () => effortOptionsIn(models(), selectedModel())
  const variants = () => variantOptionsIn(models(), selectedModel())
  const selectedModelOption = () => models().find((option) => option.value === selectedModel()) ?? models()[0]
  const showsFast = () => modelSupportsFast(selectedProvider(), selectedModelOption())
  // Match desktop: only a fresh, never-sent thread may switch providers.
  const allowsProviderChoice = () =>
    store.messagesFor(props.pane).length === 0 &&
    !props.pane.provider_thread_id &&
    !store.paneWorking(props.pane)
  // <For> keys rows by identity. Projection polls replace props.pane, which
  // re-runs this; fresh row objects would recreate every button mid-click
  // (mousedown and mouseup on different nodes → no click). Reuse rows.
  type PickerRow = { provider: string; option: ModelOption }
  let pickerRowCache = new Map<string, PickerRow>()
  const stableRow = (next: Map<string, PickerRow>, provider: string, option: ModelOption): PickerRow => {
    const key = `${provider}\u0000${option.value}`
    const prev = pickerRowCache.get(key)
    const row =
      prev && prev.option.label === option.label && prev.option.description === option.description
        ? prev
        : { provider, option }
    next.set(key, row)
    return row
  }
  const pickerRows = createMemo((): PickerRow[] => {
    const provider = allowsProviderChoice() ? pickerProvider() : selectedProvider()
    const next = new Map<string, PickerRow>()
    const rows =
      provider !== 'favorites'
        ? modelsFor(provider).map((option) => stableRow(next, provider, option))
        : store.favoriteModels().map((favorite) =>
            stableRow(
              next,
              favorite.provider,
              modelsFor(favorite.provider).find((option) => option.value === favorite.model) ?? {
                value: favorite.model,
                label: shortModel(favorite.model),
              },
            ),
          )
    pickerRowCache = next
    return rows
  })
  const pickerHeading = () => {
    const provider = allowsProviderChoice() ? pickerProvider() : selectedProvider()
    if (provider === 'favorites') return 'Favorites'
    return PROVIDER_OPTIONS.find((option) => option.value === provider)?.label ?? provider
  }
  const currentModelLabel = () => {
    const match = models().find((option) => option.value === selectedModel())
    return match?.label ?? models()[0]?.label ?? shortModel(selectedModel())
  }
  // The trigger can sit anywhere in a wrapped composer toolbar. Measure it
  // instead of assuming a left edge, then clamp the fixed popover inside the
  // viewport so split panes and phone widths cannot push it off-screen.
  const placeModelMenu = () => {
    const rect = modelTrigger?.getBoundingClientRect()
    if (!rect) return
    const margin = 12
    const gap = 6
    const viewport_width = window.innerWidth
    const viewport_height = window.innerHeight
    const width = Math.min(400, Math.max(0, viewport_width - margin * 2))
    const left = Math.min(
      Math.max(margin, rect.left),
      Math.max(margin, viewport_width - width - margin),
    )
    const max_height = Math.max(160, Math.min(viewport_height * 0.55, rect.top - margin - gap))
    const bottom = Math.max(margin, viewport_height - rect.top + gap)
    setModelMenuStyle(
      `left:${left}px;bottom:${bottom}px;width:${width}px;max-height:${max_height}px`,
    )
  }
  const repositionModelMenu = () => {
    if (open() === 'model') placeModelMenu()
  }
  window.addEventListener('resize', repositionModelMenu)
  window.addEventListener('scroll', repositionModelMenu, true)
  window.visualViewport?.addEventListener('resize', repositionModelMenu)
  onCleanup(() => {
    window.removeEventListener('resize', repositionModelMenu)
    window.removeEventListener('scroll', repositionModelMenu, true)
    window.visualViewport?.removeEventListener('resize', repositionModelMenu)
  })
  createEffect(() => {
    if (open() !== 'model') return
    requestAnimationFrame(placeModelMenu)
  })
  const toggleModelPicker = () => {
    if (open() === 'model') {
      setOpen(null)
      return
    }
    setPickerProvider(selectedProvider() as PickerProvider)
    setOpen('model')
    queueMicrotask(placeModelMenu)
  }
  createEffect(() => {
    onCleanup(registerChatCommandPickers(props.pane, (command) => {
      if (command === 'model') {
        setPickerProvider(selectedProvider() as PickerProvider)
        setOpen('model')
        queueMicrotask(placeModelMenu)
      } else {
        setOpen(efforts().length > 0 ? 'effort' : variants().length > 0 ? 'variant' : showsFast() ? 'fast' : 'access')
      }
    }))
  })
  const pickModel = (provider: string, value: string) => {
    setOpen(null)
    const provider_changed = provider !== selectedProvider()
    if (!provider_changed && value === selectedModel()) return
    // A model switch can invalidate the stored effort/variant (e.g. Claude →
    // Haiku), so re-clamp both against the new model, like the desktop.
    const next = modelsFor(provider).find((option) => option.value === value)
    const effort_still_valid = !provider_changed && (next?.efforts ?? []).some(
      (option) => option.value === selectedEffort(),
    )
    const variant_still_valid =
      !provider_changed &&
      (!selectedVariant() || (next?.variants ?? []).includes(selectedVariant()!))
    const fast_still_valid = modelSupportsFast(provider, next)
    setSelectedProvider(provider)
    setSelectedModel(value)
    if (!effort_still_valid) setSelectedEffort(null)
    if (!variant_still_valid) setSelectedVariant(null)
    if (!fast_still_valid) setSelectedFast(false)
    void store.updateThreadSettings(props.pane, {
      ...(provider_changed ? { provider } : {}),
      model_ref: value,
      ...(effort_still_valid ? {} : { reasoning_effort: null }),
      ...(variant_still_valid ? {} : { reasoning_variant: null }),
      ...(fast_still_valid ? {} : { fast_mode: 'off' }),
    })
  }
  const pickEffort = (value: string | null) => {
    setOpen(null)
    if (value === selectedEffort()) return
    setSelectedEffort(value)
    void store.updateThreadSettings(props.pane, { reasoning_effort: value })
  }
  const pickVariant = (value: string | null) => {
    setOpen(null)
    if (value === selectedVariant()) return
    setSelectedVariant(value)
    void store.updateThreadSettings(props.pane, { reasoning_variant: value })
  }
  const pickFast = (value: 'off' | 'on') => {
    setOpen(null)
    if ((selectedFast() ? 'on' : 'off') === value) return
    setSelectedFast(value === 'on')
    void store.updateThreadSettings(props.pane, { fast_mode: value })
  }
  const pickAccess = (value: 'supervised' | 'full_access') => {
    setOpen(null)
    if (selectedAccess() === value) return
    setSelectedAccess(value)
    void store.updateThreadSettings(props.pane, { access_mode: value })
  }
  const menuClass =
    'anim-menu absolute bottom-full left-0 z-30 mb-1.5 max-h-[50vh] min-w-[12rem] overflow-y-auto rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] py-1 shadow-lg'
  const rowClass = (selected: boolean) =>
    `block w-full px-3 py-1.5 text-left text-[13px] ${
      selected ? 'text-[var(--accent)]' : 'text-[var(--text-muted)] hover:text-[var(--text)]'
    }`
  return (
    <>
      <Show when={open()}>
        <button
          type="button"
          class="fixed inset-0 z-20 cursor-default"
          aria-label="Close menu"
          onClick={() => setOpen(null)}
        />
      </Show>
      <div class="relative min-w-0 shrink">
        <button
          ref={(node) => { modelTrigger = node }}
          type="button"
          class="flex max-w-full items-center gap-1.5 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]"
          disabled={models().length === 0}
          onClick={toggleModelPicker}
          aria-label="Choose provider and model"
        >
          <ProviderGlyph provider={selectedProvider()} class="h-4 w-4 shrink-0 object-contain" />
          <span class="min-w-0 max-w-[5rem] truncate @[28rem]:max-w-[9rem]">{currentModelLabel()}</span>
          <Show when={models().length > 0}>
            <span aria-hidden="true" class="text-[10px]">▾</span>
          </Show>
        </button>
        <Show when={open() === 'model'}>
          <div
            class="anim-menu fixed z-30 flex min-w-0 overflow-hidden rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] shadow-lg max-[479px]:flex-col"
            style={modelMenuStyle()}
            role="menu"
          >
            <Show when={allowsProviderChoice()}>
              <div class="w-[9rem] shrink-0 overflow-y-auto border-r border-[var(--border-muted)] p-1 max-[479px]:flex max-[479px]:w-full max-[479px]:overflow-x-auto max-[479px]:overflow-y-hidden max-[479px]:border-b max-[479px]:border-r-0">
                <button
                  type="button"
                  class={`flex w-full items-center gap-2 rounded-[6px] px-2.5 py-2 text-left text-[13px] max-[479px]:w-auto max-[479px]:shrink-0 ${
                    pickerProvider() === 'favorites'
                      ? 'bg-[var(--accent-row)] text-[var(--text)]'
                      : 'text-[var(--text-muted)] hover:bg-[var(--accent-hover)]'
                  }`}
                  onClick={() => setPickerProvider('favorites')}
                  aria-label="Show favorite models"
                >
                  <FavoriteStar active />
                  <span>Favorites</span>
                </button>
                <For each={PROVIDER_OPTIONS}>
                  {(provider) => (
                    <button
                      type="button"
                      class={`flex w-full items-center gap-2 rounded-[6px] px-2.5 py-2 text-left text-[13px] max-[479px]:w-auto max-[479px]:shrink-0 ${
                        pickerProvider() === provider.value
                          ? 'bg-[var(--accent-row)] text-[var(--text)]'
                          : 'text-[var(--text-muted)] hover:bg-[var(--accent-hover)]'
                      }`}
                      onClick={() => setPickerProvider(provider.value)}
                    >
                      <ProviderGlyph provider={provider.value} class="h-4 w-4 object-contain" />
                      <span>{provider.label}</span>
                    </button>
                  )}
                </For>
              </div>
            </Show>
            <div class="min-h-0 min-w-0 flex-1 overflow-y-auto py-1">
              <div class="px-3 py-1.5 text-[10px] font-bold uppercase tracking-wide text-[var(--text-subtle)]">
                {pickerHeading()}
              </div>
              <For
                each={pickerRows()}
                fallback={
                  <p class="px-3 py-4 text-xs text-[var(--text-subtle)]">
                    {pickerProvider() === 'favorites' ? 'Star a model to keep it here.' : 'No models available.'}
                  </p>
                }
              >
                {(row) => {
                  const selected = () =>
                    row.provider === selectedProvider() && row.option.value === selectedModel()
                  const favorite = () => store.isFavoriteModel(row.provider, row.option.value)
                  return (
                    <div
                      class={`group flex min-w-0 items-center ${
                        selected() ? 'text-[var(--accent)]' : 'text-[var(--text-muted)]'
                      }`}
                    >
                      <button
                        type="button"
                        class="min-w-0 flex-1 px-3 py-2 text-left text-[13px] hover:text-[var(--text)]"
                        onClick={() => pickModel(row.provider, row.option.value)}
                      >
                        <span class="block truncate">{row.option.label}</span>
                        <Show when={row.option.description}>
                          <span class="mt-0.5 block text-[11px] leading-snug text-[var(--text-subtle)]">
                            {row.option.description}
                          </span>
                        </Show>
                        <Show when={pickerProvider() === 'favorites'}>
                          <span class="mt-0.5 block text-[10px] uppercase tracking-wide text-[var(--text-subtle)]">
                            {PROVIDER_OPTIONS.find((provider) => provider.value === row.provider)?.label ?? row.provider}
                          </span>
                        </Show>
                      </button>
                      <button
                        type="button"
                        class={`mr-1 grid h-8 w-8 shrink-0 place-items-center rounded-[6px] hover:bg-[var(--accent-hover)] hover:text-[var(--text)] ${
                          favorite() ? 'text-[var(--accent)]' : 'text-[var(--text-subtle)]'
                        }`}
                        onClick={() => store.toggleFavoriteModel(row.provider, row.option.value)}
                        aria-label={`${favorite() ? 'Remove' : 'Add'} ${row.option.label} ${favorite() ? 'from' : 'to'} favorites`}
                        title={favorite() ? 'Remove from favorites' : 'Add to favorites'}
                      >
                        <FavoriteStar active={favorite()} />
                      </button>
                    </div>
                  )
                }}
              </For>
            </div>
          </div>
        </Show>
      </div>
      <Show when={efforts().length > 0}>
        <div class="relative shrink-0">
          <button
            type="button"
            class="flex items-center gap-1 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]"
            onClick={() => setOpen(open() === 'effort' ? null : 'effort')}
            aria-label="Choose reasoning effort"
          >
            {effortLabel(selectedEffort())}
            <span aria-hidden="true" class="text-[10px]">▾</span>
          </button>
          <Show when={open() === 'effort'}>
            <div class={menuClass} role="menu">
              <For each={efforts()}>
                {(option) => (
                  <button
                    type="button"
                    class={rowClass(option.value === selectedEffort())}
                    onClick={() => pickEffort(option.value)}
                  >
                    {option.label}
                  </button>
                )}
              </For>
            </div>
          </Show>
        </div>
      </Show>
      <Show when={variants().length > 0}>
        <div class="relative shrink-0">
          <button
            type="button"
            class="flex items-center gap-1 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] capitalize text-[var(--text-muted)]"
            onClick={() => setOpen(open() === 'variant' ? null : 'variant')}
            aria-label="Choose reasoning variant"
          >
            {selectedVariant() ?? 'Default'}
            <span aria-hidden="true" class="text-[10px]">▾</span>
          </button>
          <Show when={open() === 'variant'}>
            <div class={menuClass} role="menu">
              <button type="button" class={rowClass(!selectedVariant())} onClick={() => pickVariant(null)}>
                Default
              </button>
              <For each={variants()}>
                {(variant) => (
                  <button
                    type="button"
                    class={`${rowClass(variant === selectedVariant())} capitalize`}
                    onClick={() => pickVariant(variant)}
                  >
                    {variant}
                  </button>
                )}
              </For>
            </div>
          </Show>
        </div>
      </Show>
      <Show when={showsFast()}>
        <div class="relative shrink-0">
          <button
            type="button"
            class="flex items-center gap-1 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]"
            onClick={() => setOpen(open() === 'fast' ? null : 'fast')}
            aria-label="Choose service speed"
          >
            <span class="max-w-[5.5rem] truncate @[28rem]:max-w-none">
              {selectedFast() ? 'Fast' : 'Default speed'}
            </span>
            <span aria-hidden="true" class="text-[10px]">▾</span>
          </button>
          <Show when={open() === 'fast'}>
            <div class={menuClass} role="menu">
              <button type="button" class={rowClass(!selectedFast())} onClick={() => pickFast('off')}>
                Default
              </button>
              <button type="button" class={rowClass(selectedFast())} onClick={() => pickFast('on')}>
                Fast
              </button>
            </div>
          </Show>
        </div>
      </Show>
      {/* The speed picker already reads "Fast" when fast mode is on; this
          static pill only appears when the picker is hidden (model without a
          fast tier but a persisted fast_mode flag), so composers never carry
          a duplicate pill that wraps the row and unevens pane heights. */}
      <Show when={!showsFast() && selectedFast()}>
        <span class="shrink-0 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]">Fast</span>
      </Show>
      <div class="relative shrink-0">
        <button
          type="button"
          class="flex max-w-full items-center gap-1 rounded-full bg-[var(--panel-alt)] px-2.5 py-1 text-[12px] text-[var(--text-muted)]"
          onClick={() => setOpen(open() === 'access' ? null : 'access')}
          aria-label="Choose permissions"
        >
          <span class="max-w-[5.5rem] truncate @[28rem]:max-w-none">
            {selectedAccess() === 'full_access' ? 'Full access' : 'Supervised'}
          </span>
          <span aria-hidden="true" class="text-[10px]">▾</span>
        </button>
        <Show when={open() === 'access'}>
          <div class={menuClass} role="menu">
            <button
              type="button"
              class={rowClass(selectedAccess() === 'supervised')}
              onClick={() => pickAccess('supervised')}
            >
              Supervised
            </button>
            <button
              type="button"
              class={rowClass(selectedAccess() === 'full_access')}
              onClick={() => pickAccess('full_access')}
            >
              Full access
            </button>
          </div>
        </Show>
      </div>
    </>
  )
}

function shortModel(ref: string | null | undefined): string {
  if (!ref) return 'Model'
  const tail = ref.split('/').at(-1) ?? ref
  return tail.replace(/^gpt-/, 'GPT-').replace(/claude-/, 'Claude ')
}

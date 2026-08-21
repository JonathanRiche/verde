import { For, Show, createEffect, createMemo, createSignal, onCleanup } from 'solid-js'
import { marked } from 'marked'

import { decorateFileCitations } from '../lib/citations'
import { chatImageUrl } from '../lib/live'
import { store } from '../lib/store'
import { type Attachment, type LivePane, type Message } from '../lib/types'
import { effortLabel, effortOptionsIn, modelOptionsFor, modelSupportsFast, variantOptionsIn } from '../lib/models'
import { handleFileCitationClick } from './FileViewer'
import { Icon, ProviderGlyph, ZoomButton } from './Icons'

marked.setOptions({ gfm: true, breaks: true })

// Shared 1s ticker driving working timers and group elapsed labels.
const [nowMs, setNowMs] = createSignal(Date.now())
window.setInterval(() => setNowMs(Date.now()), 1000)

// Card expand/collapse survives row remounts (live overlay rows are rebuilt
// on every streamed event), mirroring the desktop's per-card state keys.
const cardExpanded = new Map<string, boolean>()

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
  const html = marked.parse(decorateFileCitations(body), { async: false }) as string
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

  // Workspace switches mount every open pane in the niri strip at once;
  // building all transcripts' DOM synchronously blocked the switch for
  // ~700ms. Paint the focused pane's transcript immediately and fill the
  // off-screen ones in during idle frames.
  const [revealed, setRevealed] = createSignal(focused())
  createEffect(() => {
    if (focused()) setRevealed(true)
  })
  if (!revealed()) {
    // WebKit (the embedded Verde browser) has no requestIdleCallback.
    const w = window as Window & {
      requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number
      cancelIdleCallback?: (id: number) => void
    }
    if (w.requestIdleCallback && w.cancelIdleCallback) {
      const idle_id = w.requestIdleCallback(() => setRevealed(true), { timeout: 2000 })
      onCleanup(() => w.cancelIdleCallback?.(idle_id))
    } else {
      const timer_id = window.setTimeout(() => setRevealed(true), 250)
      onCleanup(() => window.clearTimeout(timer_id))
    }
  }

  createEffect(() => {
    store.ensureTranscript(props.pane)
  })

  createEffect(() => {
    const row_count = messages().length
    const rendered = revealed()
    const node = scroller
    if (!node) return
    queueMicrotask(() => {
      const el = scroller
      if (!el || !pinToBottom) return
      if (initial_jump) {
        // Don't spend the one-shot jump while the transcript is still empty
        // or unrevealed — a PWA relaunch runs this effect before the rows
        // exist and used to leave the view stuck at the top of the thread.
        if (row_count === 0 || !rendered) return
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

  const onScroll = () => {
    const node = scroller
    if (!node) return
    pinToBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 96
  }

  // Desktop parity: consecutive command/tool rows collapse into one grouped
  // card with a summary header; a lone row renders as a single command card.
  //
  // Wrapper identity matters: <For> keys by reference, so a wrapper whose
  // underlying message refs are unchanged must be reused verbatim — otherwise
  // every streamed delta remounts (and re-markdown-parses) the whole
  // transcript, which livelocks large threads.
  type RenderItem = { kind: 'row'; message: Message } | { kind: 'group'; items: Message[] }
  const itemKey = (item: RenderItem) =>
    item.kind === 'row' ? `r:${item.message.message_id}` : `g:${item.items[0]?.message_id ?? ''}`
  const allItems = createMemo<RenderItem[]>((prev) => {
    const out: RenderItem[] = []
    let run: Message[] = []
    const flush = () => {
      if (run.length >= 2) out.push({ kind: 'group', items: run })
      else for (const message of run) out.push({ kind: 'row', message })
      run = []
    }
    for (const message of messages()) {
      if (isCommandCardRow(message)) {
        run.push(message)
        continue
      }
      flush()
      out.push({ kind: 'row', message })
    }
    flush()
    if (!prev?.length) return out
    const prevByKey = new Map<string, RenderItem>()
    for (const item of prev) prevByKey.set(itemKey(item), item)
    return out.map((item) => {
      const old = prevByKey.get(itemKey(item))
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
  const [rowLimit, setRowLimit] = createSignal(TRANSCRIPT_WINDOW_ROWS)
  const hiddenCount = createMemo(() => Math.max(0, allItems().length - rowLimit()))
  const items = createMemo(() => {
    const all = allItems()
    return hiddenCount() > 0 ? all.slice(all.length - rowLimit()) : all
  })
  const showEarlier = () => {
    // Keep the viewport anchored on the rows the user was reading while
    // older rows mount above them.
    const el = scroller
    const before = el ? el.scrollHeight - el.scrollTop : 0
    setRowLimit((limit) => limit + TRANSCRIPT_WINDOW_STEP)
    queueMicrotask(() => {
      if (el) el.scrollTop = el.scrollHeight - before
    })
  }

  // Turn acceptance time while streaming — drives live group elapsed labels.
  const workingSince = createMemo(
    () => messages().find((m) => m.message_id.endsWith('-stream'))?.created_at_ms ?? null,
  )

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
        <ZoomButton pane={props.pane} />
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
        onMouseDown={() => store.focusPane(props.pane)}
      >
        <div class="mx-auto flex w-full max-w-[900px] flex-col gap-3">
          <Show when={revealed()}>
          <Show when={hiddenCount() > 0}>
            <button
              type="button"
              class="mx-auto rounded-full bg-[var(--panel-alt)] px-3 py-1.5 text-[12px] text-[var(--text-muted)] hover:text-[var(--text)]"
              onClick={showEarlier}
            >
              Show {Math.min(hiddenCount(), TRANSCRIPT_WINDOW_STEP)} earlier…
            </button>
          </Show>
          <For each={items()}>
            {(item) =>
              item.kind === 'group'
                ? <ToolCallGroup items={item.items} workingSince={workingSince()} />
                : <TranscriptRow message={item.message} pane={props.pane} />}
          </For>
          <Show when={messages().length === 0}>
            <EmptyTranscript />
          </Show>
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
  if (message.tool_call_kind && message.tool_call_kind !== 'think') return true
  return (
    message.author === 'Ran command' ||
    message.author === 'Command failed' ||
    isShellLikeBody(message.body)
  )
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
function commandPreview(body: string): string {
  return body.replace(/[\s\r\n\t]+/g, ' ').trim()
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

function CopyPill(props: { payload: string }) {
  return (
    <button
      type="button"
      class="shrink-0 rounded-[5px] bg-[rgba(56,57,62,0.34)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] hover:bg-[rgba(72,73,79,0.82)] hover:text-white"
      onClick={(event) => {
        event.stopPropagation()
        void navigator.clipboard?.writeText(props.payload)
      }}
    >
      Copy
    </button>
  )
}

function CommandCard(props: { message: Message; child?: boolean }) {
  const failed = () => commandFailed(props.message)
  const running = () => commandRunning(props.message)
  const [expanded, toggleExpanded] = usePersistedFlag(
    () => `cmd:${props.message.message_id}`,
    failed,
  )
  const [showAll, toggleShowAll] = usePersistedFlag(
    () => `cmd-more:${props.message.message_id}`,
    () => false,
  )
  const label = () => props.message.author || 'Ran command'
  const preview = () => commandPreview(props.message.body)
  const bodyLines = () => props.message.body.trim().split('\n')
  const truncated = () => !showAll() && bodyLines().length > TOOL_OUTPUT_COLLAPSED_LINES
  const visibleBody = () =>
    (showAll() ? bodyLines() : bodyLines().slice(0, TOOL_OUTPUT_COLLAPSED_LINES)).join('\n')
  const textColor = () => (failed() ? 'text-[var(--danger)]' : 'text-[var(--text-muted)]')

  return (
    <div
      class={`min-w-0 border ${props.child ? 'rounded-[8px] bg-[#0b0f10] border-[rgba(60,71,76,0.73)]' : 'rounded-[10px] bg-[var(--panel-alt)] border-[var(--border-muted)]'} ${failed() ? '!border-[var(--danger)]' : ''}`}
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
              Show all {bodyLines().length} lines
            </button>
          </Show>
        </div>
      </Show>
    </div>
  )
}

// Grouped card: "N tool calls  ·  X completed  ·  Y failed  ·  Z running  ·  m:ss"
function ToolCallGroup(props: { items: Message[]; workingSince: number | null }) {
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
    () => `group:${props.items[0]?.message_id ?? ''}`,
    () => counts().failed > 0,
  )
  const summary = () => {
    const { count, failed, running, completed } = counts()
    const noun = count === 1 ? 'tool call' : 'tool calls'
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
          <For each={props.items}>{(message) => <CommandCard message={message} child />}</For>
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
    if (![path_len, additions, deletions, patch_len].every(Number.isFinite)) return null
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

function diffLineClass(line: string): string {
  if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('@@')) {
    return 'text-[var(--text-subtle)]'
  }
  if (line.startsWith('+')) return 'text-[#34e094]'
  if (line.startsWith('-')) return 'text-[var(--danger)]'
  return 'text-[var(--text-muted)]'
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
      <div class="flex h-11 min-w-0 items-center gap-2">
        <button
          type="button"
          class="flex h-full min-w-0 flex-1 items-center gap-2 text-left"
          onClick={toggleAnchored}
        >
          <Chevron open={expanded()} />
          <span class="mono min-w-0 flex-1 truncate text-[13px] text-[var(--text)]">{props.file.path}</span>
          <span class="mono shrink-0 text-[12px] text-[#34e094]">+{props.file.additions}</span>
          <span class="mono shrink-0 text-[12px] text-[var(--danger)]">-{props.file.deletions}</span>
        </button>
        <button
          type="button"
          class="shrink-0 rounded-[5px] bg-[rgba(56,57,62,0.34)] px-2.5 py-1 text-[11px] text-[var(--text-muted)] hover:bg-[rgba(72,73,79,0.82)] hover:text-white"
          onClick={(event) => {
            event.stopPropagation()
            store.beginDiffComment(props.pane, props.file)
          }}
        >
          Comment
        </button>
        <CopyPill payload={props.file.patch} />
      </div>
      <Show when={expanded()}>
        <pre class="mono mb-2 max-w-full overflow-x-auto text-[12.5px] leading-[1.45] whitespace-pre-wrap break-words">
          <For each={props.file.patch.split('\n')}>
            {(line) => <div class={diffLineClass(line)}>{line.length > 0 ? line : ' '}</div>}
          </For>
        </pre>
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

// ---- Rows ------------------------------------------------------------------

function TranscriptRow(props: { message: Message; pane: LivePane }) {
  if (props.message.message_id.endsWith('-stream')) {
    return <WorkingRow message={props.message} />
  }
  if (isDiffSummaryRow(props.message)) {
    return <DiffCard message={props.message} pane={props.pane} />
  }
  if (isCommandCardRow(props.message)) {
    return <CommandCard message={props.message} />
  }

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
      <div class="markdown" innerHTML={html()} onClick={handleFileCitationClick} />
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
/// "Working - m:ss" / "Thinking - m:ss" label; an empty stream shows the
/// waiting placeholder.
function WorkingRow(props: { message: Message }) {
  const label = () => {
    const started = props.message.created_at_ms
    const verb = props.message.author || 'Working'
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
    if (body.length <= STREAM_PARSE_MAX) return marked.parse(decorateFileCitations(body), { async: false }) as string
    const cut = body.indexOf('\n', body.length - STREAM_PARSE_MAX)
    const tail = cut >= 0 ? body.slice(cut + 1) : body.slice(body.length - STREAM_PARSE_MAX)
    return marked.parse(decorateFileCitations(tail), { async: false }) as string
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
        <div class="markdown" innerHTML={html()} onClick={handleFileCitationClick} />
      </Show>
    </article>
  )
}

function Composer(props: { pane: LivePane; focused: boolean }) {
  let field: HTMLTextAreaElement | undefined
  let filePicker: HTMLInputElement | undefined

  const attachments = () => store.attachmentsFor(props.pane)
  const uploading = () => store.uploadingAttachmentsFor(props.pane)

  createEffect(() => {
    if (props.focused && store.composerNonce() > 0) field?.focus()
  })

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      if (uploading()) return
      void store.sendDraft(props.pane)
    }
  }

  return (
    <form
      class="min-w-0 bg-[var(--chat-black)] px-3 pb-[max(12px,var(--safe-bottom))] lg:px-5 lg:pb-[max(16px,var(--safe-bottom))]"
      onSubmit={(event) => {
        event.preventDefault()
        if (uploading()) return
        void store.sendDraft(props.pane)
      }}
    >
      <Show when={props.focused && store.notice()}>
        <p class="mx-auto mb-2 max-w-[900px] text-right text-xs text-[var(--warning)]">{store.notice()}</p>
      </Show>
      {/* Desktop prompt-box parity (state.zig paletteComposerStyle): panel-
          muted 1px border at rest, 1.5px accent border while focused — the
          extra 0.5px focus weight comes from a ring shadow so the border
          swap never shifts layout. @container lets the toolbar shrink the
          model label in a split column instead of wrapping a second row and
          making side-by-side composers different heights. */}
      <div class="@container mx-auto w-full max-w-[900px] rounded-[14px] border border-[var(--panel-muted)] bg-[var(--panel)] px-4 pt-3 pb-3 transition-colors focus-within:border-[var(--accent)] focus-within:shadow-[0_0_0_0.5px_var(--accent)]">
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
                    onClick={() => store.removeAttachment(props.pane, attachment)}
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
        <textarea
          ref={(node) => { field = node }}
          class="min-h-[52px] w-full bg-transparent text-[16px] leading-[21px] outline-none placeholder:text-[var(--text-subtle)] lg:min-h-[88px] lg:text-[18px] lg:leading-[22px]"
          placeholder="Ask anything…"
          value={store.draftFor(props.pane)}
          onInput={(event) => store.setDraftFor(props.pane, event.currentTarget.value)}
          onKeyDown={onKeyDown}
          onFocus={() => store.focusPane(props.pane)}
        />
        <div class="mt-1 flex h-8 min-w-0 flex-nowrap items-center gap-1.5">
          <input
            ref={(node) => { filePicker = node }}
            type="file"
            class="hidden"
            accept="image/png,image/jpeg,image/webp,image/gif,image/bmp"
            multiple
            onChange={(event) => {
              const files = Array.from(event.currentTarget.files ?? [])
              event.currentTarget.value = ''
              void store.attachFiles(props.pane, files)
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
          <div class="flex min-w-0 flex-1 items-center gap-1.5">
            <ComposerPickers pane={props.pane} />
          </div>
          <Show
            when={!store.paneWorking(props.pane)}
            fallback={
              <button
                type="button"
                class="composer-stop grid h-8 w-8 shrink-0 place-items-center rounded-full bg-[var(--warning)]"
                onClick={() => void store.stopTurn(props.pane)}
                aria-label="Stop"
                title="Stop this turn"
              >
                <span class="h-[9px] w-[9px] rounded-[2px] bg-[rgba(13,18,19,0.9)]" />
              </button>
            }
          >
            <button
              type="submit"
              class="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-[var(--accent)] text-[#06210f] disabled:opacity-35"
              disabled={
                store.sending() ||
                uploading() ||
                (store.draftFor(props.pane).trim().length === 0 && attachments().length === 0)
              }
              aria-label="Send"
            >
              <svg class="h-4 w-4" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 6l-6 7h4v5h4v-5h4z" fill="currentColor" />
              </svg>
            </button>
          </Show>
        </div>
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
] as const

function ComposerPickers(props: { pane: LivePane }) {
  const [open, setOpen] = createSignal<'model' | 'effort' | 'variant' | 'fast' | 'access' | null>(null)
  const [selectedProvider, setSelectedProvider] = createSignal(props.pane.provider ?? 'codex')
  const [selectedModel, setSelectedModel] = createSignal<string | null>(props.pane.model ?? null)
  const [selectedEffort, setSelectedEffort] = createSignal<string | null>(props.pane.reasoning_effort ?? null)
  const [selectedVariant, setSelectedVariant] = createSignal<string | null>(props.pane.reasoning_variant ?? null)
  const [selectedFast, setSelectedFast] = createSignal(props.pane.fast_mode === true)
  const [selectedAccess, setSelectedAccess] = createSignal(props.pane.access_mode ?? 'supervised')
  const [pickerProvider, setPickerProvider] = createSignal(selectedProvider())
  // Picker feedback is local and synchronous; the pane projection catches up
  // after the durable daemon write. Reconcile external/desktop changes when a
  // fresh pane value arrives without making the click wait on that round trip.
  createEffect(() => setSelectedProvider(props.pane.provider ?? 'codex'))
  createEffect(() => setSelectedModel(props.pane.model ?? null))
  createEffect(() => setSelectedEffort(props.pane.reasoning_effort ?? null))
  createEffect(() => setSelectedVariant(props.pane.reasoning_variant ?? null))
  createEffect(() => setSelectedFast(props.pane.fast_mode === true))
  createEffect(() => setSelectedAccess(props.pane.access_mode ?? 'supervised'))
  // Daemon catalog (provider.models.list) when the provider is reachable,
  // otherwise the static desktop-parity tables.
  createEffect(() => store.ensureProviderModels(selectedProvider()))
  createEffect(() => store.ensureProviderModels(pickerProvider()))
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
  const currentModelLabel = () => {
    const match = models().find((option) => option.value === selectedModel())
    return match?.label ?? models()[0]?.label ?? shortModel(selectedModel())
  }
  const toggleModelPicker = () => {
    if (open() === 'model') {
      setOpen(null)
      return
    }
    setPickerProvider(selectedProvider())
    setOpen('model')
  }
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
    'absolute bottom-full left-0 z-30 mb-1.5 max-h-[50vh] min-w-[12rem] overflow-y-auto rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] py-1 shadow-lg'
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
            class="absolute bottom-full left-0 z-30 mb-1.5 flex max-h-[55vh] min-w-[25rem] overflow-hidden rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] shadow-lg max-sm:min-w-[calc(100vw-3rem)]"
            role="menu"
          >
            <Show when={allowsProviderChoice()}>
              <div class="w-[9rem] shrink-0 border-r border-[var(--border-muted)] p-1">
                <For each={PROVIDER_OPTIONS}>
                  {(provider) => (
                    <button
                      type="button"
                      class={`flex w-full items-center gap-2 rounded-[6px] px-2.5 py-2 text-left text-[13px] ${
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
            <div class="min-w-0 flex-1 overflow-y-auto py-1">
              <div class="px-3 py-1.5 text-[10px] font-bold uppercase tracking-wide text-[var(--text-subtle)]">
                {PROVIDER_OPTIONS.find((provider) => provider.value === pickerProvider())?.label ?? pickerProvider()}
              </div>
              <For
                each={modelsFor(allowsProviderChoice() ? pickerProvider() : selectedProvider())}
                fallback={<p class="px-3 py-4 text-xs text-[var(--text-subtle)]">No models available.</p>}
              >
                {(option) => {
                  const provider = () => allowsProviderChoice() ? pickerProvider() : selectedProvider()
                  return (
                    <button
                      type="button"
                      class={rowClass(provider() === selectedProvider() && option.value === selectedModel())}
                      onClick={() => pickModel(provider(), option.value)}
                    >
                      {option.label}
                    </button>
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

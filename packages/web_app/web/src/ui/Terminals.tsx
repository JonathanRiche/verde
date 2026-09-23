import { createEffect, createMemo, createSignal, For, onCleanup, onMount, Show } from 'solid-js'

import { alignPtyStream, resizeSession, tailSession, writePane } from '../lib/pty'
import { store } from '../lib/store'
import { orderRange, pasteBytes, selectionText, wordBounds } from '../lib/term_select'
import { engineFailureIsPermanent, TextScreen } from '../lib/text_screen'

import type { GhosttySnapshot, GhosttyTerminal } from '../lib/ghostty'
import type { CellPoint, CellRange } from '../lib/term_select'

/// Painted grid geometry; the selection overlay is laid out from this.
interface GridGeo {
  cw: number
  ch: number
  start: number
  cols: number
  rows: number
  ox: number
  oy: number
}

const LONG_PRESS_MS = 450
const HANDLE_REACH_PX = 32
const HANDLE_PX = 20
/// Engine crashes/transient load failures tolerated before text fallback.
const WASM_MAX_CRASHES = 6
let fallback_warned = false

const KEY_NAMES: Record<string, string> = {
  Enter: 'enter',
  Backspace: 'backspace',
  Tab: 'tab',
  Escape: 'escape',
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Home: 'home',
  End: 'end',
  PageUp: 'pageup',
  PageDown: 'pagedown',
  Delete: 'delete',
}

export function TerminalView(props: { workspaceId: string; paneId: number; sessionId?: string }) {
  let canvas: HTMLCanvasElement | undefined
  let host: HTMLDivElement | undefined
  let key_input: HTMLTextAreaElement | undefined
  let frame: HTMLElement | undefined

  const [sel, setSel] = createSignal<CellRange | null>(null)
  const [geo, setGeo] = createSignal<GridGeo | null>(null)
  // Touch selections get drag handles; mouse selections do not.
  const [handles, setHandles] = createSignal(false)
  const [bar, setBar] = createSignal<{ x: number; y: number } | null>(null)
  const [paste_box, setPasteBox] = createSignal(false)
  const [copied, setCopied] = createSignal(false)
  // libghostty-vt is unavailable; the pane paints a plain-text grid instead.
  const [text_mode, setTextMode] = createSignal(false)
  let actions: { copy(): void; paste(): void; selectAll(): void; sendPaste(text: string): void } | null = null

  const closeBar = () => {
    // The paste box owned focus; hand it back so keys (and the soft keyboard)
    // keep working.
    if (paste_box()) key_input?.focus({ preventScroll: true })
    setBar(null)
    setPasteBox(false)
    setCopied(false)
  }

  const highlight = createMemo(() => {
    const range = sel()
    const grid = geo()
    if (!range || !grid) return []
    const rects: { left: number; top: number; width: number }[] = []
    const first = Math.max(range.start.row, grid.start)
    const last = Math.min(range.end.row, grid.start + grid.rows - 1)
    for (let row = first; row <= last; row += 1) {
      const from = row === range.start.row ? range.start.x : 0
      const to = row === range.end.row ? range.end.x : grid.cols - 1
      rects.push({ left: from * grid.cw, top: (row - grid.start) * grid.ch, width: (to - from + 1) * grid.cw })
    }
    return rects
  })

  /// Handle centers in canvas CSS pixels, or null when scrolled out of view.
  const handlePoint = (which: 'start' | 'end') => {
    const range = sel()
    const grid = geo()
    if (!range || !grid) return null
    const point = range[which]
    const y = point.row - grid.start
    if (y < 0 || y >= grid.rows) return null
    // Kept inside the canvas: an overhanging handle would add scroll overflow
    // to the host and turn history pans into DOM nudges.
    const x = (which === 'start' ? point.x : point.x + 1) * grid.cw
    return {
      x: Math.max(HANDLE_PX / 2, Math.min(grid.cols * grid.cw - HANDLE_PX / 2, x)),
      y: Math.min(grid.rows * grid.ch - HANDLE_PX / 2, (y + 1) * grid.ch + 7),
    }
  }

  onMount(() => {
    const surface = canvas
    const scroller = host
    const input = key_input
    if (!surface || !scroller || !input) return

    let disposed = false
    let term: GhosttyTerminal | null = null
    let tail_offset: number | null = null
    let cols = 80
    let rows = 24
    let zoom = 1
    let pinned_bottom = true
    // Native Ghostty viewport is at the live tail (vs scrolled into history).
    let viewport_bottom = true
    // TUIs own scrolling themselves, so wheel/drag become arrow keys there.
    let alt_screen = false
    // DEC 2004, tracked from the raw stream like alt_screen.
    let bracketed_paste = false
    let cell_h_px = 20
    let scroll_rows_carry = 0
    let composing = false
    let wasm_ok = true
    let wasm_crashes = 0
    let load: typeof import('../lib/ghostty') | null = null
    // Monochrome VT grid fed by the same session.tail stream once wasm is off.
    let text_screen: TextScreen | null = null
    let resize_sent = ''

    const engine = async () => {
      load ??= await import('../lib/ghostty')
      return load
    }

    const sessionId = () => {
      const resolved =
        props.sessionId ||
        store.openPanes().find((item) => item.pane_id === props.paneId && item.workspace_id === props.workspaceId)
          ?.session_id
      // Surface routing state for debugging: which session this pane writes to.
      input.dataset.session = resolved ?? ''
      input.dataset.pane = String(props.paneId)
      return resolved
    }

    const measure = () => {
      const width = Math.max(1, scroller.clientWidth)
      const height = Math.max(1, scroller.clientHeight)
      const font = 14 * zoom
      const cell_w = Math.max(7, font * 0.6)
      const cell_h = Math.max(12, font * 1.28)
      return {
        cols: Math.max(40, Math.min(200, Math.floor(width / cell_w) || 80)),
        rows: Math.max(10, Math.min(80, Math.floor(height / cell_h) || 24)),
      }
    }

    const ensure = async () => {
      const ghostty = await engine()
      const grid = measure()
      const changed = grid.cols !== cols || grid.rows !== rows
      cols = grid.cols
      rows = grid.rows
      if (term) {
        // Resize only on real change: it bumps outputRevision and can move a
        // history-scrolled viewport.
        if (changed) term.resize(cols, rows)
        return term
      }
      term = await ghostty.openGhostty(cols, rows)
      return term
    }

    const killWasm = () => {
      wasm_crashes += 1
      try {
        term?.dispose()
      } catch {
        // A trapped instance may not dispose cleanly; it is dropped either way.
      }
      term = null
      tail_offset = null
      viewport_bottom = true
      if (wasm_crashes >= WASM_MAX_CRASHES) disableWasm()
    }

    /// Switch this pane to the text fallback for its lifetime. tail_offset is
    /// already null, so the next pump replays the ring into the text grid.
    const disableWasm = (error?: unknown) => {
      if (!wasm_ok) return
      wasm_ok = false
      term = null
      tail_offset = null
      viewport_bottom = true
      setTextMode(true)
      if (!fallback_warned) {
        fallback_warned = true
        console.warn('Verde terminal: libghostty-vt unavailable; using plain-text fallback.', error ?? '')
      }
    }

    // A failed engine load counts as a crash; deterministic failures (CSP,
    // no SIMD128, invalid module) switch to the text fallback at once.
    const engineLoadFailed = (error: unknown) => {
      if (engineFailureIsPermanent(error)) {
        wasm_crashes += 1
        disableWasm(error)
      } else {
        killWasm()
      }
    }

    const textScreen = () => {
      text_screen ??= new TextScreen(cols, rows)
      text_screen.resize(cols, rows)
      return text_screen
    }

    // DEC 1049/1047 track alternate-screen apps in the raw stream; the WASM
    // snapshot does not expose terminal modes.
    const trackAltScreen = (bytes: string) => {
      const on = Math.max(bytes.lastIndexOf('\x1b[?1049h'), bytes.lastIndexOf('\x1b[?1047h'))
      const off = Math.max(bytes.lastIndexOf('\x1b[?1049l'), bytes.lastIndexOf('\x1b[?1047l'))
      if (on >= 0 || off >= 0) {
        const next = on > off
        // Row numbers mean nothing across a screen switch.
        if (next !== alt_screen && sel()) clearSelection()
        alt_screen = next
      }
      const paste_on = bytes.lastIndexOf('\x1b[?2004h')
      const paste_off = bytes.lastIndexOf('\x1b[?2004l')
      if (paste_on >= 0 || paste_off >= 0) bracketed_paste = paste_on > paste_off
    }

    // Glyphs of selected rows, kept as they scroll by so a selection that
    // extends beyond the viewport still copies in full.
    const lines = new Map<number, string[]>()
    const captureLines = (snap: GhosttySnapshot | null) => {
      const range = sel()
      if (!range || !snap) return
      snap.rows.forEach((row, y) => {
        const abs = snap.startRow + y
        if (abs < range.start.row || abs > range.end.row) return
        const line = new Array<string>(snap.cols).fill(' ')
        for (const cell of row.cells) {
          if (cell.x >= snap.cols) continue
          line[cell.x] = cell.text || ' '
          if (cell.width === 2 && cell.x + 1 < snap.cols) line[cell.x + 1] = ''
        }
        lines.set(abs, line)
      })
    }

    // Text-fallback twin of captureLines: rows are screen-relative (start 0).
    const captureText = (screen: TextScreen) => {
      const range = sel()
      if (!range) return
      screen.text().split('\n').forEach((text, y) => {
        if (y < range.start.row || y > range.end.row) return
        const line = new Array<string>(screen.cols).fill(' ')
        ;[...text].slice(0, screen.cols).forEach((glyph, x) => {
          line[x] = glyph
        })
        lines.set(y, line)
      })
    }

    let copied_timer = 0
    const clearSelection = () => {
      window.clearTimeout(copied_timer)
      lines.clear()
      setSel(null)
      setHandles(false)
      closeBar()
    }

    const select = (a: CellPoint, b: CellPoint) => {
      window.clearTimeout(copied_timer)
      const range = orderRange(a, b)
      for (const row of lines.keys()) if (row < range.start.row || row > range.end.row) lines.delete(row)
      setSel(range)
      if (text_screen && !wasm_ok) captureText(text_screen)
      else captureLines(snapshotSafe())
    }

    const pointAt = (client_x: number, client_y: number): CellPoint | null => {
      const grid = geo()
      if (!grid) return null
      const rect = surface.getBoundingClientRect()
      const x = Math.floor((client_x - rect.left) / grid.cw)
      const y = Math.floor((client_y - rect.top) / grid.ch)
      return {
        x: Math.max(0, Math.min(grid.cols - 1, x)),
        row: grid.start + Math.max(0, Math.min(grid.rows - 1, y)),
      }
    }

    const selectWordAt = (point: CellPoint) => {
      select(point, point)
      const word = wordBounds(lines.get(point.row) ?? [], point.x)
      select({ x: word.from, row: point.row }, { x: word.to, row: point.row })
      return word
    }

    /// Anchor the action bar above the selection (below when there is no room).
    const showBarAtSelection = () => {
      const range = sel()
      const grid = geo()
      if (!range || !grid || !frame) return
      const rect = surface.getBoundingClientRect()
      const outer = frame.getBoundingClientRect()
      const top_row = Math.max(0, Math.min(grid.rows - 1, range.start.row - grid.start))
      const bottom_row = Math.max(0, Math.min(grid.rows - 1, range.end.row - grid.start))
      const mid = range.start.row === range.end.row ? ((range.start.x + range.end.x + 1) / 2) * grid.cw : outer.width / 2
      const above = rect.top - outer.top + top_row * grid.ch - 52
      const below = rect.top - outer.top + (bottom_row + 1) * grid.ch + 24
      setBar({ x: rect.left - outer.left + mid, y: above >= 4 ? above : below })
    }

    const sendPaste = (text: string) => {
      closeBar()
      if (!text) return
      void writePane(
        store.client,
        props.workspaceId,
        props.paneId,
        pasteBytes(text, bracketed_paste),
        sessionId(),
      ).then(kick)
    }

    const copySelection = () => {
      const range = sel()
      if (!range) return
      const text = selectionText(range, lines)
      const done = () => {
        setCopied(true)
        copied_timer = window.setTimeout(clearSelection, 600)
      }
      const legacy = () => {
        // Insecure contexts (plain http over LAN) have no async clipboard.
        const scratch = document.createElement('textarea')
        const focused = document.activeElement as HTMLElement | null
        scratch.value = text
        // readOnly + 16px: no soft keyboard, no iOS focus-zoom.
        scratch.readOnly = true
        scratch.style.position = 'fixed'
        scratch.style.opacity = '0'
        scratch.style.fontSize = '16px'
        document.body.append(scratch)
        scratch.select()
        let ok = false
        try {
          ok = document.execCommand('copy')
        } catch {
          ok = false
        }
        scratch.remove()
        focused?.focus({ preventScroll: true })
        if (ok) done()
        else store.setNotice('Copy failed')
      }
      if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).then(done, legacy)
      else legacy()
    }

    const pasteClipboard = () => {
      const fallback = () => {
        // Permission denied or unsupported: offer a real field so the
        // platform's own paste gesture can deliver the text.
        // Top-anchored: the box is taller than the bar clamp allows for, and the
        // soft keyboard shrinks the pane from the bottom.
        if (frame) setBar({ x: bar()?.x ?? frame.clientWidth / 2, y: 8 })
        setPasteBox(true)
      }
      if (!navigator.clipboard?.readText) return fallback()
      navigator.clipboard.readText().then(sendPaste, fallback)
    }

    const selectAllVisible = () => {
      const grid = geo()
      if (!grid) return
      select({ x: 0, row: grid.start }, { x: grid.cols - 1, row: grid.start + grid.rows - 1 })
    }

    actions = { copy: copySelection, paste: pasteClipboard, selectAll: selectAllVisible, sendPaste }

    const snapshotSafe = (): GhosttySnapshot | null => {
      if (!term || !wasm_ok) return null
      try {
        return term.snapshot()
      } catch {
        killWasm()
        return null
      }
    }

    const writeSafe = (vt: GhosttyTerminal, bytes: string) => {
      if (!wasm_ok || !bytes) return false
      try {
        for (const chunk of splitPtyChunks(bytes)) vt.write(chunk)
        return true
      } catch {
        killWasm()
        return false
      }
    }

    const paintText = (ghostty: typeof import('../lib/ghostty'), screen: TextScreen) => {
      const metrics = ghostty.paintGhostty(surface, {
        screen: screen.text(),
        cols: screen.cols,
        rows: screen.rows,
        zoom,
        cursor: screen.cursor.visible ? { ...screen.cursor } : { visible: false },
      })
      if (metrics) cell_h_px = metrics.cell_h
      if (metrics) {
        const next: GridGeo = {
          cw: metrics.cell_w,
          ch: metrics.cell_h,
          start: 0,
          cols: screen.cols,
          rows: screen.rows,
          ox: surface.offsetLeft,
          oy: surface.offsetTop,
        }
        const prev = geo()
        if (prev && prev.cols !== next.cols && sel()) clearSelection()
        if (!prev || (Object.keys(next) as (keyof GridGeo)[]).some((key) => prev[key] !== next[key])) setGeo(next)
        captureText(screen)
      }
      if (pinned_bottom) scroller.scrollTop = scroller.scrollHeight
    }

    const paint = async (snap?: GhosttySnapshot | null) => {
      const ghostty = await engine()
      if (disposed) return
      if (!wasm_ok) {
        if (text_screen) paintText(ghostty, text_screen)
        else ghostty.paintGhostty(surface, { screen: '', cols, rows, zoom })
        return
      }
      const raw_view = snap ?? snapshotSafe()
      // Snapshot cursor coordinates are screen-relative; hide the cursor while
      // scrolled into history so it does not overlay old rows.
      const view = raw_view && !viewport_bottom ? { ...raw_view, cursor: null } : raw_view
      const metrics = ghostty.paintGhostty(surface, {
        snap: view,
        screen: '',
        cols: view?.cols ?? cols,
        rows: view?.visibleRows ?? view?.rows.length ?? rows,
        zoom,
        cursor: view?.cursor ?? undefined,
      })
      if (metrics) cell_h_px = metrics.cell_h
      if (metrics && view) {
        const next: GridGeo = {
          cw: metrics.cell_w,
          ch: metrics.cell_h,
          start: view.startRow,
          cols: view.cols,
          rows: view.visibleRows || view.rows.length,
          ox: surface.offsetLeft,
          oy: surface.offsetTop,
        }
        const prev = geo()
        // A reflow renumbers rows, so a selection cannot survive a column change.
        if (prev && prev.cols !== next.cols && sel()) clearSelection()
        if (!prev || (Object.keys(next) as (keyof GridGeo)[]).some((key) => prev[key] !== next[key])) setGeo(next)
        captureLines(view)
      }
      if (metrics?.compact && pinned_bottom) {
        const x = metrics.cursor_x * metrics.cell_w
        const margin = metrics.cell_w * 4
        const left = scroller.scrollLeft
        const right = left + scroller.clientWidth
        if (x < left + margin || x > right - margin) {
          scroller.scrollLeft = Math.max(0, x - scroller.clientWidth / 2)
        }
      }
      if (pinned_bottom) scroller.scrollTop = scroller.scrollHeight
    }

    const syncSize = async (id: string) => {
      const grid = measure()
      if (grid.cols === cols && grid.rows === rows && resize_sent === `${id}:${cols}x${rows}`) return
      cols = grid.cols
      rows = grid.rows
      term?.resize(cols, rows)
      text_screen?.resize(cols, rows)
      resize_sent = `${id}:${cols}x${rows}`
      await resizeSession(store.client, id, cols, rows)
    }

    const pumpOnce = async () => {
      try {
        const session_id = sessionId()
        if (!session_id) {
          await paint(null)
          return
        }
        if (scroller.clientWidth < 8 || scroller.clientHeight < 8) return
        await syncSize(session_id)
        let vt: GhosttyTerminal | null = null
        if (wasm_ok) {
          try {
            vt = await ensure()
          } catch (error) {
            engineLoadFailed(error)
            // Transient failure: leave tail_offset unset so the retry replays
            // the ring into the engine instead of skipping this output.
            if (wasm_ok) {
              await paint(null)
              return
            }
          }
        }
        if (disposed) return
        const text = wasm_ok ? null : textScreen()

        const tailed = await tailSession(store.client, session_id, tail_offset)
        if (disposed) return
        const raw = tailed?.text ?? ''
        if (raw) last_activity_ms = Date.now()
        if (tail_offset == null) {
          const tail = alignPtyStream(raw)
          if (vt && tail) writeSafe(vt, tail)
          if (text) {
            text.reset()
            text.write(tail)
          }
          trackAltScreen(tail)
        } else if (raw) {
          if (vt) writeSafe(vt, raw)
          text?.write(raw)
          trackAltScreen(raw)
        }
        // Wasm disabled mid-pump: keep tail_offset null so the next pump
        // replays the ring into the new text grid.
        const disabled_now = !wasm_ok && !text
        if (typeof tailed?.next_offset === 'number' && !disabled_now) tail_offset = tailed.next_offset

        if (pinned_bottom && term && wasm_ok) {
          try {
            term.scrollToBottom()
            viewport_bottom = true
          } catch {
            killWasm()
          }
        }
        const snap = snapshotSafe()
        if (snap) {
          cols = snap.cols
          rows = snap.visibleRows || snap.rows.length || rows
        }
        await paint(snap)
      } catch {
        await paint(snapshotSafe())
      }
    }

    // One pump at a time. Each pump reads tail_offset at the start and writes it
    // at the end, so overlapping pumps refetch the same bytes, write them into
    // the VT twice, and rewind the offset when they land out of order. On a phone
    // a pump routinely exceeds the 160ms tick, so unguarded ticks pile up into an
    // ever-growing backlog — the "massive delay" that worsens the longer you type.
    let pumping = false
    let pump_queued = false
    // Adaptive pacing: a terminal with flowing output (or fresh keystrokes)
    // polls at the fast tick; an idle one backs off. Flat 160ms polling per
    // visible terminal saturated the gateway's serial RPC loop and slowed
    // every other call the web app makes.
    const POLL_FAST_MS = 160
    const POLL_IDLE_MS = 1000
    const POLL_ACTIVE_WINDOW_MS = 3000
    let last_activity_ms = Date.now()
    let last_poll_ms = 0
    const pump = async () => {
      if (pumping) {
        pump_queued = true
        return
      }
      pumping = true
      try {
        await pumpOnce()
      } finally {
        pumping = false
        if (pump_queued && !disposed) {
          pump_queued = false
          void pump()
        }
      }
    }

    // Echo a keystroke as soon as its write lands instead of waiting out the
    // tick; typing also re-arms the fast polling window.
    const kick = () => {
      last_activity_ms = Date.now()
      void pump()
    }

    const onKeyDown = (event: KeyboardEvent) => {
      // An armed prefix owns every key, including the clipboard chords.
      if (store.prefixMode()) return
      const key = event.key.toLowerCase()
      if (event.ctrlKey && event.shiftKey && !event.altKey && (key === 'c' || key === 'v')) {
        event.stopPropagation()
        if (key === 'v') {
          // Native paste-as-plain-text lands in onPaste with no permission
          // prompt; the canvas has no paste target, so move focus first.
          if (event.target !== input) input.focus({ preventScroll: true })
          return
        }
        event.preventDefault()
        copySelection()
        return
      }
      if (event.metaKey && !event.ctrlKey && !event.altKey && key === 'c' && sel()) {
        event.preventDefault()
        event.stopPropagation()
        copySelection()
        return
      }
      if (store.shouldHandleKey(event)) return
      // Let the IME/soft keyboard deliver text through the input event instead.
      if (
        composing ||
        event.isComposing ||
        event.keyCode === 229 ||
        event.key === 'Unidentified' ||
        event.key === 'Process' ||
        event.key === 'Dead'
      )
        return
      event.preventDefault()
      event.stopPropagation()
      if ((sel() || bar()) && event.key === 'Escape') return clearSelection()
      if (sel() && !['Control', 'Shift', 'Alt', 'Meta'].includes(event.key)) clearSelection()
      void sendTerminalInput(props.workspaceId, props.paneId, sessionId(), event).then(kick)
    }

    const domAtBottom = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48

    const atViewportBottom = (snap?: GhosttySnapshot | null): boolean => {
      const view = snap ?? snapshotSafe()
      if (!view) return true
      return view.startRow + view.visibleRows >= view.totalRows
    }

    // Move the native Ghostty viewport through retained history; TUIs get the
    // gesture as arrow keys because the alternate screen has no scrollback.
    const scrollHistory = (step: number) => {
      if (!step) return
      if (alt_screen) {
        const bytes = (step < 0 ? NAMED_KEYS.up : NAMED_KEYS.down).repeat(Math.min(6, Math.abs(step)))
        void writePane(store.client, props.workspaceId, props.paneId, bytes, sessionId())
        return
      }
      if (!term || !wasm_ok) return
      try {
        term.scrollBy(step)
        const snap = term.snapshot()
        viewport_bottom = atViewportBottom(snap)
        pinned_bottom = viewport_bottom && domAtBottom()
        void paint(snap)
      } catch {
        killWasm()
      }
    }

    const scrollVertical = (px: number) => {
      if (!px) return
      const dom_max = scroller.scrollHeight - scroller.clientHeight
      // Up: drain the DOM overflow (phone tall-grid pan) before history.
      // Down: drain history back to the tail before the DOM overflow.
      if (px < 0 ? dom_max > 1 && scroller.scrollTop > 0 : dom_max > 1 && viewport_bottom) {
        scroller.scrollTop = Math.max(0, Math.min(dom_max, scroller.scrollTop + px))
        pinned_bottom = viewport_bottom && domAtBottom()
        return
      }
      scroll_rows_carry += px / Math.max(8, cell_h_px)
      const step = Math.trunc(scroll_rows_carry)
      if (step) {
        scroll_rows_carry -= step
        scrollHistory(step)
      }
    }

    const onWheel = (event: WheelEvent) => {
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault()
        event.stopPropagation()
        const next = event.deltaY < 0 ? zoom * 1.1 : zoom / 1.1
        zoom = Math.max(0.85, Math.min(2.4, next))
        void paint()
        return
      }
      event.preventDefault()
      event.stopPropagation()
      if (event.deltaX) scroller.scrollLeft += event.deltaX
      const px = event.deltaMode === 1
        ? event.deltaY * cell_h_px
        : event.deltaMode === 2
          ? event.deltaY * scroller.clientHeight
          : event.deltaY
      scrollVertical(px)
    }

    // A finished drag/long-press still emits a click; swallow it so it neither
    // clears the new selection nor raises the soft keyboard.
    let suppress_click = false
    const suppressClick = () => {
      suppress_click = true
      window.setTimeout(() => {
        suppress_click = false
      }, 400)
    }
    const onClickCapture = (event: MouseEvent) => {
      if (suppress_click) {
        suppress_click = false
        event.stopPropagation()
        return
      }
      if (sel() || bar()) {
        clearSelection()
        // A dismiss tap must not also raise the soft keyboard.
        if (Date.now() - last_touch_ms < 1000) event.stopPropagation()
      }
    }

    let mouse_anchor: { point: CellPoint; x: number; y: number; dragged: boolean } | null = null
    const onMouseMove = (event: MouseEvent) => {
      if (!mouse_anchor) return
      if (!mouse_anchor.dragged && Math.hypot(event.clientX - mouse_anchor.x, event.clientY - mouse_anchor.y) < 4) return
      const head = pointAt(event.clientX, event.clientY)
      if (!head) return
      mouse_anchor.dragged = true
      closeBar()
      setHandles(false)
      select(mouse_anchor.point, head)
    }
    const onMouseUp = () => {
      if (mouse_anchor?.dragged) suppressClick()
      mouse_anchor = null
      window.removeEventListener('mousemove', onMouseMove)
      window.removeEventListener('mouseup', onMouseUp)
    }
    const onMouseDown = (event: MouseEvent) => {
      if (event.button !== 0 || Date.now() - last_touch_ms < 1000) return
      // The host's own scrollbars are not text.
      if (event.target !== surface) return
      const point = pointAt(event.clientX, event.clientY)
      if (!point) return
      mouse_anchor = { point, x: event.clientX, y: event.clientY, dragged: false }
      window.addEventListener('mousemove', onMouseMove)
      window.addEventListener('mouseup', onMouseUp)
    }
    const onDoubleClick = (event: MouseEvent) => {
      const point = pointAt(event.clientX, event.clientY)
      if (!point) return
      setHandles(false)
      selectWordAt(point)
      suppressClick()
    }
    const onContextMenu = (event: MouseEvent) => {
      event.preventDefault()
      // Touch long-press also raises contextmenu; the touch path owns that.
      if (Date.now() - last_touch_ms < 1000 || !frame) return
      const outer = frame.getBoundingClientRect()
      setPasteBox(false)
      setCopied(false)
      setBar({ x: event.clientX - outer.left, y: event.clientY - outer.top + 6 })
    }

    let last_touch_ms = 0
    let long_press = 0
    let touch_select: CellPoint | null = null
    // The long-pressed word stays whole while the finger extends past it.
    let touch_word: { from: number; to: number; row: number } | null = null
    const cancelLongPress = () => {
      window.clearTimeout(long_press)
      long_press = 0
    }
    const grabbedHandle = (touch: Touch): CellPoint | null => {
      const range = sel()
      if (!range || !handles()) return null
      const rect = surface.getBoundingClientRect()
      let best: { reach: number; anchor: CellPoint } | null = null
      for (const which of ['start', 'end'] as const) {
        const at = handlePoint(which)
        if (!at) continue
        const reach = Math.hypot(touch.clientX - rect.left - at.x, touch.clientY - rect.top - at.y)
        // Dragging one handle pivots around the opposite end.
        if (reach <= HANDLE_REACH_PX && (!best || reach < best.reach)) {
          best = { reach, anchor: which === 'start' ? range.end : range.start }
        }
      }
      return best?.anchor ?? null
    }

    let pinch: { distance: number; zoom: number } | null = null
    let touch_pan: { x: number; y: number } | null = null
    const touchDistance = (touches: TouchList) => {
      if (touches.length < 2) return 0
      const dx = touches[0].clientX - touches[1].clientX
      const dy = touches[0].clientY - touches[1].clientY
      return Math.hypot(dx, dy)
    }
    const onTouchStart = (event: TouchEvent) => {
      last_touch_ms = Date.now()
      cancelLongPress()
      if (event.touches.length === 2) {
        pinch = { distance: touchDistance(event.touches), zoom }
        touch_pan = null
        touch_select = null
      } else if (event.touches.length === 1) {
        const touch = event.touches[0]
        touch_pan = { x: touch.clientX, y: touch.clientY }
        touch_word = null
        touch_select = grabbedHandle(touch)
        if (touch_select) {
          closeBar()
          return
        }
        const { clientX, clientY } = touch
        long_press = window.setTimeout(() => {
          long_press = 0
          const point = pointAt(clientX, clientY)
          if (!point) return
          setHandles(true)
          closeBar()
          const word = selectWordAt(point)
          touch_select = { x: word.from, row: point.row }
          touch_word = { ...word, row: point.row }
          navigator.vibrate?.(8)
        }, LONG_PRESS_MS)
      }
    }
    const onTouchMove = (event: TouchEvent) => {
      last_touch_ms = Date.now()
      if (touch_select && event.touches.length === 1) {
        if (event.cancelable) event.preventDefault()
        const head = pointAt(event.touches[0].clientX, event.touches[0].clientY)
        if (head && touch_word) {
          const before = head.row < touch_word.row || (head.row === touch_word.row && head.x < touch_word.from)
          const after = head.row > touch_word.row || (head.row === touch_word.row && head.x > touch_word.to)
          select(
            before ? head : { x: touch_word.from, row: touch_word.row },
            after ? head : { x: touch_word.to, row: touch_word.row },
          )
        } else if (head) select(touch_select, head)
        return
      }
      if (long_press && touch_pan && event.touches.length === 1) {
        const moved = Math.hypot(event.touches[0].clientX - touch_pan.x, event.touches[0].clientY - touch_pan.y)
        // Finger jitter must not cancel the hold, and must not pan either.
        if (moved < 10) return
        cancelLongPress()
      }
      if (pinch && event.touches.length === 2) {
        event.preventDefault()
        const distance = touchDistance(event.touches)
        if (pinch.distance < 8) return
        zoom = Math.max(0.85, Math.min(2.4, pinch.zoom * (distance / pinch.distance)))
        void paint()
        return
      }
      if (!touch_pan || event.touches.length !== 1) return
      const touch = event.touches[0]
      const dy = touch_pan.y - touch.clientY
      const dx = touch_pan.x - touch.clientX
      touch_pan = { x: touch.clientX, y: touch.clientY }
      // Horizontal pans stay native (CSS touch-action: pan-x); vertical is ours.
      if (Math.abs(dy) <= Math.abs(dx)) return
      if (event.cancelable) event.preventDefault()
      scrollVertical(dy)
    }
    const onTouchEnd = () => {
      last_touch_ms = Date.now()
      cancelLongPress()
      if (touch_select) {
        touch_select = null
        touch_word = null
        suppressClick()
        showBarAtSelection()
      }
      pinch = null
      touch_pan = null
    }

    const onPaste = (event: ClipboardEvent) => {
      event.preventDefault()
      sendPaste(event.clipboardData?.getData('text/plain') ?? '')
    }

    const onScroll = () => {
      pinned_bottom = viewport_bottom && domAtBottom()
    }

    // Android soft keyboards type through IME composition: keydown is
    // 'Unidentified' and text lives only in the field until the word commits.
    // So mirror the field: on every input event diff against what was already
    // sent and forward the delta (deletions become \x7f) — live, even
    // mid-composition, so each keystroke reaches the PTY immediately.
    // Keydown-handled keys call preventDefault, never mutate the field, and
    // therefore cannot double-send through this path.
    let sent_value = ''
    const syncFromField = () => {
      const value = input.value
      if (value !== sent_value) {
        let prefix = 0
        const min = Math.min(sent_value.length, value.length)
        while (prefix < min && sent_value[prefix] === value[prefix]) prefix += 1
        const dels = '\x7f'.repeat(sent_value.length - prefix)
        const adds = value.slice(prefix).replace(/\n/g, '\r')
        sent_value = value
        if (dels || adds) {
          void writePane(store.client, props.workspaceId, props.paneId, dels + adds, sessionId()).then(kick)
        }
      }
      // Shed committed text so the invisible field cannot grow forever. Never
      // clear mid-composition: that would corrupt the IME state.
      if (!composing && (value.includes('\n') || value.length > 200)) {
        input.value = ''
        sent_value = ''
      }
    }
    const onInput = () => {
      syncFromField()
    }
    const onCompositionStart = () => {
      composing = true
    }
    const onCompositionEnd = () => {
      composing = false
      syncFromField()
    }
    const onBlur = () => {
      composing = false
      input.value = ''
      sent_value = ''
    }

    surface.tabIndex = 0
    surface.addEventListener('keydown', onKeyDown)
    input.addEventListener('keydown', onKeyDown)
    input.addEventListener('input', onInput)
    input.addEventListener('compositionstart', onCompositionStart)
    input.addEventListener('compositionend', onCompositionEnd)
    input.addEventListener('blur', onBlur)
    input.addEventListener('paste', onPaste)
    scroller.addEventListener('click', onClickCapture, true)
    scroller.addEventListener('mousedown', onMouseDown)
    scroller.addEventListener('dblclick', onDoubleClick)
    scroller.addEventListener('contextmenu', onContextMenu)
    scroller.addEventListener('touchcancel', onTouchEnd)
    scroller.addEventListener('wheel', onWheel, { passive: false })
    scroller.addEventListener('scroll', onScroll, { passive: true })
    scroller.addEventListener('touchstart', onTouchStart, { passive: true })
    scroller.addEventListener('touchmove', onTouchMove, { passive: false })
    scroller.addEventListener('touchend', onTouchEnd)
    // The desktop GUI re-asserts its grid on the shared PTY while its window
    // is focused; clearing the sent-key makes the next pump re-send this
    // client's size, so whichever client the user is actually in owns it.
    const onWindowFocus = () => {
      resize_sent = ''
      void pump()
    }
    window.addEventListener('focus', onWindowFocus)
    const observer = new ResizeObserver(() => {
      void pump()
    })
    observer.observe(scroller)
    const poll = window.setInterval(() => {
      const now = Date.now()
      const idle = now - last_activity_ms > POLL_ACTIVE_WINDOW_MS
      if (idle && now - last_poll_ms < POLL_IDLE_MS) return
      last_poll_ms = now
      void pump()
    }, POLL_FAST_MS)
    void pump()

    onCleanup(() => {
      disposed = true
      window.clearInterval(poll)
      window.removeEventListener('focus', onWindowFocus)
      observer.disconnect()
      surface.removeEventListener('keydown', onKeyDown)
      input.removeEventListener('keydown', onKeyDown)
      input.removeEventListener('input', onInput)
      input.removeEventListener('compositionstart', onCompositionStart)
      input.removeEventListener('compositionend', onCompositionEnd)
      input.removeEventListener('blur', onBlur)
      input.removeEventListener('paste', onPaste)
      cancelLongPress()
      window.clearTimeout(copied_timer)
      onMouseUp()
      actions = null
      scroller.removeEventListener('click', onClickCapture, true)
      scroller.removeEventListener('mousedown', onMouseDown)
      scroller.removeEventListener('dblclick', onDoubleClick)
      scroller.removeEventListener('contextmenu', onContextMenu)
      scroller.removeEventListener('touchcancel', onTouchEnd)
      scroller.removeEventListener('wheel', onWheel)
      scroller.removeEventListener('scroll', onScroll)
      scroller.removeEventListener('touchstart', onTouchStart)
      scroller.removeEventListener('touchmove', onTouchMove)
      scroller.removeEventListener('touchend', onTouchEnd)
      term?.dispose()
    })
  })

  // A canvas cannot summon the virtual keyboard; taps focus the hidden
  // textarea so phones get a real input target. Tap-vs-drag is decided by the
  // browser: click only fires for taps without movement.
  const focusKeys = () => {
    key_input?.focus({ preventScroll: true })
  }

  return (
    <section
      ref={(node) => {
        frame = node
      }}
      class="relative flex min-h-0 min-w-0 flex-1 flex-col bg-[var(--chat-black)]"
      onMouseDown={() => {
        const pane = store.openPanes().find((item) => item.pane_id === props.paneId)
        if (pane) store.focusPane(pane)
      }}
      onClick={focusKeys}
    >
      <div
        class="ghostty-host min-h-0 min-w-0 flex-1"
        ref={(node) => {
          host = node
        }}
      >
        <canvas
          class="ghostty-canvas"
          ref={(node) => {
            canvas = node
          }}
        />
        <div class="vt-select-layer" style={{ left: `${geo()?.ox ?? 0}px`, top: `${geo()?.oy ?? 0}px` }}>
          <For each={highlight()}>
            {(rect) => (
              <div
                class="vt-select-rect"
                style={{
                  left: `${rect.left}px`,
                  top: `${rect.top}px`,
                  width: `${rect.width}px`,
                  height: `${geo()?.ch ?? 0}px`,
                }}
              />
            )}
          </For>
          <Show when={handles()}>
            <For each={['start', 'end'] as const}>
              {(which) => (
                <Show when={handlePoint(which)}>
                  {(at) => <div class="vt-select-handle" style={{ left: `${at().x}px`, top: `${at().y}px` }} />}
                </Show>
              )}
            </For>
          </Show>
        </div>
      </div>
      <Show when={text_mode()}>
        <span
          class="absolute right-2 top-1.5 z-10 rounded-[6px] border border-[var(--border-muted)] bg-[var(--panel)] px-1.5 py-0.5 text-[11px] text-[var(--text-subtle)] opacity-80"
          title="The terminal engine could not load; showing plain text without colours or scrollback."
        >
          Text mode
        </span>
      </Show>
      <Show when={bar()}>
        {(at) => (
          <div
            class="vt-actions"
            style={{ '--vt-y': `${at().y}px` }}
            ref={(node) => {
              // Center on the anchor, then clamp inside the pane and safe areas.
              const place = () => {
                const pane = node.parentElement
                if (!pane) return
                const hi = pane.clientWidth - node.offsetWidth - 8
                node.style.setProperty('--vt-w', `${node.offsetWidth}px`)
                node.style.setProperty('--vt-left', `${Math.max(8, Math.min(hi, (bar()?.x ?? 0) - node.offsetWidth / 2))}px`)
              }
              // Re-place when the anchor moves or the contents change width.
              createEffect(() => {
                bar()
                paste_box()
                sel()
                queueMicrotask(place)
              })
            }}
            onMouseDown={(event) => {
              // Keep terminal focus (and the soft keyboard state) while tapping.
              if (!paste_box()) event.preventDefault()
              event.stopPropagation()
            }}
            onClick={(event) => event.stopPropagation()}
          >
            <Show
              when={paste_box()}
              fallback={
                <div
                  class="anim-menu flex overflow-hidden rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] shadow-lg"
                  role="toolbar"
                  aria-label="Terminal selection"
                >
                  <span class="sr-only" aria-live="polite">{copied() ? 'Copied' : ''}</span>
                  <Show when={sel()}>
                    <button type="button" class="vt-action" onClick={() => actions?.copy()}>
                      {copied() ? 'Copied' : 'Copy'}
                    </button>
                  </Show>
                  <button type="button" class="vt-action" onClick={() => actions?.paste()}>
                    Paste
                  </button>
                  <button type="button" class="vt-action" onClick={() => actions?.selectAll()}>
                    Select all
                  </button>
                </div>
              }
            >
              <div role="dialog" aria-label="Paste into terminal" class="anim-pop flex w-[15rem] flex-col gap-2 rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] p-2 shadow-lg">
                <textarea
                  class="vt-paste-field"
                  rows={2}
                  placeholder="Clipboard access is blocked. Paste here."
                  aria-label="Paste text for the terminal"
                  ref={(node) => queueMicrotask(() => node.focus())}
                  onPaste={(event) => {
                    event.preventDefault()
                    actions?.sendPaste(event.clipboardData?.getData('text/plain') ?? '')
                  }}
                  onKeyDown={(event) => {
                    event.stopPropagation()
                    if (event.key === 'Escape') closeBar()
                  }}
                />
                <div class="flex justify-end">
                  <button type="button" class="vt-action" onClick={closeBar}>
                    Cancel
                  </button>
                  <button
                    type="button"
                    class="vt-action vt-action-primary"
                    onClick={(event) => {
                      const field = event.currentTarget.closest('.vt-actions')?.querySelector('textarea')
                      actions?.sendPaste(field?.value ?? '')
                    }}
                  >
                    Send
                  </button>
                </div>
              </div>
            </Show>
          </div>
        )}
      </Show>
      <textarea
        class="ghostty-key-input"
        ref={(node) => {
          key_input = node
        }}
        autocomplete="off"
        autocapitalize="none"
        autocorrect="off"
        spellcheck={false}
        enterkeyhint="enter"
        aria-label="Terminal input"
        rows={1}
      />
    </section>
  )
}

const NAMED_KEYS: Record<string, string> = {
  enter: '\r',
  backspace: '\x7f',
  tab: '\t',
  escape: '\x1b',
  up: '\x1b[A',
  down: '\x1b[B',
  right: '\x1b[C',
  left: '\x1b[D',
  home: '\x1b[H',
  end: '\x1b[F',
  pageup: '\x1b[5~',
  pagedown: '\x1b[6~',
  delete: '\x1b[3~',
}

async function sendTerminalInput(
  workspaceId: string,
  paneId: number,
  sessionId: string | undefined,
  event: KeyboardEvent,
): Promise<void> {
  const named = KEY_NAMES[event.key]
  if (named && sessionId) {
    const bytes = NAMED_KEYS[named]
    if (bytes) await writePane(store.client, workspaceId, paneId, bytes, sessionId)
    return
  }
  if (named) {
    await store.client.call('terminal.key', {
      workspace_id: workspaceId,
      pane: paneId,
      key: named,
      ctrl: event.ctrlKey,
      alt: event.altKey,
      shift: event.shiftKey,
    })
    return
  }
  if ((event.ctrlKey || event.metaKey) && event.key.length === 1) {
    const code = event.key.toLowerCase().charCodeAt(0) - 96
    if (code >= 1 && code <= 26) {
      await writePane(store.client, workspaceId, paneId, String.fromCharCode(code), sessionId)
      return
    }
  }
  if (event.key.length === 1) {
    await writePane(store.client, workspaceId, paneId, event.key, sessionId)
  }
}

function splitPtyChunks(bytes: string, size = 4096): string[] {
  if (bytes.length <= size) return [bytes]
  const chunks: string[] = []
  let index = 0
  while (index < bytes.length) {
    let end = Math.min(bytes.length, index + size)
    if (end < bytes.length) {
      const newline = bytes.lastIndexOf('\n', end)
      if (newline > index) end = newline + 1
    }
    chunks.push(bytes.slice(index, end))
    index = end
  }
  return chunks
}

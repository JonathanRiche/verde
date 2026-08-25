import { onCleanup, onMount } from 'solid-js'

import { alignPtyStream, resizeSession, tailSession, writePane } from '../lib/pty'
import { store } from '../lib/store'

import type { GhosttySnapshot, GhosttyTerminal } from '../lib/ghostty'

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
    let cell_h_px = 20
    let scroll_rows_carry = 0
    let composing = false
    let wasm_ok = true
    let wasm_crashes = 0
    let load: typeof import('../lib/ghostty') | null = null
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
      term?.dispose()
      term = null
      tail_offset = null
      viewport_bottom = true
      if (wasm_crashes >= 6) wasm_ok = false
    }

    // DEC 1049/1047 track alternate-screen apps in the raw stream; the WASM
    // snapshot does not expose terminal modes.
    const trackAltScreen = (bytes: string) => {
      const on = Math.max(bytes.lastIndexOf('\x1b[?1049h'), bytes.lastIndexOf('\x1b[?1047h'))
      const off = Math.max(bytes.lastIndexOf('\x1b[?1049l'), bytes.lastIndexOf('\x1b[?1047l'))
      if (on >= 0 || off >= 0) alt_screen = on > off
    }

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

    const paint = async (snap?: GhosttySnapshot | null) => {
      const ghostty = await engine()
      if (disposed) return
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
        const vt = wasm_ok ? await ensure() : null
        if (disposed) return

        const tailed = await tailSession(store.client, session_id, tail_offset)
        if (disposed) return
        const raw = tailed?.text ?? ''
        if (raw) last_activity_ms = Date.now()
        if (tail_offset == null) {
          const tail = alignPtyStream(raw)
          if (vt && tail) writeSafe(vt, tail)
          trackAltScreen(tail)
        } else if (raw) {
          if (vt) writeSafe(vt, raw)
          trackAltScreen(raw)
        }
        if (typeof tailed?.next_offset === 'number') tail_offset = tailed.next_offset

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

    let pinch: { distance: number; zoom: number } | null = null
    let touch_pan: { x: number; y: number } | null = null
    const touchDistance = (touches: TouchList) => {
      if (touches.length < 2) return 0
      const dx = touches[0].clientX - touches[1].clientX
      const dy = touches[0].clientY - touches[1].clientY
      return Math.hypot(dx, dy)
    }
    const onTouchStart = (event: TouchEvent) => {
      if (event.touches.length === 2) {
        pinch = { distance: touchDistance(event.touches), zoom }
        touch_pan = null
      } else if (event.touches.length === 1) {
        touch_pan = { x: event.touches[0].clientX, y: event.touches[0].clientY }
      }
    }
    const onTouchMove = (event: TouchEvent) => {
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
      pinch = null
      touch_pan = null
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
      </div>
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

import { onCleanup, onMount } from 'solid-js'

import { matchKeyAction } from '../lib/keybinds'
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

  onMount(() => {
    const surface = canvas
    const scroller = host
    if (!surface || !scroller) return

    let disposed = false
    let term: GhosttyTerminal | null = null
    let last_tail = ''
    let tail_offset: number | null = null
    let cols = 80
    let rows = 24
    let zoom = 1
    let pinned_bottom = true
    let wasm_ok = true
    let wasm_crashes = 0
    let load: typeof import('../lib/ghostty') | null = null
    let resize_sent = ''

    const engine = async () => {
      load ??= await import('../lib/ghostty')
      return load
    }

    const sessionId = () =>
      props.sessionId ||
      store.openPanes().find((item) => item.pane_id === props.paneId && item.workspace_id === props.workspaceId)
        ?.session_id

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
      cols = grid.cols
      rows = grid.rows
      if (term) {
        term.resize(cols, rows)
        return term
      }
      term = await ghostty.openGhostty(cols, rows)
      return term
    }

    const killWasm = () => {
      wasm_crashes += 1
      term?.dispose()
      term = null
      last_tail = ''
      tail_offset = null
      if (wasm_crashes >= 6) wasm_ok = false
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
      const view = snap ?? snapshotSafe()
      const metrics = ghostty.paintGhostty(surface, {
        snap: view,
        screen: '',
        cols: view?.cols ?? cols,
        rows: view?.visibleRows ?? view?.rows.length ?? rows,
        zoom,
        cursor: view?.cursor ?? undefined,
      })
      if (metrics?.compact) {
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

    const pump = async () => {
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
        if (tail_offset == null) {
          const tail = alignPtyStream(raw)
          if (vt && tail) writeSafe(vt, tail)
          last_tail = tail
        } else if (raw) {
          if (vt) writeSafe(vt, raw)
          last_tail += raw
        }
        if (typeof tailed?.next_offset === 'number') tail_offset = tailed.next_offset

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

    const onKeyDown = (event: KeyboardEvent) => {
      if (matchKeyAction(event)) return
      event.preventDefault()
      event.stopPropagation()
      void sendTerminalInput(props.workspaceId, props.paneId, sessionId(), event)
    }

    const onWheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()
      event.stopPropagation()
      const next = event.deltaY < 0 ? zoom * 1.1 : zoom / 1.1
      zoom = Math.max(0.85, Math.min(2.4, next))
      void paint()
    }

    let pinch: { distance: number; zoom: number } | null = null
    const touchDistance = (touches: TouchList) => {
      if (touches.length < 2) return 0
      const dx = touches[0].clientX - touches[1].clientX
      const dy = touches[0].clientY - touches[1].clientY
      return Math.hypot(dx, dy)
    }
    const onTouchStart = (event: TouchEvent) => {
      if (event.touches.length === 2) {
        pinch = { distance: touchDistance(event.touches), zoom }
      }
    }
    const onTouchMove = (event: TouchEvent) => {
      if (!pinch || event.touches.length !== 2) return
      event.preventDefault()
      const distance = touchDistance(event.touches)
      if (pinch.distance < 8) return
      zoom = Math.max(0.85, Math.min(2.4, pinch.zoom * (distance / pinch.distance)))
      void paint()
    }
    const onTouchEnd = () => {
      pinch = null
    }

    const onScroll = () => {
      pinned_bottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48
    }

    surface.tabIndex = 0
    surface.addEventListener('keydown', onKeyDown)
    scroller.addEventListener('wheel', onWheel, { passive: false })
    scroller.addEventListener('scroll', onScroll, { passive: true })
    scroller.addEventListener('touchstart', onTouchStart, { passive: true })
    scroller.addEventListener('touchmove', onTouchMove, { passive: false })
    scroller.addEventListener('touchend', onTouchEnd)
    const observer = new ResizeObserver(() => {
      void pump()
    })
    observer.observe(scroller)
    const poll = window.setInterval(() => {
      void pump()
    }, 160)
    void pump()

    onCleanup(() => {
      disposed = true
      window.clearInterval(poll)
      observer.disconnect()
      surface.removeEventListener('keydown', onKeyDown)
      scroller.removeEventListener('wheel', onWheel)
      scroller.removeEventListener('scroll', onScroll)
      scroller.removeEventListener('touchstart', onTouchStart)
      scroller.removeEventListener('touchmove', onTouchMove)
      scroller.removeEventListener('touchend', onTouchEnd)
      term?.dispose()
    })
  })

  return (
    <section
      class="flex min-h-0 min-w-0 flex-1 flex-col bg-[var(--chat-black)]"
      onMouseDown={() => {
        canvas?.focus()
        const pane = store.openPanes().find((item) => item.pane_id === props.paneId)
        if (pane) store.focusPane(pane)
      }}
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

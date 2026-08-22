import { For, Show, createEffect, createMemo, onCleanup, onMount } from 'solid-js'

import { store } from '../lib/store'
import type { LivePane } from '../lib/types'
import { effectivePanesPerView } from '../lib/ui_config'
import { ChatPane } from './ChatPane'
import { Icon, ZoomButton } from './Icons'
import { TerminalView } from './Terminals'

export function WorkspaceCanvas() {
  let scroller: HTMLDivElement | undefined
  let ignore_scroll = false
  let scroll_timer = 0
  let focus_timer = 0
  let last_focused_id: number | null = null

  // Zoom renders only the maximized pane; the single column then naturally
  // fills the strip and other panes remount from daemon state on unzoom.
  const panes = () => {
    const all = store.openPanes()
    const zoomed_id = store.maximizedPaneId()
    if (zoomed_id != null) {
      const zoomed = all.filter((pane) => pane.pane_id === zoomed_id)
      if (zoomed.length > 0) return zoomed
    }
    return all
  }

  const pane_order = createMemo(() => panes().map((pane) => pane.pane_id).join(','))

  createEffect(() => {
    pane_order()
    const id = store.focusedPaneId()
    const root = scroller
    if (!root || id == null) return
    const column = root.querySelector(`[data-pane-id="${id}"]`)
    if (!(column instanceof HTMLElement)) return
    const instant = store.takeInstantFocus(id) || last_focused_id === id
    last_focused_id = id
    ignore_scroll = true
    window.clearTimeout(focus_timer)
    column.scrollIntoView({ inline: 'start', block: 'nearest', behavior: instant ? 'auto' : 'smooth' })
    focus_timer = window.setTimeout(() => {
      ignore_scroll = false
    }, instant ? 120 : 450)
  })

  onMount(() => {
    const root = scroller
    if (!root) return

    const onWheel = (event: WheelEvent) => {
      if (event.ctrlKey) return
      const target = event.target
      if (target instanceof Element && target.closest('.ghostty-host, .scrollbar-thin, textarea')) return
      if (Math.abs(event.deltaX) >= Math.abs(event.deltaY)) return
      event.preventDefault()
      root.scrollLeft += event.deltaY
    }

    const onScroll = () => {
      if (ignore_scroll) return
      window.clearTimeout(scroll_timer)
      scroll_timer = window.setTimeout(() => {
        const id = nearestPaneId(root)
        const pane = store.openPanes().find((item) => item.pane_id === id)
        if (pane) store.focusPane(pane)
      }, 80)
    }

    root.addEventListener('wheel', onWheel, { passive: false })
    root.addEventListener('scroll', onScroll, { passive: true })
    onCleanup(() => {
      window.clearTimeout(focus_timer)
      window.clearTimeout(scroll_timer)
      root.removeEventListener('wheel', onWheel)
      root.removeEventListener('scroll', onScroll)
    })
  })

  const inset = () => store.maximizedPaneId() == null && !store.compact()
  const panes_per_view = () =>
    effectivePanesPerView(store.uiConfig(), panes().length, store.maximizedPaneId() != null)
  const pane_gap = () => store.uiConfig().workspace_pane_gap

  return (
    <div
      class={`niri-strip flex min-h-0 min-w-0 flex-1 overflow-x-auto overflow-y-hidden ${store.initialViewReady() ? '' : 'invisible'} ${inset() ? 'niri-inset' : 'niri-zoomed'}`}
      style={{
        '--workspace-pane-gap': inset() ? `${pane_gap()}px` : '0px',
        '--workspace-panes-per-view': String(Math.max(1, panes_per_view())),
      }}
      ref={(node) => {
        scroller = node
      }}
    >
      <For each={panes()} fallback={<EmptyWorkspace />}>
        {(pane) => (
          <div class="niri-column" data-pane-id={String(pane.pane_id)}>
            <PaneFrame pane={pane} />
          </div>
        )}
      </For>
    </div>
  )
}

function nearestPaneId(root: HTMLDivElement): number | null {
  const mid = root.scrollLeft + root.clientWidth / 2
  let best: { id: number; dist: number } | null = null
  for (const node of root.querySelectorAll('[data-pane-id]')) {
    if (!(node instanceof HTMLElement)) continue
    const center = node.offsetLeft + node.offsetWidth / 2
    const dist = Math.abs(center - mid)
    const id = Number(node.dataset.paneId)
    if (!Number.isFinite(id)) continue
    if (!best || dist < best.dist) best = { id, dist }
  }
  return best?.id ?? null
}

function PaneFrame(props: { pane: LivePane }) {
  const focused = () => store.focusedPaneId() === props.pane.pane_id
  return (
    <div
      class={`flex h-full min-h-0 min-w-0 flex-1 flex-col bg-[var(--panel)] ${focused() ? 'ring-1 ring-inset ring-[var(--accent)]' : ''}`}
      onMouseDown={() => store.focusPane(props.pane)}
    >
      <Show when={props.pane.kind === 'terminal'}>
        <header class="hidden h-10 shrink-0 items-center gap-2 border-b border-[var(--border-muted)] px-3 lg:flex">
          <Icon name="terminal" class="h-4 w-4 text-[var(--text-muted)]" />
          <div class="min-w-0 flex-1 truncate text-[14px] font-medium">{store.paneTitle(props.pane)}</div>
          <Show when={props.pane.running}>
            <span class="text-[11px] tracking-wide text-[var(--accent)]">Live</span>
          </Show>
          <ZoomButton pane={props.pane} />
        </header>
      </Show>
      <Show when={props.pane.kind === 'chat'}>
        <ChatPane pane={props.pane} />
      </Show>
      <Show when={props.pane.kind === 'terminal'}>
        <TerminalView
          workspaceId={props.pane.workspace_id}
          paneId={props.pane.pane_id}
          sessionId={props.pane.session_id}
        />
      </Show>
      <Show when={props.pane.kind === 'browser'}>
        <div class="grid flex-1 place-items-center px-6 text-center text-[13px] text-[var(--text-subtle)]">
          Browser panes stay on the desktop runtime.
        </div>
      </Show>
    </div>
  )
}

function EmptyWorkspace() {
  return (
    <div class="grid min-w-full flex-1 place-items-center text-[var(--text-subtle)]">
      <div class="max-w-sm px-6 text-center">
        <div class="wordmark text-[28px] text-[var(--text)]">No open panes</div>
        <p class="mt-2 text-[14px]">Start a chat or a daemon terminal from this client.</p>
        <button
          type="button"
          class="mt-4 inline-flex items-center gap-2 rounded-[7px] bg-[var(--accent-row)] px-3 py-1.5 text-[13px] text-[var(--text)]"
          onClick={() => void store.runCommand('new-thread')}
        >
          <Icon name="chat" />
          New chat
        </button>
      </div>
    </div>
  )
}

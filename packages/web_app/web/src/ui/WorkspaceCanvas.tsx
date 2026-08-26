import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from 'solid-js'

import { store } from '../lib/store'
import type { LayoutNode, LivePane, WorkspacePaneGroup } from '../lib/types'
import { effectivePanesPerView } from '../lib/ui_config'
import { ChatPane } from './ChatPane'
import { Icon, ZoomButton } from './Icons'
import { PaneActionsButton } from './Sidebar'
import { TerminalView } from './Terminals'

export function WorkspaceCanvas() {
  let scroller: HTMLDivElement | undefined
  let ignore_scroll = false
  let scroll_timer = 0
  let focus_timer = 0
  let last_focused_id: number | null = null

  // Zoom renders only the maximized pane; the single column then naturally
  // fills the strip and other panes remount from daemon state on unzoom.
  const groups = (): WorkspacePaneGroup[] => {
    const zoomed_id = store.maximizedPaneId()
    if (zoomed_id != null) {
      const zoomed = store.openPanes().find((pane) => pane.pane_id === zoomed_id)
      if (zoomed) return [{ key: `zoom:${zoomed_id}`, panes: [zoomed], layout: { leaf: zoomed_id } }]
    }
    return store.paneGroups()
  }

  const pane_order = createMemo(() => groups().flatMap((group) => group.panes.map((pane) => pane.pane_id)).join(','))

  createEffect(() => {
    pane_order()
    const id = store.focusedPaneId()
    const root = scroller
    if (!root || id == null) return
    const leaf = root.querySelector(`[data-pane-id="${id}"]`)
    if (!(leaf instanceof HTMLElement)) return
    const column = leaf.closest('.niri-column')
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
    effectivePanesPerView(store.uiConfig(), groups().length, store.maximizedPaneId() != null)
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
      <For each={groups()} fallback={<EmptyWorkspace />}>
        {(group) => (
          <div
            class="niri-column"
            data-scroll-group={group.key}
            data-representative-pane-id={String(group.panes[0]?.pane_id ?? '')}
          >
            <PaneGroupNode
              node={group.layout}
              panes={group.panes}
              bordered={groups().length > 1 || group.panes.length > 1}
            />
          </div>
        )}
      </For>
    </div>
  )
}

function nearestPaneId(root: HTMLDivElement): number | null {
  const mid = root.scrollLeft + root.clientWidth / 2
  let best: { id: number; dist: number } | null = null
  for (const node of root.querySelectorAll('[data-scroll-group]')) {
    if (!(node instanceof HTMLElement)) continue
    const center = node.offsetLeft + node.offsetWidth / 2
    const dist = Math.abs(center - mid)
    const id = Number(node.dataset.representativePaneId)
    if (!Number.isFinite(id)) continue
    if (!best || dist < best.dist) best = { id, dist }
  }
  return best?.id ?? null
}

function firstLayoutLeaf(node: LayoutNode): number {
  return 'leaf' in node ? node.leaf : firstLayoutLeaf(node.split.first)
}

function PaneGroupNode(props: { node: LayoutNode; panes: LivePane[]; bordered: boolean }) {
  if ('leaf' in props.node) {
    const leaf_id = props.node.leaf
    const pane = props.panes.find((item) => item.pane_id === leaf_id)
    return (
      <Show when={pane} keyed>
        {(item) => (
          <div
            class={`min-h-0 min-w-0 flex-1 overflow-hidden ${props.bordered ? 'pane-tile' : ''}`}
            data-pane-id={String(item.pane_id)}
          >
            <PaneFrame pane={item} />
          </div>
        )}
      </Show>
    )
  }
  const split = props.node.split
  const [ratio, setRatio] = createSignal(Math.min(0.78, Math.max(0.22, split.ratio)))
  return (
    <div class={`pane-split flex min-h-0 min-w-0 flex-1 ${split.axis === 'vertical' ? 'flex-row' : 'flex-col'}`}>
      <div class="flex min-h-0 min-w-0 overflow-hidden" style={{ flex: `${ratio()} 1 0%` }}>
        <PaneGroupNode node={split.first} panes={props.panes} bordered={props.bordered} />
      </div>
      <SplitGutter
        axis={split.axis}
        ratio={ratio()}
        onRatio={setRatio}
        onCommit={(next_ratio) => void store.resizePaneSplit(
          firstLayoutLeaf(split.first),
          firstLayoutLeaf(split.second),
          split.axis,
          next_ratio,
        )}
      />
      <div class="flex min-h-0 min-w-0 overflow-hidden" style={{ flex: `${1 - ratio()} 1 0%` }}>
        <PaneGroupNode node={split.second} panes={props.panes} bordered={props.bordered} />
      </div>
    </div>
  )
}

function SplitGutter(props: {
  axis: 'vertical' | 'horizontal'
  ratio: number
  onRatio: (ratio: number) => void
  onCommit: (ratio: number) => void
}) {
  let gutter!: HTMLButtonElement
  const onPointerDown = (event: PointerEvent) => {
    if (event.button !== 0) return
    event.preventDefault()
    const container = gutter.parentElement
    if (!container) return
    gutter.setPointerCapture(event.pointerId)
    const initial_ratio = props.ratio
    let dragged_ratio = initial_ratio
    const update = (pointer: PointerEvent) => {
      const rect = container.getBoundingClientRect()
      const gutter_extent = props.axis === 'vertical' ? gutter.offsetWidth : gutter.offsetHeight
      const full_extent = props.axis === 'vertical' ? rect.width : rect.height
      const pointer_offset = props.axis === 'vertical' ? pointer.clientX - rect.left : pointer.clientY - rect.top
      const raw = (pointer_offset - gutter_extent / 2) / Math.max(full_extent - gutter_extent, 1)
      dragged_ratio = Math.min(0.78, Math.max(0.22, raw))
      props.onRatio(dragged_ratio)
    }
    const cleanup = (pointer: PointerEvent) => {
      if (gutter.hasPointerCapture(pointer.pointerId)) gutter.releasePointerCapture(pointer.pointerId)
      gutter.removeEventListener('pointermove', update)
      gutter.removeEventListener('pointerup', finish)
      gutter.removeEventListener('pointercancel', cancel)
    }
    const finish = (pointer: PointerEvent) => {
      update(pointer)
      cleanup(pointer)
      props.onCommit(dragged_ratio)
    }
    const cancel = (pointer: PointerEvent) => {
      cleanup(pointer)
      props.onRatio(initial_ratio)
    }
    gutter.addEventListener('pointermove', update)
    gutter.addEventListener('pointerup', finish)
    gutter.addEventListener('pointercancel', cancel)
  }
  return (
    <button
      ref={gutter}
      type="button"
      class={`pane-split-gutter ${props.axis === 'vertical' ? 'pane-split-gutter-vertical' : 'pane-split-gutter-horizontal'}`}
      aria-label={`Resize ${props.axis} pane split`}
      onPointerDown={onPointerDown}
    />
  )
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
          <PaneActionsButton pane={props.pane} />
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

/**
 * Right side panel (desktop side_panel.zig parity, minus Browser/Agents):
 * Changes and Files for the selected workspace. Docked beside the canvas at
 * lg+, a right-edge sheet below that.
 */
import { For, Show, createEffect, createSignal, onCleanup, onMount } from 'solid-js'

import { type SidePanelView, clampPanelWidth, sidePanel } from '../lib/side_panel'
import { store } from '../lib/store'
import { ChangesView } from './ChangesView'
import { Icon } from './Icons'
import { FilesView } from './WorkspaceFiles'

const VIEWS: Array<{ view: SidePanelView; label: string; icon: string }> = [
  { view: 'changes', label: 'Changes', icon: 'git' },
  { view: 'files', label: 'Files', icon: 'files' },
]

function PanelBody(props: { sheet?: boolean; onClose: () => void }) {
  const workspaceId = () => store.workspace()?.workspace_id ?? null
  return (
    <div class="flex h-full min-h-0 flex-col bg-[var(--panel)]">
      <div class="flex h-10 shrink-0 items-center gap-1 border-b border-[var(--border-muted)] px-2">
        <div role="tablist" aria-label="Side panel" class="flex min-w-0 flex-1 gap-0.5">
          <For each={VIEWS}>
            {(item) => (
              <button
                type="button"
                role="tab"
                aria-selected={sidePanel.view() === item.view}
                class={`flex h-7 items-center gap-1.5 rounded-[6px] px-2.5 text-[12.5px] ${
                  sidePanel.view() === item.view ? 'bg-[var(--accent-wash)] text-[var(--text)]' : 'text-[var(--text-muted)] hover:text-[var(--text)]'
                }`}
                onClick={() => sidePanel.setView(item.view)}
              >
                <Icon name={item.icon} class="h-3.5 w-3.5" />
                {item.label}
              </button>
            )}
          </For>
        </div>
        <button
          type="button"
          class="grid h-8 w-8 shrink-0 place-items-center rounded-[6px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
          aria-label="Close side panel"
          onClick={() => props.onClose()}
        >
          <Icon name="close" class="h-4 w-4" />
        </button>
      </div>
      <div class="min-h-0 flex-1">
        <Show when={workspaceId()} keyed fallback={<p class="px-4 py-6 text-[13px] text-[var(--text-muted)]">Select a workspace.</p>}>
          {(id) => (
            <Show when={sidePanel.view() === 'changes'} fallback={<FilesView workspaceId={id} />}>
              <ChangesView workspaceId={id} narrow={props.sheet} />
            </Show>
          )}
        </Show>
      </div>
    </div>
  )
}

/// Docked panel (lg+). The left edge drags to resize.
export function SidePanelDock() {
  const [viewport, setViewport] = createSignal(typeof window === 'undefined' ? 1440 : window.innerWidth)
  onMount(() => {
    const onResize = () => setViewport(window.innerWidth)
    window.addEventListener('resize', onResize)
    onCleanup(() => window.removeEventListener('resize', onResize))
  })
  const width = () => clampPanelWidth(sidePanel.width(), viewport())

  const startResize = (event: PointerEvent) => {
    event.preventDefault()
    const start_x = event.clientX
    const start_w = width()
    const target = event.currentTarget as HTMLElement
    target.setPointerCapture(event.pointerId)
    const move = (next: PointerEvent) => sidePanel.setWidth(clampPanelWidth(start_w + (start_x - next.clientX), window.innerWidth))
    const up = () => { target.removeEventListener('pointermove', move); target.removeEventListener('pointerup', up) }
    target.addEventListener('pointermove', move)
    target.addEventListener('pointerup', up)
  }

  return (
    <Show when={sidePanel.open()}>
      <aside class="relative hidden h-full shrink-0 border-l border-[var(--border-muted)] lg:block" style={{ width: `${width()}px` }} aria-label="Side panel">
        <div
          class="side-panel-grip"
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize side panel"
          onPointerDown={startResize}
          onDblClick={() => sidePanel.setWidth(clampPanelWidth(440, viewport()))}
        />
        <PanelBody onClose={() => sidePanel.setOpen(false)} />
      </aside>
    </Show>
  )
}

/// Sheet (below lg), kept mounted through its slide-out like the left drawer.
export function SidePanelSheet() {
  const EXIT_MS = 200
  const [mounted, setMounted] = createSignal(false)
  let timer: ReturnType<typeof setTimeout> | undefined
  createEffect(() => {
    clearTimeout(timer)
    if (sidePanel.sheetOpen()) setMounted(true)
    else timer = setTimeout(() => setMounted(false), EXIT_MS)
  })
  onCleanup(() => clearTimeout(timer))
  // Growing past lg hands over to the dock.
  onMount(() => {
    const query = window.matchMedia('(min-width: 1024px)')
    const onChange = (event: MediaQueryListEvent) => { if (event.matches && sidePanel.sheetOpen()) { sidePanel.setSheetOpen(false); sidePanel.setOpen(true) } }
    query.addEventListener('change', onChange)
    onCleanup(() => query.removeEventListener('change', onChange))
  })
  return (
    <Show when={mounted()}>
      <div class={`absolute inset-0 z-30 lg:hidden ${sidePanel.sheetOpen() ? 'drawer-open' : 'drawer-closing'}`}>
        <button type="button" class="drawer-backdrop absolute inset-0 bg-black/50" aria-label="Close side panel" onClick={() => sidePanel.setSheetOpen(false)} />
        <div class="side-sheet-panel absolute inset-y-0 right-0 w-[min(440px,94vw)] pt-[var(--safe-top)] pb-[var(--safe-bottom)] shadow-[-8px_0_40px_rgba(0,0,0,0.45)]">
          <PanelBody sheet onClose={() => sidePanel.setSheetOpen(false)} />
        </div>
      </div>
    </Show>
  )
}

/// Pane-header toggle (desktop puts it beside the pane menu).
export function SidePanelToggle() {
  return (
    <button
      type="button"
      class={`grid h-7 w-7 shrink-0 place-items-center rounded-[6px] hover:bg-[var(--accent-hover)] hover:text-[var(--text)] ${sidePanel.open() ? 'text-[var(--accent)]' : 'text-[var(--text-subtle)]'}`}
      aria-label={sidePanel.open() ? 'Hide side panel' : 'Show changes and files'}
      aria-pressed={sidePanel.open()}
      title="Changes and files"
      onMouseDown={(event) => event.stopPropagation()}
      onClick={() => sidePanel.setOpen(!sidePanel.open())}
    >
      <Icon name="git" class="h-4 w-4" />
    </button>
  )
}

/// Mobile header button that opens the sheet.
export function SidePanelSheetButton() {
  return (
    <button
      type="button"
      class="grid h-10 w-10 shrink-0 place-items-center text-[var(--text-subtle)]"
      aria-label="Changes and files"
      onClick={() => sidePanel.showSheet(sidePanel.view())}
    >
      <Icon name="git" />
    </button>
  )
}

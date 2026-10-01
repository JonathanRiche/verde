import { For, Show, createEffect, createSignal, onCleanup } from 'solid-js'
import { Portal } from 'solid-js/web'

import { summaryChip, type GitAction } from '../lib/git_changes'
import { store } from '../lib/store'
import type { LivePane } from '../lib/types'

const git = store.gitChanges

/// Chat header split button `[↑ Commit & push 4 | ▾]`. The label follows repo
/// state (see gitActionState); hidden when there is nothing to commit or push.
export function GitChangesChip(props: { pane: LivePane }) {
  const [menu, setMenu] = createSignal<{ x: number; y: number } | null>(null)
  let caret: HTMLButtonElement | undefined
  const state = () => git.actionState(props.pane)
  const busy = () => git.actionRunning(props.pane)
  const pushy = () => state().primary === 'push' || state().primary === 'commit_and_push'
  const openMenu = () => {
    const rect = caret?.getBoundingClientRect()
    if (rect) setMenu({ x: rect.right, y: rect.bottom + 6 })
  }
  const closeMenu = () => { setMenu(null); queueMicrotask(() => caret?.focus()) }
  const choose = (action: GitAction) => { setMenu(null); git.runAction(props.pane, action, 'menu') }
  const segment = 'flex h-7 items-center hover:bg-[var(--accent-hover)] disabled:cursor-wait disabled:opacity-60'

  return (
    <Show when={state().visible}>
      <div
        class={`mono flex shrink-0 items-stretch overflow-hidden rounded-[7px] border text-[11.5px] whitespace-nowrap ${
          state().attention
            ? 'border-[color-mix(in_srgb,var(--warning)_55%,var(--border-muted))]'
            : 'border-[var(--border-muted)]'
        }`}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <button
          type="button"
          class={`${segment} gap-1.5 pr-2 pl-2.5 text-[var(--text)]`}
          aria-label={`${state().label}: ${state().title}`}
          title={state().title}
          disabled={busy()}
          onClick={() => { const action = state().primary; if (action) git.runAction(props.pane, action, 'primary') }}
        >
          <Show when={state().primary !== 'push'}>
            <span aria-hidden="true" class={pushy() ? 'text-[var(--accent)]' : 'text-[var(--text-muted)]'}>{pushy() ? '↑' : '●'}</span>
          </Show>
          <span class={state().primary === 'push' ? '' : 'max-md:hidden'}>{state().label}</span>
          <Show when={state().count > 0}>
            <span
              class={`grid h-[17px] min-w-[17px] place-items-center rounded-full px-1 text-[10.5px] font-bold ${
                state().attention
                  ? 'bg-[color-mix(in_srgb,var(--warning)_22%,transparent)] text-[var(--warning)]'
                  : 'bg-[var(--accent-wash)] text-[var(--text-muted)]'
              }`}
              aria-hidden="true"
            >{state().count}</span>
          </Show>
        </button>
        <button
          ref={(node) => { caret = node }}
          type="button"
          class={`${segment} border-l border-[var(--border-muted)] px-1.5 text-[var(--text-muted)]`}
          aria-label="More git actions"
          aria-haspopup="menu"
          aria-expanded={menu() !== null}
          disabled={busy()}
          onClick={(event) => { event.stopPropagation(); if (menu()) closeMenu(); else openMenu() }}
        >▾</button>
      </div>
      <Show when={menu()} keyed>
        {(anchor) => <GitActionsMenu pane={props.pane} anchor={anchor} onClose={closeMenu} onChoose={choose} />}
      </Show>
    </Show>
  )
}

function GitActionsMenu(props: { pane: LivePane; anchor: { x: number; y: number }; onClose: () => void; onChoose: (action: GitAction) => void }) {
  let panel: HTMLDivElement | undefined
  const width = 208
  const style = () => ({
    left: `${Math.max(8, Math.min(props.anchor.x - width, window.innerWidth - width - 8))}px`,
    top: `${Math.max(8, Math.min(props.anchor.y, window.innerHeight - 200))}px`,
    width: `${width}px`,
  })
  const buttons = () => [...(panel?.querySelectorAll<HTMLButtonElement>('button[role="menuitem"]:not(:disabled)') ?? [])]
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); props.onClose(); return }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    event.preventDefault()
    const items = buttons()
    if (items.length === 0) return
    const current = items.indexOf(document.activeElement as HTMLButtonElement)
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1
      : event.key === 'ArrowDown' ? (current + 1 + items.length) % items.length : (current - 1 + items.length) % items.length
    items[next]?.focus()
  }
  createEffect(() => {
    queueMicrotask(() => buttons()[0]?.focus())
    const onResize = () => props.onClose()
    window.addEventListener('resize', onResize)
    onCleanup(() => window.removeEventListener('resize', onResize))
  })
  return (
    <Portal>
      <div class="fixed inset-0 z-50" onPointerDown={() => props.onClose()}>
        <div
          ref={(node) => { panel = node }}
          class="anim-menu fixed rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel-alt)] p-1.5 shadow-[0_18px_55px_rgba(0,0,0,0.5)] outline-none"
          style={style()}
          role="menu"
          aria-label="Git actions"
          tabIndex={-1}
          onKeyDown={onKeyDown}
          onPointerDown={(event) => event.stopPropagation()}
        >
          <For each={git.actionState(props.pane).menu}>
            {(item) => (
              <button
                type="button"
                role="menuitem"
                class="flex h-8 w-full items-center rounded-[7px] px-2.5 text-left text-[13px] text-[var(--text)] hover:bg-[var(--accent-hover)] focus:bg-[var(--accent-hover)] focus:outline-none disabled:cursor-not-allowed disabled:opacity-40"
                disabled={item.disabled}
                onClick={() => props.onChoose(item.action)}
              >{item.label}</button>
            )}
          </For>
        </div>
      </div>
    </Portal>
  )
}

/// Sidebar chat-row marker for pending changes (amber when attention).
export function GitChangesDot(props: { pane: LivePane }) {
  const chip = () => summaryChip(props.pane.kind === 'chat' ? store.gitChanges.summaryForThread(props.pane.thread_id) : null)
  return (
    <Show when={chip().visible}>
      <span
        class={`h-[6px] w-[6px] shrink-0 rounded-full ${chip().attention ? 'bg-[var(--warning)]' : 'bg-[var(--text-subtle)]'}`}
        role="img"
        aria-label={chip().attention ? 'Uncommitted changes need attention' : 'Uncommitted changes'}
        title={chip().text.slice(2)}
      />
    </Show>
  )
}

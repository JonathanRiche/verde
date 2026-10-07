import { Show, createSignal, onCleanup, onMount } from 'solid-js'
import { Portal } from 'solid-js/web'

import { store } from '../lib/store'
import type { LivePane } from '../lib/types'
import { ChatRouting } from './ChatRouting'
import { Icon, WorkspaceGlyph } from './Icons'

/// Workspace + connection under the prompt box, mirroring the desktop
/// composer's directory pill (left) and connection pill (right). Full-size
/// layouts always show both, read-only once the conversation has started;
/// compact (phone) layouts show one combined chip only on new chats, so the
/// prompt area stays clean once work begins (the pane "…" menu keeps the
/// full controls). Both open the shared ChatRouting controls.
export function ComposerRouting(props: { pane: LivePane }) {
  const [open, setOpen] = createSignal<{ anchor: DOMRect; align: 'left' | 'right' } | null>(null)
  onMount(() => { void store.refreshConnections() })

  const workspace = () => {
    const id = store.owningWorkspaceId(props.pane)
    return store.workspaces().find((row) => row.workspace_id === id) ?? null
  }
  const connectionLabel = () => {
    const id = store.connectionFor(props.pane)
    if (!id || id === 'local') return 'Local'
    return store.connections()?.connections.find((row) => row.profile_id === id)?.label ?? 'Unavailable'
  }
  /// Same rule ChatRouting uses for the connection select.
  const started = () => store.paneWorking(props.pane) || Boolean(props.pane.committed) || Boolean(props.pane.provider_thread_id)
  const show = (event: MouseEvent, align: 'left' | 'right') => {
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect()
    setOpen((current) => (current ? null : { anchor: rect, align }))
  }
  const pill = 'flex h-8 min-w-0 max-w-[50%] items-center gap-2 rounded-[8px] px-2 text-[12.5px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-white'

  return (
    <>
      <Show
        when={!store.compact()}
        fallback={(
          <Show when={!started()}>
            <div class="mx-auto mt-2 flex w-full max-w-[900px]">
              <button
                type="button"
                class="flex h-9 min-w-0 max-w-full items-center gap-2 rounded-full border border-[var(--panel-muted)] bg-[var(--panel)] px-3 text-[13px] text-[var(--text-muted)] active:bg-[var(--accent-hover)]"
                aria-label={`Chat routing: ${workspace()?.label ?? 'Workspace'}, ${connectionLabel()}`}
                aria-haspopup="dialog"
                onClick={(event) => show(event, 'left')}
              >
                <Show when={workspace()}>
                  {(row) => <WorkspaceGlyph workspace={row()} class="h-[18px] w-[18px]" iconClass="h-3 w-3" />}
                </Show>
                <span class="min-w-0 truncate">{workspace()?.label ?? 'Workspace'}</span>
                <span class="shrink-0 text-[var(--text-subtle)]">·</span>
                <span class="min-w-0 truncate">{connectionLabel()}</span>
                <Icon name="chevronDown" class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)]" />
              </button>
            </div>
          </Show>
        )}
      >
        <div class="mx-auto mt-2 flex w-full max-w-[900px] items-center justify-between gap-2">
          <button
            type="button"
            class={pill}
            title={started() ? 'Workspace (start a new chat to change it)' : 'Chat workspace'}
            aria-haspopup="dialog"
            onClick={(event) => show(event, 'left')}
          >
            <Show when={workspace()}>
              {(row) => <WorkspaceGlyph workspace={row()} class="h-[18px] w-[18px]" iconClass="h-3 w-3" />}
            </Show>
            <span class="min-w-0 truncate">{workspace()?.label ?? 'Workspace'}</span>
            <Icon name={started() ? 'lock' : 'chevronDown'} class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)]" />
          </button>
          <button
            type="button"
            class={pill}
            title={started() ? 'This conversation keeps its original connection' : 'Chat connection'}
            aria-haspopup="dialog"
            onClick={(event) => show(event, 'right')}
          >
            <Icon name="monitor" class="h-4 w-4 shrink-0" />
            <span class="min-w-0 truncate">{connectionLabel()}</span>
            <Icon name={started() ? 'lock' : 'chevronDown'} class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)]" />
          </button>
        </div>
      </Show>
      <Show when={open()} keyed>
        {(target) => <RoutingPopover pane={props.pane} anchor={target.anchor} align={target.align} onClose={() => setOpen(null)} />}
      </Show>
    </>
  )
}

/// Popover above the trigger on full-size layouts; bottom sheet on phones.
function RoutingPopover(props: { pane: LivePane; anchor: DOMRect; align: 'left' | 'right'; onClose: () => void }) {
  const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') props.onClose() }
  window.addEventListener('keydown', onKey)
  onCleanup(() => window.removeEventListener('keydown', onKey))
  const width = Math.min(320, window.innerWidth - 16)
  const left = props.align === 'left'
    ? Math.max(8, Math.min(props.anchor.left, window.innerWidth - width - 8))
    : Math.max(8, Math.min(props.anchor.right - width, window.innerWidth - width - 8))
  return (
    <Portal>
      <div class="anim-fade fixed inset-0 z-50">
        <button type="button" class="absolute inset-0 cursor-default bg-black/30 lg:bg-transparent" aria-label="Close chat routing" onPointerDown={props.onClose} />
        <Show
          when={!store.compact()}
          fallback={(
            <div role="dialog" aria-label="Chat routing" class="anim-menu absolute inset-x-0 bottom-0 rounded-t-[16px] border-t border-[var(--panel-muted)] bg-[var(--panel-alt)] px-3 pt-3 pb-[max(16px,var(--safe-bottom))]">
              <ChatRouting pane={props.pane} onClose={props.onClose} />
            </div>
          )}
        >
          <div
            role="dialog"
            aria-label="Chat routing"
            class="anim-menu absolute rounded-[10px] border border-[var(--panel-muted)] bg-[var(--panel-alt)] p-2 shadow-[0_18px_55px_rgba(0,0,0,0.5)]"
            style={{ left: `${left}px`, bottom: `${window.innerHeight - props.anchor.top + 6}px`, width: `${width}px` }}
          >
            <ChatRouting pane={props.pane} onClose={props.onClose} />
          </div>
        </Show>
      </div>
    </Portal>
  )
}

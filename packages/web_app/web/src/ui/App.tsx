import { Show, createEffect, createSignal, onCleanup, onMount } from 'solid-js'

import { store } from '../lib/store'
import { applyReducedMotion } from '../lib/ui_config'
import { isSubagentThreadId } from '../lib/types'
import { FileViewer, fileViewerOpen } from './FileViewer'
import { History, historyOpen } from './History'
import { Icon } from './Icons'
import { Palette, Settings, WorkspaceDialog } from './Overlays'
import { ActionDialog } from './ActionDialog'
import { PrefixBar } from './PrefixBar'
import { PaneActionsButton, Sidebar } from './Sidebar'
import { WorkspaceCanvas } from './WorkspaceCanvas'

export function App() {
  onMount(() => {
    store.start()
    const onKey = (event: KeyboardEvent) => store.handleKey(event)
    window.addEventListener('keydown', onKey)
    onCleanup(() => window.removeEventListener('keydown', onKey))
  })

  // verde.json is the source of truth for motion, per area like the desktop.
  createEffect(() => applyReducedMotion(store.uiConfig().reduced_motion_parts))

  // Keep the drawer mounted for its slide-out so closing animates too.
  const DRAWER_EXIT_MS = 200
  const [drawerMounted, setDrawerMounted] = createSignal(false)
  let drawerExitTimer: ReturnType<typeof setTimeout> | undefined
  createEffect(() => {
    clearTimeout(drawerExitTimer)
    if (store.drawerOpen()) setDrawerMounted(true)
    else drawerExitTimer = setTimeout(() => setDrawerMounted(false), DRAWER_EXIT_MS)
  })
  onCleanup(() => clearTimeout(drawerExitTimer))

  const railWidth = () => (store.sidebarCollapsed() ? 'var(--sidebar-collapsed)' : 'var(--sidebar-w)')
  const focused = () => store.focusedPane()

  return (
    <div class="flex h-full min-h-0 bg-[var(--chat-black)]">
      <div class="sidebar-rail hidden shrink-0 lg:block" style={{ width: railWidth() }}>
        <Sidebar />
      </div>

      <Show when={drawerMounted()}>
        {/* absolute, not fixed: iOS standalone clips fixed boxes to its short
            layout viewport (see styles.css), and #app already fills the screen. */}
        <div class={`absolute inset-0 z-30 lg:hidden ${store.drawerOpen() ? 'drawer-open' : 'drawer-closing'}`}>
          <button
            type="button"
            class="drawer-backdrop absolute inset-0 bg-black/50"
            aria-label="Close workspace drawer"
            onClick={() => store.setDrawerOpen(false)}
          />
          <div class="drawer-panel absolute inset-y-0 left-0 w-[min(380px,92vw)] bg-[var(--panel)] pt-[var(--safe-top)] shadow-[8px_0_40px_rgba(0,0,0,0.45)]">
            <Sidebar drawer />
          </div>
        </div>
      </Show>

      <div class="relative flex min-w-0 flex-1 flex-col overflow-hidden">
        <div class="flex h-[calc(2.75rem+var(--safe-top))] shrink-0 items-center gap-2 border-b border-[var(--border-muted)] bg-[var(--panel)] px-2 pt-[var(--safe-top)] lg:hidden">
          <button
            type="button"
            class="grid h-10 w-10 place-items-center text-[var(--text-subtle)]"
            onClick={() => store.setDrawerOpen(true)}
            aria-label="Open workspaces"
          >
            <Icon name="menu" />
          </button>
          <div class="min-w-0 flex-1 truncate text-[14px] font-medium">
            {focused() ? store.paneTitle(focused()!) : (store.workspace()?.label ?? 'Verde')}
          </div>
          <Show
            when={(focused()?.kind === 'chat' || focused()?.kind === 'terminal') ? focused() : undefined}
            keyed
          >
            {(pane) => <PaneActionsButton pane={pane} mobile />}
          </Show>
        </div>

        <WorkspaceCanvas />
        <PrefixBar />
      </div>

      <Palette />
      <Settings />
      <WorkspaceDialog />
      <ActionDialog />
      <History />
      <FileViewer />
      <NoticeToast />
    </div>
  )
}

const NOTICE_TOAST_MS = 4000

/// Global home for store.notice. The focused chat composer renders the notice
/// inline, so the toast only covers what that misses: a terminal or empty
/// workspace in focus, a sub-agent pane, or an overlay covering the composer.
function NoticeToast() {
  const overlayOpen = () =>
    store.paletteOpen() || store.settingsOpen() || store.workspaceDialogOpen() || historyOpen() || fileViewerOpen()
  const composerShows = () => {
    const pane = store.focusedPane()
    return pane?.kind === 'chat' && !isSubagentThreadId(pane.thread_id)
  }
  const [dismissed, setDismissed] = createSignal<string | null>(null)
  const text = () => {
    const notice = store.notice()
    if (!notice || notice === dismissed()) return null
    return overlayOpen() || !composerShows() ? notice : null
  }
  createEffect(() => {
    const notice = store.notice()
    if (!notice) return setDismissed(null)
    // Hides only the toast: the composer keeps its own copy until the store
    // clears it.
    const timer = setTimeout(() => setDismissed(notice), NOTICE_TOAST_MS)
    onCleanup(() => clearTimeout(timer))
  })
  return (
    // absolute, not fixed: see the drawer note above. The live region stays
    // mounted so the text change is announced.
    <div
      role="status"
      aria-live="polite"
      class="pointer-events-none absolute inset-x-0 bottom-[calc(16px+var(--safe-bottom))] z-50 flex justify-center px-3"
    >
      <Show when={text()} keyed>
        {(notice) => (
          <button
            type="button"
            class="anim-reveal pointer-events-auto w-full max-w-[28rem] rounded-[10px] border border-[color-mix(in_srgb,var(--warning)_55%,var(--border-muted))] bg-[var(--panel)] px-3.5 py-2.5 text-left text-[13px] text-[var(--text)] shadow-lg"
            aria-label={`${notice} (dismiss)`}
            onClick={() => setDismissed(notice)}
          >
            {notice}
          </button>
        )}
      </Show>
    </div>
  )
}

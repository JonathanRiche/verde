import { Show, onCleanup, onMount } from 'solid-js'

import { store } from '../lib/store'
import { Icon } from './Icons'
import { Palette, Settings } from './Overlays'
import { Sidebar } from './Sidebar'
import { WorkspaceCanvas } from './WorkspaceCanvas'

export function App() {
  onMount(() => {
    store.start()
    const onKey = (event: KeyboardEvent) => store.handleKey(event)
    window.addEventListener('keydown', onKey)
    onCleanup(() => window.removeEventListener('keydown', onKey))
  })

  const railWidth = () => (store.sidebarCollapsed() ? 'var(--sidebar-collapsed)' : 'var(--sidebar-w)')
  const focused = () => store.focusedPane()

  return (
    <div class="flex h-full min-h-0 bg-[var(--chat-black)]">
      <div class="hidden shrink-0 lg:block" style={{ width: railWidth() }}>
        <Sidebar />
      </div>

      <Show when={store.drawerOpen()}>
        <div class="fixed inset-0 z-30 lg:hidden">
          <button
            type="button"
            class="absolute inset-0 bg-black/50"
            aria-label="Close workspace drawer"
            onClick={() => store.setDrawerOpen(false)}
          />
          <div class="absolute inset-y-0 left-0 w-[min(300px,88vw)] bg-[var(--panel)] shadow-[8px_0_40px_rgba(0,0,0,0.45)]">
            <Sidebar />
          </div>
        </div>
      </Show>

      <div class="flex min-w-0 flex-1 flex-col overflow-hidden">
        <div class="flex h-11 shrink-0 items-center gap-2 border-b border-[var(--border-muted)] bg-[var(--panel)] px-2 lg:hidden">
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
        </div>

        <WorkspaceCanvas />
      </div>

      <Palette />
      <Settings />
    </div>
  )
}

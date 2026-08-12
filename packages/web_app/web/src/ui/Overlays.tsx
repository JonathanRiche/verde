import { For, Show, createMemo, createResource, createSignal } from 'solid-js'

import { store } from '../lib/store'
import { loadTheme } from '../lib/theme'

const COMMANDS = [
  { id: 'new-thread', title: 'New chat thread', hint: 'Ctrl+T' },
  { id: 'new-terminal', title: 'New terminal split', hint: 'Ctrl+Alt+T' },
  { id: 'toggle-sidebar', title: 'Toggle sidebar', hint: 'Ctrl+S' },
  { id: 'maximize', title: 'Maximize pane', hint: 'Alt+Z' },
  { id: 'settings', title: 'Open settings', hint: 'Ctrl+,' },
]

export function Palette() {
  const [query, setQuery] = createSignal('')
  const results = createMemo(() => {
    const needle = query().trim().toLowerCase()
    const panes = store.openPanes().map((pane) => ({
      id: `pane:${pane.workspace_id}:${pane.pane_id}`,
      title: store.paneTitle(pane),
      hint: pane.kind,
    }))
    const actives = store.activePanes().map((pane) => ({
      id: `pane:${pane.workspace_id}:${pane.pane_id}`,
      title: store.paneTitle(pane),
      hint: 'active',
    }))
    const workspaces = store.workspaces().map((workspace) => ({
      id: `workspace:${workspace.workspace_id}`,
      title: workspace.label,
      hint: 'workspace',
    }))
    const seen = new Set<string>()
    return [...COMMANDS, ...actives, ...panes, ...workspaces].filter((item) => {
      if (seen.has(item.id)) return false
      seen.add(item.id)
      return item.title.toLowerCase().includes(needle)
    })
  })

  const run = (id: string) => {
    if (id.startsWith('pane:')) {
      const [, workspaceId, paneId] = id.split(':')
      const pane = [...store.openPanes(), ...store.activePanes()].find(
        (item) => item.workspace_id === workspaceId && item.pane_id === Number(paneId),
      )
      if (pane) store.focusPane(pane)
      store.setPaletteOpen(false)
      return
    }
    if (id.startsWith('workspace:')) {
      store.selectWorkspace(id.slice('workspace:'.length))
      store.setPaletteOpen(false)
      return
    }
    void store.runCommand(id)
  }

  return (
    <Show when={store.paletteOpen()}>
      <div class="fixed inset-0 z-40 bg-black/55" onClick={() => store.setPaletteOpen(false)}>
        <div
          class="mx-auto mt-[12vh] max-w-[560px] overflow-hidden rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
          onClick={(event) => event.stopPropagation()}
        >
          <input
            class="w-full border-b border-[var(--border-muted)] bg-transparent px-4 py-3 text-[15px] outline-none placeholder:text-[var(--text-subtle)]"
            placeholder="Jump to a pane, workspace, or command"
            autofocus
            value={query()}
            onInput={(event) => setQuery(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === 'Escape') store.setPaletteOpen(false)
              if (event.key === 'Enter' && results()[0]) run(results()[0].id)
            }}
          />
          <ul class="max-h-[50vh] overflow-y-auto p-1.5 scrollbar-thin">
            <For each={results()} fallback={<li class="px-3 py-4 text-sm text-[var(--text-subtle)]">Nothing matches.</li>}>
              {(item) => (
                <li>
                  <button
                    type="button"
                    class="flex w-full items-center justify-between rounded-[7px] px-3 py-2 text-left text-[14px] hover:bg-[var(--accent-hover)]"
                    onClick={() => run(item.id)}
                  >
                    <span>{item.title}</span>
                    <span class="mono text-[10px] text-[var(--text-subtle)]">{item.hint}</span>
                  </button>
                </li>
              )}
            </For>
          </ul>
        </div>
      </div>
    </Show>
  )
}

export function Settings() {
  const [theme] = createResource(loadTheme)
  return (
    <Show when={store.settingsOpen()}>
      <div class="fixed inset-0 z-40 bg-black/55" onClick={() => store.setSettingsOpen(false)}>
        <div
          class="absolute top-16 right-8 w-[28rem] max-w-[calc(100vw-2rem)] rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] p-5 max-md:right-3 max-md:bottom-3 max-md:left-3 max-md:w-auto max-md:rounded-[14px]"
          onClick={(event) => event.stopPropagation()}
        >
          <div class="wordmark text-[28px] leading-none">Settings</div>
          <p class="mt-2 text-[13px] text-[var(--text-muted)]">
            This client is a live projection of the running desktop daemon. Colors come from the same
            verde.json / Omarchy path as the desktop app.
          </p>
          <p class="mt-2 text-[13px] text-[var(--text-muted)]">
            On a phone, open this URL over HTTPS (Tailscale) and use <strong>Add to Home Screen</strong>
            (Safari) or <strong>Install app</strong> (Chrome) for a standalone Verde icon.
          </p>
          <dl class="mt-4 space-y-0 text-[13px]">
            <Row label="Theme" value={theme()?.active ?? '…'} />
            <Row label="Theme source" value={theme()?.source ?? '…'} />
            <Row label="Daemon" value={store.source()} />
            <Row label="Socket" value={store.connected() ? 'websocket open' : 'reconnecting'} />
            <Row label="Workspace" value={store.workspace()?.label ?? '—'} />
            <Row label="Open panes" value={String(store.openPanes().length)} />
            <Row label="Focused pane" value={store.focusedPane() ? store.paneTitle(store.focusedPane()!) : '—'} />
          </dl>
          <button
            type="button"
            class="mt-5 w-full rounded-[7px] border border-[var(--border-muted)] py-2 text-[14px] hover:bg-[var(--accent-hover)]"
            onClick={() => store.setSettingsOpen(false)}
          >
            Close
          </button>
        </div>
      </div>
    </Show>
  )
}

function Row(props: { label: string; value: string }) {
  return (
    <div class="flex items-center justify-between gap-4 border-b border-[var(--border-muted)] py-2">
      <dt class="text-[var(--text-subtle)]">{props.label}</dt>
      <dd class="mono text-right text-[12px]">{props.value}</dd>
    </div>
  )
}

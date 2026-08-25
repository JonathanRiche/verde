import { For, Show, createMemo, createResource, createSignal } from 'solid-js'

import { fetchRpc, unwrapResult } from '../lib/live'
import { store } from '../lib/store'
import { loadTheme } from '../lib/theme'

const COMMANDS = [
  { id: 'new-thread', title: 'New chat thread', hint: 'Ctrl+T' },
  { id: 'new-terminal', title: 'New terminal split', hint: 'Ctrl+Alt+T' },
  { id: 'toggle-sidebar', title: 'Toggle sidebar', hint: 'Ctrl+S' },
  { id: 'maximize', title: 'Zoom / unzoom pane', hint: 'Alt+Z' },
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

export function WorkspaceDialog() {
  const [path, setPath] = createSignal('')
  const [submitting, setSubmitting] = createSignal(false)
  const [browserOpen, setBrowserOpen] = createSignal(false)
  const [browserLoading, setBrowserLoading] = createSignal(false)
  const [browserError, setBrowserError] = createSignal<string | null>(null)
  const [directoryListing, setDirectoryListing] = createSignal<{
    path: string
    parent?: string | null
    directories: Array<{ name: string; path: string }>
  } | null>(null)

  const close = () => {
    if (submitting()) return
    setPath('')
    setBrowserOpen(false)
    setBrowserError(null)
    setDirectoryListing(null)
    store.setWorkspaceDialogOpen(false)
  }

  const browse = async (requested_path?: string) => {
    // The projected workspace can belong to a different host than verde-web,
    // so an empty browser must start from the gateway machine's filesystem.
    const target = requested_path ?? (path().trim() || '/')
    setBrowserOpen(true)
    setBrowserLoading(true)
    setBrowserError(null)
    try {
      // HTTP on purpose: the shared websocket answers RPCs serially, so this
      // interactive browse must not queue behind a background projection sweep.
      const response = await fetchRpc('web.directory.list', { path: target })
      if (response.error || response.ok === false) {
        setBrowserError(response.error?.message ?? 'could not list directory')
        return
      }
      const listing = unwrapResult<{
        path: string
        parent?: string | null
        directories: Array<{ name: string; path: string }>
      }>(response)
      if (!listing || !Array.isArray(listing.directories)) {
        setBrowserError('directory listing was invalid')
        return
      }
      setDirectoryListing(listing)
      setPath(listing.path)
    } catch (err) {
      setBrowserError(err instanceof Error ? err.message : 'could not list directory')
    } finally {
      setBrowserLoading(false)
    }
  }

  const submit = async (event: SubmitEvent) => {
    event.preventDefault()
    if (!path().trim() || submitting()) return
    setSubmitting(true)
    const created = await store.createWorkspace(path())
    setSubmitting(false)
    if (created) setPath('')
  }

  return (
    <Show when={store.workspaceDialogOpen()}>
      <div class="fixed inset-0 z-40 bg-black/55" onClick={close}>
        <form
          class="mx-auto mt-[16vh] w-[32rem] max-w-[calc(100vw-2rem)] rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] p-5 shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
          onClick={(event) => event.stopPropagation()}
          onSubmit={submit}
        >
          <div class="wordmark text-[28px] leading-none">Add Workspace</div>
          <p class="mt-2 text-[13px] text-[var(--text-muted)]">
            Enter the absolute path to a project directory on the machine running Verde.
          </p>
          <div class="mt-4 flex gap-2">
            <input
              class="mono min-w-0 flex-1 rounded-[7px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 py-2 text-[13px] outline-none focus:border-[var(--accent)]"
              aria-label="Workspace path"
              placeholder="/path/to/project"
              autofocus
              value={path()}
              onInput={(event) => setPath(event.currentTarget.value)}
              onKeyDown={(event) => {
                if (event.key === 'Escape') close()
              }}
            />
            <button
              type="button"
              class="shrink-0 rounded-[7px] border border-[var(--border-muted)] px-3 py-2 text-[13px] hover:bg-[var(--accent-hover)]"
              onClick={() => void browse()}
            >
              Browse…
            </button>
          </div>
          <Show when={browserOpen()}>
            <div class="mt-3 overflow-hidden rounded-[7px] border border-[var(--border-muted)] bg-[var(--chat-black)]">
              <div class="flex items-center gap-2 border-b border-[var(--border-muted)] p-2">
                <button
                  type="button"
                  class="rounded px-2 py-1 text-[12px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] disabled:opacity-40"
                  disabled={!directoryListing()?.parent || browserLoading()}
                  onClick={() => {
                    const parent = directoryListing()?.parent
                    if (parent) void browse(parent)
                  }}
                >
                  Up
                </button>
                <span class="mono min-w-0 flex-1 truncate text-[11px] text-[var(--text-subtle)]">
                  {directoryListing()?.path ?? 'Loading…'}
                </span>
              </div>
              <div class="max-h-[32vh] overflow-y-auto p-1 scrollbar-thin">
                <Show when={!browserLoading()} fallback={<p class="px-3 py-4 text-xs text-[var(--text-subtle)]">Loading folders…</p>}>
                  <For
                    each={directoryListing()?.directories ?? []}
                    fallback={<p class="px-3 py-4 text-xs text-[var(--text-subtle)]">No subfolders.</p>}
                  >
                    {(directory) => (
                      <button
                        type="button"
                        class="flex w-full items-center gap-2 rounded-[5px] px-3 py-1.5 text-left text-[13px] hover:bg-[var(--accent-hover)]"
                        onClick={() => void browse(directory.path)}
                      >
                        <span class="text-[var(--accent)]">▸</span>
                        <span class="truncate">{directory.name}</span>
                      </button>
                    )}
                  </For>
                </Show>
              </div>
            </div>
          </Show>
          <Show when={browserError()}>
            <p class="mt-2 text-xs text-[var(--warning)]">{browserError()}</p>
          </Show>
          <Show when={store.notice()}>
            <p class="mt-2 text-xs text-[var(--warning)]">{store.notice()}</p>
          </Show>
          <div class="mt-4 flex justify-end gap-2">
            <button
              type="button"
              class="rounded-[7px] border border-[var(--border-muted)] px-4 py-2 text-[13px] hover:bg-[var(--accent-hover)]"
              disabled={submitting()}
              onClick={close}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="rounded-[7px] bg-[var(--accent)] px-4 py-2 text-[13px] text-white disabled:opacity-50"
              disabled={!path().trim() || submitting()}
            >
              {submitting() ? 'Adding…' : 'Add Workspace'}
            </button>
          </div>
        </form>
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

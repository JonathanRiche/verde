import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, onMount, untrack } from 'solid-js'

import { store } from '../lib/store'
import type { HistoryThread } from '../lib/history'
import type { Workspace } from '../lib/types'
import { Icon, ProviderGlyph } from './Icons'

// Overlay-only view state: the workspace whose saved chats are being browsed.
const [historyWorkspaceId, setHistoryWorkspaceId] = createSignal<string | null>(null)

/// Read by the global notice toast.
export const historyOpen = () => historyWorkspaceId() != null

export function openHistory(workspaceId: string) {
  setHistoryWorkspaceId(workspaceId)
}

export function relativeTime(seconds: number | null | undefined, nowSeconds: number): string {
  if (!seconds) return ''
  const age = Math.max(0, nowSeconds - seconds)
  if (age < 60) return 'now'
  if (age < 3600) return `${Math.floor(age / 60)}m`
  if (age < 86400) return `${Math.floor(age / 3600)}h`
  if (age < 604800) return `${Math.floor(age / 86400)}d`
  return new Date(seconds * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

type Loaded<T> = { state: 'loading' } | { state: 'error'; detail: string | null } | { state: 'ready'; rows: T[] }

export function History() {
  return (
    <Show when={historyWorkspaceId()} keyed>
      {(workspaceId) => <HistorySheet workspaceId={workspaceId} />}
    </Show>
  )
}

function HistorySheet(props: { workspaceId: string }) {
  const close = () => setHistoryWorkspaceId(null)
  const [tab, setTab] = createSignal<'chats' | 'workspaces'>('chats')
  const [query, setQuery] = createSignal('')
  const [threads, setThreads] = createSignal<Loaded<HistoryThread>>({ state: 'loading' })
  const [closed, setClosed] = createSignal<Loaded<Workspace>>({ state: 'loading' })
  const [confirming, setConfirming] = createSignal<string | null>(null)
  const [busy, setBusy] = createSignal<string | null>(null)
  const now = Math.floor(Date.now() / 1000)
  // Action failures surface here: store.notice only renders behind the backdrop.
  const [failure, setFailure] = createSignal<string | null>(null)
  let disposed = false
  onCleanup(() => { disposed = true })
  // The history API clears store.notice when a call starts, so the value read
  // right after a failed await belongs to that call, never to a stale one.
  const failureOf = (fallback: string) => untrack(() => store.notice()) ?? fallback

  const workspace = () => store.workspaces().find((row) => row.workspace_id === props.workspaceId)

  const loadThreads = async () => {
    setThreads({ state: 'loading' })
    const rows = await store.loadHistory(props.workspaceId)
    if (!disposed) setThreads(rows ? { state: 'ready', rows: rows.filter((row) => !row.archived) } : { state: 'error', detail: untrack(() => store.notice()) })
  }
  const loadClosed = async () => {
    setClosed({ state: 'loading' })
    const rows = await store.listArchivedWorkspaces()
    if (!disposed) setClosed(rows ? { state: 'ready', rows } : { state: 'error', detail: untrack(() => store.notice()) })
  }
  void loadThreads()
  // Closed workspaces load lazily: most visits only browse chats.
  createEffect(on(tab, (value) => { if (value === 'workspaces') void loadClosed() }, { defer: true }))

  const matches = (text: string) => text.toLowerCase().includes(query().trim().toLowerCase())
  const groups = createMemo(() => {
    const current = threads()
    if (current.state !== 'ready') return []
    return store.groupHistory(current.rows.filter((row) => matches(`${row.title} ${row.provider ?? ''}`)), now)
  })
  const closedRows = createMemo(() => {
    const current = closed()
    return current.state === 'ready' ? current.rows.filter((row) => matches(`${row.label} ${row.path}`)) : []
  })
  const count = () => {
    const current = threads()
    return current.state === 'ready' ? ` · ${current.rows.length}` : ''
  }

  const open = async (thread: HistoryThread) => {
    if (busy()) return
    setBusy(thread.local_thread_id)
    setFailure(null)
    const ok = await store.openHistoryThread(props.workspaceId, thread.local_thread_id)
    if (disposed) return
    setBusy(null)
    if (ok) {
      close()
      store.setDrawerOpen(false)
    } else setFailure(failureOf('Could not open that chat.'))
  }
  const archive = async (thread: HistoryThread) => {
    if (busy()) return
    if (confirming() !== thread.local_thread_id) {
      setConfirming(thread.local_thread_id)
      return
    }
    setBusy(thread.local_thread_id)
    setFailure(null)
    const ok = await store.archiveThread(props.workspaceId, thread.local_thread_id)
    if (disposed) return
    setBusy(null)
    setConfirming(null)
    if (!ok) {
      setFailure(failureOf('Could not archive that chat.'))
      return
    }
    setThreads((current) => current.state === 'ready'
      ? { state: 'ready', rows: current.rows.filter((row) => row.local_thread_id !== thread.local_thread_id) }
      : current)
  }
  const reopen = async (row: Workspace) => {
    if (busy()) return
    setBusy(row.workspace_id)
    setFailure(null)
    const ok = await store.reopenWorkspace(row.workspace_id)
    if (disposed) return
    setBusy(null)
    if (ok) {
      close()
      store.setDrawerOpen(false)
    } else setFailure(failureOf('Could not reopen that workspace.'))
  }

  // An armed Confirm must not linger: it reverts on its own after a pause.
  createEffect(() => {
    if (!confirming() || busy()) return
    const timer = setTimeout(() => setConfirming(null), 4000)
    onCleanup(() => clearTimeout(timer))
  })

  let panel: HTMLDivElement | undefined
  let filter: HTMLInputElement | undefined
  const tabIds = ['chats', 'workspaces'] as const
  const selectTab = (id: (typeof tabIds)[number]) => { setTab(id); setQuery('') }

  onMount(() => {
    const restore = document.activeElement instanceof HTMLElement ? document.activeElement : null
    // Wide screens have a hardware keyboard; on phones focusing the filter
    // would pop the soft keyboard over half the list.
    if (typeof matchMedia === 'function' && matchMedia('(min-width: 1024px)').matches) filter?.focus()
    else panel?.focus()
    // Window capture: Esc must work when focus sits outside the overlay
    // (opened from a context menu, or after tapping the backdrop padding).
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        if (confirming()) setConfirming(null)
        else close()
        return
      }
      if (event.key !== 'Tab' || !panel) return
      // Keep the global Tab-to-composer shortcut behind this modal.
      event.stopPropagation()
      const items = [...panel.querySelectorAll<HTMLElement>('button:not(:disabled), input, [tabindex="0"]')]
      if (items.length === 0) return
      const first = items[0]
      const last = items[items.length - 1]
      const active = document.activeElement
      if (!panel.contains(active) || active === panel) {
        event.preventDefault()
        ;(event.shiftKey ? last : first).focus()
      } else if (event.shiftKey && active === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && active === last) {
        event.preventDefault()
        first.focus()
      }
    }
    window.addEventListener('keydown', onKey, true)
    onCleanup(() => {
      window.removeEventListener('keydown', onKey, true)
      if (restore?.isConnected) restore.focus()
    })
  })

  return (
    // absolute, not fixed: iOS standalone clips fixed boxes to its short layout
    // viewport, and #app already fills the screen (same as the drawer).
    <div class="anim-fade absolute inset-0 z-40 bg-black/55" onClick={close}>
      <div
        class="history-panel anim-pop flex flex-col overflow-hidden border-[var(--border-muted)] bg-[var(--panel)] shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
        role="dialog"
        aria-modal="true"
        aria-label="Chat history"
        tabindex="-1"
        ref={(node) => { panel = node }}
        onClick={(event) => {
          event.stopPropagation()
          // Any click that is not on the armed Confirm button cancels it; the
          // check lives here so it does not depend on the button's propagation.
          if (!(event.target as HTMLElement | null)?.closest?.('[data-archive-confirm]')) setConfirming(null)
        }}
      >
        <div class="flex shrink-0 items-center gap-2 px-4 pt-3">
          <div class="flex min-w-0 flex-1 items-baseline gap-2 text-[15px] font-medium text-white">
            <span class="shrink-0">History{count()}</span>
            <span class="min-w-0 truncate text-[13px] font-normal text-[var(--text-subtle)]">{workspace()?.label ?? ''}</span>
          </div>
          <button
            type="button"
            class="grid h-11 w-11 place-items-center rounded-[6px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white lg:h-8 lg:w-8"
            aria-label="Close history"
            onClick={close}
          >
            <Icon name="close" class="h-4 w-4" />
          </button>
        </div>
        <div
          class="flex shrink-0 gap-1 px-3 pt-1"
          role="tablist"
          aria-label="History sections"
          onKeyDown={(event) => {
            if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
            event.preventDefault()
            const next = tabIds[(tabIds.indexOf(tab()) + 1) % tabIds.length]
            selectTab(next)
            document.getElementById(`history-tab-${next}`)?.focus()
          }}
        >
          <For each={[['chats', 'Chats'], ['workspaces', 'Closed workspaces']] as const}>
            {([id, label]) => (
              <button
                type="button"
                role="tab"
                id={`history-tab-${id}`}
                aria-controls="history-tabpanel"
                tabindex={tab() === id ? 0 : -1}
                aria-selected={tab() === id}
                class={`h-11 rounded-[7px] px-3 text-[13px] lg:h-8 ${tab() === id ? 'bg-[var(--accent-hover)] text-white' : 'text-[var(--text-muted)] hover:text-white'}`}
                onClick={() => selectTab(id)}
              >
                {label}
              </button>
            )}
          </For>
        </div>
        <input
          class="mt-1 w-full shrink-0 border-y border-[var(--border-muted)] bg-transparent px-4 py-3 text-[15px] outline-none placeholder:text-[var(--text-subtle)]"
          placeholder={tab() === 'chats' ? 'Filter saved chats' : 'Filter closed workspaces'}
          aria-label="Filter"
          value={query()}
          ref={(node) => { filter = node }}
          onInput={(event) => setQuery(event.currentTarget.value)}
        />
        <Show when={failure()}>
          <p class="anim-reveal shrink-0 border-b border-[var(--border-muted)] px-4 py-2 text-[13px] text-[var(--warning)]" role="alert">
            {failure()}
          </p>
        </Show>

        <div
          class="min-h-0 flex-1 overflow-y-auto p-1.5 scrollbar-thin"
          role="tabpanel"
          id="history-tabpanel"
          aria-labelledby={`history-tab-${tab()}`}
        >
          <Show when={tab() === 'chats'}>
            <Show when={threads().state === 'loading'}><Status text="Loading saved chats…" /></Show>
            <Show when={threads().state === 'error'}>
              <Status text="Could not load history." detail={errorDetail(threads())} onRetry={() => void loadThreads()} />
            </Show>
            <Show when={threads().state === 'ready' && groups().length === 0}>
              <Status text={query().trim() ? 'Nothing matches.' : 'No saved chats in this workspace.'} />
            </Show>
            <For each={groups()}>
              {(group) => (
                <section>
                  <div class="px-3 pt-3 pb-1 text-[11px] tracking-wide text-[var(--text-subtle)]">
                    {group.label.toUpperCase()}
                  </div>
                  <For each={group.threads}>
                    {(thread) => (
                      <div class="flex min-h-11 items-center rounded-[7px] hover:bg-[var(--accent-hover)] lg:min-h-9">
                        <button
                          type="button"
                          class={`flex min-h-11 min-w-0 flex-1 items-center gap-2.5 px-3 text-left lg:min-h-9 ${busy() === thread.local_thread_id ? 'opacity-50' : ''}`}
                          disabled={busy() != null}
                          onClick={() => void open(thread)}
                        >
                          <ProviderGlyph provider={thread.provider ?? 'codex'} class="h-4 w-4 shrink-0" />
                          <span class="min-w-0 flex-1 truncate text-[14px]">{thread.title || 'Untitled chat'}</span>
                          <span class="mono shrink-0 text-[10px] text-[var(--text-subtle)]">
                            {/* The glyph already names the provider; phones need the width for the title. */}
                            <span class="hidden lg:inline">{thread.provider ?? ''} </span>
                            {relativeTime(thread.last_activity_at, now)}
                          </span>
                        </button>
                        <button
                          type="button"
                          data-archive-confirm={confirming() === thread.local_thread_id ? '' : undefined}
                          aria-label={confirming() === thread.local_thread_id
                            ? `Confirm archive of ${thread.title || 'Untitled chat'}`
                            : `Archive ${thread.title || 'Untitled chat'}`}
                          class={`mr-1 h-11 shrink-0 rounded-[6px] px-2.5 text-[12px] lg:h-7 ${busy() === thread.local_thread_id ? 'opacity-50' : ''} ${
                            confirming() === thread.local_thread_id
                              ? 'bg-[var(--danger)] font-bold text-[#0d1213]'
                              : 'text-[var(--text-subtle)] hover:text-white'
                          }`}
                          disabled={busy() != null}
                          onClick={() => void archive(thread)}
                        >
                          {busy() === thread.local_thread_id && confirming() === thread.local_thread_id
                            ? 'Archiving…'
                            : confirming() === thread.local_thread_id ? 'Archive?' : 'Archive'}
                        </button>
                      </div>
                    )}
                  </For>
                </section>
              )}
            </For>
          </Show>

          <Show when={tab() === 'workspaces'}>
            <Show when={closed().state === 'loading'}><Status text="Loading closed workspaces…" /></Show>
            <Show when={closed().state === 'error'}>
              <Status text="Could not load closed workspaces." detail={errorDetail(closed())} onRetry={() => void loadClosed()} />
            </Show>
            <Show when={closed().state === 'ready' && closedRows().length === 0}>
              <Status text={query().trim() ? 'Nothing matches.' : 'No closed workspaces.'} />
            </Show>
            <For each={closedRows()}>
              {(row) => (
                <div class="flex min-h-11 items-center gap-2.5 rounded-[7px] px-3 hover:bg-[var(--accent-hover)] lg:min-h-9">
                  <Icon name="folder" class="h-4 w-4 shrink-0 text-[var(--text-subtle)]" />
                  <div class="min-w-0 flex-1 py-1.5">
                    <div class="truncate text-[14px]">{row.label}</div>
                    <div class="mono truncate text-[10px] text-[var(--text-subtle)]">{row.path}</div>
                  </div>
                  <button
                    type="button"
                    class={`h-11 shrink-0 rounded-[6px] px-2.5 text-[12px] text-[var(--accent)] hover:text-white lg:h-7 ${busy() === row.workspace_id ? 'opacity-50' : ''}`}
                    disabled={busy() != null}
                    onClick={() => void reopen(row)}
                  >
                    {busy() === row.workspace_id ? 'Reopening…' : 'Reopen'}
                  </button>
                </div>
              )}
            </For>
          </Show>
        </div>
      </div>
    </div>
  )
}

function errorDetail(loaded: Loaded<unknown>): string | null {
  return loaded.state === 'error' ? loaded.detail : null
}

function Status(props: { text: string; detail?: string | null; onRetry?: () => void }) {
  return (
    <div class="flex items-center gap-3 px-3 py-4 text-sm text-[var(--text-subtle)]" role="status">
      <span class="min-w-0 flex-1">
        {props.text}
        <Show when={props.detail}>
          <span class="mt-0.5 block text-xs text-[var(--warning)]">{props.detail}</span>
        </Show>
      </span>
      <Show when={props.onRetry}>
        <button type="button" class="h-11 rounded-[6px] px-3 text-[13px] text-[var(--accent)] lg:h-8" onClick={props.onRetry}>
          Retry
        </button>
      </Show>
    </div>
  )
}

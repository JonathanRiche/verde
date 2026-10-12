import { For, Show, createEffect, createMemo, createRoot, createSignal, on, onCleanup, onMount, untrack } from 'solid-js'

import {
  CHARACTER_INFO, COMPANION_CHARACTERS, COMPANION_SUGGESTIONS, MAX_COMPANIONS, NAME_MAX_BYTES,
  activeCompanion, addCompanion, cleanCompanionName, companionPose, companionStatusLine, crewStatusPill,
  parseCrewLinks, parseRosterSnapshot, patchCompanion, removeCompanion, saveRoster, selectCompanion,
  withDefaultCompanion,
  type Companion, type CompanionCharacter, type CrewLink, type PillTone, type Roster, type RosterSnapshot,
} from '../lib/companion'
import { composerEnterShouldSubmit } from '../lib/composer_input'
import { modelOptionsFor } from '../lib/models'
import { store } from '../lib/store'
import type { LivePane, Message, RpcEnvelope } from '../lib/types'
import { providerLabel } from '../lib/web_actions'
import { ApprovalCard, TranscriptRow } from './ChatPane'
import { CompanionAvatar } from './CompanionAvatar'
import { Icon, Spinner } from './Icons'
import { containModalFocus } from './Overlays'

const BRAIN_PROVIDERS = ['codex', 'claude', 'cursor', 'opencode', 'pi', 'fx', 'grok', 'muse'] as const
/// Roster polling: often while the panel is open, slowly for the dock.
const POLL_MS = 5000
const DOCK_POLL_EVERY = 6
const CONVERSATION_WINDOW = 50

/// User edits ride the interactive HTTP path; polling shares the websocket.
const call = (method: string, params: unknown): Promise<RpcEnvelope> => store.workspaceCall(method, params)
const pollCall = (method: string, params: unknown): Promise<RpcEnvelope> => store.client.call(method, params)
const sameJson = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)
const errorText = (error: unknown, fallback: string) => (error instanceof Error ? error.message : fallback)

/// Older daemons (or paired scopes without chat:read) cannot serve the roster.
const UNAVAILABLE_CODES = new Set(['unknown_method', 'method_not_found', 'forbidden', 'insufficient_scope', 'capability_unavailable'])

function createCompanionState() {
  const [snapshot, setSnapshot] = createSignal<RosterSnapshot | null>(null, { equals: sameJson })
  const [unavailable, setUnavailable] = createSignal(false)
  const [loadError, setLoadError] = createSignal<string | null>(null)
  const [panelOpen, setPanelOpen] = createSignal(false)
  const [view, setView] = createSignal<'chat' | 'settings'>('chat')
  const [crew, setCrew] = createSignal<CrewLink[]>([], { equals: sameJson })
  const [saving, setSaving] = createSignal(false)
  let refreshing: Promise<void> | null = null
  let queue: Promise<unknown> = Promise.resolve()

  const roster = (): Roster | null => snapshot()?.roster ?? null
  const active = createMemo<Companion | null>(() => {
    const current = roster()
    return current ? activeCompanion(current) : null
  }, null, { equals: sameJson })

  /// Concurrent callers share one in-flight read.
  const refresh = (): Promise<void> => {
    refreshing ??= readRoster().finally(() => { refreshing = null })
    return refreshing
  }
  const readRoster = async () => {
    try {
      const response = await pollCall('companion.roster.get', {})
      const next = parseRosterSnapshot(response)
      if (!next) {
        if (UNAVAILABLE_CODES.has(response.error?.code ?? '')) setUnavailable(true)
        setLoadError(response.error?.message ?? 'Could not load companions')
        return
      }
      setUnavailable(false)
      setLoadError(null)
      setSnapshot(next)
    } catch (error) {
      setLoadError(errorText(error, 'Could not load companions'))
    }
  }

  /// Serialized optimistic-concurrency save; `edit` is re-applied after a
  /// conflict so another client's save is never overwritten.
  const save = (edit: (roster: Roster) => Roster | null): Promise<boolean> => {
    const run = queue.then(async () => {
      setSaving(true)
      try {
        let current = snapshot()
        if (!current) {
          await refresh()
          current = snapshot()
        }
        if (!current) throw new Error(loadError() ?? 'Companions are unavailable')
        setSnapshot(await saveRoster(call, current, edit))
        return true
      } catch (error) {
        store.setNotice(errorText(error, 'Could not save companions'))
        void refresh()
        return false
      } finally {
        setSaving(false)
      }
    })
    queue = run.catch(() => {})
    return run
  }

  const refreshCrew = async () => {
    const companion = active()
    if (!companion?.thread_id || !companion.home_workspace_id) {
      setCrew([])
      return
    }
    try {
      const response = await pollCall('chat.links.list', {
        workspace_id: companion.home_workspace_id,
        parent_thread_id: companion.thread_id,
      })
      if (!response.error && response.ok !== false) setCrew(parseCrewLinks(response))
    } catch {
      // Keep the last crew until the connection recovers.
    }
  }

  // Roster threads never become canvas panes; the panel renders them.
  createEffect(() => {
    const companions = roster()?.companions ?? []
    untrack(() => store.setCompanionThreads(companions.map((row) => ({ workspace_id: row.home_workspace_id, thread_id: row.thread_id }))))
  })
  // Only the open panel streams the active companion's conversation.
  createEffect(() => {
    const companion = active()
    const open = panelOpen()
    untrack(() => store.setCompanionTarget(open && companion?.thread_id
      ? { workspace_id: companion.home_workspace_id, thread_id: companion.thread_id }
      : null))
  })
  createEffect(on(() => active()?.id, () => { setCrew([]); if (panelOpen()) void refreshCrew() }, { defer: true }))

  const defaultHome = () => store.workspace()?.workspace_id ?? store.workspaces()[0]?.workspace_id ?? ''

  const open = async (target: 'chat' | 'settings' = 'chat') => {
    setView(target)
    setPanelOpen(true)
    if (!snapshot()) await refresh()
    // First use: an empty machine roster gets a default Sprout.
    if (snapshot() && roster()?.companions.length === 0) await save((current) => withDefaultCompanion(current, defaultHome()))
    void refreshCrew()
  }
  const close = () => {
    setPanelOpen(false)
    setView('chat')
  }

  /// Resolves the active companion's chat, creating and binding its thread on
  /// first send (home workspace, else the first workspace).
  const ensureThread = async (): Promise<LivePane | null> => {
    const companion = active()
    if (!companion) return null
    if (companion.thread_id) return store.companionPane()
    const workspaces = store.workspaces()
    const home = workspaces.find((row) => row.workspace_id === companion.home_workspace_id) ?? workspaces[0]
    if (!home) {
      store.setNotice('Add a workspace so your companion has somewhere to work.')
      return null
    }
    const thread_id = await store.createCompanionThread(home.workspace_id, {
      title: companion.name,
      provider: companion.provider || home.provider || 'codex',
      model: companion.model || null,
    })
    if (!thread_id) return null
    const saved = await save((current) => {
      const fresh = current.companions.find((row) => row.id === companion.id)
      // Another client bound a thread first: keep theirs.
      if (!fresh || fresh.thread_id) return null
      return patchCompanion(current, companion.id, { home_workspace_id: home.workspace_id, thread_id })
    })
    if (!saved) return null
    const bound = active()
    if (!bound?.thread_id) return null
    store.setCompanionTarget({ workspace_id: bound.home_workspace_id, thread_id: bound.thread_id })
    return store.companionPane()
  }

  return {
    snapshot, roster, active, unavailable, loadError, panelOpen, view, setView, crew, saving,
    refresh, refreshCrew, save, open, close, ensureThread, defaultHome,
  }
}

const companion = createRoot(createCompanionState)

/// Machine-wide presence derived from real state only.
function usePresence() {
  const needs = () => store.needsYou().length
  const running = () => store.runningChatCount()
  return {
    needs,
    running,
    status: () => companionStatusLine({ needs: needs(), running: running() }),
    pose: () => companionPose({ connected: store.connected(), needs: needs(), working: running() > 0 }),
  }
}

/// Mounted once by App: polls the roster (and crew while open) and renders
/// the panel.
export function CompanionHost() {
  onMount(() => {
    let tick = 0
    const timer = window.setInterval(() => {
      tick += 1
      if (document.visibilityState === 'hidden' || !store.connected() || companion.unavailable()) return
      if (companion.panelOpen()) {
        void companion.refresh()
        void companion.refreshCrew()
      } else if (tick % DOCK_POLL_EVERY === 0) {
        void companion.refresh()
      }
    }, POLL_MS)
    onCleanup(() => window.clearInterval(timer))
  })
  createEffect(on(store.connected, (connected) => {
    if (connected && !companion.snapshot()) void companion.refresh()
  }))
  return (
    <Show when={companion.panelOpen()}>
      <CompanionPanel />
    </Show>
  )
}

/// Always-reachable entry point. `sidebar` sits above the sidebar footer,
/// `floating` covers the hidden-sidebar desktop layout, `icon` is the
/// compact mobile top-bar button.
export function CompanionDock(props: { variant: 'sidebar' | 'floating' | 'icon' }) {
  const presence = usePresence()
  const current = () => companion.active()
  const name = () => current()?.name ?? 'Companion'
  const character = (): CompanionCharacter => current()?.character ?? 'sprout'
  const label = () => `Open ${name()}: ${presence.status()}`
  const badge = () => (
    <Show when={presence.needs() > 0}>
      <span class="grid h-[18px] min-w-[18px] place-items-center rounded-full bg-[var(--warning)] px-1 text-[10px] font-semibold text-black" aria-hidden="true">
        {presence.needs()}
      </span>
    </Show>
  )
  return (
    <Show when={!companion.unavailable()}>
      <Show
        when={props.variant !== 'icon'}
        fallback={
          <button
            type="button"
            class="relative grid h-10 w-10 place-items-center rounded-[8px] hover:bg-[var(--accent-hover)]"
            aria-label={label()}
            aria-haspopup="dialog"
            aria-expanded={companion.panelOpen()}
            onClick={() => void companion.open()}
          >
            <CompanionAvatar character={character()} pose={presence.pose()} class="h-7 w-7" />
            <span class="absolute -top-0.5 -right-0.5">{badge()}</span>
          </button>
        }
      >
        <button
          type="button"
          class={`flex min-w-0 items-center gap-2.5 rounded-[10px] border border-[var(--border-muted)] text-left hover:bg-[var(--accent-hover)] ${
            props.variant === 'floating'
              ? 'absolute bottom-3 left-14 z-20 hidden max-w-[16rem] bg-[var(--panel)] py-1.5 pr-3 pl-2 shadow-[0_6px_20px_rgba(0,0,0,0.35)] lg:flex'
              : 'w-full bg-[var(--panel-alt)] px-2.5 py-2'
          }`}
          aria-label={label()}
          aria-haspopup="dialog"
          aria-expanded={companion.panelOpen()}
          onClick={() => {
            store.setDrawerOpen(false)
            void companion.open()
          }}
        >
          <CompanionAvatar character={character()} pose={presence.pose()} class="h-9 w-9" />
          <span class="min-w-0 flex-1">
            <span class="block truncate text-[13px] font-medium text-[var(--text)]">{name()}</span>
            <span class={`block truncate text-[11.5px] ${presence.needs() > 0 ? 'text-[var(--warning)]' : 'text-[var(--text-subtle)]'}`}>
              {presence.status()}
            </span>
          </span>
          {badge()}
        </button>
      </Show>
    </Show>
  )
}

const PILL_CLASS: Record<PillTone, string> = {
  accent: 'bg-[var(--accent-wash)] text-[var(--accent)]',
  warning: 'bg-[color-mix(in_srgb,var(--warning)_18%,transparent)] text-[var(--warning)]',
  danger: 'bg-[color-mix(in_srgb,var(--danger)_18%,transparent)] text-[var(--danger)]',
  done: 'bg-[var(--panel-muted)] text-[var(--text-muted)]',
  muted: 'bg-[var(--panel-alt)] text-[var(--text-subtle)]',
}

function StatusPill(props: { status: string }) {
  const pill = () => crewStatusPill(props.status)
  return (
    <span class={`shrink-0 whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-medium ${PILL_CLASS[pill().tone]}`}>
      {pill().label}
    </span>
  )
}

function brainLabel(provider: string | null | undefined, model: string | null | undefined): string {
  if (!provider) return 'New-chat defaults'
  const options = store.providerModels(provider) ?? modelOptionsFor(provider)
  const modelName = model ? options.find((row) => row.value === model)?.label ?? model : 'default model'
  return `${providerLabel(provider)} · ${modelName}`
}

function CompanionPanel() {
  let panel: HTMLElement | undefined
  let field: HTMLTextAreaElement | undefined
  containModalFocus(companion.panelOpen, () => panel, () => (companion.view() === 'chat' ? field : undefined))
  const presence = usePresence()
  const current = () => companion.active()
  const companions = () => companion.roster()?.companions ?? []
  const pane = () => store.companionPane()
  const brain = () => {
    const live = pane()
    return live ? brainLabel(live.provider, live.model) : brainLabel(current()?.provider, current()?.model)
  }
  const ownThread = (workspace_id: string, thread_id: string) =>
    current()?.home_workspace_id === workspace_id && current()?.thread_id === thread_id
  const needs = createMemo(() => store.needsYou().filter((row) => !ownThread(row.workspace_id, row.local_thread_id)))

  const openChat = async (workspace_id: string, thread_id: string) => {
    const opened = await store.openChat(workspace_id, thread_id)
    if (opened && store.compact()) companion.close()
  }

  const addNew = async () => {
    const used = new Set(companions().map((row) => row.character))
    const character = COMPANION_CHARACTERS.find((row) => !used.has(row)) ?? 'sprout'
    const saved = await companion.save((roster) => addCompanion(roster, character, { home_workspace_id: companion.defaultHome() }))
    if (saved) companion.setView('settings')
  }

  return (
    <div
      class="anim-fade absolute inset-0 z-40 flex justify-end bg-black/45"
      onClick={() => companion.close()}
    >
      <section
        ref={(node) => { panel = node }}
        role="dialog"
        aria-modal="true"
        aria-label={`Companion ${current()?.name ?? ''}`.trim()}
        tabindex="-1"
        class="anim-menu flex h-full w-full flex-col border-l border-[var(--border-muted)] bg-[var(--panel)] pt-[var(--safe-top)] pb-[var(--safe-bottom)] shadow-[-8px_0_40px_rgba(0,0,0,0.45)] sm:w-[min(460px,100vw)]"
        onClick={(event) => event.stopPropagation()}
        onKeyDown={(event) => {
          if (event.key !== 'Escape' || event.isComposing) return
          event.preventDefault()
          event.stopPropagation()
          if (companion.view() === 'settings') companion.setView('chat')
          else companion.close()
        }}
      >
        <header class="flex shrink-0 items-center gap-3 border-b border-[var(--border-muted)] px-4 py-3">
          <CompanionAvatar character={current()?.character ?? 'sprout'} pose={presence.pose()} class="h-12 w-12" />
          <div class="min-w-0 flex-1">
            <h2 class="truncate text-[16px] font-semibold">{current()?.name ?? 'Companion'}</h2>
            <p class="truncate text-[12px] text-[var(--text-subtle)]" title="Brain">{brain()}</p>
          </div>
          <button
            type="button"
            class="grid h-10 w-10 place-items-center rounded-[7px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white disabled:opacity-40 lg:h-8 lg:w-8"
            aria-label="New companion"
            title={companions().length >= MAX_COMPANIONS ? `Up to ${MAX_COMPANIONS} companions` : 'New companion'}
            disabled={companion.saving() || companions().length >= MAX_COMPANIONS}
            onClick={() => void addNew()}
          >
            <Icon name="plus" class="h-[18px] w-[18px]" />
          </button>
          <button
            type="button"
            class={`grid h-10 w-10 place-items-center rounded-[7px] hover:bg-[var(--accent-hover)] hover:text-white lg:h-8 lg:w-8 ${companion.view() === 'settings' ? 'text-[var(--accent)]' : 'text-[var(--text-subtle)]'}`}
            aria-label="Companion settings"
            aria-pressed={companion.view() === 'settings'}
            onClick={() => companion.setView(companion.view() === 'settings' ? 'chat' : 'settings')}
          >
            <Icon name="settings" class="h-4 w-4" />
          </button>
          <button
            type="button"
            class="grid h-10 w-10 place-items-center rounded-[7px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white lg:h-8 lg:w-8"
            aria-label="Close companion"
            onClick={() => companion.close()}
          >
            <Icon name="close" class="h-4 w-4" />
          </button>
        </header>

        <Show when={companions().length > 1}>
          <div class="flex shrink-0 gap-1.5 overflow-x-auto border-b border-[var(--border-muted)] px-4 py-2 scrollbar-thin" role="group" aria-label="Switch companion">
            <For each={companions()}>
              {(row) => (
                <button
                  type="button"
                  class={`flex shrink-0 items-center gap-1.5 rounded-full border py-1 pr-3 pl-1.5 text-[12px] ${
                    row.id === current()?.id
                      ? 'border-[var(--accent)] bg-[var(--accent-wash)] text-[var(--text)]'
                      : 'border-[var(--border-muted)] text-[var(--text-muted)] hover:bg-[var(--accent-hover)]'
                  }`}
                  aria-pressed={row.id === current()?.id}
                  disabled={companion.saving()}
                  onClick={() => void companion.save((roster) => selectCompanion(roster, row.id))}
                >
                  <CompanionAvatar character={row.character} pose="idle" class="h-5 w-5" />
                  {row.name}
                </button>
              )}
            </For>
          </div>
        </Show>

        <Show when={companion.loadError() && !companion.snapshot()}>
          <div class="flex shrink-0 items-center gap-2 px-4 py-3 text-[13px] text-[var(--warning)]" role="alert">
            <span class="min-w-0 flex-1">{companion.loadError()}</span>
            <button type="button" class="rounded-[7px] border border-[var(--border-muted)] px-2.5 py-1 text-[12px] text-[var(--text)] hover:bg-[var(--accent-hover)]" onClick={() => void companion.refresh()}>
              Retry
            </button>
          </div>
        </Show>

        <Show
          when={companion.view() === 'chat'}
          fallback={<Show when={current()?.id} keyed>{(_id) => <CompanionSettings companion={current()!} />}</Show>}
        >
          <Show when={needs().length > 0 || companion.crew().length > 0}>
            <div class="max-h-[38%] shrink-0 overflow-y-auto border-b border-[var(--border-muted)] px-4 py-2 scrollbar-thin">
              <Show when={needs().length > 0}>
                <h3 class="py-1 text-[11px] font-semibold tracking-wide text-[var(--warning)]">NEEDS YOU</h3>
                <ul class="flex flex-col gap-1">
                  <For each={needs()}>
                    {(row) => (
                      <li>
                        <button
                          type="button"
                          class="flex w-full min-w-0 items-center gap-2 rounded-[7px] px-2 py-1.5 text-left hover:bg-[var(--accent-hover)]"
                          onClick={() => void openChat(row.workspace_id, row.local_thread_id)}
                        >
                          <span class="cmd-dot-pulse h-2 w-2 shrink-0 rounded-full bg-[var(--warning)]" aria-hidden="true" />
                          <span class="min-w-0 flex-1">
                            <span class="block truncate text-[13px]">{row.title}</span>
                            <span class="block truncate text-[11.5px] text-[var(--text-subtle)]">{row.workspace_label} · {row.approval_title}</span>
                          </span>
                          <StatusPill status="waiting_approval" />
                        </button>
                      </li>
                    )}
                  </For>
                </ul>
              </Show>
              <Show when={companion.crew().length > 0}>
                <h3 class="py-1 text-[11px] font-semibold tracking-wide text-[var(--text-subtle)]">CREW</h3>
                <ul class="flex flex-col gap-1">
                  <For each={companion.crew()}>
                    {(link) => (
                      <li>
                        <button
                          type="button"
                          class="flex w-full min-w-0 items-center gap-2 rounded-[7px] px-2 py-1.5 text-left hover:bg-[var(--accent-hover)]"
                          title={link.summary || link.title}
                          onClick={() => void openChat(link.workspace_id, link.local_thread_id)}
                        >
                          <span class="min-w-0 flex-1">
                            <span class="block truncate text-[13px]">{link.title}</span>
                            <span class="block truncate text-[11.5px] text-[var(--text-subtle)]">
                              {store.workspaces().find((row) => row.workspace_id === link.workspace_id)?.label ?? link.workspace_id}
                              {link.provider ? ` · ${providerLabel(link.provider)}` : ''}
                              {link.summary ? ` · ${link.summary}` : ''}
                            </span>
                          </span>
                          <StatusPill status={link.status} />
                        </button>
                      </li>
                    )}
                  </For>
                </ul>
              </Show>
            </div>
          </Show>
          <Conversation fieldRef={(node) => { field = node }} />
        </Show>
      </section>
    </div>
  )
}

function Conversation(props: { fieldRef: (node: HTMLTextAreaElement) => void }) {
  let scroller: HTMLDivElement | undefined
  let field: HTMLTextAreaElement | undefined
  const current = () => companion.active()
  const pane = () => store.companionPane()
  const [draft, setDraft] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [limit, setLimit] = createSignal(CONVERSATION_WINDOW)
  const coarse = typeof window !== 'undefined' && window.matchMedia?.('(pointer: coarse)').matches

  createEffect(() => {
    const live = pane()
    if (live) store.ensureTranscript(live)
  })
  const transcript = () => {
    const live = pane()
    return live ? store.transcriptState(live) : null
  }
  const messages = createMemo<Message[]>(() => {
    const live = pane()
    if (!live) return []
    return store.messagesFor(live).filter((row) => row.author !== '__verde_codex_background_snapshot')
  })
  const visible = createMemo(() => messages().slice(-limit()))
  const hasThread = () => Boolean(current()?.thread_id)
  const empty = () => messages().length === 0 && (!hasThread() || Boolean(transcript()?.loaded))
  const missing = () => hasThread() && !pane()
  const working = () => store.paneWorking(pane())

  // Stay pinned to the newest message unless the user scrolled up.
  let pinned = true
  createEffect(on(() => [visible().length, visible().at(-1)?.body.length], () => {
    queueMicrotask(() => {
      if (scroller && pinned) scroller.scrollTop = scroller.scrollHeight
    })
  }))

  const showEarlier = async () => {
    pinned = false
    if (messages().length > limit()) {
      setLimit((value) => value + CONVERSATION_WINDOW)
      return
    }
    const live = pane()
    if (live && transcript()?.hasOlder) {
      await store.loadOlderTranscript(live)
      setLimit((value) => value + CONVERSATION_WINDOW)
    }
  }

  const submit = async (text: string) => {
    const value = text.trim()
    if (!value || busy()) return
    setBusy(true)
    try {
      const live = await companion.ensureThread()
      if (!live) {
        if (current()?.thread_id) store.setNotice('Still loading this conversation; try again in a moment.')
        return
      }
      pinned = true
      const accepted = await store.sendPromptTo(live, value)
      if (accepted && draft().trim() === value) {
        setDraft('')
        if (field) field.value = ''
      }
    } finally {
      setBusy(false)
    }
  }

  const startFresh = () => companion.save((roster) => {
    const id = current()?.id
    return id ? patchCompanion(roster, id, { thread_id: '' }) : null
  })

  return (
    <>
      <div
        ref={(node) => { scroller = node }}
        class="min-h-0 flex-1 overflow-y-auto px-4 py-3 scrollbar-thin"
        tabindex="0"
        aria-label="Conversation"
        onScroll={() => {
          if (scroller) pinned = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 96
        }}
      >
        <Show when={!missing()} fallback={
          <div class="px-2 py-10 text-center text-[13px] text-[var(--text-muted)]" role="status">
            <p>Looking for this conversation…</p>
            <button
              type="button"
              class="mt-3 rounded-full bg-[var(--panel-alt)] px-3 py-1.5 text-[12.5px] hover:bg-[var(--accent-hover)]"
              disabled={companion.saving()}
              onClick={() => void startFresh()}
            >
              Start a new conversation
            </button>
          </div>
        }>
          <Show when={!empty()} fallback={
            <div class="flex flex-col items-center px-2 py-8 text-center">
              <CompanionAvatar character={current()?.character ?? 'sprout'} pose="idle" class="h-20 w-20" />
              <p class="mt-3 text-[17px] font-semibold">Hi, I'm {current()?.name ?? 'Sprout'}.</p>
              <p class="mt-1 text-[12.5px] text-[var(--text-muted)]">
                {CHARACTER_INFO[current()?.character ?? 'sprout'].tagline}
              </p>
              <div class="mt-5 flex w-full flex-col gap-2">
                <For each={COMPANION_SUGGESTIONS}>
                  {(suggestion) => (
                    <button
                      type="button"
                      class="w-full rounded-[10px] border border-[var(--border-muted)] px-3 py-2.5 text-left text-[13px] hover:bg-[var(--accent-hover)] disabled:opacity-50"
                      disabled={busy() || !current()}
                      onClick={() => void submit(suggestion)}
                    >
                      {suggestion}
                    </button>
                  )}
                </For>
              </div>
            </div>
          }>
            <div class="flex flex-col gap-3">
              <Show when={messages().length > limit() || transcript()?.hasOlder}>
                <button
                  type="button"
                  class="mx-auto rounded-full bg-[var(--panel-alt)] px-3 py-1.5 text-[12px] text-[var(--text-muted)] hover:text-[var(--text)]"
                  disabled={transcript()?.loadingOlder}
                  onClick={() => void showEarlier()}
                >
                  {transcript()?.loadingOlder ? 'Loading earlier messages…' : 'Show earlier messages'}
                </button>
              </Show>
              <Show when={pane()}>
                {(live) => <For each={visible()}>{(message) => <TranscriptRow message={message} pane={live()} />}</For>}
              </Show>
              <Show when={transcript() && !transcript()!.loaded && messages().length === 0}>
                <p class="text-center text-[12px] text-[var(--text-muted)]" role="status">
                  {transcript()?.error ? 'Could not load this conversation.' : 'Loading conversation…'}
                </p>
              </Show>
            </div>
          </Show>
        </Show>
      </div>
      <Show when={pane()}>{(live) => <ApprovalCard pane={live()} />}</Show>
      <form
        class="flex shrink-0 items-end gap-2 border-t border-[var(--border-muted)] px-3 py-2.5"
        onSubmit={(event) => {
          event.preventDefault()
          void submit(draft())
        }}
      >
        <label class="sr-only" for="companion-composer">Message {current()?.name ?? 'your companion'}</label>
        <textarea
          id="companion-composer"
          ref={(node) => { field = node; props.fieldRef(node) }}
          rows={2}
          class="max-h-40 min-h-[44px] min-w-0 flex-1 resize-none rounded-[var(--radius-composer)] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 py-2 text-[14px] text-[var(--text)] outline-none placeholder:text-[var(--text-subtle)] focus:border-[var(--accent)]"
          placeholder={`Ask ${current()?.name ?? 'your companion'} to orchestrate…`}
          value={draft()}
          disabled={!current()}
          onInput={(event) => setDraft(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (composerEnterShouldSubmit(event, { compact: store.compact(), coarsePointer: Boolean(coarse) })) {
              event.preventDefault()
              void submit(draft())
            }
          }}
        />
        <Show
          when={working() && !draft().trim()}
          fallback={
            <button
              type="submit"
              class="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-[var(--accent)] text-black disabled:opacity-40"
              aria-label={working() ? 'Queue follow-up' : 'Send'}
              disabled={busy() || !draft().trim() || !current()}
            >
              <Show when={busy()} fallback={<Icon name="send" class="h-5 w-5" />}>
                <Spinner class="h-4 w-4" />
              </Show>
            </button>
          }
        >
          <button
            type="button"
            class="composer-stop grid h-11 w-11 shrink-0 place-items-center rounded-full border border-[var(--border-muted)] text-[var(--text)] hover:bg-[var(--accent-hover)]"
            aria-label="Stop"
            onClick={() => void store.stopTurn(pane())}
          >
            <span class="h-3 w-3 rounded-[2px] bg-current" aria-hidden="true" />
          </button>
        </Show>
      </form>
    </>
  )
}

function CompanionSettings(props: { companion: Companion }) {
  const fieldClass = 'w-full rounded-[7px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-2.5 py-2 text-[13.5px] text-[var(--text)] outline-none focus:border-[var(--accent)]'
  const [name, setName] = createSignal(props.companion.name)
  const [character, setCharacter] = createSignal<CompanionCharacter>(props.companion.character)
  const [orders, setOrders] = createSignal(props.companion.orders)
  const [provider, setProvider] = createSignal(props.companion.provider)
  const [model, setModel] = createSignal(props.companion.model)
  const [confirmRemove, setConfirmRemove] = createSignal(false)
  const companions = () => companion.roster()?.companions ?? []

  createEffect(() => { if (provider()) store.ensureProviderModels(provider()) })
  const models = createMemo(() => {
    const id = provider()
    if (!id) return []
    const options = (store.providerModels(id) ?? modelOptionsFor(id)).map((row) => ({ value: row.value, label: row.label }))
    if (model() && !options.some((row) => row.value === model())) options.unshift({ value: model(), label: model() })
    return options
  })
  const cleanedName = () => cleanCompanionName(name())
  const dirty = () =>
    cleanedName() !== props.companion.name || character() !== props.companion.character ||
    orders().trim() !== props.companion.orders || provider() !== props.companion.provider || model() !== props.companion.model

  const saveChanges = async () => {
    if (!cleanedName()) {
      store.setNotice('Give your companion a name.')
      return
    }
    const brainChanged = provider() !== props.companion.provider || model() !== props.companion.model
    const saved = await companion.save((roster) => patchCompanion(roster, props.companion.id, {
      name: name(), character: character(), orders: orders(), provider: provider(), model: model(),
    }))
    // The live thread owns the brain of an existing conversation; carry the
    // change over when it is idle so the next turn uses it.
    const live = store.companionPane()
    if (saved && brainChanged && provider() && live && companion.active()?.id === props.companion.id && !store.paneWorking(live)) {
      await store.updateThreadSettings(live, { provider: provider(), model_ref: model() || null })
    }
    if (saved) companion.setView('chat')
  }

  return (
    <form
      class="min-h-0 flex-1 overflow-y-auto px-4 py-4 scrollbar-thin"
      onSubmit={(event) => {
        event.preventDefault()
        void saveChanges()
      }}
    >
      <label class="block text-[12px] font-medium text-[var(--text-muted)]" for="companion-name">Name</label>
      <input
        id="companion-name"
        class={`${fieldClass} mt-1`}
        value={name()}
        maxLength={NAME_MAX_BYTES}
        autocomplete="off"
        onInput={(event) => setName(event.currentTarget.value)}
      />

      <fieldset class="mt-4">
        <legend class="text-[12px] font-medium text-[var(--text-muted)]">Character</legend>
        <div class="mt-1 grid grid-cols-3 gap-2" role="radiogroup" aria-label="Character">
          <For each={COMPANION_CHARACTERS}>
            {(row) => (
              <button
                type="button"
                role="radio"
                aria-checked={character() === row}
                class={`flex flex-col items-center gap-1 rounded-[10px] border px-2 py-2.5 text-[12.5px] ${
                  character() === row
                    ? 'border-[var(--accent)] bg-[var(--accent-wash)]'
                    : 'border-[var(--border-muted)] hover:bg-[var(--accent-hover)]'
                }`}
                title={CHARACTER_INFO[row].tagline}
                onClick={() => setCharacter(row)}
              >
                <CompanionAvatar character={row} pose="idle" class="h-10 w-10" />
                {CHARACTER_INFO[row].name}
              </button>
            )}
          </For>
        </div>
        <p class="mt-1.5 text-[12px] text-[var(--text-subtle)]">{CHARACTER_INFO[character()].tagline}</p>
      </fieldset>

      <label class="mt-4 block text-[12px] font-medium text-[var(--text-muted)]" for="companion-orders">Standing orders</label>
      <textarea
        id="companion-orders"
        class={`${fieldClass} mt-1 min-h-[96px] resize-y`}
        rows={4}
        placeholder="Always run the tests before calling work done."
        value={orders()}
        onInput={(event) => setOrders(event.currentTarget.value)}
      />
      <p class="mt-1 text-[12px] text-[var(--text-subtle)]">Included with every message to {cleanedName() || 'your companion'}.</p>

      <div class="mt-4 grid grid-cols-2 gap-2">
        <label class="block text-[12px] font-medium text-[var(--text-muted)]">
          Brain
          <select
            class={`${fieldClass} mt-1`}
            value={provider()}
            onChange={(event) => {
              setProvider(event.currentTarget.value)
              setModel('')
            }}
          >
            <option value="">New-chat default</option>
            <For each={[...BRAIN_PROVIDERS]}>{(row) => <option value={row}>{providerLabel(row)}</option>}</For>
          </select>
        </label>
        <label class="block text-[12px] font-medium text-[var(--text-muted)]">
          Model
          <select
            class={`${fieldClass} mt-1`}
            value={model()}
            disabled={!provider()}
            onChange={(event) => setModel(event.currentTarget.value)}
          >
            <option value="">Default</option>
            <For each={models()}>{(row) => <option value={row.value}>{row.label}</option>}</For>
          </select>
        </label>
      </div>

      <div class="mt-5 flex flex-wrap items-center gap-2">
        <button
          type="submit"
          class="min-h-[40px] rounded-[7px] bg-[var(--accent)] px-4 text-[13px] font-medium text-black disabled:opacity-40"
          disabled={companion.saving() || !dirty() || !cleanedName()}
        >
          Save
        </button>
        <button
          type="button"
          class="min-h-[40px] rounded-[7px] border border-[var(--border-muted)] px-3 text-[13px] hover:bg-[var(--accent-hover)]"
          onClick={() => companion.setView('chat')}
        >
          Cancel
        </button>
        <Show when={props.companion.thread_id}>
          <button
            type="button"
            class="min-h-[40px] rounded-[7px] border border-[var(--border-muted)] px-3 text-[13px] hover:bg-[var(--accent-hover)] disabled:opacity-40"
            disabled={companion.saving()}
            onClick={() => void companion.save((roster) => patchCompanion(roster, props.companion.id, { thread_id: '' })).then((ok) => { if (ok) companion.setView('chat') })}
          >
            New conversation
          </button>
        </Show>
      </div>

      <div class="mt-6 border-t border-[var(--border-muted)] pt-4">
        <Show
          when={confirmRemove()}
          fallback={
            <button
              type="button"
              class="min-h-[40px] rounded-[7px] border border-[var(--border-muted)] px-3 text-[13px] text-[var(--danger)] hover:bg-[color-mix(in_srgb,var(--danger)_12%,transparent)] disabled:opacity-40"
              disabled={companion.saving() || companions().length <= 1}
              title={companions().length <= 1 ? 'Keep at least one companion' : undefined}
              onClick={() => setConfirmRemove(true)}
            >
              Remove {props.companion.name}
            </button>
          }
        >
          <div class="flex flex-wrap items-center gap-2" role="alert">
            <span class="text-[13px]">Remove {props.companion.name}? Its chat stays in history.</span>
            <button
              type="button"
              class="min-h-[40px] rounded-[7px] bg-[var(--danger)] px-3 text-[13px] font-medium text-black disabled:opacity-40"
              disabled={companion.saving()}
              onClick={() => void companion.save((roster) => removeCompanion(roster, props.companion.id)).then((ok) => { if (ok) companion.setView('chat') })}
            >
              Remove
            </button>
            <button
              type="button"
              class="min-h-[40px] rounded-[7px] border border-[var(--border-muted)] px-3 text-[13px] hover:bg-[var(--accent-hover)]"
              onClick={() => setConfirmRemove(false)}
            >
              Keep
            </button>
          </div>
        </Show>
      </div>
    </form>
  )
}

/**
 * Changes view of the side panel: every uncommitted file across the
 * workspace's repositories, filtered by the chat that claimed it, with a
 * lazily fetched per-file diff (collapsed context, stacked/split). Pressing
 * diff line numbers selects lines on one side to ask a chat about them.
 */
import { For, Show, batch, createEffect, createMemo, createSignal, on, onCleanup } from 'solid-js'

import { type DiffFold, type DiffLineSelection, type DiffSide, changeBar, diffSelectionText, parsePatchLines } from '../lib/diff_lines'
import { SIDE_PANEL_SPLIT_MIN_W, sidePanel } from '../lib/side_panel'
import { store } from '../lib/store'
import type { LivePane } from '../lib/types'
import { unwrapResult } from '../lib/live'
import {
  FILTER_ALL, FULL_CONTEXT_LINES, type ChangesFilter, type FilePatch, type WorkspaceChanges, type WorkspaceFile, type WorkspaceRepo,
  changesErrorText, filterOptions, filterRepos, ownerChip, parseFilePatch, parseWorkspaceChanges, patchKey, repoPromptPath, rpcFailure,
  splitPath, statusLetter, totals, validFilter,
} from '../lib/workspace_changes'
import { DiffLayoutToggle, DiffPatch, diffLayout } from './DiffView'
import { Icon, Spinner } from './Icons'
import { PanelMessage } from './PanelMessage'
import { LinePrompt, openWorkspacePath } from './WorkspaceFiles'

interface PatchState {
  status: 'loading' | 'ready' | 'error'
  /// File facts the patch was fetched for; a change refetches it.
  signature: string
  patch?: FilePatch
  error?: string
  /// The patch carries the whole file as context.
  full?: boolean
  /// Whole-file context was too large to fetch.
  full_unavailable?: boolean
}

/// Quiet period after the last chat.turn entry before Changes re-reads.
const TURN_SETTLE_MS = 2000

/// Selected diff lines of one file; `anchor` is where a shift-press extends from.
type FileLineSelection = DiffLineSelection & { key: string; anchor: number }

const signatureOf = (file: WorkspaceFile) => `${file.status}:${file.untracked}:${file.additions}:${file.deletions}`
// Filter choice per workspace for this page session.
const filters = new Map<string, ChangesFilter>()

export function ChangesView(props: { workspaceId: string; narrow?: boolean }) {
  const [data, setData] = createSignal<WorkspaceChanges | null>(null)
  const [status, setStatus] = createSignal<'loading' | 'ready' | 'error'>('loading')
  const [error, setError] = createSignal('')
  const [filter, setFilterSignal] = createSignal<ChangesFilter>(FILTER_ALL)
  const [expanded, setExpanded] = createSignal<ReadonlySet<string>>(new Set())
  const [patches, setPatches] = createSignal<Record<string, PatchState>>({})
  const [revealed, setRevealed] = createSignal<Record<string, ReadonlySet<number>>>({})
  const [pendingFold, setPendingFold] = createSignal<Record<string, number | null>>({})
  let generation = 0

  const setFilter = (value: ChangesFilter) => { filters.set(props.workspaceId, value); setFilterSignal(value) }

  const load = async (quiet: boolean) => {
    const workspace_id = props.workspaceId
    const gen = ++generation
    if (!quiet || !data()) setStatus('loading')
    try {
      const response = await store.workspaceCall('git.changes.workspace', { workspace_id })
      if (gen !== generation) return
      const failure = rpcFailure(response)
      const next = failure ? null : parseWorkspaceChanges(unwrapResult(response))
      if (!next) { batch(() => { setStatus('error'); setError(changesErrorText(failure?.code, failure?.message)) }); return }
      batch(() => {
        setData(next)
        setFilterSignal(validFilter(next, filter()))
        setStatus('ready')
      })
      refreshExpanded(next)
    } catch (err) {
      if (gen !== generation) return
      batch(() => { setStatus('error'); setError(err instanceof Error ? err.message : 'Could not load changes.') })
    }
  }

  /// Expanded files whose numbers moved get a fresh patch; vanished ones collapse.
  const refreshExpanded = (next: WorkspaceChanges) => {
    const files = new Map<string, { repo: WorkspaceRepo; file: WorkspaceFile }>()
    for (const repo of next.repos) for (const file of repo.files) files.set(patchKey(repo.root, file.path), { repo, file })
    const open = [...expanded()].filter((key) => files.has(key))
    if (open.length !== expanded().size) setExpanded(new Set(open))
    for (const key of open) {
      const { repo, file } = files.get(key)!
      if (patches()[key]?.signature !== signatureOf(file)) void fetchPatch(repo, file, patches()[key]?.full ? FULL_CONTEXT_LINES : null)
    }
  }

  const fetchPatch = async (repo: WorkspaceRepo, file: WorkspaceFile, context_lines: number | null, fold_key?: number) => {
    const key = patchKey(repo.root, file.path)
    const signature = signatureOf(file)
    const previous = patches()[key]
    if (context_lines == null || !previous?.patch) setPatches((all) => ({ ...all, [key]: { ...previous, status: 'loading', signature } }))
    try {
      const params: Record<string, unknown> = { workspace_id: props.workspaceId, root: repo.root, path: file.path }
      if (context_lines != null) params.context_lines = context_lines
      const response = await store.workspaceCall('git.changes.file_patch', params)
      const failure = rpcFailure(response)
      const patch = failure ? null : parseFilePatch(unwrapResult(response))
      if (!patch) {
        setPatches((all) => ({ ...all, [key]: { status: 'error', signature, error: changesErrorText(failure?.code, failure?.message) } }))
        return
      }
      const wanted_full = context_lines != null && context_lines >= FULL_CONTEXT_LINES
      if (wanted_full && (patch.truncated || patch.patch == null) && previous?.patch) {
        // Whole-file context is over the patch cap: keep the short patch.
        setPatches((all) => ({ ...all, [key]: { ...previous, status: 'ready', full_unavailable: true } }))
        store.setNotice('This file is too large to show with full context.')
        return
      }
      batch(() => {
        setPatches((all) => ({ ...all, [key]: { status: 'ready', signature, patch, full: wanted_full } }))
        if (fold_key != null) setRevealed((all) => ({ ...all, [key]: new Set([...(all[key] ?? []), fold_key]) }))
      })
    } catch (err) {
      setPatches((all) => ({ ...all, [key]: { status: 'error', signature, error: err instanceof Error ? err.message : 'Could not load the diff.' } }))
    } finally {
      if (fold_key != null) setPendingFold((all) => ({ ...all, [key]: null }))
    }
  }

  const toggleFile = (repo: WorkspaceRepo, file: WorkspaceFile) => {
    const key = patchKey(repo.root, file.path)
    const next = new Set(expanded())
    if (next.has(key)) { next.delete(key); setExpanded(next); return }
    next.add(key)
    setExpanded(next)
    const cached = patches()[key]
    if (!cached || cached.status === 'error' || cached.signature !== signatureOf(file)) void fetchPatch(repo, file, null)
  }

  const reveal = (repo: WorkspaceRepo, file: WorkspaceFile, fold: DiffFold) => {
    const key = patchKey(repo.root, file.path)
    if (fold.lines) { setRevealed((all) => ({ ...all, [key]: new Set([...(all[key] ?? []), fold.key]) })); return }
    if (patches()[key]?.full_unavailable) { store.setNotice('This file is too large to show with full context.'); return }
    setPendingFold((all) => ({ ...all, [key]: fold.key }))
    void fetchPatch(repo, file, FULL_CONTEXT_LINES, fold.key)
  }

  const [lineSelection, setLineSelection] = createSignal<FileLineSelection | null>(null)
  /// A pressed line number starts a selection (or clears the same single
  /// line); shift extends it on the same side of the same file.
  const selectLine = (key: string, side: DiffSide, line: number, extend: boolean) => {
    const current = lineSelection()
    const same = current?.key === key && current.side === side
    if (same && extend) { setLineSelection({ ...current, start: Math.min(current.anchor, line), end: Math.max(current.anchor, line) }); return }
    if (same && current.start === line && current.end === line) { setLineSelection(null); return }
    setLineSelection({ key, side, anchor: line, start: line, end: line })
  }

  // A new workspace starts over; its last filter choice is kept.
  createEffect(on(() => props.workspaceId, (workspace_id) => {
    generation += 1
    batch(() => {
      setData(null); setExpanded(new Set<string>()); setPatches({}); setRevealed({}); setPendingFold({}); setLineSelection(null)
      setFilterSignal(filters.get(workspace_id) ?? FILTER_ALL)
    })
    void load(false)
  }))
  // Claims move when chats edit files: the summary revision follows them.
  createEffect(on(() => store.gitChanges.summaries()[props.workspaceId]?.revision, (revision, previous) => {
    if (revision !== undefined && previous !== undefined && revision !== previous) void load(true)
  }))
  // A chat may have edited files without moving a claim: re-read once its
  // turn activity settles (no push events for the working tree).
  let turnTimer: ReturnType<typeof setTimeout> | undefined
  createEffect(on(() => store.turnActivity()[props.workspaceId], (count, previous) => {
    if (count === undefined || count === previous) return
    clearTimeout(turnTimer)
    turnTimer = setTimeout(() => void load(true), TURN_SETTLE_MS)
  }, { defer: true }))
  onCleanup(() => clearTimeout(turnTimer))
  // After a commit (or a cancelled sheet), the tree may have changed.
  createEffect(on(() => store.gitChanges.sheetPane() != null, (open, was) => { if (was && !open) void load(true) }))
  // Edits made outside chats only show up on a re-read.
  const onFocus = () => { if (document.visibilityState !== 'hidden') void load(true) }
  window.addEventListener('focus', onFocus)
  onCleanup(() => window.removeEventListener('focus', onFocus))

  const titleFor = (thread_id: string) => {
    const pane = store.openPanes().find((item) => item.kind === 'chat' && item.thread_id === thread_id)
    return pane ? store.paneTitle(pane) : null
  }
  const options = createMemo(() => filterOptions(data(), titleFor))
  const repos = createMemo(() => filterRepos(data(), filter()))
  const sum = createMemo(() => totals(repos()))
  const split = () => !props.narrow && diffLayout() === 'split' && sidePanel.width() >= SIDE_PANEL_SPLIT_MIN_W

  /// Commit… target: the filtered chat, else the focused chat of this workspace.
  const commitPane = (): LivePane | null => {
    const chats = store.openPanes().filter((pane) => pane.kind === 'chat' && pane.thread_id && pane.workspace_id === props.workspaceId)
    const current = filter()
    if (current !== FILTER_ALL && current !== 'unassigned') return chats.find((pane) => pane.thread_id === current) ?? null
    const focused = store.focusedChat()
    return focused && chats.includes(focused) ? focused : chats[0] ?? null
  }
  const commitTitle = () => {
    const pane = commitPane()
    if (pane) return `Review and commit ${store.paneTitle(pane)}'s changes`
    return filter() === FILTER_ALL || filter() === 'unassigned' ? 'Open a chat in this workspace to commit' : 'Open this chat to commit its changes'
  }

  return (
    <div class="flex h-full min-h-0 flex-col">
      <div class="shrink-0 border-b border-[var(--border-muted)] px-3 pt-2.5 pb-2">
        <div class="flex items-center gap-2">
          <div class="mono min-w-0 flex-1 truncate text-[12px] text-[var(--text-muted)]">
            <Show when={data()} fallback={status() === 'loading' ? 'Loading changes…' : ''}>
              {sum().files} {sum().files === 1 ? 'file' : 'files'}
              <span class="ml-2 text-[var(--diff-add)]">+{sum().additions}</span>
              <span class="ml-1.5 text-[var(--danger)]">−{sum().deletions}</span>
            </Show>
          </div>
          <Show when={!props.narrow && sidePanel.width() >= SIDE_PANEL_SPLIT_MIN_W}><DiffLayoutToggle /></Show>
          <button
            type="button"
            class="grid h-7 w-7 shrink-0 place-items-center rounded-[6px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
            aria-label="Refresh changes"
            title="Refresh"
            onClick={() => void load(true)}
          >
            <Show when={status() === 'loading' && data()} fallback={<Icon name="refresh" class="h-4 w-4" />}><Spinner class="h-3.5 w-3.5" /></Show>
          </button>
          <button
            type="button"
            class="h-7 shrink-0 rounded-[6px] border border-[var(--border-muted)] px-2.5 text-[12px] text-[var(--text)] hover:bg-[var(--accent-hover)] disabled:cursor-not-allowed disabled:opacity-50"
            disabled={!commitPane() || sum().files === 0}
            title={commitTitle()}
            onClick={() => { const pane = commitPane(); if (pane) store.gitChanges.openSheet(pane, { mode: 'commit' }) }}
          >
            Commit…
          </button>
        </div>
        <Show when={options().length > 1}>
          <div role="radiogroup" aria-label="Filter changes by chat" class="mt-2 flex gap-1.5 overflow-x-auto pb-0.5 scrollbar-thin">
            <For each={options()}>
              {(option) => (
                <button
                  type="button"
                  role="radio"
                  aria-checked={filter() === option.key}
                  class={`flex h-7 max-w-[14rem] shrink-0 items-center gap-1.5 rounded-full border px-2.5 text-[12px] ${
                    filter() === option.key
                      ? 'border-[color-mix(in_srgb,var(--accent)_55%,var(--border-muted))] bg-[var(--accent-wash)] text-[var(--text)]'
                      : 'border-[var(--border-muted)] text-[var(--text-muted)] hover:text-[var(--text)]'
                  }`}
                  onClick={() => setFilter(option.key)}
                >
                  <span class="truncate">{option.label}</span>
                  <span class="mono text-[11px] text-[var(--text-subtle)]">{option.files}</span>
                </button>
              )}
            </For>
          </div>
        </Show>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto scrollbar-thin">
        <Show when={status() !== 'error' || data()} fallback={<PanelMessage text={error()} action={{ label: 'Retry', run: () => void load(false) }} />}>
          <Show when={data()} fallback={<PanelMessage text="Loading changes…" />}>
            <Show when={repos().length > 0} fallback={<PanelMessage text={filter() === FILTER_ALL ? 'No uncommitted changes in this workspace.' : 'No uncommitted changes for this filter.'} />}>
              <For each={repos()}>
                {(repo) => (
                  <section class="border-b border-[var(--border-muted)] last:border-b-0">
                    <RepoHeader repo={repo} />
                    <Show when={repo.too_many_files}>
                      <p class="px-3 pb-2.5 text-[12px] text-[var(--warning)]">Too many changed files to list here. Use git in a terminal.</p>
                    </Show>
                    <For each={repo.files}>
                      {(file) => {
                        const key = () => patchKey(repo.root, file.path)
                        return (
                          <FileRow
                            repo={repo}
                            file={file}
                            titleFor={titleFor}
                            open={expanded().has(key())}
                            patch={patches()[key()]}
                            revealed={revealed()[key()] ?? new Set<number>()}
                            pendingFold={pendingFold()[key()] ?? null}
                            split={split()}
                            onToggle={() => toggleFile(repo, file)}
                            onReveal={(fold) => reveal(repo, file, fold)}
                            onRetry={() => void fetchPatch(repo, file, null)}
                            onOpen={() => void openWorkspacePath(props.workspaceId, `${repo.root.replace(/\/$/, '')}/${file.path}`)}
                            workspaceId={props.workspaceId}
                            promptPath={repoPromptPath(repo, file.path, store.workspace()?.path)}
                            selection={lineSelection()?.key === key() ? lineSelection() : null}
                            onLine={(side, line, extend) => selectLine(key(), side, line, extend)}
                            onClearSelection={() => setLineSelection(null)}
                          />
                        )
                      }}
                    </For>
                  </section>
                )}
              </For>
            </Show>
          </Show>
        </Show>
      </div>
    </div>
  )
}

function RepoHeader(props: { repo: WorkspaceRepo }) {
  return (
    <div class="flex items-center gap-2 px-3 pt-2.5 pb-1.5 text-[12px]" title={props.repo.root}>
      <Icon name="git" class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)]" />
      <span class="truncate font-medium text-[var(--text)]">{props.repo.name}</span>
      <Show when={props.repo.branch}>
        <span class="mono truncate text-[var(--text-subtle)]">{props.repo.branch}</span>
      </Show>
      <span class="flex-1" />
      <Show when={props.repo.ahead > 0}><span class="mono shrink-0 text-[var(--text-muted)]" title={`${props.repo.ahead} unpushed`}>↑{props.repo.ahead}</span></Show>
      <Show when={props.repo.behind > 0}><span class="mono shrink-0 text-[var(--text-muted)]" title={`${props.repo.behind} behind`}>↓{props.repo.behind}</span></Show>
    </div>
  )
}

function FileRow(props: {
  repo: WorkspaceRepo
  file: WorkspaceFile
  titleFor: (thread_id: string) => string | null
  open: boolean
  patch: PatchState | undefined
  revealed: ReadonlySet<number>
  pendingFold: number | null
  split: boolean
  onToggle: () => void
  onReveal: (fold: DiffFold) => void
  onRetry: () => void
  onOpen: () => void
  workspaceId: string
  promptPath: string
  selection: DiffLineSelection | null
  onLine: (side: DiffSide, line: number, extend: boolean) => void
  onClearSelection: () => void
}) {
  const badge = () => statusLetter(props.file)
  const chip = () => ownerChip(props.file, props.titleFor)
  const parts = () => splitPath(props.file.path)
  return (
    <div class={props.open ? 'bg-[color-mix(in_srgb,var(--panel-alt)_60%,transparent)]' : ''}>
      <button
        type="button"
        class="changes-file-row"
        aria-expanded={props.open}
        aria-label={`${props.open ? 'Collapse' : 'Expand'} diff for ${props.file.path}`}
        title={props.file.path}
        onClick={() => props.onToggle()}
      >
        <span class={`changes-status changes-status-${badge().tone}`} title={badge().label}>{badge().letter}</span>
        <span class="mono min-w-0 flex-1 truncate text-[12.5px]">
          <span class="text-[var(--text-subtle)]">{parts().dir}</span>
          <span class="text-[var(--text)]">{parts().name}</span>
        </span>
        <span class={`changes-owner changes-owner-${chip().tone}`} title={chip().title}>{chip().text}</span>
        <Show when={!props.file.binary} fallback={<span class="mono shrink-0 text-[11px] text-[var(--text-subtle)]">bin</span>}>
          <span class="mono shrink-0 text-[11px] text-[var(--diff-add)]">+{props.file.additions}</span>
          <span class="mono shrink-0 text-[11px] text-[var(--danger)]">−{props.file.deletions}</span>
          <span class="changes-bar" aria-hidden="true">
            <For each={changeBar(props.file.additions, props.file.deletions)}>{(cell) => <span class={`changes-bar-${cell}`} />}</For>
          </span>
        </Show>
      </button>
      <Show when={props.open}>
        <div class="px-3 pb-2">
          <div class="mb-1.5 flex items-center gap-2">
            <button type="button" class="diff-action" aria-label={`Open ${props.file.path}`} onClick={() => props.onOpen()} disabled={props.file.status === 'deleted'}>Open</button>
          </div>
          <PatchBody
            patch={props.patch}
            file={props.file}
            revealed={props.revealed}
            pendingFold={props.pendingFold}
            split={props.split}
            onReveal={props.onReveal}
            onRetry={props.onRetry}
            workspaceId={props.workspaceId}
            promptPath={props.promptPath}
            selection={props.selection}
            onLine={props.onLine}
            onClearSelection={props.onClearSelection}
          />
        </div>
      </Show>
    </div>
  )
}

function PatchBody(props: {
  patch: PatchState | undefined
  file: WorkspaceFile
  revealed: ReadonlySet<number>
  pendingFold: number | null
  split: boolean
  onReveal: (fold: DiffFold) => void
  onRetry: () => void
  workspaceId: string
  promptPath: string
  selection: DiffLineSelection | null
  onLine: (side: DiffSide, line: number, extend: boolean) => void
  onClearSelection: () => void
}) {
  const note = (text: string) => <p class="py-2 text-[12px] text-[var(--text-muted)]">{text}</p>
  return (
    <Show when={props.patch && props.patch.status !== 'loading'} fallback={note('Loading diff…')}>
      <Show
        when={props.patch!.status === 'ready' && props.patch!.patch}
        fallback={
          <Show when={props.patch!.status === 'error'} fallback={note('Loading diff…')}>
            <div class="flex items-center gap-2 py-2 text-[12px] text-[var(--danger)]">
              <span class="min-w-0 flex-1">{props.patch!.error}</span>
              <button type="button" class="diff-action" onClick={() => props.onRetry()}>Retry</button>
            </div>
          </Show>
        }
      >
        {(patch) => (
          <Show when={!patch().clean} fallback={note('This file is no longer changed.')}>
            <Show when={!patch().binary} fallback={note('Binary file — no text diff.')}>
              <Show when={!patch().truncated && patch().patch != null} fallback={note('This diff is too large to show here.')}>
                <DiffPatch
                  patch={patch().patch!}
                  path={props.file.path}
                  split={props.split}
                  fold={{ revealed: props.revealed, onReveal: props.onReveal, pending: props.pendingFold }}
                  select={{ selection: props.selection, onLine: props.onLine }}
                />
                <Show when={props.selection}>
                  {(selection) => (
                    <LinePrompt
                      range={{ start: selection().start, end: selection().end, text: diffSelectionText(parsePatchLines(patch().patch!), selection()) }}
                      side={selection().side}
                      workspaceId={props.workspaceId}
                      displayPath={props.promptPath}
                      onClose={() => props.onClearSelection()}
                      onSent={(chat) => { props.onClearSelection(); store.setNotice(`Sent to ${chat}`) }}
                    />
                  )}
                </Show>
              </Show>
            </Show>
          </Show>
        )}
      </Show>
    </Show>
  )
}

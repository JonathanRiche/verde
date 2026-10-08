import { For, Show, createEffect, createMemo, createSignal, on, onCleanup } from 'solid-js'

import {
  canSelectHunks, commitButtonLabel, commitSubject, fileKey, hunkTicked, isCommitShortcut, normalizeTick, ownershipLabel, toastAutoDismisses, toggleFileTick, toggleHunkTick,
  type CommitAction, type GitToastTone, type Ownership, type ReviewFile, type ReviewRepo,
} from '../lib/git_changes'
import { store } from '../lib/store'
import { DiffPatch } from './DiffView'
import { Icon, Spinner } from './Icons'

const git = store.gitChanges
const OWNERSHIP_TAGS: Record<Ownership, string> = { mine: '', shared: 'Shared', unclear: 'Unclear', unassigned: 'Unassigned' }

/// Commit dialog, default-branch confirm, and the result toast; mounted once by App.
export function GitChangesLayer() {
  return (
    <>
      <CommitSheet />
      <DefaultBranchConfirm />
      <GitToast />
    </>
  )
}

/// Focus trap + Escape/Ctrl+Enter for a modal panel. Capture phase: the modal
/// owns the keyboard while open, so app keybinds never fire underneath it.
function trapModal(panel: () => HTMLElement | undefined, onEscape: () => void, onSubmit?: () => void) {
  const restore = document.activeElement instanceof HTMLElement ? document.activeElement : null
  const focusable = () => [...(panel()?.querySelectorAll<HTMLElement>(
    'button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex="-1"])',
  ) ?? [])].filter((element) => element.getClientRects().length > 0)
  const onKey = (event: KeyboardEvent) => {
    const root = panel()
    if (event.key === 'Escape' && !event.isComposing) {
      event.preventDefault()
      event.stopPropagation()
      onEscape()
      return
    }
    if (onSubmit && isCommitShortcut(event)) {
      event.preventDefault()
      event.stopPropagation()
      onSubmit()
      return
    }
    if (event.key === 'Tab') {
      event.stopPropagation()
      const items = focusable()
      const first = items[0], last = items.at(-1)
      const active = document.activeElement
      if (!first || !root?.contains(active) || active === root || (event.shiftKey ? active === first : active === last)) {
        event.preventDefault()
        ;(event.shiftKey ? last : first)?.focus()
      }
      return
    }
    // Capture stops the event before it reaches the target, so focusable
    // non-button rows (`data-key-activate`) are activated here.
    const active = document.activeElement
    if ((event.key === ' ' || event.key === 'Enter') && !event.ctrlKey && !event.metaKey && !event.altKey && !event.isComposing
      && active instanceof HTMLElement && root?.contains(active) && active.hasAttribute('data-key-activate')) {
      event.preventDefault()
      event.stopPropagation()
      if (!event.repeat) active.click()
      return
    }
    if (root?.contains(document.activeElement) || document.activeElement === document.body) event.stopPropagation()
  }
  window.addEventListener('keydown', onKey, true)
  onCleanup(() => {
    window.removeEventListener('keydown', onKey, true)
    if (restore?.isConnected) restore.focus()
  })
}

const PRIMARY_BUTTON = 'h-9 rounded-[7px] bg-[var(--accent)] px-4 text-[13px] font-bold text-[#0d1213] hover:bg-[var(--accent-hi)] disabled:cursor-not-allowed disabled:opacity-40'
const SECONDARY_BUTTON = 'h-9 rounded-[7px] border border-[var(--border-muted)] px-3 text-[13px] text-[var(--text)] hover:bg-[var(--accent-hover)] disabled:cursor-not-allowed disabled:opacity-40'

function CommitSheet() {
  let panel: HTMLDivElement | undefined
  const open = () => git.sheetPane() !== null
  const review = () => git.review()
  const title = () => { const pane = git.sheetPane(); return pane ? store.paneTitle(pane) : '' }
  const repos = () => review()?.repos.filter((repo) => repo.files.length > 0) ?? []
  const fileCount = createMemo(() => review()?.repos.reduce((total, repo) => total + repo.files.length, 0) ?? 0)
  const submit = () => { if (git.canCommit()) void git.commit(git.primaryAction()) }

  createEffect(() => {
    if (!open()) return
    queueMicrotask(() => panel?.focus())
    trapModal(() => panel, () => git.closeSheet(), submit)
  })

  const primaryLabel = () => commitButtonLabel(git.primaryAction(), false, git.busy())
  const alternateLabel = (action: CommitAction) => commitButtonLabel(action, false, git.busy())
  const branchLabel = () => commitButtonLabel(git.primaryAction(), true, git.busy())
  /// Tab in an empty box copies the suggestion in for editing.
  const onMessageKey = (event: KeyboardEvent & { currentTarget: HTMLTextAreaElement }) => {
    if (event.key !== 'Tab' || event.shiftKey || event.currentTarget.value || !git.generated()) return
    event.preventDefault()
    git.setMessage(git.generated()!)
  }

  return (
    <Show when={open()}>
      <div class="anim-fade absolute inset-0 z-40 bg-black/55" onClick={() => git.closeSheet()}>
        <div
          class="anim-pop absolute top-12 left-1/2 flex max-h-[calc(100%-4rem)] w-[40rem] max-w-[calc(100vw-2rem)] -translate-x-1/2 flex-col rounded-[12px] border border-[var(--border-muted)] bg-[var(--panel)] outline-none max-md:top-auto max-md:right-3 max-md:bottom-[calc(0.75rem+var(--safe-bottom))] max-md:left-3 max-md:max-h-[calc(100%-1.5rem-var(--safe-top)-var(--safe-bottom))] max-md:w-auto max-md:translate-x-0 max-md:rounded-[14px]"
          role="dialog"
          aria-modal="true"
          aria-labelledby="commit-sheet-title"
          tabindex="-1"
          ref={(node) => { panel = node }}
          onClick={(event) => event.stopPropagation()}
        >
          <div class="flex shrink-0 items-start gap-3 px-5 pt-4 pb-2">
            <div class="min-w-0 flex-1">
              <div id="commit-sheet-title" class="text-[16px] font-medium">Commit changes</div>
              <div class="mt-0.5 truncate text-[12.5px] text-[var(--text-muted)]">
                Files this chat changed{title() ? ` in “${title()}”` : ''}. Files other chats touched stay out unless you add them.
              </div>
            </div>
            <button type="button" class="grid h-8 w-8 shrink-0 place-items-center rounded-[7px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)]" aria-label="Close" onClick={() => git.closeSheet()}>✕</button>
          </div>

          <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 py-2 scrollbar-thin">
            <Show when={review()?.turn_running}>
              <p class="mb-3 rounded-[8px] border border-[color-mix(in_srgb,var(--warning)_45%,var(--border-muted))] px-3 py-2 text-[12.5px] text-[var(--warning)]">
                This chat is still working, so this shows its changes as of now.
              </p>
            </Show>
            <Show when={git.reviewStatus() === 'loading' && !review()}>
              <p role="status" class="py-6 text-center text-[13px] text-[var(--text-muted)]">Loading changes…</p>
            </Show>
            <Show when={git.reviewStatus() === 'error' && !review()}>
              <div class="flex items-center justify-between gap-4 py-4">
                <p role="alert" class="text-[13px] text-[var(--warning)]">{git.error() ?? 'Could not load changes.'}</p>
                <button type="button" class={SECONDARY_BUTTON} onClick={() => void git.reloadReview()}>Retry</button>
              </div>
            </Show>
            <Show when={review() && fileCount() === 0}>
              <p class="py-6 text-center text-[13px] text-[var(--text-muted)]">No uncommitted changes for this chat.</p>
            </Show>

            <Show when={review() && fileCount() > 0}>
              <div class="space-y-3 rounded-[10px] border border-[var(--border-muted)] bg-[color-mix(in_srgb,var(--panel-alt)_55%,transparent)] p-3 text-[13px]">
                <div class="grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-1">
                  <For each={repos()}>
                    {(repo) => (
                      <>
                        <span class="text-[var(--text-muted)]">{repos().length > 1 ? repo.name : 'Branch'}</span>
                        <span class="flex min-w-0 items-center justify-between gap-2">
                          <span class="mono truncate font-medium">{repo.branch ?? '(detached HEAD)'}</span>
                          <Show when={repo.is_default_branch}>
                            <span class="shrink-0 text-right text-[12px] text-[var(--warning)]">Warning: default branch</span>
                          </Show>
                        </span>
                      </>
                    )}
                  </For>
                </div>

                <div>
                  <div class="mb-1.5 flex items-center justify-between">
                    <span class="text-[var(--text-muted)]">
                      Files
                      <Show when={git.selectedFiles() !== fileCount()}>
                        <span class="text-[var(--text-subtle)]"> ({git.selectedFiles()} of {fileCount()})</span>
                      </Show>
                    </span>
                    <button
                      type="button"
                      class="h-7 rounded-[6px] px-2 text-[12.5px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
                      aria-pressed={git.diffsShown()}
                      onClick={() => git.setDiffsShown(!git.diffsShown())}
                    >{git.diffsShown() ? 'Hide diffs' : 'Show diffs'}</button>
                  </div>
                  <div class={`overflow-y-auto overscroll-contain rounded-[8px] border border-[var(--border-muted)] bg-[var(--chat-black)] p-1 scrollbar-thin ${git.diffsShown() ? 'max-h-[22rem]' : 'max-h-60'}`}>
                    <For each={repos()}>
                      {(repo) => <RepoGroup repo={repo} multiple={repos().length > 1} />}
                    </For>
                  </div>
                  <div class="mono mt-1.5 flex justify-end gap-1 text-[12px]">
                    <span class="text-[var(--diff-add)]">+{git.totals().additions}</span>
                    <span class="text-[var(--text-subtle)]">/</span>
                    <span class="text-[var(--danger)]">−{git.totals().deletions}</span>
                  </div>
                </div>
              </div>

              <div class="mt-4 pb-1">
                <div class="flex items-center justify-between gap-2">
                  <label for="commit-sheet-message" class="text-[13px] font-medium">Commit message <span class="font-normal text-[var(--text-subtle)]">(optional)</span></label>
                  <div class="flex items-center gap-2 text-[11.5px] text-[var(--text-subtle)]">
                    <Show when={git.messageStatus() === 'idle' && git.generated() && !git.message()}><span class="max-md:hidden">Tab to edit</span></Show>
                    <Show when={git.messageStatus() === 'idle' && git.messageSource()}><span class="max-md:hidden">{git.messageSource()}</span></Show>
                    <button
                      type="button"
                      class="grid h-7 w-7 place-items-center rounded-[6px] text-[14px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] disabled:opacity-40"
                      aria-label="Regenerate commit message from the selected changes"
                      title="Regenerate from the selected changes"
                      disabled={git.messageStatus() === 'writing' || git.selectedFiles() === 0}
                      onClick={() => void git.regenerateMessage()}
                    >↻</button>
                  </div>
                </div>
                <textarea
                  id="commit-sheet-message"
                  class="mono mt-1.5 block h-20 w-full resize-y rounded-[8px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 py-2 text-[13px] leading-[1.45] text-[var(--text)] outline-none placeholder:text-[var(--text-subtle)] focus:border-[var(--accent)]"
                  placeholder={git.placeholder()}
                  value={git.message()}
                  onInput={(event) => git.setMessage(event.currentTarget.value)}
                  onKeyDown={onMessageKey}
                />
                <Show when={git.error()}>
                  <p role="alert" class="mt-2 text-[12.5px] text-[var(--warning)]">{git.error()}</p>
                </Show>
              </div>
            </Show>
          </div>

          <Show when={review() && fileCount() > 0}>
            <div class="flex shrink-0 flex-wrap items-center justify-end gap-2 px-5 pt-2 pb-4">
              <span class="mr-auto text-[12px] text-[var(--text-subtle)] max-md:hidden">Ctrl+Enter to {commitButtonLabel(git.primaryAction(), false, null).toLowerCase()}</span>
              <button type="button" class={SECONDARY_BUTTON} onClick={() => git.closeSheet()}>Cancel</button>
              <button
                type="button"
                class={SECONDARY_BUTTON}
                disabled={!git.canCommit()}
                title={git.branchSuggestion() ? `New branch: ${git.branchSuggestion()}` : 'Create a feature branch at HEAD and commit there'}
                onClick={() => void git.commit(git.primaryAction(), true)}
              >{branchLabel()}</button>
              <Show when={git.alternateAction()}>
                {(action) => (
                  <button type="button" class={SECONDARY_BUTTON} disabled={!git.canCommit()} onClick={() => void git.commit(action())}>
                    {alternateLabel(action())}
                  </button>
                )}
              </Show>
              <button type="button" class={PRIMARY_BUTTON} disabled={!git.canCommit()} onClick={submit}>{primaryLabel()}</button>
            </div>
          </Show>
        </div>
      </div>
    </Show>
  )
}

/// "Commit & push to main?" — asked before the quick path lands on the default branch.
function DefaultBranchConfirm() {
  let panel: HTMLDivElement | undefined
  // Keyed on open/closed only: the confirm object is replaced when the
  // message arrives, which must not remount the dialog or move focus.
  const open = createMemo(() => git.confirm() !== null)
  createEffect(() => {
    if (!open()) return
    queueMicrotask(() => panel?.focus())
    trapModal(() => panel, () => void git.resolveConfirm('abort'))
  })
  return (
    <Show when={open()}>
      {(_open) => {
        const confirm = () => git.confirm() ?? { branch: '', files: 0, status: 'writing', message: '', branch_name: null }
        const ready = () => confirm().status === 'ready'
        const subject = () => (ready() ? commitSubject(confirm().message) : 'Writing message…')
        return (
          <div class="anim-fade absolute inset-0 z-40 bg-black/55" onClick={() => void git.resolveConfirm('abort')}>
            <div
              class="anim-pop absolute top-24 left-1/2 w-[34rem] max-w-[calc(100vw-2rem)] -translate-x-1/2 rounded-[12px] border border-[var(--border-muted)] bg-[var(--panel)] px-5 pt-4 pb-4 outline-none max-md:top-auto max-md:right-3 max-md:bottom-[calc(0.75rem+var(--safe-bottom))] max-md:left-3 max-md:w-auto max-md:translate-x-0"
              role="alertdialog"
              aria-modal="true"
              aria-labelledby="default-branch-title"
              aria-describedby="default-branch-detail"
              tabindex="-1"
              ref={(node) => { panel = node }}
              onClick={(event) => event.stopPropagation()}
            >
              <div id="default-branch-title" class="text-[16px] font-medium">Commit & push to <span class="mono">{confirm().branch}</span>?</div>
              <p id="default-branch-detail" class="mt-1 truncate text-[12.5px] text-[var(--text-muted)]" role="status">
                {confirm().files} {confirm().files === 1 ? 'file' : 'files'} · <span class={ready() ? 'mono text-[var(--text)]' : ''}>{subject()}</span>
              </p>
              <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
                <button type="button" class={`${SECONDARY_BUTTON} mr-auto`} onClick={() => void git.resolveConfirm('abort')}>Abort</button>
                <button type="button" class={SECONDARY_BUTTON} disabled={!ready()} onClick={() => void git.resolveConfirm('push')}>
                  Commit & push to <span class="mono">{confirm().branch}</span>
                </button>
                <button
                  type="button"
                  class={PRIMARY_BUTTON}
                  disabled={!ready()}
                  title={confirm().branch_name ? `New branch: ${confirm().branch_name}` : undefined}
                  onClick={() => void git.resolveConfirm('new_branch')}
                >Create branch & continue</button>
              </div>
            </div>
          </div>
        )
      }}
    </Show>
  )
}

function RepoGroup(props: { repo: ReviewRepo; multiple: boolean }) {
  return (
    <section>
      <Show when={props.multiple}>
        <div class="px-2 pt-1.5 pb-0.5 text-[11px] font-bold uppercase tracking-[0.08em] text-[var(--text-subtle)]">{props.repo.name}</div>
      </Show>
      <For each={props.repo.files}>
        {(file) => <FileRow root={props.repo.root} file={file} />}
      </For>
    </section>
  )
}

/// One file: clicking the row (or Space/Enter on it, via trapModal) toggles the whole file;
/// the chevron expands its hunks. Excluded files are dimmed; files that are
/// not only this chat's carry a tag.
function FileRow(props: { root: string; file: ReviewFile }) {
  const [expanded, setExpanded] = createSignal(git.diffsShown())
  // Show/Hide diffs expands or collapses every file.
  createEffect(on(git.diffsShown, (shown) => setExpanded(shown), { defer: true }))
  const tick = () => normalizeTick(props.file, git.ticks()[fileKey(props.root, props.file.path)])
  const partial = () => Array.isArray(tick())
  const excluded = () => tick() === 'none'
  const tag = () => OWNERSHIP_TAGS[props.file.ownership]
  const hunks = () => canSelectHunks(props.file)
  const wholePatch = () => props.file.hunks.map((hunk) => hunk.text).join('\n')
  const toggle = () => git.setFileTick(props.root, props.file, toggleFileTick(tick()))
  return (
    <div class="border-b border-[var(--border-muted)] last:border-b-0">
      <div
        class="mono flex min-h-[32px] cursor-pointer items-center gap-2 rounded-[6px] px-1.5 text-[12.5px] outline-none select-none hover:bg-[var(--accent-hover)] focus-visible:ring-1 focus-visible:ring-[var(--accent)]"
        role="checkbox"
        tabindex="0"
        aria-checked={partial() ? 'mixed' : !excluded()}
        aria-label={`Include ${props.file.path}`}
        title={`${props.file.path}${excluded() ? ' (excluded)' : ''}`}
        data-key-activate
        onClick={toggle}
      >
        <input
          type="checkbox"
          class="pointer-events-none h-4 w-4 shrink-0 accent-[var(--accent)]"
          tabindex="-1"
          aria-hidden="true"
          checked={!excluded()}
          ref={(node) => createEffect(() => { node.indeterminate = partial() })}
        />
        <button
          type="button"
          class="grid h-6 w-5 shrink-0 place-items-center rounded-[5px] text-[11px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
          aria-expanded={expanded()}
          aria-label={`${expanded() ? 'Hide' : 'Show'} diff for ${props.file.path}`}
          onClick={(event) => { event.stopPropagation(); setExpanded((value) => !value) }}
        >{expanded() ? '▾' : '▸'}</button>
        <span class={`min-w-0 flex-1 truncate text-[var(--text)] ${excluded() ? 'opacity-45' : ''}`}>{props.file.path}</span>
        <Show when={tag()}>
          <span class="shrink-0 rounded-full bg-[color-mix(in_srgb,var(--warning)_14%,transparent)] px-1.5 py-px font-sans text-[10.5px] text-[var(--warning)]" title={ownershipLabel(props.file)}>{tag()}</span>
        </Show>
        <Show when={partial()}>
          <span class="shrink-0 font-sans text-[10.5px] text-[var(--text-subtle)]">partial</span>
        </Show>
        <span class={`shrink-0 whitespace-nowrap ${excluded() ? 'opacity-45' : ''}`}>
          <span class="text-[var(--diff-add)]">+{props.file.additions}</span>
          <span class="text-[var(--text-subtle)]"> / </span>
          <span class="text-[var(--danger)]">−{props.file.deletions}</span>
        </span>
      </div>
      <Show when={expanded()}>
        <div class="pb-2 pl-6">
          <Show when={props.file.binary}>
            <p class="py-1 text-[12px] text-[var(--text-muted)]">Binary file — can only be committed whole.</p>
          </Show>
          <Show when={!props.file.binary && props.file.preview_truncated}>
            <p class="py-1 text-[12px] text-[var(--text-muted)]">Diff too large to preview — can only be committed whole.</p>
          </Show>
          <Show when={!props.file.binary && !props.file.preview_truncated}>
            <Show
              when={hunks()}
              fallback={
                <Show when={props.file.hunks.length > 0} fallback={<p class="py-1 text-[12px] text-[var(--text-muted)]">No textual diff.</p>}>
                  <DiffPatch patch={wholePatch()} path={props.file.path} />
                </Show>
              }
            >
              <For each={props.file.hunks}>
                {(hunk) => (
                  <div class="flex items-start gap-2">
                    <input
                      type="checkbox"
                      class="mt-1 h-4 w-4 shrink-0 accent-[var(--accent)]"
                      checked={hunkTicked(tick(), hunk.index)}
                      aria-label={`Include hunk ${hunk.header || hunk.index + 1} of ${props.file.path}`}
                      onChange={() => git.setFileTick(props.root, props.file, toggleHunkTick(props.file, tick(), hunk.index))}
                    />
                    <div class="min-w-0 flex-1"><DiffPatch patch={hunk.text} path={props.file.path} /></div>
                  </div>
                )}
              </For>
            </Show>
          </Show>
        </div>
      </Show>
    </div>
  )
}

const GIT_TOAST_MS = 5000

const TONE_COLOR: Record<GitToastTone, string> = {
  running: 'text-[var(--text-muted)]',
  success: 'text-[var(--diff-add)]',
  info: 'text-[var(--text-muted)]',
  warning: 'text-[var(--warning)]',
  error: 'text-[var(--danger)]',
}

/// State icon: spinner while running, check on success, ! on failure.
function GitToneIcon(props: { tone: GitToastTone; class?: string }) {
  const size = () => props.class ?? 'h-4 w-4'
  return (
    <Show when={props.tone !== 'running'} fallback={<Spinner class={`${size()} ${TONE_COLOR.running}`} />}>
      <Show when={props.tone === 'success' || props.tone === 'info'} fallback={
        <svg class={`${size()} shrink-0 ${TONE_COLOR[props.tone]}`} viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="12" cy="12" r="8.2" fill="none" stroke="currentColor" stroke-width="1.7" />
          <path d="M12 8v4.6 M12 15.8h.01" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" />
        </svg>
      }>
        <Icon name="check" class={`${size()} shrink-0 ${TONE_COLOR[props.tone]}`} />
      </Show>
    </Show>
  )
}

/// Bottom card for every git action (header button, dialog, quick path).
/// Success auto-dismisses; warnings and errors wait for ×.
function GitToast() {
  createEffect(() => {
    const toast = git.toast()
    if (!toast || !toastAutoDismisses(toast.tone)) return
    const timer = setTimeout(() => { if (git.toast()?.id === toast.id) git.dismissToast() }, GIT_TOAST_MS)
    onCleanup(() => clearTimeout(timer))
  })
  return (
    <div role="status" aria-live="polite" class="pointer-events-none absolute inset-x-0 bottom-[calc(72px+var(--safe-bottom))] z-50 flex justify-center px-3">
      <Show when={git.toast()} keyed>
        {(toast) => (
          <div
            class={`anim-reveal pointer-events-auto flex w-full max-w-[30rem] items-start gap-3 rounded-[10px] border bg-[var(--panel)] px-3.5 py-2.5 text-[13px] text-[var(--text)] shadow-lg ${
              toast.tone === 'error' ? 'border-[color-mix(in_srgb,var(--danger)_45%,var(--border-muted))]'
                : toast.tone === 'warning' ? 'border-[color-mix(in_srgb,var(--warning)_40%,var(--border-muted))]' : 'border-[var(--border-muted)]'
            } ${toastAutoDismisses(toast.tone) ? 'cursor-pointer' : ''}`}
            onClick={() => { if (toastAutoDismisses(toast.tone)) git.dismissToast() }}
          >
            <span class="mt-px grid h-[18px] shrink-0 place-items-center"><GitToneIcon tone={toast.tone} /></span>
            <div class="min-w-0 flex-1">
              <div class="break-words font-semibold">{toast.title}</div>
              <Show when={toast.detail}>
                <div class="mt-0.5 truncate text-[12px] text-[var(--text-subtle)]" title={toast.detail ?? undefined}>{toast.detail}</div>
              </Show>
              <Show when={toast.error}>
                <div class={`mt-1 whitespace-pre-wrap break-words text-[12.5px] ${toast.tone === 'error' ? 'text-[var(--danger)]' : 'text-[var(--warning)]'}`}>{toast.error}</div>
              </Show>
            </div>
            <Show when={toast.action}>
              {(action) => (
                <button type="button" class="h-8 shrink-0 self-center rounded-[7px] bg-[var(--accent)] px-3 text-[12.5px] font-bold text-[#0d1213] hover:bg-[var(--accent-hi)]"
                  onClick={(event) => { event.stopPropagation(); const run = action().run; git.dismissToast(); run() }}>
                  {action().label}
                </button>
              )}
            </Show>
            <Show when={toast.tone !== 'running'}>
              <button type="button" class="grid h-7 w-7 shrink-0 place-items-center rounded-[6px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)]" aria-label="Dismiss"
                onClick={(event) => { event.stopPropagation(); git.dismissToast() }}>✕</button>
            </Show>
          </div>
        )}
      </Show>
    </div>
  )
}

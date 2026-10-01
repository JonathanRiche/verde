/**
 * Per-chat git change review and user-initiated commits (daemon
 * `git.changes.*`, see headless git_changes_protocol.zig). Summaries live in
 * their own small slice so chip/dot refreshes never rebuild the projection.
 * Nothing here commits without an explicit click.
 */
import { batch, createEffect, createMemo, createSignal, on, untrack } from 'solid-js'

import { unwrapResult } from './live'
import type { RpcEnvelope } from './types'

export type Ownership = 'mine' | 'shared' | 'unclear' | 'unassigned'
export type CommitAction = 'commit' | 'commit_and_push'

export interface ThreadChangeSummary {
  local_thread_id: string
  files: number
  additions: number
  deletions: number
  /// Files shared with another chat or with an unclear owner.
  attention: number
}

export interface WorkspaceChangeSummary {
  workspace_id: string
  revision: number
  threads: Record<string, ThreadChangeSummary>
}

export interface ReviewHunk { index: number; header: string; text: string }
export interface ReviewFile {
  path: string
  status: string
  ownership: Ownership
  other_threads: Array<{ local_thread_id: string; title: string }>
  additions: number
  deletions: number
  binary: boolean
  hunk_selectable: boolean
  preview_truncated: boolean
  hunks: ReviewHunk[]
}

/// Branch facts for one repository (`git.changes.status` and each review repo).
/// Computed without fetching, so ahead/behind are against the last fetch.
export interface RepoStatus {
  root: string
  name: string
  branch: string | null
  default_branch: string | null
  is_default_branch: boolean
  upstream: string | null
  ahead: number
  behind: number
  has_remote: boolean
}
export interface StatusResult { workspace_id: string; local_thread_id: string; repos: RepoStatus[] }

export interface ReviewRepo extends RepoStatus { head: string | null; files: ReviewFile[] }
export interface ReviewResult {
  review_id: string
  workspace_id: string
  local_thread_id: string
  turn_running: boolean
  default_action: CommitAction
  repos: ReviewRepo[]
}

export interface FileSelection { path: string; hunks?: number[] }
export interface RepoSelection { root: string; files: FileSelection[] }

export interface RepoCommit {
  root: string
  commit: string
  short_commit: string
  subject: string
  files: number
  branch?: string | null
  branch_created?: boolean
  push: 'not_requested' | 'pushed' | 'rejected' | 'failed' | string
  push_message: string | null
  index_reset: boolean
}
export interface CommitResult { workspace_id: string; local_thread_id: string; files: number; repos: RepoCommit[] }

export interface CommitRequest {
  review_id: string
  message: string
  selections: RepoSelection[]
  push: boolean
  new_branch?: boolean
  branch_name?: string
}

/// A file is either wholly ticked, unticked, or ticked for these hunk indices.
export type FileTick = 'all' | 'none' | number[]
export type Ticks = Record<string, FileTick>

// ---- Pure helpers ----------------------------------------------------------

const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0)
const str = (value: unknown): string => (typeof value === 'string' ? value : '')
const OWNERSHIPS: readonly Ownership[] = ['mine', 'shared', 'unclear', 'unassigned']

export function parseSummaryResult(value: unknown): WorkspaceChangeSummary | null {
  const root = value as { workspace_id?: unknown; revision?: unknown; threads?: unknown } | null
  if (!root || typeof root !== 'object' || typeof root.workspace_id !== 'string') return null
  const threads: Record<string, ThreadChangeSummary> = {}
  for (const row of Array.isArray(root.threads) ? root.threads : []) {
    const id = str(row?.local_thread_id)
    if (!id) continue
    threads[id] = { local_thread_id: id, files: num(row.files), additions: num(row.additions), deletions: num(row.deletions), attention: num(row.attention) }
  }
  return { workspace_id: root.workspace_id, revision: num(root.revision), threads }
}

const optStr = (value: unknown): string | null => (typeof value === 'string' && value ? value : null)

function parseRepoStatus(repo: Record<string, unknown> & { root: string }): RepoStatus {
  return {
    root: repo.root, name: str(repo.name) || repo.root.split('/').filter(Boolean).at(-1) || repo.root,
    branch: optStr(repo.branch), default_branch: optStr(repo.default_branch),
    is_default_branch: repo.is_default_branch === true, upstream: optStr(repo.upstream),
    ahead: num(repo.ahead), behind: num(repo.behind), has_remote: repo.has_remote === true,
  }
}

export function parseStatusResult(value: unknown): StatusResult | null {
  const root = value as Record<string, unknown> | null
  if (!root || typeof root !== 'object' || typeof root.local_thread_id !== 'string') return null
  const repos = (Array.isArray(root.repos) ? root.repos : []).flatMap((repo: Record<string, unknown>) =>
    repo && typeof repo.root === 'string' && repo.root ? [parseRepoStatus(repo as Record<string, unknown> & { root: string })] : [])
  return { workspace_id: str(root.workspace_id), local_thread_id: root.local_thread_id, repos }
}

export function parseReviewResult(value: unknown): ReviewResult | null {
  const root = value as Record<string, unknown> | null
  if (!root || typeof root !== 'object' || typeof root.review_id !== 'string' || !root.review_id) return null
  const repos: ReviewRepo[] = (Array.isArray(root.repos) ? root.repos : []).flatMap((repo: Record<string, unknown>) => {
    if (!repo || typeof repo.root !== 'string') return []
    const files: ReviewFile[] = (Array.isArray(repo.files) ? repo.files : []).flatMap((file: Record<string, unknown>) => {
      if (!file || typeof file.path !== 'string' || !file.path) return []
      const ownership = OWNERSHIPS.includes(file.ownership as Ownership) ? file.ownership as Ownership : 'unclear'
      const hunks = (Array.isArray(file.hunks) ? file.hunks : []).flatMap((hunk: Record<string, unknown>) =>
        hunk && typeof hunk.index === 'number' && typeof hunk.text === 'string'
          ? [{ index: hunk.index, header: str(hunk.header), text: hunk.text }] : [])
      const other_threads = (Array.isArray(file.other_threads) ? file.other_threads : []).flatMap((row: Record<string, unknown>) =>
        row && typeof row.local_thread_id === 'string' ? [{ local_thread_id: row.local_thread_id, title: str(row.title) }] : [])
      return [{
        path: file.path, status: str(file.status) || 'modified', ownership, other_threads,
        additions: num(file.additions), deletions: num(file.deletions),
        binary: file.binary === true, hunk_selectable: file.hunk_selectable === true,
        preview_truncated: file.preview_truncated === true, hunks,
      }]
    })
    return [{ ...parseRepoStatus(repo as Record<string, unknown> & { root: string }), head: typeof repo.head === 'string' ? repo.head : null, files }]
  })
  return {
    review_id: root.review_id, workspace_id: str(root.workspace_id), local_thread_id: str(root.local_thread_id),
    turn_running: root.turn_running === true,
    default_action: root.default_action === 'commit_and_push' ? 'commit_and_push' : 'commit',
    repos,
  }
}

/// Header chip `● 4 files +120 −30`; hidden when the chat owns no files.
export function summaryChip(summary: ThreadChangeSummary | null | undefined): { visible: boolean; text: string; attention: boolean; label: string } {
  if (!summary || summary.files === 0) return { visible: false, text: '', attention: false, label: '' }
  const files = `${summary.files} ${summary.files === 1 ? 'file' : 'files'}`
  const attention = summary.attention > 0
  return {
    visible: true, attention,
    text: `● ${files} +${summary.additions} −${summary.deletions}`,
    label: `Review ${files} changed by this chat${attention ? `, ${summary.attention} need attention` : ''}`,
  }
}

export const fileKey = (root: string, path: string): string => `${root}\u0000${path}`

/// Hunks are pickable only when the daemon sent them and allows partial commits.
export function canSelectHunks(file: ReviewFile): boolean {
  return file.hunk_selectable && !file.binary && !file.preview_truncated && file.hunks.length > 0
}

/// Mine is ticked; shared/unclear/unassigned stay unticked until the user opts in.
export function defaultTicks(review: ReviewResult): Ticks {
  const ticks: Ticks = {}
  for (const repo of review.repos) {
    for (const file of repo.files) ticks[fileKey(repo.root, file.path)] = file.ownership === 'mine' ? 'all' : 'none'
  }
  return ticks
}

/// Keep whole-file choices across a reload; partial hunk picks reset because
/// hunk indices are only meaningful within one review.
export function carryTicks(review: ReviewResult, previous: Ticks): Ticks {
  const ticks = defaultTicks(review)
  for (const key of Object.keys(ticks)) {
    const old = previous[key]
    if (old === 'all' || old === 'none') ticks[key] = old
  }
  return ticks
}

export function normalizeTick(file: ReviewFile, tick: FileTick | undefined): FileTick {
  if (tick === undefined || tick === 'none') return 'none'
  if (tick === 'all') return 'all'
  if (!canSelectHunks(file)) return tick.length > 0 ? 'all' : 'none'
  const valid = new Set(file.hunks.map((hunk) => hunk.index))
  const picked = [...new Set(tick.filter((index) => valid.has(index)))].sort((a, b) => a - b)
  if (picked.length === 0) return 'none'
  return picked.length === valid.size ? 'all' : picked
}

export function toggleFileTick(tick: FileTick | undefined): FileTick {
  return tick === 'all' ? 'none' : 'all'
}

export function hunkTicked(tick: FileTick | undefined, index: number): boolean {
  return tick === 'all' || (Array.isArray(tick) && tick.includes(index))
}

export function toggleHunkTick(file: ReviewFile, tick: FileTick | undefined, index: number): FileTick {
  const current = tick === 'all' ? file.hunks.map((hunk) => hunk.index) : Array.isArray(tick) ? tick : []
  const next = current.includes(index) ? current.filter((value) => value !== index) : [...current, index]
  return normalizeTick(file, next)
}

export function buildSelections(review: ReviewResult, ticks: Ticks): RepoSelection[] {
  const selections: RepoSelection[] = []
  for (const repo of review.repos) {
    const files: FileSelection[] = []
    for (const file of repo.files) {
      const tick = normalizeTick(file, ticks[fileKey(repo.root, file.path)])
      if (tick === 'none') continue
      files.push(tick === 'all' ? { path: file.path } : { path: file.path, hunks: tick })
    }
    if (files.length > 0) selections.push({ root: repo.root, files })
  }
  return selections
}

export function selectionFileCount(selections: RepoSelection[]): number {
  return selections.reduce((total, repo) => total + repo.files.length, 0)
}

export function ownershipLabel(file: Pick<ReviewFile, 'ownership' | 'other_threads'>): string {
  switch (file.ownership) {
    case 'mine': return 'Mine'
    case 'shared': {
      const titles = file.other_threads.map((row) => row.title.trim() || 'another chat')
      return titles.length ? `Shared with ${titles.join(', ')}` : 'Shared'
    }
    case 'unassigned': return 'Unassigned'
    default: return 'Unclear owner'
  }
}

export type CommitErrorKind = 'reload' | 'retry' | 'identity' | 'other'
export function commitErrorKind(code: string | undefined): CommitErrorKind {
  if (code === 'changed_since_review' || code === 'review_expired') return 'reload'
  if (code === 'head_moved') return 'retry'
  if (code === 'missing_git_identity') return 'identity'
  return 'other'
}

export function commitErrorText(code: string | undefined, message: string | undefined): string {
  switch (commitErrorKind(code)) {
    case 'reload': return code === 'review_expired'
      ? 'This review expired, so it was reloaded. Check the selection and commit again.'
      : 'Files changed since this review was opened, so it was reloaded. Check the selection and commit again.'
    case 'retry': return 'HEAD moved while committing; nothing was written. Try again.'
    case 'identity': return 'Git has no user.name / user.email for this repository. Set them with `git config`, then try again.'
    default: return message || 'Commit failed.'
  }
}

// ---- Result toasts ---------------------------------------------------------

/// `running` spins; `success`/`info` auto-dismiss; `warning` (amber) and
/// `error` (red) stay until dismissed.
export type GitToastTone = 'running' | 'success' | 'info' | 'warning' | 'error'
export interface GitToastContent {
  tone: GitToastTone
  title: string
  /// Muted line: short sha(s) · branch · subject, when known.
  detail: string | null
  /// Failure text, shown under the detail.
  error: string | null
  /// Repository whose push was rejected; the toast offers Pull & push.
  pull_push_root: string | null
}

const plural = (count: number, one: string, many = `${one}s`) => `${count} ${count === 1 ? one : many}`
const joinDetail = (parts: Array<string | null | undefined>): string | null => parts.filter((part) => !!part).join(' · ') || null
const uniq = (values: Array<string | null | undefined>): string[] => [...new Set(values.filter((value): value is string => !!value))]
export const PUSH_REJECTED_TEXT = 'The remote has commits you don\'t have.'

export function toastContent(tone: GitToastTone, title: string, extra: Partial<Omit<GitToastContent, 'tone' | 'title'>> = {}): GitToastContent {
  return { tone, title, detail: extra.detail ?? null, error: extra.error ?? null, pull_push_root: extra.pull_push_root ?? null }
}

/// Spinner title while a commit runs.
export function commitRunningTitle(files: number, push: boolean, new_branch = false): string {
  const noun = files > 0 ? ` ${plural(files, 'file')}` : ''
  if (new_branch) return push ? `Creating branch, committing & pushing${noun}…` : `Creating branch, committing${noun}…`
  return push ? `Committing & pushing${noun}…` : `Committing${noun}…`
}

/// `Committed & pushed 3 files` + `e57cfce · feature/x · Add login`. The commit
/// itself succeeded, so a failed/rejected push is amber, not red.
export function commitToast(result: CommitResult): GitToastContent {
  const repos = result.repos
  const files = result.files || repos.reduce((total, repo) => total + repo.files, 0)
  const pushed = repos.length > 0 && repos.every((repo) => repo.push === 'pushed')
  const rejected = repos.find((repo) => repo.push === 'rejected') ?? null
  const failed = repos.find((repo) => repo.push === 'failed') ?? null
  const shas = uniq(repos.map((repo) => repo.short_commit || repo.commit.slice(0, 7)))
  const branches = uniq(repos.map((repo) => (repo.branch ? `${repo.branch_created ? 'new branch ' : ''}${repo.branch}` : null)))
  const subject = repos.map((repo) => repo.subject?.trim()).find(Boolean) ?? null
  const reset = repos.some((repo) => repo.index_reset) ? 'staged changes for these files were reset' : null
  const detail = joinDetail([shas.join(', '), branches.join(', '), subject, reset])
  const title = `${pushed ? 'Committed & pushed' : 'Committed'} ${plural(files, 'file')}`
  if (rejected) return toastContent('warning', title, { detail, error: `Push rejected: ${PUSH_REJECTED_TEXT}`, pull_push_root: rejected.root })
  if (failed) return toastContent('warning', title, { detail, error: `Push failed${failed.push_message ? `: ${failed.push_message}` : '.'}` })
  return toastContent('success', title, { detail })
}

/// A commit that did not happen (`reload` means the review was reloaded).
export function commitFailureToast(push: boolean, code: string | undefined, message: string | undefined): GitToastContent {
  const kind = commitErrorKind(code)
  return toastContent(kind === 'reload' || kind === 'retry' ? 'warning' : 'error', push ? 'Commit & push failed' : 'Commit failed', { error: commitErrorText(code, message) })
}

type PushTarget = Pick<RepoStatus, 'root' | 'name' | 'branch' | 'upstream' | 'ahead'>
const targetLabel = (target: PushTarget, many: boolean) => (many ? `${target.name} ${target.branch ?? ''}`.trim() : target.branch)

/// Spinner title for one push target.
export function pushRunningTitle(target: PushTarget): string {
  if (target.ahead > 0 && target.upstream) return `Pushing ${plural(target.ahead, 'commit')} to ${target.upstream}…`
  return target.upstream ? `Pushing ${target.branch}…` : `Publishing ${target.branch}…`
}

export interface PushOutcome {
  target: PushTarget
  /// `pushed`, `rejected`, `failed`, or `in_progress` (another push running).
  push: string
  message: string | null
}

/// `Pushed 2 commits to origin/main`; unpublished branches read `Published x`.
export function pushToast(outcomes: PushOutcome[]): GitToastContent {
  if (outcomes.length === 0) return toastContent('info', 'Nothing to push')
  const many = outcomes.length > 1
  const pushed = outcomes.filter((row) => row.push === 'pushed')
  const rejected = outcomes.filter((row) => row.push === 'rejected')
  const failed = outcomes.filter((row) => row.push !== 'pushed' && row.push !== 'rejected')
  const errors = [
    ...(rejected.length ? [`Push${many ? ` of ${rejected.map((row) => row.target.branch).join(', ')}` : ''} rejected: ${PUSH_REJECTED_TEXT}`] : []),
    ...failed.map((row) => {
      const why = row.push === 'in_progress' ? 'a push is already running' : row.message || 'push failed'
      return many ? `${row.target.branch}: ${why}` : why.charAt(0).toUpperCase() + why.slice(1)
    }),
  ]
  const error = errors.join('\n') || null
  const pull_push_root = rejected[0]?.target.root ?? null
  if (pushed.length === 0) {
    const detail = joinDetail([uniq(outcomes.map((row) => targetLabel(row.target, many))).join(', ')])
    return toastContent(rejected.length && !failed.length ? 'warning' : 'error', rejected.length && !failed.length ? 'Push rejected' : 'Push failed', { detail, error, pull_push_root })
  }
  let title: string
  if (pushed.length === 1) {
    const { target } = pushed[0]
    title = target.upstream
      ? `Pushed ${target.ahead > 0 ? `${plural(target.ahead, 'commit')} ` : ''}to ${target.upstream}`
      : `Published ${target.branch}`
  } else {
    const commits = pushed.reduce((total, row) => total + row.target.ahead, 0)
    title = `Pushed ${commits > 0 ? `${plural(commits, 'commit')} to ` : ''}${plural(pushed.length, 'branch', 'branches')}`
  }
  const detail = pushed.length === 1 && !many
    ? joinDetail([pushed[0].target.name, pushed[0].target.upstream ? null : pushed[0].target.branch])
    : joinDetail([pushed.map((row) => targetLabel(row.target, true)).join(', ')])
  return toastContent(errors.length ? 'warning' : 'success', title, { detail, error, pull_push_root })
}

/// Pull & push outcome; `failure` is the RPC error when the call itself failed.
export function pullPushToast(
  repo: { root: string; name: string; branch: string | null },
  outcome: { push?: string; push_message?: string | null } | null,
  failure?: { code?: string; message?: string } | null,
): GitToastContent {
  const detail = joinDetail([repo.name, repo.branch])
  if (failure) {
    if (failure.code === 'turns_running') return toastContent('warning', 'Pull & push waiting', { detail, error: 'Chats are still running in this repository. Pull & push once they finish.' })
    return toastContent('error', 'Pull & push failed', { detail, error: failure.message || 'Pull & push failed.' })
  }
  if (outcome?.push === 'pushed') return toastContent('success', 'Pulled & pushed', { detail })
  if (outcome?.push === 'rejected') return toastContent('warning', 'Push rejected', { detail, error: `The remote moved again. ${PUSH_REJECTED_TEXT}`, pull_push_root: repo.root })
  return toastContent('error', 'Pull & push failed', { detail, error: outcome?.push_message || 'Push failed.' })
}

/// Commit request body; `new_branch`/`branch_name` are sent only when used.
export function commitRequest(options: {
  review_id: string; message: string; selections: RepoSelection[]; push: boolean; new_branch?: boolean; branch_name?: string | null
}): CommitRequest {
  const body: CommitRequest = { review_id: options.review_id, message: options.message, selections: options.selections, push: options.push }
  if (options.new_branch) {
    body.new_branch = true
    if (options.branch_name) body.branch_name = options.branch_name
  }
  return body
}

// ---- Commit message box ----------------------------------------------------

/// The generated message is only the placeholder; an empty box commits it.
export function effectiveCommitMessage(typed: string, generated: string | null | undefined): string {
  return typed.trim() || (generated ?? '').trim()
}

export function commitMessagePlaceholder(status: 'idle' | 'writing' | 'error', generated: string | null | undefined): string {
  if (status === 'writing') return 'Writing message…'
  if (generated?.trim()) return generated.trim()
  return status === 'error' ? 'Couldn\'t write a message. Describe these changes' : 'Describe these changes'
}

/// First line of a commit message, for one-line previews.
export const commitSubject = (message: string): string => message.trim().split('\n')[0]?.trim() ?? ''

/// +/− totals of the ticked changes; partial files count their picked hunks.
export function selectedTotals(review: ReviewResult | null, ticks: Ticks): { files: number; additions: number; deletions: number } {
  const totals = { files: 0, additions: 0, deletions: 0 }
  for (const repo of review?.repos ?? []) {
    for (const file of repo.files) {
      const tick = normalizeTick(file, ticks[fileKey(repo.root, file.path)])
      if (tick === 'none') continue
      totals.files += 1
      if (tick === 'all') { totals.additions += file.additions; totals.deletions += file.deletions; continue }
      for (const hunk of file.hunks) {
        if (!tick.includes(hunk.index)) continue
        for (const line of hunk.text.split('\n').slice(1)) {
          if (line.startsWith('+')) totals.additions += 1
          else if (line.startsWith('-')) totals.deletions += 1
        }
      }
    }
  }
  return totals
}

// ---- Header split button ---------------------------------------------------

export type GitAction = 'commit' | 'commit_and_push' | 'push' | 'pull_push'
export interface GitMenuItem { action: GitAction; label: string; disabled: boolean }
export interface GitActionState {
  visible: boolean
  /// Primary click; `commit` / `commit_and_push` run the quick path (the
  /// menu's `Commit…` opens the dialog).
  primary: GitAction | null
  label: string
  /// Files the quick path commits (the chat's own, not shared or unclear);
  /// 0 hides the badge.
  count: number
  attention: boolean
  title: string
  menu: GitMenuItem[]
}

const repoKey = (root: string, branch: string) => `${root}\u0000${branch}`

/// Repositories a push would target. `all` (the ▾ Push item) includes every
/// branch without an upstream; otherwise only ahead branches and branches this
/// client created (`published_pending`).
export function pushTargets(status: StatusResult | null, all: boolean, pending: ReadonlySet<string> = new Set()): RepoStatus[] {
  return (status?.repos ?? []).filter((repo) => repo.has_remote && repo.branch && (
    repo.ahead > 0 || (!repo.upstream && (all || pending.has(repoKey(repo.root, repo.branch))))
  ))
}

/// Header split button: the label follows repo state. With changes it runs the
/// configured default; with nothing to commit but commits ahead it pushes;
/// with nothing to do it is hidden.
export function gitActionState(input: {
  summary: ThreadChangeSummary | null | undefined
  status: StatusResult | null | undefined
  defaultAction: CommitAction
  /// `root\0branch` of branches this client created and has not pushed.
  pending?: ReadonlySet<string>
  /// Roots whose last push was rejected.
  rejected?: ReadonlySet<string>
}): GitActionState {
  const status = input.status ?? null
  const files = input.summary?.files ?? 0
  const attention = files > 0 && (input.summary?.attention ?? 0) > 0
  // Unknown status (not fetched yet, or an older daemon) assumes a remote.
  const hasRemote = status ? status.repos.some((repo) => repo.has_remote) : true
  const ahead = (status?.repos ?? []).reduce((total, repo) => total + (repo.has_remote ? repo.ahead : 0), 0)
  const primaryPush = pushTargets(status, false, input.pending)
  const anyPush = pushTargets(status, true, input.pending)
  const rejected = (status?.repos ?? []).some((repo) => input.rejected?.has(repo.root))
  const menu: GitMenuItem[] = [
    { action: 'commit', label: 'Commit…', disabled: files === 0 },
    { action: 'commit_and_push', label: 'Commit & push', disabled: files === 0 || !hasRemote },
  ]
  if (anyPush.length) menu.push({ action: 'push', label: ahead > 0 ? `Push ${ahead} ${ahead === 1 ? 'commit' : 'commits'}` : 'Push', disabled: false })
  if (rejected) menu.push({ action: 'pull_push', label: 'Pull & push', disabled: false })

  if (files > 0) {
    const primary: CommitAction = input.defaultAction === 'commit_and_push' && hasRemote ? 'commit_and_push' : 'commit'
    const noun = `${files} ${files === 1 ? 'file' : 'files'}`
    const summary = input.summary!
    // Shared and unclear files are counted in `attention`; the quick path
    // leaves them out, so the badge does too.
    const mine = Math.max(0, files - summary.attention)
    return {
      visible: true, primary, count: mine, attention, menu,
      label: primary === 'commit_and_push' ? 'Commit & push' : 'Commit',
      title: `${noun} +${summary.additions} −${summary.deletions} changed by this chat${attention ? `, ${summary.attention} need attention` : ''}`,
    }
  }
  if (primaryPush.length) {
    const branches = [...new Set(primaryPush.map((repo) => repo.branch as string))].join(', ')
    return {
      visible: true, primary: 'push', count: 0, attention: false, menu,
      label: ahead > 0 ? `↑${ahead} Push` : '↑ Push',
      title: ahead > 0 ? `Push ${ahead} ${ahead === 1 ? 'commit' : 'commits'} on ${branches}` : `Publish ${branches}`,
    }
  }
  return { visible: false, primary: null, label: '', count: 0, attention: false, title: '', menu }
}

// ---- Commit / Commit & push quick path -------------------------------------

/// What the header Commit / Commit & push does with a fresh review. Only files
/// the chat owns (`mine`) are committed, whole; shared, unclear and unassigned
/// files are left out, never a reason to stop.
export type QuickCommitPlan =
  | { kind: 'nothing' }
  /// Nothing is this chat's own: the full dialog decides.
  | { kind: 'dialog' }
  /// Commit & push onto the default branch asks first.
  | { kind: 'confirm'; branch: string; files: number; left_out: number; selections: RepoSelection[] }
  | { kind: 'direct'; files: number; left_out: number; selections: RepoSelection[] }

export function quickCommitPlan(review: ReviewResult, push = true): QuickCommitPlan {
  const files = review.repos.flatMap((repo) => repo.files)
  if (files.length === 0) return { kind: 'nothing' }
  const selections = buildSelections(review, defaultTicks(review))
  if (selections.length === 0) return { kind: 'dialog' }
  const count = selectionFileCount(selections)
  const left_out = leftOutFileCount(review)
  // A local commit on the default branch needs no confirmation.
  const onDefault = push ? review.repos.find((repo) => repo.is_default_branch && selections.some((row) => row.root === repo.root)) : undefined
  if (onDefault) return { kind: 'confirm', branch: onDefault.branch ?? onDefault.default_branch ?? 'main', files: count, left_out, selections }
  return { kind: 'direct', files: count, left_out, selections }
}

/// Shared and unclear files the quick path leaves out.
export function leftOutFileCount(review: ReviewResult): number {
  return review.repos.reduce((total, repo) => total + repo.files.filter((file) => file.ownership === 'shared' || file.ownership === 'unclear').length, 0)
}

/// Toast detail for files the quick path left out.
export const leftOutNote = (count: number): string => `${plural(count, 'file')} left out (shared/unclear) — use Commit… to review them`

/// Leads the toast detail with how many files the quick path left out.
export function noteLeftOut(content: GitToastContent, count: number): GitToastContent {
  if (count <= 0) return content
  return { ...content, detail: joinDetail([leftOutNote(count), content.detail]) }
}

// ---- Commit message settings (verde.json chat.commit_*) --------------------

export const COMMIT_MESSAGE_PROVIDERS = ['auto', 'codex', 'claude', 'cursor', 'opencode'] as const
export type CommitMessageProvider = typeof COMMIT_MESSAGE_PROVIDERS[number]
export const COMMIT_PROVIDER_LABELS: Record<CommitMessageProvider, string> = {
  auto: 'Auto', codex: 'Codex', claude: 'Claude', cursor: 'Cursor', opencode: 'OpenCode',
}
/// Daemon defaults when `commit_message_model` is null.
export const COMMIT_PROVIDER_DEFAULT_MODELS: Record<Exclude<CommitMessageProvider, 'auto'>, string> = {
  codex: 'gpt-6-luna', claude: 'sonnet', cursor: 'composer-2', opencode: 'opencode/gpt-5.4',
}

export interface CommitConfig { provider: CommitMessageProvider; model: string | null; default_action: CommitAction }
export interface CommitConfigPatch {
  commit_message_provider?: CommitMessageProvider
  /// Empty string clears back to the provider default.
  commit_message_model?: string
  commit_default_action?: CommitAction
}
export const DEFAULT_COMMIT_CONFIG: CommitConfig = { provider: 'auto', model: null, default_action: 'commit' }

export function parseCommitConfig(config: unknown): CommitConfig {
  const chat = (config as { chat?: Record<string, unknown> } | null)?.chat
  if (!chat || typeof chat !== 'object') return DEFAULT_COMMIT_CONFIG
  const provider = COMMIT_MESSAGE_PROVIDERS.includes(chat.commit_message_provider as CommitMessageProvider)
    ? chat.commit_message_provider as CommitMessageProvider : 'auto'
  return {
    provider,
    model: typeof chat.commit_message_model === 'string' && chat.commit_message_model ? chat.commit_message_model : null,
    default_action: chat.commit_default_action === 'commit_and_push' ? 'commit_and_push' : 'commit',
  }
}

export function applyCommitConfigPatch(config: CommitConfig, patch: CommitConfigPatch): CommitConfig {
  return {
    provider: patch.commit_message_provider ?? config.provider,
    model: patch.commit_message_model === undefined ? config.model : patch.commit_message_model || null,
    default_action: patch.commit_default_action ?? config.default_action,
  }
}

// ---- Completed-commit transcript row ---------------------------------------

export interface CommitNoticeCommit {
  sha: string
  repo: string | null
  pushed: boolean
  /// Web page for the commit (`remote <url>` line); null when unknown. Older
  /// daemons wrote it before the push, so only link it when `pushed`.
  url: string | null
  /// `local` line: the repository had no remote at all when it committed.
  local: boolean
}
export interface CommitNotice {
  files: number
  commits: CommitNoticeCommit[]
  /// Line 2: the committed subject; null when absent or empty.
  subject: string | null
  /// Line 3 `branch <name>`; null when absent (older rows, detached HEAD).
  branch: string | null
}

const COMMIT_NOTICE_HEAD = /^Committed (\d+) files?: (.+)$/
const COMMIT_NOTICE_ENTRY = /^([0-9a-f]{4,64})(?: \((.+)\))?( · pushed)?$/i

/// http(s) URL only (never `javascript:` and friends); null otherwise.
export function commitWebUrl(value: string): { url: string; host: string } | null {
  try {
    const parsed = new URL(value.trim())
    if ((parsed.protocol !== 'https:' && parsed.protocol !== 'http:') || !parsed.hostname) return null
    return { url: parsed.href, host: parsed.hostname }
  } catch {
    return null
  }
}

/// Parses the daemon's UI-only git row (`role: system`, `author: git`):
/// `Committed N file[s]: <sha7>[ (<repo>)][ · pushed][, ...]`, then optional
/// positional lines: subject, `branch <name>`, and one line per commit in
/// order: `remote <url>`, bare `remote` (no link), or `local` (no remote at
/// all). Missing fields are blank lines. Null when line 1 does not match, so
/// callers can fall back to the plain text.
export function parseCommitNotice(body: string): CommitNotice | null {
  const lines = body.replace(/\r\n?/g, '\n').split('\n')
  const head = COMMIT_NOTICE_HEAD.exec(lines[0]?.trim() ?? '')
  if (!head) return null
  const commits: CommitNoticeCommit[] = []
  for (const entry of head[2].split(', ')) {
    const match = COMMIT_NOTICE_ENTRY.exec(entry.trim())
    if (!match) return null
    commits.push({ sha: match[1], repo: match[2] ?? null, pushed: !!match[3], url: null, local: false })
  }
  const subject = lines[1]?.trim() || null
  const branchLine = lines[2]?.trim() ?? ''
  const branch = branchLine.startsWith('branch ') ? branchLine.slice('branch '.length).trim() || null : null
  commits.forEach((commit, index) => {
    const line = lines[3 + index]?.trim() ?? ''
    if (line.startsWith('remote ')) commit.url = commitWebUrl(line.slice('remote '.length))?.url ?? null
    else if (line === 'local') commit.local = true
  })
  return { files: Number(head[1]), commits, subject, branch }
}

/// The commit's web page, only once it is pushed (unpushed pages 404).
export function commitNoticeLink(commit: CommitNoticeCommit): { url: string; host: string } | null {
  return commit.pushed && commit.url ? commitWebUrl(commit.url) : null
}

/// Every commit on the card was made in a repository with no remote.
export function commitNoticeLocalOnly(notice: CommitNotice): boolean {
  return notice.commits.length > 0 && notice.commits.every((commit) => commit.local && !commit.pushed)
}

/// A commit card offers Push while some commit on it is unpushed and the
/// chat's branch status has something to push (ahead, or unpublished) on the
/// card's branch.
export function commitCardPushable(notice: CommitNotice, status: StatusResult | null | undefined, pending: ReadonlySet<string> = new Set()): boolean {
  if (notice.commits.every((commit) => commit.pushed)) return false
  if (commitNoticeLocalOnly(notice)) return false
  const targets = pushTargets(status ?? null, true, pending)
  return targets.length > 0 && (!notice.branch || targets.some((repo) => repo.branch === notice.branch))
}

// ---- Commit dialog footer --------------------------------------------------

/// What the dialog is doing: which button ran (`push` + `new_branch` identify
/// it) and whether it is still writing the message before committing.
export interface CommitBusy { push: boolean; new_branch: boolean; writing: boolean }

/// The sheet's other action, next to the primary: plain Commit from a
/// Commit & push sheet, or Commit & push when some repository has a remote.
export function commitAlternateAction(mode: CommitAction, repos: ReadonlyArray<Pick<RepoStatus, 'has_remote'>>): CommitAction | null {
  if (mode === 'commit_and_push') return 'commit'
  return repos.some((repo) => repo.has_remote) ? 'commit_and_push' : null
}

/// Footer button text for `action` (on a new branch or not): its label, or
/// its progress while that button's commit runs.
export function commitButtonLabel(action: CommitAction, new_branch: boolean, busy: CommitBusy | null): string {
  const push = action === 'commit_and_push'
  const clicked = !!busy && busy.new_branch === new_branch && (new_branch || busy.push === push)
  if (clicked && busy!.writing) return 'Writing message…'
  if (new_branch) {
    if (clicked) return 'Creating branch…'
    return push ? 'Commit & push on new branch' : 'Commit on new branch'
  }
  if (clicked) return push ? 'Committing & pushing…' : 'Committing…'
  return push ? 'Commit & push' : 'Commit'
}

/// Ctrl+Enter (Cmd+Enter on macOS) runs the sheet's primary action.
export function isCommitShortcut(event: Pick<KeyboardEvent, 'key' | 'ctrlKey' | 'metaKey' | 'isComposing'>): boolean {
  return event.key === 'Enter' && (event.ctrlKey || event.metaKey) && !event.isComposing
}

// ---- Reactive slice --------------------------------------------------------

export interface GitRoute { workspace_id: string; local_thread_id: string; repository_id: string; relative_cwd: string | null }

const SUMMARY_DEBOUNCE_MS = 500
/// A repeated commit for the same review returns the stored result; while the
/// first is still running the daemon answers `in_progress`.
const IN_PROGRESS_RETRY_MS = 1500
const IN_PROGRESS_RETRIES = 20

function rpcError(response: RpcEnvelope): { code?: string; message?: string } | null {
  if (!response.error && response.ok !== false) return null
  const error = response.error as { code?: string; message?: string } | string | undefined
  return typeof error === 'string' ? { code: error, message: error } : { code: error?.code, message: error?.message }
}

const unsupported = (code: string | undefined) => code === 'method_not_found' || code === 'unsupported' || code === 'unknown_method'
const repoName = (root: string) => root.split('/').filter(Boolean).at(-1) ?? root
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))
const requestId = () => `push-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`

export interface GitToast extends Omit<GitToastContent, 'pull_push_root'> {
  id: number
  action?: { label: string; run: () => void }
}

/// Success and info toasts dismiss themselves; the rest wait for the user.
export const toastAutoDismisses = (tone: GitToastTone): boolean => tone === 'success' || tone === 'info'

export interface DefaultBranchConfirm<Pane> {
  pane: Pane
  review: ReviewResult
  selections: RepoSelection[]
  branch: string
  files: number
  /// Shared/unclear files the commit leaves out (named in the result toast).
  left_out: number
  status: 'writing' | 'ready'
  message: string
  branch_name: string | null
}

export function createGitChanges<Pane>(deps: {
  /// Summary calls go to the local daemon; they never touch the projection.
  localCall: (method: string, params: unknown) => Promise<RpcEnvelope>
  /// Review/status/commit/push calls run where the chat runs (same routing as `@` search).
  paneCall: (pane: Pane, method: string, params: unknown) => Promise<RpcEnvelope>
  route: (pane: Pane) => GitRoute | null
  defaultAction: () => CommitAction
  /// The focused chat. Its branch status is fetched when focus moves to it
  /// and alongside its workspace's summary refreshes; there is no polling.
  focusedPane?: () => Pane | null
  /// After a push or pull & push: the daemon rewrites the chat's commit rows
  /// (` · pushed`, remote link), so the transcript is refetched.
  afterPush?: (pane: Pane) => void
}) {
  const [summaries, setSummaries] = createSignal<Record<string, WorkspaceChangeSummary>>({})
  let disabled = false
  const inflight = new Map<string, Promise<void>>()
  const rerun = new Set<string>()
  const timers = new Map<string, ReturnType<typeof setTimeout>>()

  const refreshSummary = (workspace_id: string): Promise<void> => {
    if (disabled || !workspace_id) return Promise.resolve()
    const running = inflight.get(workspace_id)
    if (running) { rerun.add(workspace_id); return running }
    const run = (async () => {
      try {
        const response = await deps.localCall('git.changes.summary', { workspace_id })
        const error = rpcError(response)
        if (error) { if (unsupported(error.code)) disabled = true; return }
        const next = parseSummaryResult(unwrapResult(response))
        if (!next || next.workspace_id !== workspace_id) return
        setSummaries((prev) => {
          const old = prev[workspace_id]
          if (old && old.revision === next.revision && next.revision !== 0) return prev
          return { ...prev, [workspace_id]: next }
        })
        refreshFocusedStatus(workspace_id)
      } catch {
        // Offline gateway: keep the last known chips; the next event retries.
      } finally {
        inflight.delete(workspace_id)
        if (rerun.delete(workspace_id)) void refreshSummary(workspace_id)
      }
    })()
    inflight.set(workspace_id, run)
    return run
  }
  const scheduleSummaryRefresh = (workspace_id: string, delay = SUMMARY_DEBOUNCE_MS) => {
    if (disabled || !workspace_id) return
    clearTimeout(timers.get(workspace_id))
    timers.set(workspace_id, setTimeout(() => { timers.delete(workspace_id); void refreshSummary(workspace_id) }, delay))
  }
  const refreshSummaries = (workspace_ids: Iterable<string>) => {
    for (const id of workspace_ids) void refreshSummary(id)
  }
  // Plain accessors (not memos) so they stay reactive under any Solid build;
  // the per-workspace maps are tiny.
  const summaryForThread = (thread_id: string | null | undefined): ThreadChangeSummary | null => {
    if (!thread_id) return null
    for (const summary of Object.values(summaries())) {
      const row = summary.threads[thread_id]
      if (row) return row
    }
    return null
  }

  // ---- Branch status (button labels) ----
  const [statuses, setStatuses] = createSignal<Record<string, StatusResult>>({})
  let statusDisabled = false
  const statusInflight = new Map<string, Promise<void>>()
  const statusRerun = new Map<string, Pane>()

  const refreshStatus = (pane: Pane): Promise<void> => {
    const route = deps.route(pane)
    if (statusDisabled || !route) return Promise.resolve()
    const key = route.local_thread_id
    const running = statusInflight.get(key)
    if (running) { statusRerun.set(key, pane); return running }
    const run = (async () => {
      try {
        const response = await deps.paneCall(pane, 'git.changes.status', route)
        const error = rpcError(response)
        if (error) { if (unsupported(error.code)) statusDisabled = true; return }
        const next = parseStatusResult(unwrapResult(response))
        if (!next || next.local_thread_id !== key) return
        setStatuses((prev) => (prev[key] && JSON.stringify(prev[key]) === JSON.stringify(next) ? prev : { ...prev, [key]: next }))
      } catch {
        // Keep the last known status; the next refresh retries.
      } finally {
        statusInflight.delete(key)
        const again = statusRerun.get(key)
        if (again !== undefined) { statusRerun.delete(key); void refreshStatus(again) }
      }
    })()
    statusInflight.set(key, run)
    return run
  }
  function refreshFocusedStatus(workspace_id?: string) {
    const pane = deps.focusedPane?.()
    const route = pane ? deps.route(pane) : null
    if (!pane || !route || (workspace_id && route.workspace_id !== workspace_id)) return
    void refreshStatus(pane)
  }
  if (deps.focusedPane) {
    const focusedThread = createMemo(() => {
      const pane = deps.focusedPane!()
      return pane ? deps.route(pane)?.local_thread_id ?? null : null
    })
    createEffect(on(focusedThread, (id) => { if (id) untrack(() => refreshFocusedStatus()) }))
  }
  const statusForThread = (thread_id: string | null | undefined) => (thread_id ? statuses()[thread_id] ?? null : null)

  /// Branches this client created without pushing, and roots whose last push
  /// was rejected; both only shape the header menu.
  const [pending, setPending] = createSignal<ReadonlySet<string>>(new Set())
  const [rejected, setRejected] = createSignal<ReadonlySet<string>>(new Set())
  const markRejected = (root: string, value: boolean) => setRejected((prev) => {
    if (prev.has(root) === value) return prev
    const next = new Set(prev)
    if (value) next.add(root); else next.delete(root)
    return next
  })
  /// Thread whose quick action (commit & push, push, pull & push) is running.
  const [running, setRunning] = createSignal<string | null>(null)

  const actionState = (pane: Pane): GitActionState => {
    const id = deps.route(pane)?.local_thread_id ?? null
    return gitActionState({
      summary: summaryForThread(id), status: statusForThread(id), defaultAction: deps.defaultAction(),
      pending: pending(), rejected: rejected(),
    })
  }
  const actionRunning = (pane: Pane) => {
    const id = deps.route(pane)?.local_thread_id
    return !!id && running() === id
  }

  // ---- Toast ----
  const [toast, setToast] = createSignal<GitToast | null>(null)
  let toastId = 0
  type ToastAction = { label: string; run: () => void }
  const showToast = (content: GitToastContent, action?: ToastAction) => {
    const { pull_push_root: _root, ...rest } = content
    setToast({ ...rest, id: ++toastId, action })
  }
  const showProgress = (title: string, detail: string | null = null) => showToast(toastContent('running', title, { detail }))
  const showError = (title: string, err: unknown, fallback: string, action?: ToastAction) =>
    showToast(toastContent('error', title, { error: err instanceof Error && err.message ? err.message : fallback }), action)
  const dismissToast = () => setToast(null)
  /// Shows `content`, offering Pull & push when its push was rejected.
  const showOutcome = (pane: Pane, workspace_id: string, content: GitToastContent, action?: ToastAction) => {
    const root = content.pull_push_root
    showToast(content, action ?? (root ? { label: 'Pull & push', run: () => void pullPush(pane, workspace_id, root) } : undefined))
  }

  // ---- Commit dialog ----
  const [sheetPane, setSheetPane] = createSignal<Pane | null>(null)
  const [sheetMode, setSheetMode] = createSignal<CommitAction>('commit')
  const [review, setReview] = createSignal<ReviewResult | null>(null)
  const [reviewStatus, setReviewStatus] = createSignal<'loading' | 'ready' | 'error'>('loading')
  const [ticks, setTicks] = createSignal<Ticks>({})
  /// "Show diffs": every file's hunks expanded. Ticking works either way.
  const [diffsShown, setDiffsShownSignal] = createSignal(false)
  /// What the user typed; empty commits `generated`.
  const [message, setMessageSignal] = createSignal('')
  const [generated, setGenerated] = createSignal<string | null>(null)
  const [branchSuggestion, setBranchSuggestion] = createSignal<string | null>(null)
  const [messageStatus, setMessageStatus] = createSignal<'idle' | 'writing' | 'error'>('idle')
  const [messageSource, setMessageSource] = createSignal<string | null>(null)
  const [busy, setBusy] = createSignal<CommitBusy | null>(null)
  const [error, setError] = createSignal<string | null>(null)
  let generation = 0
  let messageGeneration = 0
  let generatedFor = ''
  let messageRequest: Promise<void> | null = null

  const selections = (): RepoSelection[] => {
    const current = review()
    return current ? buildSelections(current, ticks()) : []
  }
  const selectedFiles = () => selectionFileCount(selections())
  const totals = () => selectedTotals(review(), ticks())
  const primaryAction = (): CommitAction => sheetMode()
  const alternateAction = (): CommitAction | null => commitAlternateAction(sheetMode(), review()?.repos ?? [])
  const effectiveMessage = () => effectiveCommitMessage(message(), generated())
  const placeholder = () => commitMessagePlaceholder(messageStatus(), generated())
  /// An empty box with no (or a stale) suggestion still commits: `commit`
  /// writes the message first.
  const canCommit = () => reviewStatus() === 'ready' && selectedFiles() > 0 && !busy()
  /// The suggestion no longer covers what is ticked.
  const messageStale = () => JSON.stringify(selections()) !== generatedFor

  const setMessage = (value: string) => setMessageSignal(value)

  /// One `commit_message` call; null on failure (the caller decides).
  const requestMessage = async (pane: Pane, review_id: string, picked: RepoSelection[]) => {
    const response = await deps.paneCall(pane, 'git.changes.commit_message', { review_id, selections: picked })
    const failure = rpcError(response)
    const result = unwrapResult<{ message?: string; branch?: string | null; provider?: string; model?: string }>(response)
    if (failure || typeof result?.message !== 'string' || !result.message.trim()) return { ok: false as const, code: failure?.code }
    return {
      ok: true as const, message: result.message.trim(), branch: typeof result.branch === 'string' && result.branch ? result.branch : null,
      source: result.provider ? `${result.provider}${result.model ? ` · ${result.model}` : ''}` : null,
    }
  }

  const generateMessage = (explicit: boolean): Promise<void> => {
    const request = writeMessage(explicit)
    messageRequest = request
    void request.finally(() => { if (messageRequest === request) messageRequest = null })
    return request
  }

  const writeMessage = async (explicit: boolean) => {
    const pane = sheetPane()
    const current = review()
    if (!pane || !current) return
    const picked = selections()
    if (picked.length === 0) return
    const gen = generation
    const request = ++messageGeneration
    generatedFor = JSON.stringify(picked)
    // ↻ is an explicit request for a fresh suggestion, so it clears typing.
    if (explicit) setMessageSignal('')
    setMessageStatus('writing')
    try {
      const result = await requestMessage(pane, current.review_id, picked)
      if (gen !== generation || request !== messageGeneration) return
      if (!result.ok) {
        setMessageStatus('error')
        if (commitErrorKind(result.code) === 'reload') void loadReview(true)
        return
      }
      batch(() => {
        setGenerated(result.message)
        setBranchSuggestion(result.branch)
        setMessageSource(result.source)
        setMessageStatus('idle')
      })
    } catch {
      if (gen === generation && request === messageGeneration) setMessageStatus('error')
    }
  }

  /// Show/Hide diffs expands or collapses every file; hiding them refreshes a
  /// stale suggestion when nothing was typed.
  const setDiffsShown = (value: boolean) => {
    setDiffsShownSignal(value)
    if (!value && !message().trim() && review() && selectedFiles() > 0 && messageStale()) {
      void generateMessage(false)
    }
  }

  const acceptReview = (next: ReviewResult, reload: boolean) => {
    const previous = ticks()
    batch(() => {
      setReview(next)
      setTicks(reload ? carryTicks(next, previous) : defaultTicks(next))
      setReviewStatus('ready')
    })
    if (!reload && !generated()) void generateMessage(false)
  }

  const loadReview = async (reload: boolean) => {
    const pane = sheetPane()
    const route = pane ? deps.route(pane) : null
    if (!pane || !route) { setReviewStatus('error'); setError('This chat has no saved thread yet.'); return }
    const gen = ++generation
    if (!reload) setReviewStatus('loading')
    try {
      const response = await deps.paneCall(pane, 'git.changes.review', { ...route, include_unassigned: true })
      if (gen !== generation) return
      const failure = rpcError(response)
      const next = failure ? null : parseReviewResult(unwrapResult(response))
      if (!next) {
        setReviewStatus('error')
        setError(failure?.message ?? 'Could not load this chat\'s changes.')
        return
      }
      acceptReview(next, reload)
    } catch (err) {
      if (gen !== generation) return
      setReviewStatus('error')
      setError(err instanceof Error ? err.message : 'Could not load this chat\'s changes.')
    }
  }

  /// Opens "Commit changes". The quick path passes the review (and message)
  /// it already loaded so the dialog does not fetch them again.
  const openSheet = (pane: Pane, options: { mode?: CommitAction; review?: ReviewResult; generated?: string | null; branch?: string | null } = {}) => {
    generation += 1
    messageGeneration += 1
    generatedFor = ''
    batch(() => {
      setSheetPane(() => pane)
      setSheetMode(options.mode ?? 'commit')
      setReview(null)
      setTicks({})
      setDiffsShownSignal(false)
      setMessageSignal('')
      setGenerated(options.generated ?? null)
      setBranchSuggestion(options.branch ?? null)
      setMessageStatus('idle')
      setMessageSource(null)
      setBusy(null)
      setError(null)
    })
    if (options.review) {
      if (options.generated) generatedFor = JSON.stringify(buildSelections(options.review, defaultTicks(options.review)))
      acceptReview(options.review, false)
    } else void loadReview(false)
  }

  const closeSheet = () => {
    const pane = sheetPane()
    const route = pane ? deps.route(pane) : null
    generation += 1
    messageGeneration += 1
    batch(() => { setSheetPane(null); setReview(null); setBusy(null); setError(null); setDiffsShownSignal(false) })
    if (route) void refreshSummary(route.workspace_id)
  }

  const afterAction = (pane: Pane, workspace_id: string, pushed = false) => {
    void refreshSummary(workspace_id)
    void refreshStatus(pane)
    if (pushed) deps.afterPush?.(pane)
  }

  const repoFacts = (pane: Pane, root: string) => {
    const repo = statusForThread(deps.route(pane)?.local_thread_id)?.repos.find((row) => row.root === root)
    return { root, name: repo?.name ?? repoName(root), branch: repo?.branch ?? null }
  }

  const pullPush = async (pane: Pane, workspace_id: string, root: string) => {
    const repo = repoFacts(pane, root)
    showProgress('Pulling & pushing…', [repo.name, repo.branch].filter(Boolean).join(' · '))
    try {
      const response = await deps.paneCall(pane, 'git.changes.pull_push', { workspace_id, root })
      const failure = rpcError(response)
      const result = failure ? null : unwrapResult<{ push?: string; push_message?: string | null }>(response)
      if (result?.push === 'pushed') markRejected(root, false)
      const retry = failure?.code === 'turns_running' ? { label: 'Retry', run: () => void pullPush(pane, workspace_id, root) } : undefined
      showOutcome(pane, workspace_id, pullPushToast(repo, result, failure), retry)
    } catch (err) {
      showError('Pull & push failed', err, 'Pull & push failed.')
    } finally {
      afterAction(pane, workspace_id, true)
    }
  }

  /// Toast, menu state and refreshes after any successful commit; `left_out`
  /// leads the toast detail after a quick commit.
  const finishCommit = (pane: Pane, workspace_id: string, raw: CommitResult, left_out = 0) => {
    const repos = Array.isArray(raw.repos) ? raw.repos : []
    const outcome = noteLeftOut(commitToast({ ...raw, repos }), left_out)
    for (const repo of repos) {
      if (repo.push === 'pushed') markRejected(repo.root, false)
      if (repo.push === 'rejected') markRejected(repo.root, true)
      if (repo.branch_created && repo.branch && repo.push !== 'pushed') {
        setPending((prev) => new Set(prev).add(repoKey(repo.root, repo.branch as string)))
      }
    }
    showOutcome(pane, workspace_id, outcome)
    afterAction(pane, workspace_id)
  }

  /// `git.changes.commit`, waiting out `in_progress` (commits are idempotent
  /// per review, so a repeat returns the first result).
  const sendCommit = async (pane: Pane, body: CommitRequest) => {
    for (let attempt = 0; ; attempt += 1) {
      const response = await deps.paneCall(pane, 'git.changes.commit', body)
      const failure = rpcError(response)
      if (failure?.code === 'in_progress' && attempt < IN_PROGRESS_RETRIES) { await sleep(IN_PROGRESS_RETRY_MS); continue }
      return { failure, result: failure ? null : unwrapResult<CommitResult>(response) }
    }
  }

  const commit = async (action: CommitAction = sheetMode(), new_branch = false) => {
    const pane = sheetPane()
    const current = review()
    const picked = selections()
    if (!pane || !current || busy() || picked.length === 0) return
    const gen = generation
    const push = action === 'commit_and_push'
    setBusy({ push, new_branch, writing: false })
    setError(null)
    try {
      // An empty box commits the suggestion; write it first when there is none
      // yet or it no longer matches the ticks.
      if (!message().trim() && (messageStale() || !generated() || messageStatus() === 'writing')) {
        const stale = messageStale()
        if (!stale && messageStatus() === 'error') {
          setError('Couldn\'t write a commit message. Type one, then commit.')
          return
        }
        setBusy({ push, new_branch, writing: true })
        await (!stale && messageRequest ? messageRequest : generateMessage(false))
        if (gen !== generation) return
        setBusy({ push, new_branch, writing: false })
        if (messageStale() || messageStatus() !== 'idle' || !generated()) {
          setError('Couldn\'t write a commit message. Type one, then commit.')
          return
        }
      }
      const text = effectiveMessage()
      if (!text) { setError('Write a commit message first.'); return }
      showProgress(commitRunningTitle(selectionFileCount(picked), push, new_branch), commitSubject(text))
      const { failure, result } = await sendCommit(pane, commitRequest({
        review_id: current.review_id, message: text, selections: picked, push,
        new_branch, branch_name: branchSuggestion(),
      }))
      // The toast reports the outcome even if the dialog was closed meanwhile;
      // an open dialog shows the failure inline (a toast would cover its
      // footer on phones).
      if (failure || !result) {
        if (gen !== generation) { showToast(commitFailureToast(push, failure?.code, failure?.message)); return }
        dismissToast()
        setError(commitErrorText(failure?.code, failure?.message))
        if (commitErrorKind(failure?.code) === 'reload') await loadReview(true)
        return
      }
      if (gen === generation) closeSheet()
      finishCommit(pane, current.workspace_id, result)
    } catch (err) {
      if (gen !== generation) showError(push ? 'Commit & push failed' : 'Commit failed', err, 'Commit failed.')
      else { dismissToast(); setError(err instanceof Error ? err.message : 'Commit failed.') }
    } finally {
      if (gen === generation) setBusy(null)
    }
  }

  const setFileTick = (root: string, file: ReviewFile, tick: FileTick) =>
    setTicks((prev) => ({ ...prev, [fileKey(root, file.path)]: normalizeTick(file, tick) }))

  // ---- Quick actions (header button) ----
  const [confirm, setConfirm] = createSignal<DefaultBranchConfirm<Pane> | null>(null)

  const quickCommit = async (
    pane: Pane, current: ReviewResult, picked: RepoSelection[], text: string, push: boolean,
    new_branch: boolean, branch_name: string | null, left_out: number,
  ) => {
    showProgress(commitRunningTitle(selectionFileCount(picked), push, new_branch), commitSubject(text))
    const mode: CommitAction = push ? 'commit_and_push' : 'commit'
    const reopen = { label: 'Review', run: () => openSheet(pane, { mode }) }
    try {
      const { failure, result } = await sendCommit(pane, commitRequest({
        review_id: current.review_id, message: text, selections: picked, push, new_branch, branch_name,
      }))
      if (failure || !result) {
        showToast(commitFailureToast(push, failure?.code, failure?.message), failure?.code === 'missing_git_identity' ? undefined : reopen)
        return
      }
      finishCommit(pane, current.workspace_id, result, left_out)
    } catch (err) {
      showError(push ? 'Commit & push failed' : 'Commit failed', err, 'Commit failed.', reopen)
    }
  }

  /// Header Commit / Commit & push: review → commit_message → commit. Only the
  /// chat's own files are committed; the dialog opens when none are, and
  /// Commit & push onto the default branch asks first.
  const quickAction = async (pane: Pane, push: boolean) => {
    const route = deps.route(pane)
    if (!route || running()) return
    const mode: CommitAction = push ? 'commit_and_push' : 'commit'
    const failed = push ? 'Commit & push failed' : 'Commit failed'
    setRunning(route.local_thread_id)
    try {
      showProgress('Reviewing changes…')
      const response = await deps.paneCall(pane, 'git.changes.review', { ...route, include_unassigned: true })
      const failure = rpcError(response)
      const current = failure ? null : parseReviewResult(unwrapResult(response))
      if (!current) {
        showToast(toastContent('error', failed, { error: failure?.message ?? 'Could not load this chat\'s changes.' }))
        return
      }
      const plan = quickCommitPlan(current, push)
      if (plan.kind === 'nothing') { showToast(toastContent('info', 'No uncommitted changes')); void refreshSummary(route.workspace_id); return }
      if (plan.kind === 'dialog') { dismissToast(); openSheet(pane, { mode, review: current }); return }
      if (plan.kind === 'confirm') {
        dismissToast()
        setConfirm({ pane, review: current, selections: plan.selections, branch: plan.branch, files: plan.files, left_out: plan.left_out, status: 'writing', message: '', branch_name: null })
      } else showProgress('Writing commit message…')
      const written = await requestMessage(pane, current.review_id, plan.selections)
      if (plan.kind === 'confirm' && confirm()?.review.review_id !== current.review_id) return // aborted meanwhile
      if (!written.ok) {
        // No message to commit with: let the user write one.
        setConfirm(null)
        dismissToast()
        openSheet(pane, { mode, review: current })
        return
      }
      if (plan.kind === 'confirm') {
        setConfirm((prev) => prev && { ...prev, status: 'ready', message: written.message, branch_name: written.branch })
        return
      }
      await quickCommit(pane, current, plan.selections, written.message, push, false, written.branch, plan.left_out)
    } catch (err) {
      setConfirm(null)
      showError(failed, err, `${failed}.`)
    } finally {
      setRunning(null)
    }
  }
  const commitAndPush = (pane: Pane) => quickAction(pane, true)
  const quickCommitOnly = (pane: Pane) => quickAction(pane, false)

  /// Default-branch confirm: push to it, or commit on a new branch and push that.
  const resolveConfirm = async (choice: 'abort' | 'push' | 'new_branch') => {
    const current = confirm()
    if (!current) return
    setConfirm(null)
    if (choice === 'abort' || current.status !== 'ready') return
    const id = deps.route(current.pane)?.local_thread_id ?? null
    setRunning(id)
    try {
      await quickCommit(current.pane, current.review, current.selections, current.message, true, choice === 'new_branch', current.branch_name, current.left_out)
    } finally {
      setRunning(null)
    }
  }

  /// Push ahead branches (`all` adds branches without an upstream).
  const push = async (pane: Pane, all = false) => {
    const route = deps.route(pane)
    if (!route || running()) return
    setRunning(route.local_thread_id)
    try {
      if (!statusForThread(route.local_thread_id)) await refreshStatus(pane)
      const targets = pushTargets(statusForThread(route.local_thread_id), all, pending())
      if (targets.length === 0) { showToast(pushToast([])); return }
      const outcomes: PushOutcome[] = []
      for (const target of targets) {
        showProgress(pushRunningTitle(target), targets.length > 1 ? target.name : null)
        try {
          const response = await deps.paneCall(pane, 'git.changes.push', { workspace_id: route.workspace_id, root: target.root, request_id: requestId() })
          const failure = rpcError(response)
          const result = failure ? null : unwrapResult<{ push?: string; push_message?: string | null }>(response)
          const push = failure ? (failure.code === 'in_progress' ? 'in_progress' : 'failed') : result?.push ?? 'failed'
          if (push === 'pushed') markRejected(target.root, false)
          if (push === 'rejected') markRejected(target.root, true)
          outcomes.push({ target, push, message: failure ? failure.message ?? null : result?.push_message ?? null })
        } catch (err) {
          outcomes.push({ target, push: 'failed', message: err instanceof Error ? err.message : null })
        }
      }
      showOutcome(pane, route.workspace_id, pushToast(outcomes))
    } finally {
      setRunning(null)
      afterAction(pane, route.workspace_id, true)
    }
  }

  const pullPushRejected = (pane: Pane) => {
    const route = deps.route(pane)
    if (!route) return
    for (const repo of statusForThread(route.local_thread_id)?.repos ?? []) {
      if (rejected().has(repo.root)) void pullPush(pane, route.workspace_id, repo.root)
    }
  }

  /// Transcript commit card: offer Push while the row is unpushed and its
  /// branch has something to push.
  const canPushCommit = (pane: Pane, notice: CommitNotice) => {
    const id = deps.route(pane)?.local_thread_id
    return commitCardPushable(notice, statusForThread(id), pending())
  }

  /// Header button / menu dispatch. The primary Commit runs the quick path;
  /// the menu's Commit… opens the dialog.
  const runAction = (pane: Pane, action: GitAction, source: 'primary' | 'menu' = 'menu') => {
    switch (action) {
      case 'commit': if (source === 'primary') void quickCommitOnly(pane); else openSheet(pane, { mode: 'commit' }); return
      case 'commit_and_push': void commitAndPush(pane); return
      case 'push': void push(pane, source === 'menu'); return
      case 'pull_push': pullPushRejected(pane); return
    }
  }

  return {
    summaries, summaryForThread, refreshSummary, refreshSummaries, scheduleSummaryRefresh,
    statusForThread, refreshStatus, actionState, actionRunning, runAction, commitAndPush, quickCommit: quickCommitOnly, push, canPushCommit,
    confirm, resolveConfirm,
    sheetPane, sheetMode, review, reviewStatus, ticks, setFileTick, selections, selectedFiles, totals, primaryAction, alternateAction,
    diffsShown, setDiffsShown,
    message, setMessage, generated, branchSuggestion, effectiveMessage, placeholder, canCommit,
    messageStatus, messageSource, regenerateMessage: () => generateMessage(true),
    busy, error, openSheet, closeSheet, reloadReview: () => loadReview(false), commit,
    toast, dismissToast,
  }
}

export type GitChanges<Pane> = ReturnType<typeof createGitChanges<Pane>>

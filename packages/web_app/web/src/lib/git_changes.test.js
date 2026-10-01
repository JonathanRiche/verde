import { expect, test } from 'bun:test'
import { createRoot } from 'solid-js'

import {
  applyCommitConfigPatch, buildSelections, carryTicks, commitAlternateAction, commitButtonLabel, commitCardPushable, commitErrorKind, commitFailureToast, commitMessagePlaceholder,
  commitRequest, commitRunningTitle, commitToast, commitWebUrl, pullPushToast, pushRunningTitle, pushToast, toastAutoDismisses,
  createGitChanges, defaultTicks, effectiveCommitMessage, fileKey, gitActionState, isCommitShortcut, normalizeTick, ownershipLabel,
  leftOutFileCount, leftOutNote, noteLeftOut, parseCommitConfig, parseCommitNotice, commitNoticeLink, commitNoticeLocalOnly, parseReviewResult, parseStatusResult, parseSummaryResult, pushTargets, quickCommitPlan, selectedTotals,
  selectionFileCount, summaryChip, toggleFileTick, toggleHunkTick,
} from './git_changes.ts'

const hunks = (n) => Array.from({ length: n }, (_, index) => ({ index, header: `@@ -${index} +${index} @@`, text: `@@ -${index} +${index} @@\n-a\n+b` }))
const file = (path, ownership, extra = {}) => ({
  path, status: 'modified', ownership, other_threads: [], additions: 1, deletions: 1,
  binary: false, hunk_selectable: true, preview_truncated: false, hunks: hunks(3), ...extra,
})
const review = () => parseReviewResult({
  review_id: 'r1', workspace_id: 'ws', local_thread_id: 't1', turn_running: false, default_action: 'commit',
  repos: [
    { root: '/repo', name: 'repo', branch: 'main', head: 'abc', files: [
      file('a.ts', 'mine'),
      file('b.ts', 'shared', { other_threads: [{ local_thread_id: 't2', title: 'Fix login' }] }),
      file('c.ts', 'unclear'),
      file('bin.png', 'mine', { binary: true, hunk_selectable: false, hunks: [] }),
    ] },
    { root: '/lib', name: 'lib', files: [file('d.ts', 'unassigned')] },
  ],
})

test('summary chip text, attention tone, and hidden at zero files', () => {
  expect(summaryChip({ local_thread_id: 't', files: 4, additions: 120, deletions: 30, attention: 0 }))
    .toMatchObject({ visible: true, text: '● 4 files +120 −30', attention: false })
  expect(summaryChip({ local_thread_id: 't', files: 1, additions: 2, deletions: 0, attention: 1 }))
    .toMatchObject({ visible: true, text: '● 1 file +2 −0', attention: true })
  expect(summaryChip({ local_thread_id: 't', files: 0, additions: 0, deletions: 0, attention: 0 }).visible).toBe(false)
  expect(summaryChip(null).visible).toBe(false)
})

test('summary parsing indexes threads and drops malformed rows', () => {
  const parsed = parseSummaryResult({ workspace_id: 'ws', revision: 7, threads: [{ local_thread_id: 't1', files: 2, additions: 3, deletions: -1, attention: 1 }, { files: 9 }] })
  expect(parsed.revision).toBe(7)
  expect(Object.keys(parsed.threads)).toEqual(['t1'])
  expect(parsed.threads.t1.deletions).toBe(0)
  expect(parseSummaryResult({ threads: [] })).toBeNull()
})

test('default ticks select only files the chat owns', () => {
  const ticks = defaultTicks(review())
  expect(ticks[fileKey('/repo', 'a.ts')]).toBe('all')
  expect(ticks[fileKey('/repo', 'bin.png')]).toBe('all')
  expect(ticks[fileKey('/repo', 'b.ts')]).toBe('none')
  expect(ticks[fileKey('/repo', 'c.ts')]).toBe('none')
  expect(ticks[fileKey('/lib', 'd.ts')]).toBe('none')
})

test('selections carry partial hunks, whole files, and skip empty repos', () => {
  const current = review()
  const ticks = defaultTicks(current)
  const b = current.repos[0].files[1]
  ticks[fileKey('/repo', 'b.ts')] = toggleHunkTick(b, 'none', 2)
  ticks[fileKey('/repo', 'b.ts')] = toggleHunkTick(b, ticks[fileKey('/repo', 'b.ts')], 0)
  const selections = buildSelections(current, ticks)
  expect(selections).toEqual([{ root: '/repo', files: [{ path: 'a.ts' }, { path: 'b.ts', hunks: [0, 2] }, { path: 'bin.png' }] }])
  expect(selectionFileCount(selections)).toBe(3)
})

test('hunk toggles collapse to all/none and binary files stay whole-file', () => {
  const current = review()
  const a = current.repos[0].files[0]
  expect(toggleHunkTick(a, 'all', 1)).toEqual([0, 2])
  expect(toggleHunkTick(a, [0, 2], 1)).toBe('all')
  expect(toggleHunkTick(a, [1], 1)).toBe('none')
  expect(toggleFileTick([1])).toBe('all')
  expect(toggleFileTick('all')).toBe('none')
  const binary = current.repos[0].files[3]
  expect(normalizeTick(binary, [0])).toBe('all')
  const truncated = file('big.ts', 'mine', { preview_truncated: true })
  expect(normalizeTick(truncated, [1])).toBe('all')
  expect(normalizeTick(a, [9])).toBe('none')
})

test('reload keeps whole-file choices but resets partial hunk picks', () => {
  const current = review()
  const previous = { [fileKey('/repo', 'a.ts')]: 'none', [fileKey('/repo', 'b.ts')]: [1], [fileKey('/repo', 'c.ts')]: 'all' }
  const ticks = carryTicks(current, previous)
  expect(ticks[fileKey('/repo', 'a.ts')]).toBe('none')
  expect(ticks[fileKey('/repo', 'b.ts')]).toBe('none')
  expect(ticks[fileKey('/repo', 'c.ts')]).toBe('all')
})

test('ownership labels', () => {
  const current = review()
  expect(current.repos[0].files.map(ownershipLabel)).toEqual(['Mine', 'Shared with Fix login', 'Unclear owner', 'Mine'])
  expect(ownershipLabel({ ownership: 'unassigned', other_threads: [] })).toBe('Unassigned')
})

test('commit toast: title, detail line, and push outcomes', () => {
  const repo = { root: '/repo', commit: 'e57cfce0', short_commit: 'e57cfce', subject: 'Add login', files: 3, branch: 'feature/x', push: 'not_requested', push_message: null, index_reset: false }
  expect(commitToast({ files: 3, repos: [repo] })).toEqual({
    tone: 'success', title: 'Committed 3 files', detail: 'e57cfce · feature/x · Add login', error: null, pull_push_root: null,
  })
  expect(commitToast({ files: 1, repos: [{ ...repo, files: 1, push: 'pushed' }] })).toMatchObject({ tone: 'success', title: 'Committed & pushed 1 file' })
  expect(commitToast({ files: 3, repos: [{ ...repo, push: 'rejected' }] })).toMatchObject({
    tone: 'warning', title: 'Committed 3 files', error: "Push rejected: The remote has commits you don't have.", pull_push_root: '/repo',
  })
  expect(commitToast({ files: 3, repos: [{ ...repo, push: 'failed', push_message: 'no auth' }] })).toMatchObject({ tone: 'warning', error: 'Push failed: no auth', pull_push_root: null })
  expect(commitToast({ files: 3, repos: [{ ...repo, index_reset: true }] }).detail).toContain('staged changes for these files were reset')
  // Unknown fields drop out of the detail line; two repos list both shas.
  expect(commitToast({ files: 0, repos: [{ ...repo, subject: '', branch: null }, { ...repo, root: '/lib', short_commit: 'def5678', files: 2, subject: '', branch: null }] }))
    .toMatchObject({ title: 'Committed 5 files', detail: 'e57cfce, def5678' })
})

test('commit toast: running titles and failures', () => {
  expect(commitRunningTitle(3, false)).toBe('Committing 3 files…')
  expect(commitRunningTitle(1, true)).toBe('Committing & pushing 1 file…')
  expect(commitRunningTitle(2, true, true)).toBe('Creating branch, committing & pushing 2 files…')
  expect(commitFailureToast(false, 'missing_git_identity')).toMatchObject({ tone: 'error', title: 'Commit failed', error: expect.stringContaining('user.name') })
  expect(commitFailureToast(true, 'head_moved')).toMatchObject({ tone: 'warning', title: 'Commit & push failed' })
  expect(commitFailureToast(true, 'other', 'boom').error).toBe('boom')
})

test('push toast: commits and upstream in the title, rejection offers pull & push', () => {
  const target = { root: '/repo', name: 'repo', branch: 'main', upstream: 'origin/main', ahead: 2 }
  expect(pushToast([{ target, push: 'pushed', message: null }])).toEqual({
    tone: 'success', title: 'Pushed 2 commits to origin/main', detail: 'repo', error: null, pull_push_root: null,
  })
  expect(pushToast([{ target: { ...target, ahead: 1 }, push: 'pushed', message: null }]).title).toBe('Pushed 1 commit to origin/main')
  expect(pushToast([{ target: { ...target, branch: 'feature/x', upstream: null, ahead: 1 }, push: 'pushed', message: null }]))
    .toMatchObject({ title: 'Published feature/x', detail: 'repo · feature/x' })
  expect(pushToast([{ target, push: 'rejected', message: null }])).toMatchObject({
    tone: 'warning', title: 'Push rejected', error: "Push rejected: The remote has commits you don't have.", pull_push_root: '/repo',
  })
  expect(pushToast([{ target, push: 'failed', message: 'auth failed' }])).toMatchObject({ tone: 'error', title: 'Push failed', error: 'Auth failed' })
  const lib = { root: '/lib', name: 'lib', branch: 'dev', upstream: 'origin/dev', ahead: 1 }
  expect(pushToast([{ target, push: 'pushed', message: null }, { target: lib, push: 'in_progress', message: null }]))
    .toMatchObject({ tone: 'warning', title: 'Pushed 2 commits to origin/main', error: 'dev: a push is already running' })
  expect(pushToast([{ target, push: 'pushed', message: null }, { target: lib, push: 'pushed', message: null }]))
    .toMatchObject({ tone: 'success', title: 'Pushed 3 commits to 2 branches', detail: 'repo main, lib dev' })
  expect(pushToast([])).toMatchObject({ tone: 'info', title: 'Nothing to push' })
  expect(pushRunningTitle(target)).toBe('Pushing 2 commits to origin/main…')
  expect(pushRunningTitle({ ...target, upstream: null })).toBe('Publishing main…')
})

test('pull & push toast', () => {
  const repo = { root: '/repo', name: 'repo', branch: 'main' }
  expect(pullPushToast(repo, { push: 'pushed' })).toEqual({ tone: 'success', title: 'Pulled & pushed', detail: 'repo · main', error: null, pull_push_root: null })
  expect(pullPushToast(repo, { push: 'rejected' })).toMatchObject({ tone: 'warning', title: 'Push rejected', pull_push_root: '/repo' })
  expect(pullPushToast(repo, { push: 'failed', push_message: 'conflict' })).toMatchObject({ tone: 'error', error: 'conflict' })
  expect(pullPushToast(repo, null, { code: 'turns_running' })).toMatchObject({ tone: 'warning', error: expect.stringContaining('still running') })
  expect(pullPushToast(repo, null, { code: 'x', message: 'rebase failed' })).toMatchObject({ tone: 'error', title: 'Pull & push failed', error: 'rebase failed' })
  expect(toastAutoDismisses('success')).toBe(true)
  expect(toastAutoDismisses('info')).toBe(true)
  expect(['running', 'warning', 'error'].some(toastAutoDismisses)).toBe(false)
})

test('commit error classification', () => {
  expect(commitErrorKind('changed_since_review')).toBe('reload')
  expect(commitErrorKind('review_expired')).toBe('reload')
  expect(commitErrorKind('head_moved')).toBe('retry')
  expect(commitErrorKind('missing_git_identity')).toBe('identity')
  expect(commitErrorKind('invalid_params')).toBe('other')
})

test('commit config parsing and patches', () => {
  expect(parseCommitConfig({})).toEqual({ provider: 'auto', model: null, default_action: 'commit' })
  const parsed = parseCommitConfig({ chat: { commit_message_provider: 'claude', commit_message_model: 'opus', commit_default_action: 'commit_and_push' } })
  expect(parsed).toEqual({ provider: 'claude', model: 'opus', default_action: 'commit_and_push' })
  expect(parseCommitConfig({ chat: { commit_message_provider: 'bogus' } }).provider).toBe('auto')
  expect(applyCommitConfigPatch(parsed, { commit_message_provider: 'codex', commit_message_model: '' })).toEqual({ provider: 'codex', model: null, default_action: 'commit_and_push' })
})

test('commit shortcut is Ctrl/Cmd+Enter only', () => {
  expect(isCommitShortcut({ key: 'Enter', ctrlKey: true, metaKey: false, isComposing: false })).toBe(true)
  expect(isCommitShortcut({ key: 'Enter', ctrlKey: false, metaKey: true, isComposing: false })).toBe(true)
  expect(isCommitShortcut({ key: 'Enter', ctrlKey: false, metaKey: false, isComposing: false })).toBe(false)
  expect(isCommitShortcut({ key: 'Enter', ctrlKey: true, metaKey: false, isComposing: true })).toBe(false)
})

const rawReview = (id = 'r1') => ({
  review_id: id, workspace_id: 'ws', local_thread_id: 't1', turn_running: true, default_action: 'commit_and_push',
  repos: [{ root: '/repo', name: 'repo', branch: 'main', files: [file('a.ts', 'mine'), file('b.ts', 'shared')] }],
})
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function harness(handler) {
  const calls = []
  let api
  let dispose
  createRoot((d) => {
    dispose = d
    api = createGitChanges({
      localCall: async (method, params) => { calls.push({ method, params }); return handler(method, params) },
      paneCall: async (_pane, method, params) => { calls.push({ method, params }); return handler(method, params) },
      route: () => ({ workspace_id: 'ws', local_thread_id: 't1', repository_id: 'primary', relative_cwd: null }),
      defaultAction: () => 'commit',
    })
  })
  return { api, calls, dispose }
}

test('opening the sheet loads the review with the chat route and auto-fills without clobbering typing', async () => {
  let resolveMessage
  const { api, calls, dispose } = harness((method) => {
    if (method === 'git.changes.review') return { result: rawReview() }
    if (method === 'git.changes.commit_message') return new Promise((resolve) => { resolveMessage = resolve })
    return { result: {} }
  })
  api.openSheet({})
  await flush()
  expect(calls[0]).toEqual({ method: 'git.changes.review', params: { workspace_id: 'ws', local_thread_id: 't1', repository_id: 'primary', relative_cwd: null, include_unassigned: true } })
  expect(api.review().turn_running).toBe(true)
  expect(api.primaryAction()).toBe('commit')
  expect(calls[1].params).toEqual({ review_id: 'r1', selections: [{ root: '/repo', files: [{ path: 'a.ts' }] }] })
  expect(api.messageStatus()).toBe('writing')
  api.setMessage('my own words')
  resolveMessage({ result: { message: 'Generated', provider: 'codex', model: 'gpt-6-luna' } })
  await flush()
  expect(api.message()).toBe('my own words')
  expect(api.messageStatus()).toBe('idle')
  dispose()
})

test('changed_since_review reloads the review and keeps the message', async () => {
  let reviews = 0
  const { api, calls, dispose } = harness((method) => {
    if (method === 'git.changes.review') return { result: rawReview(`r${++reviews}`) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a' } }
    if (method === 'git.changes.commit') return { ok: false, error: { code: 'changed_since_review', message: 'changed' } }
    return { result: {} }
  })
  api.openSheet({})
  await flush(); await flush()
  expect(api.message()).toBe('')
  expect(api.generated()).toBe('Add a')
  await api.commit('commit')
  expect(api.review().review_id).toBe('r2')
  expect(api.generated()).toBe('Add a')
  expect(api.error()).toContain('reloaded')
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toEqual({ review_id: 'r1', message: 'Add a', selections: [{ root: '/repo', files: [{ path: 'a.ts' }] }], push: false })
  dispose()
})

test('successful commit closes the sheet, toasts, and refreshes the summary', async () => {
  const { api, calls, dispose } = harness((method) => {
    if (method === 'git.changes.review') return { result: rawReview() }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a' } }
    if (method === 'git.changes.commit') return { result: { workspace_id: 'ws', local_thread_id: 't1', files: 1, repos: [{ root: '/repo', commit: 'e57cfce1', short_commit: 'e57cfce', subject: 'Add a', files: 1, push: 'rejected', index_reset: false }] } }
    if (method === 'git.changes.summary') return { result: { workspace_id: 'ws', revision: 3, threads: [] } }
    return { result: {} }
  })
  api.openSheet({})
  await flush(); await flush()
  await api.commit('commit_and_push')
  expect(api.sheetPane()).toBeNull()
  expect(api.toast()).toMatchObject({ tone: 'warning', title: 'Committed 1 file', detail: 'e57cfce · Add a' })
  expect(api.toast().action.label).toBe('Pull & push')
  await flush()
  expect(calls.some((call) => call.method === 'git.changes.summary')).toBe(true)
  dispose()
})

// ---- Header split button, quick path, and message box ----------------------

const repoStatus = (extra = {}) => ({
  root: '/repo', name: 'repo', branch: 'feature/x', default_branch: 'main', is_default_branch: false,
  upstream: 'origin/feature/x', ahead: 0, behind: 0, has_remote: true, ...extra,
})
const statusOf = (...repos) => ({ workspace_id: 'ws', local_thread_id: 't1', repos })
const changes = (files, attention = 0) => ({ local_thread_id: 't1', files, additions: 12, deletions: 3, attention })

test('status parsing keeps branch facts and defaults missing ones', () => {
  const parsed = parseStatusResult({ workspace_id: 'ws', local_thread_id: 't1', repos: [
    { root: '/repo', branch: 'main', default_branch: 'main', is_default_branch: true, upstream: 'origin/main', ahead: 2, behind: -1, has_remote: true },
    { name: 'no-root' },
  ] })
  expect(parsed.repos).toEqual([{ root: '/repo', name: 'repo', branch: 'main', default_branch: 'main', is_default_branch: true, upstream: 'origin/main', ahead: 2, behind: 0, has_remote: true }])
  expect(parseStatusResult({ repos: [] })).toBeNull()
  const reviewed = parseReviewResult({ review_id: 'r', repos: [{ root: '/r', branch: 'main', is_default_branch: true, ahead: 1, files: [] }] })
  expect(reviewed.repos[0]).toMatchObject({ branch: 'main', is_default_branch: true, ahead: 1, upstream: null, has_remote: false })
})

test('button label follows changes, then commits ahead, else hides', () => {
  const status = statusOf(repoStatus())
  expect(gitActionState({ summary: changes(4), status, defaultAction: 'commit' })).toMatchObject({ visible: true, primary: 'commit', label: 'Commit', count: 4, attention: false })
  expect(gitActionState({ summary: changes(4, 1), status, defaultAction: 'commit_and_push' })).toMatchObject({ primary: 'commit_and_push', label: 'Commit & push', count: 3, attention: true })
  // The badge counts what the quick path commits: files minus shared/unclear.
  expect(gitActionState({ summary: changes(2, 2), status, defaultAction: 'commit' })).toMatchObject({ visible: true, count: 0, attention: true })
  // Status not fetched yet: assume a remote and keep the configured default.
  expect(gitActionState({ summary: changes(1), status: null, defaultAction: 'commit_and_push' }).label).toBe('Commit & push')
  // No remote at all: pushing is impossible, so the default falls back to Commit.
  const local = gitActionState({ summary: changes(1), status: statusOf(repoStatus({ has_remote: false, upstream: null })), defaultAction: 'commit_and_push' })
  expect(local.label).toBe('Commit')
  expect(local.menu.find((item) => item.action === 'commit_and_push').disabled).toBe(true)

  const ahead = gitActionState({ summary: changes(0), status: statusOf(repoStatus({ ahead: 3 })), defaultAction: 'commit' })
  expect(ahead).toMatchObject({ visible: true, primary: 'push', label: '↑3 Push', count: 0 })
  expect(ahead.menu.map((item) => [item.action, item.disabled])).toEqual([['commit', true], ['commit_and_push', true], ['push', false]])

  expect(gitActionState({ summary: changes(0), status, defaultAction: 'commit' }).visible).toBe(false)
  expect(gitActionState({ summary: null, status: null, defaultAction: 'commit' }).visible).toBe(false)
})

test('menu offers Push without an upstream and Pull & push after a rejection', () => {
  const unpublished = statusOf(repoStatus({ upstream: null }))
  const plain = gitActionState({ summary: changes(2), status: unpublished, defaultAction: 'commit' })
  expect(plain.menu.map((item) => item.action)).toEqual(['commit', 'commit_and_push', 'push'])
  // Nothing to commit and an unpushed branch nobody asked to publish: hidden.
  expect(gitActionState({ summary: changes(0), status: unpublished, defaultAction: 'commit' }).visible).toBe(false)
  // A branch this client created is offered for publishing.
  const pending = new Set(['/repo\u0000feature/x'])
  expect(gitActionState({ summary: changes(0), status: unpublished, defaultAction: 'commit', pending })).toMatchObject({ visible: true, primary: 'push', label: '↑ Push' })
  expect(pushTargets(unpublished, false).length).toBe(0)
  expect(pushTargets(unpublished, true).map((repo) => repo.root)).toEqual(['/repo'])
  const rejected = gitActionState({ summary: changes(0), status: statusOf(repoStatus({ ahead: 1 })), defaultAction: 'commit', rejected: new Set(['/repo']) })
  expect(rejected.menu.map((item) => item.label)).toEqual(['Commit…', 'Commit & push', 'Push 1 commit', 'Pull & push'])
})

const planReview = (repoExtra, files) => parseReviewResult({
  review_id: 'r1', workspace_id: 'ws', local_thread_id: 't1', turn_running: false, default_action: 'commit',
  repos: [{ root: '/repo', name: 'repo', branch: 'feature/x', has_remote: true, ...repoExtra, files }],
})

test('quick commit plan commits only the chat\'s own files', () => {
  const a = { root: '/repo', files: [{ path: 'a.ts' }] }
  expect(quickCommitPlan(planReview({}, []))).toEqual({ kind: 'nothing' })
  expect(quickCommitPlan(planReview({}, []), false)).toEqual({ kind: 'nothing' })
  // Shared/unclear files never stop it while the chat has files of its own.
  expect(quickCommitPlan(planReview({}, [file('a.ts', 'mine'), file('b.ts', 'shared')])))
    .toEqual({ kind: 'direct', files: 1, left_out: 1, selections: [a] })
  expect(quickCommitPlan(planReview({}, [file('a.ts', 'mine'), file('b.ts', 'shared'), file('c.ts', 'unclear'), file('d.ts', 'unassigned')])))
    .toEqual({ kind: 'direct', files: 1, left_out: 2, selections: [a] })
  // Unassigned files next to the chat's own are simply left out (not counted).
  expect(quickCommitPlan(planReview({}, [file('a.ts', 'mine'), file('d.ts', 'unassigned')])))
    .toEqual({ kind: 'direct', files: 1, left_out: 0, selections: [a] })
  // Nothing of its own: the dialog decides.
  expect(quickCommitPlan(planReview({}, [file('d.ts', 'unassigned')]))).toEqual({ kind: 'dialog' })
  expect(quickCommitPlan(planReview({}, [file('b.ts', 'shared'), file('c.ts', 'unclear')]))).toEqual({ kind: 'dialog' })
  expect(quickCommitPlan(planReview({}, [file('b.ts', 'shared')]), false)).toEqual({ kind: 'dialog' })
  // Commit & push onto the default branch confirms, even with files left out.
  expect(quickCommitPlan(planReview({ branch: 'main', is_default_branch: true }, [file('a.ts', 'mine')])))
    .toMatchObject({ kind: 'confirm', branch: 'main', files: 1, left_out: 0 })
  expect(quickCommitPlan(planReview({ branch: 'main', is_default_branch: true }, [file('a.ts', 'mine'), file('c.ts', 'unclear')])))
    .toMatchObject({ kind: 'confirm', branch: 'main', files: 1, left_out: 1, selections: [a] })
  // Plain Commit never asks: a local commit on the default branch is fine.
  expect(quickCommitPlan(planReview({ branch: 'main', is_default_branch: true }, [file('a.ts', 'mine')]), false))
    .toEqual({ kind: 'direct', files: 1, left_out: 0, selections: [a] })
  // The default branch only matters for a repository holding the chat's files.
  const split = parseReviewResult({
    review_id: 'r1', workspace_id: 'ws', local_thread_id: 't1', turn_running: false, default_action: 'commit',
    repos: [
      { root: '/repo', name: 'repo', branch: 'feature/x', has_remote: true, files: [file('a.ts', 'mine')] },
      { root: '/lib', name: 'lib', branch: 'main', is_default_branch: true, has_remote: true, files: [file('d.ts', 'unassigned'), file('e.ts', 'shared')] },
    ],
  })
  expect(quickCommitPlan(split)).toEqual({ kind: 'direct', files: 1, left_out: 1, selections: [a] })
  expect(leftOutFileCount(split)).toBe(1)
})

test('quick commit toast names the files it left out', () => {
  expect(leftOutNote(1)).toBe('1 file left out (shared/unclear) — use Commit… to review them')
  expect(leftOutNote(2)).toBe('2 files left out (shared/unclear) — use Commit… to review them')
  const toast = commitToast({ files: 2, repos: [{ root: '/repo', commit: 'e57cfce1234', short_commit: 'e57cfce', subject: 'Fix', files: 2, branch: 'feature/x', push: 'pushed' }] })
  expect(noteLeftOut(toast, 2).detail).toBe('2 files left out (shared/unclear) — use Commit… to review them · e57cfce · feature/x · Fix')
  expect(noteLeftOut(toast, 0).detail).toBe('e57cfce · feature/x · Fix')
  expect(noteLeftOut({ ...toast, detail: null }, 1).detail).toBe('1 file left out (shared/unclear) — use Commit… to review them')
})

test('empty message commits the generated one; typing overrides it', () => {
  expect(effectiveCommitMessage('', 'Add login form')).toBe('Add login form')
  expect(effectiveCommitMessage('   \n', ' Add login form \n')).toBe('Add login form')
  expect(effectiveCommitMessage(' Fix typo ', 'Add login form')).toBe('Fix typo')
  expect(effectiveCommitMessage('', null)).toBe('')
  expect(commitMessagePlaceholder('writing', 'old')).toBe('Writing message…')
  expect(commitMessagePlaceholder('idle', 'Add login form')).toBe('Add login form')
  expect(commitMessagePlaceholder('idle', null)).toBe('Describe these changes')
  expect(commitMessagePlaceholder('error', null)).toContain("Couldn't write a message")
})

test('commit request sends new_branch fields only when used', () => {
  const base = { review_id: 'r', message: 'm', selections: [], push: true }
  expect(commitRequest({ ...base, branch_name: 'feature/x' })).toEqual(base)
  expect(commitRequest({ ...base, new_branch: true, branch_name: 'feature/x' })).toEqual({ ...base, new_branch: true, branch_name: 'feature/x' })
  expect(commitRequest({ ...base, new_branch: true, branch_name: null })).toEqual({ ...base, new_branch: true })
})

test('toast names a created branch and totals count picked hunks', () => {
  const repo = { root: '/repo', commit: 'e57cfce0', short_commit: 'e57cfce', subject: 's', files: 3, push: 'pushed', push_message: null, index_reset: false, branch: 'feature/login', branch_created: true }
  expect(commitToast({ files: 3, repos: [repo] })).toMatchObject({ title: 'Committed & pushed 3 files', detail: 'e57cfce · new branch feature/login · s' })
  expect(commitToast({ files: 3, repos: [{ ...repo, branch_created: false }] }).detail).toBe('e57cfce · feature/login · s')
  const current = review()
  const ticks = defaultTicks(current)
  ticks[fileKey('/repo', 'a.ts')] = [0, 1]
  expect(selectedTotals(current, ticks)).toEqual({ files: 2, additions: 3, deletions: 3 })
})

function actionHarness(handler, focused = null) {
  const calls = []
  let api, dispose
  const pane = { id: 'p1' }
  createRoot((d) => {
    dispose = d
    api = createGitChanges({
      localCall: async (method, params) => { calls.push({ method, params }); return handler(method, params) },
      paneCall: async (_pane, method, params) => { calls.push({ method, params }); return handler(method, params) },
      route: () => ({ workspace_id: 'ws', local_thread_id: 't1', repository_id: 'primary', relative_cwd: null }),
      defaultAction: () => 'commit_and_push',
      focusedPane: focused ?? undefined,
    })
  })
  return { api, calls, dispose, pane }
}
const commitOk = (extra = {}) => ({ result: { workspace_id: 'ws', local_thread_id: 't1', files: 1, repos: [{ root: '/repo', commit: 'abc12345', short_commit: 'abc1234', subject: 'Add a', files: 1, push: 'pushed', index_reset: false, branch: 'feature/x', ...extra }] } })

test('quick commit & push goes review → commit_message → commit(push) off the default branch', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('a.ts', 'mine'), file('d.ts', 'unassigned')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a\n\nBody', branch: 'feature/add-a' } }
    if (method === 'git.changes.commit') return commitOk()
    return { result: {} }
  })
  await api.commitAndPush(pane)
  expect(calls.slice(0, 3).map((call) => call.method)).toEqual(['git.changes.review', 'git.changes.commit_message', 'git.changes.commit'])
  expect(calls[2].params).toEqual({ review_id: 'r1', message: 'Add a\n\nBody', selections: [{ root: '/repo', files: [{ path: 'a.ts' }] }], push: true })
  expect(api.toast()).toMatchObject({ tone: 'success', title: 'Committed & pushed 1 file', detail: 'abc1234 · feature/x · Add a' })
  expect(api.sheetPane()).toBeNull()
  dispose()
})

test('quick path on the default branch confirms, and Create branch commits on the suggested branch', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({ branch: 'main', is_default_branch: true }, [file('a.ts', 'mine')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a', branch: 'feature/add-a' } }
    if (method === 'git.changes.commit') return commitOk({ branch: 'feature/add-a', branch_created: true })
    return { result: {} }
  })
  await api.commitAndPush(pane)
  expect(api.confirm()).toMatchObject({ branch: 'main', files: 1, status: 'ready', message: 'Add a', branch_name: 'feature/add-a' })
  expect(calls.some((call) => call.method === 'git.changes.commit')).toBe(false)
  await api.resolveConfirm('new_branch')
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toMatchObject({ push: true, new_branch: true, branch_name: 'feature/add-a' })
  expect(api.confirm()).toBeNull()
  expect(api.toast()).toMatchObject({ title: 'Committed & pushed 1 file', detail: 'abc1234 · new branch feature/add-a · Add a' })
  dispose()
})

test('quick commit & push leaves shared files out and names them in the toast', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('a.ts', 'mine'), file('b.ts', 'shared'), file('c.ts', 'unclear')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a' } }
    if (method === 'git.changes.commit') return commitOk()
    return { result: {} }
  })
  await api.commitAndPush(pane)
  expect(api.sheetPane()).toBeNull()
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toEqual({ review_id: 'r1', message: 'Add a', selections: [{ root: '/repo', files: [{ path: 'a.ts' }] }], push: true })
  expect(api.toast()).toMatchObject({ tone: 'success', title: 'Committed & pushed 1 file', detail: '2 files left out (shared/unclear) — use Commit… to review them · abc1234 · feature/x · Add a' })
  dispose()
})

test('quick path opens the dialog in commit & push mode when nothing is the chat\'s own', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('b.ts', 'shared'), file('d.ts', 'unassigned')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add b' } }
    return { result: {} }
  })
  await api.commitAndPush(pane)
  await flush()
  expect(api.sheetPane()).toBe(pane)
  expect(api.primaryAction()).toBe('commit_and_push')
  // The dialog reuses the quick path's review instead of fetching another.
  expect(calls.filter((call) => call.method === 'git.changes.review').length).toBe(1)
  expect(calls.some((call) => call.method === 'git.changes.commit')).toBe(false)
  dispose()
})

test('header Commit commits the chat\'s own files without a dialog, even on the default branch', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({ branch: 'main', is_default_branch: true }, [file('a.ts', 'mine'), file('b.ts', 'shared')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a' } }
    if (method === 'git.changes.commit') return commitOk({ push: 'not_requested', branch: 'main' })
    return { result: {} }
  })
  api.runAction(pane, 'commit', 'primary')
  for (let i = 0; i < 5; i += 1) await flush()
  expect(api.confirm()).toBeNull()
  expect(api.sheetPane()).toBeNull()
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toEqual({ review_id: 'r1', message: 'Add a', selections: [{ root: '/repo', files: [{ path: 'a.ts' }] }], push: false })
  expect(api.toast()).toMatchObject({ tone: 'success', title: 'Committed 1 file', detail: '1 file left out (shared/unclear) — use Commit… to review them · abc1234 · main · Add a' })
  dispose()
})

test('header Commit with no changes says so; the menu Commit… opens the dialog', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, []) }
    return { result: {} }
  })
  await api.quickCommit(pane)
  expect(api.toast()).toMatchObject({ tone: 'info', title: 'No uncommitted changes' })
  expect(api.sheetPane()).toBeNull()
  api.runAction(pane, 'commit', 'menu')
  expect(api.sheetPane()).toBe(pane)
  expect(api.primaryAction()).toBe('commit')
  expect(calls.some((call) => call.method === 'git.changes.commit')).toBe(false)
  dispose()
})

test('dialog: empty box commits the generated message, typing wins, ↻ clears typing', async () => {
  let n = 0
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('a.ts', 'mine')]) }
    if (method === 'git.changes.commit_message') return { result: { message: `Generated ${++n}`, branch: 'feature/gen' } }
    if (method === 'git.changes.commit') return commitOk({ push: 'not_requested' })
    return { result: {} }
  })
  api.openSheet(pane)
  await flush(); await flush()
  expect(api.message()).toBe('')
  expect(api.placeholder()).toBe('Generated 1')
  expect(api.canCommit()).toBe(true)
  api.setMessage('Mine')
  expect(api.effectiveMessage()).toBe('Mine')
  await api.regenerateMessage()
  expect(api.message()).toBe('')
  expect(api.effectiveMessage()).toBe('Generated 2')
  await api.commit('commit', true)
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toMatchObject({ message: 'Generated 2', push: false, new_branch: true, branch_name: 'feature/gen' })
  dispose()
})

test('push: a rejection offers Pull & push and shows it in the menu', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.status') return { result: statusOf(repoStatus({ ahead: 2 })) }
    if (method === 'git.changes.push') return { result: { root: '/repo', push: 'rejected' } }
    return { result: {} }
  })
  await api.push(pane)
  const pushCall = calls.find((call) => call.method === 'git.changes.push')
  expect(pushCall.params).toMatchObject({ workspace_id: 'ws', root: '/repo' })
  expect(typeof pushCall.params.request_id).toBe('string')
  expect(api.toast()).toMatchObject({ tone: 'warning', title: 'Push rejected' })
  expect(api.toast().action.label).toBe('Pull & push')
  expect(api.actionState(pane).menu.map((item) => item.action)).toContain('pull_push')
  dispose()
})

test('focused chat status is fetched alongside its workspace summary refresh', async () => {
  const { api, calls, dispose } = actionHarness((method) => {
    if (method === 'git.changes.status') return { result: statusOf(repoStatus({ ahead: 1 })) }
    if (method === 'git.changes.summary') return { result: { workspace_id: 'ws', revision: 1, threads: [] } }
    return { result: {} }
  }, () => ({ id: 'focused' }))
  // The focus-change effect only runs in the browser build of Solid (bun
  // resolves the server build), so count from here.
  await flush()
  const statusCalls = () => calls.filter((call) => call.method === 'git.changes.status')
  const before = statusCalls().length
  await api.refreshSummary('ws')
  await flush()
  expect(statusCalls().length).toBe(before + 1)
  expect(statusCalls().at(-1).params).toEqual({ workspace_id: 'ws', local_thread_id: 't1', repository_id: 'primary', relative_cwd: null })
  await api.refreshSummary('other')
  await flush()
  expect(statusCalls().length).toBe(before + 1)
  expect(api.actionState({}).label).toBe('↑1 Push')
  dispose()
})

test('dialog: nothing ticked disables commit; ticking then committing writes a fresh message first', async () => {
  let n = 0
  const { api, calls, dispose, pane } = actionHarness((method, params) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('b.ts', 'shared'), file('d.ts', 'unassigned')]) }
    if (method === 'git.changes.commit_message') return { result: { message: `Message ${++n} for ${params.selections[0].files.map((f) => f.path).join(',')}` } }
    if (method === 'git.changes.commit') return commitOk({ push: 'not_requested' })
    return { result: {} }
  })
  api.openSheet(pane)
  await flush(); await flush()
  expect(api.selectedFiles()).toBe(0)
  expect(api.canCommit()).toBe(false)
  expect(calls.some((call) => call.method === 'git.changes.commit_message')).toBe(false)
  const current = api.review()
  api.setFileTick('/repo', current.repos[0].files[0], 'all')
  expect(api.canCommit()).toBe(true)
  await api.commit('commit')
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toMatchObject({ message: 'Message 1 for b.ts', selections: [{ root: '/repo', files: [{ path: 'b.ts' }] }] })
  dispose()
})

test('dialog: hiding diffs regenerates a stale suggestion, and a stale one is rewritten before committing', async () => {
  let n = 0
  const { api, calls, dispose, pane } = actionHarness((method, params) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('a.ts', 'mine'), file('b.ts', 'shared')]) }
    if (method === 'git.changes.commit_message') return { result: { message: `Message ${++n}: ${params.selections[0].files.map((f) => f.path).join(',')}` } }
    if (method === 'git.changes.commit') return commitOk({ push: 'not_requested' })
    return { result: {} }
  })
  api.openSheet(pane)
  await flush(); await flush()
  expect(api.generated()).toBe('Message 1: a.ts')
  const [, shared] = api.review().repos[0].files
  api.setDiffsShown(true)
  expect(api.diffsShown()).toBe(true)
  api.setFileTick('/repo', shared, 'all')
  api.setDiffsShown(false)
  await flush(); await flush()
  expect(api.generated()).toBe('Message 2: a.ts,b.ts')
  // Ticking with diffs hidden leaves the suggestion stale until commit.
  api.setFileTick('/repo', shared, 'none')
  await api.commit('commit')
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params.message).toBe('Message 3: a.ts')
  expect(calls.filter((call) => call.method === 'git.changes.commit_message').length).toBe(3)
  dispose()
})

test('dialog: a failed message for the current ticks asks the user to type one', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('a.ts', 'mine')]) }
    if (method === 'git.changes.commit_message') return { ok: false, error: { code: 'provider_failed', message: 'nope' } }
    return { result: {} }
  })
  api.openSheet(pane)
  await flush(); await flush()
  expect(api.messageStatus()).toBe('error')
  await api.commit('commit')
  expect(api.error()).toContain('Type one')
  expect(calls.some((call) => call.method === 'git.changes.commit')).toBe(false)
  dispose()
})

// ---- Footer alternate action and commit transcript row ---------------------

test('alternate action: Commit from a push sheet, Commit & push only with a remote', () => {
  expect(commitAlternateAction('commit_and_push', [])).toBe('commit')
  expect(commitAlternateAction('commit', [{ has_remote: false }, { has_remote: true }])).toBe('commit_and_push')
  expect(commitAlternateAction('commit', [{ has_remote: false }])).toBeNull()
  expect(commitAlternateAction('commit', [])).toBeNull()
})

test('footer labels show progress only on the clicked button', () => {
  const busy = (push, new_branch, writing = false) => ({ push, new_branch, writing })
  expect(commitButtonLabel('commit', false, null)).toBe('Commit')
  expect(commitButtonLabel('commit_and_push', false, null)).toBe('Commit & push')
  expect(commitButtonLabel('commit', true, null)).toBe('Commit on new branch')
  // Alternate (Commit & push) clicked from a Commit sheet.
  expect(commitButtonLabel('commit_and_push', false, busy(true, false, true))).toBe('Writing message…')
  expect(commitButtonLabel('commit', false, busy(true, false, true))).toBe('Commit')
  expect(commitButtonLabel('commit', true, busy(true, false, true))).toBe('Commit on new branch')
  expect(commitButtonLabel('commit_and_push', false, busy(true, false))).toBe('Committing & pushing…')
  expect(commitButtonLabel('commit', false, busy(true, false))).toBe('Commit')
  // Primary and new-branch buttons.
  expect(commitButtonLabel('commit', false, busy(false, false))).toBe('Committing…')
  expect(commitButtonLabel('commit_and_push', false, busy(false, false))).toBe('Commit & push')
  expect(commitButtonLabel('commit', true, busy(false, true, true))).toBe('Writing message…')
  expect(commitButtonLabel('commit', true, busy(false, true))).toBe('Creating branch…')
  expect(commitButtonLabel('commit', false, busy(false, true))).toBe('Commit')
})

test('dialog: alternate Commit & push commits the selection with push, writing the message first', async () => {
  let resolveMessage
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({}, [file('a.ts', 'mine')]) }
    if (method === 'git.changes.commit_message') return new Promise((resolve) => { resolveMessage = resolve })
    if (method === 'git.changes.commit') return commitOk()
    return { result: {} }
  })
  api.openSheet(pane, { mode: 'commit' })
  await flush(); await flush()
  expect(api.alternateAction()).toBe('commit_and_push')
  const running = api.commit(api.alternateAction())
  await flush()
  expect(api.busy()).toEqual({ push: true, new_branch: false, writing: true })
  expect(commitButtonLabel('commit_and_push', false, api.busy())).toBe('Writing message…')
  expect(commitButtonLabel('commit', false, api.busy())).toBe('Commit')
  expect(api.canCommit()).toBe(false)
  resolveMessage({ result: { message: 'Add a', branch: 'feature/add-a' } })
  await running
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toEqual({ review_id: 'r1', message: 'Add a', selections: [{ root: '/repo', files: [{ path: 'a.ts' }] }], push: true })
  expect(api.sheetPane()).toBeNull()
  expect(api.confirm()).toBeNull()
  dispose()
})

test('dialog: alternate plain Commit from a Commit & push sheet does not push', async () => {
  const { api, calls, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({ has_remote: false }, [file('a.ts', 'mine')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a' } }
    if (method === 'git.changes.commit') return commitOk({ push: 'not_requested' })
    return { result: {} }
  })
  api.openSheet(pane, { mode: 'commit_and_push' })
  await flush(); await flush()
  expect(api.alternateAction()).toBe('commit')
  await api.commit(api.alternateAction())
  const commit = calls.find((call) => call.method === 'git.changes.commit')
  expect(commit.params).toMatchObject({ message: 'Add a', push: false })
  expect(commit.params.new_branch).toBeUndefined()
  dispose()
})

test('dialog: no remote hides the Commit & push alternate', async () => {
  const { api, dispose, pane } = actionHarness((method) => {
    if (method === 'git.changes.review') return { result: planReview({ has_remote: false }, [file('a.ts', 'mine')]) }
    if (method === 'git.changes.commit_message') return { result: { message: 'Add a' } }
    return { result: {} }
  })
  api.openSheet(pane, { mode: 'commit' })
  await flush(); await flush()
  expect(api.alternateAction()).toBeNull()
  dispose()
})

test('commit notice: full three-line body', () => {
  expect(parseCommitNotice('Committed 3 files: e57cfce · pushed\nAdd login form\nbranch feature/login')).toEqual({
    files: 3, commits: [{ sha: 'e57cfce', repo: null, pushed: true, url: null, local: false }], subject: 'Add login form', branch: 'feature/login',
  })
})

test('commit notice: older one-line rows and multiple repositories', () => {
  expect(parseCommitNotice('Committed 1 file: abc1234')).toEqual({
    files: 1, commits: [{ sha: 'abc1234', repo: null, pushed: false, url: null, local: false }], subject: null, branch: null,
  })
  expect(parseCommitNotice('Committed 4 files: abc1234 (app) · pushed, def5678 (lib)')).toEqual({
    files: 4,
    commits: [{ sha: 'abc1234', repo: 'app', pushed: true, url: null, local: false }, { sha: 'def5678', repo: 'lib', pushed: false, url: null, local: false }],
    subject: null, branch: null,
  })
})

test('commit notice: empty positional subject with a branch, and subject without branch', () => {
  expect(parseCommitNotice('Committed 2 files: abc1234\n\nbranch main')).toMatchObject({ subject: null, branch: 'main' })
  expect(parseCommitNotice('Committed 2 files: abc1234\nFix it')).toMatchObject({ subject: 'Fix it', branch: null })
})

test('commit notice: unrelated git text is not a commit card', () => {
  expect(parseCommitNotice('Pushed feature/x')).toBeNull()
  expect(parseCommitNotice('Committed 2 files: not-a-sha')).toBeNull()
  expect(parseCommitNotice('')).toBeNull()
})

test('commit notice: remote lines give each commit a web link', () => {
  const url = 'https://github.com/acme/app/commit/e57cfce0'
  expect(parseCommitNotice(`Committed 3 files: e57cfce · pushed\nAdd login\nbranch main\nremote ${url}`)).toEqual({
    files: 3, commits: [{ sha: 'e57cfce', repo: null, pushed: true, url, local: false }], subject: 'Add login', branch: 'main',
  })
  // Positional: blank subject/branch lines, one remote line per commit in order.
  const two = parseCommitNotice('Committed 4 files: abc1234 (app) · pushed, def5678 (lib) · pushed\n\n\nremote https://github.com/acme/app/commit/abc1234\nremote https://git.example.org/acme/lib/commit/def5678')
  expect(two).toMatchObject({ subject: null, branch: null })
  expect(two.commits.map((commit) => commit.url)).toEqual(['https://github.com/acme/app/commit/abc1234', 'https://git.example.org/acme/lib/commit/def5678'])
  // A repo without a remote leaves its line blank.
  expect(parseCommitNotice('Committed 4 files: abc1234 (app), def5678 (lib)\nFix\nbranch x\n\nremote https://h.io/c/def5678').commits.map((c) => c.url))
    .toEqual([null, 'https://h.io/c/def5678'])
  // Non-http(s) URLs never become links.
  expect(parseCommitNotice('Committed 1 file: abc1234\nFix\nbranch x\nremote javascript:alert(1)').commits[0].url).toBeNull()
  // Links only for pushed commits: older rows carried a link before the push.
  const unpushed = parseCommitNotice('Committed 1 file: 0aae44a\nFix\nbranch main\nremote https://github.com/o/r/commit/0aae44a')
  expect(commitNoticeLink(unpushed.commits[0])).toBeNull()
  expect(commitNoticeLink(parseCommitNotice(`Committed 3 files: e57cfce · pushed\nAdd login\nbranch main\nremote ${url}`).commits[0])).toEqual({ url, host: 'github.com' })
  expect(commitWebUrl('https://github.com/a/b/commit/1')).toEqual({ url: 'https://github.com/a/b/commit/1', host: 'github.com' })
  expect(commitWebUrl('not a url')).toBeNull()
})

test('commit notice: local line marks a repository with no remote', () => {
  const local = parseCommitNotice('Committed 1 file: abc1234\nwip\nbranch main\nlocal')
  expect(local.commits).toEqual([{ sha: 'abc1234', repo: null, pushed: false, url: null, local: true }])
  expect(commitNoticeLocalOnly(local)).toBe(true)
  // Never offers Push, even if the live status says the branch is ahead.
  expect(commitCardPushable(local, statusOf(repoStatus({ ahead: 1 })))).toBe(false)
  // Bare `remote` and older rows without the line are not local.
  expect(commitNoticeLocalOnly(parseCommitNotice('Committed 1 file: abc1234\n\n\nremote'))).toBe(false)
  expect(commitNoticeLocalOnly(parseCommitNotice('Committed 1 file: abc1234'))).toBe(false)
  const mixed = parseCommitNotice('Committed 2 files: abc1234 (app), def5678 (notes)\n\n\nremote\nlocal')
  expect(mixed.commits.map((commit) => commit.local)).toEqual([false, true])
  expect(commitNoticeLocalOnly(mixed)).toBe(false)
})

test('commit card offers Push only for unpushed rows with something to push on their branch', () => {
  const notice = parseCommitNotice('Committed 1 file: abc1234\nFix\nbranch feature/x')
  const pushed = parseCommitNotice('Committed 1 file: abc1234 · pushed\nFix\nbranch feature/x')
  expect(commitCardPushable(notice, statusOf(repoStatus({ ahead: 1 })))).toBe(true)
  expect(commitCardPushable(pushed, statusOf(repoStatus({ ahead: 1 })))).toBe(false)
  // Up to date, no status yet, or no remote: nothing to push.
  expect(commitCardPushable(notice, statusOf(repoStatus()))).toBe(false)
  expect(commitCardPushable(notice, null)).toBe(false)
  expect(commitCardPushable(notice, statusOf(repoStatus({ ahead: 1, has_remote: false })))).toBe(false)
  // Unpublished branch (no upstream) can be published.
  expect(commitCardPushable(notice, statusOf(repoStatus({ upstream: null })))).toBe(true)
  // The chat moved to another branch: pushing it would not publish this commit.
  expect(commitCardPushable(notice, statusOf(repoStatus({ branch: 'other', ahead: 2 })))).toBe(false)
  // Rows without a branch line fall back to any pushable branch.
  expect(commitCardPushable(parseCommitNotice('Committed 1 file: abc1234'), statusOf(repoStatus({ ahead: 1 })))).toBe(true)
})

import { expect, test } from 'bun:test'
import { createRoot } from 'solid-js'

import { buildSelections, carryTicks, createGitChanges, defaultTicks, fileKey, normalizeTick, leftOutFileCount, parseReviewResult, quickCommitPlan, selectionFileCount, toggleFileTick, toggleHunkTick } from './git_changes.ts'

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
  dispose()
})

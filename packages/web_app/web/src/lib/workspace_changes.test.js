import { expect, test } from 'bun:test'
import {
  FILTER_ALL, FILTER_UNASSIGNED, changesErrorText, filterOptions, filterRepos, ownerChip,
  parseFilePatch, parseWorkspaceChanges, repoPromptPath, statusLetter, totals, validFilter,
} from './workspace_changes'

const owner = (id, title, unclear = false) => ({ local_thread_id: id, title, unclear })
const raw = {
  workspace_id: 'ws', revision: 7,
  repos: [
    {
      root: '/w/app', name: 'app', branch: 'main', is_default_branch: true, ahead: 1, has_remote: true, head: 'abc',
      files: [
        { path: 'a.ts', status: 'modified', ownership: 'mine', owners: [owner('t1', 'Fix login')], additions: 3, deletions: 1 },
        { path: 'b.ts', status: 'added', untracked: true, ownership: 'unassigned', owners: [], additions: 10 },
        { path: 'c.ts', status: 'deleted', ownership: 'shared', owners: [owner('t1', 'Fix login'), owner('t2', 'Docs')], deletions: 4 },
        { path: '', status: 'modified' },
        'junk',
      ],
    },
    { root: '/w/lib', too_many_files: true, files: [] },
    { name: 'no root' },
  ],
}

test('workspace changes parse defensively', () => {
  const parsed = parseWorkspaceChanges(raw)
  expect(parsed.revision).toBe(7)
  expect(parsed.repos.map((repo) => repo.name)).toEqual(['app', 'lib'])
  expect(parsed.repos[0].files.map((file) => file.path)).toEqual(['a.ts', 'b.ts', 'c.ts'])
  expect(parsed.repos[0].files[1]).toMatchObject({ untracked: true, deletions: 0, ownership: 'unassigned' })
  expect(parsed.repos[1].too_many_files).toBe(true)
  expect(parseWorkspaceChanges({ repos: [] })).toBeNull()
  // Missing ownership is derived from owners.
  const derived = parseWorkspaceChanges({ workspace_id: 'ws', repos: [{ root: '/r', files: [{ path: 'x', owners: [owner('a', 'A'), owner('b', 'B')] }] }] })
  expect(derived.repos[0].files[0].ownership).toBe('shared')
})

test('filter options list claiming chats then unassigned', () => {
  const parsed = parseWorkspaceChanges(raw)
  expect(filterOptions(parsed)).toEqual([
    { key: FILTER_ALL, label: 'All', files: 3 },
    { key: 't1', label: 'Fix login', files: 2 },
    { key: 't2', label: 'Docs', files: 1 },
    { key: FILTER_UNASSIGNED, label: 'Unassigned', files: 1 },
  ])
  expect(filterOptions(parsed, (id) => (id === 't2' ? 'Live title' : null))[2].label).toBe('Live title')
})

test('filtering narrows files and drops empty repos', () => {
  const parsed = parseWorkspaceChanges(raw)
  expect(filterRepos(parsed, 't2').map((repo) => repo.files.map((file) => file.path))).toEqual([['c.ts']])
  expect(filterRepos(parsed, FILTER_UNASSIGNED)[0].files.map((file) => file.path)).toEqual(['b.ts'])
  // Too-many-files repos stay visible only under All.
  expect(filterRepos(parsed, FILTER_ALL).map((repo) => repo.name)).toEqual(['app', 'lib'])
  expect(totals(filterRepos(parsed, 't1'))).toEqual({ files: 2, additions: 3, deletions: 5 })
  expect(validFilter(parsed, 't9')).toBe(FILTER_ALL)
  expect(validFilter(parsed, 't2')).toBe('t2')
})

test('status letters and owner chips', () => {
  expect(statusLetter({ status: 'added', untracked: true }).letter).toBe('U')
  expect(statusLetter({ status: 'deleted', untracked: false })).toMatchObject({ letter: 'D', tone: 'del' })
  expect(statusLetter({ status: 'copied', untracked: false }).letter).toBe('C')
  expect(ownerChip({ ownership: 'unassigned', owners: [] })).toMatchObject({ text: 'Unassigned', tone: 'none' })
  expect(ownerChip({ ownership: 'mine', owners: [owner('t1', 'Fix')] })).toMatchObject({ text: 'Fix', tone: 'owned' })
  expect(ownerChip({ ownership: 'unclear', owners: [owner('t1', 'Fix', true)] })).toMatchObject({ text: 'Fix ?', tone: 'attention' })
  expect(ownerChip({ ownership: 'shared', owners: [owner('t1', 'Fix'), owner('t2', 'Docs')] }).text).toBe('Fix +1')
})

test('file patch parse and error text', () => {
  expect(parseFilePatch({ root: '/r', path: 'a', patch: '@@', additions: 1, context_lines: 3 })).toMatchObject({ patch: '@@', context_lines: 3, clean: false })
  expect(parseFilePatch({ root: '/r', path: 'a', clean: true })).toMatchObject({ clean: true, patch: null, context_lines: null })
  expect(parseFilePatch({ path: 'a' })).toBeNull()
  expect(changesErrorText('method_not_found')).toContain('does not support')
  expect(changesErrorText('weird', 'Boom')).toBe('Boom')
})

test('repo prompt paths are bare only for the workspace home repo', () => {
  expect(repoPromptPath({ root: '/w/verde/', name: 'verde' }, 'src/a.ts', '/w/verde')).toBe('src/a.ts')
  expect(repoPromptPath({ root: '/w/verde/lib', name: 'lib' }, 'a.c', '/w/verde')).toBe('lib/a.c')
  expect(repoPromptPath({ root: '/w/verde', name: 'verde' }, 'a', null)).toBe('verde/a')
  expect(changesErrorText('capability_unavailable')).toContain('unavailable')
})

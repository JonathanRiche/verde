/**
 * Changes panel data: every uncommitted file across a workspace's
 * repositories (`git.changes.workspace`) and lazily fetched per-file patches
 * (`git.changes.file_patch`), filtered by the chat that claimed each file.
 * See headless git_changes_protocol.zig. Read-only; commits go through the
 * per-chat commit sheet.
 */
import type { RepoStatus } from './git_changes'
import type { RpcEnvelope } from './types'

export type WorkspaceOwnership = 'mine' | 'shared' | 'unclear' | 'unassigned'
export interface WorkspaceOwner { local_thread_id: string; title: string; unclear: boolean }
export interface WorkspaceFile {
  path: string
  /// `modified`, `added`, `deleted` (untracked files are `added`), or any
  /// newer status the daemon reports.
  status: string
  untracked: boolean
  ownership: WorkspaceOwnership
  owners: WorkspaceOwner[]
  additions: number
  deletions: number
  binary: boolean
}
export interface WorkspaceRepo extends RepoStatus { head: string | null; too_many_files: boolean; files: WorkspaceFile[] }
export interface WorkspaceChanges { workspace_id: string; revision: number; repos: WorkspaceRepo[] }

export interface FilePatch {
  root: string
  path: string
  clean: boolean
  status: string
  binary: boolean
  truncated: boolean
  additions: number
  deletions: number
  context_lines: number | null
  patch: string | null
}

/// Context the view asks for to expand every collapsed run (whole file).
export const FULL_CONTEXT_LINES = 1_000_000

const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0)
const str = (value: unknown): string => (typeof value === 'string' ? value : '')
const optStr = (value: unknown): string | null => (typeof value === 'string' && value ? value : null)
const OWNERSHIPS: readonly WorkspaceOwnership[] = ['mine', 'shared', 'unclear', 'unassigned']
const record = (value: unknown): Record<string, unknown> | null =>
  value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
const rows = (value: unknown): Record<string, unknown>[] =>
  (Array.isArray(value) ? value : []).flatMap((row) => { const item = record(row); return item ? [item] : [] })

function parseFile(file: Record<string, unknown>): WorkspaceFile | null {
  if (typeof file.path !== 'string' || !file.path) return null
  const owners = rows(file.owners).flatMap((owner) =>
    typeof owner.local_thread_id === 'string' && owner.local_thread_id
      ? [{ local_thread_id: owner.local_thread_id, title: str(owner.title), unclear: owner.unclear === true }] : [])
  let ownership = OWNERSHIPS.includes(file.ownership as WorkspaceOwnership) ? file.ownership as WorkspaceOwnership : null
  ownership ??= owners.length === 0 ? 'unassigned' : owners.length > 1 ? 'shared' : 'mine'
  return {
    path: file.path, status: str(file.status) || 'modified', untracked: file.untracked === true,
    ownership, owners, additions: num(file.additions), deletions: num(file.deletions), binary: file.binary === true,
  }
}

export function parseWorkspaceChanges(value: unknown): WorkspaceChanges | null {
  const root = record(value)
  if (!root || typeof root.workspace_id !== 'string') return null
  const repos = rows(root.repos).flatMap((repo): WorkspaceRepo[] => {
    if (typeof repo.root !== 'string' || !repo.root) return []
    return [{
      root: repo.root, name: str(repo.name) || repo.root.split('/').filter(Boolean).at(-1) || repo.root,
      branch: optStr(repo.branch), default_branch: optStr(repo.default_branch),
      is_default_branch: repo.is_default_branch === true, upstream: optStr(repo.upstream),
      ahead: num(repo.ahead), behind: num(repo.behind), has_remote: repo.has_remote === true,
      head: optStr(repo.head), too_many_files: repo.too_many_files === true,
      files: rows(repo.files).flatMap((file) => { const parsed = parseFile(file); return parsed ? [parsed] : [] }),
    }]
  })
  return { workspace_id: root.workspace_id, revision: num(root.revision), repos }
}

export function parseFilePatch(value: unknown): FilePatch | null {
  const root = record(value)
  if (!root || typeof root.root !== 'string' || typeof root.path !== 'string') return null
  return {
    root: root.root, path: root.path, clean: root.clean === true, status: str(root.status) || 'modified',
    binary: root.binary === true, truncated: root.truncated === true,
    additions: num(root.additions), deletions: num(root.deletions),
    context_lines: typeof root.context_lines === 'number' ? num(root.context_lines) : null,
    patch: typeof root.patch === 'string' ? root.patch : null,
  }
}

// ---- Chat filter -------------------------------------------------------------

/// `all`, `unassigned`, or a local thread id.
export type ChangesFilter = string
export const FILTER_ALL = 'all'
export const FILTER_UNASSIGNED = 'unassigned'

export interface FilterOption { key: ChangesFilter; label: string; files: number }

/// All, then each chat that claimed files (most files first), then
/// Unassigned when any file has no owner.
export function filterOptions(changes: WorkspaceChanges | null, titleFor: (thread_id: string) => string | null = () => null): FilterOption[] {
  let total = 0
  let unassigned = 0
  const chats = new Map<string, FilterOption>()
  for (const repo of changes?.repos ?? []) {
    for (const file of repo.files) {
      total += 1
      if (file.owners.length === 0) { unassigned += 1; continue }
      for (const owner of file.owners) {
        const row = chats.get(owner.local_thread_id)
        if (row) row.files += 1
        else chats.set(owner.local_thread_id, { key: owner.local_thread_id, label: titleFor(owner.local_thread_id) || owner.title || 'Untitled chat', files: 1 })
      }
    }
  }
  const options: FilterOption[] = [{ key: FILTER_ALL, label: 'All', files: total }]
  options.push(...[...chats.values()].sort((a, b) => b.files - a.files || a.label.localeCompare(b.label)))
  if (unassigned > 0) options.push({ key: FILTER_UNASSIGNED, label: 'Unassigned', files: unassigned })
  return options
}

export function fileMatchesFilter(file: WorkspaceFile, filter: ChangesFilter): boolean {
  if (filter === FILTER_ALL) return true
  if (filter === FILTER_UNASSIGNED) return file.owners.length === 0
  return file.owners.some((owner) => owner.local_thread_id === filter)
}

/// Repos with their files narrowed to the filter. Clean repos are dropped;
/// a repo with too many files stays visible under All so the user learns why.
export function filterRepos(changes: WorkspaceChanges | null, filter: ChangesFilter): WorkspaceRepo[] {
  return (changes?.repos ?? []).flatMap((repo) => {
    const files = repo.files.filter((file) => fileMatchesFilter(file, filter))
    if (files.length > 0 || (repo.too_many_files && filter === FILTER_ALL)) return [{ ...repo, files }]
    return []
  })
}

/// A filter whose chat no longer owns anything falls back to All.
export function validFilter(changes: WorkspaceChanges | null, filter: ChangesFilter): ChangesFilter {
  if (filter === FILTER_ALL || !changes) return filter
  return filterOptions(changes).some((option) => option.key === filter) ? filter : FILTER_ALL
}

export function totals(repos: WorkspaceRepo[]): { files: number; additions: number; deletions: number } {
  let files = 0, additions = 0, deletions = 0
  for (const repo of repos) for (const file of repo.files) { files += 1; additions += file.additions; deletions += file.deletions }
  return { files, additions, deletions }
}

// ---- Row labels ----------------------------------------------------------------

/// One-letter status badge (`M`/`A`/`D`/`U` untracked/`R`).
export function statusLetter(file: Pick<WorkspaceFile, 'status' | 'untracked'>): { letter: string; label: string; tone: 'add' | 'del' | 'mod' } {
  if (file.untracked) return { letter: 'U', label: 'Untracked', tone: 'add' }
  switch (file.status) {
    case 'added': return { letter: 'A', label: 'Added', tone: 'add' }
    case 'deleted': return { letter: 'D', label: 'Deleted', tone: 'del' }
    case 'modified': return { letter: 'M', label: 'Modified', tone: 'mod' }
    case 'renamed': return { letter: 'R', label: 'Renamed', tone: 'mod' }
    default: return { letter: (file.status[0] ?? '?').toUpperCase(), label: file.status || 'Changed', tone: 'mod' }
  }
}

/// Owner chip: the claiming chat, `title +N` when shared, `?` when unclear.
export function ownerChip(file: Pick<WorkspaceFile, 'ownership' | 'owners'>, titleFor: (thread_id: string) => string | null = () => null): { text: string; title: string; tone: 'none' | 'owned' | 'attention' } {
  const name = (owner: WorkspaceOwner) => titleFor(owner.local_thread_id) || owner.title || 'Untitled chat'
  const [first, ...rest] = file.owners
  if (!first) return { text: 'Unassigned', title: 'No chat claimed this file', tone: 'none' }
  const names = file.owners.map(name)
  const unclear = file.ownership === 'unclear' || file.owners.some((owner) => owner.unclear)
  const text = rest.length > 0 ? `${name(first)} +${rest.length}` : `${name(first)}${unclear ? ' ?' : ''}`
  const title = rest.length > 0 ? `Changed by ${names.join(', ')}` : unclear ? `Probably changed by ${names[0]}` : `Changed by ${names[0]}`
  return { text, title, tone: rest.length > 0 || unclear ? 'attention' : 'owned' }
}

/// `dir/` prefix and basename for a two-tone path label.
export function splitPath(path: string): { dir: string; name: string } {
  const slash = path.lastIndexOf('/')
  return slash < 0 ? { dir: '', name: path } : { dir: path.slice(0, slash + 1), name: path.slice(slash + 1) }
}

const trimSlash = (path: string): string => path.replace(/\/+$/, '')

/// Path of a repository file in chat prompts: bare when the repository is
/// the workspace home, else `<repo name>/<path>`.
export function repoPromptPath(repo: Pick<WorkspaceRepo, 'root' | 'name'>, path: string, home: string | null | undefined): string {
  return home && trimSlash(repo.root) === trimSlash(home) ? path : `${repo.name}/${path}`
}

export const patchKey = (root: string, path: string): string => `${root}\u0000${path}`

/// Plain-language text for a daemon error code.
export function changesErrorText(code: string | undefined, message: string | undefined): string {
  switch (code) {
    case 'method_not_found': case 'unknown_method': case 'unsupported':
      return 'This Verde daemon does not support the Changes view yet. Update and restart the daemon.'
    case 'resource_not_found': return 'This workspace is no longer available.'
    case 'capability_unavailable': return 'Changes are unavailable for this workspace (git is missing or the daemon cannot read it).'
    case 'invalid_params': return 'That file is not part of this repository.'
    case 'path_outside_roots': case 'path_outside_workspace': return 'That repository is not part of this workspace.'
    default: return message || 'Could not load changes.'
  }
}

/// `{ code, message }` of a failed envelope, or null on success.
export function rpcFailure(response: RpcEnvelope): { code?: string; message?: string } | null {
  if (!response.error && response.ok !== false) return null
  const error = response.error as { code?: string; message?: string } | string | undefined
  return typeof error === 'string' ? { code: error, message: error } : { code: error?.code, message: error?.message }
}

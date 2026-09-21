import { createSignal } from 'solid-js'
import { unwrapResult } from './live'
import type { RpcEnvelope, Thread, Workspace } from './types'

export interface RepositoryManifest {
  workspace_id: string
  repositories: Array<{ repository_id: string; label: string; bindings: Array<{ runtime_id: string; root_path: string; availability?: string }> }>
}
export interface ChatCwdChoice {
  id: string
  label: string
  path: string
  repository_id: string
  relative_cwd: string | null
}
export function safeRelativeCwd(path: string): boolean {
  return path.length > 0 && path.length <= 4096 && !path.startsWith('/') && !/[\\\x00-\x1f:]/.test(path) && path.split('/').every((part) => part !== '..' && part !== '.' && part !== '')
}
const absoluteRoot = (path: string) => path.startsWith('/') && !/[\\\x00-\x1f]/.test(path) && !path.split('/').some((part) => part === '..' || part === '.')
export const chatCwdLocked = (thread: Partial<Thread>, working = false) => working || Boolean(thread.committed || thread.provider_thread_id || thread.runtime_id)

/** Only manifest bindings and previously reported thread subfolders are selectable. */
export function buildChatCwdChoices(workspace: Workspace, manifest: RepositoryManifest | null, runtimeId: string | null, local: boolean, known: readonly Partial<Thread>[] = []): ChatCwdChoice[] {
  const choices = new Map<string, ChatCwdChoice>()
  const add = (repository_id: string, label: string, root: string, relative_cwd: string | null) => {
    const id = JSON.stringify([repository_id, relative_cwd])
    choices.set(id, { id, label: relative_cwd ? `${label} / ${relative_cwd}` : label, path: relative_cwd ? `${root.replace(/\/$/, '')}/${relative_cwd}` : root, repository_id, relative_cwd })
  }
  if (!manifest || manifest.workspace_id !== workspace.workspace_id || !runtimeId) return []
  for (const repository of manifest.repositories ?? []) {
    const binding = repository.bindings?.find((row) => row.runtime_id === runtimeId && (!row.availability || row.availability === 'available'))
    if (!binding || !absoluteRoot(binding.root_path)) continue
    if (local && repository.repository_id === 'primary' && binding.root_path !== workspace.path) continue
    add(repository.repository_id, repository.repository_id === 'primary' ? 'Workspace root' : repository.label, binding.root_path, null)
    for (const thread of known) {
      if ((thread.repository_id ?? 'primary') !== repository.repository_id || (thread.runtime_id && thread.runtime_id !== runtimeId)) continue
      if (thread.repository_cwd && safeRelativeCwd(thread.repository_cwd)) add(repository.repository_id, repository.label, binding.root_path, thread.repository_cwd)
    }
  }
  return [...choices.values()]
}

/** Keep legacy local roots; explicit repository choices use daemon path validation. */
export function chatCwdTurnParams(thread: Pick<Thread, 'repository_id' | 'repository_cwd'>, remote: boolean, workspacePath: string) {
  return remote || thread.repository_cwd || (thread.repository_id && thread.repository_id !== 'primary')
    ? { repository_id: thread.repository_id ?? 'primary', relative_cwd: thread.repository_cwd ?? null, ...(remote ? { require_provider_ready: true } : {}) }
    : { project_path: workspacePath }
}

export function createChatCwdApi<Pane>(deps: {
  context: (pane: Pane) => Promise<{ key: string; workspace: Workspace; runtimeId: string | null; local: boolean; known: Thread[] }>
  call: (pane: Pane, method: string, params: unknown) => Promise<RpcEnvelope>
  locked: (pane: Pane) => boolean
  save: (pane: Pane, choice: ChatCwdChoice) => Promise<boolean>
  notice: (message: string) => void
}) {
  const [states, setStates] = createSignal<Record<string, ChatCwdChoice[]>>({})
  async function listChatCwdChoices(pane: Pane): Promise<ChatCwdChoice[]> {
    try {
      const context = await deps.context(pane)
      const response = await deps.call(pane, 'workspace.repository.manifest.get', { workspace_id: context.workspace.workspace_id })
      const manifest = response.error || response.ok === false ? null : unwrapResult<RepositoryManifest>(response)
      const choices = buildChatCwdChoices(context.workspace, manifest, context.runtimeId, context.local, context.known)
      setStates((previous) => ({ ...previous, [context.key]: choices }))
      if (!manifest || manifest.workspace_id !== context.workspace.workspace_id) deps.notice('Repository choices are unavailable; no working directory can be selected until validation succeeds.')
      return choices
    } catch {
      deps.notice('Could not load working-directory choices for this connection.')
      return []
    }
  }
  async function setChatCwd(pane: Pane, choiceId: string): Promise<boolean> {
    if (deps.locked(pane)) { deps.notice('Start a new chat to change its working directory; this route is locked.'); return false }
    const before = await deps.context(pane)
    const choices = await listChatCwdChoices(pane)
    const after = await deps.context(pane)
    if (before.key !== after.key || deps.locked(pane)) { deps.notice('The chat route changed or became locked. Select a directory again.'); return false }
    const choice = choices.find((row) => row.id === choiceId)
    if (!choice) { deps.notice('Choose a directory reported for this workspace.'); return false }
    return deps.save(pane, choice)
  }
  return { listChatCwdChoices, setChatCwd, chatCwdChoices: (key: string) => states()[key] ?? [] }
}

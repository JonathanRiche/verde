import { unwrapResult } from './live'
import type { RpcEnvelope, Thread, Workspace } from './types'

export interface HistoryThread extends Thread {
  workspace_id: string
  open: boolean
}

export interface HistoryGroup {
  label: 'Today' | 'This week' | 'Older'
  threads: HistoryThread[]
}

/** Match desktop's rolling 24-hour / seven-day buckets. Times are Unix seconds. */
export function groupHistory(threads: readonly HistoryThread[], nowSeconds: number): HistoryGroup[] {
  const groups: HistoryGroup[] = [
    { label: 'Today', threads: [] },
    { label: 'This week', threads: [] },
    { label: 'Older', threads: [] },
  ]
  for (const thread of [...threads].sort((a, b) => (b.last_activity_at ?? 0) - (a.last_activity_at ?? 0))) {
    const age = nowSeconds - (thread.last_activity_at ?? 0)
    groups[age < 86400 ? 0 : age < 604800 ? 1 : 2].threads.push(thread)
  }
  return groups.filter((group) => group.threads.length > 0)
}

interface HistoryDependencies {
  call: (method: string, params: unknown) => Promise<RpcEnvelope>
  mutation: () => Promise<{ client_id: string; request_key: string }>
  notice: (message: string | null) => void
  threadChanged: (workspaceId: string, thread: Pick<Thread, 'local_thread_id' | 'archived'>, revision: number) => void
  workspaceReopened: (workspace: Workspace) => void
}

/** Daemon-only operations; callers own their local pane projection. */
export function createHistoryApi(deps: HistoryDependencies) {
  async function request<T>(method: string, params: unknown): Promise<T> {
    const response = await deps.call(method, params)
    const result = unwrapResult<T>(response)
    if (response.error || response.ok === false || !result) {
      throw new Error(response.error?.message ?? `${method} failed`)
    }
    return result
  }

  async function attempt<T>(action: () => Promise<T>): Promise<T | null> {
    deps.notice(null)
    try {
      return await action()
    } catch (error) {
      deps.notice(error instanceof Error ? error.message : 'History operation failed')
      return null
    }
  }

  async function pages<T>(method: string, params: object, key: string): Promise<T[]> {
    const rows: T[] = []
    const seen = new Set<string>()
    let cursor: string | undefined
    do {
      const page = await request<Record<string, unknown>>(method, { ...params, limit: 100, cursor })
      if (!Array.isArray(page[key])) throw new Error(`Invalid ${method} response`)
      rows.push(...page[key] as T[])
      const next = page.next_cursor
      if (next != null && (typeof next !== 'string' || !next || seen.has(next))) {
        throw new Error(`Invalid ${method} cursor`)
      }
      cursor = next as string | undefined
      if (cursor) seen.add(cursor)
    } while (cursor)
    return rows
  }

  function loadHistory(workspaceId: string): Promise<HistoryThread[] | null> {
    return attempt(() => {
      if (!workspaceId) throw new Error('Workspace is required')
      return pages<HistoryThread>('chat.thread.list', {
        workspace_id: workspaceId, open: false, recent_first: true,
      }, 'threads')
    })
  }

  async function changeThread(workspaceId: string, threadId: string, archived: boolean): Promise<boolean> {
    return (await attempt(async () => {
      if (!workspaceId || !threadId) throw new Error('Workspace and thread are required')
      const mutation = await deps.mutation()
      const current = await request<{ store_revision: number }>('daemon.storeStatus', {})
      if (!Number.isSafeInteger(current.store_revision)) throw new Error('Missing thread store revision')
      const response = await deps.call('chat.thread.archive.set', {
        mutation: { ...mutation, expected_store_revision: current.store_revision },
        workspace_id: workspaceId, local_thread_id: threadId, archived,
      })
      if (['method_not_found', 'unknown_method'].includes(response.error?.code ?? '')) {
        throw new Error('update Verde to archive from the web')
      }
      const result = unwrapResult<{ store_revision: number }>(response)
      if (response.error || response.ok === false || !Number.isSafeInteger(result?.store_revision)) {
        throw new Error(response.error?.message ?? 'Could not change thread archive state')
      }
      deps.threadChanged(workspaceId, { local_thread_id: threadId, archived }, result!.store_revision)
      return true
    })) ?? false
  }

  function listArchivedWorkspaces(): Promise<Workspace[] | null> {
    return attempt(async () => (await pages<Workspace>('workspace.list', {
      include_archived: true,
    }, 'workspaces')).filter((workspace) => workspace.archived))
  }

  async function reopenWorkspace(workspaceId: string): Promise<boolean> {
    return (await attempt(async () => {
      if (!workspaceId) throw new Error('Workspace is required')
      const mutation = await deps.mutation()
      // List rows omit layout and other metadata. Read the complete workspace
      // before upserting so reopening cannot reset those fields to defaults.
      const current = await request<{
        snapshot?: { workspaces?: Workspace[] }; workspaces?: Workspace[]; store_revision: number
      }>('core.snapshot', { workspace_id: workspaceId, scopes: ['workspaces'] })
      const workspace = (current.snapshot?.workspaces ?? current.workspaces ?? [])
        .find((row) => row.workspace_id === workspaceId)
      if (!workspace) throw new Error('Saved workspace not found')
      if (!Number.isSafeInteger(current.store_revision)) throw new Error('Missing workspace store revision')
      const metadata = { ...workspace, archived: false }
      delete metadata.threads
      delete metadata.messages
      await request('workspace.upsert', {
        mutation: { ...mutation, expected_store_revision: current.store_revision }, workspace: metadata,
      })
      deps.workspaceReopened(metadata)
      return true
    })) ?? false
  }

  return {
    loadHistory,
    openHistoryThread: (workspaceId: string, threadId: string): Promise<boolean> => changeThread(workspaceId, threadId, false),
    archiveThread: (workspaceId: string, threadId: string): Promise<boolean> => changeThread(workspaceId, threadId, true),
    listArchivedWorkspaces,
    reopenWorkspace,
  }
}

/** Only a newer daemon read may override an optimistic archive. */
export function reconcileHistoryArchives(
  pending: Map<string, number>, workspaceId: string, threads: readonly (Thread & { open?: boolean })[], revision: number,
): void {
  if (!Number.isSafeInteger(revision)) return
  for (const thread of threads) {
    const key = `${workspaceId}\u0000${thread.local_thread_id}`
    const archivedAt = pending.get(key)
    if (archivedAt !== undefined && revision > archivedAt && thread.archived === false && thread.open === true) pending.delete(key)
  }
}

export async function registerHistoryClient(call: HistoryDependencies['call']): Promise<string> {
  const response = await call('daemon.client.register', { persistent: false })
  const result = unwrapResult<{ client_id?: string }>(response)
  if (response.error || response.ok === false || typeof result?.client_id !== 'string' || !result.client_id) {
    throw new Error(response.error?.message ?? 'Could not register web client')
  }
  return result.client_id
}

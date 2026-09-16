import type { RpcEnvelope, Thread } from './types'

export interface ChatConnection {
  profile_id: string
  label: string
  phase: string
  ready: boolean
  runtime_id: string | null
  failure: string | null
}

export interface ConnectionCatalog {
  connections: ChatConnection[]
  defaults: { workspace_id: string; profile_id: string }[]
}

export function effectiveConnection(thread: Pick<Thread, 'profile_id' | 'committed' | 'provider_thread_id'>, workspace: string, catalog: ConnectionCatalog): string {
  if (thread.profile_id) return thread.profile_id
  // Existing local conversations must never move when a workspace default changes.
  if (thread.committed || thread.provider_thread_id) return 'local'
  return catalog.defaults.find((row) => row.workspace_id === workspace)?.profile_id ?? 'local'
}

export async function fetchConnections(): Promise<ConnectionCatalog> {
  const response = await fetch('/api/chat-connections', { credentials: 'same-origin', cache: 'no-store' })
  const data = await response.json()
  if (!response.ok || !Array.isArray(data.connections) || !Array.isArray(data.defaults)) {
    throw new Error(data.error?.message ?? 'Could not load saved connections')
  }
  return data
}

export async function connectionRpc(connection: ChatConnection, runtimeId: string | null | undefined, method: string, params: unknown): Promise<RpcEnvelope> {
  if (!connection.ready || !connection.runtime_id) throw new Error(`${connection.label}: ${connection.failure ?? connection.phase}. Check the connection before sending.`)
  if (runtimeId && runtimeId !== connection.runtime_id) throw new Error('This chat belongs to a different runtime. Restore its connection to continue.')
  const response = await fetch('/api/chat-connection-rpc', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ profile_id: connection.profile_id, runtime_id: runtimeId ?? connection.runtime_id, method, params }),
  })
  return response.json()
}

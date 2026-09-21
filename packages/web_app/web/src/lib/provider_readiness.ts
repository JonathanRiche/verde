import { createSignal } from 'solid-js'
import { unwrapResult } from './live'
import type { ChatConnection, ConnectionCatalog } from './connections'
import type { RpcEnvelope } from './types'

export type ProviderReadinessState = 'checking' | 'missing' | 'signed_out' | 'ready' | 'unavailable' | 'unsupported'
export interface ProviderReadiness {
  provider: string
  state: ProviderReadinessState
  label: string
  detail: string
}
export interface ProviderStatusRow { provider: string; installed?: boolean; state?: string; authentication?: string }
export function parseProviderReadiness(row: ProviderStatusRow): ProviderReadiness {
  const state: ProviderReadinessState = row.installed === false || row.state === 'missing' ? 'missing'
    : ['unauthenticated', 'required', 'signed_out'].includes(row.authentication ?? '') ? 'signed_out'
    : row.installed === true && row.state !== 'unavailable' && ['authenticated', 'signed_in'].includes(row.authentication ?? '') ? 'ready' : 'unavailable'
  const labels = { missing: 'CLI not found', signed_out: 'Sign-in needed', ready: 'Ready', unavailable: 'Could not verify' }
  return { provider: row.provider, state, label: labels[state], detail: state === 'unavailable' ? 'The daemon reports installation only; provider sign-in has not been verified.' : labels[state] }
}
export interface RuntimeBlocker { kind: 'loading' | 'missing' | 'offline' | 'identity'; detail: string }
export function runtimeBlocker(profile: string, pinnedRuntime: string | null | undefined, catalog: ConnectionCatalog | null): RuntimeBlocker | null {
  if (profile === 'local') return null
  if (!catalog) return { kind: 'loading', detail: 'Connections are loading.' }
  const connection: ChatConnection | undefined = catalog.connections.find((row) => row.profile_id === profile)
  if (!connection) return { kind: 'missing', detail: 'The saved connection is unavailable.' }
  if (pinnedRuntime && connection.runtime_id && pinnedRuntime !== connection.runtime_id) return { kind: 'identity', detail: 'This chat belongs to a different runtime. Restore its original connection.' }
  if (!connection.ready || !connection.runtime_id) return { kind: 'offline', detail: `${connection.label}: ${connection.failure ?? connection.phase}` }
  return null
}

export function createProviderReadinessApi(call: (method: string, params: unknown) => Promise<RpcEnvelope>) {
  const [rows, setRows] = createSignal<Record<string, ProviderReadiness>>({})
  const [runtimeId, setRuntimeId] = createSignal<string | null>(null)
  const [checking, setChecking] = createSignal(false)
  let pending: Promise<void> | null = null
  function recheckProviderReadiness(): Promise<void> {
    if (pending) return pending
    setChecking(true)
    pending = (async () => {
      try {
        const response = await call('providers.status', {})
        if (response.error || response.ok === false) throw new Error('unavailable')
        const status = unwrapResult<{ runtime_id: string; providers: ProviderStatusRow[] }>(response)
        if (!status || !Array.isArray(status.providers) || typeof status.runtime_id !== 'string') throw new Error('invalid status')
        setRuntimeId(status.runtime_id)
        setRows(Object.fromEntries(status.providers.filter((row) => typeof row.provider === 'string').map((row) => [row.provider, parseProviderReadiness(row)])))
      } catch {
        setRuntimeId(null)
        setRows({})
      } finally { setChecking(false); pending = null }
    })()
    return pending
  }
  function providerReadiness(provider: string, remote = false): ProviderReadiness {
    if (remote) return { provider, state: 'unsupported', label: 'Could not verify', detail: 'The remote web bridge does not permit providers.status. Check provider readiness on that runtime.' }
    if (checking()) return { provider, state: 'checking', label: 'Checking', detail: 'Checking provider installation.' }
    return rows()[provider] ?? { provider, state: 'unavailable', label: 'Could not verify', detail: 'Provider status is unavailable. Check again.' }
  }
  return { providerReadiness, recheckProviderReadiness, providerRuntimeId: runtimeId }
}

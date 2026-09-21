import { createSignal } from 'solid-js'
import { unwrapResult } from './live'
import type { ChatConnection, ConnectionCatalog } from './connections'
import type { RpcEnvelope } from './types'

export type ProviderReadinessState = 'checking' | 'missing' | 'signed_out' | 'ready' | 'unverified' | 'unavailable' | 'unsupported'
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
    : row.installed !== true || row.state === 'unavailable' ? 'unavailable'
    : ['authenticated', 'signed_in'].includes(row.authentication ?? '') ? 'ready' : 'unverified'
  const labels = { missing: 'CLI not found', signed_out: 'Sign-in needed', ready: 'Ready', unverified: 'CLI installed', unavailable: 'Provider status unavailable' }
  const detail = state === 'unverified' ? 'The CLI is installed. The daemon does not check provider sign-in.'
    : state === 'unavailable' ? 'The daemon could not report provider status. You can still try sending a message.' : labels[state]
  return { provider: row.provider, state, label: labels[state], detail }
}
export interface RuntimeBlocker { kind: 'loading' | 'missing' | 'offline' | 'identity'; detail: string }
export function providerReadinessNoticeVisible(status: ProviderReadiness, blocker: RuntimeBlocker | null, dismissed: boolean): boolean {
  return !!blocker || status.state === 'missing' || status.state === 'signed_out' || (status.state === 'unavailable' && !dismissed)
}
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
  const [checked, setChecked] = createSignal(false)
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
      } finally { setChecked(true); setChecking(false); pending = null }
    })()
    return pending
  }
  function providerReadiness(provider: string, remote = false): ProviderReadiness {
    if (remote) return { provider, state: 'unsupported', label: 'Provider status not supported', detail: 'This connection does not support provider status checks.' }
    if (checking() || !checked()) return { provider, state: 'checking', label: 'Checking', detail: 'Checking provider installation.' }
    return rows()[provider] ?? { provider, state: 'unavailable', label: 'Provider status unavailable', detail: 'The daemon could not report provider status. You can still try sending a message.' }
  }
  return { providerReadiness, recheckProviderReadiness, providerRuntimeId: runtimeId }
}

import { expect, test } from 'bun:test'
import { createProviderReadinessApi, parseProviderReadiness, providerReadinessNoticeVisible, runtimeBlocker } from './provider_readiness.ts'
test('readiness never mistakes installation or unknown auth for ready', () => {
  const row = { provider: 'codex', installed: true, state: 'unknown', authentication: 'unknown' }
  expect(parseProviderReadiness(row).state).toBe('unverified')
  expect(parseProviderReadiness({ provider: 'codex', installed: true }).state).toBe('unverified')
  expect(parseProviderReadiness({ provider: 'codex' }).state).toBe('unavailable')
  expect(parseProviderReadiness({ ...row, installed: false }).state).toBe('missing')
  expect(parseProviderReadiness({ ...row, authentication: 'unauthenticated' }).state).toBe('signed_out')
  expect(parseProviderReadiness({ ...row, authentication: 'authenticated' }).state).toBe('ready')
  expect(parseProviderReadiness({ ...row, state: 'unavailable', authentication: 'authenticated' }).state).toBe('unavailable')
})
test('composer hides passive status but keeps actionable provider and runtime problems visible', () => {
  for (const state of ['ready', 'unverified', 'checking', 'unsupported']) {
    expect(providerReadinessNoticeVisible({ state }, null, false)).toBe(false)
  }
  expect(providerReadinessNoticeVisible({ state: 'unavailable' }, null, false)).toBe(true)
  expect(providerReadinessNoticeVisible({ state: 'unavailable' }, null, true)).toBe(false)
  for (const state of ['missing', 'signed_out']) {
    expect(providerReadinessNoticeVisible({ state }, null, true)).toBe(true)
  }
  for (const kind of ['loading', 'missing', 'offline', 'identity']) {
    expect(providerReadinessNoticeVisible({ state: 'unverified' }, { kind }, true)).toBe(true)
  }
})
test('installation-only daemon response does not produce a composer warning or claim sign-in', async () => {
  const api = createProviderReadinessApi(async () => ({ result: { runtime_id: 'runtime', providers: [
    { provider: 'codex', installed: true, state: 'unknown', authentication: 'unknown' },
  ] } }))
  expect(api.providerReadiness('codex').state).toBe('checking')
  expect(providerReadinessNoticeVisible(api.providerReadiness('codex'), null, false)).toBe(false)
  await api.recheckProviderReadiness()
  const status = api.providerReadiness('codex')
  expect(status.state).toBe('unverified')
  expect(status.label).toBe('CLI installed')
  expect(providerReadinessNoticeVisible(status, null, false)).toBe(false)
})
test('runtime blockers distinguish loading, missing, offline and identity mismatch', () => {
  const catalog = { connections: [{ profile_id: 'remote', label: 'Remote', ready: true, phase: 'ready', runtime_id: 'runtime', failure: null }], defaults: [] }
  expect(runtimeBlocker('local', null, null)).toBeNull()
  expect(runtimeBlocker('remote', null, null).kind).toBe('loading')
  expect(runtimeBlocker('missing', null, catalog).kind).toBe('missing')
  expect(runtimeBlocker('remote', 'other', catalog).kind).toBe('identity')
  expect(runtimeBlocker('remote', 'runtime', catalog)).toBeNull()
  catalog.connections[0].ready = false
  expect(runtimeBlocker('remote', null, catalog).kind).toBe('offline')
})
test('recheck uses daemon status, deduplicates inflight probes and clears stale readiness on failure', async () => {
  let resolve, calls = 0
  const api = createProviderReadinessApi(async (method, params) => {
    expect(method).toBe('providers.status'); expect(params).toEqual({}); calls++
    return new Promise((done) => { resolve = done })
  })
  const first = api.recheckProviderReadiness()
  const second = api.recheckProviderReadiness()
  expect(api.providerReadiness('codex').state).toBe('checking')
  expect(calls).toBe(1)
  resolve({ result: { runtime_id: 'runtime', providers: [{ provider: 'codex', installed: false, state: 'missing', authentication: 'unknown' }] } })
  await Promise.all([first, second])
  expect(api.providerReadiness('codex').state).toBe('missing')
  expect(api.providerRuntimeId()).toBe('runtime')
  const again = api.recheckProviderReadiness()
  resolve({ ok: false, error: { code: 'network' } })
  await again
  expect(api.providerRuntimeId()).toBeNull()
  expect(api.providerReadiness('codex').state).toBe('unavailable')
})

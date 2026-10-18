import { expect, test } from 'bun:test'
import { createProviderReadinessApi, parseProviderReadiness } from './provider_readiness.ts'
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

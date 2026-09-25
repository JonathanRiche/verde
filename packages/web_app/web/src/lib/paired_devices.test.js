import { expect, test } from 'bun:test'
import { createPairedDevicesSettings } from './store.ts'

const settle = () => new Promise(resolve => setTimeout(resolve, 0))
const device = { device_id: 'phone', label: 'Phone', scopes: ['chat:read'], last_used_at_ms: null }

test('owner loads on Settings open only, caches until close, and refetches after revoke', async () => {
  const calls = []
  let revoked = false
  const settings = createPairedDevicesSettings(async (method, params) => {
    calls.push({ method, params })
    if (method === 'device.revoke') {
      revoked = true
      return { result: { revoked: true } }
    }
    return { result: { devices: [{ ...device, revoked_at_ms: revoked ? 123 : null }] } }
  })
  expect(calls).toEqual([])
  settings.setOpen(true)
  await settle()
  expect(settings.status()).toBe('ready')
  expect(settings.devices()[0].preset).toBeUndefined()
  settings.setOpen(true)
  expect(calls).toHaveLength(1)
  await settings.revoke('phone')
  expect(calls.map(call => call.method)).toEqual(['device.list', 'device.revoke', 'device.list'])
  expect(calls[1].params).toEqual({ access_protocol_version: 1, device_id: 'phone' })
  expect(settings.devices()[0].revoked_at_ms).toBe(123)
  settings.setOpen(false)
  settings.setOpen(true)
  await settle()
  expect(calls).toHaveLength(4)
})

test('paired forbidden response hides the entire section without an error', async () => {
  const settings = createPairedDevicesSettings(async () => ({ error: { code: 'forbidden', message: 'method is not available to paired sessions' } }))
  settings.setOpen(true)
  await settle()
  expect(settings.status()).toBe('hidden')
  expect(settings.devices()).toEqual([])
  expect(settings.revokeError()).toBeNull()
})

for (const failure of ['network', 'daemon', 'invalid', 'insufficient_scope']) {
  test(`${failure} failure stays visible with Retry and can recover`, async () => {
    let fail = true
    const settings = createPairedDevicesSettings(async () => {
      if (!fail) return { result: { devices: [{ ...device, preset: 'chat' }] } }
      if (failure === 'network') throw new Error('offline')
      if (failure === 'invalid') return { result: {} }
      return { ok: false, error: { code: failure, message: 'Unavailable' } }
    })
    settings.setOpen(true)
    await settle()
    expect(settings.status()).toBe('error')
    fail = false
    await settings.refresh()
    expect(settings.status()).toBe('ready')
    expect(settings.devices()[0].preset).toBe('chat')
  })
}

test('a response from a closed Settings session cannot overwrite a new session', async () => {
  let resolve
  let calls = 0
  const settings = createPairedDevicesSettings(() => ++calls === 1
    ? new Promise(done => { resolve = done })
    : Promise.resolve({ result: { devices: [device] } }))
  settings.setOpen(true)
  settings.setOpen(false)
  settings.setOpen(true)
  await settle()
  resolve({ error: { code: 'forbidden' } })
  await settle()
  expect(settings.status()).toBe('ready')
  expect(settings.devices()).toEqual([device])
})

test('failed revoke keeps the list and permits retry', async () => {
  const settings = createPairedDevicesSettings(async method => method === 'device.list'
    ? { result: { devices: [device] } }
    : { error: { code: 'unavailable' } })
  settings.setOpen(true)
  await settle()
  await settings.revoke('phone')
  expect(settings.status()).toBe('ready')
  expect(settings.revokeError()).toBe("Couldn't revoke device. Try again.")
  expect(settings.revoking()).toBeNull()
})

import { expect, test } from 'bun:test'
import { sidebarMenuAvailability, requestSidebarThreadSync, DESKTOP_ACTION_REASON } from './commands'
import { store } from './store'

const workspace = { workspace_id: 'ws', label: 'Workspace', path: '/repo' }
const pane = { workspace_id: 'ws', pane_id: 1, native_pane_id: 42, kind: 'chat', thread_id: 'local', provider_thread_id: 'provider', profile_id: 'local' }
const unavailable = [
  'workspace-open-codex-tui', 'workspace-herdr-handoff', 'workspace-herdr-focus-terminal', 'workspace-herdr-unlink',
  'workspace-import-codex', 'workspace-import-opencode', 'workspace-import-claude',
  'thread-regenerate-title', 'thread-handoff', 'thread-open-tui', 'thread-open-chat',
  'pane-split-chat-right', 'pane-split-chat-down', 'pane-split-terminal-right', 'pane-split-terminal-down',
  'pane-close',
]

for (const action of unavailable) {
  test(`${action} is visibly disabled and direct store dispatch reports why without RPC`, async () => {
    const item = sidebarMenuAvailability({ action, label: 'Action' }, pane)
    expect(item.disabled).toBe(true)
    expect(item.label).toContain(DESKTOP_ACTION_REASON)
    const originalFetch = globalThis.fetch
    let requests = 0
    globalThis.fetch = async () => { requests++; throw new Error('No transport allowed') }
    try {
      await store.runSidebarContextAction({ action, workspace, pane })
      expect(store.notice()).toBe(DESKTOP_ACTION_REASON)
      expect(requests).toBe(0)
    } finally {
      globalThis.fetch = originalFetch
      store.setNotice(null)
    }
  })
}

test('sync calls the daemon contract with the owning workspace, independent of native pane ID', async () => {
  const calls = []
  const thread = { local_thread_id: 'local', provider_thread_id: 'provider', title: 'Saved', profile_id: 'local' }
  const response = { result: { thread, store_revision: 43 } }
  expect(await requestSidebarThreadSync(async (method, params) => {
    calls.push({ method, params }); return response
  }, 'owner', thread, false)).toBe(response)
  expect(calls).toEqual([{ method: 'provider.thread.sync', params: {
    workspace_id: 'owner', local_thread_id: 'local', provider_thread_id: 'provider',
  } }])
  expect(sidebarMenuAvailability({ action: 'thread-sync', label: 'Sync thread' }, { ...pane, native_pane_id: undefined }).disabled).not.toBe(true)
})

test('remote, missing and busy sync targets cannot issue a mutation', async () => {
  const call = async () => { throw new Error('unexpected transport') }
  const thread = { local_thread_id: 'local', provider_thread_id: 'provider', title: 'Saved' }
  await expect(requestSidebarThreadSync(call, 'ws', thread, true)).rejects.toThrow('finish')
  await expect(requestSidebarThreadSync(call, 'ws', { ...thread, provider_thread_id: null }, false)).rejects.toThrow('saved provider thread')
  await expect(requestSidebarThreadSync(call, 'ws', { ...thread, profile_id: 'remote' }, false)).rejects.toThrow('desktop app')
  expect(sidebarMenuAvailability({ action: 'thread-sync', label: 'Sync thread' }, { ...pane, profile_id: 'remote' }).label).toContain(DESKTOP_ACTION_REASON)
})

test('sync failures propagate without trying palette.run or transcript upserts', async () => {
  const failure = { error: { code: 'conflict', message: 'thread changed' } }
  let calls = 0
  const result = await requestSidebarThreadSync(async () => { calls++; return failure }, 'ws', {
    local_thread_id: 't', provider_thread_id: 'p', title: 'Saved',
  }, false)
  expect(result).toBe(failure)
  expect(calls).toBe(1)
})

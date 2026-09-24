import { expect, test } from 'bun:test'
import { sidebarMenuAvailability, requestSidebarThreadSync } from './commands'

const pane = { workspace_id: 'ws', pane_id: 1, native_pane_id: 42, kind: 'chat', thread_id: 'local', provider_thread_id: 'provider', profile_id: 'local' }
const webActions = [
  'workspace-open-codex-tui', 'workspace-herdr-handoff', 'workspace-herdr-focus-terminal', 'workspace-herdr-unlink',
  'workspace-import-codex', 'workspace-import-opencode', 'workspace-import-claude',
  'thread-regenerate-title', 'thread-handoff', 'thread-open-tui', 'thread-open-chat',
  'pane-split-chat-right', 'pane-split-chat-down', 'pane-split-terminal-right', 'pane-split-terminal-down',
]

test('desktop-tiled chat and daemon terminal panes close from the web; browser panes do not', () => {
  const close = { action: 'pane-close', label: 'Close pane' }
  expect(sidebarMenuAvailability(close, pane).disabled).not.toBe(true)
  expect(sidebarMenuAvailability(close, { ...pane, kind: 'terminal', thread_id: undefined, session_id: 's' }).disabled).not.toBe(true)
  expect(sidebarMenuAvailability(close, { ...pane, kind: 'browser', thread_id: undefined }).label).toContain('no running session')
  expect(sidebarMenuAvailability(close, { ...pane, kind: 'terminal', thread_id: undefined }).label).toContain('no running session')
})

test('former desktop-only actions are enabled in the web client', () => {
  for (const action of webActions) {
    for (const target of [pane, { ...pane, native_pane_id: undefined }]) {
      const item = sidebarMenuAvailability({ action, label: 'Action' }, target)
      expect(item.disabled).not.toBe(true)
      expect(item.label).toBe('Action')
    }
  }
})

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
  await expect(requestSidebarThreadSync(call, 'ws', { ...thread, profile_id: 'remote' }, false)).rejects.toThrow('another machine')
  expect(sidebarMenuAvailability({ action: 'thread-sync', label: 'Sync thread' }, { ...pane, profile_id: 'remote' }).label).toContain('another machine')
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

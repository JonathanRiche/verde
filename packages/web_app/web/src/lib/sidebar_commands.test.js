import { expect, test } from 'bun:test'
import { sidebarMenuAvailability, requestSidebarThreadSync } from './commands'

const pane = { workspace_id: 'ws', pane_id: 1, native_pane_id: 42, kind: 'chat', thread_id: 'local', provider_thread_id: 'provider', profile_id: 'local' }

test('remote, missing and busy sync targets cannot issue a mutation', async () => {
  const call = async () => { throw new Error('unexpected transport') }
  const thread = { local_thread_id: 'local', provider_thread_id: 'provider', title: 'Saved' }
  await expect(requestSidebarThreadSync(call, 'ws', thread, true)).rejects.toThrow('finish')
  await expect(requestSidebarThreadSync(call, 'ws', { ...thread, provider_thread_id: null }, false)).rejects.toThrow('saved provider thread')
  await expect(requestSidebarThreadSync(call, 'ws', { ...thread, profile_id: 'remote' }, false)).rejects.toThrow('another machine')
  expect(sidebarMenuAvailability({ action: 'thread-sync', label: 'Sync thread' }, { ...pane, profile_id: 'remote' }).label).toContain('another machine')
})

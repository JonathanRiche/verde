import { describe, expect, test } from 'bun:test'
import { requestWorkspaceCommand } from './command_requests'

const workspace = { workspace_id: 'owner', label: 'Saved', path: '/repo', workspace_layout_json: 'layout', threads: [{ local_thread_id: 't' }], messages: [{ body: 'keep out' }] }
const mutation = async () => ({ client_id: 'paired-client', request_key: 'command-request' })
const ok = { result: { applied: true } }
const forbidden = { error: { code: 'forbidden', message: 'method is not available to paired sessions' } }

describe('workspace command RPC handlers', () => {
  for (const patch of [{ label: 'Renamed' }, { archived: true }]) {
    test(`paired ${JSON.stringify(patch)} uses authorized daemon upsert with full metadata`, async () => {
      const calls = []
      const call = async (method, params) => {
        calls.push({ method, params })
        return method === 'workspace.upsert' ? ok : forbidden
      }
      expect(await requestWorkspaceCommand(call, mutation, workspace, patch)).toBe(ok)
      expect(calls.map((row) => row.method)).toEqual(['label' in patch ? 'workspace.rename' : 'workspace.close', 'workspace.upsert'])
      expect(calls[1].params).toEqual({ mutation: await mutation(), workspace: {
        workspace_id: 'owner', label: 'Saved', path: '/repo', workspace_layout_json: 'layout', ...patch,
      } })
      expect(workspace.threads).toHaveLength(1)
    })
  }
  test('real failures never trigger a second mutation', async () => {
    const failure = { error: { code: 'conflict', message: 'changed' } }
    let calls = 0
    expect(await requestWorkspaceCommand(async () => { calls++; return failure }, mutation, workspace, { label: 'x' })).toBe(failure)
    expect(calls).toBe(1)
  })
})

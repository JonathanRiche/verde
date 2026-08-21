import { describe, expect, test } from 'bun:test'

import { panesForWorkspace, requestTerminalOpen } from './store.ts'

describe('panesForWorkspace', () => {
  test('keeps daemon thread settings ahead of a stale live pane', () => {
    const workspace = {
      workspace_id: 'workspace-1',
      label: 'Workspace',
      path: '/workspace',
      threads: [
        {
          local_thread_id: 'thread-1',
          title: 'New thread',
          sort_index: 0,
          provider: 'codex',
          model_ref: 'gpt-current',
          reasoning_effort: null,
          reasoning_variant: 'max',
          fast_mode: 'on',
        },
      ],
    }
    const stale_live_layout = {
      panes: [
        {
          id: 7,
          kind: 'chat',
          thread: 0,
          title: 'New thread',
          provider: 'claude',
          model: 'old-model',
          reasoning_effort: 'low',
          reasoning_variant: null,
          fast_mode: false,
          send_pending: true,
        },
      ],
    }

    const [pane] = panesForWorkspace(workspace, [], [], new Set(), stale_live_layout)

    expect(pane).toMatchObject({
      provider: 'codex',
      model: 'gpt-current',
      reasoning_effort: null,
      reasoning_variant: 'max',
      fast_mode: true,
      send_pending: true,
    })
  })
})

describe('requestTerminalOpen', () => {
  const workspace = { workspace_id: 'workspace-1', path: '/workspace' }

  test('uses the native desktop terminal operation when available', async () => {
    const calls = []
    const result = await requestTerminalOpen(async (method, params) => {
      calls.push({ method, params })
      return { id: 1, result: { panes: [] } }
    }, workspace, 'fallback-session')

    expect(result.native).toBe(true)
    expect(calls).toEqual([
      { method: 'terminal.open', params: { workspace_id: 'workspace-1' } },
    ])
  })

  test('falls back to a daemon session only when terminal.open is unavailable', async () => {
    const calls = []
    const result = await requestTerminalOpen(async (method, params) => {
      calls.push({ method, params })
      if (method === 'terminal.open') {
        return { id: 1, error: { code: 'method_not_found', message: method } }
      }
      return { id: 2, result: { created: true } }
    }, workspace, 'fallback-session')

    expect(result.native).toBe(false)
    expect(calls).toEqual([
      { method: 'terminal.open', params: { workspace_id: 'workspace-1' } },
      {
        method: 'session.create',
        params: {
          id: 'fallback-session',
          cwd: '/workspace',
          workspace_path: '/workspace',
          workspace_id: 'workspace-1',
          label: 'Terminal',
        },
      },
    ])
  })

  test('does not hide a native terminal rejection behind the headless fallback', async () => {
    const calls = []
    const result = await requestTerminalOpen(async (method, params) => {
      calls.push({ method, params })
      return { id: 1, error: { code: 'rejected', message: 'could not open terminal' } }
    }, workspace, 'fallback-session')

    expect(result.native).toBe(true)
    expect(result.response.error?.code).toBe('rejected')
    expect(calls).toHaveLength(1)
  })
})

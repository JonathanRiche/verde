import { describe, expect, test } from 'bun:test'
import { pendingShellRows, runComposerShellCommand, shellRunParams } from './shell_mode'

const ids = { workspace_id: 'w', local_thread_id: 't' }
const ok = { ok: true, result: { status: 'completed', exit_code: 0, cwd: '/repo', shell: '/bin/sh', duration_ms: 4, command_message_id: 'c', result_message_id: 'r' } }

describe('shellRunParams', () => {
  test('legacy local chats name the workspace root', () => {
    expect(shellRunParams(ids, 'ls', { repository_id: 'primary', repository_cwd: null }, false, '/repo'))
      .toEqual({ workspace_id: 'w', local_thread_id: 't', command: 'ls', project_path: '/repo' })
  })

  test('routed and remote chats send only the repository route', () => {
    expect(shellRunParams(ids, 'ls', { repository_id: 'primary', repository_cwd: 'src' }, false, '/repo'))
      .toEqual({ workspace_id: 'w', local_thread_id: 't', command: 'ls', repository_id: 'primary', relative_cwd: 'src' })
    const remote = shellRunParams(ids, 'ls', {}, true, '/repo')
    expect(remote).toEqual({ workspace_id: 'w', local_thread_id: 't', command: 'ls', repository_id: 'primary', relative_cwd: null })
    expect('project_path' in remote).toBe(false)
  })
})

test('pendingShellRows mirrors the desktop command and running rows', () => {
  const rows = pendingShellRows('git status', 5, { command: 'a', running: 'b' })
  expect(rows[0]).toMatchObject({ message_id: 'a', role: 'user', body: '!git status' })
  expect(rows[1]).toMatchObject({ message_id: 'b', role: 'system', author: 'Running command', tool_call_kind: 'execute', tool_call_status: 'in_progress' })
})

describe('runComposerShellCommand', () => {
  test('returns the daemon result', async () => {
    const outcome = await runComposerShellCommand({ call: async () => ok, confirm: () => { throw new Error('no prompt') } }, { command: 'ls' })
    expect(outcome.kind).toBe('ran')
    expect(outcome.notice).toBe('Workspace command finished.')
  })

  test('resends once with confirmed after the user approves', async () => {
    const calls = []
    const call = async (params) => {
      calls.push(params)
      return calls.length === 1 ? { error: { code: 'confirmation_required', message: 'Destructive command.' } } : ok
    }
    const outcome = await runComposerShellCommand({ call, confirm: (message) => message.includes('rm -rf x') }, { command: 'rm -rf x' })
    expect(outcome.kind).toBe('ran')
    expect(calls).toEqual([{ command: 'rm -rf x' }, { command: 'rm -rf x', confirmed: true }])
  })

  test('declining does not rerun the command', async () => {
    let count = 0
    const call = async () => { count += 1; return { error: { code: 'confirmation_required', message: 'Supervised.' } } }
    const outcome = await runComposerShellCommand({ call, confirm: () => false }, { command: 'ls' })
    expect(outcome).toEqual({ kind: 'declined', notice: 'Command was not run.' })
    expect(count).toBe(1)
  })

  test('maps daemon errors to composer notices', async () => {
    const run = (error) => runComposerShellCommand({ call: async () => ({ error }), confirm: () => false }, { command: 'ls' })
    expect((await run({ code: 'conflict', message: 'x' })).notice).toBe('This chat already has a running command or provider request.')
    expect((await run({ code: 'resource_not_found', message: 'resource not found' })).notice).toContain('Send a message first')
    expect((await run({ code: 'invalid_params', message: 'project_path does not match' })).notice).toBe('project_path does not match')
  })

  test('reports timed out and failed commands', async () => {
    const result = (status) => ({ ok: true, result: { ...ok.result, status } })
    expect((await runComposerShellCommand({ call: async () => result('timed_out'), confirm: () => false }, {})).notice).toContain('timed out')
    expect((await runComposerShellCommand({ call: async () => result('failed'), confirm: () => false }, {})).notice).toBe('Workspace command failed.')
  })
})

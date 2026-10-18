import { describe, expect, test } from 'bun:test'
import { runComposerShellCommand } from './shell_mode'

const ok = { ok: true, result: { status: 'completed', exit_code: 0, cwd: '/repo', shell: '/bin/sh', duration_ms: 4, command_message_id: 'c', result_message_id: 'r' } }

describe('runComposerShellCommand', () => {
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

})

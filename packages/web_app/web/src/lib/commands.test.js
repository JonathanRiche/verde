import { describe, expect, test } from 'bun:test'
import { COMMANDS, dispatchWebCommand } from './commands.ts'

const workspace = { workspace_id: 'ws', label: 'Workspace', path: '/workspace' }
const pane = { workspace_id: 'ws', pane_id: 1, kind: 'chat', thread_id: 'thread', native_pane_id: 42 }
function fixture(overrides = {}) {
  const calls = []
  const notices = []
  return {
    calls, notices,
    context: {
      workspace, pane,
      handlers: Object.fromEntries(COMMANDS.map((row) => [row.id, async () => calls.push(['native', row.id])])),
      notice: (message) => notices.push(message),
      ...overrides,
    },
  }
}

describe('web command catalog and dispatch', () => {
  test('missing targets yield notices, never an unrelated action', async () => {
    for (const [id, overrides, notice] of [
      ['thread.new', { workspace: null }, 'workspace'],
      ['pane.close', { pane: null }, 'pane'],
      ['pane.close', { pane: { ...pane, workspace_id: 'other' } }, 'pane'],
      ['thread.choose_model', { pane: { ...pane, kind: 'terminal' } }, 'chat'],
      ['thread.rename_current', { pane: { ...pane, thread_id: undefined } }, 'chat'],
    ]) {
      const { context, calls, notices } = fixture(overrides)
      await dispatchWebCommand(id, context)
      expect(calls).toEqual([])
      expect(notices[0]).toContain(notice)
    }
  })
  test('handler failures become notices without exposing exception contents', async () => {
    const { context, notices } = fixture()
    context.handlers['thread.new'] = async () => { throw new Error('private response') }
    await dispatchWebCommand('thread.new', context)
    expect(notices.length).toBe(1)
    expect(notices.every((message) => message.startsWith('Could not run') && !message.includes('private'))).toBe(true)
  })
})

import { describe, expect, test } from 'bun:test'
import { COMMANDS, dispatchWebCommand, openChatCommandPicker, registerChatCommandPickers } from './commands.ts'

const workspace = { workspace_id: 'ws', label: 'Workspace', path: '/workspace' }
const pane = { workspace_id: 'ws', pane_id: 1, kind: 'chat', thread_id: 'thread', native_pane_id: 42 }
function fixture(overrides = {}) {
  const calls = []
  const notices = []
  return {
    calls, notices,
    context: {
      workspace, pane,
      handlers: Object.fromEntries(COMMANDS.filter((row) => !row.desktop).map((row) => [row.id, async () => calls.push(['native', row.id])])),
      notice: (message) => notices.push(message),
      ...overrides,
    },
  }
}

describe('web command catalog and dispatch', () => {
  test('catalog IDs are unique and user-facing rows have labels', () => {
    expect(new Set(COMMANDS.map((row) => row.id)).size).toBe(COMMANDS.length)
    expect(COMMANDS.every((row) => row.title.length > 0 && typeof row.hint === 'string')).toBe(true)
  })
  for (const command of COMMANDS) {
    test(`${command.id} dispatches through its declared handler`, async () => {
      const { context, calls, notices } = fixture()
      await dispatchWebCommand(command.id, context)
      expect(calls).toEqual(command.available ? [['native', command.id]] : [])
      expect(notices).toEqual(command.available ? [] : [command.unavailableReason])
    })
    if (command.desktop) {
      test(`${command.id} never reaches desktop without a native pane`, async () => {
        const { context, calls, notices } = fixture({ pane: { ...pane, native_pane_id: undefined } })
        await dispatchWebCommand(command.id, context)
        expect(calls).toEqual([])
        expect(notices[0]).toBe(command.unavailableReason)
      })
    }
  }
  test('legacy sidebar command IDs still work', async () => {
    const { context, calls } = fixture()
    for (const id of ['new-thread', 'new-terminal', 'toggle-sidebar', 'settings', 'maximize']) await dispatchWebCommand(id, context)
    expect(calls.map((row) => row[1])).toEqual(['thread.new', 'pane.terminal', 'app.sidebar', 'app.settings', 'pane.zoom'])
  })
  test('existing focus action names use native handlers', async () => {
    const { context, calls, notices } = fixture()
    for (const direction of ['left', 'right', 'up', 'down', 'prompt']) {
      await dispatchWebCommand(`workspace.focus_${direction}`, context)
    }
    expect(calls.map((row) => row[1])).toEqual(['pane.focus_left', 'pane.focus_right', 'pane.focus_up', 'pane.focus_down', 'pane.focus_prompt'])
    expect(notices).toEqual([])
  })
  test('add workspace and app actions work without a selected workspace', async () => {
    const { context, calls, notices } = fixture({ workspace: null, pane: null })
    for (const id of ['workspace.add', 'app.settings', 'app.sidebar']) await dispatchWebCommand(id, context)
    expect(calls.length).toBe(3)
    expect(notices).toEqual([])
  })
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
  test('workspace commands can target an unfocused workspace', async () => {
    const { context, calls } = fixture({ pane: { ...pane, workspace_id: 'other' } })
    await dispatchWebCommand('thread.new', context)
    expect(calls).toEqual([['native', 'thread.new']])
  })
  test('unsupported commands do not silently disappear or fall through to Live', async () => {
    const { context, calls, notices } = fixture()
    await dispatchWebCommand('workspace.open_editor', context)
    await dispatchWebCommand('invented.command', context)
    expect(calls).toEqual([])
    expect(notices.length).toBe(2)
    expect(notices.every((message) => message.includes('not available'))).toBe(true)
  })
  test('handler failures become notices without exposing exception contents', async () => {
    const { context, notices } = fixture()
    context.handlers['thread.new'] = async () => { throw new Error('private response') }
    await dispatchWebCommand('thread.new', context)
    expect(notices.length).toBe(1)
    expect(notices.every((message) => message.startsWith('Could not run') && !message.includes('private'))).toBe(true)
  })
})

test('picker bridge isolates workspaces and preserves replacement registrations during cleanup', () => {
  const calls = []
  const other = { ...pane, workspace_id: 'other' }
  const old = registerChatCommandPickers(pane, (command) => calls.push(['old', command]))
  const replacement = registerChatCommandPickers(pane, (command) => calls.push(['new', command]))
  const otherCleanup = registerChatCommandPickers(other, (command) => calls.push(['other', command]))
  old()
  expect(openChatCommandPicker(pane, 'model')).toBe(true)
  expect(openChatCommandPicker(other, 'run_config')).toBe(true)
  expect(calls).toEqual([['new', 'model'], ['other', 'run_config']])
  replacement()
  otherCleanup()
  expect(openChatCommandPicker(pane, 'model')).toBe(false)
  expect(openChatCommandPicker(other, 'model')).toBe(false)
})


test('validation rejects without dismissing the palette; accepted handlers dismiss first', async () => {
  let open = true
  const { context, notices } = fixture({ accepted: () => { open = false } })
  for (const id of ['pane.browser', 'missing']) {
    await dispatchWebCommand(id, context)
    expect(open).toBe(true)
  }
  await dispatchWebCommand('pane.close', { ...context, pane: null })
  expect(open).toBe(true)
  expect(notices).toHaveLength(3)
  context.handlers['app.settings'] = () => expect(open).toBe(false)
  await dispatchWebCommand('app.settings', context)
})

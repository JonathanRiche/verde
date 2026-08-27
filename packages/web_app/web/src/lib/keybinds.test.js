import { describe, expect, test } from 'bun:test'

import { acceleratorMatches, parseAccelerator, parseWebKeybindConfig } from './keybinds.ts'

describe('parseWebKeybindConfig', () => {
  test('keeps prefix and Ctrl+H/J/K/L disabled by default', () => {
    const config = parseWebKeybindConfig(null)
    expect(config.prefix.enabled).toBe(false)
    expect(config.directFocusLetters).toEqual({})
  })

  test('uses standalone t actions and default/alternate split chords', () => {
    const config = parseWebKeybindConfig({ keybinds: { prefix: true } })
    const target = (label) => config.prefix.bindings.find((row) => row.key.label === label)?.target

    expect(target('T')).toEqual({ action: 'new_thread' })
    expect(target('Shift+T')).toEqual({ action: 'new_terminal' })
    expect(target('C')).toEqual({ action: 'workspace.add' })
    expect(target('Shift+C')).toEqual({ action: 'workspace.split_chat_horizontal' })
    expect(target('V')).toEqual({ action: 'workspace.split_default_vertical' })
    expect(target('Minus')).toEqual({ action: 'workspace.split_default_horizontal' })
    expect(target('Shift+V')).toEqual({ action: 'workspace.split_alternate_vertical' })
    expect(target('Shift+Minus')).toEqual({ action: 'workspace.split_alternate_horizontal' })
  })

  test('reads the shared verde.json prefix and opt-in focus bindings', () => {
    const config = parseWebKeybindConfig({
      keybinds: {
        workspace: {
          focus_left: 'Ctrl+H',
          focus_down: 'Ctrl+J',
          focus_up: 'Ctrl+K',
          focus_right: 'Ctrl+L',
        },
        prefix: true,
      },
    })
    expect(config.prefix.enabled).toBe(true)
    expect(config.prefix.keys[0].label).toBe('Ctrl+B')
    expect(config.directFocusLetters).toEqual({
      h: 'focus_left', j: 'focus_down', k: 'focus_up', l: 'focus_right',
    })
  })

  test('merges prefix remaps and removals over the desktop defaults', () => {
    const config = parseWebKeybindConfig({
      keybinds: {
        prefix: {
          enabled: true,
          key: 'Ctrl+A',
          bindings: { x: null, g: { action: 'workspace.next' } },
        },
      },
    })
    expect(config.prefix.keys[0].label).toBe('Ctrl+A')
    expect(config.prefix.bindings.some((row) => row.key.label === 'X')).toBe(false)
    expect(config.prefix.bindings.find((row) => row.key.label === 'g')?.target).toEqual({ action: 'workspace.next' })
  })

  test('parses prefix command placement', () => {
    const config = parseWebKeybindConfig({
      keybinds: {
        prefix: {
          enabled: true,
          bindings: {
            g: { command: 'lazygit', in: 'pane' },
            f: { command: 'htop', open: 'floating' },
            b: { command: 'true' },
            x: { command: 'nope', in: 'not-a-place' },
          },
        },
      },
    })
    expect(config.prefix.bindings.find((row) => row.key.label === 'g')?.target).toEqual({ command: 'lazygit', in: 'pane' })
    expect(config.prefix.bindings.find((row) => row.key.label === 'f')?.target).toEqual({ command: 'htop', in: 'floating' })
    expect(config.prefix.bindings.find((row) => row.key.label === 'b')?.target).toEqual({ command: 'true' })
    expect(config.prefix.bindings.some((row) => row.key.label === 'x')).toBe(false)
  })
})

describe('acceleratorMatches', () => {
  test('matches shifted punctuation by physical key', () => {
    const help = parseAccelerator('Shift+Slash')
    expect(acceleratorMatches(help, {
      key: '?', code: 'Slash', ctrlKey: false, metaKey: false, altKey: false, shiftKey: true,
    })).toBe(true)
  })
})

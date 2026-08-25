import { describe, expect, test } from 'bun:test'

import { acceleratorMatches, parseAccelerator, parseWebKeybindConfig } from './keybinds.ts'

describe('parseWebKeybindConfig', () => {
  test('keeps prefix and Ctrl+H/J/K/L disabled by default', () => {
    const config = parseWebKeybindConfig(null)
    expect(config.prefix.enabled).toBe(false)
    expect(config.directFocusLetters).toEqual({})
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
})

describe('acceleratorMatches', () => {
  test('matches shifted punctuation by physical key', () => {
    const help = parseAccelerator('Shift+Slash')
    expect(acceleratorMatches(help, {
      key: '?', code: 'Slash', ctrlKey: false, metaKey: false, altKey: false, shiftKey: true,
    })).toBe(true)
  })
})

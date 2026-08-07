import { describe, expect, test } from 'bun:test'

import { portableThemePackage, themeImportCommand, themePackageUrl } from './theme-package'

function hexChannels(hex: string): [number, number, number] {
  const value = hex.replace('#', '')
  return [
    Number.parseInt(value.slice(0, 2), 16),
    Number.parseInt(value.slice(2, 4), 16),
    Number.parseInt(value.slice(4, 6), 16),
  ]
}

function luminance(hex: string): number {
  const [r, g, b] = hexChannels(hex)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

const kanagawa = {
  slug: 'kanagawa',
  name: 'Kanagawa',
  bg: '#1f1f28',
  accent: '#7e9cd8',
  fg: '#dcd7ba',
  warm: '#c0a36e',
}

describe('portable website themes', () => {
  test('produce versioned Verde theme packages', () => {
    const result = portableThemePackage(kanagawa)

    expect(result.schema_version).toBe(1)
    expect(result.name).toBe('Kanagawa')
    expect(result.theme.source).toBe('default')
    expect(result.theme.colors).toMatchObject({
      background: '#1f1f28',
      panel: '#1f1f28',
      panel_alt: '#282831',
      accent: '#7e9cd8',
      accent_dim: '#7e9cd836',
      warning: '#c0a36e',
    })
  })

  test('give diffs their own semantic colors instead of the accent', () => {
    const colors = portableThemePackage(kanagawa).theme.colors

    // Additions and removals must be distinguishable from each other, and
    // must not be painted the accent — Kanagawa's accent is blue, so reusing
    // it rendered added lines blue and left removals undefined.
    expect(colors.diff_add).toBeDefined()
    expect(colors.diff_remove).toBeDefined()
    expect(colors.diff_add).not.toBe(colors.diff_remove)
    expect(colors.diff_add).not.toBe(colors.accent)
    expect(colors.diff_remove).not.toBe(colors.accent)

    // diff_add reads green, diff_remove reads red.
    const [addR, addG, addB] = hexChannels(colors.diff_add!)
    expect(addG).toBeGreaterThan(addR)
    expect(addG).toBeGreaterThan(addB)

    const [remR, remG, remB] = hexChannels(colors.diff_remove!)
    expect(remR).toBeGreaterThan(remG)
    expect(remR).toBeGreaterThan(remB)
  })

  test('keep selection a wash so selected text stays legible', () => {
    const colors = portableThemePackage(kanagawa).theme.colors

    expect(colors.selection).not.toBe(colors.accent)
    expect(colors.selection).not.toBe(colors.diff_add)
  })

  test('tone diff colors for light themes as well as dark', () => {
    const latte = {
      slug: 'catppuccin-latte',
      name: 'Catppuccin Latte',
      bg: '#eff1f5',
      accent: '#1e66f5',
      fg: '#4c4f69',
      warm: '#df8e1d',
    }

    const dark = portableThemePackage(kanagawa).theme.colors
    const light = portableThemePackage(latte).theme.colors

    // The same base green must resolve differently per theme, and stay darker
    // than the background it sits on for a light theme.
    expect(light.diff_add).not.toBe(dark.diff_add)
    expect(luminance(light.diff_add!)).toBeLessThan(luminance(light.background!))
    expect(luminance(dark.diff_add!)).toBeGreaterThan(luminance(dark.background!))
  })

  test('exposes stable production URLs and import commands', () => {
    expect(themePackageUrl('kanagawa')).toBe('https://verdeai.dev/themes/kanagawa.json')
    expect(themeImportCommand('kanagawa')).toBe(
      'verde theme import https://verdeai.dev/themes/kanagawa.json',
    )
  })
})

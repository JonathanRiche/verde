import { describe, expect, test } from 'bun:test'

import { portableThemePackage, themeImportCommand, themePackageUrl } from './theme-package'

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

  test('exposes stable production URLs and import commands', () => {
    expect(themePackageUrl('kanagawa')).toBe('https://verdeai.dev/themes/kanagawa.json')
    expect(themeImportCommand('kanagawa')).toBe(
      'verde theme import https://verdeai.dev/themes/kanagawa.json',
    )
  })
})

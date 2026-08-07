export interface PortableThemeSource {
  slug: string
  name: string
  bg: string
  accent: string
  fg: string
  warm: string
}

export interface PortableThemePackage {
  schema_version: 1
  name: string
  theme: {
    source: 'default'
    colors: Record<string, string>
  }
}

const THEME_ORIGIN = 'https://verdeai.dev'

function hexToRgb(hex: string): [number, number, number] {
  const value = hex.replace('#', '')
  return [
    Number.parseInt(value.slice(0, 2), 16),
    Number.parseInt(value.slice(2, 4), 16),
    Number.parseInt(value.slice(4, 6), 16),
  ]
}

function rgbToHex(rgb: [number, number, number]): string {
  return `#${rgb.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
}

function mix(from: string, to: string, amount: number): string {
  const start = hexToRgb(from)
  const end = hexToRgb(to)
  return rgbToHex(start.map((channel, index) =>
    Math.round(channel + (end[index]! - channel) * amount),
  ) as [number, number, number])
}

function lighten(hex: string, amount: number): string {
  const offset = amount * 255
  return rgbToHex(hexToRgb(hex).map((channel) =>
    Math.min(255, Math.round(channel + offset)),
  ) as [number, number, number])
}

/* Diff colors carry fixed semantic meaning — additions read green, removals
   read red — so they can't be derived from the four Omarchy palette colors.
   These bases are toned toward the theme's own foreground, which keeps them
   legible on light and dark backgrounds alike: on a dark theme fg lightens
   them, on a light theme fg darkens them. */
const DIFF_ADD_BASE = '#3fb950'
const DIFF_REMOVE_BASE = '#f85149'

/** Build the same semantic palette Verde derives from an Omarchy colors.toml. */
export function portableThemePackage(theme: PortableThemeSource): PortableThemePackage {
  const panelMuted = lighten(theme.bg, 0.12)
  return {
    schema_version: 1,
    name: theme.name,
    theme: {
      source: 'default',
      colors: {
        background: theme.bg,
        panel: theme.bg,
        panel_alt: lighten(theme.bg, 0.035),
        panel_muted: panelMuted,
        text: theme.fg,
        text_muted: mix(theme.fg, theme.bg, 0.18),
        text_subtle: mix(theme.fg, theme.bg, 0.52),
        accent: theme.accent,
        accent_dim: `${theme.accent}36`,
        border: mix(theme.accent, theme.bg, 0.44),
        border_muted: panelMuted,
        warning: theme.warm,
        diff_add: mix(DIFF_ADD_BASE, theme.fg, 0.2),
        diff_remove: mix(DIFF_REMOVE_BASE, theme.fg, 0.2),
        // A selection is a fill sitting behind text, so it has to stay a wash
        // rather than the full-strength accent — otherwise selected text loses
        // all contrast against it.
        selection: mix(theme.accent, theme.bg, 0.78),
      },
    },
  }
}

export function themePackageUrl(slug: string): string {
  return `${THEME_ORIGIN}/themes/${encodeURIComponent(slug)}.json`
}

export function themeImportCommand(slug: string): string {
  return `verde theme import ${themePackageUrl(slug)}`
}

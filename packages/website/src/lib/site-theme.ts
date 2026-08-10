//! Shared Omarchy theme state for the marketing site.
//!
//! One module-level signal drives both the homepage showcase chips and the
//! nav dropdown, and `themeCssText` re-skins the whole page by overriding
//! the design tokens in styles.css with values derived from the theme's four
//! palette colors — the same way the desktop app derives its UI from an
//! Omarchy colors.toml. The pick persists in a plain cookie that the root
//! loader reads server-side, so a returning visitor's SSR HTML is already
//! themed — no client-side restore, no flash.

import { createSignal } from 'solid-js'
import { isServer } from 'solid-js/web'

import appScreenshot from '../../../../assets/green_verde.png'

/** Cookie persisting the visitor's picked theme; read server-side by the root
    loader so SSR paints the saved theme with no flash. Value is the plain
    theme slug — validated against the manifest on every read. */
export const THEME_COOKIE = 'verde_theme'

/* Screenshots live in src/assets/theme_shots/<slug>.png. The glob picks them
   up at build time, so dropping a new capture into that folder is all it
   takes for its theme to appear — no code change. Themes without a
   screenshot are hidden. */
const themeShotModules = import.meta.glob('../assets/theme_shots/*.png', {
  eager: true,
  import: 'default',
}) as Record<string, string>

function themeShot(slug: string): string | undefined {
  return themeShotModules[`../assets/theme_shots/${slug}.png`]
}

export interface OmarchyTheme {
  slug: string
  name: string
  bg: string
  accent: string
  /** Theme foreground — drives derived text/panel/line tokens. */
  fg: string
  /** Theme's yellow/secondary (colors.toml color3) — replaces the amber counterpoint. */
  warm: string
  /** Optional fallback image used when no capture exists yet (default theme only). */
  fallbackShot?: string
}

/* bg/accent/fg/warm are copied verbatim from each theme's Omarchy colors.toml
   (warm = color3). 'verde' matches the site's own default tokens.
   'mist-deep' has no upstream colors.toml — it is a Verde-native light theme,
   so its four values are the source of truth rather than a copy. */
const OMARCHY_THEMES: OmarchyTheme[] = [
  { slug: 'verde', name: 'Verde default', bg: '#101820', accent: '#50c878', fg: '#eaf0f2', warm: '#e8a44a', fallbackShot: appScreenshot },
  { slug: 'tokyo-night', name: 'Tokyo Night', bg: '#1a1b26', accent: '#7aa2f7', fg: '#a9b1d6', warm: '#e0af68' },
  { slug: 'catppuccin', name: 'Catppuccin', bg: '#1e1e2e', accent: '#89b4fa', fg: '#cdd6f4', warm: '#f9e2af' },
  { slug: 'everforest', name: 'Everforest', bg: '#2d353b', accent: '#7fbbb3', fg: '#d3c6aa', warm: '#dbbc7f' },
  { slug: 'gruvbox', name: 'Gruvbox', bg: '#282828', accent: '#7daea3', fg: '#d4be98', warm: '#d8a657' },
  { slug: 'kanagawa', name: 'Kanagawa', bg: '#1f1f28', accent: '#7e9cd8', fg: '#dcd7ba', warm: '#c0a36e' },
  { slug: 'nord', name: 'Nord', bg: '#2e3440', accent: '#81a1c1', fg: '#d8dee9', warm: '#ebcb8b' },
  { slug: 'rose-pine', name: 'Rosé Pine', bg: '#faf4ed', accent: '#56949f', fg: '#575279', warm: '#ea9d34' },
  { slug: 'matte-black', name: 'Matte Black', bg: '#121212', accent: '#e68e0d', fg: '#bebebe', warm: '#b91c1c' },
  { slug: 'osaka-jade', name: 'Osaka Jade', bg: '#111c18', accent: '#509475', fg: '#c1c497', warm: '#459451' },
  { slug: 'ristretto', name: 'Ristretto', bg: '#2c2525', accent: '#f38d70', fg: '#e6d9db', warm: '#f9cc6c' },
  { slug: 'catppuccin-latte', name: 'Catppuccin Latte', bg: '#eff1f5', accent: '#1e66f5', fg: '#4c4f69', warm: '#df8e1d' },
  { slug: 'lumon', name: 'Lumon', bg: '#16242d', accent: '#8bc9eb', fg: '#d6e2ee', warm: '#6fa4c9' },
  { slug: 'hackerman', name: 'Hackerman', bg: '#0b0c16', accent: '#82fb9c', fg: '#ddf7ff', warm: '#50f7d4' },
  { slug: 'ethereal', name: 'Ethereal', bg: '#060b1e', accent: '#7d82d9', fg: '#ffcead', warm: '#e9bb4f' },
  { slug: 'miasma', name: 'Miasma', bg: '#222222', accent: '#78824b', fg: '#c2c2b0', warm: '#b36d43' },
  { slug: 'retro-82', name: 'Retro 82', bg: '#05182e', accent: '#faa968', fg: '#f6dcac', warm: '#e97b3c' },
  { slug: 'flexoki-light', name: 'Flexoki Light', bg: '#fffcf0', accent: '#205ea6', fg: '#100f0f', warm: '#d0a215' },
  { slug: 'mist-deep', name: 'Mist Deep', bg: '#eef2f4', accent: '#0f6ac9', fg: '#0d1012', warm: '#a0791a' },
  { slug: 'vantablack', name: 'Vantablack', bg: '#000000', accent: '#8d8d8d', fg: '#ffffff', warm: '#cecece' },
  { slug: 'white', name: 'White', bg: '#ffffff', accent: '#6e6e6e', fg: '#000000', warm: '#4a4a4a' },
]

export const availableThemes = OMARCHY_THEMES.map((t) => ({
  ...t,
  shot: themeShot(t.slug) ?? t.fallbackShot,
})).filter((t): t is OmarchyTheme & { shot: string } => t.shot !== undefined)

export function themeBySlug(slug: string | null | undefined) {
  return availableThemes.find((t) => t.slug === slug)
}

/* On the client the signal initializes straight from the cookie, so hydration
   agrees with the cookie-driven SSR output. On the server the signal is never
   read for theming (see displayedTheme) and never written, so concurrent
   requests can't leak state into each other. */
function clientCookieSlug(): string | null {
  if (isServer) return null
  const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${THEME_COOKIE}=([^;]+)`))
  return match ? decodeURIComponent(match[1]!) : null
}

export const [activeThemeSlug, setActiveThemeSlug] = createSignal(
  themeBySlug(clientCookieSlug())?.slug ?? availableThemes[0]?.slug ?? 'verde',
)

export function activeTheme() {
  return themeBySlug(activeThemeSlug()) ?? availableThemes[0]!
}

/** Theme to render right now: on the server, the cookie slug the root loader
    read; on the client, the shared signal (itself cookie-initialized). */
export function displayedTheme(ssrSlug: string | null | undefined) {
  if (isServer) return themeBySlug(ssrSlug) ?? availableThemes[0]!
  return activeTheme()
}

export function persistThemeCookie(slug: string) {
  if (isServer) return
  document.cookie = `${THEME_COOKIE}=${encodeURIComponent(slug)}; path=/; max-age=31536000; samesite=lax`
}

/* ── Token derivation ── */

function hexToRgb(hex: string): [number, number, number] {
  const h = hex.replace('#', '')
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
}

/** Mix a→b by t (0..1), returned as a hex color. */
function mix(a: string, b: string, t: number): string {
  const ca = hexToRgb(a)
  const cb = hexToRgb(b)
  const c = ca.map((v, i) => Math.round(v + (cb[i]! - v) * t))
  return `#${c.map((v) => v.toString(16).padStart(2, '0')).join('')}`
}

function alpha(hex: string, a: number): string {
  const [r, g, b] = hexToRgb(hex)
  return `rgba(${r}, ${g}, ${b}, ${a})`
}

/** Relative-luminance check so light themes derive toward black, not white. */
function isLight(hex: string): boolean {
  const [r, g, b] = hexToRgb(hex)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 128
}

function siteTokensFor(t: OmarchyTheme): Record<string, string> {
  const { bg, fg, accent, warm } = t
  const light = isLight(bg)
  // Text pushes past the theme fg toward full contrast; fg itself becomes the
  // muted tier. Mix ratios eyeballed against the stock Verde tokens.
  const contrast = light ? '#000000' : '#ffffff'
  return {
    '--accent-rgb': hexToRgb(accent).join(', '),
    '--warm-rgb': hexToRgb(warm).join(', '),
    '--bg-rgb': hexToRgb(bg).join(', '),
    '--bg': bg,
    '--bg-soft': mix(bg, fg, 0.03),
    '--panel': mix(bg, fg, 0.05),
    '--panel-strong': mix(bg, fg, 0.04),
    '--panel-raised': mix(bg, fg, 0.1),
    '--panel-alt': mix(bg, fg, 0.07),
    '--line': mix(bg, fg, 0.16),
    '--line-soft': alpha(fg, 0.12),
    '--line-glow': alpha(accent, 0.18),
    '--line-warm': alpha(warm, 0.22),
    '--text': mix(fg, contrast, 0.35),
    '--muted': mix(fg, bg, 0.15),
    '--subtle': mix(fg, bg, 0.4),
    '--time': mix(fg, bg, 0.3),
    '--accent': accent,
    '--accent-strong': mix(accent, contrast, 0.25),
    '--accent-soft': mix(bg, accent, 0.3),
    '--accent-wash': alpha(accent, 0.08),
    '--accent-glow': alpha(accent, 0.04),
    '--warm': warm,
    '--warm-strong': mix(warm, contrast, 0.25),
    '--warm-wash': alpha(warm, 0.08),
    '--shadow-glow': `0 0 80px ${alpha(accent, 0.08)}`,
  }
}

/** CSS text for the theme's token overrides, rendered into a `<style>` tag
    (in the Header) that follows the shared signal. Empty for the default
    theme so the stock stylesheet tokens win. The tag lives in `<body>`,
    after the main stylesheet, so its equal-specificity `:root` block takes
    precedence by source order. */
export function themeCssText(t: OmarchyTheme): string {
  if (t.slug === 'verde') return ''
  const decls = Object.entries(siteTokensFor(t))
    .map(([key, value]) => `${key}:${value}`)
    .join(';')
  return `:root{${decls}}`
}

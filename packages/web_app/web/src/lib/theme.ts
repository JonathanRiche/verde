//! Apply the theme the Zig gateway resolved from verde.json / Omarchy,
//! the same search order as the desktop app.

export interface TerminalTheme {
  background: string
  foreground: string
  cursor: string
  palette: string[]
}

export interface ThemePayload {
  ok: boolean
  source: string
  active: string
  config_path: string
  omarchy_path: string
  colors: Record<string, string>
  terminal?: TerminalTheme
}

let lastJson = ''

export async function loadTheme(): Promise<ThemePayload | null> {
  try {
    const response = await fetch('/api/theme', { cache: 'no-store' })
    if (!response.ok) return null
    return (await response.json()) as ThemePayload
  } catch {
    return null
  }
}

export function applyTheme(payload: ThemePayload): void {
  const colors = payload.colors
  const root = document.documentElement
  const bg = colors.background ?? '#0d1213'
  const panel = colors.panel ?? '#20272a'
  const accent = colors.accent ?? '#50c878'
  const text = colors.text ?? '#f0f0f5'
  const muted = colors.text_muted ?? '#b9bbc3'
  const subtle = colors.text_subtle ?? '#787887'
  const warning = colors.warning ?? '#fbbf24'
  const selection = colors.selection ?? accent
  const borderMuted = colors.border_muted ?? '#3c474c'

  set('--chat-black', bg)
  set('--panel', panel)
  set('--panel-alt', colors.panel_alt ?? mix(bg, text, 0.06))
  set('--panel-muted', colors.panel_muted ?? mix(bg, text, 0.12))
  set('--border', colors.border ?? mix(accent, bg, 0.44))
  set('--border-muted', borderMuted)
  set('--text', text)
  set('--text-muted', muted)
  set('--text-subtle', subtle)
  set('--time', mix(text, bg, 0.3))
  set('--accent', accent)
  set('--accent-hi', mix(accent, '#ffffff', 0.2))
  set('--accent-dim', colors.accent_dim ?? rgba(accent, 0.21))
  set('--accent-wash', rgba(accent, 0.12))
  set('--accent-row', rgba(accent, 0.22))
  set('--accent-hover', rgba(accent, 0.14))
  set('--warning', warning)
  set('--danger', colors.diff_remove ?? '#ff6464')
  set('--user-bubble', mix(selection, panel, 0.55))
  set('--assistant-card', mix(bg, text, 0.04))
  set('--selection', selection)
  root.style.setProperty('--accent-rgb', hexToRgb(accent).join(', '))
  document.body.style.background = bg
  applyTerminalTheme(payload)
}

export function applyTerminalTheme(payload: ThemePayload): void {
  const term = payload.terminal ?? terminalFromUiColors(payload.colors)
  set('--vt-bg', term.background)
  set('--vt-fg', term.foreground)
  set('--vt-cursor', term.cursor)
  for (let index = 0; index < 16; index += 1) {
    set(`--vt-${index}`, term.palette[index] ?? '#808080')
  }
}

export function terminalPalette(): string[] {
  const style = getComputedStyle(document.documentElement)
  return Array.from({ length: 16 }, (_, index) => {
    return style.getPropertyValue(`--vt-${index}`).trim() || '#808080'
  })
}

export function terminalDefaults(): { bg: string; fg: string; cursor: string } {
  const style = getComputedStyle(document.documentElement)
  return {
    bg: style.getPropertyValue('--vt-bg').trim() || style.getPropertyValue('--chat-black').trim() || '#1f1f28',
    fg: style.getPropertyValue('--vt-fg').trim() || style.getPropertyValue('--text').trim() || '#dcd7ba',
    cursor: style.getPropertyValue('--vt-cursor').trim() || style.getPropertyValue('--text-muted').trim() || '#c8c093',
  }
}

function terminalFromUiColors(colors: Record<string, string>): TerminalTheme {
  const bg = colors.background ?? '#0d1213'
  const text = colors.text ?? '#f0f0f5'
  const muted = colors.text_muted ?? '#b9bbc3'
  const subtle = colors.text_subtle ?? '#787887'
  const danger = colors.diff_remove ?? '#ff6464'
  const green = colors.diff_add ?? '#34e094'
  const yellow = colors.warning ?? '#fbbf24'
  const selection = colors.selection ?? colors.accent ?? '#58a6ff'
  const accent = colors.accent ?? '#50c878'
  return {
    background: bg,
    foreground: text,
    cursor: muted,
    palette: [
      subtle,
      danger,
      green,
      yellow,
      selection,
      accent,
      muted,
      text,
      muted,
      mix(danger, '#ffffff', 0.12),
      mix(green, '#ffffff', 0.12),
      mix(yellow, '#ffffff', 0.12),
      mix(selection, '#ffffff', 0.12),
      mix(accent, '#ffffff', 0.2),
      mix(muted, '#ffffff', 0.14),
      mix(text, '#ffffff', 0.04),
    ],
  }
}

export function startThemeSync(): () => void {
  const tick = async () => {
    const payload = await loadTheme()
    if (!payload?.colors) return
    const json = JSON.stringify({ colors: payload.colors, terminal: payload.terminal })
    if (json === lastJson) return
    lastJson = json
    applyTheme(payload)
    document.documentElement.dataset.themeActive = payload.active
    document.documentElement.dataset.themeSource = payload.source
  }
  void tick()
  const id = window.setInterval(() => void tick(), 2500)
  return () => window.clearInterval(id)
}

function set(name: string, value: string): void {
  document.documentElement.style.setProperty(name, value)
}

function hexToRgb(hex: string): [number, number, number] {
  const value = hex.replace('#', '')
  return [
    Number.parseInt(value.slice(0, 2), 16) || 0,
    Number.parseInt(value.slice(2, 4), 16) || 0,
    Number.parseInt(value.slice(4, 6), 16) || 0,
  ]
}

function mix(from: string, to: string, amount: number): string {
  const a = hexToRgb(from)
  const b = hexToRgb(to)
  const t = Math.min(1, Math.max(0, amount))
  const c = a.map((channel, index) => Math.round(channel + (b[index]! - channel) * t))
  return `#${c.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
}

function rgba(hex: string, alpha: number): string {
  const [r, g, b] = hexToRgb(hex)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

//! Deterministic per-workspace identity (icon + theme-derived color) shared by
//! every Verde client. Contract: docs/workspace-switcher-sidebar.md.

/// Semantic icon names in fixed index order; clients map them to native glyphs.
export const WORKSPACE_ICONS = [
  'folder', 'rocket', 'flask', 'leaf', 'bolt', 'star', 'flame', 'cube',
  'code', 'terminal', 'globe', 'heart', 'moon', 'sun', 'compass', 'puzzle',
] as const

export type WorkspaceIconName = (typeof WORKSPACE_ICONS)[number]

export const WORKSPACE_COLOR_SLOTS = 8

/// FNV-1a 32-bit over the id's UTF-8 bytes.
export function workspaceIdentityHash(id: string): number {
  let hash = 0x811c9dc5
  for (const byte of new TextEncoder().encode(id)) {
    hash = Math.imul(hash ^ byte, 0x01000193) >>> 0
  }
  return hash >>> 0
}

export interface WorkspaceIdentitySlots {
  hash: number
  icon_index: number
  color_index: number
  icon: WorkspaceIconName
}

export function workspaceIdentitySlots(id: string): WorkspaceIdentitySlots {
  const hash = workspaceIdentityHash(id)
  const icon_index = hash % WORKSPACE_ICONS.length
  return {
    hash,
    icon_index,
    color_index: (hash >>> 8) % WORKSPACE_COLOR_SLOTS,
    icon: WORKSPACE_ICONS[icon_index]!,
  }
}

/// Color slot `slot`: the accent's hue rotated by slot*45deg with saturation
/// and lightness clamped so every slot stays legible on the theme background.
export function workspaceSlotColor(accent: string, slot: number, dark: boolean): string {
  const [h, s, l] = rgbToHsl(parseHex(accent))
  const hue = (h + slot * 45) % 360
  const sat = clamp(s, 0.45, 0.85)
  const light = dark ? clamp(l, 0.55, 0.72) : clamp(l, 0.38, 0.5)
  return toHex(hslToRgb(hue, sat, light))
}

export interface WorkspaceIdentity extends WorkspaceIdentitySlots {
  color: string
}

export function workspaceIdentity(id: string, accent: string, dark: boolean): WorkspaceIdentity {
  const slots = workspaceIdentitySlots(id)
  return { ...slots, color: workspaceSlotColor(accent, slots.color_index, dark) }
}

/// True when `background` is a dark color (relative luminance below 0.5).
export function isDarkBackground(background: string): boolean {
  const [r, g, b] = parseHex(background)
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

function parseHex(hex: string): [number, number, number] {
  let value = hex.trim().replace('#', '')
  if (value.length === 3) value = [...value].map((ch) => ch + ch).join('')
  const channel = (offset: number) => Number.parseInt(value.slice(offset, offset + 2), 16) || 0
  return [channel(0), channel(2), channel(4)]
}

function toHex(rgb: [number, number, number]): string {
  return `#${rgb.map((channel) => Math.round(channel).toString(16).padStart(2, '0')).join('')}`
}

function rgbToHsl([r8, g8, b8]: [number, number, number]): [number, number, number] {
  const r = r8 / 255
  const g = g8 / 255
  const b = b8 / 255
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const l = (max + min) / 2
  const d = max - min
  if (d === 0) return [0, 0, l]
  const s = d / (1 - Math.abs(2 * l - 1))
  let h: number
  if (max === r) h = ((g - b) / d) % 6
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  h *= 60
  if (h < 0) h += 360
  return [h, s, l]
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const c = (1 - Math.abs(2 * l - 1)) * s
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = l - c / 2
  const [r, g, b] = h < 60 ? [c, x, 0]
    : h < 120 ? [x, c, 0]
      : h < 180 ? [0, c, x]
        : h < 240 ? [0, x, c]
          : h < 300 ? [x, 0, c]
            : [c, 0, x]
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255]
}

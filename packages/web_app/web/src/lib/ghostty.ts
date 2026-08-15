import wasmUrl from '../assets/ghostty-vt.wasm?url'
import {
  instantiateGhostty,
  simdSupported,
  type GhosttyColor,
  type GhosttyRuntime,
  type GhosttySnapshot,
  type GhosttyTerminal,
} from './ghostty_vt'

import type { ScreenCell, ScreenCursor } from './pty'
import { terminalDefaults, terminalPalette } from './theme'

export type { GhosttySnapshot, GhosttyTerminal }

/// One engine instance per page; every terminal pane shares it. Loaded via
/// arrayBuffer + compile so the gateway's MIME type for .wasm never matters.
let runtime_promise: Promise<GhosttyRuntime> | null = null

function sharedRuntime(): Promise<GhosttyRuntime> {
  if (!runtime_promise) {
    runtime_promise = (async () => {
      if (!simdSupported()) {
        throw new Error('Terminal engine unavailable: this browser lacks WebAssembly SIMD128.')
      }
      const response = await fetch(wasmUrl)
      if (!response.ok) throw new Error(`ghostty-vt.wasm fetch failed (${response.status})`)
      return instantiateGhostty(await response.arrayBuffer())
    })()
    // A transient failure (offline fetch) should not poison every later pane.
    runtime_promise.catch(() => {
      runtime_promise = null
    })
  }
  return runtime_promise
}

const FONT_STACK = '"JetBrains Mono", ui-monospace, monospace'

export const READABLE_FONT = 14
export const READABLE_FONT_MOBILE = 16

/// Phone legibility floor/ceiling for the terminal grid (CSS px).
const MOBILE_MIN_FONT = 12
const MOBILE_MAX_FONT = 17
/// Vertical fill cap for a remote grid shorter than the phone pane.
const MOBILE_MAX_STRETCH = 2
/// Monospace advance per em, measured once the webfont is live.
const CELL_ADVANCE_EM = 0.6

export async function openGhostty(cols: number, rows: number): Promise<GhosttyTerminal> {
  const engine = await sharedRuntime()
  return engine.createTerminal({
    cols: Math.max(20, cols),
    rows: Math.max(6, rows),
    // Retained history backs wheel/touch scrolling via the native viewport
    // (scrollBy/scrollToBottom); 0 would make every pane unscrollable.
    maxScrollback: 4000,
    colorScheme: 'dark',
  })
}

export function cssColor(
  color: GhosttyColor | null | undefined,
  palette: readonly GhosttyColor[],
  fallback: string,
): string {
  if (!color) return fallback
  if (color.kind === 'rgb') return `rgb(${color.red}, ${color.green}, ${color.blue})`
  const themed = terminalPalette()[color.index]
  if (themed) return themed
  const mapped = palette[color.index]
  if (mapped?.kind === 'rgb') return `rgb(${mapped.red}, ${mapped.green}, ${mapped.blue})`
  return fallback
}

/// True only on phone-width viewports, where the grid must fit the screen.
/// A narrow pane on a wide desktop is not a phone.
function phoneViewport(): boolean {
  return typeof window !== 'undefined' && window.innerWidth < 720
}

export function readableFontPx(zoom = 1): number {
  const compact = typeof window !== 'undefined' && window.matchMedia('(max-width: 720px)').matches
  const base = compact ? READABLE_FONT_MOBILE : READABLE_FONT
  return Math.max(11, Math.min(28, base * zoom))
}

export interface PaintInput {
  snap?: GhosttySnapshot | null
  screen?: string
  cols: number
  rows: number
  zoom?: number
  fg?: string
  bg?: string
  cursor?: ScreenCursor
  cells?: ScreenCell[]
}

export interface PaintMetrics {
  cell_w: number
  cell_h: number
  compact: boolean
  cursor_x: number
  cursor_y: number
}

/// Paint the desktop's decoded screen at a readable monospace size.
/// Glyphs come from terminal.screen (already UTF-8 from libghostty).
/// Colors/cursor come from the WASM snapshot when the grid matches.
export function paintGhostty(canvas: HTMLCanvasElement, input: PaintInput): PaintMetrics | null {
  const cols = Math.max(1, input.cols)
  const rows = Math.max(1, input.rows)
  const host = canvas.parentElement
  const view_w = Math.max(1, host?.clientWidth ?? canvas.clientWidth)
  const view_h = Math.max(1, host?.clientHeight ?? canvas.clientHeight)
  if (view_w < 8 || view_h < 8) return null

  const ctx = canvas.getContext('2d')
  if (!ctx) return null

  const theme = themeColors()
  const zoom = input.zoom ?? 1
  const compact = view_w < 720
  let font_px = 14
  let cell_w = 8
  let cell_h = 16
  if (compact) {
    // Phone: fit the whole grid width so the prompt and right-hand TUI chrome
    // land on screen, but never below a legible floor. A 120-160 col desktop
    // grid cannot fit at 12px, so it stays at the floor and the host pans to
    // the cursor instead of squashing glyphs into sub-pixel mush.
    // Narrow desktop columns keep the height-filled size they already had:
    // width-fitting is keyed to the viewport, not to one pane's width.
    ctx.font = `${MOBILE_MAX_FONT}px ${FONT_STACK}`
    const advance = Math.max(0.1, ctx.measureText('M').width / MOBILE_MAX_FONT) || CELL_ADVANCE_EM
    const by_width = phoneViewport() ? view_w / cols / advance : Number.POSITIVE_INFINITY
    const by_height = view_h / rows / 1.3
    const fit = Math.min(by_width, by_height)
    font_px = Math.max(MOBILE_MIN_FONT, Math.min(MOBILE_MAX_FONT, fit)) * zoom
    cell_h = font_px * 1.3
    ctx.font = `${font_px}px ${FONT_STACK}`
    cell_w = Math.max(1, ctx.measureText('M').width)
  } else {
    cell_h = (view_h / rows) * zoom
    font_px = Math.max(8, Math.min(32, cell_h / 1.28))
    ctx.font = `${font_px}px ${FONT_STACK}`
    cell_w = Math.max(1, ctx.measureText('M').width)
  }
  const grid_w = cell_w * cols
  const grid_h = cell_h * rows
  // Phone: the remote grid keeps the desktop pane's aspect, so fitting its width
  // strands a black band under it. Absorb that slack by scaling the canvas
  // vertically instead of padding the line height, which keeps box-drawing runs
  // contiguous. Capped so glyphs stay proportionate rather than smeared.
  const stretch_y = compact && phoneViewport() && grid_h > 8
    ? Math.min(MOBILE_MAX_STRETCH, Math.max(1, view_h / grid_h))
    : 1
  const paint_w = Math.max(view_w, Math.ceil(grid_w))
  const paint_h = Math.max(view_h, Math.ceil(grid_h * stretch_y))
  const layout_h = paint_h / stretch_y

  const dpr = window.devicePixelRatio || 1
  canvas.style.width = `${paint_w}px`
  canvas.style.height = `${paint_h}px`
  const pixel_w = Math.max(1, Math.floor(paint_w * dpr))
  const pixel_h = Math.max(1, Math.floor(paint_h * dpr))
  if (canvas.width !== pixel_w) canvas.width = pixel_w
  if (canvas.height !== pixel_h) canvas.height = pixel_h
  ctx.setTransform(dpr, 0, 0, dpr * stretch_y, 0, 0)
  ctx.imageSmoothingEnabled = false
  ctx.font = `${font_px}px ${FONT_STACK}`
  ctx.textBaseline = 'middle'
  ctx.textAlign = 'left'

  const snap = input.snap
  const desktop = indexDesktopCells(input.cells)
  const term = terminalDefaults()
  const default_bg = input.bg || term.bg || cssColor(snap?.defaultBackground, snap?.palette ?? [], theme.bg)
  const default_fg = input.fg || term.fg || cssColor(snap?.defaultForeground, snap?.palette ?? [], theme.fg)
  ctx.fillStyle = default_bg
  ctx.fillRect(0, 0, paint_w, layout_h)

  const lines = splitScreen(input.screen ?? '', rows)
  // Daemon session.tail is raw PTY, so glyphs usually come from the WASM grid.
  const snap_ok = snap != null && (snap.cols === cols || !input.screen)

  for (let y = 0; y < rows; y += 1) {
    const glyphs = lines[y] ?? []
    const snap_row = snap_ok ? snap.rows[y] : undefined
    const styled = styleByColumn(snap_row?.cells, cols)

    let x = 0
    while (x < cols) {
      const cell = styled[x]
      const style = cell?.style
      const live = desktop.get(`${x},${y}`)
      const from_snap = cell?.text && !isCsiJunk(cell.text) ? cell.text : ''
      const from_screen = glyphs[x] ?? ''
      const glyph = from_screen || from_snap
      const width = cell?.width === 2 || isWide(glyph) ? 2 : 1

      let fg = default_fg
      let bg = default_bg
      let dim = false
      let invisible = false
      if (live) {
        if (live.fg) fg = live.fg
        if (live.bg) bg = live.bg
        dim = Boolean((live.f ?? 0) & 2)
        invisible = Boolean((live.f ?? 0) & 16)
      } else if (style) {
        fg = cssColor(style.foreground, snap!.palette, default_fg)
        bg = cssColor(style.background, snap!.palette, default_bg)
        if (style.inverse) {
          const swap = fg
          fg = bg
          bg = swap
        }
        dim = style.dim
        invisible = style.invisible
      }

      const left = x * cell_w
      const top = y * cell_h
      if (bg !== default_bg) {
        ctx.fillStyle = bg
        ctx.fillRect(left, top, width * cell_w, cell_h)
      }
      if (glyph && glyph !== ' ' && !invisible && !isCsiJunk(glyph)) {
        ctx.fillStyle = dim ? fade(fg, 0.65) : fg
        if ((live?.f ?? 0) & 1) ctx.font = `bold ${font_px}px ${FONT_STACK}`
        ctx.fillText(glyph, left, top + cell_h / 2)
        if ((live?.f ?? 0) & 1) ctx.font = `${font_px}px ${FONT_STACK}`
      }
      x += width
    }
  }

  const cursor = input.cursor?.visible !== false && input.cursor?.x != null
    ? { x: input.cursor.x, y: input.cursor.y ?? 0, visible: true, shape: 'bar' as const }
    : snap?.cursor
  if (cursor?.visible) {
    ctx.fillStyle = term.cursor || cssColor(snap?.cursorColor, snap?.palette ?? [], default_fg)
    const x = cursor.x * cell_w
    const y = cursor.y * cell_h
    if (cursor.shape === 'bar') ctx.fillRect(x, y + 2, Math.max(1.5, cell_w * 0.12), cell_h - 4)
    else if (cursor.shape === 'underline') ctx.fillRect(x, y + cell_h - 3, cell_w, 2)
    else ctx.fillRect(x, y, cell_w, cell_h)
  }

  return {
    cell_w,
    cell_h: cell_h * stretch_y,
    compact,
    cursor_x: cursor?.visible ? cursor.x : 0,
    cursor_y: cursor?.visible ? cursor.y : 0,
  }
}

function indexDesktopCells(cells: ScreenCell[] | undefined): Map<string, ScreenCell> {
  const map = new Map<string, ScreenCell>()
  if (!cells) return map
  for (const cell of cells) map.set(`${cell.x},${cell.y}`, cell)
  return map
}

function splitScreen(text: string, rows: number): string[][] {
  const raw = text.split('\n')
  const lines: string[][] = []
  for (let y = 0; y < rows; y += 1) {
    lines.push(graphemes(raw[y] ?? ''))
  }
  return lines
}

function graphemes(value: string): string[] {
  if (typeof Intl !== 'undefined' && 'Segmenter' in Intl) {
    return [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(value)].map((part) => part.segment)
  }
  return [...value]
}

function styleByColumn(
  cells: GhosttySnapshot['rows'][number]['cells'] | undefined,
  cols: number,
): Array<GhosttySnapshot['rows'][number]['cells'][number] | undefined> {
  const out: Array<GhosttySnapshot['rows'][number]['cells'][number] | undefined> = Array.from({ length: cols })
  if (!cells) return out
  for (const cell of cells) {
    if (cell.x >= 0 && cell.x < cols) out[cell.x] = cell
  }
  return out
}

function isCsiJunk(value: string): boolean {
  return /^(?:\d+;)*\d+m\]?$/.test(value) || /^\[\??\d/.test(value) || value.includes('\x1b')
}

function isWide(value: string): boolean {
  if (!value) return false
  const code = value.codePointAt(0) ?? 0
  return code >= 0x1100 && (
    code <= 0x115f ||
    code === 0x2329 ||
    code === 0x232a ||
    (code >= 0x2e80 && code <= 0xa4cf && code !== 0x303f) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe10 && code <= 0xfe19) ||
    (code >= 0xfe30 && code <= 0xfe6f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6) ||
    (code >= 0x1f300 && code <= 0x1faff)
  )
}

function themeColors(): { bg: string; fg: string } {
  const style = getComputedStyle(document.documentElement)
  return {
    bg: style.getPropertyValue('--chat-black').trim() || '#0d1213',
    fg: style.getPropertyValue('--text').trim() || '#dcd7ba',
  }
}

function fade(rgb: string, amount: number): string {
  const match = rgb.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/)
  if (!match) return rgb
  const next = [match[1], match[2], match[3]].map((part) => Math.round(Number(part) * amount))
  return `rgb(${next[0]}, ${next[1]}, ${next[2]})`
}

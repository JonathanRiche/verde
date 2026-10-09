/**
 * Right side panel state (Changes / Files), mirroring the desktop's side
 * panel. One panel for the web client, remembered across reloads. At lg+ it
 * docks beside the workspace canvas; below that it is a sheet.
 */
import { createRoot, createSignal } from 'solid-js'

export type SidePanelView = 'changes' | 'files'

const VIEW_KEY = 'verde.web.side_panel.view'
const OPEN_KEY = 'verde.web.side_panel.open'
const WIDTH_KEY = 'verde.web.side_panel.width'
export const SIDE_PANEL_MIN_W = 320
export const SIDE_PANEL_DEFAULT_W = 440
/// Split diffs need two readable columns.
export const SIDE_PANEL_SPLIT_MIN_W = 720

function read(key: string): string | null {
  try { return localStorage.getItem(key) } catch { return null }
}
function write(key: string, value: string): void {
  try { localStorage.setItem(key, value) } catch { /* private mode: lasts for this page */ }
}

/// Keeps the canvas at least 360px wide (desktop MIN_CONTENT_W parity).
export function clampPanelWidth(width: number, viewport: number): number {
  const max = Math.max(SIDE_PANEL_MIN_W, viewport - 360 - 280)
  if (!Number.isFinite(width)) return SIDE_PANEL_DEFAULT_W
  return Math.round(Math.min(Math.max(width, SIDE_PANEL_MIN_W), max))
}

export const parseView = (value: string | null): SidePanelView => (value === 'files' ? 'files' : 'changes')

export const sidePanel = createRoot(() => {
  const [view, setViewSignal] = createSignal<SidePanelView>(parseView(read(VIEW_KEY)))
  const [open, setOpenSignal] = createSignal(read(OPEN_KEY) === '1')
  const [width, setWidthSignal] = createSignal(Number(read(WIDTH_KEY)) || SIDE_PANEL_DEFAULT_W)

  const setOpen = (value: boolean) => { setOpenSignal(value); write(OPEN_KEY, value ? '1' : '0') }
  const setView = (value: SidePanelView) => { setViewSignal(value); write(VIEW_KEY, value) }
  const setWidth = (value: number) => { setWidthSignal(value); write(WIDTH_KEY, String(Math.round(value))) }

  /// Shows `target`, or closes the panel when it already shows it.
  const toggle = (target: SidePanelView) => {
    if (open() && view() === target) { setOpen(false); return }
    setView(target)
    setOpen(true)
  }
  const show = (target: SidePanelView) => { setView(target); setOpen(true) }

  // Below lg the panel is a sheet; it never reopens itself on load.
  const [sheetOpen, setSheetOpen] = createSignal(false)
  const showSheet = (target: SidePanelView) => { setView(target); setSheetOpen(true) }

  /// Keyboard toggle (Ctrl+Alt+B): the dock at lg+, the sheet below.
  const toggleVisible = (docked: boolean) => {
    if (docked) setOpen(!open())
    else setSheetOpen(!sheetOpen())
  }

  return { view, setView, open, setOpen, width, setWidth, toggle, show, sheetOpen, setSheetOpen, showSheet, toggleVisible }
})

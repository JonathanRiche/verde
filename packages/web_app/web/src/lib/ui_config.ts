/// Daemon-projected `verde.json` `ui` slice. Defaults match desktop AppConfig.

export interface UiConfig {
  workspace_pane_gap: number
  workspace_panes_per_view: number
  workspace_scroll_direction: 'horizontal' | 'vertical'
  workspace_scroll_mode: 'automatic' | 'always' | 'disabled'
  workspace_scroll_threshold: number
  unzoom_on_pane_navigation: boolean
  reduced_motion: boolean
}

export const DEFAULT_UI_CONFIG: UiConfig = {
  workspace_pane_gap: 12,
  workspace_panes_per_view: 2,
  workspace_scroll_direction: 'horizontal',
  workspace_scroll_mode: 'automatic',
  workspace_scroll_threshold: 2,
  unzoom_on_pane_navigation: false,
  reduced_motion: false,
}

const MIN_PANES_PER_VIEW = 1
const MAX_PANES_PER_VIEW = 6
const MIN_PANE_GAP = 0
const MAX_PANE_GAP = 64
const MIN_SCROLL_THRESHOLD = 1
const MAX_SCROLL_THRESHOLD = 64

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' ? (value as Record<string, unknown>) : null
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}

function numberField(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

/// Decode `core.snapshot` `config` (or a bare `ui` object). Unknown or
/// partial payloads keep desktop defaults so an older daemon still renders.
export function parseUiConfig(raw: unknown): UiConfig {
  const root = asRecord(raw)
  const ui = asRecord(root?.ui) ?? root ?? {}
  const direction = ui.workspace_scroll_direction === 'vertical' ? 'vertical' : 'horizontal'
  const mode =
    ui.workspace_scroll_mode === 'always' || ui.workspace_scroll_mode === 'disabled'
      ? ui.workspace_scroll_mode
      : 'automatic'
  return {
    workspace_pane_gap: clamp(numberField(ui.workspace_pane_gap, DEFAULT_UI_CONFIG.workspace_pane_gap), MIN_PANE_GAP, MAX_PANE_GAP),
    workspace_panes_per_view: clamp(
      Math.round(numberField(ui.workspace_panes_per_view, DEFAULT_UI_CONFIG.workspace_panes_per_view)),
      MIN_PANES_PER_VIEW,
      MAX_PANES_PER_VIEW,
    ),
    workspace_scroll_direction: direction,
    workspace_scroll_mode: mode,
    workspace_scroll_threshold: clamp(
      Math.round(numberField(ui.workspace_scroll_threshold, DEFAULT_UI_CONFIG.workspace_scroll_threshold)),
      MIN_SCROLL_THRESHOLD,
      MAX_SCROLL_THRESHOLD,
    ),
    unzoom_on_pane_navigation: ui.unzoom_on_pane_navigation === true,
    reduced_motion: ui.reduced_motion === true,
  }
}

/// How many columns the strip should fit, matching desktop scrollingLayoutEnabled.
export function effectivePanesPerView(ui: UiConfig, visible_count: number, maximized: boolean): number {
  if (maximized || visible_count <= 1) return 1
  const scrolling =
    ui.workspace_scroll_mode === 'always' ||
    (ui.workspace_scroll_mode === 'automatic' && visible_count >= ui.workspace_scroll_threshold)
  if (!scrolling) return visible_count
  return Math.min(ui.workspace_panes_per_view, visible_count)
}

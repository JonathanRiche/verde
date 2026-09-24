/// Daemon-projected `verde.json` `ui` slice. Defaults match desktop AppConfig.

/// Per-area `ui.reduced_motion_parts`; true means that area does not animate.
export interface ReducedMotionParts {
  /// Strip scroll when focus moves between panes (snaps by default).
  pane_scroll: boolean
  /// Pane resize/zoom easing and the focus-ring crossfade.
  pane_layout: boolean
  /// Breathing pulse on status dots and the running stop button.
  status_pulse: boolean
  /// Transcript and composer fades inside chat panes.
  chat: boolean
  /// Sidebar, drawer, menus, and dialogs.
  chrome: boolean
}

export const DEFAULT_REDUCED_MOTION: ReducedMotionParts = {
  pane_scroll: true,
  pane_layout: false,
  status_pulse: false,
  chat: false,
  chrome: false,
}

const MOTION_PARTS = Object.keys(DEFAULT_REDUCED_MOTION) as Array<keyof ReducedMotionParts>

export interface UiConfig {
  workspace_pane_gap: number
  workspace_panes_per_view: number
  workspace_split_default_pane: 'chat' | 'terminal'
  workspace_scroll_direction: 'horizontal' | 'vertical'
  workspace_scroll_mode: 'automatic' | 'always' | 'disabled'
  workspace_scroll_threshold: number
  unzoom_on_pane_navigation: boolean
  /// Every area reduced; kept for callers that want one switch.
  reduced_motion: boolean
  reduced_motion_parts: ReducedMotionParts
}

export const DEFAULT_UI_CONFIG: UiConfig = {
  workspace_pane_gap: 12,
  workspace_panes_per_view: 1,
  workspace_split_default_pane: 'chat',
  workspace_scroll_direction: 'horizontal',
  workspace_scroll_mode: 'automatic',
  workspace_scroll_threshold: 3,
  unzoom_on_pane_navigation: false,
  reduced_motion: false,
  reduced_motion_parts: DEFAULT_REDUCED_MOTION,
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

/// Same precedence as desktop config load: a legacy `reduced_motion: true`
/// reduces every area (`false` only means "not everything"), then
/// `reduced_motion_parts` refines per area.
function parseReducedMotion(ui: Record<string, unknown>): ReducedMotionParts {
  const parts = { ...DEFAULT_REDUCED_MOTION }
  if (ui.reduced_motion === true) for (const part of MOTION_PARTS) parts[part] = true
  const overrides = asRecord(ui.reduced_motion_parts)
  if (overrides) {
    for (const part of MOTION_PARTS) {
      if (typeof overrides[part] === 'boolean') parts[part] = overrides[part] as boolean
    }
  }
  return parts
}

/// Mirror the parts onto `<html data-reduce-motion-*>` so CSS can disable
/// each area's animations independently.
export function applyReducedMotion(parts: ReducedMotionParts, root: HTMLElement = document.documentElement): void {
  for (const part of MOTION_PARTS) {
    root.toggleAttribute(`data-reduce-motion-${part.replace('_', '-')}`, parts[part])
  }
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
  const reduced_motion_parts = parseReducedMotion(ui)
  return {
    workspace_pane_gap: clamp(numberField(ui.workspace_pane_gap, DEFAULT_UI_CONFIG.workspace_pane_gap), MIN_PANE_GAP, MAX_PANE_GAP),
    workspace_panes_per_view: clamp(
      Math.round(numberField(ui.workspace_panes_per_view, DEFAULT_UI_CONFIG.workspace_panes_per_view)),
      MIN_PANES_PER_VIEW,
      MAX_PANES_PER_VIEW,
    ),
    workspace_split_default_pane: ui.workspace_split_default_pane === 'terminal' ? 'terminal' : 'chat',
    workspace_scroll_direction: direction,
    workspace_scroll_mode: mode,
    workspace_scroll_threshold: clamp(
      Math.round(numberField(ui.workspace_scroll_threshold, DEFAULT_UI_CONFIG.workspace_scroll_threshold)),
      MIN_SCROLL_THRESHOLD,
      MAX_SCROLL_THRESHOLD,
    ),
    unzoom_on_pane_navigation: ui.unzoom_on_pane_navigation === true,
    reduced_motion: MOTION_PARTS.every((part) => reduced_motion_parts[part]),
    reduced_motion_parts,
  }
}

/// A `config.ui.set` request: omitted fields keep their current value.
export type UiConfigPatch = Partial<Omit<UiConfig, 'reduced_motion' | 'reduced_motion_parts'>> & {
  reduced_motion_parts?: Partial<ReducedMotionParts>
}

export const UI_CONFIG_LIMITS = {
  pane_gap: { min: MIN_PANE_GAP, max: MAX_PANE_GAP },
  panes_per_view: { min: MIN_PANES_PER_VIEW, max: MAX_PANES_PER_VIEW },
  scroll_threshold: { min: MIN_SCROLL_THRESHOLD, max: MAX_SCROLL_THRESHOLD },
} as const

export function mergeUiConfigPatch(base: UiConfigPatch, patch: UiConfigPatch): UiConfigPatch {
  const merged: UiConfigPatch = { ...base, ...patch }
  if (base.reduced_motion_parts || patch.reduced_motion_parts) {
    merged.reduced_motion_parts = { ...base.reduced_motion_parts, ...patch.reduced_motion_parts }
  }
  return merged
}

/// Overlay a patch on a parsed config (optimistic web edits, and in-flight
/// edits a stale snapshot must not revert).
export function applyUiConfigPatch(config: UiConfig, patch: UiConfigPatch): UiConfig {
  const { reduced_motion_parts: parts_patch, ...fields } = patch
  const reduced_motion_parts = { ...config.reduced_motion_parts, ...parts_patch }
  return {
    ...config,
    ...fields,
    reduced_motion_parts,
    reduced_motion: MOTION_PARTS.every((part) => reduced_motion_parts[part]),
  }
}

/// Drop the fields of `sent` that `pending` still holds unchanged: the
/// request carrying them settled, newer edits stay pending.
export function settleUiConfigPatch(pending: UiConfigPatch, sent: UiConfigPatch): UiConfigPatch {
  const next: UiConfigPatch = { ...pending }
  const record = next as Record<string, unknown>
  for (const [key, value] of Object.entries(sent)) {
    if (key === 'reduced_motion_parts') continue
    if (record[key] === value) delete record[key]
  }
  if (sent.reduced_motion_parts && next.reduced_motion_parts) {
    const parts = { ...next.reduced_motion_parts }
    for (const [part, value] of Object.entries(sent.reduced_motion_parts)) {
      if (parts[part as keyof ReducedMotionParts] === value) delete parts[part as keyof ReducedMotionParts]
    }
    if (Object.keys(parts).length === 0) delete next.reduced_motion_parts
    else next.reduced_motion_parts = parts
  }
  return next
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

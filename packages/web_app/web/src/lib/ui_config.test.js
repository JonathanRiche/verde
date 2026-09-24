import { describe, expect, test } from 'bun:test'

import { DEFAULT_REDUCED_MOTION, DEFAULT_UI_CONFIG, applyReducedMotion, effectivePanesPerView, parseUiConfig } from './ui_config.ts'

describe('parseUiConfig', () => {
  test('keeps desktop defaults for an empty snapshot', () => {
    expect(parseUiConfig(null)).toEqual(DEFAULT_UI_CONFIG)
  })

  test('reads the daemon ui slice', () => {
    const ui = parseUiConfig({
      ui: {
        workspace_pane_gap: 8,
        workspace_panes_per_view: 1,
        workspace_split_default_pane: 'terminal',
        workspace_scroll_direction: 'vertical',
        workspace_scroll_mode: 'always',
        workspace_scroll_threshold: 4,
        unzoom_on_pane_navigation: true,
        reduced_motion: true,
      },
    })
    expect(ui.workspace_panes_per_view).toBe(1)
    expect(ui.workspace_pane_gap).toBe(8)
    expect(ui.workspace_split_default_pane).toBe('terminal')
    expect(ui.workspace_scroll_direction).toBe('vertical')
    expect(ui.workspace_scroll_mode).toBe('always')
    expect(ui.workspace_scroll_threshold).toBe(4)
    expect(ui.unzoom_on_pane_navigation).toBe(true)
    expect(ui.reduced_motion).toBe(true)
  })
})

describe('effectivePanesPerView', () => {
  test('shows one column when the desktop is in 1-pane scrolling mode', () => {
    const ui = { ...DEFAULT_UI_CONFIG, workspace_panes_per_view: 1, workspace_scroll_mode: 'always' }
    expect(effectivePanesPerView(ui, 3, false)).toBe(1)
  })

  test('fits every pane when scrolling is disabled', () => {
    const ui = { ...DEFAULT_UI_CONFIG, workspace_scroll_mode: 'disabled', workspace_panes_per_view: 1 }
    expect(effectivePanesPerView(ui, 3, false)).toBe(3)
  })

  test('uses the automatic threshold before scrolling', () => {
    const ui = { ...DEFAULT_UI_CONFIG, workspace_panes_per_view: 1, workspace_scroll_threshold: 3 }
    expect(effectivePanesPerView(ui, 2, false)).toBe(2)
    expect(effectivePanesPerView(ui, 3, false)).toBe(1)
  })
})

describe('reduced motion parts', () => {
  test('defaults snap pane scrolling only, like the desktop', () => {
    expect(parseUiConfig({}).reduced_motion_parts).toEqual(DEFAULT_REDUCED_MOTION)
    expect(parseUiConfig({ ui: { reduced_motion: false } }).reduced_motion_parts).toEqual(DEFAULT_REDUCED_MOTION)
    expect(parseUiConfig({}).reduced_motion).toBe(false)
  })

  test('legacy true reduces every area; parts refine it', () => {
    const all = parseUiConfig({ ui: { reduced_motion: true } })
    expect(Object.values(all.reduced_motion_parts).every(Boolean)).toBe(true)
    const refined = parseUiConfig({ ui: { reduced_motion: true, reduced_motion_parts: { pane_scroll: false, chat: 'yes' } } })
    expect(refined.reduced_motion_parts.pane_scroll).toBe(false)
    expect(refined.reduced_motion_parts.chat).toBe(true)
    expect(refined.reduced_motion).toBe(false)
  })

  test('parts map to root data attributes', () => {
    const attrs = new Map()
    const root = { toggleAttribute: (name, on) => { if (on) attrs.set(name, ''); else attrs.delete(name) } }
    applyReducedMotion({ ...DEFAULT_REDUCED_MOTION, status_pulse: true, chrome: true }, root)
    expect([...attrs.keys()].sort()).toEqual([
      'data-reduce-motion-chrome', 'data-reduce-motion-pane-scroll', 'data-reduce-motion-status-pulse',
    ])
    applyReducedMotion({ ...DEFAULT_REDUCED_MOTION, pane_scroll: false }, root)
    expect(attrs.size).toBe(0)
  })
})

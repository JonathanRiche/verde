import { describe, expect, test } from 'bun:test'

import {
  DEFAULT_REDUCED_MOTION, DEFAULT_UI_CONFIG, applyUiConfigPatch, effectivePanesPerView,
  mergeUiConfigPatch, parseUiConfig, settleUiConfigPatch,
} from './ui_config.ts'

test('effectivePanesPerView follows scroll mode and the automatic threshold', () => {
  const ui = { ...DEFAULT_UI_CONFIG, workspace_panes_per_view: 1, workspace_scroll_threshold: 3 }
  expect(effectivePanesPerView({ ...ui, workspace_scroll_mode: 'always' }, 3, false)).toBe(1)
  expect(effectivePanesPerView({ ...ui, workspace_scroll_mode: 'disabled' }, 3, false)).toBe(3)
  expect(effectivePanesPerView(ui, 2, false)).toBe(2)
  expect(effectivePanesPerView(ui, 3, false)).toBe(1)
})

test('legacy reduced_motion true reduces every area; parts refine it', () => {
  const all = parseUiConfig({ ui: { reduced_motion: true } })
  expect(Object.values(all.reduced_motion_parts).every(Boolean)).toBe(true)
  const refined = parseUiConfig({ ui: { reduced_motion: true, reduced_motion_parts: { pane_scroll: false, chat: 'yes' } } })
  expect(refined.reduced_motion_parts.pane_scroll).toBe(false)
  expect(refined.reduced_motion_parts.chat).toBe(true)
  expect(refined.reduced_motion).toBe(false)
})

describe('ui config patches', () => {
  test('apply overlays fields and motion parts and recomputes the master switch', () => {
    const all = Object.fromEntries(Object.keys(DEFAULT_REDUCED_MOTION).map((part) => [part, true]))
    const next = applyUiConfigPatch(DEFAULT_UI_CONFIG, { workspace_pane_gap: 20, reduced_motion_parts: all })
    expect(next.workspace_pane_gap).toBe(20)
    expect(next.reduced_motion).toBe(true)
    expect(applyUiConfigPatch(next, { reduced_motion_parts: { chat: false } }).reduced_motion).toBe(false)
  })

  test('settle keeps newer pending edits and drops confirmed ones', () => {
    const first = { workspace_pane_gap: 20, reduced_motion_parts: { chat: true } }
    const pending = mergeUiConfigPatch(first, { workspace_pane_gap: 21, reduced_motion_parts: { chrome: true } })
    expect(settleUiConfigPatch(pending, first)).toEqual({ workspace_pane_gap: 21, reduced_motion_parts: { chrome: true } })
    expect(settleUiConfigPatch({ workspace_pane_gap: 20 }, { workspace_pane_gap: 20 })).toEqual({})
  })
})

import { expect, test } from 'bun:test'
import { SIDE_PANEL_DEFAULT_W, SIDE_PANEL_MIN_W, clampPanelWidth, parseView } from './side_panel'

test('panel width keeps the canvas usable', () => {
  expect(clampPanelWidth(100, 1600)).toBe(SIDE_PANEL_MIN_W)
  expect(clampPanelWidth(500, 1600)).toBe(500)
  // 1600 - 360 canvas - 280 sidebar
  expect(clampPanelWidth(5000, 1600)).toBe(960)
  expect(clampPanelWidth(Number.NaN, 1600)).toBe(SIDE_PANEL_DEFAULT_W)
  // Tiny viewports still get the minimum (the dock is hidden below lg anyway).
  expect(clampPanelWidth(600, 800)).toBe(SIDE_PANEL_MIN_W)
})

test('unknown stored views fall back to Changes', () => {
  expect(parseView('files')).toBe('files')
  expect(parseView('browser')).toBe('changes')
  expect(parseView(null)).toBe('changes')
})

import { describe, expect, test } from 'bun:test'
import {
  WORKSPACE_ICONS,
  isDarkBackground,
  workspaceIdentity,
  workspaceIdentityHash,
  workspaceIdentitySlots,
  workspaceSlotColor,
} from './workspace_identity'

// Cross-client vectors (docs/workspace-switcher-sidebar.md). Other clients
// should pin the same hash/icon/color slots for these ids.
describe('workspace identity', () => {
  test('pins FNV-1a slots for shared ids', () => {
    expect(workspaceIdentitySlots('ws-alpha')).toEqual({ hash: 0x48d4ea0e, icon_index: 14, color_index: 2, icon: 'compass' })
    expect(workspaceIdentitySlots('baaa819e66d8f3be')).toEqual({ hash: 0x9f38bee9, icon_index: 9, color_index: 6, icon: 'terminal' })
    expect(workspaceIdentitySlots('')).toEqual({ hash: 0x811c9dc5, icon_index: 5, color_index: 5, icon: 'star' })
  })

  test('hashes UTF-8 bytes, not UTF-16 code units', () => {
    // 'é' is 0xC3 0xA9 in UTF-8.
    let manual = 0x811c9dc5
    for (const byte of [0xc3, 0xa9]) manual = Math.imul(manual ^ byte, 0x01000193) >>> 0
    expect(workspaceIdentityHash('é')).toBe(manual)
  })

  test('derives slot colors from the theme accent', () => {
    // Default Verde accent #50c878 on a dark theme.
    expect(workspaceIdentity('ws-alpha', '#50c878', true).color).toBe('#5064c8')
    expect(workspaceIdentity('baaa819e66d8f3be', '#50c878', true).color).toBe('#c8b450')
    expect(workspaceIdentity('', '#50c878', true).color).toBe('#c85a50')
    // Light themes clamp lightness into [0.38, 0.50].
    expect(workspaceIdentity('ws-alpha', '#50c878', false).color).toBe('#3d53c2')
    // Slot 0 is the (clamped) accent itself.
    expect(workspaceSlotColor('#50c878', 0, true)).toBe('#50c878')
    // A gray accent gets saturation clamped up to 0.45.
    expect(workspaceSlotColor('#808080', 0, true)).not.toBe('#808080')
  })

  test('keeps the icon order fixed', () => {
    expect(WORKSPACE_ICONS).toHaveLength(16)
    expect(WORKSPACE_ICONS[0]).toBe('folder')
    expect(WORKSPACE_ICONS[15]).toBe('puzzle')
  })

  test('detects dark backgrounds', () => {
    expect(isDarkBackground('#0d1213')).toBe(true)
    expect(isDarkBackground('#f5f5f5')).toBe(false)
  })
})

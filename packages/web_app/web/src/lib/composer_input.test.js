import { describe, expect, test } from 'bun:test'

import { composerEnterShouldSubmit } from './composer_input.ts'

function enterEvent(init = {}) {
  return { key: 'Enter', shiftKey: false, ...init }
}

describe('composerEnterShouldSubmit', () => {
  test('sends on plain Enter from a desktop keyboard', () => {
    expect(composerEnterShouldSubmit(enterEvent(), { compact: false, coarsePointer: false })).toBe(true)
  })

  test('keeps Shift+Enter as a newline', () => {
    expect(composerEnterShouldSubmit(enterEvent({ shiftKey: true }), { compact: false, coarsePointer: false })).toBe(false)
  })

  test('does not send from the phone layout', () => {
    expect(composerEnterShouldSubmit(enterEvent(), { compact: true, coarsePointer: false })).toBe(false)
  })

  test('does not send from a coarse pointer (iPhone / iPad)', () => {
    expect(composerEnterShouldSubmit(enterEvent(), { compact: false, coarsePointer: true })).toBe(false)
  })

  test('does not send while an IME is composing', () => {
    expect(composerEnterShouldSubmit(enterEvent({ isComposing: true }), { compact: false, coarsePointer: false })).toBe(false)
  })

  test('does not send on the IME keyCode 229 path', () => {
    expect(composerEnterShouldSubmit(enterEvent({ keyCode: 229 }), { compact: false, coarsePointer: false })).toBe(false)
  })

  test('ignores keys that are not Enter', () => {
    expect(composerEnterShouldSubmit({ key: 'a', shiftKey: false }, { compact: false, coarsePointer: false })).toBe(false)
  })
})

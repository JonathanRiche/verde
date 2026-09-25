import { expect, test } from 'bun:test'

import { composerEnterShouldSubmit } from './composer_input.ts'

const desktop = { compact: false, coarsePointer: false }

test('only a plain physical-keyboard Enter outside IME composition submits', () => {
  expect(composerEnterShouldSubmit({ key: 'Enter', shiftKey: false }, desktop)).toBe(true)
  for (const [event, options] of [
    [{ shiftKey: true }, desktop],
    [{}, { compact: true, coarsePointer: false }],
    [{}, { compact: false, coarsePointer: true }],
    [{ isComposing: true }, desktop],
    [{ keyCode: 229 }, desktop],
    [{ key: 'a' }, desktop],
  ]) {
    expect(composerEnterShouldSubmit({ key: 'Enter', shiftKey: false, ...event }, options)).toBe(false)
  }
})

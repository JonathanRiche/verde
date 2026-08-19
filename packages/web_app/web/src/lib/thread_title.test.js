import { describe, expect, test } from 'bun:test'

import { makeThreadTitle } from './thread_title.ts'

describe('makeThreadTitle', () => {
  test('uses the desktop empty-prompt fallback', () => {
    expect(makeThreadTitle(' \n\t ')).toBe('New chat')
  })

  test('compacts the opening prompt into one line', () => {
    expect(makeThreadTitle('  Explain\n\n durable\tchat titles  ')).toBe('Explain durable chat titles')
  })

  test('caps the fallback at 96 UTF-8 bytes', () => {
    expect(new TextEncoder().encode(makeThreadTitle('a'.repeat(120)))).toHaveLength(96)
    expect(new TextEncoder().encode(makeThreadTitle(`Title ${'🌿'.repeat(40)}`)).length).toBeLessThanOrEqual(96)
  })
})

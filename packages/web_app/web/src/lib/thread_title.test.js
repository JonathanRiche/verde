import { expect, test } from 'bun:test'

import { makeThreadTitle } from './thread_title.ts'

test('makeThreadTitle falls back when blank, compacts whitespace and caps at 96 UTF-8 bytes', () => {
  expect(makeThreadTitle(' \n\t ')).toBe('New chat')
  expect(makeThreadTitle('  Explain\n\n durable\tchat titles  ')).toBe('Explain durable chat titles')
  expect(new TextEncoder().encode(makeThreadTitle('a'.repeat(120)))).toHaveLength(96)
  expect(new TextEncoder().encode(makeThreadTitle(`Title ${'🌿'.repeat(40)}`)).length).toBeLessThanOrEqual(96)
})

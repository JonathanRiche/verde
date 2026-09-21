import { describe, expect, test } from 'bun:test'

import { orderRange, pasteBytes, selectionText, wordBounds } from './term_select'

const cells = (text) => [...text]

describe('term_select', () => {
  test('orders reversed drags', () => {
    const range = orderRange({ x: 3, row: 5 }, { x: 9, row: 2 })
    expect(range.start).toEqual({ x: 9, row: 2 })
    expect(range.end).toEqual({ x: 3, row: 5 })
  })

  test('word bounds stop at whitespace', () => {
    expect(wordBounds(cells('ls  foo/bar.txt x'), 6)).toEqual({ from: 4, to: 14 })
    expect(wordBounds(cells('a  b'), 1)).toEqual({ from: 1, to: 1 })
  })

  test('wide-glyph filler cells stay inside the word', () => {
    const line = ['a', ' ', '\u65e5', '', '\u672c', '', ' ', 'b']
    expect(wordBounds(line, 2)).toEqual({ from: 2, to: 5 })
    expect(wordBounds(line, 3)).toEqual({ from: 2, to: 5 })
  })

  test('joins rows, trims trailing blanks, tolerates missing rows', () => {
    const lines = new Map([
      [10, cells('hello world   ')],
      [11, cells('second        ')],
    ])
    const range = { start: { x: 6, row: 10 }, end: { x: 2, row: 12 } }
    expect(selectionText(range, lines)).toBe('world\nsecond\n')
  })

  test('paste encoding', () => {
    expect(pasteBytes('a\r\nb\nc', false)).toBe('a\rb\rc')
    expect(pasteBytes('x\x1b[201~rm', true)).toBe('\x1b[200~xrm\x1b[201~')
  })
})

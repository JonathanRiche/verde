/** Terminal text selection helpers. Rows are absolute (scrollback) row indices. */

export interface CellPoint {
  x: number
  row: number
}

export interface CellRange {
  start: CellPoint
  end: CellPoint
}

/** Order two points into an inclusive range. */
export function orderRange(a: CellPoint, b: CellPoint): CellRange {
  const a_first = a.row < b.row || (a.row === b.row && a.x <= b.x)
  return a_first ? { start: a, end: b } : { start: b, end: a }
}

/** Expand a column to the whitespace-delimited word around it (inclusive). */
export function wordBounds(line: string[], x: number): { from: number; to: number } {
  // '' is the filler after a wide glyph: part of the word, not a gap.
  const blank = (i: number) => line[i] !== '' && !(line[i] ?? '').trim()
  if (x < 0 || x >= line.length || blank(x)) return { from: x, to: x }
  let from = x
  let to = x
  while (from > 0 && !blank(from - 1)) from -= 1
  while (to < line.length - 1 && !blank(to + 1)) to += 1
  return { from, to }
}

/** Join the selected cells; `lines` maps absolute row -> per-column glyphs. */
export function selectionText(range: CellRange, lines: Map<number, string[]>): string {
  const out: string[] = []
  for (let row = range.start.row; row <= range.end.row; row += 1) {
    const line = lines.get(row) ?? []
    const from = row === range.start.row ? range.start.x : 0
    const to = row === range.end.row ? range.end.x + 1 : line.length
    out.push(line.slice(from, to).map((glyph) => glyph ?? ' ').join('').trimEnd())
  }
  return out.join('\n')
}

/**
 * Bytes for pasting into a PTY. Bracketed mode strips the end marker from the
 * payload so pasted text cannot break out of the bracket and run as typed input.
 */
export function pasteBytes(text: string, bracketed: boolean): string {
  const body = text.replace(/\r\n?|\n/g, '\r')
  if (!bracketed) return body
  return `\x1b[200~${body.replaceAll('\x1b[201~', '')}\x1b[201~`
}

import { expect, test } from 'bun:test'
import { changeBar, diffSelectionText, foldPatchLines, hasUnloadedFold, lineNumberOn, parsePatchLines, splitItems, stackedSide } from './diff_lines'

const ctx = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => ` line ${from + i}`)

// Two -U3 hunks of a 40-line file: line 10 and line 30 changed.
const shortPatch = [
  'diff --git a/f.ts b/f.ts', 'index 1..2 100644', '--- a/f.ts', '+++ b/f.ts',
  '@@ -7,7 +7,7 @@', ...ctx(7, 9), '-old 10', '+new 10', ...ctx(11, 13),
  '@@ -27,7 +27,7 @@', ...ctx(27, 29), '-old 30', '+new 30', ...ctx(31, 33), '',
].join('\n')

// The same change with the whole file as context.
const fullPatch = [
  'diff --git a/f.ts b/f.ts', '--- a/f.ts', '+++ b/f.ts',
  '@@ -1,40 +1,40 @@', ...ctx(1, 9), '-old 10', '+new 10', ...ctx(11, 29), '-old 30', '+new 30', ...ctx(31, 40), '',
].join('\n')

const folds = (items) => items.filter((item) => item.kind === 'fold').map(({ fold }) => [fold.key, fold.count, fold.lines === null])

test('hunk headers record their start lines', () => {
  const hunk = parsePatchLines(shortPatch).find((line) => line.kind === 'hunk')
  expect([hunk.old_start, hunk.new_start]).toEqual([7, 7])
})

test('short-context gaps become unloaded folds keyed by first hidden line', () => {
  const items = foldPatchLines(parsePatchLines(shortPatch))
  expect(folds(items)).toEqual([[1, 6, true], [14, 13, true]])
  expect(items.some((item) => item.kind === 'line' && item.line.kind === 'meta')).toBe(false)
  expect(hasUnloadedFold(items)).toBe(true)
})

test('full-context runs fold with the same keys, plus the trailing run', () => {
  const items = foldPatchLines(parsePatchLines(fullPatch))
  expect(folds(items)).toEqual([[1, 6, false], [14, 13, false], [34, 7, false]])
  expect(hasUnloadedFold(items)).toBe(false)
  // Three lines of context stay visible either side of each change.
  const visible = items.filter((item) => item.kind === 'line').map((item) => item.line.old_no)
  expect(visible.slice(0, 4)).toEqual([7, 8, 9, 10])
})

test('revealed folds render their lines', () => {
  const items = foldPatchLines(parsePatchLines(fullPatch), new Set([14]))
  expect(folds(items).map(([key]) => key)).toEqual([1, 34])
  expect(items.filter((item) => item.kind === 'line').length).toBe(3 + 2 + 3 + 13 + 3 + 2 + 3)
})

test('short runs between changes are never folded', () => {
  const patch = ['@@ -1,9 +1,9 @@', '-a', '+b', ...ctx(2, 8), '-c', '+d', ''].join('\n')
  expect(folds(foldPatchLines(parsePatchLines(patch)))).toEqual([])
})

test('new files start at line zero and have no leading gap', () => {
  const patch = ['@@ -0,0 +1,2 @@', '+a', '+b', ''].join('\n')
  expect(folds(foldPatchLines(parsePatchLines(patch)))).toEqual([])
})

test('split items keep folds as full rows and pair edits', () => {
  const items = splitItems(foldPatchLines(parsePatchLines(shortPatch)))
  expect(items[0].kind).toBe('fold')
  const edit = items.find((item) => item.kind === 'row' && item.row.left?.kind === 'del')
  expect(edit.row.right.text).toBe('new 10')
  expect(edit.row.left.emph).toEqual([0, 3])
})

test('change bar scales with size and shows both sides', () => {
  expect(changeBar(0, 0)).toEqual(['none', 'none', 'none', 'none', 'none'])
  const even = changeBar(500, 500)
  expect(even.filter((cell) => cell === 'none').length).toBe(0)
  expect(even.indexOf('del')).toBe(even.lastIndexOf('add') + 1)
  expect(changeBar(1000, 0)).toEqual(['add', 'add', 'add', 'add', 'add'])
  expect(changeBar(1, 0).filter((cell) => cell === 'add').length).toBe(1)
  const mostlyAdds = changeBar(200, 1)
  expect(mostlyAdds.filter((cell) => cell === 'del').length).toBe(1)
  expect(mostlyAdds.filter((cell) => cell !== 'none').length).toBe(5)
})

test('diff line selections read one side of the patch', () => {
  const lines = parsePatchLines(['@@ -4,3 +4,3 @@', ' keep', '-old a', '+new a', ' tail'].join('\n'))
  const [, keep, del, add] = lines
  expect(stackedSide(del)).toBe('old')
  expect(stackedSide(add)).toBe('new')
  expect(lineNumberOn(keep, 'old')).toBe(4)
  expect(lineNumberOn(del, 'new')).toBeNull()
  expect(lineNumberOn(add, 'new')).toBe(5)
  expect(lineNumberOn(lines[0], 'new')).toBeNull()
  expect(diffSelectionText(lines, { side: 'new', start: 4, end: 6 })).toBe('keep\nnew a\ntail')
  expect(diffSelectionText(lines, { side: 'old', start: 5, end: 5 })).toBe('old a')
})

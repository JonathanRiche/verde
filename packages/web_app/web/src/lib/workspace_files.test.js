import { expect, test } from 'bun:test'
import {
  absolutePath, displayPath, rootPath, fenceLanguage, filesErrorText, formatSize, highlightLines, languageForPath, lineRange,
  locateInRoots, parseFileRead, parseFilesListing, selectedText, selectionPrompt,
} from './workspace_files'

test('listings parse roots and root-relative entries and never show .git', () => {
  const listing = parseFilesListing({
    roots: [{ id: 'home', name: 'app', path: '/w/app' }, { id: 'lib', path: '/w/lib' }, { name: 'no id', path: '/w/x' }],
    root: 'home',
    path: '',
    entries: [
      { name: '.git', path: '.git', kind: 'directory' },
      { name: 'src', path: 'src', kind: 'directory' },
      { name: 'dist', path: 'dist', kind: 'directory', ignored: true },
      { name: 'a.ts', path: 'a.ts', kind: 'file', size: 12, symlink: true },
      { name: 'nopath' },
    ],
    truncated: true,
  })
  expect(listing.roots).toEqual([{ id: 'home', name: 'app', path: '/w/app' }, { id: 'lib', name: 'lib', path: '/w/lib' }])
  expect(listing.root).toBe('home')
  expect(listing.path).toBe('')
  expect(listing.entries.map((entry) => entry.name)).toEqual(['src', 'dist', 'a.ts'])
  expect(listing.entries[1].ignored).toBe(true)
  expect(listing.entries[2]).toMatchObject({ kind: 'file', size: 12, symlink: true })
  expect(listing.truncated).toBe(true)
  // Roots-only listing.
  expect(parseFilesListing({ roots: [] })).toMatchObject({ root: null, path: null, entries: [] })
})

test('reads parse kind and encoding with safe defaults', () => {
  expect(parseFileRead({ root: 'home', path: 'docs/a.md', kind: 'markdown', encoding: 'utf8', content: '# hi' }))
    .toMatchObject({ root: 'home', name: 'a.md', kind: 'markdown', content: '# hi' })
  expect(parseFileRead({ root: 'home', path: 'x', kind: 'mystery' }).kind).toBe('binary')
  expect(parseFileRead({ path: 'x', kind: 'text' })).toBeNull()
  expect(parseFileRead({ root: 'home', kind: 'text' })).toBeNull()
})

const ROOTS = [{ id: 'home', name: 'verde', path: '/w/verde' }, { id: 'verde-cloud', name: 'verde-cloud', path: '/w/verde-cloud/' }]

test('display paths match the shared formatter', () => {
  expect(displayPath('/w/verde/src/main.zig', ROOTS)).toBe('src/main.zig')
  expect(displayPath('/w/verde', ROOTS)).toBe('.')
  expect(displayPath('/w/verde-cloud/README', ROOTS)).toBe('verde-cloud/README')
  expect(displayPath('/w/verde-cloud', ROOTS)).toBe('verde-cloud')
  expect(displayPath('/elsewhere/x', ROOTS)).toBe('/elsewhere/x')
  // Nested roots: the deepest wins.
  const nested = [{ id: 'home', name: 'home', path: '/w' }, { id: 'lib', name: 'lib', path: '/w/lib' }]
  expect(displayPath('/w/lib/doc.md', nested)).toBe('lib/doc.md')
  expect(displayPath('/wx/y', nested)).toBe('/wx/y')
})

test('root paths are bare in the home and folder-prefixed elsewhere', () => {
  expect(rootPath(ROOTS[0], 'src/main.zig')).toBe('src/main.zig')
  expect(rootPath(ROOTS[0], '')).toBe('.')
  expect(rootPath(ROOTS[1], 'README')).toBe('verde-cloud/README')
  expect(rootPath({ id: 'docs', name: 'docs' }, '')).toBe('docs')
})

test('absolute paths map to (root, relative path) and back', () => {
  expect(absolutePath(ROOTS[1], 'a/b.ts')).toBe('/w/verde-cloud/a/b.ts')
  expect(absolutePath(ROOTS[0], '')).toBe('/w/verde')
  expect(locateInRoots('/w/verde/src/main.zig', ROOTS)).toEqual({ root: 'home', path: 'src/main.zig' })
  expect(locateInRoots('/w/verde-cloud/README', ROOTS)).toEqual({ root: 'verde-cloud', path: 'README' })
  expect(locateInRoots('/w/verde-clouds/x', ROOTS)).toBeNull()
  expect(locateInRoots('/w/verde', ROOTS)).toBeNull()
  expect(locateInRoots('/w/verde/../etc/passwd', ROOTS)).toBeNull()
  const nested = [{ id: 'home', name: 'home', path: '/w' }, { id: 'lib', name: 'lib', path: '/w/lib' }]
  expect(locateInRoots('/w/lib/x.c', nested)).toEqual({ root: 'lib', path: 'x.c' })
})

test('languages, sizes and error text', () => {
  expect(languageForPath('/a/App.tsx')).toBe('ts')
  expect(languageForPath('/a/Makefile')).toBe('makefile')
  expect(languageForPath('/a/.bashrc')).toBe('sh')
  expect(languageForPath('/a/main.zig')).toBe('zig')
  expect(formatSize(512)).toBe('512 B')
  expect(formatSize(2048)).toBe('2.0 KB')
  expect(formatSize(3 * 1024 * 1024)).toBe('3.0 MB')
  expect(filesErrorText('path_outside_roots')).toContain('outside')
})

test('highlighted lines are lossless and colour across lines', () => {
  const text = 'const a = 1\n/* one\ntwo */\nreturn a\n'
  const lines = highlightLines(text, 'ts')
  expect(lines.length).toBe(4)
  expect(lines.map((line) => line.map((token) => token.text).join('')).join('\n')).toBe(text.slice(0, -1))
  expect(lines[2][0]).toEqual({ cls: 'tok-comment', text: 'two */' })
  // Many lines spill into several tokenizer chunks without losing any.
  const big = Array.from({ length: 4000 }, (_, i) => `let x${i} = ${i}`).join('\n')
  expect(highlightLines(big, 'ts').length).toBe(4000)
})

// Cases mirror packages/client_core/src/selection_prompt.zig so every
// client sends the same text.
test('selection prompt matches the shared formatter', () => {
  expect(lineRange(9, 4)).toEqual({ start: 4, end: 9 })
  expect(selectedText('a\nb\nc\nd', { start: 2, end: 3 })).toBe('b\nc')
  expect(selectionPrompt({ path: '/w/verde/src/main.zig', roots: ROOTS, start_line: 12, text: 'const x = 1;\n', instruction: ' Rename x. ' }))
    .toBe('In `src/main.zig` line 12:\n```zig\nconst x = 1;\n```\nRename x.')
  expect(selectionPrompt({ path: '/w/verde-cloud/README', roots: ROOTS, start_line: 3, end_line: 5, text: 'a\nb\nc', instruction: 'Why?' }))
    .toBe('In `verde-cloud/README` lines 3\u20135:\n```\na\nb\nc\n```\nWhy?')
  const nested = [{ id: 'home', name: 'home', path: '/w' }, { id: 'lib', name: 'lib', path: '/w/lib' }]
  expect(selectionPrompt({ path: '/w/lib/doc.md', roots: nested, start_line: 1, end_line: 2, side: 'old', text: '```zig\n```', instruction: 'Fix' }))
    .toBe('In `lib/doc.md` lines 1\u20132 (diff, old side):\n````markdown\n```zig\n```\n````\nFix')
  expect(selectionPrompt({ path: '/w/a', roots: [], start_line: 4, end_line: 2, text: '', instruction: '' })).toBeNull()
  expect(selectionPrompt({ path: '/w/a', roots: [], start_line: 0, text: '', instruction: '' })).toBeNull()
  expect(selectionPrompt({ path: '/w/a', roots: [], start_line: 1, text: 'x'.repeat(256 * 1024 + 1), instruction: '' })).toBeNull()
  expect(fenceLanguage('/a/App.TSX')).toBe('tsx')
  expect(fenceLanguage('/a/.bashrc')).toBe('')
  expect(fenceLanguage('/a/notes.txt')).toBe('')
})

import { describe, expect, test } from 'bun:test'

import { engineFailureIsPermanent, TextScreen } from './text_screen'

const rows = (screen) => screen.text().split('\n')

describe('text_screen', () => {
  test('prints lines and drops SGR/OSC sequences', () => {
    const screen = new TextScreen(20, 4)
    screen.write('\x1b]0;title\x07\x1b[1;32m$\x1b[0m ls\r\nfile.txt\r\n')
    expect(rows(screen)).toEqual(['$ ls', 'file.txt', '', ''])
    expect(screen.cursor).toEqual({ x: 0, y: 2, visible: true })
  })

  test('scrolls when output passes the bottom row', () => {
    const screen = new TextScreen(10, 3)
    screen.write('a\r\nb\r\nc\r\nd')
    expect(rows(screen)).toEqual(['b', 'c', 'd'])
  })

  test('honours cursor positioning and erase', () => {
    const screen = new TextScreen(10, 3)
    screen.write('hello\r\nworld')
    screen.write('\x1b[1;3H\x1b[K\x1b[2;1HW')
    expect(rows(screen)).toEqual(['he', 'World', ''])
    screen.write('\x1b[2J\x1b[H')
    expect(screen.text()).toBe('\n\n')
  })

  test('wraps at the right margin with deferred wrap', () => {
    const screen = new TextScreen(4, 3)
    screen.write('abcd')
    expect(screen.cursor.y).toBe(0)
    screen.write('e')
    expect(rows(screen)).toEqual(['abcd', 'e', ''])
  })

  test('alternate screen restores the main grid', () => {
    const screen = new TextScreen(10, 2)
    screen.write('shell$')
    screen.write('\x1b[?1049h\x1b[Hvim')
    expect(screen.altScreen).toBe(true)
    expect(rows(screen)).toEqual(['vim', ''])
    screen.write('\x1b[?1049l')
    expect(rows(screen)).toEqual(['shell$', ''])
    expect(screen.cursor.x).toBe(6)
  })

  test('sequences split across writes still parse', () => {
    const screen = new TextScreen(10, 2)
    screen.write('x\x1b[')
    screen.write('2;1Hy\x1b]0;t')
    screen.write('itle\x1b\\z')
    expect(rows(screen)).toEqual(['x', 'yz'])
  })

  test('wide glyphs keep later columns aligned', () => {
    const screen = new TextScreen(10, 1)
    screen.write('日x')
    expect(screen.text()).toBe('日 x')
    expect(screen.cursor.x).toBe(3)
  })

  test('tracks cursor visibility', () => {
    const screen = new TextScreen(10, 1)
    screen.write('\x1b[?25l')
    expect(screen.cursor.visible).toBe(false)
    screen.write('\x1b[?25h')
    expect(screen.cursor.visible).toBe(true)
  })

  test('resize keeps the bottom rows and clamps the cursor', () => {
    const screen = new TextScreen(10, 3)
    screen.write('a\r\nb\r\nprompt')
    screen.resize(4, 2)
    expect(rows(screen)).toEqual(['b', 'prom'])
    expect(screen.cursor).toEqual({ x: 3, y: 1, visible: true })
  })
})

describe('engineFailureIsPermanent', () => {
  test('CSP and compile failures are permanent', () => {
    expect(engineFailureIsPermanent(new WebAssembly.CompileError("WebAssembly.instantiate(): Refused to compile or instantiate WebAssembly module because 'unsafe-eval' is not an allowed source"))).toBe(true)
    expect(engineFailureIsPermanent(new Error('Terminal engine unavailable: this browser lacks WebAssembly SIMD128.'))).toBe(true)
  })

  test('fetch failures are transient', () => {
    expect(engineFailureIsPermanent(new TypeError('Failed to fetch'))).toBe(false)
    expect(engineFailureIsPermanent(new Error('ghostty-vt.wasm fetch failed (503)'))).toBe(false)
  })
})

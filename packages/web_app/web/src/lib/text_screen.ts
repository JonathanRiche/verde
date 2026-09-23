/// Plain-text VT fallback for terminal panes when the libghostty-vt engine
/// cannot load (CSP without 'wasm-unsafe-eval', no SIMD128, trapped module).
/// It consumes the same raw PTY stream as the engine (daemon `session.tail`;
/// `session.screen` is also raw ring bytes, not a rendered grid) and keeps a
/// monochrome character grid: cursor motion, erase, scroll regions and the
/// alternate screen are honoured; colours, scrollback and every other mode are
/// dropped. Output is the `screen` text `paintGhostty` already knows how to draw.

export interface TextCursor {
  x: number
  y: number
  visible: boolean
}

/// True when an engine load failure will recur on every retry, so the pane
/// should switch to the text fallback at once instead of burning retries.
export function engineFailureIsPermanent(error: unknown): boolean {
  if (typeof WebAssembly !== 'undefined') {
    if (error instanceof WebAssembly.CompileError || error instanceof WebAssembly.LinkError) return true
  }
  const name = error instanceof Error ? error.name : ''
  const message = error instanceof Error ? error.message : String(error ?? '')
  if (name === 'CompileError' || name === 'LinkError' || name === 'SecurityError') return true
  return /SIMD128|unsafe-eval|Content Security Policy|WebAssembly\.(?:instantiate|compile)\(\).*(?:not allowed|refused)/i.test(message)
}

type Mode = 'ground' | 'esc' | 'csi' | 'string' | 'string_esc' | 'charset'

export class TextScreen {
  cols: number
  rows: number
  cursor: TextCursor = { x: 0, y: 0, visible: true }
  private grid: string[][]
  private saved_main: { grid: string[][]; cursor: TextCursor } | null = null
  private saved_cursor: { x: number; y: number } | null = null
  private top = 0
  private bottom: number
  private wrap_pending = false
  private mode: Mode = 'ground'
  private params = ''

  constructor(cols: number, rows: number) {
    this.cols = Math.max(1, Math.floor(cols))
    this.rows = Math.max(1, Math.floor(rows))
    this.bottom = this.rows - 1
    this.grid = this.blankGrid()
  }

  get altScreen(): boolean {
    return this.saved_main != null
  }

  /// Visible grid as newline-joined rows (trailing blanks trimmed per row).
  text(): string {
    return this.grid.map((row) => row.join('').replace(/\s+$/, '')).join('\n')
  }

  reset(): void {
    this.saved_main = null
    this.saved_cursor = null
    this.grid = this.blankGrid()
    this.cursor = { x: 0, y: 0, visible: true }
    this.top = 0
    this.bottom = this.rows - 1
    this.wrap_pending = false
    this.mode = 'ground'
    this.params = ''
  }

  /// Keep the top-left content; the PTY repaints after its own SIGWINCH.
  resize(cols: number, rows: number): void {
    const next_cols = Math.max(1, Math.floor(cols))
    const next_rows = Math.max(1, Math.floor(rows))
    if (next_cols === this.cols && next_rows === this.rows) return
    const fit = (grid: string[][]) => {
      // Rows that no longer fit leave from the top, so the prompt stays visible.
      const kept = grid.slice(Math.max(0, grid.length - next_rows))
      while (kept.length < next_rows) kept.push([])
      return kept.map((row) => {
        const line = row.slice(0, next_cols)
        while (line.length < next_cols) line.push(' ')
        return line
      })
    }
    const dropped = Math.max(0, this.rows - next_rows)
    this.grid = fit(this.grid)
    if (this.saved_main) this.saved_main.grid = fit(this.saved_main.grid)
    this.cols = next_cols
    this.rows = next_rows
    this.top = 0
    this.bottom = next_rows - 1
    this.cursor.x = Math.min(this.cursor.x, next_cols - 1)
    this.cursor.y = Math.max(0, Math.min(this.cursor.y - dropped, next_rows - 1))
    this.wrap_pending = false
  }

  write(bytes: string): void {
    for (const char of bytes) this.feed(char)
  }

  private feed(char: string): void {
    const code = char.codePointAt(0) ?? 0
    switch (this.mode) {
      case 'esc':
        return this.escape(char)
      case 'csi':
        if (code >= 0x40 && code <= 0x7e) {
          this.mode = 'ground'
          this.csi(char, this.params)
        } else if (code === 0x1b) {
          this.mode = 'esc'
        } else {
          this.params += char
        }
        return
      case 'string':
        // OSC/DCS/APC/PM bodies end at BEL or ST (ESC \).
        if (code === 0x07) this.mode = 'ground'
        else if (code === 0x1b) this.mode = 'string_esc'
        return
      case 'string_esc':
        this.mode = char === '\\' ? 'ground' : 'string'
        return
      case 'charset':
        this.mode = 'ground'
        return
    }
    if (code === 0x1b) {
      this.mode = 'esc'
      return
    }
    if (code < 0x20 || code === 0x7f) return this.control(code)
    if (code >= 0x80 && code < 0xa0) return
    this.print(char, code)
  }

  private control(code: number): void {
    switch (code) {
      case 0x08:
        this.wrap_pending = false
        this.cursor.x = Math.max(0, this.cursor.x - 1)
        return
      case 0x09:
        this.wrap_pending = false
        this.cursor.x = Math.min(this.cols - 1, (Math.floor(this.cursor.x / 8) + 1) * 8)
        return
      case 0x0a:
      case 0x0b:
      case 0x0c:
        this.lineFeed()
        return
      case 0x0d:
        this.wrap_pending = false
        this.cursor.x = 0
        return
    }
  }

  private escape(char: string): void {
    this.mode = 'ground'
    switch (char) {
      case '[':
        this.mode = 'csi'
        this.params = ''
        return
      case ']':
      case 'P':
      case '_':
      case '^':
      case 'X':
        this.mode = 'string'
        return
      case '(':
      case ')':
      case '*':
      case '+':
      case '#':
      case '%':
        this.mode = 'charset'
        return
      case '7':
        this.saved_cursor = { x: this.cursor.x, y: this.cursor.y }
        return
      case '8':
        if (this.saved_cursor) this.moveTo(this.saved_cursor.x, this.saved_cursor.y)
        return
      case 'D':
        this.lineFeed()
        return
      case 'E':
        this.cursor.x = 0
        this.lineFeed()
        return
      case 'M':
        this.wrap_pending = false
        if (this.cursor.y === this.top) this.scrollDown(1)
        else this.cursor.y = Math.max(0, this.cursor.y - 1)
        return
      case 'c':
        this.reset()
        return
    }
  }

  private csi(final: string, raw: string): void {
    const private_mode = raw.startsWith('?')
    // Other intermediates/prefixes (>, =, space, !) mark queries we ignore.
    if (/^[<=>]/.test(raw) || /[ !"$']/.test(raw)) return
    const list = (private_mode ? raw.slice(1) : raw).split(';').map((part) => {
      const value = Number.parseInt(part.split(':')[0], 10)
      return Number.isFinite(value) ? value : 0
    })
    const arg = (index: number, fallback = 1) => (list[index] ? list[index] : fallback)
    const x = this.cursor.x
    const y = this.cursor.y
    if (private_mode) {
      if (final === 'h' || final === 'l') for (const mode of list) this.privateMode(mode, final === 'h')
      return
    }
    switch (final) {
      case 'A':
        return this.moveTo(x, Math.max(this.cursor.y >= this.top ? this.top : 0, y - arg(0)))
      case 'B':
      case 'e':
        return this.moveTo(x, Math.min(this.cursor.y <= this.bottom ? this.bottom : this.rows - 1, y + arg(0)))
      case 'C':
      case 'a':
        return this.moveTo(x + arg(0), y)
      case 'D':
        return this.moveTo(x - arg(0), y)
      case 'E':
        return this.moveTo(0, y + arg(0))
      case 'F':
        return this.moveTo(0, y - arg(0))
      case 'G':
      case '`':
        return this.moveTo(arg(0) - 1, y)
      case 'd':
        return this.moveTo(x, arg(0) - 1)
      case 'H':
      case 'f':
        return this.moveTo(arg(1) - 1, arg(0) - 1)
      case 'J':
        return this.eraseDisplay(list[0] ?? 0)
      case 'K':
        return this.eraseLine(list[0] ?? 0)
      case 'X':
        this.fill(y, x, Math.min(this.cols, x + arg(0)))
        return
      case 'P': {
        const row = this.grid[y]
        row.splice(x, Math.min(arg(0), this.cols - x))
        while (row.length < this.cols) row.push(' ')
        return
      }
      case '@': {
        const row = this.grid[y]
        row.splice(x, 0, ...new Array<string>(Math.min(arg(0), this.cols - x)).fill(' '))
        row.length = this.cols
        return
      }
      case 'L':
        if (y >= this.top && y <= this.bottom) this.scrollRegion(y, this.bottom, -arg(0))
        return
      case 'M':
        if (y >= this.top && y <= this.bottom) this.scrollRegion(y, this.bottom, arg(0))
        return
      case 'S':
        return this.scrollUp(arg(0))
      case 'T':
        return this.scrollDown(arg(0))
      case 'r': {
        const top = arg(0) - 1
        const bottom = (list[1] ? list[1] : this.rows) - 1
        if (top < bottom && bottom < this.rows) {
          this.top = top
          this.bottom = bottom
        } else {
          this.top = 0
          this.bottom = this.rows - 1
        }
        return this.moveTo(0, 0)
      }
      case 's':
        this.saved_cursor = { x, y }
        return
      case 'u':
        if (this.saved_cursor) this.moveTo(this.saved_cursor.x, this.saved_cursor.y)
        return
    }
  }

  private privateMode(mode: number, on: boolean): void {
    if (mode === 25) {
      this.cursor.visible = on
      return
    }
    if (mode !== 1049 && mode !== 1047 && mode !== 47) return
    if (on && !this.saved_main) {
      this.saved_main = { grid: this.grid, cursor: { ...this.cursor } }
      this.grid = this.blankGrid()
      this.top = 0
      this.bottom = this.rows - 1
    } else if (!on && this.saved_main) {
      this.grid = this.saved_main.grid
      this.cursor = this.saved_main.cursor
      this.saved_main = null
      this.top = 0
      this.bottom = this.rows - 1
    }
    this.wrap_pending = false
  }

  private print(char: string, code: number): void {
    const row = this.grid[this.cursor.y]
    // Combining marks and joiners attach to the previous cell.
    if ((code >= 0x300 && code <= 0x36f) || code === 0x200d || (code >= 0xfe00 && code <= 0xfe0f)) {
      const at = this.wrap_pending ? this.cursor.x : Math.max(0, this.cursor.x - 1)
      row[at] = (row[at] === ' ' ? '' : row[at]) + char
      return
    }
    const width = wide(code) ? 2 : 1
    if (this.wrap_pending || this.cursor.x + width > this.cols) {
      this.cursor.x = 0
      this.lineFeed()
    }
    const target = this.grid[this.cursor.y]
    target[this.cursor.x] = char
    // A space keeps later columns aligned; the painter skips the second cell.
    if (width === 2 && this.cursor.x + 1 < this.cols) target[this.cursor.x + 1] = ' '
    if (this.cursor.x + width >= this.cols) {
      this.cursor.x = this.cols - 1
      this.wrap_pending = true
    } else {
      this.cursor.x += width
    }
  }

  private moveTo(x: number, y: number): void {
    this.wrap_pending = false
    this.cursor.x = Math.max(0, Math.min(this.cols - 1, x))
    this.cursor.y = Math.max(0, Math.min(this.rows - 1, y))
  }

  private lineFeed(): void {
    this.wrap_pending = false
    if (this.cursor.y === this.bottom) this.scrollUp(1)
    else this.cursor.y = Math.min(this.rows - 1, this.cursor.y + 1)
  }

  private scrollUp(count: number): void {
    this.scrollRegion(this.top, this.bottom, count)
  }

  private scrollDown(count: number): void {
    this.scrollRegion(this.top, this.bottom, -count)
  }

  /// Positive count moves rows up (content leaves at `from`); negative moves down.
  private scrollRegion(from: number, to: number, count: number): void {
    const span = to - from + 1
    const amount = Math.min(span, Math.abs(count))
    if (amount <= 0) return
    const region = this.grid.slice(from, to + 1)
    const blanks = Array.from({ length: amount }, () => this.blankRow())
    const next = count > 0 ? [...region.slice(amount), ...blanks] : [...blanks, ...region.slice(0, span - amount)]
    this.grid.splice(from, span, ...next)
  }

  private eraseDisplay(kind: number): void {
    const { x, y } = this.cursor
    if (kind === 0) {
      this.fill(y, x, this.cols)
      for (let row = y + 1; row < this.rows; row += 1) this.grid[row] = this.blankRow()
    } else if (kind === 1) {
      for (let row = 0; row < y; row += 1) this.grid[row] = this.blankRow()
      this.fill(y, 0, x + 1)
    } else if (kind === 2 || kind === 3) {
      this.grid = this.blankGrid()
    }
  }

  private eraseLine(kind: number): void {
    const { x, y } = this.cursor
    if (kind === 0) this.fill(y, x, this.cols)
    else if (kind === 1) this.fill(y, 0, x + 1)
    else if (kind === 2) this.grid[y] = this.blankRow()
  }

  private fill(y: number, from: number, to: number): void {
    const row = this.grid[y]
    for (let x = Math.max(0, from); x < Math.min(this.cols, to); x += 1) row[x] = ' '
  }

  private blankRow(): string[] {
    return new Array<string>(this.cols).fill(' ')
  }

  private blankGrid(): string[][] {
    return Array.from({ length: this.rows }, () => this.blankRow())
  }
}

function wide(code: number): boolean {
  return code >= 0x1100 && (
    code <= 0x115f ||
    code === 0x2329 ||
    code === 0x232a ||
    (code >= 0x2e80 && code <= 0xa4cf && code !== 0x303f) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe10 && code <= 0xfe19) ||
    (code >= 0xfe30 && code <= 0xfe6f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6) ||
    (code >= 0x1f300 && code <= 0x1faff)
  )
}

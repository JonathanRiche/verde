/// Verde-owned binding over the official pre-built `ghostty-vt.wasm`
/// (libghostty-vt). Replaces the abandoned `@slopus/ghostty-wasm` wrapper
/// while preserving its public surface (`GhosttyTerminal` / `GhosttySnapshot`
/// / `GhosttyColor`) so the paint path stays untouched.
///
/// Pin: ghostty-org/ghostty@d760ee96e54657416eb427b793c7e839f003df7d
/// Artifact: https://tip.files.ghostty.org/d760ee96e54657416eb427b793c7e839f003df7d/ghostty-vt.wasm
/// SHA-256: 429a012aa07105f158a01676c5c02d852cc0b31a4ca6c04d95ab2338df3f837a
///
/// ABI rules (from include/ghostty/vt/*.h at the pin):
/// - wasm32: pointers/size_t are u32, little-endian; structs pass by pointer.
/// - Struct layouts come from `ghostty_type_json()` at runtime, never from
///   hard-coded offsets — the JSON is the compatibility contract.
/// - DataViews are recreated whenever wasm memory grows (buffer identity).

export type GhosttyColor =
  | { kind: 'rgb'; red: number; green: number; blue: number }
  | { kind: 'palette'; index: number }

export interface GhosttyCellStyle {
  foreground: GhosttyColor | null
  background: GhosttyColor | null
  bold: boolean
  inverse: boolean
  dim: boolean
  invisible: boolean
}

export interface GhosttyCell {
  x: number
  text: string
  width: number
  style?: GhosttyCellStyle
}

export interface GhosttyRow {
  cells: GhosttyCell[]
}

export interface GhosttyCursor {
  visible: boolean
  x: number
  y: number
  shape: 'bar' | 'block' | 'underline' | 'block_hollow'
}

export interface GhosttySnapshot {
  cols: number
  rows: GhosttyRow[]
  /// Viewport geometry in scrollbar row space: the viewport is at the live
  /// tail when startRow + visibleRows >= totalRows.
  startRow: number
  visibleRows: number
  totalRows: number
  cursor: GhosttyCursor | null
  defaultBackground: GhosttyColor | null
  defaultForeground: GhosttyColor | null
  cursorColor: GhosttyColor | null
  palette: GhosttyColor[]
}

export interface GhosttyTerminal {
  write(data: string): void
  resize(cols: number, rows: number): void
  snapshot(): GhosttySnapshot
  scrollBy(rows: number): void
  scrollToBottom(): void
  dispose(): void
}

export interface GhosttyTerminalOptions {
  cols: number
  rows: number
  /// Retained history in rows (libghostty scrollback-max-lines).
  maxScrollback?: number
  /// Accepted for compatibility with the old wrapper; Verde themes colors
  /// at paint time, so the engine's default scheme is never shown raw.
  colorScheme?: 'dark' | 'light'
}

// GhosttyResult (types.h)
const RESULT_SUCCESS = 0
const RESULT_OUT_OF_SPACE = -3

// GhosttyTerminalData / GhosttyTerminalOption (terminal.h)
const TERMINAL_DATA_SCROLLBAR = 9
const TERMINAL_OPT_SCROLLBACK_MAX_LINES = 28

// GhosttyTerminalScrollViewportTag (terminal.h)
const SCROLL_VIEWPORT_BOTTOM = 1
const SCROLL_VIEWPORT_DELTA = 2

// GhosttyRenderStateData (render.h)
const RS_DATA_COLS = 1
const RS_DATA_ROWS = 2
const RS_DATA_DIRTY = 3
const RS_DATA_ROW_ITERATOR = 4
const RS_DATA_CURSOR_VISUAL_STYLE = 10
const RS_DATA_CURSOR_VISIBLE = 11
const RS_DATA_CURSOR_VIEWPORT_HAS_VALUE = 14
const RS_DATA_CURSOR_VIEWPORT_X = 15
const RS_DATA_CURSOR_VIEWPORT_Y = 16

// GhosttyRenderStateOption (render.h)
const RS_OPTION_DIRTY = 0

// GhosttyRenderStateRowData / GhosttyRenderStateRowCellsData (render.h)
const ROW_DATA_CELLS = 3
const CELL_DATA_STYLE = 2
const CELL_DATA_HAS_STYLING = 8
const CELL_DATA_GRAPHEMES_UTF8 = 9

// GhosttyStyleColorTag (style.h)
const STYLE_COLOR_PALETTE = 1
const STYLE_COLOR_RGB = 2

const CURSOR_SHAPES: GhosttyCursor['shape'][] = ['bar', 'block', 'underline', 'block_hollow']

/// One grapheme cluster; libghostty reports the required size on overflow.
const TEXT_CAP = 256

interface GhosttyExports {
  memory: WebAssembly.Memory
  ghostty_type_json(): number
  ghostty_wasm_alloc_opaque(): number
  ghostty_wasm_free_opaque(ptr: number): void
  ghostty_wasm_alloc_u8_array(len: number): number
  ghostty_wasm_free_u8_array(ptr: number, len: number): void
  ghostty_terminal_new(allocator: number, out: number, cols: number, rows: number): number
  ghostty_terminal_free(term: number): void
  ghostty_terminal_vt_write(term: number, ptr: number, len: number): void
  ghostty_terminal_resize(term: number, cols: number, rows: number, cell_w: number, cell_h: number): number
  ghostty_terminal_set(term: number, option: number, value: number): number
  ghostty_terminal_get(term: number, data: number, out: number): number
  ghostty_terminal_scroll_viewport(term: number, behavior: number): void
  ghostty_render_state_new(allocator: number, out: number): number
  ghostty_render_state_free(state: number): void
  ghostty_render_state_update(state: number, term: number): number
  ghostty_render_state_get(state: number, data: number, out: number): number
  ghostty_render_state_set(state: number, option: number, value: number): number
  ghostty_render_state_colors_get(state: number, out: number): number
  ghostty_render_state_row_iterator_new(allocator: number, out: number): number
  ghostty_render_state_row_iterator_free(iterator: number): void
  ghostty_render_state_row_iterator_next(iterator: number): number
  ghostty_render_state_row_get(iterator: number, data: number, out: number): number
  ghostty_render_state_row_cells_new(allocator: number, out: number): number
  ghostty_render_state_row_cells_free(cells: number): void
  ghostty_render_state_row_cells_next(cells: number): number
  ghostty_render_state_row_cells_get(cells: number, data: number, out: number): number
}

interface FieldLayout {
  offset: number
  size: number
  type: string
}

interface TypeLayout {
  size: number
  fields: Record<string, FieldLayout>
}

export interface GhosttyRuntime {
  exports: GhosttyExports
  createTerminal(options: GhosttyTerminalOptions): GhosttyTerminal
}

const decoder = new TextDecoder()
const encoder = new TextEncoder()

export function simdSupported(): boolean {
  // Minimal module using a v128 local; the official wasm requires SIMD128.
  const probe = Uint8Array.of(
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0xfd, 0x0f, 0x1a, 0x0b,
  )
  try {
    return WebAssembly.validate(probe)
  } catch {
    return false
  }
}

/// Instantiate the shared engine. All terminals on a page share one instance:
/// the C API is handle-based and the web app is single-threaded.
export async function instantiateGhostty(
  source: WebAssembly.Module | BufferSource,
): Promise<GhosttyRuntime> {
  const imports = {
    env: {
      log: (ptr: number, len: number) => {
        try {
          const memory = (instance.exports as unknown as GhosttyExports).memory
          console.debug('[ghostty-vt]', decoder.decode(new Uint8Array(memory.buffer, ptr, len)))
        } catch {
          // Logging must never take down the terminal.
        }
      },
    },
  }
  const instance =
    source instanceof WebAssembly.Module
      ? await WebAssembly.instantiate(source, imports)
      : (await WebAssembly.instantiate(source, imports)).instance
  return buildRuntime(instance.exports as unknown as GhosttyExports)
}

function buildRuntime(exports: GhosttyExports): GhosttyRuntime {
  // The type layout JSON is the ABI contract for struct offsets.
  const json_ptr = exports.ghostty_type_json()
  const json_bytes = new Uint8Array(exports.memory.buffer, json_ptr)
  const nul = json_bytes.indexOf(0)
  const layouts = JSON.parse(decoder.decode(json_bytes.subarray(0, nul < 0 ? undefined : nul))) as Record<
    string,
    TypeLayout
  >
  const layout = (name: string): TypeLayout => {
    const found = layouts[name]
    if (!found) throw new Error(`ghostty-vt: missing type layout ${name}`)
    return found
  }
  const field = (name: string, field_name: string): FieldLayout => {
    const found = layout(name).fields[field_name]
    if (!found) throw new Error(`ghostty-vt: missing field ${name}.${field_name}`)
    return found
  }

  const style_type = layout('GhosttyStyle')
  const style_fg = field('GhosttyStyle', 'fg_color')
  const style_bg = field('GhosttyStyle', 'bg_color')
  const style_bold = field('GhosttyStyle', 'bold')
  const style_faint = field('GhosttyStyle', 'faint')
  const style_inverse = field('GhosttyStyle', 'inverse')
  const style_invisible = field('GhosttyStyle', 'invisible')
  const style_size = field('GhosttyStyle', 'size')
  const color_tag = field('GhosttyStyleColor', 'tag')
  const color_value = field('GhosttyStyleColor', 'value')
  const colors_type = layout('GhosttyRenderStateColors')
  const colors_size = field('GhosttyRenderStateColors', 'size')
  const colors_background = field('GhosttyRenderStateColors', 'background')
  const colors_foreground = field('GhosttyRenderStateColors', 'foreground')
  const colors_cursor = field('GhosttyRenderStateColors', 'cursor')
  const colors_cursor_has_value = field('GhosttyRenderStateColors', 'cursor_has_value')
  const colors_palette = field('GhosttyRenderStateColors', 'palette')
  const rgb_size = layout('GhosttyColorRgb').size
  const scrollbar_total = field('GhosttyTerminalScrollbar', 'total')
  const scrollbar_offset = field('GhosttyTerminalScrollbar', 'offset')
  const scrollbar_len = field('GhosttyTerminalScrollbar', 'len')
  const scroll_type = layout('GhosttyTerminalScrollViewport')
  const scroll_tag = field('GhosttyTerminalScrollViewport', 'tag')
  const scroll_value = field('GhosttyTerminalScrollViewport', 'value')
  const buffer_ptr = field('GhosttyBuffer', 'ptr')
  const buffer_cap = field('GhosttyBuffer', 'cap')
  const buffer_len = field('GhosttyBuffer', 'len')
  const buffer_size = layout('GhosttyBuffer').size

  // Scratch arena for out-params, reused across calls (single-threaded).
  const scratch_size = Math.max(colors_type.size, style_type.size, scroll_type.size) + 64 + buffer_size + TEXT_CAP
  const scratch = exports.ghostty_wasm_alloc_u8_array(scratch_size)
  if (!scratch) throw new Error('ghostty-vt: scratch allocation failed')
  const struct_ptr = scratch
  const small_ptr = scratch + Math.max(colors_type.size, style_type.size, scroll_type.size)
  const gbuf_ptr = small_ptr + 32
  const text_ptr = gbuf_ptr + buffer_size
  const handle_slot = exports.ghostty_wasm_alloc_opaque()
  if (!handle_slot) throw new Error('ghostty-vt: handle slot allocation failed')

  // Wasm memory growth detaches the old buffer; refresh views by identity.
  let view_cache = new DataView(exports.memory.buffer)
  const view = (): DataView => {
    if (view_cache.buffer !== exports.memory.buffer) view_cache = new DataView(exports.memory.buffer)
    return view_cache
  }
  const bytes = (ptr: number, len: number): Uint8Array => new Uint8Array(exports.memory.buffer, ptr, len)

  const check = (result: number, what: string): void => {
    if (result !== RESULT_SUCCESS) throw new Error(`ghostty-vt: ${what} failed (${result})`)
  }
  const takeHandle = (result: number, what: string): number => {
    check(result, what)
    const handle = view().getUint32(handle_slot, true)
    if (!handle) throw new Error(`ghostty-vt: ${what} returned null handle`)
    return handle
  }

  const readRgb = (ptr: number): GhosttyColor => {
    const v = view()
    return { kind: 'rgb', red: v.getUint8(ptr), green: v.getUint8(ptr + 1), blue: v.getUint8(ptr + 2) }
  }

  const readStyleColor = (ptr: number): GhosttyColor | null => {
    const v = view()
    const tag = v.getUint32(ptr + color_tag.offset, true)
    if (tag === STYLE_COLOR_PALETTE) return { kind: 'palette', index: v.getUint8(ptr + color_value.offset) }
    if (tag === STYLE_COLOR_RGB) return readRgb(ptr + color_value.offset)
    return null
  }

  const createTerminal = (options: GhosttyTerminalOptions): GhosttyTerminal => {
    const cols = Math.max(1, Math.floor(options.cols))
    const rows = Math.max(1, Math.floor(options.rows))
    const term = takeHandle(exports.ghostty_terminal_new(0, handle_slot, cols, rows), 'terminal_new')
    let state = 0
    let row_iter = 0
    let row_cells = 0
    let write_ptr = 0
    let write_cap = 0
    let disposed = false
    let cached: GhosttySnapshot | null = null

    const free = (): void => {
      if (row_cells) exports.ghostty_render_state_row_cells_free(row_cells)
      if (row_iter) exports.ghostty_render_state_row_iterator_free(row_iter)
      if (state) exports.ghostty_render_state_free(state)
      if (write_ptr) exports.ghostty_wasm_free_u8_array(write_ptr, write_cap)
      exports.ghostty_terminal_free(term)
      row_cells = row_iter = state = write_ptr = write_cap = 0
    }

    try {
      if (options.maxScrollback != null) {
        view().setUint32(small_ptr, Math.max(0, Math.floor(options.maxScrollback)), true)
        check(
          exports.ghostty_terminal_set(term, TERMINAL_OPT_SCROLLBACK_MAX_LINES, small_ptr),
          'set scrollback-max-lines',
        )
      }
      state = takeHandle(exports.ghostty_render_state_new(0, handle_slot), 'render_state_new')
      row_iter = takeHandle(exports.ghostty_render_state_row_iterator_new(0, handle_slot), 'row_iterator_new')
      row_cells = takeHandle(exports.ghostty_render_state_row_cells_new(0, handle_slot), 'row_cells_new')
    } catch (error) {
      free()
      throw error
    }

    const ensureLive = (): void => {
      if (disposed) throw new Error('ghostty-vt: terminal disposed')
    }

    const getSmallU16 = (getter: (out: number) => number, what: string): number => {
      check(getter(small_ptr), what)
      return view().getUint16(small_ptr, true)
    }
    const getSmallU32 = (getter: (out: number) => number, what: string): number => {
      check(getter(small_ptr), what)
      return view().getUint32(small_ptr, true)
    }
    const getSmallBool = (getter: (out: number) => number, what: string): boolean => {
      check(getter(small_ptr), what)
      return view().getUint8(small_ptr) !== 0
    }

    const readCellText = (): string => {
      let v = view()
      v.setUint32(gbuf_ptr + buffer_ptr.offset, text_ptr, true)
      v.setUint32(gbuf_ptr + buffer_cap.offset, TEXT_CAP, true)
      v.setUint32(gbuf_ptr + buffer_len.offset, 0, true)
      const result = exports.ghostty_render_state_row_cells_get(row_cells, CELL_DATA_GRAPHEMES_UTF8, gbuf_ptr)
      // A cluster over TEXT_CAP bytes is pathological input; drop its text.
      if (result === RESULT_OUT_OF_SPACE) return ''
      check(result, 'cell graphemes')
      v = view()
      const len = v.getUint32(gbuf_ptr + buffer_len.offset, true)
      if (!len) return ''
      return decoder.decode(bytes(text_ptr, len))
    }

    const readCellStyle = (): GhosttyCellStyle => {
      view().setUint32(struct_ptr + style_size.offset, style_type.size, true)
      check(exports.ghostty_render_state_row_cells_get(row_cells, CELL_DATA_STYLE, struct_ptr), 'cell style')
      const v = view()
      return {
        foreground: readStyleColor(struct_ptr + style_fg.offset),
        background: readStyleColor(struct_ptr + style_bg.offset),
        bold: v.getUint8(struct_ptr + style_bold.offset) !== 0,
        inverse: v.getUint8(struct_ptr + style_inverse.offset) !== 0,
        dim: v.getUint8(struct_ptr + style_faint.offset) !== 0,
        invisible: v.getUint8(struct_ptr + style_invisible.offset) !== 0,
      }
    }

    const snapshot = (): GhosttySnapshot => {
      ensureLive()
      check(exports.ghostty_render_state_update(state, term), 'render_state_update')
      const dirty = getSmallU32((out) => exports.ghostty_render_state_get(state, RS_DATA_DIRTY, out), 'dirty')
      if (dirty === 0 && cached) return cached

      const view_cols = getSmallU16((out) => exports.ghostty_render_state_get(state, RS_DATA_COLS, out), 'cols')
      const view_rows = getSmallU16((out) => exports.ghostty_render_state_get(state, RS_DATA_ROWS, out), 'rows')

      // Defaults + palette in one sized-struct call.
      view().setUint32(struct_ptr + colors_size.offset, colors_type.size, true)
      check(exports.ghostty_render_state_colors_get(state, struct_ptr), 'colors_get')
      const v = view()
      const background = readRgb(struct_ptr + colors_background.offset)
      const foreground = readRgb(struct_ptr + colors_foreground.offset)
      const cursor_color = v.getUint8(struct_ptr + colors_cursor_has_value.offset)
        ? readRgb(struct_ptr + colors_cursor.offset)
        : null
      const palette: GhosttyColor[] = new Array(256)
      for (let index = 0; index < 256; index += 1) {
        palette[index] = readRgb(struct_ptr + colors_palette.offset + index * rgb_size)
      }

      // Viewport position in scrollbar row space (u64s; row counts fit a double).
      check(exports.ghostty_terminal_get(term, TERMINAL_DATA_SCROLLBAR, struct_ptr), 'scrollbar')
      const sv = view()
      const total_rows = Number(sv.getBigUint64(struct_ptr + scrollbar_total.offset, true))
      const start_row = Number(sv.getBigUint64(struct_ptr + scrollbar_offset.offset, true))
      const scrollbar_rows = Number(sv.getBigUint64(struct_ptr + scrollbar_len.offset, true))

      let cursor: GhosttyCursor | null = null
      const in_viewport = getSmallBool(
        (out) => exports.ghostty_render_state_get(state, RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, out),
        'cursor has_value',
      )
      if (in_viewport) {
        const visible = getSmallBool(
          (out) => exports.ghostty_render_state_get(state, RS_DATA_CURSOR_VISIBLE, out),
          'cursor visible',
        )
        const cursor_x = getSmallU16(
          (out) => exports.ghostty_render_state_get(state, RS_DATA_CURSOR_VIEWPORT_X, out),
          'cursor x',
        )
        const cursor_y = getSmallU16(
          (out) => exports.ghostty_render_state_get(state, RS_DATA_CURSOR_VIEWPORT_Y, out),
          'cursor y',
        )
        const shape_tag = getSmallU32(
          (out) => exports.ghostty_render_state_get(state, RS_DATA_CURSOR_VISUAL_STYLE, out),
          'cursor style',
        )
        cursor = { visible, x: cursor_x, y: cursor_y, shape: CURSOR_SHAPES[shape_tag] ?? 'block' }
      }

      // Sparse rows: only cells with text or explicit styling are materialized,
      // matching what the paint path consumes. Populate-style gets take a
      // pointer to the pre-allocated handle, not the handle itself.
      view().setUint32(handle_slot, row_iter, true)
      check(exports.ghostty_render_state_get(state, RS_DATA_ROW_ITERATOR, handle_slot), 'row_iterator populate')
      const out_rows: GhosttyRow[] = []
      while (exports.ghostty_render_state_row_iterator_next(row_iter)) {
        const cells: GhosttyCell[] = []
        view().setUint32(handle_slot, row_cells, true)
        check(exports.ghostty_render_state_row_get(row_iter, ROW_DATA_CELLS, handle_slot), 'row cells populate')
        let x = 0
        while (exports.ghostty_render_state_row_cells_next(row_cells)) {
          const styled = getSmallBool(
            (out) => exports.ghostty_render_state_row_cells_get(row_cells, CELL_DATA_HAS_STYLING, out),
            'cell has_styling',
          )
          const text = readCellText()
          if (text || styled) {
            const cell: GhosttyCell = { x, text, width: 1 }
            if (styled) cell.style = readCellStyle()
            cells.push(cell)
          }
          x += 1
        }
        out_rows.push({ cells })
      }

      // Consume dirty so an unchanged terminal can reuse this snapshot.
      view().setUint32(small_ptr, 0, true)
      exports.ghostty_render_state_set(state, RS_OPTION_DIRTY, small_ptr)

      cached = {
        cols: view_cols,
        rows: out_rows,
        startRow: start_row,
        visibleRows: scrollbar_rows || view_rows,
        totalRows: total_rows,
        cursor,
        defaultBackground: background,
        defaultForeground: foreground,
        cursorColor: cursor_color,
        palette,
      }
      return cached
    }

    const scroll = (tag: number, delta: number): void => {
      ensureLive()
      const v = view()
      const base = struct_ptr
      new Uint8Array(exports.memory.buffer, base, scroll_type.size).fill(0)
      v.setUint32(base + scroll_tag.offset, tag, true)
      v.setInt32(base + scroll_value.offset, delta, true)
      exports.ghostty_terminal_scroll_viewport(term, base)
      cached = null
    }

    return {
      write(data: string): void {
        ensureLive()
        if (!data) return
        const encoded = encoder.encode(data)
        if (encoded.length > write_cap) {
          if (write_ptr) exports.ghostty_wasm_free_u8_array(write_ptr, write_cap)
          write_cap = Math.max(8192, encoded.length)
          write_ptr = exports.ghostty_wasm_alloc_u8_array(write_cap)
          if (!write_ptr) {
            write_cap = 0
            throw new Error('ghostty-vt: write buffer allocation failed')
          }
        }
        bytes(write_ptr, encoded.length).set(encoded)
        exports.ghostty_terminal_vt_write(term, write_ptr, encoded.length)
        cached = null
      },
      resize(next_cols: number, next_rows: number): void {
        ensureLive()
        // Cell pixel sizes only feed XTWINOPS pixel reports; the web canvas
        // rasterizes at paint time, so nominal cell metrics are fine.
        check(
          exports.ghostty_terminal_resize(
            term,
            Math.max(1, Math.floor(next_cols)),
            Math.max(1, Math.floor(next_rows)),
            8,
            16,
          ),
          'resize',
        )
        cached = null
      },
      snapshot,
      scrollBy(delta_rows: number): void {
        const step = Math.trunc(delta_rows)
        if (step) scroll(SCROLL_VIEWPORT_DELTA, step)
      },
      scrollToBottom(): void {
        scroll(SCROLL_VIEWPORT_BOTTOM, 0)
      },
      dispose(): void {
        if (disposed) return
        disposed = true
        cached = null
        free()
      },
    }
  }

  return { exports, createTerminal }
}

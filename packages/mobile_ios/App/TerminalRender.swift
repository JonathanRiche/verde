import CoreGraphics
import Foundation
import UIKit

// Pure presentation rules for the terminal grid (unit tested). Grid contents are
// user content: nothing here logs, and nothing is exposed to accessibility.

struct GridSize: Equatable {
    var cols: UInt16
    var rows: UInt16
}

/// Monospace cell size in points and the text baseline offset within a cell.
struct CellMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var baseline: CGFloat

    /// Cell width is rounded to device pixels so background runs never leave seams.
    static func monospaced(size: CGFloat, scale: CGFloat) -> CellMetrics {
        let font = UIFont.monospacedSystemFont(ofSize: max(size, 1), weight: .regular)
        let ctFont = font as CTFont
        var character: UniChar = 0x4d // "M"
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        }
        // Monospace advance is ~0.6 em; implausible measurements use that instead.
        let natural = advance.width >= size * 0.3 ? advance.width : size * 0.6
        let pixels = max(scale, 1)
        let width = max((natural * pixels).rounded() / pixels, 1 / pixels)
        let height = ceil(font.ascender - font.descender + max(font.leading, 0))
        return CellMetrics(width: width, height: height > 0 ? height : ceil(size * 1.2),
                           baseline: font.ascender > 0 ? font.ascender : size)
    }
}

let MIN_FONT_POINTS: CGFloat = 8
let MAX_FONT_POINTS: CGFloat = 32
let MAX_GRID_SIDE = 512
let MAX_GRID_CELLS = 65_536

/// Largest grid that fits, bounded by the core's limits (512 per side, 65,536 cells).
func terminalGrid(width: CGFloat, height: CGFloat, metrics: CellMetrics) -> GridSize {
    var cols = min(max(Int((width / max(metrics.width, 1)).rounded(.down)), 1), MAX_GRID_SIDE)
    let rows = min(max(Int((height / max(metrics.height, 1)).rounded(.down)), 1), MAX_GRID_SIDE)
    if cols * rows > MAX_GRID_CELLS { cols = MAX_GRID_CELLS / rows }
    return GridSize(cols: UInt16(cols), rows: UInt16(rows))
}

/// `#RRGGBB` → 0xRRGGBB; malformed values fall back to `fallback`.
func parseColor(_ value: String, _ fallback: UInt32) -> UInt32 {
    guard value.utf8.count == 7, value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) else { return fallback }
    return rgb
}

func cgColor(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
}

struct TextStyle: Equatable {
    var fg: UInt32
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    /// Decorations are drawn even over blank cells.
    var decorated: Bool { underline || strikethrough }
}

/// `ascii` runs hold single-cell printable ASCII (blanks as spaces) drawn glyph by
/// glyph at exact cell positions; other runs are one cell (wide = 2) each.
struct TextRun: Equatable {
    var row: Int
    var col: Int
    var text: String
    var cells: Int
    var style: TextStyle
    var ascii: Bool
}

struct BgRun: Equatable {
    var row: Int
    var col: Int
    var cells: Int
    var color: UInt32
}

struct CursorBox: Equatable {
    var row: Int
    var col: Int
    var cells: Int
    var shape: TerminalCursorShape
    var color: UInt32
    /// Glyph under a block cursor, redrawn in `textColor`.
    var text: String
    var textColor: UInt32
    var style: TextStyle
}

struct RenderPlan: Equatable {
    var cols: Int
    var rows: Int
    var background: UInt32
    var backgrounds: [BgRun]
    var texts: [TextRun]
    var cursor: CursorBox?
}

private func printableASCII(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    return scalars.count == 1 && (0x21...0x7e).contains(scalars.first!.value)
}

/// Draw operations for one snapshot. Colors are already resolved by the VT (including
/// reverse-video mode); only the per-cell inverse flag is applied here. The fill is the
/// most common background; other backgrounds merge into horizontal runs.
func renderPlan(_ snapshot: TerminalSnapshot, fallbackFg: UInt32 = 0xffffff, fallbackBg: UInt32 = 0x000000) -> RenderPlan {
    let cols = Int(snapshot.cols), rows = Int(snapshot.rows)
    let cells = snapshot.cells
    let count = min(cells.count, cols * rows)
    var fgs = [UInt32](repeating: fallbackFg, count: count)
    var bgs = [UInt32](repeating: fallbackBg, count: count)
    var frequency: [UInt32: Int] = [:]
    for i in 0..<count {
        var fg = parseColor(cells[i].fg, fallbackFg)
        var bg = parseColor(cells[i].bg, fallbackBg)
        if cells[i].inverse { swap(&fg, &bg) }
        fgs[i] = fg
        bgs[i] = bg
        frequency[bg, default: 0] += 1
    }
    let background = frequency.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? fallbackBg
    var backgrounds: [BgRun] = []
    var texts: [TextRun] = []
    func style(_ i: Int) -> TextStyle {
        TextStyle(fg: fgs[i], bold: cells[i].bold, italic: cells[i].italic,
                  underline: cells[i].underline, strikethrough: cells[i].strikethrough)
    }
    for row in 0..<rows {
        var col = 0
        while col < cols, row * cols + col < count {
            let bg = bgs[row * cols + col]
            var end = col + 1
            while end < cols, row * cols + end < count, bgs[row * cols + end] == bg { end += 1 }
            if bg != background { backgrounds.append(BgRun(row: row, col: col, cells: end - col, color: bg)) }
            col = end
        }
        var run: TextRun?
        func flush() {
            guard var current = run else { return }
            run = nil
            if !current.style.decorated {
                // Blanks only matter under decorations.
                let leading = current.text.prefix { $0 == " " }.count
                current.text = String(current.text.dropFirst(leading))
                current.col += leading
                while current.text.last == " " { current.text.removeLast() }
                current.cells = current.text.count
                if current.text.isEmpty { return }
            }
            texts.append(current)
        }
        for c in 0..<cols {
            let i = row * cols + c
            guard i < count else { break }
            let cell = cells[i]
            if cell.width == 0 { flush(); continue }
            let blank = cell.text.isEmpty || cell.text == " "
            let cellStyle = style(i)
            if cell.width == 1, blank || printableASCII(cell.text) {
                let glyph = blank ? " " : cell.text
                if run != nil, run!.style == cellStyle, run!.col + run!.cells == c {
                    run!.text += glyph
                    run!.cells += 1
                } else {
                    flush()
                    run = TextRun(row: row, col: c, text: glyph, cells: 1, style: cellStyle, ascii: true)
                }
                continue
            }
            flush()
            texts.append(TextRun(row: row, col: c, text: cell.text, cells: cell.width == 2 ? 2 : 1, style: cellStyle, ascii: false))
        }
        flush()
    }
    var cursor: CursorBox?
    let at = snapshot.cursor
    if at.visible, snapshot.scroll_offset == 0, Int(at.row) < rows, Int(at.col) < cols {
        let i = Int(at.row) * cols + Int(at.col)
        let inside = i < count
        cursor = CursorBox(row: Int(at.row), col: Int(at.col), cells: inside && cells[i].width == 2 ? 2 : 1,
                           shape: at.shape, color: inside ? fgs[i] : fallbackFg,
                           text: inside && cells[i].text != " " ? cells[i].text : "",
                           textColor: inside ? bgs[i] : background,
                           style: inside ? style(i) : TextStyle(fg: fallbackFg))
    }
    return RenderPlan(cols: cols, rows: rows, background: background, backgrounds: backgrounds, texts: texts, cursor: cursor)
}

/// A linear (stream) selection between two grid cells, inclusive, in either drag direction.
struct GridSelection: Equatable {
    var anchorRow: Int
    var anchorCol: Int
    var row: Int
    var col: Int

    private var ordered: ((Int, Int), (Int, Int)) {
        (anchorRow, anchorCol) <= (row, col) ? ((anchorRow, anchorCol), (row, col)) : ((row, col), (anchorRow, anchorCol))
    }
    var start: (row: Int, col: Int) { ordered.0 }
    var end: (row: Int, col: Int) { ordered.1 }
    func contains(_ r: Int, _ c: Int) -> Bool { start <= (r, c) && (r, c) <= end }
}

/// Selected text; trailing blanks per line are trimmed, and lines join with `\n`.
func selectedText(_ snapshot: TerminalSnapshot, _ selection: GridSelection) -> String {
    let cols = Int(snapshot.cols)
    let (startRow, startCol) = selection.start
    let (endRow, endCol) = selection.end
    guard cols > 0, startRow <= min(endRow, Int(snapshot.rows) - 1) else { return "" }
    var lines: [String] = []
    for row in max(startRow, 0)...min(endRow, Int(snapshot.rows) - 1) {
        let from = row == startRow ? startCol : 0
        let to = row == endRow ? min(endCol, cols - 1) : cols - 1
        var line = ""
        if from <= to {
            for col in from...to {
                let index = row * cols + col
                guard index < snapshot.cells.count else { break }
                let cell = snapshot.cells[index]
                if cell.width == 0 { continue }
                line += cell.text.isEmpty ? " " : cell.text
            }
        }
        while line.last == " " { line.removeLast() }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

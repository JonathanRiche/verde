package dev.verdeai.app

import dev.verdeai.core.TerminalCursorShape
import dev.verdeai.core.TerminalSnapshot
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// Pure presentation rules for the terminal canvas (unit tested). Grid contents are
// user content: nothing here logs, and nothing is exposed to semantics.

/** Monospace cell size in pixels and the text baseline offset within a cell. */
internal data class CellMetrics(val width: Float, val height: Float, val baseline: Float)

/** Largest grid that fits, bounded by the core's limits (512 per side, 65,536 cells). */
internal fun terminalGrid(widthPx: Float, heightPx: Float, metrics: CellMetrics): Pair<Int, Int> {
    var cols = floor(widthPx / max(metrics.width, 1f)).toInt().coerceIn(1, MAX_GRID_SIDE)
    val rows = floor(heightPx / max(metrics.height, 1f)).toInt().coerceIn(1, MAX_GRID_SIDE)
    if (cols * rows > MAX_GRID_CELLS) cols = MAX_GRID_CELLS / rows
    return cols to rows
}

internal const val MAX_GRID_SIDE = 512
internal const val MAX_GRID_CELLS = 65_536

/** `#RRGGBB` → opaque ARGB; malformed values fall back to [fallback]. */
internal fun parseColor(value: String, fallback: Int): Int =
    if (value.length == 7 && value[0] == '#') value.substring(1).toIntOrNull(16)?.let { it or (0xff shl 24) } ?: fallback
    else fallback

internal data class TextRun(val row: Int, val col: Int, val text: String, val cells: Int,
    val fg: Int, val bold: Boolean, val italic: Boolean, val underline: Boolean, val strikethrough: Boolean)
internal data class BgRun(val row: Int, val col: Int, val cells: Int, val color: Int)
internal data class CursorBox(val row: Int, val col: Int, val cells: Int, val shape: TerminalCursorShape, val color: Int, val textColor: Int)
internal data class RenderPlan(val cols: Int, val rows: Int, val background: Int, val backgrounds: List<BgRun>,
    val texts: List<TextRun>, val cursor: CursorBox?)

/**
 * Draw operations for one snapshot. Colors are already resolved by the VT (including
 * reverse-video mode); only the per-cell inverse flag is applied here. The canvas fill is
 * the most common background, and other backgrounds merge into horizontal runs.
 */
internal fun renderPlan(snapshot: TerminalSnapshot, fallbackFg: Int = 0xffffffff.toInt(), fallbackBg: Int = 0xff000000.toInt()): RenderPlan {
    val cols = snapshot.cols
    val rows = snapshot.rows
    val cells = snapshot.cells
    val count = min(cells.size, cols * rows)
    val fgs = IntArray(count)
    val bgs = IntArray(count)
    val frequency = HashMap<Int, Int>()
    for (i in 0 until count) {
        val cell = cells[i]
        var fg = parseColor(cell.fg, fallbackFg)
        var bg = parseColor(cell.bg, fallbackBg)
        if (cell.inverse) { val swap = fg; fg = bg; bg = swap }
        fgs[i] = fg; bgs[i] = bg
        frequency.merge(bg, 1, Int::plus)
    }
    val background = frequency.maxByOrNull { it.value }?.key ?: fallbackBg
    val backgrounds = ArrayList<BgRun>()
    val texts = ArrayList<TextRun>()
    for (row in 0 until rows) {
        var col = 0
        while (col < cols) {
            val i = row * cols + col
            if (i >= count) break
            val bg = bgs[i]
            var end = col + 1
            while (end < cols && row * cols + end < count && bgs[row * cols + end] == bg) end++
            if (bg != background) backgrounds += BgRun(row, col, end - col, bg)
            col = end
        }
        for (c in 0 until cols) {
            val i = row * cols + c
            if (i >= count) break
            val cell = cells[i]
            if (cell.width == 0 || cell.text.isEmpty() || cell.text == " ") continue
            texts += TextRun(row, c, cell.text, if (cell.width == 2) 2 else 1, fgs[i], cell.bold, cell.italic, cell.underline, cell.strikethrough)
        }
    }
    val cursor = snapshot.cursor.takeIf { it.visible && snapshot.scroll_offset == 0L && it.row in 0 until rows && it.col in 0 until cols }?.let {
        val i = it.row * cols + it.col
        val wide = i < count && cells[i].width == 2
        CursorBox(it.row, it.col, if (wide) 2 else 1, it.shape, if (i < count) fgs[i] else fallbackFg, if (i < count) bgs[i] else background)
    }
    return RenderPlan(cols, rows, background, backgrounds, texts, cursor)
}

/** A linear (stream) selection between two grid cells, inclusive, in either drag direction. */
internal data class GridSelection(val anchorRow: Int, val anchorCol: Int, val row: Int, val col: Int) {
    private val startKey get() = min(anchorRow * 1_000 + anchorCol, row * 1_000 + col)
    private val endKey get() = max(anchorRow * 1_000 + anchorCol, row * 1_000 + col)
    fun contains(r: Int, c: Int) = (r * 1_000 + c) in startKey..endKey
    val start get() = startKey / 1_000 to startKey % 1_000
    val end get() = endKey / 1_000 to endKey % 1_000
}

/** Selected text; trailing blanks per line are trimmed, and lines join with `\n`. */
internal fun selectedText(snapshot: TerminalSnapshot, selection: GridSelection): String {
    val cols = snapshot.cols
    val (startRow, startCol) = selection.start
    val (endRow, endCol) = selection.end
    val lines = ArrayList<String>()
    for (row in startRow.coerceAtLeast(0)..min(endRow, snapshot.rows - 1)) {
        val from = if (row == startRow) startCol else 0
        val to = if (row == endRow) min(endCol, cols - 1) else cols - 1
        val line = StringBuilder()
        for (col in from..to) {
            val cell = snapshot.cells.getOrNull(row * cols + col) ?: break
            if (cell.width == 0) continue
            line.append(cell.text.ifEmpty { " " })
        }
        lines += line.trimEnd().toString()
    }
    return lines.joinToString("\n")
}

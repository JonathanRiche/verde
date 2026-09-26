package dev.verdeai.app

import dev.verdeai.core.*

/**
 * D-07 diff card data layer. The core owns all diff parsing: `diff_index` locates each
 * VERDE_DIFF_V2 file record, `diff` parses one record into hunks/lines/word spans, and `highlight`
 * supplies syntax spans. This file only maps those results onto display rows (UTF-8 byte offsets
 * to UTF-16 indices, tab expansion) and formats copies. There is deliberately no Kotlin diff parser.
 */
internal interface DiffRenderSource {
    fun cachedIndex(body: String): RenderResult<DiffIndexView>?
    suspend fun index(body: String): RenderResult<DiffIndexView>
    fun cachedDiff(text: String): RenderResult<DiffView>?
    suspend fun diff(text: String): RenderResult<DiffView>
    fun cachedHighlight(code: String, language: String): RenderResult<List<RenderSpan>>?
    suspend fun highlight(code: String, language: String): RenderResult<List<RenderSpan>>
}

internal fun TranscriptModel.diffSource(): DiffRenderSource {
    val model = this
    return object : DiffRenderSource {
        override fun cachedIndex(body: String) = model.cachedDiffIndex(body)
        override suspend fun index(body: String) = model.diffIndex(body)
        override fun cachedDiff(text: String) = model.cachedDiff(text)
        override suspend fun diff(text: String) = model.diff(text)
        override fun cachedHighlight(code: String, language: String) = model.cachedHighlight(code, language)
        override suspend fun highlight(code: String, language: String) = model.highlight(code, language)
    }
}

/** A `diff_index` body whose byte offsets can be sliced back into per-file record strings. */
internal class DiffBody(val body: String) {
    private val bytes by lazy(LazyThreadSafetyMode.PUBLICATION) { body.encodeToByteArray() }

    /** Byte range [start, end) of the body; the core only reports ranges on UTF-8 boundaries. */
    private fun slice(start: ULong, end: ULong): String? {
        val size = bytes.size.toULong()
        if (start > end || end > size) return null
        return bytes.decodeToString(start.toInt(), end.toInt())
    }

    /** The file's record re-wrapped as a one-file VERDE_DIFF_V2 body, plus its bare patch. */
    fun record(entry: DiffIndexEntry): DiffRecord? {
        val record = slice(entry.start, entry.end) ?: return null
        val patch = slice(entry.patch_start, entry.end) ?: return null
        return DiffRecord(DIFF_MARKER + record, patch)
    }
}

internal data class DiffRecord(val text: String, val patch: String)

/** Languages the core ships grammars for (K-11); anything else renders without syntax colours. */
internal fun diffLanguage(path: String): String? =
    when (path.substringAfterLast('/').substringAfterLast('.', "").lowercase()) {
        "js", "mjs", "cjs" -> "js"
        "jsx" -> "jsx"
        "ts", "mts", "cts" -> "ts"
        "tsx" -> "tsx"
        "json" -> "json"
        else -> null
    }

/** A styled range of a display row, in UTF-16 indices of [DiffRow.text]. */
internal data class DiffRange(val start: Int, val end: Int, val kind: String)

/**
 * One unified-view row. [text] is display text (tabs expanded); [raw] is the core's line text,
 * used for copies. [words] are the core's word-level change spans, [syntax] its highlight spans.
 */
internal data class DiffRow(
    val kind: String,
    val raw: String,
    val text: String,
    val oldLine: ULong?,
    val newLine: ULong?,
    val words: List<DiffRange>,
    val syntax: List<DiffRange>,
)

internal data class DiffHunkModel(val header: String, val rows: List<DiffRow>)

internal data class DiffFileModel(val binary: Boolean, val hunks: List<DiffHunkModel>, val numberWidth: Int) {
    val lineCount = hunks.sumOf { it.rows.size }
}

/** What an expanded file shows: the core's parse, or (when the core can't render it) its source. */
internal sealed interface DiffFileRender {
    data class Parsed(val model: DiffFileModel) : DiffFileRender
    data class Source(val patch: String) : DiffFileRender
}

internal const val TAB_WIDTH = 4

internal fun hunkHeader(hunk: DiffHunk) = "@@ -${hunk.old_start},${hunk.old_count} +${hunk.new_start},${hunk.new_count} @@"

/** The hunk as a unified-diff fragment (header plus prefixed lines), for "Copy hunk". */
internal fun hunkPatch(hunk: DiffHunkModel): String = buildString {
    append(hunk.header)
    for (row in hunk.rows) {
        append('\n')
        when (row.kind) {
            "add" -> append('+')
            "delete" -> append('-')
            "context" -> append(' ')
        }
        append(row.raw)
    }
    append('\n')
}

/**
 * Parses one file through the core and attaches syntax spans. Returns [DiffFileRender.Source] when
 * the core cannot render the record (budget, malformed), so the patch shows as plain text.
 */
internal suspend fun renderDiffFile(source: DiffRenderSource, record: DiffRecord, path: String): DiffFileRender {
    val files = source.diff(record.text).value?.files
    if (files.isNullOrEmpty()) return DiffFileRender.Source(record.patch)
    val hunks = files.flatMap { it.hunks }
    val language = diffLanguage(path)
    var oldSpans: List<RenderSpan> = emptyList()
    var newSpans: List<RenderSpan> = emptyList()
    if (language != null && hunks.isNotEmpty()) {
        oldSpans = sideSpans(source, sideText(hunks, old = true), language)
        newSpans = sideSpans(source, sideText(hunks, old = false), language)
    }
    return DiffFileRender.Parsed(diffFileModel(files.any { it.binary } && hunks.isEmpty(), hunks, oldSpans, newSpans))
}

private suspend fun sideSpans(source: DiffRenderSource, text: String, language: String): List<RenderSpan> {
    if (text.isEmpty() || text.length > MAX_HIGHLIGHT_CHARS) return emptyList()
    return source.highlight(text, language).value.orEmpty()
}

/** The core caps utility text at 64 KiB; bigger sides skip syntax colouring. */
private const val MAX_HIGHLIGHT_CHARS = 60 * 1024

/**
 * One side of the file (old: context + deleted, new: context + added) joined by newlines, so the
 * grammar sees consecutive lines with their surrounding context.
 */
internal fun sideText(hunks: List<DiffHunk>, old: Boolean): String = buildString {
    var first = true
    for (hunk in hunks) for (line in hunk.lines) {
        if (!onSide(line, old)) continue
        if (!first) append('\n')
        append(line.text)
        first = false
    }
}

private fun onSide(line: DiffLine, old: Boolean) = line.kind != "meta" && (if (old) line.old_line != null else line.new_line != null)

internal fun diffFileModel(binary: Boolean, hunks: List<DiffHunk>, oldSpans: List<RenderSpan>, newSpans: List<RenderSpan>): DiffFileModel {
    val old = SideCursor(oldSpans)
    val new = SideCursor(newSpans)
    var maxNumber = 1uL
    val models = hunks.map { hunk ->
        val rows = hunk.lines.map { line ->
            val oldSyntax = if (onSide(line, true)) old.take(line.text) else null
            val newSyntax = if (onSide(line, false)) new.take(line.text) else null
            maxNumber = maxOf(maxNumber, line.old_line ?: 0uL, line.new_line ?: 0uL)
            diffRow(line, (if (line.kind == "delete") oldSyntax else newSyntax ?: oldSyntax).orEmpty())
        }
        DiffHunkModel(hunkHeader(hunk), rows)
    }
    return DiffFileModel(binary, models, maxNumber.toString().length)
}

/** Walks one side's joined text line by line, cutting the (ordered) highlight spans per line. */
private class SideCursor(private val spans: List<RenderSpan>) {
    private var offset = 0uL
    private var next = 0

    /** Byte-relative spans of the next line of this side, which is [text]. */
    fun take(text: String): List<RenderSpan> {
        val start = offset
        val end = start + utf8Size(text).toULong()
        offset = end + 1uL
        if (spans.isEmpty()) return emptyList()
        while (next < spans.size && spans[next].end <= start) next++
        val out = ArrayList<RenderSpan>()
        var i = next
        while (i < spans.size && spans[i].start < end) {
            val span = spans[i]
            val s = maxOf(span.start, start) - start
            val e = minOf(span.end, end) - start
            if (e > s) out.add(RenderSpan(s, e, span.kind))
            i++
        }
        return out
    }
}

private fun utf8Size(text: String): Int {
    var bytes = 0
    var i = 0
    while (i < text.length) {
        val c = text[i]
        bytes += when {
            c.code < 0x80 -> 1
            c.code < 0x800 -> 2
            Character.isHighSurrogate(c) && i + 1 < text.length && Character.isLowSurrogate(text[i + 1]) -> { i++; 4 }
            else -> 3
        }
        i++
    }
    return bytes
}

private fun diffRow(line: DiffLine, syntax: List<RenderSpan>): DiffRow {
    val raw = line.text
    // Tabs become spaces up to the next stop so every row keeps a monospace column grid.
    val display = StringBuilder(raw.length)
    val toDisplay = IntArray(raw.length + 1)
    for (i in raw.indices) {
        toDisplay[i] = display.length
        if (raw[i] == '\t') repeat(TAB_WIDTH - display.length % TAB_WIDTH) { display.append(' ') } else display.append(raw[i])
    }
    toDisplay[raw.length] = display.length
    val bytes = utf8ToUtf16(raw)
    val last = bytes.size - 1
    fun ranges(spans: List<RenderSpan>) = spans.mapNotNull { span ->
        val start = toDisplay[bytes[span.start.coerceAtMost(last.toULong()).toInt()]]
        val end = toDisplay[bytes[span.end.coerceAtMost(last.toULong()).toInt()]]
        if (end > start) DiffRange(start, end, span.kind) else null
    }
    return DiffRow(line.kind, raw, display.toString(), line.old_line, line.new_line, ranges(line.spans), ranges(syntax))
}

/**
 * Plain-text rendering of a file model for golden tests: gutter, sign, text with word spans in
 * ⟦…⟧, then syntax spans as `kind@start-end` (display UTF-16 indices).
 */
internal fun diffGolden(model: DiffFileModel): String = buildString {
    if (model.binary) appendLine("binary")
    for (hunk in model.hunks) {
        appendLine(hunk.header)
        for (row in hunk.rows) {
            append(diffGutter(row, model.numberWidth))
            var text = row.text
            for (w in row.words.sortedByDescending { it.start }) text = text.substring(0, w.start) + "⟦" + text.substring(w.start, w.end) + "⟧" + text.substring(w.end)
            append(text)
            if (row.syntax.isNotEmpty()) append("  | ").append(row.syntax.joinToString(" ") { "${it.kind}@${it.start}-${it.end}" })
            appendLine()
        }
    }
}

/** `old new s ` gutter: right-aligned one-based numbers (blank when absent) and the change sign. */
internal fun diffGutter(row: DiffRow, width: Int): String {
    if (row.kind == "meta") return " ".repeat(width * 2 + 4)
    val sign = when (row.kind) { "add" -> '+'; "delete" -> '-'; else -> ' ' }
    return (row.oldLine?.toString() ?: "").padStart(width) + " " + (row.newLine?.toString() ?: "").padStart(width) + " " + sign + " "
}

/** Card totals from the writer's per-file header counts (web parity). */
internal fun diffTotals(files: List<DiffIndexEntry>): Pair<ULong, ULong> =
    files.fold(0uL to 0uL) { (a, d), f -> (a + f.additions) to (d + f.deletions) }

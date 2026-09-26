package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.verdeai.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal const val DIFF_CARD = "diff-card"
internal const val DIFF_LINES = "diff-lines"
internal const val DIFF_FULL_SCREEN = "diff-full-screen"

/** Files listed before "Show more files"; rows shown per expanded file before "Show more lines". */
internal const val DIFF_FILE_PAGE = 30
internal const val DIFF_INLINE_LINES = 200
internal const val DIFF_MORE_LINES = 400
/** Past this many inline rows only the lazily laid out full-screen view shows the rest. */
internal const val DIFF_INLINE_MAX = 1_200
/** Rows per Text inside an inline hunk, bounding each text layout. */
private const val DIFF_CHUNK_ROWS = 80
/** Clipboard transactions over ~1 MB fail on Android; bigger copies are refused, never truncated. */
internal const val DIFF_MAX_COPY_CHARS = 256 * 1024

/** The D-07 `diff` renderer: registered in [TranscriptRenderers]. */
@Composable
internal fun DiffCard(row: ChatRow, ctx: TranscriptContext) {
    val source = remember(ctx.model) { ctx.model.diffSource() }
    DiffCard(row.id, row.body, source, ctx.onCitation) { entry ->
        ctx.model.composer.commentOnDiff(entry.path, entry.additions, entry.deletions)
    }
}

@Composable
internal fun DiffCard(id: String, body: String, source: DiffRenderSource, onOpenFile: ((FileCitation) -> Unit)? = null, onComment: ((DiffIndexEntry) -> Unit)? = null) {
    val index by produceState(source.cachedIndex(body), body) { value = source.index(body) }
    val diffBody = remember(body) { DiffBody(body) }
    var wrap by rememberSaveable("$id:wrap") { mutableStateOf(false) }
    var fileLimit by rememberSaveable("$id:files") { mutableIntStateOf(DIFF_FILE_PAGE) }
    val colors = MaterialTheme.colorScheme
    val files = index?.value?.files
    Column(Modifier.fillMaxWidth().border(1.dp, colors.outlineVariant, RoundedCornerShape(10.dp))
        .background(colors.surfaceContainerLow, RoundedCornerShape(10.dp)).testTag(DIFF_CARD)) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 8.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (files == null) "Changed files" else "Changed files · ${files.size}", Modifier.weight(1f),
                style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            // One file: its own row already shows the counts.
            if (files != null && files.size > 1) {
                val (added, removed) = remember(files) { diffTotals(files) }
                DiffCounts(added, removed)
            }
            FilterChip(selected = wrap, onClick = { wrap = !wrap }, label = { Text("Wrap lines") })
        }
        HorizontalDivider(color = colors.outlineVariant)
        val note: String? = when {
            index == null -> "Loading changes…"
            files == null -> "This diff couldn't be decoded on the phone."
            files.isEmpty() -> "Diff data is empty or could not be restored."
            else -> null
        }
        if (note != null) Text(note, Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        if (files != null) {
            files.take(fileLimit).forEachIndexed { i, entry ->
                if (i > 0) HorizontalDivider(color = colors.outlineVariant.copy(alpha = 0.5f))
                DiffFileSection("$id:$i", entry, diffBody, source, wrap, defaultExpanded = files.size == 1, onOpenFile, onComment)
            }
            if (files.size > fileLimit) {
                val more = files.size - fileLimit
                TextButton(onClick = { fileLimit += DIFF_FILE_PAGE }, Modifier.padding(horizontal = 4.dp)) {
                    Text("Show ${minOf(more, DIFF_FILE_PAGE)} more files · $more hidden")
                }
            }
        }
    }
}

@Composable
private fun DiffCounts(added: ULong, removed: ULong) {
    val palette = diffPalette()
    Text(buildAnnotatedString {
        withStyle(SpanStyle(color = palette.addSign)) { append("+$added") }
        append(' ')
        withStyle(SpanStyle(color = palette.deleteSign)) { append("−$removed") }
    }, style = MaterialTheme.typography.labelMedium.copy(fontFamily = VerdeMono))
}

@Composable
private fun DiffFileSection(key: String, entry: DiffIndexEntry, body: DiffBody, source: DiffRenderSource, wrap: Boolean, defaultExpanded: Boolean,
                            onOpenFile: ((FileCitation) -> Unit)?, onComment: ((DiffIndexEntry) -> Unit)?) {
    var expanded by rememberSaveable("$key:open") { mutableStateOf(defaultExpanded) }
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().clickable(onClickLabel = if (expanded) "Collapse ${entry.path}" else "Expand ${entry.path}") { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (expanded) "▾" else "▸", color = colors.onSurfaceVariant)
            Text(entry.path, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono),
                maxLines = 1, overflow = TextOverflow.StartEllipsis)
            DiffCounts(entry.additions, entry.deletions)
        }
        if (expanded) DiffFileBody(key, entry, body, source, wrap, onOpenFile, onComment)
    }
}

@Composable
private fun DiffFileBody(key: String, entry: DiffIndexEntry, body: DiffBody, source: DiffRenderSource, wrap: Boolean,
                         onOpenFile: ((FileCitation) -> Unit)?, onComment: ((DiffIndexEntry) -> Unit)?) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val record by produceState<DiffRecord?>(null, entry, body) { value = withContext(Dispatchers.Default) { body.record(entry) } }
    val render by produceState<DiffFileRender?>(null, record) {
        val r = record ?: return@produceState
        value = withContext(Dispatchers.Default) { renderDiffFile(source, r, entry.path) }
    }
    var budget by rememberSaveable("$key:budget") { mutableIntStateOf(DIFF_INLINE_LINES) }
    var fullScreen by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    val patch = record?.patch
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
        if (onComment != null) TextButton(onClick = { onComment(entry) }) { Text("Comment") }
        TextButton(onClick = { clipboard.setText(AnnotatedString(entry.path)) }) { Text("Copy path") }
        val copyable = patch != null && patch.length <= DIFF_MAX_COPY_CHARS
        TextButton(onClick = { if (patch != null) clipboard.setText(AnnotatedString(patch)) }, enabled = copyable) {
            Text(if (patch != null && !copyable) "Patch too large to copy" else "Copy patch")
        }
        val parsed = render as? DiffFileRender.Parsed
        if (parsed != null && parsed.model.hunks.isNotEmpty()) TextButton(onClick = { fullScreen = true }) { Text("Full screen") }
        // D-12: the current file on the host, at the first changed line.
        if (onOpenFile != null && !(parsed?.model?.binary == true && viewerKind(entry.path) == ViewerKind.Text)) TextButton(onClick = {
            onOpenFile(FileCitation(entry.path, parsed?.model?.let(::firstNewLine)))
        }) { Text("Open file") }
    }
    when (val r = render) {
        null -> Text("Rendering…", Modifier.padding(horizontal = 12.dp, vertical = 6.dp), style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant)
        is DiffFileRender.Source -> DiffSourceText(r.patch, budget) { budget += DIFF_MORE_LINES }
        is DiffFileRender.Parsed -> {
            val model = r.model
            when {
                model.binary -> DiffNote("Binary file — not shown.")
                model.hunks.isEmpty() -> DiffNote("No line changes.")
                else -> DiffHunks(key, model, wrap, budget, onMore = {
                    if (budget >= DIFF_INLINE_MAX) fullScreen = true else budget += DIFF_MORE_LINES
                })
            }
            if (fullScreen) DiffFullScreen(entry.path, model, wrap, patch, onClose = { fullScreen = false })
        }
    }
    Spacer(Modifier.height(6.dp))
}

@Composable
private fun DiffNote(text: String) =
    Text(text, Modifier.padding(horizontal = 12.dp, vertical = 6.dp), style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)

/** The core couldn't parse this record (too big or malformed): its source text, never reparsed. */
@Composable
private fun DiffSourceText(patch: String, budget: Int, onMore: () -> Unit) {
    DiffNote("Too large or unusual to render as a diff here; showing the patch text.")
    val (shown, truncated) = remember(patch, budget) { leadingLines(patch, budget) }
    Text(shown, Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp).testTag(DIFF_LINES),
        style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono), softWrap = false)
    if (truncated) TextButton(onClick = onMore, Modifier.padding(horizontal = 4.dp)) { Text("Show more lines") }
}

@Composable
private fun DiffHunks(key: String, model: DiffFileModel, wrap: Boolean, budget: Int, onMore: () -> Unit) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var collapsed by rememberSaveable("$key:collapsed") { mutableStateOf(emptySet<Int>()) }
    val colors = MaterialTheme.colorScheme
    var left = budget
    var hidden = 0
    model.hunks.forEachIndexed { i, hunk ->
        val isCollapsed = i in collapsed
        if (left <= 0) { if (!isCollapsed) hidden += hunk.rows.size; return@forEachIndexed }
        Row(Modifier.fillMaxWidth().background(colors.secondaryContainer.copy(alpha = 0.45f))
            .clickable(onClickLabel = if (isCollapsed) "Expand hunk" else "Collapse hunk") {
                collapsed = if (isCollapsed) collapsed - i else collapsed + i
            }.padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (isCollapsed) "▸" else "▾", color = colors.onSurfaceVariant)
            Text(hunk.header, Modifier.weight(1f).padding(start = 6.dp), style = MaterialTheme.typography.labelSmall.copy(fontFamily = VerdeMono),
                color = colors.onSecondaryContainer, maxLines = 1, overflow = TextOverflow.Ellipsis)
            TextButton(onClick = { clipboard.setText(AnnotatedString(hunkPatch(hunk))) }) { Text("Copy hunk") }
        }
        if (isCollapsed) return@forEachIndexed
        val rows = if (hunk.rows.size <= left) hunk.rows else hunk.rows.subList(0, left)
        hidden += hunk.rows.size - rows.size
        left -= rows.size
        DiffLines(rows, model.numberWidth, wrap)
    }
    if (hidden > 0) TextButton(onClick = onMore, Modifier.padding(horizontal = 4.dp)) {
        Text(if (budget >= DIFF_INLINE_MAX) "Open full screen · $hidden more lines" else "Show more lines · $hidden remaining")
    }
}

internal data class DiffPalette(
    val addLine: Color, val deleteLine: Color, val addWord: Color, val deleteWord: Color,
    val addSign: Color, val deleteSign: Color, val gutter: Color, val meta: Color,
)

@Composable
internal fun diffPalette(): DiffPalette {
    val c = MaterialTheme.colorScheme
    return remember(c) {
        val add = VerdeColors.DiffAdd
        val delete = VerdeColors.Danger
        DiffPalette(add.copy(alpha = 0.08f), delete.copy(alpha = 0.10f), add.copy(alpha = 0.26f), delete.copy(alpha = 0.32f),
            add, delete, c.outline, c.onSurfaceVariant)
    }
}

/** Rows of one Text: its styled string plus each row's [start, end) for line backgrounds. */
internal class DiffChunk(val text: AnnotatedString, val starts: IntArray, val ends: IntArray, val kinds: List<String>)

internal fun diffChunk(rows: List<DiffRow>, width: Int, palette: DiffPalette, syntax: (String) -> SpanStyle?): DiffChunk {
    val starts = IntArray(rows.size)
    val ends = IntArray(rows.size)
    val text = buildAnnotatedString {
        rows.forEachIndexed { i, row ->
            if (i > 0) append('\n')
            starts[i] = length
            withStyle(SpanStyle(color = when (row.kind) { "add" -> palette.addSign; "delete" -> palette.deleteSign; else -> palette.gutter })) {
                append(diffGutter(row, width))
            }
            val base = length
            if (row.kind == "meta") withStyle(SpanStyle(color = palette.meta, fontStyle = FontStyle.Italic)) { append(row.text) }
            else append(row.text)
            for (s in row.syntax) syntax(s.kind)?.let { addStyle(it, base + s.start, base + s.end) }
            for (w in row.words) addStyle(SpanStyle(background = if (w.kind == "delete") palette.deleteWord else palette.addWord), base + w.start, base + w.end)
            ends[i] = length
        }
    }
    return DiffChunk(text, starts, ends, rows.map { it.kind })
}

@Composable
private fun diffTextStyle() = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono)

/** Chunked rows of one hunk: scrolled horizontally together, or wrapped under a hanging gutter. */
@Composable
private fun DiffLines(rows: List<DiffRow>, width: Int, wrap: Boolean) {
    val palette = diffPalette()
    val syntax = tokenStyle()
    val chunks = remember(rows, width, palette, syntax) { rows.chunked(DIFF_CHUNK_ROWS).map { diffChunk(it, width, palette, syntax) } }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val column = if (wrap) Modifier.fillMaxWidth()
        else Modifier.horizontalScroll(rememberScrollState()).widthIn(min = maxWidth).width(IntrinsicSize.Max)
        Column(column.testTag(DIFF_LINES)) { chunks.forEach { DiffChunkText(it, width, wrap, palette, Modifier.fillMaxWidth()) } }
    }
}

@Composable
private fun DiffChunkText(chunk: DiffChunk, width: Int, wrap: Boolean, palette: DiffPalette, modifier: Modifier) {
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val style = diffTextStyle()
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    // Wrapped continuation lines hang under the text column, not under the gutter.
    val indented = remember(chunk, wrap, style, density) {
        if (!wrap) chunk.text else {
            val gutter = with(density) { measurer.measure(" ".repeat(width * 2 + 4), style).size.width.toSp() }
            AnnotatedString.Builder(chunk.text).apply {
                addStyle(ParagraphStyle(textIndent = TextIndent(restLine = gutter)), 0, chunk.text.length)
            }.toAnnotatedString()
        }
    }
    Text(indented, modifier.drawBehind {
        val l = layout ?: return@drawBehind
        for (i in chunk.kinds.indices) {
            val color = when (chunk.kinds[i]) { "add" -> palette.addLine; "delete" -> palette.deleteLine; else -> continue }
            if (chunk.starts[i] > l.layoutInput.text.length) break
            val top = l.getLineTop(l.getLineForOffset(chunk.starts[i]))
            val bottom = l.getLineBottom(l.getLineForOffset(maxOf(chunk.starts[i], chunk.ends[i] - 1)))
            drawRect(color, Offset(0f, top), Size(size.width, bottom - top))
        }
    }.padding(horizontal = 8.dp), style = style, softWrap = wrap, onTextLayout = { layout = it })
}

private sealed interface DiffScreenItem {
    data class Header(val hunk: Int) : DiffScreenItem
    data class Line(val hunk: Int, val row: Int) : DiffScreenItem
}

/** Whole-file view: a LazyColumn of rows, so even 4,096-line patches lay out only what's visible. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DiffFullScreen(path: String, model: DiffFileModel, initialWrap: Boolean, patch: String?, onClose: () -> Unit) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var wrap by remember { mutableStateOf(initialWrap) }
    val palette = diffPalette()
    val syntax = tokenStyle()
    val style = diffTextStyle()
    val colors = MaterialTheme.colorScheme
    val items = remember(model) {
        buildList {
            model.hunks.forEachIndexed { h, hunk ->
                add(DiffScreenItem.Header(h))
                hunk.rows.indices.forEach { add(DiffScreenItem.Line(h, it)) }
            }
        }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().testTag(DIFF_FULL_SCREEN)) {
            Column {
                VerdeTopBar(showWorkspaceMenu = false,
                    title = { Text(path, maxLines = 1, overflow = TextOverflow.StartEllipsis, style = MaterialTheme.typography.titleSmall) },
                    navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.Filled.Close, contentDescription = "Close diff") } },
                    actions = {
                        FilterChip(selected = wrap, onClick = { wrap = !wrap }, label = { Text("Wrap lines") })
                        TextButton(onClick = { if (patch != null) clipboard.setText(AnnotatedString(patch)) },
                            enabled = patch != null && patch.length <= DIFF_MAX_COPY_CHARS) { Text("Copy patch") }
                    })
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val measurer = rememberTextMeasurer()
                    val density = LocalDensity.current
                    // Monospace rows: the widest few (by length) bound the scrollable content width.
                    val contentWidth = remember(model, style, density) {
                        val widest = model.hunks.flatMap { it.rows }.sortedByDescending { it.text.length }.take(4)
                        val px = widest.maxOfOrNull { measurer.measure(diffGutter(it, model.numberWidth) + it.text, style, softWrap = false).size.width } ?: 0
                        with(density) { px.toDp() } + 16.dp
                    }
                    val list = if (wrap) Modifier.fillMaxSize()
                    else Modifier.horizontalScroll(rememberScrollState()).width(maxOf(maxWidth, contentWidth)).fillMaxHeight()
                    LazyColumn(list) {
                        items(items, key = { if (it is DiffScreenItem.Line) "l${it.hunk}:${it.row}" else "h${(it as DiffScreenItem.Header).hunk}" },
                            contentType = { it::class }) { item ->
                            when (item) {
                                is DiffScreenItem.Header -> Text(model.hunks[item.hunk].header,
                                    Modifier.fillMaxWidth().background(colors.secondaryContainer.copy(alpha = 0.45f)).padding(horizontal = 8.dp, vertical = 4.dp),
                                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = VerdeMono), color = colors.onSecondaryContainer)
                                is DiffScreenItem.Line -> {
                                    val row = model.hunks[item.hunk].rows[item.row]
                                    val chunk = remember(row, palette, syntax) { diffChunk(listOf(row), model.numberWidth, palette, syntax) }
                                    DiffChunkText(chunk, model.numberWidth, wrap, palette, Modifier.fillMaxWidth())
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** First line of the new file that a hunk touches, for opening the file at the change. */
internal fun firstNewLine(model: DiffFileModel): ULong? {
    val rows = model.hunks.asSequence().flatMap { it.rows }
    return rows.firstOrNull { it.kind == "add" && it.newLine != null }?.newLine ?: rows.firstNotNullOfOrNull { it.newLine }
}

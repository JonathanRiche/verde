package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatRow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.runtime.withFrameNanos
import kotlin.math.abs

/*
 * Tool rows (desktop ToolRow parity, shared spec S2): per-kind icon, title, one-line mono summary,
 * status icon + colour, chevron. The whole row toggles; the expanded body has labelled Input /
 * Output / Error sections and the row's only Copy button.
 */

internal enum class ToolKind { Read, Edit, Delete, Move, Search, Execute, Think, Fetch, Mcp, Subagent, Other }

/** The core's kind tag, else what the row's author and body say (legacy rows). */
internal fun toolKind(row: ChatRow): ToolKind {
    val tag = row.tool?.kind
    if (tag != null) return when (tag) {
        "read" -> ToolKind.Read
        "edit" -> ToolKind.Edit
        "delete" -> ToolKind.Delete
        "move" -> ToolKind.Move
        "search" -> ToolKind.Search
        "execute" -> ToolKind.Execute
        "think" -> ToolKind.Think
        "fetch" -> ToolKind.Fetch
        "mcp" -> ToolKind.Mcp
        "subagent" -> ToolKind.Subagent
        else -> ToolKind.Other
    }
    if (isSubagentRow(row)) return ToolKind.Subagent
    return when (row.author.trim().lowercase()) {
        "ran command", "command failed", "bash", "shell", "run" -> ToolKind.Execute
        "read", "read file" -> ToolKind.Read
        "edit", "write", "multiedit" -> ToolKind.Edit
        "delete" -> ToolKind.Delete
        "move" -> ToolKind.Move
        "search", "grep", "glob", "find" -> ToolKind.Search
        "fetch", "webfetch", "web fetch" -> ToolKind.Fetch
        else -> if (isCommandRow(row) && row.tool == null) ToolKind.Execute else ToolKind.Other
    }
}

/** What a tool row shows: the core's parsed fields when present, else the row's author and body. */
internal data class ToolDisplay(
    val kind: ToolKind,
    val title: String,
    val summary: String?,
    val input: String?,
    val output: String?,
    val error: String?,
) {
    /** True when the core supplied sections; legacy rows show their body as one block. */
    val sectioned get() = input != null || output != null || error != null
}

internal fun toolDisplay(row: ChatRow): ToolDisplay {
    val tool = row.tool
    val kind = toolKind(row)
    val title = tool?.title?.takeIf { it.isNotBlank() } ?: row.author.ifBlank { "Tool" }
    val summary = tool?.summary?.takeIf { it.isNotBlank() } ?: firstBodyLine(row.body)?.takeIf { it != title }
    return ToolDisplay(kind, title, summary, tool?.input, tool?.output, tool?.error)
}

private val SECTION_LABELS = setOf("Tool:", "Input:", "Output:", "Error:", "Locations:", "Transcript:")

/** The body's first meaningful line, skipping section labels ("Tool:", "Input:", …); bounded for huge bodies. */
internal fun firstBodyLine(body: String, max: Int = 240): String? =
    body.take(4_000).lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() && it !in SECTION_LABELS }
        ?.let { if (it.length > max) it.take(max - 1) + "…" else it }

/** TalkBack: "status, title, summary". */
internal fun toolRowLabel(display: ToolDisplay, row: ChatRow): String =
    listOfNotNull(toolStatusLabel(row), display.title, display.summary).joinToString(", ")

/** What Copy puts on the clipboard: the output when there is one, else the raw body. */
internal fun toolCopyText(display: ToolDisplay, row: ChatRow): String =
    display.output ?: display.error ?: display.input ?: row.body

internal fun toolStatusLabel(row: ChatRow) = when {
    commandFailed(row) -> "Failed"
    commandRunning(row) -> "Running"
    else -> "Completed"
}

/** A unified diff (Edit output): hunk headers or +/- lines after file headers. */
internal fun looksLikeDiff(text: String): Boolean {
    var hunks = 0
    var signs = 0
    for (line in text.lineSequence().take(400)) {
        if (line.startsWith("@@")) hunks++
        else if ((line.startsWith("+") && !line.startsWith("+++")) || (line.startsWith("-") && !line.startsWith("---"))) signs++
    }
    return hunks > 0 || (signs > 0 && text.lineSequence().any { it.startsWith("--- ") || it.startsWith("+++ ") })
}

internal enum class DiffLineKind { Add, Delete, Hunk, Meta, Context }

internal fun diffLineKind(line: String): DiffLineKind = when {
    line.startsWith("@@") -> DiffLineKind.Hunk
    line.startsWith("+++") || line.startsWith("---") || line.startsWith("diff ") || line.startsWith("index ") -> DiffLineKind.Meta
    line.startsWith("+") -> DiffLineKind.Add
    line.startsWith("-") -> DiffLineKind.Delete
    else -> DiffLineKind.Context
}

@Composable
internal fun toolKindPainter(kind: ToolKind): Painter = when (kind) {
    ToolKind.Read -> painterResource(R.drawable.ic_tool_file)
    ToolKind.Edit -> rememberVectorPainter(Icons.Filled.Edit)
    ToolKind.Delete -> rememberVectorPainter(Icons.Filled.Delete)
    ToolKind.Move -> rememberVectorPainter(Icons.AutoMirrored.Filled.ArrowForward)
    ToolKind.Search -> rememberVectorPainter(Icons.Filled.Search)
    ToolKind.Execute -> painterResource(R.drawable.ic_tool_terminal)
    ToolKind.Think -> painterResource(R.drawable.ic_tool_think)
    ToolKind.Fetch -> painterResource(R.drawable.ic_tool_globe)
    ToolKind.Mcp -> painterResource(R.drawable.ic_tool_plug)
    ToolKind.Subagent -> painterResource(R.drawable.ic_tool_people)
    ToolKind.Other -> rememberVectorPainter(Icons.Filled.Build)
}

// ---- Disclosure anchoring ----

/**
 * Keeps a tapped disclosure header where it was while its content grows or shrinks, so expanding
 * or collapsing never moves the reading position (the reversed transcript would otherwise re-anchor
 * on its bottom item and jump).
 */
internal class DisclosureAnchor(private val list: LazyListState, private val scope: CoroutineScope) {
    /** [item] is the toggled row's list index at the time of the tap (its header sits inside it). */
    fun toggle(header: () -> LayoutCoordinates?, item: Int?, change: () -> Unit) {
        val before = header()?.takeIf { it.isAttached }?.positionInWindow()?.y
        // The item's top edge, in the reversed list's logical offsets (from the bottom).
        val beforeTop = item?.let { i -> list.layoutInfo.visibleItemsInfo.find { it.index == i }?.let { it.offset + it.size } }
        change()
        if (before == null) return
        scope.launch {
            // Two frames to recompose and lay out the new height, then put the header back.
            withFrameNanos { }
            withFrameNanos { }
            // A row the list no longer places can keep stale coordinates: trust them only while placed.
            val placed = item == null || list.layoutInfo.visibleItemsInfo.any { it.index == item }
            val after = if (placed) header()?.takeIf { it.isAttached }?.positionInWindow()?.y else null
            if (after != null) {
                val delta = after - before
                // Reversed layout: a forward scroll moves content down the screen.
                if (abs(delta) > 0.5f) list.scrollBy(-delta)
                return@launch
            }
            // A big item that shrank re-anchors the reversed list past itself and its header is
            // disposed: bring the item back to the bottom edge, then put its top where it was.
            if (item == null || beforeTop == null) return@launch
            list.scrollToItem(item, 0)
            withFrameNanos { }
            val info = list.layoutInfo.visibleItemsInfo.find { it.index == item } ?: return@launch
            val shift = (info.offset + info.size) - beforeTop
            if (shift != 0) list.scrollBy(shift.toFloat())
        }
    }
}

internal val LocalDisclosureAnchor = staticCompositionLocalOf<DisclosureAnchor?> { null }
/** The transcript list index of the item being composed, for [DisclosureAnchor]. */
internal val LocalTranscriptIndex = compositionLocalOf<Int?> { null }

/** Expanded state for one disclosure whose toggle keeps [header] in place. */
internal class Disclosure(private val state: MutableState<Boolean>, private val anchor: DisclosureAnchor?) {
    var header: LayoutCoordinates? = null
    var index: Int? = null
    val expanded get() = state.value
    fun toggle() {
        val flip = { state.value = !state.value }
        anchor?.toggle({ header }, index, flip) ?: flip()
    }
    val track: Modifier get() = Modifier.onGloballyPositioned { header = it }
}

/**
 * Expanded / collapsed choices for one transcript, kept outside its rows. A lazy row that shrinks
 * past the list's anchor is disposed and recreated, and its own saved state could come back at
 * the default (A5-1: a failed group sprang open again on every collapse).
 */
internal class DisclosureStore(initial: Map<String, Boolean> = emptyMap()) {
    val choices = androidx.compose.runtime.snapshots.SnapshotStateMap<String, Boolean>().apply { putAll(initial) }
    fun state(key: String, initial: Boolean): MutableState<Boolean> = object : MutableState<Boolean> {
        override var value: Boolean
            get() = choices[key] ?: initial
            set(v) { choices[key] = v }
        override fun component1() = value
        override fun component2(): (Boolean) -> Unit = { value = it }
    }

    companion object {
        val Saver = androidx.compose.runtime.saveable.Saver<DisclosureStore, HashMap<String, Boolean>>(
            save = { HashMap(it.choices) }, restore = { DisclosureStore(it) })
    }
}

internal val LocalDisclosureStore = staticCompositionLocalOf<DisclosureStore?> { null }

@Composable
internal fun rememberDisclosure(key: String, initial: Boolean): Disclosure {
    val store = LocalDisclosureStore.current
    val state = if (store != null) remember(store, key) { store.state(key, initial) } else rememberSaveable(key) { mutableStateOf(initial) }
    val anchor = LocalDisclosureAnchor.current
    val index = LocalTranscriptIndex.current
    return remember(state, anchor) { Disclosure(state, anchor) }.also { it.index = index }
}

// ---- Rows ----

private const val TOOL_PREVIEW_LINES = 40

@Composable
private fun ToolStatusIcon(row: ChatRow) {
    val colors = MaterialTheme.colorScheme
    Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
        when {
            commandRunning(row) -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.primary)
            commandFailed(row) -> Icon(Icons.Filled.Close, contentDescription = null, tint = colors.error, modifier = Modifier.size(18.dp))
            else -> Icon(Icons.Filled.Check, contentDescription = null, tint = colors.primary, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
internal fun Chevron(expanded: Boolean, modifier: Modifier = Modifier) {
    Icon(Icons.Filled.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.size(20.dp).rotate(if (expanded) 90f else 0f))
}

@Composable
internal fun CopyIconButton(label: String, text: () -> String) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    IconButton(onClick = { clipboard.setText(AnnotatedString(text())) }) {
        Icon(painterResource(R.drawable.ic_copy), contentDescription = label, tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp))
    }
}

/** One tool call: a single outlined card on its own, or a flat row inside a group. */
@Composable
internal fun ToolRow(row: ChatRow, child: Boolean) {
    val display = remember(row) { toolDisplay(row) }
    val disclosure = rememberDisclosure("tool:" + row.id, commandFailed(row))
    val colors = MaterialTheme.colorScheme
    val failed = commandFailed(row)
    val shape = RoundedCornerShape(10.dp)
    val frame = when {
        !child -> Modifier.border(1.dp, if (failed) colors.error else colors.outlineVariant, shape).background(colors.surfaceContainerLow, shape)
        failed -> Modifier.border(1.dp, colors.error, shape)
        else -> Modifier
    }
    Column(Modifier.fillMaxWidth().then(frame)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).then(disclosure.track)
            .clickable(role = Role.Button, onClickLabel = if (disclosure.expanded) "Collapse" else "Expand") { disclosure.toggle() }
            .semantics(mergeDescendants = true) {
                contentDescription = toolRowLabel(display, row)
                stateDescription = if (disclosure.expanded) "Expanded" else "Collapsed"
            }
            .padding(start = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(toolKindPainter(display.kind), contentDescription = null, tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
            Text(display.title, Modifier.widthIn(max = 160.dp), style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(display.summary.orEmpty(), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono),
                maxLines = 1, overflow = TextOverflow.Ellipsis, color = colors.onSurfaceVariant)
            ToolStatusIcon(row)
            if (disclosure.expanded) CopyIconButton("Copy output") { toolCopyText(display, row) }
            else Spacer(Modifier.width(4.dp))
            Chevron(disclosure.expanded, Modifier.padding(end = 8.dp))
        }
        if (disclosure.expanded) ToolBody(row, display)
    }
}

@Composable
private fun ToolBody(row: ChatRow, display: ToolDisplay) {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!display.sectioned) ToolSection(null, row.body, row.id + ":body", diff = false, error = false)
        else {
            display.input?.let { ToolSection("Input", it, row.id + ":input", diff = false, error = false) }
            display.output?.let { ToolSection("Output", it, row.id + ":output", diff = display.kind == ToolKind.Edit && looksLikeDiff(it), error = false) }
            display.error?.let { ToolSection("Error", it, row.id + ":error", diff = false, error = true) }
        }
        if (!display.sectioned && row.body.isBlank()) Text("No output", style = MaterialTheme.typography.bodySmall, color = colors.outline)
    }
}

@Composable
private fun ToolSection(label: String?, text: String, key: String, diff: Boolean, error: Boolean) {
    val colors = MaterialTheme.colorScheme
    var all by rememberSaveable(key) { mutableStateOf(false) }
    val total = remember(text) { countLines(text) }
    val (shown, truncated) = remember(text, all) { if (all) text.trim() to false else leadingLines(text, TOOL_PREVIEW_LINES) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (label != null) Text(label, style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
            color = if (error) colors.error else colors.onSurfaceVariant)
        val shape = RoundedCornerShape(7.dp)
        Box(Modifier.fillMaxWidth().background(colors.surfaceVariant.copy(alpha = .5f), shape).padding(vertical = 8.dp)) {
            SelectionContainer {
                if (diff) DiffOutput(shown)
                else Text(shown, Modifier.fillMaxWidth().padding(horizontal = 10.dp),
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono),
                    color = if (error) colors.error else colors.onSurface, softWrap = true)
            }
        }
        if (truncated) TextButton(onClick = { all = true }) { Text("Show all $total lines") }
    }
}

/** Unified-diff output in the patch view's added / removed / hunk palette. */
@Composable
private fun DiffOutput(text: String) {
    val palette = diffPalette()
    val colors = MaterialTheme.colorScheme
    val hunk = colors.secondaryContainer.copy(alpha = 0.45f)
    val lines = remember(text) { text.split('\n') }
    val kinds = remember(lines) { lines.map(::diffLineKind) }
    val styled = remember(lines, kinds, palette) {
        buildAnnotatedString {
            lines.forEachIndexed { i, line ->
                if (i > 0) append('\n')
                val color = when (kinds[i]) {
                    DiffLineKind.Add -> palette.addSign
                    DiffLineKind.Delete -> palette.deleteSign
                    DiffLineKind.Hunk, DiffLineKind.Meta -> palette.meta
                    DiffLineKind.Context -> Color.Unspecified
                }
                if (color == Color.Unspecified) append(line) else withStyle(SpanStyle(color = color)) { append(line) }
            }
        }
    }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    Text(styled, Modifier.horizontalScroll(rememberScrollState()).drawBehind {
        val l = layout ?: return@drawBehind
        var offset = 0
        lines.forEachIndexed { i, line ->
            val fill = when (kinds[i]) {
                DiffLineKind.Add -> palette.addLine
                DiffLineKind.Delete -> palette.deleteLine
                DiffLineKind.Hunk -> hunk
                else -> null
            }
            if (fill != null && offset <= l.layoutInput.text.length) {
                val n = l.getLineForOffset(offset.coerceAtMost(l.layoutInput.text.length))
                drawRect(fill, Offset(0f, l.getLineTop(n)), Size(size.width, l.getLineBottom(n) - l.getLineTop(n)))
            }
            offset += line.length + 1
        }
    }.padding(horizontal = 10.dp), style = diffTextStyle(), softWrap = false, onTextLayout = { layout = it })
}

/** Two or more tool calls (or subagents): one outline, a summary header, flat child rows. */
@Composable
internal fun ToolGroupCard(item: TranscriptItem.ToolGroup, ctx: TranscriptContext) {
    val counts = remember(item.rows) { toolCounts(item.rows) }
    val disclosure = rememberDisclosure(item.key, counts.failed > 0)
    val colors = MaterialTheme.colorScheme
    val elapsed = ctx.turnStartedAt?.let { elapsedLabel(it, ctx.now) }
    val summary = toolGroupSummary(item.rows, item.subagent, elapsed)
    val kinds = remember(item.rows) { item.rows.map(::toolKind).distinct().take(3) }
    val shape = RoundedCornerShape(10.dp)
    Column(Modifier.fillMaxWidth().border(1.dp, colors.outlineVariant, shape).background(colors.surfaceContainerLow, shape)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).then(disclosure.track)
            .clickable(role = Role.Button, onClickLabel = if (disclosure.expanded) "Collapse" else "Expand") { disclosure.toggle() }
            .semantics(mergeDescendants = true) {
                contentDescription = summary
                stateDescription = if (disclosure.expanded) "Expanded" else "Collapsed"
            }
            .padding(start = 12.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
                kinds.forEach { Icon(toolKindPainter(it), contentDescription = null, tint = colors.onSurfaceVariant, modifier = Modifier.size(16.dp)) }
            }
            Text(summary, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
                color = if (counts.failed > 0) colors.error else colors.onSurfaceVariant)
            if (counts.running > 0) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.primary)
            Chevron(disclosure.expanded)
        }
        if (disclosure.expanded) Column(Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, bottom = 4.dp)) {
            item.rows.forEachIndexed { index, row ->
                if (index > 0 && !commandFailed(row) && !commandFailed(item.rows[index - 1]))
                    HorizontalDivider(Modifier.padding(horizontal = 8.dp), thickness = 1.dp, color = colors.outlineVariant.copy(alpha = .6f))
                ToolRow(row, child = true)
            }
        }
    }
}


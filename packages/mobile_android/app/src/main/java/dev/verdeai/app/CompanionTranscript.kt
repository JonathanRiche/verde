package dev.verdeai.app

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatRow

/*
 * Dense transcript rows for the companion sheet only; the full chat screen keeps its cards.
 * User messages are compact bubbles, tool calls single muted lines that expand on tap, and the
 * working indicator a small inline row.
 */

internal val CompactTranscriptRenderers = TranscriptRenderers.Default.copy(
    message = { item, ctx -> CompactMessageRow(item.row, ctx) },
    tool = { item, _ -> CompactToolRow(item.row) },
    toolGroup = { item, ctx -> CompactToolGroupRow(item, ctx) },
    working = { item, ctx -> CompactWorkingRow(item, ctx) },
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CompactMessageRow(row: ChatRow, ctx: TranscriptContext) {
    // Attachments and parent-agent steers keep the full renderer (rare in the companion chat).
    if (row.attachments.isNotEmpty() || parentSteerBody(row.role, row.body) != null) return MessageRow(row, ctx)
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var menu by remember { mutableStateOf(false) }
    val delivery = deliveryLabel(row.delivery)
    if (row.role == "user") {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            Column(Modifier.align(Alignment.CenterEnd).widthIn(max = maxWidth * .8f)
                .background(VerdeColors.UserBubble, RoundedCornerShape(12.dp))
                .combinedClickable(onClick = {}, onLongClickLabel = "Copy message", onLongClick = { menu = true })
                .padding(horizontal = 10.dp, vertical = 8.dp), horizontalAlignment = Alignment.End) {
                Text(row.body, style = MaterialTheme.typography.bodyMedium)
                delivery?.let { Text(it, style = MaterialTheme.typography.labelSmall,
                    color = if (row.delivery == "failed") MaterialTheme.colorScheme.error else VerdeColors.Subtle) }
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Copy message") }, onClick = { menu = false; clipboard.setText(AnnotatedString(row.body)) })
            }
        }
        return
    }
    Box(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClickLabel = "Copy message", onLongClick = { menu = true })
            .padding(horizontal = 2.dp, vertical = 2.dp)) {
            if (row.body.isNotEmpty()) MarkdownText(streamTail(row), ctx.model, ctx.onCitation)
            delivery?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle) }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Copy message") }, onClick = { menu = false; clipboard.setText(AnnotatedString(row.body)) })
        }
    }
}

@Composable
private fun compactToolColor(row: ChatRow) = when {
    commandFailed(row) -> MaterialTheme.colorScheme.error
    commandRunning(row) -> MaterialTheme.colorScheme.primary
    else -> VerdeColors.Subtle
}

/** One muted line: status dot, tool name and the command preview; tap shows the output. */
@Composable
internal fun CompactToolRow(row: ChatRow, indent: Boolean = false) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var expanded by rememberSaveable(row.id) { mutableStateOf(commandFailed(row)) }
    Column(Modifier.fillMaxWidth().padding(start = if (indent) 12.dp else 0.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .clickable(onClickLabel = if (expanded) "Hide output" else "Show output") { expanded = !expanded }
            .padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            StatusPip(compactToolColor(row), toolStatusLabel(row), commandRunning(row), size = 6.dp, command = true)
            Text(row.author.ifEmpty { "Tool" }, style = MaterialTheme.typography.labelMedium, color = VerdeColors.Muted, maxLines = 1)
            Text(commandPreview(row.body), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono),
                color = VerdeColors.Subtle, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (expanded) {
            val (shown, truncated) = remember(row.body) { leadingLines(row.body, COMPACT_OUTPUT_LINES) }
            Text(shown, Modifier.fillMaxWidth().background(VerdeColors.Panel, RoundedCornerShape(8.dp)).padding(8.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono), color = VerdeColors.Muted)
            Row {
                if (truncated) Text("Showing the first $COMPACT_OUTPUT_LINES lines", Modifier.weight(1f).align(Alignment.CenterVertically),
                    style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
                TextButton(onClick = { clipboard.setText(AnnotatedString(row.body)) }) { Text("Copy output", style = MaterialTheme.typography.labelSmall) }
            }
        }
    }
}

private const val COMPACT_OUTPUT_LINES = 20

@Composable
private fun CompactToolGroupRow(item: TranscriptItem.ToolGroup, ctx: TranscriptContext) {
    val counts = remember(item.rows) { toolCounts(item.rows) }
    var expanded by rememberSaveable(item.key) { mutableStateOf(counts.failed > 0) }
    val elapsed = ctx.turnStartedAt?.let { elapsedLabel(it, ctx.now) }
    val color = when { counts.failed > 0 -> MaterialTheme.colorScheme.error; counts.running > 0 -> MaterialTheme.colorScheme.primary; else -> VerdeColors.Subtle }
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .clickable(onClickLabel = if (expanded) "Collapse" else "Expand") { expanded = !expanded }.padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            StatusPip(color, if (counts.failed > 0) "Some failed" else if (counts.running > 0) "Running" else "Completed",
                active = counts.running > 0 && counts.failed == 0, size = 6.dp, command = true)
            Text(toolGroupSummary(item.rows, item.subagent, elapsed), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                color = VerdeColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (expanded) "▾" else "▸", color = VerdeColors.Subtle)
        }
        if (expanded) item.rows.forEach { CompactToolRow(it, indent = true) }
    }
}

@Composable
private fun CompactWorkingRow(item: TranscriptItem.Working, ctx: TranscriptContext) {
    val elapsed = item.turn.started_at_ms?.let { elapsedLabel(it, ctx.now) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        StatusPip(active = true, size = 6.dp, command = true)
        Text(workingLabel(item, elapsed), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
    }
}

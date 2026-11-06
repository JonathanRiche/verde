package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatBackground
import dev.verdeai.core.ChatBackgroundTask
import dev.verdeai.core.ChatRow

/**
 * U1: background commands render like the desktop: one compact line each (terminal icon, the
 * label in mono, a status glyph + word, the age), finished ones next to each other as one list.
 * A tap shows the whole command with Copy. The core's task ID / log / PID / stop lines never show.
 */

internal fun backgroundStatusLabel(status: String) = when (status) {
    "running" -> "Running"
    "completed" -> "Finished"
    "failed" -> "Failed"
    "stopped" -> "Stopped"
    else -> status.replaceFirstChar { it.uppercase() }
}

/** The line's age: when it finished, else when it started. */
internal fun backgroundAge(task: ChatBackground, nowMs: Long): String? =
    (task.finished_at_ms ?: task.started_at_ms)?.let { agoLabel(it, nowMs) }

/** "2 background tasks running". */
internal fun runningTasksLabel(count: Int) = "$count background task${if (count == 1) "" else "s"} running"

@Composable
internal fun BackgroundTaskCard(item: TranscriptItem.Background, ctx: TranscriptContext) {
    val colors = MaterialTheme.colorScheme
    val shape = RoundedCornerShape(10.dp)
    Column(Modifier.fillMaxWidth().border(1.dp, colors.outlineVariant, shape).background(colors.surfaceContainerLow, shape)
        .padding(vertical = 2.dp)) {
        item.rows.forEach { row -> row.background?.let { BackgroundLine(row, it, ctx.now) } }
    }
}

@Composable
private fun BackgroundLine(row: ChatRow, task: ChatBackground, now: Long) {
    val colors = MaterialTheme.colorScheme
    val disclosure = rememberDisclosure("bg:" + row.id, false)
    val status = backgroundStatusLabel(task.status)
    val age = backgroundAge(task, now)
    val tint = when (task.status) {
        "running", "completed" -> colors.primary
        "failed" -> colors.error
        else -> VerdeColors.Muted
    }
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).then(disclosure.track)
            .clickable(role = Role.Button, onClickLabel = if (disclosure.expanded) "Hide command" else "Show command") { disclosure.toggle() }
            .nameOnly(listOfNotNull("Background command: ${task.label}", status, age).joinToString(", "),
                state = if (disclosure.expanded) "Expanded" else "Collapsed")
            .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(painterResource(R.drawable.ic_tool_terminal), contentDescription = null, tint = colors.onSurfaceVariant,
                modifier = Modifier.size(16.dp))
            Text(task.label, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium.copy(fontFamily = VerdeMono),
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            StatusGlyph(task.status, tint)
            Text(status, style = MaterialTheme.typography.labelSmall, color = tint, maxLines = 1)
            age?.let { Text("· $it", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle, maxLines = 1) }
        }
        if (disclosure.expanded && row.body.isNotBlank()) Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, bottom = 8.dp),
            verticalAlignment = Alignment.Top) {
            SelectionContainer(Modifier.weight(1f).padding(top = 4.dp)) {
                Text(row.body, style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono), color = colors.onSurface)
            }
            CopyIconButton("Copy command") { row.body }
        }
    }
}

@Composable
private fun StatusGlyph(status: String, tint: Color) {
    when (status) {
        "running" -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = tint, trackColor = tint.copy(alpha = .2f))
        "completed" -> Icon(Icons.Filled.Check, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        "failed" -> Icon(Icons.Filled.Close, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        else -> Box(Modifier.size(8.dp).background(tint, RoundedCornerShape(1.dp)))
    }
}

/**
 * Running background tasks pinned above the composer: "2 background tasks running" and their
 * labels; a tap scrolls to the first one's row. The phone has no stop action.
 */
@Composable
internal fun RunningTasksBar(tasks: List<ChatBackgroundTask>, onJump: (String) -> Unit) {
    if (tasks.isEmpty()) return
    val colors = MaterialTheme.colorScheme
    val title = runningTasksLabel(tasks.size)
    val labels = tasks.joinToString(" · ") { it.label }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).background(VerdeColors.Panel)
        .clickable(role = Role.Button, onClickLabel = "Show") { onJump(tasks.first().row_id) }
        .nameOnly("$title: $labels").padding(horizontal = 16.dp).testTag(RUNNING_TASKS_BAR),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.primary, trackColor = colors.primary.copy(alpha = .2f))
        Text(title, style = MaterialTheme.typography.labelMedium, color = colors.onSurface, maxLines = 1)
        Text(labels, Modifier.weight(1f), style = MaterialTheme.typography.labelSmall.copy(fontFamily = VerdeMono),
            color = VerdeColors.Subtle, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

internal const val RUNNING_TASKS_BAR = "running-tasks-bar"

/** A one-shot scroll request for the transcript list (by row id). */
internal class TranscriptJump {
    var target by mutableStateOf<String?>(null)
}

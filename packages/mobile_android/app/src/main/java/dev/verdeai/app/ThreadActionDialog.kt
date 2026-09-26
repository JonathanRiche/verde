package dev.verdeai.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.verdeai.core.ThreadSummary

/** Each confirmation owns one intent; uncertain outcomes are never silently replayed. */
@Composable
internal fun ThreadActionDialog(thread: ThreadSummary, action: String, model: ManageModel,
    onDismiss: () -> Unit, onClosed: () -> Unit) {
    var title by rememberSaveable { mutableStateOf(thread.title) }
    var intent by rememberSaveable { mutableStateOf<String?>(null) }
    val state by model.state.collectAsState()
    val result = outcome(state, intent)
    val pending = result is JobOutcome.Pending
    val label = when (action) { "rename" -> "Rename chat"; "close" -> "Close chat"; else -> "Sync thread" }
    LaunchedEffect(result) {
        if (result is JobOutcome.Done) { if (action == "close") onClosed() else onDismiss() }
    }
    Dialog(onDismissRequest = { if (!pending) onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(modifier = Modifier.fillMaxWidth(.9f).widthIn(max = 400.dp),
            color = VerdeColors.Panel, shape = MaterialTheme.shapes.large,
            border = BorderStroke(1.dp, VerdeColors.Border)) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(label, style = MaterialTheme.typography.titleMedium)
                if (action == "rename") {
                    Text("Chat title", style = MaterialTheme.typography.labelMedium)
                    Surface(color = VerdeColors.PanelAlt, shape = MaterialTheme.shapes.small,
                        border = BorderStroke(1.dp, VerdeColors.Border)) {
                        BasicTextField(title, { title = it }, enabled = !pending, singleLine = true,
                            textStyle = MaterialTheme.typography.bodyLarge.copy(color = VerdeColors.Text),
                            cursorBrush = SolidColor(VerdeColors.Accent),
                            modifier = Modifier.fillMaxWidth().padding(12.dp).testTag("thread-rename-title")
                                .semantics { contentDescription = "Chat title" })
                    }
                } else Text(if (action == "close") "Close “${thread.title}”? You can reopen it from History."
                    else "Reload “${thread.title}” from its saved provider thread on the host.")
                if (pending) Text("Working…")
                if (result is JobOutcome.Failed) Text(result.message, color = MaterialTheme.colorScheme.error)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(enabled = !pending, onClick = onDismiss) { Text(if (result is JobOutcome.Failed) "Dismiss" else "Cancel") }
                    TextButton(enabled = !pending && intent == null && (action != "rename" || title.trim().isNotEmpty()), onClick = {
                        intent = when (action) {
                            "rename" -> model.renameThread(thread.workspace_id, thread.thread_id, title)
                            "close" -> model.closeThread(thread.workspace_id, thread.thread_id)
                            else -> model.syncThread(thread.workspace_id, thread.thread_id)
                        }
                    }) { Text(label) }
                }
            }
        }
    }
}

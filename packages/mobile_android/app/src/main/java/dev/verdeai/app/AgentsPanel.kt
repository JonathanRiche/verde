package dev.verdeai.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.*
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatOrchestration
import dev.verdeai.core.ChatLinkedAgent

@Composable
internal fun AgentsWaitingBar(agents: ChatOrchestration, open: () -> Unit) {
    if (agents.waiting_count == 0L) return
    Surface(onClick = open, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        color = VerdeColors.Panel, shape = MaterialTheme.shapes.small) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(12.dp)
            .semantics { liveRegion = LiveRegionMode.Polite }) {
            Column(Modifier.weight(1f)) {
                Text(agents.title, color = if (agents.needs_you) VerdeColors.Warning else VerdeColors.Accent)
                Text(agents.summary, style = MaterialTheme.typography.bodySmall)
            }
            Text(if (agents.needs_you) "Review agents" else "View agents", color = VerdeColors.Accent)
        }
    }
}

@Composable
internal fun AgentsPanel(agents: ChatOrchestration?, close: () -> Unit, open: (ChatLinkedAgent) -> Unit, workspaceLabels: Map<String, String> = emptyMap(), entryFocus: FocusRequester? = null) {
    val focus = LocalFocusManager.current
    Column(Modifier.fillMaxSize().padding(12.dp).onPreviewKeyEvent { event ->
        if (event.type != KeyEventType.KeyDown) false else when (event.key) {
            Key.Escape -> { close(); true }
            Key.DirectionDown -> focus.moveFocus(FocusDirection.Next)
            Key.DirectionUp -> focus.moveFocus(FocusDirection.Previous)
            else -> false
        }
    }) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Agents", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).padding(vertical = 12.dp))
            TextButton(onClick = close, modifier = Modifier.heightIn(min = 48.dp).then(entryFocus?.let { Modifier.focusRequester(it) } ?: Modifier)) { Text("Close agents") }
        }
        if (agents?.error != null) SelectionContainer { Text("Couldn't refresh agents. Reconnect to try again.") }
        if (agents?.links.isNullOrEmpty()) SelectionContainer {
            Text(if (agents == null || !agents.loaded) "Loading agents…" else "No linked agents yet. Delegated chats will appear here.")
        }
        LazyColumn(Modifier.weight(1f)) {
            items(agents?.links.orEmpty(), key = { it.link_id }) { agent ->
                Surface(onClick = { open(agent) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .named("${agent.title}, ${agent.status_label}, ${agent.provider}. Open child chat"),
                    shape = MaterialTheme.shapes.small, color = VerdeColors.Panel) {
                    Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(agent.title, style = MaterialTheme.typography.titleSmall)
                        Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                            Text(agent.status_label, color = when { agent.needs_you -> VerdeColors.Warning; agent.status == "failed" -> VerdeColors.Danger; agent.status in listOf("aborted", "interrupted", "idle") -> VerdeColors.Muted; else -> VerdeColors.Accent },
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp))
                        }
                        Text(listOf(agent.provider, agent.model).filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.bodySmall)
                        Text(workspaceLabels[agent.workspace_id] ?: agent.workspace_id, style = MaterialTheme.typography.bodySmall)
                        if (agent.updated_at_ms > 0) Text(agoLabel(agent.updated_at_ms, System.currentTimeMillis()), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentsSheet(agents: ChatOrchestration?, close: () -> Unit, open: (ChatLinkedAgent) -> Unit, workspaceLabels: Map<String, String> = emptyMap()) {
    ModalBottomSheet(onDismissRequest = close) { Box(Modifier.fillMaxWidth().fillMaxHeight(0.85f)) { AgentsPanel(agents, close, open, workspaceLabels) } }
}

internal val LocalAgentsPanelVisible = androidx.compose.runtime.staticCompositionLocalOf<(Boolean) -> Unit> { {} }

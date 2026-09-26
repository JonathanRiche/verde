package dev.verdeai.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*

internal fun drawerThreads(workspace: Workspace): List<ThreadSummary> {
    val open = workspace.panes.mapNotNull { it.thread_id }.toSet()
    return workspaceThreads(workspace).filter { !it.archived && it.thread_id in open }
}

/** Shared browse projections only: search and folding never mutate the host. */
@Composable
internal fun WorkspaceDrawer(state: BrowseState, currentTab: String, visible: Boolean, onClose: () -> Unit,
    onTab: (String) -> Unit, onWorkspace: (String) -> Unit, onThread: (String, String) -> Unit,
    onHistory: () -> Unit, onNewChat: () -> Unit, selectedWorkspace: String? = null, selectedThread: String? = null,
    selectedTerminal: String? = null, onTerminal: (String, String) -> Unit = { _, _ -> },
    onNewWorkspaceChat: (String) -> Unit = {}, onNewTerminal: (String) -> Unit = {}, onAddWorkspace: () -> Unit = {},
    canEditThreads: Boolean = false, onThreadAction: (ThreadSummary, String) -> Unit = { _, _ -> }) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val workspaces = state.workspaces?.items.orEmpty().filter { it.open }
    val filter = query.trim()
    fun matches(value: String) = filter.isEmpty() || value.contains(filter, ignoreCase = true)
    ModalDrawerSheet(drawerContainerColor = VerdeColors.Panel, drawerShape = RoundedCornerShape(0.dp),
        modifier = Modifier.widthIn(max = 380.dp).fillMaxWidth(.92f).testTag("workspace-drawer")) {
        if (visible) {
            BackHandler { if (searching) { searching = false; query = "" } else onClose() }
            VerdeTopBar(title = { VerdeWordmark() }, showWorkspaceMenu = false,
                actions = {
                    IconButton(onClick = onAddWorkspace) { Icon(Icons.Filled.Add, "Add workspace") }
                    IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close workspace drawer") }
                })
            if (searching) OutlinedTextField(query, { query = it }, singleLine = true,
                placeholder = { Text("Chats, workspaces, commands") },
                leadingIcon = { Icon(Icons.Filled.Search, null) },
                trailingIcon = { IconButton(onClick = { query = ""; searching = false }) { Icon(Icons.Filled.Close, "Close search") } },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp).testTag("drawer-search"))
            else VerdeListRow(headlineContent = { Text("Search", color = VerdeColors.Subtle) },
                leadingContent = { Icon(Icons.Filled.Search, null, Modifier.size(18.dp)) },
                modifier = Modifier.fillMaxWidth().clickable { searching = true })
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 12.dp)) {
                item {
                    Row {
                        if (matches("Home")) DrawerRow("Home", currentTab == Routes.HOME, Modifier.weight(1f)) { onTab(Routes.HOME) }
                        if (matches("Workspaces")) DrawerRow("Workspaces", currentTab == Routes.WORKSPACES, Modifier.weight(1f)) { onTab(Routes.WORKSPACES) }
                    }
                }
                if (hasContent(state) && !needsPairing(state)) {
                    item {
                        Row(Modifier.padding(horizontal = 8.dp)) {
                            if (matches("New chat")) TextButton(onClick = onNewChat) { Text("New chat") }
                            if (matches("History")) TextButton(onClick = onHistory) { Text("History") }
                        }
                    }
                    val active = workspaces.flatMap { ws -> drawerThreads(ws).filter { activeStatus(it.status) || it.status == "waiting_approval" }.map { ws to it } }
                        .filter { matches(it.second.title) }
                    if (active.isNotEmpty() && !searching) {
                        item { VerdeSection("Active") }
                        items(active, key = { "active:${it.first.workspace_id}:${it.second.thread_id}" }) { (ws, thread) ->
                            DrawerChat(thread, selectedWorkspace == ws.workspace_id && selectedThread == thread.thread_id, canEditThreads, onThreadAction) {
                                onThread(ws.workspace_id, thread.thread_id)
                            }
                        }
                        item { HorizontalDivider(Modifier.padding(12.dp), color = VerdeColors.Border) }
                    }
                    workspaces.forEach { workspace ->
                        val threads = drawerThreads(workspace).filter { matches(it.title) || matches(workspace.label) }
                        val terminals = workspace.panes.filter { it.kind == "terminal" && it.terminal_id != null && (matches(it.title) || matches(workspace.label)) }
                        if (matches(workspace.label) || threads.isNotEmpty() || terminals.isNotEmpty() ||
                            (filter.isNotEmpty() && (matches("New terminal") || matches("New chat") || matches("Workspace")))) {
                            item(key = "workspace:${workspace.workspace_id}") {
                                var folded by rememberSaveable(workspace.workspace_id, selectedWorkspace) {
                                    mutableStateOf(workspace.workspace_id != (selectedWorkspace ?: workspaces.firstOrNull()?.workspace_id))
                                }
                                val expanded = searching || !folded
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    TextButton(onClick = { folded = !folded }, modifier = Modifier.width(48.dp)
                                        .semantics { contentDescription = "${if (expanded) "Collapse" else "Expand"} ${workspace.label}" }) {
                                        Text(if (expanded) "▾" else "▸", color = VerdeColors.Subtle)
                                    }
                                    Text(workspace.label, style = MaterialTheme.typography.titleSmall, maxLines = 1,
                                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).clickable { onWorkspace(workspace.workspace_id) }
                                            .padding(vertical = 12.dp).semantics { selected = selectedWorkspace == workspace.workspace_id })
                                    IconButton(onClick = { onNewWorkspaceChat(workspace.workspace_id) }) { Icon(Icons.Filled.Add, "New chat in ${workspace.label}", Modifier.size(18.dp)) }
                                }
                                if (expanded) {
                                    Column(Modifier.padding(start = 12.dp)) {
                                        threads.forEach { thread -> DrawerChat(thread,
                                            selectedWorkspace == workspace.workspace_id && selectedThread == thread.thread_id, canEditThreads, onThreadAction) { onThread(workspace.workspace_id, thread.thread_id) } }
                                        terminals.forEach { pane -> DrawerRow(">_ ${pane.title}", selectedWorkspace == workspace.workspace_id && selectedTerminal == pane.terminal_id) {
                                            onTerminal(workspace.workspace_id, pane.terminal_id!!)
                                        } }
                                        Row {
                                            TextButton(onClick = { onNewTerminal(workspace.workspace_id) }) { Text("New terminal", style = MaterialTheme.typography.labelMedium) }
                                            TextButton(onClick = { onWorkspace(workspace.workspace_id) }) { Text("Workspace", style = MaterialTheme.typography.labelMedium) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HorizontalDivider(color = VerdeColors.Border)
            DrawerRow("Hosts", currentTab == Routes.HOSTS) { onTab(Routes.HOSTS) }
        } else Spacer(Modifier.fillMaxHeight())
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DrawerChat(thread: ThreadSummary, active: Boolean, canEdit: Boolean,
    onAction: (ThreadSummary, String) -> Unit, onClick: () -> Unit) {
    var menu by remember(thread.workspace_id, thread.thread_id) { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    Box {

    VerdeListRow(headlineContent = { Text(thread.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = { ProviderGlyph(thread.provider) },
        trailingContent = { StatusPip(statusColor(thread.status, thread.status == "waiting_approval"), statusLabel(thread.status), active = activeStatus(thread.status)) },
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)
            .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, RoundedCornerShape(7.dp))
            .semantics { selected = active }
            .pointerInput(thread.workspace_id, thread.thread_id) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (event.type == PointerEventType.Press && event.buttons.isSecondaryPressed) {
                            event.changes.forEach { it.consume() }
                            menu = true
                        }
                    }
                }
            }
            .combinedClickable(onClick = onClick, onLongClickLabel = "Chat actions", onLongClick = { menu = true }))
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Open chat") }, onClick = { menu = false; onClick() })
            DropdownMenuItem(text = { Text("Copy title") }, onClick = { menu = false; clipboard.setText(AnnotatedString(thread.title)) })
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Rename chat") }, enabled = canEdit,
                onClick = { menu = false; onAction(thread, "rename") })
            DropdownMenuItem(text = { Text("Sync thread") }, enabled = canEdit && !activeStatus(thread.status) && thread.status != "waiting_approval",
                onClick = { menu = false; onAction(thread, "sync") })
            DropdownMenuItem(text = { Text("Close chat", color = VerdeColors.Danger) }, enabled = canEdit,
                onClick = { menu = false; onAction(thread, "close") })
        }
    }
}

@Composable
private fun DrawerRow(label: String, active: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    VerdeListRow(headlineContent = { Text(label, color = if (active) VerdeColors.AccentHi else VerdeColors.Text) },
        modifier = modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp)
            .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, RoundedCornerShape(7.dp))
            .semantics { selected = active }.clickable(onClick = onClick))
}

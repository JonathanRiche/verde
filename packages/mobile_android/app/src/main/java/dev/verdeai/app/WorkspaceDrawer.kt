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
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.draw.rotate
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
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

/** Switcher order: the core's recency rank (focus/activity newest first, closed untimed last). */
internal fun switcherWorkspaces(items: List<Workspace>): List<Workspace> = items.sortedBy { it.recency_rank }

/** Target for new chats/terminals under All Workspaces. */
internal fun mostRecentOpenWorkspace(items: List<Workspace>): Workspace? =
    items.filter { it.open }.minByOrNull { it.recency_rank }

/** Case-insensitive subsequence match, matching the desktop/web switcher. */
internal fun fuzzyMatches(query: String, value: String): Boolean {
    var i = 0
    val q = query.trim().lowercase()
    if (q.isEmpty()) return true
    for (c in value.lowercase()) if (i < q.length && c == q[i]) i++
    return i == q.length
}

internal data class DrawerItem(val workspace: Workspace, val thread: ThreadSummary?, val pane: Pane?) {
    val key get() = "${workspace.workspace_id}:${thread?.thread_id ?: pane?.terminal_id}"
    val active get() = thread?.let { t ->
        activeStatus(t.status) || t.status == "waiting_approval" || t.status == "failed" || pane?.attention_kind != null
    } ?: (pane?.attention == true)
    val title get() = thread?.title ?: pane?.title.orEmpty()
    /** A chat's last activity; terminals carry no synced status-change time yet. */
    val activityMs get() = thread?.last_activity_at_ms
}

/**
 * Flat Active/Open rows by workspace recency. Active always spans every open workspace;
 * Open follows the scope (null = All Workspaces). Under All Workspaces Open interleaves
 * every workspace newest activity first (untimed last; the stable sort keeps workspace
 * then layout order for ties), matching the desktop sidebar.
 */
internal fun drawerItems(items: List<Workspace>, scope: String?): Pair<List<DrawerItem>, List<DrawerItem>> {
    val rows = switcherWorkspaces(items).filter { it.open }.flatMap { ws ->
        val panes = ws.panes.associateBy { it.thread_id }
        drawerThreads(ws).map { DrawerItem(ws, it, panes[it.thread_id]) } +
            ws.panes.filter { it.kind == "terminal" && it.terminal_id != null }.map { DrawerItem(ws, null, it) }
    }
    val (active, open) = rows.partition { it.active }
    if (scope == null) return active to open.sortedWith(compareByDescending { it.activityMs ?: Long.MIN_VALUE })
    return active to open.filter { it.workspace.workspace_id == scope }
}

/** Shared browse projections only: scope and search never mutate the host. */
@Composable
internal fun WorkspaceDrawer(state: BrowseState, currentTab: String, visible: Boolean, onClose: () -> Unit,
    onTab: (String) -> Unit, onThread: (String, String) -> Unit, onHistory: () -> Unit,
    scope: String?, onScope: (String?) -> Unit, onNewChat: (String?) -> Unit,
    selectedWorkspace: String? = null, selectedThread: String? = null,
    selectedTerminal: String? = null, onTerminal: (String, String) -> Unit = { _, _ -> },
    onNewTerminal: (String) -> Unit = {}, onAddWorkspace: () -> Unit = {},
    onWorkspaceSettings: (String) -> Unit = {}, canManageWorkspaces: Boolean = false, onReopen: (String) -> Unit = {},
    canEditThreads: Boolean = false, onThreadAction: (ThreadSummary, String) -> Unit = { _, _ -> }) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val all = state.workspaces?.items.orEmpty()
    val scoped = all.find { it.workspace_id == scope }
    // Under All Workspaces new work goes to the most recently used workspace.
    val target = scoped?.takeIf { it.open } ?: mostRecentOpenWorkspace(all)
    val filter = query.trim()
    fun matches(value: String) = filter.isEmpty() || value.contains(filter, ignoreCase = true)
    ModalDrawerSheet(drawerContainerColor = VerdeColors.Panel, drawerShape = RoundedCornerShape(0.dp),
        modifier = Modifier.widthIn(max = 380.dp).fillMaxWidth(.92f).testTag("workspace-drawer")) {
        if (visible) {
            BackHandler { if (searching) { searching = false; query = "" } else onClose() }
            VerdeTopBar(title = { VerdeWordmark() }, showWorkspaceMenu = false,
                actions = { IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close workspace drawer") } })
            val ready = hasContent(state) && !needsPairing(state)
            if (ready) WorkspaceSwitcher(all, scoped, onScope, onWorkspaceSettings, onAddWorkspace, canManageWorkspaces, onReopen)
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                if (searching) OutlinedTextField(query, { query = it }, singleLine = true,
                    placeholder = { Text("Search chats") },
                    leadingIcon = { Icon(Icons.Filled.Search, null) },
                    trailingIcon = { IconButton(onClick = { query = ""; searching = false }) { Icon(Icons.Filled.Close, "Close search") } },
                    modifier = Modifier.weight(1f).testTag("drawer-search"))
                else Row(Modifier.weight(1f).heightIn(min = 40.dp).background(VerdeColors.PanelAlt, RoundedCornerShape(20.dp))
                    .clickable { searching = true }.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Search, null, Modifier.size(18.dp), tint = VerdeColors.Subtle)
                    Text("Search", color = VerdeColors.Subtle)
                }
                if (ready) {
                    IconButton(onClick = { onNewChat(target?.workspace_id) }) { Icon(Icons.Filled.Add, "New chat") }
                    if (target != null) IconButton(onClick = { onNewTerminal(target.workspace_id) }) {
                        Icon(workspaceIcon(9), "New terminal", Modifier.size(20.dp))
                    }
                }
            }
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 12.dp)) {
                if (ready) {
                    if (scoped != null && !scoped.open) item { Text("${scoped.label} is closed.", Modifier.padding(16.dp), color = VerdeColors.Muted) }
                    val (active, open) = drawerItems(all, scope)
                    fun section(title: String, rows: List<DrawerItem>, chip: Boolean) {
                        val shown = rows.filter { matches(it.title) || matches(it.workspace.label) }
                        if (shown.isEmpty()) return
                        item(key = "section:$title") { VerdeSection(title) }
                        items(shown, key = { "$title:${it.key}" }) { row ->
                            val ws = row.workspace.workspace_id
                            if (row.thread != null) DrawerChat(row.thread, selectedWorkspace == ws && selectedThread == row.thread.thread_id,
                                canEditThreads, onThreadAction, row.workspace.takeIf { chip }) { onThread(ws, row.thread.thread_id) }
                            else row.pane?.terminal_id?.let { id ->
                                DrawerRow(">_ ${row.title}", selectedWorkspace == ws && selectedTerminal == id, chip = row.workspace.takeIf { chip }) { onTerminal(ws, id) }
                            }
                        }
                    }
                    // Active is global, so its rows always name their workspace.
                    section("Active", active, chip = true)
                    section("Open", open, chip = scope == null)
                    if (filter.isNotEmpty()) item(key = "history") { DrawerRow("Search all chat history for \"$filter\"", false, onClick = onHistory) }
                }
            }
            HorizontalDivider(color = VerdeColors.Border)
            Row {
                DrawerRow("Home", currentTab == Routes.HOME, Modifier.weight(1f)) { onTab(Routes.HOME) }
                DrawerRow("Workspaces", currentTab == Routes.WORKSPACES, Modifier.weight(1f)) { onTab(Routes.WORKSPACES) }
                DrawerRow("Hosts", currentTab == Routes.HOSTS, Modifier.weight(1f)) { onTab(Routes.HOSTS) }
            }
        } else Spacer(Modifier.fillMaxHeight())
    }
}

/** Full-width scope trigger plus its context-menu popover (spec "Switcher popover"). */
@Composable
private fun WorkspaceSwitcher(all: List<Workspace>, scoped: Workspace?, onScope: (String?) -> Unit,
    onSettings: (String) -> Unit, onAddWorkspace: () -> Unit, canManage: Boolean, onReopen: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    // Closed workspaces sit in a collapsed group; a query searches them regardless.
    var closedExpanded by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(7.dp)).clickable { query = ""; closedExpanded = false; open = true }
            .padding(horizontal = 8.dp).testTag("workspace-switcher")
            .semantics { contentDescription = "Workspace scope: ${scoped?.label ?: "All Workspaces"}" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (scoped != null) WorkspaceChip(scoped, 22.dp)
            else Icon(Icons.Filled.Menu, null, Modifier.size(22.dp), tint = VerdeColors.Muted)
            Text(scoped?.label ?: "All Workspaces", style = MaterialTheme.typography.titleSmall, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.KeyboardArrowDown, null, tint = VerdeColors.Subtle)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = VerdeColors.PanelAlt,
            modifier = Modifier.widthIn(min = 280.dp, max = 340.dp).testTag("workspace-switcher-menu")) {
            OutlinedTextField(query, { query = it }, singleLine = true, placeholder = { Text("Search workspaces") },
                leadingIcon = { Icon(Icons.Filled.Search, null) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp).testTag("workspace-switcher-search"))
            if (fuzzyMatches(query, "All Workspaces")) DropdownMenuItem(text = { Text("All Workspaces") },
                leadingIcon = { Icon(Icons.Filled.Menu, null, Modifier.size(20.dp)) },
                trailingIcon = if (scoped == null) ({ Icon(Icons.Filled.Check, null, Modifier.size(18.dp)) }) else null,
                onClick = { open = false; onScope(null) })
            val matching = switcherWorkspaces(all).filter { fuzzyMatches(query, it.label) }
            val row: @Composable (Workspace) -> Unit = { ws ->
                // Closed rows reopen on select, which needs workspace management rights.
                val enabled = ws.open || canManage
                DropdownMenuItem(enabled = enabled,
                    modifier = Modifier.alpha(if (ws.open) 1f else .55f).semantics { selected = scoped?.workspace_id == ws.workspace_id },
                    leadingIcon = { WorkspaceChip(ws, 22.dp) },
                    text = { Text(ws.label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    trailingIcon = if (ws.open) ({ IconButton(onClick = { open = false; onSettings(ws.workspace_id) }) {
                        Icon(Icons.Filled.Settings, "Settings for ${ws.label}", Modifier.size(18.dp))
                    } }) else null,
                    onClick = {
                        open = false
                        if (!ws.open) onReopen(ws.workspace_id)
                        onScope(ws.workspace_id)
                    })
            }
            matching.filter { it.open }.forEach { row(it) }
            val closed = matching.filter { !it.open }
            if (closed.isNotEmpty()) {
                val expanded = closedExpanded || query.isNotBlank()
                DropdownMenuItem(enabled = query.isBlank(),
                    modifier = Modifier.testTag("workspace-switcher-closed")
                        .semantics { stateDescription = if (expanded) "expanded" else "collapsed" },
                    leadingIcon = { Icon(Icons.Filled.KeyboardArrowDown, null,
                        Modifier.size(22.dp).rotate(if (expanded) 0f else -90f), tint = VerdeColors.Subtle) },
                    text = { Text("Closed Workspaces", color = VerdeColors.Muted) },
                    trailingIcon = { Text("${closed.size}", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle) },
                    onClick = { closedExpanded = !closedExpanded })
                if (expanded) closed.forEach { row(it) }
            }
            HorizontalDivider(color = VerdeColors.Border)
            DropdownMenuItem(text = { Text("New workspace") }, leadingIcon = { Icon(Icons.Filled.Add, null, Modifier.size(20.dp)) },
                onClick = { open = false; onAddWorkspace() })
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DrawerChat(thread: ThreadSummary, active: Boolean, canEdit: Boolean,
    onAction: (ThreadSummary, String) -> Unit, chip: Workspace? = null, onClick: () -> Unit) {
    var menu by remember(thread.workspace_id, thread.thread_id) { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    Box {

    VerdeListRow(headlineContent = { Text(thread.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = { Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            chip?.let { WorkspaceChip(it, 16.dp) }
            ProviderGlyph(thread.provider)
        } },
        trailingContent = { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GitChangesDot(GitChat(thread.workspace_id, thread.thread_id))
            StatusPip(statusColor(thread.status, thread.status == "waiting_approval"), statusLabel(thread.status), active = activeStatus(thread.status))
        } },
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
private fun DrawerRow(label: String, active: Boolean, modifier: Modifier = Modifier, chip: Workspace? = null, onClick: () -> Unit) {
    VerdeListRow(headlineContent = { Text(label, color = if (active) VerdeColors.AccentHi else VerdeColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = chip?.let { { WorkspaceChip(it, 16.dp) } },
        modifier = modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp)
            .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, RoundedCornerShape(7.dp))
            .semantics { selected = active }.clickable(onClick = onClick))
}

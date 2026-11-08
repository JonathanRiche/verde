package dev.verdeai.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.material.icons.filled.Home
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*

/** Open chats, leaving out [hidden] (the companions' conversations, see [LocalHiddenThreads]). */
internal fun drawerThreads(workspace: Workspace, hidden: Set<String> = emptySet()): List<ThreadSummary> {
    val open = workspace.panes.mapNotNull { it.thread_id }.toSet()
    return workspaceThreads(workspace).filter { !it.archived && it.thread_id in open && it.thread_id !in hidden }
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
    /** C11: the core's state: Active holds the chats that need you, run or failed (Home's sections). */
    val state get() = chatState(thread?.state ?: pane?.state)
    val active get() = state == ChatState.NeedsYou || state == ChatState.Running || state == ChatState.Failed ||
        (thread == null && pane != null && pane.kind == "terminal" && activeStatus(pane.status))
    val title get() = thread?.title ?: pane?.title.orEmpty()
    /** A chat's last activity; terminals carry no synced status-change time yet. */
    val activityMs get() = thread?.last_activity_at_ms
}

/**
 * Flat Active/Open rows by workspace recency. Both follow the scope (null = All Workspaces). Under All Workspaces Open interleaves
 * every workspace newest activity first (untimed last; the stable sort keeps workspace
 * then layout order for ties), matching the desktop sidebar.
 */
internal fun drawerItems(items: List<Workspace>, scope: String?, hidden: Set<String> = emptySet()): Pair<List<DrawerItem>, List<DrawerItem>> {
    val rows = switcherWorkspaces(items).filter { it.open }.flatMap { ws ->
        val panes = ws.panes.associateBy { it.thread_id }
        drawerThreads(ws, hidden).map { DrawerItem(ws, it, panes[it.thread_id]) } +
            ws.panes.filter { it.kind == "terminal" && it.terminal_id != null }.map { DrawerItem(ws, null, it) }
    }
    val (active, open) = rows.partition { it.active }
    if (scope == null) return active to open.sortedWith(compareByDescending { it.activityMs ?: Long.MIN_VALUE })
    // A6-8: a workspace scope scopes Active too.
    return active.filter { it.workspace.workspace_id == scope } to open.filter { it.workspace.workspace_id == scope }
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
    canEditThreads: Boolean = false, onThreadAction: (ThreadSummary, String) -> Unit = { _, _ -> },
    onSettings: (() -> Unit)? = null,
    onChanges: ((String) -> Unit)? = null, onFiles: ((String) -> Unit)? = null,
    /** A permanent pane beside the content rather than a modal drawer; [onClose] then collapses it. */
    persistent: Boolean = false,
    /** Permanent pane only: Moss and its voice controls, above the tabs. */
    dock: (@Composable () -> Unit)? = null) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val all = state.workspaces?.items.orEmpty()
    val hidden = LocalHiddenThreads.current
    val scoped = all.find { it.workspace_id == scope }
    // Under All Workspaces new work goes to the most recently used workspace.
    // A5-4: the open chat's (or screen's) workspace first, then the most recent one.
    val target = scoped?.takeIf { it.open } ?: all.find { it.workspace_id == selectedWorkspace && it.open } ?: mostRecentOpenWorkspace(all)
    val filter = query.trim()
    fun matches(value: String) = filter.isEmpty() || value.contains(filter, ignoreCase = true)
    ModalDrawerSheet(drawerContainerColor = VerdeColors.Panel, drawerShape = RoundedCornerShape(0.dp),
        windowInsets = if (persistent) WindowInsets.safeDrawing.only(WindowInsetsSides.Start + WindowInsetsSides.Vertical) else DrawerDefaults.windowInsets,
        modifier = (if (persistent) Modifier.fillMaxSize() else Modifier.widthIn(max = 380.dp).fillMaxWidth(.92f)).testTag("workspace-drawer")) {
        if (visible) {
            // A permanent pane isn't a layer: back belongs to the content unless a search is open.
            BackHandler(enabled = !persistent || searching) { if (searching) { searching = false; query = "" } else onClose() }
            VerdeTopBar(title = { VerdeWordmark() }, showWorkspaceMenu = false,
                actions = {
                    // Settings is a footer destination (iOS parity); the header only closes.
                    if (persistent) IconButton(onClick = onClose, modifier = Modifier.named("Collapse sidebar")) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null) }
                    else IconButton(onClick = onClose, modifier = Modifier.named("Close workspace drawer")) { Icon(Icons.Filled.Close, null) }
                })
            val ready = hasContent(state) && !needsPairing(state)
            if (ready) WorkspaceSwitcher(all, scoped, onScope, onWorkspaceSettings, onAddWorkspace, canManageWorkspaces, onReopen)
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                if (searching) OutlinedTextField(query, { query = it }, singleLine = true,
                    placeholder = { Text("Search chats") },
                    leadingIcon = { Icon(Icons.Filled.Search, null) },
                    trailingIcon = { IconButton(onClick = { query = ""; searching = false }, modifier = Modifier.named("Close search")) { Icon(Icons.Filled.Close, null) } },
                    modifier = Modifier.weight(1f).testTag("drawer-search"))
                else Row(Modifier.weight(1f).heightIn(min = 40.dp).background(VerdeColors.PanelAlt, RoundedCornerShape(20.dp))
                    .clickable(role = Role.Button) { searching = true }.nameOnly("Search chats").padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Search, null, Modifier.size(18.dp), tint = VerdeColors.Subtle)
                    Text("Search", color = VerdeColors.Subtle)
                }
                if (ready) {
                    // r5: the sidebar too starts a chat from here, so its chat list keeps the height a
                    // separate New chat button took.
                    IconButton(onClick = { onNewChat(target?.workspace_id) }, modifier = Modifier.named("New chat").testTag(SIDEBAR_NEW_CHAT)) { Icon(Icons.Filled.Add, null) }
                    if (target != null) IconButton(onClick = { onNewTerminal(target.workspace_id) }, modifier = Modifier.named("New terminal")) {
                        Icon(workspaceIcon(9), null, Modifier.size(20.dp))
                    }
                }
            }
            if (ready && target != null && !searching && onChanges != null && onFiles != null) {
                ExplorerLinks({ onChanges(target.workspace_id) }, { onFiles(target.workspace_id) }, target.label.takeIf { scoped == null },
                    Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            }
            // A different scope starts at Active, rather than retaining the previous Open-row anchor.
            val listState = key(scope) { rememberLazyListState() }
            LazyColumn(Modifier.weight(1f), state = listState, contentPadding = PaddingValues(bottom = 12.dp)) {
                if (ready) {
                    if (scoped != null && !scoped.open) item { Text("${scoped.label} is closed.", Modifier.padding(16.dp), color = VerdeColors.Muted) }
                    val (active, open) = drawerItems(all, scope, hidden)
                    fun section(title: String, rows: List<DrawerItem>, chip: Boolean) {
                        val shown = rows.filter { matches(it.title) || matches(it.workspace.label) }
                        if (shown.isEmpty()) return
                        item(key = "section:$title") { VerdeSection(title) }
                        items(shown, key = { "$title:${it.key}" }) { row ->
                            val ws = row.workspace.workspace_id
                            if (row.thread != null) DrawerChat(row.thread, selectedWorkspace == ws && selectedThread == row.thread.thread_id,
                                canEditThreads, onThreadAction, row.workspace.takeIf { chip }, row.pane) { onThread(ws, row.thread.thread_id) }
                            else row.pane?.terminal_id?.let { id ->
                                DrawerTerminal(row.pane, selectedWorkspace == ws && selectedTerminal == id, row.workspace.takeIf { chip }) { onTerminal(ws, id) }
                            }
                        }
                    }
                    section("Active", active, chip = scope == null)
                    section("Open", open, chip = scope == null)
                    if (filter.isNotEmpty()) item(key = "history") { DrawerRow("Search all chat history for \"$filter\"", false, onClick = onHistory) }
                }
            }
            HorizontalDivider(color = VerdeColors.Border)
            if (persistent) {
                dock?.invoke()
                // Each tab takes the width of its label, so "Workspaces" never truncates in 300dp.
                DrawerFooter(currentTab, onTab, onSettings)
            } else DrawerFooter(currentTab, onTab, onSettings)
        } else Spacer(Modifier.fillMaxHeight())
    }
}

internal const val SIDEBAR_NEW_CHAT = "sidebar-new-chat"

/**
 * The drawer's destinations, the same four on both platforms: Home, Workspaces, Hosts, Settings.
 * Content-sized, so "Workspaces" never truncates; two per row when the drawer is narrow.
 */
/**
 * The drawer's destinations, the same four on both platforms: Home, Workspaces, Hosts, Settings.
 * A6-7: one row of icon-over-label tabs that fits a 300dp sidebar, so nothing wraps and the chat
 * list above keeps its height.
 */
@Composable
private fun DrawerFooter(currentTab: String, onTab: (String) -> Unit, onSettings: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        FooterTab("Home", rememberVectorPainter(Icons.Filled.Home), currentTab == Routes.HOME, Modifier.weight(1f)) { onTab(Routes.HOME) }
        FooterTab("Workspaces", painterResource(R.drawable.ic_folder), currentTab == Routes.WORKSPACES, Modifier.weight(1f)) { onTab(Routes.WORKSPACES) }
        FooterTab("Hosts", painterResource(R.drawable.host_machine), currentTab == Routes.HOSTS, Modifier.weight(1f)) { onTab(Routes.HOSTS) }
        onSettings?.let { open -> FooterTab("Settings", painterResource(R.drawable.ic_settings), currentTab == Routes.SECURITY, Modifier.weight(1f), open) }
    }
}

@Composable
private fun FooterTab(label: String, icon: androidx.compose.ui.graphics.painter.Painter, active: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val tint = if (active) VerdeColors.AccentHi else VerdeColors.Muted
    Column(modifier.heightIn(min = 56.dp).clip(RoundedCornerShape(10.dp))
        .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel)
        .clickable(role = Role.Tab, onClick = onClick).nameOnly(label, selected = active)
        .padding(vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Text(label, color = if (active) VerdeColors.AccentHi else VerdeColors.Text, style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp),
            maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun SidebarTab(label: String, active: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Text(label, modifier.padding(vertical = 2.dp).clip(RoundedCornerShape(7.dp))
        .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel)
        .clickable(role = Role.Tab, onClick = onClick).nameOnly(label, selected = active)
        .heightIn(min = 48.dp).wrapContentHeight(Alignment.CenterVertically).padding(horizontal = 6.dp),
        color = if (active) VerdeColors.AccentHi else VerdeColors.Text, style = MaterialTheme.typography.bodyMedium, maxLines = 1, softWrap = false,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center, overflow = TextOverflow.Ellipsis)
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
            .nameOnly("Workspace scope: ${scoped?.label ?: "All Workspaces"}")
            .padding(horizontal = 8.dp).testTag("workspace-switcher"),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (scoped != null) WorkspaceChip(scoped, 22.dp)
            else Icon(Icons.Filled.Menu, null, Modifier.size(22.dp), tint = VerdeColors.Muted)
            Text(scoped?.label ?: "All Workspaces", style = MaterialTheme.typography.titleSmall, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.KeyboardArrowDown, null, tint = VerdeColors.Subtle)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = VerdeColors.PanelAlt,
            modifier = Modifier.widthIn(min = 280.dp, max = 340.dp).testTag("workspace-switcher-menu")) {
            LiveOverMenu()
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
                    text = { Text(workspaceName(ws), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    trailingIcon = if (ws.open) ({ IconButton(onClick = { open = false; onSettings(ws.workspace_id) }, modifier = Modifier.named("Settings for ${ws.label}")) {
                        Icon(Icons.Filled.Settings, null, Modifier.size(18.dp))
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
    onAction: (ThreadSummary, String) -> Unit, chip: Workspace? = null, pane: Pane? = null, onClick: () -> Unit) {
    var menu by remember(thread.workspace_id, thread.thread_id) { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    Box {

    VerdeListRow(headlineContent = { Text(thread.title, maxLines = if (active) 2 else 1, overflow = TextOverflow.Ellipsis,
        fontWeight = if (chatState(thread.state ?: pane?.state) == ChatState.Unread) FontWeight.SemiBold else FontWeight.Normal) },
        supportingContent = thread.orchestration_subtitle.takeIf { it.isNotBlank() }?.let { subtitle -> { Text(subtitle, color = if (chatState(thread.state) == ChatState.NeedsYou) VerdeColors.Warning else VerdeColors.Accent) } },
        leadingContent = { Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            chip?.let { WorkspaceChip(it, 16.dp) }
            ProviderGlyph(thread.provider)
        } },
        trailingContent = { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GitChangesDot(GitChat(thread.workspace_id, thread.thread_id))
            // A8-5: one dot rule in every scope (Home's): amber when it needs you, pulsing green while
            // running, red when failed; done and idle chats carry none.
            // C11: the core's state, the same mark as Home.
            StateMark(chatState(thread.state ?: pane?.state))
        } },
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)
            .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, RoundedCornerShape(7.dp))
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
            .combinedClickable(onClick = onClick, onLongClickLabel = "Chat actions", onLongClick = { menu = true })
            .nameOnly(listOfNotNull(chip?.label, thread.title, chatState(thread.state ?: pane?.state).let { st ->
                chatStateLabel(st, thread.status) ?: "Unread".takeIf { st == ChatState.Unread } }).joinToString(", "), selected = active))
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            LiveOverMenu()
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

/** Terminal row: an agent TUI shows its provider glyph and a live status pip, like the desktop/web rail. */
@Composable
private fun DrawerTerminal(pane: Pane, active: Boolean, chip: Workspace?, onClick: () -> Unit) {
    VerdeListRow(headlineContent = { Text(pane.title, color = if (active) VerdeColors.AccentHi else VerdeColors.Text, maxLines = if (active) 2 else 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = { Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            chip?.let { WorkspaceChip(it, 16.dp) }
            if (pane.provider != null) ProviderGlyph(pane.provider)
            else Icon(painterResource(R.drawable.ic_tool_terminal), contentDescription = null, tint = VerdeColors.Subtle, modifier = Modifier.size(18.dp))
        } },
        trailingContent = if (activeStatus(pane.status)) ({
            StatusPip(statusColor(pane.status, pane.status == "waiting"), paneLabel(pane), active = pane.status == "working")
        }) else null,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp)
            .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, RoundedCornerShape(7.dp))
            .clickable(onClick = onClick).nameOnly(listOfNotNull(chip?.label, pane.title, paneLabel(pane).takeIf { activeStatus(pane.status) }).joinToString(", "), selected = active))
}

@Composable
private fun DrawerRow(label: String, active: Boolean, modifier: Modifier = Modifier, chip: Workspace? = null, onClick: () -> Unit) {
    VerdeListRow(headlineContent = { Text(label, color = if (active) VerdeColors.AccentHi else VerdeColors.Text, maxLines = if (active) 2 else 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = chip?.let { { WorkspaceChip(it, 16.dp) } },
        modifier = modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp)
            .background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, RoundedCornerShape(7.dp))
            .clickable(onClick = onClick).nameOnly(listOfNotNull(chip?.label, label).joinToString(", "), selected = active))
}

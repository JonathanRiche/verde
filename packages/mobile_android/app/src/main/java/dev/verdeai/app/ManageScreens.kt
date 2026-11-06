package dev.verdeai.app

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.ui.res.painterResource
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*
import kotlinx.coroutines.delay

internal object ManageRoutes {
    const val HISTORY = "history"
    const val NEW_CHAT = "new-chat"
    const val NEW_CHAT_IN = "new-chat/{ws}"
    const val ADD_WORKSPACE = "workspace-add"
    fun newChat(ws: String?) = if (ws == null) NEW_CHAT else "new-chat/${Uri.encode(ws)}"
}

internal const val MANAGE_LIST = "manage-list"
internal const val HISTORY_SEARCH = "history-search"
internal const val WORKSPACE_PATH = "workspace-path"
internal const val WORKSPACE_LABEL = "workspace-label"
internal const val RENAME_FIELD = "rename-field"
internal const val IDENTITY_ICON = "identity-icon-"
internal const val IDENTITY_COLOR = "identity-color-"
internal const val SEARCH_DEBOUNCE_MS = 300L

/** History rows in core order with a header whenever the core's bucket changes. */
internal fun historySections(items: List<ThreadSummary>): List<Pair<String, List<ThreadSummary>>> {
    val out = mutableListOf<Pair<String, MutableList<ThreadSummary>>>()
    for (item in items.filterNot(::subagent)) {
        if (out.lastOrNull()?.first != item.history_bucket) out += item.history_bucket to mutableListOf()
        out.last().second += item
    }
    return out
}

private fun connected(state: BrowseState) = state.host?.phase == "ready" && state.host?.auth_state == "paired"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ManageFrame(title: String, onBack: () -> Unit, content: LazyListScope.() -> Unit) {
    Column(Modifier.fillMaxSize()) {
        VerdeTopBar(title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onClick = onBack, modifier = Modifier.named("Back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null) } })
        LazyColumn(Modifier.fillMaxSize().testTag(MANAGE_LIST), content = content)
    }
}

/**
 * S30: the Schedules empty-state pattern shared by quiet lists (New chat with no workspace, the
 * companion's Conversations): an icon, one line, one primary action.
 */
@Composable
internal fun QuietEmptyState(icon: Int, text: String, action: String?, enabled: Boolean = true, modifier: Modifier = Modifier, onAction: () -> Unit = {}) {
    Column(modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(painterResource(icon), contentDescription = null, tint = VerdeColors.Muted, modifier = Modifier.size(32.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = VerdeColors.Muted,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (action != null) NamedButton(action, onAction, Modifier.heightIn(min = 40.dp), enabled = enabled,
            container = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = .12f),
            content = if (enabled) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
            shape = MaterialTheme.shapes.small, padding = PaddingValues(horizontal = 24.dp))
    }
}

private fun LazyListScope.line(key: String, text: String, error: Boolean = false) {
    item(key = key) {
        Text(text, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodyMedium,
            color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
    }
}

private fun LazyListScope.section(text: String) {
    item(key = "section:$text") {
        VerdeSection(text)
    }
}

private fun LazyListScope.progress(key: String) {
    item(key = key) { LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) }
}

/** Host-level gate for management screens; true when the caller may render its content. */
private fun LazyListScope.ready(state: BrowseState): Boolean {
    val message = when {
        state.hostId == null -> "No host selected."
        needsPairing(state) -> "Pair this phone with ${state.row?.saved?.label ?: "the host"} first."
        !hasContent(state) -> "Loading workspaces…"
        else -> return true
    }
    line("gate", message)
    return false
}

// ---- History ----

@Composable
internal fun HistoryScreen(browse: BrowseModel, manage: ManageModel, onOpenThread: (ThreadSummary) -> Unit, onBack: () -> Unit) {
    val state by browse.state.collectAsState()
    val history = state.workspaces?.history
    val workspaces = state.workspaces?.items.orEmpty()
    val labels = workspaceLabels(workspaces)
    var query by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf<String?>(null) }
    // What the core's history currently reflects; a leftover search from an earlier visit resets.
    var applied by remember { mutableStateOf((history?.query ?: "") to null as String?) }
    LaunchedEffect(query, filter, state.hostId) {
        val wanted = query.trim() to filter
        if (wanted == applied || state.hostId == null) return@LaunchedEffect
        if (wanted.first != applied.first) delay(SEARCH_DEBOUNCE_MS)
        manage.searchHistory(wanted.first, wanted.second)
        applied = wanted
    }
    // Home's recent chats read the same list, so leave it unfiltered.
    val reset by rememberUpdatedState { if (applied != ("" to null)) manage.searchHistory("", null) }
    DisposableEffect(Unit) { onDispose { reset() } }
    val now = rememberListNow(false)
    ManageFrame("History", onBack) {
        if (!ready(state)) return@ManageFrame
        item(key = "search") {
            // A5-7: a search pill (like the drawer's) whose text has its inner padding, so neither the
            // text nor a keyboard focus ring sits against the edge.
            BasicTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).testTag(HISTORY_SEARCH),
                singleLine = true, textStyle = MaterialTheme.typography.bodyLarge.copy(color = VerdeColors.Text),
                cursorBrush = SolidColor(VerdeColors.Accent), decorationBox = { field ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).background(VerdeColors.PanelAlt, RoundedCornerShape(24.dp))
                        .padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.Search, contentDescription = null, tint = VerdeColors.Muted, modifier = Modifier.size(20.dp))
                        Box(Modifier.weight(1f)) {
                            if (query.isEmpty()) Text("Search chats", color = VerdeColors.Subtle)
                            field()
                        }
                        // S38: a full 48dp Clear search target.
                        if (query.isNotEmpty()) IconButton(onClick = { query = "" }, modifier = Modifier.named("Clear search")) {
                            Icon(Icons.Filled.Close, contentDescription = null, tint = VerdeColors.Muted)
                        }
                    }
                })
        }
        if (workspaces.size > 1) item(key = "filters") {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item { FilterChip(filter == null, { filter = null }, label = { Text("All") }) }
                items(workspaces, key = { it.workspace_id }) { ws ->
                    FilterChip(filter == ws.workspace_id, { filter = if (filter == ws.workspace_id) null else ws.workspace_id },
                        label = { Text(labels[ws.workspace_id] ?: ws.label, maxLines = 1, overflow = TextOverflow.Ellipsis) })
                }
            }
        }
        if (history == null) return@ManageFrame
        val sections = historySections(history.items)
        for ((bucket, threads) in sections) {
            section(bucket)
            items(threads, key = { "history:${it.workspace_id}:${it.thread_id}" }) { thread ->
                val parts = listOfNotNull(labels[thread.workspace_id].takeIf { filter == null },
                    statusLabel(thread.status).takeIf { thread.status != "idle" }, "Archived".takeIf { thread.archived },
                    thread.last_activity_at_ms?.let { agoLabel(it, now) })
                VerdeListRow(headlineContent = { Text(thread.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    leadingContent = { ProviderGlyph(thread.provider) },
                    supportingContent = parts.takeIf { it.isNotEmpty() }?.let { { Text(it.joinToString(" · "), maxLines = 1) } },
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open") { onOpenThread(thread) }
                        .nameOnly(listOf(thread.title).plus(parts).joinToString(", ")))
            }
        }
        history.error?.let { line("history-error", "Couldn't load chats. ${it.message}".trim(), error = true) }
        when {
            history.loading -> progress("history-loading")
            history.next_cursor != null -> item(key = "more:${history.next_cursor}") {
                // Reaching the end asks for exactly one more page per cursor; the button retries.
                LaunchedEffect(history.next_cursor) { if (history.error == null) manage.loadMoreHistory() }
                TextButton(onClick = { manage.loadMoreHistory() }, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Load more") }
            }
            sections.isEmpty() -> line("history-empty", if (applied.first.isNotEmpty() || filter != null) "No chats match." else "No chats yet.")
        }
    }
}

// ---- New chat ----

@Composable
internal fun Picker(label: String, value: String, choices: List<ChatChoice>, enabled: Boolean, providerIcons: Boolean = false, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Box {
            // S29: the field's own node reads "Label: value. Change".
            val on = enabled && choices.isNotEmpty()
            NamedButton("$label: $value. Change", { open = true }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("picker:$label"), enabled = on,
                shape = MaterialTheme.shapes.small, padding = PaddingValues(horizontal = 24.dp, vertical = 8.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, if (on) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.outline.copy(alpha = .12f))) {
                if (providerIcons) {
                    ProviderGlyph(choices.find { it.label == value }?.id ?: value)
                    Spacer(Modifier.width(8.dp))
                }
                Text(value, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                LiveOverMenu()
                choices.forEach { choice ->
                    DropdownMenuItem(text = { Text(choice.label) },
                        leadingIcon = if (providerIcons) ({ ProviderGlyph(choice.id) }) else null, enabled = choice.enabled, onClick = { open = false; onPick(choice.id) })
                }
            }
        }
    }
}

private fun label(choices: List<ChatChoice>, id: String?, fallback: String) = choices.find { it.id == id }?.label ?: id ?: fallback

@Composable
internal fun NewChatScreen(
    browse: BrowseModel,
    manage: ManageModel,
    initialWorkspace: String?,
    onCreated: (workspaceId: String, threadId: String) -> Unit,
    onAddWorkspace: () -> Unit = {},
    onBack: () -> Unit,
) {
    val state by browse.state.collectAsState()
    val manageState by manage.state.collectAsState()
    val open = state.workspaces?.items.orEmpty().filter { it.open }
    var workspaceId by rememberSaveable { mutableStateOf(initialWorkspace) }
    LaunchedEffect(open.map { it.workspace_id }) {
        if (workspaceId == null || open.none { it.workspace_id == workspaceId }) workspaceId = initialWorkspace?.takeIf { id -> open.any { it.workspace_id == id } }
            ?: mostRecentOpenWorkspace(open)?.workspace_id
    }
    val chat = manageState.view?.new_chat?.takeIf { it.workspace_id != null && it.workspace_id == workspaceId }
    // One select per workspace (and host) so the core loads that workspace's provider and models.
    LaunchedEffect(workspaceId, manageState.hostId, manageState.view != null) {
        val ws = workspaceId ?: return@LaunchedEffect
        if (manageState.view != null && manageState.view?.new_chat?.workspace_id != ws) manage.select(ws)
    }
    var createIntent by rememberSaveable { mutableStateOf<String?>(null) }
    val result = outcome(manageState, createIntent)
    LaunchedEffect(result) {
        val job = (result as? JobOutcome.Done)?.job ?: return@LaunchedEffect
        val thread = job.thread_id ?: return@LaunchedEffect
        createIntent = null
        onCreated(job.workspace_id ?: workspaceId.orEmpty(), thread)
    }
    ManageFrame("New chat", onBack) {
        if (!ready(state)) return@ManageFrame
        if (open.isEmpty()) {
            item(key = "no-workspaces") {
                QuietEmptyState(R.drawable.ic_folder, "Chats run in a workspace. Add one to start.", "Add workspace",
                    modifier = Modifier.testTag("no-workspaces"), onAction = onAddWorkspace)
            }
            return@ManageFrame
        }
        val ws = workspaceId ?: return@ManageFrame
        val selection = chat?.selection ?: ChatSelection()
        val catalogs = chat?.catalogs ?: ChatCatalogs()
        val busy = result == JobOutcome.Pending
        item(key = "workspace") {
            Picker("Workspace", open.find { it.workspace_id == ws }?.label ?: "Workspace",
                open.map { ChatChoice(it.workspace_id, it.label) }, !busy) { workspaceId = it }
        }
        item(key = "provider") {
            val providers = chat?.providers.orEmpty()
            Picker("Provider", label(providers, selection.provider, "Provider"), providers, chat != null && !busy, providerIcons = true) {
                if (it != selection.provider) manage.select(ws, ChatSelection(provider=it))
            }
        }
        item(key = "model") {
            // S25: no bare "Default": the default model names what it resolves to.
            val models = catalogs.models.map { it.copy(label = pickerRowLabel(ComposerPicker.Model, it, catalogs)) }
            Picker("Model", modelValueLabel(catalogs, selection), models, chat != null && !busy) {
                manage.select(ws, selection.copy(model=it))
            }
        }
        if (catalogs.efforts.isNotEmpty()) item(key = "effort") {
            val efforts = catalogs.efforts.map { it.copy(label = pickerRowLabel(ComposerPicker.Effort, it, catalogs)) }
            Picker("Effort", effortValueLabel(catalogs, selection), efforts, chat != null && !busy) {
                manage.select(ws, selection.copy(effort=it))
            }
        }
        if (catalogs.access.isNotEmpty()) item(key = "access") {
            Picker("Access", accessChipLabel(catalogs.access, selection.access),
                catalogs.access.map { it.copy(label = pickerRowLabel(ComposerPicker.Access, it, catalogs)) }, chat != null && !busy) {
                manage.select(ws, selection.copy(access=it))
            }
        }
        if (chat == null || chat.loading) progress("models-loading")
        chat?.error?.let { line("models-error", "Couldn't load this provider's models. The defaults still work.", error = true) }
        (result as? JobOutcome.Failed)?.let { line("create-error", it.message, error = true) }
        when {
            !connected(state) -> line("create-offline", "Connect to the host to start a chat.")
            manageState.view?.can_create_threads == false -> line("create-scope", "This phone can't start chats on this host.")
        }
        item(key = "create") {
            Button(shape = MaterialTheme.shapes.small, onClick = { createIntent = manage.createThread(ws, selection) }, enabled = chat?.can_create == true && !busy,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).heightIn(min = 48.dp)) {
                Text(if (busy) "Creating…" else "Start chat")
            }
        }
    }
}

// ---- Add workspace ----

@Composable
internal fun AddWorkspaceScreen(browse: BrowseModel, manage: ManageModel, onCreated: (workspaceId: String) -> Unit, onBack: () -> Unit) {
    val state by browse.state.collectAsState()
    val manageState by manage.state.collectAsState()
    val view = manageState.view
    val directory = view?.directory
    var path by rememberSaveable { mutableStateOf("") }
    var name by rememberSaveable { mutableStateOf("") }
    var createIntent by rememberSaveable { mutableStateOf<String?>(null) }
    val result = outcome(manageState, createIntent)
    LaunchedEffect(manageState.hostId, connected(state), view != null) {
        if (view != null && connected(state) && directory?.supported == true) manage.listDirectory(directory.path.ifEmpty { null })
    }
    LaunchedEffect(result) {
        val job = (result as? JobOutcome.Done)?.job ?: return@LaunchedEffect
        createIntent = null
        job.workspace_id?.let(onCreated)
    }
    val busy = result == JobOutcome.Pending
    ManageFrame("Add workspace", onBack) {
        if (!ready(state)) return@ManageFrame
        item(key = "path") {
            OutlinedTextField(path, { path = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).testTag(WORKSPACE_PATH),
                singleLine = true, label = { Text("Folder on the computer") }, placeholder = { Text("/home/you/project") })
        }
        item(key = "label") {
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).testTag(WORKSPACE_LABEL),
                singleLine = true, label = { Text("Name (optional)") })
        }
        (result as? JobOutcome.Failed)?.let { line("add-error", it.message, error = true) }
        when {
            !connected(state) -> line("add-offline", "Connect to the host to add a workspace.")
            view?.can_manage_workspaces == false -> line("add-scope", "This phone can't change workspaces on this host.")
        }
        item(key = "add") {
            Button(shape = MaterialTheme.shapes.small, onClick = { createIntent = manage.createWorkspace(path.trim(), name) },
                enabled = path.isNotBlank() && view?.can_manage_workspaces == true && !busy,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) { Text(if (busy) "Adding…" else "Add workspace") }
        }
        // S34: "Recent folders" and "Contents of <folder>" below, as two sections.
        if (directory == null) return@ManageFrame
        if (!directory.supported) {
            line("browse-unsupported", "Update verde on the computer to browse folders. You can still type a path.")
            return@ManageFrame
        }
        // A5-8: no stale suggestions from closed workspaces (their folders may be gone).
        val suggestions = freshFolderSuggestions(directory.suggestions, state.workspaces?.items.orEmpty())
        // S34: recent folders are their own section, apart from what's in the folder being browsed.
        if (suggestions.isNotEmpty()) {
            section("Recent folders")
            // S15: suggested folders as list rows: a name that tells them apart, the full path under it.
            val labels = folderChipLabels(suggestions)
            items(suggestions, key = { "suggestion:$it" }) { root ->
                VerdeListRow(headlineContent = { Text(labels[root] ?: root, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    // U: the folder it sits in, not the raw path (the full path is in the field once chosen).
                    supportingContent = basename(root.trimEnd('/').substringBeforeLast('/', "")).takeIf { it.isNotEmpty() }?.let { p ->
                        { Text("in $p", maxLines = 1, overflow = TextOverflow.Ellipsis) } },
                    leadingContent = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null, tint = VerdeColors.Muted, modifier = Modifier.size(20.dp)) },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = VerdeColors.Muted) },
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { manage.listDirectory(root) }.nameOnly("Browse $root"))
            }
        }
        if (directory.path.isNotEmpty()) {
            section("Contents of ${basename(directory.path)}")
            item(key = "current") {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(directory.path, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    NamedButton("Use this folder", { path = directory.path }, enabled = directory.error == null && !directory.loading)
                }
            }
        }
        directory.error?.let { line("browse-error", it.message, error = true) }
        if (directory.loading) progress("browse-loading")
        directory.parent?.let { parent ->
            item(key = "parent") {
                VerdeListRow(headlineContent = { Text("..") }, supportingContent = { Text("Up one folder") },
                    leadingContent = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null, tint = VerdeColors.Muted, modifier = Modifier.size(20.dp)) },
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { manage.listDirectory(parent) }.nameOnly("Up one folder"))
            }
        }
        items(directory.entries, key = { "dir:" + it.path }) { entry ->
            VerdeListRow(headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                leadingContent = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null, tint = VerdeColors.Muted, modifier = Modifier.size(20.dp)) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = VerdeColors.Muted) },
                modifier = Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Browse") { manage.listDirectory(entry.path) }.nameOnly(entry.name))
        }
        if (!directory.loading && directory.error == null && directory.entries.isEmpty() && directory.path.isNotEmpty()) line("browse-empty", "No folders here.")
    }
}

// ---- Workspace actions ----

/** New chat, rename and close/reopen for one workspace, with the latest result under the buttons. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun WorkspaceActions(state: BrowseState, manage: ManageModel, workspace: Workspace, onNewChat: () -> Unit,
    /** Rows that go after New chat (Changes, Files). */
    extraRows: (@Composable () -> Unit)? = null) {
    val manageState by manage.state.collectAsState()
    var intent by rememberSaveable(workspace.workspace_id) { mutableStateOf<String?>(null) }
    var renaming by rememberSaveable(workspace.workspace_id) { mutableStateOf(false) }
    var closing by rememberSaveable(workspace.workspace_id) { mutableStateOf(false) }
    var styling by rememberSaveable(workspace.workspace_id) { mutableStateOf(false) }
    val result = outcome(manageState, intent)
    val busy = result == JobOutcome.Pending
    val canManage = manageState.view?.can_manage_workspaces == true && !busy
    Column(Modifier.fillMaxWidth()) {
        // S15: list rows, as on iOS: icon, title, chevron; New chat in the accent, Close in error.
        if (workspace.open) ActionRow(Icons.Filled.Add, "New chat", enabled = manageState.view?.can_create_threads == true,
            tint = MaterialTheme.colorScheme.primary, onClick = onNewChat)
        extraRows?.invoke()
        ActionRow(Icons.Filled.Edit, "Rename", enabled = canManage) { renaming = true }
        ActionRow(painterResource(R.drawable.ic_palette), "Icon and color", enabled = canManage) { styling = true }
        if (workspace.open) ActionRow(Icons.Filled.Close, "Close workspace", enabled = canManage, tint = MaterialTheme.colorScheme.error,
            chevron = false) { closing = true }
        else ActionRow(Icons.Filled.Refresh, "Reopen workspace", enabled = canManage, chevron = false) { intent = manage.setArchived(workspace.workspace_id, false) }
        if (renaming) {
            var label by rememberSaveable(workspace.workspace_id) { mutableStateOf(workspace.label) }
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(label, { label = it }, Modifier.weight(1f).testTag(RENAME_FIELD), singleLine = true, label = { Text("Name") })
                TextButton(onClick = { renaming = false; intent = manage.rename(workspace.workspace_id, label) },
                    enabled = label.isNotBlank() && label.trim() != workspace.label) { Text("Save") }
                TextButton(onClick = { renaming = false }) { Text("Cancel") }
            }
        }
        when (result) {
            is JobOutcome.Failed -> Text(result.message, Modifier.padding(horizontal = 8.dp), color = MaterialTheme.colorScheme.error)
            JobOutcome.Pending -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(8.dp))
            else -> Unit
        }
        if (!connected(state)) Text("Connect to the host to change this workspace.", Modifier.padding(horizontal = 8.dp),
            style = MaterialTheme.typography.bodySmall)
    }
    if (closing) {
        AlertDialog(onDismissRequest = { closing = false }, title = { LiveOverModal(); Text("Close ${workspace.label}?") },
            text = { Text("verde stops this workspace's terminals and moves it to Closed. Its chats stay in history, and you can reopen it later.") },
            confirmButton = { TextButton(onClick = { closing = false; intent = manage.close(workspace.workspace_id) },
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Close workspace") } },
            dismissButton = { TextButton(onClick = { closing = false }) { Text("Cancel") } })
    }
    if (styling) WorkspaceIdentityDialog(workspace, onDismiss = { styling = false }) { icon, color ->
        styling = false
        intent = manage.setIdentity(workspace.workspace_id, icon, color)
    }
}

/** Picks a pinned icon and color, or "Automatic" (null) for either; Save sends one intent. */
@Composable
internal fun WorkspaceIdentityDialog(workspace: Workspace, onDismiss: () -> Unit, onSave: (Int?, Int?) -> Unit) {
    val id = workspace.workspace_id
    var icon by rememberSaveable(id) { mutableStateOf(if (workspace.icon_custom) workspace.icon_index else null) }
    var color by rememberSaveable(id) { mutableStateOf(if (workspace.color_custom) workspace.color_index else null) }
    val (autoIcon, autoColor) = remember(id) { workspaceAutoIdentity(id) }
    val tint = workspaceColor(color ?: autoColor, VerdeColors.Accent, VerdeColors.dark)
    val changed = icon != (if (workspace.icon_custom) workspace.icon_index else null) ||
        color != (if (workspace.color_custom) workspace.color_index else null)
    AlertDialog(onDismissRequest = onDismiss, title = { LiveOverModal(); Text("Icon and color") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Icon", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                    FilterChip(selected = icon == null, onClick = { icon = null }, label = { Text("Automatic") })
                }
                for (row in 0 until 4) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (col in 0 until 4) {
                        val k = row * 4 + col
                        val selected = (icon ?: autoIcon) == k
                        Box(Modifier.weight(1f).aspectRatio(1f).testTag(IDENTITY_ICON + k)
                            .background(if (selected) tint.copy(alpha = .18f) else Color.Transparent, RoundedCornerShape(10.dp))
                            .then(if (selected && icon != null) Modifier.border(2.dp, tint, RoundedCornerShape(10.dp)) else Modifier)
                            .selectable(selected = selected && icon != null, role = Role.RadioButton) { icon = k }
                            .semantics { contentDescription = WORKSPACE_ICON_NAMES[k] },
                            contentAlignment = Alignment.Center) {
                            Icon(workspaceIcon(k), contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
                        }
                    }
                }
                Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Color", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                    FilterChip(selected = color == null, onClick = { color = null }, label = { Text("Automatic") })
                }
                // Two rows of four: every swatch keeps a 48dp target, and each has its own name (V: iOS's
                // hue names, a repeat numbered: "Green", "Green 2").
                val names = workspaceColorNames(VerdeColors.Accent)
                for (row in 0 until 2) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (col in 0 until 4) {
                        val k = row * 4 + col
                        val selected = color == k
                        val swatch = workspaceColor(k, VerdeColors.Accent, VerdeColors.dark)
                        Box(Modifier.weight(1f).heightIn(min = 48.dp).testTag(IDENTITY_COLOR + k)
                            .selectable(selected = selected, role = Role.RadioButton) { color = k }
                            .semantics { contentDescription = names[k] }, contentAlignment = Alignment.Center) {
                            Box(Modifier.size(40.dp)
                                .then(if (selected) Modifier.border(2.dp, MaterialTheme.colorScheme.onSurface, CircleShape) else Modifier)
                                .padding(4.dp).background(swatch, CircleShape))
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(icon, color) }, enabled = changed) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}

/** A hue's everyday name (iOS colorHueName), for TalkBack. */
internal fun colorHueName(hue: Float): String = when {
    hue < 15f -> "Red"; hue < 40f -> "Orange"; hue < 65f -> "Yellow"; hue < 95f -> "Lime"; hue < 150f -> "Green"
    hue < 185f -> "Teal"; hue < 205f -> "Cyan"; hue < 250f -> "Blue"; hue < 275f -> "Indigo"; hue < 300f -> "Purple"
    hue < 330f -> "Magenta"; hue < 345f -> "Pink"; else -> "Red"
}

/** The eight identity colours' names for [accent], a repeat numbered ("Green 2"), as on iOS. */
internal fun workspaceColorNames(accent: Color): List<String> {
    val seen = HashMap<String, Int>()
    return (0 until 8).map { slot ->
        val c = workspaceColor(slot, accent, dark = false)
        val max = maxOf(c.red, c.green, c.blue); val min = minOf(c.red, c.green, c.blue); val d = max - min
        var h = when {
            d <= 0f -> 0f
            max == c.red -> 60f * (((c.green - c.blue) / d) % 6f)
            max == c.green -> 60f * ((c.blue - c.red) / d + 2f)
            else -> 60f * ((c.red - c.green) / d + 4f)
        }
        if (h < 0f) h += 360f
        val name = colorHueName(h)
        val n = (seen[name] ?: 0) + 1
        seen[name] = n
        if (n > 1) "$name $n" else name
    }
}

/** A spoken name for a workspace colour swatch ("Teal"), from its hue. */
internal fun colorName(color: Color): String {
    val r = color.red; val g = color.green; val b = color.blue
    val max = maxOf(r, g, b); val min = minOf(r, g, b); val d = max - min
    if (d < .05f) return if (max > .5f) "Grey" else "Charcoal"
    val h = when (max) {
        r -> 60f * (((g - b) / d).mod(6f))
        g -> 60f * ((b - r) / d + 2f)
        else -> 60f * ((r - g) / d + 4f)
    }
    return when {
        h < 15f -> "Red"; h < 45f -> "Orange"; h < 70f -> "Yellow"; h < 100f -> "Lime"; h < 160f -> "Green"
        h < 200f -> "Teal"; h < 250f -> "Blue"; h < 290f -> "Violet"; h < 335f -> "Pink"; else -> "Red"
    }
}

/**
 * Chip labels for folder paths: the last segment, or as many trailing segments as it takes to tell
 * a path from every other one ("…/scripts/demo"), so two folders never read the same.
 */
internal fun folderChipLabels(paths: List<String>): Map<String, String> {
    val parts = paths.associateWith { p -> p.trimEnd('/').split('/').filter { it.isNotEmpty() } }
    fun tail(p: String, k: Int) = parts.getValue(p).takeLast(k).joinToString("/")
    return paths.associateWith { p ->
        val segments = parts.getValue(p)
        if (segments.isEmpty()) return@associateWith p.ifEmpty { "/" }
        var k = 1
        while (k < segments.size && paths.any { o -> o != p && tail(o, k) == tail(p, k) }) k++
        if (k >= segments.size) p.trimEnd('/').ifEmpty { "/" } else (if (k > 1) "…/" else "") + tail(p, k)
    }
}

/** A tappable list row: leading icon, title, optional trailing chevron (S15). */
@Composable
internal fun ActionRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, enabled: Boolean = true,
    tint: Color = Color.Unspecified, chevron: Boolean = true, inset: androidx.compose.ui.unit.Dp = 16.dp, onClick: () -> Unit) =
    ActionRow(androidx.compose.ui.graphics.vector.rememberVectorPainter(icon), title, enabled, tint, chevron, inset, onClick)

@Composable
internal fun ActionRow(icon: androidx.compose.ui.graphics.painter.Painter, title: String, enabled: Boolean = true,
    tint: Color = Color.Unspecified, chevron: Boolean = true, inset: androidx.compose.ui.unit.Dp = 16.dp, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val ink = (if (tint == Color.Unspecified) colors.onSurface else tint).let { if (enabled) it else it.copy(alpha = .38f) }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .nameOnly(title).padding(horizontal = inset, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Icon(icon, contentDescription = null, tint = if (tint == Color.Unspecified) colors.onSurfaceVariant.let { if (enabled) it else it.copy(alpha = .38f) } else ink,
            modifier = Modifier.size(22.dp))
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = ink)
        if (chevron) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.onSurfaceVariant)
    }
}

/**
 * Add-workspace suggestions worth offering: folders tied to an open workspace (the folder, one of
 * its parents or one inside it) always stay; folders known only from closed workspaces go, since
 * the host can't vouch they still exist.
 */
internal fun freshFolderSuggestions(suggestions: List<String>, workspaces: List<Workspace>): List<String> {
    fun norm(p: String) = p.trimEnd('/')
    fun related(a: String, b: String) = norm(a) == norm(b) || norm(a).startsWith(norm(b) + "/") || norm(b).startsWith(norm(a) + "/")
    val open = workspaces.filter { it.open && it.path.isNotEmpty() }.map { it.path }
    val closed = workspaces.filter { !it.open && it.path.isNotEmpty() }.map { it.path }
    return suggestions.filter { s -> open.any { related(s, it) } || closed.none { related(s, it) } }.distinctBy(::norm)
}

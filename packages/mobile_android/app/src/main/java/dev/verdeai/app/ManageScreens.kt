package dev.verdeai.app

import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
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
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } })
        LazyColumn(Modifier.fillMaxSize().testTag(MANAGE_LIST), content = content)
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
    val labels = workspaces.associate { it.workspace_id to it.label }
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
    val now = rememberNow(false)
    ManageFrame("History", onBack) {
        if (!ready(state)) return@ManageFrame
        item(key = "search") {
            BasicTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag(HISTORY_SEARCH),
                singleLine = true, textStyle = MaterialTheme.typography.bodyLarge.copy(color = VerdeColors.Text),
                cursorBrush = SolidColor(VerdeColors.Accent), decorationBox = { field ->
                    Column {
                        Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(vertical = 12.dp)) {
                            if (query.isEmpty()) Text("Search chats", color = VerdeColors.Subtle)
                            field()
                        }
                        HorizontalDivider(color = VerdeColors.Border)
                    }
                })
        }
        if (workspaces.size > 1) item(key = "filters") {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item { FilterChip(filter == null, { filter = null }, label = { Text("All") }) }
                items(workspaces, key = { it.workspace_id }) { ws ->
                    FilterChip(filter == ws.workspace_id, { filter = if (filter == ws.workspace_id) null else ws.workspace_id },
                        label = { Text(ws.label, maxLines = 1, overflow = TextOverflow.Ellipsis) })
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
                    modifier = Modifier.fillMaxWidth().clickable(onClickLabel = "Open") { onOpenThread(thread) })
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
private fun Picker(label: String, value: String, choices: List<ChatChoice>, enabled: Boolean, providerIcons: Boolean = false, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Box {
            OutlinedButton(shape = MaterialTheme.shapes.small, onClick = { open = true }, enabled = enabled && choices.isNotEmpty(), modifier = Modifier.fillMaxWidth().testTag("picker:$label")) {
                if (providerIcons) {
                    ProviderGlyph(choices.find { it.label == value }?.id ?: value)
                    Spacer(Modifier.width(8.dp))
                }
                Text(value, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
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
    onBack: () -> Unit,
) {
    val state by browse.state.collectAsState()
    val manageState by manage.state.collectAsState()
    val open = state.workspaces?.items.orEmpty().filter { it.open }
    var workspaceId by rememberSaveable { mutableStateOf(initialWorkspace) }
    LaunchedEffect(open.map { it.workspace_id }) {
        if (workspaceId == null || open.none { it.workspace_id == workspaceId }) workspaceId = initialWorkspace?.takeIf { id -> open.any { it.workspace_id == id } }
            ?: open.firstOrNull()?.workspace_id
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
            line("no-workspaces", "Add a workspace first.")
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
            Picker("Model", label(catalogs.models, selection.model, "Default"), catalogs.models, chat != null && !busy) {
                manage.select(ws, selection.copy(model=it))
            }
        }
        if (catalogs.efforts.isNotEmpty()) item(key = "effort") {
            Picker("Effort", label(catalogs.efforts, selection.effort, "Default"), catalogs.efforts, chat != null && !busy) {
                manage.select(ws, selection.copy(effort=it))
            }
        }
        if (catalogs.access.isNotEmpty()) item(key = "access") {
            Picker("Access", label(catalogs.access, selection.access, "Default"), catalogs.access, chat != null && !busy) {
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
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
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
        section("Browse folders")
        if (directory == null) return@ManageFrame
        if (!directory.supported) {
            line("browse-unsupported", "Update Verde on the computer to browse folders. You can still type a path.")
            return@ManageFrame
        }
        if (directory.suggestions.isNotEmpty()) item(key = "suggestions") {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(directory.suggestions, key = { it }) { root ->
                    AssistChip(onClick = { manage.listDirectory(root) }, label = { Text(root, maxLines = 1, overflow = TextOverflow.Ellipsis) })
                }
            }
        }
        if (directory.path.isNotEmpty()) item(key = "current") {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(directory.path, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                TextButton(onClick = { path = directory.path }, enabled = directory.error == null && !directory.loading) { Text("Use this folder") }
            }
        }
        directory.error?.let { line("browse-error", it.message, error = true) }
        if (directory.loading) progress("browse-loading")
        directory.parent?.let { parent ->
            item(key = "parent") {
                VerdeListRow(headlineContent = { Text("..") }, supportingContent = { Text("Up one folder") },
                    modifier = Modifier.fillMaxWidth().clickable { manage.listDirectory(parent) })
            }
        }
        items(directory.entries, key = { "dir:" + it.path }) { entry ->
            VerdeListRow(headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                modifier = Modifier.fillMaxWidth().clickable(onClickLabel = "Browse") { manage.listDirectory(entry.path) })
        }
        if (!directory.loading && directory.error == null && directory.entries.isEmpty() && directory.path.isNotEmpty()) line("browse-empty", "No folders here.")
    }
}

// ---- Workspace actions ----

/** New chat, rename and close/reopen for one workspace, with the latest result under the buttons. */
@Composable
internal fun WorkspaceActions(state: BrowseState, manage: ManageModel, workspace: Workspace, onNewChat: () -> Unit) {
    val manageState by manage.state.collectAsState()
    var intent by rememberSaveable(workspace.workspace_id) { mutableStateOf<String?>(null) }
    var renaming by rememberSaveable(workspace.workspace_id) { mutableStateOf(false) }
    var closing by rememberSaveable(workspace.workspace_id) { mutableStateOf(false) }
    val result = outcome(manageState, intent)
    val busy = result == JobOutcome.Pending
    val canManage = manageState.view?.can_manage_workspaces == true && !busy
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (workspace.open) TextButton(onClick = onNewChat, enabled = manageState.view?.can_create_threads == true) { Text("New chat") }
            TextButton(onClick = { renaming = true }, enabled = canManage) { Text("Rename") }
            if (workspace.open) TextButton(onClick = { closing = true }, enabled = canManage) { Text("Close") }
            else TextButton(onClick = { intent = manage.setArchived(workspace.workspace_id, false) }, enabled = canManage) { Text("Reopen") }
        }
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
        AlertDialog(onDismissRequest = { closing = false }, title = { Text("Close ${workspace.label}?") },
            text = { Text("Verde stops this workspace's terminals and moves it to Closed. Its chats stay in history, and you can reopen it later.") },
            confirmButton = { TextButton(onClick = { closing = false; intent = manage.close(workspace.workspace_id) }) { Text("Close workspace") } },
            dismissButton = { TextButton(onClick = { closing = false }) { Text("Cancel") } })
    }
}

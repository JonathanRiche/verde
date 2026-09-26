package dev.verdeai.app

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*
import kotlinx.coroutines.delay

/** Wall clock for elapsed timers; tests pass a fixed clock with ticking disabled. */
internal class UiClock(val now: () -> Long = System::currentTimeMillis, val ticking: Boolean = true)
internal const val BROWSE_LIST = "browse-list"
internal val LocalUiClock = staticCompositionLocalOf { UiClock() }

@Composable
internal fun rememberNow(enabled: Boolean): Long {
    val clock = LocalUiClock.current
    val now by produceState(clock.now(), enabled, clock) {
        value = clock.now()
        while (enabled && clock.ticking) { delay(1_000); value = clock.now() }
    }
    return now
}

// ---- Pure presentation rules (unit tested) ----

internal fun statusLabel(status: String): String = when (status) {
    "waiting_approval" -> "Needs approval"
    "waiting" -> "Waiting"
    "working", "running", "accepted" -> "Working"
    "idle" -> "Idle"
    "exited" -> "Exited"
    "unavailable" -> "Unavailable"
    "completed" -> "Done"
    "failed" -> "Failed"
    "aborted", "cancelled" -> "Stopped"
    else -> status.replace('_', ' ').replaceFirstChar { it.uppercase() }
}

/** K-17 attention reason shown as a badge; null when the core reports none. */
internal fun attentionLabel(kind: String?): String? = when (kind) {
    null -> null
    "unread" -> "Unread"
    "needs_approval" -> "Needs approval"
    "blocked" -> "Blocked"
    "failed" -> "Failed"
    else -> kind.replace('_', ' ').replaceFirstChar { it.uppercase() }
}

internal fun paneLabel(pane: Pane): String = when {
    pane.kind == "terminal" && pane.status == "working" -> "Running"
    else -> statusLabel(pane.status)
}

internal fun elapsedLabel(startMs: Long, nowMs: Long): String {
    val total = ((nowMs - startMs).coerceAtLeast(0)) / 1000
    val h = total / 3600; val m = (total % 3600) / 60; val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

internal fun agoLabel(thenMs: Long, nowMs: Long): String {
    val minutes = (nowMs - thenMs).coerceAtLeast(0) / 60_000
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "$minutes min ago"
        minutes < 24 * 60 -> "${minutes / 60} h ago"
        else -> "${minutes / (24 * 60)} d ago"
    }
}

internal fun paneLine(pane: Pane, nowMs: Long): String {
    val kind = when (pane.kind) { "terminal" -> "Terminal"; "browser" -> "Browser"; else -> "Chat" }
    val timer = pane.started_at_ms?.takeIf { pane.can_stop }?.let { " · ${elapsedLabel(it, nowMs)}" } ?: ""
    return "$kind · ${paneLabel(pane)}$timer"
}

internal fun subagent(thread: ThreadSummary) = thread.thread_id.startsWith("subagent:")

/** Most recent non-archived top-level chats from the core's history projection. */
internal fun recentThreads(workspaces: WorkspacesView?, limit: Int = 8): List<ThreadSummary> =
    workspaces?.history?.items.orEmpty().filter { !it.archived && !subagent(it) }.take(limit)

internal fun workspaceThreads(workspace: Workspace): List<ThreadSummary> =
    workspace.threads.filter { !subagent(it) }.sortedWith(compareByDescending<ThreadSummary> { it.last_activity_at_ms ?: 0 }.thenBy { it.thread_id })

internal fun openable(pane: Pane) = when (pane.kind) {
    "chat" -> pane.thread_id != null
    "terminal" -> pane.terminal_id != null
    else -> false
}

internal enum class BannerAction { Retry, Hosts }
internal data class Banner(val text: String, val action: BannerAction? = null, val error: Boolean = false, val busy: Boolean = false)

/** Cached views, or a live projection backed by at least one snapshot. */
internal fun hasContent(state: BrowseState) = state.hasData &&
    (state.savedAtMs != null || state.host?.sync_state in setOf("ready", "stale"))

internal fun showSpinner(state: BrowseState): Boolean {
    val host = state.host ?: return !state.fatal
    return state.networkAvailable && !state.fatal && state.row?.fatal != true &&
        host.phase != "failed" && host.error == null && host.trust_proposal == null && !host.update_required
}

internal fun needsPairing(state: BrowseState) = state.host?.auth_state in setOf("unpaired", "signed_out", "signing_out")

internal fun browseBanner(state: BrowseState, nowMs: Long): Banner? {
    val host = state.host
    val saved = state.savedAtMs?.let { " Showing saved data from ${agoLabel(it, nowMs)}." } ?: ""
    return when {
        state.fatal || state.row?.fatal == true -> Banner("Connection unavailable — reopen Verde.", error=true)
        host == null || host.auth_state == "loading" -> if (state.savedAtMs != null) Banner("Loading.$saved", busy=true) else null
        needsPairing(state) -> null
        host.auth_state == "repair_required" -> Banner("Pair again — device authorization needs renewal.", BannerAction.Hosts, error=true)
        host.trust_proposal != null -> Banner("Review this host's identity before connecting.", BannerAction.Hosts, error=true)
        host.update_required -> Banner("Update required — update Verde on this phone or host.", error=true)
        !state.networkAvailable -> Banner("You're offline.$saved", error=true)
        host.phase == "failed" || host.error?.failure_kind == "network" ->
            Banner("Can't reach ${host.label}. Is Tailscale on?$saved", BannerAction.Retry, error=true)
        state.home?.error != null || state.workspaces?.error != null ->
            Banner("Couldn't load the latest data. Pull down to retry.$saved", BannerAction.Retry, error=true)
        host.phase != "ready" -> Banner("Connecting…$saved", busy=true)
        state.savedAtMs != null -> Banner("Updating…$saved", busy=true)
        state.home?.incomplete_scopes?.isNotEmpty() == true -> Banner("Some host data is still loading.")
        else -> null
    }
}

// ---- Shared pieces ----

@Composable
internal fun statusColor(status: String, attention: Boolean): Color {
    val colors = MaterialTheme.colorScheme
    return when {
        attention || status == "waiting_approval" -> colors.error
        status in setOf("working", "running", "accepted", "waiting") -> colors.primary
        else -> colors.outline
    }
}

@Composable
private fun Dot(color: Color, description: String) {
    Box(Modifier.size(10.dp).background(color, CircleShape).semantics { contentDescription = description })
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MenuRow(
    headline: String,
    supporting: String?,
    enabled: Boolean,
    onOpen: () -> Unit,
    menu: List<Pair<String, () -> Unit>>,
    leading: (@Composable () -> Unit)? = null,
    badge: String? = null,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ListItem(
            headlineContent = { Text(headline, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            supportingContent = supporting?.let { { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) } },
            leadingContent = leading,
            trailingContent = badge?.let { { AttentionBadge(it) } },
            modifier = Modifier.fillMaxWidth().combinedClickable(
                enabled = enabled || menu.isNotEmpty(),
                onClickLabel = "Open", onLongClickLabel = "More actions",
                onClick = { if (enabled) onOpen() else if (menu.isNotEmpty()) expanded = true },
                onLongClick = { if (menu.isNotEmpty()) expanded = true }),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            menu.forEach { (label, action) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { expanded = false; action() })
            }
        }
    }
}

@Composable
private fun AttentionBadge(text: String) {
    Badge(containerColor = MaterialTheme.colorScheme.errorContainer, contentColor = MaterialTheme.colorScheme.onErrorContainer) {
        Text(text, Modifier.padding(horizontal = 4.dp))
    }
}

@Composable
private fun PaneItem(pane: Pane, now: Long, onOpen: (Pane) -> Unit) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val canOpen = openable(pane)
    val menu = buildList {
        if (canOpen) add("Open" to { onOpen(pane) })
        add("Copy title" to { clipboard.setText(AnnotatedString(pane.title)) })
    }
    MenuRow(pane.title, paneLine(pane, now), canOpen, { onOpen(pane) }, menu,
        leading = { Dot(statusColor(pane.status, pane.attention), paneLabel(pane)) },
        badge = attentionLabel(pane.attention_kind))
}

@Composable
private fun ThreadItem(thread: ThreadSummary, now: Long, workspaceLabel: String?, onOpen: (ThreadSummary) -> Unit) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val parts = listOfNotNull(workspaceLabel, statusLabel(thread.status).takeIf { thread.status != "idle" },
        thread.last_activity_at_ms?.let { agoLabel(it, now) })
    MenuRow(thread.title, parts.joinToString(" · ").ifEmpty { null }, true, { onOpen(thread) },
        listOf("Open" to { onOpen(thread) }, "Copy title" to { clipboard.setText(AnnotatedString(thread.title)) }),
        leading = { Dot(statusColor(thread.status, thread.status == "waiting_approval"), statusLabel(thread.status)) })
}

private fun LazyListScope.header(text: String) {
    item(key = "header:$text") {
        Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp))
    }
}

private fun LazyListScope.note(key: String, text: String) {
    item(key = key) { Text(text, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodyMedium) }
}

/** Title, host status, banner and pull-to-refresh shared by the browse screens. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BrowseFrame(
    title: String,
    state: BrowseState,
    now: Long,
    onRefresh: () -> Unit,
    onHosts: () -> Unit,
    onBack: (() -> Unit)? = null,
    content: LazyListScope.() -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        if (onBack != null) {
            TopAppBar(title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } })
        }
        PullToRefreshBox(isRefreshing = state.refreshing, onRefresh = onRefresh, modifier = Modifier.fillMaxSize()) {
            LazyColumn(Modifier.fillMaxSize().testTag(BROWSE_LIST)) {
                if (onBack == null) item(key = "title") {
                    Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp)) {
                        Text(title, style = MaterialTheme.typography.headlineLarge)
                        state.row?.let { row ->
                            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                val status = hostStatus(row)
                                Dot(hostDotColor(row), status)
                                Text("${row.saved.label} · $status", style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                }
                browseBanner(state, now)?.let { banner ->
                    item(key = "banner") {
                        Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                            colors = CardDefaults.cardColors(containerColor =
                                if (banner.error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer)) {
                            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(banner.text)
                                if (banner.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                                when (banner.action) {
                                    BannerAction.Retry -> TextButton(onClick = onRefresh, enabled = !state.refreshing) { Text("Retry") }
                                    BannerAction.Hosts -> TextButton(onClick = onHosts) { Text("Open hosts") }
                                    null -> Unit
                                }
                            }
                        }
                    }
                }
                content()
            }
        }
    }
}

/** Shared host-level gates; returns true when the caller should render its own content. */
private fun LazyListScope.gate(state: BrowseState, onPair: () -> Unit): Boolean {
    when {
        state.hostId == null -> {
            note("no-host", "No host selected.")
            item(key = "choose") { TextButton(onClick = onPair, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Choose a host") } }
        }
        needsPairing(state) -> {
            note("unpaired", "This phone isn't paired with ${state.row?.saved?.label ?: "this host"} yet.")
            item(key = "pair") { Button(onClick = onPair, modifier = Modifier.padding(horizontal = 16.dp)) { Text("Pair with this host") } }
        }
        !hasContent(state) -> {
            if (showSpinner(state)) item(key = "loading") {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator()
                    Text("Loading workspaces…")
                }
            } else note("nodata", "No data yet. Pull down to retry when the host is reachable.")
        }
        else -> return true
    }
    return false
}

// ---- Screens ----

@Composable
internal fun HomeScreen(
    model: BrowseModel,
    onOpenPane: (Pane) -> Unit,
    onOpenThread: (ThreadSummary) -> Unit,
    onOpenWorkspace: (String) -> Unit,
    onHosts: () -> Unit,
    onPair: () -> Unit,
) {
    val state by model.state.collectAsState()
    val panes = state.home?.items.orEmpty()
    val now = rememberNow(panes.any { it.can_stop && it.started_at_ms != null })
    BrowseFrame("Home", state, now, model::refresh, onHosts) {
        if (!gate(state, onPair)) return@BrowseFrame
        val attention = panes.filter { it.attention }
        val running = panes.filterNot { it.attention }
        if (attention.isNotEmpty()) {
            header("Needs attention")
            items(attention, key = { "attention:" + it.id }) { PaneItem(it, now, onOpenPane) }
        }
        if (running.isNotEmpty()) {
            header("Running")
            items(running, key = { "running:" + it.id }) { PaneItem(it, now, onOpenPane) }
        }
        if (panes.isEmpty()) note("idle", "Nothing is running or waiting on you.")
        val labels = state.workspaces?.items.orEmpty().associate { it.workspace_id to it.label }
        val recent = recentThreads(state.workspaces)
        if (recent.isNotEmpty()) {
            header("Recent chats")
            items(recent, key = { "recent:${it.workspace_id}:${it.thread_id}" }) { ThreadItem(it, now, labels[it.workspace_id], onOpenThread) }
        }
        val open = state.workspaces?.items.orEmpty().filter { it.open }
        if (open.isNotEmpty()) {
            header("Workspaces")
            items(open, key = { "workspace:" + it.workspace_id }) { WorkspaceItem(it, onOpenWorkspace) }
        } else if (state.workspaces != null) note("noworkspaces", "No workspaces on this host yet. Add one from Verde on your computer.")
    }
}

@Composable
private fun WorkspaceItem(workspace: Workspace, onOpen: (String) -> Unit) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val chats = workspace.threads.count { !subagent(it) && !it.archived }
    val terminals = workspace.panes.count { it.kind == "terminal" && it.terminal_id != null }
    val active = workspace.panes.count { it.attention || it.can_stop || it.status == "working" }
    val flagged = workspace.panes.count { it.attention_kind != null }
    val summary = listOfNotNull(
        "$chats chat${if (chats == 1) "" else "s"}",
        terminals.takeIf { it > 0 }?.let { "$it terminal${if (it == 1) "" else "s"}" },
        active.takeIf { it > 0 }?.let { "$it active" },
        "closed".takeIf { !workspace.open },
    ).joinToString(" · ")
    MenuRow(workspace.label, listOf(summary, workspace.path).filter { it.isNotEmpty() }.joinToString("\n"), true,
        { onOpen(workspace.workspace_id) },
        listOf("Open" to { onOpen(workspace.workspace_id) }, "Copy path" to { clipboard.setText(AnnotatedString(workspace.path)) }),
        leading = { Dot(if (active > 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline, if (active > 0) "Active" else "Idle") },
        badge = flagged.takeIf { it > 0 }?.let { "$it need${if (it == 1) "s" else ""} attention" })
}

@Composable
internal fun WorkspacesScreen(model: BrowseModel, onOpenWorkspace: (String) -> Unit, onHosts: () -> Unit, onPair: () -> Unit) {
    val state by model.state.collectAsState()
    val now = rememberNow(false)
    BrowseFrame("Workspaces", state, now, model::refresh, onHosts) {
        if (!gate(state, onPair)) return@BrowseFrame
        val all = state.workspaces?.items.orEmpty()
        if (all.isEmpty()) { note("empty", "No workspaces on this host yet. Add one from Verde on your computer."); return@BrowseFrame }
        items(all.filter { it.open }, key = { it.workspace_id }) { WorkspaceItem(it, onOpenWorkspace) }
        val closed = all.filterNot { it.open }
        if (closed.isNotEmpty()) {
            header("Closed")
            items(closed, key = { "closed:" + it.workspace_id }) { WorkspaceItem(it, onOpenWorkspace) }
        }
    }
}

@Composable
internal fun WorkspaceScreen(
    model: BrowseModel,
    workspaceId: String,
    onOpenPane: (Pane) -> Unit,
    onOpenThread: (ThreadSummary) -> Unit,
    onHosts: () -> Unit,
    onPair: () -> Unit,
    onNewTerminal: (() -> Unit)? = null,
    onBack: () -> Unit,
) {
    val state by model.state.collectAsState()
    val workspace = state.workspaces?.items?.find { it.workspace_id == workspaceId }
    val now = rememberNow(workspace?.panes.orEmpty().any { it.can_stop && it.started_at_ms != null })
    var showArchived by rememberSaveable(workspaceId) { mutableStateOf(false) }
    BrowseFrame(workspace?.label ?: "Workspace", state, now, model::refresh, onHosts, onBack) {
        if (!gate(state, onPair)) return@BrowseFrame
        if (workspace == null) { note("missing", "This workspace is no longer on the host."); return@BrowseFrame }
        if (workspace.path.isNotEmpty()) note("path", workspace.path)
        header("Panes")
        if (workspace.panes.isEmpty()) note("nopanes", "No open panes.")
        items(workspace.panes, key = { "pane:" + it.id }) { PaneItem(it, now, onOpenPane) }
        if (onNewTerminal != null && canWrite(state.host) && workspace.path.isNotEmpty()) item(key = "new-terminal") {
            TextButton(onClick = onNewTerminal, modifier = Modifier.padding(horizontal = 8.dp)) { Text("New terminal") }
        }
        val threads = workspaceThreads(workspace)
        val (archived, current) = threads.partition { it.archived }
        header("Chats")
        if (current.isEmpty()) note("nochats", "No chats in this workspace yet.")
        items(current, key = { "thread:" + it.thread_id }) { ThreadItem(it, now, null, onOpenThread) }
        if (archived.isNotEmpty()) {
            item(key = "archived-toggle") {
                TextButton(onClick = { showArchived = !showArchived }, modifier = Modifier.padding(horizontal = 8.dp)) {
                    Text(if (showArchived) "Hide archived (${archived.size})" else "Show archived (${archived.size})")
                }
            }
            if (showArchived) items(archived, key = { "archived:" + it.thread_id }) { ThreadItem(it, now, null, onOpenThread) }
        }
    }
}


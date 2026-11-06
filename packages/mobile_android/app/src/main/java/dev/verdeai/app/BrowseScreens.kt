package dev.verdeai.app

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.ui.res.painterResource
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.withStyle
import dev.verdeai.core.*
import kotlinx.coroutines.delay

/** Wall clock for elapsed timers; tests pass a fixed clock with ticking disabled. */
internal class UiClock(val now: () -> Long = System::currentTimeMillis, val ticking: Boolean = true)
internal const val BROWSE_LIST = "browse-list"
internal val LocalUiClock = staticCompositionLocalOf { UiClock() }

@Composable
internal fun rememberNow(enabled: Boolean, everyMs: Long = 1_000): Long {
    val clock = LocalUiClock.current
    val now by produceState(clock.now(), enabled, everyMs, clock) {
        value = clock.now()
        while (enabled && clock.ticking) { delay(everyMs); value = clock.now() }
    }
    return now
}

/** A2-9: list screens tick each second while a timer runs, else every 30 s so "12 min ago" stays true. */
@Composable
internal fun rememberListNow(timers: Boolean): Long = rememberNow(true, if (timers) 1_000 else 30_000)

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

/** S26: a pane is "Running" while its turn or process is live (not merely open, done or unread). */
internal fun homeRunning(pane: Pane): Boolean = activeStatus(pane.status) || (pane.kind == "terminal" && pane.status in setOf("working", "running"))

internal fun subagent(thread: ThreadSummary) = thread.thread_id.startsWith("subagent:")

/** Chat lists match the desktop sidebar: a draft that never sent a message stays hidden unless a turn is live. */
internal fun listed(thread: ThreadSummary) = !subagent(thread) && (thread.committed || activeTurn(thread.status))

/**
 * Thread ids the chat lists leave out: the companions' conversations ([companionThreadIds]),
 * reached through the companion bubble instead. Provided by the app shell.
 */
internal val LocalHiddenThreads = compositionLocalOf { emptySet<String>() }

/** A chat pane for one of [hidden]'s threads. */
internal fun hiddenPane(pane: Pane, hidden: Set<String>) = pane.kind == "chat" && pane.thread_id != null && pane.thread_id in hidden

/** Use the live catalog: history belongs to the independently filtered, paged search screen. */
internal fun recentThreads(workspaces: WorkspacesView?, limit: Int = 8, hidden: Set<String> = emptySet()): List<ThreadSummary> =
    // S14: chats of closed workspaces aren't "recent".
    workspaces?.items.orEmpty().filter { it.open }.flatMap { it.threads }
        .filter { !it.archived && listed(it) && it.thread_id !in hidden }
        .sortedWith(compareByDescending<ThreadSummary> { it.last_activity_at_ms ?: 0L }
            .thenBy { it.workspace_id }.thenBy { it.thread_id })
        .take(limit)

/**
 * S14: workspace names as lists show them. A name several workspaces share gets the parent folder
 * that tells them apart ("scripts · …/demo"); identical paths get a number.
 */
internal fun workspaceLabels(items: List<Workspace>): Map<String, String> {
    val out = HashMap<String, String>()
    items.groupBy { it.label }.forEach { (label, group) ->
        if (group.size == 1) { out[group.single().workspace_id] = label; return@forEach }
        val parents = group.map { it.path.trimEnd('/').substringBeforeLast('/', "") }
        val tails = folderChipLabels(parents.distinct())
        val seen = HashMap<String, Int>()
        group.forEachIndexed { i, ws ->
            val parent = parents[i]
            // "label · parent folder": the shortest distinguishing tail, never a raw "…/" path.
            val tail = (tails[parent] ?: parent).removePrefix("…/").trimStart('/').ifEmpty { "/" }
            val base = if (parent.isEmpty()) label else "$label · $tail"
            val n = (seen[base] ?: 0) + 1
            seen[base] = n
            out[ws.workspace_id] = if (n == 1) base else "$base ($n)"
        }
    }
    return out
}

internal val LocalWorkspaceLabels = compositionLocalOf<Map<String, String>> { emptyMap() }

/** The workspace's name as lists show it ([workspaceLabels]); its own label outside a list. */
/** S34: the folder that tells each workspace apart: its parent's name, more of it only when labels collide. */
internal fun workspaceParents(items: List<Workspace>): Map<String, String> {
    val labels = workspaceLabels(items)
    return items.associate { ws ->
        val named = labels[ws.workspace_id]?.takeIf { it != ws.label }?.substringAfter(" \u00b7 ", "")
        ws.workspace_id to (named?.takeIf { it.isNotEmpty() } ?: basename(ws.path.trimEnd('/').substringBeforeLast('/', "")))
    }
}

@Composable
internal fun workspaceName(ws: Workspace): String = LocalWorkspaceLabels.current[ws.workspace_id] ?: ws.label

internal fun workspaceThreads(workspace: Workspace): List<ThreadSummary> =
    workspace.threads.filter { !subagent(it) }.sortedWith(compareByDescending<ThreadSummary> { it.last_activity_at_ms ?: 0L }.thenBy { it.thread_id })

internal fun openable(pane: Pane) = when (pane.kind) {
    "chat" -> pane.thread_id != null
    "terminal" -> pane.terminal_id != null
    else -> false
}

internal enum class BannerAction { Retry, Hosts }
internal data class Banner(val text: String, val action: BannerAction? = null, val error: Boolean = false, val busy: Boolean = false)

/** Cached views, or a live projection backed by at least one snapshot. */
internal fun hasContent(state: BrowseState) = state.hasData &&
    (state.savedAtMs != null || state.hasSynced || state.host?.sync_state in setOf("ready", "stale") ||
        state.workspaces?.items?.isNotEmpty() == true || state.home?.items?.isNotEmpty() == true)

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
        state.fatal || state.row?.fatal == true -> Banner("Connection unavailable — reopen verde.", error=true)
        host == null || host.auth_state == "loading" -> if (state.savedAtMs != null) Banner("Loading.$saved", busy=true) else null
        needsPairing(state) -> null
        host.auth_state == "repair_required" -> Banner("Pair again — device authorization needs renewal.", BannerAction.Hosts, error=true)
        host.trust_proposal != null -> Banner("Review this host's identity before connecting.", BannerAction.Hosts, error=true)
        host.update_required -> Banner("Update required — update verde on this phone or host.", error=true)
        !state.networkAvailable -> Banner("You're offline.$saved", error=true)
        host.phase == "failed" || host.error?.failure_kind == "network" ->
            Banner("Can't reach ${state.row?.saved?.label ?: host.label}. Is Tailscale on?$saved", BannerAction.Retry, error=true)
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
        status == "failed" -> colors.error
        attention || status == "waiting_approval" -> VerdeColors.Warning
        status in setOf("working", "running", "accepted", "waiting") -> colors.primary
        else -> colors.outline
    }
}

@Composable
private fun Dot(color: Color, description: String, active: Boolean = false) {
    StatusPip(color, description, active, size = 8.dp)
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
    styledSupporting: AnnotatedString? = null,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        VerdeListRow(
            // S7: 16sp titles that take a second line rather than cut off; 13sp "workspace · state · age".
            headlineContent = { Text(headline, maxLines = 2, overflow = TextOverflow.Ellipsis, style = ROW_TITLE) },
            supportingContent = (styledSupporting ?: supporting?.let(::AnnotatedString))?.let { { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, style = ROW_SUBTITLE) } },
            leadingContent = leading,
            trailingContent = badge?.let { { if (it == UNREAD) UnreadDot() else AttentionBadge(it) } },
            // S4: one TalkBack stop that reads "title, subtitle".
            modifier = Modifier.fillMaxWidth().combinedClickable(
                enabled = enabled || menu.isNotEmpty(),
                onClickLabel = "Open", onLongClickLabel = "More actions",
                onClick = { if (enabled) onOpen() else if (menu.isNotEmpty()) expanded = true },
                onLongClick = { if (menu.isNotEmpty()) expanded = true })
                // V: the badge isn't repeated when the subtitle already says it ("Failed").
                .nameOnly(listOfNotNull(headline, (styledSupporting?.text ?: supporting)?.replace('\n', ' '),
                    badge?.takeIf { b -> (styledSupporting?.text ?: supporting)?.contains(b, ignoreCase = true) != true }).joinToString(", ")),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            LiveOverMenu()
            menu.forEach { (label, action) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { expanded = false; action() })
            }
        }
    }
}

internal const val UNREAD = "Unread"

/** S21: an unread finished chat is just a dot (TalkBack: "Unread"), never an amber "needs you". */
@Composable
private fun UnreadDot() {
    Box(Modifier.size(8.dp).background(VerdeColors.Muted, CircleShape))
}

@Composable
private fun AttentionBadge(text: String) {
    // S: failed is the error container; approval / needs-you the amber one.
    val failed = text.contains("fail", ignoreCase = true)
    val colors = MaterialTheme.colorScheme
    Badge(containerColor = if (failed) colors.errorContainer else colors.tertiaryContainer,
        contentColor = if (failed) colors.onErrorContainer else colors.onTertiaryContainer) {
        Text(text, Modifier.padding(horizontal = 4.dp))
    }
}

private fun paneProvider(state: BrowseState, pane: Pane): String? =
    state.workspaces?.items?.find { it.workspace_id == pane.workspace_id }
        ?.let(::workspaceThreads)?.find { it.thread_id == pane.thread_id }?.provider

/** Provider glyph plus the git dot: titles line up whether or not a row has the dot. */
private val HOME_LEADING_WIDTH = 34.dp
private val ROW_TITLE = androidx.compose.ui.text.TextStyle(fontFamily = VerdeSans, fontSize = 16.sp, lineHeight = 22.sp)
private val ROW_SUBTITLE = androidx.compose.ui.text.TextStyle(fontFamily = VerdeSans, fontSize = 13.sp, lineHeight = 18.sp)

/** S7 state colour: working = accent, needs you / waiting = amber, failed = error; done and idle say nothing. */
internal enum class RowState { Working, NeedsYou, Failed, Quiet }

internal fun rowState(status: String, attention: Boolean): RowState = when {
    status == "failed" -> RowState.Failed
    attention || status == "waiting_approval" || status == "waiting" -> RowState.NeedsYou
    status in setOf("working", "running", "accepted") -> RowState.Working
    else -> RowState.Quiet
}

/** "workspace · state · age", leaving out empty parts (no dangling separators); the state is coloured. */
@Composable
private fun stateLine(parts: List<String?>, state: String?, kind: RowState): AnnotatedString {
    val colors = MaterialTheme.colorScheme
    val tint = when (kind) { RowState.Working -> colors.primary; RowState.NeedsYou -> colors.tertiary; RowState.Failed -> colors.error; RowState.Quiet -> null }
    return androidx.compose.ui.text.buildAnnotatedString {
        val shown = parts.filterNotNull().filter { it.isNotBlank() }
        shown.forEachIndexed { i, part ->
            if (i > 0) append(" · ")
            if (part == state && tint != null) withStyle(androidx.compose.ui.text.SpanStyle(color = tint)) { append(part) } else append(part)
        }
    }
}

/** Working rows spin; everything else has no dot (the coloured state text carries it). */
@Composable
private fun RowStateMark(kind: RowState) {
    if (kind == RowState.Working) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun PaneItem(pane: Pane, now: Long, onOpen: (Pane) -> Unit, provider: String? = null) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val canOpen = openable(pane)
    val menu = buildList {
        if (canOpen) add("Open" to { onOpen(pane) })
        add("Copy title" to { clipboard.setText(AnnotatedString(pane.title)) })
    }
    // A5-9: "needs you" is the core's call (C8); an unread finished chat just gets its Unread badge.
    val kind = rowState(pane.status, pane.needs_you)
    val kindLabel = when (pane.kind) { "terminal" -> "Terminal"; "browser" -> "Browser"; else -> "Chat" }
    val timer = pane.started_at_ms?.takeIf { pane.can_stop }?.let { elapsedLabel(it, now) }
    MenuRow(pane.title, paneLine(pane, now), canOpen, { onOpen(pane) }, menu,
        styledSupporting = stateLine(listOf(kindLabel, paneLabel(pane), timer), paneLabel(pane), kind),
        leading = { Row(Modifier.widthIn(min = HOME_LEADING_WIDTH), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            val glyph = Modifier.size(20.dp)
            if (pane.kind == "chat") ProviderGlyph(provider, glyph) else if (pane.provider != null) ProviderGlyph(pane.provider, glyph)
            else Spacer(glyph)
            RowStateMark(kind)
        } },
        badge = attentionLabel(pane.attention_kind))
}

@Composable
private fun ThreadItem(thread: ThreadSummary, now: Long, workspaceLabel: String?, onOpen: (ThreadSummary) -> Unit, unread: Boolean = false) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val kind = rowState(thread.status, false)
    val state = statusLabel(thread.status).takeIf { thread.status !in setOf("idle", "completed") }
    val parts = listOf(workspaceLabel, state, thread.last_activity_at_ms?.let { agoLabel(it, now) })
    MenuRow(thread.title, parts.filterNotNull().joinToString(" · ").ifEmpty { null }, true, { onOpen(thread) },
        listOf("Open" to { onOpen(thread) }, "Copy title" to { clipboard.setText(AnnotatedString(thread.title)) }),
        styledSupporting = stateLine(parts, state, kind).takeIf { it.isNotEmpty() },
        badge = UNREAD.takeIf { unread },
        leading = { Row(Modifier.widthIn(min = HOME_LEADING_WIDTH), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ProviderGlyph(thread.provider, Modifier.size(20.dp))
            GitChangesDot(GitChat(thread.workspace_id, thread.thread_id))
            RowStateMark(kind)
        } })
}

private fun LazyListScope.header(text: String) {
    item(key = "header:$text") {
        VerdeSection(text)
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
    /** r5: an opaque band at the bottom holds the New chat button and the resting bubble, so they never cover row text. */
    band: Boolean = onBack == null && LocalBubbleReserve.current > 0.dp,
    content: LazyListScope.() -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize()) {
        if (onBack != null) {
            VerdeTopBar(title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack, modifier = Modifier.named("Back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null) } })
        }
        PullToRefreshBox(isRefreshing = state.refreshing, onRefresh = onRefresh, modifier = Modifier.fillMaxSize()) {
            // Top-level lists keep their last rows clear of the New chat button and the companion bubble (S1).
            LazyColumn(Modifier.fillMaxSize().testTag(BROWSE_LIST),
                contentPadding = PaddingValues(bottom = if (band) BOTTOM_BAND + 8.dp else 16.dp)) {
                if (onBack == null) item(key = "title") {
                    Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp)) {
                        Text(title, style = MaterialTheme.typography.titleLarge)
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
    if (band) BottomBand(Modifier.align(Alignment.BottomCenter))
    }
}

@Composable
private fun WorkspaceFolderRow(workspace: Workspace, parent: String?) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var menu by remember { mutableStateOf(false) }
    val short = listOfNotNull(parent?.takeIf { it.isNotEmpty() }, basename(workspace.path)).joinToString(" \u00b7 ")
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(short, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = VerdeColors.Muted,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        Box {
            IconButton(onClick = { menu = true }, modifier = Modifier.named("Folder details")) {
                Icon(Icons.Filled.MoreVert, contentDescription = null, tint = VerdeColors.Muted)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                LiveOverMenu()
                Text(workspace.path, Modifier.padding(horizontal = 16.dp, vertical = 8.dp).widthIn(max = 320.dp),
                    style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
                DropdownMenuItem(text = { Text("Copy path") }, onClick = { menu = false; clipboard.setText(AnnotatedString(workspace.path)) })
            }
        }
    }
}

/** r5 (iOS parity): the bottom band's height: the 56dp New chat button / bubble with 16dp around them. */
internal val BOTTOM_BAND = 88.dp

/** An opaque strip under the floating controls: rows scroll beneath it, never beneath the controls. */
@Composable
internal fun BottomBand(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(BOTTOM_BAND).background(MaterialTheme.colorScheme.background).testTag(BOTTOM_BAND_TAG)) {
        HorizontalDivider(color = VerdeColors.Border.copy(alpha = .5f))
    }
}

internal const val BOTTOM_BAND_TAG = "bottom-band"

/** Shared host-level gates; returns true when the caller should render its own content. */
private fun LazyListScope.gate(state: BrowseState, onPair: () -> Unit): Boolean {
    when {
        state.hostId == null -> {
            note("no-host", "No host selected.")
            item(key = "choose") { TextButton(onClick = onPair, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Choose a host") } }
        }
        needsPairing(state) -> {
            note("unpaired", "This phone isn't paired with ${state.row?.saved?.label ?: "this host"} yet.")
            item(key = "pair") { Button(shape = MaterialTheme.shapes.small, onClick = onPair, modifier = Modifier.padding(horizontal = 16.dp)) { Text("Pair with this host") } }
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
    onNewChat: (() -> Unit)? = null,
    onHistory: (() -> Unit)? = null,
) {
    val state by model.state.collectAsState()
    val hidden = LocalHiddenThreads.current
    val panes = state.home?.items.orEmpty()
    val now = rememberListNow(panes.any { it.can_stop && it.started_at_ms != null })
    val docked = LocalWindowTier.current.docked
    Box(Modifier.fillMaxSize()) {
        BrowseFrame("Home", state, now, model::refresh, onHosts, band = onNewChat != null || LocalBubbleReserve.current > 0.dp) {
            if (!gate(state, onPair)) return@BrowseFrame
            // S26: three sections from the core's state. "Needs you" is its needs_you; "Running" is a
            // live turn or process; finished chats sit in "Recent", an unread one with a neutral dot.
            val attention = panes.filter { it.needs_you }
            val running = panes.filter { !it.needs_you && !hiddenPane(it, hidden) && homeRunning(it) }
            if (attention.isNotEmpty()) {
                header("Needs you")
                items(attention, key = { "attention:" + it.id }) { PaneItem(it, now, onOpenPane, paneProvider(state, it)) }
            }
            if (running.isNotEmpty()) {
                header("Running")
                items(running, key = { "running:" + it.id }) { PaneItem(it, now, onOpenPane, paneProvider(state, it)) }
            }
            if (attention.isEmpty() && running.isEmpty()) note("idle", "Nothing is running or waiting on you.")
            val labels = workspaceLabels(state.workspaces?.items.orEmpty())
            val unread = panes.filter { it.attention_kind == "unread" && it.thread_id != null }.map { it.workspace_id to it.thread_id!! }.toSet()
            // Beside the docked sidebar (foldable, tablet) Home keeps a short Recent (S26).
            val recent = recentThreads(state.workspaces, limit = if (docked) 5 else 8, hidden = hidden)
            if (recent.isNotEmpty()) {
                header("Recent")
                items(recent, key = { "recent:${it.workspace_id}:${it.thread_id}" }) {
                    ThreadItem(it, now, labels[it.workspace_id], onOpenThread, unread = (it.workspace_id to it.thread_id) in unread)
                }
                if (onHistory != null) item(key = "history") {
                    NamedButton("All chats", onHistory, Modifier.padding(horizontal = 8.dp))
                }
            }
            val open = state.workspaces?.items.orEmpty().filter { it.open }
            if (open.isNotEmpty()) {
                header("Workspaces")
                val parents = workspaceParents(state.workspaces?.items.orEmpty())
                items(open, key = { "workspace:" + it.workspace_id }) { WorkspaceItem(it, onOpenWorkspace, parents[it.workspace_id]) }
            } else if (state.workspaces != null) note("noworkspaces", "No workspaces on this host yet. Add one from the Workspaces menu.")
        }
        if (onNewChat != null && hasContent(state) && !needsPairing(state) && state.workspaces?.items.orEmpty().any { it.open }) {
            // S29: the FAB's own node is named "New chat" (a Material FAB names only its child text).
            // In the band beside the resting bubble (its side's 56dp + margins), like iOS.
            val bubbleRight = LocalBubbleReserve.current > 0.dp && BubblePrefs.of(LocalContext.current).placement.edge == BubbleEdge.Right
            NamedButton("New chat", onNewChat, Modifier.align(androidx.compose.ui.Alignment.BottomEnd)
                .padding(start = 16.dp, top = 16.dp, bottom = 16.dp, end = if (bubbleRight) 80.dp else 16.dp).heightIn(min = 56.dp),
                container = MaterialTheme.colorScheme.primaryContainer, content = MaterialTheme.colorScheme.onPrimaryContainer,
                shape = RoundedCornerShape(16.dp), padding = PaddingValues(horizontal = 20.dp), shadow = 6.dp)
        }
    }
}

@Composable
private fun WorkspaceItem(workspace: Workspace, onOpen: (String) -> Unit, parent: String? = null) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val chats = workspace.threads.count { listed(it) && !it.archived }
    val terminals = workspace.panes.count { it.kind == "terminal" && it.terminal_id != null }
    val active = workspace.panes.count { it.needs_you || it.can_stop || it.status == "working" }
    val flagged = workspace.panes.count { it.needs_you }
    val summary = listOfNotNull(
        "$chats chat${if (chats == 1) "" else "s"}",
        terminals.takeIf { it > 0 }?.let { "$it terminal${if (it == 1) "" else "s"}" },
        active.takeIf { it > 0 }?.let { "$it active" },
        "closed".takeIf { !workspace.open },
    ).joinToString(" · ")
    // S21: closed workspaces show their name and state, not a stale (often doubled) path.
    // S34: the title is the label; the subtitle the one folder that tells it apart, then its counts.
    // The full path stays on the workspace's own screen.
    MenuRow(workspace.label, listOfNotNull(parent?.takeIf { it.isNotEmpty() }, summary).joinToString(" \u00b7 "), true,
        { onOpen(workspace.workspace_id) },
        listOf("Open" to { onOpen(workspace.workspace_id) }, "Copy path" to { clipboard.setText(AnnotatedString(workspace.path)) }),
        // S27: list rows like iOS and Hosts: the workspace's own icon leads.
        leading = { WorkspaceChip(workspace, 28.dp) },
        badge = flagged.takeIf { it > 0 }?.let { "$it need${if (it == 1) "s" else ""} you" })
}

@Composable
internal fun WorkspacesScreen(model: BrowseModel, onOpenWorkspace: (String) -> Unit, onHosts: () -> Unit, onPair: () -> Unit,
    onNewChat: (() -> Unit)? = null, onHistory: (() -> Unit)? = null, onAddWorkspace: (() -> Unit)? = null) {
    val state by model.state.collectAsState()
    val now = rememberNow(false)
    BrowseFrame("Workspaces", state, now, model::refresh, onHosts) {
        if (!gate(state, onPair)) return@BrowseFrame
        val all = state.workspaces?.items.orEmpty()
        if (all.isEmpty()) {
            note("empty", if (onAddWorkspace != null) "No workspaces on this host yet." else "No workspaces on this host yet. Add one from verde on your computer.")
            if (onAddWorkspace != null) item(key = "add-workspace") {
                ActionRow(painterResource(R.drawable.ic_folder), "Add workspace", tint = MaterialTheme.colorScheme.primary, onClick = onAddWorkspace)
            }
            return@BrowseFrame
        }
        // S27: the same icon rows as iOS (New chat, History, Add workspace), then Open / Closed.
        if (onNewChat != null) item(key = "new-chat") { ActionRow(Icons.Filled.Edit, "New chat", onClick = onNewChat) }
        if (onHistory != null) item(key = "history") { ActionRow(painterResource(R.drawable.ic_schedule), "History", onClick = onHistory) }
        if (onAddWorkspace != null) item(key = "add-workspace") { ActionRow(painterResource(R.drawable.ic_folder), "Add workspace", onClick = onAddWorkspace) }
        header("Open")
        val open = all.filter { it.open }
        if (open.isEmpty()) note("noopen", "No open workspaces.")
        val parents = workspaceParents(all)
        items(open, key = { it.workspace_id }) { WorkspaceItem(it, onOpenWorkspace, parents[it.workspace_id]) }
        val closed = all.filterNot { it.open }
        if (closed.isNotEmpty()) {
            header("Closed")
            items(closed, key = { "closed:" + it.workspace_id }) { WorkspaceItem(it, onOpenWorkspace, parents[it.workspace_id]) }
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
    actions: (@Composable (Workspace) -> Unit)? = null,
    onBack: () -> Unit,
) {
    val state by model.state.collectAsState()
    val workspace = state.workspaces?.items?.find { it.workspace_id == workspaceId }
    val hidden = LocalHiddenThreads.current
    val now = rememberListNow(workspace?.panes.orEmpty().any { it.can_stop && it.started_at_ms != null })
    var showArchived by rememberSaveable(workspaceId) { mutableStateOf(false) }
    BrowseFrame(workspace?.label ?: "Workspace", state, now, model::refresh, onHosts, onBack) {
        if (!gate(state, onPair)) return@BrowseFrame
        if (workspace == null) { note("missing", "This workspace is no longer on the host."); return@BrowseFrame }
        // U: the distinguishing parent and the folder ("demo · project"); the full path only in its menu.
        if (workspace.path.isNotEmpty()) item(key = "path") {
            WorkspaceFolderRow(workspace, workspaceParents(state.workspaces?.items.orEmpty())[workspace.workspace_id])
        }
        if (actions != null) item(key = "actions") { actions(workspace) }
        header("Panes")
        val panes = workspace.panes.filterNot { hiddenPane(it, hidden) }
        if (panes.isEmpty()) note("nopanes", "No open panes.")
        items(panes, key = { "pane:" + it.id }) { PaneItem(it, now, onOpenPane, paneProvider(state, it)) }
        if (onNewTerminal != null && canWrite(state.host) && workspace.path.isNotEmpty()) item(key = "new-terminal") {
            ActionRow(androidx.compose.ui.res.painterResource(R.drawable.ic_tool_terminal), "New terminal",
                tint = MaterialTheme.colorScheme.primary, chevron = false, onClick = onNewTerminal)
        }
        val threads = workspaceThreads(workspace).filter { listed(it) && it.thread_id !in hidden }
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


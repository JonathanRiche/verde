package dev.verdeai.app

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.verdeai.core.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

internal const val TRANSCRIPT_LIST = "transcript-list"
internal const val JUMP_TO_BOTTOM = "Jump to latest"

/** What every item renderer gets: the model (render queries, actions) and shared callbacks. */
internal class TranscriptContext(
    val model: TranscriptModel,
    val now: Long,
    val onCitation: (FileCitation) -> Unit,
    /** The core's active turn start, for running-tool timers; null when idle. */
    val turnStartedAt: Long? = null,
)

/**
 * Per-kind renderers. Later lanes override one entry — D-07 `diff`, D-09 `approval` — via
 * `TranscriptRenderers.Default.copy(...)` without touching grouping, paging or scrolling.
 */
internal data class TranscriptRenderers(
    val message: @Composable (TranscriptItem.Message, TranscriptContext) -> Unit = { item, ctx -> MessageRow(item.row, ctx) },
    val tool: @Composable (TranscriptItem.Tool, TranscriptContext) -> Unit = { item, _ -> ToolCard(item.row, child = false) },
    val toolGroup: @Composable (TranscriptItem.ToolGroup, TranscriptContext) -> Unit = { item, ctx -> ToolGroupCard(item, ctx) },
    val think: @Composable (TranscriptItem.Think, TranscriptContext) -> Unit = { item, ctx -> ThinkCard(item.row, ctx) },
    val diff: @Composable (TranscriptItem.Diff, TranscriptContext) -> Unit = { item, ctx -> DiffCard(item.row, ctx) },
    val notice: @Composable (TranscriptItem.Notice, TranscriptContext) -> Unit = { item, ctx -> NoticeRow(item.row, ctx) },
    val usage: @Composable (TranscriptItem.Usage, TranscriptContext) -> Unit = { item, _ -> UsageCard(item.usage) },
    val working: @Composable (TranscriptItem.Working, TranscriptContext) -> Unit = { item, ctx -> WorkingRow(item, ctx) },
    val approval: @Composable (TranscriptItem.Approval, TranscriptContext) -> Unit = ApprovalRenderer,
) {
    @Composable
    fun Render(item: TranscriptItem, ctx: TranscriptContext) = when (item) {
        is TranscriptItem.Message -> message(item, ctx)
        is TranscriptItem.Tool -> tool(item, ctx)
        is TranscriptItem.ToolGroup -> toolGroup(item, ctx)
        is TranscriptItem.Think -> think(item, ctx)
        is TranscriptItem.Diff -> diff(item, ctx)
        is TranscriptItem.Notice -> notice(item, ctx)
        is TranscriptItem.Usage -> usage(item, ctx)
        is TranscriptItem.Working -> working(item, ctx)
        is TranscriptItem.Approval -> approval(item, ctx)
    }

    companion object { val Default = TranscriptRenderers() }
}

/** Transcript-level banner: host gates first (shared with browse), then this thread's own error. */
internal fun transcriptBanner(state: TranscriptState, nowMs: Long): Banner? {
    val browse = state.browse
    if (state.fatal) return Banner("Connection unavailable — reopen Verde.", error=true)
    if (needsPairing(browse)) return Banner("This phone isn't paired with ${browse.row?.saved?.label ?: "this host"}.", BannerAction.Hosts, error=true)
    browseBanner(browse.copy(home=null, workspaces=null, savedAtMs=null), nowMs)?.let { return it }
    // A failed approval decision also lands in the thread error; the approval card reports it.
    val error = state.thread?.error?.takeIf { it != state.thread?.approval?.error }
    if (error != null) return Banner("Couldn't load this chat. ${error.message}".trim(), BannerAction.Retry, error=true)
    return null
}

internal enum class TranscriptPlaceholder { Loading, Missing, Offline, Empty, Error }

internal fun transcriptPlaceholder(state: TranscriptState): TranscriptPlaceholder? {
    val thread = state.thread
    val host = state.browse.host
    return when {
        thread != null && thread.rows.isNotEmpty() -> null
        thread?.error != null -> TranscriptPlaceholder.Error
        thread != null && !thread.page.loading && state.focusError == null -> TranscriptPlaceholder.Empty
        state.focusError == "thread_unavailable" -> TranscriptPlaceholder.Missing
        state.fatal || !state.browse.networkAvailable || host?.phase == "failed" || needsPairing(state.browse) -> TranscriptPlaceholder.Offline
        else -> TranscriptPlaceholder.Loading
    }
}

/** Navigation entry: one [TranscriptModel] per back-stack entry, bound to the selected host. */
@Composable
internal fun ThreadRoute(hosts: HostsModel, browse: BrowseModel, workspaceId: String, threadId: String, onHosts: () -> Unit,
                         onCitation: (FileCitation) -> Unit = {}, onBack: () -> Unit) {
    val model: TranscriptModel = viewModel(key = "transcript:$workspaceId:$threadId",
        factory = viewModelFactory { initializer { TranscriptModel(hosts, browse.state, workspaceId, threadId) } })
    val browseState by browse.state.collectAsState()
    val title = browseState.workspaces?.items?.find { it.workspace_id == workspaceId }?.threads?.find { it.thread_id == threadId }?.title
    TranscriptScreen(model, title, onBack, onHosts, browse::refresh, onCitation)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TranscriptScreen(
    model: TranscriptModel,
    title: String?,
    onBack: () -> Unit,
    onHosts: () -> Unit,
    onRetryConnection: () -> Unit,
    onCitation: (FileCitation) -> Unit = {},
    renderers: TranscriptRenderers = TranscriptRenderers.Default,
    /** D-08 swaps in the composer; the default is the stop bar. */
    bottomBar: @Composable (TranscriptModel, TranscriptState) -> Unit = { m, s -> StopBar(m, s) },
) {
    val state by model.state.collectAsState()
    DisposableEffect(model) {
        model.setVisible(true)
        onDispose { model.setVisible(false) }
    }
    val items = remember(state.thread) { state.thread?.let(::transcriptItems).orEmpty() }
    val now = rememberNow(state.turn?.started_at_ms != null)
    val context = TranscriptContext(model, now, onCitation, state.turn?.started_at_ms)
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                Column {
                    Text(state.thread?.thread?.title ?: title ?: "Chat", maxLines = 1, overflow = TextOverflow.Ellipsis)
                    state.thread?.thread?.let { t ->
                        Text(listOfNotNull(t.provider, t.model).joinToString(" · "), style = MaterialTheme.typography.labelMedium,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } })
        transcriptBanner(state, now)?.let { banner ->
            BannerCard(banner, onRetry = { if (state.thread?.error != null) model.retry() else onRetryConnection() }, onHosts = onHosts)
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (val placeholder = transcriptPlaceholder(state)) {
                null -> TranscriptList(items, state, context, renderers)
                else -> Placeholder(placeholder, model)
            }
        }
        bottomBar(model, state)
    }
}

@Composable
private fun BannerCard(banner: Banner, onRetry: () -> Unit, onHosts: () -> Unit) {
    Card(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        colors = CardDefaults.cardColors(containerColor =
            if (banner.error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(banner.text)
            if (banner.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            when (banner.action) {
                BannerAction.Retry -> TextButton(onClick = onRetry) { Text("Retry") }
                BannerAction.Hosts -> TextButton(onClick = onHosts) { Text("Open hosts") }
                null -> Unit
            }
        }
    }
}

@Composable
private fun Placeholder(kind: TranscriptPlaceholder, model: TranscriptModel) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        when (kind) {
            TranscriptPlaceholder.Loading -> { CircularProgressIndicator(); Text("Loading conversation…") }
            TranscriptPlaceholder.Missing -> Text("This chat is no longer on the host.")
            TranscriptPlaceholder.Offline -> Text("This conversation will load when the host is reachable.")
            TranscriptPlaceholder.Empty -> Text("No messages yet.")
            TranscriptPlaceholder.Error -> {
                Text("Couldn't load this conversation.")
                Button(onClick = model::retry) { Text("Retry loading") }
            }
        }
    }
}

/** How close (in items) to the oldest loaded row before the next page is requested. */
private const val PREFETCH_ITEMS = 5

@Composable
private fun TranscriptList(items: List<TranscriptItem>, state: TranscriptState, ctx: TranscriptContext, renderers: TranscriptRenderers) {
    // Newest first + reverseLayout: index 0 sits at the bottom, so growth of the streaming row
    // and older pages prepended at the top both leave the reading position alone.
    val reversed = remember(items) { items.asReversed() }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val atBottom by remember { derivedStateOf { list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < 48 } }
    // Follow new output only while the reader is at the bottom; changed by user scrolls only.
    var follow by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(list) {
        // Updated while (and as) a scroll settles, never by an insertion shifting the anchor.
        var moving = false
        snapshotFlow { list.isScrollInProgress to atBottom }.collect { (scrolling, bottom) ->
            if (scrolling || moving) follow = bottom
            moving = scrolling
        }
    }
    val newest = reversed.firstOrNull()?.key
    LaunchedEffect(newest, reversed.size) { if (follow && reversed.isNotEmpty()) list.scrollToItem(0) }
    val page = state.thread?.page
    LaunchedEffect(list, page) {
        snapshotFlow { list.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .distinctUntilChanged()
            .collect { top -> if (top >= list.layoutInfo.totalItemsCount - PREFETCH_ITEMS) ctx.model.loadOlder() }
    }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize().testTag(TRANSCRIPT_LIST), state = list, reverseLayout = true,
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.Bottom)) {
            items(reversed, key = { it.key }, contentType = { it::class }) { item -> renderers.Render(item, ctx) }
            item(key = "page-header", contentType = "header") { PageHeader(page, ctx.model) }
        }
        ApprovalBanner(reversed, list, ctx.model.approvals, Modifier.align(Alignment.TopCenter))
        if (!atBottom && reversed.isNotEmpty()) {
            SmallFloatingActionButton(
                onClick = { follow = true; scope.launch { list.animateScrollToItem(0) } },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
            ) { Icon(Icons.Filled.KeyboardArrowDown, contentDescription = JUMP_TO_BOTTOM) }
        }
    }
}

@Composable
private fun PageHeader(page: ChatPage?, model: TranscriptModel) {
    Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
        when {
            page == null -> Unit
            page.loading -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text("Loading earlier messages…", style = MaterialTheme.typography.bodySmall)
            }
            page.has_older -> TextButton(onClick = { model.loadOlder(force = true) }) { Text("Load earlier messages") }
            else -> Text("Start of conversation", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
        }
    }
}

// ---- Default renderers ----

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun MessageRow(row: ChatRow, ctx: TranscriptContext) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var menu by remember { mutableStateOf(false) }
    val mine = row.role == "user"
    val colors = MaterialTheme.colorScheme
    Box(Modifier.fillMaxWidth(), contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier.fillMaxWidth(if (mine) 0.88f else 1f)
                .background(if (mine) colors.primaryContainer else colors.surfaceContainerLow, RoundedCornerShape(12.dp))
                .combinedClickable(onClick = {}, onLongClickLabel = "Copy message", onLongClick = { menu = true })
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(if (mine) "You" else row.author.ifEmpty { "Assistant" }, style = MaterialTheme.typography.labelMedium,
                    color = colors.onSurfaceVariant)
                deliveryLabel(row.delivery)?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = if (row.delivery == "failed") colors.error else colors.outline)
                }
            }
            if (row.attachments.isNotEmpty()) Attachments(row.attachments)
            if (row.body.isNotEmpty()) {
                // User text is shown verbatim (web parity); assistant output goes through the core AST.
                if (mine) Text(row.body, style = MaterialTheme.typography.bodyMedium)
                else MarkdownText(streamTail(row), ctx.model, ctx.onCitation)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Copy message") }, onClick = { menu = false; clipboard.setText(AnnotatedString(row.body)) })
        }
    }
}

internal fun deliveryLabel(delivery: String) = when (delivery) {
    "optimistic" -> "Sending…"
    "streaming" -> "Streaming"
    "failed" -> "Not sent"
    else -> null
}

/** Streaming bodies re-render per delta; only a bounded tail is sent for markdown until commit. */
internal fun streamTail(row: ChatRow, max: Int = 16_000): String {
    if (row.delivery != "streaming" || row.body.length <= max) return row.body
    val cut = row.body.indexOf('\n', row.body.length - max)
    return if (cut >= 0) row.body.substring(cut + 1) else row.body.takeLast(max)
}

@Composable
private fun Attachments(attachments: List<ChatAttachment>) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        attachments.forEach { a ->
            // Host images need an authenticated fetch the core doesn't offer yet; show the name only.
            AssistChip(onClick = {}, label = { Text((if (a.mime.startsWith("image/")) "Image · " else "") + basename(a.name), maxLines = 1,
                overflow = TextOverflow.Ellipsis) })
        }
    }
}

@Composable
private fun StatusDot(color: Color, description: String) {
    Box(Modifier.size(9.dp).background(color, CircleShape).semantics { contentDescription = description })
}

@Composable
private fun toolColor(row: ChatRow): Color = when {
    commandFailed(row) -> MaterialTheme.colorScheme.error
    commandRunning(row) -> MaterialTheme.colorScheme.primary
    else -> MaterialTheme.colorScheme.outline
}

internal fun toolStatusLabel(row: ChatRow) = when {
    commandFailed(row) -> "Failed"
    commandRunning(row) -> "Running"
    else -> "Completed"
}

private const val TOOL_PREVIEW_LINES = 40

@Composable
internal fun ToolCard(row: ChatRow, child: Boolean) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var expanded by rememberSaveable(row.id) { mutableStateOf(commandFailed(row)) }
    var all by rememberSaveable(row.id + ":all") { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth()
        .border(1.dp, if (commandRunning(row)) colors.primary else colors.outlineVariant, RoundedCornerShape(10.dp))
        .background(if (child) colors.surface else colors.surfaceContainerLow, RoundedCornerShape(10.dp))) {
        Row(Modifier.fillMaxWidth().clickable(onClickLabel = if (expanded) "Collapse" else "Expand") { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(toolColor(row), toolStatusLabel(row))
            Text(row.author.ifEmpty { "Tool" }, style = MaterialTheme.typography.labelLarge)
            Text(commandPreview(row.body), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, maxLines = 1,
                overflow = TextOverflow.Ellipsis, color = colors.onSurfaceVariant)
            Text(if (expanded) "▾" else "▸", color = colors.onSurfaceVariant)
        }
        if (expanded) {
            val total = remember(row.body) { countLines(row.body) }
            val (shown, truncated) = remember(row.body, all) { if (all) row.body.trim() to false else leadingLines(row.body, TOOL_PREVIEW_LINES) }
            Text(shown, Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), softWrap = false)
            Row(Modifier.padding(horizontal = 4.dp)) {
                TextButton(onClick = { clipboard.setText(AnnotatedString(row.body)) }) { Text("Copy output") }
                if (truncated) TextButton(onClick = { all = true }) { Text("Show all $total lines") }
            }
        }
    }
}

@Composable
internal fun ToolGroupCard(item: TranscriptItem.ToolGroup, ctx: TranscriptContext) {
    val counts = remember(item.rows) { toolCounts(item.rows) }
    var expanded by rememberSaveable(item.key) { mutableStateOf(counts.failed > 0) }
    val colors = MaterialTheme.colorScheme
    val elapsed = ctx.turnStartedAt?.let { elapsedLabel(it, ctx.now) }
    Column(Modifier.fillMaxWidth()
        .border(1.dp, if (counts.running > 0 && counts.failed == 0) colors.primary else colors.outlineVariant, RoundedCornerShape(10.dp))
        .background(colors.surfaceContainerLow, RoundedCornerShape(10.dp))) {
        Row(Modifier.fillMaxWidth().clickable(onClickLabel = if (expanded) "Collapse" else "Expand") { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(when { counts.failed > 0 -> colors.error; counts.running > 0 -> colors.primary; else -> colors.outline },
                if (counts.failed > 0) "Some failed" else if (counts.running > 0) "Running" else "Completed")
            Text(toolGroupSummary(item.rows, item.subagent, elapsed), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                maxLines = 1, overflow = TextOverflow.Ellipsis, color = colors.onSurfaceVariant)
            Text(if (expanded) "▾" else "▸", color = colors.onSurfaceVariant)
        }
        if (expanded) Column(Modifier.padding(start = 8.dp, end = 8.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item.rows.forEach { ToolCard(it, child = true) }
        }
    }
}

@Composable
internal fun ThinkCard(row: ChatRow, ctx: TranscriptContext) {
    var expanded by rememberSaveable(row.id) { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().clickable(onClickLabel = if (expanded) "Collapse" else "Expand") { expanded = !expanded }
        .padding(horizontal = 4.dp, vertical = 2.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(if (expanded) "▾" else "▸", style = MaterialTheme.typography.labelMedium, color = colors.outline)
            Text(if (commandRunning(row)) "Thinking…" else "Thought", style = MaterialTheme.typography.labelMedium, color = colors.outline)
        }
        if (expanded && row.body.isNotEmpty()) {
            MarkdownText(streamTail(row), ctx.model, ctx.onCitation, Modifier.padding(start = 12.dp, top = 4.dp))
        }
    }
}

@Composable
internal fun NoticeRow(row: ChatRow, ctx: TranscriptContext) {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().background(colors.secondaryContainer.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
        .padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (row.author.isNotEmpty()) Text(row.author, style = MaterialTheme.typography.labelSmall, color = colors.onSecondaryContainer)
        MarkdownText(row.body, ctx.model, ctx.onCitation)
    }
}

@Composable
internal fun UsageCard(usage: ChatUsage) {
    val colors = MaterialTheme.colorScheme
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("${usage.provider.replaceFirstChar { it.uppercase() }} usage", style = MaterialTheme.typography.titleSmall)
            usage.limits.forEach { limit ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row {
                        Text(limit.label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        Text("${limit.percent_left}% left", style = MaterialTheme.typography.bodySmall)
                    }
                    LinearProgressIndicator(progress = { limit.percent_left.coerceIn(0, 100) / 100f }, Modifier.fillMaxWidth()
                        .semantics { contentDescription = "${limit.label} ${limit.percent_left}% left" })
                    if (limit.reset.isNotEmpty()) Text(limit.reset, style = MaterialTheme.typography.labelSmall, color = colors.outline)
                }
            }
            (usage.stats + usage.recent).forEach { stat ->
                Row {
                    Text(stat.label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                    Text(stat.value, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@Composable
internal fun WorkingRow(item: TranscriptItem.Working, ctx: TranscriptContext) {
    val elapsed = item.turn.started_at_ms?.let { elapsedLabel(it, ctx.now) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
        Text(workingLabel(item, elapsed), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
    }
}

internal const val STOP_BAR = "stop-bar"

/** Default bottom slot until D-08's composer: a Stop button bound to the core's active turn. */
@Composable
internal fun StopBar(model: TranscriptModel, state: TranscriptState) {
    if (state.turn == null) return
    Surface(tonalElevation = 3.dp) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag(STOP_BAR), verticalAlignment = Alignment.CenterVertically) {
            Text(if (state.stopping) "Stopping the current turn…" else "The agent is working.", Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium)
            if (state.stopping) OutlinedButton(onClick = {}, enabled = false) { Text("Stopping…") }
            else Button(onClick = model::stop, enabled = state.canStop,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("Stop") }
        }
    }
}

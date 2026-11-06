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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.ui.draw.rotate
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
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
    /** Known chats (this workspace first), to name child chats in orchestration cards. */
    val threads: List<ThreadSummary> = emptyList(),
    /** Opens another chat in this workspace by thread id; null when navigation is unavailable. */
    val onOpenThread: ((String) -> Unit)? = null,
    val git: GitChangesModel? = null,
)

/**
 * Per-kind renderers. Later lanes override one entry — D-07 `diff`, D-09 `approval` — via
 * `TranscriptRenderers.Default.copy(...)` without touching grouping, paging or scrolling.
 */
internal data class TranscriptRenderers(
    val message: @Composable (TranscriptItem.Message, TranscriptContext) -> Unit = { item, ctx -> MessageRow(item.row, ctx) },
    val tool: @Composable (TranscriptItem.Tool, TranscriptContext) -> Unit = { item, _ -> ToolRow(item.row, child = false) },
    val toolGroup: @Composable (TranscriptItem.ToolGroup, TranscriptContext) -> Unit = { item, ctx -> ToolGroupCard(item, ctx) },
    val think: @Composable (TranscriptItem.Think, TranscriptContext) -> Unit = { item, ctx -> ThinkCard(item.row, ctx) },
    val diff: @Composable (TranscriptItem.Diff, TranscriptContext) -> Unit = { item, ctx -> DiffCard(item.row, ctx) },
    val notice: @Composable (TranscriptItem.Notice, TranscriptContext) -> Unit = { item, ctx -> NoticeRow(item.row, ctx) },
    val usage: @Composable (TranscriptItem.Usage, TranscriptContext) -> Unit = { item, _ -> UsageCard(item.usage) },
    val working: @Composable (TranscriptItem.Working, TranscriptContext) -> Unit = { item, ctx -> WorkingRow(item, ctx) },
    val approval: @Composable (TranscriptItem.Approval, TranscriptContext) -> Unit = ApprovalRenderer,
    val childNotice: @Composable (TranscriptItem.ChildNotice, TranscriptContext) -> Unit = { item, ctx -> ChildNotificationCard(item, ctx) },
    val voice: @Composable (TranscriptItem.Voice, TranscriptContext) -> Unit = { item, ctx -> VoiceBlock(item, ctx, compact = false) },
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
        is TranscriptItem.ChildNotice -> childNotice(item, ctx)
        is TranscriptItem.Voice -> voice(item, ctx)
    }

    companion object { val Default = TranscriptRenderers() }
}

/** Transcript-level banner: host gates first (shared with browse), then this thread's own error. */
internal fun transcriptBanner(state: TranscriptState, nowMs: Long): Banner? {
    val browse = state.browse
    if (state.fatal) return Banner("Connection unavailable — reopen verde.", error=true)
    if (needsPairing(browse)) return Banner("This phone isn't paired with ${browse.row?.saved?.label ?: "this host"}.", BannerAction.Hosts, error=true)
    browseBanner(browse.copy(home=null, workspaces=null, savedAtMs=null), nowMs)?.let { return it }
    // A failed approval decision also lands in the thread error; the approval card reports it.
    val error = state.thread?.error?.takeIf { state.thread?.page?.loading != true && it != state.thread?.approval?.error }
    if (error != null) return Banner("Couldn't load this chat. ${error.message}".trim(), BannerAction.Retry, error=true)
    return null
}

internal enum class TranscriptPlaceholder { Loading, Missing, Offline, Empty, Error }

internal fun transcriptPlaceholder(state: TranscriptState): TranscriptPlaceholder? {
    val thread = state.thread
    val host = state.browse.host
    return when {
        thread != null && thread.rows.isNotEmpty() -> null
        thread?.page?.loading == true -> TranscriptPlaceholder.Loading
        thread?.error != null -> TranscriptPlaceholder.Error
        thread != null && !thread.page.loading && state.focusError == null -> TranscriptPlaceholder.Empty
        state.focusError == "thread_unavailable" -> TranscriptPlaceholder.Missing
        state.fatal || !state.browse.networkAvailable || host?.phase == "failed" || needsPairing(state.browse) -> TranscriptPlaceholder.Offline
        else -> TranscriptPlaceholder.Loading
    }
}

/** Navigation entry: one [TranscriptModel] per back-stack entry, bound to the selected host. */
@Composable
internal fun ThreadRoute(hosts: HostsModel, browse: BrowseModel, manage: ManageModel, workspaceId: String, threadId: String, onHosts: () -> Unit,
                         onCitation: (FileCitation) -> Unit = {}, onThreadAction: (ThreadSummary, String) -> Unit,
                         onOpenThread: ((String) -> Unit)? = null, onBack: () -> Unit) {
    val model: TranscriptModel = viewModel(key = "transcript:$workspaceId:$threadId",
        factory = viewModelFactory { initializer { TranscriptModel(hosts, browse.state, workspaceId, threadId) } })
    val browseState by browse.state.collectAsState()
    val workspaces = browseState.workspaces?.items.orEmpty()
    val threads = workspaces.find { it.workspace_id == workspaceId }?.threads.orEmpty()
    // Child chats may live in another workspace; this workspace's threads win the lookup.
    val knownThreads = threads + workspaces.filter { it.workspace_id != workspaceId }.flatMap { it.threads }
    val title = threads.find { it.thread_id == threadId }?.title
    val manageState by manage.state.collectAsState()
    val gitClient = LocalGitChangesClient.current
    val git = if (gitClient == null) null else viewModel<GitChangesModel>(key = "git:${browseState.hostId}:${System.identityHashCode(gitClient)}:$workspaceId:$threadId",
        factory = viewModelFactory { initializer { GitChangesModel(GitChat(workspaceId, threadId), gitClient) } })
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    LaunchedEffect(git, lifecycleState) { if (lifecycleState == Lifecycle.State.RESUMED) git?.focus() }
    // An "Ask agent" selection from the file or diff viewer arrives with this navigation.
    LaunchedEffect(model) { PromptHandoff.take(browseState.hostId, workspaceId, threadId)?.let(model.composer::ask) }
    TranscriptScreen(model, title, onBack, onHosts, browse::refresh, onCitation,
        canEditThread = manageState.view?.can_create_threads == true, onThreadAction = onThreadAction,
        gitChanges = git, threads = knownThreads, onOpenThread = onOpenThread, bottomBar = { m, s -> ChatComposer(m, s) })
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
    canEditThread: Boolean = false,
    onThreadAction: ((ThreadSummary, String) -> Unit)? = null,
    threads: List<ThreadSummary> = emptyList(),
    onOpenThread: ((String) -> Unit)? = null,
    gitChanges: GitChangesModel? = null,
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
    val context = TranscriptContext(model, now, onCitation, state.turn?.started_at_ms, threads, onOpenThread, gitChanges)
    val openDrawer = LocalWorkspaceMenu.current
    val tier = LocalWindowTier.current
    var chatMenu by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize()) {
        VerdeTopBar(
            title = {
                // S10: [back] [drawer] title over the provider's name … [companion] [⋯], the same on every launch.
                val provider = state.thread?.thread?.provider
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ProviderGlyph(provider)
                    Column {
                        Text(state.thread?.thread?.title ?: title ?: "Chat", maxLines = 1,
                            overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                        provider?.let { id -> Text(PROVIDERS.find { it.first == id }?.second ?: id.replaceFirstChar { it.uppercase() }, maxLines = 1,
                            style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted) }
                    }
                }
            },
            showWorkspaceMenu = false,
            navigationIcon = {
                // Beside a permanent sidebar neither has a job: chats are switched from the list.
                if (!tier.docked) Row {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    openDrawer?.let { open ->
                        IconButton(onClick = open) { Icon(Icons.Filled.Menu, contentDescription = "Open workspace drawer") }
                    }
                }
            },
            actions = {
                // Git actions never sit between the companion and ⋯: they get the row under the header.
                if (onThreadAction != null) Box {
                    val thread = state.thread?.thread
                    IconButton(onClick = { chatMenu = true }, enabled = thread != null) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "Chat actions", modifier = Modifier.rotate(90f))
                    }
                    DropdownMenu(expanded = chatMenu, onDismissRequest = { chatMenu = false }) {
                        LiveOverMenu()
                        listOf("Rename chat" to "rename", "Sync chat" to "sync", "Close chat" to "close").forEach { (label, action) ->
                            DropdownMenuItem(text = { Text(label) },
                                enabled = canEditThread && thread != null &&
                                    (action != "sync" || (!activeStatus(thread.status) && thread.status != "waiting_approval")),
                                onClick = { chatMenu = false; thread?.let { onThreadAction(it, action) } })
                        }
                    }
                }
            })
        gitChanges?.let { GitChangesHeader(it) }
        transcriptBanner(state, now)?.let { banner ->
            BannerCard(banner, onRetry = { if (state.thread?.error != null) model.retry() else onRetryConnection() }, onHosts = onHosts)
        }
        // A-KB: a tap on the transcript (not taken by a control) or a scroll drag puts the keyboard away.
        val dismissKeyboard = rememberKeyboardDismiss()
        Box(Modifier.weight(1f).fillMaxWidth().dismissKeyboardOnTouch(dismissKeyboard)) {
            CompositionLocalProvider(LocalDismissKeyboard provides dismissKeyboard) {
            when (val placeholder = transcriptPlaceholder(state)) {
                null -> TranscriptList(items, state, context, renderers)
                else -> Placeholder(placeholder, model)
            }
            }
        }
        bottomBar(model, state)
    }
    gitChanges?.let { GitChangesLayer(it) }
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
internal fun TranscriptList(items: List<TranscriptItem>, state: TranscriptState, ctx: TranscriptContext, renderers: TranscriptRenderers,
    spacing: Dp = 8.dp, contentPadding: PaddingValues = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
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
    val anchor = remember(list, scope) { DisclosureAnchor(list, scope) }
    val disclosures = rememberSaveable(saver = DisclosureStore.Saver) { DisclosureStore() }
    // A2-6: "Jump to latest" takes its own strip under the transcript instead of floating over text.
    Column(Modifier.fillMaxSize()) {
    Box(Modifier.weight(1f).fillMaxWidth()) {
        CompositionLocalProvider(LocalDisclosureAnchor provides anchor, LocalDisclosureStore provides disclosures) {
        LazyColumn(Modifier.fillMaxSize().testTag(TRANSCRIPT_LIST), state = list, reverseLayout = true,
            contentPadding = contentPadding, verticalArrangement = Arrangement.spacedBy(spacing, Alignment.Bottom)) {
            itemsIndexed(reversed, key = { _, it -> it.key }, contentType = { _, it -> it::class }) { index, item ->
                CompositionLocalProvider(LocalTranscriptIndex provides index) { TranscriptItemFrame(item) { renderers.Render(item, ctx) } }
            }
            item(key = "page-header", contentType = "header") { PageHeader(page, ctx.model) }
        }
        }
        ApprovalBanner(reversed, list, ctx.model.approvals, Modifier.align(Alignment.TopCenter))
    }
    if (!atBottom && reversed.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) {
        FilledTonalButton(onClick = { follow = true; scope.launch { list.animateScrollToItem(0) } },
            contentPadding = PaddingValues(start = 12.dp, end = 16.dp), modifier = Modifier.height(40.dp)
                .semantics { contentDescription = JUMP_TO_BOTTOM }) {
            Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(4.dp))
            Text("Latest", style = MaterialTheme.typography.labelLarge)
        }
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
    var selecting by remember { mutableStateOf(false) }
    val dismissKeyboard = LocalDismissKeyboard.current
    val mine = row.role == "user"
    // Steers from an orchestrating parent agent show only its words, labelled as the parent.
    val steer = remember(row.role, row.body) { parentSteerBody(row.role, row.body) }
    val body = steer ?: row.body
    val colors = MaterialTheme.colorScheme
    Box(Modifier.fillMaxWidth(), contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier.fillMaxWidth()
                .background(when { steer != null -> VerdeColors.Panel; mine -> VerdeColors.UserBubble; else -> VerdeColors.Assistant }, RoundedCornerShape(10.dp))
                .border(1.dp, if (mine) VerdeColors.UserBubble else VerdeColors.Border, RoundedCornerShape(10.dp))
                .combinedClickable(onClick = { dismissKeyboard?.invoke() }, onLongClickLabel = "Message actions", onLongClick = { menu = true })
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (!mine) ProviderGlyph(row.author, Modifier.size(16.dp))
                Text(when { steer != null -> "Parent agent"; mine -> "You"; else -> row.author.ifEmpty { "Assistant" } },
                    style = MaterialTheme.typography.labelMedium, color = if (steer != null) colors.primary else colors.onSurfaceVariant)
                deliveryLabel(row.delivery)?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = if (row.delivery == "failed") colors.error else colors.outline)
                }
            }
            if (row.attachments.isNotEmpty()) AttachmentStrip(row, ctx)
            if (body.isNotEmpty()) {
                // A2-11: prompts and replies share the core's markdown AST (desktop
                // transcriptBodyUsesMarkdown), so `code` and **bold** in a prompt render. It is safe
                // by construction: only http(s)/mailto links are tappable and remote images never load.
                MarkdownText(streamTail(row.copy(body = body)), ctx.model, ctx.onCitation)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            LiveOverMenu()
            DropdownMenuItem(text = { Text("Copy message") }, onClick = { menu = false; clipboard.setText(AnnotatedString(body)) })
            DropdownMenuItem(text = { Text("Select text") }, onClick = { menu = false; selecting = true })
        }
        if (selecting) SelectTextDialog({ MarkdownText(body, ctx.model, ctx.onCitation) }) { selecting = false }
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
internal fun ThinkCard(row: ChatRow, ctx: TranscriptContext) {
    val disclosure = rememberDisclosure("think:" + row.id, false)
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).then(disclosure.track)
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClickLabel = if (disclosure.expanded) "Collapse" else "Expand") { disclosure.toggle() }
            .padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(toolKindPainter(ToolKind.Think), contentDescription = null, tint = colors.outline, modifier = Modifier.size(16.dp))
            Text(if (commandRunning(row)) "Thinking…" else "Thought", style = MaterialTheme.typography.labelMedium, color = colors.outline)
            Chevron(disclosure.expanded)
        }
        if (disclosure.expanded && row.body.isNotEmpty()) {
            MarkdownText(streamTail(row), ctx.model, ctx.onCitation, Modifier.padding(start = 12.dp, top = 4.dp))
        }
    }
}

@Composable
internal fun NoticeRow(row: ChatRow, ctx: TranscriptContext) {
    if (isGitCommitRow(row)) {
        GitCommitNotice(row.body, ctx.git)
        return
    }
    if (isVoiceAuthor(row.author)) {
        VoiceNote(row)
        return
    }
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().background(colors.secondaryContainer.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
        .padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (row.author.isNotEmpty()) Text(row.author, style = MaterialTheme.typography.labelSmall, color = colors.onSecondaryContainer)
        MarkdownText(row.body, ctx.model, ctx.onCitation)
    }
}

@Composable
internal fun childStatusColor(status: ChildStatus): Color = when (status) {
    ChildStatus.Running, ChildStatus.Completed -> MaterialTheme.colorScheme.primary
    ChildStatus.WaitingApproval, ChildStatus.Blocked -> VerdeColors.Warning
    ChildStatus.Failed -> MaterialTheme.colorScheme.error
    ChildStatus.Idle, ChildStatus.Aborted, ChildStatus.Interrupted -> MaterialTheme.colorScheme.outline
}

/**
 * Child results in their orchestrating parent: compact rows (status dot, child title, status,
 * chevron, one-line summary) that expand to the full reply. A batched delivery stacks its rows in
 * one container with thin dividers.
 */
@Composable
internal fun ChildNotificationCard(item: TranscriptItem.ChildNotice, ctx: TranscriptContext) {
    Column(Modifier.fillMaxWidth()
        .background(VerdeColors.Panel, RoundedCornerShape(10.dp))
        .border(1.dp, VerdeColors.Border, RoundedCornerShape(10.dp))) {
        item.notifications.forEachIndexed { index, notification ->
            if (index > 0) HorizontalDivider(thickness = 1.dp, color = VerdeColors.Border)
            ChildResultRow(notification, "${item.key}:child:$index", ctx)
        }
    }
}

/** One child's result: collapsed to a summary line unless the human must act on it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChildResultRow(notification: ChildNotification, key: String, ctx: TranscriptContext) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val child = ctx.threads.find { it.thread_id == notification.childId }
    val title = childTitle(notification.childId, child?.title)
    var menu by remember { mutableStateOf(false) }
    // Keyed per message and child index, so the choice survives scrolling for the screen session.
    val disclosure = rememberDisclosure(key, notification.status.expandedByDefault)
    val expanded = disclosure.expanded
    val summary = remember(notification.reply) { childReplySummary(notification.reply) }
    val colors = MaterialTheme.colorScheme
    val statusColor = childStatusColor(notification.status)
    val open = ctx.onOpenThread?.let { { it(notification.childId) } }
    Box(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().then(disclosure.track)
            .combinedClickable(onClickLabel = if (expanded) "Collapse" else "Expand", onClick = { disclosure.toggle() },
                onLongClickLabel = "Copy reply", onLongClick = { menu = true })
            .padding(start = 12.dp, end = 8.dp, top = 8.dp, bottom = if (expanded) 4.dp else 8.dp)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 28.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatusPip(statusColor, size = 8.dp, active = notification.status == ChildStatus.Running)
                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(notification.status.label, style = MaterialTheme.typography.labelMedium, color = statusColor, maxLines = 1)
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = colors.onSurfaceVariant,
                    modifier = Modifier.size(20.dp).rotate(if (expanded) 180f else 0f))
            }
            if (!expanded) {
                Text(summary.ifEmpty { "No reply" }, Modifier.padding(start = 16.dp, end = 4.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (summary.isEmpty()) colors.outline else colors.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else {
                Column(Modifier.fillMaxWidth().padding(top = 4.dp, end = 4.dp)) {
                    val text = notification.reply.trim()
                    if (text.isNotEmpty()) MarkdownText(text, ctx.model, ctx.onCitation)
                    else Text("No reply", style = MaterialTheme.typography.bodySmall, color = colors.outline)
                }
                if (open != null) TextButton(onClick = open, Modifier.align(Alignment.End), contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Text("Open chat", style = MaterialTheme.typography.labelMedium)
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            LiveOverMenu()
            DropdownMenuItem(text = { Text("Copy reply") }, onClick = { menu = false; clipboard.setText(AnnotatedString(notification.reply.trim())) })
        }
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
        // S13: waiting on the user is amber (dot and text); working is the accent.
        val tint = if (item.waitingApproval && !item.turn.stop_pending) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary
        StatusPip(tint, active = true, size = 8.dp, command = true)
        Text(workingLabel(item, elapsed), style = MaterialTheme.typography.labelMedium, color = tint)
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

/** The whole message, rendered (A2-7: no markdown marks) and selectable, for copying part of it. */
@Composable
private fun SelectTextDialog(content: @Composable () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text("Select text") },
        text = {
            Box(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                androidx.compose.foundation.text.selection.SelectionContainer { content() }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } })
}

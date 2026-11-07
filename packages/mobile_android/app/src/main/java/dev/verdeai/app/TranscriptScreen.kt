package dev.verdeai.app

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.isShiftPressed
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
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.focus.focusProperties
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
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
internal const val LATEST_STRIP = "latest-strip"

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
    val background: @Composable (TranscriptItem.Background, TranscriptContext) -> Unit = { item, ctx -> BackgroundTaskCard(item, ctx) },
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
        is TranscriptItem.Background -> background(item, ctx)
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
    // S19: a failed send is reported on its message row, not as a chat that couldn't load.
    val error = state.thread?.error?.takeIf { state.thread?.page?.loading != true && it != state.thread?.approval?.error && !state.sendFailed }
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

/** One flexible title slot: subtitles never cost the title its second line. */
@Composable
internal fun TranscriptTitle(title: String, provider: String?) {
    val measurer = rememberTextMeasurer()
    val style = MaterialTheme.typography.bodyMedium
    val defaultScale = LocalDensity.current.fontScale == 1f
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Measure at the exact slot width before layout, avoiding a subtitle/height feedback frame.
        val layout = measurer.measure(AnnotatedString(title), style = style, maxLines = 2, overflow = TextOverflow.Ellipsis,
            constraints = Constraints(maxWidth = constraints.maxWidth))
        Column {
            Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis, style = style)
            if (defaultScale && layout.lineCount == 1 && !layout.hasVisualOverflow && provider != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    ProviderGlyph(provider, Modifier.size(12.dp))
                    Text(PROVIDERS.find { it.first == provider }?.second ?: provider.replaceFirstChar { it.uppercase() },
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted)
                }
            }
        }
    }
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
    val items = remember(state.thread, state.removed) {
        state.thread?.let(::transcriptItems).orEmpty().filterNot { it is TranscriptItem.Message && it.row.id in state.removed }
    }
    val now = rememberNow(state.turn?.started_at_ms != null)
    val context = TranscriptContext(model, now, onCitation, state.turn?.started_at_ms, threads, onOpenThread, gitChanges)
    val openDrawer = LocalWorkspaceMenu.current
    val tier = LocalWindowTier.current
    var chatMenu by remember { mutableStateOf(false) }
    val jump = remember { TranscriptJump() }
    // A8-6: where Shift+Tab lands when it leaves the top of the transcript (the header's last control).
    val headerFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    val headerEntry = remember { androidx.compose.ui.focus.FocusRequester() }
    val composerFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    val tabletop = rememberTabletopHinge()
    val columnBounds = remember { mutableStateOf<androidx.compose.ui.geometry.Rect?>(null) }
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().then(if (tabletop != null) Modifier.onGloballyPositioned { columnBounds.value = it.boundsInWindow() } else Modifier)) {
        Box(Modifier.focusRequester(headerEntry).keyboardRegion(composerFocus)) {
        VerdeTopBar(
            title = {
                TranscriptTitle(state.thread?.thread?.title ?: title ?: "Chat", state.thread?.thread?.provider)
            },
            showWorkspaceMenu = false,
            navigationIcon = {
                // Beside a permanent sidebar neither has a job: chats are switched from the list.
                if (!tier.docked) Row {
                    IconButton(onClick = onBack, modifier = Modifier.named("Back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null) }
                    openDrawer?.let { open ->
                        IconButton(onClick = open, modifier = Modifier.named("Open workspace drawer")) { Icon(Icons.Filled.Menu, contentDescription = null) }
                    }
                }
            },
            actions = {
                // Git actions never sit between the companion and ⋯: they get the row under the header.
                if (onThreadAction != null) Box(Modifier.focusRequester(headerFocus)) {
                    val thread = state.thread?.thread
                    IconButton(onClick = { chatMenu = true }, enabled = thread != null, modifier = Modifier.named("Chat actions")) {
                        Icon(Icons.Filled.MoreVert, contentDescription = null, modifier = Modifier.rotate(90f))
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
        }
        gitChanges?.let { GitChangesHeader(it) }
        transcriptBanner(state, now)?.let { banner ->
            BannerCard(banner, onRetry = { if (state.thread?.error != null) model.retry() else onRetryConnection() }, onHosts = onHosts)
        }
        // A-KB: a tap on the transcript (not taken by a control) or a scroll drag puts the keyboard away.
        val dismissKeyboard = rememberKeyboardDismiss()
        // A8-6: a long chat doesn't stand between the header and the composer. Tab from the header
        // skips to the composer; Shift+Tab from the composer comes back into the transcript at the
        // newest row. Inside, Tab walks every control (Copy code, tool rows, Copy output) and goes
        // on to the composer instead of wrapping back to the header.
        val newestFocus = remember { androidx.compose.ui.focus.FocusRequester() }
        val groupTab = remember { GroupTabHolder() }
        val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
        val tabScope = rememberCoroutineScope()
        var transcriptFocused by remember { mutableStateOf(false) }
        Box(Modifier.weight(1f).fillMaxWidth().dismissKeyboardOnTouch(dismissKeyboard)
            .onPreviewKeyEvent { event ->
                val tab = event.key == androidx.compose.ui.input.key.Key.Tab &&
                    event.type == androidx.compose.ui.input.key.KeyEventType.KeyDown
                if (tab) {
                    // On screen older rows are above: Shift+Tab walks up to older rows (the reversed
                    // list's "next"), Tab down to newer ones; leaving the top goes to the header,
                    // leaving the bottom to the composer, never the other way round.
                    val back = event.isShiftPressed
                    // S49: inside an expanded tool group, Tab walks its children top to bottom first.
                    val inGroup = groupTab.owner?.tab(back) == true
                    if (!inGroup) focusManager.moveFocus(if (back) androidx.compose.ui.focus.FocusDirection.Next else androidx.compose.ui.focus.FocusDirection.Previous)
                    tabScope.launch {
                        withFrameNanos { }
                        withFrameNanos { }
                        if (!transcriptFocused) runCatching { (if (back) headerFocus else composerFocus).requestFocus() }
                    }
                }
                tab
            }
            .onFocusChanged { transcriptFocused = it.hasFocus }
            .focusProperties {
                @Suppress("DEPRECATION") @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
                // The list reverses Tab's search direction. Redirect at its boundary before
                // the search wraps back into the destination and loses the header.
                exit = { direction ->
                    when (direction) {
                        androidx.compose.ui.focus.FocusDirection.Next -> headerFocus
                        androidx.compose.ui.focus.FocusDirection.Previous -> composerFocus
                        else -> androidx.compose.ui.focus.FocusRequester.Default
                    }
                }
                @Suppress("DEPRECATION") @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
                enter = { direction ->
                    if (direction == androidx.compose.ui.focus.FocusDirection.Next) composerFocus
                    else androidx.compose.ui.focus.FocusRequester.Default
                }
            }.focusGroup()) {
            CompositionLocalProvider(LocalDismissKeyboard provides dismissKeyboard, LocalNewestFocus provides newestFocus, LocalGroupTab provides groupTab) {
            when (val placeholder = transcriptPlaceholder(state)) {
                null -> TranscriptList(items, state, context, renderers, jump = jump)
                else -> Placeholder(placeholder, model)
            }
            }
        }
        // A8-6: Shift+Tab from the composer's first control goes into the transcript at the newest
        // message (not the oldest one on screen); within the composer it moves back as usual.
        // F7: half-opened with a horizontal fold (tabletop), the transcript ends at the hinge and the
        // composer and its controls sit below it; nothing crosses the fold.
        val lower = tabletop?.let { (hingeTop, hingeBottom) ->
            val density = LocalDensity.current
            val bottom = columnBounds.value?.bottom ?: return@let null
            val parts = hingeSegments(columnBounds.value?.top ?: 0f, bottom, hingeTop, hingeBottom,
                with(density) { 8.dp.toPx() }) ?: return@let null
            with(density) { parts.gap.toDp() to parts.after.toDp() }
        }
        if (lower != null) Spacer(Modifier.height(lower.first))
        Column(if (lower != null) Modifier.fillMaxWidth().height(lower.second) else Modifier.fillMaxWidth()) {
        // U1: running background commands stay in view above the composer.
        state.thread?.background_tasks?.takeIf { it.isNotEmpty() }?.let { tasks -> RunningTasksBar(tasks) { jump.target = it } }
        Box(Modifier.fillMaxWidth().keyboardRegion(headerEntry, newestFocus)) {
            CompositionLocalProvider(LocalComposerFocus provides composerFocus) { bottomBar(model, state) }
        }
        }
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
                BannerAction.Retry -> TextButton(onClick = onRetry, modifier = Modifier.heightIn(min = 48.dp)) { Text("Retry") }
                BannerAction.Hosts -> TextButton(onClick = onHosts, modifier = Modifier.heightIn(min = 48.dp)) { Text("Open hosts") }
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
    spacing: Dp = 8.dp, contentPadding: PaddingValues = PaddingValues(horizontal = 12.dp, vertical = 8.dp), jump: TranscriptJump? = null) {
    // Newest first + reverseLayout: index 0 sits at the bottom, so growth of the streaming row
    // and older pages prepended at the top both leave the reading position alone.
    val reversed = remember(items) { items.asReversed() }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
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
    // F3 / A7-5: across a fold/unfold or any resize (each recreates the activity) the reader keeps the
    // row at the top of the screen where it was, found by its key: the TOP row and its gap below the
    // viewport's top edge (the restored index anchored the bottom row, so the top drifted each cycle).
    var anchorKey by rememberSaveable { mutableStateOf<String?>(null) }
    var anchorGap by rememberSaveable { mutableIntStateOf(0) }
    val currentItems by rememberUpdatedState(reversed)
    var anchored by remember { mutableStateOf(false) }
    LaunchedEffect(list) {
        snapshotFlow { Triple(anchored && list.isScrollInProgress, list.firstVisibleItemIndex, list.firstVisibleItemScrollOffset) }.collect { (scrolling, _, _) ->
            // Only real scrolls after the restore below move the anchor; a relayout at a new width
            // shifts offsets too, and recording those made the row drift on every fold cycle.
            if (!scrolling) return@collect
            val info = list.layoutInfo
            val top = info.visibleItemsInfo.filter { it.index < currentItems.size }.maxByOrNull { it.index } ?: return@collect
            anchorKey = currentItems[top.index].key
            anchorGap = topGap(info, top)
        }
    }
    LaunchedEffect(reversed.isNotEmpty()) {
        if (anchored || reversed.isEmpty()) return@LaunchedEffect
        try {
            val key = anchorKey ?: return@LaunchedEffect
            if (follow) return@LaunchedEffect
            val index = reversed.indexOfFirst { it.key == key }
            if (index < 0) return@LaunchedEffect
            if (list.layoutInfo.visibleItemsInfo.none { it.index == index }) list.scrollToItem(index)
            // Re-applied while the new layout settles (the Latest strip and composer find their size
            // after the first frames), so the row ends exactly where it was.
            repeat(8) {
                withFrameNanos { }
                val info = list.layoutInfo
                val row = info.visibleItemsInfo.find { it.index == index } ?: return@repeat
                val delta = anchorGap - topGap(info, row)
                if (delta != 0) list.scrollBy(delta.toFloat())
                kotlinx.coroutines.delay(60)
            }
        } finally {
            anchored = true
        }
    }
    // U1: the running-tasks bar scrolls to a task's row.
    LaunchedEffect(jump?.target) {
        val id = jump?.target ?: return@LaunchedEffect
        val index = reversed.indexOfFirst { item -> item is TranscriptItem.Background && item.rows.any { it.id == id } }
        if (index >= 0) {
            follow = false
            // (a) / A7-9: outline the task for a moment so the eye finds it, as on iOS: first, so it
            // shows even when the row is already in view or the scroll is interrupted.
            jump.highlight = id
            scope.launch { kotlinx.coroutines.delay(2_500); if (jump.highlight == id) jump.highlight = null }
            // S41: the row lands clear of the Latest strip that appears once the list leaves the bottom.
            runCatching { list.showBackgroundTask(index, with(density) { 12.dp.roundToPx() }) }
        }
        jump.target = null
    }
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
        CompositionLocalProvider(LocalDisclosureAnchor provides anchor, LocalDisclosureStore provides disclosures, LocalTranscriptJump provides jump) {
        LazyColumn(Modifier.fillMaxSize().testTag(TRANSCRIPT_LIST).keepTopRowOnResize(list) { atBottom }, state = list, reverseLayout = true,
            contentPadding = contentPadding, verticalArrangement = Arrangement.spacedBy(spacing, Alignment.Bottom)) {
            itemsIndexed(reversed, key = { _, it -> it.key }, contentType = { _, it -> it::class }) { index, item ->
                val newest = LocalNewestFocus.current
                CompositionLocalProvider(LocalTranscriptIndex provides index) {
                    // A8-6: the newest row takes focus when Shift+Tab comes back from the composer.
                    Box(if (index == 0 && newest != null) Modifier.focusRequester(newest) else Modifier) {
                        TranscriptItemFrame(item) { renderers.Render(item, ctx) }
                    }
                }
            }
            item(key = "page-header", contentType = "header") { PageHeader(page, ctx.model) }
        }
        }
        ApprovalBanner(reversed, list, ctx.model.approvals, Modifier.align(Alignment.TopCenter))
    }
    // S42: "Latest" is one full-width strip under the transcript (as on iOS), never a pill over it.
    if (!atBottom && reversed.isNotEmpty()) Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).background(VerdeColors.AccentWash)
        .clickable(role = androidx.compose.ui.semantics.Role.Button) { follow = true; scope.launch { list.animateScrollToItem(0) } }
        .nameOnly(JUMP_TO_BOTTOM).testTag(LATEST_STRIP),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(4.dp))
        Text("Latest", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
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

/** A negative logical offset insets a row from the physical bottom in this reversed list. The strip/bar are outside it. */
internal suspend fun LazyListState.showBackgroundTask(index: Int, bottomGap: Int) {
    animateScrollToItem(index, -bottomGap)
}

/** A8-6: focus for the newest transcript row (Shift+Tab from the composer lands there). */
internal val LocalNewestFocus = staticCompositionLocalOf<androidx.compose.ui.focus.FocusRequester?> { null }

// ---- Default renderers ----

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun MessageRow(row: ChatRow, ctx: TranscriptContext) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var menu by remember { mutableStateOf(false) }
    var selecting by remember { mutableStateOf(false) }
    // A6-2: closing a menu or the Select text dialog returns focus here, not to the header's Back.
    val rowFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    var refocus by remember { mutableIntStateOf(0) }
    val dismissKeyboard = LocalDismissKeyboard.current
    val mine = row.role == "user"
    // Steers from an orchestrating parent agent show only its words, labelled as the parent.
    val steer = remember(row.role, row.body) { parentSteerBody(row.role, row.body) }
    val body = steer ?: row.body
    val colors = MaterialTheme.colorScheme
    // A7-4: Tab goes from the card to its own controls (Copy code, links) before the next row, and
    // the card's focus stop has a name.
    val who = when { steer != null -> "Parent agent"; mine -> "You"; else -> row.author.ifEmpty { "Assistant" } }
    Box(Modifier.fillMaxWidth().then(rememberGroupTab(expanded = true)), contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier.fillMaxWidth()
                .background(when { steer != null -> VerdeColors.Panel; mine -> VerdeColors.UserBubble; else -> VerdeColors.Assistant }, RoundedCornerShape(10.dp))
                .border(1.dp, if (mine) VerdeColors.UserBubble else VerdeColors.Border, RoundedCornerShape(10.dp))
                // S29: a message is focusable and long-pressable, not an unnamed tap target (the
                // transcript already puts the keyboard away on a tap).
                .focusRequester(rowFocus)
                .semantics { contentDescription = "$who message" }
                .focusable()
                .longPressMenu("Message actions") { menu = true }
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
            if (mine && row.delivery == "failed") FailedSend(row, ctx.model)
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
        if (selecting) SelectTextDialog({ MarkdownText(body, ctx.model, ctx.onCitation) }) {
            selecting = false
            refocus++
        }
        LaunchedEffect(refocus) {
            if (refocus == 0) return@LaunchedEffect
            withFrameNanos { }
            runCatching { rowFocus.requestFocus() }
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
internal fun ThinkCard(row: ChatRow, ctx: TranscriptContext) {
    val disclosure = rememberDisclosure("think:" + row.id, false)
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).then(disclosure.track)
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClickLabel = if (disclosure.expanded) "Collapse" else "Expand") { disclosure.toggle() }
            .nameOnly(if (commandRunning(row)) "Thinking…" else "Thought", state = if (disclosure.expanded) "Expanded" else "Collapsed")
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

/** S19: a message that didn't send says why and offers Retry and Remove (48dp each) on its own row. */
@Composable
private fun FailedSend(row: ChatRow, model: TranscriptModel) {
    val state by model.state.collectAsState()
    val reason = composerError(state.thread?.error) ?: "This message wasn't sent."
    Column(Modifier.fillMaxWidth().padding(top = 2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(reason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.semantics { liveRegion = androidx.compose.ui.semantics.LiveRegionMode.Polite })
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { model.composer.resend(row.body) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Retry") }
            TextButton(onClick = { model.removeFailed(row.id) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Remove") }
        }
    }
}

/**
 * S20 / A6-1: when a reversed list's viewport changes height (keyboard, attachment strip, composer
 * growth, the Latest strip) the reading position holds: at the bottom it stays at the bottom (the
 * reversed list anchors there by itself); scrolled up, the top row stays put instead of sliding
 * under the header. The size is only recorded during layout; the correction runs afterwards, from
 * a coroutine, because scrolling inside a measure/layout callback crashes Compose.
 */
/** The gap in px between the viewport's top edge and [item]'s top edge (either layout direction). */
internal fun topGap(info: androidx.compose.foundation.lazy.LazyListLayoutInfo, item: androidx.compose.foundation.lazy.LazyListItemInfo): Int =
    if (info.reverseLayout) info.viewportEndOffset - (item.offset + item.size) else item.offset - info.viewportStartOffset

@Composable
internal fun Modifier.keepTopRowOnResize(list: LazyListState, atBottom: () -> Boolean): Modifier {
    val viewport = remember { mutableIntStateOf(-1) }
    val bottom by rememberUpdatedState(atBottom)
    LaunchedEffect(list) {
        var last = -1
        snapshotFlow { viewport.intValue }.collect { height ->
            val before = last
            last = height
            // Outside layout: a raw delta neither takes the scroll lock nor cancels the user's drag.
            if (before > 0 && height > 0 && before != height && !bottom()) list.dispatchRawDelta((before - height).toFloat())
        }
    }
    return this.onSizeChanged { viewport.intValue = it.height }
}

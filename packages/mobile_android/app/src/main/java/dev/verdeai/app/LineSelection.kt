package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ExplorerRoot
import dev.verdeai.core.ThreadSummary
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * "Ask agent about these lines": a long-press-and-drag (or line-number tap) selection over a text
 * or diff viewer, a bar with Copy / Ask agent, and a sheet that sends the shared `selection_prompt`
 * message to one of the workspace's chats. Selected text and instructions stay in memory and are
 * never logged.
 */
internal data class PickedLines(val start: Int, val end: Int, val side: String?, val text: String)

/** What the prompt formatter needs: an absolute path plus the picked lines. */
internal data class SelectionExcerpt(val path: String, val start: Int, val end: Int, val side: String?, val text: String)

/** A contiguous selection of viewer positions (1-based file lines, or 1-based diff rows). */
@Stable
internal class LineSelection {
    var anchor by mutableStateOf<Int?>(null)
        private set
    var focus by mutableStateOf<Int?>(null)
        private set
    /** Bound by the visible viewer: turns positions into lines and text. */
    var source: ((IntRange) -> PickedLines?)? = null

    val range: IntRange? get() = anchor?.let { a -> val f = focus ?: a; minOf(a, f)..maxOf(a, f) }
    fun contains(position: Int) = range?.contains(position) == true
    fun start(position: Int) { anchor = position; focus = position }
    fun drag(position: Int) { if (anchor != null) focus = position }
    /** A line-number tap starts a selection, extends it, or clears a single line tapped again. */
    fun tap(position: Int) {
        val r = range
        when {
            r == null -> start(position)
            r.first == position && r.last == position -> clear()
            else -> focus = position
        }
    }
    fun clear() { anchor = null; focus = null }
    fun picked(): PickedLines? = range?.let { source?.invoke(it) }
}

internal val LocalLineSelection = staticCompositionLocalOf<LineSelection?> { null }

internal val SelectedLineColor = Color(0x3350C878)

/** Lines [range] (1-based) of a text file, without the final newline. */
internal fun fileLines(text: String, starts: IntArray, range: IntRange): PickedLines? {
    if (starts.isEmpty()) return null
    val first = range.first.coerceIn(1, starts.size)
    val last = range.last.coerceIn(first, starts.size)
    val end = lineEnd(text, starts, last - 1)
    return PickedLines(first, last, null, text.substring(starts[first - 1], end))
}

/**
 * Diff rows [range] (1-based, hunk headers excluded) as lines of one side: the old side when only
 * deletions (and context) are picked, else the new side. Rows not on that side are left out.
 */
internal fun diffLines(rows: List<DiffRow>, range: IntRange): PickedLines? {
    if (rows.isEmpty()) return null
    val picked = rows.subList((range.first - 1).coerceIn(0, rows.size), range.last.coerceIn(0, rows.size)).filter { it.kind != "meta" }
    val old = picked.none { it.kind == "add" } && picked.any { it.kind == "delete" }
    val side = picked.filter { if (old) it.oldLine != null else it.newLine != null }
    if (side.isEmpty()) return null
    val numbers = side.map { (if (old) it.oldLine else it.newLine)!!.toInt() }
    return PickedLines(numbers.min(), numbers.max(), if (old) "old" else "new", side.joinToString("\n") { it.raw })
}

internal fun linesLabel(picked: PickedLines): String {
    val lines = if (picked.end > picked.start) "Lines ${picked.start}–${picked.end}" else "Line ${picked.start}"
    return when (picked.side) { "old" -> "$lines (old)"; "new" -> "$lines (new)"; else -> lines }
}

/**
 * Selection gestures over a lazy viewer: a long press starts a selection that follows the finger
 * (auto-scrolling at the edges), a tap on the line-number gutter starts or extends one, and a tap
 * on text extends an active selection. Plain drags still scroll. [line] maps a visible item to its
 * selectable position (null for headers).
 */
internal fun Modifier.lineGestures(
    selection: LineSelection?,
    list: LazyListState,
    gutterChars: Int,
    line: (LazyListItemInfo) -> Int?,
    pick: (IntRange) -> PickedLines?,
): Modifier = if (selection == null) this else composed {
    val currentLine by rememberUpdatedState(line)
    val currentPick by rememberUpdatedState(pick)
    DisposableEffect(selection) {
        selection.source = { currentPick(it) }
        onDispose { selection.source = null }
    }
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    pointerInput(selection, list, gutterChars) {
        // Monospace bodySmall digits are ~7.2dp wide; the gutter also has 8dp padding each side.
        val gutter = (gutterChars * 7.5f + 16f).dp.toPx()
        val edge = 48.dp.toPx()
        fun at(y: Float): Int? = list.layoutInfo.visibleItemsInfo
            .firstOrNull { y >= it.offset && y < it.offset + it.size }?.let(currentLine)
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            var outcome = 0 // 0 long press, 1 tap, 2 taken by scrolling
            withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                outcome = if (waitForUpOrCancellation() != null) 1 else 2
            }
            when (outcome) {
                1 -> {
                    val position = at(down.position.y) ?: return@awaitEachGesture
                    if (down.position.x <= gutter) selection.tap(position)
                    else if (selection.range != null) selection.drag(position)
                }
                0 -> {
                    val start = at(down.position.y) ?: return@awaitEachGesture
                    selection.start(start)
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    // Initial pass: the list never sees these moves, so it doesn't scroll under the finger.
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        change.consume()
                        if (!change.pressed) break
                        val y = change.position.y
                        at(y.coerceIn(0f, size.height - 1f))?.let(selection::drag)
                        val delta = when {
                            y < edge -> -(edge - y) / 3f
                            y > size.height - edge -> (y - size.height + edge) / 3f
                            else -> 0f
                        }
                        if (delta != 0f) scope.launch { list.scrollBy(delta) }
                    }
                }
            }
        }
    }
}

/** The bar shown while lines are selected. */
@Composable
internal fun SelectionBar(picked: PickedLines?, onAsk: () -> Unit, onClear: () -> Unit, modifier: Modifier = Modifier) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    Surface(modifier.fillMaxWidth().testTag(SELECTION_BAR_TAG), color = VerdeColors.PanelAlt, tonalElevation = 3.dp) {
        Row(Modifier.navigationBarsPadding().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClear) { Icon(Icons.Filled.Close, contentDescription = "Clear selection") }
            Text(picked?.let(::linesLabel) ?: "Nothing to ask about", Modifier.weight(1f),
                style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            TextButton(onClick = { picked?.let { clipboard.setText(AnnotatedString(it.text)) } }, enabled = picked != null) { Text("Copy") }
            Button(onClick = onAsk, enabled = picked != null, modifier = Modifier.testTag(SELECTION_ASK_TAG)) { Text("Ask agent") }
        }
    }
}

/** Chats the selection can go to: the workspace's top-level, unarchived chats, open and recent first. */
internal fun askTargets(threads: List<ThreadSummary>): List<ThreadSummary> =
    threads.filter { !it.archived && listed(it) }
        .sortedWith(compareByDescending<ThreadSummary> { it.open }.thenByDescending { it.last_activity_at_ms ?: 0L }.thenBy { it.thread_id })

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AskAgentSheet(
    picked: PickedLines,
    path: String,
    chats: List<ThreadSummary>,
    sending: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onSend: (thread: String, instruction: String) -> Unit,
) {
    var chat by rememberSaveable { mutableStateOf(chats.firstOrNull()?.thread_id) }
    var instruction by rememberSaveable { mutableStateOf("") }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Panel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(ASK_SHEET_TAG)) {
        Column(Modifier.fillMaxWidth().imePadding().padding(horizontal = 16.dp).padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Ask agent", style = MaterialTheme.typography.titleLarge)
            Text("${basename(path)} · ${linesLabel(picked)}", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted,
                maxLines = 1, overflow = TextOverflow.StartEllipsis)
            Text(picked.text.lineSequence().take(6).joinToString("\n"), Modifier.fillMaxWidth().background(VerdeColors.Assistant).padding(8.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono), maxLines = 6, overflow = TextOverflow.Ellipsis)
            VerdeSection("Send to", Modifier.padding(start = 0.dp))
            if (chats.isEmpty()) Text("This workspace has no chats yet. Start one, then try again.", color = VerdeColors.Warning,
                style = MaterialTheme.typography.bodySmall)
            Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                chats.forEach { thread ->
                    Row(Modifier.fillMaxWidth().selectable(thread.thread_id == chat, role = Role.RadioButton) { chat = thread.thread_id }
                        .padding(vertical = 4.dp).testTag("ask-chat-${thread.thread_id}"), verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = thread.thread_id == chat, onClick = null)
                        Spacer(Modifier.width(8.dp))
                        ProviderGlyph(thread.provider)
                        Spacer(Modifier.width(8.dp))
                        Text(thread.title.ifBlank { "Untitled chat" }, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (activeStatus(thread.status)) Text("working", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Accent)
                    }
                }
            }
            OutlinedTextField(instruction, { instruction = it }, Modifier.fillMaxWidth().testTag(ASK_INSTRUCTION_TAG),
                placeholder = { Text("What should the agent do?") }, minLines = 2, maxLines = 5, enabled = !sending)
            chats.find { it.thread_id == chat }?.takeIf { activeStatus(it.status) }?.let {
                Text("This chat is working; your message goes in as a follow-up.", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
            }
            error?.let { Text(it, color = VerdeColors.Warning, style = MaterialTheme.typography.bodySmall) }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss, enabled = !sending) { Text("Cancel") }
                Button(onClick = { chat?.let { onSend(it, instruction) } }, enabled = !sending && chat != null && instruction.isNotBlank(),
                    modifier = Modifier.testTag(ASK_SEND_TAG)) { Text(if (sending) "Sending…" else "Send") }
            }
        }
    }
}

/**
 * Ask-agent messages waiting for their chat screen to open; in memory only, keyed by host,
 * workspace and chat, taken once.
 */
internal object PromptHandoff {
    private val pending = mutableMapOf<String, String>()
    private fun key(host: String?, workspace: String, thread: String) = "${host.orEmpty()}\u0000$workspace\u0000$thread"
    @Synchronized fun put(host: String?, workspace: String, thread: String, text: String) { pending[key(host, workspace, thread)] = text }
    @Synchronized fun take(host: String?, workspace: String, thread: String): String? = pending.remove(key(host, workspace, thread))
    @Synchronized fun clear() = pending.clear()
}

/**
 * Wraps a viewer with line selection: provides [LocalLineSelection], shows the selection bar and
 * the ask sheet, and hands the formatted message to the chosen chat's screen. [path] is the
 * absolute path the selection belongs to (null disables asking). [roots] name the message's path
 * (default: the workspace folders; diffs pass their repository).
 */
@Composable
internal fun SelectionScope(
    explorer: ExplorerModel,
    hostId: String?,
    path: String?,
    workspace: dev.verdeai.core.Workspace?,
    onOpenThread: (workspace: String, thread: String) -> Unit,
    roots: List<ExplorerRoot>? = null,
    content: @Composable () -> Unit,
) {
    val selection = remember(path) { LineSelection() }
    val state by explorer.state.collectAsState()
    val scope = rememberCoroutineScope()
    var asking by remember { mutableStateOf<PickedLines?>(null) }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Roots name non-home folders in the message; load them once if nothing cached them yet.
    LaunchedEffect(explorer) { if (roots == null && explorer.state.value.files?.loaded != true) explorer.loadRoots() }
    CompositionLocalProvider(LocalLineSelection provides if (path == null) null else selection) {
        Box(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f)) { content() }
                if (path != null && selection.range != null) {
                    SelectionBar(selection.picked(), onAsk = { error = null; asking = selection.picked() }, onClear = selection::clear)
                }
            }
        }
    }
    val picked = asking
    if (picked != null && path != null) {
        val chats = remember(workspace) { askTargets(workspace?.threads.orEmpty()) }
        AskAgentSheet(picked, path, chats, sending, error, onDismiss = { if (!sending) asking = null }) { thread, instruction ->
            sending = true
            scope.launch {
                val named = roots ?: state.files?.roots.orEmpty().filter { it.path.isNotEmpty() }.ifEmpty {
                    workspace?.let { listOf(ExplorerRoot(HOME_ROOT, it.label, it.path, home = true)) }.orEmpty()
                }
                val text = explorer.prompt(SelectionExcerpt(path, picked.start, picked.end, picked.side, picked.text), named, instruction)
                sending = false
                if (text == null) { error = "Couldn't prepare the message. The selection may be too large."; return@launch }
                PromptHandoff.put(hostId, explorer.workspaceId, thread, text)
                asking = null
                selection.clear()
                onOpenThread(explorer.workspaceId, thread)
            }
        }
    }
}

internal const val SELECTION_BAR_TAG = "selection-bar"
internal const val SELECTION_ASK_TAG = "selection-ask"
internal const val ASK_SHEET_TAG = "ask-sheet"
internal const val ASK_INSTRUCTION_TAG = "ask-instruction"
internal const val ASK_SEND_TAG = "ask-send"

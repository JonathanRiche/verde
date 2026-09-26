package dev.verdeai.app

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Paint
import android.graphics.Typeface
import android.os.PersistableBundle
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.verdeai.core.TerminalCursorShape
import kotlin.math.ceil

/** The single most relevant status line for the terminal screen, or null when live. */
internal fun terminalNotice(s: TerminalUiState, b: BrowseState, hostId: String?): String? {
    val view = s.view
    return when {
        s.failure != null -> s.failure
        b.hostId != hostId -> "This terminal belongs to another host. Switch hosts to use it."
        !b.networkAvailable -> "You're offline. Showing the last screen; input is paused."
        b.row?.fatal == true -> "Connection unavailable — reopen Verde."
        b.host?.phase != "ready" -> "Reconnecting… Showing the last screen; input is paused."
        s.terminalId == null -> "Opening a new terminal…"
        view == null -> "Opening terminal…"
        view.session_status == "exited" -> "The session has ended."
        view.session_status == "unknown" || (view.error != null && !view.attached) -> "This terminal is no longer available."
        view.session_status == "starting" -> "Starting shell…"
        !canWrite(b.host) -> "View only: this phone was paired without terminal access."
        view.error != null && view.stale -> "Connection interrupted. Catching up…"
        s.replayGap -> "Reconnected. Some earlier output may be missing."
        else -> null
    }
}

internal fun cellMetrics(paint: Paint): CellMetrics {
    val size = paint.textSize.coerceAtLeast(1f)
    // Monospace advance is ~0.6 em; implausible measurements (stub graphics) use that instead.
    val width = paint.measureText("M").takeIf { it >= size * 0.3f } ?: (size * 0.6f)
    val metrics = paint.fontMetrics
    val height = ceil(metrics.descent - metrics.ascent).takeIf { it > 0f } ?: ceil(size * 1.2f)
    val baseline = (-metrics.ascent).takeIf { it > 0f } ?: size
    return CellMetrics(width, height, baseline)
}

internal const val MIN_FONT_SP = 8f
internal const val MAX_FONT_SP = 32f
private const val SELECTION_ARGB = 0x6633B5E5
private val KEY_ROW_HEIGHT = 48.dp

/**
 * Native terminal for one daemon session. [terminalId] null opens a new session in the
 * workspace (`terminal_create`) once the grid is measured.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TerminalScreen(hosts: HostsModel, browse: BrowseModel, workspaceId: String, terminalId: String?, onBack: () -> Unit) {
    val hostId = rememberSaveable { browse.state.value.hostId ?: "" }
    val model = viewModel { TerminalModel(hosts, browse, createSavedStateHandle(), hostId.ifEmpty { null }, workspaceId, terminalId) }
    val state by model.state.collectAsState()
    val browseState by browse.state.collectAsState()
    val interactive by model.interactive.collectAsState()
    val writable = canWrite(browseState.host) && browseState.hostId == hostId
    val workspace = browseState.workspaces?.items?.find { it.workspace_id == workspaceId }
    val pane = state.terminalId?.let { id -> (browseState.home?.items.orEmpty() + workspace?.panes.orEmpty()).find { it.terminal_id == id } }
    val title = pane?.title ?: state.view?.label?.takeIf { it.isNotEmpty() } ?: if (terminalId == null) "New terminal" else "Terminal"

    var fontSp by rememberSaveable { mutableFloatStateOf(14f) }
    var selection by remember { mutableStateOf<GridSelection?>(null) }
    val context = LocalContext.current
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    var inputView by remember { mutableStateOf<TerminalInputView?>(null) }
    val send = remember(model) { { input: TermInput -> selection = null; model.input(input) } }

    Column(Modifier.fillMaxSize()) {
        VerdeTopBar(title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } })
        // Overlays (notice, "Latest") never change the measured grid, so they cause no host resize.
        Box(Modifier.weight(1f).fillMaxWidth()) {
            TerminalCanvas(state, fontSp, selection,
                onMeasured = model::measured,
                onTap = { if (selection != null) selection = null else if (writable) inputView?.showKeyboard() },
                onScroll = model::scroll,
                onZoom = { zoom -> fontSp = (fontSp * zoom).coerceIn(MIN_FONT_SP, MAX_FONT_SP) },
                onSelect = { selection = it })
            if (writable) AndroidView(factory = { TerminalInputView(it, send).also { view -> inputView = view } },
                update = { it.onInput = send },
                modifier = Modifier.size(1.dp).align(Alignment.TopStart).testTag("terminal-input"))
            val offset = state.snapshot?.scroll_offset ?: 0L
            if (offset > 0) FilledTonalButton(onClick = { model.scroll(-offset.toInt()) },
                modifier = Modifier.align(Alignment.TopEnd).padding(12.dp)) { Text("Latest") }
            terminalNotice(state, browseState, hostId.ifEmpty { null })?.let { notice ->
                Surface(color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.95f), tonalElevation = 2.dp,
                    modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()) {
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(notice, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f).testTag("terminal-notice"))
                        if (state.replayGap && notice.startsWith("Reconnected")) TextButton(onClick = model::dismissGap) { Text("Dismiss") }
                    }
                }
            }
        }
        val selected = selection
        // Selection actions replace the key row at the same height, so selecting never resizes.
        if (selected != null || writable) Box(Modifier.fillMaxWidth().background(VerdeColors.Panel).height(KEY_ROW_HEIGHT)) {
            if (selected != null) Row(Modifier.fillMaxSize().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { selection = null }) { Text("Cancel") }
                TextButton(onClick = {
                    state.snapshot?.let { copySensitive(context, selectedText(it, selected)) }
                    selection = null
                }) { Text("Copy") }
            } else AccessoryRow(state, interactive, send, model::toggleCtrl, model::toggleAlt,
                onPaste = { clipboard.getText()?.text?.takeIf { it.isNotEmpty() }?.let { send(TermInput.Paste(it)) } })
        }
    }
}

/** Copies without logging; Android 13+ hides sensitive clips from the clipboard preview. */
private fun copySensitive(context: android.content.Context, text: String) {
    val manager = context.getSystemService(ClipboardManager::class.java) ?: return
    val clip = ClipData.newPlainText("Terminal", text)
    clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
    manager.setPrimaryClip(clip)
}

@Composable
private fun AccessoryRow(state: TerminalUiState, enabled: Boolean, send: (TermInput) -> Unit,
    onCtrl: () -> Unit, onAlt: () -> Unit, onPaste: () -> Unit) {
    @Composable fun keyButton(label: String, description: String = label, input: TermInput) =
        TextButton(onClick = { send(input) }, enabled = enabled, contentPadding = PaddingValues(horizontal = 10.dp),
            modifier = Modifier.semantics { contentDescription = description }) { Text(label) }
    @Composable fun toggle(label: String, on: Boolean, action: () -> Unit) =
        FilterChip(selected = on, onClick = action, enabled = enabled, label = { Text(label) }, modifier = Modifier.padding(horizontal = 2.dp))
    Row(Modifier.fillMaxSize().testTag("terminal-keys").horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        keyButton("Esc", "Escape", TermInput.Key("Escape"))
        keyButton("Tab", input = TermInput.Key("Tab"))
        toggle("Ctrl", state.ctrl, onCtrl)
        toggle("Alt", state.alt, onAlt)
        keyButton("←", "Left", TermInput.Key("ArrowLeft"))
        keyButton("↓", "Down", TermInput.Key("ArrowDown"))
        keyButton("↑", "Up", TermInput.Key("ArrowUp"))
        keyButton("→", "Right", TermInput.Key("ArrowRight"))
        keyButton("|", "Pipe", TermInput.Text("|"))
        keyButton("~", "Tilde", TermInput.Text("~"))
        keyButton("/", "Slash", TermInput.Text("/"))
        keyButton("-", "Dash", TermInput.Text("-"))
        keyButton("Home", input = TermInput.Key("Home"))
        keyButton("End", input = TermInput.Key("End"))
        keyButton("PgUp", "Page up", TermInput.Key("PageUp"))
        keyButton("PgDn", "Page down", TermInput.Key("PageDown"))
        TextButton(onClick = onPaste, enabled = enabled, contentPadding = PaddingValues(horizontal = 10.dp)) { Text("Paste") }
    }
}

private enum class Gesture { Tap, Scroll, Pinch, Select }

/** Tap, drag or pinch before the long-press timeout; the caller treats a timeout as selection. */
private suspend fun AwaitPointerEventScope.classify(down: PointerInputChange): Gesture {
    while (true) {
        val event = awaitPointerEvent()
        if (event.changes.count { it.pressed } > 1) return Gesture.Pinch
        val change = event.changes.firstOrNull { it.id == down.id } ?: return Gesture.Tap
        if (!change.pressed) return Gesture.Tap
        if ((change.position - down.position).getDistance() > viewConfiguration.touchSlop) return Gesture.Scroll
    }
}

/**
 * Canvas renderer plus gestures: tap (keyboard), vertical drag (scrollback), pinch (font
 * size) and long-press drag (selection). The grid is never exposed to semantics.
 */
@Composable
private fun TerminalCanvas(state: TerminalUiState, fontSp: Float, selection: GridSelection?,
    onMeasured: (Int, Int) -> Unit, onTap: () -> Unit, onScroll: (Int) -> Unit, onZoom: (Float) -> Unit,
    onSelect: (GridSelection) -> Unit) {
    val density = LocalDensity.current
    val textPx = with(density) { fontSp.sp.toPx() }
    val context = LocalContext.current
    val font = remember(context) { androidx.core.content.res.ResourcesCompat.getFont(context, R.font.jetbrains_mono) ?: Typeface.MONOSPACE }
    val paint = remember(textPx, font) { Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = font; textSize = textPx } }
    val metrics = remember(paint) { cellMetrics(paint) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    LaunchedEffect(size, metrics) {
        if (size.width > 0 && size.height > 0) terminalGrid(size.width.toFloat(), size.height.toFloat(), metrics).let { onMeasured(it.first, it.second) }
    }
    val snapshot = state.snapshot
    val plan = remember(snapshot) { snapshot?.let { renderPlan(it) } }
    val latestTap by rememberUpdatedState(onTap)
    val latestScroll by rememberUpdatedState(onScroll)
    val latestZoom by rememberUpdatedState(onZoom)
    val latestSelect by rememberUpdatedState(onSelect)
    val grid by rememberUpdatedState(plan?.let { it.cols to it.rows })
    val background = plan?.let { Color(it.background) } ?: VerdeColors.Background
    Canvas(Modifier.fillMaxSize().background(background).clipToBounds().onSizeChanged { size = it }.testTag("terminal-canvas")
        .pointerInput(metrics) {
            fun cell(position: Offset): Pair<Int, Int> {
                val (cols, rows) = grid ?: (1 to 1)
                return (position.y / metrics.height).toInt().coerceIn(0, rows - 1) to (position.x / metrics.width).toInt().coerceIn(0, cols - 1)
            }
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val gesture = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) { classify(down) } ?: Gesture.Select
                when (gesture) {
                    Gesture.Tap -> latestTap()
                    Gesture.Select -> {
                        val anchor = cell(down.position)
                        latestSelect(GridSelection(anchor.first, anchor.second, anchor.first, anchor.second))
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            val at = cell(change.position)
                            latestSelect(GridSelection(anchor.first, anchor.second, at.first, at.second))
                            change.consume()
                            if (!change.pressed) break
                        }
                    }
                    Gesture.Scroll, Gesture.Pinch -> {
                        var pending = 0f
                        var pinching = gesture == Gesture.Pinch
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            if (pressed.size > 1) pinching = true
                            if (pinching) {
                                val zoom = event.calculateZoom()
                                if (zoom != 1f && pressed.size > 1) latestZoom(zoom)
                            } else {
                                val change = pressed.first()
                                // Dragging down reveals older rows (positive delta).
                                pending += change.position.y - change.previousPosition.y
                                val rows = (pending / metrics.height).toInt()
                                if (rows != 0) { latestScroll(rows); pending -= rows * metrics.height }
                            }
                            event.changes.forEach { it.consume() }
                        }
                    }
                }
            }
        }) {
        val current = plan ?: return@Canvas
        val w = metrics.width
        val h = metrics.height
        drawIntoCanvas { canvas ->
            val c = canvas.nativeCanvas
            val fill = Paint().apply { style = Paint.Style.FILL }
            for (run in current.backgrounds) {
                fill.color = run.color
                c.drawRect(run.col * w, run.row * h, (run.col + run.cells) * w, (run.row + 1) * h, fill)
            }
            if (selection != null) {
                fill.color = SELECTION_ARGB
                val (startRow, startCol) = selection.start
                val (endRow, endCol) = selection.end
                for (row in startRow..minOf(endRow, current.rows - 1)) {
                    val from = if (row == startRow) startCol else 0
                    val to = if (row == endRow) endCol else current.cols - 1
                    c.drawRect(from * w, row * h, (to + 1) * w, (row + 1) * h, fill)
                }
            }
            for (run in current.texts) drawText(c, paint, run.text, run.col * w, run.row * h + metrics.baseline, run.fg,
                run.bold, run.italic, run.underline, run.strikethrough)
            current.cursor?.let { cursor ->
                fill.color = cursor.color
                val left = cursor.col * w
                val top = cursor.row * h
                when (cursor.shape) {
                    TerminalCursorShape.block -> {
                        c.drawRect(left, top, left + cursor.cells * w, top + h, fill)
                        current.texts.find { it.row == cursor.row && it.col == cursor.col }?.let { run ->
                            drawText(c, paint, run.text, left, top + metrics.baseline, cursor.textColor, run.bold, run.italic, run.underline, run.strikethrough)
                        }
                    }
                    TerminalCursorShape.underline -> c.drawRect(left, top + h - maxOf(2f, h / 10f), left + cursor.cells * w, top + h, fill)
                    TerminalCursorShape.bar -> c.drawRect(left, top, left + maxOf(2f, w / 8f), top + h, fill)
                }
            }
        }
    }
}

private fun drawText(c: android.graphics.Canvas, paint: Paint, text: String, x: Float, y: Float, color: Int,
    bold: Boolean, italic: Boolean, underline: Boolean, strike: Boolean) {
    paint.color = color
    paint.isFakeBoldText = bold
    paint.textSkewX = if (italic) -0.2f else 0f
    paint.isUnderlineText = underline
    paint.isStrikeThruText = strike
    c.drawText(text, x, y, paint)
}

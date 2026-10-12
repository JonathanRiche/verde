package dev.verdeai.app

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitTouchSlopOrCancellation
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.verdeai.core.Pane
import dev.verdeai.core.CompanionLink
import dev.verdeai.core.ThreadSummary
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.roundToInt

/*
 * The companion's chat-head: a small draggable bubble drawn over the app (in-app overlay, not a
 * system window). It snaps to the nearest side, remembers where it was left, carries a "needs you"
 * badge, and briefly speaks up when something new needs the user or the companion replies.
 */

internal const val COMPANION_BUBBLE = "companion-bubble"
internal const val COMPANION_BUBBLE_POPUP = "companion-bubble-popup"
internal const val BUBBLE_POPUP_MS = 4_000L

// ---- Placement (pure, unit tested) ----

internal enum class BubbleEdge { Left, Right }

/** Saved placement: the side it hugs and its height as a fraction of the free vertical range. */
internal data class BubblePlacement(val edge: BubbleEdge = BubbleEdge.Right, val fraction: Float = DEFAULT_BUBBLE_FRACTION)
internal const val DEFAULT_BUBBLE_FRACTION = .62f

/** Where the bubble's whole square may sit, in px: safe insets, top bar and composer region excluded. */
internal data class BubbleArea(val left: Float, val top: Float, val right: Float, val bottom: Float)

/**
 * The allowed area for a [size] px bubble in a [width]×[height] window. [insetBottom] is the larger
 * of the navigation bar and the keyboard, so the bubble slides up while typing. [reserveBottom]
 * keeps it above the composer and its send button. Always leaves room for one bubble.
 */
internal fun bubbleArea(width: Float, height: Float, size: Float, insetLeft: Float, insetTop: Float, insetRight: Float,
    insetBottom: Float, reserveTop: Float, reserveBottom: Float, margin: Float): BubbleArea {
    val left = insetLeft + margin
    val right = max(left + size, width - insetRight - margin)
    val top = insetTop + reserveTop + margin
    var bottom = height - insetBottom - reserveBottom - margin
    // A tall keyboard can eat the reserve; give up the reserve before the safe insets.
    if (bottom - top < size) bottom = max(height - insetBottom - margin, top + size)
    val clampedTop = if (bottom - top < size) max(insetTop + margin, bottom - size) else top
    return BubbleArea(left, clampedTop, right, max(bottom, clampedTop + size))
}

/** Top-left corner for [placement] inside [area]. */
internal fun bubbleOffset(placement: BubblePlacement, area: BubbleArea, size: Float): Offset {
    val range = max(0f, area.bottom - area.top - size)
    val x = if (placement.edge == BubbleEdge.Left) area.left else area.right - size
    return Offset(x, area.top + placement.fraction.coerceIn(0f, 1f) * range)
}

/** Where a bubble dropped with its top-left at [at] settles: the nearer side, height clamped. */
internal fun snapBubble(at: Offset, area: BubbleArea, size: Float): BubblePlacement {
    val center = at.x + size / 2f
    val edge = if (center < (area.left + area.right) / 2f) BubbleEdge.Left else BubbleEdge.Right
    val range = area.bottom - area.top - size
    val fraction = if (range <= 0f) 0f else ((at.y - area.top) / range).coerceIn(0f, 1f)
    return BubblePlacement(edge, fraction)
}

// ---- Badge and pop-ups (pure, unit tested) ----

private fun chatKey(workspaceId: String, threadId: String) = "chat:$workspaceId\u001f$threadId"

/**
 * Everything that needs the user, deduplicated by chat: Home panes flagged across workspaces,
 * crew links waiting for approval or blocked/failed, and the companion's own pending approval.
 */
internal fun bubbleNeedKeys(needs: List<Pane>, crew: List<CompanionLink>, companionThread: ThreadSummary?): Set<String> {
    val keys = LinkedHashSet<String>()
    needs.forEach { pane -> keys += pane.thread_id?.let { chatKey(pane.workspace_id, it) } ?: "pane:${pane.id}" }
    crew.filter { crewStatus(it).needsYou }.forEach { keys += chatKey(it.workspace_id, it.local_thread_id) }
    companionThread?.takeIf { it.status == "waiting_approval" }?.let { keys += chatKey(it.workspace_id, it.thread_id) }
    return keys
}

/** "1" … "99", then "99+". */
internal fun badgeLabel(count: Int): String = if (count > 99) "99+" else count.toString()

internal fun bubbleDescription(name: String, count: Int): String = when (count) {
    0 -> "$name, nothing needs you"
    1 -> "$name, 1 thing needs you"
    else -> "$name, $count things need you"
}

/** One line of a reply for the speech bubble. */
internal fun replyPreview(body: String, max: Int = 80): String {
    val line = childReplySummary(body).ifEmpty { body.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty() }
    return if (line.length <= max) line else line.substring(0, max - 1).trimEnd() + "…"
}

/** What the bubble has already announced. Nothing is announced until it has seen one snapshot. */
internal data class BubbleSeen(val needs: Set<String> = emptySet(), val replyAt: Long? = null, val primed: Boolean = false)

internal sealed interface BubblePopup {
    data class NeedsYou(val count: Int) : BubblePopup
    data object Reply : BubblePopup
}

internal data class BubbleStep(val seen: BubbleSeen, val popup: BubblePopup?)

/**
 * Advances [seen] with the current needs and the companion's latest finished-reply time. Only a
 * collapsed bubble pops up: for a need it has not announced yet, else for a newer reply.
 */
internal fun bubbleStep(seen: BubbleSeen, needKeys: Set<String>, replyAt: Long?, collapsed: Boolean): BubbleStep {
    val latest = listOfNotNull(seen.replyAt, replyAt).maxOrNull()
    val next = BubbleSeen(needKeys, latest, primed = true)
    if (!seen.primed || !collapsed) return BubbleStep(next, null)
    if ((needKeys - seen.needs).isNotEmpty()) return BubbleStep(next, BubblePopup.NeedsYou(needKeys.size))
    if (replyAt != null && seen.replyAt != null && replyAt > seen.replyAt) return BubbleStep(next, BubblePopup.Reply)
    return BubbleStep(next, null)
}

// ---- Preferences ----

/** Device-local bubble preferences (shown or hidden, last side and height). */
internal class BubblePrefs private constructor(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("companion_bubble", Context.MODE_PRIVATE)
    var hidden by mutableStateOf(preferences.getBoolean("hidden", false))
        private set
    var placement by mutableStateOf(BubblePlacement(
        if (preferences.getString("edge", null) == "left") BubbleEdge.Left else BubbleEdge.Right,
        preferences.getFloat("fraction", DEFAULT_BUBBLE_FRACTION).coerceIn(0f, 1f)))
        private set

    fun updateHidden(value: Boolean) {
        hidden = value
        preferences.edit().putBoolean("hidden", value).apply()
    }

    fun place(value: BubblePlacement) {
        placement = value
        preferences.edit().putString("edge", if (value.edge == BubbleEdge.Left) "left" else "right").putFloat("fraction", value.fraction).apply()
    }

    companion object {
        @Volatile private var instance: BubblePrefs? = null
        fun of(context: Context): BubblePrefs = instance ?: synchronized(this) { instance ?: BubblePrefs(context).also { instance = it } }
    }
}

/** Animations off (developer option or accessibility "remove animations"). */
internal fun reducedMotion(context: Context): Boolean =
    try { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f } catch (_: Exception) { false }

/** Settings row that brings a hidden bubble back. */
@Composable
internal fun CompanionBubbleSetting() {
    val context = LocalContext.current
    val prefs = remember(context) { BubblePrefs.of(context) }
    VerdeSection("Companion")
    Row(Modifier.fillMaxWidth().toggleable(!prefs.hidden, role = Role.Switch) { prefs.updateHidden(!it) }
        .padding(vertical = 12.dp).testTag("companion-bubble-setting"), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Show companion bubble", style = MaterialTheme.typography.bodyLarge)
            Text("A floating shortcut to your companion on every screen.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = !prefs.hidden, onCheckedChange = null)
    }
}

// ---- Overlay ----

/** Hold-to-talk hooks for the bubble; null when this phone has no speech recognizer. */
internal class BubbleTalk(
    val state: TalkState,
    val level: Float,
    val speaking: Boolean,
    val error: String?,
    /** Starts listening; false when it could not (no permission yet, no conversation). */
    val start: () -> Boolean,
    val move: (outside: Boolean) -> Unit,
    val release: () -> Unit,
    val cancel: () -> Unit,
    val stopSpeaking: () -> Unit,
    val clearError: () -> Unit,
)

/** Live (real-time) voice hooks for the bubble: double-tap starts, tap ends. */
internal class BubbleLive(val active: Boolean, val level: Float, val caption: String?, val toggle: () -> Unit)

/** What the speech chip says while talking: live words, cancel hint, or sending. */
internal fun talkChip(state: TalkState): String? = when (state) {
    TalkState.Idle -> null
    is TalkState.Listening -> when {
        state.cancelArmed -> "Release to cancel"
        state.partial.isNotBlank() -> state.partial
        else -> "Listening…"
    }
    is TalkState.Finishing -> state.partial.ifBlank { "Sending…" }
}

/**
 * Full-window overlay holding the bubble. It never consumes touches outside the bubble and its
 * speech chip. While [shown] is false nothing is drawn, but needs/replies are still marked seen.
 */
@Composable
internal fun CompanionBubbleLayer(
    shown: Boolean,
    hostId: String?,
    name: String,
    character: CompanionCharacter,
    pose: CompanionPose,
    needKeys: Set<String>,
    running: Boolean,
    replyAt: Long?,
    replyText: () -> String?,
    talk: BubbleTalk?,
    live: BubbleLive? = null,
    onOpen: () -> Unit,
) {
    val context = LocalContext.current
    val prefs = remember(context) { BubblePrefs.of(context) }
    var seen by remember(hostId) { mutableStateOf(BubbleSeen()) }
    var popup by remember(hostId) { mutableStateOf<Pair<Int, String>?>(null) }
    var serial by remember { mutableIntStateOf(0) }
    LaunchedEffect(needKeys, replyAt, shown) {
        val step = bubbleStep(seen, needKeys, replyAt, collapsed = shown)
        seen = step.seen
        when (val kind = step.popup) {
            is BubblePopup.NeedsYou -> popup = ++serial to "$name: ${companionStatusLine(CompanionPulse(kind.count, 0))}"
            BubblePopup.Reply -> popup = ++serial to "$name: ${replyText()?.takeIf { it.isNotBlank() } ?: "replied"}"
            null -> Unit
        }
    }
    LaunchedEffect(popup?.first) {
        if (popup != null) { delay(BUBBLE_POPUP_MS); popup = null }
    }
    LaunchedEffect(shown) { if (!shown) popup = null }
    val talkError = talk?.error
    LaunchedEffect(talkError) { if (talkError != null) { delay(BUBBLE_POPUP_MS); talk?.clearError() } }
    if (!shown) return
    val liveOn = live?.takeIf { it.active }
    val chip = if (liveOn != null) "Live" + (liveOn.caption?.takeIf { it.isNotBlank() }?.let { " \u00b7 $it" } ?: "")
        else talk?.let { talkChip(it.state) } ?: talkError ?: popup?.second
    CompanionBubble(prefs, name, character, pose, needKeys.size, running, chip, talk, live,
        // While Live, a tap ends it; otherwise it opens the sheet.
        onOpen = {
            popup = null
            talk?.stopSpeaking()
            val ending = live?.takeIf { it.active }
            if (ending != null) ending.toggle() else onOpen()
        },
        onHide = { popup = null; prefs.updateHidden(true) })
}

private enum class BubbleGesture { Tap, Drag, Hold }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CompanionBubble(prefs: BubblePrefs, name: String, character: CompanionCharacter, pose: CompanionPose, count: Int,
    running: Boolean, chip: String?, talk: BubbleTalk?, live: BubbleLive?, onOpen: () -> Unit, onHide: () -> Unit) {
    val context = LocalContext.current
    val reduced = remember(context) { reducedMotion(context) }
    val haptics = LocalHapticFeedback.current
    val currentTalk by rememberUpdatedState(talk)
    val currentOpen by rememberUpdatedState(onOpen)
    val currentLive by rememberUpdatedState(live)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val direction = LocalLayoutDirection.current
        val size = with(density) { BUBBLE_SIZE.toPx() }
        val safe = WindowInsets.safeDrawing
        val area = bubbleArea(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat(), size,
            safe.getLeft(density, direction).toFloat(), safe.getTop(density).toFloat(), safe.getRight(density, direction).toFloat(),
            safe.getBottom(density).toFloat(), reserveTop = with(density) { 56.dp.toPx() },
            reserveBottom = with(density) { 88.dp.toPx() }, margin = with(density) { 8.dp.toPx() })
        val currentArea by rememberUpdatedState(area)
        val position = remember { Animatable(bubbleOffset(prefs.placement, area, size), Offset.VectorConverter) }
        var dragging by remember { mutableStateOf(false) }
        val scope = rememberCoroutineScope()
        // Settle on the saved side, and slide with the keyboard or rotation.
        LaunchedEffect(area, prefs.placement, dragging) {
            if (dragging) return@LaunchedEffect
            val target = bubbleOffset(prefs.placement, area, size)
            if (reduced) position.snapTo(target) else position.animateTo(target, spring(dampingRatio = .75f, stiffness = Spring.StiffnessMediumLow))
        }
        val gap = with(density) { 8.dp.toPx() }
        val onLeft = position.value.x + size / 2f < (area.left + area.right) / 2f
        val talking = talk != null && talk.state !is TalkState.Idle
        chip?.let { text ->
            Surface(onClick = { if (!talking) onOpen() }, shape = RoundedCornerShape(14.dp),
                color = if (talk?.state.let { it is TalkState.Listening && it.cancelArmed }) VerdeColors.DangerPanel else VerdeColors.Panel,
                shadowElevation = 6.dp, border = androidx.compose.foundation.BorderStroke(1.dp, VerdeColors.Border),
                modifier = Modifier.layout { measurable, constraints ->
                    val maxWidth = max(0, (constraints.maxWidth * .7f).roundToInt())
                    val placeable = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0, maxWidth = maxWidth))
                    layout(constraints.maxWidth, constraints.maxHeight) {
                        // A window-sized node without pointer handlers of its own: only the chip takes touches.
                        val x = if (onLeft) position.value.x + size + gap else position.value.x - gap - placeable.width
                        val y = position.value.y + (size - placeable.height) / 2f
                        placeable.place(x.roundToInt(), y.roundToInt())
                    }
                }.testTag(COMPANION_BUBBLE_POPUP)) {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (talk != null && talk.state is TalkState.Listening) LevelBars(talk.level)
                    Text(text, style = MaterialTheme.typography.bodySmall, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        Box(Modifier.offset { IntOffset(position.value.x.roundToInt(), position.value.y.roundToInt()) }.size(BUBBLE_SIZE)) {
            Box(Modifier.fillMaxSize()
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        var moved: PointerInputChange? = null
                        // Tap opens, an early drag moves the bubble, holding still talks.
                        val gesture = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                            val slop = awaitTouchSlopOrCancellation(down.id) { change, _ -> change.consume() }
                            if (slop == null) BubbleGesture.Tap else { moved = slop; BubbleGesture.Drag }
                        } ?: BubbleGesture.Hold
                        when (gesture) {
                            BubbleGesture.Tap -> {
                                // Double-tap toggles Live; a single tap (or any tap while Live) opens / ends.
                                val liveHooks = currentLive
                                if (liveHooks == null || liveHooks.active) currentOpen()
                                else {
                                    val second = withTimeoutOrNull(viewConfiguration.doubleTapTimeoutMillis) { awaitFirstDown() }
                                    if (second == null) currentOpen()
                                    else { second.consume(); waitForUpOrCancellation(); liveHooks.toggle() }
                                }
                            }
                            BubbleGesture.Drag -> {
                                dragging = true
                                moved?.let { first -> val delta = first.positionChange(); scope.launch { position.snapTo(position.value + delta) } }
                                drag(down.id) { change ->
                                    val delta = change.positionChange()
                                    change.consume()
                                    scope.launch { position.snapTo(position.value + delta) }
                                }
                                prefs.place(snapBubble(position.value, currentArea, size))
                                dragging = false
                            }
                            BubbleGesture.Hold -> {
                                val hooks = currentTalk
                                if (hooks == null) { currentOpen(); return@awaitEachGesture }
                                if (!hooks.start()) return@awaitEachGesture
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                val center = Offset(size / 2f, size / 2f)
                                while (true) {
                                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                                    if (change == null) { hooks.cancel(); break }
                                    if (!change.pressed) { change.consume(); hooks.release(); break }
                                    change.consume()
                                    // Dragging well off the bubble arms cancel; coming back disarms it.
                                    hooks.move((change.position - center).getDistance() > size * 1.25f)
                                }
                            }
                        }
                    }
                }
                .semantics {
                    role = Role.Button
                    contentDescription = bubbleDescription(name, count)
                    onClick(label = "Open $name") { onOpen(); true }
                    customActions = buildList {
                        if (talk != null) add(CustomAccessibilityAction(if (talking) "Stop and send" else "Talk to $name") {
                            if (talking) talk.release() else talk.start()
                            true
                        })
                        if (talk?.speaking == true) add(CustomAccessibilityAction("Stop speaking") { talk?.stopSpeaking(); true })
                        if (live != null) add(CustomAccessibilityAction(if (live.active) "End live voice" else "Start live voice") { live.toggle(); true })
                        add(CustomAccessibilityAction("Hide bubble") { onHide(); true })
                    }
                }
                .testTag(COMPANION_BUBBLE)) {
                val liveOn = live?.active == true
                if (liveOn) LiveRing(live?.level ?: 0f) else if (running || talking) RunningRing(reduced)
                Box(Modifier.align(Alignment.Center).size(50.dp)
                    .background(if (talking) VerdeColors.AccentWash else VerdeColors.Panel, CircleShape)
                    .border(1.dp, if (talking) VerdeColors.Accent else if (count > 0) VerdeColors.Warning else VerdeColors.Border, CircleShape),
                    contentAlignment = Alignment.Center) {
                    CompanionAvatar(character, if (talking) CompanionPose.Working else pose, size = 42.dp)
                }
                if (count > 0) Box(Modifier.align(Alignment.TopEnd).defaultMinSize(minWidth = 18.dp, minHeight = 18.dp)
                    .background(VerdeColors.Danger, CircleShape).border(1.5.dp, VerdeColors.Background, CircleShape)
                    .padding(horizontal = 4.dp), contentAlignment = Alignment.Center) {
                    Text(badgeLabel(count), color = VerdeColors.Background, style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp, lineHeight = 12.sp))
                }
            }
        }
    }
}

/** Live: an accent ring that swells with the conversation's loudness. */
@Composable
private fun BoxScope.LiveRing(level: Float) {
    val width by androidx.compose.animation.core.animateDpAsState((2f + 4f * level.coerceIn(0f, 1f)).dp, label = "Live ring")
    Box(Modifier.matchParentSize().border(width, VerdeColors.Accent, CircleShape))
}

/** Microphone level as four small bars. */
@Composable
internal fun LevelBars(level: Float, modifier: Modifier = Modifier) {
    Row(modifier.height(16.dp).semantics { contentDescription = "Microphone level" }, verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        listOf(.45f, .8f, 1f, .6f).forEach { weight ->
            val fraction = (.2f + .8f * (level * weight).coerceIn(0f, 1f))
            Box(Modifier.width(3.dp).fillMaxHeight(fraction).background(VerdeColors.Accent, RoundedCornerShape(1.5.dp)))
        }
    }
}

private val BUBBLE_SIZE = 56.dp

/** A soft accent ring while crew or the companion is running; static when animations are off. */
@Composable
private fun BoxScope.RunningRing(reduced: Boolean) {
    val alpha = if (reduced) 1f else {
        val transition = rememberInfiniteTransition(label = "Companion crew running")
        transition.animateFloat(initialValue = .35f, targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "Ring").value
    }
    Box(Modifier.matchParentSize().alpha(alpha).border(2.dp, VerdeColors.Accent, CircleShape))
}

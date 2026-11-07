package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Home
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.geometry.Rect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/*
 * Adaptive layout rules, driven by the window's width and never by the device model. Material's
 * 840dp "expanded" class is deliberately not used: a large foldable's inner screen is narrower.
 */

internal const val MEDIUM_WINDOW_DP = 600f
internal const val TWO_PANE_WINDOW_DP = 700f
internal const val THREE_PANE_WINDOW_DP = 1000f

internal val SIDEBAR_WIDTH = 300.dp
internal val SIDEBAR_RAIL_WIDTH = 56.dp
internal val MOSS_PANE_WIDTH = 320.dp
internal val MOSS_SLOT_WIDTH = 340.dp
internal val TRANSCRIPT_TEXT_MAX_WIDTH = 720.dp

internal const val SHELL_SIDEBAR = "shell-sidebar"
internal const val SHELL_RAIL = "shell-rail"
internal const val SHELL_MOSS = "shell-moss"
internal const val SHELL_CONTENT = "shell-content"

internal enum class WindowTier {
    /** Under 600dp: the phone layout, cover screens included. */
    Compact,
    /** 600dp up: one pane, compact composer, Commit bar in the chat header, capped transcript text. */
    Medium,
    /** 700dp up: permanent sidebar beside the content; Moss takes the sidebar's slot while open. */
    TwoPane,
    /** 1000dp up: Moss gets a third pane while open. */
    ThreePane;

    val wide get() = this != Compact
    val docked get() = this == TwoPane || this == ThreePane
}

internal fun windowTier(widthDp: Float): WindowTier = when {
    widthDp >= THREE_PANE_WINDOW_DP -> WindowTier.ThreePane
    widthDp >= TWO_PANE_WINDOW_DP -> WindowTier.TwoPane
    widthDp >= MEDIUM_WINDOW_DP -> WindowTier.Medium
    else -> WindowTier.Compact
}

/** The window's tier; Compact where no shell provides one (screen tests). */
internal val LocalWindowTier = staticCompositionLocalOf { WindowTier.Compact }

/** Measures the real width (split-screen and freeform too) and provides its tier. */
@Composable
internal fun AdaptiveWindow(content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val hinge = rememberHalfOpenHinge()
        CompositionLocalProvider(LocalWindowTier provides windowTier(maxWidth.value), LocalHalfOpenHinge provides hinge, content = content)
    }
}

internal enum class SidebarMode { Hidden, Full, Rail }

/** Where an open Moss goes; None whenever it is closed, so it never takes or reserves space by itself. */
internal enum class MossPlacement { None, Sheet, SidebarSlot, ThirdPane }

internal data class ShellPanes(val sidebar: SidebarMode, val moss: MossPlacement)

/** Which panes a window shows. [mossOpen] only ever comes from the user opening Moss. */
internal fun shellPanes(tier: WindowTier, collapsed: Boolean, mossOpen: Boolean, pairing: Boolean): ShellPanes {
    val moss = when {
        !mossOpen -> MossPlacement.None
        tier == WindowTier.ThreePane -> MossPlacement.ThirdPane
        tier == WindowTier.TwoPane -> MossPlacement.SidebarSlot
        else -> MossPlacement.Sheet
    }
    val sidebar = when {
        !tier.docked || pairing || moss == MossPlacement.SidebarSlot -> SidebarMode.Hidden
        collapsed -> SidebarMode.Rail
        else -> SidebarMode.Full
    }
    return ShellPanes(sidebar, moss)
}

/**
 * The docked shell's panes. [content] keeps one call path at every width and pane count, because
 * `rememberSaveable` keys on that path and a fold recreates the activity: a different path would
 * lose the open chat's scroll position and every other saved value under the NavHost.
 */
@Composable
internal fun AdaptiveShellFrame(panes: ShellPanes, sidebar: @Composable () -> Unit, rail: @Composable () -> Unit,
    moss: @Composable () -> Unit, content: @Composable () -> Unit) {
    // These panes sit outside any Surface, whose content color icons and text would otherwise inherit.
    CompositionLocalProvider(LocalContentColor provides VerdeColors.Text) {
    val hinge = LocalHalfOpenHinge.current?.takeUnless { it.horizontal }
    val density = LocalDensity.current
    var bounds by remember { mutableStateOf<Rect?>(null) }
    val segments = bounds?.let { area -> hinge?.let {
        hingeSegments(area.left, area.right, it.bounds.left, it.bounds.right, with(density) { 8.dp.toPx() })
    } }
    val sideWidth = segments?.let { with(density) { it.before.toDp() } }
    Row(Modifier.fillMaxSize().onGloballyPositioned { bounds = it.boundsInWindow() }) {
        when (panes.sidebar) {
            SidebarMode.Full -> {
                Box(Modifier.width(sideWidth ?: SIDEBAR_WIDTH).fillMaxHeight().testTag(SHELL_SIDEBAR)) { sidebar() }
                if (segments == null) PaneDivider()
            }
            SidebarMode.Rail -> {
                Box(Modifier.width(sideWidth ?: SIDEBAR_RAIL_WIDTH).fillMaxHeight().testTag(SHELL_RAIL)) { rail() }
                if (segments == null) PaneDivider()
            }
            SidebarMode.Hidden -> Unit
        }
        if (panes.moss == MossPlacement.SidebarSlot) {
            // r5: a little wider than the sidebar, so the companion's composer shows its brain in full
            // ("Codex · GPT-6.1 Sol") beside the attach, mic and send controls.
            MossPane(sideWidth ?: MOSS_SLOT_WIDTH, WindowInsetsSides.Start, moss)
            if (segments == null) PaneDivider()
        }
        if (segments != null) {
            if (panes.sidebar == SidebarMode.Hidden && panes.moss != MossPlacement.SidebarSlot)
                Spacer(Modifier.width(sideWidth ?: 0.dp))
            Spacer(Modifier.width(with(density) { segments.gap.toDp() }))
        }
        Box(Modifier.weight(1f).fillMaxHeight().testTag(SHELL_CONTENT)) {
            // A book posture's content pane is a cover-sized window even when the full display is wide.
            CompositionLocalProvider(LocalWindowTier provides (segments?.let { windowTier(it.after / density.density) } ?: LocalWindowTier.current)) {
                content()
            }
        }
        if (panes.moss == MossPlacement.ThirdPane) {
            PaneDivider()
            MossPane(MOSS_PANE_WIDTH, WindowInsetsSides.End, moss)
        }
    }
    }
}

@Composable
private fun MossPane(width: androidx.compose.ui.unit.Dp, edge: WindowInsetsSides, moss: @Composable () -> Unit) {
    // The bottom inset includes the keyboard, which consumes the composer's own imePadding.
    Box(Modifier.background(VerdeColors.Background).fillMaxHeight().testTag(SHELL_MOSS)
        .windowInsetsPadding(WindowInsets.safeDrawing.only(edge + WindowInsetsSides.Vertical)).width(width)) { moss() }
}

@Composable
private fun PaneDivider() = VerticalDivider(color = VerdeColors.Border)

/** The content pane's insets: side panes own the edges they sit on. Phones get all of them, as before. */
@Composable
internal fun contentWindowInsets(tier: WindowTier, panes: ShellPanes): WindowInsets {
    if (!tier.docked) return WindowInsets.safeDrawing
    var sides = WindowInsetsSides.Vertical
    if (panes.sidebar == SidebarMode.Hidden && panes.moss != MossPlacement.SidebarSlot) sides += WindowInsetsSides.Start
    if (panes.moss != MossPlacement.ThirdPane) sides += WindowInsetsSides.End
    return WindowInsets.safeDrawing.only(sides)
}

/** The collapsed sidebar: expand, new chat and Moss stay reachable while content gets nearly the full width. */
@Composable
internal fun SidebarRail(onExpand: () -> Unit, onNewChat: () -> Unit, dock: (@Composable ColumnScope.() -> Unit)?,
    currentTab: String = "", onTab: (String) -> Unit = {}, onSettings: (() -> Unit)? = null) {
    Column(Modifier.fillMaxHeight().background(VerdeColors.Panel)
        .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Start + WindowInsetsSides.Vertical))
        .width(SIDEBAR_RAIL_WIDTH), horizontalAlignment = Alignment.CenterHorizontally) {
        IconButton(onClick = onExpand, modifier = Modifier.named("Expand sidebar")) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) }
        IconButton(onClick = onNewChat, modifier = Modifier.named("New chat")) { Icon(Icons.Filled.Add, null) }
        Spacer(Modifier.weight(1f))
        dock?.invoke(this)
        // F8: the collapsed rail keeps the four destinations (icons only), so they stay one tap away.
        @Composable fun tab(label: String, icon: androidx.compose.ui.graphics.painter.Painter, active: Boolean, go: () -> Unit) {
            IconButton(onClick = go, modifier = Modifier.background(if (active) VerdeColors.AccentWash else VerdeColors.Panel, androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                .named(label).semantics { selected = active }) {
                Icon(icon, contentDescription = null, tint = if (active) VerdeColors.AccentHi else VerdeColors.Muted)
            }
        }
        tab("Home", androidx.compose.ui.graphics.vector.rememberVectorPainter(Icons.Filled.Home), currentTab == Routes.HOME) { onTab(Routes.HOME) }
        tab("Workspaces", androidx.compose.ui.res.painterResource(R.drawable.ic_folder), currentTab == Routes.WORKSPACES) { onTab(Routes.WORKSPACES) }
        tab("Hosts", androidx.compose.ui.res.painterResource(R.drawable.host_machine), currentTab == Routes.HOSTS) { onTab(Routes.HOSTS) }
        onSettings?.let { tab("Settings", androidx.compose.ui.res.painterResource(R.drawable.ic_settings), currentTab == Routes.SECURITY, it) }
    }
}

/**
 * One transcript item. S17: on wide windows the transcript stops at [TRANSCRIPT_TEXT_MAX_WIDTH], centred
 * (tool rows included); only diffs use the pane. One call path at every width keeps each
 * row's saved expansion across a fold.
 */
@Composable
internal fun TranscriptItemFrame(item: TranscriptItem, content: @Composable () -> Unit) {
    val capped = LocalWindowTier.current.wide && !transcriptItemGoesWide(item)
    Box(if (capped) Modifier.fillMaxWidth().wrapContentWidth(Alignment.CenterHorizontally)
        .widthIn(max = TRANSCRIPT_TEXT_MAX_WIDTH).fillMaxWidth() else Modifier.fillMaxWidth()) { content() }
}

internal fun transcriptItemGoesWide(item: TranscriptItem): Boolean = item is TranscriptItem.Diff

/** Half-open fold coordinates in the app window, in either tabletop or book posture. */
internal data class HalfOpenHinge(val bounds: Rect, val horizontal: Boolean)
internal val LocalHalfOpenHinge = staticCompositionLocalOf<HalfOpenHinge?> { null }
internal data class HingeSegments(val before: Float, val gap: Float, val after: Float)

/** Leave clearance on both sides even for a zero-width crease. Reject folds outside this pane. */
internal fun hingeSegments(start: Float, end: Float, hingeStart: Float, hingeEnd: Float, clearance: Float): HingeSegments? {
    val before = hingeStart - clearance - start
    val after = end - hingeEnd - clearance
    if (before <= 0f || after <= 0f) return null
    return HingeSegments(before, hingeEnd - hingeStart + 2f * clearance, after)
}

@Composable
private fun rememberHalfOpenHinge(): HalfOpenHinge? {
    val context = androidx.compose.ui.platform.LocalContext.current
    val activity = remember(context) {
        generateSequence(context) { (it as? android.content.ContextWrapper)?.baseContext }.filterIsInstance<android.app.Activity>().firstOrNull()
    } ?: return null
    val layouts = remember(activity) {
        runCatching { androidx.window.layout.WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity) }
            .getOrElse { kotlinx.coroutines.flow.emptyFlow() }
    }
    val info by layouts.collectAsState(initial = null)
    val fold = info?.displayFeatures?.filterIsInstance<androidx.window.layout.FoldingFeature>()?.firstOrNull {
        it.state == androidx.window.layout.FoldingFeature.State.HALF_OPENED
    } ?: return null
    return HalfOpenHinge(Rect(fold.bounds.left.toFloat(), fold.bounds.top.toFloat(), fold.bounds.right.toFloat(), fold.bounds.bottom.toFloat()), fold.orientation == androidx.window.layout.FoldingFeature.Orientation.HORIZONTAL)
}

@Composable
internal fun rememberTabletopHinge(): Pair<Float, Float>? = LocalHalfOpenHinge.current?.takeIf { it.horizontal }?.let {
    it.bounds.top to it.bounds.bottom
}

package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
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
        CompositionLocalProvider(LocalWindowTier provides windowTier(maxWidth.value), content = content)
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
    Row(Modifier.fillMaxSize()) {
        when (panes.sidebar) {
            SidebarMode.Full -> {
                Box(Modifier.width(SIDEBAR_WIDTH).fillMaxHeight().testTag(SHELL_SIDEBAR)) { sidebar() }
                PaneDivider()
            }
            SidebarMode.Rail -> {
                Box(Modifier.fillMaxHeight().testTag(SHELL_RAIL)) { rail() }
                PaneDivider()
            }
            SidebarMode.Hidden -> Unit
        }
        if (panes.moss == MossPlacement.SidebarSlot) {
            MossPane(SIDEBAR_WIDTH, WindowInsetsSides.Start, moss)
            PaneDivider()
        }
        Box(Modifier.weight(1f).fillMaxHeight().testTag(SHELL_CONTENT)) { content() }
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
internal fun SidebarRail(onExpand: () -> Unit, onNewChat: () -> Unit, dock: (@Composable ColumnScope.() -> Unit)?) {
    Column(Modifier.fillMaxHeight().background(VerdeColors.Panel)
        .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Start + WindowInsetsSides.Vertical))
        .width(SIDEBAR_RAIL_WIDTH), horizontalAlignment = Alignment.CenterHorizontally) {
        IconButton(onClick = onExpand) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, "Expand sidebar") }
        IconButton(onClick = onNewChat) { Icon(Icons.Filled.Add, "New chat") }
        Spacer(Modifier.weight(1f))
        dock?.invoke(this)
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

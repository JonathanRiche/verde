package dev.verdeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.width
import dev.verdeai.core.ChatCatalogs
import dev.verdeai.core.ChatChoice
import dev.verdeai.core.ChatRow
import dev.verdeai.core.ChatSelection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w1400dp-h900dp")
// Real text measurement: the default mode's fake metrics can't tell whether a label fits.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AdaptiveLayoutTest {
    @get:Rule val compose = createComposeRule()

    private val everyTier = WindowTier.entries

    @Test fun widthThresholdsPickTheTier() {
        // 320dp is a cover screen; ~750dp the Fold's inner screen, under Material's 840dp "expanded".
        mapOf(320f to WindowTier.Compact, 599.9f to WindowTier.Compact,
            600f to WindowTier.Medium, 699.9f to WindowTier.Medium,
            700f to WindowTier.TwoPane, 750f to WindowTier.TwoPane, 999.9f to WindowTier.TwoPane,
            1000f to WindowTier.ThreePane, 1400f to WindowTier.ThreePane)
            .forEach { (width, tier) -> assertEquals("$width dp", tier, windowTier(width)) }
    }

    @Test fun mossNeverPlacesItselfUnlessOpened() {
        for (tier in everyTier) for (collapsed in listOf(false, true)) for (pairing in listOf(false, true)) {
            assertEquals(MossPlacement.None, shellPanes(tier, collapsed, mossOpen = false, pairing).moss)
        }
    }

    @Test fun anOpenMossGoesWhereTheWindowHasRoom() {
        fun moss(tier: WindowTier) = shellPanes(tier, collapsed = false, mossOpen = true, pairing = false)
        assertEquals(ShellPanes(SidebarMode.Hidden, MossPlacement.Sheet), moss(WindowTier.Compact))
        assertEquals(ShellPanes(SidebarMode.Hidden, MossPlacement.Sheet), moss(WindowTier.Medium))
        // It takes over the sidebar's slot only here, and only while open.
        assertEquals(ShellPanes(SidebarMode.Hidden, MossPlacement.SidebarSlot), moss(WindowTier.TwoPane))
        assertEquals(ShellPanes(SidebarMode.Full, MossPlacement.ThirdPane), moss(WindowTier.ThreePane))
    }

    @Test fun sidebarIsPermanentOnlyFromTwoPanes() {
        fun sidebar(tier: WindowTier, collapsed: Boolean = false, pairing: Boolean = false) = shellPanes(tier, collapsed, false, pairing).sidebar
        assertEquals(SidebarMode.Hidden, sidebar(WindowTier.Compact))
        assertEquals(SidebarMode.Hidden, sidebar(WindowTier.Medium))
        assertEquals(SidebarMode.Full, sidebar(WindowTier.TwoPane))
        assertEquals(SidebarMode.Full, sidebar(WindowTier.ThreePane))
        assertEquals(SidebarMode.Rail, sidebar(WindowTier.TwoPane, collapsed = true))
        assertEquals(SidebarMode.Hidden, sidebar(WindowTier.Compact, collapsed = true))
        assertEquals(SidebarMode.Hidden, sidebar(WindowTier.TwoPane, pairing = true))
    }

    /** The frame at a real measured width, with a Moss flag the test controls. */
    private fun frame(width: Int, mossOpen: () -> Boolean, collapsed: () -> Boolean = { false }) {
        compose.setContent {
            Box(Modifier.requiredWidth(width.dp)) {
                AdaptiveWindow {
                    val tier = LocalWindowTier.current
                    val panes = shellPanes(tier, collapsed(), mossOpen(), pairing = false)
                    AdaptiveShellFrame(panes, sidebar = { Text("Chats") }, rail = { Text("Rail") },
                        moss = { Text("Moss") }, content = { Text("Content") })
                }
            }
        }
    }

    private fun contentWidth() = compose.onNodeWithTag(SHELL_CONTENT).getUnclippedBoundsInRoot().width

    @Test fun closedMossReservesNoSpaceAtTwoPanes() {
        frame(750, { false })
        compose.onNodeWithTag(SHELL_SIDEBAR).assertWidthIsEqualTo(SIDEBAR_WIDTH)
        compose.onNodeWithTag(SHELL_MOSS).assertDoesNotExist()
        contentWidth().let { assertTrue("$it", it >= (750 - 300 - 2).dp) }
    }

    @Test fun closedMossReservesNoSpaceAtThreePanes() {
        frame(1200, { false })
        compose.onNodeWithTag(SHELL_MOSS).assertDoesNotExist()
        contentWidth().let { assertTrue("$it", it >= (1200 - 300 - 2).dp) }
    }

    @Test fun mossSwapsWithTheSidebarAndGivesItBack() {
        var open by mutableStateOf(false)
        frame(750, { open })
        compose.onNodeWithText("Chats").assertExists()
        open = true
        compose.waitForIdle()
        compose.onNodeWithText("Chats").assertDoesNotExist()
        compose.onNodeWithTag(SHELL_MOSS).assertWidthIsEqualTo(MOSS_SLOT_WIDTH)
        open = false
        compose.waitForIdle()
        compose.onNodeWithText("Chats").assertExists()
        compose.onNodeWithTag(SHELL_MOSS).assertDoesNotExist()
    }

    @Test fun mossGetsItsOwnPaneOnAWideWindow() {
        frame(1200, { true })
        compose.onNodeWithText("Chats").assertExists()
        compose.onNodeWithText("Moss").assertExists()
        compose.onNodeWithTag(SHELL_MOSS).assertWidthIsEqualTo(MOSS_PANE_WIDTH)
    }

    @Test fun nothingBesideTheContentBelowTwoPanes() {
        frame(650, { false })
        compose.onNodeWithTag(SHELL_SIDEBAR).assertDoesNotExist()
        compose.onNodeWithTag(SHELL_RAIL).assertDoesNotExist()
        compose.onNodeWithTag(SHELL_CONTENT).assertWidthIsEqualTo(650.dp)
    }

    @Test fun collapsedSidebarLeavesARail() {
        frame(750, { false }, collapsed = { true })
        compose.onNodeWithTag(SHELL_SIDEBAR).assertDoesNotExist()
        compose.onNodeWithText("Rail").assertExists()
    }

    /**
     * A fold recreates the activity at another width. `rememberSaveable` keys on the call path, so
     * the content (the NavHost, the transcript's scroll) must keep its path between layouts.
     */
    @Test fun contentStateSurvivesRecreationAtAnotherWidth() {
        var width by mutableIntStateOf(400)
        var moss by mutableStateOf(false)
        val tester = StateRestorationTester(compose)
        tester.setContent {
            Box(Modifier.requiredWidth(width.dp)) {
                AdaptiveWindow {
                    val panes = shellPanes(LocalWindowTier.current, collapsed = false, mossOpen = moss, pairing = false)
                    AdaptiveShellFrame(panes, sidebar = { Text("Chats") }, rail = {}, moss = { Text("Moss") }) {
                        var count by rememberSaveable { mutableIntStateOf(0) }
                        TextButton(onClick = { count++ }, Modifier.testTag("counter")) { Text("count $count") }
                    }
                }
            }
        }
        compose.onNodeWithTag("counter").performClick()
        compose.onNodeWithText("count 1").assertExists()

        // Unfold, fold, and unfold with Moss open at each pane count.
        for ((w, m) in listOf(750 to false, 400 to false, 750 to true, 1200 to true, 650 to false)) {
            width = w
            moss = m
            tester.emulateSavedInstanceStateRestore()
            compose.onNodeWithText("count 1").assertExists()
        }
    }

    @Test fun transcriptTextAndToolsAreCappedButDiffsGoWide() {
        val message = TranscriptItem.Message(ChatRow("m", "assistant", body = "hello"))
        val diff = TranscriptItem.Diff(ChatRow("d", "tool", kind = "diff", body = "@@"))
        val tool = TranscriptItem.Tool(ChatRow("t", "tool", kind = "tool", body = "ls"))
        assertFalse(transcriptItemGoesWide(message))
        assertTrue(transcriptItemGoesWide(diff))
        assertFalse(transcriptItemGoesWide(tool))
        compose.setContent {
            CompositionLocalProvider(LocalWindowTier provides WindowTier.ThreePane) {
                Box(Modifier.requiredWidth(1200.dp)) {
                    androidx.compose.foundation.layout.Column(Modifier.fillMaxWidth()) {
                        TranscriptItemFrame(message) { Box(Modifier.fillMaxWidth().testTag("message")) }
                        TranscriptItemFrame(diff) { Box(Modifier.fillMaxWidth().testTag("diff")) }
                    }
                }
            }
        }
        compose.onNodeWithTag("message").assertWidthIsEqualTo(TRANSCRIPT_TEXT_MAX_WIDTH)
        compose.onNodeWithTag("diff").assertWidthIsEqualTo(1200.dp)
    }

    @Test fun phoneTranscriptIsNotCapped() {
        val message = TranscriptItem.Message(ChatRow("m", "assistant", body = "hello"))
        compose.setContent {
            Box(Modifier.requiredWidth(900.dp)) {
                TranscriptItemFrame(message) { Box(Modifier.fillMaxWidth().testTag("message")) }
            }
        }
        compose.onNodeWithTag("message").assertWidthIsEqualTo(900.dp)
    }

    /** Laid out on one line, not ellipsized, and within its measured box. */
    private fun overflows(text: String): Boolean {
        val results = mutableListOf<TextLayoutResult>()
        compose.onNode(hasText(text), useUnmergedTree = true).fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action?.invoke(results)
        val layout = results.single()
        return layout.lineCount != 1 || layout.isLineEllipsized(0) || layout.getLineRight(0) > layout.size.width + 1f
    }

    @Test fun sidebarTabsDoNotTruncate() {
        compose.setContent {
            VerdeTheme {
                Box(Modifier.requiredWidth(SIDEBAR_WIDTH)) {
                    WorkspaceDrawer(BrowseState(), Routes.HOME, visible = true, onClose = {}, onTab = {}, onThread = { _, _ -> },
                        onHistory = {}, scope = null, onScope = {}, onNewChat = {}, persistent = true)
                }
            }
        }
        listOf("Home", "Workspaces", "Hosts").forEach { assertFalse(it, overflows(it)) }
        compose.onNodeWithContentDescription("Collapse sidebar").assertExists()
        compose.onNodeWithContentDescription("Close workspace drawer").assertDoesNotExist()
    }

    private val longModel = "A rather long model display name"

    private fun composerRow(width: Int) {
        val catalogs = ChatCatalogs(models = listOf(ChatChoice("m", longModel)),
            efforts = listOf(ChatChoice("low", "Low"), ChatChoice("high", "High")),
            access = listOf(ChatChoice("ask", "Ask first")))
        compose.setContent {
            VerdeTheme {
                Box(Modifier.requiredWidth(width.dp)) {
                    WideComposerRow(catalogs, ChatSelection(provider = "claude", model = "m", effort = "high", access = "ask"), "claude",
                        fresh = false, onPicker = {}, attach = { Text("Attach") }, actions = { Text("Send") })
                }
            }
        }
    }

    @Test fun wideComposerKeepsEveryControlOnOneRow() {
        composerRow(700)
        val top = { label: String -> compose.onNode(hasText(label), useUnmergedTree = true).getUnclippedBoundsInRoot().let { (it.top + it.bottom) / 2 } }
        val center = top(longModel)
        listOf("Attach", "High", "Ask first", "Send").forEach { label ->
            assertTrue("$label centered with the model", (top(label) - center).value.let { kotlin.math.abs(it) < 2f })
        }
    }

    @Test fun modelChipNeitherTruncatesWithRoomNorStretches() {
        composerRow(700)
        assertFalse(overflows(longModel))
        val text = compose.onNode(hasText(longModel), useUnmergedTree = true).getUnclippedBoundsInRoot()
        val send = compose.onNodeWithText("Send").getUnclippedBoundsInRoot()
        val access = compose.onNode(hasText("Ask first"), useUnmergedTree = true).getUnclippedBoundsInRoot()
        // Unused room stays after the chips, before send, rather than inside the model chip.
        assertTrue("room was left for send", send.left - access.right > 40.dp)
        assertTrue("label starts the chip", text.left < access.left)
    }

    @Test fun narrowChatKeepsTheRowOnScreen() {
        composerRow(380)
        val send = compose.onNodeWithText("Send").getUnclippedBoundsInRoot()
        assertTrue("send is inside the row: ${send.right}", send.right <= 380.dp)
        compose.onNodeWithContentDescription("Access: Ask first. Change").assertExists()
    }

    private fun dockState(opened: Boolean = false, talk: BubbleTalk? = null, live: BubbleLive? = null, onToggle: () -> Unit = {}) =
        CompanionDockState("Moss", CompanionCharacter.Moss, CompanionPose.Idle, 2, false, BubbleChip("Moss: replied") {}, talk, live, opened, onToggle)

    @Test fun dockKeepsTheBubblesAffordances() {
        val taps = mutableListOf<String>()
        val talk = BubbleTalk(TalkState.Idle, 0f, false, null, start = { taps += "talk"; true }, move = {}, release = {}, cancel = {},
            stopSpeaking = { taps += "quiet" }, clearError = {})
        val live = BubbleLive(false, { 0f }) { taps += "live" }
        compose.setContent { VerdeTheme { CompanionDock(dockState(talk = talk, live = live, onToggle = { taps += "open" })) } }
        compose.onNodeWithText("Moss: replied").assertExists()
        compose.onNodeWithContentDescription("Moss, 2 things need you").assertHasClickAction().performClick()
        compose.onNodeWithContentDescription("Talk to Moss").performClick()
        compose.onNodeWithContentDescription("Start live voice").performClick()
        assertEquals(listOf("quiet", "open", "talk", "live"), taps)
    }

    @Test fun dockTalkTapsToSendAndCanCancel() {
        val taps = mutableListOf<String>()
        val talk = BubbleTalk(TalkState.Listening("hi", false), 0f, false, null, start = { true }, move = {},
            release = { taps += "send" }, cancel = { taps += "cancel" }, stopSpeaking = {}, clearError = {})
        compose.setContent { VerdeTheme { CompanionDock(dockState(talk = talk)) } }
        compose.onNodeWithContentDescription("Stop and send").performClick()
        compose.onNodeWithContentDescription("Cancel recording").performClick()
        assertEquals(listOf("send", "cancel"), taps)
    }

    @Test fun sidePanesInheritTheThemeTextColor() {
        var rail: androidx.compose.ui.graphics.Color? = null
        var moss: androidx.compose.ui.graphics.Color? = null
        var text: androidx.compose.ui.graphics.Color? = null
        compose.setContent {
            VerdeTheme {
                text = VerdeColors.Text
                AdaptiveShellFrame(ShellPanes(SidebarMode.Rail, MossPlacement.SidebarSlot), sidebar = {},
                    rail = { rail = androidx.compose.material3.LocalContentColor.current },
                    moss = { moss = androidx.compose.material3.LocalContentColor.current }, content = {})
            }
        }
        compose.waitForIdle()
        assertEquals(text, rail)
        assertEquals(text, moss)
    }

    @Test fun railKeepsNewChatExpandAndMoss() {
        val taps = mutableListOf<String>()
        compose.setContent {
            VerdeTheme {
                Box(Modifier.fillMaxSize()) {
                    SidebarRail(onExpand = { taps += "expand" }, onNewChat = { taps += "new" },
                        dock = { CompanionRailDock(dockState(onToggle = { taps += "moss" })) })
                }
            }
        }
        compose.onNodeWithContentDescription("Expand sidebar").performClick()
        compose.onNodeWithContentDescription("New chat").performClick()
        compose.onNodeWithContentDescription("Moss, 2 things need you").performClick()
        assertEquals(listOf("expand", "new", "moss"), taps)
    }
}

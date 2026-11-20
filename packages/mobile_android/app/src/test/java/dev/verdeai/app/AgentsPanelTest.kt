package dev.verdeai.app

import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.verdeai.core.ChatOrchestration
import dev.verdeai.core.ChatPage
import dev.verdeai.core.ChatRow
import dev.verdeai.core.ChatSubagent
import dev.verdeai.core.ChatThreadView
import dev.verdeai.core.ChatTool
import dev.verdeai.core.ThreadSummary
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalTestApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AgentsPanelTest {
    @get:Rule val compose = createComposeRule()

    private val subagents = listOf(
        ChatSubagent(row_id = "turn:t:msg:2", tool_call_id = "agent-2", title = "Explore the repo", status = "running", status_label = "Working"),
        ChatSubagent(row_id = "saved-1", tool_call_id = "agent-1", title = "Fix the bug", status = "completed", status_label = "Done", updated_at_ms = 1_000),
    )

    @Test fun listsProviderSubagentsWhenThereAreNoLinkedChats() {
        val shown = mutableListOf<String>()
        compose.setContent {
            VerdeTheme {
                AgentsPanel(ChatOrchestration(loaded = true, subagents = subagents), close = {}, open = {}, provider = "claude",
                    showSubagent = { shown += it.row_id })
            }
        }
        compose.onNodeWithText("Claude subagents").assertIsDisplayed()
        compose.onNodeWithText("Explore the repo").assertIsDisplayed()
        compose.onNodeWithText("Fix the bug").assertIsDisplayed()
        compose.onNodeWithText("No agents yet", substring = true).assertDoesNotExist()
        compose.onNodeWithContentDescription("Explore the repo, Working. Show in transcript").assertHasClickAction().performClick()
        compose.runOnIdle { assertEquals(listOf("turn:t:msg:2"), shown) }
    }

    @Test fun subagentRowsAreKeyboardOperable() {
        val shown = mutableListOf<String>()
        var closed = 0
        val entry = FocusRequester()
        compose.setContent {
            VerdeTheme {
                AgentsPanel(ChatOrchestration(loaded = true, subagents = subagents), close = { closed++ }, open = {}, entryFocus = entry,
                    provider = "claude", showSubagent = { shown += it.row_id })
            }
        }
        compose.runOnIdle { entry.requestFocus() }
        compose.onRoot().performKeyInput { pressKey(Key.Tab) }
        compose.onNodeWithContentDescription("Explore the repo, Working. Show in transcript").assertIsFocused()
        compose.onRoot().performKeyInput { pressKey(Key.DirectionDown) }
        compose.onNodeWithContentDescription("Fix the bug, Done. Show in transcript").assertIsFocused()
        compose.onRoot().performKeyInput { pressKey(Key.Enter) }
        compose.runOnIdle { assertEquals(listOf("saved-1"), shown) }
        compose.onRoot().performKeyInput { pressKey(Key.Escape) }
        compose.runOnIdle { assertEquals(1, closed) }
    }

    @Test fun emptyStateOnlyWhenNeitherLinksNorSubagents() {
        compose.setContent { VerdeTheme { AgentsPanel(ChatOrchestration(loaded = true), close = {}, open = {}) } }
        compose.onNodeWithText("No agents yet. Linked chats and subagents will appear here.").assertIsDisplayed()
    }

    @Test fun headingNamesTheProvider() {
        assertEquals("Claude subagents", subagentsHeading("claude"))
        assertEquals("OpenCode subagents", subagentsHeading("opencode"))
        assertEquals("Acme subagents", subagentsHeading("acme"))
        assertEquals("Subagents", subagentsHeading(null))
        assertEquals("Subagents", subagentsHeading(""))
    }

    @Test fun aSubagentJumpFindsItsToolGroup() {
        val row = ChatRow(id = "saved-1", role = "system", kind = "tool", author = "Subagent", body = "Input:\nx",
            tool = ChatTool(id = "agent-1", kind = "subagent", status = "completed"))
        val items = transcriptItems(ChatThreadView(
            thread = ThreadSummary("w", "t", "Chat", "claude", null, null, open = true, archived = false, last_activity_at_ms = null,
                status = "idle", history_bucket = "today"),
            rows = listOf(row), page = ChatPage(has_older = false, cursor = null, loading = false),
            turn = null, approval = null, usage = null, stale = false, error = null))
        val group = items.single()
        assertTrue(group is TranscriptItem.ToolGroup && group.subagent)
        assertTrue(group.showsRow("saved-1"))
        assertFalse(group.showsRow("other"))
    }
}

package dev.verdeai.app

import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** S1: content screens carry the companion in their top app bar. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h900dp")
class CompanionHeaderTest {
    @get:Rule val compose = createComposeRule()

    private fun state(count: Int, running: Boolean = false, failed: Int = 0, onToggle: () -> Unit) = CompanionDockState("Sprout", CompanionCharacter.Sprout, CompanionPose.Idle, count,
        running = running, chip = BubbleChip(null) {}, talk = null, live = null, opened = false, onToggle = onToggle, failed = failed)

    @Test fun topBarShowsTheCompanionWithItsBadgeAndOpensIt() {
        var opened = 0
        compose.setContent {
            VerdeTheme {
                CompositionLocalProvider(LocalCompanionHeader provides state(1) { opened++ }) {
                    VerdeTopBar(title = { Text("Chat") })
                }
            }
        }
        compose.onNodeWithTag(COMPANION_HEADER).assertContentDescriptionEquals("Sprout, 1 thing needs you").performClick()
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1_000)
        assertEquals(1, opened)
    }

    @Test fun accessibleValueChangesWithTheCompanionsActualState() {
        var shown by mutableStateOf(state(0) {})
        compose.setContent { VerdeTheme { CompanionHeaderButton(shown) } }
        fun value(text: String) = compose.onNodeWithTag(COMPANION_HEADER)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, text))
        value("Ready")
        shown = state(0, running = true) {}; compose.waitForIdle(); value("Working")
        shown = state(0, failed = 1) {}; compose.waitForIdle(); value("Failed")
        shown = state(1) {}; compose.waitForIdle(); value("Needs you")
        assertEquals("Listening", bubbleStateValue(CompanionPose.Idle, 0, false, 0, TalkState.Listening()))
        assertEquals("Transcribing", bubbleStateValue(CompanionPose.Idle, 0, false, 0, TalkState.Finishing("")))
        assertEquals("Live voice", bubbleStateValue(CompanionPose.Idle, 0, false, 0, live = true))
    }

    @Test fun idleStatusSlotCreatesNoGhostNode() {
        compose.setContent {
            androidx.compose.foundation.layout.Row { StateMark(ChatState.Idle); Text("Chat") }
        }
        compose.onNodeWithText("Chat").assertExists()
        compose.onNodeWithContentDescription("Idle").assertDoesNotExist()
        assertEquals(1, compose.onRoot().fetchSemanticsNode().children.size)
    }

    @Test fun noHeaderButtonWithoutTheShellsState() {
        compose.setContent { VerdeTheme { VerdeTopBar(title = { Text("Chat") }) } }
        compose.onNodeWithTag(COMPANION_HEADER).assertDoesNotExist()
    }
}

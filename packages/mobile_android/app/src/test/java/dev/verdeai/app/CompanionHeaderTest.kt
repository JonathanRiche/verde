package dev.verdeai.app

import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
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

    private fun state(count: Int, onToggle: () -> Unit) = CompanionDockState("Sprout", CompanionCharacter.Sprout, CompanionPose.Idle, count,
        running = false, chip = BubbleChip(null) {}, talk = null, live = null, opened = false, onToggle = onToggle)

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

    @Test fun noHeaderButtonWithoutTheShellsState() {
        compose.setContent { VerdeTheme { VerdeTopBar(title = { Text("Chat") }) } }
        compose.onNodeWithTag(COMPANION_HEADER).assertDoesNotExist()
    }
}

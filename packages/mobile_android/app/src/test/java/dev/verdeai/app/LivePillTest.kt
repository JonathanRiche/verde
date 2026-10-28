package dev.verdeai.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LivePillTest {
    @get:Rule val compose = createComposeRule()

    @Test fun pillButtonsRouteAndCaptionsToggle() {
        var ui by mutableStateOf(LiveUi(phase = LivePhase.Live, captions = listOf(LiveCaption(true, "run the tests"), LiveCaption(false, "On it."))))
        var captions by mutableStateOf(true)
        val taps = mutableListOf<String>()
        compose.setContent {
            VerdeTheme {
                LivePill(ui, input = .3f, output = 0f, character = CompanionCharacter.Moss, name = "Moss", captionsShown = captions,
                    onExpand = { taps += "expand" }, onSettings = { taps += "settings" },
                    onCaptions = { captions = !captions; taps += "captions" },
                    onMute = { ui = ui.copy(muted = !ui.muted); taps += "mute" }, onEnd = { taps += "end" })
            }
        }
        compose.onNodeWithTag(LIVE_PILL).assertExists()
        compose.onNodeWithText("You: run the tests").assertExists()
        compose.onNodeWithText("Moss: On it.").assertExists()

        compose.onNodeWithContentDescription("Mute microphone").performClick()
        compose.onNodeWithContentDescription("Unmute microphone").assertExists()
        compose.onNodeWithContentDescription("Hide captions").performClick()
        compose.onNodeWithTag(LIVE_PILL_CAPTIONS).assertDoesNotExist()
        compose.onNodeWithContentDescription("Voice settings").performClick()
        compose.onNodeWithContentDescription("End live voice").performClick()
        compose.onNodeWithContentDescription("Listening", substring = false, useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithContentDescription("Muted", useUnmergedTree = true).performClick()
        assertEquals(listOf("mute", "captions", "settings", "end", "expand"), taps)
    }

    @Test fun statusLabelsFollowPhase() {
        assertEquals("Connecting…", liveStatusLabel(LiveUi(phase = LivePhase.Connecting), false, "Moss"))
        assertEquals("Moss is speaking", liveStatusLabel(LiveUi(phase = LivePhase.Live), true, "Moss"))
        assertEquals("Muted", liveStatusLabel(LiveUi(phase = LivePhase.Live, muted = true), false, "Moss"))
        assertTrue(liveStatusLabel(LiveUi(phase = LivePhase.Live), false, "Moss") == "Listening")
    }
}

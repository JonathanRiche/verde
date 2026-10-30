package dev.verdeai.app

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Dp
import androidx.core.graphics.Insets
import androidx.core.view.WindowInsetsCompat
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

    @Test fun callBarShowsThePillOrAFailedCallsReason() {
        var ui by mutableStateOf(LiveUi(phase = LivePhase.Live, captions = listOf(LiveCaption(false, "On it."))))
        val taps = mutableListOf<String>()
        compose.setContent {
            VerdeTheme {
                LiveCallBar(ui, input = { 0f }, output = { 0f }, character = CompanionCharacter.Moss, name = "Moss", captionsShown = true,
                    onExpand = { taps += "expand" }, onSettings = { taps += "settings" }, onCaptions = { taps += "captions" },
                    onMute = { taps += "mute" }, onEnd = { taps += "end" }, onRetry = { taps += "retry" }, onClose = { taps += "close" })
            }
        }
        compose.onNodeWithTag(LIVE_CALL_BAR).assertExists()
        compose.onNodeWithTag(LIVE_PILL).assertExists()
        compose.onNodeWithText("Moss: On it.").assertExists()
        // The docked captions card keeps two rows whatever was said, so the screens under the bar hold still.
        val oneLine = compose.onNodeWithTag(LIVE_CALL_BAR).fetchSemanticsNode().size.height
        ui = ui.copy(captions = listOf(LiveCaption(true, "hello"), LiveCaption(false, "Hi there.")))
        compose.onNodeWithText("You: hello").assertExists()
        assertEquals(oneLine, compose.onNodeWithTag(LIVE_CALL_BAR).fetchSemanticsNode().size.height)
        compose.onNodeWithContentDescription("End live voice").performClick()

        ui = LiveUi(phase = LivePhase.Failed, error = "The voice provider is unavailable.")
        compose.onNodeWithTag(LIVE_PILL).assertDoesNotExist()
        compose.onNodeWithText("The voice provider is unavailable.").assertExists()
        compose.onNodeWithText("Try again").performClick()
        compose.onNodeWithText("Close").performClick()
        assertEquals(listOf("end", "retry", "close"), taps)
    }

    private fun barHost(taps: MutableList<String>) = LiveBarHost(mutableStateOf<@Composable (Dp) -> Unit>({ top ->
        LiveCallBar(LiveUi(phase = LivePhase.Live), { 0f }, { 0f }, CompanionCharacter.Moss, "Moss", captionsShown = false,
            onExpand = {}, onSettings = {}, onCaptions = {}, onMute = {}, onEnd = { taps += "end" },
            onRetry = {}, onClose = {}, statusBarHeight = top)
    }))

    @Test fun callBarSitsInADialogsWindowButNotOverTheLock() {
        var locked by mutableStateOf(false)
        val taps = mutableListOf<String>()
        val host = barHost(taps)
        compose.setContent {
            VerdeTheme {
                CompositionLocalProvider(LocalLiveBar provides host, LocalAppLocked provides locked) {
                    AlertDialog(onDismissRequest = {}, title = { LiveOverModal(); Text("Close workspace?") },
                        confirmButton = { TextButton(onClick = { taps += "confirm" }) { Text("Close") } })
                }
            }
        }
        compose.onNodeWithText("Close workspace?").assertExists()
        compose.onNodeWithTag(LIVE_CALL_BAR).assertExists()
        // The bar in the dialog works, and so does the dialog, laid out below it.
        compose.onNodeWithContentDescription("End live voice").performClick()
        compose.onNodeWithText("Close").performClick()
        assertEquals(listOf("end", "confirm"), taps)
        locked = true
        compose.onNodeWithTag(LIVE_CALL_BAR).assertDoesNotExist()
    }

    @Test fun menusGetTheBarOnlyWhenTheyReachIt() {
        val host = barHost(mutableListOf())
        compose.setContent {
            VerdeTheme {
                CompositionLocalProvider(LocalLiveBar provides host) {
                    DropdownMenu(expanded = true, onDismissRequest = {}) {
                        LiveOverMenu()
                        DropdownMenuItem(text = { Text("Rename") }, onClick = {})
                    }
                }
            }
        }
        compose.onNodeWithText("Rename").assertExists()
        compose.onNodeWithTag(LIVE_CALL_BAR).assertDoesNotExist()
        // A bar reaching far down the screen: the menu overlaps it, so a copy floats over the menu.
        host.bottom = 100_000
        compose.onNodeWithTag(LIVE_CALL_BAR).assertExists()
    }

    @Test fun barInsetsDropOnlyTheTop() {
        val insets = WindowInsetsCompat.Builder()
            .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, 60, 0, 0))
            .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, 40))
            .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, 300)).build()
        val out = withoutTopInsets(insets)
        assertEquals(0, out.getInsets(WindowInsetsCompat.Type.statusBars()).top)
        assertEquals(0, out.getInsets(WindowInsetsCompat.Type.systemBars()).top)
        assertEquals(40, out.getInsets(WindowInsetsCompat.Type.systemBars()).bottom)
        assertEquals(300, out.getInsets(WindowInsetsCompat.Type.ime()).bottom)
    }

    @Test fun statusLabelsFollowPhase() {
        assertEquals("Connecting…", liveStatusLabel(LiveUi(phase = LivePhase.Connecting), false, "Moss"))
        assertEquals("Moss is speaking", liveStatusLabel(LiveUi(phase = LivePhase.Live), true, "Moss"))
        assertEquals("Muted", liveStatusLabel(LiveUi(phase = LivePhase.Live, muted = true), false, "Moss"))
        assertTrue(liveStatusLabel(LiveUi(phase = LivePhase.Live), false, "Moss") == "Listening")
    }
}

package dev.verdeai.app

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.verdeai.core.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35])
class ThreadActionsTest {
    @get:Rule val compose = createComposeRule()
    private val thread = ThreadSummary("ws", "t1", "Menu chat", "codex", null, null, true, false, null, "idle", "Today")
    private val actions = mutableListOf<String>()
    private var opens = 0
    private fun launch(edit: Boolean = true) {
        compose.setContent { VerdeTheme {
            DrawerChat(thread, false, edit, { target, action ->
                assertEquals(thread.thread_id, target.thread_id)
                actions.add(action)
            }, { opens++ })
        } }
    }
    @Test fun longPressOffersThreadActionsWithoutOpeningChat() {
        launch()
        compose.onNodeWithText("Menu chat").performTouchInput { longClick() }
        compose.onNodeWithText("Rename chat").performClick()
        assertEquals(listOf("rename"), actions)
        assertEquals(0, opens)
    }
    @Test fun secondaryMouseClickOpensMenuAndCloseDispatchesOnce() {
        launch()
        compose.onNodeWithText("Menu chat").performMouseInput { click(button = MouseButton.Secondary) }
        compose.onNodeWithText("Close chat").performClick()
        assertEquals(listOf("close"), actions)
        assertEquals(0, opens)
    }
    @Test fun readOnlyDeviceCanOpenButCannotMutate() {
        launch(edit=false)
        compose.onNodeWithText("Menu chat").performTouchInput { longClick() }
        compose.onNodeWithText("Rename chat").assertIsNotEnabled()
        compose.onNodeWithText("Sync thread").assertIsNotEnabled()
        compose.onNodeWithText("Close chat").assertIsNotEnabled()
        compose.onNodeWithText("Open chat").performClick()
        assertEquals(1, opens)
        assertTrue(actions.isEmpty())
    }
}

package dev.verdeai.app

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** S49: Tab inside an expanded tool group goes through its children top to bottom, then leaves it. */
@RunWith(RobolectricTestRunner::class)
class GroupTabTest {
    @get:Rule val compose = createComposeRule()

    @Test fun tabWalksTheGroupInReadingOrderThenLeaves() {
        val holder = GroupTabHolder()
        compose.setContent {
            CompositionLocalProvider(LocalGroupTab provides holder) {
                Column {
                    Box(Modifier.size(48.dp).testTag("above").focusable())
                    Column(rememberGroupTab(expanded = true)) {
                        listOf("a", "b", "c").forEach { Box(Modifier.size(48.dp).testTag(it).focusable()) }
                    }
                    Box(Modifier.size(48.dp).testTag("below").focusable())
                }
            }
        }
        compose.onNodeWithTag("a").requestFocus()
        compose.waitForIdle()
        fun tab(back: Boolean = false) {
            compose.runOnIdle { assertNotNull("the group owns Tab while focused", holder.owner); holder.owner!!.tab(back) }
            compose.waitForIdle()
        }
        tab(); compose.onNodeWithTag("b").assertIsFocused()
        tab(); compose.onNodeWithTag("c").assertIsFocused()
        tab(back = true); compose.onNodeWithTag("b").assertIsFocused()
        tab(); tab(); compose.onNodeWithTag("below").assertIsFocused()

        compose.onNodeWithTag("a").requestFocus()
        compose.waitForIdle()
        tab(back = true); compose.onNodeWithTag("above").assertIsFocused()
    }
}

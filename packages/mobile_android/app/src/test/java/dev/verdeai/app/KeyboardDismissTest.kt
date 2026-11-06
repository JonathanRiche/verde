package dev.verdeai.app

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** A-KB: taps that no control takes, and user scrolls, put the keyboard away. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h900dp")
class KeyboardDismissTest {
    @get:Rule val compose = createComposeRule()

    @Test fun plainTapsAndScrollsDismissButControlsKeepTheirTaps() {
        var dismissed = 0
        var clicked = 0
        compose.setContent {
            Column(Modifier.fillMaxSize().dismissKeyboardOnTouch { dismissed++ }) {
                Button(onClick = { clicked++ }) { Text("Control") }
                LazyColumn(Modifier.height(300.dp).testTag("list")) {
                    items(60) { Text("Line $it", Modifier.height(40.dp)) }
                }
            }
        }
        compose.onNodeWithText("Control").performClick()
        assertEquals(1, clicked)
        assertEquals(0, dismissed)
        compose.onNodeWithText("Line 1").performClick()
        assertEquals(1, dismissed)
        compose.onNodeWithTag("list").performTouchInput { swipeUp() }
        compose.waitForIdle()
        assertTrue(dismissed > 1)
    }
}

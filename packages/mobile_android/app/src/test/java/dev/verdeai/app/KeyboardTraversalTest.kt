package dev.verdeai.app

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalTestApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class KeyboardTraversalTest {
    @get:Rule val compose = createComposeRule()
    private fun tab(back: Boolean = false) {
        compose.onRoot().performKeyInput {
            if (back) keyDown(Key.ShiftLeft)
            pressKey(Key.Tab)
            if (back) keyUp(Key.ShiftLeft)
        }
        compose.waitForIdle()
    }

    @Test fun headerAndLazyRowsShareOneForwardAndReverseCycle() {
        val header = FocusRequester(); val body = FocusRequester()
        compose.setContent {
            Column {
                Row(Modifier.focusRequester(header).keyboardRegion(body)) {
                    Button(onClick = {}, modifier = Modifier.testTag("drawer")) { Text("Drawer") }
                    Button(onClick = {}, modifier = Modifier.testTag("host")) { Text("Host") }
                }
                Box(Modifier.focusRequester(body).keyboardRegion(header)) {
                    LazyColumn(Modifier.height(300.dp).focusProperties { canFocus = false }) {
                        items(3) { i -> Button(onClick = {}, modifier = Modifier.testTag("row$i")) { Text("Chat $i") } }
                    }
                }
            }
        }
        compose.runOnIdle { header.requestFocus() }
        compose.onNodeWithTag("drawer").assertIsFocused()
        listOf("host", "row0", "row1", "row2", "drawer").forEach { tag -> tab(); compose.onNodeWithTag(tag).assertIsFocused() }
        listOf("row2", "row1", "row0", "host", "drawer").forEach { tag -> tab(true); compose.onNodeWithTag(tag).assertIsFocused() }
    }

    @Test fun bubbleJoinsTheCycleAndReverseReturnsToTheLastRow() {
        val header = FocusRequester(); val body = FocusRequester(); val bubble = FocusRequester()
        compose.setContent {
            androidx.compose.material3.Scaffold(topBar = {
                Row(Modifier.focusRequester(header).keyboardRegion(body, bubble)) {
                    Button({}, Modifier.testTag("drawer")) { Text("Drawer") }
                    Button({}, Modifier.testTag("host")) { Text("Host") }
                }
            }) { padding ->
                Column(Modifier.padding(padding).focusRequester(body).keyboardRegion(header)) {
                    Column {
                        repeat(2) { i -> Button({}, Modifier.testTag("row$i")) { Text("Chat $i") } }
                    }
                    Text("Bubble", Modifier.focusRequester(bubble).keyboardBridge(header).focusable().testTag("bubble"))
                }
            }
        }
        compose.runOnIdle { header.requestFocus() }
        listOf("host", "row0", "row1", "bubble", "drawer").forEach { tag -> tab(); compose.onNodeWithTag(tag).assertIsFocused() }
        listOf("bubble", "row1", "row0", "host", "drawer").forEach { tag -> tab(true); compose.onNodeWithTag(tag).assertIsFocused() }
    }

    @Test fun composerTabLeavesForHeaderAndReverseReturnsToLastControl() {
        val header = FocusRequester(); val composer = FocusRequester(); val field = FocusRequester(); val actions = FocusRequester()
        compose.setContent {
            Column {
                Row(Modifier.focusRequester(header).keyboardRegion(field)) {
                    Button(onClick = {}, modifier = Modifier.testTag("back")) { Text("Back") }
                    Button(onClick = {}, modifier = Modifier.focusRequester(actions).testTag("actions")) { Text("Actions") }
                }
                Column(Modifier.focusRequester(composer).keyboardRegion(header, actions)) {
                    BasicTextField("", {}, Modifier.focusRequester(field).tabMovesFocus().testTag("field"))
                    Button(onClick = {}, modifier = Modifier.testTag("access")) { Text("Access") }
                }
            }
        }
        compose.runOnIdle { field.requestFocus() }
        tab(); compose.onNodeWithTag("access").assertIsFocused()
        tab(); compose.onNodeWithTag("back").assertIsFocused()
        tab(true); compose.onNodeWithTag("access").assertIsFocused()
        tab(true); compose.onNodeWithTag("field").assertIsFocused()
        tab(true); compose.onNodeWithTag("actions").assertIsFocused()
    }
}

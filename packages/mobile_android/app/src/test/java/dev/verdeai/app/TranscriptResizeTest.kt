package dev.verdeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** A6-1 / S20: a viewport resize while scrolled up never scrolls from inside layout, and keeps the top row. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h900dp")
class TranscriptResizeTest {
    @get:Rule val compose = createComposeRule()

    @Test fun resizingWhileScrolledUpKeepsTheTopRowAndDoesNotCrash() {
        val list = LazyListState()
        var strip by mutableStateOf(0.dp)
        compose.setContent {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    LazyColumn(Modifier.fillMaxSize().keepTopRowOnResize(list) { list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < 48 },
                        state = list, reverseLayout = true) {
                        items((0 until 200).toList(), key = { it }) { Text("Row $it", Modifier.height(40.dp)) }
                    }
                }
                Box(Modifier.height(strip))
            }
        }
        runBlocking { compose.awaitIdle() }
        compose.runOnIdle { runBlocking { list.scrollToItem(30, 0) } }
        compose.waitForIdle()
        val topBefore = compose.runOnIdle { list.layoutInfo.visibleItemsInfo.last().index }
        // Several height changes in a row: the Latest strip, an attachment strip, the keyboard.
        for (h in listOf(48.dp, 120.dp, 300.dp, 0.dp)) {
            strip = h
            compose.waitForIdle()
        }
        val topAfter = compose.runOnIdle { list.layoutInfo.visibleItemsInfo.last().index }
        assertTrue("top row moved from $topBefore to $topAfter", kotlin.math.abs(topAfter - topBefore) <= 1)
        // At the bottom the list stays at the bottom.
        compose.runOnIdle { runBlocking { list.scrollToItem(0, 0) } }
        strip = 200.dp
        compose.waitForIdle()
        assertEquals(0, compose.runOnIdle { list.firstVisibleItemIndex })
    }
}

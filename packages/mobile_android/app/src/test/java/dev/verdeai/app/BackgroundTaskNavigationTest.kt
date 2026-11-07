package dev.verdeai.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatBackgroundTask
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class BackgroundTaskNavigationTest {
    @get:Rule val compose = createComposeRule()
    @Test fun barSummarizesAndBringsAnOffscreenTaskAboveTheLatestStrip() {
        compose.setContent {
            VerdeTheme {
                val list = rememberLazyListState()
                val scope = rememberCoroutineScope()
                var latest by remember { mutableStateOf(false) }
                Column(Modifier.height(500.dp)) {
                    LazyColumn(Modifier.weight(1f).testTag("viewport"), state = list, reverseLayout = true) {
                        items(60) { i -> Text("Task row $i", Modifier.height(80.dp)) }
                    }
                    if (latest) Text("Latest", Modifier.height(48.dp).testTag("latest"))
                    RunningTasksBar(listOf(ChatBackgroundTask("task", label = "bun run build --watch", status = "running"))) {
                        assertEquals("task", it)
                        latest = true
                        scope.launch { list.showBackgroundTask(30, 12) }
                    }
                }
            }
        }
        compose.onNodeWithText("bun run build --watch").assertDoesNotExist()
        compose.onNodeWithContentDescription("1 background task running").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Task row 30").assertIsDisplayed()
        val row = compose.onNodeWithText("Task row 30").getUnclippedBoundsInRoot()
        val viewport = compose.onNodeWithTag("viewport").getUnclippedBoundsInRoot()
        val latest = compose.onNodeWithTag("latest").getUnclippedBoundsInRoot()
        assertTrue("row starts above the viewport: $row / $viewport", row.top >= viewport.top)
        assertTrue("row overlaps Latest: $row / $latest", row.bottom < latest.top)
    }
}

package dev.verdeai.app

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import dev.verdeai.core.MarkdownNode
import dev.verdeai.core.RenderSpan
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MarkdownStreamingTest {
    @get:Rule val compose = createComposeRule()

    @Test fun streamingFinishesInFlightParseThenRendersLatestBody() {
        val release = CompletableDeferred<Unit>()
        val requested = mutableListOf<String>()
        val completed = mutableListOf<String>()
        val text = mutableStateOf("first")
        val source = object : MarkdownSource {
            override fun cachedMarkdown(text: String): RenderResult<List<MarkdownNode>>? = null
            override suspend fun markdown(text: String): RenderResult<List<MarkdownNode>> {
                requested.add(text)
                if (text == "first") release.await()
                completed.add(text)
                return RenderResult(listOf(MarkdownNode("paragraph", 0uL, text.length.toULong(), children =
                    listOf(MarkdownNode("text", 0uL, text.length.toULong(), text = text)))))
            }
            override fun cachedHighlight(code: String, language: String): RenderResult<List<RenderSpan>>? = null
            override suspend fun highlight(code: String, language: String): RenderResult<List<RenderSpan>> = error("Unexpected code block")
        }
        compose.setContent { VerdeTheme { MarkdownText(text.value, source, {}) } }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(listOf("first"), requested); text.value = "intermediate" }
        compose.waitForIdle()
        compose.runOnIdle { text.value = "latest complete response" }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(listOf("first"), requested); release.complete(Unit) }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(listOf("first", "latest complete response"), requested)
            assertEquals(requested, completed)
        }
        compose.onNodeWithText("latest complete response").assertIsDisplayed()
    }
}

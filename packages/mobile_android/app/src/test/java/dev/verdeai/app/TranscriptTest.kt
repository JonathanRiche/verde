package dev.verdeai.app

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import dev.verdeai.core.RenderSpan
import org.junit.Assert.*
import org.junit.Test

/** Pure transcript rules: core selector encoding, UTF-8 span offsets, and link admission. */
class TranscriptTest {
    @Test fun selectorsMatchTheCorePercentEncoding() {
        assertEquals("thread:%5B%22chat-fixture-ws%22%2C%22chat-fixture-thread%22%5D",
            chatSelector("thread", "chat-fixture-ws", "chat-fixture-thread"))
        assertEquals("composer:%5B%22a%20b%22%2C%22%C3%A9%22%5D", chatSelector("composer", "a b", "é"))
    }

    @Test fun coreUtf8SpansMapToUtf16Indices() {
        // UTF-8 byte offsets → UTF-16 indices across 1-, 2-, 3- and 4-byte characters.
        assertArrayEquals(intArrayOf(0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 5), utf8ToUtf16("aé世😀"))
        val spans = listOf(RenderSpan(3uL, 6uL, "keyword"), RenderSpan(6uL, 99uL, "string"))
        val text = highlighted("aé世😀", spans) { SpanStyle(color = Color.Red) }
        assertEquals(listOf(2 to 3, 3 to 5), text.spanStyles.map { it.start to it.end })
    }

    @Test fun linksOnlyAdmitWebAndMailSchemes() {
        assertEquals("https://x.dev", safeLinkUrl("https://x.dev"))
        assertNull(safeLinkUrl("javascript:alert(1)"))
        assertNull(safeLinkUrl("/relative"))
    }
}

package dev.verdeai.app

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import dev.verdeai.core.ChatRow
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

    @Test fun savedVoiceRowsGroupBySpeakerAndMergeFragments() {
        fun row(id: Int, role: String, author: String, body: String) = ChatRow(id = id.toString(), role = role, author = author, body = body)
        val you = "You (voice)"
        val moss = "Moss (voice)"
        val user = listOf("The companion", "to run a longer", "test.", "with the", "Muse wonderful", "model.", "It finished the basic test.",
            "The companion to run a longer test with the Muse wonderful model. And finish the basic test. I want one",
            "thread", "where you test", "multiple", "prompts, summary.", "prompt, summary, prompt.")
        val rows = buildList {
            add(row(83, "system", "Live", "🎙 Live voice · xAI Grok · 14:31"))
            user.forEachIndexed { i, body -> add(row(84 + i, "user", you, body)) }
            add(row(97, "assistant", moss, "On it — kicking off that multi-prompt test thread now."))
            add(row(98, "system", "Live", "→ Asked Moss: Run a longer test with the Muse wonderful model."))
            add(row(99, "assistant", moss, "The companion accepted it. I'll flag you when the first results come in."))
            add(row(100, "system", "Live", "← Moss replied"))
            add(row(101, "assistant", moss, "Good news: the basic test passed, and the long run is live."))
        }
        val items = groupVoice(rows.map { if (it.role == "system") TranscriptItem.Notice(it) else TranscriptItem.Message(it) })
        assertEquals(listOf("Notice", "Voice", "Voice", "Notice", "Voice", "Notice", "Voice"), items.map { it::class.simpleName })
        val you1 = items[1] as TranscriptItem.Voice
        assertTrue(you1.user)
        assertEquals("You", you1.speaker)
        assertEquals(13, you1.rows.size)
        assertEquals("The companion to run a longer test with the Muse wonderful model. And finish the basic test. " +
            "I want one thread where you test multiple prompts, summary. prompt, summary, prompt.", you1.body)
        val moss1 = items[2] as TranscriptItem.Voice
        assertFalse(moss1.user)
        assertEquals("Moss", moss1.speaker)
        assertEquals("On it — kicking off that multi-prompt test thread now.", moss1.body)
        // Consecutive companion lines join as paragraphs; ordinary messages are untouched.
        val pair = groupVoice(listOf(TranscriptItem.Message(row(1, "assistant", moss, "One.")), TranscriptItem.Message(row(2, "assistant", moss, "Two.")),
            TranscriptItem.Message(row(3, "user", "", "typed"))))
        assertEquals("One.\n\nTwo.", (pair[0] as TranscriptItem.Voice).body)
        assertTrue(pair[1] is TranscriptItem.Message)
    }
}

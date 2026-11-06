package dev.verdeai.app

import dev.verdeai.core.ChatChoice
import dev.verdeai.core.ChatMention
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** S5: chips name their resolved value; `/` and `@` lists are deduplicated. */
class ComposerLabelsTest {
    private val access = listOf(ChatChoice("supervised", "Supervised"), ChatChoice("full_access", "Full access"))

    @Test fun accessChipShowsTheResolvedMode() {
        assertEquals("Supervised", accessValueLabel(access, "supervised"))
        assertEquals("Full access", accessValueLabel(access, "full_access"))
        assertEquals("Default · Supervised", accessValueLabel(access, null))
        assertEquals("Default · Supervised", accessValueLabel(access, ""))
        assertEquals("Default", accessValueLabel(emptyList(), null))
        assertTrue(accessIsFull(access, "full_access"))
        assertFalse(accessIsFull(access, null))
    }

    @Test fun slashCommandsAreDeduplicatedAndFiltered() {
        val catalog = List(5) { ChatChoice("code-review", "/code-review") } +
            listOf(ChatChoice("compact", "compact"), ChatChoice("off", "/clear", enabled = false))
        assertEquals(listOf("/code-review", "/compact"), slashSuggestions(catalog, ""))
        assertEquals(listOf("/compact"), slashSuggestions(catalog, "COM"))
    }

    @Test fun mentionsShowFileNameThenFolder() {
        val mentions = listOf(ChatMention("src/reconnect.ts", "reconnect.ts"), ChatMention("src/reconnect.ts", "reconnect.ts"),
            ChatMention("README.md", "README.md"))
        assertEquals(listOf("reconnect.ts" to "src", "README.md" to null), mentionSuggestions(mentions))
    }
}

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

    @Test fun defaultModelAndEffortNameWhatTheyResolveTo() {
        val models = listOf(ChatChoice("default", "Default"), ChatChoice("sonnet", "Sonnet 5.5"))
        val efforts = listOf(ChatChoice("", "Default"), ChatChoice("high", "High"))
        val known = dev.verdeai.core.ChatCatalogs(models = models, efforts = efforts, default_model_label = "Opus 5.5", default_effort_label = "High")
        val unknown = dev.verdeai.core.ChatCatalogs(models = models, efforts = efforts)
        val none = dev.verdeai.core.ChatSelection()
        assertEquals("Default \u00b7 Opus 5.5", modelValueLabel(known, none))
        assertEquals("Default", modelValueLabel(unknown, none))
        assertEquals("Sonnet 5.5", modelValueLabel(known, dev.verdeai.core.ChatSelection(model = "sonnet")))
        assertEquals("Default \u00b7 High", effortValueLabel(known, none))
        assertEquals("Default", effortValueLabel(unknown, none))
        assertEquals("High", effortValueLabel(known, dev.verdeai.core.ChatSelection(effort = "high")))
        assertEquals("Default \u00b7 Opus 5.5 \u00b7 Default \u00b7 High", compactSettingsLabel(known, none))
    }
}

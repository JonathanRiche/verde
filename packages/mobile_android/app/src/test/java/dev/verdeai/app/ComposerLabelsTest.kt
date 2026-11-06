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
        // Unset access runs as full access on the host (the core sends none; thread_create defaults to full_access).
        assertEquals("Default · Full access", accessValueLabel(access, null))
        assertEquals("Default · Full access", accessValueLabel(access, ""))
        assertEquals("full_access", effectiveAccess(null))
        assertEquals("supervised", effectiveAccess("supervised"))
        assertEquals("Default", accessValueLabel(emptyList(), null))
        assertTrue(accessIsFull(access, "full_access"))
        assertTrue(accessIsFull(access, null))
        assertFalse(accessIsFull(access, "supervised"))
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
        assertEquals("Opus 5.5", modelValueLabel(known, none))
        assertEquals("Default", modelValueLabel(unknown, none))
        assertEquals("Sonnet 5.5", modelValueLabel(known, dev.verdeai.core.ChatSelection(model = "sonnet")))
        assertEquals("High", effortValueLabel(known, none))
        assertEquals("Auto", effortValueLabel(unknown, none))
        assertEquals("High", effortValueLabel(known, dev.verdeai.core.ChatSelection(effort = "high")))
        assertEquals("Opus 5.5", compactSettingsLabel(known, none))
        assertEquals("Codex \u00b7 Opus 5.5", compactSettingsLabel(known, none, "codex"))
        assertEquals("Full access", accessChipLabel(access, null))
        assertEquals("Supervised", accessChipLabel(access, "supervised"))
    }

    @Test fun chipsShareOneAbbreviationTable() {
        assertEquals("Med", chipShort(ComposerPicker.Effort, "Medium"))
        assertEquals("Auto", chipShort(ComposerPicker.Effort, "Auto"))
        assertEquals("High", chipShort(ComposerPicker.Effort, "High"))
        assertEquals("Fast", chipShort(ComposerPicker.Speed, "on"))
        assertEquals("Std", chipShort(ComposerPicker.Speed, "off"))
        assertEquals("Ask", chipShort(ComposerPicker.Access, "Supervised"))
        assertEquals("Full", chipShort(ComposerPicker.Access, "Full access"))
        assertEquals("GPT-6.1 Sol", chipShort(ComposerPicker.Model, "GPT-6.1 Sol"))
        // S35: one wording on both platforms: "<value> (default)", never a bare "Default".
        assertEquals("Auto (default)", pickerRowLabel(ComposerPicker.Effort, ChatChoice("", "Default")))
        // S45: one default model row, "Opus 5.5 (default)"; the explicit "Opus 5.5" row is left out.
        val cat = dev.verdeai.core.ChatCatalogs(models = listOf(ChatChoice("", "Default"), ChatChoice("opus", "Opus 5.5"), ChatChoice("fable", "Fable 5.1")),
            default_model_label = "Opus 5.5")
        assertEquals("Opus 5.5 (default)", pickerRowLabel(ComposerPicker.Model, ChatChoice("", "Default"), cat))
        assertEquals(listOf("", "fable"), modelChoices(cat).map { it.id })
        assertEquals("", modelCurrent(cat, "opus"))
        assertEquals("fable", modelCurrent(cat, "fable"))
        assertEquals("Default", pickerRowLabel(ComposerPicker.Model, ChatChoice("", "Default"), dev.verdeai.core.ChatCatalogs()))
        assertEquals("Standard (default)", pickerRowLabel(ComposerPicker.Speed, ChatChoice("off", "Normal")))
        assertEquals("Fast", pickerRowLabel(ComposerPicker.Speed, ChatChoice("on", "Fast")))
        assertEquals("Full access (default)", pickerRowLabel(ComposerPicker.Access, ChatChoice("full_access", "Full access")))
        assertEquals("Supervised", pickerRowLabel(ComposerPicker.Access, ChatChoice("supervised", "Supervised")))
        assertEquals("Standard", speedLabel(null))
    }

    /** The host takes 16 attachments per turn (MAX_ATTACHMENTS_PER_TURN); 16 bounded images stay far under its 256 MB. */
    @Test fun sixteenImagesPerMessage() {
        assertEquals(16, ComposerModel.MAX_IMAGES)
        assertTrue(ComposerModel.MAX_IMAGES.toLong() * ComposerModel.MAX_IMAGE_BYTES < 256L * 1024 * 1024)
    }

    /** S44: drafts read "Photo 3 of 16" (Remove "Photo 3 of 16"); a lone image keeps its name; the strip counts them. */
    @Test fun draftImagesHaveDistinctNames() {
        assertEquals(listOf("Photo 1 of 3", "Photo 2 of 3", "Photo 3 of 3"), draftImageNames(listOf("1000001.jpg", "1000002.jpg", "diagram.png")))
        assertEquals("Photo 16 of 16", draftImageNames(List(16) { "photo.jpg" }).last())
        assertEquals(listOf("diagram.png"), draftImageNames(listOf("diagram.png")))
        assertEquals("16 photos", draftImageCount(16))
    }

    /** S45: the model chip keeps both ends with no space beside the ellipsis ("GPT…Sol"). */
    @Test fun modelNameMiddleTruncatesWithoutSpaces() {
        val width = { t: String -> t.length.toFloat() }
        assertEquals("GPT-6.1 Sol", middleFit("GPT-6.1 Sol", 20f, width))
        assertEquals("GPT…Sol", middleFit("GPT-6.1 Sol", 7f, width))
    }
}

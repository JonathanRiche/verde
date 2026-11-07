package dev.verdeai.app

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.verdeai.core.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NewChatPickerTest {
    @get:Rule val compose = createComposeRule()
    @Test fun effectiveDefaultIsMarkedAndSelectionFollowsAnExplicitChoice() {
        val catalogs = ChatCatalogs(models = listOf(ChatChoice("default", "Default"), ChatChoice("opus", "Opus 5.5"),
            ChatChoice("sonnet", "Sonnet 5.5")), default_model_label = "Opus 5.5")
        compose.setContent {
            var selected by remember { mutableStateOf<String?>(null) }
            VerdeTheme {
                Picker("Model", modelValueLabel(catalogs, ChatSelection(model = selected)), newChatModelChoices(catalogs, selected), true,
                    selectedId = modelCurrent(catalogs, selected)) { selected = it }
            }
        }
        compose.onNodeWithContentDescription("Model: Opus 5.5. Change").performClick()
        compose.onNodeWithText("Opus 5.5 (default)").assertIsSelected()
        compose.onNodeWithText("Opus 5.5", substring = false).assertDoesNotExist()
        compose.onNodeWithText("Sonnet 5.5").performClick()
        compose.onNodeWithContentDescription("Model: Sonnet 5.5. Change").performClick()
        compose.onNodeWithText("Sonnet 5.5").assertIsSelected()
        compose.onNodeWithText("Opus 5.5 (default)").assertIsNotSelected()
    }
    @Test fun explicitCatalogWithoutADefaultSentinelStillMarksTheKnownDefault() {
        val catalogs = ChatCatalogs(models = listOf(ChatChoice("sol", "Sol"), ChatChoice("astra", "Astra")), default_model_label = "Sol")
        assertEquals(listOf("Sol (default)", "Astra"), newChatModelChoices(catalogs, "astra").map { it.label })
        assertEquals("sol", modelCurrent(catalogs, null))
        val laterDefault = catalogs.copy(default_model_label = "Astra")
        assertEquals("astra", modelCurrent(laterDefault, null))
        assertEquals(listOf("Sol", "Astra (default)"), newChatModelChoices(laterDefault, null).map { it.label })
    }
}

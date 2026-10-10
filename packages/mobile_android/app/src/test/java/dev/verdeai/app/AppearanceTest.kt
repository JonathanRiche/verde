package dev.verdeai.app

import android.content.Context
import android.content.res.Configuration
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class AppearanceTest {
    @get:Rule val compose = createComposeRule()
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Before fun resetPreferences() {
        context.getSharedPreferences("appearance", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test fun systemIsDefaultAndExplicitChoicesSurviveRecreation() {
        val settings = AppearanceSettings(context)
        assertEquals(AppearanceMode.SYSTEM, settings.mode)
        for (mode in AppearanceMode.entries) {
            settings.select(mode)
            assertEquals(mode, AppearanceSettings(context).mode)
        }
    }

    private fun selectTheme(label: String) {
        compose.onNodeWithTag("appearance-theme-picker").performClick()
        compose.onNodeWithTag("appearance-theme-list").performScrollToNode(hasText(label))
        compose.onNodeWithText(label, substring = false).performClick()
    }

    @Test fun bundledPalettesMatchTheWebsiteAndOverrideSystemAppearance() {
        val settings = AppearanceSettings(context)
        val themes = bundledThemes(context)
        assertEquals(AppearanceMode.entries.mapNotNull { it.themeId }.toSet(), themes.keys)
        assertEquals(8, themes.size)
        for (mode in AppearanceMode.entries.filter { it.themeId != null }) {
            assertEquals(mode.label, themes.getValue(mode.themeId!!).name)
            settings.select(mode)
            val palette = settings.palette(false)
            assertEquals(palette, settings.palette(true))
            assertEquals(mode != AppearanceMode.CATPPUCCIN_LATTE, palette.dark)
            assertNotEquals(palette.Background, palette.Text)
        }
        assertEquals("#1a1b26", themes.getValue("tokyo-night").colors["background"])
        assertEquals("#1e66f5", themes.getValue("catppuccin-latte").colors["accent"])
    }

    @Test fun selectionUpdatesCustomAndMaterialColorsAndSystemTracksConfiguration() {
        val settings = AppearanceSettings(context)
        var systemDark by mutableStateOf(false)
        var palette = DarkPalette
        var surface = DarkPalette.Background
        compose.setContent {
            val configuration = Configuration(LocalConfiguration.current).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (systemDark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            CompositionLocalProvider(LocalConfiguration provides configuration, LocalAppearanceSettings provides settings) {
                VerdeTheme {
                    // Pairing wraps itself in a second theme; it must retain the selected setting.
                    VerdeTheme {
                        val current = VerdeColors
                        val colors = MaterialTheme.colorScheme
                        SideEffect { palette = current; surface = colors.surface }
                        AppearanceSettingsSection()
                    }
                }
            }
        }
        compose.runOnIdle { assertEquals(LightPalette, palette); systemDark = true }
        compose.runOnIdle { assertEquals(DarkPalette, palette) }
        selectTheme("Light")
        compose.runOnIdle {
            assertEquals(LightPalette, palette)
            assertEquals(palette.Background, surface)
            assertEquals(AppearanceMode.LIGHT, AppearanceSettings(context).mode)
        }
        selectTheme("Dark")
        compose.runOnIdle { systemDark = false }
        compose.runOnIdle { assertEquals(DarkPalette, palette); assertEquals(palette.Background, surface) }
        selectTheme("Tokyo Night")
        compose.runOnIdle { assertEquals(settings.palette(false), palette); assertEquals(palette.Background, surface) }
        selectTheme("Catppuccin Latte")
        compose.runOnIdle { assertFalse(palette.dark); assertEquals(palette.Background, surface); systemDark = true }
        compose.runOnIdle { assertFalse(palette.dark) }
        selectTheme("Ristretto")
        compose.runOnIdle { assertTrue(palette.dark); assertEquals(settings.palette(false), palette); systemDark = false }
        selectTheme("System")
        compose.runOnIdle { assertEquals(LightPalette, palette) }
    }
}

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
        compose.onNodeWithText("Light", substring = false).performClick()
        compose.runOnIdle {
            assertEquals(LightPalette, palette)
            assertEquals(palette.Background, surface)
            assertEquals(AppearanceMode.LIGHT, AppearanceSettings(context).mode)
        }
        compose.onNodeWithText("Dark", substring = false).performClick()
        compose.runOnIdle { systemDark = false }
        compose.runOnIdle { assertEquals(DarkPalette, palette); assertEquals(palette.Background, surface) }
        compose.onNodeWithText("System", substring = false).performClick()
        compose.runOnIdle { assertEquals(LightPalette, palette) }
    }
}

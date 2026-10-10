package dev.verdeai.app

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

internal enum class AppearanceMode(val label: String, val themeId: String? = null) {
    SYSTEM("System"), LIGHT("Light"), DARK("Dark"),
    TOKYO_NIGHT("Tokyo Night", "tokyo-night"), CATPPUCCIN("Catppuccin", "catppuccin"),
    CATPPUCCIN_LATTE("Catppuccin Latte", "catppuccin-latte"), GRUVBOX("Gruvbox", "gruvbox"),
    KANAGAWA("Kanagawa", "kanagawa"), MATTE_BLACK("Matte Black", "matte-black"),
    OSAKA_JADE("Osaka Jade", "osaka-jade"), RISTRETTO("Ristretto", "ristretto");
}

/** A device-local preference: changing a host must never change the phone's theme. */
internal class AppearanceSettings(context: Context) {
    private val themes = bundledThemes(context).mapValues { it.value.palette() }
    private val preferences = context.applicationContext.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    var mode by mutableStateOf(AppearanceMode.entries.find { it.name == preferences.getString("theme", null) } ?: AppearanceMode.SYSTEM)
        private set

    fun palette(systemDark: Boolean, mode: AppearanceMode = this.mode): VerdePalette = when (mode) {
        AppearanceMode.SYSTEM -> if (systemDark) DarkPalette else LightPalette
        AppearanceMode.LIGHT -> LightPalette
        AppearanceMode.DARK -> DarkPalette
        else -> themes.getValue(requireNotNull(mode.themeId))
    }

    fun select(mode: AppearanceMode) {
        this.mode = mode
        preferences.edit().putString("theme", mode.name).apply()
    }
}

internal val LocalAppearanceSettings = staticCompositionLocalOf<AppearanceSettings?> { null }

@Composable
internal fun AppearanceSystemBars() {
    val activity = LocalContext.current as? ComponentActivity ?: return
    val dark = VerdeColors.dark
    SideEffect {
        activity.enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT) { dark },
            navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT) { dark },
        )
    }
}

@Composable
internal fun AppearanceSettingsSection() {
    val settings = LocalAppearanceSettings.current ?: return
    VerdeSection("Appearance")
    Text("Theme", style = MaterialTheme.typography.titleSmall)
    Text("System follows your phone’s Light or Dark appearance automatically.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    var choosing by remember { mutableStateOf(false) }
    OutlinedButton(onClick = { choosing = true }, modifier = Modifier.fillMaxWidth().testTag("appearance-theme-picker")) {
        Text(settings.mode.label, Modifier.weight(1f))
        ThemeSwatch(VerdeColors)
    }
    if (choosing) AlertDialog(onDismissRequest = { choosing = false }, title = { Text("Theme") },
        text = {
            LazyColumn(Modifier.heightIn(max = 420.dp).testTag("appearance-theme-list").selectableGroup()) {
                items(AppearanceMode.entries, key = { it.name }) { mode ->
                    Row(Modifier.fillMaxWidth().selectable(selected = settings.mode == mode, role = Role.RadioButton,
                        onClick = { settings.select(mode); choosing = false }).padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = settings.mode == mode, onClick = null)
                        Text(mode.label, Modifier.weight(1f).padding(horizontal = 8.dp))
                        ThemeSwatch(settings.palette(androidx.compose.foundation.isSystemInDarkTheme(), mode))
                    }
                }
            }
        }, confirmButton = { TextButton(onClick = { choosing = false }) { Text("Done") } })
}

@Composable
private fun ThemeSwatch(palette: VerdePalette) {
    Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        listOf(palette.Background, palette.Text, palette.Accent).forEach { color ->
            Box(Modifier.size(12.dp).background(color, CircleShape).border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape))
        }
    }
}

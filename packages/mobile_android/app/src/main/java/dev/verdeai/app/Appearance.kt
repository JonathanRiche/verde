package dev.verdeai.app

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

internal enum class AppearanceMode(val label: String) {
    SYSTEM("System"), LIGHT("Light"), DARK("Dark");

    fun isDark(systemDark: Boolean) = when (this) {
        SYSTEM -> systemDark
        LIGHT -> false
        DARK -> true
    }
}

/** A device-local preference: changing a host must never change the phone's theme. */
internal class AppearanceSettings(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    var mode by mutableStateOf(AppearanceMode.entries.find { it.name == preferences.getString("theme", null) } ?: AppearanceMode.SYSTEM)
        private set

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
    Column(Modifier.selectableGroup()) {
        AppearanceMode.entries.forEach { mode ->
            Row(Modifier.fillMaxWidth().selectable(selected = settings.mode == mode, role = Role.RadioButton,
                onClick = { settings.select(mode) }).padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = settings.mode == mode, onClick = null)
                Text(mode.label, Modifier.padding(start = 16.dp))
            }
        }
    }
}

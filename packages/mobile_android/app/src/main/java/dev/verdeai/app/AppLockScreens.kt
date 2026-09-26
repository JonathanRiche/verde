package dev.verdeai.app

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner

/** True while the app lock covers the UI. Screens that open their own dialogs should hold them back. */
internal val LocalAppLocked = staticCompositionLocalOf { false }

internal const val LOCK_SCREEN = "app-lock-screen"

internal class AppLockControls(val model: AppLockModel, val auth: DeviceAuth)

/** Provided by [VerdeApp] when the Activity supplies an app lock; null in screen tests. */
internal val LocalAppLockControls = staticCompositionLocalOf<AppLockControls?> { null }

/**
 * Keeps [content] composed (navigation, focus claims and host work continue) but hides it from
 * sight, input and accessibility while locked. The lock itself is a full-screen dialog window so
 * it also sits above any dialog that was open when Verde locked.
 */
@Composable
internal fun AppLockGate(model: AppLockModel, auth: DeviceAuth, content: @Composable () -> Unit) {
    val state by model.state.collectAsState()
    val covered = state.covered
    Box(Modifier.fillMaxSize()) {
        Box(if (covered) Modifier.fillMaxSize().clearAndSetSemantics { } else Modifier.fillMaxSize()) {
            CompositionLocalProvider(LocalAppLocked provides covered) { content() }
        }
        // Opaque in-window cover: no content flash before settings load or while the dialog animates in.
        if (covered) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).clearAndSetSemantics { })
    }
    if (!covered) return
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) {
        // A focused composer or terminal must not keep receiving IME or hardware keys under the lock.
        focus.clearFocus(force = true)
        keyboard?.hide()
    }
    if (!state.locked) return
    val activity = LocalContext.current as? Activity
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val resumed by lifecycle.currentStateFlow.collectAsState()
    LaunchedEffect(state.autoPrompt, resumed) {
        if (state.autoPrompt && resumed.isAtLeast(Lifecycle.State.RESUMED)) model.unlock(auth)
    }
    Dialog(
        // Back leaves Verde rather than revealing the screen underneath.
        onDismissRequest = { activity?.moveTaskToBack(true) },
        properties = DialogProperties(dismissOnBackPress = true, dismissOnClickOutside = false,
            usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        // The dialog window has its own system bars; keep their icons readable on the dark surface.
        val view = LocalView.current
        SideEffect {
            (view.parent as? DialogWindowProvider)?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = false
                    isAppearanceLightNavigationBars = false
                }
            }
        }
        LockScreen(state, onUnlock = { model.unlock(auth) })
    }
}

@Composable
internal fun LockScreen(state: AppLockState, onUnlock: () -> Unit) {
    Surface(Modifier.fillMaxSize().testTag(LOCK_SCREEN)) {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            VerdeWordmark()
            Icon(Icons.Filled.Lock, contentDescription = null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
            Text("Verde is locked", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
            Text("Unlock with your fingerprint, face or screen lock. Your chats keep running on your hosts.",
                textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
            state.message?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
            Button(shape = MaterialTheme.shapes.small, onClick = onUnlock) { Text(if (state.authenticating) "Try again" else "Unlock") }
        }
    }
}

/** Settings → App lock & privacy. Changes apply immediately and persist in the credential store. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SecuritySettingsScreen(model: AppLockModel, auth: DeviceAuth, onBack: () -> Unit) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateFlow.collectAsState()
    // Picks up a screen lock the user just set in system settings.
    LaunchedEffect(lifecycleState) { if (lifecycleState == Lifecycle.State.RESUMED) model.refresh() }
    val settings = state.settings
    val lockOn = settings.enabled
    Column(Modifier.fillMaxSize()) {
        VerdeTopBar(title = { Text("App lock & privacy") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SettingSwitch("Require unlock",
                "Ask for your fingerprint, face or screen lock when you open Verde.",
                checked = lockOn, enabled = state.loaded && !state.authenticating && (lockOn || state.available),
            ) { model.setEnabled(it, auth) }
            if (!state.available) {
                Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(if (lockOn) "App lock is paused because this phone has no screen lock."
                            else "This phone has no screen lock. Set a PIN, pattern or password to use app lock.")
                        Button(shape = MaterialTheme.shapes.small, onClick = { openScreenLockSetup(context) }) { Text("Set up screen lock") }
                    }
                }
            }
            state.message?.takeIf { !state.locked }?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Text("Lock after leaving Verde", style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(top = 8.dp).semantics { heading() })
            Column(Modifier.selectableGroup()) {
                RelockAfter.entries.forEach { option ->
                    Row(Modifier.fillMaxWidth().selectable(selected = settings.relock_after == option, enabled = lockOn,
                        role = Role.RadioButton) { model.setRelockAfter(option) }.padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = settings.relock_after == option, onClick = null, enabled = lockOn)
                        Text(option.label, Modifier.padding(start = 16.dp),
                            color = if (lockOn) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f))
                    }
                }
            }
            HorizontalDivider()
            SettingSwitch("Hide content in screenshots and recents",
                "Blocks screenshots and screen recording, and blanks Verde's preview in recent apps." +
                    if (lockOn && android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU)
                        " On this Android version app lock keeps this on." else "",
                checked = settings.secure_screen, enabled = state.loaded) { model.setSecureScreen(it) }
            state.saveError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun SettingSwitch(title: String, detail: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onChange)
        .padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

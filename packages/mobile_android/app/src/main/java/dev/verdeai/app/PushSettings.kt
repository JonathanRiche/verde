package dev.verdeai.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** What the Compose UI needs from D-14. Null in tests and previews: no notification UI. */
internal class PushControls(
    val state: StateFlow<PushUiState>,
    val setEnabled: suspend (Boolean) -> Unit,
    val markAsked: suspend () -> Unit,
    /** System-level permission/channel state; re-read when the screen resumes. */
    val systemAllowed: () -> Boolean,
    val links: StateFlow<ThreadLink?>,
    val consumeLink: (ThreadLink) -> Unit,
)

internal val LocalPushControls = staticCompositionLocalOf<PushControls?> { null }

internal fun needsPermissionPrompt(context: Context) = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED

internal fun pushStatusText(state: PushUiState): String = when (state.status) {
    PushStatus.Unavailable -> "Notifications aren't available in this build."
    PushStatus.Off -> "Get notified when an agent finishes, fails or needs your approval."
    PushStatus.Registering -> "Setting up notifications…"
    PushStatus.WaitingForHost -> "Notifications start once a paired host is connected."
    PushStatus.On -> "On. Notification content is end-to-end encrypted from your host to this phone."
    PushStatus.Error -> "Couldn't finish setting up notifications. Verde retries when you next open it."
}

/** Turns notifications on, asking for POST_NOTIFICATIONS (API 33+) first. */
@Composable
private fun rememberEnableNotifications(controls: PushControls, onDenied: () -> Unit = {}): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        scope.launch { controls.setEnabled(granted) }
        if (!granted) onDenied()
    }
    return {
        if (needsPermissionPrompt(context)) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        else scope.launch { controls.setEnabled(true) }
    }
}

/**
 * Offers notifications once, right after a pairing completes (never on cold launch). Declining
 * is remembered; the settings toggle stays available.
 */
@Composable
internal fun PushOptInPrompt(hostsState: HostsState) {
    val controls = LocalPushControls.current ?: return
    val state by controls.state.collectAsState()
    val pairing = hostsState.pairing?.let { id -> hostsState.rows.find { it.saved.id == id } }
    val justPaired = pairing?.view?.auth_state == "paired" && pairing.view.trust_proposal == null
    var dismissed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val enable = rememberEnableNotifications(controls)
    if (!justPaired || dismissed || !state.loaded || !state.available || state.asked || state.enabled) return
    AlertDialog(
        onDismissRequest = { dismissed = true; scope.launch { controls.markAsked() } },
        title = { Text("Turn on notifications?") },
        text = { Text("Verde can tell you when an agent finishes, fails or needs your approval, even when your phone is locked. " +
            "Notification content is encrypted on your host and only this phone can read it.") },
        confirmButton = { TextButton(onClick = { dismissed = true; enable() }) { Text("Turn on") } },
        dismissButton = { TextButton(onClick = { dismissed = true; scope.launch { controls.markAsked() } }) { Text("Not now") } },
    )
}

/** Settings section (Security & privacy screen). */
@Composable
internal fun NotificationSettingsSection() {
    val controls = LocalPushControls.current ?: return
    val state by controls.state.collectAsState()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateFlow.collectAsState()
    // Re-read the system setting after the user returns from system notification settings.
    val systemAllowed = remember(lifecycleState) { controls.systemAllowed() }
    var denied by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val enable = rememberEnableNotifications(controls) { denied = true }
    HorizontalDivider()
    Text("Notifications", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp).semantics { heading() })
    Row(Modifier.fillMaxWidth().toggleable(state.enabled, enabled = state.loaded && state.available, role = Role.Switch) { on ->
        if (on) enable() else scope.launch { controls.setEnabled(false) }
    }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Agent notifications")
            Text(pushStatusText(state), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = state.enabled, onCheckedChange = null, enabled = state.loaded && state.available)
    }
    if (state.available && (denied || (state.enabled && !systemAllowed))) {
        Text("Notifications are blocked for Verde in system settings.", color = MaterialTheme.colorScheme.error)
        Button(shape = MaterialTheme.shapes.small, onClick = {
            context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }) { Text("Open notification settings") }
    }
}

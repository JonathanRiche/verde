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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
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
        // The dialog window has its own system bars; keep their icons readable in the selected theme.
        val view = LocalView.current
        val dark = VerdeColors.dark
        SideEffect {
            (view.parent as? DialogWindowProvider)?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
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
            Text("verde is locked", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
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
internal fun SecuritySettingsScreen(model: AppLockModel, auth: DeviceAuth, onHosts: (() -> Unit)? = null, onBack: () -> Unit) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateFlow.collectAsState()
    // Picks up a screen lock the user just set in system settings.
    LaunchedEffect(lifecycleState) { if (lifecycleState == Lifecycle.State.RESUMED) model.refresh() }
    val settings = state.settings
    val lockOn = settings.enabled
    Column(Modifier.fillMaxSize()) {
        VerdeTopBar(title = { Text("Settings") })
        // S8: Appearance, Notifications, Security, Companion, Hosts, About (iOS has the same order).
        CompositionLocalProvider(LocalSectionInset provides 0.dp) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            AppearanceSettingsSection()
            HorizontalDivider()
            NotificationSettingsSection()
            HorizontalDivider()
            VerdeSection("Security")
            SettingSwitch("Require unlock",
                "Ask for your fingerprint, face or screen lock when you open verde.",
                checked = lockOn, enabled = state.loaded && !state.authenticating && (lockOn || state.available),
            ) { model.setEnabled(it, auth) }
            if (!state.available) {
                Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(if (lockOn) "App lock is paused because this phone has no screen lock."
                            else "This phone has no screen lock. Set a PIN, pattern or password to use app lock.")
                        // V: the button's own node is named.
                        NamedButton("Set up screen lock", { openScreenLockSetup(context) }, Modifier.heightIn(min = 48.dp),
                            container = MaterialTheme.colorScheme.primary, content = MaterialTheme.colorScheme.onPrimary,
                            shape = MaterialTheme.shapes.small, padding = PaddingValues(horizontal = 24.dp))
                    }
                }
            }
            state.message?.takeIf { !state.locked }?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Text("Lock after leaving verde", style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(top = 8.dp).semantics { heading() })
            Column(Modifier.selectableGroup()) {
                RelockAfter.entries.forEach { option ->
                    Row(Modifier.fillMaxWidth().selectable(selected = settings.relock_after == option, enabled = lockOn,
                        role = Role.RadioButton) { model.setRelockAfter(option) }.nameOnly(option.label).heightIn(min = 48.dp).padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = settings.relock_after == option, onClick = null, enabled = lockOn)
                        Text(option.label, Modifier.padding(start = 16.dp),
                            color = if (lockOn) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f))
                    }
                }
            }
            HorizontalDivider()
            SettingSwitch("Hide content in screenshots and recents",
                "Blocks screenshots and screen recording, and blanks verde's preview in recent apps." +
                    if (lockOn && android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU)
                        " On this Android version app lock keeps this on." else "",
                checked = settings.secure_screen, enabled = state.loaded) { model.setSecureScreen(it) }
            state.saveError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            HorizontalDivider()
            CompanionBubbleSetting()
            LocalGitChangesClient.current?.let { client ->
                val git by client.snapshot.collectAsState()
                HorizontalDivider(color = VerdeColors.Border)
                GitCommitSettingsSection(git.settings)
            }
            if (onHosts != null) {
                HorizontalDivider()
                VerdeSection("Hosts")
                SettingLink("Manage hosts", "Pair, rename, switch or sign out of the computers this phone uses.", onHosts)
            }
            HorizontalDivider()
            VerdeSection("About")
            SettingValue("Version", appVersionLabel())
            var licences by rememberSaveable { mutableStateOf(false) }
            SettingLink("Open-source licences", "The fonts and icons verde ships with.") { licences = true }
            val uri = androidx.compose.ui.platform.LocalUriHandler.current
            SettingLink("Source code", SOURCE_URL.removePrefix("https://")) { uri.openUri(SOURCE_URL) }
            if (licences) LicencesScreen { licences = false }
        }
        }
    }
}

/** "0.1.0 (12)": the app's version name and build number. */
internal fun appVersionLabel(name: String = BuildConfig.VERSION_NAME, code: Int = BuildConfig.VERSION_CODE) = "$name ($code)"

@Composable
private fun SettingLink(title: String, detail: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClick = onClick).nameOnly("$title, $detail").padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SettingValue(title: String, value: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics(mergeDescendants = true) {}.padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        androidx.compose.foundation.text.selection.SelectionContainer {
            Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SettingSwitch(title: String, detail: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onChange)
        .nameOnly("$title, $detail").padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

internal const val SOURCE_URL = "https://github.com/JonathanRiche/verde"

/** One bundled component and its licence text (a raw resource), shown on the Licences page. */
internal data class BundledLicence(val name: String, val licence: String, val raw: Int?, val url: String? = null)

internal val BUNDLED_LICENCES = listOf(
    BundledLicence("Noto Sans", "SIL Open Font License 1.1", R.raw.licence_noto_sans),
    BundledLicence("Cal Sans", "SIL Open Font License 1.1", R.raw.licence_cal_sans),
    BundledLicence("JetBrains Mono", "SIL Open Font License 1.1", R.raw.licence_jetbrains_mono),
    BundledLicence("Material Icons", "Apache License 2.0", null, "https://www.apache.org/licenses/LICENSE-2.0"),
)

/**
 * One blank-line block as paragraphs (the iOS renderer): rulers ("-----") are dropped, and an
 * all-caps heading line ("PREAMBLE") stands as its own paragraph instead of running into the text.
 */
internal fun licenceBlockParagraphs(block: String): List<String> {
    val out = mutableListOf<String>()
    val current = mutableListOf<String>()
    fun flush() { if (current.isNotEmpty()) { out += current.joinToString(" "); current.clear() } }
    for (raw in block.split('\n')) {
        val line = raw.trim()
        if (line.isEmpty()) continue
        if (line.all { it == '-' || it == '=' || it == '_' }) { flush(); continue }
        val letters = line.filter { it.isLetter() }
        // A heading opens its block, is short, all caps and has no closing full stop.
        if (current.isEmpty() && letters.isNotEmpty() && letters == letters.uppercase() && line.length <= 40 && !line.endsWith(".")) {
            out += line; continue
        }
        current += line
    }
    flush()
    return out
}

/** Hard-wrapped licence text as paragraphs: blank lines separate them, the lines within one join. */
internal fun licenceParagraphs(text: String): List<String> =
    text.replace("\r\n", "\n").split(Regex("\n\\s*\n")).flatMap(::licenceBlockParagraphs).filter { it.isNotEmpty() }

/** Licence text reflowed for a phone, one paragraph per blank-line-separated block. */
internal fun reflowLicence(text: String): String = licenceParagraphs(text).joinToString("\n\n")

/** S15: every bundled font's licence in full (no template placeholders), selectable. */
@Composable
private fun LicencesScreen(onClose: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        LiveOverModal()
        DialogSystemBars()
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                VerdeTopBar(title = { Text("Open-source licences") }, showWorkspaceMenu = false, companion = false,
                    navigationIcon = { IconButton(onClick = onClose, modifier = Modifier.named("Back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null) } })
                androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
                    BUNDLED_LICENCES.forEach { item ->
                        item(key = item.name) {
                            Column(Modifier.padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(item.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
                                Text(item.licence, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                val paragraphs = remember(item.raw) {
                                    item.raw?.let { id -> context.resources.openRawResource(id).bufferedReader().use { r -> licenceParagraphs(r.readText()) } }
                                }
                                if (paragraphs != null) androidx.compose.foundation.text.selection.SelectionContainer {
                                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                        paragraphs.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
                                    }
                                }
                                item.url?.let { url -> TextButton(onClick = { uri.openUri(url) }, contentPadding = PaddingValues(horizontal = 0.dp)) { Text(url) } }
                            }
                        }
                    }
                }
            }
        }
    }
}

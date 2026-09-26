package dev.verdeai.app

import android.app.Activity
import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import dev.verdeai.core.SecureStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** How long Verde may stay in the background before it asks to be unlocked again. */
@Suppress("EnumEntryName")
@Serializable
internal enum class RelockAfter(val millis: Long, val label: String) {
    immediately(0L, "Immediately"),
    one_minute(60_000L, "After 1 minute"),
    five_minutes(5 * 60_000L, "After 5 minutes"),
    fifteen_minutes(15 * 60_000L, "After 15 minutes"),
}

/** Persisted in the credential store (Keystore-wrapped, no backup). Off by default; secure screen on. */
@Serializable
internal data class LockSettings(
    val version: Int = 1,
    val enabled: Boolean = false,
    val relock_after: RelockAfter = RelockAfter.one_minute,
    val secure_screen: Boolean = true,
)

internal data class AppLockState(
    val loaded: Boolean = false,
    val settings: LockSettings = LockSettings(),
    val locked: Boolean = false,
    /** The device has a PIN, pattern, password or biometric; without one Verde never locks. */
    val available: Boolean = true,
    val authenticating: Boolean = false,
    /** Show the system prompt without a tap: set when the lock engages or Verde returns while locked. */
    val autoPrompt: Boolean = false,
    /** System-provided prompt error or a local notice; never contains app content. */
    val message: String? = null,
    val saveError: String? = null,
) {
    /** UI is hidden until settings load, so a locked app never flashes its content. */
    val covered get() = !loaded || locked
}

internal sealed interface AuthOutcome {
    data object Success : AuthOutcome
    /** No screen lock or biometric: the lock must step aside rather than trap the user. */
    data object Unavailable : AuthOutcome
    data class Failed(val message: String?) : AuthOutcome
}

internal interface DeviceAuth {
    fun available(): Boolean
    /** Shows the system prompt. [done] runs at most once on the main thread; returns a cancel handle. */
    fun authenticate(title: String, done: (AuthOutcome) -> Unit): () -> Unit
}

/**
 * Process-scoped app lock. It gates UI only: host cores, sync and tails keep running underneath,
 * and nothing here touches [HostsModel]. Background time is measured on the monotonic clock.
 */
internal class AppLockModel(
    private val store: SecureStore,
    private val foreground: StateFlow<Boolean>?,
    private val deviceSecure: () -> Boolean,
    private val now: () -> Long = SystemClock::elapsedRealtime,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val mutableState = MutableStateFlow(AppLockState())
    val state: StateFlow<AppLockState> = mutableState.asStateFlow()
    private val writes = Mutex()
    private var backgroundedAt: Long? = null
    private var attempt = 0
    private var cancelPrompt: (() -> Unit)? = null
    private var promptClosedAway = false
    private var resultPending = false
    private var awayForResult = false

    init {
        scope.launch {
            val settings = try {
                store.get(KEY)?.let { LockJson.decodeFromString(LockSettings.serializer(), it) } ?: LockSettings()
            } catch (e: CancellationException) { throw e } catch (_: Exception) {
                // Unreadable settings must not lock the user out; the next change rewrites them.
                LockSettings()
            }
            val available = deviceSecure()
            val locked = settings.enabled && available
            mutableState.update { it.copy(loaded = true, settings = settings, available = available,
                locked = locked, autoPrompt = locked) }
            foreground?.collect(::onForeground)
        }
    }

    /** Re-reads whether the device can authenticate (e.g. after the user sets a screen lock). */
    fun refresh() {
        val available = deviceSecure()
        mutableState.update { it.copy(available = available, locked = it.locked && available) }
    }

    internal fun onForeground(visible: Boolean) {
        if (!visible) {
            // The system credential screen backgrounds Verde; that time is not "away".
            if (!state.value.authenticating && backgroundedAt == null) {
                backgroundedAt = now()
                awayForResult = resultPending
            }
            resultPending = false
            return
        }
        val since = backgroundedAt
        backgroundedAt = null
        val returningFromPrompt = promptClosedAway
        promptClosedAway = false
        refresh()
        // Coming back from the credential screen is neither a relock nor a reason to re-prompt.
        val forResult = awayForResult
        awayForResult = false
        if (returningFromPrompt || since == null) return
        val current = state.value
        // A picker or camera Verde opened gets a short grace so attaching a photo doesn't relock.
        val limit = if (forResult) maxOf(current.settings.relock_after.millis, RESULT_GRACE_MS) else current.settings.relock_after.millis
        if (current.locked) mutableState.update { it.copy(autoPrompt = !it.authenticating) }
        else if (current.loaded && current.settings.enabled && current.available && now() - since >= limit) lock()
    }

    /** Verde is starting an activity for a result (photo/file picker, camera). */
    fun expectResult() { resultPending = true }

    /** Verde is visible again; a result trip too short to count as background is over. */
    fun resumed() { resultPending = false }

    fun lock() {
        if (!state.value.settings.enabled || !deviceSecure()) return
        mutableState.update { it.copy(locked = true, autoPrompt = !it.authenticating, message = null) }
    }

    fun unlock(auth: DeviceAuth) {
        if (!state.value.locked) return
        prompt(auth, "Unlock Verde") { outcome ->
            when (outcome) {
                AuthOutcome.Success -> mutableState.update { it.copy(locked = false, message = null) }
                AuthOutcome.Unavailable -> mutableState.update { it.copy(locked = false, available = false, message = null) }
                is AuthOutcome.Failed -> mutableState.update { it.copy(message = outcome.message) }
            }
        }
    }

    /** Turning the lock on requires one successful unlock, which proves the user can get back in. */
    fun setEnabled(enabled: Boolean, auth: DeviceAuth) {
        if (!enabled) {
            save { it.copy(enabled = false) }
            mutableState.update { it.copy(locked = false, message = null) }
            return
        }
        if (!auth.available()) {
            mutableState.update { it.copy(available = false, message = NO_SCREEN_LOCK) }
            return
        }
        prompt(auth, "Turn on app lock") { outcome ->
            when (outcome) {
                AuthOutcome.Success -> { save { it.copy(enabled = true) }; mutableState.update { it.copy(message = null) } }
                AuthOutcome.Unavailable -> mutableState.update { it.copy(available = false, message = NO_SCREEN_LOCK) }
                is AuthOutcome.Failed -> mutableState.update { it.copy(message = outcome.message) }
            }
        }
    }

    fun setRelockAfter(value: RelockAfter) = save { it.copy(relock_after = value) }
    fun setSecureScreen(value: Boolean) = save { it.copy(secure_screen = value) }

    /** Cancels a pending prompt, e.g. when the Activity that hosts it is finishing. */
    fun cancelPrompt() {
        cancelPrompt?.invoke()
    }

    private fun prompt(auth: DeviceAuth, title: String, done: (AuthOutcome) -> Unit) {
        // A second request replaces a prompt the system may have dropped (e.g. on rotation).
        cancelPrompt?.invoke()
        val token = ++attempt
        mutableState.update { it.copy(authenticating = true, autoPrompt = false, message = null) }
        cancelPrompt = auth.authenticate(title) { outcome ->
            if (token != attempt) return@authenticate
            cancelPrompt = null
            // A prompt needs the user present, so the away time it caused never counts.
            backgroundedAt = null
            promptClosedAway = foreground?.value == false
            mutableState.update { it.copy(authenticating = false) }
            done(outcome)
        }
    }

    private fun save(change: (LockSettings) -> LockSettings) {
        mutableState.update { it.copy(settings = change(it.settings), saveError = null) }
        scope.launch {
            try {
                writes.withLock { store.put(KEY, LockJson.encodeToString(LockSettings.serializer(), state.value.settings)) }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {
                mutableState.update { it.copy(saveError = "Couldn't save this setting. It applies until Verde restarts.") }
            }
        }
    }

    companion object {
        const val KEY = "android/1/app-lock"
        const val RESULT_GRACE_MS = 60_000L
        const val NO_SCREEN_LOCK = "Set a screen lock on this phone to use app lock."
        private val LockJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; coerceInputValues = true }
    }
}

internal fun deviceSecure(context: Context): Boolean =
    context.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true

/** Platform BiometricPrompt (API 28+): no FragmentActivity or extra dependency needed. */
internal class AndroidDeviceAuth(private val activity: Activity) : DeviceAuth {
    override fun available(): Boolean = deviceSecure(activity)

    override fun authenticate(title: String, done: (AuthOutcome) -> Unit): () -> Unit {
        val signal = CancellationSignal()
        var finished = false
        val finish = { outcome: AuthOutcome -> if (!finished) { finished = true; done(outcome) } }
        val builder = BiometricPrompt.Builder(activity).setTitle(title)
            .setSubtitle("Use your fingerprint, face or screen lock")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
        } else {
            @Suppress("DEPRECATION") builder.setDeviceCredentialAllowed(true)
        }
        try {
            builder.build().authenticate(signal, activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = finish(AuthOutcome.Success)
                // A rejected finger/face keeps the prompt open; only errors end it.
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    finish(if (!available() || errorCode in UNAVAILABLE) AuthOutcome.Unavailable
                        else AuthOutcome.Failed(if (errorCode in QUIET) null else errString.toString()))
                }
            })
        } catch (e: RuntimeException) {
            // Some OEM builds throw instead of reporting an error; keep the Unlock button usable.
            Log.w("VerdeAppLock", "prompt failed: ${e.javaClass.simpleName}")
            finish(if (available()) AuthOutcome.Failed("Couldn't show the unlock prompt. Try again.") else AuthOutcome.Unavailable)
        }
        return { if (!finished) signal.cancel() }
    }

    private companion object {
        val UNAVAILABLE = setOf(BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL)
        val QUIET = setOf(BiometricPrompt.BIOMETRIC_ERROR_CANCELED, BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED)
    }
}

/** FLAG_SECURE blanks screenshots, recordings and the recents preview. */
internal fun applySecureWindow(activity: Activity, state: AppLockState) {
    val lockEnabled = state.settings.enabled && state.available
    // Android 13+ can hide only the recents preview; older versions need FLAG_SECURE for that.
    val secure = state.settings.secure_screen || (lockEnabled && Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU)
    if (secure) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) activity.setRecentsScreenshotEnabled(!lockEnabled)
}

/** Opens the system "choose screen lock" flow, falling back to Security settings. */
internal fun openScreenLockSetup(context: Context) {
    for (action in listOf(DevicePolicyManager.ACTION_SET_NEW_PASSWORD, Settings.ACTION_SECURITY_SETTINGS, Settings.ACTION_SETTINGS)) {
        try {
            context.startActivity(Intent(action).apply { if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
            return
        } catch (_: ActivityNotFoundException) { } catch (_: SecurityException) { }
    }
}

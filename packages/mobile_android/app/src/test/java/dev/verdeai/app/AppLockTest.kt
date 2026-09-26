package dev.verdeai.app

import android.os.Build
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.verdeai.core.SecureStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class AppLockTest {
    @get:Rule val compose = createComposeRule()
    private val store = MemoryStore()
    private val auth = FakeAuth()
    private val visible = MutableStateFlow(true)
    private var clock = 10_000L

    private fun model() = AppLockModel(store, visible, { auth.secure }, { clock }, CoroutineScope(Dispatchers.Unconfined))
    private fun enabled(relock: RelockAfter = RelockAfter.one_minute) {
        store.values[AppLockModel.KEY] = """{"version":1,"enabled":true,"relock_after":"${relock.name}","secure_screen":true}"""
    }
    private fun away(millis: Long) { visible.value = false; clock += millis; visible.value = true }

    @Test fun offByDefaultNeverLocks() {
        val lock = model()
        assertTrue(lock.state.value.loaded)
        assertFalse(lock.state.value.locked)
        assertEquals(LockSettings(), lock.state.value.settings)
        assertTrue(lock.state.value.settings.secure_screen)
        away(60 * 60_000L)
        assertFalse(lock.state.value.locked)
        assertEquals(0, auth.requests.size)
    }

    @Test fun locksOnLaunchAndUnlocksWithTheSystemPrompt() {
        enabled()
        val lock = model()
        assertTrue(lock.state.value.locked)
        assertTrue(lock.state.value.autoPrompt)
        lock.unlock(auth)
        assertTrue(lock.state.value.authenticating)
        assertFalse(lock.state.value.autoPrompt)
        assertEquals("Unlock Verde", auth.requests.single().title)
        auth.finish(AuthOutcome.Failed(null))
        assertTrue(lock.state.value.locked)
        assertFalse(lock.state.value.authenticating)
        lock.unlock(auth)
        auth.finish(AuthOutcome.Success)
        assertFalse(lock.state.value.locked)
    }

    @Test fun relocksOnlyAfterTheChosenTimeInTheBackground() {
        for (relock in RelockAfter.entries) {
            enabled(relock)
            val lock = model()
            lock.unlock(auth); auth.finish(AuthOutcome.Success)
            if (relock.millis > 0) {
                away(relock.millis - 1)
                assertFalse(relock.name, lock.state.value.locked)
            }
            away(relock.millis)
            assertTrue(relock.name, lock.state.value.locked)
            assertTrue(relock.name, lock.state.value.autoPrompt)
        }
    }

    @Test fun theCredentialScreenIsNotTimeAway() {
        enabled(RelockAfter.immediately)
        val lock = model()
        lock.unlock(auth)
        // The PIN screen stops Verde's Activity; ProcessLifecycleOwner reports background.
        visible.value = false
        clock += 30 * 60_000L
        auth.finish(AuthOutcome.Success)
        visible.value = true
        assertFalse(lock.state.value.locked)
        // A real trip away still relocks.
        away(1)
        assertTrue(lock.state.value.locked)
    }

    @Test fun cancellingThePromptDoesNotLoopIt() {
        enabled()
        val lock = model()
        lock.unlock(auth)
        visible.value = false
        auth.finish(AuthOutcome.Failed(null))
        visible.value = true
        assertTrue(lock.state.value.locked)
        assertFalse(lock.state.value.autoPrompt)
        assertNull(lock.state.value.message)
        away(5_000)
        assertTrue(lock.state.value.autoPrompt)
    }

    @Test fun aReplacedPromptIgnoresItsLateResult() {
        enabled()
        val lock = model()
        lock.unlock(auth)
        lock.unlock(auth)
        assertEquals(1, auth.cancelled)
        auth.requests[0].done(AuthOutcome.Success)
        assertTrue(lock.state.value.locked)
        auth.requests[1].done(AuthOutcome.Failed("Too many attempts. Try again later."))
        assertEquals("Too many attempts. Try again later.", lock.state.value.message)
        assertTrue(lock.state.value.locked)
    }

    @Test fun neverLocksOutWithoutAScreenLock() {
        enabled()
        auth.secure = false
        val lock = model()
        assertFalse(lock.state.value.locked)
        assertFalse(lock.state.value.available)
        away(60 * 60_000L)
        assertFalse(lock.state.value.locked)

        // The screen lock is removed while Verde is locked: the prompt reports it and the lock steps aside.
        auth.secure = true
        val second = model()
        assertTrue(second.state.value.locked)
        second.unlock(auth)
        auth.finish(AuthOutcome.Unavailable)
        assertFalse(second.state.value.locked)
        assertFalse(second.state.value.available)
        assertTrue(second.state.value.settings.enabled)

        // Removing it while Verde is away also unlocks on return.
        val third = model()
        auth.secure = false
        away(1_000)
        assertFalse(third.state.value.locked)
    }

    @Test fun turningOnRequiresAScreenLockAndOneUnlock() {
        auth.secure = false
        val lock = model()
        lock.setEnabled(true, auth)
        assertEquals(AppLockModel.NO_SCREEN_LOCK, lock.state.value.message)
        assertFalse(lock.state.value.settings.enabled)
        assertEquals(0, auth.requests.size)

        auth.secure = true
        lock.refresh()
        lock.setEnabled(true, auth)
        assertEquals("Turn on app lock", auth.requests.single().title)
        auth.finish(AuthOutcome.Failed("Not recognized"))
        assertFalse(lock.state.value.settings.enabled)
        assertNull(store.values[AppLockModel.KEY])
        lock.setEnabled(true, auth)
        auth.finish(AuthOutcome.Success)
        assertTrue(lock.state.value.settings.enabled)
        assertFalse(lock.state.value.locked)
        lock.setRelockAfter(RelockAfter.fifteen_minutes)
        lock.setSecureScreen(false)

        val reloaded = model()
        assertEquals(LockSettings(enabled = true, relock_after = RelockAfter.fifteen_minutes, secure_screen = false),
            reloaded.state.value.settings)
        assertTrue(reloaded.state.value.locked)

        reloaded.setEnabled(false, auth)
        assertFalse(reloaded.state.value.locked)
        assertFalse(model().state.value.settings.enabled)
    }

    @Test fun unreadableSettingsFallBackToUnlockedDefaults() {
        store.values[AppLockModel.KEY] = "{not json"
        assertEquals(LockSettings(), model().state.value.settings)
        store.values[AppLockModel.KEY] = """{"enabled":true,"relock_after":"forever","extra":1}"""
        val lock = model()
        assertTrue(lock.state.value.settings.enabled)
        assertEquals(RelockAfter.one_minute, lock.state.value.settings.relock_after)
        store.failReads = true
        assertFalse(model().state.value.locked)
    }

    @Test fun saveFailureIsReported() {
        val lock = model()
        store.failWrites = true
        lock.setSecureScreen(false)
        assertFalse(lock.state.value.settings.secure_screen)
        assertNotNull(lock.state.value.saveError)
    }

    @Test fun gateHidesContentUntilUnlocked() {
        enabled()
        val lock = model()
        compose.setContent { AppLockGate(lock, auth) { Text("secret transcript") } }
        compose.waitForIdle()
        compose.onNodeWithTag(LOCK_SCREEN).assertExists()
        compose.onNodeWithText("Verde is locked").assertExists()
        compose.onNodeWithText("secret transcript").assertDoesNotExist()
        // The prompt opens by itself once.
        assertEquals(1, auth.requests.size)
        compose.runOnUiThread { auth.finish(AuthOutcome.Failed(null)) }
        compose.onNodeWithText("Unlock").performClick()
        assertEquals(2, auth.requests.size)
        compose.runOnUiThread { auth.finish(AuthOutcome.Success) }
        compose.waitForIdle()
        compose.onNodeWithTag(LOCK_SCREEN).assertDoesNotExist()
        compose.onNodeWithText("secret transcript").assertIsDisplayed()
    }

    @Test fun settingsOfferScreenLockSetupWithoutOne() {
        auth.secure = false
        val lock = model()
        compose.setContent { SecuritySettingsScreen(lock, auth) {} }
        compose.onNodeWithText("Set up screen lock").assertExists()
        compose.onNodeWithText("Require unlock").assertExists()
        compose.onAllNodes(isToggleable()).onFirst().assertIsNotEnabled()
    }

    @Test fun settingsTurnOnLockAndChooseTimeout() {
        val lock = model()
        compose.setContent { SecuritySettingsScreen(lock, auth) {} }
        compose.onNodeWithText("Set up screen lock").assertDoesNotExist()
        compose.onNodeWithText("After 5 minutes").performClick()
        assertEquals(RelockAfter.one_minute, lock.state.value.settings.relock_after) // Disabled until the lock is on.
        compose.onNodeWithText("Require unlock").performClick()
        compose.runOnUiThread { auth.finish(AuthOutcome.Success) }
        compose.waitForIdle()
        compose.onAllNodes(isToggleable()).onFirst().assertIsOn()
        compose.onNodeWithText("After 5 minutes").performClick()
        assertEquals(RelockAfter.five_minutes, lock.state.value.settings.relock_after)
        compose.onNodeWithText("Hide content in screenshots and recents").performScrollTo().performClick()
        assertFalse(lock.state.value.settings.secure_screen)
        assertTrue(store.values[AppLockModel.KEY]!!.contains("\"five_minutes\""))
    }

    @Test fun secureWindowFollowsTheSettings() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        fun secure() = activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
        applySecureWindow(activity, AppLockState(loaded = true))
        assertTrue(secure())
        applySecureWindow(activity, AppLockState(loaded = true, settings = LockSettings(secure_screen = false)))
        assertFalse(secure())
        applySecureWindow(activity, AppLockState(loaded = true, settings = LockSettings(enabled = true, secure_screen = false)))
        // Android 13+ hides just the recents preview; older versions need FLAG_SECURE for it.
        assertEquals(Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU, secure())
        applySecureWindow(activity, AppLockState(loaded = true, available = false, settings = LockSettings(enabled = true, secure_screen = false)))
        assertFalse(secure())
    }

    private class Request(val title: String, val done: (AuthOutcome) -> Unit)

    private class FakeAuth : DeviceAuth {
        var secure = true
        var cancelled = 0
        val requests = mutableListOf<Request>()
        override fun available() = secure
        override fun authenticate(title: String, done: (AuthOutcome) -> Unit): () -> Unit {
            requests += Request(title, done)
            return { cancelled++ }
        }
        fun finish(outcome: AuthOutcome) = requests.last().done(outcome)
    }

    private class MemoryStore : SecureStore {
        val values = mutableMapOf<String, String>()
        var failReads = false
        var failWrites = false
        override suspend fun get(key: String): String? { if (failReads) error("locked"); return values[key] }
        override suspend fun put(key: String, value: String) { if (failWrites) error("locked"); values[key] = value }
        override suspend fun delete(key: String) { values.remove(key) }
    }
}

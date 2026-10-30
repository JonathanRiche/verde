package dev.verdeai.app

import android.app.Notification
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** A Live call carries on in the background like a phone call. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LiveCallServiceTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()

    @After fun reset() { LiveCalls.hangUp = {} }

    /** End then Start: the ending call's late clean-up must not stop the new call's service. */
    @Test fun aStaleEndingKeepsTheNewerCall() {
        val first = LiveCalls.started(context, "Moss")
        assertEquals(LiveCallService::class.java.name, shadowOf(context).nextStartedService.component?.className)
        val second = LiveCalls.started(context, "Moss")
        LiveCalls.ended(context, first)
        assertTrue(LiveCalls.active.value)
        assertNullStop()
        LiveCalls.ended(context, second)
        assertFalse(LiveCalls.active.value)
        assertEquals(LiveCallService::class.java.name, shadowOf(context).nextStoppedService.component?.className)
    }

    private fun assertNullStop() = assertEquals(null, shadowOf(context).nextStoppedService)

    @Test fun ongoingCallNotificationReturnsToTheCallAndHangsUp() {
        var hungUp = 0
        LiveCalls.hangUp = { hungUp++ }
        val controller = Robolectric.buildService(LiveCallService::class.java,
            Intent(context, LiveCallService::class.java).putExtra(LiveCallService.EXTRA_NAME, "Moss")).create().startCommand(0, 1)
        val shadow = shadowOf(controller.get())
        val notification = shadow.lastForegroundNotification
        assertNotNull(notification)
        assertEquals(Notification.CATEGORY_CALL, notification.category)
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        // Call style: the companion as the caller, the platform's ongoing-call look and Hang up button.
        assertEquals("Moss", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertTrue(notification.extras.getString(Notification.EXTRA_TEMPLATE).orEmpty().endsWith("CallStyle"))
        assertNotNull(notification.contentIntent)
        // Hang up from the notification ends the call and the service.
        controller.withIntent(Intent(context, LiveCallService::class.java).setAction(LiveCallService.ACTION_HANG_UP)).startCommand(0, 2)
        assertEquals(1, hungUp)
        assertTrue(shadow.isStoppedBySelf)
    }

    /** Swiping verde away from Recents ends the call; leaving it doesn't. */
    @Test fun closingVerdeFromRecentsEndsTheCall() {
        var hungUp = 0
        LiveCalls.hangUp = { hungUp++ }
        val controller = Robolectric.buildService(LiveCallService::class.java).create()
        controller.get().onTaskRemoved(null)
        assertEquals(1, hungUp)
    }

    @Test fun aCallKeepsHostConnectionsInTheForeground() = runBlocking {
        val front = MutableStateFlow(true)
        val base = object : AppSignals {
            override val foreground: StateFlow<Boolean> = front
            override val network: StateFlow<NetworkState> = MutableStateFlow(NetworkState(true, "n"))
        }
        val signals = CallAwareSignals(base, CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
        val call = LiveCalls.started(context, "Moss")
        front.value = false
        assertTrue(withTimeout(1_000) { signals.foreground.first { it } })
        LiveCalls.ended(context, call)
        assertFalse(withTimeout(1_000) { signals.foreground.first { !it } })
    }
}

package dev.verdeai.app

import android.Manifest
import android.app.Application
import android.app.Notification
import androidx.test.core.app.ApplicationProvider
import dev.verdeai.core.PushNotification
import dev.verdeai.core.PushOpenRequest
import dev.verdeai.core.SecureStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap

/** D-14 payload handling and notification building, without the native core or Firebase. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PushNotificationsTest {
    private val context: Application = ApplicationProvider.getApplicationContext()
    private val store = MemoryStore()
    private val requests = mutableListOf<PushOpenRequest>()
    private val shown = mutableListOf<Pair<PushNotification, Boolean>>()
    private val forwarded = mutableListOf<PushNotification>()
    private var reply: (PushOpenRequest) -> PushNotification? = { model(dedupe = "d1") }

    private fun receiver() = PushReceiver(store, { request -> requests += request; reply(request) },
        { model, hide -> shown += model to hide }) { forwarded += it }

    private fun model(dedupe: String? = "d1", duplicate: Boolean = false, kind: String = "approval_pending",
                      actions: List<String> = listOf("open", "approve", "deny", "reply"), channel: String = "attention",
                      update: Boolean = false) =
        PushNotification(api_version = 1, opened = true, update_required = update, error = null, host_id = "a",
            workspace_id = "ws", thread_id = "th", turn_id = "tu", kind = kind, attention = "needs_approval",
            channel = channel, title = "Fix the build", body = "Run cargo test?", deep_link = "verde://thread",
            actions = actions, dedupe_key = dedupe, duplicate = duplicate)

    @Before fun setUp() {
        store.values[HostsModel.CATALOG_KEY] = """{"hosts":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"active":"a"}"""
        store.values["vc/1/a/push"] = "cmVjb3JkLWE="
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        PushChannels.create(context)
    }

    @Test fun opensWithEverySavedHostKeyAndRecordsTheDedupeKey() = runBlocking {
        store.values[PushReceiver.RECENT_KEY] = """["d0"]"""
        val result = receiver().handle(mapOf("ciphertext" to "AYUg", "collapse_id" to "c"))
        val request = requests.single()
        assertEquals("AYUg", request.envelope)
        assertEquals(listOf("a"), request.keys.map { it.host_id }) // b has no push key yet
        assertEquals("cmVjb3JkLWE=", request.keys.single().record_base64)
        assertEquals(listOf("d0"), request.recent)
        assertEquals("d1", result!!.dedupe_key)
        assertEquals("""["d0","d1"]""", store.values[PushReceiver.RECENT_KEY])
        assertEquals(false, shown.single().second)
        assertEquals(result, forwarded.single())
    }

    @Test fun duplicatesAreDropped() = runBlocking {
        reply = { model(duplicate = true) }
        assertNull(receiver().handle(mapOf("ciphertext" to "AYUg")))
        assertTrue(shown.isEmpty())
        assertTrue(forwarded.isEmpty())
    }

    @Test fun missingOrOversizedPayloadsAreIgnored() = runBlocking {
        assertNull(receiver().handle(emptyMap()))
        assertNull(receiver().handle(mapOf("ciphertext" to "")))
        assertNull(receiver().handle(mapOf("ciphertext" to "A".repeat(PushReceiver.MAX_ENVELOPE + 1))))
        assertTrue(requests.isEmpty())
        assertTrue(shown.isEmpty())
    }

    @Test fun withoutKeysOrWhenTheCoreRefusesTheNoticeIsGeneric() = runBlocking {
        store.values.remove("vc/1/a/push")
        val noKeys = receiver().handle(mapOf("ciphertext" to "AYUg"))!!
        assertTrue(requests.isEmpty())
        assertFalse(noKeys.opened)
        assertEquals(PushNotifier.GENERIC_BODY, noKeys.body)
        store.values["vc/1/a/push"] = "cmVjb3JkLWE="
        reply = { null }
        assertFalse(receiver().handle(mapOf("ciphertext" to "AYUg"))!!.opened)
        assertEquals(2, shown.size)
        assertTrue(forwarded.isEmpty())
    }

    @Test fun appLockHidesContent() = runBlocking {
        store.values[AppLockModel.KEY] = """{"version":1,"enabled":true,"relock_after":"one_minute","secure_screen":true}"""
        receiver().handle(mapOf("ciphertext" to "AYUg"))
        assertTrue(shown.single().second)
        store.values[AppLockModel.KEY] = "not json"
        receiver().handle(mapOf("ciphertext" to "AYUg"))
        assertTrue(shown.last().second) // Unreadable lock settings fail closed.
    }

    @Test fun approvalNotificationRequiresAuthAndHidesContentOnTheLockScreen() {
        val notification = PushNotifier(context).build(model(), hideContent = false)
        assertEquals(PushChannels.ATTENTION, notification.channelId)
        assertEquals("Fix the build", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("Run cargo test?", notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        val public = notification.publicVersion!!
        assertEquals("Verde", public.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals(PushNotifier.GENERIC_BODY, public.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals(3, notification.actions.size)
        assertTrue(notification.actions.all { it.isAuthenticationRequired })
        val reply = notification.actions[2]
        assertEquals(NotificationIntents.REPLY_KEY, reply.remoteInputs.single().resultKey)
    }

    @Test fun hiddenContentShowsOnlyTheEventKind() {
        val notification = PushNotifier(context).build(model(kind = "completed", channel = "completed", actions = listOf("open")), hideContent = true)
        assertEquals(PushChannels.COMPLETED, notification.channelId)
        assertNotEquals("Fix the build", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertFalse(notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString().contains("cargo"))
        assertNull(notification.actions)
    }

    private class MemoryStore : SecureStore {
        val values = ConcurrentHashMap<String, String>()
        override suspend fun get(key: String): String? = values[key]
        override suspend fun put(key: String, value: String) { values[key] = value }
        override suspend fun delete(key: String) { values.remove(key) }
    }
}

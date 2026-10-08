package dev.verdeai.app

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.os.Bundle
import androidx.core.app.RemoteInput
import androidx.test.core.app.ApplicationProvider
import dev.verdeai.core.Pane
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
        assertEquals(listOf("Approve", "Deny", "Reply"), notification.actions.map { it.title.toString() })
        assertTrue(notification.actions.all { it.isAuthenticationRequired })
        val reply = notification.actions[2]
        assertEquals(NotificationIntents.REPLY_KEY, reply.remoteInputs.single().resultKey)
    }

    @Test fun hiddenContentShowsOnlyTheEventKind() {
        val notification = PushNotifier(context).build(model(kind = "completed", channel = "completed", actions = listOf("open")), hideContent = true)
        assertEquals(PushChannels.COMPLETED, notification.channelId)
        assertEquals("Verde", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("Reply ready", notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertNull(notification.actions)
    }

    @Test fun genericAndUpdateRequiredNoticesHaveNoActions() {
        val generic = PushNotifier(context).build(genericPush(), hideContent = false)
        assertEquals("Verde", generic.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertNull(generic.actions)
        val update = PushNotifier(context).build(model(update = true, actions = listOf("open")), hideContent = false)
        assertEquals("Update Verde to read this notification.", update.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
    }

    @Test fun showReplacesTheThreadsRunningNotice() {
        val notifier = PushNotifier(context)
        val pane = Pane(id = "p", workspace_id = "ws", kind = "chat", title = "Fix the build", thread_id = "th",
            status = "running", started_at_ms = 1_000L, can_stop = true)
        notifier.showRunning("a", listOf(pane), hideContent = false)
        val manager = context.getSystemService(NotificationManager::class.java)
        val running = shadowOf(manager).allNotifications.single()
        assertTrue(running.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(PushChannels.RUNNING, running.channelId)
        assertEquals(listOf("Stop"), running.actions.map { it.title.toString() })
        notifier.show(model(), hideContent = false)
        val active = manager.activeNotifications.single()
        assertEquals(NotificationTags.thread("a", "ws", "th"), active.tag)
        notifier.showRunning("a", listOf(pane), hideContent = false)
        notifier.cancelAllRunning()
        assertEquals(listOf(NotificationTags.thread("a", "ws", "th")), manager.activeNotifications.map { it.tag })
    }

    @Test fun actionIntentsRoundTripAndReplyNeedsText() {
        val tag = NotificationTags.thread("a", "ws", "th")
        val approve = NotificationIntents.intent(context, NotificationVerb.Approve, "a", "ws", "th", "tu", tag, NotificationTags.PUSH_ID)
        assertEquals(NotificationAction(NotificationVerb.Approve, "a", "ws", "th", "tu", tag, NotificationTags.PUSH_ID),
            NotificationIntents.parse(approve))
        val reply = NotificationIntents.intent(context, NotificationVerb.Reply, "a", "ws", "th", "tu", tag, NotificationTags.PUSH_ID)
        assertNull(NotificationIntents.parse(reply))
        RemoteInput.addResultsToIntent(arrayOf(RemoteInput.Builder(NotificationIntents.REPLY_KEY).build()), reply,
            Bundle().apply { putCharSequence(NotificationIntents.REPLY_KEY, "  ship it  ") })
        assertEquals("ship it", NotificationIntents.parse(reply)!!.reply)
        assertNull(NotificationIntents.parse(Intent("other").putExtras(approve)))
    }

    @Test fun noFirebaseConfigMeansNoFirebase() {
        assertFalse(initFirebase(context, null))
        assertFalse(PushBuild.current.available) // Test builds carry no google-services.json.
    }

    private class MemoryStore : SecureStore {
        val values = ConcurrentHashMap<String, String>()
        override suspend fun get(key: String): String? = values[key]
        override suspend fun put(key: String, value: String) { values[key] = value }
        override suspend fun delete(key: String) { values.remove(key) }
    }
}

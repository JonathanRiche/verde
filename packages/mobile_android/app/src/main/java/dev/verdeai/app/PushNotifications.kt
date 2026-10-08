package dev.verdeai.app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import dev.verdeai.core.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

/*
 * D-14 notifications. Content comes only from the core's `vc_push_open` model; every decrypt
 * failure is the core's generic "A Verde chat needs attention". Nothing here logs tokens, keys,
 * envelopes or content.
 */

internal object PushChannels {
    const val ATTENTION = "attention"
    const val COMPLETED = "completed"
    const val RUNNING = "running"

    fun create(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannels(listOf(
            NotificationChannel(ATTENTION, "Attention", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Approvals, questions and failed turns"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
            NotificationChannel(COMPLETED, "Completed", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Replies that finished while you were away"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
            NotificationChannel(RUNNING, "Running", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Agents still working when you left Verde"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                setShowBadge(false)
            },
        ))
    }

    fun of(channel: String) = if (channel == COMPLETED) COMPLETED else ATTENTION
}

internal enum class NotificationVerb(val wire: String) {
    Open("open"), Approve("approve"), Deny("deny"), Reply("reply"), Stop("stop");
    companion object { fun of(wire: String?) = entries.find { it.wire == wire } }
}

/** One tapped notification or action. Ids are routing data only; the core validates everything. */
internal data class NotificationAction(
    val verb: NotificationVerb,
    val hostId: String?,
    val workspaceId: String?,
    val threadId: String?,
    val turnId: String?,
    /** Notification to clear once handled. */
    val tag: String,
    val notificationId: Int,
    /** RemoteInput text for [NotificationVerb.Reply]; memory only. */
    val reply: String? = null,
) {
    val hasThread get() = hostId != null && workspaceId != null && threadId != null
}

/** Stable notification identities: one per thread (newest event wins), one for generic notices. */
internal object NotificationTags {
    const val PUSH_ID = 1
    const val RUNNING_ID = 2
    const val GENERIC = "verde:generic"
    fun thread(host: String, workspace: String, thread: String) = "verde:t:" + listOf(host, workspace, thread).joinToString("\u001f")
    fun running(host: String, workspace: String, thread: String) = "verde:r:" + listOf(host, workspace, thread).joinToString("\u001f")
    fun of(model: PushNotification): String {
        val host = model.host_id
        val ws = model.workspace_id
        val thread = model.thread_id
        return if (host != null && ws != null && thread != null) thread(host, ws, thread) else GENERIC
    }
}

internal object NotificationIntents {
    const val ACTION = "dev.verdeai.app.action.NOTIFICATION"
    const val REPLY_KEY = "verde_reply"
    private const val VERB = "verb"
    private const val HOST = "host_id"
    private const val WORKSPACE = "workspace_id"
    private const val THREAD = "thread_id"
    private const val TURN = "turn_id"
    private const val TAG = "tag"
    private const val ID = "notification_id"

    /** Targets the non-exported [NotificationActionActivity], so no other app can forge an action. */
    fun intent(context: Context, verb: NotificationVerb, host: String?, workspace: String?, thread: String?,
               turn: String?, tag: String, id: Int): Intent =
        Intent(context, NotificationActionActivity::class.java).setAction(ACTION).putExtras(Bundle().apply {
            putString(VERB, verb.wire)
            host?.let { putString(HOST, it) }
            workspace?.let { putString(WORKSPACE, it) }
            thread?.let { putString(THREAD, it) }
            turn?.let { putString(TURN, it) }
            putString(TAG, tag)
            putInt(ID, id)
        })

    fun pending(context: Context, intent: Intent, mutable: Boolean = false): PendingIntent {
        val code = (intent.getStringExtra(TAG) + "\u0000" + intent.getStringExtra(VERB)).hashCode()
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (mutable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE
            else if (mutable) 0 else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, code, intent, flags)
    }

    fun parse(intent: Intent?): NotificationAction? {
        if (intent?.action != ACTION) return null
        val verb = NotificationVerb.of(intent.getStringExtra(VERB)) ?: return null
        val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_KEY)?.toString()
            ?.trim()?.take(MAX_REPLY)?.takeIf { it.isNotEmpty() }
        if (verb == NotificationVerb.Reply && reply == null) return null
        return NotificationAction(verb, intent.getStringExtra(HOST), intent.getStringExtra(WORKSPACE), intent.getStringExtra(THREAD),
            intent.getStringExtra(TURN), intent.getStringExtra(TAG) ?: NotificationTags.GENERIC,
            intent.getIntExtra(ID, NotificationTags.PUSH_ID), reply)
    }

    private const val MAX_REPLY = 16 * 1024
}

/** Short labels for content-hidden notifications (app lock on): no title or snippet. */
internal fun pushLabel(kind: String): String = when (kind) {
    "completed" -> "Reply ready"
    "failed" -> "Turn failed"
    "aborted" -> "Turn stopped"
    "approval_pending" -> "Needs approval"
    "input_needed" -> "Needs input"
    "test" -> "Test notification"
    else -> "A Verde chat needs attention"
}

internal class PushNotifier(private val context: Context) {
    private val manager = NotificationManagerCompat.from(context)

    fun allowed(): Boolean = manager.areNotificationsEnabled()

    /** [hideContent]: app lock is on, so even the unlocked shade shows only the event kind. */
    fun build(model: PushNotification, hideContent: Boolean): Notification {
        val tag = NotificationTags.of(model)
        val id = NotificationTags.PUSH_ID
        val title = if (hideContent || !model.opened) "Verde" else model.title
        val body = when {
            model.update_required -> "Update Verde to read this notification."
            hideContent && model.opened -> pushLabel(model.kind)
            else -> model.body
        }
        fun intent(verb: NotificationVerb) = NotificationIntents.intent(context, verb, model.host_id, model.workspace_id,
            model.thread_id, model.turn_id, tag, id)
        val builder = NotificationCompat.Builder(context, PushChannels.of(model.channel))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(if (model.kind == "approval_pending" || model.kind == "input_needed") NotificationCompat.CATEGORY_MESSAGE else NotificationCompat.CATEGORY_STATUS)
            .setPriority(if (PushChannels.of(model.channel) == PushChannels.ATTENTION) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(NotificationIntents.pending(context, intent(NotificationVerb.Open)))
            // Lock screen: only "Verde · A Verde chat needs attention" until the phone is unlocked.
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion(PushChannels.of(model.channel)))
        val thread = model.host_id != null && model.workspace_id != null && model.thread_id != null
        if (thread && model.turn_id != null && "approve" in model.actions) {
            // Decision 5: allowed from the lock screen, after a biometric/credential unlock.
            builder.addAction(NotificationCompat.Action.Builder(0, "Approve",
                NotificationIntents.pending(context, intent(NotificationVerb.Approve))).setAuthenticationRequired(true).build())
            builder.addAction(NotificationCompat.Action.Builder(0, "Deny",
                NotificationIntents.pending(context, intent(NotificationVerb.Deny))).setAuthenticationRequired(true).build())
        }
        if (thread && "reply" in model.actions) {
            val input = RemoteInput.Builder(NotificationIntents.REPLY_KEY).setLabel("Reply").build()
            builder.addAction(NotificationCompat.Action.Builder(0, "Reply",
                NotificationIntents.pending(context, intent(NotificationVerb.Reply), mutable = true))
                .addRemoteInput(input).setAllowGeneratedReplies(false).setAuthenticationRequired(true).build())
        }
        return builder.build()
    }

    @android.annotation.SuppressLint("MissingPermission") // Checked by allowed().
    fun show(model: PushNotification, hideContent: Boolean) {
        if (!allowed()) return
        val host = model.host_id
        val ws = model.workspace_id
        val thread = model.thread_id
        // Any attention event for a thread supersedes its "still running" notice.
        if (host != null && ws != null && thread != null) cancelRunning(host, ws, thread)
        manager.notify(NotificationTags.of(model), NotificationTags.PUSH_ID, build(model, hideContent))
    }

    /** Ongoing notice for a turn still running when Verde went to the background. */
    fun buildRunning(hostId: String, pane: Pane, hideContent: Boolean): Notification? {
        val thread = pane.thread_id ?: return null
        val tag = NotificationTags.running(hostId, pane.workspace_id, thread)
        fun intent(verb: NotificationVerb) = NotificationIntents.intent(context, verb, hostId, pane.workspace_id, thread,
            null, tag, NotificationTags.RUNNING_ID)
        val builder = NotificationCompat.Builder(context, PushChannels.RUNNING)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (hideContent) "Verde" else pane.title.ifBlank { "Chat" })
            .setContentText("Agent is working")
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            // The phone stops hearing about this turn in the background; never leave it forever.
            .setTimeoutAfter(RUNNING_TIMEOUT_MS)
            .setContentIntent(NotificationIntents.pending(context, intent(NotificationVerb.Open)))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion(PushChannels.RUNNING))
        pane.started_at_ms?.let { builder.setWhen(it).setUsesChronometer(true).setShowWhen(true) }
        if (pane.can_stop) builder.addAction(NotificationCompat.Action.Builder(0, "Stop",
            NotificationIntents.pending(context, intent(NotificationVerb.Stop))).setAuthenticationRequired(true).build())
        return builder.build()
    }

    @android.annotation.SuppressLint("MissingPermission")
    fun showRunning(hostId: String, panes: List<Pane>, hideContent: Boolean) {
        if (!allowed()) return
        for (pane in panes) {
            val thread = pane.thread_id ?: continue
            val notification = buildRunning(hostId, pane, hideContent) ?: continue
            manager.notify(NotificationTags.running(hostId, pane.workspace_id, thread), NotificationTags.RUNNING_ID, notification)
        }
    }

    fun cancelRunning(host: String, workspace: String, thread: String) =
        manager.cancel(NotificationTags.running(host, workspace, thread), NotificationTags.RUNNING_ID)

    /** Verde is in the foreground again: live state replaces every running notice. */
    fun cancelAllRunning() {
        val system = context.getSystemService(NotificationManager::class.java) ?: return
        system.activeNotifications.filter { it.id == NotificationTags.RUNNING_ID && it.tag?.startsWith("verde:r:") == true }
            .forEach { manager.cancel(it.tag, it.id) }
    }

    fun cancel(tag: String, id: Int) = manager.cancel(tag, id)

    private fun publicVersion(channel: String): Notification =
        NotificationCompat.Builder(context, channel).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Verde").setContentText(GENERIC_BODY).build()

    companion object {
        const val GENERIC_BODY = "A Verde chat needs attention"
        const val RUNNING_TIMEOUT_MS = 2 * 60 * 60_000L
    }
}

/** Opens one push through the core; abstracted so Robolectric tests need no native library. */
internal fun interface PushOpener {
    /** Null when the core rejected the request itself (malformed input). */
    fun open(request: PushOpenRequest): PushNotification?
}

internal object JniPushOpener : PushOpener {
    override fun open(request: PushOpenRequest): PushNotification? {
        val status = IntArray(1)
        val bytes = try { Native.pushOpen(CoreJson.encodeToString(request).encodeToByteArray(), status) } catch (_: Throwable) { null }
        if (bytes == null || status[0] != 0) return null
        return try { CoreJson.decodeFromString<PushNotification>(bytes.decodeToString()) } catch (_: Exception) { null }
    }
}

/** The core's generic model, for when the core cannot even be asked. */
internal fun genericPush(): PushNotification = PushNotification(api_version = 1, opened = false, update_required = false,
    error = "unavailable", host_id = null, workspace_id = null, thread_id = null, turn_id = null, kind = "generic",
    attention = null, channel = "attention", title = "Verde", body = PushNotifier.GENERIC_BODY, deep_link = "verde://open",
    actions = listOf("open"), dedupe_key = null, duplicate = false)

/**
 * Handles one FCM data message: gathers every saved host's push key record and the `recent`
 * dedupe list, decrypts through the core, then shows (or drops a duplicate). Runs in the
 * messaging service with or without a live Activity.
 */
internal class PushReceiver(
    private val store: SecureStore,
    private val opener: PushOpener,
    private val show: (PushNotification, Boolean) -> Unit,
    /** Hands an opened push to a live host core (`push_received`); no-op without an Activity. */
    private val forward: (PushNotification) -> Unit = {},
) {
    private val recentLock = Mutex()

    suspend fun handle(data: Map<String, String>): PushNotification? {
        val envelope = data["ciphertext"]?.takeIf { it.isNotEmpty() && it.length <= MAX_ENVELOPE } ?: return null
        val keys = try {
            hostIds().mapNotNull { id -> store.get("vc/1/$id/push")?.let { PushOpenKey(host_id = id, record_base64 = it) } }
        } catch (_: Exception) { emptyList() } // Locked or unreadable store: generic notice below.
        val model = recentLock.withLock {
            val recent = loadRecent()
            val opened = (if (keys.isEmpty()) null else opener.open(PushOpenRequest(api_version = 1, envelope = envelope, keys = keys, recent = recent)))
                ?: genericPush()
            if (opened.duplicate) return null
            opened.dedupe_key?.let { key -> saveRecent((recent + key).takeLast(MAX_RECENT)) }
            opened
        }
        show(model, hideContent())
        if (model.opened) forward(model)
        return model
    }

    private suspend fun hostIds(): List<String> = store.get(HostsModel.CATALOG_KEY)
        ?.let { CoreJson.decodeFromString<HostCatalog>(it).hosts.map(SavedHost::id) }.orEmpty().take(MAX_KEYS)

    private suspend fun loadRecent(): List<String> = try {
        store.get(RECENT_KEY)?.let { CoreJson.decodeFromString<List<String>>(it) }.orEmpty()
    } catch (_: Exception) { emptyList() }

    private suspend fun saveRecent(recent: List<String>) {
        try { store.put(RECENT_KEY, CoreJson.encodeToString(recent)) } catch (_: Exception) { }
    }

    /** D-15: with app lock on, the shade shows the event kind only. */
    private suspend fun hideContent(): Boolean = try {
        store.get(AppLockModel.KEY)?.let { CoreJson.decodeFromString<LockSettings>(it).enabled } ?: false
    } catch (_: Exception) { true }

    companion object {
        const val RECENT_KEY = "android/1/push-recent"
        const val MAX_RECENT = 128
        const val MAX_KEYS = 32
        /** Relay-enforced envelope bound (README) with headroom. */
        const val MAX_ENVELOPE = 4096
    }
}

/**
 * Non-exported trampoline for every notification tap and action. It hands the action to the
 * process (never through an exported Intent, so other apps cannot forge an approval) and opens
 * MainActivity, which runs it once its hosts are loaded.
 */
class NotificationActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NotificationIntents.parse(intent)?.let { (application as VerdeApplication).push.dispatch(it) }
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        finish()
    }
}

/** Process-scoped queue of tapped notification actions; one consumer, each action runs once. */
internal class NotificationActionQueue {
    private val channel = Channel<NotificationAction>(capacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val actions: ReceiveChannel<NotificationAction> get() = channel
    fun post(action: NotificationAction) { channel.trySend(action) }
}

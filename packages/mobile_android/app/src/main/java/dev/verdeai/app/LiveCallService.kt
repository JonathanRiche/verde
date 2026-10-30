package dev.verdeai.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A Live call as the rest of the process sees it, so it can carry on like a phone call while verde
 * is in the background: [LiveCallService] keeps the process and microphone going with an
 * ongoing-call notification, and host connections stay open (see [CallAwareSignals]).
 */
internal object LiveCalls {
    private val mutableActive = MutableStateFlow(false)
    /** A call is connecting, live or reconnecting. */
    val active: StateFlow<Boolean> = mutableActive.asStateFlow()
    /** Ends the current call (the notification's Hang up, verde swiped away). Set by [LiveVoice]. */
    @Volatile var hangUp: () -> Unit = {}
    private var current = 0L

    /** A call started; returns its token for [ended]. Starts the service: verde is in front when a call starts. */
    fun started(context: Context, name: String): Long {
        val token = ++current
        mutableActive.value = true
        val intent = Intent(context, LiveCallService::class.java).putExtra(LiveCallService.EXTRA_NAME, name)
        // Without the service the call still works in front; it just stops when verde is left.
        try { ContextCompat.startForegroundService(context, intent) } catch (e: Exception) { Log.w(TAG, "live call service not started", e) }
        return token
    }

    /** The call with [token] ended; a newer call keeps the service. */
    fun ended(context: Context, token: Long) {
        if (token != current) return
        mutableActive.value = false
        context.stopService(Intent(context, LiveCallService::class.java))
    }

    private const val TAG = "VerdeLive"
}

/**
 * Keeps a Live call going while verde is in the background: a microphone foreground service with a
 * call-style notification (tap returns to the call, Hang up ends it). Swiping verde away from Recents
 * ends the call; only leaving verde keeps it.
 */
class LiveCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANG_UP) {
            LiveCalls.hangUp()
            stopSelf()
            return START_NOT_STICKY
        }
        val name = intent?.getStringExtra(EXTRA_NAME)?.ifBlank { null } ?: "your companion"
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(name), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        return START_NOT_STICKY
    }

    /** verde was swiped away from Recents: closing it ends the call, like quitting a call app. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        LiveCalls.hangUp()
        stopSelf()
    }

    private fun notification(name: String): android.app.Notification {
        channel(this)
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val hangUp = PendingIntent.getService(this, 1, Intent(this, LiveCallService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val caller = Person.Builder().setName(name).setImportant(true).build()
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Live with $name")
            .setContentText("Tap to return to the call")
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(caller, hangUp))
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setUsesChronometer(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            // Lock screen shows that a call is on, not who with.
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    internal companion object {
        const val EXTRA_NAME = "name"
        const val ACTION_HANG_UP = "dev.verdeai.app.LIVE_HANG_UP"
        private const val CHANNEL = "live_call"
        private const val NOTIFICATION_ID = 0x11CE

        fun channel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Live calls", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "A Live voice conversation that continues while you use other apps"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            })
        }
    }
}

/**
 * The app's signals for host connections: a Live call counts as foreground, so the companion's tools
 * and transcript saving keep working while verde is in the background, as a call app's connection does.
 * App lock and push still follow the real foreground.
 */
internal class CallAwareSignals(private val base: AppSignals, scope: CoroutineScope) : AppSignals {
    override val foreground: StateFlow<Boolean> = combine(base.foreground, LiveCalls.active) { front, call -> front || call }
        .stateIn(scope, SharingStarted.Eagerly, base.foreground.value || LiveCalls.active.value)
    override val network get() = base.network
}

package dev.verdeai.app

import android.content.Context
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.verdeai.core.PushNotification
import dev.verdeai.core.SecureStore
import kotlinx.coroutines.*

/** Process-scoped D-14 state: registration, notifications and the action queue. */
internal class PushCenter(context: Context, store: SecureStore, build: PushBuild = PushBuild.current,
                          firebaseReady: Boolean = initFirebase(context, build.firebase)) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val build = build
    val notifier = PushNotifier(context.applicationContext)
    val registrar = PushRegistrar(store, if (firebaseReady) FirebasePushTokens() else null,
        if (firebaseReady) build.relay?.let { PushRelay(it) } else null, scope)
    val actions = NotificationActionQueue()
    /** Set while an Activity's hosts are live, to forward opened pushes as `push_received`. */
    @Volatile var forward: ((PushNotification) -> Unit)? = null
    val receiver = PushReceiver(store, JniPushOpener, notifier::show) { model -> forward?.invoke(model) }

    fun dispatch(action: NotificationAction) = actions.post(action)
}

/**
 * Data-only FCM messages (C-02: `ciphertext`, `collapse_id`, `aps`). The notification is built
 * here even in the background; there is never an FCM `notification` field.
 */
class VerdeMessagingService : FirebaseMessagingService() {
    private val push get() = (application as VerdeApplication).push

    override fun onMessageReceived(message: RemoteMessage) {
        // Runs on FCM's worker thread with a short budget; decrypt and post synchronously.
        runBlocking { withTimeoutOrNull(MESSAGE_BUDGET_MS) { push.receiver.handle(message.data) } }
    }

    override fun onNewToken(token: String) {
        runBlocking { withTimeoutOrNull(TOKEN_BUDGET_MS) { push.registrar.onNewToken(token) } }
    }

    private companion object {
        const val MESSAGE_BUDGET_MS = 8_000L
        const val TOKEN_BUDGET_MS = 15_000L
    }
}

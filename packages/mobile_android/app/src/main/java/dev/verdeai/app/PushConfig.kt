package dev.verdeai.app

import android.content.Context
import com.google.android.gms.tasks.Task
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/*
 * D-14 build inputs. Both are optional: without `VERDE_GOOGLE_SERVICES_JSON` there is no
 * Firebase at all, and without `VERDE_PUSH_RELAY_URL` registration is skipped. Neither case
 * crashes; settings show "Notifications aren't available in this build".
 */

/** The FirebaseOptions fields extracted from google-services.json at build time. */
internal data class FirebaseConfig(val projectId: String, val appId: String, val apiKey: String, val senderId: String) {
    companion object {
        /** Null unless every field is present. */
        fun of(projectId: String, appId: String, apiKey: String, senderId: String): FirebaseConfig? =
            if (listOf(projectId, appId, apiKey, senderId).any { it.isBlank() }) null
            else FirebaseConfig(projectId, appId, apiKey, senderId)
    }
}

internal data class PushBuild(val firebase: FirebaseConfig?, val relay: HttpUrl?) {
    /** Firebase and a relay are both needed to register. */
    val available get() = firebase != null && relay != null

    companion object {
        fun of(firebase: FirebaseConfig?, relayUrl: String): PushBuild = PushBuild(firebase, relayBase(relayUrl))

        /** The compiled-in configuration (app/build.gradle.kts). */
        val current: PushBuild by lazy {
            of(FirebaseConfig.of(BuildConfig.FIREBASE_PROJECT_ID, BuildConfig.FIREBASE_APP_ID,
                BuildConfig.FIREBASE_API_KEY, BuildConfig.FIREBASE_SENDER_ID), BuildConfig.PUSH_RELAY_URL)
        }

        /** HTTPS base URL without query or fragment; anything else disables registration. */
        internal fun relayBase(text: String): HttpUrl? {
            val url = text.trim().trimEnd('/').takeIf { it.isNotEmpty() }?.toHttpUrlOrNull() ?: return null
            return url.takeIf { it.isHttps && it.query == null && it.fragment == null }
        }
    }
}

/**
 * Initializes the default FirebaseApp from build-time options; false (and no Firebase) when this
 * build has none. FirebaseInitProvider is removed in the manifest, so nothing else initializes it.
 */
internal fun initFirebase(context: Context, config: FirebaseConfig?): Boolean {
    config ?: return false
    return try {
        if (FirebaseApp.getApps(context).isEmpty()) {
            FirebaseApp.initializeApp(context, FirebaseOptions.Builder().setProjectId(config.projectId)
                .setApplicationId(config.appId).setApiKey(config.apiKey).setGcmSenderId(config.senderId).build())
        }
        true
    } catch (_: Exception) { false } // Never log options or exception text.
}

/** The FCM registration token. Abstracted so registration logic runs without Firebase in tests. */
internal interface PushTokens {
    suspend fun token(): String
    /** Drops the token so FCM stops delivering; called when notifications are turned off. */
    suspend fun delete()
}

// getToken/deleteToken are the only token APIs firebase-messaging 25.x ships; still supported.
@Suppress("DEPRECATION")
internal class FirebasePushTokens : PushTokens {
    override suspend fun token(): String {
        val messaging = FirebaseMessaging.getInstance()
        // Opting in: auto-init stays on so FCM rotates the token and calls onNewToken.
        messaging.isAutoInitEnabled = true
        return messaging.token.await()
    }
    override suspend fun delete() {
        val messaging = FirebaseMessaging.getInstance()
        messaging.isAutoInitEnabled = false
        messaging.deleteToken().await()
    }
}

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener { task ->
        val error = task.exception
        if (error != null) continuation.resumeWithException(error)
        else if (task.isCanceled) continuation.resumeWithException(java.util.concurrent.CancellationException("task_canceled"))
        else continuation.resume(task.result)
    }
}

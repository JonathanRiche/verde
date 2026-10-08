package dev.verdeai.app

import dev.verdeai.core.CoreJson
import dev.verdeai.core.SecureStore
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** What the registrar may know about one saved host. */
internal enum class HostPushState {
    /** Paired; registration needs the core online (foreground, connected). */
    Paired,
    /** Signed out, unpaired or being wiped: its registration must be retired. */
    Gone,
    /** Still loading, repairing or otherwise undecided: leave it alone for now. */
    Unknown,
}

internal enum class HostRegistration { Registered, Unsupported, Retry }

/** The app's saved hosts, seen through their cores. Attached only while the UI process is live. */
internal interface PushHosts {
    /**
     * Every saved host; a host missing from the map has been removed from this phone.
     * Null while the host catalog is still loading.
     */
    fun states(): Map<String, HostPushState>?
    /** `push_register` on that host's core (key generation, `device.push.register`). */
    suspend fun register(hostId: String, sendToken: String, keySeedBase64: String): HostRegistration
}

/**
 * Persisted at [PushRegistrar.KEY] in the credential store (Keystore-wrapped, no backup). Holds the
 * relay capability and the FCM token; neither is ever logged. `hosts` maps a host id to the
 * fingerprint of the `send_token` it was registered with. `retired` capabilities are deleted from
 * the relay only after every paired host has the current one (README: rotate, update, delete).
 */
@Serializable
internal data class PushRecord(
    val version: Int = 1,
    val enabled: Boolean = false,
    /** The opt-in prompt was shown once; it is never shown again automatically. */
    val asked: Boolean = false,
    val fcm_token: String? = null,
    val send_token: String? = null,
    val hosts: Map<String, String> = emptyMap(),
    /** A host left: mint a fresh capability so the departed host's copy stops working. */
    val rotate: Boolean = false,
    val retired: List<String> = emptyList(),
)

internal enum class PushStatus { Unavailable, Off, Registering, WaitingForHost, On, Error }

internal data class PushUiState(
    val loaded: Boolean = false,
    /** False when this build has no Firebase config or relay URL. */
    val available: Boolean = false,
    val enabled: Boolean = false,
    val asked: Boolean = false,
    val status: PushStatus = PushStatus.Off,
)

/**
 * D-14 registration: FCM token → relay `/v1/register` → `send_token` → `push_register` on every
 * paired host (the core derives and stores the X25519 key from a fresh seed). Process-scoped and
 * serialized; safe to call from the messaging service while no Activity exists.
 */
internal class PushRegistrar(
    private val store: SecureStore,
    private val tokens: PushTokens?,
    private val relay: PushRelay?,
    private val scope: CoroutineScope,
    private val random: SecureRandom = SecureRandom(),
) {
    private val mutex = Mutex()
    private val mutableState = MutableStateFlow(PushUiState(available = tokens != null && relay != null))
    val state: StateFlow<PushUiState> = mutableState.asStateFlow()
    @Volatile private var hosts: PushHosts? = null
    private val requests = Channel<Unit>(Channel.CONFLATED)

    init {
        scope.launch {
            try { publish(load(), null) } catch (e: CancellationException) { throw e } catch (_: Exception) { }
            for (request in requests) try { sync() } catch (e: CancellationException) { throw e } catch (_: Exception) { }
        }
    }

    fun attach(source: PushHosts) { hosts = source; requestSync() }
    fun detach(source: PushHosts) { if (hosts === source) hosts = null }

    /** Coalesced background sync (foreground, pairing changes, token refresh). */
    fun requestSync() { requests.trySend(Unit) }

    suspend fun setEnabled(on: Boolean) {
        mutex.withLock { save(load().copy(enabled = on, asked = true)) }
        sync()
    }

    /** The user dismissed the opt-in prompt. */
    suspend fun markAsked() = mutex.withLock { save(load().copy(asked = true)) }

    /** FirebaseMessagingService.onNewToken: register the new token now, update hosts when online. */
    suspend fun onNewToken(token: String) = sync(token)

    suspend fun sync(knownToken: String? = null) = mutex.withLock {
        var record = try { load() } catch (e: CancellationException) { throw e } catch (_: Exception) {
            mutableState.update { it.copy(status = PushStatus.Error) }
            return@withLock
        }
        if (tokens == null || relay == null) return@withLock publish(record, PushStatus.Unavailable)
        if (!record.enabled) {
            if (record.send_token != null || record.fcm_token != null) {
                record = record.copy(send_token = null, fcm_token = null, hosts = emptyMap(), rotate = false,
                    retired = (record.retired + listOfNotNull(record.send_token)).distinct())
                save(record)
                try { tokens.delete() } catch (e: CancellationException) { throw e } catch (_: Exception) { }
            }
            record = deleteRetired(record)
            return@withLock publish(record, PushStatus.Off)
        }
        val source = hosts
        val states = source?.states()
        if (states != null) {
            // Removed or signed-out hosts: sign-out's device.self.revoke already deleted the host's
            // registration; rotating also cuts off a host whose revoke went unconfirmed.
            val gone = record.hosts.keys.filter { states[it] == null || states[it] == HostPushState.Gone }
            if (gone.isNotEmpty()) record = record.copy(hosts = record.hosts - gone.toSet(), rotate = record.send_token != null)
            if (states.values.none { it == HostPushState.Paired } && states.values.none { it == HostPushState.Unknown }) {
                // Nothing left to notify: drop the capability entirely until a host is paired.
                record = record.copy(send_token = null, hosts = emptyMap(), rotate = false,
                    retired = (record.retired + listOfNotNull(record.send_token)).distinct())
                save(record)
                record = deleteRetired(record)
                return@withLock publish(record, PushStatus.WaitingForHost)
            }
            save(record)
        }
        mutableState.update { it.copy(status = PushStatus.Registering) }
        val token = try { knownToken ?: tokens.token() } catch (e: CancellationException) { throw e } catch (_: Exception) {
            return@withLock publish(record, PushStatus.Error)
        }
        if (record.send_token == null || record.fcm_token != token || record.rotate) {
            val sendToken = try { relay.register(token) } catch (e: CancellationException) { throw e } catch (_: Exception) {
                return@withLock publish(record, PushStatus.Error)
            }
            record = record.copy(fcm_token = token, send_token = sendToken, hosts = emptyMap(), rotate = false,
                retired = (record.retired + listOfNotNull(record.send_token)).distinct())
            save(record)
        }
        val current = record.send_token!!
        val print = fingerprint(current)
        if (source == null || states == null) return@withLock publish(record, PushStatus.On)
        var failed = false
        for ((id, value) in states) {
            if (value != HostPushState.Paired) continue
            if (record.hosts[id]?.endsWith(print) == true) continue
            val seed = ByteArray(32).also(random::nextBytes)
            val encoded = Base64.getEncoder().encodeToString(seed)
            seed.fill(0)
            val result = try { source.register(id, current, encoded) } catch (e: CancellationException) { throw e } catch (_: Exception) { HostRegistration.Retry }
            when (result) {
                HostRegistration.Registered -> record = record.copy(hosts = record.hosts + (id to print))
                HostRegistration.Unsupported -> record = record.copy(hosts = record.hosts + (id to "unsupported:$print"))
                HostRegistration.Retry -> failed = true
            }
            save(record)
        }
        val waiting = states.values.any { it == HostPushState.Unknown }
        if (!failed && !waiting) record = deleteRetired(record)
        val registered = record.hosts.values.any { it == print }
        publish(record, when {
            failed -> PushStatus.Error
            registered -> PushStatus.On
            else -> PushStatus.WaitingForHost
        })
    }

    private suspend fun deleteRetired(record: PushRecord): PushRecord {
        val relay = relay ?: return record
        if (record.retired.isEmpty()) return record
        val kept = record.retired.filter { token -> relay.unregister(token) == RelayDelete.Retry }
        val next = record.copy(retired = kept)
        save(next)
        return next
    }

    private suspend fun load(): PushRecord = store.get(KEY)?.let {
        try { CoreJson.decodeFromString<PushRecord>(it) } catch (_: Exception) { null }
    } ?: PushRecord()

    private suspend fun save(record: PushRecord) = store.put(KEY, CoreJson.encodeToString(record))

    private fun publish(record: PushRecord, status: PushStatus?) {
        mutableState.update {
            it.copy(loaded = true, enabled = record.enabled, asked = record.asked,
                status = status ?: if (!it.available) PushStatus.Unavailable else if (!record.enabled) PushStatus.Off else it.status)
        }
    }

    companion object {
        const val KEY = "android/1/push"
        internal fun fingerprint(sendToken: String): String =
            MessageDigest.getInstance("SHA-256").digest(sendToken.encodeToByteArray()).take(12)
                .joinToString("") { "%02x".format(it) }
    }
}

package dev.verdeai.app

import android.app.Application
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import java.net.URLEncoder
import java.security.SecureRandom
import java.util.UUID

class VerdeApplication : Application() {
    val secureStore by lazy { AndroidSecureStore(this) }
    val viewCache by lazy { AndroidSecureStore(this, "view-cache") }
    internal val signals: AppSignals by lazy { AndroidAppSignals(this) }
    /** Process-scoped so rotation and Activity recreation never relock; gates UI only. */
    internal val appLock by lazy { AppLockModel(secureStore, signals.foreground, { deviceSecure(this) }) }
}

internal data class PairingState(
    val host: HostView? = null,
    val operation: Operation? = null,
    val busy: Boolean = false,
    val notice: String? = null,
    val fatal: Boolean = false,
) {
    val error get() = operation?.error ?: host?.error
    val canEnter get() = !fatal && !busy && host != null && host.lifecycle == Lifecycle.foreground &&
        host.auth_state != "loading" && host.auth_state != "paired" &&
        host.trust_proposal == null && operation?.state != "pending" && error?.domain != "storage"
    val complete get() = host?.auth_state == "paired" && host.trust_proposal == null
}

/** UI state only. The core retains the grant/nonce and decides all retry and trust policy. */
internal class PairingModel(private val createHost: suspend () -> CoreHost) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(PairingState())
    val state = mutableState.asStateFlow()
    // Deliberately not SavedStateHandle/rememberSaveable: pair material dies with the process.
    var link by mutableStateOf("")
    var manualHost by mutableStateOf("")
    var grant by mutableStateOf("")
    var code by mutableStateOf("")
    var deviceLabel by mutableStateOf(Build.MODEL)
    private var pairIntent: String? = null
    // Lifecycle/network events are delivered in call order, after `start`, and deduplicated.
    private val signals = Channel<(Long, Long) -> Event>(Channel.UNLIMITED)
    private var lastForeground: Boolean? = null
    private var lastNetwork: NetworkState? = null
    private val host = scope.async { createHost().also {
        try { it.send { n,w -> EventStart(now_ms=n, wall_time_ms=w, foreground=false, network_available=true) } }
        catch (e: Exception) { it.close(); throw e }
    } }

    init {
        scope.launch {
            try {
                val core = host.await()
                launch { core.hosts.collect { query ->
                    mutableState.update { it.copy(host=query?.data?.items?.firstOrNull(),
                        operation=query?.data?.operations?.find { op -> op.intent_id == pairIntent } ?: it.operation) }
                } }
                launch { core.failed.collect { failed -> if (failed) mutableState.update { it.copy(fatal=true) } } }
                for (signal in signals) {
                    try { core.send(signal) }
                    catch (_: CoreInputRejected) { }
                }
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { mutableState.update { it.copy(fatal=true) } }
        }
    }

    fun receiveLink(value: String) {
        // Receiving an Intent or QR never authorizes exchange or replaces an in-flight grant.
        if (state.value.busy || state.value.operation?.state == "pending" || state.value.complete) {
            notice("Finish the current pairing before opening another link.")
        } else if (value.length > 8192) notice("This pairing link is too long. Create a new link on the host.")
        else { link = value; notice(null) }
    }

    fun pair(manual: Boolean = false) {
        if (!state.value.canEnter) return
        val value = if (manual) manualPairLink(manualHost.trim(), grant.trim(), code.trim()) else link.trim()
        val label = deviceLabel.trim()
        if (value.isEmpty() || label.isEmpty()) { notice("Enter a pairing link and a device label."); return }
        val id = UUID.randomUUID().toString()
        val nonce = ByteArray(16).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) }
        pairIntent = id
        mutableState.update { it.copy(operation=Operation(id, "pending", null)) }
        clearInputs()
        action(pairSubmission=true) { core -> core.send { n,w -> EventPair(now_ms=n, wall_time_ms=w, intent_id=id,
            link=value, device_label=label, client_nonce=nonce) } }
    }

    fun trust(proposalId: String, accept: Boolean) = action { core ->
        core.send { n,w -> EventTrustDecision(now_ms=n, wall_time_ms=w,
            intent_id=UUID.randomUUID().toString(), proposal_id=proposalId, accept=accept) }
    }
    fun retry() = action { core -> core.send { n,w -> EventRetryConnection(now_ms=n,
        wall_time_ms=w, intent_id=UUID.randomUUID().toString()) } }
    fun foreground(active: Boolean) {
        if (lastForeground == active) return
        lastForeground = active
        signals.trySend { n,w -> if (active) EventForeground(now_ms=n, wall_time_ms=w) else EventBackground(now_ms=n, wall_time_ms=w) }
    }
    /** The core invalidates transport on a changed route and reconnects with its jittered backoff. */
    fun network(state: NetworkState) {
        if (lastNetwork == state) return
        lastNetwork = state
        signals.trySend { n,w -> EventNetworkChanged(now_ms=n, wall_time_ms=w, available=state.available, network_id=state.id) }
    }
    fun notice(text: String?) { mutableState.update { it.copy(notice=text) } }
    private fun clearInputs() { link=""; manualHost=""; grant=""; code="" }
    private fun action(pairSubmission: Boolean = false, block: suspend (CoreHost) -> Unit) {
        if (state.value.busy || state.value.fatal) return
        mutableState.update { it.copy(busy=true, notice=null) }
        scope.launch {
            try { block(host.await()) }
            catch (e: CoreInputRejected) {
                if (pairSubmission) mutableState.update { it.copy(operation=null) }
                notice(if (e.status == 1) "Invalid pairing link or device label. Copy a fresh link from Verde."
                    else "The host is not ready for this action. Try again after it finishes loading.")
            } catch (_: Exception) { mutableState.update { it.copy(fatal=true) } }
            finally { mutableState.update { it.copy(busy=false) } }
        }
    }
    internal suspend fun coreHost(): CoreHost = host.await()

    override fun onCleared() = dispose()
    internal fun dispose() {
        clearInputs()
        signals.close()
        // Own cleanup beyond scope cancellation; CoreHost closes its dispatcher/executor.
        scope.launch {
            try { host.await().close() } catch (_: Exception) { }
            finally { scope.cancel() }
        }
    }
}

internal fun manualPairLink(host: String, grant: String, code: String): String {
    fun encode(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    return "verde://pair?host=${encode(host)}&grant_id=${encode(grant)}#code=${encode(code)}"
}

internal fun pairingError(error: LocalError): String = when {
    error.domain == "storage" -> "Could not save or read the secure credential. Unlock your phone and retry."
    error.code == "grant_rejected" -> "This pairing grant has expired, was already used, or was rejected. Create a new pairing link on the host."
    error.code == "auth_rejected" -> "The host rejected authentication. Check its paired-device settings."
    error.code == "network_unavailable" || error.failure_kind == "network" -> "Host unreachable. Is Tailscale on? Check that your phone and host are connected, then retry."
    error.code == "exchange_uncertain" -> "The host may have paired this phone, but no response arrived. Create a new grant; this exchange cannot be safely retried."
    error.code == "trust_denied" -> "Host not trusted. No pairing credential was sent."
    error.code == "tls_rejected" -> "The host's secure connection could not be verified. Check its certificate before trying a new pairing link."
    error.code == "repair_required" -> "This device needs to pair again. Create a new pairing link on the host."
    error.code == "protocol_rejected" -> "This host is not compatible. Update Verde on the host and phone."
    else -> "Pairing could not complete. Check the host and try again."
}

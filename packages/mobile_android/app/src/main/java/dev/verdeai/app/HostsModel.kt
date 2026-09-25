package dev.verdeai.app

import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import java.util.UUID

@Serializable
internal data class SavedHost(val id: String, val label: String)
@Serializable
internal data class HostCatalog(val hosts: List<SavedHost>, val active: String?)
internal data class HostRow(val saved: SavedHost, val view: HostView? = null,
    val operation: Operation? = null, val busy: Boolean = false, val fatal: Boolean = false)
internal data class HostsState(val rows: List<HostRow> = emptyList(), val active: String? = null,
    val loading: Boolean = true, val busy: Boolean = false, val error: String? = null,
    val pairing: String? = null)

/** Owns platform host identities/selection only; every protocol action belongs to its core. */
internal class HostsModel(private val store: SecureStore,
    private val createHost: suspend (SavedHost) -> CoreHost) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(HostsState())
    val state = mutableState.asStateFlow()
    private val sessions = linkedMapOf<String, PairingModel>()
    private val observers = mutableMapOf<String, Job>()
    private val operations = mutableMapOf<String, String>()
    private var catalog = HostCatalog(emptyList(), null)
    private var foreground = false
    private var pendingLink: String? = null
    private var closed = false
    init { load() }

    fun pairing(id: String): PairingModel? = sessions[id]
    // D-05 consumes projections from this handle; runtime data is never merged across hosts.
    suspend fun activeCore(): CoreHost? = state.value.active?.let { sessions[it]?.coreHost() }

    fun load() {
        if (state.value.busy || closed) return
        mutableState.update { it.copy(busy=true, error=null) }
        scope.launch {
            try {
                val saved = store.get(CATALOG_KEY)
                val value = saved?.let { CoreJson.decodeFromString<HostCatalog>(it) }
                    ?: HostCatalog(listOf(SavedHost("primary", "My host")), "primary")
                require(value.hosts.size <= 32 && value.hosts.map { it.id }.distinct().size == value.hosts.size &&
                    value.hosts.all { it.id.matches(Regex("[A-Za-z0-9_-]{1,128}")) && it.label.isNotBlank() } &&
                    (value.active == null || value.hosts.any { it.id == value.active }))
                if (saved == null) persist(value) else catalog=value
                mutableState.update { it.copy(rows=value.hosts.map(::HostRow), active=value.active, loading=false) }
                value.hosts.forEach(::open)
            } catch (_: Exception) {
                mutableState.update { it.copy(error="Could not load saved hosts. Unlock your phone and retry.") }
            } finally {
                mutableState.update { it.copy(busy=false) }
                if (!state.value.loading) pendingLink?.let { pendingLink=null; receiveLink(it) }
            }
        }
    }
    private fun open(saved: SavedHost) {
        if (sessions.containsKey(saved.id)) return
        val pairing = PairingModel { createHost(saved) }
        sessions[saved.id] = pairing
        pairing.foreground(foreground)
        observers[saved.id] = scope.launch {
            launch { pairing.state.collect { value ->
                row(saved.id) { it.copy(view=value.host, fatal=value.fatal) }
            } }
            try { pairing.coreHost().hosts.collect { value ->
                row(saved.id) { it.copy(operation=value?.data?.operations?.find { op -> op.intent_id == operations[saved.id] }) }
            } } catch (_: Exception) { row(saved.id) { it.copy(fatal=true) } }
        }
    }
    private fun row(id: String, change: (HostRow) -> HostRow) {
        mutableState.update { it.copy(rows=it.rows.map { row -> if (row.saved.id == id) change(row) else row }) }
    }
    private suspend fun persist(value: HostCatalog) {
        store.put(CATALOG_KEY, CoreJson.encodeToString(value))
        catalog=value
    }
    private fun catalogAction(block: suspend () -> Unit) {
        if (state.value.busy || state.value.loading || closed) return
        mutableState.update { it.copy(busy=true, error=null) }
        scope.launch {
            try { block() }
            catch (_: Exception) { mutableState.update { it.copy(error="Could not save hosts. Unlock your phone and retry.") } }
            finally { mutableState.update { it.copy(busy=false) } }
        }
    }
    fun select(id: String) = catalogAction {
        if (catalog.hosts.none { it.id == id }) return@catalogAction
        persist(catalog.copy(active=id))
        mutableState.update { it.copy(active=id, pairing=null) }
    }
    fun add(label: String, link: String? = null) = catalogAction {
        if (catalog.hosts.size >= 32) {
            mutableState.update { it.copy(error="Remove a host before adding another (32 host limit).") }
            return@catalogAction
        }
        val saved = SavedHost(UUID.randomUUID().toString(), label.trim().take(128).ifEmpty { "My host" })
        persist(HostCatalog(catalog.hosts + saved, saved.id))
        mutableState.update { it.copy(rows=it.rows + HostRow(saved), active=saved.id, pairing=saved.id) }
        open(saved)
        link?.let { sessions[saved.id]?.receiveLink(it) }
    }
    fun showPairing(id: String?) { mutableState.update { it.copy(pairing=id) } }
    fun receiveLink(link: String) {
        if (state.value.loading) { pendingLink=link; return }
        val id = state.value.pairing ?: state.value.active
        val model = sessions[id]
        if (model != null && !model.state.value.complete) {
            model.receiveLink(link)
            showPairing(id)
        } else add("My host", link)
    }
    fun foreground(active: Boolean) {
        foreground=active
        sessions.values.forEach { it.foreground(active) }
    }
    fun signOut(id: String, forget: Boolean = false) = action(id) { core, intent ->
        core.send { n,w -> if (forget) EventForgetHost(now_ms=n, wall_time_ms=w, intent_id=intent, host_id=id)
            else EventSignOut(now_ms=n, wall_time_ms=w, intent_id=intent, host_id=id) }
    }
    fun retry(id: String) = action(id) { core, intent ->
        core.send { n,w -> EventRetryConnection(now_ms=n, wall_time_ms=w, intent_id=intent) }
    }
    private fun action(id: String, block: suspend (CoreHost, String) -> Unit) {
        val row = state.value.rows.find { it.saved.id == id } ?: return
        if (row.busy || row.operation?.state == "pending" || row.fatal) return
        val session = sessions[id] ?: return
        val intent = UUID.randomUUID().toString()
        operations[id]=intent
        row(id) { it.copy(busy=true, operation=null) }
        scope.launch {
            try { block(session.coreHost(), intent) }
            catch (_: CoreInputRejected) { mutableState.update { it.copy(error="This host is still loading or finishing an action. Try again shortly.") } }
            catch (_: Exception) { row(id) { it.copy(fatal=true) } }
            finally { row(id) { it.copy(busy=false) } }
        }
    }
    /** Catalog removal is allowed only after the core confirms its secure-store deletes. */
    fun remove(id: String) = catalogAction {
        if (state.value.rows.find { it.saved.id == id }?.view?.auth_state != "signed_out") return@catalogAction
        val remaining = catalog.hosts.filterNot { it.id == id }
        val active = if (catalog.active == id) remaining.firstOrNull()?.id else catalog.active
        persist(HostCatalog(remaining, active))
        observers.remove(id)?.cancel()
        sessions.remove(id)?.dispose()
        operations.remove(id)
        mutableState.update { it.copy(rows=it.rows.filterNot { row -> row.saved.id == id }, active=active,
            pairing=it.pairing?.takeUnless { pair -> pair == id }) }
    }
    override fun onCleared() {
        closed=true
        pendingLink=null
        sessions.values.forEach { it.dispose() }
        scope.cancel()
    }
    companion object { const val CATALOG_KEY = "android/1/hosts" }
}

internal fun hostStatus(row: HostRow): String = when {
    row.fatal -> "Connection unavailable — reopen Verde"
    row.view == null || row.view.auth_state == "loading" -> "Loading"
    row.view.auth_state == "signed_out" -> "Signed out"
    row.view.auth_state == "signing_out" -> "Removing local data"
    row.view.auth_state == "repair_required" -> "Pair again — device authorization needs renewal"
    row.view.trust_proposal != null -> "Review host identity"
    row.view.update_required -> "Update required"
    row.view.auth_state == "unpaired" -> "Not paired"
    row.view.phase == "ready" -> "Connected"
    row.view.error?.failure_kind == "network" || row.view.phase == "failed" -> "Unreachable — is Tailscale on?"
    row.view.lifecycle == Lifecycle.background || row.view.phase == "disabled" -> "Offline"
    else -> "Connecting"
}

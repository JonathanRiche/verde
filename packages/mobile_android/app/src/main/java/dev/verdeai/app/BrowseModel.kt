package dev.verdeai.app

import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.Optional
import java.util.UUID

internal data class BrowseState(
    val hostId: String? = null,
    val row: HostRow? = null,
    val home: HomeView? = null,
    val workspaces: WorkspacesView? = null,
    /** Non-null while the warm-start cache is shown instead of this session's live projection. */
    val savedAtMs: Long? = null,
    val refreshing: Boolean = false,
    val networkAvailable: Boolean = true,
    val fatal: Boolean = false,
) {
    val host get() = row?.view
    val hasData get() = home != null || workspaces != null
}

/**
 * Screen state for the selected host only. Projections come from that host's core
 * (`home` / `workspaces` queries); this class never merges hosts or calls the daemon.
 */
internal class BrowseModel(
    private val hosts: HostsModel,
    private val cache: ViewCache? = null,
    private val signals: AppSignals? = null,
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val saveIntervalMs: Long = 5_000,
) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(BrowseState())
    val state = mutableState.asStateFlow()
    private var refreshJob: Job? = null

    init {
        scope.launch {
            hosts.state.map { it.active }.distinctUntilChanged().collectLatest { id -> observe(id) }
        }
        scope.launch {
            hosts.state.collect { value ->
                mutableState.update { it.copy(row=value.rows.find { row -> row.saved.id == it.hostId }) }
            }
        }
        signals?.let { source -> scope.launch {
            source.network.collect { network -> mutableState.update { it.copy(networkAvailable=network.available) } }
        } }
    }

    private suspend fun observe(id: String?) = coroutineScope {
        refreshJob?.cancel()
        mutableState.update { BrowseState(hostId=id, row=hosts.state.value.rows.find { row -> row.saved.id == id },
            networkAvailable=it.networkAvailable) }
        if (id == null) return@coroutineScope
        val saved = cache?.load(id)
        if (saved != null) mutableState.update { it.copy(home=saved.home, workspaces=saved.workspaces, savedAtMs=saved.saved_at_ms) }
        val core = try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (core == null) { mutableState.update { it.copy(fatal=true) }; return@coroutineScope }
        val live = combine(core.hosts, core.home, core.workspaces) { h, home, ws -> Triple(h?.data?.items?.firstOrNull(), home?.data, ws?.data) }
        launch { saveLive(id, live) }
        // The cache stays visible until this session's core has synced once; afterwards the
        // core's own (possibly stale) projection is always at least as new as the cache.
        var synced = false
        live.collect { (view, home, workspaces) ->
            val auth = view?.auth_state
            if (auth in HostsModel.WIPED) {
                mutableState.update { it.copy(home=null, workspaces=null, savedAtMs=null) }
                return@collect
            }
            if (view?.sync_state == "ready") synced = true
            if (synced || mutableState.value.savedAtMs == null) {
                mutableState.update { it.copy(home=home, workspaces=workspaces, savedAtMs=null) }
            }
        }
    }

    private suspend fun saveLive(id: String, live: Flow<Triple<HostView?, HomeView?, WorkspacesView?>>) {
        val store = cache ?: return
        fun paired() = hosts.state.value.rows.find { it.saved.id == id }?.view?.auth_state == "paired"
        // A wipe maps to null so it conflates over any pending save instead of queueing behind it.
        live.mapNotNull { (view, home, workspaces) ->
            when {
                view?.auth_state in HostsModel.WIPED -> Optional.empty()
                view?.auth_state != "paired" || view.sync_state != "ready" || home == null || workspaces == null -> null
                else -> Optional.of(home.copy(loading=false, stale=false, error=null) to workspaces.copy(loading=false, stale=false, error=null))
            }
        }.distinctUntilChanged().conflate().collect { value ->
            val (home, workspaces) = value.orElse(null) ?: return@collect
            store.save(id, CachedViews(saved_at_ms=wallClock(), home=home, workspaces=workspaces)) { paired() }
            delay(saveIntervalMs)
        }
    }

    /**
     * Pull-to-refresh / Retry: `retry_connection` skips any reconnect backoff and, when the
     * connection is ready, re-reads the snapshot and thread catalog.
     */
    fun refresh() {
        if (refreshJob?.isActive == true) return
        val id = state.value.hostId ?: return
        mutableState.update { it.copy(refreshing=true) }
        refreshJob = scope.launch {
            try {
                val core = hosts.core(id) ?: return@launch
                core.send { n,w -> EventRetryConnection(now_ms=n, wall_time_ms=w, intent_id=UUID.randomUUID().toString()) }
                withTimeoutOrNull(REFRESH_TIMEOUT_MS) { core.home.first { it?.data?.loading != true } }
            } catch (e: CancellationException) { throw e }
            catch (_: CoreInputRejected) { }
            catch (_: Exception) { mutableState.update { it.copy(fatal=true) } }
            finally { mutableState.update { it.copy(refreshing=false) } }
        }
    }

    override fun onCleared() { scope.cancel() }

    companion object { const val REFRESH_TIMEOUT_MS = 15_000L }
}

package dev.verdeai.app

import android.util.Log
import dev.verdeai.core.SocketTrace
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** Opt-in via adb setprop log.tag.VerdeConnection INFO; contains no user/host identifiers. */
internal object ConnectionDiagnostics {
    private const val TAG = "VerdeConnection"
    private fun log(value: String) { if (Log.isLoggable(TAG, Log.INFO)) Log.i(TAG, value) }
    fun socket(value: SocketTrace) = log("socket=${value.socket} event=${value.event} age_ms=${value.ageMs} messages=${value.messages} code=${value.code} failure=${value.failure}")
    fun observe(scope: CoroutineScope, signals: AppSignals, browse: BrowseModel) {
        scope.launch { signals.foreground.collect { log("foreground=$it") } }
        scope.launch {
            var previous: NetworkState? = null
            signals.network.collect {
                log("network_available=${it.available} route_changed=${previous != null && previous?.id != it.id}")
                previous = it
            }
        }
        scope.launch {
            browse.state.map { listOf(it.host?.phase == "ready", it.host?.sync_state == "ready",
                it.refreshing, it.savedAtMs != null, browseBanner(it, System.currentTimeMillis())?.busy == true) }
                .distinctUntilChanged().collect {
                    log("ready=${it[0]} synced=${it[1]} refreshing=${it[2]} cached=${it[3]} busy_banner=${it[4]}")
                }
        }
    }
}

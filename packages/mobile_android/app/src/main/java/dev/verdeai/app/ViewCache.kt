package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

/** Last live core projections for one host, shown only until that host's core has synced. */
@Serializable
internal data class CachedViews(val version: Int = 1, val saved_at_ms: Long, val home: HomeView, val workspaces: WorkspacesView)

/**
 * Warm-start cache in its own encrypted, no-backup store. Content (titles, paths) is never
 * logged. Sign-out and removal clear it; unreadable or oversized entries are discarded.
 */
internal class ViewCache(private val store: SecureStore) {
    private val lock = Mutex()
    suspend fun load(hostId: String): CachedViews? = try {
        store.get(key(hostId))?.let { CoreJson.decodeFromString<CachedViews>(it) }?.takeIf { it.version == 1 }
    } catch (e: CancellationException) { throw e } catch (_: Exception) { null }

    /**
     * Returns false when [allowed] no longer holds, the bounded copy is still too large, or the
     * store rejects it. Writes and [clear] are serialized, so a save that races sign-out either
     * observes the wipe in [allowed] or lands before the clear that removes it.
     */
    suspend fun save(hostId: String, views: CachedViews, allowed: () -> Boolean = { true }): Boolean = try {
        val encoded = CoreJson.encodeToString(bounded(views))
        if (encoded.length > MAX_BYTES) false
        else lock.withLock { if (!allowed()) false else { store.put(key(hostId), encoded); true } }
    } catch (e: CancellationException) { throw e } catch (_: Exception) { false }

    suspend fun clear(hostId: String) {
        try { lock.withLock { store.delete(key(hostId)) } } catch (e: CancellationException) { throw e } catch (_: Exception) { }
    }

    private fun bounded(views: CachedViews) = views.copy(
        home = views.home.copy(items = views.home.items.take(MAX_ITEMS)),
        workspaces = views.workspaces.copy(
            items = views.workspaces.items.take(MAX_ITEMS).map { it.copy(panes = it.panes.take(MAX_ITEMS), threads = it.threads.take(MAX_ITEMS)) },
            history = views.workspaces.history.copy(items = views.workspaces.history.items.take(MAX_ITEMS), next_cursor = null)))

    companion object {
        const val MAX_BYTES = 512 * 1024
        const val MAX_ITEMS = 200
        fun key(hostId: String) = "android/1/views/$hostId"
    }
}

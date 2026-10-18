package dev.verdeai.app

import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/** Home/Workspaces over a fake core that serves real K-09 core projections (see fixtures/k09). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35], qualifiers="w411dp-h1500dp")
class BrowseTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private val store = Store()
    private val cacheStore = Store()
    private val cache = ViewCache(cacheStore)
    private val signals = FakeSignals()
    private val cores = CopyOnWriteArrayList<BrowseCore>()
    private val core get() = cores.single()

    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idle(); condition()
    }
    private fun launch() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            val provider=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals, cache) { saved ->
                        val fake=BrowseCore(saved).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake)
                    }
                    else -> BrowseModel(hosts, cache, signals, wallClock={ NOW }, saveIntervalMs=50)
                } as T
            })
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
        }
        compose.setContent {
            VerdeApp(hosts, browse, UiClock(now={ NOW }, ticking=false))
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
    }

    @Test fun signOutClearsCachedAndShownViews() {
        launch()
        await { runBlocking { cache.load("alpha") } != null }
        compose.runOnIdle { hosts.signOut("alpha") }
        await { runBlocking { cache.load("alpha") } == null && !cacheStore.values.containsKey(ViewCache.key("alpha")) }
        await { browse.state.value.home?.items.isNullOrEmpty() }
    }

    @Test fun cacheIsBoundedAndSkipsDisallowedWrites() = runBlocking {
        val views=CachedViews(saved_at_ms=1, home=K09.homeLive.data!!, workspaces=K09.workspacesLive.data!!.let { ws ->
            ws.copy(history=ws.history.copy(next_cursor="cursor"), items=List(ViewCache.MAX_ITEMS + 5) { ws.items.single().copy(workspace_id="w$it") }) })
        assertFalse(cache.save("alpha", views) { false })
        assertNull(cache.load("alpha"))
        assertTrue(cache.save("alpha", views))
        val loaded=cache.load("alpha")!!
        assertEquals(ViewCache.MAX_ITEMS, loaded.workspaces.items.size)
        assertNull(loaded.workspaces.history.next_cursor)
        cacheStore.values[ViewCache.key("alpha")]="{not json"
        assertNull(cache.load("alpha"))
    }

    private object K09 {
        private fun read(name: String) = BrowseTest::class.java.getResource("/fixtures/k09/$name")!!.readText()
        val homeLive: HomeQuery = CoreJson.decodeFromString(read("home-live.json"))
        val workspacesLive: WorkspacesQuery = CoreJson.decodeFromString(read("workspaces-live.json"))
    }

    private class FakeSignals : AppSignals {
        override val foreground=MutableStateFlow(true)
        override val network=MutableStateFlow(NetworkState(true, "net-1"))
    }

    private class Store : SecureStore {
        val values=ConcurrentHashMap<String,String>()
        override suspend fun get(key: String): String? = values[key]
        override suspend fun put(key: String, value: String) { values[key]=value }
        override suspend fun delete(key: String) { values.remove(key) }
    }

    /**
     * Minimal stand-in for the core's host/sync behaviour: syncing and refreshing complete through
     * real `set_timer` → `timer_fired` round-trips, and every batch invalidates hosts/home/workspaces.
     */
    private class BrowseCore(val saved: SavedHost) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        @Volatile var freed=false
        @Volatile var syncDelayMs: Long?=10
        @Volatile var home=K09.homeLive
        @Volatile var workspaces=K09.workspacesLive
        @Volatile private var row=HostView(saved.id,saved.label,null,null,null,"idle",Lifecycle.background,"paired","empty",
            emptyList(),emptyList(),null,null,false,null)
        @Volatile private var synced=false
        @Volatile private var loading=false
        private var network=true
        private var sequence=0
        override fun create(config: ByteArray)=1L
        override fun handle(host: Long, event: ByteArray): ByteArray {
            val decoded=CoreJson.decodeFromString<Event>(event.decodeToString())
            events.add(decoded)
            val effects=mutableListOf<Effect>()
            fun timer(id: String, delay: Long) { effects.add(EffectSetTimer("t${sequence++}","1",id,delay,"test")) }
            fun connect() {
                val delay=syncDelayMs
                if (row.auth_state != "paired" || row.lifecycle != Lifecycle.foreground || !network || delay == null) return
                row=row.copy(phase="connecting", sync_state=if (synced) "stale" else "loading"); timer("sync", delay)
            }
            when (decoded) {
                is EventForeground -> { row=row.copy(lifecycle=Lifecycle.foreground); connect() }
                is EventBackground -> row=row.copy(lifecycle=Lifecycle.background, phase="disabled")
                is EventNetworkChanged -> {
                    network=decoded.available
                    if (network) connect() else row=row.copy(phase="disabled", sync_state=if (synced) "stale" else "empty")
                }
                is EventTimerFired -> when (decoded.timer_id) {
                    "sync" -> if (row.phase == "connecting") { synced=true; row=row.copy(phase="ready", sync_state="ready") }
                    "refresh" -> { loading=false; row=row.copy(sync_state="ready") }
                }
                is EventRetryConnection -> if (row.phase == "ready") { loading=true; row=row.copy(sync_state="loading"); timer("refresh", 150) }
                is EventSignOut -> { synced=false; row=row.copy(auth_state="signed_out", phase="disabled", sync_state="empty") }
                else -> Unit
            }
            effects.add(EffectStateChanged("s${sequence++}","1","1",listOf("hosts","home","workspaces")))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray = when (selector) {
            "home" -> CoreJson.encodeToString(if (synced) home.copy(data=home.data!!.copy(loading=loading))
                else HomeQuery(1,"1",HomeView(emptyList(),row.sync_state == "loading",false,emptyList(),null),null))
            "workspaces" -> CoreJson.encodeToString(if (synced) workspaces.copy(data=workspaces.data!!.copy(loading=loading))
                else WorkspacesQuery(1,"1",WorkspacesView(emptyList(),row.sync_state == "loading",false,null,HistoryView("",emptyList(),null,false,null)),null))
            else -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(row),emptyList()),null))
        }.encodeToByteArray()
        override fun free(host: Long) { freed=true }
    }

    companion object { const val NOW=1_700_000_100_000L }
}

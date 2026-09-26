package dev.verdeai.app

import android.content.ClipboardManager
import android.content.Context
import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
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
    private var setup: (BrowseCore) -> Unit = {}
    private val core get() = cores.single()

    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idle(); condition()
    }
    private fun awaitText(text: String, substring: Boolean = false) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idle()
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    }
    private fun launch(active: Boolean = true) {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), if (active) "alpha" else null))
        compose.runOnUiThread {
            val provider=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals, cache) { saved ->
                        val fake=BrowseCore(saved).also(setup).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake)
                    }
                    else -> BrowseModel(hosts, cache, signals, wallClock={ NOW }, saveIntervalMs=50)
                } as T
            })
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
        }
        compose.setContent { VerdeApp(hosts, browse, UiClock(now={ NOW }, ticking=false)) }
    }
    private fun list() = compose.onNodeWithTag(BROWSE_LIST)
    private fun scrollTo(text: String) { list().performScrollToNode(hasText(text)) }

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
    }

    @Test fun homeShowsAttentionRunningRecentAndWorkspacesWithTimers() {
        launch()
        awaitText("Needs attention")
        compose.onNodeWithText("Studio · Connected", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("Chat · Needs approval · 1:00", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("Terminal · Running", useUnmergedTree=true).assertExists()
        scrollTo("Running")
        compose.onNodeWithText("Chat · Working · 0:55", useUnmergedTree=true).assertExists()
        scrollTo("Recent chats")
        // Subagent threads never surface as top-level recent chats.
        compose.onNodeWithText("Child", useUnmergedTree=true).assertDoesNotExist()
        scrollTo("Fixture workspace")
        // Platform signals reach the core in order: start → network → foreground.
        val kinds=core.events.map { it::class.simpleName }
        assertEquals(listOf("EventStart","EventNetworkChanged","EventForeground"), kinds.take(3))
        assertEquals("net-1", core.events.filterIsInstance<EventNetworkChanged>().single().network_id)
    }

    @Test fun attentionKindShowsAsBadgesOnHomeAndWorkspaceRows() {
        fun tag(q: HomeQuery) = q.copy(data=q.data!!.copy(items=q.data!!.items.map {
            if (it.thread_id == "layout-thread") it.copy(attention_kind="needs_approval") else it }))
        setup={ core ->
            core.home=tag(K09.homeLive)
            core.workspaces=K09.workspacesLive.let { q -> q.copy(data=q.data!!.copy(items=q.data!!.items.map { ws ->
                ws.copy(panes=ws.panes.map { if (it.thread_id == "web-thread-fixture") it.copy(attention=true, attention_kind="unread") else it }) })) }
        }
        launch()
        awaitText("Needs attention")
        compose.onNodeWithText("Needs approval", useUnmergedTree=true).assertExists()
        compose.onNode(hasText("Workspaces") and hasClickAction()).performClick()
        awaitText("1 needs attention")
        compose.onNodeWithText("Fixture workspace").performClick()
        awaitText("Unread")
    }

    @Test fun tappingAChatOpensTheFocusedTranscriptAndBackUnfocuses() {
        launch()
        awaitText("Needs attention")
        compose.onAllNodesWithText("Layout chat")[0].performClick()
        // D-06: the transcript focuses its thread (K-17 attention clears) and loads from the core.
        awaitText("Loading conversation…")
        await { core.events.any { it is EventFocus && it.thread_id == "layout-thread" } }
        compose.onNodeWithContentDescription("Back").performClick()
        awaitText("Needs attention")
        await { core.events.any { it is EventFocus && it.thread_id == null } }
    }

    @Test fun workspacesListDetailAndLongPressMenus() {
        launch()
        awaitText("Needs attention")
        compose.onNode(hasText("Workspaces") and hasClickAction()).performClick()
        awaitText("/tmp/k09-fixture-project", substring=true)
        compose.onNodeWithText("Fixture workspace").performTouchInput { longClick() }
        compose.onNodeWithText("Copy path").performClick()
        val clipboard=ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)
        assertEquals("/tmp/k09-fixture-project", clipboard.primaryClip?.getItemAt(0)?.text?.toString())
        compose.onNodeWithText("Fixture workspace").performClick()
        awaitText("Panes")
        compose.onNodeWithText("Browser · Unavailable", useUnmergedTree=true).assertExists()
        scrollTo("Chats")
        compose.onNodeWithText("Child", useUnmergedTree=true).assertDoesNotExist()
        // The workspace's chats come from the paged catalog, newest first.
        val chats=compose.onAllNodes(hasText("Web chat") or hasText("Layout chat")).fetchSemanticsNodes()
        assertTrue(chats.size >= 4)
        list().performScrollToNode(hasText("htop"))
        compose.onNodeWithText("htop").performTouchInput { longClick() }
        compose.onNodeWithText("Open").performClick()
        awaitText("The terminal view is coming in a later update.")
        compose.onNodeWithContentDescription("Back").performClick()
        awaitText("Panes")
    }

    @Test fun pullToRefreshSendsRetryAndShowsTheRefreshedProjection() {
        setup={ it.afterRefresh=K09.home to K09.workspaces }
        launch()
        awaitText("Needs attention")
        list().performTouchInput { swipeDown(startY=top + 10f, endY=bottom, durationMillis=600) }
        await { core.events.any { it is EventRetryConnection } }
        awaitText("Nothing is running or waiting on you.")
        await { !browse.state.value.refreshing }
        compose.onNodeWithText("Needs attention").assertDoesNotExist()
    }

    @Test fun warmStartShowsCacheUntilLiveSyncThenSavesLiveViews() {
        runBlocking { cache.save("alpha", CachedViews(saved_at_ms=NOW - 3 * 60_000, home=K09.homeLive.data!!, workspaces=K09.workspacesLive.data!!)) }
        setup={ it.syncDelayMs=null; it.home=K09.home; it.workspaces=K09.workspaces }
        launch()
        awaitText("Showing saved data from 3 min ago.", substring=true)
        compose.onNodeWithText("Chat · Needs approval · 1:00", useUnmergedTree=true).assertExists()
        // A route change lets the (fake) core finish its first sync.
        core.syncDelayMs=10
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-2") }
        awaitText("Nothing is running or waiting on you.")
        compose.onNodeWithText("Showing saved data", substring=true).assertDoesNotExist()
        await { runBlocking { cache.load("alpha") }?.home?.items?.isEmpty() == true }
        assertEquals(NOW, runBlocking { cache.load("alpha") }!!.saved_at_ms)
    }

    @Test fun offlineWithoutCacheShowsOfflineAndNoData() {
        signals.network.value=NetworkState(false, "")
        launch()
        awaitText("You're offline.")
        compose.onNodeWithText("No data yet. Pull down to retry when the host is reachable.").assertExists()
        assertEquals(false, core.events.filterIsInstance<EventNetworkChanged>().single().available)
    }

    @Test fun backgroundAndNetworkChangesReachTheCoreAndForegroundRecovers() {
        launch()
        awaitText("Needs attention")
        compose.runOnIdle { signals.foreground.value=false }
        await { core.events.any { it is EventBackground } }
        compose.runOnIdle { signals.foreground.value=false; signals.network.value=NetworkState(true, "net-1") }
        compose.runOnIdle { signals.foreground.value=true }
        await { core.events.count { it is EventForeground } == 2 }
        await { browse.state.value.host?.phase == "ready" }
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-3") }
        await { core.events.any { it is EventNetworkChanged && it.network_id == "net-3" } }
        // Unchanged values are deduplicated before reaching the core.
        assertEquals(1, core.events.count { it is EventBackground })
        assertEquals(2, core.events.count { it is EventForeground })
        awaitText("Needs attention")
    }

    @Test fun signOutClearsCachedAndShownViews() {
        launch()
        awaitText("Needs attention")
        await { runBlocking { cache.load("alpha") } != null }
        compose.runOnIdle { hosts.signOut("alpha") }
        await { runBlocking { cache.load("alpha") } == null && !cacheStore.values.containsKey(ViewCache.key("alpha")) }
        awaitText("This phone isn't paired with Studio yet.")
        compose.onNodeWithText("Needs attention").assertDoesNotExist()
        compose.onNodeWithText("Pair with this host").assertExists()
    }

    @Test fun withoutActiveHostTheAppStartsOnHosts() {
        launch(active=false)
        awaitText("Hosts")
        compose.onNodeWithText("Use Studio").performScrollTo().performClick()
        awaitText("Needs attention")
    }

    @Test fun bannerAndLabelRules() {
        val row=HostRow(SavedHost("a","Studio"), HostView("a","Studio",null,null,null,"ready",Lifecycle.foreground,"paired","ready",
            emptyList(),emptyList(),null,null,false,null))
        val ready=BrowseState("a", row, K09.home.data, K09.workspaces.data)
        assertNull(browseBanner(ready, NOW))
        assertEquals("You're offline. Showing saved data from 5 min ago.",
            browseBanner(ready.copy(networkAvailable=false, savedAtMs=NOW - 5 * 60_000), NOW)!!.text)
        val unreachable=ready.copy(row=row.copy(view=row.view!!.copy(phase="failed", error=LocalError(domain="net",code="x",message="",failure_kind="network"))))
        assertEquals(BannerAction.Retry, browseBanner(unreachable, NOW)!!.action)
        assertEquals(BannerAction.Hosts, browseBanner(ready.copy(row=row.copy(view=row.view.copy(auth_state="repair_required"))), NOW)!!.action)
        val failed=ready.copy(home=ready.home!!.copy(error=LocalError(domain="rpc",code="x",message="",retryable=true)))
        assertTrue(browseBanner(failed, NOW)!!.text.startsWith("Couldn't load"))
        assertFalse(hasContent(ready.copy(row=row.copy(view=row.view.copy(sync_state="loading")))))
        assertTrue(showSpinner(ready.copy(row=row.copy(view=row.view.copy(sync_state="loading")))))
        assertEquals("1:01:05", elapsedLabel(0, 3_665_000))
        assertEquals("0:00", elapsedLabel(10, 0))
        assertEquals("2 h ago", agoLabel(0, 2 * 3_600_000 + 5))
        assertEquals(listOf("Web chat","Layout chat"), recentThreads(K09.workspaces.data).map { it.title })
        assertEquals("Needs approval", statusLabel("waiting_approval"))
        assertEquals("Unread", attentionLabel("unread"))
        assertNull(attentionLabel(null))
        assertFalse(openable(K09.workspaces.data!!.items.single().panes.single { it.kind == "browser" }))
        assertFalse(openable(K09.workspaces.data!!.items.single().panes.single { it.kind == "terminal" }))
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
        val home: HomeQuery = CoreJson.decodeFromString(read("home.json"))
        val workspaces: WorkspacesQuery = CoreJson.decodeFromString(read("workspaces.json"))
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
        @Volatile var afterRefresh: Pair<HomeQuery, WorkspacesQuery>?=null
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
                    "refresh" -> { loading=false; afterRefresh?.let { (h, w) -> home=h; workspaces=w } }
                }
                is EventRetryConnection -> if (row.phase == "ready") { loading=true; timer("refresh", 30) }
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

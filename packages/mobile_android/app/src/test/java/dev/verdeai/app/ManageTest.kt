package dev.verdeai.app

import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
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
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/** D-10 history, new chat and workspace management through the app shell over a fake core. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35], qualifiers="w411dp-h1500dp")
class ManageTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private val store = Store()
    private val signals = FakeSignals()
    private val cores = CopyOnWriteArrayList<ManageCore>()
    private var setup: (ManageCore) -> Unit = {}
    private val core get() = cores.single()

    private fun pump() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) { pump(); condition() }
    private fun exists(text: String, substring: Boolean = false) =
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    private fun awaitText(text: String, substring: Boolean = false) = await { exists(text, substring) }
    private fun click(text: String) = compose.onNode(hasText(text) and hasClickAction()).performClick()
    private fun list() = compose.onNodeWithTag(MANAGE_LIST)
    private fun tab(label: String) {
        compose.onNodeWithContentDescription("Open workspace drawer").performClick()
        compose.onNode(hasText(label) and hasClickAction() and hasAnyAncestor(hasTestTag(MANAGE_LIST)).not()
        and hasAnyAncestor(hasTestTag(BROWSE_LIST)).not()).performClick()
    }
    private inline fun <reified T : Event> sent() = core.events.filterIsInstance<T>()

    private fun launch() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            val provider=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals) { saved ->
                        val fake=ManageCore(saved).also(setup).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake)
                    }
                    else -> BrowseModel(hosts, null, signals, wallClock={ NOW })
                } as T
            })
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
        }
        compose.setContent { VerdeApp(hosts, browse, UiClock(now={ NOW }, ticking=false)) }
        awaitText("Studio · Connected", substring=true)
    }

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
        FocusClaim.owner=null
    }

    @Test fun drawerRenameAndCloseConfirmExactlyOneIntent() {
        setup={ it.contextThread=true }
        launch()
        compose.onNodeWithContentDescription("Open workspace drawer").performClick()
        compose.onNode(hasText("Alpha plan") and hasAnyAncestor(hasTestTag("workspace-drawer"))).performTouchInput { longClick() }
        click("Rename chat")
        compose.onNodeWithTag("thread-rename-title").performTextReplacement("Renamed on phone")
        click("Rename chat")
        await { sent<EventThreadRename>().size == 1 }
        val rename=sent<EventThreadRename>().single()
        assertEquals("ws-one", rename.workspace_id)
        assertEquals("t1", rename.thread_id)
        assertEquals("Renamed on phone", rename.title)
        await { !exists("Chat title") }
        compose.onNodeWithContentDescription("Open workspace drawer").performClick()
        compose.onNode(hasText("Alpha plan") and hasAnyAncestor(hasTestTag("workspace-drawer"))).performTouchInput { longClick() }
        click("Close chat")
        assertTrue(sent<EventThreadClose>().isEmpty())
        click("Cancel")
        assertTrue(sent<EventThreadClose>().isEmpty())
        compose.onNodeWithContentDescription("Open workspace drawer").performClick()
        compose.onNode(hasText("Alpha plan") and hasAnyAncestor(hasTestTag("workspace-drawer"))).performTouchInput { longClick() }
        click("Close chat")
        click("Close chat")
        await { sent<EventThreadClose>().size == 1 }
        assertEquals("t1", sent<EventThreadClose>().single().thread_id)
    }

    @Test fun historyGroupsPagesSearchesFiltersAndResetsOnLeave() {
        launch()
        awaitText("All chats")
        click("All chats")
        await { compose.onAllNodesWithTag(HISTORY_SEARCH).fetchSemanticsNodes().isNotEmpty() }
        awaitText("Alpha plan")
        compose.onNodeWithText("TODAY").assertExists()
        // Reaching the end loads exactly one more page per cursor.
        list().performScrollToNode(hasText("Gamma notes"))
        compose.onNodeWithText("OLDER").assertExists()
        assertEquals(1, sent<EventHistoryLoadMore>().size)
        compose.onNodeWithText("Load more").assertDoesNotExist()
        // Subagent threads are never listed.
        assertFalse(exists("Subagent run"))

        compose.onNodeWithTag(HISTORY_SEARCH).performTextInput("beta")
        compose.mainClock.advanceTimeBy(SEARCH_DEBOUNCE_MS + 50)
        await { sent<EventHistorySearch>().any { it.query == "beta" } }
        val search=sent<EventHistorySearch>().single()
        assertNull(search.workspace_id)
        awaitText("Beta review")
        assertFalse(exists("Alpha plan"))

        compose.onNode(hasText("Old") and hasClickAction()).performClick()
        await { sent<EventHistorySearch>().any { it.workspace_id == "ws-old" } }
        assertEquals("beta", sent<EventHistorySearch>().last().query)
        awaitText("No chats match.")

        compose.onNodeWithContentDescription("Back").performClick()
        await { sent<EventHistorySearch>().last().let { it.query == "" && it.workspace_id == null } }
        awaitText("Alpha plan")
    }

    @Test fun newChatSelectsProviderAndModelThenOpensTheTranscript() {
        launch()
        click("New chat")
        await { sent<EventNewChatSelect>().isNotEmpty() }
        assertEquals("ws-one", sent<EventNewChatSelect>().single().workspace_id)
        assertNull(sent<EventNewChatSelect>().single().provider)
        // The core picks the workspace's provider.
        awaitText("Claude")
        compose.onNodeWithTag("picker:Provider").performClick()
        compose.onNodeWithText("Codex").performClick()
        await { sent<EventNewChatSelect>().last().provider == "codex" }
        assertNull(sent<EventNewChatSelect>().last().model)
        compose.onNodeWithTag("picker:Model").performClick()
        compose.onNodeWithText("GPT Two").performClick()
        await { sent<EventNewChatSelect>().last().model == "gpt-2" }
        assertEquals("codex", sent<EventNewChatSelect>().last().provider)
        awaitText("GPT Two")

        click("Start chat")
        await { sent<EventThreadCreate>().isNotEmpty() }
        val create=sent<EventThreadCreate>().single()
        assertEquals("ws-one", create.workspace_id); assertEquals("codex", create.provider); assertEquals("gpt-2", create.model)
        // The created thread opens in D-06's transcript, which focuses it.
        await { sent<EventFocus>().any { it.workspace_id == "ws-one" && it.thread_id == "web-thread-1" } }
        // Back skips the finished form.
        compose.onNodeWithContentDescription("Back").performClick()
        awaitText("RECENT CHATS")
    }

    @Test fun newChatShowsCreateFailures() {
        setup={ it.createFailure="invalid_selection" }
        launch()
        click("New chat")
        awaitText("Claude")
        click("Start chat")
        awaitText("That model setting is not available.")
        assertTrue(sent<EventFocus>().none { it.thread_id != null })
    }

    @Test fun addWorkspaceBrowsesFoldersAndOpensTheNewWorkspace() {
        launch()
        tab("Workspaces")
        click("Add workspace")
        await { sent<EventDirectoryList>().isNotEmpty() }
        assertNull(sent<EventDirectoryList>().single().path)
        awaitText("src")
        click("src")
        await { sent<EventDirectoryList>().last().path == "/home/u/src" }
        awaitText("verde")
        awaitText("/home/u/src")
        click("Use this folder")
        compose.onNodeWithTag(WORKSPACE_PATH).assert(hasText("/home/u/src"))
        click("verde")
        await { sent<EventDirectoryList>().last().path == "/home/u/src/verde" }
        awaitText("/home/u/src/verde")
        click("Use this folder")
        compose.onNodeWithTag(WORKSPACE_LABEL).performTextInput("Verde app")
        compose.onNode(hasText("Add workspace") and hasClickAction()).performClick()
        await { sent<EventWorkspaceCreate>().isNotEmpty() }
        val create=sent<EventWorkspaceCreate>().single()
        assertEquals("/home/u/src/verde", create.path); assertEquals("Verde app", create.label)
        // The new workspace opens in place of the form.
        awaitText("/home/u/src/verde")
        compose.onNodeWithText("Verde app").assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        awaitText("CLOSED")
    }

    @Test fun unsupportedDaemonStillAcceptsATypedPath() {
        setup={ it.directorySupported=false }
        launch()
        tab("Workspaces")
        click("Add workspace")
        awaitText("Update Verde on the computer to browse folders. You can still type a path.")
        assertTrue(sent<EventDirectoryList>().isEmpty())
        compose.onNodeWithTag(WORKSPACE_PATH).performTextInput("/srv/app")
        compose.onNode(hasText("Add workspace") and hasClickAction()).performClick()
        await { sent<EventWorkspaceCreate>().singleOrNull()?.path == "/srv/app" }
    }

    @Test fun closeShowsBusyCountsThenClosesReopensAndRenames() {
        setup={ it.busy=ManageBusy(2, 1) }
        launch()
        tab("Workspaces")
        awaitText("One")
        compose.onNode(hasText("One") and hasClickAction()).performClick()
        awaitText("/home/u/one")
        click("Close")
        click("Close workspace")
        awaitText("Stop 2 running requests and 1 background task first.")
        assertEquals("ws-one", sent<EventWorkspaceClose>().single().workspace_id)

        core.busy=null
        click("Close")
        click("Close workspace")
        awaitText("Reopen")
        assertEquals(2, sent<EventWorkspaceClose>().size)
        assertFalse(exists("Stop 2 running", substring=true))

        click("Reopen")
        await { sent<EventWorkspaceArchive>().singleOrNull()?.archived == false }
        awaitText("Close")

        click("Rename")
        compose.onNodeWithTag(RENAME_FIELD).performTextClearance()
        compose.onNodeWithTag(RENAME_FIELD).performTextInput("  Renamed ")
        click("Save")
        await { sent<EventWorkspaceRename>().isNotEmpty() }
        assertEquals("Renamed", sent<EventWorkspaceRename>().single().label)
        awaitText("Renamed")
    }

    @Test fun presentationRules() {
        assertEquals("Stop 1 running request first.", busyMessage(ManageBusy(1, 0)))
        assertEquals("Stop 3 running background tasks first.", busyMessage(ManageBusy(0, 3)))
        assertEquals("Stop 2 running requests and 1 background task first.", busyMessage(ManageBusy(2, 1)))
        assertEquals("Stop this workspace's running requests and tasks first.", busyMessage(null))
        val sections=historySections(listOf(thread("a","Today"), thread("b","Today"), thread("subagent:x","Today"), thread("c","Older")))
        assertEquals(listOf("Today" to listOf("a","b"), "Older" to listOf("c")), sections.map { (k, v) -> k to v.map { it.thread_id } })
        val job=ManageJob("i1","workspace_close","failed","ws",null,ManageBusy(0,1),LocalError(code="workspace_busy",message=""))
        val state=ManageState(view=ManageView(listOf(job), ManageDirectory(), ManageNewChat(selection=ChatSelection(), catalogs=ChatCatalogs()), true, true),
            refused=setOf("i2"))
        assertEquals(JobOutcome.Failed("Stop 1 running background task first."), outcome(state, "i1"))
        assertTrue(outcome(state, "i2") is JobOutcome.Failed)
        assertEquals(JobOutcome.Pending, outcome(state, "i3"))
        assertEquals(JobOutcome.Idle, outcome(state, null))
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
     * Host/sync as in TranscriptTest plus the D-10 intents. Management results land synchronously,
     * which is enough to drive the UI's job tracking; the core engine itself is covered by
     * manage_test.zig.
     */
    private class ManageCore(val saved: SavedHost) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        @Volatile var freed=false
        @Volatile var busy: ManageBusy?=null
        @Volatile var createFailure: String?=null
        @Volatile var directorySupported=true
        @Volatile var contextThread=false
        private var row=HostView(saved.id,saved.label,null,null,null,"idle",Lifecycle.background,"paired","empty",
            emptyList(),listOf("chat:read","chat:write","repository:read","repository:write"),null,null,false,null)
        private var network=true
        private var sequence=0
        private val workspaces=mutableListOf(
            Workspace("ws-one","One","/home/u/one",true,emptyList(),emptyList()),
            Workspace("ws-old","Old","/srv/old",false,emptyList(),emptyList()))
        private val allHistory=listOf(
            thread("t1","Today","ws-one","Alpha plan"), thread("t2","Today","ws-one","Beta review"),
            thread("subagent:t9","Today","ws-one","Subagent run"), thread("t3","Older","ws-old","Gamma notes"))
        private var query=""
        private var filter: String?=null
        private var pages=1
        private val jobs=mutableListOf<ManageJob>()
        private var directory=ManageDirectory()
        private var chat=ManageNewChat(selection=ChatSelection(), catalogs=ChatCatalogs())
        private var threads=0
        private var focused: String?=null

        override fun create(config: ByteArray)=1L
        override fun handle(host: Long, event: ByteArray): ByteArray {
            val decoded=CoreJson.decodeFromString<Event>(event.decodeToString())
            events.add(decoded)
            val effects=mutableListOf<Effect>()
            fun connect() {
                if (row.lifecycle != Lifecycle.foreground || !network) return
                row=row.copy(phase="connecting", sync_state="loading")
                effects.add(EffectSetTimer("t${sequence++}","1","sync",10,"test"))
            }
            fun job(kind: String, id: String, ws: String?, thread: String?=null, code: String?=null, message: String="", busy: ManageBusy?=null) {
                jobs+=ManageJob(id, kind, if (code == null) "succeeded" else "failed", ws, thread, busy, code?.let { LocalError(code=it, message=message) })
            }
            fun ws(id: String, change: (Workspace) -> Workspace) { val i=workspaces.indexOfFirst { it.workspace_id == id }; workspaces[i]=change(workspaces[i]) }
            when (decoded) {
                is EventForeground -> { row=row.copy(lifecycle=Lifecycle.foreground); connect() }
                is EventNetworkChanged -> {
                    val was=network
                    network=decoded.available
                    if (!network) row=row.copy(phase="disabled") else if (!was || row.phase != "ready") connect()
                }
                is EventTimerFired -> if (decoded.timer_id == "sync" && row.phase == "connecting") row=row.copy(phase="ready", sync_state="ready")
                is EventHistorySearch -> { query=decoded.query; filter=decoded.workspace_id; pages=1 }
                is EventHistoryLoadMore -> pages=2
                is EventFocus -> focused=decoded.thread_id
                is EventNewChatSelect -> {
                    val provider=decoded.provider ?: "claude"
                    val models=if (provider == "codex") listOf(ChatChoice("gpt-1","GPT One"), ChatChoice("gpt-2","GPT Two"))
                        else listOf(ChatChoice("sonnet","Sonnet"))
                    chat=chat.copy(workspace_id=decoded.workspace_id, selection=ChatSelection(provider, decoded.model),
                        providers=listOf(ChatChoice("codex","Codex"), ChatChoice("claude","Claude")),
                        catalogs=ChatCatalogs(models=models), can_create=true)
                }
                is EventThreadCreate -> if (createFailure != null) job("thread_create", decoded.intent_id, decoded.workspace_id, code=createFailure,
                    message="That model setting is not available.")
                    else job("thread_create", decoded.intent_id, decoded.workspace_id, "web-thread-${++threads}")
                is EventThreadRename -> job("thread_rename", decoded.intent_id, decoded.workspace_id, decoded.thread_id)
                is EventThreadClose -> job("thread_close", decoded.intent_id, decoded.workspace_id, decoded.thread_id)
                is EventThreadSync -> job("thread_sync", decoded.intent_id, decoded.workspace_id, decoded.thread_id)
                is EventWorkspaceCreate -> {
                    val id="ws-new"
                    workspaces+=Workspace(id, decoded.label ?: decoded.path.substringAfterLast('/'), decoded.path, true, emptyList(), emptyList())
                    job("workspace_create", decoded.intent_id, id)
                }
                is EventWorkspaceClose -> {
                    val refused=busy
                    if (refused != null) job("workspace_close", decoded.intent_id, decoded.workspace_id, code="workspace_busy", busy=refused)
                    else { ws(decoded.workspace_id) { it.copy(open=false) }; job("workspace_close", decoded.intent_id, decoded.workspace_id) }
                }
                is EventWorkspaceArchive -> { ws(decoded.workspace_id) { it.copy(open=!decoded.archived) }; job("workspace_archive", decoded.intent_id, decoded.workspace_id) }
                is EventWorkspaceRename -> { ws(decoded.workspace_id) { it.copy(label=decoded.label) }; job("workspace_rename", decoded.intent_id, decoded.workspace_id) }
                is EventDirectoryList -> {
                    val path=decoded.path ?: "/home/u"
                    val children=when (path) { "/home/u" -> listOf("src"); "/home/u/src" -> listOf("verde", "other"); else -> emptyList() }
                    directory=directory.copy(path=path, parent=path.substringBeforeLast('/').ifEmpty { null }.takeIf { path != "/home/u" },
                        entries=children.map { ManageDirectoryEntry(it, "$path/$it") })
                }
                else -> Unit
            }
            val scopes=mutableListOf("hosts","home","workspaces","manage")
            effects.add(EffectStateChanged("s${sequence++}","1","1",scopes))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }

        private fun history(): HistoryView {
            val matching=allHistory.filter { (query.isEmpty() || it.title.contains(query, ignoreCase=true)) && (filter == null || it.workspace_id == filter) }
            val page=if (pages == 1 && query.isEmpty() && filter == null) matching.take(3) else matching
            return HistoryView(query, page, if (page.size < matching.size) "cursor-1" else null, false, null)
        }

        override fun query(host: Long, selector: String): ByteArray = when (selector) {
            "hosts" -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(row),emptyList()),null))
            "home" -> CoreJson.encodeToString(HomeQuery(1,"1",HomeView(emptyList(),false,false,emptyList(),null),null))
            "workspaces" -> CoreJson.encodeToString(WorkspacesQuery(1,"1",WorkspacesView(workspaces.map { ws ->
                ws.copy(threads=allHistory.filter { it.workspace_id == ws.workspace_id },
                    panes=if (contextThread && ws.workspace_id == "ws-one") listOf(Pane("p1", "ws-one", "chat", "Alpha plan", thread_id="t1")) else ws.panes) }, false, false, null, history()),null))
            "manage" -> {
                val ready=row.phase == "ready"
                CoreJson.encodeToString(ManageQuery(1,"1",ManageView(jobs.toList(), directory.copy(supported=directorySupported,
                    suggestions=listOf("/home/u")), chat.copy(can_create=chat.can_create && ready), ready, ready),null))
            }
            else -> """{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":"Unknown thread."}}"""
        }.encodeToByteArray()
        override fun free(host: Long) { freed=true }
    }

    companion object {
        const val NOW=1_790_000_000_000L
        fun thread(id: String, bucket: String, ws: String="ws", title: String=id) =
            ThreadSummary(ws, id, title, "codex", null, null, true, false, NOW - 60_000, "idle", bucket)
    }
}

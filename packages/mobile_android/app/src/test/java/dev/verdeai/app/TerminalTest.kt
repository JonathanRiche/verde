package dev.verdeai.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.activity.ComponentActivity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.time.Duration
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Terminal screen over a fake core that follows the K-12 pump contract (attach → reset
 * `terminal_output` → `terminal_applied`) with the recorded K-12 tail bytes, and a fake VT
 * that serves the committed real-VT snapshot (fixtures/k12). The JNI path is covered by
 * `TerminalJniTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35], qualifiers="w411dp-h800dp")
class TerminalTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val models = ViewModelStore()
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private val store = Store()
    private val signals = FakeSignals()
    private val cores = CopyOnWriteArrayList<TermCore>()
    private val vt = FakeVt()
    private var scopes = listOf("terminal:read", "terminal:write")
    private val core get() = cores.single()

    // Advances the paused main looper so debounced work (resize) can run.
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20)); condition()
    }
    private fun awaitText(text: String, substring: Boolean = false) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idle()
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    }
    private inline fun <reified T : Event> events() = core.events.filterIsInstance<T>()
    private fun inputs() = events<EventTerminalInput>().map { it.input }

    private fun launch() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            val provider=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals, null) { saved ->
                        val fake=TermCore(saved, scopes).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake, vt)
                    }
                    else -> BrowseModel(hosts, null, signals, wallClock={ NOW })
                } as T
            })
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
        }
        compose.setContent { VerdeApp(hosts, browse, UiClock(now={ NOW }, ticking=false)) }
    }

    private fun openWorkspace() {
        awaitText("NEEDS ATTENTION")
        compose.onNodeWithContentDescription("Open workspace drawer").performClick()
        compose.onNode(hasText("Workspaces") and hasClickAction()).performClick()
        awaitText("Fixture workspace")
        compose.onNodeWithText("Fixture workspace").performClick()
        awaitText("PANES")
    }

    private fun openHtop(inWorkspace: Boolean = false) {
        if (!inWorkspace) openWorkspace()
        compose.onNodeWithTag(BROWSE_LIST).performScrollToNode(hasText("htop"))
        compose.onNodeWithText("htop").performClick()
        await { events<EventTerminalApplied>().any { it.terminal_id == "sess-7" } }
    }

    private fun inputView(): TerminalInputView {
        fun find(view: View): TerminalInputView? = view as? TerminalInputView
            ?: (view as? ViewGroup)?.let { group -> (0 until group.childCount).firstNotNullOfOrNull { find(group.getChildAt(it)) } }
        return find(compose.activity.window.decorView)!!
    }

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
    }

    @Test fun attachReplaysTheK12TailRendersAndTypesThroughTheCore() {
        vt.reply="\u001b[3;1R"
        launch()
        openHtop()
        val applied=events<EventTerminalApplied>().first()
        assertNull(applied.error)
        assertEquals("1", applied.grid_revision)
        // The first reset recreates the VT at the core's grid, then writes the recorded bytes once.
        assertEquals(TerminalConfig(cols=20, rows=4, scrollback_rows=TerminalVt.DEFAULT_SCROLLBACK_ROWS), vt.configs.first())
        assertEquals(tail(), vt.writes.first())
        // Device replies go back through terminal_reply.
        await { events<EventTerminalReply>().isNotEmpty() }
        assertEquals("\u001b[3;1R", Base64.getDecoder().decode(events<EventTerminalReply>().single().bytes_base64).decodeToString())
        compose.onNodeWithTag("terminal-canvas").assertExists()
        compose.onNodeWithTag("terminal-notice").assertDoesNotExist()
        compose.onNodeWithText("htop", useUnmergedTree=true).assertExists()

        // The measured canvas drives session.resize, and the VT follows the core's size.
        await { events<EventTerminalResize>().isNotEmpty() }
        val resize=events<EventTerminalResize>().single()
        assertTrue(resize.cols > 20 && resize.rows > 4)
        await { vt.resizes.contains(resize.cols to resize.rows) }

        compose.onNodeWithContentDescription("Escape").performClick()
        compose.onNodeWithContentDescription("Up").performClick()
        compose.onNodeWithTag("terminal-keys").performScrollToNode(hasContentDescription("Pipe"))
        compose.onNodeWithContentDescription("Pipe").performClick()
        await { inputs().size == 3 }
        assertEquals(listOf(key("Escape"), key("ArrowUp"), text("|")), inputs())
        // DECCKM from the replayed stream reaches the core's key encoding.
        assertTrue(events<EventTerminalInput>().all { it.vt_modes.application_cursor && it.vt_modes.bracketed_paste })

        val connection=compose.runOnIdle { inputView().onCreateInputConnection(EditorInfo()) }
        compose.runOnIdle { connection.commitText("ls\n", 1) }
        compose.onNodeWithTag("terminal-keys").performScrollToNode(hasText("Ctrl"))
        compose.onNodeWithText("Ctrl").performClick()
        compose.runOnIdle { connection.commitText("c", 1); connection.deleteSurroundingText(1, 0) }
        compose.runOnIdle {
            inputView().dispatchKeyEvent(KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_D, 0, KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON))
            inputView().dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_LEFT))
        }
        await { inputs().size == 9 }
        assertEquals(listOf(text("ls"), key("Enter"), key("c", ctrl=true), key("Backspace"), key("d", ctrl=true), key("ArrowLeft")), inputs().drop(3))

        val clipboard=ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText("", "echo hi"))
        compose.onNodeWithTag("terminal-keys").performScrollToNode(hasText("Paste"))
        compose.onNodeWithText("Paste").performClick()
        await { inputs().size == 10 }
        assertEquals(EventTerminalInputInput(EventTerminalInputInputKind.paste, text="echo hi", ctrl=false, alt=false, shift=false), inputs().last())

        // Focus goes through the shared FocusClaim: claimed on open, released on leave.
        val focus=events<EventFocus>().single()
        assertEquals(listOf("fixture-ws", null, "sess-7"), listOf(focus.workspace_id, focus.thread_id, focus.terminal_id))
        compose.onNodeWithContentDescription("Back").performClick()
        await { events<EventTerminalDetach>().any { it.terminal_id == "sess-7" } }
        await { vt.freed.isNotEmpty() }
        awaitText("PANES")
        await { events<EventFocus>().size == 2 }
        assertEquals(listOf(null, null, null), events<EventFocus>().last().let { listOf(it.workspace_id, it.thread_id, it.terminal_id) })
        assertNull(FocusClaim.owner)
    }

    @Test fun scrollbackSelectionCopiesSensitiveTextAndReturnsToLive() {
        launch()
        openHtop()
        val canvas=compose.onNodeWithTag("terminal-canvas")
        // Dragging down pages into older rows; the "Latest" button snaps back.
        canvas.performTouchInput { down(Offset(100f, 10f)); moveBy(Offset(0f, 60f)); moveBy(Offset(0f, 60f)); up() }
        await { vt.scrolls.sum() > 0 }
        awaitText("Latest")
        compose.onNodeWithText("Latest").performClick()
        await { vt.scrolls.sum() == 0 }
        // Long-press selects from the first cell to the end of row two.
        canvas.performTouchInput { down(Offset(1f, 1f)); advanceEventTime(1_000); moveTo(Offset(width - 1f, 25f)); up() }
        awaitText("Copy")
        compose.onNodeWithText("Copy").performClick()
        val clipboard=ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)
        await { clipboard.primaryClip != null }
        assertEquals("RED\nwide: 界 e\u0301", clipboard.primaryClip!!.getItemAt(0).text.toString())
        assertTrue(clipboard.primaryClip!!.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        compose.onNodeWithText("Copy").assertDoesNotExist()
    }

    @Test fun offlinePausesInputAndReconnectReplayShowsTheGapNotice() {
        launch()
        openHtop()
        compose.runOnIdle { signals.network.value=NetworkState(false, "") }
        awaitText("You're offline. Showing the last screen; input is paused.")
        compose.onNodeWithContentDescription("Escape").assertIsNotEnabled()
        // The last screen stays up while offline.
        compose.onNodeWithTag("terminal-canvas").assertExists()
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-2") }
        await { events<EventTerminalApplied>().size == 2 }
        awaitText("Reconnected. Some earlier output may be missing.")
        assertEquals(2, vt.configs.size)
        compose.onNodeWithText("Dismiss").performClick()
        compose.onNodeWithTag("terminal-notice").assertDoesNotExist()
        compose.onNodeWithContentDescription("Escape").assertIsEnabled().performClick()
        await { inputs() == listOf(key("Escape")) }
    }

    @Test fun newTerminalCreatesASessionInTheWorkspace() {
        launch()
        openWorkspace()
        compose.onNodeWithTag(BROWSE_LIST).performScrollToNode(hasText("New terminal"))
        compose.onNodeWithText("New terminal").performClick()
        await { events<EventTerminalCreate>().isNotEmpty() }
        val create=events<EventTerminalCreate>().single()
        assertEquals("fixture-ws", create.workspace_id)
        assertNull(create.cwd)
        assertTrue(create.cols > 20 && create.rows > 4)
        await { events<EventTerminalApplied>().any { it.terminal_id == "mobile:fixture:1" } }
        // terminal_create attaches by itself; the screen never sends a second attach.
        assertTrue(events<EventTerminalAttach>().isEmpty())
        compose.onNodeWithContentDescription("Tab").performClick()
        await { events<EventTerminalInput>().any { it.terminal_id == "mobile:fixture:1" && it.input == key("Tab") } }
        // It matches its own measured size already, so no resize is needed.
        assertTrue(events<EventTerminalResize>().isEmpty())
    }

    @Test fun withoutTerminalWriteTheTerminalIsViewOnly() {
        scopes=listOf("terminal:read")
        vt.reply="\u001b[3;1R"
        launch()
        openWorkspace()
        compose.onNodeWithText("New terminal").assertDoesNotExist()
        openHtop(inWorkspace=true)
        awaitText("View only: this phone was paired without terminal access.")
        compose.onNodeWithContentDescription("Escape").assertDoesNotExist()
        compose.onNodeWithTag("terminal-input").assertDoesNotExist()
        compose.waitForIdle()
        assertTrue(events<EventTerminalReply>().isEmpty())
        assertTrue(events<EventTerminalResize>().isEmpty())
    }

    @Test fun hardwareKeysMapToCoreKeyNames() {
        fun down(code: Int, meta: Int = 0) = hardwareKey(KeyEvent(0, 0, KeyEvent.ACTION_DOWN, code, 0, meta))
        assertEquals(TermInput.Key("Enter"), down(KeyEvent.KEYCODE_ENTER))
        assertEquals(TermInput.Key("Tab", shift=true), down(KeyEvent.KEYCODE_TAB, KeyEvent.META_SHIFT_ON))
        assertEquals(TermInput.Key("PageDown"), down(KeyEvent.KEYCODE_PAGE_DOWN))
        assertEquals(TermInput.Key("Escape"), down(KeyEvent.KEYCODE_ESCAPE))
        assertEquals(TermInput.Text("a"), down(KeyEvent.KEYCODE_A))
        assertEquals(TermInput.Text("A"), down(KeyEvent.KEYCODE_A, KeyEvent.META_SHIFT_ON))
        assertEquals(TermInput.Key("x", alt=true), down(KeyEvent.KEYCODE_X, KeyEvent.META_ALT_ON))
        assertNull(down(KeyEvent.KEYCODE_SHIFT_LEFT))
    }

    private fun tail() = CoreJson.parseToJsonElement(File(System.getProperty("verde.core.fixtures")!!, "terminal/tail.json").readText())
        .jsonObject["text"]!!.jsonPrimitive.content

    private fun key(name: String, ctrl: Boolean = false) =
        EventTerminalInputInput(EventTerminalInputInputKind.key, key=name, ctrl=ctrl, alt=false, shift=false)
    private fun text(value: String) = EventTerminalInputInput(EventTerminalInputInputKind.text, text=value, ctrl=false, alt=false, shift=false)

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

    /** VT stand-in serving the committed real-VT snapshot; records every call (tests only). */
    private class FakeVt : TerminalBridge {
        private val snapshot: TerminalSnapshot = CoreJson.decodeFromString(
            TerminalTest::class.java.getResource("/fixtures/k12/snapshot.json")!!.readText())
        val configs=CopyOnWriteArrayList<TerminalConfig>()
        val writes=CopyOnWriteArrayList<String>()
        val resizes=CopyOnWriteArrayList<Pair<Int,Int>>()
        val scrolls=CopyOnWriteArrayList<Int>()
        val freed=CopyOnWriteArrayList<Long>()
        @Volatile var reply: String?=null
        private var handles=0L
        private var revision=0
        override fun create(config: ByteArray): Long { configs += CoreJson.decodeFromString<TerminalConfig>(config.decodeToString()); return ++handles }
        override fun write(term: Long, bytes: ByteArray): Int { writes += bytes.decodeToString(); revision++; return 0 }
        override fun resize(term: Long, cols: Int, rows: Int): Int { resizes += cols to rows; return 0 }
        override fun scroll(term: Long, deltaRows: Int): Int {
            val offset=scrolls.sum()
            scrolls += (offset + deltaRows).coerceIn(0, 10) - offset
            return 0
        }
        override fun snapshot(term: Long): ByteArray {
            val replies=reply?.let { Base64.getEncoder().encodeToString(it.encodeToByteArray()) } ?: ""
            reply=null
            return CoreJson.encodeToString(snapshot.copy(revision=revision.toString(), scroll_offset=scrolls.sum().toLong(),
                scrollback_rows=10, reply_bytes_base64=replies)).encodeToByteArray()
        }
        override fun free(term: Long) { freed += term }
    }

    /**
     * Host/sync stand-in plus the K-12 pump contract: attach (or a reconnect while attached)
     * emits a reset `terminal_output`; create starts the session through a timer round-trip.
     * Every batch invalidates hosts/home/workspaces and every terminal selector.
     */
    private class TermCore(saved: SavedHost, scopes: List<String>) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        @Volatile var freed=false
        private val home: HomeQuery = CoreJson.decodeFromString(read("home-live.json"))
        private val workspaces: WorkspacesQuery = CoreJson.decodeFromString(read("workspaces-live.json"))
        private val tail=CoreJson.parseToJsonElement(File(System.getProperty("verde.core.fixtures")!!, "terminal/tail.json").readText())
            .jsonObject["text"]!!.jsonPrimitive.content
        @Volatile private var row=HostView(saved.id,saved.label,null,null,null,"idle",Lifecycle.background,"paired","ready",
            emptyList(),scopes,null,null,false,null)
        private val terminals=LinkedHashMap<String, TerminalView>()
        private var sequence=0
        private var created=0

        override fun create(config: ByteArray)=1L
        override fun handle(host: Long, event: ByteArray): ByteArray {
            val decoded=CoreJson.decodeFromString<Event>(event.decodeToString())
            events.add(decoded)
            val effects=mutableListOf<Effect>()
            fun output(id: String, text: String) {
                effects.add(EffectTerminalOutput("o${sequence++}","1",id,true,Base64.getEncoder().encodeToString(text.encodeToByteArray()),"65"))
            }
            fun update(id: String, change: (TerminalView) -> TerminalView) { terminals[id]?.let { terminals[id]=change(it) } }
            when (decoded) {
                is EventForeground -> row=row.copy(lifecycle=Lifecycle.foreground, phase="ready")
                is EventNetworkChanged -> if (!decoded.available) {
                    row=row.copy(phase="disabled"); terminals.keys.toList().forEach { id -> update(id) { it.copy(stale=true) } }
                } else if (row.phase != "ready") {
                    row=row.copy(phase="ready")
                    // Reconnect: attached terminals restart from a full (reset) replay.
                    terminals.values.filter { it.attached }.forEach { view -> update(view.terminal_id) { it.copy(stale=false) }; output(view.terminal_id, tail) }
                }
                is EventTerminalAttach -> {
                    terminals[decoded.terminal_id]=(terminals[decoded.terminal_id] ?: TerminalView(decoded.terminal_id, "fixture-ws", "htop"))
                        .copy(attached=true, session_status="running", cols=20, rows=4, stale=false, next_offset="0")
                    output(decoded.terminal_id, tail)
                }
                is EventTerminalDetach -> update(decoded.terminal_id) { it.copy(attached=false) }
                is EventTerminalApplied -> update(decoded.terminal_id) { it.copy(grid_revision=decoded.grid_revision, next_offset="65") }
                is EventTerminalResize -> update(decoded.terminal_id) { it.copy(cols=decoded.cols, rows=decoded.rows) }
                is EventTerminalCreate -> {
                    val id="mobile:fixture:${++created}"
                    terminals[id]=TerminalView(id, decoded.workspace_id, "Terminal", "starting", true, decoded.cols, decoded.rows, null, "0", true, null)
                    effects.add(EffectSetTimer("t${sequence++}","1","create:$id",10,"test"))
                }
                is EventTimerFired -> if (decoded.timer_id.startsWith("create:")) {
                    val id=decoded.timer_id.removePrefix("create:")
                    update(id) { it.copy(session_status="running", stale=false) }
                    output(id, "$ ")
                }
                else -> Unit
            }
            effects.add(EffectStateChanged("s${sequence++}","1","1",listOf("hosts","home","workspaces") + terminals.keys.map(::terminalSelector)))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray = when {
            selector == "home" -> CoreJson.encodeToString(home)
            selector == "workspaces" -> CoreJson.encodeToString(workspaces)
            selector.startsWith("terminal:") -> CoreJson.encodeToString(TerminalQuery(1,"1",
                terminals.values.find { terminalSelector(it.terminal_id) == selector },null))
            else -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(row),emptyList()),null))
        }.encodeToByteArray()
        override fun free(host: Long) { freed=true }

        private fun read(name: String) = TerminalTest::class.java.getResource("/fixtures/k09/$name")!!.readText()
    }

    companion object { const val NOW=1_700_000_100_000L }
}

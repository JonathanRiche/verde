package dev.verdeai.app

import android.content.ClipboardManager
import android.content.Context
import android.os.Looper
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
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
import java.util.concurrent.atomic.AtomicInteger

/**
 * D-06 transcript over a fake core that serves real core projections recorded from the K-10 chat
 * fixtures and real K-11 render results (see fixtures/d06/README.md).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35], qualifiers="w411dp-h1500dp")
class TranscriptTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private lateinit var transcript: TranscriptModel
    private val store = Store()
    private val signals = FakeSignals()
    private val cores = CopyOnWriteArrayList<ChatCore>()
    private var setup: (ChatCore) -> Unit = {}
    private val core get() = cores.single()
    private val citations = CopyOnWriteArrayList<FileCitation>()
    private val networkIds = AtomicInteger(1)

    /** Advances the paused main looper's clock too, so Main-dispatcher delays (unfocus debounce) run. */
    private fun pump() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) { pump(); condition() }
    private fun awaitText(text: String, substring: Boolean = false) = compose.waitUntil(5000) {
        pump()
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    }
    private fun exists(text: String, substring: Boolean = false) =
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()

    private fun launch(workspace: String = WS, thread: String = THREAD) {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            val provider=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals) { saved ->
                        val fake=ChatCore(saved).also(setup).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake)
                    }
                    BrowseModel::class.java -> BrowseModel(hosts, null, signals, wallClock={ NOW })
                    else -> TranscriptModel(hosts, browse.state, workspace, thread, unfocusDelayMs=50)
                } as T
            })
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
            transcript=provider[TranscriptModel::class.java]
        }
        compose.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalUiClock provides UiClock(now={ NOW }, ticking=false)) {
                    TranscriptScreen(transcript, "Chat fixture", onBack={}, onHosts={}, onRetryConnection=browse::refresh,
                        onCitation={ citations.add(it) })
                }
            }
        }
    }

    /** Delivers whatever the fake core now holds, like a tail response landing. */
    private fun deliver(change: ChatCore.() -> Unit) {
        core.change()
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-${networkIds.incrementAndGet()}") }
    }
    private fun list() = compose.onNodeWithTag(TRANSCRIPT_LIST)
    private fun focuses() = core.events.filterIsInstance<EventFocus>()

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
        FocusClaim.owner=null
    }

    @Test fun opensFocusedRendersCoreMarkdownAndPagesOlderOncePerCursor() {
        launch()
        awaitText("History 44")
        // Entering the screen is the one focus that clears K-17 attention and starts the page load.
        val focus=focuses().single()
        assertEquals(WS, focus.workspace_id); assertEquals(THREAD, focus.thread_id); assertNull(focus.terminal_id)
        compose.onNodeWithText("Chat fixture").assertExists()
        // Bodies went through the core's markdown utility, not a Kotlin parser.
        await { compose.onAllNodesWithTag(MARKDOWN_TAG, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty() }
        assertTrue(core.utilityQueries.get() > 0)
        assertEquals(0, core.fallbackRenders.get())
        compose.onNodeWithText("Start of conversation").assertDoesNotExist()
        // Scrolling to the oldest loaded row requests exactly one older page.
        list().performScrollToNode(hasText("History 5"))
        await { core.events.any { it is EventThreadLoadOlder } }
        await { transcript.state.value.thread?.page?.has_older == false }
        list().performScrollToNode(hasText("History 0"))
        list().performScrollToNode(hasText("Start of conversation"))
        assertEquals(1, core.events.count { it is EventThreadLoadOlder })
        // The newest row stays present after prepending older history.
        list().performScrollToIndex(0)
        awaitText("History 44")
    }

    @Test fun richRowsUseTheirRenderersAndNeverShowHostPaths() {
        setup={ it.thread="thread-rich" }
        launch()
        awaitText("Build fixed")
        assertEquals(0, core.fallbackRenders.get())
        // Heading markers are consumed by the AST; the code block is highlighted by core spans.
        assertFalse(exists("## Build fixed", substring=true))
        list().performScrollToNode(hasText("Copy code"))
        val code=compose.onNode(hasText("const answer", substring=true), useUnmergedTree=true).fetchSemanticsNode()
        val styled=code.config[SemanticsProperties.Text].single()
        assertTrue(styled.spanStyles.isNotEmpty())
        compose.onNodeWithText("Copy code").performClick()
        assertEquals("const answer: number = 42; // typed\nexport default answer;", clip())
        list().performScrollToNode(hasText("tests"))
        compose.onNodeWithText("✅ 12 passed", useUnmergedTree=true).assertExists()
        // Latest usage row becomes the core-parsed usage card.
        list().performScrollToNode(hasText("Codex usage"))
        compose.onNodeWithText("72% left", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("resets Oct 2", useUnmergedTree=true).assertExists()
        list().performScrollToNode(hasText("Provider restarted after an update."))
        // Changed-files default card lists files from the core diff utility (D-07 replaces it).
        list().performScrollToNode(hasText("Changed files · 1"))
        compose.onNodeWithText("src/main.zig", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("+1 −1", useUnmergedTree=true).assertExists()
        // Consecutive tool calls collapse into a group; a failure expands it by default.
        list().performScrollToNode(hasText("3 tool calls · 2 completed · 1 failed"))
        list().performScrollToNode(hasText("error: missing semicolon", substring=true))
        list().performScrollToNode(hasText("1 subagent · 1 completed"))
        compose.onNodeWithText("Found 2 callers.", substring=true).assertDoesNotExist()
        compose.onNodeWithText("1 subagent · 1 completed").performClick()
        compose.onNodeWithText("Subagent").performClick()
        list().performScrollToNode(hasText("Output:\nFound 2 callers.", substring=true))
        list().performScrollToNode(hasText("Thought"))
        compose.onNodeWithText("Checking the build output first.", substring=true).assertDoesNotExist()
        // The user's image attachment shows its file name only.
        list().performScrollToNode(hasText("Image · screenshot.png"))
        compose.onNodeWithText("/tmp/rich-project", substring=true, useUnmergedTree=true).assertDoesNotExist()
        compose.onNodeWithText("Can you fix the build? Here is the screenshot.").assertExists()
    }

    @Test fun liveTailStreamsWorkingTimerAndStopUsesTheCoreTurnId() {
        setup={ it.thread="thread-running"; it.composer="composer-running" }
        launch()
        awaitText("Fixture prompt")
        awaitText("Working · 1:05")
        compose.onNodeWithText("Stop").assertIsEnabled()
        deliver { thread="thread-streaming" }
        awaitText("stub-ok")
        // Both the overlaid prompt and the partial reply are still streaming.
        assertEquals(2, compose.onAllNodesWithText("Streaming", useUnmergedTree=true).fetchSemanticsNodes().size)
        compose.onNodeWithText("Stop").performClick()
        await { core.events.any { it is EventTurnCancel } }
        assertEquals("fixture-turn", core.events.filterIsInstance<EventTurnCancel>().single().turn_id)
        awaitText("Stopping · 1:05")
        compose.onNodeWithText("Stopping…").assertIsNotEnabled()
        // Commit replaces the overlay; the A-09 access-cap notice arrives with the committed page.
        deliver { thread="thread-committed"; composer="composer-committed" }
        awaitText("This device is limited to approval-required access.", substring=true)
        compose.onNodeWithText("Stopping", substring=true).assertDoesNotExist()
        compose.onNodeWithTag(STOP_BAR).assertDoesNotExist()
        assertEquals(1, core.events.count { it is EventTurnCancel })
    }

    @Test fun newOutputFollowsAtBottomButNeverYanksAScrolledUpReader() {
        setup={ it.thread=synthetic(500) }
        launch()
        awaitText("Message 499")
        compose.onNodeWithContentDescription(JUMP_TO_BOTTOM).assertDoesNotExist()
        // At the bottom, new output is followed.
        deliver { thread=synthetic(501) }
        awaitText("Message 500")
        // Scrolled up, new output leaves the reading position alone and offers a jump.
        list().performScrollToIndex(60)
        awaitText("Message 440")
        compose.onNodeWithContentDescription(JUMP_TO_BOTTOM).assertExists()
        deliver { thread=synthetic(502) }
        await { transcript.state.value.thread?.rows?.size == 502 }
        compose.waitForIdle()
        assertFalse(exists("Message 501"))
        assertTrue(exists("Message 440"))
        compose.onNodeWithContentDescription(JUMP_TO_BOTTOM).performClick()
        awaitText("Message 501")
        await { compose.onAllNodesWithContentDescription(JUMP_TO_BOTTOM).fetchSemanticsNodes().isEmpty() }
    }

    @Test fun offlineFocusIsRetriedOnceWhenTheHostBecomesReady() {
        signals.network.value=NetworkState(false, "")
        launch()
        awaitText("You're offline.")
        awaitText("This conversation will load when the host is reachable.")
        await { focuses().size == 1 }
        assertEquals("unavailable", core.operations[focuses().single().intent_id]?.error?.code)
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-9") }
        awaitText("History 44")
        assertEquals(2, focuses().size)
        // Further state changes never re-spend receipts on focus.
        deliver { }
        deliver { }
        compose.waitForIdle()
        assertEquals(2, focuses().size)
    }

    @Test fun loadingErrorRetryAndMissingStates() {
        setup={ it.thread="thread-loading" }
        launch()
        awaitText("Loading conversation…")
        deliver { thread="thread-error" }
        awaitText("Couldn't load this conversation.")
        awaitText("The runtime rejected the request.", substring=true)
        core.afterFocus="thread-open"
        compose.onNodeWithText("Retry loading").performClick()
        awaitText("History 44")
        assertEquals(2, focuses().size)
    }

    @Test fun aThreadTheHostNoLongerHasSaysSo() {
        setup={ it.missing=true }
        launch()
        awaitText("This chat is no longer on the host.")
        assertEquals("thread_unavailable", core.operations[focuses().single().intent_id]?.error?.code)
    }

    @Test fun leavingUnfocusesOnlyWhatThisScreenStillOwns() {
        launch()
        awaitText("History 44")
        compose.runOnIdle { transcript.setVisible(false) }
        await { focuses().any { it.thread_id == null } }
        compose.runOnIdle { transcript.setVisible(true) }
        await { focuses().count { it.thread_id == THREAD } == 2 }
        // Another surface claimed focus: this screen's later unfocus must not clobber it.
        compose.runOnIdle { FocusClaim.owner=Any(); transcript.setVisible(false) }
        repeat(20) { pump() }
        compose.waitForIdle()
        assertEquals(1, focuses().count { it.thread_id == null })
    }

    @Test fun pureRules() {
        assertEquals("thread:%5B%22chat-fixture-ws%22%2C%22chat-fixture-thread%22%5D", chatSelector("thread", WS, THREAD))
        assertEquals("composer:%5B%22a%20b%22%2C%22%C3%A9%22%5D", chatSelector("composer", "a b", "é"))
        // UTF-8 byte offsets → UTF-16 indices across 1-, 2-, 3- and 4-byte characters.
        assertArrayEquals(intArrayOf(0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 5), utf8ToUtf16("aé世😀"))
        val spans=listOf(RenderSpan(3uL, 6uL, "keyword"), RenderSpan(6uL, 99uL, "string"))
        val text=highlighted("aé世😀", spans) { androidx.compose.ui.text.SpanStyle(color=Color.Red) }
        assertEquals(listOf(2 to 3, 3 to 5), text.spanStyles.map { it.start to it.end })
        assertEquals("https://x.dev", safeLinkUrl("https://x.dev"))
        assertNull(safeLinkUrl("javascript:alert(1)"))
        assertNull(safeLinkUrl("/relative"))
        assertEquals("screenshot.png", basename("/tmp/rich-project/.verde/screenshot.png"))
        assertEquals("main.zig:42", citationLabel(FileCitation("/tmp/x/main.zig", 42uL)))
        assertEquals("a\nb" to true, leadingLines("a\nb\nc", 2))
        assertEquals(3, countLines("a\nb\nc\n"))
        assertEquals("Input: zig build", commandPreview("Input:\nzig   build\n"))
        val rich=Fixtures.thread("thread-rich").data!!
        val items=transcriptItems(rich)
        assertEquals(listOf("Message","Think","ToolGroup","ToolGroup","Diff","Message","Notice","Usage"), items.map { it::class.simpleName })
        val (tools, agents)=items.filterIsInstance<TranscriptItem.ToolGroup>()
        assertFalse(tools.subagent); assertTrue(agents.subagent)
        assertEquals("3 tool calls · 2 completed · 1 failed", toolGroupSummary(tools.rows, false, "0:05"))
        val running=Fixtures.thread("thread-stopping").data!!
        val working=transcriptItems(running).last() as TranscriptItem.Working
        assertEquals("Stopping · 1:05", workingLabel(working, "1:05"))
        assertEquals(listOf("working"), transcriptItems(running).filterIsInstance<TranscriptItem.Working>().map { it.key })
        assertTrue(transcriptItems(Fixtures.thread("thread-committed").data!!).none { it is TranscriptItem.Working })
        // Streaming bodies send only a bounded tail to the markdown utility.
        val big=ChatRow("s","assistant",body="x".repeat(20_000) + "\n" + "tail", delivery="streaming")
        assertEquals("tail", streamTail(big, 10))
        assertEquals(big.body, streamTail(big.copy(delivery="committed"), 10))
        // Citations are routed to the host-file callback (D-12), links only for admitted schemes.
        val assistant=rich.rows.single { it.id == "rich-assistant" }
        val nodes=Fixtures.render("markdown", assistant.body)!!.jsonObject["data"]!!.jsonObject["nodes"]!!
        val blocks=markdownBlocks(CoreJson.decodeFromJsonElement(nodes), MdStyle(Color.Blue, Color.Gray)) { citations.add(it) }
        val paragraph=blocks.filterIsInstance<MdBlock.Paragraph>().first().text
        val links=paragraph.getLinkAnnotations(0, paragraph.length).map { it.item }
        (links.filterIsInstance<LinkAnnotation.Clickable>().single()).linkInteractionListener!!.onClick(links.first())
        assertEquals(FileCitation("/tmp/rich-project/src/main.zig", 42uL), citations.single())
        assertEquals("https://ziglang.org/documentation/", links.filterIsInstance<LinkAnnotation.Url>().single().url)
        assertEquals(listOf("Heading","Paragraph","Bullets","Quote","Code","Table"), blocks.map { it::class.simpleName })
    }

    private fun clip()=ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)
        .primaryClip?.getItemAt(0)?.text?.toString()

    /** thread-open's envelope with [count] synthetic rows (exercises the fallback render path). */
    private fun synthetic(count: Int): String {
        val base=Fixtures.thread("thread-older")
        val rows=List(count) { ChatRow("syn-$it","assistant",author="Codex",body="Message $it") }
        return CoreJson.encodeToString(base.copy(data=base.data!!.copy(rows=rows)))
    }

    private object Fixtures {
        fun read(name: String)=TranscriptTest::class.java.getResource("/fixtures/d06/$name")!!.readText()
        private val texts=ConcurrentHashMap<String,String>()
        fun text(name: String): String = if (name.startsWith("{")) name else texts.getOrPut(name) { read("$name.json") }
        fun thread(name: String): ThreadQuery=CoreJson.decodeFromString(text(name))
        private val renders: List<JsonObject> by lazy { Json.parseToJsonElement(read("render.json")).jsonArray.map { it.jsonObject } }
        fun render(kind: String, body: String, language: String?=null): JsonElement? = renders.firstOrNull { entry ->
            val q=entry["query"]!!.jsonObject
            q["kind"]!!.jsonPrimitive.content == kind && q["text"]!!.jsonPrimitive.content == body &&
                (language == null || q["language"]?.jsonPrimitive?.content == language)
        }?.get("result")
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
     * Host/sync as in BrowseTest plus the chat intents D-06 sends. Thread/composer projections are
     * recorded core envelopes; network-id bumps from [deliver] stand in for a tail response landing.
     * Utility queries answer from the recorded K-11 results; only bodies outside the recording (the
     * synthetic scroll test) get a synthesized single-paragraph AST, counted in [fallbackRenders].
     */
    private class ChatCore(val saved: SavedHost) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        val operations=ConcurrentHashMap<String, Operation>()
        val utilityQueries=AtomicInteger()
        val fallbackRenders=AtomicInteger()
        @Volatile var freed=false
        @Volatile var thread="thread-open"
        @Volatile var composer="composer-idle"
        @Volatile var afterFocus: String?=null
        @Volatile var missing=false
        @Volatile private var ensured=false
        @Volatile private var row=HostView(saved.id,saved.label,null,null,null,"idle",Lifecycle.background,"paired","empty",
            emptyList(),emptyList(),null,null,false,null)
        private var network=true
        private var sequence=0
        private val threadSelector=chatSelector("thread", WS, THREAD)
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
            fun op(id: String, state: String, code: String?=null) {
                operations[id]=Operation(id, state, code?.let { LocalError(code=it, message="") })
            }
            val online=row.phase == "ready"
            when (decoded) {
                is EventForeground -> { row=row.copy(lifecycle=Lifecycle.foreground); connect() }
                is EventNetworkChanged -> {
                    val was=network
                    network=decoded.available
                    if (!network) row=row.copy(phase="disabled") else if (!was || row.phase != "ready") connect()
                }
                is EventTimerFired -> if (decoded.timer_id == "sync" && row.phase == "connecting") row=row.copy(phase="ready", sync_state="ready")
                is EventFocus -> when {
                    decoded.thread_id == null -> op(decoded.intent_id, "succeeded")
                    missing -> op(decoded.intent_id, "failed", "thread_unavailable")
                    // The real core ensures an empty, unloaded thread here; no rows either way.
                    !online -> op(decoded.intent_id, "failed", "unavailable")
                    else -> { ensured=true; afterFocus?.let { thread=it }; op(decoded.intent_id, "pending") }
                }
                is EventThreadLoadOlder -> {
                    op(decoded.intent_id, "pending")
                    thread="thread-loading-older"
                    effects.add(EffectSetTimer("t${sequence++}","1","older",10,"test"))
                }
                is EventTurnCancel -> if (thread == "thread-streaming" || thread == "thread-running") {
                    op(decoded.intent_id, "pending"); thread="thread-stopping"; composer="composer-stopping"
                } else op(decoded.intent_id, "failed", "stale_turn")
                else -> Unit
            }
            if (decoded is EventTimerFired && decoded.timer_id == "older") thread="thread-older"
            val scopes=mutableListOf("hosts","home","workspaces")
            if (ensured) scopes+=listOf(threadSelector, chatSelector("composer", WS, THREAD))
            effects.add(EffectStateChanged("s${sequence++}","1","1",scopes))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray = when {
            selector == "hosts" -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(row),operations.values.toList()),null))
            selector == "home" -> CoreJson.encodeToString(HomeQuery(1,"1",HomeView(emptyList(),false,false,emptyList(),null),null))
            selector == "workspaces" -> CoreJson.encodeToString(WorkspacesQuery(1,"1",WorkspacesView(emptyList(),false,false,null,
                HistoryView("",emptyList(),null,false,null)),null))
            selector.startsWith("thread:") -> if (ensured) Fixtures.text(thread) else notFound()
            selector.startsWith("composer:") -> if (ensured) Fixtures.text(composer) else notFound()
            selector.startsWith("{") -> utility(Json.parseToJsonElement(selector).jsonObject)
            else -> notFound()
        }.encodeToByteArray()
        private fun notFound()="""{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":"Unknown thread."}}"""
        private fun utility(q: JsonObject): String {
            utilityQueries.incrementAndGet()
            val kind=q["utility"]!!.jsonPrimitive.content
            val text=q["text"]!!.jsonPrimitive.content
            Fixtures.render(kind, text, q["language"]?.jsonPrimitive?.content)?.let { return it.toString() }
            fallbackRenders.incrementAndGet()
            val bytes=text.encodeToByteArray().size
            val data=when (kind) {
                "markdown" -> """{"nodes":[{"kind":"document","start":0,"end":$bytes,"children":[{"kind":"paragraph","start":0,"end":$bytes,"children":[{"kind":"text","start":0,"end":$bytes,"text":${JsonPrimitive(text)},"children":[]}]}]}]}"""
                "highlight" -> """{"spans":[]}"""
                else -> """{"files":[]}"""
            }
            return """{"api_version":1,"revision":"1","data":$data,"error":null}"""
        }
        override fun free(host: Long) { freed=true }
    }

    companion object {
        const val WS="chat-fixture-ws"
        const val THREAD="chat-fixture-thread"
        /** Fixture turn started at 1790363190811; the UI clock sits 65 s later. */
        const val NOW=1_790_363_190_811L + 65_000
    }
}

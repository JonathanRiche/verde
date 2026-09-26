package dev.verdeai.app

import android.os.Looper
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
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
 * D-09 approval card over a fake core serving real core `thread:` projections recorded from the
 * core's approval harness (fixtures/d09/README.md). Operation receipts are synthesized like D-06.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35], qualifiers="w411dp-h1500dp")
class ApprovalTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private lateinit var transcript: TranscriptModel
    private val store = Store()
    private val signals = FakeSignals()
    private val cores = CopyOnWriteArrayList<ApprovalCore>()
    private var setup: (ApprovalCore) -> Unit = {}
    private val core get() = cores.single()
    private val haptics = CopyOnWriteArrayList<HapticFeedbackType>()
    private val networkIds = AtomicInteger(1)

    private fun pump() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) { pump(); condition() }
    private fun exists(text: String, substring: Boolean = false) =
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    private fun awaitText(text: String, substring: Boolean = false) = await { exists(text, substring) }
    private fun awaitGone(text: String, substring: Boolean = false) = await { !exists(text, substring) }
    private fun decisions() = core.events.filterIsInstance<EventApprovalDecide>()

    private fun launch() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            val provider=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals) { saved ->
                        val fake=ApprovalCore(saved).also(setup).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake)
                    }
                    BrowseModel::class.java -> BrowseModel(hosts, null, signals, wallClock={ NOW })
                    else -> TranscriptModel(hosts, browse.state, WS, THREAD, unfocusDelayMs=50)
                } as T
            })
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
            transcript=provider[TranscriptModel::class.java]
        }
        val recorder=object : HapticFeedback { override fun performHapticFeedback(hapticFeedbackType: HapticFeedbackType) { haptics.add(hapticFeedbackType) } }
        compose.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalUiClock provides UiClock(now={ NOW }, ticking=false), LocalHapticFeedback provides recorder) {
                    TranscriptScreen(transcript, "Chat fixture", onBack={}, onHosts={}, onRetryConnection=browse::refresh)
                }
            }
        }
    }

    /** Delivers whatever the fake core now holds, like a tail or RPC response landing. */
    private fun deliver(change: ApprovalCore.() -> Unit) {
        core.change()
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-${networkIds.incrementAndGet()}") }
    }

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
        FocusClaim.owner=null
    }

    @Test fun approveTargetsTheCurrentCallThenConfirmsAndReportsTheOutcome() {
        setup={ it.thread="approval-command" }
        launch()
        awaitText("Command approval")
        compose.onNodeWithText("$ zig build test --summary all", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("Waiting for approval", substring=true).assertExists()
        // The card announces itself politely to TalkBack.
        val header=compose.onNodeWithContentDescription("Approval required: Command approval", useUnmergedTree=true).fetchSemanticsNode()
        assertEquals(LiveRegionMode.Polite, header.config[SemanticsProperties.LiveRegion])

        compose.onNodeWithText(APPROVE_LABEL).performClick()
        await { decisions().isNotEmpty() }
        val sent=decisions().single()
        assertEquals("fixture-turn", sent.turn_id); assertEquals("call-cmd", sent.call_id)
        assertEquals(EventApprovalDecideDecision.approve, sent.decision)
        assertEquals(WS, sent.workspace_id); assertEquals(THREAD, sent.thread_id)
        assertEquals(listOf(HapticFeedbackType.Confirm), haptics.toList())
        // In flight: both choices locked, the chosen one says so.
        awaitText("Approving…")
        compose.onNodeWithText(DENY_LABEL).assertIsNotEnabled()
        compose.onNodeWithText("Approving…").assertIsNotEnabled()

        // The host accepted it: confirmed, no buttons left to tap twice.
        deliver { operations[sent.intent_id]=Operation(sent.intent_id, "succeeded", null); thread="approval-sent" }
        awaitText("Approved — waiting for the agent to continue.")
        assertFalse(exists(APPROVE_LABEL)); assertFalse(exists(DENY_LABEL))
        await { haptics.size == 2 }
        assertEquals(HapticFeedbackType.Confirm, haptics.last())

        // The tail clears it: the card leaves and the outcome is announced.
        deliver { thread="approval-resolved" }
        awaitGone("Command approval")
        compose.onNodeWithTag(APPROVAL_OUTCOME).assertTextEquals("Approved")
        assertEquals(1, decisions().size)
    }

    @Test fun aStaleDecisionSaysSoWithoutAThreadErrorBanner() {
        setup={ it.thread="approval-command"; it.onDecide={ id -> thread="approval-stale"; operations[id]=staleOp(id) } }
        launch()
        awaitText("Command approval")
        compose.onNodeWithText(DENY_LABEL).performClick()
        await { decisions().isNotEmpty() }
        assertEquals(EventApprovalDecideDecision.deny, decisions().single().decision)
        assertEquals(listOf(HapticFeedbackType.Reject), haptics.toList())
        awaitText("This request is no longer waiting", substring=true)
        assertFalse(exists(APPROVE_LABEL)); assertFalse(exists(DENY_LABEL))
        // The core also mirrors the RPC failure into thread.error; the card owns that message.
        assertNotNull(transcript.state.value.thread?.error)
        assertFalse(exists("Couldn't load this chat", substring=true))
    }

    @Test fun anUncertainFailureCanBeRetried() {
        setup={ it.thread="approval-command"; it.onDecide={ id -> thread="approval-failed"; operations[id]=Operation(id, "uncertain", failedError()) } }
        launch()
        awaitText("Command approval")
        compose.onNodeWithText(DENY_LABEL).performClick()
        awaitText("Couldn't confirm your decision reached the host. Try again.")
        val status=compose.onNodeWithText("Couldn't confirm your decision reached the host. Try again.", useUnmergedTree=true).fetchSemanticsNode()
        assertEquals(LiveRegionMode.Assertive, status.config[SemanticsProperties.LiveRegion])
        // Tap haptic, then one more for the failure.
        await { haptics.size == 2 }
        assertEquals(listOf(HapticFeedbackType.Reject, HapticFeedbackType.Reject), haptics.toList())
        core.onDecide={ id -> thread="approval-pending"; operations[id]=Operation(id, "pending", null) }
        compose.onNodeWithText(APPROVE_LABEL).assertIsEnabled().performClick()
        await { decisions().size == 2 }
        assertEquals(EventApprovalDecideDecision.approve, decisions().last().decision)
        awaitText("Approving…")
    }

    @Test fun anApprovalAnsweredOnAnotherDeviceIsReflected() {
        setup={ it.thread="approval-command" }
        launch()
        awaitText("Command approval")
        deliver { thread="approval-resolved" }
        awaitGone("Command approval")
        compose.onNodeWithTag(APPROVAL_OUTCOME).assertTextEquals("Approval answered on another device")
        assertTrue(decisions().isEmpty())
        // The notice is transient.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ApprovalController.OUTCOME_MS + 100))
        await { compose.onAllNodesWithTag(APPROVAL_OUTCOME).fetchSemanticsNodes().isEmpty() }
    }

    @Test fun theBannerJumpsToAnOffscreenCard() {
        setup={ it.thread="approval-command" }
        launch()
        awaitText("Command approval")
        compose.onNodeWithTag(APPROVAL_BANNER).assertDoesNotExist()
        compose.onNodeWithTag(TRANSCRIPT_LIST).performScrollToNode(hasText("History 6"))
        await { compose.onAllNodesWithTag(APPROVAL_BANNER).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Needs approval · Command approval", useUnmergedTree=true).assertExists()
        compose.onNodeWithTag(APPROVAL_BANNER).performClick()
        awaitText("Command approval")
        await { compose.onAllNodesWithTag(APPROVAL_BANNER).fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithText(APPROVE_LABEL).assertIsDisplayed()
    }

    @Test fun anEditShowsTheFileNameAndChangeBeforeTheFullRequest() {
        setup={ it.thread="approval-edit" }
        launch()
        awaitText("Claude wants to use Edit")
        compose.onNodeWithText("Edit", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("main.zig", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("− const answer = 41;", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("+ const answer = 42;", useUnmergedTree=true).assertExists()
        // The host path only appears in the raw request, behind an explicit tap.
        assertFalse(exists("/tmp/fixture-project", substring=true))
        compose.onNodeWithText("▸ Show full request").performClick()
        awaitText("/tmp/fixture-project/src/main.zig", substring=true)
        compose.onNodeWithText("Copy request").assertExists()
    }

    @Test fun sharedHelpersForNotificationActions() = runBlocking {
        // D-14 path: read the open thread's approval straight from the core, then decide it.
        val fake=ApprovalCore(SavedHost("alpha","Studio")).also { it.thread="approval-command"; it.ensured=true }
        val host=CoreHost.create(dev.verdeai.core.Config(1,"alpha","Studio",null,null,1,"",0uL), EffectExecutor(store,"alpha"), fake)
        try {
            val target=currentApprovalTarget(host, WS, THREAD)!!
            assertEquals(ApprovalTarget(WS, THREAD, "fixture-turn", "call-cmd"), target)
            val result=decideApproval(host, target, ApprovalDecision.Deny, intentId="intent-1")
            assertEquals(DecideResult.Sent("intent-1"), result)
            val event=fake.events.filterIsInstance<EventApprovalDecide>().single()
            assertEquals(EventApprovalDecideDecision.deny, event.decision); assertEquals("intent-1", event.intent_id)
            // A pending decision is not re-offered as a target.
            assertNull(currentApprovalTarget(host, WS, THREAD))
            fake.thread="approval-resolved"
            assertNull(currentApprovalTarget(host, WS, THREAD))
        } finally { host.close() }
    }

    @Test fun phaseRules() {
        val idle=Fixtures.thread("approval-command").data!!.approval!!
        val pending=Fixtures.thread("approval-pending").data!!.approval!!
        val stale=Fixtures.thread("approval-stale").data!!.approval!!
        val failed=Fixtures.thread("approval-failed").data!!.approval!!
        assertEquals("idle", idle.resolution); assertEquals("pending", pending.resolution)
        assertEquals("failed", stale.resolution); assertTrue(staleApprovalError(stale.error))
        assertEquals("failed", failed.resolution); assertFalse(staleApprovalError(failed.error))
        assertEquals("uncertain", failed.error?.delivery)
        assertNull(Fixtures.thread("approval-resolved").data!!.approval)

        val sending=LocalDecision(idle.key, ApprovalDecision.Approve, LocalDecision.State.Sending)
        assertEquals(ApprovalPhase.Idle, approvalPhase(idle, null))
        assertEquals(ApprovalPhase.Sending(ApprovalDecision.Approve), approvalPhase(idle, sending))
        assertEquals(ApprovalPhase.Sending(ApprovalDecision.Approve), approvalPhase(pending, sending))
        assertEquals(ApprovalPhase.Sending(null), approvalPhase(pending, null))
        assertEquals(ApprovalPhase.Sent(ApprovalDecision.Approve), approvalPhase(pending, sending.copy(state=LocalDecision.State.Sent)))
        assertEquals(ApprovalPhase.Stale, approvalPhase(stale, sending))
        assertEquals(ApprovalPhase.Stale, approvalPhase(idle, sending.copy(state=LocalDecision.State.Stale)))
        assertEquals(ApprovalPhase.Failed(ApprovalDecision.Approve, true), approvalPhase(failed, sending))
        // A decision for another call never leaks onto this card.
        assertEquals(ApprovalPhase.Idle, approvalPhase(idle, sending.copy(key="other")))
        assertTrue(ApprovalPhase.Idle.canDecide()); assertTrue(ApprovalPhase.Failed(null, false).canDecide())
        assertFalse(ApprovalPhase.Sending(null).canDecide()); assertFalse(ApprovalPhase.Stale.canDecide())
    }

    @Test fun previewRules() {
        fun preview(title: String, body: String)=approvalPreview(ChatApproval("t","c",title,body))
        val bash=preview("Claude wants to use Bash", "Tool: Bash\n\nReason: Runs the tests\n\n{\n  \"command\": \"zig build test\",\n  \"description\": \"Run tests\"\n}")
        assertEquals("Bash", bash.tool); assertEquals("zig build test", bash.command); assertEquals("Runs the tests", bash.reason)
        assertTrue(bash.changes.isEmpty())
        val edit=approvalPreview(Fixtures.thread("approval-edit").data!!.approval!!)
        assertEquals("Edit", edit.tool); assertEquals("/tmp/fixture-project/src/main.zig", edit.path)
        assertEquals(listOf(PreviewLine(PreviewKind.Remove, "const answer = 41;"), PreviewLine(PreviewKind.Add, "const answer = 42;")), edit.changes)
        val write=preview("Claude wants to use Write", "Tool: Write\n\n{\"file_path\":\"/x/a.md\",\"content\":\"" + (1..40).joinToString("\\n") { "l$it" } + "\"}")
        assertEquals(PREVIEW_LINES, write.changes.size); assertTrue(write.changesTruncated)
        assertTrue(write.changes.all { it.kind == PreviewKind.Add })
        val codex=preview("Command approval", "cargo test -p core")
        assertEquals("cargo test -p core", codex.command); assertNull(codex.tool)
        val diff=preview("File change approval", "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same")
        assertEquals(listOf(PreviewKind.Hunk, PreviewKind.Hunk, PreviewKind.Hunk, PreviewKind.Hunk, PreviewKind.Remove, PreviewKind.Add, PreviewKind.Context),
            diff.changes.map { it.kind })
        val opencode=preview("OpenCode wants bash permission", "Action: bash\nls -la\nResources:\n- /tmp")
        assertEquals("bash", opencode.tool)
        // Free text stays free text; malformed JSON is ignored, never thrown.
        assertEquals(ApprovalPreview(), preview("Permissions request", "Needs network access to fetch deps."))
        assertEquals("Edit", preview("x", "Tool: Edit\n\n{not json").tool)
        assertEquals(ApprovalPreview(), preview("x", ""))
    }

    private fun staleOp(id: String)=Operation(id, "failed", Fixtures.thread("approval-stale").data!!.approval!!.error)
    private fun failedError()=Fixtures.thread("approval-failed").data!!.approval!!.error

    private object Fixtures {
        fun read(name: String)=ApprovalTest::class.java.getResource("/fixtures/d09/$name")!!.readText()
        private val texts=ConcurrentHashMap<String,String>()
        fun text(name: String): String=texts.getOrPut(name) { read("$name.json") }
        fun thread(name: String): ThreadQuery=CoreJson.decodeFromString(text(name))
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
     * Host/sync as in TranscriptTest. `thread:` answers are recorded core envelopes; `approval_decide`
     * moves to the recorded `approval-pending` projection with a pending receipt by default.
     * Utility queries (markdown for the History rows) get a plain single-paragraph AST.
     */
    private class ApprovalCore(val saved: SavedHost) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        val operations=ConcurrentHashMap<String, Operation>()
        @Volatile var freed=false
        @Volatile var thread="approval-command"
        @Volatile var ensured=false
        @Volatile var onDecide: ApprovalCore.(String) -> Unit={ id -> thread="approval-pending"; operations[id]=Operation(id, "pending", null) }
        @Volatile private var row=HostView(saved.id,saved.label,null,null,null,"idle",Lifecycle.background,"paired","empty",
            emptyList(),emptyList(),null,null,false,null)
        private var network=true
        private var sequence=0
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
            when (decoded) {
                is EventForeground -> { row=row.copy(lifecycle=Lifecycle.foreground); connect() }
                is EventNetworkChanged -> {
                    val was=network
                    network=decoded.available
                    if (!network) row=row.copy(phase="disabled") else if (!was || row.phase != "ready") connect()
                }
                is EventTimerFired -> if (decoded.timer_id == "sync" && row.phase == "connecting") row=row.copy(phase="ready", sync_state="ready")
                is EventFocus -> {
                    if (decoded.thread_id != null) ensured=true
                    operations[decoded.intent_id]=Operation(decoded.intent_id, if (decoded.thread_id == null) "succeeded" else "pending", null)
                }
                is EventThreadLoadOlder -> operations[decoded.intent_id]=Operation(decoded.intent_id, "pending", null)
                is EventApprovalDecide -> onDecide(decoded.intent_id)
                else -> Unit
            }
            val scopes=mutableListOf("hosts","operations","home","workspaces")
            if (ensured) scopes+=listOf(chatSelector("thread", WS, THREAD), chatSelector("composer", WS, THREAD))
            effects.add(EffectStateChanged("s${sequence++}","1","1",scopes))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray = when {
            selector == "hosts" -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(row),operations.values.toList()),null))
            selector == "operations" -> CoreJson.encodeToString(OperationsQuery(1,"1",OperationsView(operations.values.toList()),null))
            selector == "home" -> CoreJson.encodeToString(HomeQuery(1,"1",HomeView(emptyList(),false,false,emptyList(),null),null))
            selector == "workspaces" -> CoreJson.encodeToString(WorkspacesQuery(1,"1",WorkspacesView(emptyList(),false,false,null,
                HistoryView("",emptyList(),null,false,null)),null))
            selector.startsWith("thread:") -> if (ensured) Fixtures.text(thread) else NOT_FOUND
            selector.startsWith("{") -> markdown(Json.parseToJsonElement(selector).jsonObject)
            else -> NOT_FOUND
        }.encodeToByteArray()
        private fun markdown(q: JsonObject): String {
            val text=q["text"]!!.jsonPrimitive.content
            val bytes=text.encodeToByteArray().size
            val data=when (q["utility"]!!.jsonPrimitive.content) {
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
        const val NOW=1_790_363_190_811L + 65_000
        private const val NOT_FOUND="""{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":"Unknown thread."}}"""
    }
}

package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * D-09 approval decision rules over real core `thread:` projections recorded from the core's
 * approval harness (fixtures/d09/README.md).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35])
class ApprovalTest {
    private val store = Store()

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

    private object Fixtures {
        fun read(name: String)=ApprovalTest::class.java.getResource("/fixtures/d09/$name")!!.readText()
        private val texts=ConcurrentHashMap<String,String>()
        fun text(name: String): String=texts.getOrPut(name) { read("$name.json") }
        fun thread(name: String): ThreadQuery=CoreJson.decodeFromString(text(name))
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
        private const val NOT_FOUND="""{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":"Unknown thread."}}"""
    }
}

package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CompanionTest {
    // ---- Roster JSON ----

    @Test fun companionQueryDecodesTheCoreViewAndIgnoresUnknownFields() {
        val query = CoreJson.decodeFromString(CompanionQuery.serializer(), """{
            "api_version":1,"revision":"9","error":null,"data":{
            "loaded":true,"loading":false,"saving":false,"supported":true,"can_edit":true,"revision":"3","error":null,"future":1,
            "roster":{"version":1,"active_id":"c1","companions":[
              {"id":"c1","name":"Juniper","character":"moss","home_workspace_id":"ws","thread_id":"t1","provider":"claude","model":"opus","orders":"Run tests."},
              {"id":"c2","name":"Wren"}]},
            "crew":{"workspace_id":"ws","thread_id":"t1","loaded":true,"loading":false,"error":null,"links":[
              {"link_id":"l1","workspace_id":"other","parent_workspace_id":"ws","local_thread_id":"child","title":"Fix CI","provider":"codex",
               "status":"waiting_approval","summary":"","updated_at_ms":5,"hidden":false}]}}}""")
        val view = query.data!!
        assertEquals("3", view.revision)
        assertEquals("Juniper", activeCompanion(view.roster)?.name)
        assertEquals(CompanionCharacter.Moss, CompanionCharacter.of(view.roster.companions[0].character))
        // Missing fields take the wire defaults.
        assertEquals("sprout", view.roster.companions[1].character)
        assertEquals("", view.roster.companions[1].thread_id)
        assertEquals(ChildStatus.WaitingApproval, crewStatus(view.crew.links.single()))
    }

    @Test fun saveEventEncodesTheRosterAndDecimalRevision() {
        val roster = seededRoster("ws", id = "c1")
        val json = CoreJson.parseToJsonElement(CoreJson.encodeToString<Event>(
            EventCompanionSave(now_ms = 1, wall_time_ms = 2, intent_id = "i", roster = roster, expected_revision = "0"))).jsonObject
        assertEquals("companion_save", json["type"]!!.jsonPrimitive.content)
        assertEquals("0", json["expected_revision"]!!.jsonPrimitive.content)
        assertTrue(json["expected_revision"]!!.jsonPrimitive.isString)
        val entry = json["roster"]!!.jsonObject["companions"]!!.jsonArray.single().jsonObject
        assertEquals("Sprout", entry["name"]!!.jsonPrimitive.content)
        assertEquals("sprout", entry["character"]!!.jsonPrimitive.content)
        assertEquals("ws", entry["home_workspace_id"]!!.jsonPrimitive.content)
        assertEquals("c1", json["roster"]!!.jsonObject["active_id"]!!.jsonPrimitive.content)
    }

    // ---- Roster rules ----

    @Test fun namesAreOneLineAndClippedTo32BytesWithoutSplittingCharacters() {
        assertEquals("Juniper", cleanCompanionName("  Juni\nper ".replace("\n", "")))
        assertEquals("a b", cleanCompanionName("a\nb"))
        val emoji = "🌱".repeat(10) // 4 bytes each
        assertEquals("🌱".repeat(8), cleanCompanionName(emoji))
        assertEquals("é".repeat(16), clipUtf8("é".repeat(20), 32))
        assertEquals(1024, clipUtf8("x".repeat(2000), MAX_COMPANION_ORDERS_BYTES).length)
    }

    @Test fun addRemoveAndSwitchKeepAtLeastOneAndAtMostEight() {
        var roster = seededRoster("ws", id = "a")
        assertNull(roster.removing("a"))
        assertNull(roster.activating("a"))
        roster = roster.adding(CompanionEntry(id = "b", name = "Moss", character = "moss"))!!
        assertEquals("b", roster.active_id)
        assertNull(roster.adding(CompanionEntry(id = "b", name = "Dup")))
        roster = roster.activating("a")!!
        assertEquals("a", activeCompanion(roster)?.id)
        val removed = roster.removing("a")!!
        assertEquals(listOf("b"), removed.companions.map { it.id })
        assertEquals("b", removed.active_id)
        var full = roster
        (3..MAX_COMPANIONS).forEach { full = full.adding(CompanionEntry(id = "c$it", name = "C$it"))!! }
        assertEquals(MAX_COMPANIONS, full.companions.size)
        assertNull(full.adding(CompanionEntry(id = "x", name = "X")))
        // A stale active id falls back to the first companion.
        assertEquals("a", activeCompanion(full.copy(active_id = "gone"))?.id)
    }

    @Test fun suggestedNamesNumberTakenCharacterNames() {
        val roster = seededRoster("ws", id = "a")
        assertEquals("Moss", suggestedName(roster, CompanionCharacter.Moss))
        assertEquals("Sprout 2", suggestedName(roster, CompanionCharacter.Sprout))
        assertEquals("Sprout", suggestedName(null, CompanionCharacter.Sprout))
    }

    // ---- Crew and status ----

    private fun link(id: String, status: String, ws: String = "w", thread: String = id, hidden: Boolean = false, at: Long = 0) =
        CompanionLink(link_id = id, workspace_id = ws, local_thread_id = thread, status = status, hidden = hidden, updated_at_ms = at)

    @Test fun crewStatusesMapToOrchestrationStatuses() {
        val expected = mapOf("running" to ChildStatus.Running, "waiting_approval" to ChildStatus.WaitingApproval,
            "blocked" to ChildStatus.Blocked, "completed" to ChildStatus.Completed, "failed" to ChildStatus.Failed,
            "aborted" to ChildStatus.Aborted, "interrupted" to ChildStatus.Interrupted, "idle" to ChildStatus.Idle, "mystery" to ChildStatus.Idle)
        expected.forEach { (wire, status) -> assertEquals(wire, status, crewStatus(link("l", wire))) }
        assertTrue(ChildStatus.WaitingApproval.needsYou && ChildStatus.Blocked.needsYou && ChildStatus.Failed.needsYou)
        assertFalse(ChildStatus.Running.needsYou || ChildStatus.Completed.needsYou)
        assertEquals("Needs approval", crewStatus(link("l", "waiting_approval")).label)
    }

    @Test fun visibleCrewHidesHiddenLinksAndPutsNeedsYouFirst() {
        val crew = CompanionCrew(links = listOf(link("done", "completed", at = 9), link("run", "running", at = 1),
            link("ask", "waiting_approval", at = 0), link("gone", "running", hidden = true), link("new", "completed", at = 10)))
        assertEquals(listOf("ask", "run", "new", "done"), visibleCrew(crew).map { it.link_id })
        assertTrue(visibleCrew(null).isEmpty())
    }

    @Test fun pulseCountsAttentionAndRunningAcrossWorkspacesWithoutDoubleCounting() {
        fun pane(id: String, status: String, attention: Boolean = false, ws: String = "w") =
            Pane(id = id, workspace_id = ws, kind = "chat", title = id, thread_id = id, status = status, attention = attention)
        val panes = listOf(pane("ask", "waiting_approval", attention = true), pane("run", "working"), pane("idle", "idle"))
        val crew = listOf(link("ask", "waiting_approval"), link("blocked", "blocked", ws = "x"), link("run", "running"), link("bg", "running", ws = "x"))
        val pulse = companionPulse(panes, crew)
        assertEquals(CompanionPulse(needsYou = 2, running = 2), pulse)
        assertEquals("2 things need you", companionStatusLine(pulse))
        assertEquals("1 thing needs you", companionStatusLine(CompanionPulse(1, 5)))
        assertEquals("1 chat running", companionStatusLine(CompanionPulse(0, 1)))
        assertEquals("3 chats running", companionStatusLine(CompanionPulse(0, 3)))
        assertEquals("Ready when you are", companionStatusLine(CompanionPulse(0, 0)))
    }

    @Test fun poseFollowsRealStateWithApprovalOutrankingWork() {
        assertEquals(CompanionPose.Paused, companionPose(online = false, approval = true, working = true))
        assertEquals(CompanionPose.Approval, companionPose(online = true, approval = true, working = true))
        assertEquals(CompanionPose.Working, companionPose(online = true, approval = false, working = true))
        assertEquals(CompanionPose.Idle, companionPose(online = true, approval = false, working = false))
    }

    @Test fun notificationsForCompanionThreadsCarryTheCompanionName() {
        val roster = CompanionRoster(active_id = "a", companions = listOf(
            CompanionEntry(id = "a", name = "Juniper", home_workspace_id = "ws", thread_id = "t1"),
            CompanionEntry(id = "b", name = "Nobody")))
        CompanionThreads.update("host", roster)
        assertEquals("Juniper", CompanionThreads.name("host", "ws", "t1"))
        assertNull(CompanionThreads.name("host", "ws", "t2"))
        assertNull(CompanionThreads.name("other", "ws", "t1"))
        assertEquals("Juniper: Reply ready", companionNotificationTitle("Juniper", "Reply ready"))
        assertEquals("Juniper", companionNotificationTitle("Juniper", ""))
        assertEquals("Reply ready", companionNotificationTitle(null, "Reply ready"))
        assertEquals("a", companionFor(roster, "ws", "t1")?.id)
        CompanionThreads.update("host", null)
        assertNull(CompanionThreads.name("host", "ws", "t1"))
    }

    // ---- Session over a fake core ----

    private class Core : CompanionCore {
        override val views = MutableStateFlow<Map<String, JsonElement>>(emptyMap())
        override val operations = MutableStateFlow<OperationsQuery?>(null)
        val sent = mutableListOf<Event>()
        var handle: (Event) -> Unit = {}
        private val settled = mutableListOf<Operation>()
        override suspend fun query(selector: String) = views.value[selector] ?: error("missing_fixture")
        override suspend fun send(event: (Long, Long) -> Event) { val value = event(100, 200); sent += value; handle(value) }
        fun settle(id: String, state: String, code: String? = null) {
            settled += Operation(id, state, code?.let { LocalError(domain = "companion", code = it, message = "fixture") })
            operations.value = OperationsQuery(1, settled.size.toString(), OperationsView(settled.toList()), null)
        }
        fun companion(revision: String, roster: CompanionRoster, loading: Boolean = false) {
            val view = CompanionView(loaded = true, loading = loading, can_edit = true, revision = revision, roster = roster, crew = CompanionCrew())
            views.value = views.value + (COMPANION_SELECTOR to CoreJson.encodeToJsonElement(CompanionQuery.serializer(), CompanionQuery(1, revision, view, null)))
        }
        var jobs = listOf<ManageJob>()
        var newChat = ManageNewChat(selection = ChatSelection(), catalogs = ChatCatalogs())
        fun manage() {
            val view = ManageView(jobs, ManageDirectory(), newChat, can_manage_workspaces = true, can_create_threads = true)
            views.value = views.value + ("manage" to CoreJson.encodeToJsonElement(ManageQuery.serializer(), ManageQuery(1, "1", view, null)))
        }
    }

    private fun fixture(test: suspend CoroutineScope.(Core, CompanionSession) -> Unit) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val core = Core()
        core.companion("4", seededRoster("ws", id = "a"))
        val session = CompanionSession(core, scope)
        try { withTimeout(5000) { scope.test(core, session) } } finally { scope.cancel() }
    }

    @Test fun saveReappliesTheEditAfterAConflict() = fixture { core, session ->
        val other = seededRoster("ws", id = "a").adding(CompanionEntry(id = "b", name = "Wren", character = "vireo"))!!
        core.handle = { event ->
            if (event is EventCompanionSave) {
                if (core.sent.count { it is EventCompanionSave } == 1) {
                    // Another device saved first: the core fails the write and re-reads.
                    core.settle(event.intent_id, "failed", "conflict")
                    core.companion("5", other)
                } else {
                    core.companion("6", event.roster)
                    core.settle(event.intent_id, "succeeded")
                }
            }
        }
        val result = session.update { it.adding(CompanionEntry(id = "c", name = "Moss", character = "moss")) }
        assertEquals(CompanionSave.Saved, result)
        val saves = core.sent.filterIsInstance<EventCompanionSave>()
        assertEquals(listOf("4", "5"), saves.map { it.expected_revision })
        assertEquals(listOf("a", "b", "c"), saves.last().roster.companions.map { it.id })
        assertEquals("6", session.view.value?.revision)
    }

    @Test fun nonConflictFailuresAndNoOpEditsDoNotRetry() = fixture { core, session ->
        core.handle = { event -> if (event is EventCompanionSave) core.settle(event.intent_id, "failed", "insufficient_scope") }
        val failed = session.update { it.replacing(it.companions[0].copy(name = "Fern")) }
        assertTrue(failed is CompanionSave.Failed)
        assertEquals("insufficient_scope", (failed as CompanionSave.Failed).code)
        assertEquals(1, core.sent.count { it is EventCompanionSave })
        assertEquals(CompanionSave.Unchanged, session.update { null })
        assertEquals(CompanionSave.Unchanged, session.update { it })
        assertEquals(1, core.sent.count { it is EventCompanionSave })
    }

    @Test fun createThreadUsesTheCompanionBrainAndRecordsTheThread() = fixture { core, session ->
        core.handle = { event ->
            when (event) {
                is EventNewChatSelect -> {
                    core.newChat = ManageNewChat(workspace_id = event.workspace_id,
                        selection = ChatSelection(provider = event.provider ?: "codex", model = event.model ?: "fast"),
                        catalogs = ChatCatalogs(models = listOf(ChatChoice("fast", "Fast"), ChatChoice("deep", "Deep"))), can_create = true)
                    core.manage(); core.settle(event.intent_id, "succeeded")
                }
                is EventThreadCreate -> {
                    core.jobs = core.jobs + ManageJob(event.intent_id, "thread_create", "succeeded", event.workspace_id, "web-thread-1")
                    core.manage(); core.settle(event.intent_id, "succeeded")
                }
                is EventCompanionSave -> { core.companion("5", event.roster); core.settle(event.intent_id, "succeeded") }
                else -> Unit
            }
        }
        val companion = CompanionEntry(id = "a", name = "Sprout", home_workspace_id = "ws", provider = "claude", model = "deep")
        assertEquals(CompanionSave.Saved, session.createThread(companion, "ws"))
        val create = core.sent.filterIsInstance<EventThreadCreate>().single()
        assertEquals("claude", create.provider)
        assertEquals("deep", create.model)
        assertEquals("web-thread-1", session.view.value?.roster?.companions?.single()?.thread_id)
        val rename = core.sent.filterIsInstance<EventThreadRename>().single()
        assertEquals("Sprout", rename.title)
        assertEquals("web-thread-1", rename.thread_id)
    }
}

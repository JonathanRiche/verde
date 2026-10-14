package dev.verdeai.app

import androidx.compose.ui.geometry.Offset
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

    @Test fun activityListsCrewPlusOtherRunningChatsDedupedAndMatchesTheHeaderCount() {
        fun pane(id: String, status: String, ws: String = "w", attention: Boolean = false, kind: String = "chat") =
            Pane(id = "p-$id", workspace_id = ws, kind = kind, title = "Title $id", thread_id = id, status = status, attention = attention)
        // Three chats running from the CLI, none linked to the companion; one terminal; one idle chat.
        val panes = listOf(pane("cli1", "working"), pane("cli2", "running", ws = "x"), pane("cli3", "waiting"),
            pane("term", "working", kind = "terminal"), pane("idle", "idle"), pane("mine", "working"))
        val hidden = setOf("mine")
        val bare = companionActivity(panes, emptyList(), hidden)
        assertEquals(listOf("cli1", "cli2", "cli3"), bare.map { it.threadId }.sorted())
        assertTrue(bare.all { it.status == ChildStatus.Running && it.linkId == null })
        assertEquals("Title cli2", bare.single { it.threadId == "cli2" }.title)
        val pulse = companionPulse(panes, emptyList(), hidden)
        assertEquals(3, pulse.running)
        // The header's "3 running" has a pill: the activity summary is never empty when running > 0.
        assertEquals("3 running", companionHeaderSuffix(0, pulse.running))
        assertEquals("3 running", activitySummary(bare.map { it.status }))

        // A crew link for a running chat appears once; an idle link whose chat is running reads as running.
        val crew = listOf(link("cli1", "idle"), link("done", "completed"), link("ask", "waiting_approval", ws = "x"))
        val mixed = companionActivity(panes, crew, hidden)
        assertEquals(5, mixed.size)
        assertEquals(mixed.size, mixed.map { it.workspaceId to it.threadId }.toSet().size)
        assertEquals("ask", mixed.first().threadId)
        assertEquals(ChildStatus.Running, mixed.single { it.threadId == "cli1" }.status)
        assertEquals("l:cli1", mixed.single { it.threadId == "cli1" }.key)
        assertEquals(companionPulse(panes, crew, hidden).running, mixed.count { it.status.running })
        assertEquals("3 running \u00b7 1 waiting \u00b7 1 done", activitySummary(mixed.map { it.status }))
        // The companion's own conversation never shows as activity.
        assertTrue(companionActivity(panes, listOf(link("mine", "running")), hidden).none { it.threadId == "mine" })
    }

    @Test fun headerCountAlwaysHasAPanelToToggle() {
        fun snapshot(panes: List<Pane>, crew: List<CompanionLink> = emptyList()): CompanionSnapshot {
            val needs = panes.filter { it.attention || it.status == "waiting_approval" }
            return CompanionSnapshot(null, needs, crew, companionPulse(panes, crew), bubbleNeedKeys(needs, crew, null), false, null,
                companionActivity(panes, crew))
        }
        val running = snapshot(listOf(Pane(id = "p", workspace_id = "w", kind = "chat", title = "t", thread_id = "t", status = "working")))
        assertEquals(StripPanel.Crew, headerPanel(running))
        assertEquals(StripPanel.Crew, shownPanel(StripPanel.Crew, running))
        assertNull(shownPanel(StripPanel.Needs, running))
        val asking = snapshot(listOf(Pane(id = "p", workspace_id = "w", kind = "chat", title = "t", thread_id = "t", status = "waiting_approval", attention = true)))
        assertEquals(StripPanel.Needs, headerPanel(asking))
        val idle = snapshot(emptyList())
        assertNull(companionHeaderSuffix(idle.needKeys.size, idle.pulse.running))
        assertNull(headerPanel(idle))
        assertNull(shownPanel(StripPanel.Crew, idle))
    }

    @Test fun companionThreadIdsCoverCurrentAndPastConversations() {
        val roster = CompanionRoster(version = 1, active_id = "a", companions = listOf(
            CompanionEntry(id = "a", name = "Moss", thread_id = "now", history = listOf(CompanionPastConversation("old1"), CompanionPastConversation("old2"))),
            CompanionEntry(id = "b", name = "Wren", history = listOf(CompanionPastConversation("old3")))))
        assertEquals(setOf("now", "old1", "old2", "old3"), companionThreadIds(roster))
        assertTrue(companionThreadIds(null).isEmpty())
    }

    @Test fun compactSheetLabels() {
        assertEquals("1 needs you", needsLabel(1))
        assertEquals("3 need you", needsLabel(3))
        assertNull(crewSummary(emptyList()))
        assertEquals("2 running \u00b7 1 waiting \u00b7 1 done", crewSummary(listOf(link("a", "running"), link("b", "running"),
            link("c", "blocked"), link("d", "completed"), link("e", "aborted"))))
        assertEquals("1 in crew", crewSummary(listOf(link("x", "idle"))))
        assertEquals("2 in crew", crewSummary(listOf(link("x", "idle"), link("y", "interrupted"))))
        assertEquals("3 need you", companionHeaderSuffix(3, 2))
        assertEquals("2 running", companionHeaderSuffix(0, 2))
        assertNull(companionHeaderSuffix(0, 0))
        val models = listOf(ChatChoice("haiku", "Haiku 5.5"), ChatChoice("opus", "Opus 5.5"))
        val efforts = listOf(ChatChoice("", "Default"), ChatChoice("low", "Low"))
        assertEquals("Haiku 5.5 \u00b7 Low", compactSettingsLabel(models, efforts, ChatSelection(model = "haiku", effort = "low")))
        assertEquals("Haiku 5.5 \u00b7 Default", compactSettingsLabel(models, efforts, ChatSelection()))
        assertEquals("Opus 5.5", compactSettingsLabel(models, emptyList(), ChatSelection(model = "opus")))
        assertEquals("custom-model", compactSettingsLabel(models, emptyList(), ChatSelection(model = "custom-model")))
        assertEquals("Model", compactSettingsLabel(emptyList(), emptyList(), ChatSelection()))
    }

    @Test fun brainChangesApplyInPlaceUnlessAnOngoingConversationChangesProvider() {
        val now = ChatSelection(provider = "claude", model = "opus", effort = "high")
        assertEquals(BrainChange.None, classifyBrainChange("t1", "claude", false, now, now.copy(access = "full_access")))
        assertEquals(BrainChange.InPlace, classifyBrainChange("t1", "claude", false, now, now.copy(model = "haiku")))
        assertEquals(BrainChange.InPlace, classifyBrainChange("t1", "claude", false, now, now.copy(effort = "low")))
        assertEquals(BrainChange.InPlace, classifyBrainChange("t1", "claude", false, now, now.copy(speed = "on")))
        assertEquals(BrainChange.HandOff, classifyBrainChange("t1", "claude", false, now, ChatSelection(provider = "codex", model = "gpt")))
        // An empty (uncommitted) thread or no thread at all switches provider in place.
        assertEquals(BrainChange.InPlace, classifyBrainChange("t1", "claude", true, now, ChatSelection(provider = "codex")))
        assertEquals(BrainChange.InPlace, classifyBrainChange("", null, false, now, ChatSelection(provider = "codex")))
        // Unknown thread provider: trust the roster and change in place.
        assertEquals(BrainChange.InPlace, classifyBrainChange("t1", null, false, now, ChatSelection(provider = "codex")))
    }

    @Test fun brainRosterPayloadAndLabels() {
        val entry = CompanionEntry(id = "a", name = "Moss", character = "moss", home_workspace_id = "ws", thread_id = "t1", orders = "Test first.")
        val next = withBrain(entry, ChatSelection(provider = "codex", model = "gpt-5", effort = "high", speed = "on"))
        assertEquals("codex", next.provider)
        assertEquals("gpt-5", next.model)
        assertEquals(entry.copy(provider = "codex", model = "gpt-5"), next)
        assertEquals("", withBrain(entry, ChatSelection()).model)
        val roster = seededRoster("ws", id = "a").replacing(next)
        assertEquals("codex", activeCompanion(roster)?.provider)
        assertEquals("Claude \u00b7 Opus 5.5 \u00b7 High", brainLabel("Claude", "Opus 5.5", "High"))
        assertEquals("Claude \u00b7 Opus 5.5", brainLabel("Claude", "Opus 5.5", null))
        assertEquals("Codex", brainLabel("Codex", " ", ""))
        assertEquals("Default brain", brainLabel(null, null, null))
        val chat = ManageNewChat(workspace_id = "ws", selection = ChatSelection(provider = "claude", model = "sonnet"),
            catalogs = ChatCatalogs(models = listOf(ChatChoice("sonnet", "Sonnet"), ChatChoice("opus", "Opus"), ChatChoice("old", "Old", enabled = false)),
                efforts = listOf(ChatChoice("", "Default"), ChatChoice("high", "High"))))
        assertEquals(ChatSelection(provider = "claude", model = "opus", effort = "high"), brainSelection(chat, "opus", "high", "on"))
        assertEquals(chat.selection, brainSelection(chat, "old", "extreme", null))
        val (title, body) = brainSwitchDialog("Moss", "Claude", "Codex")
        assertEquals("Switch Moss to Codex?", title)
        assertEquals("Moss keeps this conversation. Claude will write a quick handoff brief first, then Codex takes over with the brief and recent history.", body)
        assertTrue(brainSwitchDialog("Moss", null, "Codex").second.contains("The current brain will write"))
    }

    private fun past(thread: String, title: String = thread, ended: Long = 1) = CompanionPastConversation(thread_id = thread, title = title, ended_at_ms = ended)

    @Test fun historyPushDedupesAndCapsAtTwelve() {
        var history = emptyList<CompanionPastConversation>()
        (1..14).forEach { history = pushHistory(history, past("t$it")) }
        assertEquals(MAX_CONVERSATION_HISTORY, history.size)
        assertEquals("t14", history.first().thread_id)
        assertEquals("t3", history.last().thread_id)
        history = pushHistory(history, past("t10", title = "again"))
        assertEquals(listOf("t10", "t14", "t13"), history.take(3).map { it.thread_id })
        assertEquals(1, history.count { it.thread_id == "t10" })
        assertEquals("again", history.first().title)
    }

    @Test fun newConversationResumeAndForgetUpdateTheRoster() {
        val entry = CompanionEntry(id = "a", name = "Moss", home_workspace_id = "ws", thread_id = "t2", provider = "codex", model = "gpt-5",
            history = listOf(past("t1", "Fix CI").copy(provider = "claude", model = "opus")))
        val roster = CompanionRoster(active_id = "a", companions = listOf(entry))
        val fresh = activeCompanion(rosterWithNewConversation(roster, "a", "Deploy", 50))!!
        assertEquals("", fresh.thread_id)
        assertEquals(listOf("t2", "t1"), fresh.history.map { it.thread_id })
        assertEquals(CompanionPastConversation("t2", "Deploy", "codex", "gpt-5", 50), fresh.history.first())
        // Nothing to archive without a current conversation.
        assertNull(rosterWithNewConversation(roster.replacing(fresh), "a", "x", 60))
        val resumed = activeCompanion(rosterResuming(roster, "a", "t1", "Deploy", 70))!!
        assertEquals("t1", resumed.thread_id)
        assertEquals("claude", resumed.provider)
        assertEquals("opus", resumed.model)
        assertEquals(listOf("t2"), resumed.history.map { it.thread_id })
        assertEquals(70L, resumed.history.single().ended_at_ms)
        // Resuming from an empty current conversation archives nothing.
        val fromFresh = activeCompanion(rosterResuming(roster.replacing(fresh), "a", "t1", "x", 80))!!
        assertEquals(listOf("t2"), fromFresh.history.map { it.thread_id })
        assertNull(rosterResuming(roster, "a", "missing", "x", 1))
        val forgotten = activeCompanion(rosterForgetting(roster, "a", "t1"))!!
        assertTrue(forgotten.history.isEmpty())
        assertEquals("t2", forgotten.thread_id)
        assertNull(rosterForgetting(roster, "a", "nope"))
    }

    @Test fun conversationTitlesAndBrainSwitchStatus() {
        assertEquals("Fix CI", conversationTitle("Fix CI", "Moss", "hello"))
        assertEquals("check the build", conversationTitle("Moss", "Moss", "\ncheck the build\nmore"))
        assertEquals("deploy", conversationTitle("New Chat", "Moss", "deploy"))
        assertEquals("Conversation", conversationTitle(null, "Moss", null))
        assertNull(handoffStatus(null))
        assertEquals("Switching brain\u2026", handoffStatus(CompanionBrainSwitch("i")))
        assertEquals("Handing off to Codex\u2026", handoffStatus(CompanionBrainSwitch("i", "briefing", from = "Claude \u00b7 opus", to = "Codex \u00b7 gpt-5")))
        assertEquals("Switched to Codex", handoffStatus(CompanionBrainSwitch("i", "switched", to = "Codex")))
        assertNull(handoffStatus(CompanionBrainSwitch("i", "failed", error_code = "companion_busy")))
        assertEquals("Moss is still working. Wait for the current turn to finish, then switch.", brainSwitchError("companion_busy", "Moss"))
        assertEquals("Codex", brainProviderOf("Codex \u00b7 gpt-5"))
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

    // ---- Bubble ----

    private val area = bubbleArea(width = 400f, height = 800f, size = 56f, insetLeft = 0f, insetTop = 24f, insetRight = 0f,
        insetBottom = 48f, reserveTop = 56f, reserveBottom = 88f, margin = 8f)

    @Test fun bubbleAreaExcludesInsetsTopBarAndComposerRegion() {
        assertEquals(BubbleArea(left = 8f, top = 88f, right = 392f, bottom = 656f), area)
        // A tall keyboard gives up the composer reserve first, but never the safe insets.
        val typing = bubbleArea(400f, 800f, 56f, 0f, 24f, 0f, insetBottom = 600f, reserveTop = 56f, reserveBottom = 88f, margin = 8f)
        assertEquals(192f, typing.bottom)
        assertTrue(typing.bottom - typing.top >= 56f)
        assertTrue(typing.top >= 32f)
    }

    @Test fun droppedBubbleSnapsToTheNearerEdgeWithClampedHeight() {
        assertEquals(BubblePlacement(BubbleEdge.Left, 0f), snapBubble(Offset(100f, -50f), area, 56f))
        assertEquals(BubblePlacement(BubbleEdge.Right, 1f), snapBubble(Offset(250f, 2000f), area, 56f))
        val middle = snapBubble(Offset(300f, 88f + 256f), area, 56f)
        assertEquals(BubbleEdge.Right, middle.edge)
        assertEquals(.5f, middle.fraction, 1e-4f)
        // Placement maps back inside the area, flush with the chosen side.
        assertEquals(Offset(8f, 88f), bubbleOffset(BubblePlacement(BubbleEdge.Left, 0f), area, 56f))
        assertEquals(Offset(336f, 600f), bubbleOffset(BubblePlacement(BubbleEdge.Right, 1f), area, 56f))
        assertEquals(Offset(336f, 600f), bubbleOffset(BubblePlacement(BubbleEdge.Right, 7f), area, 56f))
        val round = bubbleOffset(middle, area, 56f)
        assertEquals(middle, snapBubble(round, area, 56f))
    }

    @Test fun badgeCountsEachChatThatNeedsYouOnce() {
        fun pane(id: String, thread: String?, ws: String = "w") = Pane(id = id, workspace_id = ws, kind = if (thread == null) "terminal" else "chat",
            title = id, thread_id = thread, status = "waiting_approval", attention = true)
        val needs = listOf(pane("p1", "a"), pane("p2", null))
        val crew = listOf(link("a", "waiting_approval"), link("b", "blocked"), link("c", "running"), link("d", "failed", ws = "x"))
        val companion = ThreadSummary("home", "t", "Moss", "codex", null, null, true, false, 1, "waiting_approval", "today")
        val keys = bubbleNeedKeys(needs, crew, companion)
        assertEquals(5, keys.size)
        assertEquals(4, bubbleNeedKeys(needs, crew, companion.copy(status = "idle")).size)
        assertEquals("99+", badgeLabel(120))
        assertEquals("Moss, 2 things need you", bubbleDescription("Moss", 2))
        assertEquals("Moss, 1 thing needs you", bubbleDescription("Moss", 1))
        assertEquals("Moss, nothing needs you", bubbleDescription("Moss", 0))
    }

    @Test fun popupOnlyForNewNeedsOrNewerRepliesWhileCollapsed() {
        // The first snapshot primes without announcing what was already there.
        var step = bubbleStep(BubbleSeen(), setOf("a"), 10, collapsed = true)
        assertNull(step.popup)
        step = bubbleStep(step.seen, setOf("a"), 10, collapsed = true)
        assertNull(step.popup)
        step = bubbleStep(step.seen, setOf("a", "b"), 10, collapsed = true)
        assertEquals(BubblePopup.NeedsYou(2), step.popup)
        // A need that left and came back is new again; one that just stays is not.
        step = bubbleStep(step.seen, setOf("b"), 10, collapsed = true)
        assertNull(step.popup)
        step = bubbleStep(step.seen, setOf("b"), 20, collapsed = true)
        assertEquals(BubblePopup.Reply, step.popup)
        step = bubbleStep(step.seen, setOf("b"), 20, collapsed = true)
        assertNull(step.popup)
        // An open sheet (or hidden bubble) marks things seen silently.
        step = bubbleStep(step.seen, setOf("b", "c"), 30, collapsed = false)
        assertNull(step.popup)
        step = bubbleStep(step.seen, setOf("b", "c"), 30, collapsed = true)
        assertNull(step.popup)
        // A missing reply time (turn running) never pops or rewinds.
        step = bubbleStep(step.seen, setOf("b", "c"), null, collapsed = true)
        assertNull(step.popup)
        assertEquals(30L, step.seen.replyAt)
        assertEquals("Done: tests pass.", replyPreview("**Summary:** Done: tests pass. More detail\nsecond line"))
        assertEquals(80, replyPreview("x".repeat(200)).length)
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

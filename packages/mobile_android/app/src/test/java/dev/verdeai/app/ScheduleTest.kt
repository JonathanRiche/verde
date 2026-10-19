package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

class ScheduleTest {
    private val utc: ZoneId = ZoneOffset.UTC
    // Sunday 18 October 2026, 10:00 UTC.
    private val now = LocalDate.of(2026, 10, 18).atTime(10, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
    private val home = ScheduleHome("Juniper", "ws", "t1")
    private val hour = 3_600_000L

    private fun entry(id: String = "s1", repeat: String = "daily", time: String = "09:00", days: List<Int> = emptyList(),
        every: Long? = null, at: Long? = null, enabled: Boolean = true, next: Long? = null) = ScheduleEntry(id = id, name = "Morning CI check",
        prompt = "Check CI.", target_kind = "thread", target_workspace_id = "ws", target_thread_id = "t1", repeat_kind = repeat,
        repeat_at_ms = at, repeat_every_minutes = every, repeat_time = time, repeat_weekdays = days, enabled = enabled, next_run_ms = next)

    // ---- Human repeat ----

    @Test fun repeatLabelsReadLikeASentence() {
        assertEquals("Weekdays at 09:00", repeatLabel(entry(days = listOf(5, 1, 2, 3, 4)), now, utc))
        assertEquals("Daily at 07:30", repeatLabel(entry(time = "07:30"), now, utc))
        assertEquals("Daily at 07:30", repeatLabel(entry(time = "07:30", days = (0..6).toList()), now, utc))
        assertEquals("Weekends at 10:00", repeatLabel(entry(time = "10:00", days = listOf(6, 0)), now, utc))
        // Custom days read Monday first.
        assertEquals("Mon, Wed, Sun at 08:00", repeatLabel(entry(time = "08:00", days = listOf(0, 3, 1)), now, utc))
        assertEquals("Every 2 hours", repeatLabel(entry(repeat = "interval", every = 120), now, utc))
        assertEquals("Every hour", repeatLabel(entry(repeat = "interval", every = 60), now, utc))
        assertEquals("Every 45 minutes", repeatLabel(entry(repeat = "interval", every = 45), now, utc))
        assertEquals("Every day", repeatLabel(entry(repeat = "interval", every = 1440), now, utc))
        assertEquals("Every 90 minutes", repeatLabel(entry(repeat = "interval", every = 90), now, utc))
    }

    @Test fun onceShowsTheDayRelativeToNow() {
        fun at(day: Int, h: Int, m: Int) = LocalDate.of(2026, 10, day).atTime(h, m).toInstant(ZoneOffset.UTC).toEpochMilli()
        assertEquals("Once · Tue 14:30", repeatLabel(entry(repeat = "once", at = at(20, 14, 30)), now, utc))
        assertEquals("Once · Today 18:05", repeatLabel(entry(repeat = "once", at = at(18, 18, 5)), now, utc))
        assertEquals("Once · Tomorrow 09:00", repeatLabel(entry(repeat = "once", at = at(19, 9, 0)), now, utc))
        assertEquals("Once · Sat 31 Oct 08:00", repeatLabel(entry(repeat = "once", at = at(31, 8, 0)), now, utc))
        // The phone's zone decides the day and time shown.
        assertEquals("Once · Tue 16:30", repeatLabel(entry(repeat = "once", at = at(20, 14, 30)), now, ZoneId.of("Europe/Berlin")))
        assertEquals("Once", repeatLabel(entry(repeat = "once", at = null), now, utc))
    }

    // ---- Next run and last status ----

    @Test fun nextRunUsesTheDaemonClock() {
        assertEquals("Paused", nextRunLabel(entry(enabled = false, next = now + hour), now))
        assertEquals("Next in 3h", nextRunLabel(entry(next = now + 3 * hour + 59_000), now))
        assertEquals("Next in 1h 30m", nextRunLabel(entry(next = now + 90 * 60_000), now))
        assertEquals("Next in 12m", nextRunLabel(entry(next = now + 12 * 60_000), now))
        assertEquals("Next in under a minute", nextRunLabel(entry(next = now + 30_000), now))
        assertEquals("Due now", nextRunLabel(entry(next = now - 1), now))
        assertEquals("Next in 2d", nextRunLabel(entry(next = now + 50 * hour), now))
        assertEquals("Not scheduled", nextRunLabel(entry(next = null), now))
        // The list's now_ms advances with phone time since it arrived; before a list, phone time.
        assertEquals(5_000L + 2_000L, hostNow(viewNowMs = 5_000, receivedAtMs = 100, phoneNowMs = 2_100))
        assertEquals(5_000L, hostNow(viewNowMs = 5_000, receivedAtMs = 100, phoneNowMs = 50))
        assertEquals(42L, hostNow(viewNowMs = 0, receivedAtMs = 0, phoneNowMs = 42))
    }

    @Test fun lastRunSummarizesTheOutcome() {
        val base = entry()
        assertEquals("Not run yet", lastRunLabel(base, now))
        assertEquals("Last run ok · 2h ago", lastRunLabel(base.copy(last_status = "ok", last_run_ms = now - 2 * hour, run_count = 3), now))
        assertEquals("Last run ok · just now", lastRunLabel(base.copy(last_status = "ok", last_run_ms = now - 10_000, run_count = 1), now))
        assertEquals("Last run late · 5m ago", lastRunLabel(base.copy(last_status = "late", last_run_ms = now - 5 * 60_000), now))
        val failed = base.copy(last_status = "failed", last_error = "\n  Provider not configured\nstack", last_run_ms = now - hour)
        assertEquals("Failed: Provider not configured", lastRunLabel(failed, now))
        assertTrue(lastRunFailed(failed))
        assertEquals("Failed: no details", lastRunLabel(base.copy(last_status = "failed"), now))
    }

    @Test fun titlesAndTargetsFallBackSensibly() {
        assertEquals("Morning CI check", scheduleTitle(entry()))
        assertEquals("Check CI.", scheduleTitle(entry().copy(name = " ", prompt = "\n Check CI.\nThen more")))
        val labels = mapOf("ws" to "verde", "api" to "api")
        assertEquals("Sends to Juniper's chat", targetLabel(entry(), home, labels::get))
        assertEquals("Sends to a chat in verde", targetLabel(entry().copy(target_thread_id = "other"), home, labels::get))
        assertEquals("New chat in api · Claude · opus", targetLabel(entry().copy(target_kind = "new_chat", target_workspace_id = "api",
            target_thread_id = "", target_provider = "claude", target_model = "opus"), home, labels::get))
    }

    // ---- Form → intent ----

    private fun encode(event: Event) = CoreJson.parseToJsonElement(CoreJson.encodeToString<Event>(event)).jsonObject

    @Test fun companionChatIsTheDefaultTargetAndParent() {
        val draft = exampleDraft(home, "ws", now, utc)
        assertEquals(ScheduleSendTo.Companion, draft.sendTo)
        assertNull(draftProblem(draft, home, now))
        val json = encode(createEvent(draft, home, 1, 2, "i")!!)
        assertEquals("schedule_create", json["type"]!!.jsonPrimitive.content)
        assertEquals("Morning CI check", json["name"]!!.jsonPrimitive.content)
        assertEquals("mobile", json["created_by"]!!.jsonPrimitive.content)
        assertTrue(json["enabled"]!!.jsonPrimitive.boolean)
        val target = json["target"]!!.jsonObject
        assertEquals("thread", target["kind"]!!.jsonPrimitive.content)
        assertEquals("ws", target["workspace_id"]!!.jsonPrimitive.content)
        assertEquals("t1", target["thread_id"]!!.jsonPrimitive.content)
        assertEquals("ws", json["parent_workspace_id"]!!.jsonPrimitive.content)
        assertEquals("t1", json["parent_thread_id"]!!.jsonPrimitive.content)
        val repeat = json["repeat"]!!.jsonObject
        assertEquals("daily", repeat["kind"]!!.jsonPrimitive.content)
        assertEquals("09:00", repeat["time"]!!.jsonPrimitive.content)
        assertEquals(listOf(1, 2, 3, 4, 5), repeat["weekdays"]!!.jsonArray.map { it.jsonPrimitive.int })
    }

    @Test fun aBlankNameIsLeftToTheDaemonAndNewChatsCarryProviderAndModel() {
        val draft = ScheduleDraft(prompt = "  Summarize open PRs.  ", name = "  ", sendTo = ScheduleSendTo.NewChat, workspaceId = "api",
            provider = "claude", model = "", repeat = RepeatChoice.Interval, every = "2", unit = IntervalUnit.Hours)
        val event = createEvent(draft, home, 1, 2, "i")!!
        assertNull(event.name)
        assertEquals("Summarize open PRs.", event.prompt)
        assertEquals(ScheduleTarget(kind = "new_chat", workspace_id = "api", provider = "claude"), event.target)
        assertEquals(ScheduleRepeat(kind = "interval", every_minutes = 120), event.repeat)
        // Results still report back to the companion.
        assertEquals("t1", event.parent_thread_id)
        assertEquals("opus", draft.copy(model = "opus").targetPayload(home)?.model)
        // Without a companion conversation there is no parent.
        val orphan = createEvent(draft, ScheduleHome("Juniper", "ws", ""), 1, 2, "i")!!
        assertNull(orphan.parent_thread_id)
        assertNull(orphan.parent_workspace_id)
    }

    @Test fun onceMapsTheChosenLocalTimeToEpochMillis() {
        val berlin = ZoneId.of("Europe/Berlin")
        val at = localAtMs(LocalDate.of(2026, 10, 20), 14, 30, berlin)
        assertEquals(LocalDate.of(2026, 10, 20).atTime(12, 30).toInstant(ZoneOffset.UTC).toEpochMilli(), at)
        val draft = ScheduleDraft(prompt = "Ship it.", repeat = RepeatChoice.Once, atMs = at)
        assertEquals(ScheduleRepeat(kind = "once", at_ms = at), draft.repeatPayload())
        assertEquals(now + hour, nextHourMs(now + 1, utc))
    }

    @Test fun saveStaysDisabledUntilTheDraftIsValid() {
        val ok = ScheduleDraft(prompt = "Check CI.")
        assertNull(draftProblem(ok, home, now))
        assertEquals("Write what the task should do.", draftProblem(ok.copy(prompt = "  \n"), home, now))
        assertEquals("Keep the prompt under 16 KiB.", draftProblem(ok.copy(prompt = "x".repeat(16385)), home, now))
        assertEquals("Juniper's chat isn't set up yet.", draftProblem(ok, ScheduleHome("Juniper", "ws", ""), now))
        val newChat = ok.copy(sendTo = ScheduleSendTo.NewChat, workspaceId = "api")
        assertEquals("Choose a provider for the new chat.", draftProblem(newChat, home, now))
        assertEquals("Choose a workspace.", draftProblem(newChat.copy(workspaceId = "", provider = "codex"), home, now))
        val interval = ok.copy(repeat = RepeatChoice.Interval, unit = IntervalUnit.Minutes)
        assertEquals("Repeat at most every 5 minutes.", draftProblem(interval.copy(every = "4"), home, now))
        assertNull(draftProblem(interval.copy(every = "5"), home, now))
        assertEquals(5L, interval.copy(every = "5").everyMinutes())
        assertEquals("Repeat at least once every 7 days.", draftProblem(interval.copy(every = "169", unit = IntervalUnit.Hours), home, now))
        assertEquals("Enter how often it repeats.", draftProblem(interval.copy(every = ""), home, now))
        val once = ok.copy(repeat = RepeatChoice.Once, atMs = now - 1)
        assertEquals("Choose a time in the future.", draftProblem(once, home, now))
        assertNull(draftProblem(once.copy(atMs = now + hour), home, now))
        val custom = ok.copy(days = DayPreset.Custom, customDays = emptySet())
        assertEquals("Choose at least one day.", draftProblem(custom, home, now))
        assertEquals(listOf(0, 6), custom.copy(customDays = setOf(6, 0)).weekdays())
        assertEquals("Use a time like 09:00.", draftProblem(ok.copy(time = "24:00"), home, now))
        assertTrue(validTime("23:59"))
        assertFalse(validTime("9:00"))
    }

    @Test fun editSendsOnlyWhatChanged() {
        val original = entry(days = listOf(1, 2, 3, 4, 5)).copy(name = "CI")
        val draft = draftOf(original, home)
        assertEquals(ScheduleSendTo.Companion, draft.sendTo)
        assertEquals(DayPreset.Weekdays, draft.days)
        // An untouched form changes nothing, so Save just closes.
        assertTrue(updateEvent(original, draft, home, 1, 2, "i")!!.changesNothing())
        val changed = updateEvent(original, draft.copy(time = "10:15", name = ""), home, 1, 2, "i")!!
        assertEquals("s1", changed.id)
        assertNull(changed.name)
        assertNull(changed.prompt)
        assertNull(changed.target)
        assertNull(changed.enabled)
        assertEquals(ScheduleRepeat(kind = "daily", time = "10:15", weekdays = listOf(1, 2, 3, 4, 5)), changed.repeat)
        val json = encode(changed)
        assertEquals("schedule_update", json["type"]!!.jsonPrimitive.content)
        // Unchanged fields go out as null, which the core treats as "leave as is".
        assertEquals(JsonNull, json["prompt"])
        // An interval of whole hours edits in hours; a past one-off can still be renamed.
        val interval = draftOf(entry(repeat = "interval", every = 180), home)
        assertEquals(IntervalUnit.Hours to "3", interval.unit to interval.every)
        val fired = entry(repeat = "once", at = now - hour, enabled = false)
        assertNull(draftProblem(draftOf(fired, home).copy(name = "Renamed"), home, now, fired))
    }

    @Test fun anotherChatTargetIsKeptOnEdit() {
        val other = entry().copy(target_workspace_id = "api", target_thread_id = "cli-thread")
        val draft = draftOf(other, home)
        assertEquals(ScheduleSendTo.ExistingChat, draft.sendTo)
        assertEquals(ScheduleTarget(kind = "thread", workspace_id = "api", thread_id = "cli-thread"), draft.targetPayload(home))
        assertTrue(updateEvent(other, draft, home, 1, 2, "i")!!.changesNothing())
        val moved = updateEvent(other, draft.copy(sendTo = ScheduleSendTo.Companion), home, 1, 2, "i")!!
        assertEquals(ScheduleTarget(kind = "thread", workspace_id = "ws", thread_id = "t1"), moved.target)
    }

    @Test fun schedulesQueryDecodesTheCoreView() {
        val query = CoreJson.decodeFromString(SchedulesQuery.serializer(), """{"api_version":1,"revision":"2","error":null,"data":{
            "loaded":true,"loading":false,"saving":false,"supported":true,"can_edit":true,"now_ms":1000,"future":1,
            "schedules":[{"id":"a","name":"CI","prompt":"Check CI.","target_kind":"thread","target_workspace_id":"ws","target_thread_id":"t1",
              "repeat_kind":"daily","repeat_time":"09:00","repeat_weekdays":[1,2,3,4,5],"enabled":true,"next_run_ms":5000,"last_status":"ok",
              "last_run_ms":900,"run_count":2},{"id":"b","enabled":false}],
            "busy_ids":["a"],"last_run":{"intent_id":"r","schedule_id":"a","workspace_id":"ws","thread_id":"t1"}}}""")
        val view = query.data!!
        assertEquals(1000L, view.now_ms)
        assertEquals("Weekdays at 09:00", repeatLabel(view.schedules[0], view.now_ms, utc))
        assertEquals("once", view.schedules[1].repeat_kind)
        assertEquals(1, ScheduleUiState(view = view).enabledCount)
        assertEquals(0, ScheduleUiState(view = view, toggling = mapOf("a" to false)).enabledCount)
        // Only a run this phone started offers "Open chat".
        assertNull(ScheduleUiState(view = view).lastRun)
        assertEquals("t1", ScheduleUiState(view = view, runIntent = "r").lastRun?.thread_id)
    }

    // ---- Controller over a fake core ----

    private class Core : CompanionCore {
        override val views = MutableStateFlow<Map<String, JsonElement>>(emptyMap())
        override val operations = MutableStateFlow<OperationsQuery?>(null)
        val sent = mutableListOf<Event>()
        var handle: (Event) -> Unit = {}
        private val settled = mutableListOf<Operation>()
        override suspend fun query(selector: String) = views.value[selector] ?: error("missing_fixture")
        override suspend fun send(event: (Long, Long) -> Event) { val value = event(100, 200); sent += value; handle(value) }
        fun settle(id: String, state: String, code: String? = null, message: String = "fixture") {
            settled += Operation(id, state, code?.let { LocalError(domain = "schedules", code = it, message = message) })
            operations.value = OperationsQuery(1, settled.size.toString(), OperationsView(settled.toList()), null)
        }
        fun schedules(view: SchedulesView) {
            views.value = views.value + (SCHEDULES_SELECTOR to CoreJson.encodeToJsonElement(SchedulesQuery.serializer(), SchedulesQuery(1, "1", view, null)))
        }
    }

    private fun fixture(test: suspend CoroutineScope.(Core, ScheduleController) -> Unit) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val core = Core()
        core.schedules(SchedulesView(loaded = true, can_edit = true, now_ms = 1000, schedules = listOf(entry())))
        val controller = ScheduleController(core, scope) { 50L }
        try { withTimeout(5000) { scope.test(core, controller) } } finally { scope.cancel() }
    }

    @Test fun toggleIsOptimisticAndRevertsOnFailure() = fixture { core, controller ->
        assertEquals(50L, controller.state.value.receivedAtMs)
        core.handle = { event -> if (event is EventScheduleUpdate) core.settle(event.intent_id, "failed", "invalid_params", "The host rejected this scheduled task.") }
        controller.setEnabled(entry(), false)
        val update = core.sent.filterIsInstance<EventScheduleUpdate>().single()
        assertEquals(false, update.enabled)
        assertNull(update.repeat)
        val state = controller.state.first { it.error != null }
        assertEquals("The host rejected this scheduled task.", state.error)
        assertTrue(state.toggling.isEmpty())
        assertEquals(1, state.enabledCount)
    }

    @Test fun runNowOffersTheChatItStarted() = fixture { core, controller ->
        core.handle = { event ->
            if (event is EventScheduleRun) {
                core.schedules(SchedulesView(loaded = true, can_edit = true, now_ms = 2000, schedules = listOf(entry()),
                    last_run = ScheduleRun(intent_id = event.intent_id, schedule_id = event.id, workspace_id = "ws", thread_id = "t1")))
                core.settle(event.intent_id, "succeeded")
            }
        }
        controller.run(entry())
        val run = controller.state.first { it.lastRun != null }.lastRun!!
        assertEquals("s1", run.schedule_id)
        assertEquals("t1", run.thread_id)
        assertNull(controller.state.value.error)
    }

    @Test fun saveShowsCoreValidationAndSkipsNoOpEdits() = fixture { core, controller ->
        core.handle = { event -> if (event is EventScheduleCreate) core.settle(event.intent_id, "failed", "invalid_repeat", "Use a time like 09:00.") }
        var saved = false
        controller.save(null, ScheduleDraft(prompt = "Check CI."), home) { saved = true }
        assertEquals("Use a time like 09:00.", controller.state.first { !it.saving && it.formError != null }.formError)
        assertFalse(saved)
        val original = entry()
        controller.save(original, draftOf(original, home), home) { saved = true }
        assertTrue(saved)
        assertEquals(0, core.sent.count { it is EventScheduleUpdate })
    }
}

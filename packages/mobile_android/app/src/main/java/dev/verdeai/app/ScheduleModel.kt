package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID

/*
 * Scheduled tasks. The daemon owns and fires them; the core's `schedules` selector lists them and
 * its five intents (`schedule_refresh/create/update/delete/run`) map 1:1 to the daemon methods.
 * This file holds the pure presentation and form rules (unit tested) and the per-host controller.
 * Prompts and names are never logged.
 */

internal const val SCHEDULES_SELECTOR = "schedules"
internal const val SCHEDULE_MIN_EVERY_MINUTES = 5L
internal const val SCHEDULE_MAX_EVERY_MINUTES = 10080L
internal const val SCHEDULE_MAX_PROMPT_BYTES = 16384
internal const val SCHEDULE_MAX_NAME_BYTES = 120
internal const val SCHEDULES_UNSUPPORTED = "Update verde on your desktop to use scheduled tasks."

/** Sunday-first, matching the daemon's 0=Sun … 6=Sat. */
internal val DAY_SHORT = listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
private val MONTH_SHORT = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
internal val WEEKDAYS = listOf(1, 2, 3, 4, 5)
/** Display order for day chips: Monday first. */
internal val DAY_ORDER = listOf(1, 2, 3, 4, 5, 6, 0)

private fun utf8Bytes(text: String) = text.toByteArray(Charsets.UTF_8).size

// ---- Presentation (pure, unit tested) ----

/** The daemon clock now: the list's `now_ms` advanced by phone time since it arrived, so no clock skew. */
internal fun hostNow(viewNowMs: Long, receivedAtMs: Long, phoneNowMs: Long): Long =
    if (viewNowMs <= 0 || receivedAtMs <= 0) phoneNowMs else viewNowMs + (phoneNowMs - receivedAtMs).coerceAtLeast(0)

/** "12m", "1h 30m", "3h", "2d" (rounded down; at least one minute). */
internal fun compactSpan(ms: Long): String {
    val minutes = ms.coerceAtLeast(0) / 60_000
    return when {
        minutes < 60 -> "${minutes.coerceAtLeast(1)}m"
        minutes < 24 * 60 -> {
            val h = minutes / 60
            val m = minutes % 60
            if (h < 3 && m > 0) "${h}h ${m}m" else "${h}h"
        }
        else -> "${minutes / (24 * 60)}d"
    }
}

/** Daemon weekdays normalized: valid, distinct, sorted; every day reads as empty. */
internal fun normalizedDays(days: List<Int>): List<Int> {
    val set = days.filter { it in 0..6 }.toSortedSet()
    return if (set.size == 7) emptyList() else set.toList()
}

/** "Weekdays", "Weekends", "Mon, Wed, Fri"; null for every day. */
internal fun daysLabel(days: List<Int>): String? {
    val set = normalizedDays(days)
    return when {
        set.isEmpty() -> null
        set == WEEKDAYS -> "Weekdays"
        set == listOf(0, 6) -> "Weekends"
        else -> DAY_ORDER.filter { it in set }.joinToString(", ") { DAY_SHORT[it] }
    }
}

/** "Every 45 minutes", "Every hour", "Every 2 hours", "Every day". */
internal fun intervalLabel(minutes: Long): String = when {
    minutes > 0 && minutes % 1440 == 0L -> (minutes / 1440).let { if (it == 1L) "Every day" else "Every $it days" }
    minutes > 0 && minutes % 60 == 0L -> (minutes / 60).let { if (it == 1L) "Every hour" else "Every $it hours" }
    else -> if (minutes == 1L) "Every minute" else "Every $minutes minutes"
}

internal fun clockLabel(hour: Int, minute: Int) = String.format(Locale.ROOT, "%02d:%02d", hour, minute)

/** "Today 14:30", "Tomorrow 09:00", "Tue 14:30" within a week, else "Tue 3 Nov 14:30" (with the year when it differs). */
internal fun whenLabel(atMs: Long, nowMs: Long, zone: ZoneId): String {
    val at = Instant.ofEpochMilli(atMs).atZone(zone)
    val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    val days = ChronoUnit.DAYS.between(today, at.toLocalDate())
    val weekday = DAY_SHORT[at.dayOfWeek.value % 7]
    val day = when (days) {
        0L -> "Today"
        1L -> "Tomorrow"
        in 2L..6L -> weekday
        else -> "$weekday ${at.dayOfMonth} ${MONTH_SHORT[at.monthValue - 1]}" + (if (at.year != today.year) " ${at.year}" else "")
    }
    return "$day ${clockLabel(at.hour, at.minute)}"
}

/** "Weekdays at 09:00", "Every 2 hours", "Daily at 07:30", "Once · Tue 14:30". */
internal fun repeatLabel(entry: ScheduleEntry, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String = when (entry.repeat_kind) {
    "once" -> entry.repeat_at_ms?.takeIf { it > 0 }?.let { "Once · ${whenLabel(it, nowMs, zone)}" } ?: "Once"
    "interval" -> entry.repeat_every_minutes?.takeIf { it > 0 }?.let(::intervalLabel) ?: "Repeats"
    "daily" -> {
        val time = entry.repeat_time.ifEmpty { "--:--" }
        daysLabel(entry.repeat_weekdays)?.let { "$it at $time" } ?: "Daily at $time"
    }
    else -> "Repeats"
}

/** "Next in 3h", "Due now" or "Paused", measured on the daemon's clock. */
internal fun nextRunLabel(entry: ScheduleEntry, hostNowMs: Long): String {
    if (!entry.enabled) return "Paused"
    val next = entry.next_run_ms ?: return "Not scheduled"
    val delta = next - hostNowMs
    return when {
        delta <= 0 -> "Due now"
        delta < 60_000 -> "Next in under a minute"
        else -> "Next in ${compactSpan(delta)}"
    }
}

internal fun agoShort(thenMs: Long, nowMs: Long): String =
    if (nowMs - thenMs < 60_000) "just now" else "${compactSpan(nowMs - thenMs)} ago"

/** "Last run ok · 2h ago", "Failed: <first line of the error>", "Not run yet". */
internal fun lastRunLabel(entry: ScheduleEntry, hostNowMs: Long): String {
    val ago = entry.last_run_ms?.takeIf { it > 0 }?.let { agoShort(it, hostNowMs) }
    fun stamped(text: String) = listOfNotNull(text, ago).joinToString(" · ")
    return when (entry.last_status) {
        null -> if (entry.run_count > 0) stamped("Last run") else "Not run yet"
        "ok" -> stamped("Last run ok")
        "queued" -> stamped("Last run queued behind a busy chat")
        "late" -> stamped("Last run late")
        "failed" -> "Failed: " + (entry.last_error?.lineSequence()?.map { it.trim() }?.firstOrNull { it.isNotEmpty() } ?: "no details")
        else -> stamped("Last run ${entry.last_status}")
    }
}

internal fun lastRunFailed(entry: ScheduleEntry) = entry.last_status == "failed"

/** The row title: the name, else the prompt's first line. */
internal fun scheduleTitle(entry: ScheduleEntry): String =
    entry.name.trim().ifEmpty { entry.prompt.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty() }.ifEmpty { "Scheduled task" }

/** The chat a companion's scheduled tasks go to; [ready] once the companion has a conversation. */
internal data class ScheduleHome(val name: String, val workspaceId: String, val threadId: String) {
    val ready get() = workspaceId.isNotEmpty() && threadId.isNotEmpty()
}

internal fun scheduleHome(entry: CompanionEntry): ScheduleHome =
    ScheduleHome(entry.name.ifBlank { CompanionCharacter.of(entry.character).label }, entry.home_workspace_id, entry.thread_id)

/** "Sends to Sprout's chat", "New chat in api · Claude", "Sends to a chat in api". */
internal fun targetLabel(entry: ScheduleEntry, home: ScheduleHome?, workspaceLabel: (String) -> String?): String {
    val where = workspaceLabel(entry.target_workspace_id) ?: "another workspace"
    if (entry.target_kind == "new_chat") {
        val provider = PROVIDERS.find { it.first == entry.target_provider }?.second ?: entry.target_provider
        return listOf("New chat in $where", provider, entry.target_model).filter { it.isNotBlank() }.joinToString(" · ")
    }
    if (home != null && home.ready && entry.target_workspace_id == home.workspaceId && entry.target_thread_id == home.threadId) return "Sends to ${home.name}'s chat"
    return "Sends to a chat in $where"
}

// ---- Form (pure, unit tested) ----

internal enum class ScheduleSendTo { Companion, NewChat, ExistingChat }
internal enum class RepeatChoice { Once, Interval, Daily }
internal enum class IntervalUnit(val minutes: Long) { Minutes(1), Hours(60) }
internal enum class DayPreset { Every, Weekdays, Custom }

/** The "New scheduled task" form. Text fields stay raw; [repeatPayload]/[targetPayload] build the wire values. */
internal data class ScheduleDraft(
    val prompt: String = "",
    val name: String = "",
    val sendTo: ScheduleSendTo = ScheduleSendTo.Companion,
    /** New chat: its workspace, provider and model (blank = default). Existing chat: the original target. */
    val workspaceId: String = "",
    val threadId: String = "",
    val provider: String = "",
    val model: String = "",
    val repeat: RepeatChoice = RepeatChoice.Daily,
    val atMs: Long? = null,
    val every: String = "1",
    val unit: IntervalUnit = IntervalUnit.Hours,
    val time: String = "09:00",
    val days: DayPreset = DayPreset.Every,
    val customDays: Set<Int> = WEEKDAYS.toSet(),
)

/** 24-hour "HH:MM", as the core accepts it. */
internal fun validTime(time: String): Boolean {
    if (time.length != 5 || time[2] != ':' || !listOf(0, 1, 3, 4).all { time[it].isDigit() }) return false
    return time.substring(0, 2).toInt() <= 23 && time.substring(3).toInt() <= 59
}

/** (hour, minute) of a valid "HH:MM", else 09:00. */
internal fun parseTime(time: String): Pair<Int, Int> =
    if (validTime(time)) time.substring(0, 2).toInt() to time.substring(3).toInt() else 9 to 0

internal fun localAtMs(date: LocalDate, hour: Int, minute: Int, zone: ZoneId): Long =
    date.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()

/** The next full hour on the phone's clock: the default for a one-off run. */
internal fun nextHourMs(nowMs: Long, zone: ZoneId): Long =
    Instant.ofEpochMilli(nowMs).atZone(zone).truncatedTo(ChronoUnit.HOURS).plusHours(1).toInstant().toEpochMilli()

internal fun ScheduleDraft.everyMinutes(): Long? =
    every.trim().takeIf { it.length in 1..6 }?.toLongOrNull()?.takeIf { it > 0 }?.let { it * unit.minutes }

internal fun ScheduleDraft.weekdays(): List<Int> = when (days) {
    DayPreset.Every -> emptyList()
    DayPreset.Weekdays -> WEEKDAYS
    DayPreset.Custom -> normalizedDays(customDays.toList())
}

/** Only the kind's own fields, as the core forwards them. */
internal fun ScheduleDraft.repeatPayload(): ScheduleRepeat = when (repeat) {
    RepeatChoice.Once -> ScheduleRepeat(kind = "once", at_ms = atMs)
    RepeatChoice.Interval -> ScheduleRepeat(kind = "interval", every_minutes = everyMinutes())
    RepeatChoice.Daily -> ScheduleRepeat(kind = "daily", time = time, weekdays = weekdays())
}

/** Null when the companion's chat is the target but it has no conversation yet. */
internal fun ScheduleDraft.targetPayload(home: ScheduleHome?): ScheduleTarget? = when (sendTo) {
    ScheduleSendTo.Companion -> home?.takeIf { it.ready }?.let { ScheduleTarget(kind = "thread", workspace_id = it.workspaceId, thread_id = it.threadId) }
    ScheduleSendTo.ExistingChat -> ScheduleTarget(kind = "thread", workspace_id = workspaceId, thread_id = threadId)
    ScheduleSendTo.NewChat -> ScheduleTarget(kind = "new_chat", workspace_id = workspaceId, provider = provider, model = model.trim().ifEmpty { null })
}

internal fun entryRepeat(entry: ScheduleEntry): ScheduleRepeat = when (entry.repeat_kind) {
    "once" -> ScheduleRepeat(kind = "once", at_ms = entry.repeat_at_ms)
    "interval" -> ScheduleRepeat(kind = "interval", every_minutes = entry.repeat_every_minutes)
    else -> ScheduleRepeat(kind = "daily", time = entry.repeat_time, weekdays = normalizedDays(entry.repeat_weekdays))
}

internal fun entryTarget(entry: ScheduleEntry): ScheduleTarget =
    if (entry.target_kind == "new_chat") ScheduleTarget(kind = "new_chat", workspace_id = entry.target_workspace_id,
        provider = entry.target_provider, model = entry.target_model.ifEmpty { null })
    else ScheduleTarget(kind = "thread", workspace_id = entry.target_workspace_id, thread_id = entry.target_thread_id)

/** A blank form: the companion's chat when it has one (else a new chat), daily at 09:00. */
internal fun newDraft(home: ScheduleHome?, workspaceId: String?, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()) = ScheduleDraft(
    sendTo = if (home?.ready == true) ScheduleSendTo.Companion else ScheduleSendTo.NewChat,
    workspaceId = workspaceId.orEmpty(), atMs = nextHourMs(nowMs, zone))

/** The empty state's example: every weekday at 9, check CI and summarize. */
internal fun exampleDraft(home: ScheduleHome?, workspaceId: String?, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()) =
    newDraft(home, workspaceId, nowMs, zone).copy(name = "Morning CI check",
        prompt = "Check CI for every workspace and summarize what failed.", repeat = RepeatChoice.Daily, time = "09:00", days = DayPreset.Weekdays)

/** The form for editing [entry]. A thread target other than the companion's chat stays as it is. */
internal fun draftOf(entry: ScheduleEntry, home: ScheduleHome?): ScheduleDraft {
    val sendTo = when {
        entry.target_kind == "new_chat" -> ScheduleSendTo.NewChat
        home != null && home.ready && entry.target_workspace_id == home.workspaceId && entry.target_thread_id == home.threadId -> ScheduleSendTo.Companion
        else -> ScheduleSendTo.ExistingChat
    }
    val minutes = entry.repeat_every_minutes?.takeIf { it > 0 } ?: 60L
    val hours = minutes % 60 == 0L
    val days = normalizedDays(entry.repeat_weekdays)
    return ScheduleDraft(prompt = entry.prompt, name = entry.name, sendTo = sendTo, workspaceId = entry.target_workspace_id,
        threadId = if (sendTo == ScheduleSendTo.ExistingChat) entry.target_thread_id else "",
        provider = entry.target_provider, model = entry.target_model,
        repeat = when (entry.repeat_kind) { "once" -> RepeatChoice.Once; "interval" -> RepeatChoice.Interval; else -> RepeatChoice.Daily },
        atMs = entry.repeat_at_ms, every = (if (hours) minutes / 60 else minutes).toString(),
        unit = if (hours) IntervalUnit.Hours else IntervalUnit.Minutes, time = entry.repeat_time.takeIf(::validTime) ?: "09:00",
        days = when { days.isEmpty() -> DayPreset.Every; days == WEEKDAYS -> DayPreset.Weekdays; else -> DayPreset.Custom },
        customDays = days.toSet().ifEmpty { WEEKDAYS.toSet() })
}

/**
 * The first problem that keeps Save disabled, mirroring the core's checks so the form never sends
 * something it would refuse; null when the draft can be saved. A one-off time must be in the
 * future unless an edit leaves the repeat unchanged.
 */
internal fun draftProblem(draft: ScheduleDraft, home: ScheduleHome?, nowMs: Long, original: ScheduleEntry? = null): String? {
    if (draft.prompt.isBlank()) return "Write what the task should do."
    if (utf8Bytes(draft.prompt.trim()) > SCHEDULE_MAX_PROMPT_BYTES) return "Keep the prompt under 16 KiB."
    if (utf8Bytes(draft.name.trim()) > SCHEDULE_MAX_NAME_BYTES) return "Keep the name under 120 bytes."
    when (draft.sendTo) {
        ScheduleSendTo.Companion -> if (home?.ready != true) return "${home?.name ?: "Your companion"}'s chat isn't set up yet."
        ScheduleSendTo.NewChat -> {
            if (draft.workspaceId.isEmpty()) return "Choose a workspace."
            if (draft.provider.isEmpty()) return "Choose a provider for the new chat."
        }
        ScheduleSendTo.ExistingChat -> if (draft.workspaceId.isEmpty() || draft.threadId.isEmpty()) return "Choose a chat."
    }
    when (draft.repeat) {
        RepeatChoice.Once -> {
            val at = draft.atMs ?: return "Choose when it should run."
            val unchanged = original != null && draft.repeatPayload() == entryRepeat(original)
            if (at <= nowMs && !unchanged) return "Choose a time in the future."
        }
        RepeatChoice.Interval -> {
            val minutes = draft.everyMinutes() ?: return "Enter how often it repeats."
            if (minutes < SCHEDULE_MIN_EVERY_MINUTES) return "Repeat at most every 5 minutes."
            if (minutes > SCHEDULE_MAX_EVERY_MINUTES) return "Repeat at least once every 7 days."
        }
        RepeatChoice.Daily -> {
            if (!validTime(draft.time)) return "Use a time like 09:00."
            if (draft.days == DayPreset.Custom && draft.customDays.none { it in 0..6 }) return "Choose at least one day."
        }
    }
    return null
}

/**
 * `schedule_create` for [draft]; null when it has no target. The companion's chat is recorded as
 * the parent, so runs that open a new chat report back to it.
 */
internal fun createEvent(draft: ScheduleDraft, home: ScheduleHome?, nowMs: Long, wallMs: Long, intentId: String): EventScheduleCreate? {
    val target = draft.targetPayload(home) ?: return null
    val parent = home?.takeIf { it.ready }
    return EventScheduleCreate(now_ms = nowMs, wall_time_ms = wallMs, intent_id = intentId,
        name = draft.name.trim().ifEmpty { null }, prompt = draft.prompt.trim(), target = target, repeat = draft.repeatPayload(),
        enabled = true, parent_workspace_id = parent?.workspaceId, parent_thread_id = parent?.threadId, created_by = "mobile")
}

/** `schedule_update` with only the fields that changed; a cleared name keeps the old one. Null without a target. */
internal fun updateEvent(original: ScheduleEntry, draft: ScheduleDraft, home: ScheduleHome?, nowMs: Long, wallMs: Long, intentId: String): EventScheduleUpdate? {
    val target = draft.targetPayload(home) ?: return null
    return EventScheduleUpdate(now_ms = nowMs, wall_time_ms = wallMs, intent_id = intentId, id = original.id,
        name = draft.name.trim().takeIf { it.isNotEmpty() && it != original.name },
        prompt = draft.prompt.trim().takeIf { it != original.prompt },
        target = target.takeIf { it != entryTarget(original) },
        repeat = draft.repeatPayload().takeIf { it != entryRepeat(original) })
}

internal fun EventScheduleUpdate.changesNothing() = name == null && prompt == null && target == null && repeat == null && enabled == null

/** Failure text for a settled schedule intent; the core's own messages are already human. */
internal fun scheduleError(error: LocalError?): String = when (error?.code) {
    null -> "Something went wrong. Try again."
    "offline", "unavailable", "cancelled" -> "Connect to the host first."
    "unsupported", "method_not_found", "unknown_method" -> SCHEDULES_UNSUPPORTED
    else -> error.message.ifBlank { "Something went wrong. Try again." }
}

// ---- Controller (unit tested with a fake core) ----

internal data class ScheduleUiState(
    val view: SchedulesView? = null,
    /** Phone time when [view]'s `now_ms` arrived; see [hostNow]. */
    val receivedAtMs: Long = 0,
    /** Switch positions while their toggle is in flight. */
    val toggling: Map<String, Boolean> = emptyMap(),
    /** The latest Run now from this phone; its chat arrives as `view.last_run`. */
    val runIntent: String? = null,
    /** A form save is in flight; [formError] is its failure. */
    val saving: Boolean = false,
    val formError: String? = null,
    /** The latest failed toggle, run or delete. */
    val error: String? = null,
) {
    val loaded get() = view?.loaded == true
    fun enabled(entry: ScheduleEntry) = toggling[entry.id] ?: entry.enabled
    /** Enabled tasks, for the companion header's count. */
    val enabledCount get() = view?.schedules.orEmpty().count { enabled(it) }
    /** The run this phone started, once it has a chat to open. */
    val lastRun get() = view?.last_run?.takeIf { it.intent_id == runIntent && it.thread_id.isNotEmpty() }
    fun clockNow(phoneNowMs: Long): Long = hostNow(view?.now_ms ?: 0L, receivedAtMs, phoneNowMs)
}

/** One host's scheduled tasks: reads the `schedules` selector and sends its intents. */
internal class ScheduleController(
    private val core: CompanionCore,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutableState = MutableStateFlow(ScheduleUiState())
    val state = mutableState.asStateFlow()

    init {
        scope.launch {
            // `schedules` appears in `views` only after its first change, so seed it once.
            decode(try { core.query(SCHEDULES_SELECTOR) } catch (e: CancellationException) { throw e } catch (_: Exception) { null })?.let { accept(it) }
            core.views.map { it[SCHEDULES_SELECTOR] }.filterNotNull().distinctUntilChanged().collect { value -> decode(value)?.let { accept(it) } }
        }
    }

    private fun decode(value: JsonElement?): SchedulesView? = value?.let {
        try { CoreJson.decodeFromJsonElement<SchedulesQuery>(it).data } catch (_: Exception) { null }
    }

    private fun accept(view: SchedulesView) = mutableState.update { s ->
        s.copy(view = view, receivedAtMs = if (s.view?.now_ms != view.now_ms || s.receivedAtMs == 0L) clock() else s.receivedAtMs)
    }

    /** Sends one intent with [id]; false when the core refused it outright. */
    private suspend fun dispatch(id: String, build: (Long, Long, String) -> Event): Boolean =
        try { core.send { n, w -> build(n, w, id) }; true }
        catch (e: CancellationException) { throw e }
        catch (_: CoreInputRejected) { false }

    /** Sends and waits for the receipt; null on success, else a message for the user. */
    private suspend fun perform(id: String = UUID.randomUUID().toString(), timeoutMs: Long = SETTLE_TIMEOUT_MS,
        build: (Long, Long, String) -> Event): String? = try {
        if (!dispatch(id, build)) "Couldn't send that to the core. Try again."
        else {
            val op = withTimeoutOrNull(timeoutMs) {
                core.operations.mapNotNull { q -> q?.data?.items?.find { it.intent_id == id }?.takeIf { it.state != "pending" } }.first()
            }
            when {
                op == null -> "The host didn't answer. Try again."
                op.state == "succeeded" -> null
                else -> scheduleError(op.error)
            }
        }
    } catch (e: CancellationException) { throw e } catch (_: Exception) { "Couldn't reach the host. Try again." }

    /** `schedule_refresh` for every workspace; settles on its own. */
    suspend fun refreshNow() {
        try { dispatch(UUID.randomUUID().toString()) { n, w, id -> EventScheduleRefresh(now_ms = n, wall_time_ms = w, intent_id = id) } }
        catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }

    fun refresh() { scope.launch { refreshNow() } }

    fun setEnabled(entry: ScheduleEntry, enabled: Boolean) {
        mutableState.update { it.copy(toggling = it.toggling + (entry.id to enabled), error = null) }
        scope.launch {
            val error = perform { n, w, id -> EventScheduleUpdate(now_ms = n, wall_time_ms = w, intent_id = id, id = entry.id, enabled = enabled) }
            mutableState.update { it.copy(toggling = it.toggling - entry.id, error = error ?: it.error) }
        }
    }

    fun run(entry: ScheduleEntry) {
        val intent = UUID.randomUUID().toString()
        mutableState.update { it.copy(runIntent = intent, error = null) }
        scope.launch {
            val error = perform(intent, RUN_TIMEOUT_MS) { n, w, id -> EventScheduleRun(now_ms = n, wall_time_ms = w, intent_id = id, id = entry.id) }
            if (error != null) mutableState.update { it.copy(error = error) }
        }
    }

    fun delete(entry: ScheduleEntry) {
        mutableState.update { it.copy(error = null) }
        scope.launch {
            val error = perform { n, w, id -> EventScheduleDelete(now_ms = n, wall_time_ms = w, intent_id = id, id = entry.id) }
            if (error != null) mutableState.update { it.copy(error = error) }
        }
    }

    /** Creates [draft], or updates [original] with only what changed; [onSaved] runs on success. */
    fun save(original: ScheduleEntry?, draft: ScheduleDraft, home: ScheduleHome?, onSaved: () -> Unit) {
        if (state.value.saving) return
        if (draft.targetPayload(home) == null) {
            mutableState.update { it.copy(formError = "${home?.name ?: "Your companion"}'s chat isn't set up yet.") }
            return
        }
        if (original != null && updateEvent(original, draft, home, 0, 0, "")?.changesNothing() == true) return onSaved()
        mutableState.update { it.copy(saving = true, formError = null) }
        scope.launch {
            val error = perform { n, w, id ->
                if (original == null) createEvent(draft, home, n, w, id)!! else updateEvent(original, draft, home, n, w, id)!!
            }
            mutableState.update { it.copy(saving = false, formError = error) }
            if (error == null) onSaved()
        }
    }

    fun clearErrors() = mutableState.update { it.copy(formError = null, error = null) }

    companion object {
        const val POLL_MS = 15_000L
        const val SETTLE_TIMEOUT_MS = 30_000L
        const val RUN_TIMEOUT_MS = 60_000L
    }
}

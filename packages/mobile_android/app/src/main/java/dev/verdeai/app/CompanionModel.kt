package dev.verdeai.app

import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.util.UUID

/*
 * Machine-wide Companion. The daemon keeps one roster per machine and appends the companion's
 * orchestrator persona and standing orders to every turn on its thread, so this app only reads and
 * writes the roster (through the core's `companion` selector) and talks through the ordinary chat
 * engine. Names, orders and message text are never logged.
 */

internal enum class CompanionCharacter(val id: String, val label: String, val blurb: String) {
    Sprout("sprout", "Sprout", "A hatchling with a crown leaf"),
    Moss("moss", "Moss", "A patient, mossy guardian"),
    Vireo("vireo", "Vireo", "A quick, watchful songbird");

    companion object { fun of(id: String?): CompanionCharacter = entries.firstOrNull { it.id == id } ?: Sprout }
}

/** Character pose, from real state only: approval outranks work; offline reads as paused. */
internal enum class CompanionPose { Idle, Working, Approval, Paused }

internal const val MAX_COMPANIONS = 8
internal const val MAX_COMPANION_NAME_BYTES = 32
internal const val MAX_COMPANION_ORDERS_BYTES = 1024
internal const val COMPANION_SELECTOR = "companion"

internal val COMPANION_SUGGESTIONS = listOf(
    "What's running across my workspaces right now?",
    "Check every workspace for chats that need me.",
    "Start the dev servers for this workspace and watch them.",
)

// ---- Pure roster rules (unit tested) ----

/** The longest prefix of [text] within [maxBytes] UTF-8 bytes, never splitting a code point. */
internal fun clipUtf8(text: String, maxBytes: Int): String {
    var bytes = 0
    var end = 0
    while (end < text.length) {
        val cp = text.codePointAt(end)
        val size = when { cp < 0x80 -> 1; cp < 0x800 -> 2; cp < 0x10000 -> 3; else -> 4 }
        if (bytes + size > maxBytes) break
        bytes += size
        end += Character.charCount(cp)
    }
    return text.substring(0, end)
}

/** One line, trimmed, at most 32 UTF-8 bytes (the daemon's limit). */
internal fun cleanCompanionName(raw: String): String =
    clipUtf8(raw.replace(Regex("[\\u0000-\\u001f\\u007f]+"), " ").trim(), MAX_COMPANION_NAME_BYTES).trim()

internal fun cleanOrders(raw: String): String = clipUtf8(raw.trim(), MAX_COMPANION_ORDERS_BYTES)

internal fun activeCompanion(roster: CompanionRoster?): CompanionEntry? {
    val list = roster?.companions.orEmpty()
    return list.firstOrNull { it.id == roster?.active_id } ?: list.firstOrNull()
}

internal fun newCompanionId(): String = "companion-" + UUID.randomUUID().toString().replace("-", "").take(16)

/** The first companion when a machine has none: Sprout, living in [workspaceId]. */
internal fun seededRoster(workspaceId: String, id: String = newCompanionId()) =
    CompanionRoster(version = 1, active_id = id, companions = listOf(CompanionEntry(id = id, name = "Sprout", character = "sprout", home_workspace_id = workspaceId)))

internal fun CompanionRoster.replacing(entry: CompanionEntry): CompanionRoster =
    copy(companions = companions.map { if (it.id == entry.id) entry else it })

/** Adds and activates [entry]; null at the 8-companion limit or on a duplicate id. */
internal fun CompanionRoster.adding(entry: CompanionEntry): CompanionRoster? =
    if (companions.size >= MAX_COMPANIONS || companions.any { it.id == entry.id }) null
    else copy(active_id = entry.id, companions = companions + entry)

/** Removes [id] but always keeps one companion; the next one becomes active if needed. */
internal fun CompanionRoster.removing(id: String): CompanionRoster? {
    if (companions.size <= 1 || companions.none { it.id == id }) return null
    val rest = companions.filterNot { it.id == id }
    return copy(companions = rest, active_id = if (rest.any { it.id == active_id }) active_id else rest.first().id)
}

internal fun CompanionRoster.activating(id: String): CompanionRoster? =
    if (companions.any { it.id == id } && activeCompanion(this)?.id != id) copy(active_id = id) else null

/** "Moss", or "Moss 2" when a companion already has that name. */
internal fun suggestedName(roster: CompanionRoster?, character: CompanionCharacter): String {
    val taken = roster?.companions.orEmpty().map { it.name.trim().lowercase() }.toSet()
    if (character.label.lowercase() !in taken) return character.label
    return (2..MAX_COMPANIONS + 1).map { "${character.label} $it" }.first { it.lowercase() !in taken }
}

/** Is this chat a companion's conversation? */
internal fun companionFor(roster: CompanionRoster?, workspaceId: String?, threadId: String?): CompanionEntry? =
    if (workspaceId.isNullOrEmpty() || threadId.isNullOrEmpty()) null
    else roster?.companions?.firstOrNull { it.thread_id == threadId && it.home_workspace_id == workspaceId }

// ---- Crew and status ----

/** Daemon link status → the shared orchestration status; unknown values read as idle. */
internal fun crewStatus(link: CompanionLink): ChildStatus = ChildStatus.parse(link.status) ?: ChildStatus.Idle
internal val ChildStatus.needsYou get() = this == ChildStatus.WaitingApproval || this == ChildStatus.Blocked || this == ChildStatus.Failed
internal val ChildStatus.running get() = this == ChildStatus.Running

/** Shown crew: hidden links dropped; needs-you first, then running, then most recent. */
internal fun visibleCrew(crew: CompanionCrew?): List<CompanionLink> =
    crew?.links.orEmpty().filterNot { it.hidden }.sortedWith(
        compareByDescending<CompanionLink> { crewStatus(it).needsYou }
            .thenByDescending { crewStatus(it).running }
            .thenByDescending { it.updated_at_ms }
            .thenBy { it.link_id })

internal data class CompanionPulse(val needsYou: Int, val running: Int)

/**
 * Every companion conversation's thread id: each companion's current one and its past ones.
 * They live behind the companion bubble, so chat lists hide them. History entries carry no
 * workspace, so threads are matched by id alone.
 */
internal fun companionThreadIds(roster: CompanionRoster?): Set<String> =
    roster?.companions.orEmpty().flatMap { c -> listOf(c.thread_id) + c.history.map { it.thread_id } }.filter { it.isNotEmpty() }.toSet()

/** One row of the sheet's activity panel: a crew link, or another chat running anywhere on the machine. */
internal data class CompanionActivity(val workspaceId: String, val threadId: String, val title: String, val status: ChildStatus,
    val linkId: String? = null) {
    val key get() = linkId?.let { "l:$it" } ?: "c:$workspaceId\u001f$threadId"
}

private fun runningChatPane(pane: Pane) = pane.kind == "chat" && !pane.attention && pane.thread_id != null && activeStatus(pane.status)

/**
 * The activity panel: the companion's crew plus every other chat running machine-wide (chats
 * started elsewhere, e.g. from the CLI, are not linked to the companion), deduplicated by
 * workspace and thread. A crew link whose chat is running reads as running unless it needs the
 * user. [hidden] (companion conversations) never appear. Needs-you first, then running.
 */
internal fun companionActivity(panes: List<Pane>, crew: List<CompanionLink>, hidden: Set<String> = emptySet()): List<CompanionActivity> {
    val running = panes.filter(::runningChatPane).associateBy { it.workspace_id to it.thread_id!! }
    val seen = HashSet<Pair<String, String>>()
    val rows = ArrayList<CompanionActivity>()
    crew.forEach { link ->
        val chat = link.workspace_id to link.local_thread_id
        if (link.local_thread_id in hidden || !seen.add(chat)) return@forEach
        val status = crewStatus(link).let { if (!it.needsYou && chat in running) ChildStatus.Running else it }
        rows += CompanionActivity(link.workspace_id, link.local_thread_id, childTitle(link.local_thread_id, link.title), status, link.link_id)
    }
    running.forEach { (chat, pane) ->
        if (chat.second in hidden || !seen.add(chat)) return@forEach
        rows += CompanionActivity(chat.first, chat.second, pane.title.ifBlank { "Chat" }, ChildStatus.Running)
    }
    return rows.sortedWith(compareByDescending<CompanionActivity> { it.status.needsYou }.thenByDescending { it.status.running })
}

/**
 * Counts across every workspace: Home panes flagged for attention plus crew links needing the
 * user (deduplicated by chat), and the running rows of [companionActivity], so the header's
 * running count always matches the activity panel.
 */
internal fun companionPulse(panes: List<Pane>, crew: List<CompanionLink>, hidden: Set<String> = emptySet()): CompanionPulse {
    val flagged = panes.filter { it.attention || it.status == "waiting_approval" }
    val flaggedChats = flagged.mapNotNull { p -> p.thread_id?.let { p.workspace_id to it } }.toSet()
    val needs = flagged.size + crew.count { crewStatus(it).needsYou && (it.workspace_id to it.local_thread_id) !in flaggedChats }
    return CompanionPulse(needs, companionActivity(panes, crew, hidden).count { it.status.running })
}

/** "1 needs you" / "3 need you". */
internal fun needsLabel(count: Int): String = if (count == 1) "1 needs you" else "$count need you"

/** The crew pill: "2 running · 1 waiting · 1 done"; null when there is no crew. */
internal fun crewSummary(crew: List<CompanionLink>): String? = activitySummary(crew.map(::crewStatus))

/** The activity pill: "2 running · 1 waiting · 1 done"; null when there is nothing to show. */
internal fun activitySummary(statuses: List<ChildStatus>): String? {
    if (statuses.isEmpty()) return null
    val running = statuses.count { it.running }
    val waiting = statuses.count { it.needsYou }
    val done = statuses.count { it == ChildStatus.Completed }
    val parts = listOfNotNull(running.takeIf { it > 0 }?.let { "$it running" }, waiting.takeIf { it > 0 }?.let { "$it waiting" },
        done.takeIf { it > 0 }?.let { "$it done" })
    return parts.joinToString(" \u00b7 ").ifEmpty { if (statuses.size == 1) "1 in crew" else "${statuses.size} in crew" }
}

/** The sheet header's small status suffix: needs first, then running; nothing when idle. */
internal fun companionHeaderSuffix(needs: Int, running: Int): String? = when {
    needs > 0 -> needsLabel(needs)
    running > 0 -> "$running running"
    else -> null
}

internal fun companionStatusLine(pulse: CompanionPulse): String = when {
    pulse.needsYou == 1 -> "1 thing needs you"
    pulse.needsYou > 1 -> "${pulse.needsYou} things need you"
    pulse.running == 1 -> "1 chat running"
    pulse.running > 1 -> "${pulse.running} chats running"
    else -> "Ready when you are"
}

internal fun companionPose(online: Boolean, approval: Boolean, working: Boolean): CompanionPose = when {
    !online -> CompanionPose.Paused
    approval -> CompanionPose.Approval
    working -> CompanionPose.Working
    else -> CompanionPose.Idle
}

// ---- Brain (pure, unit tested) ----

/** How a brain change is applied to the companion's conversation. */
internal enum class BrainChange {
    /** Nothing changed. */
    None,
    /** Same provider, an empty thread, or no thread yet: change the selection in place. */
    InPlace,
    /** A different provider on a conversation that already has history: the daemon hands it off (same thread). */
    HandOff,
}

/**
 * [threadProvider] is the companion thread's current provider (null when unknown), [threadEmpty]
 * true when it has no messages and no running turn. A provider can't switch under a live
 * provider session, so only that case is handed off by the daemon (`companion_brain_switch`).
 */
internal fun classifyBrainChange(threadId: String, threadProvider: String?, threadEmpty: Boolean, current: ChatSelection, target: ChatSelection): BrainChange {
    if (target.provider == current.provider && target.model == current.model && target.effort == current.effort && target.speed == current.speed) return BrainChange.None
    if (threadId.isEmpty() || threadEmpty) return BrainChange.InPlace
    return if (threadProvider == null || target.provider == threadProvider) BrainChange.InPlace else BrainChange.HandOff
}

/** The roster entry with the new brain; effort and speed live on the thread, not the roster. */
internal fun withBrain(entry: CompanionEntry, brain: ChatSelection): CompanionEntry =
    entry.copy(provider = brain.provider.orEmpty(), model = brain.model.orEmpty())

/** "Claude · Opus 5.5 · High"; parts that are unknown are left out. */
internal fun brainLabel(provider: String?, model: String?, effort: String?): String =
    listOf(provider, model, effort).mapNotNull { it?.trim()?.takeIf { part -> part.isNotEmpty() } }.joinToString(" \u00b7 ").ifEmpty { "Default brain" }

/** The new-chat selection with [model]/[effort]/[speed] applied where the provider's catalog offers them. */
internal fun brainSelection(chat: ManageNewChat, model: String?, effort: String?, speed: String?): ChatSelection {
    val c = chat.catalogs
    var next = chat.selection
    if (model != null && c.models.any { it.id == model && it.enabled }) next = next.copy(model = model)
    if (effort != null && c.efforts.any { it.id == effort && it.enabled }) next = next.copy(effort = effort)
    if (speed != null && c.speeds.any { it.id == speed && it.enabled }) next = next.copy(speed = speed)
    return next
}

// ---- Conversations (pure, unit tested) ----

internal const val MAX_CONVERSATION_HISTORY = 12

/** Puts [past] first, dropping an older entry for the same thread, keeping at most 12. */
internal fun pushHistory(history: List<CompanionPastConversation>, past: CompanionPastConversation): List<CompanionPastConversation> =
    (listOf(past) + history.filter { it.thread_id != past.thread_id }).take(MAX_CONVERSATION_HISTORY)

/** A history title: the chat's own title, unless it's generic, else the first thing the user said. */
internal fun conversationTitle(threadTitle: String?, companionName: String, firstUserLine: String?): String {
    val title = threadTitle?.trim().orEmpty()
    if (title.isNotEmpty() && title != "New Chat" && title != companionName.trim()) return clipUtf8(title, 96)
    val said = firstUserLine?.lineSequence()?.map { it.trim() }?.firstOrNull { it.isNotEmpty() }
    return clipUtf8(said ?: title.ifEmpty { "Conversation" }, 96)
}

private fun archived(entry: CompanionEntry, title: String, nowMs: Long) =
    CompanionPastConversation(thread_id = entry.thread_id, title = title, provider = entry.provider, model = entry.model, ended_at_ms = nowMs)

/** New conversation: the current one goes to the front of history and the next one starts fresh. */
internal fun rosterWithNewConversation(roster: CompanionRoster, companionId: String, title: String, nowMs: Long): CompanionRoster? {
    val entry = roster.companions.firstOrNull { it.id == companionId } ?: return null
    if (entry.thread_id.isEmpty()) return null
    return roster.replacing(entry.copy(thread_id = "", history = pushHistory(entry.history, archived(entry, title, nowMs))))
}

/** Resume [threadId] from history; the current conversation takes its place there. Its brain comes back too. */
internal fun rosterResuming(roster: CompanionRoster, companionId: String, threadId: String, currentTitle: String, nowMs: Long): CompanionRoster? {
    val entry = roster.companions.firstOrNull { it.id == companionId } ?: return null
    val past = entry.history.firstOrNull { it.thread_id == threadId } ?: return null
    var history = entry.history.filter { it.thread_id != threadId }
    if (entry.thread_id.isNotEmpty() && entry.thread_id != threadId) history = pushHistory(history, archived(entry, currentTitle, nowMs))
    return roster.replacing(entry.copy(thread_id = past.thread_id, provider = past.provider.ifEmpty { entry.provider },
        model = if (past.provider.isNotEmpty()) past.model else entry.model, history = history))
}

/** Drops [threadId] from the list only; the chat itself stays in the workspace. */
internal fun rosterForgetting(roster: CompanionRoster, companionId: String, threadId: String): CompanionRoster? {
    val entry = roster.companions.firstOrNull { it.id == companionId } ?: return null
    if (entry.history.none { it.thread_id == threadId }) return null
    return roster.replacing(entry.copy(history = entry.history.filter { it.thread_id != threadId }))
}

// ---- Brain switch (pure, unit tested) ----

/** The provider part of a daemon brain label ("Codex · gpt-5" → "Codex"). */
internal fun brainProviderOf(label: String): String = label.substringBefore(" \u00b7 ").trim()

/** Header status while the companion changes brains; null when nothing is in progress. */
internal fun handoffStatus(switch: CompanionBrainSwitch?): String? = when (switch?.status) {
    null -> null
    "pending" -> "Switching brain\u2026"
    "briefing" -> "Handing off to ${brainProviderOf((switch?.to ?: "")).ifEmpty { "the new brain" }}\u2026"
    "switched" -> "Switched to ${brainProviderOf((switch?.to ?: "")).ifEmpty { "the new brain" }}"
    else -> null
}

/** Confirm dialog for switching an ongoing conversation's provider: title and body. */
internal fun brainSwitchDialog(name: String, from: String?, to: String): Pair<String, String> {
    val outgoing = from?.takeIf { it.isNotBlank() } ?: "The current brain"
    return "Switch $name to $to?" to "$name keeps this conversation. $outgoing will write a quick handoff brief first, then $to takes over with the brief and recent history."
}

internal fun brainSwitchError(code: String?, name: String): String = when (code) {
    "companion_busy" -> "$name is still working. Wait for the current turn to finish, then switch."
    "busy" -> "Still switching brains."
    "offline", "unavailable" -> "Connect to the host first."
    "unknown_method", "method_not_found", "unsupported" -> "Update verde on the computer to switch brains."
    else -> "Couldn't switch $name's brain. Try again."
}

/** Notification title for a companion's chat: "Juniper: <title>". */
internal fun companionNotificationTitle(name: String?, title: String): String {
    val who = name?.trim().orEmpty()
    if (who.isEmpty()) return title
    return if (title.isBlank()) who else "$who: $title"
}

/**
 * Process-wide index of companion threads per host, memory only, so notifications raised while
 * Verde runs can be titled with the companion's name. Empty after a cold start until a roster loads.
 */
internal object CompanionThreads {
    @Volatile private var names: Map<String, String> = emptyMap()
    private fun key(host: String, workspace: String, thread: String) = listOf(host, workspace, thread).joinToString("\u001f")

    @Synchronized fun update(hostId: String, roster: CompanionRoster?) {
        val prefix = hostId + "\u001f"
        val kept = names.filterKeys { !it.startsWith(prefix) }
        val added = roster?.companions.orEmpty().filter { it.thread_id.isNotEmpty() && it.home_workspace_id.isNotEmpty() }
            .associate { key(hostId, it.home_workspace_id, it.thread_id) to it.name }
        names = kept + added
    }

    fun name(hostId: String?, workspaceId: String?, threadId: String?): String? {
        if (hostId == null || workspaceId == null || threadId == null) return null
        return names[key(hostId, workspaceId, threadId)]
    }
}

// ---- Core session (unit tested with a fake core) ----

/** The slice of a host core the companion needs; tests substitute a fake. */
internal interface CompanionCore {
    val views: StateFlow<Map<String, JsonElement>>
    val operations: StateFlow<OperationsQuery?>
    suspend fun query(selector: String): JsonElement
    suspend fun send(event: (Long, Long) -> Event)
}

private class HostCompanionCore(private val host: CoreHost) : CompanionCore {
    override val views get() = host.views
    override val operations get() = host.operations
    override suspend fun query(selector: String) = host.query(selector)
    override suspend fun send(event: (Long, Long) -> Event) = host.send(event)
}

internal sealed interface CompanionSave {
    data object Saved : CompanionSave
    data object Unchanged : CompanionSave
    data class Failed(val message: String, val code: String? = null) : CompanionSave
}

/** Failure text for a settled companion intent. */
internal fun companionError(error: LocalError?): String = when (error?.code) {
    null -> "Something went wrong. Try again."
    "offline", "unavailable", "cancelled" -> "Connect to the host first."
    "insufficient_scope" -> "This phone isn't allowed to change companions. Pair again with chat access."
    "unsupported", "method_not_found" -> "Update verde on the computer to use companions."
    "conflict" -> "Companions changed on another device. Try again."
    else -> error.message.ifBlank { "Something went wrong. Try again." }
}

/**
 * One host's roster: reads the `companion` selector, refreshes roster and crew, and saves edits.
 * A save is applied to the newest roster at its revision; on `conflict` the core re-reads and the
 * same edit is re-applied, so concurrent editors never overwrite each other.
 */
internal class CompanionSession(private val core: CompanionCore, scope: CoroutineScope) {
    private val mutableView = MutableStateFlow<CompanionView?>(null)
    val view = mutableView.asStateFlow()
    private val saving = Mutex()

    init {
        scope.launch {
            // `companion` appears in `views` only after its first change, so seed it once.
            mutableView.value = decode(try { core.query(COMPANION_SELECTOR) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }) ?: mutableView.value
            core.views.map { it[COMPANION_SELECTOR] }.filterNotNull().distinctUntilChanged().collect { value ->
                decode(value)?.let { mutableView.value = it }
            }
        }
    }

    private fun decode(value: JsonElement?): CompanionView? = value?.let {
        try { CoreJson.decodeFromJsonElement<CompanionQuery>(it).data } catch (_: Exception) { null }
    }

    /** Sends one intent; null when the core refused it outright. */
    private suspend fun dispatch(build: (Long, Long, String) -> Event): String? {
        val id = UUID.randomUUID().toString()
        return try { core.send { n, w -> build(n, w, id) }; id }
        catch (e: CancellationException) { throw e }
        catch (_: CoreInputRejected) { null }
    }

    private suspend fun settled(id: String, timeoutMs: Long): Operation? = withTimeoutOrNull(timeoutMs) {
        core.operations.mapNotNull { q -> q?.data?.items?.find { it.intent_id == id }?.takeIf { it.state != "pending" } }.first()
    }

    suspend fun refresh() { dispatch { n, w, id -> EventCompanionRefresh(now_ms = n, wall_time_ms = w, intent_id = id) } }

    suspend fun refreshCrew(workspaceId: String, threadId: String) {
        if (workspaceId.isEmpty() || threadId.isEmpty()) return
        dispatch { n, w, id -> EventCompanionCrewRefresh(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId, thread_id = threadId) }
    }

    /** Applies [edit] to the newest roster and saves it; [edit] returning null means "nothing to do". */
    suspend fun update(attempts: Int = 3, edit: (CompanionRoster) -> CompanionRoster?): CompanionSave {
        saving.withLock { repeat(attempts) {
            val current = view.value?.takeIf { it.loaded } ?: return CompanionSave.Failed("Companions haven't loaded yet.", "not_loaded")
            val next = edit(current.roster) ?: return CompanionSave.Unchanged
            if (next == current.roster) return CompanionSave.Unchanged
            val id = dispatch { n, w, id -> EventCompanionSave(now_ms = n, wall_time_ms = w, intent_id = id, roster = next, expected_revision = current.revision) }
                ?: return CompanionSave.Failed("Couldn't send that to the core. Try again.", "rejected")
            val op = settled(id, SAVE_TIMEOUT_MS) ?: return CompanionSave.Failed("The host didn't answer. Try again.", "timeout")
            if (op.state == "succeeded") return CompanionSave.Saved
            if (op.error?.code != "conflict") return CompanionSave.Failed(companionError(op.error), op.error?.code)
            // The core re-reads after a conflict; wait for the newer revision before re-applying.
            withTimeoutOrNull(REREAD_TIMEOUT_MS) { view.first { it != null && it.loaded && !it.loading && it.revision != current.revision } }
        } }
        return CompanionSave.Failed(companionError(LocalError(code = "conflict", message = "")), "conflict")
    }

    private fun manageView(value: JsonElement?): ManageView? = value?.let {
        try { CoreJson.decodeFromJsonElement<ManageQuery>(it).data } catch (_: Exception) { null }
    }

    private suspend fun newChat(workspaceId: String): ManageNewChat? = withTimeoutOrNull(MODELS_TIMEOUT_MS) {
        flow {
            emit(core.views.value["manage"] ?: try { core.query("manage") } catch (e: CancellationException) { throw e } catch (_: Exception) { null })
            emitAll(core.views.map { it["manage"] })
        }.map { manageView(it)?.new_chat }.first { it != null && it.workspace_id == workspaceId && !it.loading }
    }

    private suspend fun select(workspaceId: String, selection: ChatSelection): Boolean {
        val id = dispatch { n, w, id -> EventNewChatSelect(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId,
            provider = selection.provider, model = selection.model, effort = selection.effort, access = selection.access, speed = selection.speed) } ?: return false
        return settled(id, MODELS_TIMEOUT_MS)?.state == "succeeded"
    }

    /**
     * Creates [companion]'s conversation in [workspaceId] with its preferred brain (falling back to
     * the workspace defaults) and records the new thread in the roster.
     */
    /**
     * [brain]: a brain switch (Settings → Brain) — its provider/model/effort/speed win over the
     * roster's, the roster gets the new provider/model, and the new thread replaces [replacing].
     */
    suspend fun createThread(companion: CompanionEntry, workspaceId: String, brain: ChatSelection? = null, replacing: String? = null): CompanionSave {
        val provider = (brain?.provider ?: companion.provider).ifEmpty { null }
        val picked = (provider != null && select(workspaceId, ChatSelection(provider = provider))) || (brain == null && select(workspaceId, ChatSelection()))
        if (!picked) return CompanionSave.Failed("Couldn't load the models for ${companion.name}'s conversation.", "invalid_selection")
        var chat = newChat(workspaceId) ?: return CompanionSave.Failed("The host didn't load its models. Try again.", "timeout")
        val desired = brainSelection(chat, brain?.model ?: companion.model.ifEmpty { null }, brain?.effort, brain?.speed)
        if (desired != chat.selection && select(workspaceId, desired)) chat = newChat(workspaceId) ?: chat
        if (!chat.can_create) return CompanionSave.Failed("This phone can't start chats on this host.", "insufficient_scope")
        val selection = chat.selection
        val id = dispatch { n, w, id -> EventThreadCreate(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId,
            provider = selection.provider ?: "codex", model = selection.model, effort = selection.effort, access = selection.access, speed = selection.speed) }
            ?: return CompanionSave.Failed("Couldn't send that to the core. Try again.", "rejected")
        val op = settled(id, CREATE_TIMEOUT_MS) ?: return CompanionSave.Failed("The host didn't answer. Try again.", "timeout")
        if (op.state != "succeeded") return CompanionSave.Failed(companionError(op.error), op.error?.code)
        val job = manageView(core.views.value["manage"] ?: core.query("manage"))?.operations?.lastOrNull { it.intent_id == id }
        val thread = job?.thread_id ?: return CompanionSave.Failed("The host didn't return the new chat.", "invalid_thread")
        val saved = update { roster ->
            val current = roster.companions.firstOrNull { it.id == companion.id } ?: return@update null
            when {
                brain != null -> if (replacing != null && current.thread_id != replacing) null
                    else roster.replacing(current.copy(thread_id = thread, home_workspace_id = workspaceId,
                        provider = selection.provider.orEmpty(), model = selection.model.orEmpty()))
                current.thread_id.isNotEmpty() -> null
                else -> roster.replacing(current.copy(thread_id = thread, home_workspace_id = workspaceId))
            }
        }
        // Best effort: list the conversation under the companion's name instead of "New Chat".
        if (saved == CompanionSave.Saved) dispatch { n, w, rid -> EventThreadRename(now_ms = n, wall_time_ms = w, intent_id = rid,
            workspace_id = workspaceId, thread_id = thread, title = cleanCompanionName(companion.name).ifEmpty { "Companion" }) }
        return saved
    }

    /** `companion_brain_switch`; null on success (switched or briefing), else the daemon's error code. */
    suspend fun brainSwitch(companionId: String, provider: String, model: String?, brief: Boolean): String? {
        val id = dispatch { n, w, id -> EventCompanionBrainSwitch(now_ms = n, wall_time_ms = w, intent_id = id, companion_id = companionId,
            provider = provider, model = model, brief = brief) } ?: return "rejected"
        val op = settled(id, SAVE_TIMEOUT_MS) ?: return "timeout"
        return if (op.state == "succeeded") null else op.error?.code ?: "failed"
    }

    /** Saves the brain on the roster entry (provider/model); the live thread is changed separately. */
    suspend fun saveBrain(companionId: String, brain: ChatSelection): CompanionSave = update { roster ->
        roster.companions.firstOrNull { it.id == companionId }?.let { roster.replacing(withBrain(it, brain)) }
    }

    companion object {
        const val SAVE_TIMEOUT_MS = 30_000L
        const val REREAD_TIMEOUT_MS = 10_000L
        const val MODELS_TIMEOUT_MS = 20_000L
        const val CREATE_TIMEOUT_MS = 60_000L
    }
}

// ---- Screen model ----

internal data class CompanionUiState(
    val hostId: String? = null,
    val view: CompanionView? = null,
    /** A thread is being created for the active companion. */
    val settingUp: Boolean = false,
    val setupError: String? = null,
    val saving: Boolean = false,
    /** Latest failed save, shown in the settings sheet; cleared by the next save. */
    val saveError: String? = null,
    val fatal: Boolean = false,
) {
    val roster get() = view?.takeIf { it.loaded }?.roster
    val active get() = activeCompanion(roster)
    /** The bubble appears once the host's roster has loaded (older hosts never show it). */
    val available get() = view?.loaded == true && view.supported
}

/**
 * The selected host's companion: roster, crew, polling while visible, first-run setup (a Sprout and
 * its conversation) and settings edits.
 */
internal class CompanionModel(
    private val hosts: HostsModel,
    private val browse: StateFlow<BrowseState>,
    private val pollMs: Long = POLL_MS,
    private val openPollMs: Long = OPEN_POLL_MS,
    private val schedulePollMs: Long = ScheduleController.POLL_MS,
) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(CompanionUiState())
    val state = mutableState.asStateFlow()
    private val visible = MutableStateFlow(false)
    private val sheetOpen = MutableStateFlow(false)
    private var session: CompanionSession? = null
    private var core: CoreHost? = null
    /** The Scheduled sheet is open: refresh on open and keep refreshing while it shows. */
    private val schedulesOpen = MutableStateFlow(false)
    private val mutableSchedules = MutableStateFlow(ScheduleUiState())
    /** The selected host's scheduled tasks (the companion header's count and the Scheduled sheet). */
    val schedules = mutableSchedules.asStateFlow()
    private var planner: ScheduleController? = null
    /** Companions whose conversation setup ran this session; a retry is explicit. */
    private val attempted = mutableSetOf<String>()
    private var seeded = false

    init {
        scope.launch { browse.map { it.hostId }.distinctUntilChanged().collectLatest { id -> observe(id) } }
    }

    private suspend fun observe(id: String?) = coroutineScope {
        session = null
        core = null
        planner = null
        attempted.clear()
        seeded = false
        mutableState.value = CompanionUiState(hostId = id)
        mutableSchedules.value = ScheduleUiState()
        if (id == null) return@coroutineScope
        val host = try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (host == null) { mutableState.update { it.copy(fatal = true) }; return@coroutineScope }
        val current = CompanionSession(HostCompanionCore(host), this)
        session = current
        core = host
        launch {
            current.view.collect { view ->
                mutableState.update { it.copy(view = view) }
                if (view?.loaded == true) CompanionThreads.update(id, view.roster)
            }
        }
        launch { host.failed.collect { failed -> if (failed) mutableState.update { it.copy(fatal = true) } } }
        // Poll roster and crew only while Verde is in the foreground and the host is ready:
        // slowly behind the bubble, faster while the companion sheet is open.
        launch {
            combine(visible, sheetOpen, browse.map { ready(it) }.distinctUntilChanged()) { shown, open, ready ->
                if (shown && ready) (if (open) openPollMs else pollMs) else 0L
            }.distinctUntilChanged().collectLatest { interval ->
                while (interval > 0) {
                    poll(current)
                    delay(interval)
                }
            }
        }
        // Scheduled tasks: read while the companion sheet (for its count) or the Scheduled sheet is
        // open, in the foreground on a ready host. Opening the Scheduled sheet restarts the loop, so
        // it refreshes at once. A host without the methods is asked once per opening, not every poll.
        val tasks = ScheduleController(HostCompanionCore(host), this)
        planner = tasks
        launch { tasks.state.collect { mutableSchedules.value = it } }
        launch {
            combine(visible, sheetOpen, schedulesOpen, browse.map { ready(it) }.distinctUntilChanged()) { shown, open, list, online ->
                if (shown && online && (open || list)) list else null
            }.distinctUntilChanged().collectLatest { list ->
                if (list == null) return@collectLatest
                var first = true
                while (true) {
                    if (first || list || tasks.state.value.view?.supported != false) tasks.refreshNow()
                    first = false
                    delay(schedulePollMs)
                }
            }
        }
        // First-run setup writes to the host, so it runs only once the user opens the companion.
        launch {
            combine(current.view, sheetOpen, browse) { view, open, b -> Triple(view, open, b) }.collect { (view, open, b) ->
                if (view != null && open) setup(current, view, b)
            }
        }
    }

    private fun ready(state: BrowseState) = state.host?.phase == "ready" && state.host?.auth_state == "paired" && state.networkAvailable

    private suspend fun poll(current: CompanionSession) {
        current.refresh()
        val active = activeCompanion(current.view.value?.roster?.takeIf { current.view.value?.loaded == true })
        if (active != null && active.thread_id.isNotEmpty()) current.refreshCrew(active.home_workspace_id, active.thread_id)
    }

    /** First run: seed Sprout in the most recent workspace, then give the active companion a thread. */
    private fun setup(current: CompanionSession, view: CompanionView, browse: BrowseState) {
        if (!view.loaded || !view.can_edit || view.saving || mutableState.value.settingUp) return
        val open = browse.workspaces?.items.orEmpty().filter { it.open }
        val fallback = mostRecentOpenWorkspace(open)?.workspace_id ?: return
        if (view.roster.companions.isEmpty()) {
            if (seeded) return
            seeded = true
            scope.launch { current.update { roster -> if (roster.companions.isEmpty()) seededRoster(fallback) else null } }
            return
        }
        val active = activeCompanion(view.roster) ?: return
        if (active.thread_id.isNotEmpty() || !attempted.add(active.id)) return
        val home = active.home_workspace_id.takeIf { ws -> open.any { it.workspace_id == ws } } ?: fallback
        startThread(current, active, home)
    }

    private fun startThread(current: CompanionSession, companion: CompanionEntry, workspaceId: String) {
        mutableState.update { it.copy(settingUp = true, setupError = null) }
        scope.launch {
            val result = try { current.createThread(companion, workspaceId) }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) { CompanionSave.Failed("Couldn't reach the host. Try again.") }
            mutableState.update { it.copy(settingUp = false, setupError = (result as? CompanionSave.Failed)?.message) }
        }
    }

    /** Explicit retry after a failed conversation setup. */
    fun retrySetup() {
        val current = session ?: return
        val active = state.value.active ?: return
        val open = browse.value.workspaces?.items.orEmpty().filter { it.open }
        val home = active.home_workspace_id.takeIf { ws -> open.any { it.workspace_id == ws } }
            ?: mostRecentOpenWorkspace(open)?.workspace_id ?: return
        attempted.add(active.id)
        startThread(current, active, home)
    }

    /** Verde is in the foreground: keep the roster and crew fresh for the bubble. */
    fun setVisible(shown: Boolean) { visible.value = shown }

    /** The companion sheet is open: poll faster and run first-time setup. */
    fun setSheetOpen(open: Boolean) { sheetOpen.value = open }

    /**
     * First line of the companion's latest reply, when the core still holds that thread's
     * transcript (it is read, never fetched, so the thread's unread state is untouched).
     */
    fun latestReply(workspaceId: String, threadId: String): String? {
        val raw = core?.views?.value?.get(chatSelector("thread", workspaceId, threadId)) ?: return null
        val thread = try { CoreJson.decodeFromJsonElement<ThreadQuery>(raw).data } catch (_: Exception) { null } ?: return null
        return thread.rows.lastOrNull { it.role == "assistant" && it.kind == "message" && it.body.isNotBlank() }?.body?.let(::replyPreview)
    }

    fun refresh() {
        val current = session ?: return
        scope.launch { poll(current) }
    }

    /** Saves [edit] (applied to the newest roster); [onSaved] runs after a successful save. */
    fun save(edit: (CompanionRoster) -> CompanionRoster?, onSaved: () -> Unit = {}) {
        val current = session ?: return
        mutableState.update { it.copy(saving = true, saveError = null) }
        scope.launch {
            val result = try { current.update(edit = edit) }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) { CompanionSave.Failed("Couldn't reach the host. Try again.") }
            mutableState.update { it.copy(saving = false, saveError = (result as? CompanionSave.Failed)?.message) }
            if (result !is CompanionSave.Failed) onSaved()
        }
    }

    fun update(entry: CompanionEntry, onSaved: () -> Unit = {}) = save({ roster ->
        roster.companions.firstOrNull { it.id == entry.id }?.let { old ->
            // Settings edit the name, character and orders only. Thread, brain and history are owned by
            // setup, the Brain page and Conversations; a stale sheet must not overwrite them.
            roster.replacing(entry.copy(thread_id = old.thread_id, home_workspace_id = old.home_workspace_id.ifEmpty { entry.home_workspace_id },
                provider = old.provider, model = old.model, history = old.history))
        }
    }, onSaved)

    fun switchTo(id: String) = save({ it.activating(id) })

    fun add(character: CompanionCharacter, name: String, onSaved: () -> Unit = {}) {
        val home = state.value.active?.home_workspace_id?.takeIf { it.isNotEmpty() }
            ?: mostRecentOpenWorkspace(browse.value.workspaces?.items.orEmpty())?.workspace_id ?: ""
        val entry = CompanionEntry(id = newCompanionId(), name = cleanCompanionName(name).ifEmpty { character.label },
            character = character.id, home_workspace_id = home)
        save({ it.adding(entry) }, onSaved)
    }

    fun remove(id: String, onSaved: () -> Unit = {}) = save({ it.removing(id) }, onSaved)

    /**
     * Settings → Brain. [change] comes from [classifyBrainChange]: in place re-selects the live
     * thread's model (and, on an empty thread, its provider) through `composer_select`; a provider
     * switch on a conversation with history starts a fresh thread. Either way the roster keeps the
     * provider/model so later threads use them. [onDone] gets null on success, else a message.
     */
    fun applyBrain(entry: CompanionEntry, target: ChatSelection, change: BrainChange, transcript: TranscriptModel?, brief: Boolean = true,
        onDone: (String?) -> Unit) {
        val current = session ?: return onDone("Connect to the host first.")
        if (change == BrainChange.None) return onDone(null)
        mutableState.update { it.copy(saving = true, saveError = null) }
        scope.launch {
            val error = try {
                when (change) {
                    BrainChange.HandOff -> switchCompanionProvider(target.provider.orEmpty(), target.model, brief)
                    else -> {
                        val live = transcript?.takeIf { entry.thread_id.isNotEmpty() && it.threadId == entry.thread_id && it.workspaceId == entry.home_workspace_id }
                        val selected = if (live == null) null else selectOnThread(live, target)
                        selected ?: (current.saveBrain(entry.id, target) as? CompanionSave.Failed)?.message
                    }
                }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { "Couldn't reach the host. Try again." }
            mutableState.update { it.copy(saving = false, saveError = error) }
            onDone(error)
        }
    }

    /**
     * Moves the active companion's conversation (one with history) to another [provider]/[model].
     * Returns null on success, else a message for the user.
     *
     * Context-preserving: `companion_brain_switch` keeps the same thread. With [brief] the outgoing
     * brain first writes a handoff brief; the daemon then switches the thread, replays the brief and
     * recent history to the new brain (hidden), and updates the roster. Progress shows through
     * `companion.brain_switch` ([handoffStatus]).
     */
    suspend fun switchCompanionProvider(provider: String, model: String?, brief: Boolean = true): String? {
        if (provider.isEmpty()) return "Choose a provider."
        val current = session ?: return "Connect to the host first."
        val entry = state.value.active ?: return "Companions haven't loaded yet."
        // The daemon keeps the same thread: the outgoing brain writes a brief, then the new one takes over.
        val error = current.brainSwitch(entry.id, provider, model?.ifEmpty { null }, brief) ?: return null
        return brainSwitchError(error, entry.name.ifBlank { "Your companion" })
    }

    /** Starts a fresh conversation; the current one moves to the companion's history. */
    fun newConversation(title: String, onSaved: () -> Unit = {}) {
        val active = state.value.active ?: return
        attempted.remove(active.id)
        save({ rosterWithNewConversation(it, active.id, title, System.currentTimeMillis()) }, onSaved)
    }

    /** Resumes an earlier conversation from history. */
    fun resumeConversation(threadId: String, currentTitle: String, onSaved: () -> Unit = {}) {
        val active = state.value.active ?: return
        save({ rosterResuming(it, active.id, threadId, currentTitle, System.currentTimeMillis()) }, onSaved)
    }

    /** Removes an earlier conversation from the list (the chat stays on the host). */
    fun forgetConversation(threadId: String) {
        val active = state.value.active ?: return
        save({ rosterForgetting(it, active.id, threadId) })
    }

    /** `composer_select` on the companion thread; a provider change on an empty thread goes provider first. */
    private suspend fun selectOnThread(model: TranscriptModel, target: ChatSelection): String? {
        val now = model.state.value.composer?.selection
        suspend fun choose(selection: ChatSelection): Operation? {
            val op = model.dispatch { id, n, w -> EventComposerSelect(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = model.workspaceId,
                thread_id = model.threadId, provider = selection.provider, model = selection.model, effort = selection.effort,
                access = selection.access, speed = selection.speed) } ?: return null
            if (op.state != "pending") return op
            return withTimeoutOrNull(BRAIN_WAIT_MS) {
                model.operations.mapNotNull { list -> list.find { it.intent_id == op.intent_id }?.takeIf { it.state != "pending" } }.first()
            }
        }
        val access = now?.access
        if (now?.provider != target.provider) {
            val switched = choose(ChatSelection(provider = target.provider, access = access))
            if (switched?.state != "succeeded") return composerError(switched?.error) ?: "Couldn't switch the provider."
            // The new provider's models load before the model can be chosen.
            withTimeoutOrNull(BRAIN_WAIT_MS) { model.state.first { it.composer?.selection?.provider == target.provider && it.composer?.catalogs?.models?.isNotEmpty() == true } }
        }
        var op = choose(target.copy(access = access))
        if (op?.state == "failed" && op.error?.code == "invalid_selection") op = choose(target.copy(effort = null, speed = null, access = access))
        return if (op?.state == "succeeded") null else composerError(op?.error) ?: "Couldn't change the model."
    }

    /** The companion's chat is gone from the host: forget it so setup starts a new one. */
    fun resetConversation(id: String, threadId: String) {
        attempted.remove(id)
        save({ roster ->
            roster.companions.firstOrNull { it.id == id && it.thread_id == threadId }?.let { roster.replacing(it.copy(thread_id = "")) }
        })
    }

    fun clearSaveError() = mutableState.update { it.copy(saveError = null) }

    // ---- Scheduled tasks ----

    fun setSchedulesOpen(open: Boolean) { schedulesOpen.value = open }
    fun refreshSchedules() { planner?.refresh() }
    fun setScheduleEnabled(entry: ScheduleEntry, enabled: Boolean) { planner?.setEnabled(entry, enabled) }
    fun runSchedule(entry: ScheduleEntry) { planner?.run(entry) }
    fun deleteSchedule(entry: ScheduleEntry) { planner?.delete(entry) }
    /** Creates [draft], or updates [original]; [onSaved] runs after the host accepted it. */
    fun saveSchedule(original: ScheduleEntry?, draft: ScheduleDraft, home: ScheduleHome?, onSaved: () -> Unit) {
        planner?.save(original, draft, home, onSaved)
    }
    fun clearScheduleErrors() { planner?.clearErrors() }

    override fun onCleared() { scope.cancel() }

    companion object {
        const val POLL_MS = 8_000L
        const val BRAIN_WAIT_MS = 20_000L
        const val OPEN_POLL_MS = 4_000L
    }
}

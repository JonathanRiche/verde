package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID

/*
 * D-09 approvals. The core owns approval truth: `thread:<id>.approval` comes from the current turn's
 * snapshot/tail (`approvalFromTurn`) and is cleared when any client resolves it. This file only
 * sends `approval_decide` and follows its receipt. The top-level helpers take a [CoreHost] and no
 * UI state so D-14's notification actions can reuse them.
 */

/** The daemon only supports a one-off allow or deny per request (`chat.turn.approve`). */
internal enum class ApprovalDecision(val wire: EventApprovalDecideDecision) {
    Approve(EventApprovalDecideDecision.approve),
    Deny(EventApprovalDecideDecision.deny),
}

/** The exact request a decision answers; the core rejects anything but the current turn + call. */
internal data class ApprovalTarget(val workspaceId: String, val threadId: String, val turnId: String, val callId: String) {
    companion object {
        fun of(workspaceId: String, threadId: String, approval: ChatApproval) =
            ApprovalTarget(workspaceId, threadId, approval.turn_id, approval.call_id)
    }
}

internal val ChatApproval.key get() = "$turn_id\u0000$call_id"

internal sealed interface DecideResult {
    /** The core accepted the intent; follow [intentId] in `hosts.operations`. */
    data class Sent(val intentId: String) : DecideResult
    /** The core refused the event outright (malformed or out of budget). */
    data object Rejected : DecideResult
    /** The host failed; its owner reports that separately. */
    data object Failed : DecideResult
}

/** Hands one decision to the core. Never logs the target or the request body. */
internal suspend fun decideApproval(host: CoreHost, target: ApprovalTarget, decision: ApprovalDecision,
                                    intentId: String = UUID.randomUUID().toString()): DecideResult = try {
    host.send { n, w ->
        EventApprovalDecide(now_ms=n, wall_time_ms=w, intent_id=intentId, workspace_id=target.workspaceId,
            thread_id=target.threadId, turn_id=target.turnId, call_id=target.callId, decision=decision.wire)
    }
    DecideResult.Sent(intentId)
} catch (e: CancellationException) { throw e }
catch (_: CoreInputRejected) { DecideResult.Rejected }
catch (_: Exception) { DecideResult.Failed }

/** Suspends until the core settles [intentId] (succeeded, failed or uncertain). */
internal suspend fun awaitOperation(host: CoreHost, intentId: String): Operation =
    host.hosts.mapNotNull { q -> q?.data?.operations?.find { it.intent_id == intentId }?.takeIf { it.state != "pending" } }.first()

/**
 * The open thread's current approval as a decision target, or null. The core only tracks approvals
 * for threads it has open (`thread_open`/`focus`), so a push action must open the thread first:
 * push payloads carry no `call_id` (push.md).
 */
internal suspend fun currentApprovalTarget(host: CoreHost, workspaceId: String, threadId: String): ApprovalTarget? = try {
    val view = CoreJson.decodeFromJsonElement<ThreadQuery>(host.query(chatSelector("thread", workspaceId, threadId))).data
    view?.approval?.takeIf { it.resolution != "pending" }?.let { ApprovalTarget.of(workspaceId, threadId, it) }
} catch (e: CancellationException) { throw e } catch (_: Exception) { null }

/** Codes meaning "this request is no longer the one waiting" (answered elsewhere or expired). */
internal fun staleApprovalError(error: LocalError?) =
    error != null && (error.code in STALE_CODES || error.rpc_code in STALE_CODES)
private val STALE_CODES = setOf("stale_approval", "not_found")

/** This phone's latest decision for one approval key. */
internal data class LocalDecision(val key: String, val decision: ApprovalDecision, val state: State, val error: LocalError? = null) {
    enum class State { Sending, Sent, Failed, Stale }
}

internal sealed interface ApprovalPhase {
    data object Idle : ApprovalPhase
    data class Sending(val decision: ApprovalDecision?) : ApprovalPhase
    /** The host accepted the decision; the agent has not picked it up yet. */
    data class Sent(val decision: ApprovalDecision?) : ApprovalPhase
    /** The request is no longer current — answered on another device or expired. */
    data object Stale : ApprovalPhase
    data class Failed(val decision: ApprovalDecision?, val uncertain: Boolean) : ApprovalPhase
}

/** Pure merge of the core's resolution with this phone's in-flight decision. */
internal fun approvalPhase(approval: ChatApproval, local: LocalDecision?): ApprovalPhase {
    val mine = local?.takeIf { it.key == approval.key }
    if (mine?.state == LocalDecision.State.Stale) return ApprovalPhase.Stale
    return when (approval.resolution) {
        "failed" -> if (staleApprovalError(approval.error)) ApprovalPhase.Stale
            else ApprovalPhase.Failed(mine?.decision, approval.error?.delivery == "uncertain")
        "pending" -> if (mine?.state == LocalDecision.State.Sent) ApprovalPhase.Sent(mine.decision) else ApprovalPhase.Sending(mine?.decision)
        else -> when (mine?.state) {
            LocalDecision.State.Sending -> ApprovalPhase.Sending(mine.decision)
            LocalDecision.State.Sent -> ApprovalPhase.Sent(mine.decision)
            LocalDecision.State.Failed -> ApprovalPhase.Failed(mine.decision, mine.error?.delivery == "uncertain")
            else -> ApprovalPhase.Idle
        }
    }
}

internal fun ApprovalPhase.canDecide() = this is ApprovalPhase.Idle || this is ApprovalPhase.Failed

/** What happened to an approval that just left the transcript. */
internal enum class ApprovalOutcome(val text: String) {
    Approved("Approved"),
    Denied("Denied"),
    Elsewhere("Approval answered on another device"),
    Closed("Approval request closed"),
}

internal data class OutcomeNotice(val outcome: ApprovalOutcome, val serial: Int)

/**
 * One thread's approval decisions. Tracks this phone's decision through the core receipt and
 * notices when the pending approval disappears, to say who resolved it.
 */
internal class ApprovalController(
    private val scope: CoroutineScope,
    private val workspaceId: String,
    private val threadId: String,
    thread: Flow<ChatThreadView?>,
    private val host: () -> CoreHost?,
    private val outcomeMs: Long = OUTCOME_MS,
) {
    private val mutableLocal = MutableStateFlow<LocalDecision?>(null)
    val local = mutableLocal.asStateFlow()
    private val mutableOutcome = MutableStateFlow<OutcomeNotice?>(null)
    /** Transient notice after an approval leaves; cleared after a few seconds. */
    val outcome = mutableOutcome.asStateFlow()
    private var serial = 0
    private var clearing: Job? = null

    init {
        scope.launch {
            var last: ChatApproval? = null
            thread.filterNotNull().collect { view ->
                val current = view.approval
                val previous = last
                last = current
                if (previous != null && current?.key != previous.key) resolved(previous, view)
                if (current != null) mutableOutcome.value = null
            }
        }
    }

    private fun resolved(previous: ChatApproval, view: ChatThreadView) {
        val mine = mutableLocal.value?.takeIf { it.key == previous.key }
        val outcome = when {
            mine != null && mine.state in setOf(LocalDecision.State.Sending, LocalDecision.State.Sent) ->
                if (mine.decision == ApprovalDecision.Approve) ApprovalOutcome.Approved else ApprovalOutcome.Denied
            view.turn?.let { activeTurn(it.status) } == true && view.turn.turn_id == previous.turn_id -> ApprovalOutcome.Elsewhere
            else -> ApprovalOutcome.Closed
        }
        if (mine != null) mutableLocal.value = null
        mutableOutcome.value = OutcomeNotice(outcome, ++serial)
        clearing?.cancel()
        clearing = scope.launch { delay(outcomeMs); mutableOutcome.value = null }
    }

    /** Sends [decision] for [approval] unless one is already on its way. Returns whether it was sent. */
    fun decide(approval: ChatApproval, decision: ApprovalDecision): Boolean {
        val host = host() ?: return false
        val key = approval.key
        if (!approvalPhase(approval, mutableLocal.value).canDecide()) return false
        mutableLocal.value = LocalDecision(key, decision, LocalDecision.State.Sending)
        scope.launch {
            val next = when (val result = decideApproval(host, ApprovalTarget.of(workspaceId, threadId, approval), decision)) {
                is DecideResult.Sent -> {
                    val op = awaitOperation(host, result.intentId)
                    when {
                        op.state == "succeeded" -> LocalDecision.State.Sent to null
                        staleApprovalError(op.error) -> LocalDecision.State.Stale to op.error
                        else -> LocalDecision.State.Failed to op.error
                    }
                }
                else -> LocalDecision.State.Failed to null
            }
            mutableLocal.update { if (it?.key == key) it.copy(state=next.first, error=next.second) else it }
        }
        return true
    }

    companion object { const val OUTCOME_MS = 4_000L }
}

// ---- What is being approved ----

internal enum class PreviewKind { Add, Remove, Context, Hunk }
internal data class PreviewLine(val kind: PreviewKind, val text: String)

/**
 * Structured view of an approval body. Providers send free text: Claude's bridge sends
 * `Tool:`/`Path:`/`Reason:` sections plus the tool input as JSON, Codex sends the bare command,
 * OpenCode an `Action:` line. Anything unrecognised is still shown verbatim in the details.
 */
internal data class ApprovalPreview(
    val tool: String? = null,
    val command: String? = null,
    val path: String? = null,
    val reason: String? = null,
    val changes: List<PreviewLine> = emptyList(),
    val changesTruncated: Boolean = false,
)

private const val PREVIEW_BYTES = 64 * 1024
internal const val PREVIEW_LINES = 24

internal fun approvalPreview(approval: ChatApproval): ApprovalPreview {
    val body = approval.body
    if (body.isBlank()) return ApprovalPreview()
    val head = if (body.length > PREVIEW_BYTES) body.substring(0, PREVIEW_BYTES) else body
    var tool: String? = null; var path: String? = null; var reason: String? = null; var command: String? = null
    val lines = ArrayList<PreviewLine>()
    var truncated = false
    fun add(kind: PreviewKind, text: String) {
        for (line in text.split('\n')) {
            if (lines.size >= PREVIEW_LINES) { truncated = true; return }
            lines.add(PreviewLine(kind, line))
        }
    }
    val sections = head.split("\n\n")
    var jsonStart = -1
    for ((index, section) in sections.withIndex()) {
        val s = section.trim()
        when {
            s.startsWith("Tool: ") -> tool = s.removePrefix("Tool: ").lineSequence().first().trim()
            s.startsWith("Action: ") -> tool = s.removePrefix("Action: ").lineSequence().first().trim()
            s.startsWith("Path: ") -> path = s.removePrefix("Path: ").lineSequence().first().trim()
            s.startsWith("Reason: ") -> reason = s.removePrefix("Reason: ").trim()
            s.startsWith("{") && jsonStart < 0 -> jsonStart = index
        }
    }
    if (jsonStart >= 0 && body.length <= PREVIEW_BYTES) {
        val input = try { Json.parseToJsonElement(sections.drop(jsonStart).joinToString("\n\n")) as? JsonObject } catch (_: Exception) { null }
        if (input != null) {
            fun str(name: String) = (input[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
            command = str("command") ?: (input["command"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }?.joinToString(" ")
            path = str("file_path") ?: str("notebook_path") ?: str("path") ?: path
            val edits = (input["edits"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: listOf(input)
            for (edit in edits) {
                val old = (edit["old_string"] as? JsonPrimitive)?.contentOrNull
                val new = (edit["new_string"] as? JsonPrimitive)?.contentOrNull
                if (old != null || new != null) {
                    if (!old.isNullOrEmpty()) add(PreviewKind.Remove, old)
                    if (!new.isNullOrEmpty()) add(PreviewKind.Add, new)
                }
            }
            if (lines.isEmpty()) str("content")?.let { add(PreviewKind.Add, it) }
        }
    }
    if (lines.isEmpty() && isUnifiedDiff(head)) {
        for (line in head.lineSequence()) {
            if (lines.size >= PREVIEW_LINES) { truncated = true; break }
            lines.add(when {
                line.startsWith("@@") -> PreviewLine(PreviewKind.Hunk, line)
                line.startsWith("+++") || line.startsWith("---") || line.startsWith("diff --git") -> PreviewLine(PreviewKind.Hunk, line)
                line.startsWith("+") -> PreviewLine(PreviewKind.Add, line.substring(1))
                line.startsWith("-") -> PreviewLine(PreviewKind.Remove, line.substring(1))
                else -> PreviewLine(PreviewKind.Context, line.removePrefix(" "))
            })
        }
    }
    // Codex's command approvals carry the bare command as the whole body.
    if (command == null && tool == null && lines.isEmpty() && approval.title.contains("command", ignoreCase=true) &&
        !head.contains("\n\n") && head.length <= 4096) command = head.trim()
    return ApprovalPreview(tool, command, path, reason, lines, truncated)
}

private fun isUnifiedDiff(text: String): Boolean {
    val lines = text.lineSequence().take(400).toList()
    return lines.any { it.startsWith("diff --git ") } ||
        (lines.any { it.startsWith("@@ ") } && lines.any { it.startsWith("+++ ") || it.startsWith("--- ") })
}

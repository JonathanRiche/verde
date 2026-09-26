package dev.verdeai.app

import dev.verdeai.core.*

/**
 * One visible transcript entry. Rows come from the core's thread projection; this layer only
 * groups and classifies them (desktop/web ChatPane parity) so each kind can get its own renderer.
 * D-07 (diff card) and D-09 (approval card) plug in through [TranscriptRenderers].
 */
internal sealed interface TranscriptItem {
    val key: String

    /** A user, assistant or plain system message rendered from the core's markdown AST. */
    data class Message(val row: ChatRow) : TranscriptItem { override val key get() = "r:" + row.id }
    /** A lone tool/command call. */
    data class Tool(val row: ChatRow) : TranscriptItem { override val key get() = "r:" + row.id }
    /** Consecutive tool calls (2+) or subagent calls (1+), collapsed behind a summary. */
    data class ToolGroup(val rows: List<ChatRow>, val subagent: Boolean) : TranscriptItem {
        override val key get() = "g:${if (subagent) "subagent" else "tool"}:" + rows.first().id
    }
    /** Model reasoning (`think` tool rows). */
    data class Think(val row: ChatRow) : TranscriptItem { override val key get() = "r:" + row.id }
    /** "Changed files" VERDE_DIFF_V2 summary row — D-07 replaces the default renderer. */
    data class Diff(val row: ChatRow) : TranscriptItem { override val key get() = "r:" + row.id }
    /** System notices, including A-09 access-cap notices. */
    data class Notice(val row: ChatRow) : TranscriptItem { override val key get() = "r:" + row.id }
    /** The latest provider usage summary, parsed by the core. */
    data class Usage(val row: ChatRow, val usage: ChatUsage) : TranscriptItem { override val key get() = "r:" + row.id }
    /** Live "Working · m:ss" footer for the core's active turn. */
    data class Working(val turn: ChatTurn, val waitingApproval: Boolean) : TranscriptItem { override val key get() = "working" }
    /** Pending tool approval — D-09 replaces the default renderer. */
    data class Approval(val approval: ChatApproval) : TranscriptItem { override val key get() = "approval:${approval.turn_id}:${approval.call_id}" }
}

internal const val DIFF_MARKER = "VERDE_DIFF_V2\n"
private const val HIDDEN_AUTHOR = "__verde_codex_background_snapshot"

private fun shellLike(body: String): Boolean {
    val t = body.trimStart()
    if (t.trimEnd().length < 8) return false
    return listOf("/usr/bin/bash", "/bin/bash", "bash -lc", "/usr/bin/env bash", "/bin/sh -lc", "/usr/bin/sh").any { t.startsWith(it) }
}

internal fun isDiffRow(row: ChatRow) = row.role == "system" && row.author == "Changed files" && row.body.startsWith(DIFF_MARKER)

internal fun isThinkRow(row: ChatRow) = row.role == "system" && (row.tool?.kind == "think" ||
    (row.tool == null && row.kind == "tool" && (row.author == "Think" || row.author == "Thinking")))

internal fun isCommandRow(row: ChatRow): Boolean {
    if (row.role != "system") return false
    if (row.tool?.kind == "subagent" || row.author == "Subagent") return true
    if (row.tool != null && row.tool.kind != "think") return true
    return row.author == "Ran command" || row.author == "Command failed" || shellLike(row.body)
}

internal fun isSubagentRow(row: ChatRow): Boolean {
    if (row.tool?.kind == "subagent" || row.author == "Subagent") return true
    if (row.author == "Ran command" || row.author == "Command failed") return false
    val tool = toolField(row.body, "Tool")
    if (tool != null && tool.trim().lowercase() in setOf("task", "agent", "subagent", "taskexecute", "spawnagent", "spawn_agent")) return true
    if (toolField(row.body, "Input")?.contains("\"subagent_type\"") == true) return true
    return toolField(row.body, "Output")?.contains("<task id=\"") == true
}

/** The `Label:\n...` section of a tool body, up to the next blank line. */
internal fun toolField(body: String, label: String): String? {
    val prefix = "$label:\n"
    val start = if (body.startsWith(prefix)) prefix.length else body.indexOf("\n\n$prefix").let { if (it < 0) return null else it + 2 + prefix.length }
    val rest = body.substring(start)
    val end = rest.indexOf("\n\n")
    return (if (end >= 0) rest.substring(0, end) else rest).trim().ifEmpty { null }
}

internal fun commandFailed(row: ChatRow) = row.tool?.status == "failed" || row.author == "Command failed" || row.body.startsWith("Command failed")
internal fun commandRunning(row: ChatRow) = row.tool?.status == "in_progress" || row.tool?.status == "pending"

/** Whitespace-collapsed one-line preview of the leading slice of a (possibly huge) tool body. */
internal fun commandPreview(body: String, max: Int = 400): String =
    body.take(max).replace(Regex("\\s+"), " ").trim()

/** First [max] lines without splitting a multi-megabyte body into lines. */
internal fun leadingLines(body: String, max: Int): Pair<String, Boolean> {
    val text = body.trim()
    if (text.isEmpty() || max <= 0) return "" to false
    var from = 0
    repeat(max) {
        val nl = text.indexOf('\n', from)
        if (nl < 0) return text to false
        from = nl + 1
    }
    return text.substring(0, from - 1) to (from < text.length)
}

internal fun countLines(body: String): Int {
    val text = body.trim()
    return if (text.isEmpty()) 0 else 1 + text.count { it == '\n' }
}

/** Host paths stay abstract on the phone; only the file name is shown. */
internal fun basename(path: String) = path.trimEnd('/').substringAfterLast('/').ifEmpty { path }

internal data class ToolCounts(val count: Int, val completed: Int, val failed: Int, val running: Int)

internal fun toolCounts(rows: List<ChatRow>): ToolCounts {
    var failed = 0; var running = 0
    for (row in rows) if (commandFailed(row)) failed++ else if (commandRunning(row)) running++
    return ToolCounts(rows.size, rows.size - failed - running, failed, running)
}

internal fun toolGroupSummary(rows: List<ChatRow>, subagent: Boolean, elapsed: String?): String {
    val c = toolCounts(rows)
    val noun = if (subagent) (if (c.count == 1) "subagent" else "subagents") else (if (c.count == 1) "tool call" else "tool calls")
    return buildList {
        add("${c.count} $noun"); add("${c.completed} completed")
        if (c.failed > 0) add("${c.failed} failed")
        if (c.running > 0) add("${c.running} running")
        if (c.running > 0 && elapsed != null) add(elapsed)
    }.joinToString(" · ")
}

/** Pure projection from the core's thread view to renderable items (oldest first). */
internal fun transcriptItems(view: ChatThreadView): List<TranscriptItem> {
    val out = ArrayList<TranscriptItem>(view.rows.size + 2)
    val lastUsage = if (view.usage != null) view.rows.indexOfLast { it.role == "system" && it.author == "Usage" } else -1
    var run = ArrayList<ChatRow>()
    var runSubagent = false
    fun flush() {
        when {
            run.isEmpty() -> Unit
            runSubagent -> out.add(TranscriptItem.ToolGroup(run, true))
            run.size >= 2 -> out.add(TranscriptItem.ToolGroup(run, false))
            else -> out.add(TranscriptItem.Tool(run.single()))
        }
        run = ArrayList(); runSubagent = false
    }
    view.rows.forEachIndexed { index, row ->
        if (row.author == HIDDEN_AUTHOR) return@forEachIndexed
        if (isCommandRow(row) && !isDiffRow(row)) {
            val subagent = isSubagentRow(row)
            if (run.isNotEmpty() && subagent != runSubagent) flush()
            runSubagent = subagent
            run.add(row)
            return@forEachIndexed
        }
        flush()
        out.add(when {
            isDiffRow(row) -> TranscriptItem.Diff(row)
            isThinkRow(row) -> TranscriptItem.Think(row)
            index == lastUsage -> TranscriptItem.Usage(row, view.usage!!)
            row.role == "system" -> TranscriptItem.Notice(row)
            else -> TranscriptItem.Message(row)
        })
    }
    flush()
    view.approval?.let { out.add(TranscriptItem.Approval(it)) }
    view.turn?.takeIf { activeTurn(it.status) }?.let { out.add(TranscriptItem.Working(it, it.status == "waiting_approval" || view.approval != null)) }
    return out
}

internal fun workingLabel(item: TranscriptItem.Working, elapsed: String?): String {
    val verb = when {
        item.turn.stop_pending -> "Stopping"
        item.waitingApproval -> "Waiting for approval"
        else -> "Working"
    }
    return if (elapsed != null) "$verb · $elapsed" else verb
}

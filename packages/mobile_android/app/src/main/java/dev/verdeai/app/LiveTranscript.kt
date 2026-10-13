package dev.verdeai.app

import dev.verdeai.core.CompanionTranscriptMessage
import java.util.UUID

/*
 * The text record of a live voice session, saved into the companion's chat (core
 * `companion_transcript_save`). One line per user utterance and per spoken reply (streaming
 * pieces merged), plus short system lines for tool hand-offs. Never audio. Pure and unit tested.
 */

internal const val LIVE_USER_AUTHOR = "You (voice)"
internal const val LIVE_SYSTEM_AUTHOR = "Live"
internal const val LIVE_SAVE_INTERVAL_MS = 120_000L

internal fun liveAssistantAuthor(name: String) = "${name.ifBlank { "Companion" }} (voice)"

/** Saved messages written by a live session ("You (voice)", "Moss (voice)", "Live"). */
internal fun isVoiceAuthor(author: String) = author == LIVE_SYSTEM_AUTHOR || author.endsWith(" (voice)")

internal data class LiveLine(val key: String, val role: String, val author: String, val body: String, val createdAtMs: Long, val open: Boolean)

internal class LiveTranscript(
    val sessionId: String = UUID.randomUUID().toString(),
    private val assistantAuthor: String,
) {
    private val lines = ArrayList<LiveLine>()
    private var next = 0
    private var openUser = -1
    private var openAssistant = -1
    /** A streamed user line closed because the reply began; its final transcript may still arrive. */
    private var unconfirmedUser = -1
    /** Lines before this index are saved (or were blank). */
    var saved = 0
        private set

    val all: List<LiveLine> get() = lines.toList()

    /** Content worth saving: anything the user or the companion actually said. */
    val hasContent get() = lines.any { it.role != "system" && it.body.isNotBlank() }

    private fun add(role: String, author: String, body: String, now: Long, open: Boolean): Int {
        lines += LiveLine((next++).toString(), role, author, body, now, open)
        return lines.size - 1
    }

    private fun update(index: Int, change: (LiveLine) -> LiveLine) { lines[index] = change(lines[index]) }

    fun header(text: String, now: Long) { if (lines.isEmpty()) add("system", LIVE_SYSTEM_AUTHOR, text, now, open = false) }

    fun userPartial(text: String, cumulative: Boolean, now: Long) {
        if (openUser < 0) {
            if (text.isBlank()) return
            unconfirmedUser = -1
            openUser = add("user", LIVE_USER_AUTHOR, text.trimStart(), now, open = true)
        } else update(openUser) { it.copy(body = if (cumulative) text else it.body + text) }
    }

    fun userFinal(text: String, now: Long) {
        val target = if (openUser >= 0) openUser else unconfirmedUser
        openUser = -1
        unconfirmedUser = -1
        when {
            // Already saved with the streamed words: keep the record as saved.
            target in 0 until saved -> Unit
            target >= 0 -> update(target) { it.copy(body = text.trim().ifEmpty { it.body.trim() }, open = false) }
            text.isNotBlank() -> add("user", LIVE_USER_AUTHOR, text.trim(), now, open = false)
        }
    }

    fun assistantDelta(delta: String, now: Long) {
        if (openAssistant < 0) {
            if (delta.isBlank()) return
            // The model answering means the user's (streamed) utterance is over.
            val streamed = openUser
            closeUser()
            unconfirmedUser = streamed
            openAssistant = add("assistant", assistantAuthor, delta.trimStart(), now, open = true)
        } else update(openAssistant) { it.copy(body = it.body + delta) }
    }

    /** End of a response (or barge-in): the reply line is complete as heard. */
    fun assistantDone() {
        if (openAssistant >= 0) { update(openAssistant) { it.copy(body = it.body.trim(), open = false) }; openAssistant = -1 }
    }

    /** Gemini: the turn is over, so any streamed user words are final too. */
    fun turnDone() { assistantDone(); closeUser() }

    private fun closeUser() {
        if (openUser >= 0) { update(openUser) { it.copy(body = it.body.trim(), open = false) }; openUser = -1 }
    }

    fun system(text: String, now: Long) { add("system", LIVE_SYSTEM_AUTHOR, text, now, open = false) }

    /**
     * Lines ready to save, in order: closed lines after the last save, stopping at the first line
     * still being spoken. [final] closes everything (the session ended). Empty sessions save nothing.
     */
    fun pending(final: Boolean): List<LiveLine> {
        if (final) { assistantDone(); closeUser() }
        if (!hasContent) return emptyList()
        val out = ArrayList<LiveLine>()
        for (i in saved until lines.size) {
            val line = lines[i]
            if (line.open) break
            out += line
        }
        return out
    }

    /** The first [count] pending lines are stored; later saves start after them. */
    fun markSaved(count: Int) { saved = (saved + count).coerceAtMost(lines.size) }
}

/** Wire form for `companion_transcript_save`; blank lines are dropped (the core skips them too). */
internal fun transcriptMessages(lines: List<LiveLine>): List<CompanionTranscriptMessage> =
    lines.filter { it.body.isNotBlank() }.map { CompanionTranscriptMessage(key = it.key, role = it.role, author = it.author, body = it.body, created_at_ms = it.createdAtMs) }

/** Splits a save into events of at most [max] lines (the core's per-event limit). */
internal fun saveBatches(lines: List<LiveLine>, max: Int = 200): List<List<LiveLine>> = lines.chunked(max)

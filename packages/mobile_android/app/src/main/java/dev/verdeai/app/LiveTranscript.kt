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

/**
 * A user or companion line. User lines are [open] while being spoken, then closed; only
 * [committed] lines are saved (an utterance commits on its final transcript or when the reply
 * starts; one closed by a pause or a new item may still be replaced by a longer version of itself).
 */
internal data class LiveLine(val key: String, val role: String, val author: String, val body: String, val createdAtMs: Long, val open: Boolean,
    val committed: Boolean = !open)

/** Lowercase words only: punctuation dropped, whitespace collapsed (for comparing transcript snapshots). */
internal fun normalizeSpeech(text: String): String {
    val out = StringBuilder(text.length)
    var space = false
    for (c in text) {
        if (c.isLetterOrDigit()) {
            if (space && out.isNotEmpty()) out.append(' ')
            space = false
            out.append(c.lowercaseChar())
        } else if (c.isWhitespace()) space = true
    }
    return out.toString()
}

/** [snapshot]'s words continue [prefix] (whole words; both normalized). */
internal fun extendsSpeech(snapshot: String, prefix: String) = prefix.isNotEmpty() && (snapshot == prefix || snapshot.startsWith("$prefix "))

/** The original text after the first [prefixLength] normalized characters, leading punctuation trimmed. */
internal fun speechRemainder(text: String, prefixLength: Int): String {
    if (prefixLength <= 0) return text.trim()
    var length = 0
    var space = false
    for ((i, c) in text.withIndex()) {
        if (c.isLetterOrDigit()) {
            if (space && length > 0) length++
            space = false
            length++
            if (length >= prefixLength) return text.substring(i + 1).trimStart { !it.isLetterOrDigit() }.trimEnd()
        } else if (c.isWhitespace()) space = true
    }
    return ""
}

internal const val USER_LINE_IDLE_MS = 3_000L

internal class LiveTranscript(
    val sessionId: String = UUID.randomUUID().toString(),
    private val assistantAuthor: String,
) {
    private val lines = ArrayList<LiveLine>()
    private var next = 0
    private var openUser: String? = null
    private var openItem: String? = null
    private var lastUserUpdate = 0L
    private var openAssistant: String? = null
    /** Closed by a pause or a new item, not yet committed: a longer snapshot of the same words replaces it. */
    private var tentative: String? = null
    private var tentativeItem: String? = null
    /** Committed by the reply starting; a late final transcript (OpenAI) may still correct it. */
    private var unconfirmedUser: String? = null
    /** xAI-style cumulative transcripts keep growing across utterances. */
    private var cumulativeStream = false
    /** Normalized words already committed in the current cumulative stream, and the latest committed line. */
    private var streamNorm = ""
    private var lastCommittedNorm = ""
    private var lastClosedUserNorm = ""
    /** Lines before this index are saved (or were blank). */
    var saved = 0
        private set

    val all: List<LiveLine> get() = lines.toList()

    /** Content worth saving: anything the user or the companion actually said. */
    val hasContent get() = lines.any { it.role != "system" && it.body.isNotBlank() }

    private fun index(key: String?) = if (key == null) -1 else lines.indexOfFirst { it.key == key }

    private fun add(role: String, author: String, body: String, now: Long, open: Boolean, committed: Boolean = !open): String {
        val key = (next++).toString()
        lines += LiveLine(key, role, author, body, now, open, committed)
        return key
    }

    private fun update(key: String?, change: (LiveLine) -> LiveLine) {
        val i = index(key)
        if (i >= 0) lines[i] = change(lines[i])
    }

    /** Removes an unsaved line (a superseded or repeated utterance). */
    private fun drop(key: String?) {
        val i = index(key)
        if (i >= saved) lines.removeAt(i)
    }

    fun header(text: String, now: Long) { if (lines.isEmpty()) add("system", LIVE_SYSTEM_AUTHOR, text, now, open = false) }

    /** A cumulative snapshot without the words earlier committed lines already hold. */
    private fun strip(text: String): String {
        val words = normalizeSpeech(text)
        val prefix = when {
            extendsSpeech(words, streamNorm) -> streamNorm
            extendsSpeech(words, lastCommittedNorm) -> lastCommittedNorm
            else -> { streamNorm = ""; "" }
        }
        return speechRemainder(text, prefix.length)
    }

    fun userPartial(text: String, cumulative: Boolean, now: Long, itemId: String? = null) {
        if (cumulative) cumulativeStream = true
        // A different transcription item is a different utterance.
        if (openUser != null && itemId != null && openItem != null && itemId != openItem) closeUser(commit = false)
        val body = if (cumulative) strip(text) else text
        if (openUser == null) {
            val start = body.trimStart()
            if (start.isBlank()) return
            settleTentative(start)
            unconfirmedUser = null
            openUser = add("user", LIVE_USER_AUTHOR, start, now, open = true)
            openItem = itemId
        } else if (cumulative) {
            // Same item: the snapshot replaces the line (never a new line); an empty remainder changes nothing.
            if (body.isNotBlank()) update(openUser) { it.copy(body = body) }
        } else update(openUser) { it.copy(body = it.body + text) }
        lastUserUpdate = now
    }

    fun userFinal(text: String, now: Long, itemId: String? = null) {
        val body = if (cumulativeStream) strip(text) else text.trim()
        if (openUser != null && (itemId == null || openItem == null || itemId == openItem)) {
            if (body.isNotBlank()) update(openUser) { it.copy(body = body) }
            closeUser(commit = true)
            return
        }
        if (itemId != null && itemId == tentativeItem && tentative != null) {
            if (body.isNotBlank()) update(tentative) { it.copy(body = body) }
            commit(tentative, stream = true)
            tentative = null; tentativeItem = null
            return
        }
        val late = unconfirmedUser
        unconfirmedUser = null
        if (late != null && index(late) >= saved) {
            if (body.isNotBlank()) update(late) { it.copy(body = body) }
            return
        }
        if (body.isBlank() || normalizeSpeech(body) == lastClosedUserNorm) return
        settleTentative(body)
        val key = add("user", LIVE_USER_AUTHOR, body, now, open = false, committed = false)
        lastClosedUserNorm = normalizeSpeech(body)
        commit(key, stream = true)
    }

    /** No transcript update for a while: the utterance is over (not yet committed). */
    fun tick(now: Long) {
        if (openUser != null && now - lastUserUpdate >= USER_LINE_IDLE_MS) closeUser(commit = false)
    }

    /** The model began answering: the user's utterance is done. */
    fun assistantStarted() {
        val user = openUser
        closeUser(commit = true)
        if (user != null && index(user) >= 0) unconfirmedUser = user
        tentative?.let { commit(it, stream = false) }
        tentative = null; tentativeItem = null
    }

    fun assistantDelta(delta: String, now: Long) {
        if (openAssistant == null) {
            if (delta.isBlank()) return
            assistantStarted()
            openAssistant = add("assistant", assistantAuthor, delta.trimStart(), now, open = true)
        } else update(openAssistant) { it.copy(body = it.body + delta) }
    }

    /** End of a response (or barge-in): the reply line is complete as heard. */
    fun assistantDone() {
        if (openAssistant != null) { update(openAssistant) { it.copy(body = it.body.trim(), open = false, committed = true) }; openAssistant = null }
    }

    /** End of the model's turn; the user's line is left to its own signals (they may already be talking). */
    fun turnDone() = assistantDone()

    private fun closeUser(commit: Boolean) {
        val key = openUser ?: return
        val item = openItem
        openUser = null; openItem = null
        val line = lines.getOrNull(index(key)) ?: return
        val body = line.body.trim()
        val words = normalizeSpeech(body)
        // An exact repeat of the previous utterance is the same utterance reported twice.
        if (words.isEmpty() || words == lastClosedUserNorm) { drop(key); return }
        update(key) { it.copy(body = body, open = false, committed = false) }
        lastClosedUserNorm = words
        if (commit) commit(key, stream = true) else {
            tentative?.let { commit(it, stream = false) }
            tentative = key; tentativeItem = item
        }
    }

    /** A new utterance [start]s: a tentative line it merely extends is dropped, otherwise it is committed. */
    private fun settleTentative(start: String) {
        val key = tentative ?: return
        tentative = null; tentativeItem = null
        val line = lines.getOrNull(index(key)) ?: return
        if (extendsSpeech(normalizeSpeech(start), normalizeSpeech(line.body)) && index(key) >= saved) drop(key)
        else commit(key, stream = false)
    }

    private fun commit(key: String?, stream: Boolean) {
        val line = lines.getOrNull(index(key)) ?: return
        update(key) { it.copy(open = false, committed = true) }
        if (stream && cumulativeStream && line.role == "user") {
            val words = normalizeSpeech(line.body)
            streamNorm = if (streamNorm.isEmpty()) words else "$streamNorm $words"
            lastCommittedNorm = words
        }
    }

    fun system(text: String, now: Long) { add("system", LIVE_SYSTEM_AUTHOR, text, now, open = false) }

    /** Recent spoken lines for the live captions: the same merged, de-duplicated lines that get saved. */
    fun captions(max: Int = LIVE_CAPTIONS): List<LiveCaption> =
        lines.filter { it.role != "system" && it.body.isNotBlank() }.takeLast(max).map { LiveCaption(it.role == "user", it.body, it.open) }

    /**
     * Lines ready to save, in order: committed lines after the last save, stopping at the first line
     * still being spoken or not yet committed. [final] closes and commits everything (the session
     * ended). Empty sessions save nothing.
     */
    fun pending(final: Boolean): List<LiveLine> {
        if (final) {
            assistantDone()
            closeUser(commit = true)
            tentative?.let { commit(it, stream = false) }
            tentative = null; tentativeItem = null
        }
        if (!hasContent) return emptyList()
        val out = ArrayList<LiveLine>()
        for (i in saved until lines.size) {
            val line = lines[i]
            if (line.open || !line.committed) break
            out += line
        }
        return out
    }

    /** The first [count] pending lines are stored; later saves start after them. */
    fun markSaved(count: Int) { saved = (saved + count).coerceAtMost(lines.size) }
}

/** Feeds one provider event into the transcript. */
internal fun LiveTranscript.feed(event: LiveEvent, now: Long) {
    when (event) {
        is LiveEvent.UserPartial -> userPartial(event.text, event.cumulative, now, event.itemId)
        is LiveEvent.UserText -> userFinal(event.text, now, event.itemId)
        LiveEvent.ResponseStarted -> assistantStarted()
        is LiveEvent.AssistantText -> assistantDelta(event.delta, now)
        LiveEvent.TurnDone, LiveEvent.Interrupted -> assistantDone()
        else -> Unit
    }
}

/** Wire form for `companion_transcript_save`; blank lines are dropped (the core skips them too). */
internal fun transcriptMessages(lines: List<LiveLine>): List<CompanionTranscriptMessage> =
    lines.filter { it.body.isNotBlank() }.map { CompanionTranscriptMessage(key = it.key, role = it.role, author = it.author, body = it.body, created_at_ms = it.createdAtMs) }

/** Splits a save into events of at most [max] lines (the core's per-event limit). */
internal fun saveBatches(lines: List<LiveLine>, max: Int = 200): List<List<LiveLine>> = lines.chunked(max)

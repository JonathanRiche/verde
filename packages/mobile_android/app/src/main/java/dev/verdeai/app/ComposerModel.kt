package dev.verdeai.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.Base64
import java.util.UUID

/** A caret-anchored `@file` or `/command` token; offsets are UTF-16, like the web composer. */
internal data class ComposerToken(val start: Int, val end: Int, val query: String)

/** Web `fileMentionAtCaret`: the whitespace-delimited word under the caret, if it starts with `@`. */
internal fun fileMentionAtCaret(draft: String, caret: Int): ComposerToken? {
    if (caret < 0 || caret > draft.length) return null
    var start = caret
    var end = caret
    while (start > 0 && !draft[start - 1].isWhitespace()) start--
    while (end < draft.length && !draft[end].isWhitespace()) end++
    if (start >= draft.length || draft[start] != '@' || caret <= start) return null
    return ComposerToken(start, end, draft.substring(start + 1, caret))
}

/** Web `slashTokenAtCaret`: the leading `/name` token while the caret is inside it. */
internal fun slashTokenAtCaret(draft: String, caret: Int): ComposerToken? {
    val start = draft.indexOfFirst { it !in " \t\r\n" }
    if (start < 0 || draft[start] != '/' || draft.getOrNull(start + 1) == '/') return null
    var end = start + 1
    while (end < draft.length && !draft[end].isWhitespace()) end++
    if (caret <= start || caret > end) return null
    return ComposerToken(start, end, draft.substring(start + 1, caret))
}

private fun replaceToken(draft: String, token: ComposerToken, text: String): TextFieldValue {
    val suffix = draft.substring(token.end)
    val replacement = text + if (suffix.startsWith(" ")) "" else " "
    val caret = token.start + replacement.length + if (suffix.startsWith(" ")) 1 else 0
    return TextFieldValue(draft.substring(0, token.start) + replacement + suffix, TextRange(caret))
}

/** Web `acceptFileMention`: only repository-relative daemon paths are inserted. */
internal fun acceptFileMention(value: TextFieldValue, path: String): TextFieldValue? {
    val token = fileMentionAtCaret(value.text, value.selection.start) ?: return null
    if (path.isEmpty() || path.any { it == '\r' || it == '\n' || it == '\u0000' || it == '\\' } || path.startsWith("/") ||
        Regex("^[a-zA-Z]:").containsMatchIn(path) || path.split('/').any { it == ".." || it.isEmpty() }) return null
    return replaceToken(value.text, token, "@$path")
}

internal fun acceptSlashCommand(value: TextFieldValue, name: String): TextFieldValue? {
    val token = slashTokenAtCaret(value.text, value.selection.start) ?: return null
    if (!Regex("^/[^/\\s]+$").matches(name)) return null
    return replaceToken(value.text, token, name)
}

/** What the send button would do with this draft; mirrors web `parseSlashCommand` / `classifyBangCommand`. */
internal sealed interface ComposerAction {
    data object Prompt : ComposerAction
    data object Shell : ComposerAction
    /** `//text` sends `/text` as a prompt. */
    data class Literal(val text: String) : ComposerAction
    data class Slash(val name: String, val args: String) : ComposerAction
}

internal fun composerAction(draft: String): ComposerAction {
    if (draft.startsWith("!") && !draft.startsWith("!!")) return ComposerAction.Shell
    val text = draft.trim { it in " \t\r\n" }
    if (!text.startsWith("/")) return ComposerAction.Prompt
    if (text.startsWith("//")) return ComposerAction.Literal(text.substring(1))
    val end = text.indexOfFirst { it in " \t\r\n" }
    val name = if (end < 0) text else text.substring(0, end)
    val args = if (end < 0) "" else text.substring(end).trim()
    return ComposerAction.Slash(name, args)
}

/** Web `followupKind`: providers with daemon steering steer; images always queue (the core forces it too). */
internal fun followupKind(provider: String?, images: Boolean): EventFollowupSubmitKind =
    if (!images && provider in setOf("codex", "claude", "pi")) EventFollowupSubmitKind.steer else EventFollowupSubmitKind.queue

internal enum class ComposerPicker { Provider, Model, Effort, Access, Speed }

/** Web `PROVIDER_OPTIONS`, in desktop order. */
internal val PROVIDERS = listOf("codex" to "Codex", "claude" to "Claude", "cursor" to "Cursor", "opencode" to "OpenCode",
    "pi" to "Pi", "fx" to "FX", "grok" to "Grok", "muse" to "Muse")

/** One image ready for the core: already downscaled and re-encoded by [ImageAttachments]. */
internal class PickedImage(val name: String, val mime: String, val bytes: ByteArray)

/** User-facing text for a failed composer operation; codes and daemon messages only, never draft content. */
internal fun composerError(error: LocalError?): String? {
    if (error == null) return null
    return when (error.code) {
        "draft_unavailable" -> "The draft changed or is still loading. Try again."
        "turn_active" -> "The agent is still replying. Send it as a follow-up."
        "followup_unavailable" -> "A follow-up is already waiting for this reply."
        "stale_followup" -> "That follow-up has changed. Check it and try again."
        "insufficient_scope" -> "This phone isn't allowed to do that. Re-pair it with more access on the desktop."
        "empty_command" -> "Type a command after !."
        "unknown_command" -> "That command isn't available for this provider."
        "provider_thread_required" -> "Send a message first. This command needs an existing conversation."
        "invalid_selection" -> "That option isn't available for this model."
        "resource_limit" -> "That's too large to keep on the phone. Remove an image or shorten the message."
        "invalid_input" -> "The phone couldn't use that. Try a smaller image or a shorter message."
        "stale_confirmation" -> "The command confirmation expired. Send it again."
        "thread_unavailable" -> "This chat isn't available right now."
        "offline", "unavailable" -> "The host is offline. Your draft is kept."
        else -> error.message.ifBlank { "That didn't work (${error.code})." }
    }
}

/**
 * The composer of one chat thread. The core owns the draft (text, attachments, selection) and
 * persists it; this class only keeps the in-progress text field, debounces `draft_set`, and turns
 * UI actions into intents. Draft text and image bytes are never logged.
 */
internal class ComposerModel(
    private val chat: TranscriptModel,
    private val scope: CoroutineScope,
    private val draftDelayMs: Long = DRAFT_DELAY_MS,
    private val searchDelayMs: Long = SEARCH_DELAY_MS,
) {
    var focusRequest by mutableStateOf(0)
        private set
    var imagePreviews by mutableStateOf<Map<String, ByteArray>>(emptyMap())
        private set
    var field by mutableStateOf(TextFieldValue(""))
        private set
    /** A local message (rejected intent, oversized image, …); cleared on the next action. */
    var notice by mutableStateOf<String?>(null)
        private set
    /** A send, slash command or attachment change is being handed to the core. */
    var busy by mutableStateOf(false)
        private set
    var mention by mutableStateOf<ComposerToken?>(null)
        private set
    var slash by mutableStateOf<ComposerToken?>(null)
        private set

    /** Local edits not yet handed to the core; the core's draft never overwrites them. */
    private var editing = false
    private var dispatching = 0
    private var adopted = false
    private var saveJob: Job? = null
    private var searchJob: Job? = null
    private var searched: String? = null
    private var slashRequested = false
    var slashLoading by mutableStateOf(false)
        private set
    private val lock = Mutex()

    init {
        scope.launch { chat.state.map { it.composer?.draft }.distinctUntilChanged().collect { adopt(it) } }
    }

    private val workspaceId get() = chat.workspaceId
    private val threadId get() = chat.threadId

    /** Takes the core's draft (restore, pull-back, clear after send) unless the user is mid-edit. */
    private fun adopt(draft: ChatDraft?) {
        val ids = draft?.attachments.orEmpty().map { it.local_id }.toSet()
        imagePreviews = imagePreviews.filterKeys { it in ids }
        if (draft == null || editing || dispatching > 0) return
        if (!adopted || draft.text != field.text) {
            adopted = true
            field = TextFieldValue(draft.text, TextRange(draft.text.length))
            updateTokens(field)
        }
    }

    fun edit(value: TextFieldValue) {
        val changed = value.text != field.text
        field = value
        if (changed) {
            editing = true
            notice = null
            saveJob?.cancel()
            saveJob = scope.launch { delay(draftDelayMs); withContext(NonCancellable) { flush() } }
        }
        updateTokens(value)
    }

    /** Append a review prompt without discarding an unsent draft or dispatching a turn. */
    fun commentOnDiff(path: String, additions: ULong, deletions: ULong) {
        if (busy || chat.latestComposer()?.send_operation?.state == "pending") return
        val root = chat.state.value.browse.workspaces?.items?.find { it.workspace_id == workspaceId }?.path.orEmpty().trimEnd('/')
        val mention = if (root.isNotEmpty() && path.startsWith("$root/")) path.removePrefix("$root/") else path
        val before = field.text
        val next = before + (if (before.isEmpty() || before.endsWith('\n')) "" else "\n") +
            "About your edit to @$mention (+$additions/-$deletions): "
        edit(TextFieldValue(next, TextRange(next.length)))
        focusRequest++
    }

    private fun updateTokens(value: TextFieldValue) {
        val caret = value.selection.start
        slash = slashTokenAtCaret(value.text, caret)
        val token = fileMentionAtCaret(value.text, caret)
        mention = token
        if (token != null && token.query != searched) {
            searchJob?.cancel()
            searchJob = scope.launch {
                delay(searchDelayMs)
                searched = token.query
                chat.dispatch { id, n, w -> EventMentionSearch(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, query=token.query) }
            }
        }
        if (slash != null) requestSlash()
    }

    /** The core fetches `provider.slash.list` once per provider selection; each fetch spends a receipt. */
    private fun requestSlash() {
        if (slashRequested || chat.latestComposer()?.catalogs?.slash?.isNotEmpty() == true) return
        slashRequested = true
        slashLoading = true
        scope.launch {
            try {
                val op = outcome(chat.dispatch { id, n, w -> EventSlashSearch(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, query="") })
                if (op == null || op.state == "failed") fail(op)
            } finally { slashLoading = false }
        }
    }

    /** Opens the provider catalog without replacing an existing message. */
    fun openSlashCommands() {
        if (!field.text.isBlank() && slash == null) return
        if (!slashLoading && chat.latestComposer()?.catalogs?.slash?.isEmpty() != false) slashRequested = false
        if (field.text.isBlank()) edit(TextFieldValue("/", TextRange(1))) else requestSlash()
        focusRequest++
    }

    fun acceptMention(path: String) {
        acceptFileMention(field, path)?.let { edit(it) }
    }

    fun acceptSlash(name: String) {
        acceptSlashCommand(field, name)?.let { edit(it) }
    }

    /** The core's attachments of this draft, re-sent by reference (empty bytes; the core keeps them). */
    private fun references(): List<AttachmentInput> = chat.latestComposer()?.draft?.attachments.orEmpty()
        .map { AttachmentInput(local_id=it.local_id, name=it.name, mime=it.mime, byte_size=it.byte_size, bytes_base64="") }

    private suspend fun setDraft(text: String, inputs: List<AttachmentInput>): Operation? {
        dispatching++
        try {
            return chat.dispatch { id, n, w -> EventDraftSet(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, text=text, attachments=inputs) }
        } finally { dispatching-- }
    }

    /** Hands pending text to the core; false when the core refused it (the edit stays local). */
    suspend fun flush(): Boolean = lock.withLock {
        if (!editing) return true
        editing = false
        val op = setDraft(field.text, references())
        if (op == null || op.state == "failed") {
            editing = true
            notice = composerError(op?.error) ?: composerError(LocalError(code="unavailable", message=""))
            return false
        }
        adopt(chat.latestComposer()?.draft)
        return true
    }

    /** Leaving the screen: the model's scope is ending, so the last edit goes out detached. */
    fun flushDetached() {
        saveJob?.cancel()
        if (!editing) return
        editing = false
        val text = field.text
        val inputs = references()
        detached.launch {
            try { chat.dispatch { id, n, w -> EventDraftSet(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, text=text, attachments=inputs) } }
            catch (_: Exception) { }
        }
    }

    /** App backgrounded: save now instead of waiting for the debounce. */
    fun flushNow() {
        saveJob?.cancel()
        if (editing) scope.launch { flush() }
    }

    private inline fun action(crossinline block: suspend () -> Unit) {
        if (busy) return
        busy = true
        notice = null
        scope.launch { try { block() } finally { busy = false } }
    }

    /** Send, steer/queue, `!` shell confirmation or `/command`, depending on the draft and turn. */
    fun submit() = action {
        saveJob?.cancel()
        if (!flush()) return@action
        val composer = chat.latestComposer() ?: return@action
        val text = composer.draft.text
        if (text.isBlank() && composer.draft.attachments.isEmpty()) return@action
        when (val parsed = composerAction(text)) {
            ComposerAction.Shell -> fail(send(composer.draft.revision))
            is ComposerAction.Slash -> runSlash(parsed, text)
            is ComposerAction.Literal -> {
                val op = setDraft(parsed.text, references())
                if (op?.state == "failed") return@action fail(op)
                adopt(chat.latestComposer()?.draft)
                chat.latestComposer()?.let { fail(sendOrFollow(it)) }
            }
            ComposerAction.Prompt -> fail(sendOrFollow(composer))
        }
    }

    private suspend fun send(revision: String) =
        chat.dispatch { id, n, w -> EventSend(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, draft_revision=revision) }

    private suspend fun sendOrFollow(composer: ChatComposerView): Operation? {
        val state = chat.state.value
        if (state.turn == null) return send(composer.draft.revision)
        val kind = followupKind(composer.selection.provider ?: state.thread?.thread?.provider, composer.draft.attachments.isNotEmpty())
        return chat.dispatch { id, n, w -> EventFollowupSubmit(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId,
            draft_revision=composer.draft.revision, kind=kind) }
    }

    private fun fail(op: Operation?) {
        if (op == null) notice = composerError(LocalError(code="unavailable", message=""))
        else if (op.state == "failed") notice = composerError(op.error)
    }

    private suspend fun runSlash(action: ComposerAction.Slash, text: String) {
        requestSlash()
        val commands = chat.state.map { it.composer?.catalogs?.slash.orEmpty() }.let { flow ->
            withTimeoutOrNull(SLASH_WAIT_MS) { flow.first { it.isNotEmpty() } } ?: chat.latestComposer()?.catalogs?.slash.orEmpty()
        }
        val command = commands.find { it.label == action.name || "/" + it.label == action.name }
        if (command == null) { notice = if (commands.isEmpty()) "Commands aren't available right now." else "Unknown command ${action.name}."; return }
        if (!command.enabled) { notice = "${action.name} is ${command.reason ?: "unavailable"}."; return }
        val op = outcome(chat.dispatch { id, n, w -> EventSlashRun(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId,
            command=command.id, args=action.args) })
        if (op == null || op.state == "failed") return fail(op)
        clearIfUnchanged(text)
    }

    /** Clears the draft once a command ran, unless the user already typed something new. */
    private suspend fun clearIfUnchanged(text: String) {
        if (field.text != text || editing) return
        lock.withLock {
            if (field.text != text || editing) return
            val op = setDraft("", references())
            if (op?.state != "failed") { field = TextFieldValue(""); updateTokens(field) }
        }
    }

    /** Waits (bounded) for a pending operation's outcome in the core's `hosts` operations. */
    private suspend fun outcome(op: Operation?): Operation? {
        if (op == null || op.state != "pending") return op
        return withTimeoutOrNull(OUTCOME_WAIT_MS) {
            chat.operations.mapNotNull { list -> list.find { it.intent_id == op.intent_id } }.first { it.state != "pending" }
        } ?: chat.operation(op.intent_id) ?: op
    }

    /** Run or dismiss the `!command` the core staged for confirmation. */
    fun confirmShell(confirmation: ChatShellConfirmation, accept: Boolean) = action {
        val text = field.text
        val op = chat.dispatch { id, n, w -> EventShellConfirm(now_ms=n, wall_time_ms=w, intent_id=id, confirmation_id=confirmation.id, accept=accept) }
        if (op == null || op.state == "failed") return@action fail(op)
        if (accept && composerAction(text) == ComposerAction.Shell) clearIfUnchanged(text)
    }

    fun select(picker: ComposerPicker, id: String) = action {
        val composer = chat.latestComposer() ?: return@action
        val s = composer.selection
        val next = when (picker) {
            ComposerPicker.Provider -> ChatSelection(provider=id, model=null, effort=null, access=s.access, speed=null)
            ComposerPicker.Model -> s.copy(model=id)
            ComposerPicker.Effort -> s.copy(effort=id)
            ComposerPicker.Access -> s.copy(access=id)
            ComposerPicker.Speed -> s.copy(speed=id)
        }
        var op = choose(next)
        // A new model may not offer the old effort or speed; fall back to its defaults.
        if (op?.state == "failed" && op.error?.code == "invalid_selection" && picker == ComposerPicker.Model) op = choose(next.copy(effort=null, speed=null))
        if (op != null && op.state != "failed") slashRequested = false
        fail(op)
    }

    private suspend fun choose(s: ChatSelection) = chat.dispatch { id, n, w -> EventComposerSelect(now_ms=n, wall_time_ms=w, intent_id=id,
        workspace_id=workspaceId, thread_id=threadId, provider=s.provider, model=s.model, effort=s.effort, access=s.access, speed=s.speed) }

    /** New images go to the core with bytes; the draft's existing ones by reference. */
    fun attach(images: List<PickedImage>, rejected: Int = 0) = action {
        if (!flush()) return@action
        val existing = references()
        val room = MAX_IMAGES - existing.size
        val accepted = images.take(room.coerceAtLeast(0))
        val total = chat.latestComposer()?.draft?.attachments.orEmpty().sumOf { it.byte_size.toLongOrNull() ?: 0L } + accepted.sumOf { it.bytes.size.toLong() }
        when {
            accepted.isEmpty() && images.isNotEmpty() -> { notice = "Up to $MAX_IMAGES images per message."; return@action }
            total > MAX_TOTAL_BYTES -> { notice = "These images are too large together. Send some first."; return@action }
        }
        if (accepted.isNotEmpty()) {
            val added = accepted.map { AttachmentInput(local_id="img-" + UUID.randomUUID(), name=it.name, mime=it.mime,
                byte_size=it.bytes.size.toString(), bytes_base64=Base64.getEncoder().encodeToString(it.bytes)) }
            val op = setDraft(field.text, existing + added)
            if (op == null || op.state == "failed") return@action fail(op)
            imagePreviews = imagePreviews + added.mapIndexed { index, input -> input.local_id to accepted[index].bytes }.toMap()
        }
        notice = when {
            rejected > 0 -> "Only images can be attached from the phone."
            accepted.size < images.size -> "Up to $MAX_IMAGES images per message."
            else -> null
        }
    }

    fun detach(localId: String) = action {
        if (!flush()) return@action
        fail(setDraft(field.text, references().filterNot { it.local_id == localId }))
    }

    fun showNotice(text: String) { notice = text }

    fun retryFollowup(f: ChatFollowup) = action {
        fail(chat.dispatch { id, n, w -> EventFollowupRetry(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, followup_id=f.id) })
    }

    /** Pull back restores the follow-up into the draft; local unsaved text goes to the core first. */
    fun pullBackFollowup(f: ChatFollowup) = action {
        if (!flush()) return@action
        fail(chat.dispatch { id, n, w -> EventFollowupPullBack(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, followup_id=f.id) })
    }

    fun cancelFollowup(f: ChatFollowup) = action {
        fail(chat.dispatch { id, n, w -> EventFollowupCancel(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, followup_id=f.id) })
    }

    companion object {
        /** Each `draft_set` spends a core receipt, so typing is batched generously. */
        const val DRAFT_DELAY_MS = 600L
        const val SEARCH_DELAY_MS = 200L
        const val SLASH_WAIT_MS = 5_000L
        const val OUTCOME_WAIT_MS = 30_000L
        const val MAX_IMAGES = 4
        /** Per image after re-encoding; the core also enforces the daemon's own attachment limit. */
        const val MAX_IMAGE_BYTES = 160 * 1024
        /** Base64 in the core's 512 KiB draft record, with room for the text. */
        const val MAX_TOTAL_BYTES = 320L * 1024
        private val detached = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }
}

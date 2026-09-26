package dev.verdeai.app

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import java.util.UUID

/** One user input before the core's key encoding (terminal.md). */
internal sealed interface TermInput {
    data class Text(val text: String) : TermInput
    /** [key] is a core key name (`Escape`, `ArrowUp`, …) or a single ASCII character. */
    data class Key(val key: String, val ctrl: Boolean = false, val alt: Boolean = false, val shift: Boolean = false) : TermInput
    data class Paste(val text: String) : TermInput
}

internal data class TerminalUiState(
    val terminalId: String? = null,
    val view: TerminalView? = null,
    val snapshot: TerminalSnapshot? = null,
    /** True after the emulator had to be rebuilt from a later replay (gap, reconnect or apply failure). */
    val replayGap: Boolean = false,
    val creating: Boolean = false,
    /** Terminal-level failure that input cannot recover from (create/attach rejected). */
    val failure: String? = null,
    val ctrl: Boolean = false,
    val alt: Boolean = false,
)

/** Sticky Ctrl/Alt from the accessory row apply to the next input only. */
internal fun withModifiers(input: TermInput, ctrl: Boolean, alt: Boolean): List<TermInput> = when (input) {
    is TermInput.Key -> listOf(input.copy(ctrl = input.ctrl || ctrl, alt = input.alt || alt))
    is TermInput.Paste -> listOf(input)
    is TermInput.Text -> {
        val single = input.text.length == 1 && input.text[0].code in 0x20..0x7e
        when {
            (ctrl || alt) && single -> listOf(TermInput.Key(input.text, ctrl = ctrl, alt = alt))
            else -> splitLines(input.text)
        }
    }
}

/** IMEs commit newlines as text; the terminal expects the Enter key (CR). */
internal fun splitLines(text: String): List<TermInput> = buildList {
    var start = 0
    for (i in text.indices) if (text[i] == '\n') {
        if (i > start) add(TermInput.Text(text.substring(start, i)))
        add(TermInput.Key("Enter"))
        start = i + 1
    }
    if (start < text.length) add(TermInput.Text(text.substring(start)))
}

internal fun canWrite(host: HostView?) = host?.scopes?.contains("terminal:write") == true

/**
 * Screen model for one daemon session on the selected host (`session.*` via the core only).
 * It owns the local VT for its lifetime; leaving the screen detaches the pump and frees the
 * VT but never kills the session. Terminal contents are never logged.
 */
internal class TerminalModel(
    private val hosts: HostsModel,
    private val browse: BrowseModel,
    private val saved: SavedStateHandle,
    private val hostId: String?,
    private val workspaceId: String,
    terminalId: String?,
    private val resizeDebounceMs: Long = 150,
) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(TerminalUiState(terminalId = terminalId ?: saved.get<String>(CREATED_KEY)))
    val state = mutableState.asStateFlow()
    private val desired = MutableStateFlow<Pair<Int, Int>?>(null)
    private val inputs = Channel<TermInput>(Channel.UNLIMITED)
    private var core: CoreHost? = null
    private var vt: TerminalVt? = null

    /** Connected, attached, running and allowed to type. */
    val interactive: StateFlow<Boolean> = combine(browse.state, state) { b, s ->
        b.hostId == hostId && b.networkAvailable && b.host?.phase == "ready" && canWrite(b.host) && s.view?.attached == true &&
            s.view.session_status == "running" && s.failure == null
    }.stateIn(scope, SharingStarted.Eagerly, false)

    init {
        scope.launch {
            val host = hostId?.let { id -> try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            if (host == null) { fail("This host is no longer available."); return@launch }
            core = host
            state.value.terminalId?.let { attach(host, it) } ?: create(host)
        }
        scope.launch { for (input in inputs) deliver(input) }
        scope.launch { resizes() }
    }

    private fun fail(message: String) = mutableState.update { it.copy(failure = message, creating = false) }

    private suspend fun create(host: CoreHost) {
        // The core needs a measured grid and a ready connection; creation is never retried automatically.
        val size = desired.filterNotNull().first()
        browse.state.first { it.host?.phase == "ready" && it.networkAvailable }
        if (!canWrite(browse.state.value.host)) { fail("This phone can view terminals but not open them."); return }
        mutableState.update { it.copy(creating = true) }
        val intent = UUID.randomUUID().toString()
        val created = try {
            host.createTerminal(replies = true) { n, w -> EventTerminalCreate(now_ms = n, wall_time_ms = w, intent_id = intent,
                workspace_id = workspaceId, cwd = null, cols = size.first, rows = size.second) }
        } catch (e: CancellationException) { throw e } catch (e: CoreInputRejected) {
            fail(if (e.status == 5) TOO_MANY else "Couldn't open a terminal.")
            return
        } catch (_: Exception) { fail("Couldn't open a terminal."); return }
        if (created == null) {
            val code = host.operations.value?.data?.items?.find { it.intent_id == intent }?.error?.code
            fail(when (code) {
                "workspace_path_unavailable" -> "This workspace has no folder on the host."
                "not_connected" -> "Not connected. Try again when the host is reachable."
                else -> "Couldn't open a terminal."
            })
            return
        }
        val (id, terminal) = created
        // A restored screen attaches to this session instead of creating another one.
        saved[CREATED_KEY] = id
        mutableState.update { it.copy(terminalId = id, creating = false) }
        observe(host, id, terminal)
    }

    private suspend fun attach(host: CoreHost, id: String) {
        val terminal = try { host.openTerminal(id, replies = canWrite(browse.state.value.host)) }
            catch (e: CancellationException) { throw e } catch (_: Exception) { fail("Connection unavailable — reopen Verde."); return }
        observe(host, id, terminal)
        try {
            host.send { n, w -> EventTerminalAttach(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(), terminal_id = id) }
        } catch (e: CancellationException) { throw e } catch (e: CoreInputRejected) {
            fail(if (e.status == 5) TOO_MANY else "Couldn't open this terminal.")
        } catch (_: Exception) { fail("Connection unavailable — reopen Verde.") }
    }

    private fun observe(host: CoreHost, id: String, terminal: TerminalVt) {
        vt = terminal
        scope.launch { focus(host, id) }
        scope.launch { terminal.snapshot.collect { snapshot -> mutableState.update { it.copy(snapshot = snapshot) } } }
        // The first reset is the initial replay; later ones rebuilt the screen from a partial replay.
        scope.launch { terminal.resets.collect { count -> if (count > 1) mutableState.update { it.copy(replayGap = true) } } }
        scope.launch {
            host.terminalView(id).collect { view ->
                mutableState.update { it.copy(view = view) }
                // The local grid follows the session's size (resize acks and host-side changes).
                if (view != null) terminal.resize(view.cols, view.rows)
            }
        }
    }

    /**
     * Claims the core's single focus slot (shared with the transcript via [FocusClaim]) so a
     * late unfocus from the chat screen just left cannot clear it. No thread is focused here.
     */
    private suspend fun focus(host: CoreHost, id: String) {
        FocusClaim.owner = this
        try {
            host.send { n, w -> EventFocus(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                workspace_id = workspaceId, thread_id = null, terminal_id = id) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { }
    }

    /** Grid measured from the canvas; drives `terminal_create` and `terminal_resize`. */
    fun measured(cols: Int, rows: Int) { desired.value = cols to rows }

    @OptIn(FlowPreview::class)
    private suspend fun resizes() {
        var sent: Pair<Int, Int>? = null
        combine(desired, state.map { it.view }.distinctUntilChanged(), interactive) { size, view, ready -> Triple(size, view, ready) }
            .debounce(resizeDebounceMs)
            .collect { (size, view, ready) ->
                val id = state.value.terminalId
                // Re-check after every reconnect, but never fight a size the host changed later.
                if (size == null || view == null || !ready || id == null) { sent = null; return@collect }
                if (size == sent) return@collect
                sent = size
                if (view.cols == size.first && view.rows == size.second) return@collect
                try {
                    core?.send { n, w -> EventTerminalResize(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                        terminal_id = id, cols = size.first, rows = size.second) }
                } catch (e: CancellationException) { throw e } catch (_: Exception) { }
            }
    }

    fun toggleCtrl() = mutableState.update { it.copy(ctrl = !it.ctrl) }
    fun toggleAlt() = mutableState.update { it.copy(alt = !it.alt) }
    fun dismissGap() = mutableState.update { it.copy(replayGap = false) }

    fun input(input: TermInput) {
        if (!interactive.value) return
        val current = state.value
        mutableState.update { it.copy(ctrl = false, alt = false) }
        withModifiers(input, current.ctrl, current.alt).forEach { inputs.trySend(it) }
    }

    /** Scrollback in rows (positive = older), within the VT's page-granular history. */
    fun scroll(rows: Int) { val terminal = vt ?: return; scope.launch { terminal.scroll(rows) } }

    private suspend fun deliver(input: TermInput) {
        val host = core ?: return
        val id = state.value.terminalId ?: return
        // Typing returns to the live screen first.
        state.value.snapshot?.scroll_offset?.takeIf { it > 0 }?.let { vt?.scroll(-it.toInt()) }
        val modes = state.value.snapshot?.vt_modes ?: VtModes(application_cursor = false, bracketed_paste = false)
        val payload = when (input) {
            is TermInput.Text -> EventTerminalInputInput(EventTerminalInputInputKind.text, text = input.text, ctrl = false, alt = false, shift = false)
            is TermInput.Paste -> EventTerminalInputInput(EventTerminalInputInputKind.paste, text = input.text, ctrl = false, alt = false, shift = false)
            is TermInput.Key -> EventTerminalInputInput(EventTerminalInputInputKind.key, key = input.key, ctrl = input.ctrl, alt = input.alt, shift = input.shift)
        }
        try {
            host.send { n, w -> EventTerminalInput(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                terminal_id = id, vt_modes = modes, input = payload) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {
            // Unencodable keys (e.g. Ctrl+digit) are rejected by the core and dropped; never retried.
        }
    }

    override fun onCleared() {
        val id = state.value.terminalId
        val host = core
        val terminal = vt
        scope.cancel()
        inputs.close()
        if (host != null && id != null && terminal != null) host.closeTerminal(id, terminal)
        if (host != null && FocusClaim.owner === this) {
            FocusClaim.owner = null
            // Detached so the release still reaches the core after this model's scope is gone.
            released.launch {
                try {
                    host.send { n, w -> EventFocus(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                        workspace_id = null, thread_id = null, terminal_id = null) }
                } catch (_: Exception) { }
            }
        }
    }

    companion object {
        private val released = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        const val CREATED_KEY = "created_terminal"
        private const val TOO_MANY = "Too many terminals were opened this session. Reopen Verde to open more."
    }
}

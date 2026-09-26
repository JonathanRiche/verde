package dev.verdeai.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.put
import java.util.UUID

/** Encodes the core's revision-1 thread identity exactly like `chat.selectorFor`. */
internal fun chatSelector(prefix: String, workspaceId: String, threadId: String): String {
    val json = JsonArray(listOf(JsonPrimitive(workspaceId), JsonPrimitive(threadId))).toString()
    val out = StringBuilder(prefix).append(':')
    for (byte in json.encodeToByteArray()) {
        val b = byte.toInt() and 0xFF
        val c = b.toChar()
        if ((c in 'a'..'z') || (c in 'A'..'Z') || (c in '0'..'9') || c == '-' || c == '_' || c == '.' || c == '~') out.append(c)
        else out.append('%').append(HEX[b shr 4]).append(HEX[b and 15])
    }
    return out.toString()
}
private const val HEX = "0123456789ABCDEF"

/**
 * Which on-screen surface currently owns the core's single `focus` slot. A screen only clears
 * focus it still owns, so a late unfocus from a screen being left never clobbers the next one.
 * Other focus-sending screens (e.g. the terminal view) should claim it the same way.
 */
internal object FocusClaim {
    var owner: Any? = null
}

internal data class TranscriptState(
    val workspaceId: String,
    val threadId: String,
    val browse: BrowseState = BrowseState(),
    val thread: ChatThreadView? = null,
    val composer: ChatComposerView? = null,
    /** Error code of the latest failed `focus` receipt, e.g. `unavailable` or `thread_unavailable`. */
    val focusError: String? = null,
    val stopSending: Boolean = false,
    val fatal: Boolean = false,
) {
    val turn get() = thread?.turn?.takeIf { activeTurn(it.status) }
    val canStop get() = composer?.can_stop == true && turn?.stop_pending == false && !stopSending
    val stopping get() = turn?.stop_pending == true || stopSending
}

internal fun activeTurn(status: String) = status in setOf("working", "waiting", "accepted", "running", "waiting_approval")

/**
 * One chat thread of the selected host. The transcript, page, turn and composer all come from the
 * core's `thread:` / `composer:` projections; this class only turns UI actions into intents.
 * Message bodies are never logged or persisted here.
 */
internal class TranscriptModel(
    private val hosts: HostsModel,
    private val browse: StateFlow<BrowseState>,
    val workspaceId: String,
    val threadId: String,
    private val unfocusDelayMs: Long = UNFOCUS_DELAY_MS,
) : ViewModel(), HighlightSource {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(TranscriptState(workspaceId, threadId))
    val state = mutableState.asStateFlow()
    private val visible = MutableStateFlow(false)
    val threadSelector = chatSelector("thread", workspaceId, threadId)
    val composerSelector = chatSelector("composer", workspaceId, threadId)

    private var core: CoreHost? = null
    private val connected = MutableStateFlow<CoreHost?>(null)
    private var focused = false
    private var focusIntent: String? = null
    private var focusEpoch = -1
    private var readyEpoch = 0
    private var requestedCursor: String? = null
    private val renders = RenderCache()
    /** D-09: this thread's approval decisions (helpers in Approvals.kt are shared with D-14). */
    val approvals = ApprovalController(viewModelScope, workspaceId, threadId, state.map { it.thread }, host = { core })

    init {
        scope.launch { browse.collect { value -> mutableState.update { it.copy(browse=value) } } }
        scope.launch { browse.map { it.hostId }.distinctUntilChanged().collectLatest { id -> observe(id) } }
    }

    private suspend fun observe(id: String?) = coroutineScope {
        core = null; connected.value = null; focused = false; focusIntent = null; requestedCursor = null
        mutableState.update { it.copy(thread=null, composer=null, focusError=null, fatal=false) }
        if (id == null) return@coroutineScope
        val host = try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (host == null) { mutableState.update { it.copy(fatal=true) }; return@coroutineScope }
        core = host
        connected.value = host
        launch {
            host.views.map { it[threadSelector] to it[composerSelector] }.distinctUntilChanged().collect { (thread, composer) ->
                mutableState.update { it.copy(thread=decodeThread(thread), composer=decodeComposer(composer)) }
            }
        }
        launch { host.failed.collect { failed -> if (failed) mutableState.update { it.copy(fatal=true) } } }
        var lastReady = false
        combine(visible, host.hosts, host.operations, browse.map { it.networkAvailable }) { shown, query, operations, network ->
            val view = query?.data?.items?.firstOrNull()
            Gate(shown, ready(view), settling(view, network), failure(operations))
        }
            .distinctUntilChanged()
            .collectLatest { gate ->
                if (gate.ready && !lastReady) readyEpoch++
                lastReady = gate.ready
                mutableState.update { it.copy(focusError=gate.failure) }
                if (gate.visible) {
                    // Each intent spends a core receipt: wait out an in-flight connection instead of
                    // spending one on a certain rejection, and re-focus only after a rejected focus
                    // *and* a fresh ready edge so this can never loop.
                    if (!focused && !gate.settling) sendFocus(host)
                    else if (focused && gate.failure != null && readyEpoch > focusEpoch) sendFocus(host)
                } else if (focused) {
                    delay(unfocusDelayMs)
                    sendUnfocus(host)
                }
            }
    }

    private data class Gate(val visible: Boolean, val ready: Boolean, val settling: Boolean, val failure: String?)

    /**
     * Paired, online and still connecting or syncing. Offline, failed or trust-blocked hosts are not
     * settling: focus is sent at once so K-17 attention still clears, then retried when ready.
     */
    private fun settling(view: HostView?, network: Boolean): Boolean {
        if (view == null) return true
        if (!network || view.auth_state != "paired" || view.update_required || view.trust_proposal != null) return false
        if (view.phase in setOf("failed", "awaiting_trust")) return false
        return !ready(view)
    }

    private fun ready(view: HostView?) = view != null && view.phase == "ready" && view.auth_state == "paired" &&
        view.sync_state in setOf("ready", "stale")

    private fun failure(query: OperationsQuery?): String? {
        val id = focusIntent ?: return null
        val op = query?.data?.items?.find { it.intent_id == id } ?: return null
        return if (op.state == "failed") op.error?.code ?: "failed" else null
    }

    private fun decodeThread(value: JsonElement?): ChatThreadView? = value?.let {
        try { CoreJson.decodeFromJsonElement<ThreadQuery>(it).data } catch (_: Exception) { null }
    }
    private fun decodeComposer(value: JsonElement?): ChatComposerView? = value?.let {
        try { CoreJson.decodeFromJsonElement<ComposerQuery>(it).data } catch (_: Exception) { null }
    }

    private suspend fun sendFocus(host: CoreHost) {
        val id = UUID.randomUUID().toString()
        focusIntent = id; focused = true; focusEpoch = readyEpoch
        FocusClaim.owner = this
        send(host) { n, w -> EventFocus(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, thread_id=threadId, terminal_id=null) }
    }

    private suspend fun sendUnfocus(host: CoreHost) {
        focused = false
        if (FocusClaim.owner !== this) return
        FocusClaim.owner = null
        send(host) { n, w -> EventFocus(now_ms=n, wall_time_ms=w, intent_id=UUID.randomUUID().toString(), workspace_id=null, thread_id=null, terminal_id=null) }
    }

    private suspend fun send(host: CoreHost, event: (Long, Long) -> Event): Boolean = try {
        host.send(event); true
    } catch (e: CancellationException) { throw e }
    catch (_: CoreInputRejected) { false }
    catch (_: Exception) { mutableState.update { it.copy(fatal=true) }; false }

    /** The screen is on display; focus (and so K-17 attention clearing) follows it. */
    fun setVisible(shown: Boolean) { visible.value = shown }

    /** Explicit user retry: re-focus reloads the newest page and restarts the live tail. */
    fun retry() {
        val host = core ?: return
        requestedCursor = null
        scope.launch { sendFocus(host) }
    }

    /** Requests the next older page once per cursor; the core rejects overlapping pages anyway. */
    fun loadOlder(force: Boolean = false) {
        val host = core ?: return
        val page = state.value.thread?.page ?: return
        if (!page.has_older || page.loading || page.cursor == null) return
        if (!force && requestedCursor == page.cursor) return
        requestedCursor = page.cursor
        scope.launch {
            send(host) { n, w -> EventThreadLoadOlder(now_ms=n, wall_time_ms=w, intent_id=UUID.randomUUID().toString(),
                workspace_id=workspaceId, thread_id=threadId) }
        }
    }

    /** Stop uses the core's own active turn id; a second tap while stopping is ignored. */
    fun stop() {
        val host = core ?: return
        val current = state.value
        val turn = current.turn ?: return
        if (!current.canStop) return
        mutableState.update { it.copy(stopSending=true) }
        scope.launch {
            try {
                send(host) { n, w -> EventTurnCancel(now_ms=n, wall_time_ms=w, intent_id=UUID.randomUUID().toString(),
                    workspace_id=workspaceId, thread_id=threadId, turn_id=turn.turn_id) }
            } finally { mutableState.update { it.copy(stopSending=false) } }
        }
    }

    // ---- D-08 composer hooks ----

    /** The composer in the transcript's bottom bar; shares this model's scope, core and lifetime. */
    private val composerModel = lazy { ComposerModel(this, scope) }
    internal val composer: ComposerModel by composerModel

    /** Intent outcomes of the connected host, as the core reports them in `operations`. */
    @OptIn(ExperimentalCoroutinesApi::class)
    internal val operations: Flow<List<Operation>> = connected
        .flatMapLatest { host -> host?.operations?.map { it?.data?.items.orEmpty() } ?: flowOf(emptyList()) }
        .distinctUntilChanged()

    /** The newest outcome of one of this screen's intents. */
    internal fun operation(id: String): Operation? = core?.operations?.value?.data?.items?.find { it.intent_id == id }

    /** The core's newest composer projection, read straight from the host (no collector lag). */
    internal fun latestComposer(): ChatComposerView? = decodeComposer(core?.views?.value?.get(composerSelector))

    /**
     * Sends one chat intent with a fresh id and returns its operation. A call the core refuses
     * outright (malformed or over a size limit; state unchanged) comes back as a failed operation
     * with `invalid_input` / `resource_limit`; null means there is no connected core at all.
     */
    internal suspend fun dispatch(build: (id: String, now: Long, wall: Long) -> Event): Operation? {
        val host = core ?: return null
        val id = UUID.randomUUID().toString()
        try { host.send { n, w -> build(id, n, w) } }
        catch (e: CancellationException) { throw e }
        catch (e: CoreInputRejected) {
            return Operation(id, "failed", LocalError(code=if (e.status == 5) "resource_limit" else "invalid_input", message=""))
        } catch (_: Exception) { mutableState.update { it.copy(fatal=true) }; return null }
        return host.operations.value?.data?.items?.find { it.intent_id == id } ?: Operation(id, "pending", null)
    }

    // ---- K-11 rendering utilities (pure core queries; work offline) ----

    fun cachedMarkdown(text: String): RenderResult<List<MarkdownNode>>? = renders.markdown[text]
    suspend fun markdown(text: String): RenderResult<List<MarkdownNode>> = renders.markdown[text] ?: run {
        val result = utility<MarkdownQuery, List<MarkdownNode>>(buildJsonObject { put("utility", "markdown"); put("text", text) }.toString()) { it.data?.nodes }
        result.also { renders.markdown[text] = it }
    }

    override fun cachedHighlight(code: String, language: String): RenderResult<List<RenderSpan>>? = renders.highlight[language + "\u0000" + code]
    override suspend fun highlight(code: String, language: String): RenderResult<List<RenderSpan>> = renders.highlight[language + "\u0000" + code] ?: run {
        val result = utility<HighlightQuery, List<RenderSpan>>(buildJsonObject { put("utility", "highlight"); put("text", code); put("language", language) }.toString()) { it.data?.spans }
        result.also { renders.highlight[language + "\u0000" + code] = it }
    }

    fun cachedDiff(text: String): RenderResult<DiffView>? = renders.diff[text]
    suspend fun diff(text: String): RenderResult<DiffView> = renders.diff[text] ?: run {
        val result = utility<DiffQuery, DiffView>(buildJsonObject { put("utility", "diff"); put("text", text) }.toString()) { it.data }
        result.also { renders.diff[text] = it }
    }

    /** D-07: locates each file record of a (possibly large) VERDE_DIFF_V2 body so files render one at a time. */
    fun cachedDiffIndex(text: String): RenderResult<DiffIndexView>? = renders.diffIndex[text]
    suspend fun diffIndex(text: String): RenderResult<DiffIndexView> = renders.diffIndex[text] ?: run {
        val selector = buildJsonObject { put("utility", "diff_index"); put("text", text) }.toString()
        utility<DiffIndexQuery, DiffIndexView>(selector, MAX_INDEX_SELECTOR) { it.data }.also { renders.diffIndex[text] = it }
    }

    private suspend inline fun <reified Q, T> utility(selector: String, limit: Int = MAX_RENDER_SELECTOR, crossinline data: (Q) -> T?): RenderResult<T> {
        if (selector.length > limit) return RenderResult(null)
        val host = core ?: return RenderResult(null)
        return try {
            RenderResult(data(CoreJson.decodeFromJsonElement<Q>(host.query(selector))))
        } catch (e: CancellationException) { throw e } catch (_: Exception) { RenderResult(null) }
    }

    override fun onCleared() {
        if (composerModel.isInitialized()) composer.flushDetached()
        val host = core
        if (focused && host != null && FocusClaim.owner === this) {
            FocusClaim.owner = null
            // Detached so the unfocus still reaches the core after this model's scope is gone.
            detached.launch {
                try {
                    host.send { n, w -> EventFocus(now_ms=n, wall_time_ms=w, intent_id=UUID.randomUUID().toString(),
                        workspace_id=null, thread_id=null, terminal_id=null) }
                } catch (_: Exception) { }
            }
        }
        focused = false
        scope.cancel()
    }

    companion object {
        const val UNFOCUS_DELAY_MS = 500L
        /** The core caps utility input at 64 KiB; larger bodies render as plain text. */
        const val MAX_RENDER_SELECTOR = 72 * 1024
        /** `diff_index` only frames records; the core bounds it by the 1 MiB query selector. */
        const val MAX_INDEX_SELECTOR = 1024 * 1024
        private val detached = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }
}

/** A finished render query; `value == null` means "render the source text as-is". */
internal class RenderResult<T>(val value: T?)

/** Bounded LRU caches keyed by source text, owned by one transcript screen. */
internal class RenderCache(max: Int = 256) {
    val markdown = lru<RenderResult<List<MarkdownNode>>>(max)
    val highlight = lru<RenderResult<List<RenderSpan>>>(max / 4)
    val diff = lru<RenderResult<DiffView>>(max / 8)
    val diffIndex = lru<RenderResult<DiffIndexView>>(max / 16)
    private fun <V> lru(size: Int) = object : LinkedHashMap<String, V>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, V>?) = this.size > size
    }
}

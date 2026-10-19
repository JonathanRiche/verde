package dev.verdeai.app

import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.UUID
import java.util.concurrent.TimeUnit

/*
 * Phase 2: a live, full-duplex voice conversation with the Companion through xAI Grok Voice,
 * OpenAI Realtime or Gemini Live. The desktop keeps the API keys and mints a short-lived token
 * per session (core `voice_session_create`); the phone opens the provider WebSocket itself and
 * runs the voice model's tools against the companion. Tokens, audio and transcripts are never logged.
 */

internal enum class LivePhase { Off, Connecting, Live, Reconnecting, Failed }

internal data class LiveCaption(val user: Boolean, val text: String, val open: Boolean = false)

internal data class LiveUi(
    val phase: LivePhase = LivePhase.Off,
    val provider: String = "",
    val voice: String = "",
    val muted: Boolean = false,
    val error: String? = null,
    val captions: List<LiveCaption> = emptyList(),
) {
    val active get() = phase == LivePhase.Connecting || phase == LivePhase.Live || phase == LivePhase.Reconnecting
}

internal const val LIVE_CAPTIONS = 8
internal const val LIVE_SILENCE_MS = 120_000L

/** Captions after one provider event (pure, unit tested): assistant deltas grow one open caption. */
internal fun liveCaptions(captions: List<LiveCaption>, event: LiveEvent): List<LiveCaption> {
    val next = when (event) {
        is LiveEvent.UserText -> {
            val open = captions.indexOfLast { it.user && it.open }
            when {
                open >= 0 -> captions.mapIndexed { i, c -> if (i == open) c.copy(text = event.text.trim().ifEmpty { c.text }, open = false) else c }
                event.text.isBlank() -> captions
                else -> captions + LiveCaption(true, event.text.trim())
            }
        }
        is LiveEvent.UserPartial -> {
            val open = captions.indexOfLast { it.user && it.open }
            if (open >= 0) captions.mapIndexed { i, c -> if (i == open) c.copy(text = if (event.cumulative) event.text else c.text + event.text) else c }
            else if (event.text.isBlank()) captions else captions + LiveCaption(true, event.text.trimStart(), open = true)
        }
        is LiveEvent.AssistantText -> {
            val last = captions.lastOrNull()
            if (last != null && !last.user && last.open) captions.dropLast(1) + last.copy(text = last.text + event.delta)
            else if (event.delta.isBlank()) captions else captions + LiveCaption(false, event.delta.trimStart(), open = true)
        }
        LiveEvent.TurnDone, LiveEvent.Interrupted -> captions.map { it.copy(open = false) }
        else -> return captions
    }
    return next.takeLast(LIVE_CAPTIONS)
}

internal fun liveError(code: String?): String = when (code) {
    "voice_not_configured" -> "Add an API key for live voice in companion settings."
    "voice_key_rejected" -> "The voice provider rejected the API key. Replace it in companion settings."
    "voice_provider_unavailable" -> "Couldn't reach the voice provider. Try again."
    "unsupported", "unknown_method" -> "Update verde on the computer to use live voice."
    "offline", "unavailable" -> "Connect to the host first."
    "insufficient_scope" -> "This phone isn't allowed to use live voice. Pair again with chat access."
    "microphone" -> "Couldn't open the microphone."
    "protocol" -> "This voice provider isn't supported yet."
    "dropped" -> "The live connection dropped."
    null -> "Live voice stopped."
    else -> "The voice provider ended the conversation."
}

/** Reads the voice selector of the active host's core. */
internal fun decodeVoice(value: JsonElement?): VoiceView? = value?.let {
    try { CoreJson.decodeFromJsonElement<VoiceQuery>(it).data } catch (_: Exception) { null }
}

private sealed interface Signal {
    data object Open : Signal
    class Text(val text: String) : Signal
    data class Closed(val code: String) : Signal
    data object Stop : Signal
    data object Silence : Signal
}

private enum class Ending { Stopped, Reconnect, Failed }

internal class LiveVoice(
    private val context: Context,
    private val hosts: HostsModel,
    private val browse: StateFlow<BrowseState>,
    private val companion: CompanionModel,
) : ViewModel() {
    private val mutableUi = MutableStateFlow(LiveUi())
    val ui = mutableUi.asStateFlow()
    private val mutableInput = MutableStateFlow(0f)
    val inputLevel = mutableInput.asStateFlow()
    private val mutableOutput = MutableStateFlow(0f)
    val outputLevel = mutableOutput.asStateFlow()
    private val mutableVoice = MutableStateFlow<VoiceView?>(null)
    /** The host's `voice` view: providers, configured keys (never the keys) and the latest session. */
    val voice = mutableVoice.asStateFlow()

    /** The companion chat's model (set by the shell); `ask_companion` sends through it. */
    var companionTranscript: TranscriptModel? = null
    /** The current companion snapshot and workspace labels (set by the shell) for the tools. */
    var snapshot: () -> CompanionSnapshot? = { null }
    var workspaceLabel: (String) -> String? = { null }

    private val client by lazy { OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build() }
    private var job: Job? = null
    private var signals: Channel<Signal>? = null
    private var socket: WebSocket? = null
    private var protocol: LiveProtocol? = null
    private var mic: LiveMic? = null
    @Volatile private var lastActivity = 0L
    private var transcript: LiveTranscript? = null
    /** Ended sessions with lines not yet stored (offline, host gone); retried when the host is ready. */
    private val unsaved = ArrayList<LiveTranscript>()
    private val saveLock = kotlinx.coroutines.sync.Mutex()

    init {
        // Saved transcripts that failed (offline, background) go out once the host is ready again.
        viewModelScope.launch {
            browse.map { it.host?.phase == "ready" && it.networkAvailable }.distinctUntilChanged().collect { ready ->
                if (ready && unsaved.isNotEmpty()) flushUnsaved()
            }
        }
        viewModelScope.launch {
            browse.map { it.hostId }.distinctUntilChanged().collectLatest { id ->
                stop()
                mutableVoice.value = null
                if (id == null) return@collectLatest
                val host = try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null } ?: return@collectLatest
                mutableVoice.value = decodeVoice(try { host.query("voice") } catch (e: CancellationException) { throw e } catch (_: Exception) { null })
                host.views.map { it["voice"] }.filterNotNull().distinctUntilChanged().collect { value ->
                    decodeVoice(value)?.let { mutableVoice.value = it }
                }
            }
        }
    }

    private suspend fun core(): CoreHost? = try { hosts.activeCore() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }

    private suspend fun dispatch(build: (Long, Long, String) -> Event): Pair<CoreHost, String>? {
        val host = core() ?: return null
        val id = UUID.randomUUID().toString()
        return try { host.send { n, w -> build(n, w, id) }; host to id }
        catch (e: CancellationException) { throw e } catch (_: Exception) { null }
    }

    fun refreshProviders() {
        viewModelScope.launch { dispatch { n, w, id -> EventVoiceProvidersRefresh(now_ms = n, wall_time_ms = w, intent_id = id) } }
    }

    /**
     * Saves provider settings on the desktop. [apiKey]: null keeps the stored key, "" removes it.
     * [onDone] gets null on success, else a message. The key is never kept on this phone.
     */
    fun configure(provider: String, apiKey: String?, model: String?, voiceName: String?, makeDefault: Boolean?, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val sent = dispatch { n, w, id -> EventVoiceProviderConfigure(now_ms = n, wall_time_ms = w, intent_id = id, provider = provider,
                api_key = apiKey, model = model, voice = voiceName, make_default = makeDefault) }
            if (sent == null) { onDone("Couldn't reach the host."); return@launch }
            val op = withTimeoutOrNull(30_000) { awaitOperation(sent.first, sent.second) }
            onDone(when {
                op == null -> "The host didn't answer."
                op.state == "succeeded" -> null
                else -> op.error?.code?.let { if (it == "invalid_params") "The desktop rejected these settings." else liveError(it) } ?: "Couldn't save."
            })
        }
    }

    fun toggle() = if (ui.value.active) stop() else start()

    fun start() {
        if (ui.value.active) return
        mutableUi.value = LiveUi(phase = LivePhase.Connecting)
        val name = companion.state.value.active?.name.orEmpty()
        val record = LiveTranscript(assistantAuthor = liveAssistantAuthor(name))
        transcript = record
        job = viewModelScope.launch {
            // Long sessions save as they go; every ending (End, background, silence, error) saves the rest.
            val ticker = launch { while (isActive) { delay(LIVE_SAVE_INTERVAL_MS); saveActive() } }
            try { converseLoop(record) } finally {
                ticker.cancel()
                finishTranscript(record)
            }
        }
    }

    private suspend fun converseLoop(record: LiveTranscript) {
        run {
            var attempts = 0
            while (currentCoroutineContext().isActive) {
                val session = createSession() ?: return
                val proto = liveProtocol(session) ?: return fail("protocol")
                mutableUi.update { it.copy(provider = session.provider, voice = session.voice) }
                val now = System.currentTimeMillis()
                record.header("\uD83C\uDF99 Live voice \u00b7 ${providerLabel(session.provider)} \u00b7 " +
                    java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(now)), now)
                when (converse(session, proto)) {
                    Ending.Stopped -> { mutableUi.value = LiveUi(); return }
                    Ending.Failed -> return
                    Ending.Reconnect -> {
                        if (++attempts > MAX_RECONNECTS) return fail("dropped")
                        mutableUi.update { it.copy(phase = LivePhase.Reconnecting) }
                        delay(500L * attempts)
                    }
                }
            }
        }
    }

    // ---- Saving the conversation as text ----


    /** The companion thread transcripts are saved to. */
    private fun saveTarget(): Pair<String, String>? = companion.state.value.active
        ?.takeIf { it.thread_id.isNotEmpty() && it.home_workspace_id.isNotEmpty() }?.let { it.home_workspace_id to it.thread_id }

    /** A companion turn is streaming in that thread: periodic saves wait so lines don't land mid-reply. */
    private fun companionTurnRunning(target: Pair<String, String>): Boolean {
        if (companionTranscript?.state?.value?.turn != null) return true
        val thread = browse.value.workspaces?.items?.find { it.workspace_id == target.first }?.threads?.find { it.thread_id == target.second }
        return thread != null && activeTurn(thread.status)
    }

    private suspend fun saveActive() {
        val record = transcript ?: return
        val target = saveTarget() ?: return
        if (companionTurnRunning(target)) return
        saveLock.withLockSafe { save(record, target, final = false) }
    }

    private fun finishTranscript(record: LiveTranscript) {
        if (transcript === record) transcript = null
        if (record.pending(final = true).isEmpty()) return
        unsaved += record
        viewModelScope.launch { flushUnsaved() }
    }

    /** Saves every ended session's remaining lines; anything that fails stays queued for the next try. */
    private suspend fun flushUnsaved() = saveLock.withLockSafe {
        val target = saveTarget() ?: return@withLockSafe
        val done = unsaved.filter { save(it, target, final = true) }
        unsaved.removeAll(done.toSet())
    }

    /** Sends the record's pending lines in batches; true when nothing is left to save. */
    private suspend fun save(record: LiveTranscript, target: Pair<String, String>, final: Boolean): Boolean {
        for (batch in saveBatches(record.pending(final))) {
            val messages = transcriptMessages(batch)
            if (messages.isEmpty()) { record.markSaved(batch.size); continue }
            val sent = dispatch { n, w, id -> EventCompanionTranscriptSave(now_ms = n, wall_time_ms = w, intent_id = id,
                workspace_id = target.first, thread_id = target.second, session_id = record.sessionId, messages = messages) } ?: return false
            val op = withTimeoutOrNull(SAVE_WAIT_MS) { awaitOperation(sent.first, sent.second) }
            if (op?.state != "succeeded") return false
            record.markSaved(batch.size)
        }
        return record.pending(final).isEmpty()
    }

    private suspend inline fun <T> kotlinx.coroutines.sync.Mutex.withLockSafe(block: () -> T): T? =
        if (tryLock()) try { block() } finally { unlock() } else null

    /** Ends Live now; cancelling the conversation releases the socket, mic, speaker and audio route. */
    fun stop() {
        job?.cancel()
        job = null
        mutableUi.value = LiveUi()
    }

    fun toggleMute() {
        val muted = !ui.value.muted
        mic?.muted = muted
        mutableUi.update { it.copy(muted = muted) }
    }

    fun dismissError() { if (ui.value.phase == LivePhase.Failed) mutableUi.value = LiveUi() }

    private fun fail(code: String?) { mutableUi.update { it.copy(phase = LivePhase.Failed, error = liveError(code)) } }

    private suspend fun createSession(): VoiceSession? {
        val sent = dispatch { n, w, id -> EventVoiceSessionCreate(now_ms = n, wall_time_ms = w, intent_id = id,
            companion_id = companion.state.value.active?.id) } ?: run { fail("offline"); return null }
        val (host, id) = sent
        val session = withTimeoutOrNull(SESSION_WAIT_MS) {
            host.views.map { decodeVoice(it["voice"])?.session }.first { it != null && it.intent_id == id && it.status != "pending" }
        }
        if (session == null) { fail("voice_provider_unavailable"); return null }
        if (session.status != "ready") { fail(session.error_code); return null }
        return session
    }

    /** One WebSocket conversation; returns how it ended. */
    private suspend fun converse(session: VoiceSession, proto: LiveProtocol): Ending {
        val channel = Channel<Signal>(Channel.UNLIMITED)
        signals = channel
        protocol = proto
        val route = LiveAudioRoute(context)
        val speaker = LiveSpeaker(proto.outputRate) { mutableOutput.value = it }
        val request = Request.Builder().url(session.websocket_url).apply {
            if (session.auth == "bearer") header("Authorization", "Bearer ${session.token}")
        }.build()
        val ws = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { channel.trySend(Signal.Open) }
            override fun onMessage(webSocket: WebSocket, text: String) { channel.trySend(Signal.Text(text)) }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { channel.trySend(Signal.Text(bytes.utf8())) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); channel.trySend(Signal.Closed("closed")) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { channel.trySend(Signal.Closed("closed")) }
            // Exceptions may carry the URL (and so a query token): never log them.
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                channel.trySend(Signal.Closed(if (response?.code == 401 || response?.code == 403) "voice_key_rejected" else "dropped"))
            }
        })
        socket = ws
        lastActivity = System.currentTimeMillis()
        val silence = viewModelScope.launch {
            while (isActive) {
                delay(1_000)
                val now = System.currentTimeMillis()
                // A pause ends the user's utterance even if the provider never sends a final transcript.
                transcript?.let { record -> record.tick(now); mutableUi.update { it.copy(captions = record.captions()) } }
                if (now - lastActivity > LIVE_SILENCE_MS) channel.trySend(Signal.Silence)
            }
        }
        route.acquire()
        speaker.start()
        var ready = false
        fun goLive() {
            if (ready) return
            ready = true
            mutableUi.update { it.copy(phase = LivePhase.Live, error = null) }
            val capture = LiveMic(proto.inputRate) { chunk, level ->
                mutableInput.value = level
                if (level > SPEECH_LEVEL) lastActivity = System.currentTimeMillis()
                ws.send(proto.audio(chunk))
            }
            capture.muted = ui.value.muted
            mic = capture
            if (!capture.start()) channel.trySend(Signal.Closed("microphone"))
        }
        try {
            for (signal in channel) when (signal) {
                Signal.Open -> {
                    proto.setup(session).forEach { ws.send(it) }
                    if (proto.readyOnOpen) goLive()
                }
                is Signal.Text -> for (event in proto.parse(signal.text)) when (event) {
                    LiveEvent.Ready -> goLive()
                    is LiveEvent.Audio -> { speaker.play(event.pcm); lastActivity = System.currentTimeMillis() }
                    // Transcript events: merged per utterance/response in the record; captions show the same lines.
                    is LiveEvent.AssistantText, LiveEvent.TurnDone, LiveEvent.ResponseStarted -> transcribe(event)
                    is LiveEvent.UserText, is LiveEvent.UserPartial -> {
                        lastActivity = System.currentTimeMillis()
                        transcribe(event)
                    }
                    LiveEvent.Interrupted -> {
                        speaker.flush()
                        lastActivity = System.currentTimeMillis()
                        transcribe(event)
                    }
                    is LiveEvent.ToolCall -> viewModelScope.launch {
                        val output = try { runTool(event.name, event.arguments) } catch (e: CancellationException) { throw e }
                            catch (_: Exception) { buildJsonObject { put("error", "failed") } }
                        if (socket === ws) proto.toolResult(event.callId, event.name, output).forEach { ws.send(it) }
                    }
                    LiveEvent.GoAway -> return Ending.Reconnect
                    is LiveEvent.Failure -> { fail(event.code); return Ending.Failed }
                    is LiveEvent.Ignored -> Log.d(TAG, "ignored live event type ${event.type.take(64)}")
                }
                Signal.Stop, Signal.Silence -> return Ending.Stopped
                is Signal.Closed -> {
                    if (signal.code == "dropped" && ready) return Ending.Reconnect
                    fail(signal.code)
                    return Ending.Failed
                }
            }
            return Ending.Stopped
        } finally {
            silence.cancel()
            signals = null
            socket = null
            protocol = null
            mic?.stop(); mic = null
            speaker.stop()
            ws.close(1000, null)
            route.release()
            mutableInput.value = 0f
            mutableOutput.value = 0f
            channel.close()
        }
    }

    private fun transcribe(event: LiveEvent) {
        val record = transcript
        if (record == null) { mutableUi.update { it.copy(captions = liveCaptions(it.captions, event)) }; return }
        record.feed(event, System.currentTimeMillis())
        mutableUi.update { it.copy(captions = record.captions()) }
    }

    /** Sends a text update into the live conversation (e.g. the companion's finished reply). */
    private fun inject(text: String) {
        val ws = socket ?: return
        val proto = protocol ?: return
        proto.inject(text).forEach { ws.send(it) }
    }

    private suspend fun runTool(name: String, arguments: JsonObject): JsonObject = when (name) {
        "ask_companion" -> ask((arguments["request"] as? JsonPrimitive)?.contentOrNull.orEmpty())
        "companion_status" -> snapshot()?.let { companionStatusJson(it.crew, it.needs, workspaceLabel) } ?: buildJsonObject { put("error", "not_ready") }
        "decide_approval" -> decide((arguments["chat"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
            (arguments["approve"] as? JsonPrimitive)?.booleanOrNull)
        else -> buildJsonObject { put("error", "unknown_tool") }
    }

    /** Hands [request] to the companion as a spoken turn and reports its reply into the conversation when done. */
    private fun ask(request: String): JsonObject {
        if (request.isBlank()) return buildJsonObject { put("accepted", false); put("error", "empty_request") }
        val model = companionTranscript
        if (model == null) {
            companion.retrySetup()
            return buildJsonObject { put("accepted", false); put("error", "companion_not_ready") }
        }
        val before = model.state.value.thread?.rows.orEmpty().map { it.id }.toSet()
        val name = companion.state.value.active?.name?.ifBlank { null } ?: "Companion"
        transcript?.system("\u2192 Asked $name: ${request.trim()}", System.currentTimeMillis())
        model.composer.sendSpoken(request)
        viewModelScope.launch {
            var started = false
            val finished = withTimeoutOrNull(ASK_WAIT_MS) {
                model.state.first { state ->
                    if (state.turn != null) started = true
                    started && state.turn == null
                }
            } ?: return@launch
            val reply = finished.thread?.rows.orEmpty().lastOrNull { it.id !in before && it.role == "assistant" && it.kind == "message" }?.body
            if (!reply.isNullOrBlank() && ui.value.phase == LivePhase.Live) {
                transcript?.system("\u2190 $name replied", System.currentTimeMillis())
                inject(companionUpdate(reply))
            }
        }
        return buildJsonObject { put("accepted", true) }
    }

    private suspend fun decide(chat: String, approve: Boolean?): JsonObject {
        if (approve == null) return buildJsonObject { put("error", "missing_decision") }
        val current = snapshot() ?: return buildJsonObject { put("error", "not_ready") }
        val target = when (val match = matchApproval(chat, approvalCandidates(current.needs, current.crew))) {
            ApprovalMatch.NotFound -> return buildJsonObject { put("error", "not_found") }
            ApprovalMatch.Ambiguous -> return buildJsonObject { put("error", "ambiguous") }
            is ApprovalMatch.Found -> match.candidate
        }
        val host = core() ?: return buildJsonObject { put("error", "offline") }
        try {
            host.send { n, w -> EventThreadOpen(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                workspace_id = target.workspaceId, thread_id = target.threadId) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return buildJsonObject { put("error", "offline") } }
        val selector = chatSelector("thread", target.workspaceId, target.threadId)
        val approval = host.awaitView(selector, APPROVAL_WAIT_MS) { value ->
            CoreJson.decodeFromJsonElement<ThreadQuery>(value).data?.approval?.takeIf { it.resolution != "pending" }
        } ?: return buildJsonObject { put("error", "no_pending_approval") }
        val decision = if (approve) ApprovalDecision.Approve else ApprovalDecision.Deny
        val sent = decideApproval(host, ApprovalTarget.of(target.workspaceId, target.threadId, approval), decision) as? DecideResult.Sent
            ?: return buildJsonObject { put("error", "failed") }
        val op = withTimeoutOrNull(APPROVAL_WAIT_MS) { awaitOperation(host, sent.intentId) }
        return buildJsonObject {
            put("chat", target.title)
            when {
                op?.state == "succeeded" -> {
                    put("ok", true); put("decision", if (approve) "approved" else "denied")
                    transcript?.system((if (approve) "\u2713 Approved " else "\u2717 Denied ") + target.title, System.currentTimeMillis())
                }
                staleApprovalError(op?.error) -> put("error", "already_answered")
                else -> put("error", "failed")
            }
        }
    }

    override fun onCleared() {
        job?.cancel()
        mic?.stop()
    }

    companion object {
        private const val TAG = "VerdeLive"
        const val MAX_RECONNECTS = 3
        const val SESSION_WAIT_MS = 50_000L
        const val APPROVAL_WAIT_MS = 15_000L
        const val ASK_WAIT_MS = 30 * 60_000L
        const val SAVE_WAIT_MS = 60_000L
        /** Mic level that counts as the user talking for the silence timeout. */
        const val SPEECH_LEVEL = .08f
    }
}

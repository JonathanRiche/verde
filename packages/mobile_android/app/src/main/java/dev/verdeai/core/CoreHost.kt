package dev.verdeai.core

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.security.SecureRandom

/** Injectable boundary; implementations must never include payloads in exceptions. */
interface CoreBridge {
    fun create(config: ByteArray): Long
    fun handle(host: Long, event: ByteArray): ByteArray
    fun query(host: Long, selector: String): ByteArray
    fun free(host: Long)
}

class CoreFailure(val status: Int) : Exception("core_call_failed")
class CoreInputRejected(val status: Int) : Exception("core_input_rejected")

object JniCoreBridge : CoreBridge {
    override fun create(config: ByteArray): Long {
        val status = IntArray(1)
        val host = Native.hostNew(config, status)
        if (status[0] != 0 || host == 0L) throw CoreFailure(status[0])
        return host
    }
    override fun handle(host: Long, event: ByteArray): ByteArray {
        val status = IntArray(1)
        val bytes = Native.hostHandle(host, event, status)
        if (status[0] != 0 || bytes == null) throw CoreFailure(status[0])
        return bytes
    }
    override fun query(host: Long, selector: String): ByteArray {
        val status = IntArray(1)
        val bytes = Native.hostQuery(host, selector.encodeToByteArray(), status)
        if (status[0] != 0 || bytes == null) throw CoreFailure(status[0])
        return bytes
    }
    override fun free(host: Long) = Native.hostFree(host)
}

/** One dedicated thread owns every call, including construction, queries and destruction. */
class CoreHost private constructor(
    private val core: CoreBridge,
    private val dispatcher: ExecutorCoroutineDispatcher,
    private val handle: Long,
    private val executor: EffectExecutor,
    private val terminalBridge: TerminalBridge,
    private val traceMetadata: ((String) -> Unit)?,
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var closed = false
    private val closing = AtomicBoolean(false)
    private val mutableViews = MutableStateFlow<Map<String, JsonElement>>(emptyMap())
    val views: StateFlow<Map<String, JsonElement>> = mutableViews.asStateFlow()
    private val mutableHosts = MutableStateFlow<HostsQuery?>(null)
    val hosts = mutableHosts.asStateFlow()
    /** Intent outcomes; announced only when a receipt is added, settled or evicted. */
    private val mutableOperations = MutableStateFlow<OperationsQuery?>(null)
    val operations = mutableOperations.asStateFlow()
    private val mutableHome = MutableStateFlow<HomeQuery?>(null)
    val home = mutableHome.asStateFlow()
    private val mutableWorkspaces = MutableStateFlow<WorkspacesQuery?>(null)
    val workspaces = mutableWorkspaces.asStateFlow()
    private val mutableFailure = MutableStateFlow<Boolean>(false)
    val failed: StateFlow<Boolean> = mutableFailure.asStateFlow()
    // Touched only on the core thread. Output for an unregistered terminal reports `unavailable`.
    private val terminals = HashMap<String, TerminalVt>()

    init {
        executor.attach(::complete)
    }

    private fun complete(completion: Completion) {
        scope.launch {
            if (!closed) try { dispatch(completion(executor.now(), executor.wall())) }
            catch (error: Exception) { fail(error) }
        }
    }

    /**
     * Registers a VT for [id]'s `terminal_output` (terminal.md: one serialized executor per handle).
     * Device replies are routed back through `terminal_reply` unless [replies] is false.
     */
    suspend fun openTerminal(id: String, replies: Boolean = true): TerminalVt = withContext(dispatcher) {
        check(!closed) { "host_closed" }
        register(id, replies)
    }

    private fun register(id: String, replies: Boolean): TerminalVt {
        val vt = TerminalVt(terminalBridge, onReply = { bytes -> if (replies) reply(id, bytes) })
        terminals.put(id, vt)?.let { old -> scope.launch { old.close() } }
        return vt
    }

    /** Detaches the pump (the daemon session keeps running) and frees the local VT. */
    fun closeTerminal(id: String, vt: TerminalVt) {
        scope.launch {
            if (terminals[id] === vt) {
                terminals.remove(id)
                if (!closed) try { dispatch(EventTerminalDetach(now_ms=executor.now(), wall_time_ms=executor.wall(),
                    intent_id=java.util.UUID.randomUUID().toString(), terminal_id=id)) }
                catch (_: CoreInputRejected) {} catch (error: Exception) { fail(error) }
            }
            vt.close()
        }
    }

    /**
     * Sends `terminal_create` and returns the new session's terminal ID. Every committed change
     * lists all terminal selectors, so the only new selector after this batch is that row.
     */
    suspend fun createTerminal(replies: Boolean, event: (Long, Long) -> EventTerminalCreate): Pair<String, TerminalVt>? = withContext(dispatcher) {
        check(!closed) { "host_closed" }
        val before = mutableViews.value.keys.filter { it.startsWith("terminal:") }.toSet()
        try { dispatch(event(executor.now(), executor.wall())) }
        catch (e: CoreInputRejected) { throw e } catch (error: Exception) { fail(error); throw CoreFailure(-1) }
        val id = mutableViews.value.filterKeys { it.startsWith("terminal:") && it !in before }.values.firstNotNullOfOrNull {
            CoreJson.decodeFromJsonElement(TerminalQuery.serializer(), it).data?.terminal_id
        } ?: return@withContext null
        // Registered in the same core-thread turn, so the first output cannot miss the VT.
        id to register(id, replies)
    }

    /** This handle's `terminal:<id>` view, re-read on every coalesced invalidation. */
    fun terminalView(id: String): Flow<TerminalView?> {
        val selector = terminalSelector(id)
        return views.map { it[selector] }.distinctUntilChanged().map { element ->
            element?.let { CoreJson.decodeFromJsonElement(TerminalQuery.serializer(), it).data }
        }
    }

    private suspend fun reply(id: String, bytes: ByteArray) {
        try { send { n, w -> EventTerminalReply(now_ms=n, wall_time_ms=w, terminal_id=id,
            bytes_base64=java.util.Base64.getEncoder().encodeToString(bytes)) } }
        // Not ready/attached (or oversized): the reply is dropped rather than replayed later.
        catch (_: CoreInputRejected) {} catch (_: CoreFailure) {} catch (_: IllegalStateException) {}
    }

    /** Core thread: resolve the grid size (terminal.md: query the view before recreating the VT). */
    private fun terminalOutput(effect: EffectTerminalOutput) {
        fun applied(result: TerminalApplied) = complete { n, w -> EventTerminalApplied(now_ms=n, wall_time_ms=w,
            effect_id=effect.effect_id, generation=effect.generation, terminal_id=effect.terminal_id,
            grid_revision=result.gridRevision, error=result.error) }
        val vt = terminals[effect.terminal_id]
            ?: return applied(TerminalApplied("0", PlatformFailure(PlatformFailureCode.unavailable)))
        val view = CoreJson.decodeFromString<TerminalQuery>(core.query(handle, terminalSelector(effect.terminal_id)).decodeToString()).data
        val bytes = java.util.Base64.getDecoder().decode(effect.bytes_base64)
        scope.launch {
            val started = System.nanoTime()
            val result = try { vt.apply(effect.reset, bytes, view?.cols ?: 80, view?.rows ?: 24) }
                catch (e: CancellationException) { if (closed) throw e; TerminalApplied("0", PlatformFailure(PlatformFailureCode.unavailable)) }
            executor.recordTerminalTiming(TerminalTimingStage.OutputApply, started)
            applied(result)
        }
    }

    suspend fun send(event: (Long, Long) -> Event) = withContext(dispatcher) {
        check(!closed) { "host_closed" }
        try { dispatch(event(executor.now(), executor.wall())) }
        catch (e: CoreInputRejected) { throw e } catch (error: Exception) { fail(error); throw CoreFailure(-1) }
    }

    /** D-12: the body fetched for a succeeded `file_open` intent, once; memory only. */
    fun takeFile(intentId: String): FileBody? = executor.files.take(intentId)

    suspend fun query(selector: String): JsonElement = withContext(dispatcher) {
        check(!closed) { "host_closed" }
        try { read(selector) }
        catch (_: Exception) { throw CoreFailure(-1) }
    }

    private fun read(selector: String): JsonElement {
        val trace = traceMetadata != null
        val started = System.nanoTime()
        val bytes = core.query(handle, selector)
        val queried = System.nanoTime()
        val result = CoreJson.parseToJsonElement(bytes.decodeToString())
        if (trace) {
            val kind = when {
                selector.startsWith("thread:") -> "thread"
                selector.startsWith("composer:") -> "composer"
                selector in setOf("hosts", "operations", "home", "workspaces", "attention", "manage") -> selector
                else -> "utility"
            }
            traceMetadata?.invoke("query_kind=$kind native_ms=${(queried-started)/1_000_000} decode_ms=${(System.nanoTime()-queried)/1_000_000} bytes=${bytes.size}")
        }
        return result
    }

    private fun dispatch(event: Event) {
        val started = System.nanoTime()
        val trace = traceMetadata != null
        if (trace && event is EventHttpResponse && (event.error != null || event.status !in 200..299)) {
            traceMetadata?.invoke("http_status=${event.status} failure=${event.error?.kind} code=${event.error?.code}")
        }
        val eventKind = when (event) {
            is EventDraftSet -> "draft"
            is EventSend -> "send"
            is EventFollowupSubmit -> "followup"
            is EventHttpResponse -> "http"
            is EventWsMessage -> "socket"
            else -> "other"
        }
        val encodedEvent = CoreJson.encodeToString<Event>(event).encodeToByteArray()
        val bytes = try {
            core.handle(handle, encodedEvent)
        } catch (e: CoreFailure) {
            traceMetadata?.invoke("core_rejected event=$eventKind bytes=${encodedEvent.size} status=${e.status}")
            // Only a rejected call (before any effects) is recoverable. Decode,
            // query and effect failures must still tear down the host. A resource
            // limit also rolls the transaction back (e.g. the 32 terminal records).
            if (e.status == 1 || e.status == 4 || e.status == 5) throw CoreInputRejected(e.status)
            throw e
        }
        if (event is EventTerminalInput) executor.recordTerminalTiming(TerminalTimingStage.InputHandle, started)
        val handled = System.nanoTime()
        var queries = 0
        val batch = CoreJson.decodeFromString<EffectBatch>(bytes.decodeToString())
        check(batch.api_version == 1L) { "unsupported_core_revision" }
        for (effect in batch.effects) {
            if (effect is EffectStateChanged) {
                val updated = mutableViews.value.toMutableMap()
                effect.scopes.forEach {
                    queries++
                    val snapshot = read(it)
                    updated[it] = snapshot
                    when (it) {
                        "hosts" -> {
                            val hosts = CoreJson.decodeFromJsonElement<HostsQuery>(snapshot)
                            if (hosts.data?.items?.any { host -> host.auth_state == "signing_out" || host.auth_state == "signed_out" } == true) {
                                // A core-driven wipe also retires any platform-cached projections.
                                updated.clear()
                                updated[it] = snapshot
                                executor.files.clear()
                                mutableHome.value = null
                                mutableWorkspaces.value = null
                            }
                            mutableHosts.value = hosts
                        }
                        "operations" -> mutableOperations.value = CoreJson.decodeFromJsonElement<OperationsQuery>(snapshot)
                        "home" -> mutableHome.value = CoreJson.decodeFromJsonElement<HomeQuery>(snapshot)
                        "workspaces" -> mutableWorkspaces.value = CoreJson.decodeFromJsonElement<WorkspacesQuery>(snapshot)
                    }
                }
                mutableViews.value = updated.toMap()
            } else if (effect is EffectTerminalOutput) terminalOutput(effect)
            else executor.execute(effect)
        }
        if (trace) traceMetadata?.invoke("core_event=$eventKind handle_ms=${(handled-started)/1_000_000} publish_ms=${(System.nanoTime()-handled)/1_000_000} queries=$queries")
        if (event is EventTerminalInput) executor.recordTerminalTiming(TerminalTimingStage.InputDispatch, started)
    }

    private fun fail(error: Exception) {
        // Never include exception messages or stacks: serializers may include payloads.
        val kind = when (error) {
            is CoreInputRejected -> "input_rejected"
            is CoreFailure -> "native"
            is kotlinx.serialization.SerializationException -> "decode"
            is CancellationException -> "cancelled"
            is IllegalStateException -> "state"
            else -> "platform"
        }
        val status = when (error) {
            is CoreInputRejected -> error.status
            is CoreFailure -> error.status
            else -> null
        }
        traceMetadata?.invoke("core_failure kind=$kind status=$status")
        mutableFailure.value = true
        if (!closed) { closed = true; executor.close(); core.free(handle); closeTerminals() }
    }

    private fun closeTerminals() {
        val open = terminals.values.toList()
        terminals.clear()
        open.forEach { vt -> CoroutineScope(Dispatchers.Default).launch { vt.close() } }
    }

    suspend fun close() {
        if (!closing.compareAndSet(false, true)) return
        try {
            withContext(NonCancellable + dispatcher) {
                if (!closed) {
                    try { dispatch(EventShutdown(now_ms = executor.now(), wall_time_ms = executor.wall())) }
                    finally { closed = true; executor.close(); core.free(handle); closeTerminals() }
                }
            }
        } finally {
            scope.cancel()
            dispatcher.close()
        }
    }

    companion object {
        suspend fun create(config: Config, executor: EffectExecutor, core: CoreBridge = JniCoreBridge,
            terminals: TerminalBridge = JniTerminalBridge, traceMetadata: ((String) -> Unit)? = null): CoreHost {
            val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "verde-core") }.asCoroutineDispatcher()
            var allocated = 0L
            try {
                val random = SecureRandom()
                val nonce = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
                val session = config.copy(session_nonce = nonce, jitter_seed = random.nextLong().toULong())
                val handle = withContext(dispatcher) {
                    core.create(CoreJson.encodeToString(session).encodeToByteArray()).also { allocated = it }
                }
                return CoreHost(core, dispatcher, handle, executor, terminals, traceMetadata)
            } catch (_: Exception) {
                withContext(NonCancellable + dispatcher) { if (allocated != 0L) core.free(allocated) }
                dispatcher.close(); executor.close(); throw CoreFailure(-1)
            }
        }
    }
}

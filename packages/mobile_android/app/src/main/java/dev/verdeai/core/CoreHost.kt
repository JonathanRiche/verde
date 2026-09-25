package dev.verdeai.core

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
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
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var closed = false
    private val closing = AtomicBoolean(false)
    private val mutableViews = MutableStateFlow<Map<String, JsonElement>>(emptyMap())
    val views: StateFlow<Map<String, JsonElement>> = mutableViews.asStateFlow()
    private val mutableHosts = MutableStateFlow<HostsQuery?>(null)
    val hosts = mutableHosts.asStateFlow()
    private val mutableHome = MutableStateFlow<HomeQuery?>(null)
    val home = mutableHome.asStateFlow()
    private val mutableWorkspaces = MutableStateFlow<WorkspacesQuery?>(null)
    val workspaces = mutableWorkspaces.asStateFlow()
    private val mutableFailure = MutableStateFlow<Boolean>(false)
    val failed: StateFlow<Boolean> = mutableFailure.asStateFlow()

    init {
        executor.attach { completion ->
            scope.launch {
                if (!closed) try { dispatch(completion(executor.now(), executor.wall())) }
                catch (_: Exception) { fail() }
            }
        }
    }

    suspend fun send(event: (Long, Long) -> Event) = withContext(dispatcher) {
        check(!closed) { "host_closed" }
        try { dispatch(event(executor.now(), executor.wall())) }
        catch (e: CoreInputRejected) { throw e } catch (_: Exception) { fail(); throw CoreFailure(-1) }
    }

    suspend fun query(selector: String): JsonElement = withContext(dispatcher) {
        check(!closed) { "host_closed" }
        try { read(selector) }
        catch (_: Exception) { throw CoreFailure(-1) }
    }

    private fun read(selector: String) = CoreJson.parseToJsonElement(core.query(handle, selector).decodeToString())

    private fun dispatch(event: Event) {
        val bytes = try {
            core.handle(handle, CoreJson.encodeToString<Event>(event).encodeToByteArray())
        } catch (e: CoreFailure) {
            // Only a rejected call (before any effects) is recoverable. Decode,
            // query and effect failures must still tear down the host.
            if (e.status == 1 || e.status == 4) throw CoreInputRejected(e.status)
            throw e
        }
        val batch = CoreJson.decodeFromString<EffectBatch>(bytes.decodeToString())
        check(batch.api_version == 1L) { "unsupported_core_revision" }
        for (effect in batch.effects) {
            if (effect is EffectStateChanged) {
                val updated = mutableViews.value.toMutableMap()
                effect.scopes.forEach {
                    val snapshot = read(it)
                    updated[it] = snapshot
                    when (it) {
                        "hosts" -> mutableHosts.value = CoreJson.decodeFromString<HostsQuery>(snapshot.toString())
                        "home" -> mutableHome.value = CoreJson.decodeFromString<HomeQuery>(snapshot.toString())
                        "workspaces" -> mutableWorkspaces.value = CoreJson.decodeFromString<WorkspacesQuery>(snapshot.toString())
                    }
                }
                mutableViews.value = updated.toMap()
            } else executor.execute(effect)
        }
    }

    private fun fail() {
        mutableFailure.value = true
        if (!closed) { closed = true; executor.close(); core.free(handle) }
    }

    suspend fun close() {
        if (!closing.compareAndSet(false, true)) return
        try {
            withContext(NonCancellable + dispatcher) {
                if (!closed) {
                    try { dispatch(EventShutdown(now_ms = executor.now(), wall_time_ms = executor.wall())) }
                    finally { closed = true; executor.close(); core.free(handle) }
                }
            }
        } finally {
            scope.cancel()
            dispatcher.close()
        }
    }

    companion object {
        suspend fun create(config: Config, executor: EffectExecutor, core: CoreBridge = JniCoreBridge): CoreHost {
            val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "verde-core") }.asCoroutineDispatcher()
            var allocated = 0L
            try {
                val random = SecureRandom()
                val nonce = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
                val session = config.copy(session_nonce = nonce, jitter_seed = random.nextLong().toULong())
                val handle = withContext(dispatcher) {
                    core.create(CoreJson.encodeToString(session).encodeToByteArray()).also { allocated = it }
                }
                return CoreHost(core, dispatcher, handle, executor)
            } catch (_: Exception) {
                withContext(NonCancellable + dispatcher) { if (allocated != 0L) core.free(allocated) }
                dispatcher.close(); executor.close(); throw CoreFailure(-1)
            }
        }
    }
}

package dev.verdeai.core

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.decodeFromString
import java.util.Base64
import java.util.concurrent.Executors

/** Injectable `vc_term_*` boundary. Implementations never put grid contents or bytes in exceptions. */
interface TerminalBridge {
    fun create(config: ByteArray): Long
    fun write(term: Long, bytes: ByteArray): Int
    fun resize(term: Long, cols: Int, rows: Int): Int
    fun scroll(term: Long, deltaRows: Int): Int
    fun snapshot(term: Long): ByteArray
    fun free(term: Long)
}

object JniTerminalBridge : TerminalBridge {
    override fun create(config: ByteArray): Long {
        val status = IntArray(1)
        val term = Native.termNew(config, status)
        if (status[0] != 0 || term == 0L) throw CoreFailure(status[0])
        return term
    }
    override fun write(term: Long, bytes: ByteArray) = Native.termWrite(term, bytes)
    override fun resize(term: Long, cols: Int, rows: Int) = Native.termResize(term, cols, rows)
    override fun scroll(term: Long, deltaRows: Int) = Native.termScroll(term, deltaRows)
    override fun snapshot(term: Long): ByteArray {
        val status = IntArray(1)
        val bytes = Native.termSnapshot(term, status)
        if (status[0] != 0 || bytes == null) throw CoreFailure(status[0])
        return bytes
    }
    override fun free(term: Long) = Native.termFree(term)
}

/** `terminal:<id>` with the core's percent-encoding (unreserved bytes pass through). */
fun terminalSelector(id: String): String = buildString {
    append("terminal:")
    for (byte in id.encodeToByteArray()) {
        val c = byte.toInt() and 0xff
        if (c in 'A'.code..'Z'.code || c in 'a'.code..'z'.code || c in '0'.code..'9'.code || c == '-'.code ||
            c == '_'.code || c == '.'.code || c == '~'.code) append(c.toChar())
        else append('%').append("%02X".format(c))
    }
}

/** Outcome reported to the core as `terminal_applied`. */
data class TerminalApplied(val gridRevision: String, val error: PlatformFailure?)

/**
 * One local VT handle on its own serialized executor (terminal.md). It never kills the
 * daemon session. Snapshots and device replies are content: never log them.
 */
class TerminalVt(
    private val bridge: TerminalBridge,
    private val scrollbackRows: Long = DEFAULT_SCROLLBACK_ROWS,
    private val onReply: suspend (ByteArray) -> Unit = {},
) {
    private val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "verde-term") }.asCoroutineDispatcher()
    private var handle = 0L
    private var cols = 0
    private var rows = 0
    private var writes = 0L
    @Volatile private var closed = false
    private val mutableSnapshot = MutableStateFlow<TerminalSnapshot?>(null)
    /** Latest full grid; kept across transient failures so the last screen stays visible. */
    val snapshot: StateFlow<TerminalSnapshot?> = mutableSnapshot.asStateFlow()
    private val mutableResets = MutableStateFlow(0)
    /** Number of emulator resets (initial replay, truncation/gap replay, apply-failure recovery). */
    val resets: StateFlow<Int> = mutableResets.asStateFlow()

    /** Routes one `terminal_output`: reset/recreate at the core's grid size, write once, publish. */
    suspend fun apply(reset: Boolean, bytes: ByteArray, cols: Int, rows: Int): TerminalApplied {
        var replies: ByteArray? = null
        val result = withContext(dispatcher) {
            if (closed) return@withContext TerminalApplied("0", PlatformFailure(PlatformFailureCode.unavailable))
            try {
                if (reset || handle == 0L) {
                    release()
                    handle = bridge.create(CoreJson.encodeToString(TerminalConfig.serializer(),
                        TerminalConfig(cols=cols, rows=rows, scrollback_rows=scrollbackRows)).encodeToByteArray())
                    this@TerminalVt.cols = cols; this@TerminalVt.rows = rows
                    mutableResets.value += 1
                } else if (cols != this@TerminalVt.cols || rows != this@TerminalVt.rows) {
                    if (bridge.resize(handle, cols, rows) == 0) { this@TerminalVt.cols = cols; this@TerminalVt.rows = rows }
                }
            } catch (_: Exception) {
                release()
                return@withContext TerminalApplied("0", PlatformFailure(PlatformFailureCode.resource))
            }
            val status = bridge.write(handle, bytes)
            if (status != 0) {
                // A poisoned VT (terminal.md) is recreated on the core's next reset replay.
                release()
                return@withContext TerminalApplied("0", PlatformFailure(if (status == 5 || status == 3) PlatformFailureCode.resource else PlatformFailureCode.io))
            }
            writes += 1
            val published = publish()
            replies = published?.second
            TerminalApplied(published?.first?.revision ?: writes.toString(), null)
        }
        replies?.let { onReply(it) }
        return result
    }

    /** Local emulator resize; the caller separately asks the host for `session.resize`. */
    suspend fun resize(cols: Int, rows: Int) = local { if (handle != 0L && (cols != this.cols || rows != this.rows) &&
        bridge.resize(handle, cols, rows) == 0) { this.cols = cols; this.rows = rows; true } else false }

    /** Positive rows move toward older history, negative toward the live bottom; the VT clamps. */
    suspend fun scroll(deltaRows: Int) = local { deltaRows != 0 && handle != 0L && bridge.scroll(handle, deltaRows) == 0 }

    private suspend fun local(change: () -> Boolean) {
        var replies: ByteArray? = null
        withContext(dispatcher) {
            if (!closed && change()) replies = publish()?.second
        }
        replies?.let { onReply(it) }
    }

    /** Snapshot drains device replies only after a successful output allocation. */
    private fun publish(): Pair<TerminalSnapshot, ByteArray?>? = try {
        val snapshot = CoreJson.decodeFromString<TerminalSnapshot>(bridge.snapshot(handle).decodeToString())
        mutableSnapshot.value = snapshot
        snapshot to snapshot.reply_bytes_base64.takeIf { it.isNotEmpty() }?.let { Base64.getDecoder().decode(it) }
    } catch (_: Exception) { null }

    private fun release() {
        if (handle != 0L) { bridge.free(handle); handle = 0L }
    }

    suspend fun close() {
        if (closed) return
        try { withContext(NonCancellable + dispatcher) { closed = true; release() } }
        finally { dispatcher.close() }
    }

    companion object { const val DEFAULT_SCROLLBACK_ROWS = 2_000L }
}

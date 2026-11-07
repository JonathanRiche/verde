package dev.verdeai.core

import okhttp3.Response
import okhttp3.Call
import java.io.Closeable
import java.io.FilterInputStream
import java.util.concurrent.ConcurrentHashMap

/** A native-only, pinned request capability. Never handed to page JavaScript. */
class PreviewAccess(private val fetch: (String, String, String?, (Call) -> Unit) -> Response) : Closeable {
    private val calls = ConcurrentHashMap.newKeySet<Call>()
    private val responses = ConcurrentHashMap.newKeySet<Response>()
    @Volatile private var closed = false
    fun open(path: String, method: String, range: String?): Response {
        check(!closed)
        val pending = ArrayList<Call>()
        val response = try { fetch(path, method, range) { call ->
            calls.add(call); pending.add(call); if (closed) call.cancel()
        } } finally { pending.forEach { calls.remove(it) } }
        responses.add(response)
        if (closed) { response.close(); error("preview_closed") }
        return response
    }
    fun stream(response: Response): java.io.InputStream = object : FilterInputStream(response.body!!.byteStream()) {
        override fun close() { responses.remove(response); response.close() }
    }
    fun cancel() { calls.toList().forEach { it.cancel() }; responses.toList().forEach { responses.remove(it); it.close() } }
    override fun close() { closed = true; cancel() }
}

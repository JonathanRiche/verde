package dev.verdeai.core

import android.os.SystemClock
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.RequestBody.Companion.toRequestBody
import okio.ByteString
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Socket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.*

typealias Completion = (Long, Long) -> Event

/** Owns platform work for one host. Callbacks enqueue events; they never call JNI. */
class EffectExecutor(
    private val store: SecureStore,
    private val hostId: String,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    private val wallClock: () -> Long = { System.currentTimeMillis() },
    private val notify: (EffectNotify) -> Unit = {},
    // Tests may supply a loopback CA. Production always uses the platform trust manager.
    private val baseClient: OkHttpClient = OkHttpClient(),
    /** D-12: bodies of `file_fetch` effects, held in memory only until the viewer takes them. */
    val files: FileSink = FileSink(),
) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // The core caps outstanding correlations at 256. OkHttp's default five per
    // origin would let parked tails queue interactive requests behind them.
    private val networkDispatcher = Dispatcher().apply {
        maxRequests = 256
        maxRequestsPerHost = 256
    }
    private val calls = ConcurrentHashMap<String, Call>()
    private val sockets = ConcurrentHashMap<String, SocketState>()
    private val timers = ConcurrentHashMap<String, Job>()
    private val clients = ConcurrentHashMap.newKeySet<OkHttpClient>()
    private val storage = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    @Volatile private var completion: ((Completion) -> Unit)? = null
    private val closed = AtomicBoolean(false)
    init { require(hostId.matches(Regex("[A-Za-z0-9_-]{1,128}"))); scope.launch { for (operation in storage) operation() } }
    internal fun attach(callback: (Completion) -> Unit) { check(completion == null); completion = callback }
    fun now() = clock()
    fun wall() = wallClock()
    private fun emit(event: Completion) { if (!closed.get()) completion?.invoke(event) }

    fun execute(effect: Effect) {
        check(!closed.get()) { "executor_closed" }
        when (effect) {
            is EffectHttpRequest -> http(effect)
            is EffectHttpCancel -> calls.remove(effect.request_id)?.cancel()
            is EffectFileFetch -> fileFetch(effect)
            is EffectWsOpen -> websocket(effect)
            is EffectWsSend -> sockets[effect.socket_id]?.let {
                if (!it.socket.send(effect.text)) it.finish(null, false, failure(TransportFailureKind.network, TransportFailureCode.reset))
            }
            is EffectWsClose -> sockets[effect.socket_id]?.let {
                it.socket.close(effect.code, null)
                // Local close must promptly release the socket even if the peer never replies.
                it.finish(effect.code, true, null)
            }
            is EffectSetTimer -> {
                timers.remove(effect.timer_id)?.cancel()
                val job = scope.launch(start = CoroutineStart.LAZY) {
                    delay(effect.delay_ms.coerceAtLeast(0))
                    timers.remove(effect.timer_id)
                    emit { n, w -> EventTimerFired(now_ms=n, wall_time_ms=w, timer_id=effect.timer_id, generation=effect.generation) }
                }
                timers[effect.timer_id] = job
                job.start()
            }
            is EffectCancelTimer -> timers.remove(effect.timer_id)?.cancel()
            is EffectSecureStoreGet -> storage.trySend {
                var value: String? = null
                val error = storageResult(effect.key) { value = store.get(effect.key) }
                emit { n, w -> EventSecureStoreValue(now_ms=n, wall_time_ms=w, effect_id=effect.effect_id, generation=effect.generation, key=effect.key, value_base64=value, error=error) }
            }.getOrThrow()
            is EffectSecureStorePut -> storage.trySend {
                val error = storageResult(effect.key) { store.put(effect.key, effect.value_base64) }
                storeDone(effect.effect_id, effect.generation, effect.key, error)
            }.getOrThrow()
            is EffectSecureStoreDelete -> storage.trySend {
                val error = storageResult(effect.key) { store.delete(effect.key) }
                storeDone(effect.effect_id, effect.generation, effect.key, error)
            }.getOrThrow()
            is EffectTlsProbe -> probe(effect)
            is EffectNotify -> notify(effect)
            is EffectLog -> Unit // No platform logging, including opaque core diagnostic fields.
            is EffectTerminalOutput -> emit { n, w -> EventTerminalApplied(now_ms=n, wall_time_ms=w,
                effect_id=effect.effect_id, generation=effect.generation, terminal_id=effect.terminal_id,
                grid_revision="0", error=PlatformFailure(PlatformFailureCode.unavailable)) }
            is EffectStateChanged -> error("state_change_requires_host")
        }
    }

    private suspend fun storageResult(key: String, operation: suspend () -> Unit): PlatformFailure? = try {
        require(key.startsWith("vc/1/$hostId/") && key.length <= 4096) { "invalid_storage_scope" }
        operation(); null
    } catch (e: CancellationException) { throw e }
      catch (_: android.security.keystore.UserNotAuthenticatedException) { PlatformFailure(PlatformFailureCode.locked) }
      catch (_: SecurityException) { PlatformFailure(PlatformFailureCode.denied) }
      catch (_: Exception) { PlatformFailure(PlatformFailureCode.io) }

    private fun storeDone(id: String, generation: String, key: String, error: PlatformFailure?) = emit { n, w ->
        EventSecureStoreDone(now_ms=n, wall_time_ms=w, effect_id=id, generation=generation, key=key, error=error)
    }

    private fun secureUrl(value: String, tls: Tls): HttpUrl {
        val url = value.replaceFirst(Regex("^wss:"), "https:").toHttpUrl()
        val origin = tls.origin.toHttpUrl()
        require(url.isHttps && origin.isHttps && url.host == origin.host && url.port == origin.port &&
            url.username.isEmpty() && url.password.isEmpty() && url.fragment == null &&
            origin.username.isEmpty() && origin.password.isEmpty() && origin.encodedPath == "/" &&
            origin.query == null && origin.fragment == null) { "invalid_tls_origin" }
        return url
    }

    private fun client(url: HttpUrl, tls: Tls, timeout: Long): OkHttpClient {
        require(tls.spki_sha256.matches(Regex("[0-9a-f]{64}"))) { "invalid_pin" }
        val digest = tls.spki_sha256.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val okhttpPin = "sha256/" + Base64.getEncoder().encodeToString(digest)
        // Pinner is checked after system trust + hostname validation and before HTTP bytes.
        // A private pool per effect also prevents reuse across changed trust decisions.
        var originalHeaders: Headers? = null
        val sent = AtomicBoolean(false)
        return baseClient.newBuilder().dispatcher(networkDispatcher).connectionPool(ConnectionPool())
            .eventListener(object : EventListener() {
                override fun requestHeadersStart(call: Call) {
                    if (!sent.compareAndSet(false, true)) call.cancel()
                }
            })
            .addInterceptor { chain ->
                val response = chain.proceed(chain.request())
                originalHeaders?.let { response.newBuilder().headers(it).build() } ?: response
            }
            .addNetworkInterceptor { chain ->
                val response = chain.proceed(chain.request())
                // OkHttp retries 503 + Retry-After: 0 even with retries disabled.
                // Hide that hint from its follow-up layer, then restore original headers.
                if (response.code == 503) {
                    originalHeaders = response.headers
                    response.newBuilder().header("Retry-After", "2147483647").build()
                } else response
            }
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .cookieJar(CookieJar.NO_COOKIES).cache(null).authenticator(Authenticator.NONE)
            .proxyAuthenticator(Authenticator.NONE)
            .certificatePinner(CertificatePinner.Builder().add(url.host, okhttpPin).build())
            .callTimeout(timeout.coerceAtLeast(1), TimeUnit.MILLISECONDS)
            .build().also { clients.add(it) }
    }

    private fun release(client: OkHttpClient) { clients.remove(client); client.connectionPool.evictAll() }

    private fun http(e: EffectHttpRequest) {
        var client: OkHttpClient? = null
        try {
            val url = secureUrl(e.url, e.tls)
            val active = client(url, e.tls, e.timeout_ms).also { client = it }
            val request = Request.Builder().url(url)
            e.headers.forEach { request.addHeader(it.name, it.value) }
            val body = e.body_base64?.let { Base64.getDecoder().decode(it).toRequestBody() }
            request.method(e.method, body)
            val call = active.newCall(request.build())
            calls[e.effect_id] = call
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    calls.remove(e.effect_id); release(active)
                    httpDone(e, null, emptyList(), null, if (call.isCanceled()) failure(TransportFailureKind.cancelled, TransportFailureCode.cancelled) else transport(error))
                }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use {
                            val output = ByteArrayOutputStream()
                            val buffer = ByteArray(8192)
                            val input = it.body?.byteStream()
                            if (input != null) while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                if (output.size().toLong() + count > e.max_response_bytes) throw ResponseLimit()
                                output.write(buffer, 0, count)
                            }
                            httpDone(e, it.code, it.headers.map { h -> Header(h.first, h.second) }, Base64.getEncoder().encodeToString(output.toByteArray()), null)
                        }
                    } catch (error: Exception) { httpDone(e, null, emptyList(), null, transport(error)) }
                    finally { calls.remove(e.effect_id); release(active) }
                }
            })
        } catch (error: Exception) { client?.let(::release); httpDone(e, null, emptyList(), null, transport(error)) }
    }

    /**
     * `http_request` semantics (pinned, no redirects/cookies/retries) for a GET whose body stays in
     * [files]; the core receives the status only. Nothing about the file is logged.
     */
    private fun fileFetch(e: EffectFileFetch) {
        var client: OkHttpClient? = null
        fun done(status: Int?, error: TransportFailure?) = emit { n, w ->
            EventHttpResponse(now_ms=n, wall_time_ms=w, effect_id=e.effect_id, generation=e.generation,
                status=status, headers=emptyList(), body_base64=null, error=error)
        }
        try {
            val url = secureUrl(e.url, e.tls)
            val active = client(url, e.tls, e.timeout_ms).also { client = it }
            val request = Request.Builder().url(url).get()
            e.headers.forEach { request.addHeader(it.name, it.value) }
            val call = active.newCall(request.build())
            calls[e.effect_id] = call
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    calls.remove(e.effect_id); release(active)
                    done(null, if (call.isCanceled()) failure(TransportFailureKind.cancelled, TransportFailureCode.cancelled) else transport(error))
                }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use {
                            if (!it.isSuccessful) { done(it.code, null); return }
                            val body = it.body
                            if (body != null && body.contentLength() > e.max_response_bytes) throw ResponseLimit()
                            val output = ByteArrayOutputStream()
                            val buffer = ByteArray(64 * 1024)
                            val input = body?.byteStream()
                            if (input != null) while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                if (output.size().toLong() + count > e.max_response_bytes) throw ResponseLimit()
                                output.write(buffer, 0, count)
                            }
                            if (call.isCanceled()) throw IOException()
                            files.put(e.intent_id, FileBody(output.toByteArray(), it.header("Content-Type")))
                            done(it.code, null)
                        }
                    } catch (error: Exception) {
                        done(null, if (call.isCanceled()) failure(TransportFailureKind.cancelled, TransportFailureCode.cancelled) else transport(error))
                    } catch (_: OutOfMemoryError) {
                        // Reported like the size cap: the viewer shows "too large".
                        done(null, transport(ResponseLimit()))
                    } finally { calls.remove(e.effect_id); release(active) }
                }
            })
        } catch (error: Exception) { client?.let(::release); done(null, transport(error)) }
    }

    private fun httpDone(e: EffectHttpRequest, status: Int?, headers: List<Header>, body: String?, error: TransportFailure?) = emit { n,w ->
        EventHttpResponse(now_ms=n, wall_time_ms=w, effect_id=e.effect_id, generation=e.generation, status=status, headers=headers, body_base64=body, error=error)
    }

    private inner class SocketState(val effect: EffectWsOpen, val client: OkHttpClient) {
        lateinit var socket: WebSocket
        val finished = AtomicBoolean(false)
        fun finish(code: Int?, clean: Boolean, error: TransportFailure?) {
            if (!finished.compareAndSet(false, true)) return
            sockets.remove(effect.effect_id)
            if (::socket.isInitialized) socket.cancel()
            release(client)
            emit { n,w -> EventWsClosed(now_ms=n, wall_time_ms=w, socket_id=effect.effect_id, generation=effect.generation, code=code, clean=clean, error=error) }
        }
    }

    private fun websocket(e: EffectWsOpen) {
        var active: OkHttpClient? = null
        try {
            val url = secureUrl(e.url, e.tls)
            active = client(url, e.tls, 30_000)
            val state = SocketState(e, active)
            val request = Request.Builder().url(url).header("Sec-WebSocket-Protocol", e.protocols.joinToString(", ")).build()
            state.socket = active.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    val protocol = response.header("Sec-WebSocket-Protocol") ?: ""
                    if (protocol !in e.protocols || protocol.startsWith("verde.ticket.")) {
                        state.finish(null, false, failure(TransportFailureKind.network, TransportFailureCode.unknown)); return
                    }
                    emit { n,w -> EventWsOpen(now_ms=n, wall_time_ms=w, socket_id=e.effect_id, generation=e.generation, protocol=protocol) }
                }
                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text.toByteArray().size.toLong() > e.max_message_bytes) {
                        state.finish(1009, false, failure(TransportFailureKind.resource, TransportFailureCode.resource)); return
                    }
                    if (!state.finished.get()) emit { n,w -> EventWsMessage(now_ms=n, wall_time_ms=w, socket_id=e.effect_id, generation=e.generation, text=text) }
                }
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    state.finish(1003, false, failure(TransportFailureKind.network, TransportFailureCode.unknown))
                }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    // 1005 means the peer sent an empty close frame; it is a
                    // local sentinel and must never be echoed onto the wire.
                    webSocket.close(if (code == 1005) 1000 else code, null)
                }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { state.finish(code, true, null) }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    response?.close(); state.finish(null, false, transport(t))
                }
            })
            sockets[e.effect_id] = state
            if (state.finished.get()) { sockets.remove(e.effect_id, state); state.socket.cancel() }
        } catch (error: Exception) {
            active?.let(::release)
            emit { n,w -> EventWsClosed(now_ms=n, wall_time_ms=w, socket_id=e.effect_id, generation=e.generation, code=null, clean=false, error=transport(error)) }
        }
    }

    private val probes = ConcurrentHashMap.newKeySet<Socket>()
    private fun probe(e: EffectTlsProbe) { scope.launch {
        var pin = ""
        var trusted = false
        try {
            val url = e.origin.toHttpUrl()
            require(url.isHttps && url.encodedPath == "/" && url.query == null && url.fragment == null && url.username.isEmpty() && url.password.isEmpty())
            val raw = Socket()
            probes.add(raw)
            try {
                raw.connect(InetSocketAddress(url.host, url.port), 15_000)
                val socket = baseClient.sslSocketFactory.createSocket(raw, url.host, url.port, true) as SSLSocket
                socket.soTimeout = 15_000
                socket.sslParameters = socket.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                socket.startHandshake()
                // The handshake sends no HTTP headers, pairing material or credential bytes.
                val certificate = socket.session.peerCertificates.first() as X509Certificate
                pin = java.security.MessageDigest.getInstance("SHA-256").digest(certificate.publicKey.encoded)
                    .joinToString("") { "%02x".format(it) }
                trusted = true
            } finally { probes.remove(raw); raw.close() }
        } catch (_: Exception) { /* No exception diagnostics may leave this boundary. */ }
        emit { n,w -> EventTlsPeer(now_ms=n, wall_time_ms=w, effect_id=e.effect_id, generation=e.generation, origin=e.origin, spki_sha256=pin, system_trusted=trusted) }
    } }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        completion = null
        calls.values.forEach { it.cancel() }; calls.clear()
        sockets.values.forEach { it.socket.cancel() }; sockets.clear()
        probes.forEach { try { it.close() } catch (_: IOException) {} }; probes.clear()
        timers.values.forEach { it.cancel() }; timers.clear()
        storage.close(); scope.cancel()
        files.clear()
        clients.forEach { it.connectionPool.evictAll() }; clients.clear()
        networkDispatcher.executorService.shutdown()
    }

    private class ResponseLimit : IOException()
    private fun failure(kind: TransportFailureKind, code: TransportFailureCode) = TransportFailure(kind, code)
    private fun transport(error: Throwable): TransportFailure = when (error) {
        is ResponseLimit -> failure(TransportFailureKind.resource, TransportFailureCode.resource)
        is SSLPeerUnverifiedException -> failure(TransportFailureKind.tls,
            if (error.message?.startsWith("Certificate pinning failure!") == true) TransportFailureCode.pin_mismatch else TransportFailureCode.hostname)
        is SSLException -> failure(TransportFailureKind.tls, TransportFailureCode.certificate)
        is SocketTimeoutException -> failure(TransportFailureKind.timeout, TransportFailureCode.timeout)
        is IllegalArgumentException -> failure(TransportFailureKind.tls, TransportFailureCode.pin_mismatch)
        else -> failure(TransportFailureKind.network, TransportFailureCode.unknown)
    }
}

package dev.verdeai.core

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import okhttp3.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.KeyGenerator

class CoreHostTest {
    private class MemoryStore : SecureStore {
        val values = mutableMapOf<String,String>()
        var fail = false
        override suspend fun get(key: String): String? { if (fail) throw java.io.IOException("fixture"); return values[key] }
        override suspend fun put(key: String, value: String) { if (fail) throw java.io.IOException("fixture"); values[key] = value }
        override suspend fun delete(key: String) { values.remove(key) }
    }
    private class FakeCore : CoreBridge {
        val events = Channel<Event>(Channel.UNLIMITED)
        var effects: List<Effect> = emptyList()
        var reaction: (Event) -> List<Effect> = { emptyList() }
        var thread = 0L
        var freed = false
        var queryStatus: Int? = null
        val selectors = mutableListOf<String>()
        private fun checkThread() {
            val current = Thread.currentThread().id
            if (thread == 0L) thread = current
            check(thread == current)
        }
        override fun create(config: ByteArray): Long { checkThread(); return 1 }
        override fun handle(host: Long, event: ByteArray): ByteArray {
            checkThread(); check(!freed)
            val decoded = CoreJson.decodeFromString<Event>(event.decodeToString())
            events.trySend(decoded)
            val batch = effects + reaction(decoded)
            effects = emptyList()
            return CoreJson.encodeToString(EffectBatch(1, "1", batch)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray {
            checkThread(); check(!freed); selectors.add(selector)
            queryStatus?.let { throw CoreFailure(it) }
            return """{"api_version":1,"revision":"2","data":null,"error":null}""".encodeToByteArray()
        }
        override fun free(host: Long) { checkThread(); check(!freed); freed = true }
        suspend inline fun <reified T : Event> next(): T = withTimeout(5_000) {
            while (true) { val event = events.receive(); if (event is T) return@withTimeout event }
            error("unreachable")
        }
    }
    private val config = Config(1, "test", "Test", null, null, 1, "01234567890123456789012345678901", 1uL)
    private fun executor(store: SecureStore = MemoryStore(), client: OkHttpClient = OkHttpClient()): EffectExecutor {
        val clock = AtomicLong(10)
        return EffectExecutor(store, "test", { clock.incrementAndGet() }, { 1000 }, baseClient=client)
    }
    private suspend fun start(host: CoreHost) = host.send { n,w -> EventStart(now_ms=n, wall_time_ms=w, foreground=true, network_available=true) }

    @Test fun inputStatusFromQueryAfterBatchRemainsFatal() = runBlocking {
        val core = FakeCore()
        core.queryStatus = 1
        core.effects = listOf(EffectStateChanged("view", "1", "1", listOf("hosts")))
        val host = CoreHost.create(config, executor(), core)
        try {
            try { start(host); fail("Expected batch failure") }
            catch (_: CoreFailure) { }
            assertTrue(host.failed.value)
            assertTrue(core.freed)
        } finally { host.close() }
    }

    @Test fun storageTimersViewsAndShutdown() = runBlocking {
        val core = FakeCore()
        val store = MemoryStore()
        val key = "vc/1/test/credential"
        core.effects = listOf(EffectSecureStorePut("put", "1", key, "YWJj"),
            EffectSecureStoreGet("get", "1", key), EffectSetTimer("timer", "1", "t", 200, "retry"),
            EffectSetTimer("cancel", "1", "cancelled", 10_000, "retry"), EffectCancelTimer("c", "1", "cancelled"),
            EffectStateChanged("view", "1", "2", listOf("hosts", "home", "workspaces")))
        val host = CoreHost.create(config, executor(store), core)
        try {
            start(host)
            assertNull(core.next<EventSecureStoreDone>().error)
            assertEquals("YWJj", core.next<EventSecureStoreValue>().value_base64)
            assertEquals("t", core.next<EventTimerFired>().timer_id)
            assertEquals("2", host.hosts.value?.revision)
            assertEquals(3, host.views.value.size)
            core.effects = listOf(EffectSecureStoreDelete("del", "1", key), EffectSecureStoreGet("missing", "1", key))
            host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
            assertNull(core.next<EventSecureStoreDone>().error)
            assertNull(core.next<EventSecureStoreValue>().value_base64)
            store.fail = true
            core.effects = listOf(EffectSecureStoreGet("fail", "1", key))
            host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
            assertEquals(PlatformFailureCode.io, core.next<EventSecureStoreValue>().error?.code)
        } finally { host.close() }
        assertTrue(core.freed)
    }

    private class TlsFixture : AutoCloseable {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val server = MockWebServer()
        val client = OkHttpClient.Builder().sslSocketFactory(
            HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build().let { it.sslSocketFactory() },
            HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build().trustManager,
        ).build()
        init {
            val serverTls = HandshakeCertificates.Builder().heldCertificate(cert).build()
            server.useHttps(serverTls.sslSocketFactory(), false)
            server.start()
        }
        val pin get() = java.security.MessageDigest.getInstance("SHA-256").digest(cert.certificate.publicKey.encoded)
            .joinToString("") { "%02x".format(it) }
        val origin get() = server.url("/").toString().removeSuffix("/")
        fun http(id: String = "http", pin: String = this.pin, cap: Long = 1000) = EffectHttpRequest(id,"1","POST",server.url("/api/rpc").toString(),emptyList(),"e30=",3000,cap,Tls(origin,pin))
        override fun close() { server.shutdown(); client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll() }
    }

    @Test fun httpSuccessPinMismatchAndSystemTrust() = runBlocking {
        TlsFixture().use { fixture ->
            val core = FakeCore()
            val host = CoreHost.create(config, executor(client=fixture.client), core)
            try {
                fixture.server.enqueue(MockResponse().setBody("reply"))
                core.effects = listOf(fixture.http())
                start(host)
                val response = core.next<EventHttpResponse>()
                assertNull(response.error?.code?.name, response.error)
                assertEquals(200, response.status)
                assertEquals("reply", String(Base64.getDecoder().decode(response.body_base64)))
                assertNotNull(fixture.server.takeRequest(2, TimeUnit.SECONDS))
                core.effects = listOf(fixture.http("bad", "0".repeat(64)))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                assertEquals(TransportFailureCode.pin_mismatch, core.next<EventHttpResponse>().error?.code)
                assertNull(fixture.server.takeRequest(200, TimeUnit.MILLISECONDS))
                fixture.server.enqueue(MockResponse().setBody("too large"))
                core.effects = listOf(fixture.http("cap", cap=2))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                assertEquals(TransportFailureCode.resource, core.next<EventHttpResponse>().error?.code)
                fixture.server.takeRequest(2, TimeUnit.SECONDS)
            } finally { host.close() }
            val untrustedCore = FakeCore()
            val untrustedHost = CoreHost.create(config, executor(), untrustedCore)
            try {
                untrustedCore.effects = listOf(fixture.http())
                start(untrustedHost)
                assertEquals(TransportFailureKind.tls, untrustedCore.next<EventHttpResponse>().error?.kind)
                assertNull(fixture.server.takeRequest(200, TimeUnit.MILLISECONDS))
            } finally { untrustedHost.close() }
        }
    }

    @Test fun noRedirectReplayAndIndependentRequests() = runBlocking {
        TlsFixture().use { fixture ->
            val core = FakeCore()
            val host = CoreHost.create(config, executor(client=fixture.client), core)
            try {
                fixture.server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After", "0"))
                core.effects = listOf(fixture.http("busy").copy(method="GET", body_base64=null))
                start(host)
                val busy = core.next<EventHttpResponse>()
                assertNull(busy.error?.code?.name, busy.error)
                assertEquals(503, busy.status)
                assertEquals("0", busy.headers.first { it.name.equals("Retry-After", true) }.value)
                fixture.server.takeRequest(2, TimeUnit.SECONDS)
                assertNull(fixture.server.takeRequest(100, TimeUnit.MILLISECONDS))
                fixture.server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", fixture.server.url("/elsewhere")))
                core.effects = listOf(fixture.http("redirect"))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                assertEquals(302, core.next<EventHttpResponse>().status)
                fixture.server.takeRequest(2, TimeUnit.SECONDS)
                assertNull(fixture.server.takeRequest(100, TimeUnit.MILLISECONDS))
                fixture.server.enqueue(MockResponse().setBody("slow").setBodyDelay(500, TimeUnit.MILLISECONDS))
                core.effects = listOf(fixture.http("slow"))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                fixture.server.takeRequest(2, TimeUnit.SECONDS)
                fixture.server.enqueue(MockResponse().setBody("fast"))
                core.effects = listOf(fixture.http("fast"))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                assertEquals("fast", core.next<EventHttpResponse>().effect_id)
                assertEquals("slow", core.next<EventHttpResponse>().effect_id)
                fixture.server.takeRequest(2, TimeUnit.SECONDS)
                fixture.server.enqueue(MockResponse().setBody("cancel").setBodyDelay(3, TimeUnit.SECONDS))
                core.effects = listOf(fixture.http("cancel"))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                fixture.server.takeRequest(2, TimeUnit.SECONDS)
                core.effects = listOf(EffectHttpCancel("c", "1", "cancel"))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                assertNotNull(core.next<EventHttpResponse>().error)
            } finally { host.close() }
        }
    }

    @Test fun parkedCallsDoNotOccupyInteractiveSlots() = runBlocking {
        TlsFixture().use { fixture ->
            val arrived = java.util.concurrent.CountDownLatch(6)
            fixture.server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
                override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                    if (request.path == "/interactive") return MockResponse().setBody("ready")
                    arrived.countDown()
                    return MockResponse().setBody("parked").setBodyDelay(3, TimeUnit.SECONDS)
                }
            }
            val core = FakeCore()
            val host = CoreHost.create(config, executor(client=fixture.client), core)
            try {
                core.effects = (1..6).map { fixture.http("parked-$it").copy(timeout_ms=5000) }
                start(host)
                assertTrue(arrived.await(2, TimeUnit.SECONDS))
                core.effects = listOf(fixture.http("interactive").copy(url=fixture.server.url("/interactive").toString()))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                assertEquals("interactive", core.next<EventHttpResponse>().effect_id)
            } finally { host.close() }
        }
    }

    @Test fun websocketRoundTripAndProbe() = runBlocking {
        TlsFixture().use { fixture ->
            fixture.server.enqueue(MockResponse().setHeader("Sec-WebSocket-Protocol", "verde.v1").withWebSocketUpgrade(object : WebSocketListener() {
                override fun onMessage(socket: WebSocket, text: String) { socket.send(text); socket.close(1000, null) }
                override fun onClosing(socket: WebSocket, code: Int, reason: String) { socket.close(code, null) }
            }))
            val core = FakeCore()
            val host = CoreHost.create(config, executor(client=fixture.client), core)
            try {
                core.effects = listOf(EffectWsOpen("ws", "1", fixture.server.url("/ws").toString().replace("https:","wss:"), listOf("verde.v1", "verde.ticket.fixture"), Tls(fixture.origin,fixture.pin), 1000))
                core.reaction = { if (it is EventWsOpen) listOf(EffectWsSend("send", "1", "ws", "fixture")) else emptyList() }
                start(host)
                assertEquals("verde.v1", core.next<EventWsOpen>().protocol)
                assertEquals("fixture", core.next<EventWsMessage>().text)
                assertTrue(core.next<EventWsClosed>().clean)
                assertEquals("verde.v1, verde.ticket.fixture", fixture.server.takeRequest(2,TimeUnit.SECONDS)?.getHeader("Sec-WebSocket-Protocol"))
                core.effects = listOf(EffectTlsProbe("probe", "1", fixture.origin))
                host.send { n,w -> EventForeground(now_ms=n, wall_time_ms=w) }
                val peer = core.next<EventTlsPeer>()
                assertTrue(peer.system_trusted)
                assertEquals(fixture.pin, peer.spki_sha256)
                assertNull(fixture.server.takeRequest(200,TimeUnit.MILLISECONDS))
            } finally { host.close() }
        }
    }

    @Test fun encryptedStoreRoundTripAndTampering() = runBlocking {
        val master = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val serializer = CredentialSerializer { master }
        val output = java.io.ByteArrayOutputStream()
        val value = mapOf("vc/1/test/credential" to "fixture-secret")
        serializer.writeTo(value, output)
        val encrypted = output.toByteArray()
        assertFalse(String(encrypted).contains("fixture-secret"))
        assertEquals(value, serializer.readFrom(encrypted.inputStream()))
        encrypted[encrypted.lastIndex] = (encrypted.last().toInt() xor 1).toByte()
        try { serializer.readFrom(encrypted.inputStream()); fail("tamper accepted") }
        catch (_: javax.crypto.AEADBadTagException) { }
    }
}

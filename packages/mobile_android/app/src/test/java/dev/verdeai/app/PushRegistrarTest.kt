package dev.verdeai.app

import dev.verdeai.core.CoreJson
import dev.verdeai.core.SecureStore
import kotlinx.coroutines.*
import kotlinx.serialization.decodeFromString
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** D-14 registration: relay contract, per-host registration, token refresh, rotation and opt-out. */
class PushRegistrarTest {
    private lateinit var relayServer: MockWebServer
    private val store = MemoryStore()
    private val tokens = FakeTokens()
    private val hosts = FakeHosts()
    /** Inert: the registrar's background loop never runs, so only explicit syncs reach the relay. */
    private val scope = CoroutineScope(Job().apply { cancel() })

    @Before fun setUp() { relayServer = MockWebServer().apply { start() } }
    @After fun tearDown() { relayServer.shutdown() }

    private fun registrar(withRelay: Boolean = true, withTokens: Boolean = true) = PushRegistrar(store,
        if (withTokens) tokens else null, if (withRelay) PushRelay(relayServer.url("/relay/")) else null, scope)
    private fun created(token: String) = MockResponse().setResponseCode(201).setBody("""{"send_token":"$token"}""")
    private fun take(): RecordedRequest = relayServer.takeRequest(5, TimeUnit.SECONDS)!!
    private fun record(): PushRecord = CoreJson.decodeFromString(store.values[PushRegistrar.KEY]!!)

    @Test fun withoutFirebaseOrRelayNothingIsRegistered() = runBlocking {
        for (push in listOf(registrar(withTokens = false), registrar(withRelay = false))) {
            push.attach(hosts)
            push.setEnabled(true)
            assertEquals(PushStatus.Unavailable, push.state.value.status)
            assertFalse(push.state.value.available)
        }
        assertEquals(0, relayServer.requestCount)
        assertEquals(0, tokens.requests)
        assertTrue(hosts.registered.isEmpty())
    }

    @Test fun enablingRegistersTheTokenThenEveryPairedHost() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired, "b" to HostPushState.Paired, "c" to HostPushState.Gone)
        relayServer.enqueue(created("v1.one.sig"))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        val request = take()
        assertEquals("POST", request.method)
        assertEquals("/relay/v1/register", request.path)
        assertEquals("""{"platform":"android","push_token":"fcm-1"}""", request.body.readUtf8())
        assertEquals(setOf("a", "b"), hosts.registered.keys)
        hosts.registered.values.forEach { (sendToken, seed) ->
            assertEquals("v1.one.sig", sendToken)
            assertEquals(32, Base64.getDecoder().decode(seed).size)
        }
        assertNotEquals(hosts.registered["a"]!!.second, hosts.registered["b"]!!.second)
        assertEquals(PushStatus.On, push.state.value.status)
        // A second sync with nothing changed touches neither relay nor hosts.
        hosts.registered.clear()
        push.sync()
        assertEquals(1, relayServer.requestCount)
        assertTrue(hosts.registered.isEmpty())
    }

    @Test fun tokenRefreshRegistersUpdatesHostsThenDeletesTheOldCapability() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired)
        relayServer.enqueue(created("v1.old.sig"))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        take()
        // Background refresh (no Activity): new capability now, old one kept until hosts move.
        push.detach(hosts)
        relayServer.enqueue(created("v1.new.sig"))
        push.onNewToken("fcm-2")
        assertEquals("""{"platform":"android","push_token":"fcm-2"}""", take().body.readUtf8())
        assertEquals(listOf("v1.old.sig"), record().retired)
        assertEquals("v1.new.sig", record().send_token)
        assertEquals(2, relayServer.requestCount)
        // Foreground again: the host gets the new capability, then the old one is deleted.
        hosts.registered.clear()
        tokens.token = "fcm-2"
        relayServer.enqueue(MockResponse().setResponseCode(204))
        push.attach(hosts)
        push.sync()
        assertEquals("v1.new.sig", hosts.registered["a"]!!.first)
        val delete = take()
        assertEquals("DELETE", delete.method)
        assertEquals("/relay/v1/register", delete.path)
        assertEquals("""{"send_token":"v1.old.sig"}""", delete.body.readUtf8())
        assertTrue(record().retired.isEmpty())
        assertEquals(PushStatus.On, push.state.value.status)
    }

    @Test fun oldCapabilityIsKeptWhileAHostCannotBeUpdated() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired)
        relayServer.enqueue(created("v1.old.sig"))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        take()
        hosts.result = HostRegistration.Retry
        relayServer.enqueue(created("v1.new.sig"))
        push.onNewToken("fcm-2")
        take()
        assertEquals(listOf("v1.old.sig"), record().retired)
        assertEquals(2, relayServer.requestCount)
        assertEquals(PushStatus.Error, push.state.value.status)
    }

    @Test fun removingAHostRotatesTheCapability() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired, "b" to HostPushState.Paired)
        relayServer.enqueue(created("v1.first.sig"))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        take()
        hosts.states = mapOf("a" to HostPushState.Paired) // b removed from this phone
        hosts.registered.clear()
        relayServer.enqueue(created("v1.second.sig"))
        relayServer.enqueue(MockResponse().setResponseCode(410)) // already revoked is fine
        push.sync()
        assertEquals("POST", take().method)
        assertEquals("""{"send_token":"v1.first.sig"}""", take().body.readUtf8())
        assertEquals(setOf("a"), hosts.registered.keys)
        assertEquals("v1.second.sig", hosts.registered["a"]!!.first)
        assertEquals(setOf("a"), record().hosts.keys)
        assertTrue(record().retired.isEmpty())
    }

    @Test fun catalogStillLoadingRetiresNothing() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired)
        relayServer.enqueue(created("v1.one.sig"))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        take()
        hosts.states = null
        push.sync()
        assertEquals(1, relayServer.requestCount)
        assertEquals(setOf("a"), record().hosts.keys)
    }

    @Test fun turningOffDeletesTheCapabilityAndTheToken() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired)
        relayServer.enqueue(created("v1.one.sig"))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        take()
        relayServer.enqueue(MockResponse().setResponseCode(503))
        push.setEnabled(false)
        assertEquals("DELETE", take().method)
        assertEquals(1, tokens.deletes)
        // 503 keeps it for a retry; the next sync deletes it.
        assertEquals(listOf("v1.one.sig"), record().retired)
        relayServer.enqueue(MockResponse().setResponseCode(204))
        push.sync()
        take()
        assertTrue(record().retired.isEmpty())
        assertNull(record().send_token)
        assertEquals(PushStatus.Off, push.state.value.status)
    }

    @Test fun relayFailuresNeverLeakTheRequest() = runBlocking {
        hosts.states = mapOf("a" to HostPushState.Paired)
        relayServer.enqueue(MockResponse().setResponseCode(503).setBody("""{"send_token":"nope"}"""))
        val push = registrar()
        push.attach(hosts)
        push.setEnabled(true)
        take()
        assertEquals(PushStatus.Error, push.state.value.status)
        assertNull(record().send_token)
        assertTrue(hosts.registered.isEmpty())
        val error = runCatching { PushRelay(relayServer.url("/")).also { relayServer.enqueue(MockResponse().setResponseCode(400)) }.register("secret-token") }.exceptionOrNull()
        assertTrue(error is RelayException)
        assertFalse(error!!.message!!.contains("secret"))
    }

    @Test fun relayBaseMustBeHttps() {
        assertNull(PushBuild.relayBase(""))
        assertNull(PushBuild.relayBase("http://relay.example"))
        assertNull(PushBuild.relayBase("https://relay.example/?x=1"))
        assertEquals("https://relay.example/base", PushBuild.relayBase("https://relay.example/base/")!!.toString())
        assertFalse(PushBuild.of(null, "https://relay.example").available)
        assertFalse(PushBuild.of(FirebaseConfig.of("p", "a", "k", "1"), "").available)
        assertNull(FirebaseConfig.of("p", "", "k", "1"))
    }

    private class FakeTokens : PushTokens {
        @Volatile var token = "fcm-1"
        @Volatile var requests = 0
        @Volatile var deletes = 0
        override suspend fun token(): String { requests++; return token }
        override suspend fun delete() { deletes++ }
    }

    private class FakeHosts : PushHosts {
        @Volatile var states: Map<String, HostPushState>? = emptyMap()
        @Volatile var result = HostRegistration.Registered
        val registered = ConcurrentHashMap<String, Pair<String, String>>()
        override fun states() = states
        override suspend fun register(hostId: String, sendToken: String, keySeedBase64: String): HostRegistration {
            if (result == HostRegistration.Registered) registered[hostId] = sendToken to keySeedBase64
            return result
        }
    }

    private class MemoryStore : SecureStore {
        val values = ConcurrentHashMap<String, String>()
        override suspend fun get(key: String): String? = values[key]
        override suspend fun put(key: String, value: String) { values[key] = value }
        override suspend fun delete(key: String) { values.remove(key) }
    }
}

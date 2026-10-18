package dev.verdeai.app

import android.os.Looper
import org.robolectric.Shadows.shadowOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import org.junit.Assert.*
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35])
class PairingScreenTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private lateinit var model: PairingModel
    private val fake = PairingCore()
    private val storage = MemoryStore()

    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idle()
        condition()
    }

    private fun launch() {
        val ticks = AtomicLong(1)
        compose.runOnUiThread {
            model = ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = PairingModel {
                    CoreHost.create(dev.verdeai.core.Config(1,"test","Test",null,null,1,"",0uL),
                        EffectExecutor(storage,"test",{ ticks.incrementAndGet() },{ 1000 }),fake)
                } as T
            })[PairingModel::class.java]
            model.foreground(true)
        }
        compose.setContent { PairingScreen(model) }
        await { model.state.value.canEnter }
    }
    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        if (::model.isInitialized) await { fake.freed }
    }
    private fun enter() {
        compose.runOnIdle { model.receiveLink("fixture-link"); model.pair() }
        await { model.state.value.host?.trust_proposal != null }
    }

    @Test fun confirmsHostAndShowsHomeOnlyAfterDurableCredential() {
        storage.failWrites = true
        launch()
        enter()
        compose.onNodeWithText("https://fixture.invalid").assertIsDisplayed()
        assertFalse(fake.events.any { it is EventTrustDecision })
        compose.onNodeWithText("Trust and pair").performScrollTo().performClick()
        await { model.state.value.error?.domain == "storage" }
        compose.onNodeWithText("Home").assertDoesNotExist()
        storage.failWrites = false
        compose.onNodeWithText("Retry").performScrollTo().performClick()
        await { model.state.value.complete }
        compose.onNodeWithText("Home").assertIsDisplayed()
        assertTrue(storage.saved)
        assertEquals(1, fake.events.count { it is EventPair })
        assertTrue(fake.events.filterIsInstance<EventPair>().single().client_nonce.matches(Regex("[0-9a-f]{32}")))
        assertTrue(model.link.isEmpty())
    }

    @Test fun deniedTrustAllowsFreshInput() {
        launch(); enter()
        compose.onNodeWithText("Do not trust").performScrollTo().performClick()
        await { model.state.value.canEnter }
        assertFalse(storage.saved)
        assertFalse(fake.events.filterIsInstance<EventTrustDecision>().single().accept)
    }

    @Test fun networkRetryDoesNotResubmitPairOrReplacePendingLink() {
        fake.networkFailure = true
        launch()
        compose.runOnIdle { model.receiveLink("fixture-link"); model.pair() }
        await { model.state.value.error?.code == "network_unavailable" }
        compose.runOnIdle { model.receiveLink("another-fixture") }
        assertTrue(model.link.isEmpty())
        compose.onNodeWithText("Retry").performScrollTo().performClick()
        await { fake.events.any { it is EventRetryConnection } }
        assertEquals(1, fake.events.count { it is EventPair })
    }

    @Test fun pairingErrorsNeverEchoPeerMessages() {
        assertFalse(pairingError(LocalError(code="unknown",message="untrusted fixture")).contains("untrusted fixture"))
    }

    private class MemoryStore : SecureStore {
        @Volatile var failWrites = false
        @Volatile var saved = false
        override suspend fun get(key: String): String? = null
        override suspend fun put(key: String, value: String) {
            if (failWrites) throw java.io.IOException("fixture")
            saved=true
        }
        override suspend fun delete(key: String) { }
    }
    private class PairingCore : CoreBridge {
        val events = CopyOnWriteArrayList<Event>()
        @Volatile var freed = false
        @Volatile var networkFailure = false
        private var row = HostView("test","Test",null,null,null,"disabled",Lifecycle.background,"unpaired","empty",
            emptyList(),emptyList(),null,null,false,null)
        private var operation: Operation? = null
        private val proposal = TrustProposal("proposal", "https://fixture.invalid", "a".repeat(64), "b".repeat(32))
        private fun put() = EffectSecureStorePut("save","1","vc/1/test/credential","Zml4dHVyZQ==")
        override fun create(config: ByteArray) = 1L
        override fun handle(host: Long, event: ByteArray): ByteArray {
            val decoded = CoreJson.decodeFromString<Event>(event.decodeToString())
            events.add(decoded)
            val effects = mutableListOf<Effect>()
            when (decoded) {
                is EventForeground -> row=row.copy(lifecycle=Lifecycle.foreground)
                is EventBackground -> row=row.copy(lifecycle=Lifecycle.background)
                is EventPair -> {
                    operation=Operation(decoded.intent_id,"pending",null)
                    row=if (networkFailure) row.copy(error=LocalError(code="network_unavailable",message="",retryable=true))
                        else row.copy(trust_proposal=proposal,error=null)
                }
                is EventTrustDecision -> {
                    row=row.copy(trust_proposal=null)
                    if (decoded.accept) effects.add(put())
                    else operation=operation!!.copy(state="failed",error=LocalError(code="trust_denied",message=""))
                }
                is EventSecureStoreDone -> if (decoded.error == null) {
                    row=row.copy(auth_state="paired",error=null)
                    operation=operation!!.copy(state="succeeded")
                } else row=row.copy(error=LocalError(domain="storage",code="io",message="",retryable=true))
                is EventRetryConnection -> if (row.error?.domain == "storage") effects.add(put())
                else -> Unit
            }
            effects.add(EffectStateChanged("view","1","1",listOf("hosts","operations")))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String) = (if (selector == "operations")
            CoreJson.encodeToString(OperationsQuery(1,"1",OperationsView(listOfNotNull(operation)),null))
        else CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(this.row),listOfNotNull(operation)),null))).encodeToByteArray()
        override fun free(host: Long) { freed=true }
    }
}

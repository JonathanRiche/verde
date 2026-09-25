package dev.verdeai.app

import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35])
class HostsScreenTest {
    @get:Rule val compose = createComposeRule()
    private var models = ViewModelStore()
    private lateinit var model: HostsModel
    private val store = MemoryStore()
    private val cores = CopyOnWriteArrayList<FakeCore>()
    private var offline = false
    private var revoked = false
    private var used = 0
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) {
        shadowOf(Looper.getMainLooper()).idle(); condition()
    }
    private fun seed() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(
            listOf(SavedHost("alpha","Alpha"),SavedHost("beta","Beta")), "alpha"))
        for (id in listOf("alpha","beta")) for (record in listOf("credential","profile"))
            store.values["vc/1/$id/$record"]="Zml4dHVyZQ=="
    }
    private fun launch(waitReady: Boolean = true) {
        compose.runOnUiThread {
            model=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = HostsModel(store) { saved ->
                    val fake=FakeCore(saved, offline, revoked).also(cores::add)
                    CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL),
                        EffectExecutor(store,saved.id),fake)
                } as T
            })[HostsModel::class.java]
            model.foreground(true)
        }
        compose.setContent { HostsScreen(model, onUse={ used++ }) }
        if (waitReady) await { !model.state.value.loading && model.state.value.rows.all { it.view?.lifecycle == Lifecycle.foreground } }
    }
    private fun row(id: String) = model.state.value.rows.single { it.saved.id == id }
    @After fun cleanup() {
        store.deleteGate?.complete(Unit)
        compose.runOnUiThread { models.clear() }
        if (::model.isInitialized) await { cores.all { it.freed } }
    }
    @Test fun listsIndependentHostsSwitchesAndRestoresSelection() {
        seed(); launch()
        compose.onNodeWithText("Alpha",useUnmergedTree=true).assertExists()
        compose.onNodeWithText("Beta",useUnmergedTree=true).assertExists()
        compose.onNodeWithText("Use Beta").performScrollTo().performClick()
        await { model.state.value.active == "beta" && !model.state.value.busy }
        // Navigation to Home belongs to VerdeApp; the host list only reports the choice.
        assertEquals(1,used)
        compose.onNodeWithText("Hosts").assertExists()
        val saved=CoreJson.decodeFromString<HostCatalog>(store.values[HostsModel.CATALOG_KEY]!!)
        assertEquals("beta",saved.active)
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
        models=ViewModelStore()
        // Restore without changing the content owner/rule.
        compose.runOnUiThread {
            model=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = HostsModel(store) { host ->
                    val fake=FakeCore(host,false,false).also(cores::add)
                    CoreHost.create(dev.verdeai.core.Config(1,host.id,host.label,null,null,1,"",0uL),EffectExecutor(store,host.id),fake)
                } as T
            })[HostsModel::class.java]
        }
        await { !model.state.value.loading }
        assertEquals("beta",model.state.value.active)
        assertEquals(2,model.state.value.rows.size)
    }
    @Test fun signOutIsHostScopedAndRemovalWaitsForDeleteAcknowledgements() {
        seed(); store.deleteGate=CompletableDeferred(); launch()
        compose.onAllNodesWithText("Sign out of host")[0].performScrollTo().performClick()
        compose.onNodeWithText("Sign out of Alpha?").assertExists()
        assertFalse(cores.any { core -> core.events.any { it is EventSignOut } })
        compose.onNodeWithText("Sign out",useUnmergedTree=true).performClick()
        await { row("alpha").view?.auth_state == "signing_out" }
        compose.runOnIdle { model.remove("alpha") }
        await { !model.state.value.busy }
        assertEquals(2,model.state.value.rows.size)
        assertTrue(store.values.containsKey("vc/1/alpha/credential"))
        assertFalse(cores.single { it.saved.id == "beta" }.events.any { it is EventSignOut })
        store.deleteGate!!.complete(Unit)
        await { row("alpha").view?.auth_state == "signed_out" }
        assertFalse(store.values.containsKey("vc/1/alpha/credential"))
        assertFalse(store.values.containsKey("vc/1/alpha/profile"))
        assertTrue(store.values.containsKey("vc/1/beta/credential"))
        compose.onNodeWithText("Remove from hosts").performScrollTo().performClick()
        await { model.state.value.rows.size == 1 }
        assertEquals("beta",model.state.value.active)
    }
    @Test fun offlineSignOutOffersExplicitForgetAndWarnsAboutDesktop() {
        seed(); offline=true; launch()
        compose.runOnIdle { model.signOut("alpha") }
        await { row("alpha").operation?.error?.code == "sign_out_unconfirmed" }
        assertTrue(store.deletes.isEmpty())
        compose.onNodeWithText("Remove from this phone anyway").performScrollTo().performClick()
        compose.onNodeWithText("This removes the local credential and host trust. This device may remain listed on the desktop until you revoke it there.").assertExists()
        compose.onNodeWithText("Cancel",useUnmergedTree=true).performClick()
        assertFalse(cores.any { core -> core.events.any { it is EventForgetHost } })
        compose.onNodeWithText("Remove from this phone anyway").performScrollTo().performClick()
        compose.onNodeWithText("Remove anyway",useUnmergedTree=true).performClick()
        await { row("alpha").view?.auth_state == "signed_out" }
        assertEquals(1,cores.single { it.saved.id == "alpha" }.events.count { it is EventForgetHost })
        assertTrue(store.values.containsKey("vc/1/beta/credential"))
    }
    @Test fun deleteFailureIsVisibleAndRetryUsesCoreWithoutRepeatingRevoke() {
        seed(); store.failDelete=true; launch()
        compose.runOnIdle { model.signOut("alpha") }
        await { row("alpha").operation?.error?.code == "sign_out_delete_failed" }
        assertNotEquals("signed_out",row("alpha").view?.auth_state)
        compose.onNodeWithText("Local data could not be removed. Unlock your phone and retry.").assertExists()
        store.failDelete=false
        compose.onNodeWithText("Retry removal").performScrollTo().performClick()
        await { row("alpha").view?.auth_state == "signed_out" }
        val events=cores.single { it.saved.id == "alpha" }.events
        assertEquals(1,events.count { it is EventSignOut })
        assertEquals(1,events.count { it is EventRetryConnection })
    }
    @Test fun revokedAndUnreachableStatesStayDistinct() {
        seed(); revoked=true; launch()
        assertTrue(hostStatus(row("alpha")).contains("Pair again"))
        assertTrue(hostStatus(row("alpha").copy(view=row("alpha").view!!.copy(auth_state="paired",phase="failed",
            error=LocalError(code="network_unavailable",message="peer text",failure_kind="network")))).contains("Tailscale"))
        compose.runOnIdle { model.signOut("alpha") }
        await { row("alpha").view?.auth_state == "signed_out" }
    }
    @Test fun catalogFailureDoesNotEraseHostsAndCanRetry() {
        seed(); store.failRead=true
        launch(waitReady=false)
        await { model.state.value.error != null }
        assertTrue(store.deletes.isEmpty())
        store.failRead=false
        compose.onNodeWithText("Retry loading hosts").performClick()
        await { !model.state.value.loading && model.state.value.rows.size == 2 }
        assertTrue(store.values.containsKey("vc/1/alpha/credential"))
    }
    @Test fun failedSelectionWritePreservesActiveHost() {
        seed(); launch()
        store.failWrite=true
        compose.runOnIdle { model.select("beta") }
        await { model.state.value.error != null && !model.state.value.busy }
        assertEquals("alpha",model.state.value.active)
        assertEquals("alpha",CoreJson.decodeFromString<HostCatalog>(store.values[HostsModel.CATALOG_KEY]!!).active)
        store.failWrite=false
        compose.runOnIdle { model.select("beta") }
        await { model.state.value.active == "beta" }
    }
    @Test fun addPersistsUniqueProfileAndMigratesPrimarySlot() {
        launch()
        assertEquals("primary",model.state.value.active)
        compose.runOnIdle { model.add("Second host") }
        await { model.state.value.rows.size == 2 && !model.state.value.busy }
        val added=model.state.value.rows.last().saved
        assertNotEquals("primary",added.id)
        assertEquals(added.id,model.state.value.pairing)
        assertTrue(store.values[HostsModel.CATALOG_KEY]!!.contains("Second host"))
    }
    private class MemoryStore : SecureStore {
        val values=ConcurrentHashMap<String,String>()
        val deletes=CopyOnWriteArrayList<String>()
        @Volatile var failDelete=false
        @Volatile var failRead=false
        @Volatile var failWrite=false
        @Volatile var deleteGate: CompletableDeferred<Unit>?=null
        override suspend fun get(key: String): String? { if (failRead) throw java.io.IOException("fixture"); return values[key] }
        override suspend fun put(key: String,value: String) { if (failWrite) throw java.io.IOException("fixture"); values[key]=value }
        override suspend fun delete(key: String) {
            deleteGate?.await()
            if (failDelete) throw java.io.IOException("fixture")
            values.remove(key); deletes.add(key)
        }
    }
    private class FakeCore(val saved: SavedHost, val offline: Boolean, revoked: Boolean) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        @Volatile var freed=false
        private var row=HostView(saved.id,saved.label,null,null,null,if (offline) "failed" else "ready",
            Lifecycle.background,if (revoked) "repair_required" else "paired","empty",emptyList(),emptyList(),null,null,false,null)
        private var op: Operation?=null
        private var record="credential"
        private var sequence=0
        private fun delete() = EffectSecureStoreDelete("delete-${sequence++}","1","vc/1/${saved.id}/$record")
        override fun create(config: ByteArray)=1L
        override fun handle(host: Long,event: ByteArray): ByteArray {
            val decoded=CoreJson.decodeFromString<Event>(event.decodeToString())
            events.add(decoded)
            val effects=mutableListOf<Effect>()
            fun wipe(id: String) { op=Operation(id,"pending",null); row=row.copy(auth_state="signing_out",error=null); effects.add(delete()) }
            when(decoded) {
                is EventForeground -> row=row.copy(lifecycle=Lifecycle.foreground)
                is EventBackground -> row=row.copy(lifecycle=Lifecycle.background)
                is EventSignOut -> {
                    check(decoded.host_id == saved.id)
                    if (offline) op=Operation(decoded.intent_id,"uncertain",LocalError(domain="auth",code="sign_out_unconfirmed",message="",retryable=true))
                    else wipe(decoded.intent_id)
                }
                is EventForgetHost -> { check(decoded.host_id == saved.id); wipe(decoded.intent_id) }
                is EventRetryConnection -> wipe(decoded.intent_id)
                is EventSecureStoreDone -> {
                    if(decoded.error != null) op=op!!.copy(state="failed",error=LocalError(domain="storage",code="sign_out_delete_failed",message="",retryable=true))
                    else if(record == "credential") { record="profile"; effects.add(delete()) }
                    else { row=row.copy(auth_state="signed_out"); op=op!!.copy(state="succeeded",error=null) }
                }
                else -> Unit
            }
            effects.add(EffectStateChanged("view","1","1",listOf("hosts")))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long,selector: String)=CoreJson.encodeToString(
            HostsQuery(1,"1",HostsView(listOf(row),listOfNotNull(op)),null)).encodeToByteArray()
        override fun free(host: Long) { freed=true }
    }
}

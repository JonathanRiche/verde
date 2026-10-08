package dev.verdeai.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import dev.verdeai.core.Config
import dev.verdeai.core.CoreHost
import dev.verdeai.core.EffectExecutor

class MainActivity : ComponentActivity() {
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private var pushDirectory: HostsPushDirectory? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(0xFF20272A.toInt()),
            navigationBarStyle = SystemBarStyle.dark(0xFF0D1213.toInt()),
        )
        // Secure until the saved privacy setting loads; D-15's app lock then owns the flag.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val app = application as VerdeApplication
        val lock = app.appLock
        lifecycleScope.launch { lock.state.collect { applySecureWindow(this@MainActivity, it) } }
        val cache = ViewCache(app.viewCache)
        // ProcessLifecycleOwner + ConnectivityManager feed every host core (foreground/background/network_changed).
        val provider = ViewModelProvider(this, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                HostsModel::class.java -> HostsModel(app.secureStore, app.signals, cache) { saved ->
                    CoreHost.create(Config(1, saved.id, saved.label, null, null, 1, "", 0uL),
                        EffectExecutor(app.secureStore, saved.id, socketTrace = ConnectionDiagnostics::socket, terminalTiming = if (ConnectionDiagnostics.enabled) ConnectionDiagnostics::terminal else null),
                        traceMetadata = if (ConnectionDiagnostics.enabled) ConnectionDiagnostics::core else null)
                }
                BrowseModel::class.java -> BrowseModel(hosts, cache, app.signals)
                NotificationActionsModel::class.java -> NotificationActionsModel(hosts, app.push, lock) { message ->
                    Toast.makeText(app, message, Toast.LENGTH_SHORT).show()
                }
                else -> error("unknown model")
            } as T
        })
        hosts = provider[HostsModel::class.java]
        browse = provider[BrowseModel::class.java]
        val actions = provider[NotificationActionsModel::class.java]
        val push = pushControls(app, actions)
        ConnectionDiagnostics.observe(lifecycleScope, app.signals, browse)
        consumePairIntent(intent)
        val auth = AndroidDeviceAuth(this)
        setContent { VerdeApp(hosts, browse, lock = AppLockControls(lock, auth), push = push) }
    }
    /**
     * D-14: registers with every paired host whenever Verde is in the foreground or the set of
     * paired hosts changes, and keeps "still running" notices in step with the foreground.
     */
    private fun pushControls(app: VerdeApplication, actions: NotificationActionsModel): PushControls {
        val push = app.push
        val directory = HostsPushDirectory(hosts, app.signals.foreground)
        pushDirectory = directory
        push.registrar.attach(directory)
        lifecycleScope.launch {
            combine(app.signals.foreground, hosts.state.map { state ->
                state.rows.map { it.saved.id to it.view?.auth_state }
            }.distinctUntilChanged()) { visible, _ -> visible }.collect { visible -> if (visible) push.registrar.requestSync() }
        }
        lifecycleScope.launch {
            observeRunningTurns(app.signals.foreground, hosts, push) { app.appLock.state.value.settings.enabled }
        }
        return PushControls(push.registrar.state, push.registrar::setEnabled, push.registrar::markAsked,
            push.notifier::allowed, actions.links, actions::consumeLink)
    }
    // Every ActivityResult launcher (pickers, camera) funnels through here.
    @Deprecated("Deprecated in ComponentActivity")
    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        (application as VerdeApplication).appLock.expectResult()
        @Suppress("DEPRECATION") super.startActivityForResult(intent, requestCode, options)
    }
    override fun onResume() {
        super.onResume()
        (application as VerdeApplication).appLock.resumed()
    }
    override fun onDestroy() {
        pushDirectory?.let { (application as VerdeApplication).push.registrar.detach(it) }
        if (isFinishing) (application as VerdeApplication).appLock.cancelPrompt()
        super.onDestroy()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumePairIntent(intent)
    }
    private fun consumePairIntent(incoming: Intent) {
        val link = takePairLink(incoming)
        intent = Intent(this, MainActivity::class.java)
        link?.let(hosts::receiveLink)
    }
}

/** Routing only: the core validates the complete link after the user's Continue action. */
internal fun takePairLink(incoming: Intent): String? {
    val link = if (incoming.action == Intent.ACTION_VIEW) incoming.dataString else null
    // Do not retain fragment secrets on the Activity Intent across recreation.
    incoming.data = null
    return link
}

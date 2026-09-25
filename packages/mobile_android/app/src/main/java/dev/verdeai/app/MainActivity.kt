package dev.verdeai.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import dev.verdeai.core.Config
import dev.verdeai.core.CoreHost
import dev.verdeai.core.EffectExecutor

class MainActivity : ComponentActivity() {
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val app = application as VerdeApplication
        val cache = ViewCache(app.viewCache)
        // ProcessLifecycleOwner + ConnectivityManager feed every host core (foreground/background/network_changed).
        val provider = ViewModelProvider(this, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                HostsModel::class.java -> HostsModel(app.secureStore, app.signals, cache) { saved ->
                    CoreHost.create(Config(1, saved.id, saved.label, null, null, 1, "", 0uL),
                        EffectExecutor(app.secureStore, saved.id))
                }
                BrowseModel::class.java -> BrowseModel(hosts, cache, app.signals)
                else -> error("unknown model")
            } as T
        })
        hosts = provider[HostsModel::class.java]
        browse = provider[BrowseModel::class.java]
        consumePairIntent(intent)
        setContent { VerdeApp(hosts, browse) }
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

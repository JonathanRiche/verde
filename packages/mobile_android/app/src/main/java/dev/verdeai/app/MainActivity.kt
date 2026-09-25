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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        hosts = ViewModelProvider(this, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = HostsModel(
                (application as VerdeApplication).secureStore) { saved ->
                CoreHost.create(Config(1, saved.id, saved.label, null, null, 1, "", 0uL),
                    EffectExecutor((application as VerdeApplication).secureStore, saved.id))
            } as T
        })[HostsModel::class.java]
        consumePairIntent(intent)
        setContent { HostsScreen(hosts) }
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
    override fun onStart() { super.onStart(); hosts.foreground(true) }
    override fun onStop() { hosts.foreground(false); super.onStop() }
}

/** Routing only: the core validates the complete link after the user's Continue action. */
internal fun takePairLink(incoming: Intent): String? {
    val link = if (incoming.action == Intent.ACTION_VIEW) incoming.dataString else null
    // Do not retain fragment secrets on the Activity Intent across recreation.
    incoming.data = null
    return link
}

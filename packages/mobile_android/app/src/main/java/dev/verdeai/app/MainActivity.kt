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
    private lateinit var pairing: PairingModel
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        pairing = ViewModelProvider(this, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = PairingModel {
                // Stable single-host slot for onboarding; D-04 owns the multi-host catalog.
                val id = "primary"
                CoreHost.create(Config(1, id, "My host", null, null, 1, "", 0uL),
                    EffectExecutor((application as VerdeApplication).secureStore, id))
            } as T
        })[PairingModel::class.java]
        consumePairIntent(intent)
        setContent { PairingScreen(pairing) }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumePairIntent(intent)
    }
    private fun consumePairIntent(incoming: Intent) {
        val link = takePairLink(incoming)
        intent = Intent(this, MainActivity::class.java)
        link?.let(pairing::receiveLink)
    }
    override fun onStart() { super.onStart(); pairing.foreground(true) }
    override fun onStop() { pairing.foreground(false); super.onStop() }
}

/** Routing only: the core validates the complete link after the user's Continue action. */
internal fun takePairLink(incoming: Intent): String? {
    val link = if (incoming.action == Intent.ACTION_VIEW) incoming.dataString else null
    // Do not retain fragment secrets on the Activity Intent across recreation.
    incoming.data = null
    return link
}

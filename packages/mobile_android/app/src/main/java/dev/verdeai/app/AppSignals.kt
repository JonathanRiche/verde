package dev.verdeai.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** `id` is an opaque local network handle; it only tells the core that the route changed. */
internal data class NetworkState(val available: Boolean, val id: String)

/** Process-wide platform signals fed to every host core as lifecycle/network events. */
internal interface AppSignals {
    val foreground: StateFlow<Boolean>
    val network: StateFlow<NetworkState>
}

/** Create on the main thread (Application.onCreate or first Activity use). */
internal class AndroidAppSignals(context: Context) : AppSignals {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val mutableForeground = MutableStateFlow(
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
    override val foreground: StateFlow<Boolean> = mutableForeground.asStateFlow()
    private val mutableNetwork = MutableStateFlow(current())
    override val network: StateFlow<NetworkState> = mutableNetwork.asStateFlow()

    init {
        // ProcessLifecycleOwner delays ON_STOP ~700 ms so rotation does not drop the socket;
        // the core then closes the WS immediately on `background`.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) { mutableForeground.value = true }
            override fun onStop(owner: LifecycleOwner) { mutableForeground.value = false }
        })
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                mutableNetwork.value = state(network, capabilities)
            }
            override fun onLost(network: Network) { mutableNetwork.value = NetworkState(false, "") }
        })
    }

    private fun current(): NetworkState {
        val network = connectivity.activeNetwork ?: return NetworkState(false, "")
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return NetworkState(false, "")
        return state(network, capabilities)
    }

    // A Tailscale VPN is the default network while connected; toggling it changes the handle.
    private fun state(network: Network, capabilities: NetworkCapabilities) = NetworkState(
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET), network.networkHandle.toString())
}

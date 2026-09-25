package dev.verdeai.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** Host catalog, pairing and sign-out. `onUse` leaves for Home after selecting a paired host. */
@Composable
internal fun HostsScreen(model: HostsModel, onUse: () -> Unit = {}) {
    val state by model.state.collectAsState()
    var adding by remember { mutableStateOf(false) }
    var label by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    val pair = state.pairing?.let(model::pairing)
    BackHandler(enabled=pair != null) { model.showPairing(null) }
    Surface(Modifier.fillMaxSize()) {
        if (pair != null) {
            Column(Modifier.safeDrawingPadding()) {
                TextButton(onClick={ model.showPairing(null) }) { Text("Back to hosts") }
                Box(Modifier.weight(1f)) { PairingScreen(pair) }
            }
        } else Column(Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement=Arrangement.spacedBy(16.dp)) {
            Text("Hosts", style=MaterialTheme.typography.headlineLarge)
            state.error?.let { Text(it, color=MaterialTheme.colorScheme.error) }
            when {
                state.loading -> {
                    if (state.busy) CircularProgressIndicator()
                    else Button(onClick=model::load) { Text("Retry loading hosts") }
                }
                state.busy -> CircularProgressIndicator()
                else -> {
                    if (state.rows.isEmpty()) Text("No saved hosts. Add a host to pair with Verde.")
                    state.rows.forEach { row ->
                        val id = row.saved.id
                        val pending = row.busy || row.operation?.state == "pending"
                        val failure = row.operation?.error ?: row.view?.error
                        OutlinedCard(Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp), verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                                    val status = hostStatus(row)
                                    Box(Modifier.size(12.dp).background(hostDotColor(row), CircleShape).semantics { contentDescription=status })
                                    Text(row.saved.label, style=MaterialTheme.typography.titleMedium)
                                    if (state.active == id) Text("Selected")
                                }
                                Text(hostStatus(row))
                                when {
                                    failure?.code == "sign_out_unconfirmed" -> {
                                        Text("Sign out could not be confirmed. Your local pairing is still saved.")
                                        Text("If you remove it anyway, this device may remain listed on the desktop. Revoke it there when you can.")
                                        TextButton(onClick={ model.signOut(id) }, enabled=!pending) { Text("Retry sign out") }
                                        TextButton(onClick={ confirmation=id to true }, enabled=!pending) { Text("Remove from this phone anyway") }
                                    }
                                    failure?.code == "sign_out_delete_failed" -> {
                                        Text("Local data could not be removed. Unlock your phone and retry.")
                                        TextButton(onClick={ model.retry(id) }, enabled=!pending) { Text("Retry removal") }
                                    }
                                    row.view?.auth_state == "signed_out" -> {
                                        Text("Local credential and host trust have been removed.")
                                        TextButton(onClick={ model.remove(id) }) { Text("Remove from hosts") }
                                        TextButton(onClick={ model.showPairing(id) }) { Text("Pair again") }
                                    }
                                    else -> {
                                        if (row.view?.auth_state == "paired" && row.view.trust_proposal == null) {
                                            TextButton(onClick={ model.select(id); onUse() }, enabled=!pending && !row.fatal) { Text("Use ${row.saved.label}") }
                                        } else if (row.view?.auth_state != "signing_out") {
                                            TextButton(onClick={ model.showPairing(id) }, enabled=!pending && !row.fatal) { Text("Pair / review host") }
                                        }
                                        if (failure?.retryable == true) TextButton(onClick={ model.retry(id) }, enabled=!pending) { Text("Retry connection") }
                                    }
                                }
                                if (pending) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("Finishing host action…") }
                                if (row.view != null && row.view.auth_state !in listOf("loading", "signed_out", "signing_out")) {
                                    TextButton(onClick={ confirmation=id to false }, enabled=!pending && !row.fatal) { Text("Sign out of host") }
                                }
                            }
                        }
                    }
                    Button(onClick={ adding=true }) { Text("Add host") }
                }
            }
        }
    }
    if (adding) AlertDialog(onDismissRequest={ adding=false }, title={ Text("Add host") },
        text={ OutlinedTextField(label, { label=it.take(128) }, label={ Text("Host name") }, singleLine=true) },
        confirmButton={ TextButton(onClick={ model.add(label); label=""; adding=false }) { Text("Continue") } },
        dismissButton={ TextButton(onClick={ adding=false }) { Text("Cancel") } })
    confirmation?.let { (id, forget) ->
        val name = state.rows.find { it.saved.id == id }?.saved?.label ?: "host"
        AlertDialog(onDismissRequest={ confirmation=null },
            title={ Text(if (forget) "Remove $name from this phone?" else "Sign out of $name?") },
            text={ Text(if (forget) "This removes the local credential and host trust. This device may remain listed on the desktop until you revoke it there."
                else "Verde will revoke this phone's access to this host and remove its local credential and trust. Other hosts stay paired.") },
            confirmButton={ TextButton(onClick={ confirmation=null; model.signOut(id, forget) }) { Text(if (forget) "Remove anyway" else "Sign out") } },
            dismissButton={ TextButton(onClick={ confirmation=null }) { Text("Cancel") } })
    }
}

@Composable
internal fun hostDotColor(row: HostRow): Color {
    val status = hostStatus(row)
    val colors = MaterialTheme.colorScheme
    return when {
        status == "Connected" -> colors.primary
        row.fatal || row.view?.auth_state == "repair_required" || status.startsWith("Unreachable") -> colors.error
        else -> colors.outline
    }
}

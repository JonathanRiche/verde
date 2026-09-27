package dev.verdeai.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Add
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** Host catalog, pairing and sign-out. `onUse` leaves for Home after selecting a paired host. */
@Composable
internal fun HostsScreen(model: HostsModel, onUse: () -> Unit = {}, onSecurity: (() -> Unit)? = null) {
    val state by model.state.collectAsState()
    var adding by rememberSaveable { mutableStateOf(false) }
    var label by rememberSaveable { mutableStateOf("") }
    var confirmation by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    var renaming by rememberSaveable { mutableStateOf<String?>(null) }
    var renameLabel by rememberSaveable { mutableStateOf("") }
    val pair = state.pairing?.let(model::pairing)
    BackHandler(enabled=pair != null) { model.showPairing(null) }
    Surface(Modifier.fillMaxSize()) {
        if (pair != null) {
            Column(Modifier.safeDrawingPadding()) {
                TextButton(onClick={ model.showPairing(null) }) { Text("Back to hosts") }
                Box(Modifier.weight(1f)) { PairingScreen(pair) }
            }
        } else Column(Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement=Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement=Arrangement.spacedBy(4.dp)) {
                Text("Hosts", style=MaterialTheme.typography.titleLarge)
                Text("Your machines, wherever you work.", style=MaterialTheme.typography.bodyMedium,
                    color=VerdeColors.Muted)
            }
            if (state.busy && !state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.error?.let { Text(it, color=MaterialTheme.colorScheme.error) }
            when {
                state.loading -> {
                    if (state.busy) CircularProgressIndicator()
                    else Button(shape = MaterialTheme.shapes.small, onClick=model::load) { Text("Retry loading hosts") }
                }
                else -> {
                    if (state.rows.isEmpty()) Text("No saved hosts. Add a host to pair with Verde.")
                    state.rows.forEach { row ->
                        val id = row.saved.id
                        val pending = row.busy || row.operation?.state == "pending"
                        val failure = row.operation?.error ?: row.view?.error
                        OutlinedCard(Modifier.fillMaxWidth(), colors = CardDefaults.outlinedCardColors(containerColor = VerdeColors.Panel),
                            border = androidx.compose.foundation.BorderStroke(1.dp, if (state.active == id) VerdeColors.Accent else VerdeColors.Border)) {
                            Column(Modifier.padding(16.dp), verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                HostHeading(row, selected=state.active == id, enabled=!state.busy,
                                    onRename={ renameLabel=row.saved.label; renaming=id },
                                    onSignOut=if (row.view != null && row.view.auth_state !in listOf("loading", "signed_out", "signing_out") && !pending && !row.fatal)
                                        { { confirmation=id to false } } else null)
                                when {
                                    failure?.code == "sign_out_unconfirmed" -> {
                                        Text("Sign out could not be confirmed. Your local pairing is still saved.")
                                        Text("If you remove it anyway, this device may remain listed on the desktop. Revoke it there when you can.")
                                        TextButton(onClick={ model.signOut(id) }, enabled=!state.busy && !pending) { Text("Retry sign out") }
                                        TextButton(onClick={ confirmation=id to true }, enabled=!state.busy && !pending) { Text("Remove from this phone anyway") }
                                    }
                                    failure?.code == "sign_out_delete_failed" -> {
                                        Text("Local data could not be removed. Unlock your phone and retry.")
                                        TextButton(onClick={ model.retry(id) }, enabled=!state.busy && !pending) { Text("Retry removal") }
                                    }
                                    row.view?.auth_state == "signed_out" -> {
                                        Text("Local credential and host trust have been removed.")
                                        TextButton(onClick={ model.remove(id) }) { Text("Remove from hosts") }
                                        TextButton(onClick={ model.showPairing(id) }) { Text("Pair again") }
                                    }
                                    else -> {
                                        if (row.view?.auth_state == "paired" && row.view.trust_proposal == null) {
                                            Button(modifier=Modifier.fillMaxWidth(), shape=MaterialTheme.shapes.small, onClick={ model.select(id, onUse) }, enabled=!state.busy && !pending && !row.fatal) { Text("Use ${row.saved.label}", maxLines=1, overflow=TextOverflow.Ellipsis) }
                                        } else if (row.view?.auth_state != "signing_out") {
                                            TextButton(onClick={ model.showPairing(id) }, enabled=!state.busy && !pending && !row.fatal) { Text("Pair / review host") }
                                        }
                                        if (failure?.retryable == true) TextButton(onClick={ model.retry(id) }, enabled=!state.busy && !pending) { Text("Retry connection") }
                                    }
                                }
                                if (pending) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("Finishing host action…") }
                            }
                        }
                    }
                    OutlinedButton(modifier=Modifier.fillMaxWidth(), shape=MaterialTheme.shapes.small,
                        enabled=!state.busy, onClick={ adding=true }) {
                        Icon(Icons.Filled.Add, contentDescription=null, modifier=Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Add host")
                    }
                }
            }
            onSecurity?.let { open -> TextButton(modifier=Modifier.fillMaxWidth(), onClick=open) { Text("App lock & privacy") } }
        }
    }
    if (adding) AlertDialog(onDismissRequest={ adding=false }, title={ Text("Add host") },
        text={ OutlinedTextField(label, { label=it.take(128) }, label={ Text("Host name") }, singleLine=true) },
        confirmButton={ TextButton(onClick={ model.add(label); label=""; adding=false }) { Text("Continue") } },
        dismissButton={ TextButton(onClick={ adding=false }) { Text("Cancel") } })
    renaming?.let { id ->
        AlertDialog(onDismissRequest={ if (!state.busy) renaming=null }, title={ Text("Rename machine") },
            text={ Column(verticalArrangement=Arrangement.spacedBy(12.dp)) {
                Text("Choose a name you recognize. This name is saved on this phone.",
                    style=MaterialTheme.typography.bodyMedium, color=VerdeColors.Muted)
                OutlinedTextField(renameLabel, { renameLabel=it.take(128) }, label={ Text("Machine name") },
                    singleLine=true, enabled=!state.busy, modifier=Modifier.fillMaxWidth())
                state.error?.let { Text(it, color=MaterialTheme.colorScheme.error) }
            } },
            confirmButton={ TextButton(enabled=renameLabel.isNotBlank() && !state.busy,
                onClick={ model.rename(id, renameLabel) { renaming=null } }) { Text(if (state.busy) "Saving…" else "Save") } },
            dismissButton={ TextButton(enabled=!state.busy, onClick={ renaming=null }) { Text("Cancel") } })
    }
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

/** Keep destructive actions out of the everyday machine-switching flow. */
@Composable
private fun HostHeading(row: HostRow, selected: Boolean, enabled: Boolean,
    onRename: () -> Unit, onSignOut: (() -> Unit)?) {
    var menu by remember(row.saved.id) { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment=Alignment.CenterVertically,
        horizontalArrangement=Arrangement.spacedBy(10.dp)) {
        Surface(color=if (selected) VerdeColors.AccentWash else VerdeColors.PanelAlt,
            shape=MaterialTheme.shapes.small) {
            Icon(painterResource(R.drawable.host_machine), contentDescription=null,
                tint=if (selected) VerdeColors.Accent else VerdeColors.Muted,
                modifier=Modifier.padding(10.dp).size(24.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement=Arrangement.spacedBy(4.dp)) {
            Text(row.saved.label, style=MaterialTheme.typography.titleMedium, maxLines=2,
                overflow=TextOverflow.Ellipsis)
            Row(verticalAlignment=Alignment.CenterVertically, horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(7.dp).background(hostDotColor(row), CircleShape))
                Text(hostStatus(row), style=MaterialTheme.typography.bodySmall, color=VerdeColors.Muted,
                    modifier=Modifier.weight(1f))
            }
            if (selected) Text("Selected", color=VerdeColors.Accent, style=MaterialTheme.typography.labelSmall)
        }
        Box {
            IconButton(onClick={ menu=true }, enabled=enabled) {
                Icon(Icons.Filled.MoreVert, contentDescription="Actions for ${row.saved.label}", modifier=Modifier.rotate(90f))
            }
            DropdownMenu(expanded=menu, onDismissRequest={ menu=false }) {
                DropdownMenuItem(text={ Text("Rename machine") }, leadingIcon={ Icon(Icons.Filled.Edit, contentDescription=null) },
                    onClick={ menu=false; onRename() })
                onSignOut?.let { signOut ->
                    HorizontalDivider()
                    DropdownMenuItem(text={ Text("Sign out of host", color=VerdeColors.Danger) },
                        onClick={ menu=false; signOut() })
                }
            }
        }
    }
}

package dev.verdeai.app

import android.Manifest
import android.content.ClipboardManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@Composable
internal fun PairingScreen(model: PairingModel) {
    val state by model.state.collectAsState()
    var manual by remember { mutableStateOf(false) }
    var scanning by remember { mutableStateOf(false) }
    LaunchedEffect(model.link) { if (model.link.isNotEmpty()) manual=false }
    val clipboard = LocalContext.current.getSystemService(ClipboardManager::class.java)
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        scanning = granted
        if (!granted) model.notice("Camera permission was denied. Paste a pairing link or enter it manually.")
    }
    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.safeDrawingPadding().imePadding().verticalScroll(rememberScrollState())
                .padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(if (state.complete) "Home" else "Pair with Verde", style=MaterialTheme.typography.headlineLarge)
                state.notice?.let { Text(it, color=MaterialTheme.colorScheme.error) }
                when {
                    state.fatal -> Text("The connection could not start. Close and reopen Verde to try again.")
                    state.host?.update_required == true -> Text("Update Verde on your phone and host to continue.")
                    state.complete -> {
                        Text("Paired securely")
                        Text("Your phone is securely paired with this host.")
                        state.error?.let { Text(pairingError(it)) }
                        if (state.error?.retryable == true) Button(onClick=model::retry, enabled=!state.busy) { Text("Retry") }
                    }
                    else -> {
                        Text("Connect Tailscale on your phone, then create a pairing link in Verde on your host.")
                        state.error?.let { Text(pairingError(it), color=MaterialTheme.colorScheme.error) }
                        state.host?.trust_proposal?.let { proposal ->
                            Text(if (state.host?.runtime_id != null) "Review changed host identity" else "Confirm your host",
                                style=MaterialTheme.typography.titleLarge)
                            Text(proposal.origin)
                            proposal.runtime_id?.let { Text("Runtime: $it") }
                            Text("TLS key (SHA-256): ${proposal.spki_sha256}")
                            Text("Only trust this host if you recognize it. If its identity changed unexpectedly, verify it with the host owner first.")
                            Button(onClick={ model.trust(proposal.id, true) }, enabled=!state.busy) { Text("Trust and pair") }
                            OutlinedButton(onClick={ model.trust(proposal.id, false) }, enabled=!state.busy) { Text("Do not trust") }
                        }
                        if (state.error?.retryable == true) {
                            Button(onClick=model::retry, enabled=!state.busy) { Text("Retry") }
                        }
                        if (state.canEnter) {
                            OutlinedTextField(value=model.deviceLabel, onValueChange={ model.deviceLabel=it.take(128) },
                                label={ Text("Device label") }, singleLine=true, modifier=Modifier.fillMaxWidth())
                            if (!manual) {
                                OutlinedTextField(value=model.link, onValueChange={ model.link=it.take(8192) },
                                    label={ Text("Pairing link") }, singleLine=true,
                                    visualTransformation=PasswordVisualTransformation(),
                                    keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Password), modifier=Modifier.fillMaxWidth())
                                Button(onClick={ model.pair() }, enabled=model.link.isNotBlank()) { Text("Continue") }
                                OutlinedButton(onClick={
                                    clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()?.let(model::receiveLink)
                                        ?: model.notice("No pairing link is on the clipboard.")
                                }) { Text("Paste link") }
                                OutlinedButton(onClick={ permission.launch(Manifest.permission.CAMERA) }) { Text("Scan QR code") }
                            } else {
                                OutlinedTextField(model.manualHost, { model.manualHost=it.take(4096) }, label={ Text("Host HTTPS address") },
                                    singleLine=true, modifier=Modifier.fillMaxWidth())
                                OutlinedTextField(model.grant, { model.grant=it.take(128) }, label={ Text("Grant ID") },
                                    singleLine=true, modifier=Modifier.fillMaxWidth())
                                OutlinedTextField(model.code, { model.code=it.take(256) }, label={ Text("Pairing code") },
                                    visualTransformation=PasswordVisualTransformation(), keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Password),
                                    singleLine=true, modifier=Modifier.fillMaxWidth())
                                Button(onClick={ model.pair(manual=true) }, enabled=model.manualHost.isNotBlank() && model.grant.isNotBlank() && model.code.isNotBlank()) { Text("Continue") }
                            }
                            TextButton(onClick={ manual=!manual }) { Text(if (manual) "Use a link instead" else "Enter manually") }
                        } else if (state.host?.trust_proposal == null && state.error == null) {
                            CircularProgressIndicator()
                            Text(if (state.operation?.state == "pending") "Connecting and securely saving pairing…" else "Loading secure host profile…")
                        }
                    }
                }
            }
        }
        if (scanning && state.canEnter) QrScanner(onLink={ scanning=false; manual=false; model.receiveLink(it) },
            onClose={ scanning=false }, onError={ scanning=false; model.notice("Camera scanning is unavailable. Paste a pairing link or enter it manually.") })
    }
}

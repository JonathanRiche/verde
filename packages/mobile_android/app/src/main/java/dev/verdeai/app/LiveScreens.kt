package dev.verdeai.app

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatChoice
import dev.verdeai.core.VoiceProvider

internal const val LIVE_PANEL = "companion-live"

/** The live conversation in the companion sheet: orb, captions, provider, mute and end. */
@Composable
internal fun LivePanel(live: LiveVoice, name: String) {
    val ui by live.ui.collectAsState()
    val input by live.inputLevel.collectAsState()
    val output by live.outputLevel.collectAsState()
    Column(Modifier.fillMaxSize().padding(16.dp).testTag(LIVE_PANEL), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(when (ui.phase) {
            LivePhase.Connecting -> "Connecting…"
            LivePhase.Reconnecting -> "Reconnecting…"
            LivePhase.Live -> if (ui.muted) "Live · mic muted" else "Live with $name"
            LivePhase.Failed -> "Live voice stopped"
            LivePhase.Off -> "Live voice"
        }, style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        if (ui.provider.isNotEmpty()) Text("${providerLabel(ui.provider)} · ${ui.voice}", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
        LiveOrb(input, output, active = ui.phase == LivePhase.Live, modifier = Modifier.size(160.dp))
        Column(Modifier.weight(1f).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.Bottom)) {
            ui.captions.forEach { caption ->
                Text(caption.text, Modifier.fillMaxWidth(), textAlign = if (caption.user) TextAlign.End else TextAlign.Start,
                    color = if (caption.user) VerdeColors.Muted else VerdeColors.Text, style = MaterialTheme.typography.bodyMedium,
                    maxLines = 4, overflow = TextOverflow.Ellipsis)
            }
        }
        ui.error?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (ui.phase == LivePhase.Failed) {
                OutlinedButton(onClick = live::dismissError) { Text("Close") }
                Button(onClick = live::start) { Text("Try again") }
            } else {
                OutlinedButton(onClick = live::toggleMute, enabled = ui.phase == LivePhase.Live,
                    modifier = Modifier.semantics { contentDescription = if (ui.muted) "Unmute microphone" else "Mute microphone" }) {
                    Text(if (ui.muted) "Unmute" else "Mute")
                }
                Button(onClick = live::stop, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("End") }
            }
        }
    }
}

/** A soft orb: its core follows the companion's voice, its ring the user's. */
@Composable
internal fun LiveOrb(input: Float, output: Float, active: Boolean, modifier: Modifier = Modifier) {
    val inner by animateFloatAsState(if (active) .55f + .35f * output else .5f, label = "Live orb voice")
    val ring by animateFloatAsState(if (active) .72f + .25f * input else .7f, label = "Live orb mic")
    val accent = VerdeColors.Accent
    val wash = VerdeColors.AccentWash
    Canvas(modifier.semantics { contentDescription = if (active) "Live conversation" else "Live voice idle" }) {
        val radius = size.minDimension / 2f
        val center = Offset(size.width / 2f, size.height / 2f)
        drawCircle(wash, radius * ring, center)
        drawCircle(accent.copy(alpha = .35f + .5f * input), radius * ring, center, style = Stroke(width = 3.dp.toPx()))
        drawCircle(accent.copy(alpha = .75f), radius * inner, center)
    }
}

internal fun providerLabel(id: String): String = when (id) {
    "xai" -> "xAI Grok"
    "openai" -> "OpenAI"
    "gemini" -> "Google Gemini"
    else -> id
}

/** Companion settings → Live voice: providers (keys stay on the desktop), voice, model and default. */
@Composable
internal fun LiveVoiceSettings(live: LiveVoice) {
    val view by live.voice.collectAsState()
    LaunchedEffect(live) { live.refreshProviders() }
    VerdeSection("Live voice")
    Text("Real-time conversation uses your own API key from xAI, OpenAI or Google. The key is sent to your desktop and stored only there; " +
        "this phone gets a short-lived token per conversation. ChatGPT, SuperGrok and Gemini subscriptions don't include API access.",
        Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
    val current = view
    when {
        current == null || (!current.loaded && current.loading) -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
        !current.supported -> Text("Update Verde on the computer to use live voice.", Modifier.padding(16.dp))
        else -> current.providers.forEach { provider ->
            key(provider.id) { ProviderRow(live, provider, isDefault = current.default_provider == provider.id) }
        }
    }
}

@Composable
private fun ProviderRow(live: LiveVoice, provider: VoiceProvider, isDefault: Boolean) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    var key by remember { mutableStateOf("") }
    var model by rememberSaveable(provider.model) { mutableStateOf(provider.model) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    fun save(apiKey: String?, voice: String? = null, makeDefault: Boolean? = null, newModel: String? = null) {
        busy = true; message = null
        live.configure(provider.id, apiKey, newModel, voice, makeDefault) { error ->
            busy = false
            message = error ?: "Saved on your desktop."
            if (error == null) key = ""
        }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
        .background(VerdeColors.PanelAlt, RoundedCornerShape(10.dp)).border(1.dp, VerdeColors.Border, RoundedCornerShape(10.dp))) {
        Row(Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(provider.label.ifBlank { providerLabel(provider.id) } + if (isDefault) " · default" else "", style = MaterialTheme.typography.titleSmall)
                Text(when (provider.key_source) {
                    "verde" -> "API key saved on your desktop"
                    "environment" -> "API key from the desktop's environment"
                    else -> "No API key"
                }, style = MaterialTheme.typography.bodySmall, color = if (provider.configured) VerdeColors.Accent else VerdeColors.Muted)
            }
            Box(Modifier.size(10.dp).background(if (provider.configured) VerdeColors.Accent else VerdeColors.Subtle, CircleShape))
        }
        if (expanded) Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(key, { key = it.trim() }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text(if (provider.configured) "Replace API key" else "Add API key") },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { save(key) }, enabled = !busy && key.isNotEmpty()) { Text("Save key") }
                if (provider.key_source == "verde") TextButton(onClick = { save("") }, enabled = !busy) { Text("Remove key") }
            }
            if (provider.voices.isNotEmpty()) {
                val choices = provider.voices.map { ChatChoice(it, it) }
                Picker("Voice", provider.voice.ifEmpty { "Default" }, choices, enabled = !busy) { save(null, voice = it) }
            }
            OutlinedTextField(model, { model = it.trim() }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text("Model (advanced)") })
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (model != provider.model && model.isNotEmpty()) TextButton(onClick = { save(null, newModel = model) }, enabled = !busy) { Text("Save model") }
                if (!isDefault) TextButton(onClick = { save(null, makeDefault = true) }, enabled = !busy && provider.configured) { Text("Make default") }
            }
            message?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted) }
        }
    }
}

/** Header button that starts or ends Live. */
@Composable
internal fun LiveButton(active: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.semantics { contentDescription = if (active) "End live voice" else "Start live voice" }) {
        Icon(painterResource(R.drawable.ic_waveform), contentDescription = null, tint = if (active) VerdeColors.Accent else VerdeColors.Text)
    }
}

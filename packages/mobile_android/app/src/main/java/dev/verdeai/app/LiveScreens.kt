package dev.verdeai.app

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
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
internal const val LIVE_PILL = "companion-live-pill"
internal const val LIVE_PILL_CAPTIONS = "companion-live-pill-captions"

/**
 * The full Live view in the companion sheet: orb, big captions, provider, mute and end. [onCollapse]
 * (the chevron) goes back to the floating pill.
 */
@Composable
internal fun LivePanel(live: LiveVoice, name: String, onCollapse: (() -> Unit)? = null) {
    val ui by live.ui.collectAsState()
    val input by live.inputLevel.collectAsState()
    val output by live.outputLevel.collectAsState()
    Column(Modifier.fillMaxSize().padding(16.dp).testTag(LIVE_PANEL), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (onCollapse != null) Row(Modifier.fillMaxWidth()) {
            IconButton(onClick = onCollapse, modifier = Modifier.semantics { contentDescription = "Show the conversation" }) {
                Icon(painterResource(R.drawable.ic_expand_more), contentDescription = null, tint = VerdeColors.Muted)
            }
        }
        Text(when (ui.phase) {
            LivePhase.Connecting -> "Connecting…"
            LivePhase.Reconnecting -> "Reconnecting…"
            LivePhase.Live -> if (ui.muted) "Live · mic muted" else "Live with $name"
            LivePhase.Failed -> "Live voice stopped"
            LivePhase.Off -> "Live voice"
        }, style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        if (ui.provider.isNotEmpty()) Text("${providerLabel(ui.provider)} · ${ui.voice}", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
        LiveOrb(input, output, active = ui.phase == LivePhase.Live, modifier = Modifier.size(if (onCollapse != null) 120.dp else 160.dp))
        // Big captions: what you and the companion are saying, newest at the bottom.
        val scroll = rememberScrollState()
        LaunchedEffect(ui.captions) { scroll.animateScrollTo(scroll.maxValue) }
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll), verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.Bottom)) {
            ui.captions.forEach { caption ->
                Text(caption.text, Modifier.fillMaxWidth(), textAlign = if (caption.user) TextAlign.End else TextAlign.Start,
                    color = if (caption.user) VerdeColors.Muted else VerdeColors.Text,
                    style = if (caption.user) MaterialTheme.typography.bodyLarge else MaterialTheme.typography.titleLarge)
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

/**
 * The floating call bar over the companion conversation (desktop and Grok style): the companion,
 * dots that rise with whoever is talking, then settings, captions, mute and a red end. Tapping the
 * companion or the dots opens the full view. Stateless so tests can drive it.
 */
@Composable
internal fun LivePill(ui: LiveUi, input: Float, output: Float, character: CompanionCharacter, name: String, captionsShown: Boolean,
    onExpand: () -> Unit, onSettings: () -> Unit, onCaptions: () -> Unit, onMute: () -> Unit, onEnd: () -> Unit,
    modifier: Modifier = Modifier) {
    val speaking = ui.phase == LivePhase.Live && output > .04f
    Column(modifier.widthIn(max = 420.dp).padding(horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth().shadow(8.dp, RoundedCornerShape(50)).background(VerdeColors.PanelAlt, RoundedCornerShape(50))
            .border(1.dp, VerdeColors.Border, RoundedCornerShape(50)).padding(6.dp).testTag(LIVE_PILL),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.weight(1f).clickable(onClickLabel = "Open the full Live view", onClick = onExpand),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(40.dp).background(VerdeColors.AccentWash, CircleShape)
                    .border(1.dp, if (speaking) VerdeColors.Accent else VerdeColors.Border, CircleShape), contentAlignment = Alignment.Center) {
                    CompanionAvatar(character, CompanionPose.Idle, size = 30.dp, description = name)
                }
                LiveDots(ui, if (speaking) output else if (ui.muted) 0f else input, speaking, Modifier.weight(1f).height(40.dp)
                    .semantics { liveRegion = LiveRegionMode.Polite; contentDescription = liveStatusLabel(ui, speaking, name) })
            }
            PillButton(R.drawable.ic_settings, "Voice settings", PillTone.Plain, onSettings)
            PillButton(R.drawable.ic_closed_caption, if (captionsShown) "Hide captions" else "Show captions",
                if (captionsShown) PillTone.Selected else PillTone.Plain, onCaptions)
            PillButton(if (ui.muted) R.drawable.ic_mic_off else R.drawable.ic_mic, if (ui.muted) "Unmute microphone" else "Mute microphone",
                if (ui.muted) PillTone.Warning else PillTone.Plain, onMute, enabled = ui.phase == LivePhase.Live)
            PillButton(R.drawable.ic_close, "End live voice", PillTone.Danger, onEnd)
        }
        if (captionsShown) LiveCaptionsCard(ui, name, Modifier.fillMaxWidth().clickable(onClickLabel = "Open the full Live view", onClick = onExpand))
    }
}

internal fun liveStatusLabel(ui: LiveUi, speaking: Boolean, name: String): String = when (ui.phase) {
    LivePhase.Connecting -> "Connecting…"
    LivePhase.Reconnecting -> "Reconnecting…"
    LivePhase.Live -> if (ui.muted) "Muted" else if (speaking) "$name is speaking" else "Listening"
    LivePhase.Failed -> "Live voice stopped"
    LivePhase.Off -> "Live voice"
}

private enum class PillTone { Plain, Selected, Warning, Danger }

@Composable
private fun PillButton(icon: Int, label: String, tone: PillTone, onClick: () -> Unit, enabled: Boolean = true) {
    val (fill, ring, tint) = when (tone) {
        PillTone.Plain -> Triple(VerdeColors.Panel, VerdeColors.Border, VerdeColors.Muted)
        PillTone.Selected -> Triple(VerdeColors.AccentWash, VerdeColors.Accent, VerdeColors.Accent)
        PillTone.Warning -> Triple(VerdeColors.DangerPanel, VerdeColors.Danger, VerdeColors.Danger)
        PillTone.Danger -> Triple(VerdeColors.Danger, VerdeColors.Danger, Color.White)
    }
    Box(Modifier.size(40.dp).background(fill, CircleShape).border(1.dp, ring, CircleShape)
        .clickable(enabled = enabled, onClickLabel = label, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), contentDescription = null, tint = if (enabled) tint else tint.copy(alpha = .4f), modifier = Modifier.size(20.dp))
    }
}

/** A row of dots that rise into a wave with the loudness of whoever is talking; one travelling dot while connecting. */
@Composable
private fun LiveDots(ui: LiveUi, level: Float, speaking: Boolean, modifier: Modifier) {
    val transition = rememberInfiniteTransition(label = "Live dots")
    val phase by transition.animateFloat(0f, (2 * Math.PI).toFloat(), infiniteRepeatable(tween(1400, easing = LinearEasing), RepeatMode.Restart), label = "ripple")
    val connecting = ui.phase == LivePhase.Connecting || ui.phase == LivePhase.Reconnecting
    val tint = when {
        speaking -> VerdeColors.Accent
        ui.phase == LivePhase.Live && !ui.muted -> VerdeColors.Muted
        else -> VerdeColors.Subtle
    }
    val accent = VerdeColors.Accent
    val subtle = VerdeColors.Subtle
    val clamped = level.coerceIn(0f, 1f)
    Canvas(modifier) {
        val dot = 4.dp.toPx()
        val step = dot + 4.dp.toPx()
        val count = maxOf(((size.width + step - dot) / step).toInt(), 1)
        val span = count * step - (step - dot)
        val x0 = (size.width - span) / 2f
        val mid = size.height / 2f
        val travelling = ((phase / (2 * Math.PI)) * count).toInt().coerceIn(0, count - 1)
        for (i in 0 until count) {
            val t = if (count == 1) .5f else i / (count - 1f)
            val envelope = 1f - kotlin.math.abs(t - .5f) * 1.4f
            val ripple = .65f + .35f * kotlin.math.sin(i * 1.9f + phase)
            val h = if (connecting) dot else dot + clamped * envelope * ripple * size.height * .6f
            val color = if (connecting) (if (i == travelling) accent else subtle) else tint
            drawRoundRect(color, Offset(x0 + i * step, mid - h / 2f), Size(dot, h), CornerRadius(dot / 2f))
        }
    }
}

/** Under the pill: the newest two spoken lines. */
@Composable
private fun LiveCaptionsCard(ui: LiveUi, name: String, modifier: Modifier) {
    Column(modifier.background(VerdeColors.PanelAlt, RoundedCornerShape(14.dp)).border(1.dp, VerdeColors.Border, RoundedCornerShape(14.dp))
        .padding(horizontal = 14.dp, vertical = 10.dp).testTag(LIVE_PILL_CAPTIONS), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val lines = ui.captions.takeLast(2)
        if (lines.isEmpty()) {
            Text(if (ui.phase == LivePhase.Live) (if (ui.muted) "Muted. Unmute to talk." else "Listening. Speak naturally.") else liveStatusLabel(ui, false, name),
                style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
        }
        lines.forEach { caption ->
            Text("${if (caption.user) "You" else name}: ${caption.text}", style = MaterialTheme.typography.bodySmall,
                color = if (caption.user) VerdeColors.Muted else VerdeColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
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
        !current.supported -> Text("Update verde on the computer to use live voice.", Modifier.padding(16.dp))
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

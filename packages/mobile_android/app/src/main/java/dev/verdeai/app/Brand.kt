package dev.verdeai.app

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Unmodified artwork shared with the web client, kept at its intrinsic density. */
@Composable
internal fun VerdeWordmark() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Image(painterResource(R.drawable.verde_logo), contentDescription = null,
            colorFilter = ColorFilter.tint(VerdeColors.Accent), modifier = Modifier.size(28.dp))
        Text("Verde", style = MaterialTheme.typography.headlineMedium)
    }
}

@Composable
internal fun ProviderGlyph(provider: String?, modifier: Modifier = Modifier.size(18.dp)) {
    val asset = when (provider?.lowercase()) {
        "codex", "openai" -> R.drawable.provider_openai
        "claude" -> R.drawable.provider_claude
        "opencode" -> R.drawable.provider_opencode
        "cursor" -> R.drawable.provider_cursor
        "grok" -> R.drawable.provider_grok
        "pi" -> R.drawable.provider_pi
        "fx" -> R.drawable.provider_fx
        "amp" -> R.drawable.provider_amp
        "muse" -> R.drawable.provider_muse
        else -> null
    }
    if (asset != null) Image(painterResource(asset), contentDescription = null, modifier = modifier)
    else Canvas(modifier) {
        val path = Path().apply {
            moveTo(size.width * .25f, size.height * .29f)
            lineTo(size.width * .75f, size.height * .29f)
            lineTo(size.width * .75f, size.height * .625f)
            lineTo(size.width * .375f, size.height * .625f)
            lineTo(size.width * .25f, size.height * .725f)
            close()
        }
        drawPath(path, VerdeColors.Subtle, style = Stroke(1.3.dp.toPx()))
    }
}

internal fun activeStatus(status: String) = status in setOf("working", "running", "accepted", "waiting")

/** Compose's infinite transition honors the platform animator duration scale. */
@Composable
private fun pulseAlpha(active: Boolean, minimum: Float, periodMs: Int): State<Float> {
    if (!active) return rememberUpdatedState(1f)
    val transition = rememberInfiniteTransition(label = "Verde status pulse")
    return transition.animateFloat(initialValue = minimum, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(periodMs / 2, easing = CubicBezierEasing(.42f, 0f, .58f, 1f)), RepeatMode.Reverse),
        label = "Status opacity")
}

@Composable
internal fun StatusPip(color: Color = VerdeColors.Accent, description: String? = null,
    active: Boolean = false, size: Dp = 6.dp, command: Boolean = false) {
    val opacity = pulseAlpha(active, if (command) .45f else .35f, if (command) 1400 else 1600)
    Box(Modifier.size(size).graphicsLayer { alpha = opacity.value }.background(color, CircleShape)
        .semantics { if (description != null) contentDescription = description })
}

/** Web's mobile yellow stop circle inside an accessible 48dp touch target. */
@Composable
internal fun StopControl(stopping: Boolean, enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val opacity = pulseAlpha(!stopping && enabled, .74f, 1400)
    val label = if (stopping) "Stopping…" else "Stop"
    IconButton(onClick = onClick, enabled = enabled, modifier = modifier.semantics { text = AnnotatedString(label) }) {
        Box(Modifier.size(44.dp).graphicsLayer { alpha = if (enabled) opacity.value else .38f }
            .background(VerdeColors.Warning, CircleShape), contentAlignment = Alignment.Center) {
            Box(Modifier.size(9.dp).background(VerdeColors.Background, RoundedCornerShape(2.dp)))
        }
    }
}

/** Web's mobile send circle, with a 48dp Android touch target. */
@Composable
internal fun SendControl(label: String, enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(onClick = onClick, enabled = enabled,
        modifier = modifier.semantics { contentDescription = label }) {
        Box(Modifier.size(44.dp).graphicsLayer { alpha = if (enabled) 1f else .35f }
            .background(VerdeColors.Accent, CircleShape), contentAlignment = Alignment.Center) {
            Icon(painterResource(R.drawable.composer_send), contentDescription = null,
                tint = Color(0xFF06210F), modifier = Modifier.size(16.dp))
        }
    }
}

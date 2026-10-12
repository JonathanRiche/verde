package dev.verdeai.app

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/*
 * Companion characters, ported from desktop `ui/companion.zig` (`renderSprout`/`renderMoss`/
 * `renderVireo`): rounded rects, triangles and short strokes in a 46-unit box, colors derived from
 * the active theme. Poses come from real state only; working adds a gentle bob.
 */

/** The theme roles the desktop character palettes derive from. */
internal data class CharacterTheme(
    val background: Color, val text: Color, val subtle: Color, val accent: Color,
    val border: Color, val panelMuted: Color, val warning: Color, val danger: Color,
)

internal fun characterTheme(p: VerdePalette) = CharacterTheme(p.Background, p.Text, p.Subtle, p.Accent, p.Border, p.PanelMuted, p.Warning, p.Danger)

internal fun mixColor(from: Color, to: Color, amount: Float): Color {
    val t = amount.coerceIn(0f, 1f)
    return Color(from.red + (to.red - from.red) * t, from.green + (to.green - from.green) * t,
        from.blue + (to.blue - from.blue) * t, from.alpha + (to.alpha - from.alpha) * t)
}
internal fun characterLuma(c: Color) = c.red * .2126f + c.green * .7152f + c.blue * .0722f
private fun lumaDistance(a: Color, b: Color) = kotlin.math.abs(characterLuma(a) - characterLuma(b))
private fun withAlpha(c: Color, alpha: Int) = c.copy(alpha = alpha / 255f)
private fun shift(c: Color, amount: Float) = Color((c.red + amount).coerceIn(0f, 1f), (c.green + amount).coerceIn(0f, 1f), (c.blue + amount).coerceIn(0f, 1f), c.alpha)
/** Raise toward the text pole: darken on light themes, lighten on dark ones. */
private fun raiseAgainst(c: Color, amount: Float, backing: Color, foreground: Color) =
    if (characterLuma(backing) > characterLuma(foreground)) shift(c, -amount) else shift(c, amount)

/** Desktop character box heights (width is always 46). */
internal fun characterHeight(character: CompanionCharacter) = when (character) {
    CompanionCharacter.Sprout -> 48f
    CompanionCharacter.Moss -> 46f
    CompanionCharacter.Vireo -> 42f
}

@Composable
internal fun CompanionAvatar(character: CompanionCharacter, pose: CompanionPose, modifier: Modifier = Modifier,
    size: Dp = 72.dp, failure: Boolean = false, description: String? = null) {
    val theme = characterTheme(VerdeColors)
    val bob = bobOffset(pose == CompanionPose.Working)
    Canvas(modifier.size(size).semantics { if (description != null) contentDescription = description }) {
        // 60×56 units leave room for Sprout's leaf (x 48) and Vireo's tail (x −9).
        val unit = minOf(this.size.width / 60f, this.size.height / 56f)
        val h = characterHeight(character)
        val origin = Offset((this.size.width - 46f * unit) / 2f + 1.5f * unit, (this.size.height - h * unit) / 2f + bob.value * unit)
        val pen = CharacterPen(this, origin, unit)
        when (character) {
            CompanionCharacter.Sprout -> pen.sprout(theme, pose)
            CompanionCharacter.Moss -> pen.moss(theme, pose)
            CompanionCharacter.Vireo -> pen.vireo(theme, pose)
        }
        if (pose == CompanionPose.Approval) pen.approvalBadge(theme)
        if (failure) pen.failureBadge(theme)
    }
}

/** A one-unit bob while a turn or delegated chat is actually running. */
@Composable
private fun bobOffset(active: Boolean): State<Float> {
    if (!active) return rememberUpdatedState(0f)
    val transition = rememberInfiniteTransition(label = "Companion working")
    return transition.animateFloat(initialValue = 0f, targetValue = -1.2f,
        animationSpec = infiniteRepeatable(tween(700, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "Companion bob")
}

/** Draws in character units: (x, y) relative to the 46-unit box. */
internal class CharacterPen(private val scope: DrawScope, private val origin: Offset, private val u: Float) {
    private fun at(x: Float, y: Float) = Offset(origin.x + x * u, origin.y + y * u)

    fun rect(x: Float, y: Float, w: Float, h: Float, color: Color, radius: Float) {
        if (w <= 0f || h <= 0f) return
        val r = minOf(radius, minOf(w, h) / 2f) * u
        scope.drawRoundRect(color, at(x, y), Size(w * u, h * u), CornerRadius(r, r))
    }

    /** Desktop `appendPanel`: stroke color fills the rect, the fill is inset by the stroke width. */
    fun panel(x: Float, y: Float, w: Float, h: Float, fill: Color, stroke: Color, radius: Float, width: Float) {
        val sw = minOf(width, minOf(w, h) * .5f)
        val r = minOf(radius, minOf(w, h) * .5f)
        rect(x, y, w, h, stroke, r)
        rect(x + sw, y + sw, w - sw * 2f, h - sw * 2f, fill, maxOf(r - sw, 0f))
    }

    fun triangle(a: Offset, b: Offset, c: Offset, color: Color) {
        val path = Path().apply { moveTo(at(a.x, a.y).x, at(a.x, a.y).y); lineTo(at(b.x, b.y).x, at(b.x, b.y).y); lineTo(at(c.x, c.y).x, at(c.x, c.y).y); close() }
        scope.drawPath(path, color)
    }

    fun line(a: Offset, b: Offset, width: Float, color: Color) =
        scope.drawLine(color, at(a.x, a.y), at(b.x, b.y), strokeWidth = width * u, cap = StrokeCap.Round)

    fun clipped(x: Float, y: Float, w: Float, h: Float, block: () -> Unit) {
        val tl = at(x, y)
        scope.clipRect(tl.x, tl.y, tl.x + w * u, tl.y + h * u) { block() }
    }

    fun failureBadge(t: CharacterTheme) {
        rect(-4f, -2f, 11f, 11f, raiseAgainst(t.background, .035f, t.background, t.text), 5.5f)
        rect(-2f, 0f, 7f, 7f, t.danger, 3.5f)
    }

    fun approvalBadge(t: CharacterTheme) {
        rect(37f, -3f, 12f, 12f, raiseAgainst(t.background, .035f, t.background, t.text), 6f)
        rect(39f, -1f, 8f, 8f, t.warning, 4f)
        val mark = if (lumaDistance(t.warning, t.text) >= lumaDistance(t.warning, t.background)) t.text else t.background
        rect(42.4f, .4f, 1.2f, 3.4f, mark, .6f)
        rect(42.4f, 4.6f, 1.2f, 1.2f, mark, .6f)
    }

    // ---- Sprout: hatchling with a crown leaf ----
    fun sprout(t: CharacterTheme, pose: CompanionPose) {
        val textLighter = characterLuma(t.text) >= characterLuma(t.background)
        val poleLight = if (textLighter) t.text else t.background
        val poleDark = if (textLighter) t.background else t.text
        val accentHi = mixColor(t.accent, poleLight, .28f)
        val well = raiseAgainst(t.background, .02f, t.background, t.text)
        val surface = raiseAgainst(t.background, .035f, t.background, t.text)
        var headTop = mixColor(t.text, accentHi, .45f)
        var headBottom = mixColor(t.text, t.accent, .38f)
        var irisTop = mixColor(t.text, t.danger, .76f)
        var irisBottom = mixColor(well, t.danger, .66f)
        if (lumaDistance(irisTop, headTop) < .18f) {
            headTop = mixColor(headTop, t.text, .15f); headBottom = mixColor(headBottom, t.text, .15f)
            if (lumaDistance(irisTop, headTop) < .18f) { irisTop = t.danger; irisBottom = t.danger }
        }
        var outline = mixColor(t.border, t.accent, .55f)
        if (lumaDistance(outline, surface) < .10f) { outline = t.border; if (lumaDistance(outline, surface) < .10f) outline = t.subtle }
        var stem = mixColor(surface, t.accent, .85f)
        var bladeStart = t.accent
        var bladeEnd = mixColor(t.accent, accentHi, .75f)
        val torsoTop = mixColor(t.text, accentHi, .38f)
        val torsoBottom = mixColor(t.text, t.accent, .34f)
        val torsoFill = mixColor(torsoTop, torsoBottom, .5f)
        if (lumaDistance(mixColor(bladeStart, bladeEnd, .5f), torsoFill) < .06f) {
            val growth = mixColor(t.accent, poleDark, .15f)
            stem = growth; bladeStart = growth; bladeEnd = growth
        }
        val headFill = mixColor(headTop, headBottom, .5f)

        rect(17f, 7f, 3f, 9f, stem, 1.5f)
        val leaf = mixColor(bladeStart, bladeEnd, .5f)
        val droop = if (pose == CompanionPose.Paused) 4f else 0f
        val p0 = Offset(19f, 10f + droop); val p1 = Offset(48f, 3f + droop); val p2 = Offset(45f, 14f + droop); val p3 = Offset(23f, 16f + droop)
        triangle(p0, p1, p2, leaf)
        triangle(p0, p2, p3, leaf)

        // Small torso and two perch feet beneath the oversized head.
        rect(12f, 38f, 22f, 13f, withAlpha(poleDark, 31), 6f)
        panel(12f, 35f, 22f, 13f, torsoFill, outline, 6f, 1f)
        val feet = mixColor(t.text, t.accent, .30f)
        rect(12.5f, 46f, 7f, 4f, feet, 2f)
        rect(26.5f, 46f, 7f, 4f, feet, 2f)

        // 36×27 head.
        rect(5f, 15f, 36f, 27f, withAlpha(poleDark, 36), 13f)
        panel(5f, 12f, 36f, 27f, headFill, outline, 13f, 1f)
        clipped(5f, 12f, 36f, 27f) { rect(10f, 15f, 26f, 2f, withAlpha(poleLight, 64), 1f) }

        val eyeY = 19f
        val ring = mixColor(well, t.danger, .40f)
        for (eyeX in floatArrayOf(13f, 24.5f)) {
            if (pose == CompanionPose.Paused) {
                rect(eyeX, eyeY + 4f, 8.5f, 2f, mixColor(t.danger, well, .70f), 1f)
            } else {
                panel(eyeX, eyeY, 8.5f, 9f, mixColor(irisTop, irisBottom, .5f), ring, 4.25f, 1f)
                val gaze = if (pose == CompanionPose.Approval) 2f else 0f
                rect(eyeX + 2.5f + gaze, eyeY + 3f, 3.5f, 4f, ring, 1.7f)
                rect(eyeX + 1.7f, eyeY + 1.4f, 3f, 3f, mixColor(t.danger, poleLight, .90f), 1.5f)
                rect(eyeX + 5.4f, eyeY + 5.9f, 1.7f, 1.7f, withAlpha(mixColor(t.danger, poleLight, .70f), 204), .85f)
            }
        }
        val buds = mixColor(t.panelMuted, t.accent, .62f)
        for (offset in floatArrayOf(-5.5f, 0f, 5.5f)) rect(5f + 18f + offset - 1.5f, 12f + 27f - 2f, 3f, 3f, buds, 1.5f)
        val mouth = mixColor(t.accent, well, .65f)
        line(Offset(19.5f, 32.5f), Offset(23f, 34f), 1.2f, mouth)
        line(Offset(23f, 34f), Offset(26.5f, 32.5f), 1.2f, mouth)
    }

    // ---- Moss: guardian bust ----
    fun moss(t: CharacterTheme, pose: CompanionPose) {
        val textLighter = characterLuma(t.text) >= characterLuma(t.background)
        val poleLight = if (textLighter) t.text else t.background
        val poleDark = if (textLighter) t.background else t.text
        val surfaceDeep = mixColor(t.background, poleDark, .18f)
        val panelColor = mixColor(t.background, t.panelMuted, .55f)
        val bronze = mixColor(t.panelMuted, mixColor(t.accent, t.warning, .30f), .16f)
        var outline = mixColor(t.border, mixColor(t.accent, t.warning, .30f), .22f)
        if (lumaDistance(outline, bronze) < .10f) { outline = t.border; if (lumaDistance(outline, bronze) < .10f) outline = t.subtle }
        val deep = mixColor(t.accent, surfaceDeep, .28f)
        val mid = mixColor(t.accent, panelColor, .12f)
        val lit = mixColor(mixColor(t.accent, poleLight, .28f), t.accent, .42f)
        val depth = withAlpha(poleDark, 34)
        val tilt = if (pose == CompanionPose.Approval) 1.2f else 0f
        val drop = if (pose == CompanionPose.Paused) 1f else 0f

        // Shoulder mound and resting hands.
        rect(0f, 28f, 46f, 20f, depth, 10f)
        panel(0f, 26f, 46f, 20f, bronze, outline, 10f, 1f)
        rect(3f, 43f, 9f, 6f, bronze, 4f)
        rect(34f, 43f, 9f, 6f, bronze, 4f)

        // Shoulder moss carpet.
        val capX = 2f; val capY = 20f + drop
        rect(capX, capY, 42f, 11f, mid, 6f)
        rect(capX + 4f, capY + 1f, 10f, 7f, lit, 4f)
        rect(capX + 18f, capY - 1f, 12f, 8f, deep, 5f)
        rect(capX + 30f, capY + 2f, 9f, 7f, lit, 4f)
        rect(capX + 5f, capY + 6f, 7f, 6f, mid, 3.5f)
        rect(capX + 29f, capY + 6f, 9f, 8f, deep, 4f)

        // Sprig and flower.
        rect(8f, 12f + drop, 1.5f, 8f, deep, .8f)
        rect(4.5f, 12f + drop, 5f, 3.5f, lit, 1.8f)
        rect(8.5f, 13.5f + drop, 4f, 3f, mid, 1.5f)
        rect(36f, 15f + drop, 4f, 4f, mixColor(poleLight, t.warning, .18f), 2f)
        rect(37f, 16f + drop, 2f, 2f, t.warning, 1f)

        // Egg head, neck, crown moss, ports and mouth slot.
        val hx = 14f + tilt; val hy = 1f + drop
        rect(hx + 6f, hy + 17f, 5f, 8f, bronze, 2f)
        rect(hx, hy + 2f, 17f, 20f, depth, 8.5f)
        panel(hx, hy, 17f, 20f, bronze, outline, 8.5f, 1f)
        rect(hx - 3f, hy - 2f, 19f, 8f, mid, 4f)
        rect(hx - 1f, hy - 1f, 7f, 5f, lit, 2.5f)
        rect(hx + 11f, hy + 1f, 6f, 7f, deep, 3f)

        val eyeY = hy + 6f
        val gaze = if (pose == CompanionPose.Approval) 1.5f else 0f
        for (eyeX in floatArrayOf(hx + 3f, hx + 9f)) {
            if (pose == CompanionPose.Paused) {
                rect(eyeX, eyeY + 2f, 5.5f, 2f, mixColor(surfaceDeep, t.warning, .35f), 1f)
            } else {
                panel(eyeX, eyeY, 5.5f, 5.5f, mixColor(t.warning, surfaceDeep, .94f), mixColor(surfaceDeep, t.warning, .28f), 2.75f, 1f)
                rect(eyeX + 1.8f + gaze, eyeY + 1.8f, 2f, 2f, mixColor(t.warning, poleLight, .22f), 1f)
            }
        }
        rect(hx + 6f, hy + 14.5f, 5f, 2f, mixColor(surfaceDeep, t.warning, .20f), 1f)
    }

    // ---- Vireo: side-profile songbird ----
    fun vireo(t: CharacterTheme, pose: CompanionPose) {
        val textLighter = characterLuma(t.text) >= characterLuma(t.background)
        val poleLight = if (textLighter) t.text else t.background
        val poleDark = if (textLighter) t.background else t.text
        val panelColor = mixColor(t.background, t.panelMuted, .42f)
        val olive = mixColor(mixColor(t.accent, t.warning, .45f), panelColor, .42f)
        val breast = mixColor(poleLight, t.accent, .12f)
        var outline = mixColor(t.border, t.accent, .35f)
        if (lumaDistance(outline, olive) < .10f) { outline = t.border; if (lumaDistance(outline, olive) < .10f) outline = t.subtle }
        val tilt = if (pose == CompanionPose.Approval) 1.4f else 0f
        val drop = if (pose == CompanionPose.Paused) 2f else 0f
        val tailDroop = if (pose == CompanionPose.Paused) 2f else 0f
        val olive2 = mixColor(t.accent, t.warning, .45f)

        rect(-9f, 23f + tailDroop, 21f, 5f, mixColor(olive2, panelColor, .48f), 2.5f)
        rect(5f, 19f, 33f, 18f, withAlpha(outline, 40), 9f)
        panel(5f, 17f, 33f, 18f, olive, outline, 9f, 1f)
        rect(15f, 25f, 20f, 9f, breast, 5f)
        val leg = mixColor(t.panelMuted, poleDark, .30f)
        rect(18f, 34f, 1.8f, 8f, leg, .9f)
        rect(24.2f, 34f, 1.8f, 8f, leg, .9f)
        rect(6f, 19.5f, 21f, 10f, mixColor(olive2, panelColor, .40f), 5f)
        rect(4f, 24.5f, 10f, 4.5f, mixColor(olive2, t.panelMuted, .65f), 2.2f)

        val hx = 22f + tilt; val hy = 1f + drop
        panel(hx, hy, 24f, 16f, mixColor(olive, panelColor, .18f), outline, 7f, 1f)
        rect(hx + 2f, hy, 18f, 6f, mixColor(t.panelMuted, poleDark, .26f), 4f)
        val brow = mixColor(poleLight, t.accent, .20f)
        arc(listOf(Offset(hx + 5.5f, hy + 5.8f), Offset(hx + 10.2f, hy + 3.6f), Offset(hx + 16f, hy + 3.3f), Offset(hx + 22.5f, hy + 4.9f)), 1.55f, brow)
        arc(listOf(Offset(hx + 6f, hy + 7.2f), Offset(hx + 10.6f, hy + 5.4f), Offset(hx + 16.2f, hy + 5.2f), Offset(hx + 21.8f, hy + 6.6f)), 1.15f, mixColor(poleDark, t.warning, .28f))

        val ex = hx + 14.5f; val ey = hy + 6.7f
        if (pose == CompanionPose.Paused) {
            rect(ex, ey, 5.5f, 2.5f, mixColor(mixColor(t.background, poleDark, .35f), t.danger, .30f), 1.2f)
        } else {
            panel(ex, ey, 5.5f, 5.5f, mixColor(t.danger, poleLight, .12f), brow, 2.75f, 1f)
            val px = if (pose == CompanionPose.Approval) .55f + .85f else .55f
            val py = if (pose == CompanionPose.Approval) 1.55f + .45f else 1.55f
            rect(ex + px, ey + py, 2.2f, 2.2f, mixColor(t.background, poleDark, .35f), 1.1f)
        }
        rect(hx + 21f, hy + 7f, 10f, 3f, mixColor(poleDark, t.panelMuted, .22f), 1.5f)
    }

    private fun arc(points: List<Offset>, width: Float, color: Color) {
        for (i in 0 until points.size - 1) line(points[i], points[i + 1], width, color)
    }
}

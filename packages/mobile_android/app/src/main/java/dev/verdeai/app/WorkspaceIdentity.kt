package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.verdeai.core.Workspace
import kotlin.math.abs

/** Semantic names from docs/workspace-switcher-sidebar.md; the core projects the index. */
internal val WORKSPACE_ICON_NAMES = listOf("folder", "rocket", "flask", "leaf", "bolt", "star", "flame", "cube",
    "code", "terminal", "globe", "heart", "moon", "sun", "compass", "puzzle")

private fun glyph(name: String, vararg paths: Pair<String, PathFillType>): ImageVector =
    ImageVector.Builder(name = "Workspace.$name", defaultWidth = 24.dp, defaultHeight = 24.dp,
        viewportWidth = 24f, viewportHeight = 24f).apply {
        paths.forEach { (d, rule) -> addPath(addPathNodes(d), pathFillType = rule, fill = SolidColor(Color.Black)) }
    }.build()

private fun glyph(name: String, vararg paths: String) = glyph(name, *paths.map { it to PathFillType.NonZero }.toTypedArray())

/** material-icons-core lacks most of the set; these are compact Material-style paths. */
private val WORKSPACE_ICONS: List<ImageVector> by lazy {
    listOf(
        glyph("folder", "M10,4H4c-1.1,0 -2,0.9 -2,2v12c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2V8c0,-1.1 -0.9,-2 -2,-2h-8l-2,-2z"),
        glyph("rocket", "M12,2c3,2.5 4.5,6 4.5,10l-1.5,4H9l-1.5,-4C7.5,8 9,4.5 12,2zM12,7.25a1.75,1.75 0 1,0 0.01,0z" to PathFillType.EvenOdd,
            "M7.2,12.8L4.5,15.3V20l3.9,-2.9z" to PathFillType.NonZero, "M16.8,12.8l2.7,2.5V20l-3.9,-2.9z" to PathFillType.NonZero,
            "M10,17h4l-2,4.5z" to PathFillType.NonZero),
        glyph("flask", "M19.8,18.4L14,10.67V6.5l1.35,-1.69C15.61,4.48 15.38,4 14.96,4H9.04C8.62,4 8.39,4.48 8.65,4.81L10,6.5v4.17L4.2,18.4C3.71,19.06 4.18,20 5,20h14C19.82,20 20.29,19.06 19.8,18.4z"),
        glyph("leaf", "M6.05,8.05c-2.73,2.73 -2.73,7.15 -0.02,9.88c1.47,-3.4 4.09,-6.24 7.36,-7.93c-2.77,2.34 -4.71,5.61 -5.39,9.32c2.6,1.23 5.8,0.78 7.95,-1.37C19.43,14.47 20,4 20,4S9.53,4.57 6.05,8.05z"),
        glyph("bolt", "M7,2v11h3v9l7,-12h-4l4,-8z"),
        Icons.Filled.Star,
        glyph("flame", "M13.5,0.67s0.74,2.65 0.74,4.8c0,2.06 -1.35,3.73 -3.41,3.73c-2.07,0 -3.63,-1.67 -3.63,-3.73l0.03,-0.36C5.21,7.51 4,10.62 4,14c0,4.42 3.58,8 8,8s8,-3.58 8,-8C20,8.61 17.41,3.8 13.5,0.67zM11.71,19c-1.78,0 -3.22,-1.4 -3.22,-3.14c0,-1.62 1.05,-2.76 2.81,-3.12c1.77,-0.36 3.6,-1.21 4.62,-2.58c0.39,1.29 0.59,2.65 0.59,4.04c0,2.65 -2.15,4.8 -4.8,4.8z"),
        glyph("cube", "M12,3.2L19.6,7.4L12,11.6L4.4,7.4z", "M3.6,8.7L11.3,13v8.3L3.6,17z", "M20.4,8.7L12.7,13v8.3l7.7,-4.3z"),
        glyph("code", "M9.4,16.6L4.8,12l4.6,-4.6L8,6l-6,6l6,6l1.4,-1.4zM14.6,16.6l4.6,-4.6l-4.6,-4.6L16,6l6,6l-6,6l-1.4,-1.4z"),
        glyph("terminal", "M20,4H4C2.89,4 2,4.9 2,6v12c0,1.1 0.89,2 2,2h16c1.1,0 2,-0.9 2,-2V6C22,4.9 21.11,4 20,4zM20,18H4V8h16V18zM18,17h-6v-2h6V17zM7.5,17l-1.41,-1.41L8.67,13l-2.59,-2.59L7.5,9l4,4L7.5,17z"),
        glyph("globe", "M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10s10,-4.48 10,-10S17.52,2 12,2zM11,19.93c-3.95,-0.49 -7,-3.85 -7,-7.93c0,-0.62 0.08,-1.21 0.21,-1.79L9,15v1c0,1.1 0.9,2 2,2v1.93zM17.9,17.39c-0.26,-0.81 -1,-1.39 -1.9,-1.39h-1v-3c0,-0.55 -0.45,-1 -1,-1H8v-2h2c0.55,0 1,-0.45 1,-1V7h2c1.1,0 2,-0.9 2,-2v-0.41c2.93,1.19 5,4.06 5,7.41c0,2.08 -0.8,3.97 -2.1,5.39z"),
        Icons.Filled.Favorite,
        glyph("moon", "M12,3c-4.97,0 -9,4.03 -9,9s4.03,9 9,9s9,-4.03 9,-9c0,-0.46 -0.04,-0.92 -0.1,-1.36c-0.98,1.37 -2.58,2.26 -4.4,2.26c-2.98,0 -5.4,-2.42 -5.4,-5.4c0,-1.81 0.89,-3.42 2.26,-4.4C12.92,3.04 12.46,3 12,3z"),
        glyph("sun", "M12,7a5,5 0 1,0 0.01,0z", "M11,1h2v3h-2z", "M11,20h2v3h-2z", "M1,11h3v2H1z", "M20,11h3v2h-3z",
            "M4.22,5.64l1.42,-1.42l2.12,2.12l-1.42,1.42z", "M16.24,17.66l1.42,-1.42l2.12,2.12l-1.42,1.42z",
            "M4.22,18.36l2.12,-2.12l1.42,1.42l-2.12,2.12z", "M16.24,6.34l2.12,-2.12l1.42,1.42l-2.12,2.12z"),
        glyph("compass", "M12,10.9c-0.61,0 -1.1,0.49 -1.1,1.1s0.49,1.1 1.1,1.1s1.1,-0.49 1.1,-1.1s-0.49,-1.1 -1.1,-1.1zM12,2C6.48,2 2,6.48 2,12s4.48,10 10,10s10,-4.48 10,-10S17.52,2 12,2zM14.19,14.19L6,18l3.81,-8.19L18,6l-3.81,8.19z"),
        glyph("puzzle", "M20.5,11H19V7c0,-1.1 -0.9,-2 -2,-2h-4V3.5C13,2.12 11.88,1 10.5,1S8,2.12 8,3.5V5H4c-1.1,0 -2,0.9 -2,2v3.8h1.5c1.49,0 2.7,1.21 2.7,2.7s-1.21,2.7 -2.7,2.7H2V20c0,1.1 0.9,2 2,2h3.8v-1.5c0,-1.49 1.21,-2.7 2.7,-2.7s2.7,1.21 2.7,2.7V22H17c1.1,0 2,-0.9 2,-2v-4h1.5c1.38,0 2.5,-1.12 2.5,-2.5S21.88,11 20.5,11z"),
    )
}

internal fun workspaceIcon(index: Int): ImageVector = WORKSPACE_ICONS[index.mod(WORKSPACE_ICONS.size)]

/**
 * Spec color slot: the theme accent with hue rotated by `slot * 45°`, saturation clamped
 * to [0.45, 0.85] and lightness to [0.55, 0.72] (dark) or [0.38, 0.50] (light).
 */
internal fun workspaceColor(slot: Int, accent: Color = VerdeColors.Accent, dark: Boolean = true): Color {
    val r = accent.red; val g = accent.green; val b = accent.blue
    val max = maxOf(r, g, b); val min = minOf(r, g, b); val d = max - min
    val l = (max + min) / 2f
    val s = if (d == 0f) 0f else d / (1f - abs(2f * l - 1f))
    val h = when {
        d == 0f -> 0f
        max == r -> 60f * (((g - b) / d).mod(6f))
        max == g -> 60f * ((b - r) / d + 2f)
        else -> 60f * ((r - g) / d + 4f)
    }
    val hue = (h + slot.mod(8) * 45f).mod(360f)
    val light = if (dark) l.coerceIn(.55f, .72f) else l.coerceIn(.38f, .50f)
    return Color.hsl(hue, s.coerceIn(.45f, .85f), light)
}

/** Identity icon on a square chip tinted with the slot color at 18% alpha. */
@Composable
internal fun WorkspaceChip(workspace: Workspace, size: Dp = 18.dp, modifier: Modifier = Modifier) {
    val color = workspaceColor(workspace.color_index)
    Box(modifier.size(size).background(color.copy(alpha = .18f), RoundedCornerShape(size * .25f)),
        contentAlignment = Alignment.Center) {
        Icon(workspaceIcon(workspace.icon_index), contentDescription = null, tint = color,
            modifier = Modifier.padding(size * .17f).size(size * .66f))
    }
}

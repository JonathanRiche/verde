package dev.verdeai.app

import android.content.Context
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import dev.verdeai.core.CoreJson
import kotlinx.serialization.Serializable

/** Shared offline catalog, derived from the website's downloadable theme packages. */
@Serializable
internal data class BundledTheme(val id: String, val name: String, val colors: Map<String, String>) {
    fun palette(): VerdePalette {
        fun color(key: String) = Color(android.graphics.Color.parseColor(colors.getValue(key)))
        val background = color("background")
        val text = color("text")
        val accent = color("accent")
        val warning = color("warning")
        val dark = background.red * .2126f + background.green * .7152f + background.blue * .0722f < .5f
        return VerdePalette(dark = dark, Background = background, Panel = color("panel"),
            PanelAlt = color("panel_alt"), PanelMuted = color("panel_muted"), Border = color("border"),
            Text = text, Muted = color("text_muted"), Subtle = color("text_subtle"),
            Accent = accent, AccentHi = accent, Warning = warning, Danger = color("diff_remove"),
            UserBubble = color("selection"), Assistant = color("panel"), DiffAdd = color("diff_add"),
            Heading1 = warning, Heading2 = warning, Heading3 = accent, Heading4 = text,
            WarningPanel = lerp(background, warning, .18f), DangerPanel = lerp(background, color("diff_remove"), .18f))
    }
}

internal fun bundledThemes(context: Context): Map<String, BundledTheme> =
    context.assets.open("themes.json").bufferedReader().use {
        CoreJson.decodeFromString<List<BundledTheme>>(it.readText()).associateBy(BundledTheme::id)
    }

package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale

/** Shared with web/src/styles.css; intentionally independent of system/dynamic colors. */
internal object VerdeColors {
    val Background = Color(0xFF0D1213)
    val Panel = Color(0xFF20272A)
    val PanelAlt = Color(0xFF28292E)
    val PanelMuted = Color(0xFF38393E)
    val Border = Color(0xFF3C474C)
    val Text = Color(0xFFF0F0F5)
    val Muted = Color(0xFFB9BBC3)
    val Subtle = Color(0xFF787887)
    val Accent = Color(0xFF50C878)
    val AccentHi = Color(0xFF6EE89A)
    val AccentWash = Accent.copy(alpha = .19f)
    val Warning = Color(0xFFFBBF24)
    val Danger = Color(0xFFFF6464)
    val UserBubble = Color(0xFF2A4636)
    val Assistant = Color(0xFF161C1E)
    val DiffAdd = Color(0xFF34E094)
    val Heading1 = Color(0xFFF5C84A)
    val Heading2 = Color(0xFFF6D27A)
    val Heading3 = Color(0xFF99DCB3)
    val Heading4 = Color(0xFFD0D1D6)
}

internal val VerdeSans = FontFamily(Font(R.font.noto_sans_regular), Font(R.font.noto_sans_bold, FontWeight.Bold))
internal val VerdeDisplay = FontFamily(Font(R.font.cal_sans))
internal val VerdeMono = FontFamily(Font(R.font.jetbrains_mono))

private fun ui(size: Int, line: Int, weight: FontWeight = FontWeight.Normal) =
    TextStyle(fontFamily = VerdeSans, fontSize = size.sp, lineHeight = line.sp, fontWeight = weight)
private fun display(size: Int) = TextStyle(fontFamily = VerdeDisplay, fontSize = size.sp,
    lineHeight = (size + 6).sp, letterSpacing = (-size * .03).sp)

private val VerdeTypography = Typography(
    displayLarge = display(36), displayMedium = display(32), displaySmall = display(28),
    headlineLarge = display(28), headlineMedium = display(24), headlineSmall = display(22),
    titleLarge = display(20), titleMedium = ui(15, 21, FontWeight.SemiBold), titleSmall = ui(14, 20, FontWeight.SemiBold),
    bodyLarge = ui(15, 22), bodyMedium = ui(14, 21), bodySmall = ui(12, 18),
    labelLarge = ui(13, 18, FontWeight.Medium), labelMedium = ui(12, 16), labelSmall = ui(10, 14),
)

private val VerdeScheme = darkColorScheme(
    primary = VerdeColors.Accent, onPrimary = VerdeColors.Background,
    primaryContainer = VerdeColors.UserBubble, onPrimaryContainer = VerdeColors.Text,
    secondary = VerdeColors.AccentHi, onSecondary = VerdeColors.Background,
    secondaryContainer = VerdeColors.PanelAlt, onSecondaryContainer = VerdeColors.Text,
    tertiary = VerdeColors.Warning, onTertiary = VerdeColors.Background,
    tertiaryContainer = Color(0xFF443B22), onTertiaryContainer = VerdeColors.Text,
    error = VerdeColors.Danger, onError = VerdeColors.Background,
    errorContainer = Color(0xFF422829), onErrorContainer = VerdeColors.Text,
    background = VerdeColors.Background, onBackground = VerdeColors.Text,
    surface = VerdeColors.Background, onSurface = VerdeColors.Text,
    surfaceVariant = VerdeColors.PanelAlt, onSurfaceVariant = VerdeColors.Muted,
    surfaceTint = Color.Transparent, outline = VerdeColors.Subtle, outlineVariant = VerdeColors.Border,
    surfaceDim = VerdeColors.Background, surfaceBright = VerdeColors.PanelMuted,
    surfaceContainerLowest = VerdeColors.Background, surfaceContainerLow = VerdeColors.Assistant,
    surfaceContainer = VerdeColors.Panel, surfaceContainerHigh = VerdeColors.PanelAlt,
    surfaceContainerHighest = VerdeColors.PanelMuted,
    inverseSurface = VerdeColors.Text, inverseOnSurface = VerdeColors.Background, inversePrimary = VerdeColors.UserBubble,
)

@Composable
internal fun VerdeTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = VerdeScheme, typography = VerdeTypography,
        shapes = Shapes(extraSmall = RoundedCornerShape(7.dp), small = RoundedCornerShape(7.dp),
            medium = RoundedCornerShape(10.dp), large = RoundedCornerShape(14.dp), extraLarge = RoundedCornerShape(14.dp)),
        content = content)
}

/** Compact web-style row; callers retain click/long-click semantics and tags. */
@Composable
internal fun VerdeListRow(headlineContent: @Composable () -> Unit, modifier: Modifier = Modifier,
    supportingContent: (@Composable () -> Unit)? = null, leadingContent: (@Composable () -> Unit)? = null,
    trailingContent: (@Composable () -> Unit)? = null) {
    Row(modifier.heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        leadingContent?.invoke()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            ProvideTextStyle(MaterialTheme.typography.bodyMedium) { headlineContent() }
            if (supportingContent != null) CompositionLocalProvider(LocalContentColor provides VerdeColors.Muted) {
                ProvideTextStyle(MaterialTheme.typography.bodySmall) { supportingContent() }
            }
        }
        trailingContent?.invoke()
    }
}

@Composable
internal fun VerdeSection(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(Locale.ROOT), modifier.padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 4.dp)
        .semantics { heading() },
        style = MaterialTheme.typography.labelSmall.copy(letterSpacing = .8.sp, fontWeight = FontWeight.SemiBold),
        color = VerdeColors.Subtle)
}

internal val LocalWorkspaceMenu = staticCompositionLocalOf<(() -> Unit)?> { null }

/** Insets are owned by the app shell (or the containing dialog). */
@Composable
internal fun VerdeTopBar(title: @Composable () -> Unit, navigationIcon: @Composable () -> Unit = {},
    showWorkspaceMenu: Boolean = true, actions: @Composable RowScope.() -> Unit = {}) {
    Column(Modifier.background(VerdeColors.Panel)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            navigationIcon()
            Box(Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 6.dp)) {
                ProvideTextStyle(MaterialTheme.typography.titleMedium) { title() }
            }
            actions()
            if (showWorkspaceMenu) LocalWorkspaceMenu.current?.let { open ->
                IconButton(onClick = open) { Icon(Icons.Filled.Menu, contentDescription = "Open workspace drawer") }
            }
        }
        HorizontalDivider(color = VerdeColors.Border)
    }
}

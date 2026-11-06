package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.platform.LocalContext
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
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.interaction.FocusInteraction
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.node.CompositionLocalConsumerModifierNode
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DelegatingNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.currentValueOf
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.platform.LocalInputModeManager
import kotlinx.coroutines.launch
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.Dp

/** Semantic colors shared by Material controls and custom chrome. */
internal data class VerdePalette(
    val dark: Boolean = true,
    val Background: Color = Color(0xFF0D1213),
    val Panel: Color = Color(0xFF20272A),
    val PanelAlt: Color = Color(0xFF28292E),
    val PanelMuted: Color = Color(0xFF38393E),
    val Border: Color = Color(0xFF3C474C),
    val Text: Color = Color(0xFFF0F0F5),
    val Muted: Color = Color(0xFFB9BBC3),
    val Subtle: Color = Color(0xFF787887),
    val Accent: Color = Color(0xFF50C878),
    val AccentHi: Color = Color(0xFF6EE89A),
    val Warning: Color = Color(0xFFFBBF24),
    val Danger: Color = Color(0xFFFF6464),
    val UserBubble: Color = Color(0xFF2A4636),
    val Assistant: Color = Color(0xFF161C1E),
    val DiffAdd: Color = Color(0xFF34E094),
    val Heading1: Color = Color(0xFFF5C84A),
    val Heading2: Color = Color(0xFFF6D27A),
    val Heading3: Color = Color(0xFF99DCB3),
    val Heading4: Color = Color(0xFFD0D1D6),
    val WarningPanel: Color = Color(0xFF443B22),
    val DangerPanel: Color = Color(0xFF422829),
) {
    val AccentWash get() = Accent.copy(alpha = .19f)
}

internal val DarkPalette = VerdePalette()
internal val LightPalette = VerdePalette(
    dark = false,
    Background = Color(0xFFF5F7F6), Panel = Color.White, PanelAlt = Color(0xFFE9EEEB),
    PanelMuted = Color(0xFFDDE5E0), Border = Color(0xFFC2CCC6), Text = Color(0xFF15221B),
    Muted = Color(0xFF46594E), Subtle = Color(0xFF607267), Accent = Color(0xFF197D43),
    AccentHi = Color(0xFF116B36), Warning = Color(0xFFA36800), Danger = Color(0xFFB52828),
    UserBubble = Color(0xFFD8EDDF), Assistant = Color.White, DiffAdd = Color(0xFF147849),
    Heading1 = Color(0xFF805B00), Heading2 = Color(0xFF86620D),
    Heading3 = Color(0xFF197D43), Heading4 = Color(0xFF46594E),
    WarningPanel = Color(0xFFF4E6BE), DangerPanel = Color(0xFFF6DDDD),
)
internal val LocalVerdePalette = staticCompositionLocalOf { DarkPalette }
internal val VerdeColors: VerdePalette @Composable get() = LocalVerdePalette.current

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

private fun verdeScheme(p: VerdePalette) = (if (p.dark) darkColorScheme() else lightColorScheme()).copy(
    primary = p.Accent, onPrimary = if (p.dark) p.Background else Color.White,
    primaryContainer = p.UserBubble, onPrimaryContainer = p.Text,
    secondary = p.AccentHi, onSecondary = if (p.dark) p.Background else Color.White,
    secondaryContainer = p.PanelAlt, onSecondaryContainer = p.Text,
    tertiary = p.Warning, onTertiary = if (p.dark) p.Background else Color.White,
    tertiaryContainer = p.WarningPanel, onTertiaryContainer = p.Text,
    error = p.Danger, onError = if (p.dark) p.Background else Color.White,
    errorContainer = p.DangerPanel, onErrorContainer = p.Text,
    background = p.Background, onBackground = p.Text,
    surface = p.Background, onSurface = p.Text,
    surfaceVariant = p.PanelAlt, onSurfaceVariant = p.Muted,
    surfaceTint = Color.Transparent, outline = p.Subtle, outlineVariant = p.Border,
    surfaceDim = p.Background, surfaceBright = p.PanelMuted,
    surfaceContainerLowest = p.Background, surfaceContainerLow = p.Assistant,
    surfaceContainer = p.Panel, surfaceContainerHigh = p.PanelAlt,
    surfaceContainerHighest = p.PanelMuted,
    inverseSurface = p.Text, inverseOnSurface = p.Background, inversePrimary = p.UserBubble,
)

@Composable
internal fun VerdeTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val inherited = LocalAppearanceSettings.current
    val settings = inherited ?: remember(context) { AppearanceSettings(context) }
    val palette = settings.palette(isSystemInDarkTheme())
    CompositionLocalProvider(LocalAppearanceSettings provides settings, LocalVerdePalette provides palette) {
        MaterialTheme(colorScheme = verdeScheme(palette), typography = VerdeTypography,
            shapes = Shapes(extraSmall = RoundedCornerShape(7.dp), small = RoundedCornerShape(7.dp),
                medium = RoundedCornerShape(10.dp), large = RoundedCornerShape(14.dp), extraLarge = RoundedCornerShape(14.dp))) {
            // S4: every foundation clickable gets the ripple plus a keyboard-only focus ring.
            val indication = remember(palette.Accent) { FocusRingIndication(ripple(), palette.Accent) }
            CompositionLocalProvider(LocalIndication provides indication, content = content)
        }
    }
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

/**
 * The one section header: sentence case, 13sp semibold, onSurfaceVariant, inset like the rows below
 * it (16dp). Callers inside an already padded column pass `inset = 0.dp`.
 */
@Composable
internal fun VerdeSection(text: String, modifier: Modifier = Modifier, inset: Dp = LocalSectionInset.current) {
    Text(text, modifier.padding(start = inset, end = inset, top = 16.dp, bottom = 4.dp).semantics { heading() },
        style = SectionHeaderStyle, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Section headers line up with their rows: 16dp in lists, 0 inside an already padded column (Settings). */
internal val LocalSectionInset = compositionLocalOf { 16.dp }

internal val SectionHeaderStyle = TextStyle(fontFamily = VerdeSans, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold)

/**
 * Fades the edge(s) a horizontal scroller can still move toward into [color], so clipped tables,
 * code and key rows read as "more this way" instead of cut off. Put it before `horizontalScroll`.
 */
internal fun Modifier.horizontalEdgeFade(state: ScrollState, color: Color, width: Dp = 24.dp) = drawWithContent {
    drawContent()
    val w = width.toPx().coerceAtMost(size.width / 3)
    if (state.canScrollBackward) drawRect(Brush.horizontalGradient(listOf(color, Color.Transparent), startX = 0f, endX = w),
        size = Size(w, size.height))
    if (state.canScrollForward) drawRect(Brush.horizontalGradient(listOf(Color.Transparent, color), startX = size.width - w, endX = size.width),
        topLeft = Offset(size.width - w, 0f), size = Size(w, size.height))
}

/**
 * Ripple plus a 2dp accent ring drawn only while focus came from a keyboard (Tab, D-pad); touch
 * never leaves a ring behind. Installed as [LocalIndication] for every foundation clickable.
 */
internal class FocusRingIndication(private val ripple: IndicationNodeFactory, private val color: Color) : IndicationNodeFactory {
    override fun create(interactionSource: InteractionSource): DelegatableNode = object : DelegatingNode() {
        init {
            delegate(ripple.create(interactionSource))
            delegate(FocusRingNode(interactionSource, color))
        }
    }
    override fun equals(other: Any?) = other is FocusRingIndication && other.ripple == ripple && other.color == color
    override fun hashCode() = 31 * ripple.hashCode() + color.hashCode()
}

private class FocusRingNode(private val interactions: InteractionSource, private val color: Color) :
    Modifier.Node(), DrawModifierNode, CompositionLocalConsumerModifierNode {
    private var focused = false
    override fun onAttach() {
        coroutineScope.launch {
            interactions.interactions.collect { interaction ->
                when (interaction) {
                    is FocusInteraction.Focus -> { focused = true; invalidateDraw() }
                    is FocusInteraction.Unfocus -> { focused = false; invalidateDraw() }
                }
            }
        }
    }
    override fun ContentDrawScope.draw() {
        drawContent()
        if (!focused || currentValueOf(LocalInputModeManager).inputMode != InputMode.Keyboard) return
        val stroke = 2.dp.toPx()
        drawRoundRect(color, topLeft = Offset(stroke / 2, stroke / 2), size = Size(size.width - stroke, size.height - stroke),
            cornerRadius = CornerRadius(8.dp.toPx()), style = Stroke(stroke))
    }
}

internal val LocalWorkspaceMenu = staticCompositionLocalOf<(() -> Unit)?> { null }

/** Insets are owned by the app shell (or the containing dialog). */
@Composable
internal fun VerdeTopBar(title: @Composable () -> Unit, navigationIcon: @Composable () -> Unit = {},
    showWorkspaceMenu: Boolean = true, companion: Boolean = true, actions: @Composable RowScope.() -> Unit = {}) {
    Column(Modifier.background(VerdeColors.Panel)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            navigationIcon()
            Box(Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 6.dp)) {
                ProvideTextStyle(MaterialTheme.typography.titleMedium) { title() }
            }
            // S1: on content screens the companion sits here, trailing, before the screen's own actions and ⋯ menu.
            if (companion) LocalCompanionHeader.current?.let { CompanionHeaderButton(it) }
            actions()
            if (showWorkspaceMenu) LocalWorkspaceMenu.current?.let { open ->
                IconButton(onClick = open) { Icon(Icons.Filled.Menu, contentDescription = "Open workspace drawer") }
            }
        }
        HorizontalDivider(color = VerdeColors.Border)
    }
}

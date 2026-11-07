package dev.verdeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.width
import dev.verdeai.core.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * S31: the composer chip spec, locked. Every chip keeps its glyph and short label at large, XXL
 * and AX-L text, idle and while steering, in Claude and Codex chats: the chips wrap to more rows,
 * they never drop labels or run past the row, and the order is model · effort · speed · access.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w411dp-h891dp")
class ComposerChipsLayoutTest {
    @get:Rule val compose = createComposeRule()

    private fun catalogs(codex: Boolean) = ChatCatalogs(
        models = listOf(ChatChoice("", "Default"), ChatChoice("m", if (codex) "GPT-6.1 Sol" else "Opus 5.5")),
        efforts = listOf(ChatChoice("", "Default"), ChatChoice("low", "Low"), ChatChoice("high", "High")),
        access = listOf(ChatChoice("supervised", "Supervised"), ChatChoice("full_access", "Full access")),
        speeds = if (codex) listOf(ChatChoice("off", "Normal"), ChatChoice("on", "Fast")) else emptyList(),
        default_model_label = if (codex) "GPT-6.1 Sol" else "Opus 5.5")

    private fun state(steer: Boolean) = TranscriptState("w", "t", thread = ChatThreadView(
        thread = ThreadSummary("w", "t", "Chat", "codex", null, null, open = true, archived = false, last_activity_at_ms = null,
            status = if (steer) "working" else "idle", history_bucket = "today"),
        rows = listOf(ChatRow(id = "1", role = "user", body = "hello")),
        page = ChatPage(has_older = false, cursor = null, loading = false),
        turn = if (steer) ChatTurn("turn", "running") else null, approval = null, usage = null, stale = false, error = null))

    private fun view(codex: Boolean) = ChatComposerView(ChatDraft("1", if (codex) "steer this" else "", emptyList(), true),
        ChatSelection(provider = if (codex) "codex" else "claude"), catalogs(codex), emptyList(), provider_ready = true,
        can_send = true, can_stop = true, send_operation = null, followup = null, shell_confirmation = null, error = null)

    private fun check(fontScale: Float, codex: Boolean, steer: Boolean, width: Int = 379, autoModel: Boolean = false) {
        val scale = fontScale
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, scale)) {
                VerdeTheme {
                    Box(Modifier.requiredWidth(width.dp)) {
                        SettingsControls(view(codex).let { if (autoModel) it.copy(catalogs = it.catalogs.copy(default_model_label = "Auto")) else it }, state(steer), if (codex) "codex" else "claude") {}
                    }
                }
            }
        }
        val labels = if (codex) listOf(if (autoModel) "Auto" else "GPT-6.1 Sol", "Auto", "Std", "Full").distinct() else listOf("Opus 5.5", "Auto", "Full")
        val row = compose.onNodeWithTag(COMPOSER_CHIPS).getUnclippedBoundsInRoot()
        val lefts = labels.map { label ->
            val node = compose.onAllNodes(hasText(label), useUnmergedTree = true).onFirst()
            node.assertExists("$label at ${fontScale}x (codex=$codex, steer=$steer)")
            val bounds = node.getUnclippedBoundsInRoot()
            assertTrue("$label stays inside the row at ${fontScale}x", bounds.right <= row.right + 1.dp && bounds.left >= row.left - 1.dp)
            bounds
        }
        if (autoModel) {
            // Model and effort both say Auto; finding just one could hide a squeezed model label.
            compose.onAllNodes(hasText("Auto"), useUnmergedTree = true).assertCountEquals(2)
            compose.onAllNodes(hasText("Auto"), useUnmergedTree = true).fetchSemanticsNodes().indices.forEach { index ->
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                compose.onAllNodes(hasText("Auto"), useUnmergedTree = true)[index]
                    .performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                assertTrue("Auto must fit its actual slot at $width dp/$scale",
                    layout.multiParagraph.intrinsics.maxIntrinsicWidth <= layout.layoutInput.constraints.maxWidth)
                assertFalse(layout.isLineEllipsized(0))
            }
        }
        // Reading order: model · effort · speed · access (rows wrap, but never reorder).
        lefts.zipWithNext().forEach { (a, b) -> assertTrue("order at ${fontScale}x", b.top > a.top + 1.dp || b.left > a.left) }
        // Every chip keeps its name on its own node.
        listOf("Model", "Effort", "Access").forEach { compose.onNodeWithContentDescription("$it:", substring = true).assertExists() }
        if (codex) compose.onNodeWithContentDescription("Speed: Standard. Change").assertExists()
    }

    @Test
    @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Config(sdk = [35], qualifiers = "w360dp-h900dp-420dpi")
    fun coverAutoModelKeepsTheWholeShortLabel() = check(1f, codex = true, steer = false, width = 328, autoModel = true)

    @Test
    @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Config(sdk = [35], qualifiers = "w360dp-h900dp-420dpi")
    fun coverSteerAtMaximumFontKeepsLabels() = check(2f, codex = true, steer = true, width = 328, autoModel = true)

    @Test fun largeIdleClaude() = check(1.3f, codex = false, steer = false)
    @Test fun largeSteerCodex() = check(1.3f, codex = true, steer = true)
    @Test fun xxlIdleCodex() = check(1.8f, codex = true, steer = false)
    @Test fun xxlSteerClaude() = check(1.8f, codex = false, steer = true)
    @Test fun axlIdleClaude() = check(2.0f, codex = false, steer = false)
    @Test fun axlSteerCodex() = check(2.0f, codex = true, steer = true)
    @Test fun defaultSizeCodexKeepsEveryLabel() = check(1.0f, codex = true, steer = false)

    @Test
    @OptIn(ExperimentalTestApi::class)
    @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    @Config(sdk = [35], qualifiers = "w411dp-h900dp-420dpi")
    fun phoneAndCoverIncludeAttachAndSendBeforeDecidingToWrap() {
        var width by mutableStateOf(411)
        var scale by mutableStateOf(1f)
        var codex by mutableStateOf(true)
        var steer by mutableStateOf(false)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, scale)) {
                VerdeTheme {
                    // The phone card has 8dp outer +12dp inner padding on each side. Send owns
                    // another 48dp plus its 4dp gap, which a SettingsControls-only test misses.
                    Row(Modifier.requiredWidth((width - 40).dp), verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.weight(1f)) {
                            SettingsControls(view(codex), state(steer), if (codex) "codex" else "claude",
                                leading = { Box(Modifier.size(48.dp).testTag("attach")) }) {}
                        }
                        Box(Modifier.size(48.dp).testTag("send"))
                    }
                }
            }
        }
        for (w in listOf(411, 360)) for (s in listOf(1f, 1.3f, 2f))
            for (provider in listOf(true, false)) for (working in listOf(false, true)) {
                width = w; scale = s; codex = provider; steer = working; compose.waitForIdle()
                val attach = compose.onNodeWithTag("attach").getUnclippedBoundsInRoot()
                val send = compose.onNodeWithTag("send").getUnclippedBoundsInRoot()
                val kinds = if (provider) listOf("Model", "Effort", "Speed", "Access") else listOf("Model", "Effort", "Access")
                for (kind in kinds) {
                    val node = compose.onNodeWithContentDescription("$kind:", substring = true)
                    val bounds = node.getUnclippedBoundsInRoot()
                    node.assertTouchHeightIsEqualTo(48.dp).assertTouchWidthIsEqualTo(maxOf(48.dp, bounds.width))
                    assertTrue("$kind stays before Send at $w/$s", bounds.right <= send.left && bounds.left >= attach.left)
                    if (s == 1f) assertTrue("One row at $w/$s, codex=$provider, steer=$working: $bounds",
                        kotlin.math.abs((bounds.top + bounds.bottom - send.top - send.bottom).value) < 1f)
                }
                val model = compose.onNode(hasText(if (provider) "GPT" else "Opu", substring = true), useUnmergedTree = true)
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                model.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val text = layouts.single().layoutInput.text.text
                assertTrue("Readable model at $w/$s: $text", if (provider) text.startsWith("GPT") && text.endsWith("Sol")
                    else text.startsWith("Opu") && text.endsWith("5.5"))
                val layout = layouts.single()
                // Native paragraph widths can exceed an integer text box by a float rounding
                // fraction at1.3x. Check the painted line and available slot with a 1px tolerance.
                assertEquals(1, layout.lineCount)
                assertFalse(layout.isLineEllipsized(0))
                assertTrue("Model stays in its slot at $w/$s: $text",
                    layout.getLineRight(0) <= layout.size.width + 1f &&
                        layout.multiParagraph.intrinsics.maxIntrinsicWidth <= layout.layoutInput.constraints.maxWidth + 1f)
            }
    }
}

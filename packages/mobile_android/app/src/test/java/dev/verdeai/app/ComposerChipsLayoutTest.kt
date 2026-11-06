package dev.verdeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
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

    private fun check(fontScale: Float, codex: Boolean, steer: Boolean) {
        val scale = fontScale
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, scale)) {
                VerdeTheme {
                    Box(Modifier.requiredWidth(379.dp)) {
                        SettingsControls(view(codex), state(steer), if (codex) "codex" else "claude") {}
                    }
                }
            }
        }
        val labels = if (codex) listOf("GPT-6.1 Sol", "Auto", "Std", "Full") else listOf("Opus 5.5", "Auto", "Full")
        val row = compose.onNodeWithTag(COMPOSER_CHIPS).getUnclippedBoundsInRoot()
        val lefts = labels.map { label ->
            val node = compose.onNode(hasText(label), useUnmergedTree = true)
            node.assertExists("$label at ${fontScale}x (codex=$codex, steer=$steer)")
            val bounds = node.getUnclippedBoundsInRoot()
            assertTrue("$label stays inside the row at ${fontScale}x", bounds.right <= row.right + 1.dp && bounds.left >= row.left - 1.dp)
            bounds
        }
        // Reading order: model · effort · speed · access (rows wrap, but never reorder).
        lefts.zipWithNext().forEach { (a, b) -> assertTrue("order at ${fontScale}x", b.top > a.top + 1.dp || b.left > a.left) }
        // Every chip keeps its name on its own node.
        listOf("Model", "Effort", "Access").forEach { compose.onNodeWithContentDescription("$it:", substring = true).assertExists() }
        if (codex) compose.onNodeWithContentDescription("Speed: Standard. Change").assertExists()
    }

    @Test fun largeIdleClaude() = check(1.3f, codex = false, steer = false)
    @Test fun largeSteerCodex() = check(1.3f, codex = true, steer = true)
    @Test fun xxlIdleCodex() = check(1.8f, codex = true, steer = false)
    @Test fun xxlSteerClaude() = check(1.8f, codex = false, steer = true)
    @Test fun axlIdleClaude() = check(2.0f, codex = false, steer = false)
    @Test fun axlSteerCodex() = check(2.0f, codex = true, steer = true)
    @Test fun defaultSizeCodexKeepsEveryLabel() = check(1.0f, codex = true, steer = false)
}

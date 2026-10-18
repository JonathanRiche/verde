package dev.verdeai.app

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.verdeai.core.*
import org.junit.Assert.*
import org.junit.Test

/** Pure composer parsing, mirroring the web client's composer_commands.ts / followups.ts. */
class ComposerParsingTest {
    @Test fun tokensFollowTheCaretLikeTheWebComposer() {
        assertEquals(ComposerToken(4, 13, "src/m"), fileMentionAtCaret("see @src/main now", 10))
        assertNull(fileMentionAtCaret("mail a@b", 3))
        assertNull(fileMentionAtCaret("@x", 0))
        assertEquals(ComposerToken(1, 5, "co"), slashTokenAtCaret(" /com args", 4))
        assertNull(slashTokenAtCaret("//literal", 3))
        assertNull(slashTokenAtCaret("/com args", 7))
    }

    @Test fun acceptingSuggestionsValidatesAndSpaces() {
        val v = TextFieldValue("look at @src", TextRange(12))
        assertEquals(TextFieldValue("look at @src/main.zig ", TextRange(22)), acceptFileMention(v, "src/main.zig"))
        for (bad in listOf("", "/etc/passwd", "../x", "a//b", "C:/x", "a\\b", "a\nb")) assertNull(bad, acceptFileMention(v, bad))
        assertEquals(TextFieldValue("/compact ", TextRange(9)), acceptSlashCommand(TextFieldValue("/co", TextRange(3)), "/compact"))
        assertNull(acceptSlashCommand(TextFieldValue("/co", TextRange(3)), "//x"))
    }

    @Test fun actionsAndFollowupKindsMatchTheDesktop() {
        assertEquals(ComposerAction.Shell, composerAction("!ls -la"))
        assertEquals(ComposerAction.Prompt, composerAction("!!not a command"))
        assertEquals(ComposerAction.Slash("/review", "main  branch"), composerAction("  /review main  branch "))
        assertEquals(ComposerAction.Literal("/path is literal"), composerAction("//path is literal"))
        assertEquals(ComposerAction.Prompt, composerAction("hello /there"))
        assertEquals(EventFollowupSubmitKind.steer, followupKind("claude", images=false))
        // Native steer only for codex/claude/pi without images; everything else interrupts and continues.
        assertEquals(EventFollowupSubmitKind.steer, followupKind("codex", images=false))
        assertEquals(EventFollowupSubmitKind.steer, followupKind("pi", images=false))
        assertEquals(EventFollowupSubmitKind.interrupt, followupKind("claude", images=true))
        assertEquals(EventFollowupSubmitKind.interrupt, followupKind("cursor", images=false))
        assertEquals(EventFollowupSubmitKind.interrupt, followupKind("opencode", images=true))
        assertEquals(EventFollowupSubmitKind.interrupt, followupKind(null, images=false))
        assertEquals(listOf(EventFollowupSubmitKind.interrupt, EventFollowupSubmitKind.queue), followupAlternatives("claude", images=false))
        assertEquals(listOf(EventFollowupSubmitKind.queue), followupAlternatives("claude", images=true))
        assertEquals(listOf(EventFollowupSubmitKind.queue), followupAlternatives("grok", images=false))
    }
}

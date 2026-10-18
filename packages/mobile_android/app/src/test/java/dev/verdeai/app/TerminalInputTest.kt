package dev.verdeai.app

import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class TerminalInputTest {
    @Test fun composingKeystrokesAreDeliveredBeforeCommitWithoutDuplicates() {
        val inputs = mutableListOf<TermInput>()
        val view = TerminalInputView(ApplicationProvider.getApplicationContext(), inputs::add)
        val connection = view.onCreateInputConnection(EditorInfo())
        connection.setComposingText("l", 1)
        assertEquals(listOf(TermInput.Text("l")), inputs)
        connection.setComposingText("ls", 1)
        assertEquals(listOf(TermInput.Text("l"), TermInput.Text("s")), inputs)
        connection.commitText("ls", 1)
        connection.finishComposingText()
        connection.performEditorAction(EditorInfo.IME_ACTION_NONE)
        assertEquals(listOf(TermInput.Text("l"), TermInput.Text("s"), TermInput.Key("Enter")), inputs)
    }

    @Test fun composingReplacementAndDeletionPreserveCodePoints() {
        val inputs = mutableListOf<TermInput>()
        val connection = TerminalInputView(ApplicationProvider.getApplicationContext(), inputs::add)
            .onCreateInputConnection(EditorInfo())
        connection.setComposingText("a😀", 1)
        connection.setComposingText("a🦊", 1)
        connection.setComposingText("a", 1)
        connection.commitText("ab", 1)
        connection.commitText("c", 1)
        assertEquals(listOf(TermInput.Text("a😀"), TermInput.Key("Backspace"), TermInput.Text("🦊"),
            TermInput.Key("Backspace"), TermInput.Text("b"), TermInput.Text("c")), inputs)
    }

    @Test fun finishingCompositionAndDeletingCommittedTextNeverReplaysIt() {
        val inputs = mutableListOf<TermInput>()
        val connection = TerminalInputView(ApplicationProvider.getApplicationContext(), inputs::add)
            .onCreateInputConnection(EditorInfo())
        connection.setComposingText("ls", 1)
        connection.finishComposingText()
        connection.finishComposingText()
        connection.deleteSurroundingText(1, 1)
        assertEquals(listOf(TermInput.Text("ls"), TermInput.Key("Backspace"), TermInput.Key("Delete")), inputs)
    }

    @Test fun hardwareKeysMapToCoreKeyNames() {
        fun down(code: Int, meta: Int = 0) = hardwareKey(KeyEvent(0, 0, KeyEvent.ACTION_DOWN, code, 0, meta))
        assertEquals(TermInput.Key("Enter"), down(KeyEvent.KEYCODE_ENTER))
        assertEquals(TermInput.Key("Tab", shift=true), down(KeyEvent.KEYCODE_TAB, KeyEvent.META_SHIFT_ON))
        assertEquals(TermInput.Key("PageDown"), down(KeyEvent.KEYCODE_PAGE_DOWN))
        assertEquals(TermInput.Key("Escape"), down(KeyEvent.KEYCODE_ESCAPE))
        assertEquals(TermInput.Text("a"), down(KeyEvent.KEYCODE_A))
        assertEquals(TermInput.Text("A"), down(KeyEvent.KEYCODE_A, KeyEvent.META_SHIFT_ON))
        assertEquals(TermInput.Key("x", alt=true), down(KeyEvent.KEYCODE_X, KeyEvent.META_ALT_ON))
        assertNull(down(KeyEvent.KEYCODE_SHIFT_LEFT))
    }
}

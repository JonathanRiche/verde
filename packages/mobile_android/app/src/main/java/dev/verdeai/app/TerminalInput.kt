package dev.verdeai.app

import android.annotation.SuppressLint
import android.content.Context
import android.text.InputType
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager

/** Hardware key → core key input. Printable keys with Ctrl/Alt become single-byte keys. */
internal fun hardwareKey(event: KeyEvent): TermInput? {
    val ctrl = event.isCtrlPressed
    val alt = event.isAltPressed
    val shift = event.isShiftPressed
    val named = when (event.keyCode) {
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "Enter"
        KeyEvent.KEYCODE_DEL -> "Backspace"
        KeyEvent.KEYCODE_FORWARD_DEL -> "Delete"
        KeyEvent.KEYCODE_TAB -> "Tab"
        KeyEvent.KEYCODE_ESCAPE -> "Escape"
        KeyEvent.KEYCODE_DPAD_UP -> "ArrowUp"
        KeyEvent.KEYCODE_DPAD_DOWN -> "ArrowDown"
        KeyEvent.KEYCODE_DPAD_LEFT -> "ArrowLeft"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "ArrowRight"
        KeyEvent.KEYCODE_MOVE_HOME -> "Home"
        KeyEvent.KEYCODE_MOVE_END -> "End"
        KeyEvent.KEYCODE_PAGE_UP -> "PageUp"
        KeyEvent.KEYCODE_PAGE_DOWN -> "PageDown"
        else -> null
    }
    if (named != null) return TermInput.Key(named, ctrl = ctrl, alt = alt, shift = shift)
    val unicode = event.getUnicodeChar(event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK).inv())
    if (unicode == 0 || unicode and KeyCharacterMap.COMBINING_ACCENT != 0) return null
    val text = String(Character.toChars(unicode))
    val ascii = text.length == 1 && text[0].code in 0x20..0x7e
    return if ((ctrl || alt) && ascii) TermInput.Key(text, ctrl = ctrl, alt = alt) else TermInput.Text(text)
}

/**
 * Invisible focus target for the soft keyboard and hardware keys. Suggestions,
 * personalised learning and extract UI are off; nothing typed is kept or logged.
 */
@SuppressLint("ViewConstructor")
internal class TerminalInputView(context: Context, var onInput: (TermInput) -> Unit) : View(context) {
    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or EditorInfo.IME_ACTION_NONE
        return Connection(this)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val input = hardwareKey(event) ?: return super.onKeyDown(keyCode, event)
        onInput(input)
        return true
    }

    fun showKeyboard() {
        requestFocus()
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this, 0)
    }

    /** Committed text is sent once and cleared; composition stays local until committed. */
    private class Connection(private val view: TerminalInputView) : BaseInputConnection(view, true) {
        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
            super.commitText(text, newCursorPosition)
            flush()
            return true
        }

        override fun finishComposingText(): Boolean {
            super.finishComposingText()
            flush()
            return true
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            val buffer = editable
            if (buffer.isNullOrEmpty()) {
                repeat(beforeLength.coerceIn(0, 64)) { view.onInput(TermInput.Key("Backspace")) }
                return true
            }
            return super.deleteSurroundingText(beforeLength, afterLength)
        }

        override fun performEditorAction(actionCode: Int): Boolean {
            view.onInput(TermInput.Key("Enter"))
            return true
        }

        private fun flush() {
            val buffer = editable ?: return
            if (BaseInputConnection.getComposingSpanStart(buffer) >= 0) return
            val text = buffer.toString()
            buffer.clear()
            if (text.isNotEmpty()) view.onInput(TermInput.Text(text))
        }
    }
}

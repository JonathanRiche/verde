package dev.verdeai.app

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController

/** Puts the keyboard away and drops focus from the composer; null outside a chat. */
internal val LocalDismissKeyboard = compositionLocalOf<(() -> Unit)?> { null }

@Composable
internal fun rememberKeyboardDismiss(): () -> Unit {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    return remember(focus, keyboard) { { keyboard?.hide(); focus.clearFocus() } }
}

/**
 * A-KB: a tap on this area that no control consumed, or a user scroll inside it, dismisses the
 * keyboard. Rows and buttons keep their own taps; programmatic scrolls (following output) don't count.
 */
internal fun Modifier.dismissKeyboardOnTouch(dismiss: () -> Unit): Modifier = this
    .nestedScroll(object : NestedScrollConnection {
        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
            if (source == NestedScrollSource.UserInput && available.y != 0f) dismiss()
            return Offset.Zero
        }
    })
    .pointerInput(dismiss) {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Final)
            val up = waitForUpOrCancellation(PointerEventPass.Final)
            if (up != null && !up.isConsumed) dismiss()
        }
    }

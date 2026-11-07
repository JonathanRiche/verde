package dev.verdeai.app

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
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

/** The app shell's own focus target (A6-2): where focus rests when no control holds it. */
internal class ShellFocus(private val scope: CoroutineScope) {
    val requester = androidx.compose.ui.focus.FocusRequester()
    var parked by mutableStateOf(true)
    var pendingPark by mutableStateOf(false)
        private set
    private var parking: kotlinx.coroutines.Job? = null
    fun requestFocus() {
        parking?.cancel()
        parked = true
        pendingPark = true
        // Keep the native Compose view focused before the next hardware key arrives; otherwise
        // Android can spend that first Tab merely entering the view. Retry after properties settle.
        runCatching { requester.requestFocus() }
        parking = scope.launch {
            withFrameNanos { }
            runCatching { requester.requestFocus() }
            pendingPark = false
        }
    }
    fun release() {
        parking?.cancel()
        pendingPark = false
        parked = false
    }
}
internal val LocalShellFocus = compositionLocalOf<ShellFocus?> { null }

@Composable
internal fun rememberKeyboardDismiss(): () -> Unit {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val shell = LocalShellFocus.current
    // A6-2: focus rests on the shell, not nowhere, so a later Space or Enter can't wake the first
    // control (Back) and press it.
    return remember(focus, keyboard, shell) { { keyboard?.hide(); focus.clearFocus(); shell?.let { runCatching { it.requestFocus() } } } }
}

/**
 * A-KB: a tap on this area that no control consumed, or a user scroll inside it, dismisses the
 * keyboard. Rows and buttons keep their own taps; programmatic scrolls (following output) don't count,
 * and neither do scrolls with no finger down (S29: Tab bringing a focused row into view must not
 * drop the focus it just moved).
 */
internal fun Modifier.dismissKeyboardOnTouch(dismiss: () -> Unit): Modifier = composed {
    val touching = remember { booleanArrayOf(false) }
    this
        .nestedScroll(remember(dismiss) {
            object : NestedScrollConnection {
                override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                    if (touching[0] && source == NestedScrollSource.UserInput && available.y != 0f) dismiss()
                    return Offset.Zero
                }
            }
        })
        .pointerInput(Unit) {
            awaitPointerEventScope {
                while (true) touching[0] = awaitPointerEvent(PointerEventPass.Initial).changes.any { it.pressed }
            }
        }
        .pointerInput(dismiss) {
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Final)
                val up = waitForUpOrCancellation(PointerEventPass.Final)
                if (up != null && !up.isConsumed) dismiss()
            }
        }
}

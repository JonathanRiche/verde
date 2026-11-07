package dev.verdeai.app

import androidx.compose.foundation.focusGroup
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties

/** Link regions before Compose wraps its search inside a navigation destination. Keep the entry
 * direction: returning a group requester from the old exit API always enters its first child. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
internal fun Modifier.keyboardRegion(next: FocusRequester, previous: FocusRequester = FocusRequester.Default): Modifier =
    focusProperties {
        onExit = {
            val direction = requestedFocusDirection
            val target = when (direction) {
                FocusDirection.Next -> next
                FocusDirection.Previous -> previous
                else -> FocusRequester.Default
            }
            if (target != FocusRequester.Default) target.requestFocus(direction)
        }
    }.focusGroup()

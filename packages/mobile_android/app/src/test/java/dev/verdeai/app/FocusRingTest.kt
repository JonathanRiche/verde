package dev.verdeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class FocusRingTest {
    @get:Rule val compose = createComposeRule()

    @Test fun dialogCoordinatesAndDetachedCoordinatesCannotCrashTheActivityRing() {
        lateinit var activity: LayoutCoordinates
        lateinit var child: LayoutCoordinates
        lateinit var dialog: LayoutCoordinates
        var open by mutableStateOf(true)
        compose.setContent {
            Box(Modifier.onGloballyPositioned { activity = it }) {
                Box(Modifier.size(48.dp).onGloballyPositioned { child = it }) { Text("Activity") }
            }
            if (open) Dialog(onDismissRequest = { open = false }) {
                Box(Modifier.size(48.dp).onGloballyPositioned { dialog = it }) { Text("Dialog") }
            }
        }
        compose.runOnIdle {
            assertNotNull(focusRingBounds(activity, child))
            assertNull(focusRingBounds(activity, dialog))
            open = false
        }
        compose.waitForIdle()
        compose.runOnIdle { assertNull(focusRingBounds(activity, dialog)) }
    }
}

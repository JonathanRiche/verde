package dev.verdeai.app

import android.view.View
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.window.Dialog
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ModalLayersLayoutTest {
    @get:Rule val compose = createComposeRule()

    @Test fun modalHookWorksWithoutLiveAndOnlyTheFrontSheetHasAHandle() {
        var parent by mutableStateOf(true)
        var child by mutableStateOf(false)
        lateinit var background: View
        lateinit var sheet: View
        lateinit var dialog: View
        var backgroundOriginal = 0
        var sheetOriginal = 0
        var dialogOriginal = 0
        compose.setContent {
            CompositionLocalProvider(LocalModalLayers provides remember { ModalLayers() }) {
                background = LocalView.current.rootView
                backgroundOriginal = remember(background) { background.importantForAccessibility }
                Text("Background")
                if (parent) Dialog(onDismissRequest = {}) {
                    sheet = LocalView.current.rootView
                    sheetOriginal = remember(sheet) { sheet.importantForAccessibility }
                    LiveOverModal()
                    TopModalDragHandle { Text("Grabber") }
                    if (child) Dialog(onDismissRequest = {}) {
                        dialog = LocalView.current.rootView
                        dialogOriginal = remember(dialog) { dialog.importantForAccessibility }
                        LiveOverModal()
                        TopModalDragHandle { Text("Grabber") }
                    }
                }
            }
        }
        compose.onAllNodesWithText("Grabber").assertCountEquals(1)
        compose.runOnIdle {
            assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, background.importantForAccessibility)
            child = true
        }
        compose.onAllNodesWithText("Grabber").assertCountEquals(1)
        compose.runOnIdle {
            assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, sheet.importantForAccessibility)
            assertEquals(dialogOriginal, dialog.importantForAccessibility)
            child = false
        }
        compose.onAllNodesWithText("Grabber").assertCountEquals(1)
        compose.runOnIdle {
            assertEquals(sheetOriginal, sheet.importantForAccessibility)
            parent = false
        }
        compose.onAllNodesWithText("Grabber").assertCountEquals(0)
        compose.runOnIdle { assertEquals(backgroundOriginal, background.importantForAccessibility) }
    }
}

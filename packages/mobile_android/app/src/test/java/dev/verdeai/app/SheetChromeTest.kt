package dev.verdeai.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalMaterial3Api::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SheetChromeTest {
    @get:Rule val compose = createComposeRule()
    @Test fun closeStaysAboveLongContentAndHasNoDuplicateScrimTarget() {
        var closed = 0
        compose.setContent {
            VerdeTheme {
                var open by remember { mutableStateOf(true) }
                if (open) {
                    val dismiss = { closed++; open = false }
                    ModalBottomSheet(onDismissRequest = dismiss, scrimColor = Color.Unspecified,
                        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
                        SheetDismissBackdrop(dismiss)
                        Column(Modifier.height(450.dp)) {
                            SheetHeader("Settings", dismiss)
                            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).testTag("body")) {
                                repeat(40) { Text("Setting $it", Modifier.height(48.dp)) }
                            }
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
        val close = compose.onNodeWithContentDescription("Close")
        val top = close.getUnclippedBoundsInRoot().top
        compose.onNodeWithText("Setting 39").performScrollTo().assertIsDisplayed()
        compose.waitForIdle()
        assertEquals(top, close.getUnclippedBoundsInRoot().top)
        close.assertTouchHeightIsEqualTo(48.dp).assertTouchWidthIsEqualTo(48.dp)
        compose.onNodeWithContentDescription("Close sheet").assertDoesNotExist()
        close.assertIsDisplayed().performSemanticsAction(SemanticsActions.OnClick) { it() }
        compose.waitForIdle()
        assertEquals(1, closed)
        compose.onNodeWithContentDescription("Close").assertDoesNotExist()
    }
}

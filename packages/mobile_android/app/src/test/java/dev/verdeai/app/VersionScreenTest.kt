package dev.verdeai.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class VersionScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun showsSuppliedCoreVersion() {
        // Android JNI is exercised on device; the host JVM tests the actual UI.
        compose.setContent { VersionScreen("0.1.0-fixture") }
        compose.onNodeWithText("Core version: 0.1.0-fixture").assertIsDisplayed()
    }
}

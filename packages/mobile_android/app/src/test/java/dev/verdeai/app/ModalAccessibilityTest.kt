package dev.verdeai.app

import android.view.View
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class ModalAccessibilityTest {
    private fun view() = View(RuntimeEnvironment.getApplication())

    @Test fun nestedModalHidesBothBackgroundsAndRestoresTheirOriginalValues() {
        val background = view().apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES }
        val sheet = view()
        val dialog = view()
        val layers = ModalLayers()
        layers.add(background, sheet)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, background.importantForAccessibility)
        assertFalse(layers.covered(sheet))
        layers.add(background, dialog)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, sheet.importantForAccessibility)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, dialog.importantForAccessibility)
        assertTrue(layers.covered(sheet))
        layers.remove(dialog)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, sheet.importantForAccessibility)
        assertFalse(layers.covered(sheet))
        layers.remove(sheet)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_YES, background.importantForAccessibility)
    }

    @Test fun duplicateRegistrationAndParentFirstDismissalKeepTheBackgroundHidden() {
        val background = view()
        val sheet = view()
        val dialog = view()
        val layers = ModalLayers()
        layers.add(background, sheet)
        layers.add(background, sheet)
        layers.add(background, dialog)
        layers.remove(sheet)
        assertTrue(layers.covered(sheet))
        layers.remove(sheet)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, background.importantForAccessibility)
        layers.remove(dialog)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, background.importantForAccessibility)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, sheet.importantForAccessibility)
    }
}

package dev.verdeai.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** S4/S7/S8 presentation rules shared with iOS. */
class ScreenSpecTest {
    @Test fun themeHelperDescribesTheCurrentChoice() {
        assertTrue(themeHelperText(AppearanceMode.SYSTEM).startsWith("Follows your phone"))
        assertTrue(themeHelperText(AppearanceMode.DARK).startsWith("Always dark"))
        assertTrue(themeHelperText(AppearanceMode.TOKYO_NIGHT).startsWith("Tokyo Night"))
    }

    @Test fun rowStatesMapToTheSharedColourRoles() {
        assertEquals(RowState.Working, rowState("working", false))
        assertEquals(RowState.NeedsYou, rowState("waiting_approval", false))
        assertEquals(RowState.NeedsYou, rowState("idle", attention = true))
        assertEquals(RowState.Failed, rowState("failed", true))
        assertEquals(RowState.Quiet, rowState("completed", false))
        assertEquals(RowState.Quiet, rowState("idle", false))
    }

    @Test fun workspaceSwatchesHaveSpokenNames() {
        val names = (0 until 8).map { colorName(workspaceColor(it)) }
        assertEquals(8, names.distinct().size)
        assertEquals("Green", names[0])
    }

    @Test fun versionLabelNamesBuild() {
        assertEquals("0.1.0 (7)", appVersionLabel("0.1.0", 7))
    }

    @Test fun folderChipsNeverReadTheSame() {
        val paths = listOf("/tmp/r/demo", "/tmp/r/demo/project", "/tmp/r/x/scripts/demo", "/tmp/r/y/scripts/demo", "/")
        val labels = folderChipLabels(paths)
        assertEquals("…/r/demo", labels["/tmp/r/demo"])
        assertEquals("project", labels["/tmp/r/demo/project"])
        assertEquals("…/x/scripts/demo", labels["/tmp/r/x/scripts/demo"])
        assertEquals("…/y/scripts/demo", labels["/tmp/r/y/scripts/demo"])
        assertEquals("/", labels["/"])
        assertEquals(paths.size, labels.values.distinct().size)
    }
}

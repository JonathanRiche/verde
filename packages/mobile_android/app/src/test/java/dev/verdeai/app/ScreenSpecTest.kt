package dev.verdeai.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
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

    @Test fun sharedWorkspaceNamesGetTheirParentFolder() {
        fun ws(id: String, label: String, path: String) = dev.verdeai.core.Workspace(id, label, path, open = false, panes = emptyList(), threads = emptyList())
        val labels = workspaceLabels(listOf(ws("a", "scripts", "/tmp/x/demo/scripts"), ws("b", "scripts", "/tmp/y/nope/scripts"),
            ws("c", "scripts", "/tmp/y/nope/scripts"), ws("d", "web", "/srv/web")))
        assertEquals("web", labels["d"])
        assertEquals("scripts · demo", labels["a"])
        assertEquals("scripts · nope", labels["b"])
        assertEquals("scripts · nope (2)", labels["c"])
    }

    @Test fun textRolesReadOnEverySurface() {
        for (p in listOf(DarkPalette, LightPalette).map { it.readable() }) {
            for (fg in listOf(p.Subtle, p.Muted, p.Accent, p.Warning, p.Danger, p.Text)) for (bg in listOf(p.Background, p.Panel)) {
                assertTrue("contrast ${contrast(fg, bg)}", contrast(fg, bg) >= 4.5f)
            }
            assertTrue(contrast(p.Subtle, p.PanelAlt) >= 4.5f)
        }
    }

    @Test fun licencesReflowAndHaveNoPlaceholders() {
        assertEquals("one two\n\nthree", reflowLicence("one\ntwo\n\n three \n"))
        // Headings stand alone; rulers never land inside a paragraph.
        assertEquals(listOf("SIL OPEN FONT LICENSE Version 1.1", "PREAMBLE", "The goals of the OFL are good."),
            licenceParagraphs("-----\nSIL OPEN FONT LICENSE Version 1.1\n-----\n\nPREAMBLE\nThe goals of the\nOFL are good.\n"))
    }

    @Test fun addWorkspaceDropsClosedWorkspaceFolders() {
        fun ws(id: String, path: String, open: Boolean) = dev.verdeai.core.Workspace(id, id, path, open = open, panes = emptyList(), threads = emptyList())
        val workspaces = listOf(ws("demo", "/r/demo/project", true), ws("s1", "/r/x/demo/scripts/demo", false), ws("s2", "/r/nope/scripts/demo", false))
        val suggestions = listOf("/r/demo", "/r/demo/project", "/r/x/demo/scripts/demo", "/r/nope/scripts/demo", "/home/me")
        assertEquals(listOf("/r/demo", "/r/demo/project", "/home/me"), freshFolderSuggestions(suggestions, workspaces))
    }

    @Test fun imagePickerTypesAreJudgedByContent() {
        assertTrue(ImageAttachments.plausibleImageType(null))
        assertTrue(ImageAttachments.plausibleImageType("image/png"))
        assertTrue(ImageAttachments.plausibleImageType("application/octet-stream"))
        assertFalse(ImageAttachments.plausibleImageType("video/mp4"))
    }

    @Test fun picturesAreReadToTheEndHoweverShortTheReads() {
        val data = ByteArray(200_000) { (it % 251).toByte() }
        // A provider stream that hands out a few bytes at a time, with the odd empty read.
        val trickle = object : java.io.InputStream() {
            var pos = 0; var calls = 0
            override fun read(): Int = if (pos < data.size) data[pos++].toInt() and 0xff else -1
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (pos >= data.size) return -1
                calls++
                if (calls % 5 == 0) return 0
                val n = minOf(len, 1 + calls % 7, data.size - pos)
                System.arraycopy(data, pos, b, off, n); pos += n; return n
            }
            override fun available() = 1
        }
        val read = ImageAttachments.readFully(trickle)
        assertTrue(read != null && read.contentEquals(data))
        assertEquals(null, ImageAttachments.readFully(java.io.ByteArrayInputStream(data), limit = 1000))
    }

    @Test fun theFooterMarksWhereYouAre() {
        assertEquals(Routes.SECURITY, footerTab(Routes.SECURITY))
        assertEquals(Routes.WORKSPACES, footerTab(Routes.THREAD))
        assertEquals(Routes.HOME, footerTab(ManageRoutes.HISTORY))
        assertEquals(Routes.HOSTS, footerTab(Routes.HOSTS))
    }
}

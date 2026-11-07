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
        // V: TalkBack's names are distinct in every theme (a repeat is numbered, as on iOS).
        listOf(DarkPalette.Accent, LightPalette.Accent).forEach { accent ->
            val spoken = workspaceColorNames(accent)
            assertEquals(spoken.toString(), 8, spoken.distinct().size)
        }
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

    @Test fun workspaceRowsNameTheirParentFolderOnly() {
        fun ws(id: String, label: String, path: String) = dev.verdeai.core.Workspace(id, label, path, open = true, panes = emptyList(), threads = emptyList())
        val parents = workspaceParents(listOf(ws("a", "scripts", "/tmp/x/demo/scripts"), ws("b", "scripts", "/tmp/y/nope/scripts"),
            ws("d", "web", "/srv/site/web")))
        assertEquals("demo", parents["a"])
        assertEquals("nope", parents["b"])
        assertEquals("site", parents["d"])
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

    /** The footer highlight follows the current screen's type, the same fixed mapping as iOS. */
    @Test fun footerHighlightsTheCurrentScreensType() {
        listOf(Routes.THREAD, Routes.FILES, Routes.CHANGES, Routes.PATCH, Routes.FILE, Routes.WORKSPACE_FILE, Routes.TERMINAL,
            Routes.NEW_TERMINAL, Routes.WORKSPACES, Routes.WORKSPACE).forEach { assertEquals(it, Routes.WORKSPACES, footerTab(it)) }
        listOf(Routes.HOME, ManageRoutes.HISTORY, ManageRoutes.NEW_CHAT, ManageRoutes.NEW_CHAT_IN).forEach { assertEquals(it, Routes.HOME, footerTab(it)) }
        assertEquals(Routes.SECURITY, footerTab(Routes.SECURITY))
        assertEquals(Routes.HOSTS, footerTab(Routes.HOSTS))
        assertEquals("", footerTab(null))
    }

    /** A11-3: History reads the live last activity, so a filtered list keeps All's ages and order. */
    @Test fun historyUsesLiveLastActivity() {
        fun t(id: String, at: Long) = dev.verdeai.core.ThreadSummary("ws", id, id, "codex", null, null, open = true, archived = false,
            last_activity_at_ms = at, status = "idle", history_bucket = "Today")
        val stale = listOf(t("a", 300), t("b", 200))
        val live = mapOf(("ws" to "b") to t("b", 900))
        val rows = historySections(stale, live).single().second
        assertEquals(listOf("b", "a"), rows.map { it.thread_id })
        assertEquals(900L, rows.first().last_activity_at_ms)
    }

    /** A7-2: a filtered History groups and orders by the live time, as All does. */
    @Test fun historyRegroupsByLiveTime() {
        val now = 10L * 86_400_000L
        fun t(id: String, at: Long, bucket: String) = dev.verdeai.core.ThreadSummary("ws", id, id, "codex", null, null, open = true, archived = false,
            last_activity_at_ms = at, status = "idle", history_bucket = bucket)
        val stale = listOf(t("sprout", now - 3 * 3_600_000L, "Today"), t("deploy", now - 3 * 86_400_000L, "This week"))
        val live = mapOf(("ws" to "deploy") to t("deploy", now - 3 * 60_000L, "This week"))
        val sections = historySections(stale, live, now)
        assertEquals(listOf("Today"), sections.map { it.first })
        assertEquals(listOf("deploy", "sprout"), sections.single().second.map { it.thread_id })
    }

    /** A7-1: unseen failures are named on the bubble beside the needs-you count, and ring red alone. */
    @Test fun bubbleNamesFailures() {
        assertEquals("Sprout, nothing needs you", bubbleDescription("Sprout", 0))
        assertEquals("Sprout, 1 chat failed", bubbleDescription("Sprout", 0, failed = 1))
        assertEquals("Sprout, 2 chats failed", bubbleDescription("Sprout", 0, failed = 2))
        assertEquals("Sprout, 1 needs you, 1 failed", bubbleDescription("Sprout", 1, failed = 1))
        assertEquals("Sprout, 1 thing needs you", bubbleDescription("Sprout", 1))
    }
}

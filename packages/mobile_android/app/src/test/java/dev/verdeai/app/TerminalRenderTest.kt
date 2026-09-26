package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.serialization.decodeFromString
import org.junit.Assert.*
import org.junit.Test

/** Pure terminal presentation rules over the committed real-VT snapshot (fixtures/k12). */
class TerminalRenderTest {
    private val snapshot: TerminalSnapshot = CoreJson.decodeFromString(
        TerminalRenderTest::class.java.getResource("/fixtures/k12/snapshot.json")!!.readText())

    @Test fun gridFitsTheViewWithinCoreLimits() {
        val metrics = CellMetrics(10f, 20f, 16f)
        assertEquals(41 to 30, terminalGrid(415f, 610f, metrics))
        assertEquals(1 to 1, terminalGrid(0f, 0f, metrics))
        assertEquals(512 to 128, terminalGrid(1e6f, 128f * 20f, metrics))
        // 512 rows leave room for only 128 columns under the 65,536-cell cap.
        assertEquals(128 to 512, terminalGrid(1e6f, 1e6f, CellMetrics(1f, 1f, 1f)))
    }

    @Test fun planUsesVtColorsAttributesWideCellsAndCursor() {
        val plan = renderPlan(snapshot)
        assertEquals(0xff000000.toInt(), plan.background)
        assertTrue(plan.backgrounds.isEmpty())
        assertEquals(listOf("R", "E", "D"), plan.texts.filter { it.row == 0 }.map { it.text })
        assertTrue(plan.texts.filter { it.row == 0 }.all { it.bold && it.fg == 0xffcc6666.toInt() })
        val wide = plan.texts.single { it.text == "界" }
        assertEquals(2, wide.cells)
        // The spacer after a wide glyph is never drawn; the combining sequence stays one cell.
        assertEquals(listOf(0, 1, 2, 3, 4, 6, 9), plan.texts.filter { it.row == 1 }.map { it.col })
        assertEquals("e\u0301", plan.texts.single { it.row == 1 && it.col == 9 }.text)
        assertEquals(CursorBox(2, 0, 1, TerminalCursorShape.block, 0xffffffff.toInt(), 0xff000000.toInt()), plan.cursor)
    }

    @Test fun inverseRunsAndScrolledCursor() {
        val cells = snapshot.cells.toMutableList()
        for (i in 20 until 25) cells[i] = cells[i].copy(inverse = true)
        cells[45] = cells[45].copy(bg = "#112233")
        val plan = renderPlan(snapshot.copy(cells = cells, scroll_offset = 3))
        assertEquals(listOf(BgRun(1, 0, 5, 0xffffffff.toInt()), BgRun(2, 5, 1, 0xff112233.toInt())), plan.backgrounds)
        assertEquals(0xff000000.toInt(), plan.texts.first { it.row == 1 }.fg)
        assertNull(plan.cursor)
        assertNull(renderPlan(snapshot.copy(cursor = snapshot.cursor.copy(visible = false))).cursor)
        assertEquals(0xff123456.toInt(), parseColor("#123456", 0))
        assertEquals(7, parseColor("red", 7))
    }

    @Test fun selectionIsLinearInEitherDirectionAndTrimsLines() {
        assertEquals("RED\nwide: 界 e\u0301", selectedText(snapshot, GridSelection(1, 19, 0, 0)))
        assertEquals("ED", selectedText(snapshot, GridSelection(0, 1, 0, 2)))
        assertEquals("", selectedText(snapshot, GridSelection(3, 0, 3, 19)))
        assertTrue(GridSelection(1, 3, 0, 5).contains(0, 19))
        assertFalse(GridSelection(1, 3, 0, 5).contains(1, 4))
    }

    @Test fun stickyModifiersAndNewlinesBecomeCoreKeys() {
        assertEquals(listOf(TermInput.Key("c", ctrl = true)), withModifiers(TermInput.Text("c"), ctrl = true, alt = false))
        assertEquals(listOf(TermInput.Key("ArrowUp", alt = true)), withModifiers(TermInput.Key("ArrowUp"), ctrl = false, alt = true))
        assertEquals(listOf(TermInput.Text("ab")), withModifiers(TermInput.Text("ab"), ctrl = true, alt = false))
        assertEquals(listOf(TermInput.Paste("a\nb")), withModifiers(TermInput.Paste("a\nb"), ctrl = true, alt = true))
        assertEquals(listOf(TermInput.Text("ls"), TermInput.Key("Enter"), TermInput.Key("Enter"), TermInput.Text("x")), splitLines("ls\n\nx"))
    }

    @Test fun noticesFollowConnectionAndSessionState() {
        val host = HostView("a", "Studio", null, null, null, "ready", Lifecycle.foreground, "paired", "ready",
            emptyList(), listOf("terminal:read", "terminal:write"), null, null, false, null)
        val browse = BrowseState("a", HostRow(SavedHost("a", "Studio"), host))
        val view = TerminalView("sess-7", "ws", "htop", "running", true, 80, 24, "10", "1", false, null)
        val live = TerminalUiState("sess-7", view, snapshot)
        assertNull(terminalNotice(live, browse, "a"))
        assertEquals("You're offline. Showing the last screen; input is paused.", terminalNotice(live, browse.copy(networkAvailable = false), "a"))
        assertTrue(terminalNotice(live, browse.copy(row = browse.row!!.copy(view = host.copy(phase = "connecting"))), "a")!!.startsWith("Reconnecting"))
        assertTrue(terminalNotice(live, browse, "b")!!.contains("another host"))
        assertEquals("Opening a new terminal…", terminalNotice(TerminalUiState(), browse, "a"))
        assertEquals("Opening terminal…", terminalNotice(live.copy(view = null), browse, "a"))
        assertEquals("The session has ended.", terminalNotice(live.copy(view = view.copy(session_status = "exited")), browse, "a"))
        assertEquals("Starting shell…", terminalNotice(live.copy(view = view.copy(session_status = "starting")), browse, "a"))
        val gone = view.copy(attached = false, error = LocalError(domain = "rpc", code = "not_found", message = ""))
        assertEquals("This terminal is no longer available.", terminalNotice(live.copy(view = gone), browse, "a"))
        assertTrue(terminalNotice(live, browse.copy(row = browse.row!!.copy(view = host.copy(scopes = listOf("terminal:read")))), "a")!!.startsWith("View only"))
        assertEquals("Reconnected. Some earlier output may be missing.", terminalNotice(live.copy(replayGap = true), browse, "a"))
        assertEquals("Couldn't open a terminal.", terminalNotice(live.copy(failure = "Couldn't open a terminal."), browse.copy(networkAvailable = false), "a"))
    }
}

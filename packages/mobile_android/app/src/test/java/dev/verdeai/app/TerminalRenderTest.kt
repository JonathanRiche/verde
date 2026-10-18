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
}

package dev.verdeai.core

import dev.verdeai.app.GridSelection
import dev.verdeai.app.renderPlan
import dev.verdeai.app.selectedText
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/**
 * JNI-level checks against the real core on the host JVM (`zig build jvm-lib`), using the
 * recorded K-12 daemon tail. Plain JUnit on purpose: Robolectric sandboxes would load the
 * native library once per class loader.
 */
class TerminalJniTest {
    private val fixtures = File(System.getProperty("verde.core.fixtures")!!, "terminal")
    private fun tail(): ByteArray = CoreJson.parseToJsonElement(File(fixtures, "tail.json").readText())
        .jsonObject["text"]!!.jsonPrimitive.content.encodeToByteArray()
    private fun expected(): TerminalSnapshot = CoreJson.decodeFromString(
        TerminalJniTest::class.java.getResource("/fixtures/k12/snapshot.json")!!.readText())

    @Test fun recordedTailRendersTheCommittedSnapshotThroughJni() = runBlocking {
        val vt = TerminalVt(JniTerminalBridge, scrollbackRows = 100)
        try {
            val applied = vt.apply(reset = true, bytes = tail(), cols = 20, rows = 4)
            assertNull(applied.error)
            val snapshot = vt.snapshot.value!!
            assertEquals(expected(), snapshot)
            assertEquals(applied.gridRevision, snapshot.revision)
            assertEquals(1, vt.resets.value)
            // The same grid drives the canvas plan: bold red text, one wide glyph, block cursor.
            val plan = renderPlan(snapshot)
            assertEquals(20, plan.cols)
            val red = plan.texts.first { it.row == 0 && it.col == 0 }
            assertEquals("R", red.text)
            assertTrue(red.bold)
            assertEquals(0xffcc6666.toInt(), red.fg)
            assertEquals(2, plan.texts.single { it.text == "界" }.cells)
            assertEquals(2, plan.cursor!!.row)
            assertEquals("RED\nwide: 界 e\u0301", selectedText(snapshot, GridSelection(0, 0, 1, 19)))
        } finally { vt.close() }
    }

    @Test fun deviceRepliesResizeAndScrollbackRoundTrip() = runBlocking {
        val replies = CopyOnWriteArrayList<String>()
        val vt = TerminalVt(JniTerminalBridge, scrollbackRows = 100) { replies += it.decodeToString() }
        try {
            vt.apply(reset = true, bytes = tail(), cols = 20, rows = 4)
            // A cursor-position request is answered by the VT and drained with the snapshot.
            vt.apply(reset = false, bytes = "\u001b[6n".encodeToByteArray(), cols = 20, rows = 4)
            assertEquals(listOf("\u001b[3;1R"), replies)
            vt.resize(30, 6)
            assertEquals(30, vt.snapshot.value!!.cols)
            assertEquals(6, vt.snapshot.value!!.rows)
            // Output that scrolls, then page back into history and return to the live screen.
            val lines = (1..40).joinToString("") { "line $it\r\n" }.encodeToByteArray()
            vt.apply(reset = false, bytes = lines, cols = 30, rows = 6)
            assertTrue(vt.snapshot.value!!.scrollback_rows > 0)
            vt.scroll(3)
            assertEquals(3L, vt.snapshot.value!!.scroll_offset)
            assertNull(renderPlan(vt.snapshot.value!!).cursor)
            vt.scroll(-3)
            assertEquals(0L, vt.snapshot.value!!.scroll_offset)
            // A reset replay recreates the emulator at the core's size.
            vt.apply(reset = true, bytes = tail(), cols = 20, rows = 4)
            assertEquals(2, vt.resets.value)
            assertEquals(expected().cells, vt.snapshot.value!!.cells)
        } finally { vt.close() }
    }

    @Test fun selectorsMatchTheCorePercentEncoding() {
        assertEquals("terminal:sess-7", terminalSelector("sess-7"))
        assertEquals("terminal:mobile%3Aabc%3A1", terminalSelector("mobile:abc:1"))
        assertEquals("terminal:session%3A%252F%2Fone", terminalSelector("session:%2F/one"))
        assertEquals("terminal:%E7%95%8C", terminalSelector("界"))
    }
}

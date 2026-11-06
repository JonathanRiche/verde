package dev.verdeai.app

import dev.verdeai.core.ChatRow
import dev.verdeai.core.ChatTool
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolRowsTest {
    private fun row(author: String, body: String, kind: String? = null, status: String = "completed") =
        ChatRow(id = "r", role = "system", kind = "tool", author = author, body = body,
            tool = kind?.let { ChatTool(id = "t", kind = it, status = status) })

    @Test fun kindsComeFromTheCoreTagThenTheAuthor() {
        assertEquals(ToolKind.Edit, toolKind(row("Edit", "x", "edit")))
        assertEquals(ToolKind.Fetch, toolKind(row("Whatever", "x", "fetch")))
        assertEquals(ToolKind.Other, toolKind(row("Mystery", "x", "unknown_kind")))
        assertEquals(ToolKind.Execute, toolKind(row("Ran command", "ls -la")))
        assertEquals(ToolKind.Execute, toolKind(row("Command failed", "exit 1")))
        assertEquals(ToolKind.Subagent, toolKind(row("Subagent", "x")))
    }

    @Test fun legacyRowsFallBackToAuthorAndBody() {
        val display = toolDisplay(row("Ran command", "git status\n\n M a.txt"))
        assertEquals("Ran command", display.title)
        assertEquals("git status M a.txt", display.summary)
        assertFalse(display.sectioned)
        assertEquals("Tool", toolDisplay(row("", "x")).title)
    }

    @Test fun coreFieldsWinOverTheBody() {
        val r = ChatRow(id = "r", role = "system", kind = "tool", author = "Edit", body = "Tool:\nEdit `src/a.ts`\n\nInput:\n{}",
            tool = ChatTool(id = "t", kind = "edit", status = "completed", title = "Edit", summary = "src/a.ts",
                input = "{\"path\":\"src/a.ts\"}", output = "@@ -1 +1 @@\n-a\n+b"))
        val display = toolDisplay(r)
        assertEquals(ToolKind.Edit, display.kind)
        assertEquals("Edit", display.title)
        assertEquals("src/a.ts", display.summary)
        assertTrue(display.sectioned)
        assertEquals("@@ -1 +1 @@\n-a\n+b", toolCopyText(display, r))
        assertEquals("Completed, Edit, src/a.ts", toolRowLabel(display, r))
        // A titled row without a summary never falls back to the raw body.
        val titled = r.copy(tool = r.tool!!.copy(summary = null))
        assertNull(toolDisplay(titled).summary)
    }

    @Test fun labelsPairStatusWithTitleAndSummary() {
        val failed = row("Ran command", "make", "execute", status = "failed")
        assertEquals("Failed, Ran command, make", toolRowLabel(toolDisplay(failed), failed))
        val running = row("Read", "a.txt", "read", status = "in_progress")
        assertEquals("Running", toolStatusLabel(running))
    }

    @Test fun editOutputIsRecognisedAsADiff() {
        assertTrue(looksLikeDiff("@@ -1,2 +1,2 @@\n-a\n+b"))
        assertTrue(looksLikeDiff("--- a/x\n+++ b/x\n-a\n+b"))
        assertFalse(looksLikeDiff("- a bullet\n- another"))
        assertEquals(DiffLineKind.Hunk, diffLineKind("@@ -1 +1 @@"))
        assertEquals(DiffLineKind.Meta, diffLineKind("+++ b/x"))
        assertEquals(DiffLineKind.Add, diffLineKind("+b"))
        assertEquals(DiffLineKind.Delete, diffLineKind("-a"))
        assertEquals(DiffLineKind.Context, diffLineKind(" c"))
    }

    @Test fun groupSummaryCountsCallsAndFailures() {
        val rows = listOf(row("Read", "a", "read"), row("Edit", "b", "edit", status = "failed"),
            row("Search", "c", "search"), row("Ran command", "d", "execute"))
        assertEquals("4 tool calls · 1 failed", toolGroupSummary(rows, subagent = false, elapsed = null))
        val running = listOf(row("Read", "a", "read"), row("Edit", "b", "edit", status = "in_progress"))
        assertEquals("2 tool calls · 1 running · 0:05", toolGroupSummary(running, subagent = false, elapsed = "0:05"))
        assertNull(toolDisplay(row("Read", "", "read")).summary)
    }
}

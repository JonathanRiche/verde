package dev.verdeai.app

import dev.verdeai.core.*
import org.junit.Assert.*
import org.junit.Test

class HistoryCompanionTest {
    @Test fun rosterHidesCurrentAndPastConversationsBeforeGroupingWithoutHidingNamesakes() {
        val roster = CompanionRoster(companions = listOf(
            CompanionEntry("c", "Sprout", thread_id = "current", history = listOf(CompanionPastConversation("past"))),
            CompanionEntry("other", "Fern", thread_id = "fern"),
        ))
        fun row(id: String, title: String, at: Long) = ThreadSummary("ws", id, title, "codex", null, null,
            open = true, archived = false, last_activity_at_ms = at, status = "idle", history_bucket = "Today")
        val rows = listOf(row("current", "Sprout", 90), row("past", "Earlier", 80), row("fern", "Fern", 70),
            row("regular", "Sprout", 50), row("older", "Regular chat", 40))
        val hidden = companionThreadIds(roster)
        val sections = historySections(rows, nowMs = 100, hidden = hidden)
        assertEquals(listOf("regular", "older"), sections.single().second.map { it.thread_id })
        assertEquals(listOf("regular"), historySections(rows.filter { it.title == "Sprout" }, nowMs = 100, hidden = hidden).single().second.map { it.thread_id })
        assertTrue(historySections(rows.take(3), nowMs = 100, hidden = hidden).isEmpty())
    }
}

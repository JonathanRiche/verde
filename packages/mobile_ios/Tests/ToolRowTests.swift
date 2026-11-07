import XCTest
@testable import VerdeApp

/// S2 tool-row content: parsed parts, summaries, kinds and the group summary.
final class ToolRowTests: XCTestCase {
    private func row(_ author: String, _ body: String, kind: String? = nil, status: String = "completed") -> ChatRow {
        ChatRow(id: "r-\(author)", role: "system", kind: "tool", author: author, body: body,
                tool: kind.map { ChatTool(id: "t", kind: $0, status: status) })
    }

    func testSectionsAndSummaryFromBody() {
        let edit = row("Edit", "Tool:\nEdit `src/reconnect.ts`\n\nInput:\n{\"path\":\"src/reconnect.ts\"}\n\nOutput:\n@@ -1 +1 @@\n-a\n+b", kind: "edit")
        let parts = toolParts(edit)
        XCTAssertEqual(parts.kind, "edit")
        XCTAssertEqual(parts.title, "Edit")
        XCTAssertEqual(parts.summary, "src/reconnect.ts")
        XCTAssertEqual(parts.input, "{\"path\":\"src/reconnect.ts\"}")
        XCTAssertEqual(parts.output, "@@ -1 +1 @@\n-a\n+b")
        XCTAssertNil(parts.error)
        XCTAssertTrue(toolOutputIsDiff(parts))
        XCTAssertEqual(toolDiffLine("@@ -1 +1 @@"), .hunk)
        XCTAssertEqual(toolDiffLine("+b"), .add)
        XCTAssertEqual(toolDiffLine("-a"), .delete)
        XCTAssertEqual(toolDiffLine(" c"), .context)
    }

    func testCommandRowsAndRawBodies() {
        let failed = row("Command failed", "Input:\nbun run lint\n\nOutput:\nerror: missing JSDoc")
        let parts = toolParts(failed)
        XCTAssertEqual(parts.kind, "execute")
        XCTAssertEqual(parts.summary, "bun run lint")
        XCTAssertFalse(toolOutputIsDiff(parts))
        let raw = toolParts(row("Ran command", "/bin/bash -lc 'ls -la'\ntotal 0"))
        XCTAssertEqual(raw.summary, "/bin/bash -lc 'ls -la'")
        XCTAssertEqual(raw.output, "/bin/bash -lc 'ls -la'\ntotal 0")
        XCTAssertEqual(toolInputSummary("{\"command\":[\"git\",\"status\"]}"), "git status")
        XCTAssertEqual(toolInputSummary("{\"other\":1}"), "")
        XCTAssertEqual(toolSymbol("search"), "magnifyingglass")
        XCTAssertEqual(toolSymbol("unknown"), "wrench")
    }

    func testCoreToolFieldsWinOverTheBody() {
        var edit = row("Edit", "Tool:\nEdit\n\nInput:\n{\"path\":\"a.ts\"}", kind: "edit")
        edit.tool = ChatTool(id: "t", kind: "edit", status: "completed", title: "Edit file", summary: "src/a.ts",
                             input: "{\"path\":\"src/a.ts\"}", output: "@@ -1 +1 @@\n-a\n+b", error: nil)
        let parts = toolParts(edit)
        XCTAssertEqual(parts.title, "Edit file")
        XCTAssertEqual(parts.summary, "src/a.ts")
        XCTAssertEqual(parts.output, "@@ -1 +1 @@\n-a\n+b")
        XCTAssertTrue(toolOutputIsDiff(parts))
        // Empty core fields fall back to the author and body.
        edit.tool = ChatTool(id: "t", kind: "edit", status: "completed", title: "", summary: nil)
        XCTAssertEqual(toolParts(edit).title, "Edit")
        XCTAssertEqual(toolParts(edit).summary, "a.ts")
    }

    func testGroupSummaryNamesOnlyWhatDidntFinish() {
        let rows = [row("Read", "x", kind: "read"), row("Edit", "x", kind: "edit", status: "failed"),
                    row("Search", "x", kind: "search"), row("Ran command", "x", kind: "execute")]
        XCTAssertEqual(toolGroupSummary(rows, subagent: false, elapsed: nil), "4 tool calls · 1 failed")
        XCTAssertEqual(toolGroupSummary(Array(rows.prefix(1)), subagent: false, elapsed: nil), "1 tool call")
    }
}

/// U1: background commands render as compact task rows, finished runs as one list.
final class BackgroundTaskRowTests: XCTestCase {
    private func task(_ id: String, _ status: String, label: String = "pytest -q") -> ChatRow {
        ChatRow(id: id, role: "system", kind: "background_task", author: "Background command", body: "cd /x && pytest -q",
                background: ChatBackground(label: label, status: status, task_id: "t-" + id, started_at_ms: 0, finished_at_ms: 3_600_000))
    }
    private func view(_ rows: [ChatRow]) -> ChatThreadView {
        ChatThreadView(thread: ThreadSummary(workspace_id: "w", thread_id: "t", title: "T", provider: "codex", model: nil, cwd: "",
                                             open: true, archived: false, last_activity_at_ms: nil, status: "idle", history_bucket: "Today"),
                       rows: rows, page: ChatPage(has_older: false, cursor: nil, loading: false), turn: nil, approval: nil, usage: nil,
                       stale: false, error: nil)
    }

    func testFinishedTasksShareOneListAndRunningOnesStandAlone() {
        let text = ChatRow(id: "m", role: "assistant", body: "done")
        let items = transcriptItems(view([task("a", "completed"), task("b", "failed"), task("c", "running"), task("d", "completed"), text]))
        XCTAssertEqual(items.map(\.kindName), ["Background", "Background", "Background", "Message"])
        if case .background(let rows) = items[0] { XCTAssertEqual(rows.map(\.id), ["a", "b"]) } else { XCTFail() }
        if case .background(let rows) = items[1] { XCTAssertEqual(rows.map(\.id), ["c"]) } else { XCTFail() }
        XCTAssertEqual(items[1].id, "b:c", "the bar scrolls to this id")
    }

    func testWordsMatchDesktopAndAndroid() {
        XCTAssertEqual(backgroundStatusText("running"), "Running")
        XCTAssertEqual(backgroundStatusText("completed"), "Finished")
        XCTAssertEqual(backgroundStatusText("failed"), "Failed")
        XCTAssertEqual(backgroundStatusText("stopped"), "Stopped")
        XCTAssertEqual(backgroundListLine(task("a", "completed"), now: 2 * 3_600_000), "pytest -q finished · 1 h ago")
        XCTAssertEqual(backgroundBarText(1), "1 background task running")
        XCTAssertEqual(backgroundBarText(2), "2 background tasks running")
        XCTAssertEqual(backgroundLabel(task("a", "completed", label: "")), "cd /x && pytest -q")
    }
}

/// Why a sent image has no preview, the same mapping as Android.
final class AttachmentFailureTests: XCTestCase {
    func testRefusalsAskForAHostUpdateAndTransientFailuresRetry() {
        XCTAssertEqual(thumbnailPhase(status: "ready", cached: true), .image)
        XCTAssertEqual(thumbnailPhase(status: "ready", cached: false), .unavailable)
        XCTAssertEqual(thumbnailPhase(status: "loading", cached: false), .loading)
        XCTAssertEqual(thumbnailPhase(status: nil, cached: false), .loading)
        for code in ["forbidden", "insufficient_scope", "method_not_found", "unknown_method", "not_allowed", "unauthorized"] {
            XCTAssertEqual(thumbnailPhase(status: "failed", errorCode: code, cached: false), .hostRefused, code)
        }
        XCTAssertEqual(thumbnailPhase(status: "failed", errorCode: "not_found", cached: false), .unavailable)
        XCTAssertEqual(thumbnailPhase(status: "failed", errorCode: "unavailable", cached: false), .unavailable)
        XCTAssertEqual(thumbnailPhase(status: "unavailable", cached: false), .unavailable)
        XCTAssertEqual(thumbnailPhase(status: "failed", errorCode: "timeout", cached: false), .retry)
        XCTAssertEqual(thumbnailPhase(status: "failed", errorCode: nil, cached: false), .retry)
        XCTAssertEqual(thumbnailPhase(status: "failed", errorCode: "network", cached: false), .retry)
    }
}

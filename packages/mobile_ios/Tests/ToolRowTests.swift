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

    func testGroupSummaryNamesOnlyWhatDidntFinish() {
        let rows = [row("Read", "x", kind: "read"), row("Edit", "x", kind: "edit", status: "failed"),
                    row("Search", "x", kind: "search"), row("Ran command", "x", kind: "execute")]
        XCTAssertEqual(toolGroupSummary(rows, subagent: false, elapsed: nil), "4 tool calls · 1 failed")
        XCTAssertEqual(toolGroupSummary(Array(rows.prefix(1)), subagent: false, elapsed: nil), "1 tool call")
    }
}

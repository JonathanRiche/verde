import XCTest
@testable import VerdeApp

/// Review pass 2 (I2-*) rules that don't need a device.
final class Pass2Tests: XCTestCase {
    func testSelectTextIsTheRenderedText() {
        let blocks: [MdBlock] = [
            .heading(2, AttributedString("Root cause")),
            .paragraph(AttributedString("Use the retry path.")),
            .bullets(ordered: false, items: [[.paragraph(AttributedString("one"))], [.paragraph(AttributedString("two"))]]),
            .code("let a = 1\n", language: "ts"),
            .rule,
            .table([[AttributedString("Case"), AttributedString("After")], [AttributedString("a"), AttributedString("b")]]),
        ]
        XCTAssertEqual(markdownPlainText(blocks), "Root cause\n\nUse the retry path.\n\n• one\n• two\n\nlet a = 1\n\nCase\tAfter\na\tb")
    }

    func testSteerHintShowsOnce() {
        XCTAssertEqual(composerPlaceholder(.steer), "Steer the current reply…")
        XCTAssertEqual(composerPlaceholder(nil), "Ask anything, or use / for commands and @ to search files.")
        // Empty field: the placeholder says it, so no second line.
        XCTAssertNil(composerHintLine(.steer, text: "", followupShown: false))
        XCTAssertNil(composerHintLine(.steer, text: "go", followupShown: true))
        XCTAssertNil(composerHintLine(nil, text: "go", followupShown: false))
        XCTAssertEqual(composerHintLine(.steer, text: "go", followupShown: false), "Steer the current reply. Long-press Send for other options.")
    }

    func testMoreColumnsOnlyWhileContentRunsPastTheEdge() {
        XCTAssertEqual(overflowEdges(offset: 0, content: 500, container: 300), OverflowEdges(leading: false, trailing: true))
        XCTAssertEqual(overflowEdges(offset: 200, content: 500, container: 300), OverflowEdges(leading: true, trailing: false))
        XCTAssertEqual(overflowEdges(offset: 0, content: 300, container: 300), OverflowEdges())
        XCTAssertEqual(overflowEdges(offset: 0, content: 500, container: 0), OverflowEdges())
    }

    func testRelativeTimesRefreshEveryHalfMinute() {
        XCTAssertEqual(relativeTimeRefresh, 30)
    }

    /// The badge is derived from the Home projection, so the core's re-announced Home clears it.
    func testNeedsYouFollowsTheAnnouncedHome() {
        let waiting = Pane(id: "p", workspace_id: "w", kind: "chat", title: "Rotate", thread_id: "t",
                           status: "waiting_approval", attention: true, attention_kind: "needs_approval")
        var home = HomeView(items: [waiting], loading: false, stale: false, incomplete_scopes: [], error: nil)
        XCTAssertEqual(needsYouItems(home: home, workspaces: nil, crew: [], companion: nil).count, 1)
        home.items = [Pane(id: "p", workspace_id: "w", kind: "chat", title: "Rotate", thread_id: "t", status: "idle")]
        XCTAssertEqual(needsYouItems(home: home, workspaces: nil, crew: [], companion: nil).count, 0)
    }
}

/// Round-3 transcript rules: bottom hysteresis and following your own send.
final class TranscriptFollowTests: XCTestCase {
    func testAtBottomHasHysteresis() {
        XCTAssertTrue(transcriptAtBottom(false, gap: 10))
        XCTAssertTrue(transcriptAtBottom(false, gap: -30))
        // In the band between the two thresholds the current state holds.
        XCTAssertTrue(transcriptAtBottom(true, gap: 100))
        XCTAssertFalse(transcriptAtBottom(false, gap: 100))
        XCTAssertFalse(transcriptAtBottom(true, gap: 200))
    }

    func testOwnSendBringsTheTranscriptAlong() {
        let sent = ChatRow(id: "u", role: "user", body: "please fail", delivery: "optimistic")
        let reply = ChatRow(id: "a", role: "assistant", body: "ok")
        XCTAssertTrue(ownSendAtTail([.message(reply), .message(sent)]))
        XCTAssertFalse(ownSendAtTail([.message(reply)]))
        XCTAssertFalse(ownSendAtTail([.message(ChatRow(id: "u2", role: "user", body: "old"))]))
    }
}

final class LicenceTextTests: XCTestCase {
    func testHardWrappedLinesJoinIntoParagraphs() {
        XCTAssertEqual(licenceParagraphs("Copyright 2022 A\n\nThis Font Software is\nlicensed under\r\nthe OFL.\n\n\n"),
                       ["Copyright 2022 A", "This Font Software is licensed under the OFL."])
    }
}

/// Pass 4: one syntax palette and highlighted Read output / file lines.
final class SyntaxPaletteTests: XCTestCase {
    func testReadOutputIsHighlightedByExtension() {
        let read = ToolParts(kind: "read", title: "Read", summary: "src/reconnect.ts", input: nil, output: "x", error: nil)
        XCTAssertEqual(toolOutputLanguage(read), "ts")
        var other = read; other.kind = "execute"
        XCTAssertNil(toolOutputLanguage(other))
        var bare = read; bare.summary = "Makefile"
        XCTAssertNil(toolOutputLanguage(bare))
    }

    func testFileLinesKeepRangesThatSpanLines() {
        let split = FileSplit("let a\n/* x\ny */ b")
        // "let" keyword on line 1; a comment from line 2 into line 3.
        let lines = fileStyledLines(split, [DiffRange(start: 0, end: 3, kind: "keyword"), DiffRange(start: 6, end: 15, kind: "comment")])
        XCTAssertEqual(lines.map { String($0.characters) }, ["let a", "/* x", "y */ b"])
        XCTAssertEqual(lines[0].runs.count, 2)
        XCTAssertEqual(lines[2].runs.count, 2)
        XCTAssertNotNil(tokenColor("keyword"))
        XCTAssertNil(tokenColor("unknown"))
    }
}

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

    /// One "needs you" set (C8): the core's `attention.needs` drives every badge and list.
    func testNeedsYouIsTheCoreSet() {
        let needs = [AttentionNeed(workspace_id: "w", thread_id: "t", kind: .needs_approval, title: "Rotate", deep_link: "verde://t"),
                     AttentionNeed(workspace_id: "w", thread_id: "u", kind: .failed, title: "", deep_link: "verde://u")]
        let attention = AttentionView(items: [], count: 3, loading: false, needs: needs, needs_you: 2, unread: 1)
        // An unread pane flagged `attention` is not "needs you".
        let unread = Pane(id: "p", workspace_id: "w", kind: "chat", title: "Done", thread_id: "x", attention: true, attention_kind: "unread")
        let home = HomeView(items: [unread], loading: false, stale: false, incomplete_scopes: [], error: nil)
        let items = needsYouItems(attention: attention, home: home, workspaces: nil)
        XCTAssertEqual(items.map(\.reason), ["Needs approval", "Failed"])
        XCTAssertEqual(items[1].title, "Untitled chat")
        XCTAssertEqual(needsYouBadge(attention: attention, items: items), 2)
        let resolved = AttentionView(items: [], count: 1, loading: false, needs: [], needs_you: 0, unread: 1)
        XCTAssertEqual(needsYouBadge(attention: resolved, items: needsYouItems(attention: resolved, home: home, workspaces: nil)), 0)
    }

    /// Before the core's view arrives (warm-start cache), panes' own `needs_you` flags stand in.
    func testNeedsYouFallsBackToPaneFlags() {
        let waiting = Pane(id: "p", workspace_id: "w", kind: "chat", title: "Rotate", thread_id: "t",
                           status: "waiting_approval", attention: true, attention_kind: "needs_approval", needs_you: true)
        let unread = Pane(id: "q", workspace_id: "w", kind: "chat", title: "Done", thread_id: "u", attention: true, attention_kind: "unread")
        let home = HomeView(items: [waiting, unread], loading: false, stale: false, incomplete_scopes: [], error: nil)
        let items = needsYouItems(attention: nil, home: home, workspaces: nil)
        XCTAssertEqual(items.map(\.threadID), ["t"])
        XCTAssertEqual(needsYouBadge(attention: nil, items: items), 1)
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
        XCTAssertEqual(licenceParagraphs("-----\nSIL OPEN FONT LICENSE Version 1.1 - 26 February 2007\n-----\n\nPREAMBLE\nThe goals of the\nOFL are"),
                       ["SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007", "PREAMBLE", "The goals of the OFL are"])
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

/// Pass 4: list hygiene.
final class WorkspaceLabelTests: XCTestCase {
    private func ws(_ id: String, _ label: String, _ path: String) -> Workspace {
        Workspace(workspace_id: id, label: label, path: path, open: false, panes: [], threads: [])
    }

    func testSameNamedWorkspacesAreToldApart() {
        let a = ws("a", "scripts", "/tmp/demo/scripts"), b = ws("b", "scripts", "/tmp/other/scripts"), c = ws("c", "infra", "/srv/infra")
        let all = [a, b, c]
        XCTAssertEqual(workspaceDisplayLabel(a, among: all), "scripts · demo")
        XCTAssertEqual(workspaceDisplayLabel(b, among: all), "scripts · other")
        XCTAssertEqual(workspaceDisplayLabel(c, among: all), "infra")
        let same = ws("d", "scripts", "/tmp/demo/scripts")
        XCTAssertTrue(workspaceDisplayLabel(same, among: [a, same]).hasPrefix("scripts · "))
    }
}

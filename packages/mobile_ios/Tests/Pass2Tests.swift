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
        XCTAssertEqual(composerHintLine(.steer, text: "go", followupShown: false), "Steer the current reply. Hold Send for more.")
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

    /// One status truth (C11, S39): the core's lists drive every badge, list and section.
    func testNeedsYouIsTheCoreSet() {
        let needs = [AttentionNeed(workspace_id: "w", thread_id: "t", kind: .needs_approval, title: "Rotate", deep_link: "verde://t")]
        let failed = [AttentionChat(workspace_id: "w", thread_id: "u", title: "", deep_link: "verde://u", state: .failed, status: "failed")]
        let attention = AttentionView(items: [], count: 2, loading: false, needs: needs, needs_you: 1, unread: 0, failed: failed, failed_count: 1)
        let items = needsYouItems(attention: attention, home: nil, workspaces: nil)
        XCTAssertEqual(items.map(\.reason), ["Needs approval", "Failed"], "failures are listed beside what needs you")
        XCTAssertEqual(items[1].title, "Untitled chat")
        XCTAssertEqual(needsYouBadge(attention: attention, items: items), 1, "and never counted in the badge")
        // No app-side stand-in before the core's view arrives.
        XCTAssertTrue(needsYouItems(attention: nil, home: nil, workspaces: nil).isEmpty)
        XCTAssertEqual(needsYouBadge(attention: nil, items: []), 0)
    }

    func testHomeSectionsAreTheCoresAndNeverRepeat() {
        let thread = ThreadSummary(workspace_id: "w", thread_id: "r", title: "Rotate", provider: "codex", model: nil, cwd: nil,
                                   open: true, archived: false, last_activity_at_ms: 5, status: "working", history_bucket: "Today")
        var state = BrowseState()
        state.workspaces = WorkspacesView(items: [Workspace(workspace_id: "w", label: "infra", path: "/w", open: true, panes: [], threads: [thread])],
                                          loading: false, stale: false, error: nil,
                                          history: HistoryView(query: "", items: [], next_cursor: nil, loading: false, error: nil))
        state.attention = AttentionView(items: [], count: 0, loading: false,
            needs: [AttentionNeed(workspace_id: "w", thread_id: "n", kind: .blocked, title: "Ask", deep_link: "")],
            running: [AttentionChat(workspace_id: "w", thread_id: "r", title: "Rotate", deep_link: "", state: .running, status: "working")],
            recent: [AttentionChat(workspace_id: "w", thread_id: "i", title: "Idle", deep_link: "", state: .idle, status: "")])
        let sections = homeSections(state, limit: 8, hidden: [])
        XCTAssertEqual(sections.needs.map(\.thread_id), ["n"])
        XCTAssertEqual(sections.running.map(\.thread_id), ["r"])
        XCTAssertEqual(sections.running.first?.provider, "codex", "the catalog's thread fills the row")
        XCTAssertEqual(sections.recent.map(\.thread_id), ["i"])
        XCTAssertEqual(coreChatState(sections.needs.first?.state).label(status: sections.needs.first?.status ?? ""), "Needs input")
        XCTAssertTrue(homeSections(state, limit: 8, hidden: ["r"]).running.isEmpty, "companion chats stay out")
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
        // A send that failed at once still counts as your own new message (I8-4).
        XCTAssertTrue(ownSendAtTail([.message(reply), .message(ChatRow(id: "u3", role: "user", body: "x", delivery: "failed"))]))
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
        // S34: the demo's three "scripts" folders, never a raw path.
        let x = ws("x", "scripts", "/tmp/verde-mobile-review/demo/scripts")
        let y = ws("y", "scripts", "/tmp/verde-mobile-review/demo/scripts/demo/scripts")
        let z = ws("z", "scripts", "/tmp/does-not-exist /scripts/demo/scripts")
        let names = [x, y, z].map { workspaceDisplayLabel($0, among: [x, y, z]) }
        XCTAssertEqual(Set(names).count, 3, "\(names)")
        XCTAssertFalse(names.contains { $0.contains("/") }, "\(names)")
        XCTAssertEqual(names[2], "scripts · does-not-exist")
    }
}

final class TruthfulListTests: XCTestCase {
    func testTheSameFolderShowsOnce() {
        let a = Workspace(workspace_id: "a", label: "scripts", path: "/tmp/demo/scripts", open: false, panes: [], threads: [])
        let b = Workspace(workspace_id: "b", label: "scripts", path: "/tmp/demo/scripts", open: false, panes: [], threads: [])
        let c = Workspace(workspace_id: "c", label: "scripts", path: "/tmp/demo/scripts", open: true, panes: [], threads: [])
        let d = Workspace(workspace_id: "d", label: "infra", path: "/srv/infra", open: false, panes: [], threads: [])
        XCTAssertEqual(dedupedWorkspaces([a, b, c, d]).map(\.workspace_id), ["c", "d"])
        XCTAssertEqual(routeWorkspaceID(.thread(workspace: "w", thread: "t")), "w")
        XCTAssertNil(routeWorkspaceID(.history))
    }
}

final class Pass7Tests: XCTestCase {
    func testSpokenImageNames() {
        XCTAssertEqual(attachmentSpokenName("verde-attachment:779cabcdef"), "Photo")
        XCTAssertEqual(attachmentSpokenName("/home/u/shots/dashboard.png"), "dashboard.png")
        XCTAssertEqual(attachmentSpokenName(""), "Photo")
    }

    func testFolderSuggestionsDropClosedOnlyFolders() {
        let open = Workspace(workspace_id: "o", label: "demo", path: "/tmp/demo", open: true, panes: [], threads: [])
        let closed = Workspace(workspace_id: "c", label: "scripts", path: "/tmp/old/scripts", open: false, panes: [], threads: [])
        let kept = freshFolderSuggestions(["/tmp/demo", "/tmp/demo/", "/tmp/old/scripts", "/tmp", "/srv/x"], workspaces: [open, closed])
        XCTAssertEqual(kept, ["/tmp/demo", "/tmp", "/srv/x"])
    }

    func testHistoryTakesTheLiveActivityTime() {
        var thread = ThreadSummary(workspace_id: "w", thread_id: "t", title: "T", provider: "codex", model: nil, cwd: nil,
                                   open: true, archived: false, last_activity_at_ms: 1_000, status: "idle", history_bucket: "today")
        XCTAssertEqual(withLiveActivity(thread, ["t": 5_000]).last_activity_at_ms, 5_000)
        thread.last_activity_at_ms = 9_000
        XCTAssertEqual(withLiveActivity(thread, ["t": 5_000]).last_activity_at_ms, 9_000)
    }
}

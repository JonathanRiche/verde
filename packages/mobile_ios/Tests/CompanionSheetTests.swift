import XCTest
@testable import VerdeApp

final class CompanionSheetTests: XCTestCase {
    func testHeaderStatusSuffix() {
        XCTAssertEqual(companionStatusSuffix(needsYou: 3, crewRunning: 2, working: true, failed: true, connected: true).text, "3 need you")
        XCTAssertEqual(companionStatusSuffix(needsYou: 3, crewRunning: 0, working: false, failed: false, connected: true).tone, .attention)
        XCTAssertEqual(companionStatusSuffix(needsYou: 0, crewRunning: 0, working: false, failed: true, connected: true).text, "needs a look")
        XCTAssertEqual(companionStatusSuffix(needsYou: 0, crewRunning: 2, working: true, failed: false, connected: true).text, "working")
        XCTAssertEqual(companionStatusSuffix(needsYou: 0, crewRunning: 2, working: false, failed: false, connected: true).text, "2 running")
        XCTAssertEqual(companionStatusSuffix(needsYou: 0, crewRunning: 0, working: false, failed: false, connected: true).text, "ready")
        XCTAssertEqual(companionStatusSuffix(needsYou: 5, crewRunning: 0, working: false, failed: false, connected: false).text, "offline")
    }

    func testSummaryCapsules() {
        XCTAssertNil(needsSummary(0))
        XCTAssertEqual(needsSummary(3), "3 need you")
        XCTAssertNil(crewSummary([]))
        let crew = [
            CrewLink(link_id: "1", workspace_id: "w", local_thread_id: "a", status: "running"),
            CrewLink(link_id: "2", workspace_id: "w", local_thread_id: "b", status: "running"),
            CrewLink(link_id: "3", workspace_id: "w", local_thread_id: "c", status: "completed"),
            CrewLink(link_id: "4", workspace_id: "w", local_thread_id: "d", status: "blocked"),
            CrewLink(link_id: "5", workspace_id: "w", local_thread_id: "e", status: "aborted"),
        ]
        XCTAssertEqual(crewSummary(crew), "2 running · 1 waiting · 1 failed · 1 done")
        XCTAssertEqual(crewSummary([CrewLink(link_id: "1", workspace_id: "w", local_thread_id: "a", status: "idle")]), "1 idle")
    }

    func testHeaderCountAlwaysOpensAPanel() {
        XCTAssertEqual(companionHeaderPanel(needsYou: 2, running: 3, working: false, failed: false, connected: true), .needs)
        XCTAssertEqual(companionHeaderPanel(needsYou: 0, running: 3, working: false, failed: false, connected: true), .activity)
        XCTAssertNil(companionHeaderPanel(needsYou: 0, running: 0, working: false, failed: false, connected: true))
        XCTAssertNil(companionHeaderPanel(needsYou: 0, running: 3, working: true, failed: false, connected: true))
        XCTAssertNil(companionHeaderPanel(needsYou: 2, running: 3, working: false, failed: false, connected: false))
        // Every suffix that shows a count has a panel, and no other suffix does.
        for needs in 0...2 { for running in 0...2 { for working in [false, true] { for failed in [false, true] { for connected in [false, true] {
            let text = companionStatusSuffix(needsYou: needs, crewRunning: running, working: working, failed: failed, connected: connected).text
            let panel = companionHeaderPanel(needsYou: needs, running: running, working: working, failed: failed, connected: connected)
            XCTAssertEqual(text.first?.isNumber == true, panel != nil, text)
        } } } } }
    }

    func testActivityListsCrewPlusOtherRunningChatsOnce() {
        func thread(_ ws: String, _ id: String, _ status: String, archived: Bool = false) -> ThreadSummary {
            ThreadSummary(workspace_id: ws, thread_id: id, title: id, provider: "codex", model: nil, cwd: nil, open: true,
                          archived: archived, last_activity_at_ms: 1, status: status, history_bucket: "Today")
        }
        let workspace = Workspace(workspace_id: "w", label: "W", path: "/w", open: true, panes: [], threads: [
            thread("w", "crew-1", "running"), thread("w", "solo", "running"), thread("w", "idle", "idle"),
            thread("w", "approval", "waiting_approval"), thread("w", "old", "running", archived: true),
            thread("w", "subagent:x", "running"), thread("w", "own", "running"),
        ])
        let workspaces = WorkspacesView(items: [workspace], loading: false, stale: false, error: nil,
                                        history: HistoryView(query: "", items: [], next_cursor: nil, loading: false, error: nil))
        let home = HomeView(items: [Pane(id: "p1", workspace_id: "v", kind: "chat", title: "Pane chat", thread_id: "pane", status: "working", can_stop: true),
                                    Pane(id: "p2", workspace_id: "w", kind: "chat", title: "solo", thread_id: "solo", status: "working", can_stop: true),
                                    Pane(id: "p3", workspace_id: "v", kind: "terminal", title: "shell", terminal_id: "t", status: "working", can_stop: true)],
                            loading: false, stale: false, incomplete_scopes: [], error: nil)
        let crew = [CrewLink(link_id: "1", workspace_id: "w", local_thread_id: "crew-1", title: "Build", status: "running"),
                    CrewLink(link_id: "2", workspace_id: "w", local_thread_id: "crew-2", title: "Docs", status: "completed")]
        let items = activityItems(crew: crew, home: home, workspaces: workspaces, companion: (workspace: "w", thread: "own"))
        XCTAssertEqual(items.map(\.id), ["w/crew-1", "w/crew-2", "v/pane", "w/solo"])
        XCTAssertEqual(items.map(\.crew), [true, true, false, false])
        XCTAssertEqual(items.first?.title, "Build")
        XCTAssertEqual(activitySummary(items), "3 running · 1 done")
        // With no crew at all the machine-wide running chats still fill the panel.
        let solo = activityItems(crew: [], home: nil, workspaces: workspaces, companion: (workspace: "w", thread: "own"))
        XCTAssertEqual(solo.map(\.threadID), ["crew-1", "solo"])
        XCTAssertEqual(activitySummary(solo), "2 running")
        XCTAssertNil(activitySummary([]))
        // Other companions' chats stay behind the bubble.
        XCTAssertEqual(activityItems(crew: crew, home: home, workspaces: workspaces, companion: nil, hidden: ["own", "pane"]).map(\.threadID),
                       ["crew-1", "crew-2", "solo"])
    }

    func testCompanionThreadsCoverEveryCompanionAndItsHistory() {
        var moss = RosterEntry(id: "a", name: "Moss", character: .moss, home_workspace_id: "w", thread_id: "moss-now")
        moss.history = [CompanionHistoryItem(thread_id: "moss-old", title: "Old", ended_at_ms: 1),
                        CompanionHistoryItem(thread_id: "", title: "Blank", ended_at_ms: 2)]
        let sprout = RosterEntry(id: "b", name: "Sprout", character: .sprout, home_workspace_id: "w")
        XCTAssertEqual(companionThreadIDs(Roster(active_id: "b", companions: [moss, sprout])), ["moss-now", "moss-old"])
        XCTAssertTrue(companionThreadIDs(nil).isEmpty)
    }

    func testComposerChipLabel() {
        XCTAssertEqual(composerChipLabel(model: "Haiku 5.5", effort: "Low"), "Haiku 5.5 · Low")
        XCTAssertEqual(composerChipLabel(model: "Haiku 5.5", effort: nil), "Haiku 5.5")
        XCTAssertEqual(composerChipLabel(model: "Haiku 5.5", effort: "Default"), "Haiku 5.5")
    }
}

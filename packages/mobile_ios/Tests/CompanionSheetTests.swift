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

    func testComposerChipLabel() {
        XCTAssertEqual(composerChipLabel(model: "Haiku 5.5", effort: "Low"), "Haiku 5.5 · Low")
        XCTAssertEqual(composerChipLabel(model: "Haiku 5.5", effort: nil), "Haiku 5.5")
        XCTAssertEqual(composerChipLabel(model: "Haiku 5.5", effort: "Default"), "Haiku 5.5")
    }
}

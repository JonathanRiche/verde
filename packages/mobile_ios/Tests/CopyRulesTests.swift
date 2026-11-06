import XCTest
@testable import VerdeApp

/// Small wording and routing rules from the round-1 review.
final class CopyRulesTests: XCTestCase {
    func testNeedsYouIsPluralised() {
        XCTAssertEqual(needsYouCount(1), "1 needs you")
        XCTAssertEqual(needsYouCount(3), "3 need you")
        XCTAssertEqual(needsSummary(1), "1 needs you")
        XCTAssertNil(needsSummary(0))
        XCTAssertEqual(companionStatusSuffix(needsYou: 1, crewRunning: 0, working: false, failed: false, connected: true).text, "needs you", "the status says so; the capsule carries the count")
    }

    func testMissingVoiceKeyOffersSettingsNotRetry() {
        XCTAssertTrue(liveVoiceNeedsSetup("voice_not_configured"))
        XCTAssertTrue(liveVoiceNeedsSetup("voice_key_rejected"))
        XCTAssertFalse(liveVoiceNeedsSetup("offline"))
        XCTAssertFalse(liveVoiceNeedsSetup(nil))
    }

    func testFloatingBubbleOnlyOnTopLevelLists() {
        XCTAssertTrue(floatingBubbleAllowed(tab: .home, pathDepth: 0))
        XCTAssertTrue(floatingBubbleAllowed(tab: .hosts, pathDepth: 0))
        XCTAssertFalse(floatingBubbleAllowed(tab: .home, pathDepth: 1))
        XCTAssertFalse(floatingBubbleAllowed(tab: .workspaces, pathDepth: 2))
    }
}

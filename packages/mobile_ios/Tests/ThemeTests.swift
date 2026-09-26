import XCTest
import UIKit
@testable import VerdeApp

@MainActor
final class ThemeTests: XCTestCase {
    func testBundledFontsAreRegisteredUnderTheirRealNames() {
        for name in ["NotoSans-Regular", "NotoSans-Bold", "CalSans-Regular", "JetBrainsMonoNF-Regular"] {
            XCTAssertNotNil(UIFont(name: name, size: 15), "Font missing: \(name)")
        }
    }
    func testBundledArtworkLoads() {
        XCTAssertNotNil(UIImage(named: "verde_logo"))
        XCTAssertNotNil(UIImage(named: "provider_openai"))
    }
    func testDrawerOnlyIncludesOpenNonArchivedRootChats() throws {
        var workspace = try XCTUnwrap(K09.workspacesLive.data?.items.first)
        let openIDs = Set(workspace.panes.compactMap(\.thread_id))
        let actual = drawerThreads(workspace)
        XCTAssertTrue(actual.allSatisfy { openIDs.contains($0.thread_id) && !$0.archived && !isSubagent($0) })
        workspace.panes = []
        XCTAssertTrue(drawerThreads(workspace).isEmpty)
    }
}

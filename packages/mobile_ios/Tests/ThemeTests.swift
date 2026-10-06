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
    func testSwitcherOrdersByRecencyFiltersFuzzilyAndTargetsMostRecentOpenWorkspace() {
        func ws(_ id: String, _ rank: UInt32, open: Bool = true) -> Workspace {
            Workspace(workspace_id: id, label: id, path: "/" + id, open: open, panes: [], threads: [], recency_rank: rank)
        }
        let items = [ws("c", 2), ws("closed", 0, open: false), ws("a", 1)]
        XCTAssertEqual(switcherWorkspaces(items).map(\.workspace_id), ["closed", "a", "c"])
        XCTAssertEqual(mostRecentOpenWorkspace(items)?.workspace_id, "a")
        XCTAssertNil(mostRecentOpenWorkspace([ws("closed", 0, open: false)]))
        XCTAssertTrue(fuzzyMatches("vrd", "Verde"))
        XCTAssertTrue(fuzzyMatches("all", "All Workspaces"))
        XCTAssertFalse(fuzzyMatches("dv", "Verde"))
        XCTAssertTrue(drawerItems([ws("a", 0)], scope: "other").active.isEmpty)
    }
    func testDrawerActiveSpansEveryOpenWorkspaceWhileOpenFollowsScope() {
        func ws(_ id: String, _ status: String, open: Bool = true) -> Workspace {
            let thread = ThreadSummary(workspace_id: id, thread_id: id + "-t", title: id, provider: "codex", model: nil, cwd: nil, open: true,
                                       archived: false, last_activity_at_ms: 1, status: status, history_bucket: "Today")
            return Workspace(workspace_id: id, label: id, path: "/" + id, open: open,
                             panes: [Pane(id: "p-" + id, workspace_id: id, kind: "chat", title: id, thread_id: thread.thread_id)], threads: [thread])
        }
        let items = [ws("a", "working"), ws("b", "idle"), ws("c", "failed", open: false)]
        let scoped = drawerItems(items, scope: "b")
        XCTAssertEqual(scoped.active.map { $0.workspace.workspace_id }, ["a"])
        XCTAssertEqual(scoped.open.map { $0.workspace.workspace_id }, ["b"])
        XCTAssertTrue(drawerItems(items, scope: "a").open.isEmpty)
        XCTAssertEqual(drawerItems(items, scope: nil).open.map { $0.workspace.workspace_id }, ["b"])
    }
    func testWorkspaceAutoIdentityMatchesCrossClientVectors() {
        XCTAssertTrue(workspaceAutoIdentity("ws-alpha") == (14, 2))
        XCTAssertTrue(workspaceAutoIdentity("baaa819e66d8f3be") == (9, 6))
        XCTAssertTrue(workspaceAutoIdentity("") == (5, 5))
    }
    func testWorkspaceColorsRotateTheClampedAccent() {
        XCTAssertEqual(workspaceIconNames.count, 16)
        let accent = (r: 0x50 / 255.0, g: 0xc8 / 255.0, b: 0x78 / 255.0)
        let slot0 = workspaceRGB(slot: 0, accent: accent, dark: true)
        XCTAssertTrue(slot0.g > slot0.r && slot0.g > slot0.b)
        for k in 0..<8 {
            for dark in [true, false] {
                let c = workspaceRGB(slot: k, accent: accent, dark: dark)
                let l = (max(c.r, c.g, c.b) + min(c.r, c.g, c.b)) / 2
                XCTAssertTrue(dark ? (0.549...0.721).contains(l) : (0.379...0.501).contains(l), "slot \(k) lightness \(l)")
            }
        }
        XCTAssertEqual(workspaceSymbol(9), "terminal.fill")
        XCTAssertNotNil(UIImage(systemName: workspaceSymbol(0)))
        for i in 0..<16 { XCTAssertNotNil(UIImage(systemName: workspaceSymbol(i)), workspaceIconNames[i]) }
    }
}

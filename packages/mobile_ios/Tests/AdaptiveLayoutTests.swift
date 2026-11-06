import XCTest
@testable import VerdeApp

final class AdaptiveLayoutTests: XCTestCase {
    private func panes(_ width: CGFloat, collapsed: Bool = false, moss: Bool = false, peek: Bool = false) -> AdaptivePanes {
        AdaptivePanes(width: width, sidebarCollapsed: collapsed, mossOpen: moss, chatsPeek: peek)
    }

    func testWidthThresholds() {
        XCTAssertEqual(AdaptiveTier(width: 0), .phone)
        XCTAssertEqual(AdaptiveTier(width: 430), .phone)
        XCTAssertEqual(AdaptiveTier(width: 599.5), .phone)
        XCTAssertEqual(AdaptiveTier(width: 600), .single)
        XCTAssertEqual(AdaptiveTier(width: 699.5), .single)
        XCTAssertEqual(AdaptiveTier(width: 700), .split)
        XCTAssertEqual(AdaptiveTier(width: 1019.5), .split)
        XCTAssertEqual(AdaptiveTier(width: 1020), .triple)
        XCTAssertEqual(AdaptiveTier(width: 1400), .triple)
    }

    func testTierCapabilities() {
        XCTAssertFalse(AdaptiveTier.phone.wide)
        XCTAssertFalse(AdaptiveTier.phone.docked)
        XCTAssertTrue(AdaptiveTier.single.wide)
        XCTAssertFalse(AdaptiveTier.single.docked)
        XCTAssertTrue(AdaptiveTier.split.docked)
        XCTAssertTrue(AdaptiveTier.triple.docked)
    }

    /// Below 700 nothing moves: the content fills the window and the sheet and drawer stay in charge.
    func testNarrowWindowsHaveNoPanesEvenWithMossOpen() {
        for width: CGFloat in [320, 430, 599, 600, 699] {
            for moss in [false, true] {
                let layout = panes(width, moss: moss)
                XCTAssertFalse(layout.showsChats)
                XCTAssertFalse(layout.mossMounted)
                XCTAssertEqual(layout.contentLeading, 0)
                XCTAssertEqual(layout.contentTrailing, 0)
            }
        }
    }

    func testPermanentSidebarAndCollapse() {
        let open = panes(800)
        XCTAssertTrue(open.showsChats)
        XCTAssertEqual(open.contentLeading, AdaptivePanes.sidebarWidth)
        let hidden = panes(800, collapsed: true)
        XCTAssertFalse(hidden.showsChats)
        XCTAssertEqual(hidden.contentLeading, 0, "Diffs and terminals get the full width")
    }

    /// The product rule: without an explicit open, Moss gets no pane and no reserved space at any width.
    func testMossNeverOpensItselfOrReservesSpace() {
        for width in stride(from: CGFloat(320), through: 1600, by: 20) {
            for collapsed in [false, true] {
                for peek in [false, true] {
                    let layout = panes(width, collapsed: collapsed, moss: false, peek: peek)
                    XCTAssertFalse(layout.mossMounted, "width \(width)")
                    XCTAssertFalse(layout.mossVisible, "width \(width)")
                    XCTAssertFalse(layout.mossInSlot, "width \(width)")
                    XCTAssertEqual(layout.contentTrailing, 0, "width \(width)")
                    XCTAssertEqual(layout.showsChats, layout.tier.docked && !collapsed, "width \(width)")
                }
            }
        }
    }

    /// I12-1: Moss beside the content whenever the content keeps 420 points; the sidebar yields
    /// first; only a window too narrow for that gets a dimmed overlay.
    func testMossSitsBesideTheContentAndTheSidebarYieldsFirst() {
        let portrait = panes(834, moss: true)
        XCTAssertFalse(portrait.mossOverlay)
        XCTAssertFalse(portrait.showsChats, "834 - 300 can't hold 360 + 420: the sidebar steps aside")
        XCTAssertTrue(portrait.sidebarYieldsToMoss)
        XCTAssertEqual(portrait.contentLeading, 0)
        XCTAssertEqual(portrait.contentTrailing, 360)
        XCTAssertEqual(portrait.mossLeading, 834 - 360)
        let landscape = panes(1210, moss: true)
        XCTAssertTrue(landscape.showsChats)
        XCTAssertFalse(landscape.mossOverlay)
        XCTAssertEqual(landscape.contentLeading, 300)
        XCTAssertEqual(landscape.contentTrailing, 360)
        let narrow = panes(720, moss: true)
        XCTAssertTrue(narrow.mossOverlay, "720 can't hold 360 + 420: a dimmed overlay")
        XCTAssertEqual(narrow.contentTrailing, 0)
        XCTAssertEqual(panes(834).showsChats, true, "Closing Moss brings the sidebar back")
        let hidden = panes(834, collapsed: true, moss: true)
        XCTAssertFalse(hidden.sidebarYieldsToMoss)
        XCTAssertFalse(hidden.mossOverlay)
    }

    func testListsKeepTheReadableColumn() {
        XCTAssertNil(readableListMargin(402), "Phones keep the list's own margins")
        XCTAssertNil(readableListMargin(534))
        XCTAssertEqual(readableListMargin(834), 57)
    }

    func testSidebarGrowsWithTextSize() {
        XCTAssertEqual(adaptiveSidebarWidth(.large, window: 834), 300)
        XCTAssertEqual(adaptiveSidebarWidth(.accessibility3, window: 834), 380)
        XCTAssertEqual(adaptiveSidebarWidth(.accessibility3, window: 700), 322)
        XCTAssertEqual(panes(834).contentLeading, 300)
        XCTAssertEqual(AdaptivePanes(width: 834, sidebarCollapsed: false, mossOpen: false, chatsPeek: false, sidebarWidth: 380).contentLeading, 380)
    }

    func testClosingMossReturnsTheSidebar() {
        XCTAssertEqual(panes(800, moss: false), panes(800))
        XCTAssertTrue(panes(800, moss: false).showsChats)
        XCTAssertFalse(panes(800, collapsed: true, moss: false).showsChats, "A sidebar the user hid stays hidden")
    }

    func testMossGetsAThirdPaneAtWideWidths() {
        let layout = panes(1200, moss: true)
        XCTAssertTrue(layout.showsChats)
        XCTAssertTrue(layout.mossVisible)
        XCTAssertFalse(layout.mossInSlot)
        XCTAssertEqual(layout.mossWidth, AdaptivePanes.mossPaneWidth)
        XCTAssertEqual(layout.mossLeading, 1200 - AdaptivePanes.mossPaneWidth)
        XCTAssertEqual(layout.contentLeading, AdaptivePanes.sidebarWidth)
        XCTAssertEqual(layout.contentTrailing, AdaptivePanes.mossPaneWidth)
        XCTAssertFalse(layout.mossOverlay)
        XCTAssertGreaterThanOrEqual(AdaptiveTier.tripleMinWidth - AdaptivePanes.sidebarWidth - AdaptivePanes.mossPaneWidth, 360, "Content stays usable at the threshold")
    }

    func testThirdPaneIgnoresAPeekLeftOverFromTheSlot() {
        let layout = panes(1200, moss: true, peek: true)
        XCTAssertTrue(layout.mossVisible)
        XCTAssertTrue(layout.showsChats)
    }

    func testSidebarOpensReplaceAndDrawerOpensPush() {
        let a = BrowseRoute.thread(workspace: "w", thread: "a")
        let b = BrowseRoute.thread(workspace: "w", thread: "b")
        XCTAssertEqual(adaptivePath([a], opening: b, docked: true), [b])
        XCTAssertEqual(adaptivePath([a], opening: b, docked: false), [a, b])
        XCTAssertEqual(adaptivePath([], opening: b, docked: false), [b])
    }

    func testProseIsCappedAndDiffsAndToolsGoWider() {
        let row = ChatRow(id: "1", role: "assistant", author: "", body: "text")
        for tier in [AdaptiveTier.single, .split, .triple] {
            XCTAssertEqual(transcriptRowCap(.message(row), tier: tier), transcriptTextWidth)
            XCTAssertEqual(transcriptRowCap(.think(row), tier: tier), transcriptTextWidth)
            XCTAssertEqual(transcriptRowCap(.notice(row), tier: tier), transcriptTextWidth)
            XCTAssertNil(transcriptRowCap(.diff(row), tier: tier))
            XCTAssertEqual(transcriptRowCap(.tool(row), tier: tier), transcriptTextWidth)
            XCTAssertEqual(transcriptRowCap(.toolGroup([row], subagent: false), tier: tier), transcriptTextWidth)
        }
        XCTAssertNil(transcriptRowCap(.message(row), tier: .phone), "Phones are unchanged")
    }
}

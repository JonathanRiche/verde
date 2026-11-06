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
        XCTAssertEqual(AdaptiveTier(width: 999.5), .split)
        XCTAssertEqual(AdaptiveTier(width: 1000), .triple)
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

    func testOpenMossTakesTheSidebarSlotAtTwoPanes() {
        let layout = panes(800, moss: true)
        XCTAssertTrue(layout.mossVisible)
        XCTAssertTrue(layout.mossInSlot)
        XCTAssertFalse(layout.showsChats)
        XCTAssertEqual(layout.mossWidth, AdaptivePanes.sidebarWidth)
        XCTAssertEqual(layout.mossLeading, 0)
        XCTAssertEqual(layout.contentLeading, AdaptivePanes.sidebarWidth)
        XCTAssertEqual(layout.contentTrailing, 0)
    }

    func testChatListIsOneStepAwayWhileMossHoldsTheSlot() {
        let layout = panes(800, moss: true, peek: true)
        XCTAssertTrue(layout.showsChats)
        XCTAssertTrue(layout.mossMounted, "Moss stays mounted so it keeps its place")
        XCTAssertFalse(layout.mossVisible)
        XCTAssertEqual(layout.contentLeading, AdaptivePanes.sidebarWidth)
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
        XCTAssertGreaterThanOrEqual(1000 - AdaptivePanes.sidebarWidth - AdaptivePanes.mossPaneWidth, 360, "Content stays usable at the threshold")
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

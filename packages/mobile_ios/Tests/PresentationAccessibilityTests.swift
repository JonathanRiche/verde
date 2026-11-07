import XCTest
@testable import VerdeApp

final class PresentationAccessibilityTests: XCTestCase {
    func testDismissingAChildRestoresOnlyItsParentLayer() {
        let state = PresentationAccessibilityState()
        let parent = UUID(), child = UUID()
        XCTAssertEqual(state.topLayer, 0)
        state.present(parent, at: 1)
        state.present(child, at: 2)
        XCTAssertEqual(state.topLayer, 2)
        state.dismiss(child)
        XCTAssertEqual(state.topLayer, 1)
        state.dismiss(parent)
        XCTAssertEqual(state.topLayer, 0)
    }

    func testOutgoingPresentationCannotUnhideBehindAnIncomingOne() {
        let state = PresentationAccessibilityState()
        let outgoing = UUID(), incoming = UUID(), child = UUID()
        state.present(outgoing, at: 1)
        state.present(incoming, at: 1)
        state.dismiss(outgoing)
        XCTAssertEqual(state.topLayer, 1)
        state.present(child, at: 2)
        state.dismiss(incoming)
        XCTAssertEqual(state.topLayer, 2)
        state.dismiss(child)
        XCTAssertEqual(state.topLayer, 0)
    }
}

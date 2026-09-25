import XCTest
@testable import VerdeApp

final class ClientCoreTests: XCTestCase {
    func testLinkedCoreReturnsVersion() {
        // Executes the Zig C ABI in the simulator-hosted app, not a fake core.
        let version = ClientCore.version
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+([+-].+)?$"#, options: .regularExpression))
        XCTAssertEqual(ClientCore.version, version)
    }
}

import XCTest
@testable import VerdeApp

final class ClientCoreTests: XCTestCase {
    func testLargeNetworkEnvelopesCrossSwiftAndNativeBoundary() throws {
        let core = try NativeHostCore(config: Config(api_version: 1, host_id: "fixture", label: "Fixture", client_revision: 1, session_nonce: "fixture", jitter_seed: 1))
        defer { core.close() }
        let payload = String(repeating: "A", count: 1024 * 1024)
        let events: [Event] = [
            .http_response(EventHttpResponse(now_ms: 0, wall_time_ms: 0, effect_id: "missing", generation: "1", status: 200, headers: [], body_base64: payload)),
            .ws_message(EventWsMessage(now_ms: 0, wall_time_ms: 0, socket_id: "missing", generation: "1", text: payload))
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            XCTAssertGreaterThan(data.count, 1024 * 1024)
            _ = try JSONDecoder().decode(EffectList.self, from: core.handle(data))
        }
        XCTAssertFalse(try core.query("hosts").isEmpty)
    }

    func testLinkedCoreReturnsVersion() {
        // Executes the Zig C ABI in the simulator-hosted app, not a fake core.
        let version = ClientCore.version
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+([+-].+)?$"#, options: .regularExpression))
        XCTAssertEqual(ClientCore.version, version)
    }
}

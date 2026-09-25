import XCTest
@testable import VerdeApp

private let fixturePin = String(repeating: "5", count: 64)
private let fixtureRuntime = String(repeating: "1", count: 32)
private let fixtureInstance = String(repeating: "2", count: 32)
private func fixtureLink(native: Bool = false) -> String {
    let manual = PairingInput.manual(host: "https://host.invalid", grant: String(repeating: "6", count: 32), code: String(repeating: "7", count: 64))
    return native ? manual : manual.replacingOccurrences(of: "verde://pair", with: "https://verdeai.dev/pair")
}

private final class PairStorage: SecureStorage {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failCredential = false
    func get(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func put(_ key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if key.hasSuffix("/credential") && failCredential { failCredential = false; throw StorageError(code: .locked) }
        values[key] = value
    }
    func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}

private final class PairTransport: CoreTransport {
    let storage: PairStorage
    let prefix: String
    var loseExchange = false
    private let lock = NSLock()
    private var exchanges = 0
    private var firstBody: String?
    private var safeRetry = true
    private var tokenAfterSave = false
    init(storage: PairStorage, prefix: String) { self.storage = storage; self.prefix = prefix }
    func observations() -> (Int, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }; return (exchanges, safeRetry, tokenAfterSave)
    }
    func execute(_ effect: Effect, emit: @escaping (Event) -> Void) {
        switch effect {
        case .tls_probe(let e):
            emit(.tls_peer(EventTlsPeer(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                generation: e.generation, origin: e.origin, spki_sha256: fixturePin, system_trusted: true)))
        case .http_request(let e):
            var body: [String: Any]
            if e.url.hasSuffix("/.well-known/verde-runtime") {
                body = ["access_protocol_version": 1, "runtime_id": fixtureRuntime, "instance_id": fixtureInstance,
                    "https_url": "https://host.invalid", "wss_url": "wss://host.invalid/ws",
                    "capabilities": ["access.pair.v1", "access.pair.idempotent.v1"]]
            } else if e.url.hasSuffix("/auth/pair/exchange") {
                lock.lock()
                exchanges += 1
                if let firstBody { safeRetry = safeRetry && firstBody == e.body_base64 }
                else { firstBody = e.body_base64 }
                let lose = loseExchange && exchanges == 1
                lock.unlock()
                if lose {
                    emit(.http_response(EventHttpResponse(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                        generation: e.generation, status: nil, headers: [], body_base64: nil,
                        error: TransportFailure(kind: .network, code: .offline))))
                    return
                }
                XCTAssertTrue((try? storage.get(prefix + "/profile")) != nil)
                body = ["access_protocol_version": 1, "runtime_id": fixtureRuntime, "instance_id": fixtureInstance,
                    "device_id": String(repeating: "3", count: 32), "device_credential": String(repeating: "4", count: 64),
                    "scopes": ["runtime:read", "chat:read"]]
            } else if e.url.hasSuffix("/auth/access-token") {
                lock.lock(); tokenAfterSave = (try? storage.get(prefix + "/credential")) != nil; lock.unlock()
                return // Deliberately park here: this fixture tests pairing, not sync.
            } else { return XCTFail("unexpected pairing transport effect") }
            guard let bytes = try? JSONSerialization.data(withJSONObject: body) else { return XCTFail("fixture encoding") }
            emit(.http_response(EventHttpResponse(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                generation: e.generation, status: 200, headers: [], body_base64: bytes.base64EncodedString(), error: nil)))
        case .http_cancel, .ws_close: break
        default: XCTFail("unexpected pairing effect")
        }
    }
    func stop() {}
}

@MainActor
final class PairingTests: XCTestCase {
    private func fixture(storageFailure: Bool = false, lostReply: Bool = false) throws -> (PairingModel, PairStorage, PairTransport) {
        let id = UUID().uuidString
        let storage = PairStorage()
        storage.failCredential = storageFailure
        let transport = PairTransport(storage: storage, prefix: "vc/1/\(id)")
        transport.loseExchange = lostReply
        let model = PairingModel(deviceLabel: "Test phone") { store in
            let config = Config(api_version: 1, host_id: id, label: "Test host", https_url: nil, wss_url: nil,
                client_revision: 1, session_nonce: String(repeating: "0", count: 32), jitter_seed: 1)
            return CoreHost(core: try NativeHostCore(config: config), store: store, transport: transport, storage: storage)
        }
        return (model, storage, transport)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "pairing state deadline")
    }
    private func begin(_ model: PairingModel, native: Bool = false) async throws {
        await model.start()
        try await until { model.row?.auth_state == "unpaired" }
        await model.open(try XCTUnwrap(URL(string: fixtureLink(native: native))))
        try await until { model.row?.trust_proposal != nil }
    }

    func testUniversalAndNativeLinksPersistOnlyAfterTrustAndRecoverStorageFailure() async throws {
        for native in [false, true] {
            let (model, _, transport) = try fixture(storageFailure: true)
            try await begin(model, native: native)
            XCTAssertEqual(transport.observations().0, 0)
            let proposal = try XCTUnwrap(model.row?.trust_proposal)
            XCTAssertTrue(proposal.spki_sha256 == fixturePin)
            await model.trust(proposal, accept: true)
            try await until { model.error?.domain == "storage" }
            XCTAssertFalse(model.paired)
            XCTAssertFalse(transport.observations().2)
            await model.retry()
            try await until { model.paired && transport.observations().2 }
            XCTAssertEqual(transport.observations().0, 1)
            XCTAssertFalse(model.store.failed)
            await model.stop()
        }
    }

    func testLostReplyRetriesSameExchangeAndNonce() async throws {
        let (model, _, transport) = try fixture(lostReply: true)
        try await begin(model)
        await model.trust(try XCTUnwrap(model.row?.trust_proposal), accept: true)
        try await until { model.paired }
        XCTAssertEqual(transport.observations().0, 2)
        XCTAssertTrue(transport.observations().1)
        await model.stop()
    }

    func testTrustDenialDoesNotExchangeAndNewLinkCanRetry() async throws {
        let (model, _, transport) = try fixture()
        try await begin(model)
        await model.trust(try XCTUnwrap(model.row?.trust_proposal), accept: false)
        try await until { model.operation?.state == "failed" }
        XCTAssertEqual(transport.observations().0, 0)
        XCTAssertNotNil(model.errorText)
        await model.receive(fixtureLink())
        try await until { model.row?.trust_proposal != nil }
        await model.stop()
    }

    func testCoreRejectsBadLinksWithoutClosingHost() async throws {
        let (model, _, _) = try fixture()
        await model.start()
        try await until { model.row?.auth_state == "unpaired" }
        let valid = fixtureLink()
        let invalid = ["not a link", PairingInput.manual(host: "http://host.invalid", grant: String(repeating: "6", count: 32), code: String(repeating: "7", count: 64)),
            valid + "&code=duplicate", valid.replacingOccurrences(of: "#code=", with: "&code="),
            valid.replacingOccurrences(of: "verdeai.dev", with: "other.invalid")]
        for link in invalid {
            await model.receive(link)
            XCTAssertNotNil(model.inputError)
            XCTAssertFalse(model.store.failed)
        }
        await model.receive(valid)
        try await until { model.row?.trust_proposal != nil }
        XCTAssertNil(model.inputError)
        await model.stop()
    }

    func testRoutingManualFormattingAndNonce() throws {
        XCTAssertTrue(PairingInput.routes(try XCTUnwrap(URL(string: fixtureLink()))))
        XCTAssertTrue(PairingInput.routes(try XCTUnwrap(URL(string: fixtureLink(native: true)))))
        for raw in ["https://other.invalid/pair?x=1", "verde://other?x=1", "https://verdeai.dev/pair/extra?x=1"] {
            XCTAssertFalse(PairingInput.routes(try XCTUnwrap(URL(string: raw))))
        }
        let a = try PairingInput.nonce(), b = try PairingInput.nonce()
        XCTAssertTrue(a.count == 32 && a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertTrue(a != b)
    }
}

import XCTest
import Security
@testable import VerdeApp

private final class FakeCore: HostCore {
    var initial: [Effect]
    var onEvent: ((Event) -> Void)?
    var closed = false
    init(_ initial: [Effect]) { self.initial = initial }
    func handle(_ bytes: Data) throws -> Data {
        let event = try JSONDecoder().decode(Event.self, from: bytes)
        onEvent?(event)
        let effects = initial
        initial = []
        return try JSONEncoder().encode(EffectBatch(api_version: 1, revision: "9007199254740993", effects: effects))
    }
    func query(_ selector: String) throws -> Data {
        Data(#"{"api_version":1,"revision":"9007199254740993","data":{"items":[],"operations":[]},"error":null}"#.utf8)
    }
    func close() { closed = true }
}

private final class FakeTransport: CoreTransport {
    var onEffect: ((Effect, @escaping (Event) -> Void) -> Void)?
    func execute(_ effect: Effect, emit: @escaping (Event) -> Void) { onEffect?(effect, emit) }
    func stop() {}
}

final class CoreHostTests: XCTestCase {
    @MainActor
    func testEffectRoundTripsAndStore() async throws {
        let key = "vc/1/I02-\(UUID().uuidString)/credential"
        let storage = KeychainStorage(service: "dev.verdeai.app.I02.tests", api: FakeKeychainAPI())
        defer { try? storage.delete(key) }
        let tls = Tls(origin: "https://bridge.invalid", spki_sha256: String(repeating: "a", count: 64))
        let effects: [Effect] = [
            .secure_store_put(EffectSecureStorePut(effect_id: "put", generation: "1", key: key, value_base64: Data([0, 255, 42]).base64EncodedString())),
            .secure_store_get(EffectSecureStoreGet(effect_id: "get", generation: "1", key: key)),
            .secure_store_delete(EffectSecureStoreDelete(effect_id: "delete", generation: "1", key: key)),
            .secure_store_get(EffectSecureStoreGet(effect_id: "missing", generation: "1", key: key)),
            .http_request(EffectHttpRequest(effect_id: "http", generation: "2", method: "POST", url: "https://bridge.invalid/api/rpc", headers: [], body_base64: nil, timeout_ms: 100, max_response_bytes: 256, tls: tls)),
            .http_request(EffectHttpRequest(effect_id: "pin", generation: "3", method: "POST", url: "https://bridge.invalid/api/rpc", headers: [], body_base64: nil, timeout_ms: 100, max_response_bytes: 256, tls: tls)),
            .ws_open(EffectWsOpen(effect_id: "ws", generation: "4", url: "wss://bridge.invalid/ws", protocols: ["verde.v1", "verde.ticket.fixture"], tls: tls, max_message_bytes: 256)),
            .ws_send(EffectWsSend(effect_id: "send", generation: "4", socket_id: "ws", text: "fixture")),
            .ws_close(EffectWsClose(effect_id: "close", generation: "4", socket_id: "ws", code: 1000)),
            .set_timer(EffectSetTimer(effect_id: "timer", generation: "5", timer_id: "fires", delay_ms: 10, purpose: "test")),
            .set_timer(EffectSetTimer(effect_id: "timer2", generation: "5", timer_id: "cancelled", delay_ms: 10, purpose: "test")),
            .cancel_timer(EffectCancelTimer(effect_id: "cancel", generation: "5", timer_id: "cancelled")),
            .state_changed(EffectStateChanged(effect_id: "state", generation: "5", revision: "9007199254740993", scopes: ["hosts"]))
        ]
        let core = FakeCore(effects)
        let transport = FakeTransport()
        let completed = expectation(description: "all effect completions")
        completed.expectedFulfillmentCount = 10
        var lastTime: Int64 = 0
        core.onEvent = { event in
            switch event {
            case .secure_store_done(let e):
                XCTAssertTrue(["put", "delete"].contains(e.effect_id)); XCTAssertNil(e.error)
                XCTAssertEqual(e.generation, "1"); completed.fulfill()
            case .secure_store_value(let e):
                XCTAssertNil(e.error)
                XCTAssertEqual(e.value_base64, e.effect_id == "get" ? Data([0, 255, 42]).base64EncodedString() : nil)
                completed.fulfill()
            case .http_response(let e):
                XCTAssertGreaterThanOrEqual(e.now_ms, lastTime); lastTime = e.now_ms
                XCTAssertGreaterThan(e.wall_time_ms, 0)
                if e.effect_id == "pin" {
                    XCTAssertEqual(e.error?.code, .pin_mismatch); XCTAssertNil(e.status)
                    XCTAssertEqual(e.generation, "3")
                } else { XCTAssertEqual(e.status, 403); XCTAssertEqual(e.body_base64, "e30=") }
                completed.fulfill()
            case .ws_open(let e): XCTAssertEqual(e.protocol, "verde.v1"); completed.fulfill()
            case .ws_message(let e): XCTAssertEqual(e.text, "fixture"); completed.fulfill()
            case .ws_closed(let e): XCTAssertEqual(e.socket_id, "ws"); XCTAssertTrue(e.clean); completed.fulfill()
            case .timer_fired(let e): XCTAssertEqual(e.timer_id, "fires"); XCTAssertEqual(e.generation, "5"); completed.fulfill()
            default: break
            }
        }
        transport.onEffect = { effect, emit in
            switch effect {
            case .http_request(let e):
                let failure = e.effect_id == "pin" ? TLSPolicy.failure(systemTrusted: true, observed: String(repeating: "b", count: 64), expected: String(repeating: "a", count: 64)) : nil
                emit(.http_response(EventHttpResponse(now_ms: 0, wall_time_ms: 0,
                    effect_id: e.effect_id, generation: e.generation, status: failure == nil ? 403 : nil,
                    headers: [], body_base64: failure == nil ? "e30=" : nil, error: failure)))
            case .ws_open(let e):
                XCTAssertEqual(e.protocols, ["verde.v1", "verde.ticket.fixture"])
                emit(.ws_open(EventWsOpen(now_ms: 0, wall_time_ms: 0, socket_id: e.effect_id, generation: e.generation, protocol: "verde.v1")))
            case .ws_send(let e): emit(.ws_message(EventWsMessage(now_ms: 0, wall_time_ms: 0, socket_id: e.socket_id, generation: e.generation, text: e.text)))
            case .ws_close(let e): emit(.ws_closed(EventWsClosed(now_ms: 0, wall_time_ms: 0, socket_id: e.socket_id, generation: e.generation, code: e.code, clean: true, error: nil)))
            default: XCTFail("unexpected effect")
            }
        }
        let store = CoreViewStore()
        let host = CoreHost(core: core, store: store, transport: transport, storage: storage)
        try await host.send(.start(EventStart(now_ms: 0, wall_time_ms: 0, foreground: true, network_available: true)))
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(store.hosts?.revision, "9007199254740993")
        XCTAssertFalse(store.failed)
        try await host.shutdown()
        XCTAssertTrue(core.closed)
        do {
            try await host.send(.foreground(EventForeground(now_ms: 0, wall_time_ms: 0)))
            XCTFail("closed host accepted event")
        } catch CoreBridgeError.closed {}
        XCTAssertNil(try storage.get(key))
    }

    /// D-12 `file_fetch` (no iOS viewer until I-09) and effect tags newer than this build
    /// are handled without failing the host: the fetch is refused with a bodiless transport
    /// failure so the core settles its intent, and the unknown effect is dropped.
    @MainActor
    func testUnsupportedAndUnknownEffectsNeverFailTheHost() async throws {
        final class RawCore: HostCore {
            let responses = EventLog()
            var first = true
            func handle(_ bytes: Data) throws -> Data {
                let event = try JSONDecoder().decode(Event.self, from: bytes)
                responses.append(event)
                guard first else { return Data(#"{"api_version":1,"revision":"2","effects":[]}"#.utf8) }
                first = false
                return Data(#"{"api_version":1,"revision":"1","effects":[{"type":"hologram_project","effect_id":"future","generation":"1","beam":"on"},{"type":"file_fetch","effect_id":"fetch","generation":"7","intent_id":"intent-file","url":"https://bridge.invalid/api/file?path=/w/a.md","headers":[{"name":"Authorization","value":"Bearer t"}],"timeout_ms":3000,"max_response_bytes":1000,"tls":{"origin":"https://bridge.invalid","spki_sha256":"\#(String(repeating: "a", count: 64))"}},{"type":"state_changed","effect_id":"state","generation":"1","revision":"1","scopes":["hosts"]}]}"#.utf8)
            }
            func query(_ selector: String) throws -> Data {
                Data(#"{"api_version":1,"revision":"1","data":{"items":[],"operations":[]},"error":null}"#.utf8)
            }
            func close() {}
        }
        let core = RawCore()
        let store = CoreViewStore()
        let host = CoreHost(core: core, store: store, transport: SessionTransport(), storage: MemoryStorage())
        try await host.send(.start(EventStart(now_ms: 0, wall_time_ms: 0, foreground: true, network_available: true)))
        let responses = { core.responses.all.compactMap { event -> EventHttpResponse? in
            if case .http_response(let e) = event { return e }; return nil } }
        try await waitUntil("file_fetch refused") { !responses().isEmpty && store.hosts != nil }
        let refusal = try XCTUnwrap(responses().first)
        XCTAssertEqual(refusal.effect_id, "fetch"); XCTAssertEqual(refusal.generation, "7")
        XCTAssertNil(refusal.status); XCTAssertNil(refusal.body_base64); XCTAssertTrue(refusal.headers.isEmpty)
        XCTAssertEqual(refusal.error?.kind, .network); XCTAssertEqual(refusal.error?.code, .unavailable)
        XCTAssertFalse(store.failed)
        // The host stays usable after both.
        try await host.send(.foreground(EventForeground(now_ms: 0, wall_time_ms: 0)))
        XCTAssertFalse(store.failed)
        XCTAssertEqual(responses().count, 1)
        try await host.shutdown()
    }

    @MainActor
    func testNativeBoundaryStartAndShutdown() async throws {
        let store = CoreViewStore()
        let host = try CoreHost.live(hostID: "I02-\(UUID().uuidString)", label: "Fixture", httpsURL: nil, wssURL: nil, store: store)
        try await host.send(.start(EventStart(now_ms: 0, wall_time_ms: 0, foreground: false, network_available: false)))
        try await host.shutdown()
    }

    func testKeychainProtectionAndAtomicReplacement() throws {
        let storage = KeychainStorage(service: "dev.verdeai.app.I02.tests", api: FakeKeychainAPI())
        let key = UUID().uuidString
        defer { try? storage.delete(key) }
        try storage.put(key, value: Data([1]))
        try storage.put(key, value: Data([2]))
        XCTAssertEqual(try storage.get(key), Data([2]))
        var query = storage.query(key)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(storage.api.copy(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        try storage.delete(key)
        try storage.delete(key)
        XCTAssertNil(try storage.get(key))
    }

    func testStorageFailuresAreAcknowledged() {
        struct LockedStorage: SecureStorage {
            func get(_ key: String) throws -> Data? { throw StorageError(code: .locked) }
            func put(_ key: String, value: Data) throws { throw StorageError(code: .denied) }
            func delete(_ key: String) throws { throw StorageError(code: .io) }
        }
        let storage = LockedStorage()
        if case .secure_store_value(let e) = storage.execute(.secure_store_get(EffectSecureStoreGet(effect_id: "read", generation: "8", key: "key"))) {
            XCTAssertEqual(e.error?.code, .locked); XCTAssertNil(e.value_base64)
        } else { XCTFail() }
        if case .secure_store_done(let e) = storage.execute(.secure_store_put(EffectSecureStorePut(effect_id: "put", generation: "8", key: "key", value_base64: "AA=="))) {
            XCTAssertEqual(e.error?.code, .denied); XCTAssertEqual(e.effect_id, "put")
        } else { XCTFail() }
        if case .secure_store_done(let e) = storage.execute(.secure_store_delete(EffectSecureStoreDelete(effect_id: "delete", generation: "8", key: "key"))) {
            XCTAssertEqual(e.error?.code, .io); XCTAssertEqual(e.generation, "8")
        } else { XCTFail() }
    }
}

// Unsigned simulator apps have no Keychain entitlement. Exercise the exact
// SecItem queries/atomic update path through this isolated Security API fixture.
private final class FakeKeychainAPI: KeychainAPI {
    private var records: [String: [String: Any]] = [:]
    private func attributes(_ query: CFDictionary) -> [String: Any] { query as! [String: Any] }
    private func key(_ query: [String: Any]) -> String { query[kSecAttrAccount as String] as! String }
    func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        let query = attributes(query)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        guard let record = records[key(query)] else { return errSecItemNotFound }
        if query[kSecReturnAttributes as String] as? Bool == true { result.pointee = record as CFDictionary }
        else { result.pointee = record[kSecValueData as String] as! CFData }
        return errSecSuccess
    }
    func update(_ query: CFDictionary, _ values: CFDictionary) -> OSStatus {
        let id = key(attributes(query))
        guard let record = records[id] else { return errSecItemNotFound }
        records[id] = record.merging(attributes(values)) { _, new in new }
        return errSecSuccess
    }
    func add(_ query: CFDictionary) -> OSStatus {
        let record = attributes(query)
        XCTAssertEqual(record[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(record[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        records[key(record)] = record
        return errSecSuccess
    }
    func remove(_ query: CFDictionary) -> OSStatus {
        records.removeValue(forKey: key(attributes(query))) == nil ? errSecItemNotFound : errSecSuccess
    }
}

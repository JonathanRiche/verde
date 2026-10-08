import CryptoKit
import UserNotifications
import XCTest
@testable import VerdeApp

// I-10: payload decrypt + notification content, relay client (mocked URLProtocol), registration,
// token rotation, host removal and the no-relay-URL build. No network, Keychain or APNs.

/// Seals like `push_seal.zig` (X25519 + HKDF-SHA256 + ChaCha20-Poly1305) so the core opens it.
private enum Sealer {
    static func seal(_ plaintext: Data, to recipient: Curve25519.KeyAgreement.PublicKey) throws -> String {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let okm = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: ephemeral.publicKey.rawRepresentation + recipient.rawRepresentation,
            sharedInfo: Data("verde-push-v1".utf8), outputByteCount: 44).withUnsafeBytes { Data($0) }
        let header = Data([1]) + ephemeral.publicKey.rawRepresentation
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: okm.prefix(32)),
                                      nonce: try ChaChaPoly.Nonce(data: okm.suffix(12)), authenticating: header)
        return base64url(header + box.ciphertext + box.tag)
    }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    /// The core's `vc/1/<host>/push` record for a device key bound to `runtime`.
    static func record(_ key: Curve25519.KeyAgreement.PrivateKey, runtime: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "runtime_id": runtime,
            "public_key": base64url(key.publicKey.rawRepresentation), "secret_key": base64url(key.rawRepresentation)])
    }
    static func payload(kind: String, runtime: String = "rt-1", title: String = "Fix the build", snippet: String = "Run the tests?") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["runtime_id": runtime, "workspace_id": "ws-1", "thread_id": "th-1",
            "turn_id": "turn-1", "kind": kind, "title": title, "snippet": snippet])
    }
}

private func placeholder(_ ciphertext: String?) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = ""
    content.body = "A Verde chat needs attention"
    var info: [AnyHashable: Any] = ["aps": ["alert": "A Verde chat needs attention", "mutable-content": 1], "collapse_id": "c1"]
    if let ciphertext { info["ciphertext"] = ciphertext }
    content.userInfo = info
    return content
}

final class PushContentTests: XCTestCase {
    func testDecryptsApprovalIntoTitleBodyCategoryAndRoute() throws {
        let device = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try Sealer.seal(try Sealer.payload(kind: "approval_pending"), to: device.publicKey)
        let records = [(host: "aaa", record: try Sealer.record(other, runtime: "rt-9")),
                       (host: "alpha", record: try Sealer.record(device, runtime: "rt-1"))]
        let content = PushContentBuilder.content(for: placeholder(envelope)) { records }
        XCTAssertEqual(content.title, "Fix the build")
        XCTAssertEqual(content.body, "Needs approval: Run the tests?")
        XCTAssertEqual(content.categoryIdentifier, PushCategory.approval)
        XCTAssertEqual(content.threadIdentifier, "alpha/ws-1/th-1")
        XCTAssertNil(content.userInfo["ciphertext"], "the sealed blob is not kept")
        let route = try XCTUnwrap(content.userInfo["verde"] as? [String: String])
        XCTAssertEqual(route["host_id"], "alpha")
        XCTAssertEqual(route["turn_id"], "turn-1")
        XCTAssertEqual(route["kind"], "approval_pending")
        XCTAssertEqual(route["dedupe_key"], "alpha:turn-1:approval_pending")
        XCTAssertTrue(route["deep_link"]?.hasPrefix("verde://open?host_id=alpha") == true)

        let target = try XCTUnwrap(PushTarget.parse(content.userInfo, action: PushCategory.approveAction))
        XCTAssertEqual(target, PushTarget(hostID: "alpha", workspaceID: "ws-1", threadID: "th-1", turnID: "turn-1",
                                          kind: "approval_pending", action: .approve))
    }

    func testCompletedAndInputNeededOfferReply() throws {
        let device = Curve25519.KeyAgreement.PrivateKey()
        let records = [(host: "alpha", record: try Sealer.record(device, runtime: "rt-1"))]
        for kind in ["completed", "input_needed"] {
            let envelope = try Sealer.seal(try Sealer.payload(kind: kind), to: device.publicKey)
            let content = PushContentBuilder.content(for: placeholder(envelope)) { records }
            XCTAssertEqual(content.categoryIdentifier, PushCategory.reply, kind)
        }
        let failed = try Sealer.seal(try Sealer.payload(kind: "failed"), to: device.publicKey)
        XCTAssertEqual(PushContentBuilder.content(for: placeholder(failed)) { records }.categoryIdentifier, PushCategory.open)
    }

    func testDecryptFailureLeavesThePlaceholderAsIs() throws {
        let device = Curve25519.KeyAgreement.PrivateKey()
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try Sealer.seal(try Sealer.payload(kind: "completed"), to: device.publicKey)
        let wrongKey = [(host: "alpha", record: try Sealer.record(stranger, runtime: "rt-1"))]
        let wrongRuntime = [(host: "alpha", record: try Sealer.record(device, runtime: "rt-other"))]
        for (name, original, records) in [("wrong key", placeholder(envelope), wrongKey),
                                          ("wrong runtime", placeholder(envelope), wrongRuntime),
                                          ("no keys", placeholder(envelope), []),
                                          ("garbage", placeholder("not-an-envelope"), wrongKey),
                                          ("no ciphertext", placeholder(nil), wrongKey)] {
            let content = PushContentBuilder.content(for: original) { records }
            XCTAssertTrue(content === original, name)
            XCTAssertEqual(content.body, "A Verde chat needs attention", name)
            XCTAssertNil(PushTarget.parse(content.userInfo, action: UNNotificationDefaultActionIdentifier), name)
        }
    }

    func testTargetParsingAndForegroundPresentation() {
        let info: [AnyHashable: Any] = ["verde": ["host_id": "alpha", "workspace_id": "ws", "thread_id": "th", "kind": "completed"]]
        XCTAssertEqual(PushTarget.parse(info, action: PushCategory.replyAction, text: "  ship it \n")?.action, .reply("ship it"))
        XCTAssertEqual(PushTarget.parse(info, action: PushCategory.replyAction, text: "   ")?.action, .open)
        XCTAssertEqual(PushTarget.parse(info, action: PushCategory.denyAction)?.action, .deny)
        // No thread: actions degrade to opening the host.
        let hostOnly = PushTarget.parse(["verde": ["host_id": "alpha", "workspace_id": "ws", "kind": "test"]], action: PushCategory.approveAction)
        XCTAssertEqual(hostOnly?.action, .open)
        XCTAssertNil(hostOnly?.threadID)
        XCTAssertNil(PushTarget.parse(["verde": ["host_id": "a\u{1}b", "kind": "completed"]], action: ""))
        let target = PushTarget.parse(info, action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(presentationOptions(for: target, visible: "alpha/ws/th"), [])
        XCTAssertEqual(presentationOptions(for: target, visible: "alpha/ws/other"), [.banner, .list, .sound])
        XCTAssertEqual(presentationOptions(for: nil, visible: nil), [.banner, .list, .sound])
        let categories = PushTarget.categories()
        let approval = categories.first { $0.identifier == PushCategory.approval }
        XCTAssertEqual(approval?.actions.map(\.identifier), [PushCategory.approveAction, PushCategory.denyAction])
        XCTAssertTrue(approval?.actions.allSatisfy { $0.options.contains(.authenticationRequired) } == true)
        XCTAssertTrue(categories.first { $0.identifier == PushCategory.reply }?.actions.first is UNTextInputNotificationAction)
    }
}

// MARK: - Shared Keychain

private final class GroupKeychain: KeychainAPI {
    var items: [String: (group: String?, data: Data)] = [:]
    var queries: [[String: Any]] = []
    func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        let q = query as! [String: Any]
        queries.append(q)
        let group = q[kSecAttrAccessGroup as String] as? String
        let visible = items.filter { group == nil || $0.value.group == group }
        if q[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
            guard !visible.isEmpty else { return errSecItemNotFound }
            result.pointee = visible.keys.map { [kSecAttrAccount as String: $0] } as CFArray
            return errSecSuccess
        }
        guard let item = visible[q[kSecAttrAccount as String] as! String] else { return errSecItemNotFound }
        result.pointee = item.data as CFData
        return errSecSuccess
    }
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let q = query as! [String: Any]
        queries.append(q)
        let key = q[kSecAttrAccount as String] as! String
        guard let item = items[key] else { return errSecItemNotFound }
        items[key] = (item.group, (attributes as! [String: Any])[kSecValueData as String] as! Data)
        return errSecSuccess
    }
    func add(_ query: CFDictionary) -> OSStatus {
        let q = query as! [String: Any]
        queries.append(q)
        XCTAssertEqual(q[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        items[q[kSecAttrAccount as String] as! String] = (q[kSecAttrAccessGroup as String] as? String, q[kSecValueData as String] as! Data)
        return errSecSuccess
    }
    func remove(_ query: CFDictionary) -> OSStatus {
        let q = query as! [String: Any]
        queries.append(q)
        return items.removeValue(forKey: q[kSecAttrAccount as String] as! String) == nil ? errSecItemNotFound : errSecSuccess
    }
}

final class SharedKeychainTests: XCTestCase {
    let group = "ABCDE12345.dev.verdeai.app.shared"

    func testGroupNeedsATeamPrefix() {
        XCTAssertEqual(SharedKeychain.resolve(group), group)
        XCTAssertNil(SharedKeychain.resolve("dev.verdeai.app.shared"))
        XCTAssertNil(SharedKeychain.resolve(".dev.verdeai.app.shared"))
        XCTAssertNil(SharedKeychain.resolve("$(AppIdentifierPrefix)dev.verdeai.app.shared"))
        XCTAssertNil(SharedKeychain.resolve(nil))
        XCTAssertEqual(SharedKeychain.pushHost("vc/1/alpha/push"), "alpha")
        XCTAssertNil(SharedKeychain.pushHost("vc/1/alpha/credential"))
        XCTAssertNil(SharedKeychain.pushHost("vc/1//push"))
    }

    func testOnlyPushRecordsGoToTheSharedGroupAndTheExtensionReadsThem() throws {
        let api = GroupKeychain()
        let storage = KeychainStorage(api: api, sharedGroup: group)
        try storage.put("vc/1/alpha/push", value: Data("a".utf8))
        try storage.put("vc/1/beta/push", value: Data("b".utf8))
        try storage.put("vc/1/alpha/credential", value: Data("secret".utf8))
        try storage.put("ios/1/push", value: Data("state".utf8))
        XCTAssertEqual(api.items["vc/1/alpha/push"]?.group, group)
        XCTAssertNil(api.items["vc/1/alpha/credential"]?.group)
        XCTAssertNil(api.items["ios/1/push"]?.group)
        XCTAssertEqual(try storage.get("vc/1/alpha/push"), Data("a".utf8))

        let records = SharedKeychain.pushRecords(api: api, group: group)
        XCTAssertEqual(records.map(\.host), ["alpha", "beta"])
        XCTAssertEqual(records.map(\.record), [Data("a".utf8), Data("b".utf8)])
        XCTAssertTrue(api.queries.suffix(3).allSatisfy { $0[kSecAttrAccessGroup as String] as? String == group })

        try storage.delete("vc/1/alpha/push")
        XCTAssertEqual(SharedKeychain.pushRecords(api: api, group: group).map(\.host), ["beta"])
        XCTAssertTrue(SharedKeychain.pushRecords(api: GroupKeychain(), group: group).isEmpty)
    }
}

// MARK: - Relay

private final class RelayStub: URLProtocol {
    struct Call: Equatable {
        var method: String
        var url: String
        var body: [String: String]
    }
    private static let lock = NSLock()
    private static var log: [Call] = []
    private static var handler: (Call) -> (Int, [String: Any]?) = { _ in (500, nil) }
    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return log }
    static func reset(_ respond: @escaping (Call) -> (Int, [String: Any]?)) {
        lock.lock(); log = []; handler = respond; lock.unlock()
    }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let call = Call(method: request.httpMethod ?? "", url: request.url?.absoluteString ?? "",
                        body: (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:])
        Self.lock.lock()
        Self.log.append(call)
        let respond = Self.handler
        Self.lock.unlock()
        let (status, body) = respond(call)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!,
            cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let token = Data((0..<32).map { UInt8($0) })
private let tokenHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

final class PushRelayTests: XCTestCase {
    func testConfigReadsRelayAndEnvironmentFromInfo() {
        XCTAssertNil(PushConfig(info: [:]).relayURL)
        XCTAssertNil(PushConfig(info: ["VerdePushRelayURL": ""]).relayURL)
        XCTAssertNil(PushConfig(info: ["VerdePushRelayURL": "http://relay.test"]).relayURL)
        XCTAssertNil(PushConfig(info: ["VerdePushRelayURL": "https://relay.test/?x=1"]).relayURL)
        XCTAssertEqual(PushConfig(info: ["VerdePushRelayURL": " https://relay.test "]).relayURL?.absoluteString, "https://relay.test")
        XCTAssertEqual(PushConfig(info: ["VerdeAPSEnvironment": "development"]).environment, "sandbox")
        XCTAssertEqual(PushConfig(info: [:]).environment, "sandbox")
        XCTAssertEqual(PushConfig(info: ["VerdeAPSEnvironment": "production"]).environment, "production")
        XCTAssertEqual(token.pushTokenHex, tokenHex)
    }

    func testRegisterAndDeleteFollowTheRelayContract() async throws {
        RelayStub.reset { call in call.method == "POST" ? (201, ["send_token": "v1.abc.def"]) : (204, nil) }
        let relay = PushRelayClient(base: URL(string: "https://relay.test/base")!, session: RelayStub.session())
        let send = try await relay.register(token: tokenHex, environment: "sandbox")
        XCTAssertEqual(send, "v1.abc.def")
        try await relay.unregister(sendToken: send)
        XCTAssertEqual(RelayStub.calls, [
            .init(method: "POST", url: "https://relay.test/base/v1/register",
                  body: ["platform": "ios", "push_token": tokenHex, "environment": "sandbox"]),
            .init(method: "DELETE", url: "https://relay.test/base/v1/register", body: ["send_token": "v1.abc.def"]),
        ])
    }

    func testRelayErrors() async throws {
        let relay = PushRelayClient(base: URL(string: "https://relay.test")!, session: RelayStub.session())
        RelayStub.reset { _ in (410, ["error": "gone"]) }
        try await relay.unregister(sendToken: "v1.x.y") // Already revoked: success.
        for (status, body) in [(503, nil), (429, nil), (302, nil), (201, ["send_token": ""]), (201, ["other": "x"])] as [(Int, [String: Any]?)] {
            RelayStub.reset { _ in (status, body) }
            do {
                _ = try await relay.register(token: tokenHex, environment: "production")
                XCTFail("status \(status) should fail")
            } catch let error as PushRelayError {
                XCTAssertEqual(error, status == 201 ? .invalidResponse : .status(status))
            }
            XCTAssertEqual(RelayStub.calls.count, 1, "redirects are not followed")
        }
    }
}

// MARK: - Registration

@MainActor
private final class FakeSystem: PushSystem {
    var status: PushAuthorization = .authorized
    var grant = true
    var requests = 0
    var remoteRegistrations = 0
    func authorization() async -> PushAuthorization { status }
    func requestAuthorization() async -> Bool {
        requests += 1
        if grant { status = .authorized }
        return grant
    }
    func registerForRemoteNotifications() { remoteRegistrations += 1 }
}

@MainActor
private final class FakeHosts: PushHosts {
    var pushCatalogLoaded = true
    var pushHostIDs: [String] = []
    var views: [String: HostView] = [:]
    var accept = true
    var registrations: [(host: String, send: String, seed: String)] = []
    func pushView(_ id: String) -> HostView? { views[id] }
    func pushRegister(_ id: String, sendToken: String, keySeed: String) async -> Bool {
        registrations.append((id, sendToken, keySeed))
        return accept
    }
    func add(_ id: String, auth: String = "paired", ready: Bool = true) {
        if !pushHostIDs.contains(id) { pushHostIDs.append(id) }
        var view = hostView(id, id, phase: ready ? "ready" : "connecting", lifecycle: .foreground, auth: auth, sync: "ready")
        view.capabilities = ["device.push.v1"]
        view.scopes = ["device:write", "chat:write"]
        views[id] = view
    }
}

@MainActor
final class PushRegistryTests: XCTestCase {
    private func registry(relay: String? = "https://relay.test", storage: MemoryStorage = MemoryStorage(),
                          system: FakeSystem, hosts: FakeHosts) -> PushRegistry {
        // The stub runs on URLSession's queue; the counter is only touched there.
        var sends = 0
        RelayStub.reset { call in
            guard call.method == "POST" else { return (204, nil) }
            sends += 1
            return (201, ["send_token": "v1.send\(sends).mac"])
        }
        let registry = PushRegistry(config: PushConfig(relayURL: relay.flatMap { URL(string: $0) }, environment: "sandbox"),
                                    storage: storage, system: system, session: RelayStub.session(), keySeed: { "c2VlZA==" })
        registry.hosts = hosts
        return registry
    }

    private func state(_ storage: MemoryStorage) throws -> PushState {
        try JSONDecoder().decode(PushState.self, from: XCTUnwrap(storage.values[PushRegistry.stateKey]))
    }

    func testRegistersEachReadyHostWithItsOwnCapability() async throws {
        let storage = MemoryStorage(), system = FakeSystem(), hosts = FakeHosts()
        hosts.add("alpha")
        hosts.add("beta", ready: false)
        let registry = registry(storage: storage, system: system, hosts: hosts)
        await registry.refresh()
        XCTAssertEqual(system.remoteRegistrations, 1)
        registry.deviceToken(token)
        await registry.settle()
        XCTAssertEqual(RelayStub.calls.map(\.method), ["POST"])
        XCTAssertEqual(RelayStub.calls.first?.body["push_token"], tokenHex)
        XCTAssertEqual(hosts.registrations.map(\.host), ["alpha"])
        XCTAssertEqual(hosts.registrations.first?.send, "v1.send1.mac")

        hosts.add("beta")
        registry.hostChanged("beta")
        await registry.settle()
        XCTAssertEqual(hosts.registrations.map(\.send), ["v1.send1.mac", "v1.send2.mac"])
        let saved = try state(storage)
        XCTAssertEqual(saved.hosts["alpha"]?.send_token, "v1.send1.mac")
        XCTAssertEqual(saved.hosts["beta"]?.send_token, "v1.send2.mac")
        XCTAssertEqual(saved.hosts["alpha"]?.token_digest, PushRegistry.digest(token: tokenHex, environment: "sandbox"))

        // Same token on the next launch: no new capability, the host is registered again (idempotent).
        let again = self.registry(storage: storage, system: system, hosts: hosts)
        await again.refresh()
        again.deviceToken(token)
        await again.settle()
        XCTAssertEqual(RelayStub.calls, [])
        XCTAssertEqual(hosts.registrations.count, 4)
    }

    func testTokenRotationRegistersNewThenDeletesOld() async throws {
        let storage = MemoryStorage(), system = FakeSystem(), hosts = FakeHosts()
        hosts.add("alpha")
        let registry = registry(storage: storage, system: system, hosts: hosts)
        await registry.refresh()
        registry.deviceToken(token)
        await registry.settle()

        hosts.accept = false
        registry.deviceToken(Data(repeating: 7, count: 32))
        await registry.settle()
        // The host hasn't confirmed the new capability: the old one is kept.
        XCTAssertEqual(RelayStub.calls.map(\.method), ["POST", "POST"])
        XCTAssertEqual(try state(storage).hosts["alpha"]?.previous, "v1.send1.mac")

        hosts.accept = true
        await registry.refresh() // Next foreground retries.
        await registry.settle()
        XCTAssertEqual(hosts.registrations.map(\.send), ["v1.send1.mac", "v1.send2.mac", "v1.send2.mac"])
        XCTAssertEqual(RelayStub.calls.last, .init(method: "DELETE", url: "https://relay.test/v1/register", body: ["send_token": "v1.send1.mac"]))
        let saved = try state(storage)
        XCTAssertEqual(saved.hosts["alpha"]?.send_token, "v1.send2.mac")
        XCTAssertNil(saved.hosts["alpha"]?.previous)
        XCTAssertEqual(saved.retired, [])
    }

    func testSignOutAndRemovalDeleteTheHostCapability() async throws {
        let storage = MemoryStorage(), system = FakeSystem(), hosts = FakeHosts()
        hosts.add("alpha")
        hosts.add("beta")
        let registry = registry(storage: storage, system: system, hosts: hosts)
        await registry.refresh()
        registry.deviceToken(token)
        await registry.settle()

        RelayStub.reset { _ in (503, nil) }
        hosts.add("alpha", auth: "signed_out")
        registry.hostChanged("alpha")
        await registry.settle()
        XCTAssertNil(try state(storage).hosts["alpha"])
        XCTAssertEqual(try state(storage).retired, ["v1.send1.mac"], "kept for retry while the relay is down")

        RelayStub.reset { _ in (204, nil) }
        hosts.pushHostIDs = []
        hosts.views = [:]
        registry.hostChanged("beta")
        await registry.settle()
        XCTAssertEqual(Set(RelayStub.calls.map { $0.body["send_token"] }), ["v1.send1.mac", "v1.send2.mac"])
        XCTAssertTrue(RelayStub.calls.allSatisfy { $0.method == "DELETE" })
        XCTAssertEqual(try state(storage), PushState())
    }

    func testNothingIsRetiredBeforeTheCatalogLoads() async throws {
        let storage = MemoryStorage(), system = FakeSystem(), hosts = FakeHosts()
        hosts.add("alpha")
        let registry = registry(storage: storage, system: system, hosts: hosts)
        await registry.refresh()
        registry.deviceToken(token)
        await registry.settle()
        hosts.pushCatalogLoaded = false
        hosts.pushHostIDs = []
        registry.hostChanged("alpha")
        await registry.settle()
        XCTAssertEqual(try state(storage).hosts["alpha"]?.send_token, "v1.send1.mac")
    }

    func testWithoutARelayURLNothingRegisters() async throws {
        let storage = MemoryStorage(), system = FakeSystem(), hosts = FakeHosts()
        hosts.add("alpha", auth: "unpaired")
        system.status = .notDetermined
        let registry = registry(relay: nil, storage: storage, system: system, hosts: hosts)
        XCTAssertFalse(registry.available)
        registry.hostChanged("alpha")
        hosts.add("alpha")
        registry.hostChanged("alpha") // A completed pair doesn't prompt in a build without push.
        await registry.refresh()
        registry.deviceToken(token)
        await registry.settle()
        XCTAssertEqual(system.requests, 0)
        XCTAssertEqual(system.remoteRegistrations, 0)
        XCTAssertEqual(RelayStub.calls, [])
        XCTAssertTrue(hosts.registrations.isEmpty)
        XCTAssertNil(storage.values[PushRegistry.stateKey])
    }

    func testPermissionIsRequestedAfterAPairNotAtLaunch() async throws {
        let system = FakeSystem(), hosts = FakeHosts()
        system.status = .notDetermined
        hosts.add("alpha") // Already paired at launch: no prompt.
        let registry = registry(system: system, hosts: hosts)
        await registry.refresh()
        registry.hostChanged("alpha")
        hosts.add("beta", auth: "unpaired")
        registry.hostChanged("beta")
        await registry.settle()
        XCTAssertEqual(system.requests, 0)
        XCTAssertEqual(system.remoteRegistrations, 0)

        hosts.add("beta")
        registry.hostChanged("beta")
        try await waitUntil("permission requested") { system.requests == 1 && system.remoteRegistrations == 1 }
        XCTAssertEqual(registry.authorization, .authorized)
    }

    func testDeniedPermissionRetiresCapabilities() async throws {
        let storage = MemoryStorage(), system = FakeSystem(), hosts = FakeHosts()
        hosts.add("alpha")
        let registry = registry(storage: storage, system: system, hosts: hosts)
        await registry.refresh()
        registry.deviceToken(token)
        await registry.settle()
        system.status = .denied
        await registry.refresh()
        await registry.settle()
        XCTAssertEqual(RelayStub.calls.last?.method, "DELETE")
        XCTAssertEqual(try state(storage), PushState())
    }
}

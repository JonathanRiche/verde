import XCTest
@testable import VerdeApp

/// Stand-in for the core's lifecycle and sign-out/forget/retry behaviour. Every
/// batch invalidates `hosts`; secure-store deletes round-trip through the real
/// CoreHost effect executor and HostScopedStorage.
private final class HostsCore: HostCore {
    let saved: SavedHost
    let events = EventLog()
    private let lock = NSLock()
    private var row: HostView
    private var op: CoreOperation?
    private var record = "credential"
    private var sequence = 0
    private var started = false
    private let offline: Bool
    private let deleteDelayMs: UInt32
    var rejectRetry = false

    init(_ saved: SavedHost, offline: Bool, revoked: Bool, deleteDelayMs: UInt32) {
        self.saved = saved
        self.offline = offline
        self.deleteDelayMs = deleteDelayMs
        row = hostView(saved.id, saved.label, phase: offline ? "failed" : "ready", auth: revoked ? "repair_required" : "paired")
    }

    func handle(_ bytes: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let event = try JSONDecoder().decode(Event.self, from: bytes)
        var effects: [Effect] = []
        func next() -> String { sequence += 1; return "e\(sequence)" }
        func delete() {
            effects.append(.secure_store_delete(EffectSecureStoreDelete(effect_id: next(), generation: "1",
                key: "vc/1/\(saved.id)/\(record)")))
        }
        func wipe(_ intent: String) {
            op = CoreOperation(intent_id: intent, state: "pending", error: nil)
            row.auth_state = "signing_out"
            row.error = nil
            if deleteDelayMs > 0 {
                effects.append(.set_timer(EffectSetTimer(effect_id: next(), generation: "1", timer_id: "delete",
                    delay_ms: deleteDelayMs, purpose: "test")))
            } else { delete() }
        }
        switch event {
        case .start:
            guard !started else { throw CoreBridgeError.status(4) }
            started = true
        case .foreground, .background, .network_changed:
            guard started else { throw CoreBridgeError.status(4) }
            if case .foreground = event { row.lifecycle = .foreground }
            if case .background = event { row.lifecycle = .background }
        case .sign_out(let e):
            XCTAssertEqual(e.host_id, saved.id)
            if offline {
                op = CoreOperation(intent_id: e.intent_id, state: "uncertain", error: LocalError(domain: "auth",
                    code: "sign_out_unconfirmed", message: "", retryable: true))
            } else { wipe(e.intent_id) }
        case .forget_host(let e):
            XCTAssertEqual(e.host_id, saved.id)
            wipe(e.intent_id)
        case .retry_connection(let e):
            if rejectRetry { throw CoreBridgeError.status(5) }
            if op?.error?.code == "sign_out_delete_failed" { wipe(e.intent_id) }
        case .timer_fired(let e) where e.timer_id == "delete":
            delete()
        case .secure_store_done(let e):
            if e.error != nil {
                op?.state = "failed"
                op?.error = LocalError(domain: "storage", code: "sign_out_delete_failed", message: "", retryable: true)
            } else if record == "credential" {
                record = "profile"
                delete()
            } else {
                record = "credential"
                row.auth_state = "signed_out"
                op?.state = "succeeded"
                op?.error = nil
            }
        default: break
        }
        events.append(event)
        effects.append(.state_changed(EffectStateChanged(effect_id: next(), generation: "1",
            revision: String(sequence), scopes: ["hosts", "operations"])))
        return try encoded(EffectBatch(api_version: 1, revision: String(sequence), effects: effects))
    }

    func query(_ selector: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if selector == "operations" {
            return try encoded(OperationsQuery(api_version: 1, revision: String(sequence),
                data: OperationsView(items: op.map { [$0] } ?? []), error: nil))
        }
        return try encoded(HostsQuery(api_version: 1, revision: String(sequence),
            data: HostsView(items: [row], operations: op.map { [$0] } ?? []), error: nil))
    }

    func close() {}
}

@MainActor
final class HostsModelTests: XCTestCase {
    private var storage = MemoryStorage()
    private var cores: [HostsCore] = []
    private var models: [HostsModel] = []
    private var offline = false
    private var revoked = false
    private var deleteDelayMs: UInt32 = 0
    private var legacy: String?

    override func tearDown() async throws {
        for model in models { await model.close() }
        models = []
        cores = []
    }

    private func seed() throws {
        storage.set(HostsModel.catalogKey, try encoded(HostCatalog(hosts: [SavedHost(id: "alpha", label: "Alpha"),
            SavedHost(id: "beta", label: "Beta")], active: "alpha")))
        for id in ["alpha", "beta"] { for record in ["credential", "profile"] { storage.set("vc/1/\(id)/\(record)", Data("fixture".utf8)) } }
    }

    private func core(_ id: String) -> HostsCore { cores.last { $0.saved.id == id }! }

    private func launch(waitReady: Bool = true) async throws -> HostsModel {
        let storage = self.storage
        let legacy = self.legacy
        let model = HostsModel(storage: storage, cache: nil, deviceLabel: "Test phone", legacyID: { legacy }) { [unowned self] saved, store in
            let fake = HostsCore(saved, offline: self.offline, revoked: self.revoked, deleteDelayMs: self.deleteDelayMs)
            self.cores.append(fake)
            return CoreHost(core: fake, store: store, transport: NullTransport(),
                            storage: HostScopedStorage(base: storage, hostID: saved.id))
        }
        models.append(model)
        model.foreground(true)
        model.network(NetworkState(available: true, id: "net-1"))
        model.begin()
        if waitReady {
            try await waitUntil("hosts ready") { !model.loading && model.rows.allSatisfy { $0.view?.lifecycle == .foreground } }
        }
        return model
    }

    private func catalog() throws -> HostCatalog {
        try JSONDecoder().decode(HostCatalog.self, from: XCTUnwrap(storage.values[HostsModel.catalogKey]))
    }

    func testListsIndependentHostsSwitchesAndRestoresSelection() async throws {
        try seed()
        let model = try await launch()
        XCTAssertEqual(model.rows.map(\.saved.label), ["Alpha", "Beta"])
        XCTAssertEqual(hostStatus(try XCTUnwrap(model.row("alpha"))), "Connected")
        model.select("beta")
        XCTAssertEqual(model.active, "beta")
        XCTAssertEqual(try catalog().active, "beta")
        await model.close()
        let restored = try await launch()
        XCTAssertEqual(restored.active, "beta")
        XCTAssertEqual(restored.rows.count, 2)
    }

    func testSignalsReachEachCoreInOrderAndDeduplicate() async throws {
        try seed()
        let model = try await launch()
        for id in ["alpha", "beta"] {
            XCTAssertEqual(Array(core(id).events.kinds.prefix(3)), ["start", "network_changed", "foreground"])
        }
        model.foreground(true)
        model.network(NetworkState(available: true, id: "net-1"))
        model.foreground(false)
        model.network(NetworkState(available: true, id: "net-2"))
        model.foreground(true)
        try await waitUntil("signals delivered") { core("alpha").events.kinds.count == 6 && core("beta").events.kinds.count == 6 }
        XCTAssertEqual(core("alpha").events.kinds, ["start", "network_changed", "foreground", "background", "network_changed", "foreground"])
    }

    func testSignOutIsHostScopedAndRemovalWaitsForDeleteAcknowledgements() async throws {
        try seed()
        deleteDelayMs = 300
        let model = try await launch()
        model.signOut("alpha")
        try await waitUntil("signing out") { model.row("alpha")?.view?.auth_state == "signing_out" }
        XCTAssertEqual(hostStatus(try XCTUnwrap(model.row("alpha"))), "Removing local data")
        model.remove("alpha")
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertNotNil(storage.values["vc/1/alpha/credential"])
        XCTAssertEqual(core("beta").events.count { if case .sign_out = $0 { return true }; return false }, 0)
        try await waitUntil("signed out") { model.row("alpha")?.view?.auth_state == "signed_out" }
        XCTAssertNil(storage.values["vc/1/alpha/credential"])
        XCTAssertNil(storage.values["vc/1/alpha/profile"])
        XCTAssertNotNil(storage.values["vc/1/beta/credential"])
        model.remove("alpha")
        XCTAssertEqual(model.rows.map(\.saved.id), ["beta"])
        XCTAssertEqual(model.active, "beta")
        XCTAssertEqual(try catalog().hosts.map(\.id), ["beta"])
    }

    func testOfflineSignOutOffersExplicitForget() async throws {
        try seed()
        offline = true
        let model = try await launch()
        XCTAssertEqual(hostStatus(try XCTUnwrap(model.row("alpha"))), "Unreachable — is Tailscale on?")
        model.signOut("alpha")
        try await waitUntil("unconfirmed") { model.row("alpha")?.operation?.error?.code == "sign_out_unconfirmed" }
        XCTAssertTrue(storage.deletes.isEmpty)
        XCTAssertEqual(model.row("alpha")?.view?.auth_state, "paired")
        try await waitUntil("action settled") { model.row("alpha")?.busy == false }
        model.signOut("alpha", forget: true)
        try await waitUntil("forgotten") { model.row("alpha")?.view?.auth_state == "signed_out" }
        XCTAssertEqual(core("alpha").events.count { if case .forget_host = $0 { return true }; return false }, 1)
        XCTAssertNotNil(storage.values["vc/1/beta/credential"])
    }

    func testDeleteFailureRetriesThroughCoreWithoutRepeatingRevoke() async throws {
        try seed()
        let model = try await launch()
        storage.fail(delete: true)
        model.signOut("alpha")
        try await waitUntil("delete failed") { model.row("alpha")?.operation?.error?.code == "sign_out_delete_failed" }
        XCTAssertNotEqual(model.row("alpha")?.view?.auth_state, "signed_out")
        storage.fail()
        try await waitUntil("action settled") { model.row("alpha")?.busy == false }
        model.retry("alpha")
        try await waitUntil("signed out") { model.row("alpha")?.view?.auth_state == "signed_out" }
        XCTAssertEqual(core("alpha").events.count { if case .sign_out = $0 { return true }; return false }, 1)
        XCTAssertEqual(core("alpha").events.count { if case .retry_connection = $0 { return true }; return false }, 1)
    }

    func testRevokedStatusAndRejectedActionAreRecoverable() async throws {
        try seed()
        revoked = true
        let model = try await launch()
        XCTAssertTrue(hostStatus(try XCTUnwrap(model.row("alpha"))).contains("Pair again"))
        core("alpha").rejectRetry = true
        model.retry("alpha")
        try await waitUntil("rejected") { model.error != nil }
        XCTAssertEqual(model.error, "This host is still loading or finishing an action. Try again shortly.")
        XCTAssertEqual(model.row("alpha")?.fatal, false)
        try await waitUntil("action settled") { model.row("alpha")?.busy == false }
        model.signOut("alpha")
        try await waitUntil("signed out") { model.row("alpha")?.view?.auth_state == "signed_out" }
    }

    func testCatalogReadFailureDoesNotEraseHostsAndCanRetry() async throws {
        try seed()
        storage.fail(read: true)
        let model = try await launch(waitReady: false)
        XCTAssertTrue(model.loading)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(storage.deletes.isEmpty)
        storage.fail()
        model.load()
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertNotNil(storage.values["vc/1/alpha/credential"])
    }

    func testFailedSelectionWritePreservesActiveHost() async throws {
        try seed()
        let model = try await launch()
        storage.fail(write: true)
        model.select("beta")
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.active, "alpha")
        storage.fail()
        XCTAssertEqual(try catalog().active, "alpha")
        model.select("beta")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.active, "beta")
    }

    func testAddPersistsUniqueHostAndSeedsPrimarySlot() async throws {
        let model = try await launch()
        XCTAssertEqual(model.active, "primary")
        model.add(label: "  Second host  ")
        XCTAssertEqual(model.rows.count, 2)
        let added = try XCTUnwrap(model.rows.last?.saved)
        XCTAssertNotEqual(added.id, "primary")
        XCTAssertEqual(added.label, "Second host")
        XCTAssertEqual(model.pairing, added.id)
        XCTAssertEqual(model.active, added.id)
        XCTAssertEqual(try catalog().hosts.map(\.label), ["My host", "Second host"])
        // Non-pairing URLs are ignored rather than opening a host slot.
        model.open(url: try XCTUnwrap(URL(string: "https://verdeai.dev/other")))
        XCTAssertEqual(model.rows.count, 2)
    }

    func testLegacySingleHostMigratesIntoCatalog() async throws {
        legacy = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let model = try await launch()
        XCTAssertEqual(model.rows.map(\.saved.id), ["0f8fad5b-d9cb-469f-a165-70867728950e"])
        XCTAssertEqual(try catalog().active, "0f8fad5b-d9cb-469f-a165-70867728950e")
    }

    func testCatalogValidationAndScopedStorage() throws {
        XCTAssertTrue(HostsModel.validID("abc_DEF-123"))
        XCTAssertFalse(HostsModel.validID(""))
        XCTAssertFalse(HostsModel.validID("a/b"))
        XCTAssertFalse(HostsModel.validID(String(repeating: "a", count: 129)))
        XCTAssertFalse(HostsModel.valid(HostCatalog(hosts: [SavedHost(id: "a", label: "A"), SavedHost(id: "a", label: "B")], active: nil)))
        XCTAssertFalse(HostsModel.valid(HostCatalog(hosts: [SavedHost(id: "a", label: " ")], active: nil)))
        XCTAssertFalse(HostsModel.valid(HostCatalog(hosts: [SavedHost(id: "a", label: "A")], active: "b")))
        XCTAssertFalse(HostsModel.valid(HostCatalog(hosts: (0...32).map { SavedHost(id: "h\($0)", label: "H") }, active: nil)))

        let base = MemoryStorage()
        let scoped = HostScopedStorage(base: base, hostID: "alpha")
        try scoped.put("vc/1/alpha/credential", value: Data([1]))
        XCTAssertEqual(try scoped.get("vc/1/alpha/credential"), Data([1]))
        for key in ["vc/1/beta/credential", "vc/1/alphabet/credential", HostsModel.catalogKey] {
            XCTAssertThrowsError(try scoped.put(key, value: Data([2])))
            XCTAssertThrowsError(try scoped.get(key))
            XCTAssertThrowsError(try scoped.delete(key))
        }
        XCTAssertEqual(base.values.keys.sorted(), ["vc/1/alpha/credential"])
    }
}

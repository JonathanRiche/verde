import XCTest
@testable import VerdeApp

private let NOW: Int64 = 1_700_000_100_000

/// Minimal stand-in for the core's host/sync behaviour: syncing and refreshing
/// complete through real `set_timer` → `timer_fired` round-trips, and every batch
/// invalidates hosts/home/workspaces with a new revision.
private final class BrowseCore: HostCore {
    let saved: SavedHost
    let events = EventLog()
    private let lock = NSLock()
    private var _syncDelayMs: UInt32? = 10
    private var _home = K09.homeLive
    private var _workspaces = K09.workspacesLive
    private var _afterRefresh: (HomeQuery, WorkspacesQuery)?
    private var row: HostView
    private var synced = false
    private var loading = false
    private var network = true
    private var sequence = 0

    init(_ saved: SavedHost) {
        self.saved = saved
        row = hostView(saved.id, saved.label, phase: "idle")
    }

    func configure(syncDelayMs: UInt32?? = nil, home: HomeQuery? = nil, workspaces: WorkspacesQuery? = nil,
                   afterRefresh: (HomeQuery, WorkspacesQuery)? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let syncDelayMs { _syncDelayMs = syncDelayMs }
        if let home { _home = home }
        if let workspaces { _workspaces = workspaces }
        if let afterRefresh { _afterRefresh = afterRefresh }
    }

    func handle(_ bytes: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let event = try JSONDecoder().decode(Event.self, from: bytes)
        events.append(event)
        var effects: [Effect] = []
        func next() -> String { sequence += 1; return "e\(sequence)" }
        func timer(_ id: String, _ delay: UInt32) {
            effects.append(.set_timer(EffectSetTimer(effect_id: next(), generation: "1", timer_id: id, delay_ms: delay, purpose: "test")))
        }
        func connect() {
            guard row.auth_state == "paired", row.lifecycle == .foreground, network, let delay = _syncDelayMs else { return }
            row.phase = "connecting"
            row.sync_state = synced ? "stale" : "loading"
            timer("sync", delay)
        }
        switch event {
        case .foreground: row.lifecycle = .foreground; connect()
        case .background: row.lifecycle = .background; row.phase = "disabled"
        case .network_changed(let e):
            network = e.available
            if network { connect() } else { row.phase = "disabled"; row.sync_state = synced ? "stale" : "empty" }
        case .timer_fired(let e):
            if e.timer_id == "sync", row.phase == "connecting" { synced = true; row.phase = "ready"; row.sync_state = "ready" }
            if e.timer_id == "refresh" {
                loading = false
                if let refreshed = _afterRefresh { _home = refreshed.0; _workspaces = refreshed.1 }
            }
        case .retry_connection: if row.phase == "ready" { loading = true; timer("refresh", 30) }
        case .sign_out:
            synced = false
            row.auth_state = "signed_out"; row.phase = "disabled"; row.sync_state = "empty"
        default: break
        }
        effects.append(.state_changed(EffectStateChanged(effect_id: next(), generation: "1", revision: String(sequence),
            scopes: ["hosts", "home", "workspaces"])))
        return try encoded(EffectBatch(api_version: 1, revision: String(sequence), effects: effects))
    }

    func query(_ selector: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let revision = String(sequence)
        switch selector {
        case "home":
            var home = _home
            home.revision = revision
            if synced { home.data?.loading = loading } else {
                home.data = HomeView(items: [], loading: row.sync_state == "loading", stale: false, incomplete_scopes: [], error: nil)
            }
            return try encoded(home)
        case "workspaces":
            var workspaces = _workspaces
            workspaces.revision = revision
            if synced { workspaces.data?.loading = loading } else {
                workspaces.data = WorkspacesView(items: [], loading: row.sync_state == "loading", stale: false, error: nil,
                    history: HistoryView(query: "", items: [], next_cursor: nil, loading: false, error: nil))
            }
            return try encoded(workspaces)
        default:
            return try encoded(HostsQuery(api_version: 1, revision: revision, data: HostsView(items: [row], operations: []), error: nil))
        }
    }

    func close() {}
}

@MainActor
final class BrowseTests: XCTestCase {
    private var storage = MemoryStorage()
    private var directory: URL!
    private var cache: ViewCache!
    private var hosts: HostsModel!
    private var browse: BrowseModel!
    private var cores: [BrowseCore] = []
    private var setup: (BrowseCore) -> Void = { _ in }
    private var core: BrowseCore { cores.last! }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("browse-\(UUID().uuidString)")
        cache = ViewCache(directory: directory, keys: MemoryStorage())
    }

    override func tearDown() async throws {
        await hosts?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func launch(network: NetworkState = NetworkState(available: true, id: "net-1")) throws {
        storage.set(HostsModel.catalogKey, try encoded(HostCatalog(hosts: [SavedHost(id: "alpha", label: "Studio")], active: "alpha")))
        let hosts = HostsModel(storage: storage, cache: cache, deviceLabel: "Test phone") { [unowned self] saved, store in
            let fake = BrowseCore(saved)
            self.setup(fake)
            self.cores.append(fake)
            return CoreHost(core: fake, store: store, transport: NullTransport(),
                            storage: HostScopedStorage(base: storage, hostID: saved.id))
        }
        self.hosts = hosts
        browse = BrowseModel(hosts: hosts, cache: cache, wallClock: { NOW }, saveInterval: 0.05)
        hosts.foreground(true)
        hosts.network(network)
        hosts.begin()
    }

    func testSignOutClearsCachedAndShownViews() async throws {
        try launch()
        try await waitUntil("live home") { browse.state.home?.items.isEmpty == false }
        try await waitUntil("cache saved") { cache.load("alpha") != nil }
        hosts.signOut("alpha")
        try await waitUntil("signed out") { hosts.row("alpha")?.view?.auth_state == "signed_out" }
        XCTAssertNil(cache.load("alpha"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("alpha.views").path))
        XCTAssertNil(browse.state.home)
        XCTAssertNil(browse.state.workspaces)
        XCTAssertTrue(needsPairing(browse.state))
        XCTAssertNil(browseBanner(browse.state, NOW))
    }
}

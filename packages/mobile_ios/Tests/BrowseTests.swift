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

    func testHomeShowsAttentionRunningAndTimersAfterOrderedSignals() async throws {
        try launch()
        try await waitUntil("live home") { browse.state.home?.items.isEmpty == false }
        let state = browse.state
        XCTAssertTrue(hasContent(state))
        XCTAssertNil(browseBanner(state, NOW))
        XCTAssertEqual(hostStatus(try XCTUnwrap(state.row)), "Connected")
        let panes = try XCTUnwrap(state.home?.items)
        XCTAssertEqual(panes.filter(\.attention).map { paneLine($0, NOW) }, ["Chat · Needs approval · 1:00", "Terminal · Running"])
        XCTAssertEqual(panes.filter { !$0.attention }.map { paneLine($0, NOW) }, ["Chat · Working · 0:55"])
        XCTAssertFalse(recentThreads(state.workspaces).contains { $0.title == "Child" })
        // Platform signals reach the core in order: start → network → foreground.
        XCTAssertEqual(Array(core.events.kinds.prefix(3)), ["start", "network_changed", "foreground"])
        let networks = core.events.all.compactMap { event -> String? in
            if case .network_changed(let e) = event { return e.network_id }; return nil
        }
        XCTAssertEqual(networks, ["net-1"])
    }

    func testPullToRefreshSendsRetryAndShowsRefreshedProjection() async throws {
        setup = { $0.configure(afterRefresh: (K09.home, K09.workspaces)) }
        try launch()
        try await waitUntil("live home") { browse.state.home?.items.isEmpty == false }
        await browse.refresh()
        XCTAssertEqual(core.events.count { if case .retry_connection = $0 { return true }; return false }, 1)
        try await waitUntil("refreshed") { browse.state.home?.items.isEmpty == true }
        XCTAssertFalse(browse.state.refreshing)
    }

    func testWarmStartShowsCacheUntilLiveSyncThenSavesLiveViews() async throws {
        XCTAssertTrue(cache.save("alpha", CachedViews(saved_at_ms: NOW - 3 * 60_000,
            home: try XCTUnwrap(K09.homeLive.data), workspaces: try XCTUnwrap(K09.workspacesLive.data))))
        setup = { $0.configure(syncDelayMs: .some(nil), home: K09.home, workspaces: K09.workspaces) }
        try launch()
        try await waitUntil("cached banner") {
            browseBanner(browse.state, NOW)?.text.contains("Showing saved data from 3 min ago.") == true
        }
        XCTAssertEqual(browse.state.home?.items.count, 3)
        XCTAssertTrue(hasContent(browse.state))
        // A route change lets the (fake) core finish its first sync.
        core.configure(syncDelayMs: .some(10))
        hosts.network(NetworkState(available: true, id: "net-2"))
        try await waitUntil("live views") { browse.state.savedAtMs == nil && browse.state.home?.items.isEmpty == true }
        try await waitUntil("saved live views") { cache.load("alpha")?.home.items.isEmpty == true }
        XCTAssertEqual(cache.load("alpha")?.saved_at_ms, NOW)
    }

    func testOfflineWithoutCacheShowsOfflineAndNoData() async throws {
        try launch(network: NetworkState(available: false, id: ""))
        try await waitUntil("offline banner") { browseBanner(browse.state, NOW)?.text == "You're offline." }
        XCTAssertFalse(hasContent(browse.state))
        XCTAssertFalse(showSpinner(browse.state))
        let available = core.events.all.compactMap { event -> Bool? in
            if case .network_changed(let e) = event { return e.available }; return nil
        }
        XCTAssertEqual(available, [false])
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

    func testBannerAndLabelRules() throws {
        let row = HostRow(saved: SavedHost(id: "a", label: "Studio"), view: hostView("a", "Studio", lifecycle: .foreground, sync: "ready"))
        let ready = BrowseState(hostID: "a", row: row, home: K09.home.data, workspaces: K09.workspaces.data)
        XCTAssertNil(browseBanner(ready, NOW))
        var offline = ready
        offline.networkAvailable = false
        offline.savedAtMs = NOW - 5 * 60_000
        XCTAssertEqual(browseBanner(offline, NOW)?.text, "You're offline. Showing saved data from 5 min ago.")
        var unreachable = ready
        unreachable.row?.view?.phase = "failed"
        unreachable.row?.view?.error = LocalError(domain: "net", code: "x", message: "", failure_kind: "network")
        XCTAssertEqual(browseBanner(unreachable, NOW)?.action, .retry)
        XCTAssertEqual(browseBanner(unreachable, NOW)?.text, "Can't reach Studio. Is Tailscale on?")
        var repair = ready
        repair.row?.view?.auth_state = "repair_required"
        XCTAssertEqual(browseBanner(repair, NOW)?.action, .hosts)
        var failed = ready
        failed.home?.error = LocalError(domain: "rpc", code: "x", message: "", retryable: true)
        XCTAssertTrue(browseBanner(failed, NOW)?.text.hasPrefix("Couldn't load") == true)
        var loading = ready
        loading.row?.view?.sync_state = "loading"
        XCTAssertFalse(hasContent(loading))
        XCTAssertTrue(showSpinner(loading))
        var fatal = ready
        fatal.row?.fatal = true
        XCTAssertEqual(browseBanner(fatal, NOW), Banner(text: "Connection unavailable — reopen Verde.", error: true))
        var unpaired = ready
        unpaired.row?.view?.auth_state = "unpaired"
        XCTAssertTrue(needsPairing(unpaired))

        XCTAssertEqual(elapsedLabel(0, 3_665_000), "1:01:05")
        XCTAssertEqual(elapsedLabel(10, 0), "0:00")
        XCTAssertEqual(agoLabel(0, 2 * 3_600_000 + 5), "2 h ago")
        XCTAssertEqual(agoLabel(0, 30_000), "just now")
        XCTAssertEqual(agoLabel(0, 3 * 86_400_000), "3 d ago")
        XCTAssertEqual(recentThreads(K09.workspaces.data).map(\.title), ["Web chat", "Layout chat"])
        XCTAssertEqual(statusLabel("waiting_approval"), "Needs approval")
        XCTAssertEqual(statusLabel("some_state"), "Some state")
        XCTAssertEqual(attentionLabel("unread"), "Unread")
        XCTAssertEqual(attentionLabel("needs_approval"), "Needs approval")
        XCTAssertNil(attentionLabel(nil))
        let workspace = try XCTUnwrap(K09.workspaces.data?.items.first)
        XCTAssertFalse(openable(try XCTUnwrap(workspace.panes.first { $0.kind == "browser" })))
        XCTAssertFalse(openable(try XCTUnwrap(workspace.panes.first { $0.kind == "terminal" })))
        let threads = workspaceThreads(workspace)
        XCTAssertFalse(threads.contains(where: isSubagent))
        XCTAssertEqual(threads.map { $0.last_activity_at_ms ?? 0 }, threads.map { $0.last_activity_at_ms ?? 0 }.sorted(by: >))

        var flagged = try XCTUnwrap(K09.workspacesLive.data?.items.first)
        flagged.panes = flagged.panes.map { pane in
            var pane = pane
            if pane.thread_id == "layout-thread" { pane.attention_kind = "needs_approval" }
            return pane
        }
        let summary = workspaceSummary(flagged)
        XCTAssertTrue(summary.summary.contains("1 terminal"))
        XCTAssertTrue(summary.summary.contains("active"))
        XCTAssertEqual(summary.badge, "1 needs attention")
        flagged.open = false
        XCTAssertTrue(workspaceSummary(flagged).summary.hasSuffix(" · closed"))
    }
}

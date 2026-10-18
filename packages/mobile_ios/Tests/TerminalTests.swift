import UIKit
import XCTest
@testable import VerdeApp

private final class FixtureMarker {}

/// K-12 fixtures: `k12-tail.json` is the core's recorded daemon tail
/// (packages/client_core/src/fixtures/terminal/tail.json) and `k12-snapshot.json` the
/// committed real `vc_term_snapshot` for it (see the Android k12 fixture README).
enum K12 {
    private static func data(_ name: String) -> Data {
        guard let url = Bundle(for: FixtureMarker.self).url(forResource: "k12-\(name)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { fatalError("missing k12 fixture") }
        return data
    }
    static var tail: Data {
        let object = try? JSONSerialization.jsonObject(with: data("tail")) as? [String: Any]
        return Data(((object?["text"] as? String) ?? "").utf8)
    }
    static var snapshotData: Data { data("snapshot") }
    static var snapshot: TerminalSnapshot { try! JSONDecoder().decode(TerminalSnapshot.self, from: snapshotData) }
}

private func sameJSON(_ a: Data, _ b: Data) -> Bool {
    guard let x = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
          let y = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return false }
    return x.isEqual(y)
}

private func cellsJSON(_ snapshot: TerminalSnapshot?) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return snapshot.flatMap { try? encoder.encode($0.cells) }
}

/// The real core VT with every call recorded (counts only; bytes are fixture data).
final class RecordingBridge: TerminalBridge {
    private let base = NativeTerminalBridge.shared
    private let lock = NSLock()
    private var _configs: [TerminalConfig] = []
    private var _writes: [Data] = []
    private var _resizes: [GridSize] = []
    private var _scrolls: [Int32] = []
    private var _live = 0
    private var _frees = 0

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var configs: [TerminalConfig] { locked { _configs } }
    var writes: [Data] { locked { _writes } }
    var resizes: [GridSize] { locked { _resizes } }
    var scrolls: [Int32] { locked { _scrolls } }
    var live: Int { locked { _live } }
    var frees: Int { locked { _frees } }

    func create(_ config: Data) throws -> OpaquePointer {
        let term = try base.create(config)
        let decoded = try JSONDecoder().decode(TerminalConfig.self, from: config)
        locked { _configs.append(decoded); _live += 1 }
        return term
    }
    func write(_ term: OpaquePointer, _ bytes: Data) -> Int32 { locked { _writes.append(bytes) }; return base.write(term, bytes) }
    func resize(_ term: OpaquePointer, cols: UInt16, rows: UInt16) -> Int32 {
        locked { _resizes.append(GridSize(cols: cols, rows: rows)) }
        return base.resize(term, cols: cols, rows: rows)
    }
    func scroll(_ term: OpaquePointer, _ deltaRows: Int32) -> Int32 { locked { _scrolls.append(deltaRows) }; return base.scroll(term, deltaRows) }
    func snapshot(_ term: OpaquePointer) throws -> Data { try base.snapshot(term) }
    func free(_ term: OpaquePointer) { locked { _live -= 1; _frees += 1 }; base.free(term) }
}

// MARK: - Real core VT (K-12)

final class TerminalVTTests: XCTestCase {
    func testRecordedTailMatchesTheCommittedSnapshotThroughTheCABI() throws {
        let bridge = NativeTerminalBridge.shared
        let term = try bridge.create(try encoded(TerminalConfig(cols: 20, rows: 4, scrollback_rows: 100)))
        defer { bridge.free(term) }
        XCTAssertEqual(bridge.write(term, K12.tail), 0)
        XCTAssertTrue(sameJSON(try bridge.snapshot(term), K12.snapshotData), "real VT snapshot drifted from fixtures/k12")
    }

    func testRepliesResizeScrollbackAndResetRoundTrip() async throws {
        let replies = EventLog()
        let vt = TerminalVT(bridge: NativeTerminalBridge.shared, scrollbackRows: 100) { bytes in
            replies.append(.terminal_reply(EventTerminalReply(now_ms: 0, wall_time_ms: 0, terminal_id: "t",
                bytes_base64: bytes.base64EncodedString())))
        }
        _ = await vt.apply(reset: true, bytes: K12.tail, cols: 20, rows: 4)
        // A cursor-position request is answered by the VT and drained with the snapshot.
        _ = await vt.apply(reset: false, bytes: Data("\u{1b}[6n".utf8), cols: 20, rows: 4)
        let sent = replies.all.compactMap { event -> String? in
            guard case .terminal_reply(let e) = event, let bytes = Data(base64Encoded: e.bytes_base64) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        XCTAssertEqual(sent, ["\u{1b}[3;1R"])
        await vt.resize(cols: 30, rows: 6)
        var state = await vt.current()
        var snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual([snapshot.cols, snapshot.rows], [30, 6])
        let lines = (1...40).map { "line \($0)\r\n" }.joined()
        _ = await vt.apply(reset: false, bytes: Data(lines.utf8), cols: 30, rows: 6)
        state = await vt.current()
        XCTAssertGreaterThan(try XCTUnwrap(state.snapshot).scrollback_rows, 0)
        await vt.scroll(3)
        state = await vt.current()
        snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.scroll_offset, 3)
        XCTAssertNil(renderPlan(snapshot).cursor, "no cursor while viewing history")
        await vt.scroll(-3)
        state = await vt.current()
        XCTAssertEqual(try XCTUnwrap(state.snapshot).scroll_offset, 0)
        // A reset replay recreates the emulator at the core's size.
        _ = await vt.apply(reset: true, bytes: K12.tail, cols: 20, rows: 4)
        state = await vt.current()
        XCTAssertEqual(state.resets, 2)
        XCTAssertEqual(cellsJSON(state.snapshot), cellsJSON(K12.snapshot))
        // The main-thread feed follows in order.
        let feed = vt.feed
        try await waitUntil("feed") { feed.resets == 2 && feed.snapshot?.cols == 20 }
        await vt.close()
        let closed = await vt.apply(reset: false, bytes: Data("x".utf8), cols: 20, rows: 4)
        XCTAssertEqual(closed.error, .unavailable)
    }

    func testSelectorsMatchTheCorePercentEncoding() {
        XCTAssertEqual(terminalSelector("sess-7"), "terminal:sess-7")
        XCTAssertEqual(terminalSelector("mobile:abc:1"), "terminal:mobile%3Aabc%3A1")
        XCTAssertEqual(terminalSelector("session:%2F/one"), "terminal:session%3A%252F%2Fone")
        XCTAssertEqual(terminalSelector("界"), "terminal:%E7%95%8C")
        XCTAssertEqual(terminalSelector("a.b~c_d"), "terminal:a.b~c_d")
    }
}

// MARK: - Screen model over a fake core

/// Host/sync stand-in plus the K-12 pump contract: attach (or a reconnect while attached)
/// emits a reset `terminal_output`; create starts the session through a timer round-trip.
/// Every batch invalidates hosts/home/workspaces and every terminal selector.
private final class TermCore: HostCore {
    let events = EventLog()
    private let lock = NSLock()
    private let tail: Data
    private var row: HostView
    private var terminals: [String: TerminalView] = [:]
    private var order: [String] = []
    private var operations: [CoreOperation] = []
    private var sequence = 0
    private var created = 0
    private var _rejected = 0
    private var attachSuffix = ""
    private var attachStatus: Int32?

    init(_ saved: SavedHost, scopes: [String]) {
        tail = K12.tail
        row = hostView(saved.id, saved.label, phase: "idle", sync: "ready")
        row.scopes = scopes
    }

    var rejected: Int { lock.lock(); defer { lock.unlock() }; return _rejected }
    func configure(attachSuffix: String = "", attachStatus: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.attachSuffix = attachSuffix
        self.attachStatus = attachStatus
    }

    func handle(_ bytes: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let event = try JSONDecoder().decode(Event.self, from: bytes)
        var effects: [Effect] = []
        func next() -> String { sequence += 1; return "e\(sequence)" }
        func output(_ id: String, _ data: Data) {
            effects.append(.terminal_output(EffectTerminalOutput(effect_id: next(), generation: "1", terminal_id: id,
                reset: true, bytes_base64: data.base64EncodedString(), next_offset: "65")))
        }
        func put(_ view: TerminalView) {
            if terminals[view.terminal_id] == nil { order.append(view.terminal_id) }
            terminals[view.terminal_id] = view
        }
        switch event {
        case .terminal_input(let e) where e.input.ctrl && (e.input.key ?? "").allSatisfy(\.isNumber):
            _rejected += 1
            throw CoreBridgeError.status(1) // The core cannot encode Ctrl+digit.
        case .terminal_attach where attachStatus != nil:
            throw CoreBridgeError.status(attachStatus!)
        default: break
        }
        events.append(event)
        switch event {
        case .foreground: row.lifecycle = .foreground; row.phase = "ready"
        case .network_changed(let e):
            if !e.available {
                row.phase = "disabled"
                for id in order { terminals[id]?.stale = true }
            } else if row.phase != "ready" {
                row.phase = "ready"
                // Reconnect: attached terminals restart from a full (reset) replay.
                for id in order where terminals[id]?.attached == true {
                    terminals[id]?.stale = false
                    output(id, tail)
                }
            }
        case .terminal_attach(let e):
            var view = terminals[e.terminal_id] ?? TerminalView(terminal_id: e.terminal_id, workspace_id: "fixture-ws", label: "htop")
            view.attached = true; view.session_status = "running"; view.cols = 20; view.rows = 4
            view.stale = false; view.next_offset = "0"
            put(view)
            output(e.terminal_id, tail + Data(attachSuffix.utf8))
        case .terminal_detach(let e): terminals[e.terminal_id]?.attached = false
        case .terminal_applied(let e):
            if e.error == nil { terminals[e.terminal_id]?.grid_revision = e.grid_revision; terminals[e.terminal_id]?.next_offset = "65" }
        case .terminal_resize(let e): terminals[e.terminal_id]?.cols = e.cols; terminals[e.terminal_id]?.rows = e.rows
        case .terminal_create(let e):
            if e.workspace_id == "no-path" {
                operations.append(CoreOperation(intent_id: e.intent_id, state: "failed",
                    error: LocalError(code: "workspace_path_unavailable", message: "no path")))
            } else {
                created += 1
                let id = "mobile:fixture:\(created)"
                put(TerminalView(terminal_id: id, workspace_id: e.workspace_id, label: "Terminal", session_status: "starting",
                                 attached: true, cols: e.cols, rows: e.rows, stale: true))
                effects.append(.set_timer(EffectSetTimer(effect_id: next(), generation: "1", timer_id: "create:\(id)",
                                                         delay_ms: 10, purpose: "test")))
            }
        case .timer_fired(let e) where e.timer_id.hasPrefix("create:"):
            let id = String(e.timer_id.dropFirst("create:".count))
            terminals[id]?.session_status = "running"
            terminals[id]?.stale = false
            output(id, Data("$ ".utf8))
        default: break
        }
        effects.append(.state_changed(EffectStateChanged(effect_id: next(), generation: "1", revision: String(sequence),
            scopes: ["hosts", "home", "workspaces"] + order.map(terminalSelector))))
        return try encoded(EffectBatch(api_version: 1, revision: String(sequence), effects: effects))
    }

    func query(_ selector: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let revision = String(sequence)
        switch selector {
        case "home": return try encoded(K09.homeLive)
        case "workspaces": return try encoded(K09.workspacesLive)
        case "hosts":
            return try encoded(HostsQuery(api_version: 1, revision: revision,
                                          data: HostsView(items: [row], operations: operations), error: nil))
        case "operations":
            return try encoded(OperationsQuery(api_version: 1, revision: revision,
                                               data: OperationsView(items: operations), error: nil))
        default:
            let view = order.first { terminalSelector($0) == selector }.flatMap { terminals[$0] }
            return try encoded(TerminalQuery(api_version: 1, revision: revision, data: view, error: nil))
        }
    }

    func close() {}
}

@MainActor
final class TerminalModelTests: XCTestCase {
    private var storage = MemoryStorage()
    private var hosts: HostsModel!
    private var browse: BrowseModel!
    private var cores: [TermCore] = []
    private var bridge = RecordingBridge()
    private var scopes = ["terminal:read", "terminal:write"]
    private var setup: (TermCore) -> Void = { _ in }
    private var models: [TerminalModel] = []
    private var core: TermCore { cores.last! }

    override func tearDown() async throws {
        models.forEach { $0.stop() }
        await hosts?.close()
        FocusClaim.owner = nil
    }

    private func launch() async throws {
        storage.set(HostsModel.catalogKey, try encoded(HostCatalog(hosts: [SavedHost(id: "alpha", label: "Studio")], active: "alpha")))
        let bridge = self.bridge, scopes = self.scopes
        let hosts = HostsModel(storage: storage, cache: nil, deviceLabel: "Test phone") { [unowned self] saved, store in
            let fake = TermCore(saved, scopes: scopes)
            self.setup(fake)
            self.cores.append(fake)
            return CoreHost(core: fake, store: store, transport: NullTransport(),
                            storage: HostScopedStorage(base: storage, hostID: saved.id), terminals: bridge)
        }
        self.hosts = hosts
        browse = BrowseModel(hosts: hosts)
        hosts.foreground(true)
        hosts.network(NetworkState(available: true, id: "net-1"))
        hosts.begin()
        try await waitUntil("ready") { browse.state.host?.phase == "ready" }
    }

    private func open(_ terminalID: String? = "sess-7", workspace: String = "fixture-ws") -> TerminalModel {
        let model = TerminalModel(browse: browse, hostID: "alpha", workspaceID: workspace, terminalID: terminalID, resizeDelay: 0.05)
        models.append(model)
        model.start()
        return model
    }

    private func events<T>(_ match: (Event) -> T?) -> [T] { core.events.all.compactMap(match) }
    private var inputs: [TermInput] {
        events { event -> TermInput? in
            guard case .terminal_input(let e) = event else { return nil }
            switch e.input.kind {
            case .text: return .text(e.input.text ?? "")
            case .paste: return .paste(e.input.text ?? "")
            case .key: return .key(e.input.key ?? "", ctrl: e.input.ctrl, alt: e.input.alt, shift: e.input.shift)
            }
        }
    }
    private var resizes: [EventTerminalResize] { events { if case .terminal_resize(let e) = $0 { return e }; return nil } }
    private var replies: [EventTerminalReply] { events { if case .terminal_reply(let e) = $0 { return e }; return nil } }
    private var detaches: [String] { events { if case .terminal_detach(let e) = $0 { return e.terminal_id }; return nil } }
    private var creates: [EventTerminalCreate] { events { if case .terminal_create(let e) = $0 { return e }; return nil } }

    func testQueuedTextIsDiscardedWhenTerminalCloses() async throws {
        try await launch()
        let model = open()
        try await waitUntil("interactive") { model.interactive }
        model.input(.text("never replay"))
        model.stop()
        try await waitUntil("detached") { !detaches.isEmpty }
        XCTAssertTrue(inputs.isEmpty)
    }

    func testWithoutTerminalWriteTheTerminalIsViewOnly() async throws {
        scopes = ["terminal:read"]
        setup = { $0.configure(attachSuffix: "\u{1b}[6n") }
        try await launch()
        XCTAssertFalse(canWrite(browse.state.host))
        let model = open()
        model.setMeasured(GridSize(cols: 40, rows: 12))
        try await waitUntil("view only") {
            model.snapshot != nil && model.notice == "View only: this phone was paired without terminal access."
        }
        XCTAssertFalse(model.writable)
        XCTAssertFalse(model.interactive)
        model.input(.key("Escape"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(resizes.isEmpty)
        let fresh = open(nil)
        fresh.setMeasured(GridSize(cols: 20, rows: 4))
        try await waitUntil("cannot create") { fresh.notice == "This phone can view terminals but not open them." }
        XCTAssertTrue(creates.isEmpty)
    }

    func testRejectedKeysAreDroppedWithoutClosingTheHost() async throws {
        try await launch()
        let model = open()
        try await waitUntil("interactive") { model.interactive }
        model.toggleCtrl()
        model.input(.text("1"))
        model.input(.text("a"))
        try await waitUntil("next input") { inputs == [.text("a")] }
        XCTAssertEqual(core.rejected, 1)
        XCTAssertFalse(hosts.session("alpha")!.store.failed)
        XCTAssertTrue(model.interactive)
        XCTAssertNil(model.notice)
    }
}

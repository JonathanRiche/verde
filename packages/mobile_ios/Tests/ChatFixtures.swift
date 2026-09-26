import Foundation
import XCTest
@testable import VerdeApp

private final class SharedFixtureMarker {}

/// The Android test fixtures (d06/d07/d09), bundled by reference from
/// packages/mobile_android/app/src/test/resources/fixtures (see project.yml); never copied.
enum SharedFixtures {
    static func data(_ directory: String, _ file: String) -> Data {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        guard let url = Bundle(for: SharedFixtureMarker.self).url(forResource: name, withExtension: ext,
                                                                  subdirectory: "fixtures/\(directory)"),
              let data = try? Data(contentsOf: url) else { fatalError("missing shared fixture \(directory)/\(file)") }
        return data
    }
    static func text(_ directory: String, _ file: String) -> String { String(decoding: data(directory, file), as: UTF8.self) }
    static func thread(_ directory: String, _ name: String) -> ThreadQuery {
        try! JSONDecoder().decode(ThreadQuery.self, from: data(directory, "\(name).json"))
    }
    static func json(_ directory: String, _ file: String) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: data(directory, file))) as? [[String: Any]] ?? []
    }
}

let chatWS = "chat-fixture-ws"
let chatThread = "chat-fixture-thread"

/// Recorded K-11 utility replies keyed by the exact query text (d06 render.json plus the d07
/// transcript diff_index reply).
enum RecordedRenders {
    static let entries: [[String: Any]] = SharedFixtures.json("d06", "render.json") + SharedFixtures.json("d07", "transcript-render.json")

    static func result(_ kind: String, _ text: String, language: String? = nil) -> Data? {
        let entry = entries.first { entry in
            guard let query = entry["query"] as? [String: Any] else { return false }
            return query["kind"] as? String == kind && query["text"] as? String == text &&
                (language == nil || query["language"] as? String == language)
        }
        guard let result = entry?["result"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: result)
    }
}

/// Host/sync like BrowseTests plus the chat intents the transcript sends. `thread:`/`composer:`
/// answers are recorded core envelopes (d06 or d09); a network-id bump from the test stands in for
/// a tail response landing. Utility queries answer from the recorded K-11 results; bodies outside
/// the recording get a synthesized single-paragraph AST, counted in `fallbackRenders`.
final class ChatCore: HostCore {
    let events = EventLog()
    private let lock = NSLock()
    private let directory: String
    private var row: HostView
    private var _operations: [String: CoreOperation] = [:]
    private var order: [String] = []
    private var network = true
    private var sequence = 0
    private var _thread: String
    private var _composer = "composer-idle"
    private var _afterFocus: String?
    private var _missing = false
    private var _ensured = false
    private var _utilityQueries = 0
    private var _fallbackRenders = 0
    private var _onDecide: ((ChatCore, String) -> Void)?

    init(_ saved: SavedHost, directory: String = "d06", thread: String = "thread-open") {
        self.directory = directory
        _thread = thread
        row = hostView(saved.id, saved.label, phase: "idle", sync: "empty")
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var thread: String { get { locked { _thread } } set { locked { _thread = newValue } } }
    var composer: String { get { locked { _composer } } set { locked { _composer = newValue } } }
    var afterFocus: String? { get { locked { _afterFocus } } set { locked { _afterFocus = newValue } } }
    var missing: Bool { get { locked { _missing } } set { locked { _missing = newValue } } }
    var ensured: Bool { get { locked { _ensured } } set { locked { _ensured = newValue } } }
    var utilityQueries: Int { locked { _utilityQueries } }
    var fallbackRenders: Int { locked { _fallbackRenders } }
    /// Runs under the core lock for `approval_decide` (defaults to a pending receipt + projection).
    var onDecide: ((ChatCore, String) -> Void)? { get { locked { _onDecide } } set { locked { _onDecide = newValue } } }
    var operations: [String: CoreOperation] { locked { _operations } }
    /// Only call from `onDecide` (already under the lock).
    func setOperation(_ id: String, _ state: String, _ error: LocalError? = nil) {
        if _operations[id] == nil { order.append(id) }
        _operations[id] = CoreOperation(intent_id: id, state: state, error: error)
    }
    func setThreadLocked(_ name: String) { _thread = name }
    func operation(_ id: String, _ state: String, _ error: LocalError? = nil) { locked { setOperation(id, state, error) } }

    func handle(_ bytes: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let event = try JSONDecoder().decode(Event.self, from: bytes)
        events.append(event)
        var effects: [Effect] = []
        func next() -> String { sequence += 1; return "e\(sequence)" }
        func connect() {
            guard row.lifecycle == .foreground, network else { return }
            row.phase = "connecting"; row.sync_state = "loading"
            effects.append(.set_timer(EffectSetTimer(effect_id: next(), generation: "1", timer_id: "sync", delay_ms: 10, purpose: "test")))
        }
        let online = row.phase == "ready"
        switch event {
        case .foreground: row.lifecycle = .foreground; connect()
        case .network_changed(let e):
            let was = network
            network = e.available
            if !network { row.phase = "disabled" } else if !was || row.phase != "ready" { connect() }
        case .timer_fired(let e):
            if e.timer_id == "sync" && row.phase == "connecting" { row.phase = "ready"; row.sync_state = "ready" }
            if e.timer_id == "older" { _thread = "thread-older" }
        case .focus(let e):
            if e.thread_id == nil { setOperation(e.intent_id, "succeeded") }
            else if _missing { setOperation(e.intent_id, "failed", LocalError(code: "thread_unavailable", message: "")) }
            // The real core ensures an empty, unloaded thread here; no rows either way.
            else if !online { setOperation(e.intent_id, "failed", LocalError(code: "unavailable", message: "")) }
            else {
                _ensured = true
                if let after = _afterFocus { _thread = after }
                setOperation(e.intent_id, "pending")
            }
        case .thread_load_older(let e):
            setOperation(e.intent_id, "pending")
            _thread = "thread-loading-older"
            effects.append(.set_timer(EffectSetTimer(effect_id: next(), generation: "1", timer_id: "older", delay_ms: 10, purpose: "test")))
        case .turn_cancel(let e):
            if _thread == "thread-streaming" || _thread == "thread-running" {
                setOperation(e.intent_id, "pending"); _thread = "thread-stopping"; _composer = "composer-stopping"
            } else {
                setOperation(e.intent_id, "failed", LocalError(code: "stale_turn", message: ""))
            }
        case .approval_decide(let e):
            if let onDecide = _onDecide { onDecide(self, e.intent_id) }
            else { _thread = "approval-pending"; setOperation(e.intent_id, "pending") }
        default: break
        }
        var scopes = ["hosts", "home", "workspaces"]
        if _ensured { scopes += [chatSelector("thread", chatWS, chatThread), chatSelector("composer", chatWS, chatThread)] }
        effects.append(.state_changed(EffectStateChanged(effect_id: next(), generation: "1", revision: String(sequence), scopes: scopes)))
        return try encoded(EffectBatch(api_version: 1, revision: String(sequence), effects: effects))
    }

    private static let notFound = Data(#"{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":"Unknown thread."}}"#.utf8)

    func query(_ selector: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        switch selector {
        case "hosts":
            return try encoded(HostsQuery(api_version: 1, revision: String(sequence),
                                          data: HostsView(items: [row], operations: order.compactMap { _operations[$0] }), error: nil))
        case "home": return try encoded(K09.homeLive)
        case "workspaces": return try encoded(K09.workspacesLive)
        default:
            if selector.hasPrefix("thread:") { return _ensured ? SharedFixtures.data(directory, "\(_thread).json") : Self.notFound }
            if selector.hasPrefix("composer:") {
                return _ensured && directory == "d06" ? SharedFixtures.data("d06", "\(_composer).json") : Self.notFound
            }
            if selector.hasPrefix("{") { return utility(selector) }
            return Self.notFound
        }
    }

    private func utility(_ selector: String) -> Data {
        _utilityQueries += 1
        let query = (try? JSONSerialization.jsonObject(with: Data(selector.utf8))) as? [String: Any] ?? [:]
        let kind = query["utility"] as? String ?? "", text = query["text"] as? String ?? ""
        if directory == "d06", let recorded = RecordedRenders.result(kind, text, language: query["language"] as? String) { return recorded }
        _fallbackRenders += 1
        let bytes = text.utf8.count
        let data: Any
        switch kind {
        case "markdown":
            let leaf: [String: Any] = ["kind": "text", "start": 0, "end": bytes, "text": text, "children": []]
            let paragraph: [String: Any] = ["kind": "paragraph", "start": 0, "end": bytes, "children": [leaf]]
            data = ["nodes": [["kind": "document", "start": 0, "end": bytes, "children": [paragraph]]]]
        case "highlight": data = ["spans": []]
        default: data = ["files": []]
        }
        return (try? JSONSerialization.data(withJSONObject: ["api_version": 1, "revision": "1", "data": data])) ?? Data()
    }

    func close() {}
}

/// One saved host backed by a `ChatCore`, as the app wires it.
@MainActor
final class ChatHarness {
    let storage = MemoryStorage()
    private(set) var hosts: HostsModel!
    private(set) var browse: BrowseModel!
    private(set) var cores: [ChatCore] = []
    private var networkIDs = 1
    var core: ChatCore { cores.last! }

    func launch(network: Bool = true, setup: @escaping (ChatCore) -> Void = { _ in },
                make: @escaping (SavedHost) -> ChatCore = { ChatCore($0) }) async throws {
        storage.set(HostsModel.catalogKey, try encoded(HostCatalog(hosts: [SavedHost(id: "alpha", label: "Studio")], active: "alpha")))
        let storage = self.storage
        let hosts = HostsModel(storage: storage, cache: nil, deviceLabel: "Test phone") { [unowned self] saved, store in
            let fake = make(saved)
            setup(fake)
            self.cores.append(fake)
            return CoreHost(core: fake, store: store, transport: NullTransport(),
                            storage: HostScopedStorage(base: storage, hostID: saved.id))
        }
        self.hosts = hosts
        browse = BrowseModel(hosts: hosts)
        hosts.foreground(true)
        hosts.network(NetworkState(available: network, id: network ? "net-1" : ""))
        hosts.begin()
        try await waitUntil("host row") { browse.state.host != nil }
        if network { try await waitUntil("ready") { browse.state.host?.phase == "ready" } }
    }

    func setNetwork(_ available: Bool) {
        networkIDs += 1
        hosts.network(NetworkState(available: available, id: available ? "net-\(networkIDs)" : ""))
    }

    /// Delivers whatever the fake core now holds, like a tail response landing.
    func deliver(_ change: (ChatCore) -> Void = { _ in }) {
        change(core)
        setNetwork(true)
    }

    func close() async {
        await hosts?.close()
        FocusClaim.owner = nil
    }
}

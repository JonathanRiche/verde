import Foundation
import Observation
import Security
import VerdeClient

// Only CoreHost calls this synchronous boundary; no native call spans an await.
protocol HostCore: AnyObject {
    func handle(_ event: Data) throws -> Data
    func query(_ selector: String) throws -> Data
    func close()
}

private struct RejectedEvent: Error { let status: Int32 }

/// `rejected` is a transactional core refusal (no state change, host still usable);
/// every other error means the host was closed.
enum CoreBridgeError: Error { case status(Int32), rejected(Int32), closed, invalidOutput }

final class NativeHostCore: HostCore {
    private var handle: OpaquePointer?

    init(config: Config) throws {
        let bytes = try JSONEncoder().encode(config)
        let status = bytes.withUnsafeBytes {
            vc_host_new($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, &handle)
        }
        guard status == 0 else { throw CoreBridgeError.status(status) }
    }

    func handle(_ event: Data) throws -> Data { try call(event, query: false) }
    func query(_ selector: String) throws -> Data { try call(Data(selector.utf8), query: true) }
    private func call(_ input: Data, query: Bool) throws -> Data {
        guard let handle else { throw CoreBridgeError.closed }
        var output = vc_buf(ptr: nil, len: 0)
        defer { vc_buf_free(output) }
        let status = input.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
            return query ? vc_host_query(handle, pointer, input.count, &output)
                : vc_host_handle(handle, pointer, input.count, &output)
        }
        guard status == 0 else { throw CoreBridgeError.status(status) }
        guard let pointer = output.ptr else { throw CoreBridgeError.invalidOutput }
        return Data(bytes: pointer, count: output.len)
    }
    func close() {
        if let handle { vc_host_free(handle); self.handle = nil }
    }
    deinit { close() }
}

@MainActor @Observable
final class CoreViewStore {
    private(set) var hosts: HostsQuery?
    /// Intent outcomes; announced only when a receipt is added, settled or evicted.
    private(set) var operations: OperationsQuery?
    private(set) var home: HomeQuery?
    private(set) var workspaces: WorkspacesQuery?
    // Future selectors remain lossless until their typed models are registered.
    private(set) var snapshots: [String: Data] = [:]
    private(set) var notifications: [EffectNotify] = []
    private(set) var failed = false
    /// Set once this handle's core has reported a completed sync; its projections
    /// are then at least as new as any warm-start cache.
    private(set) var synced = false
    /// Platform observers (host catalog, warm-start cache) run after each publication.
    @ObservationIgnored var onApply: (() -> Void)?

    func apply(_ updates: [String: Data], notifications: [EffectNotify]) {
        do {
            for (selector, data) in updates {
                switch selector {
                case "hosts": hosts = try JSONDecoder().decode(HostsQuery.self, from: data)
                case "operations": operations = try JSONDecoder().decode(OperationsQuery.self, from: data)
                case "home": home = try JSONDecoder().decode(HomeQuery.self, from: data)
                case "workspaces": workspaces = try JSONDecoder().decode(WorkspacesQuery.self, from: data)
                default: break
                }
                snapshots[selector] = data
            }
            if let row = hosts?.data?.items.first {
                if ["signing_out", "signed_out"].contains(row.auth_state) {
                    // A core-driven wipe also retires every projection held by the platform.
                    home = nil
                    workspaces = nil
                    synced = false
                    snapshots = snapshots.filter { $0.key == "hosts" || $0.key == "operations" }
                } else if row.sync_state == "ready" { synced = true }
            }
            self.notifications.append(contentsOf: notifications)
        } catch { failed = true }
        onApply?()
    }
    func markFailed() { failed = true; onApply?() }
    func dismissNotifications() { notifications.removeAll() }
}

/// A batch's effects, tolerating tags newer than this build's generated models: those are
/// dropped (their fields are never read or logged) instead of failing the host. A known
/// effect that fails to decode is still fatal.
struct EffectList: Decodable {
    var effects: [Effect]
    private enum Keys: String, CodingKey { case effects }
    private struct Item: Decodable {
        let effect: Effect?
        init(from decoder: Decoder) throws {
            do { effect = try Effect(from: decoder) }
            catch DecodingError.dataCorrupted(let context) where context.codingPath.last?.stringValue == "type" { effect = nil }
        }
    }
    init(from decoder: Decoder) throws {
        effects = try decoder.container(keyedBy: Keys.self).decode([Item].self, forKey: .effects).compactMap(\.effect)
    }
}

protocol CoreTransport: AnyObject {
    func execute(_ effect: Effect, emit: @escaping (Event) -> Void)
    func stop()
}

actor CoreHost {
    private let core: HostCore
    private let transport: CoreTransport
    private let storage: SecureStorage
    private let store: CoreViewStore
    private let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var pump: Task<Void, Never>?
    private var timers: [String: Task<Void, Never>] = [:]
    private var publication: Task<Void, Never>?
    private var stopped = false
    private let terminalBridge: TerminalBridge
    // Output for an unregistered terminal reports `unavailable`.
    private var terminals: [String: TerminalVT] = [:]
    /// Latest `terminal:<id>` query results, used to find a newly created session.
    private var terminalViews: [String: Data] = [:]

    init(core: HostCore, store: CoreViewStore,
         transport: CoreTransport = SessionTransport(), storage: SecureStorage = KeychainStorage(),
         terminals: TerminalBridge = NativeTerminalBridge.shared) {
        self.core = core
        self.store = store
        self.transport = transport
        self.storage = storage
        terminalBridge = terminals
        let channel = AsyncStream<Event>.makeStream()
        events = channel.stream
        continuation = channel.continuation
    }

    static func live(hostID: String, label: String, httpsURL: String?, wssURL: String?,
                     store: CoreViewStore) throws -> CoreHost {
        var entropy = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw CoreBridgeError.invalidOutput
        }
        let nonce = entropy.prefix(16).map { String(format: "%02x", $0) }.joined()
        let seed = entropy.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let config = Config(api_version: 1, host_id: hostID, label: label, https_url: httpsURL,
                            wss_url: wssURL, client_revision: 1, session_nonce: nonce, jitter_seed: seed)
        return CoreHost(core: try NativeHostCore(config: config), store: store,
                        storage: HostScopedStorage(base: KeychainStorage(), hostID: hostID))
    }

    /// The actor stamps time at delivery, including user intents and async completions.
    func send(_ event: Event) throws {
        guard !stopped else { throw CoreBridgeError.closed }
        if pump == nil {
            let events = self.events
            pump = Task { [weak self] in
                for await event in events { await self?.receive(event) }
            }
        }
        do {
            let encoded = try JSONEncoder().encode(event)
            guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: encoded) else {
                throw CoreBridgeError.invalidOutput
            }
            object["now_ms"] = .integer(Int64(ProcessInfo.processInfo.systemUptime * 1000))
            object["wall_time_ms"] = .integer(Int64(Date().timeIntervalSince1970 * 1000))
            let output: Data
            do { output = try core.handle(JSONEncoder().encode(JSONValue.object(object))) }
            catch CoreBridgeError.status(let status) where Self.recoverable(event) && (status == 1 || status == 4 || status == 5) {
                // Transactional input/lifecycle/resource rejection returns no
                // effects and leaves the handle usable (e.g. a malformed link).
                throw RejectedEvent(status: status)
            }
            let batch = try JSONDecoder().decode(EffectList.self, from: output)
            try dispatch(batch.effects)
            if case .shutdown = event { finish() }
        } catch let rejected as RejectedEvent {
            throw CoreBridgeError.rejected(rejected.status)
        } catch {
            // A lost/undecodable batch is fatal; never replay partially dispatched work.
            finish()
            let previous = publication
            publication = Task { await previous?.value; await store.markFailed() }
            throw error
        }
    }

    /// User intents and lifecycle signals. Platform completions stay fatal when
    /// rejected: dropping one would lose an effect the core is waiting for.
    private static func recoverable(_ event: Event) -> Bool {
        switch event {
        case .pair, .trust_decision, .retry_connection, .sign_out, .forget_host,
             .foreground, .background, .network_changed, .focus,
             // Chat intents (I-05): e.g. an overlapping page or an already-answered approval.
             .thread_load_older, .turn_cancel, .approval_decide,
             .draft_set, .composer_select, .send, .slash_search, .slash_run, .mention_search,
             .shell_confirm, .followup_submit, .followup_retry, .followup_pull_back, .followup_cancel,
             // Terminal intents: e.g. an unencodable key or the 32-record limit.
             // A rejected device reply is dropped, never replayed.
             .terminal_create, .terminal_attach, .terminal_detach, .terminal_kill,
             .terminal_resize, .terminal_input, .terminal_reply: return true
        default: return false
        }
    }

    /// Pure K-11 utility queries (markdown, highlight, diff, diff_index); no state change.
    func query(_ selector: String) throws -> Data {
        guard !stopped else { throw CoreBridgeError.closed }
        return try core.query(selector)
    }

    // MARK: Terminals (K-12)

    enum TerminalCreation {
        case created(String, TerminalVT)
        /// The core's operation error code for the intent, if it recorded one.
        case failed(String?)
    }

    /// Registers a VT for `id`'s `terminal_output` (one serialized executor per handle).
    /// Device replies go back through `terminal_reply` unless `replies` is false.
    func openTerminal(_ id: String, replies: Bool) throws -> TerminalVT {
        guard !stopped else { throw CoreBridgeError.closed }
        return register(id, replies: replies)
    }

    private func register(_ id: String, replies: Bool) -> TerminalVT {
        let continuation = self.continuation
        let vt = TerminalVT(bridge: terminalBridge) { bytes in
            guard replies else { return }
            continuation.yield(.terminal_reply(EventTerminalReply(now_ms: 0, wall_time_ms: 0,
                terminal_id: id, bytes_base64: bytes.base64EncodedString())))
        }
        if let old = terminals.updateValue(vt, forKey: id) { Task { await old.close() } }
        return vt
    }

    /// Detaches the pump (the daemon session keeps running) and frees the local VT.
    func closeTerminal(_ id: String, _ vt: TerminalVT) async {
        if terminals[id] === vt {
            terminals[id] = nil
            if !stopped {
                // A rejection leaves nothing to undo; a fatal error already published the failure.
                try? send(.terminal_detach(EventTerminalDetach(now_ms: 0, wall_time_ms: 0,
                    intent_id: UUID().uuidString, terminal_id: id)))
            }
        }
        await vt.close()
    }

    /// Sends `terminal_create`. Every committed change lists all terminal selectors,
    /// so the only new selector after this batch is the new session's row. The VT is
    /// registered in the same actor turn, so its first output cannot miss it.
    func createTerminal(_ event: EventTerminalCreate, replies: Bool) throws -> TerminalCreation {
        let before = Set(terminalViews.keys)
        try send(.terminal_create(event))
        for (selector, data) in terminalViews where !before.contains(selector) {
            if let id = (try? JSONDecoder().decode(TerminalQuery.self, from: data))?.data?.terminal_id {
                return .created(id, register(id, replies: replies))
            }
        }
        let operations = (try? core.query("operations")).flatMap { try? JSONDecoder().decode(OperationsQuery.self, from: $0) }
        return .failed(operations?.data?.items.first { $0.intent_id == event.intent_id }?.error?.code)
    }

    /// Resolves the grid size from the terminal view (terminal.md: query before
    /// recreating the VT), applies off the core actor, then reports `terminal_applied`.
    private func terminalOutput(_ effect: EffectTerminalOutput, emit: @escaping (Event) -> Void) {
        func applied(_ result: TerminalApplied) -> Event {
            .terminal_applied(EventTerminalApplied(now_ms: 0, wall_time_ms: 0, effect_id: effect.effect_id,
                generation: effect.generation, terminal_id: effect.terminal_id, grid_revision: result.gridRevision,
                error: result.error.map { PlatformFailure(code: $0) }))
        }
        guard let vt = terminals[effect.terminal_id], let bytes = Data(base64Encoded: effect.bytes_base64) else {
            emit(applied(TerminalApplied(gridRevision: "0", error: .unavailable)))
            return
        }
        let view = (try? core.query(terminalSelector(effect.terminal_id)))
            .flatMap { try? JSONDecoder().decode(TerminalQuery.self, from: $0) }?.data
        let cols = view?.cols ?? 80, rows = view?.rows ?? 24
        Task {
            let result = await vt.apply(reset: effect.reset, bytes: bytes, cols: cols, rows: rows)
            emit(applied(result))
        }
    }

    func shutdown() throws {
        if !stopped { try send(.shutdown(EventShutdown(now_ms: 0, wall_time_ms: 0))) }
    }
    private func receive(_ event: Event) {
        guard !stopped else { return }
        do { try send(event) } catch { /* send publishes a fixed, non-sensitive failure. */ }
    }
    private func dispatch(_ effects: [Effect]) throws {
        var updates: [String: Data] = [:]
        var notices: [EffectNotify] = []
        let continuation = self.continuation
        let emit: (Event) -> Void = { continuation.yield($0) }
        for effect in effects {
            switch effect {
            case .set_timer(let value):
                timers.removeValue(forKey: value.timer_id)?.cancel()
                timers[value.timer_id] = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(value.delay_ms) * 1_000_000) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    emit(.timer_fired(EventTimerFired(now_ms: 0, wall_time_ms: 0,
                         timer_id: value.timer_id, generation: value.generation)))
                    self.timers.removeValue(forKey: value.timer_id)
                }
            case .cancel_timer(let value): timers.removeValue(forKey: value.timer_id)?.cancel()
            case .secure_store_get, .secure_store_put, .secure_store_delete:
                emit(storage.execute(effect))
            case .state_changed(let value):
                for selector in value.scopes {
                    let data = try core.query(selector)
                    updates[selector] = data
                    if selector.hasPrefix("terminal:") { terminalViews[selector] = data }
                }
            case .notify(let value): notices.append(value)
            case .log: break // No effect fields are sent to platform logs.
            case .terminal_output(let value): terminalOutput(value, emit: emit)
            default: transport.execute(effect, emit: emit)
            }
        }
        if !updates.isEmpty || !notices.isEmpty {
            let previous = publication
            publication = Task { await previous?.value; await store.apply(updates, notifications: notices) }
        }
    }
    private func finish() {
        stopped = true
        continuation.finish()
        pump?.cancel()
        pump = nil
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        transport.stop()
        core.close()
        let open = Array(terminals.values)
        terminals.removeAll()
        for vt in open { Task { await vt.close() } }
    }
    deinit {
        if !stopped {
            // Explicit shutdown is preferred. Dropping a host still seals the
            // native lifecycle before tearing down all owned platform work.
            let event = Event.shutdown(EventShutdown(
                now_ms: Int64(ProcessInfo.processInfo.systemUptime * 1000),
                wall_time_ms: Int64(Date().timeIntervalSince1970 * 1000)))
            if let bytes = try? JSONEncoder().encode(event) { _ = try? core.handle(bytes) }
        }
        continuation.finish()
        pump?.cancel()
        timers.values.forEach { $0.cancel() }
        transport.stop()
        core.close()
    }
}

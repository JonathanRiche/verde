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

enum CoreBridgeError: Error { case status(Int32), closed, invalidOutput }

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
    private(set) var home: HomeQuery?
    private(set) var workspaces: WorkspacesQuery?
    // Future selectors remain lossless until their typed models are registered.
    private(set) var snapshots: [String: Data] = [:]
    private(set) var notifications: [EffectNotify] = []
    private(set) var failed = false

    func apply(_ updates: [String: Data], notifications: [EffectNotify]) {
        do {
            for (selector, data) in updates {
                switch selector {
                case "hosts": hosts = try JSONDecoder().decode(HostsQuery.self, from: data)
                case "home": home = try JSONDecoder().decode(HomeQuery.self, from: data)
                case "workspaces": workspaces = try JSONDecoder().decode(WorkspacesQuery.self, from: data)
                default: break
                }
                snapshots[selector] = data
            }
            self.notifications.append(contentsOf: notifications)
        } catch { failed = true }
    }
    func markFailed() { failed = true }
    func dismissNotifications() { notifications.removeAll() }
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

    init(core: HostCore, store: CoreViewStore,
         transport: CoreTransport = SessionTransport(), storage: SecureStorage = KeychainStorage()) {
        self.core = core
        self.store = store
        self.transport = transport
        self.storage = storage
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
        return CoreHost(core: try NativeHostCore(config: config), store: store)
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
            let batch = try JSONDecoder().decode(EffectBatch.self, from:
                core.handle(JSONEncoder().encode(JSONValue.object(object))))
            try dispatch(batch.effects)
            if case .shutdown = event { finish() }
        } catch {
            // A lost/undecodable batch is fatal; never replay partially dispatched work.
            finish()
            let previous = publication
            publication = Task { await previous?.value; await store.markFailed() }
            throw error
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
                for selector in value.scopes { updates[selector] = try core.query(selector) }
            case .notify(let value): notices.append(value)
            case .log: break // No effect fields are sent to platform logs.
            case .terminal_output(let value):
                // The VT adapter is I-08/K-12. Report an explicit failure until attached.
                emit(.terminal_applied(EventTerminalApplied(now_ms: 0, wall_time_ms: 0,
                    effect_id: value.effect_id, generation: value.generation,
                    terminal_id: value.terminal_id, grid_revision: "0", error: PlatformFailure(code: .unavailable))))
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
    }
    deinit {
        continuation.finish()
        pump?.cancel()
        timers.values.forEach { $0.cancel() }
        transport.stop()
        core.close()
    }
}

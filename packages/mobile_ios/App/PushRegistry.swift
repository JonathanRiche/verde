import CryptoKit
import Foundation
import Observation
import Security
import UIKit
import UserNotifications

/// Notification permission as far as registration cares.
enum PushAuthorization: Equatable { case notDetermined, denied, authorized }

/// System notification/APNs entry points (fakes in tests).
@MainActor
protocol PushSystem: AnyObject {
    func authorization() async -> PushAuthorization
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
}

final class LivePushSystem: PushSystem {
    func authorization() async -> PushAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized // authorized, provisional, ephemeral
        }
    }
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }
}

/// The saved hosts as seen by push registration.
@MainActor
protocol PushHosts: AnyObject {
    /// False until the host catalog has loaded; nothing is retired before that.
    var pushCatalogLoaded: Bool { get }
    var pushHostIDs: [String] { get }
    func pushView(_ id: String) -> HostView?
    /// Sends `push_register` to that host's core and waits for its receipt.
    func pushRegister(_ id: String, sendToken: String, keySeed: String) async -> Bool
}

/// Persisted in the app's own Keychain group (never the extension's shared group).
struct PushState: Codable, Equatable {
    struct Host: Codable, Equatable {
        /// Relay capability given to this host only, so removing one host revokes just its pushes.
        var send_token: String
        /// SHA-256 of `environment:apns_token`; a change means APNs rotated the token.
        var token_digest: String
        /// Superseded capability, deleted at the relay once the host holds the new one.
        var previous: String?
    }
    var hosts: [String: Host] = [:]
    /// Capabilities still to delete at the relay (retried until 204 or 410).
    var retired: [String] = []
}

/// I-10 APNs registration: APNs token → relay `send_token` per host → `device.push.register`
/// through each host's core (which owns the X25519 key in the shared Keychain group). Handles
/// token rotation, host sign-out/removal and permission loss by deleting relay capabilities.
/// Tokens, capabilities and keys are never logged.
@MainActor @Observable
final class PushRegistry {
    static let stateKey = "ios/1/push"
    /// Auth states a completed pair starts from.
    static let pairingStates: Set<String> = ["unpaired", "repair_required"]

    private(set) var authorization: PushAuthorization = .notDetermined
    let config: PushConfig
    var available: Bool { relay != nil }

    @ObservationIgnored weak var hosts: PushHosts?
    @ObservationIgnored private let relay: PushRelayClient?
    @ObservationIgnored private let storage: SecureStorage
    @ObservationIgnored private let system: PushSystem
    @ObservationIgnored private let keySeed: () -> String?
    @ObservationIgnored private var token: String?
    /// Host → capability its core confirmed during this launch.
    @ObservationIgnored private var registered: [String: String] = [:]
    /// Hosts whose registration failed; retried after the next foreground.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var authStates: [String: String] = [:]
    @ObservationIgnored private var signatures: [String: String] = [:]
    @ObservationIgnored private var lane: Task<Void, Never>?
    @ObservationIgnored private var dirty = false

    init(config: PushConfig, storage: SecureStorage, system: PushSystem, session: URLSession = .shared,
         keySeed: @escaping () -> String? = PushRegistry.randomSeed) {
        self.config = config
        relay = config.relayURL.map { PushRelayClient(base: $0, session: session) }
        self.storage = storage
        self.system = system
        self.keySeed = keySeed
    }

    static func live() -> PushRegistry {
        PushRegistry(config: .main, storage: KeychainStorage(), system: LivePushSystem())
    }

    nonisolated static func randomSeed() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
    }

    static func digest(token: String, environment: String) -> String {
        SHA256.hash(data: Data("\(environment):\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Signals

    /// Launch and every foreground: re-read permission and re-register with APNs (Apple
    /// recommends this on each launch; it never prompts).
    func refresh() async {
        failed.removeAll()
        authorization = await system.authorization()
        if authorization == .authorized && available { system.registerForRemoteNotifications() }
        schedule()
    }

    /// Asks for permission (settings, or right after a pair), then registers.
    func requestPermission() async {
        _ = await system.requestAuthorization()
        await refresh()
    }

    func deviceToken(_ data: Data) {
        guard data.count == 32 else { return }
        let hex = data.pushTokenHex
        guard hex != token else { return }
        token = hex
        schedule()
    }

    /// A host's projection changed. A completed pair (unpaired/repair → paired) asks for
    /// permission once if it was never decided; other changes re-run registration when the
    /// host's auth state, phase or readiness moved.
    func hostChanged(_ id: String) {
        let view = hosts?.pushView(id)
        let previous = authStates[id]
        authStates[id] = view?.auth_state
        if let previous, Self.pairingStates.contains(previous), view?.auth_state == "paired",
           authorization == .notDetermined, available {
            Task { await requestPermission() }
        }
        let signature = view.map { "\($0.auth_state)|\($0.phase)|\(Self.ready($0))" } ?? "removed"
        if signatures[id] != signature {
            signatures[id] = signature
            schedule()
        }
    }

    static func ready(_ view: HostView) -> Bool {
        view.auth_state == "paired" && view.phase == "ready" && view.lifecycle == .foreground
            && view.capabilities.contains("device.push.v1") && view.scopes.contains("device:write")
    }

    static func wiped(_ state: String?) -> Bool {
        guard let state else { return true }
        return HostsModel.wiped.contains(state)
    }

    // MARK: Sync

    func schedule() {
        dirty = true
        guard lane == nil else { return }
        lane = Task { [weak self] in
            while let self, self.dirty {
                self.dirty = false
                await self.sync()
            }
            self?.lane = nil
        }
    }

    /// Waits for scheduled work (tests).
    func settle() async {
        while let lane { await lane.value }
    }

    private func load() -> PushState? {
        do {
            guard let data = try storage.get(Self.stateKey) else { return PushState() }
            return try JSONDecoder().decode(PushState.self, from: data)
        } catch is StorageError { return nil } // Locked: try again later.
        catch { return PushState() } // Corrupt: start over; old capabilities expire unused.
    }

    @discardableResult
    private func save(_ state: PushState) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return (try? storage.put(Self.stateKey, value: data)) != nil
    }

    private func sync() async {
        guard let hosts, hosts.pushCatalogLoaded, var state = load() else { return }
        let ids = Set(hosts.pushHostIDs)
        let before = state
        // Removed, signed-out or wiped hosts give up their capability at once (their core also
        // revoked the device, which clears the daemon's registration). Permission loss or a
        // build without a relay retires everything.
        for (id, entry) in state.hosts where !ids.contains(id) || Self.wiped(hosts.pushView(id)?.auth_state)
            || authorization == .denied || relay == nil {
            state.retired.append(entry.send_token)
            if let previous = entry.previous { state.retired.append(previous) }
            state.hosts[id] = nil
            registered[id] = nil
        }
        if state != before { save(state) }
        if let relay, authorization == .authorized, let token {
            let digest = Self.digest(token: token, environment: config.environment)
            for id in ids.sorted() {
                guard let view = hosts.pushView(id), Self.ready(view), !failed.contains(id) else { continue }
                var entry: PushState.Host
                if let current = state.hosts[id], current.token_digest == digest {
                    entry = current
                } else {
                    guard let send = try? await relay.register(token: token, environment: config.environment) else { continue }
                    let old = state.hosts[id]
                    if let stale = old?.previous { state.retired.append(stale) }
                    entry = PushState.Host(send_token: send, token_digest: digest, previous: old?.send_token)
                    state.hosts[id] = entry
                    registered[id] = nil
                    if !save(state) {
                        // Unpersisted capabilities would leak; drop this one now.
                        state.hosts[id] = old
                        try? await relay.unregister(sendToken: send)
                        continue
                    }
                }
                guard registered[id] != entry.send_token, let seed = keySeed() else { continue }
                // The host may have changed while the relay call was in flight.
                guard let latest = hosts.pushView(id), Self.ready(latest) else { continue }
                if await hosts.pushRegister(id, sendToken: entry.send_token, keySeed: seed) {
                    registered[id] = entry.send_token
                    if let previous = entry.previous {
                        state.retired.append(previous)
                        entry.previous = nil
                        state.hosts[id] = entry
                        save(state)
                    }
                } else {
                    failed.insert(id)
                }
            }
        }
        await flushRetired(&state)
    }

    private func flushRetired(_ state: inout PushState) async {
        guard let relay, !state.retired.isEmpty else { return }
        var kept: [String] = []
        for send in state.retired where !kept.contains(send) {
            do { try await relay.unregister(sendToken: send) }
            catch PushRelayError.status(let code) where code == 400 || code == 401 { /* Malformed: never retried. */ }
            catch { kept.append(send) }
        }
        state.retired = kept
        save(state)
    }
}

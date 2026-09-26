import Foundation
import Observation

struct SavedHost: Codable, Equatable {
    var id: String
    var label: String
}

struct HostCatalog: Codable, Equatable {
    var hosts: [SavedHost]
    var active: String?
}

/// Unambiguous name for the generated core model (Foundation also defines `Operation`).
typealias CoreOperation = Operation

struct HostRow {
    var saved: SavedHost
    var view: HostView?
    var operation: Operation?
    var busy = false
    var fatal = false
}

/// Owns platform host identities and selection only. Every protocol action
/// (pairing, sign-out, forget, retry) belongs to that host's own core handle,
/// and runtime data is never merged across hosts.
@MainActor @Observable
final class HostsModel {
    static let catalogKey = "ios/1/hosts"
    static let maxHosts = 32
    /// Auth states whose local data is gone or going; the warm-start cache follows.
    static let wiped: Set<String> = ["unpaired", "signing_out", "signed_out"]
    /// Written by the I-03 single-host build; migrated into the catalog once.
    static let legacyDefaultsKey = "pairing.hostID"

    private(set) var catalog = HostCatalog(hosts: [], active: nil)
    private(set) var loading = true
    private(set) var busy = false
    var error: String?
    private(set) var pairing: String?
    private(set) var sessions: [String: PairingModel] = [:]
    private var intents: [String: String] = [:]
    private var acting: Set<String> = []
    private var cleared: Set<String> = []
    private(set) var isForeground = false
    private(set) var networkState: NetworkState?
    private var pendingLink: String?
    private var began = false
    private var closed = false
    /// Browse/cache observers: the active host changed, or a host's store published.
    @ObservationIgnored var onActiveChange: (() -> Void)?
    @ObservationIgnored var onStoreChange: ((String) -> Void)?

    private let storage: SecureStorage
    let cache: ViewCache?
    private let deviceLabel: String
    private let legacyID: () -> String?
    private let makeHost: (SavedHost, CoreViewStore) throws -> CoreHost

    init(storage: SecureStorage, cache: ViewCache?, deviceLabel: String,
         legacyID: @escaping () -> String? = { nil },
         makeHost: @escaping (SavedHost, CoreViewStore) throws -> CoreHost) {
        self.storage = storage
        self.cache = cache
        self.deviceLabel = deviceLabel
        self.legacyID = legacyID
        self.makeHost = makeHost
    }

    static func live(deviceLabel: String) -> HostsModel {
        HostsModel(storage: KeychainStorage(), cache: ViewCache.live(), deviceLabel: deviceLabel,
                   legacyID: { UserDefaults.standard.string(forKey: legacyDefaultsKey) }) { saved, store in
            try CoreHost.live(hostID: saved.id, label: saved.label, httpsURL: nil, wssURL: nil, store: store)
        }
    }

    static func validID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f
        }
    }

    static func valid(_ value: HostCatalog) -> Bool {
        let ids = value.hosts.map(\.id)
        return value.hosts.count <= maxHosts && Set(ids).count == ids.count
            && value.hosts.allSatisfy { validID($0.id) && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 128 }
            && (value.active.map { ids.contains($0) } ?? true)
    }

    // MARK: Rows

    var active: String? { catalog.active }
    var rows: [HostRow] { catalog.hosts.map { makeRow($0) } }
    func row(_ id: String) -> HostRow? { catalog.hosts.first { $0.id == id }.map { makeRow($0) } }
    func session(_ id: String?) -> PairingModel? { id.flatMap { sessions[$0] } }

    private func makeRow(_ saved: SavedHost) -> HostRow {
        let session = sessions[saved.id]
        let intent = intents[saved.id]
        return HostRow(saved: saved, view: session?.row,
                       operation: intent.flatMap { id in session?.store.hosts?.data?.operations.first { $0.intent_id == id } },
                       busy: acting.contains(saved.id), fatal: session?.fatal ?? false)
    }

    // MARK: Catalog

    /// First load, once the app has its initial signals; later calls are no-ops.
    func begin() {
        guard !began else { return }
        began = true
        load()
    }

    func load() {
        guard loading, !closed else { return }
        busy = true
        error = nil
        do {
            let saved = try storage.get(Self.catalogKey)
            let value: HostCatalog
            if let saved {
                value = try JSONDecoder().decode(HostCatalog.self, from: saved)
            } else {
                // First launch after I-03 keeps that host's Keychain records; a fresh install gets one slot.
                let id = legacyID().flatMap { Self.validID($0) ? $0 : nil } ?? "primary"
                value = HostCatalog(hosts: [SavedHost(id: id, label: "My host")], active: id)
            }
            guard Self.valid(value) else { throw StorageError(code: .io) }
            if saved == nil { try persist(value) } else { setCatalog(value) }
            loading = false
            value.hosts.forEach { open($0) }
        } catch {
            self.error = "Could not load saved hosts. Unlock your phone and retry."
        }
        busy = false
        if !loading, let link = pendingLink { pendingLink = nil; receiveLink(link) }
    }

    private func persist(_ value: HostCatalog) throws {
        try storage.put(Self.catalogKey, value: JSONEncoder().encode(value))
        setCatalog(value)
    }

    private func setCatalog(_ value: HostCatalog) {
        let changed = value.active != catalog.active
        catalog = value
        if changed { onActiveChange?() }
    }

    private func catalogAction(_ block: () throws -> Void) {
        guard !busy, !loading, !closed else { return }
        error = nil
        do { try block() } catch { self.error = "Could not save hosts. Unlock your phone and retry." }
    }

    func select(_ id: String) {
        catalogAction {
            guard catalog.hosts.contains(where: { $0.id == id }) else { return }
            try persist(HostCatalog(hosts: catalog.hosts, active: id))
            pairing = nil
        }
    }

    func add(label: String, link: String? = nil) {
        catalogAction {
            guard catalog.hosts.count < Self.maxHosts else {
                error = "Remove a host before adding another (32 host limit)."
                return
            }
            let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            let saved = SavedHost(id: UUID().uuidString.lowercased(), label: trimmed.isEmpty ? "My host" : trimmed)
            try persist(HostCatalog(hosts: catalog.hosts + [saved], active: saved.id))
            pairing = saved.id
            open(saved)
            if let link, let session = sessions[saved.id] { Task { await session.receive(link) } }
        }
    }

    /// Catalog removal is allowed only after the core confirms its secure-store deletes.
    func remove(_ id: String) {
        catalogAction {
            guard row(id)?.view?.auth_state == "signed_out" else { return }
            let remaining = catalog.hosts.filter { $0.id != id }
            let active = catalog.active == id ? remaining.first?.id : catalog.active
            try persist(HostCatalog(hosts: remaining, active: active))
            if let session = sessions.removeValue(forKey: id) { Task { await session.stop() } }
            intents[id] = nil
            acting.remove(id)
            cleared.remove(id)
            cache?.clear(id)
            if pairing == id { pairing = nil }
        }
    }

    func showPairing(_ id: String?) { pairing = id }

    // MARK: Sessions and signals

    private func open(_ saved: SavedHost) {
        guard sessions[saved.id] == nil else { return }
        let store = CoreViewStore()
        let id = saved.id
        let makeHost = self.makeHost
        let session = PairingModel(deviceLabel: deviceLabel, store: store) { store in try makeHost(saved, store) }
        store.onApply = { [weak self] in self?.storeChanged(id) }
        sessions[id] = session
        // Queued behind `start`: network first, then the current foreground state.
        if let networkState { session.network(networkState) }
        session.foreground(isForeground)
        Task { await session.start() }
    }

    private func storeChanged(_ id: String) {
        guard let session = sessions[id] else { return }
        if let state = session.row?.auth_state {
            // Local removal or a missing credential retires this host's warm-start cache.
            if Self.wiped.contains(state) {
                if !cleared.contains(id) { cleared.insert(id); cache?.clear(id) }
            } else if state == "paired" { cleared.remove(id) }
        }
        if session.awaitingSubmit { Task { await session.submitPending() } }
        onStoreChange?(id)
    }

    /// Pairing links (scanned, pasted, universal or custom-scheme) go to the host
    /// being paired, else to a new host slot.
    func receiveLink(_ link: String) {
        guard !closed else { return }
        if loading { pendingLink = link; return }
        let id = pairing ?? catalog.active
        if let id, let session = sessions[id], !session.complete {
            pairing = id
            Task { await session.receive(link) }
        } else {
            add(label: "My host", link: link)
        }
    }

    func open(url: URL) {
        guard PairingInput.routes(url) else { return }
        receiveLink(url.absoluteString)
    }

    func foreground(_ active: Bool) {
        isForeground = active
        sessions.values.forEach { $0.foreground(active) }
    }

    func network(_ state: NetworkState) {
        networkState = state
        sessions.values.forEach { $0.network(state) }
    }

    // MARK: Host actions

    func signOut(_ id: String, forget: Bool = false) {
        action(id) { host, intent in
            try await host.send(forget
                ? .forget_host(EventForgetHost(now_ms: 0, wall_time_ms: 0, intent_id: intent, host_id: id))
                : .sign_out(EventSignOut(now_ms: 0, wall_time_ms: 0, intent_id: intent, host_id: id)))
        }
    }

    /// Also retries a failed local delete: the core resumes deletion without repeating revoke.
    func retry(_ id: String) {
        action(id) { host, intent in
            try await host.send(.retry_connection(EventRetryConnection(now_ms: 0, wall_time_ms: 0, intent_id: intent)))
        }
    }

    private func action(_ id: String, _ block: @escaping (CoreHost, String) async throws -> Void) {
        guard !closed, let row = row(id), !row.busy, row.operation?.state != "pending", !row.fatal,
              let session = sessions[id] else { return }
        let intent = UUID().uuidString
        intents[id] = intent
        acting.insert(id)
        Task {
            defer { acting.remove(id) }
            await session.start()
            guard let host = session.host else { return } // Open failure is already published as fatal.
            do { try await block(host, intent) }
            catch CoreBridgeError.rejected { error = "This host is still loading or finishing an action. Try again shortly." }
            catch { /* The host closed and its store published a fixed failure. */ }
        }
    }

    func close() async {
        closed = true
        pendingLink = nil
        let all = Array(sessions.values)
        sessions.removeAll()
        for session in all { await session.stop() }
    }
}

func hostStatus(_ row: HostRow) -> String {
    if row.fatal { return "Connection unavailable — reopen Verde" }
    guard let view = row.view, view.auth_state != "loading" else { return "Loading" }
    if view.auth_state == "signed_out" { return "Signed out" }
    if view.auth_state == "signing_out" { return "Removing local data" }
    if view.auth_state == "repair_required" { return "Pair again — device authorization needs renewal" }
    if view.trust_proposal != nil { return "Review host identity" }
    if view.update_required { return "Update required" }
    if view.auth_state == "unpaired" { return "Not paired" }
    if view.phase == "ready" { return "Connected" }
    if view.error?.failure_kind == "network" || view.phase == "failed" { return "Unreachable — is Tailscale on?" }
    if view.lifecycle == .background || view.phase == "disabled" { return "Offline" }
    return "Connecting"
}

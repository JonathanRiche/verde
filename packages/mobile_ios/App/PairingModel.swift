import Foundation
import Observation
import Security

/// Routes and formats input only. The core validates links, owns retries/nonces
/// after submission, proposes trust, and commits credentials through Keychain.
enum PairingInput {
    static func routes(_ url: URL) -> Bool {
        let raw = url.absoluteString
        return raw.hasPrefix("verde://pair?") || raw.hasPrefix("https://verdeai.dev/pair?")
    }

    static func manual(host: String, grant: String, code: String) -> String {
        var link = URLComponents()
        link.scheme = "verde"
        link.host = "pair"
        link.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "grant_id", value: grant)]
        link.fragment = "code=\(code)"
        return link.string ?? ""
    }

    static func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CoreBridgeError.invalidOutput
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One saved host's core session. The platform owns lifecycle/network signals
/// and pairing input; the core owns every protocol decision.
@MainActor @Observable
final class PairingModel {
    let store: CoreViewStore
    private(set) var host: CoreHost?
    private let makeHost: (CoreViewStore) throws -> CoreHost
    private var opening: Task<Void, Never>?
    private var started = false
    private var openFailed = false
    // Lifecycle/network events reach the core in call order, after `start`, deduplicated.
    private var signals: [Event] = []
    private var draining = false
    private var lastForeground: Bool?
    private var lastNetwork: NetworkState?
    private var pendingLink: String?
    private(set) var intentID: String?
    private(set) var submitting = false
    private(set) var inputError: String?
    var deviceLabel: String

    init(deviceLabel: String, store: CoreViewStore? = nil,
         makeHost: @escaping (CoreViewStore) throws -> CoreHost) {
        self.deviceLabel = deviceLabel
        self.store = store ?? CoreViewStore()
        self.makeHost = makeHost
    }

    var row: HostView? { store.hosts?.data?.items.first }
    var operation: Operation? { store.hosts?.data?.operations.first { $0.intent_id == intentID } }
    var busy: Bool { submitting || pendingLink != nil || (intentID != nil && operation == nil) || operation?.state == "pending" }
    var paired: Bool { row?.auth_state == "paired" && operation?.state != "pending" }
    /// Paired with an accepted identity: a new link opens another host slot instead.
    var complete: Bool { row?.auth_state == "paired" && row?.trust_proposal == nil }
    var fatal: Bool { store.failed || openFailed }
    /// A received link waits for the core's stored state before it is submitted.
    var awaitingSubmit: Bool { pendingLink != nil && !submitting }
    var error: LocalError? { row?.error ?? operation?.error }
    var errorText: String? {
        if let inputError { return inputError }
        if fatal { return "The connection stopped unexpectedly. Close and reopen Verde to try again." }
        guard let error else { return nil }
        if error.domain == "storage" { return "Could not save or load this host in Keychain. Unlock your phone, then retry." }
        switch error.code {
        case "trust_denied": return "Host was not trusted. Scan a new code when you are ready."
        case "auth_rejected": return "This pairing grant expired or was already used. Create a new grant on your host."
        case "exchange_uncertain": return "The host may have paired this phone, but its reply was lost. Create a new grant."
        case "repair_required": return "This device's access was revoked. Pair again with a new grant."
        case "tls_rejected": return "The host's secure connection could not be verified. Check its certificate and address."
        case "network_unavailable": return "Could not reach the host. Check Tailscale and your network, then retry."
        case "discovery_rejected", "identity_rejected": return "The host identity could not be verified. Check the host before pairing again."
        default: return "Pairing could not complete. Check that Verde is up to date on your phone and host."
        }
    }

    /// Opens the core once. It starts in the background; queued signals then
    /// follow in order (network before foreground when both are known).
    func start() async {
        if let opening { await opening.value; return }
        let task = Task { await openCore() }
        opening = task
        await task.value
    }

    private func openCore() async {
        do {
            let host = try makeHost(store)
            self.host = host
            try await host.send(.start(EventStart(now_ms: 0, wall_time_ms: 0, foreground: false, network_available: true)))
            started = true
            await drain()
        } catch {
            openFailed = true
            inputError = "Could not open the connection. Close and reopen Verde to try again."
            store.onApply?()
        }
    }

    func foreground(_ active: Bool) {
        guard lastForeground != active else { return }
        lastForeground = active
        enqueue(active ? .foreground(EventForeground(now_ms: 0, wall_time_ms: 0))
            : .background(EventBackground(now_ms: 0, wall_time_ms: 0)))
    }

    /// The core invalidates transport on a changed route and reconnects with its jittered backoff.
    func network(_ state: NetworkState) {
        guard lastNetwork != state else { return }
        lastNetwork = state
        enqueue(.network_changed(EventNetworkChanged(now_ms: 0, wall_time_ms: 0,
            available: state.available, network_id: state.id)))
    }

    private func enqueue(_ event: Event) {
        signals.append(event)
        Task { await drain() }
    }

    private func drain() async {
        guard started, !draining, let host else { return }
        draining = true
        defer { draining = false }
        while !signals.isEmpty {
            let event = signals.removeFirst()
            do { try await host.send(event) }
            catch CoreBridgeError.rejected { continue } // No state change; the next signal still applies.
            catch { signals.removeAll(); return }         // The host closed and published its failure.
        }
    }

    func receive(_ link: String) async {
        guard !busy else { return }
        guard link.utf8.count <= 8192 else { inputError = "This pairing link is too long."; return }
        pendingLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        inputError = nil
        await start()
        await submitPending()
    }

    func open(_ url: URL) async {
        guard PairingInput.routes(url) else { inputError = "This is not a Verde pairing link."; return }
        await receive(url.absoluteString)
    }

    func submitPending() async {
        guard !submitting, let host, let link = pendingLink,
              let row, row.auth_state != "loading", row.lifecycle == .foreground else { return }
        pendingLink = nil
        submitting = true
        defer { submitting = false }
        let id = UUID().uuidString
        do {
            let nonce = try PairingInput.nonce()
            try await host.send(.pair(EventPair(now_ms: 0, wall_time_ms: 0, intent_id: id,
                link: link, device_label: deviceLabel, client_nonce: nonce)))
            intentID = id
        } catch {
            inputError = "Invalid pairing details. Use the complete link or check the host, grant ID, code and device name."
        }
    }

    func trust(_ proposal: TrustProposal, accept: Bool) async {
        guard !submitting else { return }
        await send(.trust_decision(EventTrustDecision(now_ms: 0, wall_time_ms: 0,
            intent_id: UUID().uuidString, proposal_id: proposal.id, accept: accept)))
    }

    func retry() async {
        inputError = nil
        await send(.retry_connection(EventRetryConnection(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString)))
    }

    private func send(_ event: Event) async {
        guard let host else { return }
        submitting = true
        defer { submitting = false }
        do { try await host.send(event) }
        catch { inputError = "This action is no longer available. Check the connection and try again." }
    }

    func clearNotice() { inputError = nil }

    func stop() async {
        pendingLink = nil
        signals.removeAll()
        await opening?.value
        try? await host?.shutdown()
        host = nil
    }
}

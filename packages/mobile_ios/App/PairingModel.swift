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

@MainActor @Observable
final class PairingModel {
    let store: CoreViewStore
    private var host: CoreHost?
    private let makeHost: (CoreViewStore) throws -> CoreHost
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

    static func live(deviceLabel: String) -> PairingModel {
        // Only a local identifier is in preferences. Core profile/credential
        // bytes remain exclusively in the existing secure storage adapter.
        let defaults = UserDefaults.standard
        let key = "pairing.hostID"
        let id = defaults.string(forKey: key) ?? UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return PairingModel(deviceLabel: deviceLabel) { store in
            try CoreHost.live(hostID: id, label: "Verde host", httpsURL: nil, wssURL: nil, store: store)
        }
    }

    var row: HostView? { store.hosts?.data?.items.first }
    var operation: Operation? { store.hosts?.data?.operations.first { $0.intent_id == intentID } }
    var busy: Bool { submitting || pendingLink != nil || (intentID != nil && operation == nil) || operation?.state == "pending" }
    var paired: Bool { row?.auth_state == "paired" && operation?.state != "pending" }
    var error: LocalError? { row?.error ?? operation?.error }
    var errorText: String? {
        if let inputError { return inputError }
        if store.failed { return "The connection stopped unexpectedly. Close and reopen Verde to try again." }
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

    func start() async {
        guard host == nil else { return }
        do {
            let host = try makeHost(store)
            self.host = host
            try await host.send(.start(EventStart(now_ms: 0, wall_time_ms: 0, foreground: true, network_available: true)))
        } catch { inputError = "Could not open the connection. Close and reopen Verde to try again." }
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

    func foreground(_ active: Bool) async {
        guard host != nil else { return }
        if active { await send(.foreground(EventForeground(now_ms: 0, wall_time_ms: 0))) }
        else { await send(.background(EventBackground(now_ms: 0, wall_time_ms: 0))) }
    }

    private func send(_ event: Event) async {
        guard let host else { return }
        submitting = true
        defer { submitting = false }
        do { try await host.send(event) }
        catch { inputError = "This action is no longer available. Check the connection and try again." }
    }

    func stop() async { try? await host?.shutdown(); host = nil; pendingLink = nil }
}

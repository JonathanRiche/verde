import Foundation

/// Build-time push configuration (Info.plist, from build settings). An empty relay URL turns
/// remote registration off entirely; the APNs environment always matches the signed
/// `aps-environment` entitlement (development → sandbox).
struct PushConfig: Equatable {
    static let relayKey = "VerdePushRelayURL"
    static let environmentKey = "VerdeAPSEnvironment"

    var relayURL: URL?
    /// The relay's `environment`: `sandbox` or `production`.
    var environment: String

    static let main = PushConfig(info: Bundle.main.infoDictionary ?? [:])

    init(relayURL: URL?, environment: String) {
        self.relayURL = relayURL
        self.environment = environment
    }

    init(info: [String: Any]) {
        relayURL = Self.relay(info[Self.relayKey] as? String)
        environment = (info[Self.environmentKey] as? String) == "production" ? "production" : "sandbox"
    }

    /// Only an absolute https base URL without query, fragment or credentials is accepted.
    static func relay(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

enum PushRelayError: Error, Equatable {
    /// HTTP status from the relay (README: 400/401/410/413/429/503).
    case status(Int)
    case invalidResponse
    case network
}

/// The push relay's HTTP contract (verde-cloud `services/push-relay`). `send_token` is a
/// bearer capability: it only ever travels in request bodies and never reaches logs.
struct PushRelayClient {
    static let timeout: TimeInterval = 10

    let base: URL
    var session: URLSession = .shared

    private var endpoint: URL { base.appendingPathComponent("v1").appendingPathComponent("register") }

    /// `POST /v1/register` with the 64-hex APNs token; returns the new `send_token`.
    func register(token: String, environment: String) async throws -> String {
        let data = try await call("POST", ["platform": "ios", "push_token": token, "environment": environment], expect: [201])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let send = object["send_token"] as? String, !send.isEmpty, send.utf8.count <= 4096,
              send.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else { throw PushRelayError.invalidResponse }
        return send
    }

    /// `DELETE /v1/register`. A 410 means the capability is already gone, which is success.
    func unregister(sendToken: String) async throws {
        _ = try await call("DELETE", ["send_token": sendToken], expect: [204, 410])
    }

    private func call(_ method: String, _ body: [String: String], expect: Set<Int>) async throws -> Data {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: NoRedirects.shared) }
        catch { throw PushRelayError.network }
        guard let http = response as? HTTPURLResponse else { throw PushRelayError.invalidResponse }
        guard expect.contains(http.statusCode) else { throw PushRelayError.status(http.statusCode) }
        return data
    }
}

/// The relay never redirects; following one could forward a capability elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

extension Data {
    /// APNs device token as the relay's 64 lowercase hex characters.
    var pushTokenHex: String { map { String(format: "%02x", $0) }.joined() }
}

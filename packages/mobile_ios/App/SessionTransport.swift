import Foundation
import Security
import CryptoKit

/// A session belongs to exactly one effect and immutable TLS policy. Connections
/// can never be reused for another origin/pin. No cookies, cache or redirects.
final class SessionTransport: CoreTransport {
    private let queue = DispatchQueue(label: "dev.verdeai.core.transport")
    private var operations: [String: SessionOperation] = [:]

    func execute(_ effect: Effect, emit: @escaping (Event) -> Void) {
        queue.async {
            switch effect {
            case .http_request(let e): self.start(id: e.effect_id, effect: effect, emit: emit)
            case .tls_probe(let e): self.start(id: e.effect_id, effect: effect, emit: emit)
            case .ws_open(let e): self.start(id: e.effect_id, effect: effect, emit: emit)
            case .http_cancel(let e): self.operations[e.request_id]?.cancel()
            case .ws_close(let e): self.operations[e.socket_id]?.close(code: e.code)
            case .ws_send(let e):
                if let socket = self.operations[e.socket_id] { socket.send(e.text) }
                else {
                    emit(.ws_closed(EventWsClosed(now_ms: 0, wall_time_ms: 0, socket_id: e.socket_id,
                        generation: e.generation, code: nil, clean: false,
                        error: TransportFailure(kind: .network, code: .unavailable))))
                }
            default: preconditionFailure("transport_effect_required")
            }
        }
    }
    private func start(id: String, effect: Effect, emit: @escaping (Event) -> Void) {
        let operation = SessionOperation(effect: effect, queue: queue, emit: emit) { [weak self] in
            self?.operations.removeValue(forKey: id)
        }
        operations[id] = operation
        operation.start()
    }
    func stop() {
        queue.async {
            let active = Array(self.operations.values)
            active.forEach { $0.cancel() }
        }
    }
}

enum TLSPolicy {
    static func failure(systemTrusted: Bool, observed: String?, expected: String?) -> TransportFailure? {
        guard systemTrusted, observed != nil else { return TransportFailure(kind: .tls, code: .certificate) }
        if let expected, observed != expected { return TransportFailure(kind: .tls, code: .pin_mismatch) }
        return nil
    }

    static func endpoint(_ raw: String, origin: String, websocket: Bool) -> URL? {
        guard let url = URL(string: raw), let base = URL(string: origin),
              url.scheme == (websocket ? "wss" : "https"), base.scheme == "https",
              url.host != nil, url.host == base.host, (url.port ?? 443) == (base.port ?? 443),
              url.user == nil, url.password == nil, url.fragment == nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/" else { return nil }
        return url
    }

    static func inspect(_ trust: SecTrust, host: String) -> (Bool, String?) {
        // Explicit SSL policy validates the hostname as well as the chain.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let spki = spki(certificate: SecCertificateCopyData(leaf) as Data) else { return (false, nil) }
        // K-07 persists and compares canonical lowercase SHA-256 hex.
        let hash = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        return (true, hash)
    }

    // Extract the complete DER SubjectPublicKeyInfo, including algorithm and
    // parameters. SecKeyCopyExternalRepresentation alone is NOT an SPKI hash.
    static func spki(certificate: Data) -> Data? {
        let bytes = [UInt8](certificate)
        func item(_ offset: Int, limit: Int) -> (tag: UInt8, body: Int, end: Int)? {
            guard offset >= 0, offset + 2 <= limit, limit <= bytes.count else { return nil }
            var cursor = offset + 2
            var length = Int(bytes[offset + 1])
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, cursor + count <= limit else { return nil }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[cursor]); cursor += 1 }
            }
            guard length <= limit - cursor else { return nil }
            return (bytes[offset], cursor, cursor + length)
        }
        guard let root = item(0, limit: bytes.count), root.tag == 0x30, root.end == bytes.count,
              let tbs = item(root.body, limit: root.end), tbs.tag == 0x30 else { return nil }
        var cursor = tbs.body
        if let version = item(cursor, limit: tbs.end), version.tag == 0xa0 { cursor = version.end }
        // serialNumber, signature, issuer, validity, subject
        for _ in 0..<5 {
            guard let field = item(cursor, limit: tbs.end) else { return nil }
            cursor = field.end
        }
        guard let key = item(cursor, limit: tbs.end), key.tag == 0x30 else { return nil }
        return Data(bytes[cursor..<key.end])
    }
}

final class SessionOperation: NSObject, URLSessionDataDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let effect: Effect
    private let queue: DispatchQueue
    private let emit: (Event) -> Void
    private let ended: () -> Void
    private var session: URLSession?
    private var task: URLSessionTask?
    private var finished = false
    private var failure: TransportFailure?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var pendingSends: [String] = []
    private var sending = false

    init(effect: Effect, queue: DispatchQueue, emit: @escaping (Event) -> Void, ended: @escaping () -> Void) {
        self.effect = effect; self.queue = queue; self.emit = emit; self.ended = ended
    }
    private var policy: (origin: String, pin: String?) {
        switch effect {
        case .http_request(let e): return (e.tls.origin, e.tls.spki_sha256)
        case .ws_open(let e): return (e.tls.origin, e.tls.spki_sha256)
        case .tls_probe(let e): return (e.origin, nil)
        default: preconditionFailure("session_effect_required")
        }
    }
    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        if case .http_request(let e) = effect {
            // Parked RPCs carry longer core deadlines than interactive requests.
            config.timeoutIntervalForRequest = Double(e.timeout_ms) / 1000
            config.timeoutIntervalForResource = Double(e.timeout_ms) / 1000
        }
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegates)
        self.session = session
        switch effect {
        case .http_request(let e):
            guard let url = TLSPolicy.endpoint(e.url, origin: e.tls.origin, websocket: false),
                  !e.tls.spki_sha256.isEmpty else { fail(.tls, .certificate); return }
            var request = URLRequest(url: url)
            request.httpMethod = e.method
            request.timeoutInterval = Double(e.timeout_ms) / 1000
            request.httpShouldHandleCookies = false
            for header in e.headers { request.addValue(header.value, forHTTPHeaderField: header.name) }
            if let encoded = e.body_base64 {
                guard let data = Data(base64Encoded: encoded) else { fail(.resource, .resource); return }
                request.httpBody = data
            }
            task = session.dataTask(with: request)
        case .ws_open(let e):
            guard let url = TLSPolicy.endpoint(e.url, origin: e.tls.origin, websocket: true),
                  !e.tls.spki_sha256.isEmpty else { fail(.tls, .certificate); return }
            let socket = session.webSocketTask(with: url, protocols: e.protocols)
            socket.maximumMessageSize = Int(e.max_message_bytes)
            task = socket
        case .tls_probe(let e):
            guard let url = TLSPolicy.endpoint(e.origin, origin: e.origin, websocket: false) else {
                fail(.tls, .certificate); return
            }
            // Cancel at the server-trust challenge: never send an HTTP request.
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            task = session.dataTask(with: request)
        default: return
        }
        task?.resume()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completionHandler)
    }
    private func authenticate(_ challenge: URLAuthenticationChallenge,
                              _ complete: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !finished, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host == URL(string: policy.origin)?.host,
              challenge.protectionSpace.port == (URL(string: policy.origin)?.port ?? 443) else {
            failure = TransportFailure(kind: .tls, code: .certificate)
            complete(.cancelAuthenticationChallenge, nil)
            return
        }
        let (trusted, pin) = TLSPolicy.inspect(trust, host: challenge.protectionSpace.host)
        if case .tls_probe(let e) = effect {
            complete(.cancelAuthenticationChallenge, nil)
            emit(.tls_peer(EventTlsPeer(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                generation: e.generation, origin: e.origin, spki_sha256: pin ?? "", system_trusted: trusted)))
            finish()
        } else if let error = TLSPolicy.failure(systemTrusted: trusted, observed: pin, expected: policy.pin) {
            failure = error
            complete(.cancelAuthenticationChallenge, nil)
        } else {
            // The only path permitting request bytes: system trust AND pin match.
            complete(.useCredential, URLCredential(trust: trust))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard case .http_request(let e) = effect, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); fail(.tls, .certificate); return
        }
        self.response = http
        if response.expectedContentLength > Int64(e.max_response_bytes) {
            completionHandler(.cancel); fail(.resource, .resource)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, case .http_request(let e) = effect else { return }
        guard data.count <= Int(e.max_response_bytes) - body.count else { fail(.resource, .resource); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error { failure = failure ?? Self.map(error) }
        switch effect {
        case .http_request(let e):
            let headers = response?.allHeaderFields.map { Header(name: String(describing: $0.key), value: String(describing: $0.value)) } ?? []
            emit(.http_response(EventHttpResponse(now_ms: 0, wall_time_ms: 0,
                effect_id: e.effect_id, generation: e.generation,
                status: failure == nil ? response.map { UInt16($0.statusCode) } : nil,
                headers: failure == nil ? headers : [], body_base64: failure == nil ? body.base64EncodedString() : nil, error: failure)))
        case .tls_probe(let e):
            emit(.tls_peer(EventTlsPeer(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                generation: e.generation, origin: e.origin, spki_sha256: "", system_trusted: false)))
        case .ws_open: emitClosed(code: nil, clean: false, error: failure ?? TransportFailure(kind: .network, code: .unknown))
        default: break
        }
        finish()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard !finished, case .ws_open(let e) = effect else { return }
        guard let selected = `protocol`, e.protocols.contains(selected), selected == "verde.v1" else {
            fail(.network, .unknown); return
        }
        emit(.ws_open(EventWsOpen(now_ms: 0, wall_time_ms: 0, socket_id: e.effect_id,
            generation: e.generation, protocol: selected)))
        receive()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard !finished else { return }
        emitClosed(code: UInt16(exactly: closeCode.rawValue), clean: true, error: nil)
        finish()
    }
    private func receive() {
        guard !finished, let socket = task as? URLSessionWebSocketTask else { return }
        socket.receive { result in
            self.queue.async {
                guard !self.finished, case .ws_open(let e) = self.effect else { return }
                switch result {
                case .success(.string(let text)) where text.utf8.count <= Int(e.max_message_bytes):
                    self.emit(.ws_message(EventWsMessage(now_ms: 0, wall_time_ms: 0,
                        socket_id: e.effect_id, generation: e.generation, text: text)))
                    self.receive()
                case .success: self.fail(.resource, .resource)
                case .failure(let error):
                    let mapped = self.failure ?? Self.map(error)
                    self.fail(mapped.kind, mapped.code)
                }
            }
        }
    }
    func send(_ text: String) { pendingSends.append(text); sendNext() }
    private func sendNext() {
        guard !finished, !sending, !pendingSends.isEmpty, let socket = task as? URLSessionWebSocketTask else { return }
        sending = true
        socket.send(.string(pendingSends.removeFirst())) { error in
            self.queue.async {
                self.sending = false
                if let error { let mapped = Self.map(error); self.fail(mapped.kind, mapped.code) }
                else { self.sendNext() }
            }
        }
    }
    func cancel() { fail(.cancelled, .cancelled) }
    func close(code: UInt16) {
        guard !finished else { return }
        (task as? URLSessionWebSocketTask)?.cancel(with: .init(rawValue: Int(code)) ?? .normalClosure, reason: nil)
        emitClosed(code: code, clean: true, error: nil)
        finish()
    }
    private func emitClosed(code: UInt16?, clean: Bool, error: TransportFailure?) {
        guard case .ws_open(let e) = effect else { return }
        emit(.ws_closed(EventWsClosed(now_ms: 0, wall_time_ms: 0, socket_id: e.effect_id,
            generation: e.generation, code: code, clean: clean, error: error)))
    }
    private func fail(_ kind: TransportFailureKind, _ code: TransportFailureCode) {
        guard !finished else { return }
        failure = TransportFailure(kind: kind, code: code)
        // Complete locally even if Foundation never delivers another callback.
        if let session, let task { urlSession(session, task: task, didCompleteWithError: nil) }
        else {
            switch effect {
            case .http_request(let e):
                emit(.http_response(EventHttpResponse(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                    generation: e.generation, status: nil, headers: [], body_base64: nil, error: failure)))
            case .ws_open: emitClosed(code: nil, clean: false, error: failure)
            case .tls_probe(let e):
                emit(.tls_peer(EventTlsPeer(now_ms: 0, wall_time_ms: 0, effect_id: e.effect_id,
                    generation: e.generation, origin: e.origin, spki_sha256: "", system_trusted: false)))
            default: break
            }
            finish()
        }
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        task = nil
        pendingSends.removeAll()
        ended()
    }
    private static func map(_ error: Error) -> TransportFailure {
        switch (error as NSError).code {
        case NSURLErrorCancelled: return TransportFailure(kind: .cancelled, code: .cancelled)
        case NSURLErrorTimedOut: return TransportFailure(kind: .timeout, code: .timeout)
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return TransportFailure(kind: .network, code: .offline)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return TransportFailure(kind: .network, code: .dns)
        case NSURLErrorCannotConnectToHost: return TransportFailure(kind: .network, code: .refused)
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed: return TransportFailure(kind: .tls, code: .certificate)
        default: return TransportFailure(kind: .network, code: .unknown)
        }
    }
}

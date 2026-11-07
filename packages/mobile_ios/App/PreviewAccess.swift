import Foundation

/// A native-only request capability using the core-authorized origin, bearer, and TLS pin.
final class PreviewAccess: @unchecked Sendable {
    private let request: EffectHttpRequest
    private let queue = DispatchQueue(label: "verde.preview.assets")
    private lazy var pool = HTTPConnectionPool(queue: queue)
    private var jobs: [UUID: SessionOperation] = [:]
    private var closed = false
    init(request: EffectHttpRequest) { self.request = request }
    func open(path: String, method: String, range: String?, stream: HTTPStream) -> UUID {
        let id = UUID()
        queue.async { [self] in
            guard !closed, var target = URLComponents(string: request.url) else { stream.complete(NSError(domain: "VerdePreview", code: 1)); return }
            target.queryItems = [URLQueryItem(name: "download", value: "1"), URLQueryItem(name: "path", value: path)]
            guard let url = target.url else { stream.complete(NSError(domain: "VerdePreview", code: 1)); return }
            var headers = request.headers.filter { $0.name.lowercased() != "range" }
            if let range { headers.append(Header(name: "Range", value: range)) }
            headers.append(Header(name: "Accept-Encoding", value: "identity"))
            let effect = EffectHttpRequest(effect_id: id.uuidString, generation: request.generation, method: method, url: url.absoluteString, headers: headers,
                body_base64: nil, timeout_ms: 60_000, max_response_bytes: UInt32.max, tls: request.tls)
            let wrapped = HTTPStream(response: stream.response, data: stream.data, complete: { [weak self] error in
                self?.jobs.removeValue(forKey: id); stream.complete(error)
            })
            let operation = SessionOperation(effect: .http_request(effect), queue: queue, pool: pool, emit: { _ in }, stream: wrapped, ended: {})
            jobs[id] = operation
            operation.start()
        }
        return id
    }
    func cancel(_ id: UUID) { queue.async { self.jobs.removeValue(forKey: id)?.cancel() } }
    func cancelAll() { queue.async { self.stop() } }
    func close() { queue.async { self.closed = true; self.stop(); self.pool.close() } }
    private func stop() { let pending = Array(jobs.values); jobs.removeAll(); pending.forEach { $0.cancel() } }
}

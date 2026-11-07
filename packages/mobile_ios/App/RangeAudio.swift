import AVFoundation
import UniformTypeIdentifiers

/// AVFoundation's seek requests run through the same ephemeral, pinned TLS transport as the core.
/// Credentials never appear in the player URL; each read is bounded to 256 KiB.
final class RangeAudio: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let request: EffectHttpRequest
    private let length: Int64
    private let mime: String
    private let validator: String?
    private let queue = DispatchQueue(label: "verde.audio.ranges")
    private lazy var pool = HTTPConnectionPool(queue: queue)
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var closed = false
    private(set) lazy var asset: AVURLAsset = {
        let asset = AVURLAsset(url: URL(string: "verde-audio://recording")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }()
    private final class Job {
        let loading: AVAssetResourceLoadingRequest
        var operation: SessionOperation?
        init(_ loading: AVAssetResourceLoadingRequest) { self.loading = loading }
    }
    init(request: EffectHttpRequest, length: Int64, mime: String, validator: String?) {
        self.request = request; self.length = length; self.validator = validator
        let path = URLComponents(string: request.url)?.queryItems?.first { $0.name == "path" }?.value ?? ""
        let ext = (path as NSString).pathExtension.lowercased()
        self.mime = mime == "application/octet-stream" ? (["mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "ogg": "audio/ogg"][ext] ?? mime) : mime
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed else { return false }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = UTType(mimeType: mime)?.identifier ?? UTType.mp3.identifier
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard loadingRequest.dataRequest != nil else { loadingRequest.finishLoading(); return true }
        let job = Job(loadingRequest)
        jobs[ObjectIdentifier(loadingRequest)] = job
        read(job)
        return true
    }
    private func read(_ job: Job) {
        guard let data = job.loading.dataRequest else { return }
        let key = ObjectIdentifier(job.loading)
        let offset = max(data.requestedOffset, data.currentOffset)
        let end = data.requestsAllDataToEndOfResource ? length : min(length, data.requestedOffset + Int64(data.requestedLength))
        guard offset < end else { jobs.removeValue(forKey: key); job.loading.finishLoading(); return }
        let count = min(256 * 1024, end - offset)
        var headers = request.headers.filter { $0.name.lowercased() != "range" }
        headers.append(Header(name: "Range", value: "bytes=\(offset)-\(offset + count - 1)"))
        if let validator { headers.append(Header(name: "If-Range", value: validator)) }
        let effect = EffectHttpRequest(effect_id: UUID().uuidString, generation: request.generation, method: "GET", url: request.url,
            headers: headers, body_base64: nil, timeout_ms: 30_000, max_response_bytes: UInt32(count), tls: request.tls)
        let operation = SessionOperation(effect: .http_request(effect), queue: queue, pool: pool, emit: { [weak self, weak job] event in
            guard let self, let job, self.jobs[key] === job, case .http_response(let result) = event else { return }
            let range = result.headers.first { $0.name.lowercased() == "content-range" }?.value
            guard result.error == nil, result.status == 206, range == "bytes \(offset)-\(offset + count - 1)/\(self.length)",
                  let encoded = result.body_base64, let bytes = Data(base64Encoded: encoded), bytes.count == count else {
                self.jobs.removeValue(forKey: key)
                job.loading.finishLoading(with: NSError(domain: "VerdeAudio", code: 1))
                return
            }
            job.loading.dataRequest?.respond(with: bytes)
            self.read(job)
        }, ended: {})
        job.operation = operation
        operation.start()
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        jobs.removeValue(forKey: ObjectIdentifier(loadingRequest))?.operation?.cancel()
    }
    func close() {
        queue.async { [self] in
            closed = true
            let pending = Array(jobs.values); jobs.removeAll()
            pending.forEach { $0.operation?.cancel() }
            pool.close()
        }
    }
}

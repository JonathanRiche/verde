import Foundation

final class FileBytes: @unchecked Sendable {
    private let memory: Data?
    let url: URL?
    let mime: String?
    var audio: RangeAudio?
    let size: Int64
    init(data: Data, mime: String?) { memory = data; url = nil; self.mime = mime; size = Int64(data.count) }
    init(url: URL, size: Int64, mime: String?) { memory = nil; self.url = url; self.size = size; self.mime = mime }
    // Used only by bounded previews. Download and native audio use the file URL.
    var data: Data { memory ?? ((try? Data(contentsOf: url!, options: .mappedIfSafe)) ?? Data()) }
    init(audio: RangeAudio, size: Int64, mime: String?) { memory = nil; url = nil; self.audio = audio; self.size = size; self.mime = mime }
    deinit { audio?.close(); if let url { try? FileManager.default.removeItem(at: url) } }
}

/// Raw file bytes never enter core JSON or persistent storage. Bounded per host;
/// completions discarded by a closed viewer cannot reappear after cancellation.
final class FileBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: FileBytes] = [:]
    private var order: [String] = []
    private var ignored: Set<String> = []
    private var ignoredOrder: [String] = []
    func put(_ id: String, _ bytes: FileBytes) {
        lock.lock(); defer { lock.unlock() }
        guard !ignored.contains(id), bytes.audio != nil || bytes.url != nil || bytes.size <= 32 * 1024 * 1024 else { return }
        entries[id] = bytes; order.removeAll { $0 == id }; order.append(id)
        while entries.count > 4 || entries.values.reduce(0, { $0 + ($1.url == nil && $1.audio == nil ? Int($1.size) : 0) }) > 64 * 1024 * 1024 {
            entries.removeValue(forKey: order.removeFirst())
        }
    }
    func take(_ id: String) -> FileBytes? {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == id }
        return entries.removeValue(forKey: id)
    }
    func discard(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: id); order.removeAll { $0 == id }
        if ignored.insert(id).inserted { ignoredOrder.append(id) }
        while ignoredOrder.count > 128 { ignored.remove(ignoredOrder.removeFirst()) }
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); order.removeAll(); ignored.removeAll(); ignoredOrder.removeAll()
    }
}

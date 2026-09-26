import Foundation

struct FileBytes {
    let data: Data
    let mime: String?
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
        guard !ignored.contains(id), bytes.data.count <= 32 * 1024 * 1024 else { return }
        entries[id] = bytes; order.removeAll { $0 == id }; order.append(id)
        while entries.count > 4 || entries.values.reduce(0, { $0 + $1.data.count }) > 64 * 1024 * 1024 {
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

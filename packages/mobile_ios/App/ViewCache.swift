import Foundation
import CryptoKit

/// Last live core projections for one host, shown only until that host's core has synced.
struct CachedViews: Codable {
    var version: Int = 1
    var saved_at_ms: Int64
    var home: HomeView
    var workspaces: WorkspacesView
}

/// Warm-start cache: one AES-GCM file per host under Application Support,
/// excluded from backup and written with file protection. The key lives only in
/// this device's Keychain (`AfterFirstUnlockThisDeviceOnly`), so a restored or
/// copied file is unreadable. Content (titles, paths) is never logged. Sign-out
/// and removal clear it; unreadable or oversized entries are discarded.
///
/// Main-actor only: saves and clears are serialized with the host state that
/// decides whether a save is still allowed, so a save cannot land after a wipe.
@MainActor
final class ViewCache {
    static let maxBytes = 512 * 1024
    static let maxItems = 200
    static let keyName = "ios/1/view-cache-key"
    let directory: URL
    private let keys: SecureStorage

    init(directory: URL, keys: SecureStorage) {
        self.directory = directory
        self.keys = keys
    }

    static func live() -> ViewCache? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return ViewCache(directory: support.appendingPathComponent("ViewCache", isDirectory: true),
                         keys: KeychainStorage(service: "dev.verdeai.app.cache"))
    }

    func load(_ hostID: String) -> CachedViews? {
        guard let url = file(hostID), let sealed = try? Data(contentsOf: url) else { return nil }
        do {
            guard let raw = try keys.get(Self.keyName) else { throw CocoaError(.fileReadCorruptFile) }
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: raw), authenticating: Self.aad(hostID))
            let views = try JSONDecoder().decode(CachedViews.self, from: plain)
            guard views.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return views
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Returns false when the bounded copy is still too large or storage rejects it.
    @discardableResult
    func save(_ hostID: String, _ views: CachedViews) -> Bool {
        guard let url = file(hostID) else { return false }
        do {
            let plain = try JSONEncoder().encode(Self.bounded(views))
            guard plain.count <= Self.maxBytes else { return false }
            let box = try AES.GCM.seal(plain, using: key(), authenticating: Self.aad(hostID))
            guard let sealed = box.combined else { return false }
            try prepareDirectory()
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            return true
        } catch { return false }
    }

    func clear(_ hostID: String) {
        guard let url = file(hostID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func bounded(_ views: CachedViews) -> CachedViews {
        var copy = views
        copy.home.items = Array(views.home.items.prefix(maxItems))
        copy.workspaces.items = views.workspaces.items.prefix(maxItems).map { workspace in
            var bounded = workspace
            bounded.panes = Array(workspace.panes.prefix(maxItems))
            bounded.threads = Array(workspace.threads.prefix(maxItems))
            return bounded
        }
        copy.workspaces.history.items = Array(views.workspaces.history.items.prefix(maxItems))
        copy.workspaces.history.next_cursor = nil
        return copy
    }

    private static func aad(_ hostID: String) -> Data { Data("verde-view-cache/1/\(hostID)".utf8) }

    private func file(_ hostID: String) -> URL? {
        guard HostsModel.validID(hostID) else { return nil }
        return directory.appendingPathComponent("\(hostID).views", isDirectory: false)
    }

    private func key() throws -> SymmetricKey {
        if let raw = try keys.get(Self.keyName), raw.count == 32 { return SymmetricKey(data: raw) }
        let key = SymmetricKey(size: .bits256)
        try keys.put(Self.keyName, value: key.withUnsafeBytes { Data($0) })
        return key
    }

    private func prepareDirectory() throws {
        var url = directory
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

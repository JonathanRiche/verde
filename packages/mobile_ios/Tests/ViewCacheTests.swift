import XCTest
@testable import VerdeApp

@MainActor
final class ViewCacheTests: XCTestCase {
    private var directory: URL!
    private var keys = MemoryStorage()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func views() throws -> CachedViews {
        CachedViews(saved_at_ms: 1, home: try XCTUnwrap(K09.homeLive.data), workspaces: try XCTUnwrap(K09.workspacesLive.data))
    }

    func testEncryptedBoundHostScopedAndExcludedFromBackup() throws {
        let cache = ViewCache(directory: directory, keys: keys)
        var value = try views()
        let workspace = try XCTUnwrap(value.workspaces.items.first)
        value.workspaces.items = (0..<(ViewCache.maxItems + 5)).map { index in
            var copy = workspace
            copy.workspace_id = "w\(index)"
            return copy
        }
        value.workspaces.history.next_cursor = "cursor"
        XCTAssertTrue(cache.save("alpha", value))
        let loaded = try XCTUnwrap(cache.load("alpha"))
        XCTAssertEqual(loaded.workspaces.items.count, ViewCache.maxItems)
        XCTAssertNil(loaded.workspaces.history.next_cursor)
        XCTAssertEqual(loaded.home.items.count, 3)

        let file = directory.appendingPathComponent("alpha.views")
        let sealed = try Data(contentsOf: file)
        // Titles and paths never reach disk in plaintext.
        XCTAssertNil(sealed.range(of: Data("Fixture workspace".utf8)))
        XCTAssertNil(sealed.range(of: Data("/tmp/k09-fixture-project".utf8)))
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try keys.get(ViewCache.keyName)?.count, 32)

        // A file moved to another host's slot fails authentication and is discarded.
        let beta = directory.appendingPathComponent("beta.views")
        try sealed.write(to: beta)
        XCTAssertNil(cache.load("beta"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: beta.path))

        // Without this device's key the file is unreadable.
        XCTAssertNil(ViewCache(directory: directory, keys: MemoryStorage()).load("alpha"))

        cache.clear("alpha")
        XCTAssertNil(cache.load("alpha"))
        XCTAssertFalse(cache.save("../escape", value))
    }

    func testOversizedAndCorruptEntriesAreDiscarded() throws {
        let cache = ViewCache(directory: directory, keys: keys)
        var value = try views()
        let pane = try XCTUnwrap(value.home.items.first)
        value.home.items = (0..<ViewCache.maxItems).map { index in
            var copy = pane
            copy.id = "p\(index)"
            copy.title = String(repeating: "x", count: 4096)
            return copy
        }
        XCTAssertFalse(cache.save("alpha", value))
        XCTAssertNil(cache.load("alpha"))

        XCTAssertTrue(cache.save("alpha", try views()))
        try Data("{not sealed".utf8).write(to: directory.appendingPathComponent("alpha.views"))
        XCTAssertNil(cache.load("alpha"))
    }

    func testPushOpenReturnsGenericNoticeOrRejectsMalformedRequests() throws {
        let generic = try PushOpen.open(PushOpenRequest(api_version: 1, envelope: "not-an-envelope",
            keys: [PushOpenKey(host_id: "alpha", record_base64: "e30=")], recent: []))
        XCTAssertFalse(generic.opened)
        XCTAssertNotNil(generic.error)
        XCTAssertNil(generic.host_id)
        XCTAssertTrue(generic.deep_link.hasPrefix("verde://open"))
        XCTAssertFalse(generic.title.isEmpty)
        XCTAssertThrowsError(try PushOpen.open(PushOpenRequest(api_version: 2, envelope: "x", keys: [])))
    }
}

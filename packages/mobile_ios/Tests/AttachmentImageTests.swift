import XCTest
@testable import VerdeApp

final class AttachmentImageTests: XCTestCase {
    func testCacheNamingHidesIdsAndFollowsMime() {
        let key = attachmentKey(workspaceID: "ws", threadID: "t", messageID: "m", index: 0)
        let name = attachmentCacheName(key: key, mime: "image/png")
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertEqual(name.count, 64 + 4, "SHA-256 hex plus extension")
        XCTAssertFalse(name.contains("ws"))
        XCTAssertEqual(name, attachmentCacheName(key: key, mime: "image/png"), "stable")
        XCTAssertNotEqual(name, attachmentCacheName(key: attachmentKey(workspaceID: "ws", threadID: "t", messageID: "m", index: 1), mime: "image/png"))
        XCTAssertTrue(attachmentCacheName(key: key, mime: "image/jpeg").hasSuffix(".jpg"))
        XCTAssertTrue(attachmentCacheName(key: key, mime: "").hasSuffix(".jpg"))
    }

    func testViewDecodingAndCacheRoundTrip() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let ready = "{\"status\":\"ready\",\"mime\":\"image/png\",\"total_bytes\":\(png.count),\"data_base64\":\"\(png.base64EncodedString())\"}"
        let gone = "{\"status\":\"unavailable\",\"mime\":\"\",\"total_bytes\":0,\"error_code\":\"not_found\"}"
        let json = "{\"api_version\":1,\"revision\":\"1\",\"data\":{\"ws|t|m|0\":" + ready + ",\"ws|t|m|1\":" + gone + "}}"
        let view = decodeAttachmentsView(Data(json.utf8))
        XCTAssertEqual(view["ws|t|m|0"]?.status, "ready")
        XCTAssertEqual(view["ws|t|m|1"]?.error_code, "not_found")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AttachmentImageCache(directory: directory)
        let url = try XCTUnwrap(cache.store(png, key: "ws|t|m|0", mime: "image/png"))
        XCTAssertEqual(cache.file(for: "ws|t|m|0"), url)
        XCTAssertNotNil(cache.thumbnail(for: "ws|t|m|0", maxPixel: 64))
        XCTAssertNil(cache.file(for: "ws|t|m|9"))
        cache.clear()
        XCTAssertNil(cache.file(for: "ws|t|m|0"))
    }
}

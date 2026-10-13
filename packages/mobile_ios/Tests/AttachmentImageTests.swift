import XCTest
@testable import VerdeApp

final class AttachmentImageTests: XCTestCase {
    func testKeyFormatting() {
        XCTAssertEqual(attachmentKey(workspaceID: "ws", threadID: "t-1", messageID: "m9", index: 2), "ws|t-1|m9|2")
    }

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

    func testStatusToUI() {
        XCTAssertEqual(thumbnailPhase(status: nil, cached: false), .loading)
        XCTAssertEqual(thumbnailPhase(status: "loading", cached: false), .loading)
        XCTAssertEqual(thumbnailPhase(status: "ready", cached: false), .loading, "ready bytes still need caching")
        XCTAssertEqual(thumbnailPhase(status: "failed", cached: false), .unavailable)
        XCTAssertEqual(thumbnailPhase(status: "unavailable", cached: false), .unavailable)
        XCTAssertEqual(thumbnailPhase(status: "unavailable", cached: true), .image, "a cached image always shows")
    }

    func testThumbnailSizeKeepsAspect() {
        XCTAssertEqual(thumbnailSize(for: CGSize(width: 4000, height: 3000), longest: 160), CGSize(width: 160, height: 120))
        XCTAssertEqual(thumbnailSize(for: CGSize(width: 1000, height: 2000), longest: 160), CGSize(width: 80, height: 160))
        XCTAssertEqual(thumbnailSize(for: CGSize(width: 3000, height: 100), longest: 160).height, 48, "very wide images keep a tappable height")
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

    func testIntentFields() {
        let (type, fields) = AttachmentIntent.fetch(intentID: "i", workspaceID: "ws", threadID: "t", messageID: "m", index: 3)
        XCTAssertEqual(type, "attachment_fetch")
        if case .integer(let index)? = fields["index"] { XCTAssertEqual(index, 3) } else { XCTFail("index") }
        let (release, releaseFields) = AttachmentIntent.release(intentID: "i", key: "ws|t|m|3")
        XCTAssertEqual(release, "attachment_release")
        if case .string(let key)? = releaseFields["key"] { XCTAssertEqual(key, "ws|t|m|3") } else { XCTFail("key") }
    }
}

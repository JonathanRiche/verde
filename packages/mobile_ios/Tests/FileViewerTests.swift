import XCTest
@testable import VerdeApp

final class FileViewerTests: XCTestCase {
    func testKindsPathsAndUTF16CitationRange() {
        XCTAssertEqual(ViewerKind.of("/w/a.PDF"), .pdf)
        XCTAssertEqual(ViewerKind.of("/w/a.docx"), .office)
        XCTAssertEqual(ViewerKind.of("/w/a.md"), .markdown)
        XCTAssertEqual(ViewerKind.image.limit, 16 * 1024 * 1024)
        XCTAssertEqual(resolveFilePath("./a.swift", root: "/w/"), "/w/a.swift")
        XCTAssertNil(resolveFilePath("../secret", root: "/w"))
        XCTAssertNil(resolveFilePath("a", root: nil))
        XCTAssertEqual(fileLineRange("a😀\nsecond\nthird", line: 2, end: 3), NSRange(location: 4, length: 12))
        XCTAssertNil(fileLineRange("one", line: UInt64.max, end: nil))
    }
    func testFileBufferEvictsConsumesAndDiscardsLateCompletions() {
        let buffer = FileBuffer()
        for i in 0..<5 { buffer.put(String(i), FileBytes(data: Data([UInt8(i)]), mime: nil)) }
        XCTAssertNil(buffer.take("0"))
        XCTAssertEqual(buffer.take("1")?.data, Data([1]))
        XCTAssertNil(buffer.take("1"))
        buffer.discard("later")
        buffer.put("later", FileBytes(data: Data([9]), mime: nil))
        XCTAssertNil(buffer.take("later"))
        buffer.clear()
        XCTAssertNil(buffer.take("4"))
    }
    func testFileTransportKeepsBytesOutOfCoreAndRejectsOversize() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://bridge.invalid/api/file?path=/w/a"))
        let task = session.dataTask(with: url) // Never resumed.
        for (status, size) in [(200, 3), (403, 3), (200, 5)] {
            var events: [Event] = []; var received: FileBytes?
            let operation = SessionOperation(effect: .file_fetch(EffectFileFetch(effect_id: "file", generation: "2", intent_id: "intent", url: url.absoluteString, headers: [], timeout_ms: 1000, max_response_bytes: 4, tls: Tls(origin: "https://bridge.invalid", spki_sha256: "fixture"))), queue: DispatchQueue(label: "file.fixture"), emit: { events.append($0) }, fileReceived: { id, bytes in XCTAssertEqual(id, "intent"); received = bytes }, ended: {})
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/plain"]))
            operation.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
            operation.urlSession(session, dataTask: task, didReceive: Data(repeating: 42, count: size))
            operation.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(events.count, 1)
            guard case .http_response(let result) = events.first else { return XCTFail() }
            XCTAssertNil(result.body_base64); XCTAssertTrue(result.headers.isEmpty)
            if status == 200 && size <= 4 { XCTAssertEqual(received?.data.count, size); XCTAssertEqual(result.status, 200) }
            else { XCTAssertNil(received) }
            if size > 4 { XCTAssertEqual(result.error?.kind, .resource) }
        }
    }
    func testExplicitShareCopyIsProtectedAndRemoved() throws {
        let file = try SharedFile(Data("fixture".utf8), name: "a.txt")
        defer { file.remove() }
        XCTAssertEqual(try Data(contentsOf: file.url), Data("fixture".utf8))
        XCTAssertTrue(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testHostPaletteBoundsAndRGBA() throws {
        XCTAssertNil(HostPalette.components("#fffffffff"))
        XCTAssertNil(HostPalette.components("bad"))
        XCTAssertEqual(HostPalette.components("#11223380")?.3 ?? 0, 128.0 / 255, accuracy: 0.001)
        let palette = try JSONDecoder().decode(HostPalette.self, from: Data(##"{"colors":{"background":"#ffffffff","text":"#000000ff"},"reduced_motion":true}"##.utf8))
        XCTAssertFalse(palette.dark); XCTAssertNotNil(palette.color("text")); XCTAssertEqual(palette.reduced_motion, true)
    }
}

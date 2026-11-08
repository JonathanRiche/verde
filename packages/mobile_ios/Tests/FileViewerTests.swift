import XCTest
@testable import VerdeApp

final class FileViewerTests: XCTestCase {
    func testKindsPathsAndUTF16CitationRange() {
        XCTAssertEqual(ViewerKind.of("/w/a.PDF"), .pdf)
        XCTAssertEqual(ViewerKind.of("/w/a.docx"), .office)
        XCTAssertEqual(ViewerKind.of("/w/a.md"), .markdown)
        XCTAssertEqual(ViewerKind.image.limit, 32 * 1024 * 1024)
        XCTAssertEqual(ViewerKind.of("/w/find-your-chapter.SVG"), .svg)
        XCTAssertEqual(ViewerKind.svg.limit, 16 * 1024 * 1024)
        XCTAssertEqual(ViewerKind.of("/w/index.html"), .html)
        XCTAssertEqual(ViewerKind.fetchKind("/w/a.svg"), .download)
        for path in ["/w/index.html", "/w/a.htm", "/w/a.js", "/w/a.mjs", "/w/a.cjs", "/w/a.wasm"] { XCTAssertEqual(ViewerKind.fetchKind(path), ["html", "htm"].contains((path as NSString).pathExtension) ? .html : .download, path) }
        XCTAssertEqual(ViewerKind.fetchKind("/w/a.swift"), .file)
        XCTAssertEqual(ViewerKind.fetchKind("/w/a.png"), .file)
        XCTAssertEqual(ViewerKind.fetchKind("/w/a.docx"), .preview)
        XCTAssertEqual(resolveFilePath("./a.swift", root: "/w/"), "/w/a.swift")
        XCTAssertNil(resolveFilePath("../secret", root: "/w"))
        XCTAssertNil(resolveFilePath("a", root: nil))
        XCTAssertEqual(fileLineRange("a😀\nsecond\nthird", line: 2, end: 3), NSRange(location: 4, length: 12))
        XCTAssertNil(fileLineRange("one", line: UInt64.max, end: nil))
    }
    func testSVGPreviewIsInertAndProblemsMatchAndroid() {
        let html = svgPreviewHTML(Data("<svg><script>alert(1)</script></svg>".utf8))
        XCTAssertTrue(html.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'"))
        XCTAssertTrue(html.contains("<img alt=\"\" src=\"data:image/svg+xml;base64,"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertEqual(FileProblem.of("too_large", limit: 2 * 1024 * 1024).detail, "This file is over the 2 MB limit for viewing on the phone. Download it or open it on your computer.")
        XCTAssertEqual(FileProblem.of("unsupported", limit: 1).title, "No preview for this file type")
        XCTAssertEqual(FileProblem.of("timeout", limit: 1).title, "Host took too long")
        XCTAssertEqual(FileProblem.download("too_large", limit: ViewerKind.downloadLimit).title, "Too large to download")
        XCTAssertEqual(FileProblem.of(nil, limit: 1), .failed)
    }
    func testFileErrorsAndHTMLIsolation() {
        for code in ["connecting", "timeout", "cancelled", "busy", "server_unavailable", "too_large", "host_file_too_large", "unsupported", "forbidden", "identity", "unauthorized"] {
            XCTAssertNotEqual(FileProblem.of(code, limit: ViewerKind.downloadLimit).title, "Can't reach the host", code)
        }
        XCTAssertEqual(FileProblem.of("offline", limit: 1).title, "Can't reach the host")
        XCTAssertFalse(FileProblem.hostTooLarge.retryable)
        XCTAssertEqual(readFailure("timeout"), .problem(.of("timeout", limit: 0)))
        XCTAssertEqual(readFailure("cancelled"), .problem(.of("cancelled", limit: 0)))
        XCTAssertEqual(ViewerKind.of("a.M4A"), .audio)
        XCTAssertEqual(ViewerKind.fetchKind("a.mp3"), .audio)
        XCTAssertTrue(isolatedHTML("<body/>", textScale: 200).contains("-webkit-text-size-adjust:200%"))
        let html = isolatedHTML("<script>1</script>")
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("base-uri verde-preview:; form-action 'none'"))
        XCTAssertTrue(html.contains("<script>1</script>"))
    }
    func testPreviewPathsStayInsideTheirWorkspace() throws {
        let location = PreviewLocation(document: "/w/story/index.html", root: "/w")
        XCTAssertEqual(location.resolve(try XCTUnwrap(URL(string: "img/a%20b.png", relativeTo: location.url)?.absoluteURL)), "/w/story/img/a b.png")
        XCTAssertEqual(location.resolve(try XCTUnwrap(URL(string: "../font.ttf", relativeTo: location.url)?.absoluteURL)), "/w/font.ttf")
        for value in ["verde-preview://workspace/w/../../secret", "verde-preview://workspace/w2/x", "verde-preview://other/w/x", "file:///w/x", "https://example.com/w/x", "verde-preview://workspace/w/%2e%2e/secret"] {
            XCTAssertNil(location.resolve(try XCTUnwrap(URL(string: value))), value)
        }
        XCTAssertEqual(previewMime("style.css", reported: "application/octet-stream"), "text/css")
        XCTAssertEqual(previewMime("script.js", reported: nil), "text/javascript")
        XCTAssertEqual(previewMime("audio.mp3", reported: nil), "audio/mpeg")
        XCTAssertTrue(isolatedHTML("<body/>").contains("linked files couldn't load"))
        XCTAssertFalse(isolatedHTML("<body/>").contains("Linked files aren't loaded"))
    }
    func testPreviewStreamForwardsChunksWithoutCoreBodiesOrByteCaps() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://preview.invalid/api/file"))
        let task = session.dataTask(with: url)
        var bytes = 0, finished = false
        let stream = HTTPStream(response: { XCTAssertEqual($0.statusCode, 206); XCTAssertEqual($0.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/6") },
                                data: { bytes += $0.count }, complete: { XCTAssertNil($0); finished = true })
        let operation = SessionOperation(effect: .http_request(EffectHttpRequest(effect_id: "stream", generation: "1", method: "GET", url: url.absoluteString, headers: [], body_base64: nil, timeout_ms: 3000, max_response_bytes: 1, tls: Tls(origin: "https://preview.invalid", spki_sha256: "fixture"))), queue: DispatchQueue(label: "stream.test"), emit: { _ in XCTFail("Stream must not emit core bodies") }, stream: stream, ended: {})
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range":"bytes 2-5/6", "Content-Length":"4"]))
        operation.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        operation.urlSession(session, dataTask: task, didReceive: Data([1, 2]))
        operation.urlSession(session, dataTask: task, didReceive: Data([3, 4]))
        operation.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(bytes, 4); XCTAssertTrue(finished)
    }
    func testDownloadSpoolsMoreThan32MBAndDeletesItsPrivateCopy() throws {
        var received: FileBytes?
        var events: [Event] = []
        let effect = EffectFileFetch(effect_id: "disk", generation: "1", intent_id: "disk", url: "https://bridge.invalid/api/file?download=1&path=/w/file.bin", headers: [], timeout_ms: 3000, max_response_bytes: 0, tls: Tls(origin: "https://bridge.invalid", spki_sha256: "fixture"))
        let operation = SessionOperation(effect: .file_fetch(effect), queue: DispatchQueue(label: "stream.test"), emit: { events.append($0) }, fileReceived: { _, file in received = file }, ended: {})
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: effect.url))
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "34603008"]))
        operation.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        let chunk = Data(repeating: 42, count: 64 * 1024)
        for _ in 0..<528 { operation.urlSession(session, dataTask: task, didReceive: chunk) }
        operation.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(received?.size, 34_603_008)
        let file = try XCTUnwrap(received?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        guard case .http_response(let result) = events.first else { return XCTFail() }
        XCTAssertNil(result.body_base64)
        received = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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
}

import SwiftUI
import XCTest
@testable import VerdeApp

private typealias Fg = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
private typealias LinkKey = AttributeScopes.FoundationAttributes.LinkAttribute

/// Pure transcript rules over real K-11 core render results (shared Android fixtures, d06/README.md).
final class TranscriptRulesTests: XCTestCase {
    func testSelectorsOffsetsAndLinkSafety() throws {
        XCTAssertEqual(chatSelector("thread", chatWS, chatThread), "thread:%5B%22chat-fixture-ws%22%2C%22chat-fixture-thread%22%5D")
        XCTAssertEqual(chatSelector("composer", "a b", "é"), "composer:%5B%22a%20b%22%2C%22%C3%A9%22%5D")
        // UTF-8 byte offsets → UTF-16 indices across 1-, 2-, 3- and 4-byte characters.
        XCTAssertEqual(utf8ToUtf16("aé世😀"), [0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 5])
        let spans = [RenderSpan(start: 3, end: 6, kind: "keyword"), RenderSpan(start: 6, end: 99, kind: "string")]
        XCTAssertEqual(highlightRanges("aé世😀", spans).map { [$0.start, $0.end] }, [[2, 3], [3, 5]])
        let styled = highlighted("aé世😀", spans)
        XCTAssertEqual(String(styled.characters), "aé世😀")
        XCTAssertEqual(styled.runs.filter { $0[Fg.self] != nil }.count, 2)
        XCTAssertEqual(safeLinkUrl("https://x.dev")?.absoluteString, "https://x.dev")
        XCTAssertNil(safeLinkUrl("javascript:alert(1)"))
        XCTAssertNil(safeLinkUrl("/relative"))

        // Recorded core markdown → blocks: citations become private links, web links only for admitted schemes.
        let rich = try XCTUnwrap(SharedFixtures.thread("d06", "thread-rich").data)
        let assistant = try XCTUnwrap(rich.rows.first { $0.id == "rich-assistant" })
        let reply = try XCTUnwrap(RecordedRenders.result("markdown", assistant.body))
        let nodes = try XCTUnwrap(try JSONDecoder().decode(MarkdownQuery.self, from: reply).data?.nodes)
        let blocks = markdownBlocks(nodes)
        guard case .paragraph(let paragraph) = blocks[1] else { return XCTFail("paragraph") }
        let links = paragraph.runs.compactMap { $0[LinkKey.self] }
        let cited = try XCTUnwrap(links.compactMap(citation(from:)).first)
        XCTAssertEqual(cited.path, "/tmp/rich-project/src/main.zig")
        XCTAssertEqual(cited.line, 42)
        XCTAssertEqual(links.filter { $0.scheme == "https" }.map(\.absoluteString), ["https://ziglang.org/documentation/"])
    }
}

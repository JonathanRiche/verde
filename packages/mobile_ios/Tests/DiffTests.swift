import CryptoKit
import XCTest
@testable import VerdeApp

/// Serves only recorded core replies (d07/render.json, keyed by the SHA-256 of the query text);
/// any query outside the recording is recorded as a miss and fails the test.
@MainActor
private final class RecordedSource: DiffRenderSource {
    private var results: [String: Data] = [:]
    private(set) var queries = 0
    private(set) var misses: [String] = []

    init(_ entries: [[String: Any]]) {
        for entry in entries {
            guard let query = entry["query"] as? [String: Any], let kind = query["kind"] as? String,
                  let sha = query["sha256"] as? String, let result = entry["result"],
                  let data = try? JSONSerialization.data(withJSONObject: result) else { continue }
            results[Self.key(kind, sha, query["language"] as? String)] = data
        }
    }

    private static func key(_ kind: String, _ sha: String, _ language: String?) -> String { "\(kind)/\(sha)/\(language ?? "")" }
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func result(_ kind: String, _ text: String, _ language: String? = nil) -> Data? {
        queries += 1
        if let data = results[Self.key(kind, Self.sha(text), language)] { return data }
        misses.append("\(kind)/\(language ?? "")")
        return nil
    }

    func cachedIndex(_ body: String) -> RenderResult<DiffIndexView>? { nil }
    func index(_ body: String) async -> RenderResult<DiffIndexView> {
        RenderResult(result("diff_index", body).flatMap { try? JSONDecoder().decode(DiffIndexQuery.self, from: $0).data })
    }
    func cachedDiff(_ text: String) -> RenderResult<DiffView>? { nil }
    func diff(_ text: String) async -> RenderResult<DiffView> {
        RenderResult(result("diff", text).flatMap { try? JSONDecoder().decode(DiffQuery.self, from: $0).data })
    }
    func cachedHighlight(_ code: String, language: String) -> RenderResult<[RenderSpan]>? { nil }
    func highlight(_ code: String, language: String) async -> RenderResult<[RenderSpan]> {
        RenderResult(result("highlight", code, language).flatMap { try? JSONDecoder().decode(HighlightQuery.self, from: $0).data?.spans })
    }
}

/// D-07 / I-05 diff rows over real K-11 core results (shared Android fixtures, d07/README.md):
/// golden unified-row projections byte-identical to Android's, file records, copies and fallbacks.
@MainActor
final class DiffTests: XCTestCase {
    private lazy var source = RecordedSource(SharedFixtures.json("d07", "render.json"))
    private lazy var multi = SharedFixtures.text("d07", "multi.diff")

    private func assertGolden(_ name: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
        func trimmed(_ s: String) -> String { var s = s; while s.hasSuffix("\n") { s.removeLast() }; return s }
        XCTAssertEqual(trimmed(actual), trimmed(SharedFixtures.text("d07", name)), name, file: file, line: line)
    }

    private func entries(_ body: String) async throws -> [DiffIndexEntry] {
        let index = await source.index(body).value
        return try XCTUnwrap(index).files
    }

    private func render(_ body: String, _ path: String) async throws -> DiffFileRender {
        let files = try await entries(body)
        let entry = try XCTUnwrap(files.first { $0.path == path })
        let record = try XCTUnwrap(DiffBody(body).record(entry))
        return await renderDiffFile(source, record, path: entry.path)
    }

    private func parsed(_ path: String) async throws -> DiffFileModel {
        guard case .parsed(let model) = try await render(multi, path) else { XCTFail("\(path) not parsed"); throw CancellationError() }
        return model
    }

    func testCoreGoldenFixtureProjectsToUnifiedRows() async throws {
        // The K-11 core golden (client_core/src/fixtures/render-diff.json), word spans intact.
        let core = try JSONDecoder().decode(DiffView.self, from: SharedFixtures.data("d07", "core-render-diff.json"))
        let file = try XCTUnwrap(core.files.first)
        assertGolden("core-golden.txt", diffGolden(diffFileModel(binary: false, file.hunks, oldSpans: [], newSpans: [])))
        // The same patch as a one-file V2 body goes through index → record → diff → highlight.
        guard case .parsed(let model) = try await render(SharedFixtures.text("d07", "golden.diff"), "x.ts") else {
            return XCTFail("x.ts not parsed")
        }
        assertGolden("x-ts.golden.txt", diffGolden(model))
        XCTAssertEqual(source.misses, [])
    }

    func testMultiFileGoldensUseCoreParseAndHighlightSpans() async throws {
        let index = try await entries(multi)
        XCTAssertEqual(index.map(\.path), ["web/src/greet.ts", "config/settings.json", "assets/logo.png", "scripts/run.sh",
                                           "notes/big.txt", "data/huge.txt"])
        let totals = diffTotals(index)
        XCTAssertEqual([totals.additions, totals.deletions], [4657, 2])
        // Tabs expand to the column grid; emoji and word spans map from UTF-8 bytes to UTF-16.
        assertGolden("greet-ts.golden.txt", diffGolden(try await parsed("web/src/greet.ts")))
        assertGolden("settings-json.golden.txt", diffGolden(try await parsed("config/settings.json")))
        let logo = try await parsed("assets/logo.png")
        XCTAssertTrue(logo.binary)
        let run = try await parsed("scripts/run.sh")
        XCTAssertTrue(run.hunks.isEmpty)
        let big = try await parsed("notes/big.txt")
        XCTAssertEqual(big.lineCount, 450)
        // Past the core's per-patch budget: the source text, never a Swift parse.
        guard case .source(let patch) = try await render(multi, "data/huge.txt") else { return XCTFail("huge.txt should fall back") }
        XCTAssertTrue(patch.hasPrefix("--- /dev/null\n+++ b/data/huge.txt\n@@ -0,0 +1,4200 @@\n+generated row 00001\n"))
        XCTAssertEqual(source.misses, [])
    }

    func testCopiedHunksAreTheOriginalUnifiedFragments() async throws {
        let greet = try await parsed("web/src/greet.ts")
        XCTAssertEqual(greet.hunks.map(\.header), ["@@ -1,5 +1,6 @@", "@@ -20,3 +21,3 @@"])
        let files = try await entries(multi)
        let first = try XCTUnwrap(files.first)
        let patch = try XCTUnwrap(DiffBody(multi).record(first)).patch
        XCTAssertTrue(patch.hasPrefix("--- a/web/src/greet.ts\n"))
        XCTAssertTrue(patch.hasSuffix(hunkPatch(greet.hunks[1])))
        XCTAssertEqual(hunkPatch(greet.hunks[0]),
                       "@@ -1,5 +1,6 @@\n import { name } from './name';\n-export function greet(who: string) {\n+export function greet(who: string, loud = false) {\n \tconst text = `hello ${who} 😀`;\n+\tif (loud) return text.toUpperCase();\n \treturn text;\n }\n")
        XCTAssertEqual(hunkPatch(greet.hunks[1]),
                       "@@ -20,3 +21,3 @@\n /* greeting table */\n-const table = { en: 'hello', fr: 'bonjour' };\n+const table = { en: 'hello', fr: 'salut' };\n export default table;\n\\ No newline at end of file\n")
        // Gutter: right-aligned numbers and the sign; display rows keep the tab grid.
        let row = greet.hunks[0].rows[3]
        XCTAssertEqual(row.raw, "\tconst text = `hello ${who} 😀`;")
        XCTAssertTrue(row.text.hasPrefix("    const"))
        XCTAssertEqual(diffGutter(row, width: greet.numberWidth), " 3  3   ")
        XCTAssertEqual(source.misses, [])
    }

    func testUndecodableBodyAndLanguages() async throws {
        let broken = await source.index("VERDE_DIFF_V2\nFILE\tbroken")
        XCTAssertNil(broken.value)
        XCTAssertEqual(diffLanguage("web/src/greet.ts"), "ts")
        XCTAssertEqual(diffLanguage("a/B.JSON"), "json")
        XCTAssertEqual(diffLanguage("x.tsx"), "tsx")
        XCTAssertNil(diffLanguage("Makefile"))
        XCTAssertNil(diffLanguage("run.sh"))
    }
}

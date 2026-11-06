import XCTest
@testable import VerdeApp

/// S5: resolved chip values, current picker choice, de-duplicated suggestions, prompt bounds.
final class ComposerChipsTests: XCTestCase {
    private let access = [ChatChoice(id: "supervised", label: "Supervised"), ChatChoice(id: "full_access", label: "Full access")]

    func testAccessChipShowsTheResolvedValue() {
        XCTAssertEqual(composerAccessLabel(access, value: "supervised"), "Supervised")
        XCTAssertEqual(composerAccessLabel(access, value: "full_access"), "Full access")
        XCTAssertEqual(composerAccessLabel(access, value: nil), "Default · Full access")
        XCTAssertEqual(composerCurrentChoice(.access, value: nil), "full_access")
        XCTAssertEqual(composerCurrentChoice(.effort, value: nil), "")
        XCTAssertEqual(composerCurrentChoice(.model, value: "opus"), "opus")
        let models = [ChatChoice(id: "default", label: "Default"), ChatChoice(id: "opus", label: "Opus 5.5")]
        XCTAssertEqual(composerCurrentChoice(.model, value: nil, choices: models), "default")
        XCTAssertEqual(composerCurrentChoice(.speed, value: nil, choices: [ChatChoice(id: "off", label: "Off")]), "")
        XCTAssertEqual(composerCurrentChoice(.effort, value: nil, choices: [ChatChoice(id: "", label: "Default"), ChatChoice(id: "low", label: "Low")]), "")
    }

    func testChipsShowResolvedValues() {
        let models = [ChatChoice(id: "opus", label: "Opus 5.5"), ChatChoice(id: "haiku", label: "Haiku 5.5")]
        XCTAssertEqual(composerModelLabel(models, value: nil), "Opus 5.5")
        XCTAssertEqual(composerModelLabel(models, value: "haiku"), "Haiku 5.5")
        XCTAssertEqual(composerModelLabel([], value: nil), "Default")
        XCTAssertEqual(composerResolvedAccess(access, value: nil), "Full access")
        XCTAssertEqual(composerResolvedAccess(access, value: "supervised"), "Supervised")
    }

    func testSlashSuggestionsAreOneDeduplicatedList() {
        let slash = [ChatChoice(id: "usage", label: "/usage"), ChatChoice(id: "code-review", label: "/code-review"),
                     ChatChoice(id: "code-review", label: "/code-review"), ChatChoice(id: "code-review-2", label: "/code-review")]
        let all = composerSuggestions(ComposerToken(range: NSRange(location: 0, length: 1), query: "", marker: "/"), mentions: [], slash: slash)
        XCTAssertEqual(all.map(\.label), ["/usage", "/code-review"])
        let filtered = composerSuggestions(ComposerToken(range: NSRange(location: 0, length: 4), query: "rev", marker: "/"), mentions: [], slash: slash)
        XCTAssertEqual(filtered.map(\.id), ["code-review"])
        let files = composerSuggestions(ComposerToken(range: NSRange(location: 0, length: 4), query: "rec", marker: "@"),
                                        mentions: [ChatMention(path: "src/reconnect.ts", label: "reconnect.ts"),
                                                   ChatMention(path: "src/reconnect.ts", label: "reconnect.ts")], slash: [])
        XCTAssertEqual(files.map(\.value), ["src/reconnect.ts"])
        XCTAssertEqual(files.first?.detail, "src")
    }

    func testPromptHeightKeepsAScaledMinimum() {
        XCTAssertEqual(composerPromptHeight(10, available: 800), 56)
        XCTAssertEqual(composerPromptHeight(10, available: 800, minimum: 90), 90)
        XCTAssertEqual(composerPromptHeight(2000, available: 800, minimum: 90), 480)
    }
}

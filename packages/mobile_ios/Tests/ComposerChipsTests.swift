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

    func testFileSuggestionsMatchTheQuery() {
        let all = [ChatMention(path: "README.md", label: "README.md"), ChatMention(path: "src/reconnect.ts", label: "reconnect.ts"),
                   ChatMention(path: "docs/CHANGELOG.md", label: "CHANGELOG.md"), ChatMention(path: "src/theme.ts", label: "theme.ts"),
                   ChatMention(path: "tests/reconnect.test.ts", label: "reconnect.test.ts"), ChatMention(path: "src/r_e_c.ts", label: "r_e_c.ts")]
        XCTAssertEqual(rankedMentions(all, query: "rec").map(\.label), ["reconnect.ts", "reconnect.test.ts", "r_e_c.ts"])
        XCTAssertEqual(rankedMentions(all, query: "").count, all.count)
    }

    func testChipsDropTheDefaultPrefix() {
        let models = [ChatChoice(id: "default", label: "Default"), ChatChoice(id: "opus", label: "Opus 5.5")]
        XCTAssertEqual(composerResolvedModel(models, value: nil, defaultLabel: "Opus 5.5"), "Opus 5.5")
        XCTAssertEqual(composerResolvedModel(models, value: nil, defaultLabel: nil), "Default")
        XCTAssertEqual(composerResolvedEffort([ChatChoice(id: "", label: "Default")], value: nil, defaultLabel: "High"), "High")
    }

    func testLongChipLabelsAreCut() {
        XCTAssertEqual(chipDisplay("Opus 5.5", limit: 22), "Opus 5.5")
        XCTAssertEqual(chipDisplay("Opus 5.5 (1M context) preview", limit: 10), "Opus 5.5 …")
    }

    func testChipsShowResolvedValues() {
        let models = [ChatChoice(id: "opus", label: "Opus 5.5"), ChatChoice(id: "haiku", label: "Haiku 5.5")]
        XCTAssertEqual(composerModelLabel(models, value: nil), "Opus 5.5")
        XCTAssertEqual(composerModelLabel(models, value: "haiku"), "Haiku 5.5")
        XCTAssertEqual(composerModelLabel([], value: nil), "Default")
        let withDefault = [ChatChoice(id: "default", label: "Default"), ChatChoice(id: "opus", label: "Opus 5.5")]
        XCTAssertEqual(composerModelLabel(withDefault, value: nil, defaultLabel: "Opus 5.5"), "Default · Opus 5.5")
        XCTAssertEqual(composerModelLabel(withDefault, value: "default", defaultLabel: nil), "Default")
        XCTAssertEqual(composerModelLabel(withDefault, value: "opus", defaultLabel: "Opus 5.5"), "Opus 5.5")
        let efforts = [ChatChoice(id: "", label: "Default"), ChatChoice(id: "high", label: "High")]
        XCTAssertEqual(composerEffortLabel(efforts, value: nil, defaultLabel: nil), "Default")
        XCTAssertEqual(composerEffortLabel(efforts, value: "", defaultLabel: "Medium"), "Default · Medium")
        XCTAssertEqual(composerEffortLabel(efforts, value: "high"), "High")
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

/// I7-1: the chip layout is a pure function of the widths.
final class ComposerChipPlanTests: XCTestCase {
    private let chips = [ComposerChipWidth(kind: .model, full: 110, iconOnly: nil),
                         ComposerChipWidth(kind: .effort, full: 90, iconOnly: 44),
                         ComposerChipWidth(kind: .speed, full: 90, iconOnly: 44),
                         ComposerChipWidth(kind: .access, full: 110, iconOnly: 44)]

    func testOneRowWhileItFits() {
        XCTAssertEqual(composerChipPlan(widths: chips, available: 500), ComposerChipPlan(first: [.model, .effort, .speed, .access]))
        let tight = composerChipPlan(widths: chips, available: 350)
        XCTAssertFalse(tight.twoRows)
        XCTAssertEqual(tight.icons, [.access, .speed])
        XCTAssertEqual(composerChipPlan(widths: chips, available: 305).icons, [.access, .speed, .effort])
    }

    func testLargeTextPutsTheModelOnItsOwnRow() {
        let plan = composerChipPlan(widths: chips, available: 200)
        XCTAssertTrue(plan.twoRows)
        XCTAssertEqual(plan.first, [.model])
        XCTAssertEqual(plan.second, [.effort, .speed, .access])
        XCTAssertEqual(composerChipPlan(widths: chips, available: 200), plan, "same input, same layout")
    }
}

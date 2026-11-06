import XCTest
@testable import VerdeApp

/// S5: resolved chip values, current picker choice, de-duplicated suggestions, prompt bounds.
final class ComposerChipsTests: XCTestCase {
    private let access = [ChatChoice(id: "supervised", label: "Supervised"), ChatChoice(id: "full_access", label: "Full access")]

    func testAccessChipShowsTheResolvedValue() {
        XCTAssertEqual(composerAccessLabel(access, value: "supervised"), "Supervised")
        XCTAssertEqual(composerAccessLabel(access, value: "full_access"), "Full access")
        XCTAssertEqual(composerAccessLabel(access, value: nil), "Full access")
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
        XCTAssertEqual(composerResolvedModel(models, value: nil, defaultLabel: nil), "Auto")
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
        XCTAssertEqual(composerModelLabel([], value: nil), "Auto")
        let withDefault = [ChatChoice(id: "default", label: "Default"), ChatChoice(id: "opus", label: "Opus 5.5")]
        XCTAssertEqual(composerModelLabel(withDefault, value: nil, defaultLabel: "Opus 5.5"), "Opus 5.5")
        XCTAssertEqual(composerModelLabel(withDefault, value: "default", defaultLabel: nil), "Auto")
        XCTAssertEqual(composerPickerLabel(.model, withDefault[0], defaultModel: "Opus 5.5"), "Opus 5.5 (default)")
        XCTAssertEqual(composerPickerLabel(.speed, ChatChoice(id: "off", label: "Normal")), "Standard (default)")
        XCTAssertEqual(composerPickerLabel(.speed, ChatChoice(id: "on", label: "Fast")), "Fast")
        XCTAssertEqual(composerPickerLabel(.access, access[1]), "Full access (default)")
        XCTAssertEqual(composerPickerLabel(.effort, ChatChoice(id: "", label: "Default")), "Auto")
        XCTAssertEqual(composerSpeedLabel(nil), "Standard")
        XCTAssertEqual(composerModelLabel(withDefault, value: "opus", defaultLabel: "Opus 5.5"), "Opus 5.5")
        let efforts = [ChatChoice(id: "", label: "Default"), ChatChoice(id: "high", label: "High")]
        XCTAssertEqual(composerEffortLabel(efforts, value: nil, defaultLabel: nil), "Auto")
        XCTAssertEqual(composerEffortLabel(efforts, value: "", defaultLabel: "Medium"), "Auto · Medium")
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
        XCTAssertEqual(composerPromptHeight(2000, available: 800, minimum: 90), 320, "40% of the height at most")
    }
}

/// I7-1 / S25: the chip layout is a pure function of the widths.
final class ComposerChipPlanTests: XCTestCase {
    private let chips = [ComposerChipWidth(kind: .model, full: 110, iconOnly: nil, minimum: 70),
                         ComposerChipWidth(kind: .effort, full: 90, iconOnly: 44, short: 70, bare: 48),
                         ComposerChipWidth(kind: .speed, full: 90, iconOnly: 44, short: 66, bare: 44),
                         ComposerChipWidth(kind: .access, full: 110, iconOnly: 44, short: 66, bare: 44)]

    func testLabelsShortenBeforeTheyDisappear() {
        // 44 + 114 + 94 + 94 + 114 = 460
        XCTAssertEqual(composerChipPlan(widths: chips, available: 460), ComposerChipPlan(first: [.model, .effort, .speed, .access]))
        // Short labels: 44 + 114 + 74 + 70 + 70 = 372
        XCTAssertEqual(composerChipPlan(widths: chips, available: 372).short, [.effort, .speed, .access])
        // Then the model truncates (minimum 70) before any label goes.
        let truncated = composerChipPlan(widths: chips, available: 340)
        XCTAssertEqual(truncated.short, [.effort, .speed, .access])
        XCTAssertEqual(truncated.modelCap, 340 - (44 + 74 + 70 + 70) - 4)
        XCTAssertTrue(truncated.icons.isEmpty)
        // Then the effort and access glyphs go (the labels stay), then the speed glyph.
        let bare = composerChipPlan(widths: chips, available: 300)
        XCTAssertEqual(bare.short, [.effort, .speed, .access])
        XCTAssertEqual(bare.bare, [.effort, .access])
        XCTAssertTrue(bare.icons.isEmpty)
        // 44 + 4 + 70 (minimum) + 52 + 48 + 48 = 266
        XCTAssertEqual(composerChipPlan(widths: chips, available: 266).bare, [.effort, .speed, .access])
        // Only below that do the icons alone remain.
        let icons = composerChipPlan(widths: chips, available: 264)
        XCTAssertEqual(icons.icons, [.effort, .speed, .access])
        XCTAssertFalse(icons.twoRows)
    }

    func testLargeTextPutsTheModelOnItsOwnRow() {
        let plan = composerChipPlan(widths: chips, available: 180)
        XCTAssertTrue(plan.twoRows)
        XCTAssertEqual(plan.first, [.model])
        XCTAssertEqual(plan.second, [.effort, .speed, .access])
        XCTAssertEqual(composerChipPlan(widths: chips, available: 180), plan, "same input, same layout")
    }

    func testShortLabelTable() {
        XCTAssertEqual(composerShortLabel(.effort, id: "", label: "Default"), "Auto")
        XCTAssertEqual(composerShortLabel(.effort, id: "medium", label: "Medium"), "Med")
        XCTAssertEqual(composerShortLabel(.speed, id: "off", label: "Normal"), "Std")
        XCTAssertEqual(composerShortLabel(.speed, id: "on", label: "Fast"), "Fast")
        XCTAssertEqual(composerShortLabel(.access, id: "supervised", label: "Supervised"), "Ask")
        XCTAssertEqual(composerShortLabel(.access, id: "full_access", label: "Full access"), "Full")
    }
}

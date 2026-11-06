import XCTest
import SwiftUI
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
        XCTAssertEqual(composerPickerLabel(.model, withDefault[0], defaultModel: "Opus 5.5"), "Default (Opus 5.5)")
        XCTAssertEqual(composerPickerLabel(.model, withDefault[0], defaultModel: nil), "Default")
        XCTAssertEqual(composerPickerLabel(.model, withDefault[1], defaultModel: "Opus 5.5"), "Opus 5.5")
        XCTAssertEqual(newChatMenuLabel("Model", withDefault[0], defaultModel: "Opus 5.5"), "Default (Opus 5.5)")
        XCTAssertEqual(composerPickerLabel(.speed, ChatChoice(id: "off", label: "Normal")), "Standard (default)")
        XCTAssertEqual(composerPickerLabel(.speed, ChatChoice(id: "on", label: "Fast")), "Fast")
        XCTAssertEqual(composerPickerLabel(.access, access[1]), "Full access (default)")
        XCTAssertEqual(composerPickerLabel(.effort, ChatChoice(id: "", label: "Default")), "Auto (default)")
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

/// I7-1 / S25 / S31: the chip layout is a pure function of the widths; every chip keeps its
/// glyph and a label, and the row wraps rather than dropping either.
final class ComposerChipPlanTests: XCTestCase {
    private let chips = [ComposerChipWidth(kind: .model, full: 110, minimum: 70),
                         ComposerChipWidth(kind: .effort, full: 90, short: 70),
                         ComposerChipWidth(kind: .speed, full: 90, short: 66),
                         ComposerChipWidth(kind: .access, full: 110, short: 66)]

    func testLabelsShortenThenTheModelTruncatesThenTheRowWraps() {
        // Always the short labels: 44 + 114 + 74 + 70 + 70 = 372
        XCTAssertEqual(composerChipPlan(widths: chips, available: 460), ComposerChipPlan(rows: [[.model, .effort, .speed, .access]], short: [.effort, .speed, .access]))
        XCTAssertEqual(composerChipPlan(widths: chips, available: 372).short, [.effort, .speed, .access])
        XCTAssertNil(composerChipPlan(widths: chips, available: 372).modelCap)
        let truncated = composerChipPlan(widths: chips, available: 340)
        XCTAssertEqual(truncated.rows, [[.model, .effort, .speed, .access]])
        XCTAssertEqual(truncated.modelCap, 340 - (44 + 74 + 70 + 70) - 4)
        // Below that the chips wrap in order; nothing becomes icon-only.
        XCTAssertEqual(composerChipPlan(widths: chips, available: 300).rows, [[.model, .effort], [.speed, .access]])
    }

    func testLargeTextWrapsOntoMoreRows() {
        let plan = composerChipPlan(widths: chips, available: 180)
        XCTAssertEqual(plan.rows, [[.model], [.effort, .speed], [.access]])
        XCTAssertEqual(composerChipPlan(widths: chips, available: 180), plan, "same input, same layout")
        // A model wider than the room beside the paperclip truncates on the first row.
        XCTAssertEqual(composerChipPlan(widths: chips, available: 120).modelCap, 72)
    }

    /// S31: Claude and Codex at large, XXL and AX-L on a 402-point phone. The width doesn't depend
    /// on the turn, so idle and Steer get the same plan.
    func testRealChipsKeepEveryLabelAtEverySize() {
        let claude = [ComposerChipText(kind: .model, full: "Opus 5.5"),
                      ComposerChipText(kind: .effort, full: "Auto", short: "Auto"),
                      ComposerChipText(kind: .access, full: "Full access", short: "Full")]
        let codex = [ComposerChipText(kind: .model, full: "GPT-6.1 Sol"),
                     ComposerChipText(kind: .effort, full: "Auto", short: "Auto"),
                     ComposerChipText(kind: .speed, full: "Standard", short: "Std"),
                     ComposerChipText(kind: .access, full: "Full access", short: "Full")]
        let available = composerChipRowWidth(402)
        for size in [DynamicTypeSize.large, .xxLarge, .accessibility3] {
            for chips in [claude, codex] {
                let widths = composerChipWidths(chips, size: size)
                let idle = composerChipPlan(widths: widths, available: available)
                let steer = composerChipPlan(widths: widths, available: composerChipRowWidth(402))
                XCTAssertEqual(idle, steer)
                XCTAssertEqual(idle.all, chips.map(\.kind), "every chip once, in order, at \(size)")
                for (index, row) in idle.rows.enumerated() {
                    let used = row.reduce(index == 0 ? composerAttachWidth : -composerChipSpacing) { sum, kind in
                        let chip = widths.first { $0.kind == kind }!
                        let width = kind == .model ? min(chip.full, idle.modelCap ?? chip.full) : (idle.short.contains(kind) ? chip.short ?? chip.full : chip.full)
                        return sum + composerChipSpacing + width
                    }
                    XCTAssertLessThanOrEqual(used, available + 0.5, "row \(index) fits at \(size)")
                }
            }
            if size == .large {
                XCTAssertFalse(composerChipPlan(widths: composerChipWidths(claude, size: size), available: available).twoRows, "Claude is one row at 1.0x")
                XCTAssertFalse(composerChipPlan(widths: composerChipWidths(codex, size: size), available: available).twoRows, "Codex is one row at 1.0x")
            }
        }
    }

    func testSwatchesHaveNames() {
        let names = workspaceColorNames(accent: (0.11, 0.49, 0.29))
        XCTAssertEqual(names.count, 8)
        XCTAssertEqual(Set(names).count, 8, "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("Color") })
        XCTAssertEqual(newChatMenuLabel("Effort", ChatChoice(id: "", label: "Default")), "Auto (default)")
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

/// Multi-select attach: what fits under the per-message limit, and Android's notice for the rest.
final class ComposerImageLimitTests: XCTestCase {
    func testPicksFillTheRoomLeftAndFlagTheRest() {
        // The host's limit (attachment_protocol.zig MAX_ATTACHMENTS_PER_TURN).
        XCTAssertEqual(ComposerModel.maxImages, 16)
        XCTAssertTrue(composerImagesThatFit(picked: 3, existing: 0) == (3, false))
        XCTAssertTrue(composerImagesThatFit(picked: 16, existing: 0) == (16, false))
        XCTAssertTrue(composerImagesThatFit(picked: 20, existing: 0) == (16, true))
        XCTAssertTrue(composerImagesThatFit(picked: 5, existing: 14) == (2, true))
        XCTAssertTrue(composerImagesThatFit(picked: 1, existing: 16) == (0, true))
        XCTAssertTrue(composerImagesThatFit(picked: 0, existing: 1) == (0, false))
        XCTAssertTrue(composerImagesThatFit(picked: 3, existing: 2, max: 4) == (2, true))
        XCTAssertEqual(composerImageLimitNotice, "Up to 16 images per message.")
    }
}

import XCTest
@testable import VerdeApp

final class SettingsTests: XCTestCase {
    func testThemeHelpDescribesTheCurrentChoice() {
        XCTAssertTrue(themeHelpText(.system).hasPrefix("System follows"))
        XCTAssertTrue(themeHelpText(.dark).hasPrefix("Dark keeps"))
        XCTAssertTrue(themeHelpText(.host).contains("computer"))
        // A preset names itself instead of describing System.
        let preset = themeHelpText(.tokyoNight)
        XCTAssertFalse(preset.hasPrefix("System"), preset)
        XCTAssertTrue(preset.contains(AppearanceMode.tokyoNight.label), preset)
    }

    func testVersionLabel() {
        XCTAssertEqual(appVersionLabel(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"]), "0.1.0 (7)")
        XCTAssertEqual(appVersionLabel(["CFBundleShortVersionString": "0.1.0"]), "0.1.0")
        XCTAssertEqual(appVersionLabel(nil), "?")
    }
}

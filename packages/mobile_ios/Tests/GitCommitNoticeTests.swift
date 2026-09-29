import XCTest
@testable import VerdeApp

final class GitCommitNoticeTests: XCTestCase {
    func testLegacyOneLineNotice() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234"))
        XCTAssertEqual(notice.title, "Committed 1 file")
        XCTAssertEqual(notice.revisions, "abc1234")
        XCTAssertFalse(notice.pushed); XCTAssertNil(notice.subject); XCTAssertNil(notice.branch)
    }
    func testMultipleReposSubjectBranchAndPush() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 3 files: abc1234 (app), def5678 (lib) · pushed\nImprove fixture\nbranch feature/fixture"))
        XCTAssertEqual(notice.title, "Committed 3 files")
        XCTAssertEqual(notice.revisions, "abc1234 (app), def5678 (lib)")
        XCTAssertTrue(notice.pushed)
        XCTAssertEqual(notice.subject, "Improve fixture")
        XCTAssertEqual(notice.branch, "feature/fixture")
    }
    func testMissingOptionalLinesAndUnknownFormat() throws {
        XCTAssertNil(GitCommitNotice.parse("Commit failed"))
        XCTAssertNil(GitCommitNotice.parse("Committed 1 file: unknown"))
        XCTAssertNil(GitCommitNotice.parse("Committed many files: abc1234"))
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 2 files: abc1234\n\nbranch main"))
        XCTAssertNil(notice.subject); XCTAssertEqual(notice.branch, "main")
    }
}

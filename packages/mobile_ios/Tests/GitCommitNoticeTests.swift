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
        XCTAssertEqual(notice.title, "Committed & pushed 3 files")
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
    func testPositionalRemoteLinksValidateAndDeduplicateURLs() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234 · pushed\n\n\nremote https://github.com/owner/repo/commit/abc1234\nremote https://gitlab.com/owner/repo/commit/abc1234\nremote https://github.com/owner/repo/commit/abc1234\nremote javascript:alert(1)\nremote https://secret@example.com/repo/commit/abc1234\nremote http://example.com/repo/commit/abc1234"))
        XCTAssertNil(notice.subject); XCTAssertNil(notice.branch)
        XCTAssertEqual(notice.remotes.count, 2)
        XCTAssertEqual(notice.remotes.first?.host, "github.com")
    }
    func testUpdatedReceiptHidesPushAndShowsPushedTitle() throws {
        // The same message ID retains identity; its changed body is parsed on every render.
        let before = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234\nFixture\nbranch feature/test"))
        XCTAssertTrue(before.showsPush(canCommit: true, ahead: 2))
        XCTAssertFalse(before.showsPush(canCommit: false, ahead: 2))
        XCTAssertFalse(before.showsPush(canCommit: true, ahead: 0))
        let after = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234 · pushed\nFixture\nbranch feature/test\nremote https://github.com/owner/repo/commit/abc1234"))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.title, "Committed & pushed 1 file")
        XCTAssertFalse(after.showsPush(canCommit: true, ahead: 2))
        XCTAssertEqual(after.remotes.count, 1)
    }

}

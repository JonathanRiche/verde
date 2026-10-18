import XCTest
@testable import VerdeApp

final class GitCommitNoticeTests: XCTestCase {
    func testMultipleReposSubjectBranchAndPush() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 3 files: abc1234 (app), def5678 (lib) · pushed\nImprove fixture\nbranch feature/fixture"))
        XCTAssertEqual(notice.title, "Committed & pushed 3 files")
        XCTAssertEqual(notice.revisions, "abc1234 (app), def5678 (lib)")
        XCTAssertTrue(notice.pushed)
        XCTAssertEqual(notice.subject, "Improve fixture")
        XCTAssertEqual(notice.branch, "feature/fixture")
    }
    func testPositionalRemoteLinksValidateAndDeduplicateURLs() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234 · pushed\n\n\nremote https://github.com/owner/repo/commit/abc1234\nremote https://gitlab.com/owner/repo/commit/abc1234\nremote https://github.com/owner/repo/commit/abc1234\nremote javascript:alert(1)\nremote https://secret@example.com/repo/commit/abc1234\nremote http://example.com/repo/commit/abc1234"))
        XCTAssertNil(notice.subject); XCTAssertNil(notice.branch)
        XCTAssertEqual(notice.remotes.count, 2)
        XCTAssertEqual(notice.remotes.first?.host, "github.com")
    }
}

import XCTest
@testable import VerdeApp

final class GitCommitNoticeTests: XCTestCase {
    func testLegacyOneLineNotice() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234"))
        XCTAssertEqual(notice.title, "Committed 1 file")
        XCTAssertEqual(notice.revisions, "abc1234")
        XCTAssertFalse(notice.pushed); XCTAssertNil(notice.subject); XCTAssertNil(notice.branch)
        XCTAssertFalse(notice.entries[0].local)
        XCTAssertTrue(notice.showsPush(canCommit: true, ahead: 1))
    }
    func testMultipleReposTrackPushPerEntry() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 3 files: abc1234 (app), def5678 (lib) · pushed\nImprove fixture\nbranch feature/fixture\nremote https://github.com/o/app/commit/abc1234\nremote https://github.com/o/lib/commit/def5678"))
        XCTAssertEqual(notice.title, "Committed 3 files")
        XCTAssertEqual(notice.revisions, "abc1234 (app), def5678 (lib)")
        XCTAssertFalse(notice.pushed)
        XCTAssertNil(notice.entries[0].link)
        XCTAssertEqual(notice.remotes.map(\.absoluteString), ["https://github.com/o/lib/commit/def5678"])
        XCTAssertEqual(notice.subject, "Improve fixture")
        XCTAssertEqual(notice.branch, "feature/fixture")
    }
    func testMissingOptionalLinesAndUnknownFormat() throws {
        XCTAssertNil(GitCommitNotice.parse("Commit failed"))
        XCTAssertNil(GitCommitNotice.parse("Committed 1 file: unknown"))
        XCTAssertNil(GitCommitNotice.parse("Committed many files: abc1234"))
        XCTAssertNil(GitCommitNotice.parse("Committed 1 file: abc1234, broken"))
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 2 files: abc1234\n\nbranch main"))
        XCTAssertNil(notice.subject); XCTAssertEqual(notice.branch, "main")
    }
    func testRemoteLinksValidateOnlyTheirPositionalEntry() throws {
        for invalid in ["javascript:alert(1)", "https://secret@example.com/repo/commit/abc1234", "http://example.com/repo/commit/abc1234"] {
            let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234 · pushed\n\n\nremote \(invalid)"))
            XCTAssertTrue(notice.remotes.isEmpty)
        }
        let extra = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234 · pushed\n\n\nremote https://github.com/o/r/commit/abc1234\nremote https://unrelated.invalid/commit/abc1234"))
        XCTAssertEqual(extra.remotes.count, 1)
        XCTAssertEqual(extra.remotes[0].host, "github.com")
    }
    func testUpdatedReceiptReplacesLocalAndHidesPush() throws {
        let before = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234\nFixture\nbranch feature/test\nlocal"))
        XCTAssertFalse(before.showsPush(canCommit: true, ahead: 2))
        let after = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: abc1234 · pushed\nFixture\nbranch feature/test\nremote https://github.com/owner/repo/commit/abc1234"))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.title, "Committed & pushed 1 file")
        XCTAssertFalse(after.showsPush(canCommit: true, ahead: 2))
        XCTAssertEqual(after.remotes.count, 1)
        XCTAssertFalse(after.entries[0].local)
    }
    func testOldUnpushedURLNeverLinks() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 1 file: 0aae44a (petitedoux)\nFixture\nbranch main\nremote https://github.com/owner/petitedoux/commit/0aae44a"))
        XCTAssertTrue(notice.remotes.isEmpty)
        XCTAssertTrue(notice.showsPush(canCommit: true, ahead: 1))
        XCTAssertFalse(notice.showsPush(canCommit: false, ahead: 1))
        XCTAssertFalse(notice.showsPush(canCommit: true, ahead: 0))
    }
    func testMixedLocalBareAndMissingSlotsDoNotShiftLinks() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 4 files: aaa1111 (local), bbb2222 (unknown), ccc3333 (pushed) · pushed, ddd4444 (omitted)\n\n\nlocal\nremote\nremote https://github.com/o/r/commit/ccc3333"))
        XCTAssertTrue(notice.entries[0].local)
        XCTAssertFalse(notice.entries[0].showsPush(canCommit: true, ahead: 2))
        XCTAssertFalse(notice.entries[1].local)
        XCTAssertNil(notice.entries[1].link)
        XCTAssertEqual(notice.entries[2].link?.host, "github.com")
        XCTAssertFalse(notice.entries[3].local)
        XCTAssertTrue(notice.entries[3].showsPush(canCommit: true, ahead: 1))
    }
    func testLocalEntryCannotPushAnotherRemoteAndNamedEntriesUseTheirStatus() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 2 files: aaa1111 (local), bbb2222 (app)\n\n\nlocal"))
        let repos = [
            GitRepoStatus(root: "/local", name: "local", ahead: 5, has_remote: true),
            GitRepoStatus(root: "/app", name: "app", ahead: 0, has_remote: true),
            GitRepoStatus(root: "/other", name: "other", ahead: 2, has_remote: true)
        ]
        XCTAssertTrue(notice.entries[0].candidates(repos).isEmpty)
        XCTAssertTrue(notice.entries[1].candidates(repos).isEmpty)
    }
    func testRepoNameWithCommaAndAllPushedEntries() throws {
        let notice = try XCTUnwrap(GitCommitNotice.parse("Committed 2 files: aaa1111 (app, tools) · pushed, bbb2222 (lib) · pushed\n\n\nremote\nremote"))
        XCTAssertEqual(notice.entries[0].repo, "app, tools")
        XCTAssertTrue(notice.pushed)
        XCTAssertFalse(notice.showsPush(canCommit: true, ahead: 2))
        XCTAssertTrue(notice.remotes.isEmpty)
    }
}

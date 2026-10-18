import XCTest
@testable import VerdeApp

@MainActor
final class GitChangesTests: XCTestCase {
    @MainActor private final class Fake {
        var events: [Event] = []
        var view = GitReviewView()
        var receiptState = "succeeded"
        var status = GitStatusView()
        var summary = GitSummary(workspace_id: "w")
        var receiptError: LocalError?
        func query(_ selector: String) throws -> Data {
            if selector == "operations" {
                let items = try events.compactMap { event -> CoreOperation? in
                    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
                    return (object?["intent_id"] as? String).map { CoreOperation(intent_id: $0, state: self.receiptState, error: self.receiptError) }
                }
                return try JSONEncoder().encode(OperationsQuery(api_version: 1, revision: "1", data: OperationsView(items: items), error: nil))
            }
            if selector == "git_review" { return try JSONEncoder().encode(GitReviewQuery(api_version: 1, revision: "1", data: view, error: nil)) }
            if selector == "git_status" { return try JSONEncoder().encode(GitStatusQuery(api_version: 1, revision: "1", data: status, error: nil)) }
            return try JSONEncoder().encode(GitSummaryQuery(api_version: 1, revision: "1", data: summary, error: nil))
        }
        func model() -> GitChangesModel {
            GitChangesModel(workspace: "w", thread: "t", send: { self.events.append($0) }, query: { try self.query($0) })
        }
    }
    private func review(ownership: String = "mine", branch: String = "main") -> GitReviewView {
        let file = GitReviewFile(path: "a.swift", status: "modified", ownership: ownership, additions: 2, deletions: 1, binary: false, hunk_selectable: true, preview_truncated: false, hunks: [GitReviewHunk(index: 0, header: "@@ -1 +1 @@", text: "fixture")])
        return GitReviewView(state: "loaded", can_commit: true, review: GitReviewResult(review_id: "r", workspace_id: "w", local_thread_id: "t", turn_running: false, default_action: "commit", repos: [GitReviewRepo(root: "/repo", name: "repo", branch: branch, is_default_branch: branch == "main", files: [file])]), message_state: "ready", message: GitCommitMessageResult(message: "Fixture subject", branch: "feature/fixture", provider: "codex", model: "fixture"))
    }

    func testBlankCommitWaitsForFreshMessageThenCommitsOnce() async {
        let fake = Fake(); let model = fake.model()
        fake.view = review(ownership: "shared")
        await model.receive(fake.view)
        model.toggleFile(GitFileKey(root: "/repo", path: "a.swift"))
        XCTAssertEqual(model.generated, "")
        fake.receiptState = "pending"
        await model.commit()
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
        fake.receiptState = "succeeded"
        fake.view.message?.message = "Fresh selected changes"
        await model.refresh()
        let commits = fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.message, "Fresh selected changes")
    }

    func testFailedGenerationCannotCommitAnOldSuggestion() async {
        let fake = Fake(); let model = fake.model()
        fake.view = review()
        await model.receive(fake.view)
        fake.receiptState = "failed"
        fake.receiptError = LocalError(domain: "git", code: "unavailable", message: "Generation failed", retryable: true)
        await model.generate()
        await model.commit()
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
    }

    func testHeaderCommitSelectsOnlyMineWholeAndReportsOmissions() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review()
        var other = try XCTUnwrap(fake.view.review?.repos[0].files[0])
        other.path = "shared.swift"; other.ownership = "shared"
        fake.view.review?.repos[0].files.append(other)
        other.path = "personal.swift"; other.ownership = "unassigned"
        fake.view.review?.repos[0].files.append(other)
        await model.begin(push: false, quick: true)
        let event = try XCTUnwrap(fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }.first)
        XCTAssertFalse(model.sheet); XCTAssertFalse(model.confirmMain)
        XCTAssertFalse(event.push)
        XCTAssertEqual(event.selections[0].files.map(\.path), ["a.swift"])
        XCTAssertNil(event.selections[0].files[0].hunks)
        fake.view.result = GitCommitResult(workspace_id: "w", local_thread_id: "t", files: 1,
            repos: [GitRepoCommit(root: "/repo", commit: "abc1234", short_commit: "abc1234", subject: "Fixture", files: 1, push: "not_requested")])
        await model.refresh()
        XCTAssertTrue(model.toast?.detail.hasPrefix("1 file left out (shared/unclear) — use Commit… to review them") == true)
    }
    func testHeaderPushChecksOnlyReposWithMineFilesForDefaultBranch() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review(branch: "feature/test")
        var otherRepo = try XCTUnwrap(fake.view.review?.repos[0])
        otherRepo.root = "/other"; otherRepo.branch = "main"; otherRepo.is_default_branch = true
        otherRepo.files[0].ownership = "unclear"
        fake.view.review?.repos.append(otherRepo)
        await model.begin(push: true, quick: true)
        XCTAssertFalse(model.confirmMain); XCTAssertFalse(model.sheet)
        let event = try XCTUnwrap(fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }.first)
        XCTAssertTrue(event.push)
        XCTAssertEqual(event.selections.count, 1)
        XCTAssertEqual(event.selections[0].root, "/repo")
    }

    func testDefaultBranchMineWithSharedFilesConfirmsAndPluralizesOmissions() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review()
        var other = try XCTUnwrap(fake.view.review?.repos[0].files[0])
        other.path = "shared.swift"; other.ownership = "shared"
        fake.view.review?.repos[0].files.append(other)
        other.path = "unclear.swift"; other.ownership = "unclear"
        fake.view.review?.repos[0].files.append(other)
        await model.begin(push: true, quick: true)
        XCTAssertTrue(model.confirmMain); XCTAssertFalse(model.sheet)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
        await model.commit(push: true)
        fake.view.result = GitCommitResult(workspace_id: "w", local_thread_id: "t", files: 1,
            repos: [GitRepoCommit(root: "/repo", commit: "abc1234", short_commit: "abc1234", subject: "Fixture", files: 1, push: "pushed")])
        await model.refresh()
        XCTAssertTrue(model.toast?.detail.hasPrefix("2 files left out (shared/unclear) — use Commit… to review them") == true)
    }

    func testUnassignedFilesStartUntickedAndMonitorCannotCommit() async {
        let fake = Fake(); let model = fake.model()
        var view = review(ownership: "unassigned"); view.can_commit = false
        await model.receive(view)
        XCTAssertEqual(model.count, 0)
        model.selected.insert(GitFileKey(root: "/repo", path: "a.swift"))
        XCTAssertFalse(model.canSubmit)
        await model.commit()
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
    }
    func testFeatureBranchQuickActionCommitsOnceAndReportsRejectedPush() async {
        let fake = Fake(); let model = fake.model()
        await model.begin(push: true, quick: true)
        fake.view = review(branch: "feature/test")
        await model.receive(fake.view)
        await model.receive(fake.view)
        XCTAssertEqual(fake.events.filter { if case .git_commit = $0 { return true }; return false }.count, 1)
        var result = fake.view
        result.result = GitCommitResult(workspace_id: "w", local_thread_id: "t", files: 1, repos: [GitRepoCommit(root: "/repo", commit: "abcdefg", short_commit: "abcdefg", subject: "Fixture", files: 1, push: "rejected")])
        await model.receive(result)
        XCTAssertEqual(model.rejectedRoots, ["/repo"])
        XCTAssertTrue(model.notice?.contains("abcdefg") == true)
        XCTAssertFalse(model.notice?.contains("· pushed") == true)
    }
    func testUncertainReceiptNeverCreatesAnotherCommit() async {
        let fake = Fake(); let model = fake.model()
        await model.receive(review())
        fake.receiptState = "uncertain"
        await model.commit()
        await model.refresh()
        XCTAssertEqual(fake.events.filter { if case .git_commit = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(model.notice, "Checking original operation…")
    }

    func testHunkSelectionAndPendingMutationGuard() async {
        let fake = Fake(); let model = fake.model()
        await model.receive(review())
        let key = GitFileKey(root: "/repo", path: "a.swift")
        model.hunks[key] = [0]
        XCTAssertEqual(model.selections.first?.files.first?.hunks, [0])
        var pending = review(); pending.mutation_state = "pending"
        await model.receive(pending)
        await model.commit()
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
    }
}

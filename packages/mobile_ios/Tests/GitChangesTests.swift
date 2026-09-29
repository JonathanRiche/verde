import XCTest
import SwiftUI
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
    func testFilesAndHunksCanBeSelectedWithoutShowingDiffs() async throws {
        let fake = Fake(); let model = fake.model()
        await model.receive(review(ownership: "shared"))
        let key = GitFileKey(root: "/repo", path: "a.swift")
        XCTAssertFalse(model.canSubmit)
        model.toggleFile(key)
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(model.expanded.isEmpty)
        await model.toggleDiffs()
        XCTAssertTrue(model.expanded.contains(key))
        let file = try XCTUnwrap(model.review?.repos.first?.files.first)
        model.toggleHunk(key, file: file, index: 0, on: false)
        XCTAssertFalse(model.canSubmit)
        model.toggleHunk(key, file: file, index: 0, on: true)
        XCTAssertTrue(model.canSubmit)
        await model.toggleDiffs()
        XCTAssertTrue(model.expanded.isEmpty)
        XCTAssertTrue(model.selected.contains(key))
    }
    func testChangedSelectionRegeneratesBeforeCommitButTypedMessageDoesNot() async {
        let fake = Fake(); let model = fake.model()
        await model.receive(review(ownership: "shared"))
        model.toggleFile(GitFileKey(root: "/repo", path: "a.swift"))
        fake.receiptState = "pending"
        await model.commit()
        XCTAssertEqual(fake.events.filter { if case .git_message_generate = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
        model.message = "Chosen subject"
        await model.commit()
        XCTAssertEqual(fake.events.filter { if case .git_commit = $0 { return true }; return false }.count, 1)
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
    func testReadOnlySelectionCannotChangeAndBlankGenerationStaysOpen() async {
        let fake = Fake(); let model = fake.model()
        fake.view = review(ownership: "shared"); fake.view.can_commit = false
        await model.receive(fake.view)
        model.toggleFile(GitFileKey(root: "/repo", path: "a.swift"))
        XCTAssertEqual(model.count, 0)
        fake.view.can_commit = true; fake.view.message?.message = ""
        await model.receive(fake.view)
        model.toggleFile(GitFileKey(root: "/repo", path: "a.swift"))
        await model.commit()
        XCTAssertTrue(model.sheet)
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
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
    func testDelayedQuickGenerationResumesWhenReceiptArrives() async {
        let fake = Fake(); let model = fake.model()
        await model.begin(push: true, quick: true)
        fake.view = review(branch: "feature/test")
        fake.receiptState = "pending"
        await model.receive(fake.view)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
        fake.receiptState = "succeeded"
        await model.refresh()
        XCTAssertEqual(fake.events.filter { if case .git_commit = $0 { return true }; return false }.count, 1)
    }

    func testAlternatePushWaitsForMessageAndLabelsOnlyTappedButton() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review(ownership: "shared")
        fake.view.review?.repos[0].has_remote = true
        await model.receive(fake.view)
        model.toggleFile(GitFileKey(root: "/repo", path: "a.swift"))
        XCTAssertEqual(model.primaryAction, .commit)
        XCTAssertEqual(model.alternateAction, .push)
        fake.receiptState = "pending"
        await model.submitSheet(.push)
        XCTAssertEqual(model.actionTitle(.push), "Writing message…")
        XCTAssertEqual(model.actionTitle(.commit), "Commit")
        XCTAssertEqual(model.actionTitle(.branch), "New branch")
        XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.confirmMain)
        fake.receiptState = "succeeded"
        fake.view.message?.message = "Fresh selected changes"
        await model.refresh()
        let commits = fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }
        let event = try XCTUnwrap(commits.first)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(event.push)
        XCTAssertFalse(event.new_branch)
        XCTAssertEqual(event.selections.first?.files.first?.path, "a.swift")
        XCTAssertEqual(event.message, "Fresh selected changes")
        XCTAssertFalse(model.confirmMain)
    }
    func testPushSheetAlternateCommitsWithoutPushAndRemoteIsRequired() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review()
        fake.view.review?.repos[0].has_remote = true
        await model.begin(push: true)
        XCTAssertEqual(model.primaryAction, .push)
        XCTAssertEqual(model.alternateAction, .commit)
        await model.submitSheet(.commit)
        let event = try XCTUnwrap(fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }.first)
        XCTAssertFalse(event.push)
        XCTAssertFalse(event.new_branch)

        let local = Fake(); let localModel = local.model()
        await localModel.receive(review())
        XCTAssertFalse(localModel.hasRemote)
        await localModel.submitSheet(.push)
        XCTAssertFalse(local.events.contains { if case .git_commit = $0 { return true }; return false })
    }

    func testCommitResultToastAndExpiryDoNotDismissLaterErrors() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review()
        await model.receive(fake.view)
        fake.receiptState = "pending"
        await model.submitSheet(.commit)
        XCTAssertEqual(model.toast?.phase, .running)
        XCTAssertEqual(model.toast?.title, "Committing…")
        fake.receiptState = "succeeded"
        fake.view.result = GitCommitResult(workspace_id: "w", local_thread_id: "t", files: 1,
            repos: [GitRepoCommit(root: "/repo", commit: "abc1234", short_commit: "abc1234", subject: "Fixture", files: 1, branch: "feature/test", push: "not_requested")])
        await model.refresh()
        XCTAssertEqual(model.toast?.phase, .success)
        XCTAssertEqual(model.toast?.title, "Committed 1 file")
        XCTAssertEqual(model.toast?.detail, "abc1234 · feature/test · Fixture")
        let successID = try XCTUnwrap(model.toast?.id)
        model.expireToast(successID)
        XCTAssertNil(model.toast)
        XCTAssertNil(model.notice)
        fake.receiptState = "failed"
        fake.receiptError = LocalError(domain: "git", code: "missing_git_identity", message: "Set your Git identity on the host.", retryable: false)
        await model.commit()
        XCTAssertEqual(model.toast?.phase, .failure)
        XCTAssertEqual(model.toast?.detail, "Set your Git identity on the host.")
        model.expireToast(successID)
        XCTAssertEqual(model.toast?.phase, .failure)
        model.expireToast(try XCTUnwrap(model.toast?.id))
        XCTAssertNotNil(model.toast)
    }

    func testCommitPushRejectionKeepsCommitAndOffersPullPush() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review(); fake.view.review?.repos[0].has_remote = true
        await model.receive(fake.view)
        fake.receiptState = "pending"
        await model.submitSheet(.push)
        XCTAssertEqual(model.toast?.title, "Committing & pushing…")
        fake.receiptState = "succeeded"
        fake.view.result = GitCommitResult(workspace_id: "w", local_thread_id: "t", files: 3,
            repos: [GitRepoCommit(root: "/repo", commit: "abc1234", short_commit: "abc1234", subject: "Fixture", files: 3, branch: "main", push: "rejected", push_message: "Remote has new commits.")])
        await model.refresh()
        XCTAssertEqual(model.toast?.title, "Committed 3 files")
        XCTAssertEqual(model.toast?.phase, .warning)
        XCTAssertTrue(model.toast?.detail.contains("Remote has new commits.") == true)
        XCTAssertEqual(model.toast?.rejectedRoots, ["/repo"])
        fake.view.pull_push_result = GitPullPushResult(root: "/repo", push: "rejected")
        fake.view.mutation_state = "pending"
        await model.pullPush("/repo")
        XCTAssertEqual(model.toast?.title, "Pulling & pushing…")
        fake.view.mutation_state = "succeeded"
        fake.view.pull_push_result = GitPullPushResult(root: "/repo", push: "pushed")
        await model.refresh()
        XCTAssertEqual(model.toast?.title, "Pulled & pushed")
        XCTAssertEqual(model.toast?.phase, .success)
    }

    func testPlainPushToastUsesPrePushCountAndUpstream() async {
        let fake = Fake(); let model = fake.model()
        fake.status = GitStatusView(can_commit: true, status: GitStatusResult(workspace_id: "w", local_thread_id: "t",
            repos: [GitRepoStatus(root: "/repo", name: "repo", branch: "feature/test", upstream: "origin/feature/test", ahead: 2, has_remote: true)]))
        await model.refresh()
        fake.receiptState = "pending"
        await model.push()
        XCTAssertTrue(model.isPushing)
        XCTAssertEqual(model.toast?.phase, .running)
        fake.receiptState = "succeeded"
        fake.status.status?.repos[0].ahead = 0
        fake.view.mutation_state = "succeeded"
        fake.view.pull_push_result = GitPullPushResult(root: "/repo", push: "pushed")
        await model.refresh()
        XCTAssertEqual(model.toast?.title, "Pushed 2 commits to origin/feature/test")
        XCTAssertEqual(model.toast?.detail, "feature/test")
        XCTAssertEqual(model.toast?.phase, .success)
        XCTAssertFalse(model.isPushing)
    }

    func testCompletedCardsScreenshot() async throws {
        let fake = Fake(); let model = fake.model()
        fake.view = review()
        await model.receive(fake.view)
        await model.commit(push: true)
        fake.view.result = GitCommitResult(workspace_id: "w", local_thread_id: "t", files: 3,
            repos: [GitRepoCommit(root: "/repo", commit: "abc1234", short_commit: "abc1234", subject: "Improve fixture", files: 3, branch: "feature/fixture", push: "pushed")])
        await model.refresh()
        XCTAssertEqual(model.toast?.title, "Committed & pushed 3 files")
        let content = VStack {
            GitCommitNoticeCard(bodyText: "Committed 3 files: abc1234 · pushed\nImprove fixture\nbranch feature/fixture\nremote https://github.com/owner/repo/commit/abc1234")
            Spacer()
            GitActionToastCard(model: model)
        }.padding(.top, 30).background(VerdeTheme.background).preferredColorScheme(.dark)
        let controller = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "git-completed-cards"; attachment.lifetime = .keepAlways
        add(attachment)
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
    func testEmptyHeaderReviewShowsNoChangesWhileNonMineOpensSheet() async {
        let empty = Fake(); let model = empty.model()
        empty.view = review(); empty.view.review?.repos[0].files = []
        await model.begin(push: false, quick: true)
        XCTAssertEqual(model.toast?.title, "No uncommitted changes")
        XCTAssertFalse(model.sheet)
        XCTAssertFalse(empty.events.contains { if case .git_commit = $0 { return true }; return false })
        let shared = Fake(); let sharedModel = shared.model()
        shared.view = review(ownership: "shared")
        await sharedModel.begin(push: false, quick: true)
        XCTAssertTrue(sharedModel.sheet)
        XCTAssertEqual(sharedModel.count, 0)
        XCTAssertFalse(shared.events.contains { if case .git_commit = $0 { return true }; return false })
    }

    func testMineBadgeSubtractsAttentionWithoutUnderflow() async {
        let fake = Fake(); let model = fake.model()
        fake.summary.threads = [GitThreadSummary(local_thread_id: "t", files: 5, additions: 0, deletions: 0, attention: 3)]
        await model.refresh()
        XCTAssertEqual(model.mineCount, 2)
        fake.summary.threads[0].attention = 6
        await model.refresh()
        XCTAssertEqual(model.mineCount, 0)
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

    func testHeaderBlankGeneratedMessageReturnsToReviewWithoutCommitting() async {
        let fake = Fake(); let model = fake.model()
        fake.view = review(); fake.view.message?.message = "   "
        await model.begin(push: false, quick: true)
        XCTAssertTrue(model.sheet)
        XCTAssertEqual(model.toast?.phase, .failure)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
    }

    func testReviewSheetScreenshot() async throws {
        let fake = Fake(); let model = fake.model()
        var fixture = review(); fixture.review?.repos[0].has_remote = true
        await model.receive(fixture)
        let controller = UIHostingController(rootView: GitCommitSheet(model: model).preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "git-review-sheet"; attachment.lifetime = .keepAlways
        add(attachment)
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
    func testMainConfirmationUsesGeneratedMessageAndNewBranch() async throws {
        let fake = Fake(); let model = fake.model()
        await model.begin(push: true, quick: true)
        fake.view = review()
        await model.receive(fake.view)
        XCTAssertTrue(model.confirmMain)
        XCTAssertFalse(model.sheet)
        await model.commit(push: true, newBranch: true)
        let event = try XCTUnwrap(fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }.first)
        XCTAssertEqual(event.message, "Fixture subject")
        XCTAssertTrue(event.new_branch); XCTAssertTrue(event.push)
        XCTAssertEqual(event.branch_name, "feature/fixture")
        XCTAssertEqual(event.selections[0].files[0].path, "a.swift")
    }
    func testSharedFilesForceSheetAndTypedMessageReplacesGenerated() async throws {
        let fake = Fake(); let model = fake.model()
        await model.begin(push: true, quick: true)
        fake.view = review(ownership: "shared", branch: "feature/test")
        await model.receive(fake.view)
        XCTAssertTrue(model.sheet); XCTAssertFalse(model.confirmMain)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
        XCTAssertEqual(model.count, 0)
        model.selected.insert(GitFileKey(root: "/repo", path: "a.swift"))
        model.message = "Chosen subject"
        await model.commit()
        let event = try XCTUnwrap(fake.events.compactMap { if case .git_commit(let e) = $0 { return e }; return nil }.first)
        XCTAssertEqual(event.message, "Chosen subject")
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
    func testRejectedReceiptIsVisibleAndDoesNotResubmit() async {
        let fake = Fake(); let model = fake.model()
        fake.receiptState = "failed"
        fake.receiptError = LocalError(domain: "git", code: "scope_denied", message: "Read-only device", retryable: false)
        await model.begin(push: false)
        XCTAssertEqual(model.notice, "Read-only device")
        XCTAssertEqual(fake.events.count, 1)
    }
    func testCatalogArrivalRefreshesStatusOnceAndReconnectRefreshesAgain() async {
        let fake = Fake(); let model = fake.model()
        await model.catalog(available: false, connected: true)
        XCTAssertTrue(fake.events.isEmpty)
        await model.catalog(available: true, connected: true)
        await model.catalog(available: true, connected: true)
        XCTAssertEqual(fake.events.count, 1)
        await model.catalog(available: true, connected: false)
        await model.catalog(available: true, connected: true)
        XCTAssertEqual(fake.events.count, 2)
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

    func testRunningTurnStillUsesMineOnlyHeaderAction() async {
        let fake = Fake(); let model = fake.model()
        await model.begin(push: true, quick: true)
        var active = review(branch: "feature/test")
        active.review?.turn_running = true
        await model.receive(active)
        XCTAssertFalse(model.sheet)
        XCTAssertEqual(fake.events.filter { if case .git_commit = $0 { return true }; return false }.count, 1)
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

import XCTest
import SwiftUI
@testable import VerdeApp

@MainActor
final class GitChangesTests: XCTestCase {
    @MainActor private final class Fake {
        var events: [Event] = []
        var view = GitReviewView()
        var receiptState = "succeeded"
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
            if selector == "git_status" { return try JSONEncoder().encode(GitStatusQuery(api_version: 1, revision: "1", data: GitStatusView(), error: nil)) }
            return try JSONEncoder().encode(GitSummaryQuery(api_version: 1, revision: "1", data: GitSummary(workspace_id: "w"), error: nil))
        }
        func model() -> GitChangesModel {
            GitChangesModel(workspace: "w", thread: "t", send: { self.events.append($0) }, query: { try self.query($0) })
        }
    }
    private func review(ownership: String = "mine", branch: String = "main") -> GitReviewView {
        let file = GitReviewFile(path: "a.swift", status: "modified", ownership: ownership, additions: 2, deletions: 1, binary: false, hunk_selectable: true, preview_truncated: false, hunks: [GitReviewHunk(index: 0, header: "@@ -1 +1 @@", text: "fixture")])
        return GitReviewView(state: "loaded", can_commit: true, review: GitReviewResult(review_id: "r", workspace_id: "w", local_thread_id: "t", turn_running: false, default_action: "commit", repos: [GitReviewRepo(root: "/repo", name: "repo", branch: branch, files: [file])]), message_state: "ready", message: GitCommitMessageResult(message: "Fixture subject", branch: "feature/fixture", provider: "codex", model: "fixture"))
    }
    func testReviewSheetScreenshot() async throws {
        let fake = Fake(); let model = fake.model()
        await model.receive(review())
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

    func testRunningTurnAlwaysRequiresReview() async {
        let fake = Fake(); let model = fake.model()
        await model.begin(push: true, quick: true)
        var active = review(branch: "feature/test")
        active.review?.turn_running = true
        await model.receive(active)
        XCTAssertTrue(model.sheet)
        XCTAssertFalse(fake.events.contains { if case .git_commit = $0 { return true }; return false })
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

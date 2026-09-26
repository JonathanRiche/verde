import XCTest
@testable import VerdeApp

@MainActor
final class ManageTests: XCTestCase {
    func testCreateUsesSelectedWorkspaceAndOptionsOnce() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = ManageModel(browse: harness.browse)
        await model.start()
        await model.select(chatWS, ChatSelection(provider: "codex", model: "model", effort: "high", access: "supervised", speed: "off"))
        XCTAssertEqual(model.view?.new_chat.workspace_id, chatWS)
        async let first = model.createThread(chatWS)
        async let second = model.createThread(chatWS)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        let creates = harness.core.events.all.compactMap { if case .thread_create(let e) = $0 { return e }; return nil }
        XCTAssertEqual(creates.count, 1)
        XCTAssertEqual(creates.first?.workspace_id, chatWS)
        XCTAssertEqual(creates.first?.model, "model")
        XCTAssertEqual(creates.first?.effort, "high")
        XCTAssertEqual(creates.first?.access, "supervised")
        XCTAssertEqual(results.compactMap { $0 }.first?.thread_id, "created-thread")
        await harness.close()
    }

    func testBusyWorkspaceCloseShowsCountsAndDoesNotReportSuccess() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = ManageModel(browse: harness.browse)
        await model.start()
        let result = await model.workspace("close", id: chatWS)
        XCTAssertNil(result)
        XCTAssertEqual(model.notice, "Stop 2 running requests and 1 background tasks first.")
        XCTAssertFalse(model.busy)
        XCTAssertEqual(harness.core.events.count { if case .workspace_close = $0 { return true }; return false }, 1)
        await harness.close()
    }

    func testHistorySearchCarriesFilterAndCanResetForHome() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = ManageModel(browse: harness.browse)
        await model.start()
        await model.history("  query  ", workspace: chatWS)
        await model.history("", workspace: nil)
        let searches = harness.core.events.all.compactMap { if case .history_search(let e) = $0 { return e }; return nil }
        XCTAssertEqual(searches.map(\.query), ["query", ""])
        XCTAssertEqual(searches.first?.workspace_id, chatWS)
        XCTAssertNil(searches.last?.workspace_id)
        await harness.close()
    }

    func testUncertainMutationRequiresRefresh() {
        let job = ManageJob(intent_id: "i", kind: "thread_create", state: "uncertain")
        XCTAssertTrue(manageMessage(job).contains("Refresh"))
    }

    func testHistoryKeepsCoreBucketOrderAndOmitsSubagents() {
        func row(_ id: String, _ bucket: String) -> ThreadSummary {
            ThreadSummary(workspace_id: "w", thread_id: id, title: id, provider: "codex", model: nil, cwd: nil, open: false, archived: false, last_activity_at_ms: nil, status: "idle", history_bucket: bucket)
        }
        let groups = historySections([row("one", "Today"), row("subagent:child", "Today"), row("two", "Today"), row("old", "Earlier")])
        XCTAssertEqual(groups.map(\.0), ["Today", "Earlier"])
        XCTAssertEqual(groups[0].1.map(\.thread_id), ["one", "two"])
    }
}

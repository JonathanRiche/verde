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

    func testIdentityPinsAndResetsWithExplicitNulls() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = ManageModel(browse: harness.browse)
        await model.start()
        let job = await model.identity(chatWS, icon: 3, color: nil)
        XCTAssertEqual(job?.kind, "workspace_identity")
        let sent = harness.core.events.all.compactMap { if case .workspace_identity(let e) = $0 { return e }; return nil }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.workspace_id, chatWS)
        XCTAssertEqual(sent.first?.icon_index, 3)
        XCTAssertNil(sent.first?.color_index)
        // The reset travels as an explicit null so the daemon row returns to automatic.
        let json = String(decoding: try JSONEncoder().encode(Event.workspace_identity(sent[0])), as: UTF8.self)
        XCTAssertTrue(json.contains("\"color_index\":null"), json)
        await harness.close()
    }

    func testWorkspacePathChecksBeforeAskingTheHost() {
        XCTAssertEqual(normalizedWorkspacePath("  /Users/me/project/// \n"), "/Users/me/project")
        XCTAssertEqual(normalizedWorkspacePath("/"), "/")
        XCTAssertNil(workspacePathProblem(""))
        XCTAssertNil(workspacePathProblem("/Users/me/my project "))
        XCTAssertNotNil(workspacePathProblem("~/project"))
        XCTAssertNotNil(workspacePathProblem("Users/me/project"))
        XCTAssertNotNil(workspacePathProblem("/Users/me/../other"))
        XCTAssertNotNil(workspacePathProblem("/Users/me/a\tb"))
        XCTAssertTrue(workspaceFolderMessage(LocalError(code: "not_found", message: "directory not found")).contains("doesn't exist"))
        XCTAssertEqual(workspaceFolderMessage(LocalError(code: "busy", message: "Try again soon.")), "Try again soon.")
        XCTAssertEqual(uniqued(["/a", "/b", "/a"]), ["/a", "/b"])
    }

    func testBadWorkspacePathNeverReachesTheCore() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = ManageModel(browse: harness.browse)
        await model.start()
        for path in ["~/project", "relative/path", "/a/../b", "   "] {
            let job = await model.createWorkspace(path: path, label: "")
            XCTAssertNil(job)
            XCTAssertNotNil(model.notice, path)
        }
        let creates = harness.core.events.all.compactMap { if case .workspace_create(let e) = $0 { return e }; return nil }
        XCTAssertTrue(creates.isEmpty)
        await harness.close()
    }

    func testHistorySubtitleJoinsOnlyPresentParts() {
        var thread = ThreadSummary(workspace_id: "w", thread_id: "t", title: "Fix", provider: "codex", model: nil, cwd: "",
                                   open: true, archived: false, last_activity_at_ms: nil, status: "idle", history_bucket: "Today")
        XCTAssertEqual(historySubtitle(thread, workspace: nil, now: 0), "")
        XCTAssertEqual(historySubtitle(thread, workspace: "demo-app", now: 0), "demo-app")
        thread.archived = true
        thread.last_activity_at_ms = 0
        let line = historySubtitle(thread, workspace: "demo-app", now: 2 * 3_600_000)
        XCTAssertTrue(line.hasPrefix("demo-app · Archived · "), line)
        XCTAssertFalse(line.hasSuffix(" · "))
    }

    func testNewChatRowsNameTheResolvedDefault() {
        let access = [ChatChoice(id: "supervised", label: "Supervised"), ChatChoice(id: "full_access", label: "Full access")]
        XCTAssertEqual(newChatChoiceLabel("Access", value: nil, choices: access), "Default · Full access")
        XCTAssertEqual(newChatChoiceLabel("Access", value: "supervised", choices: access), "Supervised")
        XCTAssertEqual(newChatChoiceLabel("Model", value: nil, choices: []), "Default")
    }
}

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
}

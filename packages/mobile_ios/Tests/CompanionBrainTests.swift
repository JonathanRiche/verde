import XCTest
@testable import VerdeApp

final class CompanionBrainTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(classifyBrainChange(currentProvider: "claude", newProvider: "codex", thread: .noChat), .rosterOnly)
        XCTAssertEqual(classifyBrainChange(currentProvider: "claude", newProvider: "codex", thread: .empty), .switchNow,
                       "nothing to hand off: the host switches at once")
        XCTAssertEqual(classifyBrainChange(currentProvider: "claude", newProvider: "codex", thread: .committed), .handoff)
        XCTAssertEqual(classifyBrainChange(currentProvider: "claude", newProvider: "claude", thread: .committed), .inPlace)
        XCTAssertEqual(classifyBrainChange(currentProvider: "claude", newProvider: "claude", thread: .empty), .inPlace)
        XCTAssertEqual(classifyBrainChange(currentProvider: "claude", newProvider: "", thread: .committed), .inPlace)
    }

    func testRosterPayload() throws {
        var roster = Roster.starter(home: "ws", id: "a")
        roster.edit("a") { $0.thread_id = "t1" }
        XCTAssertTrue(roster.setBrain("a", provider: "claude", model: "opus"))
        XCTAssertFalse(roster.setBrain("a", provider: "claude", model: "opus"), "no change, nothing to save")
        XCTAssertEqual(roster.active?.thread_id, "t1", "same-chat changes keep the thread")
        XCTAssertTrue(roster.setBrain("a", provider: "codex", model: "gpt", thread: (workspace: "ws2", thread: "t2")))
        XCTAssertFalse(roster.setBrain("missing", provider: "codex", model: ""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(roster)) as? [String: Any])
        let entry = try XCTUnwrap((object["companions"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["provider"] as? String, "codex")
        XCTAssertEqual(entry["model"] as? String, "gpt")
        XCTAssertEqual(entry["home_workspace_id"] as? String, "ws2")
        XCTAssertEqual(entry["thread_id"] as? String, "t2")
    }

    func testLabels() {
        XCTAssertEqual(brainLabel(provider: "Claude", model: "Opus 5.5", effort: "High"), "Claude · Opus 5.5 · High")
        XCTAssertEqual(brainLabel(provider: "Claude", model: nil, effort: "Default"), "Claude")
        XCTAssertEqual(brainLabel(provider: "", model: "", effort: nil), "Default brain")
        XCTAssertEqual(providerDisplayName("codex"), "Codex")
        XCTAssertEqual(providerDisplayName("opencode"), "OpenCode")
        XCTAssertEqual(providerDisplayName("claude"), "Claude")
        XCTAssertEqual(providerDisplayName("claude", choices: [ChatChoice(id: "claude", label: "Claude Code")]), "Claude Code")
        XCTAssertEqual(brainSwitchTitle(name: "Moss", provider: "Codex"), "Switch Moss to Codex?")
        XCTAssertEqual(brainSwitchMessage(name: "Moss", from: "Claude", to: "Codex"),
                       "Moss keeps this conversation. Claude will write a quick handoff brief first, then Codex takes over with the brief and recent history.")
        XCTAssertEqual(newConversationMessage(name: "Moss"),
                       "Moss starts fresh with its current brain. This conversation moves to Conversations… so you can go back to it.")
    }

    func testHistoryPushDedupeAndCap() {
        var roster = Roster.starter(home: "ws", id: "a")
        XCTAssertFalse(roster.startNewConversation("a", title: "x", at: 1), "no conversation yet")
        roster.edit("a") { $0.thread_id = "t0"; $0.provider = "claude"; $0.model = "opus" }
        XCTAssertTrue(roster.startNewConversation("a", title: "Deploy plan", at: 10))
        XCTAssertEqual(roster.active?.thread_id, "", "the next message starts a fresh chat")
        XCTAssertEqual(roster.active?.history, [CompanionHistoryItem(thread_id: "t0", title: "Deploy plan", provider: "claude", model: "opus", ended_at_ms: 10)])
        for index in 1...14 {
            roster.edit("a") { $0.thread_id = "t\(index)" }
            roster.startNewConversation("a", title: "", at: Int64(10 + index))
        }
        let history = roster.active?.history ?? []
        XCTAssertEqual(history.count, RosterEntry.historyLimit)
        XCTAssertEqual(history.first?.thread_id, "t14", "newest first")
        XCTAssertEqual(history.first?.title, "Conversation")
        roster.edit("a") { $0.thread_id = "t14" }
        roster.startNewConversation("a", title: "again", at: 99)
        XCTAssertEqual(roster.active?.history.filter { $0.thread_id == "t14" }.count, 1, "deduplicated by thread")
        XCTAssertEqual(roster.active?.history.first?.title, "again")
    }

    func testResumeAndRemove() throws {
        var roster = Roster.starter(home: "ws", id: "a")
        roster.edit("a") { $0.thread_id = "old"; $0.provider = "codex"; $0.model = "gpt" }
        roster.startNewConversation("a", title: "Old chat", at: 1)
        roster.edit("a") { $0.thread_id = "new"; $0.provider = "claude"; $0.model = "opus" }
        XCTAssertTrue(roster.resumeConversation("a", threadID: "old", currentTitle: "New chat", at: 2))
        let entry = try XCTUnwrap(roster.active)
        XCTAssertEqual(entry.thread_id, "old")
        XCTAssertEqual(entry.provider, "codex", "the resumed chat's brain comes back")
        XCTAssertEqual(entry.model, "gpt")
        XCTAssertEqual(entry.history.map(\.thread_id), ["new"])
        XCTAssertEqual(entry.history.first?.provider, "claude")
        XCTAssertFalse(roster.resumeConversation("a", threadID: "missing", currentTitle: "", at: 3))
        XCTAssertTrue(roster.removeHistory("a", threadID: "new"))
        XCTAssertFalse(roster.removeHistory("a", threadID: "new"))
        XCTAssertEqual(roster.active?.thread_id, "old", "removing never touches the current chat")
    }

    func testHistoryRoundTripsThroughSaves() throws {
        let json = #"{"id":"a","name":"Moss","character":"moss","thread_id":"t2","history":[{"thread_id":"t1","title":"Old","provider":"codex","model":"","ended_at_ms":5}]}"#
        let entry = try JSONDecoder().decode(RosterEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.history.first?.title, "Old")
        let (type, fields) = try CompanionIntent.save(intentID: "i", roster: Roster(active_id: "a", companions: [entry]), expectedRevision: 4)
        XCTAssertEqual(type, "companion_save")
        if case .string(let revision)? = fields["expected_revision"] { XCTAssertEqual(revision, "4") } else { XCTFail("expected_revision") }
        guard case .object(let roster)? = fields["roster"], case .array(let companions)? = roster["companions"],
              case .object(let saved)? = companions.first, case .array(let history)? = saved["history"] else { return XCTFail("history") }
        XCTAssertEqual(history.count, 1)
    }

    func testBrainSwitchView() throws {
        let json = """
        {"data":{"loaded":true,"supported":true,"revision":"9",
         "roster":{"version":1,"active_id":"a","companions":[{"id":"a","name":"Moss","character":"moss","thread_id":"t","provider":"claude"}]},
         "crew":{"workspace_id":"","thread_id":"","links":[],"loaded":false,"loading":false},
         "brain_switch":{"intent_id":"i1","status":"briefing","from":"claude","to":"codex"}}}
        """
        let view = try XCTUnwrap(decodeCompanionView(Data(json.utf8)))
        XCTAssertEqual(view.brain_switch?.status, "briefing")
        XCTAssertEqual(brainSwitchStatusText(view.brain_switch, name: "Moss"), "Handing off to Codex…")
        let reply = try companionReply(.brainSwitch, operation: CoreOperation(intent_id: "i1", state: "succeeded", error: nil), view: view, intent: "i1")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: reply) as? [String: Any]).flatMap { $0["brain_switch"] as? [String: Any] }?["to"] as? String, "codex")
        let roster = try companionReply(.rosterGet, operation: CoreOperation(intent_id: "r", state: "succeeded", error: nil), view: view)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: roster) as? [String: Any])?["brain_switch"])

        XCTAssertNil(brainSwitchStatusText(BrainSwitchState(intent_id: "i", status: "switched", from: "claude", to: "codex"), name: "Moss"))
        XCTAssertEqual(brainSwitchStatusText(BrainSwitchState(intent_id: "i", status: "failed", error_code: "companion_busy", from: "a", to: "b"), name: "Moss"),
                       "Moss is working right now. Switch when the current turn finishes.")
        XCTAssertThrowsError(try companionReply(.brainSwitch, operation: CoreOperation(intent_id: "i1", state: "failed",
            error: LocalError(domain: "companion", code: "companion_busy", message: "m", rpc_code: "companion_busy")), view: view, intent: "i1")) {
            XCTAssertEqual($0 as? CompanionRPCError, .remote(code: "companion_busy"))
        }
        let (type, fields) = CompanionIntent.brainSwitch(intentID: "i", companionID: "a", provider: "codex", model: "", brief: false)
        XCTAssertEqual(type, "companion_brain_switch")
        XCTAssertNil(fields["model"])
        if case .bool(let brief)? = fields["brief"] { XCTAssertFalse(brief) } else { XCTFail("brief") }
    }
}

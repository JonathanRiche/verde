import XCTest
@testable import VerdeApp

/// Scripted daemon: each call pops the next reply for its method and records the params.
final class FakeCompanionRPC: CompanionRPC {
    enum Reply { case ok(String), fail(CompanionRPCError) }
    private(set) var calls: [(method: CompanionMethod, params: [String: Any])] = []
    var replies: [CompanionMethod: [Reply]] = [:]

    func call(_ method: CompanionMethod, params: Data) async throws -> Data {
        calls.append((method, (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]))
        guard var queue = replies[method], !queue.isEmpty else { throw CompanionRPCError.remote(code: "unscripted") }
        let reply = queue.removeFirst()
        replies[method] = queue
        switch reply {
        case .ok(let json): return Data(json.utf8)
        case .fail(let error): throw error
        }
    }
    func count(_ method: CompanionMethod) -> Int { calls.filter { $0.method == method }.count }
}

private let wireRoster = """
{"revision":7,"roster":{"version":1,"active_id":"b","future_flag":true,"companions":[
 {"id":"a","name":"Sprout","character":"sprout","home_workspace_id":"ws-1","thread_id":"","provider":"","model":"","orders":""},
 {"id":"b","name":"Wren","character":"vireo","home_workspace_id":"ws-2","thread_id":"chat-1","provider":"claude","model":"opus","orders":"Never push to main.","mood":{"x":1}}
]}}
"""

final class CompanionRosterTests: XCTestCase {
    func testDecodesRosterAndKeepsUnknownFieldsOnEncode() async throws {
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterGet] = [.ok(wireRoster)]
        let snapshot = try await CompanionClient(rpc: rpc).roster()
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.roster.companions.count, 2)
        let wren = try XCTUnwrap(snapshot.roster.active)
        XCTAssertEqual(wren.name, "Wren")
        XCTAssertEqual(wren.character, .vireo)
        XCTAssertEqual(wren.home_workspace_id, "ws-2")
        XCTAssertEqual(wren.thread_id, "chat-1")
        XCTAssertEqual(wren.provider, "claude")
        XCTAssertEqual(wren.model, "opus")
        XCTAssertEqual(wren.orders, "Never push to main.")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.roster)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["active_id"] as? String, "b")
        XCTAssertEqual(object["future_flag"] as? Bool, true)
        let companions = try XCTUnwrap(object["companions"] as? [[String: Any]])
        XCTAssertEqual(companions[1]["character"] as? String, "vireo")
        XCTAssertEqual(companions[0]["thread_id"] as? String, "")
        XCTAssertNotNil(companions[1]["mood"])
        XCTAssertEqual(Set(companions[0].keys), ["id", "name", "character", "home_workspace_id", "thread_id", "provider", "model", "orders"])
    }

    func testUnknownCharacterDrawsAsSproutButRoundTrips() throws {
        let entry = try JSONDecoder().decode(RosterEntry.self, from: Data(#"{"id":"x","name":"Owl","character":"owl"}"#.utf8))
        XCTAssertEqual(entry.character, .sprout)
        XCTAssertEqual(entry.home_workspace_id, "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(object["character"] as? String, "owl")
    }

    func testNeverSavedRosterShowsStableStarterSprout() async throws {
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterGet] = [.ok(#"{"revision":0,"roster":{"version":1,"active_id":"","companions":[]}}"#)]
        var roster = try await CompanionClient(rpc: rpc).roster().roster
        roster.normalize(home: "ws-1", starterID: "starter")
        XCTAssertEqual(roster.companions.map(\.name), ["Sprout"])
        XCTAssertEqual(roster.active?.id, "starter")
        XCTAssertEqual(roster.active?.home_workspace_id, "ws-1")
        XCTAssertEqual(roster.active?.thread_id, "")
        var empty = Roster()
        empty.normalize(home: nil, starterID: "starter")
        XCTAssertTrue(empty.companions.isEmpty, "no workspace, no starter")
    }

    func testAddRemoveSelectAndLimits() {
        var roster = Roster.starter(home: "ws", id: "c0")
        XCTAssertEqual(roster.add(.moss, home: "ws", id: "c1")?.name, "Moss")
        XCTAssertEqual(roster.active_id, "c1", "a new companion becomes active")
        XCTAssertEqual(roster.add(.moss, home: "ws", id: "c2")?.name, "Moss 2")
        for index in 3..<Roster.maxCompanions { XCTAssertNotNil(roster.add(.vireo, home: "ws", id: "c\(index)")) }
        XCTAssertTrue(roster.isFull)
        XCTAssertNil(roster.add(.sprout, home: "ws", id: "overflow"))
        XCTAssertEqual(roster.companions.count, 8)

        XCTAssertTrue(roster.select("c2"))
        XCTAssertFalse(roster.select("missing"))
        XCTAssertTrue(roster.remove("c2"))
        XCTAssertEqual(roster.active_id, "c3", "removing the active one selects its neighbour")
        while roster.companions.count > 1 { XCTAssertTrue(roster.remove(roster.companions[0].id)) }
        XCTAssertFalse(roster.remove(roster.companions[0].id), "the last companion stays")
        XCTAssertEqual(roster.active_id, roster.companions[0].id)
    }

    func testRenameCleansAndClipsToThirtyTwoBytes() {
        var roster = Roster.starter(home: "ws", id: "a")
        roster.add(.moss, name: "Moss", home: "ws", id: "b")
        XCTAssertTrue(roster.rename("a", to: "  Fern\u{7}ignored  "))
        XCTAssertEqual(roster.companions[0].name, "Fern")
        XCTAssertTrue(roster.rename("a", to: "moss"))
        XCTAssertEqual(roster.companions[0].name, "moss 2", "names stay unique")
        XCTAssertFalse(roster.rename("a", to: "   "))
        let long = String(repeating: "é", count: 20) // 40 bytes
        XCTAssertTrue(roster.rename("b", to: long))
        XCTAssertEqual(roster.companions[1].name, String(repeating: "é", count: 16))
        XCTAssertLessThanOrEqual(roster.companions[1].name.utf8.count, RosterEntry.nameLimit)
        roster.edit("b") { $0.orders = String(repeating: "x", count: 2000) }
        XCTAssertEqual(roster.companions[1].orders.utf8.count, RosterEntry.ordersLimit)
    }

    func testBindThreadKeepsAThreadBoundElsewhere() {
        var roster = Roster.starter(home: "ws", id: "a")
        XCTAssertTrue(roster.bindThread("a", workspace: "ws", thread: "t1"))
        XCTAssertFalse(roster.bindThread("a", workspace: "ws", thread: "t2"))
        XCTAssertEqual(roster.active?.thread_id, "t1")
    }
}

final class CompanionConflictTests: XCTestCase {
    func testPutSendsExpectedRevision() async throws {
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterPut] = [.ok(#"{"revision":8}"#)]
        let base = RosterSnapshot(revision: 7, roster: Roster.starter(home: "ws", id: "a"))
        let saved = try await CompanionClient(rpc: rpc).update(base, home: "ws", starterID: "a") { $0.rename("a", to: "Fern") }
        XCTAssertEqual(saved.revision, 8)
        XCTAssertEqual(saved.roster.active?.name, "Fern")
        let params = try XCTUnwrap(rpc.calls.last?.params)
        XCTAssertEqual(params["expected_revision"] as? Int, 7)
        let roster = try XCTUnwrap(params["roster"] as? [String: Any])
        XCTAssertEqual((roster["companions"] as? [[String: Any]])?.first?["name"] as? String, "Fern")
    }

    func testConflictRefetchesAndReappliesTheChange() async throws {
        let rpc = FakeCompanionRPC()
        // Another device renamed Wren's orders and moved to revision 9 meanwhile.
        rpc.replies[.rosterPut] = [.fail(.conflict), .ok(#"{"revision":10}"#)]
        rpc.replies[.rosterGet] = [.ok(wireRoster.replacingOccurrences(of: "\"revision\":7", with: "\"revision\":9")
            .replacingOccurrences(of: "Never push to main.", with: "Ask first."))]
        var stale = Roster.starter(home: "ws-1", id: "a")
        stale.add(.vireo, name: "Wren", home: "ws-2", id: "b")
        let base = RosterSnapshot(revision: 7, roster: stale)
        let saved = try await CompanionClient(rpc: rpc).update(base, home: "ws-1", starterID: "a") { $0.select("a") }
        XCTAssertEqual(saved.revision, 10)
        XCTAssertEqual(saved.roster.active_id, "a")
        XCTAssertEqual(saved.roster.companions.first { $0.id == "b" }?.orders, "Ask first.", "the other device's edit survives")
        XCTAssertEqual(rpc.count(.rosterGet), 1)
        XCTAssertEqual(rpc.calls.filter { $0.method == .rosterPut }.map { $0.params["expected_revision"] as? Int }, [7, 9])
    }

    func testChangeThatNoLongerAppliesSavesNothing() async throws {
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterPut] = [.fail(.conflict)]
        rpc.replies[.rosterGet] = [.ok(#"{"revision":3,"roster":{"version":1,"active_id":"z","companions":[{"id":"z","name":"Moss","character":"moss","home_workspace_id":"ws"}]}}"#)]
        let base = RosterSnapshot(revision: 2, roster: Roster.starter(home: "ws", id: "a"))
        let saved = try await CompanionClient(rpc: rpc).update(base, home: "ws", starterID: "a") { $0.rename("a", to: "Fern") }
        XCTAssertEqual(saved.revision, 3)
        XCTAssertEqual(saved.roster.active?.name, "Moss")
        XCTAssertEqual(rpc.count(.rosterPut), 1)
    }

    func testGivesUpAfterRepeatedConflicts() async {
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterPut] = Array(repeating: .fail(.conflict), count: CompanionClient.maxAttempts)
        rpc.replies[.rosterGet] = Array(repeating: .ok(wireRoster), count: CompanionClient.maxAttempts)
        let base = RosterSnapshot(revision: 1, roster: Roster.starter(home: "ws", id: "a"))
        do {
            _ = try await CompanionClient(rpc: rpc).update(base, home: "ws", starterID: "a") { $0.select("a") }
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? CompanionRPCError, .conflict)
        }
        XCTAssertEqual(rpc.count(.rosterPut), CompanionClient.maxAttempts)
        XCTAssertEqual(rpc.count(.rosterGet), CompanionClient.maxAttempts - 1)
    }
}

final class CompanionCrewTests: XCTestCase {
    func testStatusMapping() {
        let expected: [(String, CrewAttention, String)] = [
            ("waiting_approval", .approval, "Needs approval"), ("blocked", .blocked, "Needs input"),
            ("running", .running, "Running"), ("failed", .failed, "Failed"), ("aborted", .failed, "Failed"),
            ("interrupted", .failed, "Failed"), ("completed", .done, "Done"), ("idle", .idle, "Idle"), ("something_new", .idle, "Idle"),
        ]
        for (status, attention, label) in expected {
            XCTAssertEqual(CrewAttention(status: status), attention, status)
            XCTAssertEqual(attention.label, label, status)
        }
        XCTAssertTrue(CrewAttention.approval.needsYou)
        XCTAssertTrue(CrewAttention.blocked.needsYou)
        XCTAssertFalse(CrewAttention.failed.needsYou)
    }

    func testLinksDecodeSortAndHide() async throws {
        let rpc = FakeCompanionRPC()
        rpc.replies[.linksList] = [.ok("""
        {"links":[
         {"link_id":"1","workspace_id":"ws-b","parent_workspace_id":"home","local_thread_id":"t1","title":"Done one","provider":"codex","status":"completed","summary":"Shipped\\nmore","updated_at_ms":50,"hidden":false},
         {"link_id":"2","workspace_id":"","parent_workspace_id":"home","local_thread_id":"t2","title":"","provider":"claude","status":"running","summary":"","updated_at_ms":10,"hidden":false},
         {"link_id":"3","workspace_id":"ws-c","parent_workspace_id":"home","local_thread_id":"t3","title":"Asks","provider":"claude","status":"waiting_approval","summary":"","updated_at_ms":5,"hidden":false},
         {"link_id":"4","workspace_id":"ws-c","parent_workspace_id":"home","local_thread_id":"t4","title":"Hidden","provider":"claude","status":"running","summary":"","updated_at_ms":99,"hidden":true}
        ]}
        """)]
        let links = try await CompanionClient(rpc: rpc).crew(workspace: "home", thread: "chat-1")
        XCTAssertEqual(rpc.calls.last?.params["workspace_id"] as? String, "home")
        XCTAssertEqual(rpc.calls.last?.params["parent_thread_id"] as? String, "chat-1")
        let rows = crewRows(links, home: "home")
        XCTAssertEqual(rows.map(\.link_id), ["3", "2", "1"])
        XCTAssertEqual(rows[1].workspace_id, "home", "a link without a child workspace lives with its parent")
        XCTAssertEqual(rows[1].displayTitle, "Untitled chat")
        XCTAssertEqual(rows[2].detail, "Shipped")
    }

    func testPresenceStatusAndPose() {
        XCTAssertEqual(companionPresence(needsYou: 0, crewRunning: 0, working: false, failed: false, connected: true),
                       CompanionPresence(pose: .idle, failure: false, status: "Ready when you are"))
        XCTAssertEqual(companionPresence(needsYou: 0, crewRunning: 3, working: false, failed: false, connected: true).status, "3 chats running")
        XCTAssertEqual(companionPresence(needsYou: 0, crewRunning: 1, working: false, failed: false, connected: true).status, "1 chat running")
        XCTAssertEqual(companionPresence(needsYou: 0, crewRunning: 2, working: true, failed: false, connected: true).pose, .working)
        let needs = companionPresence(needsYou: 2, crewRunning: 2, working: true, failed: false, connected: true)
        XCTAssertEqual(needs.pose, .approval)
        XCTAssertEqual(needs.status, "2 things need you")
        XCTAssertEqual(companionPresence(needsYou: 1, crewRunning: 0, working: false, failed: false, connected: true).status, "1 thing needs you")
        XCTAssertEqual(companionPresence(needsYou: 1, crewRunning: 0, working: false, failed: false, connected: false).pose, .paused)
    }

    func testCrewNeedingYouJoinsTheNeedsYouList() {
        let crew = crewRows([CrewLink(link_id: "1", workspace_id: "ws", local_thread_id: "t1", title: "Deploy", status: "blocked"),
                             CrewLink(link_id: "2", workspace_id: "ws", local_thread_id: "t2", title: "Tests", status: "running")], home: "ws")
        let items = needsYouItems(home: nil, workspaces: nil, crew: crew, companion: (workspace: "ws", thread: "own"))
        XCTAssertEqual(items.map(\.threadID), ["t1"])
        XCTAssertEqual(items.first?.reason, "Needs input")
        XCTAssertTrue(needsYouItems(home: nil, workspaces: nil, crew: crew, companion: (workspace: "ws", thread: "t1")).isEmpty,
                      "the companion's own chat is not listed")
    }
}

/// The core adapter's mapping from a settled companion intent + `companion` view to RPC replies.
final class CompanionCoreReplyTests: XCTestCase {
    private func view(_ json: String) throws -> CompanionView { try JSONDecoder().decode(CompanionView.self, from: Data(json.utf8)) }
    private func op(_ state: String, code: String? = nil, rpc: String? = nil) -> Operation {
        Operation(intent_id: "i", state: state, error: code.map { LocalError(domain: "companion", code: $0, message: "m", rpc_code: rpc) })
    }
    private let loaded = """
    {"loaded":true,"loading":false,"saving":false,"supported":true,"can_edit":true,"revision":"7",
     "roster":{"version":1,"active_id":"b","companions":[{"id":"b","name":"Wren","character":"vireo","home_workspace_id":"ws-2","thread_id":"chat-1"}]},
     "crew":{"workspace_id":"ws-2","thread_id":"chat-1","links":[{"link_id":"1","workspace_id":"ws-x","local_thread_id":"t1","status":"running"}],"loaded":true,"loading":false}}
    """

    func testRosterGetAnswersFromTheView() async throws {
        let reply = try companionReply(.rosterGet, operation: op("succeeded"), view: view(loaded))
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterGet] = [.ok(String(decoding: reply, as: UTF8.self))]
        let snapshot = try await CompanionClient(rpc: rpc).roster()
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.roster.active?.name, "Wren")
        XCTAssertEqual(snapshot.roster.active?.thread_id, "chat-1")
    }

    func testPutAnswersWithTheNewRevisionAndMapsConflict() throws {
        let reply = try companionReply(.rosterPut, operation: op("succeeded"), view: view(loaded))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["revision"] as? Int, 7)
        XCTAssertThrowsError(try companionReply(.rosterPut, operation: op("failed", code: "conflict", rpc: "conflict"), view: view(loaded))) {
            XCTAssertEqual($0 as? CompanionRPCError, .conflict)
        }
        XCTAssertThrowsError(try companionReply(.rosterPut, operation: op("failed", code: "busy"), view: view(loaded))) {
            XCTAssertEqual($0 as? CompanionRPCError, .remote(code: "busy"))
        }
    }

    func testOlderHostIsUnsupported() throws {
        XCTAssertThrowsError(try companionReply(.rosterGet, operation: op("failed", code: "method_not_found", rpc: "method_not_found"), view: nil)) {
            XCTAssertEqual($0 as? CompanionRPCError, .unsupported)
        }
        let old = try view(loaded.replacingOccurrences(of: "\"supported\":true", with: "\"supported\":false"))
        XCTAssertThrowsError(try companionReply(.rosterGet, operation: op("failed", code: "companion"), view: old)) {
            XCTAssertEqual($0 as? CompanionRPCError, .unsupported)
        }
    }

    func testCrewOnlyForTheRequestedThread() throws {
        let mine = try companionReply(.linksList, operation: op("succeeded"), view: view(loaded), crew: (workspace: "ws-2", thread: "chat-1"))
        XCTAssertEqual(try crewRows(JSONDecoder().decode(LinksProbe.self, from: mine).links, home: "ws-2").map(\.local_thread_id), ["t1"])
        let other = try companionReply(.linksList, operation: op("succeeded"), view: view(loaded), crew: (workspace: "ws-2", thread: "other"))
        XCTAssertTrue(try JSONDecoder().decode(LinksProbe.self, from: other).links.isEmpty)
    }

    func testBusyWaitsForCoalescedWork() throws {
        var current = try view(loaded)
        XCTAssertFalse(companionBusy(.rosterGet, current))
        current.loading = true
        current.crew.loading = true
        XCTAssertTrue(companionBusy(.rosterGet, current))
        XCTAssertTrue(companionBusy(.linksList, current))
        XCTAssertFalse(companionBusy(.rosterPut, current))
    }
}

private struct LinksProbe: Decodable { var links: [CrewLink] }

@MainActor
final class CompanionModelTests: XCTestCase {
    func testLiveChannelUntilTheHostSaysUnsupported() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = CompanionModel(browse: harness.browse)
        XCTAssertTrue(model.available, "the core's companion channel is used by default")

        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterGet] = [.fail(.unsupported)]
        CompanionModel.makeRPC = { _, _ in rpc }
        defer { CompanionModel.makeRPC = CompanionModel.liveRPC }
        let next = CompanionModel(browse: harness.browse)
        XCTAssertTrue(next.available)
        await next.refresh()
        XCTAssertFalse(next.available, "an old host keeps the classic Home")
        await harness.close()
    }

    func testRefreshLoadsRosterAndCrew() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let rpc = FakeCompanionRPC()
        rpc.replies[.rosterGet] = [.ok(wireRoster)]
        rpc.replies[.linksList] = [.ok(#"{"links":[{"link_id":"1","workspace_id":"ws-x","local_thread_id":"t1","title":"Build","status":"running"}]}"#)]
        CompanionModel.makeRPC = { _, _ in rpc }
        defer { CompanionModel.makeRPC = CompanionModel.liveRPC }
        let model = CompanionModel(browse: harness.browse)
        await model.refresh()
        XCTAssertEqual(model.active?.name, "Wren")
        XCTAssertEqual(model.conversation?.workspace, "ws-2")
        XCTAssertEqual(model.conversation?.thread, "chat-1")
        XCTAssertEqual(model.crew.map(\.local_thread_id), ["t1"])
        await harness.close()
    }
}

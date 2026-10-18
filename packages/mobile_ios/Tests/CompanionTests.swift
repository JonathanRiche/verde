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
        XCTAssertEqual(Set(companions[0].keys), ["id", "name", "character", "home_workspace_id", "thread_id", "provider", "model", "orders", "history"])
    }
}

final class CompanionConflictTests: XCTestCase {
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

/// The core adapter's mapping from a settled companion intent + `companion` view to RPC replies.
final class CompanionCoreReplyTests: XCTestCase {
    private func view(_ json: String) throws -> CompanionViewState { try JSONDecoder().decode(CompanionViewState.self, from: Data(json.utf8)) }
    private func op(_ state: String, code: String? = nil, rpc: String? = nil) -> CoreOperation {
        CoreOperation(intent_id: "i", state: state, error: code.map { LocalError(domain: "companion", code: $0, message: "m", rpc_code: rpc) })
    }
    private let loaded = """
    {"loaded":true,"loading":false,"saving":false,"supported":true,"can_edit":true,"revision":"7",
     "roster":{"version":1,"active_id":"b","companions":[{"id":"b","name":"Wren","character":"vireo","home_workspace_id":"ws-2","thread_id":"chat-1"}]},
     "crew":{"workspace_id":"ws-2","thread_id":"chat-1","links":[{"link_id":"1","workspace_id":"ws-x","local_thread_id":"t1","status":"running"}],"loaded":true,"loading":false}}
    """

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
}

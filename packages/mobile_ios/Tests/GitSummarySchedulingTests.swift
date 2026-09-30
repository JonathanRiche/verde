import XCTest
import SwiftUI
@testable import VerdeApp

private func request(_ id: String, method: String, generation: String = "1") -> Effect {
    .http_request(EffectHttpRequest(effect_id: id, generation: generation, method: "POST",
        url: "https://fixture.invalid/api/rpc", headers: [],
        body_base64: Data("{\"method\":\"\(method)\"}".utf8).base64EncodedString(),
        timeout_ms: 15000, max_response_bytes: 1024,
        tls: Tls(origin: "https://fixture.invalid", spki_sha256: String(repeating: "a", count: 64))))
}
private func response(_ id: String, generation: String = "1") -> Event {
    .http_response(EventHttpResponse(now_ms: -1, wall_time_ms: -1, effect_id: id, generation: generation,
        status: 200, headers: [], body_base64: "e30=", error: nil))
}
private final class SummaryProbeCore: HostCore {
    let events = EventLog()
    var initial: [Effect] = []
    func handle(_ bytes: Data) throws -> Data {
        events.append(try JSONDecoder().decode(Event.self, from: bytes))
        let effects = initial; initial = []
        return try encoded(EffectBatch(api_version: 1, revision: "1", effects: effects))
    }
    func query(_ selector: String) throws -> Data {
        try encoded(HostsQuery(api_version: 1, revision: "1", data: HostsView(items: [
            hostView("alpha", "Alpha", lifecycle: .foreground, sync: "ready")
        ], operations: []), error: nil))
    }
    func close() {}
}
private final class SummaryProbeTransport: CoreTransport {
    func execute(_ effect: Effect, emit: @escaping (Event) -> Void) {
        if case .http_request(let r) = effect { emit(response(r.effect_id, generation: r.generation)) }
    }
    func stop() {}
}

final class GitSummarySchedulingTests: XCTestCase {
    func testOnlySummaryCompletionsAreDeferredAndCancellationClearsThem() throws {
        var queue = CoreSummaryQueue()
        queue.track(request("summary", method: "git.changes.summary"))
        queue.track(request("chat", method: "chat.thread.get"))
        queue.track(request("commit", method: "git.changes.commit"))
        XCTAssertFalse(queue.deferResponse(response("summary", generation: "old")))
        XCTAssertTrue(queue.deferResponse(response("summary")))
        XCTAssertFalse(queue.deferResponse(response("chat")))
        XCTAssertFalse(queue.deferResponse(response("commit")))
        XCTAssertFalse(queue.deferResponse(.background(EventBackground(now_ms: 0, wall_time_ms: 0))))
        XCTAssertFalse(queue.isEmpty)
        queue.track(.http_cancel(EffectHttpCancel(effect_id: "cancel", generation: "1", request_id: "summary")))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.pop())
        queue.track(request("second", method: "git.changes.summary"))
        XCTAssertTrue(queue.deferResponse(response("second")))
        queue.clear()
        XCTAssertNil(queue.pop())
        XCTAssertFalse(queue.deferResponse(response("second")))
    }

    @MainActor
    func testChatResponsePassesQueuedSummariesAndClocksAreStampedAtDelivery() async throws {
        let core = SummaryProbeCore()
        core.initial = (0..<20).map { request("summary-\($0)", method: "git.changes.summary") }
            + [request("chat", method: "chat.thread.get")]
        let host = CoreHost(core: core, store: CoreViewStore(), transport: SummaryProbeTransport(), storage: MemoryStorage())
        try await host.send(.start(EventStart(now_ms: 0, wall_time_ms: 0, foreground: true, network_available: true)))
        try await waitUntil("all responses delivered exactly once") {
            core.events.count { if case .http_response = $0 { return true }; return false } == 21
        }
        let responses = core.events.all.compactMap { if case .http_response(let value) = $0 { return value }; return nil }
        XCTAssertEqual(responses.first?.effect_id, "chat")
        XCTAssertEqual(responses.dropFirst().map(\.effect_id), (0..<20).map { "summary-\($0)" })
        XCTAssertEqual(responses.map(\.now_ms), responses.map(\.now_ms).sorted())
        XCTAssertTrue(responses.allSatisfy { $0.now_ms > 0 && $0.wall_time_ms > 0 })
        try await host.shutdown()
    }

    @MainActor
    func testDrawingBackgroundChatDotsDoesNotSubscribeToWorkspaces() async throws {
        let storage = MemoryStorage()
        storage.set(HostsModel.catalogKey, try encoded(HostCatalog(hosts: [SavedHost(id: "alpha", label: "Alpha")], active: "alpha")))
        let core = SummaryProbeCore()
        core.initial = [.state_changed(EffectStateChanged(effect_id: "state", generation: "1", revision: "1", scopes: ["hosts"]))]
        let hosts = HostsModel(storage: storage, cache: nil, deviceLabel: "Fixture") { _, store in
            CoreHost(core: core, store: store, transport: NullTransport(), storage: storage)
        }
        let browse = BrowseModel(hosts: hosts)
        hosts.foreground(true); hosts.begin()
        try await waitUntil("fixture session started") { !hosts.loading && browse.session?.host != nil }
        let controller = UIHostingController(rootView: VStack {
            ForEach(0..<8) { i in GitThreadDot(browse: browse, workspace: "workspace-\(i)", thread: "thread-\(i)") }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(core.events.count { if case .git_summary_refresh = $0 { return true }; return false }, 0)
        window.isHidden = true; window.rootViewController = nil
        await hosts.close()
    }
}

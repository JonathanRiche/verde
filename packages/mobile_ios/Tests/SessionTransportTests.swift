import XCTest
@testable import VerdeApp

final class SessionTransportTests: XCTestCase {
    private func request(limit: UInt32 = 4) -> Effect {
        .http_request(EffectHttpRequest(effect_id: "request", generation: "9007199254740993",
            method: "POST", url: "https://bridge.invalid/api/rpc", headers: [], body_base64: nil,
            timeout_ms: 35000, max_response_bytes: limit,
            tls: Tls(origin: "https://bridge.invalid", spki_sha256: "fixture")))
    }

    func testHTTPBytesStatusRedirectAndSingleCompletion() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://bridge.invalid/api/rpc"))
        // Never resume: drive the actual delegate without network services.
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        var events: [Event] = []
        let operation = SessionOperation(effect: request(), queue: DispatchQueue(label: "http.fixture"), emit: { events.append($0) }, ended: {})
        operation.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: url)) { XCTAssertNil($0) }
        operation.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        operation.urlSession(session, dataTask: task, didReceive: Data([0, 255]))
        operation.urlSession(session, task: task, didCompleteWithError: nil)
        operation.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        XCTAssertEqual(events.count, 1)
        guard case .http_response(let event) = events.first else { return XCTFail() }
        XCTAssertEqual(event.status, 403)
        XCTAssertEqual(event.body_base64, Data([0, 255]).base64EncodedString())
        XCTAssertEqual(event.generation, "9007199254740993")
        XCTAssertNil(event.error)
    }

    func testHTTPStreamingLimitAndCancellation() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://bridge.invalid/api/rpc"))
        let task = session.dataTask(with: url)
        for cancel in [false, true] {
            var events: [Event] = []
            let operation = SessionOperation(effect: request(), queue: DispatchQueue(label: "http.fixture"), emit: { events.append($0) }, ended: {})
            if cancel { operation.cancel() }
            else {
                operation.urlSession(session, dataTask: task, didReceive: Data([1, 2, 3]))
                operation.urlSession(session, dataTask: task, didReceive: Data([4, 5]))
            }
            operation.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(events.count, 1)
            guard case .http_response(let event) = events.first else { return XCTFail() }
            XCTAssertNil(event.status); XCTAssertNil(event.body_base64)
            XCTAssertEqual(event.error?.code, cancel ? .cancelled : .resource)
        }
    }

    func testWebSocketOpenAndCloseDelegate() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "wss://bridge.invalid/ws"))
        let task = session.webSocketTask(with: url, protocols: ["verde.v1", "verde.ticket.fixture"])
        let effect = Effect.ws_open(EffectWsOpen(effect_id: "socket", generation: "2", url: url.absoluteString,
            protocols: ["verde.v1", "verde.ticket.fixture"], tls: Tls(origin: "https://bridge.invalid", spki_sha256: "pin"), max_message_bytes: 4))
        var events: [Event] = []
        let operation = SessionOperation(effect: effect, queue: DispatchQueue(label: "ws.fixture"), emit: { events.append($0) }, ended: {})
        operation.urlSession(session, webSocketTask: task, didOpenWithProtocol: "verde.v1")
        operation.urlSession(session, webSocketTask: task, didCloseWith: .normalClosure, reason: Data("never exposed".utf8))
        operation.cancel()
        XCTAssertEqual(events.count, 2)
        guard case .ws_open(let opened) = events[0], case .ws_closed(let closed) = events[1] else { return XCTFail() }
        XCTAssertEqual(opened.protocol, "verde.v1"); XCTAssertEqual(opened.socket_id, "socket")
        XCTAssertTrue(closed.clean); XCTAssertEqual(closed.code, 1000)
    }
}

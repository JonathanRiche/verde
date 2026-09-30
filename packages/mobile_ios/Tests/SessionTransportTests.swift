import XCTest
@testable import VerdeApp

final class SessionTransportTests: XCTestCase {
    func testSocketLifetimeIsIndependentOfShortRequestDeadlines() {
        let socket = Effect.ws_open(EffectWsOpen(effect_id: "socket", generation: "2",
            url: "wss://bridge.invalid/ws", protocols: ["verde.v1"],
            tls: Tls(origin: "https://bridge.invalid", spki_sha256: String(repeating: "a", count: 64)), max_message_bytes: 1024))
        let config = SessionOperation.configuration(for: socket)
        // A healthy feed must survive the 15-minute access-token lifetime;
        // reusing the probe's 30-second resource deadline closed live sockets.
        XCTAssertGreaterThan(config.timeoutIntervalForResource, 15 * 60)
        XCTAssertEqual(config.timeoutIntervalForRequest, 30)
        let http = SessionOperation.configuration(for: request())
        XCTAssertEqual(http.timeoutIntervalForRequest, 35)
        XCTAssertEqual(http.timeoutIntervalForResource, 35)
        XCTAssertEqual(SessionOperation.configuration().timeoutIntervalForResource, 30)
    }

    func testHTTPPoolReusesExactPolicyAndEvictsOnTrustChange() {
        let queue = DispatchQueue(label: "pool.policy.fixture")
        queue.sync {
            let pool = HTTPConnectionPool(queue: queue)
            defer { pool.close() }
            let origin = "https://bridge.invalid", pin = String(repeating: "a", count: 64)
            let first = pool.connection(origin: origin, pin: pin)
            XCTAssertTrue(first === pool.connection(origin: origin, pin: pin))
            var events: [Event] = []
            let pending = SessionOperation(effect: request(), queue: queue, pool: pool, emit: { events.append($0) }, ended: {})
            pending.start(resume: false)
            let changedPin = pool.connection(origin: origin, pin: String(repeating: "b", count: 64))
            XCTAssertFalse(first === changedPin)
            XCTAssertTrue(first.closed)
            XCTAssertNil(pending.task)
            XCTAssertEqual(events.count, 1)
            guard case .http_response(let cancelled) = events.first else { return XCTFail() }
            XCTAssertEqual(cancelled.error?.code, .cancelled)
            let changedOrigin = pool.connection(origin: "https://other.invalid", pin: changedPin.pin)
            XCTAssertTrue(changedPin.closed)
            XCTAssertFalse(changedOrigin === changedPin)
            let restored = pool.connection(origin: origin, pin: pin)
            XCTAssertTrue(changedOrigin.closed)
            XCTAssertFalse(restored === first, "An old trusted connection cannot be resurrected")
        }
    }

    func testSharedHTTPRequestsRouteIndependentlyAndSurviveSiblingCancellation() throws {
        let queue = DispatchQueue(label: "pool.routing.fixture")
        try queue.sync {
            let pool = HTTPConnectionPool(queue: queue)
            defer { pool.close() }
            var firstEvents: [Event] = [], secondEvents: [Event] = []
            let first = SessionOperation(effect: request(), queue: queue, pool: pool, emit: { firstEvents.append($0) }, ended: {})
            let second = SessionOperation(effect: request(), queue: queue, pool: pool, emit: { secondEvents.append($0) }, ended: {})
            first.start(resume: false); second.start(resume: false)
            let connection = pool.connection(origin: "https://bridge.invalid", pin: String(repeating: "a", count: 64))
            let task = try XCTUnwrap(second.task as? URLSessionDataTask)
            first.cancel()
            XCTAssertFalse(connection.closed)
            XCTAssertEqual(firstEvents.count, 1)
            XCTAssertTrue(secondEvents.isEmpty)
            let response = try XCTUnwrap(HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            connection.urlSession(connection.session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
            connection.urlSession(connection.session, dataTask: task, didReceive: Data([1, 2]))
            connection.urlSession(connection.session, task: task, didCompleteWithError: nil)
            connection.urlSession(connection.session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(secondEvents.count, 1)
            guard case .http_response(let result) = secondEvents.first else { return XCTFail() }
            XCTAssertEqual(result.status, 200)
            XCTAssertEqual(result.body_base64, Data([1, 2]).base64EncodedString())
            XCTAssertFalse(connection.closed)
            XCTAssertTrue(connection === pool.connection(origin: connection.origin, pin: connection.pin))
        }
    }

    func testProbeNetworkFailureIsNotACertificateRejection() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://bridge.invalid")!)
        for code in [URLError.timedOut, .networkConnectionLost, .serverCertificateUntrusted] {
            var events: [Event] = []
            let effect = Effect.tls_probe(EffectTlsProbe(effect_id: "probe", generation: "1", origin: "https://bridge.invalid"))
            let operation = SessionOperation(effect: effect, queue: DispatchQueue(label: "probe.fixture"), emit: { events.append($0) }, ended: {})
            operation.urlSession(session, task: task, didCompleteWithError: URLError(code))
            operation.cancel()
            XCTAssertEqual(events.count, 1)
            guard case .tls_peer(let peer) = events.first else { return XCTFail() }
            XCTAssertEqual(peer.error?.kind, code == .serverCertificateUntrusted ? .tls : code == .timedOut ? .timeout : .network)
            XCTAssertFalse(peer.system_trusted)
            XCTAssertEqual(peer.spki_sha256, "")
        }
    }

    func testPooledRequestPreservesLongCoreDeadline() throws {
        let queue = DispatchQueue(label: "deadline.fixture")
        let pool = HTTPConnectionPool(queue: queue)
        defer { pool.close() }
        guard case .http_request(var value) = request() else { return XCTFail() }
        value.timeout_ms = 120000
        let operation = SessionOperation(effect: .http_request(value), queue: queue, pool: pool, emit: { _ in }, ended: {})
        operation.start(resume: false)
        defer { operation.cancel() }
        XCTAssertEqual(try XCTUnwrap(operation.task?.originalRequest).timeoutInterval, 120)
        let connection = pool.connection(origin: value.tls.origin, pin: value.tls.spki_sha256)
        XCTAssertGreaterThan(connection.session.configuration.timeoutIntervalForResource, 120)
    }

    private func request(limit: UInt32 = 4) -> Effect {
        .http_request(EffectHttpRequest(effect_id: "request", generation: "9007199254740993",
            method: "POST", url: "https://bridge.invalid/api/rpc", headers: [], body_base64: nil,
            timeout_ms: 35000, max_response_bytes: limit,
            tls: Tls(origin: "https://bridge.invalid", spki_sha256: String(repeating: "a", count: 64))))
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
            protocols: ["verde.v1", "verde.ticket.fixture"], tls: Tls(origin: "https://bridge.invalid", spki_sha256: String(repeating: "a", count: 64)), max_message_bytes: 4))
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
    func testEmptyServerCloseCompletesOnceWithoutEchoingReservedCode() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "wss://bridge.invalid/ws"))
        let task = session.webSocketTask(with: url)
        let effect = Effect.ws_open(EffectWsOpen(effect_id: "socket", generation: "2", url: url.absoluteString,
            protocols: ["verde.v1"], tls: Tls(origin: "https://bridge.invalid", spki_sha256: String(repeating: "a", count: 64)), max_message_bytes: 4))
        var events: [Event] = []
        var ended = 0
        let operation = SessionOperation(effect: effect, queue: DispatchQueue(label: "ws.empty-close"), emit: { events.append($0) }, ended: { ended += 1 })
        operation.urlSession(session, webSocketTask: task, didCloseWith: .noStatusReceived, reason: nil)
        operation.cancel()
        operation.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(events.count, 1)
        guard case .ws_closed(let closed) = events.first else { return XCTFail() }
        XCTAssertEqual(closed.code, 1005)
        XCTAssertTrue(closed.clean)
        XCTAssertNil(closed.error)
    }

}

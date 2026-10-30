import UIKit
import XCTest
@testable import VerdeApp

final class LiveAudioHoldsTests: XCTestCase {
    func testOldTeardownKeepsTheSessionForTheNextCall() {
        var holds = LiveAudioHolds()
        holds.request(1)
        XCTAssertTrue(holds.acquire(1))
        holds.activated(1, ok: true)
        XCTAssertTrue(holds.mayRun(1))
        holds.end(1)
        XCTAssertFalse(holds.mayRun(1), "an ended call never starts its engine")
        holds.request(2) // Start again before the old release has run.
        XCTAssertFalse(holds.release(1), "the queued call keeps the session")
        XCTAssertTrue(holds.active)
        XCTAssertTrue(holds.acquire(2))
        holds.activated(2, ok: true)
        XCTAssertTrue(holds.mayRun(2))
        holds.end(2)
        XCTAssertTrue(holds.release(2))
        XCTAssertEqual(holds, LiveAudioHolds())
    }

    func testCallEndedBeforeItsAcquireRunsIsSkipped() {
        var holds = LiveAudioHolds()
        holds.request(1)
        holds.end(1)
        XCTAssertFalse(holds.acquire(1))
        XCTAssertFalse(holds.mayRun(1))
        XCTAssertFalse(holds.release(1), "never activated, nothing to deactivate")
        XCTAssertEqual(holds, LiveAudioHolds())
    }

    func testEndedQueuedCallDoesNotKeepTheSession() {
        var holds = LiveAudioHolds()
        holds.request(1)
        XCTAssertTrue(holds.acquire(1))
        holds.activated(1, ok: true)
        holds.request(2)
        holds.end(2)
        holds.end(1)
        XCTAssertTrue(holds.release(1))
        XCTAssertFalse(holds.acquire(2))
        XCTAssertFalse(holds.release(2))
        XCTAssertEqual(holds, LiveAudioHolds())
    }

    func testReleaseWhileAnotherCallHoldsKeepsTheSession() {
        var holds = LiveAudioHolds()
        holds.request(1)
        holds.request(2)
        XCTAssertTrue(holds.acquire(1))
        holds.activated(1, ok: true)
        XCTAssertTrue(holds.acquire(2))
        holds.activated(2, ok: true)
        holds.end(1)
        XCTAssertFalse(holds.release(1))
        XCTAssertTrue(holds.mayRun(2))
        holds.end(2)
        XCTAssertTrue(holds.release(2))
    }

    func testFailedActivationNeverRuns() {
        var holds = LiveAudioHolds()
        holds.request(1)
        XCTAssertTrue(holds.acquire(1))
        holds.activated(1, ok: false)
        XCTAssertFalse(holds.mayRun(1))
        holds.end(1)
        XCTAssertFalse(holds.release(1))
        XCTAssertEqual(holds, LiveAudioHolds())
    }
}

final class LiveAudioSessionTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class FakeEngine: LiveAudioEngine, @unchecked Sendable {
        let name: String
        let log: Log
        var fails = false
        /// Signalled when start begins; start waits for `proceed` when set.
        var started: DispatchSemaphore?
        var proceed: DispatchSemaphore?
        init(_ name: String, _ log: Log) { self.name = name; self.log = log }
        func start(inputRate: Double) throws {
            started?.signal()
            proceed?.wait()
            log.add("start \(name)")
            if fails { throw LiveVoiceError.failed("audio") }
        }
        func stop() { log.add("stop \(name)") }
    }

    private func makeSession(_ log: Log, queue: DispatchQueue, activationFails: Bool = false) -> LiveAudioSession {
        LiveAudioSession(backend: .init(activate: {
            log.add("activate")
            if activationFails { throw LiveVoiceError.failed("audio") }
        }, deactivate: { log.add("deactivate") }), queue: queue)
    }

    func testRapidEndStartEndSkipsAllAudioWork() {
        let log = Log()
        let queue = DispatchQueue(label: "live-audio-test")
        let session = makeSession(log, queue: queue)
        let done = expectation(description: "both calls released")
        queue.suspend()
        let first = session.begin()
        session.run(FakeEngine("a", log), token: first, inputRate: 24000) { ok in log.add("ran a \(ok)") }
        session.finish(first)
        let second = session.begin()
        session.run(FakeEngine("b", log), token: second, inputRate: 24000) { ok in log.add("ran b \(ok)") }
        session.finish(second) { done.fulfill() }
        queue.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(log.all, ["ran a false", "ran b false"])
    }

    func testOldTeardownNeverStopsOrDeactivatesTheNewerCall() {
        let log = Log()
        let queue = DispatchQueue(label: "live-audio-test")
        let session = makeSession(log, queue: queue)
        let first = session.begin()
        let ranFirst = expectation(description: "first call started")
        session.run(FakeEngine("a", log), token: first, inputRate: 24000) { ok in log.add("ran a \(ok)"); ranFirst.fulfill() }
        wait(for: [ranFirst], timeout: 5)

        let ranSecond = expectation(description: "second call started")
        queue.suspend()
        session.finish(first)
        let second = session.begin()
        session.run(FakeEngine("b", log), token: second, inputRate: 16000) { ok in log.add("ran b \(ok)"); ranSecond.fulfill() }
        queue.resume()
        wait(for: [ranSecond], timeout: 5)
        XCTAssertEqual(log.all, ["activate", "start a", "ran a true", "stop a", "activate", "start b", "ran b true"])

        let released = expectation(description: "second call released")
        session.finish(second) { released.fulfill() }
        wait(for: [released], timeout: 5)
        XCTAssertEqual(Array(log.all.suffix(2)), ["stop b", "deactivate"])
    }

    func testEndingDuringEngineStartStopsItAndDeactivates() {
        let log = Log()
        let queue = DispatchQueue(label: "live-audio-test")
        let session = makeSession(log, queue: queue)
        let engine = FakeEngine("a", log)
        engine.started = DispatchSemaphore(value: 0)
        engine.proceed = DispatchSemaphore(value: 0)
        let token = session.begin()
        session.run(engine, token: token, inputRate: 24000) { ok in log.add("ran a \(ok)") }
        XCTAssertEqual(engine.started?.wait(timeout: .now() + 5), .success)
        let released = expectation(description: "released")
        session.finish(token) { released.fulfill() }
        engine.proceed?.signal()
        wait(for: [released], timeout: 5)
        XCTAssertEqual(log.all, ["activate", "start a", "ran a true", "stop a", "deactivate"])
    }

    func testFailedActivationReportsAndNeverStartsTheEngine() {
        let log = Log()
        let queue = DispatchQueue(label: "live-audio-test")
        let session = makeSession(log, queue: queue, activationFails: true)
        let token = session.begin()
        let ran = expectation(description: "ran")
        session.run(FakeEngine("a", log), token: token, inputRate: 24000) { ok in log.add("ran a \(ok)"); ran.fulfill() }
        wait(for: [ran], timeout: 5)
        let released = expectation(description: "released")
        session.finish(token) { released.fulfill() }
        wait(for: [released], timeout: 5)
        XCTAssertEqual(log.all, ["activate", "ran a false"])
    }

    func testFailedEngineStartReportsAndReleasesTheSession() {
        let log = Log()
        let queue = DispatchQueue(label: "live-audio-test")
        let session = makeSession(log, queue: queue)
        let engine = FakeEngine("a", log)
        engine.fails = true
        let token = session.begin()
        let ran = expectation(description: "ran")
        session.run(engine, token: token, inputRate: 24000) { ok in log.add("ran a \(ok)"); ran.fulfill() }
        wait(for: [ran], timeout: 5)
        let released = expectation(description: "released")
        session.finish(token) { released.fulfill() }
        wait(for: [released], timeout: 5)
        XCTAssertEqual(log.all, ["activate", "start a", "ran a false", "deactivate"])
    }
}

@MainActor final class LiveCallBarWindowTests: XCTestCase {
    func testOnlyTheBarTakesTouchesAndTheWindowNeverBecomesKey() {
        let window = LiveCallBarWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.accessibilityViewIsModal)
        XCTAssertNil(window.hitTest(CGPoint(x: 100, y: 400), with: nil), "nothing to hit before the bar is measured")
        window.touchRect = CGRect(x: 0, y: 59, width: 390, height: 56)
        XCTAssertNil(window.hitTest(CGPoint(x: 100, y: 400), with: nil), "touches below the bar reach the app")
        XCTAssertNil(window.hitTest(CGPoint(x: 100, y: 20), with: nil), "and so do touches above it")
    }
}

/// A Live call keeps going while verde is in the background, like a phone call.
final class LiveBackgroundTests: XCTestCase {
    func testAppDeclaresBackgroundAudio() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertEqual(modes, ["audio"])
    }
}

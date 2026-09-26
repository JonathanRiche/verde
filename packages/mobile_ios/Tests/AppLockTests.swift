import SwiftUI
import XCTest
@testable import VerdeApp

@MainActor final class AppLockTests: XCTestCase {
    final class Auth: DeviceAuthenticating {
        var result = true
        var calls = 0
        func authenticate() async -> Bool { calls += 1; return result }
    }
    func testColdStartLocksAndFailedAuthenticationNeverRevealsContent() async throws {
        let store = MemoryStorage(), auth = Auth()
        try store.put("ios/1/app-lock", value: JSONEncoder().encode(LockSettings(enabled: true)))
        let lock = AppLock(storage: store, auth: auth)
        XCTAssertTrue(lock.covered)
        lock.load(); lock.phase(.active)
        XCTAssertTrue(lock.locked)
        auth.result = false; await lock.unlock()
        XCTAssertTrue(lock.covered)
        auth.result = true; await lock.unlock()
        XCTAssertFalse(lock.covered)
    }
    func testBackgroundTimeoutAndInactiveSystemPrompt() async throws {
        let store = MemoryStorage(), auth = Auth()
        var clock: TimeInterval = 100
        try store.put("ios/1/app-lock", value: JSONEncoder().encode(LockSettings(enabled: true, timeout: 60)))
        let lock = AppLock(storage: store, auth: auth, now: { clock })
        lock.load(); lock.phase(.active); await lock.unlock()
        lock.phase(.inactive); clock += 120; lock.phase(.active)
        XCTAssertFalse(lock.locked) // System prompts don't count as background.
        lock.phase(.background); XCTAssertTrue(lock.covered)
        clock += 59; lock.phase(.active); XCTAssertFalse(lock.locked)
        lock.phase(.background); clock += 60; lock.phase(.active); XCTAssertTrue(lock.locked)
    }
    func testEnableRequiresAuthenticationAndStorageFailureKeepsOldSettings() async {
        let store = MemoryStorage(), auth = Auth()
        let lock = AppLock(storage: store, auth: auth)
        lock.load(); lock.phase(.active)
        auth.result = false; await lock.update(LockSettings(enabled: true))
        XCTAssertFalse(lock.settings.enabled)
        auth.result = true; store.fail(write: true); await lock.update(LockSettings(enabled: true))
        XCTAssertFalse(lock.settings.enabled)
        store.fail(); await lock.update(LockSettings(enabled: true, timeout: 0))
        XCTAssertTrue(lock.settings.enabled)
        lock.phase(.background); XCTAssertTrue(lock.locked)
    }
    func testKeychainReadFailureFailsClosedThenRetryRecovers() {
        let store = MemoryStorage(); store.fail(read: true)
        let lock = AppLock(storage: store, auth: Auth())
        lock.load(); lock.phase(.active)
        XCTAssertTrue(lock.covered); XCTAssertFalse(lock.loaded)
        store.fail(); lock.load()
        XCTAssertFalse(lock.covered); XCTAssertTrue(lock.loaded)
    }
}

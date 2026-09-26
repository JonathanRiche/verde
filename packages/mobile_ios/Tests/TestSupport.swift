import XCTest
@testable import VerdeApp

/// Thread-safe in-memory SecureStorage with injectable failures.
final class MemoryStorage: SecureStorage {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var deleted: [String] = []
    private var failures: (read: Bool, write: Bool, delete: Bool) = (false, false, false)

    var values: [String: Data] { lock.lock(); defer { lock.unlock() }; return storage }
    var deletes: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
    func set(_ key: String, _ value: Data?) { lock.lock(); storage[key] = value; lock.unlock() }
    func fail(read: Bool = false, write: Bool = false, delete: Bool = false) {
        lock.lock(); failures = (read, write, delete); lock.unlock()
    }

    func get(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failures.read { throw StorageError(code: .locked) }
        return storage[key]
    }
    func put(_ key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failures.write { throw StorageError(code: .locked) }
        storage[key] = value
    }
    func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failures.delete { throw StorageError(code: .locked) }
        storage.removeValue(forKey: key)
        deleted.append(key)
    }
}

/// Records events for assertions; the fake cores append from the CoreHost actor.
final class EventLog {
    private let lock = NSLock()
    private var items: [Event] = []
    func append(_ event: Event) { lock.lock(); items.append(event); lock.unlock() }
    var all: [Event] { lock.lock(); defer { lock.unlock() }; return items }
    func count(_ match: (Event) -> Bool) -> Int { all.filter(match).count }
    var kinds: [String] {
        all.map { event in
            switch event {
            case .start: return "start"
            case .foreground: return "foreground"
            case .background: return "background"
            case .network_changed: return "network_changed"
            case .retry_connection: return "retry_connection"
            case .sign_out: return "sign_out"
            case .forget_host: return "forget_host"
            default: return "other"
            }
        }.filter { $0 != "other" }
    }
}

@MainActor
func waitUntil(_ message: String = "condition", timeout: TimeInterval = 5,
               file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), "deadline: \(message)", file: file, line: line)
}

func hostView(_ id: String, _ label: String, phase: String = "ready", lifecycle: Lifecycle = .background,
              auth: String = "paired", sync: String = "empty") -> HostView {
    HostView(host_id: id, label: label, https_url: nil, runtime_id: nil, instance_id: nil, phase: phase,
             lifecycle: lifecycle, auth_state: auth, sync_state: sync, capabilities: [], scopes: [],
             retry_at_ms: nil, trust_proposal: nil, update_required: false, error: nil)
}

/// Real K-09 core projections (see Fixtures/k09-*.json and the Android fixture README).
enum K09 {
    private static func read<T: Decodable>(_ name: String) -> T {
        final class Marker {}
        guard let url = Bundle(for: Marker.self).url(forResource: "k09-\(name)", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) else {
            fatalError("missing k09 fixture")
        }
        return value
    }
    static var home: HomeQuery { read("home") }
    static var workspaces: WorkspacesQuery { read("workspaces") }
    static var homeLive: HomeQuery { read("home-live") }
    static var workspacesLive: WorkspacesQuery { read("workspaces-live") }
}

final class NullTransport: CoreTransport {
    func execute(_ effect: Effect, emit: @escaping (Event) -> Void) {}
    func stop() {}
}

func encoded<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

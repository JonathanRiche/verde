import Foundation
import Observation
import VerdeClient

/// Injectable `vc_term_*` boundary. Implementations never put grid contents or
/// bytes in errors or logs.
protocol TerminalBridge: AnyObject {
    func create(_ config: Data) throws -> OpaquePointer
    func write(_ term: OpaquePointer, _ bytes: Data) -> Int32
    func resize(_ term: OpaquePointer, cols: UInt16, rows: UInt16) -> Int32
    func scroll(_ term: OpaquePointer, _ deltaRows: Int32) -> Int32
    func snapshot(_ term: OpaquePointer) throws -> Data
    func free(_ term: OpaquePointer)
}

/// The linked core's VT (K-12). Each handle is only touched from its `TerminalVT` actor.
final class NativeTerminalBridge: TerminalBridge {
    static let shared = NativeTerminalBridge()

    func create(_ config: Data) throws -> OpaquePointer {
        var term: OpaquePointer?
        let status = config.withUnsafeBytes { vc_term_new($0.bindMemory(to: UInt8.self).baseAddress, config.count, &term) }
        guard status == 0, let term else { throw CoreBridgeError.status(status) }
        return term
    }
    func write(_ term: OpaquePointer, _ bytes: Data) -> Int32 {
        bytes.withUnsafeBytes { vc_term_write(term, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
    }
    func resize(_ term: OpaquePointer, cols: UInt16, rows: UInt16) -> Int32 { vc_term_resize(term, cols, rows) }
    func scroll(_ term: OpaquePointer, _ deltaRows: Int32) -> Int32 { vc_term_scroll(term, deltaRows) }
    func snapshot(_ term: OpaquePointer) throws -> Data {
        var output = vc_buf(ptr: nil, len: 0)
        defer { vc_buf_free(output) }
        let status = vc_term_snapshot(term, &output)
        guard status == 0, let pointer = output.ptr else { throw CoreBridgeError.status(status) }
        return Data(bytes: pointer, count: output.len)
    }
    func free(_ term: OpaquePointer) { vc_term_free(term) }
}

/// `terminal:<id>` with the core's percent-encoding (unreserved bytes pass through).
func terminalSelector(_ id: String) -> String {
    var out = "terminal:"
    for byte in id.utf8 {
        switch byte {
        case 0x41...0x5a, 0x61...0x7a, 0x30...0x39, 0x2d, 0x5f, 0x2e, 0x7e: out.append(Character(UnicodeScalar(byte)))
        default: out += String(format: "%%%02X", byte)
        }
    }
    return out
}

/// Outcome reported to the core as `terminal_applied`.
struct TerminalApplied: Equatable {
    var gridRevision: String
    var error: PlatformFailureCode?
}

/// Main-thread view of one VT: the latest grid and how often the emulator was rebuilt.
/// Updated in order through the main queue; never logged.
@Observable
final class TerminalFeed {
    /// Latest full grid; kept across transient failures so the last screen stays visible.
    fileprivate(set) var snapshot: TerminalSnapshot?
    /// Emulator resets (initial replay, gap/reconnect replay, apply-failure recovery).
    fileprivate(set) var resets = 0
}

/// One local VT handle on its own serialized executor (terminal.md). It never
/// kills the daemon session. Snapshots and device replies are content: never log them.
actor TerminalVT {
    static let defaultScrollbackRows: UInt32 = 2_000

    nonisolated let feed = TerminalFeed()
    private let bridge: TerminalBridge
    private let scrollbackRows: UInt32
    private let onReply: (Data) -> Void
    private var handle: OpaquePointer?
    private var cols: UInt16 = 0
    private var rows: UInt16 = 0
    private var writes = 0
    private var resets = 0
    private var latest: TerminalSnapshot?
    private var closed = false

    init(bridge: TerminalBridge, scrollbackRows: UInt32 = TerminalVT.defaultScrollbackRows,
         onReply: @escaping (Data) -> Void = { _ in }) {
        self.bridge = bridge
        self.scrollbackRows = scrollbackRows
        self.onReply = onReply
    }

    /// Routes one `terminal_output`: reset/recreate at the core's grid size, write once, publish.
    func apply(reset: Bool, bytes: Data, cols: UInt16, rows: UInt16) -> TerminalApplied {
        guard !closed else { return TerminalApplied(gridRevision: "0", error: .unavailable) }
        if reset || handle == nil {
            release()
            do {
                let config = try JSONEncoder().encode(TerminalConfig(cols: cols, rows: rows, scrollback_rows: scrollbackRows))
                handle = try bridge.create(config)
            } catch { return TerminalApplied(gridRevision: "0", error: .resource) }
            self.cols = cols
            self.rows = rows
            resets += 1
        } else if let handle, cols != self.cols || rows != self.rows,
                  bridge.resize(handle, cols: cols, rows: rows) == 0 {
            self.cols = cols
            self.rows = rows
        }
        guard let handle else { return TerminalApplied(gridRevision: "0", error: .unavailable) }
        let status = bridge.write(handle, bytes)
        guard status == 0 else {
            // A poisoned VT (terminal.md) is recreated on the core's next reset replay.
            release()
            return TerminalApplied(gridRevision: "0", error: status == 5 || status == 3 ? .resource : .io)
        }
        writes += 1
        let snapshot = publish()
        return TerminalApplied(gridRevision: snapshot?.revision ?? String(writes), error: nil)
    }

    /// Local emulator resize; the model separately asks the host for `session.resize`.
    func resize(cols: UInt16, rows: UInt16) {
        guard !closed, let handle, cols != self.cols || rows != self.rows,
              bridge.resize(handle, cols: cols, rows: rows) == 0 else { return }
        self.cols = cols
        self.rows = rows
        publish()
    }

    /// Positive rows move toward older history, negative toward the live bottom; the VT clamps.
    func scroll(_ deltaRows: Int32) {
        guard !closed, deltaRows != 0, let handle, bridge.scroll(handle, deltaRows) == 0 else { return }
        publish()
    }

    /// Latest decoded grid and reset count, for callers already on this executor's timeline.
    func current() -> (snapshot: TerminalSnapshot?, resets: Int) { (latest, resets) }

    func close() {
        closed = true
        release()
    }

    deinit {
        if let handle { bridge.free(handle) }
    }

    /// Snapshot drains device replies only after a successful output allocation.
    @discardableResult
    private func publish() -> TerminalSnapshot? {
        guard let handle, let data = try? bridge.snapshot(handle),
              let snapshot = try? JSONDecoder().decode(TerminalSnapshot.self, from: data) else { return nil }
        latest = snapshot
        let feed = self.feed
        let resets = self.resets
        // The main queue is FIFO, so screens see grids in the order the VT produced them.
        DispatchQueue.main.async {
            feed.snapshot = snapshot
            if feed.resets != resets { feed.resets = resets }
        }
        if !snapshot.reply_bytes_base64.isEmpty, let reply = Data(base64Encoded: snapshot.reply_bytes_base64) {
            onReply(reply)
        }
        return snapshot
    }

    private func release() {
        if let handle { bridge.free(handle) }
        handle = nil
    }
}

import UIKit
import XCTest
@testable import VerdeApp

private final class FixtureMarker {}

/// K-12 fixtures: `k12-tail.json` is the core's recorded daemon tail
/// (packages/client_core/src/fixtures/terminal/tail.json) and `k12-snapshot.json` the
/// committed real `vc_term_snapshot` for it (see the Android k12 fixture README).
enum K12 {
    private static func data(_ name: String) -> Data {
        guard let url = Bundle(for: FixtureMarker.self).url(forResource: "k12-\(name)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { fatalError("missing k12 fixture") }
        return data
    }
    static var tail: Data {
        let object = try? JSONSerialization.jsonObject(with: data("tail")) as? [String: Any]
        return Data(((object?["text"] as? String) ?? "").utf8)
    }
    static var snapshotData: Data { data("snapshot") }
    static var snapshot: TerminalSnapshot { try! JSONDecoder().decode(TerminalSnapshot.self, from: snapshotData) }
}

private func sameJSON(_ a: Data, _ b: Data) -> Bool {
    guard let x = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
          let y = try? JSONSerialization.jsonObject(with: b) as? NSDictionary else { return false }
    return x.isEqual(y)
}

private func cellsJSON(_ snapshot: TerminalSnapshot?) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return snapshot.flatMap { try? encoder.encode($0.cells) }
}

/// The real core VT with every call recorded (counts only; bytes are fixture data).
final class RecordingBridge: TerminalBridge {
    private let base = NativeTerminalBridge.shared
    private let lock = NSLock()
    private var _configs: [TerminalConfig] = []
    private var _writes: [Data] = []
    private var _resizes: [GridSize] = []
    private var _scrolls: [Int32] = []
    private var _live = 0
    private var _frees = 0

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var configs: [TerminalConfig] { locked { _configs } }
    var writes: [Data] { locked { _writes } }
    var resizes: [GridSize] { locked { _resizes } }
    var scrolls: [Int32] { locked { _scrolls } }
    var live: Int { locked { _live } }
    var frees: Int { locked { _frees } }

    func create(_ config: Data) throws -> OpaquePointer {
        let term = try base.create(config)
        let decoded = try JSONDecoder().decode(TerminalConfig.self, from: config)
        locked { _configs.append(decoded); _live += 1 }
        return term
    }
    func write(_ term: OpaquePointer, _ bytes: Data) -> Int32 { locked { _writes.append(bytes) }; return base.write(term, bytes) }
    func resize(_ term: OpaquePointer, cols: UInt16, rows: UInt16) -> Int32 {
        locked { _resizes.append(GridSize(cols: cols, rows: rows)) }
        return base.resize(term, cols: cols, rows: rows)
    }
    func scroll(_ term: OpaquePointer, _ deltaRows: Int32) -> Int32 { locked { _scrolls.append(deltaRows) }; return base.scroll(term, deltaRows) }
    func snapshot(_ term: OpaquePointer) throws -> Data { try base.snapshot(term) }
    func free(_ term: OpaquePointer) { locked { _live -= 1; _frees += 1 }; base.free(term) }
}

// MARK: - Real core VT (K-12)

final class TerminalVTTests: XCTestCase {
    func testRecordedTailMatchesTheCommittedSnapshotThroughTheCABI() throws {
        let bridge = NativeTerminalBridge.shared
        let term = try bridge.create(try encoded(TerminalConfig(cols: 20, rows: 4, scrollback_rows: 100)))
        defer { bridge.free(term) }
        XCTAssertEqual(bridge.write(term, K12.tail), 0)
        XCTAssertTrue(sameJSON(try bridge.snapshot(term), K12.snapshotData), "real VT snapshot drifted from fixtures/k12")
    }

    func testVTAppliesRendersAndSelectsTheFixture() async throws {
        let vt = TerminalVT(bridge: NativeTerminalBridge.shared)
        let applied = await vt.apply(reset: true, bytes: K12.tail, cols: 20, rows: 4)
        XCTAssertNil(applied.error)
        let (current, resets) = await vt.current()
        let snapshot = try XCTUnwrap(current)
        XCTAssertEqual(applied.gridRevision, snapshot.revision)
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(cellsJSON(snapshot), cellsJSON(K12.snapshot))
        XCTAssertTrue(snapshot.vt_modes.application_cursor && snapshot.vt_modes.bracketed_paste)

        let plan = renderPlan(snapshot)
        XCTAssertEqual(plan.cols, 20)
        XCTAssertEqual(plan.rows, 4)
        XCTAssertEqual(plan.background, 0x000000)
        let red = try XCTUnwrap(plan.texts.first)
        XCTAssertEqual([red.row, red.col], [0, 0])
        XCTAssertEqual(red.text, "RED")
        XCTAssertTrue(red.style.bold)
        XCTAssertEqual(red.style.fg, 0xCC6666)
        XCTAssertTrue(red.ascii)
        let wide = try XCTUnwrap(plan.texts.first { $0.text == "界" })
        XCTAssertEqual(wide.cells, 2)
        XCTAssertFalse(wide.ascii)
        XCTAssertEqual(plan.texts.filter { $0.row == 1 }.map(\.text), ["wide:", "界", "e\u{301}"])
        XCTAssertEqual(plan.cursor?.row, 2)
        XCTAssertEqual(plan.cursor?.col, 0)
        XCTAssertEqual(plan.cursor?.shape, .block)
        XCTAssertEqual(selectedText(snapshot, GridSelection(anchorRow: 1, anchorCol: 19, row: 0, col: 0)), "RED\nwide: 界 e\u{301}")
        await vt.close()
    }

    func testRepliesResizeScrollbackAndResetRoundTrip() async throws {
        let replies = EventLog()
        let vt = TerminalVT(bridge: NativeTerminalBridge.shared, scrollbackRows: 100) { bytes in
            replies.append(.terminal_reply(EventTerminalReply(now_ms: 0, wall_time_ms: 0, terminal_id: "t",
                bytes_base64: bytes.base64EncodedString())))
        }
        _ = await vt.apply(reset: true, bytes: K12.tail, cols: 20, rows: 4)
        // A cursor-position request is answered by the VT and drained with the snapshot.
        _ = await vt.apply(reset: false, bytes: Data("\u{1b}[6n".utf8), cols: 20, rows: 4)
        let sent = replies.all.compactMap { event -> String? in
            guard case .terminal_reply(let e) = event, let bytes = Data(base64Encoded: e.bytes_base64) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        XCTAssertEqual(sent, ["\u{1b}[3;1R"])
        await vt.resize(cols: 30, rows: 6)
        var state = await vt.current()
        var snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual([snapshot.cols, snapshot.rows], [30, 6])
        let lines = (1...40).map { "line \($0)\r\n" }.joined()
        _ = await vt.apply(reset: false, bytes: Data(lines.utf8), cols: 30, rows: 6)
        state = await vt.current()
        XCTAssertGreaterThan(try XCTUnwrap(state.snapshot).scrollback_rows, 0)
        await vt.scroll(3)
        state = await vt.current()
        snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.scroll_offset, 3)
        XCTAssertNil(renderPlan(snapshot).cursor, "no cursor while viewing history")
        await vt.scroll(-3)
        state = await vt.current()
        XCTAssertEqual(try XCTUnwrap(state.snapshot).scroll_offset, 0)
        // A reset replay recreates the emulator at the core's size.
        _ = await vt.apply(reset: true, bytes: K12.tail, cols: 20, rows: 4)
        state = await vt.current()
        XCTAssertEqual(state.resets, 2)
        XCTAssertEqual(cellsJSON(state.snapshot), cellsJSON(K12.snapshot))
        // The main-thread feed follows in order.
        let feed = vt.feed
        try await waitUntil("feed") { feed.resets == 2 && feed.snapshot?.cols == 20 }
        await vt.close()
        let closed = await vt.apply(reset: false, bytes: Data("x".utf8), cols: 20, rows: 4)
        XCTAssertEqual(closed.error, .unavailable)
    }

    func testSelectorsMatchTheCorePercentEncoding() {
        XCTAssertEqual(terminalSelector("sess-7"), "terminal:sess-7")
        XCTAssertEqual(terminalSelector("mobile:abc:1"), "terminal:mobile%3Aabc%3A1")
        XCTAssertEqual(terminalSelector("session:%2F/one"), "terminal:session%3A%252F%2Fone")
        XCTAssertEqual(terminalSelector("界"), "terminal:%E7%95%8C")
        XCTAssertEqual(terminalSelector("a.b~c_d"), "terminal:a.b~c_d")
    }
}

// MARK: - Pure rules

final class TerminalRulesTests: XCTestCase {
    func testHardwareKeysMapToCoreKeyNames() {
        XCTAssertEqual(hardwareKey(input: "\r", flags: []), .key("Enter"))
        XCTAssertEqual(hardwareKey(input: "\t", flags: .shift), .key("Tab", shift: true))
        XCTAssertEqual(hardwareKey(input: UIKeyCommand.inputPageDown, flags: []), .key("PageDown"))
        XCTAssertEqual(hardwareKey(input: UIKeyCommand.inputEscape, flags: []), .key("Escape"))
        XCTAssertEqual(hardwareKey(input: UIKeyCommand.inputUpArrow, flags: [.control, .alternate]), .key("ArrowUp", ctrl: true, alt: true))
        XCTAssertEqual(hardwareKey(input: UIKeyCommand.inputDelete, flags: .control), .key("Backspace", ctrl: true))
        XCTAssertEqual(hardwareKey(input: "\u{7f}", flags: []), .key("Delete"))
        XCTAssertEqual(hardwareKey(input: UIKeyCommand.inputHome, flags: []), .key("Home"))
        XCTAssertEqual(hardwareKey(input: "a", flags: []), .text("a"))
        XCTAssertEqual(hardwareKey(input: "a", flags: .shift), .text("A"))
        XCTAssertEqual(hardwareKey(input: "c", flags: .control), .key("c", ctrl: true))
        XCTAssertEqual(hardwareKey(input: "x", flags: .alternate), .key("x", alt: true))
        XCTAssertEqual(hardwareKey(input: "[", flags: .control), .key("[", ctrl: true))
        XCTAssertEqual(hardwareKey(input: " ", flags: .control), .key(" ", ctrl: true))
        XCTAssertNil(hardwareKey(input: "", flags: .shift))
    }

    func testEveryRegisteredKeyCommandMapsToInput() {
        let commands = terminalKeyCommands()
        XCTAssertTrue(commands.allSatisfy { hardwareKey(input: $0.input, flags: $0.flags) != nil })
        // Plain printable keys stay with the text system (IME and key repeat).
        XCTAssertFalse(commands.contains { command in
            let scalars = command.input.unicodeScalars
            return command.flags.isEmpty && scalars.count == 1 && scalars.first!.value >= 0x20 && scalars.first!.value != 0x7f
        })
        let unique = Set(commands.map { "\($0.input)|\($0.flags.rawValue)" })
        XCTAssertEqual(unique.count, commands.count, "duplicate key commands")
    }

    func testStickyModifiersAndNewlines() {
        XCTAssertEqual(withModifiers(.text("c"), ctrl: true, alt: false), [.key("c", ctrl: true)])
        XCTAssertEqual(withModifiers(.text("x"), ctrl: false, alt: true), [.key("x", alt: true)])
        XCTAssertEqual(withModifiers(.key("ArrowLeft"), ctrl: true, alt: true), [.key("ArrowLeft", ctrl: true, alt: true)])
        XCTAssertEqual(withModifiers(.text("ls\n"), ctrl: false, alt: false), [.text("ls"), .key("Enter")])
        XCTAssertEqual(withModifiers(.paste("a\nb"), ctrl: true, alt: false), [.paste("a\nb")], "paste keeps its newlines")
        XCTAssertEqual(withModifiers(.text("界"), ctrl: true, alt: false), [.text("界")])
        XCTAssertEqual(splitLines("a\r\nb\n\n"), [.text("a"), .key("Enter"), .text("b"), .key("Enter"), .key("Enter")])
        XCTAssertEqual(splitLines(""), [])
    }

    func testAccessoryKeysHaveLabelsAndCoreInputs() {
        XCTAssertEqual(accessoryKeys.map(\.accessibility), ["Escape", "Tab", "Left", "Down", "Up", "Right", "Pipe", "Tilde",
                                                             "Slash", "Dash", "Home", "End", "Page up", "Page down"])
        XCTAssertEqual(Set(accessoryKeys.map(\.label)).count, accessoryKeys.count)
    }

    func testGridSizeFitsTheViewWithinCoreLimits() {
        let metrics = CellMetrics(width: 8, height: 16, baseline: 12)
        XCTAssertEqual(terminalGrid(width: 390, height: 600, metrics: metrics), GridSize(cols: 48, rows: 37))
        XCTAssertEqual(terminalGrid(width: 1, height: 1, metrics: metrics), GridSize(cols: 1, rows: 1))
        let huge = terminalGrid(width: 100_000, height: 100_000, metrics: CellMetrics(width: 1, height: 1, baseline: 1))
        XCTAssertEqual(huge.rows, 512)
        XCTAssertLessThanOrEqual(Int(huge.cols) * Int(huge.rows), 65_536)
        let real = CellMetrics.monospaced(size: 14, scale: 3)
        XCTAssertGreaterThan(real.width, 5)
        XCTAssertEqual((real.width * 3).rounded(), real.width * 3, "cell width snaps to device pixels")
        XCTAssertGreaterThan(real.height, real.baseline)
    }

    func testColorsInverseAndBlankTrimming() {
        XCTAssertEqual(parseColor("#CC6666", 0), 0xCC6666)
        XCTAssertEqual(parseColor("red", 7), 7)
        XCTAssertEqual(parseColor("#12345", 7), 7)
        var snapshot = K12.snapshot
        snapshot.cells[0].inverse = true
        snapshot.cells[21].underline = true // "i" in "wide:"
        snapshot.cursor.visible = false
        let plan = renderPlan(snapshot)
        XCTAssertEqual(plan.backgrounds.first, BgRun(row: 0, col: 0, cells: 1, color: 0xCC6666))
        XCTAssertEqual(plan.texts.first?.style.fg, 0x000000)
        XCTAssertTrue(plan.texts.contains { $0.row == 1 && $0.text == "i" && $0.style.underline })
        XCTAssertFalse(plan.texts.contains { $0.text.hasPrefix(" ") || $0.text.hasSuffix(" ") })
        XCTAssertNil(plan.cursor)
    }

    func testNoticesFollowPriority() {
        func host(phase: String = "ready", scopes: [String] = ["terminal:read", "terminal:write"]) -> HostView {
            var view = hostView("alpha", "Studio", phase: phase)
            view.scopes = scopes
            return view
        }
        func state(_ view: HostView? = host(), network: Bool = true, fatal: Bool = false, id: String = "alpha") -> BrowseState {
            var state = BrowseState(hostID: id, row: view.map { HostRow(saved: SavedHost(id: "alpha", label: "Studio"), view: $0) })
            state.networkAvailable = network
            state.fatal = fatal
            return state
        }
        func terminal(_ status: String = "running", attached: Bool = true, stale: Bool = false, error: Bool = false) -> TerminalView {
            TerminalView(terminal_id: "sess-7", session_status: status, attached: attached, stale: stale,
                         error: error ? LocalError(code: "x", message: "m") : nil)
        }
        func notice(_ b: BrowseState, id: String? = "sess-7", view: TerminalView? = terminal(), gap: Bool = false,
                    failure: String? = nil) -> String? {
            terminalNotice(failure: failure, terminalID: id, view: view, replayGap: gap, browse: b, hostID: "alpha")
        }
        XCTAssertNil(notice(state()))
        XCTAssertEqual(notice(state(), failure: "Couldn't open this terminal."), "Couldn't open this terminal.")
        XCTAssertEqual(notice(state(id: "beta")), "This terminal belongs to another host. Switch hosts to use it.")
        XCTAssertEqual(notice(state(network: false)), "You're offline. Showing the last screen; input is paused.")
        XCTAssertEqual(notice(state(fatal: true)), "Connection unavailable — reopen Verde.")
        XCTAssertEqual(notice(state(host(phase: "connecting"))), "Reconnecting… Showing the last screen; input is paused.")
        XCTAssertEqual(notice(state(), id: nil, view: nil), "Opening a new terminal…")
        XCTAssertEqual(notice(state(), view: nil), "Opening terminal…")
        XCTAssertEqual(notice(state(), view: terminal("exited")), "The session has ended.")
        XCTAssertEqual(notice(state(), view: terminal("unknown")), "This terminal is no longer available.")
        XCTAssertEqual(notice(state(), view: terminal(attached: false, error: true)), "This terminal is no longer available.")
        XCTAssertEqual(notice(state(), view: terminal("starting")), "Starting shell…")
        XCTAssertEqual(notice(state(host(scopes: ["terminal:read"]))), "View only: this phone was paired without terminal access.")
        XCTAssertEqual(notice(state(), view: terminal(stale: true, error: true)), "Connection interrupted. Catching up…")
        XCTAssertEqual(notice(state(), gap: true), "Reconnected. Some earlier output may be missing.")
        XCTAssertEqual(notice(state(network: false), view: terminal("exited"), gap: true),
                       "You're offline. Showing the last screen; input is paused.")
    }
}

// MARK: - Grid view (UIKit)

@MainActor
final class TerminalGridViewTests: XCTestCase {
    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> UInt32 {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cgImage!, in: CGRect(x: -x, y: -(image.cgImage!.height - 1 - y), width: image.cgImage!.width, height: image.cgImage!.height))
        return UInt32(data[0]) << 16 | UInt32(data[1]) << 8 | UInt32(data[2])
    }

    private func close(_ a: UInt32, _ b: UInt32, tolerance: Int = 6) -> Bool {
        [0, 8, 16].allSatisfy { (shift: UInt32) -> Bool in
            let x = Int((a >> shift) & 0xff), y = Int((b >> shift) & 0xff)
            return abs(x - y) <= tolerance
        }
    }

    func testRealSnapshotDrawsColorsGlyphsAndCursor() async throws {
        let vt = TerminalVT(bridge: NativeTerminalBridge.shared)
        _ = await vt.apply(reset: true, bytes: K12.tail, cols: 20, rows: 4)
        let state = await vt.current()
        let snapshot = try XCTUnwrap(state.snapshot)
        await vt.close()
        let view = TerminalGridView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        view.fontSize = 20
        view.snapshot = snapshot
        let metrics = view.metrics
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in view.draw(view.bounds) }

        // Default background fills the grid; the block cursor sits at row 2, col 0.
        XCTAssertTrue(close(pixel(image, Int(metrics.width * 10.5), Int(metrics.height * 3.5)), 0x000000))
        let cursorCell = snapshot.cells[2 * 20]
        XCTAssertTrue(close(pixel(image, Int(metrics.width * 0.5), Int(metrics.height * 2.5)), parseColor(cursorCell.fg, 0xffffff)))
        // The bold red "RED" glyphs put red ink in the first three cells of row 0.
        var redInk = false
        for x in 0..<Int(metrics.width * 3) {
            for y in 0..<Int(metrics.height) where !redInk {
                let rgb = pixel(image, x, y)
                let (r, g, b) = (Int(rgb >> 16), Int((rgb >> 8) & 0xff), Int(rgb & 0xff))
                redInk = r > 120 && r > g + 40 && r > b + 40
            }
        }
        XCTAssertTrue(redInk, "no red glyph ink")
        // Selection overlays the selected cells.
        view.selection = GridSelection(anchorRow: 3, anchorCol: 0, row: 3, col: 19)
        let selected = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in view.draw(view.bounds) }
        XCTAssertFalse(close(pixel(selected, Int(metrics.width * 10.5), Int(metrics.height * 3.5)), 0x000000))
    }

    func testLayoutReportsTheMeasuredGridOnce() async throws {
        let view = TerminalGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        var measured: [GridSize] = []
        view.onMeasured = { measured.append($0) }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try await waitUntil("measured") { !measured.isEmpty }
        XCTAssertEqual(measured, [terminalGrid(width: 320, height: 200, metrics: view.metrics)])
        view.fontSize = 28 // pinch result
        view.layoutIfNeeded()
        try await waitUntil("remeasured") { measured.count == 2 }
        XCTAssertLessThan(measured[1].cols, measured[0].cols)
    }

    func testKeyboardCommitsTextImeAndBackspaceWithoutCorrections() {
        let view = TerminalGridView(frame: .zero)
        var inputs: [TermInput] = []
        view.onInput = { inputs.append($0) }
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.autocapitalizationType, UITextAutocapitalizationType.none)
        XCTAssertEqual(view.smartQuotesType, .no)
        XCTAssertEqual(view.inlinePredictionType, .no)
        XCTAssertTrue(view.hasText, "backspace must reach the terminal on an empty buffer")
        view.insertText("l")
        view.insertText("s\n")
        view.deleteBackward()
        // IME composition stays local until committed.
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        view.deleteBackward()
        XCTAssertEqual(view.text(in: view.markedTextRange!), "に")
        view.insertText("日")
        XCTAssertNil(view.markedTextRange)
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText()
        XCTAssertEqual(inputs, [.text("l"), .text("s\n"), .key("Backspace"), .text("日"), .text("k")])
        XCTAssertFalse(view.canBecomeFirstResponder, "read-only until the host is writable")
        view.inputEnabled = true
        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertEqual(view.keyCommands?.count, terminalKeyCommands().count)
        XCTAssertTrue(view.keyCommands?.allSatisfy(\.wantsPriorityOverSystemBehavior) == true)
        XCTAssertEqual(view.accessibilityLabel, "Terminal")
        XCTAssertNil(view.accessibilityValue, "grid contents are never exposed")
    }
}

// MARK: - Screen model over a fake core

/// Host/sync stand-in plus the K-12 pump contract: attach (or a reconnect while attached)
/// emits a reset `terminal_output`; create starts the session through a timer round-trip.
/// Every batch invalidates hosts/home/workspaces and every terminal selector.
private final class TermCore: HostCore {
    let events = EventLog()
    private let lock = NSLock()
    private let tail: Data
    private var row: HostView
    private var terminals: [String: TerminalView] = [:]
    private var order: [String] = []
    private var operations: [CoreOperation] = []
    private var sequence = 0
    private var created = 0
    private var _rejected = 0
    private var attachSuffix = ""
    private var attachStatus: Int32?

    init(_ saved: SavedHost, scopes: [String]) {
        tail = K12.tail
        row = hostView(saved.id, saved.label, phase: "idle", sync: "ready")
        row.scopes = scopes
    }

    var rejected: Int { lock.lock(); defer { lock.unlock() }; return _rejected }
    func configure(attachSuffix: String = "", attachStatus: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.attachSuffix = attachSuffix
        self.attachStatus = attachStatus
    }

    func handle(_ bytes: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let event = try JSONDecoder().decode(Event.self, from: bytes)
        var effects: [Effect] = []
        func next() -> String { sequence += 1; return "e\(sequence)" }
        func output(_ id: String, _ data: Data) {
            effects.append(.terminal_output(EffectTerminalOutput(effect_id: next(), generation: "1", terminal_id: id,
                reset: true, bytes_base64: data.base64EncodedString(), next_offset: "65")))
        }
        func put(_ view: TerminalView) {
            if terminals[view.terminal_id] == nil { order.append(view.terminal_id) }
            terminals[view.terminal_id] = view
        }
        switch event {
        case .terminal_input(let e) where e.input.ctrl && (e.input.key ?? "").allSatisfy(\.isNumber):
            _rejected += 1
            throw CoreBridgeError.status(1) // The core cannot encode Ctrl+digit.
        case .terminal_attach where attachStatus != nil:
            throw CoreBridgeError.status(attachStatus!)
        default: break
        }
        events.append(event)
        switch event {
        case .foreground: row.lifecycle = .foreground; row.phase = "ready"
        case .network_changed(let e):
            if !e.available {
                row.phase = "disabled"
                for id in order { terminals[id]?.stale = true }
            } else if row.phase != "ready" {
                row.phase = "ready"
                // Reconnect: attached terminals restart from a full (reset) replay.
                for id in order where terminals[id]?.attached == true {
                    terminals[id]?.stale = false
                    output(id, tail)
                }
            }
        case .terminal_attach(let e):
            var view = terminals[e.terminal_id] ?? TerminalView(terminal_id: e.terminal_id, workspace_id: "fixture-ws", label: "htop")
            view.attached = true; view.session_status = "running"; view.cols = 20; view.rows = 4
            view.stale = false; view.next_offset = "0"
            put(view)
            output(e.terminal_id, tail + Data(attachSuffix.utf8))
        case .terminal_detach(let e): terminals[e.terminal_id]?.attached = false
        case .terminal_applied(let e):
            if e.error == nil { terminals[e.terminal_id]?.grid_revision = e.grid_revision; terminals[e.terminal_id]?.next_offset = "65" }
        case .terminal_resize(let e): terminals[e.terminal_id]?.cols = e.cols; terminals[e.terminal_id]?.rows = e.rows
        case .terminal_create(let e):
            if e.workspace_id == "no-path" {
                operations.append(CoreOperation(intent_id: e.intent_id, state: "failed",
                    error: LocalError(code: "workspace_path_unavailable", message: "no path")))
            } else {
                created += 1
                let id = "mobile:fixture:\(created)"
                put(TerminalView(terminal_id: id, workspace_id: e.workspace_id, label: "Terminal", session_status: "starting",
                                 attached: true, cols: e.cols, rows: e.rows, stale: true))
                effects.append(.set_timer(EffectSetTimer(effect_id: next(), generation: "1", timer_id: "create:\(id)",
                                                         delay_ms: 10, purpose: "test")))
            }
        case .timer_fired(let e) where e.timer_id.hasPrefix("create:"):
            let id = String(e.timer_id.dropFirst("create:".count))
            terminals[id]?.session_status = "running"
            terminals[id]?.stale = false
            output(id, Data("$ ".utf8))
        default: break
        }
        effects.append(.state_changed(EffectStateChanged(effect_id: next(), generation: "1", revision: String(sequence),
            scopes: ["hosts", "home", "workspaces"] + order.map(terminalSelector))))
        return try encoded(EffectBatch(api_version: 1, revision: String(sequence), effects: effects))
    }

    func query(_ selector: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let revision = String(sequence)
        switch selector {
        case "home": return try encoded(K09.homeLive)
        case "workspaces": return try encoded(K09.workspacesLive)
        case "hosts":
            return try encoded(HostsQuery(api_version: 1, revision: revision,
                                          data: HostsView(items: [row], operations: operations), error: nil))
        case "operations":
            return try encoded(OperationsQuery(api_version: 1, revision: revision,
                                               data: OperationsView(items: operations), error: nil))
        default:
            let view = order.first { terminalSelector($0) == selector }.flatMap { terminals[$0] }
            return try encoded(TerminalQuery(api_version: 1, revision: revision, data: view, error: nil))
        }
    }

    func close() {}
}

@MainActor
final class TerminalModelTests: XCTestCase {
    private var storage = MemoryStorage()
    private var hosts: HostsModel!
    private var browse: BrowseModel!
    private var cores: [TermCore] = []
    private var bridge = RecordingBridge()
    private var scopes = ["terminal:read", "terminal:write"]
    private var setup: (TermCore) -> Void = { _ in }
    private var models: [TerminalModel] = []
    private var core: TermCore { cores.last! }

    override func tearDown() async throws {
        models.forEach { $0.stop() }
        await hosts?.close()
        FocusClaim.owner = nil
    }

    private func launch() async throws {
        storage.set(HostsModel.catalogKey, try encoded(HostCatalog(hosts: [SavedHost(id: "alpha", label: "Studio")], active: "alpha")))
        let bridge = self.bridge, scopes = self.scopes
        let hosts = HostsModel(storage: storage, cache: nil, deviceLabel: "Test phone") { [unowned self] saved, store in
            let fake = TermCore(saved, scopes: scopes)
            self.setup(fake)
            self.cores.append(fake)
            return CoreHost(core: fake, store: store, transport: NullTransport(),
                            storage: HostScopedStorage(base: storage, hostID: saved.id), terminals: bridge)
        }
        self.hosts = hosts
        browse = BrowseModel(hosts: hosts)
        hosts.foreground(true)
        hosts.network(NetworkState(available: true, id: "net-1"))
        hosts.begin()
        try await waitUntil("ready") { browse.state.host?.phase == "ready" }
    }

    private func open(_ terminalID: String? = "sess-7", workspace: String = "fixture-ws") -> TerminalModel {
        let model = TerminalModel(browse: browse, hostID: "alpha", workspaceID: workspace, terminalID: terminalID, resizeDelay: 0.05)
        models.append(model)
        model.start()
        return model
    }

    private func events<T>(_ match: (Event) -> T?) -> [T] { core.events.all.compactMap(match) }
    private var inputs: [TermInput] {
        events { event -> TermInput? in
            guard case .terminal_input(let e) = event else { return nil }
            switch e.input.kind {
            case .text: return .text(e.input.text ?? "")
            case .paste: return .paste(e.input.text ?? "")
            case .key: return .key(e.input.key ?? "", ctrl: e.input.ctrl, alt: e.input.alt, shift: e.input.shift)
            }
        }
    }
    private var applied: [EventTerminalApplied] { events { if case .terminal_applied(let e) = $0 { return e }; return nil } }
    private var resizes: [EventTerminalResize] { events { if case .terminal_resize(let e) = $0 { return e }; return nil } }
    private var replies: [EventTerminalReply] { events { if case .terminal_reply(let e) = $0 { return e }; return nil } }
    private var focuses: [EventFocus] { events { if case .focus(let e) = $0 { return e }; return nil } }
    private var detaches: [String] { events { if case .terminal_detach(let e) = $0 { return e.terminal_id }; return nil } }
    private var attaches: [String] { events { if case .terminal_attach(let e) = $0 { return e.terminal_id }; return nil } }
    private var creates: [EventTerminalCreate] { events { if case .terminal_create(let e) = $0 { return e }; return nil } }

    func testAttachReplaysTheK12TailTypesThroughTheCoreAndDetachesOnLeave() async throws {
        setup = { $0.configure(attachSuffix: "\u{1b}[6n") }
        try await launch()
        let model = open()
        try await waitUntil("applied") { !applied.isEmpty && model.snapshot != nil }
        XCTAssertNil(applied[0].error)
        XCTAssertEqual(applied[0].grid_revision, "1")
        XCTAssertEqual(applied[0].terminal_id, "sess-7")
        // The first reset recreates the VT at the core's grid, then writes the recorded bytes once.
        XCTAssertEqual(bridge.configs.map { [Int($0.cols), Int($0.rows), Int($0.scrollback_rows)] }, [[20, 4, 2000]])
        XCTAssertEqual(bridge.writes.first, K12.tail + Data("\u{1b}[6n".utf8))
        XCTAssertEqual(cellsJSON(model.snapshot), cellsJSON(K12.snapshot))
        // Device replies go back through terminal_reply.
        try await waitUntil("reply") { !replies.isEmpty }
        XCTAssertEqual(replies.compactMap { Data(base64Encoded: $0.bytes_base64) }, [Data("\u{1b}[3;1R".utf8)])
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.interactive)
        XCTAssertEqual(model.view?.label, "htop")

        // The measured canvas drives one debounced session.resize, and the VT follows the core's size.
        model.setMeasured(GridSize(cols: 30, rows: 8))
        model.setMeasured(GridSize(cols: 40, rows: 12))
        try await waitUntil("resize") { !resizes.isEmpty }
        try await waitUntil("vt follows") { model.snapshot?.cols == 40 && model.snapshot?.rows == 12 }
        XCTAssertEqual(resizes.map { [$0.cols, $0.rows] }, [[40, 12]])
        XCTAssertTrue(bridge.resizes.contains(GridSize(cols: 40, rows: 12)))

        model.input(.key("Escape"))
        model.input(.key("ArrowUp"))
        model.input(.text("|"))
        model.input(.text("ls\n"))
        model.toggleCtrl()
        XCTAssertTrue(model.ctrl)
        model.input(.text("c"))
        XCTAssertFalse(model.ctrl, "sticky Ctrl applies to one input")
        model.input(.key("Backspace"))
        model.input(hardwareKey(input: "d", flags: .control)!)
        model.toggleAlt()
        model.input(.key("ArrowLeft"))
        model.input(.paste("echo hi"))
        try await waitUntil("inputs") { inputs.count == 10 }
        XCTAssertEqual(inputs, [.key("Escape"), .key("ArrowUp"), .text("|"), .text("ls"), .key("Enter"), .key("c", ctrl: true),
                                .key("Backspace"), .key("d", ctrl: true), .key("ArrowLeft", alt: true), .paste("echo hi")])
        // DECCKM and bracketed paste from the replayed stream reach the core's key encoding.
        let modes = events { event -> VtModes? in if case .terminal_input(let e) = event { return e.vt_modes }; return nil }
        XCTAssertTrue(modes.allSatisfy { $0.application_cursor && $0.bracketed_paste })

        // Focus goes through the shared FocusClaim: claimed on open, released on leave.
        XCTAssertEqual(focuses.count, 1)
        XCTAssertEqual([focuses[0].workspace_id, focuses[0].thread_id, focuses[0].terminal_id], ["fixture-ws", nil, "sess-7"])
        XCTAssertEqual(FocusClaim.owner, ObjectIdentifier(model))
        model.stop()
        try await waitUntil("detached") { detaches == ["sess-7"] && bridge.live == 0 }
        try await waitUntil("focus released") { focuses.count == 2 }
        XCTAssertEqual([focuses[1].workspace_id, focuses[1].thread_id, focuses[1].terminal_id], [nil, nil, nil])
        XCTAssertNil(FocusClaim.owner)
        XCTAssertFalse(core.events.all.contains { if case .terminal_kill = $0 { return true }; return false }, "leaving never kills")
        // Input after leaving is dropped.
        model.input(.text("x"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inputs.count, 10)
    }

    func testScrollbackSnapsBackBeforeTyping() async throws {
        setup = { $0.configure(attachSuffix: (1...40).map { "line \($0)\r\n" }.joined()) }
        try await launch()
        let model = open()
        try await waitUntil("applied") { (model.snapshot?.scrollback_rows ?? 0) > 0 && model.interactive }
        model.scroll(2)
        try await waitUntil("in history") { model.snapshot?.scroll_offset == 2 }
        XCTAssertNil(renderPlan(model.snapshot!).cursor)
        model.input(.text("q"))
        try await waitUntil("typed") { inputs == [.text("q")] }
        try await waitUntil("live") { model.snapshot?.scroll_offset == 0 }
        XCTAssertEqual(bridge.scrolls, [2, -2])
    }

    func testOfflinePausesInputAndResizeThenReconnectReplayShowsTheGapNotice() async throws {
        try await launch()
        let model = open()
        model.setMeasured(GridSize(cols: 20, rows: 4))
        try await waitUntil("applied") { model.snapshot != nil && model.interactive }
        hosts.network(NetworkState(available: false, id: ""))
        try await waitUntil("offline") { model.notice == "You're offline. Showing the last screen; input is paused." }
        XCTAssertFalse(model.interactive)
        XCTAssertNotNil(model.snapshot, "the last screen stays up while offline")
        model.input(.key("Escape"))
        model.setMeasured(GridSize(cols: 50, rows: 10))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertTrue(resizes.isEmpty, "no resize while offline")

        hosts.network(NetworkState(available: true, id: "net-2"))
        try await waitUntil("replayed") { applied.count == 2 }
        try await waitUntil("gap notice") { model.notice == "Reconnected. Some earlier output may be missing." }
        XCTAssertEqual(bridge.configs.count, 2)
        // The size measured while offline is sent once connected again.
        try await waitUntil("resize after reconnect") { resizes.map { [$0.cols, $0.rows] } == [[50, 10]] }
        model.dismissGap()
        XCTAssertNil(model.notice)
        model.input(.key("Escape"))
        try await waitUntil("typed") { inputs == [.key("Escape")] }
    }

    func testNewTerminalCreatesOnceMeasuredWithoutAttachOrResize() async throws {
        try await launch()
        let model = open(nil)
        var created: [String] = []
        model.onCreated = { created.append($0) }
        XCTAssertEqual(model.notice, "Opening a new terminal…")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(creates.isEmpty, "create waits for a measured grid")
        model.setMeasured(GridSize(cols: 44, rows: 14))
        try await waitUntil("created") { model.terminalID == "mobile:fixture:1" }
        XCTAssertEqual(creates.count, 1)
        XCTAssertEqual(creates[0].workspace_id, "fixture-ws")
        XCTAssertNil(creates[0].cwd)
        XCTAssertEqual([creates[0].cols, creates[0].rows], [44, 14])
        XCTAssertEqual(created, ["mobile:fixture:1"])
        try await waitUntil("running") { applied.contains { $0.terminal_id == "mobile:fixture:1" } && model.interactive }
        XCTAssertNil(model.notice)
        XCTAssertEqual([model.snapshot?.cols, model.snapshot?.rows], [44, 14])
        // terminal_create attaches by itself; the screen never sends a second attach.
        XCTAssertTrue(attaches.isEmpty)
        model.input(.key("Tab"))
        try await waitUntil("typed") { inputs == [.key("Tab")] }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(resizes.isEmpty, "it already matches its measured size")
        model.stop()
        try await waitUntil("detached") { detaches == ["mobile:fixture:1"] && bridge.live == 0 }
    }

    func testCreateAndAttachFailuresShowTheirMessages() async throws {
        try await launch()
        let missing = open(nil, workspace: "no-path")
        missing.setMeasured(GridSize(cols: 20, rows: 4))
        try await waitUntil("failed") { missing.notice == "This workspace has no folder on the host." }
        XCTAssertNil(missing.terminalID)
        XCTAssertEqual(bridge.live, 0)
        core.configure(attachStatus: 5)
        let limited = open()
        try await waitUntil("limit") { limited.notice == TerminalModel.tooMany }
        XCTAssertFalse(limited.interactive)
        XCTAssertFalse(hosts.session("alpha")!.store.failed, "a rejected intent keeps the host")
    }

    func testWithoutTerminalWriteTheTerminalIsViewOnly() async throws {
        scopes = ["terminal:read"]
        setup = { $0.configure(attachSuffix: "\u{1b}[6n") }
        try await launch()
        XCTAssertFalse(canWrite(browse.state.host))
        let model = open()
        model.setMeasured(GridSize(cols: 40, rows: 12))
        try await waitUntil("view only") {
            model.snapshot != nil && model.notice == "View only: this phone was paired without terminal access."
        }
        XCTAssertFalse(model.writable)
        XCTAssertFalse(model.interactive)
        model.input(.key("Escape"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(resizes.isEmpty)
        let fresh = open(nil)
        fresh.setMeasured(GridSize(cols: 20, rows: 4))
        try await waitUntil("cannot create") { fresh.notice == "This phone can view terminals but not open them." }
        XCTAssertTrue(creates.isEmpty)
    }

    func testRejectedKeysAreDroppedWithoutClosingTheHost() async throws {
        try await launch()
        let model = open()
        try await waitUntil("interactive") { model.interactive }
        model.toggleCtrl()
        model.input(.text("1"))
        model.input(.text("a"))
        try await waitUntil("next input") { inputs == [.text("a")] }
        XCTAssertEqual(core.rejected, 1)
        XCTAssertFalse(hosts.session("alpha")!.store.failed)
        XCTAssertTrue(model.interactive)
        XCTAssertNil(model.notice)
    }
}

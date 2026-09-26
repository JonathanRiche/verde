import Foundation
import Observation
import UIKit

/// One user input before the core's key encoding (terminal.md).
enum TermInput: Equatable {
    case text(String)
    /// `key` is a core key name (`Escape`, `ArrowUp`, …) or a single ASCII character.
    case key(String, ctrl: Bool = false, alt: Bool = false, shift: Bool = false)
    case paste(String)
}

/// Sticky Ctrl/Alt from the key row apply to the next input only.
func withModifiers(_ input: TermInput, ctrl: Bool, alt: Bool) -> [TermInput] {
    switch input {
    case .key(let key, let c, let a, let shift): return [.key(key, ctrl: c || ctrl, alt: a || alt, shift: shift)]
    case .paste: return [input]
    case .text(let text):
        let scalars = text.unicodeScalars
        if ctrl || alt, scalars.count == 1, (0x20...0x7e).contains(scalars.first!.value) {
            return [.key(text, ctrl: ctrl, alt: alt)]
        }
        return splitLines(text)
    }
}

/// Keyboards commit newlines as text; the terminal expects the Enter key (CR).
func splitLines(_ text: String) -> [TermInput] {
    var out: [TermInput] = []
    var current = ""
    for character in text {
        if character == "\n" || character == "\r\n" || character == "\r" {
            if !current.isEmpty { out.append(.text(current)) }
            out.append(.key("Enter"))
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { out.append(.text(current)) }
    return out
}

/// Hardware key command → core input. Printable keys with Ctrl/Alt become single-byte keys.
func hardwareKey(input: String, flags: UIKeyModifierFlags) -> TermInput? {
    let ctrl = flags.contains(.control)
    let alt = flags.contains(.alternate)
    let shift = flags.contains(.shift)
    let named: String?
    switch input {
    case UIKeyCommand.inputEscape: named = "Escape"
    case "\t": named = "Tab"
    case "\r": named = "Enter"
    // `UIKeyCommand.inputDelete` is the Backspace key ("\u{8}"); forward delete
    // arrives through `pressesBegan` (`keyboardDeleteForward`).
    case UIKeyCommand.inputDelete: named = "Backspace"
    case "\u{7f}": named = "Delete"
    case UIKeyCommand.inputUpArrow: named = "ArrowUp"
    case UIKeyCommand.inputDownArrow: named = "ArrowDown"
    case UIKeyCommand.inputLeftArrow: named = "ArrowLeft"
    case UIKeyCommand.inputRightArrow: named = "ArrowRight"
    case UIKeyCommand.inputHome: named = "Home"
    case UIKeyCommand.inputEnd: named = "End"
    case UIKeyCommand.inputPageUp: named = "PageUp"
    case UIKeyCommand.inputPageDown: named = "PageDown"
    default: named = nil
    }
    if let named { return .key(named, ctrl: ctrl, alt: alt, shift: shift) }
    let scalars = input.unicodeScalars
    guard scalars.count == 1, let scalar = scalars.first, scalar.value >= 0x20, scalar.value != 0x7f else { return nil }
    let text = shift ? input.uppercased() : input
    if ctrl || alt, scalar.value <= 0x7e { return .key(text, ctrl: ctrl, alt: alt) }
    return .text(text)
}

/// Every hardware combination the terminal claims ahead of the system (focus, text
/// editing). Plain printable keys and Return stay with the text system (IME, repeat).
func terminalKeyCommands() -> [(input: String, flags: UIKeyModifierFlags)] {
    let named = [UIKeyCommand.inputEscape, "\t", UIKeyCommand.inputUpArrow,
                 UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                 UIKeyCommand.inputHome, UIKeyCommand.inputEnd, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown]
    let combos: [UIKeyModifierFlags] = [[], .shift, .control, .alternate, [.control, .shift], [.alternate, .shift],
                                        [.control, .alternate], [.control, .alternate, .shift]]
    var out: [(input: String, flags: UIKeyModifierFlags)] = named.flatMap { input in combos.map { (input: input, flags: $0) } }
    let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
    for key in letters + ["[", "]", "\\", " "] { out.append((key, .control)) }
    for key in letters { out.append((key, [.control, .alternate])) }
    for key in letters + "0123456789.,/;'-=[]\\`".map(String.init) {
        out.append((key, .alternate))
        if key.first!.isLetter { out.append((key, [.alternate, .shift])) }
    }
    for key in ["\r", UIKeyCommand.inputDelete] {
        for flags: UIKeyModifierFlags in [.control, .alternate, .shift] { out.append((key, flags)) }
    }
    return out
}

func canWrite(_ host: HostView?) -> Bool { host?.scopes.contains("terminal:write") == true }

/// One accessory-row key (`nil` input = sticky modifier or local action).
struct AccessoryKey: Equatable {
    var label: String
    var accessibility: String
    var input: TermInput
}

let accessoryKeys: [AccessoryKey] = [
    AccessoryKey(label: "Esc", accessibility: "Escape", input: .key("Escape")),
    AccessoryKey(label: "Tab", accessibility: "Tab", input: .key("Tab")),
    AccessoryKey(label: "←", accessibility: "Left", input: .key("ArrowLeft")),
    AccessoryKey(label: "↓", accessibility: "Down", input: .key("ArrowDown")),
    AccessoryKey(label: "↑", accessibility: "Up", input: .key("ArrowUp")),
    AccessoryKey(label: "→", accessibility: "Right", input: .key("ArrowRight")),
    AccessoryKey(label: "|", accessibility: "Pipe", input: .text("|")),
    AccessoryKey(label: "~", accessibility: "Tilde", input: .text("~")),
    AccessoryKey(label: "/", accessibility: "Slash", input: .text("/")),
    AccessoryKey(label: "-", accessibility: "Dash", input: .text("-")),
    AccessoryKey(label: "Home", accessibility: "Home", input: .key("Home")),
    AccessoryKey(label: "End", accessibility: "End", input: .key("End")),
    AccessoryKey(label: "PgUp", accessibility: "Page up", input: .key("PageUp")),
    AccessoryKey(label: "PgDn", accessibility: "Page down", input: .key("PageDown")),
]

let replayGapNotice = "Reconnected. Some earlier output may be missing."

/// The single most relevant status line for the terminal screen, or nil when live.
func terminalNotice(failure: String?, terminalID: String?, view: TerminalView?, replayGap: Bool,
                    browse b: BrowseState, hostID: String?) -> String? {
    if let failure { return failure }
    if b.hostID != hostID { return "This terminal belongs to another host. Switch hosts to use it." }
    if !b.networkAvailable { return "You're offline. Showing the last screen; input is paused." }
    if b.fatal || b.row?.fatal == true { return "Connection unavailable — reopen Verde." }
    if b.host?.phase != "ready" { return "Reconnecting… Showing the last screen; input is paused." }
    if terminalID == nil { return "Opening a new terminal…" }
    guard let view else { return "Opening terminal…" }
    if view.session_status == "exited" { return "The session has ended." }
    if view.session_status == "unknown" || (view.error != nil && !view.attached) { return "This terminal is no longer available." }
    if view.session_status == "starting" { return "Starting shell…" }
    if !canWrite(b.host) { return "View only: this phone was paired without terminal access." }
    if view.error != nil && view.stale { return "Connection interrupted. Catching up…" }
    if replayGap { return replayGapNotice }
    return nil
}

/// The core has one focus slot shared by every screen; only its latest claimant releases it.
@MainActor
enum FocusClaim {
    static var owner: ObjectIdentifier?
}

/// Screen model for one daemon session on its host (`session.*` via the core only).
/// It owns the local VT while started; `stop` detaches the pump and frees the VT but
/// never kills the session. Terminal contents are never logged.
@MainActor @Observable
final class TerminalModel {
    static let tooMany = "Too many terminals were opened this session. Reopen Verde to open more."

    let hostID: String?
    let workspaceID: String
    private(set) var terminalID: String?
    private(set) var feed: TerminalFeed?
    private(set) var creating = false
    /// Terminal-level failure that input cannot recover from (create/attach rejected).
    private(set) var failure: String?
    private(set) var ctrl = false
    private(set) var alt = false
    /// Grid measured from the view; drives `terminal_create` and `terminal_resize`.
    private(set) var measured: GridSize?
    private var dismissedResets = 1

    @ObservationIgnored private let browse: BrowseModel
    @ObservationIgnored private let resizeDelay: TimeInterval
    @ObservationIgnored private var host: CoreHost?
    @ObservationIgnored private var vt: TerminalVT?
    @ObservationIgnored private var inputs: AsyncStream<TermInput>.Continuation?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeKey: ResizeKey?
    @ObservationIgnored private var sent: GridSize?
    @ObservationIgnored private var followed: GridSize?
    @ObservationIgnored private var pendingCreate = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var closed = false
    /// Receives a created session's ID so a reopened screen attaches instead of creating again.
    @ObservationIgnored var onCreated: ((String) -> Void)?

    private struct ResizeKey: Equatable {
        var size: GridSize?
        var view: GridSize?
        var ready: Bool
        var id: String?
    }

    init(browse: BrowseModel, hostID: String?, workspaceID: String, terminalID: String?, resizeDelay: TimeInterval = 0.15) {
        self.browse = browse
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.resizeDelay = resizeDelay
    }

    var snapshot: TerminalSnapshot? { feed?.snapshot }
    /// True after the emulator was rebuilt from a later replay (gap, reconnect or apply failure).
    var replayGap: Bool { (feed?.resets ?? 0) > dismissedResets }

    var view: TerminalView? {
        guard let id = terminalID, let data = browse.hosts.session(hostID)?.store.snapshots[terminalSelector(id)] else { return nil }
        return (try? JSONDecoder().decode(TerminalQuery.self, from: data))?.data
    }

    /// This screen's host is selected and grants `terminal:write`.
    var writable: Bool {
        let b = browse.state
        return b.hostID == hostID && canWrite(b.host)
    }

    /// Connected, attached, running and allowed to type.
    var interactive: Bool {
        let b = browse.state
        guard let view, failure == nil, b.hostID == hostID, b.networkAvailable, b.host?.phase == "ready",
              canWrite(b.host) else { return false }
        return view.attached && view.session_status == "running"
    }

    var notice: String? {
        terminalNotice(failure: failure, terminalID: terminalID, view: view, replayGap: replayGap,
                       browse: browse.state, hostID: hostID)
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        let (stream, continuation) = AsyncStream<TermInput>.makeStream()
        inputs = continuation
        tasks.append(Task { [weak self] in
            for await input in stream { await self?.deliver(input) }
        })
        tasks.append(Task { [weak self] in await self?.open() })
        track()
    }

    /// Detaches (never kills) the session, frees the VT and releases focus. Final.
    func stop() {
        guard !closed else { return }
        closed = true
        tasks.forEach { $0.cancel() }
        resizeTask?.cancel()
        inputs?.finish()
        let host = self.host, id = terminalID, vt = self.vt
        let releaseFocus = FocusClaim.owner == ObjectIdentifier(self)
        if releaseFocus { FocusClaim.owner = nil }
        guard let host else { return }
        // Detached from this model so the release still reaches the core after the screen is gone.
        Task {
            if let id, let vt { await host.closeTerminal(id, vt) }
            if releaseFocus {
                try? await host.send(.focus(EventFocus(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString,
                    workspace_id: nil, thread_id: nil, terminal_id: nil)))
            }
        }
    }

    func setMeasured(_ size: GridSize) { if measured != size { measured = size } }
    func toggleCtrl() { ctrl.toggle() }
    func toggleAlt() { alt.toggle() }
    func dismissGap() { dismissedResets = feed?.resets ?? dismissedResets }

    func input(_ input: TermInput) {
        guard interactive else { return }
        let (c, a) = (ctrl, alt)
        if ctrl { ctrl = false }
        if alt { alt = false }
        withModifiers(input, ctrl: c, alt: a).forEach { inputs?.yield($0) }
    }

    /// Scrollback in rows (positive = older), within the VT's page-granular history.
    func scroll(_ rows: Int) {
        guard let vt, rows != 0 else { return }
        Task { await vt.scroll(Int32(clamping: rows)) }
    }

    // MARK: Session

    private func fail(_ message: String) {
        failure = message
        creating = false
        pendingCreate = false
    }

    private func open() async {
        guard let session = browse.hosts.session(hostID) else { fail("This host is no longer available."); return }
        await session.start()
        guard !closed else { return }
        guard let host = session.host else { fail("Connection unavailable — reopen Verde."); return }
        self.host = host
        if let id = terminalID { await attach(host, id) } else { pendingCreate = true; reevaluate() }
    }

    private func attach(_ host: CoreHost, _ id: String) async {
        let vt: TerminalVT
        do { vt = try await host.openTerminal(id, replies: canWrite(browse.state.host)) }
        catch { fail("Connection unavailable — reopen Verde."); return }
        if closed { await host.closeTerminal(id, vt); return }
        observe(host, id, vt)
        do {
            try await host.send(.terminal_attach(EventTerminalAttach(now_ms: 0, wall_time_ms: 0,
                intent_id: UUID().uuidString, terminal_id: id)))
        } catch CoreBridgeError.rejected(let status) {
            fail(status == 5 ? Self.tooMany : "Couldn't open this terminal.")
        } catch { fail("Connection unavailable — reopen Verde.") }
    }

    /// The core needs a measured grid and a ready connection; creation is never retried automatically.
    private func create(_ host: CoreHost, _ size: GridSize) async {
        guard canWrite(browse.state.host) else { fail("This phone can view terminals but not open them."); return }
        creating = true
        let event = EventTerminalCreate(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString,
                                        workspace_id: workspaceID, cwd: nil, cols: size.cols, rows: size.rows)
        let result: CoreHost.TerminalCreation
        do { result = try await host.createTerminal(event, replies: true) }
        catch CoreBridgeError.rejected(let status) { fail(status == 5 ? Self.tooMany : "Couldn't open a terminal."); return }
        catch { fail("Couldn't open a terminal."); return }
        switch result {
        case .failed(let code):
            switch code {
            case "workspace_path_unavailable": fail("This workspace has no folder on the host.")
            case "not_connected": fail("Not connected. Try again when the host is reachable.")
            default: fail("Couldn't open a terminal.")
            }
        case .created(let id, let vt):
            onCreated?(id)
            if closed { await host.closeTerminal(id, vt); return }
            terminalID = id
            creating = false
            observe(host, id, vt)
        }
    }

    private func observe(_ host: CoreHost, _ id: String, _ vt: TerminalVT) {
        self.vt = vt
        feed = vt.feed
        FocusClaim.owner = ObjectIdentifier(self)
        tasks.append(Task {
            try? await host.send(.focus(EventFocus(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString,
                workspace_id: workspaceID, thread_id: nil, terminal_id: id)))
        })
        reevaluate()
    }

    // MARK: Reactions

    /// Re-runs `reevaluate` after any change to what it reads (store publications included).
    private func track() {
        guard !closed else { return }
        withObservationTracking {
            _ = (measured, view?.cols, view?.rows, interactive, browse.state.host?.phase, browse.state.networkAvailable)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.track()
                self?.reevaluate()
            }
        }
    }

    private func reevaluate() {
        guard !closed else { return }
        let b = browse.state
        if pendingCreate, let host, let size = measured, b.host?.phase == "ready", b.networkAvailable {
            pendingCreate = false
            tasks.append(Task { await create(host, size) })
        }
        let current = view
        // The local grid follows the session's size (resize acks and host-side changes).
        if let current, let vt {
            let size = GridSize(cols: current.cols, rows: current.rows)
            if size != followed {
                followed = size
                Task { await vt.resize(cols: size.cols, rows: size.rows) }
            }
        }
        let key = ResizeKey(size: measured, view: current.map { GridSize(cols: $0.cols, rows: $0.rows) },
                            ready: interactive, id: terminalID)
        guard key != resizeKey else { return }
        resizeKey = key
        resizeTask?.cancel()
        let delay = UInt64(resizeDelay * 1_000_000_000)
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.resize()
        }
    }

    /// Only while connected and interactive; re-checked after every reconnect, but never
    /// fights a size the host changed later.
    private func resize() async {
        guard let size = measured, let view, interactive, let id = terminalID, let host else { sent = nil; return }
        if size == sent { return }
        sent = size
        if view.cols == size.cols && view.rows == size.rows { return }
        try? await host.send(.terminal_resize(EventTerminalResize(now_ms: 0, wall_time_ms: 0,
            intent_id: UUID().uuidString, terminal_id: id, cols: size.cols, rows: size.rows)))
    }

    private func deliver(_ input: TermInput) async {
        guard let host, let id = terminalID else { return }
        // Typing returns to the live screen first.
        if let offset = snapshot?.scroll_offset, offset > 0 { await vt?.scroll(-Int32(clamping: offset)) }
        let modes = snapshot?.vt_modes ?? VtModes(application_cursor: false, bracketed_paste: false)
        let payload: EventTerminalInputInput
        switch input {
        case .text(let text): payload = EventTerminalInputInput(kind: .text, text: text, ctrl: false, alt: false, shift: false)
        case .paste(let text): payload = EventTerminalInputInput(kind: .paste, text: text, ctrl: false, alt: false, shift: false)
        case .key(let key, let ctrl, let alt, let shift):
            payload = EventTerminalInputInput(kind: .key, key: key, ctrl: ctrl, alt: alt, shift: shift)
        }
        // Unencodable keys (e.g. Ctrl+digit) are rejected by the core and dropped; never retried.
        try? await host.send(.terminal_input(EventTerminalInput(now_ms: 0, wall_time_ms: 0,
            intent_id: UUID().uuidString, terminal_id: id, vt_modes: modes, input: payload)))
    }
}

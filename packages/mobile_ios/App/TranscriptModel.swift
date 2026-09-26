import Foundation
import Observation

/// Encodes the core's revision-1 thread identity exactly like `chat.selectorFor`.
func chatSelector(_ prefix: String, _ workspaceID: String, _ threadID: String) -> String {
    let json = (try? JSONSerialization.data(withJSONObject: [workspaceID, threadID], options: [.withoutEscapingSlashes])) ?? Data()
    let hex = Array("0123456789ABCDEF")
    var out = prefix + ":"
    for byte in json {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
            out.append(Character(UnicodeScalar(byte)))
        default:
            out.append("%")
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 15)])
        }
    }
    return out
}

struct TranscriptState {
    var browse = BrowseState()
    var thread: ChatThreadView?
    var composer: ChatComposerView?
    /// Error code of the latest failed `focus` receipt, e.g. `unavailable` or `thread_unavailable`.
    var focusError: String?
    var stopSending = false
    var fatal = false

    var turn: ChatTurn? { thread?.turn.flatMap { activeTurn($0.status) ? $0 : nil } }
    /// The core handle or this host's session is gone; only reopening Verde recovers.
    var unavailable: Bool { fatal || browse.fatal || browse.row?.fatal == true }
    var canStop: Bool { composer?.can_stop == true && turn?.stop_pending == false && !stopSending }
    var stopping: Bool { turn?.stop_pending == true || stopSending }
}

/// Transcript-level banner: host gates first (shared with browse), then this thread's own error.
func transcriptBanner(_ state: TranscriptState, _ nowMs: Int64) -> Banner? {
    let browse = state.browse
    if state.unavailable { return Banner(text: "Connection unavailable — reopen Verde.", error: true) }
    if needsPairing(browse) {
        return Banner(text: "This phone isn't paired with \(browse.row?.saved.label ?? "this host").", action: .hosts, error: true)
    }
    var gates = browse
    gates.home = nil
    gates.workspaces = nil
    gates.savedAtMs = nil
    if let banner = browseBanner(gates, nowMs) { return banner }
    // A failed approval decision is also mirrored into the thread error; the approval card reports it.
    if let error = state.thread?.error, !sameError(error, state.thread?.approval?.error) {
        return Banner(text: "Couldn't load this chat. \(error.message)".trimmingCharacters(in: .whitespaces), action: .retry, error: true)
    }
    return nil
}

enum TranscriptPlaceholder: Equatable { case loading, missing, offline, empty, error }

func transcriptPlaceholder(_ state: TranscriptState) -> TranscriptPlaceholder? {
    let thread = state.thread
    let host = state.browse.host
    if let thread, !thread.rows.isEmpty { return nil }
    if thread?.error != nil { return .error }
    if let thread, !thread.page.loading, state.focusError == nil { return .empty }
    if state.focusError == "thread_unavailable" { return .missing }
    if state.unavailable || !state.browse.networkAvailable || host?.phase == "failed" || needsPairing(state.browse) { return .offline }
    return .loading
}

/// Bounded LRU keyed by source text.
final class RenderLRU<V> {
    private let capacity: Int
    private var entries: [String: (value: V, tick: Int)] = [:]
    private var tick = 0
    init(_ capacity: Int) { self.capacity = capacity }
    subscript(key: String) -> V? {
        get {
            guard let entry = entries[key] else { return nil }
            tick += 1
            entries[key] = (entry.value, tick)
            return entry.value
        }
        set {
            guard let newValue else { entries[key] = nil; return }
            tick += 1
            entries[key] = (newValue, tick)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key {
                entries[oldest] = nil
            }
        }
    }
}

private struct UtilitySelector: Encodable {
    let utility: String
    let text: String
    var language: String?
}

private func utilitySelector(_ utility: String, _ text: String, language: String? = nil) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = (try? encoder.encode(UtilitySelector(utility: utility, text: text, language: language))) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Decodes a utility reply off the main actor.
private func decodeDetached<T>(_ data: Data, _ transform: @escaping (Data) throws -> T?) async -> T? {
    await Task.detached(priority: .userInitiated) { try? transform(data) }.value ?? nil
}

/// One chat thread of the selected host. The transcript, page, turn and composer all come from the
/// core's `thread:` / `composer:` projections; this class only turns UI actions into intents.
/// Message bodies are never logged or persisted here.
@MainActor @Observable
final class TranscriptModel: DiffRenderSource {
    static let unfocusDelay: TimeInterval = 0.5
    /// The core caps utility input at 64 KiB; larger bodies render as plain text.
    static let maxRenderSelector = 72 * 1024
    /// `diff_index` only frames records; the core bounds it by the 1 MiB query selector.
    static let maxIndexSelector = 1024 * 1024

    let workspaceID: String
    let threadID: String
    let threadSelector: String
    let composerSelector: String

    private(set) var thread: ChatThreadView?
    private(set) var composer: ChatComposerView?
    /// Renderable items, rebuilt once per thread projection (never per frame).
    private(set) var items: [TranscriptItem] = []
    private(set) var focusError: String?
    private(set) var stopSending = false
    private(set) var fatal = false
    @ObservationIgnored private(set) var approvals: ApprovalController!
    /// Card disclosure state; survives lazy cell reuse.
    let disclosure = DisclosureStore()
    @ObservationIgnored lazy var input = ComposerModel(chat: self)

    @ObservationIgnored private let browse: BrowseModel
    @ObservationIgnored private let unfocusDelay: TimeInterval
    @ObservationIgnored private(set) var host: CoreHost?
    @ObservationIgnored private var boundHostID: String?
    @ObservationIgnored private var boundSession: ObjectIdentifier?
    @ObservationIgnored private var bound = false
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var focused = false
    @ObservationIgnored private var focusIntent: String?
    @ObservationIgnored private var focusEpoch = -1
    @ObservationIgnored private var readyEpoch = 0
    @ObservationIgnored private var lastReady = false
    @ObservationIgnored private var lastGate: Gate?
    @ObservationIgnored private var unfocusTask: Task<Void, Never>?
    @ObservationIgnored private var requestedCursor: String?
    @ObservationIgnored private var threadData: Data?
    @ObservationIgnored private var composerData: Data?
    @ObservationIgnored private var sends: AsyncStream<(CoreHost, Event, ((Bool) -> Void)?)>.Continuation?
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var closed = false

    @ObservationIgnored private let markdownCache = RenderLRU<RenderResult<[MdBlock]>>(256)
    @ObservationIgnored private let highlightCache = RenderLRU<RenderResult<[RenderSpan]>>(64)
    @ObservationIgnored private let diffCache = RenderLRU<RenderResult<DiffView>>(32)
    @ObservationIgnored private let indexCache = RenderLRU<RenderResult<DiffIndexView>>(16)

    private struct Gate: Equatable {
        var visible: Bool
        var ready: Bool
        var settling: Bool
        var failure: String?
    }

    init(browse: BrowseModel, workspaceID: String, threadID: String, unfocusDelay: TimeInterval = TranscriptModel.unfocusDelay,
         outcomeDelay: TimeInterval = ApprovalController.outcomeDelay) {
        self.browse = browse
        self.workspaceID = workspaceID
        self.threadID = threadID
        self.unfocusDelay = unfocusDelay
        threadSelector = chatSelector("thread", workspaceID, threadID)
        composerSelector = chatSelector("composer", workspaceID, threadID)
        approvals = ApprovalController(workspaceID: workspaceID, threadID: threadID, host: { [weak self] in self?.host },
            operations: { [weak self] in self?.store?.operations?.data?.items }, outcomeDelay: outcomeDelay)
    }

    var state: TranscriptState {
        TranscriptState(browse: browse.state, thread: thread, composer: composer, focusError: focusError,
                        stopSending: stopSending, fatal: fatal)
    }

    private var store: CoreViewStore? { browse.hosts.session(boundHostID)?.store }

    func start() {
        guard !started, !closed else { return }
        started = true
        let (stream, continuation) = AsyncStream<(CoreHost, Event, ((Bool) -> Void)?)>.makeStream()
        sends = continuation
        // One ordered lane, so a focus never overtakes an unfocus sent before it.
        sender = Task { [weak self] in
            for await (host, event, done) in stream {
                let ok = await self?.deliver(host, event) ?? false
                done?(ok)
            }
        }
        track()
        reevaluate()
    }

    /// The screen is on display; focus (and so K-17 attention clearing) follows it.
    func setVisible(_ shown: Bool) {
        visible = shown
        reevaluate()
    }

    /// Final teardown: releases focus this model still owns (detached, so it outlives the model).
    func stop() {
        guard !closed else { return }
        closed = true
        unfocusTask?.cancel()
        opening?.cancel()
        sends?.finish()
        if focused, let host, FocusClaim.owner == ObjectIdentifier(self) {
            FocusClaim.owner = nil
            Task { try? await host.send(Self.unfocusEvent()) }
        }
        focused = false
    }

    /// Explicit user retry: re-focus reloads the newest page and restarts the live tail.
    func retry() {
        guard let host else { return }
        requestedCursor = nil
        sendFocus(host)
    }

    /// Requests the next older page once per cursor; the core rejects overlapping pages anyway.
    func loadOlder(force: Bool = false) {
        guard let host, let page = thread?.page, page.has_older, !page.loading, let cursor = page.cursor else { return }
        if !force && requestedCursor == cursor { return }
        requestedCursor = cursor
        enqueue(host, .thread_load_older(EventThreadLoadOlder(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString,
            workspace_id: workspaceID, thread_id: threadID)))
    }

    /// Stop uses the core's own active turn id; a second tap while stopping is ignored.
    func stopTurn() {
        let current = state
        guard let host, let turn = current.turn, current.canStop else { return }
        stopSending = true
        enqueue(host, .turn_cancel(EventTurnCancel(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString,
            workspace_id: workspaceID, thread_id: threadID, turn_id: turn.turn_id))) { [weak self] _ in
            self?.stopSending = false
        }
    }

    // MARK: Binding

    /// (Re)binds to the selected host's session; a host switch resets everything.
    private func bind() {
        let id = browse.hostID
        let session = browse.hosts.session(id)
        let identity = session.map(ObjectIdentifier.init)
        if bound && id == boundHostID && identity == boundSession { return }
        bound = true
        boundHostID = id
        boundSession = identity
        opening?.cancel()
        unfocusTask?.cancel()
        host = nil
        focused = false
        focusIntent = nil
        requestedCursor = nil
        lastGate = nil
        lastReady = false
        threadData = nil
        composerData = nil
        if thread != nil { thread = nil }
        if composer != nil { composer = nil }
        if !items.isEmpty { items = [] }
        if focusError != nil { focusError = nil }
        if fatal { fatal = false }
        approvals.reset()
        // A missing session surfaces through `BrowseState.fatal`.
        guard let session else { return }
        opening = Task { [weak self] in
            await session.start()
            guard let self, !Task.isCancelled, !self.closed, self.boundSession == identity else { return }
            guard let host = session.host else { self.fatal = true; return }
            self.host = host
            self.reevaluate()
        }
    }

    /// Re-runs `reevaluate` after any change to what it reads (store publications included).
    private func track() {
        guard !closed else { return }
        withObservationTracking {
            let session = browse.hosts.session(browse.hostID)
            let b = browse.state
            _ = (b.hostID, b.fatal, b.networkAvailable, b.host?.phase, b.host?.auth_state, b.host?.sync_state,
                 b.host?.trust_proposal != nil, b.host?.update_required, session?.host != nil)
            if let store = session?.store {
                _ = (store.snapshots[threadSelector], store.snapshots[composerSelector], store.hosts?.revision, store.operations?.revision, store.failed)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.track()
                self?.reevaluate()
            }
        }
    }

    private func reevaluate() {
        guard started, !closed else { return }
        bind()
        guard let host, let store else { return }
        if store.failed && !fatal { fatal = true }
        let threadBytes = store.snapshots[threadSelector]
        if threadBytes != threadData {
            threadData = threadBytes
            thread = threadBytes.flatMap { try? JSONDecoder().decode(ThreadQuery.self, from: $0) }?.data
            items = thread.map(transcriptItems) ?? []
            approvals.update(thread: thread)
        }
        let composerBytes = store.snapshots[composerSelector]
        if composerBytes != composerData {
            composerData = composerBytes
            composer = composerBytes.flatMap { try? JSONDecoder().decode(ComposerQuery.self, from: $0) }?.data
        }
        approvals.settle(operations: store.operations?.data?.items)

        let b = browse.state
        let gate = Gate(visible: visible, ready: ready(b.host), settling: settling(b.host, network: b.networkAvailable),
                        failure: failure(store.operations))
        guard gate != lastGate else { return }
        lastGate = gate
        unfocusTask?.cancel()
        if gate.ready && !lastReady { readyEpoch += 1 }
        lastReady = gate.ready
        if focusError != gate.failure { focusError = gate.failure }
        if gate.visible {
            // Each intent spends a core receipt: wait out an in-flight connection instead of
            // spending one on a certain rejection, and re-focus only after a rejected focus *and*
            // a fresh ready edge so this can never loop.
            if !focused && !gate.settling { sendFocus(host) }
            else if focused && gate.failure != nil && readyEpoch > focusEpoch { sendFocus(host) }
        } else if focused {
            let delay = UInt64(unfocusDelay * 1_000_000_000)
            let owner = ObjectIdentifier(self)
            unfocusTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if let self { self.sendUnfocus(host) }
                else if FocusClaim.owner == owner {
                    // The screen is gone; its focus still must not outlive it.
                    FocusClaim.owner = nil
                    try? await host.send(Self.unfocusEvent())
                }
            }
        }
    }

    /// Paired, online and still connecting or syncing. Offline, failed or trust-blocked hosts are
    /// not settling: focus is sent at once so K-17 attention still clears, then retried when ready.
    private func settling(_ view: HostView?, network: Bool) -> Bool {
        guard let view else { return true }
        if !network || view.auth_state != "paired" || view.update_required || view.trust_proposal != nil { return false }
        if ["failed", "awaiting_trust"].contains(view.phase) { return false }
        return !ready(view)
    }

    private func ready(_ view: HostView?) -> Bool {
        guard let view else { return false }
        return view.phase == "ready" && view.auth_state == "paired" && ["ready", "stale"].contains(view.sync_state)
    }

    private func failure(_ query: OperationsQuery?) -> String? {
        guard let id = focusIntent, let op = query?.data?.items.first(where: { $0.intent_id == id }) else { return nil }
        return op.state == "failed" ? (op.error?.code ?? "failed") : nil
    }

    // MARK: Intents

    private static func unfocusEvent() -> Event {
        .focus(EventFocus(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: nil, thread_id: nil, terminal_id: nil))
    }

    private func sendFocus(_ host: CoreHost) {
        let id = UUID().uuidString
        focusIntent = id
        focused = true
        focusEpoch = readyEpoch
        FocusClaim.owner = ObjectIdentifier(self)
        enqueue(host, .focus(EventFocus(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspaceID,
                                        thread_id: threadID, terminal_id: nil)))
    }

    private func sendUnfocus(_ host: CoreHost) {
        focused = false
        guard FocusClaim.owner == ObjectIdentifier(self) else { return }
        FocusClaim.owner = nil
        enqueue(host, Self.unfocusEvent())
    }

    private func enqueue(_ host: CoreHost, _ event: Event, done: ((Bool) -> Void)? = nil) {
        guard let sends else { done?(false); return }
        if case .terminated = sends.yield((host, event, done)) { done?(false) }
    }

    /// A rejected intent leaves the host usable; any other error means it failed.
    private func deliver(_ host: CoreHost, _ event: Event) async -> Bool {
        do {
            try await host.send(event)
            return true
        } catch CoreBridgeError.rejected {
            return false
        } catch {
            if !fatal { fatal = true }
            return false
        }
    }

    // MARK: K-11 rendering utilities (pure core queries; work offline)

    func cachedMarkdown(_ text: String) -> RenderResult<[MdBlock]>? { markdownCache[text] }

    func markdown(_ text: String) async -> RenderResult<[MdBlock]> {
        if let cached = markdownCache[text] { return cached }
        guard let host else { return RenderResult(nil) }
        let result = RenderResult(await utility(host, utilitySelector("markdown", text)) { data in
            try JSONDecoder().decode(MarkdownQuery.self, from: data).data.map { markdownBlocks($0.nodes) }
        })
        markdownCache[text] = result
        return result
    }

    func cachedHighlight(_ code: String, language: String) -> RenderResult<[RenderSpan]>? { highlightCache[language + "\u{0}" + code] }

    func highlight(_ code: String, language: String) async -> RenderResult<[RenderSpan]> {
        let key = language + "\u{0}" + code
        if let cached = highlightCache[key] { return cached }
        guard let host else { return RenderResult(nil) }
        let result = RenderResult(await utility(host, utilitySelector("highlight", code, language: language)) { data in
            try JSONDecoder().decode(HighlightQuery.self, from: data).data?.spans
        })
        highlightCache[key] = result
        return result
    }

    func cachedDiff(_ text: String) -> RenderResult<DiffView>? { diffCache[text] }

    func diff(_ text: String) async -> RenderResult<DiffView> {
        if let cached = diffCache[text] { return cached }
        guard let host else { return RenderResult(nil) }
        let result = RenderResult(await utility(host, utilitySelector("diff", text)) { data in
            try JSONDecoder().decode(DiffQuery.self, from: data).data
        })
        diffCache[text] = result
        return result
    }

    /// D-07: locates each file record of a (possibly large) VERDE_DIFF_V2 body so files render one at a time.
    func cachedIndex(_ body: String) -> RenderResult<DiffIndexView>? { indexCache[body] }

    func index(_ body: String) async -> RenderResult<DiffIndexView> {
        if let cached = indexCache[body] { return cached }
        guard let host else { return RenderResult(nil) }
        let result = RenderResult(await utility(host, utilitySelector("diff_index", body), limit: Self.maxIndexSelector) { data in
            try JSONDecoder().decode(DiffIndexQuery.self, from: data).data
        })
        indexCache[body] = result
        return result
    }

    private func utility<T>(_ host: CoreHost, _ selector: String, limit: Int = TranscriptModel.maxRenderSelector,
                            _ transform: @escaping (Data) throws -> T?) async -> T? {
        guard selector.utf8.count <= limit, let data = try? await host.query(selector) else { return nil }
        return await decodeDetached(data, transform)
    }
}

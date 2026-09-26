import Foundation
import Observation

/*
 * D-09 / I-05 approvals. The core owns approval truth: `thread:<id>.approval` comes from the current
 * turn's snapshot/tail and is cleared when any client resolves it. This file only sends
 * `approval_decide` and follows its receipt. The top-level helpers take a `CoreHost` and no UI
 * state so notification actions (I-08) can reuse them. Request bodies are never logged.
 */

/// The daemon only supports a one-off allow or deny per request (`chat.turn.approve`).
enum ApprovalDecision: Equatable {
    case approve, deny
    var wire: EventApprovalDecideDecision { self == .approve ? .approve : .deny }
}

/// The exact request a decision answers; the core rejects anything but the current turn + call.
struct ApprovalTarget: Equatable {
    let workspaceID: String
    let threadID: String
    let turnID: String
    let callID: String

    init(workspaceID: String, threadID: String, turnID: String, callID: String) {
        self.workspaceID = workspaceID
        self.threadID = threadID
        self.turnID = turnID
        self.callID = callID
    }

    init(workspaceID: String, threadID: String, approval: ChatApproval) {
        self.init(workspaceID: workspaceID, threadID: threadID, turnID: approval.turn_id, callID: approval.call_id)
    }
}

extension ChatApproval {
    var key: String { turn_id + "\u{0}" + call_id }
}

enum DecideResult: Equatable {
    /// The core accepted the intent; follow the intent id in `hosts.operations`.
    case sent(String)
    /// The core refused the event outright (malformed or out of budget).
    case rejected
    /// The host failed; its owner reports that separately.
    case failed
}

/// Hands one decision to the core. Never logs the target or the request body.
func decideApproval(host: CoreHost, target: ApprovalTarget, decision: ApprovalDecision,
                    intentID: String = UUID().uuidString) async -> DecideResult {
    do {
        try await host.send(.approval_decide(EventApprovalDecide(now_ms: 0, wall_time_ms: 0, intent_id: intentID,
            workspace_id: target.workspaceID, thread_id: target.threadID, turn_id: target.turnID,
            call_id: target.callID, decision: decision.wire)))
        return .sent(intentID)
    } catch CoreBridgeError.rejected {
        return .rejected
    } catch {
        return .failed
    }
}

/// The open thread's current approval as a decision target, or nil. The core only tracks approvals
/// for threads it has open (`focus`), so a push action must open the thread first: push payloads
/// carry no `call_id`.
func currentApprovalTarget(host: CoreHost, workspaceID: String, threadID: String) async -> ApprovalTarget? {
    guard let data = try? await host.query(chatSelector("thread", workspaceID, threadID)),
          let approval = (try? JSONDecoder().decode(ThreadQuery.self, from: data))?.data?.approval,
          approval.resolution != "pending" else { return nil }
    return ApprovalTarget(workspaceID: workspaceID, threadID: threadID, approval: approval)
}

private let staleCodes: Set<String> = ["stale_approval", "not_found"]

/// Codes meaning "this request is no longer the one waiting" (answered elsewhere or expired).
func staleApprovalError(_ error: LocalError?) -> Bool {
    guard let error else { return false }
    return staleCodes.contains(error.code) || error.rpc_code.map(staleCodes.contains) == true
}

/// Field-wise `LocalError` equality (the generated models are not Equatable).
func sameError(_ a: LocalError?, _ b: LocalError?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?):
        return a.domain == b.domain && a.code == b.code && a.message == b.message && a.failure_kind == b.failure_kind &&
            a.retryable == b.retryable && a.retry_after_ms == b.retry_after_ms && a.intent_id == b.intent_id &&
            a.rpc_code == b.rpc_code && a.delivery == b.delivery
    default: return false
    }
}

/// This phone's latest decision for one approval key.
struct LocalDecision {
    enum State { case sending, sent, failed, stale }
    var key: String
    var decision: ApprovalDecision
    var state: State
    var error: LocalError?
}

enum ApprovalPhase: Equatable {
    case idle
    case sending(ApprovalDecision?)
    /// The host accepted the decision; the agent has not picked it up yet.
    case sent(ApprovalDecision?)
    /// The request is no longer current — answered on another device or expired.
    case stale
    case failed(ApprovalDecision?, uncertain: Bool)

    var canDecide: Bool {
        switch self {
        case .idle, .failed: return true
        default: return false
        }
    }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var isSent: Bool { if case .sent = self { return true }; return false }
}

/// Pure merge of the core's resolution with this phone's in-flight decision.
func approvalPhase(_ approval: ChatApproval, _ local: LocalDecision?) -> ApprovalPhase {
    let mine = local?.key == approval.key ? local : nil
    if mine?.state == .stale { return .stale }
    switch approval.resolution {
    case "failed":
        return staleApprovalError(approval.error) ? .stale : .failed(mine?.decision, uncertain: approval.error?.delivery == "uncertain")
    case "pending":
        return mine?.state == .sent ? .sent(mine?.decision) : .sending(mine?.decision)
    default:
        guard let mine else { return .idle }
        switch mine.state {
        case .sending: return .sending(mine.decision)
        case .sent: return .sent(mine.decision)
        case .failed: return .failed(mine.decision, uncertain: mine.error?.delivery == "uncertain")
        case .stale: return .stale
        }
    }
}

/// What happened to an approval that just left the transcript.
enum ApprovalOutcome: Equatable {
    case approved, denied, elsewhere, closed
    var text: String {
        switch self {
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .elsewhere: return "Approval answered on another device"
        case .closed: return "Approval request closed"
        }
    }
}

struct OutcomeNotice: Equatable {
    let outcome: ApprovalOutcome
    let serial: Int
}

func phaseText(_ phase: ApprovalPhase) -> String? {
    switch phase {
    case .idle: return nil
    case .sending(let decision):
        switch decision {
        case .approve: return "Sending your approval…"
        case .deny: return "Sending your denial…"
        case nil: return "Sending your decision…"
        }
    case .sent(let decision):
        return decision == .deny ? "Denied — waiting for the agent." : "Approved — waiting for the agent to continue."
    case .stale: return "This request is no longer waiting. It was answered elsewhere or expired."
    case .failed(_, let uncertain):
        return uncertain ? "Couldn't confirm your decision reached the host. Try again." : "Couldn't send your decision. Try again."
    }
}

/// Haptic kinds (Android `Confirm` / `Reject`), played by `ApprovalHaptics`.
enum ApprovalFeedback: Equatable { case confirm, reject }

/// The haptic for a tap that sent `decision`.
func tapFeedback(_ decision: ApprovalDecision) -> ApprovalFeedback { decision == .approve ? .confirm : .reject }

/// A failure or confirmation the user didn't just cause (e.g. a retried send) is still felt once.
func phaseFeedback(from previous: ApprovalPhase, to next: ApprovalPhase) -> ApprovalFeedback? {
    if next.isFailed && !previous.isFailed { return .reject }
    if next.isSent && !previous.isSent { return .confirm }
    return nil
}

/// A VoiceOver announcement for a phase change; failures interrupt (high priority).
struct ApprovalAnnouncement: Equatable {
    let text: String
    let urgent: Bool
}

func phaseAnnouncement(from previous: ApprovalPhase, to next: ApprovalPhase) -> ApprovalAnnouncement? {
    guard next != previous, let text = phaseText(next) else { return nil }
    return ApprovalAnnouncement(text: text, urgent: next.isFailed)
}

/// One thread's approval decisions. Tracks this phone's decision through the core receipt and
/// notices when the pending approval disappears, to say who resolved it. Driven by its owner:
/// `update(thread:)` on every new thread projection, `settle(operations:)` on every hosts change.
@MainActor @Observable
final class ApprovalController {
    static let outcomeDelay: TimeInterval = 4

    private(set) var local: LocalDecision?
    /// Transient notice after an approval leaves; cleared after a few seconds.
    private(set) var outcome: OutcomeNotice?

    @ObservationIgnored private let workspaceID: String
    @ObservationIgnored private let threadID: String
    @ObservationIgnored private let host: () -> CoreHost?
    @ObservationIgnored private let operations: () -> [Operation]?
    @ObservationIgnored private let outcomeDelay: TimeInterval
    @ObservationIgnored private var last: ChatApproval?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var clearing: Task<Void, Never>?
    @ObservationIgnored private var pending: (key: String, intentID: String)?

    init(workspaceID: String, threadID: String, host: @escaping () -> CoreHost?,
         operations: @escaping () -> [Operation]?, outcomeDelay: TimeInterval = ApprovalController.outcomeDelay) {
        self.workspaceID = workspaceID
        self.threadID = threadID
        self.host = host
        self.operations = operations
        self.outcomeDelay = outcomeDelay
    }

    /// A new thread projection (nil projections are ignored, like a missing snapshot).
    func update(thread view: ChatThreadView?) {
        guard let view else { return }
        let current = view.approval
        let previous = last
        last = current
        if let previous, current?.key != previous.key { resolved(previous, view) }
        if current != nil && outcome != nil { outcome = nil }
    }

    /// Settles this phone's in-flight decision from the core receipt.
    func settle(operations: [Operation]?) {
        guard let pending, let op = operations?.first(where: { $0.intent_id == pending.intentID }), op.state != "pending" else { return }
        self.pending = nil
        let next: (LocalDecision.State, LocalError?)
        if op.state == "succeeded" { next = (.sent, nil) }
        else if staleApprovalError(op.error) { next = (.stale, op.error) }
        else { next = (.failed, op.error) }
        if var mine = local, mine.key == pending.key {
            mine.state = next.0
            mine.error = next.1
            local = mine
        }
    }

    /// Host switch: nothing carries over.
    func reset() {
        local = nil
        outcome = nil
        last = nil
        pending = nil
        clearing?.cancel()
    }

    private func resolved(_ previous: ChatApproval, _ view: ChatThreadView) {
        let mine = local?.key == previous.key ? local : nil
        let result: ApprovalOutcome
        if let mine, mine.state == .sending || mine.state == .sent {
            result = mine.decision == .approve ? .approved : .denied
        } else if let turn = view.turn, activeTurn(turn.status), turn.turn_id == previous.turn_id {
            result = .elsewhere
        } else {
            result = .closed
        }
        if mine != nil { local = nil; pending = nil }
        serial += 1
        outcome = OutcomeNotice(outcome: result, serial: serial)
        clearing?.cancel()
        let delay = UInt64(outcomeDelay * 1_000_000_000)
        clearing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.outcome = nil
        }
    }

    /// Sends `decision` for `approval` unless one is already on its way. Returns whether it was sent.
    @discardableResult
    func decide(_ approval: ChatApproval, _ decision: ApprovalDecision) -> Bool {
        guard let host = host(), approvalPhase(approval, local).canDecide else { return false }
        let key = approval.key
        local = LocalDecision(key: key, decision: decision, state: .sending)
        let target = ApprovalTarget(workspaceID: workspaceID, threadID: threadID, approval: approval)
        Task { [weak self] in
            let result = await decideApproval(host: host, target: target, decision: decision)
            guard let self else { return }
            switch result {
            case .sent(let id):
                self.pending = (key, id)
                self.settle(operations: self.operations())
            case .rejected, .failed:
                if var mine = self.local, mine.key == key {
                    mine.state = .failed
                    mine.error = nil
                    self.local = mine
                }
            }
        }
        return true
    }
}

// MARK: - What is being approved

enum PreviewKind: Equatable { case add, remove, context, hunk }

struct PreviewLine: Equatable {
    let kind: PreviewKind
    let text: String
}

/// Structured view of an approval body. Providers send free text: Claude's bridge sends
/// `Tool:`/`Path:`/`Reason:` sections plus the tool input as JSON, Codex sends the bare command,
/// OpenCode an `Action:` line. Anything unrecognised is still shown verbatim in the details.
struct ApprovalPreview: Equatable {
    var tool: String?
    var command: String?
    var path: String?
    var reason: String?
    var changes: [PreviewLine] = []
    var changesTruncated = false
}

private let previewUnits = 64 * 1024
let previewLines = 24

private func firstLine(_ text: Substring) -> String {
    String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        .trimmingCharacters(in: .whitespaces)
}

func approvalPreview(_ approval: ChatApproval) -> ApprovalPreview {
    let body = approval.body
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ApprovalPreview() }
    let units = body.utf16
    let oversized = units.count > previewUnits
    let headText = oversized ? truncatedHead(body) : body
    var out = ApprovalPreview()
    var lines: [PreviewLine] = []
    var truncated = false
    func add(_ kind: PreviewKind, _ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= previewLines { truncated = true; return }
            lines.append(PreviewLine(kind: kind, text: String(line)))
        }
    }
    let sections = headText.components(separatedBy: "\n\n")
    var jsonStart = -1
    for (index, section) in sections.enumerated() {
        let s = section.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("Tool: ") { out.tool = firstLine(s.dropFirst(6)) }
        else if s.hasPrefix("Action: ") { out.tool = firstLine(s.dropFirst(8)) }
        else if s.hasPrefix("Path: ") { out.path = firstLine(s.dropFirst(6)) }
        else if s.hasPrefix("Reason: ") { out.reason = String(s.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) }
        else if s.hasPrefix("{") && jsonStart < 0 { jsonStart = index }
    }
    if jsonStart >= 0 && !oversized,
       let data = sections[jsonStart...].joined(separator: "\n\n").data(using: .utf8),
       let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        func str(_ name: String) -> String? { input[name] as? String }
        if let command = str("command") { out.command = command }
        else if let parts = input["command"] as? [Any] {
            out.command = parts.compactMap { part -> String? in
                if let s = part as? String { return s }
                if let n = part as? NSNumber { return n.stringValue }
                return nil
            }.joined(separator: " ")
        }
        out.path = str("file_path") ?? str("notebook_path") ?? str("path") ?? out.path
        let edits = (input["edits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [input]
        for edit in edits {
            let old = edit["old_string"] as? String, new = edit["new_string"] as? String
            if old != nil || new != nil {
                if let old, !old.isEmpty { add(.remove, old) }
                if let new, !new.isEmpty { add(.add, new) }
            }
        }
        if lines.isEmpty, let content = str("content") { add(.add, content) }
    }
    if lines.isEmpty && isUnifiedDiff(headText) {
        for line in headText.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= previewLines { truncated = true; break }
            if line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") {
                lines.append(PreviewLine(kind: .hunk, text: String(line)))
            } else if line.hasPrefix("+") {
                lines.append(PreviewLine(kind: .add, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                lines.append(PreviewLine(kind: .remove, text: String(line.dropFirst())))
            } else {
                lines.append(PreviewLine(kind: .context, text: String(line.hasPrefix(" ") ? line.dropFirst() : line)))
            }
        }
    }
    // Codex's command approvals carry the bare command as the whole body.
    if out.command == nil && out.tool == nil && lines.isEmpty && approval.title.localizedCaseInsensitiveContains("command") &&
        !headText.contains("\n\n") && headText.utf16.count <= 4096 {
        out.command = headText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    out.changes = lines
    out.changesTruncated = truncated
    return out
}

/// The first 64 Ki UTF-16 units, rounded down to a scalar boundary.
private func truncatedHead(_ body: String) -> String {
    let units = body.utf16
    var end = units.index(units.startIndex, offsetBy: previewUnits)
    while end.samePosition(in: body.unicodeScalars) == nil { end = units.index(before: end) }
    return String(body.unicodeScalars[..<end])
}

private func isUnifiedDiff(_ text: String) -> Bool {
    let lines = text.split(separator: "\n", maxSplits: 400, omittingEmptySubsequences: false).prefix(400)
    return lines.contains { $0.hasPrefix("diff --git ") } ||
        (lines.contains { $0.hasPrefix("@@ ") } && lines.contains { $0.hasPrefix("+++ ") || $0.hasPrefix("--- ") })
}

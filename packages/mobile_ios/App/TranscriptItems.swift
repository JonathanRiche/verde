import Foundation

/// One visible transcript entry. Rows come from the core's thread projection; this layer only
/// groups and classifies them (desktop/web ChatPane parity, Android D-06) so each kind gets its
/// own renderer. Message bodies are never logged.
enum TranscriptItem: Identifiable {
    /// A user, assistant or plain system message rendered from the core's markdown AST.
    case message(ChatRow)
    /// A lone tool/command call.
    case tool(ChatRow)
    /// Consecutive tool calls (2+) or subagent calls (1+), collapsed behind a summary.
    case toolGroup([ChatRow], subagent: Bool)
    /// Model reasoning (`think` tool rows).
    case think(ChatRow)
    /// "Changed files" VERDE_DIFF_V2 summary row.
    case diff(ChatRow)
    /// System notices, including A-09 access-cap notices.
    case notice(ChatRow)
    /// The latest provider usage summary, parsed by the core.
    case usage(ChatRow, ChatUsage)
    /// Live "Working · m:ss" footer for the core's active turn.
    case working(ChatTurn, waitingApproval: Bool)
    /// Pending tool approval.
    case approval(ChatApproval)

    var id: String {
        switch self {
        case .message(let row), .tool(let row), .think(let row), .diff(let row), .notice(let row), .usage(let row, _):
            return "r:" + row.id
        case .toolGroup(let rows, let subagent): return "g:\(subagent ? "subagent" : "tool"):" + (rows.first?.id ?? "")
        case .working: return "working"
        case .approval(let approval): return "approval:\(approval.turn_id):\(approval.call_id)"
        }
    }

    /// Stable kind name (tests and accessibility identifiers).
    var kindName: String {
        switch self {
        case .message: return "Message"
        case .tool: return "Tool"
        case .toolGroup: return "ToolGroup"
        case .think: return "Think"
        case .diff: return "Diff"
        case .notice: return "Notice"
        case .usage: return "Usage"
        case .working: return "Working"
        case .approval: return "Approval"
        }
    }
}

let diffMarker = "VERDE_DIFF_V2\n"
private let hiddenAuthor = "__verde_codex_background_snapshot"

func activeTurn(_ status: String) -> Bool {
    ["working", "waiting", "accepted", "running", "waiting_approval"].contains(status)
}

private func shellLike(_ body: String) -> Bool {
    let t = body.drop { $0.isWhitespace }
    if t.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 { return false }
    return ["/usr/bin/bash", "/bin/bash", "bash -lc", "/usr/bin/env bash", "/bin/sh -lc", "/usr/bin/sh"].contains { t.hasPrefix($0) }
}

func isDiffRow(_ row: ChatRow) -> Bool {
    row.role == "system" && row.author == "Changed files" && row.body.hasPrefix(diffMarker)
}

func isThinkRow(_ row: ChatRow) -> Bool {
    row.role == "system" && (row.tool?.kind == "think" ||
        (row.tool == nil && row.kind == "tool" && (row.author == "Think" || row.author == "Thinking")))
}

func isCommandRow(_ row: ChatRow) -> Bool {
    guard row.role == "system" else { return false }
    if row.tool?.kind == "subagent" || row.author == "Subagent" { return true }
    if let tool = row.tool, tool.kind != "think" { return true }
    return row.author == "Ran command" || row.author == "Command failed" || shellLike(row.body)
}

func isSubagentRow(_ row: ChatRow) -> Bool {
    if row.tool?.kind == "subagent" || row.author == "Subagent" { return true }
    if row.author == "Ran command" || row.author == "Command failed" { return false }
    if let tool = toolField(row.body, "Tool"),
       ["task", "agent", "subagent", "taskexecute", "spawnagent", "spawn_agent"].contains(tool.trimmingCharacters(in: .whitespaces).lowercased()) {
        return true
    }
    if toolField(row.body, "Input")?.contains("\"subagent_type\"") == true { return true }
    return toolField(row.body, "Output")?.contains("<task id=\"") == true
}

/// The `Label:\n...` section of a tool body, up to the next blank line.
func toolField(_ body: String, _ label: String) -> String? {
    let prefix = label + ":\n"
    let rest: Substring
    if body.hasPrefix(prefix) {
        rest = body.dropFirst(prefix.count)
    } else if let range = body.range(of: "\n\n" + prefix) {
        rest = body[range.upperBound...]
    } else {
        return nil
    }
    let value = rest.range(of: "\n\n").map { rest[..<$0.lowerBound] } ?? rest
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func commandFailed(_ row: ChatRow) -> Bool {
    row.tool?.status == "failed" || row.author == "Command failed" || row.body.hasPrefix("Command failed")
}

func commandRunning(_ row: ChatRow) -> Bool { row.tool?.status == "in_progress" || row.tool?.status == "pending" }

/// Whitespace-collapsed one-line preview of the leading slice of a (possibly huge) tool body.
func commandPreview(_ body: String, max: Int = 400) -> String {
    String(body.prefix(max)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// First `max` lines without splitting a multi-megabyte body into lines.
func leadingLines(_ body: String, _ max: Int) -> (text: String, truncated: Bool) {
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, max > 0 else { return ("", false) }
    let scalars = text.unicodeScalars
    var from = scalars.startIndex
    for _ in 0..<max {
        guard let newline = scalars[from...].firstIndex(of: "\n") else { return (text, false) }
        from = scalars.index(after: newline)
    }
    let cut = scalars.index(before: from)
    return (String(scalars[..<cut]), from < scalars.endIndex)
}

func countLines(_ body: String) -> Int {
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? 0 : 1 + text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
}

/// Host paths stay abstract on the phone; only the file name is shown.
func basename(_ path: String) -> String {
    var trimmed = Substring(path)
    while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    let name = trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    return name.isEmpty ? path : name
}

struct ToolCounts: Equatable {
    var count: Int
    var completed: Int
    var failed: Int
    var running: Int
}

func toolCounts(_ rows: [ChatRow]) -> ToolCounts {
    var failed = 0, running = 0
    for row in rows {
        if commandFailed(row) { failed += 1 } else if commandRunning(row) { running += 1 }
    }
    return ToolCounts(count: rows.count, completed: rows.count - failed - running, failed: failed, running: running)
}

func toolGroupSummary(_ rows: [ChatRow], subagent: Bool, elapsed: String?) -> String {
    let c = toolCounts(rows)
    let noun = subagent ? (c.count == 1 ? "subagent" : "subagents") : (c.count == 1 ? "tool call" : "tool calls")
    var parts = ["\(c.count) \(noun)", "\(c.completed) completed"]
    if c.failed > 0 { parts.append("\(c.failed) failed") }
    if c.running > 0 { parts.append("\(c.running) running") }
    if c.running > 0, let elapsed { parts.append(elapsed) }
    return parts.joined(separator: " · ")
}

func toolStatusLabel(_ row: ChatRow) -> String {
    commandFailed(row) ? "Failed" : commandRunning(row) ? "Running" : "Completed"
}

/// Pure projection from the core's thread view to renderable items (oldest first).
func transcriptItems(_ view: ChatThreadView) -> [TranscriptItem] {
    var out: [TranscriptItem] = []
    out.reserveCapacity(view.rows.count + 2)
    let lastUsage = view.usage == nil ? -1 : (view.rows.lastIndex { $0.role == "system" && $0.author == "Usage" } ?? -1)
    var run: [ChatRow] = []
    var runSubagent = false
    func flush() {
        if run.isEmpty { return }
        if runSubagent { out.append(.toolGroup(run, subagent: true)) }
        else if run.count >= 2 { out.append(.toolGroup(run, subagent: false)) }
        else { out.append(.tool(run[0])) }
        run = []
        runSubagent = false
    }
    for (index, row) in view.rows.enumerated() {
        if row.author == hiddenAuthor { continue }
        if isCommandRow(row) && !isDiffRow(row) {
            let subagent = isSubagentRow(row)
            if !run.isEmpty && subagent != runSubagent { flush() }
            runSubagent = subagent
            run.append(row)
            continue
        }
        flush()
        if isDiffRow(row) { out.append(.diff(row)) }
        else if isThinkRow(row) { out.append(.think(row)) }
        else if index == lastUsage, let usage = view.usage { out.append(.usage(row, usage)) }
        else if row.role == "system" { out.append(.notice(row)) }
        else { out.append(.message(row)) }
    }
    flush()
    if let approval = view.approval { out.append(.approval(approval)) }
    if let turn = view.turn, activeTurn(turn.status) {
        out.append(.working(turn, waitingApproval: turn.status == "waiting_approval" || view.approval != nil))
    }
    return out
}

func workingLabel(_ turn: ChatTurn, waitingApproval: Bool, elapsed: String?) -> String {
    let verb = turn.stop_pending ? "Stopping" : waitingApproval ? "Waiting for approval" : "Working"
    return elapsed.map { "\(verb) · \($0)" } ?? verb
}

func deliveryLabel(_ delivery: String) -> String? {
    switch delivery {
    case "optimistic": return "Sending…"
    case "streaming": return "Streaming"
    case "failed": return "Not sent"
    default: return nil
    }
}

/// Streaming bodies re-render per delta; only a bounded tail is sent for markdown until commit.
func streamTail(_ row: ChatRow, max: Int = 16_000) -> String {
    let units = row.body.utf16
    guard row.delivery == "streaming", units.count > max else { return row.body }
    var start = units.index(units.endIndex, offsetBy: -max)
    let scalars = row.body.unicodeScalars
    // Round up to a scalar boundary, then prefer starting after the next newline.
    while start.samePosition(in: scalars) == nil { start = units.index(after: start) }
    let tail = scalars[start...]
    if let newline = tail.firstIndex(of: "\n") { return String(scalars[scalars.index(after: newline)...]) }
    return String(tail)
}

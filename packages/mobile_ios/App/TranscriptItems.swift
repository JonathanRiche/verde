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
    /// Linked child chats' status notifications, delivered to their parent as a user or system
    /// turn; a batched delivery carries several (one card each).
    case childNotification(ChatRow, [ChildNotification])
    /// The latest provider usage summary, parsed by the core.
    case usage(ChatRow, ChatUsage)
    /// Live "Working · m:ss" footer for the core's active turn.
    case working(ChatTurn, waitingApproval: Bool)
    /// Pending tool approval.
    case approval(ChatApproval)

    var id: String {
        switch self {
        case .message(let row), .tool(let row), .think(let row), .diff(let row), .notice(let row), .usage(let row, _),
             .childNotification(let row, _):
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
        case .childNotification: return "ChildNotification"
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

/// "4 tool calls · 1 failed": the count, then only what didn't simply finish.
func toolGroupSummary(_ rows: [ChatRow], subagent: Bool, elapsed: String?) -> String {
    let c = toolCounts(rows)
    let noun = subagent ? (c.count == 1 ? "subagent" : "subagents") : (c.count == 1 ? "tool call" : "tool calls")
    var parts = ["\(c.count) \(noun)"]
    if c.failed > 0 { parts.append("\(c.failed) failed") }
    if c.running > 0 { parts.append("\(c.running) running") }
    if c.running > 0, let elapsed { parts.append(elapsed) }
    return parts.joined(separator: " · ")
}

func toolStatusLabel(_ row: ChatRow) -> String {
    commandFailed(row) ? "Failed" : commandRunning(row) ? "Running" : "Completed"
}

/// What a tool row shows (desktop ToolRow parity): the core's parsed fields when it sends them,
/// else the row's author and body sections.
struct ToolParts: Equatable {
    var kind: String
    var title: String
    /// One plain line naming what the call acts on; empty when nothing fits.
    var summary: String
    var input: String?
    var output: String?
    var error: String?
}

/// The tool's kind (read, edit, delete, move, search, execute, think, fetch, mcp, subagent, other).
func toolKind(_ row: ChatRow) -> String {
    if let kind = row.tool?.kind, !kind.isEmpty { return kind }
    switch row.author.lowercased() {
    case "ran command", "command failed", "bash", "shell": return "execute"
    case "read": return "read"
    case "edit", "write", "multiedit": return "edit"
    case "search", "grep", "glob": return "search"
    case "subagent", "task": return "subagent"
    case "fetch", "webfetch", "websearch": return "fetch"
    default: return shellLike(row.body) ? "execute" : "other"
    }
}

/// SF Symbol per tool kind.
func toolSymbol(_ kind: String) -> String {
    switch kind {
    case "read": return "doc.text"
    case "edit": return "pencil"
    case "delete": return "trash"
    case "move": return "arrow.right"
    case "search": return "magnifyingglass"
    case "execute": return "terminal"
    case "think": return "lightbulb"
    case "fetch": return "globe"
    case "mcp": return "wrench.and.screwdriver"
    case "subagent": return "person.2"
    default: return "wrench"
    }
}

private let summaryKeys = ["command", "cmd", "file_path", "filePath", "path", "pattern", "query", "url", "name", "description"]

/// The value an input names first (command, path, pattern, url…), or its first plain line.
func toolInputSummary(_ input: String?) -> String {
    guard let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else { return "" }
    if input.hasPrefix("{"), let data = input.data(using: .utf8),
       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        for key in summaryKeys {
            if let value = object[key] as? String, !value.isEmpty { return oneLine(value) }
            if let parts = object[key] as? [String], !parts.isEmpty { return oneLine(parts.joined(separator: " ")) }
        }
        return ""
    }
    return oneLine(input)
}

private func oneLine(_ text: String) -> String {
    let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return String(first.prefix(300)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`")))
}

func toolParts(_ row: ChatRow) -> ToolParts {
    let body = row.body
    let input = toolField(body, "Input")
    let output = toolField(body, "Output")
    let error = toolField(body, "Error")
    let sectioned = input != nil || output != nil || error != nil || toolField(body, "Tool") != nil
    let raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = row.author.isEmpty ? "Tool" : row.author
    var summary = toolInputSummary(input)
    if summary.isEmpty, !sectioned { summary = oneLine(raw) }
    return coreToolParts(row, ToolParts(kind: toolKind(row), title: title, summary: summary, input: input,
                                        output: sectioned ? output : (raw.isEmpty ? nil : raw), error: error))
}

/// The core's parsed tool fields, where present, over the local fallback.
private func coreToolParts(_ row: ChatRow, _ fallback: ToolParts) -> ToolParts {
    guard let tool = row.tool else { return fallback }
    func present(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    var parts = fallback
    if let title = present(tool.title) { parts.title = title }
    if let summary = present(tool.summary) { parts.summary = summary }
    // Sections come together from one parse; mixing the core's with the fallback's could repeat one.
    if present(tool.input) != nil || present(tool.output) != nil || present(tool.error) != nil {
        parts.input = present(tool.input)
        parts.output = present(tool.output)
        parts.error = present(tool.error)
    }
    return parts
}

/// The text Copy puts on the pasteboard: the whole tool body.
func toolCopyText(_ row: ChatRow) -> String { row.body }

/// A Read's output is the file's text: highlight it by the path's extension (S13).
func toolOutputLanguage(_ parts: ToolParts) -> String? {
    guard parts.kind == "read" else { return nil }
    let ext = (parts.summary as NSString).pathExtension.lowercased()
    return ext.isEmpty || ext.count > 10 ? nil : ext
}

/// One diff line's role in an Edit's unified-diff output.
enum ToolDiffLine: Equatable { case hunk, add, delete, context }

/// Unified-diff output (an Edit's result) is coloured like the patch view.
func toolOutputIsDiff(_ parts: ToolParts) -> Bool {
    guard parts.kind == "edit", let output = parts.output else { return false }
    return output.hasPrefix("@@") || output.contains("\n@@") || output.hasPrefix("--- ") || output.hasPrefix("diff --git")
}

func toolDiffLine(_ line: Substring) -> ToolDiffLine {
    if line.hasPrefix("@@") { return .hunk }
    if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .hunk }
    if line.hasPrefix("+") { return .add }
    if line.hasPrefix("-") { return .delete }
    return .context
}

/// Consecutive live-voice lines from one speaker become one row (the first row's id, the last
/// row's delivery): a user turn's pieces are merged by `mergedSpeech` (which also cleans up older
/// saves of fragments and cumulative snapshots), a companion's replies become paragraphs.
func groupVoiceRows(_ rows: [ChatRow]) -> [ChatRow] {
    var out: [ChatRow] = []
    out.reserveCapacity(rows.count)
    var run: [ChatRow] = []
    func flush() {
        guard var merged = run.first else { return }
        if run.count > 1 {
            let bodies = run.map(\.body)
            merged.body = merged.role == "user" ? mergedSpeech(bodies)
                : bodies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            merged.delivery = run[run.count - 1].delivery
        }
        out.append(merged)
        run = []
    }
    for row in rows {
        let voice = (row.role == "user" || row.role == "assistant") && isVoiceSpeaker(row.author)
        if let first = run.first, !(voice && row.role == first.role && row.author == first.author) { flush() }
        if voice { run.append(row) } else { out.append(row) }
    }
    flush()
    return out
}

/// Pure projection from the core's thread view to renderable items (oldest first).
func transcriptItems(_ view: ChatThreadView) -> [TranscriptItem] {
    var out: [TranscriptItem] = []
    out.reserveCapacity(view.rows.count + 2)
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
    let rows = view.rows.contains(where: { isVoiceSpeaker($0.author) }) ? groupVoiceRows(view.rows) : view.rows
    let lastUsage = view.usage == nil ? -1 : (rows.lastIndex { $0.role == "system" && $0.author == "Usage" } ?? -1)
    for (index, row) in rows.enumerated() {
        if row.author == hiddenAuthor { continue }
        if let notifications = childNotifications(role: row.role, body: row.body) {
            flush()
            out.append(.childNotification(row, notifications))
            continue
        }
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

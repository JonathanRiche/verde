import Foundation

/*
 * Pure helpers for the tools a live voice session can call on the phone: ask_companion,
 * companion_status and decide_approval. `LiveVoice` runs them against the existing models.
 */

enum LiveToolName {
    static let askCompanion = "ask_companion"
    static let companionStatus = "companion_status"
    static let decideApproval = "decide_approval"
}

/// A tool call's arguments object (empty when missing or not an object).
func toolArguments(_ raw: String) -> [String: Any] { (jsonObject(raw) as? [String: Any]) ?? [:] }

func stringArgument(_ value: Any?) -> String? {
    let text: String?
    if let value = value as? String { text = value } else if let value = value as? NSNumber { text = value.stringValue } else { text = nil }
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

/// Models send booleans in several shapes: true/false, 1/0, or words.
func boolArgument(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    guard let word = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
    if ["true", "yes", "approve", "approved", "allow", "1"].contains(word) { return true }
    if ["false", "no", "deny", "denied", "reject", "0"].contains(word) { return false }
    return nil
}

enum ApprovalMatch: Equatable {
    case found(NeedsYouItem)
    case ambiguous
    case notFound
}

/// Picks the pending approval the user named. An exact (case-insensitive) title wins; otherwise the
/// name must appear in exactly one title or "title workspace" string. With a single pending approval
/// an empty name picks it.
func matchApproval(_ query: String, _ pending: [NeedsYouItem]) -> ApprovalMatch {
    let approvals = pending.filter { $0.reason == "Needs approval" }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if needle.isEmpty { return approvals.count == 1 ? .found(approvals[0]) : approvals.isEmpty ? .notFound : .ambiguous }
    let exact = approvals.filter { $0.title.lowercased() == needle }
    if exact.count == 1 { return .found(exact[0]) }
    if exact.count > 1 { return .ambiguous }
    let partial = approvals.filter { item in
        let haystack = (item.title + " " + (item.workspaceLabel ?? "")).lowercased()
        return haystack.contains(needle)
    }
    if partial.count == 1 { return .found(partial[0]) }
    return partial.isEmpty ? .notFound : .ambiguous
}

/// `companion_status`: what needs the user and what the crew is doing.
func companionStatusJSON(name: String, status: String, needsYou: [NeedsYouItem], crew: [CrewLink], workspaceLabels: [String: String]) -> String {
    let needs: [[String: Any]] = needsYou.map { item -> [String: Any] in
        ["chat": item.title, "workspace": item.workspaceLabel ?? "", "reason": item.reason]
    }
    let members: [[String: Any]] = crew.map { link -> [String: Any] in
        ["chat": link.displayTitle, "workspace": workspaceLabels[link.workspace_id] ?? "", "status": link.attention.label,
         "summary": link.detail ?? ""]
    }
    return jsonString(["companion": name, "status": status, "needs_you": needs, "crew": members])
}

/// The companion's finished reply for the live model: plain text, at most ~600 characters.
func companionUpdateText(_ body: String, limit: Int = 600) -> String {
    let plain = speechLines(body).joined(separator: " ")
    let clipped = plain.count > limit ? String(plain.prefix(limit)) + "…" : plain
    return "companion_update: " + (clipped.isEmpty ? "(no text reply)" : clipped)
}

func toolError(_ code: String) -> String { jsonString(["error": code]) }

import Foundation

/*
 * The text record of a live voice conversation, saved into the companion's chat
 * (`companion_transcript_save`) so the conversation survives as ordinary history. Pure and unit
 * tested: lines accumulate from streaming events, finished lines are saved in order, and keys
 * ("<session>:<n>") make every save idempotent. Audio is never kept.
 */

struct LiveTranscriptLine: Equatable {
    var key: String
    /// `user`, `assistant` or `system`.
    var role: String
    var author: String
    var body: String
    var createdAtMs: Int64
}

struct LiveTranscript {
    static let batchLimit = 200
    static let systemAuthor = "Live"

    let sessionID: String
    let companionName: String
    private(set) var lines: [LiveTranscriptLine] = []
    /// Lines `0..<saved` are on the desktop.
    private(set) var saved = 0
    private var counter = 0
    /// The current utterance's line: transcript updates replace or extend it until the user starts
    /// a new utterance.
    private var userLine: Int?
    /// Its transcript is final (no more updates expected before saving).
    private var userDone = false
    private var assistantOpen: Int?

    /// Starts with "🎙 Live voice · <provider> · <time>"; it is only saved alongside real content.
    init(sessionID: String, companionName: String, providerLabel: String, startedAt: Date = Date(), timeText: String? = nil) {
        self.sessionID = sessionID
        self.companionName = companionName
        let time = timeText ?? DateFormatter.localizedString(from: startedAt, dateStyle: .none, timeStyle: .short)
        let parts = ["🎙 Live voice", providerLabel, time].filter { !$0.isEmpty }
        append(role: "system", author: Self.systemAuthor, body: parts.joined(separator: " · "), at: Int64(startedAt.timeIntervalSince1970 * 1000))
    }

    var userAuthor: String { "You (voice)" }
    var assistantAuthor: String { companionName + " (voice)" }

    /// True until something besides the header line was said or done.
    var isEmpty: Bool { !lines.dropFirst().contains { !$0.body.isEmpty } }

    private mutating func nextKey() -> String {
        defer { counter += 1 }
        return "\(sessionID):\(counter)"
    }

    @discardableResult
    private mutating func append(role: String, author: String, body: String, at: Int64) -> Int {
        lines.append(LiveTranscriptLine(key: nextKey(), role: role, author: author, body: body, createdAtMs: at))
        return lines.count - 1
    }

    /// What the user said. `cumulative` and `final` updates carry the whole utterance so far
    /// (replace); others are deltas (append). Transcription often lands after the reply started,
    /// so a new utterance line goes before that unsaved reply to keep the conversation's order.
    mutating func user(_ text: String, final: Bool, cumulative: Bool, at: Int64) {
        if let index = userLine, index >= saved {
            lines[index].body = cumulative || final ? text : lines[index].body + text
        } else {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let trailing = lines.indices.last.flatMap { lines[$0].role == "assistant" && $0 >= saved && $0 > 0 ? $0 : nil }
            if let reply = assistantOpen ?? trailing {
                let line = LiveTranscriptLine(key: nextKey(), role: "user", author: userAuthor, body: text,
                                              createdAtMs: min(at, lines[reply].createdAtMs - 1))
                lines.insert(line, at: reply)
                if let open = assistantOpen { assistantOpen = open + 1 }
                userLine = reply
            } else {
                userLine = append(role: "user", author: userAuthor, body: text, at: at)
            }
        }
        if let index = userLine, final || cumulative { lines[index].body = lines[index].body.trimmingCharacters(in: .whitespacesAndNewlines) }
        userDone = final
    }

    /// A piece of the spoken reply; one line per response.
    mutating func assistant(_ delta: String, at: Int64) {
        if let index = assistantOpen {
            lines[index].body += delta
        } else {
            guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            assistantOpen = append(role: "assistant", author: assistantAuthor, body: delta, at: at)
        }
    }

    /// The response finished or was cut off. `newTurn` (Gemini's turnComplete) also ends the
    /// utterance; OpenAI-style sessions end it when the user starts speaking again.
    mutating func endResponse(newTurn: Bool = false) {
        closeAssistant()
        if newTurn { closeUser() }
    }

    /// The user started a new utterance (barge-in included).
    mutating func speechStarted() {
        closeAssistant()
        closeUser()
    }

    /// A tool hand-off ("→ Asked Moss: …").
    mutating func system(_ text: String, at: Int64) {
        closeUser()
        closeAssistant()
        append(role: "system", author: Self.systemAuthor, body: text, at: at)
    }

    private mutating func closeUser() {
        if let index = userLine { lines[index].body = lines[index].body.trimmingCharacters(in: .whitespacesAndNewlines) }
        userLine = nil
        userDone = false
    }

    private mutating func closeAssistant() {
        if let index = assistantOpen { lines[index].body = lines[index].body.trimmingCharacters(in: .whitespacesAndNewlines) }
        assistantOpen = nil
    }

    /// Closes everything still streaming (the session is ending).
    mutating func finish() {
        closeUser()
        closeAssistant()
    }

    /// The utterance being transcribed, for captions.
    var currentUserText: String? { userLine.map { lines[$0].body } }

    /// Finished lines not yet saved, oldest first; open lines (and anything after them) wait.
    var unsaved: [LiveTranscriptLine] {
        guard !isEmpty else { return [] }
        let open = [assistantOpen, userDone ? nil : userLine].compactMap { $0 }.min() ?? lines.count
        guard open > saved else { return [] }
        return Array(lines[saved..<open]).filter { !$0.body.isEmpty }
    }

    /// Records that every line up to and including `key` reached the desktop.
    mutating func markSaved(through key: String) {
        if let index = lines.firstIndex(where: { $0.key == key }), index >= saved { saved = index + 1 }
    }
}

/// Splits lines into events of at most `limit` messages.
func transcriptBatches(_ lines: [LiveTranscriptLine], limit: Int = LiveTranscript.batchLimit) -> [[LiveTranscriptLine]] {
    stride(from: 0, to: lines.count, by: max(1, limit)).map { Array(lines[$0..<min($0 + max(1, limit), lines.count)]) }
}

/// Voice-conversation lines in the chat (rendered with a mic glyph in the Companion sheet).
func isVoiceAuthor(_ author: String) -> Bool { author.hasSuffix("(voice)") || author == LiveTranscript.systemAuthor }

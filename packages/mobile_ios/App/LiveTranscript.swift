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
    /// Lines are tracked by key: inserting or dropping lines never misdirects an update.
    private var userOpenKey: String?
    private var userItem: String?
    private var assistantOpenKey: String?
    /// The last user line plain deltas may still extend (Gemini sends input pieces late).
    private var appendKey: String?
    private var lastUserUpdate: Int64 = 0
    /// Transcription item id → its line, so updates for an item replace that line.
    private var itemKeys: [String: String] = [:]
    /// xAI's cumulative transcript keeps growing across utterances: the part already committed
    /// to closed lines, and the newest snapshot.
    private var cumulativeStream = false
    private var committedSnapshot = ""
    private var latestSnapshot = ""
    /// A user line with no updates for this long is complete.
    static let userIdleMs: Int64 = 3000

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

    private func index(of key: String?) -> Int? {
        guard let key else { return nil }
        return lines.firstIndex { $0.key == key }
    }

    /// What the user said, per transcription `item`. `cumulative` and `final` updates carry the
    /// whole transcript so far (replace); others are deltas (append). On a cumulative stream the
    /// text already committed to earlier lines is stripped, so each utterance is saved once.
    /// A late final transcript goes before the unsaved reply it triggered.
    mutating func user(_ text: String, final: Bool, cumulative: Bool, item: String? = nil, at: Int64) {
        let whole = cumulative || final
        if let item, userOpenKey != nil, let current = userItem, current != item { closeUser() }
        if cumulative && !final { cumulativeStream = true }
        var body = text
        var stripped = false
        if cumulativeStream && whole {
            latestSnapshot = text
            if !committedSnapshot.isEmpty, let rest = remainderAfter(prefix: committedSnapshot, in: text) {
                body = rest
                stripped = true
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        lastUserUpdate = at

        // The open line, or (for the same item, not new speech) the item's unsaved closed line.
        var target = index(of: userOpenKey)
        if target == nil, !stripped, let item, let line = index(of: itemKeys[item]), line >= saved { target = line }
        if target == nil, !whole, let line = index(of: appendKey), line >= saved { target = line }

        if let line = target {
            if whole {
                if !body.isEmpty { lines[line].body = body }
            } else {
                lines[line].body += text
            }
            if let item { itemKeys[item] = lines[line].key }
            if final && lines[line].key == userOpenKey { closeUser() }
            return
        }
        guard !body.isEmpty else { return }
        // A delta keeps its spacing ("check " + "the build"); lines are trimmed when they close.
        let firstText = whole ? body : text
        let trailing = lines.indices.last.flatMap { lines[$0].role == "assistant" && $0 >= saved && $0 > 0 ? $0 : nil }
        let key: String
        if final, let reply = index(of: assistantOpenKey) ?? trailing {
            key = nextKey()
            lines.insert(LiveTranscriptLine(key: key, role: "user", author: userAuthor, body: firstText,
                                            createdAtMs: min(at, lines[reply].createdAtMs - 1)), at: reply)
        } else {
            key = lines[append(role: "user", author: userAuthor, body: firstText, at: at)].key
        }
        userOpenKey = key
        userItem = item
        appendKey = key
        if let item { itemKeys[item] = key }
        if final { closeUser() }
    }

    /// A piece of the spoken reply; one line per response. The reply starting ends the utterance.
    mutating func assistant(_ delta: String, at: Int64) {
        if let line = index(of: assistantOpenKey) {
            lines[line].body += delta
        } else {
            guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            closeUser()
            assistantOpenKey = lines[append(role: "assistant", author: assistantAuthor, body: delta, at: at)].key
        }
    }

    /// The response finished or was cut off. `newTurn` (Gemini's turnComplete) also ends the
    /// utterance; OpenAI-style sessions end it when the user starts speaking again.
    mutating func endResponse(newTurn: Bool = false) {
        closeAssistant()
        if newTurn { closeUser(); appendKey = nil }
    }

    /// The user started a new utterance (barge-in included).
    mutating func speechStarted() {
        closeAssistant()
        closeUser()
        appendKey = nil
    }

    /// A tool hand-off ("→ Asked Moss: …").
    mutating func system(_ text: String, at: Int64) {
        closeUser()
        closeAssistant()
        appendKey = nil
        append(role: "system", author: Self.systemAuthor, body: text, at: at)
    }

    /// Closes a user line that has had no updates for `userIdleMs`.
    mutating func tick(now: Int64) {
        if userOpenKey != nil && now - lastUserUpdate >= Self.userIdleMs { closeUser() }
    }

    private mutating func closeUser() {
        defer { userOpenKey = nil; userItem = nil }
        guard let line = index(of: userOpenKey) else { return }
        lines[line].body = lines[line].body.trimmingCharacters(in: .whitespacesAndNewlines)
        if cumulativeStream && !latestSnapshot.isEmpty { committedSnapshot = latestSnapshot }
        dropRepeat(at: line)
    }

    /// A closed user line that repeats the previous one is dropped; a previous unsaved line that
    /// this one merely extends is replaced by it.
    private mutating func dropRepeat(at line: Int) {
        guard let previous = lines[..<line].lastIndex(where: { $0.role == "user" }) else { return }
        let current = normalizedSpeech(lines[line].body), before = normalizedSpeech(lines[previous].body)
        guard !current.isEmpty, !before.isEmpty else { return }
        if current == before, line >= saved {
            remove(at: line)
        } else if (current + " ").hasPrefix(before + " "), previous >= saved {
            remove(at: previous)
        }
    }

    private mutating func remove(at line: Int) {
        let key = lines[line].key
        lines.remove(at: line)
        if appendKey == key { appendKey = nil }
        itemKeys = itemKeys.filter { $0.value != key }
    }

    private mutating func closeAssistant() {
        if let line = index(of: assistantOpenKey) { lines[line].body = lines[line].body.trimmingCharacters(in: .whitespacesAndNewlines) }
        assistantOpenKey = nil
    }

    /// Closes everything still streaming (the session is ending).
    mutating func finish() {
        closeUser()
        closeAssistant()
    }

    /// The utterance being transcribed (or the last one), for captions.
    var currentUserText: String? {
        if let line = index(of: userOpenKey) { return lines[line].body }
        return lines.last { $0.role == "user" }?.body
    }

    /// Finished lines not yet saved, oldest first; open lines (and anything after them) wait.
    var unsaved: [LiveTranscriptLine] {
        guard !isEmpty else { return [] }
        let open = [index(of: assistantOpenKey), index(of: userOpenKey)].compactMap { $0 }.min() ?? lines.count
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

// MARK: - Speech text matching

/// Lowercased words: letters and digits kept, apostrophes dropped ("Let's" → "lets"), other
/// punctuation and whitespace become single spaces. `ends[i]` is where `chars[i]` ends in `text`.
private func speechWords(_ text: String) -> (chars: [Character], ends: [String.Index]) {
    var chars: [Character] = []
    var ends: [String.Index] = []
    var gap = false
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if character.isLetter || character.isNumber {
            if gap && !chars.isEmpty { chars.append(" "); ends.append(index) }
            gap = false
            for lower in String(character).lowercased() { chars.append(lower); ends.append(next) }
        } else if character != "'" && character != "’" {
            gap = true
        }
        index = next
    }
    return (chars, ends)
}

/// "Thanks. Okay." and "thanks okay" compare equal.
func normalizedSpeech(_ text: String) -> String { String(speechWords(text).chars) }

/// The part of `text` after a leading `prefix` (compared normalized, on a word boundary), with
/// leading punctuation and spaces trimmed; nil when `text` doesn't start with `prefix`.
func remainderAfter(prefix: String, in text: String) -> String? {
    let head = speechWords(prefix).chars
    let words = speechWords(text)
    guard !head.isEmpty, words.chars.count >= head.count, Array(words.chars[0..<head.count]) == head else { return nil }
    if words.chars.count > head.count, words.chars[head.count] != " " { return nil }
    let rest = text[words.ends[head.count - 1]...]
    return String(rest.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespacesAndNewlines)
}

import Foundation

/*
 * The text record of a live voice conversation, saved into the companion's chat
 * (`companion_transcript_save`) so the conversation survives as ordinary history. Pure and unit
 * tested: lines accumulate from streaming events, finished lines are saved in order, and keys
 * ("<session>:<n>") make every save idempotent. Audio is never kept. Everything the user says
 * between companion replies or system lines is one user line (one turn), merged by `mergedSpeech`.
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
    private var userPiece = 0
    private var userItem: String?
    private var assistantOpenKey: String?
    /// The last user line plain deltas may still extend (Gemini sends input pieces late).
    private var appendKey: String?
    private var appendPiece = 0
    private var lastUserUpdate: Int64 = 0
    /// The user line collecting the current turn; it is not saved until the turn ends.
    private var turnKey: String?
    /// Each user line's utterances (raw text, oldest first); its body is `mergedSpeech` of them.
    private var pieces: [String: [String]] = [:]
    /// Transcription item id → its line and utterance, so updates for an item replace that text.
    private var itemRefs: [String: PieceRef] = [:]
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

    /// One utterance within a user line.
    private struct PieceRef: Equatable {
        var key: String
        var piece: Int
    }

    private func pieceText(_ ref: PieceRef) -> String {
        guard let list = pieces[ref.key], ref.piece < list.count else { return "" }
        return list[ref.piece]
    }

    /// Replaces one utterance of a user line and rebuilds the line from its utterances.
    private mutating func setPiece(_ ref: PieceRef, _ text: String, line: Int) {
        var list = pieces[ref.key] ?? [lines[line].body]
        while list.count <= ref.piece { list.append("") }
        list[ref.piece] = text
        pieces[ref.key] = list
        lines[line].body = mergedSpeech(list)
    }

    /// What the user said, per transcription `item`. `cumulative` and `final` updates carry the
    /// whole transcript so far (replace); others are deltas (append). On a cumulative stream the
    /// text already committed to earlier lines is stripped, so each utterance is saved once.
    /// A late final transcript goes before the unsaved reply it triggered. A new utterance joins
    /// the same turn's unsaved user line instead of starting another one.
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

        // The open utterance, or (for the same item, not new speech) the item's unsaved closed line.
        var target: PieceRef?
        if let key = userOpenKey, index(of: key) != nil { target = PieceRef(key: key, piece: userPiece) }
        if target == nil, !stripped, let item, let ref = itemRefs[item], let line = index(of: ref.key), line >= saved { target = ref }
        if target == nil, !whole, let key = appendKey, let line = index(of: key), line >= saved { target = PieceRef(key: key, piece: appendPiece) }

        if let ref = target, let line = index(of: ref.key) {
            if whole {
                if !body.isEmpty { setPiece(ref, body, line: line) }
            } else {
                setPiece(ref, pieceText(ref) + text, line: line)
            }
            if let item { itemRefs[item] = ref }
            if final && ref.key == userOpenKey { closeUser() }
            return
        }
        guard !body.isEmpty else { return }
        // A delta keeps its spacing ("check " + "the build"); lines are trimmed when they close.
        let firstText = whole ? body : text
        let trailing = lines.indices.last.flatMap { lines[$0].role == "assistant" && $0 >= saved && $0 > 0 ? $0 : nil }
        let reply: Int? = final ? (index(of: assistantOpenKey) ?? trailing) : nil
        // The turn's unsaved user line: just before the reply a late transcript belongs to, or the open turn.
        var turnLine: Int?
        if let reply {
            if reply > saved, lines[reply - 1].role == "user" { turnLine = reply - 1 }
        } else if let line = index(of: turnKey), line == lines.count - 1, line >= saved {
            turnLine = line
        }
        let ref: PieceRef
        if let line = turnLine {
            let key = lines[line].key
            var list = pieces[key] ?? [lines[line].body]
            ref = PieceRef(key: key, piece: list.count)
            list.append(firstText)
            pieces[key] = list
            lines[line].body = mergedSpeech(list)
        } else if let reply {
            let key = nextKey()
            lines.insert(LiveTranscriptLine(key: key, role: "user", author: userAuthor, body: firstText,
                                            createdAtMs: min(at, lines[reply].createdAtMs - 1)), at: reply)
            pieces[key] = [firstText]
            ref = PieceRef(key: key, piece: 0)
        } else {
            let key = lines[append(role: "user", author: userAuthor, body: firstText, at: at)].key
            pieces[key] = [firstText]
            ref = PieceRef(key: key, piece: 0)
        }
        if reply == nil { turnKey = ref.key }
        userOpenKey = ref.key
        userPiece = ref.piece
        userItem = item
        appendKey = ref.key
        appendPiece = ref.piece
        if let item { itemRefs[item] = ref }
        if final { closeUser() }
    }

    /// A piece of the spoken reply; one line per response. The reply starting ends the utterance.
    mutating func assistant(_ delta: String, at: Int64) {
        if let line = index(of: assistantOpenKey) {
            lines[line].body += delta
        } else {
            guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            closeUser()
            turnKey = nil
            assistantOpenKey = lines[append(role: "assistant", author: assistantAuthor, body: delta, at: at)].key
        }
    }

    /// The response finished or was cut off. `newTurn` (Gemini's turnComplete) also ends the
    /// utterance; OpenAI-style sessions end it when the user starts speaking again.
    mutating func endResponse(newTurn: Bool = false) {
        closeAssistant()
        if newTurn { closeUser(); appendKey = nil; turnKey = nil }
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
        turnKey = nil
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
        if turnKey == key { turnKey = nil }
        pieces[key] = nil
        itemRefs = itemRefs.filter { $0.value.key != key }
    }

    private mutating func closeAssistant() {
        if let line = index(of: assistantOpenKey) { lines[line].body = lines[line].body.trimmingCharacters(in: .whitespacesAndNewlines) }
        assistantOpenKey = nil
    }

    /// Closes everything still streaming (the session is ending).
    mutating func finish() {
        closeUser()
        closeAssistant()
        turnKey = nil
    }

    /// The utterance being transcribed (or the last one), for captions.
    var currentUserText: String? {
        if let line = index(of: userOpenKey) { return lines[line].body }
        return lines.last { $0.role == "user" }?.body
    }

    /// Finished lines not yet saved, oldest first; open lines, the user turn still being spoken,
    /// and anything after them wait.
    var unsaved: [LiveTranscriptLine] {
        guard !isEmpty else { return [] }
        let open = [index(of: assistantOpenKey), index(of: userOpenKey), index(of: turnKey)].compactMap { $0 }.min() ?? lines.count
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

/// A spoken line's speaker ("You (voice)", "Moss (voice)"), not a "Live" marker.
func isVoiceSpeaker(_ author: String) -> Bool { author.hasSuffix("(voice)") }

/// "Moss (voice)" → "Moss".
func voiceSpeakerName(_ author: String) -> String {
    var name = author
    if name.hasSuffix("(voice)") { name = String(name.dropLast("(voice)".count)) }
    return name.trimmingCharacters(in: .whitespaces)
}

/// One user turn's text from its utterances, oldest first. A piece whose words contain all the
/// earlier pieces' words, or start with the first earlier pieces holding most of their words (the
/// rest were drafts it re-transcribes), is a cumulative snapshot that replaces them. The pieces
/// left are joined with single spaces. Pieces without words are dropped.
func mergedSpeech(_ pieces: [String]) -> String {
    var kept: [String] = []
    var keptWords: [String] = []
    for piece in pieces {
        let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalizedSpeech(text)
        guard !words.isEmpty else { continue }
        if !keptWords.isEmpty && speechSupersedes(words, keptWords) {
            kept = []
            keptWords = []
        }
        kept.append(text)
        keptWords.append(words)
    }
    return kept.joined(separator: " ")
}

/// `words` (normalized) restates the normalized `earlier` pieces.
private func speechSupersedes(_ words: String, _ earlier: [String]) -> Bool {
    let all = earlier.joined(separator: " ")
    if (" " + words + " ").contains(" " + all + " ") { return true }
    let total = all.split(separator: " ").count
    var prefix = ""
    var covered = 0
    for piece in earlier {
        prefix = prefix.isEmpty ? piece : prefix + " " + piece
        guard (words + " ").hasPrefix(prefix + " ") else { break }
        covered += piece.split(separator: " ").count
    }
    return covered * 2 > total
}

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

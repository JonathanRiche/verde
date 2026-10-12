import Foundation
import CoreGraphics

/*
 * Pure rules for Companion voice: when replies are read aloud, how markdown becomes speakable
 * sentences while a reply streams, and how a press on the bubble or mic is classified. Unit tested;
 * `CompanionVoice` owns the audio effects. Transcripts and replies are never logged.
 */

// MARK: - Settings

enum CompanionVoiceStore {
    static let readAloudKey = "companion.voice.readAloud"
    static let rateKey = "companion.voice.rate"
    static let voiceKey = "companion.voice.identifier"
    static let serverRecognitionKey = "companion.voice.serverRecognition"
}

enum ReadAloud: String, CaseIterable, Identifiable {
    case always, afterVoice, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "Always"
        case .afterVoice: return "Only after I speak"
        case .never: return "Never"
        }
    }
}

/// The stored choice, or the default when unset: "Only after I speak", or "Never" while
/// VoiceOver is running (VoiceOver already reads the reply).
func effectiveReadAloud(stored: String, voiceOverRunning: Bool) -> ReadAloud {
    ReadAloud(rawValue: stored) ?? (voiceOverRunning ? .never : .afterVoice)
}

func shouldReadAloud(_ policy: ReadAloud, voiceTurn: Bool) -> Bool {
    switch policy {
    case .always: return true
    case .afterVoice: return voiceTurn
    case .never: return false
    }
}

// MARK: - Markdown to speech

private func replacing(_ text: String, _ pattern: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
}

/// Speakable lines from a (possibly still streaming) markdown reply: code blocks are skipped (an
/// unterminated fence drops the rest), links keep their text, bare URLs become "a link", and
/// markup is removed. One entry per non-empty source line.
func speechLines(_ markdown: String) -> [String] {
    var lines: [String] = []
    var fenced = false
    for raw in markdown.components(separatedBy: .newlines) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
        if fenced { continue }
        var line = trimmed
        line = replacing(line, #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")                  // images: alt text
        line = replacing(line, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")                    // links: their text
        line = replacing(line, #"<?\b(?:https?://|www\.)[^\s>)]*[^\s>).,!?;:'"]>?"#, with: "a link")   // bare URLs
        line = replacing(line, #"^#{1,6}\s+"#, with: "")                                 // headings
        line = replacing(line, #"^>\s?"#, with: "")                                      // quotes
        line = replacing(line, #"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "")     // list markers, task boxes
        line = replacing(line, #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$"#, with: "") // table rules
        line = line.replacingOccurrences(of: "|", with: ", ")
        line = line.replacingOccurrences(of: "`", with: "")
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "~~", with: "")
        line = replacing(line, #"(?<![\w*])\*(?!\s)|(?<!\s)\*(?![\w*])"#, with: "")      // *emphasis*
        line = replacing(line, #"(?<!\w)_+(?=\w)|(?<=\w)_+(?!\w)"#, with: "")            // _emphasis_, not snake_case
        line = replacing(line, #"\s+"#, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if line.isEmpty || line == "a link" && lines.last == "a link" { continue }
        lines.append(line)
    }
    return lines
}

private let terminators: Set<Character> = [".", "!", "?", "…"]

/// Whole sentences of a reply. While streaming (`final == false`) the last line and any sentence
/// not yet followed by more text are held back; a finished line without end punctuation ends its
/// sentence (lists, headings).
func speechSentences(_ markdown: String, final: Bool) -> [String] {
    var lines = speechLines(markdown)
    var tail = ""
    if !final, let last = lines.popLast() { tail = last }
    // A finished line ends its sentence; the very last line of a finished reply needs no period.
    var text = lines.enumerated().map { index, line in
        terminators.contains(line.last ?? " ") || (final && index == lines.count - 1) ? line : line + "."
    }.joined(separator: " ")
    if !tail.isEmpty { text += (text.isEmpty ? "" : " ") + tail }
    var sentences: [String] = []
    var current = ""
    let characters = Array(text)
    for (index, character) in characters.enumerated() {
        current.append(character)
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        if terminators.contains(character), next.map({ $0 == " " }) ?? false {
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            current = ""
        }
    }
    let rest = current.trimmingCharacters(in: .whitespaces)
    if final, !rest.isEmpty { sentences.append(rest) }
    return sentences
}

/// Feeds a growing reply and returns only sentences not spoken yet.
struct SentenceChunker {
    private(set) var spoken = 0

    mutating func next(_ markdown: String, final: Bool) -> [String] {
        let sentences = speechSentences(markdown, final: final)
        guard sentences.count > spoken else { return [] }
        let fresh = Array(sentences[spoken...])
        spoken = sentences.count
        return fresh
    }
}

// MARK: - Gestures

/// What a press on the bubble turns into: a still hold of `holdDelay` talks, movement past `slop`
/// before that repositions, and a quick release is a tap.
enum PressIntent: Equatable { case undecided, talk, reposition }

enum PressRules {
    static let holdDelay: TimeInterval = 0.3
    static let slop: CGFloat = 10
    /// Dragging this far from where a talk began cancels it on release.
    static let cancelDistance: CGFloat = 80
}

func classifyPress(_ current: PressIntent, elapsed: TimeInterval, distance: CGFloat) -> PressIntent {
    guard current == .undecided else { return current }
    if distance > PressRules.slop { return .reposition }
    if elapsed >= PressRules.holdDelay { return .talk }
    return .undecided
}

func talkCancelled(distance: CGFloat) -> Bool { distance > PressRules.cancelDistance }

/// The sheet mic: a press that started listening sends when held, keeps listening after a quick
/// tap; a press while already listening sends.
enum MicRelease: Equatable { case keepListening, send }

func micRelease(startedByPress: Bool, elapsed: TimeInterval) -> MicRelease {
    startedByPress && elapsed < PressRules.holdDelay ? .keepListening : .send
}

/// Input level (RMS amplitude) mapped to 0...1 over a -50...0 dB window for the meter.
func normalizedLevel(rms: Float) -> Double {
    guard rms > 0, rms.isFinite else { return 0 }
    return min(1, max(0, (Double(20 * log10(rms)) + 50) / 50))
}

import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/*
 * Companion voice, phase 1: on-device speech-to-text (Speech framework, server recognition only
 * when the user allows it) and spoken replies (AVSpeechSynthesizer). Audio callbacks run off the
 * main actor and hop back; transcripts, replies and audio are never logged or stored.
 */
@MainActor @Observable
final class CompanionVoice {
    enum Phase: Equatable { case idle, starting, listening, finishing }

    static let finalWait: Duration = .milliseconds(1500)

    private(set) var phase: Phase = .idle
    private(set) var partial = ""
    /// Input level 0...1 for the meter.
    private(set) var level: Double = 0
    private(set) var speaking = false
    /// A permission or availability problem to show the user; cleared on the next start.
    var notice: String?
    /// A transcript from the bubble, sent by the sheet's composer once it opens.
    var pendingPrompt: String?
    /// Live voice owns audio: no reading aloud meanwhile.
    @ObservationIgnored var suspended = false

    var listening: Bool { phase == .starting || phase == .listening }

    private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finalText: String?
    @ObservationIgnored private var gotFinal = false
    @ObservationIgnored private var session = 0
    private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var synthDelegate: SynthDelegate?
    @ObservationIgnored private var audioActive = false
    // Reply reading.
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var baseline: String?
    @ObservationIgnored private var voiceArmed = false
    @ObservationIgnored private var readingID: String?
    @ObservationIgnored private var chunker = SentenceChunker()
    @ObservationIgnored private var muted: Set<String> = []

    init() {
        let delegate = SynthDelegate { [weak self] in
            Task { @MainActor in self?.speechQueueChanged() }
        }
        synthDelegate = delegate
        synthesizer.delegate = delegate
    }

    // MARK: Listening

    /// Starts listening; false (with `notice`) when permission or recognition is unavailable.
    @discardableResult
    func start() async -> Bool {
        guard phase == .idle else { return phase == .listening || phase == .starting }
        guard !suspended else { notice = "End the live conversation to use the mic."; return false }
        stopSpeaking() // Barge-in.
        notice = nil
        partial = ""
        level = 0
        phase = .starting
        session += 1
        let current = session
        guard await authorized() else { phase = .idle; return false }
        guard current == session, phase == .starting else { return false }
        let allowServer = UserDefaults.standard.bool(forKey: CompanionVoiceStore.serverRecognitionKey)
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            return fail("Speech recognition isn't available right now.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if !allowServer {
            return fail("On-device recognition isn't available for this language. You can allow server recognition in Companion settings.")
        }
        do {
            try activateAudio()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return fail("No microphone is available.") }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request: request) { [weak self] value in
                Task { @MainActor in if let self, self.session == current, self.listening { self.level = value } }
            })
            engine.prepare()
            try engine.start()
        } catch {
            return fail("Couldn't start the microphone.")
        }
        self.request = request
        finalText = nil
        gotFinal = false
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, final, failed in
            Task { @MainActor in self?.received(text, final: final, failed: failed, session: current) }
        })
        phase = .listening
        return true
    }

    /// Stops listening and returns the transcript (nil when nothing was heard).
    func finish() async -> String? {
        guard listening else { return nil }
        let current = session
        phase = .finishing
        stopAudio()
        request?.endAudio()
        let deadline = ContinuousClock.now.advanced(by: Self.finalWait)
        while !gotFinal, session == current, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let text = (finalText ?? partial).trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        if text.isEmpty { notice = "I didn't catch that." }
        return text.isEmpty ? nil : text
    }

    func cancel() {
        guard phase != .idle else { return }
        stopAudio()
        reset()
    }

    private func received(_ text: String?, final: Bool, failed: Bool, session current: Int) {
        guard current == session else { return }
        if let text { partial = text; if final { finalText = text } }
        if final || failed { gotFinal = true }
    }

    private func fail(_ message: String) -> Bool {
        stopAudio()
        reset()
        notice = message
        return false
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func reset() {
        task?.cancel()
        task = nil
        request = nil
        session += 1
        phase = .idle
        level = 0
        partial = ""
        deactivateIfIdle()
    }

    private func authorized() async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard speech == .authorized else {
            notice = speech == .restricted ? "Speech recognition is restricted on this device."
                : "Allow Speech Recognition for verde in Settings to talk to your companion."
            return false
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined:
            if await AVAudioApplication.requestRecordPermission() { return true }
        default: break
        }
        notice = "Allow Microphone access for verde in Settings to talk to your companion."
        return false
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func tap(request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            level(normalizedLevel(rms: (sum / Float(buffer.frameLength)).squareRoot()))
        }
    }

    private nonisolated static func results(_ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    // MARK: Audio session

    /// Recording uses play-and-record (replies follow on the speaker); reading a typed turn's reply
    /// only needs playback, so the microphone stays off.
    private func activateAudio(recording: Bool = true) throws {
        let audio = AVAudioSession.sharedInstance()
        if recording {
            try audio.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        } else if audio.category != .playAndRecord {
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try audio.setActive(true)
        audioActive = true
    }

    private func deactivateIfIdle() {
        guard audioActive, phase == .idle, !synthesizer.isSpeaking else { return }
        audioActive = false
        // Live voice is taking the session over and deactivates it off the main thread when it ends.
        guard !suspended else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Speaking

    func speak(_ sentence: String) {
        guard !sentence.isEmpty, !listening, !suspended else { return }
        if !audioActive { try? activateAudio(recording: false) }
        let utterance = AVSpeechUtterance(string: sentence)
        let stored = UserDefaults.standard.object(forKey: CompanionVoiceStore.rateKey) as? Double ?? 1
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(stored)))
        let identifier = UserDefaults.standard.string(forKey: CompanionVoiceStore.voiceKey) ?? ""
        utterance.voice = identifier.isEmpty ? companionVoices().first : AVSpeechSynthesisVoice(identifier: identifier)
        synthesizer.speak(utterance)
        speaking = true
    }

    /// Barge-in: stops at once and never resumes the reply being read.
    func stopSpeaking() {
        if let readingID { muted.insert(readingID) }
        readingID = nil
        voiceArmed = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
        deactivateIfIdle()
    }

    private func speechQueueChanged() {
        speaking = synthesizer.isSpeaking
        if !speaking { deactivateIfIdle() }
    }

    // MARK: Reading replies

    /// A voice turn was just sent: its reply qualifies for "Only after I speak".
    func noteVoiceSend() { voiceArmed = true }

    /// Leaving the companion: stop and forget, so returning never replays an old reply.
    func leave() {
        stopSpeaking()
        primed = false
        baseline = nil
        muted = []
    }

    /// Speaks new assistant text in the companion chat, sentence by sentence as it streams.
    /// The first look only records where the conversation is, so history is never read.
    func observe(rows: [ChatRow], turnActive: Bool, policy: ReadAloud) {
        guard !suspended else { primed = false; return }
        let last = rows.last { $0.role == "assistant" && $0.kind == "message" }
        guard primed else { primed = true; baseline = last?.id; return }
        guard let last, last.id != baseline, !muted.contains(last.id) else { return }
        guard shouldReadAloud(policy, voiceTurn: voiceArmed) else {
            if !turnActive { baseline = last.id; voiceArmed = false }
            return
        }
        if readingID != last.id {
            // A turn can stream several messages: finish the previous one first.
            if let previous = readingID, let row = rows.first(where: { $0.id == previous }) {
                chunker.next(row.body, final: true).forEach(speak)
            }
            readingID = last.id
            chunker = SentenceChunker()
        }
        chunker.next(last.body, final: !turnActive).forEach(speak)
        if !turnActive {
            baseline = last.id
            readingID = nil
            voiceArmed = false
        }
    }
}

/// Voices for the current language, best quality first.
func companionVoices(language: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> [AVSpeechSynthesisVoice] {
    let prefix = String(language.prefix(2))
    return AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == language || $0.language.hasPrefix(prefix) }
        .sorted {
            let a = voiceRank($0.quality) + ($0.language == language ? 1 : 0)
            let b = voiceRank($1.quality) + ($1.language == language ? 1 : 0)
            return a != b ? a > b : $0.name < $1.name
        }
}

func voiceRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
    switch quality {
    case .premium: return 20
    case .enhanced: return 10
    default: return 0
    }
}

private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let changed: @Sendable () -> Void
    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { changed() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { changed() }
}

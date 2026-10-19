import AVFoundation
import Foundation
import Observation
import UIKit

/// Hands microphone chunks from the audio thread to the socket once the session accepts audio.
final class LiveUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var proto: RealtimeProtocol?
    private var ready = false

    func attach(_ socket: URLSessionWebSocketTask, _ proto: RealtimeProtocol, ready: Bool) {
        lock.lock(); self.socket = socket; self.proto = proto; self.ready = ready; lock.unlock()
    }
    func markReady() { lock.lock(); ready = true; lock.unlock() }
    func detach() { lock.lock(); socket = nil; proto = nil; ready = false; lock.unlock() }

    func send(audio: Data) {
        lock.lock()
        let socket = ready ? self.socket : nil
        let message = socket == nil ? nil : proto?.audio(audio)
        lock.unlock()
        guard let socket, let message else { return }
        socket.send(.string(message)) { _ in }
    }
}

/*
 * Real-time voice conversation with the Companion (xAI Grok Voice, OpenAI Realtime, Gemini Live).
 * The desktop mints a short-lived provider token (`voice_session_create`); the phone talks to the
 * provider directly over a WebSocket and runs the session's tools against the existing models.
 * Tokens, keys, audio and transcripts are never logged or stored.
 */
@MainActor @Observable
final class LiveVoice {
    enum Phase: Equatable { case idle, connecting, live, failed(String) }

    static let silenceLimit: TimeInterval = 120
    static let captionLimit = 400
    static let maxReconnects = 3

    private(set) var phase: Phase = .idle
    private(set) var userCaption = ""
    private(set) var assistantCaption = ""
    private(set) var inputLevel: Double = 0
    private(set) var outputLevel: Double = 0
    /// "Grok · Ara" etc.
    private(set) var label = ""
    /// A non-fatal provider message.
    private(set) var notice: String?
    private(set) var muted = false

    func setMuted(_ value: Bool) {
        muted = value
        audio?.muted = value
        if value { inputLevel = 0 }
    }

    var active: Bool { phase == .connecting || phase == .live }
    var failure: String? { if case .failed(let message) = phase { return message }; return nil }

    @ObservationIgnored let companion: CompanionModel
    @ObservationIgnored let speech: CompanionVoice
    @ObservationIgnored private let uplink = LiveUplink()
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var proto: RealtimeProtocol?
    @ObservationIgnored private var audio: LiveAudio?
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    @ObservationIgnored private var transcript: TranscriptModel?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reconnects = 0
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The conversation as text, saved into the companion chat (never audio).
    @ObservationIgnored private var record: LiveTranscript?
    @ObservationIgnored private var lastSaved = Date()
    @ObservationIgnored private var saving = false
    static let saveInterval: TimeInterval = 120

    init(companion: CompanionModel, speech: CompanionVoice) {
        self.companion = companion
        self.speech = speech
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
            Task { @MainActor in if began { self?.end() } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end() }
        })
    }

    // MARK: Lifecycle

    func toggle() { if active { end() } else { Task { await start() } } }

    func start() async {
        guard !active else { return }
        speech.cancel()
        speech.stopSpeaking()
        speech.suspended = true
        phase = .connecting
        userCaption = ""; assistantCaption = ""; notice = nil; setMuted(false)
        reconnects = 0
        record = nil
        lastSaved = Date()
        generation += 1
        let current = generation
        guard await AVAudioApplication.requestRecordPermission() else {
            return fail("Allow Microphone access for verde in Settings to talk live.")
        }
        do {
            let session = try await LiveVoiceClient(browse: companion.browse).createSession(companionID: companion.active?.id)
            guard current == generation else { return }
            try connect(session, generation: current)
        } catch LiveVoiceError.failed(let code) {
            if current == generation { fail(code == "audio" ? "Couldn't start the microphone." : liveVoiceMessage(code)) }
        } catch {
            if current == generation { fail(liveVoiceMessage(nil)) }
        }
    }

    /// Ends the conversation (Stop, background, interruption or two minutes of silence).
    func end() {
        flushTranscript(final: true)
        teardown()
        phase = .idle
    }

    private func fail(_ message: String) {
        flushTranscript(final: true)
        teardown()
        phase = .failed(message)
    }

    // MARK: Transcript

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func note(_ text: String) { record?.system(text, at: now) }

    /// Saves finished, unsaved lines into the companion chat. During the session this waits while a
    /// companion turn is streaming there; at the end everything goes. Saves are idempotent by key.
    private func flushTranscript(final: Bool) {
        guard var current = record else { return }
        if final {
            current.finish()
            record = current
        } else if companion.conversationBusy || saving {
            return
        }
        let lines = current.unsaved
        guard !lines.isEmpty else { return }
        lastSaved = Date()
        saving = true
        let sessionID = current.sessionID
        let companion = self.companion
        Task { [weak self] in
            if let conversation = await companion.ensureConversation() {
                let client = LiveVoiceClient(browse: companion.browse)
                for batch in transcriptBatches(lines) {
                    guard await client.saveTranscript(workspaceID: conversation.workspace, threadID: conversation.thread,
                                                      sessionID: sessionID, lines: batch) else { break }
                    if let key = batch.last?.key, self?.record?.sessionID == sessionID { self?.record?.markSaved(through: key) }
                }
            }
            self?.saving = false
        }
    }

    private func teardown() {
        generation += 1
        receiver?.cancel(); receiver = nil
        watchdog?.cancel(); watchdog = nil
        watchers.forEach { $0.cancel() }; watchers = []
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        uplink.detach()
        audio?.stop(); audio = nil
        proto = nil
        transcript?.setVisible(false); transcript = nil
        speech.suspended = false
        inputLevel = 0; outputLevel = 0
    }

    private func connect(_ session: LiveVoiceSession, generation current: Int) throws {
        guard let url = URL(string: session.websocket_url) else { throw LiveVoiceError.failed("voice_provider_unavailable") }
        let proto = RealtimeProtocol(protocolName: session.protocolName, provider: session.provider)
        var request = URLRequest(url: url)
        if session.auth == "bearer" { request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization") }
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
        self.socket = socket
        self.proto = proto
        let providerLabel = LiveVoiceClient(browse: companion.browse).view?.providers.first { $0.id == session.provider }?.label
            ?? session.provider.capitalized
        label = [providerLabel, session.voice].filter { !$0.isEmpty }.joined(separator: " · ")
        if record == nil {
            record = LiveTranscript(sessionID: UUID().uuidString, companionName: companion.active?.name ?? "Companion",
                                    providerLabel: providerLabel)
        }
        uplink.attach(socket, proto, ready: !proto.waitsForSetup)
        send(proto.setup(instructions: session.instructions, model: session.model, voice: session.voice, tools: session.tools))
        if audio == nil {
            let audio = LiveAudio()
            let uplink = self.uplink
            audio.onChunk = { chunk in uplink.send(audio: chunk) }
            audio.onLevel = { [weak self] level in Task { @MainActor in self?.heard(level) } }
            audio.muted = muted
            try audio.start(inputRate: proto.inputRate)
            self.audio = audio
        }
        receiver = Task { [weak self] in await self?.receive(socket, generation: current) }
        if !proto.waitsForSetup { phase = .live }
        lastActivity = Date()
        startWatchdog(current)
    }

    private func reconnect(_ current: Int) async {
        guard current == generation, reconnects < Self.maxReconnects else { return fail("The live connection ended.") }
        reconnects += 1
        generation += 1
        let next = generation
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        uplink.detach()
        do {
            let session = try await LiveVoiceClient(browse: companion.browse).createSession(companionID: companion.active?.id)
            guard next == generation else { return }
            try connect(session, generation: next)
        } catch LiveVoiceError.failed(let code) {
            if next == generation { fail(liveVoiceMessage(code)) }
        } catch {
            if next == generation { fail(liveVoiceMessage(nil)) }
        }
    }

    private func startWatchdog(_ current: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, current == self.generation else { return }
                if Date().timeIntervalSince(self.lastActivity) > Self.silenceLimit { self.end(); return }
                self.record?.tick(now: self.now)
                if Date().timeIntervalSince(self.lastSaved) > Self.saveInterval { self.flushTranscript(final: false) }
            }
        }
    }

    // MARK: Socket

    private func send(_ message: String) {
        socket?.send(.string(message)) { _ in }
    }

    private func receive(_ socket: URLSessionWebSocketTask, generation current: Int) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch {
                guard current == generation, active else { return }
                if proto?.kind == .geminiLive { await reconnect(current) } else { fail("The live connection ended.") }
                return
            }
            guard current == generation, let proto else { return }
            let text: String
            switch message {
            case .string(let value): text = value
            case .data(let value): text = String(decoding: value, as: UTF8.self)
            @unknown default: continue
            }
            for event in proto.parse(text) { handle(event, generation: current) }
        }
    }

    private func handle(_ event: RealtimeEvent, generation current: Int) {
        record?.tick(now: now)
        switch event {
        case .ready:
            uplink.markReady()
            if phase == .connecting {
                phase = .live
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        case .audio(let data):
            outputLevel = audio?.play(data) ?? 0
            lastActivity = Date()
        case .assistantText(let delta):
            assistantCaption = String((assistantCaption + delta).suffix(Self.captionLimit))
            record?.assistant(delta, at: now)
            lastActivity = Date()
        case .userText(let text, let item):
            record?.user(text, final: true, cumulative: true, item: item, at: now)
            userCaption = String((record?.currentUserText ?? "").suffix(Self.captionLimit))
            lastActivity = Date()
        case .userTextPartial(let text, let cumulative, let item):
            record?.user(text, final: false, cumulative: cumulative, item: item, at: now)
            userCaption = String((record?.currentUserText ?? "").suffix(Self.captionLimit))
            lastActivity = Date()
        case .speechStarted, .interrupted:
            audio?.flush()
            outputLevel = 0
            if event == .speechStarted {
                assistantCaption = ""
                record?.speechStarted()
            } else {
                record?.endResponse()
            }
            lastActivity = Date()
        case .toolCall(let id, let name, let arguments):
            let task = Task { [weak self] in
                guard let self else { return }
                let output = await self.runTool(name, arguments, generation: current)
                guard current == self.generation, let proto = self.proto else { return }
                proto.toolResult(id: id, name: name, output: output).forEach(self.send)
            }
            watchers.append(task)
        case .turnComplete:
            outputLevel = 0
            record?.endResponse(newTurn: proto?.kind == .geminiLive)
        case .goAway:
            Task { [weak self] in await self?.reconnect(current) }
        case .error(let message):
            notice = message
        }
    }

    private func heard(_ level: Double) {
        guard active else { return }
        inputLevel = muted ? 0 : level
        if level > 0.3 && !muted { lastActivity = Date() }
    }

    // MARK: Tools

    private func runTool(_ name: String, _ raw: String, generation current: Int) async -> String {
        let args = toolArguments(raw)
        switch name {
        case LiveToolName.askCompanion:
            guard let request = stringArgument(args["request"]) else { return toolError("missing_request") }
            guard let conversation = await companion.ensureConversation(), current == generation else { return toolError("no_companion_chat") }
            let model = companionTranscript(conversation)
            let baseline = lastAssistant(model)?.id
            model.input.ask(request, voice: true)
            note("→ Asked \(companion.active?.name ?? "the companion"): \(request)")
            watchers.append(Task { [weak self] in await self?.relayReply(model, after: baseline, generation: current) })
            return jsonString(["accepted": true])
        case LiveToolName.companionStatus:
            let labels = Dictionary((companion.browse.state.workspaces?.items ?? []).map { ($0.workspace_id, $0.label) }, uniquingKeysWith: { a, _ in a })
            return companionStatusJSON(name: companion.active?.name ?? "Companion", status: companion.presence.status,
                                       needsYou: companion.needsYou, crew: companion.crew, workspaceLabels: labels)
        case LiveToolName.decideApproval:
            guard let approve = boolArgument(args["approve"]) else { return toolError("missing_approve") }
            switch matchApproval(stringArgument(args["chat"]) ?? "", companion.needsYou) {
            case .ambiguous: return toolError("ambiguous")
            case .notFound: return toolError("not_found")
            case .found(let item):
                let model = TranscriptModel(browse: companion.browse, workspaceID: item.workspaceID, threadID: item.threadID)
                model.start()
                model.setVisible(true)
                let sent = await model.decideFromNotification(.init(decision: approve ? .approve : .deny, turnID: nil), wait: .seconds(10))
                model.setVisible(false)
                if sent { note((approve ? "✓ Approved " : "✕ Denied ") + item.title) }
                return sent ? jsonString(["ok": true, "chat": item.title, "decision": approve ? "approved" : "denied"]) : toolError("not_pending")
            }
        default:
            return toolError("unknown_tool")
        }
    }

    /// The companion chat, kept focused while Live runs so its replies stream in.
    private func companionTranscript(_ conversation: (workspace: String, thread: String)) -> TranscriptModel {
        if let transcript, transcript.workspaceID == conversation.workspace, transcript.threadID == conversation.thread { return transcript }
        transcript?.setVisible(false)
        let model = TranscriptModel(browse: companion.browse, workspaceID: conversation.workspace, threadID: conversation.thread)
        model.start()
        model.setVisible(true)
        transcript = model
        return model
    }

    private func lastAssistant(_ model: TranscriptModel) -> ChatRow? {
        model.thread?.rows.last { $0.role == "assistant" && $0.kind == "message" }
    }

    /// When the companion's turn for an `ask_companion` finishes, tells the live model what it said.
    private func relayReply(_ model: TranscriptModel, after baseline: String?, generation current: Int) async {
        let start = ContinuousClock.now
        var started = false
        while !Task.isCancelled, current == generation, ContinuousClock.now - start < .seconds(15 * 60) {
            let running = model.state.turn != nil
            if running { started = true }
            let elapsed = ContinuousClock.now - start
            if !running, let reply = lastAssistant(model), reply.id != baseline, started || elapsed > .seconds(3) {
                if let proto { proto.inject(companionUpdateText(reply.body)).forEach(send) }
                note("← \(companion.active?.name ?? "Companion") replied")
                return
            }
            // The turn never started (e.g. the send was refused).
            if !started && elapsed > .seconds(30) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

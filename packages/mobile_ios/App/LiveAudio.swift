import AVFoundation
import Foundation

/// One live call's audio engine, started and stopped only on `LiveAudioSession`'s queue.
protocol LiveAudioEngine: AnyObject, Sendable {
    func start(inputRate: Double) throws
    func stop()
}

/*
 * Who holds the shared audio session. A call's request and end are recorded the moment the main
 * actor makes them; its acquire, engine start and release then run in order on the audio queue.
 * Each call has its own token, so a late teardown never stops a newer call's engine, the session
 * stays active while any call holds it or is queued to, and steps of an ended call are skipped.
 */
struct LiveAudioHolds: Equatable {
    private(set) var active = false
    private(set) var holders: Set<Int> = []
    private(set) var queued: Set<Int> = []
    private(set) var ended: Set<Int> = []

    /// A call asked for the session; its acquire is queued.
    mutating func request(_ token: Int) { queued.insert(token) }
    /// The call ended; its steps still queued are skipped.
    mutating func end(_ token: Int) { ended.insert(token) }

    /// The queued acquire runs: true activates the session for the call, false skips (it ended).
    mutating func acquire(_ token: Int) -> Bool {
        queued.remove(token)
        guard !ended.contains(token) else { return false }
        holders.insert(token)
        return true
    }

    /// Activation finished; a call whose activation failed no longer holds the session.
    mutating func activated(_ token: Int, ok: Bool) {
        if ok { active = true } else { holders.remove(token) }
    }

    /// The call's engine may start: it holds the active session and hasn't ended.
    func mayRun(_ token: Int) -> Bool { active && holders.contains(token) && !ended.contains(token) }

    /// The release runs: true deactivates the session (nobody holds it and no live call waits for it).
    mutating func release(_ token: Int) -> Bool {
        holders.remove(token)
        queued.remove(token)
        ended.remove(token)
        guard active, holders.isEmpty, queued.allSatisfy({ ended.contains($0) }) else { return false }
        active = false
        return true
    }
}

/*
 * Runs AVAudioSession activation and engine start/stop on one serial queue, off the main actor:
 * these calls block for hundreds of milliseconds. `begin`, `run` and `finish` enqueue at once, so
 * work keeps the order the main actor asked for; completions arrive on the queue.
 */
final class LiveAudioSession: @unchecked Sendable {
    struct Backend: Sendable {
        var activate: @Sendable () throws -> Void
        var deactivate: @Sendable () -> Void

        static let system = Backend(activate: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)
        }, deactivate: {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        })
    }

    static let shared = LiveAudioSession(backend: .system)

    private let backend: Backend
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var holds = LiveAudioHolds()
    private var nextToken = 0
    /// Started engines by call; touched only on `queue`.
    private var engines: [Int: any LiveAudioEngine] = [:]

    init(backend: Backend, queue: DispatchQueue = DispatchQueue(label: "dev.verdeai.app.live-audio", qos: .userInitiated)) {
        self.backend = backend
        self.queue = queue
    }

    /// A new call: activates the session in the background (while the host mints the provider
    /// token) and returns the call's token for `run` and `finish`.
    func begin() -> Int {
        let token = withHolds { holds -> Int in
            nextToken += 1
            holds.request(nextToken)
            return nextToken
        }
        queue.async { [self] in
            guard withHolds({ $0.acquire(token) }) else { return }
            let ok: Bool
            do { try backend.activate(); ok = true } catch { ok = false }
            withHolds { $0.activated(token, ok: ok) }
        }
        return token
    }

    /// Starts the call's engine once its session is active; false when activation or the engine
    /// failed, or the call already ended.
    func run(_ engine: any LiveAudioEngine, token: Int, inputRate: Double, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard withHolds({ $0.mayRun(token) }) else { return completion(false) }
            do {
                try engine.start(inputRate: inputRate)
                engines[token] = engine
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    /// Ends the call: skips its queued steps, stops its engine and, when no other call holds or
    /// waits for the session, deactivates it.
    func finish(_ token: Int, completion: (@Sendable () -> Void)? = nil) {
        withHolds { $0.end(token) }
        queue.async { [self] in
            engines.removeValue(forKey: token)?.stop()
            if withHolds({ $0.release(token) }) { backend.deactivate() }
            completion?()
        }
    }

    private func withHolds<T>(_ body: (inout LiveAudioHolds) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&holds)
    }
}

/*
 * Full-duplex audio for live voice: the microphone with voice processing (echo cancellation so the
 * model doesn't hear itself), converted to 16-bit mono PCM at the protocol's input rate in ~40 ms
 * chunks, and 24 kHz PCM16 replies played through an AVAudioPlayerNode. Audio is never stored.
 * `start`/`stop` run on `LiveAudioSession`'s queue; `play`, `flush` and `muted` on the main actor;
 * the callbacks on the audio thread.
 */
final class LiveAudio: LiveAudioEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var running = false
    private var mutedFlag = false
    private var chunker = PCMChunker(chunkBytes: 1920)
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
    /// One encoded chunk of microphone audio.
    private let onChunk: @Sendable (Data) -> Void
    /// Microphone level 0...1.
    private let onLevel: @Sendable (Double) -> Void

    init(onChunk: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Double) -> Void) {
        self.onChunk = onChunk
        self.onLevel = onLevel
    }

    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mutedFlag }
        set { lock.lock(); mutedFlag = newValue; lock.unlock() }
    }

    func start(inputRate: Double) throws {
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            let hardware = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputRate, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: hardware, to: target), let playbackFormat else {
                throw LiveVoiceError.failed("audio")
            }
            converter.downmix = true
            self.converter = converter
            self.target = target
            lock.lock(); chunker = PCMChunker(chunkBytes: pcmChunkBytes(rate: inputRate)); lock.unlock()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in self?.captured(buffer) }
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            // A half-started engine releases the microphone before the session is deactivated.
            input.removeTap(onBus: 0)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            if player.engine != nil { engine.detach(player) }
            throw error
        }
        lock.lock(); running = true; lock.unlock()
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target, buffer.frameLength > 0 else { return }
        if let samples = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            onLevel(normalizedLevel(rms: (sum / Float(buffer.frameLength)).squareRoot()))
        }
        if muted { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(out.frameLength) * 2)
        lock.lock()
        let chunks = chunker.append(data)
        lock.unlock()
        for chunk in chunks { onChunk(chunk) }
    }

    /// Queues one reply chunk (16-bit mono PCM at 24 kHz); returns its level for the orb. Replies
    /// that arrive before the engine has started are dropped.
    @discardableResult
    func play(_ pcm16: Data) -> Double {
        guard let playbackFormat else { return 0 }
        let floats = pcm16Floats(pcm16)
        guard !floats.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(floats.count)),
              let channel = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for (index, value) in floats.enumerated() { channel[index] = value; sum += value * value }
        buffer.frameLength = AVAudioFrameCount(floats.count)
        guard isRunning else { return 0 }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return normalizedLevel(rms: (sum / Float(floats.count)).squareRoot())
    }

    /// Barge-in: drop everything queued.
    func flush() {
        guard isRunning else { return }
        player.stop()
        player.play()
    }

    /// The main actor only plays into a started engine; `stop` runs after it has let go of this one.
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.detach(player)
    }
}

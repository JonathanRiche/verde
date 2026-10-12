import AVFoundation
import Foundation

/*
 * Full-duplex audio for live voice: the microphone with voice processing (echo cancellation so the
 * model doesn't hear itself), converted to 16-bit mono PCM at the protocol's input rate in ~40 ms
 * chunks, and 24 kHz PCM16 replies played through an AVAudioPlayerNode. Audio is never stored.
 * Callbacks arrive on the audio thread.
 */
final class LiveAudio {
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
    var onChunk: ((Data) -> Void)?
    /// Microphone level 0...1.
    var onLevel: ((Double) -> Void)?

    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mutedFlag }
        set { lock.lock(); mutedFlag = newValue; lock.unlock() }
    }

    func start(inputRate: Double) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
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
        running = true
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target, buffer.frameLength > 0 else { return }
        if let samples = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            onLevel?(normalizedLevel(rms: (sum / Float(buffer.frameLength)).squareRoot()))
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
        for chunk in chunks { onChunk?(chunk) }
    }

    /// Queues one reply chunk (16-bit mono PCM at 24 kHz); returns its level for the orb.
    @discardableResult
    func play(_ pcm16: Data) -> Double {
        guard running, let playbackFormat else { return 0 }
        let floats = pcm16Floats(pcm16)
        guard !floats.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(floats.count)),
              let channel = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for (index, value) in floats.enumerated() { channel[index] = value; sum += value * value }
        buffer.frameLength = AVAudioFrameCount(floats.count)
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return normalizedLevel(rms: (sum / Float(floats.count)).squareRoot())
    }

    /// Barge-in: drop everything queued.
    func flush() {
        guard running else { return }
        player.stop()
        player.play()
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.detach(player)
        onChunk = nil
        onLevel = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

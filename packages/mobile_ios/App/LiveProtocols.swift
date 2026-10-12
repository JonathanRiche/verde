import Foundation

/*
 * Wire messages for live voice, per protocol. Pure (unit tested): building setup/audio/tool/inject
 * messages and parsing server events. `openai_realtime` serves xAI Grok Voice (classic session
 * shape) and OpenAI Realtime (GA shape); `gemini_live` serves Google Gemini Live.
 */

enum RealtimeEvent: Equatable {
    case ready
    case audio(Data)
    case assistantText(String)
    case userText(String)
    /// The user started talking: stop and flush playback (barge-in).
    case speechStarted
    /// The server cut its own reply short.
    case interrupted
    case toolCall(id: String, name: String, arguments: String)
    case turnComplete
    /// The server will close soon (Gemini): reconnect with a fresh session.
    case goAway
    case error(String)
}

func jsonString(_ object: [String: Any]) -> String { jsonText(object) }

/// Any JSON value (object, array or fragment) as text; "{}" when it can't be encoded.
func jsonText(_ value: Any) -> String {
    // An invalid object raises an Objective-C exception instead of throwing: check first.
    let fragment = value is String || value is NSNumber || value is NSNull
    guard fragment || JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

func jsonObject(_ text: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

/// A tool's JSON Schema; an empty or unreadable schema becomes an empty object schema.
func toolSchema(_ raw: String) -> [String: Any] {
    (jsonObject(raw) as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()] as [String: Any]
}

struct RealtimeProtocol: Equatable {
    enum Kind: Equatable { case openAIRealtime(ga: Bool), geminiLive }
    let kind: Kind

    /// `protocol` from the session; OpenAI itself uses the GA session shape, others (xAI) the classic one.
    init(protocolName: String, provider: String) {
        kind = protocolName == "gemini_live" ? .geminiLive : .openAIRealtime(ga: provider == "openai")
    }

    var inputRate: Double { kind == .geminiLive ? 16000 : 24000 }
    var outputRate: Double { 24000 }
    /// Gemini accepts audio only after `setupComplete`.
    var waitsForSetup: Bool { kind == .geminiLive }

    // MARK: Client messages

    func setup(instructions: String, model: String, voice: String, tools: [LiveVoiceTool]) -> String {
        switch kind {
        case .openAIRealtime(let ga):
            let functions: [[String: Any]] = tools.map { tool -> [String: Any] in
                ["type": "function", "name": tool.name, "description": tool.description, "parameters": toolSchema(tool.parameters)]
            }
            var session: [String: Any]
            if ga {
                let format: [String: Any] = ["type": "audio/pcm", "rate": 24000]
                var output: [String: Any] = ["format": format]
                if !voice.isEmpty { output["voice"] = voice }
                let input: [String: Any] = ["format": format, "turn_detection": ["type": "server_vad"]]
                let audio: [String: Any] = ["input": input, "output": output]
                session = ["type": "realtime", "instructions": instructions, "audio": audio]
            } else {
                session = ["instructions": instructions, "input_audio_format": "pcm16", "output_audio_format": "pcm16",
                           "turn_detection": ["type": "server_vad"]]
                if !voice.isEmpty { session["voice"] = voice }
            }
            if !functions.isEmpty { session["tools"] = functions }
            return jsonString(["type": "session.update", "session": session])
        case .geminiLive:
            var generation: [String: Any] = ["responseModalities": ["AUDIO"]]
            if !voice.isEmpty {
                generation["speechConfig"] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]
            }
            var setup: [String: Any] = [
                "model": model.hasPrefix("models/") ? model : "models/" + model,
                "generationConfig": generation,
                "systemInstruction": ["parts": [["text": instructions]]],
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any](),
            ]
            if !tools.isEmpty {
                let declarations: [[String: Any]] = tools.map { tool -> [String: Any] in
                    ["name": tool.name, "description": tool.description, "parameters": toolSchema(tool.parameters)]
                }
                setup["tools"] = [["functionDeclarations": declarations] as [String: Any]]
            }
            return jsonString(["setup": setup])
        }
    }

    func audio(_ pcm16: Data) -> String {
        let base64 = pcm16.base64EncodedString()
        switch kind {
        case .openAIRealtime: return jsonString(["type": "input_audio_buffer.append", "audio": base64])
        case .geminiLive: return jsonString(["realtimeInput": ["audio": ["data": base64, "mimeType": "audio/pcm;rate=16000"]]])
        }
    }

    /// The tool's result, then (OpenAI-style) a request for the model to continue.
    func toolResult(id: String, name: String, output: String) -> [String] {
        switch kind {
        case .openAIRealtime:
            let item: [String: Any] = ["type": "function_call_output", "call_id": id, "output": output]
            return [jsonString(["type": "conversation.item.create", "item": item]), jsonString(["type": "response.create"])]
        case .geminiLive:
            let response = (jsonObject(output) as? [String: Any]) ?? ["result": output]
            let entry: [String: Any] = ["id": id, "name": name, "response": response]
            return [jsonString(["toolResponse": ["functionResponses": [entry]]])]
        }
    }

    /// Text the model should react to (e.g. a `companion_update`).
    func inject(_ text: String) -> [String] {
        switch kind {
        case .openAIRealtime:
            let item: [String: Any] = ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]
            return [jsonString(["type": "conversation.item.create", "item": item]), jsonString(["type": "response.create"])]
        case .geminiLive:
            let turn: [String: Any] = ["role": "user", "parts": [["text": text]]]
            return [jsonString(["clientContent": ["turns": [turn], "turnComplete": true] as [String: Any]])]
        }
    }

    // MARK: Server events

    func parse(_ text: String) -> [RealtimeEvent] {
        guard let message = jsonObject(text) as? [String: Any] else { return [] }
        switch kind {
        case .openAIRealtime: return parseOpenAI(message)
        case .geminiLive: return parseGemini(message)
        }
    }

    private func parseOpenAI(_ m: [String: Any]) -> [RealtimeEvent] {
        let type = m["type"] as? String ?? ""
        switch type {
        case "session.created", "session.updated": return [.ready]
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = m["delta"] as? String, let data = Data(base64Encoded: delta) else { return [] }
            return [.audio(data)]
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return (m["delta"] as? String).map { [.assistantText($0)] } ?? []
        case "conversation.item.input_audio_transcription.completed":
            return (m["transcript"] as? String).map { [.userText($0)] } ?? []
        case "input_audio_buffer.speech_started": return [.speechStarted]
        case "response.function_call_arguments.done":
            guard let id = m["call_id"] as? String, let name = m["name"] as? String else { return [] }
            return [.toolCall(id: id, name: name, arguments: m["arguments"] as? String ?? "{}")]
        case "response.done": return [.turnComplete]
        case "error":
            let error = m["error"] as? [String: Any]
            return [.error(error?["message"] as? String ?? error?["code"] as? String ?? "error")]
        default: return []
        }
    }

    private func parseGemini(_ m: [String: Any]) -> [RealtimeEvent] {
        var events: [RealtimeEvent] = []
        if m["setupComplete"] != nil { events.append(.ready) }
        if let content = m["serverContent"] as? [String: Any] {
            if content["interrupted"] as? Bool == true { events.append(.interrupted) }
            if let input = (content["inputTranscription"] as? [String: Any])?["text"] as? String { events.append(.userText(input)) }
            if let output = (content["outputTranscription"] as? [String: Any])?["text"] as? String { events.append(.assistantText(output)) }
            let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any], let base64 = inline["data"] as? String, let data = Data(base64Encoded: base64) {
                    events.append(.audio(data))
                }
            }
            if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        }
        if let call = m["toolCall"] as? [String: Any] {
            for function in call["functionCalls"] as? [[String: Any]] ?? [] {
                guard let name = function["name"] as? String else { continue }
                let args = function["args"].map { jsonText($0) } ?? "{}"
                events.append(.toolCall(id: function["id"] as? String ?? "", name: name, arguments: args))
            }
        }
        if m["goAway"] != nil { events.append(.goAway) }
        if let error = m["error"] as? [String: Any] { events.append(.error(error["message"] as? String ?? "error")) }
        return events
    }
}

// MARK: - Audio framing

/// Bytes of 16-bit mono PCM for `milliseconds` at `rate`.
func pcmChunkBytes(rate: Double, milliseconds: Double = 40) -> Int { Int(rate * milliseconds / 1000) * 2 }

/// Collects converted microphone audio and emits fixed-size chunks (~40 ms), never splitting a sample.
struct PCMChunker {
    let chunkBytes: Int
    private(set) var pending = Data()

    init(chunkBytes: Int) { self.chunkBytes = max(2, chunkBytes - chunkBytes % 2) }

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(Data(pending.prefix(chunkBytes)))
            pending = Data(pending.dropFirst(chunkBytes))
        }
        return chunks
    }
}

/// Little-endian PCM16 to floats in -1...1 (a trailing odd byte is ignored).
func pcm16Floats(_ data: Data) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(data.count / 2)
    data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        var index = 0
        while index + 1 < bytes.count {
            let value = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            out.append(Float(value) / 32768)
            index += 2
        }
    }
    return out
}

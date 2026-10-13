import XCTest
@testable import VerdeApp

private func object(_ text: String) -> [String: Any] { (jsonObject(text) as? [String: Any]) ?? [:] }
private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func list(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

private let tools = [LiveVoiceTool(name: "ask_companion", description: "Ask the companion",
                                   parameters: #"{"type":"object","properties":{"request":{"type":"string"}},"required":["request"]}"#)]

final class LiveProtocolTests: XCTestCase {
    func testOpenAIUsesTheGASessionShape() {
        let proto = RealtimeProtocol(protocolName: "openai_realtime", provider: "openai")
        XCTAssertEqual(proto.inputRate, 24000)
        XCTAssertFalse(proto.waitsForSetup)
        let message = object(proto.setup(instructions: "Be brief", model: "gpt-realtime", voice: "marin", tools: tools))
        XCTAssertEqual(message["type"] as? String, "session.update")
        let session = dict(message["session"])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["instructions"] as? String, "Be brief")
        let audio = dict(session["audio"])
        XCTAssertEqual(dict(dict(audio["input"])["format"])["rate"] as? Int, 24000)
        XCTAssertEqual(dict(dict(audio["input"])["turn_detection"])["type"] as? String, "server_vad")
        XCTAssertEqual(dict(audio["output"])["voice"] as? String, "marin")
        let tool = list(session["tools"]).first ?? [:]
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, "ask_companion")
        XCTAssertEqual(dict(tool["parameters"])["type"] as? String, "object", "the raw schema string becomes an object")
    }

    func testXAIUsesTheClassicSessionShape() {
        let proto = RealtimeProtocol(protocolName: "openai_realtime", provider: "xai")
        let session = dict(object(proto.setup(instructions: "Hi", model: "grok", voice: "Ara", tools: [])))["session"]
        let classic = dict(session)
        XCTAssertNil(classic["type"])
        XCTAssertEqual(classic["voice"] as? String, "Ara")
        XCTAssertEqual(classic["input_audio_format"] as? String, "pcm16")
        XCTAssertEqual(classic["output_audio_format"] as? String, "pcm16")
        XCTAssertEqual(dict(classic["turn_detection"])["type"] as? String, "server_vad")
        XCTAssertNil(classic["tools"])
        XCTAssertEqual(dict(dict(dict(classic["audio"])["input"])["transcription"])["model"] as? String, "grok-transcribe")
        XCTAssertEqual(proto.parse(#"{"type":"conversation.item.input_audio_transcription.updated","transcript":"turn on the"}"#),
                       [.userTextPartial("turn on the", cumulative: true, item: nil)])
        XCTAssertEqual(proto.parse(#"{"type":"conversation.item.input_audio_transcription.updated","item_id":"item_7","transcript":"Hi"}"#),
                       [.userTextPartial("Hi", cumulative: true, item: "item_7")])
        let append = object(proto.audio(Data([1, 2, 3])))
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testGeminiSetupAndAudio() {
        let proto = RealtimeProtocol(protocolName: "gemini_live", provider: "google")
        XCTAssertEqual(proto.inputRate, 16000)
        XCTAssertTrue(proto.waitsForSetup)
        let setup = dict(object(proto.setup(instructions: "Hi", model: "gemini-live-2.5", voice: "Puck", tools: tools))["setup"])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-live-2.5")
        let generation = dict(setup["generationConfig"])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertEqual(dict(dict(dict(generation["speechConfig"])["voiceConfig"])["prebuiltVoiceConfig"])["voiceName"] as? String, "Puck")
        XCTAssertEqual(list(dict(setup["systemInstruction"])["parts"]).first?["text"] as? String, "Hi")
        XCTAssertNotNil(setup["inputAudioTranscription"])
        XCTAssertNotNil(setup["outputAudioTranscription"])
        XCTAssertEqual(list(list(setup["tools"]).first?["functionDeclarations"]).first?["name"] as? String, "ask_companion")
        let prefixed = dict(object(proto.setup(instructions: "", model: "models/x", voice: "", tools: []))["setup"])
        XCTAssertEqual(prefixed["model"] as? String, "models/x")
        let audio = dict(dict(object(proto.audio(Data([9, 9])))["realtimeInput"])["audio"])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, Data([9, 9]).base64EncodedString())
    }

    func testOpenAIEvents() {
        let proto = RealtimeProtocol(protocolName: "openai_realtime", provider: "openai")
        let pcm = Data([0, 1, 2, 3]).base64EncodedString()
        XCTAssertEqual(proto.parse(#"{"type":"response.output_audio.delta","delta":"\#(pcm)"}"#), [.audio(Data([0, 1, 2, 3]))])
        XCTAssertEqual(proto.parse(#"{"type":"response.audio.delta","delta":"\#(pcm)"}"#), [.audio(Data([0, 1, 2, 3]))])
        XCTAssertEqual(proto.parse(#"{"type":"response.audio_transcript.delta","delta":"Hel"}"#), [.assistantText("Hel")])
        XCTAssertEqual(proto.parse(#"{"type":"response.output_audio_transcript.delta","delta":"lo"}"#), [.assistantText("lo")])
        XCTAssertEqual(proto.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hey"}"#), [.userText("hey", item: nil)])
        XCTAssertEqual(proto.parse(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"he"}"#),
                       [.userTextPartial("he", cumulative: false, item: nil)])
        XCTAssertEqual(proto.parse(#"{"type":"input_audio_buffer.speech_started"}"#), [.speechStarted])
        XCTAssertEqual(proto.parse(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"companion_status","arguments":"{}"}"#),
                       [.toolCall(id: "c1", name: "companion_status", arguments: "{}")])
        XCTAssertEqual(proto.parse(#"{"type":"session.updated"}"#), [.ready])
        XCTAssertEqual(proto.parse(#"{"type":"error","error":{"message":"bad"}}"#), [.error("bad")])
        XCTAssertEqual(proto.parse("not json"), [])
    }

    func testGeminiEvents() {
        let proto = RealtimeProtocol(protocolName: "gemini_live", provider: "google")
        XCTAssertEqual(proto.parse(#"{"setupComplete":{}}"#), [.ready])
        let pcm = Data([5, 6]).base64EncodedString()
        let content = #"{"serverContent":{"interrupted":true,"outputTranscription":{"text":"Hi"},"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(pcm)"}}]},"turnComplete":true}}"#
        XCTAssertEqual(proto.parse(content), [.interrupted, .assistantText("Hi"), .audio(Data([5, 6])), .turnComplete])
        let call = proto.parse(#"{"toolCall":{"functionCalls":[{"id":"f1","name":"decide_approval","args":{"approve":true}}]}}"#)
        XCTAssertEqual(call, [.toolCall(id: "f1", name: "decide_approval", arguments: #"{"approve":true}"#)])
        XCTAssertEqual(proto.parse(#"{"goAway":{"timeLeft":"10s"}}"#), [.goAway])
    }

    func testToolResultsAndInjectedUpdates() {
        let openai = RealtimeProtocol(protocolName: "openai_realtime", provider: "xai")
        let result = openai.toolResult(id: "c1", name: "ask_companion", output: #"{"accepted":true}"#)
        XCTAssertEqual(result.count, 2)
        let item = dict(object(result[0])["item"])
        XCTAssertEqual(object(result[0])["type"] as? String, "conversation.item.create")
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "c1")
        XCTAssertEqual(item["output"] as? String, #"{"accepted":true}"#)
        XCTAssertEqual(object(result[1])["type"] as? String, "response.create")
        let injected = openai.inject("companion_update: done")
        let message = dict(object(injected[0])["item"])
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(list(message["content"]).first?["text"] as? String, "companion_update: done")

        let gemini = RealtimeProtocol(protocolName: "gemini_live", provider: "google")
        let response = list(dict(object(gemini.toolResult(id: "f1", name: "x", output: "plain")[0])["toolResponse"])["functionResponses"]).first ?? [:]
        XCTAssertEqual(response["id"] as? String, "f1")
        XCTAssertEqual(dict(response["response"])["result"] as? String, "plain", "non-object output is wrapped")
        let turn = dict(object(gemini.inject("hello")[0])["clientContent"])
        XCTAssertEqual(turn["turnComplete"] as? Bool, true)
        XCTAssertEqual(list(list(turn["turns"]).first?["parts"]).first?["text"] as? String, "hello")
    }

    func testPCMChunking() {
        XCTAssertEqual(pcmChunkBytes(rate: 24000), 1920)
        XCTAssertEqual(pcmChunkBytes(rate: 16000), 1280)
        var chunker = PCMChunker(chunkBytes: 1920)
        XCTAssertTrue(chunker.append(Data(count: 1000)).isEmpty)
        let chunks = chunker.append(Data(count: 3000))
        XCTAssertEqual(chunks.map(\.count), [1920, 1920])
        XCTAssertEqual(chunker.pending.count, 160)
        XCTAssertEqual(PCMChunker(chunkBytes: 7).chunkBytes, 6, "never splits a 16-bit sample")
        XCTAssertEqual(pcm16Floats(Data([0x00, 0x80, 0xff, 0x7f, 0x01])), [-1, Float(32767) / 32768])
    }
}

final class LiveToolTests: XCTestCase {
    private let pending = [
        NeedsYouItem(workspaceID: "w1", threadID: "t1", title: "Deploy API", workspaceLabel: "backend", reason: "Needs approval"),
        NeedsYouItem(workspaceID: "w2", threadID: "t2", title: "Deploy web", workspaceLabel: "frontend", reason: "Needs approval"),
        NeedsYouItem(workspaceID: "w3", threadID: "t3", title: "Fix tests", workspaceLabel: "backend", reason: "Needs input"),
    ]

    func testApprovalMatching() {
        XCTAssertEqual(matchApproval("deploy api", pending), .found(pending[0]))
        XCTAssertEqual(matchApproval("frontend", pending), .found(pending[1]), "workspace names count")
        XCTAssertEqual(matchApproval("deploy", pending), .ambiguous)
        XCTAssertEqual(matchApproval("fix tests", pending), .notFound, "blocked chats aren't approvals")
        XCTAssertEqual(matchApproval("", pending), .ambiguous)
        XCTAssertEqual(matchApproval("", [pending[0]]), .found(pending[0]))
        XCTAssertEqual(matchApproval("", []), .notFound)
    }

    func testArguments() {
        let args = toolArguments(#"{"chat":" Deploy API ","approve":"yes","n":1}"#)
        XCTAssertEqual(stringArgument(args["chat"]), "Deploy API")
        XCTAssertEqual(boolArgument(args["approve"]), true)
        XCTAssertEqual(boolArgument(args["n"]), true)
        XCTAssertEqual(boolArgument(false), false)
        XCTAssertEqual(boolArgument("deny"), false)
        XCTAssertNil(boolArgument("maybe"))
        XCTAssertNil(stringArgument("   "))
        XCTAssertTrue(toolArguments("[1]").isEmpty)
    }

    func testStatusAndUpdateText() {
        let status = object(companionStatusJSON(name: "Moss", status: "1 thing needs you", needsYou: [pending[0]],
                                                crew: [CrewLink(link_id: "1", workspace_id: "w9", local_thread_id: "c", title: "Build", status: "running")],
                                                workspaceLabels: ["w9": "infra"]))
        XCTAssertEqual(status["companion"] as? String, "Moss")
        XCTAssertEqual(list(status["needs_you"]).first?["chat"] as? String, "Deploy API")
        XCTAssertEqual(list(status["crew"]).first?["status"] as? String, "Running")
        XCTAssertEqual(list(status["crew"]).first?["workspace"] as? String, "infra")
        XCTAssertEqual(companionUpdateText("**Done.** See [PR](https://x.y/1).\n```\ncode\n```"), "companion_update: Done. See PR.")
        let long = companionUpdateText(String(repeating: "a", count: 700))
        XCTAssertEqual(long.count, "companion_update: ".count + 601)
        XCTAssertEqual(jsonString(["error": "ambiguous"]), toolError("ambiguous"))
    }
}

final class LiveVoiceCoreTests: XCTestCase {
    func testViewDecodesProvidersAndSession() throws {
        let json = """
        {"api_version":1,"revision":"3","data":{"loaded":true,"loading":false,"supported":true,"default_provider":"xai",
         "providers":[{"id":"xai","label":"xAI Grok","protocol":"openai_realtime","configured":true,"key_source":"environment","model":"grok-voice","voice":"Ara","voices":["Ara","Rex"]}],
         "session":{"intent_id":"i1","status":"ready","provider":"xai","protocol":"openai_realtime","model":"grok-voice","voice":"Ara",
          "token":"t","expires_at_ms":5,"websocket_url":"wss://api.x.ai/v1/realtime","auth":"bearer","instructions":"Hi",
          "tools":[{"name":"companion_status","description":"d","parameters":"{}"},{"name":"x","description":"","parameters":{"type":"object"}}],
          "companion":{"id":"c","name":"Moss","home_workspace_id":"w","thread_id":"t"}}},"error":null}
        """
        let view = try XCTUnwrap(decodeLiveVoiceView(Data(json.utf8)))
        XCTAssertEqual(view.default_provider, "xai")
        XCTAssertEqual(view.providers.first?.protocolName, "openai_realtime")
        XCTAssertEqual(view.providers.first?.voices, ["Ara", "Rex"])
        XCTAssertEqual(view.providers.first?.keyDescription, "Key from the desktop's environment")
        let session = try XCTUnwrap(view.session)
        XCTAssertEqual(session.status, "ready")
        XCTAssertEqual(session.protocolName, "openai_realtime")
        XCTAssertEqual(session.auth, "bearer")
        XCTAssertEqual(session.tools.map(\.name), ["companion_status", "x"])
        XCTAssertEqual(session.tools[1].parameters, #"{"type":"object"}"#, "an object schema is kept as JSON text")
        XCTAssertEqual(session.companion?.name, "Moss")
        XCTAssertNil(decodeLiveVoiceView(Data(#"{"data":null}"#.utf8)))
    }

    func testIntentFieldsOmitEmptyValues() {
        let configure = LiveVoiceIntent.configureFields(intentID: "i", provider: "openai", apiKey: "", model: nil, voice: "marin", makeDefault: true)
        XCTAssertNil(configure["api_key"])
        XCTAssertNil(configure["model"])
        if case .string(let voice)? = configure["voice"] { XCTAssertEqual(voice, "marin") } else { XCTFail("voice") }
        if case .bool(let value)? = configure["make_default"] { XCTAssertTrue(value) } else { XCTFail("make_default") }
        let session = LiveVoiceIntent.sessionFields(intentID: "i", provider: nil, model: "", voice: nil, companionID: "c1")
        XCTAssertNil(session["provider"])
        if case .string(let id)? = session["companion_id"] { XCTAssertEqual(id, "c1") } else { XCTFail("companion_id") }
        XCTAssertEqual(liveVoiceMessage("voice_not_configured"), "Add an API key for a live voice provider in Companion settings.")
    }
}

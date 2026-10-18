import XCTest
@testable import VerdeApp

final class LiveProtocolTests: XCTestCase {
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
}

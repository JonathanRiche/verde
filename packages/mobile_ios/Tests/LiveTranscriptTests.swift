import XCTest
@testable import VerdeApp

final class LiveTranscriptTests: XCTestCase {
    private func make() -> LiveTranscript {
        LiveTranscript(sessionID: "s1", companionName: "Moss", providerLabel: "xAI Grok", startedAt: Date(timeIntervalSince1970: 100), timeText: "9:41")
    }

    func testEmptySessionSavesNothing() {
        var record = make()
        XCTAssertTrue(record.isEmpty)
        XCTAssertEqual(record.lines.first?.body, "🎙 Live voice · xAI Grok · 9:41")
        XCTAssertEqual(record.lines.first?.author, "Live")
        record.finish()
        XCTAssertTrue(record.unsaved.isEmpty)
    }

    func testDeltasMergeIntoOneReplyLine() {
        var record = make()
        record.user("What's running?", final: true, cumulative: true, at: 1)
        record.assistant("Two ", at: 2)
        record.assistant("chats are running.", at: 3)
        XCTAssertEqual(record.unsaved.map(\.body), ["🎙 Live voice · xAI Grok · 9:41", "What's running?"], "an open reply waits")
        record.endResponse()
        let lines = record.unsaved
        XCTAssertEqual(lines.map(\.body), ["🎙 Live voice · xAI Grok · 9:41", "What's running?", "Two chats are running."])
        XCTAssertEqual(lines.map(\.author), ["Live", "You (voice)", "Moss (voice)"])
        XCTAssertEqual(lines.map(\.role), ["system", "user", "assistant"])
        XCTAssertEqual(Set(lines.map(\.key)).count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.key.hasPrefix("s1:") })
    }

    func testCumulativeUpdatesReplaceAndLateTranscriptsKeepOrder() {
        var record = make()
        record.speechStarted()
        record.user("turn", final: false, cumulative: true, at: 1)
        record.user("turn on the", final: false, cumulative: true, at: 2)
        record.user("turn on the dev servers", final: true, cumulative: true, at: 3)
        XCTAssertEqual(record.lines.filter { $0.role == "user" }.map(\.body), ["turn on the dev servers"])

        // OpenAI: the next transcript lands after the reply started.
        record.speechStarted()
        record.assistant("Sure", at: 10)
        record.user("and watch them", final: true, cumulative: true, at: 11)
        record.assistant(", watching.", at: 12)
        record.endResponse()
        XCTAssertEqual(record.lines.dropFirst().map(\.body), ["turn on the dev servers", "and watch them", "Sure, watching."])
        XCTAssertLessThan(record.lines[2].createdAtMs, record.lines[3].createdAtMs)
    }

    func testDeltaTranscriptsAppendUntilTheTurnEnds() {
        var record = make()
        record.user("check ", final: false, cumulative: false, at: 1)
        record.user("the build", final: false, cumulative: false, at: 2)
        record.assistant("On it.", at: 3)
        XCTAssertEqual(record.unsaved.count, 1, "the utterance is still open")
        record.endResponse(newTurn: true)
        XCTAssertEqual(record.unsaved.dropFirst().map(\.body), ["check the build", "On it."])
    }

    func testToolLinesAndSavingByKey() {
        var record = make()
        record.user("ask Moss to run the tests", final: true, cumulative: true, at: 1)
        record.system("→ Asked Moss: run the tests", at: 2)
        let first = record.unsaved
        XCTAssertEqual(first.last?.body, "→ Asked Moss: run the tests")
        record.markSaved(through: first.last!.key)
        XCTAssertTrue(record.unsaved.isEmpty, "saved lines are never sent again")
        record.system("← Moss replied", at: 3)
        XCTAssertEqual(record.unsaved.map(\.body), ["← Moss replied"])
        record.markSaved(through: "unknown")
        XCTAssertEqual(record.unsaved.count, 1)
    }

    func testBatching() {
        let lines = (0..<450).map { LiveTranscriptLine(key: "s:\($0)", role: "user", author: "You (voice)", body: "x", createdAtMs: Int64($0)) }
        let batches = transcriptBatches(lines)
        XCTAssertEqual(batches.map(\.count), [200, 200, 50])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.key), lines.map(\.key))
        XCTAssertTrue(transcriptBatches([]).isEmpty)
    }

    func testSaveEventFields() {
        let line = LiveTranscriptLine(key: "s1:1", role: "user", author: "You (voice)", body: "hi", createdAtMs: 7)
        let fields = LiveVoiceIntent.transcriptFields(intentID: "i", workspaceID: "w", threadID: "t", sessionID: "s1", lines: [line])
        if case .string(let value)? = fields["session_id"] { XCTAssertEqual(value, "s1") } else { XCTFail("session_id") }
        guard case .array(let messages)? = fields["messages"], case .object(let message)? = messages.first else { return XCTFail("messages") }
        if case .string(let key)? = message["key"] { XCTAssertEqual(key, "s1:1") } else { XCTFail("key") }
        if case .integer(let at)? = message["created_at_ms"] { XCTAssertEqual(at, 7) } else { XCTFail("created_at_ms") }
        XCTAssertTrue(isVoiceAuthor("Moss (voice)"))
        XCTAssertTrue(isVoiceAuthor("Live"))
        XCTAssertFalse(isVoiceAuthor("Moss"))
    }
}

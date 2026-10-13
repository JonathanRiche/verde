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
        record.user(" now", final: false, cumulative: false, at: 3)
        record.assistant("On it.", at: 4)
        record.user(" please", final: false, cumulative: false, at: 5) // Gemini's input pieces can lag the reply.
        XCTAssertEqual(record.unsaved.map(\.body), ["🎙 Live voice · xAI Grok · 9:41", "check the build now please"],
                       "the reply starting closes the utterance; the open reply waits")
        record.endResponse(newTurn: true)
        XCTAssertEqual(record.unsaved.dropFirst().map(\.body), ["check the build now please", "On it."])
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

    /// The reported xAI run: cumulative `.updated` snapshots that keep growing across utterances,
    /// repeats, and a punctuation rewrite ("work. Thanks." → "work, thanks.").
    func testXAICumulativeTranscriptSavesEachUtteranceOnce() {
        var record = make()
        var at: Int64 = 0
        func update(_ text: String, _ item: String) {
            at += 100
            record.user(text, final: false, cumulative: true, item: item, at: at)
        }
        record.speechStarted()
        for text in ["Alright.", "Alright.", "Alright, okay.", "Alright, okay. Let's get",
                     "Alright, okay. Let's get back to work. Thanks.", "Alright, okay. Let's get back to work. Thanks.",
                     "Alright, okay. Let's get back to work. Thanks."] { update(text, "item_1") }
        XCTAssertEqual(record.currentUserText, "Alright, okay. Let's get back to work. Thanks.", "captions follow the open line")
        record.assistant("Sure.", at: at + 50)
        record.endResponse()
        record.speechStarted()
        for text in ["Alright, okay. Let's get back to work. Thanks. Okay.",
                     "Alright, okay. Let's get back to work, thanks. Okay so here's a bug.",
                     "Alright, okay. Let's get back to work, thanks. Okay so here's a bug.",
                     "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats",
                     "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say.",
                     "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say two times.",
                     "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say two times."] {
            update(text, "item_2")
        }
        // The same item again after a pause adds nothing new.
        record.tick(now: at + LiveTranscript.userIdleMs)
        update("Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say two times.", "item_2")
        record.finish()
        XCTAssertEqual(record.unsaved.filter { $0.role == "user" }.map(\.body),
                       ["Alright, okay. Let's get back to work. Thanks.", "Okay so here's a bug. It repeats what you say two times."])
    }

    func testNewItemIDClosesTheOpenLineAndRepeatsStayOne() {
        var record = make()
        record.user("Like a", final: false, cumulative: true, item: "a", at: 1)
        record.user("Like a", final: false, cumulative: true, item: "a", at: 2)
        record.user("Like a dog", final: false, cumulative: true, item: "b", at: 3) // a new item closes "Like a"
        record.tick(now: 3 + LiveTranscript.userIdleMs)
        XCTAssertEqual(record.unsaved.filter { $0.role == "user" }.map(\.body), ["Like a", "dog"])
    }

    func testClosedRepeatIsDropped() {
        var record = make()
        record.user("Okay.", final: true, cumulative: true, at: 1)
        record.speechStarted()
        record.user("okay", final: true, cumulative: true, at: 2)
        XCTAssertEqual(record.unsaved.filter { $0.role == "user" }.map(\.body), ["Okay."])
    }

    func testPeriodicSaveMidUtteranceSavesNoOpenLine() {
        var record = make()
        record.user("Can you check", final: false, cumulative: true, item: "x", at: 1)
        XCTAssertTrue(record.unsaved.filter { $0.role == "user" }.isEmpty, "an open line is never saved")
        record.tick(now: 1 + LiveTranscript.userIdleMs - 1)
        XCTAssertTrue(record.unsaved.filter { $0.role == "user" }.isEmpty)
        record.tick(now: 1 + LiveTranscript.userIdleMs)
        XCTAssertEqual(record.unsaved.filter { $0.role == "user" }.map(\.body), ["Can you check"])
    }

    func testOpenAICompletedReplacesItsItemsLine() {
        var record = make()
        record.speechStarted()
        record.user("what's", final: false, cumulative: false, item: "i1", at: 1)
        record.user(" up", final: false, cumulative: false, item: "i1", at: 2)
        record.assistant("Not much.", at: 3)
        record.user("What's up?", final: true, cumulative: true, item: "i1", at: 4)
        record.endResponse()
        XCTAssertEqual(record.unsaved.dropFirst().map(\.body), ["What's up?", "Not much."])
    }

    func testSpeechMatching() {
        XCTAssertEqual(normalizedSpeech("Alright, okay. Let's  get back to work!"), "alright okay lets get back to work")
        XCTAssertEqual(remainderAfter(prefix: "Thanks. Okay.", in: "thanks. Okay so here's a bug."), "so here's a bug.")
        XCTAssertEqual(remainderAfter(prefix: "Like a", in: "Like a"), "")
        XCTAssertNil(remainderAfter(prefix: "work", in: "workers unite"), "word boundaries only")
        XCTAssertNil(remainderAfter(prefix: "Hello", in: "Goodbye"))
    }
}

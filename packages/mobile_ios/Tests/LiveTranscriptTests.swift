import XCTest
@testable import VerdeApp

final class LiveTranscriptTests: XCTestCase {
    private func make() -> LiveTranscript {
        LiveTranscript(sessionID: "s1", companionName: "Moss", providerLabel: "xAI Grok", startedAt: Date(timeIntervalSince1970: 100), timeText: "9:41")
    }

    func testCumulativeUpdatesReplaceAndLateTranscriptsKeepOrder() {
        var record = make()
        record.speechStarted()
        record.user("turn", final: false, cumulative: true, at: 1)
        record.user("turn on the", final: false, cumulative: true, at: 2)
        record.user("turn on the dev servers", final: true, cumulative: true, at: 3)
        XCTAssertEqual(record.lines.filter { $0.role == "user" }.map(\.body), ["turn on the dev servers"])

        // OpenAI: the next transcript lands after the reply started. It was said before the reply,
        // so it joins that turn's line (one user line per turn) rather than a line of its own.
        record.speechStarted()
        record.assistant("Sure", at: 10)
        record.user("and watch them", final: true, cumulative: true, at: 11)
        record.assistant(", watching.", at: 12)
        record.endResponse()
        XCTAssertEqual(record.lines.dropFirst().map(\.body), ["turn on the dev servers and watch them", "Sure, watching."])
        XCTAssertLessThan(record.lines[1].createdAtMs, record.lines[2].createdAtMs)

        // With no turn line before the reply, a late transcript still goes in front of it.
        record.speechStarted()
        record.assistant("Done", at: 20)
        record.user("thanks", final: true, cumulative: true, at: 21)
        record.endResponse()
        XCTAssertEqual(record.lines.suffix(2).map(\.body), ["thanks", "Done"])
        XCTAssertLessThan(record.lines[3].createdAtMs, record.lines[4].createdAtMs)
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

    /// The reported xAI session: each fragment arrives as its own item (partial, then final), a
    /// cumulative snapshot re-transcribes the start, and the whole turn is saved as one line that
    /// waits until the companion replies.
    func testFragmentedTurnIsSavedAsOneUserLine() {
        var record = make()
        var at: Int64 = 0
        for (n, text) in Self.fragments.enumerated() {
            at += 100
            record.speechStarted()
            record.user(text, final: false, cumulative: true, item: "item_\(n)", at: at)
            record.user(text, final: true, cumulative: true, item: "item_\(n)", at: at + 10)
            record.tick(now: at + 50)
        }
        XCTAssertEqual(record.unsaved.map(\.role), ["system"], "the turn is still being spoken")
        XCTAssertEqual(record.currentUserText, Self.mergedTurn)
        record.assistant("On it — kicking off that multi-prompt test thread now.", at: at + 200)
        record.endResponse()
        record.system("→ Asked Moss: Run a longer test.", at: at + 300)
        record.assistant("The companion accepted it.", at: at + 400)
        record.endResponse()
        record.system("← Moss replied", at: at + 500)
        record.finish()
        XCTAssertEqual(record.unsaved.map(\.role), ["system", "user", "assistant", "system", "assistant", "system"])
        XCTAssertEqual(record.unsaved.filter { $0.role == "user" }.map(\.body), [Self.mergedTurn])
    }

    /// The display merge over the rows already saved by older builds (rows 84–96).
    func testMergedSpeechCleansUpSavedFragments() {
        XCTAssertEqual(mergedSpeech(Self.fragments), Self.mergedTurn)
        XCTAssertEqual(mergedSpeech(["Alright.", "  ", "alright, okay"]), "alright, okay")
        XCTAssertEqual(mergedSpeech(["check the", "build"]), "check the build")
        XCTAssertEqual(voiceSpeakerName("Moss (voice)"), "Moss")
        XCTAssertTrue(isVoiceSpeaker("You (voice)"))
        XCTAssertFalse(isVoiceSpeaker(LiveTranscript.systemAuthor))
    }

    func testVoiceRowsGroupBySpeaker() {
        var rows = [ChatRow(id: "83", role: "system", author: "Live", body: "🎙 Live voice · xAI Grok · 14:31")]
        rows += Self.fragments.enumerated().map { ChatRow(id: "\(84 + $0.offset)", role: "user", author: "You (voice)", body: $0.element) }
        rows += [
            ChatRow(id: "97", role: "assistant", author: "Moss (voice)", body: "On it — kicking off that multi-prompt test thread now."),
            ChatRow(id: "98", role: "system", author: "Live", body: "→ Asked Moss: Run a longer test."),
            ChatRow(id: "99", role: "assistant", author: "Moss (voice)", body: "The companion accepted it."),
            ChatRow(id: "100", role: "system", author: "Live", body: "← Moss replied"),
            ChatRow(id: "101", role: "assistant", author: "Moss (voice)", body: "Good news."),
            ChatRow(id: "102", role: "assistant", author: "Moss (voice)", body: "The long run is live."),
            ChatRow(id: "103", role: "user", author: "", body: "typed"),
        ]
        let grouped = groupVoiceRows(rows)
        XCTAssertEqual(grouped.map(\.id), ["83", "84", "97", "98", "99", "100", "101", "103"])
        XCTAssertEqual(grouped[1].body, Self.mergedTurn)
        XCTAssertEqual(grouped[6].body, "Good news.\n\nThe long run is live.")
        XCTAssertEqual(grouped[7].body, "typed")
    }

    static let fragments = [
        "The companion", "to run a longer", "test.", "with the", "Muse wonderful", "model.", "It finished the basic test.",
        "The companion to run a longer test with the Muse wonderful model. And finish the basic test. I want one",
        "thread", "where you test", "multiple", "prompts, summary.", "prompt, summary, prompt.",
    ]
    static let mergedTurn = "The companion to run a longer test with the Muse wonderful model. And finish the basic test. "
        + "I want one thread where you test multiple prompts, summary. prompt, summary, prompt."
}

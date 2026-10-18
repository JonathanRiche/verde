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

        // OpenAI: the next transcript lands after the reply started.
        record.speechStarted()
        record.assistant("Sure", at: 10)
        record.user("and watch them", final: true, cumulative: true, at: 11)
        record.assistant(", watching.", at: 12)
        record.endResponse()
        XCTAssertEqual(record.lines.dropFirst().map(\.body), ["turn on the dev servers", "and watch them", "Sure, watching."])
        XCTAssertLessThan(record.lines[2].createdAtMs, record.lines[3].createdAtMs)
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
}

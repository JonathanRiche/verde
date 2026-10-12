import XCTest
@testable import VerdeApp

final class CompanionSpeechTests: XCTestCase {
    func testMarkdownBecomesSpeakableLines() {
        let reply = """
        # Plan
        Here is **the** [docs](https://x.y/z) and https://example.com/a.
        ```swift
        let x = 1
        ```
        - Run `npm_install`
        1. Done_now with snake_case
        This is *very* _nice_ 2 * 3
        """
        XCTAssertEqual(speechLines(reply), ["Plan", "Here is the docs and a link.", "Run npm_install",
                                            "Done_now with snake_case", "This is very nice 2 * 3"])
    }

    func testStreamingHoldsBackTheUnfinishedSentence() {
        let partial = "Sure. I'll check the servers now. They"
        XCTAssertEqual(speechSentences(partial, final: false), ["Sure.", "I'll check the servers now."])
        XCTAssertEqual(speechSentences(partial, final: true), ["Sure.", "I'll check the servers now.", "They"])
        XCTAssertEqual(speechSentences("Version 3.5 is out", final: false), [], "decimals don't end a sentence")
    }

    func testChunkerSpeaksEachSentenceOnce() {
        var chunker = SentenceChunker()
        let first = "Sure. I'll check the servers now. They"
        XCTAssertEqual(chunker.next(first, final: false), ["Sure.", "I'll check the servers now."])
        XCTAssertEqual(chunker.next(first, final: false), [])
        let more = first + " look fine.\n- api: up"
        XCTAssertEqual(chunker.next(more, final: false), ["They look fine."])
        XCTAssertEqual(chunker.next(more, final: true), ["api: up"])
    }

    func testOpenCodeFenceIsSkippedWhileStreaming() {
        let reply = "Run this:\n```sh\nnpm start"
        XCTAssertEqual(speechSentences(reply, final: false), [])
        XCTAssertEqual(speechSentences(reply, final: true), ["Run this:"])
    }

    func testReadAloudPolicy() {
        XCTAssertEqual(effectiveReadAloud(stored: "", voiceOverRunning: false), .afterVoice)
        XCTAssertEqual(effectiveReadAloud(stored: "", voiceOverRunning: true), .never)
        XCTAssertEqual(effectiveReadAloud(stored: "always", voiceOverRunning: true), .always)
        XCTAssertTrue(shouldReadAloud(.always, voiceTurn: false))
        XCTAssertTrue(shouldReadAloud(.afterVoice, voiceTurn: true))
        XCTAssertFalse(shouldReadAloud(.afterVoice, voiceTurn: false))
        XCTAssertFalse(shouldReadAloud(.never, voiceTurn: true))
    }

    func testHoldVersusDrag() {
        XCTAssertEqual(classifyPress(.undecided, elapsed: 0.1, distance: 2), .undecided)
        XCTAssertEqual(classifyPress(.undecided, elapsed: 0.1, distance: 15), .reposition)
        XCTAssertEqual(classifyPress(.undecided, elapsed: 0.31, distance: 3), .talk)
        XCTAssertEqual(classifyPress(.undecided, elapsed: 0.5, distance: 40), .reposition, "movement wins before a talk starts")
        XCTAssertEqual(classifyPress(.talk, elapsed: 0, distance: 100), .talk, "a talk never turns into a drag")
        XCTAssertEqual(classifyPress(.reposition, elapsed: 2, distance: 0), .reposition)
        XCTAssertTrue(talkCancelled(distance: 81))
        XCTAssertFalse(talkCancelled(distance: 50))
    }

    func testMicTapAndHold() {
        XCTAssertEqual(micRelease(startedByPress: true, elapsed: 0.1), .keepListening, "tap to start")
        XCTAssertEqual(micRelease(startedByPress: true, elapsed: 0.6), .send, "hold to talk")
        XCTAssertEqual(micRelease(startedByPress: false, elapsed: 0.1), .send, "tap to send")
    }

    func testLevel() {
        XCTAssertEqual(normalizedLevel(rms: 0), 0)
        XCTAssertEqual(normalizedLevel(rms: 1), 1)
        XCTAssertEqual(normalizedLevel(rms: 0.01), 0.2, accuracy: 0.001)
    }
}

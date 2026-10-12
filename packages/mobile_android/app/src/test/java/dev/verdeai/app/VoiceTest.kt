package dev.verdeai.app

import android.speech.SpeechRecognizer
import dev.verdeai.core.ChatRow
import org.junit.Assert.*
import org.junit.Test

class VoiceTest {
    // ---- Markdown → speech ----

    @Test fun speechTextDropsMarkupCodeTablesAndUrls() {
        val reply = """
            ## Status
            **All good.** I checked `verde` and *two* workspaces:
            - The dev server is up
            - Tests pass: see [the run](https://ci.example/run/1)
            ```zig
            const x = 1. Not spoken.
            ```
            | a | b |
            |---|---|
            Details at https://example.com/very/long/path?q=1 for later
            > Quoted line
        """.trimIndent()
        assertEquals("Status. All good. I checked verde and two workspaces: The dev server is up. " +
            "Tests pass: see the run. Details at a link for later. Quoted line.", speechText(reply))
    }

    @Test fun anUnclosedFenceHidesTheRestAndBareLinkTextBecomesALink() {
        assertEquals("Here is the fix:", speechText("Here is the fix:\n```kotlin\nval a = 1"))
        assertEquals("Open a link.", speechText("Open [https://x.dev](https://x.dev)"))
        assertEquals("", speechText("```\ncode\n```\n---\n"))
    }

    @Test fun streamingSpeaksOnlyCompleteSentencesAndStaysPrefixStable() {
        val partial = "On it. I'm checking the serv"
        assertEquals(listOf("On it."), speakableSentences(partial, final = false))
        val more = "On it. I'm checking the servers now. Two are"
        assertEquals(listOf("On it.", "I'm checking the servers now."), speakableSentences(more, final = false))
        assertEquals(listOf("On it.", "I'm checking the servers now.", "Two are up."), speakableSentences("$more up", final = true))
        // A finished line counts as a sentence even without punctuation.
        assertEquals(listOf("First item."), speakableSentences("- First item\n- Sec", final = false))
        assertEquals(listOf("Hello.", "World!"), splitSentences("Hello.  World!  "))
    }

    private fun row(id: String, role: String, body: String, delivery: String = "committed", kind: String = "message") =
        ChatRow(id = id, role = role, kind = kind, body = body, delivery = delivery)

    @Test fun trackerSpeaksEachNewSentenceOnceThenDisarmsWhenTheTurnEnds() {
        val tracker = ReplyTracker()
        val before = listOf(row("old", "assistant", "Earlier reply."))
        tracker.arm(before, voice = true, nowMs = 0)
        assertTrue(tracker.armed && tracker.voiceTurn)
        val user = row("u", "user", "what's running?")
        assertEquals(emptyList<String>(), tracker.next(before + user, turnActive = true, nowMs = 1))
        val streaming = row("a", "assistant", "Checking now. Two serv", delivery = "streaming")
        assertEquals(listOf("Checking now."), tracker.next(before + user + streaming, turnActive = true, nowMs = 2))
        assertEquals(emptyList<String>(), tracker.next(before + user + streaming, turnActive = true, nowMs = 3))
        val tool = row("t", "assistant", "ls", kind = "tool")
        val done = row("a", "assistant", "Checking now. Two servers are up.")
        assertEquals(listOf("Two servers are up."), tracker.next(before + user + streaming.copy(body = done.body) + tool, turnActive = false, nowMs = 4))
        assertFalse(tracker.armed)
        assertEquals(emptyList<String>(), tracker.next(before + user + done + row("b", "assistant", "Later."), turnActive = false, nowMs = 5))
    }

    @Test fun trackerWaitsForTheTurnAndTimesOutWhenNothingStarts() {
        val tracker = ReplyTracker(armTimeoutMs = 100)
        tracker.arm(emptyList(), voice = true, nowMs = 0)
        tracker.next(emptyList(), turnActive = false, nowMs = 50)
        assertTrue(tracker.armed)
        tracker.next(emptyList(), turnActive = false, nowMs = 200)
        assertFalse(tracker.armed)
        // "Always" arms mid-turn: this turn's rows after the last user message are spoken.
        val always = ReplyTracker()
        always.armAtTurn(listOf(row("u", "user", "hi"), row("a", "assistant", "Hello there. More", delivery = "streaming")), nowMs = 0)
        assertFalse(always.voiceTurn)
        assertEquals(listOf("Hello there."), always.next(listOf(row("u", "user", "hi"), row("a", "assistant", "Hello there. More", delivery = "streaming")), true, 1))
    }

    // ---- Policy ----

    @Test fun readAloudPolicy() {
        assertEquals(ReadAloud.AfterSpeech, effectiveReadAloud(null, talkBack = false))
        assertEquals(ReadAloud.Never, effectiveReadAloud(null, talkBack = true))
        assertEquals(ReadAloud.Always, effectiveReadAloud(ReadAloud.Always, talkBack = true))
        assertTrue(shouldReadReply(ReadAloud.AfterSpeech, voiceTurn = true))
        assertFalse(shouldReadReply(ReadAloud.AfterSpeech, voiceTurn = false))
        assertTrue(shouldReadReply(ReadAloud.Always, voiceTurn = false))
        assertFalse(shouldReadReply(ReadAloud.Always, voiceTurn = false, doNotDisturb = true))
        assertTrue(shouldReadReply(ReadAloud.Always, voiceTurn = true, doNotDisturb = true))
        assertFalse(shouldReadReply(ReadAloud.Never, voiceTurn = true))
        assertEquals(ReadAloud.AfterSpeech, ReadAloud.of("after_speech"))
        assertNull(ReadAloud.of("loud"))
    }

    // ---- Hold-to-talk ----

    private fun run(vararg events: TalkEvent): Pair<TalkState, List<TalkEffect>> {
        var state: TalkState = TalkState.Idle
        val effects = ArrayList<TalkEffect>()
        for (event in events) { val step = talkStep(state, event); state = step.state; effects += step.effects }
        return state to effects
    }

    @Test fun holdReleaseSendsTheFinalTranscript() {
        val (state, effects) = run(TalkEvent.Press, TalkEvent.Partial("start the"), TalkEvent.Partial("start the dev servers"),
            TalkEvent.Release, TalkEvent.Final("Start the dev servers"))
        assertEquals(TalkState.Idle, state)
        assertEquals(listOf(TalkEffect.Start, TalkEffect.Stop, TalkEffect.Send("Start the dev servers")), effects)
    }

    @Test fun draggingOffCancelsAndComingBackDoesNot() {
        assertEquals(listOf(TalkEffect.Start, TalkEffect.Abort), run(TalkEvent.Press, TalkEvent.Partial("oops"), TalkEvent.Move(true), TalkEvent.Release).second)
        assertEquals(listOf(TalkEffect.Start, TalkEffect.Stop),
            run(TalkEvent.Press, TalkEvent.Move(true), TalkEvent.Move(false), TalkEvent.Release).second)
        assertEquals(TalkState.Idle, run(TalkEvent.Press, TalkEvent.Cancel).first)
    }

    @Test fun recognizerEndingEarlyOrFailingKeepsWhatWasHeard() {
        // Silence ended recognition while still holding: release sends what was heard.
        val early = run(TalkEvent.Press, TalkEvent.Final("check CI"), TalkEvent.Release)
        assertEquals(TalkEffect.Send("check CI"), early.second.last())
        // An error after release still sends the partial.
        assertEquals(TalkEffect.Send("deploy"), run(TalkEvent.Press, TalkEvent.Partial("deploy"), TalkEvent.Release,
            TalkEvent.Error(SpeechRecognizer.ERROR_NETWORK)).second.last())
        // Nothing heard: a friendly failure, no send.
        val nothing = run(TalkEvent.Press, TalkEvent.Error(SpeechRecognizer.ERROR_NO_MATCH))
        assertEquals(TalkState.Idle, nothing.first)
        assertTrue(nothing.second.last() is TalkEffect.Failed)
        assertTrue(nothing.second.none { it is TalkEffect.Send })
        val blank = run(TalkEvent.Press, TalkEvent.Release, TalkEvent.Final(" "))
        assertTrue(blank.second.last() is TalkEffect.Failed)
        // A second press while listening is ignored.
        assertEquals(listOf(TalkEffect.Start), run(TalkEvent.Press, TalkEvent.Press).second)
    }

    @Test fun labelsAndDraftJoining() {
        assertEquals("Talk to Moss", micLabel(TalkState.Idle, "Moss"))
        assertEquals("Listening. Activate to stop and send", micLabel(TalkState.Listening(), "Moss"))
        assertEquals("Release to cancel", talkChip(TalkState.Listening("hi", cancelArmed = true)))
        assertEquals("hi", talkChip(TalkState.Listening("hi")))
        assertEquals("Listening…", talkChip(TalkState.Listening()))
        assertNull(talkChip(TalkState.Idle))
        assertEquals("draft\n\nspoken words", joinDraft("draft  ", " spoken words"))
        assertEquals("spoken", joinDraft("", "spoken"))
    }
}

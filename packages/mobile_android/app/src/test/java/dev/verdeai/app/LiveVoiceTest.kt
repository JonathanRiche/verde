package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class LiveVoiceTest {
    private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject
    private fun JsonObject.o(name: String) = this[name]!!.jsonObject
    private fun JsonObject.s(name: String) = this[name]!!.jsonPrimitive.content

    // ---- OpenAI Realtime protocol ----

    @Test fun openAiEventsParseFromEitherNamingAndToolsRoundTrip() {
        val proto = OpenAiRealtime(ga = true)
        val pcm = byteArrayOf(1, 2, 3, 4)
        val b64 = Base64.getEncoder().encodeToString(pcm)
        assertArrayEquals(pcm, (proto.parse("""{"type":"response.output_audio.delta","delta":"$b64"}""").single() as LiveEvent.Audio).pcm)
        assertArrayEquals(pcm, (proto.parse("""{"type":"response.audio.delta","delta":"$b64"}""").single() as LiveEvent.Audio).pcm)
        assertEquals(LiveEvent.AssistantText("Hi"), proto.parse("""{"type":"response.audio_transcript.delta","delta":"Hi"}""").single())
        assertEquals(LiveEvent.AssistantText("Hi"), proto.parse("""{"type":"response.output_audio_transcript.delta","delta":"Hi"}""").single())
        assertEquals(LiveEvent.UserText("check CI"), proto.parse("""{"type":"conversation.item.input_audio_transcription.completed","transcript":"check CI"}""").single())
        assertEquals(LiveEvent.Interrupted, proto.parse("""{"type":"input_audio_buffer.speech_started"}""").single())
        assertEquals(LiveEvent.Ignored("rate_limits.updated"), proto.parse("""{"type":"rate_limits.updated"}""").single())
        val call = proto.parse("""{"type":"response.function_call_arguments.done","call_id":"c9","name":"ask_companion","arguments":"{\"request\":\"run tests\"}"}""").single() as LiveEvent.ToolCall
        assertEquals("c9", call.callId)
        assertEquals("run tests", call.arguments["request"]!!.jsonPrimitive.content)
        val out = proto.toolResult("c9", "ask_companion", buildJsonObject { put("accepted", true) })
        val item = obj(out[0])
        assertEquals("conversation.item.create", item.s("type"))
        assertEquals("function_call_output", item.o("item").s("type"))
        assertEquals("c9", item.o("item").s("call_id"))
        assertEquals("""{"accepted":true}""", item.o("item").s("output"))
        assertEquals("response.create", obj(out[1]).s("type"))
        val inject = proto.inject("companion_update: done")
        assertEquals("input_text", obj(inject[0]).o("item")["content"]!!.jsonArray[0].jsonObject.s("type"))
        assertEquals("response.create", obj(inject[1]).s("type"))
        val append = obj(proto.audio(pcm))
        assertEquals("input_audio_buffer.append", append.s("type"))
        assertEquals(b64, append.s("audio"))
        assertEquals(LiveEvent.Failure("invalid_api_key"), proto.parse("""{"type":"error","error":{"code":"invalid_api_key"}}""").single())
        assertEquals(LiveEvent.Ignored("unreadable"), proto.parse("not json").single())
    }

    // ---- Tools ----

    private fun pane(title: String, thread: String, ws: String = "w", status: String = "waiting_approval") =
        Pane(id = "p-$thread", workspace_id = ws, kind = "chat", title = title, thread_id = thread, status = status, attention = true, attention_kind = "needs_approval")

    @Test fun approvalMatchingNeedsAUniqueChat() {
        val crew = listOf(CompanionLink(link_id = "l", workspace_id = "x", local_thread_id = "deploy-1", title = "Deploy staging", status = "waiting_approval"),
            CompanionLink(link_id = "m", workspace_id = "x", local_thread_id = "run-1", title = "Run things", status = "running"))
        val candidates = approvalCandidates(listOf(pane("Fix CI", "ci-1"), pane("Fix CI flake", "ci-2"), pane("Done", "d", status = "idle").copy(attention_kind = null)), crew)
        assertEquals(3, candidates.size)
        assertEquals("ci-1", (matchApproval("fix ci", candidates) as ApprovalMatch.Found).candidate.threadId)
        assertEquals("ci-2", (matchApproval("CI-2", candidates) as ApprovalMatch.Found).candidate.threadId)
        assertEquals("deploy-1", (matchApproval("staging", candidates) as ApprovalMatch.Found).candidate.threadId)
        assertEquals(ApprovalMatch.Ambiguous, matchApproval("fix", candidates))
        assertEquals(ApprovalMatch.NotFound, matchApproval("release", candidates))
        assertEquals(ApprovalMatch.NotFound, matchApproval("  ", candidates))
        assertEquals("run tests", toolArguments("""{"request":"run tests"}""")["request"]!!.jsonPrimitive.content)
        assertTrue(toolArguments("nope").isEmpty())
        assertTrue(toolArguments(null).isEmpty())
    }

    private fun record() = LiveTranscript(sessionId = "s1", assistantAuthor = liveAssistantAuthor("Moss"))

    // ---- xAI cumulative user transcripts (regression: every snapshot was saved as its own line) ----

    private fun upd(item: String, text: String) = LiveEvent.UserPartial(text, cumulative = true, itemId = item)
    private fun done(item: String, text: String) = LiveEvent.UserText(text, itemId = item)
    private fun reply(text: String) = listOf(LiveEvent.ResponseStarted, LiveEvent.AssistantText(text), LiveEvent.TurnDone)

    @Test fun cumulativeXaiSnapshotsBecomeOneLinePerUtterance() {
        val yeah = "Yeah, that sounds like the vibe. So, can you repeat what you suggest that I do for the rest of the day?"
        val alright = "Alright, okay. Let's get back to work. Thanks."
        val events = buildList {
            add(upd("u1", "Let me")); add(upd("u1", "Let me.")); add(upd("u1", "Let me.")); add(done("u1", "Let me."))
            addAll(reply("Sure."))
            add(upd("u2", "Yeah.")); add(upd("u2", "Yeah.")); add(upd("u2", "Yeah, that's")); add(upd("u2", "Yeah, that sounds like the vibe."))
            // A new item whose cumulative text spans the previous one.
            add(upd("u3", "Yeah, that sounds like the vibe, so")); add(upd("u3", "Yeah, that sounds like the vibe, so"))
            add(upd("u3", "Yeah, that sounds like the vibe. So,")); add(upd("u3", "Yeah, that sounds like the vibe. So, can you repeat what you suggest?"))
            add(upd("u3", "Yeah, that sounds like the vibe. So, can you repeat what you suggest that I do for the"))
            add(upd("u3", "Yeah, that sounds like the vibe. So, can you repeat what you suggest that I do for the rest of the"))
            add(upd("u3", yeah)); add(upd("u3", yeah)); add(done("u3", yeah))
            addAll(reply("Here's the plan."))
            add(upd("u4", "Like a")); add(upd("u4", "Like a"))
            addAll(reply("Like a what?"))
            add(upd("u5", "Alright.")); add(upd("u6", "Alright.")); add(upd("u6", "Alright, okay.")); add(upd("u6", "Alright, okay. Let's get"))
            repeat(3) { add(upd("u6", alright)) }
            add(done("u6", alright))
            // Cumulative across utterances, with a punctuation rewrite of the committed part.
            add(upd("u7", "$alright Okay."))
            repeat(2) { add(upd("u7", "Alright, okay. Let's get back to work, thanks. Okay so here's a bug.")) }
            add(upd("u7", "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats"))
            add(upd("u7", "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say."))
            repeat(3) { add(upd("u7", "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say two times.")) }
            add(done("u7", "Alright, okay. Let's get back to work, thanks. Okay so here's a bug. It repeats what you say two times."))
            addAll(reply("Got it."))
        }
        val t = record()
        events.forEachIndexed { i, event -> t.feed(event, i.toLong()) }
        val saved = t.pending(final = true)
        assertEquals(listOf(
            "user" to "Let me.", "assistant" to "Sure.",
            "user" to yeah, "assistant" to "Here's the plan.",
            "user" to "Like a", "assistant" to "Like a what?",
            // u6 and u7 are one user turn (no reply between them): one line.
            "user" to "$alright Okay so here's a bug. It repeats what you say two times.", "assistant" to "Got it.",
        ), saved.map { it.role to it.body })
        // Captions show the same merged lines.
        assertEquals("$alright Okay so here's a bug. It repeats what you say two times.", t.captions().first { it.user && it.text.startsWith("Alright") }.text)
        assertEquals(1, t.captions(20).count { it.text == "Like a" })
    }

    // ---- One line per user turn (regression: each fragment was saved as its own line) ----

    private val fragments = listOf("The companion", "to run a longer", "test.", "with the", "Muse wonderful", "model.", "It finished the basic test.",
        "The companion to run a longer test with the Muse wonderful model. And finish the basic test. I want one",
        "thread", "where you test", "multiple", "prompts, summary.", "prompt, summary, prompt.")
    private val mergedTurn = "The companion to run a longer test with the Muse wonderful model. And finish the basic test. " +
        "I want one thread where you test multiple prompts, summary. prompt, summary, prompt."

    @Test fun fragmentsAndASupersedingSnapshotMergeIntoOneTurn() {
        assertEquals(mergedTurn, mergeSpeech(fragments))
        // Containment supersedes too; unrelated words append.
        assertEquals(listOf("so yes run it"), mergeSpeechPieces(listOf("yes", "run"), "so yes run it"))
        assertEquals(listOf("yes", "no"), mergeSpeechPieces(listOf("yes"), "no"))
        assertEquals(listOf("yes"), mergeSpeechPieces(listOf("yes"), "  "))
    }

    @Test fun eachFragmentOfAUserTurnFoldsIntoOneSavedLine() {
        val t = record()
        var now = 0L
        t.header("🎙 Live voice · xAI Grok · 14:31", now)
        // One transcription item and final per fragment, then the cumulative snapshot in its own item.
        fragments.forEachIndexed { i, text -> t.feed(upd("f$i", text), ++now); t.feed(done("f$i", text), ++now) }
        // Mid-turn saves hold the user line back: it may still absorb more speech.
        assertEquals(listOf("system"), t.pending(final = false).map { it.role })
        reply("On it — kicking off that multi-prompt test thread now.").forEach { t.feed(it, ++now) }
        t.system("→ Asked Moss: Run a longer test.", ++now)
        reply("The companion accepted it.").forEach { t.feed(it, ++now) }
        val saved = t.pending(final = false)
        assertEquals(listOf("system", "user", "assistant", "system", "assistant"), saved.map { it.role })
        assertEquals(mergedTurn, saved[1].body)
        assertEquals(LIVE_USER_AUTHOR, saved[1].author)
        assertEquals(1, t.all.count { it.role == "user" })
    }
}

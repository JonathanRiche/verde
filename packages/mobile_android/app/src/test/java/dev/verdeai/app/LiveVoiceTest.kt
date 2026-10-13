package dev.verdeai.app

import dev.verdeai.core.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class LiveVoiceTest {
    private val tools = listOf(
        VoiceTool("ask_companion", "Hand off", """{"type":"object","properties":{"request":{"type":"string"}},"required":["request"]}"""),
        VoiceTool("companion_status", "Status", "not json"),
    )
    private fun session(provider: String, protocol: String, model: String = "m", voice: String = "Ara") = VoiceSession(
        intent_id = "i", status = "ready", provider = provider, protocol = protocol, model = model, voice = voice, token = "t",
        websocket_url = "wss://example", auth = "bearer", instructions = "You are Moss.", tools = tools,
        companion = VoiceSessionCompanion("c1", "Moss", "ws", "t1"))
    private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject
    private fun JsonObject.o(name: String) = this[name]!!.jsonObject
    private fun JsonObject.s(name: String) = this[name]!!.jsonPrimitive.content

    // ---- OpenAI Realtime protocol ----

    @Test fun xaiUsesTheClassicSessionShape() {
        val proto = liveProtocol(session("xai", "openai_realtime"))!!
        assertEquals(24_000, proto.inputRate)
        val update = obj(proto.setup(session("xai", "openai_realtime")).single())
        assertEquals("session.update", update.s("type"))
        val s = update.o("session")
        assertEquals("You are Moss.", s.s("instructions"))
        assertEquals("Ara", s.s("voice"))
        assertEquals("pcm16", s.s("input_audio_format"))
        assertEquals("pcm16", s.s("output_audio_format"))
        assertEquals("server_vad", s.o("turn_detection").s("type"))
        assertNull(s["type"])
        val tool = s["tools"]!!.jsonArray[0].jsonObject
        assertEquals("function", tool.s("type"))
        assertEquals("ask_companion", tool.s("name"))
        assertEquals("request", tool.o("parameters")["required"]!!.jsonArray[0].jsonPrimitive.content)
        // A malformed schema degrades to an empty object schema.
        assertEquals("object", s["tools"]!!.jsonArray[1].jsonObject.o("parameters").s("type"))
    }

    @Test fun openAiUsesTheGaSessionShape() {
        val s = obj(liveProtocol(session("openai", "openai_realtime", voice = "marin"))!!.setup(session("openai", "openai_realtime", voice = "marin")).single()).o("session")
        assertEquals("realtime", s.s("type"))
        val audio = s.o("audio")
        assertEquals("audio/pcm", audio.o("input").o("format").s("type"))
        assertEquals(24000, audio.o("input").o("format")["rate"]!!.jsonPrimitive.int)
        assertEquals("server_vad", audio.o("input").o("turn_detection").s("type"))
        assertTrue(audio.o("input").containsKey("transcription"))
        assertEquals("marin", audio.o("output").s("voice"))
        assertNull(s["voice"])
        assertEquals(2, s["tools"]!!.jsonArray.size)
    }

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

    @Test fun xaiEnablesGrokTranscriptionAndCumulativeUserTranscripts() {
        val s = obj(liveProtocol(session("xai", "openai_realtime"))!!.setup(session("xai", "openai_realtime")).single()).o("session")
        assertEquals("grok-transcribe", s.o("audio").o("input").o("transcription").s("model"))
        assertEquals("pcm16", s.s("input_audio_format"))
        val proto = OpenAiRealtime(ga = false)
        assertEquals(LiveEvent.UserPartial("start the dev", cumulative = true, itemId = "i1"),
            proto.parse("""{"type":"conversation.item.input_audio_transcription.updated","item_id":"i1","transcript":"start the dev"}""").single())
        assertEquals(LiveEvent.UserPartial("start", cumulative = false),
            proto.parse("""{"type":"conversation.item.input_audio_transcription.delta","delta":"start"}""").single())
        var c = liveCaptions(emptyList(), LiveEvent.UserPartial("start", cumulative = true))
        c = liveCaptions(c, LiveEvent.UserPartial("start the dev servers", cumulative = true))
        assertEquals(listOf(LiveCaption(true, "start the dev servers", open = true)), c)
        c = liveCaptions(c, LiveEvent.UserText("Start the dev servers."))
        assertEquals(listOf(LiveCaption(true, "Start the dev servers.")), c)
        assertEquals(listOf(LiveEvent.UserPartial("hel", cumulative = false)), GeminiLive().parse("""{"serverContent":{"inputTranscription":{"text":"hel"}}}"""))
    }

    // ---- Gemini Live protocol ----

    @Test fun geminiSetupAudioAndToolResponses() {
        val proto = liveProtocol(session("gemini", "gemini_live", model = "gemini-live-2.5", voice = "Puck"))!!
        assertEquals(16_000, proto.inputRate)
        assertFalse(proto.readyOnOpen)
        val setup = obj(proto.setup(session("gemini", "gemini_live", model = "gemini-live-2.5", voice = "Puck")).single()).o("setup")
        assertEquals("models/gemini-live-2.5", setup.s("model"))
        assertEquals("AUDIO", setup.o("generationConfig")["responseModalities"]!!.jsonArray[0].jsonPrimitive.content)
        assertEquals("Puck", setup.o("generationConfig").o("speechConfig").o("voiceConfig").o("prebuiltVoiceConfig").s("voiceName"))
        assertEquals("You are Moss.", setup.o("systemInstruction")["parts"]!!.jsonArray[0].jsonObject.s("text"))
        assertEquals("ask_companion", setup["tools"]!!.jsonArray[0].jsonObject["functionDeclarations"]!!.jsonArray[0].jsonObject.s("name"))
        assertTrue(setup.containsKey("inputAudioTranscription") && setup.containsKey("outputAudioTranscription"))
        assertEquals("models/x", obj(GeminiLive().setup(session("gemini", "gemini_live", model = "models/x")).single()).o("setup").s("model"))

        val audio = obj(proto.audio(byteArrayOf(0, 1))).o("realtimeInput").o("audio")
        assertEquals("audio/pcm;rate=16000", audio.s("mimeType"))
        assertEquals(listOf(LiveEvent.Ready), proto.parse("""{"setupComplete":{}}"""))
        val b64 = Base64.getEncoder().encodeToString(byteArrayOf(5, 6))
        val events = proto.parse("""{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"$b64"}}]},
            "outputTranscription":{"text":"On it"},"turnComplete":true}}""")
        assertTrue(events[0] is LiveEvent.AssistantText)
        assertTrue(events[1] is LiveEvent.Audio)
        assertEquals(LiveEvent.TurnDone, events.last())
        assertEquals(listOf(LiveEvent.Interrupted), proto.parse("""{"serverContent":{"interrupted":true}}"""))
        assertEquals(listOf(LiveEvent.GoAway), proto.parse("""{"goAway":{"timeLeft":"5s"}}"""))
        val call = proto.parse("""{"toolCall":{"functionCalls":[{"id":"f1","name":"decide_approval","args":{"chat":"Fix CI","approve":true}}]}}""").single() as LiveEvent.ToolCall
        assertEquals("f1", call.callId)
        assertEquals(true, call.arguments["approve"]!!.jsonPrimitive.boolean)
        val response = obj(proto.toolResult("f1", "decide_approval", buildJsonObject { put("ok", true) }).single())
            .o("toolResponse")["functionResponses"]!!.jsonArray[0].jsonObject
        assertEquals("f1", response.s("id"))
        assertEquals("decide_approval", response.s("name"))
        assertTrue(response.o("response")["ok"]!!.jsonPrimitive.boolean)
        val inject = obj(proto.inject("companion_update: hi").single()).o("clientContent")
        assertTrue(inject["turnComplete"]!!.jsonPrimitive.boolean)
        assertEquals("companion_update: hi", inject["turns"]!!.jsonArray[0].jsonObject["parts"]!!.jsonArray[0].jsonObject.s("text"))
        assertNull(liveProtocol(session("x", "sip")))
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

    @Test fun statusAndCompanionUpdateText() {
        val crew = listOf(CompanionLink(link_id = "l", workspace_id = "x", local_thread_id = "t", title = "Fix CI", status = "running"))
        val status = companionStatusJson(crew, listOf(pane("Deploy", "d")), { if (it == "w") "verde" else null })
        assertEquals("Running", status["crew"]!!.jsonArray[0].jsonObject.s("status"))
        val need = status["needs_you"]!!.jsonArray[0].jsonObject
        assertEquals("verde", need.s("workspace"))
        assertEquals("Needs approval", need.s("reason"))
        assertEquals("companion_update: Done. Tests pass.", companionUpdate("**Done.**\n```\nlog\n```\n- Tests pass"))
        val long = companionUpdate("word ".repeat(400))
        assertTrue(long.length <= "companion_update: ".length + COMPANION_UPDATE_CHARS)
        assertTrue(long.endsWith("…"))
    }

    // ---- Audio and captions ----

    @Test fun pcmHelpers() {
        assertEquals(640, pcmChunkBytes(16_000, 20))
        assertEquals(1920, pcmChunkBytes(24_000, 40))
        assertEquals(0f, pcmLevel(ByteArray(64)))
        val loud = ByteArray(64) { if (it % 2 == 0) 0x00 else 0x40 } // 0x4000 = 16384
        assertTrue(pcmLevel(loud) > .9f)
        val pcm = ByteArray(48 * 2) { 0 }
        assertEquals(32 * 2, resamplePcm16(pcm, 24_000, 16_000).size)
        assertEquals(48 * 2 * 3, resamplePcm16(pcm, 16_000, 48_000).size)
        assertSame(pcm, resamplePcm16(pcm, 24_000, 24_000))
        // A ramp stays monotonic through resampling.
        val ramp = ByteArray(200).also { b -> for (i in 0 until 100) { b[2 * i] = (i * 100 and 0xFF).toByte(); b[2 * i + 1] = ((i * 100) shr 8).toByte() } }
        val down = resamplePcm16(ramp, 24_000, 16_000)
        val values = (0 until down.size / 2).map { (down[2 * it].toInt() and 0xFF) or (down[2 * it + 1].toInt() shl 8) }
        assertEquals(values.sorted(), values)
    }

    @Test fun captionsGrowOneAssistantLineAndCloseOnTurnOrBargeIn() {
        var c = liveCaptions(emptyList(), LiveEvent.UserText("what's running?"))
        c = liveCaptions(c, LiveEvent.AssistantText("Two "))
        c = liveCaptions(c, LiveEvent.AssistantText("chats."))
        assertEquals(listOf(LiveCaption(true, "what's running?"), LiveCaption(false, "Two chats.", open = true)), c)
        c = liveCaptions(c, LiveEvent.TurnDone)
        c = liveCaptions(c, LiveEvent.AssistantText("Next"))
        assertEquals(3, c.size)
        c = liveCaptions(c, LiveEvent.Interrupted)
        assertFalse(c.last().open)
        repeat(20) { c = liveCaptions(c, LiveEvent.UserText("u$it")) }
        assertEquals(LIVE_CAPTIONS, c.size)
        assertEquals("Add an API key for live voice in companion settings.", liveError("voice_not_configured"))
    }

    // ---- Saved transcript ----

    private fun record() = LiveTranscript(sessionId = "s1", assistantAuthor = liveAssistantAuthor("Moss"))

    @Test fun transcriptMergesStreamingIntoOneLinePerUtteranceAndReply() {
        val t = record()
        t.header("Live voice", 0)
        t.userPartial("check", cumulative = true, now = 1)
        t.userPartial("check the CI", cumulative = true, now = 2)
        t.userFinal("Check the CI.", now = 3)
        t.assistantDelta("On ", 4)
        t.assistantDelta("it.", 5)
        assertEquals(listOf("0", "1"), t.pending(final = false).map { it.key })
        t.system("\u2192 Asked Moss: check CI", 6)
        t.assistantDone()
        t.userPartial("and ", cumulative = false, now = 7)
        t.userPartial("deploy", cumulative = false, now = 8)
        val lines = t.pending(final = false)
        assertEquals(listOf("Live voice", "Check the CI.", "On it.", "\u2192 Asked Moss: check CI"), lines.map { it.body })
        assertEquals(listOf("system", "user", "assistant", "system"), lines.map { it.role })
        assertEquals(listOf(LIVE_SYSTEM_AUTHOR, LIVE_USER_AUTHOR, "Moss (voice)", LIVE_SYSTEM_AUTHOR), lines.map { it.author })
        // Saved lines are never sent again; the open utterance follows once it ends.
        t.markSaved(lines.size)
        assertTrue(t.pending(final = false).isEmpty())
        assertEquals(listOf("and deploy"), t.pending(final = true).map { it.body })
        assertTrue(isVoiceAuthor("Moss (voice)") && isVoiceAuthor("Live") && !isVoiceAuthor("Moss"))
    }

    @Test fun lateFinalTranscriptReplacesTheStreamedLineAndEmptySessionsSaveNothing() {
        val t = record()
        t.header("Live voice", 0)
        t.system("\u2713 Approved Fix CI", 1)
        assertTrue(t.pending(final = true).isEmpty())
        t.userPartial("deploy stag", cumulative = false, now = 2)
        t.assistantDelta("Deploying.", 3)
        t.userFinal("Deploy staging.", now = 4)
        t.turnDone()
        assertEquals(listOf("Live voice", "\u2713 Approved Fix CI", "Deploy staging.", "Deploying."), t.pending(final = false).map { it.body })
        val blank = listOf(LiveLine("9", "user", LIVE_USER_AUTHOR, "  ", 1, open = false), LiveLine("10", "assistant", "Moss (voice)", "Hi", 2, open = false))
        val wire = transcriptMessages(blank)
        assertEquals(listOf("10"), wire.map { it.key })
        assertEquals(2L, wire.single().created_at_ms)
        assertEquals(listOf(200, 200, 50), saveBatches(List(450) { LiveLine("$it", "user", "", "x", 0, false) }).map { it.size })
    }

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
            "user" to alright,
            "user" to "Okay so here's a bug. It repeats what you say two times.", "assistant" to "Got it.",
        ), saved.map { it.role to it.body })
        // Captions show the same merged lines.
        assertEquals("Okay so here's a bug. It repeats what you say two times.", t.captions().first { it.user && it.text.startsWith("Okay") }.text)
        assertEquals(1, t.captions(20).count { it.text == "Like a" })
    }

    @Test fun periodicSavesNeverIncludeAnUtteranceStillBeingSpoken() {
        val t = record()
        t.feed(upd("a", "Check the build"), 0)
        t.feed(done("a", "Check the build."), 1)
        t.feed(upd("b", "and then"), 2)
        t.feed(upd("b", "and then deploy"), 3)
        assertEquals(listOf("Check the build."), t.pending(final = false).map { it.body })
        // A pause closes the line, but it isn't final until the transcript or a reply confirms it.
        t.tick(3 + USER_LINE_IDLE_MS)
        assertEquals(listOf("Check the build."), t.pending(final = false).map { it.body })
        t.feed(LiveEvent.ResponseStarted, 5_000)
        assertEquals(listOf("Check the build.", "and then deploy"), t.pending(final = false).map { it.body })
    }

    @Test fun speechNormalizationAndRemainders() {
        assertEquals("alright okay lets get back to work thanks", normalizeSpeech("Alright, okay.  Let's get back to work. Thanks."))
        assertTrue(extendsSpeech("like a dog", "like a"))
        assertFalse(extendsSpeech("like apples", "like a"))
        assertTrue(extendsSpeech("like a", "like a"))
        val prefix = normalizeSpeech("Alright, okay. Let's get back to work. Thanks.")
        assertEquals("Okay so here's a bug.", speechRemainder("Alright, okay. Let's get back to work, thanks. Okay so here's a bug.", prefix.length))
        assertEquals("", speechRemainder("Alright, okay. Let's get back to work. Thanks.", prefix.length))
        assertEquals("Hello", speechRemainder(" Hello ", 0))
        // OpenAI: deltas append; the final transcript replaces.
        val t = record()
        t.feed(LiveEvent.UserPartial("deploy ", cumulative = false, itemId = "x"), 0)
        t.feed(LiveEvent.UserPartial("stag", cumulative = false, itemId = "x"), 1)
        t.feed(LiveEvent.UserText("Deploy staging.", itemId = "x"), 2)
        assertEquals(listOf("Deploy staging."), t.pending(final = false).map { it.body })
    }
}

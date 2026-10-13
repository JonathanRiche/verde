package dev.verdeai.app

import dev.verdeai.core.CompanionLink
import dev.verdeai.core.Pane
import dev.verdeai.core.VoiceSession
import dev.verdeai.core.VoiceTool
import kotlinx.serialization.json.*
import java.util.Base64

/*
 * Real-time voice wire formats (pure, unit tested). Two provider protocols speak the same live
 * conversation: `openai_realtime` (xAI Grok Voice and OpenAI Realtime) and `gemini_live` (Google
 * Gemini Live). Tokens, audio and transcripts are never logged.
 */

/** What a provider told us, normalized across protocols. */
internal sealed interface LiveEvent {
    /** The session is configured and accepts audio. */
    data object Ready : LiveEvent
    /** PCM16 mono at [LiveProtocol.outputRate]. */
    class Audio(val pcm: ByteArray) : LiveEvent
    data class AssistantText(val delta: String) : LiveEvent
    /** The user's finished utterance. */
    data class UserText(val text: String, val itemId: String? = null) : LiveEvent
    /** The user's utterance so far: [cumulative] replaces the open line (xAI), otherwise it appends (deltas). */
    data class UserPartial(val text: String, val cumulative: Boolean, val itemId: String? = null) : LiveEvent
    /** The model began a response: whatever the user was saying is over. */
    data object ResponseStarted : LiveEvent
    /** The user started talking: stop playback now (barge-in). */
    data object Interrupted : LiveEvent
    data object TurnDone : LiveEvent
    data class ToolCall(val callId: String, val name: String, val arguments: JsonObject) : LiveEvent
    /** The server is about to close; reconnect with a fresh session. */
    data object GoAway : LiveEvent
    data class Failure(val code: String) : LiveEvent
    data class Ignored(val type: String) : LiveEvent
}

internal interface LiveProtocol {
    val inputRate: Int
    val outputRate: Int
    /** Messages to send right after the socket opens. */
    fun setup(session: VoiceSession): List<String>
    /** True when [setup] alone makes the session ready (no handshake reply to wait for). */
    val readyOnOpen: Boolean
    fun audio(pcm: ByteArray): String
    fun parse(text: String): List<LiveEvent>
    fun toolResult(callId: String, name: String, output: JsonObject): List<String>
    /** A text message from the user side (e.g. a companion update) that asks for a spoken answer. */
    fun inject(text: String): List<String>
}

internal fun liveProtocol(session: VoiceSession): LiveProtocol? = when (session.protocol) {
    "openai_realtime" -> OpenAiRealtime(ga = session.provider == "openai")
    "gemini_live" -> GeminiLive()
    else -> null
}

/** The tool's JSON schema; a malformed one degrades to an empty object schema. */
internal fun toolSchema(tool: VoiceTool): JsonObject = try {
    Json.parseToJsonElement(tool.parameters) as? JsonObject
} catch (_: Exception) { null } ?: buildJsonObject { put("type", "object"); putJsonObject("properties") {} }

private fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
private fun unb64(text: String): ByteArray? = try { Base64.getDecoder().decode(text) } catch (_: IllegalArgumentException) { null }
private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.obj(name: String): JsonObject? = this[name] as? JsonObject
private fun parseObject(text: String): JsonObject? = try { Json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null }

/** Function arguments arrive as a JSON string; anything unreadable is an empty object. */
internal fun toolArguments(raw: String?): JsonObject = raw?.let(::parseObject) ?: JsonObject(emptyMap())

/**
 * OpenAI Realtime protocol. OpenAI uses the GA session shape; xAI Grok Voice the classic beta
 * shape. Both stream PCM16 mono at 24 kHz.
 */
internal class OpenAiRealtime(private val ga: Boolean) : LiveProtocol {
    override val inputRate = 24_000
    override val outputRate = 24_000
    override val readyOnOpen = true

    override fun setup(session: VoiceSession): List<String> {
        val tools = buildJsonArray {
            session.tools.forEach { tool ->
                addJsonObject {
                    put("type", "function"); put("name", tool.name); put("description", tool.description); put("parameters", toolSchema(tool))
                }
            }
        }
        val update = buildJsonObject {
            put("type", "session.update")
            putJsonObject("session") {
                if (ga) {
                    put("type", "realtime")
                    put("instructions", session.instructions)
                    putJsonObject("audio") {
                        putJsonObject("input") {
                            putJsonObject("format") { put("type", "audio/pcm"); put("rate", inputRate) }
                            putJsonObject("turn_detection") { put("type", "server_vad") }
                            putJsonObject("transcription") { put("model", "gpt-4o-mini-transcribe") }
                        }
                        putJsonObject("output") {
                            putJsonObject("format") { put("type", "audio/pcm"); put("rate", outputRate) }
                            put("voice", session.voice)
                        }
                    }
                } else {
                    put("instructions", session.instructions)
                    put("voice", session.voice)
                    put("input_audio_format", "pcm16")
                    put("output_audio_format", "pcm16")
                    putJsonObject("turn_detection") { put("type", "server_vad") }
                    // xAI: the user's words come back as cumulative `input_audio_transcription.updated` events.
                    putJsonObject("audio") { putJsonObject("input") { putJsonObject("transcription") { put("model", "grok-transcribe") } } }
                }
                put("tools", tools)
            }
        }
        return listOf(update.toString())
    }

    override fun audio(pcm: ByteArray): String =
        buildJsonObject { put("type", "input_audio_buffer.append"); put("audio", b64(pcm)) }.toString()

    override fun parse(text: String): List<LiveEvent> {
        val message = parseObject(text) ?: return listOf(LiveEvent.Ignored("unreadable"))
        val type = message["type"].str().orEmpty()
        return listOf(when (type) {
            "response.output_audio.delta", "response.audio.delta" ->
                message["delta"].str()?.let(::unb64)?.let { LiveEvent.Audio(it) } ?: LiveEvent.Ignored(type)
            "response.output_audio_transcript.delta", "response.audio_transcript.delta" -> LiveEvent.AssistantText(message["delta"].str().orEmpty())
            "conversation.item.input_audio_transcription.completed" -> LiveEvent.UserText(message["transcript"].str().orEmpty(), message["item_id"].str())
            "conversation.item.input_audio_transcription.updated" ->
                LiveEvent.UserPartial((message["transcript"] ?: message["text"]).str().orEmpty(), cumulative = true, itemId = message["item_id"].str())
            "conversation.item.input_audio_transcription.delta" ->
                LiveEvent.UserPartial(message["delta"].str().orEmpty(), cumulative = false, itemId = message["item_id"].str())
            "response.created" -> LiveEvent.ResponseStarted
            "input_audio_buffer.speech_started" -> LiveEvent.Interrupted
            "response.done" -> LiveEvent.TurnDone
            "response.function_call_arguments.done" -> LiveEvent.ToolCall(message["call_id"].str().orEmpty(),
                message["name"].str().orEmpty(), toolArguments(message["arguments"].str()))
            "session.created", "session.updated" -> LiveEvent.Ready
            "error" -> LiveEvent.Failure(message.obj("error")?.get("code").str() ?: message.obj("error")?.get("type").str() ?: "provider_error")
            else -> LiveEvent.Ignored(type)
        })
    }

    override fun toolResult(callId: String, name: String, output: JsonObject): List<String> = listOf(
        buildJsonObject {
            put("type", "conversation.item.create")
            putJsonObject("item") { put("type", "function_call_output"); put("call_id", callId); put("output", output.toString()) }
        }.toString(),
        RESPONSE_CREATE,
    )

    override fun inject(text: String): List<String> = listOf(
        buildJsonObject {
            put("type", "conversation.item.create")
            putJsonObject("item") {
                put("type", "message"); put("role", "user")
                putJsonArray("content") { addJsonObject { put("type", "input_text"); put("text", text) } }
            }
        }.toString(),
        RESPONSE_CREATE,
    )

    companion object { private val RESPONSE_CREATE = buildJsonObject { put("type", "response.create") }.toString() }
}

/** Google Gemini Live: 16 kHz PCM in, 24 kHz PCM out; ready after `setupComplete`. */
internal class GeminiLive : LiveProtocol {
    override val inputRate = 16_000
    override val outputRate = 24_000
    override val readyOnOpen = false

    override fun setup(session: VoiceSession): List<String> {
        val model = if (session.model.startsWith("models/")) session.model else "models/${session.model}"
        return listOf(buildJsonObject {
            putJsonObject("setup") {
                put("model", model)
                putJsonObject("generationConfig") {
                    putJsonArray("responseModalities") { add("AUDIO") }
                    putJsonObject("speechConfig") { putJsonObject("voiceConfig") { putJsonObject("prebuiltVoiceConfig") { put("voiceName", session.voice) } } }
                }
                putJsonObject("systemInstruction") { putJsonArray("parts") { addJsonObject { put("text", session.instructions) } } }
                putJsonArray("tools") {
                    addJsonObject {
                        putJsonArray("functionDeclarations") {
                            session.tools.forEach { tool ->
                                addJsonObject { put("name", tool.name); put("description", tool.description); put("parameters", toolSchema(tool)) }
                            }
                        }
                    }
                }
                putJsonObject("inputAudioTranscription") {}
                putJsonObject("outputAudioTranscription") {}
            }
        }.toString())
    }

    override fun audio(pcm: ByteArray): String = buildJsonObject {
        putJsonObject("realtimeInput") { putJsonObject("audio") { put("data", b64(pcm)); put("mimeType", "audio/pcm;rate=$inputRate") } }
    }.toString()

    override fun parse(text: String): List<LiveEvent> {
        val message = parseObject(text) ?: return listOf(LiveEvent.Ignored("unreadable"))
        val out = ArrayList<LiveEvent>()
        if (message.containsKey("setupComplete")) out += LiveEvent.Ready
        message.obj("serverContent")?.let { content ->
            if ((content["interrupted"] as? JsonPrimitive)?.booleanOrNull == true) out += LiveEvent.Interrupted
            // Gemini streams the user's words in pieces; the line closes when the model answers.
            content.obj("inputTranscription")?.get("text").str()?.takeIf { it.isNotEmpty() }?.let { out += LiveEvent.UserPartial(it, cumulative = false) }
            content.obj("outputTranscription")?.get("text").str()?.let { out += LiveEvent.AssistantText(it) }
            (content.obj("modelTurn")?.get("parts") as? JsonArray)?.forEach { part ->
                (part as? JsonObject)?.obj("inlineData")?.get("data").str()?.let(::unb64)?.let { out += LiveEvent.Audio(it) }
            }
            if ((content["turnComplete"] as? JsonPrimitive)?.booleanOrNull == true) out += LiveEvent.TurnDone
        }
        (message.obj("toolCall")?.get("functionCalls") as? JsonArray)?.forEach { call ->
            val fn = call as? JsonObject ?: return@forEach
            out += LiveEvent.ToolCall(fn["id"].str().orEmpty(), fn["name"].str().orEmpty(), fn.obj("args") ?: JsonObject(emptyMap()))
        }
        if (message.containsKey("goAway")) out += LiveEvent.GoAway
        message.obj("error")?.let { out += LiveEvent.Failure(it["status"].str() ?: "provider_error") }
        return out.ifEmpty { listOf(LiveEvent.Ignored(message.keys.firstOrNull().orEmpty())) }
    }

    override fun toolResult(callId: String, name: String, output: JsonObject): List<String> = listOf(buildJsonObject {
        putJsonObject("toolResponse") {
            putJsonArray("functionResponses") { addJsonObject { put("id", callId); put("name", name); put("response", output) } }
        }
    }.toString())

    override fun inject(text: String): List<String> = listOf(buildJsonObject {
        putJsonObject("clientContent") {
            putJsonArray("turns") { addJsonObject { put("role", "user"); putJsonArray("parts") { addJsonObject { put("text", text) } } } }
            put("turnComplete", true)
        }
    }.toString())
}

// ---- PCM helpers ----

/** Bytes of PCM16 mono for [ms] milliseconds at [rate]. */
internal fun pcmChunkBytes(rate: Int, ms: Int): Int = rate / 1000 * ms * 2

/** 0..1 loudness of a PCM16 little-endian buffer (RMS, scaled so speech sits mid-range). */
internal fun pcmLevel(pcm: ByteArray, length: Int = pcm.size): Float {
    val samples = length / 2
    if (samples == 0) return 0f
    var sum = 0.0
    for (i in 0 until samples) {
        val sample = (pcm[2 * i].toInt() and 0xFF) or (pcm[2 * i + 1].toInt() shl 8)
        sum += sample.toDouble() * sample
    }
    val rms = kotlin.math.sqrt(sum / samples) / 32768.0
    return (rms * 4).coerceIn(0.0, 1.0).toFloat()
}

/** Linear resampling of PCM16 mono little-endian between rates (e.g. 48 kHz capture → 24 kHz). */
internal fun resamplePcm16(pcm: ByteArray, from: Int, to: Int): ByteArray {
    if (from == to || pcm.size < 2) return pcm
    val input = pcm.size / 2
    val output = ((input.toLong() * to) / from).toInt()
    val out = ByteArray(output * 2)
    fun sample(i: Int): Int { val k = i.coerceIn(0, input - 1); return (pcm[2 * k].toInt() and 0xFF) or (pcm[2 * k + 1].toInt() shl 8) }
    for (j in 0 until output) {
        val position = j.toDouble() * from / to
        val i = position.toInt()
        val fraction = position - i
        val value = (sample(i) * (1 - fraction) + sample(i + 1) * fraction).toInt().coerceIn(-32768, 32767)
        out[2 * j] = (value and 0xFF).toByte()
        out[2 * j + 1] = ((value shr 8) and 0xFF).toByte()
    }
    return out
}

// ---- Tools (pure parts) ----

internal const val COMPANION_UPDATE_CHARS = 600

/** The text injected into the live session when the companion's turn finishes. */
internal fun companionUpdate(reply: String): String {
    val plain = speechText(reply).ifBlank { reply.trim() }
    val clipped = if (plain.length <= COMPANION_UPDATE_CHARS) plain else plain.substring(0, COMPANION_UPDATE_CHARS - 1).trimEnd() + "…"
    return "companion_update: $clipped"
}

/** A chat with a pending approval the live voice may decide. */
internal data class ApprovalCandidate(val workspaceId: String, val threadId: String, val title: String)

internal sealed interface ApprovalMatch {
    data class Found(val candidate: ApprovalCandidate) : ApprovalMatch
    data object NotFound : ApprovalMatch
    data object Ambiguous : ApprovalMatch
}

/** Exact id or title (case-insensitive) first, else a unique partial title match. */
internal fun matchApproval(query: String, candidates: List<ApprovalCandidate>): ApprovalMatch {
    val q = query.trim().lowercase()
    if (q.isEmpty()) return ApprovalMatch.NotFound
    val unique = candidates.distinctBy { it.workspaceId to it.threadId }
    fun pick(list: List<ApprovalCandidate>): ApprovalMatch? = when (list.size) { 0 -> null; 1 -> ApprovalMatch.Found(list.single()); else -> ApprovalMatch.Ambiguous }
    return pick(unique.filter { it.threadId.lowercase() == q || it.title.trim().lowercase() == q })
        ?: pick(unique.filter { it.title.lowercase().contains(q) })
        ?: ApprovalMatch.NotFound
}

/** Chats waiting for an approval: Home attention panes plus crew links waiting for approval. */
internal fun approvalCandidates(needs: List<Pane>, crew: List<CompanionLink>): List<ApprovalCandidate> =
    needs.filter { it.status == "waiting_approval" || it.attention_kind == "needs_approval" }
        .mapNotNull { pane -> pane.thread_id?.let { ApprovalCandidate(pane.workspace_id, it, pane.title) } } +
        crew.filter { crewStatus(it) == ChildStatus.WaitingApproval }
            .map { ApprovalCandidate(it.workspace_id, it.local_thread_id, childTitle(it.local_thread_id, it.title)) }

/** `companion_status` result: crew and what needs the user, by title and workspace label. */
internal fun companionStatusJson(crew: List<CompanionLink>, needs: List<Pane>, workspaceLabel: (String) -> String?): JsonObject = buildJsonObject {
    putJsonArray("crew") {
        crew.forEach { link ->
            addJsonObject {
                put("title", childTitle(link.local_thread_id, link.title))
                put("status", crewStatus(link).label)
                workspaceLabel(link.workspace_id)?.let { put("workspace", it) }
            }
        }
    }
    putJsonArray("needs_you") {
        needs.forEach { pane ->
            addJsonObject {
                put("title", pane.title.ifBlank { "Chat" })
                put("workspace", workspaceLabel(pane.workspace_id) ?: pane.workspace_id)
                put("reason", attentionLabel(pane.attention_kind) ?: statusLabel(pane.status))
            }
        }
    }
}

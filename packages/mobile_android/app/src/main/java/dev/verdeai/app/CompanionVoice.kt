package dev.verdeai.app

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.view.accessibility.AccessibilityManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.verdeai.core.ChatRow
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.Locale

/*
 * Companion voice, phase 1: on-device speech-to-text for what the user says (sent as an ordinary
 * chat turn with `voice = true`, so the agent answers briefly) and text-to-speech for the reply,
 * sentence by sentence as it streams. No audio is recorded or stored by Verde; transcripts and
 * replies are never logged.
 */

// ---- Read-aloud policy (pure, unit tested) ----

internal enum class ReadAloud(val id: String, val label: String) {
    Always("always", "Always"),
    AfterSpeech("after_speech", "Only after I speak"),
    Never("never", "Never");

    companion object { fun of(id: String?): ReadAloud? = entries.firstOrNull { it.id == id } }
}

/** The saved choice, else "only after I speak" — but never auto-speak over TalkBack by default. */
internal fun effectiveReadAloud(saved: ReadAloud?, talkBack: Boolean): ReadAloud = saved ?: if (talkBack) ReadAloud.Never else ReadAloud.AfterSpeech

/** Whether a reply is read aloud. Do-not-disturb silences replies the user didn't ask for by voice. */
internal fun shouldReadReply(policy: ReadAloud, voiceTurn: Boolean, doNotDisturb: Boolean = false): Boolean = when (policy) {
    ReadAloud.Always -> voiceTurn || !doNotDisturb
    ReadAloud.AfterSpeech -> voiceTurn
    ReadAloud.Never -> false
}

// ---- Markdown → speech (pure, unit tested) ----

private val FENCE = Regex("^(```|~~~)")
private val RULE = Regex("^([-*_]\\s*){3,}$")
private val HEADING = Regex("^#{1,6}\\s+")
private val QUOTE = Regex("^(>\\s?)+")
private val LIST_MARKER = Regex("^([-*+]|\\d{1,3}[.)])\\s+")
private val TASK_MARKER = Regex("^\\[[ xX]]\\s+")
private val IMAGE = Regex("!\\[([^\\]]*)]\\([^)]*\\)")
private val LINK = Regex("\\[([^\\]]+)]\\([^)]*\\)")
private val URL = Regex("(https?://|www\\.)\\S+")
private val INLINE_CODE = Regex("`([^`]*)`")
private val EMPHASIS = Regex("\\*\\*|__|~~|\\*")
private val SPACES = Regex("\\s+")
private val SENTENCE_BREAK = Regex("(?<=[.!?])\\s+")
private val SENTENCE_END = Regex("[.!?][\"')\\]]*\\s")

/**
 * Plain spoken text for a markdown reply: code blocks and tables are skipped (an unclosed fence
 * hides the rest), links keep their words, bare URLs become "a link", markup is dropped, and each
 * line becomes its own sentence.
 */
internal fun speechText(markdown: String): String {
    val out = ArrayList<String>()
    var fence = false
    for (raw in markdown.lines()) {
        val line = raw.trim()
        if (FENCE.containsMatchIn(line)) { fence = !fence; continue }
        if (fence || line.startsWith("|") || RULE.matches(line)) continue
        var text = HEADING.replaceFirst(line, "")
        text = QUOTE.replaceFirst(text, "")
        text = LIST_MARKER.replaceFirst(text, "")
        text = TASK_MARKER.replaceFirst(text, "")
        text = IMAGE.replace(text, "")
        text = LINK.replace(text) { match -> if (URL.matches(match.groupValues[1])) "a link" else match.groupValues[1] }
        text = URL.replace(text, "a link")
        text = INLINE_CODE.replace(text, "$1")
        text = EMPHASIS.replace(text, "")
        text = SPACES.replace(text, " ").trim()
        if (text.none { it.isLetterOrDigit() }) continue
        if (text.last() !in ".!?:;,") text += "."
        out += text
    }
    return out.joinToString(" ")
}

internal fun splitSentences(text: String): List<String> =
    text.split(SENTENCE_BREAK).map { it.trim() }.filter { s -> s.any { it.isLetterOrDigit() } }

/** Where a still-streaming reply can be cut without splitting a sentence or a line. */
internal fun speakableEnd(body: String): Int {
    val line = body.lastIndexOf('\n') + 1
    val sentence = SENTENCE_END.findAll(body).lastOrNull()?.let { it.range.last } ?: 0
    return maxOf(line, sentence)
}

/** The reply's complete sentences so far (all of them once [final]). Prefix-stable while streaming. */
internal fun speakableSentences(body: String, final: Boolean): List<String> =
    splitSentences(speechText(if (final) body else body.substring(0, speakableEnd(body))))

/**
 * Follows one reply while it streams and hands out each sentence once. Armed when the user sends
 * by voice (or, with "Always", when a turn starts); rows present when armed are never spoken.
 */
internal class ReplyTracker(private val armTimeoutMs: Long = ARM_TIMEOUT_MS) {
    private var baseline: Set<String> = emptySet()
    private val spoken = HashMap<String, Int>()
    private var sawTurn = false
    private var armedAt = 0L
    var armed = false
        private set
    var voiceTurn = false
        private set

    fun arm(rows: List<ChatRow>, voice: Boolean, nowMs: Long) {
        baseline = rows.map { it.id }.toSet()
        spoken.clear()
        sawTurn = false
        armedAt = nowMs
        armed = true
        voiceTurn = voice
    }

    /** Arms on a turn that has already started: its own assistant rows (after the last user row) count. */
    fun armAtTurn(rows: List<ChatRow>, nowMs: Long) {
        val lastUser = rows.indexOfLast { it.role == "user" }
        arm(rows.subList(0, lastUser + 1), voice = false, nowMs = nowMs)
        sawTurn = true
    }

    fun disarm() { armed = false; spoken.clear() }

    fun next(rows: List<ChatRow>, turnActive: Boolean, nowMs: Long): List<String> {
        if (!armed) return emptyList()
        if (turnActive) sawTurn = true
        val out = ArrayList<String>()
        var replied = false
        for (row in rows) {
            if (row.id in baseline || row.role != "assistant" || row.kind != "message") continue
            replied = true
            val final = row.delivery != "streaming" || !turnActive
            val sentences = speakableSentences(row.body, final)
            val done = spoken[row.id] ?: 0
            if (sentences.size > done) {
                out += sentences.subList(done, sentences.size)
                spoken[row.id] = sentences.size
            }
        }
        if (!turnActive && (sawTurn || replied || nowMs - armedAt > armTimeoutMs)) armed = false
        return out
    }

    companion object { const val ARM_TIMEOUT_MS = 30_000L }
}

// ---- Hold-to-talk state machine (pure, unit tested) ----

internal sealed interface TalkState {
    data object Idle : TalkState
    /** Recording. [ended]: the recognizer already stopped (silence) and waits for the release. */
    data class Listening(val partial: String = "", val cancelArmed: Boolean = false, val ended: Boolean = false) : TalkState
    /** Released; waiting for the final transcript. */
    data class Finishing(val partial: String) : TalkState
}

internal sealed interface TalkEvent {
    data object Press : TalkEvent
    data class Move(val outside: Boolean) : TalkEvent
    data object Release : TalkEvent
    data object Cancel : TalkEvent
    data class Partial(val text: String) : TalkEvent
    data class Final(val text: String) : TalkEvent
    data class Error(val code: Int) : TalkEvent
}

internal sealed interface TalkEffect {
    data object Start : TalkEffect
    data object Stop : TalkEffect
    data object Abort : TalkEffect
    data class Send(val text: String) : TalkEffect
    data class Failed(val message: String) : TalkEffect
}

internal data class TalkStep(val state: TalkState, val effects: List<TalkEffect> = emptyList())

internal fun talkError(code: Int): String = when (code) {
    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Didn't catch that. Try again."
    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER,
    SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "Speech recognition needs a connection right now."
    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Allow microphone access to talk."
    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The microphone is busy. Try again."
    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Speech recognition isn't available for your language."
    else -> "Couldn't hear you. Try again."
}

/** One transition of hold-to-talk; the effects drive the recognizer and the send. */
internal fun talkStep(state: TalkState, event: TalkEvent): TalkStep = when (state) {
    TalkState.Idle -> if (event == TalkEvent.Press) TalkStep(TalkState.Listening(), listOf(TalkEffect.Start)) else TalkStep(state)
    is TalkState.Listening -> when (event) {
        TalkEvent.Press -> TalkStep(state)
        is TalkEvent.Move -> TalkStep(state.copy(cancelArmed = event.outside))
        is TalkEvent.Partial -> TalkStep(state.copy(partial = event.text.ifBlank { state.partial }))
        is TalkEvent.Final -> TalkStep(state.copy(partial = event.text.ifBlank { state.partial }, ended = true))
        TalkEvent.Cancel -> TalkStep(TalkState.Idle, listOf(TalkEffect.Abort))
        TalkEvent.Release -> when {
            state.cancelArmed -> TalkStep(TalkState.Idle, listOf(TalkEffect.Abort))
            state.ended -> TalkStep(TalkState.Idle, if (state.partial.isBlank()) listOf(TalkEffect.Failed(talkError(SpeechRecognizer.ERROR_NO_MATCH)))
                else listOf(TalkEffect.Send(state.partial.trim())))
            else -> TalkStep(TalkState.Finishing(state.partial), listOf(TalkEffect.Stop))
        }
        is TalkEvent.Error -> if (state.partial.isNotBlank()) TalkStep(state.copy(ended = true))
            else TalkStep(TalkState.Idle, listOf(TalkEffect.Abort, TalkEffect.Failed(talkError(event.code))))
    }
    is TalkState.Finishing -> when (event) {
        is TalkEvent.Partial -> TalkStep(state.copy(partial = event.text.ifBlank { state.partial }))
        is TalkEvent.Final -> {
            val text = event.text.ifBlank { state.partial }.trim()
            TalkStep(TalkState.Idle, if (text.isEmpty()) listOf(TalkEffect.Failed(talkError(SpeechRecognizer.ERROR_NO_MATCH))) else listOf(TalkEffect.Send(text)))
        }
        is TalkEvent.Error -> TalkStep(TalkState.Idle, if (state.partial.isBlank()) listOf(TalkEffect.Failed(talkError(event.code)))
            else listOf(TalkEffect.Send(state.partial.trim())))
        TalkEvent.Cancel -> TalkStep(TalkState.Idle, listOf(TalkEffect.Abort))
        else -> TalkStep(state)
    }
}

/** TalkBack label for the mic in each state. */
internal fun micLabel(state: TalkState, name: String): String = when (state) {
    TalkState.Idle -> "Talk to $name"
    is TalkState.Listening -> "Listening. Activate to stop and send"
    is TalkState.Finishing -> "Sending what you said"
}

// ---- Device preferences ----

internal class VoicePrefs private constructor(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("companion_voice", Context.MODE_PRIVATE)
    /** Null until the user picks one, so the TalkBack-aware default applies. */
    var readAloud by mutableStateOf(ReadAloud.of(preferences.getString("read_aloud", null)))
        private set
    var rate by mutableFloatStateOf(preferences.getFloat("rate", 1f).coerceIn(MIN_RATE, MAX_RATE))
        private set
    var voiceName by mutableStateOf(preferences.getString("voice", null))
        private set
    var preferOnDevice by mutableStateOf(preferences.getBoolean("prefer_on_device", true))
        private set

    fun chooseReadAloud(value: ReadAloud) { readAloud = value; preferences.edit().putString("read_aloud", value.id).apply() }
    fun chooseRate(value: Float) { rate = value.coerceIn(MIN_RATE, MAX_RATE); preferences.edit().putFloat("rate", rate).apply() }
    fun chooseVoice(name: String?) { voiceName = name; preferences.edit().putString("voice", name).apply() }
    fun choosePreferOnDevice(value: Boolean) { preferOnDevice = value; preferences.edit().putBoolean("prefer_on_device", value).apply() }

    companion object {
        const val MIN_RATE = .5f
        const val MAX_RATE = 2f
        @Volatile private var instance: VoicePrefs? = null
        fun of(context: Context): VoicePrefs = instance ?: synchronized(this) { instance ?: VoicePrefs(context).also { instance = it } }
    }
}

internal fun talkBackOn(context: Context): Boolean =
    context.getSystemService(AccessibilityManager::class.java)?.isTouchExplorationEnabled == true

private fun doNotDisturb(context: Context): Boolean {
    val filter = context.getSystemService(NotificationManager::class.java)?.currentInterruptionFilter ?: return false
    return filter != NotificationManager.INTERRUPTION_FILTER_ALL && filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
}

// ---- Microphone permission ----

internal class MicPermission(val granted: () -> Boolean, val request: () -> Unit)

/** RECORD_AUDIO with a short rationale first; the user retries the gesture once it is granted. */
@Composable
internal fun rememberMicPermission(): MicPermission {
    val context = LocalContext.current
    val rationale = remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    if (rationale.value) AlertDialog(onDismissRequest = { rationale.value = false },
        title = { Text("Talk to your companion") },
        text = { Text("Verde listens only while you hold the bubble or the mic. Your phone's speech service turns what you say into text (on the device when it can), and Verde sends that text as a message. Verde doesn't record or keep audio.") },
        confirmButton = { TextButton(onClick = { rationale.value = false; launcher.launch(Manifest.permission.RECORD_AUDIO) }) { Text("Continue") } },
        dismissButton = { TextButton(onClick = { rationale.value = false }) { Text("Not now") } })
    return remember(context, launcher) {
        MicPermission(granted = { ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED },
            request = { rationale.value = true })
    }
}

// ---- Speech-to-text ----

/** One `SpeechRecognizer` session at a time, on the main thread. */
internal class SpeechInput(private val context: Context, private val onEvent: (TalkEvent) -> Unit, private val onLevel: (Float) -> Unit) {
    private var recognizer: SpeechRecognizer? = null
    var onDevice = false
        private set

    fun start(preferOnDevice: Boolean) {
        release()
        onDevice = preferOnDevice && onDeviceAvailable(context)
        val created = try {
            if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            else SpeechRecognizer.createSpeechRecognizer(context)
        } catch (_: Exception) { null }
        if (created == null) { onEvent(TalkEvent.Error(SpeechRecognizer.ERROR_CLIENT)); return }
        recognizer = created
        created.setRecognitionListener(listener)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        if (preferOnDevice) intent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        try { created.startListening(intent) } catch (_: Exception) { onEvent(TalkEvent.Error(SpeechRecognizer.ERROR_CLIENT)) }
    }

    fun stop() { try { recognizer?.stopListening() } catch (_: Exception) { } }
    fun cancel() { try { recognizer?.cancel() } catch (_: Exception) { }; release() }
    fun release() { try { recognizer?.destroy() } catch (_: Exception) { }; recognizer = null }

    private fun first(results: Bundle?): String =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) { onLevel(((rmsdB + 2f) / 12f).coerceIn(0f, 1f)) }
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() { onLevel(0f) }
        override fun onError(error: Int) { onLevel(0f); onEvent(TalkEvent.Error(error)) }
        override fun onResults(results: Bundle?) { onLevel(0f); onEvent(TalkEvent.Final(first(results))) }
        override fun onPartialResults(partialResults: Bundle?) { first(partialResults).takeIf { it.isNotBlank() }?.let { onEvent(TalkEvent.Partial(it)) } }
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    companion object {
        fun onDeviceAvailable(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && try { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) } catch (_: Exception) { false }
        /** No recognizer at all hides the mic. */
        fun available(context: Context): Boolean =
            onDeviceAvailable(context) || try { SpeechRecognizer.isRecognitionAvailable(context) } catch (_: Exception) { false }
    }
}

// ---- Text-to-speech ----

/** Speaks queued sentences on the media stream with transient, duckable audio focus. */
internal class SpeechOutput(context: Context, private val onSpeaking: (Boolean) -> Unit) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val audio = app.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes)
        .setOnAudioFocusChangeListener({ change ->
            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stop()
        }, main).build()
    private val backlog = ArrayList<String>()
    private var ready = false
    private var failed = false
    private var pending = 0
    private var serial = 0
    private var rate = 1f
    private var voiceName: String? = null
    private lateinit var tts: TextToSpeech

    init {
        tts = TextToSpeech(app) { status ->
            main.post {
                ready = status == TextToSpeech.SUCCESS
                failed = !ready
                if (ready) {
                    tts.setAudioAttributes(attributes)
                    tts.setOnUtteranceProgressListener(progress)
                    val queued = backlog.toList()
                    backlog.clear()
                    queued.forEach(::speak)
                } else backlog.clear()
            }
        }
    }

    fun configure(rate: Float, voiceName: String?) { this.rate = rate; this.voiceName = voiceName }

    fun speak(text: String) {
        if (failed || text.isBlank()) return
        if (!ready) { backlog += text; return }
        if (pending == 0) {
            audio?.requestAudioFocus(focus)
            onSpeaking(true)
        }
        tts.setSpeechRate(rate)
        val chosen = voiceName?.let { name -> try { tts.voices?.firstOrNull { it.name == name } } catch (_: Exception) { null } }
        if (chosen != null && tts.voice?.name != chosen.name) tts.setVoice(chosen)
        pending++
        val params = Bundle().apply { putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC) }
        if (tts.speak(text, TextToSpeech.QUEUE_ADD, params, "verde-${serial++}") == TextToSpeech.ERROR) done()
    }

    fun stop() {
        backlog.clear()
        if (ready) try { tts.stop() } catch (_: Exception) { }
        if (pending > 0) { pending = 0; finish() }
    }

    /** Installed voices for the phone's language, for the settings picker. */
    fun voices(): List<Voice> = if (!ready) emptyList() else try {
        val language = Locale.getDefault().language
        tts.voices.orEmpty().filter { it.locale.language == language && !it.isNetworkConnectionRequired }.sortedBy { it.name }
    } catch (_: Exception) { emptyList() }

    fun shutdown() { stop(); try { tts.shutdown() } catch (_: Exception) { } }

    private fun done() {
        if (pending == 0) return
        pending--
        if (pending == 0) finish()
    }

    private fun finish() {
        audio?.abandonAudioFocusRequest(focus)
        onSpeaking(false)
    }

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}
        override fun onDone(utteranceId: String?) { main.post { done() } }
        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) { main.post { done() } }
        override fun onError(utteranceId: String?, errorCode: Int) { main.post { done() } }
    }
}

// ---- Controller ----

/**
 * The companion's voice for this app session: hold-to-talk (bubble or sheet mic) → transcript →
 * spoken turn, and the reply read aloud per the user's policy. Lives for the activity.
 */
internal class CompanionVoice(private val context: Context) : ViewModel() {
    val prefs = VoicePrefs.of(context)
    val available: Boolean = SpeechInput.available(context)
    private val mutableTalk = MutableStateFlow<TalkState>(TalkState.Idle)
    val talk = mutableTalk.asStateFlow()
    private val mutableLevel = MutableStateFlow(0f)
    val level = mutableLevel.asStateFlow()
    private val mutableError = MutableStateFlow<String?>(null)
    val error = mutableError.asStateFlow()
    private val mutableSpeaking = MutableStateFlow(false)
    val speaking = mutableSpeaking.asStateFlow()
    private val armed = MutableStateFlow(false)
    /** Listening, sending, or waiting on / reading a reply: the companion chat keeps its focus. */
    val active: StateFlow<Boolean> = combine(talk, speaking, armed) { t, s, a -> t !is TalkState.Idle || s || a }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)
    private val input = SpeechInput(context, ::onRecognizer) { mutableLevel.value = it }
    private var outputInstance: SpeechOutput? = null
    private val output: SpeechOutput get() = outputInstance ?: SpeechOutput(context) { mutableSpeaking.value = it }.also { outputInstance = it }
    private val tracker = ReplyTracker()
    private var target: TranscriptModel? = null
    /** Sheet mic: the draft before live partials were written into the composer. */
    private var draftBefore: String? = null
    private var watched: TranscriptModel? = null
    private var watchJob: Job? = null
    private var turnWasActive = false
    private var holding: TranscriptModel? = null
    private var borrowed: TranscriptModel? = null

    val policy: ReadAloud get() = effectiveReadAloud(prefs.readAloud, talkBackOn(context))
    /** Live voice is talking: replies are never read aloud on top of it. */
    var suppressed = false
        set(value) { field = value; if (value) stopSpeaking() }

    /** Starts listening for [model]'s chat. [liveDraft] writes partials into its composer (sheet mic). */
    fun press(model: TranscriptModel, liveDraft: Boolean) {
        stopSpeaking()
        mutableError.value = null
        target = model
        draftBefore = if (liveDraft) model.composer.field.text else null
        dispatch(TalkEvent.Press)
    }

    fun move(outside: Boolean) = dispatch(TalkEvent.Move(outside))
    fun release() = dispatch(TalkEvent.Release)
    fun cancel() = dispatch(TalkEvent.Cancel)
    fun toggle(model: TranscriptModel, liveDraft: Boolean) = if (talk.value is TalkState.Idle) press(model, liveDraft) else release()
    fun clearError() { mutableError.value = null }

    private fun onRecognizer(event: TalkEvent) {
        val state = talk.value
        // The on-device recognizer may lack this language: fall back once to the default service.
        if (event is TalkEvent.Error && input.onDevice && state is TalkState.Listening && state.partial.isBlank() &&
            (event.code == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED || event.code == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)) {
            input.start(preferOnDevice = false)
            return
        }
        dispatch(event)
    }

    private fun dispatch(event: TalkEvent) {
        val step = talkStep(talk.value, event)
        mutableTalk.value = step.state
        val model = target
        (step.state as? TalkState.Listening)?.partial?.let { partial -> livePartial(model, partial) }
        (step.state as? TalkState.Finishing)?.partial?.let { partial -> livePartial(model, partial) }
        for (effect in step.effects) when (effect) {
            TalkEffect.Start -> input.start(prefs.preferOnDevice)
            TalkEffect.Stop -> input.stop()
            TalkEffect.Abort -> {
                input.cancel()
                draftBefore?.let { before -> model?.composer?.restoreDraft(before) }
                draftBefore = null
                mutableLevel.value = 0f
            }
            is TalkEffect.Send -> {
                input.release()
                send(model, effect.text)
            }
            is TalkEffect.Failed -> {
                mutableError.value = effect.message
                draftBefore?.let { before -> model?.composer?.restoreDraft(before) }
                draftBefore = null
            }
        }
    }

    private fun livePartial(model: TranscriptModel?, partial: String) {
        val before = draftBefore ?: return
        if (model == null || partial.isBlank()) return
        val text = joinDraft(before, partial)
        model.composer.edit(TextFieldValue(text, TextRange(text.length)))
    }

    private fun send(model: TranscriptModel?, text: String) {
        if (model == null) return
        val before = draftBefore
        draftBefore = null
        model.composer.sendSpoken(if (before == null) text else joinDraft(before, text), replace = before != null)
        if (policy != ReadAloud.Never) {
            tracker.arm(model.state.value.thread?.rows.orEmpty(), voice = true, nowMs = System.currentTimeMillis())
            armed.value = true
        }
    }

    /** Follows the companion chat for replies to read aloud. */
    fun attach(model: TranscriptModel?) {
        if (watched === model) return
        watchJob?.cancel()
        watched = model
        tracker.disarm()
        armed.value = false
        turnWasActive = false
        if (model == null) return
        watchJob = viewModelScope.launch {
            model.state.collect { state ->
                val rows = state.thread?.rows.orEmpty()
                val turnActive = state.turn != null
                val now = System.currentTimeMillis()
                val current = policy
                if (current == ReadAloud.Always && !tracker.armed && turnActive && !turnWasActive) tracker.armAtTurn(rows, now)
                turnWasActive = turnActive
                val sentences = tracker.next(rows, turnActive, now)
                if (sentences.isNotEmpty() && !suppressed && shouldReadReply(current, tracker.voiceTurn, doNotDisturb(context))) {
                    output.configure(prefs.rate, prefs.voiceName)
                    sentences.forEach(output::speak)
                }
                armed.value = tracker.armed
            }
        }
    }

    /**
     * Keeps the companion chat focused while a voice exchange runs with the sheet closed, so the
     * reply streams in, then hands focus back to the chat screen it was borrowed from.
     */
    fun holdFocus(model: TranscriptModel?, active: Boolean, sheetOpen: Boolean) {
        if (model != null && active) {
            if (holding !== model) {
                borrowed = (FocusClaim.owner as? TranscriptModel)?.takeIf { it !== model }
                holding = model
            }
            model.setVisible(true)
        } else if (!active) {
            val held = holding ?: return
            holding = null
            if (!sheetOpen) held.setVisible(false)
            borrowed?.refocusIfVisible()
            borrowed = null
        }
    }

    /** Barge-in, the stop button, another chat, or leaving the app. */
    fun stopSpeaking() {
        outputInstance?.stop()
        tracker.disarm()
        armed.value = false
    }

    /** Verde left the foreground: stop listening and speaking. */
    fun pause() {
        if (talk.value !is TalkState.Idle) dispatch(TalkEvent.Cancel)
        stopSpeaking()
    }

    fun voices(): List<Voice> = output.voices()

    override fun onCleared() {
        input.release()
        outputInstance?.shutdown()
        watchJob?.cancel()
    }
}

internal fun joinDraft(before: String, words: String): String {
    val head = before.trimEnd()
    return if (head.isEmpty()) words.trim() else head + "\n\n" + words.trim()
}

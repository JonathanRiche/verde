package dev.verdeai.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/*
 * Live voice audio: the microphone (voice-communication source with echo cancellation) and a
 * streaming speaker. Audio is never written to disk or logged.
 */

/** Captures PCM16 mono in [chunkMs] slices on its own thread. */
internal class LiveMic(private val rate: Int, private val chunkMs: Int = 20, private val onChunk: (ByteArray, Float) -> Unit) {
    private val running = AtomicBoolean(false)
    @Volatile var muted = false
    private var thread: Thread? = null
    private var record: AudioRecord? = null
    private var echo: AcousticEchoCanceler? = null
    private var noise: NoiseSuppressor? = null

    /** False when the microphone could not be opened (permission revoked, in use, unsupported). */
    @SuppressLint("MissingPermission") // Callers check RECORD_AUDIO first.
    fun start(): Boolean {
        if (running.get()) return true
        val chunk = pcmChunkBytes(rate, chunkMs)
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val created = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(min, chunk * 4))
        } catch (_: Exception) { return false }
        if (created.state != AudioRecord.STATE_INITIALIZED) { created.release(); return false }
        record = created
        if (AcousticEchoCanceler.isAvailable()) echo = try { AcousticEchoCanceler.create(created.audioSessionId)?.also { it.setEnabled(true) } } catch (_: Exception) { null }
        if (NoiseSuppressor.isAvailable()) noise = try { NoiseSuppressor.create(created.audioSessionId)?.also { it.setEnabled(true) } } catch (_: Exception) { null }
        try { created.startRecording() } catch (_: Exception) { stop(); return false }
        running.set(true)
        thread = Thread({
            val buffer = ByteArray(chunk)
            while (running.get()) {
                var filled = 0
                while (filled < chunk && running.get()) {
                    val read = created.read(buffer, filled, chunk - filled)
                    if (read <= 0) break
                    filled += read
                }
                if (filled == chunk && !muted) onChunk(buffer.copyOf(), pcmLevel(buffer))
                else if (filled == 0) Thread.sleep(5)
            }
        }, "verde-live-mic").also { it.start() }
        return true
    }

    fun stop() {
        running.set(false)
        thread?.join(500)
        thread = null
        try { record?.stop() } catch (_: Exception) { }
        record?.release(); record = null
        echo?.release(); echo = null
        noise?.release(); noise = null
    }
}

/** Streams PCM16 mono at [rate]; [flush] drops queued audio at once (barge-in). */
internal class LiveSpeaker(private val rate: Int, private val onLevel: (Float) -> Unit) {
    private val queue = LinkedBlockingQueue<ByteArray>()
    private val running = AtomicBoolean(false)
    private var track: AudioTrack? = null
    private var thread: Thread? = null

    fun start(): Boolean {
        if (running.get()) return true
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val created = try {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(min * 4)
                .build()
        } catch (_: Exception) { return false }
        track = created
        try { created.play() } catch (_: Exception) { created.release(); track = null; return false }
        running.set(true)
        thread = Thread({
            while (running.get()) {
                val chunk = try { queue.poll(50, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { null }
                if (chunk == null) { onLevel(0f); continue }
                onLevel(pcmLevel(chunk))
                var offset = 0
                while (offset < chunk.size && running.get()) {
                    val wrote = created.write(chunk, offset, chunk.size - offset)
                    if (wrote <= 0) break
                    offset += wrote
                }
            }
        }, "verde-live-speaker").also { it.start() }
        return true
    }

    fun play(pcm: ByteArray) { if (running.get()) queue.offer(pcm) }

    /** Barge-in: drop everything queued and in the track's buffer. */
    fun flush() {
        queue.clear()
        val current = track ?: return
        try { current.pause(); current.flush(); current.play() } catch (_: Exception) { }
        onLevel(0f)
    }

    fun stop() {
        running.set(false)
        queue.clear()
        thread?.interrupt()
        thread?.join(500)
        thread = null
        try { track?.stop() } catch (_: Exception) { }
        track?.release(); track = null
        onLevel(0f)
    }
}

/**
 * Communication mode, routing and audio focus for a live conversation; [release] restores the
 * phone's audio exactly as it was.
 */
internal class LiveAudioRoute(context: Context) {
    private val audio = context.applicationContext.getSystemService(AudioManager::class.java)
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        .build()
    private var previousMode = AudioManager.MODE_NORMAL
    private var previousSpeaker = false
    private var active = false

    @Suppress("DEPRECATION")
    fun acquire() {
        val manager = audio ?: return
        if (active) return
        active = true
        manager.requestAudioFocus(focus)
        previousMode = manager.mode
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        // Communication audio defaults to the earpiece; use a headset if one is connected, else the speaker.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = manager.availableCommunicationDevices
            val headset = devices.firstOrNull { it.type in HEADSETS }
            val target = headset ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            if (target != null) manager.setCommunicationDevice(target)
        } else {
            previousSpeaker = manager.isSpeakerphoneOn
            val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            if (outputs.none { it.type in HEADSETS }) manager.isSpeakerphoneOn = true
        }
    }

    @Suppress("DEPRECATION")
    fun release() {
        val manager = audio ?: return
        if (!active) return
        active = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) manager.clearCommunicationDevice()
        else manager.isSpeakerphoneOn = previousSpeaker
        manager.mode = previousMode
        manager.abandonAudioFocusRequest(focus)
    }

    private companion object {
        val HEADSETS = setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLE_HEADSET)
    }
}

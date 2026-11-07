package dev.verdeai.core

import android.media.MediaDataSource
import java.io.IOException

/** Seekable authenticated byte ranges; at most 256 KiB is cached, never the whole recording. */
internal class RangeAudioSource(private val length: Long, private val fetch: (Long, Int) -> ByteArray) : MediaDataSource() {
    @Volatile private var closed = false
    var onClose: () -> Unit = {}
    private var start = -1L
    private var cache = ByteArray(0)
    override fun getSize() = length
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (closed) throw IOException("audio_closed")
        if (size == 0) return 0
        if (position >= length) return -1
        if (position < 0) throw IOException("audio_offset")
        if (position < start || position >= start + cache.size) {
            val next = fetch(position, minOf(256 * 1024L, length - position).toInt())
            if (closed) throw IOException("audio_closed")
            cache = next; start = position
        }
        val from = (position - start).toInt()
        val count = minOf(size, cache.size - from)
        cache.copyInto(buffer, offset, from, from + count)
        return count
    }
    override fun close() { closed = true; onClose() }
}

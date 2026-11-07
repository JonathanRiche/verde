package dev.verdeai.core

/** A fetched workspace file. Never logged or put in a crash report; streamed downloads own a private temporary file. */
class FileBody private constructor(private val memory: ByteArray?, val file: java.io.File?, val contentType: String?, val audioSource: android.media.MediaDataSource? = null) : java.io.Closeable {
    constructor(bytes: ByteArray, contentType: String?) : this(bytes, null, contentType)
    constructor(file: java.io.File, contentType: String?) : this(null, file, contentType)
    constructor(source: android.media.MediaDataSource, contentType: String?) : this(null, null, contentType, source)
    val size: Long get() = audioSource?.size ?: file?.length() ?: memory!!.size.toLong()
    // Only bounded previews use bytes. Downloads copy streams directly to the chosen document.
    val bytes: ByteArray get() { check(size <= 32L * 1024 * 1024); return memory ?: file!!.readBytes() }
    fun openStream(): java.io.InputStream = file?.inputStream() ?: memory!!.inputStream()
    override fun close() { audioSource?.close(); file?.delete() }
}

/**
 * D-12 in-memory hand-off between the effect executor and the file viewer, keyed by the
 * `file_open` intent ID. Bounded: a body the viewer never takes (screen left while loading) is
 * evicted by later fetches, and everything is dropped on sign-out or when the host closes.
 */
class FileSink(private val capacity: Int = 4) {
    private val ignored = LinkedHashSet<String>()
    private val bodies = LinkedHashMap<String, FileBody>()

    @Synchronized fun put(intentId: String, body: FileBody) {
        if (intentId in ignored) { body.close(); return }
        bodies.remove(intentId)?.close()
        bodies[intentId] = body
        while (bodies.size > capacity) bodies.remove(bodies.keys.first())?.close()
    }

    /** Removes and returns the body; a second take returns null. */
    @Synchronized fun take(intentId: String): FileBody? = bodies.remove(intentId)

    @Synchronized fun discard(intentId: String) {
        bodies.remove(intentId)?.close(); ignored.add(intentId)
        while (ignored.size > 128) ignored.remove(ignored.first())
    }

    @Synchronized fun clear() { bodies.values.forEach { it.close() }; bodies.clear() }

    @Synchronized fun size() = bodies.size
}

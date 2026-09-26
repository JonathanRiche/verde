package dev.verdeai.core

/** A fetched workspace file. Never logged, written to disk, or put in a crash report. */
class FileBody(val bytes: ByteArray, val contentType: String?)

/**
 * D-12 in-memory hand-off between the effect executor and the file viewer, keyed by the
 * `file_open` intent ID. Bounded: a body the viewer never takes (screen left while loading) is
 * evicted by later fetches, and everything is dropped on sign-out or when the host closes.
 */
class FileSink(private val capacity: Int = 4) {
    private val bodies = LinkedHashMap<String, FileBody>()

    @Synchronized fun put(intentId: String, body: FileBody) {
        bodies.remove(intentId)
        bodies[intentId] = body
        while (bodies.size > capacity) bodies.remove(bodies.keys.first())
    }

    /** Removes and returns the body; a second take returns null. */
    @Synchronized fun take(intentId: String): FileBody? = bodies.remove(intentId)

    @Synchronized fun clear() = bodies.clear()

    @Synchronized fun size() = bodies.size
}

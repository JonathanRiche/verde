package dev.verdeai.app

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Turns picked or captured images into JPEGs no larger than providers keep (2048 px edge), and
 * reads any other picked file as it is. Everything stays in memory or the app's private cache;
 * nothing about a file is logged.
 */
internal object ImageAttachments {
    private const val MAX_EDGE = 2048

    class Prepared(val images: List<PickedImage>, val rejected: Int, val tooLarge: Int = 0)

    /**
     * [anyFile]: the document picker, where a file that isn't an image (or is one this phone can't
     * decode) attaches as it is. Photos and the camera only ever give images.
     */
    suspend fun prepare(context: Context, uris: List<Uri>, anyFile: Boolean = false, maxBytes: Int = ComposerModel.MAX_IMAGE_BYTES): Prepared =
        withContext(Dispatchers.IO) {
            var rejected = 0
            var tooLarge = 0
            val resolver = context.contentResolver
            val picked = uris.mapNotNull { uri ->
                // From the document picker only a stated image is decoded; anything else is read once, as a file.
                val tryImage = !anyFile || try { resolver.getType(uri) } catch (_: Exception) { null }?.startsWith("image/") == true
                val image = if (tryImage) try { one(resolver, uri, maxBytes) } catch (_: Exception) { null } else null
                if (image != null) return@mapNotNull image
                if (!anyFile) { rejected++; return@mapNotNull null }
                when (val file = try { file(resolver, uri) } catch (_: Exception) { null }) {
                    null -> { rejected++; null }
                    TOO_LARGE -> { tooLarge++; null }
                    else -> file
                }
            }
            Prepared(picked, rejected, tooLarge)
        }

    private val TOO_LARGE = PickedImage("", "", ByteArray(0))

    /** A picked file read whole; [TOO_LARGE] past the per-file limit, null when unreadable or empty. */
    private fun file(resolver: ContentResolver, uri: Uri): PickedImage? {
        val stated = statedSize(resolver, uri)
        if (stated != null && stated > ComposerModel.MAX_FILE_BYTES) return TOO_LARGE
        val stream = resolver.openInputStream(uri) ?: return null
        val bytes = stream.use { readFully(it, ComposerModel.MAX_FILE_BYTES) } ?: return TOO_LARGE
        if (bytes.isEmpty()) return null
        val name = fileName(rawName(resolver, uri))
        return PickedImage(name, fileMime(resolver.getType(uri), name), bytes)
    }

    private val MIME = Regex("^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$")

    /**
     * The type a file is sent under. An `image/` type is reserved for images the host can show
     * (re-encoded JPEGs); any other image, such as an SVG, goes as a plain file.
     */
    internal fun fileMime(reported: String?, name: String): String {
        val type = reported?.takeIf { it != "*/*" }
            ?: android.webkit.MimeTypeMap.getSingleton()?.getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
        val clean = type?.lowercase()?.takeIf { it.length <= 127 && MIME.matches(it) && !it.startsWith("image/") }
        return clean ?: "application/octet-stream"
    }

    /** A one-line name the host accepts: no path separators or control characters, at most 120 bytes. */
    internal fun fileName(raw: String?): String {
        var name = raw.orEmpty().map { if (it == '/' || it == '\\' || it.isISOControl()) '_' else it }.joinToString("").trim()
        if (name.isEmpty() || name == "." || name == "..") return "file"
        val extension = name.substringAfterLast('.', "").takeIf { it.isNotEmpty() && it.length <= 10 && name.contains('.') }?.let { ".$it" }.orEmpty()
        var stem = name.removeSuffix(extension)
        while ((stem + extension).toByteArray().size > 120 && stem.isNotEmpty()) stem = stem.dropLast(1)
        name = (stem + extension).trim()
        return name.ifEmpty { "file" }
    }

    /**
     * A5-2: a picker or document URI is an image when its content decodes as one. Its reported type
     * only rules out what clearly isn't (video, documents); the photo picker can report none, or a
     * generic one, for a perfectly good image.
     */
    internal fun plausibleImageType(type: String?): Boolean =
        type == null || type.startsWith("image/") || type == "application/octet-stream" || type == "*/*"

    /** Largest source file read into memory before decoding (well above any phone photo). */
    private const val MAX_SOURCE_BYTES = 64 * 1024 * 1024

    /**
     * J: the whole stream, read to EOF however short each read is. A single read() or an
     * available()-sized buffer can stop early on a provider stream (the photo picker's), and a
     * partial JPEG then decodes with its bottom missing. Null past [limit].
     */
    internal fun readFully(input: java.io.InputStream, limit: Int = MAX_SOURCE_BYTES): ByteArray? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            if (n == 0) continue
            if (out.size() + n > limit) return null
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    /** The provider's stated size, when it reports one. */
    private fun statedSize(resolver: ContentResolver, uri: Uri): Long? = try {
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0).takeIf { it > 0 } else null
        }
    } catch (_: Exception) { null }

    private fun one(resolver: ContentResolver, uri: Uri, maxBytes: Int): PickedImage? {
        if (!plausibleImageType(resolver.getType(uri))) return null
        val expected = statedSize(resolver, uri)
        // Read the complete file first, retrying briefly if the provider hands out fewer bytes than
        // it says the file has (a picker copy still being written), then decode from memory: an
        // incomplete image fails to decode instead of attaching with a black band.
        var bitmap: Bitmap? = null
        for (attempt in 0 until 4) {
            val bytes = resolver.openInputStream(uri)?.use { readFully(it) } ?: return null
            val complete = expected == null || bytes.size.toLong() >= expected
            bitmap = if (complete) decode(bytes) else null
            if (bitmap != null) break
            Thread.sleep(250L * (attempt + 1))
        }
        val bytes = encode(bitmap ?: return null, maxBytes) ?: return null
        return PickedImage(displayName(resolver, uri), "image/jpeg", bytes)
    }

    /** Decodes a whole image (scaled to [MAX_EDGE]); null when it is incomplete or not an image. */
    private fun decode(bytes: ByteArray): Bitmap? = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            // No partial images: an incomplete file throws rather than decoding with a blank remainder.
            decoder.setOnPartialImageListener { false }
            val edge = maxOf(info.size.width, info.size.height)
            if (edge > MAX_EDGE) {
                val scale = MAX_EDGE.toFloat() / edge
                decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
            }
        }
    } catch (_: Exception) { null }

    /** Steps quality, then size, down until the JPEG fits. */
    internal fun encode(source: Bitmap, maxBytes: Int): ByteArray? {
        var bitmap = source
        repeat(6) {
            for (quality in intArrayOf(90, 75, 60, 45)) {
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                if (out.size() in 1..maxBytes) return out.toByteArray()
            }
            val w = (bitmap.width * 0.7f).toInt()
            val h = (bitmap.height * 0.7f).toInt()
            if (w < 64 || h < 64) return null
            bitmap = Bitmap.createScaledBitmap(bitmap, w, h, true)
        }
        return null
    }

    private fun rawName(resolver: ContentResolver, uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (_: Exception) { null }

    private fun displayName(resolver: ContentResolver, uri: Uri): String {
        val name = rawName(resolver, uri)
        // The photo picker names files by a numeric id: the host gets "photo.jpg" instead (A6-3).
        val base = name?.substringBeforeLast('.')?.takeIf { it.isNotBlank() && !it.all(Char::isDigit) }?.take(80) ?: "photo"
        return "$base.jpg"
    }

    /** A fresh private cache file for the camera to write into, shared only through our FileProvider. */
    fun cameraTarget(context: Context): Uri {
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
        return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    }

    fun clearCamera(context: Context) {
        File(context.cacheDir, "camera").listFiles()?.forEach { it.delete() }
    }
}

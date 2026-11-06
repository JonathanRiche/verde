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
 * Turns picked or captured images into JPEGs no larger than providers keep (2048 px edge).
 * Everything stays in memory or the app's private cache; nothing about the image is logged.
 */
internal object ImageAttachments {
    private const val MAX_EDGE = 2048

    class Prepared(val images: List<PickedImage>, val rejected: Int)

    suspend fun prepare(context: Context, uris: List<Uri>, maxBytes: Int = ComposerModel.MAX_IMAGE_BYTES): Prepared =
        withContext(Dispatchers.IO) {
            var rejected = 0
            val images = uris.mapNotNull { uri ->
                val picked = try { one(context.contentResolver, uri, maxBytes) } catch (_: Exception) { null }
                if (picked == null) rejected++
                picked
            }
            Prepared(images, rejected)
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

    private fun displayName(resolver: ContentResolver, uri: Uri): String {
        val name = try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) { null }
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

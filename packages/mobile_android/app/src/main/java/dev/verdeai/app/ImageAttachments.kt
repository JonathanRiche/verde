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
 * Turns picked or captured images into small JPEGs the core can keep in its draft record.
 * Everything stays in memory or the app's private cache; nothing about the image is logged.
 */
internal object ImageAttachments {
    private const val MAX_EDGE = 1600

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

    private fun one(resolver: ContentResolver, uri: Uri, maxBytes: Int): PickedImage? {
        val type = resolver.getType(uri)
        if (type != null && !type.startsWith("image/")) return null
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val edge = maxOf(info.size.width, info.size.height)
            if (edge > MAX_EDGE) {
                val scale = MAX_EDGE.toFloat() / edge
                decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
            }
        }
        val bytes = encode(bitmap, maxBytes) ?: return null
        return PickedImage(displayName(resolver, uri), "image/jpeg", bytes)
    }

    /** Steps quality, then size, down until the JPEG fits. */
    internal fun encode(source: Bitmap, maxBytes: Int): ByteArray? {
        var bitmap = source
        repeat(6) {
            for (quality in intArrayOf(85, 70, 55, 40)) {
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
        val base = name?.substringBeforeLast('.')?.takeIf { it.isNotBlank() }?.take(80) ?: "image"
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

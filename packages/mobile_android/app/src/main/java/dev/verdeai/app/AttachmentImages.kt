package dev.verdeai.app

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.animation.core.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/*
 * Transcript image previews. Committed images are fetched through the core (`attachment_fetch`,
 * `chat.attachment.read`), written once to the app's private cache, then released from the core;
 * later views read the cached file. Images just attached in the composer show their local bytes.
 * Bytes are never logged.
 */

// ---- Pure rules (unit tested) ----

/** The core's `attachments` key. */
internal fun attachmentKey(workspaceId: String, threadId: String, messageId: String, index: Long) = "$workspaceId|$threadId|$messageId|$index"

/** Where a fetchable attachment lives on the host: its stored message and position. */
internal data class AttachmentTarget(val workspaceId: String, val threadId: String, val messageId: String, val index: Long) {
    val key get() = attachmentKey(workspaceId, threadId, messageId, index)
}

/** Only stored image rows can be fetched: they carry a `message_id` and the image its `index`. */
internal fun attachmentTarget(workspaceId: String, threadId: String, row: ChatRow, attachment: ChatAttachment): AttachmentTarget? {
    if (!attachment.mime.startsWith("image/")) return null
    val message = row.message_id?.takeIf { it.isNotEmpty() } ?: return null
    val index = attachment.index ?: return null
    return AttachmentTarget(workspaceId, threadId, message, index)
}

/** Cache file name: SHA-256 of host + key, so IDs never become paths. */
internal fun attachmentCacheName(hostId: String, key: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("$hostId\n$key".toByteArray())
    return digest.joinToString("") { "%02x".format(it) } + ".img"
}

internal enum class ImageStatus { Loading, Ready, Unavailable, Failed }

/** The core's item status for the UI; a missing item is still loading. */
internal fun imageStatus(item: AttachmentItem?): ImageStatus = when (item?.status) {
    "ready" -> ImageStatus.Ready
    "unavailable" -> ImageStatus.Unavailable
    "failed" -> ImageStatus.Failed
    else -> ImageStatus.Loading
}

/** Power-of-two downsampling so the decoded image is at most about [maxPx] on its longer side. */
internal fun sampleSize(width: Int, height: Int, maxPx: Int): Int {
    var sample = 1
    val longest = maxOf(width, height)
    while (longest / (sample * 2) >= maxPx) sample *= 2
    return sample
}

internal fun decodeImage(file: File? = null, bytes: ByteArray? = null, maxPx: Int): Bitmap? = try {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    if (file != null) BitmapFactory.decodeFile(file.path, bounds) else if (bytes != null) BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) null else {
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxPx) }
        if (file != null) BitmapFactory.decodeFile(file.path, options) else BitmapFactory.decodeByteArray(bytes, 0, bytes!!.size, options)
    }
} catch (_: OutOfMemoryError) { null } catch (_: Exception) { null }

// ---- Loader (one per transcript model) ----

internal class AttachmentImages(
    private val scope: CoroutineScope,
    private val host: () -> CoreHost?,
    private val hostId: () -> String?,
) {
    val status = mutableStateMapOf<String, ImageStatus>()
    val files = mutableStateMapOf<String, File>()

    private fun decode(value: JsonElement?): AttachmentsView? = value?.let {
        try { CoreJson.decodeFromJsonElement<AttachmentsQuery>(it).data } catch (_: Exception) { null }
    }

    /** Shows the cached file, or fetches it once. Repeated calls while loading or ready are no-ops. */
    fun request(target: AttachmentTarget, cacheRoot: File) {
        val key = target.key
        if (status[key] == ImageStatus.Loading || status[key] == ImageStatus.Ready) return
        val file = File(File(cacheRoot, ATTACHMENT_CACHE_DIR), attachmentCacheName(hostId().orEmpty(), key))
        status[key] = ImageStatus.Loading
        scope.launch {
            if (withContext(Dispatchers.IO) { file.isFile && file.length() > 0 }) {
                files[key] = file
                status[key] = ImageStatus.Ready
                return@launch
            }
            val core = host() ?: run { status[key] = ImageStatus.Failed; return@launch }
            try {
                core.send { n, w -> EventAttachmentFetch(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                    workspace_id = target.workspaceId, thread_id = target.threadId, message_id = target.messageId, index = target.index) }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { status[key] = ImageStatus.Failed; return@launch }
            val item = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                flow {
                    emit(try { core.query("attachments") } catch (e: CancellationException) { throw e } catch (_: Exception) { null })
                    emitAll(core.views.map { it["attachments"] })
                }.map { value -> decode(value)?.items?.find { it.key == key } }.first { it != null && it.status != "loading" }
            }
            val outcome = imageStatus(item)
            if (outcome != ImageStatus.Ready) {
                status[key] = if (outcome == ImageStatus.Loading) ImageStatus.Failed else outcome
                return@launch
            }
            val written = withContext(Dispatchers.IO) {
                try {
                    val bytes = Base64.getDecoder().decode(item!!.data_base64.orEmpty())
                    file.parentFile?.mkdirs()
                    val partial = File(file.parentFile, file.name + ".part")
                    partial.writeBytes(bytes)
                    partial.renameTo(file)
                } catch (_: Exception) { false }
            }
            // The bytes are on disk now; the core can drop its copy.
            try {
                core.send { n, w -> EventAttachmentRelease(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(), key = key) }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { }
            if (written) { files[key] = file; status[key] = ImageStatus.Ready } else status[key] = ImageStatus.Failed
        }
    }

    companion object { const val FETCH_TIMEOUT_MS = 120_000L }
}

internal const val ATTACHMENT_CACHE_DIR = "attachments"

// ---- UI ----

/** Attachment chips of a transcript row: thumbnails once loaded, the file name always. */
@Composable
internal fun AttachmentStrip(row: ChatRow, ctx: TranscriptContext) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        row.attachments.forEach { a -> AttachmentChip(row, a, ctx) }
    }
}

@Composable
private fun AttachmentChip(row: ChatRow, a: ChatAttachment, ctx: TranscriptContext) {
    val context = LocalContext.current
    val model = ctx.model
    val image = a.mime.startsWith("image/")
    // Just attached in the composer: the phone already has the bytes.
    val local = if (image) model.composer.previewFor(a.local_id) else null
    val target = if (image && local == null) attachmentTarget(model.workspaceId, model.threadId, row, a) else null
    val images = model.images
    if (target != null) LaunchedEffect(target.key) { images.request(target, context.cacheDir) }
    val status = when {
        local != null -> ImageStatus.Ready
        target != null -> images.status[target.key] ?: ImageStatus.Loading
        else -> ImageStatus.Unavailable
    }
    val file = target?.let { images.files[it.key] }
    val label = (if (image) "Image · " else "") + basename(a.name)
    var viewing by remember { mutableStateOf(false) }
    Surface(color = VerdeColors.PanelAlt, shape = RoundedCornerShape(10.dp)) {
        Column(Modifier.padding(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            when {
                status == ImageStatus.Ready && (local != null || file != null) -> {
                    val bitmap by produceState<Bitmap?>(null, file, local) {
                        value = withContext(Dispatchers.IO) { decodeImage(file, local, THUMBNAIL_PX) }
                    }
                    bitmap?.let { b ->
                        Image(b.asImageBitmap(), contentDescription = label, contentScale = ContentScale.Fit,
                            modifier = Modifier.widthIn(min = 96.dp, max = 160.dp).heightIn(max = 160.dp)
                                .aspectRatio(b.width.toFloat() / b.height.coerceAtLeast(1), matchHeightConstraintsFirst = b.height > b.width)
                                .clip(RoundedCornerShape(8.dp)).clickable(onClickLabel = "View image") { viewing = true })
                    } ?: ImagePlaceholder()
                }
                status == ImageStatus.Loading -> ImagePlaceholder()
                else -> Unit
            }
            Text(label, style = MaterialTheme.typography.labelMedium)
            if (status == ImageStatus.Unavailable || status == ImageStatus.Failed)
                Text("Preview unavailable", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
        }
    }
    if (viewing) ImageViewer(file, local, a.mime, label) { viewing = false }
}

private const val THUMBNAIL_PX = 480
private const val VIEWER_PX = 2048

/** A soft shimmer while the image loads (static when the UI clock doesn't tick, e.g. in tests). */
@Composable
private fun ImagePlaceholder() {
    val ticking = LocalUiClock.current.ticking
    val alpha = if (!ticking) .5f else rememberInfiniteTransition(label = "Image loading")
        .animateFloat(.3f, .7f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "Shimmer").value
    Box(Modifier.size(width = 128.dp, height = 96.dp).clip(RoundedCornerShape(8.dp)).alpha(alpha)
        .background(VerdeColors.PanelMuted).semantics { contentDescription = "Loading image" })
}

/** Full-screen image: pinch to zoom, drag to pan, swipe down (unzoomed) to close, share the cached file. */
@Composable
private fun ImageViewer(file: File?, local: ByteArray?, mime: String, label: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val bitmap by produceState<Bitmap?>(null, file, local) { value = withContext(Dispatchers.IO) { decodeImage(file, local, VIEWER_PX) } }
    var scale by remember { mutableFloatStateOf(1f) }
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        LiveOverModal()
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            bitmap?.let { b ->
                Image(b.asImageBitmap(), contentDescription = label, contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                        .pointerInput(Unit) {
                            detectTransformGestures { _, pan, zoom, _ ->
                                scale = (scale * zoom).coerceIn(1f, 6f)
                                if (scale > 1f) { offsetX += pan.x; offsetY += pan.y }
                                else {
                                    offsetX = 0f
                                    offsetY = (offsetY + pan.y).coerceAtLeast(0f)
                                    if (offsetY > size.height * .2f) onDismiss()
                                }
                            }
                        }
                        .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offsetX, translationY = offsetY))
            } ?: CircularProgressIndicator(Modifier.align(Alignment.Center))
            Row(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(8.dp)) {
                if (file != null) IconButton(onClick = { shareImage(context, file, mime) }) {
                    Icon(Icons.Filled.Share, contentDescription = "Share image", tint = Color.White)
                }
                IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Close image", tint = Color.White) }
            }
        }
    }
}

private fun shareImage(context: Context, file: File, mime: String) {
    try {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val send = Intent(Intent.ACTION_SEND).setType(mime.ifEmpty { "image/*" }).putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(send, "Share image").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: Exception) { }
}

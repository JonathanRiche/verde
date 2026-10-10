package dev.verdeai.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.put
import java.io.Closeable
import java.util.UUID

/**
 * D-12 file viewer. Bytes come from the core's authenticated `file_open` fetch (the host's bearer
 * and TLS pin) and live only in this model's memory: never written to disk, cached, logged or
 * backed up. PDFs are handed to [PdfRenderer] through an anonymous in-memory file (memfd).
 * The one exception is an explicit Download, which writes the original bytes only to the
 * document the user picked in the system file picker.
 */
internal enum class ViewerKind { Text, Markdown, Image, Svg, Pdf, Office }

private val IMAGE_EXTS = setOf("png", "jpg", "jpeg", "webp", "gif", "bmp")
private val MARKDOWN_EXTS = setOf("md", "markdown")
/** The host converts these to PDF (`/api/preview`, LibreOffice); same list as the gateway. */
private val OFFICE_EXTS = setOf("pptx", "ppt", "odp", "docx", "doc", "odt", "xlsx", "xls", "ods", "rtf")
/** The gateway refuses these inline (they'd run in its origin) and serves them only as downloads. */
private val ATTACHMENT_EXTS = setOf("html", "htm", "svg", "js", "mjs", "cjs", "wasm")

internal fun fileExtension(path: String) = path.substringAfterLast('/').let { name ->
    val dot = name.lastIndexOf('.')
    if (dot > 0) name.substring(dot + 1).lowercase() else ""
}

internal fun viewerKind(path: String): ViewerKind = when (val ext = fileExtension(path)) {
    in IMAGE_EXTS -> ViewerKind.Image
    "svg" -> ViewerKind.Svg
    in MARKDOWN_EXTS -> ViewerKind.Markdown
    "pdf" -> ViewerKind.Pdf
    in OFFICE_EXTS -> ViewerKind.Office
    else -> ViewerKind.Text
}

/** How [path] is fetched for viewing: Office converts to PDF; script-capable types come as attachments. */
internal fun viewerFetchKind(path: String): FileKind = when {
    viewerKind(path) == ViewerKind.Office -> FileKind.preview
    fileExtension(path) in ATTACHMENT_EXTS -> FileKind.download
    else -> FileKind.file
}

/** Best-effort MIME type for the save picker. */
internal fun downloadMime(path: String): String =
    android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(fileExtension(path)) ?: "application/octet-stream"

internal const val MAX_TEXT_BYTES = 2L * 1024 * 1024
internal const val MAX_IMAGE_BYTES = 16L * 1024 * 1024
/** The gateway's own ceiling (`MAX_SERVED_FILE_BYTES`). */
internal const val MAX_DOCUMENT_BYTES = 32L * 1024 * 1024

/** Per-kind phone limit, enforced while streaming; bigger files get the "too large" state. */
internal fun viewerLimit(kind: ViewerKind) = when (kind) {
    ViewerKind.Text, ViewerKind.Markdown -> MAX_TEXT_BYTES
    ViewerKind.Image, ViewerKind.Svg -> MAX_IMAGE_BYTES
    ViewerKind.Pdf, ViewerKind.Office -> MAX_DOCUMENT_BYTES
}

internal fun sizeLabel(bytes: Long) = if (bytes >= 1024 * 1024) "${bytes / (1024 * 1024)} MB" else "${bytes / 1024} KB"

/**
 * Citation/diff paths are absolute or relative to the workspace root. The core and the gateway
 * re-validate the result (absolute, no `..`, inside a registered root).
 */
internal fun resolveFilePath(path: String, workspaceRoot: String?): String? {
    val value = path.trim()
    if (value.isEmpty()) return null
    if (value.startsWith("/")) return value
    val root = workspaceRoot?.takeIf { it.startsWith("/") } ?: return null
    return root.trimEnd('/') + "/" + value.removePrefix("./")
}

/** 1-based inclusive line range to reveal; [end] is null for a single line. */
internal data class LineTarget(val line: Int, val end: Int? = null) {
    val last get() = end?.coerceAtLeast(line) ?: line
    operator fun contains(n: Int) = n in line..last
    companion object {
        fun of(line: Long?, end: Long?): LineTarget? {
            val first = line?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
            return LineTarget(first, end?.takeIf { it >= first && it <= Int.MAX_VALUE }?.toInt())
        }
    }
}

internal enum class FileProblem {
    Offline, Timeout, Interrupted, Busy, ServerUnavailable, Unauthorized, Identity,
    Forbidden, NotFound, TooLarge, Unsupported, PreviewUnavailable, Binary, Unresolved,
    PdfNeedsNewerAndroid, Unreadable, Unavailable, Failed,
}

/** Maps a `file_open` receipt error code (files.zig) onto a viewer state. */
internal fun fileProblem(code: String?): FileProblem = when (code) {
    "offline" -> FileProblem.Offline
    "timeout" -> FileProblem.Timeout
    "cancelled" -> FileProblem.Interrupted
    "busy" -> FileProblem.Busy
    "server_unavailable" -> FileProblem.ServerUnavailable
    "unauthorized" -> FileProblem.Unauthorized
    "identity" -> FileProblem.Identity
    "forbidden" -> FileProblem.Forbidden
    "not_found" -> FileProblem.NotFound
    "too_large" -> FileProblem.TooLarge
    "unsupported" -> FileProblem.Unsupported
    "invalid_path" -> FileProblem.Unresolved
    "preview_unavailable" -> FileProblem.PreviewUnavailable
    "unavailable" -> FileProblem.Unavailable
    else -> FileProblem.Failed
}

internal sealed interface FileContent {
    /** [lineStarts] are UTF-16 offsets of each displayed line; [spans] are K-11 byte ranges. */
    class Text(val text: String, val lineStarts: IntArray, val spans: List<RenderSpan>) : FileContent
    class Markdown(val source: Text, val nodes: List<MarkdownNode>) : FileContent
    class Image(val bitmap: ImageBitmap) : FileContent
    /** Rendered by a sandboxed WebView (no scripts, network or file access); [source] is the XML. */
    class Svg(val source: Text, val base64: String) : FileContent
    class Pdf(val document: PdfDocument) : FileContent
}

/** Problems where the file exists on the host but the phone can't preview it: offer a download. */
internal val DOWNLOADABLE_PROBLEMS = setOf(FileProblem.TooLarge, FileProblem.Unsupported, FileProblem.PreviewUnavailable,
    FileProblem.Binary, FileProblem.PdfNeedsNewerAndroid, FileProblem.Unreadable)

internal sealed interface DownloadStatus {
    data object Idle : DownloadStatus
    data object Saving : DownloadStatus
    data object Saved : DownloadStatus
    data class Failed(val problem: FileProblem) : DownloadStatus
}

internal data class FileViewState(
    val loading: Boolean = true,
    val content: FileContent? = null,
    val problem: FileProblem? = null,
    val retryable: Boolean = false,
    /** Set when the host sent only the file's first bytes. */
    val partial: FilePartial? = null,
)

/** A cut read: [shown] leading bytes of a [total]-byte file (0 when unknown). */
internal data class FilePartial(val shown: Long, val total: Long)

/** A rendered page source; implemented over [PdfRenderer], faked in tests. */
internal interface PdfDocument : Closeable {
    val pageCount: Int
    /** Page aspect ratio (width / height). */
    fun aspect(index: Int): Float
    suspend fun render(index: Int, widthPx: Int): ImageBitmap?
}

/** Platform decoders, replaceable in Robolectric tests (PdfRenderer and memfd need a device). */
internal interface FileDecoders {
    fun image(bytes: ByteArray): ImageBitmap?
    /** Null when the document can't be opened; throws [PdfUnsupported] below Android 11. */
    fun pdf(bytes: ByteArray): PdfDocument?
}

internal class PdfUnsupported : Exception()

internal object AndroidFileDecoders : FileDecoders {
    /** Longest decoded image edge; larger images are subsampled to bound memory. */
    private const val MAX_EDGE = 4096

    override fun image(bytes: ByteArray): ImageBitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_EDGE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)?.asImageBitmap()
    }

    override fun pdf(bytes: ByteArray): PdfDocument? {
        // An anonymous memory file: PdfRenderer needs a seekable descriptor, and the document
        // must never touch storage. Android 10 has no memfd API, so PDFs need Android 11+.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw PdfUnsupported()
        val fd = Os.memfd_create("verde-document", OsConstants.MFD_CLOEXEC)
        val pfd = try {
            var offset = 0
            while (offset < bytes.size) offset += Os.write(fd, bytes, offset, bytes.size - offset)
            Os.lseek(fd, 0, OsConstants.SEEK_SET)
            ParcelFileDescriptor.dup(fd)
        } finally { Os.close(fd) }
        return try { RendererDocument(PdfRenderer(pfd)) } catch (_: Exception) { pfd.close(); null }
    }
}

/** PdfRenderer allows one open page at a time and is not thread-safe: all use is serialized. */
private class RendererDocument(private val renderer: PdfRenderer) : PdfDocument {
    private val lock = Mutex()
    private var closed = false
    private val aspects = FloatArray(renderer.pageCount) { i ->
        renderer.openPage(i).use { page -> if (page.height > 0) page.width.toFloat() / page.height else 1f }
    }
    override val pageCount = renderer.pageCount
    override fun aspect(index: Int) = aspects.getOrElse(index) { 1f }
    override suspend fun render(index: Int, widthPx: Int): ImageBitmap? = lock.withLock {
        withContext(Dispatchers.IO) {
            if (closed || index !in 0 until pageCount) return@withContext null
            renderer.openPage(index).use { page ->
                val width = widthPx.coerceIn(1, 2048)
                val height = (width / aspect(index)).toInt().coerceIn(1, 4096)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(android.graphics.Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                bitmap.asImageBitmap()
            }
        }
    }
    override fun close() {
        // Waits for an in-flight page render; the renderer owns and closes the memfd.
        runBlocking { lock.withLock { if (!closed) { closed = true; renderer.close() } } }
    }
}

/** Splits [text] into display lines (a final newline does not start an empty last line). */
internal fun lineStarts(text: String): IntArray {
    val starts = ArrayList<Int>()
    starts.add(0)
    for (i in text.indices) if (text[i] == '\n' && i + 1 < text.length) starts.add(i + 1)
    return starts.toIntArray()
}

/** End (exclusive, without the line break) of display line [index]. */
internal fun lineEnd(text: String, starts: IntArray, index: Int): Int {
    var end = if (index + 1 < starts.size) starts[index + 1] else text.length
    if (end > starts[index] && text[end - 1] == '\n') end--
    if (end > starts[index] && text[end - 1] == '\r') end--
    return end
}

/** UTF-8 text, or null for binary content (a NUL byte, as the web viewer checks). */
internal fun decodeText(bytes: ByteArray): String? {
    if (bytes.any { it == 0.toByte() }) return null
    return bytes.decodeToString().removePrefix("﻿")
}

/**
 * One viewer screen for one file of the host [hostId] (the host the citation came from). [path]
 * is already resolved (absolute) or null when the link could not be resolved. Retry spends a new
 * intent.
 */
internal class FileViewerModel(
    private val hosts: HostsModel,
    private val hostId: String?,
    val path: String?,
    private val decoders: FileDecoders = AndroidFileDecoders,
    private val waitMs: Long = WAIT_MS,
    /** Alternate source (Files tab: `workspace.files.read`): bytes, a failed state, or null for the `/api/file` fetch. */
    private val reader: (suspend (CoreHost) -> Any?)? = null,
) : ViewModel(), HighlightSource {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(FileViewState(loading = path != null,
        problem = if (path == null) FileProblem.Unresolved else null))
    val state = mutableState.asStateFlow()
    val kind = path?.let(::viewerKind) ?: ViewerKind.Text
    val limit = viewerLimit(kind)
    private var core: CoreHost? = null
    private var job: Job? = null
    private val highlights = RenderCache(32).highlight
    private val highlightLock = Any()
    private val mutableDownload = MutableStateFlow<DownloadStatus>(DownloadStatus.Idle)
    val download = mutableDownload.asStateFlow()

    init {
        if (path != null) scope.launch { observe(hostId) }
    }

    private suspend fun observe(id: String?) = coroutineScope {
        if (id == null) { replace(FileViewState(loading = false, problem = FileProblem.Unavailable)); return@coroutineScope }
        val host = try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (host == null) { replace(FileViewState(loading = false, problem = FileProblem.Unavailable)); return@coroutineScope }
        core = host
        // Signing out wipes the host: drop the document with it.
        launch {
            host.hosts.map { q -> q?.data?.items?.firstOrNull()?.auth_state }.distinctUntilChanged().collect { auth ->
                if (auth in HostsModel.WIPED) {
                    job?.cancel()
                    replace(FileViewState(loading = false, problem = FileProblem.Unavailable, retryable = true))
                }
            }
        }
        load(host)
    }

    fun retry() {
        val host = core ?: return
        if (state.value.loading) return
        load(host)
    }

    /**
     * Fetches the original file (never the Office preview) and hands it to [write], which targets
     * the document the user just picked. [discard] removes that document if nothing was saved.
     */
    fun save(write: (ByteArray) -> Unit, discard: () -> Unit) {
        val target = path ?: return
        if (download.value == DownloadStatus.Saving) return
        val host = core ?: run { discard(); mutableDownload.value = DownloadStatus.Failed(FileProblem.Unavailable); return }
        mutableDownload.value = DownloadStatus.Saving
        scope.launch {
            val next = try {
                when (val bytes = fetchBytes(host, target, FileKind.download, MAX_DOCUMENT_BYTES)) {
                    is ByteArray -> { withContext(Dispatchers.IO) { write(bytes) }; DownloadStatus.Saved }
                    else -> DownloadStatus.Failed((bytes as FileViewState).problem ?: FileProblem.Failed)
                }
            } catch (e: CancellationException) { withContext(NonCancellable + Dispatchers.IO) { runCatching(discard) }; throw e }
                catch (_: Exception) { DownloadStatus.Failed(FileProblem.Failed) }
            if (next is DownloadStatus.Failed) withContext(Dispatchers.IO) { runCatching(discard) }
            mutableDownload.value = next
        }
    }

    /** Clears a reported save result. */
    fun downloadShown() { if (download.value != DownloadStatus.Saving) mutableDownload.value = DownloadStatus.Idle }

    private fun load(host: CoreHost) {
        val target = path ?: return
        job?.cancel()
        replace(FileViewState(loading = true))
        job = scope.launch {
            val next = try { fetch(host, target) }
                catch (e: CancellationException) { throw e }
                catch (_: CoreInputRejected) { FileViewState(loading = false, problem = FileProblem.Failed, retryable = true) }
                catch (_: Exception) { FileViewState(loading = false, problem = FileProblem.Unavailable, retryable = true) }
            replace(next)
        }
    }

    /** Returns the body as a [ByteArray], or a failed [FileViewState]. */
    private suspend fun fetchBytes(host: CoreHost, target: String, fetchKind: FileKind, maxBytes: Long): Any {
        return withTimeoutOrNull(waitMs) {
            // The document picker backgrounds the process. Its result can be delivered before
            // ON_START reaches the core; sending now would be rejected as cancelled. Wait for
            // the core's projection, then let it refresh the bearer before emitting the GET.
            val ready = host.hosts.map { q -> q?.data?.items?.firstOrNull() }.first {
                it?.lifecycle == Lifecycle.foreground || it?.auth_state in HostsModel.WIPED
            }
            if (ready?.auth_state in HostsModel.WIPED) {
                return@withTimeoutOrNull FileViewState(loading = false, problem = FileProblem.Unavailable, retryable = true)
            }
            val intent = UUID.randomUUID().toString()
            host.send { n, w -> EventFileOpen(now_ms = n, wall_time_ms = w, intent_id = intent, path = target,
                kind = fetchKind, max_bytes = maxBytes) }
            val op = host.operations.map { q -> q?.data?.items?.find { it.intent_id == intent } }
                .first { it != null && it.state != "pending" }!!
            if (op.state != "succeeded") {
                FileViewState(loading = false, problem = fileProblem(op.error?.code), retryable = op.error?.retryable == true)
            } else host.takeFile(intent)?.bytes ?: FileViewState(loading = false, problem = FileProblem.Failed, retryable = true)
        } ?: FileViewState(loading = false, problem = FileProblem.Timeout, retryable = true)
    }

    private suspend fun fetch(host: CoreHost, target: String): FileViewState {
        var partial: FilePartial? = null
        val bytes = when (val body = reader?.invoke(host) ?: fetchBytes(host, target, viewerFetchKind(target), limit)) {
            is ByteArray -> body
            is PartialBytes -> body.bytes.also { partial = body.partial }
            else -> return body as FileViewState
        }
        val content = try { withContext(Dispatchers.Default) { decode(host, bytes) } }
            catch (e: CancellationException) { throw e }
            catch (_: PdfUnsupported) { return FileViewState(loading = false, problem = FileProblem.PdfNeedsNewerAndroid) }
            catch (_: OutOfMemoryError) { return FileViewState(loading = false, problem = FileProblem.TooLarge) }
            catch (_: Exception) { return FileViewState(loading = false, problem = FileProblem.Unreadable) }
        return if (content is FileContent) FileViewState(loading = false, content = content, partial = partial)
            else FileViewState(loading = false, problem = content as FileProblem)
    }

    /** Returns a [FileContent] or a [FileProblem]. */
    private suspend fun decode(host: CoreHost, bytes: ByteArray): Any = when (kind) {
        ViewerKind.Image -> decoders.image(bytes)?.let { FileContent.Image(it) } ?: FileProblem.Unreadable
        ViewerKind.Svg -> decodeText(bytes)?.takeIf { it.isNotBlank() }?.let { text ->
            FileContent.Svg(FileContent.Text(text, lineStarts(text), emptyList()),
                java.util.Base64.getEncoder().encodeToString(bytes))
        } ?: FileProblem.Unreadable
        ViewerKind.Pdf, ViewerKind.Office ->
            (if (bytes.isEmpty()) null else decoders.pdf(bytes))?.let { FileContent.Pdf(it) } ?: FileProblem.Unreadable
        ViewerKind.Text, ViewerKind.Markdown -> {
            val text = decodeText(bytes)
            if (text == null) FileProblem.Binary
            else {
                val language = path?.let(::diffLanguage)
                val spans = if (language != null) highlight(text, language).value.orEmpty() else emptyList()
                val plain = FileContent.Text(text, lineStarts(text), spans)
                val nodes = if (kind == ViewerKind.Markdown) markdown(host, text) else null
                if (nodes != null) FileContent.Markdown(plain, nodes) else plain
            }
        }
    }

    private suspend fun markdown(host: CoreHost, text: String): List<MarkdownNode>? {
        val selector = buildJsonObject { put("utility", "markdown"); put("text", text) }.toString()
        if (selector.length > TranscriptModel.MAX_RENDER_SELECTOR) return null
        return try { CoreJson.decodeFromJsonElement<MarkdownQuery>(host.query(selector)).data?.nodes }
            catch (e: CancellationException) { throw e } catch (_: Exception) { null }
    }

    override fun cachedHighlight(code: String, language: String) = synchronized(highlightLock) { highlights[language + "\u0000" + code] }
    override suspend fun highlight(code: String, language: String): RenderResult<List<RenderSpan>> {
        cachedHighlight(code, language)?.let { return it }
        val selector = buildJsonObject { put("utility", "highlight"); put("text", code); put("language", language) }.toString()
        val host = core
        // Over the core's 64 KiB utility budget the file shows as plain text.
        val result: RenderResult<List<RenderSpan>> = if (host == null || selector.length > TranscriptModel.MAX_RENDER_SELECTOR) RenderResult(null) else try {
            RenderResult(CoreJson.decodeFromJsonElement<HighlightQuery>(host.query(selector)).data?.spans)
        } catch (e: CancellationException) { throw e } catch (_: Exception) { RenderResult<List<RenderSpan>>(null) }
        return result.also { synchronized(highlightLock) { highlights[language + "\u0000" + code] = it } }
    }

    /** Swaps state and releases a replaced PDF renderer. */
    private fun replace(next: FileViewState) {
        val old = mutableState.value.content
        mutableState.value = next
        if (old is FileContent.Pdf && old !== next.content) closeDocument(old.document)
    }

    override fun onCleared() {
        scope.cancel()
        (mutableState.value.content as? FileContent.Pdf)?.let { closeDocument(it.document) }
        mutableState.value = FileViewState(loading = false)
    }

    private fun closeDocument(document: PdfDocument) {
        closer.launch { try { document.close() } catch (_: Exception) { } }
    }

    companion object {
        /** Office previews convert on the host; the core's own timeout is 120 s. */
        const val WAIT_MS = 150_000L
        private val closer = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}

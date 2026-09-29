package dev.verdeai.app

import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.WebView
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.verdeai.core.FileCitation

internal const val FILE_LINE_TAG = "file-line"
internal const val FILE_TARGET_TAG = "file-line-target"
internal const val FILE_PROBLEM_TAG = "file-problem"
internal const val FILE_MARKDOWN_TAG = "file-markdown"
internal const val FILE_IMAGE_TAG = "file-image"
internal const val FILE_PDF_TAG = "file-pdf"
internal const val FILE_SVG_TAG = "file-svg"

/**
 * D-12 entry: resolves a citation or diff path against the workspace root and opens it on the
 * host that produced it. Paths and contents stay in memory; nothing here is logged.
 */
@Composable
internal fun FileRoute(
    hosts: HostsModel,
    browse: BrowseModel,
    workspaceId: String,
    rawPath: String,
    line: Long?,
    endLine: Long?,
    onCitation: (FileCitation) -> Unit,
    onBack: () -> Unit,
) {
    val browseState by browse.state.collectAsState()
    val hostId = remember { browse.state.value.hostId }
    val root = browseState.workspaces?.items?.find { it.workspace_id == workspaceId }?.path
    val relative = !rawPath.trim().startsWith("/")
    if (relative && root == null && browseState.workspaces == null && browseState.hostId == hostId) {
        // The workspace list (and so the root to resolve against) is still loading.
        FileScaffold(basename(rawPath), null, onBack) { Centered { CircularProgressIndicator() } }
        return
    }
    val resolved = remember(rawPath, root) { resolveFilePath(rawPath, root) }
    val model: FileViewerModel = viewModel(key = "file:$hostId:${resolved ?: rawPath}",
        factory = viewModelFactory { initializer { FileViewerModel(hosts, hostId, resolved) } })
    // Relative citations inside a viewed markdown file resolve against the same workspace.
    FileViewerScreen(model, LineTarget.of(line, endLine), onCitation, onBack, title = basename(rawPath))
}

@Composable
internal fun FileViewerScreen(
    model: FileViewerModel,
    target: LineTarget?,
    onCitation: (FileCitation) -> Unit,
    onBack: () -> Unit,
    title: String = model.path?.let(::basename) ?: "File",
) {
    val state by model.state.collectAsState()
    val saving = model.download.collectAsState().value == DownloadStatus.Saving
    val download = rememberDownload(model, title)
    // A cited line is only visible in the source; a plain markdown link opens formatted.
    var formatted by rememberSaveable { mutableStateOf(target == null) }
    val toggle = when (state.content) {
        is FileContent.Markdown -> if (formatted) "Source" else "Formatted"
        is FileContent.Svg -> if (formatted) "Source" else "Image"
        else -> null
    }
    val subtitle = target?.let { if (it.end != null && it.end > it.line) "Lines ${it.line}–${it.end}" else "Line ${it.line}" }
    FileScaffold(title, subtitle, onBack, actions = {
        if (toggle != null) TextButton(onClick = { formatted = !formatted }) { Text(toggle) }
        if (model.path != null) {
            if (saving) CircularProgressIndicator(Modifier.padding(12.dp).size(24.dp).testTag("file-saving"), strokeWidth = 2.dp)
            else IconButton(onClick = download) { Icon(DownloadIcon, contentDescription = "Download file") }
        }
    }) {
        val content = state.content
        val problem = state.problem
        when {
            content != null -> when (content) {
                is FileContent.Text -> TextFile(content, target)
                is FileContent.Markdown -> if (formatted) MarkdownFile(content, model, onCitation) else TextFile(content.source, target)
                is FileContent.Image -> ImageFile(content.bitmap)
                is FileContent.Svg -> if (formatted) SvgFile(content.base64) else TextFile(content.source, target)
                is FileContent.Pdf -> PdfFile(content.document)
            }
            problem != null -> ProblemState(problem, model.limit, if (state.retryable) model::retry else null,
                if (model.path != null && problem in DOWNLOADABLE_PROBLEMS) download else null, saving)
            else -> Centered { CircularProgressIndicator(Modifier.testTag("file-loading")) }
        }
    }
}

/**
 * Save-as for the original file, like the web viewer's Download: the system picker creates the
 * target document, then the model fetches the bytes and writes them there. Returns the launcher.
 */
@Composable
private fun rememberDownload(model: FileViewerModel, name: String): () -> Unit {
    val context = LocalContext.current
    val status by model.download.collectAsState()
    LaunchedEffect(status) {
        val message = when (val current = status) {
            DownloadStatus.Saved -> "Saved $name"
            is DownloadStatus.Failed -> downloadFailureText(current.problem)
            else -> null
        } ?: return@LaunchedEffect
        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        model.downloadShown()
    }
    val mime = remember(model.path) { model.path?.let(::downloadMime) ?: "application/octet-stream" }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(mime)) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val resolver = context.contentResolver
        model.save(
            write = { bytes -> (resolver.openOutputStream(uri, "wt") ?: error("unwritable")).use { it.write(bytes) } },
            discard = { DocumentsContract.deleteDocument(resolver, uri) },
        )
    }
    return remember(picker, name) { { picker.launch(name) } }
}

/** Material "Download" (the core icon set has none). */
private val DownloadIcon: ImageVector by lazy {
    ImageVector.Builder("Download", 24.dp, 24.dp, 24f, 24f)
        .addPath(addPathNodes("M5,20h14v-2H5V20zM19,9h-4V3H9v6H5l7,7L19,9z"), fill = SolidColor(Color.Black))
        .build()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FileScaffold(title: String, subtitle: String?, onBack: () -> Unit,
                         actions: @Composable RowScope.() -> Unit = {}, body: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        VerdeTopBar(
            title = {
                Column {
                    Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    subtitle?.let { Text(it, style = MaterialTheme.typography.labelMedium) }
                }
            },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
            actions = actions)
        Box(Modifier.weight(1f).fillMaxWidth()) { body() }
    }
}

@Composable
private fun Centered(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally, content = content)
}

internal fun problemText(problem: FileProblem, limit: Long): Pair<String, String> = when (problem) {
    FileProblem.TooLarge -> "Too large to preview" to "This file is over the ${sizeLabel(limit)} limit for viewing on the phone. Download it or open it on the host."
    FileProblem.Forbidden -> "No access" to "This file is outside the host's shared workspaces."
    FileProblem.NotFound -> "File not found" to "It may have been moved or deleted on the host."
    FileProblem.Offline -> "Can't reach the host" to "Check your connection and try again."
    FileProblem.Unsupported -> "No preview for this file" to "This file type can't be previewed on the phone. Download it to open it in another app."
    FileProblem.PreviewUnavailable -> "No preview available" to "Office previews need LibreOffice on the host."
    FileProblem.Binary -> "No preview for this file" to "This file isn't text or a supported image or document. Download it to open it in another app."
    FileProblem.Unresolved -> "Can't open this link" to "The path couldn't be resolved to a file in the workspace."
    FileProblem.PdfNeedsNewerAndroid -> "Needs Android 11" to "PDF viewing needs Android 11 or newer."
    FileProblem.Unreadable -> "Can't display this file" to "The file couldn't be decoded."
    FileProblem.Unavailable -> "Host not connected" to "Reconnect to the host to view files."
    FileProblem.Failed -> "Couldn't open the file" to "Something went wrong loading it."
}

internal fun downloadFailureText(problem: FileProblem): String = when (problem) {
    FileProblem.TooLarge -> "Too large to download (over ${sizeLabel(MAX_DOCUMENT_BYTES)})"
    FileProblem.NotFound -> "File not found on the host"
    FileProblem.Forbidden -> "This file is outside the host's shared workspaces"
    FileProblem.Offline, FileProblem.Unavailable -> "Can't reach the host"
    // Hosts before attachment downloads refuse HTML/SVG/scripts outright.
    FileProblem.Unsupported -> "Update Verde on the host to download this file type"
    else -> "Couldn't download the file"
}

@Composable
private fun ProblemState(problem: FileProblem, limit: Long, onRetry: (() -> Unit)?, onDownload: (() -> Unit)?, saving: Boolean) {
    val (title, detail) = problemText(problem, limit)
    Centered {
        Text(title, Modifier.testTag(FILE_PROBLEM_TAG), style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(detail, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (onRetry != null) {
            Spacer(Modifier.height(12.dp))
            Button(onClick = onRetry) { Text("Retry") }
        }
        if (onDownload != null) {
            Spacer(Modifier.height(12.dp))
            Button(onClick = onDownload, enabled = !saving) { Text(if (saving) "Downloading…" else "Download file") }
        }
    }
}

@Composable
private fun TextFile(content: FileContent.Text, target: LineTarget?) {
    val style = tokenStyle()
    val full = remember(content, style) { highlighted(content.text, content.spans, style) }
    val count = content.lineStarts.size
    val gutter = remember(count) { count.toString().length }
    // Open with a little context above the cited line.
    val state = rememberLazyListState(initialFirstVisibleItemIndex = target?.let { (it.line - 4).coerceIn(0, count - 1) } ?: 0)
    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono)
    val highlight = MaterialTheme.colorScheme.tertiaryContainer
    LazyColumn(Modifier.fillMaxSize(), state = state) {
        items(count, key = { it }) { index ->
            val number = index + 1
            val hit = target != null && number in target
            val text = remember(full, index) {
                val start = content.lineStarts[index]
                full.subSequence(start, lineEnd(content.text, content.lineStarts, index))
            }
            Row(Modifier.fillMaxWidth().then(if (hit) Modifier.background(highlight) else Modifier)
                .testTag(if (hit) FILE_TARGET_TAG else FILE_LINE_TAG)) {
                Text(number.toString().padStart(gutter), Modifier.padding(start = 8.dp, end = 8.dp),
                    style = mono, color = MaterialTheme.colorScheme.outline)
                Text(text.ifEmpty { AnnotatedString(" ") }, Modifier.weight(1f).padding(end = 8.dp), style = mono)
            }
        }
    }
}

private fun AnnotatedString.ifEmpty(other: () -> AnnotatedString) = if (isEmpty()) other() else this

@Composable
private fun MarkdownFile(content: FileContent.Markdown, model: FileViewerModel, onCitation: (FileCitation) -> Unit) {
    val colors = MaterialTheme.colorScheme
    val callback by rememberUpdatedState(onCitation)
    val blocks = remember(content, colors) { markdownBlocks(content.nodes, MdStyle(colors.primary, colors.surfaceVariant)) { callback(it) } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        MarkdownBlocks(blocks, model, Modifier.testTag(FILE_MARKDOWN_TAG))
    }
}

@Composable
private fun ImageFile(bitmap: ImageBitmap) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    Box(Modifier.fillMaxSize().clipToBounds().pointerInput(Unit) {
        detectTransformGestures { _, pan, zoom, _ ->
            scale = (scale * zoom).coerceIn(1f, 8f)
            offset = if (scale == 1f) Offset.Zero else offset + pan
        }
    }, contentAlignment = Alignment.Center) {
        Image(bitmap, contentDescription = "Image", contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize().testTag(FILE_IMAGE_TAG).graphicsLayer {
                scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y
            })
    }
}

/**
 * SVG can carry scripts, so it is shown the way browsers show `<img>` SVG: inside a WebView with
 * JavaScript, network and file access off, as a data URI in an `<img>` (never parsed as a
 * document) under a CSP that only allows that image.
 */
@Composable
private fun SvgFile(base64: String) {
    val background = MaterialTheme.colorScheme.background
    val html = remember(base64, background) {
        val color = String.format("#%06X", background.toArgb() and 0xFFFFFF)
        "<!doctype html><html><head><meta charset=\"utf-8\">" +
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">" +
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=8\">" +
            "<style>html,body{margin:0;height:100%;background:$color}" +
            "body{display:flex;align-items:center;justify-content:center}" +
            // Most SVGs assume a white page (dark ink, no background): back the image like a PDF page.
            "img{max-width:100%;max-height:100%;object-fit:contain;background:#fff}</style></head>" +
            "<body><img alt=\"\" src=\"data:image/svg+xml;base64,$base64\"></body></html>"
    }
    AndroidView(
        modifier = Modifier.fillMaxSize().testTag(FILE_SVG_TAG),
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = false
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.blockNetworkLoads = true
                settings.builtInZoomControls = true
                settings.displayZoomControls = false
                setBackgroundColor(background.toArgb())
            }
        },
        update = { view ->
            if (view.tag != html) { view.tag = html; view.loadDataWithBaseURL(null, html, "text/html", "utf-8", null) }
        },
        onRelease = { it.destroy() },
    )
}

@Composable
private fun PdfFile(document: PdfDocument) {
    BoxWithConstraints(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant)) {
        val widthPx = with(LocalDensity.current) { (maxWidth - 16.dp).roundToPx() }
        LazyColumn(Modifier.fillMaxSize().testTag(FILE_PDF_TAG), contentPadding = PaddingValues(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(document.pageCount, key = { it }) { index ->
                // Pages render lazily as they scroll in and are dropped when they leave.
                val page by produceState<ImageBitmap?>(null, document, index, widthPx) { value = document.render(index, widthPx) }
                Box(Modifier.fillMaxWidth().aspectRatio(document.aspect(index).coerceIn(0.1f, 10f))
                    .background(androidx.compose.ui.graphics.Color.White), contentAlignment = Alignment.Center) {
                    page?.let { Image(it, contentDescription = "Page ${index + 1}", Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                        ?: CircularProgressIndicator(Modifier.size(24.dp))
                }
            }
        }
    }
}

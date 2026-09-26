package dev.verdeai.app

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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
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
    // A cited line is only visible in the source; a plain markdown link opens formatted.
    var formatted by rememberSaveable { mutableStateOf(target == null) }
    val markdown = state.content is FileContent.Markdown
    val subtitle = target?.let { if (it.end != null && it.end > it.line) "Lines ${it.line}–${it.end}" else "Line ${it.line}" }
    FileScaffold(title, subtitle, onBack, actions = {
        if (markdown) TextButton(onClick = { formatted = !formatted }) { Text(if (formatted) "Source" else "Formatted") }
    }) {
        val content = state.content
        val problem = state.problem
        when {
            content != null -> when (content) {
                is FileContent.Text -> TextFile(content, target)
                is FileContent.Markdown -> if (formatted) MarkdownFile(content, model, onCitation) else TextFile(content.source, target)
                is FileContent.Image -> ImageFile(content.bitmap)
                is FileContent.Pdf -> PdfFile(content.document)
            }
            problem != null -> ProblemState(problem, model.limit, if (state.retryable) model::retry else null)
            else -> Centered { CircularProgressIndicator(Modifier.testTag("file-loading")) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FileScaffold(title: String, subtitle: String?, onBack: () -> Unit,
                         actions: @Composable RowScope.() -> Unit = {}, body: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
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
    FileProblem.TooLarge -> "Too large to open" to "This file is over the ${sizeLabel(limit)} limit for viewing on the phone. Open it on the host."
    FileProblem.Forbidden -> "No access" to "This file is outside the host's shared workspaces."
    FileProblem.NotFound -> "File not found" to "It may have been moved or deleted on the host."
    FileProblem.Offline -> "Can't reach the host" to "Check your connection and try again."
    FileProblem.Unsupported -> "Can't show this file" to "The host doesn't serve this file type to the phone."
    FileProblem.PreviewUnavailable -> "No preview available" to "Office previews need LibreOffice on the host."
    FileProblem.Binary -> "Binary file" to "This file isn't text, so it can't be shown here."
    FileProblem.Unresolved -> "Can't open this link" to "The path couldn't be resolved to a file in the workspace."
    FileProblem.PdfNeedsNewerAndroid -> "Needs Android 11" to "PDF viewing needs Android 11 or newer."
    FileProblem.Unreadable -> "Can't display this file" to "The file couldn't be decoded."
    FileProblem.Unavailable -> "Host not connected" to "Reconnect to the host to view files."
    FileProblem.Failed -> "Couldn't open the file" to "Something went wrong loading it."
}

@Composable
private fun ProblemState(problem: FileProblem, limit: Long, onRetry: (() -> Unit)?) {
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
    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
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

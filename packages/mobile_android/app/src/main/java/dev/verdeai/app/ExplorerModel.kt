package dev.verdeai.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * Workspace explorer: the read-only file tree and the workspace-wide Changes list. Everything is
 * read through the host core (`workspace_files_list`, `workspace_file_read`,
 * `workspace_changes_open`, `workspace_file_patch`); the phone never reads workspace files itself.
 * Files are addressed by (root id, root-relative path). Paths and contents are never logged.
 */
internal interface ExplorerConnection {
    val views: StateFlow<Map<String, JsonElement>>
    suspend fun query(selector: String): JsonElement
    suspend fun send(event: (Long, Long) -> Event)
}

internal class HostExplorerConnection(private val host: CoreHost) : ExplorerConnection {
    override val views get() = host.views
    override suspend fun query(selector: String) = host.query(selector)
    override suspend fun send(event: (Long, Long) -> Event) { host.send(event) }
}

internal data class ExplorerState(
    val files: ExplorerFilesView? = null,
    val changes: ExplorerChangesView? = null,
    val patch: ExplorerPatchView? = null,
    /** No core for the selected host (signed out, failed). */
    val unavailable: Boolean = false,
)

/** Chat filter of the Changes list: everything, one claiming chat, or files no chat claimed. */
internal sealed interface ChangesFilter {
    data object All : ChangesFilter
    data object Unassigned : ChangesFilter
    data class Chat(val threadId: String, val title: String) : ChangesFilter
}

internal fun changeOwners(repos: List<GitWorkspaceRepo>): List<ChangesFilter.Chat> =
    repos.flatMap { it.files }.flatMap { it.owners }.distinctBy { it.local_thread_id }
        .map { ChangesFilter.Chat(it.local_thread_id, ownerTitle(it)) }

/** The host always titles owners; the short-id fallback is only a guard. */
internal fun ownerTitle(owner: GitWorkspaceOwner) = owner.title.ifBlank { "Chat ${owner.local_thread_id.takeLast(6)}" }

internal fun GitWorkspaceFile.matches(filter: ChangesFilter) = when (filter) {
    ChangesFilter.All -> true
    ChangesFilter.Unassigned -> owners.isEmpty() || ownership == "unassigned"
    is ChangesFilter.Chat -> owners.any { it.local_thread_id == filter.threadId }
}

/** One-letter git-style status for the file list. */
internal fun changeLetter(file: GitWorkspaceFile) = when {
    file.untracked -> "U"
    file.status == "added" -> "A"
    file.status == "deleted" -> "D"
    file.status == "renamed" -> "R"
    else -> "M"
}

internal fun explorerErrorText(error: LocalError?): String? = error?.let {
    when (it.code) {
        "unsupported", "method_not_found" -> "Update Verde on the computer to use this."
        "scope_denied", "forbidden" -> "This phone isn't allowed to browse workspace files."
        "offline", "cancelled" -> "Connect to the host to refresh."
        "path_outside_roots" -> "This path is outside the workspace folders."
        "not_found" -> "This no longer exists on the host."
        "root_not_found" -> "This folder is no longer part of the workspace."
        "capability_unavailable" -> "Git isn't available for this repository on the host."
        "resource_not_found" -> "This workspace is no longer on the host."
        "resource_limit" -> "Too many folders open. Collapse some and try again."
        "invalid_path" -> "This path can't be opened."
        else -> it.message.ifBlank { "The host couldn't read this workspace." }
    }
}

internal const val FULL_CONTEXT_LINES = 1_000_000L

/** The root id the host gives the workspace home. */
internal const val HOME_ROOT = "home"
internal const val READ_WAIT_MS = 30_000L

/** Absolute host path of a root-relative file, for display, kind detection and download; null when the host sent no root path. */
internal fun ExplorerRoot.absolute(relative: String): String? = path.takeIf { it.startsWith("/") }?.let { it.trimEnd('/') + "/" + relative }

private fun readProblem(problem: FileProblem, retryable: Boolean = false) = FileViewState(loading = false, problem = problem, retryable = retryable)

/** Viewer outcome of a failed `workspace_file_read`; null falls back to the `/api/file` fetch (older hosts). */
internal fun readFailure(code: String?, retryable: Boolean): Any? = when (code) {
    "unsupported", "method_not_found" -> null
    "not_found", "root_not_found", "resource_not_found" -> readProblem(FileProblem.NotFound)
    "path_outside_roots", "scope_denied", "forbidden" -> readProblem(FileProblem.Forbidden)
    "offline", "cancelled", "timeout" -> readProblem(FileProblem.Offline, retryable = true)
    "invalid_path", "invalid_params", "not_file" -> readProblem(FileProblem.Unresolved)
    else -> readProblem(FileProblem.Failed, retryable = true)
}

/**
 * Viewer outcome of a finished `workspace_file` view: the file's bytes, a [FileViewState] problem,
 * or null to fetch through `/api/file` (`external` kinds such as PDFs, and older hosts).
 */
internal fun readOutcome(view: ExplorerFileView): Any? {
    view.error?.let { return readFailure(it.code, it.retryable) }
    if (!view.supported) return null
    val result = view.result ?: return readProblem(FileProblem.Failed, retryable = true)
    return when (result.kind) {
        "text", "markdown", "image" -> when (result.encoding) {
            "base64" -> try { java.util.Base64.getDecoder().decode(result.content) } catch (_: IllegalArgumentException) { readProblem(FileProblem.Unreadable) }
            else -> result.content.encodeToByteArray()
        }
        "binary" -> readProblem(FileProblem.Binary)
        "too_large" -> readProblem(FileProblem.TooLarge)
        else -> null
    }
}

/**
 * Reads one workspace file through the core (`workspace.files.read`), then closes the preview so
 * the body isn't held in core state. Returns what [readOutcome] does; a timeout is retryable.
 */
internal suspend fun readWorkspaceFile(host: CoreHost, workspaceId: String, root: String, path: String, waitMs: Long = READ_WAIT_MS): Any? {
    val intent = UUID.randomUUID().toString()
    return try {
        withTimeoutOrNull(waitMs) {
            host.send { n, w -> EventWorkspaceFileRead(now_ms = n, wall_time_ms = w, intent_id = intent, workspace_id = workspaceId, root = root, path = path) }
            val op = host.operations.map { q -> q?.data?.items?.find { it.intent_id == intent } }.first { it != null && it.state != "pending" }!!
            if (op.state != "succeeded") return@withTimeoutOrNull readFailure(op.error?.code, op.error?.retryable == true)
            val view = CoreJson.decodeFromJsonElement<ExplorerFileQuery>(host.query("workspace_file")).data
            if (view == null || view.root != root || view.path != path) readProblem(FileProblem.Failed, retryable = true) else readOutcome(view)
        } ?: readProblem(FileProblem.Offline, retryable = true)
    } finally {
        withContext(NonCancellable) {
            try { host.send { n, w -> EventWorkspacePreviewClose(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(), workspace_id = workspaceId) } }
            catch (_: Exception) { }
        }
    }
}

internal class ExplorerModel(
    val workspaceId: String,
    private val connect: suspend () -> ExplorerConnection?,
) : ViewModel(), DiffRenderSource {
    private val mutable = MutableStateFlow(ExplorerState())
    val state = mutable.asStateFlow()
    private val connection = CompletableDeferred<ExplorerConnection?>()
    private val renders = RenderCache(64)
    private val filesSelector = "workspace_files:$workspaceId"
    private val changesSelector = "workspace_changes:$workspaceId"
    private var watching = false

    init {
        viewModelScope.launch {
            val c = try { connect() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            connection.complete(c)
            if (c == null) { mutable.update { it.copy(unavailable = true) }; return@launch }
            // Cached projections (a tree opened earlier) show before any new read.
            for (selector in listOf(filesSelector, changesSelector, "workspace_patch")) {
                try { project(selector, c.query(selector)) } catch (e: CancellationException) { throw e } catch (_: Exception) { }
            }
            c.views.collect { views ->
                views[filesSelector]?.let { project(filesSelector, it) }
                views[changesSelector]?.let { project(changesSelector, it) }
                views["workspace_patch"]?.let { project("workspace_patch", it) }
            }
        }
    }

    private fun project(selector: String, value: JsonElement) {
        when (selector) {
            filesSelector -> decode<ExplorerFilesQuery>(value)?.data?.let { v -> mutable.update { it.copy(files = v) } }
            changesSelector -> decode<ExplorerChangesQuery>(value)?.data?.let { v -> mutable.update { it.copy(changes = v) } }
            else -> decode<ExplorerPatchQuery>(value)?.data?.let { v -> mutable.update { it.copy(patch = v) } }
        }
    }

    private fun intent(build: (String, Long, Long) -> Event) {
        viewModelScope.launch {
            val c = connection.await() ?: return@launch
            val id = UUID.randomUUID().toString()
            try { c.send { n, w -> build(id, n, w) } }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { /* The view keeps its last state; the next action retries. */ }
        }
    }

    /** Workspace folders: the home (`home`) and the verde.toml folders. */
    fun loadRoots() = intent { id, n, w -> EventWorkspaceFilesList(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId) }

    /** Lists one folder of [root] ("" is the root itself); the core coalesces a read already in flight. */
    fun list(root: String, path: String) = intent { id, n, w ->
        EventWorkspaceFilesList(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId, root = root, path = path)
    }

    /** Starts watching: the core refreshes on chat turns and foreground while open. */
    fun openChanges() {
        watching = true
        intent { id, n, w -> EventWorkspaceChangesOpen(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId) }
    }

    fun closeChanges() {
        if (!watching) return
        watching = false
        intent { id, n, w -> EventWorkspaceChangesClose(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId) }
    }

    fun openPatch(root: String, path: String, full: Boolean) = intent { id, n, w ->
        EventWorkspaceFilePatch(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = workspaceId, root = root, path = path,
            context_lines = if (full) FULL_CONTEXT_LINES else null)
    }

    /** The shared ask-agent message (client_core `selection_prompt`), or null when the core refuses it. */
    suspend fun prompt(excerpt: SelectionExcerpt, roots: List<ExplorerRoot>, instruction: String): String? {
        val c = connection.await() ?: return null
        val selector = buildJsonObject {
            put("utility", "selection_prompt")
            put("path", excerpt.path)
            put("roots", buildJsonArray {
                roots.forEach { r -> add(buildJsonObject { put("name", r.name); put("path", r.path); put("home", r.home) }) }
            })
            put("start_line", excerpt.start)
            put("end_line", excerpt.end)
            excerpt.side?.let { put("side", it) }
            put("text", excerpt.text)
            put("instruction", instruction)
        }.toString()
        return try {
            val data = c.query(selector).jsonObject["data"] ?: return null
            if (data !is JsonObject) null else data["text"]?.jsonPrimitive?.content
        } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCleared() {
        // Detached: stop the core refreshing this workspace once the screen is gone.
        if (watching) connection.getCompleted()?.let { c ->
            detached.launch {
                try { c.send { n, w -> EventWorkspaceChangesClose(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(), workspace_id = workspaceId) } }
                catch (_: Exception) { }
            }
        }
    }

    // ---- K-11 rendering utilities for the diff screen (pure core queries) ----

    override fun cachedIndex(body: String) = renders.diffIndex[body]
    override suspend fun index(body: String): RenderResult<DiffIndexView> = renders.diffIndex[body] ?: run {
        utility<DiffIndexQuery, DiffIndexView>(buildJsonObject { put("utility", "diff_index"); put("text", body) }.toString(),
            TranscriptModel.MAX_INDEX_SELECTOR) { it.data }.also { renders.diffIndex[body] = it }
    }
    override fun cachedDiff(text: String) = renders.diff[text]
    override suspend fun diff(text: String): RenderResult<DiffView> = renders.diff[text] ?: run {
        utility<DiffQuery, DiffView>(buildJsonObject { put("utility", "diff"); put("text", text) }.toString()) { it.data }
            .also { renders.diff[text] = it }
    }
    override fun cachedHighlight(code: String, language: String) = renders.highlight[language + "\u0000" + code]
    override suspend fun highlight(code: String, language: String): RenderResult<List<RenderSpan>> = renders.highlight[language + "\u0000" + code] ?: run {
        utility<HighlightQuery, List<RenderSpan>>(buildJsonObject { put("utility", "highlight"); put("text", code); put("language", language) }.toString()) { it.data?.spans }
            .also { renders.highlight[language + "\u0000" + code] = it }
    }

    private suspend inline fun <reified Q, T> utility(selector: String, limit: Int = TranscriptModel.MAX_RENDER_SELECTOR, crossinline data: (Q) -> T?): RenderResult<T> {
        if (selector.length > limit) return RenderResult(null)
        val c = connection.await() ?: return RenderResult(null)
        return try {
            val response = c.query(selector)
            withContext(Dispatchers.Default) { RenderResult(data(CoreJson.decodeFromJsonElement<Q>(response))) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { RenderResult(null) }
    }

    private inline fun <reified T> decode(value: JsonElement): T? = try { CoreJson.decodeFromJsonElement<T>(value) } catch (_: Exception) { null }

    companion object {
        private val detached = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }
}

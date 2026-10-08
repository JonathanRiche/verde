package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.verdeai.core.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map

/** One [ExplorerModel] per back-stack entry, bound to the host selected when the screen opened. */
@Composable
internal fun rememberExplorer(hosts: HostsModel, browse: BrowseModel, workspaceId: String): Pair<ExplorerModel, String?> {
    val hostId = remember { browse.state.value.hostId }
    val model: ExplorerModel = viewModel(key = "explorer:$hostId:$workspaceId", factory = viewModelFactory {
        initializer { ExplorerModel(workspaceId) { hostId?.let { hosts.core(it) }?.let(::HostExplorerConnection) } }
    })
    return model to hostId
}

@Composable
private fun ExplorerTopBar(title: String, subtitle: String?, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    VerdeTopBar(showWorkspaceMenu = false,
        title = {
            Column {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium)
                subtitle?.let { Text(it, maxLines = 1, overflow = TextOverflow.StartEllipsis, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted) }
            }
        },
        navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
        actions = actions)
}

@Composable
private fun ExplorerMessage(text: String, onRetry: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text, color = VerdeColors.Muted, style = MaterialTheme.typography.bodyMedium)
        onRetry?.let { TextButton(onClick = it) { Text("Try again") } }
    }
}

// ---------------------------------------------------------------- Changes

@Composable
internal fun ChangesRoute(hosts: HostsModel, browse: BrowseModel, workspaceId: String, onOpenPatch: (root: String, path: String) -> Unit, onBack: () -> Unit) {
    val (model, hostId) = rememberExplorer(hosts, browse, workspaceId)
    val browseState by browse.state.collectAsState()
    val workspace = browseState.workspaces?.items?.find { it.workspace_id == workspaceId }
    val gitClient = LocalGitChangesClient.current
    var commit by remember { mutableStateOf<Pair<String, Int>?>(null) }
    Box(Modifier.fillMaxSize()) {
        ChangesScreen(model, workspace?.label, workspace?.threads.orEmpty(), onOpenPatch,
            onCommit = if (gitClient == null) null else { thread -> commit = thread to ((commit?.second ?: 0) + 1) }, onBack = onBack)
        val target = commit
        if (target != null && gitClient != null) key(target.first) {
            val git: GitChangesModel = viewModel(key = "git:$hostId:${System.identityHashCode(gitClient)}:$workspaceId:${target.first}",
                factory = viewModelFactory { initializer { GitChangesModel(GitChat(workspaceId, target.first), gitClient) } })
            LaunchedEffect(git) { git.focus() }
            LaunchedEffect(target) { git.open() }
            // Changes aren't pushed: refetch once a commit finishes or the sheet closes.
            LaunchedEffect(git) {
                git.state.map { it.busy || it.sheet }.distinctUntilChanged().drop(1).filter { !it }.collect { model.openChanges() }
            }
            GitChangesLayer(git)
        }
    }
}

@Composable
internal fun ChangesScreen(
    model: ExplorerModel,
    label: String?,
    threads: List<ThreadSummary>,
    onOpenPatch: (root: String, path: String) -> Unit,
    onCommit: ((thread: String) -> Unit)?,
    onBack: () -> Unit,
) {
    val state by model.state.collectAsState()
    DisposableEffect(model) {
        model.openChanges()
        onDispose { model.closeChanges() }
    }
    val changes = state.changes
    val repos = changes?.repos.orEmpty()
    val owners = remember(repos, threads) {
        // The ledger's title wins; a chat the catalog knows by a better name fills a blank one.
        changeOwners(repos).map { o -> if (o.title.startsWith("Chat ")) threads.find { it.thread_id == o.threadId }?.title?.takeIf { it.isNotBlank() }?.let { o.copy(title = it) } ?: o else o }
    }
    var filter by remember { mutableStateOf<ChangesFilter>(ChangesFilter.All) }
    if (filter is ChangesFilter.Chat && owners.none { it.threadId == (filter as ChangesFilter.Chat).threadId }) filter = ChangesFilter.All
    val files = repos.sumOf { it.files.size }
    val unassigned = repos.sumOf { r -> r.files.count { it.matches(ChangesFilter.Unassigned) } }
    Column(Modifier.fillMaxSize().testTag(CHANGES_TAG)) {
        ExplorerTopBar("Changes", label, onBack) {
            if (changes?.loading == true) CircularProgressIndicator(Modifier.padding(12.dp).size(20.dp), strokeWidth = 2.dp)
            else IconButton(onClick = model::openChanges) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh changes") }
        }
        if (repos.isNotEmpty()) LazyRow(Modifier.fillMaxWidth().padding(vertical = 6.dp), contentPadding = PaddingValues(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            item { FilterChip(filter == ChangesFilter.All, { filter = ChangesFilter.All }, label = { Text("All · $files") }) }
            items(owners, key = { it.threadId }) { owner ->
                val count = repos.sumOf { r -> r.files.count { it.matches(owner) } }
                FilterChip(filter == owner, { filter = owner }, label = { Text("${owner.title} · $count", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    modifier = Modifier.widthIn(max = 220.dp).testTag("changes-filter-${owner.threadId}"))
            }
            if (unassigned > 0) item {
                FilterChip(filter == ChangesFilter.Unassigned, { filter = ChangesFilter.Unassigned }, label = { Text("Unassigned · $unassigned") },
                    modifier = Modifier.testTag("changes-filter-unassigned"))
            }
        }
        explorerErrorText(changes?.error)?.let { error ->
            if (repos.isNotEmpty()) Text(error, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = VerdeColors.Warning, style = MaterialTheme.typography.bodySmall)
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                state.unavailable -> ExplorerMessage("Connect to a host to see changes.")
                changes?.supported == false -> ExplorerMessage(explorerErrorText(LocalError(code = "unsupported", message = ""))!!)
                repos.isEmpty() && changes?.error != null -> ExplorerMessage(explorerErrorText(changes.error)!!, model::openChanges)
                changes == null || (!changes.loaded && changes.loading) || (!changes.loaded && changes.error == null) ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.testTag("changes-loading")) }
                repos.all { it.files.isEmpty() && !it.too_many_files } -> ExplorerMessage("No uncommitted changes.")
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    repos.forEach { repo ->
                        val shown = repo.files.filter { it.matches(filter) }
                        if (shown.isEmpty() && !repo.too_many_files) return@forEach
                        item(key = "repo:${repo.root}") { RepoHeader(repo, repos.size > 1) }
                        if (repo.too_many_files) item(key = "many:${repo.root}") {
                            Text("Too many changed files to list here. Review them on the computer.",
                                Modifier.padding(horizontal = 16.dp, vertical = 6.dp), color = VerdeColors.Muted, style = MaterialTheme.typography.bodySmall)
                        }
                        items(shown, key = { "file:${repo.root.length}:${repo.root}${it.path}" }) { file ->
                            ChangeRow(file) { onOpenPatch(repo.root, file.path) }
                        }
                    }
                    if (repos.none { r -> r.files.any { it.matches(filter) } || r.too_many_files }) item { ExplorerMessage("No changes for this filter.") }
                }
            }
        }
        if (onCommit != null && repos.any { it.files.isNotEmpty() }) CommitBar(filter, owners, onCommit)
    }
}

@Composable
private fun RepoHeader(repo: GitWorkspaceRepo, showName: Boolean) {
    Row(Modifier.fillMaxWidth().background(VerdeColors.PanelAlt).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            if (showName) Text(repo.name, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
            Text(listOfNotNull(repo.branch ?: repo.head?.take(8)?.let { "detached $it" },
                repo.ahead.takeIf { it > 0 }?.let { "↑$it" }, repo.behind.takeIf { it > 0 }?.let { "↓$it" }).joinToString(" · "),
                style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted)
        }
        val add = repo.files.sumOf { it.additions }
        val del = repo.files.sumOf { it.deletions }
        Text("${repo.files.size} · +$add −$del", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted)
    }
}

@Composable
private fun ChangeRow(file: GitWorkspaceFile, onClick: () -> Unit) {
    val letter = changeLetter(file)
    val color = when (letter) { "A", "U" -> VerdeColors.DiffAdd; "D" -> VerdeColors.Danger; else -> VerdeColors.Warning }
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp).testTag("change-${file.path}"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(letter, Modifier.width(14.dp), color = color, style = MaterialTheme.typography.labelLarge.copy(fontFamily = VerdeMono))
        Column(Modifier.weight(1f)) {
            Text(basename(file.path), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
            val dir = file.path.substringBeforeLast('/', "")
            if (dir.isNotEmpty()) Text(dir, maxLines = 1, overflow = TextOverflow.StartEllipsis, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
        }
        file.owners.firstOrNull()?.let { owner ->
            val more = if (file.owners.size > 1) " +${file.owners.size - 1}" else ""
            Text(ownerTitle(owner) + more + if (owner.unclear) "?" else "",
                Modifier.widthIn(max = 120.dp).background(VerdeColors.PanelMuted, RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
                maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted)
        }
        if (file.binary) Text("binary", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
        else Text(buildString { append("+${file.additions}"); append(" −${file.deletions}") },
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = VerdeMono), color = VerdeColors.Muted)
    }
}

/** Commit uses the chat-scoped commit flow; with no chat filter, the user picks the chat first. */
@Composable
private fun CommitBar(filter: ChangesFilter, owners: List<ChangesFilter.Chat>, onCommit: (String) -> Unit) {
    var picking by remember { mutableStateOf(false) }
    Surface(color = VerdeColors.Panel, tonalElevation = 2.dp) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(when (filter) {
                is ChangesFilter.Chat -> "Commit what ${filter.title} changed"
                ChangesFilter.Unassigned -> "Unassigned files are committed from the computer"
                ChangesFilter.All -> if (owners.isEmpty()) "No chat claimed these files" else "Commits go through a chat"
            }, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Box {
                Button(onClick = { if (filter is ChangesFilter.Chat) onCommit(filter.threadId) else picking = true },
                    enabled = filter is ChangesFilter.Chat || (filter == ChangesFilter.All && owners.isNotEmpty()),
                    modifier = Modifier.testTag(CHANGES_COMMIT_TAG)) { Text(if (filter is ChangesFilter.Chat) "Commit" else "Commit…") }
                DropdownMenu(picking, onDismissRequest = { picking = false }) {
                    owners.forEach { owner ->
                        DropdownMenuItem(text = { Text(owner.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            onClick = { picking = false; onCommit(owner.threadId) }, modifier = Modifier.testTag("commit-as-${owner.threadId}"))
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- Files

@Composable
internal fun FilesRoute(hosts: HostsModel, browse: BrowseModel, workspaceId: String, onOpenFile: (root: ExplorerRoot, path: String) -> Unit, onBack: () -> Unit) {
    val (model, _) = rememberExplorer(hosts, browse, workspaceId)
    val label = browse.state.collectAsState().value.workspaces?.items?.find { it.workspace_id == workspaceId }?.label
    FilesScreen(model, label, onOpenFile, onBack)
}

/** Key of one folder: root id and root-relative path ("" is the root itself). */
internal fun dirKey(root: String, path: String) = "$root\u0000$path"

/** One visible row of the flattened tree. */
internal sealed interface TreeRow {
    val key: String
    data class Root(val root: ExplorerRoot, val open: Boolean) : TreeRow { override val key get() = "root:${root.id}" }
    data class Item(val root: String, val entry: ExplorerEntry, val depth: Int, val open: Boolean) : TreeRow {
        override val key get() = "entry:${dirKey(root, entry.path)}"
    }
    data class Note(val root: String, val path: String, val depth: Int, val text: String, val retry: Boolean, val loading: Boolean = false) : TreeRow {
        override val key get() = "note:${dirKey(root, path)}"
    }
}

/** Flattens the roots and every expanded, listed folder into rows (depth-first, listing order). */
internal fun treeRows(view: ExplorerFilesView?, expanded: Set<String>): List<TreeRow> {
    if (view == null) return emptyList()
    val dirs = view.dirs.associateBy { dirKey(it.root, it.path) }
    val out = mutableListOf<TreeRow>()
    fun folder(root: String, path: String, depth: Int) {
        val dir = dirs[dirKey(root, path)]
        when {
            dir == null || (dir.loading && !dir.loaded) -> out += TreeRow.Note(root, path, depth, "Loading…", retry = false, loading = true)
            dir.error != null && !dir.loaded -> out += TreeRow.Note(root, path, depth, explorerErrorText(dir.error)!!, retry = true)
            else -> {
                if (dir.entries.isEmpty()) out += TreeRow.Note(root, path, depth, "Empty folder", retry = false)
                for (entry in dir.entries) {
                    val open = entry.kind == "directory" && dirKey(root, entry.path) in expanded
                    out += TreeRow.Item(root, entry, depth, open)
                    if (open) folder(root, entry.path, depth + 1)
                }
                if (dir.truncated) out += TreeRow.Note(root, "$path\u0000more", depth, "Showing the first ${dir.entries.size} entries", retry = false)
            }
        }
    }
    for (root in view.roots) {
        val open = dirKey(root.id, "") in expanded
        out += TreeRow.Root(root, open)
        if (open) folder(root.id, "", 1)
    }
    return out
}

private val expandedSaver = listSaver<MutableState<Set<String>>, String>({ it.value.toList() }, { mutableStateOf(it.toSet()) })

@Composable
internal fun FilesScreen(model: ExplorerModel, label: String?, onOpenFile: (root: ExplorerRoot, path: String) -> Unit, onBack: () -> Unit) {
    val state by model.state.collectAsState()
    val files = state.files
    var expanded by rememberSaveable(saver = expandedSaver) { mutableStateOf(emptySet()) }
    var seeded by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(model) { model.loadRoots() }
    // The home folder starts open; everything else opens on tap.
    LaunchedEffect(files?.roots) {
        if (!seeded && files?.roots?.isNotEmpty() == true) {
            seeded = true
            expanded = expanded + dirKey((files.roots.firstOrNull { it.home } ?: files.roots.first()).id, "")
        }
    }
    fun list(key: String) { val (root, path) = key.split('\u0000', limit = 2); model.list(root, path) }
    // Expanded folders the core hasn't listed (first open, or a cache wiped by sign-out) load now.
    LaunchedEffect(expanded, files?.dirs?.map { dirKey(it.root, it.path) }) {
        val listed = files?.dirs.orEmpty().map { dirKey(it.root, it.path) }.toSet()
        if (files?.loaded == true) expanded.filter { it !in listed }.forEach(::list)
    }
    fun toggle(key: String) { expanded = if (key in expanded) expanded - key else expanded + key }
    val rows = remember(files, expanded) { treeRows(files, expanded) }
    Column(Modifier.fillMaxSize().testTag(FILES_TAG)) {
        ExplorerTopBar("Files", label, onBack) {
            IconButton(onClick = { model.loadRoots(); expanded.forEach(::list) }) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh files") }
        }
        when {
            state.unavailable -> ExplorerMessage("Connect to a host to browse files.")
            files?.supported == false -> ExplorerMessage(explorerErrorText(LocalError(code = "unsupported", message = ""))!!)
            files?.roots.isNullOrEmpty() && files?.error != null -> ExplorerMessage(explorerErrorText(files.error)!!, model::loadRoots)
            files == null || !files.loaded -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.testTag("files-loading")) }
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(rows, key = { it.key }) { row ->
                    when (row) {
                        is TreeRow.Root -> TreeLine(0, row.open, true, row.root.name, null, false, Modifier.testTag("files-root-${row.root.name}")) {
                            toggle(dirKey(row.root.id, ""))
                        }
                        is TreeRow.Item -> {
                            val dir = row.entry.kind == "directory"
                            TreeLine(row.depth, row.open, dir, row.entry.name + if (row.entry.symlink) " ↗" else "",
                                if (dir) null else entrySize(row.entry.size.toLong()), row.entry.ignored, Modifier.testTag("files-entry-${row.entry.path}")) {
                                if (dir) toggle(dirKey(row.root, row.entry.path))
                                else files.roots.find { it.id == row.root }?.let { onOpenFile(it, row.entry.path) }
                            }
                        }
                        is TreeRow.Note -> Row(Modifier.fillMaxWidth().padding(start = (16 + 16 * row.depth).dp, end = 16.dp, top = 4.dp, bottom = 4.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            if (row.loading) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            Text(row.text, Modifier.weight(1f).padding(start = 8.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
                            if (row.retry) TextButton(onClick = { model.list(row.root, row.path) }) { Text("Retry") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TreeLine(depth: Int, open: Boolean, folder: Boolean, name: String, detail: String?, ignored: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().clickable(onClick = onClick).alpha(if (ignored) 0.5f else 1f)
        .padding(start = (8 + 16 * depth).dp, end = 16.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (folder) Icon(if (open) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = if (open) "Collapse" else "Expand", Modifier.size(20.dp), tint = VerdeColors.Muted)
        else Spacer(Modifier.width(20.dp))
        Spacer(Modifier.width(6.dp))
        Text(name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = if (depth == 0) MaterialTheme.typography.labelLarge else MaterialTheme.typography.bodyMedium,
            fontWeight = if (folder) FontWeight.Medium else FontWeight.Normal)
        detail?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle) }
    }
}

// ---------------------------------------------------------------- Patch

@Composable
internal fun PatchRoute(hosts: HostsModel, browse: BrowseModel, workspaceId: String, root: String, path: String,
    onOpenFile: (FileCitation) -> Unit, onOpenThread: (String, String) -> Unit, onBack: () -> Unit) {
    val (model, hostId) = rememberExplorer(hosts, browse, workspaceId)
    val workspace = browse.state.collectAsState().value.workspaces?.items?.find { it.workspace_id == workspaceId }
    val repoName = model.state.collectAsState().value.changes?.repos?.find { it.root == root }?.name
    val absolute = root.trimEnd('/') + "/" + path
    // Diff selections read "<repo>/<path>" unless the repository is the workspace home.
    val roots = remember(root, repoName, workspace?.path) {
        listOf(ExplorerRoot(root, repoName ?: basename(root.trimEnd('/')), root, home = workspace?.path?.trimEnd('/') == root.trimEnd('/')))
    }
    SelectionScope(model, hostId, absolute, workspace, onOpenThread, roots) {
        PatchScreen(model, root, path, onOpenFile, onBack)
    }
}

private sealed interface PatchItem {
    data class Header(val hunk: Int) : PatchItem
    data class Line(val hunk: Int, val row: Int, val position: Int) : PatchItem
}

@Composable
internal fun PatchScreen(model: ExplorerModel, root: String, path: String, onOpenFile: (FileCitation) -> Unit, onBack: () -> Unit) {
    val state by model.state.collectAsState()
    var full by rememberSaveable { mutableStateOf(false) }
    var wrap by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(root, path, full) { model.openPatch(root, path, full) }
    val view = state.patch?.takeIf { it.root == root && it.path == path }
    val result = view?.result
    val patch = result?.patch
    val render by produceState<DiffFileRender?>(null, patch) { value = if (patch.isNullOrEmpty()) null else renderDiffFile(model, DiffRecord(patch, patch), path) }
    val absolute = root.trimEnd('/') + "/" + path
    Column(Modifier.fillMaxSize().testTag(PATCH_TAG)) {
        ExplorerTopBar(basename(path), path.substringBeforeLast('/', "").ifEmpty { null }, onBack) {
            FilterChip(full, { full = !full }, label = { Text("Full file") }, modifier = Modifier.testTag("patch-full"))
            TextButton(onClick = {
                val line = (render as? DiffFileRender.Parsed)?.model?.let(::firstNewLine)
                onOpenFile(FileCitation(absolute, line, null))
            }, enabled = result?.status != "deleted") { Text("Open") }
        }
        result?.let { r ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("+${r.additions} −${r.deletions}" + if (r.truncated) " · truncated" else "", Modifier.weight(1f),
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = VerdeMono), color = VerdeColors.Muted)
                TextButton(onClick = { wrap = !wrap }) { Text(if (wrap) "No wrap" else "Wrap") }
            }
        }
        if (view?.loading == true && result != null) LinearProgressIndicator(Modifier.fillMaxWidth())
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                state.unavailable -> ExplorerMessage("Connect to a host to see this diff.")
                view?.supported == false -> ExplorerMessage(explorerErrorText(LocalError(code = "unsupported", message = ""))!!)
                view?.error != null && result == null -> ExplorerMessage(explorerErrorText(view.error)!!, { model.openPatch(root, path, full) })
                result == null ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.testTag("patch-loading")) }
                result.clean -> ExplorerMessage("No uncommitted changes in this file now.")
                result.binary -> ExplorerMessage("Binary file changed.")
                patch.isNullOrEmpty() -> ExplorerMessage("No diff to show.")
                else -> when (val r = render) {
                    null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                    is DiffFileRender.Source -> Text(r.patch, Modifier.fillMaxSize().horizontalScroll(rememberScrollState()).padding(8.dp),
                        style = diffTextStyle())
                    is DiffFileRender.Parsed -> PatchLines(r.model, wrap)
                }
            }
        }
    }
}

@Composable
private fun PatchLines(model: DiffFileModel, wrap: Boolean) {
    val palette = diffPalette()
    val syntax = tokenStyle()
    val colors = MaterialTheme.colorScheme
    val rows = remember(model) { model.hunks.flatMap { it.rows } }
    val items = remember(model) {
        var position = 0
        buildList {
            model.hunks.forEachIndexed { h, hunk ->
                add(PatchItem.Header(h))
                hunk.rows.indices.forEach { add(PatchItem.Line(h, it, ++position)) }
            }
        }
    }
    val list = rememberLazyListState()
    val selection = LocalLineSelection.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val scroll = if (wrap) Modifier.fillMaxSize() else Modifier.horizontalScroll(rememberScrollState()).width(maxWidth * 3).fillMaxHeight()
        LazyColumn(scroll.lineGestures(selection, list, model.numberWidth * 2 + 4, { it.key as? Int }) { diffLines(rows, it) }, state = list) {
            items(items, key = { if (it is PatchItem.Line) it.position else "h${(it as PatchItem.Header).hunk}" }, contentType = { it::class }) { item ->
                when (item) {
                    is PatchItem.Header -> Text(model.hunks[item.hunk].header,
                        Modifier.fillMaxWidth().background(colors.secondaryContainer.copy(alpha = 0.45f)).padding(horizontal = 8.dp, vertical = 4.dp),
                        style = MaterialTheme.typography.labelSmall.copy(fontFamily = VerdeMono), color = colors.onSecondaryContainer)
                    is PatchItem.Line -> {
                        val row = model.hunks[item.hunk].rows[item.row]
                        val chunk = remember(row, palette, syntax) { diffChunk(listOf(row), model.numberWidth, palette, syntax) }
                        val picked = selection?.contains(item.position) == true
                        DiffChunkText(chunk, model.numberWidth, wrap, palette,
                            Modifier.fillMaxWidth().then(if (picked) Modifier.background(SelectedLineColor) else Modifier).testTag(PATCH_LINE_TAG))
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- File viewer with selection

/**
 * A file opened from the Files tab: read through `workspace.files.read` by (root id, relative
 * path); [absolute] (from the root's host path, may be empty) names it for download and asking.
 */
@Composable
internal fun WorkspaceFileRoute(hosts: HostsModel, browse: BrowseModel, workspaceId: String, root: String, path: String, absolute: String,
    onCitation: (FileCitation) -> Unit, onOpenThread: (String, String) -> Unit, onBack: () -> Unit) {
    val (explorer, hostId) = rememberExplorer(hosts, browse, workspaceId)
    val workspace = browse.state.collectAsState().value.workspaces?.items?.find { it.workspace_id == workspaceId }
    val model: FileViewerModel = viewModel(key = "wfile:$hostId:$workspaceId:${dirKey(root, path)}", factory = viewModelFactory {
        initializer { FileViewerModel(hosts, hostId, absolute.ifEmpty { path }, reader = { host -> readWorkspaceFile(host, workspaceId, root, path) }) }
    })
    SelectionScope(explorer, hostId, absolute.ifEmpty { null }, workspace, onOpenThread) {
        FileViewerScreen(model, null, onCitation, onBack, title = basename(path))
    }
}

/** The FILE route with ask-agent line selection around the existing viewer. */
@Composable
internal fun SelectableFileRoute(hosts: HostsModel, browse: BrowseModel, workspaceId: String, rawPath: String, line: Long?, endLine: Long?,
    onCitation: (FileCitation) -> Unit, onOpenThread: (String, String) -> Unit, onBack: () -> Unit) {
    val (model, hostId) = rememberExplorer(hosts, browse, workspaceId)
    val workspace = browse.state.collectAsState().value.workspaces?.items?.find { it.workspace_id == workspaceId }
    val resolved = remember(rawPath, workspace?.path) { resolveFilePath(rawPath, workspace?.path) }
    SelectionScope(model, hostId, resolved, workspace, onOpenThread) {
        FileRoute(hosts, browse, workspaceId, rawPath, line, endLine, onCitation, onBack)
    }
}

internal const val CHANGES_TAG = "changes-screen"
internal const val CHANGES_COMMIT_TAG = "changes-commit"
internal const val FILES_TAG = "files-screen"
internal const val PATCH_TAG = "patch-screen"
internal const val PATCH_LINE_TAG = "patch-line"

internal fun entrySize(bytes: Long) = if (bytes < 1024) "$bytes B" else sizeLabel(bytes)

/** "Changes · Files" entry points (drawer and workspace screen); [workspace] names the target when ambiguous. */
@Composable
internal fun ExplorerLinks(onChanges: () -> Unit, onFiles: () -> Unit, workspace: String? = null, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        AssistChip(onClick = onChanges, label = { Text("Changes") }, modifier = Modifier.testTag(EXPLORER_CHANGES_LINK))
        AssistChip(onClick = onFiles, label = { Text("Files") }, modifier = Modifier.testTag(EXPLORER_FILES_LINK))
        workspace?.let { Text(it, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle) }
    }
}

internal const val EXPLORER_CHANGES_LINK = "explorer-changes"
internal const val EXPLORER_FILES_LINK = "explorer-files"

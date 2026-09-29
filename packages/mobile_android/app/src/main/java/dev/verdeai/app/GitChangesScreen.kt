package dev.verdeai.app

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

/** Shared host-scoped core boundary; null while no host is selected. */
internal val LocalGitChangesClient = staticCompositionLocalOf<GitChangesClient?> { null }

@Composable
internal fun GitChangesDot(chat: GitChat) {
    val client = LocalGitChangesClient.current ?: return
    val snapshot by client.snapshot.collectAsState()
    val summary = snapshot.summaries[chat] ?: return
    if (summary.files > 0) Box(Modifier.size(7.dp).background(
        if (summary.attention > 0) VerdeColors.Warning else VerdeColors.Accent, CircleShape)
        .semantics { contentDescription = if (summary.attention > 0) "Uncommitted changes need attention" else "Uncommitted changes" })
}

/** A second compact header row keeps the split action usable on a narrow phone. */
@Composable
internal fun GitChangesHeader(model: GitChangesModel) {
    val state by model.state.collectAsState()
    val access = state.snapshot.access[model.chat] ?: GitAccess.Unavailable
    val summary = state.snapshot.summaries[model.chat] ?: GitSummary()
    val branches = state.snapshot.branches[model.chat].orEmpty()
    val ahead = branches.filter { it.hasRemote }.sumOf { it.ahead }
    if (access == GitAccess.Unavailable) return
    if (access == GitAccess.Remote) {
        Text(access.reason!!, Modifier.padding(horizontal = 16.dp, vertical = 6.dp), color = VerdeColors.Subtle, style = MaterialTheme.typography.bodySmall)
        return
    }
    if (summary.files == 0 && ahead == 0 && state.rejectedRoots.isEmpty()) return
    var menu by remember { mutableStateOf(false) }
    val writable = access == GitAccess.Writable
    val label = if (!writable) "Changes" else if (summary.files == 0) "↑$ahead Push" else state.snapshot.settings.action.label
    val color = if (summary.attention > 0) VerdeColors.Warning else VerdeColors.Accent
    Column(Modifier.fillMaxWidth().background(VerdeColors.Panel).padding(horizontal = 12.dp, vertical = 4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (summary.files > 0) "+${summary.additions}  −${summary.deletions}" else "Unpushed commits",
                Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = VerdeColors.Muted)
            Surface(shape = RoundedCornerShape(7.dp), border = BorderStroke(1.dp, color.copy(alpha = .5f)), color = color.copy(alpha = .10f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = {
                        if (!writable) model.open(GitAction.Commit)
                        else if (summary.files == 0) model.push()
                        else model.open(state.snapshot.settings.action, quick = state.snapshot.settings.action == GitAction.CommitAndPush)
                    }, enabled = !state.busy && !state.loading && state.snapshot.connected, modifier = Modifier.testTag("git-primary")) {
                        Text(if (state.checking) "Checking commit…" else if (state.busy) "Working…" else label, color = color)
                        if (summary.files > 0) Text(summary.files.toString(), Modifier.padding(start = 8.dp).background(color.copy(alpha = .16f), CircleShape).padding(horizontal = 6.dp, vertical = 2.dp), color = color)
                    }
                    if (writable) Box {
                        IconButton(onClick = { menu = true }, enabled = !state.busy && !state.loading && state.snapshot.connected, modifier = Modifier.size(44.dp)) {
                            Icon(Icons.Filled.KeyboardArrowDown, "Git actions", tint = color)
                        }
                        DropdownMenu(menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text("Commit…") }, enabled = summary.files > 0, onClick = { menu = false; model.open(GitAction.Commit) })
                            DropdownMenuItem(text = { Text("Commit & push") }, enabled = summary.files > 0, onClick = { menu = false; model.open(GitAction.CommitAndPush, true) })
                            DropdownMenuItem(text = { Text("Push") }, enabled = branches.any { it.ahead > 0 && it.hasRemote }, onClick = { menu = false; model.push() })
                            if (state.rejectedRoots.isNotEmpty()) DropdownMenuItem(text = { Text("Pull & push") }, onClick = { menu = false; model.push(true) })
                        }
                    }
                }
            }
        }
        if (state.canRetry) TextButton(onClick = model::retry) { Text("Check again") }
        if (!writable) Text(access.reason!!, style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun GitChangesLayer(model: GitChangesModel) {
    val state by model.state.collectAsState()
    val snack = remember { SnackbarHostState() }
    val committing by rememberUpdatedState(state.busy)
    LaunchedEffect(state.notice) {
        state.notice?.let { notice ->
            val result = snack.showSnackbar(notice.text, actionLabel = if (notice.rejectedRoots.isNotEmpty()) "Pull & push" else null,
                withDismissAction = true, duration = if (notice.rejectedRoots.isNotEmpty()) SnackbarDuration.Indefinite else SnackbarDuration.Long)
            model.dismissNotice()
            if (result == SnackbarResult.ActionPerformed) model.push(true)
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) { SnackbarHost(snack, Modifier.imePadding().padding(12.dp)) }
    if (state.preparing || state.confirmingMain) {
        val branches = state.review?.repos.orEmpty().filter { it.files.isNotEmpty() && it.branch.defaultOrMain }.mapNotNull { it.branch.branch }.distinct().joinToString(", ")
        AlertDialog(onDismissRequest = model::dismiss,
            title = { Text(if (state.confirmingMain) "Commit & push to $branches?" else "Preparing commit…") },
            text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.loading || state.generating) LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(if (state.loading) "Reviewing this chat's changes…" else "${state.fileCount} ${if (state.fileCount == 1) "file" else "files"} · ${state.message.lineSequence().firstOrNull().orEmpty().ifEmpty { "Generating a message…" }}")
                if (state.messageError) {
                    Text("Couldn't generate a message.", color = VerdeColors.Warning)
                    TextButton(onClick = model::regenerate) { Text("Regenerate message") }
                }
                if (state.canRetry) TextButton(onClick = model::retry) { Text("Check again") }
                if (state.checking && !state.confirmingMain) Text("Checking commit…", color = VerdeColors.Muted)
                state.generated?.branch?.let { Text("New branch · $it", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted) }
                if (state.confirmingMain) TextButton(onClick = { model.commit(newBranch = true) }, enabled = model.canCommit()) { Text("Create branch & continue") }
            } },
            confirmButton = { if (state.confirmingMain) TextButton(onClick = { model.commit() }, enabled = model.canCommit(), modifier = Modifier.testTag("git-confirm-main")) { Text(if (state.checking) "Checking commit…" else if (state.busy) "Committing…" else "Commit & push to $branches") } },
            dismissButton = { TextButton(onClick = model::dismiss, enabled = !state.busy) { Text("Abort") } })
    }
    if (state.sheet) {
        ModalBottomSheet(onDismissRequest = model::dismiss,
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { !committing }),
            containerColor = VerdeColors.Panel, modifier = Modifier.testTag("git-sheet")) {
            GitCommitSheet(model, state)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun GitCommitSheet(model: GitChangesModel, state: GitChangesState) {
    val writable = state.snapshot.access[model.chat] == GitAccess.Writable
    Column(Modifier.fillMaxWidth().fillMaxHeight(.92f).imePadding().padding(horizontal = 16.dp)) {
        Text("Commit changes", style = MaterialTheme.typography.titleLarge)
        Text("Review this chat's changes before saving a commit.", color = VerdeColors.Muted, style = MaterialTheme.typography.bodySmall)
        if (!writable) Text((state.snapshot.access[model.chat] ?: GitAccess.ReadOnly).reason.orEmpty(), color = VerdeColors.Warning, style = MaterialTheme.typography.bodySmall)
        if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 12.dp))
        if (state.review?.turnRunning == true) Text("Frozen snapshot — this chat is still working. Later changes are not included.",
            Modifier.padding(vertical = 8.dp), color = VerdeColors.Warning, style = MaterialTheme.typography.bodySmall)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            state.review?.repos.orEmpty().forEach { repo ->
                item(key = "branch:${repo.branch.root}") { GitBranchCard(repo.branch) }
                items(repo.files, key = { "file:${repo.branch.root.length}:${repo.branch.root}${it.path}" }) { file -> GitFileRow(model, state, repo, file, writable) }
            }
            if (state.review != null && state.review.repos.all { it.files.isEmpty() }) item { Text("No uncommitted changes for this chat.", Modifier.padding(vertical = 16.dp), color = VerdeColors.Muted) }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("${state.fileCount} files · +${state.totals.first} −${state.totals.second}", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium)
            TextButton(onClick = { model.edit(!state.editing) }, enabled = !state.busy, modifier = Modifier.testTag("git-edit")) { Text(if (state.editing) "Hide diffs" else "Show diffs") }
        }
        if (writable) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("COMMIT MESSAGE", Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
                if (state.generating) Text("Generating…", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
                IconButton(onClick = model::regenerate, enabled = !state.busy && !state.generating && state.fileCount > 0) { Icon(Icons.Filled.Refresh, "Regenerate commit message") }
            }
            OutlinedTextField(state.typedMessage, onValueChange = model::message, modifier = Modifier.fillMaxWidth().testTag("git-message"),
                enabled = !state.busy, minLines = 2, maxLines = 4,
                placeholder = { Text(state.generated?.message ?: if (state.generating) "Generating a commit message…" else "Describe these changes") })
            state.generated?.let { Text("${it.provider} · ${it.model}", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle) }
            if (state.messageError) Text("Couldn't generate a message. Write one or regenerate.", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Warning)
        }
        if (state.canRetry) TextButton(onClick = model::retry) { Text("Check again") }
        state.error?.let { Text(it, Modifier.padding(vertical = 6.dp).semantics { liveRegion = LiveRegionMode.Polite }, color = VerdeColors.Warning, style = MaterialTheme.typography.bodySmall) }
        if (state.review == null && !state.loading) TextButton(onClick = { model.open(state.action) }) { Text("Refresh review") }
        val alternate = if (state.action == GitAction.Commit) GitAction.CommitAndPush else GitAction.Commit
        fun label(action: GitAction, newBranch: Boolean = false): String {
            val active = state.busy && state.submittingAction == action && state.submittingNewBranch == newBranch
            return when {
                active && state.checking -> "Checking commit…"
                active && state.generating -> "Writing message…"
                active -> "Committing…"
                newBranch -> "New branch"
                else -> action.label
            }
        }
        FlowRow(Modifier.fillMaxWidth().padding(bottom = 16.dp), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = model::dismiss, enabled = !state.busy) { Text("Cancel") }
            if (writable) {
                TextButton(onClick = { model.commit(newBranch = true) }, enabled = model.canCommit(), modifier = Modifier.testTag("git-new-branch")) { Text(label(state.action, true)) }
                if (alternate == GitAction.Commit || state.review?.repos.orEmpty().any { it.branch.hasRemote }) {
                    TextButton(onClick = { model.commit(action = alternate) }, enabled = model.canCommit(), modifier = Modifier.testTag("git-alternate")) { Text(label(alternate)) }
                }
                Button(onClick = { model.commit() }, enabled = model.canCommit(), shape = RoundedCornerShape(7.dp), modifier = Modifier.testTag("git-submit")) { Text(label(state.action)) }
            }
        }
    }
}

@Composable
private fun GitBranchCard(branch: GitBranch) {
    val color = if (branch.defaultOrMain) VerdeColors.Warning else VerdeColors.Muted
    Surface(color = color.copy(alpha = .07f), border = BorderStroke(1.dp, color.copy(alpha = .25f)), shape = RoundedCornerShape(10.dp), modifier = Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 4.dp)) {
        Column(Modifier.padding(12.dp)) {
            Text("BRANCH · ${branch.name}", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
            Text(branch.branch ?: "Detached HEAD", style = MaterialTheme.typography.titleSmall, color = color)
            if (branch.defaultOrMain) Text("Default branch", style = MaterialTheme.typography.bodySmall, color = color)
        }
    }
}

@Composable
private fun GitFileRow(model: GitChangesModel, state: GitChangesState, repo: GitRepo, file: GitFile, writable: Boolean) {
    val key = GitFileKey(repo.branch.root, file.path)
    val expanded = key in state.expanded
    val selected = state.selected.containsKey(key)
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).alpha(if (selected) 1f else .72f).clickable(enabled = writable && !state.busy) { model.toggleFile(repo.branch.root, file) }.testTag("git-file:${file.path}"), verticalAlignment = Alignment.CenterVertically) {
            TriStateCheckbox(if (!selected) ToggleableState.Off else if (state.selected[key] != null) ToggleableState.Indeterminate else ToggleableState.On, onClick = { model.toggleFile(repo.branch.root, file) }, enabled = writable && !state.busy,
                modifier = Modifier.semantics { contentDescription = "Include ${file.path}" })
            IconButton(onClick = { model.expand(key) }, enabled = !state.busy,
                modifier = Modifier.size(40.dp).semantics { contentDescription = "${if (expanded) "Hide" else "Show"} diff for ${file.path}" }) {
                Text(if (expanded) "▾" else "▸")
            }
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text(file.path, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (file.ownership != GitOwnership.Mine) Text(file.ownership.label, color = VerdeColors.Warning, style = MaterialTheme.typography.labelSmall)
            }
            Text("+${file.additions}", color = VerdeColors.DiffAdd, style = MaterialTheme.typography.labelMedium)
            Text(" −${file.deletions}", color = VerdeColors.Danger, style = MaterialTheme.typography.labelMedium)
        }
        if (expanded) {
            if (file.otherThreads.isNotEmpty()) Text("Also changed by ${file.otherThreads.joinToString(", ")}", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
            if (file.binary || file.previewTruncated) Text(if (file.binary) "Binary file — can only be committed whole." else "Preview truncated — can only be committed whole.", color = VerdeColors.Muted, style = MaterialTheme.typography.bodySmall)
            file.hunks.forEach { hunk ->
                Row(verticalAlignment = Alignment.Top) {
                    if (writable && file.canSelectHunks) Checkbox(selected && (state.selected[key] == null || hunk.index in state.selected[key].orEmpty()),
                        onCheckedChange = { model.toggleHunk(repo.branch.root, file, hunk.index) }, enabled = !state.busy,
                        modifier = Modifier.semantics { contentDescription = "Include hunk ${hunk.index + 1} of ${file.path}" })
                    Text(remember(hunk.text) { buildAnnotatedString {
                        hunk.text.lineSequence().forEach { line ->
                            val color = when { line.startsWith("+") -> VerdeColors.DiffAdd; line.startsWith("-") -> VerdeColors.Danger; line.startsWith("@@") -> VerdeColors.Subtle; else -> VerdeColors.Text }
                            withStyle(SpanStyle(color = color)) { append(line); append('\n') }
                        }
                    } }, Modifier.weight(1f).background(VerdeColors.Background, RoundedCornerShape(7.dp)).horizontalScroll(rememberScrollState()).padding(8.dp),
                        fontFamily = VerdeMono, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        HorizontalDivider(color = VerdeColors.Border.copy(alpha = .5f))
    }
}

@Composable
internal fun GitCommitSettingsSection(settings: GitSettings) {
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Commit messages", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
        val provider = when (settings.provider.lowercase()) { "codex" -> "Codex"; "claude" -> "Claude"; "cursor" -> "Cursor"; "opencode" -> "OpenCode"; else -> "Auto" }
        Text("Provider · $provider", style = MaterialTheme.typography.bodyMedium)
        Text("Model · ${settings.model?.takeIf { it.isNotBlank() } ?: "Default (fast model)"}", style = MaterialTheme.typography.bodyMedium)
        Text("Default action · ${settings.action.label}", style = MaterialTheme.typography.bodyMedium)
        Text("Change on your computer", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
    }
}

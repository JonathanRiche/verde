package dev.verdeai.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.UUID

/** Android presentation boundary. The core adapter owns routing, receipts and event-driven refresh. */
internal interface GitChangesClient {
    val snapshot: StateFlow<GitSnapshot>
    suspend fun refresh(chat: GitChat)
    suspend fun review(chat: GitChat, hunkBudgetBytes: Int = 512 * 1024): GitReview
    suspend fun message(reviewId: String, selections: List<GitSelection>): GitMessage
    /** One user intent. Core recovery reuses the same review id and reports onChecking while resolving it.
     * Remain suspended through in_progress; return/throw only a terminal receipt outcome.
     */
    suspend fun commit(reviewId: String, message: String, selections: List<GitSelection>, push: Boolean,
        newBranch: Boolean, branchName: String?, onChecking: (Boolean) -> Unit): GitCommitResult
    suspend fun retry() {}
    suspend fun push(chat: GitChat, root: String, pull: Boolean, requestId: String, onChecking: (Boolean) -> Unit = {}): GitPush
}
internal data class GitChat(val workspace: String, val thread: String)
internal enum class GitAction(val label: String) { Commit("Commit"), CommitAndPush("Commit & push") }
internal enum class GitAccess(val reason: String?) {
    Writable(null), ReadOnly("Monitor devices can review changes. Committing requires Chat or Full access."),
    Remote("Git changes are unavailable for remote-runtime chats."),
    Unavailable("This host does not support git changes.")
}
internal fun gitAccess(scopes: Set<String>, remote: Boolean = false, supported: Boolean = true): GitAccess = when {
    remote -> GitAccess.Remote
    !supported || "repository:read" !in scopes -> GitAccess.Unavailable
    "chat:write" in scopes -> GitAccess.Writable
    else -> GitAccess.ReadOnly
}
internal data class GitSettings(val provider: String = "auto", val model: String? = null, val action: GitAction = GitAction.Commit)
internal data class GitSummary(val files: Int = 0, val additions: Int = 0, val deletions: Int = 0, val attention: Int = 0)
internal data class GitBranch(val root: String, val name: String, val branch: String? = null,
    val defaultBranch: String? = null, val isDefault: Boolean = false, val ahead: Int = 0,
    val behind: Int = 0, val hasRemote: Boolean = false, val upstream: String? = null) {
    val defaultOrMain get() = isDefault || branch in setOf("main", "master") || (defaultBranch != null && branch == defaultBranch)
}
internal data class GitSnapshot(val summaries: Map<GitChat, GitSummary> = emptyMap(),
    val branches: Map<GitChat, List<GitBranch>> = emptyMap(), val access: Map<GitChat, GitAccess> = emptyMap(),
    val settings: GitSettings = GitSettings(), val connected: Boolean = false)
internal enum class GitOwnership(val label: String) { Mine("This chat"), Shared("Shared"), Unclear("Unclear owner"), Unassigned("Your edits") }
internal data class GitHunk(val index: Int, val header: String, val text: String)
internal data class GitFile(val path: String, val status: String = "modified", val ownership: GitOwnership = GitOwnership.Mine,
    val otherThreads: List<String> = emptyList(), val additions: Int = 0, val deletions: Int = 0,
    val binary: Boolean = false, val hunkSelectable: Boolean = false, val previewTruncated: Boolean = false,
    val hunks: List<GitHunk> = emptyList()) {
    val canSelectHunks get() = hunkSelectable && !binary && !previewTruncated && hunks.isNotEmpty()
}
internal data class GitRepo(val branch: GitBranch, val head: String? = null, val files: List<GitFile> = emptyList())
internal data class GitReview(val id: String, val chat: GitChat, val turnRunning: Boolean = false,
    val defaultAction: GitAction = GitAction.Commit, val repos: List<GitRepo>)
internal data class GitFileKey(val root: String, val path: String)
internal data class GitFileSelection(val path: String, val hunks: List<Int>? = null)
internal data class GitSelection(val root: String, val files: List<GitFileSelection>)
internal data class GitMessage(val message: String, val provider: String, val model: String, val branch: String? = null)
internal enum class GitPush { NotRequested, Pushed, Rejected, Failed }
internal data class GitRepoCommit(val root: String, val shortCommit: String, val files: Int, val push: GitPush, val branch: String? = null, val branchCreated: Boolean = false)
internal data class GitCommitResult(val repos: List<GitRepoCommit>)
/** Only a protocol error code crosses into presentation; raw exception messages are never shown/logged. */
internal class GitFailure(val code: String) : Exception()
internal fun gitErrorText(code: String?) = when (code) {
    "changed_since_review" -> "Files changed since this review. Review the refreshed changes before committing."
    "head_moved" -> "The branch changed while committing. Nothing was committed. Try again."
    "review_expired" -> "This review expired. Review the refreshed changes before committing."
    "missing_git_identity" -> "Set your Git name and email on your computer, then try again."
    "turns_running" -> "Chats are still working in this repository. Pull & push when they finish."
    "branch_create_failed" -> "The branch could not be created. Nothing was committed."
    "in_progress" -> "Checking commit…"
    "retry_expired", "uncertain", "invalid_response" -> "Could not confirm the result. Check the repository on your computer before starting another commit."
    "offline" -> "Connect to the host to review or commit changes."
    "busy" -> "Another Git operation is still running. Wait for it to finish."
    "timeout" -> "The host did not respond in time. Try again when connected."
    "scope_denied", "forbidden" -> "This device does not have permission to commit."
    else -> "Could not confirm the result. Check the changes on your computer before trying again."
}
internal data class GitNotice(val text: String, val rejectedRoots: List<String> = emptyList())
internal data class GitChangesState(val snapshot: GitSnapshot = GitSnapshot(), val review: GitReview? = null,
    val sheet: Boolean = false, val preparing: Boolean = false, val confirmingMain: Boolean = false,
    val loading: Boolean = false, val generating: Boolean = false, val busy: Boolean = false, val checking: Boolean = false, val canRetry: Boolean = false,
    val submittingAction: GitAction? = null, val submittingNewBranch: Boolean = false,
    val expanded: Set<GitFileKey> = emptySet(), val editing: Boolean = false, val action: GitAction = GitAction.Commit,
    val selected: Map<GitFileKey, Set<Int>?> = emptyMap(), val typedMessage: String = "",
    val generated: GitMessage? = null, val error: String? = null, val messageError: Boolean = false,
    val notice: GitNotice? = null, val rejectedRoots: Set<String> = emptySet()) {
    val message get() = typedMessage.trim().ifEmpty { generated?.message?.trim().orEmpty() }
    val selections get() = review?.repos.orEmpty().mapNotNull { repo ->
        val files = repo.files.mapNotNull { file ->
            val key = GitFileKey(repo.branch.root, file.path)
            if (selected.containsKey(key)) GitFileSelection(file.path, selected[key]?.sorted()) else null
        }
        if (files.isEmpty()) null else GitSelection(repo.branch.root, files)
    }
    val fileCount get() = selections.sumOf { it.files.size }
    val totals: Pair<Int, Int> get() {
        var additions = 0; var deletions = 0
        review?.repos.orEmpty().forEach { repo -> repo.files.forEach { file ->
            val key = GitFileKey(repo.branch.root, file.path)
            if (selected.containsKey(key)) {
                val hunks = selected[key]
                if (hunks == null) { additions += file.additions; deletions += file.deletions }
                else file.hunks.filter { it.index in hunks }.forEach { hunk ->
                    hunk.text.lineSequence().forEach { line ->
                        if (line.startsWith("+")) additions++ else if (line.startsWith("-")) deletions++
                    }
                }
            }
        } }
        return additions to deletions
    }
}

internal class GitChangesModel(val chat: GitChat, private val client: GitChangesClient) : ViewModel() {
    private val mutable = MutableStateFlow(GitChangesState(snapshot = client.snapshot.value))
    val state = mutable.asStateFlow()
    private var generation = 0
    private var messageGeneration = 0
    init { viewModelScope.launch { client.snapshot.collect { snapshot -> mutable.update { it.copy(snapshot = snapshot) } } } }
    val access get() = client.snapshot.value.access[chat] ?: GitAccess.Unavailable
    private fun writable() = access == GitAccess.Writable && client.snapshot.value.connected
    fun focus() { viewModelScope.launch { try { client.refresh(chat) } catch (e: CancellationException) { throw e } catch (_: Exception) { /* Retain last summary; next focus/event retries. */ } } }
    fun open(action: GitAction = client.snapshot.value.settings.action, quick: Boolean = false) {
        if (state.value.busy || state.value.loading || access in setOf(GitAccess.Unavailable, GitAccess.Remote)) return
        val epoch = ++generation
        ++messageGeneration
        mutable.update { GitChangesState(snapshot = it.snapshot, action = action, sheet = !quick,
            preparing = quick, loading = true, rejectedRoots = it.rejectedRoots) }
        viewModelScope.launch { load(epoch, quick) }
    }
    private suspend fun load(epoch: Int, quick: Boolean) {
        try {
            val review = client.review(chat)
            if (generation != epoch) return
            check(review.chat == chat)
            val selected = buildMap<GitFileKey, Set<Int>?> {
                review.repos.forEach { repo -> repo.files.filter { it.ownership == GitOwnership.Mine }.forEach { put(GitFileKey(repo.branch.root, it.path), null) } }
            }
            val safe = quick && writable() && !review.turnRunning && review.repos.any { it.files.isNotEmpty() } &&
                review.repos.filter { it.files.isNotEmpty() }.all { it.branch.branch != null } &&
                review.repos.flatMap { it.files }.all { it.ownership == GitOwnership.Mine }
            val main = safe && review.repos.any { it.files.isNotEmpty() && it.branch.defaultOrMain }
            mutable.update { it.copy(review = review, selected = selected, loading = false,
                sheet = !safe, preparing = safe && !main, confirmingMain = main) }
            if (access == GitAccess.Writable) generate(epoch)
            if (generation == epoch && safe && !main) {
                if (canCommit() && state.value.message.isNotBlank()) commit() else mutable.update { it.copy(sheet = true, preparing = false) }
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (generation == epoch) mutable.update { it.copy(loading = false, preparing = false, sheet = true, error = gitErrorText((e as? GitFailure)?.code)) } }
    }
    fun dismiss() {
        if (state.value.busy) return
        generation++; messageGeneration++
        mutable.update { it.copy(sheet = false, preparing = false, confirmingMain = false, loading = false, generating = false) }
    }
    fun edit(value: Boolean) {
        if (state.value.busy) return
        mutable.update { it.copy(editing = value, expanded = if (value) it.review?.repos.orEmpty().flatMap { repo -> repo.files.map { GitFileKey(repo.branch.root, it.path) } }.toSet() else emptySet()) }
        if (!value && state.value.typedMessage.isBlank() && state.value.generated == null) regenerate()
    }
    fun expand(key: GitFileKey) {
        if (state.value.busy) return
        mutable.update {
            val expanded = if (key in it.expanded) it.expanded - key else it.expanded + key
            it.copy(expanded = expanded, editing = expanded.isNotEmpty())
        }
    }
    fun message(value: String) { mutable.update { it.copy(typedMessage = value) } }
    fun toggleFile(root: String, file: GitFile) {
        if (!writable() || state.value.busy) return
        val key = GitFileKey(root, file.path)
        changeSelection { if (containsKey(key)) remove(key) else put(key, null) }
    }
    fun toggleHunk(root: String, file: GitFile, index: Int) {
        if (!writable() || state.value.busy || !file.canSelectHunks || file.hunks.none { it.index == index }) return
        val key = GitFileKey(root, file.path)
        changeSelection {
            val all = file.hunks.map { it.index }.toSet()
            val old = if (containsKey(key)) get(key) ?: all else emptySet()
            val next = if (index in old) old - index else old + index
            if (next.isEmpty()) remove(key) else put(key, next.takeUnless { it == all })
        }
    }
    private fun changeSelection(change: MutableMap<GitFileKey, Set<Int>?>.() -> Unit) {
        messageGeneration++
        mutable.update { it.copy(selected = it.selected.toMutableMap().apply(change), generated = null, generating = false, messageError = false) }
    }
    fun regenerate() { if (!state.value.busy) viewModelScope.launch { generate(generation) } }
    private suspend fun generate(epoch: Int) {
        val current = state.value
        val review = current.review ?: return
        val selections = current.selections.takeIf { it.isNotEmpty() } ?: return
        val request = ++messageGeneration
        mutable.update { it.copy(generating = true, messageError = false) }
        try {
            val message = client.message(review.id, selections)
            if (generation == epoch && messageGeneration == request) mutable.update { it.copy(generated = message, generating = false, messageError = message.message.isBlank()) }
        } catch (e: CancellationException) { throw e }
        catch (_: Exception) { if (generation == epoch && messageGeneration == request) mutable.update { it.copy(generating = false, messageError = true) } }
    }
    fun canCommit() = writable() && !state.value.busy && !state.value.loading && state.value.review != null && state.value.fileCount > 0 && !state.value.generating
    fun commit(newBranch: Boolean = false, action: GitAction = state.value.action) {
        if (!canCommit()) return
        val review = state.value.review ?: return
        val epoch = generation
        mutable.update { it.copy(busy = true, error = null, submittingAction = action, submittingNewBranch = newBranch) }
        viewModelScope.launch {
            try {
                if (state.value.message.isBlank()) generate(epoch)
                if (generation != epoch) return@launch
                val current = state.value
                if (current.message.isBlank() || !writable()) {
                    mutable.update { it.copy(busy = false, preparing = false, confirmingMain = false, sheet = true) }
                    return@launch
                }
                val result = client.commit(review.id, current.message, current.selections, action == GitAction.CommitAndPush,
                    newBranch, current.generated?.branch.takeIf { newBranch }) { canRetry ->
                    if (generation == epoch) mutable.update { it.copy(checking = true, canRetry = canRetry) }
                }
                if (generation != epoch) return@launch
                val rejected = result.repos.filter { it.push == GitPush.Rejected }.map { it.root }
                val count = result.repos.sumOf { it.files }
                val sha = result.repos.joinToString(", ") { it.shortCommit }
                val pushed = result.repos.isNotEmpty() && result.repos.all { it.push == GitPush.Pushed }
                val suffix = when { pushed -> " · pushed"; rejected.isNotEmpty() -> " · push rejected"; result.repos.any { it.push == GitPush.Failed } -> " · push failed"; else -> "" }
                mutable.update { it.copy(busy = false, checking = false, canRetry = false, sheet = false, confirmingMain = false, preparing = false,
                    review = null, notice = GitNotice("Committed $count ${if (count == 1) "file" else "files"} · $sha$suffix", rejected), rejectedRoots = it.rejectedRoots + rejected) }
                focus()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (generation != epoch) return@launch
                val code = (e as? GitFailure)?.code
                mutable.update { it.copy(busy = false, checking = false, canRetry = false, preparing = false, confirmingMain = false, sheet = true, error = gitErrorText(code)) }
                if (code in setOf("changed_since_review", "review_expired")) {
                    mutable.update { it.copy(loading = true, review = null, generated = null, selected = emptyMap()) }
                    load(epoch, false) // Refresh only; never resubmit a commit.
                } else if (code == null || code in setOf("in_progress", "uncertain", "invalid_response", "retry_expired", "timeout")) {
                    mutable.update { it.copy(review = null, selected = emptyMap()) }
                    focus()
                }
            }
        }
    }
    fun push(pull: Boolean = false) {
        if (!writable() || state.value.busy) return
        val roots = if (pull) state.value.rejectedRoots.toList() else client.snapshot.value.branches[chat].orEmpty().filter { it.hasRemote && it.ahead > 0 }.map { it.root }
        if (roots.isEmpty()) return
        mutable.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                val results = roots.map { it to client.push(chat, it, pull, UUID.randomUUID().toString()) { canRetry -> mutable.update { it.copy(checking = true, canRetry = canRetry) } } }
                val rejected = results.filter { it.second == GitPush.Rejected }.map { it.first }
                val success = results.all { it.second == GitPush.Pushed }
                mutable.update { it.copy(notice = GitNotice(if (success) "${if (pull) "Pulled and pushed" else "Pushed"} ${roots.size} repositories" else "Push did not complete. Your commits are saved.", rejected),
                    rejectedRoots = (it.rejectedRoots - results.filter { row -> row.second == GitPush.Pushed }.map { row -> row.first }.toSet()) + rejected) }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { mutable.update { it.copy(notice = GitNotice(gitErrorText((e as? GitFailure)?.code))) } }
            finally { mutable.update { it.copy(busy = false, checking = false, canRetry = false) }; focus() }
        }
    }
    fun retry() {
        if (!state.value.canRetry || !writable()) return
        mutable.update { it.copy(canRetry = false) }
        viewModelScope.launch {
            try { client.retry() }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { mutable.update { it.copy(canRetry = true) } }
        }
    }
    fun dismissNotice() { mutable.update { it.copy(notice = null) } }
}

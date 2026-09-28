package dev.verdeai.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.util.UUID

/** Injectable core transport: no daemon calls or local Git in this adapter. */
internal interface GitCoreConnection {
    val views: StateFlow<Map<String, JsonElement>>
    val operations: StateFlow<OperationsQuery?>
    suspend fun query(selector: String): JsonElement
    suspend fun send(event: (Long, Long) -> Event)
}
private class HostGitConnection(private val host: CoreHost) : GitCoreConnection {
    override val views get() = host.views
    override val operations get() = host.operations
    override suspend fun query(selector: String) = host.query(selector)
    override suspend fun send(event: (Long, Long) -> Event) = host.send(event)
}

/** Host changes retire the old boundary, so a saved screen cannot write to a newly selected host. */
internal class GitChangesBinding(hosts: HostsModel, browse: StateFlow<BrowseState>) : ViewModel() {
    private val mutable = MutableStateFlow<GitChangesClient?>(null)
    val client = mutable.asStateFlow()
    init {
        viewModelScope.launch {
            browse.map { it.hostId }.distinctUntilChanged().collectLatest { id ->
                mutable.value = null
                if (id == null) return@collectLatest
                val host = try { hosts.core(id) }
                    catch (e: CancellationException) { throw e }
                    catch (_: Exception) { null }
                if (host == null) return@collectLatest
                coroutineScope {
                    val adapter = CoreGitChangesClient(HostGitConnection(host), this)
                    mutable.value = adapter
                    try { browse.filter { it.hostId == id }.collect { adapter.catalog(it) } }
                    finally { adapter.close(); mutable.value = null }
                }
            }
        }
    }
}

internal class CoreGitChangesClient(private val core: GitCoreConnection, scope: CoroutineScope) : GitChangesClient {
    private val mutable = MutableStateFlow(GitSnapshot())
    override val snapshot = mutable.asStateFlow()
    private val alive = MutableStateFlow(true)
    private var scopes = emptySet<String>()
    private var chats = emptySet<GitChat>()
    private var catalogChats = emptySet<GitChat>()
    private var catalogSynced = false
    private val subscribed = mutableSetOf<String>()
    private val requested = mutableSetOf<String>()
    private var active: GitChat? = null
    private var latestViews = emptyMap<String, JsonElement>()
    private val scope = scope
    init { scope.launch { core.views.collect { latestViews = it; project(it) } } }

    fun close() { alive.value = false; mutable.value = GitSnapshot() }
    fun catalog(browse: BrowseState) {
        if (browse.host?.auth_state in HostsModel.WIPED) {
            scopes = emptySet(); chats = emptySet(); catalogChats = emptySet(); catalogSynced = false; active = null
            subscribed.clear(); latestViews = emptyMap(); mutable.value = GitSnapshot()
            return
        }
        scopes = browse.host?.scopes.orEmpty().toSet()
        val workspaces = browse.workspaces?.items.orEmpty()
        val nextChats = workspaces.flatMap { w -> w.threads.map { GitChat(w.workspace_id, it.thread_id) } }.toSet()
        val connected = browse.host?.phase == "ready" && browse.host?.auth_state == "paired" && browse.networkAvailable
        val arrived = active?.takeIf { it in nextChats && browse.hasSynced &&
            (it !in catalogChats || !catalogSynced || (!mutable.value.connected && connected)) }
        catalogChats = nextChats
        catalogSynced = browse.hasSynced
        chats = nextChats + listOfNotNull(active)
        mutable.update { it.copy(connected = connected) }
        project(latestViews)
        // A newly created chat can focus before its synced route exists. Core reports
        // unsupported for that missing route; retry once when the catalog catches up.
        if (arrived != null && "repository:read" in scopes && mutable.value.connected) scope.launch {
            try { refreshStatus(arrived) }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { /* A later focus can retry this read. */ }
        }
        if ("repository:read" in scopes && mutable.value.connected) workspaces.forEach { w ->
            if (w.workspace_id !in subscribed && requested.add(w.workspace_id)) scope.launch {
                try { subscribe(w.workspace_id) }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) { /* Next catalog/focus retries. */ }
                finally { requested.remove(w.workspace_id) }
            }
        }
    }
    private fun project(views: Map<String, JsonElement>) {
        val summaries = mutable.value.summaries.toMutableMap()
        val branches = mutable.value.branches.toMutableMap()
        val access = chats.associateWith { gitAccess(scopes) }.toMutableMap()
        views.filterKeys { it.startsWith("git_summary:") }.values.forEach { raw ->
            val summary = decode<GitSummaryQuery>(raw)?.data ?: return@forEach
            summaries.keys.removeAll { it.workspace == summary.workspace_id }
            summary.threads.forEach { t -> summaries[GitChat(summary.workspace_id, t.local_thread_id)] = GitSummary(t.files.toInt(), t.additions.toInt(), t.deletions.toInt(), t.attention.toInt()) }
            if (!summary.supported) access.keys.filter { it.workspace == summary.workspace_id }.forEach { access[it] = GitAccess.Unavailable }
        }
        val status = decode<GitStatusQuery>(views["git_status"])?.data
        status?.status?.let { value ->
            val chat = GitChat(value.workspace_id, value.local_thread_id)
            branches[chat] = value.repos.map { it.presentation() }
            access[chat] = if (!status.supported) GitAccess.Unavailable else gitAccess(scopes)
        }
        val review = decode<GitReviewQuery>(views["git_review"])?.data
        review?.review?.let { value ->
            val chat = GitChat(value.workspace_id, value.local_thread_id)
            // Header counts use live status; the sheet alone keeps the frozen branch facts.
            if (status?.status?.let { GitChat(it.workspace_id, it.local_thread_id) } != chat)
                branches[chat] = value.repos.map { it.presentation().branch }
            access[chat] = gitAccess(scopes)
        }
        if (status?.supported == false) active?.let { access[it] = if (status.error?.code == "unsupported" && it in catalogChats) GitAccess.Remote else GitAccess.Unavailable }
        val config = review?.config
        mutable.update { it.copy(summaries = summaries, branches = branches, access = access,
            settings = config?.let { c -> GitSettings(c.commit_message_provider, c.commit_message_model, action(c.commit_default_action)) } ?: it.settings) }
    }
    private suspend fun subscribe(workspace: String) {
        receipt { n, w, id -> EventGitSummaryRefresh(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspace) }
        subscribed.add(workspace)
        seed("git_summary:$workspace")
    }
    override suspend fun refresh(chat: GitChat) {
        active = chat
        chats = chats + chat
        project(latestViews)
        subscribe(chat.workspace)
        refreshStatus(chat)
        seed("git_review")
    }
    private suspend fun refreshStatus(chat: GitChat) {
        receipt { n, w, id -> EventGitStatusRefresh(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=chat.workspace, thread_id=chat.thread) }
        seed("git_status")
    }
    private suspend fun seed(selector: String) { latestViews = latestViews + (selector to core.query(selector)); project(latestViews) }
    override suspend fun review(chat: GitChat, hunkBudgetBytes: Int): GitReview {
        // Core enforces min(128 KiB, response limit / 16), tighter than this UI budget.
        receipt { n, w, id -> EventGitReviewOpen(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=chat.workspace, thread_id=chat.thread) }
        val value = reviewView().review ?: throw GitFailure("invalid_response")
        if (value.workspace_id != chat.workspace || value.local_thread_id != chat.thread) throw GitFailure("review_expired")
        return GitReview(value.review_id, chat, value.turn_running, action(value.default_action), value.repos.map { it.presentation() })
    }
    override suspend fun message(reviewId: String, selections: List<GitSelection>): GitMessage {
        receipt { n,w,id -> EventGitMessageGenerate(now_ms=n, wall_time_ms=w, intent_id=id, review_id=reviewId, selections=selections.wire()) }
        val view = reviewView()
        if (view.review?.review_id != reviewId) throw GitFailure("review_expired")
        val value = view.message ?: throw GitFailure("invalid_response")
        return GitMessage(value.message, value.provider, value.model, value.branch)
    }
    override suspend fun commit(reviewId: String, message: String, selections: List<GitSelection>, push: Boolean,
        newBranch: Boolean, branchName: String?, onChecking: (Boolean) -> Unit): GitCommitResult {
        receipt(recovery = true, onChecking = onChecking) { n,w,id -> EventGitCommit(now_ms=n, wall_time_ms=w, intent_id=id,
            review_id=reviewId, message=message, selections=selections.wire(), push=push, new_branch=newBranch, branch_name=branchName) }
        val view = reviewView()
        if (view.review?.review_id != reviewId) throw GitFailure("invalid_response")
        val result = view.result ?: throw GitFailure("invalid_response")
        return GitCommitResult(result.repos.map { GitRepoCommit(it.root, it.short_commit, it.files.toInt(), pushResult(it.push), it.branch, it.branch_created) })
    }
    override suspend fun retry() { receipt { n,w,id -> EventGitRetry(now_ms=n, wall_time_ms=w, intent_id=id) } }
    override suspend fun push(chat: GitChat, root: String, pull: Boolean, requestId: String, onChecking: (Boolean) -> Unit): GitPush {
        // Core derives and retains the daemon request_id from this stable intent id.
        receipt(id=requestId, recovery=!pull, onChecking=onChecking) { n,w,id -> if (pull) EventGitPullPush(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=chat.workspace, root=root)
            else EventGitPush(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=chat.workspace, root=root) }
        val result = reviewView().pull_push_result ?: throw GitFailure("invalid_response")
        if (result.root != root) throw GitFailure("invalid_response")
        return pushResult(result.push)
    }
    private suspend fun reviewView(): GitReviewView = decode<GitReviewQuery>(core.query("git_review"))?.data ?: throw GitFailure("invalid_response")

    /** Follow receipts, not time-based polling. Only core retries an identical retained mutation. */
    private suspend fun receipt(id: String = UUID.randomUUID().toString(), recovery: Boolean = false,
        onChecking: (Boolean) -> Unit = {}, build: (Long, Long, String) -> Event) {
        if (!alive.value) throw GitFailure("offline")
        core.send { n,w -> build(n,w,id) }
        var recovering = false
        try { withTimeout(if (recovery) 3_600_000L else 180_000L) {
            combine(core.operations, core.views, alive) { operations, views, alive -> Triple(operations?.data?.items?.find { it.intent_id == id }, views, alive) }
                .first { (op, views, alive) ->
                    if (!alive) throw GitFailure("offline")
                    val view = decode<GitReviewQuery>(views["git_review"])?.data
                    when (op?.state) {
                        "succeeded" -> true
                        "failed" -> throw GitFailure(op.error?.code ?: "unknown")
                        "uncertain" -> {
                            if (!recovery || view?.error?.code == "retry_expired") throw GitFailure(view?.error?.code ?: "uncertain")
                            recovering = true
                            onChecking(view?.can_retry == true)
                            false
                        }
                        else -> { if (recovering && view?.mutation_state == "pending") onChecking(false); false }
                    }
                }
        } } catch (_: TimeoutCancellationException) { throw GitFailure(if (recovery) "retry_expired" else "timeout") }
    }
    private inline fun <reified T> decode(value: JsonElement?): T? = value?.let { try { CoreJson.decodeFromJsonElement<T>(it) } catch (_: Exception) { null } }
}

private fun action(value: String) = if (value == "commit_and_push") GitAction.CommitAndPush else GitAction.Commit
private fun pushResult(value: String) = when (value) { "pushed" -> GitPush.Pushed; "rejected" -> GitPush.Rejected; "not_requested" -> GitPush.NotRequested; else -> GitPush.Failed }
private fun List<GitSelection>.wire() = map { repo -> GitRepoSelection(repo.root, repo.files.map { dev.verdeai.core.GitFileSelection(it.path, it.hunks?.map(Int::toLong)) }) }
private fun GitRepoStatus.presentation() = GitBranch(root, name, branch, default_branch, is_default_branch, ahead.toInt(), behind.toInt(), has_remote, upstream)
private fun GitReviewRepo.presentation() = GitRepo(GitBranch(root, name, branch, default_branch, is_default_branch, ahead.toInt(), behind.toInt(), has_remote, upstream), head,
    files.map { GitFile(it.path, it.status, when(it.ownership) { "mine" -> GitOwnership.Mine; "shared" -> GitOwnership.Shared; "unassigned" -> GitOwnership.Unassigned; else -> GitOwnership.Unclear },
        it.other_threads.map { t -> t.title }, it.additions.toInt(), it.deletions.toInt(), it.binary, it.hunk_selectable, it.preview_truncated,
        it.hunks.map { h -> GitHunk(h.index.toInt(), h.header, h.text) }) })

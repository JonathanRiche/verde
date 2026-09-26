package dev.verdeai.app

import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.util.UUID

internal data class ManageState(
    val hostId: String? = null,
    val view: ManageView? = null,
    /** Intents the core refused before recording a job (malformed input or a closed host). */
    val refused: Set<String> = emptySet(),
    val fatal: Boolean = false,
) {
    fun job(intentId: String?): ManageJob? = intentId?.let { id -> view?.operations?.lastOrNull { it.intent_id == id } }
}

/** Outcome of one management intent as a screen should present it. */
internal sealed class JobOutcome {
    data object Idle : JobOutcome()
    data object Pending : JobOutcome()
    data class Done(val job: ManageJob) : JobOutcome()
    data class Failed(val message: String) : JobOutcome()
}

internal fun outcome(state: ManageState, intentId: String?): JobOutcome {
    if (intentId == null) return JobOutcome.Idle
    if (intentId in state.refused) return JobOutcome.Failed("Couldn't send that to the core. Try again.")
    val job = state.job(intentId) ?: return JobOutcome.Pending
    return when (job.state) {
        "succeeded" -> JobOutcome.Done(job)
        "failed" -> JobOutcome.Failed(jobMessage(job))
        // The request may have reached the host; a refresh shows whether it applied.
        "uncertain" -> JobOutcome.Failed("The connection dropped before Verde answered. Pull to refresh to check.")
        else -> JobOutcome.Pending
    }
}

/** Busy counts from `workspace_busy`, e.g. "Stop 2 running requests and 1 background task first." */
internal fun busyMessage(busy: ManageBusy?): String {
    val requests = busy?.pending_turns ?: 0
    val tasks = busy?.running_tasks ?: 0
    fun plural(n: Long, word: String) = "$n $word${if (n == 1L) "" else "s"}"
    return when {
        requests > 0 && tasks > 0 -> "Stop ${plural(requests, "running request")} and ${plural(tasks, "background task")} first."
        requests > 0 -> "Stop ${plural(requests, "running request")} first."
        tasks > 0 -> "Stop ${plural(tasks, "running background task")} first."
        else -> "Stop this workspace's running requests and tasks first."
    }
}

internal fun jobMessage(job: ManageJob): String {
    val error = job.error
    return when (error?.code) {
        null -> "Something went wrong."
        "workspace_busy" -> busyMessage(job.busy)
        "unavailable" -> "Connect to the host first."
        "insufficient_scope" -> "This phone isn't allowed to do that. Pair again with more access."
        "conflict" -> "The workspace changed on the computer. Try again."
        "path_outside_roots" -> "Verde can't open folders there. Pick one under your home folder."
        else -> error.message.ifBlank { error.code.replace('_', ' ').replaceFirstChar { it.uppercase() } }
    }
}

/**
 * Workspace and thread management for the selected host through the core's `manage` selector:
 * new chats, add/rename/close/reopen workspaces, the folder picker and chat history search.
 * Paths and titles are shown but never logged.
 */
internal class ManageModel(
    private val hosts: HostsModel,
    private val browse: StateFlow<BrowseState>,
) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(ManageState())
    val state = mutableState.asStateFlow()
    private var core: CoreHost? = null

    init {
        scope.launch { browse.map { it.hostId }.distinctUntilChanged().collectLatest { id -> observe(id) } }
    }

    private suspend fun observe(id: String?) {
        core = null
        mutableState.value = ManageState(hostId=id)
        if (id == null) return
        val host = try { hosts.core(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (host == null) { mutableState.update { it.copy(fatal=true) }; return }
        core = host
        // `manage` only appears in `views` after its first change, so seed it with one query.
        host.views.map { it[SELECTOR] }.distinctUntilChanged().collect { value ->
            val view = decode(value ?: try { host.query(SELECTOR) } catch (e: CancellationException) { throw e } catch (_: Exception) { null })
            if (view != null) mutableState.update { it.copy(view=view) }
        }
    }

    private fun decode(value: JsonElement?): ManageView? = value?.let {
        try { CoreJson.decodeFromJsonElement<ManageQuery>(it).data } catch (_: Exception) { null }
    }

    private fun send(build: (Long, Long, String) -> Event): String {
        val id = UUID.randomUUID().toString()
        val host = core
        if (host == null) { refuse(id); return id }
        scope.launch {
            try { host.send { n, w -> build(n, w, id) } }
            catch (e: CancellationException) { throw e }
            catch (_: CoreInputRejected) { refuse(id) }
            catch (_: Exception) { refuse(id); mutableState.update { it.copy(fatal=true) } }
        }
        return id
    }

    private fun refuse(id: String) = mutableState.update { it.copy(refused=it.refused + id) }

    /** Selects the new-chat workspace and settings; the core validates against its catalogs. */
    fun select(workspaceId: String, selection: ChatSelection = ChatSelection()) = send { n, w, id ->
        EventNewChatSelect(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, provider=selection.provider,
            model=selection.model, effort=selection.effort, access=selection.access, speed=selection.speed)
    }

    fun createThread(workspaceId: String, selection: ChatSelection) = send { n, w, id ->
        EventThreadCreate(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, provider=selection.provider ?: "codex",
            model=selection.model, effort=selection.effort, access=selection.access, speed=selection.speed)
    }

    fun createWorkspace(path: String, label: String?) = send { n, w, id ->
        EventWorkspaceCreate(now_ms=n, wall_time_ms=w, intent_id=id, path=path, label=label?.trim()?.ifEmpty { null })
    }

    fun rename(workspaceId: String, label: String) = send { n, w, id ->
        EventWorkspaceRename(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, label=label.trim())
    }

    fun setArchived(workspaceId: String, archived: Boolean) = send { n, w, id ->
        EventWorkspaceArchive(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId, archived=archived)
    }

    /** Stops the workspace's sessions and archives it; refused with busy counts while work runs. */
    fun close(workspaceId: String) = send { n, w, id -> EventWorkspaceClose(now_ms=n, wall_time_ms=w, intent_id=id, workspace_id=workspaceId) }

    fun listDirectory(path: String? = null) = send { n, w, id -> EventDirectoryList(now_ms=n, wall_time_ms=w, intent_id=id, path=path) }

    fun searchHistory(query: String, workspaceId: String?) = send { n, w, id ->
        EventHistorySearch(now_ms=n, wall_time_ms=w, intent_id=id, query=query, workspace_id=workspaceId)
    }

    fun loadMoreHistory() = send { n, w, id -> EventHistoryLoadMore(now_ms=n, wall_time_ms=w, intent_id=id) }

    override fun onCleared() { scope.cancel() }

    companion object { const val SELECTOR = "manage" }
}

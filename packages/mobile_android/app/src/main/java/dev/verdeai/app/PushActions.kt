package dev.verdeai.app

import androidx.lifecycle.ViewModel
import dev.verdeai.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import java.util.UUID

/*
 * D-14 glue between notifications and the host cores. Every protocol step is a core intent
 * (`push_register`, `thread_open`, `approval_decide`, `draft_set` + `send`/`followup_submit`,
 * `turn_cancel`); this file only sequences them and waits for the core's projections.
 */

/** A thread to show once its host is selected (notification tap or action). */
internal data class ThreadLink(val hostId: String, val workspaceId: String, val threadId: String)

internal fun hostReady(view: HostView?) = view != null && view.phase == "ready" && view.auth_state == "paired" &&
    view.sync_state in setOf("ready", "stale")

/** [PushHosts] over the Activity's [HostsModel]. */
internal class HostsPushDirectory(private val hosts: HostsModel, private val foreground: StateFlow<Boolean>) : PushHosts {
    override fun states(): Map<String, HostPushState>? {
        val state = hosts.state.value
        if (state.loading) return null
        return state.rows.associate { row ->
            val auth = row.view?.auth_state
            row.saved.id to when {
                row.fatal || auth == null -> HostPushState.Unknown
                auth == "paired" -> HostPushState.Paired
                auth in HostsModel.WIPED -> HostPushState.Gone
                else -> HostPushState.Unknown
            }
        }
    }

    override suspend fun register(hostId: String, sendToken: String, keySeedBase64: String): HostRegistration {
        val core = withTimeoutOrNull(CORE_WAIT_MS) { hosts.core(hostId) } ?: return HostRegistration.Retry
        fun view() = core.hosts.value?.data?.items?.firstOrNull()
        // Registration needs the core online, which it only is in the foreground.
        if (!hostReady(view())) {
            if (!foreground.value) return HostRegistration.Retry
            withTimeoutOrNull(READY_WAIT_MS) { core.hosts.first { hostReady(it?.data?.items?.firstOrNull()) } } ?: return HostRegistration.Retry
        }
        if ("device:write" !in view()?.scopes.orEmpty()) return HostRegistration.Unsupported
        val intent = UUID.randomUUID().toString()
        try {
            core.send { n, w -> EventPushRegister(now_ms = n, wall_time_ms = w, intent_id = intent, platform = "android",
                send_token = sendToken, key_seed_base64 = keySeedBase64) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return HostRegistration.Retry }
        val op = withTimeoutOrNull(OPERATION_WAIT_MS) { awaitOperation(core, intent) } ?: return HostRegistration.Retry
        return when {
            op.state == "succeeded" -> HostRegistration.Registered
            op.error?.code == "insufficient_scope" || op.error?.rpc_code in UNSUPPORTED -> HostRegistration.Unsupported
            else -> HostRegistration.Retry
        }
    }

    private companion object {
        const val CORE_WAIT_MS = 5_000L
        const val READY_WAIT_MS = 20_000L
        const val OPERATION_WAIT_MS = 30_000L
        /** A host without A-13 (`device.push.*`) answers method_not_found. */
        val UNSUPPORTED = setOf("method_not_found", "insufficient_scope")
    }
}

/** Waits for a value derived from [selector], re-reading after every core state change. */
internal suspend fun <T : Any> CoreHost.awaitView(selector: String, timeoutMs: Long, pick: (JsonElement) -> T?): T? =
    withTimeoutOrNull(timeoutMs) {
        views.map { try { pick(query(selector)) } catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
            .filterNotNull().first()
    }

private fun threadOf(value: JsonElement): ChatThreadView? = CoreJson.decodeFromJsonElement<ThreadQuery>(value).data
private fun composerOf(value: JsonElement): ChatComposerView? = CoreJson.decodeFromJsonElement<ComposerQuery>(value).data

internal enum class ActionOutcome(val message: String?) {
    Opened(null),
    Approved("Approved"),
    Denied("Denied"),
    AlreadyAnswered("This approval was already answered."),
    ReplySent("Reply sent"),
    ReplyQueued("Reply queued"),
    Stopped("Stopping the agent"),
    NotRunning("The agent already finished."),
    Locked(null),
    Unreachable("Couldn't reach the host. Open the chat and try again."),
    Failed("Couldn't complete that from the notification. Open the chat and try again."),
}

/**
 * Runs one notification action against the selected host's core: selects the host, shows the
 * thread, waits for app lock (D-15), then opens the thread and performs the action. Push payloads
 * carry no `call_id`, so approvals are re-read from the opened thread and must match its turn.
 */
internal class NotificationActionRunner(
    private val hosts: HostsModel,
    private val links: MutableStateFlow<ThreadLink?>,
    /** Suspends until the app lock is open; false if it never opened. */
    private val unlocked: suspend () -> Boolean,
    private val timeoutMs: Long = 20_000L,
) {
    suspend fun run(action: NotificationAction): ActionOutcome {
        val hostId = action.hostId ?: return ActionOutcome.Opened
        withTimeoutOrNull(timeoutMs) { hosts.state.first { !it.loading } } ?: return ActionOutcome.Unreachable
        if (hosts.state.value.rows.none { it.saved.id == hostId }) return ActionOutcome.Opened
        if (hosts.state.value.active != hostId) {
            withTimeoutOrNull(timeoutMs) {
                while (hosts.state.value.active != hostId) {
                    hosts.state.first { !it.busy }
                    hosts.select(hostId)
                    hosts.state.first { !it.busy || it.active == hostId }
                    if (hosts.state.value.active != hostId) delay(100)
                }
            }
        }
        val ws = action.workspaceId
        val thread = action.threadId
        if (ws != null && thread != null) links.value = ThreadLink(hostId, ws, thread)
        if (action.verb == NotificationVerb.Open || ws == null || thread == null) return ActionOutcome.Opened
        if (!unlocked()) return ActionOutcome.Locked
        val core = withTimeoutOrNull(timeoutMs) { hosts.core(hostId) } ?: return ActionOutcome.Unreachable
        withTimeoutOrNull(timeoutMs) { core.hosts.first { hostReady(it?.data?.items?.firstOrNull()) } } ?: return ActionOutcome.Unreachable
        try {
            core.send { n, w -> EventThreadOpen(now_ms = n, wall_time_ms = w, intent_id = UUID.randomUUID().toString(),
                workspace_id = ws, thread_id = thread) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return ActionOutcome.Failed }
        return when (action.verb) {
            NotificationVerb.Approve, NotificationVerb.Deny -> approve(core, action, ws, thread)
            NotificationVerb.Reply -> reply(core, ws, thread, action.reply ?: return ActionOutcome.Failed)
            NotificationVerb.Stop -> stop(core, ws, thread)
            NotificationVerb.Open -> ActionOutcome.Opened
        }
    }

    private suspend fun approve(core: CoreHost, action: NotificationAction, ws: String, thread: String): ActionOutcome {
        val decision = if (action.verb == NotificationVerb.Approve) ApprovalDecision.Approve else ApprovalDecision.Deny
        val selector = chatSelector("thread", ws, thread)
        // Wait for the thread to load, then for this turn's pending approval (it may never come).
        core.awaitView(selector, timeoutMs) { threadOf(it) } ?: return ActionOutcome.Unreachable
        val target = core.awaitView(selector, timeoutMs) { value ->
            threadOf(value)?.approval?.takeIf { it.resolution != "pending" && (action.turnId == null || it.turn_id == action.turnId) }
        }?.let { ApprovalTarget.of(ws, thread, it) } ?: return ActionOutcome.AlreadyAnswered
        val sent = decideApproval(core, target, decision) as? DecideResult.Sent ?: return ActionOutcome.Failed
        val op = withTimeoutOrNull(timeoutMs) { awaitOperation(core, sent.intentId) } ?: return ActionOutcome.Failed
        return when {
            op.state == "succeeded" -> if (decision == ApprovalDecision.Approve) ActionOutcome.Approved else ActionOutcome.Denied
            staleApprovalError(op.error) -> ActionOutcome.AlreadyAnswered
            else -> ActionOutcome.Failed
        }
    }

    /** RemoteInput reply: a send when idle, a queued follow-up while a turn runs. Any saved draft is restored. */
    private suspend fun reply(core: CoreHost, ws: String, thread: String, text: String): ActionOutcome {
        val threadSelector = chatSelector("thread", ws, thread)
        val composerSelector = chatSelector("composer", ws, thread)
        core.awaitView(threadSelector, timeoutMs) { threadOf(it) } ?: return ActionOutcome.Unreachable
        val before = core.awaitView(composerSelector, timeoutMs) { composerOf(it) } ?: return ActionOutcome.Unreachable
        val saved = before.draft.takeIf { it.text.isNotBlank() || it.attachments.isNotEmpty() }
        if (!dispatch(core) { id, n, w -> EventDraftSet(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = ws,
                thread_id = thread, text = text, attachments = emptyList()) }) return ActionOutcome.Failed
        val composer = core.awaitView(composerSelector, timeoutMs) { value -> composerOf(value)?.takeIf { it.draft.text == text } }
            ?: return ActionOutcome.Failed
        val running = (core.awaitView(threadSelector, timeoutMs) { threadOf(it) })?.turn != null
        val ok = dispatch(core) { id, n, w ->
            if (running) EventFollowupSubmit(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = ws, thread_id = thread,
                draft_revision = composer.draft.revision, kind = EventFollowupSubmitKind.queue)
            else EventSend(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = ws, thread_id = thread, draft_revision = composer.draft.revision)
        }
        if (saved != null) {
            val references = saved.attachments.map { AttachmentInput(local_id = it.local_id, name = it.name, mime = it.mime,
                byte_size = it.byte_size, bytes_base64 = "") }
            dispatch(core) { id, n, w -> EventDraftSet(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = ws,
                thread_id = thread, text = saved.text, attachments = references) }
        }
        return if (!ok) ActionOutcome.Failed else if (running) ActionOutcome.ReplyQueued else ActionOutcome.ReplySent
    }

    private suspend fun stop(core: CoreHost, ws: String, thread: String): ActionOutcome {
        val view = core.awaitView(chatSelector("thread", ws, thread), timeoutMs) { threadOf(it) } ?: return ActionOutcome.Unreachable
        val turn = view.turn ?: return ActionOutcome.NotRunning
        return if (dispatch(core) { id, n, w -> EventTurnCancel(now_ms = n, wall_time_ms = w, intent_id = id, workspace_id = ws,
                thread_id = thread, turn_id = turn.turn_id) }) ActionOutcome.Stopped else ActionOutcome.Failed
    }

    /** Sends one intent and waits for its receipt; true only when it succeeded. */
    private suspend fun dispatch(core: CoreHost, event: (String, Long, Long) -> Event): Boolean {
        val id = UUID.randomUUID().toString()
        try { core.send { n, w -> event(id, n, w) } } catch (e: CancellationException) { throw e } catch (_: Exception) { return false }
        return withTimeoutOrNull(timeoutMs) { awaitOperation(core, id) }?.state == "succeeded"
    }
}

/**
 * Activity-scoped consumer of [NotificationActionQueue]; a ViewModel so rotation does not
 * interrupt a running action. Also hands decrypted pushes to the live cores (`push_received`).
 */
internal class NotificationActionsModel(
    private val hosts: HostsModel,
    private val push: PushCenter,
    lock: AppLockModel?,
    private val toast: (String) -> Unit,
) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val links = MutableStateFlow<ThreadLink?>(null)
    private val runner = NotificationActionRunner(hosts, links, unlocked = {
        lock == null || withTimeoutOrNull(UNLOCK_WAIT_MS) { lock.state.first { it.loaded && !it.locked } } != null
    })
    private val forward: (PushNotification) -> Unit = { model -> scope.launch { forward(model) } }

    init {
        push.forward = forward
        scope.launch {
            for (action in push.actions.actions) {
                if (action.verb != NotificationVerb.Open) push.notifier.cancel(action.tag, action.notificationId)
                launch {
                    val outcome = try { runner.run(action) } catch (e: CancellationException) { throw e } catch (_: Exception) { ActionOutcome.Failed }
                    outcome.message?.let(toast)
                }
            }
        }
    }

    private suspend fun forward(model: PushNotification) {
        val host = model.host_id ?: return
        val ws = model.workspace_id ?: return
        val thread = model.thread_id ?: return
        val turn = model.turn_id ?: return
        val core = withTimeoutOrNull(5_000) { hosts.core(host) } ?: return
        try {
            core.send { n, w -> EventPushReceived(now_ms = n, wall_time_ms = w, workspace_id = ws, thread_id = thread, turn_id = turn, kind = model.kind) }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { }
    }

    fun consumeLink(link: ThreadLink) { links.compareAndSet(link, null) }

    override fun onCleared() {
        if (push.forward === forward) push.forward = null
        scope.cancel()
    }

    private companion object {
        /** An action waits this long for the user to unlock Verde before it is dropped. */
        const val UNLOCK_WAIT_MS = 2 * 60_000L
    }
}

/**
 * Posts "still running" notices for chat panes with a live turn when Verde leaves the
 * foreground (the WS closes then), and clears them on return. Only while push is on, so a
 * completion push can replace them.
 */
internal suspend fun observeRunningTurns(foreground: StateFlow<Boolean>, hosts: HostsModel, push: PushCenter, hideContent: () -> Boolean) {
    foreground.collect { visible ->
        if (visible) { push.notifier.cancelAllRunning(); return@collect }
        if (push.registrar.state.value.status != PushStatus.On) return@collect
        for (row in hosts.state.value.rows) {
            if (row.view?.auth_state != "paired") continue
            val core = withTimeoutOrNull(1_000) { hosts.core(row.saved.id) } ?: continue
            val running = core.home.value?.data?.items.orEmpty().filter { it.kind == "chat" && it.thread_id != null && it.status == "running" }
            if (running.isNotEmpty()) push.notifier.showRunning(row.saved.id, running.take(MAX_RUNNING), hideContent())
        }
    }
}

private const val MAX_RUNNING = 8

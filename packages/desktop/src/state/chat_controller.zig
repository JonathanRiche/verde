//! Cross-thread send accounting and approval state transitions.

const std = @import("std");
const builtin = @import("builtin");
const headless = @import("headless");
const ai_harness = @import("../providers/harness.zig");
const app_config = @import("../app/config.zig");
const bang_commands = @import("../workspace/bang_commands.zig");
const chat_threads = @import("../chat/threads.zig");
const db_client = @import("../db/client.zig");
const db_types = @import("../db/types.zig");
const notifier = @import("../app/notifier.zig");
const runtime_log = @import("../runtime/log.zig");
const sessionizer = @import("../terminal/sessionizer.zig");
const send_runner = @import("../chat/send_runner.zig");
const loop_wakeup = @import("loop_wakeup");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const chat_types = @import("chat_types.zig");
const command_controller = @import("command_controller.zig");
const herdr_types = @import("herdr_types.zig");
const project_state = @import("project.zig");
const provider_models = @import("provider_models.zig");
const storage_mod = @import("storage.zig");
const utils = @import("../utils.zig");

const log = std.log.scoped(.native_shell);
const ChatMessage = chat_types.ChatMessage;
const ChatImageAttachment = chat_types.ChatImageAttachment;
const ChatThread = chat_types.ChatThread;
const BackgroundTask = chat_types.BackgroundTask;
const OpeningExchange = chat_types.OpeningExchange;
const PendingApproval = chat_types.PendingApproval;
const PendingDiffFile = chat_types.PendingDiffFile;
const PendingTimelineEvent = chat_types.PendingTimelineEvent;
const SendResultPayload = chat_types.SendResultPayload;
const SendState = chat_types.SendState;
const SendStatus = chat_types.SendStatus;
const FollowupKind = chat_types.FollowupKind;
const PendingFollowup = chat_types.PendingFollowup;
const TitleGenerationState = chat_types.TitleGenerationState;
const TitleGenerationRequest = chat_types.TitleGenerationRequest;
const Provider = provider_models.Provider;
const ProviderExecutionTarget = herdr_types.ProviderExecutionTarget;
const Project = project_state.Project;
const SlashCommandStatus = command_controller.SlashCommandStatus;
const PendingSlashCommandDetails = command_controller.PendingSlashCommandDetails;
const freePendingFollowup = chat_types.freePendingFollowup;
const freePendingApprovalLocked = utils.freePendingApprovalLocked;
const freePendingDiffFiles = utils.freePendingDiffFiles;
const freePendingDiffFilesLocked = utils.freePendingDiffFilesLocked;
const freePendingTimelineEvents = utils.freePendingTimelineEvents;
const freePendingTimelineEventsLocked = utils.freePendingTimelineEventsLocked;
const approvalPolicyForMode = utils.approvalPolicyForMode;
const cancelLingeringToolCallEvents = utils.cancelLingeringToolCallEvents;
const sandboxModeForMode = utils.sandboxModeForMode;
const serviceTierForMode = utils.serviceTierForMode;
const flushPendingAssistantTextLocked = utils.flushPendingAssistantTextLocked;
const transientThinkStatus = utils.transientThinkStatus;
const upsertPendingToolCallEvent = utils.upsertPendingToolCallEvent;
const slashCommandFallbackName = command_controller.slashCommandFallbackName;
const pendingTimelineEventsContainAssistant = utils.pendingTimelineEventsContainAssistant;
const BACKGROUND_TASK_POLL_MS: i64 = 1000;
const CODEX_BACKGROUND_TASK_POLL_MS: i64 = 2000;
const CODEX_BACKGROUND_TASK_POLL_MAX_MS: i64 = 60_000;
// Daemon tailing is synchronous IPC. Bounding it to Verde's active frame tier
// preserves every display opportunity while avoiding duplicate RPCs in event bursts.
const DAEMON_CHAT_POLL_INTERVAL_MS: i64 = 16;
// Time budget for that synchronous tail: the next poll waits at least
// FACTOR× the last round trip's measured cost, so a slow daemon consumes at
// most ~1/FACTOR of the render thread instead of stalling every frame.
const DAEMON_CHAT_POLL_BUDGET_FACTOR: i64 = 4;
// Backoff ceiling. Matches the ~1Hz "Working - mm:ss" repaint floor so a
// flapping daemon (e.g. 250ms connect timeouts) still gets tailed about once
// a second rather than being abandoned.
const DAEMON_CHAT_POLL_BACKOFF_MAX_MS: i64 = 1000;
// Re-attached turns can carry megabytes of Cursor edit events. Ask the daemon
// for bounded replay pages so one synchronous tail cannot exceed the IPC cap
// or monopolize the render thread.
const DAEMON_CHAT_TAIL_PAGE_BYTES: usize = 1024 * 1024;
const OPENCODE_LOGO_BYTES = @embedFile("../assets/opencode-logo-dark.png");
const CODEX_LOGO_BYTES = @embedFile("../assets/OpenAI-white-monoblossom.png");
const CLAUDE_LOGO_BYTES = @embedFile("../assets/claude-logo.png");
const CURSOR_LOGO_BYTES = @embedFile("../assets/editor_logos/cursor.png");
const PI_LOGO_BYTES = @embedFile("../assets/pi-logo.png");
const FX_LOGO_BYTES = @embedFile("../assets/fx-logo.png");
const GROK_LOGO_BYTES = @embedFile("../assets/grok-logo.png");

pub const InitialSendSnapshot = struct {
    message_count: usize,
    committed: bool,
    last_activity_at: i64,
    title: ?[:0]u8,

    pub fn init(allocator: std.mem.Allocator, thread: *const ChatThread) !InitialSendSnapshot {
        return .{
            .message_count = thread.messages.items.len,
            .committed = thread.committed,
            .last_activity_at = thread.last_activity_at,
            .title = if (thread.committed) null else try allocator.dupeZ(u8, thread.title),
        };
    }

    pub fn deinit(self: *InitialSendSnapshot, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        self.title = null;
    }

    pub fn restore(self: *InitialSendSnapshot, state: anytype, thread: *ChatThread) void {
        while (thread.messages.items.len > self.message_count) {
            state.releaseMessage(thread.messages.pop().?);
        }
        if (self.title) |title| {
            state.allocator.free(thread.title);
            thread.title = title;
            self.title = null;
        }
        thread.committed = self.committed;
        thread.last_activity_at = self.last_activity_at;
    }
};

fn harnessProviderForDbProvider(provider: Provider) ai_harness.Provider {
    return switch (provider) {
        .opencode => .opencode,
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
    };
}

fn dbProviderForChatTitleProvider(provider: app_config.ChatTitleProvider) Provider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .opencode => .opencode,
    };
}

fn ensureJsonRpcOk(allocator: std.mem.Allocator, response: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    _ = try jsonRpcResult(parsed.value);
}

pub fn initialSendStartFailureMessage(_: anyerror) []const u8 {
    return "Verde could not start this message. Your draft and attachments are still in the composer; try Send again.";
}

fn ambiguousInitialSendFailureMessage() []const u8 {
    return "Verde could not confirm that the provider request started. Your submitted message is preserved above; copy it before retrying.";
}

fn persistenceContention(err: anyerror) bool {
    return err == error.Busy or err == error.BusyRecovery or err == error.BusySnapshot or err == error.BusyTimeout;
}

fn jsonRpcResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidDaemonResponse;
    if (value.object.get("error")) |_| return error.DaemonRequestFailed;
    return value.object.get("result") orelse return error.InvalidDaemonResponse;
}

fn jsonValueI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn jsonValueU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn replacePageOwned(slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const next = try std.heap.page_allocator.dupe(u8, value);
    if (slot.*) |existing| std.heap.page_allocator.free(existing);
    slot.* = next;
}

fn daemonPayloadStringAlloc(payload_json: []const u8, field: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = jsonValueString(parsed.value.object.get(field) orelse .null) orelse return null;
    return std.heap.page_allocator.dupe(u8, value) catch null;
}

/// M5-P4 Amendment 1 display-time filter: background bookkeeping rows are now
/// COMMITTED to the transcript (matching the daemon reducer, so adoption's
/// role+body row compare holds) and hidden only at render time. Hides the
/// codex background snapshot marker unconditionally, and background-command
/// system rows whose body maps to a tracked background task (mirroring the
/// rows the pre-M5-P4 reducer used to skip appending).
pub fn shouldHideBackgroundTranscriptRow(thread: *const ChatThread, author: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, author, "__verde_codex_background_snapshot")) return true;
    if (!ChatThread.isBackgroundCommandEvent(author)) return false;
    // Read-only membership probe: backgroundTaskForEventBody returns mutable
    // task pointers for its other callers, so cast away const here instead of
    // duplicating its four identity-matching rules.
    return backgroundTaskForEventBody(@constCast(thread), body) != null;
}

pub fn backgroundTaskForEventBody(thread: *ChatThread, body: []const u8) ?*BackgroundTask {
    for (thread.background_tasks.items) |*task| {
        if (task.matchesEventBody(body)) return task;
    }
    return null;
}

pub const BangCommandRequest = struct {
    send_state: *SendState,
    command: []u8,
    cwd: []u8,
    require_confirmation: bool,
};

pub const BangPipeReader = struct {
    send_state: *SendState,
    file: std.Io.File,
    label: []const u8,
};

fn bangPipeReader(context: BangPipeReader) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = context.file.reader(threaded.io(), &read_buffer);
    var first_chunk = true;
    while (true) {
        var chunk_buffer: [4096]u8 = undefined;
        const count = reader.interface.readSliceShort(&chunk_buffer) catch break;
        if (count == 0) break;
        context.send_state.mutex.lock();
        if (context.send_state.partial_text.items.len < 2 * 1024 * 1024) {
            if (first_chunk) {
                context.send_state.partial_text.appendSlice(std.heap.page_allocator, context.label) catch {};
                first_chunk = false;
            }
            context.send_state.partial_text.appendSlice(std.heap.page_allocator, chunk_buffer[0..count]) catch {};
            context.send_state.ui_revision +%= 1;
        }
        context.send_state.mutex.unlock();
        loop_wakeup.notify();
    }
}

pub fn bangCommandWorker(request: *BangCommandRequest) void {
    const page_alloc = std.heap.page_allocator;
    const state = request.send_state;
    defer {
        page_alloc.free(request.command);
        page_alloc.free(request.cwd);
        page_alloc.destroy(request);
        state.worker_done.store(true, .release);
    }

    if (request.require_confirmation) {
        state.mutex.lock();
        while (state.status == .pending and state.approval_decision == null and !state.stop_requested) {
            state.condition.wait(&state.mutex);
        }
        const approved = state.approval_decision == .approve and !state.stop_requested;
        state.approval_decision = null;
        state.mutex.unlock();
        if (!approved) {
            state.mutex.lock();
            state.status = .aborted;
            state.mutex.unlock();
            loop_wakeup.notify();
            return;
        }
    }

    var threaded: std.Io.Threaded = .init(page_alloc, .{});
    defer threaded.deinit();
    const argv = bang_commands.shellArgv(request.command);
    const child_ptr = page_alloc.create(platform_process.OwnedChild) catch {
        state.mutex.lock();
        state.status = .failed;
        state.error_message = std.fmt.allocPrint(page_alloc, "Could not start command.", .{}) catch null;
        state.mutex.unlock();
        loop_wakeup.notify();
        return;
    };
    child_ptr.* = platform_process.spawn(page_alloc, threaded.io(), .{
        .argv = &argv,
        .cwd = .{ .path = request.cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        page_alloc.destroy(child_ptr);
        state.mutex.lock();
        state.status = .failed;
        state.error_message = std.fmt.allocPrint(page_alloc, "Could not start command: {s}", .{@errorName(err)}) catch null;
        state.mutex.unlock();
        loop_wakeup.notify();
        return;
    };

    state.mutex.lock();
    state.active_local_child = child_ptr;
    const stop_before_register = state.stop_requested;
    state.mutex.unlock();
    if (stop_before_register) child_ptr.terminateTree();

    const stdout_thread = std.Thread.spawn(.{}, bangPipeReader, .{BangPipeReader{
        .send_state = state,
        .file = child_ptr.child.stdout.?,
        .label = "stdout:\n",
    }}) catch null;
    const stderr_thread = std.Thread.spawn(.{}, bangPipeReader, .{BangPipeReader{
        .send_state = state,
        .file = child_ptr.child.stderr.?,
        .label = "\nstderr:\n",
    }}) catch null;
    const term = child_ptr.wait(threaded.io()) catch null;
    if (stdout_thread) |worker| worker.join();
    if (stderr_thread) |worker| worker.join();
    child_ptr.child.stdout = null;
    child_ptr.child.stderr = null;

    state.mutex.lock();
    state.active_local_child = null;
    const cancelled = state.stop_requested;
    const duration_ms = @max(unixTimestampMs() - state.started_at_ms, 0);
    const output = state.partial_text.items;
    const exit_code: ?u8 = if (term) |value| switch (value) {
        .exited => |code| code,
        else => null,
    } else null;
    const status: ai_harness.ToolCallStatus = if (cancelled)
        .cancelled
    else if (exit_code != null and exit_code.? == 0)
        .completed
    else
        .failed;
    const author = if (status == .completed) "Ran command" else "Command failed";
    var exit_buffer: [16]u8 = undefined;
    const exit_label = if (exit_code) |code|
        std.fmt.bufPrint(&exit_buffer, "{d}", .{code}) catch "unknown"
    else
        "terminated";
    const body = std.fmt.allocPrint(page_alloc, "$ {s}\n\nWorkspace: {s}\nShell: {s}\nExit: {s}\nDuration: {d} ms\nStatus: {s}\n\n{s}", .{
        request.command,
        request.cwd,
        bang_commands.shellName(),
        exit_label,
        duration_ms,
        if (cancelled) "cancelled" else "finished",
        if (output.len > 0) output else "(no output)",
    }) catch null;
    if (body) |owned_body| {
        if (page_alloc.dupe(u8, author)) |owned_author| {
            if (state.pending_events.items.len > 0) {
                const event = &state.pending_events.items[0];
                page_alloc.free(event.author);
                page_alloc.free(event.body);
                event.author = owned_author;
                event.body = owned_body;
                event.tool_call_status = status;
            } else {
                state.pending_events.append(page_alloc, .{
                    .role = .system,
                    .author = owned_author,
                    .body = owned_body,
                    .tool_call_kind = .execute,
                    .tool_call_status = status,
                    .tool_call_title = page_alloc.dupe(u8, request.command) catch null,
                }) catch {
                    page_alloc.free(owned_author);
                    page_alloc.free(owned_body);
                };
            }
        } else |_| {
            page_alloc.free(owned_body);
        }
    }
    state.partial_text.clearRetainingCapacity();
    const empty_thread = page_alloc.dupe(u8, "") catch null;
    const empty_reply = page_alloc.dupe(u8, "") catch null;
    if (empty_thread != null and empty_reply != null) {
        state.result = .{ .provider_thread_id = empty_thread.?, .reply_text = empty_reply.? };
        state.status = if (cancelled) .aborted else .completed;
    } else {
        if (empty_thread) |value| page_alloc.free(value);
        if (empty_reply) |value| page_alloc.free(value);
        state.status = .failed;
    }
    state.ui_revision +%= 1;
    state.mutex.unlock();
    page_alloc.destroy(child_ptr);
    loop_wakeup.notify();
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

fn monotonicMs() i64 {
    return @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
}

fn workerCleanupPending(terminal: bool, has_worker: bool, worker_done: bool) bool {
    return terminal and has_worker and !worker_done;
}

test "render polling waits for worker cleanup before joining" {
    try std.testing.expect(workerCleanupPending(true, true, false));
    try std.testing.expect(!workerCleanupPending(true, true, true));
    try std.testing.expect(!workerCleanupPending(true, false, false));
    try std.testing.expect(!workerCleanupPending(false, true, false));
}

pub fn titleGenerationWorker(request: *TitleGenerationRequest) void {
    const page_alloc = std.heap.page_allocator;
    const state = request.state;
    defer {
        page_alloc.free(request.project_path);
        page_alloc.free(request.prompt);
        page_alloc.free(request.model_ref);
        page_alloc.destroy(request);
        loop_wakeup.notify();
        state.worker_done.store(true, .release);
    }

    const send_result = send_runner.run(page_alloc, .{
        .provider = request.provider,
        .harness_kind = .local_cli,
        .project_path = request.project_path,
        .prompt = request.prompt,
        .model_ref = request.model_ref,
        .fast_mode = if (request.provider == .codex) .on else .off,
        .access_mode = .supervised,
    }, .{}) catch |err| {
        finishTitleGenerationFailure(request.state, @errorName(err));
        return;
    };
    defer page_alloc.free(send_result.provider_thread_id);
    defer page_alloc.free(send_result.reply_text);

    const title = chat_threads.makeGeneratedThreadTitle(page_alloc, send_result.reply_text) catch |err| {
        finishTitleGenerationFailure(request.state, @errorName(err));
        return;
    } orelse {
        finishTitleGenerationFailure(request.state, "The model returned an empty title.");
        return;
    };

    request.state.mutex.lock();
    defer request.state.mutex.unlock();
    request.state.result = title;
    request.state.status = .completed;
}

fn finishTitleGenerationFailure(state: *TitleGenerationState, message: []const u8) void {
    const owned_message = std.heap.page_allocator.dupe(u8, message) catch null;
    state.mutex.lock();
    defer state.mutex.unlock();
    state.error_message = owned_message;
    state.status = .failed;
}

pub const State = struct {
    pending_send_count: usize = 0,
    codex_background_poll: CodexBackgroundPollState = .{},
    daemon_tail_response_buffer: ?[]u8 = null,
    daemon_tail_connection: sessionizer.ReusableRequestConnection = .{},
    /// In-flight chat.turn.start acceptance workers (7.5): the RPC runs off
    /// the event thread; outcomes commit on the main thread in pollSend.
    acceptance_dispatches: std.ArrayListUnmanaged(*AcceptanceDispatch) = .empty,
    /// Single-slot chat.turn.tail worker: the tail RPC runs off the render
    /// thread; the response commits on the main thread in pollSend. One slot
    /// keeps the reusable connection and response buffer exclusive.
    daemon_tail_worker: ?std.Thread = null,
    daemon_tail_args: ?*DaemonTailWorkerArgs = null,

    /// Releases chat-controller-owned polling scratch space.
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.daemon_tail_worker) |worker| worker.join();
        self.daemon_tail_worker = null;
        if (self.daemon_tail_args) |args| args.destroy();
        self.daemon_tail_args = null;
        for (self.acceptance_dispatches.items) |dispatch| {
            if (dispatch.worker) |worker| worker.join();
            dispatch.destroy(allocator);
        }
        self.acceptance_dispatches.deinit(std.heap.page_allocator);
        self.daemon_tail_connection.deinit();
        if (self.daemon_tail_response_buffer) |buffer| allocator.free(buffer);
        self.daemon_tail_response_buffer = null;
    }

    pub fn beginSend(self: *State) void {
        self.pending_send_count += 1;
    }

    pub fn finishSend(self: *State) void {
        if (self.pending_send_count > 0) self.pending_send_count -= 1;
    }

    pub fn hasPending(self: State) bool {
        return self.pending_send_count > 0;
    }

    fn daemonTailResponseBuffer(self: *State, allocator: std.mem.Allocator) ![]u8 {
        if (self.daemon_tail_response_buffer) |buffer| return buffer;
        const buffer = try allocator.alloc(u8, sessionizer.MAX_RESPONSE_BYTES);
        self.daemon_tail_response_buffer = buffer;
        return buffer;
    }
};

test "daemon chat tail response buffer is reused" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    const first = try state.daemonTailResponseBuffer(std.testing.allocator);
    const second = try state.daemonTailResponseBuffer(std.testing.allocator);

    try std.testing.expectEqual(sessionizer.MAX_RESPONSE_BYTES, first.len);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(second.ptr));
}

const CodexBackgroundPollStatus = enum {
    idle,
    pending,
    completed,
};

const CodexBackgroundPollRequest = struct {
    local_thread_id: []u8,
    provider_thread_id: []u8,
    process_id: []u8,
    cwd: []u8,
    remote_host: ?[]u8,

    fn deinit(self: *CodexBackgroundPollRequest) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.local_thread_id);
        allocator.free(self.provider_thread_id);
        allocator.free(self.process_id);
        allocator.free(self.cwd);
        if (self.remote_host) |value| allocator.free(value);
        allocator.destroy(self);
    }
};

const CodexBackgroundPollState = struct {
    mutex: std.Io.Mutex = .init,
    worker: ?std.Thread = null,
    request: ?*CodexBackgroundPollRequest = null,
    status: CodexBackgroundPollStatus = .idle,
    running: ?bool = null,
};

fn codexBackgroundPollWorker(state: *CodexBackgroundPollState, request: *const CodexBackgroundPollRequest) void {
    const allocator = std.heap.page_allocator;
    const config: ai_harness.ProviderConfig = .{ .codex = .{
        .cwd = request.cwd,
        .launch_on_connect = false,
        .remote_ssh = if (request.remote_host) |host| .{ .host = host, .cwd = request.cwd } else null,
    } };
    var running: ?bool = null;
    if (ai_harness.connect(allocator, config)) |client_value| {
        var client = client_value;
        defer client.deinit();
        running = client.backgroundTerminalIsRunning(request.provider_thread_id, request.process_id) catch null;
    } else |_| {}

    const io = std.Io.Threaded.global_single_threaded.io();
    state.mutex.lockUncancelable(io);
    state.running = running;
    state.status = .completed;
    state.mutex.unlock(io);
    loop_wakeup.notify();
}

pub fn resolveApprovalLocked(send_state: *SendState, decision: ai_harness.ApprovalDecision) bool {
    if (send_state.pending_approval == null) return false;
    send_state.approval_decision = decision;
    send_state.ui_revision +%= 1;
    send_state.condition.broadcast();
    return true;
}

pub fn syncDaemonPendingApprovalLocked(send_state: *SendState, approval_value: std.json.Value) !bool {
    const page_alloc = std.heap.page_allocator;
    if (approval_value == .null) {
        if (send_state.pending_approval == null) return false;
        chat_types.freePendingApproval(page_alloc, &send_state.pending_approval);
        send_state.approval_decision = null;
        return true;
    }
    if (approval_value != .object) return error.InvalidDaemonResponse;

    const call_id = jsonValueString(approval_value.object.get("call_id") orelse .null) orelse "";
    const title = jsonValueString(approval_value.object.get("title") orelse .null) orelse "Approval requested";
    const body = jsonValueString(approval_value.object.get("body") orelse .null) orelse "";
    if (send_state.pending_approval) |current| {
        if (std.mem.eql(u8, current.call_id, call_id) and
            std.mem.eql(u8, current.title, title) and
            std.mem.eql(u8, current.body, body)) return false;
    }

    const owned_call_id = try page_alloc.dupe(u8, call_id);
    errdefer page_alloc.free(owned_call_id);
    const owned_title = try page_alloc.dupe(u8, title);
    errdefer page_alloc.free(owned_title);
    const owned_body = try page_alloc.dupe(u8, body);
    errdefer page_alloc.free(owned_body);
    chat_types.freePendingApproval(page_alloc, &send_state.pending_approval);
    send_state.pending_approval = .{
        .call_id = owned_call_id,
        .title = owned_title,
        .body = owned_body,
    };
    send_state.approval_decision = null;
    return true;
}

fn jsonValueString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

test "approval transitions replace clear and resolve pending state" {
    const allocator = std.testing.allocator;
    var send_state: SendState = .{};
    defer chat_types.freePendingApproval(allocator, &send_state.pending_approval);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"call_id":"call-1","title":"Run command","body":"Allow?"}
    , .{});
    defer parsed.deinit();

    // The production transition uses page-owned payloads.
    try std.testing.expect(try syncDaemonPendingApprovalLocked(&send_state, parsed.value));
    defer chat_types.freePendingApproval(std.heap.page_allocator, &send_state.pending_approval);
    try std.testing.expect(resolveApprovalLocked(&send_state, .approve));
    try std.testing.expectEqual(ai_harness.ApprovalDecision.approve, send_state.approval_decision.?);
    try std.testing.expect(try syncDaemonPendingApprovalLocked(&send_state, .null));
    try std.testing.expect(send_state.pending_approval == null);
    try std.testing.expect(send_state.approval_decision == null);
    try std.testing.expect(!try syncDaemonPendingApprovalLocked(&send_state, .null));
}

test "control transfer failure stays distinct actionable and clears on success" {
    var send_state: SendState = .{};
    defer {
        chat_types.freePendingApproval(std.heap.page_allocator, &send_state.pending_approval);
        if (send_state.control_error_message) |message| std.heap.page_allocator.free(message);
    }
    send_state.status = .pending;
    send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "call"),
        .title = try std.heap.page_allocator.dupe(u8, "Approve"),
        .body = try std.heap.page_allocator.dupe(u8, "Proceed?"),
    };

    setControlFailureLocked(&send_state, "rejected");
    try std.testing.expect(send_state.control_error_message != null);
    try std.testing.expect(send_state.error_message == null);
    try std.testing.expect(send_state.pending_approval != null);
    try std.testing.expect(send_state.approval_decision == null);
    clearControlFailureLocked(&send_state);
    try std.testing.expect(send_state.control_error_message == null);
    try std.testing.expect(resolveApprovalLocked(&send_state, .approve));
    try std.testing.expectEqual(ai_harness.ApprovalDecision.approve, send_state.approval_decision.?);
}

test "real addressed control seams roll back missing daemon prerequisites" {
    const allocator = std.testing.allocator;
    const FakeState = struct {
        const ApprovalMutation = enum { none, replace, clear };
        allocator: std.mem.Allocator,
        reject_cancel: bool = false,
        reject_approval: bool = false,
        replace_cancel_turn: bool = false,
        claim_cancel: bool = false,
        allow_execution_target: bool = false,
        reject_interrupt: bool = false,
        replace_interrupt_turn: bool = false,
        claim_interrupt: bool = false,
        approval_mutation: ApprovalMutation = .none,
        thread: ?*ChatThread = null,

        pub fn cancelDaemonChatTurn(self: *@This(), _: []const u8) !void {
            if (self.replace_cancel_turn) {
                const send_state = self.thread.?.send_state;
                send_state.mutex.lock();
                if (send_state.daemon_turn_id) |old| std.heap.page_allocator.free(old);
                send_state.daemon_turn_id = std.heap.page_allocator.dupe(u8, "new-turn") catch null;
                send_state.started_at_ms += 1;
                send_state.stop_requested = true;
                send_state.stop_signal_sent = false;
                send_state.mutex.unlock();
            }
            if (self.claim_cancel) {
                const send_state = self.thread.?.send_state;
                send_state.mutex.lock();
                send_state.stop_signal_sent = true;
                send_state.mutex.unlock();
            }
            if (self.reject_cancel) return error.DaemonRequestFailed;
        }
        pub fn approveDaemonChatTurn(self: *@This(), _: []const u8, _: []const u8, _: ai_harness.ApprovalDecision) !void {
            if (self.reject_approval) return error.DaemonRequestFailed;
            if (self.approval_mutation != .none) {
                const send_state = self.thread.?.send_state;
                send_state.mutex.lock();
                chat_types.freePendingApproval(std.heap.page_allocator, &send_state.pending_approval);
                if (self.approval_mutation == .replace) {
                    send_state.pending_approval = .{
                        .call_id = std.heap.page_allocator.dupe(u8, "new-call") catch unreachable,
                        .title = std.heap.page_allocator.dupe(u8, "New approval") catch unreachable,
                        .body = std.heap.page_allocator.dupe(u8, "New request") catch unreachable,
                    };
                }
                send_state.approval_decision = null;
                send_state.mutex.unlock();
            }
        }
        pub fn providerExecutionTargetForProjectThread(self: *@This(), _: usize, _: *const ChatThread, _: usize) ?ProviderExecutionTarget {
            return if (self.allow_execution_target) .{ .local = "/tmp" } else null;
        }
        pub fn interruptThreadViaHarness(self: *@This(), _: ProviderExecutionTarget, _: Provider, _: []const u8, _: ?[]u8) !void {
            const thread = self.thread.?;
            const send_state = thread.send_state;
            if (self.replace_interrupt_turn) {
                send_state.mutex.lock();
                send_state.started_at_ms += 1;
                if (thread.provider_thread_id) |old| self.allocator.free(old);
                thread.provider_thread_id = self.allocator.dupeZ(u8, "replacement-provider") catch null;
                send_state.stop_requested = true;
                send_state.stop_signal_sent = false;
                send_state.mutex.unlock();
            }
            if (self.claim_interrupt) {
                send_state.mutex.lock();
                send_state.stop_signal_sent = true;
                send_state.mutex.unlock();
            }
            if (self.reject_interrupt) return error.InterruptRejected;
        }
        pub fn setSidebarNotice(_: *@This(), _: []const u8) void {}
    };
    var fake: FakeState = .{ .allocator = allocator };
    var thread = try ChatThread.init(allocator, "Companion");
    defer thread.deinit(allocator);
    fake.thread = &thread;

    // The addressed stop seam must ignore every non-actionable state.
    const no_op_cases = [_]struct {
        status: SendStatus,
        stop_requested: bool,
        stop_signal_sent: bool,
    }{
        .{ .status = .idle, .stop_requested = true, .stop_signal_sent = false },
        .{ .status = .completed, .stop_requested = true, .stop_signal_sent = false },
        .{ .status = .pending, .stop_requested = false, .stop_signal_sent = false },
        .{ .status = .pending, .stop_requested = true, .stop_signal_sent = true },
    };
    for (no_op_cases) |case| {
        thread.send_state.status = case.status;
        thread.send_state.stop_requested = case.stop_requested;
        thread.send_state.stop_signal_sent = case.stop_signal_sent;
        const ui_revision = thread.send_state.ui_revision;
        issuePendingThreadStop(&fake, null, "/tmp", &thread);
        try std.testing.expectEqual(case.status, thread.send_state.status);
        try std.testing.expectEqual(case.stop_requested, thread.send_state.stop_requested);
        try std.testing.expectEqual(case.stop_signal_sent, thread.send_state.stop_signal_sent);
        try std.testing.expectEqual(ui_revision, thread.send_state.ui_revision);
        try std.testing.expect(thread.send_state.control_error_message == null);
    }

    thread.send_state.status = .pending;
    thread.send_state.daemon_owned = true;
    thread.send_state.stop_requested = true;
    thread.send_state.stop_signal_sent = false;

    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expect(!thread.send_state.stop_requested);
    try std.testing.expect(!thread.send_state.stop_signal_sent);
    try std.testing.expectEqualStrings(
        "Could not address the running provider turn. Try again.",
        thread.send_state.control_error_message.?,
    );

    thread.send_state.daemon_owned = false;
    thread.send_state.stop_requested = true;
    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expect(!thread.send_state.stop_requested);
    try std.testing.expectEqualStrings(
        "Could not address the running provider turn. Try again.",
        thread.send_state.control_error_message.?,
    );
    thread.send_state.daemon_owned = true;

    thread.send_state.daemon_turn_id = try std.heap.page_allocator.dupe(u8, "turn");
    thread.send_state.stop_requested = true;
    fake.reject_cancel = true;
    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expect(!thread.send_state.stop_requested);
    try std.testing.expect(!thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.control_error_message != null);
    thread.send_state.stop_requested = true;
    fake.reject_cancel = false;
    fake.replace_cancel_turn = true;
    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expect(!thread.send_state.stop_signal_sent);
    try std.testing.expectEqualStrings("new-turn", thread.send_state.daemon_turn_id.?);
    try std.testing.expect(thread.send_state.stop_requested);
    try std.testing.expect(thread.send_state.control_error_message != null);
    fake.replace_cancel_turn = false;
    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expect(thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.control_error_message == null);

    thread.send_state.stop_signal_sent = false;
    thread.send_state.stop_requested = true;
    fake.claim_cancel = true;
    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expect(thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.stop_requested);
    try std.testing.expect(thread.send_state.control_error_message != null);
    fake.claim_cancel = false;

    thread.send_state.stop_signal_sent = false;
    thread.send_state.stop_requested = true;
    fake.replace_cancel_turn = true;
    fake.reject_cancel = true;
    issuePendingThreadStop(&fake, null, "/tmp", &thread);
    try std.testing.expectEqualStrings("new-turn", thread.send_state.daemon_turn_id.?);
    try std.testing.expect(thread.send_state.stop_requested);
    try std.testing.expect(!thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.control_error_message != null);
    fake.replace_cancel_turn = false;
    fake.reject_cancel = false;

    thread.send_state.stop_requested = false;
    thread.send_state.stop_signal_sent = false;
    thread.send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "call"),
        .title = try std.heap.page_allocator.dupe(u8, "Approve"),
        .body = try std.heap.page_allocator.dupe(u8, "Proceed?"),
    };
    fake.reject_approval = true;
    try std.testing.expect(!resolveThreadPendingApproval(&fake, &thread, .approve));
    try std.testing.expect(thread.send_state.pending_approval != null);
    try std.testing.expect(thread.send_state.approval_decision == null);
    try std.testing.expect(thread.send_state.control_error_message != null);
    fake.reject_approval = false;
    fake.approval_mutation = .replace;
    try std.testing.expect(!resolveThreadPendingApproval(&fake, &thread, .approve));
    try std.testing.expectEqualStrings("new-call", thread.send_state.pending_approval.?.call_id);
    try std.testing.expect(thread.send_state.approval_decision == null);
    try std.testing.expect(thread.send_state.control_error_message != null);
    fake.approval_mutation = .clear;
    try std.testing.expect(!resolveThreadPendingApproval(&fake, &thread, .approve));
    try std.testing.expect(thread.send_state.pending_approval == null);
    try std.testing.expect(thread.send_state.control_error_message != null);
    thread.send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "final-call"),
        .title = try std.heap.page_allocator.dupe(u8, "Final"),
        .body = try std.heap.page_allocator.dupe(u8, "Proceed"),
    };
    fake.approval_mutation = .none;
    try std.testing.expect(resolveThreadPendingApproval(&fake, &thread, .approve));
    try std.testing.expectEqual(ai_harness.ApprovalDecision.approve, thread.send_state.approval_decision.?);
    try std.testing.expect(thread.send_state.control_error_message == null);

    thread.send_state.daemon_owned = false;
    thread.send_state.stop_signal_sent = false;
    thread.send_state.stop_requested = true;
    thread.provider_thread_id = try allocator.dupeZ(u8, "provider-thread");
    issuePendingThreadStop(&fake, 0, "/tmp", &thread);
    try std.testing.expect(!thread.send_state.stop_requested);
    try std.testing.expect(!thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.control_error_message != null);

    thread.send_state.stop_requested = true;
    fake.allow_execution_target = true;
    fake.replace_interrupt_turn = true;
    fake.reject_interrupt = true;
    issuePendingThreadStop(&fake, 0, "/tmp", &thread);
    try std.testing.expectEqualStrings("replacement-provider", thread.provider_thread_id.?);
    try std.testing.expect(thread.send_state.stop_requested);
    try std.testing.expect(!thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.control_error_message != null);
    fake.replace_interrupt_turn = false;
    fake.reject_interrupt = false;

    thread.send_state.stop_requested = true;
    fake.claim_interrupt = true;
    issuePendingThreadStop(&fake, 0, "/tmp", &thread);
    try std.testing.expect(thread.send_state.stop_signal_sent);
    try std.testing.expect(thread.send_state.stop_requested);
    try std.testing.expect(thread.send_state.control_error_message != null);
}

test "global polling leaves idle and completed pane-less Companion stop state untouched" {
    const allocator = std.testing.allocator;
    const PollState = struct {
        allocator: std.mem.Allocator,
        chat_controller: State = .{},
        project_controller: struct {
            projects: std.ArrayList(Project) = .empty,
        } = .{},
        poll_visits: usize = 0,

        pub fn pollTitleGenerations(_: *@This()) bool {
            return false;
        }
        pub fn pollThreadSend(self: *@This(), project_index: usize, _: usize, thread: *ChatThread) bool {
            self.poll_visits += 1;
            issuePendingThreadStop(
                self,
                project_index,
                self.project_controller.projects.items[project_index].path,
                thread,
            );
            return false;
        }
        pub fn cancelDaemonChatTurn(_: *@This(), _: []const u8) !void {}
        pub fn providerExecutionTargetForProjectThread(_: *@This(), _: usize, _: *const ChatThread, _: usize) ?ProviderExecutionTarget {
            return null;
        }
        pub fn interruptThreadViaHarness(_: *@This(), _: ProviderExecutionTarget, _: Provider, _: []const u8, _: ?[]u8) !void {}
        pub fn setSidebarNotice(_: *@This(), _: []const u8) void {}
    };
    var state: PollState = .{ .allocator = allocator };
    var project = try Project.init(allocator, "poll-companion", "Poll Companion", "/tmp/poll-companion", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    defer {
        for (state.project_controller.projects.items) |*owned_project| owned_project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    const owned_project = &state.project_controller.projects.items[0];
    const pane_count = owned_project.workspace_layout.panes.items.len;
    const companion = try owned_project.ensureCompanionThread(allocator);
    try std.testing.expectEqual(pane_count, owned_project.workspace_layout.panes.items.len);
    const unrelated = &owned_project.threads.items[0];
    unrelated.send_state.status = .pending;
    unrelated.send_state.stop_requested = false;
    state.chat_controller.beginSend();

    for ([_]SendStatus{ .idle, .completed }) |companion_status| {
        companion.send_state.status = companion_status;
        companion.send_state.stop_requested = false;
        companion.send_state.stop_signal_sent = false;
        const ui_revision = companion.send_state.ui_revision;
        const visits_before = state.poll_visits;
        _ = pollSend(&state);
        try std.testing.expectEqual(visits_before + owned_project.threads.items.len, state.poll_visits);
        try std.testing.expectEqual(companion_status, companion.send_state.status);
        try std.testing.expect(!companion.send_state.stop_requested);
        try std.testing.expect(!companion.send_state.stop_signal_sent);
        try std.testing.expectEqual(ui_revision, companion.send_state.ui_revision);
        try std.testing.expect(companion.send_state.control_error_message == null);
    }
}

test "daemon control rejects JSON-RPC error responses" {
    try std.testing.expectError(error.DaemonRequestFailed, ensureJsonRpcOk(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"rejected"}}
    ));
}

test "thread-addressed prompt staging preserves ordered images and legacy first image" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Companion");
    defer thread.deinit(allocator);
    var first = try ChatImageAttachment.init(allocator, "/tmp/first.png", "image/png", 10);
    defer first.deinit(allocator);
    var second = try ChatImageAttachment.init(allocator, "/tmp/second.jpg", "image/jpeg", 20);
    defer second.deinit(allocator);

    try stageThreadPrompt(allocator, &thread, "inspect both", &.{ first, second });
    try std.testing.expectEqualStrings("inspect both", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 2), thread.draftImageCount());
    try std.testing.expectEqualStrings("/tmp/first.png", thread.draft_image.?.path);
    try std.testing.expectEqualStrings("/tmp/second.jpg", thread.draft_extra_images.items[0].path);
}

test "pending follow-up preserves multiple draft images" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Companion");
    defer thread.deinit(allocator);
    try thread.addDraftImage(allocator, "/tmp/first.png", "image/png", 10);
    try thread.addDraftImage(allocator, "/tmp/second.jpg", "image/jpeg", 20);

    var followup: PendingFollowup = .{
        .kind = .steer,
        .prompt = try allocator.dupe(u8, "inspect both"),
    };
    defer followup.deinit(allocator);
    try copyDraftImagesToFollowup(allocator, &thread, &followup.images);

    try std.testing.expectEqual(@as(usize, 2), followup.images.items.len);
    try std.testing.expectEqualStrings("/tmp/first.png", followup.images.items[0].path);
    try std.testing.expectEqualStrings("/tmp/second.jpg", followup.images.items[1].path);
}

test "thread-addressed prompt staging is transactional and alias safe" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Companion");
    defer thread.deinit(allocator);
    thread.setDraft("prior draft");
    try thread.setDraftImage(allocator, "/tmp/prior.png", "image/png", 7);

    const alias = thread.draft_image.?;
    try stageThreadPrompt(allocator, &thread, "replacement", &.{alias});
    try std.testing.expectEqualStrings("replacement", thread.currentDraft());
    try std.testing.expectEqualStrings("/tmp/prior.png", thread.draft_image.?.path);

    const current_alias = thread.draft_image.?;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, stageThreadPrompt(failing.allocator(), &thread, "lost", &.{current_alias}));
    try std.testing.expectEqualStrings("replacement", thread.currentDraft());
    try std.testing.expectEqualStrings("/tmp/prior.png", thread.draft_image.?.path);

    var second = try ChatImageAttachment.init(allocator, "/tmp/second.png", "image/png", 9);
    defer second.deinit(allocator);
    var fail_after_first = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 4 });
    try std.testing.expectError(error.OutOfMemory, stageThreadPrompt(fail_after_first.allocator(), &thread, "also lost", &.{ current_alias, second }));
    try std.testing.expect(fail_after_first.has_induced_failure);
    try std.testing.expectEqualStrings("replacement", thread.currentDraft());
    try std.testing.expectEqualStrings("/tmp/prior.png", thread.draft_image.?.path);
}

test "thread-addressed prompt snapshot restores an existing user draft" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Visible chat");
    defer thread.deinit(allocator);
    thread.setDraft("still typing");
    try thread.setDraftImage(allocator, "/tmp/user-draft.png", "image/png", 17);

    var snapshot = try ThreadDraftSnapshot.init(allocator, &thread);
    defer snapshot.deinit(allocator);
    try stageThreadPrompt(allocator, &thread, "background prompt", &.{});
    snapshot.restore(allocator, &thread);

    try std.testing.expectEqualStrings("still typing", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 1), thread.draftImageCount());
    try std.testing.expectEqualStrings("/tmp/user-draft.png", thread.draft_image.?.path);
}

test "prospective prompt preflight rejects before thread staging" {
    const allocator = std.testing.allocator;
    const FakeState = struct {
        allow_target: bool = true,
        allow_images: bool = true,
        daemon_ready: bool = true,
        target_checks: usize = 0,
        daemon_checks: usize = 0,

        pub fn setSidebarNotice(_: *@This(), _: []const u8) void {}

        pub fn providerExecutionTargetForProjectThread(
            self: *@This(),
            _: usize,
            _: *const ChatThread,
            image_count: usize,
        ) ?ProviderExecutionTarget {
            self.target_checks += 1;
            if (!self.allow_target or (image_count > 0 and !self.allow_images)) return null;
            return .{ .local = "/tmp" };
        }

        pub fn ensureSessionDaemon(self: *@This()) !void {
            self.daemon_checks += 1;
            if (!self.daemon_ready) return error.DaemonUnavailable;
        }
    };
    var fake: FakeState = .{};
    var prospective = try ChatThread.init(allocator, "Companion");
    defer prospective.deinit(allocator);

    try std.testing.expect(!try preflightThreadPrompt(&fake, 0, &prospective, "  \n", &.{}));
    try std.testing.expectEqual(@as(usize, 0), fake.target_checks);
    try std.testing.expectEqual(@as(usize, 0), fake.daemon_checks);

    prospective.send_state.status = .pending;
    try std.testing.expect(!try preflightThreadPrompt(&fake, 0, &prospective, "send", &.{}));
    prospective.send_state.status = .idle;
    try std.testing.expectEqual(@as(usize, 0), fake.target_checks);

    fake.allow_target = false;
    try std.testing.expect(!try preflightThreadPrompt(&fake, 0, &prospective, "send", &.{}));
    try std.testing.expectEqual(@as(usize, 0), fake.daemon_checks);

    fake.allow_target = true;
    fake.allow_images = false;
    var image = try ChatImageAttachment.init(allocator, "/tmp/image.png", "image/png", 1);
    defer image.deinit(allocator);
    try std.testing.expect(!try preflightThreadPrompt(&fake, 0, &prospective, "send", &.{image}));
    try std.testing.expectEqual(@as(usize, 0), fake.daemon_checks);

    fake.allow_images = true;
    fake.daemon_ready = false;
    try std.testing.expectError(error.DaemonUnavailable, preflightThreadPrompt(&fake, 0, &prospective, "send", &.{image}));
    try std.testing.expectEqual(@as(usize, 1), fake.daemon_checks);

    fake.daemon_ready = true;
    try std.testing.expect(try preflightThreadPrompt(&fake, 0, &prospective, "send", &.{image}));
    try std.testing.expectEqual(@as(usize, 2), fake.daemon_checks);
    try std.testing.expectEqualStrings("", prospective.currentDraft());
    try std.testing.expectEqual(@as(usize, 0), prospective.messages.items.len);
}

test "failed dispatch restores retryable draft; async acceptance arms one addressed turn" {
    // M4-P3 via 7.5: durability is the acceptance receipt, now awaited on a
    // worker. A dispatch failure restores the draft (nothing reached the
    // daemon); a successful dispatch stages exactly one user row, arms one
    // pending send, and clears the visible draft once the worker is running
    // (commitAcceptanceDispatch is covered separately below).
    const allocator = std.testing.allocator;
    const FakeState = struct {
        allocator: std.mem.Allocator,
        project_controller: struct {
            projects: std.ArrayList(Project) = .empty,
            selected_index: usize = 0,
        } = .{},
        handoff_attempts: usize = 0,
        provider_handoffs: usize = 0,
        failure_rows: usize = 0,
        flushes: usize = 0,
        dirty_marks: usize = 0,

        pub fn providerExecutionTargetForProjectThread(_: *@This(), _: usize, _: *const ChatThread, _: usize) ?ProviderExecutionTarget {
            return .{ .local = "/tmp" };
        }

        pub fn ensureSessionDaemon(_: *@This()) !void {}

        pub fn appendMessageToThread(
            self: *@This(),
            thread: *ChatThread,
            role: provider_models.ChatRole,
            author: []const u8,
            body: []const u8,
            _: ?*const ChatImageAttachment,
            _: []const ChatImageAttachment,
        ) !void {
            try thread.messages.append(self.allocator, .{
                .role = role,
                .author = try self.allocator.dupeZ(u8, author),
                .body = try self.allocator.dupeZ(u8, body),
                .extra_images = try self.allocator.alloc(ChatImageAttachment, 0),
            });
            thread.touch();
        }

        pub fn releaseMessage(self: *@This(), message: ChatMessage) void {
            self.allocator.free(message.author);
            self.allocator.free(message.body);
            self.allocator.free(message.extra_images);
        }

        pub fn dispatchDaemonAcceptance(
            self: *@This(),
            _: usize,
            thread: *ChatThread,
            prompt: []const u8,
            _: ProviderExecutionTarget,
            _: *InitialSendSnapshot,
            selected: bool,
        ) !void {
            try std.testing.expectEqualStrings("retryable prompt", prompt);
            self.handoff_attempts += 1;
            if (self.handoff_attempts == 1) return error.DaemonRequestFailed;
            // Mirror production arming: pending send with the acceptance
            // receipt still in flight.
            const send_state = thread.send_state;
            send_state.mutex.lock();
            defer send_state.mutex.unlock();
            send_state.status = .pending;
            send_state.daemon_owned = true;
            send_state.acceptance_pending = true;
            self.provider_handoffs += 1;
            thread.clearDraft();
            self.markDirty();
            if (selected) self.resetComposerInputWidget();
        }

        pub fn appendInitialSendFailure(self: *@This(), _: *ChatThread, _: []const u8) void {
            self.failure_rows += 1;
        }

        pub fn requestTranscriptScrollToBottom(_: *@This()) void {}
        pub fn resetComposerInputWidget(_: *@This()) void {}
        pub fn setSidebarNotice(_: *@This(), _: []const u8) void {}
        pub fn flushDirtyBlocking(self: *@This()) void {
            self.flushes += 1;
        }

        pub fn markDirty(self: *@This()) void {
            self.dirty_marks += 1;
        }
    };

    var state: FakeState = .{ .allocator = allocator };
    var project = try Project.init(allocator, "accept-send", "Accept send", "/tmp/accept-send", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    defer {
        for (state.project_controller.projects.items) |*owned| owned.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    const thread = &state.project_controller.projects.items[0].threads.items[0];
    thread.setDraft("retryable prompt");

    try std.testing.expectError(error.DaemonRequestFailed, sendThreadDraft(&state, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), state.provider_handoffs);
    try std.testing.expectEqual(@as(usize, 1), state.handoff_attempts);
    try std.testing.expectEqual(@as(usize, 1), state.failure_rows);
    try std.testing.expectEqual(@as(usize, 1), state.flushes);
    try std.testing.expectEqualStrings("retryable prompt", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 0), thread.messages.items.len);
    try std.testing.expect(!thread.committed);

    try std.testing.expect(try sendThreadDraft(&state, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), state.provider_handoffs);
    try std.testing.expectEqual(@as(usize, 2), state.handoff_attempts);
    // Async acceptance (7.5): spawning the worker clears the composer without
    // waiting for the receipt, and the pending send blocks a duplicate submit.
    try std.testing.expectEqualStrings("", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expectEqualStrings("retryable prompt", thread.messages.items[0].body);
    try std.testing.expect(thread.isSendAcceptancePending());
    try std.testing.expect(!try sendThreadDraft(&state, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), state.provider_handoffs);
    thread.send_state.mutex.lock();
    thread.send_state.status = .idle;
    thread.send_state.daemon_owned = false;
    thread.send_state.acceptance_pending = false;
    thread.send_state.mutex.unlock();
}

test "acceptance keeps the optimistic clear, retains message id, and restores rejection" {
    const allocator = std.testing.allocator;
    const FakeState = struct {
        allocator: std.mem.Allocator,
        chat_controller: State = .{},
        project_controller: struct {
            projects: std.ArrayList(Project) = .empty,
            selected_index: usize = 0,
        } = .{},
        failure_rows: usize = 0,
        flushes: usize = 0,
        dirty_marks: usize = 0,
        composer_resets: usize = 0,

        pub fn projectThreadIndexByLocalId(self: *@This(), workspace_id: []const u8, local_thread_id: []const u8) ?ProjectThreadIndex {
            return projectThreadIndexByLocalIdImpl(self, workspace_id, local_thread_id);
        }

        fn projectThreadIndexByLocalIdImpl(self: *@This(), workspace_id: []const u8, local_thread_id: []const u8) ?ProjectThreadIndex {
            for (self.project_controller.projects.items, 0..) |*project, project_index| {
                if (!std.mem.eql(u8, project.id, workspace_id)) continue;
                for (project.threads.items, 0..) |*thread, thread_index| {
                    if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return .{
                        .project_index = project_index,
                        .thread_index = thread_index,
                    };
                }
            }
            return null;
        }

        pub fn releaseMessage(self: *@This(), message: ChatMessage) void {
            self.allocator.free(message.author);
            self.allocator.free(message.body);
            if (message.message_id) |id| self.allocator.free(id);
            self.allocator.free(message.extra_images);
        }

        pub fn appendInitialSendFailure(self: *@This(), _: *ChatThread, _: []const u8) void {
            self.failure_rows += 1;
        }

        pub fn requestTranscriptScrollToBottom(_: *@This()) void {}
        pub fn resetComposerInputWidget(self: *@This()) void {
            self.composer_resets += 1;
        }
        pub fn setSidebarNotice(_: *@This(), _: []const u8) void {}
        pub fn flushDirtyBlocking(self: *@This()) void {
            self.flushes += 1;
        }
        pub fn markDirty(self: *@This()) void {
            self.dirty_marks += 1;
        }
    };

    var state: FakeState = .{ .allocator = allocator };
    var project = try Project.init(allocator, "accept-commit", "Accept commit", "/tmp/accept-commit", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    defer {
        for (state.project_controller.projects.items) |*owned| owned.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    const thread = &state.project_controller.projects.items[0].threads.items[0];
    const project_id = state.project_controller.projects.items[0].id;

    const makeDispatch = struct {
        fn call(pid: []const u8, tid: []const u8, prompt: []const u8, outcome: AcceptanceOutcome) !*AcceptanceDispatch {
            const page_alloc = std.heap.page_allocator;
            const dispatch = try page_alloc.create(AcceptanceDispatch);
            dispatch.* = .{
                .arena = std.heap.ArenaAllocator.init(page_alloc),
                .project_id = "",
                .local_thread_id = "",
                .pref_path = "",
                .params = undefined,
                .snapshot = .{ .message_count = 0, .committed = false, .last_activity_at = 0, .title = null },
                .outcome = outcome,
            };
            const arena = dispatch.arena.allocator();
            dispatch.project_id = try arena.dupe(u8, pid);
            dispatch.local_thread_id = try arena.dupe(u8, tid);
            dispatch.params = .{
                .turn_id = try arena.dupe(u8, "gui:test:turn"),
                .workspace_id = dispatch.project_id,
                .local_thread_id = dispatch.local_thread_id,
                .provider = "claude",
                .harness = "cli",
                .project_path = "/tmp/accept-commit",
                .prompt = try arena.dupe(u8, prompt),
                .image_paths = &.{},
                .images = &.{},
                .provider_thread_id = null,
                .thread_title = "",
                .model_ref = null,
                .reasoning_effort = null,
                .opencode_reasoning_variant = null,
                .cursor_model_params_json = null,
                .fast_mode = false,
                .access_mode = "default",
                .remote_ssh_host = null,
                .remote_cwd = null,
                .message_id = try arena.dupe(u8, "gui-msg:test:turn"),
            };
            return dispatch;
        }
    }.call;

    const armThread = struct {
        fn call(chat: *State, target: *ChatThread) !void {
            const send_state = target.send_state;
            send_state.mutex.lock();
            defer send_state.mutex.unlock();
            send_state.status = .pending;
            send_state.daemon_owned = true;
            send_state.acceptance_pending = true;
            if (send_state.daemon_turn_id) |old| std.heap.page_allocator.free(old);
            send_state.daemon_turn_id = try std.heap.page_allocator.dupe(u8, "gui:test:turn");
            chat.beginSend();
        }
    }.call;

    // Accepted: the worker-start boundary clears text and image immediately;
    // the later receipt only retains the staged message identity.
    thread.setDraft("submitted prompt");
    try thread.setDraftImage(allocator, "/tmp/submitted.png", "image/png", 17);
    try thread.messages.append(allocator, .{
        .role = .user,
        .author = try allocator.dupeZ(u8, "You"),
        .body = try allocator.dupeZ(u8, "submitted prompt"),
        .extra_images = try allocator.alloc(ChatImageAttachment, 0),
    });
    const accepted = try makeDispatch(project_id, thread.local_thread_id, "submitted prompt", .accepted);
    clearComposerForAcceptance(&state, thread, accepted, true);
    try std.testing.expectEqualStrings("", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 0), thread.draftImageCount());
    try armThread(&state.chat_controller, thread);
    try std.testing.expect(commitAcceptanceDispatch(&state, accepted));
    accepted.destroy(allocator);
    try std.testing.expectEqualStrings("", thread.currentDraft());
    try std.testing.expectEqualStrings("gui-msg:test:turn", thread.messages.items[0].message_id.?);
    try std.testing.expectEqual(@as(usize, 1), state.composer_resets);
    try std.testing.expect(!thread.isSendAcceptancePending());
    try std.testing.expect(thread.isSendPending());
    try std.testing.expectEqual(@as(usize, 0), state.failure_rows);

    // Rejected: staged row popped, send disarmed, and the dispatch transfers
    // the submitted text/image back into an otherwise untouched composer.
    thread.send_state.mutex.lock();
    thread.send_state.status = .idle;
    thread.send_state.daemon_owned = false;
    thread.send_state.mutex.unlock();
    state.chat_controller.finishSend();
    thread.setDraft("second prompt");
    try thread.setDraftImage(allocator, "/tmp/retry.png", "image/png", 23);
    try thread.messages.append(allocator, .{
        .role = .user,
        .author = try allocator.dupeZ(u8, "You"),
        .body = try allocator.dupeZ(u8, "second prompt"),
        .extra_images = try allocator.alloc(ChatImageAttachment, 0),
    });
    const rejected = try makeDispatch(project_id, thread.local_thread_id, "second prompt", .rejected);
    clearComposerForAcceptance(&state, thread, rejected, true);
    try std.testing.expectEqualStrings("", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 0), thread.draftImageCount());
    try armThread(&state.chat_controller, thread);
    rejected.snapshot.message_count = 1;
    rejected.snapshot.committed = thread.committed;
    rejected.snapshot.last_activity_at = thread.last_activity_at;
    try std.testing.expect(commitAcceptanceDispatch(&state, rejected));
    rejected.destroy(allocator);
    try std.testing.expectEqualStrings("second prompt", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 1), thread.draftImageCount());
    try std.testing.expectEqualStrings("/tmp/retry.png", thread.draft_image.?.path);
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expect(!thread.isSendPending());
    try std.testing.expectEqual(@as(usize, 1), state.failure_rows);
    try std.testing.expectEqual(@as(usize, 1), state.flushes);
    try std.testing.expectEqual(@as(usize, 3), state.dirty_marks);
    try std.testing.expectEqual(@as(usize, 3), state.composer_resets);
    try std.testing.expectEqual(@as(usize, 0), state.chat_controller.pending_send_count);
}

/// Directory a local provider session should run in: the thread's override
/// when the user switched it, otherwise the owning workspace path.
pub fn effectiveThreadCwd(project_path: []const u8, thread: *const ChatThread) []const u8 {
    return if (thread.cwd) |cwd| std.mem.sliceTo(cwd, 0) else project_path;
}

pub fn providerExecutionTargetForProjectThread(
    self: anytype,
    project_index: usize,
    thread: *const ChatThread,
    image_count: usize,
) ?ProviderExecutionTarget {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[project_index];
    const link = project.herdr_link orelse return .{ .local = effectiveThreadCwd(project.path, thread) };

    if (link.remote_alias.len == 0) {
        self.setSidebarNotice("Local Herdr GUI sends use the Herdr terminal/TUI pane for now.");
        return null;
    }
    if (thread.provider != .codex) {
        var buffer: [160]u8 = undefined;
        self.setSidebarNotice(std.fmt.bufPrint(
            &buffer,
            "Remote Herdr GUI sends support Codex only for now. Use the Herdr TUI pane for {s}.",
            .{utils.providerLabel(thread.provider)},
        ) catch "Remote Herdr GUI sends support Codex only for now.");
        return null;
    }
    if (image_count > 0) {
        self.setSidebarNotice("Remote Herdr Codex GUI sends do not support local image attachments yet.");
        return null;
    }
    const remote_cwd = link.remote_cwd orelse {
        self.setSidebarNotice("Remote Herdr workspace is missing a remote cwd.");
        return null;
    };
    return .{ .remote_ssh = .{ .host = link.remote_alias, .cwd = remote_cwd } };
}

pub fn handleBangCommandSubmission(self: anytype) bool {
    const draft = self.currentDraft();
    switch (bang_commands.classifySubmission(draft)) {
        .message => |message| {
            if (message.ptr == draft.ptr) return false;
            self.setDraft(message);
            self.syncPaletteComposerFromDraft();
            return false;
        },
        .command => |command| self.beginBangCommand(command) catch |err| {
            log.err("failed to begin bang command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not start the workspace command.");
            return true;
        },
    }
    return true;
}

pub fn beginBangCommand(self: anytype, command: []const u8) !void {
    const thread = self.currentThreadMutable();
    if (thread.draftImageCount() > 0) {
        self.setSidebarNotice("Remove image attachments before running a bang command.");
        return;
    }
    if (thread.isSendPending()) {
        self.setSidebarNotice("This chat already has a running command or provider request.");
        return;
    }

    if (!thread.committed) try thread.commitFromPrompt(self.allocator, command);
    const submitted = try std.fmt.allocPrint(self.allocator, "!{s}", .{command});
    defer self.allocator.free(submitted);
    try self.appendMessageToThread(thread, .user, "You", submitted, null, &.{});

    const page_alloc = std.heap.page_allocator;
    const destructive = bang_commands.looksDestructive(command);
    const require_confirmation = destructive or thread.access_mode == .supervised;
    const state = thread.send_state;
    state.mutex.lock();
    defer state.mutex.unlock();
    state.status = .pending;
    state.started_at_ms = unixTimestampMs();
    state.result = null;
    state.error_message = null;
    state.provider = null;
    state.local_command = true;
    state.local_command_text = try page_alloc.dupe(u8, command);
    const command_cwd = effectiveThreadCwd(self.currentProject().path, self.currentThread());
    state.local_command_cwd = try page_alloc.dupe(u8, command_cwd);
    state.local_command_shell = try page_alloc.dupe(u8, bang_commands.shellName());
    state.partial_text.clearRetainingCapacity();
    freePendingTimelineEventsLocked(page_alloc, &state.pending_events);
    const preflight_body = try std.fmt.allocPrint(page_alloc, "$ {s}\n\nWorkspace: {s}\nShell: {s}\nWorking directory: {s}\nStatus: waiting to run", .{
        command,
        self.currentProject().label,
        bang_commands.shellName(),
        command_cwd,
    });
    try state.pending_events.append(page_alloc, .{
        .role = .system,
        .author = try page_alloc.dupe(u8, "Running command"),
        .body = preflight_body,
        .tool_call_kind = .execute,
        .tool_call_status = .in_progress,
        .tool_call_title = try page_alloc.dupe(u8, command),
    });
    freePendingApprovalLocked(page_alloc, &state.pending_approval);
    state.approval_decision = null;
    state.stop_requested = false;
    state.stop_signal_sent = false;
    state.ui_revision +%= 1;
    state.polled_ui_revision = 0;
    state.polled_working_seconds = -1;

    if (require_confirmation) {
        const body = try std.fmt.allocPrint(page_alloc, "Command: {s}\nWorkspace: {s}\nShell: {s}\nWorking directory: {s}\nPolicy: {s}", .{
            command,
            self.currentProject().label,
            bang_commands.shellName(),
            command_cwd,
            if (destructive) "destructive command; explicit approval required" else "Supervised workspace; approval required",
        });
        state.pending_approval = .{
            .call_id = try page_alloc.dupe(u8, "bang-command"),
            .title = try page_alloc.dupe(u8, if (destructive) "Confirm destructive command" else "Confirm workspace command"),
            .body = body,
        };
    }

    const request = try page_alloc.create(BangCommandRequest);
    request.* = .{
        .send_state = state,
        .command = try page_alloc.dupe(u8, command),
        .cwd = try page_alloc.dupe(u8, command_cwd),
        .require_confirmation = require_confirmation,
    };
    state.worker_done.store(false, .release);
    state.worker = try std.Thread.spawn(.{}, bangCommandWorker, .{request});
    self.chat_controller.beginSend();
    self.clearDraft();
    self.resetComposerInputWidget();
    self.requestTranscriptScrollToBottom();
    self.flushDirtyNow();
    self.setSidebarNotice(if (require_confirmation) "Command is waiting for approval." else "Running workspace command...");
}

pub fn retryBangCommand(self: anytype, command: []const u8) void {
    self.beginBangCommand(command) catch |err| {
        log.err("failed to retry bang command: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not retry the workspace command.");
    };
}

pub fn sendDraft(self: anytype) !void {
    _ = try self.sendThreadDraft(self.project_controller.selected_index, self.currentProject().currentThreadIndex());
}

pub fn preflightThreadPrompt(
    self: anytype,
    project_index: usize,
    thread: *const ChatThread,
    prompt: []const u8,
    images: []const ChatImageAttachment,
) !bool {
    if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len == 0 and images.len == 0) return false;
    if (thread.isSendPending()) {
        self.setSidebarNotice("This chat already has a provider request running.");
        return false;
    }
    if (self.providerExecutionTargetForProjectThread(project_index, thread, images.len) == null) return false;
    try self.ensureSessionDaemon();
    return true;
}

pub fn sendThreadPrompt(
    self: anytype,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    prompt: []const u8,
    images: []const ChatImageAttachment,
) !bool {
    const resolved = self.projectThreadIndexByLocalId(workspace_id, local_thread_id) orelse return false;
    const thread = &self.project_controller.projects.items[resolved.project_index].threads.items[resolved.thread_index];
    if (!try self.preflightThreadPrompt(resolved.project_index, thread, prompt, images)) return false;
    var previous_draft = try ThreadDraftSnapshot.init(self.allocator, thread);
    defer previous_draft.deinit(self.allocator);
    defer previous_draft.restore(self.allocator, thread);
    try stageThreadPrompt(self.allocator, thread, prompt, images);
    self.markDirty();
    return try sendThreadDraftWithUiPolicy(self, resolved.project_index, resolved.thread_index, false);
}

const ThreadDraftSnapshot = struct {
    storage: [chat_types.DRAFT_CAPACITY:0]u8,
    images: std.ArrayList(ChatImageAttachment) = .empty,

    fn init(allocator: std.mem.Allocator, thread: *const ChatThread) !ThreadDraftSnapshot {
        var snapshot: ThreadDraftSnapshot = .{ .storage = thread.draft_storage };
        errdefer snapshot.deinit(allocator);
        try snapshot.images.ensureTotalCapacity(allocator, thread.draftImageCount());
        if (thread.draft_image) |image| {
            snapshot.images.appendAssumeCapacity(try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size));
        }
        for (thread.draft_extra_images.items) |image| {
            snapshot.images.appendAssumeCapacity(try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size));
        }
        return snapshot;
    }

    fn restore(self: *ThreadDraftSnapshot, allocator: std.mem.Allocator, thread: *ChatThread) void {
        thread.clearDraftImage(allocator);
        thread.draft_storage = self.storage;
        if (self.images.items.len == 0) return;
        thread.draft_image = self.images.orderedRemove(0);
        std.mem.swap(std.ArrayList(ChatImageAttachment), &thread.draft_extra_images, &self.images);
    }

    fn deinit(self: *ThreadDraftSnapshot, allocator: std.mem.Allocator) void {
        for (self.images.items) |*image| image.deinit(allocator);
        self.images.deinit(allocator);
    }
};

fn stageThreadPrompt(allocator: std.mem.Allocator, thread: *ChatThread, prompt: []const u8, images: []const ChatImageAttachment) !void {
    var staged_images: std.ArrayList(ChatImageAttachment) = .empty;
    defer staged_images.deinit(allocator);
    errdefer for (staged_images.items) |*image| image.deinit(allocator);
    try staged_images.ensureTotalCapacity(allocator, images.len);
    for (images) |image| {
        const copy = try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size);
        staged_images.appendAssumeCapacity(copy);
    }

    var staged_draft: [chat_types.DRAFT_CAPACITY:0]u8 = std.mem.zeroes([chat_types.DRAFT_CAPACITY:0]u8);
    const prompt_len = @min(prompt.len, staged_draft.len - 1);
    @memcpy(staged_draft[0..prompt_len], prompt[0..prompt_len]);

    thread.clearDraftImage(allocator);
    thread.draft_storage = staged_draft;
    if (staged_images.items.len > 0) {
        thread.draft_image = staged_images.orderedRemove(0);
        std.mem.swap(std.ArrayList(ChatImageAttachment), &thread.draft_extra_images, &staged_images);
    }
}

pub fn sendThreadDraft(self: anytype, project_index: usize, thread_index: usize) !bool {
    return sendThreadDraftWithUiPolicy(self, project_index, thread_index, true);
}

/// Sends one thread's staged draft while optionally updating the selected composer and scroll position.
pub fn sendThreadDraftWithUiPolicy(self: anytype, project_index: usize, thread_index: usize, update_selected_ui: bool) !bool {
    if (project_index >= self.project_controller.projects.items.len) return error.WorkspaceNotFound;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return error.ThreadNotFound;
    const selected_target = update_selected_ui and project_index == self.project_controller.selected_index and thread_index == project.currentThreadIndex();
    const thread = &project.threads.items[thread_index];
    const draft = thread.currentDraft();
    const draft_image = thread.draft_image;
    const draft_image_count = thread.draftImageCount();
    if (draft.len == 0 and draft_image_count == 0) return false;

    if (thread.isSendPending()) {
        self.setSidebarNotice("This chat already has a provider request running.");
        return false;
    }
    const execution_target = self.providerExecutionTargetForProjectThread(
        project_index,
        thread,
        draft_image_count,
    ) orelse return false;

    // Prove the daemon is reachable before staging a persisted user turn.
    // A failure here cannot be an ambiguously accepted send, so the draft,
    // attachments, title, and existing transcript all remain retryable.
    self.ensureSessionDaemon() catch |err| {
        self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
        project.invalidateSidebarThreadCache();
        if (selected_target) self.requestTranscriptScrollToBottom();
        self.flushDirtyBlocking();
        return err;
    };

    const trimmed_title = std.mem.trim(u8, draft, &std.ascii.whitespace);
    var snapshot = try InitialSendSnapshot.init(self.allocator, thread);
    defer snapshot.deinit(self.allocator);
    if (!thread.committed) {
        thread.commitFromPrompt(self.allocator, if (trimmed_title.len > 0) trimmed_title else "Image") catch |err| {
            snapshot.restore(self, thread);
            self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
            project.invalidateSidebarThreadCache();
            if (selected_target) self.requestTranscriptScrollToBottom();
            self.flushDirtyBlocking();
            return err;
        };
    }
    var draft_image_copy = draft_image;
    self.appendMessageToThread(thread, .user, "You", draft, if (draft_image_copy) |*image| image else null, thread.draft_extra_images.items) catch |err| {
        snapshot.restore(self, thread);
        self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
        project.invalidateSidebarThreadCache();
        if (selected_target) self.requestTranscriptScrollToBottom();
        self.flushDirtyBlocking();
        return err;
    };
    project.invalidateSidebarThreadCache();
    // M4-P3: user-message durability is the daemon acceptance receipt.
    // chat.turn.start stages the user row (keyed by message_id) before
    // provider work; do not pre-flush via persistThreadBlocking. The RPC now
    // runs on an acceptance worker (7.5) so a busy daemon cannot stall the
    // event thread; the receipt commits in pollSend with the same
    // rejected/ambiguous classification. Once the worker exists it clears the
    // composer immediately and owns the submitted attachments for rollback.
    self.dispatchDaemonAcceptance(project_index, thread, draft, execution_target, &snapshot, selected_target) catch |err| {
        // Dispatch failures happen before anything reaches the daemon, so
        // restoring the staged user row is safe and the draft stays intact.
        snapshot.restore(self, thread);
        self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
        project.invalidateSidebarThreadCache();
        if (selected_target) self.requestTranscriptScrollToBottom();
        self.flushDirtyBlocking();
        return err;
    };
    if (selected_target) {
        self.requestTranscriptScrollToBottom();
    }
    self.setSidebarNotice("Waiting for provider reply...");
    return true;
}

pub fn abortCurrentThreadSend(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    abortThreadSend(self, self.currentThreadMutable());
}

pub fn abortThreadByLocalId(self: anytype, workspace_id: []const u8, local_thread_id: []const u8) bool {
    const thread = self.threadByLocalId(workspace_id, local_thread_id) orelse return false;
    abortThreadSend(self, thread);
    return true;
}

fn abortThreadSend(self: anytype, thread: *ChatThread) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    if (send_state.status != .pending) {
        self.setSidebarNotice("This chat is not running.");
        return;
    }

    if (send_state.stop_requested) {
        self.setSidebarNotice("Stopping provider reply...");
        return;
    }

    send_state.stop_requested = true;
    if (send_state.active_local_child) |child| child.terminateTree();
    if (send_state.pending_approval != null) {
        send_state.approval_decision = .deny;
        send_state.condition.broadcast();
    }
    self.setSidebarNotice(if (send_state.local_command) "Stopping command..." else "Stopping provider reply...");
}

pub fn queueOrSteerDraftDuringSend(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    const thread = self.currentThreadMutable();
    const kind: FollowupKind = switch (thread.provider) {
        .codex, .claude, .pi => .steer,
        .opencode => .queue,
        .cursor => .queue,
        .fx => .queue,
        .grok => .queue,
    };
    self.storeDraftDuringSend(kind);
}

/// Stores a follow-up for an explicitly addressed thread without selecting it in the desktop UI.
pub fn storeThreadFollowupPrompt(self: anytype, project_index: usize, thread_index: usize, prompt: []const u8) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[thread_index];
    if (!thread.isSendPending()) return false;
    // The submit's acceptance receipt is still in flight; a follow-up staged
    // now could double-send the same prompt once acceptance commits.
    if (thread.isSendAcceptancePending()) return false;
    if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len == 0) return false;

    const kind: FollowupKind = switch (thread.provider) {
        .codex, .claude, .pi => .steer,
        .opencode, .cursor, .fx, .grok => .queue,
    };
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    const owned_prompt = self.allocator.dupe(u8, prompt) catch return false;
    freePendingFollowup(self.allocator, &send_state.pending_followup);
    send_state.pending_followup_signal_sent = false;
    send_state.pending_followup = .{
        .kind = kind,
        .state = .pending,
        .prompt = owned_prompt,
    };
    send_state.ui_revision +%= 1;
    self.markDirty();
    return true;
}

fn copyFollowupImages(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(ChatImageAttachment),
    images: []const ChatImageAttachment,
) !void {
    try destination.ensureTotalCapacity(allocator, images.len);
    for (images) |image| {
        destination.appendAssumeCapacity(try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size));
    }
}

fn copyDraftImagesToFollowup(
    allocator: std.mem.Allocator,
    thread: *const ChatThread,
    destination: *std.ArrayList(ChatImageAttachment),
) !void {
    try destination.ensureTotalCapacity(allocator, thread.draftImageCount());
    if (thread.draft_image) |image| {
        destination.appendAssumeCapacity(try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size));
    }
    for (thread.draft_extra_images.items) |image| {
        destination.appendAssumeCapacity(try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size));
    }
}

/// Queues the current composer draft as a new turn after the active reply.
/// Codex and Claude use this for Enter while Tab remains the distinct steer action.
pub fn queueDraftDuringSend(self: anytype) void {
    self.storeDraftDuringSend(.queue);
}

pub fn storeDraftDuringSend(self: anytype, kind: FollowupKind) void {
    if (self.project_controller.projects.items.len == 0) return;
    const thread = self.currentThreadMutable();
    if (!thread.isSendPending()) {
        self.setSidebarNotice("This chat is not running.");
        return;
    }
    // The just-submitted prompt is staged while its acceptance receipt is in
    // flight (7.5); queueing during this boundary could double-send it.
    if (thread.isSendAcceptancePending()) {
        self.setSidebarNotice("Still confirming the previous send...");
        return;
    }

    const draft = thread.currentDraft();
    if (std.mem.trim(u8, draft, &std.ascii.whitespace).len == 0 and thread.draftImageCount() == 0) {
        self.setSidebarNotice("Type a message or attach an image first.");
        return;
    }

    var next_followup: PendingFollowup = .{
        .kind = kind,
        .prompt = self.allocator.dupe(u8, draft) catch {
            self.setSidebarNotice("Failed to store the pending follow-up.");
            return;
        },
    };
    copyDraftImagesToFollowup(self.allocator, thread, &next_followup.images) catch {
        next_followup.deinit(self.allocator);
        self.setSidebarNotice("Failed to store the pending follow-up attachments.");
        return;
    };

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    freePendingFollowup(self.allocator, &send_state.pending_followup);
    send_state.pending_followup_signal_sent = false;
    send_state.pending_followup = next_followup;
    // The queued-pin snapshot cache keys on this revision; a re-queued prompt
    // must invalidate it even though presence/state stay unchanged.
    send_state.ui_revision +%= 1;

    self.clearDraft();
    thread.clearDraftImage(self.allocator);
    self.resetComposerInputWidget();
    self.setSidebarNotice(switch (kind) {
        .queue => "Queued. Sends after the current reply.",
        .steer => if (thread.provider == .claude)
            "Steer queued. Waiting for Claude to accept it."
        else
            "Steer queued. Waiting for Codex to accept it.",
    });
}

pub fn pendingFollowupSnapshot(self: anytype) !?PendingFollowup {
    if (self.project_controller.projects.items.len == 0) return null;
    const send_state = self.currentThread().send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    const pending = send_state.pending_followup orelse return null;
    return .{
        .kind = pending.kind,
        .state = pending.state,
        .prompt = try self.allocator.dupe(u8, pending.prompt),
    };
}

/// Render-thread view of the queued follow-up, cached across frames on the
/// send-state identity + ui_revision (+ in-place kind/state transitions, which
/// do not bump the revision). The returned pointer stays valid until the next
/// cached-snapshot refresh; render commands copy text into the frame arena.
pub fn pendingFollowupSnapshotCached(self: anytype) ?*const PendingFollowup {
    if (self.project_controller.projects.items.len == 0) return null;
    const send_state = self.currentThread().send_state;
    const cache = &self.pending_ui_snapshot_cache;
    const identity: usize = @intFromPtr(send_state);
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    const revision = send_state.ui_revision;
    const pending = &send_state.pending_followup;
    const fresh = cache.followup_valid and
        cache.followup_send_state == identity and
        cache.followup_revision == revision and
        (cache.followup != null) == (pending.* != null) and
        (pending.* == null or
            (cache.followup.?.state == pending.*.?.state and cache.followup.?.kind == pending.*.?.kind));
    if (!fresh) {
        if (cache.followup) |*existing| existing.deinit(self.allocator);
        cache.followup = null;
        cache.followup_valid = false;
        if (pending.*) |value| {
            const prompt = self.allocator.dupe(u8, value.prompt) catch return null;
            cache.followup = .{ .kind = value.kind, .state = value.state, .prompt = prompt };
        }
        cache.followup_send_state = identity;
        cache.followup_revision = revision;
        cache.followup_valid = true;
    }
    return if (cache.followup) |*value| value else null;
}

pub fn pendingFollowupHint(self: anytype) ?[:0]const u8 {
    if (self.project_controller.projects.items.len == 0) return null;
    const thread = self.currentThread();
    if (!thread.isSendPending()) return null;
    return switch (thread.provider) {
        .codex => "Enter to queue \u{00B7} Tab to steer",
        .opencode => "Tab to queue",
        .claude => "Enter to queue \u{00B7} Tab to steer",
        .cursor => "Tab to queue",
        .pi => "Enter to queue \u{00B7} Tab to steer",
        .fx => "Tab to queue",
        .grok => "Tab to queue",
    };
}

pub fn sendPromptViaHarness(self: anytype, prompt: []const u8) !ai_harness.SendPromptResult {
    const project = self.currentProject();
    const thread = self.currentThread();

    if (thread.harness != .local_cli) {
        return error.UnsupportedHarnessMode;
    }

    const provider_cwd = effectiveThreadCwd(project.path, thread);
    const provider_config = switch (thread.provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = self.allocator,
                .working_directory = provider_cwd,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = provider_cwd,
                .launch_on_connect = false,
            },
        },
        .claude => ai_harness.ProviderConfig{
            .claude = .{
                .cwd = provider_cwd,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = provider_cwd,
                .model = if (thread.model_ref) |model_ref| model_ref else null,
            },
        },
        .pi => ai_harness.ProviderConfig{
            .pi = .{
                .cwd = provider_cwd,
            },
        },
    };

    var client = try ai_harness.connect(self.allocator, provider_config);
    defer client.deinit();

    const cursor_model_params_json = if (thread.provider == .cursor) try self.cursorModelParamsJsonAlloc(self.allocator, thread) else null;
    defer if (cursor_model_params_json) |params| self.allocator.free(params);

    return client.sendPrompt(self.allocator, .{
        .thread_id = if (thread.provider_thread_id) |thread_id| thread_id else null,
        .thread_title = thread.title,
        .prompt = prompt,
        .cwd = provider_cwd,
        .model = if (thread.model_ref) |model_ref| model_ref else null,
        .opencode_variant = if (thread.provider == .opencode) thread.opencode_reasoning_variant else null,
        .cursor_model_params_json = cursor_model_params_json,
        .reasoning_effort = if (thread.provider == .opencode and thread.opencode_reasoning_variant != null) null else thread.reasoning_effort,
        .service_tier = serviceTierForMode(thread.provider, thread.fast_mode),
        .approval_policy = approvalPolicyForMode(thread.provider, thread.access_mode),
        .sandbox_mode = sandboxModeForMode(thread.provider, thread.access_mode),
    });
}

pub fn interruptThreadViaHarness(
    self: anytype,
    execution_target: ProviderExecutionTarget,
    provider: Provider,
    thread_id: []const u8,
    turn_id: ?[]const u8,
) !void {
    if (execution_target.remoteHost() != null and provider != .codex) return error.UnsupportedRemoteProvider;
    const provider_cwd = execution_target.cwd();
    const provider_config = switch (provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = self.allocator,
                .working_directory = provider_cwd,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = provider_cwd,
                .launch_on_connect = false,
                .remote_ssh = if (execution_target.remoteHost()) |host| .{
                    .host = host,
                    .cwd = provider_cwd,
                } else null,
            },
        },
        .claude => ai_harness.ProviderConfig{
            .claude = .{
                .cwd = provider_cwd,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = provider_cwd,
            },
        },
        .pi => ai_harness.ProviderConfig{
            .pi = .{
                .cwd = provider_cwd,
            },
        },
        .fx => ai_harness.ProviderConfig{
            .fx = .{
                .cwd = provider_cwd,
            },
        },
        .grok => ai_harness.ProviderConfig{
            .grok = .{
                .cwd = provider_cwd,
            },
        },
    };

    var client = try ai_harness.connect(self.allocator, provider_config);
    defer client.deinit();

    return client.interruptThread(.{
        .thread_id = thread_id,
        .turn_id = turn_id,
    });
}

pub fn steerThreadViaHarness(
    self: anytype,
    execution_target: ProviderExecutionTarget,
    provider: Provider,
    thread_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    images: []const ChatImageAttachment,
) !void {
    if (execution_target.remoteHost() != null and provider != .codex) return error.UnsupportedRemoteProvider;
    const provider_cwd = execution_target.cwd();
    const provider_config = switch (provider) {
        .codex => ai_harness.ProviderConfig{ .codex = .{
            .cwd = provider_cwd,
            .launch_on_connect = false,
            .remote_ssh = if (execution_target.remoteHost()) |host| .{
                .host = host,
                .cwd = provider_cwd,
            } else null,
        } },
        .claude => ai_harness.ProviderConfig{ .claude = .{ .cwd = provider_cwd } },
        .opencode, .cursor, .pi, .fx, .grok => return error.UnsupportedOperation,
    };

    var client = try ai_harness.connect(self.allocator, provider_config);
    defer client.deinit();

    const image_attachments = try self.allocator.alloc(ai_harness.types.ImageAttachment, images.len);
    defer self.allocator.free(image_attachments);
    for (images, 0..) |image, index| image_attachments[index] = .{ .path = image.path };

    return client.steerThread(.{
        .thread_id = thread_id,
        .turn_id = turn_id,
        .prompt = prompt,
        .images = image_attachments,
    });
}

pub fn steerDaemonChatTurn(
    self: anytype,
    turn_id: []const u8,
    steer_id: []const u8,
    prompt: []const u8,
    images: []const ChatImageAttachment,
) !void {
    var image_paths: std.ArrayList([]const u8) = .empty;
    defer image_paths.deinit(self.allocator);
    for (images) |image| try image_paths.append(self.allocator, image.path);
    const response = try sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.steer", .{
        .turn_id = turn_id,
        .steer_id = steer_id,
        .prompt = prompt,
        .image_paths = image_paths.items,
    }, 6);
    defer self.allocator.free(response);
    try ensureJsonRpcOk(self.allocator, response);
}

pub const AcceptanceOutcome = enum { accepted, rejected, ambiguous };

const AcceptanceWireAttachment = struct { path: []const u8, mime: []const u8, byte_size: u64 };

/// Wire params for chat.turn.start, arena-owned so the acceptance worker can
/// serialize them after the submitting call has returned. Field names and
/// order mirror startDaemonChatTurn's anonymous literal (same JSON shape).
const AcceptanceTurnStartParams = struct {
    turn_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    provider: []const u8,
    harness: []const u8,
    project_path: []const u8,
    prompt: []const u8,
    image_paths: []const []const u8,
    images: []const AcceptanceWireAttachment,
    provider_thread_id: ?[]const u8,
    thread_title: []const u8,
    model_ref: ?[]const u8,
    reasoning_effort: ?[]const u8,
    opencode_reasoning_variant: ?[]const u8,
    cursor_model_params_json: ?[]const u8,
    fast_mode: bool,
    access_mode: []const u8,
    remote_ssh_host: ?[]const u8,
    remote_cwd: ?[]const u8,
    /// Thread working-directory override; the daemon falls back to
    /// `project_path` when null.
    cwd: ?[]const u8 = null,
    message_id: []const u8,
};

/// One in-flight async chat.turn.start acceptance (7.5). The event thread
/// arms the pending send and hands this to a worker; pollSend commits the
/// outcome on the main thread with the same M4-P3 classification the old
/// synchronous path used. Identity guards (project/thread ids + turn id)
/// protect the commit against thread deletion or reset during the window.
pub const AcceptanceDispatch = struct {
    arena: std.heap.ArenaAllocator,
    project_id: []const u8,
    local_thread_id: []const u8,
    pref_path: []const u8,
    params: AcceptanceTurnStartParams,
    /// Owned pre-submit rollback state; allocated with the state allocator.
    snapshot: InitialSendSnapshot,
    /// Submitted attachments move here when the visible composer clears.
    /// Keeping ownership in the dispatch makes rejection rollback infallible
    /// without adding allocations or file I/O to the submit path.
    submitted_image: ?ChatImageAttachment = null,
    submitted_extra_images: std.ArrayList(ChatImageAttachment) = .empty,
    rpc_elapsed_ms: i64 = 0,
    outcome: AcceptanceOutcome = .ambiguous,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,

    fn takeSubmittedComposer(self: *AcceptanceDispatch, thread: *ChatThread) void {
        thread.clearDraft();
        self.submitted_image = thread.draft_image;
        thread.draft_image = null;
        std.mem.swap(std.ArrayList(ChatImageAttachment), &self.submitted_extra_images, &thread.draft_extra_images);
    }

    fn restoreSubmittedComposer(self: *AcceptanceDispatch, thread: *ChatThread) bool {
        // A background/MCP caller may have staged another draft while the
        // receipt was in flight. Never replace independently authored input.
        if (thread.currentDraft().len != 0 or thread.draftImageCount() != 0) return false;
        thread.setDraft(self.params.prompt);
        thread.draft_image = self.submitted_image;
        self.submitted_image = null;
        std.mem.swap(std.ArrayList(ChatImageAttachment), &thread.draft_extra_images, &self.submitted_extra_images);
        return true;
    }

    fn destroy(self: *AcceptanceDispatch, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        if (self.submitted_image) |*image| image.deinit(allocator);
        for (self.submitted_extra_images.items) |*image| image.deinit(allocator);
        self.submitted_extra_images.deinit(allocator);
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

fn markThreadDraftMutation(self: anytype, thread: *ChatThread) void {
    self.markDirty();
    if (comptime @hasField(std.meta.Child(@TypeOf(self)), "lifecycle")) {
        thread.draft_mutation_generation = self.lifecycle.dirty_generation;
        thread.draft_mutation_ack_revision = 0;
    }
}

fn clearComposerForAcceptance(self: anytype, thread: *ChatThread, dispatch: *AcceptanceDispatch, selected: bool) void {
    dispatch.takeSubmittedComposer(thread);
    markThreadDraftMutation(self, thread);
    if (selected) self.resetComposerInputWidget();
}

fn restoreComposerAfterRejectedAcceptance(self: anytype, thread: *ChatThread, dispatch: *AcceptanceDispatch, selected: bool) void {
    if (!dispatch.restoreSubmittedComposer(thread)) return;
    markThreadDraftMutation(self, thread);
    if (selected) self.resetComposerInputWidget();
}

fn acceptanceWorkerMain(dispatch: *AcceptanceDispatch) void {
    const alloc = std.heap.page_allocator;
    const started_ms = monotonicMs();
    const outcome: AcceptanceOutcome = blk: {
        const response = sessionizer.requestAlloc(alloc, dispatch.pref_path, "chat.turn.start", dispatch.params, 1) catch |err| {
            break :blk classifyAcceptanceFailure(alloc, dispatch, err);
        };
        defer alloc.free(response);
        ensureJsonRpcOk(alloc, response) catch |err| {
            break :blk classifyAcceptanceFailure(alloc, dispatch, err);
        };
        break :blk .accepted;
    };
    dispatch.rpc_elapsed_ms = monotonicMs() - started_ms;
    dispatch.outcome = outcome;
    dispatch.done.store(true, .release);
}

/// M4-P3 classification, unchanged from the synchronous path: a lost reply
/// can follow successful acceptance, so probe the exact idempotency key
/// before exposing a retry that could run twice. A daemon JSON-RPC error is
/// a confirmed rejection; anything else stays ambiguous.
fn classifyAcceptanceFailure(alloc: std.mem.Allocator, dispatch: *AcceptanceDispatch, err: anyerror) AcceptanceOutcome {
    if (daemonChatTurnExistsRaw(alloc, dispatch.pref_path, dispatch.params.turn_id)) return .accepted;
    dispatch.err = err;
    return if (err == error.DaemonRequestFailed) .rejected else .ambiguous;
}

/// Stages daemon acceptance for a just-appended user row without blocking the
/// event thread. The pending send is armed before worker spawn; after a
/// successful spawn the composer clears immediately and this dispatch owns
/// its attachments until the receipt is classified. Spawn errors mean nothing
/// was sent, so the caller may treat them as confirmed-safe failures.
pub fn dispatchDaemonAcceptance(
    self: anytype,
    project_index: usize,
    thread: *ChatThread,
    prompt: []const u8,
    execution_target: ProviderExecutionTarget,
    snapshot: *InitialSendSnapshot,
    selected_target: bool,
) !void {
    const page_alloc = std.heap.page_allocator;
    const project = &self.project_controller.projects.items[project_index];
    const now_ms = unixTimestampMs();

    // Readiness checks and other short GUI operations may have launched the
    // shared Codex app-server in this process. Stop it before the daemon
    // worker connects so closing Verde cannot kill the server that owns the
    // durable turn.
    if (thread.provider == .codex) {
        self.finishProviderReadinessThread();
        ai_harness.releaseOwnedCodexServer();
    }

    const dispatch = try page_alloc.create(AcceptanceDispatch);
    errdefer page_alloc.destroy(dispatch);
    dispatch.* = .{
        .arena = std.heap.ArenaAllocator.init(page_alloc),
        .project_id = "",
        .local_thread_id = "",
        .pref_path = "",
        .params = undefined,
        .snapshot = .{ .message_count = 0, .committed = true, .last_activity_at = 0, .title = null },
    };
    errdefer dispatch.arena.deinit();
    const arena = dispatch.arena.allocator();

    const turn_id = try std.fmt.allocPrint(arena, "gui:{s}:{s}:{d}", .{ project.id, thread.local_thread_id, now_ms });
    // Stable client identity for the staged user row at acceptance (M4-P3);
    // the daemon keys the durable message by this id.
    const message_id = try std.fmt.allocPrint(arena, "gui-msg:{s}:{s}:{d}", .{ project.id, thread.local_thread_id, now_ms });
    const cursor_model_params_json: ?[]const u8 = if (thread.provider == .cursor) try self.cursorModelParamsJsonAlloc(arena, thread) else null;

    var image_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var wire_images: std.ArrayListUnmanaged(AcceptanceWireAttachment) = .empty;
    const draft_image_count = thread.draftImageCount();
    try image_paths.ensureTotalCapacity(arena, draft_image_count);
    try wire_images.ensureTotalCapacity(arena, draft_image_count);
    if (thread.draft_image) |image| {
        const path = try arena.dupe(u8, image.path);
        image_paths.appendAssumeCapacity(path);
        wire_images.appendAssumeCapacity(.{ .path = path, .mime = try arena.dupe(u8, image.mime), .byte_size = image.byte_size });
    }
    for (thread.draft_extra_images.items) |image| {
        const path = try arena.dupe(u8, image.path);
        image_paths.appendAssumeCapacity(path);
        wire_images.appendAssumeCapacity(.{ .path = path, .mime = try arena.dupe(u8, image.mime), .byte_size = image.byte_size });
    }

    dispatch.project_id = try arena.dupe(u8, project.id);
    dispatch.local_thread_id = try arena.dupe(u8, thread.local_thread_id);
    dispatch.pref_path = try arena.dupe(u8, self.storage.pref_path);
    dispatch.params = .{
        .turn_id = turn_id,
        .workspace_id = dispatch.project_id,
        .local_thread_id = dispatch.local_thread_id,
        .provider = @tagName(harnessProviderForDbProvider(thread.provider)),
        .harness = @tagName(thread.harness),
        .project_path = try arena.dupe(u8, project.path),
        .prompt = try arena.dupe(u8, prompt),
        .image_paths = image_paths.items,
        .images = wire_images.items,
        .provider_thread_id = if (thread.provider_thread_id) |thread_id| try arena.dupe(u8, thread_id) else null,
        .thread_title = try arena.dupe(u8, thread.title),
        .model_ref = if (thread.model_ref) |model_ref| try arena.dupe(u8, model_ref) else null,
        .reasoning_effort = if (thread.reasoning_effort) |effort| @tagName(effort) else null,
        .opencode_reasoning_variant = if (daemonReasoningVariant(thread.provider, thread.opencode_reasoning_variant)) |variant| try arena.dupe(u8, variant) else null,
        .cursor_model_params_json = cursor_model_params_json,
        .fast_mode = thread.fast_mode == .on,
        .access_mode = @tagName(thread.access_mode),
        .remote_ssh_host = if (execution_target.remoteHost()) |host| try arena.dupe(u8, host) else null,
        .remote_cwd = if (execution_target.remoteHost() != null) try arena.dupe(u8, execution_target.cwd()) else null,
        .cwd = if (thread.cwd) |cwd| try arena.dupe(u8, cwd) else null,
        .message_id = message_id,
    };

    try self.chat_controller.acceptance_dispatches.ensureUnusedCapacity(page_alloc, 1);
    const send_state_turn_id = try page_alloc.dupe(u8, turn_id);

    // Everything below is infallible until the spawn; the send is armed with
    // acceptance_pending so tail polling, steer/stop, and follow-up queueing
    // hold off until the receipt commits.
    armSendStateForDaemonTurn(self, thread, send_state_turn_id, true);
    dispatch.snapshot = snapshot.*;
    snapshot.title = null;
    self.chat_controller.acceptance_dispatches.appendAssumeCapacity(dispatch);

    dispatch.worker = std.Thread.spawn(.{}, acceptanceWorkerMain, .{dispatch}) catch |err| {
        // Nothing was sent: un-arm and hand rollback state back to the caller.
        _ = self.chat_controller.acceptance_dispatches.pop();
        disarmSendStateAfterFailedDispatch(self, thread);
        snapshot.* = dispatch.snapshot;
        dispatch.snapshot = .{ .message_count = 0, .committed = true, .last_activity_at = 0, .title = null };
        dispatch.destroy(self.allocator);
        return err;
    };
    // Once the worker exists, submission is visibly complete. Clear the
    // composer immediately instead of holding its text/images hostage to a
    // potentially slow daemon receipt. The dispatch owns the attachments for
    // rejection rollback, so this remains infallible and non-blocking.
    clearComposerForAcceptance(self, thread, dispatch, selected_target);
}

fn disarmSendStateAfterFailedDispatch(self: anytype, thread: *ChatThread) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    send_state.status = .idle;
    send_state.daemon_owned = false;
    send_state.acceptance_pending = false;
    if (send_state.daemon_turn_id) |turn_id| {
        std.heap.page_allocator.free(turn_id);
        send_state.daemon_turn_id = null;
    }
    self.chat_controller.finishSend();
}

/// Drains completed acceptance workers and commits their outcomes on the
/// main thread. Runs from pollSend ahead of the has-pending gate's per-thread
/// polling so a rejected acceptance still tears the armed send down.
pub fn pollAcceptanceDispatches(self: anytype) bool {
    var changed = false;
    var index: usize = 0;
    while (index < self.chat_controller.acceptance_dispatches.items.len) {
        const dispatch = self.chat_controller.acceptance_dispatches.items[index];
        if (!dispatch.done.load(.acquire)) {
            index += 1;
            continue;
        }
        if (dispatch.worker) |worker| {
            worker.join();
            dispatch.worker = null;
        }
        _ = self.chat_controller.acceptance_dispatches.swapRemove(index);
        changed = commitAcceptanceDispatch(self, dispatch) or changed;
        dispatch.destroy(self.allocator);
    }
    return changed;
}

/// Applies one acceptance outcome with the synchronous path's M4-P3 safety:
/// accepted retains the staged message id and the optimistic composer clear;
/// confirmed rejection restores the pre-submit state and submitted composer;
/// ambiguous keeps the staged row and leaves the composer clear so a blind
/// retry cannot duplicate a possibly accepted turn.
pub fn commitAcceptanceDispatch(self: anytype, dispatch: *AcceptanceDispatch) bool {
    const resolved = self.projectThreadIndexByLocalId(dispatch.project_id, dispatch.local_thread_id) orelse return false;
    const project = &self.project_controller.projects.items[resolved.project_index];
    const thread = &project.threads.items[resolved.thread_index];
    const send_state = thread.send_state;

    send_state.mutex.lock();
    const turn_matches = if (send_state.daemon_turn_id) |turn_id| std.mem.eql(u8, turn_id, dispatch.params.turn_id) else false;
    const armed = send_state.acceptance_pending and send_state.status == .pending and send_state.daemon_owned and turn_matches;
    if (!armed) {
        // The send was reset/aborted during the window. Drop the outcome; an
        // accepted daemon turn stays discoverable through reattach flows.
        send_state.mutex.unlock();
        return false;
    }
    send_state.acceptance_pending = false;
    if (dispatch.outcome != .accepted) {
        send_state.status = .idle;
        send_state.daemon_owned = false;
        if (send_state.daemon_turn_id) |turn_id| {
            std.heap.page_allocator.free(turn_id);
            send_state.daemon_turn_id = null;
        }
    }
    send_state.mutex.unlock();

    const selected = resolved.project_index == self.project_controller.selected_index and
        resolved.thread_index == project.currentThreadIndex();
    switch (dispatch.outcome) {
        .accepted => {
            // M4-P4: retain the acceptance-staged client id on the user row
            // so the persistence flush carries the identity instead of
            // re-minting a positional `snap-msg-{i}` for it.
            if (thread.messages.items.len > 0) {
                const user_row = &thread.messages.items[thread.messages.items.len - 1];
                if (user_row.role == .user and user_row.message_id == null and std.mem.eql(u8, user_row.body, dispatch.params.prompt)) {
                    user_row.message_id = self.allocator.dupe(u8, dispatch.params.message_id) catch null;
                }
            }
            runtime_log.diagnostic("chat submit accepted daemon_start_ms={d} thread_messages={d}", .{
                dispatch.rpc_elapsed_ms,
                thread.messages.items.len,
            });
        },
        .rejected => {
            self.chat_controller.finishSend();
            dispatch.snapshot.restore(self, thread);
            restoreComposerAfterRejectedAcceptance(self, thread, dispatch, selected);
            self.appendInitialSendFailure(thread, initialSendStartFailureMessage(dispatch.err orelse error.DaemonRequestFailed));
            project.invalidateSidebarThreadCache();
            if (selected) self.requestTranscriptScrollToBottom();
            self.flushDirtyBlocking();
        },
        .ambiguous => {
            self.chat_controller.finishSend();
            // Keep the in-memory user row (the daemon may have staged it) and
            // leave the optimistically cleared composer empty so a blind retry
            // cannot duplicate the provider turn.
            self.appendInitialSendFailure(thread, ambiguousInitialSendFailureMessage());
            project.invalidateSidebarThreadCache();
            if (selected) self.requestTranscriptScrollToBottom();
            self.flushDirtyBlocking();
        },
    }
    return true;
}

pub fn beginSendForThread(
    self: anytype,
    project_index: usize,
    thread: *ChatThread,
    prompt: []const u8,
    execution_target: ProviderExecutionTarget,
) !void {
    try self.ensureSessionDaemon();
    return self.beginSendForThreadWithReadyDaemon(project_index, thread, prompt, execution_target);
}

fn beginSendForThreadWithImages(
    self: anytype,
    project_index: usize,
    thread: *ChatThread,
    prompt: []const u8,
    images: []const ChatImageAttachment,
    execution_target: ProviderExecutionTarget,
) !void {
    try self.ensureSessionDaemon();
    return beginSendForThreadWithReadyDaemonImages(self, project_index, thread, prompt, execution_target, images);
}

pub fn beginSendForThreadWithReadyDaemon(
    self: anytype,
    project_index: usize,
    thread: *ChatThread,
    prompt: []const u8,
    execution_target: ProviderExecutionTarget,
) !void {
    return beginSendForThreadWithReadyDaemonImages(self, project_index, thread, prompt, execution_target, null);
}

fn beginSendForThreadWithReadyDaemonImages(
    self: anytype,
    project_index: usize,
    thread: *ChatThread,
    prompt: []const u8,
    execution_target: ProviderExecutionTarget,
    images: ?[]const ChatImageAttachment,
) !void {
    const page_alloc = std.heap.page_allocator;
    const execution_cwd = execution_target.cwd();
    const now_ms = unixTimestampMs();
    const project_id = self.project_controller.projects.items[project_index].id;
    const turn_id = try std.fmt.allocPrint(page_alloc, "gui:{s}:{s}:{d}", .{ project_id, thread.local_thread_id, now_ms });
    errdefer page_alloc.free(turn_id);
    // Stable client identity for the staged user row at acceptance (M4-P3).
    // Lives only for the RPC; the daemon keys the durable message by this id.
    const message_id = try std.fmt.allocPrint(self.allocator, "gui-msg:{s}:{s}:{d}", .{ project_id, thread.local_thread_id, now_ms });
    defer self.allocator.free(message_id);
    const cursor_model_params_json = if (thread.provider == .cursor) try self.cursorModelParamsJsonAlloc(page_alloc, thread) else null;
    defer if (cursor_model_params_json) |params| page_alloc.free(params);

    // Readiness checks and other short GUI operations may have launched
    // the shared Codex app-server in this process. Stop it before the
    // daemon worker connects so closing Verde cannot kill the server that
    // owns the durable turn.
    if (thread.provider == .codex) {
        self.finishProviderReadinessThread();
        ai_harness.releaseOwnedCodexServer();
    }

    // The daemon response is owned by self.allocator (startDaemonChatTurn ->
    // sessionizer.requestAlloc); freeing it with page_alloc trips
    // PageAllocator's alignment safety check and crashes the send.
    // Ordering: await the chat.turn.start acceptance receipt before the GUI
    // marks the send pending / clears the draft (caller). Staging SQLite runs
    // on the worker after the RPC returns (never under lockDaemon).
    const response: ?[]u8 = self.startDaemonChatTurn(
        project_index,
        thread,
        prompt,
        execution_target,
        execution_cwd,
        cursor_model_params_json,
        turn_id,
        message_id,
        images,
    ) catch |err| recovered: {
        // A lost reply can follow successful acceptance. Probe this exact
        // idempotency key before exposing a retry that could run twice.
        if (!self.daemonChatTurnExists(turn_id)) return err;
        break :recovered null;
    };
    defer if (response) |owned| self.allocator.free(owned);
    if (response) |json| {
        ensureJsonRpcOk(self.allocator, json) catch |err| {
            if (!self.daemonChatTurnExists(turn_id)) return err;
        };
    }

    // M4-P4 fix: retain the acceptance-staged client id on the user row the
    // caller just appended. The ledger's user_message_id references exactly
    // this value, so the persistence flush now carries the identity instead
    // of re-minting a positional `snap-msg-{i}` for it.
    if (thread.messages.items.len > 0) {
        const user_row = &thread.messages.items[thread.messages.items.len - 1];
        if (user_row.role == .user and user_row.message_id == null and std.mem.eql(u8, user_row.body, prompt)) {
            user_row.message_id = self.allocator.dupe(u8, message_id) catch null;
        }
    }

    armSendStateForDaemonTurn(self, thread, turn_id, false);
}

/// Resets a thread's send_state into a freshly-armed pending daemon turn and
/// increments the pending-send count. Takes ownership of the page-allocated
/// `turn_id`. `acceptance_pending` marks an async chat.turn.start receipt
/// still in flight (7.5); the synchronous path passes false.
fn armSendStateForDaemonTurn(self: anytype, thread: *ChatThread, turn_id: []u8, acceptance_pending: bool) void {
    const page_alloc = std.heap.page_allocator;
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    send_state.status = .pending;
    send_state.started_at_ms = unixTimestampMs();
    send_state.result = null;
    send_state.error_message = null;
    send_state.provider = thread.provider;
    if (send_state.provisional_provider_thread_id) |thread_id| {
        page_alloc.free(thread_id);
        send_state.provisional_provider_thread_id = null;
    }
    if (send_state.active_turn_id) |active_turn_id| {
        page_alloc.free(active_turn_id);
        send_state.active_turn_id = null;
    }
    if (send_state.daemon_turn_id) |old_turn_id| {
        page_alloc.free(old_turn_id);
        send_state.daemon_turn_id = null;
    }
    send_state.daemon_turn_id = turn_id;
    send_state.daemon_last_seq = 0;
    send_state.daemon_last_poll_ms = -1;
    send_state.daemon_owned = true;
    send_state.acceptance_pending = acceptance_pending;
    send_state.daemon_tail_fail_count = 0;
    send_state.thinking = false;
    send_state.partial_text.clearRetainingCapacity();
    freePendingTimelineEventsLocked(page_alloc, &send_state.pending_events);
    freePendingDiffFilesLocked(page_alloc, &send_state.pending_diff_files);
    send_state.pending_diff_has_turn_snapshot = false;
    freePendingApprovalLocked(page_alloc, &send_state.pending_approval);
    send_state.ui_revision = 1;
    send_state.polled_ui_revision = 0;
    // Reset the working-seconds tracker so the first pending poll forces
    // a render and seeds the visible "Working - 0:00" label.
    send_state.polled_working_seconds = -1;
    send_state.approval_decision = null;
    send_state.pending_followup_signal_sent = false;
    send_state.stop_requested = false;
    send_state.stop_signal_sent = false;
    send_state.worker = null;
    self.chat_controller.beginSend();
}

pub fn beginSendDraft(self: anytype, prompt: []const u8) !void {
    const execution_target = self.providerExecutionTargetForProjectThread(
        self.project_controller.selected_index,
        self.currentThread(),
        self.currentThread().draftImageCount(),
    ) orelse return;
    return self.beginSendForThread(self.project_controller.selected_index, self.currentThreadMutable(), prompt, execution_target);
}

pub fn ensureSessionDaemon(self: anytype) !void {
    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    const exe_path = try std.process.executablePathAlloc(threaded.io(), self.allocator);
    defer self.allocator.free(exe_path);
    // Submit path runs on the SDL event thread: use the budgeted interactive
    // probe (~250ms) so Enter never freezes the UI behind a busy daemon. A
    // busy-but-alive daemon passes; chat.turn.start then carries the full
    // request deadline plus its idempotent lost-reply recovery.
    try sessionizer.ensureDaemonInteractive(self.allocator, self.storage.pref_path, exe_path);
}

pub fn startDaemonChatTurn(
    self: anytype,
    project_index: usize,
    thread: *const ChatThread,
    prompt: []const u8,
    execution_target: ProviderExecutionTarget,
    execution_cwd: []const u8,
    cursor_model_params_json: ?[]const u8,
    turn_id: []const u8,
    message_id: []const u8,
    image_override: ?[]const ChatImageAttachment,
) ![]u8 {
    // Wire shape for the additive `images` param: real metadata the GUI
    // already holds, so the daemon can stage the durable user row without
    // inventing mime/byte_size. `image_paths` stays as the legacy mirror.
    const WireAttachment = struct { path: []const u8, mime: []const u8, byte_size: u64 };
    var image_paths: std.ArrayList([]const u8) = .empty;
    defer image_paths.deinit(self.allocator);
    var wire_images: std.ArrayList(WireAttachment) = .empty;
    defer wire_images.deinit(self.allocator);
    if (image_override) |images| {
        for (images) |image| {
            try image_paths.append(self.allocator, image.path);
            try wire_images.append(self.allocator, .{ .path = image.path, .mime = image.mime, .byte_size = image.byte_size });
        }
    } else {
        if (thread.draft_image) |image| {
            try image_paths.append(self.allocator, image.path);
            try wire_images.append(self.allocator, .{ .path = image.path, .mime = image.mime, .byte_size = image.byte_size });
        }
        for (thread.draft_extra_images.items) |image| {
            try image_paths.append(self.allocator, image.path);
            try wire_images.append(self.allocator, .{ .path = image.path, .mime = image.mime, .byte_size = image.byte_size });
        }
    }

    return sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.start", .{
        .turn_id = turn_id,
        .workspace_id = self.project_controller.projects.items[project_index].id,
        .local_thread_id = thread.local_thread_id,
        .provider = @tagName(harnessProviderForDbProvider(thread.provider)),
        .harness = @tagName(thread.harness),
        .project_path = self.project_controller.projects.items[project_index].path,
        .prompt = prompt,
        .image_paths = image_paths.items,
        .images = wire_images.items,
        .provider_thread_id = if (thread.provider_thread_id) |thread_id| thread_id else null,
        .thread_title = thread.title,
        .model_ref = if (thread.model_ref) |model_ref| model_ref else null,
        .reasoning_effort = if (thread.reasoning_effort) |effort| @tagName(effort) else null,
        .opencode_reasoning_variant = daemonReasoningVariant(thread.provider, thread.opencode_reasoning_variant),
        .cursor_model_params_json = cursor_model_params_json,
        .fast_mode = thread.fast_mode == .on,
        .access_mode = @tagName(thread.access_mode),
        .remote_ssh_host = if (execution_target.remoteHost()) |host| host else null,
        .remote_cwd = if (execution_target.remoteHost() != null) execution_cwd else null,
        .cwd = if (thread.cwd) |cwd| @as(?[]const u8, cwd) else null,
        // Additive M4 param: stages this stable id at acceptance (daemon worker).
        .message_id = message_id,
    }, 1);
}

pub fn daemonChatTurnExists(self: anytype, turn_id: []const u8) bool {
    return daemonChatTurnExistsRaw(self.allocator, self.storage.pref_path, turn_id);
}

/// Standalone lost-reply probe (no state), callable from acceptance workers.
fn daemonChatTurnExistsRaw(allocator: std.mem.Allocator, pref_path: []const u8, turn_id: []const u8) bool {
    const response = sessionizer.requestAlloc(allocator, pref_path, "chat.turn.tail", .{
        .turn_id = turn_id,
        .after_seq = 0,
        .max_bytes = DAEMON_CHAT_TAIL_PAGE_BYTES,
    }, 2) catch return false;
    defer allocator.free(response);
    ensureJsonRpcOk(allocator, response) catch return false;
    return true;
}

fn daemonReasoningVariant(provider: Provider, variant: ?[:0]const u8) ?[:0]const u8 {
    return switch (provider) {
        .opencode, .cursor => variant,
        .codex, .claude, .pi, .fx, .grok => null,
    };
}

test "daemon turn preserves provider reasoning variants" {
    try std.testing.expectEqualStrings("high", daemonReasoningVariant(.cursor, "high").?);
    try std.testing.expectEqualStrings("high", daemonReasoningVariant(.opencode, "high").?);
    try std.testing.expect(daemonReasoningVariant(.codex, "high") == null);
    try std.testing.expect(daemonReasoningVariant(.claude, "high") == null);
}

pub fn cancelDaemonChatTurn(self: anytype, turn_id: []const u8) !void {
    const response = try sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.cancel", .{ .turn_id = turn_id }, 3);
    defer self.allocator.free(response);
    try ensureJsonRpcOk(self.allocator, response);
}

pub fn approveDaemonChatTurn(self: anytype, turn_id: []const u8, call_id: []const u8, decision: ai_harness.ApprovalDecision) !void {
    const response = try sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.approve", .{
        .turn_id = turn_id,
        .call_id = call_id,
        .decision = @tagName(decision),
    }, 4);
    defer self.allocator.free(response);
    try ensureJsonRpcOk(self.allocator, response);
}

pub fn consumeDaemonChatTurn(self: anytype, turn_id: ?[]u8) void {
    const owned_turn_id = turn_id orelse return;
    defer std.heap.page_allocator.free(owned_turn_id);
    const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.consume", .{ .turn_id = owned_turn_id }, 5) catch |err| {
        log.warn("failed to consume daemon chat turn: {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(response);
}

/// Reattach still-live daemon turns during launch. Terminal reconciliation
/// stays on the asynchronous composite-snapshot path.
pub fn restoreDaemonChatTurnsOnLaunch(self: anytype) void {
    // Startup must stay bounded when no compatible daemon is reachable. The
    // cursor worker will retry through its ordinary composite-snapshot loop.
    const response = sessionizer.requestAllocWithTimeout(
        self.allocator,
        self.storage.pref_path,
        "chat.turn.list",
        .{},
        6,
        500,
    ) catch return;
    defer self.allocator.free(response);
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch return;
    defer parsed.deinit();
    const result = jsonRpcResult(parsed.value) catch return;
    if (result != .object) return;
    const turns = result.object.get("turns") orelse return;
    if (turns != .array) return;
    for (turns.array.items) |turn_value| {
        if (turn_value != .object) continue;
        const workspace_id = jsonValueString(turn_value.object.get("workspace_id") orelse .null) orelse continue;
        const local_thread_id = jsonValueString(turn_value.object.get("local_thread_id") orelse .null) orelse continue;
        const turn_id = jsonValueString(turn_value.object.get("turn_id") orelse .null) orelse continue;
        const status = jsonValueString(turn_value.object.get("status") orelse .null) orelse "running";
        const thread = self.threadByLocalId(workspace_id, local_thread_id) orelse continue;

        if (std.mem.eql(u8, status, "completed") or
            std.mem.eql(u8, status, "failed") or
            std.mem.eql(u8, status, "aborted")) continue;

        // Still-live turns: re-attach and resume tail from seq 0.
        const send_state = thread.send_state;
        send_state.mutex.lock();
        if (send_state.status == .idle and !send_state.daemon_owned) {
            send_state.status = .pending;
            send_state.started_at_ms = unixTimestampMs();
            send_state.provider = thread.provider;
            send_state.daemon_turn_id = std.heap.page_allocator.dupe(u8, turn_id) catch null;
            send_state.daemon_last_seq = 0;
            send_state.daemon_last_poll_ms = -1;
            send_state.daemon_owned = send_state.daemon_turn_id != null;
            send_state.ui_revision +%= 1;
            if (send_state.daemon_owned) self.chat_controller.beginSend();
        }
        send_state.mutex.unlock();
    }
}

/// Bounded main-thread half of cursor reconciliation. Blocking list/get work
/// lives on the cursor worker; this only attaches live turns carried by the
/// owned composite snapshot. Terminal rows are already in its durable half.
pub fn applyDaemonChatTurnsSnapshot(self: anytype, turns: []const headless.store.TurnRecord) !void {
    return applyDaemonChatTurnsSnapshotWithAllocator(self, turns, std.heap.page_allocator);
}

fn applyDaemonChatTurnsSnapshotWithAllocator(
    self: anytype,
    turns: []const headless.store.TurnRecord,
    attachment_allocator: std.mem.Allocator,
) !void {
    const PlannedAttachment = struct {
        send_state: *SendState,
        turn_id: ?[]u8,
        started_at_ms: i64,
        provider: Provider,
    };
    var planned: std.ArrayList(PlannedAttachment) = .empty;
    defer {
        for (planned.items) |attachment| {
            if (attachment.turn_id) |turn_id| attachment_allocator.free(turn_id);
        }
        planned.deinit(attachment_allocator);
    }
    for (turns) |turn| {
        if (std.mem.eql(u8, turn.status, "completed") or
            std.mem.eql(u8, turn.status, "failed") or
            std.mem.eql(u8, turn.status, "aborted")) continue;
        const thread = self.threadByLocalId(turn.workspace_id, turn.local_thread_id) orelse continue;
        const send_state = thread.send_state;
        send_state.mutex.lock();
        const eligible = send_state.status == .idle and !send_state.daemon_owned;
        send_state.mutex.unlock();
        if (!eligible) continue;
        const owned_turn_id = try attachment_allocator.dupe(u8, turn.turn_id);
        planned.append(attachment_allocator, .{
            .send_state = send_state,
            .turn_id = owned_turn_id,
            .started_at_ms = turn.started_at_ms,
            .provider = thread.provider,
        }) catch |err| {
            attachment_allocator.free(owned_turn_id);
            return err;
        };
    }
    for (planned.items) |*attachment| {
        const send_state = attachment.send_state;
        send_state.mutex.lock();
        if (send_state.status == .idle and !send_state.daemon_owned) {
            send_state.status = .pending;
            send_state.started_at_ms = attachment.started_at_ms;
            send_state.provider = attachment.provider;
            send_state.daemon_turn_id = attachment.turn_id;
            attachment.turn_id = null;
            send_state.daemon_last_seq = 0;
            send_state.daemon_last_poll_ms = -1;
            send_state.daemon_owned = true;
            send_state.ui_revision +%= 1;
            self.chat_controller.beginSend();
        }
        send_state.mutex.unlock();
    }
}

const TerminalTurnConsumeArgs = struct {
    pref_path: []u8,
    turn_id: []u8,
    reservation_key: []u8,
};

const TerminalConsumeStatus = enum { in_flight, completed, not_found };
const TerminalConsumeState = struct {
    status: TerminalConsumeStatus = .in_flight,
};
const TerminalConsumeDisposition = enum { accepted, not_found };
var terminal_consume_mutex: std.atomic.Mutex = .unlocked;
var terminal_consume_turns: std.StringHashMapUnmanaged(TerminalConsumeState) = .empty;

fn lockTerminalConsumes() void {
    while (!terminal_consume_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn terminalConsumeKeyAlloc(pref_path: []const u8, instance_nonce: []const u8, turn_id: []const u8) ?[]u8 {
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}\x1f{s}\x1f{s}",
        .{ pref_path, instance_nonce, turn_id },
    ) catch null;
}

fn reserveTerminalConsume(pref_path: []const u8, instance_nonce: []const u8, turn_id: []const u8) ?[]u8 {
    const key = terminalConsumeKeyAlloc(pref_path, instance_nonce, turn_id) orelse return null;
    lockTerminalConsumes();
    defer terminal_consume_mutex.unlock();
    if (terminal_consume_turns.contains(key)) {
        std.heap.page_allocator.free(key);
        return null;
    }
    terminal_consume_turns.put(std.heap.page_allocator, key, .{}) catch {
        std.heap.page_allocator.free(key);
        return null;
    };
    return std.heap.page_allocator.dupe(u8, key) catch {
        if (terminal_consume_turns.fetchRemove(key)) |entry| std.heap.page_allocator.free(entry.key);
        return null;
    };
}

fn finishTerminalConsume(reservation_key: []const u8, disposition: ?TerminalConsumeDisposition) void {
    lockTerminalConsumes();
    defer terminal_consume_mutex.unlock();
    if (disposition) |value| {
        if (terminal_consume_turns.getPtr(reservation_key)) |state| state.* = switch (value) {
            .accepted => .{ .status = .completed },
            .not_found => .{ .status = .not_found },
        };
    } else if (terminal_consume_turns.fetchRemove(reservation_key)) |entry| {
        std.heap.page_allocator.free(entry.key);
    }
}

fn pruneCompletedTerminalConsumes(
    pref_path: []const u8,
    instance_nonce: []const u8,
    turns: []const headless.store.TurnRecord,
) void {
    const pref_prefix = std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f", .{pref_path}) catch return;
    defer std.heap.page_allocator.free(pref_prefix);
    const instance_prefix = std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f{s}\x1f", .{ pref_path, instance_nonce }) catch return;
    defer std.heap.page_allocator.free(instance_prefix);
    lockTerminalConsumes();
    defer terminal_consume_mutex.unlock();
    while (true) {
        var stale_key: ?[]const u8 = null;
        var iterator = terminal_consume_turns.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, pref_prefix)) continue;
            if (!std.mem.startsWith(u8, entry.key_ptr.*, instance_prefix)) {
                stale_key = entry.key_ptr.*;
                break;
            }
            if (entry.value_ptr.status == .in_flight) continue;
            const turn_id = entry.key_ptr.*[instance_prefix.len..];
            var present = false;
            for (turns) |turn| {
                if (std.mem.eql(u8, turn_id, turn.turn_id)) {
                    present = true;
                    break;
                }
            }
            // A not_found response is still a completed consume reservation:
            // retain it while the same daemon instance continues advertising
            // the record. Only disappearance or instance replacement releases
            // the key, preventing a two-refresh consume loop.
            if (!present) {
                stale_key = entry.key_ptr.*;
                break;
            }
        }
        const key = stale_key orelse return;
        const removed = terminal_consume_turns.fetchRemove(key) orelse continue;
        std.heap.page_allocator.free(removed.key);
    }
}

fn terminalConsumeDisposition(response: []const u8) !TerminalConsumeDisposition {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDaemonResponse;
    if (parsed.value.object.get("error")) |error_value| {
        if (error_value != .object) return error.InvalidDaemonResponse;
        const code = jsonValueString(error_value.object.get("code") orelse .null) orelse return error.InvalidDaemonResponse;
        if (std.mem.eql(u8, code, "not_found")) return .not_found;
        return error.DaemonRequestFailed;
    }
    const result = parsed.value.object.get("result") orelse return error.InvalidDaemonResponse;
    if (result != .object) return error.InvalidDaemonResponse;
    const accepted = result.object.get("accepted") orelse return error.InvalidDaemonResponse;
    if (accepted != .bool or !accepted.bool) return error.InvalidDaemonResponse;
    return .accepted;
}

fn consumeReconciledTerminalTurn(args: *TerminalTurnConsumeArgs) void {
    defer {
        std.heap.page_allocator.free(args.pref_path);
        std.heap.page_allocator.free(args.turn_id);
        std.heap.page_allocator.free(args.reservation_key);
        std.heap.page_allocator.destroy(args);
    }
    const response = sessionizer.requestAlloc(
        std.heap.page_allocator,
        args.pref_path,
        "chat.turn.consume",
        .{ .turn_id = args.turn_id },
        6,
    ) catch |err| {
        log.warn("failed to consume reconciled chat turn {s}: {s}", .{ args.turn_id, @errorName(err) });
        finishTerminalConsume(args.reservation_key, null);
        return;
    };
    defer std.heap.page_allocator.free(response);
    const disposition = terminalConsumeDisposition(response) catch |err| {
        log.warn("invalid consume result for reconciled chat turn {s}: {s}", .{ args.turn_id, @errorName(err) });
        finishTerminalConsume(args.reservation_key, null);
        return;
    };
    if (disposition == .not_found) {
        log.debug("reconciled chat turn {s} was already consumed", .{args.turn_id});
    }
    finishTerminalConsume(args.reservation_key, disposition);
}

/// Move a reattached runtime send to the durable terminal state carried by a
/// composite snapshot. Projection replacement preserves live SendState by
/// thread identity, so reconnect must retire that state by turn identity too.
fn reconcileAttachedTerminalTurn(thread: *ChatThread, turn: headless.store.TurnRecord) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending or !send_state.daemon_owned) return;
    const attached_turn_id = send_state.daemon_turn_id orelse return;
    if (!std.mem.eql(u8, attached_turn_id, turn.turn_id)) return;

    if (std.mem.eql(u8, turn.status, "completed")) {
        send_state.status = .completed;
    } else if (std.mem.eql(u8, turn.status, "failed")) {
        if (send_state.error_message) |old| std.heap.page_allocator.free(old);
        send_state.error_message = std.heap.page_allocator.dupe(
            u8,
            turn.error_message orelse "Provider request failed.",
        ) catch null;
        send_state.status = .failed;
    } else if (std.mem.eql(u8, turn.status, "aborted")) {
        send_state.status = .aborted;
    } else return;
    send_state.ui_revision +%= 1;
}

/// Bounded reconnect presentation for terminal rows already carried by the
/// cursor worker. Failure status/error is shown locally; retention cleanup is
/// dispatched asynchronously so the SDL frame performs no daemon I/O.
pub fn reconcileTerminalDaemonChatTurnsSnapshot(self: anytype, turns: []const headless.store.TurnRecord) void {
    const instance_nonce = self.storage.currentInstanceNonceAlloc(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(instance_nonce);
    pruneCompletedTerminalConsumes(self.storage.pref_path, instance_nonce, turns);
    for (turns) |turn| {
        const terminal = std.mem.eql(u8, turn.status, "completed") or
            std.mem.eql(u8, turn.status, "failed") or
            std.mem.eql(u8, turn.status, "aborted");
        if (!terminal) continue;
        const thread = retryAdoptionThreadByLocalId(self, turn.workspace_id, turn.local_thread_id) orelse continue;
        reconcileAttachedTerminalTurn(thread, turn);
        if (std.mem.eql(u8, turn.status, "failed")) {
            log.warn(
                "chat turn {s} failed while the GUI was closed: {s}",
                .{ turn.turn_id, turn.error_message orelse "Provider request failed." },
            );
            self.setSidebarNotice("A chat reply failed while Verde was closed.");
        }
        const reservation_key = reserveTerminalConsume(self.storage.pref_path, instance_nonce, turn.turn_id) orelse continue;
        const args = std.heap.page_allocator.create(TerminalTurnConsumeArgs) catch {
            finishTerminalConsume(reservation_key, null);
            std.heap.page_allocator.free(reservation_key);
            continue;
        };
        args.* = .{
            .pref_path = std.heap.page_allocator.dupe(u8, self.storage.pref_path) catch {
                std.heap.page_allocator.destroy(args);
                finishTerminalConsume(reservation_key, null);
                std.heap.page_allocator.free(reservation_key);
                continue;
            },
            .turn_id = undefined,
            .reservation_key = reservation_key,
        };
        args.turn_id = std.heap.page_allocator.dupe(u8, turn.turn_id) catch {
            std.heap.page_allocator.free(args.pref_path);
            std.heap.page_allocator.destroy(args);
            finishTerminalConsume(reservation_key, null);
            std.heap.page_allocator.free(reservation_key);
            continue;
        };
        const worker = std.Thread.spawn(.{}, consumeReconciledTerminalTurn, .{args}) catch {
            finishTerminalConsume(reservation_key, null);
            std.heap.page_allocator.free(args.pref_path);
            std.heap.page_allocator.free(args.turn_id);
            std.heap.page_allocator.free(args.reservation_key);
            std.heap.page_allocator.destroy(args);
            continue;
        };
        worker.detach();
    }
}

/// Production teardown for process-global repair and consume reservations.
/// Detached consume workers own their request arguments; a late completion
/// safely observes that its reservation was already removed.
pub fn deinitProcessGlobalState(pref_path: []const u8) void {
    deinitAdoptionRepairs();
    const prefix = std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f", .{pref_path}) catch return;
    defer std.heap.page_allocator.free(prefix);
    lockTerminalConsumes();
    defer terminal_consume_mutex.unlock();
    while (true) {
        var iterator = terminal_consume_turns.iterator();
        var found: ?[]const u8 = null;
        while (iterator.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                found = entry.key_ptr.*;
                break;
            }
        }
        const key = found orelse break;
        const removed = terminal_consume_turns.fetchRemove(key) orelse continue;
        std.heap.page_allocator.free(removed.key);
    }
    if (terminal_consume_turns.count() == 0) {
        terminal_consume_turns.deinit(std.heap.page_allocator);
        terminal_consume_turns = .empty;
    }
}

test "M5-P4 live-turn attachment allocation failure sweeps staged attachment indices" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "fallible attachment");
    defer thread.deinit(allocator);
    allocator.free(thread.local_thread_id);
    thread.local_thread_id = try allocator.dupeZ(u8, "thread-fallible");
    const AttachState = struct {
        chat_controller: State = .{},
        thread: *ChatThread,

        fn threadByLocalId(self: *@This(), workspace_id: []const u8, local_thread_id: []const u8) ?*ChatThread {
            if (!std.mem.eql(u8, workspace_id, "ws-fallible")) return null;
            if (!std.mem.eql(u8, local_thread_id, self.thread.local_thread_id)) return null;
            return self.thread;
        }
    };
    var state: AttachState = .{ .thread = &thread };
    const turns = [_]headless.store.TurnRecord{
        .{
            .turn_id = "turn-fallible-1",
            .workspace_id = "ws-fallible",
            .local_thread_id = "thread-fallible",
            .status = "running",
            .started_at_ms = 1,
            .provider = "codex",
        },
        .{
            .turn_id = "turn-fallible-2",
            .workspace_id = "ws-fallible",
            .local_thread_id = "thread-fallible",
            .status = "running",
            .started_at_ms = 2,
            .provider = "codex",
        },
    };
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(
            error.OutOfMemory,
            applyDaemonChatTurnsSnapshotWithAllocator(&state, &turns, failing.allocator()),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(SendStatus.idle, thread.send_state.status);
        try std.testing.expect(thread.send_state.daemon_turn_id == null);
        try std.testing.expectEqual(@as(usize, 0), state.chat_controller.pending_send_count);
    }
}

test "launch reconciliation reattaches a live daemon turn once" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "restored live turn");
    defer thread.deinit(allocator);
    allocator.free(thread.local_thread_id);
    thread.local_thread_id = try allocator.dupeZ(u8, "thread-restored");
    thread.provider = .cursor;
    const AttachState = struct {
        chat_controller: State = .{},
        thread: *ChatThread,

        fn threadByLocalId(self: *@This(), workspace_id: []const u8, local_thread_id: []const u8) ?*ChatThread {
            if (!std.mem.eql(u8, workspace_id, "ws-restored")) return null;
            if (!std.mem.eql(u8, local_thread_id, self.thread.local_thread_id)) return null;
            return self.thread;
        }
    };
    var state: AttachState = .{ .thread = &thread };
    const turns = [_]headless.store.TurnRecord{.{
        .turn_id = "turn-restored",
        .workspace_id = "ws-restored",
        .local_thread_id = "thread-restored",
        .status = "running",
        .started_at_ms = 42,
        .provider = "cursor",
    }};

    try applyDaemonChatTurnsSnapshotWithAllocator(&state, &turns, std.heap.page_allocator);
    try std.testing.expectEqual(SendStatus.pending, thread.send_state.status);
    try std.testing.expectEqualStrings("turn-restored", thread.send_state.daemon_turn_id.?);
    try std.testing.expect(thread.send_state.daemon_owned);
    try std.testing.expectEqual(@as(usize, 1), state.chat_controller.pending_send_count);

    try applyDaemonChatTurnsSnapshotWithAllocator(&state, &turns, std.heap.page_allocator);
    try std.testing.expectEqual(@as(usize, 1), state.chat_controller.pending_send_count);
}

test "terminal snapshot retires only its matching reattached send" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "restored terminal turn");
    defer thread.deinit(allocator);
    const send_state = thread.send_state;
    send_state.status = .pending;
    send_state.daemon_owned = true;
    send_state.daemon_turn_id = try std.heap.page_allocator.dupe(u8, "turn-restored");

    reconcileAttachedTerminalTurn(&thread, .{
        .turn_id = "turn-other",
        .workspace_id = "ws-restored",
        .local_thread_id = "thread-restored",
        .status = "aborted",
        .started_at_ms = 1,
        .provider = "codex",
    });
    try std.testing.expectEqual(SendStatus.pending, send_state.status);

    reconcileAttachedTerminalTurn(&thread, .{
        .turn_id = "turn-restored",
        .workspace_id = "ws-restored",
        .local_thread_id = "thread-restored",
        .status = "aborted",
        .started_at_ms = 1,
        .provider = "codex",
    });
    try std.testing.expectEqual(SendStatus.aborted, send_state.status);
    try std.testing.expectEqual(@as(u64, 1), send_state.ui_revision);
}

test "M5-P4 reconnect consume deduplicates and validates accepted or not_found" {
    defer {
        lockTerminalConsumes();
        defer terminal_consume_mutex.unlock();
        var iterator = terminal_consume_turns.iterator();
        while (iterator.next()) |entry| std.heap.page_allocator.free(entry.key_ptr.*);
        terminal_consume_turns.deinit(std.heap.page_allocator);
        terminal_consume_turns = .empty;
    }
    const reservation = reserveTerminalConsume("/profile-a", "nonce-a", "turn-consume").?;
    defer std.heap.page_allocator.free(reservation);
    try std.testing.expect(reserveTerminalConsume("/profile-a", "nonce-a", "turn-consume") == null);
    try std.testing.expectEqual(
        TerminalConsumeDisposition.accepted,
        try terminalConsumeDisposition("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"accepted\":true}}"),
    );
    finishTerminalConsume(reservation, .accepted);
    try std.testing.expect(reserveTerminalConsume("/profile-a", "nonce-a", "turn-consume") == null);
    try std.testing.expectEqual(
        TerminalConsumeDisposition.not_found,
        try terminalConsumeDisposition("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"not_found\",\"message\":\"gone\"}}"),
    );
    try std.testing.expectError(
        error.InvalidDaemonResponse,
        terminalConsumeDisposition("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"accepted\":false}}"),
    );
    const turns = [_]headless.store.TurnRecord{.{
        .turn_id = "turn-consume",
        .workspace_id = "ws",
        .local_thread_id = "thread",
        .status = "completed",
        .started_at_ms = 1,
        .provider = "codex",
    }};
    pruneCompletedTerminalConsumes("/profile-a", "nonce-b", &turns);
    const restarted = reserveTerminalConsume("/profile-a", "nonce-b", "turn-consume").?;
    defer std.heap.page_allocator.free(restarted);
    finishTerminalConsume(restarted, .not_found);
    pruneCompletedTerminalConsumes("/profile-a", "nonce-b", &turns);
    try std.testing.expect(reserveTerminalConsume("/profile-a", "nonce-b", "turn-consume") == null);
    pruneCompletedTerminalConsumes("/profile-a", "nonce-b", &turns);
    try std.testing.expect(reserveTerminalConsume("/profile-a", "nonce-b", "turn-consume") == null);
    pruneCompletedTerminalConsumes("/profile-a", "nonce-b", &.{});
    const retried = reserveTerminalConsume("/profile-a", "nonce-b", "turn-consume").?;
    defer std.heap.page_allocator.free(retried);
    finishTerminalConsume(retried, null);
}

pub fn reserveTerminalConsumeForTest(pref_path: []const u8, instance_nonce: []const u8, turn_id: []const u8) bool {
    std.debug.assert(builtin.is_test);
    const reservation = reserveTerminalConsume(pref_path, instance_nonce, turn_id) orelse return false;
    std.heap.page_allocator.free(reservation);
    return true;
}

pub fn terminalConsumeReservedForTest(pref_path: []const u8, instance_nonce: []const u8, turn_id: []const u8) bool {
    std.debug.assert(builtin.is_test);
    const key = terminalConsumeKeyAlloc(pref_path, instance_nonce, turn_id) orelse return false;
    defer std.heap.page_allocator.free(key);
    lockTerminalConsumes();
    defer terminal_consume_mutex.unlock();
    return terminal_consume_turns.contains(key);
}

pub fn threadByLocalId(self: anytype, workspace_id: []const u8, local_thread_id: []const u8) ?*ChatThread {
    for (self.project_controller.projects.items) |*project| {
        if (!std.mem.eql(u8, project.id, workspace_id)) continue;
        for (project.threads.items) |*thread| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return thread;
        }
    }
    return null;
}

pub const ProjectThreadIndex = struct {
    project_index: usize,
    thread_index: usize,
};

pub fn projectThreadIndexByLocalId(self: anytype, workspace_id: []const u8, local_thread_id: []const u8) ?ProjectThreadIndex {
    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        if (!std.mem.eql(u8, project.id, workspace_id)) continue;
        for (project.threads.items, 0..) |*thread, thread_index| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return .{
                .project_index = project_index,
                .thread_index = thread_index,
            };
        }
    }
    return null;
}

pub fn pollSend(self: anytype) bool {
    var changed = self.pollTitleGenerations();
    // M4-P5 fix amendment: retry incomplete daemon identity adoptions on
    // ordinary ticks, ahead of the has-pending gate so an idle thread whose
    // terminal adoption failed still converges. Comptime-gated so slim
    // poll-test states without the storage surface can drive pollSend.
    if (comptime @hasField(std.meta.Child(@TypeOf(self)), "storage")) {
        changed = retryPendingAdoptions(self) or changed;
    }
    // The acceptance/tail commit paths need the full thread-resolution and
    // tail-apply surface; gate on those decls so slim poll-test fakes (which
    // never arm dispatches or tail workers) still instantiate pollSend.
    if (comptime @hasDecl(std.meta.Child(@TypeOf(self)), "projectThreadIndexByLocalId") and
        @hasDecl(std.meta.Child(@TypeOf(self)), "applyDaemonChatTurnTail"))
    {
        // Commit async chat.turn.start receipts (7.5) ahead of per-thread
        // polling so a rejected acceptance tears the armed send down before
        // its thread is tail-polled.
        changed = pollAcceptanceDispatches(self) or changed;
        // Commit a finished chat.turn.tail response before the per-thread
        // dispatch pass below (also drains the slot when no send remains,
        // e.g. after an abort while the worker was in flight).
        changed = serviceDaemonChatTailWorker(self) or changed;
    }
    if (!self.chat_controller.hasPending()) return changed;

    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        for (project.threads.items, 0..) |*thread, thread_index| {
            changed = self.pollThreadSend(project_index, thread_index, thread) or changed;
        }
    }
    return changed;
}

pub fn pollTitleGenerations(self: anytype) bool {
    var changed = false;
    for (self.project_controller.projects.items) |*project| {
        for (project.threads.items) |*thread| {
            changed = self.pollThreadTitleGeneration(project, thread) or changed;
        }
        for (project.archived_threads.items) |*thread| {
            changed = self.pollThreadTitleGeneration(project, thread) or changed;
        }
    }
    for (self.project_controller.archived_projects.items) |*project| {
        for (project.threads.items) |*thread| {
            changed = self.pollThreadTitleGeneration(project, thread) or changed;
        }
        for (project.archived_threads.items) |*thread| {
            changed = self.pollThreadTitleGeneration(project, thread) or changed;
        }
    }
    return changed;
}

pub fn pollThreadTitleGeneration(self: anytype, project: *Project, thread: *ChatThread) bool {
    const state = thread.title_generation_state;
    if (!state.mutex.tryLock()) return false;
    if (workerCleanupPending(
        state.status == .completed or state.status == .failed,
        state.worker != null,
        state.worker_done.load(.acquire),
    )) {
        state.mutex.unlock();
        return false;
    }
    var result: ?[:0]const u8 = null;
    var error_message: ?[]u8 = null;
    var manual = false;
    var discard_result = false;
    const status = state.status;
    switch (status) {
        .completed => {
            result = state.result;
            state.result = null;
        },
        .failed => {
            error_message = state.error_message;
            state.error_message = null;
        },
        else => {},
    }
    if (status == .completed or status == .failed) {
        manual = state.manual;
        discard_result = state.discard_result;
        state.manual = false;
        state.discard_result = false;
        state.status = .idle;
    }
    state.mutex.unlock();
    if (status != .completed and status != .failed) return false;

    thread.finishTitleGenerationThread();
    if (result) |generated_title| {
        defer std.heap.page_allocator.free(generated_title);
        if (!discard_result) {
            const owned = self.allocator.dupeZ(u8, generated_title) catch |err| {
                log.warn("failed to retain generated chat title: {s}", .{@errorName(err)});
                return true;
            };
            self.allocator.free(thread.title);
            thread.title = owned;
            thread.touch();
            project.invalidateSidebarThreadCache();
            self.markDirty();
            self.flushDirtyNow();
            if (manual) self.setSidebarNotice("Chat title regenerated.");
        }
    }
    if (error_message) |message| {
        defer std.heap.page_allocator.free(message);
        log.warn("chat title generation failed: {s}", .{message});
        if (manual and !discard_result) self.setSidebarNotice("Could not generate a chat title. You can rename it manually.");
    } else if (status == .failed and manual and !discard_result) {
        self.setSidebarNotice("Could not generate a chat title. You can rename it manually.");
    }
    return true;
}

pub fn openingExchange(thread: *const ChatThread) ?OpeningExchange {
    var user: ?*const ChatMessage = null;
    var assistant: ?*const ChatMessage = null;
    var user_message_count: usize = 0;
    for (thread.messages.items) |*message| {
        switch (message.role) {
            .user => {
                user_message_count += 1;
                if (user == null) user = message;
            },
            .assistant => if (assistant == null and user != null) {
                assistant = message;
            },
            else => {},
        }
    }
    return .{
        .user = user orelse return null,
        .assistant = assistant orelse return null,
        .user_message_count = user_message_count,
    };
}

pub fn boundedUtf8Prefix(value: []const u8, max_len: usize) []const u8 {
    var end = @min(value.len, max_len);
    while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
    return value[0..end];
}

pub fn startTitleGeneration(self: anytype, project_index: usize, thread: *ChatThread, manual: bool) !void {
    if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
    const exchange = openingExchange(thread) orelse return error.OpeningExchangeUnavailable;
    const user_text = if (std.mem.trim(u8, exchange.user.body, &std.ascii.whitespace).len > 0)
        boundedUtf8Prefix(exchange.user.body, 4096)
    else
        "Image attachment";
    const assistant_text = boundedUtf8Prefix(exchange.assistant.body, 4096);
    const page_alloc = std.heap.page_allocator;
    const prompt = try chat_threads.makeTitleGenerationPrompt(page_alloc, user_text, assistant_text);
    errdefer page_alloc.free(prompt);
    const project_path = try page_alloc.dupe(u8, self.project_controller.projects.items[project_index].path);
    errdefer page_alloc.free(project_path);
    const model_ref = try page_alloc.dupe(u8, self.app_config.chatTitleModel());
    errdefer page_alloc.free(model_ref);
    const request = try page_alloc.create(TitleGenerationRequest);
    errdefer page_alloc.destroy(request);
    request.* = .{
        .state = thread.title_generation_state,
        .project_path = project_path,
        .prompt = prompt,
        .provider = harnessProviderForDbProvider(dbProviderForChatTitleProvider(self.app_config.chat_title_provider)),
        .model_ref = model_ref,
    };

    const state = thread.title_generation_state;
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.status != .idle) return error.TitleGenerationBusy;
    state.status = .pending;
    state.manual = manual;
    state.discard_result = false;
    state.worker_done.store(false, .release);
    state.worker = std.Thread.spawn(.{}, titleGenerationWorker, .{request}) catch |err| {
        state.status = .idle;
        return err;
    };
}

pub fn maybeStartAutomaticTitleGeneration(self: anytype, project_index: usize, thread: *ChatThread) void {
    if (!self.app_config.automatic_chat_titles_enabled) return;
    const exchange = openingExchange(thread) orelse return;
    if (exchange.user_message_count != 1 or thread.isTitleGenerationPendingForUi()) return;
    thread.title_generation_state.mutex.lock();
    const automatic_suppressed = thread.title_generation_state.automatic_suppressed;
    thread.title_generation_state.mutex.unlock();
    if (automatic_suppressed) return;

    const fallback_prompt = if (std.mem.trim(u8, exchange.user.body, &std.ascii.whitespace).len > 0) exchange.user.body else "Image";
    const fallback_title = chat_threads.makeThreadTitle(self.allocator, fallback_prompt) catch return;
    defer self.allocator.free(fallback_title);
    if (!std.mem.eql(u8, thread.title, fallback_title)) return;

    self.startTitleGeneration(project_index, thread, false) catch |err| {
        log.warn("failed to start automatic chat title generation: {s}", .{@errorName(err)});
    };
}

pub fn canRegenerateCurrentThreadTitle(self: anytype) bool {
    if (self.project_controller.selected_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[self.project_controller.selected_index];
    if (project.selected_thread_index >= project.threads.items.len) return false;
    return self.canRegenerateThreadTitle(self.project_controller.selected_index, project.selected_thread_index);
}

pub fn canRegenerateThreadTitle(self: anytype, project_index: usize, thread_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[thread_index];
    return titleRegenerationSourceAvailable(thread) and
        !thread.isSendPendingForUi() and
        !thread.isTitleGenerationPendingForUi();
}

fn titleRegenerationSourceAvailable(thread: *const ChatThread) bool {
    return openingExchange(thread) != null or thread.persisted_message_offset > 0;
}

fn hydrateOpeningExchangeForTitle(self: anytype, project_index: usize, thread_index: usize) !void {
    while (true) {
        if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
        const project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return error.ThreadNotFound;
        const thread = &project.threads.items[thread_index];
        if (openingExchange(thread) != null or thread.persisted_message_offset == 0) return;
        if (!try self.loadOlderThreadMessagesAt(project_index, thread_index)) return;
    }
}

pub fn regenerateCurrentThreadTitle(self: anytype) void {
    if (self.project_controller.selected_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[self.project_controller.selected_index];
    if (project.selected_thread_index >= project.threads.items.len) return;
    self.regenerateThreadTitleAtIndex(self.project_controller.selected_index, project.selected_thread_index);
}

pub fn regenerateThreadTitleAtIndex(self: anytype, project_index: usize, thread_index: usize) void {
    _ = self.pollTitleGenerations();
    if (!self.canRegenerateThreadTitle(project_index, thread_index)) {
        self.setSidebarNotice("A completed opening exchange is required to generate a title.");
        return;
    }
    hydrateOpeningExchangeForTitle(self, project_index, thread_index) catch |err| {
        log.warn("failed to load the opening exchange for chat title regeneration: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not load the opening exchange for title generation.");
        return;
    };
    if (!self.canRegenerateThreadTitle(project_index, thread_index)) {
        self.setSidebarNotice("A completed opening exchange is required to generate a title.");
        return;
    }
    const thread = &self.project_controller.projects.items[project_index].threads.items[thread_index];
    self.startTitleGeneration(project_index, thread, true) catch |err| {
        log.warn("failed to start chat title regeneration: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not start chat title generation.");
        return;
    };
    self.setSidebarNotice("Generating a new chat title...");
}

test "title regeneration remains available when its opening exchange is paged out" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "New thread");
    defer thread.deinit(allocator);

    try std.testing.expect(!titleRegenerationSourceAvailable(&thread));
    thread.persisted_message_offset = 2;
    try std.testing.expect(titleRegenerationSourceAvailable(&thread));

    thread.persisted_message_offset = 0;
    try thread.messages.append(allocator, .{
        .role = .user,
        .author = try allocator.dupeZ(u8, "You"),
        .body = try allocator.dupeZ(u8, "Opening prompt"),
    });
    try thread.messages.append(allocator, .{
        .role = .assistant,
        .author = try allocator.dupeZ(u8, "Codex"),
        .body = try allocator.dupeZ(u8, "Opening reply"),
    });
    try std.testing.expect(titleRegenerationSourceAvailable(&thread));
}

pub fn pollSlashCommand(self: anytype) bool {
    var result: ?ai_harness.RunSlashCommandResult = null;
    var error_message: ?[]u8 = null;
    var display_name: ?[]u8 = null;
    var project_index: usize = 0;
    var thread_index: usize = 0;
    var next_status: SlashCommandStatus = .idle;

    self.slash_command_state.mutex.lock();
    switch (self.slash_command_state.status) {
        .completed => {
            result = self.slash_command_state.result;
            self.slash_command_state.result = null;
            display_name = self.slash_command_state.display_name;
            self.slash_command_state.display_name = null;
            self.slash_command_state.started_at_ms = 0;
            project_index = self.slash_command_state.project_index;
            thread_index = self.slash_command_state.thread_index;
            self.slash_command_state.status = .idle;
            next_status = .completed;
        },
        .failed => {
            error_message = self.slash_command_state.error_message;
            self.slash_command_state.error_message = null;
            display_name = self.slash_command_state.display_name;
            self.slash_command_state.display_name = null;
            self.slash_command_state.started_at_ms = 0;
            project_index = self.slash_command_state.project_index;
            thread_index = self.slash_command_state.thread_index;
            self.slash_command_state.status = .idle;
            next_status = .failed;
        },
        else => {},
    }
    self.slash_command_state.mutex.unlock();

    if (next_status != .idle) {
        self.finishSlashCommandThread();
    }
    if (display_name) |name| {
        std.heap.page_allocator.free(name);
    }

    switch (next_status) {
        .completed => {
            const command_result = result orelse return true;
            defer command_result.deinit(std.heap.page_allocator);
            self.applySlashCommandResult(project_index, thread_index, command_result);
        },
        .failed => {
            if (error_message) |message| {
                defer std.heap.page_allocator.free(message);
                self.setSidebarNotice(message);
            } else {
                self.setSidebarNotice("Slash command failed.");
            }
        },
        else => {},
    }

    return next_status != .idle;
}

pub fn currentThreadPendingSlashCommand(self: anytype) ?PendingSlashCommandDetails {
    if (self.project_controller.projects.items.len == 0) return null;
    const project_index = self.project_controller.selected_index;
    const thread_index = self.currentProject().selected_thread_index;

    self.slash_command_state.mutex.lock();
    defer self.slash_command_state.mutex.unlock();
    if (self.slash_command_state.status != .pending) return null;
    if (self.slash_command_state.project_index != project_index or self.slash_command_state.thread_index != thread_index) return null;

    return .{
        .provider = self.slash_command_state.provider,
        .command = self.slash_command_state.command,
        .display_name = self.slash_command_state.display_name orelse slashCommandFallbackName(self.slash_command_state.command),
        .started_at_ms = self.slash_command_state.started_at_ms,
    };
}

pub fn hasPendingSlashCommand(self: anytype) bool {
    self.slash_command_state.mutex.lock();
    defer self.slash_command_state.mutex.unlock();
    return self.slash_command_state.status == .pending;
}

pub fn currentThreadPendingSlashCommandLabel(self: anytype) ?[]const u8 {
    const details = self.currentThreadPendingSlashCommand() orelse return null;

    return switch (details.provider) {
        .claude => switch (details.command) {
            .usage => "Loading Claude usage...",
            .compact => "Compacting Claude thread context...",
            else => "Running Claude command...",
        },
        .codex => switch (details.command) {
            .usage => "Loading Codex usage...",
            .goal => "Updating Codex goal...",
            .compact => "Compacting Codex thread context...",
            .review => "Starting Codex review...",
            .shell => "Running Codex shell command...",
            .custom => "Running Codex command...",
        },
        .opencode => "Running OpenCode command...",
        .cursor => "Running Cursor command...",
        .pi => "Running Pi command...",
        .fx => "Running FX command...",
        .grok => "Running Grok command...",
    };
}

pub fn applySlashCommandResult(
    self: anytype,
    project_index: usize,
    thread_index: usize,
    result: ai_harness.RunSlashCommandResult,
) void {
    if (!result.handled) {
        if (result.notice) |notice| {
            self.setSidebarNotice(notice);
        } else {
            self.setSidebarNotice("Slash command was not handled by this provider.");
        }
        return;
    }

    if (project_index < self.project_controller.projects.items.len and thread_index < self.project_controller.projects.items[project_index].threads.items.len) {
        const thread = &self.project_controller.projects.items[project_index].threads.items[thread_index];
        if (result.thread_id) |provider_thread_id| {
            const changed = thread.provider_thread_id == null or !std.mem.eql(u8, thread.provider_thread_id.?, provider_thread_id);
            if (changed) {
                const owned = self.allocator.dupeZ(u8, provider_thread_id) catch |err| blk: {
                    log.warn("failed to persist slash command thread id: {s}", .{@errorName(err)});
                    break :blk null;
                };
                if (owned) |next| {
                    if (thread.provider_thread_id) |old| self.allocator.free(old);
                    thread.provider_thread_id = next;
                }
            }
        }

        if (result.transcript_title != null or result.transcript_body != null) {
            const title = result.transcript_title orelse "Provider command";
            const body = result.transcript_body orelse "Done.";
            self.appendMessageToThread(thread, .system, title, body, null, &.{}) catch |err| {
                log.warn("failed to append slash command result: {s}", .{@errorName(err)});
            };
            if (project_index == self.project_controller.selected_index and thread_index == self.currentProject().selected_thread_index) {
                self.requestTranscriptScrollToBottomIfFollowing();
            }
        }
    }

    if (result.notice) |notice| {
        self.setSidebarNotice(notice);
    } else {
        self.setSidebarNotice("Slash command completed.");
    }
    self.markDirty();
}

pub fn hasRunningBackgroundTasks(self: anytype) bool {
    for (self.project_controller.projects.items) |project| {
        for (project.threads.items) |thread| {
            if (threadHasRunningBackgroundTasks(&thread)) return true;
        }
        for (project.archived_threads.items) |thread| {
            if (threadHasRunningBackgroundTasks(&thread)) return true;
        }
    }
    return false;
}

pub fn threadHasRunningBackgroundTasks(thread: *const ChatThread) bool {
    for (thread.background_tasks.items) |task| {
        if (task.status == .running) return true;
    }
    return false;
}

pub fn pollBackgroundTasks(self: anytype) bool {
    var changed = finishCodexBackgroundPoll(self);
    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        for (project.threads.items, 0..) |*thread, thread_index| {
            changed = self.pollThreadBackgroundTasks(project_index, thread_index, thread) or changed;
        }
        for (project.archived_threads.items) |*thread| {
            changed = self.pollThreadBackgroundTasks(project_index, null, thread) or changed;
        }
    }
    startCodexBackgroundPoll(self);
    return changed;
}

fn startCodexBackgroundPoll(self: anytype) void {
    const poll = &self.chat_controller.codex_background_poll;
    const io = std.Io.Threaded.global_single_threaded.io();
    poll.mutex.lockUncancelable(io);
    const busy = poll.status != .idle or poll.worker != null;
    poll.mutex.unlock(io);
    if (busy) return;

    const now_ms = unixTimestampMs();
    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        for (project.threads.items) |*thread| {
            if (startCodexBackgroundPollForThread(self, poll, project_index, thread, now_ms)) return;
        }
        for (project.archived_threads.items) |*thread| {
            if (startCodexBackgroundPollForThread(self, poll, project_index, thread, now_ms)) return;
        }
    }
}

fn startCodexBackgroundPollForThread(
    self: anytype,
    poll: *CodexBackgroundPollState,
    project_index: usize,
    thread: *ChatThread,
    now_ms: i64,
) bool {
    for (thread.background_tasks.items) |*task| {
        if (task.status != .running or task.provider != .codex) continue;
        if (task.provider_thread_id == null or task.process_id == null) continue;
        const poll_interval_ms = codexBackgroundTaskPollIntervalMs(task.poll_failure_count);
        if (task.last_poll_ms != 0 and now_ms - task.last_poll_ms < poll_interval_ms) continue;
        const target = self.providerExecutionTargetForProjectThread(project_index, thread, 0) orelse return false;
        task.last_poll_ms = now_ms;

        const allocator = std.heap.page_allocator;
        const request = allocator.create(CodexBackgroundPollRequest) catch return false;
        request.* = .{
            .local_thread_id = allocator.dupe(u8, thread.local_thread_id) catch {
                allocator.destroy(request);
                return false;
            },
            .provider_thread_id = undefined,
            .process_id = undefined,
            .cwd = undefined,
            .remote_host = null,
        };
        request.provider_thread_id = allocator.dupe(u8, task.provider_thread_id.?) catch {
            allocator.free(request.local_thread_id);
            allocator.destroy(request);
            return false;
        };
        request.process_id = allocator.dupe(u8, task.process_id.?) catch {
            allocator.free(request.provider_thread_id);
            allocator.free(request.local_thread_id);
            allocator.destroy(request);
            return false;
        };
        request.cwd = allocator.dupe(u8, target.cwd()) catch {
            allocator.free(request.process_id);
            allocator.free(request.provider_thread_id);
            allocator.free(request.local_thread_id);
            allocator.destroy(request);
            return false;
        };
        request.remote_host = if (target.remoteHost()) |host| allocator.dupe(u8, host) catch {
            request.deinit();
            return false;
        } else null;

        const io = std.Io.Threaded.global_single_threaded.io();
        poll.mutex.lockUncancelable(io);
        poll.request = request;
        poll.running = null;
        poll.status = .pending;
        poll.worker = std.Thread.spawn(.{}, codexBackgroundPollWorker, .{ poll, request }) catch {
            poll.request = null;
            poll.status = .idle;
            poll.mutex.unlock(io);
            request.deinit();
            return false;
        };
        poll.mutex.unlock(io);
        return true;
    }
    return false;
}

fn finishCodexBackgroundPoll(self: anytype) bool {
    const poll = &self.chat_controller.codex_background_poll;
    const io = std.Io.Threaded.global_single_threaded.io();
    poll.mutex.lockUncancelable(io);
    if (poll.status != .completed) {
        poll.mutex.unlock(io);
        return false;
    }
    const running = poll.running;
    const request = poll.request.?;
    const worker = poll.worker.?;
    poll.worker = null;
    poll.request = null;
    poll.running = null;
    poll.status = .idle;
    poll.mutex.unlock(io);
    worker.join();
    defer request.deinit();
    const task = codexBackgroundTaskForPollRequest(self, request);
    if (running == null) {
        if (task) |entry| {
            entry.poll_failure_count = std.math.add(u8, entry.poll_failure_count, 1) catch std.math.maxInt(u8);
        }
        return false;
    }
    if (task) |entry| entry.poll_failure_count = 0;
    if (running.?) return false;
    return completeCodexBackgroundTask(self, request);
}

fn codexBackgroundTaskPollIntervalMs(failure_count: u8) i64 {
    return switch (@min(failure_count, 5)) {
        0 => CODEX_BACKGROUND_TASK_POLL_MS,
        1 => 4_000,
        2 => 8_000,
        3 => 16_000,
        4 => 32_000,
        else => CODEX_BACKGROUND_TASK_POLL_MAX_MS,
    };
}

test "Codex background polling backs off after repeated provider failures" {
    try std.testing.expectEqual(@as(i64, 2_000), codexBackgroundTaskPollIntervalMs(0));
    try std.testing.expectEqual(@as(i64, 8_000), codexBackgroundTaskPollIntervalMs(2));
    try std.testing.expectEqual(@as(i64, 60_000), codexBackgroundTaskPollIntervalMs(5));
    try std.testing.expectEqual(@as(i64, 60_000), codexBackgroundTaskPollIntervalMs(std.math.maxInt(u8)));
}

fn codexBackgroundTaskForPollRequest(self: anytype, request: *const CodexBackgroundPollRequest) ?*BackgroundTask {
    for (self.project_controller.projects.items) |*project| {
        for (project.threads.items) |*thread| {
            if (codexBackgroundTaskForPollRequestInThread(thread, request)) |task| return task;
        }
        for (project.archived_threads.items) |*thread| {
            if (codexBackgroundTaskForPollRequestInThread(thread, request)) |task| return task;
        }
    }
    return null;
}

fn codexBackgroundTaskForPollRequestInThread(thread: *ChatThread, request: *const CodexBackgroundPollRequest) ?*BackgroundTask {
    if (!std.mem.eql(u8, thread.local_thread_id, request.local_thread_id)) return null;
    for (thread.background_tasks.items) |*task| {
        if (task.provider_thread_id == null or task.process_id == null) continue;
        if (std.mem.eql(u8, task.provider_thread_id.?, request.provider_thread_id) and
            std.mem.eql(u8, task.process_id.?, request.process_id)) return task;
    }
    return null;
}

fn completeCodexBackgroundTask(self: anytype, request: *const CodexBackgroundPollRequest) bool {
    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        for (project.threads.items, 0..) |*thread, thread_index| {
            if (!std.mem.eql(u8, thread.local_thread_id, request.local_thread_id)) continue;
            return completeCodexBackgroundTaskInThread(self, project_index, thread_index, thread, request);
        }
        for (project.archived_threads.items) |*thread| {
            if (!std.mem.eql(u8, thread.local_thread_id, request.local_thread_id)) continue;
            return completeCodexBackgroundTaskInThread(self, project_index, null, thread, request);
        }
    }
    return false;
}

fn completeCodexBackgroundTaskInThread(
    self: anytype,
    project_index: usize,
    thread_index: ?usize,
    thread: *ChatThread,
    request: *const CodexBackgroundPollRequest,
) bool {
    for (thread.background_tasks.items) |*task| {
        if (task.status != .running or task.provider_thread_id == null or task.process_id == null) continue;
        if (!std.mem.eql(u8, task.provider_thread_id.?, request.provider_thread_id) or
            !std.mem.eql(u8, task.process_id.?, request.process_id)) continue;
        task.status = .completed;
        task.updated_at_ms = unixTimestampMs();
        const body = backgroundTaskCompletionBodyAlloc(self.allocator, task) catch return false;
        defer self.allocator.free(body);
        self.appendMessageToThread(thread, .system, "Background task completed", body, null, &.{}) catch return false;
        self.project_controller.projects.items[project_index].invalidateSidebarThreadCache();
        if (project_index == self.project_controller.selected_index and thread_index != null and
            thread_index.? == self.currentProject().selected_thread_index)
        {
            self.requestTranscriptScrollToBottomIfFollowing();
        }
        return true;
    }
    return false;
}

pub fn deinitBackgroundTaskPoller(self: anytype) void {
    const poll = &self.chat_controller.codex_background_poll;
    const io = std.Io.Threaded.global_single_threaded.io();
    poll.mutex.lockUncancelable(io);
    const worker = poll.worker;
    poll.mutex.unlock(io);
    if (worker) |thread| thread.join();
    if (poll.request) |request| request.deinit();
    poll.* = .{};
}

pub fn pollThreadBackgroundTasks(self: anytype, project_index: usize, thread_index: ?usize, thread: *ChatThread) bool {
    const now_ms = unixTimestampMs();
    var changed = syncThreadBackgroundTasksFromPendingEvents(self, thread);

    for (thread.background_tasks.items) |*task| {
        if (task.status != .running) continue;
        if (task.pid_path == null) continue;
        if (task.last_poll_ms != 0 and now_ms - task.last_poll_ms < BACKGROUND_TASK_POLL_MS) continue;
        task.last_poll_ms = now_ms;

        const pid = readBackgroundTaskPid(self.allocator, task.pid_path.?) orelse continue;
        task.pid = pid;
        if (backgroundTaskProcessIsAlive(pid)) continue;

        task.status = if (task.stop_requested) .stopped else .completed;
        task.updated_at_ms = now_ms;
        const body = backgroundTaskCompletionBodyAlloc(self.allocator, task) catch |err| {
            log.warn("failed to build background task completion body: {s}", .{@errorName(err)});
            continue;
        };
        defer self.allocator.free(body);
        self.appendMessageToThread(
            thread,
            .system,
            if (task.stop_requested) "Background task stopped" else "Background task completed",
            body,
            null,
            &.{},
        ) catch |err| {
            log.warn("failed to append background task completion: {s}", .{@errorName(err)});
            continue;
        };
        if (project_index < self.project_controller.projects.items.len) {
            self.project_controller.projects.items[project_index].invalidateSidebarThreadCache();
        }
        if (project_index == self.project_controller.selected_index and thread_index != null and thread_index.? == self.currentProject().selected_thread_index) {
            self.requestTranscriptScrollToBottomIfFollowing();
        }
        changed = true;
    }

    return changed;
}

pub fn backgroundTaskCompletionBodyAlloc(allocator: std.mem.Allocator, task: *const BackgroundTask) ![:0]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(task.command);
    if (task.task_id) |value| try writer.writer.print("\n\nVerde task ID: {s}", .{value});
    if (task.item_id) |value| try writer.writer.print("\nCodex item ID: {s}", .{value});
    if (task.process_id) |value| try writer.writer.print("\nProcess ID: {s}", .{value});
    if (task.provider_thread_id) |value| try writer.writer.print("\nProvider thread ID: {s}", .{value});
    if (task.log_path) |value| try writer.writer.print("\nOutput log: {s}", .{value});
    if (task.pid_path) |value| try writer.writer.print("\nPID file: {s}", .{value});
    if (task.cwd) |value| try writer.writer.print("\nCWD: {s}", .{value});
    if (task.provider) |value| try writer.writer.print("\nProvider: {s}", .{@tagName(value)});
    const owned = try writer.toOwnedSlice();
    defer allocator.free(owned);
    return try allocator.dupeZ(u8, owned);
}

fn syncThreadBackgroundTasksFromPendingEvents(self: anytype, thread: *ChatThread) bool {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return false;

    var changed = false;
    for (send_state.pending_events.items) |event| {
        if (event.role != .system) continue;
        const status = ChatThread.backgroundTaskStatusForEvent(event.author) orelse continue;
        if (backgroundTaskForEventBody(thread, event.body)) |task| {
            if (status == .running) continue;
            if (task.status == status) continue;
        } else if (status != .running) {
            continue;
        }
        thread.noteBackgroundTaskEvent(self.allocator, event.author, event.body) catch |err| {
            log.warn("failed to apply pending background task event: {s}", .{@errorName(err)});
            continue;
        };
        changed = true;
    }
    return changed;
}

fn stopUnownedBackgroundTasksAtTurnEnd(self: anytype, thread: *ChatThread) void {
    for (thread.background_tasks.items) |*task| {
        if (task.status != .running or task.pid_path != null or task.process_id != null) continue;
        const body = backgroundTaskCompletionBodyAlloc(self.allocator, task) catch |err| {
            log.warn("failed to build stopped background task body: {s}", .{@errorName(err)});
            continue;
        };
        defer self.allocator.free(body);
        self.appendMessageToThread(thread, .system, "Background task stopped", body, null, &.{}) catch |err| {
            log.warn("failed to append stopped background task: {s}", .{@errorName(err)});
            continue;
        };
        task.status = .stopped;
        task.updated_at_ms = unixTimestampMs();
    }
}

pub fn readBackgroundTaskPid(allocator: std.mem.Allocator, pid_path: []const u8) ?u32 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const raw = std.Io.Dir.cwd().readFileAlloc(threaded.io(), pid_path, allocator, .limited(256)) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, "\n\r\t ");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

pub fn backgroundTaskProcessIsAlive(pid: u32) bool {
    return platform_process.processIdIsAlive(pid);
}

/// Consecutive tail transport failures before the GUI surfaces a terminal
/// error (Amendment-2 F5). ~16 × 16 ms poll ≈ 250 ms minimum; with the
/// daemon-poll interval this is several seconds of silence — enough to cover
/// a restart handoff without flapping, short enough to end the eternal spinner.
const DAEMON_CHAT_TAIL_FAIL_THRESHOLD: u8 = 16;

/// One in-flight chat.turn.tail request. `response_buffer` is borrowed from
/// chat_controller.State scratch — safe because the single worker slot keeps
/// it (and the reusable connection) exclusive while the worker runs.
pub const DaemonTailWorkerArgs = struct {
    pref_path: []u8,
    turn_id: []u8,
    after_seq: u64,
    started_at_ms: i64,
    response_buffer: []u8,
    response: ?[]u8 = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),

    fn destroy(self: *DaemonTailWorkerArgs) void {
        const page_alloc = std.heap.page_allocator;
        page_alloc.free(self.pref_path);
        page_alloc.free(self.turn_id);
        if (self.response) |owned| page_alloc.free(owned);
        page_alloc.destroy(self);
    }
};

fn daemonTailWorkerMain(connection: *sessionizer.ReusableRequestConnection, args: *DaemonTailWorkerArgs) void {
    const page_alloc = std.heap.page_allocator;
    const response = connection.requestAllocUsingBuffer(
        page_alloc,
        args.pref_path,
        "chat.turn.tail",
        .{
            .turn_id = args.turn_id,
            .after_seq = args.after_seq,
            .max_bytes = DAEMON_CHAT_TAIL_PAGE_BYTES,
        },
        2,
        args.response_buffer,
    ) catch |err| {
        log.warn("failed to tail daemon chat turn: {s}", .{@errorName(err)});
        args.failed = true;
        args.done.store(true, .release);
        return;
    };
    args.response = response;
    args.done.store(true, .release);
}

/// Dispatch half of the tail poll: when this thread's turn is due and the
/// single worker slot is free, hand the RPC to a worker so the render thread
/// never blocks in daemon IPC. The measured-cost backoff still applies at
/// service time as the fallback pacing for a slow daemon.
pub fn pollDaemonChatTurn(self: anytype, thread: *ChatThread) bool {
    const chat = &self.chat_controller;
    // Single slot in flight: skip until the response is serviced in pollSend.
    if (chat.daemon_tail_args != null) return false;

    const page_alloc = std.heap.page_allocator;
    const send_state = thread.send_state;
    const now_ms = monotonicMs();
    send_state.mutex.lock();
    const active = send_state.status == .pending and send_state.daemon_owned and send_state.daemon_turn_id != null;
    const poll_due = active and daemonChatPollDue(send_state.daemon_last_poll_ms, now_ms, send_state.daemon_poll_backoff_ms);
    if (poll_due) send_state.daemon_last_poll_ms = now_ms;
    const turn_id = if (poll_due)
        page_alloc.dupe(u8, send_state.daemon_turn_id.?) catch null
    else
        null;
    const after_seq = send_state.daemon_last_seq;
    send_state.mutex.unlock();

    const owned_turn_id = turn_id orelse return false;

    const response_buffer = chat.daemonTailResponseBuffer(self.allocator) catch |err| {
        log.warn("failed to allocate daemon chat tail buffer: {s}", .{@errorName(err)});
        page_alloc.free(owned_turn_id);
        return false;
    };
    const pref_path = page_alloc.dupe(u8, self.storage.pref_path) catch {
        page_alloc.free(owned_turn_id);
        return false;
    };
    const args = page_alloc.create(DaemonTailWorkerArgs) catch {
        page_alloc.free(owned_turn_id);
        page_alloc.free(pref_path);
        return false;
    };
    args.* = .{
        .pref_path = pref_path,
        .turn_id = owned_turn_id,
        .after_seq = after_seq,
        .started_at_ms = now_ms,
        .response_buffer = response_buffer,
    };
    chat.daemon_tail_args = args;
    chat.daemon_tail_worker = std.Thread.spawn(.{}, daemonTailWorkerMain, .{ &chat.daemon_tail_connection, args }) catch |err| {
        log.warn("failed to spawn daemon chat tail worker: {s}", .{@errorName(err)});
        chat.daemon_tail_args = null;
        args.destroy();
        return false;
    };
    return false;
}

/// Service half of the tail poll (main thread, from pollSend): joins a
/// finished worker, applies pacing from the measured round trip, and commits
/// the response to whichever thread still owns the tailed turn.
pub fn serviceDaemonChatTailWorker(self: anytype) bool {
    const chat = &self.chat_controller;
    const args = chat.daemon_tail_args orelse return false;
    if (!args.done.load(.acquire)) return false;
    if (chat.daemon_tail_worker) |worker| worker.join();
    chat.daemon_tail_worker = null;
    chat.daemon_tail_args = null;
    defer args.destroy();

    const thread = threadByDaemonTurnId(self, args.turn_id) orelse return false;
    const send_state = thread.send_state;
    send_state.mutex.lock();
    const still_active = send_state.status == .pending and send_state.daemon_owned;
    // Fallback pacing (success or failure): the next poll waits at least
    // FACTOR× the measured round trip so a slow daemon is tailed at spaced
    // intervals instead of every frame.
    send_state.daemon_poll_backoff_ms = daemonChatPollBackoffMs(monotonicMs() - args.started_at_ms);
    send_state.mutex.unlock();
    if (!still_active) return false;

    if (args.failed) {
        return noteDaemonChatTailFailure(thread, "daemon chat turn is unavailable (daemon may have restarted mid-turn)");
    }
    const response = args.response orelse return false;

    // JSON-RPC not_found (turn gone after restart / interrupted sweep with no
    // live memory) — surface immediately rather than spinning.
    if (daemonTailResponseIsNotFound(response)) {
        return noteDaemonChatTailFailure(thread, "daemon chat turn not found after reconnect; message is preserved above");
    }

    const applied = self.applyDaemonChatTurnTail(thread, response) catch |err| {
        log.warn("failed to apply daemon chat turn tail: {s}", .{@errorName(err)});
        return noteDaemonChatTailFailure(thread, "failed to apply daemon chat turn");
    };
    if (applied) {
        send_state.mutex.lock();
        send_state.daemon_tail_fail_count = 0;
        send_state.mutex.unlock();
    }
    return applied;
}

/// Resolves the live thread that owns a daemon turn id; the worker's target
/// may have been reset or deleted while the RPC was in flight.
fn threadByDaemonTurnId(self: anytype, turn_id: []const u8) ?*ChatThread {
    for (self.project_controller.projects.items) |*project| {
        for (project.threads.items) |*thread| {
            const send_state = thread.send_state;
            send_state.mutex.lock();
            defer send_state.mutex.unlock();
            const current = send_state.daemon_turn_id orelse continue;
            if (std.mem.eql(u8, current, turn_id)) return thread;
        }
    }
    return null;
}

fn daemonTailResponseIsNotFound(response: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{}) catch return false;
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return false;
    if (err_val != .object) return false;
    const code = jsonValueString(err_val.object.get("code") orelse .null) orelse return false;
    return std.mem.eql(u8, code, "not_found") or std.mem.eql(u8, code, "resource_not_found");
}

/// Amendment-2 F5: after enough consecutive tail failures, resolve the send to
/// a visible failed state so the GUI does not spin forever. Message content
/// stays in the in-memory transcript (and may already be staged in the store).
fn noteDaemonChatTailFailure(thread: *ChatThread, message: []const u8) bool {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending or !send_state.daemon_owned) return false;
    send_state.daemon_tail_fail_count +|= 1;
    if (send_state.daemon_tail_fail_count < DAEMON_CHAT_TAIL_FAIL_THRESHOLD) return false;
    if (send_state.error_message) |old| std.heap.page_allocator.free(old);
    send_state.error_message = std.heap.page_allocator.dupe(u8, message) catch null;
    send_state.status = .failed;
    send_state.ui_revision +%= 1;
    return true;
}

fn daemonChatPollDue(last_poll_ms: i64, now_ms: i64, backoff_ms: i64) bool {
    return last_poll_ms < 0 or now_ms < last_poll_ms or
        now_ms - last_poll_ms >= DAEMON_CHAT_POLL_INTERVAL_MS + backoff_ms;
}

/// Extra wait before the next tail poll so the render thread spends at most
/// ~1/FACTOR of its time blocked in daemon IPC: the next poll starts no
/// sooner than FACTOR× the measured round trip. Fast responses (≤ interval /
/// factor) keep the plain 16ms cadence; the cap keeps a flapping daemon
/// polled about once a second.
fn daemonChatPollBackoffMs(elapsed_ms: i64) i64 {
    const budget_ms = elapsed_ms * DAEMON_CHAT_POLL_BUDGET_FACTOR - DAEMON_CHAT_POLL_INTERVAL_MS;
    return std.math.clamp(budget_ms, 0, DAEMON_CHAT_POLL_BACKOFF_MAX_MS);
}

test "daemon chat tail polling keeps the active display cadence" {
    try std.testing.expect(daemonChatPollDue(-1, 100, 0));
    try std.testing.expect(!daemonChatPollDue(100, 115, 0));
    try std.testing.expect(daemonChatPollDue(100, 116, 0));
    try std.testing.expect(daemonChatPollDue(100, 10, 0));
    // A measured-cost backoff extends the interval; clock rollback still polls.
    try std.testing.expect(!daemonChatPollDue(100, 259, 144));
    try std.testing.expect(daemonChatPollDue(100, 260, 144));
}

test "daemon chat tail backoff bounds the render-thread stall duty cycle" {
    // A fast daemon (≤4ms round trip) keeps the unmodified 16ms cadence.
    try std.testing.expectEqual(@as(i64, 0), daemonChatPollBackoffMs(0));
    try std.testing.expectEqual(@as(i64, 0), daemonChatPollBackoffMs(4));
    // A 40ms stall (observed "slowest=poll send elapsed_ms=35-41") defers the
    // next poll to 160ms after the last start: ≤25% of frames can stall.
    try std.testing.expectEqual(@as(i64, 144), daemonChatPollBackoffMs(40));
    // A flapping daemon (connect timeouts) is still tailed about once a second.
    try std.testing.expectEqual(DAEMON_CHAT_POLL_BACKOFF_MAX_MS, daemonChatPollBackoffMs(500));
}

test "daemon tail hydrates the missing user row for externally started turns" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "external turn");
    defer thread.deinit(allocator);
    thread.send_state.status = .pending;
    thread.send_state.daemon_owned = true;

    const HydrateState = struct {
        allocator: std.mem.Allocator,
        dirty: usize = 0,
        fn markDirty(self: *@This()) void {
            self.dirty += 1;
        }
        // Comptime requirement of the anytype tail applier; the test response
        // carries no events, so this never runs.
        fn applyDaemonChatEventLocked(_: *@This(), _: *SendState, _: []const u8, _: []const u8) !void {}
    };
    var state: HydrateState = .{ .allocator = allocator };
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"status":"running","events":[],"next_seq":1,"user_message_id":"web-turn:u1","user_prompt":"hello from web"}}
    ;
    try std.testing.expect(try applyDaemonChatTurnTail(&state, &thread, response));
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    const row = thread.messages.items[0];
    try std.testing.expect(row.role == .user);
    try std.testing.expectEqualStrings("You", row.author);
    try std.testing.expectEqualStrings("hello from web", row.body);
    try std.testing.expectEqualStrings("web-turn:u1", row.message_id.?);
    try std.testing.expectEqual(@as(usize, 1), state.dirty);

    // Idempotent across polls: the same identity never duplicates the row
    // (this also covers desktop-originated sends, whose staged user row
    // already carries the acceptance id).
    _ = try applyDaemonChatTurnTail(&state, &thread, response);
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.dirty);
}

test "daemon tail cursor advances only after an event applies" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "retry event");
    defer thread.deinit(allocator);
    thread.send_state.status = .pending;
    thread.send_state.daemon_owned = true;

    const RejectState = struct {
        allocator: std.mem.Allocator,
        fn markDirty(_: *@This()) void {}
        fn applyDaemonChatEventLocked(_: *@This(), _: *SendState, _: []const u8, _: []const u8) !void {
            return error.TestEventRejected;
        }
    };
    var state: RejectState = .{ .allocator = allocator };
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"status":"running","events":[{"seq":1,"kind":"diff","payload_json":"{}"}],"next_seq":2}}
    ;
    try std.testing.expectError(error.TestEventRejected, applyDaemonChatTurnTail(&state, &thread, response));
    try std.testing.expectEqual(@as(u64, 0), thread.send_state.daemon_last_seq);
}

/// True when the thread transcript already carries a row with this durable
/// identity (acceptance-staged user rows and adopted daemon rows both qualify).
fn threadHasMessageId(thread: *const ChatThread, message_id: []const u8) bool {
    for (thread.messages.items) |message| {
        const existing = message.message_id orelse continue;
        if (std.mem.eql(u8, existing, message_id)) return true;
    }
    return false;
}

fn canApplyDaemonGeneratedTitle(current_title: []const u8, expected_title: []const u8) bool {
    return expected_title.len > 0 and
        (std.mem.eql(u8, current_title, expected_title) or
            chat_threads.isPlaceholderThreadTitle(current_title));
}

test "daemon generated title replaces a stale opening placeholder" {
    try std.testing.expect(canApplyDaemonGeneratedTitle("Opening prompt", "Opening prompt"));
    try std.testing.expect(canApplyDaemonGeneratedTitle("New thread", "Opening prompt"));
    try std.testing.expect(canApplyDaemonGeneratedTitle("New Chat", "Opening prompt"));
    try std.testing.expect(!canApplyDaemonGeneratedTitle("Manual title", "Opening prompt"));
}

pub fn applyDaemonChatTurnTail(self: anytype, thread: *ChatThread, response: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{});
    defer parsed.deinit();
    const result = try jsonRpcResult(parsed.value);
    if (result != .object) return error.InvalidDaemonResponse;
    const status_text = jsonValueString(result.object.get("status") orelse .null) orelse "running";
    const events = result.object.get("events") orelse .null;
    var changed = false;

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return false;

    if (jsonValueString(result.object.get("provider_thread_id") orelse .null)) |thread_id| {
        try replacePageOwned(&send_state.provisional_provider_thread_id, thread_id);
    }
    if (jsonValueString(result.object.get("active_turn_id") orelse .null)) |turn_id| {
        try replacePageOwned(&send_state.active_turn_id, turn_id);
    }
    // Attach hydration: turns started from another client (web/CLI/MCP) never
    // staged a local user row, so the desktop transcript was missing the
    // prompt. Mirror it from the tail's acceptance identity; keyed by
    // user_message_id so desktop-originated sends (row already staged with
    // the same id) and repeated polls stay idempotent.
    if (jsonValueString(result.object.get("user_message_id") orelse .null)) |user_message_id| {
        if (jsonValueString(result.object.get("user_prompt") orelse .null)) |user_prompt| {
            if (!threadHasMessageId(thread, user_message_id)) {
                const owned_author = try self.allocator.dupeZ(u8, "You");
                errdefer self.allocator.free(owned_author);
                const owned_body = try self.allocator.dupeZ(u8, user_prompt);
                errdefer self.allocator.free(owned_body);
                const owned_extra = try self.allocator.alloc(ChatImageAttachment, 0);
                errdefer self.allocator.free(owned_extra);
                const owned_id = try self.allocator.dupe(u8, user_message_id);
                errdefer self.allocator.free(owned_id);
                try thread.messages.append(self.allocator, .{
                    .role = .user,
                    .author = owned_author,
                    .body = owned_body,
                    .extra_images = owned_extra,
                    .message_id = owned_id,
                });
                thread.touch();
                self.markDirty();
                changed = true;
            }
        }
    }
    if (events == .array) {
        for (events.array.items) |event_value| {
            if (event_value != .object) continue;
            const seq = jsonValueU64(event_value.object.get("seq") orelse .null) orelse continue;
            const kind = jsonValueString(event_value.object.get("kind") orelse .null) orelse continue;
            const payload_json = jsonValueString(event_value.object.get("payload_json") orelse .null) orelse "{}";
            try self.applyDaemonChatEventLocked(send_state, kind, payload_json);
            if (seq > send_state.daemon_last_seq) send_state.daemon_last_seq = seq;
            changed = true;
        }
    }
    if (result.object.get("pending_approval")) |approval_value| {
        if (try syncDaemonPendingApprovalLocked(send_state, approval_value)) changed = true;
    }
    if (std.mem.eql(u8, status_text, "completed")) {
        if (jsonValueString(result.object.get("generated_title") orelse .null)) |generated_title| {
            const expected_title = jsonValueString(result.object.get("generated_title_expected") orelse .null) orelse "";
            if (canApplyDaemonGeneratedTitle(thread.title, expected_title)) {
                const owned_title = try self.allocator.dupeZ(u8, generated_title);
                self.allocator.free(thread.title);
                thread.title = owned_title;
                thread.committed = true;
                self.markDirty();
            }
        }
        const provider_thread_id = jsonValueString(result.object.get("provider_thread_id") orelse .null) orelse send_state.provisional_provider_thread_id orelse "";
        const reply_text = jsonValueString(result.object.get("result_reply_text") orelse .null) orelse "";
        send_state.result = .{
            .provider_thread_id = try std.heap.page_allocator.dupe(u8, provider_thread_id),
            .reply_text = try std.heap.page_allocator.dupe(u8, reply_text),
        };
        send_state.status = .completed;
        changed = true;
    } else if (std.mem.eql(u8, status_text, "failed")) {
        const message = jsonValueString(result.object.get("error_message") orelse .null) orelse "Provider request failed.";
        send_state.error_message = try std.heap.page_allocator.dupe(u8, message);
        send_state.status = .failed;
        changed = true;
    } else if (std.mem.eql(u8, status_text, "aborted")) {
        send_state.status = .aborted;
        changed = true;
    }
    if (changed) send_state.ui_revision +%= 1;
    return changed;
}

pub fn applyDaemonChatEventLocked(self: anytype, send_state: *SendState, kind: []const u8, payload_json: []const u8) !void {
    _ = self;
    if (std.mem.eql(u8, kind, "assistant_delta")) {
        const text = daemonPayloadStringAlloc(payload_json, "text") orelse return;
        defer std.heap.page_allocator.free(text);
        try send_state.partial_text.appendSlice(std.heap.page_allocator, text);
    } else if (std.mem.eql(u8, kind, "message") or std.mem.eql(u8, kind, "steer")) {
        flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDaemonResponse;
        const object = parsed.value.object;
        const title = jsonValueString(object.get("title") orelse .null) orelse "System";
        const body = jsonValueString(object.get("body") orelse .null) orelse "";
        const owned_author = try std.heap.page_allocator.dupe(u8, title);
        errdefer std.heap.page_allocator.free(owned_author);
        const owned_body = try std.heap.page_allocator.dupe(u8, body);
        errdefer std.heap.page_allocator.free(owned_body);
        // M4-P4 fix: honor a payload identity when the daemon event carries
        // one (transcript_apply keys the committed row by the same value), so
        // the projection row lands id-carrying without waiting for terminal
        // adoption.
        const payload_message_id = if (jsonValueString(object.get("message_id") orelse .null)) |value|
            try std.heap.page_allocator.dupe(u8, value)
        else
            null;
        errdefer if (payload_message_id) |value| std.heap.page_allocator.free(value);
        var event: PendingTimelineEvent = .{
            .role = .system,
            .author = owned_author,
            .body = owned_body,
            .message_id = payload_message_id,
        };
        errdefer event.deinit(std.heap.page_allocator);
        if (object.get("images")) |images| if (images == .array) {
            try event.images.ensureTotalCapacity(std.heap.page_allocator, images.array.items.len);
            for (images.array.items) |image| {
                if (image != .object) return error.InvalidDaemonResponse;
                const path = jsonValueString(image.object.get("path") orelse .null) orelse return error.InvalidDaemonResponse;
                const mime = jsonValueString(image.object.get("mime") orelse .null) orelse "";
                const byte_size = jsonValueU64(image.object.get("byte_size") orelse .null) orelse 0;
                event.images.appendAssumeCapacity(try ChatImageAttachment.init(std.heap.page_allocator, path, mime, byte_size));
            }
        };
        try send_state.pending_events.append(std.heap.page_allocator, event);
    } else if (std.mem.eql(u8, kind, "tool_call")) {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDaemonResponse;
        const object = parsed.value.object;
        const call_id = jsonValueString(object.get("call_id") orelse .null) orelse "";
        const title = jsonValueString(object.get("title") orelse .null) orelse "";
        const kind_text = jsonValueString(object.get("kind") orelse .null);
        const status_text = jsonValueString(object.get("status") orelse .null);
        const update: ai_harness.ToolCallUpdate = .{
            .call_id = call_id,
            .title = title,
            .kind = if (kind_text) |value| parseToolCallKind(value) else null,
            .status = if (status_text) |value| parseToolCallStatus(value) else null,
            .input = jsonValueString(object.get("input") orelse .null),
            .output = jsonValueString(object.get("output") orelse .null),
            .error_text = jsonValueString(object.get("error_text") orelse .null),
            .locations = jsonValueString(object.get("locations") orelse .null),
            .raw = jsonValueString(object.get("raw") orelse .null),
        };
        // Content-less reasoning drives the "Thinking" header indicator
        // instead of a timeline row; mirror the GUI-owned stream path.
        if (transientThinkStatus(update)) |thinking| {
            send_state.thinking = thinking;
            return;
        }
        // Flush like the GUI-owned stream path does, so tool rows land
        // between assistant text segments instead of stacking above one
        // ever-growing trailing bubble on daemon-owned turns.
        flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
        try upsertPendingToolCallEvent(std.heap.page_allocator, &send_state.pending_events, update);
    } else if (std.mem.eql(u8, kind, "diff")) {
        try applyDaemonDiffEventLocked(send_state, payload_json);
    } else if (std.mem.eql(u8, kind, "thread_id")) {
        if (daemonPayloadStringAlloc(payload_json, "thread_id")) |thread_id| {
            defer std.heap.page_allocator.free(thread_id);
            try replacePageOwned(&send_state.provisional_provider_thread_id, thread_id);
        }
    } else if (std.mem.eql(u8, kind, "turn_id")) {
        if (daemonPayloadStringAlloc(payload_json, "turn_id")) |turn_id| {
            defer std.heap.page_allocator.free(turn_id);
            try replacePageOwned(&send_state.active_turn_id, turn_id);
        }
    }
}

pub fn applyDaemonDiffEventLocked(send_state: *SendState, payload_json: []const u8) !void {
    const allocator = std.heap.page_allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDaemonResponse;
    const files_value = parsed.value.object.get("files") orelse return error.InvalidDaemonResponse;
    if (files_value != .array) return error.InvalidDaemonResponse;

    var files: std.ArrayList(ai_harness.StreamDiffFile) = .empty;
    defer files.deinit(allocator);
    for (files_value.array.items) |file_value| {
        if (file_value != .object) continue;
        const path = jsonValueString(file_value.object.get("path") orelse .null) orelse continue;
        const additions = jsonValueI64(file_value.object.get("additions") orelse .null) orelse 0;
        const deletions = jsonValueI64(file_value.object.get("deletions") orelse .null) orelse 0;
        try files.append(allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = jsonValueString(file_value.object.get("patch") orelse .null),
        });
    }
    if (files.items.len == 0) return;

    flushPendingAssistantTextLocked(send_state, allocator);
    const scope_text = jsonValueString(parsed.value.object.get("scope") orelse .null) orelse "incremental";
    const scope: ai_harness.StreamDiffScope = if (std.mem.eql(u8, scope_text, "turn_snapshot"))
        .turn_snapshot
    else
        .incremental;
    utils.applyPendingDiffUpdateLocked(allocator, send_state, .{
        .files = files.items,
        .scope = scope,
    });
}

pub fn parseToolCallKind(value: []const u8) ai_harness.ToolCallKind {
    if (std.mem.eql(u8, value, "read")) return .read;
    if (std.mem.eql(u8, value, "edit")) return .edit;
    if (std.mem.eql(u8, value, "delete")) return .delete;
    if (std.mem.eql(u8, value, "move")) return .move;
    if (std.mem.eql(u8, value, "search")) return .search;
    if (std.mem.eql(u8, value, "execute")) return .execute;
    if (std.mem.eql(u8, value, "think")) return .think;
    if (std.mem.eql(u8, value, "fetch")) return .fetch;
    if (std.mem.eql(u8, value, "mcp")) return .mcp;
    return .other;
}

pub fn parseToolCallStatus(value: []const u8) ai_harness.ToolCallStatus {
    if (std.mem.eql(u8, value, "pending")) return .pending;
    if (std.mem.eql(u8, value, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, value, "completed")) return .completed;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "cancelled")) return .cancelled;
    return .unknown;
}

pub fn pollThreadSend(self: anytype, project_index: usize, thread_index: usize, thread: *ChatThread) bool {
    thread.send_state.mutex.lock();
    const command_pending = thread.send_state.local_command;
    // While the async chat.turn.start receipt is in flight (7.5) the daemon
    // turn may not exist yet: defer tailing (which would count not-found
    // failures toward the tail-fail threshold) and steer/stop issuance until
    // the acceptance commits. The working-seconds repaint below still runs.
    const acceptance_pending = thread.send_state.acceptance_pending;
    thread.send_state.mutex.unlock();
    const rpc_gated = command_pending or acceptance_pending;
    const daemon_changed = if (rpc_gated) false else self.pollDaemonChatTurn(thread);
    if (!rpc_gated) {
        self.capturePendingProviderThreadId(thread);
        self.issuePendingProviderSteer(project_index, thread_index, thread);
        self.issuePendingThreadStop(project_index, self.project_controller.projects.items[project_index].path, thread);
    }

    var completed_result: ?SendResultPayload = null;
    var failed_message: ?[]u8 = null;
    var had_pending_followup = false;
    var next_status: SendStatus = .idle;
    var completed_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty;
    var completed_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty;
    var completed_daemon_turn_id: ?[]u8 = null;
    var completed_local_command = false;
    const send_state = thread.send_state;
    var stream_changed = false;

    if (!send_state.mutex.tryLock()) return false;
    if (workerCleanupPending(
        send_state.status != .pending and send_state.status != .idle,
        send_state.worker != null,
        send_state.worker_done.load(.acquire),
    )) {
        send_state.mutex.unlock();
        return daemon_changed;
    }
    switch (send_state.status) {
        .pending => {
            if (send_state.ui_revision != send_state.polled_ui_revision) {
                send_state.polled_ui_revision = send_state.ui_revision;
                stream_changed = true;
            }
            // Force a repaint exactly when the visible seconds in the
            // "Working - mm:ss" label would change. Without this, the
            // main loop sleeps in SDL_WaitEventTimeout(IDLE) while a
            // turn is in flight and no tokens are streaming, so the
            // wall-clock label freezes until the user moves the mouse.
            const safe_started_at_ms = @max(send_state.started_at_ms, 0);
            const elapsed_ms = @max(unixTimestampMs() - safe_started_at_ms, 0);
            const elapsed_seconds = @divTrunc(elapsed_ms, std.time.ms_per_s);
            if (elapsed_seconds != send_state.polled_working_seconds) {
                send_state.polled_working_seconds = elapsed_seconds;
                stream_changed = true;
            }
        },
        .completed => {
            completed_local_command = send_state.local_command;
            had_pending_followup = send_state.pending_followup != null;
            completed_result = send_state.result;
            send_state.result = null;
            if (send_state.provisional_provider_thread_id) |thread_id| {
                std.heap.page_allocator.free(thread_id);
                send_state.provisional_provider_thread_id = null;
            }
            if (send_state.active_turn_id) |turn_id| {
                std.heap.page_allocator.free(turn_id);
                send_state.active_turn_id = null;
            }
            flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
            completed_events = send_state.pending_events;
            send_state.pending_events = .empty;
            completed_diff_files = send_state.pending_diff_files;
            send_state.pending_diff_files = .empty;
            send_state.pending_diff_has_turn_snapshot = false;
            freePendingApprovalLocked(std.heap.page_allocator, &send_state.pending_approval);
            send_state.approval_decision = null;
            send_state.provider = null;
            send_state.started_at_ms = 0;
            send_state.thinking = false;
            completed_daemon_turn_id = send_state.daemon_turn_id;
            send_state.daemon_turn_id = null;
            send_state.daemon_owned = false;
            send_state.daemon_last_seq = 0;
            send_state.daemon_last_poll_ms = -1;
            send_state.status = .idle;
            next_status = .completed;
        },
        .aborted => {
            completed_local_command = send_state.local_command;
            had_pending_followup = send_state.pending_followup != null;
            if (send_state.provisional_provider_thread_id) |thread_id| {
                std.heap.page_allocator.free(thread_id);
                send_state.provisional_provider_thread_id = null;
            }
            if (send_state.active_turn_id) |turn_id| {
                std.heap.page_allocator.free(turn_id);
                send_state.active_turn_id = null;
            }
            flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
            completed_events = send_state.pending_events;
            send_state.pending_events = .empty;
            completed_diff_files = send_state.pending_diff_files;
            send_state.pending_diff_files = .empty;
            send_state.pending_diff_has_turn_snapshot = false;
            freePendingApprovalLocked(std.heap.page_allocator, &send_state.pending_approval);
            send_state.approval_decision = null;
            send_state.provider = null;
            send_state.started_at_ms = 0;
            send_state.thinking = false;
            completed_daemon_turn_id = send_state.daemon_turn_id;
            send_state.daemon_turn_id = null;
            send_state.daemon_owned = false;
            send_state.daemon_last_seq = 0;
            send_state.daemon_last_poll_ms = -1;
            send_state.status = .idle;
            next_status = .aborted;
        },
        .failed => {
            completed_local_command = send_state.local_command;
            failed_message = send_state.error_message;
            send_state.error_message = null;
            if (send_state.provisional_provider_thread_id) |thread_id| {
                std.heap.page_allocator.free(thread_id);
                send_state.provisional_provider_thread_id = null;
            }
            if (send_state.active_turn_id) |turn_id| {
                std.heap.page_allocator.free(turn_id);
                send_state.active_turn_id = null;
            }
            send_state.partial_text.clearRetainingCapacity();
            completed_events = send_state.pending_events;
            send_state.pending_events = .empty;
            completed_diff_files = send_state.pending_diff_files;
            send_state.pending_diff_files = .empty;
            send_state.pending_diff_has_turn_snapshot = false;
            freePendingApprovalLocked(std.heap.page_allocator, &send_state.pending_approval);
            send_state.approval_decision = null;
            send_state.provider = null;
            send_state.started_at_ms = 0;
            send_state.thinking = false;
            completed_daemon_turn_id = send_state.daemon_turn_id;
            send_state.daemon_turn_id = null;
            send_state.daemon_owned = false;
            send_state.daemon_last_seq = 0;
            send_state.daemon_last_poll_ms = -1;
            send_state.status = .idle;
            next_status = .failed;
        },
        else => {},
    }
    if (next_status != .idle) clearControlFailureLocked(send_state);
    send_state.mutex.unlock();

    if (next_status != .idle) {
        self.chat_controller.finishSend();
        thread.finishSendThread();
        self.clearPendingTranscriptBody(thread);
        if (project_index < self.project_controller.projects.items.len) {
            self.project_controller.projects.items[project_index].invalidateSidebarThreadCache();
        }
        send_state.mutex.lock();
        if (send_state.local_command_text) |value| std.heap.page_allocator.free(value);
        if (send_state.local_command_cwd) |value| std.heap.page_allocator.free(value);
        if (send_state.local_command_shell) |value| std.heap.page_allocator.free(value);
        send_state.local_command_text = null;
        send_state.local_command_cwd = null;
        send_state.local_command_shell = null;
        send_state.local_command = false;
        send_state.mutex.unlock();
    }

    // The turn is over on every terminal path, so no provider can deliver
    // the terminal lifecycle event for a still-running tool row anymore;
    // downgrade leftovers before they persist into the transcript.
    if (next_status == .completed or next_status == .aborted or next_status == .failed) {
        cancelLingeringToolCallEvents(std.heap.page_allocator, &completed_events);
    }

    switch (next_status) {
        .completed => {
            if (completed_result) |result| {
                defer std.heap.page_allocator.free(result.provider_thread_id);
                defer std.heap.page_allocator.free(result.reply_text);
                defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
                defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
                const should_append_reply_text = !pendingTimelineEventsContainAssistant(completed_events.items);
                self.applyPendingTimelineEvents(thread, &completed_events) catch |err| {
                    log.err("failed to apply timeline events: {s}", .{@errorName(err)});
                };
                if (!completed_local_command) {
                    self.applySendSuccess(thread, result, should_append_reply_text) catch |err| {
                        log.err("failed to apply send result: {s}", .{@errorName(err)});
                        self.setSidebarNotice("Failed to apply provider reply.");
                    };
                    // Daemon-owned turns generate and durably commit their
                    // title before publishing completion. Keep the local
                    // worker only for legacy/non-daemon sends.
                    if (completed_daemon_turn_id == null) self.maybeStartAutomaticTitleGeneration(project_index, thread);
                } else {
                    thread.touch();
                    self.markDirty();
                    self.setSidebarNotice("Workspace command finished.");
                }
                if (!completed_local_command) stopUnownedBackgroundTasksAtTurnEnd(self, thread);
                if (project_index == self.project_controller.selected_index and thread_index == self.currentProject().selected_thread_index) {
                    self.requestTranscriptScrollToBottomIfFollowing();
                }
                // M4-P4 fix: adopt the daemon-minted transcript identities into
                // the projection, then flush unconditionally. The flush itself
                // is identity-preserving now (PersistedMessage carries
                // message_id end-to-end; the store's applySnapshot upserts by
                // identity and preserves daemon-committed rows missing from
                // the snapshot), so no flush site needs gating anymore — this
                // one, the frame-loop debounce, title-generation completion,
                // provider_thread_id capture, bang-command start, and the
                // close-time blocking flush are all safe by construction.
                if (completed_daemon_turn_id) |turn_id| adoptDaemonTranscriptIdentitiesWithRetry(self, project_index, thread, turn_id);
                self.flushDirtyNow();
                // Consume is a retention hint only (daemon already committed).
                self.consumeDaemonChatTurn(completed_daemon_turn_id);
            }
        },
        .failed => {
            defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
            defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
            if (failed_message) |message| {
                defer std.heap.page_allocator.free(message);
                self.applySendFailure(thread, &completed_events, message) catch |err| {
                    log.err("failed to apply send failure: {s}", .{@errorName(err)});
                };
                self.setSidebarNotice(message);
            } else {
                self.setSidebarNotice("Provider request failed.");
            }
            if (!completed_local_command) stopUnownedBackgroundTasksAtTurnEnd(self, thread);
            // M4-P4 fix: identity-preserving flush — adopt ids (failed turns
            // also commit durably), then flush without gating.
            if (completed_daemon_turn_id) |turn_id| adoptDaemonTranscriptIdentitiesWithRetry(self, project_index, thread, turn_id);
            self.flushDirtyNow();
            self.consumeDaemonChatTurn(completed_daemon_turn_id);
        },
        .aborted => {
            defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
            defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
            self.applyPendingTimelineEvents(thread, &completed_events) catch |err| {
                log.err("failed to apply aborted timeline events: {s}", .{@errorName(err)});
            };
            if (completed_local_command) {
                if (completed_events.items.len == 0) {
                    self.appendMessageToThread(thread, .system, "Command cancelled", "The workspace command was cancelled before it completed.", null, &.{}) catch {};
                }
            } else if (!had_pending_followup) {
                self.appendMessageToThread(
                    thread,
                    .system,
                    "Conversation interrupted",
                    "Tell the model what to do differently.",
                    null,
                    &.{},
                ) catch |err| {
                    log.err("failed to append interruption notice: {s}", .{@errorName(err)});
                };
            }
            thread.touch();
            self.markDirty();
            self.setSidebarNotice(if (completed_local_command) "Workspace command cancelled." else "Provider reply stopped.");
            if (!completed_local_command) stopUnownedBackgroundTasksAtTurnEnd(self, thread);
            // M4-P4 fix: identity-preserving flush — adopt ids (aborted turns
            // also commit durably), then flush without gating.
            if (completed_daemon_turn_id) |turn_id| adoptDaemonTranscriptIdentitiesWithRetry(self, project_index, thread, turn_id);
            self.flushDirtyNow();
            self.consumeDaemonChatTurn(completed_daemon_turn_id);
        },
        else => {},
    }

    if (next_status == .failed) {
        self.clearPendingFollowupAfterFailure(thread);
    }
    if (!completed_local_command and (next_status == .completed or next_status == .aborted)) {
        self.dispatchPendingFollowup(project_index, thread_index, thread);
    }
    // Record a real chat turn completion. Skip when a follow-up is queued
    // (the turn continues immediately) so DONE only appears once the agent
    // truly rests, mirroring the terminal-agent `.done` notification.
    // M4-P4 / Q3: daemon-owned completions already upserted the ledger row
    // in the commit transaction; GUI only focused-clears (or mirrors pending).
    if (!completed_local_command and next_status == .completed and !had_pending_followup) {
        self.noteChatCompletion(project_index, thread_index, thread, completed_daemon_turn_id != null);
    }
    return next_status != .idle or stream_changed or daemon_changed;
}

fn projectionHasMessageId(thread: *const ChatThread, message_id: []const u8) bool {
    for (thread.messages.items) |message| {
        const existing = message.message_id orelse continue;
        if (std.mem.eql(u8, existing, message_id)) return true;
    }
    return false;
}

/// M4-P5 fix amendment: adoption result. `incomplete` marks any attempt that
/// could leave daemon-minted identities unadopted (RPC/parse failure, durable
/// row not yet visible, or a row mismatch) and therefore must be retried.
/// pub so the headless IT amendment arm can assert the retry contract.
pub const AdoptionOutcome = enum { complete, incomplete };

/// M4-P4 fix: adopt daemon-minted transcript identities into the in-memory
/// projection at terminal via the durable `chat.thread.get` read, so the next
/// persistence flush carries `turn:{id}:msg:{n}` ids instead of re-minting.
///
/// Runs on the poll path AFTER the terminal branch released the send_state
/// mutex — no GUI mutex is held across the RPC, and `thread.messages` is
/// main-thread-owned state. Alignment is conservative: rows the projection
/// already ids are skipped; each remaining id-carrying store row aligns to the
/// next id-less projection row in order only when role+body match exactly.
/// A mismatch logs loudly and leaves the projection row id-less — an id is
/// never guessed (an id-less row persists as a legacy `snap-msg` row, which
/// the store belt then dedupes by identity, never by position).
///
/// M4-P5 fix amendment: no longer one-shot — the outcome is reported so a
/// failed or partial adoption is queued for retry (adoption is idempotent).
pub fn adoptDaemonTranscriptIdentities(self: anytype, project_index: usize, thread: *ChatThread) AdoptionOutcome {
    if (project_index >= self.project_controller.projects.items.len) return .complete;
    const workspace_id = self.project_controller.projects.items[project_index].id;
    return adoptDaemonTranscriptIdentitiesByWorkspaceId(self, workspace_id, thread);
}

/// Workspace-id-keyed adoption entry (M5-P4 Amendment 2): the RPC only needs
/// the workspace id, so retries can reach archived threads and archived
/// workspaces where no live project index exists.
fn adoptDaemonTranscriptIdentitiesByWorkspaceId(self: anytype, workspace_id: []const u8, thread: *ChatThread) AdoptionOutcome {
    const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.thread.get", .{
        .workspace_id = workspace_id,
        .local_thread_id = thread.local_thread_id,
    }, 6) catch |err| {
        log.warn("failed to fetch durable thread for identity adoption: {s}", .{@errorName(err)});
        return .incomplete;
    };
    defer self.allocator.free(response);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{}) catch |err| {
        log.warn("failed to parse durable thread for identity adoption: {s}", .{@errorName(err)});
        return .incomplete;
    };
    defer parsed.deinit();
    // A missing/oddly-shaped durable row may simply not be visible yet
    // (daemon restarting, commit racing the terminal tick): retryable.
    const result = jsonRpcResult(parsed.value) catch return .incomplete;
    if (result != .object) return .incomplete;
    const thread_value = result.object.get("thread") orelse return .incomplete;
    if (thread_value != .object) return .incomplete;
    const messages_value = thread_value.object.get("messages") orelse return .incomplete;
    if (messages_value != .array) return .incomplete;
    return adoptTranscriptIdentitiesFromStoreMessages(self, thread, messages_value.array.items);
}

/// Pure alignment half of the adoption (no RPC), split out so the retry
/// contract is unit-testable: mismatches and OOM leave rows id-less and
/// report `incomplete`; a pass where every store id is either already
/// present or adopted reports `complete`.
fn adoptTranscriptIdentitiesFromStoreMessages(
    self: anytype,
    thread: *ChatThread,
    store_messages: []const std.json.Value,
) AdoptionOutcome {
    var projection_index: usize = 0;
    var adopted_any = false;
    var unresolved = false;
    for (store_messages) |message_value| {
        if (message_value != .object) continue;
        const store_id = jsonValueString(message_value.object.get("message_id") orelse .null) orelse continue;
        if (store_id.len == 0) continue;
        if (projectionHasMessageId(thread, store_id)) continue;
        while (projection_index < thread.messages.items.len and thread.messages.items[projection_index].message_id != null) {
            projection_index += 1;
        }
        if (projection_index >= thread.messages.items.len) {
            // Store rows beyond the projection carry content the projection
            // never held; the store belt preserves them by identity, so there
            // is nothing to adopt into — not a retry condition.
            break;
        }
        const store_role = jsonValueString(message_value.object.get("role") orelse .null) orelse continue;
        const store_body = jsonValueString(message_value.object.get("body") orelse .null) orelse continue;
        // Forward-scan alignment: a single divergent projection row must not
        // pin the cursor and cascade mismatches onto every later store row
        // (one stuck row used to mint hundred-row repair markers that froze
        // projection convergence). Adopt into the first id-less row whose
        // role+body fingerprint matches, in order; skipped projection rows
        // stay id-less and are never revisited, so ordering is preserved.
        const match_index: ?usize = blk: {
            var scan_index = projection_index;
            while (scan_index < thread.messages.items.len) : (scan_index += 1) {
                const candidate = &thread.messages.items[scan_index];
                if (candidate.message_id != null) continue;
                if (std.mem.eql(u8, store_role, @tagName(candidate.role)) and
                    std.mem.eql(u8, store_body, candidate.body)) break :blk scan_index;
            }
            break :blk null;
        };
        if (match_index) |matched| {
            const row = &thread.messages.items[matched];
            row.message_id = self.allocator.dupe(u8, store_id) catch null;
            if (row.message_id != null) adopted_any = true else unresolved = true;
            projection_index = matched + 1;
        } else {
            unresolved = true;
            log.warn(
                "daemon transcript identity adoption mismatch for {s} (store role={s}): no id-less projection row matches; leaving store identity unadopted",
                .{ store_id, store_role },
            );
        }
    }
    if (adopted_any) self.markDirty();
    return if (unresolved) .incomplete else .complete;
}

// ---------------------------------------------------------------------------
// M4-P5 fix amendment (m4p4fix verify MAJOR-1): adoption retry registry.
//
// A failed or partial terminal adoption used to be one-shot: the unconditional
// flush then persisted id-less `snap-msg` copies of daemon content while the
// store belt restored the `turn:%` twins — permanent duplication on reopen.
// Adoption is idempotent, so incomplete attempts are queued here (keyed by
// workspace+thread+turn ids) and retried on later pollSend ticks until complete.
// Main-thread-only, matching the ownership rule for `thread.messages`; keys
// use page_allocator so no per-controller allocator outlives its owner.
// Snapshot persistence is gated while a covered row is still id-less.
// ---------------------------------------------------------------------------

const ADOPTION_RETRY_INTERVAL_MS: i64 = 1_000;
/// M5-P4 Amendment 2: exponential backoff ceiling. The base interval doubles
/// per consecutive failure (1s, 2s, 4s, ... capped here) so a wedged daemon
/// costs one RPC a minute instead of one a second, forever.
const ADOPTION_RETRY_MAX_BACKOFF_MS: i64 = 60_000;
/// M5-P4 Amendment 2: loud give-up bound. Past this many consecutive failed
/// attempts (~1.5h at the capped backoff) the entry enters a terminal failed
/// state until cursor reconciliation supplies durable identities.
const ADOPTION_RETRY_MAX_ATTEMPTS: u32 = 100;
/// Bounded logging: warn once per this many consecutive failed retries.
const ADOPTION_RETRY_LOG_EVERY: u32 = 10;
const ADOPTION_RETRY_KEY_SEPARATOR: u8 = 0x1f;

const AdoptionExpectedRow = struct {
    row_index_hint: ?usize,
    role: provider_models.ChatRole,
    author: []u8,
    body: []u8,

    fn deinit(self: *AdoptionExpectedRow) void {
        std.heap.page_allocator.free(self.author);
        std.heap.page_allocator.free(self.body);
    }
};

const AdoptionRetryState = struct {
    attempts: u32 = 0,
    next_retry_at_ms: i64 = 0,
    terminal_failed: bool = false,
    /// Failed projection-refresh validations; bounds the terminal veto.
    refresh_validation_failures: u32 = 0,
    turn_id: []u8,
    rows: std.ArrayList(AdoptionExpectedRow) = .empty,

    fn init(turn_id: []const u8, thread: *const ChatThread) !AdoptionRetryState {
        var state: AdoptionRetryState = .{ .turn_id = try std.heap.page_allocator.dupe(u8, turn_id) };
        errdefer state.deinit();
        for (thread.messages.items, 0..) |message, row_index| {
            if (message.message_id != null) continue;
            var row: AdoptionExpectedRow = .{
                .row_index_hint = row_index,
                .role = message.role,
                .author = try std.heap.page_allocator.dupe(u8, message.author),
                .body = undefined,
            };
            var row_owned = true;
            errdefer if (row_owned) std.heap.page_allocator.free(row.author);
            row.body = try std.heap.page_allocator.dupe(u8, message.body);
            errdefer if (row_owned) std.heap.page_allocator.free(row.body);
            try state.rows.append(std.heap.page_allocator, row);
            row_owned = false;
        }
        return state;
    }

    fn deinit(self: *AdoptionRetryState) void {
        for (self.rows.items) |*row| row.deinit();
        self.rows.deinit(std.heap.page_allocator);
        std.heap.page_allocator.free(self.turn_id);
    }
};

var adoption_retry_pending: std.StringHashMapUnmanaged(AdoptionRetryState) = .empty;

/// Refresh-veto counts must survive marker churn. `clearAdoptionPending` is
/// called on paths that only CLAIM resolution (pollThreadSend `.complete`,
/// pump satisfaction) — when the durable projection keeps regressing (e.g.
/// rejected flushes), the same turn re-mints a fresh marker whose
/// `refresh_validation_failures` restarted at zero, so one cycling repair
/// could veto every projection refresh forever without crossing the terminal
/// bound. Keys mirror `adoption_retry_pending`; an entry is forgotten only on
/// durably proven resolution (`.unique` refresh validation), never on clear.
var adoption_veto_history: std.StringHashMapUnmanaged(u32) = .empty;
/// Belt on history growth: only keys with at least one failed refresh
/// validation are recorded, so a real session holds a handful. At the cap new
/// keys are simply not recorded (worst case: today's restart-from-zero).
const ADOPTION_VETO_HISTORY_MAX: usize = 256;

fn rememberAdoptionVetoHistory(key: []const u8, failures: u32) void {
    if (adoption_veto_history.getPtr(key)) |existing| {
        existing.* = @max(existing.*, failures);
        return;
    }
    if (adoption_veto_history.count() >= ADOPTION_VETO_HISTORY_MAX) return;
    const owned = std.heap.page_allocator.dupe(u8, key) catch return;
    adoption_veto_history.put(std.heap.page_allocator, owned, failures) catch {
        std.heap.page_allocator.free(owned);
    };
}

fn forgetAdoptionVetoHistory(key: []const u8) void {
    if (adoption_veto_history.fetchRemove(key)) |entry| std.heap.page_allocator.free(entry.key);
}

fn adoptionRetryKeyAlloc(workspace_id: []const u8, local_thread_id: []const u8, turn_id: []const u8) ?[]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f{s}\x1f{s}", .{ workspace_id, local_thread_id, turn_id }) catch null;
}

const AdoptionRetryKeyParts = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    turn_id: []const u8,
};

fn adoptionRetryKeyParts(key: []const u8) ?AdoptionRetryKeyParts {
    const first = std.mem.indexOfScalar(u8, key, ADOPTION_RETRY_KEY_SEPARATOR) orelse return null;
    const tail = key[first + 1 ..];
    const second_relative = std.mem.indexOfScalar(u8, tail, ADOPTION_RETRY_KEY_SEPARATOR) orelse return null;
    const second = first + 1 + second_relative;
    return .{
        .workspace_id = key[0..first],
        .local_thread_id = key[first + 1 .. second],
        .turn_id = key[second + 1 ..],
    };
}

fn markAdoptionPending(workspace_id: []const u8, thread: *const ChatThread, turn_id: []const u8) void {
    const key = adoptionRetryKeyAlloc(workspace_id, thread.local_thread_id, turn_id) orelse return;
    const gop = adoption_retry_pending.getOrPut(std.heap.page_allocator, key) catch {
        std.heap.page_allocator.free(key);
        return;
    };
    if (gop.found_existing) {
        std.heap.page_allocator.free(key);
    } else {
        gop.value_ptr.* = AdoptionRetryState.init(turn_id, thread) catch {
            _ = adoption_retry_pending.remove(key);
            std.heap.page_allocator.free(key);
            return;
        };
        // A re-minted marker resumes its refresh-veto count. Restarting from
        // zero let a clear/re-mint cycle outrun the terminal bound forever,
        // freezing projection convergence app-wide (blank panes until the
        // render-path rehydration kicked in).
        gop.value_ptr.refresh_validation_failures = adoption_veto_history.get(key) orelse 0;
    }
    gop.value_ptr.attempts +|= 1;
    const attempts = gop.value_ptr.attempts;
    if (attempts >= ADOPTION_RETRY_MAX_ATTEMPTS) {
        // Loud give-up (never silent): retain a terminal repair marker until
        // a cursor snapshot supplies durable identities. The test runner
        // fails the whole binary on err-level logs, so the give-up unit test
        // (which drives this arm for real) demotes the level — production
        // keeps err.
        if (builtin.is_test) {
            log.warn(
                "transcript identity adoption for {s} entered terminal repair after {d} attempts",
                .{ thread.local_thread_id, attempts },
            );
        } else {
            log.err(
                "transcript identity adoption for {s} entered terminal repair after {d} attempts",
                .{ thread.local_thread_id, attempts },
            );
        }
        gop.value_ptr.terminal_failed = true;
        gop.value_ptr.next_retry_at_ms = std.math.maxInt(i64);
        return;
    }
    const backoff_shift: u6 = @intCast(@min(attempts -| 1, 6));
    const backoff_ms = @min(ADOPTION_RETRY_INTERVAL_MS << backoff_shift, ADOPTION_RETRY_MAX_BACKOFF_MS);
    gop.value_ptr.next_retry_at_ms = sessionizer.nowMs() + backoff_ms;
    if (attempts > 1 and attempts % ADOPTION_RETRY_LOG_EVERY == 0) {
        log.warn(
            "daemon transcript identity adoption still incomplete for {s} after {d} attempts; retrying",
            .{ thread.local_thread_id, attempts },
        );
    }
}

fn clearAdoptionPending(workspace_id: []const u8, local_thread_id: []const u8, turn_id: []const u8) void {
    const key = adoptionRetryKeyAlloc(workspace_id, local_thread_id, turn_id) orelse return;
    defer std.heap.page_allocator.free(key);
    if (adoption_retry_pending.fetchRemove(key)) |entry| {
        var state = entry.value;
        state.deinit();
        std.heap.page_allocator.free(entry.key);
    }
}

/// Test seam for the real dirty-gate/adoption-refresh path. Production creates
/// this state only through the bounded retry pump above.
pub fn markAdoptionTerminalRepairForTest(self: anytype, workspace_id: []const u8, local_thread_id: []const u8, turn_id: []const u8) void {
    std.debug.assert(builtin.is_test);
    const thread = retryAdoptionThreadByLocalId(self, workspace_id, local_thread_id) orelse return;
    markAdoptionPending(workspace_id, thread, turn_id);
    const key = adoptionRetryKeyAlloc(workspace_id, local_thread_id, turn_id) orelse return;
    defer std.heap.page_allocator.free(key);
    const entry = adoption_retry_pending.getPtr(key) orelse return;
    entry.attempts = ADOPTION_RETRY_MAX_ATTEMPTS;
    entry.terminal_failed = true;
    entry.next_retry_at_ms = std.math.maxInt(i64);
}

pub fn clearAdoptionRepairForTest(workspace_id: []const u8, local_thread_id: []const u8, turn_id: []const u8) void {
    std.debug.assert(builtin.is_test);
    clearAdoptionPending(workspace_id, local_thread_id, turn_id);
    // Veto history deliberately survives production clears; tests share the
    // module-global registry, so their cleanup must also forget it or one
    // test's veto counts would seed a later test's re-mint of the same key.
    if (adoptionRetryKeyAlloc(workspace_id, local_thread_id, turn_id)) |key| {
        defer std.heap.page_allocator.free(key);
        forgetAdoptionVetoHistory(key);
    }
}

/// True while any turn-bound adoption marker owns unresolved correspondence.
/// Lifecycle persistence calls this before capture so it can never mint a
/// `snap-msg-*` twin for daemon-owned content.
pub fn hasUnresolvedAdoptionRows(self: anytype) bool {
    _ = self;
    var iterator = adoption_retry_pending.iterator();
    return iterator.next() != null;
}

/// A repair whose fingerprints keep failing refresh validation against fresh
/// durable snapshots is unresolvable in practice (e.g. durable rows disagree
/// on role/body with what the projection rendered). Past this many failed
/// validations its veto is abandoned so one poisoned marker can never freeze
/// projection convergence and dirty-state capture for the retry pump's
/// multi-hour give-up horizon — or, via the shutdown spool, forever. The
/// worker's 250ms–5s refresh backoff makes this bound ≈30s of protection,
/// far beyond commit-visibility races.
const ADOPTION_REPAIR_MAX_REFRESH_VETOES: u32 = 10;

/// Prove every covered local row has the matching durable turn identity before
/// projection ownership can swap. A different all-identified transcript is
/// not satisfaction and must leave both the live rows and marker untouched —
/// while resolution is still plausible. A repair that keeps failing this
/// validation against fresh durable snapshots has no remaining path to
/// satisfaction; after a bounded number of vetoes the daemon-owned durable
/// projection wins: the marker is dropped loudly, accepting bounded, visible
/// divergence in one thread instead of an app-wide convergence freeze.
pub fn validateAdoptionRepairsForRefresh(self: anytype, persisted: db_types.PersistedState) !void {
    var dropped_keys: std.ArrayList([]const u8) = .empty;
    defer dropped_keys.deinit(std.heap.page_allocator);
    var veto: ?anyerror = null;
    var iterator = adoption_retry_pending.iterator();
    while (iterator.next()) |entry| {
        // A malformed key can never resolve; drop it instead of aborting the
        // whole pass — an early return here skipped the counter increment for
        // every marker, letting one bad entry veto refreshes forever.
        const parts = adoptionRetryKeyParts(entry.key_ptr.*) orelse {
            log.warn("dropping adoption repair with malformed key: durable projection wins", .{});
            try dropped_keys.append(std.heap.page_allocator, entry.key_ptr.*);
            continue;
        };
        const failure: anyerror = blk: {
            const project = project: {
                for (persisted.projects) |candidate| {
                    const id = candidate.id orelse continue;
                    if (std.mem.eql(u8, id, parts.workspace_id)) break :project candidate;
                }
                break :blk error.AdoptionRepairMismatch;
            };
            const thread = thread: {
                for (project.threads orelse &.{}) |candidate| {
                    const id = candidate.local_thread_id orelse continue;
                    if (std.mem.eql(u8, id, parts.local_thread_id)) break :thread candidate;
                }
                break :blk error.AdoptionRepairMismatch;
            };
            // A match error (page load, allocation) counts like any failed
            // validation: propagating it out of the loop skipped this
            // marker's increment and every marker after it, so a single
            // erroring repair could veto refreshes without ever crossing
            // the terminal bound.
            switch (adoptionRefreshTurnMatch(
                self,
                parts.workspace_id,
                parts.local_thread_id,
                parts.turn_id,
                thread,
                entry.value_ptr.rows.items,
            ) catch |err| break :blk err) {
                .unique => {
                    // Durably proven resolved: this key's veto history must
                    // not poison a later, legitimate repair for the same turn.
                    forgetAdoptionVetoHistory(entry.key_ptr.*);
                    continue;
                },
                .missing => break :blk error.AdoptionRepairMismatch,
                // Multiple ordered fingerprint correspondences are not enough
                // to prove identity.
                .ambiguous => break :blk error.AdoptionRepairAmbiguous,
            }
        };
        entry.value_ptr.refresh_validation_failures +|= 1;
        rememberAdoptionVetoHistory(entry.key_ptr.*, entry.value_ptr.refresh_validation_failures);
        if (entry.value_ptr.refresh_validation_failures > ADOPTION_REPAIR_MAX_REFRESH_VETOES) {
            log.warn(
                "dropping unresolvable adoption repair for thread {s} turn {s} after {d} refresh vetoes ({s}): durable projection wins",
                .{ parts.local_thread_id, parts.turn_id, entry.value_ptr.refresh_validation_failures, @errorName(failure) },
            );
            try dropped_keys.append(std.heap.page_allocator, entry.key_ptr.*);
            continue;
        }
        if (veto == null) veto = failure;
    }
    for (dropped_keys.items) |key| {
        const removed = adoption_retry_pending.fetchRemove(key) orelse continue;
        var state = removed.value;
        state.deinit();
        std.heap.page_allocator.free(removed.key);
    }
    if (veto) |err| return err;
}

const AdoptionTurnMatch = enum { missing, unique, ambiguous };

/// Count ordered fingerprint correspondences within one durable turn. Counts
/// saturate at two because the repair only distinguishes unique from ambiguous.
fn adoptionTurnMatch(
    messages: anytype,
    expected_rows: anytype,
    turn_id: []const u8,
) !AdoptionTurnMatch {
    if (expected_rows.len == 0) return .unique;
    const counts = try std.heap.page_allocator.alloc(u8, expected_rows.len + 1);
    defer std.heap.page_allocator.free(counts);
    @memset(counts, 0);
    counts[0] = 1;
    for (messages) |durable| {
        const message_id = durable.message_id orelse continue;
        if (!messageIdBelongsToTurn(message_id, turn_id)) continue;
        var reverse_index = expected_rows.len;
        while (reverse_index > 0) {
            reverse_index -= 1;
            const expected = expected_rows[reverse_index];
            if (durable.role != expected.role or
                !std.mem.eql(u8, durable.author, expected.author) or
                !std.mem.eql(u8, durable.body, expected.body)) continue;
            counts[reverse_index + 1] = @min(
                @as(u8, 2),
                counts[reverse_index + 1] +| counts[reverse_index],
            );
        }
    }
    return switch (counts[expected_rows.len]) {
        0 => .missing,
        1 => .unique,
        else => .ambiguous,
    };
}

/// Tail pages a bounded-thread probe may materialize before giving up. Four
/// pages (1024 rows) is far beyond any single turn's footprint relative to
/// the transcript tail; running out reproduces the pre-existing bounded
/// `.missing` veto rather than introducing a new failure state.
const ADOPTION_VALIDATION_MAX_TAIL_PAGES: usize = 4;

/// Judge one repair's turn correspondence against a refresh snapshot.
/// Bounded durable snapshots (`loadBounded`) carry `messages = &.{}` with
/// `message_offset` holding the full durable row count, so judging `.missing`
/// against that emptiness vetoed every refresh while any marker was pending —
/// a guaranteed veto storm, not evidence of divergence. When rows exist but
/// were not materialized, page the durable tail in from the projection store
/// and judge against real rows instead.
fn adoptionRefreshTurnMatch(
    self: anytype,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    turn_id: []const u8,
    thread: db_types.PersistedThread,
    expected_rows: anytype,
) !AdoptionTurnMatch {
    if (thread.messages.len != 0 or thread.message_offset == 0)
        return adoptionTurnMatch(thread.messages, expected_rows, turn_id);
    if (expected_rows.len == 0) return .unique;
    const allocator = std.heap.page_allocator;
    var pages: [ADOPTION_VALIDATION_MAX_TAIL_PAGES]db_types.LoadedMessagePage = undefined;
    var page_count: usize = 0;
    defer for (pages[0..page_count]) |*page| page.deinit();
    var combined: std.ArrayList(db_types.PersistedMessage) = .empty;
    defer combined.deinit(allocator);
    var before_offset: usize = thread.message_offset;
    while (page_count < pages.len and before_offset > 0) {
        // A store race (thread deleted, DB briefly unavailable) degrades to
        // the same bounded veto path a genuine mismatch takes.
        const page = self.storage.loadMessagePage(
            allocator,
            workspace_id,
            local_thread_id,
            before_offset,
            db_client.TRANSCRIPT_MESSAGE_PAGE_SIZE,
        ) catch return .missing;
        pages[page_count] = page;
        page_count += 1;
        if (page.messages.len == 0 or page.offset >= before_offset) break;
        // Older pages prepend so the accumulated rows keep transcript order
        // for the ordered-correspondence matcher.
        try combined.insertSlice(allocator, 0, page.messages);
        before_offset = page.offset;
        const match = try adoptionTurnMatch(combined.items, expected_rows, turn_id);
        if (match != .missing) return match;
    }
    return .missing;
}

test "turn-scoped adoption matcher retains ambiguous fingerprints" {
    const allocator = std.testing.allocator;
    const expected = AdoptionExpectedRow{
        .row_index_hint = 1,
        .role = .assistant,
        .author = try allocator.dupe(u8, "Codex"),
        .body = try allocator.dupe(u8, "same reply"),
    };
    defer {
        allocator.free(expected.author);
        allocator.free(expected.body);
    }
    const messages = [_]db_types.PersistedMessage{
        .{
            .message_id = "turn:shift:user",
            .role = .user,
            .author = "You",
            .body = "unrelated fingerprint",
        },
        .{
            .message_id = "turn:target:msg:1",
            .role = .assistant,
            .author = "Codex",
            .body = "same reply",
        },
        .{
            .message_id = "turn:target:msg:2",
            .role = .assistant,
            .author = "Codex",
            .body = "same reply",
        },
    };
    const expected_rows = [_]AdoptionExpectedRow{expected};
    try std.testing.expectEqual(
        AdoptionTurnMatch.ambiguous,
        try adoptionTurnMatch(&messages, &expected_rows, "target"),
    );
}

fn messageIdBelongsToTurn(message_id: []const u8, turn_id: []const u8) bool {
    const prefix = "turn:";
    if (!std.mem.startsWith(u8, message_id, prefix)) return false;
    const tail = message_id[prefix.len..];
    return tail.len > turn_id.len and
        std.mem.eql(u8, tail[0..turn_id.len], turn_id) and
        tail[turn_id.len] == ':';
}

fn adoptionRepairSatisfiedByLiveThread(
    workspace_id: []const u8,
    thread: *const ChatThread,
    turn_id: []const u8,
) bool {
    const key = adoptionRetryKeyAlloc(workspace_id, thread.local_thread_id, turn_id) orelse return false;
    defer std.heap.page_allocator.free(key);
    const repair = adoption_retry_pending.get(key) orelse return false;
    const match = adoptionTurnMatch(thread.messages.items, repair.rows.items, turn_id) catch return false;
    return match == .unique;
}

/// Called only after validation, all fallible staging, and the ownership swap.
pub fn clearValidatedAdoptionRepairs(_: anytype) void {
    while (true) {
        var iterator = adoption_retry_pending.iterator();
        const entry = iterator.next() orelse return;
        const removed = adoption_retry_pending.fetchRemove(entry.key_ptr.*) orelse continue;
        var state = removed.value;
        state.deinit();
        std.heap.page_allocator.free(removed.key);
    }
}

pub fn pendingAdoptionRepairsSnapshot(
    _: anytype,
    allocator: std.mem.Allocator,
) ![]const storage_mod.PendingAdoptionRepair {
    const repairs = try allocator.alloc(storage_mod.PendingAdoptionRepair, adoption_retry_pending.count());
    var repair_index: usize = 0;
    var iterator = adoption_retry_pending.iterator();
    while (iterator.next()) |entry| : (repair_index += 1) {
        const parts = adoptionRetryKeyParts(entry.key_ptr.*) orelse return error.InvalidAdoptionRepairKey;
        const rows = try allocator.alloc(storage_mod.PendingAdoptionRow, entry.value_ptr.rows.items.len);
        for (entry.value_ptr.rows.items, rows) |expected, *row| {
            row.* = .{
                .row_index = expected.row_index_hint,
                .role = expected.role,
                .author = try allocator.dupe(u8, expected.author),
                .body = try allocator.dupe(u8, expected.body),
            };
        }
        repairs[repair_index] = .{
            .workspace_id = try allocator.dupe(u8, parts.workspace_id),
            .local_thread_id = try allocator.dupe(u8, parts.local_thread_id),
            .turn_id = try allocator.dupe(u8, parts.turn_id),
            .rows = rows,
        };
    }
    return repairs;
}

pub fn restorePendingAdoptionRepairs(repairs: []const storage_mod.PendingAdoptionRepair) !void {
    for (repairs) |repair| {
        const key = adoptionRetryKeyAlloc(repair.workspace_id, repair.local_thread_id, repair.turn_id) orelse
            return error.OutOfMemory;
        if (adoption_retry_pending.contains(key)) {
            std.heap.page_allocator.free(key);
            continue;
        }
        var key_owned = true;
        errdefer if (key_owned) std.heap.page_allocator.free(key);
        var state: AdoptionRetryState = .{
            .attempts = ADOPTION_RETRY_MAX_ATTEMPTS,
            .next_retry_at_ms = std.math.maxInt(i64),
            .terminal_failed = true,
            .turn_id = try std.heap.page_allocator.dupe(u8, repair.turn_id),
        };
        var state_owned = true;
        errdefer if (state_owned) state.deinit();
        for (repair.rows) |source| {
            var row: AdoptionExpectedRow = .{
                .row_index_hint = source.row_index,
                .role = source.role,
                .author = try std.heap.page_allocator.dupe(u8, source.author),
                .body = undefined,
            };
            var row_owned = true;
            errdefer if (row_owned) std.heap.page_allocator.free(row.author);
            row.body = try std.heap.page_allocator.dupe(u8, source.body);
            errdefer if (row_owned) std.heap.page_allocator.free(row.body);
            try state.rows.append(std.heap.page_allocator, row);
            row_owned = false;
        }
        adoption_retry_pending.put(std.heap.page_allocator, key, state) catch |err| {
            return err;
        };
        key_owned = false;
        state_owned = false;
    }
}

fn deinitAdoptionRepairs() void {
    while (true) {
        var iterator = adoption_retry_pending.iterator();
        const entry = iterator.next() orelse break;
        const removed = adoption_retry_pending.fetchRemove(entry.key_ptr.*) orelse continue;
        var state = removed.value;
        state.deinit();
        std.heap.page_allocator.free(removed.key);
    }
    adoption_retry_pending.deinit(std.heap.page_allocator);
    adoption_retry_pending = .empty;
}

/// Terminal-tick entry: run adoption and queue a retry when incomplete.
/// Never blocks or gates the caller's flush.
fn adoptDaemonTranscriptIdentitiesWithRetry(self: anytype, project_index: usize, thread: *ChatThread, turn_id: []const u8) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const workspace_id = self.project_controller.projects.items[project_index].id;
    switch (adoptDaemonTranscriptIdentities(self, project_index, thread)) {
        .complete => if (adoptionRepairSatisfiedByLiveThread(workspace_id, thread, turn_id))
            clearAdoptionPending(workspace_id, thread.local_thread_id, turn_id),
        // Capture only the rows left id-less by this turn's partial adoption;
        // already-adopted history is outside this marker's correspondence set.
        .incomplete => markAdoptionPending(workspace_id, thread, turn_id),
    }
}

/// M5-P4 Amendment 2: pending-retry thread lookup spanning live threads,
/// archived threads, and archived workspaces (adoption only needs the
/// workspace id and the thread rows, both preserved by archiving).
fn retryAdoptionThreadByLocalId(self: anytype, workspace_id: []const u8, local_thread_id: []const u8) ?*ChatThread {
    for (self.project_controller.projects.items) |*project| {
        if (!std.mem.eql(u8, project.id, workspace_id)) continue;
        for (project.threads.items) |*thread| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return thread;
        }
        for (project.archived_threads.items) |*thread| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return thread;
        }
    }
    for (self.project_controller.archived_projects.items) |*project| {
        if (!std.mem.eql(u8, project.id, workspace_id)) continue;
        for (project.threads.items) |*thread| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return thread;
        }
        for (project.archived_threads.items) |*thread| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return thread;
        }
    }
    return null;
}

/// Retry pump: at most one due adoption per tick (each retry is one local
/// RPC; the interval bounds pressure). Threads that no longer exist drop
/// their entry. Returns whether an adoption completed this tick.
fn retryPendingAdoptions(self: anytype) bool {
    if (adoption_retry_pending.count() == 0) return false;
    const now_ms = sessionizer.nowMs();
    var due_key: ?[]const u8 = null;
    var iterator = adoption_retry_pending.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.terminal_failed) continue;
        if (entry.value_ptr.next_retry_at_ms <= now_ms) {
            due_key = entry.key_ptr.*;
            break;
        }
    }
    const key = due_key orelse return false;
    const parts = adoptionRetryKeyParts(key) orelse {
        if (adoption_retry_pending.fetchRemove(key)) |entry| {
            var state = entry.value;
            state.deinit();
            std.heap.page_allocator.free(entry.key);
        }
        return false;
    };
    // M5-P4 Amendment 2: the lookup must also reach archived threads and
    // archived workspaces — archiving preserves the rows, so dropping the
    // entry here used to leave them id-less forever (permanent duplication
    // once the store belt restored the identity twins on unarchive).
    const thread = retryAdoptionThreadByLocalId(self, parts.workspace_id, parts.local_thread_id) orelse {
        // Thread deleted everywhere (live, archived, archived workspace):
        // nothing left to adopt.
        clearAdoptionPending(parts.workspace_id, parts.local_thread_id, parts.turn_id);
        return false;
    };
    switch (adoptDaemonTranscriptIdentitiesByWorkspaceId(self, parts.workspace_id, thread)) {
        .complete => {
            if (adoptionRepairSatisfiedByLiveThread(parts.workspace_id, thread, parts.turn_id)) {
                clearAdoptionPending(parts.workspace_id, parts.local_thread_id, parts.turn_id);
                return true;
            }
            markAdoptionPending(parts.workspace_id, thread, parts.turn_id);
            return false;
        },
        .incomplete => {
            markAdoptionPending(parts.workspace_id, thread, parts.turn_id);
            return false;
        },
    }
}

test "M4-P5 amendment: incomplete adoption retries to a single identity set" {
    const allocator = std.testing.allocator;
    const AdoptState = struct {
        allocator: std.mem.Allocator,
        dirty: bool = false,
        pub fn markDirty(self: *@This()) void {
            self.dirty = true;
        }
    };
    var state: AdoptState = .{ .allocator = allocator };

    var thread = try ChatThread.init(allocator, "Adoption thread");
    defer thread.deinit(allocator);
    try thread.messages.append(allocator, .{
        .role = .user,
        .author = try allocator.dupeZ(u8, "You"),
        .body = try allocator.dupeZ(u8, "hello m4p5"),
    });
    try thread.messages.append(allocator, .{
        .role = .assistant,
        .author = try allocator.dupeZ(u8, "Assistant"),
        .body = try allocator.dupeZ(u8, "still streaming"),
    });

    var store_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\[{"message_id":"turn:t1:user","role":"user","body":"hello m4p5"},
        \\ {"message_id":"turn:t1:msg:1","role":"assistant","body":"stub-ok"}]
    ,
        .{},
    );
    defer store_parsed.deinit();
    const store_rows = store_parsed.value.array.items;

    // Failed-first adoption: the assistant row mismatches the durable body,
    // so the pass is incomplete — user id adopted, assistant left id-less,
    // and (the old one-shot bug) nothing would ever retry.
    try std.testing.expectEqual(
        AdoptionOutcome.incomplete,
        adoptTranscriptIdentitiesFromStoreMessages(&state, &thread, store_rows),
    );
    try std.testing.expect(state.dirty);
    try std.testing.expectEqualStrings("turn:t1:user", thread.messages.items[0].message_id.?);
    try std.testing.expect(thread.messages.items[1].message_id == null);

    // The projection converges on the durable body; the retry completes and
    // adopts the remaining identity.
    allocator.free(thread.messages.items[1].body);
    thread.messages.items[1].body = try allocator.dupeZ(u8, "stub-ok");
    try std.testing.expectEqual(
        AdoptionOutcome.complete,
        adoptTranscriptIdentitiesFromStoreMessages(&state, &thread, store_rows),
    );
    try std.testing.expectEqualStrings("turn:t1:msg:1", thread.messages.items[1].message_id.?);

    // Idempotent: another pass adopts nothing new, never grows the
    // projection, and keeps exactly one identity per row — the single
    // identity set the flush then persists (no snap-msg duplicates).
    try std.testing.expectEqual(
        AdoptionOutcome.complete,
        adoptTranscriptIdentitiesFromStoreMessages(&state, &thread, store_rows),
    );
    try std.testing.expectEqual(@as(usize, 2), thread.messages.items.len);
    try std.testing.expectEqualStrings("turn:t1:user", thread.messages.items[0].message_id.?);
    try std.testing.expectEqualStrings("turn:t1:msg:1", thread.messages.items[1].message_id.?);

    // Registry mechanics: repeated incomplete outcomes accumulate one entry
    // with a bounded attempt counter; completion clears it.
    markAdoptionPending("ws-adopt-test", &thread, "turn-adopt-test");
    markAdoptionPending("ws-adopt-test", &thread, "turn-adopt-test");
    const key = adoptionRetryKeyAlloc("ws-adopt-test", thread.local_thread_id, "turn-adopt-test").?;
    defer std.heap.page_allocator.free(key);
    try std.testing.expectEqual(@as(u32, 2), adoption_retry_pending.get(key).?.attempts);
    clearAdoptionPending("ws-adopt-test", thread.local_thread_id, "turn-adopt-test");
    try std.testing.expect(adoption_retry_pending.get(key) == null);
}

test "adoption refresh veto count survives clear/re-mint and stays terminal" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Veto thread");
    defer thread.deinit(allocator);
    try thread.messages.append(allocator, .{
        .role = .user,
        .author = try allocator.dupeZ(u8, "You"),
        .body = try allocator.dupeZ(u8, "veto body"),
    });

    // The marker's workspace is absent from every refresh snapshot, so each
    // validation fails — the shape of a projection that never converges.
    const persisted: db_types.PersistedState = .{};
    const TestStorage = struct {
        pub fn loadMessagePage(
            _: *const @This(),
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: usize,
            _: usize,
        ) !db_types.LoadedMessagePage {
            return error.UnexpectedMessagePageLoad;
        }
    };
    var dummy: struct { storage: TestStorage = .{} } = .{};

    markAdoptionPending("ws-veto-test", &thread, "turn-veto-test");
    const key = adoptionRetryKeyAlloc("ws-veto-test", thread.local_thread_id, "turn-veto-test").?;
    defer std.heap.page_allocator.free(key);
    defer clearAdoptionRepairForTest("ws-veto-test", thread.local_thread_id, "turn-veto-test");

    var pass: u32 = 0;
    while (pass < 5) : (pass += 1) {
        try std.testing.expectError(
            error.AdoptionRepairMismatch,
            validateAdoptionRepairsForRefresh(&dummy, persisted),
        );
    }
    try std.testing.expectEqual(@as(u32, 5), adoption_retry_pending.get(key).?.refresh_validation_failures);

    // A clear (a premature completion claim) followed by a re-mint must
    // RESUME the veto count: restarting from zero let one cycling repair
    // freeze projection convergence app-wide forever.
    clearAdoptionPending("ws-veto-test", thread.local_thread_id, "turn-veto-test");
    markAdoptionPending("ws-veto-test", &thread, "turn-veto-test");
    try std.testing.expectEqual(@as(u32, 5), adoption_retry_pending.get(key).?.refresh_validation_failures);

    // The remaining vetoes still fire...
    pass = 0;
    while (pass < ADOPTION_REPAIR_MAX_REFRESH_VETOES - 5) : (pass += 1) {
        try std.testing.expectError(
            error.AdoptionRepairMismatch,
            validateAdoptionRepairsForRefresh(&dummy, persisted),
        );
    }
    // ...and the pass that crosses the bound drops the marker without
    // vetoing: the durable projection wins and the refresh applies.
    try validateAdoptionRepairsForRefresh(&dummy, persisted);
    try std.testing.expect(adoption_retry_pending.get(key) == null);

    // A poisoned re-mint seeds past the bound and can never veto again.
    markAdoptionPending("ws-veto-test", &thread, "turn-veto-test");
    try validateAdoptionRepairsForRefresh(&dummy, persisted);
    try std.testing.expect(adoption_retry_pending.get(key) == null);
}

test "M5-P4 amendment 2: retry pump backs off, reaches archived threads, and gives up loudly" {
    const allocator = std.testing.allocator;
    // Global-registry hygiene: leave nothing behind for other tests.
    defer deinitAdoptionRepairs();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    // Real Storage against a daemon-less tmp pref path: every chat.thread.get
    // the pump issues fails hermetically at connect, exercising the true
    // incomplete → markAdoptionPending path.
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();

    const ProjectStub = struct {
        id: []const u8,
        threads: std.ArrayList(ChatThread) = .empty,
        archived_threads: std.ArrayList(ChatThread) = .empty,
    };
    const PumpState = struct {
        allocator: std.mem.Allocator,
        storage: *const storage_mod.Storage,
        chat_controller: State = .{},
        project_controller: struct {
            projects: std.ArrayList(ProjectStub) = .empty,
            archived_projects: std.ArrayList(ProjectStub) = .empty,
        } = .{},
        pub fn pollTitleGenerations(_: *@This()) bool {
            return false;
        }
        // Never reached (pending_send_count stays 0) but required so the
        // generic pollSend body instantiates against this stub.
        pub fn pollThreadSend(_: *@This(), _: usize, _: usize, _: *ChatThread) bool {
            return false;
        }
        pub fn markDirty(_: *@This()) void {}
    };
    var state: PumpState = .{ .allocator = allocator, .storage = &storage };
    defer {
        for (state.project_controller.projects.items) |*project| {
            for (project.threads.items) |*thread| thread.deinit(allocator);
            for (project.archived_threads.items) |*thread| thread.deinit(allocator);
            project.threads.deinit(allocator);
            project.archived_threads.deinit(allocator);
        }
        for (state.project_controller.archived_projects.items) |*project| {
            for (project.threads.items) |*thread| thread.deinit(allocator);
            for (project.archived_threads.items) |*thread| thread.deinit(allocator);
            project.threads.deinit(allocator);
            project.archived_threads.deinit(allocator);
        }
        state.project_controller.projects.deinit(allocator);
        state.project_controller.archived_projects.deinit(allocator);
    }

    const makeThread = struct {
        fn run(a: std.mem.Allocator, local_id: []const u8) !ChatThread {
            var thread = try ChatThread.init(a, "Retry pump thread");
            a.free(thread.local_thread_id);
            thread.local_thread_id = try a.dupeZ(u8, local_id);
            return thread;
        }
    }.run;

    var live_project: ProjectStub = .{ .id = "retry-ws" };
    try live_project.threads.append(allocator, try makeThread(allocator, "thread-live"));
    try live_project.archived_threads.append(allocator, try makeThread(allocator, "thread-archived"));
    try state.project_controller.projects.append(allocator, live_project);
    var archived_project: ProjectStub = .{ .id = "ws-arch" };
    try archived_project.threads.append(allocator, try makeThread(allocator, "thread-arch-proj"));
    try state.project_controller.archived_projects.append(allocator, archived_project);

    const forceDue = struct {
        fn run(workspace_id: []const u8, local_thread_id: []const u8, turn_id: []const u8) !void {
            const key = adoptionRetryKeyAlloc(workspace_id, local_thread_id, turn_id).?;
            defer std.heap.page_allocator.free(key);
            adoption_retry_pending.getPtr(key).?.next_retry_at_ms = 0;
        }
    }.run;
    const entryState = struct {
        fn run(workspace_id: []const u8, local_thread_id: []const u8, turn_id: []const u8) !?AdoptionRetryState {
            const key = adoptionRetryKeyAlloc(workspace_id, local_thread_id, turn_id).?;
            defer std.heap.page_allocator.free(key);
            return if (adoption_retry_pending.get(key)) |value| value else null;
        }
    }.run;

    // Arm 1 — live thread, growing backoff: each failed pump attempt doubles
    // the next-retry delay (1s base, shift by attempts-1).
    markAdoptionPending("retry-ws", &state.project_controller.projects.items[0].threads.items[0], "turn-live");
    try forceDue("retry-ws", "thread-live", "turn-live");
    try std.testing.expect(!pollSend(&state));
    var pump_entry = (try entryState("retry-ws", "thread-live", "turn-live")).?;
    try std.testing.expectEqual(@as(u32, 2), pump_entry.attempts);
    const after_two = pump_entry.next_retry_at_ms - sessionizer.nowMs();
    try std.testing.expect(after_two > ADOPTION_RETRY_INTERVAL_MS);
    try forceDue("retry-ws", "thread-live", "turn-live");
    _ = pollSend(&state);
    pump_entry = (try entryState("retry-ws", "thread-live", "turn-live")).?;
    try std.testing.expectEqual(@as(u32, 3), pump_entry.attempts);
    const after_three = pump_entry.next_retry_at_ms - sessionizer.nowMs();
    try std.testing.expect(after_three > 2 * ADOPTION_RETRY_INTERVAL_MS);
    clearAdoptionPending("retry-ws", "thread-live", "turn-live");

    // Arm 2 — archived thread in a live workspace: the entry survives the
    // pump (pre-amendment it was dropped as "thread gone").
    markAdoptionPending("retry-ws", &state.project_controller.projects.items[0].archived_threads.items[0], "turn-archived");
    try forceDue("retry-ws", "thread-archived", "turn-archived");
    _ = pollSend(&state);
    try std.testing.expectEqual(@as(u32, 2), ((try entryState("retry-ws", "thread-archived", "turn-archived")).?).attempts);
    clearAdoptionPending("retry-ws", "thread-archived", "turn-archived");

    // Arm 3 — thread inside an archived workspace: also reachable.
    markAdoptionPending("ws-arch", &state.project_controller.archived_projects.items[0].threads.items[0], "turn-arch-proj");
    try forceDue("ws-arch", "thread-arch-proj", "turn-arch-proj");
    _ = pollSend(&state);
    try std.testing.expectEqual(@as(u32, 2), ((try entryState("ws-arch", "thread-arch-proj", "turn-arch-proj")).?).attempts);
    clearAdoptionPending("ws-arch", "thread-arch-proj", "turn-arch-proj");

    // Arm 4 — truly deleted thread: entry dropped (no eternal ghost retries).
    var gone_thread = try makeThread(allocator, "thread-gone");
    defer gone_thread.deinit(allocator);
    markAdoptionPending("retry-ws", &gone_thread, "turn-gone");
    try forceDue("retry-ws", "thread-gone", "turn-gone");
    _ = pollSend(&state);
    try std.testing.expect((try entryState("retry-ws", "thread-gone", "turn-gone")) == null);

    // Arm 5 — loud give-up retains a terminal repair marker. Cursor snapshot
    // application is now the only path allowed to clear the id-less state.
    try state.project_controller.projects.items[0].threads.items[0].messages.append(allocator, .{
        .role = .assistant,
        .author = try allocator.dupeZ(u8, "Codex"),
        .body = try allocator.dupeZ(u8, "awaiting durable identity"),
    });
    markAdoptionPending("retry-ws", &state.project_controller.projects.items[0].threads.items[0], "turn-retry");
    {
        const key = adoptionRetryKeyAlloc("retry-ws", "thread-live", "turn-retry").?;
        defer std.heap.page_allocator.free(key);
        const value_ptr = adoption_retry_pending.getPtr(key).?;
        value_ptr.attempts = ADOPTION_RETRY_MAX_ATTEMPTS - 1;
        value_ptr.next_retry_at_ms = 0;
    }
    _ = pollSend(&state);
    const terminal_entry = (try entryState("retry-ws", "thread-live", "turn-retry")).?;
    try std.testing.expect(terminal_entry.terminal_failed);
    try std.testing.expectEqual(ADOPTION_RETRY_MAX_ATTEMPTS, terminal_entry.attempts);
    try std.testing.expect(hasUnresolvedAdoptionRows(&state));
    state.project_controller.projects.items[0].threads.items[0].messages.items[0].message_id =
        try allocator.dupe(u8, "turn:retry:msg:0");
    try std.testing.expect(hasUnresolvedAdoptionRows(&state));
    clearAdoptionPending("retry-ws", "thread-live", "turn-retry");
    try std.testing.expectEqual(@as(usize, 0), adoption_retry_pending.count());
}

// Records a finished in-app chat turn unless that exact pane currently has
// focus. The independent ledger survives ordinary state saves and process
// restarts until any pane-focus route acknowledges it.
//
// `daemon_owned_completion` (M4-P4 / Q3): when true the daemon already upserted
// `chat_completions` in the turn commit; the GUI never re-writes that row —
// focused clients clear it, unfocused clients only set the in-memory flag so
// the next focus/poll path can clear via the existing storage clear.
pub fn noteChatCompletion(self: anytype, project_index: usize, thread_index: usize, thread: *ChatThread, daemon_owned_completion: bool) void {
    if (self.isChatThreadFocused(project_index, thread_index)) {
        // Focused-clear: storage clear drops the daemon-written row (or a
        // legacy GUI row) within one poll cycle. The daemon-owned path never
        // set the local pending flag, so arm it to pass clearChatCompletion's
        // pending gate (which keeps ordinary focus routes storage-free).
        if (daemon_owned_completion) {
            armFocusedDaemonCompletion(thread, unixTimestampMs());
        }
        _ = self.clearChatCompletion(project_index, thread_index);
        return;
    }
    if (project_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[project_index];
    const completed_at_ms = unixTimestampMs();
    thread.completion_pending = true;
    thread.completed_at_ms = completed_at_ms;
    if (!daemon_owned_completion) {
        // Non-daemon / local paths still own the ledger write.
        self.storage.upsertChatCompletion(.{
            .workspace_id = project.id,
            .local_thread_id = thread.local_thread_id,
            .completed_at_ms = completed_at_ms,
        }) catch |err| {
            log.err("failed to persist chat completion via daemon: {s}", .{@errorName(err)});
        };
    }
    self.markDirty();

    if (!self.app_config.notifications_enabled) return;

    // The pane-less Companion thread cannot be revealed by focusing a chat
    // pane, so its completion copy must name the next action explicitly.
    const is_companion = project.isCompanionThread(thread);
    const title = if (is_companion)
        "Sprout"
    else if (thread.title.len > 0)
        thread.title
    else
        utils.providerLabel(thread.provider);

    const dir = if (project.path.len > 0) std.fs.path.basename(project.path) else "";
    var body_buf: [256]u8 = undefined;
    const body = completionNoticeBody(is_companion, dir, &body_buf);

    const icon: ?notifier.Icon = switch (thread.provider) {
        .codex => .{ .key = "codex", .png_bytes = CODEX_LOGO_BYTES },
        .opencode => .{ .key = "opencode", .png_bytes = OPENCODE_LOGO_BYTES },
        .claude => .{ .key = "claude", .png_bytes = CLAUDE_LOGO_BYTES },
        .cursor => .{ .key = "cursor", .png_bytes = CURSOR_LOGO_BYTES },
        .pi => .{ .key = "pi", .png_bytes = PI_LOGO_BYTES },
        .fx => .{ .key = "fx", .png_bytes = FX_LOGO_BYTES },
        .grok => .{ .key = "grok", .png_bytes = GROK_LOGO_BYTES },
    };
    notifier.notifyAgentDone(self.allocator, title, body, icon);
}

// A focused completion can be observed before the daemon snapshot carrying
// its exact finish time. The observation time is an upper bound that lets the
// acknowledgement suppress that snapshot without covering a later turn.
fn armFocusedDaemonCompletion(thread: anytype, now_ms: i64) void {
    thread.completion_pending = true;
    if (thread.completed_at_ms == 0) thread.completed_at_ms = now_ms;
}

test "focused daemon completion receives a suppression timestamp" {
    const ThreadStub = struct {
        completion_pending: bool = false,
        completed_at_ms: i64 = 0,
    };
    var fresh: ThreadStub = .{};
    armFocusedDaemonCompletion(&fresh, 123);
    try std.testing.expect(fresh.completion_pending);
    try std.testing.expectEqual(@as(i64, 123), fresh.completed_at_ms);

    var projected: ThreadStub = .{ .completed_at_ms = 100 };
    armFocusedDaemonCompletion(&projected, 123);
    try std.testing.expectEqual(@as(i64, 100), projected.completed_at_ms);
}

/// Completion toast copy. Companion completions direct the user to the Sprout
/// panel because no chat pane exists to focus; ordinary threads keep the
/// established "Reply ready" wording.
pub fn completionNoticeBody(is_companion: bool, dir: []const u8, buf: []u8) []const u8 {
    if (is_companion) {
        if (dir.len > 0) {
            return std.fmt.bufPrint(buf, "Sprout finished in {s}. Open the Sprout panel to review the result.", .{dir}) catch
                "Sprout finished. Open the Sprout panel to review the result.";
        }
        return "Sprout finished. Open the Sprout panel to review the result.";
    }
    if (dir.len > 0) return std.fmt.bufPrint(buf, "Reply ready in {s}", .{dir}) catch "Reply ready";
    return "Reply ready";
}

test "completion notice directs Companion completions to the Sprout panel" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Reply ready in verde", completionNoticeBody(false, "verde", &buf));
    try std.testing.expectEqualStrings("Reply ready", completionNoticeBody(false, "", &buf));
    try std.testing.expectEqualStrings(
        "Sprout finished in verde. Open the Sprout panel to review the result.",
        completionNoticeBody(true, "verde", &buf),
    );
    try std.testing.expectEqualStrings(
        "Sprout finished. Open the Sprout panel to review the result.",
        completionNoticeBody(true, "", &buf),
    );
}

// True only when the exact chat pane owns focus in the focused window.
// Merely being visible beside a terminal/browser pane must still queue DONE.
pub fn isChatThreadFocused(self: anytype, project_index: usize, thread_index: usize) bool {
    if (!self.window_input_focus) return false;
    if (project_index != self.project_controller.selected_index) return false;
    if (project_index >= self.project_controller.projects.items.len) return false;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const focused_pane_id = layout.focused_pane_id orelse return false;
    if (layout.maximized_pane_id) |max_id| {
        if (max_id != focused_pane_id) return false;
    }
    const pane = layout.paneById(focused_pane_id) orelse return false;
    return switch (pane.ref) {
        .chat => |ref| ref.thread_index == thread_index,
        else => false,
    };
}

pub fn capturePendingProviderThreadId(self: anytype, thread: *ChatThread) void {
    if (thread.provider_thread_id != null) return;

    const send_state = thread.send_state;
    if (!send_state.mutex.tryLock()) return;
    const thread_id = if (send_state.status == .pending and send_state.provisional_provider_thread_id != null)
        self.allocator.dupeZ(u8, send_state.provisional_provider_thread_id.?) catch null
    else
        null;
    send_state.mutex.unlock();

    thread.provider_thread_id = thread_id orelse return;
    self.markDirty();
    self.flushDirtyNow();
}

pub fn issuePendingThreadStop(self: anytype, project_index: ?usize, project_path: []const u8, thread: *ChatThread) void {
    var provider: Provider = undefined;
    var thread_id: ?[]u8 = null;
    var turn_id: ?[]u8 = null;
    var addressed_started_at_ms: i64 = 0;

    const send_state = thread.send_state;
    if (!send_state.mutex.tryLock()) return;
    if (send_state.status != .pending or !send_state.stop_requested or send_state.stop_signal_sent) {
        send_state.mutex.unlock();
        return;
    }
    if (send_state.daemon_owned) {
        addressed_started_at_ms = send_state.started_at_ms;
        const daemon_turn_id = if (send_state.daemon_turn_id) |id| self.allocator.dupe(u8, id) catch null else null;
        send_state.mutex.unlock();
        const owned_daemon_turn_id = daemon_turn_id orelse {
            send_state.mutex.lock();
            rollbackStopLocked(send_state, "Could not address the running provider turn. Try again.");
            send_state.mutex.unlock();
            return;
        };
        defer self.allocator.free(owned_daemon_turn_id);
        self.cancelDaemonChatTurn(owned_daemon_turn_id) catch |err| {
            log.warn("failed to cancel daemon chat turn: {s}", .{@errorName(err)});
            send_state.mutex.lock();
            if (daemonStopIdentityMatches(send_state, addressed_started_at_ms, owned_daemon_turn_id)) {
                rollbackStopLocked(send_state, "Failed to stop provider reply. Try again.");
            } else {
                setControlFailureLocked(send_state, "The running provider turn changed before stop completed. Try again.");
            }
            send_state.mutex.unlock();
            return;
        };
        send_state.mutex.lock();
        if (!daemonStopIdentityMatches(send_state, addressed_started_at_ms, owned_daemon_turn_id)) {
            setControlFailureLocked(send_state, "The running provider turn changed before stop completed. Try again.");
            send_state.mutex.unlock();
            return;
        }
        clearControlFailureLocked(send_state);
        send_state.stop_signal_sent = true;
        send_state.mutex.unlock();
        return;
    }
    addressed_started_at_ms = send_state.started_at_ms;
    provider = thread.provider;
    const pending_thread_id: ?[]const u8 = if (thread.provider_thread_id) |existing|
        existing
    else if (send_state.provisional_provider_thread_id) |provisional|
        provisional
    else
        null;
    if (pending_thread_id) |resolved_thread_id| {
        if (provider == .opencode or provider == .codex or provider == .claude or send_state.active_turn_id != null) {
            thread_id = self.allocator.dupe(u8, resolved_thread_id) catch null;
            turn_id = if (send_state.active_turn_id) |active_turn_id|
                self.allocator.dupe(u8, active_turn_id) catch null
            else
                null;
        }
    } else if (provider == .claude) {
        // Claude's current interrupt path targets the active bridge
        // process group, so it can still stop a fresh turn before the
        // SDK has emitted a session id.
        thread_id = self.allocator.dupe(u8, "") catch null;
    }
    send_state.mutex.unlock();

    const owned_thread_id = thread_id orelse {
        send_state.mutex.lock();
        rollbackStopLocked(send_state, "Could not address the running provider turn. Try again.");
        send_state.mutex.unlock();
        return;
    };
    defer self.allocator.free(owned_thread_id);
    defer if (turn_id) |owned_turn_id| self.allocator.free(owned_turn_id);

    const execution_target = if (project_index) |index|
        self.providerExecutionTargetForProjectThread(index, thread, 0) orelse {
            send_state.mutex.lock();
            rollbackStopLocked(send_state, "Could not resolve the provider execution target. Try again.");
            send_state.mutex.unlock();
            return;
        }
    else
        ProviderExecutionTarget{ .local = project_path };

    self.interruptThreadViaHarness(execution_target, provider, owned_thread_id, turn_id) catch |err| {
        log.warn("failed to interrupt provider turn: {s}", .{@errorName(err)});
        send_state.mutex.lock();
        if (nonDaemonStopIdentityMatches(thread, send_state, addressed_started_at_ms, owned_thread_id, turn_id)) {
            rollbackStopLocked(send_state, "Failed to stop provider reply. Try again.");
        } else {
            setControlFailureLocked(send_state, "The running provider turn changed before stop completed. Try again.");
        }
        send_state.mutex.unlock();
        self.setSidebarNotice("Failed to stop provider reply.");
        return;
    };
    send_state.mutex.lock();
    if (!nonDaemonStopIdentityMatches(thread, send_state, addressed_started_at_ms, owned_thread_id, turn_id)) {
        setControlFailureLocked(send_state, "The running provider turn changed before stop completed. Try again.");
        send_state.mutex.unlock();
        return;
    }
    clearControlFailureLocked(send_state);
    send_state.stop_signal_sent = true;
    send_state.mutex.unlock();
}

fn setControlFailureLocked(send_state: *SendState, message: []const u8) void {
    const page_alloc = std.heap.page_allocator;
    if (send_state.control_error_message) |old| page_alloc.free(old);
    send_state.control_error_message = page_alloc.dupe(u8, message) catch null;
    send_state.ui_revision +%= 1;
}

fn clearControlFailureLocked(send_state: *SendState) void {
    if (send_state.control_error_message) |old| std.heap.page_allocator.free(old);
    send_state.control_error_message = null;
    send_state.ui_revision +%= 1;
}

fn rollbackStopLocked(send_state: *SendState, message: []const u8) void {
    send_state.stop_requested = false;
    send_state.stop_signal_sent = false;
    setControlFailureLocked(send_state, message);
}

fn daemonStopIdentityMatches(send_state: *const SendState, started_at_ms: i64, turn_id: []const u8) bool {
    return send_state.status == .pending and send_state.daemon_owned and send_state.stop_requested and
        !send_state.stop_signal_sent and send_state.started_at_ms == started_at_ms and
        send_state.daemon_turn_id != null and std.mem.eql(u8, send_state.daemon_turn_id.?, turn_id);
}

fn nonDaemonStopIdentityMatches(
    thread: *const ChatThread,
    send_state: *const SendState,
    started_at_ms: i64,
    thread_id: []const u8,
    turn_id: ?[]const u8,
) bool {
    const current_thread_id: ?[]const u8 = if (thread.provider_thread_id) |existing|
        existing
    else if (send_state.provisional_provider_thread_id) |provisional|
        provisional
    else
        null;
    const same_turn = if (turn_id) |addressed_turn|
        send_state.active_turn_id != null and std.mem.eql(u8, send_state.active_turn_id.?, addressed_turn)
    else
        send_state.active_turn_id == null;
    return send_state.status == .pending and !send_state.daemon_owned and send_state.stop_requested and
        !send_state.stop_signal_sent and send_state.started_at_ms == started_at_ms and current_thread_id != null and
        std.mem.eql(u8, current_thread_id.?, thread_id) and same_turn;
}

pub fn issuePendingProviderSteer(
    self: anytype,
    project_index: usize,
    thread_index: usize,
    thread: *ChatThread,
) void {
    const provider = thread.provider;
    if (provider != .codex and provider != .claude) return;

    var thread_id: ?[]u8 = null;
    var turn_id: ?[]u8 = null;
    var daemon_turn_id: ?[]u8 = null;
    var prompt: ?[]u8 = null;
    var images: std.ArrayList(ChatImageAttachment) = .empty;
    defer {
        for (images.items) |*image| image.deinit(self.allocator);
        images.deinit(self.allocator);
    }

    const send_state = thread.send_state;
    if (!send_state.mutex.tryLock()) return;
    if (pendingProviderSteerCanSignal(send_state)) {
        const pending_thread_id: ?[]const u8 = if (thread.provider_thread_id) |existing|
            existing
        else if (send_state.provisional_provider_thread_id) |provisional|
            provisional
        else
            null;
        if (pending_thread_id) |resolved_thread_id| {
            const resolved_turn_id: ?[]const u8 = switch (provider) {
                .codex => send_state.active_turn_id,
                .claude, .pi => if (send_state.active_turn_id) |active| active else "",
                .opencode, .cursor, .fx, .grok => null,
            };
            if (resolved_turn_id) |active_turn_id| {
                thread_id = self.allocator.dupe(u8, resolved_thread_id) catch null;
                turn_id = self.allocator.dupe(u8, active_turn_id) catch null;
                if ((provider == .codex or provider == .claude) and send_state.daemon_owned) {
                    if (send_state.daemon_turn_id) |daemon_id| {
                        daemon_turn_id = self.allocator.dupe(u8, daemon_id) catch null;
                    }
                }
                prompt = self.allocator.dupe(u8, send_state.pending_followup.?.prompt) catch null;
                copyFollowupImages(
                    self.allocator,
                    &images,
                    send_state.pending_followup.?.images.items,
                ) catch {};
                const daemon_identity_ready = (provider != .codex and provider != .claude) or !send_state.daemon_owned or daemon_turn_id != null;
                send_state.pending_followup_signal_sent = thread_id != null and turn_id != null and prompt != null and daemon_identity_ready and
                    images.items.len == send_state.pending_followup.?.images.items.len;
                if (!send_state.pending_followup_signal_sent) {
                    if (thread_id) |owned_thread_id| {
                        self.allocator.free(owned_thread_id);
                        thread_id = null;
                    }
                    if (turn_id) |owned_turn_id| {
                        self.allocator.free(owned_turn_id);
                        turn_id = null;
                    }
                    if (prompt) |owned_prompt| {
                        self.allocator.free(owned_prompt);
                        prompt = null;
                    }
                    if (daemon_turn_id) |owned_daemon_turn_id| {
                        self.allocator.free(owned_daemon_turn_id);
                        daemon_turn_id = null;
                    }
                }
            }
        }
    }
    send_state.mutex.unlock();

    const owned_thread_id = thread_id orelse return;
    const owned_turn_id = turn_id orelse {
        self.allocator.free(owned_thread_id);
        return;
    };
    const owned_prompt = prompt orelse {
        self.allocator.free(owned_thread_id);
        self.allocator.free(owned_turn_id);
        return;
    };
    defer self.allocator.free(owned_thread_id);
    defer self.allocator.free(owned_turn_id);
    defer self.allocator.free(owned_prompt);
    defer if (daemon_turn_id) |owned_daemon_turn_id| self.allocator.free(owned_daemon_turn_id);

    // Daemon-owned Codex and Claude turns must steer through their owner. This
    // keeps the GUI from opening a second provider client for the same turn.
    const daemon_steer = (provider == .codex or provider == .claude) and daemon_turn_id != null;
    const steer_id = if (daemon_steer)
        std.fmt.allocPrint(self.allocator, "gui-steer:{s}:{d}", .{ daemon_turn_id.?, unixTimestampMs() }) catch null
    else
        null;
    defer if (steer_id) |value| self.allocator.free(value);
    var steer_failure: ?anyerror = null;
    if (daemon_steer and steer_id != null) {
        self.steerDaemonChatTurn(daemon_turn_id.?, steer_id.?, owned_prompt, images.items) catch |err| {
            steer_failure = err;
        };
    } else if (daemon_steer) {
        steer_failure = error.OutOfMemory;
    } else if (self.providerExecutionTargetForProjectThread(project_index, thread, images.items.len)) |execution_target| {
        self.steerThreadViaHarness(execution_target, provider, owned_thread_id, owned_turn_id, owned_prompt, images.items) catch |err| {
            steer_failure = err;
        };
    } else {
        steer_failure = error.UnsupportedExecutionTarget;
    }
    if (steer_failure) |err| {
        send_state.mutex.lock();
        defer send_state.mutex.unlock();
        if (send_state.pending_followup) |*pending_followup| {
            pending_followup.state = .fallback_next_turn;
        }
        send_state.pending_followup_signal_sent = false;
        self.setSidebarNotice(if (provider == .claude)
            "Claude could not steer this turn. It will send after the current reply finishes."
        else switch (err) {
            error.CodexActiveTurnNotSteerable => "Codex could not steer this turn. It will send after the current reply finishes.",
            else => "Failed to send Codex steer. It will send after the current reply finishes.",
        });
        return;
    }

    send_state.mutex.lock();
    if (send_state.pending_followup) |*pending_followup| {
        pending_followup.state = .sent_inline;
    }
    send_state.pending_followup_signal_sent = true;
    // Daemon-owned steering publishes the identified row through tail, which
    // also makes it durable. Harness-owned steering retains the existing local
    // projection path.
    if (!daemon_steer) {
        flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
        const owned_author = std.heap.page_allocator.dupe(u8, "Steering current turn") catch null;
        const owned_body = std.heap.page_allocator.dupe(u8, owned_prompt) catch null;
        if (owned_author) |author| {
            if (owned_body) |body| {
                var event: PendingTimelineEvent = .{
                    .role = .system,
                    .author = author,
                    .body = body,
                };
                copyFollowupImages(std.heap.page_allocator, &event.images, images.items) catch {
                    event.deinit(std.heap.page_allocator);
                    send_state.mutex.unlock();
                    self.setSidebarNotice(if (provider == .claude)
                        "Claude steer sent, but Verde could not display its attachments."
                    else
                        "Codex steer sent, but Verde could not display its attachments.");
                    return;
                };
                send_state.pending_events.append(std.heap.page_allocator, event) catch {
                    event.deinit(std.heap.page_allocator);
                };
            } else {
                std.heap.page_allocator.free(author);
            }
        }
    }
    send_state.mutex.unlock();
    if (project_index == self.project_controller.selected_index and thread_index == self.currentProject().selected_thread_index) {
        self.requestTranscriptScrollToBottom();
    }
    self.setSidebarNotice(if (provider == .claude)
        "Claude steer sent. Waiting for the current turn to update."
    else
        "Codex steer sent. Waiting for the current turn to update.");
}

fn pendingProviderSteerCanSignal(send_state: *const SendState) bool {
    const followup = send_state.pending_followup orelse return false;
    return send_state.status == .pending and
        !send_state.stop_requested and
        send_state.pending_approval == null and
        followup.kind == .steer and
        followup.state == .pending and
        !send_state.pending_followup_signal_sent;
}

test "provider steer polling stops after fallback to next turn or approval wait" {
    const allocator = std.testing.allocator;
    var send_state: SendState = .{
        .status = .pending,
        .pending_followup = .{
            .kind = .steer,
            .prompt = try allocator.dupe(u8, "steer this turn"),
        },
    };
    defer freePendingFollowup(allocator, &send_state.pending_followup);

    try std.testing.expect(pendingProviderSteerCanSignal(&send_state));
    send_state.pending_approval = .{
        .call_id = try allocator.dupe(u8, "call"),
        .title = try allocator.dupe(u8, "Approval"),
        .body = try allocator.dupe(u8, "Wait"),
    };
    try std.testing.expect(!pendingProviderSteerCanSignal(&send_state));
    chat_types.freePendingApproval(allocator, &send_state.pending_approval);
    send_state.pending_followup.?.state = .fallback_next_turn;
    try std.testing.expect(!pendingProviderSteerCanSignal(&send_state));
    send_state.pending_followup.?.state = .sent_inline;
    try std.testing.expect(!pendingProviderSteerCanSignal(&send_state));
}

pub fn dispatchPendingFollowup(self: anytype, project_index: usize, thread_index: usize, thread: *ChatThread) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    const pending = send_state.pending_followup;
    send_state.pending_followup = null;
    send_state.pending_followup_signal_sent = false;
    send_state.stop_requested = false;
    send_state.stop_signal_sent = false;
    send_state.mutex.unlock();

    var followup = pending orelse return;
    defer followup.deinit(self.allocator);

    if (followup.kind == .steer and followup.state == .sent_inline) {
        self.setSidebarNotice(if (thread.provider == .claude) "Claude steer applied." else "Codex steer applied.");
        return;
    }

    const execution_target = self.providerExecutionTargetForProjectThread(project_index, thread, followup.images.items.len) orelse return;

    const first_image: ?*const ChatImageAttachment = if (followup.images.items.len > 0) &followup.images.items[0] else null;
    const extra_images: []const ChatImageAttachment = if (followup.images.items.len > 1) followup.images.items[1..] else &.{};
    self.appendMessageToThread(thread, .user, "You", followup.prompt, first_image, extra_images) catch |err| {
        log.err("failed to append pending follow-up: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to append the pending follow-up.");
        return;
    };
    beginSendForThreadWithImages(self, project_index, thread, followup.prompt, followup.images.items, execution_target) catch |err| {
        log.err("failed to start pending follow-up: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to send the pending follow-up.");
        return;
    };
    if (project_index == self.project_controller.selected_index and thread_index == self.currentProject().selected_thread_index) {
        self.requestTranscriptScrollToBottom();
    }
    self.setSidebarNotice(switch (followup.kind) {
        .queue => "Queued message sent.",
        .steer => if (thread.provider == .claude)
            "Claude follow-up sent as a new turn."
        else
            "Codex follow-up sent as a new turn.",
    });
}

pub fn clearPendingFollowupAfterFailure(self: anytype, thread: *ChatThread) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    freePendingFollowup(self.allocator, &send_state.pending_followup);
    send_state.pending_followup_signal_sent = false;
    send_state.stop_requested = false;
    send_state.stop_signal_sent = false;
}

pub fn finishPickerThread(self: anytype) void {
    self.picker_state.mutex.lock();
    const maybe_worker = self.picker_state.worker;
    self.picker_state.worker = null;
    self.picker_state.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
}

pub fn finishSlashCommandThread(self: anytype) void {
    self.slash_command_state.mutex.lock();
    const maybe_worker = self.slash_command_state.worker;
    self.slash_command_state.worker = null;
    self.slash_command_state.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }

    self.slash_command_state.mutex.lock();
    const maybe_result = self.slash_command_state.result;
    const maybe_error = self.slash_command_state.error_message;
    const maybe_display_name = self.slash_command_state.display_name;
    self.slash_command_state.result = null;
    self.slash_command_state.error_message = null;
    self.slash_command_state.display_name = null;
    self.slash_command_state.started_at_ms = 0;
    self.slash_command_state.status = .idle;
    self.slash_command_state.mutex.unlock();

    if (maybe_result) |result| {
        result.deinit(std.heap.page_allocator);
    }
    if (maybe_error) |message| {
        std.heap.page_allocator.free(message);
    }
    if (maybe_display_name) |name| {
        std.heap.page_allocator.free(name);
    }
}

pub fn finishOpencodeModelCacheThread(self: anytype) void {
    self.provider_controller.opencode_model_cache.mutex.lock();
    const maybe_worker = self.provider_controller.opencode_model_cache.worker;
    self.provider_controller.opencode_model_cache.worker = null;
    const maybe_models = self.provider_controller.opencode_model_cache.models;
    self.provider_controller.opencode_model_cache.models = null;
    self.provider_controller.opencode_model_cache.status = .idle;
    self.provider_controller.opencode_model_cache.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
    if (maybe_models) |models| {
        ai_harness.freeModelInfos(std.heap.page_allocator, models);
    }
}

pub fn finishClaudeModelCacheThread(self: anytype) void {
    self.provider_controller.claude_model_cache.mutex.lock();
    const maybe_worker = self.provider_controller.claude_model_cache.worker;
    self.provider_controller.claude_model_cache.worker = null;
    const maybe_models = self.provider_controller.claude_model_cache.models;
    self.provider_controller.claude_model_cache.models = null;
    self.provider_controller.claude_model_cache.status = .idle;
    self.provider_controller.claude_model_cache.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
    if (maybe_models) |models| {
        ai_harness.freeModelInfos(std.heap.page_allocator, models);
    }
}

pub fn finishPiModelCacheThread(self: anytype) void {
    self.provider_controller.pi_model_cache.mutex.lock();
    const maybe_worker = self.provider_controller.pi_model_cache.worker;
    self.provider_controller.pi_model_cache.worker = null;
    const maybe_models = self.provider_controller.pi_model_cache.models;
    self.provider_controller.pi_model_cache.models = null;
    self.provider_controller.pi_model_cache.status = .idle;
    self.provider_controller.pi_model_cache.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
    if (maybe_models) |models| {
        ai_harness.freeModelInfos(std.heap.page_allocator, models);
    }
}

pub fn finishFxModelCacheThread(self: anytype) void {
    self.provider_controller.fx_model_cache.mutex.lock();
    const maybe_worker = self.provider_controller.fx_model_cache.worker;
    self.provider_controller.fx_model_cache.worker = null;
    const maybe_models = self.provider_controller.fx_model_cache.models;
    self.provider_controller.fx_model_cache.models = null;
    self.provider_controller.fx_model_cache.status = .idle;
    self.provider_controller.fx_model_cache.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
    if (maybe_models) |models| {
        ai_harness.freeModelInfos(std.heap.page_allocator, models);
    }
}

pub fn finishGrokModelCacheThread(self: anytype) void {
    self.provider_controller.grok_model_cache.mutex.lock();
    const maybe_worker = self.provider_controller.grok_model_cache.worker;
    self.provider_controller.grok_model_cache.worker = null;
    const maybe_models = self.provider_controller.grok_model_cache.models;
    self.provider_controller.grok_model_cache.models = null;
    self.provider_controller.grok_model_cache.status = .idle;
    self.provider_controller.grok_model_cache.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
    if (maybe_models) |models| {
        ai_harness.freeModelInfos(std.heap.page_allocator, models);
    }
}

pub fn finishCursorModelCacheThread(self: anytype) void {
    self.provider_controller.cursor_model_cache.mutex.lock();
    const maybe_worker = self.provider_controller.cursor_model_cache.worker;
    self.provider_controller.cursor_model_cache.worker = null;
    const maybe_models = self.provider_controller.cursor_model_cache.models;
    self.provider_controller.cursor_model_cache.models = null;
    self.provider_controller.cursor_model_cache.status = .idle;
    self.provider_controller.cursor_model_cache.mutex.unlock();

    if (maybe_worker) |worker| {
        worker.join();
    }
    if (maybe_models) |models| {
        ai_harness.freeModelInfos(std.heap.page_allocator, models);
    }
}

pub fn finishProviderReadinessThread(self: anytype) void {
    self.provider_controller.readiness.mutex.lock();
    const maybe_worker = self.provider_controller.readiness.worker;
    self.provider_controller.readiness.worker = null;
    self.provider_controller.readiness.mutex.unlock();

    if (maybe_worker) |worker| worker.join();
}

pub fn finishAllSendThreads(self: anytype) void {
    for (self.project_controller.projects.items) |*project| {
        for (project.threads.items) |*thread| {
            thread.finishSendThread();
        }
        for (project.archived_threads.items) |*thread| {
            thread.finishSendThread();
        }
    }
    for (self.project_controller.archived_projects.items) |*project| {
        for (project.threads.items) |*thread| {
            thread.finishSendThread();
        }
        for (project.archived_threads.items) |*thread| {
            thread.finishSendThread();
        }
    }
}

pub fn finishAllTitleGenerationThreads(self: anytype) void {
    for (self.project_controller.projects.items) |*project| {
        for (project.threads.items) |*thread| thread.finishTitleGenerationThread();
        for (project.archived_threads.items) |*thread| thread.finishTitleGenerationThread();
    }
    for (self.project_controller.archived_projects.items) |*project| {
        for (project.threads.items) |*thread| thread.finishTitleGenerationThread();
        for (project.archived_threads.items) |*thread| thread.finishTitleGenerationThread();
    }
}

pub fn prepareThreadSendForShutdown(self: anytype, project_path: []const u8, thread: *ChatThread) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    if (send_state.status != .pending) {
        send_state.mutex.unlock();
        return;
    }
    if (send_state.daemon_owned) {
        const stop_requested = send_state.stop_requested;
        if (stop_requested) {
            runtime_log.diagnostic("shutdown forwarding daemon-owned send stop provider={s} thread_title_len={d}", .{ @tagName(thread.provider), thread.title.len });
        } else {
            runtime_log.diagnostic("shutdown leaving daemon-owned send running provider={s} thread_title_len={d}", .{ @tagName(thread.provider), thread.title.len });
        }
        send_state.mutex.unlock();
        if (stop_requested) self.issuePendingThreadStop(null, project_path, thread);
        return;
    }
    send_state.stop_requested = true;
    send_state.stop_signal_sent = false;
    send_state.approval_decision = .deny;
    send_state.condition.broadcast();
    runtime_log.diagnostic("shutdown requested send stop provider={s} thread_title_len={d}", .{ @tagName(thread.provider), thread.title.len });
    send_state.mutex.unlock();

    self.issuePendingThreadStop(null, project_path, thread);
}

pub fn hasPendingStream(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.currentThread().isSendPendingForUi();
}

pub fn hasAnyPendingSends(self: anytype) bool {
    if (self.chat_controller.hasPending()) return true;
    for (self.project_controller.projects.items) |*project| {
        for (project.threads.items) |*thread| {
            if (thread.isSendPendingForUi()) return true;
        }
        for (project.archived_threads.items) |*thread| {
            if (thread.isSendPendingForUi()) return true;
        }
    }
    for (self.project_controller.archived_projects.items) |*project| {
        for (project.threads.items) |*thread| {
            if (thread.isSendPendingForUi()) return true;
        }
        for (project.archived_threads.items) |*thread| {
            if (thread.isSendPendingForUi()) return true;
        }
    }
    return false;
}

pub fn pendingSendCount(self: anytype) usize {
    return self.chat_controller.pending_send_count;
}

pub fn isPickerPending(self: anytype) bool {
    self.picker_state.mutex.lock();
    defer self.picker_state.mutex.unlock();
    return self.picker_state.status == .pending;
}

pub fn pendingApprovalSnapshot(self: anytype) !?PendingApproval {
    if (self.project_controller.projects.items.len == 0) return null;
    const send_state = self.currentThread().send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    if (send_state.status != .pending) return null;
    const approval = send_state.pending_approval orelse return null;
    return .{
        .call_id = try self.allocator.dupe(u8, approval.call_id),
        .title = try self.allocator.dupe(u8, approval.title),
        .body = try self.allocator.dupe(u8, approval.body),
    };
}

/// Render-thread view of the pending approval, cached like
/// `pendingFollowupSnapshotCached`. Approval content changes always bump the
/// send-state ui_revision (daemon tail apply, local worker), so identity +
/// revision + presence fully key the copy.
pub fn pendingApprovalSnapshotCached(self: anytype) ?*const PendingApproval {
    if (self.project_controller.projects.items.len == 0) return null;
    const send_state = self.currentThread().send_state;
    const cache = &self.pending_ui_snapshot_cache;
    const identity: usize = @intFromPtr(send_state);
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    const revision = send_state.ui_revision;
    const present = send_state.status == .pending and send_state.pending_approval != null;
    const fresh = cache.approval_valid and
        cache.approval_send_state == identity and
        cache.approval_revision == revision and
        (cache.approval != null) == present;
    if (!fresh) {
        if (cache.approval) |*existing| {
            self.allocator.free(existing.call_id);
            self.allocator.free(existing.title);
            self.allocator.free(existing.body);
        }
        cache.approval = null;
        cache.approval_valid = false;
        if (present) {
            const approval = send_state.pending_approval.?;
            const call_id = self.allocator.dupe(u8, approval.call_id) catch return null;
            const title = self.allocator.dupe(u8, approval.title) catch {
                self.allocator.free(call_id);
                return null;
            };
            const body = self.allocator.dupe(u8, approval.body) catch {
                self.allocator.free(call_id);
                self.allocator.free(title);
                return null;
            };
            cache.approval = .{ .call_id = call_id, .title = title, .body = body };
        }
        cache.approval_send_state = identity;
        cache.approval_revision = revision;
        cache.approval_valid = true;
    }
    return if (cache.approval) |*value| value else null;
}

pub fn resolvePendingApproval(self: anytype, decision: ai_harness.ApprovalDecision) void {
    if (self.project_controller.projects.items.len == 0) return;
    _ = resolveThreadPendingApproval(self, self.currentThreadMutable(), decision);
}

pub fn resolveThreadApprovalByLocalId(self: anytype, workspace_id: []const u8, local_thread_id: []const u8, decision: ai_harness.ApprovalDecision) bool {
    const thread = self.threadByLocalId(workspace_id, local_thread_id) orelse return false;
    return resolveThreadPendingApproval(self, thread, decision);
}

fn resolveThreadPendingApproval(self: anytype, thread: *ChatThread, decision: ai_harness.ApprovalDecision) bool {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    const daemon_turn_id = if (send_state.daemon_owned and send_state.daemon_turn_id != null)
        self.allocator.dupe(u8, send_state.daemon_turn_id.?) catch null
    else
        null;
    const call_id = if (send_state.pending_approval) |approval|
        self.allocator.dupe(u8, approval.call_id) catch null
    else
        null;
    if (send_state.pending_approval == null) {
        send_state.mutex.unlock();
        if (daemon_turn_id) |id| self.allocator.free(id);
        if (call_id) |id| self.allocator.free(id);
        return false;
    }
    if (send_state.daemon_owned and (daemon_turn_id == null or call_id == null)) {
        setControlFailureLocked(send_state, "Could not address the pending approval. Try again.");
        send_state.mutex.unlock();
        if (daemon_turn_id) |id| self.allocator.free(id);
        if (call_id) |id| self.allocator.free(id);
        return false;
    }
    if (daemon_turn_id) |turn_id| {
        send_state.mutex.unlock();
        defer self.allocator.free(turn_id);
        const approval_call_id = call_id orelse return false;
        defer self.allocator.free(approval_call_id);
        self.approveDaemonChatTurn(turn_id, approval_call_id, decision) catch |err| {
            log.warn("failed to approve daemon chat turn: {s}", .{@errorName(err)});
            send_state.mutex.lock();
            setControlFailureLocked(send_state, "Failed to send approval decision. Try again.");
            send_state.mutex.unlock();
            return false;
        };
        send_state.mutex.lock();
        const current_approval = send_state.pending_approval orelse {
            setControlFailureLocked(send_state, "The approval changed before the decision completed. Review the current request.");
            send_state.mutex.unlock();
            return false;
        };
        if (!std.mem.eql(u8, current_approval.call_id, approval_call_id)) {
            setControlFailureLocked(send_state, "The approval changed before the decision completed. Review the current request.");
            send_state.mutex.unlock();
            return false;
        }
        clearControlFailureLocked(send_state);
        if (!resolveApprovalLocked(send_state, decision)) {
            setControlFailureLocked(send_state, "The approval is no longer actionable.");
            send_state.mutex.unlock();
            return false;
        }
        send_state.mutex.unlock();
        return true;
    } else if (call_id) |id| {
        clearControlFailureLocked(send_state);
        _ = resolveApprovalLocked(send_state, decision);
        send_state.mutex.unlock();
        self.allocator.free(id);
        return true;
    } else {
        clearControlFailureLocked(send_state);
        _ = resolveApprovalLocked(send_state, decision);
        send_state.mutex.unlock();
        return true;
    }
}

pub fn applySendSuccess(self: anytype, thread: *ChatThread, result: SendResultPayload, append_reply_text: bool) !void {
    if (thread.provider_thread_id) |thread_id| {
        self.allocator.free(thread_id);
    }
    thread.provider_thread_id = try self.allocator.dupeZ(u8, result.provider_thread_id);
    if (!append_reply_text) {
        thread.touch();
        self.markDirty();
        self.setSidebarNotice("Provider session updated.");
        return;
    }
    if (std.mem.trim(u8, result.reply_text, &std.ascii.whitespace).len > 0 and thread.messages.items.len > 0) {
        const last_message = thread.messages.items[thread.messages.items.len - 1];
        if (last_message.role != .assistant or !std.mem.eql(u8, last_message.body, result.reply_text)) {
            try thread.messages.append(self.allocator, .{
                .role = .assistant,
                .author = try self.dupeZ(chat_threads.providerLabel(thread.provider)),
                .body = try self.dupeZ(result.reply_text),
                .image = null,
            });
        }
    } else if (std.mem.trim(u8, result.reply_text, &std.ascii.whitespace).len > 0) {
        try thread.messages.append(self.allocator, .{
            .role = .assistant,
            .author = try self.dupeZ(chat_threads.providerLabel(thread.provider)),
            .body = try self.dupeZ(result.reply_text),
            .image = null,
        });
    }
    thread.touch();
    self.markDirty();
    self.setSidebarNotice("Provider session updated.");
}

pub fn applyPendingTimelineEvents(self: anytype, thread: *ChatThread, events: *std.ArrayListUnmanaged(PendingTimelineEvent)) !void {
    if (events.items.len == 0) return;
    for (events.items) |event| {
        // M5-P4 Amendment 1 (reducer alignment): the daemon reducer commits a
        // system row for EVERY message event — including the codex background
        // snapshot marker and known background-command events — so the local
        // reducer must append the same rows for adoption's role+body row
        // compare to hold across restarts. The GUI-only side effects still
        // run (below); hiding these rows is display-time only, via
        // shouldHideBackgroundTranscriptRow in the transcript renderer.
        if (std.mem.eql(u8, event.author, "__verde_codex_background_snapshot")) {
            try self.reconcileCodexBackgroundSnapshot(thread, event.body);
        }
        try appendPendingTimelineEvent(self, thread, event);
        if (event.role == .system) {
            thread.noteBackgroundTaskEvent(self.allocator, event.author, event.body) catch |err| {
                log.warn("failed to record background task event: {s}", .{@errorName(err)});
            };
            if (ChatThread.isBackgroundCommandEvent(event.author)) {
                if (backgroundTaskForEventBody(thread, event.body)) |task| task.pid_verified = task.task_id != null;
            }
        }
    }
    thread.touch();
    self.markDirty();
}

fn appendPendingTimelineEvent(self: anytype, thread: *ChatThread, event: PendingTimelineEvent) !void {
    const owned_tool_call_id = if (event.tool_call_id) |call_id| try self.allocator.dupe(u8, call_id) else null;
    errdefer if (owned_tool_call_id) |call_id| self.allocator.free(call_id);
    const owned_message_id = if (event.message_id) |id| self.allocator.dupe(u8, id) catch null else null;
    errdefer if (owned_message_id) |id| self.allocator.free(id);
    const first_image: ?*const ChatImageAttachment = if (event.images.items.len > 0) &event.images.items[0] else null;
    const extra_images: []const ChatImageAttachment = if (event.images.items.len > 1) event.images.items[1..] else &.{};
    try self.appendMessageToThread(thread, event.role, event.author, event.body, first_image, extra_images);
    const message = &thread.messages.items[thread.messages.items.len - 1];
    message.transcript_card_started_ms = event.transcript_card_started_ms;
    message.tool_call_id = owned_tool_call_id;
    message.tool_call_kind = event.tool_call_kind;
    message.tool_call_status = event.tool_call_status;
    message.message_id = owned_message_id;
}

pub fn reconcileCodexBackgroundSnapshot(self: anytype, thread: *ChatThread, body: []const u8) !void {
    const provider_thread_id = ChatThread.backgroundTaskMetadataValue(body, "Provider thread ID:") orelse return;
    const now_ms = unixTimestampMs();
    for (thread.background_tasks.items) |*task| {
        if (task.status != .running or task.provider != .codex or task.item_id == null or task.provider_thread_id == null) continue;
        if (!std.mem.eql(u8, task.provider_thread_id.?, provider_thread_id)) continue;
        var present = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const prefix = "Codex item ID:";
            if (std.mem.startsWith(u8, line, prefix) and std.mem.eql(u8, std.mem.trim(u8, line[prefix.len..], " \t"), task.item_id.?)) {
                present = true;
                break;
            }
        }
        if (present) continue;
        task.status = .completed;
        task.updated_at_ms = now_ms;
        const completion_body = try backgroundTaskCompletionBodyAlloc(self.allocator, task);
        defer self.allocator.free(completion_body);
        try self.appendMessageToThread(thread, .system, "Background task completed", completion_body, null, &.{});
    }
}

pub fn applySendFailure(
    self: anytype,
    thread: *ChatThread,
    events: *std.ArrayListUnmanaged(PendingTimelineEvent),
    failure_message: []const u8,
) !void {
    for (events.items) |event| {
        // M5-P4 Amendment 1 (reducer alignment): keep the failure path
        // committing the same rows the daemon reducer journals — the codex
        // background snapshot marker included (hidden at display time).
        try thread.messages.append(self.allocator, .{
            .role = event.role,
            .author = try self.dupeZ(event.author),
            .body = try self.dupeZ(event.body),
            .image = null,
            .tool_call_id = if (event.tool_call_id) |call_id| try self.allocator.dupe(u8, call_id) else null,
            .tool_call_kind = event.tool_call_kind,
            .tool_call_status = event.tool_call_status,
            .message_id = if (event.message_id) |id| self.allocator.dupe(u8, id) catch null else null,
        });
        if (event.role == .system) {
            thread.noteBackgroundTaskEvent(self.allocator, event.author, event.body) catch |err| {
                log.warn("failed to record background task event: {s}", .{@errorName(err)});
            };
            if (ChatThread.isBackgroundCommandEvent(event.author)) {
                if (backgroundTaskForEventBody(thread, event.body)) |task| task.pid_verified = task.task_id != null;
            }
        }
    }
    try thread.messages.append(self.allocator, .{
        .role = .system,
        .author = try self.dupeZ("System"),
        .body = try self.dupeZ(failure_message),
        .image = null,
    });
    thread.touch();
    self.markDirty();
}

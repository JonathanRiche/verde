//! Pi provider harness speaking the pi coding agent's RPC JSONL protocol.
//!
//! Unlike Claude, pi needs no Node bridge: `pi --mode rpc` reads command lines
//! on stdin and emits event lines on stdout natively (LF-delimited JSON
//! objects, one per line). Turns spawn one RPC process each; the session id is
//! pi's session UUID, resumed with `--session-id`.

const std = @import("std");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const MAX_RPC_LINE_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_FILE_BYTES = 16 * 1024 * 1024;
const MAX_SESSION_FILE_BYTES = 64 * 1024 * 1024;
// Only the session header and the first user message are needed for listing.
const SESSION_LIST_HEAD_BYTES = 64 * 1024;
const RPC_STOP_POLL_MS = 20;
const RPC_STEER_RESPONSE_WAIT_MS = 500;
// Bounded deadline for query-only RPC spawns so a wedged pi binary can never
// hang the provider readiness worker (see the OpenCode health-probe incident).
const RPC_QUERY_DEADLINE_MS = 10_000;
const THREAD_TITLE_MAX_BYTES = 80;

const STATE_REQUEST_ID = "state-0";
const PROMPT_REQUEST_ID = "turn-1";
const MODELS_REQUEST_ID = "models-0";
const STEER_REQUEST_ID_PREFIX = "steer-";

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const ActiveTurn = struct {
    child: ?*platform_process.OwnedChild = null,
    thread_id: ?[]u8 = null,
    pending_steer_request_id: ?u64 = null,
    steer_response_request_id: ?u64 = null,
    steer_response_accepted: bool = false,
};

const ActiveProcessState = struct {
    mutex: Mutex = .{},
    turns: std.ArrayListUnmanaged(ActiveTurn) = .empty,
    next_steer_request_id: u64 = 1,
};

var active_process_state: ActiveProcessState = .{};

const StopMonitor = struct {
    request: ?provider_types.SendPromptRequest,
    target: *anyopaque,
    terminate: *const fn (*anyopaque) void,
    finished: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *StopMonitor) !void {
        const request = self.request orelse return;
        if (request.on_should_stop == null) return;
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn finish(self: *StopMonitor) void {
        self.finished.store(true, .release);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn watch(self: *StopMonitor) void {
        const request = self.request orelse return;
        const should_stop = request.on_should_stop orelse return;
        while (!self.finished.load(.acquire)) {
            if (should_stop(request.stream_context)) {
                self.cancelled.store(true, .release);
                self.terminate(self.target);
                return;
            }
            platform_runtime.sleepMillis(RPC_STOP_POLL_MS);
        }
    }
};

// Kills a query-only RPC spawn after a fixed deadline so provider readiness
// checks stay bounded even when the pi binary wedges before producing output.
const QueryDeadline = struct {
    child: *platform_process.OwnedChild,
    deadline_ms: u64 = RPC_QUERY_DEADLINE_MS,
    finished: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *QueryDeadline) !void {
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn finish(self: *QueryDeadline) void {
        self.finished.store(true, .release);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn watch(self: *QueryDeadline) void {
        var waited_ms: u64 = 0;
        while (!self.finished.load(.acquire)) {
            if (waited_ms >= self.deadline_ms) {
                self.expired.store(true, .release);
                self.child.terminateTree();
                return;
            }
            platform_runtime.sleepMillis(RPC_STOP_POLL_MS);
            waited_ms += RPC_STOP_POLL_MS;
        }
    }
};

fn terminateTurnChild(context: *anyopaque) void {
    const child: *platform_process.OwnedChild = @ptrCast(@alignCast(context));
    child.terminateTree();
}

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    // Pi's compaction and session commands are RPC-only for now; no slash
    // commands are surfaced until they get durable Verde semantics.
    return &[_]provider_types.ProviderSlashCommand{};
}

pub const Config = struct {
    executable: []const u8 = "pi",
    cwd: ?[]const u8 = null,
    /// Overrides pi's default `~/.pi/agent/sessions` root (tests only).
    sessions_root: ?[]const u8 = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn slashCommands(self: *Client) []const provider_types.ProviderSlashCommand {
        _ = self;
        return providerSlashCommands();
    }

    pub fn runSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        _ = self;
        _ = allocator;
        _ = request;
        return error.UnsupportedOperation;
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        // pi authenticates per model provider; the configured default model's
        // provider decides whether a turn could run right now.
        var state_response = self.runRpcQuery(
            .{ .id = STATE_REQUEST_ID, .type = "get_state" },
            STATE_REQUEST_ID,
        ) catch return .unknown;
        defer state_response.deinit();
        const data = getObjectField(state_response.value, "data") orelse return .unknown;
        const model = getObjectField(data, "model") orelse return .unknown;
        const model_provider = getOptionalObjectString(model, "provider") orelse return .unknown;

        const status = self.authCheckStatusAlloc(model_provider) catch return .unknown;
        defer self.allocator.free(status);
        if (std.mem.eql(u8, status, "ready")) return .signed_in;
        if (std.mem.eql(u8, status, "not_ready")) return .signed_out;
        return .unknown;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const root_path = self.sessionsRootAlloc() catch
            return allocator.alloc(provider_types.ChatThreadSummary, 0);
        defer self.allocator.free(root_path);

        const Entry = struct { sort_key: []u8, summary: provider_types.ChatThreadSummary };
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |entry| {
                allocator.free(entry.sort_key);
                allocator.free(entry.summary.id);
                allocator.free(entry.summary.title);
            }
            entries.deinit(allocator);
        }

        var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch
            return allocator.alloc(provider_types.ChatThreadSummary, 0);
        defer root_dir.close(io);

        var project_it = root_dir.iterate();
        while (project_it.next(io) catch null) |project_entry| {
            if (project_entry.kind != .directory) continue;
            var project_dir = root_dir.openDir(io, project_entry.name, .{ .iterate = true }) catch continue;
            defer project_dir.close(io);
            var file_it = project_dir.iterate();
            while (file_it.next(io) catch null) |file_entry| {
                if (file_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, file_entry.name, ".jsonl")) continue;
                const head = readFileHeadAlloc(self.allocator, io, project_dir, file_entry.name) catch continue;
                defer self.allocator.free(head);
                var info = sessionHeadInfoAlloc(self.allocator, head) catch continue;
                defer info.deinit(self.allocator);
                if (self.config.cwd) |cwd| {
                    const session_cwd = info.cwd orelse continue;
                    if (!std.mem.eql(u8, session_cwd, cwd)) continue;
                }
                const id = info.id orelse continue;
                const title = info.title orelse id;

                const sort_key = try allocator.dupe(u8, file_entry.name);
                errdefer allocator.free(sort_key);
                const owned_id = try allocator.dupe(u8, id);
                errdefer allocator.free(owned_id);
                const owned_title = try allocator.dupe(u8, title);
                errdefer allocator.free(owned_title);
                try entries.append(allocator, .{
                    .sort_key = sort_key,
                    .summary = .{ .id = owned_id, .title = owned_title },
                });
            }
        }

        // Session file names start with an ISO timestamp, so a descending
        // lexicographic sort yields newest-first.
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                return std.mem.order(u8, lhs.sort_key, rhs.sort_key) == .gt;
            }
        }.lessThan);

        const threads = try allocator.alloc(provider_types.ChatThreadSummary, entries.items.len);
        for (entries.items, 0..) |entry, index| threads[index] = entry.summary;
        for (entries.items) |entry| allocator.free(entry.sort_key);
        entries.clearAndFree(allocator);
        return threads;
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var response = try self.runRpcQuery(
            .{ .id = MODELS_REQUEST_ID, .type = "get_available_models" },
            MODELS_REQUEST_ID,
        );
        defer response.deinit();
        const data = getObjectField(response.value, "data") orelse
            return allocator.alloc(provider_types.ModelInfo, 0);
        return parseModelsValue(allocator, data);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const root_path = try self.sessionsRootAlloc();
        defer self.allocator.free(root_path);

        const session_path = try findSessionFileAlloc(self.allocator, io, root_path, thread_id);
        defer self.allocator.free(session_path);

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, session_path, self.allocator, .limited(MAX_SESSION_FILE_BYTES));
        defer self.allocator.free(bytes);

        return sessionThreadAlloc(allocator, bytes, thread_id);
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const image_paths = try collectImageAttachments(self.allocator, request);
        defer self.allocator.free(image_paths);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();

        const rpc_images = try encodeImagesAlloc(self.allocator, threaded.io(), image_paths);
        defer freeRpcImages(self.allocator, rpc_images);

        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();
        const executable = try process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable);
        defer self.allocator.free(executable);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{ executable, "--mode", "rpc" });
        if (request.thread_id) |thread_id| try argv.appendSlice(self.allocator, &.{ "--session-id", thread_id });
        // "default" defers to pi's own configured model instead of pattern-matching.
        if (request.model) |model| {
            if (!std.mem.eql(u8, model, "default")) {
                try argv.appendSlice(self.allocator, &.{ "--model", model });
            }
        }
        // Verde reasoning efforts are a strict subset of pi thinking levels.
        if (request.reasoning_effort) |effort| try argv.appendSlice(self.allocator, &.{ "--thinking", @tagName(effort) });

        const cwd = request.cwd orelse self.config.cwd;
        runtime_log.diagnostic("pi.sendPrompt spawning cwd={s}", .{cwd orelse "(inherit)"});
        var child = try platform_process.spawn(self.allocator, threaded.io(), .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());
        try registerActiveChild(&child, request.thread_id);
        defer unregisterActiveChild(&child);
        var stop_monitor: StopMonitor = .{
            .request = request,
            .target = &child,
            .terminate = terminateTurnChild,
        };
        try stop_monitor.start();
        defer stop_monitor.finish();

        // get_state is pipelined before the prompt so the daemon learns pi's
        // session UUID (the Verde thread id) before streaming begins.
        try writeJsonLine(self.allocator, child.child.stdin.?, .{ .id = STATE_REQUEST_ID, .type = "get_state" });
        try writeJsonLine(self.allocator, child.child.stdin.?, PromptPayload{
            .id = PROMPT_REQUEST_ID,
            .message = request.prompt,
            .images = rpc_images,
        });

        var turn: TurnState = .{};
        defer turn.deinit(self.allocator);

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.child.stdout.?.reader(threaded.io(), &read_buffer);
        while (true) {
            const maybe_line = takeRpcLineAlloc(self.allocator, &reader.interface) catch |err| {
                if (stop_monitor.cancelled.load(.acquire)) return error.PiTurnInterrupted;
                return err;
            };
            if (maybe_line == null) break;
            defer self.allocator.free(maybe_line.?);
            const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
            if (line.len == 0) continue;
            try self.handleRpcLine(line, request, &child, &turn);
            // agent_settled means no continuations remain; pi then idles
            // awaiting the next command, so the turn ends here.
            if (turn.settled) break;
        }

        // Stop exposing the pointer before wait closes its platform handles.
        unregisterActiveChild(&child);
        if (child.child.stdin) |stdin| {
            stdin.close(threaded.io());
            child.child.stdin = null;
        }
        const term = child.wait(threaded.io()) catch |err| {
            stop_monitor.finish();
            if (stop_monitor.cancelled.load(.acquire)) return error.PiTurnInterrupted;
            return err;
        };
        stop_monitor.finish();
        child.child.stdout = null;
        if (stop_monitor.cancelled.load(.acquire)) return error.PiTurnInterrupted;
        if (turn.error_message) |message| {
            provider_diagnostics.logError(.pi_rpc, null, message);
            if (request.on_failure) |on_failure| {
                on_failure(request.stream_context, message);
            }
            return error.PiRequestFailed;
        }
        switch (term) {
            .exited => |code| if (code != 0) return error.PiRequestFailed,
            else => return error.PiRequestFailed,
        }

        const thread_id = turn.thread_id orelse request.thread_id orelse return error.MissingSessionId;
        runtime_log.diagnostic("pi.sendPrompt completed", .{});
        return .{
            .thread_id = try allocator.dupe(u8, thread_id),
            .reply_text = try allocator.dupe(u8, turn.reply.items),
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        _ = self;
        active_process_state.mutex.lock();
        defer active_process_state.mutex.unlock();
        const index = activeTurnIndexForThreadLocked(request.thread_id) orelse return;
        const child = active_process_state.turns.items[index].child orelse return;
        child.terminateTree();
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        // Encode attachments before taking the registry mutex; file reads are slow.
        const rpc_images = try encodeImagesAlloc(self.allocator, threaded.io(), request.images);
        defer freeRpcImages(self.allocator, rpc_images);

        active_process_state.mutex.lock();
        const turn_index = activeTurnIndexForThreadLocked(request.thread_id) orelse {
            active_process_state.mutex.unlock();
            return error.PiActiveTurnNotSteerable;
        };
        const turn = &active_process_state.turns.items[turn_index];
        const child = turn.child orelse {
            active_process_state.mutex.unlock();
            return error.PiActiveTurnNotSteerable;
        };
        if (turn.pending_steer_request_id != null) {
            active_process_state.mutex.unlock();
            return error.PiSteerAlreadyPending;
        }
        const stdin = child.child.stdin orelse {
            active_process_state.mutex.unlock();
            return error.PiActiveTurnNotSteerable;
        };
        const request_id = active_process_state.next_steer_request_id;
        active_process_state.next_steer_request_id +%= 1;
        if (active_process_state.next_steer_request_id == 0) active_process_state.next_steer_request_id = 1;
        turn.pending_steer_request_id = request_id;
        turn.steer_response_request_id = null;

        var id_buffer: [STEER_REQUEST_ID_PREFIX.len + 20]u8 = undefined;
        const steer_id = std.fmt.bufPrint(&id_buffer, STEER_REQUEST_ID_PREFIX ++ "{d}", .{request_id}) catch unreachable;
        writeJsonLine(self.allocator, stdin, PromptPayload{
            .id = steer_id,
            .message = request.prompt,
            .images = rpc_images,
            .streamingBehavior = "steer",
        }) catch |err| {
            turn.pending_steer_request_id = null;
            active_process_state.mutex.unlock();
            return err;
        };
        active_process_state.mutex.unlock();

        var waited_ms: usize = 0;
        while (waited_ms < RPC_STEER_RESPONSE_WAIT_MS) : (waited_ms += 1) {
            active_process_state.mutex.lock();
            const current_index = activeTurnIndexForChildLocked(child) orelse {
                active_process_state.mutex.unlock();
                return error.PiActiveTurnNotSteerable;
            };
            const current = &active_process_state.turns.items[current_index];
            if (current.steer_response_request_id == request_id) {
                const accepted = current.steer_response_accepted;
                current.pending_steer_request_id = null;
                current.steer_response_request_id = null;
                active_process_state.mutex.unlock();
                if (!accepted) return error.PiActiveTurnNotSteerable;
                return;
            }
            active_process_state.mutex.unlock();
            platform_runtime.sleepMillis(1);
        }

        active_process_state.mutex.lock();
        if (activeTurnIndexForChildLocked(child)) |current_index| {
            const current = &active_process_state.turns.items[current_index];
            if (current.pending_steer_request_id == request_id) current.pending_steer_request_id = null;
        }
        active_process_state.mutex.unlock();
        return error.PiSteerResponseTimeout;
    }

    fn handleRpcLine(
        self: *Client,
        line: []const u8,
        request: provider_types.SendPromptRequest,
        child: ?*platform_process.OwnedChild,
        turn: *TurnState,
    ) !void {
        if (line.len > MAX_RPC_LINE_BYTES) return error.PiMessageTooLarge;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{ .allocate = .alloc_always }) catch {
            // pi may print plain-text startup noise on stdout; ignore it.
            return;
        };
        defer parsed.deinit();
        try self.handleRpcValue(parsed.value, request, child, turn);
    }

    fn handleRpcValue(
        self: *Client,
        root: std.json.Value,
        request: provider_types.SendPromptRequest,
        child: ?*platform_process.OwnedChild,
        turn: *TurnState,
    ) !void {
        const kind = getOptionalObjectString(root, "type") orelse return;
        if (std.mem.eql(u8, kind, "response")) return self.handleRpcResponse(root, request, child, turn);
        if (std.mem.eql(u8, kind, "message_update")) return self.handleMessageUpdate(root, request, turn);
        if (std.mem.eql(u8, kind, "message_end")) return self.handleMessageEnd(root, turn);
        if (std.mem.eql(u8, kind, "tool_execution_start")) return self.handleToolExecutionStart(root, request, turn);
        if (std.mem.eql(u8, kind, "tool_execution_end")) return self.handleToolExecutionEnd(root, request, turn);
        if (std.mem.eql(u8, kind, "agent_settled")) {
            turn.settled = true;
            return;
        }
    }

    fn handleRpcResponse(
        self: *Client,
        root: std.json.Value,
        request: provider_types.SendPromptRequest,
        child: ?*platform_process.OwnedChild,
        turn: *TurnState,
    ) !void {
        const id = getOptionalObjectString(root, "id") orelse return;
        const success = getOptionalObjectBool(root, "success") orelse true;
        if (std.mem.eql(u8, id, STATE_REQUEST_ID)) {
            const data = getObjectField(root, "data") orelse return;
            const session_id = getOptionalObjectString(data, "sessionId") orelse return;
            if (turn.thread_id) |old| self.allocator.free(old);
            turn.thread_id = try self.allocator.dupe(u8, session_id);
            if (child) |active_child| setActiveThreadId(active_child, session_id);
            if (request.on_thread_id) |on_thread_id| {
                on_thread_id(request.stream_context, session_id);
            }
            return;
        }
        if (std.mem.eql(u8, id, PROMPT_REQUEST_ID)) {
            if (!success) {
                const message = getOptionalObjectString(root, "error") orelse "Pi rejected the prompt.";
                try turn.replaceError(self.allocator, message);
            }
            return;
        }
        if (std.mem.startsWith(u8, id, STEER_REQUEST_ID_PREFIX)) {
            const request_id = std.fmt.parseInt(u64, id[STEER_REQUEST_ID_PREFIX.len..], 10) catch return;
            if (child) |active_child| recordSteerResponse(active_child, request_id, success);
            return;
        }
    }

    // pi reports model/auth failures (e.g. an expired OAuth refresh token) as
    // an assistant message_end with stopReason "error" while the prompt
    // response stays success:true, so the turn must fail from the message
    // itself or it would complete as an empty successful reply.
    fn handleMessageEnd(self: *Client, root: std.json.Value, turn: *TurnState) !void {
        const message = getObjectField(root, "message") orelse return;
        const role = getOptionalObjectString(message, "role") orelse return;
        if (!std.mem.eql(u8, role, "assistant")) return;
        const stop_reason = getOptionalObjectString(message, "stopReason") orelse return;
        if (!std.mem.eql(u8, stop_reason, "error")) return;
        const error_message = getOptionalObjectString(message, "errorMessage") orelse "Pi reported a model error.";
        try turn.replaceError(self.allocator, error_message);
    }

    fn handleMessageUpdate(
        self: *Client,
        root: std.json.Value,
        request: provider_types.SendPromptRequest,
        turn: *TurnState,
    ) !void {
        const event = getObjectField(root, "assistantMessageEvent") orelse return;
        const event_kind = getOptionalObjectString(event, "type") orelse return;
        if (std.mem.eql(u8, event_kind, "text_start")) {
            // Blank line between assistant text segments split by tool calls.
            if (turn.reply.items.len > 0) {
                try turn.reply.appendSlice(self.allocator, "\n\n");
                if (request.on_stream_delta) |on_stream_delta| {
                    on_stream_delta(request.stream_context, "\n\n");
                }
            }
            return;
        }
        if (std.mem.eql(u8, event_kind, "text_delta")) {
            const delta = getOptionalObjectString(event, "delta") orelse return;
            try turn.reply.appendSlice(self.allocator, delta);
            if (request.on_stream_delta) |on_stream_delta| {
                on_stream_delta(request.stream_context, delta);
            }
            return;
        }
        // Thinking deltas are not rendered; pi keeps them in its own session.
    }

    fn handleToolExecutionStart(
        self: *Client,
        root: std.json.Value,
        request: provider_types.SendPromptRequest,
        turn: *TurnState,
    ) !void {
        const call_id = getOptionalObjectString(root, "toolCallId") orelse return;
        const tool_name = getOptionalObjectString(root, "toolName") orelse return;
        const args = getObjectField(root, "args");
        if (std.mem.eql(u8, tool_name, "bash")) {
            // Shell executions must render as compact command rows: the exact
            // titles `Ran command` / `Command failed` drive Palette styling.
            const command = if (args) |value| getOptionalObjectString(value, "command") orelse "" else "";
            try turn.rememberBashCommand(self.allocator, call_id, command);
            emitMessageEvent(request, "Ran command", command);
            return;
        }
        var input_json: ?[]u8 = null;
        defer if (input_json) |value| self.allocator.free(value);
        if (args) |value| {
            input_json = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch null;
        }
        emitToolCall(request, .{
            .call_id = call_id,
            .title = tool_name,
            .kind = toolCallKindForName(tool_name),
            .status = .in_progress,
            .input = input_json,
        });
    }

    fn handleToolExecutionEnd(
        self: *Client,
        root: std.json.Value,
        request: provider_types.SendPromptRequest,
        turn: *TurnState,
    ) !void {
        const call_id = getOptionalObjectString(root, "toolCallId") orelse return;
        const is_error = getOptionalObjectBool(root, "isError") orelse false;
        if (turn.takeBashCommand(call_id)) |bash_command| {
            defer {
                self.allocator.free(bash_command.call_id);
                self.allocator.free(bash_command.command);
            }
            if (is_error) emitMessageEvent(request, "Command failed", bash_command.command);
            return;
        }
        const tool_name = getOptionalObjectString(root, "toolName") orelse "";
        const output = toolResultTextAlloc(self.allocator, root) catch null;
        defer if (output) |value| self.allocator.free(value);
        emitToolCall(request, .{
            .call_id = call_id,
            .title = tool_name,
            .kind = toolCallKindForName(tool_name),
            .status = if (is_error) .failed else .completed,
            .output = output,
            .error_text = if (is_error) output else null,
        });
    }

    fn runRpcQuery(self: *Client, payload: anytype, response_id: []const u8) !std.json.Parsed(std.json.Value) {
        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();
        const executable = try process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable);
        defer self.allocator.free(executable);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        // Query spawns stay session-free and offline so they are fast,
        // side-effect free, and never block on network access.
        var child = try platform_process.spawn(self.allocator, threaded.io(), .{
            .argv = &.{ executable, "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--offline" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());
        var deadline: QueryDeadline = .{ .child = &child };
        try deadline.start();
        defer deadline.finish();

        try writeJsonLine(self.allocator, child.child.stdin.?, payload);
        child.child.stdin.?.close(threaded.io());
        child.child.stdin = null;

        var response: ?std.json.Parsed(std.json.Value) = null;
        errdefer if (response) |*value| value.deinit();
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.child.stdout.?.reader(threaded.io(), &read_buffer);
        while (response == null) {
            const maybe_line = takeRpcLineAlloc(self.allocator, &reader.interface) catch break;
            if (maybe_line == null) break;
            defer self.allocator.free(maybe_line.?);
            const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{ .allocate = .alloc_always }) catch continue;
            const id = getOptionalObjectString(parsed.value, "id") orelse {
                parsed.deinit();
                continue;
            };
            const kind = getOptionalObjectString(parsed.value, "type") orelse {
                parsed.deinit();
                continue;
            };
            if (std.mem.eql(u8, id, response_id) and std.mem.eql(u8, kind, "response")) {
                response = parsed;
            } else {
                parsed.deinit();
            }
        }
        _ = child.wait(threaded.io()) catch {};
        // errdefer above releases the parsed response on the timeout path.
        if (deadline.expired.load(.acquire)) return error.PiRequestTimedOut;
        return response orelse error.PiRequestFailed;
    }

    fn authCheckStatusAlloc(self: *Client, model_provider: []const u8) ![]u8 {
        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();
        const executable = try process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable);
        defer self.allocator.free(executable);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        // --no-refresh keeps the check bounded: expired OAuth reads as
        // signed_out instead of blocking the readiness worker on network I/O.
        var child = try platform_process.spawn(self.allocator, threaded.io(), .{
            .argv = &.{ executable, "auth", "check", "--provider", model_provider, "--json", "--no-refresh" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());
        var deadline: QueryDeadline = .{ .child = &child };
        try deadline.start();
        defer deadline.finish();

        var status: ?[]u8 = null;
        errdefer if (status) |value| self.allocator.free(value);
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.child.stdout.?.reader(threaded.io(), &read_buffer);
        while (status == null) {
            const maybe_line = takeRpcLineAlloc(self.allocator, &reader.interface) catch break;
            if (maybe_line == null) break;
            defer self.allocator.free(maybe_line.?);
            const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (getOptionalObjectString(parsed.value, "status")) |value| {
                status = try self.allocator.dupe(u8, value);
            }
        }
        _ = child.wait(threaded.io()) catch {};
        // errdefer above releases the captured status on the timeout path.
        if (deadline.expired.load(.acquire)) return error.PiRequestTimedOut;
        return status orelse error.PiRequestFailed;
    }

    fn sessionsRootAlloc(self: *Client) ![]u8 {
        if (self.config.sessions_root) |root| return self.allocator.dupe(u8, root);
        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();
        const home = env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse return error.MissingHomeDirectory;
        return std.fs.path.join(self.allocator, &.{ home, ".pi", "agent", "sessions" });
    }
};

pub fn shutdownOwnedServer() void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    for (active_process_state.turns.items) |turn| {
        if (turn.child) |child| child.terminateTree();
    }
}

const TurnState = struct {
    reply: std.ArrayListUnmanaged(u8) = .empty,
    thread_id: ?[]u8 = null,
    error_message: ?[]u8 = null,
    settled: bool = false,
    bash_commands: std.ArrayListUnmanaged(BashCommand) = .empty,

    const BashCommand = struct {
        call_id: []u8,
        command: []u8,
    };

    fn deinit(self: *TurnState, allocator: std.mem.Allocator) void {
        self.reply.deinit(allocator);
        if (self.thread_id) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        for (self.bash_commands.items) |entry| {
            allocator.free(entry.call_id);
            allocator.free(entry.command);
        }
        self.bash_commands.deinit(allocator);
        self.* = .{};
    }

    fn replaceError(self: *TurnState, allocator: std.mem.Allocator, message: []const u8) !void {
        const owned = try allocator.dupe(u8, message);
        if (self.error_message) |old| allocator.free(old);
        self.error_message = owned;
    }

    fn rememberBashCommand(self: *TurnState, allocator: std.mem.Allocator, call_id: []const u8, command: []const u8) !void {
        const owned_call_id = try allocator.dupe(u8, call_id);
        errdefer allocator.free(owned_call_id);
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        try self.bash_commands.append(allocator, .{ .call_id = owned_call_id, .command = owned_command });
    }

    /// Removes and returns the tracked bash command; caller frees both slices.
    fn takeBashCommand(self: *TurnState, call_id: []const u8) ?BashCommand {
        for (self.bash_commands.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.call_id, call_id)) {
                return self.bash_commands.swapRemove(index);
            }
        }
        return null;
    }
};

// Field names on the wire structs match pi's RPC JSON schema exactly.
const RpcImage = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
};

const PromptPayload = struct {
    id: []const u8,
    type: []const u8 = "prompt",
    message: []const u8,
    images: []const RpcImage = &.{},
    streamingBehavior: ?[]const u8 = null,
};

fn emitMessageEvent(request: provider_types.SendPromptRequest, title: []const u8, body: []const u8) void {
    const on_stream_event = request.on_stream_event orelse return;
    on_stream_event(request.stream_context, .{ .message = .{ .title = title, .body = body } });
}

fn emitToolCall(request: provider_types.SendPromptRequest, update: provider_types.ToolCallUpdate) void {
    const on_stream_event = request.on_stream_event orelse return;
    on_stream_event(request.stream_context, .{ .tool_call = update });
}

fn toolCallKindForName(tool_name: []const u8) provider_types.ToolCallKind {
    if (provider_types.isSubagentToolName(tool_name)) return .subagent;
    if (std.mem.eql(u8, tool_name, "read")) return .read;
    if (std.mem.eql(u8, tool_name, "edit")) return .edit;
    if (std.mem.eql(u8, tool_name, "write")) return .edit;
    if (std.mem.eql(u8, tool_name, "bash")) return .execute;
    return .other;
}

/// Concatenates `result.content[].text` blocks from a tool_execution_end event.
fn toolResultTextAlloc(allocator: std.mem.Allocator, root: std.json.Value) !?[]u8 {
    const result = getObjectField(root, "result") orelse return null;
    const content = getObjectField(result, "content") orelse return null;
    if (content != .array) return null;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(allocator);
    for (content.array.items) |block| {
        const block_kind = getOptionalObjectString(block, "type") orelse continue;
        if (!std.mem.eql(u8, block_kind, "text")) continue;
        const block_text = getOptionalObjectString(block, "text") orelse continue;
        if (block_text.len == 0) continue;
        if (text.items.len > 0) try text.append(allocator, '\n');
        try text.appendSlice(allocator, block_text);
    }
    if (text.items.len == 0) {
        text.deinit(allocator);
        return null;
    }
    return try text.toOwnedSlice(allocator);
}

fn collectImageAttachments(
    allocator: std.mem.Allocator,
    request: provider_types.SendPromptRequest,
) ![]const provider_types.ImageAttachment {
    const legacy_count: usize = if (request.image) |legacy|
        if (containsImagePath(request.images, legacy.path)) 0 else 1
    else
        0;
    const images = try allocator.alloc(provider_types.ImageAttachment, request.images.len + legacy_count);
    @memcpy(images[0..request.images.len], request.images);
    if (request.image) |legacy| {
        if (legacy_count == 1) images[request.images.len] = legacy;
    }
    return images;
}

fn containsImagePath(images: []const provider_types.ImageAttachment, path: []const u8) bool {
    for (images) |image| {
        if (std.mem.eql(u8, image.path, path)) return true;
    }
    return false;
}

fn imageMimeType(path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    return null;
}

/// Reads and base64-encodes attachments for pi's inline image payloads.
/// Unsupported or unreadable attachments fail the turn visibly instead of
/// being dropped, per the provider contract.
fn encodeImagesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    images: []const provider_types.ImageAttachment,
) ![]RpcImage {
    var encoded: std.ArrayList(RpcImage) = .empty;
    errdefer {
        for (encoded.items) |image| allocator.free(image.data);
        encoded.deinit(allocator);
    }
    for (images) |image| {
        const mime = imageMimeType(image.path) orelse return error.UnsupportedImageType;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, image.path, allocator, .limited(MAX_IMAGE_FILE_BYTES)) catch
            return error.ImageAttachmentUnreadable;
        defer allocator.free(bytes);
        const encoder = std.base64.standard.Encoder;
        const data = try allocator.alloc(u8, encoder.calcSize(bytes.len));
        errdefer allocator.free(data);
        _ = encoder.encode(data, bytes);
        try encoded.append(allocator, .{ .data = data, .mimeType = mime });
    }
    return encoded.toOwnedSlice(allocator);
}

fn freeRpcImages(allocator: std.mem.Allocator, images: []RpcImage) void {
    for (images) |image| allocator.free(image.data);
    allocator.free(images);
}

fn encodeJsonLineAlloc(allocator: std.mem.Allocator, payload: anytype) ![]u8 {
    // Null optionals are omitted: pi treats e.g. `"streamingBehavior":null`
    // as an invalid value rather than an absent field.
    return std.json.Stringify.valueAlloc(allocator, payload, .{ .emit_null_optional_fields = false });
}

fn writeJsonLine(allocator: std.mem.Allocator, file: std.Io.File, payload: anytype) !void {
    const encoded = try encodeJsonLineAlloc(allocator, payload);
    defer allocator.free(encoded);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn takeRpcLineAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    _ = reader.streamDelimiterLimit(&writer.writer, '\n', .limited(MAX_RPC_LINE_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => return error.PiMessageTooLarge,
        else => return err,
    };
    const has_bytes = writer.written().len > 0;
    _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            if (!has_bytes) {
                writer.deinit();
                return null;
            }
        },
        else => return err,
    };
    return try writer.toOwnedSlice();
}

/// Reads up to `SESSION_LIST_HEAD_BYTES` from a session file for listing.
fn readFileHeadAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) ![]u8 {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const head = try allocator.alloc(u8, SESSION_LIST_HEAD_BYTES);
    errdefer allocator.free(head);
    const len = try reader.interface.readSliceShort(head);
    if (allocator.resize(head, len)) return head[0..len];
    const shrunk = try allocator.dupe(u8, head[0..len]);
    allocator.free(head);
    return shrunk;
}

const SessionHeadInfo = struct {
    id: ?[]u8 = null,
    cwd: ?[]u8 = null,
    title: ?[]u8 = null,

    fn deinit(self: *SessionHeadInfo, allocator: std.mem.Allocator) void {
        if (self.id) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        self.* = .{};
    }
};

/// Extracts session id, cwd, and a first-user-message title from the head of
/// a pi session JSONL file. Truncated trailing lines are ignored.
fn sessionHeadInfoAlloc(allocator: std.mem.Allocator, head: []const u8) !SessionHeadInfo {
    var info: SessionHeadInfo = .{};
    errdefer info.deinit(allocator);

    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const kind = getOptionalObjectString(parsed.value, "type") orelse continue;
        if (std.mem.eql(u8, kind, "session")) {
            if (getOptionalObjectString(parsed.value, "id")) |id| {
                if (info.id == null) info.id = try allocator.dupe(u8, id);
            }
            if (getOptionalObjectString(parsed.value, "cwd")) |cwd| {
                if (info.cwd == null) info.cwd = try allocator.dupe(u8, cwd);
            }
            continue;
        }
        if (std.mem.eql(u8, kind, "message") and info.title == null) {
            const message = getObjectField(parsed.value, "message") orelse continue;
            const role = getOptionalObjectString(message, "role") orelse continue;
            if (!std.mem.eql(u8, role, "user")) continue;
            const text = (messageTextAlloc(allocator, message) catch continue) orelse continue;
            defer allocator.free(text);
            info.title = try allocator.dupe(u8, truncateTitle(text));
        }
        if (info.id != null and info.title != null) break;
    }
    return info;
}

/// Concatenates the `text` content blocks of a pi session message.
fn messageTextAlloc(allocator: std.mem.Allocator, message: std.json.Value) !?[]u8 {
    const content = getObjectField(message, "content") orelse return null;
    if (content != .array) return null;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(allocator);
    for (content.array.items) |block| {
        const block_kind = getOptionalObjectString(block, "type") orelse continue;
        if (!std.mem.eql(u8, block_kind, "text")) continue;
        const block_text = getOptionalObjectString(block, "text") orelse continue;
        if (block_text.len == 0) continue;
        if (text.items.len > 0) try text.append(allocator, '\n');
        try text.appendSlice(allocator, block_text);
    }
    if (text.items.len == 0) {
        text.deinit(allocator);
        return null;
    }
    return try text.toOwnedSlice(allocator);
}

/// First line of `text`, clamped to `THREAD_TITLE_MAX_BYTES` at a UTF-8 boundary.
fn truncateTitle(text: []const u8) []const u8 {
    const first_line_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    var end = @min(first_line_end, THREAD_TITLE_MAX_BYTES);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// Locates `<root>/<project>/<timestamp>_<thread_id>.jsonl` for a session UUID.
fn findSessionFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    thread_id: []const u8,
) ![]u8 {
    const suffix = try std.fmt.allocPrint(allocator, "_{s}.jsonl", .{thread_id});
    defer allocator.free(suffix);

    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return error.FileNotFound;
    defer root_dir.close(io);
    var project_it = root_dir.iterate();
    while (project_it.next(io) catch null) |project_entry| {
        if (project_entry.kind != .directory) continue;
        var project_dir = root_dir.openDir(io, project_entry.name, .{ .iterate = true }) catch continue;
        defer project_dir.close(io);
        var file_it = project_dir.iterate();
        while (file_it.next(io) catch null) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, file_entry.name, suffix)) continue;
            return std.fs.path.join(allocator, &.{ root_path, project_entry.name, file_entry.name });
        }
    }
    return error.FileNotFound;
}

/// Builds a `ReadThreadResult` from a full pi session JSONL file.
fn sessionThreadAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    fallback_thread_id: []const u8,
) !provider_types.ReadThreadResult {
    var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
    defer {
        for (messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        messages.deinit(allocator);
    }

    var session_id: ?[]u8 = null;
    errdefer if (session_id) |value| allocator.free(value);
    var title: ?[]u8 = null;
    errdefer if (title) |value| allocator.free(value);
    var model_provider: ?[]u8 = null;
    defer if (model_provider) |value| allocator.free(value);
    var model_id: ?[]u8 = null;
    defer if (model_id) |value| allocator.free(value);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const kind = getOptionalObjectString(parsed.value, "type") orelse continue;
        if (std.mem.eql(u8, kind, "session")) {
            if (getOptionalObjectString(parsed.value, "id")) |id| {
                if (session_id == null) session_id = try allocator.dupe(u8, id);
            }
            continue;
        }
        if (std.mem.eql(u8, kind, "model_change")) {
            const provider_name = getOptionalObjectString(parsed.value, "provider") orelse continue;
            const changed_model = getOptionalObjectString(parsed.value, "modelId") orelse continue;
            if (model_provider) |old| allocator.free(old);
            model_provider = try allocator.dupe(u8, provider_name);
            if (model_id) |old| allocator.free(old);
            model_id = try allocator.dupe(u8, changed_model);
            continue;
        }
        if (std.mem.eql(u8, kind, "message")) {
            const message = getObjectField(parsed.value, "message") orelse continue;
            const role_text = getOptionalObjectString(message, "role") orelse continue;
            const role: provider_types.MessageRole = if (std.mem.eql(u8, role_text, "user"))
                .user
            else if (std.mem.eql(u8, role_text, "assistant"))
                .assistant
            else
                continue;
            const text = (messageTextAlloc(allocator, message) catch continue) orelse continue;
            errdefer allocator.free(text);
            if (role == .user and title == null) {
                title = try allocator.dupe(u8, truncateTitle(text));
            }
            const author = try allocator.dupe(u8, role_text);
            errdefer allocator.free(author);
            try messages.append(allocator, .{ .role = role, .author = author, .body = text });
        }
    }

    const owned_messages = try messages.toOwnedSlice(allocator);
    messages = .empty;
    errdefer {
        for (owned_messages) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        allocator.free(owned_messages);
    }

    const thread_id = session_id orelse try allocator.dupe(u8, fallback_thread_id);
    session_id = null;
    errdefer allocator.free(thread_id);
    const owned_title = title orelse try allocator.dupe(u8, thread_id);
    title = null;
    errdefer allocator.free(owned_title);

    var combined_model: ?[]u8 = null;
    if (model_provider != null and model_id != null) {
        combined_model = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_provider.?, model_id.? });
    }

    return .{
        .thread_id = thread_id,
        .title = owned_title,
        .model_id = combined_model,
        .messages = owned_messages,
    };
}

/// Maps pi's `get_available_models` response `data` into Verde model infos.
/// Model ids use pi's `provider/id` pattern so `--model` selection round-trips.
fn parseModelsValue(allocator: std.mem.Allocator, data: std.json.Value) ![]provider_types.ModelInfo {
    const models_value = getObjectField(data, "models") orelse
        return allocator.alloc(provider_types.ModelInfo, 0);
    if (models_value != .array) return allocator.alloc(provider_types.ModelInfo, 0);

    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    defer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }
    for (models_value.array.items) |model| {
        if (model != .object) continue;
        const id = getOptionalObjectString(model, "id") orelse continue;
        const model_provider = getOptionalObjectString(model, "provider") orelse continue;
        const name = getOptionalObjectString(model, "name") orelse id;
        const reasoning_supported = getOptionalObjectBool(model, "reasoning") orelse false;

        const provider_id = try allocator.dupe(u8, "pi");
        errdefer allocator.free(provider_id);
        const provider_name = try allocator.dupe(u8, "Pi");
        errdefer allocator.free(provider_name);
        const model_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_provider, id });
        errdefer allocator.free(model_id);
        const model_name = try allocator.dupe(u8, name);
        errdefer allocator.free(model_name);
        try models.append(allocator, .{
            .provider_id = provider_id,
            .provider_name = provider_name,
            .model_id = model_id,
            .model_name = model_name,
            .reasoning_supported = reasoning_supported,
        });
    }
    const owned = try models.toOwnedSlice(allocator);
    models = .empty;
    return owned;
}

fn registerActiveChild(child: *platform_process.OwnedChild, thread_id: ?[]const u8) !void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const owned_thread_id = if (thread_id) |value| try std.heap.page_allocator.dupe(u8, value) else null;
    errdefer if (owned_thread_id) |value| std.heap.page_allocator.free(value);
    try active_process_state.turns.append(std.heap.page_allocator, .{
        .child = child,
        .thread_id = owned_thread_id,
    });
}

fn unregisterActiveChild(child: *platform_process.OwnedChild) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const index = activeTurnIndexForChildLocked(child) orelse return;
    const turn = active_process_state.turns.swapRemove(index);
    if (turn.thread_id) |thread_id| std.heap.page_allocator.free(thread_id);
}

fn activeTurnIndexForChildLocked(child: *platform_process.OwnedChild) ?usize {
    for (active_process_state.turns.items, 0..) |turn, index| {
        if (turn.child == child) return index;
    }
    return null;
}

fn activeTurnIndexForThreadLocked(thread_id: []const u8) ?usize {
    for (active_process_state.turns.items, 0..) |turn, index| {
        if (turn.thread_id) |active_thread_id| {
            if (std.mem.eql(u8, active_thread_id, thread_id)) return index;
        }
    }
    return null;
}

fn setActiveThreadId(child: *platform_process.OwnedChild, thread_id: []const u8) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const owned = std.heap.page_allocator.dupe(u8, thread_id) catch return;
    const index = activeTurnIndexForChildLocked(child) orelse {
        std.heap.page_allocator.free(owned);
        return;
    };
    const turn = &active_process_state.turns.items[index];
    if (turn.thread_id) |old| std.heap.page_allocator.free(old);
    turn.thread_id = owned;
}

fn recordSteerResponse(child: *platform_process.OwnedChild, request_id: u64, accepted: bool) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const index = activeTurnIndexForChildLocked(child) orelse return;
    const turn = &active_process_state.turns.items[index];
    if (turn.pending_steer_request_id != request_id) return;
    turn.steer_response_request_id = request_id;
    turn.steer_response_accepted = accepted;
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(field),
        else => null,
    };
}

fn getOptionalObjectString(value: std.json.Value, field: []const u8) ?[]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .string => |text| text,
        else => null,
    };
}

fn getOptionalObjectBool(value: std.json.Value, field: []const u8) ?bool {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .bool => |flag| flag,
        else => null,
    };
}

const PiTestStreamCapture = struct {
    delta_buffer: [512]u8 = undefined,
    delta_len: usize = 0,
    message_title_buffer: [64]u8 = undefined,
    message_title_len: usize = 0,
    message_body_buffer: [256]u8 = undefined,
    message_body_len: usize = 0,
    message_count: usize = 0,
    tool_call_id_buffer: [64]u8 = undefined,
    tool_call_id_len: usize = 0,
    tool_title_buffer: [64]u8 = undefined,
    tool_title_len: usize = 0,
    tool_kind: ?provider_types.ToolCallKind = null,
    tool_status: ?provider_types.ToolCallStatus = null,
    tool_has_input: bool = false,
    tool_has_output: bool = false,
    tool_count: usize = 0,
    thread_id_buffer: [64]u8 = undefined,
    thread_id_len: usize = 0,

    fn copyInto(buffer: []u8, len: *usize, text: []const u8) void {
        const count = @min(buffer.len, text.len);
        @memcpy(buffer[0..count], text[0..count]);
        len.* = count;
    }

    fn appendInto(buffer: []u8, len: *usize, text: []const u8) void {
        const count = @min(buffer.len - len.*, text.len);
        @memcpy(buffer[len.*..][0..count], text[0..count]);
        len.* += count;
    }

    fn onDelta(context: ?*anyopaque, delta: []const u8) void {
        const self: *PiTestStreamCapture = @ptrCast(@alignCast(context orelse return));
        appendInto(&self.delta_buffer, &self.delta_len, delta);
    }

    fn onThreadId(context: ?*anyopaque, thread_id: []const u8) void {
        const self: *PiTestStreamCapture = @ptrCast(@alignCast(context orelse return));
        copyInto(&self.thread_id_buffer, &self.thread_id_len, thread_id);
    }

    fn onStreamEvent(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *PiTestStreamCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .message => |message| {
                copyInto(&self.message_title_buffer, &self.message_title_len, message.title);
                copyInto(&self.message_body_buffer, &self.message_body_len, message.body);
                self.message_count += 1;
            },
            .tool_call => |tool_call| {
                copyInto(&self.tool_call_id_buffer, &self.tool_call_id_len, tool_call.call_id);
                copyInto(&self.tool_title_buffer, &self.tool_title_len, tool_call.title);
                self.tool_kind = tool_call.kind;
                self.tool_status = tool_call.status;
                self.tool_has_input = tool_call.input != null;
                self.tool_has_output = tool_call.output != null;
                self.tool_count += 1;
            },
            else => {},
        }
    }

    fn deltas(self: *const PiTestStreamCapture) []const u8 {
        return self.delta_buffer[0..self.delta_len];
    }

    fn messageTitle(self: *const PiTestStreamCapture) []const u8 {
        return self.message_title_buffer[0..self.message_title_len];
    }

    fn messageBody(self: *const PiTestStreamCapture) []const u8 {
        return self.message_body_buffer[0..self.message_body_len];
    }

    fn toolTitle(self: *const PiTestStreamCapture) []const u8 {
        return self.tool_title_buffer[0..self.tool_title_len];
    }

    fn threadId(self: *const PiTestStreamCapture) []const u8 {
        return self.thread_id_buffer[0..self.thread_id_len];
    }
};

fn testHandleLine(client: *Client, turn: *TurnState, request: provider_types.SendPromptRequest, line: []const u8) !void {
    try client.handleRpcLine(line, request, null, turn);
}

test "pi text deltas accumulate and stream with segment separators" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var turn: TurnState = .{};
    defer turn.deinit(std.testing.allocator);
    var capture: PiTestStreamCapture = .{};
    const request: provider_types.SendPromptRequest = .{
        .prompt = "hi",
        .stream_context = &capture,
        .on_stream_delta = PiTestStreamCapture.onDelta,
    };

    try testHandleLine(&client, &turn, request,
        \\{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
    );
    try testHandleLine(&client, &turn, request,
        \\{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}
    );
    try testHandleLine(&client, &turn, request,
        \\{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"world"}}
    );
    try testHandleLine(&client, &turn, request,
        \\{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":1}}
    );
    try testHandleLine(&client, &turn, request,
        \\{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"again"}}
    );

    try std.testing.expectEqualStrings("Hello world\n\nagain", turn.reply.items);
    try std.testing.expectEqualStrings("Hello world\n\nagain", capture.deltas());
}

test "pi bash tool events author exact command rows" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var turn: TurnState = .{};
    defer turn.deinit(std.testing.allocator);
    var capture: PiTestStreamCapture = .{};
    const request: provider_types.SendPromptRequest = .{
        .prompt = "run it",
        .stream_context = &capture,
        .on_stream_event = PiTestStreamCapture.onStreamEvent,
    };

    try testHandleLine(&client, &turn, request,
        \\{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"ls -la"}}
    );
    try std.testing.expectEqual(@as(usize, 1), capture.message_count);
    try std.testing.expectEqualStrings("Ran command", capture.messageTitle());
    try std.testing.expectEqualStrings("ls -la", capture.messageBody());

    try testHandleLine(&client, &turn, request,
        \\{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"boom"}]},"isError":true}
    );
    try std.testing.expectEqual(@as(usize, 2), capture.message_count);
    try std.testing.expectEqualStrings("Command failed", capture.messageTitle());
    try std.testing.expectEqualStrings("ls -la", capture.messageBody());
    try std.testing.expectEqual(@as(usize, 0), capture.tool_count);
    try std.testing.expectEqual(@as(usize, 0), turn.bash_commands.items.len);
}

test "pi non-bash tools emit tool call lifecycle updates" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var turn: TurnState = .{};
    defer turn.deinit(std.testing.allocator);
    var capture: PiTestStreamCapture = .{};
    const request: provider_types.SendPromptRequest = .{
        .prompt = "read it",
        .stream_context = &capture,
        .on_stream_event = PiTestStreamCapture.onStreamEvent,
    };

    try testHandleLine(&client, &turn, request,
        \\{"type":"tool_execution_start","toolCallId":"call_2","toolName":"read","args":{"path":"/tmp/file"}}
    );
    try std.testing.expectEqual(@as(usize, 1), capture.tool_count);
    try std.testing.expectEqualStrings("read", capture.toolTitle());
    try std.testing.expectEqual(provider_types.ToolCallKind.read, capture.tool_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, capture.tool_status.?);
    try std.testing.expect(capture.tool_has_input);

    try testHandleLine(&client, &turn, request,
        \\{"type":"tool_execution_end","toolCallId":"call_2","toolName":"read","result":{"content":[{"type":"text","text":"contents"}]},"isError":false}
    );
    try std.testing.expectEqual(@as(usize, 2), capture.tool_count);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
    try std.testing.expect(capture.tool_has_output);
    try std.testing.expectEqual(@as(usize, 0), capture.message_count);
}

test "pi get_state response records thread id and prompt failures surface" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var turn: TurnState = .{};
    defer turn.deinit(std.testing.allocator);
    var capture: PiTestStreamCapture = .{};
    const request: provider_types.SendPromptRequest = .{
        .prompt = "hi",
        .stream_context = &capture,
        .on_thread_id = PiTestStreamCapture.onThreadId,
    };

    try testHandleLine(&client, &turn, request,
        \\{"id":"state-0","type":"response","command":"get_state","success":true,"data":{"sessionId":"0123-abcd"}}
    );
    try std.testing.expectEqualStrings("0123-abcd", turn.thread_id.?);
    try std.testing.expectEqualStrings("0123-abcd", capture.threadId());

    try testHandleLine(&client, &turn, request,
        \\{"id":"turn-1","type":"response","command":"prompt","success":false,"error":"no credentials"}
    );
    try std.testing.expectEqualStrings("no credentials", turn.error_message.?);
    try std.testing.expect(!turn.settled);

    try testHandleLine(&client, &turn, request,
        \\{"type":"agent_settled","messages":[]}
    );
    try std.testing.expect(turn.settled);
}

test "pi assistant message_end stopReason error fails the turn" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var turn: TurnState = .{};
    defer turn.deinit(std.testing.allocator);
    var capture: PiTestStreamCapture = .{};
    const request: provider_types.SendPromptRequest = .{
        .prompt = "hi",
        .stream_context = &capture,
    };

    // Observed live against pi 0.84.2: the prompt response succeeds, then the
    // provider error only surfaces on the assistant message_end.
    try testHandleLine(&client, &turn, request,
        \\{"id":"turn-1","type":"response","command":"prompt","success":true}
    );
    try std.testing.expect(turn.error_message == null);

    // User-echo message_end must not record an error.
    try testHandleLine(&client, &turn, request,
        \\{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
    );
    try std.testing.expect(turn.error_message == null);

    try testHandleLine(&client, &turn, request,
        \\{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"OAuth refresh failed for openai-codex"}}
    );
    try std.testing.expectEqualStrings("OAuth refresh failed for openai-codex", turn.error_message.?);

    try testHandleLine(&client, &turn, request,
        \\{"type":"agent_settled","messages":[]}
    );
    try std.testing.expect(turn.settled);
}

test "pi prompt payload serializes images and omits null steering" {
    const images = [_]RpcImage{.{ .data = "aGVsbG8=", .mimeType = "image/png" }};
    const encoded = try encodeJsonLineAlloc(std.testing.allocator, PromptPayload{
        .id = PROMPT_REQUEST_ID,
        .message = "describe",
        .images = images[0..],
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"mimeType\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "aGVsbG8=") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "streamingBehavior") == null);

    const steer_encoded = try encodeJsonLineAlloc(std.testing.allocator, PromptPayload{
        .id = "steer-7",
        .message = "focus",
        .streamingBehavior = "steer",
    });
    defer std.testing.allocator.free(steer_encoded);
    try std.testing.expect(std.mem.indexOf(u8, steer_encoded, "\"streamingBehavior\":\"steer\"") != null);
}

test "pi image mime types map by extension and reject unknowns" {
    try std.testing.expectEqualStrings("image/png", imageMimeType("/tmp/shot.PNG").?);
    try std.testing.expectEqualStrings("image/jpeg", imageMimeType("/tmp/photo.jpeg").?);
    try std.testing.expectEqualStrings("image/webp", imageMimeType("/tmp/pic.webp").?);
    try std.testing.expectEqual(@as(?[]const u8, null), imageMimeType("/tmp/document.pdf"));
    try std.testing.expectEqual(@as(?[]const u8, null), imageMimeType("/tmp/no_extension"));
}

test "pi collectImageAttachments preserves multi-image and legacy compatibility" {
    const modern = [_]provider_types.ImageAttachment{
        .{ .path = "/tmp/one.png" },
        .{ .path = "/tmp/two.png" },
    };
    const collected = try collectImageAttachments(std.testing.allocator, .{
        .prompt = "hello",
        .image = .{ .path = "/tmp/legacy.png" },
        .images = modern[0..],
    });
    defer std.testing.allocator.free(collected);

    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqualStrings("/tmp/one.png", collected[0].path);
    try std.testing.expectEqualStrings("/tmp/two.png", collected[1].path);
    try std.testing.expectEqualStrings("/tmp/legacy.png", collected[2].path);
}

test "pi session head info extracts id, cwd, and first user title" {
    const head =
        \\{"type":"session","version":3,"id":"019e-uuid","timestamp":"2026-05-21T02:41:49.420Z","cwd":"/home/user/project"}
        \\{"type":"model_change","provider":"google","modelId":"gemini-3-pro"}
        \\{"type":"message","message":{"role":"user","content":[{"type":"text","text":"fix the resize bug\nplease"}]}}
    ;
    var info = try sessionHeadInfoAlloc(std.testing.allocator, head);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("019e-uuid", info.id.?);
    try std.testing.expectEqualStrings("/home/user/project", info.cwd.?);
    try std.testing.expectEqualStrings("fix the resize bug", info.title.?);
}

test "pi session thread parses messages, title, and model" {
    const session =
        \\{"type":"session","version":3,"id":"019e-uuid","timestamp":"2026-05-21T02:41:49.420Z","cwd":"/home/user/project"}
        \\{"type":"model_change","provider":"google","modelId":"gemini-3-pro"}
        \\{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello there"}]}}
        \\{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"hi!"}]}}
        \\{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"ignored"}]}}
        \\{"type":"model_change","provider":"anthropic","modelId":"claude-x"}
    ;
    const result = try sessionThreadAlloc(std.testing.allocator, session, "fallback");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("019e-uuid", result.thread_id);
    try std.testing.expectEqualStrings("hello there", result.title);
    try std.testing.expectEqualStrings("anthropic/claude-x", result.model_id.?);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expectEqual(provider_types.MessageRole.user, result.messages[0].role);
    try std.testing.expectEqualStrings("hello there", result.messages[0].body);
    try std.testing.expectEqual(provider_types.MessageRole.assistant, result.messages[1].role);
    try std.testing.expectEqualStrings("hi!", result.messages[1].body);
}

test "pi model listing maps provider/id pairs and reasoning" {
    const payload =
        \\{"models":[{"id":"gemini-3-flash","name":"Gemini 3 Flash","provider":"google","reasoning":true},{"id":"basic","name":"Basic","provider":"openai","reasoning":false},{"bad":"entry"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const models = try parseModelsValue(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("pi", models[0].provider_id);
    try std.testing.expectEqualStrings("Pi", models[0].provider_name);
    try std.testing.expectEqualStrings("google/gemini-3-flash", models[0].model_id);
    try std.testing.expectEqualStrings("Gemini 3 Flash", models[0].model_name);
    try std.testing.expect(models[0].reasoning_supported);
    try std.testing.expectEqualStrings("openai/basic", models[1].model_id);
    try std.testing.expect(!models[1].reasoning_supported);
}

test "pi title truncation respects UTF-8 boundaries" {
    try std.testing.expectEqualStrings("short", truncateTitle("short"));
    try std.testing.expectEqualStrings("first", truncateTitle("first\nsecond"));
    // 79 ASCII bytes then a two-byte codepoint straddling the 80-byte cap.
    const long = "a" ** 79 ++ "é" ++ "tail";
    const truncated = truncateTitle(long);
    try std.testing.expectEqual(@as(usize, 79), truncated.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
}

test "pi tool kinds map builtin tool names" {
    try std.testing.expectEqual(provider_types.ToolCallKind.read, toolCallKindForName("read"));
    try std.testing.expectEqual(provider_types.ToolCallKind.edit, toolCallKindForName("edit"));
    try std.testing.expectEqual(provider_types.ToolCallKind.edit, toolCallKindForName("write"));
    try std.testing.expectEqual(provider_types.ToolCallKind.execute, toolCallKindForName("bash"));
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, toolCallKindForName("TaskExecute"));
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, toolCallKindForName("Agent"));
    try std.testing.expectEqual(provider_types.ToolCallKind.other, toolCallKindForName("custom_tool"));
}

test "pi rpc reader accepts lines larger than its scratch buffer" {
    const line_len = 20 * 1024;
    const input = try std.testing.allocator.alloc(u8, line_len + 4);
    defer std.testing.allocator.free(input);
    @memset(input[0..line_len], 'x');
    @memcpy(input[line_len..], "\nok\n");

    var reader = std.Io.Reader.fixed(input);
    const first = (try takeRpcLineAlloc(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(line_len, first.len);

    const second = (try takeRpcLineAlloc(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("ok", second);
    try std.testing.expectEqual(@as(?[]u8, null), try takeRpcLineAlloc(std.testing.allocator, &reader));
}

test "pi non-JSON stdout lines are ignored" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var turn: TurnState = .{};
    defer turn.deinit(std.testing.allocator);
    const request: provider_types.SendPromptRequest = .{ .prompt = "hi" };

    try testHandleLine(&client, &turn, request, "pi startup banner: not json");
    try std.testing.expect(turn.error_message == null);
    try std.testing.expect(!turn.settled);
}

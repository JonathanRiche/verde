//! OpenCode provider harness backed by the local HTTP server.

const std = @import("std");
const builtin = @import("builtin");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");

const log = std.log.scoped(.native_opencode);

const MAX_HTTP_BODY_BYTES = 8 * 1024 * 1024;
const MAX_HEALTH_WAIT_ATTEMPTS = 30;
const DEFAULT_BASE_URL = "http://127.0.0.1:4096";
const MESSAGE_POLL_LIMIT = 12;
const IMPORT_MESSAGE_LIMIT = 100_000;
const POLL_INTERVAL_MS: u64 = 150;
const MAX_POLL_ATTEMPTS = 24_000;
const EMPTY_IDLE_GRACE_POLLS: usize = 16;

fn sleepMs(ms: u64) void {
    const request: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&request, null);
}

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const Condition = struct {
    fn wait(_: *Condition, mutex: *Mutex) void {
        mutex.unlock();
        std.atomic.spinLoopHint();
        mutex.lock();
    }

    fn broadcast(_: *Condition) void {}
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    executable: []const u8 = "opencode",
    base_url: []const u8 = DEFAULT_BASE_URL,
    working_directory: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    launch_if_missing: bool = false,
};

const SharedServerState = struct {
    mutex: Mutex = .{},
    child: ?std.process.Child = null,
    owns_child: bool = false,
};

var shared_server_state: SharedServerState = .{};

/// When `VERDE_DUMP_OPENCODE_PROVIDERS` is set to a non-empty value other than `0`, writes the raw
/// JSON body from `GET /config/providers` to disk for inspection (reasoning/thinking fields, variants, etc.).
/// Override path with `VERDE_DUMP_OPENCODE_PROVIDERS_PATH` (absolute recommended on Unix: `/tmp/...`).
fn maybeDumpOpencodeProvidersConfig(body: []const u8) void {
    const flag_z = std.c.getenv("VERDE_DUMP_OPENCODE_PROVIDERS") orelse return;
    const flag = std.mem.sliceTo(flag_z, 0);
    if (flag.len == 0 or std.mem.eql(u8, flag, "0")) return;

    const default_path: []const u8 = switch (builtin.os.tag) {
        .windows => "verde-opencode-config-providers.json",
        else => "/tmp/verde-opencode-config-providers.json",
    };
    const path = if (std.c.getenv("VERDE_DUMP_OPENCODE_PROVIDERS_PATH")) |p|
        std.mem.sliceTo(p, 0)
    else
        default_path;

    var threaded = std.Io.Threaded.init_single_threaded;
    var file = std.Io.Dir.createFileAbsolute(threaded.io(), path, .{ .truncate = true }) catch |err| {
        log.warn("VERDE_DUMP_OPENCODE_PROVIDERS: create {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    defer file.close(threaded.io());
    file.writeStreamingAll(threaded.io(), body) catch |err| {
        log.warn("VERDE_DUMP_OPENCODE_PROVIDERS: write {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    log.info("VERDE_DUMP_OPENCODE_PROVIDERS: wrote {d} bytes to {s}", .{ body.len, path });
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        var client: Client = .{
            .allocator = allocator,
            .config = config,
        };
        try client.ensureServer();
        return client;
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        const response = try self.requestJson(.GET, "/provider", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const connected = getObjectField(parsed.value, "connected") orelse return .unknown;
        return switch (connected) {
            .array => |items| if (items.items.len > 0) .signed_in else .signed_out,
            else => .unknown,
        };
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        const response = try self.requestJson(.GET, "/session", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        if (parsed.value != .array) {
            return allocator.alloc(provider_types.ChatThreadSummary, 0);
        }

        var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
        defer threads.deinit(allocator);
        var saw_directory = false;

        for (parsed.value.array.items) |session_value| {
            if (session_value != .object) continue;
            const directory = getOptionalObjectString(session_value, "directory");
            if (directory != null) saw_directory = true;
            if (!sessionMatchesWorkingDirectory(self.config.working_directory, directory)) continue;

            const id = getOptionalObjectString(session_value, "id") orelse continue;
            const title = getOptionalObjectString(session_value, "title") orelse id;
            try threads.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .title = try allocator.dupe(u8, title),
            });
        }

        if (threads.items.len == 0 and self.config.working_directory != null and saw_directory) {
            return allocator.alloc(provider_types.ChatThreadSummary, 0);
        }

        return threads.toOwnedSlice(allocator);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        const response = try self.requestJson(.GET, "/config/providers", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        maybeDumpOpencodeProvidersConfig(response.body);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        return parseConfiguredModelsAlloc(allocator, parsed.value);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        const session_response = try self.requestJson(.GET, "/session", null);
        defer self.allocator.free(session_response.body);
        if (session_response.status != .ok) return error.OpencodeRequestFailed;

        var parsed_sessions = try std.json.parseFromSlice(std.json.Value, self.allocator, session_response.body, .{});
        defer parsed_sessions.deinit();

        const session_value = findSessionById(parsed_sessions.value, thread_id) orelse return error.MissingSessionId;
        const session_id = getOptionalObjectString(session_value, "id") orelse return error.MissingSessionId;
        const session_title = getOptionalObjectString(session_value, "title") orelse session_id;

        const messages_path = try std.fmt.allocPrint(
            self.allocator,
            "/session/{s}/message?limit={d}",
            .{ session_id, IMPORT_MESSAGE_LIMIT },
        );
        defer self.allocator.free(messages_path);

        const messages_response = try self.requestJson(.GET, messages_path, null);
        defer self.allocator.free(messages_response.body);
        if (messages_response.status != .ok) return error.OpencodeRequestFailed;

        var parsed_messages = try std.json.parseFromSlice(std.json.Value, self.allocator, messages_response.body, .{});
        defer parsed_messages.deinit();

        const imported_messages = try parseImportedApiMessagesAlloc(allocator, parsed_messages.value);

        return .{
            .thread_id = try allocator.dupe(u8, session_id),
            .title = try allocator.dupe(u8, session_title),
            .updated_at = extractSessionUpdatedAt(session_value),
            .messages = imported_messages,
        };
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const session_id = if (request.thread_id) |existing|
            try allocator.dupe(u8, existing)
        else
            try self.createSession(allocator, request.thread_title);
        errdefer allocator.free(session_id);

        if (request.on_thread_id) |on_thread_id| {
            on_thread_id(request.stream_context, session_id);
        }

        if (request.thread_title) |thread_title| {
            try self.ensureSessionTitle(session_id, thread_title);
        }

        var baseline = try self.fetchLatestAssistantSnapshot(allocator, session_id, null);
        defer baseline.deinit(allocator);
        const baseline_diff_payload = try self.fetchSessionDiffPayloadAlloc(session_id);
        defer self.allocator.free(baseline_diff_payload);

        const event_stream = startEventStream(self, allocator, session_id, baseline.message_id, request) catch |err| blk: {
            log.warn("failed to start OpenCode event stream: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (event_stream) |handle| signalEventStreamStop(handle);

        try self.startPromptAsync(session_id, request);

        const reply_text = try self.waitForPromptResult(
            allocator,
            session_id,
            baseline.message_id,
            baseline_diff_payload,
            request,
            if (event_stream) |handle| handle.context else null,
        );
        errdefer allocator.free(reply_text);

        return .{
            .thread_id = session_id,
            .reply_text = reply_text,
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/abort", .{request.thread_id});
        defer self.allocator.free(path);

        const response = try self.requestJson(.POST, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn ensureServer(self: *Client) !void {
        if (self.checkHealth()) {
            return;
        }

        if (!self.config.launch_if_missing) {
            return error.OpencodeServerUnavailable;
        }

        shared_server_state.mutex.lock();
        defer shared_server_state.mutex.unlock();

        if (self.checkHealth()) {
            return;
        }

        if (shared_server_state.owns_child) {
            if (self.waitForHealth(MAX_HEALTH_WAIT_ATTEMPTS)) {
                return;
            }
            stopOwnedServerLocked();
            if (self.checkHealth()) {
                return;
            }
        }

        try self.spawnServer();
        if (self.waitForHealth(MAX_HEALTH_WAIT_ATTEMPTS)) {
            return;
        }

        stopOwnedServerLocked();
        return error.OpencodeServerUnavailable;
    }

    fn checkHealth(self: *Client) bool {
        const result = self.requestJson(.GET, "/global/health", null);
        if (result) |response| {
            defer self.allocator.free(response.body);
            return response.status == .ok;
        } else |_| {
            return false;
        }
    }

    fn waitForHealth(self: *Client, attempts: usize) bool {
        var attempt: usize = 0;
        while (attempt < attempts) : (attempt += 1) {
            if (self.checkHealth()) {
                return true;
            }
            sleepMs(100);
        }
        return false;
    }

    fn spawnServer(self: *Client) !void {
        if (shared_server_state.child != null) return;

        const uri = try std.Uri.parse(self.config.base_url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
            return error.UnsupportedOpencodeScheme;
        }

        const host = try uri.getHostAlloc(self.allocator);

        const port = uri.port orelse 4096;
        const port_text = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_text);

        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();

        const executable = try process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable);
        defer self.allocator.free(executable);

        var argv = [_][]const u8{
            executable,
            "serve",
            "--hostname",
            host.bytes,
            "--port",
            port_text,
        };

        var threaded_spawn = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded_spawn.deinit();
        const child = try std.process.spawn(threaded_spawn.io(), .{
            .argv = argv[0..],
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
            .cwd = if (self.config.working_directory) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });

        shared_server_state.child = child;
        shared_server_state.owns_child = true;
    }

    fn createSession(self: *Client, allocator: std.mem.Allocator, title: ?[]const u8) ![]u8 {
        const body = try stringifyAlloc(self.allocator, .{
            .title = title orelse "Verde",
        });
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, "/session", body);
        defer self.allocator.free(response.body);
        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const id = getOptionalObjectString(parsed.value, "id") orelse return error.MissingSessionId;
        return allocator.dupe(u8, id);
    }

    fn ensureSessionTitle(self: *Client, session_id: []const u8, title: []const u8) !void {
        const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}", .{session_id});
        defer self.allocator.free(path);

        const body = try stringifyAlloc(self.allocator, .{
            .title = trimmed,
        });
        defer self.allocator.free(body);

        const response = try self.requestJson(.PATCH, path, body);
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    fn startPromptAsync(
        self: *Client,
        session_id: []const u8,
        request: provider_types.SendPromptRequest,
    ) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/prompt_async", .{session_id});
        defer self.allocator.free(path);

        const body = try buildPromptBody(self.allocator, request);
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    fn waitForPromptResult(
        self: *Client,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        baseline_assistant_id: ?[]const u8,
        baseline_diff_payload: []const u8,
        request: provider_types.SendPromptRequest,
        event_stream_context: ?*EventStreamContext,
    ) ![]u8 {
        var handled_permission_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (handled_permission_ids.items) |id| self.allocator.free(id);
            handled_permission_ids.deinit(self.allocator);
        }

        var streamed_text = try self.allocator.dupe(u8, "");
        defer self.allocator.free(streamed_text);

        var last_diff_payload = try self.allocator.dupe(u8, baseline_diff_payload);
        defer self.allocator.free(last_diff_payload);

        var last_task_summary: ?[]u8 = null;
        defer if (last_task_summary) |summary| self.allocator.free(summary);

        var last_retry_message: ?[]u8 = null;
        defer if (last_retry_message) |message| self.allocator.free(message);

        var attempt: usize = 0;
        while (attempt < MAX_POLL_ATTEMPTS) : (attempt += 1) {
            const has_pending_permissions = try self.handlePendingPermissions(session_id, request, &handled_permission_ids);
            var latest_snapshot = try self.fetchLatestAssistantSnapshot(self.allocator, session_id, baseline_assistant_id);
            defer latest_snapshot.deinit(self.allocator);
            const stream_idle = if (event_stream_context) |context|
                eventStreamReachedIdle(context)
            else
                false;
            if (event_stream_context) |context| {
                try self.syncStreamedTextFromEventStream(context, &streamed_text);
            }
            try self.emitTaskProgressFromSnapshot(&latest_snapshot, request, &last_task_summary);
            if (event_stream_context == null) {
                try self.emitAssistantProgressFromSnapshot(&latest_snapshot, baseline_assistant_id, request, &streamed_text);
            }
            try self.emitDiffProgress(session_id, request, baseline_diff_payload, &last_diff_payload);

            const status = try self.fetchSessionStatus(session_id);
            switch (status) {
                .retry => |retry| {
                    if (request.on_stream_event) |on_stream_event| {
                        if (lastRetryMessageChanged(&last_retry_message, self.allocator, retry.message)) {
                            const title = if (retry.attempt > 0)
                                try std.fmt.allocPrint(self.allocator, "OpenCode retry {d}", .{retry.attempt})
                            else
                                try self.allocator.dupe(u8, "OpenCode retry");
                            defer self.allocator.free(title);
                            on_stream_event(request.stream_context, .{ .message = .{
                                .title = title,
                                .body = retry.message,
                            } });
                        }
                    }
                },
                else => {
                    if (last_retry_message) |message| {
                        self.allocator.free(message);
                        last_retry_message = null;
                    }
                },
            }

            const has_output_activity =
                std.mem.trim(u8, streamed_text, &std.ascii.whitespace).len > 0 or
                latest_snapshot.hasRenderablePostBaselineContent(baseline_assistant_id);

            const idle_exit_with_body = blk: {
                if (status != .idle or !has_output_activity) break :blk false;
                const f = latest_snapshot.finish orelse break :blk false;
                break :blk !std.mem.eql(u8, f, "tool-calls");
            };

            if (!has_pending_permissions and
                (stream_idle or
                    latest_snapshot.isTerminalForPrompt(baseline_assistant_id) or
                    idle_exit_with_body))
            {
                break;
            }

            if (!has_pending_permissions and
                event_stream_context == null and
                status == .idle and
                !has_output_activity and
                attempt + 1 >= EMPTY_IDLE_GRACE_POLLS)
            {
                return error.OpencodeEmptyReply;
            }

            sleepMs(POLL_INTERVAL_MS);
        } else {
            return error.OpencodeRequestTimedOut;
        }

        var final_snapshot = try self.fetchLatestAssistantSnapshot(allocator, session_id, baseline_assistant_id);
        defer final_snapshot.deinit(allocator);

        if (final_snapshot.message_id) |message_id| {
            if (baseline_assistant_id == null or !std.mem.eql(u8, message_id, baseline_assistant_id.?)) {
                if (std.mem.trim(u8, final_snapshot.text, &std.ascii.whitespace).len > 0) {
                    return allocator.dupe(u8, final_snapshot.text);
                }
                if (final_snapshot.error_message) |error_message| {
                    return allocator.dupe(u8, error_message);
                }
            }
        }

        if (std.mem.trim(u8, streamed_text, &std.ascii.whitespace).len > 0) {
            return allocator.dupe(u8, streamed_text);
        }

        return allocator.dupe(u8, "");
    }

    fn syncStreamedTextFromEventStream(
        self: *Client,
        context: *EventStreamContext,
        streamed_text: *[]u8,
    ) !void {
        context.mutex.lock();
        defer context.mutex.unlock();

        if (context.streamed_text.items.len <= streamed_text.*.len) return;
        if (!std.mem.startsWith(u8, context.streamed_text.items, streamed_text.*)) return;

        self.allocator.free(streamed_text.*);
        streamed_text.* = try self.allocator.dupe(u8, context.streamed_text.items);
    }

    fn emitAssistantProgress(
        self: *Client,
        session_id: []const u8,
        baseline_assistant_id: ?[]const u8,
        request: provider_types.SendPromptRequest,
        streamed_text: *[]u8,
    ) !void {
        var snapshot = try self.fetchLatestAssistantSnapshot(self.allocator, session_id, baseline_assistant_id);
        defer snapshot.deinit(self.allocator);
        try self.emitAssistantProgressFromSnapshot(&snapshot, baseline_assistant_id, request, streamed_text);
    }

    fn emitTaskProgressFromSnapshot(
        self: *Client,
        snapshot: *const AssistantSnapshot,
        request: provider_types.SendPromptRequest,
        last_task_summary: *?[]u8,
    ) !void {
        const on_stream_event = request.on_stream_event orelse return;
        const summary = snapshot.task_summary orelse return;

        if (last_task_summary.*) |existing| {
            if (std.mem.eql(u8, existing, summary)) return;
            self.allocator.free(existing);
            last_task_summary.* = null;
        }

        on_stream_event(request.stream_context, .{ .message = .{
            .title = "OpenCode task",
            .body = summary,
        } });
        last_task_summary.* = try self.allocator.dupe(u8, summary);
    }

    fn emitAssistantProgressFromSnapshot(
        self: *Client,
        snapshot: *const AssistantSnapshot,
        baseline_assistant_id: ?[]const u8,
        request: provider_types.SendPromptRequest,
        streamed_text: *[]u8,
    ) !void {
        const on_stream_delta = request.on_stream_delta orelse return;

        const message_id = snapshot.message_id orelse return;
        if (baseline_assistant_id) |baseline_id| {
            if (std.mem.eql(u8, message_id, baseline_id)) return;
        }

        if (!std.mem.startsWith(u8, snapshot.text, streamed_text.*)) return;
        const delta = snapshot.text[streamed_text.*.len..];
        if (delta.len == 0) return;

        on_stream_delta(request.stream_context, delta);

        self.allocator.free(streamed_text.*);
        streamed_text.* = try self.allocator.dupe(u8, snapshot.text);
    }

    fn emitDiffProgress(
        self: *Client,
        session_id: []const u8,
        request: provider_types.SendPromptRequest,
        baseline_diff_payload: []const u8,
        last_diff_payload: *[]u8,
    ) !void {
        const on_stream_event = request.on_stream_event orelse return;

        const current_payload = try self.fetchSessionDiffPayloadAlloc(session_id);
        defer self.allocator.free(current_payload);
        if (std.mem.eql(u8, current_payload, last_diff_payload.*)) return;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, current_payload, .{});
        defer parsed.deinit();

        var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
        defer files.deinit(std.heap.page_allocator);
        try appendSessionDiffFiles(parsed.value, &files);
        var baseline_files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
        defer baseline_files.deinit(std.heap.page_allocator);
        try appendSessionDiffFilesFromPayload(self.allocator, baseline_diff_payload, &baseline_files);

        var changed_files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
        defer changed_files.deinit(std.heap.page_allocator);
        try appendChangedSessionDiffFiles(&changed_files, files.items, baseline_files.items);

        if (changed_files.items.len == 0) {
            self.allocator.free(last_diff_payload.*);
            last_diff_payload.* = try self.allocator.dupe(u8, current_payload);
            return;
        }

        on_stream_event(request.stream_context, .{ .diff = .{
            .files = changed_files.items,
        } });

        self.allocator.free(last_diff_payload.*);
        last_diff_payload.* = try self.allocator.dupe(u8, current_payload);
    }

    fn fetchSessionDiffPayloadAlloc(self: *Client, session_id: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/diff", .{session_id});
        defer self.allocator.free(path);

        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) {
            return self.allocator.dupe(u8, "");
        }
        return self.allocator.dupe(u8, response.body);
    }

    fn handlePendingPermissions(
        self: *Client,
        session_id: []const u8,
        request: provider_types.SendPromptRequest,
        handled_permission_ids: *std.ArrayList([]u8),
    ) !bool {
        const response = try self.requestJson(.GET, "/permission", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return false;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        if (parsed.value != .array) return false;

        var found_pending_for_session = false;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const pending_session_id = getOptionalObjectString(item, "sessionID") orelse continue;
            if (!std.mem.eql(u8, pending_session_id, session_id)) continue;

            found_pending_for_session = true;

            const request_id = getOptionalObjectString(item, "id") orelse continue;
            if (containsString(handled_permission_ids.items, request_id)) continue;

            const decision = switch (request.approval_policy orelse .on_request) {
                .never => .approve,
                .on_request => if (request.on_approval_request) |on_approval_request|
                    try self.requestPermissionApproval(item, request_id, request.stream_context, on_approval_request)
                else
                    .deny,
            };

            try self.replyToPermission(session_id, request_id, decision);
            try handled_permission_ids.append(self.allocator, try self.allocator.dupe(u8, request_id));
        }

        return found_pending_for_session;
    }

    fn requestPermissionApproval(
        self: *Client,
        value: std.json.Value,
        request_id: []const u8,
        context: ?*anyopaque,
        on_approval_request: *const fn (?*anyopaque, provider_types.ApprovalRequest) provider_types.ApprovalDecision,
    ) !provider_types.ApprovalDecision {
        const permission_name = getOptionalObjectString(value, "permission") orelse "permission";
        const title = try std.fmt.allocPrint(self.allocator, "OpenCode wants {s} permission", .{permission_name});
        defer self.allocator.free(title);

        const body = try buildPermissionBody(self.allocator, value);
        defer self.allocator.free(body);

        return on_approval_request(context, .{
            .call_id = request_id,
            .title = title,
            .body = body,
        });
    }

    fn replyToPermission(
        self: *Client,
        session_id: []const u8,
        request_id: []const u8,
        decision: provider_types.ApprovalDecision,
    ) !void {
        const reply = switch (decision) {
            .approve => "once",
            .deny => "reject",
        };

        const body = try stringifyAlloc(self.allocator, .{
            .reply = reply,
        });
        defer self.allocator.free(body);

        const path = try std.fmt.allocPrint(self.allocator, "/permission/{s}/reply", .{request_id});
        defer self.allocator.free(path);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);

        if (response.status == .ok or response.status == .no_content) return;

        const legacy_body = try stringifyAlloc(self.allocator, .{
            .response = reply,
        });
        defer self.allocator.free(legacy_body);

        const legacy_path = try std.fmt.allocPrint(self.allocator, "/session/{s}/permissions/{s}", .{ session_id, request_id });
        defer self.allocator.free(legacy_path);

        const legacy_response = try self.requestJson(.POST, legacy_path, legacy_body);
        defer self.allocator.free(legacy_response.body);

        if (legacy_response.status != .ok and legacy_response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    fn fetchLatestAssistantSnapshot(
        self: *Client,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        baseline_assistant_id: ?[]const u8,
    ) !AssistantSnapshot {
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/message?limit={d}", .{ session_id, MESSAGE_POLL_LIMIT });
        defer self.allocator.free(path);

        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const latest_opt: ?std.json.Value = if (baseline_assistant_id != null)
            findPrimaryAssistantAfterLastUser(parsed.value) orelse findLatestAssistantMessage(parsed.value)
        else
            findLatestAssistantMessage(parsed.value);
        const latest = latest_opt orelse return .{
            .text = try allocator.dupe(u8, ""),
        };

        const info = getObjectField(latest, "info") orelse return .{
            .text = try allocator.dupe(u8, ""),
        };
        const message_id = getOptionalObjectString(info, "id");

        return .{
            .message_id = if (message_id) |id| try allocator.dupe(u8, id) else null,
            .text = try extractAssistantTextAlloc(allocator, latest),
            .error_message = try extractAssistantErrorMessageAlloc(allocator, latest),
            .finish = try extractAssistantFinishAlloc(allocator, latest),
            .task_summary = try extractLatestAssistantTaskSummaryAlloc(allocator, parsed.value, baseline_assistant_id),
        };
    }

    fn fetchSessionStatus(self: *Client, session_id: []const u8) !SessionStatus {
        const response = try self.requestJson(.GET, "/session/status", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return .idle;
        const status_value = parsed.value.object.get(session_id) orelse return .idle;
        if (status_value != .object) return .idle;

        const type_name = getOptionalObjectString(status_value, "type") orelse return .busy;
        if (std.mem.eql(u8, type_name, "idle")) return .idle;
        if (std.mem.eql(u8, type_name, "busy")) return .busy;
        if (std.mem.eql(u8, type_name, "retry")) {
            return .{ .retry = .{
                .attempt = jsonInteger(getObjectField(status_value, "attempt")) orelse 0,
                .message = getOptionalObjectString(status_value, "message") orelse "OpenCode is retrying the request.",
            } };
        }

        return .busy;
    }

    fn requestJson(
        self: *Client,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        const auth_header = try self.makeAuthorizationHeader();
        defer if (auth_header) |header| self.allocator.free(header.value);

        var headers_storage: [3]std.http.Header = undefined;
        var header_count: usize = 0;
        if (payload != null) {
            headers_storage[header_count] = .{ .name = "content-type", .value = "application/json" };
            header_count += 1;
        }
        if (self.config.working_directory) |dir| {
            headers_storage[header_count] = .{ .name = "x-opencode-directory", .value = dir };
            header_count += 1;
        }
        if (auth_header) |header| {
            headers_storage[header_count] = header;
            header_count += 1;
        }

        var threaded = std.Io.Threaded.init_single_threaded;
        var http_client: std.http.Client = .{ .allocator = self.allocator, .io = threaded.io() };
        defer http_client.deinit();

        const result = try http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .extra_headers = headers_storage[0..header_count],
        });

        return .{
            .status = result.status,
            .body = try body_writer.toOwnedSlice(),
        };
    }

    fn makeAuthorizationHeader(self: *Client) !?std.http.Header {
        return makeAuthorizationHeaderAlloc(self.allocator, self.config);
    }
};

pub fn shutdownOwnedServer() void {
    shared_server_state.mutex.lock();
    defer shared_server_state.mutex.unlock();
    stopOwnedServerLocked();
}

fn stopOwnedServerLocked() void {
    if (shared_server_state.child) |*child| {
        if (shared_server_state.owns_child) {
            var threaded = std.Io.Threaded.init_single_threaded;
            child.kill(threaded.io());
        }
        shared_server_state.child = null;
        shared_server_state.owns_child = false;
    }
}

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

const SessionStatus = union(enum) {
    idle,
    busy,
    retry: struct {
        attempt: i64,
        message: []const u8,
    },
};

const AssistantSnapshot = struct {
    message_id: ?[]u8 = null,
    text: []u8,
    error_message: ?[]u8 = null,
    finish: ?[]u8 = null,
    task_summary: ?[]u8 = null,

    fn deinit(self: *AssistantSnapshot, allocator: std.mem.Allocator) void {
        if (self.message_id) |id| allocator.free(id);
        allocator.free(self.text);
        if (self.error_message) |message| allocator.free(message);
        if (self.finish) |finish| allocator.free(finish);
        if (self.task_summary) |summary| allocator.free(summary);
    }

    fn isTerminalForPrompt(self: *const AssistantSnapshot, baseline_assistant_id: ?[]const u8) bool {
        const message_id = self.message_id orelse return false;
        if (baseline_assistant_id) |baseline_id| {
            if (std.mem.eql(u8, message_id, baseline_id)) return false;
        }

        const finish = self.finish orelse return false;
        return !std.mem.eql(u8, finish, "tool-calls");
    }

    fn hasRenderablePostBaselineContent(self: *const AssistantSnapshot, baseline_assistant_id: ?[]const u8) bool {
        const message_id = self.message_id orelse return false;
        if (baseline_assistant_id) |baseline_id| {
            if (std.mem.eql(u8, message_id, baseline_id)) return false;
        }

        if (std.mem.trim(u8, self.text, &std.ascii.whitespace).len > 0) return true;
        return self.error_message != null;
    }
};

const EventStreamHandle = struct {
    worker: std.Thread,
    context: *EventStreamContext,
};

const EventStreamOpenState = enum {
    starting,
    ready,
    failed,
};

const EventStreamContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    session_id: []u8,
    baseline_assistant_id: ?[]u8,
    request: provider_types.SendPromptRequest,
    child: ?std.process.Child = null,
    streamed_text: std.ArrayListUnmanaged(u8) = .empty,
    mutex: Mutex = .{},
    condition: Condition = .{},
    open_state: EventStreamOpenState = .starting,
    stop_requested: bool = false,
    session_idle: bool = false,

    fn deinit(self: *EventStreamContext) void {
        self.allocator.free(self.session_id);
        if (self.baseline_assistant_id) |message_id| self.allocator.free(message_id);
        self.streamed_text.deinit(self.allocator);
    }
};

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{},
    };
    try stringify.write(value);
    return writer.toOwnedSlice();
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn makeAuthorizationHeaderAlloc(allocator: std.mem.Allocator, config: Config) !?std.http.Header {
    const password = config.password orelse return null;
    const username = config.username orelse "opencode";
    const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(combined);
    const encoded = try encodeBase64Alloc(allocator, combined);
    defer allocator.free(encoded);
    const value = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    return .{ .name = "authorization", .value = value };
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn getOptionalObjectString(value: std.json.Value, field: []const u8) ?[]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .string => |text| text,
        else => null,
    };
}

fn parseImportedApiMessagesAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ChatMessage {
    if (value != .array) return allocator.alloc(provider_types.ChatMessage, 0);

    var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
    errdefer {
        for (messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        messages.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) continue;
        const info = getObjectField(item, "info") orelse continue;
        const role = parseImportedApiMessageRole(info) orelse continue;
        const parts = getObjectField(item, "parts") orelse continue;
        if (parts != .array) continue;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        for (parts.array.items) |part| {
            try appendImportedPartText(allocator, &body, part);
        }

        const trimmed = std.mem.trim(u8, body.items, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        try messages.append(allocator, .{
            .role = role,
            .author = try allocator.dupe(u8, importedAuthorForRole(role)),
            .body = try allocator.dupe(u8, trimmed),
        });
    }

    return messages.toOwnedSlice(allocator);
}

fn parseImportedApiMessageRole(info: std.json.Value) ?provider_types.MessageRole {
    const role = getOptionalObjectString(info, "role") orelse return null;
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "system")) return .system;
    return null;
}

fn importedAuthorForRole(role: provider_types.MessageRole) []const u8 {
    return switch (role) {
        .user => "You",
        .assistant => "OpenCode",
        .system => "System",
    };
}

fn appendImportedPartText(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    part: std.json.Value,
) !void {
    if (part != .object) return;
    const part_type = getOptionalObjectString(part, "type") orelse return;

    if (std.mem.eql(u8, part_type, "text")) {
        if (jsonBool(getObjectField(part, "synthetic")) == true) return;
        const text = getOptionalObjectString(part, "text") orelse return;
        try appendImportedBodySegment(allocator, body, text);
        return;
    }

    if (std.mem.eql(u8, part_type, "file")) {
        const source = getObjectField(part, "source");
        const path = if (source) |source_value|
            getOptionalObjectString(source_value, "path")
        else
            null;
        const fallback = getOptionalObjectString(part, "filename") orelse getOptionalObjectString(part, "url");
        const target = path orelse fallback orelse return;
        try appendImportedBodySegment(allocator, body, target);
    }
}

fn appendImportedBodySegment(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    segment: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, segment, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (body.items.len > 0) try body.appendSlice(allocator, "\n\n");
    try body.appendSlice(allocator, trimmed);
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return switch (actual) {
        .bool => |flag| flag,
        else => null,
    };
}

fn normalizeUnixTimestamp(value: ?i64) ?i64 {
    const timestamp = value orelse return null;
    if (timestamp >= 1_000_000_000_000) return @divFloor(timestamp, 1000);
    return timestamp;
}

fn findSessionById(value: std.json.Value, thread_id: []const u8) ?std.json.Value {
    if (value != .array) return null;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const id = getOptionalObjectString(item, "id") orelse continue;
        if (std.mem.eql(u8, id, thread_id)) return item;
    }
    return null;
}

fn extractSessionUpdatedAt(value: std.json.Value) ?i64 {
    if (jsonInteger(getObjectField(value, "time_updated"))) |time_updated| {
        return normalizeUnixTimestamp(time_updated);
    }

    const time_value = getObjectField(value, "time") orelse return null;
    if (time_value == .object) {
        if (jsonInteger(getObjectField(time_value, "updated"))) |updated| {
            return normalizeUnixTimestamp(updated);
        }
        if (jsonInteger(getObjectField(time_value, "created"))) |created| {
            return normalizeUnixTimestamp(created);
        }
    }

    return null;
}

fn sessionMatchesWorkingDirectory(working_directory: ?[]const u8, session_directory: ?[]const u8) bool {
    const root = working_directory orelse return true;
    const candidate = session_directory orelse return true;
    if (std.mem.eql(u8, candidate, root)) return true;
    if (candidate.len <= root.len) return false;
    if (!std.mem.startsWith(u8, candidate, root)) return false;

    const separator = std.fs.path.sep;
    return candidate[root.len] == separator;
}

fn parseConfiguredModelsAlloc(allocator: std.mem.Allocator, root: std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    switch (providerCollectionValue(root) orelse root) {
        .array => |providers| {
            for (providers.items) |provider_value| {
                try appendProviderModels(allocator, provider_value, null, &models);
            }
        },
        .object => |providers| {
            var iterator = providers.iterator();
            while (iterator.next()) |entry| {
                try appendProviderModels(allocator, entry.value_ptr.*, entry.key_ptr.*, &models);
            }
        },
        else => {},
    }

    return models.toOwnedSlice(allocator);
}

fn providerCollectionValue(root: std.json.Value) ?std.json.Value {
    if (root != .object) return null;
    return getObjectField(root, "providers");
}

fn readReasoningSupported(model_value: std.json.Value) bool {
    if (model_value != .object) return true;
    const cap = getObjectField(model_value, "capabilities") orelse return true;
    if (cap != .object) return true;
    const r = getObjectField(cap, "reasoning") orelse return true;
    return switch (r) {
        .bool => |b| b,
        else => true,
    };
}

fn collectVariantKeysSortedAlloc(allocator: std.mem.Allocator, model_value: std.json.Value) !?[][:0]const u8 {
    if (model_value != .object) return null;
    const variants = getObjectField(model_value, "variants") orelse return null;
    if (variants != .object) return null;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = variants.object.iterator();
    while (it.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
    }
    if (names.items.len == 0) return null;

    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    const out = try allocator.alloc([:0]const u8, names.items.len);
    errdefer {
        for (out) |k| allocator.free(k);
        allocator.free(out);
    }
    for (names.items, 0..) |name, i| {
        out[i] = try allocator.dupeZ(u8, name);
    }
    return out;
}

fn appendProviderModels(
    allocator: std.mem.Allocator,
    provider_value: std.json.Value,
    fallback_provider_id: ?[]const u8,
    models: *std.ArrayList(provider_types.ModelInfo),
) !void {
    if (provider_value != .object) return;

    const provider_id = getOptionalObjectString(provider_value, "id") orelse fallback_provider_id orelse return;
    const provider_name = getOptionalObjectString(provider_value, "name") orelse
        getOptionalObjectString(provider_value, "displayName") orelse
        provider_id;
    const provider_models = getObjectField(provider_value, "models") orelse return;

    switch (provider_models) {
        .object => {
            var iterator = provider_models.object.iterator();
            while (iterator.next()) |entry| {
                try appendModelInfo(allocator, entry.value_ptr.*, provider_id, provider_name, entry.key_ptr.*, models);
            }
        },
        .array => {
            for (provider_models.array.items) |model_value| {
                try appendModelInfo(allocator, model_value, provider_id, provider_name, null, models);
            }
        },
        else => {},
    }
}

fn appendModelInfo(
    allocator: std.mem.Allocator,
    model_value: std.json.Value,
    provider_id: []const u8,
    provider_name: []const u8,
    fallback_model_id: ?[]const u8,
    models: *std.ArrayList(provider_types.ModelInfo),
) !void {
    const model_id, const model_name = switch (model_value) {
        .string => |text| .{ text, text },
        .object => .{
            getOptionalObjectString(model_value, "id") orelse fallback_model_id orelse return,
            getOptionalObjectString(model_value, "name") orelse
                getOptionalObjectString(model_value, "displayName") orelse
                getOptionalObjectString(model_value, "id") orelse
                fallback_model_id orelse return,
        },
        else => return,
    };

    const reasoning_supported = readReasoningSupported(model_value);
    const variant_keys = try collectVariantKeysSortedAlloc(allocator, model_value);
    errdefer if (variant_keys) |keys| {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    };

    try models.append(allocator, .{
        .provider_id = try allocator.dupe(u8, provider_id),
        .provider_name = try allocator.dupe(u8, provider_name),
        .model_id = try allocator.dupe(u8, model_id),
        .model_name = try allocator.dupe(u8, model_name),
        .reasoning_supported = reasoning_supported,
        .reasoning_variant_keys = variant_keys,
    });
}

fn extractAssistantTextAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const parts = getObjectField(value, "parts") orelse return allocator.dupe(u8, "");
    if (parts != .array) return allocator.dupe(u8, "");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    for (parts.array.items) |part| {
        if (part != .object) continue;
        const type_name = getOptionalObjectString(part, "type") orelse continue;
        if (!std.mem.eql(u8, type_name, "text")) continue;
        const chunk = getOptionalObjectString(part, "text") orelse "";
        try text.appendSlice(allocator, chunk);
    }

    return text.toOwnedSlice(allocator);
}

fn extractAssistantErrorMessageAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const info = getObjectField(value, "info") orelse return null;
    const error_value = getObjectField(info, "error") orelse return null;
    const message = getOptionalObjectString(error_value, "message") orelse return null;
    return try allocator.dupe(u8, message);
}

fn extractAssistantFinishAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const info = getObjectField(value, "info") orelse return null;
    const finish = getOptionalObjectString(info, "finish") orelse return null;
    return try allocator.dupe(u8, finish);
}

fn extractLatestAssistantTaskSummaryAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    baseline_assistant_id: ?[]const u8,
) !?[]u8 {
    if (value != .array) return null;

    var index = value.array.items.len;
    while (index > 0) {
        index -= 1;
        const item = value.array.items[index];
        if (item != .object) continue;
        const info = getObjectField(item, "info") orelse continue;
        const role = getOptionalObjectString(info, "role") orelse continue;
        if (!std.mem.eql(u8, role, "assistant")) continue;

        const message_id = getOptionalObjectString(info, "id");
        if (baseline_assistant_id != null and message_id != null and std.mem.eql(u8, baseline_assistant_id.?, message_id.?)) continue;

        if (try extractAssistantTaskSummaryAlloc(allocator, item)) |summary| {
            return summary;
        }
    }

    return null;
}

fn extractAssistantTaskSummaryAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const parts = getObjectField(value, "parts") orelse return null;
    if (parts != .array) return null;

    var index = parts.array.items.len;
    while (index > 0) {
        index -= 1;
        const part = parts.array.items[index];
        if (part != .object) continue;
        const part_type = getOptionalObjectString(part, "type") orelse continue;
        if (!std.mem.eql(u8, part_type, "tool")) continue;
        const tool_name = getOptionalObjectString(part, "tool") orelse continue;
        if (!std.mem.eql(u8, tool_name, "task")) continue;

        const state = getObjectField(part, "state") orelse continue;
        const status = getOptionalObjectString(state, "status") orelse continue;
        const title = getOptionalObjectString(state, "title") orelse blk: {
            const input = getObjectField(state, "input") orelse break :blk null;
            break :blk getOptionalObjectString(input, "description");
        } orelse "OpenCode task";

        if (std.mem.eql(u8, status, "running")) {
            return try std.fmt.allocPrint(allocator, "Running subtask: {s}", .{title});
        }
        if (std.mem.eql(u8, status, "completed")) {
            return try std.fmt.allocPrint(allocator, "Completed subtask: {s}", .{title});
        }
        if (std.mem.eql(u8, status, "failed")) {
            return try std.fmt.allocPrint(allocator, "Failed subtask: {s}", .{title});
        }

        return try std.fmt.allocPrint(allocator, "{s} subtask: {s}", .{ status, title });
    }

    return null;
}

fn startEventStream(self: *Client, allocator: std.mem.Allocator, session_id: []const u8, baseline_assistant_id: ?[]const u8, request: provider_types.SendPromptRequest) !?EventStreamHandle {
    if (request.on_stream_delta == null and request.on_stream_event == null) return null;

    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);

    const owned_baseline_assistant_id = if (baseline_assistant_id) |message_id|
        try allocator.dupe(u8, message_id)
    else
        null;
    errdefer if (owned_baseline_assistant_id) |message_id| allocator.free(message_id);

    const context = try allocator.create(EventStreamContext);
    errdefer allocator.destroy(context);

    context.* = .{
        .allocator = allocator,
        .config = self.config,
        .session_id = owned_session_id,
        .baseline_assistant_id = owned_baseline_assistant_id,
        .request = request,
    };
    errdefer context.deinit();

    const worker = try std.Thread.spawn(.{}, runEventStream, .{context});
    context.mutex.lock();
    while (context.open_state == .starting) {
        context.condition.wait(&context.mutex);
    }
    const open_state = context.open_state;
    context.mutex.unlock();

    if (open_state == .failed) {
        worker.join();
        context.deinit();
        allocator.destroy(context);
        return null;
    }

    return .{
        .worker = worker,
        .context = context,
    };
}

fn runEventStream(context: *EventStreamContext) void {
    streamSessionEvents(context) catch |err| {
        log.warn("OpenCode event stream ended: {s}", .{@errorName(err)});
    };
}

fn streamSessionEvents(context: *EventStreamContext) !void {
    var env_map = try process_env.buildAugmentedEnvMap(context.allocator);
    defer env_map.deinit();

    const curl_executable = try process_env.resolveExecutableInEnvMapAlloc(context.allocator, &env_map, "curl");
    defer context.allocator.free(curl_executable);

    var opened = false;
    errdefer if (!opened) signalEventStreamOpenState(context, .failed);

    const url = try std.fmt.allocPrint(context.allocator, "{s}/event", .{context.config.base_url});
    defer context.allocator.free(url);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(context.allocator);

    try argv.appendSlice(context.allocator, &.{
        curl_executable,
        "--no-buffer",
        "--silent",
        "--show-error",
        "-H",
        "accept: text/event-stream",
    });

    var owned_auth_header: ?[]u8 = null;
    defer if (owned_auth_header) |header| context.allocator.free(header);
    if (try makeAuthorizationHeaderAlloc(context.allocator, context.config)) |header| {
        defer context.allocator.free(header.value);
        owned_auth_header = try std.fmt.allocPrint(context.allocator, "{s}: {s}", .{ header.name, header.value });
        try argv.appendSlice(context.allocator, &.{ "-H", owned_auth_header.? });
    }

    var owned_directory_header: ?[]u8 = null;
    defer if (owned_directory_header) |header| context.allocator.free(header);
    if (context.config.working_directory) |dir| {
        owned_directory_header = try std.fmt.allocPrint(context.allocator, "x-opencode-directory: {s}", .{dir});
        try argv.appendSlice(context.allocator, &.{ "-H", owned_directory_header.? });
    }

    try argv.append(context.allocator, url);

    var threaded_spawn = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_spawn.deinit();
    const child = try std.process.spawn(threaded_spawn.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = &env_map,
    });

    context.mutex.lock();
    context.child = child;
    context.mutex.unlock();
    defer cleanupEventStreamChild(context);

    log.info("OpenCode event stream started for session {s} pid={d}", .{ context.session_id, child.id orelse -1 });

    opened = true;
    signalEventStreamOpenState(context, .ready);

    const stdout = context.child.?.stdout.?;
    var read_buffer: [64 * 1024]u8 = undefined;
    var threaded_read = std.Io.Threaded.init_single_threaded;
    var file_reader = stdout.reader(threaded_read.io(), &read_buffer);

    var event_name: std.ArrayList(u8) = .empty;
    defer event_name.deinit(context.allocator);
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(context.allocator);

    while (true) {
        if (isEventStreamStopRequested(context)) return;
        const maybe_line = try file_reader.interface.takeDelimiter('\n');
        if (maybe_line == null) break;

        const raw_line = maybe_line.?;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (line.len == 0) {
            if (event_data.items.len > 0 and try processEventStreamMessage(context, event_name.items, event_data.items)) {
                return;
            }
            if (isEventStreamStopRequested(context)) return;
            event_name.clearRetainingCapacity();
            event_data.clearRetainingCapacity();
            continue;
        }

        if (line[0] == ':') continue;

        if (std.mem.startsWith(u8, line, "event:")) {
            event_name.clearRetainingCapacity();
            try event_name.appendSlice(context.allocator, std.mem.trimStart(u8, line["event:".len..], " "));
            continue;
        }

        if (std.mem.startsWith(u8, line, "data:")) {
            if (event_data.items.len > 0) {
                try event_data.append(context.allocator, '\n');
            }
            try event_data.appendSlice(context.allocator, std.mem.trimStart(u8, line["data:".len..], " "));
        }
    }

    if (event_data.items.len > 0) {
        _ = try processEventStreamMessage(context, event_name.items, event_data.items);
    }
}

fn signalEventStreamOpenState(context: *EventStreamContext, next: EventStreamOpenState) void {
    context.mutex.lock();
    defer context.mutex.unlock();
    if (context.open_state != .starting) return;
    context.open_state = next;
    context.condition.broadcast();
}

fn signalEventStreamStop(handle: EventStreamHandle) void {
    log.info("stopping OpenCode event stream for session {s}", .{handle.context.session_id});
    handle.context.mutex.lock();
    handle.context.stop_requested = true;
    if (handle.context.child) |*child| {
        var threaded = std.Io.Threaded.init_single_threaded;
        child.kill(threaded.io());
    }
    handle.context.mutex.unlock();
    handle.worker.join();
    handle.context.deinit();
    handle.context.allocator.destroy(handle.context);
}

fn isEventStreamStopRequested(context: *EventStreamContext) bool {
    context.mutex.lock();
    defer context.mutex.unlock();
    return context.stop_requested;
}

fn cleanupEventStreamChild(context: *EventStreamContext) void {
    context.mutex.lock();
    var maybe_child = context.child;
    context.child = null;
    context.mutex.unlock();

    if (maybe_child) |*owned_child| {
        if (owned_child.id != null) {
            var threaded = std.Io.Threaded.init_single_threaded;
            _ = owned_child.wait(threaded.io()) catch {};
        }
    }

    log.info("OpenCode event stream exited for session {s}", .{context.session_id});
}

fn processEventStreamMessage(context: *EventStreamContext, raw_event_name: []const u8, raw_event_data: []const u8) !bool {
    if (raw_event_data.len == 0) return false;

    var parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, raw_event_data, .{});
    defer parsed.deinit();

    const envelope = parseEventEnvelope(parsed.value, raw_event_name) orelse return false;

    if (std.mem.eql(u8, envelope.event_type, "session.idle")) {
        signalEventStreamIdle(context);
        return false;
    }

    if (std.mem.eql(u8, envelope.event_type, "session.status")) {
        return false;
    }

    if (std.mem.eql(u8, envelope.event_type, "message.part.delta")) {
        try handleMessagePartDelta(context, envelope.properties);
        return false;
    }

    if (std.mem.eql(u8, envelope.event_type, "session.diff")) {
        try handleSessionDiff(context, envelope.properties);
        return false;
    }

    return false;
}

fn signalEventStreamIdle(context: *EventStreamContext) void {
    context.mutex.lock();
    context.session_idle = true;
    context.mutex.unlock();
}

fn eventStreamReachedIdle(context: *EventStreamContext) bool {
    context.mutex.lock();
    defer context.mutex.unlock();
    return context.session_idle;
}

const EventEnvelope = struct {
    event_type: []const u8,
    properties: std.json.Value,
};

fn parseEventEnvelope(root: std.json.Value, event_name: []const u8) ?EventEnvelope {
    if (root == .object) {
        if (getObjectField(root, "payload")) |payload| {
            if (payload == .object) {
                if (getOptionalObjectString(payload, "type")) |payload_type| {
                    return .{
                        .event_type = payload_type,
                        .properties = getObjectField(payload, "properties") orelse payload,
                    };
                }
            }
        }

        if (getOptionalObjectString(root, "type")) |root_type| {
            return .{
                .event_type = root_type,
                .properties = getObjectField(root, "properties") orelse root,
            };
        }
    }

    if (event_name.len == 0) return null;
    return .{
        .event_type = event_name,
        .properties = root,
    };
}

fn eventTargetsSession(value: std.json.Value, session_id: []const u8) bool {
    const event_session_id = getOptionalObjectString(value, "sessionID") orelse return false;
    return std.mem.eql(u8, event_session_id, session_id);
}

fn handleMessagePartDelta(context: *EventStreamContext, properties: std.json.Value) !void {
    if (!eventTargetsSession(properties, context.session_id)) return;

    const message_id = getOptionalObjectString(properties, "messageID") orelse return;
    if (context.baseline_assistant_id) |baseline_id| {
        if (std.mem.eql(u8, message_id, baseline_id)) return;
    }

    const field = getOptionalObjectString(properties, "field") orelse return;
    if (!std.mem.eql(u8, field, "text")) return;

    const delta = getOptionalObjectString(properties, "delta") orelse return;
    if (delta.len == 0) return;

    const on_stream_delta = context.request.on_stream_delta orelse {
        context.mutex.lock();
        defer context.mutex.unlock();
        try context.streamed_text.appendSlice(context.allocator, delta);
        return;
    };

    {
        context.mutex.lock();
        defer context.mutex.unlock();
        try context.streamed_text.appendSlice(context.allocator, delta);
    }

    const owned = try context.allocator.dupe(u8, delta);
    errdefer context.allocator.free(owned);
    on_stream_delta(context.request.stream_context, owned);
    context.allocator.free(owned);
}

fn handleSessionDiff(context: *EventStreamContext, properties: std.json.Value) !void {
    const on_stream_event = context.request.on_stream_event orelse return;
    if (!eventTargetsSession(properties, context.session_id)) return;

    const diff_value = getObjectField(properties, "diff") orelse return;
    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);

    try appendSessionDiffFiles(diff_value, &files);
    if (files.items.len == 0) return;

    on_stream_event(context.request.stream_context, .{ .diff = .{
        .files = files.items,
    } });
}

/// Subagent runs can append additional assistant messages after the root reply for the
/// current user turn. Picking the newest-by-`time.created` assistant then points at an
/// often-empty sub-leaf while the root message is still streaming or accumulating text.
fn findPrimaryAssistantAfterLastUser(root: std.json.Value) ?std.json.Value {
    if (root != .array) return null;

    var last_user_index: ?usize = null;
    for (root.array.items, 0..) |item, index| {
        if (item != .object) continue;
        const info = getObjectField(item, "info") orelse continue;
        const role = getOptionalObjectString(info, "role") orelse continue;
        if (std.mem.eql(u8, role, "user")) {
            last_user_index = index;
        }
    }

    const after_user = last_user_index orelse return null;
    var i = after_user + 1;
    while (i < root.array.items.len) : (i += 1) {
        const item = root.array.items[i];
        if (item != .object) continue;
        const info = getObjectField(item, "info") orelse continue;
        const role = getOptionalObjectString(info, "role") orelse continue;
        if (std.mem.eql(u8, role, "assistant")) {
            return item;
        }
    }

    return null;
}

fn findLatestAssistantMessage(value: std.json.Value) ?std.json.Value {
    if (value != .array) return null;

    var latest: ?std.json.Value = null;
    var latest_created: i64 = -1;

    for (value.array.items, 0..) |item, index| {
        if (item != .object) continue;
        const info = getObjectField(item, "info") orelse continue;
        const role = getOptionalObjectString(info, "role") orelse continue;
        if (!std.mem.eql(u8, role, "assistant")) continue;

        const created = extractMessageCreatedAt(info) orelse @as(i64, @intCast(index));
        if (latest == null or created >= latest_created) {
            latest = item;
            latest_created = created;
        }
    }

    return latest;
}

fn extractMessageCreatedAt(info: std.json.Value) ?i64 {
    const time = getObjectField(info, "time") orelse return null;
    return jsonInteger(getObjectField(time, "created"));
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn buildPermissionBody(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    const permission_name = getOptionalObjectString(value, "permission") orelse "permission";
    const permission_label = try std.fmt.allocPrint(allocator, "Permission: {s}", .{permission_name});
    defer allocator.free(permission_label);
    try text.appendSlice(allocator, permission_label);

    const patterns_value = getObjectField(value, "patterns");
    if (patterns_value) |patterns| {
        if (patterns == .array and patterns.array.items.len > 0) {
            try text.appendSlice(allocator, "\nPatterns:");
            for (patterns.array.items) |pattern| {
                if (pattern != .string) continue;
                const label = try std.fmt.allocPrint(allocator, "\n- {s}", .{pattern.string});
                defer allocator.free(label);
                try text.appendSlice(allocator, label);
            }
        }
    }

    if (getObjectField(value, "tool")) |tool| {
        const call_id = getOptionalObjectString(tool, "callID");
        const message_id = getOptionalObjectString(tool, "messageID");
        if (call_id != null or message_id != null) {
            try text.appendSlice(allocator, "\nTool:");
            if (call_id) |id| {
                const label = try std.fmt.allocPrint(allocator, "\n- call: {s}", .{id});
                defer allocator.free(label);
                try text.appendSlice(allocator, label);
            }
            if (message_id) |id| {
                const label = try std.fmt.allocPrint(allocator, "\n- message: {s}", .{id});
                defer allocator.free(label);
                try text.appendSlice(allocator, label);
            }
        }
    }

    return text.toOwnedSlice(allocator);
}

fn appendSessionDiffFiles(value: std.json.Value, files: *std.ArrayList(provider_types.StreamDiffFile)) !void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| {
                try appendSessionDiffFile(item, files);
            }
        },
        .object => {
            if (getObjectField(value, "files")) |nested| {
                try appendSessionDiffFiles(nested, files);
                return;
            }
            try appendSessionDiffFile(value, files);
        },
        else => {},
    }
}

fn appendSessionDiffFilesFromPayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
    files: *std.ArrayList(provider_types.StreamDiffFile),
) !void {
    if (std.mem.trim(u8, payload, &std.ascii.whitespace).len == 0) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try appendSessionDiffFiles(parsed.value, files);
}

fn appendChangedSessionDiffFiles(
    target: *std.ArrayList(provider_types.StreamDiffFile),
    current: []const provider_types.StreamDiffFile,
    baseline: []const provider_types.StreamDiffFile,
) !void {
    for (current) |file| {
        const existing = findDiffFileByPath(baseline, file.path);
        if (existing) |before| {
            if (diffFilesEqual(before, file)) continue;
        }
        try target.append(std.heap.page_allocator, file);
    }
}

fn findDiffFileByPath(files: []const provider_types.StreamDiffFile, path: []const u8) ?provider_types.StreamDiffFile {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

fn diffFilesEqual(a: provider_types.StreamDiffFile, b: provider_types.StreamDiffFile) bool {
    if (a.additions != b.additions or a.deletions != b.deletions) return false;
    return optionalStringsEqual(a.patch, b.patch);
}

fn optionalStringsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn appendSessionDiffFile(item: std.json.Value, files: *std.ArrayList(provider_types.StreamDiffFile)) !void {
    if (item != .object) return;

    const path = getOptionalObjectString(item, "file") orelse
        getOptionalObjectString(item, "path") orelse
        findFirstStringByField(item, "path") orelse
        findFirstStringByField(item, "file") orelse return;
    const patch_text = findFirstStringByField(item, "patch") orelse
        findFirstStringByField(item, "diff");
    const patch = if (patch_text) |text|
        if (text.len > 0) text else null
    else
        null;

    try files.append(std.heap.page_allocator, .{
        .path = path,
        .additions = jsonInteger(getObjectField(item, "additions")) orelse
            findFirstIntegerByField(item, "additions") orelse
            countPatchLines(patch, '+'),
        .deletions = jsonInteger(getObjectField(item, "deletions")) orelse
            findFirstIntegerByField(item, "deletions") orelse
            countPatchLines(patch, '-'),
        .patch = patch,
    });
}

fn findFirstStringByField(value: std.json.Value, field: []const u8) ?[]const u8 {
    switch (value) {
        .object => |obj| {
            if (obj.get(field)) |candidate| {
                if (candidate == .string) return candidate.string;
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findFirstStringByField(entry.value_ptr.*, field)) |text| return text;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findFirstStringByField(item, field)) |text| return text;
            }
            return null;
        },
        else => return null,
    }
}

fn findFirstIntegerByField(value: std.json.Value, field: []const u8) ?i64 {
    switch (value) {
        .object => |obj| {
            if (obj.get(field)) |candidate| {
                return switch (candidate) {
                    .integer => |number| number,
                    .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
                    else => null,
                };
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findFirstIntegerByField(entry.value_ptr.*, field)) |number| return number;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findFirstIntegerByField(item, field)) |number| return number;
            }
            return null;
        },
        else => return null,
    }
}

fn countPatchLines(patch: ?[]const u8, prefix: u8) i64 {
    const diff = patch orelse return 0;
    var count: i64 = 0;
    var it = std.mem.tokenizeScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != prefix) continue;
        if (line.len >= 3 and std.mem.eql(u8, line[0..3], if (prefix == '+') "+++" else "---")) continue;
        count += 1;
    }
    return count;
}

fn containsString(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn lastRetryMessageChanged(target: *?[]u8, allocator: std.mem.Allocator, next: []const u8) bool {
    if (target.*) |current| {
        if (std.mem.eql(u8, current, next)) return false;
        allocator.free(current);
    }

    target.* = allocator.dupe(u8, next) catch return false;
    return true;
}

fn buildMessageBodyWithModel(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    model_ref: []const u8,
) ![]u8 {
    const provider_id, const model_id = parseModelRef(model_ref);
    return stringifyAlloc(allocator, .{
        .model = .{
            .providerID = provider_id,
            .modelID = model_id,
        },
        .parts = &.{.{ .type = "text", .text = prompt }},
    });
}

fn buildPromptBody(
    allocator: std.mem.Allocator,
    request: provider_types.SendPromptRequest,
) ![]u8 {
    const mapped_effort_variant = reasoningVariantName(request.reasoning_effort);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{},
    };

    try stringify.beginObject();
    if (request.model) |model_ref| {
        const provider_id, const model_id = parseModelRef(model_ref);
        try stringify.objectField("model");
        try stringify.beginObject();
        try stringify.objectField("providerID");
        try stringify.write(provider_id);
        try stringify.objectField("modelID");
        try stringify.write(model_id);
        try stringify.endObject();
    }
    if (request.opencode_variant) |explicit| {
        try stringify.objectField("variant");
        try stringify.write(explicit);
    } else if (mapped_effort_variant) |variant_name| {
        try stringify.objectField("variant");
        try stringify.write(variant_name);
    }
    try stringify.objectField("parts");
    try stringify.beginArray();
    try writeTextPart(&stringify, request.prompt);
    if (request.image) |image| try writeImagePart(&stringify, image.path);
    for (request.images) |image| try writeImagePart(&stringify, image.path);
    try stringify.endArray();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn writeTextPart(stringify: *std.json.Stringify, text: []const u8) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("text");
    try stringify.objectField("text");
    try stringify.write(text);
    try stringify.endObject();
}

fn writeImagePart(stringify: *std.json.Stringify, path: []const u8) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("file");
    try stringify.objectField("filename");
    try stringify.write(std.fs.path.basename(path));
    try stringify.objectField("source");
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("path");
    try stringify.objectField("path");
    try stringify.write(path);
    try stringify.endObject();
    try stringify.endObject();
}

fn reasoningVariantName(value: ?provider_types.ReasoningEffort) ?[]const u8 {
    return switch (value orelse return null) {
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn parseModelRef(model_ref: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, model_ref, '/')) |slash| {
        const provider_id = model_ref[0..slash];
        const model_id = model_ref[slash + 1 ..];
        if (provider_id.len > 0 and model_id.len > 0) {
            return .{ provider_id, model_id };
        }
    }

    return .{ "opencode", model_ref };
}

test "extractAssistantTextAlloc joins text parts" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"parts":[{"type":"text","text":"hello "},{"type":"text","text":"world"},{"type":"tool","text":"ignored"}]}
    , .{});
    defer parsed.deinit();

    const text = try extractAssistantTextAlloc(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "extractAssistantTaskSummaryAlloc summarizes task tool state" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"parts":[{"type":"tool","tool":"task","state":{"status":"running","title":"Explore website package"}}]}
    , .{});
    defer parsed.deinit();

    const summary = (try extractAssistantTaskSummaryAlloc(allocator, parsed.value)).?;
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("Running subtask: Explore website package", summary);
}

test "extractLatestAssistantTaskSummaryAlloc skips baseline assistant message" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"info":{"role":"assistant","id":"baseline"},"parts":[{"type":"tool","tool":"task","state":{"status":"completed","title":"Old task"}}]},
        \\  {"info":{"role":"assistant","id":"next"},"parts":[{"type":"tool","tool":"task","state":{"status":"running","title":"New task"}}]}
        \\]
    , .{});
    defer parsed.deinit();

    const summary = (try extractLatestAssistantTaskSummaryAlloc(allocator, parsed.value, "baseline")).?;
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("Running subtask: New task", summary);
}

test "findPrimaryAssistantAfterLastUser picks root assistant for latest user turn" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"info":{"role":"user","id":"u1","time":{"created":1}},"parts":[{"type":"text","text":"hi"}]},
        \\  {"info":{"role":"assistant","id":"root","time":{"created":2}},"parts":[{"type":"text","text":"main"}]},
        \\  {"info":{"role":"assistant","id":"sub","time":{"created":99}},"parts":[]}
        \\]
    , .{});
    defer parsed.deinit();

    const item = findPrimaryAssistantAfterLastUser(parsed.value) orelse return error.TestUnexpectedNull;
    const info_obj = getObjectField(item, "info") orelse return error.TestUnexpectedNull;
    const id = getOptionalObjectString(info_obj, "id") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("root", id);
}

test "appendSessionDiffFiles keeps nested patch bodies and derives counts" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"files":[{"file":{"path":"packages/desktop/src/ui/chat_panel.zig"},"diff":"@@ -1 +1 @@\n-old\n+new\n"}]}
    , .{});
    defer parsed.deinit();

    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);

    try appendSessionDiffFiles(parsed.value, &files);
    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expectEqualStrings("packages/desktop/src/ui/chat_panel.zig", files.items[0].path);
    try std.testing.expectEqual(@as(i64, 1), files.items[0].additions);
    try std.testing.expectEqual(@as(i64, 1), files.items[0].deletions);
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-old\n+new\n", files.items[0].patch.?);
}

test "parseConfiguredModelsAlloc reads configured providers and models" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "providers": [
        \\    {
        \\      "id": "openai",
        \\      "name": "OpenAI",
        \\      "models": {
        \\        "gpt-5.4": { "id": "gpt-5.4", "name": "GPT-5.4", "capabilities": { "reasoning": true }, "variants": { "high": {}, "low": {} } }
        \\      }
        \\    },
        \\    {
        \\      "id": "zen",
        \\      "name": "Zen",
        \\      "models": {
        \\        "gpt-5.4": { "id": "gpt-5.4", "name": "GPT-5.4" },
        \\        "sonnet": { "id": "sonnet", "name": "Claude Sonnet", "capabilities": { "reasoning": false } }
        \\      }
        \\    }
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    const models = try parseConfiguredModelsAlloc(allocator, parsed.value);
    defer provider_types.freeModelInfos(allocator, models);

    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("openai", models[0].provider_id);
    try std.testing.expectEqualStrings("OpenAI", models[0].provider_name);
    try std.testing.expectEqualStrings("gpt-5.4", models[0].model_id);
    try std.testing.expectEqualStrings("GPT-5.4", models[0].model_name);
    try std.testing.expect(models[0].reasoning_supported);
    try std.testing.expect(models[0].reasoning_variant_keys != null);
    try std.testing.expectEqual(@as(usize, 2), models[0].reasoning_variant_keys.?.len);
    try std.testing.expectEqualStrings("high", models[0].reasoning_variant_keys.?[0]);
    try std.testing.expectEqualStrings("low", models[0].reasoning_variant_keys.?[1]);
    try std.testing.expectEqualStrings("zen", models[1].provider_id);
    try std.testing.expectEqualStrings("Zen", models[1].provider_name);
    try std.testing.expect(models[1].reasoning_variant_keys == null);
    try std.testing.expectEqualStrings("zen", models[2].provider_id);
    try std.testing.expectEqualStrings("sonnet", models[2].model_id);
    try std.testing.expect(!models[2].reasoning_supported);
    try std.testing.expect(models[2].reasoning_variant_keys == null);
}

test "buildPromptBody prefers explicit opencode variant over reasoning effort" {
    const allocator = std.testing.allocator;
    const body = try buildPromptBody(allocator, .{
        .prompt = "hi",
        .model = "openai/gpt-5.4",
        .opencode_variant = "minimal",
        .reasoning_effort = .high,
    });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"variant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "minimal") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "high") == null);
}

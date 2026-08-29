//! OpenCode provider harness backed by the user's shared OpenCode 2 background service.
//!
//! OpenCode 2 runs one background service per user account. Verde never owns
//! that process: it discovers the registration the service writes to
//! `$XDG_STATE_HOME/opencode/service.json`, health-checks it with the
//! registered password, and only asks the CLI (`opencode2 service start`) to
//! bring one up when none is reachable. Every request is scoped to the
//! workspace through the `location[directory]` query parameter.

const std = @import("std");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");

const log = std.log.scoped(.native_opencode);

const MAX_HTTP_BODY_BYTES = 8 * 1024 * 1024;
const MAX_SERVICE_FILE_BYTES = 64 * 1024;
const MAX_ATTACHMENT_BYTES = 32 * 1024 * 1024;
/// `opencode2 service start` returns once the service is registered; a few
/// extra probes cover slow filesystems and the first health response.
const MAX_HEALTH_WAIT_ATTEMPTS = 30;
/// Health-probe receive deadline: long enough for a healthy local service under
/// load, short enough that a wedged service cannot hang startup or shutdown.
const HEALTH_PROBE_RECV_TIMEOUT_MS = 2_000;
const DEFAULT_SERVICE_USERNAME = "opencode";
const THREAD_LIST_LIMIT = 200;
const MESSAGE_POLL_LIMIT = 12;
const IMPORT_PAGE_LIMIT = 200;
const MAX_IMPORT_PAGES = 500;
const POLL_INTERVAL_MS: u64 = 150;
const MAX_POLL_ATTEMPTS = 24_000;
const EMPTY_IDLE_GRACE_POLLS: usize = 16;
/// Working-tree diffs run `git diff` inside the service; sample them every
/// ~1.5s instead of on every poll tick.
const DIFF_POLL_STRIDE: usize = 10;

fn sleepMs(ms: u64) void {
    platform_runtime.sleepMillis(ms);
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
    executable: []const u8 = "opencode2",
    /// Explicit server override. When null, Verde discovers the user's shared
    /// background service through its registration file.
    base_url: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    launch_if_missing: bool = false,
};

/// Serializes `service start` so concurrent clients do not race to launch.
var service_launch_mutex: Mutex = .{};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

/// Resolved connection details for one service; owned by the client.
const Endpoint = struct {
    base_url: []const u8,
    password: ?[]const u8,

    fn init(allocator: std.mem.Allocator, base_url: []const u8, password: ?[]const u8) !Endpoint {
        const owned_url = try allocator.dupe(u8, std.mem.trimEnd(u8, base_url, "/"));
        errdefer allocator.free(owned_url);
        const owned_password = if (password) |value| try allocator.dupe(u8, value) else null;
        return .{ .base_url = owned_url, .password = owned_password };
    }

    fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        if (self.password) |value| allocator.free(value);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    endpoint: Endpoint,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        const endpoint = try resolveEndpoint(allocator, config);
        return .{
            .allocator = allocator,
            .config = config,
            .endpoint = endpoint,
        };
    }

    pub fn deinit(self: *Client) void {
        self.endpoint.deinit(self.allocator);
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
        const path = try self.apiPathAlloc("/provider", .{}, null);
        defer self.allocator.free(path);
        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const providers = getObjectField(parsed.value, "data") orelse return .unknown;
        return switch (providers) {
            .array => |items| if (items.items.len > 0) .signed_in else .signed_out,
            else => .unknown,
        };
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        const query = try std.fmt.allocPrint(self.allocator, "limit={d}&order=desc", .{THREAD_LIST_LIMIT});
        defer self.allocator.free(query);
        const path = try self.apiPathAlloc("/session", .{}, query);
        defer self.allocator.free(path);
        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const sessions = getObjectField(parsed.value, "data") orelse return allocator.alloc(provider_types.ChatThreadSummary, 0);
        if (sessions != .array) return allocator.alloc(provider_types.ChatThreadSummary, 0);

        var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
        defer threads.deinit(allocator);

        for (sessions.array.items) |session_value| {
            if (session_value != .object) continue;
            if (!sessionMatchesWorkingDirectory(self.config.working_directory, sessionDirectory(session_value))) continue;

            const id = getOptionalObjectString(session_value, "id") orelse continue;
            const title = getOptionalObjectString(session_value, "title") orelse id;
            try threads.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .title = try allocator.dupe(u8, title),
            });
        }

        return threads.toOwnedSlice(allocator);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        const provider_path = try self.apiPathAlloc("/provider", .{}, null);
        defer self.allocator.free(provider_path);
        const provider_response = try self.requestJson(.GET, provider_path, null);
        defer self.allocator.free(provider_response.body);

        var parsed_providers: ?std.json.Parsed(std.json.Value) = null;
        defer if (parsed_providers) |*parsed| parsed.deinit();
        if (provider_response.status == .ok) {
            parsed_providers = try std.json.parseFromSlice(std.json.Value, self.allocator, provider_response.body, .{});
        }

        const model_path = try self.apiPathAlloc("/model", .{}, null);
        defer self.allocator.free(model_path);
        const response = try self.requestJson(.GET, model_path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        return parseModelsAlloc(allocator, parsed.value, if (parsed_providers) |p| p.value else null);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        const session_path = try self.apiPathAlloc("/session/{s}", .{thread_id}, null);
        defer self.allocator.free(session_path);
        const session_response = try self.requestJson(.GET, session_path, null);
        defer self.allocator.free(session_response.body);
        if (session_response.status != .ok) return error.OpencodeRequestFailed;

        var parsed_session = try std.json.parseFromSlice(std.json.Value, self.allocator, session_response.body, .{});
        defer parsed_session.deinit();

        const session_value = getObjectField(parsed_session.value, "data") orelse return error.MissingSessionId;
        const session_id = getOptionalObjectString(session_value, "id") orelse return error.MissingSessionId;
        const session_title = getOptionalObjectString(session_value, "title") orelse session_id;

        const imported_messages = try self.fetchAllMessagesAlloc(allocator, session_id);
        errdefer {
            for (imported_messages) |message| {
                allocator.free(message.author);
                allocator.free(message.body);
            }
            allocator.free(imported_messages);
        }

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
            try self.createSession(allocator, request);
        errdefer allocator.free(session_id);

        if (request.on_thread_id) |on_thread_id| {
            on_thread_id(request.stream_context, session_id);
        }

        if (request.thread_id != null) {
            if (request.thread_title) |thread_title| {
                try self.ensureSessionTitle(session_id, thread_title);
            }
            // The model lives on the session in v2, so re-apply the request's
            // selection before each turn on an existing thread.
            self.applySessionModel(session_id, request) catch |err| {
                log.warn("failed to apply OpenCode session model: {s}", .{@errorName(err)});
            };
        }

        const baseline_diff_payload = try self.fetchWorkingDiffPayloadAlloc();
        defer self.allocator.free(baseline_diff_payload);

        const event_stream = startEventStream(self, allocator, session_id, request) catch |err| blk: {
            log.warn("failed to start OpenCode event stream: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (event_stream) |handle| signalEventStreamStop(handle);

        const user_message_id = try self.submitPrompt(session_id, request);
        defer if (user_message_id) |id| self.allocator.free(id);

        const reply_text = try self.waitForPromptResult(
            allocator,
            session_id,
            user_message_id,
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
        const path = try self.apiPathAlloc("/session/{s}/interrupt", .{request.thread_id}, null);
        defer self.allocator.free(path);

        const response = try self.requestJson(.POST, path, "{}");
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

    fn createSession(self: *Client, allocator: std.mem.Allocator, request: provider_types.SendPromptRequest) ![]u8 {
        const body = try buildSessionCreateBody(self.allocator, request.thread_title, self.config.working_directory, request);
        defer self.allocator.free(body);

        const path = try self.apiPathAlloc("/session", .{}, null);
        defer self.allocator.free(path);
        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);
        if (response.status != .ok and response.status != .created) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const session = getObjectField(parsed.value, "data") orelse return error.MissingSessionId;
        const id = getOptionalObjectString(session, "id") orelse return error.MissingSessionId;
        return allocator.dupe(u8, id);
    }

    fn ensureSessionTitle(self: *Client, session_id: []const u8, title: []const u8) !void {
        const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        const path = try self.apiPathAlloc("/session/{s}/rename", .{session_id}, null);
        defer self.allocator.free(path);

        const body = try stringifyAlloc(self.allocator, .{ .title = trimmed });
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    fn applySessionModel(self: *Client, session_id: []const u8, request: provider_types.SendPromptRequest) !void {
        if (request.model == null) return;

        const path = try self.apiPathAlloc("/session/{s}/model", .{session_id}, null);
        defer self.allocator.free(path);

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try stringify.beginObject();
        try stringify.objectField("model");
        try writeModelRef(&stringify, request);
        try stringify.endObject();

        const response = try self.requestJson(.POST, path, writer.written());
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    /// Enqueues the prompt and returns the id of the user message it created,
    /// which anchors the assistant reply lookup for this turn.
    fn submitPrompt(self: *Client, session_id: []const u8, request: provider_types.SendPromptRequest) !?[]u8 {
        const path = try self.apiPathAlloc("/session/{s}/prompt", .{session_id}, null);
        defer self.allocator.free(path);

        const body = try buildPromptBody(self.allocator, request);
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);

        if (response.status == .conflict) return error.OpencodeSessionBusy;
        if (response.status != .ok and response.status != .created and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
        if (response.body.len == 0) return null;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{}) catch return null;
        defer parsed.deinit();
        const data = getObjectField(parsed.value, "data") orelse return null;
        const id = getOptionalObjectString(data, "id") orelse return null;
        return try self.allocator.dupe(u8, id);
    }

    fn waitForPromptResult(
        self: *Client,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        user_message_id: ?[]const u8,
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

        var attempt: usize = 0;
        while (attempt < MAX_POLL_ATTEMPTS) : (attempt += 1) {
            const has_pending_permissions = try self.handlePendingPermissions(session_id, request, &handled_permission_ids);
            var latest_snapshot = try self.fetchAssistantSnapshot(self.allocator, session_id, user_message_id);
            defer latest_snapshot.deinit(self.allocator);

            const stream_terminal = if (event_stream_context) |context| eventStreamReachedTerminal(context) else false;
            if (event_stream_context) |context| {
                try self.syncStreamedTextFromEventStream(context, &streamed_text);
            } else {
                try self.emitTaskProgressFromSnapshot(&latest_snapshot, request, &last_task_summary);
                try self.emitAssistantProgressFromSnapshot(&latest_snapshot, request, &streamed_text);
            }
            if (attempt % DIFF_POLL_STRIDE == 0) {
                try self.emitDiffProgress(request, baseline_diff_payload, &last_diff_payload);
            }

            const has_output_activity =
                std.mem.trim(u8, streamed_text, &std.ascii.whitespace).len > 0 or
                latest_snapshot.hasRenderableContent();

            if (!has_pending_permissions and (stream_terminal or latest_snapshot.isTerminalForPrompt())) {
                break;
            }

            if (!has_pending_permissions and event_stream_context == null) {
                const active = try self.sessionIsActive(session_id);
                if (!active and has_output_activity) break;
                if (!active and attempt + 1 >= EMPTY_IDLE_GRACE_POLLS) return error.OpencodeEmptyReply;
            }

            sleepMs(POLL_INTERVAL_MS);
        } else {
            return error.OpencodeRequestTimedOut;
        }

        try self.emitDiffProgress(request, baseline_diff_payload, &last_diff_payload);

        var final_snapshot = try self.fetchAssistantSnapshot(allocator, session_id, user_message_id);
        defer final_snapshot.deinit(allocator);

        if (std.mem.trim(u8, final_snapshot.text, &std.ascii.whitespace).len > 0) {
            return allocator.dupe(u8, final_snapshot.text);
        }
        if (final_snapshot.error_message) |error_message| {
            return allocator.dupe(u8, error_message);
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

        const parsed_task = parseOpenCodeTaskSummary(summary);
        on_stream_event(request.stream_context, .{ .tool_call = .{
            .call_id = "opencode-task",
            .title = parsed_task.title,
            .kind = .subagent,
            .status = parsed_task.status,
            .input = summary,
        } });
        last_task_summary.* = try self.allocator.dupe(u8, summary);
    }

    fn emitAssistantProgressFromSnapshot(
        self: *Client,
        snapshot: *const AssistantSnapshot,
        request: provider_types.SendPromptRequest,
        streamed_text: *[]u8,
    ) !void {
        const on_stream_delta = request.on_stream_delta orelse return;
        if (snapshot.message_id == null) return;

        if (!std.mem.startsWith(u8, snapshot.text, streamed_text.*)) return;
        const delta = snapshot.text[streamed_text.*.len..];
        if (delta.len == 0) return;

        on_stream_delta(request.stream_context, delta);

        self.allocator.free(streamed_text.*);
        streamed_text.* = try self.allocator.dupe(u8, snapshot.text);
    }

    fn emitDiffProgress(
        self: *Client,
        request: provider_types.SendPromptRequest,
        baseline_diff_payload: []const u8,
        last_diff_payload: *[]u8,
    ) !void {
        const on_stream_event = request.on_stream_event orelse return;

        const current_payload = try self.fetchWorkingDiffPayloadAlloc();
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

        if (changed_files.items.len > 0) {
            on_stream_event(request.stream_context, .{ .diff = .{
                .files = changed_files.items,
            } });
        }

        self.allocator.free(last_diff_payload.*);
        last_diff_payload.* = try self.allocator.dupe(u8, current_payload);
    }

    /// v2 has no per-session diff; the working-tree diff scoped to the
    /// workspace is the closest signal for edits made during a turn.
    fn fetchWorkingDiffPayloadAlloc(self: *Client) ![]u8 {
        if (self.config.working_directory == null) return self.allocator.dupe(u8, "");

        const path = try self.apiPathAlloc("/vcs/diff", .{}, "mode=working");
        defer self.allocator.free(path);

        const response = self.requestJson(.GET, path, null) catch return self.allocator.dupe(u8, "");
        defer self.allocator.free(response.body);

        if (response.status != .ok) return self.allocator.dupe(u8, "");
        return self.allocator.dupe(u8, response.body);
    }

    fn handlePendingPermissions(
        self: *Client,
        session_id: []const u8,
        request: provider_types.SendPromptRequest,
        handled_permission_ids: *std.ArrayList([]u8),
    ) !bool {
        const path = try self.apiPathAlloc("/session/{s}/permission", .{session_id}, null);
        defer self.allocator.free(path);
        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return false;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const pending = getObjectField(parsed.value, "data") orelse return false;
        if (pending != .array) return false;

        var found_pending_for_session = false;
        for (pending.array.items) |item| {
            if (item != .object) continue;
            if (getOptionalObjectString(item, "sessionID")) |pending_session_id| {
                if (!std.mem.eql(u8, pending_session_id, session_id)) continue;
            }

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
        const action = getOptionalObjectString(value, "action") orelse "permission";
        const title = try std.fmt.allocPrint(self.allocator, "OpenCode wants {s} permission", .{action});
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

        const body = try stringifyAlloc(self.allocator, .{ .reply = reply });
        defer self.allocator.free(body);

        const path = try self.apiPathAlloc("/session/{s}/permission/{s}/reply", .{ session_id, request_id }, null);
        defer self.allocator.free(path);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .no_content) {
            return error.OpencodeRequestFailed;
        }
    }

    fn fetchAssistantSnapshot(
        self: *Client,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        user_message_id: ?[]const u8,
    ) !AssistantSnapshot {
        const query = try std.fmt.allocPrint(self.allocator, "order=desc&limit={d}", .{MESSAGE_POLL_LIMIT});
        defer self.allocator.free(query);
        const path = try self.apiPathAlloc("/session/{s}/message", .{session_id}, query);
        defer self.allocator.free(path);

        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const messages = getObjectField(parsed.value, "data") orelse .null;
        const latest = findPrimaryAssistantAfterUser(messages, user_message_id) orelse return .{
            .text = try allocator.dupe(u8, ""),
        };
        const message_id = getOptionalObjectString(latest, "id");

        return .{
            .message_id = if (message_id) |id| try allocator.dupe(u8, id) else null,
            .text = try extractAssistantTextAlloc(allocator, latest),
            .error_message = try extractAssistantErrorMessageAlloc(allocator, latest),
            .finish = try extractAssistantFinishAlloc(allocator, latest),
            .task_summary = try extractLatestAssistantTaskSummaryAlloc(allocator, messages, user_message_id),
        };
    }

    fn sessionIsActive(self: *Client, session_id: []const u8) !bool {
        const path = try self.apiPathAlloc("/session/active", .{}, null);
        defer self.allocator.free(path);
        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return error.OpencodeRequestFailed;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();

        const active = getObjectField(parsed.value, "data") orelse return false;
        if (active != .object) return false;
        return active.object.get(session_id) != null;
    }

    fn fetchAllMessagesAlloc(self: *Client, allocator: std.mem.Allocator, session_id: []const u8) ![]provider_types.ChatMessage {
        var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
        errdefer {
            for (messages.items) |message| {
                allocator.free(message.author);
                allocator.free(message.body);
            }
            messages.deinit(allocator);
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);

        var page: usize = 0;
        while (page < MAX_IMPORT_PAGES) : (page += 1) {
            var query: std.ArrayList(u8) = .empty;
            defer query.deinit(self.allocator);
            try query.appendSlice(self.allocator, "order=asc&limit=");
            try appendDecimal(&query, self.allocator, IMPORT_PAGE_LIMIT);
            if (cursor) |value| {
                try query.appendSlice(self.allocator, "&cursor=");
                try appendPercentEncoded(&query, self.allocator, value);
            }

            const path = try self.apiPathAlloc("/session/{s}/message", .{session_id}, query.items);
            defer self.allocator.free(path);
            const response = try self.requestJson(.GET, path, null);
            defer self.allocator.free(response.body);
            if (response.status != .ok) return error.OpencodeRequestFailed;

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
            defer parsed.deinit();

            try appendImportedApiMessages(allocator, &messages, getObjectField(parsed.value, "data") orelse .null);

            const next = blk: {
                const cursor_value = getObjectField(parsed.value, "cursor") orelse break :blk null;
                break :blk getOptionalObjectString(cursor_value, "next");
            };
            if (cursor) |value| self.allocator.free(value);
            cursor = null;
            const next_cursor = next orelse break;
            if (next_cursor.len == 0) break;
            cursor = try self.allocator.dupe(u8, next_cursor);
        }

        return messages.toOwnedSlice(allocator);
    }

    /// Builds `/api{path}` with the workspace `location[directory]` scope and
    /// any extra query string. v2 ignores a bare `directory` parameter, so the
    /// bracketed form is the only way to scope requests.
    fn apiPathAlloc(self: *Client, comptime path_fmt: []const u8, args: anytype, extra_query: ?[]const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, "/api");
        const path = try std.fmt.allocPrint(self.allocator, path_fmt, args);
        defer self.allocator.free(path);
        try out.appendSlice(self.allocator, path);

        var separator: u8 = '?';
        if (self.config.working_directory) |directory| {
            try out.append(self.allocator, separator);
            try out.appendSlice(self.allocator, "location%5Bdirectory%5D=");
            try appendPercentEncoded(&out, self.allocator, directory);
            separator = '&';
        }
        if (extra_query) |query| {
            if (query.len > 0) {
                try out.append(self.allocator, separator);
                try out.appendSlice(self.allocator, query);
            }
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn requestJson(
        self: *Client,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.endpoint.base_url, path });
        defer self.allocator.free(url);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        const auth_header = try makeAuthorizationHeaderAlloc(self.allocator, self.config.username, self.endpoint.password);
        defer if (auth_header) |header| self.allocator.free(header.value);

        var headers_storage: [2]std.http.Header = undefined;
        var header_count: usize = 0;
        if (payload != null) {
            headers_storage[header_count] = .{ .name = "content-type", .value = "application/json" };
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
};

// Service discovery -----------------------------------------------------------

const ServiceRegistration = struct {
    url: []u8,
    password: ?[]u8,

    fn deinit(self: *ServiceRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.password) |value| allocator.free(value);
    }
};

fn resolveEndpoint(allocator: std.mem.Allocator, config: Config) !Endpoint {
    if (config.base_url) |base_url| {
        var endpoint = try Endpoint.init(allocator, base_url, config.password);
        errdefer endpoint.deinit(allocator);
        if (!checkHealth(allocator, endpoint.base_url, config.username, endpoint.password)) {
            return error.OpencodeServerUnavailable;
        }
        return endpoint;
    }

    if (try discoverHealthyService(allocator, config)) |endpoint| return endpoint;
    if (!config.launch_if_missing) return error.OpencodeServerUnavailable;

    service_launch_mutex.lock();
    defer service_launch_mutex.unlock();

    if (try discoverHealthyService(allocator, config)) |endpoint| return endpoint;

    try startBackgroundService(allocator, config);

    var attempt: usize = 0;
    while (attempt < MAX_HEALTH_WAIT_ATTEMPTS) : (attempt += 1) {
        if (try discoverHealthyService(allocator, config)) |endpoint| return endpoint;
        sleepMs(200);
    }
    return error.OpencodeServerUnavailable;
}

fn discoverHealthyService(allocator: std.mem.Allocator, config: Config) !?Endpoint {
    var registration = (readServiceRegistrationAlloc(allocator) catch |err| {
        log.debug("opencode service registration unreadable: {s}", .{@errorName(err)});
        return null;
    }) orelse return null;
    defer registration.deinit(allocator);

    var endpoint = try Endpoint.init(allocator, registration.url, registration.password);
    errdefer endpoint.deinit(allocator);
    if (!checkHealth(allocator, endpoint.base_url, config.username, endpoint.password)) {
        endpoint.deinit(allocator);
        return null;
    }
    return endpoint;
}

/// `service start` daemonizes the shared service itself and exits once the
/// registration file is written, so waiting for the CLI is bounded.
fn startBackgroundService(allocator: std.mem.Allocator, config: Config) !void {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    const executable = try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, config.executable);
    defer allocator.free(executable);

    const argv = [_][]const u8{ executable, "service", "start" };

    var threaded_spawn = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_spawn.deinit();
    var child = try platform_process.spawn(allocator, threaded_spawn.io(), .{
        .argv = argv[0..],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .environ_map = &env_map,
        // The service must outlive Verde; keep it out of any Verde-owned tree.
        .own_process_tree = false,
    });
    const term = try child.wait(threaded_spawn.io());
    switch (term) {
        .exited => |code| if (code != 0) {
            log.warn("opencode2 service start exited with code {d}", .{code});
        },
        else => log.warn("opencode2 service start ended abnormally", .{}),
    }
}

fn serviceRegistrationPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |raw| {
        const state_home = std.mem.sliceTo(raw, 0);
        if (state_home.len > 0) {
            return std.fs.path.join(allocator, &.{ state_home, "opencode", "service.json" });
        }
    }
    const home_raw = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    const home = std.mem.sliceTo(home_raw, 0);
    if (home.len == 0) return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "opencode", "service.json" });
}

fn readServiceRegistrationAlloc(allocator: std.mem.Allocator) !?ServiceRegistration {
    const path = try serviceRegistrationPathAlloc(allocator);
    defer allocator.free(path);

    var threaded = std.Io.Threaded.init_single_threaded;
    const contents = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(MAX_SERVICE_FILE_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(contents);

    return try parseServiceRegistrationAlloc(allocator, contents);
}

fn parseServiceRegistrationAlloc(allocator: std.mem.Allocator, contents: []const u8) !?ServiceRegistration {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const url = getOptionalObjectString(parsed.value, "url") orelse return null;
    if (std.mem.trim(u8, url, &std.ascii.whitespace).len == 0) return null;
    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);
    const password = getOptionalObjectString(parsed.value, "password");
    return .{
        .url = owned_url,
        .password = if (password) |value| try allocator.dupe(u8, value) else null,
    };
}

// Health probes must complete in bounded time. A wedged server that accepts
// TCP but never answers (observed live 2026-07-15) previously blocked forever
// inside std.http.Client.fetch — which has no read timeout — hanging the
// provider-readiness worker and app shutdown, which joins that worker. So the
// probe speaks minimal HTTP/1.1 over a stream raced against a std.Io timeout.
fn checkHealth(allocator: std.mem.Allocator, base_url: []const u8, username: ?[]const u8, password: ?[]const u8) bool {
    return probeHealthBounded(allocator, base_url, username, password) catch |err| {
        log.debug("opencode health probe failed: {s}", .{@errorName(err)});
        return false;
    };
}

fn probeHealthBounded(allocator: std.mem.Allocator, base_url: []const u8, username: ?[]const u8, password: ?[]const u8) !bool {
    const uri = try std.Uri.parse(base_url);
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buffer);
    const port: u16 = uri.port orelse 80;

    // The service registers a literal loopback address; a hostname needing
    // DNS is never expected, so report unhealthy rather than fall back to an
    // unbounded fetch.
    const address = try std.Io.net.IpAddress.parse(host.bytes, port);

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Threaded Io has no connect-timeout support yet. Loopback connects
    // resolve immediately (accept or ECONNREFUSED), so the receive timeout
    // below is the guard that matters for a live-but-stuck service.
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    const auth_header = try makeAuthorizationHeaderAlloc(allocator, username, password);
    defer if (auth_header) |header| allocator.free(header.value);
    const request = if (auth_header) |header|
        try std.fmt.allocPrint(
            allocator,
            "GET /api/health HTTP/1.1\r\nHost: {s}:{d}\r\n{s}: {s}\r\nConnection: close\r\n\r\n",
            .{ host.bytes, port, header.name, header.value },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "GET /api/health HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
            .{ host.bytes, port },
        );
    defer allocator.free(request);

    try streamWriteAllWithIo(io, stream, request);

    // Only the status line matters; 128 bytes is ample for
    // "HTTP/1.1 200 OK\r\n" plus slack for unusual reason phrases.
    const Event = union(enum) {
        read: std.Io.net.Stream.Reader.Error!usize,
        timeout: std.Io.Cancelable!void,
    };
    var response_buffer: [128]u8 = undefined;
    var result_buffer: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &result_buffer);
    defer select.cancelDiscard();

    var filled: usize = 0;
    try select.concurrent(.read, streamReadSomeWithIo, .{ io, stream, response_buffer[filled..] });
    try select.concurrent(.timeout, std.Io.sleep, .{
        io,
        std.Io.Duration.fromMilliseconds(HEALTH_PROBE_RECV_TIMEOUT_MS),
        std.Io.Clock.awake,
    });
    while (filled < response_buffer.len) {
        switch (try select.await()) {
            .read => |result| {
                const read_len = try result;
                if (read_len == 0) break;
                filled += read_len;
                if (std.mem.indexOf(u8, response_buffer[0..filled], "\r\n") != null) break;
                try select.concurrent(.read, streamReadSomeWithIo, .{ io, stream, response_buffer[filled..] });
            },
            .timeout => |result| {
                try result;
                return false;
            },
        }
    }
    return statusLineIsOk(response_buffer[0..filled]);
}

// Shared types and helpers ----------------------------------------------------

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
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

    fn isTerminalForPrompt(self: *const AssistantSnapshot) bool {
        if (self.message_id == null) return false;
        const finish = self.finish orelse return false;
        return !std.mem.eql(u8, finish, "tool-calls") and !std.mem.eql(u8, finish, "unknown");
    }

    fn hasRenderableContent(self: *const AssistantSnapshot) bool {
        if (self.message_id == null) return false;
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
    base_url: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    working_directory: ?[]const u8,
    session_id: []u8,
    request: provider_types.SendPromptRequest,
    child: ?platform_process.OwnedChild = null,
    streamed_text: std.ArrayListUnmanaged(u8) = .empty,
    /// callID → tool name, so success/failure events can be titled and classified.
    tool_names: std.StringHashMapUnmanaged([]u8) = .empty,
    mutex: Mutex = .{},
    condition: Condition = .{},
    open_state: EventStreamOpenState = .starting,
    stop_requested: bool = false,
    session_terminal: bool = false,

    fn deinit(self: *EventStreamContext) void {
        self.allocator.free(self.session_id);
        self.streamed_text.deinit(self.allocator);
        var it = self.tool_names.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tool_names.deinit(self.allocator);
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

fn appendDecimal(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var buffer: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try list.appendSlice(allocator, text);
}

/// RFC 3986 unreserved characters pass through; everything else is `%XX`.
fn appendPercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    const HEX = "0123456789ABCDEF";
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try list.append(allocator, byte);
        } else {
            try list.appendSlice(allocator, &.{ '%', HEX[byte >> 4], HEX[byte & 0x0F] });
        }
    }
}

fn streamReadSomeWithIo(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) std.Io.net.Stream.Reader.Error!usize {
    var reader_buffer: [0]u8 = .{};
    var reader = stream.reader(io, &reader_buffer);
    var buffers: [1][]u8 = .{buffer};
    return reader.interface.readVec(&buffers) catch |err| switch (err) {
        error.EndOfStream => 0,
        error.ReadFailed => reader.err orelse error.Unexpected,
    };
}

fn streamWriteAllWithIo(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readEventStreamLine(reader: *std.Io.Reader, line_writer: *std.Io.Writer.Allocating, max_line_bytes: usize) !?[]const u8 {
    line_writer.clearRetainingCapacity();
    const line_len = try reader.streamDelimiterLimit(&line_writer.writer, '\n', .limited(max_line_bytes));
    const next = reader.peekByte() catch |err| switch (err) {
        error.EndOfStream => return if (line_len == 0) null else line_writer.written(),
        else => |read_err| return read_err,
    };
    std.debug.assert(next == '\n');
    reader.toss(1);
    return line_writer.written();
}

fn discardEventStreamLineRemainder(reader: *std.Io.Reader) !bool {
    _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return false,
        else => |read_err| return read_err,
    };
    return true;
}

// Accepts any HTTP version ("HTTP/1.1 200 OK", "HTTP/1.0 200 ...").
fn statusLineIsOk(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "HTTP/")) return false;
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    if (line.len < space + 4) return false;
    return std.mem.eql(u8, line[space + 1 .. space + 4], "200");
}

fn makeAuthorizationHeaderAlloc(allocator: std.mem.Allocator, username: ?[]const u8, password: ?[]const u8) !?std.http.Header {
    const actual_password = password orelse return null;
    const actual_username = username orelse DEFAULT_SERVICE_USERNAME;
    const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ actual_username, actual_password });
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

fn jsonBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    return switch (actual) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn normalizeUnixTimestamp(value: ?i64) ?i64 {
    const timestamp = value orelse return null;
    if (timestamp >= 1_000_000_000_000) return @divFloor(timestamp, 1000);
    return timestamp;
}

fn messageType(value: std.json.Value) ?[]const u8 {
    return getOptionalObjectString(value, "type");
}

fn messageIs(value: std.json.Value, kind: []const u8) bool {
    const type_name = messageType(value) orelse return false;
    return std.mem.eql(u8, type_name, kind);
}

// Thread import ---------------------------------------------------------------

fn appendImportedApiMessages(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(provider_types.ChatMessage),
    value: std.json.Value,
) !void {
    if (value != .array) return;

    for (value.array.items) |item| {
        if (item != .object) continue;
        const role = parseImportedApiMessageRole(item) orelse continue;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        switch (role) {
            .user => try appendImportedUserText(allocator, &body, item),
            .assistant => try appendImportedAssistantText(allocator, &body, item),
            .system => {},
        }

        const trimmed = std.mem.trim(u8, body.items, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        try messages.append(allocator, .{
            .role = role,
            .author = try allocator.dupe(u8, importedAuthorForRole(role)),
            .body = try allocator.dupe(u8, trimmed),
        });
    }
}

fn parseImportedApiMessageRole(item: std.json.Value) ?provider_types.MessageRole {
    const type_name = messageType(item) orelse return null;
    if (std.mem.eql(u8, type_name, "user")) return .user;
    if (std.mem.eql(u8, type_name, "assistant")) return .assistant;
    return null;
}

fn importedAuthorForRole(role: provider_types.MessageRole) []const u8 {
    return switch (role) {
        .user => "You",
        .assistant => "OpenCode",
        .system => "System",
    };
}

fn appendImportedUserText(allocator: std.mem.Allocator, body: *std.ArrayList(u8), item: std.json.Value) !void {
    const text = getOptionalObjectString(item, "text") orelse blk: {
        const payload = getObjectField(item, "payload") orelse break :blk null;
        break :blk getOptionalObjectString(payload, "text");
    };
    if (text) |value| try appendImportedBodySegment(allocator, body, value);

    const files = getObjectField(item, "files") orelse return;
    if (files != .array) return;
    for (files.array.items) |file| {
        const name = getOptionalObjectString(file, "name") orelse blk: {
            const source = getObjectField(file, "source") orelse break :blk null;
            break :blk getOptionalObjectString(source, "uri");
        } orelse continue;
        try appendImportedBodySegment(allocator, body, name);
    }
}

fn appendImportedAssistantText(allocator: std.mem.Allocator, body: *std.ArrayList(u8), item: std.json.Value) !void {
    const text = try extractAssistantTextAlloc(allocator, item);
    defer allocator.free(text);
    try appendImportedBodySegment(allocator, body, text);
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

fn extractSessionUpdatedAt(value: std.json.Value) ?i64 {
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

fn sessionDirectory(session_value: std.json.Value) ?[]const u8 {
    const location = getObjectField(session_value, "location") orelse return null;
    return getOptionalObjectString(location, "directory");
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

// Models ----------------------------------------------------------------------

/// Parses `GET /api/model` (`{data: [Model.Info]}`); `providers_root` is the
/// optional `GET /api/provider` body used for display names.
fn parseModelsAlloc(allocator: std.mem.Allocator, root: std.json.Value, providers_root: ?std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    const list = getObjectField(root, "data") orelse root;
    if (list != .array) return models.toOwnedSlice(allocator);

    for (list.array.items) |model_value| {
        if (model_value != .object) continue;
        if (jsonBool(getObjectField(model_value, "enabled")) == false) continue;

        const provider_id = getOptionalObjectString(model_value, "providerID") orelse continue;
        const model_id = getOptionalObjectString(model_value, "modelID") orelse
            getOptionalObjectString(model_value, "id") orelse continue;
        const model_name = getOptionalObjectString(model_value, "name") orelse model_id;
        const provider_name = providerNameFor(providers_root, provider_id) orelse provider_id;

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
            // v2 exposes reasoning control only through named variants.
            .reasoning_supported = variant_keys != null,
            .reasoning_variant_keys = variant_keys,
        });
    }

    return models.toOwnedSlice(allocator);
}

fn providerNameFor(providers_root: ?std.json.Value, provider_id: []const u8) ?[]const u8 {
    const root = providers_root orelse return null;
    const list = getObjectField(root, "data") orelse root;
    if (list != .array) return null;
    for (list.array.items) |provider| {
        const id = getOptionalObjectString(provider, "id") orelse continue;
        if (!std.mem.eql(u8, id, provider_id)) continue;
        return getOptionalObjectString(provider, "name");
    }
    return null;
}

fn collectVariantKeysSortedAlloc(allocator: std.mem.Allocator, model_value: std.json.Value) !?[][:0]const u8 {
    const variants = getObjectField(model_value, "variants") orelse return null;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    switch (variants) {
        .array => |items| for (items.items) |variant| {
            const id = switch (variant) {
                .string => |text| text,
                .object => getOptionalObjectString(variant, "id") orelse continue,
                else => continue,
            };
            try names.append(allocator, id);
        },
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try names.append(allocator, entry.key_ptr.*);
        },
        else => return null,
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

// Assistant messages ----------------------------------------------------------

fn extractAssistantTextAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const content = getObjectField(value, "content") orelse return allocator.dupe(u8, "");
    if (content != .array) return allocator.dupe(u8, "");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    for (content.array.items) |part| {
        if (part != .object) continue;
        const type_name = getOptionalObjectString(part, "type") orelse continue;
        if (!std.mem.eql(u8, type_name, "text")) continue;
        const chunk = getOptionalObjectString(part, "text") orelse "";
        try text.appendSlice(allocator, chunk);
    }

    return text.toOwnedSlice(allocator);
}

fn extractAssistantErrorMessageAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const error_value = getObjectField(value, "error") orelse return null;
    const message = switch (error_value) {
        .string => |text| text,
        .object => getOptionalObjectString(error_value, "message") orelse return null,
        else => return null,
    };
    return try allocator.dupe(u8, message);
}

fn extractAssistantFinishAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const finish = getOptionalObjectString(value, "finish") orelse return null;
    return try allocator.dupe(u8, finish);
}

fn parseOpenCodeTaskSummary(summary: []const u8) struct { title: []const u8, status: provider_types.ToolCallStatus } {
    if (std.mem.startsWith(u8, summary, "Running subtask: ")) {
        return .{ .title = summary["Running subtask: ".len..], .status = .in_progress };
    }
    if (std.mem.startsWith(u8, summary, "Completed subtask: ")) {
        return .{ .title = summary["Completed subtask: ".len..], .status = .completed };
    }
    if (std.mem.startsWith(u8, summary, "Failed subtask: ")) {
        return .{ .title = summary["Failed subtask: ".len..], .status = .failed };
    }
    if (std.mem.indexOf(u8, summary, " subtask: ")) |index| {
        return .{ .title = summary[index + " subtask: ".len ..], .status = .unknown };
    }
    return .{ .title = summary, .status = .unknown };
}

/// Scans the newest-first message window for the latest assistant step after
/// the anchoring user message and summarizes its subagent tool state.
fn extractLatestAssistantTaskSummaryAlloc(
    allocator: std.mem.Allocator,
    messages_desc: std.json.Value,
    user_message_id: ?[]const u8,
) !?[]u8 {
    if (messages_desc != .array) return null;
    const boundary = findUserBoundary(messages_desc.array.items, user_message_id);

    for (messages_desc.array.items[0..boundary]) |item| {
        if (!messageIs(item, "assistant")) continue;
        if (try extractAssistantTaskSummaryAlloc(allocator, item)) |summary| {
            return summary;
        }
    }

    return null;
}

fn extractAssistantTaskSummaryAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const content = getObjectField(value, "content") orelse return null;
    if (content != .array) return null;

    var index = content.array.items.len;
    while (index > 0) {
        index -= 1;
        const part = content.array.items[index];
        if (part != .object) continue;
        const part_type = getOptionalObjectString(part, "type") orelse continue;
        if (!std.mem.eql(u8, part_type, "tool")) continue;
        const tool_name = getOptionalObjectString(part, "name") orelse continue;
        if (!provider_types.isSubagentToolName(tool_name)) continue;

        const state = getObjectField(part, "state") orelse continue;
        const status = getOptionalObjectString(state, "status") orelse continue;
        const title = openCodeTaskTitle(getObjectField(state, "input") orelse .null, "OpenCode task");

        if (std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "streaming")) {
            return try std.fmt.allocPrint(allocator, "Running subtask: {s}", .{title});
        }
        if (std.mem.eql(u8, status, "completed")) {
            return try std.fmt.allocPrint(allocator, "Completed subtask: {s}", .{title});
        }
        if (std.mem.eql(u8, status, "error")) {
            return try std.fmt.allocPrint(allocator, "Failed subtask: {s}", .{title});
        }

        return try std.fmt.allocPrint(allocator, "{s} subtask: {s}", .{ status, title });
    }

    return null;
}

/// Index of the anchoring user message in a newest-first window: the message
/// with `user_message_id`, else the newest user message. When the anchor has
/// already scrolled out of the window, every message in it belongs to the turn.
fn findUserBoundary(items_desc: []const std.json.Value, user_message_id: ?[]const u8) usize {
    for (items_desc, 0..) |item, index| {
        if (!messageIs(item, "user")) continue;
        if (user_message_id) |wanted| {
            const id = getOptionalObjectString(item, "id") orelse continue;
            if (std.mem.eql(u8, id, wanted)) return index;
        } else {
            return index;
        }
    }
    return items_desc.len;
}

/// OpenCode creates one assistant message per model step. Prefer the latest
/// visible or terminal step for the current turn while retaining the first
/// step as an in-flight fallback. `messages_desc` is newest-first.
fn findPrimaryAssistantAfterUser(messages_desc: std.json.Value, user_message_id: ?[]const u8) ?std.json.Value {
    if (messages_desc != .array) return null;
    const items = messages_desc.array.items;
    const boundary = findUserBoundary(items, user_message_id);

    var first_assistant: ?std.json.Value = null;
    var reply_assistant: ?std.json.Value = null;
    var index = boundary;
    while (index > 0) {
        index -= 1;
        const item = items[index];
        if (!messageIs(item, "assistant")) continue;

        if (first_assistant == null) first_assistant = item;
        if (assistantMessageHasVisibleText(item) or assistantMessageIsTerminal(item) or assistantMessageHasError(item)) {
            reply_assistant = item;
        }
    }

    return reply_assistant orelse first_assistant;
}

fn assistantMessageHasVisibleText(value: std.json.Value) bool {
    const content = getObjectField(value, "content") orelse return false;
    if (content != .array) return false;
    for (content.array.items) |part| {
        if (part != .object) continue;
        const part_type = getOptionalObjectString(part, "type") orelse continue;
        if (!std.mem.eql(u8, part_type, "text")) continue;
        const text = getOptionalObjectString(part, "text") orelse continue;
        if (std.mem.trim(u8, text, &std.ascii.whitespace).len > 0) return true;
    }
    return false;
}

fn assistantMessageIsTerminal(value: std.json.Value) bool {
    const finish = getOptionalObjectString(value, "finish") orelse return false;
    return !std.mem.eql(u8, finish, "tool-calls") and !std.mem.eql(u8, finish, "unknown");
}

fn assistantMessageHasError(value: std.json.Value) bool {
    const error_value = getObjectField(value, "error") orelse return false;
    return error_value != .null;
}

// Event stream ----------------------------------------------------------------

fn startEventStream(self: *Client, allocator: std.mem.Allocator, session_id: []const u8, request: provider_types.SendPromptRequest) !?EventStreamHandle {
    if (request.on_stream_delta == null and request.on_stream_event == null) return null;

    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);

    const context = try allocator.create(EventStreamContext);
    errdefer allocator.destroy(context);

    context.* = .{
        .allocator = allocator,
        .base_url = self.endpoint.base_url,
        .username = self.config.username,
        .password = self.endpoint.password,
        .working_directory = self.config.working_directory,
        .session_id = owned_session_id,
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

fn eventStreamUrlAlloc(context: *EventStreamContext) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(context.allocator);
    try url.appendSlice(context.allocator, context.base_url);
    try url.appendSlice(context.allocator, "/api/event");
    if (context.working_directory) |directory| {
        try url.appendSlice(context.allocator, "?location%5Bdirectory%5D=");
        try appendPercentEncoded(&url, context.allocator, directory);
    }
    return url.toOwnedSlice(context.allocator);
}

fn streamSessionEvents(context: *EventStreamContext) !void {
    var env_map = try process_env.buildAugmentedEnvMap(context.allocator);
    defer env_map.deinit();

    const curl_executable = try process_env.resolveExecutableInEnvMapAlloc(context.allocator, &env_map, "curl");
    defer context.allocator.free(curl_executable);

    var opened = false;
    errdefer if (!opened) signalEventStreamOpenState(context, .failed);

    const url = try eventStreamUrlAlloc(context);
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
    if (try makeAuthorizationHeaderAlloc(context.allocator, context.username, context.password)) |header| {
        defer context.allocator.free(header.value);
        owned_auth_header = try std.fmt.allocPrint(context.allocator, "{s}: {s}", .{ header.name, header.value });
        try argv.appendSlice(context.allocator, &.{ "-H", owned_auth_header.? });
    }

    try argv.append(context.allocator, url);

    var threaded_spawn = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_spawn.deinit();
    const child = try platform_process.spawn(context.allocator, threaded_spawn.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = &env_map,
    });

    const stdout = child.child.stdout.?;
    context.mutex.lock();
    context.child = child;
    context.mutex.unlock();
    defer cleanupEventStreamChild(context);

    log.info("OpenCode event stream started session_len={d} pid={d}", .{ context.session_id.len, child.processId() orelse 0 });

    opened = true;
    signalEventStreamOpenState(context, .ready);

    var read_buffer: [64 * 1024]u8 = undefined;
    var threaded_read = std.Io.Threaded.init_single_threaded;
    var file_reader = stdout.reader(threaded_read.io(), &read_buffer);
    var line_writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer line_writer.deinit();

    var event_name: std.ArrayList(u8) = .empty;
    defer event_name.deinit(context.allocator);
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(context.allocator);

    event_loop: while (true) {
        if (isEventStreamStopRequested(context)) return;
        const maybe_line = readEventStreamLine(&file_reader.interface, &line_writer, MAX_HTTP_BODY_BYTES) catch |err| switch (err) {
            error.StreamTooLong => {
                if (!try discardEventStreamLineRemainder(&file_reader.interface)) break :event_loop;
                event_name.clearRetainingCapacity();
                event_data.clearRetainingCapacity();
                continue :event_loop;
            },
            else => |read_err| return read_err,
        };
        if (maybe_line == null) break;

        const raw_line = maybe_line.?;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (line.len == 0) {
            if (event_data.items.len > 0) {
                try processEventStreamMessage(context, event_name.items, event_data.items);
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
        try processEventStreamMessage(context, event_name.items, event_data.items);
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
    log.info("stopping OpenCode event stream session_len={d}", .{handle.context.session_id.len});
    handle.context.mutex.lock();
    handle.context.stop_requested = true;
    if (handle.context.child) |*child| child.terminateTree();
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
        if (owned_child.child.id != null) {
            var threaded = std.Io.Threaded.init_single_threaded;
            owned_child.kill(threaded.io());
        }
    }

    log.info("OpenCode event stream exited session_len={d}", .{context.session_id.len});
}

fn processEventStreamMessage(context: *EventStreamContext, raw_event_name: []const u8, raw_event_data: []const u8) !void {
    if (raw_event_data.len == 0) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, raw_event_data, .{});
    defer parsed.deinit();

    const envelope = parseEventEnvelope(parsed.value, raw_event_name) orelse return;
    const event_type = envelope.event_type;
    const properties = envelope.properties;
    if (!eventTargetsSession(properties, context.session_id)) return;

    if (eventTypeIs(event_type, "session.text.delta")) {
        try handleTextDelta(context, properties);
    } else if (eventTypeIs(event_type, "session.tool.called")) {
        try handleToolCalled(context, properties);
    } else if (eventTypeIs(event_type, "session.tool.success")) {
        try handleToolFinished(context, properties, .completed);
    } else if (eventTypeIs(event_type, "session.tool.failed")) {
        try handleToolFinished(context, properties, .failed);
    } else if (eventTypeIs(event_type, "session.retried")) {
        try emitRetryMessage(context, properties);
    } else if (eventTypeIs(event_type, "session.status")) {
        const status = getObjectField(properties, "status") orelse return;
        if (std.mem.eql(u8, getOptionalObjectString(status, "type") orelse "", "retry")) {
            try emitRetryMessage(context, status);
        }
    } else if (eventTypeIs(event_type, "session.execution.failed")) {
        emitExecutionFailure(context, properties);
        signalEventStreamTerminal(context);
    } else if (eventTypeIs(event_type, "session.execution.succeeded") or
        eventTypeIs(event_type, "session.execution.interrupted") or
        eventTypeIs(event_type, "session.idle"))
    {
        signalEventStreamTerminal(context);
    }
}

/// Live services emit `session.text.delta`; the published schema also names
/// the same events `session.next.text.delta`. Accept both spellings.
fn eventTypeIs(event_type: []const u8, comptime canonical: []const u8) bool {
    if (std.mem.eql(u8, event_type, canonical)) return true;
    if (comptime std.mem.startsWith(u8, canonical, "session.")) {
        const with_next = "session.next." ++ canonical["session.".len..];
        return std.mem.eql(u8, event_type, with_next);
    }
    return false;
}

fn signalEventStreamTerminal(context: *EventStreamContext) void {
    context.mutex.lock();
    context.session_terminal = true;
    context.mutex.unlock();
}

fn eventStreamReachedTerminal(context: *EventStreamContext) bool {
    context.mutex.lock();
    defer context.mutex.unlock();
    return context.session_terminal;
}

const EventEnvelope = struct {
    event_type: []const u8,
    properties: std.json.Value,
};

/// v2 frames are `{"id","type","data":{...}}`; older shapes used `properties`.
fn parseEventEnvelope(root: std.json.Value, event_name: []const u8) ?EventEnvelope {
    if (root == .object) {
        if (getOptionalObjectString(root, "type")) |root_type| {
            return .{
                .event_type = root_type,
                .properties = getObjectField(root, "data") orelse getObjectField(root, "properties") orelse root,
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

fn handleTextDelta(context: *EventStreamContext, properties: std.json.Value) !void {
    const delta = getOptionalObjectString(properties, "delta") orelse return;
    if (delta.len == 0) return;

    {
        context.mutex.lock();
        defer context.mutex.unlock();
        try context.streamed_text.appendSlice(context.allocator, delta);
    }

    const on_stream_delta = context.request.on_stream_delta orelse return;
    on_stream_delta(context.request.stream_context, delta);
}

fn handleToolCalled(context: *EventStreamContext, properties: std.json.Value) !void {
    const call_id = getOptionalObjectString(properties, "callID") orelse return;
    const tool_name = getOptionalObjectString(properties, "tool") orelse return;

    {
        context.mutex.lock();
        defer context.mutex.unlock();
        if (context.tool_names.get(call_id) == null) {
            const owned_call_id = try context.allocator.dupe(u8, call_id);
            errdefer context.allocator.free(owned_call_id);
            const owned_name = try context.allocator.dupe(u8, tool_name);
            errdefer context.allocator.free(owned_name);
            try context.tool_names.put(context.allocator, owned_call_id, owned_name);
        }
    }

    _ = try emitToolCalled(context.allocator, context.request, properties);
}

fn handleToolFinished(context: *EventStreamContext, properties: std.json.Value, status: provider_types.ToolCallStatus) !void {
    const call_id = getOptionalObjectString(properties, "callID") orelse return;

    context.mutex.lock();
    const tool_name: []const u8 = context.tool_names.get(call_id) orelse "tool";
    context.mutex.unlock();

    _ = try emitToolResult(context.allocator, context.request, tool_name, properties, status);
}

fn emitRetryMessage(context: *EventStreamContext, properties: std.json.Value) !void {
    const on_stream_event = context.request.on_stream_event orelse return;
    const attempt = jsonInteger(getObjectField(properties, "attempt")) orelse 0;
    const message = blk: {
        const error_value = getObjectField(properties, "error") orelse break :blk null;
        break :blk switch (error_value) {
            .string => |text| text,
            .object => getOptionalObjectString(error_value, "message"),
            else => null,
        };
    } orelse getOptionalObjectString(properties, "message") orelse "OpenCode is retrying the request.";

    const title = if (attempt > 0)
        try std.fmt.allocPrint(context.allocator, "OpenCode retry {d}", .{attempt})
    else
        try context.allocator.dupe(u8, "OpenCode retry");
    defer context.allocator.free(title);

    on_stream_event(context.request.stream_context, .{ .message = .{
        .title = title,
        .body = message,
    } });
}

fn emitExecutionFailure(context: *EventStreamContext, properties: std.json.Value) void {
    const on_stream_event = context.request.on_stream_event orelse return;
    const error_value = getObjectField(properties, "error") orelse return;
    const message = switch (error_value) {
        .string => |text| text,
        .object => getOptionalObjectString(error_value, "message") orelse return,
        else => return,
    };
    on_stream_event(context.request.stream_context, .{ .message = .{
        .title = "OpenCode error",
        .body = message,
    } });
}

fn openCodeToolKind(tool_name: []const u8) provider_types.ToolCallKind {
    if (provider_types.isSubagentToolName(tool_name)) return .subagent;
    if (std.mem.eql(u8, tool_name, "bash") or std.mem.eql(u8, tool_name, "shell")) return .execute;
    if (std.mem.eql(u8, tool_name, "read")) return .read;
    if (std.mem.eql(u8, tool_name, "edit") or std.mem.eql(u8, tool_name, "write") or std.mem.eql(u8, tool_name, "patch")) return .edit;
    if (std.mem.eql(u8, tool_name, "grep") or std.mem.eql(u8, tool_name, "glob") or std.mem.eql(u8, tool_name, "list")) return .search;
    if (std.mem.eql(u8, tool_name, "webfetch") or std.mem.eql(u8, tool_name, "websearch")) return .fetch;

    // OpenCode flattens MCP method names for some servers (for example,
    // `verde:list_processes` arrives as `verde_list_processes`). Treat tools
    // outside its built-in set as MCP calls so those methods remain visible.
    return .mcp;
}

fn openCodeTaskTitle(input: std.json.Value, fallback: []const u8) []const u8 {
    if (getOptionalObjectString(input, "description")) |description| {
        if (std.mem.trim(u8, description, &std.ascii.whitespace).len > 0) return description;
    }
    if (getOptionalObjectString(input, "prompt")) |prompt| {
        if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len > 0) return prompt;
    }
    return fallback;
}

/// Emits a `session.tool.called` event (`{callID, tool, input}`) as an in-progress tool row.
fn emitToolCalled(
    allocator: std.mem.Allocator,
    request: provider_types.SendPromptRequest,
    properties: std.json.Value,
) !bool {
    const on_stream_event = request.on_stream_event orelse return false;
    const tool_name = getOptionalObjectString(properties, "tool") orelse return false;
    const call_id = getOptionalObjectString(properties, "callID") orelse return false;
    const input_value = getObjectField(properties, "input") orelse .null;
    const input = if (input_value != .null) try stringifyAlloc(allocator, input_value) else null;
    defer if (input) |value| allocator.free(value);

    const kind = openCodeToolKind(tool_name);
    const title = if (kind == .subagent) openCodeTaskTitle(input_value, tool_name) else tool_name;

    on_stream_event(request.stream_context, .{ .tool_call = .{
        .call_id = call_id,
        .title = title,
        .kind = kind,
        .status = .in_progress,
        .input = input,
    } });
    return true;
}

/// Emits a `session.tool.success` / `session.tool.failed` event as the final tool row.
fn emitToolResult(
    allocator: std.mem.Allocator,
    request: provider_types.SendPromptRequest,
    tool_name: []const u8,
    properties: std.json.Value,
    status: provider_types.ToolCallStatus,
) !bool {
    const on_stream_event = request.on_stream_event orelse return false;
    const call_id = getOptionalObjectString(properties, "callID") orelse return false;

    const output = try extractToolOutputAlloc(allocator, properties);
    defer if (output) |value| allocator.free(value);

    const error_text = blk: {
        const error_value = getObjectField(properties, "error") orelse break :blk null;
        break :blk switch (error_value) {
            .string => |text| text,
            .object => getOptionalObjectString(error_value, "message"),
            else => null,
        };
    };

    const kind = openCodeToolKind(tool_name);
    // Result events often omit `input`. Leave subagent titles empty so the
    // in-progress description from `session.tool.called` is not overwritten
    // with the generic tool name (`task`).
    const input_value = getObjectField(properties, "input") orelse .null;
    const title = if (kind == .subagent) openCodeTaskTitle(input_value, "") else tool_name;

    on_stream_event(request.stream_context, .{ .tool_call = .{
        .call_id = call_id,
        .title = title,
        .kind = kind,
        .status = status,
        .output = output,
        .error_text = error_text,
    } });
    return true;
}

fn extractToolOutputAlloc(allocator: std.mem.Allocator, properties: std.json.Value) !?[]u8 {
    const content = getObjectField(properties, "content") orelse return null;
    if (content == .string) return try allocator.dupe(u8, content.string);
    if (content != .array) return null;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (content.array.items) |part| {
        const chunk = switch (part) {
            .string => |value| value,
            .object => getOptionalObjectString(part, "text") orelse getOptionalObjectString(part, "uri") orelse continue,
            else => continue,
        };
        if (text.items.len > 0) try text.append(allocator, '\n');
        try text.appendSlice(allocator, chunk);
    }
    if (text.items.len == 0) return null;
    return try text.toOwnedSlice(allocator);
}

// Permissions -----------------------------------------------------------------

/// Summarizes a `Permission.Request` (`action`, `resources`, `message`, `source`).
fn buildPermissionBody(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    const action = getOptionalObjectString(value, "action") orelse "permission";
    const action_label = try std.fmt.allocPrint(allocator, "Action: {s}", .{action});
    defer allocator.free(action_label);
    try text.appendSlice(allocator, action_label);

    if (getOptionalObjectString(value, "message")) |message| {
        if (std.mem.trim(u8, message, &std.ascii.whitespace).len > 0) {
            try text.appendSlice(allocator, "\n");
            try text.appendSlice(allocator, message);
        }
    }

    if (getObjectField(value, "resources")) |resources| {
        if (resources == .array and resources.array.items.len > 0) {
            try text.appendSlice(allocator, "\nResources:");
            for (resources.array.items) |resource| {
                if (resource != .string) continue;
                const label = try std.fmt.allocPrint(allocator, "\n- {s}", .{resource.string});
                defer allocator.free(label);
                try text.appendSlice(allocator, label);
            }
        }
    }

    if (getObjectField(value, "source")) |source| {
        if (getOptionalObjectString(source, "callID")) |call_id| {
            const label = try std.fmt.allocPrint(allocator, "\nTool call: {s}", .{call_id});
            defer allocator.free(label);
            try text.appendSlice(allocator, label);
        }
    }

    return text.toOwnedSlice(allocator);
}

// Diffs -----------------------------------------------------------------------

fn appendSessionDiffFiles(value: std.json.Value, files: *std.ArrayList(provider_types.StreamDiffFile)) !void {
    switch (value) {
        .array => |items| {
            for (items.items) |item| {
                try appendSessionDiffFile(item, files);
            }
        },
        .object => {
            if (getObjectField(value, "data") orelse getObjectField(value, "files")) |nested| {
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
        getOptionalObjectString(item, "path") orelse return;
    const patch_text = getOptionalObjectString(item, "patch") orelse
        getOptionalObjectString(item, "diff");
    const patch = if (patch_text) |text|
        if (text.len > 0) text else null
    else
        null;

    try files.append(std.heap.page_allocator, .{
        .path = path,
        .additions = jsonInteger(getObjectField(item, "additions")) orelse countPatchLines(patch, '+'),
        .deletions = jsonInteger(getObjectField(item, "deletions")) orelse countPatchLines(patch, '-'),
        .patch = patch,
    });
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

// Request bodies --------------------------------------------------------------

fn buildSessionCreateBody(
    allocator: std.mem.Allocator,
    title: ?[]const u8,
    directory: ?[]const u8,
    request: provider_types.SendPromptRequest,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };

    try stringify.beginObject();
    try stringify.objectField("title");
    try stringify.write(title orelse "Verde");
    if (directory) |path| {
        try stringify.objectField("location");
        try stringify.beginObject();
        try stringify.objectField("directory");
        try stringify.write(path);
        try stringify.endObject();
    }
    if (request.model != null) {
        try stringify.objectField("model");
        try writeModelRef(&stringify, request);
    }
    try stringify.endObject();
    return writer.toOwnedSlice();
}

/// Writes a v2 `Model.Ref` (`{providerID, id, variant?}`); the explicit
/// OpenCode variant wins over the generic reasoning-effort mapping.
fn writeModelRef(stringify: *std.json.Stringify, request: provider_types.SendPromptRequest) !void {
    const provider_id, const model_id = parseModelRef(request.model orelse "");
    try stringify.beginObject();
    try stringify.objectField("providerID");
    try stringify.write(provider_id);
    try stringify.objectField("id");
    try stringify.write(model_id);
    if (request.opencode_variant) |explicit| {
        try stringify.objectField("variant");
        try stringify.write(explicit);
    } else if (reasoningVariantName(request.reasoning_effort)) |variant_name| {
        try stringify.objectField("variant");
        try stringify.write(variant_name);
    }
    try stringify.endObject();
}

/// Builds the `/prompt` body: `{text, files?}` with inline base64 attachments.
fn buildPromptBody(
    allocator: std.mem.Allocator,
    request: provider_types.SendPromptRequest,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };

    try stringify.beginObject();
    try stringify.objectField("text");
    try stringify.write(request.prompt);
    if (request.image != null or request.images.len > 0) {
        try stringify.objectField("files");
        try stringify.beginArray();
        if (request.image) |image| try writeInlineFile(allocator, &stringify, image.path);
        for (request.images) |image| try writeInlineFile(allocator, &stringify, image.path);
        try stringify.endArray();
    }
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn writeInlineFile(allocator: std.mem.Allocator, stringify: *std.json.Stringify, path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(MAX_ATTACHMENT_BYTES));
    defer allocator.free(bytes);
    const encoded = try encodeBase64Alloc(allocator, bytes);
    defer allocator.free(encoded);

    try stringify.beginObject();
    try stringify.objectField("data");
    try stringify.write(encoded);
    try stringify.objectField("mime");
    try stringify.write(mimeTypeForPath(path));
    try stringify.objectField("name");
    try stringify.write(std.fs.path.basename(path));
    try stringify.objectField("source");
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("inline");
    try stringify.endObject();
    try stringify.endObject();
}

fn mimeTypeForPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(extension, ".txt") or std.ascii.eqlIgnoreCase(extension, ".md")) return "text/plain";
    return "application/octet-stream";
}

fn reasoningVariantName(value: ?provider_types.ReasoningEffort) ?[]const u8 {
    return switch (value orelse return null) {
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "high",
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

// Tests -----------------------------------------------------------------------

const OpenCodeTestToolCapture = struct {
    call_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    kind: ?provider_types.ToolCallKind = null,
    status: ?provider_types.ToolCallStatus = null,
    output_buffer: [256]u8 = undefined,
    output_len: usize = 0,
    input_buffer: [256]u8 = undefined,
    input_len: usize = 0,
    count: usize = 0,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *OpenCodeTestToolCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .tool_call => |tool_call| {
                self.call_id = tool_call.call_id;
                self.title = tool_call.title;
                self.kind = tool_call.kind;
                self.status = tool_call.status;
                if (tool_call.input) |input| {
                    self.input_len = @min(input.len, self.input_buffer.len);
                    @memcpy(self.input_buffer[0..self.input_len], input[0..self.input_len]);
                }
                if (tool_call.output) |output| {
                    self.output_len = @min(output.len, self.output_buffer.len);
                    @memcpy(self.output_buffer[0..self.output_len], output[0..self.output_len]);
                }
                self.count += 1;
            },
            else => {},
        }
    }
};

test "OpenCode tool called events preserve MCP input" {
    const payload =
        \\{"sessionID":"ses_1","assistantMessageID":"msg_1","callID":"call-1","tool":"verde:list_processes","input":{"workspace":"current"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: OpenCodeTestToolCapture = .{};

    try std.testing.expect(try emitToolCalled(std.testing.allocator, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = OpenCodeTestToolCapture.handle,
    }, parsed.value));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("call-1", capture.call_id.?);
    try std.testing.expectEqualStrings("verde:list_processes", capture.title.?);
    try std.testing.expectEqual(provider_types.ToolCallKind.mcp, capture.kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, capture.status.?);
    try std.testing.expectEqualStrings("{\"workspace\":\"current\"}", capture.input_buffer[0..capture.input_len]);
}

test "OpenCode tool called events classify task tools as subagents" {
    const payload =
        \\{"sessionID":"ses_1","callID":"task-1","tool":"task","input":{"description":"Explore website package"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: OpenCodeTestToolCapture = .{};

    try std.testing.expect(try emitToolCalled(std.testing.allocator, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = OpenCodeTestToolCapture.handle,
    }, parsed.value));
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, capture.kind.?);
    try std.testing.expectEqualStrings("Explore website package", capture.title.?);
}

test "OpenCode tool success events preserve subagent titles from input" {
    const payload =
        \\{"sessionID":"ses_1","callID":"task-1","input":{"description":"Explore website package"},"content":[{"type":"text","text":"done"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: OpenCodeTestToolCapture = .{};

    try std.testing.expect(try emitToolResult(std.testing.allocator, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = OpenCodeTestToolCapture.handle,
    }, "task", parsed.value, .completed));
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, capture.kind.?);
    try std.testing.expectEqualStrings("Explore website package", capture.title.?);
}

test "OpenCode tool success events leave subagent titles empty without input" {
    const payload =
        \\{"sessionID":"ses_1","callID":"task-1","content":[{"type":"text","text":"done"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: OpenCodeTestToolCapture = .{};

    try std.testing.expect(try emitToolResult(std.testing.allocator, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = OpenCodeTestToolCapture.handle,
    }, "task", parsed.value, .completed));
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, capture.kind.?);
    try std.testing.expectEqualStrings("", capture.title.?);
}

test "OpenCode tool success events join text content into output" {
    const payload =
        \\{"sessionID":"ses_1","callID":"bash-1","content":[{"type":"text","text":"clean"},{"type":"file","uri":"file:///tmp/x"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: OpenCodeTestToolCapture = .{};

    try std.testing.expect(try emitToolResult(std.testing.allocator, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = OpenCodeTestToolCapture.handle,
    }, "bash", parsed.value, .completed));
    try std.testing.expectEqual(provider_types.ToolCallKind.execute, capture.kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.status.?);
    try std.testing.expectEqualStrings("clean\nfile:///tmp/x", capture.output_buffer[0..capture.output_len]);
}

test "eventTypeIs accepts live and schema event spellings" {
    try std.testing.expect(eventTypeIs("session.text.delta", "session.text.delta"));
    try std.testing.expect(eventTypeIs("session.next.text.delta", "session.text.delta"));
    try std.testing.expect(!eventTypeIs("session.text.started", "session.text.delta"));
    try std.testing.expect(eventTypeIs("permission.asked", "permission.asked"));
}

test "parseEventEnvelope reads v2 data frames" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":"evt_1","type":"session.text.delta","data":{"sessionID":"ses_1","delta":"hi"}}
    , .{});
    defer parsed.deinit();

    const envelope = parseEventEnvelope(parsed.value, "") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("session.text.delta", envelope.event_type);
    try std.testing.expect(eventTargetsSession(envelope.properties, "ses_1"));
    try std.testing.expectEqualStrings("hi", getOptionalObjectString(envelope.properties, "delta").?);
}

test "extractAssistantTextAlloc joins text content parts" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"type":"assistant","content":[{"type":"text","text":"hello "},{"type":"reasoning","text":"hidden"},{"type":"text","text":"world"},{"type":"tool","name":"bash"}]}
    , .{});
    defer parsed.deinit();

    const text = try extractAssistantTextAlloc(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "readEventStreamLine accepts SSE lines larger than the file buffer" {
    const allocator = std.testing.allocator;
    const large_len = 96 * 1024;
    const payload = try allocator.alloc(u8, large_len + 6);
    defer allocator.free(payload);
    @memset(payload[0..large_len], 'x');
    @memcpy(payload[large_len..], "\nlast\n");

    var reader = std.Io.Reader.fixed(payload);
    var line_writer: std.Io.Writer.Allocating = .init(allocator);
    defer line_writer.deinit();

    const large_line = (try readEventStreamLine(&reader, &line_writer, MAX_HTTP_BODY_BYTES)).?;
    try std.testing.expectEqual(large_len, large_line.len);
    try std.testing.expectEqualStrings("last", (try readEventStreamLine(&reader, &line_writer, MAX_HTTP_BODY_BYTES)).?);
    try std.testing.expectEqual(null, try readEventStreamLine(&reader, &line_writer, MAX_HTTP_BODY_BYTES));
}

test "oversized SSE lines can be discarded before reading the next event" {
    var reader = std.Io.Reader.fixed("oversized\nok\n");
    var line_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_writer.deinit();

    try std.testing.expectError(error.StreamTooLong, readEventStreamLine(&reader, &line_writer, 4));
    try std.testing.expect(try discardEventStreamLineRemainder(&reader));
    try std.testing.expectEqualStrings("ok", (try readEventStreamLine(&reader, &line_writer, 4)).?);
}

test "extractLatestAssistantTaskSummaryAlloc summarizes the newest subagent tool" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"id":"a2","type":"assistant","content":[{"type":"tool","name":"task","state":{"status":"running","input":{"description":"New task"}}}]},
        \\  {"id":"a1","type":"assistant","content":[{"type":"tool","name":"task","state":{"status":"completed","input":{"description":"Old task"}}}]},
        \\  {"id":"u1","type":"user","text":"go"},
        \\  {"id":"a0","type":"assistant","content":[{"type":"tool","name":"task","state":{"status":"completed","input":{"description":"Stale task"}}}]}
        \\]
    , .{});
    defer parsed.deinit();

    const summary = (try extractLatestAssistantTaskSummaryAlloc(allocator, parsed.value, "u1")).?;
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("Running subtask: New task", summary);
}

test "findPrimaryAssistantAfterUser picks final step after tool calls" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"id":"final","type":"assistant","finish":"stop","content":[{"type":"text","text":"complete report"}]},
        \\  {"id":"tool-2","type":"assistant","finish":"tool-calls","content":[{"type":"tool","name":"bash"}]},
        \\  {"id":"tool-1","type":"assistant","finish":"tool-calls","content":[{"type":"reasoning","text":"first"}]},
        \\  {"id":"u1","type":"user","text":"test it"},
        \\  {"id":"old","type":"assistant","finish":"stop","content":[{"type":"text","text":"previous turn"}]}
        \\]
    , .{});
    defer parsed.deinit();

    const item = findPrimaryAssistantAfterUser(parsed.value, "u1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("final", getOptionalObjectString(item, "id") orelse return error.TestUnexpectedNull);
}

test "findPrimaryAssistantAfterUser falls back to the first in-flight step" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  {"id":"step-2","type":"assistant","finish":"tool-calls","content":[]},
        \\  {"id":"step-1","type":"assistant","finish":"tool-calls","content":[]},
        \\  {"id":"u1","type":"user","text":"test it"}
        \\]
    , .{});
    defer parsed.deinit();

    const item = findPrimaryAssistantAfterUser(parsed.value, null) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("step-1", getOptionalObjectString(item, "id") orelse return error.TestUnexpectedNull);
    // An anchor that scrolled out of the window means the whole window is the turn.
    const unanchored = findPrimaryAssistantAfterUser(parsed.value, "u0-missing-window") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("step-1", getOptionalObjectString(unanchored, "id") orelse return error.TestUnexpectedNull);
}

test "appendSessionDiffFiles reads the vcs diff data wrapper" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"data":[{"file":"packages/desktop/src/ui/chat_panel.zig","patch":"@@ -1 +1 @@\n-old\n+new\n","status":"modified"}]}
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

test "parseModelsAlloc reads v2 models with provider names and variants" {
    const allocator = std.testing.allocator;
    var parsed_models = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"data":[
        \\  {"id":"openai/gpt-5.4","modelID":"gpt-5.4","providerID":"openai","name":"GPT-5.4","enabled":true,"variants":[{"id":"low"},{"id":"high"}]},
        \\  {"id":"anthropic/sonnet","modelID":"sonnet","providerID":"anthropic","name":"Claude Sonnet","enabled":true,"variants":[]},
        \\  {"id":"zen/hidden","modelID":"hidden","providerID":"zen","name":"Hidden","enabled":false}
        \\]}
    , .{});
    defer parsed_models.deinit();
    var parsed_providers = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"data":[{"id":"openai","name":"OpenAI"}]}
    , .{});
    defer parsed_providers.deinit();

    const models = try parseModelsAlloc(allocator, parsed_models.value, parsed_providers.value);
    defer provider_types.freeModelInfos(allocator, models);

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("openai", models[0].provider_id);
    try std.testing.expectEqualStrings("OpenAI", models[0].provider_name);
    try std.testing.expectEqualStrings("gpt-5.4", models[0].model_id);
    try std.testing.expectEqualStrings("GPT-5.4", models[0].model_name);
    try std.testing.expect(models[0].reasoning_supported);
    try std.testing.expectEqual(@as(usize, 2), models[0].reasoning_variant_keys.?.len);
    try std.testing.expectEqualStrings("high", models[0].reasoning_variant_keys.?[0]);
    try std.testing.expectEqualStrings("low", models[0].reasoning_variant_keys.?[1]);
    try std.testing.expectEqualStrings("anthropic", models[1].provider_name);
    try std.testing.expect(!models[1].reasoning_supported);
    try std.testing.expect(models[1].reasoning_variant_keys == null);
}

test "buildSessionCreateBody prefers explicit opencode variant over reasoning effort" {
    const allocator = std.testing.allocator;
    const body = try buildSessionCreateBody(allocator, "Verde chat", "/tmp/work", .{
        .prompt = "hi",
        .model = "openai/gpt-5.4",
        .opencode_variant = "minimal",
        .reasoning_effort = .high,
    });
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        \\{"title":"Verde chat","location":{"directory":"/tmp/work"},"model":{"providerID":"openai","id":"gpt-5.4","variant":"minimal"}}
    , body);
}

test "buildPromptBody sends text-only prompts without files" {
    const allocator = std.testing.allocator;
    const body = try buildPromptBody(allocator, .{ .prompt = "hi there" });
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"text\":\"hi there\"}", body);
}

test "apiPathAlloc scopes requests with an encoded location directory" {
    var client: Client = .{
        .allocator = std.testing.allocator,
        .config = .{ .allocator = std.testing.allocator, .working_directory = "/tmp/my work" },
        .endpoint = .{ .base_url = "http://127.0.0.1:1", .password = null },
    };
    const path = try client.apiPathAlloc("/session/{s}/message", .{"ses_1"}, "order=desc&limit=12");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(
        "/api/session/ses_1/message?location%5Bdirectory%5D=%2Ftmp%2Fmy%20work&order=desc&limit=12",
        path,
    );
}

test "parseServiceRegistrationAlloc reads the service url and password" {
    const allocator = std.testing.allocator;
    var registration = (try parseServiceRegistrationAlloc(allocator,
        \\{"id":"svc","version":"0.0.0-beta-18414","url":"http://127.0.0.1:49374","pid":1105379,"password":"secret"}
    )) orelse return error.TestUnexpectedNull;
    defer registration.deinit(allocator);
    try std.testing.expectEqualStrings("http://127.0.0.1:49374", registration.url);
    try std.testing.expectEqualStrings("secret", registration.password.?);
    try std.testing.expectEqual(null, try parseServiceRegistrationAlloc(allocator, "{\"pid\":1}"));
}

test "buildPermissionBody summarizes v2 permission requests" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"id":"per_1","sessionID":"ses_1","action":"bash","resources":["git status"],"source":{"type":"tool","messageID":"msg_1","callID":"call_1"}}
    , .{});
    defer parsed.deinit();

    const body = try buildPermissionBody(allocator, parsed.value);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("Action: bash\nResources:\n- git status\nTool call: call_1", body);
}

test "health probe times out against a server that accepts but never responds" {
    // Wedge listener: bound and listening but never accepting or answering.
    // The kernel completes the TCP handshake via the backlog, so the probe
    // connects fine and then gets no bytes — the exact failure observed live
    // 2026-07-15, where the old fetch-based probe blocked forever.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const listen_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try listen_address.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(base_url);

    const started_ms = platform_runtime.unixTimestampMs();
    try std.testing.expect(!checkHealth(std.testing.allocator, base_url, null, "secret"));
    const elapsed_ms = platform_runtime.unixTimestampMs() - started_ms;
    // Must fail via the receive timeout (~2s), not block unboundedly; the
    // upper bound is loose to tolerate slow CI machines.
    try std.testing.expect(elapsed_ms >= 1_000);
    try std.testing.expect(elapsed_ms < 8_000);
}

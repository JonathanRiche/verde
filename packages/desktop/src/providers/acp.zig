//! Generic Agent Client Protocol (ACP) client machinery shared by ACP-backed
//! provider harnesses (Cursor, FX, ...). Transport framing, JSON-RPC request
//! builders, capability/session parsing, permission plumbing, and session
//! update mapping live here; binary discovery, argv construction, model
//! catalogs, and payload heuristics stay in the per-provider modules.
//!
//! Errors raised here are provider-neutral (`error.AcpFailed`,
//! `error.AcpSignedOut`, `error.AcpMessageTooLarge`,
//! `error.AcpAttachmentsUnsupported`). Providers map them to their existing
//! provider-specific error names at their public API boundary so user-facing
//! error messaging remains unchanged.

const std = @import("std");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const provider_types = @import("types.zig");

pub const MAX_LINE_BYTES = 16 * 1024 * 1024;
pub const MCP_TOOL_NAME_FIELD = "_verdeMcpTool";

/// Per-provider knobs threaded through the generic line handlers so shared
/// code can log, label, and title output without provider branches.
pub const Harness = struct {
    /// Diagnostics category for content-safe JSON-RPC error logging.
    diagnostics_category: provider_diagnostics.ErrorCategory,
    /// Author label for assistant messages reconstructed from history replay.
    assistant_author: []const u8,
    /// Title used when a permission request omits its own.
    permission_default_title: []const u8,
    /// Some agents (fx) stream startup diagnostics as the first
    /// agent_message_chunk. Chunks starting with this prefix, arriving before
    /// any reply text, become a system event instead of assistant prose.
    diagnostic_chunk_prefix: ?[]const u8 = null,
    diagnostic_event_title: []const u8 = "Agent warning",
};

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

/// Tracks the provider's currently active ACP child so interrupts and
/// shutdown can target it. Each provider module owns one instance.
pub const ActiveProcessState = struct {
    mutex: Mutex = .{},
    child: ?*platform_process.OwnedChild = null,
    stdin: ?std.Io.File = null,
    session_id: ?[]const u8 = null,

    pub fn lock(self: *ActiveProcessState) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *ActiveProcessState) void {
        self.mutex.unlock();
    }

    pub fn register(
        self: *ActiveProcessState,
        child: *platform_process.OwnedChild,
        stdin: ?std.Io.File,
        session_id: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child = child;
        self.stdin = stdin;
        self.session_id = session_id;
    }

    pub fn unregister(self: *ActiveProcessState, child: *platform_process.OwnedChild) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.child == child) {
            self.child = null;
            self.stdin = null;
            self.session_id = null;
        }
    }
};

/// A spawned ACP server child plus the resources needed to speak
/// newline-delimited JSON-RPC with it. Providers construct this from their
/// own argv/env logic; the transport methods are shared.
pub const Process = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    process: platform_process.OwnedChild,
    env_map: std.process.Environ.Map,
    executable: []u8,
    /// When set, deinit unregisters this child from the provider's active
    /// process tracking.
    active_state: ?*ActiveProcessState = null,
    finished: bool = false,

    pub fn writeLine(self: *Process, line: []u8) !void {
        defer self.allocator.free(line);
        const stdin = self.process.child.stdin orelse return error.ConnectionClosed;
        try writeJsonLineToFile(self.allocator, stdin, line);
    }

    pub fn closeStdin(self: *Process) !void {
        if (self.process.child.stdin) |stdin| {
            stdin.close(self.threaded.io());
            self.process.child.stdin = null;
        }
    }

    pub fn stop(self: *Process) void {
        if (self.finished or self.process.child.id == null) return;
        self.process.kill(self.threaded.io());
        self.finished = true;
        self.process.child.stdin = null;
        self.process.child.stdout = null;
    }

    pub fn deinit(self: *Process) void {
        if (self.active_state) |state| state.unregister(&self.process);
        if (!self.finished and self.process.child.id != null) {
            self.process.kill(self.threaded.io());
        }
        if (self.process.child.stdin) |stdin| stdin.close(self.threaded.io());
        self.env_map.deinit();
        self.allocator.free(self.executable);
        self.threaded.deinit();
    }
};

/// Reads one newline-delimited JSON-RPC message, returning null at EOF.
pub fn takeLineAlloc(allocator: std.mem.Allocator, reader: anytype) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    _ = reader.interface.streamDelimiterLimit(&writer.writer, '\n', .limited(MAX_LINE_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => return error.AcpMessageTooLarge,
        else => return err,
    };
    const has_bytes = writer.written().len > 0;
    _ = reader.interface.discardDelimiterInclusive('\n') catch |err| switch (err) {
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

pub const Capabilities = struct {
    image: bool = false,
    load_session: bool = false,
    list_sessions: bool = false,
};

pub const ListThreadsState = struct {
    saw_initialize: bool = false,
    threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty,

    pub fn deinit(self: *ListThreadsState, allocator: std.mem.Allocator) void {
        for (self.threads.items) |thread| {
            allocator.free(thread.id);
            allocator.free(thread.title);
        }
        self.threads.deinit(allocator);
    }
};

pub const ReadThreadState = struct {
    saw_initialize: bool = false,
    messages: std.ArrayList(provider_types.ChatMessage) = .empty,
    title: ?[]u8 = null,

    pub fn deinit(self: *ReadThreadState, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        self.messages.deinit(allocator);
        if (self.title) |title| allocator.free(title);
    }
};

pub const SendPromptState = struct {
    capabilities: Capabilities = .{},
    session_id: ?[]u8 = null,
    prompt_submitted: bool = false,
    reply: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *SendPromptState, allocator: std.mem.Allocator) void {
        if (self.session_id) |session_id| allocator.free(session_id);
        self.reply.deinit(allocator);
    }
};

pub const SendLineAction = enum {
    continue_reading,
    session_ready,
    prompt_done,
};

/// Handles one line of a listThreads exchange; returns true when done.
/// Expects request id 1 = initialize and id 2 = session/list.
pub fn handleListThreadsLine(
    allocator: std.mem.Allocator,
    harness: Harness,
    line: []const u8,
    state: *ListThreadsState,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(harness, parsed.value);
    if (responseId(parsed.value)) |id| {
        if (id == 1) {
            const capabilities = parseCapabilities(parsed.value);
            if (!capabilities.list_sessions) return error.UnsupportedOperation;
            state.saw_initialize = true;
            return false;
        }
        if (id == 2) {
            try parseSessionListResponse(allocator, parsed.value, &state.threads);
            return true;
        }
    }
    return false;
}

/// Handles one line of a readThread exchange; returns true when done.
/// Expects request id 1 = initialize and id 2 = session/load.
pub fn handleReadThreadLine(
    allocator: std.mem.Allocator,
    harness: Harness,
    line: []const u8,
    thread_id: []const u8,
    state: *ReadThreadState,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(harness, parsed.value);
    if (responseId(parsed.value)) |id| {
        if (id == 1) {
            const capabilities = parseCapabilities(parsed.value);
            if (!capabilities.load_session) return error.UnsupportedOperation;
            state.saw_initialize = true;
            return false;
        }
        if (id == 2) {
            if (state.title == null) state.title = try allocator.dupe(u8, thread_id);
            return true;
        }
    }
    if (isMethod(parsed.value, "session/update")) {
        try handleReadSessionUpdate(allocator, harness, parsed.value, state);
    }
    return false;
}

/// Handles one line of a sendPrompt exchange. Expects request id 1 =
/// initialize, id 2 = session/new or session/load, id 3 = session/prompt.
pub fn handleSendPromptLine(
    allocator: std.mem.Allocator,
    harness: Harness,
    line: []const u8,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
    stdin: ?std.Io.File,
) !SendLineAction {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(harness, parsed.value);

    // ACP server requests have their own JSON-RPC id sequence. Handle them
    // before matching response ids so a permission request cannot collide
    // with one of Verde's initialize/session/prompt request ids.
    if (isMethod(parsed.value, "session/request_permission")) {
        try handlePermissionRequest(allocator, harness, parsed.value, request, stdin);
        return .continue_reading;
    }

    if (responseId(parsed.value)) |id| {
        if (id == 1) {
            state.capabilities = parseCapabilities(parsed.value);
            return .continue_reading;
        }
        if (id == 2) {
            if (state.prompt_submitted) return .continue_reading;
            if (state.session_id == null) {
                const session_id = parseSessionId(parsed.value) orelse request.thread_id orelse return error.AcpFailed;
                state.session_id = try allocator.dupe(u8, session_id);
            }
            return .session_ready;
        }
        if (id == 3) {
            // ACP reports agent-side turn failures (unknown model for the
            // active provider, gateway HTTP errors) as a successful response
            // with stopReason "refused"; the only diagnostic is the streamed
            // text, so fail the turn instead of committing it as a reply.
            if (getObjectField(parsed.value, "result")) |result| {
                if (getOptionalObjectString(result, "stopReason")) |stop_reason| {
                    if (std.mem.eql(u8, stop_reason, "refused")) {
                        provider_diagnostics.logError(
                            harness.diagnostics_category,
                            null,
                            "prompt refused by agent; streamed reply text carries the reason",
                        );
                        return error.AcpRefused;
                    }
                }
            }
            return .prompt_done;
        }
    }

    if (isMethod(parsed.value, "session/update")) {
        // ACP servers replay session history while loading an existing
        // session. Only updates emitted after this turn's prompt was
        // submitted are live.
        if (!state.prompt_submitted) return .continue_reading;
        try handleLiveSessionUpdate(allocator, harness, parsed.value, request, state);
        return .continue_reading;
    }
    return .continue_reading;
}

pub fn makeInitializeRequestAlloc(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, "initialize");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("protocolVersion");
    try stringify.write(1);
    try stringify.objectField("clientCapabilities");
    try stringify.beginObject();
    try stringify.objectField("fs");
    try stringify.beginObject();
    try stringify.objectField("readTextFile");
    try stringify.write(false);
    try stringify.objectField("writeTextFile");
    try stringify.write(false);
    try stringify.endObject();
    try stringify.objectField("terminal");
    try stringify.write(false);
    try stringify.endObject();
    try stringify.objectField("clientInfo");
    try stringify.beginObject();
    try stringify.objectField("name");
    try stringify.write("verde");
    try stringify.objectField("version");
    try stringify.write("0.1.0");
    try stringify.endObject();
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub fn makeSessionListRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd_owned: []u8) ![]u8 {
    defer allocator.free(cwd_owned);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, "session/list");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("cwd");
    try stringify.write(cwd_owned);
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub const McpHttpServer = struct {
    url: []const u8,
    authorization: []const u8,
    client_name: []const u8,
};

const McpServer = union(enum) {
    stdio: []const u8,
    http: McpHttpServer,
};

pub fn makeSessionNewRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd: []const u8, mcp_executable: ?[]const u8) ![]u8 {
    const server: ?McpServer = if (mcp_executable) |executable| .{ .stdio = executable } else null;
    return makeSessionSetupRequestAlloc(allocator, id, "session/new", null, cwd, server);
}

pub fn makeSessionLoadRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, cwd: []const u8, mcp_executable: ?[]const u8) ![]u8 {
    const server: ?McpServer = if (mcp_executable) |executable| .{ .stdio = executable } else null;
    return makeSessionSetupRequestAlloc(allocator, id, "session/load", session_id, cwd, server);
}

pub fn makeSessionNewRequestWithHttpMcpAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    cwd: []const u8,
    server: ?McpHttpServer,
) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/new", null, cwd, if (server) |value| .{ .http = value } else null);
}

pub fn makeSessionLoadRequestWithHttpMcpAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    session_id: []const u8,
    cwd: []const u8,
    server: ?McpHttpServer,
) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/load", session_id, cwd, if (server) |value| .{ .http = value } else null);
}

pub fn makePromptRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    session_id: []const u8,
    request: provider_types.SendPromptRequest,
    image_supported: bool,
) ![]u8 {
    const images = try collectImageAttachments(allocator, request);
    defer allocator.free(images);
    if (images.len > 0 and !image_supported) return error.AcpAttachmentsUnsupported;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, "session/prompt");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("sessionId");
    try stringify.write(session_id);
    try stringify.objectField("prompt");
    try stringify.beginArray();
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("text");
    try stringify.objectField("text");
    try stringify.write(request.prompt);
    try stringify.endObject();
    for (images) |image| {
        try writeImageContentBlock(allocator, &stringify, image);
    }
    try stringify.endArray();
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub fn makeCancelNotificationAlloc(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("method");
    try stringify.write("session/cancel");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("sessionId");
    try stringify.write(session_id);
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub fn makePermissionResponseAlloc(allocator: std.mem.Allocator, id: i64, option_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("result");
    try stringify.beginObject();
    try stringify.objectField("outcome");
    try stringify.beginObject();
    try stringify.objectField("outcome");
    try stringify.write("selected");
    try stringify.objectField("optionId");
    try stringify.write(option_id);
    try stringify.endObject();
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub fn writeJsonLineToFile(allocator: std.mem.Allocator, file: std.Io.File, line: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

pub fn responseId(value: std.json.Value) ?i64 {
    // ACP server requests use their own id sequence, which can collide with
    // Verde's request ids. Only JSON-RPC responses are eligible here.
    if (getObjectField(value, "method") != null) return null;
    return getOptionalObjectInteger(value, "id");
}

pub fn isMethod(value: std.json.Value, method: []const u8) bool {
    const actual = getOptionalObjectString(value, "method") orelse return false;
    return std.mem.eql(u8, actual, method);
}

pub fn failIfJsonRpcError(harness: Harness, value: std.json.Value) !void {
    const error_value = getObjectField(value, "error") orelse return;
    const message = getOptionalObjectString(error_value, "message") orelse "";
    if (isAuthError(message)) return error.AcpSignedOut;
    provider_diagnostics.logError(
        harness.diagnostics_category,
        getOptionalObjectInteger(error_value, "code"),
        message,
    );
    return error.AcpFailed;
}

pub fn parseCapabilities(value: std.json.Value) Capabilities {
    const result = getObjectField(value, "result") orelse return .{};
    const agent = getObjectField(result, "agentCapabilities") orelse return .{};
    const prompt = getObjectField(agent, "promptCapabilities");
    const sessions = getObjectField(agent, "sessionCapabilities");
    return .{
        .image = if (prompt) |p| getOptionalObjectBool(p, "image") orelse false else false,
        .load_session = getOptionalObjectBool(agent, "loadSession") orelse false,
        .list_sessions = if (sessions) |s| getObjectField(s, "list") != null else false,
    };
}

pub fn parseSessionId(value: std.json.Value) ?[]const u8 {
    const result = getObjectField(value, "result") orelse return null;
    return getOptionalObjectString(result, "sessionId");
}

pub fn parseSessionListResponse(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    threads: *std.ArrayList(provider_types.ChatThreadSummary),
) !void {
    const result = getObjectField(value, "result") orelse return;
    const sessions = getObjectField(result, "sessions") orelse return;
    if (sessions != .array) return;
    for (sessions.array.items) |session| {
        if (session != .object) continue;
        const id = getOptionalObjectString(session, "sessionId") orelse continue;
        const title = getOptionalObjectString(session, "title") orelse id;
        try threads.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
        });
    }
}

pub fn shouldAutoApprovePermission(request: provider_types.SendPromptRequest) bool {
    return (request.approval_policy orelse .on_request) == .never;
}

pub fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn getOptionalObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

pub fn getOptionalObjectInteger(value: std.json.Value, key: []const u8) ?i64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |number| number,
        else => null,
    };
}

pub fn getOptionalObjectBool(value: std.json.Value, key: []const u8) ?bool {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn handleReadSessionUpdate(
    allocator: std.mem.Allocator,
    harness: Harness,
    value: std.json.Value,
    state: *ReadThreadState,
) !void {
    const update = sessionUpdateObject(value) orelse return;
    const kind = getOptionalObjectString(update, "sessionUpdate") orelse return;
    if (std.mem.eql(u8, kind, "session_info_update")) {
        if (getOptionalObjectString(update, "title")) |title| {
            if (state.title) |old| allocator.free(old);
            state.title = try allocator.dupe(u8, title);
        }
        return;
    }
    const role: provider_types.MessageRole = if (std.mem.eql(u8, kind, "user_message_chunk"))
        .user
    else if (std.mem.eql(u8, kind, "agent_message_chunk"))
        .assistant
    else
        return;
    const text = contentText(update) orelse return;
    try appendChatMessageChunk(allocator, harness, &state.messages, role, text);
}

fn handleLiveSessionUpdate(
    allocator: std.mem.Allocator,
    harness: Harness,
    value: std.json.Value,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
) !void {
    const update = sessionUpdateObject(value) orelse return;
    const kind = getOptionalObjectString(update, "sessionUpdate") orelse return;
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        const text = contentText(update) orelse return;
        if (text.len == 0) return;
        if (harness.diagnostic_chunk_prefix) |prefix| {
            if (state.reply.items.len == 0 and std.mem.startsWith(u8, text, prefix)) {
                if (request.on_stream_event) |on_stream_event| {
                    on_stream_event(request.stream_context, .{ .message = .{
                        .title = harness.diagnostic_event_title,
                        .body = text,
                    } });
                }
                return;
            }
        }
        try state.reply.appendSlice(allocator, text);
        if (request.on_stream_delta) |on_stream_delta| {
            on_stream_delta(request.stream_context, text);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
        const event = (try toolEventAlloc(allocator, update)) orelse return;
        defer event.deinit(allocator);
        if (request.on_stream_event) |on_stream_event| {
            on_stream_event(request.stream_context, .{ .tool_call = .{
                .call_id = event.call_id,
                .title = event.title,
                .kind = event.tool_kind,
                .status = event.status,
                .input = event.input,
                .output = event.output,
                .error_text = event.error_text,
                .locations = event.locations,
                .raw = event.raw,
            } });
            emitDiffUpdate(allocator, update, event.output, request.stream_context, on_stream_event);
        }
    }
}

fn emitDiffUpdate(
    allocator: std.mem.Allocator,
    update: std.json.Value,
    serialized_output: ?[]const u8,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) void {
    if (findTextDiff(update)) |diff| {
        if (emitTextDiffUpdate(allocator, diff, context, on_stream_event)) return;
    }
    if (serialized_output) |output| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch null;
        if (parsed) |*owned| {
            defer owned.deinit();
            if (findTextDiff(owned.value)) |diff| {
                if (emitTextDiffUpdate(allocator, diff, context, on_stream_event)) return;
            }
        }
    }

    const path = findFirstStringForKeys(update, &.{ "path", "filePath", "relativePath", "file" }) orelse return;
    const patch = findFirstStringForKeys(update, &.{ "diff", "patch" }) orelse return;
    if (patch.len == 0) return;
    const files = [_]provider_types.StreamDiffFile{.{
        .path = path,
        .additions = countUnifiedPatchLines(patch, '+'),
        .deletions = countUnifiedPatchLines(patch, '-'),
        .patch = patch,
    }};
    on_stream_event(context, .{ .diff = .{ .files = &files } });
}

fn emitTextDiffUpdate(
    allocator: std.mem.Allocator,
    diff: TextDiff,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const patch = textDiffPatchAlloc(allocator, diff) catch return false;
    defer allocator.free(patch);
    if (patch.len == 0) return false;
    const files = [_]provider_types.StreamDiffFile{.{
        .path = diff.path,
        .additions = countUnifiedPatchLines(patch, '+'),
        .deletions = countUnifiedPatchLines(patch, '-'),
        .patch = patch,
    }};
    on_stream_event(context, .{ .diff = .{ .files = &files } });
    return true;
}

const TextDiff = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    created: bool,
};

fn findTextDiff(value: std.json.Value) ?TextDiff {
    switch (value) {
        .object => |object| {
            const content_type = getOptionalObjectString(value, "type") orelse "";
            if (std.mem.eql(u8, content_type, "diff")) {
                const path = getOptionalObjectString(value, "path") orelse return null;
                const old_value = object.get("oldText") orelse return null;
                const new_value = object.get("newText") orelse return null;
                const old_text: []const u8 = switch (old_value) {
                    .string => |text| text,
                    .null => "",
                    else => return null,
                };
                const new_text: []const u8 = switch (new_value) {
                    .string => |text| text,
                    else => return null,
                };
                return .{
                    .path = path,
                    .old_text = old_text,
                    .new_text = new_text,
                    .created = old_value == .null,
                };
            }

            var fields = object.iterator();
            while (fields.next()) |field| {
                if (findTextDiff(field.value_ptr.*)) |diff| return diff;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findTextDiff(item)) |diff| return diff;
            }
        },
        else => {},
    }
    return null;
}

fn textDiffPatchAlloc(allocator: std.mem.Allocator, diff: TextDiff) ![]u8 {
    if (std.mem.eql(u8, diff.old_text, diff.new_text)) return allocator.dupe(u8, "");

    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(allocator);
    try appendTextLines(allocator, &old_lines, diff.old_text);
    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(allocator);
    try appendTextLines(allocator, &new_lines, diff.new_text);

    const common_len = @min(old_lines.items.len, new_lines.items.len);
    var prefix_len: usize = 0;
    while (prefix_len < common_len and std.mem.eql(u8, old_lines.items[prefix_len], new_lines.items[prefix_len])) {
        prefix_len += 1;
    }

    var suffix_len: usize = 0;
    while (suffix_len < common_len - prefix_len and
        std.mem.eql(
            u8,
            old_lines.items[old_lines.items.len - suffix_len - 1],
            new_lines.items[new_lines.items.len - suffix_len - 1],
        ))
    {
        suffix_len += 1;
    }

    const context_lines: usize = 3;
    const context_start = prefix_len - @min(prefix_len, context_lines);
    const trailing_context = @min(suffix_len, context_lines);
    const old_change_end = old_lines.items.len - suffix_len;
    const new_change_end = new_lines.items.len - suffix_len;
    const old_hunk_end = old_change_end + trailing_context;
    const new_hunk_end = new_change_end + trailing_context;
    const old_count = old_hunk_end - context_start;
    const new_count = new_hunk_end - context_start;
    const old_start = if (old_count == 0) @as(usize, 0) else context_start + 1;
    const new_start = if (new_count == 0) @as(usize, 0) else context_start + 1;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    if (diff.created) {
        try writer.writer.print("--- /dev/null\n+++ b/{s}\n", .{diff.path});
    } else {
        try writer.writer.print("--- a/{s}\n+++ b/{s}\n", .{ diff.path, diff.path });
    }
    try writer.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });

    for (old_lines.items[context_start..prefix_len]) |line| try writer.writer.print(" {s}\n", .{line});
    for (old_lines.items[prefix_len..old_change_end]) |line| try writer.writer.print("-{s}\n", .{line});
    for (new_lines.items[prefix_len..new_change_end]) |line| try writer.writer.print("+{s}\n", .{line});
    for (old_lines.items[old_change_end..old_hunk_end]) |line| try writer.writer.print(" {s}\n", .{line});
    return writer.toOwnedSlice();
}

fn appendTextLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    if (text.len == 0) return;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    // A trailing newline terminates the last line; it does not start another.
    if (text[text.len - 1] == '\n') lines.items.len -= 1;
}

fn findFirstStringForKeys(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    switch (value) {
        .object => |object| {
            for (keys) |key| {
                const candidate = object.get(key) orelse continue;
                if (candidate == .string and candidate.string.len > 0) return candidate.string;
            }
            var fields = object.iterator();
            while (fields.next()) |field| {
                if (findFirstStringForKeys(field.value_ptr.*, keys)) |text| return text;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findFirstStringForKeys(item, keys)) |text| return text;
            }
        },
        else => {},
    }
    return null;
}

fn countUnifiedPatchLines(patch: []const u8, prefix: u8) i64 {
    var count: i64 = 0;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != prefix) continue;
        if (line.len >= 3 and std.mem.eql(u8, line[0..3], if (prefix == '+') "+++" else "---")) continue;
        count += 1;
    }
    return count;
}

fn handlePermissionRequest(
    allocator: std.mem.Allocator,
    harness: Harness,
    value: std.json.Value,
    request: provider_types.SendPromptRequest,
    stdin: ?std.Io.File,
) !void {
    const id = responseId(value) orelse return;
    const params = getObjectField(value, "params") orelse value;
    const title = getOptionalObjectString(params, "title") orelse harness.permission_default_title;
    const body = permissionBody(params);
    const call_id = getOptionalObjectString(params, "toolCallId") orelse getOptionalObjectString(params, "permissionId") orelse "acp-tool";
    const decision: provider_types.ApprovalDecision = if (shouldAutoApprovePermission(request))
        .approve
    else if (request.on_approval_request) |on_approval_request|
        on_approval_request(request.stream_context, .{
            .call_id = call_id,
            .title = title,
            .body = body,
        })
    else
        .deny;
    if (stdin) |file| {
        const option_id = permissionOptionId(params, decision);
        const response = try makePermissionResponseAlloc(allocator, id, option_id);
        defer allocator.free(response);
        try writeJsonLineToFile(allocator, file, response);
    }
}

fn permissionOptionId(params: std.json.Value, decision: provider_types.ApprovalDecision) []const u8 {
    const fallback = if (decision == .approve) "allow-once" else "reject-once";
    const options = getObjectField(params, "options") orelse return fallback;
    if (options != .array) return fallback;

    var first: ?[]const u8 = null;
    for (options.array.items) |option| {
        if (option != .object) continue;
        const id = getOptionalObjectString(option, "optionId") orelse getOptionalObjectString(option, "id") orelse continue;
        if (first == null) first = id;
        if (decision == .approve) {
            if (containsAnyIgnoreCase(id, &.{ "allow", "approve", "accept" })) return id;
        } else {
            if (containsAnyIgnoreCase(id, &.{ "reject", "deny", "disallow" })) return id;
        }
    }
    return first orelse fallback;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

fn permissionBody(params: std.json.Value) []const u8 {
    if (getOptionalObjectString(params, "body")) |body| return body;
    if (getOptionalObjectString(params, "description")) |description| return description;
    if (getOptionalObjectString(params, "toolCallId")) |tool| return tool;
    return "";
}

fn sessionUpdateObject(value: std.json.Value) ?std.json.Value {
    const params = getObjectField(value, "params") orelse return null;
    return getObjectField(params, "update");
}

fn contentText(update: std.json.Value) ?[]const u8 {
    const content = getObjectField(update, "content") orelse return null;
    if (content == .object) {
        return getOptionalObjectString(content, "text");
    }
    return null;
}

const ToolEvent = struct {
    call_id: []u8,
    title: []u8,
    tool_kind: ?provider_types.ToolCallKind,
    status: ?provider_types.ToolCallStatus,
    input: ?[]u8,
    output: ?[]u8,
    error_text: ?[]u8,
    locations: ?[]u8,
    raw: []u8,

    fn deinit(self: ToolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.title);
        if (self.input) |value| allocator.free(value);
        if (self.output) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        if (self.locations) |value| allocator.free(value);
        allocator.free(self.raw);
    }
};

fn toolEventAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?ToolEvent {
    const title = try toolTitleAlloc(allocator, update);
    errdefer allocator.free(title);
    const call_id_text = toolCallId(update) orelse "";
    const status = toolStatus(update);
    const input = try toolInputAlloc(allocator, update);
    errdefer if (input) |value| allocator.free(value);
    const output = try toolOutputAlloc(allocator, update);
    errdefer if (output) |value| allocator.free(value);
    const error_text = try toolErrorAlloc(allocator, update, status);
    errdefer if (error_text) |value| allocator.free(value);
    const locations = try toolLocationsAlloc(allocator, update);
    errdefer if (locations) |value| allocator.free(value);
    const raw = try jsonValueCompactAlloc(allocator, update);
    errdefer allocator.free(raw);

    const has_meaningful_content = input != null or output != null or error_text != null or locations != null;
    if (call_id_text.len == 0 and !has_meaningful_content and title.len == 0) {
        allocator.free(title);
        allocator.free(raw);
        return null;
    }

    return .{
        .call_id = try allocator.dupe(u8, call_id_text),
        .title = title,
        .tool_kind = toolKind(update),
        .status = status,
        .input = input,
        .output = output,
        .error_text = error_text,
        .locations = locations,
        .raw = raw,
    };
}

fn toolCallId(update: std.json.Value) ?[]const u8 {
    if (getTrimmedObjectString(update, "toolCallId")) |call_id| return call_id;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, "toolCallId")) |call_id| return call_id;
        if (getTrimmedObjectString(tool_call, "id")) |call_id| return call_id;
    }
    return null;
}

fn toolKind(update: std.json.Value) ?provider_types.ToolCallKind {
    if (mcpToolName(update) != null) return .mcp;
    const explicit_kind = getTrimmedObjectString(update, "kind") orelse nested: {
        const tool_call = getObjectField(update, "toolCall") orelse break :nested null;
        break :nested getTrimmedObjectString(tool_call, "kind");
    };
    if (explicit_kind) |kind| {
        if (std.mem.eql(u8, kind, "read")) return .read;
        if (std.mem.eql(u8, kind, "edit")) return .edit;
        if (std.mem.eql(u8, kind, "delete")) return .delete;
        if (std.mem.eql(u8, kind, "move")) return .move;
        if (std.mem.eql(u8, kind, "search")) return .search;
        if (std.mem.eql(u8, kind, "execute")) return .execute;
        if (std.mem.eql(u8, kind, "think")) return .think;
        if (std.mem.eql(u8, kind, "fetch")) return .fetch;
        // ACP `other` is deliberately non-specific. Let provider titles such
        // as `MCP: ...` refine it, and otherwise preserve an earlier kind.
        if (!std.mem.eql(u8, kind, "other")) return .other;
    }

    const title = toolTitle(update) orelse "";
    if (std.ascii.startsWithIgnoreCase(title, "mcp") or std.ascii.startsWithIgnoreCase(title, "verde:")) return .mcp;
    if (getTrimmedObjectString(update, "command") != null or title.len > 0 and title[0] == '`') return .execute;
    if (std.ascii.startsWithIgnoreCase(title, "read")) return .read;
    if (std.ascii.startsWithIgnoreCase(title, "edit") or std.ascii.startsWithIgnoreCase(title, "write")) return .edit;
    if (std.ascii.startsWithIgnoreCase(title, "grep") or std.ascii.startsWithIgnoreCase(title, "find") or std.ascii.startsWithIgnoreCase(title, "search")) return .search;
    return null;
}

fn toolStatus(update: std.json.Value) ?provider_types.ToolCallStatus {
    const status = getTrimmedObjectString(update, "status") orelse nested: {
        const tool_call = getObjectField(update, "toolCall") orelse return null;
        break :nested getTrimmedObjectString(tool_call, "status") orelse return null;
    };
    if (std.mem.eql(u8, status, "pending")) return .pending;
    if (std.mem.eql(u8, status, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, status, "completed")) return .completed;
    if (std.mem.eql(u8, status, "failed")) return .failed;
    if (std.mem.eql(u8, status, "cancelled") or std.mem.eql(u8, status, "canceled")) return .cancelled;
    return .unknown;
}

fn toolTitle(update: std.json.Value) ?[]const u8 {
    if (getTrimmedObjectString(update, "title")) |title| return title;
    if (getTrimmedObjectString(update, "name")) |name| return name;
    if (getTrimmedObjectString(update, "toolName")) |tool_name| return tool_name;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, "title")) |title| return title;
        if (getTrimmedObjectString(tool_call, "name")) |name| return name;
        if (getTrimmedObjectString(tool_call, "toolName")) |tool_name| return tool_name;
    }
    return null;
}

fn toolTitleAlloc(allocator: std.mem.Allocator, update: std.json.Value) ![]u8 {
    if (mcpToolName(update)) |tool_name| {
        return std.fmt.allocPrint(allocator, "MCP: {s}", .{tool_name});
    }
    if (toolTitle(update)) |title| return allocator.dupe(u8, title);
    return allocator.dupe(u8, "");
}

fn mcpToolName(update: std.json.Value) ?[]const u8 {
    if (getTrimmedObjectString(update, MCP_TOOL_NAME_FIELD)) |name| return name;
    for ([_][]const u8{ "rawOutput", "output", "result" }) |field_name| {
        const field = getObjectField(update, field_name) orelse continue;
        if (getTrimmedObjectString(field, MCP_TOOL_NAME_FIELD)) |name| return name;
    }
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, MCP_TOOL_NAME_FIELD)) |name| return name;
        for ([_][]const u8{ "rawOutput", "output", "result" }) |field_name| {
            const field = getObjectField(tool_call, field_name) orelse continue;
            if (getTrimmedObjectString(field, MCP_TOOL_NAME_FIELD)) |name| return name;
        }
    }
    return null;
}

fn toolInputAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "rawInput", "input", "args", "arguments", "params", "command" };
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return toolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn toolOutputAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "rawOutput", "output", "result", "content" };
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return toolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn toolErrorAlloc(
    allocator: std.mem.Allocator,
    update: std.json.Value,
    status: ?provider_types.ToolCallStatus,
) !?[]u8 {
    const field_names = [_][]const u8{ "error", "errorMessage" };
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (try toolFieldsAlloc(allocator, tool_call, &field_names)) |value| return value;
    }
    if ((status orelse .unknown) != .failed) return null;
    if (getTrimmedObjectString(update, "body")) |body| return try allocator.dupe(u8, body);
    if (getTrimmedObjectString(update, "description")) |description| return try allocator.dupe(u8, description);
    return null;
}

fn toolLocationsAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{"locations"};
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return toolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn toolFieldsAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    field_names: []const []const u8,
) !?[]u8 {
    for (field_names) |field_name| {
        const field = getObjectField(value, field_name) orelse continue;
        switch (field) {
            .string => |text| {
                const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
                if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
            },
            .object => |object| {
                if (object.count() == 0) continue;
                const json = (try jsonObjectForToolDisplayAlloc(allocator, object)) orelse continue;
                const trimmed = std.mem.trim(u8, json, &std.ascii.whitespace);
                if (trimmed.len == 0) {
                    allocator.free(json);
                    continue;
                }
                return json;
            },
            .array => |array| {
                if (array.items.len == 0) continue;
                const json = try jsonValueCompactAlloc(allocator, field);
                const trimmed = std.mem.trim(u8, json, &std.ascii.whitespace);
                if (trimmed.len == 0) {
                    allocator.free(json);
                    continue;
                }
                return json;
            },
            else => {},
        }
    }
    return null;
}

fn jsonObjectForToolDisplayAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?[]u8 {
    if (object.count() == 0) return null;
    if (object.count() == 1 and object.get(MCP_TOOL_NAME_FIELD) != null) return null;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    var fields = object.iterator();
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field.key_ptr.*, MCP_TOOL_NAME_FIELD)) continue;
        try stringify.objectField(field.key_ptr.*);
        try stringify.write(field.value_ptr.*);
    }
    try stringify.endObject();
    const json = try writer.toOwnedSlice();
    return @as(?[]u8, json);
}

fn jsonValueCompactAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(value);
    return writer.toOwnedSlice();
}

fn getTrimmedObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const text = getOptionalObjectString(value, key) orelse return null;
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return if (trimmed.len > 0) trimmed else null;
}

fn appendChatMessageChunk(
    allocator: std.mem.Allocator,
    harness: Harness,
    messages: *std.ArrayList(provider_types.ChatMessage),
    role: provider_types.MessageRole,
    text: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (messages.items.len > 0 and messages.items[messages.items.len - 1].role == role) {
        const old = messages.items[messages.items.len - 1].body;
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ old, text });
        allocator.free(old);
        messages.items[messages.items.len - 1].body = combined;
        return;
    }
    try messages.append(allocator, .{
        .role = role,
        .author = try allocator.dupe(u8, switch (role) {
            .user => "You",
            .assistant => harness.assistant_author,
            .system => "System",
        }),
        .body = try allocator.dupe(u8, trimmed),
    });
}

fn writeJsonRpcHead(stringify: *std.json.Stringify, id: i64, method: []const u8) !void {
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("method");
    try stringify.write(method);
}

fn makeSessionSetupRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    session_id: ?[]const u8,
    cwd: []const u8,
    mcp_server: ?McpServer,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, method);
    try stringify.objectField("params");
    try stringify.beginObject();
    if (session_id) |sid| {
        try stringify.objectField("sessionId");
        try stringify.write(sid);
    }
    try stringify.objectField("cwd");
    try stringify.write(cwd);
    try stringify.objectField("mcpServers");
    try stringify.beginArray();
    if (mcp_server) |server| {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write("verde");
        switch (server) {
            .stdio => |executable| {
                try stringify.objectField("command");
                try stringify.write(executable);
                try stringify.objectField("args");
                try stringify.beginArray();
                try stringify.write("mcp");
                try stringify.endArray();
                try stringify.objectField("env");
                try stringify.beginArray();
                try writeAcpNameValue(&stringify, "VERDE_MCP_MANAGED", "1");
                try stringify.endArray();
            },
            .http => |http| {
                try stringify.objectField("type");
                try stringify.write("http");
                try stringify.objectField("url");
                try stringify.write(http.url);
                try stringify.objectField("headers");
                try stringify.beginArray();
                try writeAcpNameValue(&stringify, "Authorization", http.authorization);
                try writeAcpNameValue(&stringify, "X-Verde-MCP-Client", http.client_name);
                try writeAcpNameValue(&stringify, "X-Verde-MCP-Managed", "1");
                try stringify.endArray();
            },
        }
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn writeAcpNameValue(stringify: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try stringify.beginObject();
    try stringify.objectField("name");
    try stringify.write(name);
    try stringify.objectField("value");
    try stringify.write(value);
    try stringify.endObject();
}

fn writeImageContentBlock(allocator: std.mem.Allocator, stringify: *std.json.Stringify, image: provider_types.ImageAttachment) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), image.path, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(bytes);
    const encoded = try encodeBase64Alloc(allocator, bytes);
    defer allocator.free(encoded);

    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("image");
    try stringify.objectField("mimeType");
    try stringify.write(mimeTypeForPath(image.path));
    try stringify.objectField("data");
    try stringify.write(encoded);
    try stringify.endObject();
}

fn collectImageAttachments(allocator: std.mem.Allocator, request: provider_types.SendPromptRequest) ![]const provider_types.ImageAttachment {
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

fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn mimeTypeForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    return "image/png";
}

fn isAuthError(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "auth") != null or
        std.mem.indexOf(u8, message, "login") != null or
        std.mem.indexOf(u8, message, "API key") != null or
        std.mem.indexOf(u8, message, "unauthorized") != null;
}

const TEST_HARNESS: Harness = .{
    .diagnostics_category = .cursor_acp,
    .assistant_author = "Assistant",
    .permission_default_title = "Permission request",
};

const TestDiffCapture = struct {
    count: usize = 0,
    path: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    patch_storage: [4096]u8 = undefined,
    additions: i64 = 0,
    deletions: i64 = 0,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *TestDiffCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .diff => |diff| {
                if (diff.files.len == 0) return;
                self.count += 1;
                self.path = diff.files[0].path;
                if (diff.files[0].patch) |patch| {
                    if (patch.len <= self.patch_storage.len) {
                        @memcpy(self.patch_storage[0..patch.len], patch);
                        self.patch = self.patch_storage[0..patch.len];
                    }
                }
                self.additions = diff.files[0].additions;
                self.deletions = diff.files[0].deletions;
            },
            else => {},
        }
    }
};

test "makeInitializeRequestAlloc writes ACP initialize JSON-RPC" {
    const json = try makeInitializeRequestAlloc(std.testing.allocator, 42);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), getOptionalObjectInteger(parsed.value, "id").?);
    try std.testing.expect(responseId(parsed.value) == null);
    try std.testing.expectEqualStrings("initialize", getOptionalObjectString(parsed.value, "method").?);
}

test "session setup passes Verde MCP through ACP" {
    const json = try makeSessionNewRequestAlloc(std.testing.allocator, 2, "/tmp/project", "/opt/verde/bin/verde");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const params = getObjectField(parsed.value, "params").?;
    const servers = getObjectField(params, "mcpServers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), servers.len);
    try std.testing.expectEqualStrings("verde", getOptionalObjectString(servers[0], "name").?);
    try std.testing.expectEqualStrings("/opt/verde/bin/verde", getOptionalObjectString(servers[0], "command").?);
    const args = getObjectField(servers[0], "args").?.array.items;
    try std.testing.expectEqualStrings("mcp", args[0].string);
    const environment = getObjectField(servers[0], "env").?.array.items;
    try std.testing.expectEqualStrings("VERDE_MCP_MANAGED", getOptionalObjectString(environment[0], "name").?);
    try std.testing.expectEqualStrings("1", getOptionalObjectString(environment[0], "value").?);
}

test "session setup passes authenticated Verde HTTP MCP through ACP" {
    const json = try makeSessionNewRequestWithHttpMcpAlloc(std.testing.allocator, 2, "/tmp/project", .{
        .url = "http://127.0.0.1:47371/mcp",
        .authorization = "Bearer test-token",
        .client_name = "fx",
    });
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const params = getObjectField(parsed.value, "params").?;
    const server = getObjectField(params, "mcpServers").?.array.items[0];
    try std.testing.expectEqualStrings("http", getOptionalObjectString(server, "type").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:47371/mcp", getOptionalObjectString(server, "url").?);
    const headers = getObjectField(server, "headers").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("Authorization", getOptionalObjectString(headers[0], "name").?);
    try std.testing.expectEqualStrings("Bearer test-token", getOptionalObjectString(headers[0], "value").?);
    try std.testing.expectEqualStrings("fx", getOptionalObjectString(headers[1], "value").?);
}

test "makePromptRequestAlloc writes text and image content blocks" {
    const request = provider_types.SendPromptRequest{ .prompt = "hello" };
    const json = try makePromptRequestAlloc(std.testing.allocator, 3, "session-1", request, true);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const params = getObjectField(parsed.value, "params").?;
    try std.testing.expectEqualStrings("session-1", getOptionalObjectString(params, "sessionId").?);
    const prompt = getObjectField(params, "prompt").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), prompt.len);
    try std.testing.expectEqualStrings("text", getOptionalObjectString(prompt[0], "type").?);
}

test "parseSessionListResponse maps ACP sessions to thread summaries" {
    const payload =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"s1","cwd":"/tmp","title":"One"},{"sessionId":"s2","cwd":"/tmp"}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
    defer {
        for (threads.items) |thread| {
            std.testing.allocator.free(thread.id);
            std.testing.allocator.free(thread.title);
        }
        threads.deinit(std.testing.allocator);
    }
    try parseSessionListResponse(std.testing.allocator, parsed.value, &threads);
    try std.testing.expectEqual(@as(usize, 2), threads.items.len);
    try std.testing.expectEqualStrings("s1", threads.items[0].id);
    try std.testing.expectEqualStrings("One", threads.items[0].title);
    try std.testing.expectEqualStrings("s2", threads.items[1].title);
}

test "handleReadSessionUpdate combines consecutive role chunks" {
    var state: ReadThreadState = .{};
    defer state.deinit(std.testing.allocator);
    const one =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hel"}}}}
    ;
    const two =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}}}
    ;
    var parsed_one = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, one, .{});
    defer parsed_one.deinit();
    var parsed_two = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, two, .{});
    defer parsed_two.deinit();
    try handleReadSessionUpdate(std.testing.allocator, TEST_HARNESS, parsed_one.value, &state);
    try handleReadSessionUpdate(std.testing.allocator, TEST_HARNESS, parsed_two.value, &state);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("hello", state.messages.items[0].body);
    try std.testing.expectEqualStrings("Assistant", state.messages.items[0].author);
}

test "ACP tool updates emit structured diff snapshots" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCall":{"input":{"filePath":"src/main.zig"},"output":{"patch":"--- a/src/main.zig\n+++ b/src/main.zig\n@@ -1 +1,2 @@\n-old\n+new\n+again"}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestDiffCapture = .{};
    emitDiffUpdate(std.testing.allocator, parsed.value, null, &capture, TestDiffCapture.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("src/main.zig", capture.path.?);
    try std.testing.expectEqual(@as(i64, 2), capture.additions);
    try std.testing.expectEqual(@as(i64, 1), capture.deletions);
}

test "ACP text diff content emits a compact structured patch" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-1","title":"Edit File","kind":"edit","status":"completed","content":[{"type":"diff","path":"src/main.zig","oldText":"const a = 1;\nconst b = 2;\nconst c = 3;\n","newText":"const a = 1;\nconst b = 4;\nconst c = 3;\n"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestDiffCapture = .{};
    emitDiffUpdate(std.testing.allocator, parsed.value, null, &capture, TestDiffCapture.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("src/main.zig", capture.path.?);
    try std.testing.expectEqual(@as(i64, 1), capture.additions);
    try std.testing.expectEqual(@as(i64, 1), capture.deletions);
    try std.testing.expectEqualStrings(
        "--- a/src/main.zig\n" ++
            "+++ b/src/main.zig\n" ++
            "@@ -1,3 +1,3 @@\n" ++
            " const a = 1;\n" ++
            "-const b = 2;\n" ++
            "+const b = 4;\n" ++
            " const c = 3;\n",
        capture.patch.?,
    );
}

test "ACP text diff content preserves new-file semantics" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","content":[{"type":"diff","path":"src/new.zig","oldText":null,"newText":"const created = true;\n"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestDiffCapture = .{};
    emitDiffUpdate(std.testing.allocator, parsed.value, null, &capture, TestDiffCapture.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(i64, 1), capture.additions);
    try std.testing.expectEqual(@as(i64, 0), capture.deletions);
    try std.testing.expect(std.mem.startsWith(u8, capture.patch.?, "--- /dev/null\n+++ b/src/new.zig\n"));
}

test "ACP serialized tool output emits a structured text diff" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed"}
    ;
    const output =
        \\[{"type":"diff","path":"tmp/temp.txt","oldText":"before\n","newText":"before\nafter\n"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestDiffCapture = .{};
    emitDiffUpdate(std.testing.allocator, parsed.value, output, &capture, TestDiffCapture.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("tmp/temp.txt", capture.path.?);
    try std.testing.expectEqual(@as(i64, 1), capture.additions);
    try std.testing.expectEqual(@as(i64, 0), capture.deletions);
    try std.testing.expect(std.mem.indexOf(u8, capture.patch.?, "+after\n") != null);
}

test "toolEvent preserves status-only ACP lifecycle updates" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"in_progress"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("call-1", event.call_id);
    try std.testing.expectEqualStrings("", event.title);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, event.status.?);
    try std.testing.expect(event.tool_kind == null);
    try std.testing.expect(event.input == null);
    try std.testing.expect(event.output == null);
}

test "toolEvent keeps meaningful ACP tool text" {
    const payload =
        \\{"sessionUpdate":"tool_call","title":"Shell","command":"git status --short","status":"pending"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Shell", event.title);
    try std.testing.expectEqual(provider_types.ToolCallKind.execute, event.tool_kind.?);
    try std.testing.expectEqualStrings("git status --short", event.input.?);
}

test "toolEvent keeps non-lifecycle status failures" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolName":"edit","status":"failed"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("edit", event.title);
    try std.testing.expectEqual(provider_types.ToolCallStatus.failed, event.status.?);
}

test "toolEvent shows tool call starts with structured input" {
    const payload =
        \\{"sessionUpdate":"tool_call","toolName":"Read","input":{"path":"/tmp/a.txt"},"status":"pending"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Read", event.title);
    try std.testing.expectEqual(provider_types.ToolCallKind.read, event.tool_kind.?);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp/a.txt\"}", event.input.?);
}

test "toolEvent ignores empty ACP input containers" {
    const payload =
        \\{"sessionUpdate":"tool_call","toolCallId":"call-2","title":"Read File","kind":"read","rawInput":{},"locations":[{"path":"/tmp/a.txt"}],"status":"pending"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.input == null);
    try std.testing.expectEqualStrings("[{\"path\":\"/tmp/a.txt\"}]", event.locations.?);
    try std.testing.expectEqualStrings(payload, event.raw);
}

test "toolEvent ignores empty ACP output arrays" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-3","title":"MCP: tool","kind":"other","content":[],"status":"completed"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(provider_types.ToolCallKind.mcp, event.tool_kind.?);
    try std.testing.expect(event.output == null);
    try std.testing.expectEqualStrings(payload, event.raw);
}

test "toolEvent promotes tagged Verde MCP results into the title" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-4","status":"completed","rawOutput":{"success":true,"_verdeMcpTool":"navigate_browser"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("MCP: navigate_browser", event.title);
    try std.testing.expectEqual(provider_types.ToolCallKind.mcp, event.tool_kind.?);
    try std.testing.expectEqualStrings("{\"success\":true}", event.output.?);
}

test "handleSendPromptLine accepts session/load response without sessionId" {
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{
        .thread_id = "existing-session",
        .prompt = "continue",
    };
    const line =
        \\{"jsonrpc":"2.0","id":2,"result":{"models":{"currentModelId":"composer-2[fast=true]"}}}
    ;
    const action = try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null);
    try std.testing.expectEqual(SendLineAction.session_ready, action);
    try std.testing.expectEqualStrings("existing-session", state.session_id.?);
}

test "handleSendPromptLine fails the turn when the prompt result is refused" {
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    state.prompt_submitted = true;
    const request = provider_types.SendPromptRequest{ .prompt = "yo" };
    const refused =
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"refused"}}
    ;
    try std.testing.expectError(error.AcpRefused, handleSendPromptLine(std.testing.allocator, TEST_HARNESS, refused, request, &state, null));
    const done =
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
    ;
    try std.testing.expectEqual(SendLineAction.prompt_done, try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, done, request, &state, null));
}

test "handleSendPromptLine routes leading diagnostic chunks to a system event" {
    const Capture = struct {
        var events: usize = 0;
        fn onEvent(_: ?*anyopaque, event: provider_types.StreamEvent) void {
            switch (event) {
                .message => |message| {
                    if (std.mem.eql(u8, message.title, "FX warning")) events += 1;
                },
                else => {},
            }
        }
    };
    Capture.events = 0;
    const harness: Harness = .{
        .diagnostics_category = .cursor_acp,
        .assistant_author = "Assistant",
        .permission_default_title = "Permission request",
        .diagnostic_chunk_prefix = "skill discovery warning:",
        .diagnostic_event_title = "FX warning",
    };
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    state.prompt_submitted = true;
    const request = provider_types.SendPromptRequest{ .prompt = "yo", .on_stream_event = Capture.onEvent };
    const warning =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"skill discovery warning: candidate skipped"}}}}
    ;
    const reply =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Ready."}}}}
    ;
    _ = try handleSendPromptLine(std.testing.allocator, harness, warning, request, &state, null);
    _ = try handleSendPromptLine(std.testing.allocator, harness, reply, request, &state, null);
    // A later chunk with the prefix is real reply text, not a diagnostic.
    _ = try handleSendPromptLine(std.testing.allocator, harness, warning, request, &state, null);
    try std.testing.expectEqual(@as(usize, 1), Capture.events);
    try std.testing.expectEqualStrings("Ready.skill discovery warning: candidate skipped", state.reply.items);
}

test "handleSendPromptLine ignores session history replay before prompt submission" {
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{
        .thread_id = "existing-session",
        .prompt = "continue",
    };
    const line =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"existing-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"replayed history"}}}}
    ;

    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null),
    );
    try std.testing.expectEqual(@as(usize, 0), state.reply.items.len);

    state.prompt_submitted = true;
    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null),
    );
    try std.testing.expectEqualStrings("replayed history", state.reply.items);
}

test "handleSendPromptLine handles permission request id collision before prompt response" {
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{
        .thread_id = "existing-session",
        .prompt = "continue",
        .approval_policy = .never,
    };
    const line =
        \\{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{"toolCallId":"tool-3","options":[{"optionId":"reject-once"},{"optionId":"allow-once"}]}}
    ;

    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null),
    );
}

test "handleSendPromptLine ignores non-permission ACP server request id collisions" {
    var state: SendPromptState = .{
        .capabilities = .{ .image = true },
        .prompt_submitted = true,
    };
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{
        .thread_id = "existing-session",
        .prompt = "continue",
    };
    const initialize_collision =
        \\{"jsonrpc":"2.0","id":1,"method":"fs/read_text_file","params":{"path":"/tmp/example"}}
    ;
    const session_collision =
        \\{"jsonrpc":"2.0","id":2,"method":"terminal/wait_for_exit","params":{"terminalId":"terminal-1"}}
    ;

    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, initialize_collision, request, &state, null),
    );
    try std.testing.expect(state.capabilities.image);
    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, session_collision, request, &state, null),
    );
    try std.testing.expect(state.session_id == null);
}

test "auto-approve permission requests when approval policy is never" {
    try std.testing.expect(shouldAutoApprovePermission(.{
        .prompt = "continue",
        .approval_policy = .never,
    }));
    try std.testing.expect(!shouldAutoApprovePermission(.{
        .prompt = "continue",
        .approval_policy = .on_request,
    }));
}

test "makePermissionResponseAlloc writes selected ACP option id" {
    const approve = try makePermissionResponseAlloc(std.testing.allocator, 9, "allow-always");
    defer std.testing.allocator.free(approve);
    const deny = try makePermissionResponseAlloc(std.testing.allocator, 10, "reject-once");
    defer std.testing.allocator.free(deny);
    try std.testing.expect(std.mem.indexOf(u8, approve, "allow-always") != null);
    try std.testing.expect(std.mem.indexOf(u8, deny, "reject-once") != null);
}

test "permissionOptionId chooses matching ACP request options" {
    const payload =
        \\{"options":[{"optionId":"reject-once"},{"optionId":"allow-once"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("allow-once", permissionOptionId(parsed.value, .approve));
    try std.testing.expectEqualStrings("reject-once", permissionOptionId(parsed.value, .deny));
}

test "permissionOptionId matches FX underscore option ids" {
    const payload =
        \\{"options":[{"optionId":"allow_once","name":"Allow once"},{"optionId":"allow_always","name":"Allow for this session"},{"optionId":"reject_once","name":"Reject"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("allow_once", permissionOptionId(parsed.value, .approve));
    try std.testing.expectEqualStrings("reject_once", permissionOptionId(parsed.value, .deny));
}

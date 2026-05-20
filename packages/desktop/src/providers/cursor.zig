//! Cursor provider harness backed by Cursor CLI ACP (`agent acp`).

const std = @import("std");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");
const runtime_log = @import("../runtime_log.zig");

const DEFAULT_EXECUTABLE = "agent";
const FALLBACK_EXECUTABLE = "cursor-agent";
const DEFAULT_MODEL = "composer-2";
const MAX_ACP_LINE_BYTES = 16 * 1024 * 1024;
const MAX_CURSOR_OUTPUT_BYTES = 8 * 1024 * 1024;

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const ActiveProcessState = struct {
    mutex: Mutex = .{},
    child: ?*std.process.Child = null,
    stdin: ?std.Io.File = null,
    session_id: ?[]const u8 = null,
};

var active_process_state: ActiveProcessState = .{};

pub const Config = struct {
    executable: []const u8 = DEFAULT_EXECUTABLE,
    cwd: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = DEFAULT_MODEL,
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

    pub fn authState(self: *Client) !provider_types.AuthState {
        var env_map = try self.cursorEnvMap(self.allocator);
        defer env_map.deinit();

        const executable = self.resolveExecutable(self.allocator, &env_map) catch |err| switch (err) {
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer self.allocator.free(executable);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const result = std.process.run(self.allocator, threaded.io(), .{
            .argv = &.{ executable, "status", "--format", "json" },
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
            .stdout_limit = .limited(MAX_CURSOR_OUTPUT_BYTES),
            .stderr_limit = .limited(512 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) return .signed_out,
            else => return .signed_out,
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result.stdout, .{}) catch return .unknown;
        defer parsed.deinit();
        if (getOptionalObjectBool(parsed.value, "isAuthenticated") orelse false) return .signed_in;
        if (getOptionalObjectString(parsed.value, "status")) |status| {
            if (std.mem.eql(u8, status, "authenticated")) return .signed_in;
        }
        return .signed_out;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var acp = try self.spawnAcp(allocator, null);
        defer acp.deinit();

        var state: ListThreadsState = .{};
        errdefer state.deinit(allocator);

        try acp.writeLine(try makeInitializeRequestAlloc(allocator, 1));
        try acp.writeLine(try makeSessionListRequestAlloc(allocator, 2, try self.cwdAbsoluteAlloc(allocator)));
        try acp.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = acp.child.stdout.?.reader(acp.threaded.io(), &read_buffer);
        while (try takeAcpLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try handleListThreadsLine(allocator, line, &state)) break;
        }

        acp.stop();
        const threads = try state.threads.toOwnedSlice(allocator);
        state.threads = .empty;
        return threads;
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var env_map = try self.cursorEnvMap(allocator);
        defer env_map.deinit();

        const executable = self.resolveExecutable(allocator, &env_map) catch return staticModelsAlloc(allocator);
        defer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const result = std.process.run(allocator, threaded.io(), .{
            .argv = &.{ executable, "models" },
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
            .stdout_limit = .limited(MAX_CURSOR_OUTPUT_BYTES),
            .stderr_limit = .limited(512 * 1024),
        }) catch return staticModelsAlloc(allocator);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) return staticModelsAlloc(allocator),
            else => return staticModelsAlloc(allocator),
        }
        return parseModelsTextAlloc(allocator, result.stdout) catch staticModelsAlloc(allocator);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var acp = try self.spawnAcp(allocator, null);
        defer acp.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);

        var state: ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try acp.writeLine(try makeInitializeRequestAlloc(allocator, 1));
        try acp.writeLine(try makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd));
        try acp.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = acp.child.stdout.?.reader(acp.threaded.io(), &read_buffer);
        while (try takeAcpLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try handleReadThreadLine(allocator, line, thread_id, &state)) break;
        }

        acp.stop();
        const messages = try state.messages.toOwnedSlice(allocator);
        state.messages = .empty;
        const title = if (state.title) |title| title else try allocator.dupe(u8, thread_id);
        state.title = null;
        return .{
            .thread_id = try allocator.dupe(u8, thread_id),
            .title = title,
            .messages = messages,
        };
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const model_arg = try cursorModelArgAlloc(allocator, request.model orelse self.config.model orelse DEFAULT_MODEL, request.cursor_model_params_json);
        defer if (model_arg) |arg| allocator.free(arg);

        var acp = try self.spawnAcp(allocator, model_arg);
        defer acp.deinit();

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);

        var state: SendPromptState = .{};
        errdefer state.deinit(allocator);

        try acp.writeLine(try makeInitializeRequestAlloc(allocator, 1));
        if (request.thread_id) |thread_id| {
            try acp.writeLine(try makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd));
        } else {
            try acp.writeLine(try makeSessionNewRequestAlloc(allocator, 2, cwd));
        }

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = acp.child.stdout.?.reader(acp.threaded.io(), &read_buffer);
        while (try takeAcpLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const action = try handleSendPromptLine(allocator, line, request, &state, acp.child.stdin);
            switch (action) {
                .continue_reading => {},
                .session_ready => {
                    if (state.session_id) |session_id| {
                        registerActiveChild(&acp.child, acp.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        try acp.writeLine(try makePromptRequestAlloc(allocator, 3, session_id, request, state.capabilities.image));
                    }
                },
                .prompt_done => break,
            }
            if (request.on_should_stop) |should_stop| {
                if (should_stop(request.stream_context)) {
                    if (state.session_id) |session_id| {
                        try acp.writeLine(try makeCancelNotificationAlloc(allocator, session_id));
                    }
                    return error.CodexTurnInterrupted;
                }
            }
        }

        unregisterActiveChild(&acp.child);
        try acp.closeStdin();
        acp.stop();

        const thread_id = state.session_id orelse return error.CursorAcpFailed;
        state.session_id = null;
        const reply_text = try state.reply.toOwnedSlice(allocator);
        state.reply = .empty;
        return .{
            .thread_id = thread_id,
            .reply_text = reply_text,
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        _ = self;
        active_process_state.mutex.lock();
        defer active_process_state.mutex.unlock();

        const child = active_process_state.child orelse return;
        const session_id = active_process_state.session_id orelse return;
        if (!std.mem.eql(u8, session_id, request.thread_id)) return;
        if (active_process_state.stdin) |stdin| {
            const line = try makeCancelNotificationAlloc(std.heap.page_allocator, session_id);
            defer std.heap.page_allocator.free(line);
            writeJsonLineToFile(std.heap.page_allocator, stdin, line) catch {
                var threaded = std.Io.Threaded.init_single_threaded;
                child.kill(threaded.io());
            };
        } else {
            var threaded = std.Io.Threaded.init_single_threaded;
            child.kill(threaded.io());
        }
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn cursorEnvMap(self: *Client, allocator: std.mem.Allocator) !std.process.Environ.Map {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        errdefer env_map.deinit();
        try ensureCursorApiKeyEnv(allocator, self.config, &env_map);
        return env_map;
    }

    fn resolveExecutable(self: *Client, allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
        return resolveCursorExecutableAlloc(allocator, env_map, self.config.executable);
    }

    fn spawnAcp(self: *Client, allocator: std.mem.Allocator, model_arg: ?[]const u8) !AcpProcess {
        var env_map = try self.cursorEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try self.resolveExecutable(allocator, &env_map);
        errdefer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const argv_with_model = [_][]const u8{ executable, "--model", model_arg orelse "", "acp" };
        const argv_default = [_][]const u8{ executable, "acp" };
        var child = try std.process.spawn(threaded.io(), .{
            .argv = if (model_arg != null) argv_with_model[0..] else argv_default[0..],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());
        if (child.id) |pid| _ = std.c.setpgid(pid, pid);

        return .{
            .allocator = allocator,
            .threaded = threaded,
            .child = child,
            .env_map = env_map,
            .executable = executable,
        };
    }

    fn cwdAbsoluteAlloc(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        if (self.config.cwd) |cwd| return std.fs.path.resolve(allocator, &.{cwd});
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        return std.process.currentPathAlloc(threaded.io(), allocator);
    }

    fn cwdAbsoluteAllocForRequest(self: *Client, allocator: std.mem.Allocator, request: provider_types.SendPromptRequest) ![]u8 {
        if (request.cwd) |cwd| return std.fs.path.resolve(allocator, &.{cwd});
        return self.cwdAbsoluteAlloc(allocator);
    }
};

pub fn shutdownOwnedServer() void {}

const AcpProcess = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    child: std.process.Child,
    env_map: std.process.Environ.Map,
    executable: []u8,
    finished: bool = false,

    fn writeLine(self: *AcpProcess, line: []u8) !void {
        defer self.allocator.free(line);
        const stdin = self.child.stdin orelse return error.ConnectionClosed;
        try writeJsonLineToFile(self.allocator, stdin, line);
    }

    fn closeStdin(self: *AcpProcess) !void {
        if (self.child.stdin) |stdin| {
            stdin.close(self.threaded.io());
            self.child.stdin = null;
        }
    }

    fn stop(self: *AcpProcess) void {
        if (self.finished or self.child.id == null) return;
        self.child.kill(self.threaded.io());
        self.finished = true;
        self.child.stdin = null;
        self.child.stdout = null;
    }

    fn deinit(self: *AcpProcess) void {
        unregisterActiveChild(&self.child);
        if (!self.finished and self.child.id != null) {
            self.child.kill(self.threaded.io());
        }
        if (self.child.stdin) |stdin| stdin.close(self.threaded.io());
        self.env_map.deinit();
        self.allocator.free(self.executable);
        self.threaded.deinit();
    }
};

fn registerActiveChild(child: *std.process.Child, stdin: ?std.Io.File, session_id: []const u8) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    active_process_state.child = child;
    active_process_state.stdin = stdin;
    active_process_state.session_id = session_id;
}

fn unregisterActiveChild(child: *std.process.Child) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    if (active_process_state.child == child) {
        active_process_state.child = null;
        active_process_state.stdin = null;
        active_process_state.session_id = null;
    }
}

fn takeAcpLineAlloc(allocator: std.mem.Allocator, reader: anytype) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    _ = reader.interface.streamDelimiterLimit(&writer.writer, '\n', .limited(MAX_ACP_LINE_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => return error.CursorAcpMessageTooLarge,
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

const AcpCapabilities = struct {
    image: bool = false,
    load_session: bool = false,
    list_sessions: bool = false,
};

const ListThreadsState = struct {
    saw_initialize: bool = false,
    threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty,

    fn deinit(self: *ListThreadsState, allocator: std.mem.Allocator) void {
        for (self.threads.items) |thread| {
            allocator.free(thread.id);
            allocator.free(thread.title);
        }
        self.threads.deinit(allocator);
    }
};

const ReadThreadState = struct {
    saw_initialize: bool = false,
    messages: std.ArrayList(provider_types.ChatMessage) = .empty,
    title: ?[]u8 = null,

    fn deinit(self: *ReadThreadState, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        self.messages.deinit(allocator);
        if (self.title) |title| allocator.free(title);
    }
};

const SendPromptState = struct {
    capabilities: AcpCapabilities = .{},
    session_id: ?[]u8 = null,
    reply: std.ArrayList(u8) = .empty,

    fn deinit(self: *SendPromptState, allocator: std.mem.Allocator) void {
        if (self.session_id) |session_id| allocator.free(session_id);
        self.reply.deinit(allocator);
    }
};

const SendLineAction = enum {
    continue_reading,
    session_ready,
    prompt_done,
};

fn handleListThreadsLine(allocator: std.mem.Allocator, line: []const u8, state: *ListThreadsState) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(parsed.value);
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

fn handleReadThreadLine(allocator: std.mem.Allocator, line: []const u8, thread_id: []const u8, state: *ReadThreadState) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(parsed.value);
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
        try handleReadSessionUpdate(allocator, parsed.value, state);
    }
    return false;
}

fn handleSendPromptLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
    stdin: ?std.Io.File,
) !SendLineAction {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(parsed.value);

    if (responseId(parsed.value)) |id| {
        if (id == 1) {
            state.capabilities = parseCapabilities(parsed.value);
            return .continue_reading;
        }
        if (id == 2) {
            if (state.session_id == null) {
                const session_id = parseSessionId(parsed.value) orelse request.thread_id orelse return error.CursorAcpFailed;
                state.session_id = try allocator.dupe(u8, session_id);
            }
            return .session_ready;
        }
        if (id == 3) return .prompt_done;
    }

    if (isMethod(parsed.value, "session/request_permission")) {
        try handlePermissionRequest(allocator, parsed.value, request, stdin);
        return .continue_reading;
    }
    if (isMethod(parsed.value, "session/update")) {
        try handleLiveSessionUpdate(allocator, parsed.value, request, state);
        return .continue_reading;
    }
    return .continue_reading;
}

fn makeInitializeRequestAlloc(allocator: std.mem.Allocator, id: i64) ![]u8 {
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

fn makeSessionListRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd_owned: []u8) ![]u8 {
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

fn makeSessionNewRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd: []const u8) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/new", null, cwd);
}

fn makeSessionLoadRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, cwd: []const u8) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/load", session_id, cwd);
}

fn makeSessionSetupRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    session_id: ?[]const u8,
    cwd: []const u8,
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
    try stringify.endArray();
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn makePromptRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    session_id: []const u8,
    request: provider_types.SendPromptRequest,
    image_supported: bool,
) ![]u8 {
    const images = try collectImageAttachments(allocator, request);
    defer allocator.free(images);
    if (images.len > 0 and !image_supported) return error.CursorAttachmentsUnsupported;

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

fn makeCancelNotificationAlloc(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
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

fn makePermissionResponseAlloc(allocator: std.mem.Allocator, id: i64, option_id: []const u8) ![]u8 {
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

fn writeJsonRpcHead(stringify: *std.json.Stringify, id: i64, method: []const u8) !void {
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("method");
    try stringify.write(method);
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

fn writeJsonLineToFile(allocator: std.mem.Allocator, file: std.Io.File, line: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn responseId(value: std.json.Value) ?i64 {
    return getOptionalObjectInteger(value, "id");
}

fn isMethod(value: std.json.Value, method: []const u8) bool {
    const actual = getOptionalObjectString(value, "method") orelse return false;
    return std.mem.eql(u8, actual, method);
}

fn failIfJsonRpcError(value: std.json.Value) !void {
    const error_value = getObjectField(value, "error") orelse return;
    const message = getOptionalObjectString(error_value, "message") orelse "";
    if (isAuthError(message)) return error.CursorSignedOut;
    runtime_log.diagnostic("cursor.acp error: {s}", .{message});
    return error.CursorAcpFailed;
}

fn parseCapabilities(value: std.json.Value) AcpCapabilities {
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

fn parseSessionId(value: std.json.Value) ?[]const u8 {
    const result = getObjectField(value, "result") orelse return null;
    return getOptionalObjectString(result, "sessionId");
}

fn parseSessionListResponse(
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

fn handleReadSessionUpdate(allocator: std.mem.Allocator, value: std.json.Value, state: *ReadThreadState) !void {
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
    try appendChatMessageChunk(allocator, &state.messages, role, text);
}

fn handleLiveSessionUpdate(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
) !void {
    const update = sessionUpdateObject(value) orelse return;
    const kind = getOptionalObjectString(update, "sessionUpdate") orelse return;
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        const text = contentText(update) orelse return;
        if (text.len == 0) return;
        try state.reply.appendSlice(allocator, text);
        if (request.on_stream_delta) |on_stream_delta| {
            on_stream_delta(request.stream_context, text);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
        const event = (try cursorToolEventAlloc(allocator, update, kind)) orelse return;
        defer event.deinit(allocator);
        if (request.on_stream_event) |on_stream_event| {
            on_stream_event(request.stream_context, .{ .message = .{ .title = event.title, .body = event.body } });
        }
    }
}

fn handlePermissionRequest(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    request: provider_types.SendPromptRequest,
    stdin: ?std.Io.File,
) !void {
    const id = responseId(value) orelse return;
    const params = getObjectField(value, "params") orelse value;
    const title = getOptionalObjectString(params, "title") orelse "Cursor permission request";
    const body = permissionBody(params);
    const call_id = getOptionalObjectString(params, "toolCallId") orelse getOptionalObjectString(params, "permissionId") orelse "cursor-tool";
    const decision = if (request.on_approval_request) |on_approval_request|
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

const CursorToolEvent = struct {
    title: []u8,
    body: []u8,

    fn deinit(self: CursorToolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

fn cursorToolEventAlloc(allocator: std.mem.Allocator, update: std.json.Value, kind: []const u8) !?CursorToolEvent {
    const title_text = cursorToolTitle(update);
    const body = try cursorToolBodyAlloc(allocator, update);
    errdefer if (body) |text| allocator.free(text);
    const status = getTrimmedObjectString(update, "status");

    if (body) |text| {
        if (isNoisyCursorToolStatus(text)) {
            allocator.free(text);
            return null;
        }
        return .{
            .title = try allocator.dupe(u8, title_text),
            .body = text,
        };
    }
    if (status) |text| {
        if (isNoisyCursorToolStatus(text)) return null;
        return .{
            .title = try allocator.dupe(u8, title_text),
            .body = try allocator.dupe(u8, text),
        };
    }
    if (std.mem.eql(u8, kind, "tool_call") and !std.mem.eql(u8, title_text, "Cursor tool")) {
        return .{
            .title = try allocator.dupe(u8, title_text),
            .body = try allocator.dupe(u8, "Started"),
        };
    }
    return null;
}

fn cursorToolTitle(update: std.json.Value) []const u8 {
    if (getTrimmedObjectString(update, "title")) |title| return title;
    if (getTrimmedObjectString(update, "name")) |name| return name;
    if (getTrimmedObjectString(update, "toolName")) |tool_name| return tool_name;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, "title")) |title| return title;
        if (getTrimmedObjectString(tool_call, "name")) |name| return name;
        if (getTrimmedObjectString(tool_call, "toolName")) |tool_name| return tool_name;
    }
    return "Cursor tool";
}

fn cursorToolBodyAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    if (getTrimmedObjectString(update, "command")) |command| return try toolBodyWithNameAlloc(allocator, update, command);
    if (getTrimmedObjectString(update, "body")) |body| return try allocator.dupe(u8, body);
    if (getTrimmedObjectString(update, "description")) |description| return try allocator.dupe(u8, description);
    if (try cursorToolStructuredBodyAlloc(allocator, update)) |body| return body;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, "command")) |command| return try toolBodyWithNameAlloc(allocator, update, command);
        if (getTrimmedObjectString(tool_call, "body")) |body| return try allocator.dupe(u8, body);
        if (getTrimmedObjectString(tool_call, "description")) |description| return try allocator.dupe(u8, description);
        if (try cursorToolStructuredBodyAlloc(allocator, tool_call)) |body| return body;
    }
    if (contentText(update)) |text| {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    return null;
}

fn cursorToolStructuredBodyAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "input", "args", "arguments", "rawInput", "params" };
    for (field_names) |field_name| {
        const field = getObjectField(value, field_name) orelse continue;
        switch (field) {
            .string => |text| {
                const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
                if (trimmed.len > 0) return try toolBodyWithNameAlloc(allocator, value, trimmed);
            },
            .object, .array => {
                const json = try jsonValueCompactAlloc(allocator, field);
                errdefer allocator.free(json);
                const trimmed = std.mem.trim(u8, json, &std.ascii.whitespace);
                if (trimmed.len == 0) {
                    allocator.free(json);
                    continue;
                }
                return try toolBodyWithNameOwnedAlloc(allocator, value, json);
            },
            else => {},
        }
    }
    return null;
}

fn toolBodyWithNameAlloc(allocator: std.mem.Allocator, update: std.json.Value, body: []const u8) ![]u8 {
    const title = cursorToolTitle(update);
    if (std.mem.eql(u8, title, "Cursor tool")) return allocator.dupe(u8, body);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ title, body });
}

fn toolBodyWithNameOwnedAlloc(allocator: std.mem.Allocator, update: std.json.Value, body: []u8) ![]u8 {
    const title = cursorToolTitle(update);
    if (std.mem.eql(u8, title, "Cursor tool")) return body;
    defer allocator.free(body);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ title, body });
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

fn isNoisyCursorToolStatus(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, "pending") or
        std.mem.eql(u8, trimmed, "in_progress") or
        std.mem.eql(u8, trimmed, "completed");
}

fn appendChatMessageChunk(
    allocator: std.mem.Allocator,
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
            .assistant => "Cursor",
            .system => "System",
        }),
        .body = try allocator.dupe(u8, trimmed),
    });
}

fn parseModelsTextAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]provider_types.ModelInfo {
    var raw_models: std.ArrayList(RawCursorModel) = .empty;
    defer raw_models.deinit(allocator);

    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or std.mem.eql(u8, line, "Available models")) continue;
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        const id = std.mem.trim(u8, line[0..sep], " \t");
        var name = std.mem.trim(u8, line[sep + 3 ..], " \t");
        if (std.mem.endsWith(u8, name, " (current)")) name = name[0 .. name.len - " (current)".len];
        if (std.mem.endsWith(u8, name, " (default)")) name = name[0 .. name.len - " (default)".len];
        if (id.len == 0 or name.len == 0) continue;
        try raw_models.append(allocator, .{ .id = id, .name = name });
    }
    if (raw_models.items.len == 0) return staticModelsAlloc(allocator);

    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    const consumed = try allocator.alloc(bool, raw_models.items.len);
    defer allocator.free(consumed);
    @memset(consumed, false);

    const pinned = [_][]const u8{ "auto", "composer-2.5", "composer-2" };
    for (pinned) |id| {
        _ = try appendCursorModelByBaseId(allocator, raw_models.items, consumed, &models, id);
    }

    for (raw_models.items, 0..) |raw, index| {
        if (consumed[index]) continue;
        if (stripFastSuffix(raw.id)) |base_id| {
            if (rawModelIndex(raw_models.items, base_id) != null) {
                _ = try appendCursorModelByBaseId(allocator, raw_models.items, consumed, &models, base_id);
                continue;
            }
        }
        try appendModel(allocator, &models, raw.id, raw.name, false);
        consumed[index] = true;
    }
    return models.toOwnedSlice(allocator);
}

const RawCursorModel = struct {
    id: []const u8,
    name: []const u8,
};

fn appendCursorModelByBaseId(
    allocator: std.mem.Allocator,
    raw_models: []const RawCursorModel,
    consumed: []bool,
    models: *std.ArrayList(provider_types.ModelInfo),
    base_id: []const u8,
) !bool {
    const fast_id = try std.fmt.allocPrint(allocator, "{s}-fast", .{base_id});
    defer allocator.free(fast_id);
    const base_index = rawModelIndex(raw_models, base_id);
    const fast_index = rawModelIndex(raw_models, fast_id);

    if (base_index) |index| {
        try appendModel(allocator, models, raw_models[index].id, raw_models[index].name, fast_index != null);
        consumed[index] = true;
        if (fast_index) |fi| consumed[fi] = true;
        return true;
    }
    if (fast_index) |index| {
        try appendModel(allocator, models, raw_models[index].id, raw_models[index].name, false);
        consumed[index] = true;
        return true;
    }
    return false;
}

fn rawModelIndex(raw_models: []const RawCursorModel, id: []const u8) ?usize {
    for (raw_models, 0..) |model, index| {
        if (std.mem.eql(u8, model.id, id)) return index;
    }
    return null;
}

fn stripFastSuffix(id: []const u8) ?[]const u8 {
    return if (std.mem.endsWith(u8, id, "-fast")) id[0 .. id.len - "-fast".len] else null;
}

fn staticModelsAlloc(allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    try appendModel(allocator, &models, "auto", "Auto", false);
    try appendModel(allocator, &models, "composer-2.5", "Composer 2.5", true);
    try appendModel(allocator, &models, "composer-2", "Composer 2", true);
    try appendModel(allocator, &models, "gpt-5.5-medium", "GPT-5.5", true);
    try appendModel(allocator, &models, "gpt-5.4-medium", "GPT-5.4", true);
    try appendModel(allocator, &models, "claude-opus-4-7-thinking-xhigh", "Claude Opus 4.7 Thinking", true);
    try appendModel(allocator, &models, "claude-sonnet-4-6", "Claude Sonnet 4.6", false);
    return models.toOwnedSlice(allocator);
}

fn appendModel(
    allocator: std.mem.Allocator,
    models: *std.ArrayList(provider_types.ModelInfo),
    id: []const u8,
    name: []const u8,
    fast_supported: bool,
) !void {
    try models.append(allocator, .{
        .provider_id = try allocator.dupe(u8, "cursor"),
        .provider_name = try allocator.dupe(u8, "Cursor"),
        .model_id = try allocator.dupe(u8, id),
        .model_name = try allocator.dupe(u8, name),
        .cursor_fast_supported = fast_supported,
    });
}

fn cursorModelArgAlloc(allocator: std.mem.Allocator, model: []const u8, params_json: ?[]const u8) !?[]u8 {
    const params = params_json orelse return try allocator.dupe(u8, model);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return try allocator.dupe(u8, model);

    var fast: ?bool = null;
    var reasoning: ?[]const u8 = null;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id = getOptionalObjectString(item, "id") orelse continue;
        const value = getOptionalObjectString(item, "value") orelse continue;
        if (std.mem.eql(u8, id, "fast")) {
            fast = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, id, "reasoning") or std.mem.eql(u8, id, "effort")) {
            reasoning = value;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, model);
    if (reasoning) |value| {
        if (!std.mem.eql(u8, value, "medium") and std.mem.indexOf(u8, model, value) == null) {
            try out.append(allocator, '-');
            try out.appendSlice(allocator, value);
        }
    }
    if (fast == true and !std.mem.endsWith(u8, out.items, "-fast")) {
        try out.appendSlice(allocator, "-fast");
    }
    return try out.toOwnedSlice(allocator);
}

fn resolveCursorExecutableAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    configured: []const u8,
) ![]u8 {
    const candidates = [_][]const u8{ configured, DEFAULT_EXECUTABLE, FALLBACK_EXECUTABLE };
    var tried: [3][]const u8 = .{ "", "", "" };
    var tried_len: usize = 0;
    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        var duplicate = false;
        for (tried[0..tried_len]) |old| {
            if (std.mem.eql(u8, old, candidate)) duplicate = true;
        }
        if (duplicate) continue;
        tried[tried_len] = candidate;
        tried_len += 1;
        return process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, candidate) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => continue,
            else => return err,
        };
    }
    runtime_log.diagnostic("cursor CLI not found; install with `curl https://cursor.com/install -fsS | bash`, ensure ~/.local/bin is on PATH, then run `agent login`.", .{});
    return error.FileNotFound;
}

fn ensureCursorApiKeyEnv(
    allocator: std.mem.Allocator,
    config: Config,
    env_map: *std.process.Environ.Map,
) !void {
    if (config.api_key) |api_key| {
        if (api_key.len > 0) try env_map.put("CURSOR_API_KEY", api_key);
        return;
    }
    if (env_map.get("CURSOR_API_KEY")) |api_key| {
        if (api_key.len > 0) return;
    }

    const api_key = loadCursorApiKeyFromUserEnvFilesAlloc(allocator) catch return;
    defer allocator.free(api_key);
    if (api_key.len > 0) try env_map.put("CURSOR_API_KEY", api_key);
}

fn loadCursorApiKeyFromUserEnvFilesAlloc(allocator: std.mem.Allocator) ![]u8 {
    const home_z = std.c.getenv("HOME") orelse return error.FileNotFound;
    const home = std.mem.sliceTo(home_z, 0);
    const candidates = [_][]const u8{
        ".config/verde/env",
        ".zshenv",
        ".zprofile",
        ".bash_profile",
        ".bashrc",
        ".profile",
    };

    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ home, candidate });
        defer allocator.free(path);
        const api_key = loadCursorApiKeyFromFileAlloc(allocator, path) catch continue;
        if (api_key.len > 0) return api_key;
        allocator.free(api_key);
    }

    return error.FileNotFound;
}

fn loadCursorApiKeyFromFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (parseCursorApiKeyLine(line)) |value| {
            return allocator.dupe(u8, value);
        }
    }
    return error.FileNotFound;
}

fn parseCursorApiKeyLine(line: []const u8) ?[]const u8 {
    const export_prefix = "export ";
    var rest = line;
    if (std.mem.startsWith(u8, rest, export_prefix)) rest = std.mem.trim(u8, rest[export_prefix.len..], " \t");
    if (!std.mem.startsWith(u8, rest, "CURSOR_API_KEY")) return null;
    rest = rest["CURSOR_API_KEY".len..];
    rest = std.mem.trim(u8, rest, " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    rest = std.mem.trim(u8, rest[1..], " \t");
    if (rest.len == 0) return null;

    if ((rest[0] == '"' or rest[0] == '\'') and rest.len >= 2) {
        const quote = rest[0];
        const end = std.mem.indexOfScalarPos(u8, rest, 1, quote) orelse return null;
        return rest[1..end];
    }

    const end = std.mem.indexOfAny(u8, rest, " \t#") orelse rest.len;
    return rest[0..end];
}

fn getOptionalObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getOptionalObjectInteger(value: std.json.Value, key: []const u8) ?i64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |number| number,
        else => null,
    };
}

fn getOptionalObjectBool(value: std.json.Value, key: []const u8) ?bool {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn isAuthError(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "auth") != null or
        std.mem.indexOf(u8, message, "login") != null or
        std.mem.indexOf(u8, message, "API key") != null or
        std.mem.indexOf(u8, message, "unauthorized") != null;
}

test "makeInitializeRequestAlloc writes ACP initialize JSON-RPC" {
    const json = try makeInitializeRequestAlloc(std.testing.allocator, 42);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), responseId(parsed.value).?);
    try std.testing.expectEqualStrings("initialize", getOptionalObjectString(parsed.value, "method").?);
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
    try handleReadSessionUpdate(std.testing.allocator, parsed_one.value, &state);
    try handleReadSessionUpdate(std.testing.allocator, parsed_two.value, &state);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("hello", state.messages.items[0].body);
}

test "cursorToolEvent suppresses status-only ACP tool updates" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"in_progress"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call_update");
    try std.testing.expect(event == null);
}

test "cursorToolEvent keeps meaningful ACP tool text" {
    const payload =
        \\{"sessionUpdate":"tool_call","title":"Shell","command":"git status --short","status":"pending"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call")).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Shell", event.title);
    try std.testing.expectEqualStrings("Shell: git status --short", event.body);
}

test "cursorToolEvent keeps non-lifecycle status failures" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolName":"edit","status":"failed"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call_update")).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("edit", event.title);
    try std.testing.expectEqualStrings("failed", event.body);
}

test "cursorToolEvent shows tool call starts with structured input" {
    const payload =
        \\{"sessionUpdate":"tool_call","toolName":"Read","input":{"path":"/tmp/a.txt"},"status":"pending"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call")).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Read", event.title);
    try std.testing.expectEqualStrings("Read: {\"path\":\"/tmp/a.txt\"}", event.body);
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
    const action = try handleSendPromptLine(std.testing.allocator, line, request, &state, null);
    try std.testing.expectEqual(SendLineAction.session_ready, action);
    try std.testing.expectEqualStrings("existing-session", state.session_id.?);
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

test "resolveCursorExecutableAlloc falls back to cursor-agent after configured command" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/definitely/missing");
    try std.testing.expectError(error.FileNotFound, resolveCursorExecutableAlloc(std.testing.allocator, &env_map, "missing-agent"));
}

test "cursorModelArgAlloc folds legacy SDK params into CLI model id" {
    const params =
        \\[{"id":"reasoning","value":"high"},{"id":"fast","value":"true"}]
    ;
    const arg = try cursorModelArgAlloc(std.testing.allocator, "gpt-5.5", params);
    defer std.testing.allocator.free(arg.?);
    try std.testing.expectEqualStrings("gpt-5.5-high-fast", arg.?);
}

test "parseModelsTextAlloc reads Cursor CLI model output" {
    const output =
        \\Available models
        \\
        \\composer-2-fast - Composer 2 Fast
        \\composer-2 - Composer 2 (current)
        \\gpt-5.3-codex - Codex 5.3
        \\composer-2.5 - Composer 2.5
        \\composer-2.5-fast - Composer 2.5 Fast (default)
        \\
    ;
    const models = try parseModelsTextAlloc(std.testing.allocator, output);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("composer-2.5", models[0].model_id);
    try std.testing.expect(models[0].cursor_fast_supported);
    try std.testing.expectEqualStrings("composer-2", models[1].model_id);
    try std.testing.expect(models[1].cursor_fast_supported);
    try std.testing.expectEqualStrings("gpt-5.3-codex", models[2].model_id);
}

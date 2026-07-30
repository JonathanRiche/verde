//! Cursor provider harness backed by Cursor CLI ACP (`agent acp`).

const std = @import("std");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const provider_mcp = @import("mcp.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const DEFAULT_EXECUTABLE = "agent";
const FALLBACK_EXECUTABLE = "cursor-agent";
const DEFAULT_MODEL = "composer-2.5";
const MAX_ACP_LINE_BYTES = 16 * 1024 * 1024;
const MAX_CURSOR_OUTPUT_BYTES = 8 * 1024 * 1024;
const MCP_TOOL_NAME_FIELD = "_verdeMcpTool";

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
    child: ?*platform_process.OwnedChild = null,
    stdin: ?std.Io.File = null,
    session_id: ?[]const u8 = null,
};

var active_process_state: ActiveProcessState = .{};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

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
        var acp = try self.spawnAcp(allocator, null, false);
        defer acp.deinit();

        var state: ListThreadsState = .{};
        errdefer state.deinit(allocator);

        try acp.writeLine(try makeInitializeRequestAlloc(allocator, 1));
        try acp.writeLine(try makeSessionListRequestAlloc(allocator, 2, try self.cwdAbsoluteAlloc(allocator)));
        try acp.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = acp.process.child.stdout.?.reader(acp.threaded.io(), &read_buffer);
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

        const executable = try self.resolveExecutable(allocator, &env_map);
        defer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const result = try std.process.run(allocator, threaded.io(), .{
            .argv = &.{ executable, "models" },
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
            .stdout_limit = .limited(MAX_CURSOR_OUTPUT_BYTES),
            .stderr_limit = .limited(512 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) return error.CursorModelDiscoveryFailed,
            else => return error.CursorModelDiscoveryFailed,
        }
        return parseModelsTextAlloc(allocator, result.stdout);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var acp = try self.spawnAcp(allocator, null, false);
        defer acp.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);
        const mcp_executable = if (provider_mcp.isInstalled(allocator, .cursor))
            try platform_runtime.executablePathAlloc(allocator)
        else
            null;
        defer if (mcp_executable) |executable| allocator.free(executable);

        var state: ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try acp.writeLine(try makeInitializeRequestAlloc(allocator, 1));
        try acp.writeLine(try makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd, mcp_executable));
        try acp.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = acp.process.child.stdout.?.reader(acp.threaded.io(), &read_buffer);
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

        // Cursor can issue multiple permission requests concurrently. In Full
        // Access, launch its native Run Everything mode so those tools do not
        // deadlock behind ACP's single pending approval exchange.
        var acp = try self.spawnAcp(allocator, model_arg, shouldAutoApprovePermission(request));
        defer acp.deinit();

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);
        const mcp_executable = if (provider_mcp.isInstalled(allocator, .cursor))
            try platform_runtime.executablePathAlloc(allocator)
        else
            null;
        defer if (mcp_executable) |executable| allocator.free(executable);

        var state: SendPromptState = .{};
        errdefer state.deinit(allocator);

        try acp.writeLine(try makeInitializeRequestAlloc(allocator, 1));
        if (request.thread_id) |thread_id| {
            try acp.writeLine(try makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd, mcp_executable));
        } else {
            try acp.writeLine(try makeSessionNewRequestAlloc(allocator, 2, cwd, mcp_executable));
        }

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = acp.process.child.stdout.?.reader(acp.threaded.io(), &read_buffer);
        while (try takeAcpLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const action = try handleSendPromptLine(allocator, line, request, &state, acp.process.child.stdin);
            switch (action) {
                .continue_reading => {},
                .session_ready => {
                    if (state.session_id) |session_id| {
                        registerActiveChild(&acp.process, acp.process.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        try acp.writeLine(try makePromptRequestAlloc(allocator, 3, session_id, request, state.capabilities.image));
                        state.prompt_submitted = true;
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

        unregisterActiveChild(&acp.process);
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
                child.terminateTree();
            };
        } else {
            child.terminateTree();
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

    fn spawnAcp(self: *Client, allocator: std.mem.Allocator, model_arg: ?[]const u8, force_commands: bool) !AcpProcess {
        var env_map = try self.cursorEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try self.resolveExecutable(allocator, &env_map);
        errdefer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const argv_with_model_and_force = [_][]const u8{ executable, "--force", "--model", model_arg orelse "", "acp" };
        const argv_with_model = [_][]const u8{ executable, "--model", model_arg orelse "", "acp" };
        const argv_with_force = [_][]const u8{ executable, "--force", "acp" };
        const argv_default = [_][]const u8{ executable, "acp" };
        var child = try platform_process.spawn(allocator, threaded.io(), .{
            .argv = if (model_arg != null)
                if (force_commands) argv_with_model_and_force[0..] else argv_with_model[0..]
            else if (force_commands)
                argv_with_force[0..]
            else
                argv_default[0..],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());

        return .{
            .allocator = allocator,
            .threaded = threaded,
            .process = child,
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

pub fn shutdownOwnedServer() void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    if (active_process_state.child) |child| child.terminateTree();
}

const AcpProcess = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    process: platform_process.OwnedChild,
    env_map: std.process.Environ.Map,
    executable: []u8,
    finished: bool = false,

    fn writeLine(self: *AcpProcess, line: []u8) !void {
        defer self.allocator.free(line);
        const stdin = self.process.child.stdin orelse return error.ConnectionClosed;
        try writeJsonLineToFile(self.allocator, stdin, line);
    }

    fn closeStdin(self: *AcpProcess) !void {
        if (self.process.child.stdin) |stdin| {
            stdin.close(self.threaded.io());
            self.process.child.stdin = null;
        }
    }

    fn stop(self: *AcpProcess) void {
        if (self.finished or self.process.child.id == null) return;
        self.process.kill(self.threaded.io());
        self.finished = true;
        self.process.child.stdin = null;
        self.process.child.stdout = null;
    }

    fn deinit(self: *AcpProcess) void {
        unregisterActiveChild(&self.process);
        if (!self.finished and self.process.child.id != null) {
            self.process.kill(self.threaded.io());
        }
        if (self.process.child.stdin) |stdin| stdin.close(self.threaded.io());
        self.env_map.deinit();
        self.allocator.free(self.executable);
        self.threaded.deinit();
    }
};

fn registerActiveChild(child: *platform_process.OwnedChild, stdin: ?std.Io.File, session_id: []const u8) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    active_process_state.child = child;
    active_process_state.stdin = stdin;
    active_process_state.session_id = session_id;
}

fn unregisterActiveChild(child: *platform_process.OwnedChild) void {
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
    prompt_submitted: bool = false,
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

    // ACP server requests have their own JSON-RPC id sequence. Handle them
    // before matching response ids so a permission request cannot collide
    // with one of Verde's initialize/session/prompt request ids.
    if (isMethod(parsed.value, "session/request_permission")) {
        try handlePermissionRequest(allocator, parsed.value, request, stdin);
        return .continue_reading;
    }

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

    if (isMethod(parsed.value, "session/update")) {
        // Cursor replays session history while loading an existing session.
        // Only updates emitted after this turn's prompt was submitted are live.
        if (!state.prompt_submitted) return .continue_reading;
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

fn makeSessionNewRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd: []const u8, mcp_executable: ?[]const u8) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/new", null, cwd, mcp_executable);
}

fn makeSessionLoadRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, cwd: []const u8, mcp_executable: ?[]const u8) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/load", session_id, cwd, mcp_executable);
}

fn makeSessionSetupRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    session_id: ?[]const u8,
    cwd: []const u8,
    mcp_executable: ?[]const u8,
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
    if (mcp_executable) |executable| {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write("verde");
        try stringify.objectField("command");
        try stringify.write(executable);
        try stringify.objectField("args");
        try stringify.beginArray();
        try stringify.write("mcp");
        try stringify.endArray();
        try stringify.objectField("env");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write("VERDE_MCP_MANAGED");
        try stringify.objectField("value");
        try stringify.write("1");
        try stringify.endObject();
        try stringify.endArray();
        try stringify.endObject();
    }
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
    provider_diagnostics.logError(
        .cursor_acp,
        getOptionalObjectInteger(error_value, "code"),
        message,
    );
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
            emitCursorDiffUpdate(update, request.stream_context, on_stream_event);
        }
    }
}

fn emitCursorDiffUpdate(
    update: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) void {
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

const TestDiffCapture = struct {
    count: usize = 0,
    path: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    additions: i64 = 0,
    deletions: i64 = 0,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *TestDiffCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .diff => |diff| {
                if (diff.files.len == 0) return;
                self.count += 1;
                self.path = diff.files[0].path;
                self.patch = diff.files[0].patch;
                self.additions = diff.files[0].additions;
                self.deletions = diff.files[0].deletions;
            },
            else => {},
        }
    }
};

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

fn shouldAutoApprovePermission(request: provider_types.SendPromptRequest) bool {
    return (request.approval_policy orelse .on_request) == .never;
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
    call_id: []u8,
    title: []u8,
    tool_kind: ?provider_types.ToolCallKind,
    status: ?provider_types.ToolCallStatus,
    input: ?[]u8,
    output: ?[]u8,
    error_text: ?[]u8,
    locations: ?[]u8,
    raw: []u8,

    fn deinit(self: CursorToolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.title);
        if (self.input) |value| allocator.free(value);
        if (self.output) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        if (self.locations) |value| allocator.free(value);
        allocator.free(self.raw);
    }
};

fn cursorToolEventAlloc(allocator: std.mem.Allocator, update: std.json.Value, kind: []const u8) !?CursorToolEvent {
    _ = kind;
    const title = try cursorToolTitleAlloc(allocator, update);
    errdefer allocator.free(title);
    const call_id_text = cursorToolCallId(update) orelse "";
    const status = cursorToolStatus(update);
    const input = try cursorToolInputAlloc(allocator, update);
    errdefer if (input) |value| allocator.free(value);
    const output = try cursorToolOutputAlloc(allocator, update);
    errdefer if (output) |value| allocator.free(value);
    const error_text = try cursorToolErrorAlloc(allocator, update, status);
    errdefer if (error_text) |value| allocator.free(value);
    const locations = try cursorToolLocationsAlloc(allocator, update);
    errdefer if (locations) |value| allocator.free(value);
    const raw = try jsonValueCompactAlloc(allocator, update);
    errdefer allocator.free(raw);

    const has_meaningful_content = input != null or output != null or error_text != null or locations != null;
    if (call_id_text.len == 0 and !has_meaningful_content and title.len == 0) {
        allocator.free(title);
        return null;
    }

    return .{
        .call_id = try allocator.dupe(u8, call_id_text),
        .title = title,
        .tool_kind = cursorToolKind(update),
        .status = status,
        .input = input,
        .output = output,
        .error_text = error_text,
        .locations = locations,
        .raw = raw,
    };
}

fn cursorToolCallId(update: std.json.Value) ?[]const u8 {
    if (getTrimmedObjectString(update, "toolCallId")) |call_id| return call_id;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, "toolCallId")) |call_id| return call_id;
        if (getTrimmedObjectString(tool_call, "id")) |call_id| return call_id;
    }
    return null;
}

fn cursorToolKind(update: std.json.Value) ?provider_types.ToolCallKind {
    if (cursorMcpToolName(update) != null) return .mcp;
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

    const title = cursorToolTitle(update) orelse "";
    if (std.ascii.startsWithIgnoreCase(title, "mcp") or std.ascii.startsWithIgnoreCase(title, "verde:")) return .mcp;
    if (getTrimmedObjectString(update, "command") != null or title.len > 0 and title[0] == '`') return .execute;
    if (std.ascii.startsWithIgnoreCase(title, "read")) return .read;
    if (std.ascii.startsWithIgnoreCase(title, "edit") or std.ascii.startsWithIgnoreCase(title, "write")) return .edit;
    if (std.ascii.startsWithIgnoreCase(title, "grep") or std.ascii.startsWithIgnoreCase(title, "find") or std.ascii.startsWithIgnoreCase(title, "search")) return .search;
    return null;
}

fn cursorToolStatus(update: std.json.Value) ?provider_types.ToolCallStatus {
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

fn cursorToolTitle(update: std.json.Value) ?[]const u8 {
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

fn cursorToolTitleAlloc(allocator: std.mem.Allocator, update: std.json.Value) ![]u8 {
    if (cursorMcpToolName(update)) |tool_name| {
        return std.fmt.allocPrint(allocator, "MCP: {s}", .{tool_name});
    }
    if (cursorToolTitle(update)) |title| return allocator.dupe(u8, title);
    return allocator.dupe(u8, "");
}

fn cursorMcpToolName(update: std.json.Value) ?[]const u8 {
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

fn cursorToolInputAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "rawInput", "input", "args", "arguments", "params", "command" };
    if (try cursorToolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return cursorToolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn cursorToolOutputAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "rawOutput", "output", "result", "content" };
    if (try cursorToolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return cursorToolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn cursorToolErrorAlloc(
    allocator: std.mem.Allocator,
    update: std.json.Value,
    status: ?provider_types.ToolCallStatus,
) !?[]u8 {
    const field_names = [_][]const u8{ "error", "errorMessage" };
    if (try cursorToolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (try cursorToolFieldsAlloc(allocator, tool_call, &field_names)) |value| return value;
    }
    if ((status orelse .unknown) != .failed) return null;
    if (getTrimmedObjectString(update, "body")) |body| return try allocator.dupe(u8, body);
    if (getTrimmedObjectString(update, "description")) |description| return try allocator.dupe(u8, description);
    return null;
}

fn cursorToolLocationsAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{"locations"};
    if (try cursorToolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return cursorToolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn cursorToolFieldsAlloc(
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
    if (raw_models.items.len == 0) return error.CursorModelsUnavailable;

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
        const base_id = stripFastSuffix(raw.id) orelse raw.id;
        if (reasoningGroupBaseId(raw_models.items, base_id)) |reasoning_base_id| {
            try appendCursorReasoningModel(allocator, raw_models.items, consumed, &models, reasoning_base_id);
            continue;
        }
        _ = try appendCursorModelByBaseId(allocator, raw_models.items, consumed, &models, base_id);
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

const CURSOR_REASONING_VALUES = [_][]const u8{ "none", "low", "medium", "high", "xhigh", "extra-high", "max" };

const CursorReasoningSuffix = struct {
    base_id: []const u8,
    value: []const u8,
};

fn stripReasoningSuffix(id: []const u8) ?CursorReasoningSuffix {
    if (std.mem.endsWith(u8, id, "-extra-high")) {
        return .{ .base_id = id[0 .. id.len - "-extra-high".len], .value = "extra-high" };
    }
    for (CURSOR_REASONING_VALUES) |value| {
        if (std.mem.eql(u8, value, "extra-high")) continue;
        if (id.len <= value.len + 1) continue;
        const suffix_start = id.len - value.len;
        if (id[suffix_start - 1] != '-' or !std.mem.eql(u8, id[suffix_start..], value)) continue;
        return .{ .base_id = id[0 .. suffix_start - 1], .value = value };
    }
    return null;
}

fn reasoningGroupBaseId(raw_models: []const RawCursorModel, id: []const u8) ?[]const u8 {
    const candidate = if (stripReasoningSuffix(id)) |suffix| suffix.base_id else id;
    var seen_variants: [CURSOR_REASONING_VALUES.len]bool = @splat(false);
    var has_base = false;
    for (raw_models) |raw| {
        const normalized = stripFastSuffix(raw.id) orelse raw.id;
        if (std.mem.eql(u8, normalized, candidate)) {
            has_base = true;
            continue;
        }
        const suffix = stripReasoningSuffix(normalized) orelse continue;
        if (!std.mem.eql(u8, suffix.base_id, candidate)) continue;
        for (CURSOR_REASONING_VALUES, 0..) |value, index| {
            if (std.mem.eql(u8, suffix.value, value)) seen_variants[index] = true;
        }
    }
    var variant_count: usize = if (has_base) 1 else 0;
    for (seen_variants) |seen| {
        if (seen) variant_count += 1;
    }
    return if (variant_count >= 2) candidate else null;
}

fn appendCursorReasoningModel(
    allocator: std.mem.Allocator,
    raw_models: []const RawCursorModel,
    consumed: []bool,
    models: *std.ArrayList(provider_types.ModelInfo),
    base_id: []const u8,
) !void {
    var values: [CURSOR_REASONING_VALUES.len][]const u8 = undefined;
    var values_len: usize = 0;
    const default_index: ?usize = rawModelIndex(raw_models, base_id);
    var first_variant_index: ?usize = null;
    var clean_name_index: ?usize = null;
    var medium_index: ?usize = null;
    var high_index: ?usize = null;
    var fast_supported = false;

    for (CURSOR_REASONING_VALUES) |value| {
        const variant_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ base_id, value });
        defer allocator.free(variant_id);
        if (rawModelIndex(raw_models, variant_id)) |index| {
            if (first_variant_index == null) first_variant_index = index;
            values[values_len] = value;
            values_len += 1;
            if (clean_name_index == null and !modelNameEndsWithReasoningValue(raw_models[index].name, value)) clean_name_index = index;
            if (std.mem.eql(u8, value, "medium")) medium_index = index;
            if (std.mem.eql(u8, value, "high")) high_index = index;
        } else if (std.mem.eql(u8, value, "medium") and default_index != null) {
            values[values_len] = value;
            values_len += 1;
        }
    }

    for (raw_models) |raw| {
        if (stripFastSuffix(raw.id)) |normalized| {
            if (std.mem.eql(u8, normalized, base_id)) fast_supported = true;
            if (stripReasoningSuffix(normalized)) |suffix| {
                if (std.mem.eql(u8, suffix.base_id, base_id)) fast_supported = true;
            }
        }
    }

    const selected_index = default_index orelse clean_name_index orelse medium_index orelse high_index orelse first_variant_index orelse unreachable;
    const selected = raw_models[selected_index];
    try appendReasoningModel(
        allocator,
        models,
        selected.id,
        selected.name,
        fast_supported,
        values[0..values_len],
    );

    for (raw_models, 0..) |raw, index| {
        const normalized = stripFastSuffix(raw.id) orelse raw.id;
        if (std.mem.eql(u8, normalized, base_id)) {
            consumed[index] = true;
            continue;
        }
        const suffix = stripReasoningSuffix(normalized) orelse continue;
        if (std.mem.eql(u8, suffix.base_id, base_id)) consumed[index] = true;
    }
}

fn modelNameEndsWithReasoningValue(name: []const u8, value: []const u8) bool {
    const label = if (std.mem.eql(u8, value, "xhigh") or std.mem.eql(u8, value, "extra-high"))
        "Extra High"
    else if (std.mem.eql(u8, value, "none"))
        "None"
    else if (std.mem.eql(u8, value, "low"))
        "Low"
    else if (std.mem.eql(u8, value, "medium"))
        "Medium"
    else if (std.mem.eql(u8, value, "high"))
        "High"
    else if (std.mem.eql(u8, value, "max"))
        "Max"
    else
        return false;
    var stem = name;
    if (std.mem.endsWith(u8, stem, " (NO ZDR)")) stem = stem[0 .. stem.len - " (NO ZDR)".len];
    if (std.mem.endsWith(u8, stem, " Thinking")) stem = stem[0 .. stem.len - " Thinking".len];
    return std.mem.endsWith(u8, stem, label);
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

fn appendReasoningModel(
    allocator: std.mem.Allocator,
    models: *std.ArrayList(provider_types.ModelInfo),
    id: []const u8,
    name: []const u8,
    fast_supported: bool,
    reasoning_values: []const []const u8,
) !void {
    const provider_id = try allocator.dupe(u8, "cursor");
    errdefer allocator.free(provider_id);
    const provider_name = try allocator.dupe(u8, "Cursor");
    errdefer allocator.free(provider_name);
    const model_id = try allocator.dupe(u8, id);
    errdefer allocator.free(model_id);
    const model_name = try allocator.dupe(u8, name);
    errdefer allocator.free(model_name);
    const param_id = try allocator.dupe(u8, "effort");
    errdefer allocator.free(param_id);
    const values = try allocator.alloc([:0]const u8, reasoning_values.len);
    var initialized_len: usize = 0;
    errdefer {
        for (values[0..initialized_len]) |value| allocator.free(value);
        allocator.free(values);
    }
    for (reasoning_values, 0..) |value, index| {
        values[index] = try allocator.dupeZ(u8, value);
        initialized_len += 1;
    }

    try models.append(allocator, .{
        .provider_id = provider_id,
        .provider_name = provider_name,
        .model_id = model_id,
        .model_name = model_name,
        .cursor_fast_supported = fast_supported,
        .cursor_reasoning_param_id = param_id,
        .cursor_reasoning_values = values,
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
    const model_reasoning = stripReasoningSuffix(model);
    try out.appendSlice(allocator, if (reasoning != null and model_reasoning != null) model_reasoning.?.base_id else model);
    if (reasoning) |value| {
        const keep_unsuffixed_medium = model_reasoning == null and std.mem.eql(u8, value, "medium");
        if (!keep_unsuffixed_medium) {
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
    runtime_log.diagnostic("cursor CLI not found; install Cursor Agent for this platform, ensure `agent` or `cursor-agent` is on PATH, then run `agent login`.", .{});
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

test "Cursor tool updates emit structured diff snapshots" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCall":{"input":{"filePath":"src/main.zig"},"output":{"patch":"--- a/src/main.zig\n+++ b/src/main.zig\n@@ -1 +1,2 @@\n-old\n+new\n+again"}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestDiffCapture = .{};
    emitCursorDiffUpdate(parsed.value, &capture, TestDiffCapture.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("src/main.zig", capture.path.?);
    try std.testing.expectEqual(@as(i64, 2), capture.additions);
    try std.testing.expectEqual(@as(i64, 1), capture.deletions);
}

test "cursorToolEvent preserves status-only ACP lifecycle updates" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"in_progress"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call_update")).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("call-1", event.call_id);
    try std.testing.expectEqualStrings("", event.title);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, event.status.?);
    try std.testing.expect(event.tool_kind == null);
    try std.testing.expect(event.input == null);
    try std.testing.expect(event.output == null);
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
    try std.testing.expectEqual(provider_types.ToolCallKind.execute, event.tool_kind.?);
    try std.testing.expectEqualStrings("git status --short", event.input.?);
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
    try std.testing.expectEqual(provider_types.ToolCallStatus.failed, event.status.?);
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
    try std.testing.expectEqual(provider_types.ToolCallKind.read, event.tool_kind.?);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp/a.txt\"}", event.input.?);
}

test "cursorToolEvent ignores empty ACP input containers" {
    const payload =
        \\{"sessionUpdate":"tool_call","toolCallId":"call-2","title":"Read File","kind":"read","rawInput":{},"locations":[{"path":"/tmp/a.txt"}],"status":"pending"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call")).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event.input == null);
    try std.testing.expectEqualStrings("[{\"path\":\"/tmp/a.txt\"}]", event.locations.?);
    try std.testing.expectEqualStrings(payload, event.raw);
}

test "cursorToolEvent ignores empty ACP output arrays" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-3","title":"MCP: tool","kind":"other","content":[],"status":"completed"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call_update")).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(provider_types.ToolCallKind.mcp, event.tool_kind.?);
    try std.testing.expect(event.output == null);
    try std.testing.expectEqualStrings(payload, event.raw);
}

test "cursorToolEvent promotes tagged Verde MCP results into the title" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-4","status":"completed","rawOutput":{"success":true,"_verdeMcpTool":"navigate_browser"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const event = (try cursorToolEventAlloc(std.testing.allocator, parsed.value, "tool_call_update")).?;
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
    const action = try handleSendPromptLine(std.testing.allocator, line, request, &state, null);
    try std.testing.expectEqual(SendLineAction.session_ready, action);
    try std.testing.expectEqualStrings("existing-session", state.session_id.?);
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
        try handleSendPromptLine(std.testing.allocator, line, request, &state, null),
    );
    try std.testing.expectEqual(@as(usize, 0), state.reply.items.len);

    state.prompt_submitted = true;
    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, line, request, &state, null),
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
        try handleSendPromptLine(std.testing.allocator, line, request, &state, null),
    );
}

test "Cursor Full Access auto-approves permission requests" {
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

test "cursorModelArgAlloc replaces a flattened Cursor effort suffix" {
    const params =
        \\[{"id":"effort","value":"low"},{"id":"fast","value":"true"}]
    ;
    const arg = try cursorModelArgAlloc(std.testing.allocator, "cursor-grok-4.5-high", params);
    defer std.testing.allocator.free(arg.?);
    try std.testing.expectEqualStrings("cursor-grok-4.5-low-fast", arg.?);
}

test "cursorModelArgAlloc replaces Kimi max with the selected effort" {
    const params =
        \\[{"id":"effort","value":"high"}]
    ;
    const arg = try cursorModelArgAlloc(std.testing.allocator, "kimi-k3-max", params);
    defer std.testing.allocator.free(arg.?);
    try std.testing.expectEqualStrings("kimi-k3-high", arg.?);
}

test "parseModelsTextAlloc reads Cursor CLI model output" {
    const output =
        \\Available models
        \\
        \\composer-2-fast - Composer 2 Fast
        \\composer-2 - Composer 2 (current)
        \\gpt-5.3-codex-low - Codex 5.3 Low
        \\gpt-5.3-codex - Codex 5.3
        \\gpt-5.3-codex-fast - Codex 5.3 Fast
        \\gpt-5.3-codex-high - Codex 5.3 High
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
    try std.testing.expect(models[2].cursor_fast_supported);
    try std.testing.expectEqualStrings("effort", models[2].cursor_reasoning_param_id.?);
    try std.testing.expectEqual(@as(usize, 3), models[2].cursor_reasoning_values.?.len);
    try std.testing.expectEqualStrings("low", models[2].cursor_reasoning_values.?[0]);
    try std.testing.expectEqualStrings("medium", models[2].cursor_reasoning_values.?[1]);
    try std.testing.expectEqualStrings("high", models[2].cursor_reasoning_values.?[2]);
}

test "parseModelsTextAlloc groups Grok effort rows without an unsuffixed model" {
    const output =
        \\Available models
        \\cursor-grok-4.5-high - Cursor Grok 4.5
        \\cursor-grok-4.5-high-fast - Cursor Grok 4.5 Fast
        \\cursor-grok-4.5-low - Cursor Grok 4.5 Low
        \\cursor-grok-4.5-low-fast - Cursor Grok 4.5 Low Fast
        \\cursor-grok-4.5-medium - Cursor Grok 4.5 Medium
        \\cursor-grok-4.5-medium-fast - Cursor Grok 4.5 Medium Fast
    ;
    const models = try parseModelsTextAlloc(std.testing.allocator, output);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("cursor-grok-4.5-high", models[0].model_id);
    try std.testing.expectEqualStrings("Cursor Grok 4.5", models[0].model_name);
    try std.testing.expect(models[0].cursor_fast_supported);
    try std.testing.expectEqual(@as(usize, 3), models[0].cursor_reasoning_values.?.len);
    try std.testing.expectEqualStrings("low", models[0].cursor_reasoning_values.?[0]);
    try std.testing.expectEqualStrings("medium", models[0].cursor_reasoning_values.?[1]);
    try std.testing.expectEqualStrings("high", models[0].cursor_reasoning_values.?[2]);
}

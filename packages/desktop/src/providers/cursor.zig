//! Cursor provider harness backed by the official `@cursor/sdk` TypeScript runtime.
//!
//! Cursor's public SDK is TypeScript. Keep this provider as a thin Zig-owned
//! bridge so Verde uses Cursor's harness, rules, hooks, skills, MCP config, and
//! model routing as Cursor intends instead of reimplementing that agent loop.

const std = @import("std");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");
const runtime_log = @import("../runtime_log.zig");
const builtin = @import("builtin");

const MAX_BRIDGE_STDOUT_BYTES = 16 * 1024 * 1024;
const MAX_BRIDGE_STDERR_BYTES = 512 * 1024;
const DEFAULT_MODEL = "composer-2";
const IMPORT_MESSAGE_LIMIT = 1000;

pub const Config = struct {
    executable: []const u8 = "node",
    cwd: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = DEFAULT_MODEL,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        const response = self.runBridge(.auth, std.heap.page_allocator, .{}) catch |err| switch (err) {
            error.CursorSignedOut => return .signed_out,
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer response.deinit(std.heap.page_allocator);
        return .signed_in;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        const response = self.runBridge(.list_threads, allocator, .{}) catch {
            return allocator.alloc(provider_types.ChatThreadSummary, 0);
        };
        defer response.deinit(allocator);
        return parseThreadSummariesAlloc(allocator, response.items orelse "[]");
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        const response = self.runBridge(.list_models, allocator, .{}) catch {
            return staticModelsAlloc(allocator);
        };
        defer response.deinit(allocator);
        return parseModelsAlloc(allocator, response.items orelse "[]") catch staticModelsAlloc(allocator);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        const response = try self.runBridge(.read_thread, allocator, .{
            .thread_id = thread_id,
        });
        defer response.deinit(allocator);

        const title = response.title orelse thread_id;
        const messages = try parseMessagesAlloc(allocator, response.items orelse "[]");
        return .{
            .thread_id = try allocator.dupe(u8, thread_id),
            .title = try allocator.dupe(u8, title),
            .updated_at = response.updated_at,
            .messages = messages,
        };
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        if (hasPromptAttachments(request)) return error.CursorAttachmentsUnsupported;

        const bridge_response = try self.runBridge(.send_prompt, allocator, .{
            .request = request,
        });
        defer bridge_response.deinit(allocator);

        if (request.on_thread_id) |on_thread_id| {
            on_thread_id(request.stream_context, bridge_response.thread_id);
        }
        if (bridge_response.run_id) |run_id| {
            if (request.on_turn_id) |on_turn_id| {
                on_turn_id(request.stream_context, run_id);
            }
        }
        return .{
            .thread_id = try allocator.dupe(u8, bridge_response.thread_id),
            .reply_text = try allocator.dupe(u8, bridge_response.reply_text),
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        const response = try self.runBridge(.interrupt_thread, self.allocator, .{
            .thread_id = request.thread_id,
            .turn_id = request.turn_id,
        });
        response.deinit(self.allocator);
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn runBridge(
        self: *Client,
        command: BridgeCommand,
        allocator: std.mem.Allocator,
        input: BridgeInput,
    ) !BridgeResponse {
        const request_json = try makeBridgeRequestJsonAlloc(allocator, self.config, command, input);
        defer allocator.free(request_json);
        const bridge_cwd = try resolveBridgeCwdAlloc(allocator, self.config.cwd);
        defer if (bridge_cwd) |path| allocator.free(path);

        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        defer env_map.deinit();
        try env_map.put("VERDE_CURSOR_REQUEST", request_json);
        try addBundledNodeModulesEnv(allocator, &env_map);
        try ensureCursorApiKeyEnv(allocator, self.config, &env_map);

        const executable = try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, self.config.executable);
        defer allocator.free(executable);

        if (command == .send_prompt) {
            runtime_log.diagnostic("cursor.runBridge send_prompt bridge_cwd={s} request_json_len={d}", .{ bridge_cwd orelse "(inherit)", request_json.len });
            return self.runBridgeStreaming(allocator, input, executable, bridge_cwd, &env_map);
        }

        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();

        const result = try std.process.run(allocator, threaded.io(), .{
            .argv = &.{ executable, "--input-type=module", "--eval", BRIDGE_SCRIPT },
            // Keep Node module resolution anchored at Verde's launch cwd; the selected
            // project is still passed to Cursor through `local.cwd` in the JSON request.
            .cwd = if (bridge_cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
            .stdout_limit = .limited(MAX_BRIDGE_STDOUT_BYTES),
            .stderr_limit = .limited(MAX_BRIDGE_STDERR_BYTES),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        return parseBridgeEventsAlloc(allocator, result.stdout, result.term, if (input.request) |request| request else null);
    }

    fn runBridgeStreaming(
        self: *Client,
        allocator: std.mem.Allocator,
        input: BridgeInput,
        executable: []const u8,
        bridge_cwd: ?[]const u8,
        env_map: *const std.process.Environ.Map,
    ) !BridgeResponse {
        _ = self;
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        runtime_log.diagnostic("cursor.spawn streaming bridge cwd={s}", .{bridge_cwd orelse "(inherit)"});
        var child = try std.process.spawn(io, .{
            .argv = &.{ executable, "--input-type=module", "--eval", BRIDGE_SCRIPT },
            .cwd = if (bridge_cwd) |path| .{ .path = path } else .inherit,
            .environ_map = env_map,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer if (child.id != null) child.kill(io);

        var state: BridgeParseState = .{};
        errdefer state.deinit(allocator);

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &read_buffer);
        while (try reader.interface.takeDelimiter('\n')) |raw_line| {
            if (try processBridgeLine(allocator, raw_line, if (input.request) |request| request else null, &state)) {
                break;
            }
            if (input.request) |send_request| {
                if (send_request.on_should_stop) |should_stop| {
                    if (should_stop(send_request.stream_context)) {
                        runtime_log.diagnostic("cursor.streaming bridge stopping on shutdown request", .{});
                        _ = child.kill(io);
                        child.id = null;
                        return error.CodexTurnInterrupted;
                    }
                }
            }
        }

        _ = child.kill(io);
        child.id = null;
        const term: std.process.Child.Term = .{ .exited = 0 };
        runtime_log.diagnostic("cursor.streaming bridge finished reply_len={d}", .{state.reply.items.len});
        try finishBridgeResponse(term, state.saw_error);
        if (state.response.thread_id.len == 0 and state.reply.items.len == 0) {
            if (state.error_message) |message| {
                runtime_log.diagnostic("cursor.streaming bridge empty response after error: {s}", .{message});
            } else {
                runtime_log.diagnostic("cursor.streaming bridge empty response without final event", .{});
            }
        }
        state.response.reply_text = try state.reply.toOwnedSlice(allocator);
        state.reply = .empty;
        const response = state.response;
        state.response = .{};
        return response;
    }
};

pub fn shutdownOwnedServer() void {}

fn hasPromptAttachments(request: provider_types.SendPromptRequest) bool {
    return request.image != null or request.images.len > 0;
}

fn resolveBridgeCwdAlloc(allocator: std.mem.Allocator, configured_cwd: ?[]const u8) !?[]u8 {
    if (configured_cwd) |cwd| {
        if (hasCursorSdkNodeModule(cwd)) return try allocator.dupe(u8, cwd);
    }

    const candidates = [_][]const u8{ ".", "..", "../.." };
    for (candidates) |candidate| {
        if (hasCursorSdkNodeModule(candidate)) return try allocator.dupe(u8, candidate);
    }
    return null;
}

fn hasCursorSdkNodeModule(cwd: []const u8) bool {
    var threaded = std.Io.Threaded.init_single_threaded;
    const manifest = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}/node_modules/@cursor/sdk/package.json",
        .{cwd},
    ) catch return false;
    defer std.heap.page_allocator.free(manifest);
    std.Io.Dir.cwd().access(threaded.io(), manifest, .{}) catch return false;
    return true;
}

const BridgeResponse = struct {
    thread_id: []u8 = &.{},
    run_id: ?[]u8 = null,
    reply_text: []u8 = &.{},
    title: ?[]u8 = null,
    items: ?[]u8 = null,
    updated_at: ?i64 = null,

    fn deinit(self: BridgeResponse, allocator: std.mem.Allocator) void {
        if (self.thread_id.len > 0) allocator.free(self.thread_id);
        if (self.run_id) |run_id| allocator.free(run_id);
        if (self.reply_text.len > 0) allocator.free(self.reply_text);
        if (self.title) |title| allocator.free(title);
        if (self.items) |items| allocator.free(items);
    }
};

const BridgeParseState = struct {
    response: BridgeResponse = .{},
    reply: std.ArrayList(u8) = .empty,
    saw_error: bool = false,
    error_message: ?[]u8 = null,

    fn deinit(self: *BridgeParseState, allocator: std.mem.Allocator) void {
        self.response.deinit(allocator);
        self.reply.deinit(allocator);
        if (self.error_message) |message| allocator.free(message);
    }
};

const BridgeCommand = enum {
    auth,
    list_threads,
    list_models,
    read_thread,
    send_prompt,
    interrupt_thread,
};

const BridgeInput = struct {
    request: ?provider_types.SendPromptRequest = null,
    thread_id: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,
};

fn makeBridgeRequestJsonAlloc(
    allocator: std.mem.Allocator,
    config: Config,
    command: BridgeCommand,
    input: BridgeInput,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("command");
    try stringify.write(@tagName(command));
    try stringify.objectField("cwd");
    try stringify.write(if (input.request) |request| request.cwd orelse config.cwd else config.cwd);
    try stringify.objectField("model");
    try stringify.write(if (input.request) |request| request.model orelse config.model orelse DEFAULT_MODEL else config.model orelse DEFAULT_MODEL);
    try stringify.objectField("modelParams");
    if (input.request) |request| {
        if (request.cursor_model_params_json) |params_json| {
            var parsed_params = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
            defer parsed_params.deinit();
            try stringify.write(parsed_params.value);
        } else {
            try stringify.write(null);
        }
    } else {
        try stringify.write(null);
    }
    try stringify.objectField("threadId");
    try stringify.write(input.thread_id orelse if (input.request) |request| request.thread_id else null);
    try stringify.objectField("turnId");
    try stringify.write(input.turn_id);
    try stringify.objectField("title");
    try stringify.write(if (input.request) |request| request.thread_title else null);
    try stringify.objectField("prompt");
    try stringify.write(if (input.request) |request| request.prompt else null);
    try stringify.objectField("limit");
    try stringify.write(IMPORT_MESSAGE_LIMIT);
    try stringify.endObject();

    return writer.toOwnedSlice();
}

fn parseBridgeEventsAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
    term: std.process.Child.Term,
    request: ?provider_types.SendPromptRequest,
) !BridgeResponse {
    var state: BridgeParseState = .{};
    errdefer state.deinit(allocator);

    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |raw_line| {
        _ = try processBridgeLine(allocator, raw_line, request, &state);
    }

    try finishBridgeResponse(term, state.saw_error);

    state.response.reply_text = try state.reply.toOwnedSlice(allocator);
    state.reply = .empty;
    const response = state.response;
    state.response = .{};
    return response;
}

fn processBridgeLine(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
    request: ?provider_types.SendPromptRequest,
    state: *BridgeParseState,
) !bool {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const event_type = getOptionalObjectString(parsed.value, "type") orelse return false;
    if (std.mem.eql(u8, event_type, "error")) {
        state.saw_error = true;
        if (getOptionalObjectString(parsed.value, "message")) |message| {
            runtime_log.diagnostic("cursor.bridge error: {s}", .{message});
            if (state.error_message == null) state.error_message = try allocator.dupe(u8, message);
        }
        if (isAuthError(getOptionalObjectString(parsed.value, "message"))) return error.CursorSignedOut;
        return false;
    }
    if (std.mem.eql(u8, event_type, "thread")) {
        if (state.response.thread_id.len == 0) {
            const thread_id = getOptionalObjectString(parsed.value, "threadId") orelse getOptionalObjectString(parsed.value, "agentId") orelse return false;
            state.response.thread_id = try allocator.dupe(u8, thread_id);
        }
        if (state.response.title == null) {
            if (getOptionalObjectString(parsed.value, "title")) |title| state.response.title = try allocator.dupe(u8, title);
        }
        state.response.updated_at = getOptionalObjectInteger(parsed.value, "updatedAt") orelse state.response.updated_at;
        return false;
    }
    if (std.mem.eql(u8, event_type, "turn")) {
        if (state.response.run_id == null) {
            const run_id = getOptionalObjectString(parsed.value, "runId") orelse return false;
            state.response.run_id = try allocator.dupe(u8, run_id);
        }
        return false;
    }
    if (std.mem.eql(u8, event_type, "delta")) {
        const text = getOptionalObjectString(parsed.value, "text") orelse return false;
        try state.reply.appendSlice(allocator, text);
        if (request) |send_request| {
            if (send_request.on_stream_delta) |on_stream_delta| {
                on_stream_delta(send_request.stream_context, text);
            }
        }
        return false;
    }
    if (std.mem.eql(u8, event_type, "command")) {
        const body = getOptionalObjectString(parsed.value, "command") orelse getOptionalObjectString(parsed.value, "body") orelse return false;
        const failed = getOptionalObjectBool(parsed.value, "failed") orelse false;
        if (request) |send_request| {
            if (send_request.on_stream_event) |on_stream_event| {
                on_stream_event(send_request.stream_context, .{
                    .message = .{
                        .title = if (failed) "Command failed" else "Ran command",
                        .body = body,
                    },
                });
            }
        }
        return false;
    }
    if (std.mem.eql(u8, event_type, "debug")) {
        const name = getOptionalObjectString(parsed.value, "name") orelse "unknown";
        const value = getOptionalObjectInteger(parsed.value, "value") orelse 0;
        runtime_log.diagnostic("cursor.bridge debug {s}={d}", .{ name, value });
        return false;
    }
    if (std.mem.eql(u8, event_type, "items")) {
        const json = getObjectField(parsed.value, "items") orelse return false;
        state.response.items = try std.json.Stringify.valueAlloc(allocator, json, .{ .whitespace = .minified });
        return false;
    }
    if (std.mem.eql(u8, event_type, "final")) {
        if (getOptionalObjectString(parsed.value, "replyText")) |text| {
            if (text.len > 0) {
                state.reply.clearRetainingCapacity();
                try state.reply.appendSlice(allocator, text);
            }
        }
        if (state.response.thread_id.len == 0) {
            const thread_id = getOptionalObjectString(parsed.value, "threadId") orelse getOptionalObjectString(parsed.value, "agentId") orelse "";
            if (thread_id.len > 0) state.response.thread_id = try allocator.dupe(u8, thread_id);
        }
        if (state.response.run_id == null) {
            if (getOptionalObjectString(parsed.value, "runId")) |run_id| state.response.run_id = try allocator.dupe(u8, run_id);
        }
        return true;
    }
    return false;
}

fn finishBridgeResponse(term: std.process.Child.Term, saw_error: bool) !void {
    switch (term) {
        .exited => |code| if (code != 0) {
            if (saw_error) return error.CursorBridgeFailed;
            return error.CursorBridgeFailed;
        },
        else => return error.CursorBridgeFailed,
    }
}

fn addBundledNodeModulesEnv(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) !void {
    const bundled = bundledNodeModulesPathAlloc(allocator) catch return;
    defer allocator.free(bundled);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().access(threaded.io(), bundled, .{}) catch return;

    try env_map.put("VERDE_NODE_MODULES", bundled);
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
        const api_key = loadCursorApiKeyFromFileAlloc(allocator, path) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.IsDir => continue,
            else => continue,
        };
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

fn bundledNodeModulesPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.FileNotFound;

    return switch (builtin.os.tag) {
        .macos => std.fs.path.resolve(allocator, &.{ exe_dir, "..", "Resources", "node_modules" }),
        else => std.fs.path.resolve(allocator, &.{ exe_dir, "..", "share", "verde", "node_modules" }),
    };
}

fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .linux => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const len = std.c.readlink("/proc/self/exe", &buffer, buffer.len);
            if (len < 0) return error.FileNotFound;
            return allocator.dupe(u8, buffer[0..@intCast(len)]);
        },
        .macos => {
            var size: u32 = std.fs.max_path_bytes;
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (_NSGetExecutablePath(&buffer, &size) != 0) {
                const dynamic_buffer = try allocator.alloc(u8, size);
                errdefer allocator.free(dynamic_buffer);
                if (_NSGetExecutablePath(dynamic_buffer.ptr, &size) != 0) return error.NameTooLong;
                return std.fs.path.resolve(allocator, &.{std.mem.sliceTo(dynamic_buffer, 0)});
            }
            return std.fs.path.resolve(allocator, &.{std.mem.sliceTo(&buffer, 0)});
        },
        else => return error.FileNotFound,
    }
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

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

fn isAuthError(message: ?[]const u8) bool {
    const text = message orelse return false;
    return std.mem.indexOf(u8, text, "API key") != null or
        std.mem.indexOf(u8, text, "unauthorized") != null or
        std.mem.indexOf(u8, text, "Authentication") != null;
}

fn parseThreadSummariesAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]provider_types.ChatThreadSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(provider_types.ChatThreadSummary, 0);

    var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
    errdefer {
        for (threads.items) |thread| {
            allocator.free(thread.id);
            allocator.free(thread.title);
        }
        threads.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id = getOptionalObjectString(item, "agentId") orelse getOptionalObjectString(item, "id") orelse continue;
        const title = getOptionalObjectString(item, "name") orelse
            getOptionalObjectString(item, "summary") orelse
            id;
        try threads.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
        });
    }

    return threads.toOwnedSlice(allocator);
}

fn parseModelsAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]provider_types.ModelInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return staticModelsAlloc(allocator);

    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id = getOptionalObjectString(item, "id") orelse continue;
        const name = getOptionalObjectString(item, "displayName") orelse id;
        try appendCursorModelFromJson(allocator, &models, item, id, name);
    }

    if (models.items.len == 0) return staticModelsAlloc(allocator);
    return models.toOwnedSlice(allocator);
}

fn staticModelsAlloc(allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    try appendModel(allocator, &models, "default", "Auto");
    try appendModel(allocator, &models, "composer-2", "Composer 2");
    try appendModel(allocator, &models, "gpt-5.5", "GPT-5.5");
    try appendModel(allocator, &models, "gpt-5.4", "GPT-5.4");
    try appendModel(allocator, &models, "claude-opus-4-7", "Claude Opus 4.7");
    try appendModel(allocator, &models, "claude-sonnet-4-5", "Claude Sonnet 4.5");
    return models.toOwnedSlice(allocator);
}

fn appendModel(
    allocator: std.mem.Allocator,
    models: *std.ArrayList(provider_types.ModelInfo),
    id: []const u8,
    name: []const u8,
) !void {
    try models.append(allocator, .{
        .provider_id = try allocator.dupe(u8, "cursor"),
        .provider_name = try allocator.dupe(u8, "Cursor"),
        .model_id = try allocator.dupe(u8, id),
        .model_name = try allocator.dupe(u8, name),
    });
}

fn appendCursorModelFromJson(
    allocator: std.mem.Allocator,
    models: *std.ArrayList(provider_types.ModelInfo),
    item: std.json.Value,
    id: []const u8,
    name: []const u8,
) !void {
    var fast_supported = false;
    var reasoning_param_id: ?[]const u8 = null;
    var reasoning_values: ?[][:0]const u8 = null;
    var requires_thinking = false;

    if (item.object.get("parameters")) |params_value| {
        if (params_value == .array) {
            var effort_values: ?std.json.Value = null;
            var reasoning_param_values: ?std.json.Value = null;
            var has_thinking = false;
            for (params_value.array.items) |param| {
                if (param != .object) continue;
                const param_id = getOptionalObjectString(param, "id") orelse continue;
                if (std.mem.eql(u8, param_id, "fast")) {
                    fast_supported = true;
                } else if (std.mem.eql(u8, param_id, "thinking")) {
                    has_thinking = true;
                } else if (std.mem.eql(u8, param_id, "reasoning")) {
                    reasoning_param_values = param.object.get("values");
                    reasoning_param_id = "reasoning";
                } else if (std.mem.eql(u8, param_id, "effort")) {
                    effort_values = param.object.get("values");
                }
            }
            if (reasoning_param_values == null and effort_values != null) {
                reasoning_param_values = effort_values;
                reasoning_param_id = "effort";
                requires_thinking = has_thinking;
            }
            if (reasoning_param_values) |values| {
                reasoning_values = try cursorParamValuesAlloc(allocator, values);
            }
        }
    }

    errdefer if (reasoning_values) |values| {
        for (values) |value| allocator.free(value);
        allocator.free(values);
    };

    try models.append(allocator, .{
        .provider_id = try allocator.dupe(u8, "cursor"),
        .provider_name = try allocator.dupe(u8, "Cursor"),
        .model_id = try allocator.dupe(u8, id),
        .model_name = try allocator.dupe(u8, name),
        .cursor_fast_supported = fast_supported,
        .cursor_reasoning_param_id = if (reasoning_param_id) |param_id| try allocator.dupe(u8, param_id) else null,
        .cursor_reasoning_values = reasoning_values,
        .cursor_reasoning_requires_thinking = requires_thinking,
    });
}

fn cursorParamValuesAlloc(allocator: std.mem.Allocator, values: std.json.Value) !?[][:0]const u8 {
    if (values != .array) return null;
    var out: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (out.items) |value| allocator.free(value);
        out.deinit(allocator);
    }
    for (values.array.items) |value_obj| {
        if (value_obj != .object) continue;
        const value = getOptionalObjectString(value_obj, "value") orelse continue;
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "true")) continue;
        try out.append(allocator, try allocator.dupeZ(u8, value));
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn parseMessagesAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]provider_types.ChatMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(provider_types.ChatMessage, 0);

    var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
    errdefer {
        for (messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        messages.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const role_text = getOptionalObjectString(item, "role") orelse continue;
        const body = getOptionalObjectString(item, "text") orelse continue;
        const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const role: provider_types.MessageRole = if (std.mem.eql(u8, role_text, "user"))
            .user
        else if (std.mem.eql(u8, role_text, "assistant"))
            .assistant
        else
            .system;
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

    return messages.toOwnedSlice(allocator);
}

const BRIDGE_SCRIPT =
    \\import { createRequire } from "node:module";
    \\import { pathToFileURL } from "node:url";
    \\const fail = (message) => {
    \\  process.stdout.write(JSON.stringify({ type: "error", message }) + "\n");
    \\  process.exit(1);
    \\};
    \\const emit = (event) => process.stdout.write(JSON.stringify(event) + "\n");
    \\const requireFromBundledModules = () => {
    \\  const root = process.env.VERDE_NODE_MODULES;
    \\  if (!root) return createRequire(import.meta.url);
    \\  const normalized = root.replace(/\/+$/, "");
    \\  return createRequire(pathToFileURL(`${normalized}/package.json`));
    \\};
    \\const withTimeout = (promise, ms, label) => new Promise((resolve, reject) => {
    \\  const timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
    \\  promise.then((value) => {
    \\    clearTimeout(timer);
    \\    resolve(value);
    \\  }, (error) => {
    \\    clearTimeout(timer);
    \\    reject(error);
    \\  });
    \\});
    \\const modelSelection = (id, params) => id ? { id, ...(Array.isArray(params) && params.length ? { params } : {}) } : undefined;
    \\const agentOptions = () => ({
    \\  apiKey: process.env.CURSOR_API_KEY,
    \\  model: modelSelection(input.model || "composer-2", input.modelParams),
    \\  name: input.title || undefined,
    \\  local: { cwd: input.cwd || process.cwd() },
    \\});
    \\const textFromContent = (content) =>
    \\  Array.isArray(content)
    \\    ? content.filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("")
    \\    : "";
    \\const messageText = (message) => {
    \\  if (typeof message?.text === "string") return message.text;
    \\  if (typeof message?.content === "string") return message.content;
    \\  return textFromContent(message?.content);
    \\};
    \\const messageRole = (message) => {
    \\  if (message?.role === "user" || message?.role === "assistant") return message.role;
    \\  if (message?.type === "user" || message?.type === "assistant") return message.type;
    \\  return undefined;
    \\};
    \\const normalizeMessage = (item) => {
    \\  const message = item?.message ?? item;
    \\  const role = messageRole(message);
    \\  const text = messageText(message);
    \\  if (!role || !text) return null;
    \\  return { role, text };
    \\};
    \\const agentId = (agent) => agent?.agentId || agent?.id;
    \\const titleOf = (item) => item?.name || item?.summary || item?.agentId || item?.id || "";
    \\
    \\let input;
    \\try {
    \\  input = JSON.parse(process.env.VERDE_CURSOR_REQUEST || "{}");
    \\} catch (error) {
    \\  fail(`invalid request: ${error?.message || error}`);
    \\}
    \\
    \\try {
    \\  const require = requireFromBundledModules();
    \\  const sdkModule = await import(require.resolve("@cursor/sdk"));
    \\  const sdk = sdkModule.Agent ? sdkModule : (sdkModule.default || sdkModule);
    \\  const { Agent, Cursor } = sdk;
    \\  if (input.command === "auth") {
    \\    await Cursor.me({ apiKey: process.env.CURSOR_API_KEY });
    \\    emit({ type: "ok" });
    \\  } else if (input.command === "list_models") {
    \\    const models = await withTimeout(Cursor.models.list({ apiKey: process.env.CURSOR_API_KEY }), 5000, "Cursor model discovery");
    \\    emit({ type: "items", items: models });
    \\  } else if (input.command === "list_threads") {
    \\    const result = await Agent.list({ runtime: "local", cwd: input.cwd || process.cwd(), limit: input.limit || 100 });
    \\    emit({ type: "items", items: result.items });
    \\  } else if (input.command === "read_thread") {
    \\    if (!input.threadId) fail("threadId is required");
    \\    const info = await Agent.get(input.threadId, { cwd: input.cwd || process.cwd(), apiKey: process.env.CURSOR_API_KEY });
    \\    emit({ type: "thread", threadId: input.threadId, title: titleOf(info), updatedAt: info?.lastModified || null });
    \\    const messages = await Agent.messages.list(input.threadId, { runtime: "local", cwd: input.cwd || process.cwd(), limit: input.limit || 1000 });
    \\    emit({ type: "items", items: (Array.isArray(messages) ? messages : messages?.items || []).map(normalizeMessage).filter(Boolean) });
    \\  } else if (input.command === "interrupt_thread") {
    \\    if (!input.threadId || !input.turnId) fail("threadId and turnId are required");
    \\    const run = await Agent.getRun(input.turnId, { runtime: "local", cwd: input.cwd || process.cwd(), agentId: input.threadId, apiKey: process.env.CURSOR_API_KEY });
    \\    await run.cancel();
    \\    emit({ type: "ok" });
    \\  } else if (input.command === "send_prompt") {
    \\  const agent = input.threadId
    \\    ? await Agent.resume(input.threadId, agentOptions())
    \\    : await Agent.create(agentOptions());
    \\  emit({ type: "thread", threadId: agentId(agent), title: input.title || agentId(agent) });
    \\  const run = await agent.send(input.prompt || "", { model: modelSelection(input.model || "composer-2", input.modelParams) });
    \\  emit({ type: "turn", runId: run.id });
    \\  let deltaCount = 0;
    \\  for await (const event of run.stream()) {
    \\    if (event?.type === "assistant") {
    \\      const content = Array.isArray(event.message?.content) ? event.message.content : [];
    \\      const text = content
    \\        .filter((block) => block?.type === "text" && typeof block.text === "string")
    \\        .map((block) => block.text)
    \\        .join("");
    \\      if (!text) continue;
    \\      deltaCount += 1;
    \\      emit({ type: "delta", text });
    \\      continue;
    \\    }
    \\    if (event?.type === "text-delta") {
    \\      const text = typeof event.text === "string" ? event.text : "";
    \\      if (!text) continue;
    \\      deltaCount += 1;
    \\      emit({ type: "delta", text });
    \\      continue;
    \\    }
    \\    if (event?.type === "tool_call" && event.name) {
    \\      emit({ type: "command", command: `${event.name} ${JSON.stringify(event.args ?? {})}`, failed: event.status === "error" });
    \\    }
    \\  }
    \\  const result = await run.wait();
    \\  emit({ type: "debug", name: "deltaCount", value: deltaCount });
    \\  emit({ type: "final", threadId: agentId(agent) || run.agentId, runId: run.id, replyText: result?.result || "" });
    \\  } else {
    \\    fail(`unsupported command: ${input.command}`);
    \\  }
    \\} catch (error) {
    \\  fail(error?.stack || error?.message || String(error));
    \\}
;

test "parseBridgeEventsAlloc reads cursor ids and reply" {
    const payload =
        \\{"type":"thread","threadId":"agent_123"}
        \\{"type":"turn","runId":"run_456"}
        \\{"type":"delta","text":"do"}
        \\{"type":"delta","text":"ne"}
        \\
    ;
    const parsed = try parseBridgeEventsAlloc(std.testing.allocator, payload, .{ .exited = 0 }, null);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("agent_123", parsed.thread_id);
    try std.testing.expectEqualStrings("run_456", parsed.run_id.?);
    try std.testing.expectEqualStrings("done", parsed.reply_text);
}

test "makeBridgeRequestJsonAlloc keeps cursor model and cwd" {
    const json = try makeBridgeRequestJsonAlloc(std.testing.allocator, .{}, .send_prompt, .{
        .request = .{
            .prompt = "hello",
            .cwd = "/tmp/project",
            .model = "composer-2",
        },
    });
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", getOptionalObjectString(parsed.value, "prompt").?);
    try std.testing.expectEqualStrings("/tmp/project", getOptionalObjectString(parsed.value, "cwd").?);
    try std.testing.expectEqualStrings("composer-2", getOptionalObjectString(parsed.value, "model").?);
    try std.testing.expectEqualStrings("send_prompt", getOptionalObjectString(parsed.value, "command").?);
}

test "hasPromptAttachments rejects legacy and multi image requests" {
    try std.testing.expect(!hasPromptAttachments(.{ .prompt = "text only" }));
    try std.testing.expect(hasPromptAttachments(.{
        .prompt = "legacy",
        .image = .{ .path = "/tmp/one.png" },
    }));

    const images = [_]provider_types.ImageAttachment{
        .{ .path = "/tmp/one.png" },
        .{ .path = "/tmp/two.png" },
    };
    try std.testing.expect(hasPromptAttachments(.{
        .prompt = "multi",
        .images = images[0..],
    }));
}

test "parseBridgeEventsAlloc maps command events to stream events" {
    const Context = struct {
        title: []const u8 = "",
        body: []const u8 = "",

        fn onEvent(raw: ?*anyopaque, event: provider_types.StreamEvent) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw orelse return));
            switch (event) {
                .message => |message| {
                    ctx.title = message.title;
                    ctx.body = message.body;
                },
                .diff => {},
            }
        }
    };

    var ctx: Context = .{};
    const payload =
        \\{"type":"thread","threadId":"agent_123"}
        \\{"type":"command","command":"bash -lc zig build test","failed":true}
        \\
    ;
    const parsed = try parseBridgeEventsAlloc(std.testing.allocator, payload, .{ .exited = 0 }, .{
        .prompt = "hello",
        .stream_context = &ctx,
        .on_stream_event = Context.onEvent,
    });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Command failed", ctx.title);
    try std.testing.expectEqualStrings("bash -lc zig build test", ctx.body);
}

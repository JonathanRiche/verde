//! FX provider harness backed by the fx CLI ACP server (`fx acp`).
//! Generic ACP transport/protocol machinery lives in `acp.zig`; this module
//! owns fx binary discovery, argv construction, and fx's handshake-based
//! auth/model discovery (fx exposes its model catalog only through ACP
//! `configOptions`, not a CLI subcommand).

const std = @import("std");
const acp = @import("acp.zig");
const platform_process = @import("../platform/process.zig");
const provider_mcp = @import("mcp.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const DEFAULT_EXECUTABLE = "fx";
// The fx installer (`curl -fsSL https://fx.sh/setup.sh | bash`) places the
// binary here, which desktop launch environments often lack on PATH.
const INSTALL_FALLBACK_RELATIVE = ".local/bin/fx";

const ACP_HARNESS: acp.Harness = .{
    .diagnostics_category = .fx_acp,
    .assistant_author = "FX",
    .permission_default_title = "FX permission request",
    // fx prefixes its first chunk with skill-loader diagnostics that would
    // otherwise be committed as the start of the assistant reply.
    .diagnostic_chunk_prefix = "skill discovery warning:",
    .diagnostic_event_title = "FX warning",
};

var active_process_state: acp.ActiveProcessState = .{};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

pub const Config = struct {
    executable: []const u8 = DEFAULT_EXECUTABLE,
    cwd: ?[]const u8 = null,
    // fx persists its own model selection per session; null defers to it.
    model: ?[]const u8 = null,
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

    // fx has no status subcommand; ACP initialize is the auth probe. It fails
    // with a "Run fx login ..." JSON-RPC error when no usable Vercel AI
    // Gateway credential exists, which the shared layer maps to AcpSignedOut.
    pub fn authState(self: *Client) !provider_types.AuthState {
        var proc = self.spawnAcp(self.allocator, null) catch |err| switch (err) {
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer proc.deinit();

        proc.writeLine(acp.makeInitializeRequestAlloc(self.allocator, 1) catch return .unknown) catch return .unknown;
        proc.closeStdin() catch return .unknown;

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (true) {
            const raw_line = (acp.takeLineAlloc(self.allocator, &reader) catch return .unknown) orelse return .unknown;
            defer self.allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return .unknown;
            defer parsed.deinit();
            acp.failIfJsonRpcError(ACP_HARNESS, parsed.value) catch |err| switch (err) {
                error.AcpSignedOut => return .signed_out,
                else => return .unknown,
            };
            if (acp.responseId(parsed.value)) |id| {
                if (id == 1) {
                    proc.stop();
                    return .signed_in;
                }
            }
        }
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        return self.listThreadsAcp(allocator) catch |err| return mapAcpError(err);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        return self.listModelsAcp(allocator) catch |err| return mapAcpError(err);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        return self.readThreadAcp(allocator, thread_id) catch |err| return mapAcpError(err);
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        return self.sendPromptAcp(allocator, request) catch |err| return mapAcpError(err);
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        _ = self;
        active_process_state.lock();
        defer active_process_state.unlock();

        const child = active_process_state.child orelse return;
        const session_id = active_process_state.session_id orelse return;
        if (!std.mem.eql(u8, session_id, request.thread_id)) return;
        if (active_process_state.stdin) |stdin| {
            const line = try acp.makeCancelNotificationAlloc(std.heap.page_allocator, session_id);
            defer std.heap.page_allocator.free(line);
            acp.writeJsonLineToFile(std.heap.page_allocator, stdin, line) catch {
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

    fn listThreadsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var proc = try self.spawnAcp(allocator, null);
        defer proc.deinit();

        var state: acp.ListThreadsState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionListRequestAlloc(allocator, 2, try self.cwdAbsoluteAlloc(allocator)));
        try proc.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleListThreadsLine(allocator, ACP_HARNESS, line, &state)) break;
        }

        proc.stop();
        const threads = try state.threads.toOwnedSlice(allocator);
        state.threads = .empty;
        return threads;
    }

    // fx publishes its model catalog only in the `configOptions` of a
    // session/new or session/load response. Loading the newest existing
    // session avoids minting an empty throwaway session on every refresh;
    // session/new is the first-run fallback.
    fn listModelsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var proc = try self.spawnAcp(allocator, null);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionListRequestAlloc(allocator, 2, try allocator.dupe(u8, cwd)));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            try acp.failIfJsonRpcError(ACP_HARNESS, parsed.value);
            const id = acp.responseId(parsed.value) orelse continue;
            if (id == 2) {
                if (try newestSessionIdAlloc(allocator, parsed.value)) |session_id| {
                    defer allocator.free(session_id);
                    try proc.writeLine(try acp.makeSessionLoadRequestAlloc(allocator, 3, session_id, cwd, null));
                } else {
                    try proc.writeLine(try acp.makeSessionNewRequestAlloc(allocator, 3, cwd, null));
                }
                try proc.closeStdin();
                continue;
            }
            if (id == 3) {
                const models = try parseModelConfigOptionsAlloc(allocator, parsed.value);
                proc.stop();
                return models;
            }
        }
        return error.AcpFailed;
    }

    fn readThreadAcp(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var proc = try self.spawnAcp(allocator, null);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);
        var mcp_connection = if (provider_mcp.isInstalled(allocator, .fx))
            try provider_mcp.loadHttpConnection(allocator)
        else
            null;
        defer if (mcp_connection) |*connection| connection.deinit(allocator);
        const mcp_http: ?acp.McpHttpServer = if (mcp_connection) |connection| .{
            .url = connection.url,
            .authorization = connection.authorization,
            .client_name = "fx",
        } else null;

        var state: acp.ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionLoadRequestWithHttpMcpAlloc(allocator, 2, thread_id, cwd, mcp_http));
        try proc.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleReadThreadLine(allocator, ACP_HARNESS, line, thread_id, &state)) break;
        }

        proc.stop();
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

    fn sendPromptAcp(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        // `fx acp --model <id>` overrides the session's stored model for this
        // process; fx has no fast/effort suffix algebra. "default" is Verde's
        // sentinel for deferring to fx's own persisted model selection.
        const requested_model = request.model orelse self.config.model;
        const model_arg = if (requested_model) |model|
            (if (std.mem.eql(u8, model, "default")) null else model)
        else
            null;

        var proc = try self.spawnAcp(allocator, model_arg);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);
        var mcp_connection = if (provider_mcp.isInstalled(allocator, .fx))
            try provider_mcp.loadHttpConnection(allocator)
        else
            null;
        defer if (mcp_connection) |*connection| connection.deinit(allocator);
        const mcp_http: ?acp.McpHttpServer = if (mcp_connection) |connection| .{
            .url = connection.url,
            .authorization = connection.authorization,
            .client_name = "fx",
        } else null;

        var state: acp.SendPromptState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        if (request.thread_id) |thread_id| {
            try proc.writeLine(try acp.makeSessionLoadRequestWithHttpMcpAlloc(allocator, 2, thread_id, cwd, mcp_http));
        } else {
            try proc.writeLine(try acp.makeSessionNewRequestWithHttpMcpAlloc(allocator, 2, cwd, mcp_http));
        }

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const action = try acp.handleSendPromptLine(allocator, ACP_HARNESS, line, request, &state, proc.process.child.stdin);
            switch (action) {
                .continue_reading => {},
                .session_ready => {
                    if (state.session_id) |session_id| {
                        active_process_state.register(&proc.process, proc.process.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        try proc.writeLine(try acp.makePromptRequestAlloc(allocator, 3, session_id, request, state.capabilities.image));
                        state.prompt_submitted = true;
                    }
                },
                .prompt_done => break,
            }
            if (request.on_should_stop) |should_stop| {
                if (should_stop(request.stream_context)) {
                    if (state.session_id) |session_id| {
                        try proc.writeLine(try acp.makeCancelNotificationAlloc(allocator, session_id));
                    }
                    return error.CodexTurnInterrupted;
                }
            }
        }

        active_process_state.unregister(&proc.process);
        try proc.closeStdin();
        proc.stop();

        const thread_id = state.session_id orelse return error.AcpFailed;
        state.session_id = null;
        const reply_text = try state.reply.toOwnedSlice(allocator);
        state.reply = .empty;
        return .{
            .thread_id = thread_id,
            .reply_text = reply_text,
        };
    }

    fn spawnAcp(self: *Client, allocator: std.mem.Allocator, model_arg: ?[]const u8) !acp.Process {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try resolveFxExecutableAlloc(allocator, &env_map, self.config.executable);
        errdefer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const argv_with_model = [_][]const u8{ executable, "acp", "--model", model_arg orelse "" };
        const argv_default = [_][]const u8{ executable, "acp" };
        var child = try platform_process.spawn(allocator, threaded.io(), .{
            .argv = if (model_arg != null) argv_with_model[0..] else argv_default[0..],
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
            .active_state = &active_process_state,
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
    active_process_state.lock();
    defer active_process_state.unlock();
    if (active_process_state.child) |child| child.terminateTree();
}

/// Maps provider-neutral ACP errors to FX error names so user-facing error
/// messaging can address fx specifically (e.g. suggest `fx login`).
fn mapAcpError(err: anyerror) anyerror {
    return switch (err) {
        error.AcpFailed => error.FxAcpFailed,
        error.AcpRefused => error.FxAcpRefused,
        error.AcpSignedOut => error.FxSignedOut,
        error.AcpMessageTooLarge => error.FxAcpMessageTooLarge,
        error.AcpAttachmentsUnsupported => error.FxAttachmentsUnsupported,
        else => err,
    };
}

// fx session/list entries carry sessionId/cwd/updatedAt (ISO-8601, so
// lexicographic comparison orders chronologically) and no title.
fn newestSessionIdAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const result = acp.getObjectField(value, "result") orelse return null;
    const sessions = acp.getObjectField(result, "sessions") orelse return null;
    if (sessions != .array) return null;

    var newest_id: ?[]const u8 = null;
    var newest_stamp: []const u8 = "";
    for (sessions.array.items) |session| {
        if (session != .object) continue;
        const id = acp.getOptionalObjectString(session, "sessionId") orelse continue;
        const stamp = acp.getOptionalObjectString(session, "updatedAt") orelse "";
        if (newest_id == null or std.mem.order(u8, stamp, newest_stamp) != .lt) {
            newest_id = id;
            newest_stamp = stamp;
        }
    }
    const id = newest_id orelse return null;
    return try allocator.dupe(u8, id);
}

// Parses the `configOptions` model select from a session/new or session/load
// response: {"id":"model","type":"select","currentValue":..,"options":[{value,name}]}.
fn parseModelConfigOptionsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    const result = acp.getObjectField(value, "result") orelse return error.AcpFailed;
    const config_options = acp.getObjectField(result, "configOptions") orelse return error.AcpFailed;
    if (config_options != .array) return error.AcpFailed;
    for (config_options.array.items) |option| {
        if (option != .object) continue;
        const option_id = acp.getOptionalObjectString(option, "id") orelse continue;
        if (!std.mem.eql(u8, option_id, "model")) continue;
        const entries = acp.getObjectField(option, "options") orelse continue;
        if (entries != .array) continue;
        for (entries.array.items) |entry| {
            if (entry != .object) continue;
            const id = acp.getOptionalObjectString(entry, "value") orelse continue;
            const name = acp.getOptionalObjectString(entry, "name") orelse id;
            try models.append(allocator, .{
                .provider_id = try allocator.dupe(u8, "fx"),
                .provider_name = try allocator.dupe(u8, "FX"),
                .model_id = try allocator.dupe(u8, id),
                .model_name = try allocator.dupe(u8, name),
            });
        }
    }
    if (models.items.len == 0) return error.AcpFailed;
    return models.toOwnedSlice(allocator);
}

fn resolveFxExecutableAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    configured: []const u8,
) ![]u8 {
    const candidates = [_][]const u8{ configured, DEFAULT_EXECUTABLE };
    var tried: [2][]const u8 = .{ "", "" };
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

    if (env_map.get("HOME")) |home| {
        if (home.len > 0) {
            const fallback = try std.fs.path.join(allocator, &.{ home, INSTALL_FALLBACK_RELATIVE });
            defer allocator.free(fallback);
            if (process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, fallback)) |resolved| {
                return resolved;
            } else |err| switch (err) {
                error.FileNotFound, error.AccessDenied => {},
                else => return err,
            }
        }
    }

    runtime_log.diagnostic("fx CLI not found; install it with `curl -fsSL https://fx.sh/setup.sh | bash`, ensure `fx` is on PATH, then run `fx login`.", .{});
    return error.FileNotFound;
}

test "resolveFxExecutableAlloc reports missing fx binary" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/definitely/missing");
    try env_map.put("HOME", "/definitely/missing-home");
    try std.testing.expectError(error.FileNotFound, resolveFxExecutableAlloc(std.testing.allocator, &env_map, "missing-fx"));
}

test "parseModelConfigOptionsAlloc reads fx configOptions model select" {
    const payload =
        \\{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1","configOptions":[
        \\{"id":"provider","name":"Provider","category":"provider","type":"select","currentValue":"gateway","options":[{"value":"gateway","name":"gateway"}]},
        \\{"id":"model","name":"Model","category":"model","type":"select","currentValue":"anthropic/claude-sonnet-4.5","options":[
        \\{"value":"anthropic/claude-sonnet-4.5","name":"anthropic/claude-sonnet-4.5"},
        \\{"value":"openai/gpt-5.2","name":"openai/gpt-5.2"}]},
        \\{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"code","options":[{"value":"ask","name":"Ask"},{"value":"code","name":"Code"}]}
        \\],"modes":{"currentModeId":"code","availableModes":[]}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const models = try parseModelConfigOptionsAlloc(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("fx", models[0].provider_id);
    try std.testing.expectEqualStrings("FX", models[0].provider_name);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4.5", models[0].model_id);
    try std.testing.expectEqualStrings("openai/gpt-5.2", models[1].model_id);
}

test "parseModelConfigOptionsAlloc fails without a model option" {
    const payload =
        \\{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1","configOptions":[]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.AcpFailed, parseModelConfigOptionsAlloc(std.testing.allocator, parsed.value));
}

test "newestSessionIdAlloc picks the most recently updated fx session" {
    const payload =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessions":[
        \\{"sessionId":"old","cwd":"/w","updatedAt":"2026-08-01T10:00:00Z"},
        \\{"sessionId":"new","cwd":"/w","updatedAt":"2026-08-20T09:30:00Z"},
        \\{"sessionId":"mid","cwd":"/w","updatedAt":"2026-08-10T12:00:00Z"}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const id = (try newestSessionIdAlloc(std.testing.allocator, parsed.value)).?;
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("new", id);
}

test "newestSessionIdAlloc returns null for an empty fx session list" {
    const payload =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessions":[]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try newestSessionIdAlloc(std.testing.allocator, parsed.value));
}

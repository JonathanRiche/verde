//! Cursor provider harness backed by the official `@cursor/sdk` TypeScript runtime.
//!
//! Cursor's public SDK is TypeScript. Keep this provider as a thin Zig-owned
//! bridge so Verde uses Cursor's harness, rules, hooks, skills, MCP config, and
//! model routing as Cursor intends instead of reimplementing that agent loop.

const std = @import("std");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");

const MAX_BRIDGE_STDOUT_BYTES = 16 * 1024 * 1024;
const MAX_BRIDGE_STDERR_BYTES = 512 * 1024;
const DEFAULT_MODEL = "composer-2";

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
        if (self.config.api_key) |key| {
            if (std.mem.trim(u8, key, &std.ascii.whitespace).len > 0) return .signed_in;
        }
        if (std.c.getenv("CURSOR_API_KEY")) |value| {
            if (std.mem.trim(u8, std.mem.sliceTo(value, 0), &std.ascii.whitespace).len > 0) return .signed_in;
        }
        return .signed_out;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        _ = self;
        return allocator.alloc(provider_types.ChatThreadSummary, 0);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        _ = self;
        var models: std.ArrayList(provider_types.ModelInfo) = .empty;
        defer models.deinit(allocator);

        try appendModel(allocator, &models, "composer-2", "Composer 2");
        try appendModel(allocator, &models, "gpt-5.5", "GPT-5.5");
        try appendModel(allocator, &models, "gpt-5.4", "GPT-5.4");
        try appendModel(allocator, &models, "claude-opus-4-7", "Claude Opus 4.7");
        try appendModel(allocator, &models, "claude-sonnet-4-5", "Claude Sonnet 4.5");

        return models.toOwnedSlice(allocator);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        _ = self;
        _ = allocator;
        _ = thread_id;
        return error.UnsupportedOperation;
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const bridge_response = try self.runBridge(allocator, request);
        defer bridge_response.deinit(allocator);

        if (request.on_thread_id) |on_thread_id| {
            on_thread_id(request.stream_context, bridge_response.thread_id);
        }
        if (bridge_response.run_id) |run_id| {
            if (request.on_turn_id) |on_turn_id| {
                on_turn_id(request.stream_context, run_id);
            }
        }
        if (request.on_stream_delta) |on_stream_delta| {
            if (bridge_response.reply_text.len > 0) {
                on_stream_delta(request.stream_context, bridge_response.reply_text);
            }
        }

        return .{
            .thread_id = try allocator.dupe(u8, bridge_response.thread_id),
            .reply_text = try allocator.dupe(u8, bridge_response.reply_text),
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn runBridge(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !BridgeResponse {
        const request_json = try makeBridgeRequestJsonAlloc(allocator, self.config, request);
        defer allocator.free(request_json);

        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        defer env_map.deinit();
        try env_map.put("VERDE_CURSOR_REQUEST", request_json);
        if (self.config.api_key) |api_key| {
            try env_map.put("CURSOR_API_KEY", api_key);
        }

        const executable = try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, self.config.executable);
        defer allocator.free(executable);

        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();

        const result = try std.process.run(allocator, threaded.io(), .{
            .argv = &.{ executable, "--input-type=module", "--eval", BRIDGE_SCRIPT },
            .cwd = if (request.cwd orelse self.config.cwd) |path| .{ .path = path } else .inherit,
            .env_map = &env_map,
            .stdout_limit = .limited(MAX_BRIDGE_STDOUT_BYTES),
            .stderr_limit = .limited(MAX_BRIDGE_STDERR_BYTES),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) return error.CursorBridgeFailed,
            else => return error.CursorBridgeFailed,
        }

        return parseBridgeResponseAlloc(allocator, result.stdout);
    }
};

pub fn shutdownOwnedServer() void {}

const BridgeResponse = struct {
    thread_id: []u8,
    run_id: ?[]u8 = null,
    reply_text: []u8,

    fn deinit(self: BridgeResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_id);
        if (self.run_id) |run_id| allocator.free(run_id);
        allocator.free(self.reply_text);
    }
};

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

fn makeBridgeRequestJsonAlloc(
    allocator: std.mem.Allocator,
    config: Config,
    request: provider_types.SendPromptRequest,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try std.json.Stringify.value(.{
        .prompt = request.prompt,
        .cwd = request.cwd orelse config.cwd,
        .model = request.model orelse config.model orelse DEFAULT_MODEL,
    }, .{ .whitespace = .minified }, &writer.writer);

    return writer.toOwnedSlice();
}

fn parseBridgeResponseAlloc(allocator: std.mem.Allocator, payload: []const u8) !BridgeResponse {
    const trimmed = std.mem.trim(u8, payload, &std.ascii.whitespace);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCursorBridgeResponse;
    if (getOptionalObjectString(parsed.value, "error")) |_| return error.CursorBridgeFailed;

    const thread_id = getOptionalObjectString(parsed.value, "threadId") orelse
        getOptionalObjectString(parsed.value, "agentId") orelse
        return error.MissingThreadId;
    const reply_text = getOptionalObjectString(parsed.value, "replyText") orelse "";
    const run_id = getOptionalObjectString(parsed.value, "runId");

    return .{
        .thread_id = try allocator.dupe(u8, thread_id),
        .run_id = if (run_id) |id| try allocator.dupe(u8, id) else null,
        .reply_text = try allocator.dupe(u8, reply_text),
    };
}

fn getOptionalObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

const BRIDGE_SCRIPT =
    \\const fail = (message) => {
    \\  process.stdout.write(JSON.stringify({ error: message }) + "\n");
    \\  process.exit(1);
    \\};
    \\
    \\let input;
    \\try {
    \\  input = JSON.parse(process.env.VERDE_CURSOR_REQUEST || "{}");
    \\} catch (error) {
    \\  fail(`invalid request: ${error?.message || error}`);
    \\}
    \\
    \\try {
    \\  const { Agent } = await import("@cursor/sdk");
    \\  const agent = await Agent.create({
    \\    apiKey: process.env.CURSOR_API_KEY,
    \\    model: { id: input.model || "composer-2" },
    \\    local: { cwd: input.cwd || process.cwd() },
    \\  });
    \\  const run = await agent.send(input.prompt || "");
    \\  let reply = "";
    \\  for await (const event of run.stream()) {
    \\    const text =
    \\      typeof event?.text === "string" ? event.text :
    \\      typeof event?.delta === "string" ? event.delta :
    \\      typeof event?.message === "string" ? event.message :
    \\      typeof event?.data?.text === "string" ? event.data.text :
    \\      typeof event?.data?.delta === "string" ? event.data.delta :
    \\      "";
    \\    reply += text;
    \\  }
    \\  process.stdout.write(JSON.stringify({
    \\    agentId: agent.id || null,
    \\    threadId: agent.id || run.agentId || run.id,
    \\    runId: run.id || null,
    \\    replyText: reply,
    \\  }) + "\n");
    \\} catch (error) {
    \\  fail(error?.stack || error?.message || String(error));
    \\}
;

test "parseBridgeResponseAlloc reads cursor ids and reply" {
    const payload =
        \\{"agentId":"agent_123","threadId":"agent_123","runId":"run_456","replyText":"done"}
    ;
    const parsed = try parseBridgeResponseAlloc(std.testing.allocator, payload);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("agent_123", parsed.thread_id);
    try std.testing.expectEqualStrings("run_456", parsed.run_id.?);
    try std.testing.expectEqualStrings("done", parsed.reply_text);
}

test "makeBridgeRequestJsonAlloc keeps cursor model and cwd" {
    const json = try makeBridgeRequestJsonAlloc(std.testing.allocator, .{}, .{
        .prompt = "hello",
        .cwd = "/tmp/project",
        .model = "composer-2",
    });
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", getOptionalObjectString(parsed.value, "prompt").?);
    try std.testing.expectEqualStrings("/tmp/project", getOptionalObjectString(parsed.value, "cwd").?);
    try std.testing.expectEqualStrings("composer-2", getOptionalObjectString(parsed.value, "model").?);
}

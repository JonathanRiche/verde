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
            .cwd = if (if (input.request) |request| request.cwd orelse self.config.cwd else self.config.cwd) |path| .{ .path = path } else .inherit,
            .env_map = &env_map,
            .stdout_limit = .limited(MAX_BRIDGE_STDOUT_BYTES),
            .stderr_limit = .limited(MAX_BRIDGE_STDERR_BYTES),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        return parseBridgeEventsAlloc(allocator, result.stdout, result.term, if (input.request) |request| request else null);
    }
};

pub fn shutdownOwnedServer() void {}

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
    var response: BridgeResponse = .{};
    errdefer response.deinit(allocator);

    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);

    var lines = std.mem.splitScalar(u8, payload, '\n');
    var saw_error = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const event_type = getOptionalObjectString(parsed.value, "type") orelse continue;
        if (std.mem.eql(u8, event_type, "error")) {
            saw_error = true;
            if (isAuthError(getOptionalObjectString(parsed.value, "message"))) return error.CursorSignedOut;
            continue;
        }
        if (std.mem.eql(u8, event_type, "thread")) {
            if (response.thread_id.len == 0) {
                const thread_id = getOptionalObjectString(parsed.value, "threadId") orelse getOptionalObjectString(parsed.value, "agentId") orelse continue;
                response.thread_id = try allocator.dupe(u8, thread_id);
            }
            if (response.title == null) {
                if (getOptionalObjectString(parsed.value, "title")) |title| response.title = try allocator.dupe(u8, title);
            }
            response.updated_at = getOptionalObjectInteger(parsed.value, "updatedAt") orelse response.updated_at;
            continue;
        }
        if (std.mem.eql(u8, event_type, "turn")) {
            if (response.run_id == null) {
                const run_id = getOptionalObjectString(parsed.value, "runId") orelse continue;
                response.run_id = try allocator.dupe(u8, run_id);
            }
            continue;
        }
        if (std.mem.eql(u8, event_type, "delta")) {
            const text = getOptionalObjectString(parsed.value, "text") orelse continue;
            try reply.appendSlice(allocator, text);
            if (request) |send_request| {
                if (send_request.on_stream_delta) |on_stream_delta| {
                    on_stream_delta(send_request.stream_context, text);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, event_type, "items")) {
            const json = getObjectField(parsed.value, "items") orelse continue;
            response.items = try std.json.Stringify.valueAlloc(allocator, json, .{ .whitespace = .minified });
            continue;
        }
        if (std.mem.eql(u8, event_type, "final")) {
            if (getOptionalObjectString(parsed.value, "replyText")) |text| {
                reply.clearRetainingCapacity();
                try reply.appendSlice(allocator, text);
            }
            if (response.thread_id.len == 0) {
                const thread_id = getOptionalObjectString(parsed.value, "threadId") orelse getOptionalObjectString(parsed.value, "agentId") orelse "";
                if (thread_id.len > 0) response.thread_id = try allocator.dupe(u8, thread_id);
            }
            if (response.run_id == null) {
                if (getOptionalObjectString(parsed.value, "runId")) |run_id| response.run_id = try allocator.dupe(u8, run_id);
            }
        }
    }

    switch (term) {
        .exited => |code| if (code != 0) {
            if (saw_error) return error.CursorBridgeFailed;
            return error.CursorBridgeFailed;
        },
        else => return error.CursorBridgeFailed,
    }

    response.reply_text = try reply.toOwnedSlice(allocator);
    reply = .empty;
    return response;
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
        try appendModel(allocator, &models, id, name);
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
    \\const fail = (message) => {
    \\  process.stdout.write(JSON.stringify({ type: "error", message }) + "\n");
    \\  process.exit(1);
    \\};
    \\const emit = (event) => process.stdout.write(JSON.stringify(event) + "\n");
    \\const modelSelection = (id) => id ? { id } : undefined;
    \\const agentOptions = () => ({
    \\  apiKey: process.env.CURSOR_API_KEY,
    \\  model: modelSelection(input.model || "composer-2"),
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
    \\  const { Agent, Cursor } = await import("@cursor/sdk");
    \\  if (input.command === "auth") {
    \\    await Cursor.me({ apiKey: process.env.CURSOR_API_KEY });
    \\    emit({ type: "ok" });
    \\  } else if (input.command === "list_models") {
    \\    const models = await Cursor.models.list({ apiKey: process.env.CURSOR_API_KEY });
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
    \\  const run = await agent.send(input.prompt || "", { model: modelSelection(input.model || "composer-2") });
    \\  emit({ type: "turn", runId: run.id });
    \\  let reply = "";
    \\  for await (const event of run.stream()) {
    \\    if (event?.type !== "assistant") continue;
    \\    const text = messageText(event.message);
    \\    if (!text) continue;
    \\    reply += text;
    \\    emit({ type: "delta", text });
    \\  }
    \\  const result = await run.wait();
    \\  emit({ type: "final", threadId: agentId(agent) || run.agentId, runId: run.id, replyText: result?.result || reply });
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

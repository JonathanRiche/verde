//! Claude provider harness backed by the official Claude Agent SDK.

const std = @import("std");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");
const runtime_log = @import("../runtime_log.zig");

const BRIDGE_SOURCE = @embedFile("claude_bridge.mjs");
const MAX_BRIDGE_LINE_BYTES = 8 * 1024 * 1024;

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
    process_group: ?std.posix.pid_t = null,
};

var active_process_state: ActiveProcessState = .{};

pub const Config = struct {
    executable: []const u8 = "node",
    claude_executable: []const u8 = "claude",
    cwd: ?[]const u8 = null,
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
        var response = try self.runBridge(.{ .command = "auth", .cwd = self.config.cwd, .claude_executable = self.config.claude_executable }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return .unknown;
        const state = getOptionalObjectString(result, "state") orelse return .unknown;
        if (std.mem.eql(u8, state, "signed_in")) return .signed_in;
        if (std.mem.eql(u8, state, "signed_out")) return .signed_out;
        return .unknown;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var response = try self.runBridge(.{ .command = "list_threads", .cwd = self.config.cwd, .claude_executable = self.config.claude_executable }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return allocator.alloc(provider_types.ChatThreadSummary, 0);
        const threads_value = getObjectField(result, "threads") orelse return allocator.alloc(provider_types.ChatThreadSummary, 0);
        if (threads_value != .array) return allocator.alloc(provider_types.ChatThreadSummary, 0);

        var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
        defer threads.deinit(allocator);
        for (threads_value.array.items) |thread| {
            if (thread != .object) continue;
            const id = getOptionalObjectString(thread, "id") orelse continue;
            const title = getOptionalObjectString(thread, "title") orelse id;
            try threads.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .title = try allocator.dupe(u8, title),
            });
        }
        return threads.toOwnedSlice(allocator);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var response = try self.runBridge(.{ .command = "list_models", .cwd = self.config.cwd, .claude_executable = self.config.claude_executable }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return allocator.alloc(provider_types.ModelInfo, 0);
        const models_value = getObjectField(result, "models") orelse return allocator.alloc(provider_types.ModelInfo, 0);
        if (models_value != .array) return allocator.alloc(provider_types.ModelInfo, 0);

        var models: std.ArrayList(provider_types.ModelInfo) = .empty;
        defer models.deinit(allocator);
        for (models_value.array.items) |model| {
            if (model != .object) continue;
            const id = getOptionalObjectString(model, "id") orelse continue;
            const name = getOptionalObjectString(model, "name") orelse id;
            const reasoning_supported = getOptionalObjectBool(model, "reasoning_supported") orelse true;
            const effort_values = try parseStringArrayField(allocator, model, "supported_effort_levels");
            errdefer if (effort_values) |values| {
                for (values) |value| allocator.free(value);
                allocator.free(values);
            };
            try models.append(allocator, .{
                .provider_id = try allocator.dupe(u8, "claude"),
                .provider_name = try allocator.dupe(u8, "Claude"),
                .model_id = try allocator.dupe(u8, id),
                .model_name = try allocator.dupe(u8, name),
                .reasoning_supported = reasoning_supported,
                .claude_effort_values = effort_values,
            });
        }
        return models.toOwnedSlice(allocator);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var response = try self.runBridge(.{
            .command = "read_thread",
            .cwd = self.config.cwd,
            .thread_id = thread_id,
            .claude_executable = self.config.claude_executable,
        }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return error.MissingSessionId;
        const id = getOptionalObjectString(result, "thread_id") orelse thread_id;
        const title = getOptionalObjectString(result, "title") orelse id;
        const messages_value = getObjectField(result, "messages");

        var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
        defer {
            for (messages.items) |message| {
                allocator.free(message.author);
                allocator.free(message.body);
            }
            messages.deinit(allocator);
        }

        if (messages_value != null and messages_value.? == .array) {
            for (messages_value.?.array.items) |message| {
                if (message != .object) continue;
                const body = getOptionalObjectString(message, "text") orelse continue;
                const role_text = getOptionalObjectString(message, "role") orelse "assistant";
                const role = parseRole(role_text);
                try messages.append(allocator, .{
                    .role = role,
                    .author = try allocator.dupe(u8, role_text),
                    .body = try allocator.dupe(u8, body),
                });
            }
        }

        const owned_messages = try messages.toOwnedSlice(allocator);
        messages = .empty;
        return .{
            .thread_id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .messages = owned_messages,
        };
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const image_attachments = try collectImageAttachments(allocator, request);
        defer allocator.free(image_attachments);

        const bridge_request = BridgeSendPromptRequest{
            .command = "send_prompt",
            .thread_id = request.thread_id,
            .prompt = request.prompt,
            .images = image_attachments,
            .cwd = request.cwd orelse self.config.cwd,
            .model = request.model,
            .reasoning_effort = if (request.reasoning_effort) |effort| @tagName(effort) else null,
            .approval_policy = if (request.approval_policy) |policy| @tagName(policy) else null,
            .sandbox_mode = if (request.sandbox_mode) |mode| @tagName(mode) else null,
            .claude_executable = self.config.claude_executable,
        };
        var response = try self.runBridge(bridge_request, request);
        defer response.deinit(self.allocator);

        const result = response.result orelse return error.ClaudeRequestFailed;
        const thread_id = getOptionalObjectString(result, "thread_id") orelse request.thread_id orelse return error.MissingSessionId;
        const reply_text = getOptionalObjectString(result, "reply_text") orelse "";

        return .{
            .thread_id = try allocator.dupe(u8, thread_id),
            .reply_text = try allocator.dupe(u8, reply_text),
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        _ = self;
        _ = request;
        active_process_state.mutex.lock();
        defer active_process_state.mutex.unlock();

        const child = active_process_state.child orelse return;
        const process_group = active_process_state.process_group;
        var threaded = std.Io.Threaded.init_single_threaded;
        if (process_group) |pgid| {
            std.posix.kill(-pgid, std.posix.SIG.TERM) catch |err| {
                runtime_log.diagnostic("claude.interruptThread group SIGTERM failed pgid={d}: {s}", .{ pgid, @errorName(err) });
                child.kill(threaded.io());
            };
        } else {
            child.kill(threaded.io());
        }
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn runBridge(self: *Client, payload: anytype, stream_request: ?provider_types.SendPromptRequest) !BridgeResponse {
        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();

        const executable = try process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable);
        defer self.allocator.free(executable);

        const bridge_path = try writeBridgeFile(self.allocator);
        defer self.allocator.free(bridge_path);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        runtime_log.diagnostic("claude.runBridge spawning cwd={s} bridge={s}", .{ self.config.cwd orelse "(inherit)", bridge_path });
        var child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ executable, bridge_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());
        if (child.id) |pid| {
            _ = std.c.setpgid(pid, pid);
        }
        registerActiveChild(&child);
        defer unregisterActiveChild(&child);

        try writeJsonLine(self.allocator, child.stdin.?, payload);
        const keep_stdin_open = if (stream_request) |request| request.on_approval_request != null else false;
        if (!keep_stdin_open) {
            child.stdin.?.close(threaded.io());
            child.stdin = null;
        }

        var response: BridgeResponse = .{};
        errdefer response.deinit(self.allocator);

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.stdout.?.reader(threaded.io(), &read_buffer);
        while (true) {
            const maybe_line = try reader.interface.takeDelimiter('\n');
            if (maybe_line == null) break;
            const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
            if (line.len == 0) continue;
            try self.handleBridgeLine(line, stream_request, child.stdin, &response);
        }

        const term = try child.wait(threaded.io());
        if (child.stdin) |stdin| {
            stdin.close(threaded.io());
            child.stdin = null;
        }
        child.stdout = null;
        if (response.error_message) |message| {
            runtime_log.diagnostic("claude.runBridge error: {s}", .{message});
            return error.ClaudeRequestFailed;
        }
        switch (term) {
            .exited => |code| if (code != 0) return error.ClaudeRequestFailed,
            else => return error.ClaudeRequestFailed,
        }
        runtime_log.diagnostic("claude.runBridge completed", .{});
        return response;
    }

    fn handleBridgeLine(
        self: *Client,
        line: []const u8,
        stream_request: ?provider_types.SendPromptRequest,
        stdin: ?std.Io.File,
        response: *BridgeResponse,
    ) !void {
        if (line.len > MAX_BRIDGE_LINE_BYTES) return error.ClaudeMessageTooLarge;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();

        const kind = getOptionalObjectString(parsed.value, "type") orelse return;
        if (std.mem.eql(u8, kind, "error")) {
            response.replaceError(self.allocator, getOptionalObjectString(parsed.value, "message") orelse "Claude provider request failed.") catch {};
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "thread_id")) {
            if (stream_request) |request| {
                if (request.on_thread_id) |on_thread_id| {
                    if (getOptionalObjectString(parsed.value, "thread_id")) |thread_id| {
                        on_thread_id(request.stream_context, thread_id);
                    }
                }
            }
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "delta")) {
            if (stream_request) |request| {
                if (request.on_stream_delta) |on_stream_delta| {
                    if (getOptionalObjectString(parsed.value, "text")) |text| {
                        on_stream_delta(request.stream_context, text);
                    }
                }
            }
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "stream_event")) {
            if (stream_request) |request| {
                if (request.on_stream_event) |on_stream_event| {
                    const title = getOptionalObjectString(parsed.value, "title") orelse "Claude";
                    const body = getOptionalObjectString(parsed.value, "body") orelse "";
                    on_stream_event(request.stream_context, .{ .message = .{ .title = title, .body = body } });
                }
            }
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "approval_request")) {
            if (stream_request) |request| {
                if (request.on_approval_request) |on_approval_request| {
                    const request_id = getOptionalObjectInt(parsed.value, "request_id") orelse {
                        parsed.deinit();
                        return;
                    };
                    const call_id = getOptionalObjectString(parsed.value, "call_id") orelse "claude-tool";
                    const title = getOptionalObjectString(parsed.value, "title") orelse "Claude permission request";
                    const body = getOptionalObjectString(parsed.value, "body") orelse "";
                    const decision = on_approval_request(request.stream_context, .{
                        .call_id = call_id,
                        .title = title,
                        .body = body,
                    });
                    if (stdin) |input| {
                        try writeJsonLine(self.allocator, input, .{
                            .type = "approval_response",
                            .request_id = request_id,
                            .decision = if (decision == .approve) "approve" else "deny",
                        });
                    }
                }
            }
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "result")) {
            if (response.result_tree) |*old| old.deinit();
            response.result_tree = parsed;
            response.result = parsed.value;
            return;
        }
        parsed.deinit();
    }
};

pub fn shutdownOwnedServer() void {}

fn registerActiveChild(child: *std.process.Child) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    active_process_state.child = child;
    active_process_state.process_group = child.id;
}

fn unregisterActiveChild(child: *std.process.Child) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    if (active_process_state.child == child) {
        active_process_state.child = null;
        active_process_state.process_group = null;
    }
}

const BridgeResponse = struct {
    result_tree: ?std.json.Parsed(std.json.Value) = null,
    result: ?std.json.Value = null,
    error_message: ?[]u8 = null,

    fn deinit(self: *BridgeResponse, allocator: std.mem.Allocator) void {
        if (self.result_tree) |*tree| tree.deinit();
        if (self.error_message) |message| allocator.free(message);
        self.* = .{};
    }

    fn replaceError(self: *BridgeResponse, allocator: std.mem.Allocator, message: []const u8) !void {
        if (self.error_message) |old| allocator.free(old);
        self.error_message = try allocator.dupe(u8, message);
    }
};

const BridgeSendPromptRequest = struct {
    command: []const u8,
    thread_id: ?[]const u8 = null,
    prompt: []const u8,
    images: []const provider_types.ImageAttachment = &.{},
    cwd: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    approval_policy: ?[]const u8 = null,
    sandbox_mode: ?[]const u8 = null,
    claude_executable: []const u8,
};

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

fn writeBridgeFile(allocator: std.mem.Allocator) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const cwd = try std.process.currentPathAlloc(threaded.io(), allocator);
    defer allocator.free(cwd);
    const path = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "verde-claude-agent-sdk-bridge.mjs" });
    errdefer allocator.free(path);

    const file = try std.Io.Dir.createFileAbsolute(threaded.io(), path, .{ .truncate = true });
    defer file.close(threaded.io());
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(BRIDGE_SOURCE);
    try writer.interface.flush();
    return path;
}

fn writeJsonLine(allocator: std.mem.Allocator, file: std.Io.File, payload: anytype) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(encoded);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
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

fn getOptionalObjectInt(value: std.json.Value, field: []const u8) ?i64 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .integer => |int| int,
        else => null,
    };
}

fn parseStringArrayField(allocator: std.mem.Allocator, value: std.json.Value, field: []const u8) !?[][:0]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    if (field_value != .array) return null;
    var items: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    for (field_value.array.items) |item| {
        if (item != .string) continue;
        try items.append(allocator, try allocator.dupeZ(u8, item.string));
    }
    return try items.toOwnedSlice(allocator);
}

fn parseRole(text: []const u8) provider_types.MessageRole {
    if (std.mem.eql(u8, text, "system")) return .system;
    if (std.mem.eql(u8, text, "user")) return .user;
    return .assistant;
}

test "parseRole maps Claude roles" {
    try std.testing.expectEqual(provider_types.MessageRole.user, parseRole("user"));
    try std.testing.expectEqual(provider_types.MessageRole.assistant, parseRole("assistant"));
    try std.testing.expectEqual(provider_types.MessageRole.system, parseRole("system"));
    try std.testing.expectEqual(provider_types.MessageRole.assistant, parseRole("other"));
}

test "collectImageAttachments preserves multi-image and legacy compatibility" {
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

test "BridgeSendPromptRequest serializes multiple images" {
    const images = [_]provider_types.ImageAttachment{
        .{ .path = "/tmp/one.png" },
        .{ .path = "/tmp/two.png" },
    };
    const payload = BridgeSendPromptRequest{
        .command = "send_prompt",
        .prompt = "describe",
        .images = images[0..],
        .claude_executable = "claude",
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{});
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"images\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "/tmp/one.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "/tmp/two.png") != null);
}

//! Claude provider harness backed by the official Claude Agent SDK.

const std = @import("std");
const builtin = @import("builtin");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../process_env.zig");
const provider_types = @import("../provider_types.zig");
const runtime_log = @import("../runtime_log.zig");

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
    child: ?*platform_process.OwnedChild = null,
};

var active_process_state: ActiveProcessState = .{};

const CLAUDE_SLASH_COMMANDS = [_]provider_types.ProviderSlashCommand{
    .{
        .id = .usage,
        .name = "/usage",
        .summary = "Show Claude session cost, token, context, and plan usage estimates.",
        .usage = "/usage",
        .requires_thread = false,
    },
    .{
        .id = .compact,
        .name = "/compact",
        .summary = "Compact the current Claude Code session context when the SDK exposes the command.",
        .usage = "/compact [instructions]",
        .requires_thread = true,
    },
    .{
        .id = .custom,
        .name = "/code-review",
        .summary = "Run Claude's code-review skill for the current workspace or instructions.",
        .usage = "/code-review [instructions]",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/debug",
        .summary = "Run Claude's debugging skill with optional symptoms or context.",
        .usage = "/debug [symptoms]",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/loop",
        .summary = "Run Claude's iterative implementation/test loop skill.",
        .usage = "/loop [goal]",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/batch",
        .summary = "Run Claude's batch skill for multi-step or parallelizable work.",
        .usage = "/batch [goal]",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/skills",
        .summary = "List or use Claude skills exposed by the SDK for this project.",
        .usage = "/skills [query]",
        .requires_thread = false,
    },
};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return CLAUDE_SLASH_COMMANDS[0..];
}

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

    pub fn slashCommands(self: *Client) []const provider_types.ProviderSlashCommand {
        _ = self;
        return providerSlashCommands();
    }

    pub fn runSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        return switch (request.command) {
            .usage, .compact, .custom => self.runBridgeSlashCommand(allocator, request),
            else => error.UnsupportedOperation,
        };
    }

    fn runBridgeSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const command_name = slashCommandName(request) orelse return error.UnsupportedOperation;
        var response = try self.runBridge(.{
            .provider = "claude",
            .command = "run_slash_command",
            .thread_id = request.thread_id,
            .slash_command = command_name,
            .raw_text = request.raw_text,
            .args = request.args,
            .cwd = if (request.cwd) |cwd| cwd else self.config.cwd,
            .claude_executable = self.config.claude_executable,
        }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return error.ClaudeRequestFailed;
        return slashCommandResultAlloc(allocator, result);
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        var response = try self.runBridge(.{ .provider = "claude", .command = "auth", .cwd = self.config.cwd, .claude_executable = self.config.claude_executable }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return .unknown;
        const state = getOptionalObjectString(result, "state") orelse return .unknown;
        if (std.mem.eql(u8, state, "signed_in")) return .signed_in;
        if (std.mem.eql(u8, state, "signed_out")) return .signed_out;
        return .unknown;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var response = try self.runBridge(.{ .provider = "claude", .command = "list_threads", .cwd = self.config.cwd, .claude_executable = self.config.claude_executable }, null);
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
        var response = try self.runBridge(.{ .provider = "claude", .command = "list_models", .cwd = self.config.cwd, .claude_executable = self.config.claude_executable }, null);
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
            .provider = "claude",
            .command = "read_thread",
            .cwd = self.config.cwd,
            .thread_id = thread_id,
            .claude_executable = self.config.claude_executable,
        }, null);
        defer response.deinit(self.allocator);

        const result = response.result orelse return error.MissingSessionId;
        const id = getOptionalObjectString(result, "thread_id") orelse thread_id;
        const title = getOptionalObjectString(result, "title") orelse id;
        const model_id = getOptionalObjectString(result, "model_id");
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
            .model_id = if (model_id) |model| try allocator.dupe(u8, model) else null,
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
            .provider = "claude",
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
        child.terminateTree();
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

        const bridge_path = try providerBridgePathAlloc(self.allocator);
        defer self.allocator.free(bridge_path);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        runtime_log.diagnostic("claude.runBridge spawning cwd={s} bridge={s}", .{ self.config.cwd orelse "(inherit)", bridge_path });
        var child = try platform_process.spawn(self.allocator, threaded.io(), .{
            .argv = &.{ executable, bridge_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());
        registerActiveChild(&child);
        defer unregisterActiveChild(&child);

        try writeJsonLine(self.allocator, child.child.stdin.?, payload);
        const keep_stdin_open = if (stream_request) |request| request.on_approval_request != null else false;
        if (!keep_stdin_open) {
            child.child.stdin.?.close(threaded.io());
            child.child.stdin = null;
        }

        var response: BridgeResponse = .{};
        errdefer response.deinit(self.allocator);

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.child.stdout.?.reader(threaded.io(), &read_buffer);
        while (true) {
            const maybe_line = try takeBridgeLineAlloc(self.allocator, &reader.interface);
            if (maybe_line == null) break;
            defer self.allocator.free(maybe_line.?);
            const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
            if (line.len == 0) continue;
            try self.handleBridgeLine(line, stream_request, child.child.stdin, &response);
        }

        // Stop exposing the pointer before wait closes its platform handles.
        unregisterActiveChild(&child);
        const term = try child.wait(threaded.io());
        if (child.child.stdin) |stdin| {
            stdin.close(threaded.io());
            child.child.stdin = null;
        }
        child.child.stdout = null;
        if (response.error_message) |message| {
            provider_diagnostics.logError(.claude_bridge, null, message);
            if (stream_request) |request| {
                if (request.on_failure) |on_failure| {
                    on_failure(request.stream_context, message);
                }
            }
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

pub fn shutdownOwnedServer() void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    if (active_process_state.child) |child| child.terminateTree();
}

fn takeBridgeLineAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    _ = reader.streamDelimiterLimit(&writer.writer, '\n', .limited(MAX_BRIDGE_LINE_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => return error.ClaudeMessageTooLarge,
        else => return err,
    };
    const has_bytes = writer.written().len > 0;
    _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
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

fn registerActiveChild(child: *platform_process.OwnedChild) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    active_process_state.child = child;
}

fn unregisterActiveChild(child: *platform_process.OwnedChild) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    if (active_process_state.child == child) {
        active_process_state.child = null;
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
    provider: []const u8,
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

fn providerBridgePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try platform_runtime.executablePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.FileNotFound;

    var installed = try providerBridgeInstalledPathsAlloc(allocator, builtin.os.tag, exe_dir);
    defer deinitOwnedPaths(allocator, &installed);
    for (installed.items) |candidate| {
        if (pathExists(allocator, candidate)) return try allocator.dupe(u8, candidate);
    }

    const dev = try std.fs.path.resolve(allocator, &.{ "zig-out", "share", "verde", "provider_bridge.mjs" });
    if (pathExists(allocator, dev)) return dev;
    allocator.free(dev);

    const desktop_dev = try std.fs.path.resolve(allocator, &.{ "packages", "desktop", "zig-out", "share", "verde", "provider_bridge.mjs" });
    if (pathExists(allocator, desktop_dev)) return desktop_dev;
    allocator.free(desktop_dev);

    return error.ProviderBridgeNotFound;
}

fn providerBridgeInstalledPathsAlloc(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    exe_dir: []const u8,
) !std.ArrayList([]u8) {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    if (os_tag == .macos) {
        try appendProviderBridgePath(allocator, &paths, &.{ exe_dir, "..", "Resources", "provider_bridge.mjs" });
        return paths;
    }

    // Packaged CLI binaries live in bin/, while the Windows GUI executable and
    // flat Linux installs (e.g. AUR's /usr/lib/verde) keep everything beside
    // the executable. Probe both layouts, then the system-wide share locations
    // distro packages may use, before falling back to dev trees.
    try appendProviderBridgePath(allocator, &paths, &.{ exe_dir, "..", "share", "verde", "provider_bridge.mjs" });
    try appendProviderBridgePath(allocator, &paths, &.{ exe_dir, "share", "verde", "provider_bridge.mjs" });
    if (os_tag != .windows) {
        try appendProviderBridgePath(allocator, &paths, &.{"/usr/local/share/verde/provider_bridge.mjs"});
        try appendProviderBridgePath(allocator, &paths, &.{"/usr/share/verde/provider_bridge.mjs"});
    }
    return paths;
}

fn appendProviderBridgePath(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8), components: []const []const u8) !void {
    const path = try std.fs.path.resolve(allocator, components);
    errdefer allocator.free(path);
    try paths.append(allocator, path);
}

fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn pathExists(allocator: std.mem.Allocator, path: []const u8) bool {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().access(threaded.io(), path, .{}) catch return false;
    return true;
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

fn dupeOptionalObjectString(allocator: std.mem.Allocator, value: std.json.Value, field: []const u8) !?[]u8 {
    const text = getOptionalObjectString(value, field) orelse return null;
    return try allocator.dupe(u8, text);
}

fn slashCommandName(request: provider_types.RunSlashCommandRequest) ?[]const u8 {
    return switch (request.command) {
        .usage => "/usage",
        .compact => "/compact",
        .custom => slashCommandRoot(request.raw_text),
        else => null,
    };
}

fn slashCommandRoot(raw_text: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "/")) return null;
    const root_end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    if (root_end <= 1) return null;
    return text[0..root_end];
}

fn slashCommandResultAlloc(allocator: std.mem.Allocator, value: std.json.Value) !provider_types.RunSlashCommandResult {
    var result: provider_types.RunSlashCommandResult = .{
        .handled = getOptionalObjectBool(value, "handled") orelse true,
    };
    errdefer result.deinit(allocator);

    result.thread_id = try dupeOptionalObjectString(allocator, value, "thread_id");
    result.notice = try dupeOptionalObjectString(allocator, value, "notice");
    result.transcript_title = try dupeOptionalObjectString(allocator, value, "transcript_title");
    result.transcript_body = try dupeOptionalObjectString(allocator, value, "transcript_body");
    return result;
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

test "Claude bridge reader accepts lines larger than its scratch buffer" {
    const line_len = 20 * 1024;
    const input = try std.testing.allocator.alloc(u8, line_len + 4);
    defer std.testing.allocator.free(input);
    @memset(input[0..line_len], 'x');
    @memcpy(input[line_len..], "\nok\n");

    var reader = std.Io.Reader.fixed(input);
    const first = (try takeBridgeLineAlloc(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(line_len, first.len);
    try std.testing.expectEqual(@as(u8, 'x'), first[0]);
    try std.testing.expectEqual(@as(u8, 'x'), first[first.len - 1]);

    const second = (try takeBridgeLineAlloc(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("ok", second);
    try std.testing.expectEqual(@as(?[]u8, null), try takeBridgeLineAlloc(std.testing.allocator, &reader));
}

test "providerSlashCommands exposes Claude usage and compact" {
    const commands = providerSlashCommands();
    try std.testing.expectEqual(@as(usize, 7), commands.len);
    try std.testing.expectEqual(provider_types.ProviderSlashCommandId.usage, commands[0].id);
    try std.testing.expectEqualStrings("/usage", commands[0].name);
    try std.testing.expect(!commands[0].requires_thread);
    try std.testing.expectEqual(provider_types.ProviderSlashCommandId.compact, commands[1].id);
    try std.testing.expectEqualStrings("/compact", commands[1].name);
    try std.testing.expect(commands[1].requires_thread);
    try std.testing.expectEqual(provider_types.ProviderSlashCommandId.custom, commands[2].id);
    try std.testing.expectEqualStrings("/code-review", commands[2].name);
}

test "slashCommandResultAlloc duplicates bridge result strings" {
    const payload =
        \\{"handled":true,"notice":"Claude usage loaded.","transcript_title":"Usage","transcript_body":"Cost: $0.01"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const result = try slashCommandResultAlloc(std.testing.allocator, parsed.value);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.handled);
    try std.testing.expectEqualStrings("Claude usage loaded.", result.notice.?);
    try std.testing.expectEqualStrings("Usage", result.transcript_title.?);
    try std.testing.expectEqualStrings("Cost: $0.01", result.transcript_body.?);
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
        .provider = "claude",
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

test "Windows provider bridge probes CLI and package-root GUI layouts" {
    var paths = try providerBridgeInstalledPathsAlloc(std.testing.allocator, .windows, "/package/bin");
    defer deinitOwnedPaths(std.testing.allocator, &paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    for (paths.items) |path| {
        for (path) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };
    }
    try std.testing.expect(std.mem.endsWith(u8, paths.items[0], "/package/share/verde/provider_bridge.mjs"));
    try std.testing.expect(std.mem.endsWith(u8, paths.items[1], "/package/bin/share/verde/provider_bridge.mjs"));
}

test "Linux provider bridge probes packaged, flat, and system share layouts" {
    var paths = try providerBridgeInstalledPathsAlloc(std.testing.allocator, .linux, "/usr/lib/verde");
    defer deinitOwnedPaths(std.testing.allocator, &paths);

    try std.testing.expectEqual(@as(usize, 4), paths.items.len);
    try std.testing.expectEqualStrings("/usr/lib/share/verde/provider_bridge.mjs", paths.items[0]);
    try std.testing.expectEqualStrings("/usr/lib/verde/share/verde/provider_bridge.mjs", paths.items[1]);
    try std.testing.expectEqualStrings("/usr/local/share/verde/provider_bridge.mjs", paths.items[2]);
    try std.testing.expectEqualStrings("/usr/share/verde/provider_bridge.mjs", paths.items[3]);
}

test "Windows detached bridge source uses PowerShell temp paths and tree cleanup" {
    const source = @embedFile("provider_bridge.ts");
    try std.testing.expect(std.mem.indexOf(u8, source, "process.platform === \"win32\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "tmpdir()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "detachedPosixShellCommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "setsid sh -lc") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "taskkill.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "'/T' '/F'") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "PID file:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Stop-Process") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "Write-Output"));
}

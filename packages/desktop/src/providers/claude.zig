//! Claude provider harness backed by the official Claude Agent SDK.

const std = @import("std");
const builtin = @import("builtin");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const MAX_BRIDGE_LINE_BYTES = 8 * 1024 * 1024;
const BRIDGE_STOP_POLL_MS = 20;
const BRIDGE_STEER_RESPONSE_WAIT_MS = 500;

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const ActiveBridge = struct {
    child: ?*platform_process.OwnedChild = null,
    thread_id: ?[]u8 = null,
    pending_steer_request_id: ?u64 = null,
    steer_response_request_id: ?u64 = null,
    steer_response_accepted: bool = false,
};

const ActiveProcessState = struct {
    mutex: Mutex = .{},
    bridges: std.ArrayListUnmanaged(ActiveBridge) = .empty,
    next_steer_request_id: u64 = 1,
};

var active_process_state: ActiveProcessState = .{};

const BridgeStopMonitor = struct {
    request: ?provider_types.SendPromptRequest,
    target: *anyopaque,
    terminate: *const fn (*anyopaque) void,
    finished: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *BridgeStopMonitor) !void {
        const request = self.request orelse return;
        if (request.on_should_stop == null) return;
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn finish(self: *BridgeStopMonitor) void {
        self.finished.store(true, .release);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn watch(self: *BridgeStopMonitor) void {
        const request = self.request orelse return;
        const should_stop = request.on_should_stop orelse return;
        while (!self.finished.load(.acquire)) {
            if (should_stop(request.stream_context)) {
                self.cancelled.store(true, .release);
                self.terminate(self.target);
                return;
            }
            platform_runtime.sleepMillis(BRIDGE_STOP_POLL_MS);
        }
    }
};

fn terminateBridgeChild(context: *anyopaque) void {
    const child: *platform_process.OwnedChild = @ptrCast(@alignCast(context));
    child.terminateTree();
}

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
        active_process_state.mutex.lock();
        defer active_process_state.mutex.unlock();
        const index = activeBridgeIndexForThreadLocked(request.thread_id) orelse return;
        const child = active_process_state.bridges.items[index].child orelse return;
        child.terminateTree();
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        active_process_state.mutex.lock();
        const bridge_index = activeBridgeIndexForThreadLocked(request.thread_id) orelse {
            active_process_state.mutex.unlock();
            return error.ClaudeActiveTurnNotSteerable;
        };
        const bridge = &active_process_state.bridges.items[bridge_index];
        const child = bridge.child orelse {
            active_process_state.mutex.unlock();
            return error.ClaudeActiveTurnNotSteerable;
        };
        if (bridge.pending_steer_request_id != null) {
            active_process_state.mutex.unlock();
            return error.ClaudeSteerAlreadyPending;
        }
        const stdin = child.child.stdin orelse {
            active_process_state.mutex.unlock();
            return error.ClaudeActiveTurnNotSteerable;
        };
        const request_id = active_process_state.next_steer_request_id;
        active_process_state.next_steer_request_id +%= 1;
        if (active_process_state.next_steer_request_id == 0) active_process_state.next_steer_request_id = 1;
        bridge.pending_steer_request_id = request_id;
        bridge.steer_response_request_id = null;
        writeJsonLine(self.allocator, stdin, .{
            .type = "steer_prompt",
            .request_id = request_id,
            .prompt = request.prompt,
            .images = request.images,
        }) catch |err| {
            bridge.pending_steer_request_id = null;
            active_process_state.mutex.unlock();
            return err;
        };
        active_process_state.mutex.unlock();

        var waited_ms: usize = 0;
        while (waited_ms < BRIDGE_STEER_RESPONSE_WAIT_MS) : (waited_ms += 1) {
            active_process_state.mutex.lock();
            const current_index = activeBridgeIndexForChildLocked(child) orelse {
                active_process_state.mutex.unlock();
                return error.ClaudeActiveTurnNotSteerable;
            };
            const current = &active_process_state.bridges.items[current_index];
            if (current.steer_response_request_id == request_id) {
                const accepted = current.steer_response_accepted;
                current.pending_steer_request_id = null;
                current.steer_response_request_id = null;
                active_process_state.mutex.unlock();
                if (!accepted) return error.ClaudeActiveTurnNotSteerable;
                return;
            }
            active_process_state.mutex.unlock();
            platform_runtime.sleepMillis(1);
        }

        active_process_state.mutex.lock();
        if (activeBridgeIndexForChildLocked(child)) |current_index| {
            const current = &active_process_state.bridges.items[current_index];
            if (current.pending_steer_request_id == request_id) current.pending_steer_request_id = null;
        }
        active_process_state.mutex.unlock();
        return error.ClaudeSteerResponseTimeout;
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
        try registerActiveChild(&child, if (stream_request) |request| request.thread_id else null);
        defer unregisterActiveChild(&child);
        var stop_monitor: BridgeStopMonitor = .{
            .request = stream_request,
            .target = &child,
            .terminate = terminateBridgeChild,
        };
        try stop_monitor.start();
        defer stop_monitor.finish();

        try writeJsonLine(self.allocator, child.child.stdin.?, payload);
        const keep_stdin_open = stream_request != null;
        if (!keep_stdin_open) {
            child.child.stdin.?.close(threaded.io());
            child.child.stdin = null;
        }

        var response: BridgeResponse = .{};
        errdefer response.deinit(self.allocator);

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = child.child.stdout.?.reader(threaded.io(), &read_buffer);
        while (true) {
            const maybe_line = takeBridgeLineAlloc(self.allocator, &reader.interface) catch |err| {
                if (stop_monitor.cancelled.load(.acquire)) return error.ClaudeTurnInterrupted;
                return err;
            };
            if (maybe_line == null) break;
            defer self.allocator.free(maybe_line.?);
            const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
            if (line.len == 0) continue;
            try self.handleBridgeLine(line, stream_request, child.child.stdin, &child, &response);
        }

        // Stop exposing the pointer before wait closes its platform handles.
        unregisterActiveChild(&child);
        const term = child.wait(threaded.io()) catch |err| {
            stop_monitor.finish();
            if (stop_monitor.cancelled.load(.acquire)) return error.ClaudeTurnInterrupted;
            return err;
        };
        stop_monitor.finish();
        if (child.child.stdin) |stdin| {
            stdin.close(threaded.io());
            child.child.stdin = null;
        }
        child.child.stdout = null;
        if (stop_monitor.cancelled.load(.acquire)) return error.ClaudeTurnInterrupted;
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
        child: *platform_process.OwnedChild,
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
            if (getOptionalObjectString(parsed.value, "thread_id")) |thread_id| {
                setActiveThreadId(child, thread_id);
                if (stream_request) |request| {
                    if (request.on_thread_id) |on_thread_id| {
                        on_thread_id(request.stream_context, thread_id);
                    }
                }
            }
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "steer_response")) {
            const request_id = getOptionalObjectInt(parsed.value, "request_id") orelse {
                parsed.deinit();
                return;
            };
            if (request_id >= 0) {
                recordSteerResponse(child, @intCast(request_id), getOptionalObjectBool(parsed.value, "accepted") orelse false);
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
        if (std.mem.eql(u8, kind, "tool_call_event")) {
            if (stream_request) |request| {
                _ = emitBridgeToolCallEvent(parsed.value, request);
            }
            parsed.deinit();
            return;
        }
        if (std.mem.eql(u8, kind, "diff_event")) {
            if (stream_request) |request| {
                _ = try emitBridgeDiffEvent(parsed.value, request);
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
    for (active_process_state.bridges.items) |bridge| {
        if (bridge.child) |child| child.terminateTree();
    }
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

fn registerActiveChild(child: *platform_process.OwnedChild, thread_id: ?[]const u8) !void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const owned_thread_id = if (thread_id) |value| try std.heap.page_allocator.dupe(u8, value) else null;
    errdefer if (owned_thread_id) |value| std.heap.page_allocator.free(value);
    try active_process_state.bridges.append(std.heap.page_allocator, .{
        .child = child,
        .thread_id = owned_thread_id,
    });
}

fn unregisterActiveChild(child: *platform_process.OwnedChild) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const index = activeBridgeIndexForChildLocked(child) orelse return;
    const bridge = active_process_state.bridges.swapRemove(index);
    if (bridge.thread_id) |thread_id| std.heap.page_allocator.free(thread_id);
}

fn activeBridgeIndexForChildLocked(child: *platform_process.OwnedChild) ?usize {
    for (active_process_state.bridges.items, 0..) |bridge, index| {
        if (bridge.child == child) return index;
    }
    return null;
}

fn activeBridgeIndexForThreadLocked(thread_id: []const u8) ?usize {
    for (active_process_state.bridges.items, 0..) |bridge, index| {
        if (bridge.thread_id) |active_thread_id| {
            if (std.mem.eql(u8, active_thread_id, thread_id)) return index;
        }
    }
    return null;
}

fn setActiveThreadId(child: *platform_process.OwnedChild, thread_id: []const u8) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const owned = std.heap.page_allocator.dupe(u8, thread_id) catch return;
    const index = activeBridgeIndexForChildLocked(child) orelse {
        std.heap.page_allocator.free(owned);
        return;
    };
    const bridge = &active_process_state.bridges.items[index];
    if (bridge.thread_id) |old| std.heap.page_allocator.free(old);
    bridge.thread_id = owned;
}

fn recordSteerResponse(child: *platform_process.OwnedChild, request_id: u64, accepted: bool) void {
    active_process_state.mutex.lock();
    defer active_process_state.mutex.unlock();
    const index = activeBridgeIndexForChildLocked(child) orelse return;
    const bridge = &active_process_state.bridges.items[index];
    if (bridge.pending_steer_request_id != request_id) return;
    bridge.steer_response_request_id = request_id;
    bridge.steer_response_accepted = accepted;
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

fn bridgeToolCallKind(value: []const u8) provider_types.ToolCallKind {
    if (std.mem.eql(u8, value, "mcp")) return .mcp;
    return .other;
}

fn bridgeToolCallStatus(value: []const u8) provider_types.ToolCallStatus {
    if (std.mem.eql(u8, value, "pending")) return .pending;
    if (std.mem.eql(u8, value, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, value, "completed")) return .completed;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "cancelled")) return .cancelled;
    return .unknown;
}

fn emitBridgeToolCallEvent(root: std.json.Value, request: provider_types.SendPromptRequest) bool {
    const on_stream_event = request.on_stream_event orelse return false;
    const call_id = getOptionalObjectString(root, "call_id") orelse return false;
    const kind = getOptionalObjectString(root, "kind");
    const status = getOptionalObjectString(root, "status");
    on_stream_event(request.stream_context, .{ .tool_call = .{
        .call_id = call_id,
        .title = getOptionalObjectString(root, "title") orelse "",
        .kind = if (kind) |value| bridgeToolCallKind(value) else null,
        .status = if (status) |value| bridgeToolCallStatus(value) else null,
        .input = getOptionalObjectString(root, "input"),
        .output = getOptionalObjectString(root, "output"),
        .error_text = getOptionalObjectString(root, "error_text"),
    } });
    return true;
}

const ClaudeTestDiffCapture = struct {
    path: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    count: usize = 0,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *ClaudeTestDiffCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .diff => |diff| {
                if (diff.files.len == 0) return;
                self.path = diff.files[0].path;
                self.patch = diff.files[0].patch;
                self.count += 1;
            },
            else => {},
        }
    }
};

const ClaudeTestToolCapture = struct {
    call_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    kind: ?provider_types.ToolCallKind = null,
    status: ?provider_types.ToolCallStatus = null,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    count: usize = 0,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *ClaudeTestToolCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .tool_call => |tool_call| {
                self.call_id = tool_call.call_id;
                self.title = tool_call.title;
                self.kind = tool_call.kind;
                self.status = tool_call.status;
                self.input = tool_call.input;
                self.output = tool_call.output;
                self.count += 1;
            },
            else => {},
        }
    }
};

fn emitBridgeDiffEvent(root: std.json.Value, request: provider_types.SendPromptRequest) !bool {
    const on_stream_event = request.on_stream_event orelse return false;
    const files_value = getObjectField(root, "files") orelse return false;
    if (files_value != .array) return false;

    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);
    for (files_value.array.items) |file| {
        const path = getOptionalObjectString(file, "path") orelse continue;
        try files.append(std.heap.page_allocator, .{
            .path = path,
            .additions = getOptionalObjectInt(file, "additions") orelse 0,
            .deletions = getOptionalObjectInt(file, "deletions") orelse 0,
            .patch = getOptionalObjectString(file, "patch"),
        });
    }
    if (files.items.len == 0) return false;
    on_stream_event(request.stream_context, .{ .diff = .{ .files = files.items } });
    return true;
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

test "Claude bridge stop monitor interrupts a blocked provider request" {
    const Capture = struct {
        stop_requested: std.atomic.Value(bool) = .init(false),
        terminate_count: std.atomic.Value(usize) = .init(0),

        fn shouldStop(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context orelse return true));
            return self.stop_requested.load(.acquire);
        }

        fn terminate(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.terminate_count.fetchAdd(1, .monotonic);
        }
    };

    var capture: Capture = .{};
    var monitor: BridgeStopMonitor = .{
        .request = .{
            .prompt = "blocked",
            .stream_context = &capture,
            .on_should_stop = Capture.shouldStop,
        },
        .target = &capture,
        .terminate = Capture.terminate,
    };
    try monitor.start();
    defer monitor.finish();

    capture.stop_requested.store(true, .release);
    var attempts: usize = 0;
    while (capture.terminate_count.load(.acquire) == 0 and attempts < 100) : (attempts += 1) {
        platform_runtime.sleepMillis(1);
    }

    try std.testing.expect(monitor.cancelled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), capture.terminate_count.load(.acquire));
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

test "Claude bridge diff events preserve file patches" {
    const payload =
        \\{"type":"diff_event","files":[{"path":"src/main.zig","additions":1,"deletions":1,"patch":"@@ -1 +1 @@\n-old\n+new"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: ClaudeTestDiffCapture = .{};

    try std.testing.expect(try emitBridgeDiffEvent(parsed.value, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = ClaudeTestDiffCapture.handle,
    }));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("src/main.zig", capture.path.?);
    try std.testing.expect(std.mem.indexOf(u8, capture.patch.?, "+new") != null);
}

test "Claude bridge MCP events preserve input and output" {
    const payload =
        \\{"type":"tool_call_event","call_id":"tool-1","title":"verde.list_processes","kind":"mcp","status":"completed","input":"{\"workspace\":\"current\"}","output":"{\"ok\":true}"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: ClaudeTestToolCapture = .{};

    try std.testing.expect(emitBridgeToolCallEvent(parsed.value, .{
        .prompt = "",
        .stream_context = &capture,
        .on_stream_event = ClaudeTestToolCapture.handle,
    }));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("tool-1", capture.call_id.?);
    try std.testing.expectEqualStrings("verde.list_processes", capture.title.?);
    try std.testing.expectEqual(provider_types.ToolCallKind.mcp, capture.kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.status.?);
    try std.testing.expectEqualStrings("{\"workspace\":\"current\"}", capture.input.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", capture.output.?);
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

test "Claude bridge keeps explicitly backgrounded tools alive for auto continuation" {
    const source = @embedFile("provider_bridge.ts");
    try std.testing.expect(std.mem.indexOf(u8, source, "item?.input?.run_in_background === true") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (alreadyBackgrounded) return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "prompt: promptChannel.messages()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "message?.type === \"steer_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "activeClaudePromptChannel?.push(prompt, \"next\")") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "query.close()"));
}

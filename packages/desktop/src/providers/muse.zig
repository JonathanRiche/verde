//! Muse Code provider harness backed by the stable Muse Session Protocol
//! exposed by `muse serve` over newline-delimited JSON-RPC.

const std = @import("std");
const acp = @import("acp.zig");
const platform_process = @import("../platform/process.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const platform_runtime = @import("platform_runtime");

const DEFAULT_EXECUTABLE = "muse";
const INSTALL_FALLBACK_RELATIVE = ".local/bin/muse";
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

var active_process_state: acp.ActiveProcessState = .{};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

pub const Config = struct {
    executable: []const u8 = DEFAULT_EXECUTABLE,
    cwd: ?[]const u8 = null,
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

    pub fn authState(self: *Client) !provider_types.AuthState {
        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();
        const executable = resolveMuseExecutableAlloc(self.allocator, &env_map, self.config.executable) catch |err| switch (err) {
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer self.allocator.free(executable);
        if (env_map.get("META_API_KEY")) |key| {
            if (std.mem.trim(u8, key, &std.ascii.whitespace).len > 0) return .signed_in;
        }

        const config_root = if (env_map.get("XDG_CONFIG_HOME")) |root|
            try self.allocator.dupe(u8, root)
        else if (env_map.get("HOME")) |home|
            try std.fs.path.join(self.allocator, &.{ home, ".config" })
        else
            return .unknown;
        defer self.allocator.free(config_root);
        const auth_path = try std.fs.path.join(self.allocator, &.{ config_root, "muse", "auth.json" });
        defer self.allocator.free(auth_path);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), auth_path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return .signed_out,
            else => return .unknown,
        };
        defer self.allocator.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return .unknown;
        defer parsed.deinit();
        const providers = acp.getObjectField(parsed.value, "providers") orelse return .signed_out;
        return if (acp.getObjectField(providers, "meta") != null) .signed_in else .signed_out;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var proc = try self.spawnServer(allocator, false);
        defer proc.deinit();
        try writeInitialize(&proc);
        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);
        try proc.writeLine(try makeSessionListRequestAlloc(allocator, 2, cwd));
        try proc.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            try failIfRpcError(parsed.value);
            if (acp.responseId(parsed.value) != 2) continue;
            const threads = try parseSessionListAlloc(allocator, parsed.value);
            proc.stop();
            return threads;
        }
        return error.MuseProtocolFailed;
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var proc = try self.spawnServer(allocator, false);
        defer proc.deinit();
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        try handshake(&proc, allocator, &reader);
        try proc.writeLine(try makeEmptyRequestAlloc(allocator, 2, "model/list"));
        try proc.closeStdin();
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            try failIfRpcError(parsed.value);
            if (acp.responseId(parsed.value) != 2) continue;
            const models = try parseModelListAlloc(allocator, parsed.value);
            proc.stop();
            return models;
        }
        return error.MuseProtocolFailed;
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var proc = try self.spawnServer(allocator, false);
        defer proc.deinit();
        try writeInitialize(&proc);
        try proc.writeLine(try makeSessionReadRequestAlloc(allocator, 2, thread_id));
        try proc.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            try failIfRpcError(parsed.value);
            if (acp.responseId(parsed.value) != 2) continue;
            const thread = try parseReadThreadAlloc(allocator, thread_id, parsed.value);
            proc.stop();
            return thread;
        }
        return error.MuseProtocolFailed;
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const disable_sandbox = (request.sandbox_mode orelse .workspace_write) == .danger_full_access;
        var proc = try self.spawnServer(allocator, disable_sandbox);
        defer proc.deinit();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        try handshake(&proc, allocator, &reader);

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);
        const setup_command_id = try uuidV7Alloc(allocator, proc.threaded.io());
        defer allocator.free(setup_command_id);
        const approval_mode = approvalModeForPolicy(request.approval_policy);
        if (request.thread_id) |thread_id| {
            try proc.writeLine(try makeSessionResumeRequestAlloc(allocator, 2, setup_command_id, thread_id));
        } else {
            // Muse 1.0.3 selects approval on the wire. 1.0.2 sealed it at
            // host start and rejected explicit modes; retry without the field.
            try proc.writeLine(try makeSessionStartRequestAlloc(
                allocator,
                2,
                setup_command_id,
                cwd,
                request.model orelse self.config.model,
                approval_mode,
            ));
        }

        const session_id = waitForSessionSetupAlloc(allocator, &reader, request.thread_id) catch |err| blk: {
            if (request.thread_id != null or err != error.MuseApprovalModeRejected) return err;
            const retry_command_id = try uuidV7Alloc(allocator, proc.threaded.io());
            defer allocator.free(retry_command_id);
            try proc.writeLine(try makeSessionStartRequestAlloc(
                allocator,
                2,
                retry_command_id,
                cwd,
                request.model orelse self.config.model,
                null,
            ));
            break :blk try waitForSessionSetupAlloc(allocator, &reader, request.thread_id);
        };
        errdefer allocator.free(session_id);
        if (request.on_thread_id) |callback| callback(request.stream_context, session_id);

        active_process_state.register(&proc.process, proc.process.child.stdin, session_id);
        if (request.thread_id != null) {
            if (request.model orelse self.config.model) |model| {
                if (!std.mem.eql(u8, model, "default")) {
                    const model_command_id = try uuidV7Alloc(allocator, proc.threaded.io());
                    defer allocator.free(model_command_id);
                    try proc.writeLine(try makeSessionSetModelRequestAlloc(allocator, 4, model_command_id, session_id, model));
                }
            }
        }
        const turn_command_id = try uuidV7Alloc(allocator, proc.threaded.io());
        defer allocator.free(turn_command_id);
        try proc.writeLine(try makeTurnStartRequestAlloc(allocator, 5, turn_command_id, session_id, request));

        var reply: std.ArrayList(u8) = .empty;
        errdefer reply.deinit(allocator);
        var agent_items: std.StringHashMapUnmanaged(void) = .empty;
        defer deinitStringSet(allocator, &agent_items);
        var streamed_items: std.StringHashMapUnmanaged(void) = .empty;
        defer deinitStringSet(allocator, &streamed_items);
        var turn_id_storage: ?[]u8 = null;
        defer if (turn_id_storage) |turn_id| allocator.free(turn_id);
        var cancel_sent = false;

        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();

            if (acp.responseId(parsed.value)) |id| {
                // Best-effort session/setModel (id 4) must not fail the turn.
                if (id == 4) continue;
                try failIfRpcError(parsed.value);
                if (id == 5) {
                    const result = acp.getObjectField(parsed.value, "result") orelse return error.MuseProtocolFailed;
                    const turn_id = acp.getOptionalObjectString(result, "turnId") orelse return error.MuseProtocolFailed;
                    turn_id_storage = try allocator.dupe(u8, turn_id);
                    if (request.on_turn_id) |callback| callback(request.stream_context, turn_id);
                }
                continue;
            }
            try failIfRpcError(parsed.value);

            const method = acp.getOptionalObjectString(parsed.value, "method") orelse continue;
            const params = acp.getObjectField(parsed.value, "params") orelse continue;
            if (std.mem.eql(u8, method, "turn/started")) {
                emitWorkingEvent(request);
            } else if (std.mem.eql(u8, method, "item/started")) {
                if (acp.getObjectField(params, "item")) |item| {
                    const item_id = acp.getOptionalObjectString(item, "itemId") orelse "";
                    const kind = acp.getOptionalObjectString(item, "kind") orelse "";
                    if (item_id.len > 0 and std.mem.eql(u8, kind, "agentMessage")) {
                        try agent_items.put(allocator, try allocator.dupe(u8, item_id), {});
                    }
                    emitItemEvent(request, item);
                }
            } else if (std.mem.eql(u8, method, "item/delta")) {
                const item_id = acp.getOptionalObjectString(params, "itemId") orelse "";
                const field = acp.getOptionalObjectString(params, "field") orelse "text";
                const delta = acp.getOptionalObjectString(params, "delta") orelse "";
                if (delta.len > 0 and agent_items.contains(item_id) and isTextField(field)) {
                    try reply.appendSlice(allocator, delta);
                    if (!streamed_items.contains(item_id)) try streamed_items.put(allocator, try allocator.dupe(u8, item_id), {});
                    if (request.on_stream_delta) |callback| callback(request.stream_context, delta);
                }
            } else if (std.mem.eql(u8, method, "item/updated") or std.mem.eql(u8, method, "item/completed")) {
                if (acp.getObjectField(params, "item")) |item| {
                    const item_id = acp.getOptionalObjectString(item, "itemId") orelse "";
                    const kind = acp.getOptionalObjectString(item, "kind") orelse "";
                    if (std.mem.eql(u8, method, "item/completed") and
                        std.mem.eql(u8, kind, "agentMessage") and
                        !streamed_items.contains(item_id))
                    {
                        const text = acp.getOptionalObjectString(item, "text") orelse "";
                        try reply.appendSlice(allocator, text);
                        if (request.on_stream_delta) |callback| callback(request.stream_context, text);
                    }
                    emitItemEvent(request, item);
                }
            } else if (std.mem.eql(u8, method, "approval/requested") or std.mem.eql(u8, method, "approval/updated")) {
                emitApprovalProgress(request, params);
                try decideApproval(allocator, &proc, request, params);
            } else if (std.mem.eql(u8, method, "session/todoListChanged")) {
                emitTodoEvent(request, params);
            } else if (std.mem.eql(u8, method, "userInput/requested")) {
                try cancelUserInput(allocator, &proc, params);
                if (request.on_failure) |callback| callback(request.stream_context, "Muse requested structured user input; continue in a new message.");
            } else if (std.mem.eql(u8, method, "turn/retryScheduled")) {
                const retry_turn_id = acp.getOptionalObjectString(params, "turnId") orelse "";
                if (turn_id_storage) |turn_id| {
                    if (!std.mem.eql(u8, retry_turn_id, turn_id)) continue;
                }
                const reason = acp.getOptionalObjectString(params, "reason") orelse "request failed";
                if (isNonRecoverableRetryReason(reason)) {
                    const message = "Muse rejected the model request. Check the Muse account/subscription and selected model.";
                    if (request.on_failure) |callback| callback(request.stream_context, message);
                    return error.MuseRequestRejected;
                }
                emitRetryEvent(request, params, reason);
            } else if (std.mem.eql(u8, method, "turn/completed")) {
                const completed_turn_id = acp.getOptionalObjectString(params, "turnId") orelse "";
                if (turn_id_storage) |turn_id| {
                    if (!std.mem.eql(u8, completed_turn_id, turn_id)) continue;
                }
                const terminal = acp.getOptionalObjectString(params, "terminal") orelse "failed";
                if (std.mem.eql(u8, terminal, "failed")) {
                    const error_value = acp.getObjectField(params, "error");
                    const message = if (error_value) |value| acp.getOptionalObjectString(value, "message") orelse "Muse turn failed" else "Muse turn failed";
                    if (request.on_failure) |callback| callback(request.stream_context, message);
                    return error.MuseTurnFailed;
                }
                if (std.mem.eql(u8, terminal, "cancelled")) return error.MuseTurnCancelled;
                proc.stop();
                return .{
                    .thread_id = session_id,
                    .reply_text = try reply.toOwnedSlice(allocator),
                };
            }

            if (!cancel_sent) {
                if (request.on_should_stop) |should_stop| {
                    if (should_stop(request.stream_context)) {
                        const command_id = try uuidV7Alloc(allocator, proc.threaded.io());
                        defer allocator.free(command_id);
                        try proc.writeLine(try makeTurnInterruptRequestAlloc(
                            allocator,
                            91,
                            command_id,
                            session_id,
                            turn_id_storage,
                        ));
                        cancel_sent = true;
                    }
                }
            }
        }
        return error.MuseProtocolFailed;
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const command_id = uuidV7Alloc(self.allocator, threaded.io()) catch null;
        defer if (command_id) |id| self.allocator.free(id);
        const line = if (command_id) |id|
            makeTurnInterruptRequestAlloc(self.allocator, 91, id, request.thread_id, request.turn_id) catch null
        else
            null;
        defer if (line) |payload| self.allocator.free(payload);

        active_process_state.lock();
        defer active_process_state.unlock();
        const child = active_process_state.child orelse return;
        const session_id = active_process_state.session_id orelse return;
        if (!std.mem.eql(u8, session_id, request.thread_id)) return;
        // Priority-lane interrupt first so Muse can leave an approval wait.
        // terminateTree is the fail-safe when stdin is already closed or the
        // host ignores the command while blocked.
        if (line) |payload| {
            if (active_process_state.stdin) |stdin| {
                acp.writeJsonLineToFile(self.allocator, stdin, payload) catch {};
            }
        }
        child.terminateTree();
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn spawnServer(self: *Client, allocator: std.mem.Allocator, disable_sandbox: bool) !acp.Process {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try resolveMuseExecutableAlloc(allocator, &env_map, self.config.executable);
        errdefer allocator.free(executable);
        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const argv_default = [_][]const u8{ executable, "serve", "--trust-workspace" };
        const argv_full_access = [_][]const u8{ executable, "serve", "--trust-workspace", "--disable-sandbox" };
        var child = try platform_process.spawn(allocator, threaded.io(), .{
            .argv = if (disable_sandbox) argv_full_access[0..] else argv_default[0..],
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

fn isNonRecoverableRetryReason(reason: []const u8) bool {
    // Muse normalizes HTTP 4xx failures (including the observed subscription
    // HTTP 402 response) to `client`. Repeating an unchanged client request
    // for several minutes cannot recover and makes native chat appear hung.
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, reason, &std.ascii.whitespace), "client");
}

fn emitRetryEvent(request: provider_types.SendPromptRequest, params: std.json.Value, reason: []const u8) void {
    const callback = request.on_stream_event orelse return;
    const next_attempt = acp.getOptionalObjectInteger(params, "nextAttempt") orelse 0;
    const max_attempts = acp.getOptionalObjectInteger(params, "maxAttempts") orelse 0;
    const delay_ms = acp.getOptionalObjectInteger(params, "retryDelayMs") orelse 0;
    var body_buffer: [256]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_buffer,
        "Attempt {d}/{d} in {d} ms: {s}",
        .{ next_attempt, max_attempts, delay_ms, reason },
    ) catch "Muse scheduled another model attempt.";
    callback(request.stream_context, .{ .message = .{ .title = "Muse retrying", .body = body } });
}

fn writeInitialize(proc: *acp.Process) !void {
    try proc.writeLine(try makeInitializeRequestAlloc(proc.allocator, 1));
    try proc.writeLine(try makeInitializedNotificationAlloc(proc.allocator));
}

fn handshake(proc: *acp.Process, allocator: std.mem.Allocator, reader: anytype) !void {
    try proc.writeLine(try makeInitializeRequestAlloc(proc.allocator, 1));
    try waitForResponseIdAlloc(allocator, reader, 1);
    try proc.writeLine(try makeInitializedNotificationAlloc(proc.allocator));
}

fn waitForResponseIdAlloc(allocator: std.mem.Allocator, reader: anytype, expected_id: i64) !void {
    while (try acp.takeLineAlloc(allocator, reader)) |raw_line| {
        defer allocator.free(raw_line);
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (acp.responseId(parsed.value) != expected_id) continue;
        try failIfRpcError(parsed.value);
        return;
    }
    return error.MuseProtocolFailed;
}

fn waitForSessionSetupAlloc(allocator: std.mem.Allocator, reader: anytype, existing_id: ?[]const u8) ![]u8 {
    while (try acp.takeLineAlloc(allocator, reader)) |raw_line| {
        defer allocator.free(raw_line);
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (acp.responseId(parsed.value) != 2) continue;
        failIfRpcError(parsed.value) catch |err| return err;
        if (existing_id) |session_id| return allocator.dupe(u8, session_id);
        const result = acp.getObjectField(parsed.value, "result") orelse return error.MuseProtocolFailed;
        const session = acp.getObjectField(result, "session") orelse return error.MuseProtocolFailed;
        const session_id = acp.getOptionalObjectString(session, "sessionId") orelse return error.MuseProtocolFailed;
        return allocator.dupe(u8, session_id);
    }
    return error.MuseProtocolFailed;
}

fn failIfRpcError(value: std.json.Value) !void {
    const error_value = acp.getObjectField(value, "error") orelse return;
    const message = acp.getOptionalObjectString(error_value, "message") orelse "";
    if (containsAuthHint(message)) return error.MuseSignedOut;
    if (isApprovalModeRejected(message)) return error.MuseApprovalModeRejected;
    return error.MuseProtocolFailed;
}

fn isApprovalModeRejected(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "approvalMode") != null or
        std.mem.indexOf(u8, message, "approval mode") != null or
        std.mem.indexOf(u8, message, "ApprovalMode") != null;
}

fn approvalModeForPolicy(policy: ?provider_types.ApprovalPolicy) ?[]const u8 {
    return switch (policy orelse .on_request) {
        .never => "allowAll",
        .on_request => "onRequest",
    };
}

fn isTextField(field: []const u8) bool {
    return std.mem.eql(u8, field, "text") or std.mem.startsWith(u8, field, "text.");
}

fn containsAuthHint(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "not logged in") != null or
        std.mem.indexOf(u8, message, "API key") != null or
        std.mem.indexOf(u8, message, "unauthorized") != null;
}

fn parseSessionListAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ChatThreadSummary {
    var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
    errdefer {
        for (threads.items) |thread| {
            allocator.free(thread.id);
            allocator.free(thread.title);
        }
        threads.deinit(allocator);
    }
    const result = acp.getObjectField(value, "result") orelse return error.MuseProtocolFailed;
    const sessions = acp.getObjectField(result, "sessions") orelse return error.MuseProtocolFailed;
    if (sessions != .array) return error.MuseProtocolFailed;
    for (sessions.array.items) |session| {
        const id = acp.getOptionalObjectString(session, "sessionId") orelse continue;
        try threads.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, id),
        });
    }
    return threads.toOwnedSlice(allocator);
}

fn parseModelListAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }
    const result = acp.getObjectField(value, "result") orelse return error.MuseProtocolFailed;
    const entries = acp.getObjectField(result, "models") orelse return error.MuseProtocolFailed;
    if (entries != .array) return error.MuseProtocolFailed;
    for (entries.array.items) |entry| {
        const model_id = acp.getOptionalObjectString(entry, "modelId") orelse continue;
        const label = acp.getOptionalObjectString(entry, "displayLabel") orelse model_id;
        const description = acp.getOptionalObjectString(entry, "description");
        try models.append(allocator, .{
            .provider_id = try allocator.dupe(u8, "muse"),
            .provider_name = try allocator.dupe(u8, "Muse"),
            .model_id = try allocator.dupe(u8, model_id),
            .model_name = try allocator.dupe(u8, label),
            .description = if (description) |text|
                if (text.len > 0) try allocator.dupe(u8, text) else null
            else
                null,
        });
    }
    return models.toOwnedSlice(allocator);
}

fn parseReadThreadAlloc(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
    value: std.json.Value,
) !provider_types.ReadThreadResult {
    var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
    errdefer {
        for (messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        messages.deinit(allocator);
    }
    const result = acp.getObjectField(value, "result") orelse return error.MuseProtocolFailed;
    const session = acp.getObjectField(result, "session") orelse return error.MuseProtocolFailed;
    const history = acp.getObjectField(result, "history") orelse return error.MuseProtocolFailed;
    const items_value = acp.getObjectField(history, "items") orelse .null;
    var first_prompt: ?[]const u8 = null;
    if (items_value == .array) {
        for (items_value.array.items) |item| {
            const kind = acp.getOptionalObjectString(item, "kind") orelse continue;
            const text = acp.getOptionalObjectString(item, "text") orelse continue;
            if (std.mem.eql(u8, kind, "userMessage")) {
                if (first_prompt == null and text.len > 0) first_prompt = text;
                try messages.append(allocator, .{
                    .role = .user,
                    .author = try allocator.dupe(u8, "You"),
                    .body = try allocator.dupe(u8, text),
                });
            } else if (std.mem.eql(u8, kind, "agentMessage")) {
                try messages.append(allocator, .{
                    .role = .assistant,
                    .author = try allocator.dupe(u8, "Muse"),
                    .body = try allocator.dupe(u8, text),
                });
            }
        }
    }
    const model_id = if (acp.getOptionalObjectString(session, "modelId")) |model| try allocator.dupe(u8, model) else null;
    errdefer if (model_id) |model| allocator.free(model);
    const title_source = first_prompt orelse thread_id;
    const title_len = @min(title_source.len, 80);
    return .{
        .thread_id = try allocator.dupe(u8, thread_id),
        .title = try allocator.dupe(u8, title_source[0..title_len]),
        .model_id = model_id,
        .messages = try messages.toOwnedSlice(allocator),
    };
}

fn emitWorkingEvent(request: provider_types.SendPromptRequest) void {
    const callback = request.on_stream_event orelse return;
    callback(request.stream_context, .{ .tool_call = .{
        .call_id = "muse-turn",
        .title = "",
        .kind = .think,
        .status = .in_progress,
    } });
}

fn emitItemEvent(request: provider_types.SendPromptRequest, item: std.json.Value) void {
    const callback = request.on_stream_event orelse return;
    const item_kind = acp.getOptionalObjectString(item, "kind") orelse "";
    if (std.mem.eql(u8, item_kind, "reasoning")) {
        callback(request.stream_context, .{ .tool_call = .{
            .call_id = acp.getOptionalObjectString(item, "itemId") orelse "muse-reasoning",
            .title = "Thinking",
            .kind = .think,
            .status = toolStatus(acp.getOptionalObjectString(item, "status") orelse "inProgress"),
            .output = acp.getOptionalObjectString(item, "text"),
        } });
        return;
    }
    if (std.mem.eql(u8, item_kind, "toolCall") or
        std.mem.eql(u8, item_kind, "userShell") or
        std.mem.eql(u8, item_kind, "subagent") or
        acp.getOptionalObjectString(item, "tool") != null)
    {
        emitToolEvent(request, item);
        return;
    }
    if (item_kind.len == 0 or std.mem.eql(u8, item_kind, "agentMessage") or std.mem.eql(u8, item_kind, "userMessage")) return;
    const fallback = acp.getOptionalObjectString(item, "fallbackText") orelse acp.getOptionalObjectString(item, "text") orelse return;
    if (fallback.len == 0) return;
    callback(request.stream_context, .{ .message = .{
        .title = if (item_kind.len > 0) item_kind else "Muse",
        .body = fallback,
    } });
}

fn emitToolEvent(request: provider_types.SendPromptRequest, item: std.json.Value) void {
    const callback = request.on_stream_event orelse return;
    const item_kind = acp.getOptionalObjectString(item, "kind") orelse "";
    const tool = acp.getOptionalObjectString(item, "tool") orelse if (std.mem.eql(u8, item_kind, "subagent")) "subagent" else "shell";
    const status = toolStatus(acp.getOptionalObjectString(item, "status") orelse "inProgress");
    const kind = if (std.mem.eql(u8, item_kind, "subagent")) .subagent else toolKind(tool);
    const is_shell = kind == .execute;
    const title = if (is_shell)
        if (status == .failed) "Command failed" else "Ran command"
    else if (std.mem.eql(u8, item_kind, "subagent"))
        "Subagent"
    else
        tool;
    callback(request.stream_context, .{ .tool_call = .{
        .call_id = acp.getOptionalObjectString(item, "callId") orelse acp.getOptionalObjectString(item, "itemId") orelse "muse-tool",
        .title = title,
        .kind = kind,
        .status = status,
        .input = acp.getOptionalObjectString(item, "args") orelse acp.getOptionalObjectString(item, "commandText"),
        .output = acp.getOptionalObjectString(item, "output") orelse acp.getOptionalObjectString(item, "visibleOutput"),
        .error_text = acp.getOptionalObjectString(item, "failureReason"),
    } });
}

fn emitApprovalProgress(request: provider_types.SendPromptRequest, params: std.json.Value) void {
    const callback = request.on_stream_event orelse return;
    const tool = acp.getOptionalObjectString(params, "toolName") orelse "tool";
    const kind = toolKind(tool);
    const title = if (kind == .execute) "Ran command" else tool;
    callback(request.stream_context, .{ .tool_call = .{
        .call_id = acp.getOptionalObjectString(params, "toolCallId") orelse
            acp.getOptionalObjectString(params, "itemId") orelse
            acp.getOptionalObjectString(params, "approvalId") orelse "muse-approval",
        .title = title,
        .kind = kind,
        .status = .in_progress,
        .input = acp.getOptionalObjectString(params, "rawArgs"),
    } });
}

fn emitTodoEvent(request: provider_types.SendPromptRequest, params: std.json.Value) void {
    const callback = request.on_stream_event orelse return;
    const items = acp.getObjectField(params, "items") orelse return;
    if (items != .array or items.array.items.len == 0) return;
    var body_buffer: [1024]u8 = undefined;
    var offset: usize = 0;
    for (items.array.items) |item| {
        const text = acp.getOptionalObjectString(item, "text") orelse continue;
        const status = acp.getOptionalObjectString(item, "status") orelse "pending";
        const mark: []const u8 = if (std.mem.eql(u8, status, "completed"))
            "x"
        else if (std.mem.eql(u8, status, "inProgress"))
            ">"
        else
            " ";
        const line = std.fmt.bufPrint(body_buffer[offset..], "- [{s}] {s}\n", .{ mark, text }) catch break;
        offset += line.len;
        if (offset + 32 >= body_buffer.len) break;
    }
    if (offset == 0) return;
    callback(request.stream_context, .{ .message = .{
        .title = "Todos",
        .body = body_buffer[0..offset],
    } });
}

fn toolKind(tool: []const u8) provider_types.ToolCallKind {
    if (containsIgnoreCase(tool, "shell") or containsIgnoreCase(tool, "bash") or containsIgnoreCase(tool, "command")) return .execute;
    if (containsIgnoreCase(tool, "read")) return .read;
    if (containsIgnoreCase(tool, "edit") or containsIgnoreCase(tool, "write")) return .edit;
    if (containsIgnoreCase(tool, "delete")) return .delete;
    if (containsIgnoreCase(tool, "move")) return .move;
    if (containsIgnoreCase(tool, "search") or containsIgnoreCase(tool, "find")) return .search;
    if (containsIgnoreCase(tool, "fetch") or containsIgnoreCase(tool, "web")) return .fetch;
    if (containsIgnoreCase(tool, "mcp")) return .mcp;
    return .other;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn toolStatus(status: []const u8) provider_types.ToolCallStatus {
    if (std.mem.eql(u8, status, "inProgress")) return .in_progress;
    if (std.mem.eql(u8, status, "completed")) return .completed;
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "rejected") or std.mem.eql(u8, status, "timedOut")) return .failed;
    if (std.mem.eql(u8, status, "cancelled")) return .cancelled;
    return .unknown;
}

fn decideApproval(
    allocator: std.mem.Allocator,
    proc: *acp.Process,
    request: provider_types.SendPromptRequest,
    params: std.json.Value,
) !void {
    const approval_id = acp.getOptionalObjectString(params, "approvalId") orelse return error.MuseProtocolFailed;
    const requirement = acp.getObjectField(params, "currentRequirementId") orelse return error.MuseProtocolFailed;
    const choices = acp.getObjectField(params, "availableChoices") orelse return error.MuseProtocolFailed;
    if (choices != .array) return error.MuseProtocolFailed;
    const tool_name = acp.getOptionalObjectString(params, "toolName") orelse "Muse tool";
    const raw_args = acp.getOptionalObjectString(params, "rawArgs") orelse "";
    const decision = if ((request.approval_policy orelse .on_request) == .never)
        provider_types.ApprovalDecision.approve
    else if (request.on_approval_request) |callback|
        callback(request.stream_context, .{ .call_id = approval_id, .title = tool_name, .body = raw_args })
    else
        provider_types.ApprovalDecision.deny;
    const choice_id = chooseApprovalChoice(choices.array.items, decision) orelse return error.MuseProtocolFailed;
    const command_id = try uuidV7Alloc(allocator, proc.threaded.io());
    defer allocator.free(command_id);
    try proc.writeLine(try makeApprovalDecisionRequestAlloc(allocator, 80, command_id, params, requirement, choice_id));
}

fn chooseApprovalChoice(choices: []const std.json.Value, decision: provider_types.ApprovalDecision) ?[]const u8 {
    for (choices) |choice| {
        const value = approvalDecisionName(choice) orelse continue;
        const scope = acp.getOptionalObjectString(choice, "scope") orelse "once";
        const matches = switch (decision) {
            .approve => std.mem.startsWith(u8, value, "approved") and std.mem.eql(u8, scope, "once"),
            .deny => std.mem.startsWith(u8, value, "denied") or std.mem.eql(u8, value, "abort"),
        };
        if (matches) return acp.getOptionalObjectString(choice, "choiceId");
    }
    for (choices) |choice| {
        const value = approvalDecisionName(choice) orelse continue;
        const matches = switch (decision) {
            .approve => std.mem.startsWith(u8, value, "approved"),
            .deny => std.mem.startsWith(u8, value, "denied") or std.mem.eql(u8, value, "abort"),
        };
        if (matches) return acp.getOptionalObjectString(choice, "choiceId");
    }
    return null;
}

fn approvalDecisionName(choice: std.json.Value) ?[]const u8 {
    const field = acp.getObjectField(choice, "decision") orelse return null;
    return switch (field) {
        .string => |text| text,
        .object => acp.getOptionalObjectString(field, "kind"),
        else => null,
    };
}

fn cancelUserInput(allocator: std.mem.Allocator, proc: *acp.Process, params: std.json.Value) !void {
    const request_id = acp.getOptionalObjectString(params, "userInputId") orelse return;
    const session_id = acp.getOptionalObjectString(params, "sessionId") orelse return;
    const command_id = try uuidV7Alloc(allocator, proc.threaded.io());
    defer allocator.free(command_id);
    try proc.writeLine(try makeUserInputCancelRequestAlloc(allocator, 81, command_id, session_id, request_id));
}

fn reasoningEffortName(effort: provider_types.ReasoningEffort) []const u8 {
    return switch (effort) {
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "ultra",
    };
}

fn makeInitializeRequestAlloc(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "initialize");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("clientInfo");
    try json.beginObject();
    try json.objectField("name");
    try json.write("verde");
    try json.objectField("version");
    try json.write("0.1");
    try json.endObject();
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeInitializedNotificationAlloc(allocator: std.mem.Allocator) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("method");
    try json.write("initialized");
    try json.objectField("params");
    try json.beginObject();
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeEmptyRequestAlloc(allocator: std.mem.Allocator, id: i64, method: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, method);
    try json.objectField("params");
    try json.beginObject();
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeSessionListRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "session/list");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("workspaceRoot");
    try json.write(cwd);
    try json.objectField("limit");
    try json.write(200);
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeSessionReadRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "session/read");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("sessionId");
    try json.write(session_id);
    try json.objectField("excludeItems");
    try json.write(false);
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeSessionStartRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    command_id: []const u8,
    cwd: []const u8,
    model: ?[]const u8,
    approval_mode: ?[]const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "session/start");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("workspaceRoot");
    try json.write(cwd);
    if (model) |model_id| {
        if (!std.mem.eql(u8, model_id, "default")) {
            try json.objectField("modelId");
            try json.write(model_id);
        }
    }
    if (approval_mode) |mode| {
        try json.objectField("approvalMode");
        try json.write(mode);
    }
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeSessionResumeRequestAlloc(allocator: std.mem.Allocator, id: i64, command_id: []const u8, session_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "session/resume");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("sessionId");
    try json.write(session_id);
    try json.objectField("excludeItems");
    try json.write(true);
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeSessionSetModelRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    command_id: []const u8,
    session_id: []const u8,
    model_id: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "session/setModel");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("sessionId");
    try json.write(session_id);
    try json.objectField("model");
    try json.beginObject();
    try json.objectField("modelId");
    try json.write(model_id);
    try json.endObject();
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeTurnStartRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    command_id: []const u8,
    session_id: []const u8,
    request: provider_types.SendPromptRequest,
) ![]u8 {
    const images = try collectImagesAlloc(allocator, request);
    defer allocator.free(images);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "turn/start");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("sessionId");
    try json.write(session_id);
    try json.objectField("input");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.write(request.prompt);
    try json.endObject();
    for (images) |image| try writeImagePart(allocator, &json, image);
    try json.endArray();
    if (request.reasoning_effort) |effort| {
        try json.objectField("reasoningEffort");
        try json.write(reasoningEffortName(effort));
    }
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeTurnInterruptRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    command_id: []const u8,
    session_id: []const u8,
    turn_id: ?[]const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "turn/interrupt");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("sessionId");
    try json.write(session_id);
    if (turn_id) |value| {
        try json.objectField("turnId");
        try json.write(value);
    }
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeApprovalDecisionRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    command_id: []const u8,
    params: std.json.Value,
    requirement: std.json.Value,
    choice_id: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "approval/decide");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("sessionId");
    try json.write(acp.getOptionalObjectString(params, "sessionId") orelse return error.MuseProtocolFailed);
    try json.objectField("approvalId");
    try json.write(acp.getOptionalObjectString(params, "approvalId") orelse return error.MuseProtocolFailed);
    try json.objectField("choiceId");
    try json.write(choice_id);
    try json.objectField("requirementId");
    try json.write(requirement);
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn makeUserInputCancelRequestAlloc(allocator: std.mem.Allocator, id: i64, command_id: []const u8, session_id: []const u8, request_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeRequestHead(&json, id, "userInput/cancel");
    try json.objectField("params");
    try json.beginObject();
    try json.objectField("commandId");
    try json.write(command_id);
    try json.objectField("sessionId");
    try json.write(session_id);
    try json.objectField("userInputId");
    try json.write(request_id);
    try json.endObject();
    try json.endObject();
    return writer.toOwnedSlice();
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var iterator = set.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
    set.deinit(allocator);
}

fn writeRequestHead(json: *std.json.Stringify, id: i64, method: []const u8) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("method");
    try json.write(method);
}

fn collectImagesAlloc(allocator: std.mem.Allocator, request: provider_types.SendPromptRequest) ![]provider_types.ImageAttachment {
    const add_legacy: usize = if (request.image) |legacy| if (containsImage(request.images, legacy.path)) 0 else 1 else 0;
    const images = try allocator.alloc(provider_types.ImageAttachment, request.images.len + add_legacy);
    @memcpy(images[0..request.images.len], request.images);
    if (request.image) |legacy| if (add_legacy == 1) {
        images[request.images.len] = legacy;
    };
    return images;
}

fn containsImage(images: []const provider_types.ImageAttachment, path: []const u8) bool {
    for (images) |image| if (std.mem.eql(u8, image.path, path)) return true;
    return false;
}

fn writeImagePart(allocator: std.mem.Allocator, json: *std.json.Stringify, image: provider_types.ImageAttachment) !void {
    const media_type = imageMimeType(image.path) orelse return error.MuseUnsupportedImageType;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), image.path, allocator, .limited(MAX_IMAGE_BYTES)) catch return error.MuseImageUnreadable;
    defer allocator.free(bytes);
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, size);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    try json.beginObject();
    try json.objectField("type");
    try json.write("image");
    try json.objectField("mediaType");
    try json.write(media_type);
    try json.objectField("base64Data");
    try json.write(encoded);
    try json.endObject();
}

fn imageMimeType(path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    return null;
}

fn uuidV7Alloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    const now_ms: u64 = @intCast(@max(platform_runtime.unixTimestampMs(), 0));
    bytes[0] = @truncate(now_ms >> 40);
    bytes[1] = @truncate(now_ms >> 32);
    bytes[2] = @truncate(now_ms >> 24);
    bytes[3] = @truncate(now_ms >> 16);
    bytes[4] = @truncate(now_ms >> 8);
    bytes[5] = @truncate(now_ms);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

fn resolveMuseExecutableAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    configured: []const u8,
) ![]u8 {
    const candidates = [_][]const u8{ configured, DEFAULT_EXECUTABLE };
    for (candidates, 0..) |candidate, index| {
        if (candidate.len == 0) continue;
        if (index == 1 and std.mem.eql(u8, candidate, candidates[0])) continue;
        return process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, candidate) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => continue,
            else => return err,
        };
    }
    if (env_map.get("HOME")) |home| {
        const fallback = try std.fs.path.join(allocator, &.{ home, INSTALL_FALLBACK_RELATIVE });
        defer allocator.free(fallback);
        return process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, fallback) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.FileNotFound,
            else => return err,
        };
    }
    return error.FileNotFound;
}

test "Muse model list parser preserves catalog ids and labels" {
    const payload =
        \\{"jsonrpc":"2.0","id":2,"result":{"models":[{"modelId":"muse-spark-1.3-contributor","displayLabel":"muse-spark-1.3-contributor","description":"Your content, including inter-session messages, may be used for product improvement.","providerId":"meta"},{"modelId":"muse-spark-1.3","displayLabel":"muse-spark-1.3","description":null,"providerId":"meta"}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const models = try parseModelListAlloc(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("muse", models[0].provider_id);
    try std.testing.expectEqualStrings("muse-spark-1.3-contributor", models[0].model_id);
    try std.testing.expectEqualStrings(
        "Your content, including inter-session messages, may be used for product improvement.",
        models[0].description.?,
    );
    try std.testing.expect(models[1].description == null);
}

test "Muse approval choice prefers once for approval" {
    const payload =
        \\[{"choiceId":"session","decision":"approvedForSession","label":"Allow session","scope":"session"},{"choiceId":"once","decision":"approved","label":"Allow once","scope":"once"},{"choiceId":"deny","decision":"denied","label":"Deny","scope":"once"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("once", chooseApprovalChoice(parsed.value.array.items, .approve).?);
    try std.testing.expectEqualStrings("deny", chooseApprovalChoice(parsed.value.array.items, .deny).?);
}

test "Muse session start omits approval mode when the host sealed it" {
    const payload = try makeSessionStartRequestAlloc(
        std.testing.allocator,
        2,
        "01991b47-0000-7000-8000-000000000001",
        "/tmp/workspace",
        "muse-spark-1.3-contributor",
        null,
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "approvalMode") == null);
}

test "Muse session start sends allowAll for full-access policy" {
    try std.testing.expectEqualStrings("allowAll", approvalModeForPolicy(.never).?);
    try std.testing.expectEqualStrings("onRequest", approvalModeForPolicy(.on_request).?);
    const payload = try makeSessionStartRequestAlloc(
        std.testing.allocator,
        2,
        "01991b47-0000-7000-8000-000000000001",
        "/tmp/workspace",
        "muse-spark-1.3-contributor",
        "allowAll",
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"approvalMode\":\"allowAll\"") != null);
}

test "Muse interrupt uses the priority lane" {
    const payload = try makeTurnInterruptRequestAlloc(
        std.testing.allocator,
        91,
        "01991b47-0000-7000-8000-000000000002",
        "session-1",
        "turn-1",
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"method\":\"turn/interrupt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"turnId\":\"turn-1\"") != null);
}

test "Muse approval choice reads object-shaped decisions" {
    const payload =
        \\[{"choiceId":"allow_once","decision":{"kind":"approved"},"label":"Allow once","scope":"once"},{"choiceId":"abort","decision":{"kind":"abort"},"label":"Reject","scope":"once"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("allow_once", chooseApprovalChoice(parsed.value.array.items, .approve).?);
    try std.testing.expectEqualStrings("abort", chooseApprovalChoice(parsed.value.array.items, .deny).?);
}

test "Muse approval-mode rejection is distinguished from protocol failure" {
    try std.testing.expect(isApprovalModeRejected("unknown field approvalMode"));
    try std.testing.expect(!isApprovalModeRejected("session not found"));
}

test "Muse image MIME types fail visibly for unsupported attachments" {
    try std.testing.expectEqualStrings("image/png", imageMimeType("shot.PNG").?);
    try std.testing.expectEqualStrings("image/jpeg", imageMimeType("photo.jpeg").?);
    try std.testing.expect(imageMimeType("notes.txt") == null);
}

test "Muse retry classification stops non-recoverable client failures" {
    try std.testing.expect(isNonRecoverableRetryReason("client"));
    try std.testing.expect(isNonRecoverableRetryReason(" CLIENT "));
    try std.testing.expect(!isNonRecoverableRetryReason("timeout"));
    try std.testing.expect(!isNonRecoverableRetryReason("server"));
}

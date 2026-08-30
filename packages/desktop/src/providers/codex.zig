//! Codex provider harness backed by `codex app-server`.

const std = @import("std");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const OVERLOAD_ERROR_CODE = -32001;
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const DEFAULT_WS_URL = "ws://127.0.0.1:4500";
// Codex can return saved thread history in one frame; match its own app-server client limit.
const MAX_WS_MESSAGE_BYTES = 128 * 1024 * 1024;
const MAX_HTTP_LINE_BYTES = 16 * 1024;
const MAX_RPC_RETRIES = 4;
const INTERRUPTIBLE_READ_POLL_MS = 250;
// Control-plane RPCs (initialize, thread/resume, turn/interrupt, thread/list,
// ...) answer immediately on a healthy app-server. Total socket silence beyond
// this window means the socket or the server is wedged (e.g. after a network
// drop), so fail the call instead of blocking the send thread forever.
const RPC_IDLE_TIMEOUT_MS: u64 = 30_000;
// An accepted turn/start emits thread events promptly. Silence after acceptance
// means the turn is queued behind a wedged turn or the server died; once the
// turn produces any event, long quiet stretches are legitimate again (model
// thinking, long tool runs) and no deadline applies.
const TURN_ACCEPT_IDLE_TIMEOUT_MS: u64 = 30_000;
// The websocket upgrade targets a local or forwarded port; a wedged server can
// accept the TCP connection and then never answer the upgrade request.
const HANDSHAKE_IDLE_TIMEOUT_MS: u64 = 10_000;

/// Controls how long a blocking websocket read may wait and which cancellation
/// signals it honors between poll intervals.
const ReadWait = struct {
    /// In-flight send whose stop callback is polled between reads.
    request: ?provider_types.SendPromptRequest = null,
    /// Fail with `error.CodexServerUnresponsive` after this much complete
    /// socket silence. Null waits indefinitely.
    idle_timeout_ms: ?u64 = null,
};

/// Default wait for fast control-plane RPC responses.
const RPC_WAIT: ReadWait = .{ .idle_timeout_ms = RPC_IDLE_TIMEOUT_MS };
/// Poll interval while waiting for `codex app-server` after spawn (100ms × attempts).
const MAX_CONNECT_WAIT_ATTEMPTS = 120;
const MAX_PROTOCOL_INIT_ATTEMPTS = 8;
const JSON_RPC_METHOD_NOT_FOUND: i64 = -32601;

const ServerRequestKind = enum {
    command_approval,
    file_change_approval,
    permissions_approval,
    mcp_elicitation,
    dynamic_tool,
    unsupported,
};

const CODEX_SLASH_COMMANDS = [_]provider_types.ProviderSlashCommand{
    .{
        .id = .usage,
        .name = "/usage",
        .summary = "Show Codex account and usage information.",
        .usage = "/usage",
        .requires_thread = false,
    },
    .{
        .id = .goal,
        .name = "/goal",
        .summary = "View, set, clear, or update the current Codex goal.",
        .usage = "/goal [status|clear|active|paused|blocked|complete|<objective>]",
        .requires_thread = true,
    },
    .{
        .id = .compact,
        .name = "/compact",
        .summary = "Compact the current Codex thread context.",
        .usage = "/compact",
        .requires_thread = true,
    },
    .{
        .id = .review,
        .name = "/review",
        .summary = "Start a Codex code review for changes, a base branch, a commit, or custom instructions.",
        .usage = "/review [changes|base <branch>|commit <sha> [title]|custom <instructions>]",
        .requires_thread = true,
    },
    .{
        .id = .shell,
        .name = "/shell",
        .summary = "Run an unsandboxed Codex shell command after explicit typed confirmation.",
        .usage = "/shell confirm <command>",
        .requires_thread = true,
        .destructive_or_sensitive = true,
    },
};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return CODEX_SLASH_COMMANDS[0..];
}

fn sleepMs(ms: u64) void {
    platform_runtime.sleepMillis(ms);
}

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

pub const Transport = enum(u8) {
    websocket,
    stdio_jsonl,
};

pub const Config = struct {
    executable: []const u8 = "codex",
    cwd: ?[]const u8 = null,
    transport: Transport = .websocket,
    websocket_url: ?[]const u8 = DEFAULT_WS_URL,
    launch_on_connect: bool = true,
};

const SharedServerState = struct {
    mutex: Mutex = .{},
    child: ?platform_process.OwnedChild = null,
    owns_child: bool = false,
};

var shared_server_state: SharedServerState = .{};

fn turnSteerRequestPayloadAlloc(
    allocator: std.mem.Allocator,
    id: u64,
    request: provider_types.SteerThreadRequest,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{},
    };

    try stringify.beginObject();
    try stringify.objectField("method");
    try stringify.write("turn/steer");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("threadId");
    try stringify.write(request.thread_id);
    try stringify.objectField("input");
    try stringify.beginArray();
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("text");
    try stringify.objectField("text");
    try stringify.write(request.prompt);
    try stringify.endObject();
    for (request.images) |image| {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("localImage");
        try stringify.objectField("path");
        try stringify.write(image.path);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.objectField("expectedTurnId");
    try stringify.write(request.turn_id);
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stream: ?std.Io.net.Stream = null,
    initialized: bool = false,
    next_request_id: u64 = 1,
    loaded_threads: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        runtime_log.diagnostic(
            "codex.Client.init begin transport={s} url_len={d} cwd={s} launch_on_connect={}",
            .{
                @tagName(config.transport),
                if (config.websocket_url) |url| url.len else 0,
                config.cwd orelse "(inherit)",
                config.launch_on_connect,
            },
        );
        var client: Client = .{
            .allocator = allocator,
            .config = config,
            .loaded_threads = std.StringHashMap(void).init(allocator),
        };
        errdefer client.deinit();
        client.ensureConnected() catch |err| {
            runtime_log.diagnostic("codex.Client.init ensureConnected failed: {s}", .{@errorName(err)});
            return err;
        };
        runtime_log.diagnostic("codex.Client.init connected initialized={}", .{client.initialized});
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.closeStream();
        self.freeLoadedThreads();
        self.loaded_threads.deinit();
    }

    pub fn authState(self: *Client) !provider_types.AuthState {
        try self.ensureConnected();

        const params = .{ .refreshToken = false };
        const payload = try self.callRpcForResultAlloc("account/read", params);
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        const account = getObjectField(parsed.value, "account") orelse return .signed_out;
        return switch (account) {
            .null => .signed_out,
            .object => .signed_in,
            else => .unknown,
        };
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        try self.ensureConnected();

        var threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty;
        defer threads.deinit(allocator);

        var cursor: ?[]u8 = null;
        defer if (cursor) |owned_cursor| self.allocator.free(owned_cursor);

        while (true) {
            const params = .{
                .limit = 100,
                .sortKey = "updated_at",
                .archived = false,
                .cwd = self.config.cwd,
                .cursor = cursor,
            };
            const payload = try self.callRpcForResultAlloc("thread/list", params);
            defer self.allocator.free(payload);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
            defer parsed.deinit();

            const threads_value = getObjectField(parsed.value, "data") orelse break;
            if (threads_value != .array) break;

            for (threads_value.array.items) |item| {
                if (item != .object) continue;
                const id_value = item.object.get("id") orelse continue;
                const id = stringValue(id_value) orelse continue;
                const title = getOptionalObjectString(item, "name") orelse
                    getOptionalObjectString(item, "title") orelse
                    getOptionalObjectString(item, "preview") orelse
                    id;

                try threads.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .title = try allocator.dupe(u8, title),
                });
            }

            if (cursor) |owned_cursor| {
                self.allocator.free(owned_cursor);
                cursor = null;
            }

            const next_cursor = getOptionalObjectString(parsed.value, "nextCursor") orelse break;
            cursor = try self.allocator.dupe(u8, next_cursor);
        }

        return threads.toOwnedSlice(allocator);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        _ = self;
        _ = allocator;
        return error.UnsupportedOperation;
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        try self.ensureConnected();

        const params = .{
            .threadId = thread_id,
            .includeTurns = true,
        };
        const payload = try self.callRpcForResultAlloc("thread/read", params);
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        const thread = getObjectField(parsed.value, "thread") orelse return error.MissingThreadId;
        const id = getOptionalObjectString(thread, "id") orelse return error.MissingThreadId;
        const title = getOptionalObjectString(thread, "name") orelse
            getOptionalObjectString(thread, "title") orelse
            getOptionalObjectString(thread, "preview") orelse
            id;

        var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
        defer {
            for (messages.items) |message| {
                allocator.free(message.author);
                allocator.free(message.body);
            }
            messages.deinit(allocator);
        }

        const turns_value = getObjectField(thread, "turns");
        if (turns_value != null and turns_value.? == .array) {
            for (turns_value.?.array.items) |turn| {
                const items_value = getObjectField(turn, "items") orelse continue;
                if (items_value != .array) continue;
                for (items_value.array.items) |item| {
                    try appendImportedMessagesForItem(allocator, item, &messages);
                }
            }
        }

        const owned_messages = try messages.toOwnedSlice(allocator);
        messages = .empty;

        return .{
            .thread_id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .updated_at = getOptionalObjectInteger(thread, "updatedAt"),
            .messages = owned_messages,
        };
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        runtime_log.diagnostic(
            "codex.sendPrompt begin thread_id_len={d} model_len={d} prompt_len={d}",
            .{ if (request.thread_id) |thread_id| thread_id.len else 0, if (request.model) |model| model.len else 0, request.prompt.len },
        );
        try self.ensureConnected();

        const thread_id = if (request.thread_id) |existing| blk: {
            runtime_log.diagnostic("codex.sendPrompt using existing thread_id_len={d}", .{existing.len});
            break :blk try allocator.dupe(u8, existing);
        } else blk: {
            runtime_log.diagnostic("codex.sendPrompt starting new thread", .{});
            break :blk try self.startThread(allocator, request);
        };
        errdefer allocator.free(thread_id);

        if (request.on_thread_id) |on_thread_id| {
            on_thread_id(request.stream_context, thread_id);
        }

        runtime_log.diagnostic("codex.sendPrompt ensuring thread loaded thread_id_len={d}", .{thread_id.len});
        try self.ensureThreadLoaded(thread_id, .{
            .request = request,
            .idle_timeout_ms = RPC_IDLE_TIMEOUT_MS,
        });

        runtime_log.diagnostic("codex.sendPrompt starting turn thread_id_len={d}", .{thread_id.len});
        const reply = try self.startTurnAndCollectReply(allocator, thread_id, request);
        errdefer allocator.free(reply);
        self.emitBackgroundTerminals(thread_id, request) catch |err| {
            // The endpoint is experimental; a missing/older server must not
            // turn an otherwise successful conversation turn into a failure.
            runtime_log.diagnostic("codex background terminal list unavailable: {s}", .{@errorName(err)});
        };
        runtime_log.diagnostic("codex.sendPrompt completed thread_id_len={d} reply_len={d}", .{ thread_id.len, reply.len });

        return .{
            .thread_id = thread_id,
            .reply_text = reply,
        };
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
            .usage => self.runUsageSlashCommand(allocator),
            .goal => self.runGoalSlashCommand(allocator, request),
            .compact => self.runCompactSlashCommand(allocator, request),
            .review => self.runReviewSlashCommand(allocator, request),
            .shell => self.runShellSlashCommand(allocator, request),
            .custom => error.UnsupportedOperation,
        };
    }

    fn runUsageSlashCommand(self: *Client, allocator: std.mem.Allocator) !provider_types.RunSlashCommandResult {
        try self.ensureConnected();

        const payload = try self.callRpcForResultAlloc("account/usage/read", @as(?u8, null));
        defer self.allocator.free(payload);
        const maybe_rate_payload = self.callRpcForResultAlloc("account/rateLimits/read", @as(?u8, null)) catch |err| blk: {
            runtime_log.diagnostic("codex.runUsageSlashCommand rate limits unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (maybe_rate_payload) |rate_payload| self.allocator.free(rate_payload);

        return self.slashUsageResultAlloc(allocator, payload, maybe_rate_payload) catch |err| switch (err) {
            // If Codex changes the shape, keep the command useful instead of
            // failing the GUI action just because the prettier formatter broke.
            error.InvalidUsagePayload => self.slashJsonResultAlloc(allocator, "Usage", "Codex usage loaded.", payload),
            else => return err,
        };
    }

    fn runGoalSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const thread_id = request.thread_id orelse return error.MissingThreadId;
        try self.ensureConnected();
        try self.ensureThreadLoaded(thread_id, RPC_WAIT);

        const args = std.mem.trim(u8, request.args, " \t\r\n");
        if (args.len == 0 or std.mem.eql(u8, args, "status")) {
            const payload = try self.callRpcForResultAlloc("thread/goal/get", .{ .threadId = thread_id });
            defer self.allocator.free(payload);
            return self.slashGoalResultAlloc(allocator, "Codex goal loaded.", payload);
        }

        if (std.mem.eql(u8, args, "clear")) {
            const payload = try self.callRpcForResultAlloc("thread/goal/clear", .{ .threadId = thread_id });
            defer self.allocator.free(payload);
            return self.slashGoalResultAlloc(allocator, "Codex goal cleared.", payload);
        }

        if (isGoalStatus(args)) {
            const payload = try self.callRpcForResultAlloc("thread/goal/set", .{
                .threadId = thread_id,
                .status = args,
            });
            defer self.allocator.free(payload);

            const notice = try std.fmt.allocPrint(allocator, "Codex goal marked {s}.", .{args});
            defer allocator.free(notice);
            return self.slashGoalResultAlloc(allocator, notice, payload);
        }

        const payload = try self.callRpcForResultAlloc("thread/goal/set", .{
            .threadId = thread_id,
            .objective = args,
        });
        defer self.allocator.free(payload);
        return self.slashGoalResultAlloc(allocator, "Codex goal updated.", payload);
    }

    fn runCompactSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const thread_id = request.thread_id orelse return error.MissingThreadId;
        try self.ensureConnected();
        try self.ensureThreadLoaded(thread_id, RPC_WAIT);

        try self.callThreadCompactAndWait(thread_id);

        return self.slashTextResultAlloc(
            allocator,
            "Compact",
            "Compacted thread context.",
            "Thread context compacted.\n\nFuture Codex turns will continue from the compacted conversation summary.",
        );
    }

    fn runReviewSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const thread_id = request.thread_id orelse return error.MissingThreadId;
        try self.ensureConnected();
        try self.ensureThreadLoaded(thread_id, RPC_WAIT);

        const review_text = try self.callReviewStartAndWait(allocator, thread_id, request.args);
        defer allocator.free(review_text);
        const body = if (std.mem.trim(u8, review_text, &std.ascii.whitespace).len == 0)
            "Codex review completed with no findings."
        else
            review_text;

        return self.slashTextResultAlloc(
            allocator,
            "Review",
            "Codex review completed.",
            body,
        );
    }

    fn runShellSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const thread_id = request.thread_id orelse return error.MissingThreadId;
        const command = confirmedShellCommand(request.args) orelse {
            return self.slashTextResultAlloc(
                allocator,
                "Shell",
                "Shell command was not run.",
                "Codex shell commands run unsandboxed with full access. To confirm, use:\n\n/shell confirm <command>",
            );
        };
        try self.ensureConnected();
        try self.ensureThreadLoaded(thread_id, RPC_WAIT);

        const output = try self.callShellCommandAndWait(allocator, thread_id, command);
        defer allocator.free(output);
        const body = try formatShellCommandResultAlloc(allocator, command, output);
        defer allocator.free(body);

        return self.slashTextResultAlloc(
            allocator,
            "Shell",
            "Codex shell command completed.",
            body,
        );
    }

    fn slashTextResultAlloc(
        self: *Client,
        allocator: std.mem.Allocator,
        title: []const u8,
        notice: []const u8,
        body_text: []const u8,
    ) !provider_types.RunSlashCommandResult {
        _ = self;
        const owned_notice = try allocator.dupe(u8, notice);
        errdefer allocator.free(owned_notice);
        const owned_title = try allocator.dupe(u8, title);
        errdefer allocator.free(owned_title);
        const body = try allocator.dupe(u8, body_text);
        errdefer allocator.free(body);

        return .{
            .handled = true,
            .notice = owned_notice,
            .transcript_title = owned_title,
            .transcript_body = body,
        };
    }

    fn slashJsonResultAlloc(
        self: *Client,
        allocator: std.mem.Allocator,
        title: []const u8,
        notice: []const u8,
        payload: []const u8,
    ) !provider_types.RunSlashCommandResult {
        _ = self;
        const owned_notice = try allocator.dupe(u8, notice);
        errdefer allocator.free(owned_notice);
        const owned_title = try allocator.dupe(u8, title);
        errdefer allocator.free(owned_title);
        const body = try std.fmt.allocPrint(allocator, "```json\n{s}\n```", .{payload});
        errdefer allocator.free(body);

        return .{
            .handled = true,
            .notice = owned_notice,
            .transcript_title = owned_title,
            .transcript_body = body,
        };
    }

    fn slashGoalResultAlloc(
        self: *Client,
        allocator: std.mem.Allocator,
        notice: []const u8,
        payload: []const u8,
    ) !provider_types.RunSlashCommandResult {
        _ = self;

        const body = formatGoalSummaryAlloc(allocator, payload) catch |err| switch (err) {
            error.InvalidGoalPayload => try std.fmt.allocPrint(allocator, "```json\n{s}\n```", .{payload}),
            else => return err,
        };
        errdefer allocator.free(body);
        const owned_notice = try allocator.dupe(u8, notice);
        errdefer allocator.free(owned_notice);
        const owned_title = try allocator.dupe(u8, "Goal");
        errdefer allocator.free(owned_title);

        return .{
            .handled = true,
            .notice = owned_notice,
            .transcript_title = owned_title,
            .transcript_body = body,
        };
    }

    fn slashUsageResultAlloc(
        self: *Client,
        allocator: std.mem.Allocator,
        payload: []const u8,
        maybe_rate_payload: ?[]const u8,
    ) !provider_types.RunSlashCommandResult {
        _ = self;

        const body = try formatUsageSummaryAlloc(allocator, payload, maybe_rate_payload);
        errdefer allocator.free(body);
        const owned_notice = try allocator.dupe(u8, "Codex usage loaded.");
        errdefer allocator.free(owned_notice);
        const owned_title = try allocator.dupe(u8, "Usage");
        errdefer allocator.free(owned_title);

        return .{
            .handled = true,
            .notice = owned_notice,
            .transcript_title = owned_title,
            .transcript_body = body,
        };
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        try self.ensureConnected();

        if (request.turn_id) |turn_id| {
            const payload = self.callRpcForResultAlloc("turn/interrupt", .{
                .threadId = request.thread_id,
                .turnId = turn_id,
            }) catch |err| switch (err) {
                error.CodexRpcFailed => blk: {
                    break :blk try self.callRpcForResultAlloc("turn/interrupt", .{
                        .threadId = request.thread_id,
                    });
                },
                else => return err,
            };
            self.allocator.free(payload);
            return;
        }

        const payload = try self.callRpcForResultAlloc("turn/interrupt", .{
            .threadId = request.thread_id,
        });
        self.allocator.free(payload);
    }

    /// Terminates one retained terminal without interrupting its owning turn.
    pub fn terminateBackgroundTerminal(self: *Client, thread_id: []const u8, process_id: []const u8) !void {
        try self.ensureConnected();
        try self.ensureThreadLoaded(thread_id, RPC_WAIT);
        const payload = try self.callRpcForResultAlloc("thread/backgroundTerminals/terminate", .{
            .threadId = thread_id,
            .processId = process_id,
        });
        defer self.allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        const terminated = getObjectField(parsed.value, "terminated") orelse return error.InvalidBackgroundTerminalResponse;
        if (terminated != .bool or !terminated.bool) return error.BackgroundTerminalNotTerminated;
    }

    /// Reports whether one retained terminal is still present in the provider.
    pub fn backgroundTerminalIsRunning(self: *Client, thread_id: []const u8, process_id: []const u8) !bool {
        try self.ensureConnected();
        // Polling uses a fresh app-server connection. Thread-scoped RPCs are
        // rejected until that connection resumes the persisted thread.
        try self.ensureThreadLoaded(thread_id, RPC_WAIT);
        const payload = try self.callRpcForResultAlloc("thread/backgroundTerminals/list", .{ .threadId = thread_id });
        defer self.allocator.free(payload);
        return backgroundTerminalListContainsProcess(self.allocator, payload, process_id);
    }

    fn emitBackgroundTerminals(self: *Client, thread_id: []const u8, request: provider_types.SendPromptRequest) !void {
        const on_stream_event = request.on_stream_event orelse return;
        var identities: std.Io.Writer.Allocating = .init(self.allocator);
        defer identities.deinit();
        try identities.writer.print("Provider thread ID: {s}", .{thread_id});
        const payload = try self.callRpcForResultAlloc("thread/backgroundTerminals/list", .{ .threadId = thread_id });
        defer self.allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        const data = getObjectField(parsed.value, "data") orelse return error.InvalidBackgroundTerminalResponse;
        if (data != .array) return error.InvalidBackgroundTerminalResponse;
        for (data.array.items) |item| {
            const item_id = getOptionalObjectString(item, "itemId") orelse continue;
            const process_id = getOptionalObjectString(item, "processId") orelse continue;
            const command = getOptionalObjectString(item, "command") orelse continue;
            const cwd = getOptionalObjectString(item, "cwd") orelse "";
            const body = try std.fmt.allocPrint(self.allocator, "{s}\n\nProvider: codex\nCodex item ID: {s}\nProcess ID: {s}\nProvider thread ID: {s}\nCWD: {s}", .{ command, item_id, process_id, thread_id, cwd });
            defer self.allocator.free(body);
            on_stream_event(request.stream_context, .{ .message = .{ .title = "Background command", .body = body } });
            try identities.writer.print("\nCodex item ID: {s}", .{item_id});
        }
        const marker = try identities.toOwnedSlice();
        defer self.allocator.free(marker);
        on_stream_event(request.stream_context, .{ .message = .{ .title = "__verde_codex_background_snapshot", .body = marker } });
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        try self.ensureConnected();
        try self.ensureThreadLoaded(request.thread_id, RPC_WAIT);

        const payload = try self.callTurnSteerForResultAlloc(request);
        defer self.allocator.free(payload);
    }

    fn ensureConnected(self: *Client) !void {
        if (self.stream == null) {
            runtime_log.diagnostic("codex.ensureConnected stream=null transport={s}", .{@tagName(self.config.transport)});
            switch (self.config.transport) {
                .websocket => self.connectWebSocket() catch |err| {
                    runtime_log.diagnostic("codex.ensureConnected connectWebSocket failed: {s}", .{@errorName(err)});
                    return err;
                },
                .stdio_jsonl => return error.TransportNotImplemented,
            }
        }

        if (!self.initialized) {
            runtime_log.diagnostic("codex.ensureConnected initializing protocol", .{});
            self.initializeProtocol() catch |err| {
                runtime_log.diagnostic("codex.ensureConnected initializeProtocol failed: {s}", .{@errorName(err)});
                return err;
            };
            runtime_log.diagnostic("codex.ensureConnected protocol initialized", .{});
        }
    }

    fn closeStream(self: *Client) void {
        if (self.stream) |stream| {
            self.writeCloseFrame(stream) catch {};
            var threaded = std.Io.Threaded.init_single_threaded;
            stream.close(threaded.io());
            self.stream = null;
        }

        self.initialized = false;
    }

    fn connectWebSocket(self: *Client) !void {
        const raw_url = self.effectiveWebSocketUrl() orelse return error.MissingWebSocketUrl;
        runtime_log.diagnostic("codex.connectWebSocket begin url_len={d}", .{raw_url.len});
        const uri = std.Uri.parse(raw_url) catch |err| {
            runtime_log.diagnostic("codex.connectWebSocket Uri.parse failed: {s}", .{@errorName(err)});
            return err;
        };
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buffer) catch |err| {
            runtime_log.diagnostic("codex.connectWebSocket getHost failed: {s}", .{@errorName(err)});
            return err;
        };
        const host = host_name.bytes;

        if (!std.ascii.eqlIgnoreCase(uri.scheme, "ws")) {
            return error.UnsupportedWebSocketScheme;
        }

        const port = uri.port orelse 80;
        runtime_log.diagnostic("codex.connectWebSocket target host_len={d} port={d}", .{ host.len, port });
        if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
            runtime_log.diagnostic("codex.connectWebSocket connected existing server", .{});
            self.stream = stream;
            return;
        }

        if (!self.config.launch_on_connect) {
            return error.NotConnected;
        }

        shared_server_state.mutex.lock();
        defer shared_server_state.mutex.unlock();
        runtime_log.diagnostic("codex.connectWebSocket acquired shared server lock owns_child={} has_child={}", .{
            shared_server_state.owns_child,
            shared_server_state.child != null,
        });

        if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
            runtime_log.diagnostic("codex.connectWebSocket connected after lock", .{});
            self.stream = stream;
            return;
        }

        if (shared_server_state.owns_child) {
            if (try self.waitForWebSocket(uri, host, port, MAX_CONNECT_WAIT_ATTEMPTS)) |stream| {
                self.stream = stream;
                return;
            }
            stopOwnedServerLocked();
            if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
                self.stream = stream;
                return;
            }
        }

        self.spawnWebSocketServer(raw_url) catch |err| {
            runtime_log.diagnostic("codex.connectWebSocket spawnWebSocketServer failed: {s}", .{@errorName(err)});
            return err;
        };

        // Brief pause so the child can bind and accept before we hammer the port.
        sleepMs(80);

        if (try self.waitForWebSocket(uri, host, port, MAX_CONNECT_WAIT_ATTEMPTS)) |stream| {
            runtime_log.diagnostic("codex.connectWebSocket connected after spawn", .{});
            self.stream = stream;
            return;
        }

        stopOwnedServerLocked();
        if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
            self.stream = stream;
            return;
        }

        return error.NotConnected;
    }

    fn effectiveWebSocketUrl(self: *const Client) ?[]const u8 {
        return self.config.websocket_url;
    }

    fn spawnWebSocketServer(self: *Client, url: []const u8) !void {
        if (shared_server_state.child != null) return;

        runtime_log.diagnostic("codex.spawnWebSocketServer begin url_len={d}", .{url.len});
        var env_map = process_env.buildAugmentedEnvMap(self.allocator) catch |err| {
            runtime_log.diagnostic("codex.spawnWebSocketServer buildAugmentedEnvMap failed: {s}", .{@errorName(err)});
            return err;
        };
        defer env_map.deinit();

        const executable = process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, self.config.executable) catch |err| {
            runtime_log.diagnostic("codex.spawnWebSocketServer resolve executable failed executable={s}: {s}", .{ self.config.executable, @errorName(err) });
            return err;
        };
        defer self.allocator.free(executable);
        runtime_log.diagnostic("codex.spawnWebSocketServer executable={s}", .{executable});

        var argv = [_][]const u8{
            executable,
            "app-server",
            "--listen",
            url,
        };

        var threaded_spawn = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded_spawn.deinit();
        const child = platform_process.spawn(self.allocator, threaded_spawn.io(), .{
            .argv = argv[0..],
            .stdin = .ignore,
            // codex prints a startup banner. A detached daemon may have dead
            // inherited pipes, so route app-server stdio to the null device.
            .stdout = .ignore,
            .stderr = .ignore,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        }) catch |err| {
            runtime_log.diagnostic("codex.spawnWebSocketServer process.spawn failed: {s}", .{@errorName(err)});
            return err;
        };

        runtime_log.diagnostic("codex.spawnWebSocketServer started pid={d}", .{child.processId() orelse 0});
        shared_server_state.child = child;
        shared_server_state.owns_child = true;
    }

    fn tryConnectWebSocket(
        self: *Client,
        uri: std.Uri,
        host: []const u8,
        port: u16,
    ) !?std.Io.net.Stream {
        var threaded = std.Io.Threaded.init_single_threaded;
        const address = std.Io.net.IpAddress.parse(host, port) catch
            std.Io.net.IpAddress.resolve(threaded.io(), host, port) catch return null;
        const stream = address.connect(threaded.io(), .{ .mode = .stream }) catch return null;
        errdefer stream.close(threaded.io());

        self.performWebSocketHandshake(stream, uri, host, port) catch |err| {
            runtime_log.diagnostic("codex.tryConnectWebSocket handshake not ready: {s}", .{@errorName(err)});
            stream.close(threaded.io());
            return null;
        };
        return stream;
    }

    fn waitForWebSocket(
        self: *Client,
        uri: std.Uri,
        host: []const u8,
        port: u16,
        attempts: usize,
    ) !?std.Io.net.Stream {
        var attempt: usize = 0;
        while (attempt < attempts) : (attempt += 1) {
            if (try self.tryConnectWebSocket(uri, host, port)) |stream| {
                return stream;
            }
            sleepMs(100);
        }
        return null;
    }

    fn performWebSocketHandshake(
        self: *Client,
        stream: std.Io.net.Stream,
        uri: std.Uri,
        host: []const u8,
        port: u16,
    ) !void {
        var nonce: [16]u8 = undefined;
        var threaded = std.Io.Threaded.init_single_threaded;
        try std.Io.randomSecure(threaded.io(), &nonce);

        const key = try encodeBase64Alloc(self.allocator, &nonce);
        defer self.allocator.free(key);

        const accept_expected = try computeAcceptKeyAlloc(self.allocator, key);
        defer self.allocator.free(accept_expected);

        const host_header = if (port == 80)
            try self.allocator.dupe(u8, host)
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
        defer self.allocator.free(host_header);

        const request_target = try buildRequestTargetAlloc(self.allocator, uri);
        defer self.allocator.free(request_target);

        const request = try std.fmt.allocPrint(
            self.allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ request_target, host_header, key },
        );
        defer self.allocator.free(request);

        try streamWriteAll(stream, request);

        const status_line = try readHttpLineAlloc(self.allocator, stream);
        defer self.allocator.free(status_line);
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) {
            return error.WebSocketUpgradeRejected;
        }

        var accept_header: ?[]u8 = null;
        defer if (accept_header) |line| self.allocator.free(line);

        while (true) {
            const line = try readHttpLineAlloc(self.allocator, stream);
            if (line.len == 0) {
                self.allocator.free(line);
                break;
            }

            if (std.ascii.startsWithIgnoreCase(line, "sec-websocket-accept:")) {
                accept_header = line;
            } else {
                self.allocator.free(line);
            }
        }

        const accept_line = accept_header orelse return error.MissingWebSocketAccept;
        const colon_index = std.mem.indexOfScalar(u8, accept_line, ':') orelse return error.MissingWebSocketAccept;
        const accept_value = std.mem.trim(u8, accept_line[colon_index + 1 ..], " \t");
        if (!std.mem.eql(u8, accept_value, accept_expected)) {
            return error.WebSocketAcceptMismatch;
        }
    }

    fn initializeProtocol(self: *Client) !void {
        const params = .{
            .clientInfo = .{
                .name = "editorts_native",
                .title = "EditorTs Native",
                .version = "0.1.0",
            },
            .capabilities = .{
                .experimentalApi = true,
            },
        };

        var attempt: usize = 0;
        while (attempt < MAX_PROTOCOL_INIT_ATTEMPTS) : (attempt += 1) {
            const payload = self.callRpcForResultAlloc("initialize", params) catch |err| switch (err) {
                error.CodexRpcFailed, error.ServerOverloaded => {
                    if (attempt + 1 >= MAX_PROTOCOL_INIT_ATTEMPTS) return err;
                    runtime_log.diagnostic("codex.initializeProtocol retry attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
                    sleepMs(120 + @as(u64, attempt) * 80);
                    continue;
                },
                else => return err,
            };
            defer self.allocator.free(payload);

            try self.sendNotification("initialized", .{});
            self.initialized = true;
            return;
        }
        return error.CodexRpcFailed;
    }

    fn startThread(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) ![]u8 {
        const payload = try self.callThreadStartAlloc(request);
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        const thread = getObjectField(parsed.value, "thread") orelse return error.MissingThreadId;
        const id = getOptionalObjectString(thread, "id") orelse return error.MissingThreadId;
        try self.rememberLoadedThread(id);
        return allocator.dupe(u8, id);
    }

    fn callThreadStartAlloc(self: *Client, request: provider_types.SendPromptRequest) ![]u8 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        var stringify: std.json.Stringify = .{
            .writer = &writer.writer,
            .options = .{},
        };

        try stringify.beginObject();
        try stringify.objectField("method");
        try stringify.write("thread/start");
        try stringify.objectField("id");
        try stringify.write(id);
        try stringify.objectField("params");
        try stringify.beginObject();
        if (request.cwd) |working_dir| {
            try stringify.objectField("cwd");
            try stringify.write(working_dir);
        }
        if (request.model) |selected_model| {
            try stringify.objectField("model");
            try stringify.write(selected_model);
        }
        if (request.service_tier) |service_tier| {
            try stringify.objectField("serviceTier");
            try stringify.write(service_tier);
        }
        if (request.approval_policy) |approval_policy| {
            try stringify.objectField("approvalPolicy");
            try stringify.write(approvalPolicyString(approval_policy));
        }
        if (request.sandbox_mode) |sandbox_mode| {
            try stringify.objectField("sandbox");
            try stringify.write(sandboxModeString(sandbox_mode));
        }
        try stringify.objectField("experimentalRawEvents");
        try stringify.write(false);
        try stringify.objectField("persistExtendedHistory");
        try stringify.write(true);
        try stringify.endObject();
        try stringify.endObject();

        const payload = try writer.toOwnedSlice();
        defer self.allocator.free(payload);
        runtime_log.diagnostic("Codex RPC thread/start id={d} payload_len={d}", .{ id, payload.len });
        try self.writeTextMessage(payload);
        const result = try self.awaitResultPayloadAlloc(id, .{
            .request = request,
            .idle_timeout_ms = RPC_IDLE_TIMEOUT_MS,
        });
        runtime_log.diagnostic("Codex RPC thread/start id={d} result_len={d}", .{ id, result.len });
        return result;
    }

    fn ensureThreadLoaded(self: *Client, thread_id: []const u8, wait: ReadWait) !void {
        if (self.loaded_threads.contains(thread_id)) return;

        const params = .{
            .threadId = thread_id,
            // Verde already owns the visible transcript, so avoid returning the
            // potentially very large saved history merely to resume the thread.
            .excludeTurns = true,
        };
        const payload = try self.callRpcForResultAllocWait("thread/resume", params, wait);
        defer self.allocator.free(payload);

        // Codex persists a thread's MCP policy snapshot. Refresh after resume
        // so chats created before Verde's managed approval mode inherit it.
        const reload_payload = self.callRpcForResultAllocWait(
            "config/mcpServer/reload",
            @as(?u8, null),
            wait,
        ) catch |err| switch (err) {
            // Older app-server versions do not expose this RPC. Resuming the
            // thread remains useful there, even though its MCP snapshot stays.
            error.CodexRpcFailed => {
                runtime_log.diagnostic("codex MCP config refresh after resume unavailable: {s}", .{@errorName(err)});
                try self.rememberLoadedThread(thread_id);
                return;
            },
            else => return err,
        };
        defer self.allocator.free(reload_payload);

        try self.rememberLoadedThread(thread_id);
    }

    fn rememberLoadedThread(self: *Client, thread_id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, thread_id);
        errdefer self.allocator.free(owned);

        const gop = try self.loaded_threads.getOrPut(owned);
        if (gop.found_existing) {
            self.allocator.free(owned);
            return;
        }
        gop.value_ptr.* = {};
    }

    fn startTurnAndCollectReply(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
        request: provider_types.SendPromptRequest,
    ) ![]u8 {
        const request_id = try self.sendTurnStartRequest(thread_id, request);
        var turn_started = false;
        var started_turn_id: ?[]u8 = null;
        defer if (started_turn_id) |turn_id| allocator.free(turn_id);
        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(allocator);

        // True once the accepted turn has produced any message after its
        // turn/start response; before that, total socket silence can only mean
        // a dead connection or a turn wedged behind stale app-server state.
        var saw_turn_activity = false;
        var saw_mcp_tool_call = false;

        while (true) {
            const wait: ReadWait = .{
                .request = request,
                .idle_timeout_ms = if (saw_turn_activity) null else TURN_ACCEPT_IDLE_TIMEOUT_MS,
            };
            const message = self.readTextMessageAllocInterruptible(self.allocator, wait) catch |err| {
                if (err == error.CodexTurnInterrupted or err == error.CodexServerUnresponsive) {
                    // The app-server keeps running a turn after its client
                    // disconnects. Do not await this response: cancelling the
                    // in-flight read may have discarded bytes from that stream.
                    _ = self.sendRequest("turn/interrupt", .{
                        .threadId = thread_id,
                    }) catch |interrupt_err| {
                        runtime_log.diagnostic("failed to interrupt stopped Codex turn: {s}", .{@errorName(interrupt_err)});
                    };
                }
                return err;
            };
            defer self.allocator.free(message);
            // Only messages read after the turn/start response processed in a
            // prior iteration count as turn activity.
            if (turn_started) saw_turn_activity = true;

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (try self.maybeHandleServerRequest(root, request)) {
                continue;
            }
            if (try self.maybeHandleMatchingResponse(root, request_id)) {
                turn_started = true;
                if (started_turn_id == null) {
                    if (extractTurnIdFromStartResponse(root)) |turn_id| {
                        started_turn_id = try allocator.dupe(u8, turn_id);
                        if (request.on_turn_id) |on_turn_id| {
                            on_turn_id(request.stream_context, turn_id);
                        }
                    }
                }
                continue;
            }

            if (!turn_started) continue;

            if (started_turn_id == null) {
                if (extractTurnIdFromStartedNotification(root, thread_id)) |turn_id| {
                    started_turn_id = try allocator.dupe(u8, turn_id);
                    if (request.on_turn_id) |on_turn_id| {
                        on_turn_id(request.stream_context, turn_id);
                    }
                }
            }

            saw_mcp_tool_call = saw_mcp_tool_call or isMcpToolCallNotification(root);

            try emitNotificationEvent(self, root, request);

            if (try appendNotificationDelta(root, allocator, &reply)) {
                if (request.on_stream_delta) |on_stream_delta| {
                    if (extractNotificationDelta(root)) |delta| {
                        on_stream_delta(request.stream_context, delta);
                    }
                }
                continue;
            }

            if (detectTurnTerminalState(root, thread_id, started_turn_id)) |terminal_state| {
                switch (terminal_state) {
                    .completed => break,
                    .failed => {
                        emitTurnFailure(root, request);
                        return error.CodexTurnFailed;
                    },
                    .interrupted => return error.CodexTurnInterrupted,
                }
            }
        }

        // Fast MCP completion notifications may carry the terminal status
        // before app-server attaches the persisted result. Hydrate only this
        // turn's items before the UI commits its pending tool cards.
        if (saw_mcp_tool_call) {
            self.emitHydratedMcpToolOutputs(thread_id, started_turn_id, request) catch |err| {
                runtime_log.diagnostic("failed to hydrate Codex MCP outputs: {s}", .{@errorName(err)});
            };
        }

        return reply.toOwnedSlice(allocator);
    }

    fn emitHydratedMcpToolOutputs(
        self: *Client,
        thread_id: []const u8,
        turn_id: ?[]const u8,
        request: provider_types.SendPromptRequest,
    ) !void {
        const on_stream_event = request.on_stream_event orelse return;
        const payload = try self.callRpcForResultAlloc("thread/read", .{
            .threadId = thread_id,
            .includeTurns = true,
        });
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        _ = try emitHydratedMcpToolOutputsFromThreadValue(
            self.allocator,
            parsed.value,
            turn_id,
            request.stream_context,
            on_stream_event,
        );
    }

    fn sendTurnStartRequest(
        self: *Client,
        thread_id: []const u8,
        request: provider_types.SendPromptRequest,
    ) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        var stringify: std.json.Stringify = .{
            .writer = &writer.writer,
            .options = .{},
        };

        try stringify.beginObject();
        try stringify.objectField("method");
        try stringify.write("turn/start");
        try stringify.objectField("id");
        try stringify.write(id);
        try stringify.objectField("params");
        try stringify.beginObject();
        try stringify.objectField("threadId");
        try stringify.write(thread_id);
        if (request.cwd) |working_dir| {
            try stringify.objectField("cwd");
            try stringify.write(working_dir);
        }
        if (request.model) |selected_model| {
            try stringify.objectField("model");
            try stringify.write(selected_model);
        }
        if (request.service_tier) |service_tier| {
            try stringify.objectField("serviceTier");
            try stringify.write(service_tier);
        }
        if (request.reasoning_effort) |effort| {
            try stringify.objectField("effort");
            try stringify.write(effort);
        }
        try writeTurnPolicyOverrides(&stringify, request);
        try stringify.objectField("input");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("text");
        try stringify.objectField("text");
        try stringify.write(request.prompt);
        try stringify.endObject();
        if (request.image) |image| {
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write("localImage");
            try stringify.objectField("path");
            try stringify.write(image.path);
            try stringify.endObject();
        }
        for (request.images) |image| {
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write("localImage");
            try stringify.objectField("path");
            try stringify.write(image.path);
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.endObject();
        try stringify.endObject();

        const payload = try writer.toOwnedSlice();
        defer self.allocator.free(payload);
        runtime_log.diagnostic("Codex RPC turn/start id={d} thread_id_len={d} payload_len={d}", .{ id, thread_id.len, payload.len });
        try self.writeTextMessage(payload);
        return id;
    }

    fn freeLoadedThreads(self: *Client) void {
        var it = self.loaded_threads.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
    }

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const message = .{
            .method = method,
            .params = params,
        };
        const payload = try stringifyAlloc(self.allocator, message);
        defer self.allocator.free(payload);
        try self.writeTextMessage(payload);
    }

    fn sendRequest(self: *Client, method: []const u8, params: anytype) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        const message = .{
            .method = method,
            .id = id,
            .params = params,
        };

        const payload = try stringifyAlloc(self.allocator, message);
        defer self.allocator.free(payload);
        try self.writeTextMessage(payload);
        return id;
    }

    fn callTurnSteerForResultAlloc(self: *Client, request: provider_types.SteerThreadRequest) ![]u8 {
        var attempt: usize = 0;
        var retried_turn_mismatch = false;
        var retry_turn_id: ?[]u8 = null;
        defer if (retry_turn_id) |turn_id| self.allocator.free(turn_id);
        while (true) : (attempt += 1) {
            var current_request = request;
            if (retry_turn_id) |turn_id| current_request.turn_id = turn_id;
            const id = try self.sendTurnSteerRequest(current_request);
            const maybe_payload = self.awaitTurnSteerResultPayloadAlloc(id, &retry_turn_id);
            if (maybe_payload) |payload| {
                return payload;
            } else |err| switch (err) {
                error.CodexExpectedTurnMismatch => {
                    if (retried_turn_mismatch or retry_turn_id == null) return error.CodexRpcFailed;
                    retried_turn_mismatch = true;
                    continue;
                },
                error.ServerOverloaded => {
                    if (attempt + 1 >= MAX_RPC_RETRIES) return err;
                    sleepMs(@min(@as(u64, 100) * (@as(u64, 1) << @intCast(attempt)), 1500));
                    continue;
                },
                else => return err,
            }
        }
    }

    fn sendTurnSteerRequest(self: *Client, request: provider_types.SteerThreadRequest) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        const payload = try turnSteerRequestPayloadAlloc(self.allocator, id, request);
        defer self.allocator.free(payload);
        try self.writeTextMessage(payload);
        return id;
    }

    fn callRpcForResultAlloc(self: *Client, method: []const u8, params: anytype) ![]u8 {
        return self.callRpcForResultAllocWait(method, params, RPC_WAIT);
    }

    fn callRpcForResultAllocWait(self: *Client, method: []const u8, params: anytype, wait: ReadWait) ![]u8 {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const id = try self.sendRequest(method, params);
            const maybe_payload = self.awaitResultPayloadAlloc(id, wait);
            if (maybe_payload) |payload| {
                return payload;
            } else |err| switch (err) {
                error.ServerOverloaded => {
                    if (attempt + 1 >= MAX_RPC_RETRIES) return err;
                    sleepMs(@min(@as(u64, 100) * (@as(u64, 1) << @intCast(attempt)), 1500));
                    continue;
                },
                else => return err,
            }
        }
    }

    fn callThreadCompactAndWait(self: *Client, thread_id: []const u8) !void {
        const id = try self.sendRequest("thread/compact/start", .{ .threadId = thread_id });
        var response_received = false;
        var compaction_completed = false;

        while (true) {
            const message = try self.readTextMessageAlloc(self.allocator);
            defer self.allocator.free(message);
            runtime_log.diagnostic("Codex RPC compact await id={d} message_len={d}", .{ id, message.len });

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (isContextCompactionCompleted(root, thread_id) or isThreadCompactionIdle(root, thread_id)) {
                compaction_completed = true;
            }

            if (parseMessageId(root)) |response_id| {
                if (response_id != id) continue;

                if (getObjectField(root, "error")) |rpc_error| {
                    provider_diagnostics.logError(
                        .codex_compact_rpc,
                        getOptionalObjectInteger(rpc_error, "code"),
                        message,
                    );
                    if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                        if (code == OVERLOAD_ERROR_CODE) return error.ServerOverloaded;
                    }
                    return error.CodexRpcFailed;
                }

                _ = getObjectField(root, "result") orelse return error.MissingRpcResult;
                response_received = true;
            }

            if (response_received and compaction_completed) return;
        }
    }

    fn callReviewStartAndWait(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
        args: []const u8,
    ) ![]u8 {
        const id = try self.sendReviewStartRequest(thread_id, args);
        var response_received = false;
        var review_text: std.ArrayList(u8) = .empty;
        defer review_text.deinit(allocator);

        while (true) {
            const message = try self.readTextMessageAlloc(self.allocator);
            defer self.allocator.free(message);
            runtime_log.diagnostic("Codex RPC review await id={d} message_len={d}", .{ id, message.len });

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (extractReviewCompletedText(root, thread_id)) |text| {
                review_text.clearRetainingCapacity();
                try review_text.appendSlice(allocator, text);
            } else if (try appendNotificationDelta(root, allocator, &review_text)) {
                // Keep assistant deltas as a fallback for protocol versions that
                // complete review without an `exitedReviewMode` payload.
            }

            if (parseMessageId(root)) |response_id| {
                if (response_id != id) continue;
                if (getObjectField(root, "error")) |rpc_error| {
                    provider_diagnostics.logError(
                        .codex_review_rpc,
                        getOptionalObjectInteger(rpc_error, "code"),
                        message,
                    );
                    if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                        if (code == OVERLOAD_ERROR_CODE) return error.ServerOverloaded;
                    }
                    return error.CodexRpcFailed;
                }
                _ = getObjectField(root, "result") orelse return error.MissingRpcResult;
                response_received = true;
            }

            if (response_received and isThreadCompactionIdle(root, thread_id)) {
                return review_text.toOwnedSlice(allocator);
            }
        }
    }

    fn callShellCommandAndWait(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
        command: []const u8,
    ) ![]u8 {
        const id = try self.sendRequest("thread/shellCommand", .{
            .threadId = thread_id,
            .command = command,
        });
        var response_received = false;
        var command_completed = false;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        while (true) {
            const message = try self.readTextMessageAlloc(self.allocator);
            defer self.allocator.free(message);
            runtime_log.diagnostic("Codex RPC shell await id={d} message_len={d}", .{ id, message.len });

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (extractShellOutputDelta(root)) |delta| try output.appendSlice(allocator, delta);
            if (isShellCommandCompleted(root, thread_id)) command_completed = true;

            if (parseMessageId(root)) |response_id| {
                if (response_id != id) continue;
                if (getObjectField(root, "error")) |rpc_error| {
                    provider_diagnostics.logError(
                        .codex_shell_rpc,
                        getOptionalObjectInteger(rpc_error, "code"),
                        message,
                    );
                    if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                        if (code == OVERLOAD_ERROR_CODE) return error.ServerOverloaded;
                    }
                    return error.CodexRpcFailed;
                }
                _ = getObjectField(root, "result") orelse return error.MissingRpcResult;
                response_received = true;
            }

            if (response_received and command_completed) return output.toOwnedSlice(allocator);
        }
    }

    fn sendReviewStartRequest(self: *Client, thread_id: []const u8, args: []const u8) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        var stringify: std.json.Stringify = .{
            .writer = &writer.writer,
            .options = .{},
        };

        try stringify.beginObject();
        try stringify.objectField("method");
        try stringify.write("review/start");
        try stringify.objectField("id");
        try stringify.write(id);
        try stringify.objectField("params");
        try stringify.beginObject();
        try stringify.objectField("threadId");
        try stringify.write(thread_id);
        try stringify.objectField("delivery");
        try stringify.write("inline");
        try stringify.objectField("target");
        try writeReviewTarget(&stringify, args);
        try stringify.endObject();
        try stringify.endObject();

        const payload = try writer.toOwnedSlice();
        defer self.allocator.free(payload);
        runtime_log.diagnostic("Codex RPC review/start id={d} thread_id_len={d} payload_len={d}", .{ id, thread_id.len, payload.len });
        try self.writeTextMessage(payload);
        return id;
    }

    fn awaitResultPayloadAlloc(self: *Client, id: u64, wait: ReadWait) ![]u8 {
        while (true) {
            const message = try self.readTextMessageAllocInterruptible(self.allocator, wait);
            defer self.allocator.free(message);
            runtime_log.diagnostic("Codex RPC await id={d} message_len={d}", .{ id, message.len });

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            const response_id = parseMessageId(root) orelse {
                continue;
            };

            if (response_id != id) continue;

            if (getObjectField(root, "error")) |rpc_error| {
                provider_diagnostics.logError(
                    .codex_rpc,
                    getOptionalObjectInteger(rpc_error, "code"),
                    message,
                );
                if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                    if (code == OVERLOAD_ERROR_CODE) return error.ServerOverloaded;
                }
                return error.CodexRpcFailed;
            }

            const result = getObjectField(root, "result") orelse return error.MissingRpcResult;
            const payload = try stringifyAlloc(self.allocator, result);
            runtime_log.diagnostic("Codex RPC response id={d} message_len={d} result_len={d}", .{ id, message.len, payload.len });
            return payload;
        }
    }

    fn awaitTurnSteerResultPayloadAlloc(self: *Client, id: u64, retry_turn_id: *?[]u8) ![]u8 {
        while (true) {
            const message = try self.readTextMessageAllocInterruptible(self.allocator, RPC_WAIT);
            defer self.allocator.free(message);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();

            const root = parsed.value;
            const response_id = parseMessageId(root) orelse {
                continue;
            };

            if (response_id != id) continue;

            if (getObjectField(root, "error")) |rpc_error| {
                if (std.mem.indexOf(u8, message, "activeTurnNotSteerable") != null or
                    std.mem.indexOf(u8, message, "active_turn_not_steerable") != null or
                    std.mem.indexOf(u8, message, "active turn not steerable") != null)
                {
                    return error.CodexActiveTurnNotSteerable;
                }
                if (getOptionalObjectString(rpc_error, "message")) |error_message| {
                    if (extractActualTurnIdFromSteerMismatch(error_message)) |actual_turn_id| {
                        if (retry_turn_id.*) |old_turn_id| self.allocator.free(old_turn_id);
                        retry_turn_id.* = try self.allocator.dupe(u8, actual_turn_id);
                        return error.CodexExpectedTurnMismatch;
                    }
                }
                if (std.mem.indexOf(u8, message, "code") != null) {
                    if (getObjectField(getObjectField(root, "error").?, "code")) |code_value| {
                        if (code_value == .integer and code_value.integer == OVERLOAD_ERROR_CODE) {
                            return error.ServerOverloaded;
                        }
                    }
                }
                return error.CodexRpcFailed;
            }

            const result = getObjectField(root, "result") orelse return error.MissingRpcResult;
            return try stringifyAlloc(self.allocator, result);
        }
    }

    fn maybeHandleMatchingResponse(self: *Client, root: std.json.Value, id: u64) !bool {
        _ = self;
        const response_id = parseMessageId(root) orelse return false;
        if (response_id != id) return false;

        if (getObjectField(root, "error")) |rpc_error| {
            if (getOptionalObjectInteger(rpc_error, "code")) |code| {
                if (code == OVERLOAD_ERROR_CODE) {
                    return error.ServerOverloaded;
                }
            }
            return error.CodexRpcFailed;
        }

        return true;
    }

    fn maybeHandleServerRequest(self: *Client, root: std.json.Value, request: provider_types.SendPromptRequest) !bool {
        const method = getOptionalObjectString(root, "method") orelse return false;
        const request_id = parseServerRequestId(root) orelse return false;

        switch (serverRequestKind(method)) {
            .command_approval => try handleCommandApprovalRequest(self, root, request_id, request),
            .file_change_approval => try handleFileChangeApprovalRequest(self, root, request_id, request),
            .permissions_approval => try handlePermissionsApprovalRequest(self, root, request_id, request),
            .mcp_elicitation => try handleMcpElicitationRequest(self, root, request_id, request),
            .dynamic_tool => try handleDynamicToolCallRequest(self, root, request_id, request),
            .unsupported => {
                // App-server stops the turn while a server request is unanswered.
                // A protocol addition must fail explicitly instead of becoming a
                // silent infinite "Working" state in the GUI.
                try handleUnsupportedServerRequest(self, method, request_id, request);
            },
        }
        return true;
    }

    fn writeTextMessage(self: *Client, payload: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        try writeClientFrame(self.allocator, stream, payload, .text);
    }

    fn writeCloseFrame(self: *Client, stream: std.Io.net.Stream) !void {
        try writeClientFrame(self.allocator, stream, "", .connection_close);
    }

    fn readTextMessageAlloc(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        const stream = self.stream orelse return error.NotConnected;

        while (true) {
            const frame = try readServerFrameAlloc(allocator, stream);
            errdefer allocator.free(frame.payload);

            switch (frame.opcode) {
                .pong => {
                    allocator.free(frame.payload);
                    continue;
                },
                .ping => {
                    defer allocator.free(frame.payload);
                    try writeClientFrame(self.allocator, stream, frame.payload, .pong);
                    continue;
                },
                .connection_close => {
                    allocator.free(frame.payload);
                    return error.ConnectionClosed;
                },
                .text => return frame.payload,
                else => {
                    allocator.free(frame.payload);
                    return error.UnexpectedWebSocketFrame;
                },
            }
        }
    }

    fn readTextMessageAllocInterruptible(
        self: *Client,
        allocator: std.mem.Allocator,
        wait: ReadWait,
    ) ![]u8 {
        const stream = self.stream orelse return error.NotConnected;

        while (true) {
            const frame = try readServerFrameAllocInterruptible(allocator, stream, wait);
            errdefer allocator.free(frame.payload);

            switch (frame.opcode) {
                .pong => {
                    allocator.free(frame.payload);
                    continue;
                },
                .ping => {
                    defer allocator.free(frame.payload);
                    try writeClientFrame(self.allocator, stream, frame.payload, .pong);
                    continue;
                },
                .connection_close => {
                    allocator.free(frame.payload);
                    return error.ConnectionClosed;
                },
                .text => return frame.payload,
                else => {
                    allocator.free(frame.payload);
                    return error.UnexpectedWebSocketFrame;
                },
            }
        }
    }
};

pub fn shutdownOwnedServer() void {
    shared_server_state.mutex.lock();
    defer shared_server_state.mutex.unlock();
    stopOwnedServerLocked();
}

fn extractActualTurnIdFromSteerMismatch(message: []const u8) ?[]const u8 {
    const prefix = "expected active turn id `";
    const separator = "` but found `";
    if (!std.mem.startsWith(u8, message, prefix) or !std.mem.endsWith(u8, message, "`")) return null;
    const remainder = message[prefix.len .. message.len - 1];
    const separator_index = std.mem.indexOf(u8, remainder, separator) orelse return null;
    const actual_turn_id = remainder[separator_index + separator.len ..];
    return if (actual_turn_id.len == 0) null else actual_turn_id;
}

fn stopOwnedServerLocked() void {
    if (shared_server_state.child) |*child| {
        if (shared_server_state.owns_child) {
            runtime_log.diagnostic("codex.stopOwnedServer stopping pid={d}", .{child.processId() orelse 0});
            var threaded = std.Io.Threaded.init_single_threaded;
            child.kill(threaded.io());
        }
        shared_server_state.child = null;
        shared_server_state.owns_child = false;
    }
}

const FrameOpcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
    _,
};

const Frame = struct {
    opcode: FrameOpcode,
    payload: []u8,
};

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{},
    };
    try stringify.write(value);
    return writer.toOwnedSlice();
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn computeAcceptKeyAlloc(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var sha_input: std.ArrayList(u8) = .empty;
    defer sha_input.deinit(allocator);
    try sha_input.appendSlice(allocator, key);
    try sha_input.appendSlice(allocator, WS_GUID);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(sha_input.items, &digest, .{});
    return encodeBase64Alloc(allocator, &digest);
}

fn buildRequestTargetAlloc(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const path = switch (uri.path) {
        .raw => |raw| if (raw.len == 0) "/" else raw,
        .percent_encoded => |encoded| if (encoded.len == 0) "/" else encoded,
    };

    var target = std.ArrayList(u8).empty;
    defer target.deinit(allocator);
    try target.appendSlice(allocator, path);

    if (uri.query) |query| {
        try target.append(allocator, '?');
        switch (query) {
            .raw => |raw| try target.appendSlice(allocator, raw),
            .percent_encoded => |encoded| try target.appendSlice(allocator, encoded),
        }
    }

    return target.toOwnedSlice(allocator);
}

fn readHttpLineAlloc(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        // A wedged app-server can accept the TCP connection without ever
        // answering the upgrade; never block connect (and therefore stop and
        // resume paths) forever on that.
        const read = try streamReadInterruptible(stream, &byte, .{
            .idle_timeout_ms = HANDSHAKE_IDLE_TIMEOUT_MS,
        });
        if (read == 0) return error.EndOfStream;

        if (byte[0] == '\n') break;
        if (line.items.len >= MAX_HTTP_LINE_BYTES) return error.HttpLineTooLong;
        if (byte[0] != '\r') {
            try line.append(allocator, byte[0]);
        }
    }

    return line.toOwnedSlice(allocator);
}

fn readExact(stream: std.Io.net.Stream, buffer: []u8) !void {
    var index: usize = 0;
    while (index < buffer.len) {
        const amt = try streamRead(stream, buffer[index..]);
        if (amt == 0) return error.EndOfStream;
        index += amt;
    }
}

fn readExactInterruptible(
    stream: std.Io.net.Stream,
    buffer: []u8,
    wait: ReadWait,
) !void {
    var index: usize = 0;
    while (index < buffer.len) {
        const amt = try streamReadInterruptible(stream, buffer[index..], wait);
        if (amt == 0) return error.EndOfStream;
        index += amt;
    }
}

fn writeClientFrame(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    payload: []const u8,
    opcode: FrameOpcode,
) !void {
    var header: [14]u8 = undefined;
    var index: usize = 0;

    header[index] = @as(u8, 0x80) | @as(u8, @intCast(@intFromEnum(opcode)));
    index += 1;

    if (payload.len <= 125) {
        header[index] = 0x80 | @as(u8, @intCast(payload.len));
        index += 1;
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[index] = 0x80 | 126;
        index += 1;
        var len16: [2]u8 = undefined;
        std.mem.writeInt(u16, &len16, @intCast(payload.len), .big);
        @memcpy(header[index .. index + len16.len], &len16);
        index += 2;
    } else {
        header[index] = 0x80 | 127;
        index += 1;
        var len64: [8]u8 = undefined;
        std.mem.writeInt(u64, &len64, payload.len, .big);
        @memcpy(header[index .. index + len64.len], &len64);
        index += 8;
    }

    var mask: [4]u8 = undefined;
    var threaded = std.Io.Threaded.init_single_threaded;
    try std.Io.randomSecure(threaded.io(), &mask);
    @memcpy(header[index .. index + 4], &mask);
    index += 4;

    const masked = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked);
    for (payload, 0..) |byte, i| {
        masked[i] = byte ^ mask[i % mask.len];
    }

    try streamWriteAll(stream, header[0..index]);
    try streamWriteAll(stream, masked);
}

fn streamRead(stream: std.Io.net.Stream, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    var threaded = std.Io.Threaded.init_single_threaded;
    return streamReadWithIo(threaded.io(), stream, buffer);
}

fn readWaitShouldStop(wait: ReadWait) bool {
    const request = wait.request orelse return false;
    const should_stop = request.on_should_stop orelse return false;
    return should_stop(request.stream_context);
}

fn streamReadInterruptible(
    stream: std.Io.net.Stream,
    buffer: []u8,
    wait: ReadWait,
) !usize {
    if (buffer.len == 0) return 0;
    if (readWaitShouldStop(wait)) return error.CodexTurnInterrupted;

    const Event = union(enum) {
        read: std.Io.net.Stream.Reader.Error!usize,
        poll: std.Io.Cancelable!void,
    };
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result_buffer: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &result_buffer);
    defer select.cancelDiscard();

    try select.concurrent(.read, streamReadWithIo, .{ io, stream, buffer });
    try select.concurrent(.poll, std.Io.sleep, .{
        io,
        std.Io.Duration.fromMilliseconds(INTERRUPTIBLE_READ_POLL_MS),
        std.Io.Clock.awake,
    });
    // Idle accounting restarts on every call, so any received byte anywhere in
    // the message stream resets the deadline.
    var idle_ms: u64 = 0;
    while (true) {
        switch (try select.await()) {
            .read => |result| return try result,
            .poll => |result| {
                try result;
                if (readWaitShouldStop(wait)) return error.CodexTurnInterrupted;
                idle_ms += INTERRUPTIBLE_READ_POLL_MS;
                if (wait.idle_timeout_ms) |limit| {
                    if (idle_ms >= limit) return error.CodexServerUnresponsive;
                }
                try select.concurrent(.poll, std.Io.sleep, .{
                    io,
                    std.Io.Duration.fromMilliseconds(INTERRUPTIBLE_READ_POLL_MS),
                    std.Io.Clock.awake,
                });
            },
        }
    }
}

fn streamReadWithIo(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) std.Io.net.Stream.Reader.Error!usize {
    var reader_buffer: [0]u8 = .{};
    var reader = stream.reader(io, &reader_buffer);
    return reader.interface.readSliceShort(buffer) catch {
        return reader.err orelse error.Unexpected;
    };
}

fn streamWriteAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var threaded = std.Io.Threaded.init_single_threaded;
    var writer = stream.writer(threaded.io(), &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readServerFrameAlloc(allocator: std.mem.Allocator, stream: std.Io.net.Stream) !Frame {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    const opcode: FrameOpcode = @enumFromInt(header[0] & 0x0f);
    const masked = (header[1] & 0x80) != 0;
    const len_marker = header[1] & 0x7f;

    const payload_len: usize = switch (len_marker) {
        126 => blk: {
            var buf: [2]u8 = undefined;
            try readExact(stream, &buf);
            break :blk std.mem.readInt(u16, &buf, .big);
        },
        127 => blk: {
            var buf: [8]u8 = undefined;
            try readExact(stream, &buf);
            const long = std.mem.readInt(u64, &buf, .big);
            break :blk std.math.cast(usize, long) orelse return error.WebSocketMessageTooLarge;
        },
        else => len_marker,
    };

    if (payload_len > MAX_WS_MESSAGE_BYTES) {
        runtime_log.diagnostic(
            "websocket frame too large opcode={s} masked={} payload_len={d}",
            .{ @tagName(opcode), masked, payload_len },
        );
        return error.WebSocketMessageTooLarge;
    }

    var mask: [4]u8 = undefined;
    if (masked) {
        try readExact(stream, &mask);
    }

    const payload = allocator.alloc(u8, payload_len) catch |err| {
        runtime_log.diagnostic(
            "websocket payload alloc failed opcode={s} payload_len={d}: {s}",
            .{ @tagName(opcode), payload_len, @errorName(err) },
        );
        return err;
    };
    errdefer allocator.free(payload);
    try readExact(stream, payload);

    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % mask.len];
        }
    }

    return .{
        .opcode = opcode,
        .payload = payload,
    };
}

fn readServerFrameAllocInterruptible(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    wait: ReadWait,
) !Frame {
    var header: [2]u8 = undefined;
    try readExactInterruptible(stream, &header, wait);

    const opcode: FrameOpcode = @enumFromInt(header[0] & 0x0f);
    const masked = (header[1] & 0x80) != 0;
    const len_marker = header[1] & 0x7f;

    const payload_len: usize = switch (len_marker) {
        126 => blk: {
            var buf: [2]u8 = undefined;
            try readExactInterruptible(stream, &buf, wait);
            break :blk std.mem.readInt(u16, &buf, .big);
        },
        127 => blk: {
            var buf: [8]u8 = undefined;
            try readExactInterruptible(stream, &buf, wait);
            const long = std.mem.readInt(u64, &buf, .big);
            break :blk std.math.cast(usize, long) orelse return error.WebSocketMessageTooLarge;
        },
        else => len_marker,
    };

    if (payload_len > MAX_WS_MESSAGE_BYTES) {
        runtime_log.diagnostic(
            "websocket frame too large opcode={s} masked={} payload_len={d}",
            .{ @tagName(opcode), masked, payload_len },
        );
        return error.WebSocketMessageTooLarge;
    }

    var mask: [4]u8 = undefined;
    if (masked) {
        try readExactInterruptible(stream, &mask, wait);
    }

    const payload = allocator.alloc(u8, payload_len) catch |err| {
        runtime_log.diagnostic(
            "websocket payload alloc failed opcode={s} payload_len={d}: {s}",
            .{ @tagName(opcode), payload_len, @errorName(err) },
        );
        return err;
    };
    errdefer allocator.free(payload);
    try readExactInterruptible(stream, payload, wait);

    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % mask.len];
        }
    }

    return .{
        .opcode = opcode,
        .payload = payload,
    };
}

fn parseMessageId(root: std.json.Value) ?u64 {
    const id_value = getObjectField(root, "id") orelse return null;
    return switch (id_value) {
        .integer => |value| if (value < 0) null else @as(u64, @intCast(value)),
        else => null,
    };
}

fn parseServerRequestId(root: std.json.Value) ?std.json.Value {
    const id_value = getObjectField(root, "id") orelse return null;
    return switch (id_value) {
        .integer, .string => id_value,
        else => null,
    };
}

fn serverRequestKind(method: []const u8) ServerRequestKind {
    if (std.mem.eql(u8, method, "item/commandExecution/requestApproval")) return .command_approval;
    if (std.mem.eql(u8, method, "item/fileChange/requestApproval")) return .file_change_approval;
    if (std.mem.eql(u8, method, "item/permissions/requestApproval")) return .permissions_approval;
    if (std.mem.eql(u8, method, "mcpServer/elicitation/request")) return .mcp_elicitation;
    if (std.mem.eql(u8, method, "item/tool/call")) return .dynamic_tool;
    return .unsupported;
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn getOptionalObjectString(value: std.json.Value, field: []const u8) ?[]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    return stringValue(field_value);
}

fn getOptionalObjectInteger(value: std.json.Value, field: []const u8) ?i64 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value) {
        .integer => |number| number,
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

fn backgroundTerminalListContainsProcess(allocator: std.mem.Allocator, payload: []const u8, process_id: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const data = getObjectField(parsed.value, "data") orelse return error.InvalidBackgroundTerminalResponse;
    if (data != .array) return error.InvalidBackgroundTerminalResponse;
    for (data.array.items) |item| {
        const candidate = getOptionalObjectString(item, "processId") orelse continue;
        if (std.mem.eql(u8, candidate, process_id)) return true;
    }
    return false;
}

fn isContextCompactionCompleted(root: std.json.Value, thread_id: []const u8) bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    if (!std.mem.eql(u8, method, "item/completed")) return false;

    const params = getObjectField(root, "params") orelse return false;
    if (getOptionalObjectString(params, "threadId")) |notification_thread_id| {
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return false;
    }

    const item = getObjectField(params, "item") orelse return false;
    const item_type = getOptionalObjectString(item, "type") orelse return false;
    return std.mem.eql(u8, item_type, "contextCompaction");
}

fn isThreadCompactionIdle(root: std.json.Value, thread_id: []const u8) bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    if (std.mem.eql(u8, method, "turn/completed")) {
        const params = getObjectField(root, "params") orelse return false;
        const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return false;
        return std.mem.eql(u8, notification_thread_id, thread_id);
    }
    if (std.mem.eql(u8, method, "thread/status/changed")) {
        const params = getObjectField(root, "params") orelse return false;
        const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return false;
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return false;
        const status = getObjectField(params, "status") orelse return false;
        const type_name = getOptionalObjectString(status, "type") orelse return false;
        return std.mem.eql(u8, type_name, "idle");
    }
    return false;
}

fn writeReviewTarget(stringify: *std.json.Stringify, raw_args: []const u8) !void {
    const args = std.mem.trim(u8, raw_args, " \t\r\n");
    if (args.len == 0 or std.mem.eql(u8, args, "changes") or std.mem.eql(u8, args, "uncommitted")) {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("uncommittedChanges");
        try stringify.endObject();
        return;
    }

    var parts = std.mem.tokenizeAny(u8, args, " \t\r\n");
    const kind = parts.next() orelse "";
    if (std.mem.eql(u8, kind, "base")) {
        const branch = parts.next() orelse "main";
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("baseBranch");
        try stringify.objectField("branch");
        try stringify.write(branch);
        try stringify.endObject();
        return;
    }
    if (std.mem.eql(u8, kind, "commit")) {
        const sha = parts.next() orelse args;
        const title_start = if (std.mem.indexOf(u8, args, sha)) |sha_start|
            @min(args.len, sha_start + sha.len)
        else
            args.len;
        const title = std.mem.trim(u8, args[title_start..], " \t\r\n");
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("commit");
        try stringify.objectField("sha");
        try stringify.write(sha);
        if (title.len > 0) {
            try stringify.objectField("title");
            try stringify.write(title);
        }
        try stringify.endObject();
        return;
    }

    const instructions = if (std.mem.startsWith(u8, args, "custom"))
        std.mem.trim(u8, args["custom".len..], " \t\r\n")
    else
        args;
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("custom");
    try stringify.objectField("instructions");
    try stringify.write(instructions);
    try stringify.endObject();
}

fn confirmedShellCommand(raw_args: []const u8) ?[]const u8 {
    const args = std.mem.trim(u8, raw_args, " \t\r\n");
    if (!std.mem.startsWith(u8, args, "confirm")) return null;
    if (args.len > "confirm".len and !std.ascii.isWhitespace(args["confirm".len])) return null;
    const command = std.mem.trim(u8, args["confirm".len..], " \t\r\n");
    return if (command.len == 0) null else command;
}

fn formatShellCommandResultAlloc(allocator: std.mem.Allocator, command: []const u8, output: []const u8) ![]u8 {
    const trimmed_output = std.mem.trim(u8, output, "\r\n");
    if (trimmed_output.len == 0) {
        return std.fmt.allocPrint(allocator, "Command:\n{s}\n\nNo output captured.", .{command});
    }
    return std.fmt.allocPrint(allocator, "Command:\n{s}\n\nOutput:\n{s}", .{ command, trimmed_output });
}

fn extractReviewCompletedText(root: std.json.Value, thread_id: []const u8) ?[]const u8 {
    const method = getOptionalObjectString(root, "method") orelse return null;
    if (!std.mem.eql(u8, method, "item/completed")) return null;
    const params = getObjectField(root, "params") orelse return null;
    if (getOptionalObjectString(params, "threadId")) |notification_thread_id| {
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;
    }
    const item = getObjectField(params, "item") orelse return null;
    const item_type = getOptionalObjectString(item, "type") orelse return null;
    if (!std.mem.eql(u8, item_type, "exitedReviewMode")) return null;
    return getOptionalObjectString(item, "review");
}

fn extractShellOutputDelta(root: std.json.Value) ?[]const u8 {
    const method = getOptionalObjectString(root, "method") orelse return null;
    if (!std.mem.eql(u8, method, "item/commandExecution/outputDelta")) return null;
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByPath(params, &.{ "delta", "text" }) orelse
        findFirstStringByPath(params, &.{ "delta", "output" }) orelse
        findFirstStringByPath(params, &.{"delta"}) orelse
        findFirstStringByPath(params, &.{"output"}) orelse
        findFirstStringByPath(params, &.{"text"});
}

fn isShellCommandCompleted(root: std.json.Value, thread_id: []const u8) bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    if (!std.mem.eql(u8, method, "item/completed")) return false;
    const params = getObjectField(root, "params") orelse return false;
    if (getOptionalObjectString(params, "threadId")) |notification_thread_id| {
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return false;
    }
    const item = getObjectField(params, "item") orelse return false;
    const item_type = getOptionalObjectString(item, "type") orelse return false;
    return std.mem.eql(u8, item_type, "commandExecution");
}

fn isGoalStatus(args: []const u8) bool {
    return std.mem.eql(u8, args, "active") or
        std.mem.eql(u8, args, "paused") or
        std.mem.eql(u8, args, "blocked") or
        std.mem.eql(u8, args, "complete");
}

fn formatGoalSummaryAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.InvalidGoalPayload;
    defer parsed.deinit();

    const root = getObjectField(parsed.value, "result") orelse parsed.value;
    const goal = if (getObjectField(root, "goal")) |goal_value| switch (goal_value) {
        .null => return allocator.dupe(u8, "Codex goal\n\nNo active Codex goal."),
        else => goal_value,
    } else root;

    const objective = getOptionalObjectString(goal, "objective") orelse
        getOptionalObjectString(goal, "text") orelse
        getOptionalObjectString(goal, "description");
    const status = getOptionalObjectString(goal, "status");
    const token_budget = getOptionalObjectInteger(goal, "tokenBudget") orelse
        getOptionalObjectInteger(goal, "token_budget");

    if (objective == null and status == null and token_budget == null) {
        return allocator.dupe(u8, "Codex goal\n\nNo active Codex goal.");
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try writer.writer.print("Codex goal\n\n", .{});
    if (status) |value| try writer.writer.print("Status: {s}\n", .{value});
    if (objective) |value| try writer.writer.print("Objective: {s}\n", .{value});
    if (token_budget) |value| try writer.writer.print("Token budget: {d}\n", .{value});

    return writer.toOwnedSlice();
}

fn formatUsageSummaryAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
    maybe_rate_payload: ?[]const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.InvalidUsagePayload;
    defer parsed.deinit();

    const root = getObjectField(parsed.value, "result") orelse parsed.value;
    const summary = getObjectField(root, "summary") orelse return error.InvalidUsagePayload;
    const buckets = getObjectField(root, "dailyUsageBuckets");

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try writer.writer.print("Codex usage\n\n", .{});
    if (maybe_rate_payload) |rate_payload| {
        try appendRateLimitsSummary(allocator, &writer.writer, rate_payload);
    }

    try writer.writer.print("Summary\n", .{});
    if (getOptionalObjectInteger(summary, "lifetimeTokens")) |tokens| {
        try writer.writer.print("• Lifetime tokens: ", .{});
        try writeTokenCount(&writer.writer, tokens);
        try writer.writer.print("\n", .{});
    }
    if (getOptionalObjectInteger(summary, "peakDailyTokens")) |tokens| {
        try writer.writer.print("• Peak day: ", .{});
        try writeTokenCount(&writer.writer, tokens);
        if (peakUsageDate(buckets, tokens)) |date| try writer.writer.print(" on {s}", .{date});
        try writer.writer.print("\n", .{});
    }
    if (getOptionalObjectInteger(summary, "currentStreakDays")) |current| {
        try writer.writer.print("• Current streak: {d} day{s}", .{ current, pluralSuffix(current) });
        if (getOptionalObjectInteger(summary, "longestStreakDays")) |longest| {
            try writer.writer.print(" (longest {d})", .{longest});
        }
        try writer.writer.print("\n", .{});
    }
    if (getOptionalObjectInteger(summary, "longestRunningTurnSec")) |seconds| {
        try writer.writer.print("• Longest turn: ", .{});
        try writeDuration(&writer.writer, seconds);
        try writer.writer.print("\n", .{});
    }

    if (buckets) |daily| {
        try appendRecentUsageBuckets(&writer.writer, daily, 7);
    }

    return writer.toOwnedSlice();
}

fn appendRateLimitsSummary(allocator: std.mem.Allocator, writer: anytype, payload: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();

    const root = getObjectField(parsed.value, "result") orelse parsed.value;
    var wrote_header = false;
    if (getObjectField(root, "rateLimits")) |limits| {
        try appendRateLimitBlock(writer, limits, &wrote_header);
    }
    if (getObjectField(root, "rateLimitsByLimitId")) |by_id| {
        if (by_id == .object) {
            var it = by_id.object.iterator();
            while (it.next()) |entry| {
                const limits = entry.value_ptr.*;
                if (isDefaultCodexLimit(limits)) continue;
                try appendRateLimitBlock(writer, limits, &wrote_header);
            }
        }
    }
    if (getObjectField(root, "rateLimitResetCredits")) |credits| {
        if (getOptionalObjectInteger(credits, "availableCount")) |count| {
            if (!wrote_header) {
                try writer.print("Limits\n", .{});
                wrote_header = true;
            }
            try writer.print("• Reset credits: {d} available\n", .{count});
        }
    }
    if (wrote_header) try writer.print("\n", .{});
}

fn appendRateLimitBlock(writer: anytype, limits: std.json.Value, wrote_header: *bool) !void {
    const label = getOptionalObjectString(limits, "limitName") orelse "Codex";
    if (!wrote_header.*) {
        try writer.print("Limits\n", .{});
        wrote_header.* = true;
    }

    if (getObjectField(limits, "primary")) |primary| {
        try appendWindowLimit(writer, label, "5h", primary);
    }
    if (getObjectField(limits, "secondary")) |secondary| {
        try appendWindowLimit(writer, label, "weekly", secondary);
    }
    if (getObjectField(limits, "credits")) |credits| {
        if (getOptionalObjectBool(credits, "unlimited") == true) {
            try writer.print("• {s} credits: unlimited\n", .{label});
        } else if (getOptionalObjectString(credits, "balance")) |balance| {
            if (getOptionalObjectBool(credits, "hasCredits") == true) {
                try writer.print("• {s} credits: {s}\n", .{ label, balance });
            }
        }
    }
}

fn appendWindowLimit(writer: anytype, label: []const u8, window_label: []const u8, window: std.json.Value) !void {
    const used_percent = getOptionalObjectInteger(window, "usedPercent") orelse return;
    const left = @max(@as(i64, 0), 100 - @min(@as(i64, 100), @max(@as(i64, 0), used_percent)));
    try writer.print("• {s} {s}: {d}% left", .{ label, window_label, left });
    if (getOptionalObjectInteger(window, "resetsAt")) |resets_at| {
        try writer.print(" (resets ", .{});
        try writeResetTime(writer, resets_at);
        try writer.print(")", .{});
    }
    try writer.print("\n", .{});
}

fn isDefaultCodexLimit(limits: std.json.Value) bool {
    const id = getOptionalObjectString(limits, "limitId") orelse return false;
    return std.mem.eql(u8, id, "codex");
}

fn appendRecentUsageBuckets(writer: anytype, buckets: std.json.Value, max_rows: usize) !void {
    if (buckets != .array or buckets.array.items.len == 0) return;

    try writer.print("\nRecent daily usage\n", .{});
    const start = if (buckets.array.items.len > max_rows) buckets.array.items.len - max_rows else 0;
    for (buckets.array.items[start..]) |bucket| {
        const date = getOptionalObjectString(bucket, "startDate") orelse continue;
        const tokens = getOptionalObjectInteger(bucket, "tokens") orelse continue;
        try writer.print("• {s}: ", .{date});
        try writeTokenCount(writer, tokens);
        try writer.print("\n", .{});
    }
}

fn peakUsageDate(maybe_buckets: ?std.json.Value, peak_tokens: i64) ?[]const u8 {
    const buckets = maybe_buckets orelse return null;
    if (buckets != .array) return null;
    for (buckets.array.items) |bucket| {
        const tokens = getOptionalObjectInteger(bucket, "tokens") orelse continue;
        if (tokens == peak_tokens) return getOptionalObjectString(bucket, "startDate");
    }
    return null;
}

fn writeTokenCount(writer: anytype, tokens: i64) !void {
    const value: u64 = if (tokens <= 0) 0 else @intCast(tokens);
    if (value >= 1_000_000_000) return writeFixedOne(writer, value, 1_000_000_000, "B tokens");
    if (value >= 1_000_000) return writeFixedOne(writer, value, 1_000_000, "M tokens");
    if (value >= 1_000) return writeFixedOne(writer, value, 1_000, "K tokens");
    try writer.print("{d} tokens", .{value});
}

fn writeFixedOne(writer: anytype, value: u64, scale: u64, suffix: []const u8) !void {
    const whole = value / scale;
    const fraction = (value % scale) * 10 / scale;
    if (fraction == 0) {
        try writer.print("{d} {s}", .{ whole, suffix });
    } else {
        try writer.print("{d}.{d} {s}", .{ whole, fraction, suffix });
    }
}

fn writeDuration(writer: anytype, seconds: i64) !void {
    const value: u64 = if (seconds <= 0) 0 else @intCast(seconds);
    const hours = value / 3600;
    const minutes = (value % 3600) / 60;
    if (hours > 0) {
        try writer.print("{d}h {d}m", .{ hours, minutes });
    } else if (minutes > 0) {
        try writer.print("{d}m", .{minutes});
    } else {
        try writer.print("{d}s", .{value});
    }
}

fn writeResetTime(writer: anytype, resets_at: i64) !void {
    const now = unixTimestampSeconds();
    if (now <= 0 or resets_at <= now) {
        try writer.print("soon", .{});
        return;
    }

    try writer.print("in ", .{});
    try writeDuration(writer, resets_at - now);
}

fn unixTimestampSeconds() i64 {
    return @divTrunc(platform_runtime.unixTimestampMs(), std.time.ms_per_s);
}

fn pluralSuffix(count: i64) []const u8 {
    return if (count == 1) "" else "s";
}

fn appendImportedMessagesForItem(
    allocator: std.mem.Allocator,
    item: std.json.Value,
    messages: *std.ArrayList(provider_types.ChatMessage),
) !void {
    const item_type = getOptionalObjectString(item, "type") orelse return;

    if (std.mem.eql(u8, item_type, "userMessage")) {
        const content = getObjectField(item, "content") orelse return;
        const body = try flattenUserMessageContentAlloc(allocator, content);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .user, "You", body);
        return;
    }

    if (std.mem.eql(u8, item_type, "agentMessage")) {
        const text = getOptionalObjectString(item, "text") orelse return;
        if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .assistant, "Codex", text);
        return;
    }

    if (std.mem.eql(u8, item_type, "commandExecution")) {
        const command = getOptionalObjectString(item, "command") orelse return;
        const status = getOptionalObjectString(item, "status") orelse "completed";
        const author: []const u8 = if (std.mem.eql(u8, status, "failed")) "Command failed" else "Ran command";
        try appendImportedMessage(allocator, messages, .system, author, command);
        return;
    }

    if (std.mem.eql(u8, item_type, "mcpToolCall")) {
        const status = getOptionalObjectString(item, "status") orelse return;
        if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "failed")) return;
        var label_buf: [512]u8 = undefined;
        const label = formatMcpToolCallLabel(&label_buf, item) orelse return;
        const author: []const u8 = if (std.mem.eql(u8, status, "failed")) "Command failed" else "Ran command";
        try appendImportedMessage(allocator, messages, .system, author, label);
        return;
    }

    if (std.mem.eql(u8, item_type, "fileChange")) {
        const changes = getObjectField(item, "changes") orelse return;
        const body = try buildImportedFileChangeSummaryAlloc(allocator, changes);
        defer allocator.free(body);
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .system, "Changed files", body);
        return;
    }

    if (std.mem.eql(u8, item_type, "webSearch")) {
        const query = getOptionalObjectString(item, "query") orelse return;
        if (std.mem.trim(u8, query, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .system, "Web search", query);
        return;
    }

    if (std.mem.eql(u8, item_type, "collabAgentToolCall") or std.mem.eql(u8, item_type, "subAgentActivity")) {
        const body = getOptionalObjectString(item, "prompt") orelse
            getOptionalObjectString(item, "agentPath") orelse
            getOptionalObjectString(item, "agent_path") orelse
            getOptionalObjectString(item, "tool") orelse
            "Codex subagent";
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) return;
        try appendImportedMessage(allocator, messages, .system, "Subagent", body);
    }
}

fn appendImportedMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(provider_types.ChatMessage),
    role: provider_types.MessageRole,
    author: []const u8,
    body: []const u8,
) !void {
    try messages.append(allocator, .{
        .role = role,
        .author = try allocator.dupe(u8, author),
        .body = try allocator.dupe(u8, body),
    });
}

fn flattenUserMessageContentAlloc(allocator: std.mem.Allocator, content: std.json.Value) ![]u8 {
    if (content != .array) return allocator.dupe(u8, "");

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    for (content.array.items) |entry| {
        if (entry != .object) continue;
        const content_type = getOptionalObjectString(entry, "type") orelse continue;
        var segment: ?[]const u8 = null;

        if (std.mem.eql(u8, content_type, "text")) {
            segment = getOptionalObjectString(entry, "text");
        } else if (std.mem.eql(u8, content_type, "mention")) {
            segment = getOptionalObjectString(entry, "path") orelse getOptionalObjectString(entry, "name");
        } else if (std.mem.eql(u8, content_type, "skill")) {
            segment = getOptionalObjectString(entry, "name");
        }

        if (segment) |text| {
            if (text.len == 0) continue;
            if (builder.items.len > 0) try builder.appendSlice(allocator, "\n\n");
            try builder.appendSlice(allocator, text);
            continue;
        }

        if (std.mem.eql(u8, content_type, "localImage")) {
            const path = getOptionalObjectString(entry, "path") orelse continue;
            if (builder.items.len > 0) try builder.appendSlice(allocator, "\n\n");
            const label = try std.fmt.allocPrint(allocator, "[Image: {s}]", .{path});
            defer allocator.free(label);
            try builder.appendSlice(allocator, label);
            continue;
        }

        if (std.mem.eql(u8, content_type, "image")) {
            const url = getOptionalObjectString(entry, "url") orelse continue;
            if (builder.items.len > 0) try builder.appendSlice(allocator, "\n\n");
            const label = try std.fmt.allocPrint(allocator, "[Image: {s}]", .{url});
            defer allocator.free(label);
            try builder.appendSlice(allocator, label);
        }
    }

    return builder.toOwnedSlice(allocator);
}

fn buildImportedFileChangeSummaryAlloc(allocator: std.mem.Allocator, changes: std.json.Value) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    if (changes != .array) return allocator.dupe(u8, "");

    for (changes.array.items) |change| {
        const path = getOptionalObjectString(change, "path") orelse continue;
        const additions = countDiffLines(change, '+');
        const deletions = countDiffLines(change, '-');
        if (body.items.len > 0) try body.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "{s}  +{d} / -{d}", .{
            path,
            additions,
            deletions,
        });
        defer allocator.free(line);
        try body.appendSlice(allocator, line);
    }

    return body.toOwnedSlice(allocator);
}

fn appendNotificationDelta(
    root: std.json.Value,
    allocator: std.mem.Allocator,
    reply: *std.ArrayList(u8),
) !bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    if (!std.mem.eql(u8, method, "item/agentMessage/delta")) {
        return false;
    }

    const params = getObjectField(root, "params") orelse return true;

    if (findFirstStringByPath(params, &.{ "delta", "text" })) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }
    if (findFirstStringByPath(params, &.{"delta"})) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }
    if (findFirstStringByPath(params, &.{ "item", "text" })) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }
    if (findFirstStringByPath(params, &.{"text"})) |text| {
        try reply.appendSlice(allocator, text);
        return true;
    }

    return true;
}

fn extractNotificationDelta(root: std.json.Value) ?[]const u8 {
    const method = getOptionalObjectString(root, "method") orelse return null;
    if (!std.mem.eql(u8, method, "item/agentMessage/delta")) {
        return null;
    }

    const params = getObjectField(root, "params") orelse return null;

    return findFirstStringByPath(params, &.{ "delta", "text" }) orelse
        findFirstStringByPath(params, &.{"delta"}) orelse
        findFirstStringByPath(params, &.{ "item", "text" }) orelse
        findFirstStringByPath(params, &.{"text"});
}

fn emitNotificationEvent(self: *Client, root: std.json.Value, request: provider_types.SendPromptRequest) !void {
    const method = getOptionalObjectString(root, "method") orelse return;

    const on_stream_event = request.on_stream_event orelse return;

    if (std.mem.eql(u8, method, "item/started") or std.mem.eql(u8, method, "item/completed")) {
        if (try emitItemEvent(self.allocator, root, request.stream_context, on_stream_event)) {
            return;
        }
    }

    if (std.mem.eql(u8, method, "turn/diff/updated")) {
        if (buildDiffSummary(root, .turn_snapshot, request.stream_context, on_stream_event)) {
            return;
        }
    }

    if (std.mem.eql(u8, method, "item/fileChange/outputDelta")) {
        if (buildDiffSummary(root, .incremental, request.stream_context, on_stream_event)) {
            return;
        }
    }

    if (std.mem.indexOf(u8, method, "toolCall") != null or
        std.mem.indexOf(u8, method, "exec") != null or
        std.mem.eql(u8, method, "command/exec"))
    {
        if (extractCommandSummary(root)) |command| {
            on_stream_event(request.stream_context, .{ .message = .{
                .title = "Ran command",
                .body = command,
            } });
            return;
        }

        on_stream_event(request.stream_context, .{ .message = .{
            .title = "Tool call",
            .body = method,
        } });
    }
}

// Long-running items surface as structured tool-call lifecycle updates
// (started -> in_progress, completed -> completed/failed) keyed by the Codex
// item id, so the transcript shows work while it runs instead of staying on
// "Waiting for streamed output..." until each item finishes. Titles stay empty
// for execute/think/search kinds so the shared upsert derives the contract
// authors ("Ran command", "Command failed", "Think", ...) and compact rows.
fn emitItemEvent(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) !bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    const params = getObjectField(root, "params") orelse return false;
    const item = getObjectField(params, "item") orelse return false;
    const item_type = getOptionalObjectString(item, "type") orelse return false;
    const started = std.mem.eql(u8, method, "item/started");

    if (std.mem.eql(u8, item_type, "commandExecution")) {
        const command = getOptionalObjectString(item, "command") orelse return false;
        const call_id = getOptionalObjectString(item, "id") orelse "";
        if (started) {
            on_stream_event(context, .{ .tool_call = .{
                .call_id = call_id,
                .title = "",
                .kind = .execute,
                .status = .in_progress,
                .input = command,
            } });
            return true;
        }
        const status = getOptionalObjectString(item, "status") orelse "completed";
        const output = try formatCommandExecutionOutputAlloc(allocator, item);
        defer if (output) |text| allocator.free(text);
        on_stream_event(context, .{ .tool_call = .{
            .call_id = call_id,
            .title = "",
            .kind = .execute,
            .status = toolCallStatusFromCodex(status),
            .input = command,
            .output = output,
        } });
        return true;
    }

    if (std.mem.eql(u8, item_type, "mcpToolCall"))
        return emitMcpToolCallItem(allocator, item, started, context, on_stream_event);

    if (std.mem.eql(u8, item_type, "collabAgentToolCall"))
        return emitCollabAgentToolCallItem(item, started, context, on_stream_event);

    if (std.mem.eql(u8, item_type, "subAgentActivity"))
        return emitSubAgentActivityItem(item, context, on_stream_event);

    if (std.mem.eql(u8, item_type, "reasoning")) {
        const call_id = getOptionalObjectString(item, "id") orelse return false;
        // Reasoning surfaces only as a transient "Thinking" liveness row: no
        // summary output is attached, so the shared upsert removes the row
        // again once the terminal status lands.
        on_stream_event(context, .{ .tool_call = .{
            .call_id = call_id,
            .title = "",
            .kind = .think,
            .status = if (started) .in_progress else .completed,
        } });
        return true;
    }

    if (std.mem.eql(u8, item_type, "webSearch")) {
        const call_id = getOptionalObjectString(item, "id") orelse return false;
        const query = getOptionalObjectString(item, "query") orelse "";
        on_stream_event(context, .{ .tool_call = .{
            .call_id = call_id,
            .title = "",
            .kind = .search,
            .status = if (started) .in_progress else .completed,
            .input = if (query.len > 0) query else null,
        } });
        return true;
    }

    if (std.mem.eql(u8, item_type, "fileChange")) {
        const call_id = getOptionalObjectString(item, "id") orelse "";
        const status = getOptionalObjectString(item, "status") orelse if (started) "inProgress" else "completed";
        const changes = getObjectField(item, "changes");
        const input = if (changes) |value|
            try buildImportedFileChangeSummaryAlloc(allocator, value)
        else
            null;
        defer if (input) |text| allocator.free(text);
        on_stream_event(context, .{ .tool_call = .{
            .call_id = call_id,
            .title = "",
            .kind = .edit,
            .status = if (started) .in_progress else toolCallStatusFromCodex(status),
            .input = if (input) |text| if (text.len > 0) text else null else null,
        } });
        if (started) return true;
        if (buildFileChangeItemSummary(item, context, on_stream_event)) {
            return true;
        }
        return true;
    }

    if (std.mem.eql(u8, item_type, "contextCompaction")) {
        if (!std.mem.eql(u8, method, "item/completed")) return false;
        on_stream_event(context, .{ .message = .{
            .title = "Context compacted",
            .body = "Codex summarized earlier conversation context to make room for the rest of this turn.",
        } });
        return true;
    }

    return false;
}

fn emitMcpToolCallItem(
    allocator: std.mem.Allocator,
    item: std.json.Value,
    started: bool,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) !bool {
    var label_buf: [512]u8 = undefined;
    const label = formatMcpToolCallLabel(&label_buf, item) orelse return false;
    const call_id = getOptionalObjectString(item, "id") orelse "";
    if (started) {
        on_stream_event(context, .{ .tool_call = .{
            .call_id = call_id,
            .title = "",
            .kind = .mcp,
            .status = .in_progress,
            .input = label,
        } });
        return true;
    }

    const status = getOptionalObjectString(item, "status") orelse return false;
    if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "failed")) return true;
    const output = try formatMcpToolCallOutputAlloc(allocator, item);
    defer if (output) |text| allocator.free(text);
    const error_text = if (getObjectField(item, "error")) |error_value|
        getOptionalObjectString(error_value, "message")
    else
        null;
    on_stream_event(context, .{ .tool_call = .{
        .call_id = call_id,
        .title = "",
        .kind = .mcp,
        .status = toolCallStatusFromCodex(status),
        .input = label,
        .output = output,
        .error_text = error_text,
    } });
    return true;
}

fn emitHydratedMcpToolOutputsFromThreadValue(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    turn_id: ?[]const u8,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) !usize {
    const thread = getObjectField(root, "thread") orelse return 0;
    const turns = getObjectField(thread, "turns") orelse return 0;
    if (turns != .array or turns.array.items.len == 0) return 0;

    var selected_turn: std.json.Value = turns.array.items[turns.array.items.len - 1];
    if (turn_id) |expected_id| {
        for (turns.array.items) |turn| {
            const candidate_id = getOptionalObjectString(turn, "id") orelse continue;
            if (std.mem.eql(u8, candidate_id, expected_id)) {
                selected_turn = turn;
                break;
            }
        }
    }

    const items = getObjectField(selected_turn, "items") orelse return 0;
    if (items != .array) return 0;

    var emitted: usize = 0;
    for (items.array.items) |item| {
        const item_type = getOptionalObjectString(item, "type") orelse continue;
        if (!std.mem.eql(u8, item_type, "mcpToolCall")) continue;
        if (try emitMcpToolCallItem(allocator, item, false, context, on_stream_event)) emitted += 1;
    }
    return emitted;
}

fn isMcpToolCallNotification(root: std.json.Value) bool {
    const method = getOptionalObjectString(root, "method") orelse return false;
    if (!std.mem.eql(u8, method, "item/started") and !std.mem.eql(u8, method, "item/completed")) return false;
    const params = getObjectField(root, "params") orelse return false;
    const item = getObjectField(params, "item") orelse return false;
    const item_type = getOptionalObjectString(item, "type") orelse return false;
    return std.mem.eql(u8, item_type, "mcpToolCall");
}

fn toolCallStatusFromCodex(status: []const u8) provider_types.ToolCallStatus {
    if (std.mem.eql(u8, status, "failed")) return .failed;
    if (std.mem.eql(u8, status, "declined") or std.mem.eql(u8, status, "cancelled")) return .cancelled;
    return .completed;
}

/// The command itself travels in the tool-call `input` field; this collects
/// the remaining execution details for the `output` field.
fn formatCommandExecutionOutputAlloc(allocator: std.mem.Allocator, item: std.json.Value) !?[]u8 {
    const output = getOptionalObjectString(item, "aggregatedOutput") orelse "";
    const cwd = getOptionalObjectString(item, "cwd") orelse "";
    const exit_code = getOptionalObjectInteger(item, "exitCode");
    const duration = getOptionalObjectInteger(item, "durationMs");
    if (output.len == 0 and cwd.len == 0 and exit_code == null and duration == null) return null;
    return try std.fmt.allocPrint(allocator, "CWD: {s}\nExit code: {d}\nDuration ms: {d}\n\n{s}", .{
        cwd, exit_code orelse -1, duration orelse -1, output,
    });
}

fn formatMcpToolCallLabel(buffer: []u8, item: std.json.Value) ?[]const u8 {
    const server = getOptionalObjectString(item, "server") orelse return null;
    const tool = getOptionalObjectString(item, "tool") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}.{s}", .{ server, tool }) catch tool;
}

/// Extracts readable MCP text results while retaining structured-only data.
fn formatMcpToolCallOutputAlloc(allocator: std.mem.Allocator, item: std.json.Value) !?[]u8 {
    const result = getObjectField(item, "result") orelse return null;
    if (result == .null) return null;

    if (getObjectField(result, "content")) |content| {
        if (content == .array) {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            errdefer writer.deinit();
            var wrote = false;
            for (content.array.items) |content_item| {
                const text = getOptionalObjectString(content_item, "text") orelse continue;
                if (text.len == 0) continue;
                if (wrote) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text);
                wrote = true;
            }
            if (wrote) return try writer.toOwnedSlice();
            writer.deinit();
        }
    }

    if (getObjectField(result, "structuredContent")) |structured| {
        if (structured != .null) return try stringifyAlloc(allocator, structured);
    }
    return try stringifyAlloc(allocator, result);
}

fn firstReceiverThreadId(item: std.json.Value) ?[]const u8 {
    const field = getObjectField(item, "receiverThreadIds") orelse getObjectField(item, "receiver_thread_ids") orelse return null;
    if (field != .array or field.array.items.len == 0) return null;
    return stringValue(field.array.items[0]);
}

fn collabAgentCallId(item: std.json.Value) []const u8 {
    return firstReceiverThreadId(item) orelse
        getOptionalObjectString(item, "id") orelse
        "";
}

fn collabAgentStatus(item: std.json.Value, started: bool) provider_types.ToolCallStatus {
    if (started) return .in_progress;
    const status = getOptionalObjectString(item, "status") orelse return .completed;
    if (std.mem.eql(u8, status, "inProgress") or std.mem.eql(u8, status, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, status, "failed")) return .failed;
    if (std.mem.eql(u8, status, "interrupted")) return .cancelled;
    return .completed;
}

fn emitCollabAgentToolCallItem(
    item: std.json.Value,
    started: bool,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const tool = getOptionalObjectString(item, "tool") orelse "";
    // Spawn/resume are child-agent lifecycle. Wait/send/list are parent
    // orchestration around an already-visible child and would duplicate rows.
    const is_child_lifecycle = std.mem.eql(u8, tool, "spawnAgent") or
        std.mem.eql(u8, tool, "resumeAgent") or
        tool.len == 0;
    if (!is_child_lifecycle) return true;

    const call_id = collabAgentCallId(item);
    if (call_id.len == 0) return false;
    const prompt = getOptionalObjectString(item, "prompt");
    const model = getOptionalObjectString(item, "model");
    const input = if (prompt) |text|
        text
    else if (model) |text|
        text
    else
        tool;
    const error_text = if (getObjectField(item, "error")) |error_value|
        getOptionalObjectString(error_value, "message")
    else
        null;
    on_stream_event(context, .{ .tool_call = .{
        .call_id = call_id,
        .title = if (prompt) |text| text else "Codex subagent",
        .kind = .subagent,
        .status = collabAgentStatus(item, started),
        .input = if (input.len > 0) input else null,
        .error_text = error_text,
    } });
    return true;
}

fn emitSubAgentActivityItem(
    item: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const call_id = getOptionalObjectString(item, "agentThreadId") orelse
        getOptionalObjectString(item, "id") orelse
        return false;
    const kind = getOptionalObjectString(item, "kind") orelse "";
    const status: provider_types.ToolCallStatus = if (std.mem.eql(u8, kind, "completed"))
        .completed
    else if (std.mem.eql(u8, kind, "interrupted"))
        .cancelled
    else
        .in_progress;
    const path = getOptionalObjectString(item, "agentPath") orelse "Codex subagent";
    on_stream_event(context, .{ .tool_call = .{
        .call_id = call_id,
        .title = path,
        .kind = .subagent,
        .status = status,
        .input = path,
    } });
    return true;
}

fn handleCommandApprovalRequest(self: *Client, root: std.json.Value, request_id: std.json.Value, request: provider_types.SendPromptRequest) !void {
    const decision = if (shouldAutoApproveRequest(request))
        .approve
    else blk: {
        const on_approval_request = request.on_approval_request orelse break :blk .deny;
        const body = extractCommandApprovalSummary(root) orelse "Codex requested command approval.";
        const call_id = try serverRequestApprovalIdAlloc(self.allocator, request_id);
        defer self.allocator.free(call_id);
        break :blk on_approval_request(request.stream_context, .{
            .call_id = call_id,
            .title = "Command approval",
            .body = body,
        });
    };

    try respondToServerRequest(request_id, self, .{
        .decision = approvalDecisionString(decision),
    });
}

fn handleFileChangeApprovalRequest(self: *Client, root: std.json.Value, request_id: std.json.Value, request: provider_types.SendPromptRequest) !void {
    const decision = if (shouldAutoApproveRequest(request))
        .approve
    else blk: {
        const on_approval_request = request.on_approval_request orelse break :blk .deny;
        const body = extractFileChangeApprovalSummary(root) orelse "Codex requested file change approval.";
        const call_id = try serverRequestApprovalIdAlloc(self.allocator, request_id);
        defer self.allocator.free(call_id);
        break :blk on_approval_request(request.stream_context, .{
            .call_id = call_id,
            .title = "File change approval",
            .body = body,
        });
    };

    try respondToServerRequest(request_id, self, .{
        .decision = approvalDecisionString(decision),
    });
}

fn handlePermissionsApprovalRequest(self: *Client, root: std.json.Value, request_id: std.json.Value, request: provider_types.SendPromptRequest) !void {
    const decision = if (shouldAutoApproveRequest(request))
        .approve
    else blk: {
        const on_approval_request = request.on_approval_request orelse break :blk .deny;
        const body = extractPermissionsApprovalSummary(root) orelse "Codex requested additional permissions.";
        const call_id = try serverRequestApprovalIdAlloc(self.allocator, request_id);
        defer self.allocator.free(call_id);
        break :blk on_approval_request(request.stream_context, .{
            .call_id = call_id,
            .title = "Permissions request",
            .body = body,
        });
    };

    try respondToServerRequest(request_id, self, .{
        .decision = approvalDecisionString(decision),
    });
}

fn handleMcpElicitationRequest(
    self: *Client,
    root: std.json.Value,
    request_id: std.json.Value,
    request: provider_types.SendPromptRequest,
) !void {
    const params = getObjectField(root, "params") orelse .null;
    const elicitation = getObjectField(params, "request") orelse params;
    const mode = getOptionalObjectString(elicitation, "mode") orelse "form";
    const message = getOptionalObjectString(elicitation, "message") orelse "Codex requested additional input.";
    const server_name = getOptionalObjectString(params, "serverName") orelse "MCP server";

    // Verde currently supports the binary confirmation subset of form
    // elicitations. Structured forms must be declined because accepting them
    // without schema-valid content would terminate the turn with a protocol
    // error in app-server.
    if (!std.mem.eql(u8, mode, "form") and !std.mem.eql(u8, mode, "openai/form")) {
        try respondMcpElicitation(request_id, self, .deny);
        return;
    }
    const schema = getObjectField(elicitation, "requestedSchema") orelse .null;
    if (!mcpElicitationAllowsEmptyContent(schema)) {
        if (request.on_stream_event) |on_stream_event| {
            on_stream_event(request.stream_context, .{ .message = .{
                .title = "Input request unsupported",
                .body = message,
            } });
        }
        try respondMcpElicitation(request_id, self, .deny);
        return;
    }

    const decision = if (request.on_approval_request) |on_approval_request| blk: {
        const call_id = try serverRequestApprovalIdAlloc(self.allocator, request_id);
        defer self.allocator.free(call_id);
        break :blk on_approval_request(request.stream_context, .{
            .call_id = call_id,
            .title = server_name,
            .body = message,
        });
    } else .deny;
    try respondMcpElicitation(request_id, self, decision);
}

fn serverRequestApprovalIdAlloc(allocator: std.mem.Allocator, request_id: std.json.Value) ![]u8 {
    return switch (request_id) {
        .integer => |value| std.fmt.allocPrint(allocator, "rpc-int:{d}", .{value}),
        .string => |value| std.fmt.allocPrint(allocator, "rpc-string:{s}", .{value}),
        else => error.InvalidServerRequestId,
    };
}

fn mcpElicitationAllowsEmptyContent(schema: std.json.Value) bool {
    if (schema == .null) return true;
    if (schema != .object) return false;
    const required = schema.object.get("required") orelse return true;
    return required == .array and required.array.items.len == 0;
}

fn respondMcpElicitation(
    request_id: std.json.Value,
    self: *Client,
    decision: provider_types.ApprovalDecision,
) !void {
    switch (decision) {
        .approve => try respondToServerRequest(request_id, self, .{
            .action = "accept",
            .content = .{},
            ._meta = @as(?u8, null),
        }),
        .deny => try respondToServerRequest(request_id, self, .{
            .action = "decline",
            .content = @as(?u8, null),
            ._meta = @as(?u8, null),
        }),
    }
}

fn handleDynamicToolCallRequest(
    self: *Client,
    root: std.json.Value,
    request_id: std.json.Value,
    request: provider_types.SendPromptRequest,
) !void {
    const params = getObjectField(root, "params") orelse .null;
    const tool = getOptionalObjectString(params, "tool") orelse "unknown";
    const message = try std.fmt.allocPrint(
        self.allocator,
        "Verde cannot execute client-hosted Codex tool `{s}`. Continue without it or use built-in Codex tools instead.",
        .{tool},
    );
    defer self.allocator.free(message);

    if (request.on_stream_event) |on_stream_event| {
        on_stream_event(request.stream_context, .{ .message = .{
            .title = "Tool unavailable",
            .body = message,
        } });
    }

    const payload = try dynamicToolFailurePayloadAlloc(self.allocator, request_id, message);
    defer self.allocator.free(payload);
    try self.writeTextMessage(payload);
}

fn handleUnsupportedServerRequest(
    self: *Client,
    method: []const u8,
    request_id: std.json.Value,
    request: provider_types.SendPromptRequest,
) !void {
    const message = try std.fmt.allocPrint(self.allocator, "Unsupported Codex app-server request: {s}", .{method});
    defer self.allocator.free(message);
    runtime_log.diagnostic("Codex server request unsupported method={s}", .{method});

    if (request.on_stream_event) |on_stream_event| {
        on_stream_event(request.stream_context, .{ .message = .{
            .title = "Codex request unsupported",
            .body = message,
        } });
    }

    try respondServerError(request_id, self, JSON_RPC_METHOD_NOT_FOUND, message);
}

fn dynamicToolFailurePayloadAlloc(allocator: std.mem.Allocator, request_id: std.json.Value, message: []const u8) ![]u8 {
    const ContentItem = struct {
        type: []const u8,
        text: []const u8,
    };
    const content_items = [_]ContentItem{.{
        .type = "inputText",
        .text = message,
    }};
    return stringifyAlloc(allocator, .{
        .id = request_id,
        .result = .{
            .success = false,
            .contentItems = &content_items,
        },
    });
}

fn respondToServerRequest(request_id: std.json.Value, self: *Client, result: anytype) !void {
    const payload = try stringifyAlloc(self.allocator, .{
        .id = request_id,
        .result = result,
    });
    defer self.allocator.free(payload);
    try self.writeTextMessage(payload);
}

fn serverErrorPayloadAlloc(allocator: std.mem.Allocator, request_id: std.json.Value, code: i64, message: []const u8) ![]u8 {
    return stringifyAlloc(allocator, .{
        .id = request_id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    });
}

fn respondServerError(request_id: std.json.Value, self: *Client, code: i64, message: []const u8) !void {
    const payload = try serverErrorPayloadAlloc(self.allocator, request_id, code, message);
    defer self.allocator.free(payload);
    try self.writeTextMessage(payload);
}

fn buildDiffSummary(
    root: std.json.Value,
    scope: provider_types.StreamDiffScope,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const params = getObjectField(root, "params") orelse return false;
    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);

    if (!appendDiffFiles(params, &files)) return false;
    on_stream_event(context, .{ .diff = .{
        .files = files.items,
        .scope = scope,
    } });
    return true;
}

fn buildFileChangeItemSummary(
    item: std.json.Value,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const changes = getObjectField(item, "changes") orelse return false;
    var files: std.ArrayList(provider_types.StreamDiffFile) = .empty;
    defer files.deinit(std.heap.page_allocator);

    if (!appendDiffFiles(changes, &files)) return false;
    on_stream_event(context, .{ .diff = .{
        .files = files.items,
    } });
    return true;
}

fn appendDiffFiles(value: std.json.Value, files: *std.ArrayList(provider_types.StreamDiffFile)) bool {
    switch (value) {
        .object => |obj| {
            if (extractPathFromValue(value)) |path| {
                const additions = findFirstIntegerByField(value, "additions") orelse
                    findFirstIntegerByField(value, "addedLines") orelse
                    findFirstIntegerByField(value, "added") orelse
                    countDiffLines(value, '+');
                const deletions = findFirstIntegerByField(value, "deletions") orelse
                    findFirstIntegerByField(value, "removedLines") orelse
                    findFirstIntegerByField(value, "removed") orelse
                    countDiffLines(value, '-');
                const patch = findFirstStringByField(value, "diff") orelse
                    findFirstStringByField(value, "patch");

                appendOrReplaceDiffFile(files, .{
                    .path = path,
                    .additions = additions,
                    .deletions = deletions,
                    .patch = patch,
                }) catch return false;
            }

            var found = false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                found = appendDiffFiles(entry.value_ptr.*, files) or found;
            }
            return found or extractPathFromValue(value) != null;
        },
        .array => |arr| {
            var found = false;
            for (arr.items) |item| {
                found = appendDiffFiles(item, files) or found;
            }
            return found;
        },
        else => return false,
    }
}

fn appendOrReplaceDiffFile(
    files: *std.ArrayList(provider_types.StreamDiffFile),
    next: provider_types.StreamDiffFile,
) !void {
    for (files.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, next.path)) continue;

        existing.additions = next.additions;
        existing.deletions = next.deletions;
        existing.patch = next.patch;
        return;
    }

    try files.append(std.heap.page_allocator, next);
}

fn appendChangedFiles(value: std.json.Value, lines: *std.ArrayList(u8)) bool {
    switch (value) {
        .object => |obj| {
            if (obj.get("path")) |path_value| {
                if (stringValue(path_value)) |path| {
                    appendChangedFileLine(lines, path, value);
                    return true;
                }
            }
            if (obj.get("filePath")) |path_value| {
                if (stringValue(path_value)) |path| {
                    appendChangedFileLine(lines, path, value);
                    return true;
                }
            }

            var found = false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                found = appendChangedFiles(entry.value_ptr.*, lines) or found;
            }
            return found;
        },
        .array => |arr| {
            var found = false;
            for (arr.items) |item| {
                found = appendChangedFiles(item, lines) or found;
            }
            return found;
        },
        else => return false,
    }
}

fn appendChangedFileLine(lines: *std.ArrayList(u8), path: []const u8, value: std.json.Value) void {
    const additions = findFirstIntegerByField(value, "additions") orelse
        findFirstIntegerByField(value, "addedLines") orelse
        findFirstIntegerByField(value, "added") orelse
        countDiffLines(value, '+');
    const deletions = findFirstIntegerByField(value, "deletions") orelse
        findFirstIntegerByField(value, "removedLines") orelse
        findFirstIntegerByField(value, "removed") orelse
        countDiffLines(value, '-');

    if (lines.items.len > 0) {
        lines.append(std.heap.page_allocator, '\n') catch return;
    }
    const line = std.fmt.allocPrint(std.heap.page_allocator, "{s}  +{d} / -{d}", .{ path, additions, deletions }) catch return;
    defer std.heap.page_allocator.free(line);
    lines.appendSlice(std.heap.page_allocator, line) catch return;
}

fn extractPathFromValue(value: std.json.Value) ?[]const u8 {
    if (getObjectField(value, "path")) |path_value| {
        if (stringValue(path_value)) |path| return path;
    }
    if (getObjectField(value, "filePath")) |path_value| {
        if (stringValue(path_value)) |path| return path;
    }
    return null;
}

fn extractCommandSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "command") orelse
        findFirstStringByField(params, "rawInput") orelse
        findFirstStringByField(params, "cmd") orelse
        findFirstStringByField(params, "commandLine");
}

fn extractCommandApprovalSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "command") orelse
        findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "cwd") orelse
        findFirstStringByField(params, "title") orelse
        findFirstStringByField(params, "message");
}

fn extractFileChangeApprovalSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "grantRoot") orelse
        findFirstStringByField(params, "title") orelse
        findFirstStringByField(params, "message");
}

fn extractPermissionsApprovalSummary(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    return findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "reason") orelse
        findFirstStringByField(params, "title") orelse
        findFirstStringByField(params, "message");
}

const TurnTerminalState = enum {
    completed,
    failed,
    interrupted,
};

fn extractTurnIdFromStartResponse(root: std.json.Value) ?[]const u8 {
    const result = getObjectField(root, "result") orelse return null;
    const turn = getObjectField(result, "turn") orelse return null;
    return getOptionalObjectString(turn, "id");
}

fn extractTurnIdFromStartedNotification(root: std.json.Value, thread_id: []const u8) ?[]const u8 {
    const method = getOptionalObjectString(root, "method") orelse return null;
    if (!std.mem.eql(u8, method, "turn/started")) return null;

    const params = getObjectField(root, "params") orelse return null;
    const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return null;
    if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;

    const turn = getObjectField(params, "turn") orelse return null;
    return getOptionalObjectString(turn, "id");
}

fn detectTurnTerminalState(root: std.json.Value, thread_id: []const u8, turn_id: ?[]const u8) ?TurnTerminalState {
    const method = getOptionalObjectString(root, "method") orelse return null;
    const params = getObjectField(root, "params") orelse return null;

    if (std.mem.eql(u8, method, "turn/completed")) {
        const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return null;
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;

        const turn = getObjectField(params, "turn") orelse return null;
        if (turn_id) |expected_turn_id| {
            const completed_turn_id = getOptionalObjectString(turn, "id") orelse return null;
            if (!std.mem.eql(u8, completed_turn_id, expected_turn_id)) return null;
        }

        const status = getOptionalObjectString(turn, "status") orelse return .completed;
        if (std.mem.eql(u8, status, "completed")) return .completed;
        if (std.mem.eql(u8, status, "failed")) return .failed;
        if (std.mem.eql(u8, status, "interrupted")) return .interrupted;
        return null;
    }

    if (std.mem.eql(u8, method, "thread/status/changed")) {
        const notification_thread_id = getOptionalObjectString(params, "threadId") orelse return null;
        if (!std.mem.eql(u8, notification_thread_id, thread_id)) return null;

        const status = getObjectField(params, "status") orelse return null;
        const type_name = getOptionalObjectString(status, "type") orelse return null;
        if (std.mem.eql(u8, type_name, "idle")) return .completed;
    }

    return null;
}

fn extractTurnFailureMessage(root: std.json.Value) ?[]const u8 {
    const params = getObjectField(root, "params") orelse return null;
    const turn = getObjectField(params, "turn") orelse return null;
    const error_value = getObjectField(turn, "error") orelse return null;
    return getOptionalObjectString(error_value, "message");
}

fn emitTurnFailure(root: std.json.Value, request: provider_types.SendPromptRequest) void {
    const on_failure = request.on_failure orelse return;
    const message = extractTurnFailureMessage(root) orelse return;
    on_failure(request.stream_context, message);
}

fn findFirstStringByPath(value: std.json.Value, fields: []const []const u8) ?[]const u8 {
    var current = value;
    for (fields) |field| {
        current = getObjectField(current, field) orelse return null;
    }
    return stringValue(current);
}

fn findFirstStringByField(value: std.json.Value, field: []const u8) ?[]const u8 {
    switch (value) {
        .object => |obj| {
            if (obj.get(field)) |candidate| {
                if (stringValue(candidate)) |text| return text;
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findFirstStringByField(entry.value_ptr.*, field)) |text| return text;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findFirstStringByField(item, field)) |text| return text;
            }
            return null;
        },
        else => return null,
    }
}

fn findFirstIntegerByField(value: std.json.Value, field: []const u8) ?i64 {
    switch (value) {
        .object => |obj| {
            if (obj.get(field)) |candidate| {
                switch (candidate) {
                    .integer => |number| return number,
                    else => {},
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findFirstIntegerByField(entry.value_ptr.*, field)) |number| return number;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findFirstIntegerByField(item, field)) |number| return number;
            }
            return null;
        },
        else => return null,
    }
}

fn countDiffLines(value: std.json.Value, prefix: u8) i64 {
    const diff = findFirstStringByField(value, "diff") orelse return 0;
    var count: i64 = 0;
    var it = std.mem.tokenizeScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != prefix) continue;
        if (line.len >= 3 and std.mem.eql(u8, line[0..3], if (prefix == '+') "+++" else "---")) continue;
        count += 1;
    }
    return count;
}

fn approvalPolicyString(value: provider_types.ApprovalPolicy) []const u8 {
    return switch (value) {
        .on_request => "on-request",
        .never => "never",
    };
}

fn shouldAutoApproveRequest(request: provider_types.SendPromptRequest) bool {
    return (request.approval_policy orelse .on_request) == .never;
}

fn sandboxModeString(value: provider_types.SandboxMode) []const u8 {
    return switch (value) {
        .workspace_write => "workspace-write",
        .danger_full_access => "danger-full-access",
    };
}

fn writeTurnPolicyOverrides(
    stringify: *std.json.Stringify,
    request: provider_types.SendPromptRequest,
) !void {
    if (request.approval_policy) |approval_policy| {
        try stringify.objectField("approvalPolicy");
        try stringify.write(approvalPolicyString(approval_policy));
    }
    if (request.sandbox_mode) |sandbox_mode| {
        // thread/start accepts the legacy string-valued `sandbox`, while
        // turn/start requires a SandboxPolicy object. Sending it on every turn
        // keeps resumed threads aligned with Verde's current access picker.
        try stringify.objectField("sandboxPolicy");
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(switch (sandbox_mode) {
            .workspace_write => "workspaceWrite",
            .danger_full_access => "dangerFullAccess",
        });
        try stringify.endObject();
    }
}

test "turn policy overrides preserve supervised and full access on resumed threads" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        approval_policy: provider_types.ApprovalPolicy,
        sandbox_mode: provider_types.SandboxMode,
        expected_approval: []const u8,
        expected_sandbox_type: []const u8,
    }{
        .{ .approval_policy = .on_request, .sandbox_mode = .workspace_write, .expected_approval = "on-request", .expected_sandbox_type = "workspaceWrite" },
        .{ .approval_policy = .never, .sandbox_mode = .danger_full_access, .expected_approval = "never", .expected_sandbox_type = "dangerFullAccess" },
    };

    for (cases) |case| {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try stringify.beginObject();
        try writeTurnPolicyOverrides(&stringify, .{
            .prompt = "hi",
            .approval_policy = case.approval_policy,
            .sandbox_mode = case.sandbox_mode,
        });
        try stringify.endObject();
        const payload = try writer.toOwnedSlice();
        defer allocator.free(payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.expected_approval, parsed.value.object.get("approvalPolicy").?.string);
        try std.testing.expectEqualStrings(
            case.expected_sandbox_type,
            parsed.value.object.get("sandboxPolicy").?.object.get("type").?.string,
        );
    }
}

fn approvalDecisionString(value: provider_types.ApprovalDecision) []const u8 {
    return switch (value) {
        .approve => "accept",
        .deny => "decline",
    };
}

const TestFailureCapture = struct {
    message: ?[]const u8 = null,

    fn handle(context: ?*anyopaque, message: []const u8) void {
        const self: *TestFailureCapture = @ptrCast(@alignCast(context orelse return));
        self.message = message;
    }
};

const TestStreamEventCapture = struct {
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    message_count: usize = 0,
    title_storage: [128]u8 = undefined,
    body_storage: [1024]u8 = undefined,
    tool_call_count: usize = 0,
    tool_call_id: ?[]const u8 = null,
    tool_kind: ?provider_types.ToolCallKind = null,
    tool_status: ?provider_types.ToolCallStatus = null,
    tool_input: ?[]const u8 = null,
    tool_output: ?[]const u8 = null,
    diff_count: usize = 0,
    diff_path: ?[]const u8 = null,
    diff_patch: ?[]const u8 = null,
    diff_scope: ?provider_types.StreamDiffScope = null,
    tool_call_id_storage: [128]u8 = undefined,
    tool_input_storage: [1024]u8 = undefined,
    tool_output_storage: [1024]u8 = undefined,
    diff_path_storage: [512]u8 = undefined,
    diff_patch_storage: [2048]u8 = undefined,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *TestStreamEventCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .message => |message| {
                const title_len = @min(message.title.len, self.title_storage.len);
                const body_len = @min(message.body.len, self.body_storage.len);
                @memcpy(self.title_storage[0..title_len], message.title[0..title_len]);
                @memcpy(self.body_storage[0..body_len], message.body[0..body_len]);
                self.title = self.title_storage[0..title_len];
                self.body = self.body_storage[0..body_len];
                self.message_count += 1;
            },
            .tool_call => |tool_call| {
                const id_len = @min(tool_call.call_id.len, self.tool_call_id_storage.len);
                @memcpy(self.tool_call_id_storage[0..id_len], tool_call.call_id[0..id_len]);
                self.tool_call_id = self.tool_call_id_storage[0..id_len];
                self.tool_kind = tool_call.kind;
                self.tool_status = tool_call.status;
                if (tool_call.input) |input| {
                    const input_len = @min(input.len, self.tool_input_storage.len);
                    @memcpy(self.tool_input_storage[0..input_len], input[0..input_len]);
                    self.tool_input = self.tool_input_storage[0..input_len];
                } else {
                    self.tool_input = null;
                }
                if (tool_call.output) |output| {
                    const output_len = @min(output.len, self.tool_output_storage.len);
                    @memcpy(self.tool_output_storage[0..output_len], output[0..output_len]);
                    self.tool_output = self.tool_output_storage[0..output_len];
                } else {
                    self.tool_output = null;
                }
                self.tool_call_count += 1;
            },
            .diff => |diff| {
                if (diff.files.len == 0) return;
                self.diff_scope = diff.scope;
                const file = diff.files[0];
                const path_len = @min(file.path.len, self.diff_path_storage.len);
                @memcpy(self.diff_path_storage[0..path_len], file.path[0..path_len]);
                self.diff_path = self.diff_path_storage[0..path_len];
                if (file.patch) |patch| {
                    const patch_len = @min(patch.len, self.diff_patch_storage.len);
                    @memcpy(self.diff_patch_storage[0..patch_len], patch[0..patch_len]);
                    self.diff_patch = self.diff_patch_storage[0..patch_len];
                }
                self.diff_count += 1;
            },
        }
    }
};

test "build request target preserves path and query" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("ws://127.0.0.1:4500/rpc?client=native");
    const target = try buildRequestTargetAlloc(allocator, uri);
    defer allocator.free(target);

    try std.testing.expectEqualStrings("/rpc?client=native", target);
}

test "turn steer payload preserves multiple local images" {
    const allocator = std.testing.allocator;
    const images = [_]provider_types.ImageAttachment{
        .{ .path = "/tmp/first.png" },
        .{ .path = "/tmp/second.jpg" },
    };
    const payload = try turnSteerRequestPayloadAlloc(allocator, 17, .{
        .thread_id = "thread-1",
        .turn_id = "turn-1",
        .prompt = "compare these",
        .images = &images,
    });
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    const input = params.object.get("input").?;
    try std.testing.expectEqual(@as(usize, 3), input.array.items.len);
    try std.testing.expectEqualStrings("text", input.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("localImage", input.array.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("/tmp/first.png", input.array.items[1].object.get("path").?.string);
    try std.testing.expectEqualStrings("/tmp/second.jpg", input.array.items[2].object.get("path").?.string);
}

test "turn steer mismatch extracts the server active turn id" {
    try std.testing.expectEqualStrings(
        "turn-current",
        extractActualTurnIdFromSteerMismatch("expected active turn id `turn-stale` but found `turn-current`").?,
    );
    try std.testing.expect(extractActualTurnIdFromSteerMismatch("no active turn to steer") == null);
    try std.testing.expect(extractActualTurnIdFromSteerMismatch("expected active turn id `old` but found ``") == null);
}

test "compute accept key matches websocket example" {
    const allocator = std.testing.allocator;
    const accept = try computeAcceptKeyAlloc(allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer allocator.free(accept);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "appendImportedMessagesForItem maps transcript items into chat messages" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {
        \\    "type": "userMessage",
        \\    "id": "u1",
        \\    "content": [
        \\      { "type": "text", "text": "Look at this" },
        \\      { "type": "localImage", "path": "/tmp/screenshot.png" }
        \\    ]
        \\  },
        \\  {
        \\    "type": "agentMessage",
        \\    "id": "a1",
        \\    "text": "I checked it."
        \\  },
        \\  {
        \\    "type": "commandExecution",
        \\    "id": "c1",
        \\    "command": "git status",
        \\    "status": "completed"
        \\  },
        \\  {
        \\    "type": "mcpToolCall",
        \\    "id": "m1",
        \\    "server": "verde",
        \\    "tool": "capture_browser_screenshot",
        \\    "status": "completed"
        \\  },
        \\  {
        \\    "type": "fileChange",
        \\    "id": "f1",
        \\    "changes": [
        \\      {
        \\        "path": "src/main.zig",
        \\        "diff": "@@ -1 +1 @@\n-old\n+new\n"
        \\      }
        \\    ]
        \\  }
        \\]
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var messages: std.ArrayList(provider_types.ChatMessage) = .empty;
    defer {
        for (messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        messages.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        try appendImportedMessagesForItem(allocator, item, &messages);
    }

    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expectEqual(provider_types.MessageRole.user, messages.items[0].role);
    try std.testing.expectEqualStrings("You", messages.items[0].author);
    try std.testing.expectEqualStrings("Look at this\n\n[Image: /tmp/screenshot.png]", messages.items[0].body);
    try std.testing.expectEqual(provider_types.MessageRole.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("Codex", messages.items[1].author);
    try std.testing.expectEqualStrings("I checked it.", messages.items[1].body);
    try std.testing.expectEqualStrings("Ran command", messages.items[2].author);
    try std.testing.expectEqualStrings("git status", messages.items[2].body);
    try std.testing.expectEqualStrings("Ran command", messages.items[3].author);
    try std.testing.expectEqualStrings("verde.capture_browser_screenshot", messages.items[3].body);
    try std.testing.expectEqualStrings("Changed files", messages.items[4].author);
    try std.testing.expectEqualStrings("src/main.zig  +1 / -1", messages.items[4].body);
}

test "formatUsageSummaryAlloc renders concise usage summary" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "summary": {
        \\    "lifetimeTokens": 9827869446,
        \\    "peakDailyTokens": 680466423,
        \\    "longestRunningTurnSec": 72844,
        \\    "currentStreakDays": 5,
        \\    "longestStreakDays": 49
        \\  },
        \\  "dailyUsageBuckets": [
        \\    { "startDate": "2026-06-12", "tokens": 1000 },
        \\    { "startDate": "2026-06-13", "tokens": 2000000 },
        \\    { "startDate": "2026-06-14", "tokens": 3000000 },
        \\    { "startDate": "2026-06-15", "tokens": 4000000 },
        \\    { "startDate": "2026-06-16", "tokens": 5000000 },
        \\    { "startDate": "2026-06-17", "tokens": 680466423 },
        \\    { "startDate": "2026-06-18", "tokens": 7000000 },
        \\    { "startDate": "2026-06-19", "tokens": 8000000 }
        \\  ]
        \\}
    ;

    const body = try formatUsageSummaryAlloc(allocator, json, null);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Lifetime tokens: 9.8 B tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Peak day: 680.4 M tokens on 2026-06-17") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Current streak: 5 days (longest 49)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Longest turn: 20h 14m") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026-06-12") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026-06-19: 8 M tokens") != null);
}

test "formatGoalSummaryAlloc renders active goal" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "goal": {
        \\    "objective": "Ship GUI slash commands",
        \\    "status": "active",
        \\    "tokenBudget": 12000
        \\  }
        \\}
    ;

    const body = try formatGoalSummaryAlloc(allocator, json);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Codex goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Status: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Objective: Ship GUI slash commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Token budget: 12000") != null);
}

test "formatGoalSummaryAlloc renders empty goal" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "goal": null
        \\  }
        \\}
    ;

    const body = try formatGoalSummaryAlloc(allocator, json);
    defer allocator.free(body);

    try std.testing.expectEqualStrings("Codex goal\n\nNo active Codex goal.", body);
}

test "writeReviewTarget serializes supported target shapes" {
    const allocator = std.testing.allocator;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeReviewTarget(&stringify, "");
    const changes = try writer.toOwnedSlice();
    defer allocator.free(changes);
    try std.testing.expectEqualStrings("{\"type\":\"uncommittedChanges\"}", changes);

    var base_writer: std.Io.Writer.Allocating = .init(allocator);
    defer base_writer.deinit();
    var base_stringify: std.json.Stringify = .{ .writer = &base_writer.writer, .options = .{} };
    try writeReviewTarget(&base_stringify, "base main");
    const base = try base_writer.toOwnedSlice();
    defer allocator.free(base);
    try std.testing.expectEqualStrings("{\"type\":\"baseBranch\",\"branch\":\"main\"}", base);

    var commit_writer: std.Io.Writer.Allocating = .init(allocator);
    defer commit_writer.deinit();
    var commit_stringify: std.json.Stringify = .{ .writer = &commit_writer.writer, .options = .{} };
    try writeReviewTarget(&commit_stringify, "commit abc123 Polish slash commands");
    const commit = try commit_writer.toOwnedSlice();
    defer allocator.free(commit);
    try std.testing.expectEqualStrings("{\"type\":\"commit\",\"sha\":\"abc123\",\"title\":\"Polish slash commands\"}", commit);
}

test "confirmedShellCommand requires explicit confirmation" {
    try std.testing.expect(confirmedShellCommand("git status") == null);
    try std.testing.expect(confirmedShellCommand("confirm") == null);
    try std.testing.expect(confirmedShellCommand("confirmed git status") == null);
    try std.testing.expectEqualStrings("git status --short", confirmedShellCommand(" confirm git status --short ").?);
}

test "formatUsageSummaryAlloc includes remaining rate limits" {
    const allocator = std.testing.allocator;
    const usage_json =
        \\{
        \\  "summary": { "lifetimeTokens": 1000 },
        \\  "dailyUsageBuckets": []
        \\}
    ;
    const rate_json =
        \\{
        \\  "rateLimits": {
        \\    "limitId": "codex",
        \\    "limitName": null,
        \\    "primary": { "usedPercent": 10, "windowDurationMins": 300 },
        \\    "secondary": { "usedPercent": 2, "windowDurationMins": 10080 },
        \\    "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
        \\  },
        \\  "rateLimitsByLimitId": {
        \\    "codex_bengalfox": {
        \\      "limitId": "codex_bengalfox",
        \\      "limitName": "GPT-5.3-Codex-Spark",
        \\      "primary": { "usedPercent": 0, "windowDurationMins": 300 },
        \\      "secondary": { "usedPercent": 0, "windowDurationMins": 10080 }
        \\    },
        \\    "codex": {
        \\      "limitId": "codex",
        \\      "limitName": null,
        \\      "primary": { "usedPercent": 10, "windowDurationMins": 300 },
        \\      "secondary": { "usedPercent": 2, "windowDurationMins": 10080 }
        \\    }
        \\  },
        \\  "rateLimitResetCredits": { "availableCount": 2 }
        \\}
    ;

    const body = try formatUsageSummaryAlloc(allocator, usage_json, rate_json);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Codex 5h: 90% left") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Codex weekly: 98% left") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "GPT-5.3-Codex-Spark 5h: 100% left") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Reset credits: 2 available") != null);
}

test "shouldAutoApproveRequest follows approval policy" {
    try std.testing.expect(shouldAutoApproveRequest(.{ .prompt = "hi", .approval_policy = .never }));
    try std.testing.expect(!shouldAutoApproveRequest(.{ .prompt = "hi", .approval_policy = .on_request }));
    try std.testing.expect(!shouldAutoApproveRequest(.{ .prompt = "hi" }));
}

test "Codex server approval request ids are non-empty" {
    const allocator = std.testing.allocator;
    const integer_id = try serverRequestApprovalIdAlloc(allocator, .{ .integer = 42 });
    defer allocator.free(integer_id);
    try std.testing.expectEqualStrings("rpc-int:42", integer_id);

    const string_id = try serverRequestApprovalIdAlloc(allocator, .{ .string = "" });
    defer allocator.free(string_id);
    try std.testing.expectEqualStrings("rpc-string:", string_id);
}

test "dynamic tool server request returns a failure result instead of hanging" {
    const allocator = std.testing.allocator;
    const request_json =
        \\{
        \\  "id": "server-request-1",
        \\  "method": "item/tool/call",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "turnId": "turn-456",
        \\    "callId": "call-789",
        \\    "tool": "exec",
        \\    "arguments": {}
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{});
    defer parsed.deinit();

    const method = getOptionalObjectString(parsed.value, "method").?;
    try std.testing.expectEqual(ServerRequestKind.dynamic_tool, serverRequestKind(method));
    const request_id = parseServerRequestId(parsed.value).?;
    const payload = try dynamicToolFailurePayloadAlloc(allocator, request_id, "Tool unavailable.");
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"id\":\"server-request-1\",\"result\":{\"success\":false,\"contentItems\":[{\"type\":\"inputText\",\"text\":\"Tool unavailable.\"}]}}",
        payload,
    );
}

test "unknown Codex server request receives method not found" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(ServerRequestKind.unsupported, serverRequestKind("currentTime/read"));

    const request_id: std.json.Value = .{ .integer = 42 };
    const payload = try serverErrorPayloadAlloc(
        allocator,
        request_id,
        JSON_RPC_METHOD_NOT_FOUND,
        "Unsupported Codex app-server request: currentTime/read",
    );
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"id\":42,\"error\":{\"code\":-32601,\"message\":\"Unsupported Codex app-server request: currentTime/read\"}}",
        payload,
    );
}

test "MCP elicitation server request is recognized" {
    try std.testing.expectEqual(
        ServerRequestKind.mcp_elicitation,
        serverRequestKind("mcpServer/elicitation/request"),
    );
}

test "MCP elicitation only accepts content-free schemas" {
    const allocator = std.testing.allocator;
    var empty_schema = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"type":"object","properties":{}}
    , .{});
    defer empty_schema.deinit();
    try std.testing.expect(mcpElicitationAllowsEmptyContent(empty_schema.value));

    var required_schema = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}
    , .{});
    defer required_schema.deinit();
    try std.testing.expect(!mcpElicitationAllowsEmptyContent(required_schema.value));
}

test "detectTurnTerminalState recognizes thread idle fallback for the active thread" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "thread/status/changed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "status": { "type": "idle" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const terminal = detectTurnTerminalState(parsed.value, "thread-123", "turn-456");
    try std.testing.expectEqual(TurnTerminalState.completed, terminal.?);
}

test "detectTurnTerminalState matches turn completion status for the started turn" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "turn/completed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "turn": {
        \\      "id": "turn-456",
        \\      "status": "failed",
        \\      "items": [],
        \\      "error": { "message": "boom", "codexErrorInfo": null, "additionalDetails": null }
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const terminal = detectTurnTerminalState(parsed.value, "thread-123", "turn-456");
    try std.testing.expectEqual(TurnTerminalState.failed, terminal.?);
    try std.testing.expectEqual(@as(?TurnTerminalState, null), detectTurnTerminalState(parsed.value, "thread-123", "other-turn"));
    try std.testing.expectEqualStrings("boom", extractTurnFailureMessage(parsed.value).?);

    var capture: TestFailureCapture = .{};
    emitTurnFailure(parsed.value, .{
        .prompt = "test",
        .stream_context = &capture,
        .on_failure = TestFailureCapture.handle,
    });
    try std.testing.expectEqualStrings("boom", capture.message.?);
}

test "command execution emits lifecycle tool call updates" {
    const allocator = std.testing.allocator;
    const started_json =
        \\{
        \\  "method": "item/started",
        \\  "params": {
        \\    "item": {
        \\      "id": "command-1",
        \\      "type": "commandExecution",
        \\      "command": "git status",
        \\      "status": "inProgress"
        \\    }
        \\  }
        \\}
    ;
    var started = try std.json.parseFromSlice(std.json.Value, allocator, started_json, .{});
    defer started.deinit();

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(try emitItemEvent(allocator, started.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 0), capture.message_count);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqualStrings("command-1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallKind.execute, capture.tool_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, capture.tool_status.?);
    try std.testing.expectEqualStrings("git status", capture.tool_input.?);

    const completed_json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "item": {
        \\      "id": "command-1",
        \\      "type": "commandExecution",
        \\      "command": "git status",
        \\      "status": "completed",
        \\      "aggregatedOutput": "clean tree",
        \\      "exitCode": 0
        \\    }
        \\  }
        \\}
    ;
    var completed = try std.json.parseFromSlice(std.json.Value, allocator, completed_json, .{});
    defer completed.deinit();

    try std.testing.expect(try emitItemEvent(allocator, completed.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 0), capture.message_count);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_call_count);
    try std.testing.expectEqualStrings("command-1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
    try std.testing.expectEqualStrings("git status", capture.tool_input.?);
    try std.testing.expect(std.mem.indexOf(u8, capture.tool_output.?, "clean tree") != null);
}

test "turn diff notification emits file snapshots with patch aliases" {
    const payload =
        \\{"method":"turn/diff/updated","params":{"files":[{"path":"src/main.zig","patch":"--- a/src/main.zig\n+++ b/src/main.zig\n@@ -1 +1 @@\n-old\n+new"}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(buildDiffSummary(parsed.value, .turn_snapshot, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 1), capture.diff_count);
    try std.testing.expectEqual(provider_types.StreamDiffScope.turn_snapshot, capture.diff_scope.?);
    try std.testing.expectEqualStrings("src/main.zig", capture.diff_path.?);
    try std.testing.expect(std.mem.indexOf(u8, capture.diff_patch.?, "+new") != null);
}

test "file change items emit edit lifecycle and diff events" {
    const payload =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "item": {
        \\      "id": "call_apply_patch_1",
        \\      "type": "fileChange",
        \\      "status": "completed",
        \\      "changes": [{
        \\        "path": "/work/test.ts",
        \\        "kind": {"type": "update"},
        \\        "diff": "@@ -1 +1 @@\n-old\n+new\n"
        \\      }]
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(try emitItemEvent(std.testing.allocator, parsed.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqualStrings("call_apply_patch_1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallKind.edit, capture.tool_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
    try std.testing.expect(std.mem.indexOf(u8, capture.tool_input.?, "/work/test.ts") != null);
    try std.testing.expectEqual(@as(usize, 1), capture.diff_count);
    try std.testing.expectEqualStrings("/work/test.ts", capture.diff_path.?);
    try std.testing.expect(std.mem.indexOf(u8, capture.diff_patch.?, "+new") != null);
}

test "reasoning items emit transient think lifecycle tool call updates" {
    const allocator = std.testing.allocator;
    const started_json =
        \\{
        \\  "method": "item/started",
        \\  "params": {
        \\    "item": {
        \\      "id": "reasoning-1",
        \\      "type": "reasoning"
        \\    }
        \\  }
        \\}
    ;
    var started = try std.json.parseFromSlice(std.json.Value, allocator, started_json, .{});
    defer started.deinit();

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(try emitItemEvent(allocator, started.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqual(provider_types.ToolCallKind.think, capture.tool_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, capture.tool_status.?);

    const completed_json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "item": {
        \\      "id": "reasoning-1",
        \\      "type": "reasoning",
        \\      "summary": ["**Reviewing layout code**", "Checking zoom handling"]
        \\    }
        \\  }
        \\}
    ;
    var completed = try std.json.parseFromSlice(std.json.Value, allocator, completed_json, .{});
    defer completed.deinit();

    try std.testing.expect(try emitItemEvent(allocator, completed.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 2), capture.tool_call_count);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
    // No summary output travels with the terminal event; the shared upsert
    // relies on that to drop the transient "Thinking" row.
    try std.testing.expect(capture.tool_output == null);
}

test "MCP calls emit lifecycle tool call updates" {
    const allocator = std.testing.allocator;
    const started_json =
        \\{
        \\  "method": "item/started",
        \\  "params": {
        \\    "item": {
        \\      "id": "mcp-1",
        \\      "type": "mcpToolCall",
        \\      "server": "verde",
        \\      "tool": "capture_browser_screenshot",
        \\      "status": "inProgress"
        \\    }
        \\  }
        \\}
    ;
    var started = try std.json.parseFromSlice(std.json.Value, allocator, started_json, .{});
    defer started.deinit();

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(try emitItemEvent(allocator, started.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 0), capture.message_count);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqual(provider_types.ToolCallKind.mcp, capture.tool_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, capture.tool_status.?);
    try std.testing.expectEqualStrings("verde.capture_browser_screenshot", capture.tool_input.?);

    const completed_json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "item": {
        \\      "id": "mcp-1",
        \\      "type": "mcpToolCall",
        \\      "server": "verde",
        \\      "tool": "capture_browser_screenshot",
        \\      "status": "completed",
        \\      "result": {
        \\        "content": [
        \\          { "type": "text", "text": "{\"ok\":true,\"items\":[1,2]}" }
        \\        ]
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var completed = try std.json.parseFromSlice(std.json.Value, allocator, completed_json, .{});
    defer completed.deinit();

    try std.testing.expect(try emitItemEvent(allocator, completed.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 2), capture.tool_call_count);
    try std.testing.expectEqualStrings("mcp-1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
    try std.testing.expectEqualStrings("verde.capture_browser_screenshot", capture.tool_input.?);
    try std.testing.expectEqualStrings("{\"ok\":true,\"items\":[1,2]}", capture.tool_output.?);

    const failed_json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "item": {
        \\      "id": "mcp-2",
        \\      "type": "mcpToolCall",
        \\      "server": "blender",
        \\      "tool": "execute_blender_code",
        \\      "status": "failed"
        \\    }
        \\  }
        \\}
    ;
    var failed = try std.json.parseFromSlice(std.json.Value, allocator, failed_json, .{});
    defer failed.deinit();

    try std.testing.expect(try emitItemEvent(allocator, failed.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 3), capture.tool_call_count);
    try std.testing.expectEqualStrings("mcp-2", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.failed, capture.tool_status.?);
    try std.testing.expectEqualStrings("blender.execute_blender_code", capture.tool_input.?);
}

test "collab agent spawn emits subagent lifecycle updates" {
    const allocator = std.testing.allocator;
    const started_json =
        \\{
        \\  "method": "item/started",
        \\  "params": {
        \\    "item": {
        \\      "id": "collab-1",
        \\      "type": "collabAgentToolCall",
        \\      "tool": "spawnAgent",
        \\      "status": "inProgress",
        \\      "senderThreadId": "parent-1",
        \\      "receiverThreadIds": ["child-1"],
        \\      "prompt": "Explore the web app",
        \\      "model": "gpt-5"
        \\    }
        \\  }
        \\}
    ;
    var started = try std.json.parseFromSlice(std.json.Value, allocator, started_json, .{});
    defer started.deinit();

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(try emitItemEvent(allocator, started.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqualStrings("child-1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, capture.tool_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, capture.tool_status.?);
    try std.testing.expectEqualStrings("Explore the web app", capture.tool_input.?);

    const activity_json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "item": {
        \\      "id": "activity-1",
        \\      "type": "subAgentActivity",
        \\      "kind": "completed",
        \\      "agentThreadId": "child-1",
        \\      "agentPath": "Explore the web app"
        \\    }
        \\  }
        \\}
    ;
    var activity = try std.json.parseFromSlice(std.json.Value, allocator, activity_json, .{});
    defer activity.deinit();

    try std.testing.expect(try emitItemEvent(allocator, activity.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqual(@as(usize, 2), capture.tool_call_count);
    try std.testing.expectEqualStrings("child-1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
}

test "hydrated Codex turn items backfill MCP output" {
    const payload =
        \\{
        \\  "thread": {
        \\    "id": "thread-1",
        \\    "turns": [{
        \\      "id": "turn-1",
        \\      "items": [{
        \\        "id": "mcp-1",
        \\        "type": "mcpToolCall",
        \\        "server": "verde",
        \\        "tool": "list_workspaces",
        \\        "status": "completed",
        \\        "arguments": {},
        \\        "result": {
        \\          "content": [{"type":"text","text":"{\"ok\":true}"}],
        \\          "structuredContent": null
        \\        }
        \\      }]
        \\    }]
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    var capture: TestStreamEventCapture = .{};

    try std.testing.expectEqual(@as(usize, 1), try emitHydratedMcpToolOutputsFromThreadValue(
        std.testing.allocator,
        parsed.value,
        "turn-1",
        &capture,
        TestStreamEventCapture.handle,
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.tool_call_count);
    try std.testing.expectEqualStrings("mcp-1", capture.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, capture.tool_status.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", capture.tool_output.?);
}

test "isContextCompactionCompleted matches compact item completion" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "item": {
        \\      "id": "item-1",
        \\      "type": "contextCompaction"
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(isContextCompactionCompleted(parsed.value, "thread-123"));
    try std.testing.expect(!isContextCompactionCompleted(parsed.value, "other-thread"));

    var capture: TestStreamEventCapture = .{};
    try std.testing.expect(try emitItemEvent(allocator, parsed.value, &capture, TestStreamEventCapture.handle));
    try std.testing.expectEqualStrings("Context compacted", capture.title.?);
    try std.testing.expectEqualStrings(
        "Codex summarized earlier conversation context to make room for the rest of this turn.",
        capture.body.?,
    );
}

test "isThreadCompactionIdle matches idle fallback" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "thread/status/changed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "status": { "type": "idle" }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(isThreadCompactionIdle(parsed.value, "thread-123"));
    try std.testing.expect(!isThreadCompactionIdle(parsed.value, "other-thread"));
}

test "extractReviewCompletedText reads exited review item" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "item": {
        \\      "type": "exitedReviewMode",
        \\      "id": "turn-1",
        \\      "review": "Looks solid overall."
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Looks solid overall.", extractReviewCompletedText(parsed.value, "thread-123").?);
    try std.testing.expect(extractReviewCompletedText(parsed.value, "other-thread") == null);
}

test "extractShellOutputDelta and completion parse shell notifications" {
    const allocator = std.testing.allocator;
    const delta_json =
        \\{
        \\  "method": "item/commandExecution/outputDelta",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "delta": { "text": "hello\\n" }
        \\  }
        \\}
    ;
    var delta = try std.json.parseFromSlice(std.json.Value, allocator, delta_json, .{});
    defer delta.deinit();
    try std.testing.expectEqualStrings("hello\\n", extractShellOutputDelta(delta.value).?);

    const completed_json =
        \\{
        \\  "method": "item/completed",
        \\  "params": {
        \\    "threadId": "thread-123",
        \\    "item": { "type": "commandExecution", "status": "completed" }
        \\  }
        \\}
    ;
    var completed = try std.json.parseFromSlice(std.json.Value, allocator, completed_json, .{});
    defer completed.deinit();
    try std.testing.expect(isShellCommandCompleted(completed.value, "thread-123"));
    try std.testing.expect(!isShellCommandCompleted(completed.value, "other-thread"));
}

test "background terminal list matches the exact provider process" {
    const payload =
        \\{
        \\  "data": [
        \\    { "processId": "123", "command": "sleep 10" },
        \\    { "processId": "456", "command": "mise run build" }
        \\  ]
        \\}
    ;
    try std.testing.expect(try backgroundTerminalListContainsProcess(std.testing.allocator, payload, "456"));
    try std.testing.expect(!try backgroundTerminalListContainsProcess(std.testing.allocator, payload, "45"));
}

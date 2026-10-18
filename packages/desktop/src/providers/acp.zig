//! Generic Agent Client Protocol (ACP) client machinery shared by ACP-backed
//! provider harnesses (Cursor, FX, ...). Transport framing, JSON-RPC request
//! builders, capability/session parsing, permission plumbing, and session
//! update mapping live here; binary discovery, argv construction, model
//! catalogs, and payload heuristics stay in the per-provider modules.
//!
//! Errors raised here are provider-neutral (`error.AcpFailed`,
//! `error.AcpSignedOut`, `error.AcpMessageTooLarge`,
//! `error.AcpAttachmentsUnsupported`). Providers map them to their existing
//! provider-specific error names at their public API boundary so user-facing
//! error messaging remains unchanged.

const std = @import("std");
const provider_diagnostics = @import("diagnostics.zig");
const platform_process = @import("../platform/process.zig");
const provider_types = @import("types.zig");
const cursor_extensions = @import("cursor_extensions.zig");

pub const MAX_LINE_BYTES = 16 * 1024 * 1024;
pub const MCP_TOOL_NAME_FIELD = "_verdeMcpTool";

/// Per-provider knobs threaded through the generic line handlers so shared
/// code can log, label, and title output without provider branches.
pub const Harness = struct {
    cursor_extensions_enabled: bool = false,
    /// Diagnostics category for content-safe JSON-RPC error logging.
    diagnostics_category: provider_diagnostics.ErrorCategory,
    /// Author label for assistant messages reconstructed from history replay.
    assistant_author: []const u8,
    /// Title used when a permission request omits its own.
    permission_default_title: []const u8,
    /// Some agents (fx) stream startup diagnostics as the first
    /// agent_message_chunk. Chunks starting with this prefix, arriving before
    /// any reply text, become a system event instead of assistant prose.
    diagnostic_chunk_prefix: ?[]const u8 = null,
    diagnostic_event_title: []const u8 = "Agent warning",
    /// Replaces a provider-specific error emitted as assistant prose with a
    /// user-facing explanation. Returning null preserves ordinary text.
    agent_error_message: ?*const fn ([]const u8) ?[]const u8 = null,
};

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

/// Tracks the provider's currently active ACP child so interrupts and
/// shutdown can target it. Each provider module owns one instance.
pub const ActiveProcessState = struct {
    mutex: Mutex = .{},
    child: ?*platform_process.OwnedChild = null,
    stdin: ?std.Io.File = null,
    session_id: ?[]const u8 = null,

    pub fn lock(self: *ActiveProcessState) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *ActiveProcessState) void {
        self.mutex.unlock();
    }

    pub fn register(
        self: *ActiveProcessState,
        child: *platform_process.OwnedChild,
        stdin: ?std.Io.File,
        session_id: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child = child;
        self.stdin = stdin;
        self.session_id = session_id;
    }

    pub fn unregister(self: *ActiveProcessState, child: *platform_process.OwnedChild) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.child == child) {
            self.child = null;
            self.stdin = null;
            self.session_id = null;
        }
    }
};

/// A slash command an agent advertised at runtime (`available_commands_update`
/// after session setup, or grok's initialize `_meta.availableCommands`).
pub const LiveCommand = struct {
    name: []u8,
    description: []u8,
    hint: []u8,
};

const LiveCommandSlot = struct { commands: []LiveCommand = &.{} };
const LIVE_COMMAND_SLOTS = std.meta.fields(provider_diagnostics.ErrorCategory).len;
/// Latest advertised list per harness (keyed by diagnostics category), kept
/// for the daemon's lifetime so `provider.slash.list` can merge it with the
/// static catalog. Refilled by the next session setup after a restart.
var live_commands: [LIVE_COMMAND_SLOTS]LiveCommandSlot = @splat(.{});
var live_commands_mutex: Mutex = .{};
/// Picker summaries stay short; Cursor skill descriptions run to paragraphs.
const LIVE_COMMAND_SUMMARY_BYTES = 200;

/// Replaces the remembered list for `category` with the `availableCommands`
/// array (`[{name, description?, input?: {hint}}]`). Non-arrays are ignored.
pub fn rememberAvailableCommands(category: provider_diagnostics.ErrorCategory, commands: std.json.Value) void {
    if (commands != .array) return;
    const allocator = std.heap.page_allocator;
    var list: std.ArrayList(LiveCommand) = .empty;
    for (commands.array.items) |entry| {
        const raw_name = std.mem.trim(u8, getOptionalObjectString(entry, "name") orelse continue, " \t\r\n/");
        if (raw_name.len == 0 or raw_name.len > 64 or std.mem.indexOfAny(u8, raw_name, " \t\r\n") != null) continue;
        const raw_description = std.mem.trim(u8, getOptionalObjectString(entry, "description") orelse "", " \t\r\n");
        const raw_hint = if (getObjectField(entry, "input")) |input| std.mem.trim(u8, getOptionalObjectString(input, "hint") orelse "", " \t\r\n") else "";
        const name = allocator.dupe(u8, raw_name) catch continue;
        const description = allocator.dupe(u8, truncateUtf8(raw_description, LIVE_COMMAND_SUMMARY_BYTES)) catch {
            allocator.free(name);
            continue;
        };
        const hint = allocator.dupe(u8, truncateUtf8(raw_hint, 120)) catch {
            allocator.free(name);
            allocator.free(description);
            continue;
        };
        list.append(allocator, .{ .name = name, .description = description, .hint = hint }) catch {
            allocator.free(name);
            allocator.free(description);
            allocator.free(hint);
            continue;
        };
    }
    const owned = list.toOwnedSlice(allocator) catch {
        freeLiveCommands(allocator, list.items);
        list.deinit(allocator);
        return;
    };
    live_commands_mutex.lock();
    defer live_commands_mutex.unlock();
    const slot = &live_commands[@intFromEnum(category)];
    freeLiveCommands(allocator, slot.commands);
    slot.commands = owned;
}

/// grok lists its commands in the initialize response (`result._meta.availableCommands`).
pub fn rememberAvailableCommandsFromInitialize(category: provider_diagnostics.ErrorCategory, value: std.json.Value) void {
    const result = getObjectField(value, "result") orelse return;
    const meta = getObjectField(result, "_meta") orelse return;
    rememberAvailableCommands(category, getObjectField(meta, "availableCommands") orelse return);
}

fn freeLiveCommands(allocator: std.mem.Allocator, commands: []LiveCommand) void {
    for (commands) |command| {
        allocator.free(command.name);
        allocator.free(command.description);
        allocator.free(command.hint);
    }
    if (commands.len > 0) allocator.free(commands);
}

fn truncateUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// The static catalog followed by live commands it does not already list,
/// every string owned by `allocator` (free with freeSlashCommandList).
pub fn slashCommandsWithLiveAlloc(
    allocator: std.mem.Allocator,
    category: ?provider_diagnostics.ErrorCategory,
    static: []const provider_types.ProviderSlashCommand,
) ![]provider_types.ProviderSlashCommand {
    var out: std.ArrayList(provider_types.ProviderSlashCommand) = .empty;
    errdefer {
        freeSlashCommandStrings(allocator, out.items);
        out.deinit(allocator);
    }
    for (static) |command| {
        var copy = command;
        copy.name = try allocator.dupe(u8, command.name);
        errdefer allocator.free(copy.name);
        copy.summary = try allocator.dupe(u8, command.summary);
        errdefer allocator.free(copy.summary);
        copy.usage = try allocator.dupe(u8, command.usage);
        errdefer allocator.free(copy.usage);
        try out.append(allocator, copy);
    }
    const slot_index = @intFromEnum(category orelse return out.toOwnedSlice(allocator));
    live_commands_mutex.lock();
    defer live_commands_mutex.unlock();
    for (live_commands[slot_index].commands) |live| {
        var known = false;
        for (static) |command| {
            if (command.name.len == live.name.len + 1 and command.name[0] == '/' and std.mem.eql(u8, command.name[1..], live.name)) known = true;
        }
        if (known) continue;
        const name = try std.fmt.allocPrint(allocator, "/{s}", .{live.name});
        errdefer allocator.free(name);
        const summary = try allocator.dupe(u8, if (live.description.len > 0) live.description else "Agent slash command.");
        errdefer allocator.free(summary);
        const usage = if (live.hint.len > 0)
            try std.fmt.allocPrint(allocator, "/{s} {s}", .{ live.name, live.hint })
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{live.name});
        errdefer allocator.free(usage);
        try out.append(allocator, .{
            .id = .custom,
            .name = name,
            .summary = summary,
            .usage = usage,
            .requires_thread = false,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn freeSlashCommandStrings(allocator: std.mem.Allocator, commands: []const provider_types.ProviderSlashCommand) void {
    for (commands) |command| {
        allocator.free(command.name);
        allocator.free(command.summary);
        allocator.free(command.usage);
    }
}

pub fn freeSlashCommandList(allocator: std.mem.Allocator, commands: []const provider_types.ProviderSlashCommand) void {
    freeSlashCommandStrings(allocator, commands);
    allocator.free(commands);
}

/// `/name` of a slash prompt (`/review --pr 7` -> `/review`); null for
/// ordinary text or a bare `/`.
pub fn slashCommandRoot(raw_text: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "/")) return null;
    const root_end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    if (root_end <= 1) return null;
    return text[0..root_end];
}

/// A spawned ACP server child plus the resources needed to speak
/// newline-delimited JSON-RPC with it. Providers construct this from their
/// own argv/env logic; the transport methods are shared.
pub const Process = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    process: platform_process.OwnedChild,
    env_map: std.process.Environ.Map,
    executable: []u8,
    /// When set, deinit unregisters this child from the provider's active
    /// process tracking.
    active_state: ?*ActiveProcessState = null,
    finished: bool = false,

    pub fn writeLine(self: *Process, line: []u8) !void {
        defer self.allocator.free(line);
        const stdin = self.process.child.stdin orelse return error.ConnectionClosed;
        try writeJsonLineToFile(self.allocator, stdin, line);
    }

    pub fn closeStdin(self: *Process) !void {
        if (self.process.child.stdin) |stdin| {
            stdin.close(self.threaded.io());
            self.process.child.stdin = null;
        }
    }

    pub fn stop(self: *Process) void {
        if (self.finished or self.process.child.id == null) return;
        self.process.kill(self.threaded.io());
        self.finished = true;
        self.process.child.stdin = null;
        self.process.child.stdout = null;
    }

    pub fn deinit(self: *Process) void {
        if (self.active_state) |state| state.unregister(&self.process);
        if (!self.finished and self.process.child.id != null) {
            self.process.kill(self.threaded.io());
        }
        if (self.process.child.stdin) |stdin| stdin.close(self.threaded.io());
        self.env_map.deinit();
        self.allocator.free(self.executable);
        self.threaded.deinit();
    }
};

/// Reads one newline-delimited JSON-RPC message, returning null at EOF.
pub fn takeLineAlloc(allocator: std.mem.Allocator, reader: anytype) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    _ = reader.interface.streamDelimiterLimit(&writer.writer, '\n', .limited(MAX_LINE_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => return error.AcpMessageTooLarge,
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

pub const Capabilities = struct {
    image: bool = false,
    load_session: bool = false,
    list_sessions: bool = false,
    /// `sessionCapabilities.resume`: restore a session without replaying its
    /// history, which `session/load` streams back on every turn.
    resume_session: bool = false,
    /// `mcpCapabilities.http`: clients may only pass HTTP MCP servers to
    /// agents that advertise it.
    mcp_http: bool = false,
};

pub const ListThreadsState = struct {
    saw_initialize: bool = false,
    threads: std.ArrayList(provider_types.ChatThreadSummary) = .empty,

    pub fn deinit(self: *ListThreadsState, allocator: std.mem.Allocator) void {
        for (self.threads.items) |thread| {
            allocator.free(thread.id);
            allocator.free(thread.title);
        }
        self.threads.deinit(allocator);
    }
};

pub const ReadThreadState = struct {
    saw_initialize: bool = false,
    messages: std.ArrayList(provider_types.ChatMessage) = .empty,
    title: ?[]u8 = null,

    pub fn deinit(self: *ReadThreadState, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        self.messages.deinit(allocator);
        if (self.title) |title| allocator.free(title);
    }
};

pub const SendPromptState = struct {
    cursor: cursor_extensions.State = .{},
    capabilities: Capabilities = .{},
    session_id: ?[]u8 = null,
    prompt_submitted: bool = false,
    reply: std.ArrayList(u8) = .empty,
    agent_error_emitted: bool = false,
    /// True while `agent_thought_chunk` updates are streaming and no visible
    /// reply text or tool call has followed them yet.
    thinking: bool = false,
    /// Count of thought segments seen this turn; keys the transient row ids.
    thought_segments: u32 = 0,
    /// Hash of the last plan published this turn. Agents resend the whole
    /// plan on every change, so identical resends are not repeated as cards.
    last_plan_hash: ?u64 = null,
    /// Context/cost figures gathered this turn; published as one "Usage"
    /// row when the prompt completes.
    usage: TurnUsage = .{},

    pub fn deinit(self: *SendPromptState, allocator: std.mem.Allocator) void {
        if (self.session_id) |session_id| allocator.free(session_id);
        self.reply.deinit(allocator);
        self.cursor.deinit(allocator);
    }
};

/// Figures from ACP `usage_update` notifications (context tokens in use,
/// context window size, cumulative session cost) plus the prompt response's
/// own token counts (`usage` per the spec, `_meta` for grok).
pub const TurnUsage = struct {
    context_used: ?u64 = null,
    context_size: ?u64 = null,
    cost_amount: ?f64 = null,
    cost_currency: [8]u8 = @splat(0),
    cost_currency_len: u8 = 0,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,

    fn currency(self: *const TurnUsage) []const u8 {
        return self.cost_currency[0..self.cost_currency_len];
    }

    fn setCurrency(self: *TurnUsage, text: []const u8) void {
        const len: u8 = @intCast(@min(text.len, self.cost_currency.len));
        @memcpy(self.cost_currency[0..len], text[0..len]);
        self.cost_currency_len = len;
    }

    fn isEmpty(self: *const TurnUsage) bool {
        return self.context_used == null and self.cost_amount == null and self.input_tokens == null and self.output_tokens == null;
    }
};

pub const SendLineAction = enum {
    continue_reading,
    /// The initialize response arrived and `state.capabilities` is set; the
    /// caller now sends session/new, session/load, or session/resume.
    initialized,
    session_ready,
    prompt_done,
};

/// Handles one line of a listThreads exchange; returns true when done.
/// Expects request id 1 = initialize and id 2 = session/list.
pub fn handleListThreadsLine(
    allocator: std.mem.Allocator,
    harness: Harness,
    line: []const u8,
    state: *ListThreadsState,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(harness, parsed.value);
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

/// Handles one line of a readThread exchange; returns true when done.
/// Expects request id 1 = initialize and id 2 = session/load.
pub fn handleReadThreadLine(
    allocator: std.mem.Allocator,
    harness: Harness,
    line: []const u8,
    thread_id: []const u8,
    state: *ReadThreadState,
) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try failIfJsonRpcError(harness, parsed.value);
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
        try handleReadSessionUpdate(allocator, harness, parsed.value, state);
    }
    return false;
}

/// Handles one line of a sendPrompt exchange. Expects request id 1 =
/// initialize, id 2 = session/new, session/load, or session/resume, id 3 =
/// session/prompt.
pub fn handleSendPromptLine(
    allocator: std.mem.Allocator,
    harness: Harness,
    line: []const u8,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
    stdin: ?std.Io.File,
) !SendLineAction {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    failIfJsonRpcError(harness, parsed.value) catch |err| {
        finishThinking(request, state);
        reportJsonRpcFailure(request, parsed.value);
        return err;
    };

    // ACP server requests have their own JSON-RPC id sequence. Handle them
    // before matching response ids so a permission request cannot collide
    // with one of Verde's initialize/session/prompt request ids.
    if (isMethod(parsed.value, "session/request_permission")) {
        try handlePermissionRequest(allocator, harness, parsed.value, request, stdin);
        return .continue_reading;
    }

    if (harness.cursor_extensions_enabled) {
        const method = getOptionalObjectString(parsed.value, "method") orelse "";
        if (std.mem.startsWith(u8, method, "cursor/")) {
            finishThinking(request, state);
            _ = try cursor_extensions.handle(allocator, parsed.value, request, &state.cursor, stdin);
            return .continue_reading;
        }
    }

    // Any other agent-to-client request (fs/terminal/elicitation, vendor
    // extensions) is unsupported; answer it so the agent does not wait on a
    // reply that never comes.
    if (serverRequestId(parsed.value)) |server_id| {
        if (stdin) |file| {
            const response = try makeMethodNotFoundResponseAlloc(allocator, server_id);
            defer allocator.free(response);
            try writeJsonLineToFile(allocator, file, response);
        }
        return .continue_reading;
    }

    if (responseId(parsed.value)) |id| {
        if (id == 1) {
            state.capabilities = parseCapabilities(parsed.value);
            return .initialized;
        }
        if (id == 2) {
            if (state.prompt_submitted) return .continue_reading;
            if (state.session_id == null) {
                const session_id = parseSessionId(parsed.value) orelse request.thread_id orelse return error.AcpFailed;
                state.session_id = try allocator.dupe(u8, session_id);
            }
            return .session_ready;
        }
        if (id == 3) {
            finishThinking(request, state);
            // ACP reports agent-side turn failures (unknown model for the
            // active provider, gateway HTTP errors) as a successful response
            // with stopReason "refused"; the only diagnostic is the streamed
            // text, so fail the turn instead of committing it as a reply.
            if (getObjectField(parsed.value, "result")) |result| {
                if (getOptionalObjectString(result, "stopReason")) |stop_reason| {
                    if (std.mem.eql(u8, stop_reason, "refused")) {
                        provider_diagnostics.logError(
                            harness.diagnostics_category,
                            null,
                            "prompt refused by agent; streamed reply text carries the reason",
                        );
                        return error.AcpRefused;
                    }
                }
                recordPromptUsage(result, &state.usage);
            }
            emitUsageSummary(allocator, request, state) catch {};
            return .prompt_done;
        }
    }

    if (isMethod(parsed.value, "session/update")) {
        // Command lists arrive right after session setup, before the prompt,
        // so they are kept regardless of replay state.
        if (sessionUpdateObject(parsed.value)) |update| {
            if (getOptionalObjectString(update, "sessionUpdate")) |kind| {
                if (std.mem.eql(u8, kind, "available_commands_update")) {
                    rememberAvailableCommands(harness.diagnostics_category, getObjectField(update, "availableCommands") orelse .null);
                    return .continue_reading;
                }
            }
        }
        // ACP servers replay session history while loading an existing
        // session. Only updates emitted after this turn's prompt was
        // submitted are live.
        if (!state.prompt_submitted) return .continue_reading;
        try handleLiveSessionUpdate(allocator, harness, parsed.value, request, state);
        return .continue_reading;
    }
    return .continue_reading;
}

pub fn makeInitializeRequestAlloc(allocator: std.mem.Allocator, id: i64) ![]u8 {
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

pub fn makeSessionListRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd_owned: []u8) ![]u8 {
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

pub const McpHttpServer = struct {
    url: []const u8,
    authorization: []const u8,
    client_name: []const u8,
};

const McpServer = union(enum) {
    stdio: []const u8,
    http: McpHttpServer,
};

pub fn makeSessionNewRequestAlloc(allocator: std.mem.Allocator, id: i64, cwd: []const u8, mcp_executable: ?[]const u8) ![]u8 {
    const server: ?McpServer = if (mcp_executable) |executable| .{ .stdio = executable } else null;
    return makeSessionSetupRequestAlloc(allocator, id, "session/new", null, cwd, server, null);
}

pub fn makeSessionLoadRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, cwd: []const u8, mcp_executable: ?[]const u8) ![]u8 {
    const server: ?McpServer = if (mcp_executable) |executable| .{ .stdio = executable } else null;
    return makeSessionSetupRequestAlloc(allocator, id, "session/load", session_id, cwd, server, null);
}

pub fn makeSessionNewRequestWithHttpMcpAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    cwd: []const u8,
    server: ?McpHttpServer,
) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/new", null, cwd, if (server) |value| .{ .http = value } else null, null);
}

pub fn makeSessionLoadRequestWithHttpMcpAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    session_id: []const u8,
    cwd: []const u8,
    server: ?McpHttpServer,
) ![]u8 {
    return makeSessionSetupRequestAlloc(allocator, id, "session/load", session_id, cwd, if (server) |value| .{ .http = value } else null, null);
}

/// Writes the value of a session request's `_meta` field (an object).
pub const SessionMetaWriter = *const fn (*std.json.Stringify) std.json.Stringify.Error!void;

pub const SessionSetup = struct {
    cwd: []const u8,
    /// Continue this session; null starts a new one.
    session_id: ?[]const u8 = null,
    /// Dropped unless the agent advertised `mcpCapabilities.http`.
    mcp_http: ?McpHttpServer = null,
    meta: ?SessionMetaWriter = null,
};

/// Builds the session request for a prompt turn once the initialize response
/// is known: session/new without a session id, otherwise session/resume when
/// advertised (no history replay) and session/load as the fallback.
pub fn makeTurnSessionRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    capabilities: Capabilities,
    setup: SessionSetup,
) ![]u8 {
    const server: ?McpServer = if (capabilities.mcp_http) (if (setup.mcp_http) |value| McpServer{ .http = value } else null) else null;
    const method = if (setup.session_id == null)
        "session/new"
    else if (capabilities.resume_session)
        "session/resume"
    else
        "session/load";
    return makeSessionSetupRequestAlloc(allocator, id, method, setup.session_id, setup.cwd, server, setup.meta);
}

pub fn makePromptRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    session_id: []const u8,
    request: provider_types.SendPromptRequest,
    image_supported: bool,
) ![]u8 {
    const images = try collectImageAttachments(allocator, request);
    defer allocator.free(images);
    if (images.len > 0 and !image_supported) return error.AcpAttachmentsUnsupported;

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

pub fn makeCancelNotificationAlloc(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
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

pub fn makePermissionResponseAlloc(allocator: std.mem.Allocator, id: std.json.Value, option_id: ?[]const u8) ![]u8 {
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
    try stringify.write(if (option_id != null) "selected" else "cancelled");
    if (option_id) |selected| {
        try stringify.objectField("optionId");
        try stringify.write(selected);
    }
    try stringify.endObject();
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

/// Standard ACP `session/set_model`; agents accept only ids from their own
/// catalog (`models.availableModels` in the session response).
pub fn makeSetModelRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, model_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, "session/set_model");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("sessionId");
    try stringify.write(session_id);
    try stringify.objectField("modelId");
    try stringify.write(model_id);
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

/// JSON-RPC -32601 reply for an agent request Verde does not implement.
pub fn makeMethodNotFoundResponseAlloc(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("error");
    try stringify.beginObject();
    try stringify.objectField("code");
    try stringify.write(-32601);
    try stringify.objectField("message");
    try stringify.write("Method not supported by Verde");
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

pub fn writeJsonLineToFile(allocator: std.mem.Allocator, file: std.Io.File, line: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writerStreaming(threaded.io(), &write_buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

/// Server request IDs are independent of our numeric response sequence.
pub fn serverRequestId(value: std.json.Value) ?std.json.Value {
    if (getOptionalObjectString(value, "method") == null) return null;
    const id = getObjectField(value, "id") orelse return null;
    return switch (id) {
        .integer, .string => id,
        else => null,
    };
}

pub fn responseId(value: std.json.Value) ?i64 {
    // ACP server requests use their own id sequence, which can collide with
    // Verde's request ids. Only JSON-RPC responses are eligible here.
    if (getObjectField(value, "method") != null) return null;
    return getOptionalObjectInteger(value, "id");
}

pub fn isMethod(value: std.json.Value, method: []const u8) bool {
    const actual = getOptionalObjectString(value, "method") orelse return false;
    return std.mem.eql(u8, actual, method);
}

pub fn failIfJsonRpcError(harness: Harness, value: std.json.Value) !void {
    const error_value = getObjectField(value, "error") orelse return;
    const message = getOptionalObjectString(error_value, "message") orelse "";
    if (isAuthError(message)) return error.AcpSignedOut;
    provider_diagnostics.logError(
        harness.diagnostics_category,
        getOptionalObjectInteger(error_value, "code"),
        message,
    );
    return error.AcpFailed;
}

pub fn parseCapabilities(value: std.json.Value) Capabilities {
    const result = getObjectField(value, "result") orelse return .{};
    const agent = getObjectField(result, "agentCapabilities") orelse return .{};
    const prompt = getObjectField(agent, "promptCapabilities");
    const sessions = getObjectField(agent, "sessionCapabilities");
    const mcp = getObjectField(agent, "mcpCapabilities");
    return .{
        .image = if (prompt) |p| getOptionalObjectBool(p, "image") orelse false else false,
        .load_session = getOptionalObjectBool(agent, "loadSession") orelse false,
        .list_sessions = if (sessions) |s| sessionCapabilityPresent(s, "list") else false,
        .resume_session = if (sessions) |s| sessionCapabilityPresent(s, "resume") else false,
        .mcp_http = if (mcp) |m| getOptionalObjectBool(m, "http") orelse false else false,
    };
}

// Session capabilities are objects (`{}`) when supported; null or false
// means unsupported.
fn sessionCapabilityPresent(sessions: std.json.Value, key: []const u8) bool {
    const field = getObjectField(sessions, key) orelse return false;
    return switch (field) {
        .null => false,
        .bool => |enabled| enabled,
        else => true,
    };
}

pub fn parseSessionId(value: std.json.Value) ?[]const u8 {
    const result = getObjectField(value, "result") orelse return null;
    return getOptionalObjectString(result, "sessionId");
}

pub fn parseSessionListResponse(
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

pub fn shouldAutoApprovePermission(request: provider_types.SendPromptRequest) bool {
    return (request.approval_policy orelse .on_request) == .never;
}

pub fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn getOptionalObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

pub fn getOptionalObjectInteger(value: std.json.Value, key: []const u8) ?i64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |number| number,
        else => null,
    };
}

pub fn getOptionalObjectBool(value: std.json.Value, key: []const u8) ?bool {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn handleReadSessionUpdate(
    allocator: std.mem.Allocator,
    harness: Harness,
    value: std.json.Value,
    state: *ReadThreadState,
) !void {
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
    if (role == .assistant) {
        if (harness.agent_error_message) |agent_error_message| {
            if (agent_error_message(text)) |message| {
                if (state.messages.items.len > 0) {
                    const previous = state.messages.items[state.messages.items.len - 1];
                    if (previous.role == .assistant and std.mem.eql(u8, previous.body, message)) return;
                }
                try appendChatMessageChunk(allocator, harness, &state.messages, role, message);
                return;
            }
        }
    }
    try appendChatMessageChunk(allocator, harness, &state.messages, role, text);
}

fn handleLiveSessionUpdate(
    allocator: std.mem.Allocator,
    harness: Harness,
    value: std.json.Value,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
) !void {
    const update = sessionUpdateObject(value) orelse return;
    const kind = getOptionalObjectString(update, "sessionUpdate") orelse return;
    if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
        // Reasoning text is never shown; like Codex, it only drives the
        // transient "Thinking" indicator until visible output arrives.
        startThinking(request, state);
        return;
    }
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        const text = contentText(update) orelse return;
        if (text.len == 0) return;
        finishThinking(request, state);
        if (harness.agent_error_message) |agent_error_message| {
            if (agent_error_message(text)) |message| {
                if (state.agent_error_emitted) return;
                state.agent_error_emitted = true;
                try state.reply.appendSlice(allocator, message);
                if (request.on_stream_delta) |on_stream_delta| {
                    on_stream_delta(request.stream_context, message);
                }
                return;
            }
        }
        if (harness.diagnostic_chunk_prefix) |prefix| {
            if (state.reply.items.len == 0 and std.mem.startsWith(u8, text, prefix)) {
                if (request.on_stream_event) |on_stream_event| {
                    on_stream_event(request.stream_context, .{ .message = .{
                        .title = harness.diagnostic_event_title,
                        .body = text,
                    } });
                }
                return;
            }
        }
        try state.reply.appendSlice(allocator, text);
        if (request.on_stream_delta) |on_stream_delta| {
            on_stream_delta(request.stream_context, text);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "plan")) {
        try emitPlanUpdate(allocator, update, request, state);
        return;
    }
    if (std.mem.eql(u8, kind, "usage_update")) {
        recordUsageUpdate(update, &state.usage);
        return;
    }
    if (std.mem.eql(u8, kind, "current_mode_update")) {
        // Agents switch modes themselves (Cursor enters Plan from its
        // create_plan flow); say so in the transcript.
        const mode = getOptionalObjectString(update, "currentModeId") orelse return;
        const on_stream_event = request.on_stream_event orelse return;
        const body = try std.fmt.allocPrint(allocator, "{s} switched to {s} mode.", .{ harness.assistant_author, mode });
        defer allocator.free(body);
        on_stream_event(request.stream_context, .{ .message = .{ .title = "Mode", .body = body } });
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
        finishThinking(request, state);
        const event = (try toolEventAlloc(allocator, update)) orelse return;
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
            emitDiffUpdate(allocator, update, event.output, request.stream_context, on_stream_event);
        }
    }
}

// `usage_update`: {used, size, cost?: {amount, currency}}; cumulative, so the
// latest one wins.
fn recordUsageUpdate(update: std.json.Value, usage: *TurnUsage) void {
    if (jsonUnsigned(getObjectField(update, "used"))) |used| usage.context_used = used;
    if (jsonUnsigned(getObjectField(update, "size"))) |size| usage.context_size = size;
    const cost = getObjectField(update, "cost") orelse return;
    if (cost != .object) return;
    if (jsonFloat(getObjectField(cost, "amount"))) |amount| {
        usage.cost_amount = amount;
        usage.setCurrency(getOptionalObjectString(cost, "currency") orelse "USD");
    }
}

// Prompt response token counts: `result.usage` per the ACP spec; grok puts
// the same figures under `result._meta`.
fn recordPromptUsage(result: std.json.Value, usage: *TurnUsage) void {
    const sources = [_]?std.json.Value{ getObjectField(result, "usage"), getObjectField(result, "_meta") };
    for (sources) |maybe_source| {
        const source = maybe_source orelse continue;
        if (source != .object) continue;
        if (jsonUnsigned(getObjectField(source, "inputTokens"))) |tokens| usage.input_tokens = tokens;
        if (jsonUnsigned(getObjectField(source, "outputTokens"))) |tokens| usage.output_tokens = tokens;
    }
}

/// One compact "Usage" system row per turn, e.g.
/// `Context: 61,234 of 500,000 tokens (12%) · Session cost: $0.12 · Last turn: 1,200 in / 340 out`.
fn emitUsageSummary(allocator: std.mem.Allocator, request: provider_types.SendPromptRequest, state: *SendPromptState) !void {
    const on_stream_event = request.on_stream_event orelse return;
    const usage = &state.usage;
    if (usage.isEmpty()) return;
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const w = &body.writer;
    var parts: usize = 0;
    if (usage.context_used) |used| {
        try w.writeAll("Context: ");
        try writeGrouped(w, used);
        if (usage.context_size) |size| {
            try w.writeAll(" of ");
            try writeGrouped(w, size);
            try w.writeAll(" tokens");
            if (size > 0) try w.print(" ({d}%)", .{@min(used * 100 / size, 100)});
        } else {
            try w.writeAll(" tokens");
        }
        parts += 1;
    }
    if (usage.cost_amount) |amount| {
        if (parts > 0) try w.writeAll(" · ");
        if (std.mem.eql(u8, usage.currency(), "USD")) {
            try w.print("Session cost: ${d:.2}", .{amount});
        } else {
            try w.print("Session cost: {d:.2} {s}", .{ amount, usage.currency() });
        }
        parts += 1;
    }
    if (usage.input_tokens != null or usage.output_tokens != null) {
        if (parts > 0) try w.writeAll(" · ");
        try w.writeAll("Last turn: ");
        try writeGrouped(w, usage.input_tokens orelse 0);
        try w.writeAll(" in / ");
        try writeGrouped(w, usage.output_tokens orelse 0);
        try w.writeAll(" out");
    }
    on_stream_event(request.stream_context, .{ .message = .{ .title = "Usage", .body = body.written() } });
}

fn writeGrouped(w: *std.Io.Writer, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    for (text, 0..) |digit, index| {
        if (index > 0 and (text.len - index) % 3 == 0) try w.writeByte(',');
        try w.writeByte(digit);
    }
}

fn jsonUnsigned(value: ?std.json.Value) ?u64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0) @intFromFloat(@floor(f)) else null,
        else => null,
    };
}

fn jsonFloat(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

/// ACP `plan` updates carry the complete entry list each time. Publish it as
/// the "Todos" task list the transcript renders as a plan card.
fn emitPlanUpdate(
    allocator: std.mem.Allocator,
    update: std.json.Value,
    request: provider_types.SendPromptRequest,
    state: *SendPromptState,
) !void {
    const on_stream_event = request.on_stream_event orelse return;
    const body = (try planBodyAlloc(allocator, update)) orelse return;
    defer allocator.free(body);
    const hash = std.hash.Wyhash.hash(0, body);
    if (state.last_plan_hash == hash) return;
    state.last_plan_hash = hash;
    finishThinking(request, state);
    on_stream_event(request.stream_context, .{ .message = .{
        .title = "Todos",
        .body = body,
    } });
}

fn planBodyAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const entries = getObjectField(update, "entries") orelse return null;
    if (entries != .array) return null;
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();
    for (entries.array.items) |entry| {
        const raw_content = getOptionalObjectString(entry, "content") orelse continue;
        const content = std.mem.trim(u8, raw_content, " \t\r\n");
        if (content.len == 0) continue;
        const status = getOptionalObjectString(entry, "status") orelse "pending";
        const marker = if (std.mem.eql(u8, status, "completed"))
            "x"
        else if (std.mem.eql(u8, status, "in_progress"))
            ">"
        else
            " ";
        // Keep each entry on one line; the card parses line by line.
        try body.writer.print("- [{s}] ", .{marker});
        for (content) |byte| try body.writer.writeByte(if (byte == '\n' or byte == '\r') ' ' else byte);
        try body.writer.writeByte('\n');
    }
    if (body.written().len == 0) {
        body.deinit();
        return null;
    }
    return try body.toOwnedSlice();
}

/// Opens a content-less `think` row so the GUI shows "Thinking" while an
/// agent streams reasoning. The shared upsert drops the row again once the
/// terminal status lands, mirroring Codex reasoning items.
fn startThinking(request: provider_types.SendPromptRequest, state: *SendPromptState) void {
    if (state.thinking) return;
    state.thinking = true;
    state.thought_segments +|= 1;
    emitThinkStatus(request, state.thought_segments, .in_progress);
}

fn finishThinking(request: provider_types.SendPromptRequest, state: *SendPromptState) void {
    if (!state.thinking) return;
    state.thinking = false;
    emitThinkStatus(request, state.thought_segments, .completed);
}

fn emitThinkStatus(request: provider_types.SendPromptRequest, segment: u32, status: provider_types.ToolCallStatus) void {
    const on_stream_event = request.on_stream_event orelse return;
    var id_buf: [32]u8 = undefined;
    const call_id = std.fmt.bufPrint(&id_buf, "acp-thought-{d}", .{segment}) catch return;
    on_stream_event(request.stream_context, .{ .tool_call = .{
        .call_id = call_id,
        .title = "",
        .kind = .think,
        .status = status,
    } });
}

/// Surfaces the agent's own JSON-RPC error text (image rejected, session
/// inactive, credential expired) so the failed turn explains itself instead
/// of showing a bare error name.
fn reportJsonRpcFailure(request: provider_types.SendPromptRequest, value: std.json.Value) void {
    const on_failure = request.on_failure orelse return;
    const error_value = getObjectField(value, "error") orelse return;
    const message = std.mem.trim(u8, getOptionalObjectString(error_value, "message") orelse return, " \t\r\n");
    if (message.len == 0) return;
    on_failure(request.stream_context, message);
}

fn emitDiffUpdate(
    allocator: std.mem.Allocator,
    update: std.json.Value,
    serialized_output: ?[]const u8,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) void {
    if (findTextDiff(update)) |diff| {
        if (emitTextDiffUpdate(allocator, diff, context, on_stream_event)) return;
    }
    if (serialized_output) |output| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch null;
        if (parsed) |*owned| {
            defer owned.deinit();
            if (findTextDiff(owned.value)) |diff| {
                if (emitTextDiffUpdate(allocator, diff, context, on_stream_event)) return;
            }
        }
    }

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

fn emitTextDiffUpdate(
    allocator: std.mem.Allocator,
    diff: TextDiff,
    context: ?*anyopaque,
    on_stream_event: *const fn (?*anyopaque, provider_types.StreamEvent) void,
) bool {
    const patch = textDiffPatchAlloc(allocator, diff) catch return false;
    defer allocator.free(patch);
    if (patch.len == 0) return false;
    const files = [_]provider_types.StreamDiffFile{.{
        .path = diff.path,
        .additions = countUnifiedPatchLines(patch, '+'),
        .deletions = countUnifiedPatchLines(patch, '-'),
        .patch = patch,
    }};
    on_stream_event(context, .{ .diff = .{ .files = &files } });
    return true;
}

const TextDiff = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    created: bool,
};

fn findTextDiff(value: std.json.Value) ?TextDiff {
    switch (value) {
        .object => |object| {
            const content_type = getOptionalObjectString(value, "type") orelse "";
            if (std.mem.eql(u8, content_type, "diff")) {
                const path = getOptionalObjectString(value, "path") orelse return null;
                const old_value = object.get("oldText") orelse return null;
                const new_value = object.get("newText") orelse return null;
                const old_text: []const u8 = switch (old_value) {
                    .string => |text| text,
                    .null => "",
                    else => return null,
                };
                const new_text: []const u8 = switch (new_value) {
                    .string => |text| text,
                    else => return null,
                };
                return .{
                    .path = path,
                    .old_text = old_text,
                    .new_text = new_text,
                    .created = old_value == .null,
                };
            }

            var fields = object.iterator();
            while (fields.next()) |field| {
                if (findTextDiff(field.value_ptr.*)) |diff| return diff;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findTextDiff(item)) |diff| return diff;
            }
        },
        else => {},
    }
    return null;
}

fn textDiffPatchAlloc(allocator: std.mem.Allocator, diff: TextDiff) ![]u8 {
    if (std.mem.eql(u8, diff.old_text, diff.new_text)) return allocator.dupe(u8, "");

    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(allocator);
    try appendTextLines(allocator, &old_lines, diff.old_text);
    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(allocator);
    try appendTextLines(allocator, &new_lines, diff.new_text);

    const common_len = @min(old_lines.items.len, new_lines.items.len);
    var prefix_len: usize = 0;
    while (prefix_len < common_len and std.mem.eql(u8, old_lines.items[prefix_len], new_lines.items[prefix_len])) {
        prefix_len += 1;
    }

    var suffix_len: usize = 0;
    while (suffix_len < common_len - prefix_len and
        std.mem.eql(
            u8,
            old_lines.items[old_lines.items.len - suffix_len - 1],
            new_lines.items[new_lines.items.len - suffix_len - 1],
        ))
    {
        suffix_len += 1;
    }

    const context_lines: usize = 3;
    const context_start = prefix_len - @min(prefix_len, context_lines);
    const trailing_context = @min(suffix_len, context_lines);
    const old_change_end = old_lines.items.len - suffix_len;
    const new_change_end = new_lines.items.len - suffix_len;
    const old_hunk_end = old_change_end + trailing_context;
    const new_hunk_end = new_change_end + trailing_context;
    const old_count = old_hunk_end - context_start;
    const new_count = new_hunk_end - context_start;
    const old_start = if (old_count == 0) @as(usize, 0) else context_start + 1;
    const new_start = if (new_count == 0) @as(usize, 0) else context_start + 1;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    if (diff.created) {
        try writer.writer.print("--- /dev/null\n+++ b/{s}\n", .{diff.path});
    } else {
        try writer.writer.print("--- a/{s}\n+++ b/{s}\n", .{ diff.path, diff.path });
    }
    try writer.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });

    for (old_lines.items[context_start..prefix_len]) |line| try writer.writer.print(" {s}\n", .{line});
    for (old_lines.items[prefix_len..old_change_end]) |line| try writer.writer.print("-{s}\n", .{line});
    for (new_lines.items[prefix_len..new_change_end]) |line| try writer.writer.print("+{s}\n", .{line});
    for (old_lines.items[old_change_end..old_hunk_end]) |line| try writer.writer.print(" {s}\n", .{line});
    return writer.toOwnedSlice();
}

fn appendTextLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    if (text.len == 0) return;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    // A trailing newline terminates the last line; it does not start another.
    if (text[text.len - 1] == '\n') lines.items.len -= 1;
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

fn handlePermissionRequest(
    allocator: std.mem.Allocator,
    harness: Harness,
    value: std.json.Value,
    request: provider_types.SendPromptRequest,
    stdin: ?std.Io.File,
) !void {
    const id = serverRequestId(value) orelse return;
    const params = getObjectField(value, "params") orelse value;
    const tool_call = getObjectField(params, "toolCall") orelse params;
    const title = getOptionalObjectString(tool_call, "title") orelse getOptionalObjectString(params, "title") orelse harness.permission_default_title;
    const body = permissionBody(params);
    const call_id = getOptionalObjectString(tool_call, "toolCallId") orelse getOptionalObjectString(params, "permissionId") orelse "acp-tool";
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

fn permissionOptionId(params: std.json.Value, decision: provider_types.ApprovalDecision) ?[]const u8 {
    const options = getObjectField(params, "options") orelse return null;
    if (options != .array) return null;
    const desired = if (decision == .approve) "allow_once" else "reject_once";
    const persistent = if (decision == .approve) "allow_always" else "reject_always";
    var fallback: ?[]const u8 = null;
    for (options.array.items) |option| {
        const id = getOptionalObjectString(option, "optionId") orelse getOptionalObjectString(option, "id") orelse continue;
        const kind = getOptionalObjectString(option, "kind") orelse id;
        if (std.mem.eql(u8, kind, desired) or std.mem.eql(u8, kind, if (decision == .approve) "allow-once" else "reject-once")) return id;
        if (std.mem.eql(u8, kind, persistent) or std.mem.eql(u8, kind, if (decision == .approve) "allow-always" else "reject-always")) fallback = id;
    }
    // Never answer a rejection with an unrelated (possibly approving) option.
    return fallback;
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

const ToolEvent = struct {
    call_id: []u8,
    title: []u8,
    tool_kind: ?provider_types.ToolCallKind,
    status: ?provider_types.ToolCallStatus,
    input: ?[]u8,
    output: ?[]u8,
    error_text: ?[]u8,
    locations: ?[]u8,
    raw: []u8,

    fn deinit(self: ToolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.title);
        if (self.input) |value| allocator.free(value);
        if (self.output) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        if (self.locations) |value| allocator.free(value);
        allocator.free(self.raw);
    }
};

fn toolEventAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?ToolEvent {
    const title = try toolTitleAlloc(allocator, update);
    errdefer allocator.free(title);
    const call_id_text = toolCallId(update) orelse "";
    const status = toolStatus(update);
    const input = try toolInputAlloc(allocator, update);
    errdefer if (input) |value| allocator.free(value);
    const output = try toolOutputAlloc(allocator, update);
    errdefer if (output) |value| allocator.free(value);
    const error_text = try toolErrorAlloc(allocator, update, status);
    errdefer if (error_text) |value| allocator.free(value);
    const locations = try toolLocationsAlloc(allocator, update);
    errdefer if (locations) |value| allocator.free(value);
    const raw = try jsonValueCompactAlloc(allocator, update);
    errdefer allocator.free(raw);

    const has_meaningful_content = input != null or output != null or error_text != null or locations != null;
    if (call_id_text.len == 0 and !has_meaningful_content and title.len == 0) {
        allocator.free(title);
        allocator.free(raw);
        return null;
    }

    return .{
        .call_id = try allocator.dupe(u8, call_id_text),
        .title = title,
        .tool_kind = toolKind(update),
        .status = status,
        .input = input,
        .output = output,
        .error_text = error_text,
        .locations = locations,
        .raw = raw,
    };
}

fn toolCallId(update: std.json.Value) ?[]const u8 {
    if (getTrimmedObjectString(update, "toolCallId")) |call_id| return call_id;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (getTrimmedObjectString(tool_call, "toolCallId")) |call_id| return call_id;
        if (getTrimmedObjectString(tool_call, "id")) |call_id| return call_id;
    }
    return null;
}

fn toolKind(update: std.json.Value) ?provider_types.ToolCallKind {
    if (mcpToolName(update) != null) return .mcp;
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
        if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "subagent") or std.mem.eql(u8, kind, "agent")) return .subagent;
        // ACP `other` is deliberately non-specific. Let provider titles such
        // as `MCP: ...` refine it, and otherwise preserve an earlier kind.
        if (!std.mem.eql(u8, kind, "other")) return .other;
    }

    const title = toolTitle(update) orelse "";
    const tool_name = getTrimmedObjectString(update, "toolName") orelse nested_name: {
        const tool_call = getObjectField(update, "toolCall") orelse break :nested_name "";
        break :nested_name getTrimmedObjectString(tool_call, "toolName") orelse
            getTrimmedObjectString(tool_call, "name") orelse
            "";
    };
    if (provider_types.isSubagentToolName(title) or provider_types.isSubagentToolName(tool_name)) return .subagent;
    // Grok uses the task description as its title and identifies the native
    // tool through rawInput.variant, rather than ACP's toolName field.
    const raw_input = getObjectField(update, "rawInput") orelse nested_input: {
        const tool_call = getObjectField(update, "toolCall") orelse break :nested_input null;
        break :nested_input getObjectField(tool_call, "rawInput");
    };
    if (raw_input) |input| {
        if (getTrimmedObjectString(input, "variant")) |variant| {
            if (std.mem.eql(u8, variant, "Task")) return .subagent;
        }
    }
    if (std.ascii.startsWithIgnoreCase(title, "mcp") or std.ascii.startsWithIgnoreCase(title, "verde:")) return .mcp;
    if (getTrimmedObjectString(update, "command") != null or title.len > 0 and title[0] == '`') return .execute;
    if (std.ascii.startsWithIgnoreCase(title, "read")) return .read;
    if (std.ascii.startsWithIgnoreCase(title, "edit") or std.ascii.startsWithIgnoreCase(title, "write")) return .edit;
    if (std.ascii.startsWithIgnoreCase(title, "grep") or std.ascii.startsWithIgnoreCase(title, "find") or std.ascii.startsWithIgnoreCase(title, "search")) return .search;
    return null;
}

fn toolStatus(update: std.json.Value) ?provider_types.ToolCallStatus {
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

fn toolTitle(update: std.json.Value) ?[]const u8 {
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

fn toolTitleAlloc(allocator: std.mem.Allocator, update: std.json.Value) ![]u8 {
    if (mcpToolName(update)) |tool_name| {
        return std.fmt.allocPrint(allocator, "MCP: {s}", .{tool_name});
    }
    if (toolTitle(update)) |title| return allocator.dupe(u8, title);
    return allocator.dupe(u8, "");
}

fn mcpToolName(update: std.json.Value) ?[]const u8 {
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

fn toolInputAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "rawInput", "input", "args", "arguments", "params", "command" };
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return toolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn toolOutputAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{ "rawOutput", "output", "result", "content" };
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return toolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn toolErrorAlloc(
    allocator: std.mem.Allocator,
    update: std.json.Value,
    status: ?provider_types.ToolCallStatus,
) !?[]u8 {
    const field_names = [_][]const u8{ "error", "errorMessage" };
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        if (try toolFieldsAlloc(allocator, tool_call, &field_names)) |value| return value;
    }
    if ((status orelse .unknown) != .failed) return null;
    if (getTrimmedObjectString(update, "body")) |body| return try allocator.dupe(u8, body);
    if (getTrimmedObjectString(update, "description")) |description| return try allocator.dupe(u8, description);
    return null;
}

fn toolLocationsAlloc(allocator: std.mem.Allocator, update: std.json.Value) !?[]u8 {
    const field_names = [_][]const u8{"locations"};
    if (try toolFieldsAlloc(allocator, update, &field_names)) |value| return value;
    if (getObjectField(update, "toolCall")) |tool_call| {
        return toolFieldsAlloc(allocator, tool_call, &field_names);
    }
    return null;
}

fn toolFieldsAlloc(
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
    harness: Harness,
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
            .assistant => harness.assistant_author,
            .system => "System",
        }),
        .body = try allocator.dupe(u8, trimmed),
    });
}

fn writeJsonRpcHead(stringify: *std.json.Stringify, id: i64, method: []const u8) !void {
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("method");
    try stringify.write(method);
}

fn makeSessionSetupRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    session_id: ?[]const u8,
    cwd: []const u8,
    mcp_server: ?McpServer,
    meta: ?SessionMetaWriter,
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
    if (mcp_server) |server| {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write("verde");
        switch (server) {
            .stdio => |executable| {
                try stringify.objectField("command");
                try stringify.write(executable);
                try stringify.objectField("args");
                try stringify.beginArray();
                try stringify.write("mcp");
                try stringify.endArray();
                try stringify.objectField("env");
                try stringify.beginArray();
                try writeAcpNameValue(&stringify, "VERDE_MCP_MANAGED", "1");
                try stringify.endArray();
            },
            .http => |http| {
                try stringify.objectField("type");
                try stringify.write("http");
                try stringify.objectField("url");
                try stringify.write(http.url);
                try stringify.objectField("headers");
                try stringify.beginArray();
                try writeAcpNameValue(&stringify, "Authorization", http.authorization);
                try writeAcpNameValue(&stringify, "X-Verde-MCP-Client", http.client_name);
                try writeAcpNameValue(&stringify, "X-Verde-MCP-Managed", "1");
                try stringify.endArray();
            },
        }
        try stringify.endObject();
    }
    try stringify.endArray();
    if (meta) |write_meta| {
        try stringify.objectField("_meta");
        try write_meta(&stringify);
    }
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn writeAcpNameValue(stringify: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try stringify.beginObject();
    try stringify.objectField("name");
    try stringify.write(name);
    try stringify.objectField("value");
    try stringify.write(value);
    try stringify.endObject();
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

fn isAuthError(message: []const u8) bool {
    // fx 0.0.8 reports expired or replaced credentials at prompt time as
    // "<provider> requires a new sign-in." / "Credential ..." notices.
    return std.mem.indexOf(u8, message, "auth") != null or
        std.mem.indexOf(u8, message, "login") != null or
        std.mem.indexOf(u8, message, "API key") != null or
        std.mem.indexOf(u8, message, "unauthorized") != null or
        std.mem.indexOf(u8, message, "sign-in") != null or
        std.mem.indexOf(u8, message, "sign in") != null or
        std.ascii.indexOfIgnoreCase(message, "credential") != null;
}

const TEST_HARNESS: Harness = .{
    .diagnostics_category = .cursor_acp,
    .assistant_author = "Assistant",
    .permission_default_title = "Permission request",
};

fn testAgentErrorMessage(text: []const u8) ?[]const u8 {
    return if (std.mem.indexOf(u8, text, "provider busy") != null) "Friendly provider message" else null;
}

const ERROR_TEST_HARNESS: Harness = .{
    .diagnostics_category = .cursor_acp,
    .assistant_author = "Assistant",
    .permission_default_title = "Permission request",
    .agent_error_message = testAgentErrorMessage,
};

const TestDiffCapture = struct {
    count: usize = 0,
    path: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    patch_storage: [4096]u8 = undefined,
    additions: i64 = 0,
    deletions: i64 = 0,

    fn handle(context: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *TestDiffCapture = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .diff => |diff| {
                if (diff.files.len == 0) return;
                self.count += 1;
                self.path = diff.files[0].path;
                if (diff.files[0].patch) |patch| {
                    if (patch.len <= self.patch_storage.len) {
                        @memcpy(self.patch_storage[0..patch.len], patch);
                        self.patch = self.patch_storage[0..patch.len];
                    }
                }
                self.additions = diff.files[0].additions;
                self.deletions = diff.files[0].deletions;
            },
            else => {},
        }
    }
};

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
    try handleReadSessionUpdate(std.testing.allocator, TEST_HARNESS, parsed_one.value, &state);
    try handleReadSessionUpdate(std.testing.allocator, TEST_HARNESS, parsed_two.value, &state);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("hello", state.messages.items[0].body);
    try std.testing.expectEqualStrings("Assistant", state.messages.items[0].author);
}

test "agent prose errors are rewritten and duplicate retries are suppressed" {
    const payload =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Error: provider busy"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var history: ReadThreadState = .{};
    defer history.deinit(std.testing.allocator);
    try handleReadSessionUpdate(std.testing.allocator, ERROR_TEST_HARNESS, parsed.value, &history);
    try handleReadSessionUpdate(std.testing.allocator, ERROR_TEST_HARNESS, parsed.value, &history);
    try std.testing.expectEqual(@as(usize, 1), history.messages.items.len);
    try std.testing.expectEqualStrings("Friendly provider message", history.messages.items[0].body);

    var live: SendPromptState = .{ .prompt_submitted = true };
    defer live.deinit(std.testing.allocator);
    const request: provider_types.SendPromptRequest = .{ .prompt = "hello" };
    _ = try handleSendPromptLine(std.testing.allocator, ERROR_TEST_HARNESS, payload, request, &live, null);
    _ = try handleSendPromptLine(std.testing.allocator, ERROR_TEST_HARNESS, payload, request, &live, null);
    try std.testing.expect(live.agent_error_emitted);
    try std.testing.expectEqualStrings("Friendly provider message", live.reply.items);
}

test "ACP text diff content emits a compact structured patch" {
    const payload =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call-1","title":"Edit File","kind":"edit","status":"completed","content":[{"type":"diff","path":"src/main.zig","oldText":"const a = 1;\nconst b = 2;\nconst c = 3;\n","newText":"const a = 1;\nconst b = 4;\nconst c = 3;\n"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    var capture: TestDiffCapture = .{};
    emitDiffUpdate(std.testing.allocator, parsed.value, null, &capture, TestDiffCapture.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("src/main.zig", capture.path.?);
    try std.testing.expectEqual(@as(i64, 1), capture.additions);
    try std.testing.expectEqual(@as(i64, 1), capture.deletions);
    try std.testing.expectEqualStrings(
        "--- a/src/main.zig\n" ++
            "+++ b/src/main.zig\n" ++
            "@@ -1,3 +1,3 @@\n" ++
            " const a = 1;\n" ++
            "-const b = 2;\n" ++
            "+const b = 4;\n" ++
            " const c = 3;\n",
        capture.patch.?,
    );
}

test "toolEvent maps ACP titles, kinds, statuses, and inputs" {
    const cases = [_]struct {
        payload: []const u8,
        title: []const u8,
        kind: ?provider_types.ToolCallKind = null,
        status: ?provider_types.ToolCallStatus = null,
        input: ?[]const u8 = null,
    }{
        .{
            .payload =
            \\{"sessionUpdate":"tool_call","title":"Shell","command":"git status --short","status":"pending"}
            ,
            .title = "Shell",
            .kind = .execute,
            .input = "git status --short",
        },
        // Non-lifecycle failures keep their status.
        .{
            .payload =
            \\{"sessionUpdate":"tool_call_update","toolName":"edit","status":"failed"}
            ,
            .title = "edit",
            .status = .failed,
        },
        .{
            .payload =
            \\{"sessionUpdate":"tool_call","toolName":"Read","input":{"path":"/tmp/a.txt"},"status":"pending"}
            ,
            .title = "Read",
            .kind = .read,
            .input = "{\"path\":\"/tmp/a.txt\"}",
        },
        .{
            .payload =
            \\{"sessionUpdate":"tool_call","toolCallId":"task-1","toolName":"task","title":"Explore website","status":"in_progress"}
            ,
            .title = "Explore website",
            .kind = .subagent,
        },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.payload, .{});
        defer parsed.deinit();
        const event = (try toolEventAlloc(std.testing.allocator, parsed.value)).?;
        defer event.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.title, event.title);
        if (case.kind) |kind| try std.testing.expectEqual(kind, event.tool_kind.?);
        if (case.status) |status| try std.testing.expectEqual(status, event.status.?);
        if (case.input) |input| try std.testing.expectEqualStrings(input, event.input.?);
    }
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
    const action = try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null);
    try std.testing.expectEqual(SendLineAction.session_ready, action);
    try std.testing.expectEqualStrings("existing-session", state.session_id.?);
}

test "handleSendPromptLine fails the turn when the prompt result is refused" {
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    state.prompt_submitted = true;
    const request = provider_types.SendPromptRequest{ .prompt = "yo" };
    const refused =
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"refused"}}
    ;
    try std.testing.expectError(error.AcpRefused, handleSendPromptLine(std.testing.allocator, TEST_HARNESS, refused, request, &state, null));
    const done =
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
    ;
    try std.testing.expectEqual(SendLineAction.prompt_done, try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, done, request, &state, null));
}

test "agent_thought_chunk drives a transient think lifecycle" {
    const Capture = struct {
        var in_progress: usize = 0;
        var completed: usize = 0;
        var last_call_id: [32]u8 = undefined;
        var last_call_id_len: usize = 0;
        fn onEvent(_: ?*anyopaque, event: provider_types.StreamEvent) void {
            switch (event) {
                .tool_call => |call| {
                    if ((call.kind orelse .other) != .think) return;
                    if (call.input != null or call.output != null) return;
                    switch (call.status orelse .unknown) {
                        .in_progress => in_progress += 1,
                        .completed => completed += 1,
                        else => {},
                    }
                    last_call_id_len = @min(call.call_id.len, last_call_id.len);
                    @memcpy(last_call_id[0..last_call_id_len], call.call_id[0..last_call_id_len]);
                },
                else => {},
            }
        }
    };
    Capture.in_progress = 0;
    Capture.completed = 0;
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    state.prompt_submitted = true;
    const request = provider_types.SendPromptRequest{ .prompt = "yo", .on_stream_event = Capture.onEvent };
    const thought =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"considering"}}}}
    ;
    const reply =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Ready."}}}}
    ;
    const done =
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":2}}}
    ;
    // Consecutive thought chunks open one row; the first visible text closes it.
    _ = try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, thought, request, &state, null);
    _ = try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, thought, request, &state, null);
    try std.testing.expect(state.thinking);
    try std.testing.expectEqual(@as(usize, 1), Capture.in_progress);
    try std.testing.expectEqual(@as(usize, 0), Capture.completed);
    _ = try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, reply, request, &state, null);
    try std.testing.expect(!state.thinking);
    try std.testing.expectEqual(@as(usize, 1), Capture.completed);
    try std.testing.expectEqualStrings("acp-thought-1", Capture.last_call_id[0..Capture.last_call_id_len]);
    // A second reasoning segment gets a fresh row id and is closed by the
    // prompt response when nothing visible follows it.
    _ = try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, thought, request, &state, null);
    try std.testing.expectEqual(@as(usize, 2), Capture.in_progress);
    try std.testing.expectEqualStrings("acp-thought-2", Capture.last_call_id[0..Capture.last_call_id_len]);
    try std.testing.expectEqual(SendLineAction.prompt_done, try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, done, request, &state, null));
    try std.testing.expect(!state.thinking);
    try std.testing.expectEqual(@as(usize, 2), Capture.completed);
    // Thought text never reaches the reply.
    try std.testing.expectEqualStrings("Ready.", state.reply.items);
}

test "handleSendPromptLine reports JSON-RPC error text through on_failure" {
    const Capture = struct {
        var message: [128]u8 = undefined;
        var message_len: usize = 0;
        fn onFailure(_: ?*anyopaque, text: []const u8) void {
            message_len = @min(text.len, message.len);
            @memcpy(message[0..message_len], text[0..message_len]);
        }
    };
    Capture.message_len = 0;
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    state.prompt_submitted = true;
    const request = provider_types.SendPromptRequest{ .prompt = "look", .on_failure = Capture.onFailure };
    const rejected =
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Image prompt exceeds size limit"}}
    ;
    try std.testing.expectError(error.AcpFailed, handleSendPromptLine(std.testing.allocator, TEST_HARNESS, rejected, request, &state, null));
    try std.testing.expectEqualStrings("Image prompt exceeds size limit", Capture.message[0..Capture.message_len]);

    const expired =
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"Vercel AI Gateway requires a new sign-in."}}
    ;
    try std.testing.expectError(error.AcpSignedOut, handleSendPromptLine(std.testing.allocator, TEST_HARNESS, expired, request, &state, null));
    try std.testing.expectEqualStrings("Vercel AI Gateway requires a new sign-in.", Capture.message[0..Capture.message_len]);
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
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null),
    );
    try std.testing.expectEqual(@as(usize, 0), state.reply.items.len);

    state.prompt_submitted = true;
    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, line, request, &state, null),
    );
    try std.testing.expectEqualStrings("replayed history", state.reply.items);
}

test "handleSendPromptLine ignores non-permission ACP server request id collisions" {
    var state: SendPromptState = .{
        .capabilities = .{ .image = true },
        .prompt_submitted = true,
    };
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{
        .thread_id = "existing-session",
        .prompt = "continue",
    };
    const initialize_collision =
        \\{"jsonrpc":"2.0","id":1,"method":"fs/read_text_file","params":{"path":"/tmp/example"}}
    ;
    const session_collision =
        \\{"jsonrpc":"2.0","id":2,"method":"terminal/wait_for_exit","params":{"terminalId":"terminal-1"}}
    ;

    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, initialize_collision, request, &state, null),
    );
    try std.testing.expect(state.capabilities.image);
    try std.testing.expectEqual(
        SendLineAction.continue_reading,
        try handleSendPromptLine(std.testing.allocator, TEST_HARNESS, session_collision, request, &state, null),
    );
    try std.testing.expect(state.session_id == null);
}

test "ACP permission decisions use kinds and never approve an unrecognized rejection" {
    var params = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"options":[{"optionId":"opaque-always","kind":"allow_always"},{"optionId":"opaque-once","kind":"allow_once"},{"optionId":"opaque-reject","kind":"reject_once"}]}
    , .{});
    defer params.deinit();
    try std.testing.expectEqualStrings("opaque-once", permissionOptionId(params.value, .approve).?);
    try std.testing.expectEqualStrings("opaque-reject", permissionOptionId(params.value, .deny).?);
    var only_allow = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"options":[{"optionId":"allow-once"}]}
    , .{});
    defer only_allow.deinit();
    try std.testing.expect(permissionOptionId(only_allow.value, .deny) == null);
    const response = try makePermissionResponseAlloc(std.testing.allocator, .{ .integer = 3 }, null);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"result":{"outcome":{"outcome":"cancelled"}}}
    , response);
}

test "ACP prompts preserve multiple images and reject unsupported attachments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.png", .data = "first-image" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.png", .data = "second-image" });
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const first = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "a.png" });
    defer allocator.free(first);
    const second = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "b.png" });
    defer allocator.free(second);
    const request: provider_types.SendPromptRequest = .{ .prompt = "Compare", .images = &.{ .{ .path = first }, .{ .path = second } } };
    const json = try makePromptRequestAlloc(allocator, 3, "session", request, true);
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const blocks = getObjectField(getObjectField(parsed.value, "params").?, "prompt").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("Zmlyc3QtaW1hZ2U=", getOptionalObjectString(blocks[1], "data").?);
    try std.testing.expectEqualStrings("c2Vjb25kLWltYWdl", getOptionalObjectString(blocks[2], "data").?);
    try std.testing.expectError(error.AcpAttachmentsUnsupported, makePromptRequestAlloc(allocator, 3, "session", request, false));

    // Text-only prompts never need image capability.
    const text_only = try makePromptRequestAlloc(allocator, 4, "session", .{ .prompt = "hello" }, false);
    defer allocator.free(text_only);
    var parsed_text = try std.json.parseFromSlice(std.json.Value, allocator, text_only, .{});
    defer parsed_text.deinit();
    const text_blocks = getObjectField(getObjectField(parsed_text.value, "params").?, "prompt").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), text_blocks.len);
    try std.testing.expectEqualStrings("text", getOptionalObjectString(text_blocks[0], "type").?);
}

fn testWriteMeta(stringify: *std.json.Stringify) std.json.Stringify.Error!void {
    try stringify.write(.{ .fx = .{ .profileMcpServers = true } });
}

test "makeTurnSessionRequestAlloc picks new, resume, or load and gates HTTP MCP" {
    const allocator = std.testing.allocator;
    const mcp: McpHttpServer = .{ .url = "http://127.0.0.1:9/mcp", .authorization = "Bearer t", .client_name = "test" };

    const fresh = try makeTurnSessionRequestAlloc(allocator, 2, .{ .mcp_http = true }, .{ .cwd = "/w", .mcp_http = mcp, .meta = testWriteMeta });
    defer allocator.free(fresh);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "\"method\":\"session/new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "\"sessionId\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "\"type\":\"http\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "\"_meta\":{\"fx\":{\"profileMcpServers\":true}}") != null);

    const resumed = try makeTurnSessionRequestAlloc(allocator, 2, .{ .resume_session = true }, .{ .cwd = "/w", .session_id = "s-1", .mcp_http = mcp });
    defer allocator.free(resumed);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"method\":\"session/resume\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"sessionId\":\"s-1\"") != null);
    // No mcpCapabilities.http: the server must not be sent.
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"mcpServers\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "_meta") == null);

    const loaded = try makeTurnSessionRequestAlloc(allocator, 2, .{}, .{ .cwd = "/w", .session_id = "s-1" });
    defer allocator.free(loaded);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "\"method\":\"session/load\"") != null);
}

test "available_commands_update feeds the live slash catalog merged with static rows" {
    var state: SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{ .prompt = "hi" };
    const update =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[
        \\{"name":"compact","description":"Compress history"},
        \\{"name":"simplify","description":"Find low-info comments. (global)"},
        \\{"name":"deep-research","description":"Research","input":{"hint":"<query>"}},
        \\{"name":"bad name","description":"rejected"},{"description":"no name"}]}}}
    ;
    // Before the prompt is submitted the update is still recorded.
    try std.testing.expectEqual(SendLineAction.continue_reading, try handleSendPromptLine(std.testing.allocator, .{
        .diagnostics_category = .fx_acp,
        .assistant_author = "FX",
        .permission_default_title = "Permission",
    }, update, request, &state, null));

    const static_rows = [_]provider_types.ProviderSlashCommand{.{
        .id = .compact,
        .name = "/compact",
        .summary = "Static compact.",
        .usage = "/compact",
        .requires_thread = true,
    }};
    const merged = try slashCommandsWithLiveAlloc(std.testing.allocator, .fx_acp, static_rows[0..]);
    defer freeSlashCommandList(std.testing.allocator, merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("/compact", merged[0].name);
    try std.testing.expectEqualStrings("Static compact.", merged[0].summary);
    try std.testing.expectEqualStrings("/simplify", merged[1].name);
    try std.testing.expectEqual(provider_types.ProviderSlashCommandId.custom, merged[1].id);
    try std.testing.expectEqualStrings("Find low-info comments. (global)", merged[1].summary);
    try std.testing.expectEqualStrings("/simplify", merged[1].usage);
    try std.testing.expectEqualStrings("/deep-research <query>", merged[2].usage);

    // Other harnesses are unaffected; providers without a live list keep
    // their static rows.
    const other = try slashCommandsWithLiveAlloc(std.testing.allocator, .custom_acp, static_rows[0..]);
    defer freeSlashCommandList(std.testing.allocator, other);
    try std.testing.expectEqual(@as(usize, 1), other.len);
    const plain = try slashCommandsWithLiveAlloc(std.testing.allocator, null, static_rows[0..]);
    defer freeSlashCommandList(std.testing.allocator, plain);
    try std.testing.expectEqual(@as(usize, 1), plain.len);

    // A later update replaces the list.
    var replaced = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[{"name":"loop","description":"Run on an interval"}]
    , .{});
    defer replaced.deinit();
    rememberAvailableCommands(.fx_acp, replaced.value);
    const latest = try slashCommandsWithLiveAlloc(std.testing.allocator, .fx_acp, &.{});
    defer freeSlashCommandList(std.testing.allocator, latest);
    try std.testing.expectEqual(@as(usize, 1), latest.len);
    try std.testing.expectEqualStrings("/loop", latest[0].name);
    var cleared = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[]", .{});
    defer cleared.deinit();
    rememberAvailableCommands(.fx_acp, cleared.value);
}

//! Verde-native terminal session identity and daemon protocol helpers.
//!
//! This module is intentionally separate from `terminal.zig`: terminal UI code
//! can import these small types while the long-lived PTY owner and CLI attach
//! behavior grow here instead of being buried in the renderer/pane code.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("../providers/harness.zig");
const headless = @import("headless");
const process_registry = @import("../daemon/process_registry.zig");
const platform_ipc = @import("../platform/ipc.zig");
const platform_live_endpoint = @import("../platform/live_endpoint.zig");
const workspace_identity = @import("../platform/workspace_identity.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const send_runner = @import("../chat/send_runner.zig");
const windows_conpty = @import("platform/windows_conpty.zig");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const log = std.log.scoped(.sessionizer);

pub const SOCKET_NAME = "verde-sessionizer.sock";
pub const LIVE_SOCKET_NAME = "verde.sock";
pub const PID_FILE_NAME = "verde-sessionizer.pid";
pub const WINDOWS_PIPE_PREFIX = "\\\\.\\pipe\\verde-sessionizer-";
// Bump whenever the daemon RPC/state surface changes incompatibly. GUI chat
// turns are daemon-owned now; accepting an older daemon makes the UI
// attach to a process that cannot list/tail those turns.
// Version 8 retires daemons whose Codex client could silently discard
// app-server tool requests and leave GUI turns pending forever.
// Version 9 transfers Codex server ownership to the daemon and retains
// completed chat turns until the desktop consumes them.
// Version 10 terminates the complete PTY process group for managed processes.
// Version 11 updates daemon-owned Codex resume limits and tool event mapping.
// Version 12 actively interrupts app-server turns when daemon sends are stopped.
// Version 13 transports structured tool-call lifecycle events to the desktop.
// Version 14 preserves provider-specific tool titles and inferred MCP kinds.
// Version 15 carries exact Verde MCP method names through Cursor tool results.
// Version 16 transports complete diff snapshots instead of empty diff events.
// Version 17 transports MCP tool outputs from every daemon-owned GUI provider.
// Version 18 reloads daemon-owned Cursor turns with structured edit diffs.
// Version 19 makes the daemon authoritative for lifecycle: bind-safe startup,
// prepare-for-upgrade drain instead of hard-kill, and persistent-by-default
// idle policy (see headless_verde.md Lifetime).
pub const PROTOCOL_VERSION: u32 = 19;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 30;
const MAX_OUTPUT_RING: usize = 1024 * 1024;
const DAEMON_POLL_READ_BUDGET: usize = 64 * 1024;
const SESSIONIZER_MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
/// Maximum response capacity accepted by the sessionizer protocol.
pub const MAX_RESPONSE_BYTES: usize = SESSIONIZER_MAX_MESSAGE_BYTES;
const SESSIONIZER_REQUEST_TIMEOUT_MS: u32 = 5000;
const ATTACH_STALE_MS: i64 = 60 * std.time.ms_per_s;
/// Env override so hermetic tests can force a fast idle exit without changing
/// production lifetime policy (null / unset = never idle-exit).
const IDLE_EXIT_ENV_NAME = "VERDE_SESSION_DAEMON_IDLE_EXIT_MS";
/// Bounded wait while an incompatible daemon drains live state before upgrade.
const REPLACEMENT_WAIT_MS: i64 = 5 * std.time.ms_per_s;
/// Extra grace after prepareShutdown accepts, independent of the prepare deadline.
const REPLACEMENT_GONE_GRACE_MS: i64 = 1 * std.time.ms_per_s;
const REPLACEMENT_POLL_MS: i64 = 50;
const REPLACEMENT_BIND_WAIT_MS: i64 = 1 * std.time.ms_per_s;
const LEGACY_TERMINATION_GRACE_MS: i64 = 500;
const TERMINAL_WINSIZE_IOCTL: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .windows => 0,
    else => @intCast(std.c.T.IOCSWINSZ),
};
const TERMINAL_GET_PGRP_IOCTL: ?c_int = switch (builtin.os.tag) {
    .linux => @intCast(std.c.T.IOCGPGRP),
    .macos => @bitCast(@as(u32, 0x40047477)),
    else => null,
};

pub const RevivePolicy = enum {
    attach_or_create,
    attach_only,
    restart,
    manual,
};

pub const LayoutContext = struct {
    project_id: []const u8,
    project_path: []const u8 = "",
    dock_id: u32,
};

pub const LeafSessionMetadata = struct {
    session_id: ?[]const u8 = null,
    revive_policy: RevivePolicy = .attach_or_create,
};

pub const SessionStatus = enum {
    missing,
    starting,
    running,
    exited,
};

pub const SessionSummary = struct {
    session_id: []const u8,
    project_id: []const u8 = "",
    project_path: []const u8 = "",
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    label: []const u8 = "",
    status: SessionStatus = .missing,
    created_at_ms: ?i64 = null,
    last_attached_at_ms: ?i64 = null,
};

pub const Method = enum {
    @"session.list",
    @"session.inspect",
    @"session.create",
    @"session.attach",
    @"session.detach",
    @"session.write",
    @"session.resize",
    @"session.tail",
    @"session.tail.batch",
    @"session.screen",
    @"session.kill",
    @"session.cleanup",

    pub fn text(self: Method) []const u8 {
        return @tagName(self);
    }
};

pub const METHOD_NAMES = [_][]const u8{
    "session.list",
    "session.inspect",
    "session.create",
    "session.attach",
    "session.detach",
    "session.write",
    "session.resize",
    "session.tail",
    "session.tail.batch",
    "session.screen",
    "session.kill",
    "session.cleanup",
};

test "session tail batching is an additive daemon method" {
    try std.testing.expectEqualStrings("session.tail", METHOD_NAMES[7]);
    try std.testing.expectEqualStrings("session.tail.batch", METHOD_NAMES[8]);
}

pub fn stableSessionId(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    dock_id: u32,
    pane_id: u32,
) ![]u8 {
    var safe_project_id: std.ArrayList(u8) = .empty;
    defer safe_project_id.deinit(allocator);
    try appendSafeComponent(allocator, &safe_project_id, project_id);
    if (safe_project_id.items.len == 0) try safe_project_id.appendSlice(allocator, "project");

    return try std.fmt.allocPrint(
        allocator,
        "verde:{s}:dock:{d}:pane:{d}",
        .{ safe_project_id.items, dock_id, pane_id },
    );
}

pub fn sessionIdForLeaf(
    allocator: std.mem.Allocator,
    context: ?LayoutContext,
    pane_id: u32,
    existing_session_id: ?[]const u8,
) !?[]u8 {
    if (existing_session_id) |session_id| return try allocator.dupe(u8, session_id);
    const ctx = context orelse return null;
    return try stableSessionId(allocator, ctx.project_id, ctx.dock_id, pane_id);
}

/// Env override for the sessionizer endpoint (Unix socket path or Windows
/// named-pipe path). When set and non-empty, clients and daemons use this
/// instead of deriving the endpoint from `pref_path`, so hermetic tests and
/// isolated CLI/MCP helpers never fall back to the user's live daemon.
pub const SESSIONIZER_SOCKET_ENV_NAME = "VERDE_SESSIONIZER_SOCKET";

pub fn socketPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (try sessionizerEndpointOverrideAlloc(allocator)) |override| return override;
    return defaultSocketPath(allocator, pref_path);
}

/// Pref-derived endpoint only (ignores `VERDE_SESSIONIZER_SOCKET`). Used by
/// hermetic spawners that compute an isolation path before installing the env
/// override for both client and daemon bind.
pub fn defaultSocketPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return windowsPipeName(allocator, pref_path);
    return std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
}

/// Returns a caller-owned endpoint when `VERDE_SESSIONIZER_SOCKET` is set.
fn sessionizerEndpointOverrideAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSIONIZER_SOCKET_ENV_NAME) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    errdefer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return owned;
}

fn windowsPipeName(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var end = pref_path.len;
    while (end > 0 and (pref_path[end - 1] == '\\' or pref_path[end - 1] == '/')) : (end -= 1) {}
    for (pref_path[0..end]) |byte| {
        const canonical = if (byte == '/') '\\' else std.ascii.toLower(byte);
        try normalized.append(allocator, canonical);
    }
    const hash = std.hash.Wyhash.hash(0, normalized.items);
    return std.fmt.allocPrint(allocator, "{s}{x:0>16}", .{ WINDOWS_PIPE_PREFIX, hash });
}

pub fn pidFilePath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ pref_path, PID_FILE_NAME });
}

pub fn requestAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
) ![]u8 {
    return requestAllocMaxResponse(
        allocator,
        pref_path,
        method,
        params,
        request_id,
        SESSIONIZER_MAX_MESSAGE_BYTES,
    );
}

/// Desktop transport adapter for `headless.Client`: send one raw request JSON
/// document to the session daemon at `pref_path` (or the endpoint override).
/// Keeps the headless package std-only; sockets/pipes live here.
pub const HeadlessTransport = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,

    pub fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *HeadlessTransport = @ptrCast(@alignCast(ctx));
        return try sendRequestJsonAlloc(self.allocator, self.pref_path, request_json);
    }
};

/// Send a pre-encoded request envelope to the sessionizer endpoint.
pub fn sendRequestJsonAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    request_json: []const u8,
) ![]u8 {
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    return try platform_ipc.requestAlloc(allocator, endpoint, request_json, .{
        .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
    });
}

/// Build a typed headless client bound to the sessionizer transport for `pref_path`.
pub fn headlessClient(allocator: std.mem.Allocator, transport: *HeadlessTransport) headless.Client {
    return headless.Client.init(allocator, transport, HeadlessTransport.send);
}

/// Sends one daemon request while bounding the response scratch allocation.
pub fn requestAllocMaxResponse(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
    max_response_bytes: usize,
) ![]u8 {
    std.debug.assert(max_response_bytes > 0 and max_response_bytes <= SESSIONIZER_MAX_MESSAGE_BYTES);
    const result = try requestWithPeerAlloc(
        allocator,
        pref_path,
        method,
        params,
        request_id,
        max_response_bytes,
        null,
    );
    return result.response;
}

/// Sends one daemon request using caller-owned response scratch space.
///
/// The returned response remains allocator-owned.
fn requestAllocUsingBufferDirect(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
    response_buffer: []u8,
) ![]u8 {
    std.debug.assert(response_buffer.len > 0 and response_buffer.len <= SESSIONIZER_MAX_MESSAGE_BYTES);
    const result = try requestWithPeerAlloc(
        allocator,
        pref_path,
        method,
        params,
        request_id,
        response_buffer.len,
        response_buffer,
    );
    return result.response;
}

/// Compatibility wrapper retaining the old call-site lifetime shape. The
/// daemon serves one request per connection, so each call deliberately opens
/// a fresh transport instead of silently retrying a dead reusable stream.
pub const ReusableRequestConnection = struct {
    pub fn deinit(self: *ReusableRequestConnection) void {
        self.* = .{};
    }

    pub fn requestAllocUsingBuffer(
        self: *ReusableRequestConnection,
        allocator: std.mem.Allocator,
        pref_path: []const u8,
        method: []const u8,
        params: anytype,
        request_id: u64,
        response_buffer: []u8,
    ) ![]u8 {
        _ = self;
        return requestAllocUsingBufferDirect(allocator, pref_path, method, params, request_id, response_buffer);
    }
};

test "reusable daemon connection rejects a stale response id" {
    const allocator = std.testing.allocator;
    const response = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}");
    try std.testing.expectError(
        error.ResponseIdMismatch,
        validateResponseAndKeepAlloc(allocator, response, 8),
    );
}

const RequestResult = struct {
    response: []u8,
    authenticated_server_process_id: ?u32 = null,
};

const RequestTransport = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    max_response_bytes: usize,
    response_buffer: ?[]u8,
    authenticated_server_process_id: ?u32 = null,

    fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *RequestTransport = @ptrCast(@alignCast(ctx));
        const socket_path = try socketPath(self.allocator, self.pref_path);
        defer self.allocator.free(socket_path);

        if (builtin.os.tag == .windows) {
            const result = try platform_ipc.requestWithPeerAlloc(self.allocator, socket_path, request_json, .{
                .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
                .max_response_bytes = self.max_response_bytes,
                .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
            });
            self.authenticated_server_process_id = result.server_process_id;
            return result.response;
        }

        const stream = try connectUnixStreamAtPath(socket_path);
        defer stream.close(std.Io.Threaded.global_single_threaded.io());
        const read_buffer = self.response_buffer orelse try self.allocator.alloc(u8, self.max_response_bytes);
        defer if (self.response_buffer == null) self.allocator.free(read_buffer);
        return try requestJsonOnUnixStreamAlloc(self.allocator, stream, request_json, read_buffer);
    }
};

fn requestWithPeerAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
    max_response_bytes: usize,
    response_buffer: ?[]u8,
) !RequestResult {
    var transport: RequestTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .max_response_bytes = max_response_bytes,
        .response_buffer = response_buffer,
    };
    var client = headless.Client.init(allocator, &transport, RequestTransport.send);
    var call = try client.callAllocWithId(request_id, method, params);
    const response = call.takeResponse();
    call.deinit(allocator);
    return .{
        .response = response,
        .authenticated_server_process_id = transport.authenticated_server_process_id,
    };
}

fn validateResponseAndKeepAlloc(allocator: std.mem.Allocator, response: []u8, request_id: u64) ![]u8 {
    var client = headless.Client.initEncoder(allocator);
    var parsed = client.parseResponseWithId(request_id, response) catch |err| {
        allocator.free(response);
        return err;
    };
    parsed.deinit();
    return response;
}

fn connectUnixStreamAtPath(socket_path: []const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    return address.connect(std.Io.Threaded.global_single_threaded.io());
}

fn requestJsonOnUnixStreamAlloc(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    request_json: []const u8,
    response_buffer: []u8,
) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request_json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var reader = stream.reader(io, response_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.ConnectionAborted;
    return allocator.dupe(u8, std.mem.trim(u8, line, "\r"));
}
const DaemonStatus = struct {
    protocol_version: u32,
    pid: ?usize = null,
    session_count: ?usize = null,
    chat_turn_count: ?usize = null,
    running_session_count: ?usize = null,
    keep_alive_turn_count: ?usize = null,
    accepting_mutations: ?bool = null,
    shutdown_requested: ?bool = null,
};

const PrepareShutdownResult = struct {
    accepted: bool,
    safe_to_exit: bool,
    running_sessions: usize,
    keep_alive_turns: usize,
    shutdown_requested: bool,
    method_missing: bool = false,
};

fn parseDaemonStatus(allocator: std.mem.Allocator, response: []const u8) ?DaemonStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const protocol_version = jsonU32(result.object.get("protocol_version") orelse .null) orelse return null;
    const pid = jsonUsize(result.object.get("pid") orelse .null);
    return .{
        .protocol_version = protocol_version,
        .pid = pid,
        .session_count = jsonUsize(result.object.get("session_count") orelse .null),
        .chat_turn_count = jsonUsize(result.object.get("chat_turn_count") orelse .null),
        .running_session_count = jsonUsize(result.object.get("running_session_count") orelse .null),
        .keep_alive_turn_count = jsonUsize(result.object.get("keep_alive_turn_count") orelse .null),
        .accepting_mutations = jsonBool(result.object.get("accepting_mutations") orelse .null),
        .shutdown_requested = jsonBool(result.object.get("shutdown_requested") orelse .null),
    };
}

fn parsePrepareShutdownResult(allocator: std.mem.Allocator, response: []const u8) ?PrepareShutdownResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("error")) |err_value| {
        if (err_value == .object) {
            const code = jsonString(err_value.object.get("code") orelse .null) orelse return null;
            if (std.mem.eql(u8, code, "method_not_found")) {
                return .{
                    .accepted = false,
                    .safe_to_exit = false,
                    .running_sessions = 0,
                    .keep_alive_turns = 0,
                    .shutdown_requested = false,
                    .method_missing = true,
                };
            }
        }
        return null;
    }
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    return .{
        .accepted = jsonBool(result.object.get("accepted") orelse .null) orelse false,
        .safe_to_exit = jsonBool(result.object.get("safe_to_exit") orelse .null) orelse false,
        .running_sessions = jsonUsize(result.object.get("running_sessions") orelse .null) orelse 0,
        .keep_alive_turns = jsonUsize(result.object.get("keep_alive_turns") orelse .null) orelse 0,
        .shutdown_requested = jsonBool(result.object.get("shutdown_requested") orelse .null) orelse false,
    };
}

/// Ensure a protocol-compatible session daemon is reachable at `pref_path`.
///
/// On version mismatch, requests a prepare-for-upgrade drain instead of
/// hard-killing while live PTYs or unconsumed/running turns exist. Replacement
/// waits are bounded; callers get a clear error rather than a silent kill.
pub fn ensureDaemon(allocator: std.mem.Allocator, pref_path: []const u8, exe_path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var replacement_requested = false;

    if (requestWithPeerAlloc(allocator, pref_path, "status", .{}, 0, SESSIONIZER_MAX_MESSAGE_BYTES, null)) |result| {
        defer allocator.free(result.response);
        if (parseDaemonStatus(allocator, result.response)) |status| {
            if (status.protocol_version == PROTOCOL_VERSION) return;
            replacement_requested = true;
            try replaceIncompatibleDaemon(
                allocator,
                pref_path,
                io,
                status,
                result.authenticated_server_process_id,
            );
        }
    } else |_| {}

    // The old daemon releases its endpoint lock just before the replacement
    // tries to bind. Probe both lock and pathname briefly so that tiny release
    // windows do not turn a graceful handoff into a 5-second unavailable retry.
    if (replacement_requested) try waitForReplacementBindSlot(allocator, pref_path, io);
    try spawnDaemon(allocator, exe_path);
    var attempts: usize = 0;
    var last_probe_error: anyerror = error.NoDaemonStatus;
    while (attempts < 250) : (attempts += 1) {
        if (requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            defer allocator.free(response);
            if (parseDaemonStatus(allocator, response)) |status| {
                if (status.protocol_version == PROTOCOL_VERSION) return;
                last_probe_error = error.IncompatibleDaemonProtocol;
            } else {
                last_probe_error = error.InvalidDaemonStatus;
            }
        } else |err| {
            last_probe_error = err;
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    log.warn(
        "session daemon unavailable after {d} status attempts last_probe_error={s}",
        .{ attempts, @errorName(last_probe_error) },
    );
    return error.SessionDaemonUnavailable;
}

/// Graceful protocol-version replacement (headless_verde.md Lifetime).
/// v19+ drains via prepareShutdown; pre-v19 falls back to terminate+respawn.
fn replaceIncompatibleDaemon(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    io: std.Io,
    status: DaemonStatus,
    authenticated_server_process_id: ?u32,
) !void {
    const deadline_ms = nowMs() + REPLACEMENT_WAIT_MS;
    var saw_method = false;
    var last_running_sessions: usize = status.running_session_count orelse status.session_count orelse 0;
    var last_keep_alive_turns: usize = status.keep_alive_turn_count orelse status.chat_turn_count orelse 0;

    while (nowMs() <= deadline_ms) {
        if (requestAlloc(allocator, pref_path, "daemon.prepareShutdown", .{}, 0)) |response| {
            defer allocator.free(response);
            if (parsePrepareShutdownResult(allocator, response)) |prepared| {
                if (prepared.method_missing) {
                    // Pre-v19: method_not_found. Do not spawn until the old
                    // listener is gone; status counts every legacy shell.
                    try terminateLegacyDaemon(allocator, pref_path, status, authenticated_server_process_id, io);
                    return;
                }
                saw_method = true;
                last_running_sessions = prepared.running_sessions;
                last_keep_alive_turns = prepared.keep_alive_turns;
                if (prepared.accepted and prepared.safe_to_exit) {
                    // Own grace window so a late prepare accept still has time to exit.
                    const gone_deadline_ms = nowMs() + REPLACEMENT_GONE_GRACE_MS;
                    if (waitForDaemonGone(allocator, pref_path, io, gone_deadline_ms)) return;
                    log.warn(
                        "session daemon prepareShutdown accepted but process remained protocol={d} pid={?}",
                        .{ status.protocol_version, status.pid },
                    );
                    return error.DaemonReplacementTimeout;
                }
            }
        } else |err| {
            // Only connect-class failures mean the endpoint is gone. Parse
            // failures / internal_error must not trigger a doomed respawn.
            if (isEndpointGoneError(err)) return;
            // Transient or protocol errors: retry until deadline.
        }
        std.Io.sleep(io, .fromMilliseconds(REPLACEMENT_POLL_MS), .awake) catch {};
    }

    if (!saw_method) {
        // No prepareShutdown surface observed — treat as legacy terminate+respawn.
        try terminateLegacyDaemon(allocator, pref_path, status, authenticated_server_process_id, io);
        return;
    }
    log.warn(
        "session daemon replacement blocked live_sessions={d} keep_alive_turns={d} protocol={d}",
        .{ last_running_sessions, last_keep_alive_turns, status.protocol_version },
    );
    return error.DaemonReplacementBlocked;
}

/// Historical pre-v19 replacement: terminate and authenticate that the old
/// endpoint disappeared before ensureDaemon attempts a new bind.
fn terminateLegacyDaemon(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    status: DaemonStatus,
    authenticated_server_process_id: ?u32,
    io: std.Io,
) !void {
    if (daemonProcessIdForReplacement(builtin.os.tag, status.pid, authenticated_server_process_id)) |pid| {
        terminateDaemonProcess(pid);
    }
    if (waitForDaemonGone(allocator, pref_path, io, nowMs() + LEGACY_TERMINATION_GRACE_MS)) return;

    if (builtin.os.tag != .windows) {
        if (daemonProcessIdForReplacement(builtin.os.tag, status.pid, authenticated_server_process_id)) |pid| {
            if (legacyPidStillOwnsEndpoint(allocator, pref_path, pid)) {
                forceTerminateDaemonProcess(pid);
                if (waitForDaemonGone(allocator, pref_path, io, nowMs() + REPLACEMENT_GONE_GRACE_MS)) return;
            } else {
                log.warn("skipping legacy daemon SIGKILL pid={d}: endpoint pid verification failed", .{pid});
            }
        }
    }
    return error.LegacyDaemonTerminationTimeout;
}

fn waitForReplacementBindSlot(allocator: std.mem.Allocator, pref_path: []const u8, io: std.Io) !void {
    if (builtin.os.tag == .windows) return;
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    const deadline_ms = nowMs() + REPLACEMENT_BIND_WAIT_MS;
    while (nowMs() <= deadline_ms) {
        var guard = platform_ipc.UnixEndpointGuard.acquire(allocator, io, endpoint) catch |err| switch (err) {
            error.EndpointInUse => {
                std.Io.sleep(io, .fromMilliseconds(REPLACEMENT_POLL_MS), .awake) catch {};
                continue;
            },
            else => return err,
        };
        const reclaim_result = guard.reclaimStaleEndpoint();
        guard.deinit();
        reclaim_result catch |err| switch (err) {
            error.EndpointInUse => {
                std.Io.sleep(io, .fromMilliseconds(REPLACEMENT_POLL_MS), .awake) catch {};
                continue;
            },
        };
        return;
    }
    return error.SessionDaemonUnavailable;
}

fn legacyPidStillOwnsEndpoint(allocator: std.mem.Allocator, pref_path: []const u8, expected_pid: usize) bool {
    const response = requestAlloc(allocator, pref_path, "status", .{}, 0) catch return false;
    defer allocator.free(response);
    const status = parseDaemonStatus(allocator, response) orelse return false;
    return status.pid == expected_pid;
}

/// Connect-class errors only. A live daemon that returns parse/internal errors
/// must not be classified as gone (would doom spawn with EndpointInUse).
fn isEndpointGoneError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.FileNotFound => true,
        else => false,
    };
}

/// Returns true when the endpoint is connect-gone. Non-connect errors keep the
/// poll alive until the grace deadline because the daemon may still be exiting.
fn waitForDaemonGone(allocator: std.mem.Allocator, pref_path: []const u8, io: std.Io, deadline_ms: i64) bool {
    while (nowMs() <= deadline_ms) {
        if (requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
        } else |err| {
            if (isEndpointGoneError(err)) return true;
            // Still reachable but unhappy — keep waiting within the grace window.
        }
        std.Io.sleep(io, .fromMilliseconds(REPLACEMENT_POLL_MS), .awake) catch {};
    }
    return false;
}

/// Windows replacement must use the PID bound to the authenticated pipe
/// handle. A JSON PID is only trusted on Unix, where the socket path supplies
/// the peer boundary and there is no portable peer-PID result here.
fn daemonProcessIdForReplacement(
    comptime os_tag: std.Target.Os.Tag,
    reported_process_id: ?usize,
    authenticated_server_process_id: ?u32,
) ?usize {
    if (os_tag == .windows) {
        return if (authenticated_server_process_id) |process_id| @as(usize, process_id) else null;
    }
    return reported_process_id;
}

/// Path to the currently running executable, used so provider hooks invoke
/// this exact installed CLI rather than relying on a GUI-launch PATH.
fn selfExePathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    return platform_runtime.executablePathAlloc(allocator);
}

/// Resolves the console CLI that terminal children should use for provider
/// hooks. Windows packages keep the GUI and console subsystem executables in
/// separate directories because their names collide on case-insensitive disks.
fn sessionCliPathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    const executable = selfExePathAlloc(allocator) catch return allocator.dupeZ(u8, "verde");
    defer allocator.free(executable);
    if (builtin.os.tag != .windows) return allocator.dupeZ(u8, executable);

    const resolved = resolveWindowsCliPathAlloc(allocator, executable) catch
        return allocator.dupeZ(u8, executable);
    defer allocator.free(resolved);
    return allocator.dupeZ(u8, resolved);
}

const WindowsCliPathResolver = struct {
    env_map: *const std.process.Environ.Map,

    fn resolve(self: *const WindowsCliPathResolver, allocator: std.mem.Allocator, candidate: []const u8) !?[]u8 {
        return process_env.resolveExecutableInEnvMapAlloc(allocator, self.env_map, candidate) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
};

fn resolveWindowsCliPathAlloc(allocator: std.mem.Allocator, executable: []const u8) ![]u8 {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    var resolver: WindowsCliPathResolver = .{ .env_map = &env_map };
    return resolveWindowsCliPathWith(allocator, executable, &resolver);
}

fn resolveWindowsDaemonPathAlloc(allocator: std.mem.Allocator, executable: []const u8) ![]u8 {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    var resolver: WindowsCliPathResolver = .{ .env_map = &env_map };
    return resolveWindowsDaemonPathWith(allocator, executable, &resolver);
}

fn resolveWindowsDaemonPathWith(allocator: std.mem.Allocator, executable: []const u8, resolver: anytype) ![]u8 {
    const executable_dir = std.fs.path.dirnameWindows(executable) orelse return allocator.dupe(u8, executable);
    const parent_name = std.fs.path.basenameWindows(executable_dir);

    // A raw Windows build installs its console executable in bin\cli. Keep
    // that exact binary instead of letting a different Verde on PATH win when
    // the general GUI-to-CLI resolver searches its fallback candidates.
    if (std.ascii.eqlIgnoreCase(parent_name, "cli")) {
        if (try resolver.resolve(allocator, executable)) |resolved| return resolved;
    }
    return resolveWindowsCliPathWith(allocator, executable, resolver);
}

fn resolveWindowsCliPathWith(allocator: std.mem.Allocator, executable: []const u8, resolver: anytype) ![]u8 {
    const executable_dir = std.fs.path.dirnameWindows(executable) orelse return allocator.dupe(u8, executable);
    const prefix_candidate = try std.fs.path.resolveWindows(allocator, &.{ executable_dir, "cli", "verde.exe" });
    defer allocator.free(prefix_candidate);
    const package_candidate = try std.fs.path.resolveWindows(allocator, &.{ executable_dir, "..", "bin", "verde.exe" });
    defer allocator.free(package_candidate);

    // Prefix installs use bin\cli\verde.exe; assembled ZIPs use
    // app\Verde.exe + bin\verde.exe. PATH is the final way to avoid handing a
    // GUI-subsystem executable to a terminal child.
    for ([_][]const u8{ prefix_candidate, package_candidate, "verde.exe" }) |candidate| {
        if (try resolver.resolve(allocator, candidate)) |resolved| return resolved;
    }
    return allocator.dupe(u8, executable);
}

pub fn spawnDaemon(allocator: std.mem.Allocator, exe_path: []const u8) !void {
    const daemon_exe = try daemonExecutablePath(allocator, exe_path);
    defer allocator.free(daemon_exe);
    if (builtin.os.tag == .windows) {
        log.info("spawning Windows session daemon executable={s}", .{daemon_exe});
        return spawnWindowsDaemon(allocator, daemon_exe);
    }

    const daemon_exe_z = try allocator.dupeZ(u8, daemon_exe);
    defer allocator.free(daemon_exe_z);

    const fork_result = std.c.fork();
    if (fork_result < 0) return error.ForkFailed;
    if (fork_result == 0) {
        _ = std.c.setsid();
        var child_argv: [3:null]?[*:0]const u8 = .{ daemon_exe_z.ptr, "__session-daemon", null };
        _ = std.c.execve(daemon_exe_z.ptr, &child_argv, std.c.environ);
        std.c._exit(127);
    }
}

fn spawnWindowsDaemon(allocator: std.mem.Allocator, daemon_exe: []const u8) !void {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const windows = std.os.windows;

    // Zig 0.16's process spawn always enables Windows handle inheritance. A
    // detached daemon would then retain redirected CI/parent pipes after this
    // process exits, so use CreateProcessW with inheritance explicitly off.
    const command_line = try windows_conpty.windowsCreateCommandLine(allocator, &.{ daemon_exe, "__session-daemon" });
    defer allocator.free(command_line);
    const command_line_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, command_line);
    defer allocator.free(command_line_w);
    const application_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, daemon_exe);
    defer allocator.free(application_w);

    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    const environment = try env_map.createWindowsBlock(allocator, .{});
    defer environment.deinit(allocator);

    var startup_info: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    var process_info: windows.PROCESS.INFORMATION = undefined;
    const creation_flags: windows.CreateProcessFlags = .{
        .create_unicode_environment = true,
        .create_no_window = true,
    };
    if (!windows.kernel32.CreateProcessW(
        application_w.ptr,
        command_line_w.ptr,
        null,
        null,
        .FALSE,
        creation_flags,
        environment.slice.ptr,
        null,
        &startup_info,
        &process_info,
    ).toBool()) return windows.unexpectedError(windows.GetLastError());

    // The daemon owns its lifetime; the launcher only releases its references.
    windows.CloseHandle(process_info.hThread);
    windows.CloseHandle(process_info.hProcess);
}

pub fn daemonExecutablePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, exe_path, "/\\") != null or (exe_path.len >= 2 and exe_path[1] == ':')) {
        if (builtin.os.tag == .windows) return resolveWindowsDaemonPathAlloc(allocator, exe_path);
        return allocator.dupe(u8, exe_path);
    }
    if (builtin.os.tag == .windows) {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        defer env_map.deinit();
        return process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, exe_path);
    }
    const path_ptr = std.c.getenv("PATH") orelse return allocator.dupe(u8, exe_path);
    const path_value = std.mem.span(path_ptr);
    var iterator = std.mem.splitScalar(u8, path_value, ':');
    while (iterator.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, exe_path });
        defer allocator.free(candidate);
        const candidate_z = try allocator.dupeZ(u8, candidate);
        if (std.c.access(candidate_z.ptr, std.c.X_OK) == 0) {
            allocator.free(candidate_z);
            return allocator.dupe(u8, candidate);
        }
        allocator.free(candidate_z);
    }
    return allocator.dupe(u8, exe_path);
}

fn terminateDaemonProcess(pid: usize) void {
    if (builtin.os.tag == .windows) {
        _ = windows_conpty.terminateProcessById(@intCast(pid));
        return;
    }
    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
}

fn forceTerminateDaemonProcess(pid: usize) void {
    if (builtin.os.tag == .windows) {
        _ = windows_conpty.terminateProcessById(@intCast(pid));
        return;
    }
    std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
}

pub const CreateOptions = struct {
    session_id: []const u8,
    project_id: []const u8 = "",
    project_path: []const u8 = "",
    cwd: []const u8 = "",
    label: []const u8 = "",
    command: []const []const u8 = &.{},
    cols: u16 = DEFAULT_COLS,
    rows: u16 = DEFAULT_ROWS,
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    pref_path: []const u8 = "",
};

const ChildIdentity = struct {
    session_id: [:0]u8,
    project_id: [:0]u8,
    project_path: [:0]u8,
    dock_id: [:0]u8,
    pane_id: [:0]u8,
    live_endpoint: [:0]u8,
    sessionizer_endpoint: [:0]u8,
    cli_path: [:0]u8,

    fn init(allocator: std.mem.Allocator, options: CreateOptions) !ChildIdentity {
        const session_id = try allocator.dupeZ(u8, options.session_id);
        errdefer allocator.free(session_id);
        const project_id = try allocator.dupeZ(u8, options.project_id);
        errdefer allocator.free(project_id);
        const project_path = try allocator.dupeZ(u8, options.project_path);
        errdefer allocator.free(project_path);
        const dock_id = try std.fmt.allocPrintSentinel(allocator, "{d}", .{options.dock_id}, 0);
        errdefer allocator.free(dock_id);
        const pane_id = try std.fmt.allocPrintSentinel(allocator, "{d}", .{options.pane_id}, 0);
        errdefer allocator.free(pane_id);

        const live_endpoint_text = try platform_live_endpoint.alloc(allocator, options.pref_path);
        defer allocator.free(live_endpoint_text);
        const live_endpoint = try allocator.dupeZ(u8, live_endpoint_text);
        errdefer allocator.free(live_endpoint);
        const sessionizer_endpoint_text = try socketPath(allocator, options.pref_path);
        defer allocator.free(sessionizer_endpoint_text);
        const sessionizer_endpoint = try allocator.dupeZ(u8, sessionizer_endpoint_text);
        errdefer allocator.free(sessionizer_endpoint);

        const cli_path = try sessionCliPathAlloc(allocator);
        errdefer allocator.free(cli_path);

        return .{
            .session_id = session_id,
            .project_id = project_id,
            .project_path = project_path,
            .dock_id = dock_id,
            .pane_id = pane_id,
            .live_endpoint = live_endpoint,
            .sessionizer_endpoint = sessionizer_endpoint,
            .cli_path = cli_path,
        };
    }

    fn deinit(self: ChildIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.project_id);
        allocator.free(self.project_path);
        allocator.free(self.dock_id);
        allocator.free(self.pane_id);
        allocator.free(self.live_endpoint);
        allocator.free(self.sessionizer_endpoint);
        allocator.free(self.cli_path);
    }
};

const PosixPtyBackend = if (builtin.os.tag == .windows) struct {} else struct {
    const Self = @This();

    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,
    running: bool = true,
    exit_status: ?u32 = null,

    extern fn forkpty(
        amaster: *c_int,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const std.posix.winsize,
    ) c_int;

    fn create(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        command: []const [:0]u8,
        identity: ChildIdentity,
        cols: u16,
        rows: u16,
    ) !Self {
        const cwd_z = try allocator.dupeZ(u8, cwd);
        defer allocator.free(cwd_z);

        var master_fd: c_int = -1;
        const winsize: std.posix.winsize = .{
            .row = @max(rows, 1),
            .col = @max(cols, 1),
            .xpixel = 0,
            .ypixel = 0,
        };
        const fork_result = forkpty(&master_fd, null, null, &winsize);
        if (fork_result < 0) return error.ForkPtyFailed;
        if (fork_result == 0) childExec(cwd_z, command, identity);

        const owned_master: std.posix.fd_t = @intCast(master_fd);
        errdefer {
            std.posix.kill(@intCast(fork_result), std.posix.SIG.TERM) catch {};
            _ = std.c.close(owned_master);
        }
        try setNonBlocking(owned_master);
        return .{
            .master_fd = owned_master,
            .child_pid = @intCast(fork_result),
        };
    }

    fn deinit(self: *Self, _: std.mem.Allocator) void {
        if (self.running) _ = self.signalTermination();
        _ = std.c.close(self.master_fd);
        _ = self.captureExitStatus();
    }

    fn read(self: *Self, buffer: []u8) windows_conpty.ReadResult {
        while (true) {
            const read_raw = std.c.read(self.master_fd, buffer.ptr, buffer.len);
            if (read_raw > 0) return .{ .bytes = @intCast(read_raw) };
            if (read_raw == 0) return .{ .eof = true };
            const errno = std.c._errno().*;
            if (errno == @intFromEnum(std.c.E.INTR)) continue;
            if (errno == @intFromEnum(std.c.E.AGAIN)) return .{};
            return .{ .eof = true };
        }
    }

    fn write(self: *Self, bytes: []const u8) !bool {
        if (!self.running or bytes.len == 0) return false;
        try writeAll(self.master_fd, bytes);
        return true;
    }

    fn resize(self: *Self, cols: u16, rows: u16) !void {
        if (!self.running) return;
        var winsize: std.posix.winsize = .{
            .row = @max(rows, 1),
            .col = @max(cols, 1),
            .xpixel = 0,
            .ypixel = 0,
        };
        if (std.c.ioctl(self.master_fd, TERMINAL_WINSIZE_IOCTL, &winsize) != 0) return error.ResizeFailed;

        const foreground_process_group = self.foregroundProcessGroup();
        if (foreground_process_group) |pgrp| _ = std.c.kill(-@as(std.posix.pid_t, @intCast(pgrp)), std.c.SIG.WINCH);
        _ = signalDescendantProcessGroups(std.heap.smp_allocator, self.child_pid, if (foreground_process_group) |pgrp| @intCast(pgrp) else null, std.c.SIG.WINCH);
    }

    fn terminate(self: *Self) bool {
        if (!self.running) return false;
        if (!self.signalTermination()) return false;
        _ = self.captureExitStatus();
        return true;
    }

    fn signalTermination(self: *Self) bool {
        const foreground_process_group: ?std.posix.pid_t = if (self.foregroundProcessGroup()) |pgrp| @intCast(pgrp) else null;
        var signaled = signalDescendantProcessGroups(
            std.heap.smp_allocator,
            self.child_pid,
            foreground_process_group,
            std.c.SIG.TERM,
        ) > 0;

        // forkpty makes the child a process-group leader. Signal both that
        // group and a distinct foreground group so script runners cannot
        // leave their actual application alive after the launcher exits.
        if (foreground_process_group) |pgrp| {
            if (pgrp != self.child_pid and std.c.kill(-pgrp, std.c.SIG.TERM) == 0) signaled = true;
        }
        if (std.c.kill(-self.child_pid, std.c.SIG.TERM) == 0) signaled = true;
        if (!signaled and std.c.kill(self.child_pid, std.c.SIG.TERM) == 0) signaled = true;
        return signaled;
    }

    fn foregroundProcessGroup(self: *const Self) ?usize {
        if (!self.running) return null;
        const ioctl_value = TERMINAL_GET_PGRP_IOCTL orelse return null;
        var pgrp: c_int = 0;
        if (std.c.ioctl(self.master_fd, ioctl_value, &pgrp) != 0 or pgrp <= 0) return null;
        return @intCast(pgrp);
    }

    fn processId(self: *const Self) usize {
        return @intCast(self.child_pid);
    }

    fn isRunning(self: *Self) bool {
        _ = self.captureExitStatus();
        return self.running;
    }

    fn exitStatus(self: *Self) ?u32 {
        _ = self.captureExitStatus();
        return self.exit_status;
    }

    fn ioHealth(_: *const Self) windows_conpty.IoHealth {
        return .{};
    }

    fn captureExitStatus(self: *Self) bool {
        if (self.exit_status != null) return false;
        var status: c_int = 0;
        const wait_result = std.c.waitpid(self.child_pid, &status, std.c.W.NOHANG);
        if (wait_result == 0) return false;
        self.running = false;
        self.exit_status = @bitCast(status);
        return true;
    }

    fn childExec(cwd: [:0]const u8, command: []const [:0]u8, identity: ChildIdentity) noreturn {
        if (std.c.chdir(cwd.ptr) != 0) std.c._exit(127);
        process_env.applyAugmentedPathToCurrentProcess(std.heap.page_allocator) catch {};
        const term = childTermEnvValue();
        _ = setenv("TERM", term.ptr, 1);
        _ = setenv("COLORTERM", "truecolor", 1);
        _ = setenv("TERM_PROGRAM", "verde", 1);
        _ = setenv("TERM_PROGRAM_VERSION", "1.1.0", 1);
        _ = setenv("CLICOLOR", "1", 1);
        _ = setenv("CLICOLOR_FORCE", "1", 1);
        _ = setenv("FORCE_COLOR", "3", 1);
        _ = setenv("VERDE", "1", 1);
        _ = setenv("VERDE_SESSION_ID", identity.session_id.ptr, 1);
        _ = setenv("VERDE_WORKSPACE_ID", identity.project_id.ptr, 1);
        _ = setenv("VERDE_WORKSPACE_PATH", identity.project_path.ptr, 1);
        _ = setenv("VERDE_DOCK_ID", identity.dock_id.ptr, 1);
        _ = setenv("VERDE_PANE_ID", identity.pane_id.ptr, 1);
        _ = setenv("VERDE_SOCKET", identity.live_endpoint.ptr, 1);
        _ = setenv("VERDE_LIVE_ENDPOINT", identity.live_endpoint.ptr, 1);
        _ = setenv("VERDE_LIVE_SOCKET", identity.live_endpoint.ptr, 1);
        _ = setenv("VERDE_SESSIONIZER_SOCKET", identity.sessionizer_endpoint.ptr, 1);
        _ = setenv("VERDE_CLI", identity.cli_path.ptr, 1);
        if (std.c.getenv("LANG") == null) {
            const lang = childLocaleEnvValue();
            _ = setenv("LANG", lang.ptr, 1);
        }

        var argv: [64:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 64;
        const count = @min(command.len, argv.len - 1);
        for (command[0..count], 0..) |arg, index| argv[index] = arg.ptr;
        if (count > 0) _ = std.c.execve(command[0].ptr, &argv, std.c.environ);
        std.c._exit(127);
    }
};

const PtyBackend = if (builtin.os.tag == .windows) windows_conpty.Backend else PosixPtyBackend;

const PtySession = struct {
    const AttachClient = struct {
        attach_id: []u8,
        label: []u8,
        created_at_ms: i64,
        last_seen_at_ms: i64,
    };

    session_id: []u8,
    project_id: []u8,
    project_path: []u8,
    cwd: []u8,
    label: []u8,
    command_label: []u8,
    dock_id: u32,
    pane_id: u32,
    backend: PtyBackend,
    child_pid: usize,
    cols: u16,
    rows: u16,
    output_ring: std.ArrayList(u8) = .empty,
    /// Cumulative count of bytes ever appended to output_ring. Forms the public
    /// "offset" the desktop client sends in `session.tail` requests. The ring
    /// itself is capped at MAX_OUTPUT_RING and drops oldest bytes on overflow,
    /// so a raw array index isn't a stable cursor — once 1 MB has streamed
    /// through, the array length saturates and every later request collapses
    /// to an empty slice (the bug that froze TUI panes mid-output).
    output_total: u64 = 0,
    running: bool = true,
    stream_eof: bool = false,
    exit_status: ?u32 = null,
    /// Daemon-owned workspace identity used by the unread registry dual-write.
    registry_workspace_id: ?[]u8 = null,
    /// Prevent duplicate terminal outcomes when kill, polling, and cleanup overlap.
    registry_finished: bool = false,
    created_at_ms: i64,
    last_attached_at_ms: ?i64 = null,
    attach_clients: std.ArrayList(AttachClient) = .empty,

    pub fn create(allocator: std.mem.Allocator, options: CreateOptions) !*PtySession {
        const self = try allocator.create(PtySession);
        errdefer allocator.destroy(self);

        const cwd = if (std.mem.trim(u8, options.cwd, &std.ascii.whitespace).len > 0)
            options.cwd
        else
            ".";
        const command = try commandForOptions(allocator, options.command);
        defer freeCommand(allocator, command);
        const command_label = try commandLabel(allocator, command);
        errdefer allocator.free(command_label);

        const identity = try ChildIdentity.init(allocator, options);
        defer identity.deinit(allocator);
        var backend = try PtyBackend.create(allocator, cwd, command, identity, options.cols, options.rows);
        errdefer backend.deinit(allocator);

        const session_id = try allocator.dupe(u8, options.session_id);
        errdefer allocator.free(session_id);
        const project_id = try allocator.dupe(u8, options.project_id);
        errdefer allocator.free(project_id);
        const project_path = try allocator.dupe(u8, options.project_path);
        errdefer allocator.free(project_path);
        const owned_cwd = try allocator.dupe(u8, cwd);
        errdefer allocator.free(owned_cwd);
        const label = try allocator.dupe(u8, if (options.label.len > 0) options.label else command_label);
        errdefer allocator.free(label);

        self.* = .{
            .session_id = session_id,
            .project_id = project_id,
            .project_path = project_path,
            .cwd = owned_cwd,
            .label = label,
            .command_label = command_label,
            .dock_id = options.dock_id,
            .pane_id = options.pane_id,
            .child_pid = backend.processId(),
            .backend = backend,
            .cols = options.cols,
            .rows = options.rows,
            .created_at_ms = nowMs(),
        };
        return self;
    }

    pub fn deinit(self: *PtySession, allocator: std.mem.Allocator) void {
        self.backend.deinit(allocator);
        allocator.free(self.session_id);
        allocator.free(self.project_id);
        allocator.free(self.project_path);
        allocator.free(self.cwd);
        allocator.free(self.label);
        allocator.free(self.command_label);
        if (self.registry_workspace_id) |workspace_id| allocator.free(workspace_id);
        for (self.attach_clients.items) |client| {
            allocator.free(client.attach_id);
            allocator.free(client.label);
        }
        self.attach_clients.deinit(allocator);
        self.output_ring.deinit(allocator);
        allocator.destroy(self);
    }

    fn poll(self: *PtySession, allocator: std.mem.Allocator) !void {
        try self.drainOutput(allocator, DAEMON_POLL_READ_BUDGET);
        _ = self.captureExitStatus();
    }

    fn writeInput(self: *PtySession, bytes: []const u8) !bool {
        if (!self.running or bytes.len == 0) return false;
        return self.backend.write(bytes);
    }

    fn resize(self: *PtySession, cols: u16, rows: u16) void {
        if (!self.running) return;
        const previous_cols = self.cols;
        const previous_rows = self.rows;
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        self.backend.resize(self.cols, self.rows) catch |err| {
            log.warn("resize failed id_len={d} pid={d} err={s}", .{ self.session_id.len, self.child_pid, @errorName(err) });
            return;
        };
        log.info(
            "resize id_len={d} pid={d} pgrp={?d} {d}x{d}->{d}x{d}",
            .{
                self.session_id.len,
                self.child_pid,
                self.foregroundProcessGroup(),
                previous_cols,
                previous_rows,
                self.cols,
                self.rows,
            },
        );
    }

    fn terminate(self: *PtySession) bool {
        // Windows may still own descendants in the ConPTY job after the direct
        // shell exits, so let the backend decide whether termination applies.
        if (!self.backend.terminate()) return false;
        _ = self.captureExitStatus();
        return true;
    }

    fn foregroundProcessGroup(self: *const PtySession) ?usize {
        if (!self.running) return null;
        return self.backend.foregroundProcessGroup();
    }

    fn attach(self: *PtySession, allocator: std.mem.Allocator, label: []const u8) ![]u8 {
        const now = nowMs();
        self.cleanupStaleAttaches(allocator, now);
        const attach_id = try std.fmt.allocPrint(allocator, "{s}:attach:{d}:{d}", .{ self.session_id, now, self.attach_clients.items.len });
        errdefer allocator.free(attach_id);
        try self.attach_clients.append(allocator, .{
            .attach_id = attach_id,
            .label = try allocator.dupe(u8, if (label.len > 0) label else "client"),
            .created_at_ms = now,
            .last_seen_at_ms = now,
        });
        self.last_attached_at_ms = now;
        return try allocator.dupe(u8, attach_id);
    }

    fn detach(self: *PtySession, allocator: std.mem.Allocator, attach_id: []const u8) bool {
        for (self.attach_clients.items, 0..) |client, index| {
            if (!std.mem.eql(u8, client.attach_id, attach_id)) continue;
            const removed = self.attach_clients.orderedRemove(index);
            allocator.free(removed.attach_id);
            allocator.free(removed.label);
            return true;
        }
        return false;
    }

    fn touchAttach(self: *PtySession, attach_id: []const u8) bool {
        const now = nowMs();
        for (self.attach_clients.items) |*client| {
            if (!std.mem.eql(u8, client.attach_id, attach_id)) continue;
            client.last_seen_at_ms = now;
            return true;
        }
        return false;
    }

    fn cleanupStaleAttaches(self: *PtySession, allocator: std.mem.Allocator, now: i64) void {
        var index: usize = 0;
        while (index < self.attach_clients.items.len) {
            const client = self.attach_clients.items[index];
            if (now - client.last_seen_at_ms <= ATTACH_STALE_MS) {
                index += 1;
                continue;
            }
            const removed = self.attach_clients.orderedRemove(index);
            allocator.free(removed.attach_id);
            allocator.free(removed.label);
        }
    }

    fn drainOutput(self: *PtySession, allocator: std.mem.Allocator, max_bytes: usize) !void {
        var buffer: [8192]u8 = undefined;
        var read_total: usize = 0;
        while (read_total < max_bytes) {
            const capacity = @min(buffer.len, max_bytes - read_total);
            const result = self.backend.read(buffer[0..capacity]);
            self.output_total +%= result.dropped;
            if (result.bytes > 0) {
                try self.appendOutput(allocator, buffer[0..result.bytes]);
                read_total += result.bytes;
            }
            if (result.eof) self.stream_eof = true;
            if (result.bytes == 0) return;
        }
    }

    /// Number of bytes dropped from the head of `output_ring` over its lifetime
    /// (i.e. `output_total - output_ring.items.len`). Subtracting this from a
    /// cumulative client offset yields the corresponding index into the ring.
    fn ringStart(self: *const PtySession) u64 {
        return self.output_total - @as(u64, @intCast(self.output_ring.items.len));
    }

    /// Translate a cumulative client offset into a valid index inside
    /// `output_ring.items`. Clamps below-window offsets to 0 (caller will
    /// receive the oldest still-buffered bytes instead of an empty slice) and
    /// past-the-end offsets to the ring length.
    fn ringIndexForOffset(self: *const PtySession, offset: u64) usize {
        const start = self.ringStart();
        if (offset <= start) return 0;
        const idx = offset - start;
        return @intCast(@min(idx, @as(u64, @intCast(self.output_ring.items.len))));
    }

    fn appendOutput(self: *PtySession, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len >= MAX_OUTPUT_RING) {
            self.output_ring.clearRetainingCapacity();
            try self.output_ring.appendSlice(allocator, bytes[bytes.len - MAX_OUTPUT_RING ..]);
            self.output_total +%= bytes.len;
            return;
        }
        const overflow = self.output_ring.items.len + bytes.len -| MAX_OUTPUT_RING;
        if (overflow > 0) {
            std.mem.copyForwards(u8, self.output_ring.items[0 .. self.output_ring.items.len - overflow], self.output_ring.items[overflow..]);
            self.output_ring.shrinkRetainingCapacity(self.output_ring.items.len - overflow);
        }
        try self.output_ring.appendSlice(allocator, bytes);
        self.output_total +%= bytes.len;
    }

    fn captureExitStatus(self: *PtySession) bool {
        const was_running = self.running;
        // A ConPTY pipe can fail independently of its hosted process. Keep the
        // process handle/waitpid as the sole liveness authority and report pipe
        // health separately so a degraded stream cannot create duplicate PTYs.
        if (builtin.os.tag == .windows) {
            self.exit_status = self.backend.exitStatus();
            self.running = self.exit_status == null;
        } else {
            self.running = self.backend.isRunning();
            self.exit_status = self.backend.exitStatus();
        }
        return was_running and !self.running;
    }
};

const ChatTurnStatus = enum { running, waiting_approval, completed, failed, aborted };
const ApprovalDecision = enum { approve, deny };

const PendingApproval = struct {
    call_id: []u8,
    title: []u8,
    body: []u8,

    fn deinit(self: *PendingApproval, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

const ChatEvent = struct {
    seq: u64,
    kind: []u8,
    payload_json: []u8,

    fn deinit(self: *ChatEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.payload_json);
    }
};

const ChatTurn = struct {
    allocator: std.mem.Allocator,
    turn_id: []u8,
    workspace_id: []u8,
    local_thread_id: []u8,
    request: send_runner.Request,
    owned_image_paths: []const []const u8,
    mutex: std.atomic.Mutex = .unlocked,
    worker_thread: ?std.Thread = null,
    events: std.ArrayList(ChatEvent) = .empty,
    next_seq: u64 = 1,
    status: ChatTurnStatus = .running,
    consumed: bool = false,
    worker_done: bool = false,
    cancel_requested: bool = false,
    provider_thread_id: ?[]u8 = null,
    active_turn_id: ?[]u8 = null,
    result_reply_text: ?[]u8 = null,
    error_message: ?[]u8 = null,
    pending_approval: ?PendingApproval = null,
    approval_call_id: ?[]u8 = null,
    approval_decision: ?ApprovalDecision = null,

    fn deinit(self: *ChatTurn, allocator: std.mem.Allocator) void {
        if (self.worker_thread) |worker_thread| {
            // Error paths can deinitialize the daemon while a provider worker
            // still has callbacks into this turn. Cancel and join before any
            // storage it may dereference is released.
            lockTurn(self);
            self.cancel_requested = true;
            self.mutex.unlock();
            worker_thread.join();
        }
        allocator.free(self.turn_id);
        allocator.free(self.workspace_id);
        allocator.free(self.local_thread_id);
        freeRunnerRequest(allocator, self.request, self.owned_image_paths);
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.active_turn_id) |value| allocator.free(value);
        if (self.result_reply_text) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        if (self.pending_approval) |*approval| approval.deinit(allocator);
        if (self.approval_call_id) |value| allocator.free(value);
        allocator.destroy(self);
    }

    fn appendEvent(self: *ChatTurn, allocator: std.mem.Allocator, kind: []const u8, payload_json: []const u8) void {
        const owned_kind = allocator.dupe(u8, kind) catch return;
        errdefer allocator.free(owned_kind);
        const owned_payload = allocator.dupe(u8, payload_json) catch return;
        errdefer allocator.free(owned_payload);
        var event: ChatEvent = .{
            .seq = self.next_seq,
            .kind = owned_kind,
            .payload_json = owned_payload,
        };
        errdefer event.deinit(allocator);
        self.events.append(allocator, event) catch return;
        self.next_seq += 1;
    }

    fn appendStringEvent(self: *ChatTurn, allocator: std.mem.Allocator, kind: []const u8, field: []const u8, value: []const u8) void {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        s.beginObject() catch return;
        s.objectField(field) catch return;
        s.write(value) catch return;
        s.endObject() catch return;
        const payload = writer.toOwnedSlice() catch return;
        defer allocator.free(payload);
        self.appendEvent(allocator, kind, payload);
    }
};

fn freeRunnerRequest(allocator: std.mem.Allocator, request: send_runner.Request, image_paths: []const []const u8) void {
    allocator.free(request.project_path);
    allocator.free(request.prompt);
    for (image_paths) |path| allocator.free(path);
    allocator.free(image_paths);
    if (request.provider_thread_id) |value| allocator.free(value);
    allocator.free(request.thread_title);
    if (request.model_ref) |value| allocator.free(value);
    if (request.opencode_reasoning_variant) |value| allocator.free(value);
    if (request.cursor_model_params_json) |value| allocator.free(value);
    if (request.remote_ssh_host) |value| allocator.free(value);
    if (request.remote_cwd) |value| allocator.free(value);
}

/// Generate the daemon namespace once at startup. Registry IDs and revisions
/// are only comparable within this random instance namespace.
fn randomInstanceNonce(allocator: std.mem.Allocator) []u8 {
    var random_bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return allocator.dupe(u8, &hex) catch @panic("failed to allocate daemon instance nonce");
}

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    registry: process_registry.ProcessRegistry,
    sessions: std.ArrayList(*PtySession) = .empty,
    chat_turns: std.ArrayList(*ChatTurn) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    idle_since_ms: ?i64 = null,
    /// null = persistent (no idle exit). Tests set VERDE_SESSION_DAEMON_IDLE_EXIT_MS.
    idle_exit_ms: ?i64 = null,
    /// False after a successful prepareShutdown while the daemon drains out.
    accepting_mutations: bool = true,
    /// Set only when prepareShutdown accepted a safe upgrade handoff.
    shutdown_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) Daemon {
        const instance_nonce = randomInstanceNonce(allocator);
        defer allocator.free(instance_nonce);
        return .{
            .allocator = allocator,
            .registry = process_registry.ProcessRegistry.init(allocator, instance_nonce) catch @panic("failed to initialize daemon process registry"),
            .idle_exit_ms = idleExitMsFromEnv(allocator),
        };
    }

    pub fn deinit(self: *Daemon) void {
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.chat_turns.items) |turn| turn.deinit(self.allocator);
        self.chat_turns.deinit(self.allocator);
        self.registry.deinit(self.allocator);
    }

    fn pollSessions(self: *Daemon) void {
        const now = nowMs();
        for (self.sessions.items) |session| {
            session.poll(self.allocator) catch {};
            if (!session.running) self.noteSessionExitInRegistry(session, null, now);
            session.cleanupStaleAttaches(self.allocator, now);
        }
    }

    /// Live PTY sessions or unconsumed/running turns that must not be dropped.
    fn hasLiveKeepAliveState(self: *Daemon) bool {
        self.removeFinishedConsumedChatTurns();
        for (self.sessions.items) |session| {
            if (session.running) return true;
        }
        for (self.chat_turns.items) |turn| {
            lockTurn(turn);
            const keep_alive = chatTurnKeepsDaemonAlive(turn.status, turn.consumed, turn.worker_done);
            turn.mutex.unlock();
            if (keep_alive) return true;
        }
        return false;
    }

    fn countRunningSessions(self: *const Daemon) usize {
        var count: usize = 0;
        for (self.sessions.items) |session| {
            if (session.running) count += 1;
        }
        return count;
    }

    fn countKeepAliveTurns(self: *Daemon) usize {
        var count: usize = 0;
        for (self.chat_turns.items) |turn| {
            lockTurn(turn);
            const keep_alive = chatTurnKeepsDaemonAlive(turn.status, turn.consumed, turn.worker_done);
            turn.mutex.unlock();
            if (keep_alive) count += 1;
        }
        return count;
    }

    /// Exit when prepareShutdown accepted a safe handoff, or when the optional
    /// idle-exit override elapses with no keep-alive state (tests only by default).
    fn shouldExitForIdle(self: *Daemon) bool {
        if (self.hasLiveKeepAliveState()) {
            self.idle_since_ms = null;
            return false;
        }
        if (self.shutdown_requested) return true;

        // Authoritative lifetime: stay up until explicit stop/upgrade/logout
        // unless tests set VERDE_SESSION_DAEMON_IDLE_EXIT_MS.
        const idle_exit_ms = self.idle_exit_ms orelse return false;
        const now = nowMs();
        if (self.idle_since_ms == null) {
            self.idle_since_ms = now;
            return false;
        }
        return now - self.idle_since_ms.? >= idle_exit_ms;
    }

    fn removeFinishedConsumedChatTurns(self: *Daemon) void {
        var index: usize = 0;
        while (index < self.chat_turns.items.len) {
            const turn = self.chat_turns.items[index];
            lockTurn(turn);
            const remove = turn.consumed and turn.worker_done;
            turn.mutex.unlock();
            if (remove) {
                self.chat_turns.orderedRemove(index).deinit(self.allocator);
                continue;
            }
            index += 1;
        }
    }

    fn find(self: *Daemon, session_id: []const u8) ?*PtySession {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.session_id, session_id)) return session;
        }
        return null;
    }

    /// Dual-write (unread): publish a newly created session into the registry.
    /// Registry failures are diagnostic only and never fail session.create.
    fn observeSessionInRegistry(self: *Daemon, session: *PtySession, command_line: []const u8, now_ms: i64) void {
        if (session.project_id.len == 0 and session.project_path.len == 0) return;

        var derived_workspace_id: ?[]u8 = null;
        defer if (derived_workspace_id) |workspace_id| self.allocator.free(workspace_id);
        const workspace_id = if (session.project_id.len > 0)
            session.project_id
        else blk: {
            derived_workspace_id = workspace_identity.deriveProjectId(self.allocator, session.project_path) catch |err| {
                log.warn("registry workspace derivation failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
                return;
            };
            break :blk derived_workspace_id.?;
        };

        // Register the path before observeTerminalProcess: observe returns a
        // borrowed pointer that any later registry mutation invalidates.
        if (session.project_path.len > 0) {
            _ = self.registry.registerWorkspacePath(
                self.allocator,
                workspace_id,
                session.project_path,
                now_ms,
            ) catch |err| {
                log.warn("registry workspace path failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
                return;
            };
        }

        session.registry_workspace_id = self.allocator.dupe(u8, workspace_id) catch |err| {
            log.warn("registry workspace dupe failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
            return;
        };
        const process_group: ?u32 = if (session.foregroundProcessGroup()) |group| @intCast(group) else null;
        const pid: u32 = @intCast(session.child_pid);
        const observation: process_registry.TerminalProcessObservation = .{
            .process_identity = process_registry.processIdentity(process_group, pid),
            .session_id = session.session_id,
            .command = command_line,
            .cwd = session.project_path,
            .pid = pid,
            .process_group = process_group,
            .started_at_ms = now_ms,
            .observed_at_ms = now_ms,
            // Daemon-socket sessions have no desktop dock or pane.
            .dock_id = 0,
            .pane_id = null,
            .owner_kind = "terminal",
            .owner_title = session.session_id,
            .provider = null,
        };
        _ = self.registry.observeTerminalProcess(self.allocator, workspace_id, observation, .{}) catch |err| {
            log.warn("registry session observation failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
            return;
        };
    }

    /// Record a session exit in the registry exactly once.
    fn noteSessionExitInRegistry(self: *Daemon, session: *PtySession, cancellation_reason: ?[]const u8, now_ms: i64) void {
        if (session.registry_finished or session.registry_workspace_id == null) return;

        const finish: process_registry.TerminalProcessFinish = if (cancellation_reason != null)
            .{ .cancellation_reason = cancellation_reason }
        else if (session.exit_status) |raw_status|
            // exit_status is a raw wait status on fork backends, not a decoded
            // exit code. P2 only preserves zero/non-zero classification; signal
            // decoding differs by backend and remains deferred.
            .{ .exit_code = if (raw_status == 0) 0 else raw_status }
        else
            .{};
        const finished = self.registry.finishTerminalProcess(
            self.allocator,
            session.registry_workspace_id.?,
            session.session_id,
            finish,
            now_ms,
        ) catch |err| {
            log.warn("registry session finish failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
            return;
        };
        _ = finished;
        // finishTerminalProcess is idempotent-by-removal; mark the local guard
        // for both an actual finish and a harmless already-finished no-op.
        session.registry_finished = true;
    }

    fn removeAt(self: *Daemon, index: usize) void {
        const session = self.sessions.orderedRemove(index);
        session.deinit(self.allocator);
    }

    fn handleRequest(self: *Daemon, request_json: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, request_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return try errorResponseAlloc(self.allocator, .null, "invalid_request", "request must be an object");
        const id_value = parsed.value.object.get("id") orelse .null;
        const method = jsonString(parsed.value.object.get("method") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_request", "missing method");
        const params = parsed.value.object.get("params") orelse .null;

        const response = self.handleMethodRequest(id_value, method, params) catch |err| switch (err) {
            error.SessionNotFound => try errorResponseAlloc(self.allocator, id_value, "resource_not_found", "session not found"),
            error.ResponseTooLarge => try errorResponseAlloc(self.allocator, id_value, "response_too_large", "response exceeds transport limit"),
            else => return err,
        };
        if (response.len > MAX_RESPONSE_BYTES) {
            self.allocator.free(response);
            return try errorResponseAlloc(self.allocator, id_value, "response_too_large", "response exceeds transport limit");
        }
        return response;
    }

    fn handleMethodRequest(self: *Daemon, id_value: std.json.Value, method: []const u8, params: std.json.Value) ![]u8 {
        if (!self.accepting_mutations and methodMutatesState(method)) {
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                "invalid_state",
                "daemon is preparing shutdown and is not accepting mutations",
            );
        }
        if (std.mem.eql(u8, method, "session.list")) return try self.listResponse(id_value);
        if (std.mem.eql(u8, method, "session.inspect")) return try self.inspectResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.create")) return try self.createResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.attach")) return try self.attachResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.detach")) return try self.detachResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.write")) return try self.writeResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.resize")) return try self.resizeResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.tail")) return try self.tailResponse(id_value, params, false);
        if (std.mem.eql(u8, method, "session.tail.batch")) return try self.tailBatchResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.screen")) return try self.tailResponse(id_value, params, true);
        if (std.mem.eql(u8, method, "session.kill")) return try self.killResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.cleanup")) return try self.cleanupResponse(id_value);
        if (std.mem.eql(u8, method, "chat.turn.start")) return try self.chatTurnStartResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.list")) return try self.chatTurnListResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.tail")) return try self.chatTurnTailResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.approve")) return try self.chatTurnApproveResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.cancel")) return try self.chatTurnCancelResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.consume")) return try self.chatTurnConsumeResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_WORKSPACE_RESOLVE)) return try self.workspaceResolveResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_LIST)) return try self.processListResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_INSPECT)) return try self.processInspectResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_WAIT)) return try self.processWaitResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_LOGS)) return try self.processLogsResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_LEASE_CHECK)) return try self.leaseCheckResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_LEASE_ACQUIRE)) return try self.leaseAcquireResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_LEASE_RENEW)) return try self.leaseRenewResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_LEASE_RELEASE)) return try self.leaseReleaseResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_DAEMON_NOTIFICATIONS)) return try self.notificationsResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_DAEMON_CLIENT_REGISTER)) return try self.clientRegisterResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_DAEMON_CLIENT_HEARTBEAT)) return try self.clientHeartbeatResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.registry.METHOD_DAEMON_CLIENT_CLOSE)) return try self.clientCloseResponse(id_value, params);
        if (std.mem.eql(u8, method, "status")) return try self.statusResponse(id_value);
        if (std.mem.eql(u8, method, "daemon.prepareShutdown")) return try self.prepareShutdownResponse(id_value);
        // Additive headless core methods; existing methods and error codes unchanged.
        if (std.mem.startsWith(u8, method, "core.")) return try self.coreResponse(id_value, method, params);
        return try errorResponseAlloc(self.allocator, id_value, "method_not_found", method);
    }

    fn methodMutatesState(method: []const u8) bool {
        return headless.isMutatingMethod(method);
    }

    fn statusResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        const keep_alive_turns = self.countKeepAliveTurns();
        return try okValueResponse(self.allocator, id_value, .{
            .protocol_version = PROTOCOL_VERSION,
            .pid = platform_runtime.processId(),
            .session_count = self.sessions.items.len,
            .chat_turn_count = self.chat_turns.items.len,
            .running_session_count = self.countRunningSessions(),
            .keep_alive_turn_count = keep_alive_turns,
            .accepting_mutations = self.accepting_mutations,
            .shutdown_requested = self.shutdown_requested,
            // null when idle exit is disabled (authoritative default).
            .idle_exit_ms = self.idle_exit_ms,
        });
    }

    /// Prepare-for-upgrade shutdown (headless_verde.md Lifetime §Protocol-version
    /// replacement). Enters drain only when no live PTYs / keep-alive turns remain
    /// so a refused upgrade does not freeze a healthy daemon.
    fn prepareShutdownResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        self.removeFinishedConsumedChatTurns();
        const running_sessions = self.countRunningSessions();
        const keep_alive_turns = self.countKeepAliveTurns();
        const safe_to_exit = running_sessions == 0 and keep_alive_turns == 0;
        if (safe_to_exit) {
            self.accepting_mutations = false;
            self.shutdown_requested = true;
        }
        return try okValueResponse(self.allocator, id_value, .{
            .accepted = safe_to_exit,
            .safe_to_exit = safe_to_exit,
            .running_sessions = running_sessions,
            .keep_alive_turns = keep_alive_turns,
            .session_count = self.sessions.items.len,
            .chat_turn_count = self.chat_turns.items.len,
            .shutdown_requested = self.shutdown_requested,
            .accepting_mutations = self.accepting_mutations,
        });
    }

    fn coreResponse(self: *Daemon, id_value: std.json.Value, method: []const u8, params: std.json.Value) ![]u8 {
        const ctx: headless.Context = .{
            .pid = platform_runtime.processId(),
            .sessionizer_protocol_version = PROTOCOL_VERSION,
            .session_count = self.sessions.items.len,
            .chat_turn_count = self.chat_turns.items.len,
        };
        // Request id for the typed dispatcher is informational; wire id stays id_value.
        const typed = headless.dispatchMethod(0, method, params, ctx);
        return switch (typed.body) {
            .status => |result| try okValueResponse(self.allocator, id_value, result),
            .capabilities => |result| try okValueResponse(self.allocator, id_value, result),
            .err => |err| try errorResponseAllocWithData(self.allocator, id_value, err.code, err.message, err.data),
        };
    }

    fn workspaceResolveResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn processListResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        // Pruning only mutates this workspace's outcome list, so the borrowed
        // workspace record remains valid while the snapshot is serialized.
        _ = self.registry.pruneTerminalProcessOutcomes(self.allocator, workspace.id, nowMs());
        const include_notifications = if (params == .object) jsonBool(params.object.get("include_notifications") orelse .null) orelse false else false;
        const include_outcomes = if (params == .object) jsonBool(params.object.get("include_outcomes") orelse .null) orelse false else false;
        var notifications: std.ArrayList(*const process_registry.Notification) = .empty;
        defer notifications.deinit(self.allocator);
        const next_notification_seq = if (include_notifications)
            self.registry.collectNotifications(self.allocator, workspace.id, null, 0, 0, &notifications) catch |err| return self.registryErrorResponse(id_value, err)
        else
            workspace.notifications.next_seq;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("polled_at_ms");
        try s.write(nowMs());
        try s.objectField("processes");
        try s.beginArray();
        for (workspace.managed_processes.items) |process| try writeManagedProcessSnapshot(&s, workspace, &process);
        for (workspace.tracked_terminal_processes.items) |process| try writeTrackedProcessSnapshot(&s, workspace, &process);
        for (workspace.external_processes.items) |process| try writeExternalProcessSnapshot(&s, workspace, &process);
        try s.endArray();
        try s.objectField("outcomes");
        try s.beginArray();
        if (include_outcomes) for (workspace.terminal_process_outcomes.items) |outcome| try writeTerminalOutcome(&s, &outcome);
        try s.endArray();
        try s.objectField("leases");
        try s.beginArray();
        for (workspace.leases.items) |lease| try writeLeaseRecord(&s, &lease);
        try s.endArray();
        try s.objectField("notifications");
        try s.beginArray();
        if (include_notifications) for (notifications.items) |notification| try writeRegistryNotification(&s, notification);
        try s.endArray();
        try s.objectField("next_notification_seq");
        try s.write(next_notification_seq);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn processInspectResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        const process_id = requiredObjectString(params, "process_id") catch |err| return self.registryErrorResponse(id_value, err);
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        for (workspace.managed_processes.items) |process| {
            if (!std.mem.eql(u8, process.id, process_id) and !std.mem.eql(u8, process.name, process_id)) continue;
            try s.objectField("process");
            try writeManagedProcessSnapshot(&s, workspace, &process);
            try s.endObject();
            try s.endObject();
            return try writer.toOwnedSlice();
        }
        for (workspace.tracked_terminal_processes.items) |process| {
            if (!std.mem.eql(u8, process.process_id, process_id)) continue;
            try s.objectField("process");
            try writeTrackedProcessSnapshot(&s, workspace, &process);
            try s.endObject();
            try s.endObject();
            return try writer.toOwnedSlice();
        }
        for (workspace.external_processes.items) |process| {
            if (!std.mem.eql(u8, process.process_id, process_id)) continue;
            try s.objectField("process");
            try writeExternalProcessSnapshot(&s, workspace, &process);
            try s.endObject();
            try s.endObject();
            return try writer.toOwnedSlice();
        }
        for (workspace.terminal_process_outcomes.items) |outcome| {
            if (!std.mem.eql(u8, outcome.process_id, process_id)) continue;
            try s.objectField("outcome");
            try writeTerminalOutcome(&s, &outcome);
            try s.endObject();
            try s.endObject();
            return try writer.toOwnedSlice();
        }
        const response = try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "process not found");
        writer.deinit();
        return response;
    }

    fn processWaitResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        const process_id = requiredObjectString(params, "process_id") catch |err| return self.registryErrorResponse(id_value, err);
        const after_registry_revision = if (params == .object)
            jsonU64(params.object.get("after_registry_revision") orelse .null)
        else
            null;
        // A7 is deliberately bounded-immediate in P2. Clients poll; this
        // accepted field is ignored and never sleeps under the daemon lock.
        _ = if (params == .object) params.object.get("timeout_ms") else null;

        _ = self.registry.pruneTerminalProcessOutcomes(self.allocator, workspace.id, nowMs());
        var running = false;
        var outcome: ?*const process_registry.TerminalProcessOutcome = null;
        for (workspace.tracked_terminal_processes.items) |process| {
            if (!std.mem.eql(u8, process.process_id, process_id)) continue;
            running = true;
            break;
        }
        if (!running) {
            for (workspace.terminal_process_outcomes.items) |*candidate| {
                if (!std.mem.eql(u8, candidate.process_id, process_id)) continue;
                outcome = candidate;
                break;
            }
        }
        if (!running and outcome == null) {
            return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "process not found");
        }

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("process_id");
        try s.write(process_id);
        try s.objectField("terminal_state");
        if (outcome) |finished| try s.write(@tagName(finished.status)) else try s.write(null);
        try s.objectField("outcome");
        if (outcome) |finished| try writeTerminalOutcome(&s, finished) else try s.write(null);
        try s.objectField("changed");
        try s.write(if (running)
            (after_registry_revision != null and self.registry.registry_revision != after_registry_revision.?)
        else
            true);
        try s.objectField("timed_out");
        try s.write(running);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn processLogsResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        const process_id = requiredObjectString(params, "process_id") catch |err| return self.registryErrorResponse(id_value, err);

        // Managed proc:{...} IDs join this lookup when W5 adds daemon-owned
        // managed sessions. W3 only resolves tracked terminal process IDs.
        var session_id: ?[]const u8 = null;
        for (workspace.tracked_terminal_processes.items) |process| {
            if (std.mem.eql(u8, process.process_id, process_id)) {
                session_id = process.session_id;
                break;
            }
        }
        const session = if (session_id) |id| self.find(id) else null;
        if (session == null) {
            return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "process logs unavailable");
        }

        const after_cursor = if (params == .object)
            jsonU64(params.object.get("after_cursor") orelse .null)
        else
            null;
        const requested_max_bytes = if (params == .object)
            jsonU32(params.object.get("max_bytes") orelse .null) orelse 0
        else
            0;
        const max_bytes: ?usize = if (requested_max_bytes == 0)
            null
        else
            @min(@as(usize, @intCast(requested_max_bytes)), MAX_OUTPUT_RING);
        try session.?.poll(self.allocator);
        const text_range = outputWindowRange(session.?, after_cursor, 0, max_bytes);
        const text = try self.allocator.dupe(u8, session.?.output_ring.items[text_range.start..text_range.end]);
        defer self.allocator.free(text);

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("process_id");
        try s.write(process_id);
        try s.objectField("cursor");
        try s.write(session.?.output_total);
        try s.objectField("complete");
        // poll drained the backend before this check; EOF means no unread
        // stream bytes remain, while the ring still retains the returned text.
        try s.write(!session.?.running and session.?.stream_eof);
        try s.objectField("text");
        try s.write(text);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn leaseCheckResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(headless.registry.LeaseCheckRequest, self.allocator, params) catch
            return self.registryErrorResponse(id_value, error.InvalidParams);
        defer parsed.deinit();
        const request = parsed.value;
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        if (request.owner.len == 0) return self.registryErrorResponse(id_value, error.LeaseOwnerRequired);

        var inferred_resources: [1][]const u8 = undefined;
        const selected_resources: []const []const u8 = if (request.explicit_resources.len != 0)
            request.explicit_resources
        else if (request.resources.len != 0)
            request.resources
        else if (process_registry.inferredWorkspaceResource(request.command)) |resource| blk: {
            inferred_resources[0] = resource;
            break :blk inferred_resources[0..];
        } else &.{};

        var conflicts: std.ArrayList(process_registry.LeaseConflictInfo) = .empty;
        defer conflicts.deinit(self.allocator);
        if (selected_resources.len != 0) {
            self.registry.checkLeaseConflicts(
                self.allocator,
                workspace.id,
                request.owner,
                selected_resources,
                nowMs(),
                &conflicts,
            ) catch |err| return self.registryErrorResponse(id_value, err);
        }

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("command");
        try s.write(request.command);
        try s.objectField("classification");
        try s.write(@tagName(process_registry.classifyWorkspaceCommand(request.command)));
        try s.objectField("resources");
        try writeStringList(&s, request.resources);
        try s.objectField("explicit_resources");
        try writeStringList(&s, request.explicit_resources);
        try s.objectField("inferred_resources");
        if (request.explicit_resources.len == 0 and request.resources.len == 0)
            try writeStringList(&s, selected_resources)
        else
            try s.beginArray();
        if (request.explicit_resources.len != 0 or request.resources.len != 0) try s.endArray();
        try s.objectField("conflicts");
        try writeLeaseConflictList(&s, workspace, conflicts.items);
        try s.objectField("allowed");
        try s.write(conflicts.items.len == 0);
        try s.objectField("conflict_count");
        try s.write(@as(u32, @intCast(conflicts.items.len)));
        try s.objectField("warning");
        try s.write(null);
        try s.objectField("options");
        try writeLeaseOptions(&s);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn leaseAcquireResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(headless.registry.LeaseAcquireRequest, self.allocator, params) catch
            return self.registryErrorResponse(id_value, error.InvalidParams);
        defer parsed.deinit();
        const request = parsed.value;
        const workspace = self.resolveLeaseAcquireWorkspace(params) catch |err| return self.registryErrorResponse(id_value, err);
        if (request.owner.len == 0) return self.registryErrorResponse(id_value, error.LeaseOwnerRequired);
        if (request.resources.len == 0) return self.registryErrorResponse(id_value, error.LeaseResourcesRequired);

        var conflicts: std.ArrayList(process_registry.LeaseConflictInfo) = .empty;
        defer conflicts.deinit(self.allocator);
        self.registry.checkLeaseConflicts(
            self.allocator,
            workspace.id,
            request.owner,
            request.resources,
            nowMs(),
            &conflicts,
        ) catch |err| return self.registryErrorResponse(id_value, err);
        if (!request.force and conflicts.items.len != 0) {
            return try leaseConflictErrorResponse(self, id_value, workspace, conflicts.items);
        }

        const renewed_in_place = leaseResourcesMatch(workspace.leases.items, request.owner, request.resources);
        const client_id = self.effectiveLeaseClientId(request.client_id, request.owner, nowMs()) catch |err| return self.registryErrorResponse(id_value, err);
        var acquired = self.registry.acquireLease(
            self.allocator,
            workspace.id,
            request.owner,
            client_id,
            request.command,
            request.resources,
            request.force,
            process_registry.clampLeaseTtl(request.ttl_ms),
            nowMs(),
        ) catch |err| return self.registryErrorResponse(id_value, err);
        defer acquired.deinit(self.allocator);

        const lease = acquired.lease;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("acquired");
        try s.write(true);
        try s.objectField("forced");
        try s.write(request.force);
        try s.objectField("renewed");
        try s.write(renewed_in_place);
        try s.objectField("lease_id");
        try s.write(lease.id);
        try s.objectField("owner");
        try s.write(lease.owner);
        try s.objectField("client_id");
        try s.write(lease.client_id);
        try s.objectField("command");
        try s.write(lease.command);
        try s.objectField("resources");
        try writeStringList(&s, lease.resources.items);
        try s.objectField("created_at_ms");
        try s.write(lease.created_at_ms);
        try s.objectField("expires_at_ms");
        try s.write(lease.expires_at_ms);
        try s.objectField("last_renewal_ms");
        try s.write(lease.last_renewal_ms);
        try s.objectField("lease");
        try writeLeaseRecord(&s, lease);
        try s.objectField("conflicts");
        try s.beginArray();
        try s.endArray();
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn leaseRenewResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(headless.registry.LeaseRenewRequest, self.allocator, params) catch
            return self.registryErrorResponse(id_value, error.InvalidParams);
        defer parsed.deinit();
        const request = parsed.value;
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        if (request.owner.len == 0 or request.lease_id.len == 0) return self.registryErrorResponse(id_value, error.InvalidParams);
        const client_id = self.effectiveLeaseClientId(request.client_id, request.owner, nowMs()) catch |err| return self.registryErrorResponse(id_value, err);
        const lease = self.registry.renewLeaseById(
            self.allocator,
            workspace.id,
            request.owner,
            request.lease_id,
            process_registry.clampLeaseTtl(request.ttl_ms),
            nowMs(),
        ) catch |err| switch (err) {
            error.LeaseNotFound => return self.registryErrorResponse(id_value, err),
            error.LeaseOwnerMismatch => {
                var conflicts: std.ArrayList(process_registry.LeaseConflictInfo) = .empty;
                defer conflicts.deinit(self.allocator);
                for (workspace.leases.items) |existing| {
                    if (!std.mem.eql(u8, existing.id, request.lease_id)) continue;
                    try conflicts.append(self.allocator, .{
                        .owner = existing.owner,
                        .client_id = existing.client_id,
                        .lease_id = existing.id,
                        .command = existing.command,
                        .resources = existing.resources.items,
                    });
                    break;
                }
                return try leaseConflictErrorResponse(self, id_value, workspace, conflicts.items);
            },
        };

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("renewed");
        try s.write(true);
        try s.objectField("lease_id");
        try s.write(lease.id);
        try s.objectField("owner");
        try s.write(lease.owner);
        try s.objectField("client_id");
        try s.write(client_id);
        try s.objectField("created_at_ms");
        try s.write(lease.created_at_ms);
        try s.objectField("expires_at_ms");
        try s.write(lease.expires_at_ms);
        try s.objectField("last_renewal_ms");
        try s.write(lease.last_renewal_ms);
        try s.objectField("lease");
        try writeLeaseRecord(&s, lease);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn leaseReleaseResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(headless.registry.LeaseReleaseRequest, self.allocator, params) catch
            return self.registryErrorResponse(id_value, error.InvalidParams);
        defer parsed.deinit();
        const request = parsed.value;
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        if (request.owner.len == 0) return self.registryErrorResponse(id_value, error.LeaseOwnerRequired);
        _ = self.effectiveLeaseClientId(request.client_id, request.owner, nowMs()) catch |err| return self.registryErrorResponse(id_value, err);
        const released_count = self.registry.releaseLease(self.allocator, workspace.id, request.owner, request.lease_id, nowMs());

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("released");
        try s.write(released_count != 0);
        try s.objectField("released_count");
        try s.write(@as(u32, @intCast(released_count)));
        try s.objectField("lease_id");
        if (request.lease_id) |lease_id| try s.write(lease_id) else try s.write(null);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn notificationsResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(headless.registry.NotificationsRequest, self.allocator, params) catch
            return self.registryErrorResponse(id_value, error.InvalidParams);
        defer parsed.deinit();
        const request = parsed.value;
        const workspace = self.resolveWorkspaceFromParams(params) catch |err| return self.registryErrorResponse(id_value, err);
        var notifications: std.ArrayList(*const process_registry.Notification) = .empty;
        defer notifications.deinit(self.allocator);
        const next_seq = self.registry.collectNotifications(
            self.allocator,
            workspace.id,
            request.owner_session_id,
            request.after_seq,
            @intCast(request.limit),
            &notifications,
        ) catch |err| return self.registryErrorResponse(id_value, err);

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField("notifications");
        try s.beginArray();
        for (notifications.items) |notification| try writeRegistryNotification(&s, notification);
        try s.endArray();
        try s.objectField("next_notification_seq");
        try s.write(next_seq);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    /// Returns the registered client for a lease request, or creates the
    /// short-lived compatibility client used by legacy owner callers.
    fn effectiveLeaseClientId(self: *Daemon, params_client_id: ?[]const u8, owner: []const u8, now_ms: i64) ![]const u8 {
        if (params_client_id) |client_id| {
            if (self.registry.client(client_id)) |client| {
                if (client.closed) return error.ClientClosed;
                return client.client_id;
            }
        }
        return (try self.registry.ensureCompatibilityClient(self.allocator, owner, now_ms)).client_id;
    }

    fn clientRegisterResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const persistent = if (params == .object) jsonBool(params.object.get("persistent") orelse .null) orelse false else false;
        if (params != .object and params != .null) return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_INVALID_PARAMS, "params must be an object or null");
        const client = self.registry.registerClient(self.allocator, persistent, nowMs()) catch |err| return self.registryErrorResponse(id_value, err);
        return try clientResponse(self.allocator, id_value, &self.registry, .register, client);
    }

    fn clientHeartbeatResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const client_id = requiredObjectString(params, "client_id") catch |err| return self.registryErrorResponse(id_value, err);
        const accepted = self.registry.heartbeatClient(client_id, nowMs());
        if (!accepted) return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "client not found");
        const client = self.registry.client(client_id).?;
        return try clientResponse(self.allocator, id_value, &self.registry, .heartbeat, client);
    }

    fn clientCloseResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const client_id = requiredObjectString(params, "client_id") catch |err| return self.registryErrorResponse(id_value, err);
        const closed = self.registry.closeClient(client_id, nowMs());
        if (!closed) return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "client not found");
        const client = self.registry.client(client_id).?;
        return try clientResponse(self.allocator, id_value, &self.registry, .close, client);
    }

    fn resolveWorkspaceFromParams(self: *Daemon, params: std.json.Value) !*process_registry.WorkspaceRecord {
        const fields = try workspaceRefFields(params);
        const now = nowMs();
        var derived_id: ?[]u8 = null;
        defer if (derived_id) |value| self.allocator.free(value);

        var workspace_id = fields.workspace_id;
        if (fields.workspace_path) |path| {
            derived_id = try workspace_identity.deriveProjectId(self.allocator, path);
            if (workspace_id) |id| {
                if (!std.mem.eql(u8, id, derived_id.?)) return error.WorkspaceReferenceMismatch;
            } else {
                workspace_id = derived_id.?;
            }
            if (self.registry.workspaceByPath(self.allocator, path, now)) |existing| {
                if (!std.mem.eql(u8, existing.id, workspace_id.?)) return error.WorkspacePathMapsToDifferentId;
            }
        }
        const id = workspace_id orelse return error.WorkspaceReferenceRequired;
        if (fields.workspace_path == null and self.registry.workspace(id) == null) return error.WorkspaceNotFound;
        const workspace = try self.registry.ensureWorkspace(self.allocator, id);
        // Path-based reads may establish only volatile workspace metadata; the
        // registry is not a durable or externally advertised mutation in P2.
        if (fields.workspace_path) |path| return try self.registry.registerWorkspacePath(self.allocator, id, path, now);
        return workspace;
    }

    fn resolveLeaseAcquireWorkspace(self: *Daemon, params: std.json.Value) !*process_registry.WorkspaceRecord {
        const fields = try workspaceRefFields(params);
        if (fields.workspace_id) |workspace_id| {
            if (fields.workspace_path == null) return try self.registry.ensureWorkspace(self.allocator, workspace_id);
        }
        return self.resolveWorkspaceFromParams(params);
    }

    fn registryErrorResponse(self: *Daemon, id_value: std.json.Value, err: anyerror) ![]u8 {
        const mapped = switch (err) {
            error.InvalidParams,
            error.WorkspaceReferenceRequired,
            error.WorkspaceReferenceMismatch,
            error.WorkspacePathRequired,
            error.WorkspacePathMapsToDifferentId,
            error.WorkspaceIdRequired,
            error.ClientOwnerRequired,
            error.LeaseOwnerRequired,
            error.LeaseResourcesRequired,
            => .{ headless.registry.ERR_INVALID_PARAMS, "invalid workspace or client parameters" },
            error.WorkspaceNotFound => .{ headless.registry.ERR_RESOURCE_NOT_FOUND, "workspace not found" },
            error.LeaseNotFound => .{ headless.registry.ERR_RESOURCE_NOT_FOUND, "lease not found" },
            error.ClientClosed => .{ headless.registry.ERR_INVALID_STATE, "client is closed" },
            error.WorkspaceCapacityExceeded => .{ headless.registry.ERR_INVALID_STATE, "workspace registry capacity exceeded" },
            error.SessionNotFound => .{ headless.registry.ERR_RESOURCE_NOT_FOUND, "resource not found" },
            else => .{ headless.registry.ERR_INTERNAL, @errorName(err) },
        };
        return try errorResponseAlloc(self.allocator, id_value, mapped[0], mapped[1]);
    }

    fn listResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("daemon_running");
        try s.write(true);
        try s.objectField("protocol_version");
        try s.write(PROTOCOL_VERSION);
        try s.objectField("sessions");
        try s.beginArray();
        for (self.sessions.items) |session| try writeSessionSummary(&s, session);
        try s.endArray();
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn inspectResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("session");
        try writeSessionSummary(&s, session);
        try s.objectField("tail_bytes");
        try s.write(session.output_ring.items.len);
        try s.objectField("cwd");
        try s.write(session.cwd);
        try s.objectField("command");
        try s.write(session.command_label);
        try s.objectField("attached_clients");
        try s.beginArray();
        for (session.attach_clients.items) |client| {
            try s.beginObject();
            try s.objectField("attach_id");
            try s.write(client.attach_id);
            try s.objectField("label");
            try s.write(client.label);
            try s.objectField("created_at_ms");
            try s.write(client.created_at_ms);
            try s.objectField("last_seen_at_ms");
            try s.write(client.last_seen_at_ms);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn createResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const session_id = jsonString(params.object.get("id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing id");
        if (self.find(session_id)) |existing| {
            // A duplicate create is an attach-or-create request. Preserve a live
            // PTY, but never hand a stopped one back as though it were reusable:
            // the desktop would otherwise discard and reattach the same dead
            // session every frame without ever starting a replacement shell.
            try existing.poll(self.allocator);
            if (!existing.running) {
                for (self.sessions.items, 0..) |candidate, index| {
                    if (candidate != existing) continue;
                    self.noteSessionExitInRegistry(existing, null, nowMs());
                    self.removeAt(index);
                    break;
                }
            } else {
                existing.last_attached_at_ms = nowMs();
                return try okSessionResponse(self.allocator, id_value, existing, false);
            }
        }

        const command = try jsonStringArray(self.allocator, params.object.get("command") orelse .null);
        defer freeStringArray(self.allocator, command);
        const cwd = jsonString(params.object.get("cwd") orelse .null) orelse ".";
        const session = try PtySession.create(self.allocator, .{
            .session_id = session_id,
            .project_id = jsonString(params.object.get("workspace_id") orelse params.object.get("project_id") orelse .null) orelse "",
            .project_path = jsonString(params.object.get("workspace_path") orelse params.object.get("project_path") orelse .null) orelse "",
            .cwd = cwd,
            .label = jsonString(params.object.get("label") orelse .null) orelse "",
            .command = command,
            .cols = jsonU16(params.object.get("cols") orelse .null) orelse DEFAULT_COLS,
            .rows = jsonU16(params.object.get("rows") orelse .null) orelse DEFAULT_ROWS,
            .dock_id = jsonU32(params.object.get("dock_id") orelse .null) orelse 0,
            .pane_id = jsonU32(params.object.get("pane_id") orelse .null) orelse 0,
            .pref_path = jsonString(params.object.get("pref_path") orelse .null) orelse "",
        });
        errdefer session.deinit(self.allocator);
        try self.sessions.append(self.allocator, session);
        const command_line = std.mem.join(self.allocator, " ", command) catch |err| {
            log.warn("registry command join failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
            return try okSessionResponse(self.allocator, id_value, session, true);
        };
        defer self.allocator.free(command_line);
        self.observeSessionInRegistry(session, command_line, nowMs());
        return try okSessionResponse(self.allocator, id_value, session, true);
    }

    fn attachResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        const label = jsonString(params.object.get("label") orelse .null) orelse "";
        const attach_id = try session.attach(self.allocator, label);
        defer self.allocator.free(attach_id);
        return try okValueResponse(self.allocator, id_value, .{
            .id = session.session_id,
            .attach_id = attach_id,
            .running = session.running,
            .attached_clients = session.attach_clients.items.len,
        });
    }

    fn detachResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        const attach_id = jsonString(params.object.get("attach_id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing attach_id");
        const detached = session.detach(self.allocator, attach_id);
        return try okValueResponse(self.allocator, id_value, .{
            .accepted = detached,
            .attached_clients = session.attach_clients.items.len,
        });
    }

    fn writeResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        touchAttachFromParams(session, params);
        const text = jsonString(params.object.get("text") orelse .null) orelse "";
        const wrote = try session.writeInput(text);
        log.info(
            "write id_len={d} pid={d} pgrp={?d} input_bytes={d}",
            .{ session.session_id.len, session.child_pid, session.foregroundProcessGroup(), text.len },
        );
        // Respond immediately with process metadata only (mirrors
        // resizeResponse). This used to pollSettle (~15ms) and return the
        // echo/output bytes, but shipping ring output in a write response
        // breaks the tail-cursor ordering contract: the client must consume
        // ring bytes exclusively via `session.tail`, or an out-of-band
        // next_offset skips un-tailed bytes (the frozen-pane-after-unzoom
        // bug). Dropping the settle also removes per-keystroke IPC latency.
        return try okValueResponse(self.allocator, id_value, .{
            .accepted = wrote,
            .bytes = text.len,
            .running = session.running,
            .pid = session.child_pid,
            .foreground_process_group = session.foregroundProcessGroup(),
        });
    }

    fn resizeResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        touchAttachFromParams(session, params);
        session.resize(
            jsonU16(params.object.get("cols") orelse .null) orelse session.cols,
            jsonU16(params.object.get("rows") orelse .null) orelse session.rows,
        );
        // Respond immediately with process metadata only. This used to
        // pollSettle (~15ms) and return the program's SIGWINCH redraw bytes,
        // but the client must not apply output from a resize response anyway
        // (its terminal model still has the old grid at that point — the nvim
        // unzoom bug), and it tails the redraw via `session.tail` right after.
        // Blocking here only added latency to every interactive pane resize.
        // Clients tolerate the missing `text`/`next_offset` fields: absent
        // `text` reads as empty and the tail cursor stays untouched.
        return try okValueResponse(self.allocator, id_value, .{
            .accepted = true,
            .running = session.running,
            .pid = session.child_pid,
            .foreground_process_group = session.foregroundProcessGroup(),
            .child_process_count = childProcessCount(session.child_pid),
        });
    }

    fn tailResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value, screen: bool) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try self.writeTailResult(&s, session, params, screen);
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn tailBatchResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return error.InvalidParams;
        const requests = params.object.get("requests") orelse return error.InvalidParams;
        if (requests != .array) return error.InvalidParams;

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("responses");
        try s.beginArray();
        for (requests.array.items) |request| {
            try s.beginObject();
            const session = if (request == .object)
                if (jsonString(request.object.get("id") orelse .null)) |session_id| self.find(session_id) else null
            else
                null;
            if (session) |found| {
                try s.objectField("result");
                try self.writeTailResult(&s, found, request, false);
            } else {
                try s.objectField("error");
                try s.write("not_found");
            }
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn writeTailResult(self: *Daemon, s: *std.json.Stringify, session: *PtySession, params: std.json.Value, screen: bool) !void {
        touchAttachFromParams(session, params);
        try session.poll(self.allocator);
        const lines = jsonU32(params.object.get("lines") orelse .null) orelse if (screen) DEFAULT_ROWS else 80;
        const start_offset = jsonUsize(params.object.get("offset") orelse .null);
        const max_bytes = jsonUsize(params.object.get("max_bytes") orelse .null);
        const text_range = outputWindowRange(session, if (start_offset) |offset| @intCast(offset) else null, lines, max_bytes);
        const text = try self.allocator.dupe(u8, session.output_ring.items[text_range.start..text_range.end]);
        defer self.allocator.free(text);
        const ring_start = session.ringStart();
        try s.write(.{
            .id = session.session_id,
            .running = session.running,
            .exit_status = session.exit_status,
            .pid = session.child_pid,
            .foreground_process_group = session.foregroundProcessGroup(),
            .text = text,
            .offset = ring_start + @as(u64, @intCast(text_range.start)),
            .next_offset = session.output_total,
            .child_process_count = childProcessCount(session.child_pid),
        });
    }

    fn killResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const wanted_id = jsonString(params.object.get("id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing id");
        for (self.sessions.items) |session| {
            if (!std.mem.eql(u8, session.session_id, wanted_id)) continue;
            const signaled = session.terminate();
            self.noteSessionExitInRegistry(session, "session.kill", nowMs());
            return try okValueResponse(self.allocator, id_value, .{ .accepted = true, .signaled = signaled });
        }
        return try errorResponseAlloc(self.allocator, id_value, "not_found", wanted_id);
    }

    fn cleanupResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.sessions.items.len) {
            const session = self.sessions.items[index];
            try session.poll(self.allocator);
            if (session.running) {
                index += 1;
                continue;
            }
            self.noteSessionExitInRegistry(session, null, nowMs());
            self.removeAt(index);
            removed += 1;
        }
        return try okValueResponse(self.allocator, id_value, .{ .removed = removed });
    }

    fn chatTurnStartResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn_id = jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id");
        if (self.findChatTurn(turn_id)) |turn| return try okValueResponse(self.allocator, id_value, .{ .turn_id = turn.turn_id, .created = false });

        const turn = try createChatTurnFromParams(self.allocator, params);
        errdefer turn.deinit(self.allocator);
        try self.chat_turns.append(self.allocator, turn);
        errdefer _ = self.chat_turns.pop();
        const thread = try std.Thread.spawn(.{}, chatTurnThread, .{ self.allocator, turn });
        turn.worker_thread = thread;
        return try okValueResponse(self.allocator, id_value, .{ .turn_id = turn.turn_id, .created = true });
    }

    fn chatTurnListResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const workspace_filter = if (params == .object) jsonString(params.object.get("workspace_id") orelse .null) else null;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("turns");
        try s.beginArray();
        for (self.chat_turns.items) |turn| {
            if (turn.consumed) continue;
            if (workspace_filter) |wanted| if (!std.mem.eql(u8, wanted, turn.workspace_id)) continue;
            {
                lockTurn(turn);
                defer turn.mutex.unlock();
                try writeChatTurnSummary(&s, turn);
            }
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn chatTurnTailResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn = self.findChatTurn(jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id")) orelse
            return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
        const after_seq = jsonUsize(params.object.get("after_seq") orelse .null) orelse 0;
        lockTurn(turn);
        defer turn.mutex.unlock();
        if (chatTailUpperBound(turn, @intCast(after_seq)) > MAX_RESPONSE_BYTES) return error.ResponseTooLarge;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try writeChatTurnTail(&s, turn, @intCast(after_seq));
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn chatTurnApproveResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn = self.findChatTurn(jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id")) orelse
            return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
        const call_id = jsonString(params.object.get("call_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing call_id");
        const decision_text = jsonString(params.object.get("decision") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing decision");
        const decision: ApprovalDecision = if (std.mem.eql(u8, decision_text, "approve")) .approve else .deny;
        lockTurn(turn);
        defer turn.mutex.unlock();
        if (turn.pending_approval == null or !std.mem.eql(u8, turn.pending_approval.?.call_id, call_id)) return try errorResponseAlloc(self.allocator, id_value, "not_found", "approval not found");
        if (turn.approval_call_id) |old| self.allocator.free(old);
        turn.approval_call_id = try self.allocator.dupe(u8, call_id);
        turn.approval_decision = decision;
        return try okValueResponse(self.allocator, id_value, .{ .accepted = true });
    }

    fn chatTurnCancelResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn = self.findChatTurn(jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id")) orelse
            return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
        lockTurn(turn);
        turn.cancel_requested = true;
        if (turn.status == .running or turn.status == .waiting_approval) {
            turn.status = .aborted;
            turn.appendEvent(self.allocator, "aborted", "{}");
        }
        turn.mutex.unlock();
        return try okValueResponse(self.allocator, id_value, .{ .accepted = true });
    }

    fn chatTurnConsumeResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn_id = jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id");
        for (self.chat_turns.items, 0..) |turn, index| {
            if (!std.mem.eql(u8, turn.turn_id, turn_id)) continue;
            lockTurn(turn);
            const can_remove = turn.worker_done;
            turn.consumed = true;
            turn.mutex.unlock();
            if (can_remove) self.chat_turns.orderedRemove(index).deinit(self.allocator);
            return try okValueResponse(self.allocator, id_value, .{ .accepted = true });
        }
        return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
    }

    fn findChatTurn(self: *Daemon, turn_id: []const u8) ?*ChatTurn {
        for (self.chat_turns.items) |turn| if (std.mem.eql(u8, turn.turn_id, turn_id)) return turn;
        return null;
    }

    fn requiredSession(self: *Daemon, id_value: std.json.Value, params: std.json.Value) !*PtySession {
        _ = id_value;
        if (params != .object) return error.InvalidParams;
        const wanted_id = jsonString(params.object.get("id") orelse .null) orelse return error.MissingSessionId;
        return self.find(wanted_id) orelse return error.SessionNotFound;
    }
};

const WorkspaceRefFields = struct {
    workspace_id: ?[]const u8 = null,
    workspace_path: ?[]const u8 = null,
};

fn parseDaemonParams(comptime T: type, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Parsed(T) {
    return try std.json.parseFromValue(T, allocator, params, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn workspaceRefFields(params: std.json.Value) !WorkspaceRefFields {
    if (params != .object) return error.InvalidParams;
    const params_object = params.object;
    const workspace_value = params_object.get("workspace") orelse .null;
    const workspace_object = if (workspace_value == .object) workspace_value.object else if (workspace_value == .null)
        params_object
    else
        return error.InvalidParams;
    return .{
        .workspace_id = try optionalObjectString(workspace_object, "workspace_id"),
        .workspace_path = try optionalObjectString(workspace_object, "workspace_path"),
    };
}

fn optionalObjectString(object: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    return jsonString(value) orelse error.InvalidParams;
}

fn leaseResourcesMatch(
    leases: []const process_registry.LeaseRecord,
    owner: []const u8,
    requested: []const []const u8,
) bool {
    for (leases) |lease| {
        if (!std.mem.eql(u8, lease.owner, owner)) continue;
        var unique_requested: usize = 0;
        for (requested, 0..) |resource, index| {
            var duplicate = false;
            for (requested[0..index]) |prior| {
                if (std.mem.eql(u8, prior, resource)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) unique_requested += 1;
        }
        if (lease.resources.items.len != unique_requested) continue;
        var matches = true;
        for (lease.resources.items) |resource| {
            var found = false;
            for (requested) |candidate| {
                if (std.mem.eql(u8, resource, candidate)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn requiredObjectString(params: std.json.Value, field: []const u8) ![]const u8 {
    if (params != .object) return error.InvalidParams;
    const value = params.object.get(field) orelse return error.InvalidParams;
    const string = jsonString(value) orelse return error.InvalidParams;
    if (string.len == 0) return error.InvalidParams;
    return string;
}

fn writeRegistryEnvelope(s: *std.json.Stringify, daemon: *const Daemon) !void {
    try s.objectField("instance_nonce");
    try s.write(daemon.registry.instance_nonce);
    try s.objectField("registry_revision");
    try s.write(daemon.registry.registry_revision);
}

fn writeLeaseOptions(s: *std.json.Stringify) !void {
    try s.beginArray();
    try s.write(headless.registry.NOTIFICATION_OPTION_WAIT);
    try s.write(headless.registry.NOTIFICATION_OPTION_CANCEL_EXISTING);
    try s.write(headless.registry.NOTIFICATION_OPTION_RUN_ANYWAY);
    try s.write(headless.registry.NOTIFICATION_OPTION_OPEN_OWNER);
    try s.endArray();
}

fn writeLeaseConflictList(
    s: *std.json.Stringify,
    workspace: *const process_registry.WorkspaceRecord,
    conflicts: []const process_registry.LeaseConflictInfo,
) !void {
    try s.beginArray();
    for (conflicts) |conflict| try writeLeaseConflict(s, workspace, conflict);
    try s.endArray();
}

fn writeLeaseConflict(
    s: *std.json.Stringify,
    workspace: *const process_registry.WorkspaceRecord,
    conflict: process_registry.LeaseConflictInfo,
) !void {
    var created_at_ms: i64 = 0;
    var expires_at_ms: ?i64 = null;
    for (workspace.leases.items) |lease| {
        if (!std.mem.eql(u8, lease.id, conflict.lease_id)) continue;
        created_at_ms = lease.created_at_ms;
        expires_at_ms = lease.expires_at_ms;
        break;
    }
    try s.beginObject();
    try s.objectField("kind");
    try s.write("lease");
    try s.objectField("source");
    try s.write("lease");
    try s.objectField("resource");
    if (conflict.resources.len != 0) try s.write(conflict.resources[0]) else try s.write("");
    try s.objectField("id");
    try s.write(conflict.lease_id);
    try s.objectField("owner");
    try s.write(conflict.owner);
    try s.objectField("owner_kind");
    try s.write("agent");
    try s.objectField("command");
    try s.write(conflict.command);
    try s.objectField("status");
    try s.write("leased");
    try s.objectField("cancel_method");
    try s.write("workspace.releaseLease (owner only)");
    try s.objectField("session_id");
    try s.write(null);
    try s.objectField("pane_id");
    try s.write(null);
    try s.objectField("thread_id");
    try s.write(null);
    try s.objectField("started_at_ms");
    try s.write(created_at_ms);
    try s.objectField("expires_at_ms");
    if (expires_at_ms) |expires| try s.write(expires) else try s.write(null);
    try s.endObject();
}

fn writeLeaseConflictData(
    s: *std.json.Stringify,
    workspace: *const process_registry.WorkspaceRecord,
    conflicts: []const process_registry.LeaseConflictInfo,
) !void {
    try s.beginObject();
    try s.objectField("conflicts");
    try writeLeaseConflictList(s, workspace, conflicts);
    try s.objectField("options");
    try writeLeaseOptions(s);
    try s.endObject();
}

fn leaseConflictErrorResponse(
    self: *Daemon,
    id_value: std.json.Value,
    workspace: *const process_registry.WorkspaceRecord,
    conflicts: []const process_registry.LeaseConflictInfo,
) ![]u8 {
    var data_writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer data_writer.deinit();
    var data_stringify: std.json.Stringify = .{ .writer = &data_writer.writer, .options = .{} };
    try writeLeaseConflictData(&data_stringify, workspace, conflicts);
    const data_json = try data_writer.toOwnedSlice();
    defer self.allocator.free(data_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return try errorResponseAllocWithData(
        self.allocator,
        id_value,
        headless.registry.ERR_CONFLICT,
        "workspace lease conflicts with an existing lease",
        parsed.value,
    );
}

fn writeWorkspaceInfo(s: *std.json.Stringify, daemon: *const Daemon, workspace: *const process_registry.WorkspaceRecord) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(workspace.id);
    try s.objectField("path");
    if (workspace.canonical_path) |path| try s.write(path) else try s.write("");
    try s.objectField("label");
    try s.write(null);
    try s.objectField("instance_nonce");
    try s.write(daemon.registry.instance_nonce);
    try s.objectField("registry_revision");
    try s.write(daemon.registry.registry_revision);
    try s.endObject();
}

fn writeManagedProcessSnapshot(
    s: *std.json.Stringify,
    workspace: *const process_registry.WorkspaceRecord,
    process: *const process_registry.ManagedProcess,
) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(process.id);
    try s.objectField("workspace_id");
    try s.write(workspace.id);
    try s.objectField("workspace_path");
    if (workspace.canonical_path) |path| try s.write(path) else try s.write("");
    try s.objectField("source");
    try s.write("managed");
    try s.objectField("kind");
    try s.write("managed");
    try s.objectField("name");
    try s.write(process.name);
    try s.objectField("owner");
    try s.write(null);
    try s.objectField("owner_session_id");
    try s.write(process.session_id);
    try s.objectField("command");
    try s.write(process.command);
    try s.objectField("cwd");
    try s.write(process.cwd);
    try s.objectField("status");
    try s.write(@tagName(process.status));
    try s.objectField("classification");
    try s.write(@tagName(process_registry.classifyWorkspaceCommand(process.command)));
    try s.objectField("resources");
    try writeStringList(s, process.resources.items);
    try s.objectField("pid");
    if (process.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (process.process_group) |group| try s.write(group) else try s.write(null);
    try s.objectField("dock_id");
    try s.write(null);
    try s.objectField("pane_id");
    try s.write(null);
    try s.objectField("created_at_ms");
    try s.write(@as(i64, 0));
    try s.objectField("started_at_ms");
    if (process.last_start_ms == 0) try s.write(null) else try s.write(process.last_start_ms);
    try s.objectField("finished_at_ms");
    if (process.last_exit_ms == 0) try s.write(null) else try s.write(process.last_exit_ms);
    try s.objectField("exit_code");
    try s.write(null);
    try s.objectField("signal");
    try s.write(null);
    try s.objectField("cancellation_reason");
    try s.write(null);
    try s.objectField("runtime_status");
    try s.write(@tagName(process.status));
    try s.objectField("restart_count");
    try s.write(process.restart_count);
    try s.objectField("attention");
    try s.write(false);
    try s.endObject();
}

fn writeTrackedProcessSnapshot(
    s: *std.json.Stringify,
    workspace: *const process_registry.WorkspaceRecord,
    process: *const process_registry.TrackedTerminalProcess,
) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(process.process_id);
    try s.objectField("workspace_id");
    try s.write(workspace.id);
    try s.objectField("workspace_path");
    if (workspace.canonical_path) |path| try s.write(path) else try s.write("");
    try s.objectField("source");
    try s.write("terminal");
    try s.objectField("kind");
    try s.write("tracked_terminal");
    try s.objectField("name");
    try s.write(process.command);
    try s.objectField("owner");
    if (process.owner_title.len == 0) try s.write(null) else try s.write(process.owner_title);
    try s.objectField("owner_session_id");
    try s.write(process.session_id);
    try s.objectField("command");
    try s.write(process.command);
    try s.objectField("cwd");
    try s.write(process.cwd);
    try s.objectField("status");
    try s.write("running");
    try s.objectField("classification");
    try s.write(@tagName(process_registry.classifyWorkspaceCommand(process.command)));
    try s.objectField("resources");
    try s.beginArray();
    try s.endArray();
    try s.objectField("pid");
    if (process.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (process.process_group) |group| try s.write(group) else try s.write(null);
    try s.objectField("dock_id");
    try s.write(process.dock_id);
    try s.objectField("pane_id");
    if (process.pane_id) |pane| try s.write(pane) else try s.write(null);
    try s.objectField("created_at_ms");
    try s.write(process.started_at_ms);
    try s.objectField("started_at_ms");
    try s.write(process.started_at_ms);
    try s.objectField("finished_at_ms");
    try s.write(null);
    try s.objectField("exit_code");
    try s.write(null);
    try s.objectField("signal");
    try s.write(null);
    try s.objectField("cancellation_reason");
    try s.write(null);
    try s.objectField("runtime_status");
    try s.write(null);
    try s.objectField("restart_count");
    try s.write(@as(u32, 0));
    try s.objectField("attention");
    try s.write(false);
    try s.endObject();
}

fn writeExternalProcessSnapshot(
    s: *std.json.Stringify,
    workspace: *const process_registry.WorkspaceRecord,
    process: *const process_registry.ExternalProcess,
) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(process.process_id);
    try s.objectField("workspace_id");
    try s.write(workspace.id);
    try s.objectField("workspace_path");
    if (workspace.canonical_path) |path| try s.write(path) else try s.write("");
    try s.objectField("source");
    try s.write("external");
    try s.objectField("kind");
    try s.write("external");
    try s.objectField("name");
    try s.write("");
    try s.objectField("owner");
    try s.write(process.owner_title);
    try s.objectField("owner_session_id");
    try s.write(null);
    try s.objectField("command");
    try s.write(process.command);
    try s.objectField("cwd");
    try s.write(process.cwd);
    try s.objectField("status");
    try s.write(@tagName(process.status));
    try s.objectField("classification");
    try s.write(@tagName(process_registry.classifyWorkspaceCommand(process.command)));
    try s.objectField("resources");
    try s.beginArray();
    try s.endArray();
    try s.objectField("pid");
    if (process.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (process.process_group) |group| try s.write(group) else try s.write(null);
    try s.objectField("dock_id");
    try s.write(null);
    try s.objectField("pane_id");
    try s.write(null);
    try s.objectField("created_at_ms");
    try s.write(process.started_at_ms);
    try s.objectField("started_at_ms");
    try s.write(process.started_at_ms);
    try s.objectField("finished_at_ms");
    if (process.finished_at_ms) |finished| try s.write(finished) else try s.write(null);
    try s.objectField("exit_code");
    try s.write(null);
    try s.objectField("signal");
    try s.write(null);
    try s.objectField("cancellation_reason");
    try s.write(null);
    try s.objectField("runtime_status");
    try s.write(null);
    try s.objectField("restart_count");
    try s.write(@as(u32, 0));
    try s.objectField("attention");
    try s.write(process.status == .failed or process.status == .crashed);
    try s.endObject();
}

fn writeTerminalOutcome(s: *std.json.Stringify, outcome: *const process_registry.TerminalProcessOutcome) !void {
    try s.beginObject();
    try s.objectField("workspace_id");
    try s.write(outcome.workspace_id);
    try s.objectField("process_id");
    try s.write(outcome.process_id);
    try s.objectField("id");
    try s.write(outcome.process_id);
    try s.objectField("generation");
    try s.write(outcome.generation);
    try s.objectField("session_id");
    try s.write(outcome.session_id);
    try s.objectField("command");
    try s.write(outcome.command);
    try s.objectField("cwd");
    try s.write(outcome.cwd);
    try s.objectField("classification");
    try s.write(@tagName(process_registry.classifyWorkspaceCommand(outcome.command)));
    try s.objectField("pid");
    if (outcome.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (outcome.process_group) |group| try s.write(group) else try s.write(null);
    try s.objectField("started_at_ms");
    try s.write(outcome.started_at_ms);
    try s.objectField("finished_at_ms");
    try s.write(outcome.finished_at_ms);
    try s.objectField("dock_id");
    try s.write(outcome.dock_id);
    try s.objectField("pane_id");
    if (outcome.pane_id) |pane| try s.write(pane) else try s.write(null);
    try s.objectField("owner_kind");
    try s.write(outcome.owner_kind);
    try s.objectField("owner_title");
    try s.write(outcome.owner_title);
    try s.objectField("provider");
    if (outcome.provider) |provider| try s.write(provider) else try s.write(null);
    try s.objectField("status");
    try s.write(@tagName(outcome.status));
    try s.objectField("exit_code");
    if (outcome.exit_code) |code| try s.write(code) else try s.write(null);
    try s.objectField("signal");
    if (outcome.signal) |signal| try s.write(signal) else try s.write(null);
    try s.objectField("cancellation_reason");
    if (outcome.cancellation_reason) |reason| try s.write(reason) else try s.write(null);
    try s.endObject();
}

fn writeLeaseRecord(s: *std.json.Stringify, lease: *const process_registry.LeaseRecord) !void {
    try s.beginObject();
    try s.objectField("workspace_id");
    try s.write(lease.workspace_id);
    try s.objectField("id");
    try s.write(lease.id);
    try s.objectField("owner");
    try s.write(lease.owner);
    try s.objectField("client_id");
    try s.write(lease.client_id);
    try s.objectField("command");
    try s.write(lease.command);
    try s.objectField("resources");
    try writeStringList(s, lease.resources.items);
    try s.objectField("created_at_ms");
    try s.write(lease.created_at_ms);
    try s.objectField("expires_at_ms");
    try s.write(lease.expires_at_ms);
    try s.objectField("last_renewal_ms");
    try s.write(lease.last_renewal_ms);
    try s.endObject();
}

fn writeRegistryNotification(s: *std.json.Stringify, notification: *const process_registry.Notification) !void {
    try s.beginObject();
    try s.objectField("seq");
    try s.write(notification.seq);
    try s.objectField("type");
    try s.write(notification.type);
    try s.objectField("workspace_id");
    try s.write(notification.workspace_id);
    try s.objectField("owner_session_id");
    if (notification.owner_session_id) |owner| try s.write(owner) else try s.write(null);
    try s.objectField("title");
    try s.write(notification.title);
    try s.objectField("body");
    try s.write(notification.body);
    try s.objectField("command");
    try s.write(notification.command);
    try s.objectField("created_at_ms");
    try s.write(notification.created_at_ms);
    try s.endObject();
}

fn writeStringList(s: *std.json.Stringify, values: []const []const u8) !void {
    try s.beginArray();
    for (values) |value| try s.write(value);
    try s.endArray();
}

const ClientResponseKind = enum { register, heartbeat, close };

fn clientResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    registry: *const process_registry.ProcessRegistry,
    kind: ClientResponseKind,
    client: *const process_registry.ClientRecord,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("instance_nonce");
    try s.write(registry.instance_nonce);
    try s.objectField("registry_revision");
    try s.write(registry.registry_revision);
    try s.objectField("client_id");
    try s.write(client.client_id);
    switch (kind) {
        .register => {
            try s.objectField("persistent");
            try s.write(client.persistent);
            try s.objectField("retention_ms");
            try s.write(if (client.persistent) @as(u64, 0) else @as(u64, @intCast(process_registry.DISCONNECTED_RETENTION_MS)));
        },
        .heartbeat => {
            try s.objectField("accepted");
            try s.write(true);
            try s.objectField("last_heartbeat_ms");
            try s.write(client.last_heartbeat_ms);
        },
        .close => {
            try s.objectField("closed");
            try s.write(client.closed);
            try s.objectField("released_leases");
            try s.write(@as(u32, 0));
        },
    }
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

pub fn runDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    try process_env.applyAugmentedPathToCurrentProcess(allocator);
    if (builtin.os.tag == .windows) return runWindowsDaemon(allocator, pref_path);
    return runUnixDaemon(allocator, pref_path);
}

fn runUnixDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    return runSessionizerServer(allocator, pref_path);
}

fn runWindowsDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    return runSessionizerServer(allocator, pref_path);
}

fn runSessionizerServer(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    var setup_threaded = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().createDirPath(setup_threaded.io(), pref_path);
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    const pid_path = try pidFilePath(allocator, pref_path);
    defer allocator.free(pid_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    var stop_requested = std.atomic.Value(bool).init(false);
    var server_context: SessionizerServerContext = .{
        .daemon = &daemon,
        .endpoint = endpoint,
        .pid_path = pid_path,
        .stop_requested = &stop_requested,
    };
    defer finishSessionizerServer(&server_context);

    // The readiness callback runs only after Unix bind or Windows pipe
    // ownership succeeds, so no lifetime worker can outlive a failed bind.
    try platform_ipc.serve(allocator, endpoint, .{
        .context = &server_context,
        .should_stop = sessionizerServerShouldStop,
        .handle_request = handleSessionizerServerRequest,
        .on_ready = sessionizerServerReady,
    }, .{
        .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
    });
}

const SessionizerServerContext = struct {
    daemon: *Daemon,
    endpoint: []const u8,
    pid_path: []const u8,
    stop_requested: *std.atomic.Value(bool),
    drain_thread: ?std.Thread = null,
    pid_published: bool = false,
};

fn sessionizerServerReady(raw_context: *anyopaque) !void {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    try writePidFile(context.pid_path);
    context.pid_published = true;
    context.drain_thread = try std.Thread.spawn(.{}, drainSessionsThread, .{DrainThreadContext{
        .daemon = context.daemon,
        .endpoint = context.endpoint,
        .stop_requested = context.stop_requested,
    }});
}

fn sessionizerServerShouldStop(raw_context: *anyopaque) bool {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    if (context.stop_requested.load(.acquire)) return true;
    const daemon = context.daemon;
    lockDaemon(daemon);
    defer daemon.mutex.unlock();
    return daemon.shutdown_requested and !daemon.hasLiveKeepAliveState();
}

/// True when a peer can still complete a connection to `endpoint`.
/// Used to refuse binding over a live daemon (Unix) instead of unlinking first.
/// Windows named-pipe busy is reported as `error.EndpointInUse` from
/// `platform_ipc.serve` (FIRST_PIPE_INSTANCE); this probe is retained for
/// endpoint classification tests and is Unix-oriented.
fn sessionizerEndpointIsLive(io: std.Io, endpoint: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    return platform_ipc.unixEndpointAcceptsConnections(io, endpoint);
}

/// Optional idle-exit override for hermetic tests. Unset/empty => persistent.
/// Uses the daemon allocator (not page_allocator) so test GPAs observe the alloc.
fn idleExitMsFromEnv(allocator: std.mem.Allocator) ?i64 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, IDLE_EXIT_ENV_NAME) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    if (parsed < 0) return null;
    return parsed;
}

fn handleSessionizerServerRequest(raw_context: *anyopaque, request: []u8) anyerror![]u8 {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    const daemon = context.daemon;
    defer daemon.allocator.free(request);

    lockDaemon(daemon);
    const response = daemon.handleRequest(std.mem.trim(u8, request, "\r")) catch |err| {
        daemon.mutex.unlock();
        return errorResponseAlloc(daemon.allocator, .null, "internal_error", @errorName(err));
    };
    daemon.mutex.unlock();
    return response;
}

const DrainThreadContext = struct {
    daemon: *Daemon,
    endpoint: []const u8,
    stop_requested: *std.atomic.Value(bool),
};

fn drainSessionsThread(context: DrainThreadContext) void {
    while (!context.stop_requested.load(.acquire)) {
        const daemon = context.daemon;
        lockDaemon(daemon);
        daemon.pollSessions();
        const prune_now_ms = nowMs();
        // Pruning mutates only each outcome list, not the workspaces array, so
        // iterating the records while pruning is safe under this lock.
        for (daemon.registry.workspaces.items) |workspace| {
            _ = daemon.registry.pruneTerminalProcessOutcomes(daemon.allocator, workspace.id, prune_now_ms);
        }
        const should_exit = daemon.shouldExitForIdle();
        daemon.mutex.unlock();
        if (should_exit) {
            context.stop_requested.store(true, .release);
            platform_ipc.wake(daemon.allocator, context.endpoint, .{
                .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
                .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
                .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
            });
            harness.shutdownOwnedProviderProcesses();
            return;
        }
        sleepMs(20);
    }
}

fn finishSessionizerServer(context: *SessionizerServerContext) void {
    context.stop_requested.store(true, .release);
    if (context.drain_thread != null) {
        platform_ipc.wake(context.daemon.allocator, context.endpoint, .{
            .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
            .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
            .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
        });
        context.drain_thread.?.join();
        context.drain_thread = null;
    }
    if (context.pid_published) deletePidFileIfOwned(context.pid_path);
}

fn lockDaemon(daemon: *Daemon) void {
    while (!daemon.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn lockTurn(turn: *ChatTurn) void {
    while (!turn.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn chatTurnKeepsDaemonAlive(status: ChatTurnStatus, consumed: bool, worker_done: bool) bool {
    if (status == .running or status == .waiting_approval) return true;
    // A finished result exists only in daemon memory until the desktop tails
    // and consumes it. Exiting after the generic idle timeout would discard
    // replies whenever Verde remained closed for more than 30 seconds.
    return !consumed or !worker_done;
}

fn sleepMs(milliseconds: i64) void {
    platform_runtime.sleepMillis(@intCast(@max(milliseconds, 0)));
}

fn okSessionResponse(allocator: std.mem.Allocator, id_value: std.json.Value, session: *const PtySession, created: bool) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("created");
    try s.write(created);
    try s.objectField("session");
    try writeSessionSummary(&s, session);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn okValueResponse(allocator: std.mem.Allocator, id_value: std.json.Value, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.write(value);
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn errorResponseAlloc(allocator: std.mem.Allocator, id_value: std.json.Value, code: []const u8, message: []const u8) ![]u8 {
    return errorResponseAllocWithData(allocator, id_value, code, message, null);
}

fn errorResponseAllocWithData(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    code: []const u8,
    message: []const u8,
    data: ?std.json.Value,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try writeJsonValue(&s, id_value);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    if (data) |payload| {
        try s.objectField("data");
        try s.write(payload);
    }
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn beginOk(s: *std.json.Stringify, id_value: std.json.Value) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try writeJsonValue(s, id_value);
}

fn writeSessionSummary(s: *std.json.Stringify, session: *const PtySession) !void {
    const io_health = session.backend.ioHealth();
    try s.beginObject();
    try s.objectField("id");
    try s.write(session.session_id);
    try s.objectField("session_id");
    try s.write(session.session_id);
    try s.objectField("workspace_id");
    try s.write(session.project_id);
    try s.objectField("workspace_path");
    try s.write(session.project_path);
    try s.objectField("cwd");
    try s.write(session.cwd);
    try s.objectField("label");
    try s.write(session.label);
    try s.objectField("command");
    try s.write(session.command_label);
    try s.objectField("dock_id");
    try s.write(session.dock_id);
    try s.objectField("pane_id");
    try s.write(session.pane_id);
    try s.objectField("pid");
    try s.write(session.child_pid);
    try s.objectField("foreground_process_group");
    if (session.foregroundProcessGroup()) |pgrp| try s.write(pgrp) else try s.write(null);
    try s.objectField("child_process_count");
    try s.write(childProcessCount(session.child_pid));
    try s.objectField("running");
    try s.write(session.running);
    try s.objectField("status");
    try s.write(if (session.running) "running" else "exited");
    try s.objectField("exit_status");
    if (session.exit_status) |value| try s.write(value) else try s.write(null);
    try s.objectField("stream_eof");
    try s.write(session.stream_eof);
    try s.objectField("output_reader_status");
    try s.write(@tagName(io_health.output_reader_status));
    try s.objectField("output_reader_error_code");
    if (io_health.output_reader_error_code) |value| try s.write(value) else try s.write(null);
    try s.objectField("input_writer_status");
    try s.write(@tagName(io_health.input_writer_status));
    try s.objectField("input_writer_error_code");
    if (io_health.input_writer_error_code) |value| try s.write(value) else try s.write(null);
    try s.objectField("cols");
    try s.write(session.cols);
    try s.objectField("rows");
    try s.write(session.rows);
    try s.objectField("created_at_ms");
    try s.write(session.created_at_ms);
    try s.objectField("last_attached_at_ms");
    if (session.last_attached_at_ms) |value| try s.write(value) else try s.write(null);
    try s.objectField("attached_clients");
    try s.write(session.attach_clients.items.len);
    try s.endObject();
}

fn writeChatTurnSummary(s: *std.json.Stringify, turn: *const ChatTurn) !void {
    try s.beginObject();
    try s.objectField("turn_id");
    try s.write(turn.turn_id);
    try s.objectField("workspace_id");
    try s.write(turn.workspace_id);
    try s.objectField("local_thread_id");
    try s.write(turn.local_thread_id);
    try s.objectField("status");
    try s.write(@tagName(turn.status));
    try s.objectField("next_seq");
    try s.write(turn.next_seq);
    try s.objectField("provider_thread_id");
    if (turn.provider_thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("pending_approval");
    try writePendingApproval(s, turn.pending_approval);
    try s.endObject();
}

fn writeChatTurnTail(s: *std.json.Stringify, turn: *const ChatTurn, after_seq: u64) !void {
    try s.beginObject();
    try s.objectField("status");
    try s.write(@tagName(turn.status));
    try s.objectField("events");
    try s.beginArray();
    for (turn.events.items) |event| {
        if (event.seq <= after_seq) continue;
        try s.beginObject();
        try s.objectField("seq");
        try s.write(event.seq);
        try s.objectField("kind");
        try s.write(event.kind);
        try s.objectField("payload_json");
        try s.write(event.payload_json);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("next_seq");
    try s.write(turn.next_seq);
    try s.objectField("provider_thread_id");
    if (turn.provider_thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("active_turn_id");
    if (turn.active_turn_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("result_reply_text");
    if (turn.result_reply_text) |value| try s.write(value) else try s.write(null);
    try s.objectField("error_message");
    if (turn.error_message) |value| try s.write(value) else try s.write(null);
    try s.objectField("pending_approval");
    try writePendingApproval(s, turn.pending_approval);
    try s.endObject();
}

fn chatTailUpperBound(turn: *const ChatTurn, after_seq: u64) usize {
    var total: usize = 4096;
    for (turn.events.items) |event| {
        if (event.seq <= after_seq) continue;
        total = saturatedAdd(total, 96);
        total = saturatedAdd(total, jsonStringUpperBound(event.kind.len));
        total = saturatedAdd(total, jsonStringUpperBound(event.payload_json.len));
    }
    if (turn.provider_thread_id) |value| total = saturatedAdd(total, jsonStringUpperBound(value.len));
    if (turn.active_turn_id) |value| total = saturatedAdd(total, jsonStringUpperBound(value.len));
    if (turn.result_reply_text) |value| total = saturatedAdd(total, jsonStringUpperBound(value.len));
    if (turn.error_message) |value| total = saturatedAdd(total, jsonStringUpperBound(value.len));
    if (turn.pending_approval) |approval| {
        total = saturatedAdd(total, 96);
        total = saturatedAdd(total, jsonStringUpperBound(approval.call_id.len));
        total = saturatedAdd(total, jsonStringUpperBound(approval.title.len));
        total = saturatedAdd(total, jsonStringUpperBound(approval.body.len));
    }
    return total;
}

fn jsonStringUpperBound(byte_len: usize) usize {
    // This is only a cheap allocation guard; the exact serialized length
    // check after writing the response is authoritative for the 8 MiB limit.
    return saturatedAdd(2, byte_len);
}

fn saturatedAdd(left: usize, right: usize) usize {
    return std.math.add(usize, left, right) catch std.math.maxInt(usize);
}

fn writePendingApproval(s: *std.json.Stringify, pending: ?PendingApproval) !void {
    const approval = pending orelse {
        try s.write(null);
        return;
    };
    try s.beginObject();
    try s.objectField("call_id");
    try s.write(approval.call_id);
    try s.objectField("title");
    try s.write(approval.title);
    try s.objectField("body");
    try s.write(approval.body);
    try s.endObject();
}

fn createChatTurnFromParams(allocator: std.mem.Allocator, params: std.json.Value) !*ChatTurn {
    const turn = try allocator.create(ChatTurn);
    errdefer allocator.destroy(turn);
    const image_paths = try jsonStringArray(allocator, params.object.get("image_paths") orelse .null);
    errdefer freeStringArray(allocator, image_paths);
    const provider = parseEnum(harness.Provider, jsonString(params.object.get("provider") orelse .null) orelse return error.InvalidParams) orelse return error.InvalidParams;
    const harness_kind = parseEnum(harness.HarnessKind, jsonString(params.object.get("harness") orelse .null) orelse "local_cli") orelse return error.InvalidParams;
    const request: send_runner.Request = .{
        .provider = provider,
        .harness_kind = harness_kind,
        .project_path = try requiredDupe(allocator, params, "project_path"),
        .prompt = try requiredDupe(allocator, params, "prompt"),
        .image_paths = image_paths,
        .provider_thread_id = try optionalDupe(allocator, params, "provider_thread_id"),
        .thread_title = try requiredDupe(allocator, params, "thread_title"),
        .model_ref = try optionalDupe(allocator, params, "model_ref"),
        .reasoning_effort = if (jsonString(params.object.get("reasoning_effort") orelse .null)) |value| parseEnum(harness.ReasoningEffort, value) else null,
        .opencode_reasoning_variant = try optionalDupe(allocator, params, "opencode_reasoning_variant"),
        .cursor_model_params_json = try optionalDupe(allocator, params, "cursor_model_params_json"),
        .fast_mode = if (jsonBool(params.object.get("fast_mode") orelse .null) orelse false) .on else .off,
        .access_mode = parseAccessMode(jsonString(params.object.get("access_mode") orelse .null)),
        .remote_ssh_host = try optionalDupe(allocator, params, "remote_ssh_host"),
        .remote_cwd = try optionalDupe(allocator, params, "remote_cwd"),
    };
    turn.* = .{
        .allocator = allocator,
        .turn_id = try requiredDupe(allocator, params, "turn_id"),
        .workspace_id = try requiredDupe(allocator, params, "workspace_id"),
        .local_thread_id = try requiredDupe(allocator, params, "local_thread_id"),
        .request = request,
        .owned_image_paths = image_paths,
    };
    return turn;
}

fn chatTurnThread(allocator: std.mem.Allocator, turn: *ChatTurn) void {
    const result = send_runner.run(allocator, turn.request, .{
        .context = turn,
        .on_thread_id = chatSinkThreadId,
        .on_turn_id = chatSinkTurnId,
        .on_stream_delta = chatSinkDelta,
        .on_stream_event = chatSinkEvent,
        .on_failure = chatSinkFailure,
        .on_should_stop = chatSinkShouldStop,
        .on_approval_request = chatSinkApproval,
    });
    lockTurn(turn);
    defer turn.mutex.unlock();
    if (turn.cancel_requested or turn.status == .aborted) {
        turn.worker_done = true;
        return;
    }
    if (result) |value| {
        turn.status = .completed;
        if (turn.provider_thread_id) |old| allocator.free(old);
        turn.provider_thread_id = allocator.dupe(u8, value.provider_thread_id) catch null;
        turn.result_reply_text = allocator.dupe(u8, value.reply_text) catch null;
        turn.appendEvent(allocator, "completed", "{}");
        allocator.free(value.provider_thread_id);
        allocator.free(value.reply_text);
    } else |err| {
        turn.status = if (turn.cancel_requested) .aborted else .failed;
        if (turn.error_message == null) {
            turn.error_message = allocator.dupe(u8, @errorName(err)) catch null;
        }
        const message = turn.error_message orelse @errorName(err);
        turn.appendStringEvent(allocator, if (turn.status == .aborted) "aborted" else "failed", "message", message);
    }
    turn.worker_done = true;
}

fn chatSinkThreadId(context: ?*anyopaque, thread_id: []const u8) void {
    const turn = chatTurnFromContext(context) orelse return;
    const allocator = turn.allocator;
    lockTurn(turn);
    defer turn.mutex.unlock();
    if (turn.provider_thread_id) |old| allocator.free(old);
    turn.provider_thread_id = allocator.dupe(u8, thread_id) catch null;
    turn.appendStringEvent(allocator, "thread_id", "thread_id", thread_id);
}

fn chatSinkTurnId(context: ?*anyopaque, turn_id: []const u8) void {
    const turn = chatTurnFromContext(context) orelse return;
    const allocator = turn.allocator;
    lockTurn(turn);
    defer turn.mutex.unlock();
    if (turn.active_turn_id) |old| allocator.free(old);
    turn.active_turn_id = allocator.dupe(u8, turn_id) catch null;
    turn.appendStringEvent(allocator, "turn_id", "turn_id", turn_id);
}

fn chatSinkDelta(context: ?*anyopaque, delta: []const u8) void {
    const turn = chatTurnFromContext(context) orelse return;
    const allocator = turn.allocator;
    lockTurn(turn);
    defer turn.mutex.unlock();
    turn.appendStringEvent(allocator, "assistant_delta", "text", delta);
}

fn chatSinkEvent(context: ?*anyopaque, event: harness.StreamEvent) void {
    const turn = chatTurnFromContext(context) orelse return;
    const allocator = turn.allocator;
    lockTurn(turn);
    defer turn.mutex.unlock();
    switch (event) {
        .message => |message| {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
            s.beginObject() catch return;
            s.objectField("title") catch return;
            s.write(message.title) catch return;
            s.objectField("body") catch return;
            s.write(message.body) catch return;
            s.endObject() catch return;
            const payload = writer.toOwnedSlice() catch return;
            defer allocator.free(payload);
            turn.appendEvent(allocator, "message", payload);
        },
        .tool_call => |tool_call| {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
            s.beginObject() catch return;
            s.objectField("call_id") catch return;
            s.write(tool_call.call_id) catch return;
            s.objectField("title") catch return;
            s.write(tool_call.title) catch return;
            if (tool_call.kind) |kind| {
                s.objectField("kind") catch return;
                s.write(@tagName(kind)) catch return;
            }
            if (tool_call.status) |status| {
                s.objectField("status") catch return;
                s.write(@tagName(status)) catch return;
            }
            inline for (.{ "input", "output", "error_text", "locations", "raw" }) |field_name| {
                const value = @field(tool_call, field_name);
                if (value) |text| {
                    s.objectField(field_name) catch return;
                    s.write(text) catch return;
                }
            }
            s.endObject() catch return;
            const payload = writer.toOwnedSlice() catch return;
            defer allocator.free(payload);
            turn.appendEvent(allocator, "tool_call", payload);
        },
        .diff => |diff| {
            const payload = chatDiffPayloadAlloc(allocator, diff.files, diff.scope) catch return;
            defer allocator.free(payload);
            turn.appendEvent(allocator, "diff", payload);
        },
    }
}

fn chatDiffPayloadAlloc(
    allocator: std.mem.Allocator,
    files: []const harness.StreamDiffFile,
    scope: harness.StreamDiffScope,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("scope");
    try s.write(@tagName(scope));
    try s.objectField("files");
    try s.beginArray();
    for (files) |file| {
        try s.beginObject();
        try s.objectField("path");
        try s.write(file.path);
        try s.objectField("additions");
        try s.write(file.additions);
        try s.objectField("deletions");
        try s.write(file.deletions);
        if (file.patch) |patch| {
            try s.objectField("patch");
            try s.write(patch);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return writer.toOwnedSlice();
}

fn chatSinkFailure(context: ?*anyopaque, message: []const u8) void {
    const turn = chatTurnFromContext(context) orelse return;
    const allocator = turn.allocator;
    lockTurn(turn);
    defer turn.mutex.unlock();
    if (turn.error_message) |old| allocator.free(old);
    turn.error_message = allocator.dupe(u8, message) catch null;
}

fn chatSinkShouldStop(context: ?*anyopaque) bool {
    const turn = chatTurnFromContext(context) orelse return true;
    lockTurn(turn);
    defer turn.mutex.unlock();
    return turn.cancel_requested or turn.status == .aborted;
}

fn chatSinkApproval(context: ?*anyopaque, request: harness.ApprovalRequest) harness.ApprovalDecision {
    const turn = chatTurnFromContext(context) orelse return .deny;
    const allocator = turn.allocator;
    lockTurn(turn);
    if (turn.pending_approval) |*old| {
        old.deinit(allocator);
        turn.pending_approval = null;
    }
    const call_id = allocator.dupe(u8, request.call_id) catch {
        turn.mutex.unlock();
        return .deny;
    };
    const title = allocator.dupe(u8, request.title) catch {
        allocator.free(call_id);
        turn.mutex.unlock();
        return .deny;
    };
    const body = allocator.dupe(u8, request.body) catch {
        allocator.free(call_id);
        allocator.free(title);
        turn.mutex.unlock();
        return .deny;
    };
    turn.pending_approval = .{ .call_id = call_id, .title = title, .body = body };
    turn.status = .waiting_approval;
    turn.approval_decision = null;
    turn.appendStringEvent(allocator, "approval_requested", "call_id", request.call_id);
    turn.mutex.unlock();
    while (true) {
        sleepMs(20);
        lockTurn(turn);
        if (turn.cancel_requested) {
            turn.mutex.unlock();
            return .deny;
        }
        if (turn.approval_decision) |decision| {
            turn.status = .running;
            if (turn.pending_approval) |*approval| {
                approval.deinit(allocator);
                turn.pending_approval = null;
            }
            turn.mutex.unlock();
            return if (decision == .approve) .approve else .deny;
        }
        turn.mutex.unlock();
    }
}

fn chatTurnFromContext(context: ?*anyopaque) ?*ChatTurn {
    const ptr = context orelse return null;
    if (@intFromPtr(ptr) % @alignOf(ChatTurn) != 0) {
        log.warn("daemon chat callback received misaligned context ptr=0x{x}", .{@intFromPtr(ptr)});
        return null;
    }
    return @ptrCast(@alignCast(ptr));
}

fn touchAttachFromParams(session: *PtySession, params: std.json.Value) void {
    if (params != .object) return;
    const attach_id = jsonString(params.object.get("attach_id") orelse .null) orelse return;
    _ = session.touchAttach(attach_id);
}

fn writeJsonValue(s: *std.json.Stringify, value: std.json.Value) !void {
    switch (value) {
        .integer => |v| try s.write(v),
        .float => |v| try s.write(v),
        .number_string => |v| try s.write(v),
        .string => |v| try s.write(v),
        .bool => |v| try s.write(v),
        .null => try s.write(null),
        else => try s.write(null),
    }
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u32, text, 10) catch null,
        else => null,
    };
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn jsonUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(usize, text, 10) catch null,
        else => null,
    };
}

fn jsonU16(value: std.json.Value) ?u16 {
    const value_u32 = jsonU32(value) orelse return null;
    return if (value_u32 <= std.math.maxInt(u16)) @intCast(value_u32) else null;
}

fn jsonBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

fn parseEnum(comptime T: type, text: []const u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, text)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseAccessMode(text: ?[]const u8) send_runner.AccessMode {
    const value = text orelse return .full_access;
    if (std.mem.eql(u8, value, "supervised")) return .supervised;
    return .full_access;
}

fn requiredDupe(allocator: std.mem.Allocator, params: std.json.Value, field: []const u8) ![]u8 {
    const text = jsonString(params.object.get(field) orelse .null) orelse return error.InvalidParams;
    return try allocator.dupe(u8, text);
}

fn optionalDupe(allocator: std.mem.Allocator, params: std.json.Value, field: []const u8) !?[]u8 {
    const text = jsonString(params.object.get(field) orelse .null) orelse return null;
    return try allocator.dupe(u8, text);
}

fn jsonStringArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        const text = jsonString(item) orelse continue;
        try out.append(allocator, try allocator.dupe(u8, text));
    }
    return try out.toOwnedSlice(allocator);
}

fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn commandForOptions(allocator: std.mem.Allocator, args: []const []const u8) ![][:0]u8 {
    if (builtin.os.tag == .windows) return windows_conpty.commandForOptions(allocator, args);
    if (args.len > 0) return dupeCommand(allocator, args);
    return dupeCommand(allocator, &.{ defaultInteractiveShell(), "-i" });
}

fn defaultInteractiveShell() []const u8 {
    if (std.c.getenv("SHELL")) |shell_ptr| {
        const shell = std.mem.span(shell_ptr);
        if (shell.len > 0) return shell;
    }
    return switch (builtin.os.tag) {
        .macos => "/bin/zsh",
        else => "/bin/bash",
    };
}

fn childTermEnvValue() [:0]const u8 {
    return switch (builtin.os.tag) {
        // macOS ships xterm-256color, but not Ghostty's terminfo entry. zsh's
        // line editor relies on terminfo for clear-to-end-line while drawing
        // syntax highlighting and autosuggestions.
        .macos => "xterm-256color",
        else => "xterm-ghostty",
    };
}

fn childLocaleEnvValue() [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "en_US.UTF-8",
        else => "C.UTF-8",
    };
}

fn dupeCommand(allocator: std.mem.Allocator, args: []const []const u8) ![][:0]u8 {
    const command = try allocator.alloc([:0]u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    for (args, 0..) |arg, index| {
        command[index] = if (index == 0)
            try resolveExecutableArg(allocator, arg)
        else
            try allocator.dupeZ(u8, arg);
        initialized += 1;
    }
    return command;
}

fn resolveExecutableArg(allocator: std.mem.Allocator, arg: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, arg, '/') != null) return allocator.dupeZ(u8, arg);
    const path_ptr = std.c.getenv("PATH") orelse return allocator.dupeZ(u8, arg);
    const path_value = std.mem.span(path_ptr);
    var iterator = std.mem.splitScalar(u8, path_value, ':');
    while (iterator.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, arg });
        defer allocator.free(candidate);
        const candidate_z = try allocator.dupeZ(u8, candidate);
        if (std.c.access(candidate_z.ptr, std.c.X_OK) == 0) return candidate_z;
        allocator.free(candidate_z);
    }
    return allocator.dupeZ(u8, arg);
}

fn freeCommand(allocator: std.mem.Allocator, command: []const [:0]u8) void {
    for (command) |arg| allocator.free(arg);
    allocator.free(command);
}

fn commandLabel(allocator: std.mem.Allocator, command: []const [:0]u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    for (command, 0..) |arg, index| {
        if (index > 0) try writer.writer.writeByte(' ');
        try writer.writer.writeAll(arg);
    }
    return try writer.toOwnedSlice();
}

fn tailLines(allocator: std.mem.Allocator, bytes: []const u8, lines: u32) ![]u8 {
    if (bytes.len == 0 or lines == 0) return allocator.dupe(u8, "");
    var remaining = lines;
    var start = bytes.len;
    while (start > 0 and remaining > 0) {
        start -= 1;
        if (bytes[start] == '\n') remaining -= 1;
    }
    if (start < bytes.len and bytes[start] == '\n') start += 1;
    return allocator.dupe(u8, bytes[start..]);
}

const ByteRange = struct {
    start: usize,
    end: usize,
};

fn bytesRangeFromOffset(bytes: []const u8, offset: usize, max_bytes: ?usize) ByteRange {
    var start = @min(offset, bytes.len);
    if (max_bytes) |limit| {
        if (limit > 0 and bytes.len - start > limit) start = bytes.len - limit;
    }
    return .{ .start = start, .end = bytes.len };
}

fn bytesRangeForTailLines(bytes: []const u8, lines: u32, max_bytes: ?usize) ByteRange {
    if (bytes.len == 0 or lines == 0) return .{ .start = bytes.len, .end = bytes.len };
    var remaining = lines;
    var start = bytes.len;
    while (start > 0 and remaining > 0) {
        start -= 1;
        if (bytes[start] == '\n') remaining -= 1;
    }
    if (start < bytes.len and bytes[start] == '\n') start += 1;
    if (max_bytes) |limit| {
        if (limit > 0 and bytes.len - start > limit) start = bytes.len - limit;
    }
    return .{ .start = start, .end = bytes.len };
}

fn outputWindowRange(session: *const PtySession, offset: ?u64, lines: u32, max_bytes: ?usize) ByteRange {
    if (offset) |cursor| {
        return bytesRangeFromOffset(
            session.output_ring.items,
            session.ringIndexForOffset(cursor),
            max_bytes,
        );
    }
    return bytesRangeForTailLines(session.output_ring.items, lines, max_bytes);
}

fn bytesFromOffset(allocator: std.mem.Allocator, bytes: []const u8, offset: usize) ![]u8 {
    const start = @min(offset, bytes.len);
    return allocator.dupe(u8, bytes[start..]);
}

fn childProcessCount(pid: usize) ?usize {
    if (builtin.os.tag != .linux or pid == 0) return null;
    return linuxChildProcessCount(@intCast(pid));
}

fn linuxChildProcessCount(pid: std.posix.pid_t) ?usize {
    if (builtin.os.tag != .linux or pid <= 0) return null;

    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/task/{d}/children", .{ pid, pid }) catch return null;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.c.close(fd);

    var buffer: [4096]u8 = undefined;
    const read_raw = std.c.read(fd, &buffer, buffer.len);
    if (read_raw <= 0) return 0;

    var count: usize = 0;
    var in_number = false;
    for (buffer[0..@intCast(read_raw)]) |byte| {
        if (byte >= '0' and byte <= '9') {
            if (!in_number) {
                count += 1;
                in_number = true;
            }
        } else {
            in_number = false;
        }
    }
    return count;
}

fn signalDescendantProcessGroups(
    allocator: std.mem.Allocator,
    root_pid: std.posix.pid_t,
    foreground_process_group: ?std.posix.pid_t,
    signal: std.c.SIG,
) usize {
    if (builtin.os.tag != .linux or root_pid <= 0) return 0;

    var processes: std.ArrayList(std.posix.pid_t) = .empty;
    defer processes.deinit(allocator);
    var process_groups: std.ArrayList(std.posix.pid_t) = .empty;
    defer process_groups.deinit(allocator);

    appendProcessChildren(allocator, &processes, root_pid) catch return 0;
    var index: usize = 0;
    while (index < processes.items.len) : (index += 1) {
        const pid = processes.items[index];
        appendProcessChildren(allocator, &processes, pid) catch {};
        const pgrp = processGroupForPid(pid) orelse continue;
        if (pgrp <= 0 or pgrp == root_pid) continue;
        if (foreground_process_group) |foreground| {
            if (pgrp == foreground) continue;
        }
        if (containsPid(process_groups.items, pgrp)) continue;
        process_groups.append(allocator, pgrp) catch continue;
    }

    var signaled: usize = 0;
    for (process_groups.items) |pgrp| {
        if (std.c.kill(-pgrp, signal) == 0) signaled += 1;
    }
    return signaled;
}

fn appendProcessChildren(allocator: std.mem.Allocator, processes: *std.ArrayList(std.posix.pid_t), pid: std.posix.pid_t) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/task/{d}/children", .{ pid, pid });
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.c.close(fd);

    var buffer: [4096]u8 = undefined;
    const read_raw = std.c.read(fd, &buffer, buffer.len);
    if (read_raw <= 0) return;

    var iterator = std.mem.tokenizeAny(u8, buffer[0..@intCast(read_raw)], " \t\r\n");
    while (iterator.next()) |token| {
        const child_pid = std.fmt.parseInt(std.posix.pid_t, token, 10) catch continue;
        if (child_pid > 0 and !containsPid(processes.items, child_pid)) try processes.append(allocator, child_pid);
    }
}

fn processGroupForPid(pid: std.posix.pid_t) ?std.posix.pid_t {
    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.c.close(fd);

    var buffer: [1024]u8 = undefined;
    const read_raw = std.c.read(fd, &buffer, buffer.len);
    if (read_raw <= 0) return null;
    const stat = buffer[0..@intCast(read_raw)];
    const comm_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    if (comm_end + 2 >= stat.len) return null;

    var fields = std.mem.tokenizeScalar(u8, stat[comm_end + 2 ..], ' ');
    _ = fields.next() orelse return null; // state
    _ = fields.next() orelse return null; // parent pid
    const pgrp_text = fields.next() orelse return null;
    return std.fmt.parseInt(std.posix.pid_t, pgrp_text, 10) catch null;
}

fn containsPid(items: []const std.posix.pid_t, pid: std.posix.pid_t) bool {
    for (items) |item| {
        if (item == pid) return true;
    }
    return false;
}

pub fn nowMs() i64 {
    return platform_runtime.unixTimestampMs();
}

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const current = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (current < 0) return error.FcntlFailed;
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.c.F.SETFL, current | @as(c_int, @intCast(nonblock))) < 0) return error.FcntlFailed;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written_raw = std.c.write(fd, remaining.ptr, remaining.len);
        if (written_raw < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return error.WriteFailed;
        }
        const written: usize = @intCast(written_raw);
        if (written == 0) return error.WriteFailed;
        remaining = remaining[written..];
    }
}

fn writePidFile(path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(threaded.io());
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}\n", .{platform_runtime.processId()});
    var write_buffer: [64]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn deletePidFileIfOwned(path: []const u8) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(64)) catch return;
    defer std.heap.page_allocator.free(bytes);
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    const pid = std.fmt.parseInt(usize, text, 10) catch return;
    if (pid != platform_runtime.processId()) return;
    deleteFilePath(io, path);
}

fn deleteSocketPath(path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    var threaded = std.Io.Threaded.init_single_threaded;
    deleteFilePath(threaded.io(), path);
}

fn deleteFilePath(io: std.Io, path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

fn appendSafeComponent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var previous_was_underscore = false;
    for (value) |byte| {
        const safe = isSafeIdByte(byte);
        const next = if (safe) byte else '_';
        if (next == '_') {
            if (previous_was_underscore) continue;
            previous_was_underscore = true;
        } else {
            previous_was_underscore = false;
        }
        try out.append(allocator, next);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        out.shrinkRetainingCapacity(out.items.len - 1);
    }
}

fn isSafeIdByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '_' or
        byte == '.';
}

fn testSessionCreateResponseWasCreated(allocator: std.mem.Allocator, response: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    return jsonBool(result.object.get("created") orelse .null) orelse error.InvalidResponse;
}

fn observeTestTerminalProcess(
    daemon: *Daemon,
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    session_id: []const u8,
    process_identity: u32,
    command: []const u8,
    cwd: []const u8,
) ![]u8 {
    const observed = try daemon.registry.observeTerminalProcess(allocator, workspace_id, .{
        .process_identity = process_identity,
        .session_id = session_id,
        .command = command,
        .cwd = cwd,
        .pid = 42,
        .process_group = 42,
        .started_at_ms = 1,
        .observed_at_ms = 1,
        .dock_id = 0,
        .pane_id = null,
        .owner_kind = "terminal",
        .owner_title = session_id,
        .provider = null,
    }, .{});
    return allocator.dupe(u8, observed.process_id);
}

test "session create dual-writes a tracked terminal process" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const before_revision = daemon.registry.registry_revision;
    const process_id = try observeTestTerminalProcess(
        &daemon,
        allocator,
        "test-dual-write-workspace",
        "test-dual-write-session",
        101,
        "/bin/cat",
        "/tmp/test-dual-write",
    );
    defer allocator.free(process_id);

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.list","params":{"workspace":{"workspace_id":"test-dual-write-workspace"}}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const process = result.get("processes").?.array.items[0].object;
    try std.testing.expectEqual(@as(usize, 1), result.get("processes").?.array.items.len);
    try std.testing.expect(std.mem.startsWith(u8, process.get("id").?.string, "term:"));
    try std.testing.expectEqualStrings("/bin/cat", process.get("command").?.string);
    try std.testing.expectEqualStrings("/tmp/test-dual-write", process.get("cwd").?.string);
    try std.testing.expectEqualStrings(process_id, process.get("id").?.string);
    try std.testing.expect(daemon.registry.registry_revision > before_revision);
}

test "session exit records exactly one outcome" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const completed_id = try observeTestTerminalProcess(&daemon, allocator, "test-outcomes", "completed-session", 201, "/bin/true", ".");
    defer allocator.free(completed_id);
    const failed_id = try observeTestTerminalProcess(&daemon, allocator, "test-outcomes", "failed-session", 202, "/bin/false", ".");
    defer allocator.free(failed_id);
    const cancelled_id = try observeTestTerminalProcess(&daemon, allocator, "test-outcomes", "cancelled-session", 203, "/bin/cat", ".");
    defer allocator.free(cancelled_id);

    const finished_at_ms = nowMs();
    try std.testing.expect(try daemon.registry.finishTerminalProcess(allocator, "test-outcomes", "completed-session", .{ .exit_code = 0 }, finished_at_ms));
    try std.testing.expect(!try daemon.registry.finishTerminalProcess(allocator, "test-outcomes", "completed-session", .{ .exit_code = 0 }, finished_at_ms + 1));
    try std.testing.expect(try daemon.registry.finishTerminalProcess(allocator, "test-outcomes", "failed-session", .{ .exit_code = 2 }, finished_at_ms));
    try std.testing.expect(try daemon.registry.finishTerminalProcess(allocator, "test-outcomes", "cancelled-session", .{ .cancellation_reason = "session.kill" }, finished_at_ms));

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.list","params":{"workspace":{"workspace_id":"test-outcomes"},"include_outcomes":true}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const outcomes = parsed.value.object.get("result").?.object.get("outcomes").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), outcomes.len);
    var completed_count: usize = 0;
    var failed_count: usize = 0;
    var cancelled_count: usize = 0;
    for (outcomes) |outcome| {
        const status = outcome.object.get("status").?.string;
        if (std.mem.eql(u8, status, "completed")) completed_count += 1;
        if (std.mem.eql(u8, status, "failed")) failed_count += 1;
        if (std.mem.eql(u8, status, "cancelled")) cancelled_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), completed_count);
    try std.testing.expectEqual(@as(usize, 1), failed_count);
    try std.testing.expectEqual(@as(usize, 1), cancelled_count);
}

test "duplicate create replacement advances the tracked generation" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const first_id = try observeTestTerminalProcess(&daemon, allocator, "test-replacement", "replacement-session", 301, "/bin/cat", ".");
    defer allocator.free(first_id);
    const first = daemon.registry.terminalProcessActiveForSession("test-replacement", "replacement-session").?;
    const first_generation = first.generation;
    try std.testing.expect(try daemon.registry.finishTerminalProcess(allocator, "test-replacement", "replacement-session", .{ .exit_code = 0 }, nowMs()));

    const second_id = try observeTestTerminalProcess(&daemon, allocator, "test-replacement", "replacement-session", 302, "/bin/cat", ".");
    defer allocator.free(second_id);
    const second = daemon.registry.terminalProcessActiveForSession("test-replacement", "replacement-session").?;
    try std.testing.expect(second.generation > first_generation);
    try std.testing.expect(!std.mem.eql(u8, first_id, second_id));

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"process.list","params":{"workspace":{"workspace_id":"test-replacement"},"include_outcomes":true}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 1), result.get("processes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.get("outcomes").?.array.items.len);
}

test "process.wait is a bounded immediate check" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const process_id = try observeTestTerminalProcess(&daemon, allocator, "test-wait", "wait-session", 401, "/bin/cat", ".");
    defer allocator.free(process_id);
    const running_revision = daemon.registry.registry_revision;
    const running_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"process.wait\",\"params\":{{\"workspace\":{{\"workspace_id\":\"test-wait\"}},\"process_id\":\"{s}\",\"after_registry_revision\":{d},\"timeout_ms\":20000}}}}",
        .{ process_id, running_revision },
    );
    defer allocator.free(running_request);
    const running_response = try daemon.handleRequest(running_request);
    defer allocator.free(running_response);
    var running_parsed = try std.json.parseFromSlice(std.json.Value, allocator, running_response, .{});
    defer running_parsed.deinit();
    const running_result = running_parsed.value.object.get("result").?.object;
    try std.testing.expect(running_result.get("timed_out").?.bool);
    try std.testing.expect(running_result.get("terminal_state").? == .null);
    try std.testing.expect(!running_result.get("changed").?.bool);

    try std.testing.expect(try daemon.registry.finishTerminalProcess(allocator, "test-wait", "wait-session", .{ .exit_code = 0 }, nowMs()));
    const finished_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"process.wait\",\"params\":{{\"workspace\":{{\"workspace_id\":\"test-wait\"}},\"process_id\":\"{s}\"}}}}",
        .{process_id},
    );
    defer allocator.free(finished_request);
    const finished_response = try daemon.handleRequest(finished_request);
    defer allocator.free(finished_response);
    var finished_parsed = try std.json.parseFromSlice(std.json.Value, allocator, finished_response, .{});
    defer finished_parsed.deinit();
    const finished_result = finished_parsed.value.object.get("result").?.object;
    try std.testing.expect(!finished_result.get("timed_out").?.bool);
    try std.testing.expectEqualStrings("completed", finished_result.get("terminal_state").?.string);
    try std.testing.expect(finished_result.get("outcome").? == .object);
    try std.testing.expect(finished_result.get("changed").?.bool);

    const unknown_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":6,"method":"process.wait","params":{"workspace":{"workspace_id":"test-wait"},"process_id":"term:missing:1"}}
    );
    defer allocator.free(unknown_response);
    var unknown_parsed = try std.json.parseFromSlice(std.json.Value, allocator, unknown_response, .{});
    defer unknown_parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        unknown_parsed.value.object.get("error").?.object.get("code").?.string,
    );
}

test "process.logs resolves opaque id to session tail" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    _ = try daemon.registry.ensureWorkspace(allocator, "test-logs");

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":7,"method":"process.logs","params":{"workspace":{"workspace_id":"test-logs"},"process_id":"term:missing:1"}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const error_value = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_RESOURCE_NOT_FOUND, error_value.get("code").?.string);
    try std.testing.expectEqualStrings("process logs unavailable", error_value.get("message").?.string);
}

test "lease acquire returns conflict data with options" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "lease-conflict");

    const first_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-conflict"},"owner":"owner-a","command":"build","resources":["build"]}}
    );
    defer allocator.free(first_response);
    const second_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-conflict"},"owner":"owner-b","command":"build","resources":["build"]}}
    );
    defer allocator.free(second_response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, second_response, .{});
    defer parsed.deinit();
    const error_value = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_CONFLICT, error_value.get("code").?.string);
    const data = error_value.get("data").?.object;
    const conflicts = data.get("conflicts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqualStrings("owner-a", conflicts[0].object.get("owner").?.string);
    try std.testing.expectEqualStrings("workspace.releaseLease (owner only)", conflicts[0].object.get("cancel_method").?.string);
    const options = data.get("options").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), options.len);
    try std.testing.expectEqualStrings("wait", options[0].string);
    try std.testing.expectEqualStrings("cancel_existing", options[1].string);
    try std.testing.expectEqualStrings("run_anyway", options[2].string);
    try std.testing.expectEqualStrings("open_owner", options[3].string);
}

test "forced lease acquire keeps both leases and queues one notification" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "lease-forced");

    const first_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-forced"},"owner":"owner-a","command":"build","resources":["build"]}}
    );
    defer allocator.free(first_response);
    const forced_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-forced"},"owner":"owner-b","command":"build","resources":["build"],"force":true}}
    );
    defer allocator.free(forced_response);
    var forced_parsed = try std.json.parseFromSlice(std.json.Value, allocator, forced_response, .{});
    defer forced_parsed.deinit();
    const forced_result = forced_parsed.value.object.get("result").?.object;
    try std.testing.expect(forced_result.get("acquired").?.bool);
    try std.testing.expect(forced_result.get("forced").?.bool);

    const listed_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"process.list","params":{"workspace":{"workspace_id":"lease-forced"},"include_notifications":true}}
    );
    defer allocator.free(listed_response);
    var listed = try std.json.parseFromSlice(std.json.Value, allocator, listed_response, .{});
    defer listed.deinit();
    const result = listed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 2), result.get("leases").?.array.items.len);
    const notifications = result.get("notifications").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), notifications.len);
    try std.testing.expectEqualStrings("Conflicting command started", notifications[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("owner-a", notifications[0].object.get("owner_session_id").?.string);
}

test "same-owner acquire renews the same lease id" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "lease-renew-acquire");

    const first_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-renew-acquire"},"owner":"owner-a","command":"build","resources":["build"],"ttl_ms":1000}}
    );
    defer allocator.free(first_response);
    var first = try std.json.parseFromSlice(std.json.Value, allocator, first_response, .{});
    defer first.deinit();
    const first_result = first.value.object.get("result").?.object;
    const first_id = first_result.get("lease_id").?.string;
    const first_expiry = first_result.get("expires_at_ms").?.integer;
    const second_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-renew-acquire"},"owner":"owner-a","command":"build","resources":["build"],"ttl_ms":3600000}}
    );
    defer allocator.free(second_response);
    var second = try std.json.parseFromSlice(std.json.Value, allocator, second_response, .{});
    defer second.deinit();
    const second_result = second.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(first_id, second_result.get("lease_id").?.string);
    try std.testing.expect(second_result.get("expires_at_ms").?.integer > first_expiry);
    try std.testing.expect(second_result.get("renewed").?.bool);
}

test "lease renew by id is owner-checked" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "lease-renew-id");

    const acquired_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-renew-id"},"owner":"owner-a","command":"build","resources":["build"]}}
    );
    defer allocator.free(acquired_response);
    var acquired = try std.json.parseFromSlice(std.json.Value, allocator, acquired_response, .{});
    defer acquired.deinit();
    const lease_id = acquired.value.object.get("result").?.object.get("lease_id").?.string;
    const wrong_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"lease.renew\",\"params\":{{\"workspace\":{{\"workspace_id\":\"lease-renew-id\"}},\"owner\":\"owner-b\",\"lease_id\":\"{s}\"}}}}",
        .{lease_id},
    );
    defer allocator.free(wrong_request);
    const wrong_response = try daemon.handleRequest(wrong_request);
    defer allocator.free(wrong_response);
    var wrong = try std.json.parseFromSlice(std.json.Value, allocator, wrong_response, .{});
    defer wrong.deinit();
    try std.testing.expectEqualStrings(headless.registry.ERR_CONFLICT, wrong.value.object.get("error").?.object.get("code").?.string);

    const right_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"lease.renew\",\"params\":{{\"workspace\":{{\"workspace_id\":\"lease-renew-id\"}},\"owner\":\"owner-a\",\"lease_id\":\"{s}\",\"ttl_ms\":5000}}}}",
        .{lease_id},
    );
    defer allocator.free(right_request);
    const right_response = try daemon.handleRequest(right_request);
    defer allocator.free(right_response);
    var right = try std.json.parseFromSlice(std.json.Value, allocator, right_response, .{});
    defer right.deinit();
    const right_result = right.value.object.get("result").?.object;
    try std.testing.expect(right_result.get("renewed").?.bool);
    try std.testing.expectEqualStrings(lease_id, right_result.get("lease_id").?.string);

    const unknown_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"lease.renew","params":{"workspace":{"workspace_id":"lease-renew-id"},"owner":"owner-a","lease_id":"lease:missing"}}
    );
    defer allocator.free(unknown_response);
    var unknown = try std.json.parseFromSlice(std.json.Value, allocator, unknown_response, .{});
    defer unknown.deinit();
    try std.testing.expectEqualStrings(headless.registry.ERR_RESOURCE_NOT_FOUND, unknown.value.object.get("error").?.object.get("code").?.string);
}

test "lease release is owner-only and idempotent" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "lease-release");

    const acquired_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"lease.acquire","params":{"workspace":{"workspace_id":"lease-release"},"owner":"owner-a","command":"build","resources":["build"]}}
    );
    defer allocator.free(acquired_response);
    var acquired = try std.json.parseFromSlice(std.json.Value, allocator, acquired_response, .{});
    defer acquired.deinit();
    const lease_id = acquired.value.object.get("result").?.object.get("lease_id").?.string;
    const wrong_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"lease.release\",\"params\":{{\"workspace\":{{\"workspace_id\":\"lease-release\"}},\"owner\":\"owner-b\",\"lease_id\":\"{s}\"}}}}",
        .{lease_id},
    );
    defer allocator.free(wrong_request);
    const wrong_response = try daemon.handleRequest(wrong_request);
    defer allocator.free(wrong_response);
    var wrong = try std.json.parseFromSlice(std.json.Value, allocator, wrong_response, .{});
    defer wrong.deinit();
    const wrong_result = wrong.value.object.get("result").?.object;
    try std.testing.expect(!wrong_result.get("released").?.bool);
    try std.testing.expectEqual(@as(i64, 0), wrong_result.get("released_count").?.integer);

    const listed_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"process.list","params":{"workspace":{"workspace_id":"lease-release"}}}
    );
    defer allocator.free(listed_response);
    var listed = try std.json.parseFromSlice(std.json.Value, allocator, listed_response, .{});
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.value.object.get("result").?.object.get("leases").?.array.items.len);

    const right_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"lease.release\",\"params\":{{\"workspace\":{{\"workspace_id\":\"lease-release\"}},\"owner\":\"owner-a\",\"lease_id\":\"{s}\"}}}}",
        .{lease_id},
    );
    defer allocator.free(right_request);
    const right_response = try daemon.handleRequest(right_request);
    defer allocator.free(right_response);
    var right = try std.json.parseFromSlice(std.json.Value, allocator, right_response, .{});
    defer right.deinit();
    const right_result = right.value.object.get("result").?.object;
    try std.testing.expect(right_result.get("released").?.bool);
    try std.testing.expectEqual(@as(i64, 1), right_result.get("released_count").?.integer);
}

test "notifications pull honors cursor and limit" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "notification-cursor");

    const first_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"lease.acquire","params":{"workspace":{"workspace_id":"notification-cursor"},"owner":"owner-a","command":"build","resources":["build"]}}
    );
    defer allocator.free(first_response);
    const second_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"lease.acquire","params":{"workspace":{"workspace_id":"notification-cursor"},"owner":"owner-b","command":"deps","resources":["deps"]}}
    );
    defer allocator.free(second_response);
    const first_force_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"lease.acquire","params":{"workspace":{"workspace_id":"notification-cursor"},"owner":"owner-c","command":"build","resources":["build"],"force":true}}
    );
    defer allocator.free(first_force_response);
    const second_force_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"lease.acquire","params":{"workspace":{"workspace_id":"notification-cursor"},"owner":"owner-c","command":"deps","resources":["deps"],"force":true}}
    );
    defer allocator.free(second_force_response);

    const first_pull_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":5,"method":"daemon.notifications","params":{"workspace":{"workspace_id":"notification-cursor"},"after_seq":0,"limit":1}}
    );
    defer allocator.free(first_pull_response);
    var first_pull = try std.json.parseFromSlice(std.json.Value, allocator, first_pull_response, .{});
    defer first_pull.deinit();
    const first_result = first_pull.value.object.get("result").?.object;
    const first_notifications = first_result.get("notifications").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), first_notifications.len);
    try std.testing.expectEqualStrings("owner-a", first_notifications[0].object.get("owner_session_id").?.string);
    try std.testing.expectEqual(@as(i64, 3), first_result.get("next_notification_seq").?.integer);

    const second_pull_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":6,"method":"daemon.notifications","params":{"workspace":{"workspace_id":"notification-cursor"},"after_seq":1,"limit":1}}
    );
    defer allocator.free(second_pull_response);
    var second_pull = try std.json.parseFromSlice(std.json.Value, allocator, second_pull_response, .{});
    defer second_pull.deinit();
    const second_notifications = second_pull.value.object.get("result").?.object.get("notifications").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), second_notifications.len);
    try std.testing.expectEqualStrings("owner-b", second_notifications[0].object.get("owner_session_id").?.string);

    const unaffected_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":7,"method":"daemon.notifications","params":{"workspace":{"workspace_id":"notification-cursor"},"owner_session_id":"owner-z","after_seq":0}}
    );
    defer allocator.free(unaffected_response);
    var unaffected = try std.json.parseFromSlice(std.json.Value, allocator, unaffected_response, .{});
    defer unaffected.deinit();
    try std.testing.expectEqual(@as(usize, 0), unaffected.value.object.get("result").?.object.get("notifications").?.array.items.len);
}

test "session create reuses running session and replaces stopped session" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"id":"test-reuse-replace","cwd":".","command":["/bin/cat"],"pref_path":"/tmp"}}
    ;

    const initial_response = try daemon.handleRequest(request);
    defer allocator.free(initial_response);
    try std.testing.expect(try testSessionCreateResponseWasCreated(allocator, initial_response));
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    const initial = daemon.sessions.items[0];
    const initial_pid = initial.child_pid;

    // Stream EOF is diagnostic state, not evidence that the child exited.
    initial.stream_eof = true;
    try std.testing.expect(!initial.captureExitStatus());
    try std.testing.expect(initial.running);
    initial.stream_eof = false;

    const attach_id = try initial.attach(allocator, "test-client");
    defer allocator.free(attach_id);
    try std.testing.expectEqual(@as(usize, 1), initial.attach_clients.items.len);

    const reused_response = try daemon.handleRequest(request);
    defer allocator.free(reused_response);
    try std.testing.expect(!try testSessionCreateResponseWasCreated(allocator, reused_response));
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    try std.testing.expectEqual(initial_pid, daemon.sessions.items[0].child_pid);
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items[0].attach_clients.items.len);

    try std.testing.expect(initial.terminate());
    var attempts: usize = 0;
    while (attempts < 100 and initial.running) : (attempts += 1) {
        try initial.poll(allocator);
        if (initial.running) try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(!initial.running);

    const replacement_response = try daemon.handleRequest(request);
    defer allocator.free(replacement_response);
    try std.testing.expect(try testSessionCreateResponseWasCreated(allocator, replacement_response));
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    try std.testing.expect(daemon.sessions.items[0].running);
    try std.testing.expectEqual(@as(usize, 0), daemon.sessions.items[0].attach_clients.items.len);
}

test "daemon kill response retains the session until termination is observed" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const create_request =
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"id":"test-kill-confirmation","cwd":".","command":["/bin/cat"],"pref_path":"/tmp"}}
    ;
    const create_response = try daemon.handleRequest(create_request);
    defer allocator.free(create_response);
    try std.testing.expect(try testSessionCreateResponseWasCreated(allocator, create_response));
    const session = daemon.sessions.items[0];
    const child_pid = session.backend.child_pid;
    const master_fd = session.backend.master_fd;
    defer session.backend.child_pid = child_pid;
    defer session.backend.master_fd = master_fd;

    session.backend.child_pid = std.math.maxInt(std.posix.pid_t);
    session.backend.master_fd = -1;
    const unsignaled_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"session.kill","params":{"id":"test-kill-confirmation"}}
    );
    defer allocator.free(unsignaled_response);
    var unsignaled = try std.json.parseFromSlice(std.json.Value, allocator, unsignaled_response, .{});
    defer unsignaled.deinit();
    const unsignaled_result = unsignaled.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(unsignaled_result.get("accepted") orelse .null).?);
    try std.testing.expect(!jsonBool(unsignaled_result.get("signaled") orelse .null).?);
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    try std.testing.expect(session.running);

    session.backend.child_pid = child_pid;
    session.backend.master_fd = master_fd;
    const signaled_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"session.kill","params":{"id":"test-kill-confirmation"}}
    );
    defer allocator.free(signaled_response);
    var signaled = try std.json.parseFromSlice(std.json.Value, allocator, signaled_response, .{});
    defer signaled.deinit();
    const signaled_result = signaled.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(signaled_result.get("accepted") orelse .null).?);
    try std.testing.expect(jsonBool(signaled_result.get("signaled") orelse .null).?);
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);

    var attempts: usize = 0;
    while (attempts < 100 and session.running) : (attempts += 1) {
        try session.poll(allocator);
        if (session.running) try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(!session.running);
    try std.testing.expect(session.exit_status != null);
}

test "unknown terminal session returns resource_not_found" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":7,"method":"session.tail","params":{"id":"missing-session"}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("resource_not_found", err.get("code").?.string);
    try std.testing.expectEqualStrings("session not found", err.get("message").?.string);
}

test "daemon registry starts in a fresh random namespace" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    try std.testing.expectEqual(@as(usize, 32), daemon.registry.instance_nonce.len);
    for (daemon.registry.instance_nonce) |byte| {
        try std.testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
    }
    try std.testing.expectEqual(@as(u64, 0), daemon.registry.registry_revision);
    try std.testing.expect(daemon.registry.clients.count() == 0);
}

test "registry workspace resolution, empty list, and client lifecycle" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const list_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.list","params":{"workspace":{"workspace_path":"/tmp/verde-registry-spine"},"include_outcomes":true,"include_notifications":true}}
    );
    defer allocator.free(list_response);
    var list_parsed = try std.json.parseFromSlice(std.json.Value, allocator, list_response, .{});
    defer list_parsed.deinit();
    const list_result = list_parsed.value.object.get("result").?.object;
    try std.testing.expect(list_result.get("instance_nonce").?.string.len == 32);
    try std.testing.expectEqual(@as(usize, 0), list_result.get("processes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), list_result.get("outcomes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), list_result.get("leases").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), list_result.get("notifications").?.array.items.len);
    try std.testing.expectEqualStrings("/tmp/verde-registry-spine", list_result.get("workspace").?.object.get("path").?.string);

    const register_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.client.register","params":{"persistent":true}}
    );
    defer allocator.free(register_response);
    var register_parsed = try std.json.parseFromSlice(std.json.Value, allocator, register_response, .{});
    defer register_parsed.deinit();
    const client_id = register_parsed.value.object.get("result").?.object.get("client_id").?.string;
    const heartbeat_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"daemon.client.heartbeat\",\"params\":{{\"client_id\":\"{s}\"}}}}",
        .{client_id},
    );
    defer allocator.free(heartbeat_request);
    const heartbeat_response = try daemon.handleRequest(heartbeat_request);
    defer allocator.free(heartbeat_response);
    var heartbeat_parsed = try std.json.parseFromSlice(std.json.Value, allocator, heartbeat_response, .{});
    defer heartbeat_parsed.deinit();
    try std.testing.expect(jsonBool(heartbeat_parsed.value.object.get("result").?.object.get("accepted").?).?);

    const close_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"daemon.client.close\",\"params\":{{\"client_id\":\"{s}\"}}}}",
        .{client_id},
    );
    defer allocator.free(close_request);
    const close_response = try daemon.handleRequest(close_request);
    defer allocator.free(close_response);
    var close_parsed = try std.json.parseFromSlice(std.json.Value, allocator, close_response, .{});
    defer close_parsed.deinit();
    try std.testing.expect(jsonBool(close_parsed.value.object.get("result").?.object.get("closed").?).?);
}

test "registry workspace id and path must agree" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":5,"method":"workspace.resolve","params":{"workspace":{"workspace_id":"wrong-id","workspace_path":"/tmp/verde-registry-mismatch"}}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_PARAMS, parsed.value.object.get("error").?.object.get("code").?.string);
}

test "registry rejects a path pre-registered to a different workspace id" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    _ = try daemon.registry.ensureWorkspace(allocator, "pre-registered-workspace");
    _ = try daemon.registry.registerWorkspacePath(
        allocator,
        "pre-registered-workspace",
        "/tmp/verde-registry-pre-registered-alias",
        1,
    );

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":6,"method":"workspace.resolve","params":{"workspace":{"workspace_path":"/tmp/verde-registry-pre-registered-alias"}}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_INVALID_PARAMS,
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}

test "stable session id sanitizes project id" {
    const allocator = std.testing.allocator;
    const session_id = try stableSessionId(allocator, "my project:/tmp/repo", 2, 9);
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("verde:my_project_tmp_repo:dock:2:pane:9", session_id);
}

test "session id for leaf preserves existing id" {
    const allocator = std.testing.allocator;
    const session_id = (try sessionIdForLeaf(
        allocator,
        .{ .project_id = "project-a", .dock_id = 0 },
        4,
        "custom-session",
    )).?;
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("custom-session", session_id);
}

test "sessionizer socket paths use Verde pref path" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // Hermetic: pin/clear override so pref-derived derivation is what we assert.
    const prev: ?[:0]u8 = if (std.c.getenv(SESSIONIZER_SOCKET_ENV_NAME)) |value|
        try allocator.dupeZ(u8, std.mem.span(value))
    else
        null;
    _ = unsetenv(SESSIONIZER_SOCKET_ENV_NAME);
    defer {
        if (prev) |value| {
            _ = setenv(SESSIONIZER_SOCKET_ENV_NAME, value.ptr, 1);
            allocator.free(value);
        }
    }
    const socket = try socketPath(allocator, "/tmp/verde");
    defer allocator.free(socket);
    try std.testing.expect(std.mem.endsWith(u8, socket, "/tmp/verde/" ++ SOCKET_NAME));
}

test "sessionizer socket path honors VERDE_SESSIONIZER_SOCKET override" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const override_path = "/tmp/verde-sessionizer-override-test.sock";
    const prev: ?[:0]u8 = if (std.c.getenv(SESSIONIZER_SOCKET_ENV_NAME)) |value|
        try allocator.dupeZ(u8, std.mem.span(value))
    else
        null;
    try std.testing.expect(setenv(SESSIONIZER_SOCKET_ENV_NAME, override_path, 1) == 0);
    defer {
        if (prev) |value| {
            _ = setenv(SESSIONIZER_SOCKET_ENV_NAME, value.ptr, 1);
            allocator.free(value);
        } else {
            _ = unsetenv(SESSIONIZER_SOCKET_ENV_NAME);
        }
    }

    const socket = try socketPath(allocator, "/tmp/verde-ignored-pref");
    defer allocator.free(socket);
    try std.testing.expectEqualStrings(override_path, socket);
}

test "Windows sessionizer pipe name is stable across path spelling" {
    const allocator = std.testing.allocator;
    const canonical = try windowsPipeName(allocator, "C:\\Users\\Test User\\AppData\\Roaming\\verde\\Native");
    defer allocator.free(canonical);
    const alternate = try windowsPipeName(allocator, "c:/users/test user/appdata/roaming/verde/native/");
    defer allocator.free(alternate);

    try std.testing.expect(std.mem.startsWith(u8, canonical, WINDOWS_PIPE_PREFIX));
    try std.testing.expectEqualStrings(canonical, alternate);
}

test "Windows daemon replacement ignores the status payload PID" {
    try std.testing.expectEqual(
        @as(?usize, 77),
        daemonProcessIdForReplacement(.windows, 999_999, 77),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        daemonProcessIdForReplacement(.windows, 999_999, null),
    );
    try std.testing.expectEqual(
        @as(?usize, 42),
        daemonProcessIdForReplacement(.linux, 42, null),
    );
}

test "Windows pipe rollout rejects legacy daemons" {
    const recreated_pipe_status = parseDaemonStatus(
        std.testing.allocator,
        "{\"result\":{\"protocol_version\":4,\"pid\":999999}}",
    ).?;
    const unflushed_pipe_status = parseDaemonStatus(
        std.testing.allocator,
        "{\"result\":{\"protocol_version\":5,\"pid\":999999}}",
    ).?;
    try std.testing.expect(recreated_pipe_status.protocol_version != PROTOCOL_VERSION);
    try std.testing.expect(unflushed_pipe_status.protocol_version != PROTOCOL_VERSION);
}

test "daemon chat diff payload preserves files and patches" {
    const payload = try chatDiffPayloadAlloc(std.testing.allocator, &.{.{
        .path = "src/main.zig",
        .additions = 2,
        .deletions = 1,
        .patch = "@@ -1 +1,2 @@\n-old\n+new\n+again\n",
    }}, .turn_snapshot);
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("turn_snapshot", parsed.value.object.get("scope").?.string);
    const files = parsed.value.object.get("files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0].object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 2), files[0].object.get("additions").?.integer);
    try std.testing.expectEqualStrings(
        "@@ -1 +1,2 @@\n-old\n+new\n+again\n",
        files[0].object.get("patch").?.string,
    );
}

test "daemon retains chat turns until their result is consumed" {
    try std.testing.expect(chatTurnKeepsDaemonAlive(.running, false, false));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.waiting_approval, false, false));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.completed, false, true));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.failed, false, true));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.aborted, false, true));
    try std.testing.expect(!chatTurnKeepsDaemonAlive(.completed, true, true));
}

test "prepareShutdown refuses while a live PTY exists" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    // Unit tests pin idle policy explicitly so env from the runner cannot
    // make shouldExitForIdle spuriously true.
    daemon.idle_exit_ms = null;

    const create_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"id":"lifecycle-live-pty","cwd":".","command":["/bin/cat"],"pref_path":"/tmp"}}
    );
    defer allocator.free(create_response);
    try std.testing.expect(try testSessionCreateResponseWasCreated(allocator, create_response));
    try std.testing.expect(daemon.sessions.items[0].running);

    const prepare_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare_response);
    var prepared = try std.json.parseFromSlice(std.json.Value, allocator, prepare_response, .{});
    defer prepared.deinit();
    const result = prepared.value.object.get("result").?.object;
    try std.testing.expect(!jsonBool(result.get("accepted") orelse .null).?);
    try std.testing.expect(!jsonBool(result.get("safe_to_exit") orelse .null).?);
    try std.testing.expectEqual(@as(usize, 1), jsonUsize(result.get("running_sessions") orelse .null).?);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
    try std.testing.expect(!daemon.shouldExitForIdle());

    // Existing live session is preserved; replacement must wait, not kill.
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    try std.testing.expect(daemon.sessions.items[0].running);
}

test "prepareShutdown preserves unconsumed completed turns" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;

    const turn = try allocator.create(ChatTurn);
    errdefer allocator.destroy(turn);
    const empty_images = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(empty_images);
    turn.* = .{
        .allocator = allocator,
        .turn_id = try allocator.dupe(u8, "turn-unconsumed"),
        .workspace_id = try allocator.dupe(u8, "ws"),
        .local_thread_id = try allocator.dupe(u8, "thread"),
        .request = .{
            .provider = .claude,
            .harness_kind = .local_cli,
            .project_path = try allocator.dupe(u8, "."),
            .prompt = try allocator.dupe(u8, "hello"),
            .thread_title = try allocator.dupe(u8, ""),
        },
        .owned_image_paths = empty_images,
        .status = .completed,
        .consumed = false,
        .worker_done = true,
    };
    try daemon.chat_turns.append(allocator, turn);

    const prepare_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare_response);
    var prepared = try std.json.parseFromSlice(std.json.Value, allocator, prepare_response, .{});
    defer prepared.deinit();
    const result = prepared.value.object.get("result").?.object;
    try std.testing.expect(!jsonBool(result.get("accepted") orelse .null).?);
    try std.testing.expect(!jsonBool(result.get("safe_to_exit") orelse .null).?);
    try std.testing.expectEqual(@as(usize, 1), jsonUsize(result.get("keep_alive_turns") orelse .null).?);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
    try std.testing.expectEqual(@as(usize, 1), daemon.chat_turns.items.len);
    try std.testing.expect(!daemon.chat_turns.items[0].consumed);

    // After consume, prepareShutdown may accept.
    const consume_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"chat.turn.consume","params":{"turn_id":"turn-unconsumed"}}
    );
    defer allocator.free(consume_response);
    const prepare_ok = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":5,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare_ok);
    var prepared_ok = try std.json.parseFromSlice(std.json.Value, allocator, prepare_ok, .{});
    defer prepared_ok.deinit();
    const ok_result = prepared_ok.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(ok_result.get("accepted") orelse .null).?);
    try std.testing.expect(jsonBool(ok_result.get("safe_to_exit") orelse .null).?);
    try std.testing.expect(daemon.shutdown_requested);
    try std.testing.expect(!daemon.accepting_mutations);
    try std.testing.expect(daemon.shouldExitForIdle());
}

test "draining dispatcher rejects every state mutator" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.accepting_mutations = false;

    const methods = [_][]const u8{
        "session.create",
        "session.attach",
        "session.detach",
        "session.write",
        "session.resize",
        "session.kill",
        "session.cleanup",
        "chat.turn.start",
        "chat.turn.approve",
        "chat.turn.cancel",
        "chat.turn.consume",
        "process.start",
        "process.stop",
        "process.restart",
        "lease.acquire",
        "lease.renew",
        "lease.release",
        "daemon.client.register",
        "daemon.client.heartbeat",
        "daemon.client.close",
        "daemon.stop",
    };
    for (methods, 0..) |method, index| {
        const request = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{}}}}",
            .{ index, method },
        );
        defer allocator.free(request);
        const response = try daemon.handleRequest(request);
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        const error_value = parsed.value.object.get("error").?.object;
        try std.testing.expectEqualStrings("invalid_state", jsonString(error_value.get("code").?).?);
    }
}

test "idle exit is disabled by default and honors override" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // Pin idle env so Daemon.init does not inherit a runner override.
    const prev_idle: ?[:0]u8 = if (std.c.getenv(IDLE_EXIT_ENV_NAME)) |value|
        try allocator.dupeZ(u8, std.mem.span(value))
    else
        null;
    _ = unsetenv(IDLE_EXIT_ENV_NAME);
    defer {
        if (prev_idle) |value| {
            _ = setenv(IDLE_EXIT_ENV_NAME, value.ptr, 1);
            allocator.free(value);
        }
    }
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    try std.testing.expect(daemon.idle_exit_ms == null);
    try std.testing.expect(!daemon.shouldExitForIdle());
    try std.testing.expect(!daemon.shouldExitForIdle());

    daemon.idle_exit_ms = 0;
    daemon.idle_since_ms = null;
    try std.testing.expect(!daemon.shouldExitForIdle()); // first observation arms the timer
    // Historical 30s idle window is enough to prove the override elapsed.
    daemon.idle_since_ms = nowMs() - (30 * std.time.ms_per_s);
    try std.testing.expect(daemon.shouldExitForIdle());
}

test "stale sessionizer endpoint is not treated as live" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    // Use a short /tmp path rather than testing.tmpDir: AF_UNIX sun_path is
    // ~104 bytes on Linux, and Zig's nested tmpDir paths routinely overflow it.
    const base = try std.fmt.allocPrint(allocator, "/tmp/verde-lifecycle-stale-{d}", .{platform_runtime.processId()});
    defer allocator.free(base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const socket = try std.fs.path.join(allocator, &.{ base, SOCKET_NAME });
    defer allocator.free(socket);

    // Stale path: file exists but nothing accepts connections.
    {
        var file = try std.Io.Dir.cwd().createFile(io, socket, .{});
        file.close(io);
    }
    try std.testing.expect(!sessionizerEndpointIsLive(io, socket));
}

test "live sessionizer endpoint probe detects a listening daemon socket" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    // Short /tmp path: sun_path ~104-byte limit rejects long testing.tmpDir paths.
    const base = try std.fmt.allocPrint(allocator, "/tmp/verde-lifecycle-live-{d}", .{platform_runtime.processId()});
    defer allocator.free(base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const socket = try std.fs.path.join(allocator, &.{ base, SOCKET_NAME });
    defer allocator.free(socket);

    const address = try std.Io.net.UnixAddress.init(socket);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    defer deleteSocketPath(socket);

    try std.testing.expect(sessionizerEndpointIsLive(io, socket));
}

test "parsePrepareShutdownResult detects method_not_found for legacy daemons" {
    const allocator = std.testing.allocator;
    const missing = parsePrepareShutdownResult(allocator,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":"method_not_found","message":"daemon.prepareShutdown"}}
    ).?;
    try std.testing.expect(missing.method_missing);
    try std.testing.expect(!missing.accepted);

    const ready = parsePrepareShutdownResult(allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"accepted":true,"safe_to_exit":true,"running_sessions":0,"keep_alive_turns":0,"shutdown_requested":true}}
    ).?;
    try std.testing.expect(ready.accepted);
    try std.testing.expect(ready.safe_to_exit);
    try std.testing.expect(!ready.method_missing);
}

test "endpoint-gone classification is connect-class only" {
    try std.testing.expect(isEndpointGoneError(error.ConnectionRefused));
    try std.testing.expect(isEndpointGoneError(error.FileNotFound));
    try std.testing.expect(!isEndpointGoneError(error.ConnectionTimedOut));
    try std.testing.expect(!isEndpointGoneError(error.MessageTooLarge));
    try std.testing.expect(!isEndpointGoneError(error.OutOfMemory));
}

test "Windows daemon replacement still requires authenticated pipe PID" {
    try std.testing.expectEqual(
        @as(?usize, 77),
        daemonProcessIdForReplacement(.windows, 999_999, 77),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        daemonProcessIdForReplacement(.windows, 999_999, null),
    );
}

const TestCliPathMapping = struct {
    query: []const u8,
    result: []const u8,
};

const TestCliPathResolver = struct {
    mappings: []const TestCliPathMapping,

    fn resolve(self: *const TestCliPathResolver, allocator: std.mem.Allocator, candidate: []const u8) !?[]u8 {
        for (self.mappings) |mapping| {
            if (std.ascii.eqlIgnoreCase(candidate, mapping.query)) return @as(?[]u8, try allocator.dupe(u8, mapping.result));
        }
        return null;
    }
};

test "Windows CLI resolver selects packaged console executable" {
    const allocator = std.testing.allocator;
    var resolver: TestCliPathResolver = .{ .mappings = &.{.{
        .query = "C:\\Verde\\bin\\verde.exe",
        .result = "C:\\Verde\\bin\\verde.exe",
    }} };
    const resolved = try resolveWindowsCliPathWith(allocator, "C:\\Verde\\app\\Verde.exe", &resolver);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("C:\\Verde\\bin\\verde.exe", resolved);
}

test "Windows daemon resolver selects packaged console executable" {
    const allocator = std.testing.allocator;
    var resolver: TestCliPathResolver = .{ .mappings = &.{.{
        .query = "C:\\Verde\\bin\\verde.exe",
        .result = "C:\\Verde\\bin\\verde.exe",
    }} };
    const resolved = try resolveWindowsDaemonPathWith(allocator, "C:\\Verde\\app\\Verde.exe", &resolver);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("C:\\Verde\\bin\\verde.exe", resolved);
}

test "Windows daemon resolver preserves raw-prefix console executable" {
    const allocator = std.testing.allocator;
    var resolver: TestCliPathResolver = .{ .mappings = &.{
        .{
            .query = "C:\\verde-build\\bin\\cli\\verde.exe",
            .result = "C:\\verde-build\\bin\\cli\\verde.exe",
        },
        .{ .query = "verde.exe", .result = "D:\\Installed\\verde.exe" },
    } };
    const resolved = try resolveWindowsDaemonPathWith(
        allocator,
        "C:\\verde-build\\bin\\cli\\verde.exe",
        &resolver,
    );
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("C:\\verde-build\\bin\\cli\\verde.exe", resolved);
}

test "Windows CLI resolver prefers raw-prefix cli subdirectory" {
    const allocator = std.testing.allocator;
    var resolver: TestCliPathResolver = .{ .mappings = &.{
        .{ .query = "C:\\verde-build\\bin\\cli\\verde.exe", .result = "C:\\verde-build\\bin\\cli\\verde.exe" },
        .{ .query = "C:\\verde-build\\bin\\verde.exe", .result = "C:\\verde-build\\bin\\verde.exe" },
    } };
    const resolved = try resolveWindowsCliPathWith(allocator, "C:\\verde-build\\bin\\Verde.exe", &resolver);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("C:\\verde-build\\bin\\cli\\verde.exe", resolved);
}

test "Windows CLI resolver falls back through PATH then current executable" {
    const allocator = std.testing.allocator;
    var path_resolver: TestCliPathResolver = .{ .mappings = &.{.{
        .query = "verde.exe",
        .result = "D:\\Tools\\verde.exe",
    }} };
    const from_path = try resolveWindowsCliPathWith(allocator, "C:\\standalone\\Verde.exe", &path_resolver);
    defer allocator.free(from_path);
    try std.testing.expectEqualStrings("D:\\Tools\\verde.exe", from_path);

    var fallback_resolver: TestCliPathResolver = .{ .mappings = &.{} };
    const fallback = try resolveWindowsCliPathWith(allocator, "C:\\standalone\\Verde.exe", &fallback_resolver);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("C:\\standalone\\Verde.exe", fallback);
}

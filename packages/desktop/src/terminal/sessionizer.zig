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
const daemon_store = @import("../daemon/store.zig");
const platform_ipc = @import("../platform/ipc.zig");
const platform_live_endpoint = @import("../platform/live_endpoint.zig");
const workspace_identity = @import("../platform/workspace_identity.zig");
const stack = @import("../workspace/stack.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const send_runner = @import("../chat/send_runner.zig");
const transcript_apply = @import("../chat/transcript_apply.zig");
const windows_conpty = @import("platform/windows_conpty.zig");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const log = std.log.scoped(.sessionizer);
const store_protocol = headless.store;
const changes_protocol = headless.changes_protocol;
const change_journal = @import("../daemon/change_journal.zig");

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
/// Q7: hard ceiling for a `core.changes` bounded long-poll (25s). A real
/// limit, not a tuning knob: it bounds how long a parked waiter can occupy
/// one of the TRANSPORT_WORKER_COUNT transport workers before answering with
/// a heartbeat, so a shutdown/join is never gated on an unbounded wait.
const MAX_CHANGES_WAIT_MS: u32 = 25_000;
const ATTACH_STALE_MS: i64 = 60 * std.time.ms_per_s;
/// Env override so hermetic tests can force a fast idle exit without changing
/// production lifetime policy (null / unset = never idle-exit).
const IDLE_EXIT_ENV_NAME = "VERDE_SESSION_DAEMON_IDLE_EXIT_MS";
/// Optional path-valued override: absolute directory for hermetic store DBs.
/// When set, the daemon opens `{value}/state.sqlite` post-bind. When unset,
/// production opens `{pref_path}/state.sqlite` after endpoint ownership (M3-P3).
pub const SESSION_DAEMON_STORE_DIR_ENV_NAME = "VERDE_SESSION_DAEMON_STORE_DIR";
/// Test-only: when set to a non-empty value other than "0"/"false", skip the
/// production store open so store-less capability_unavailable paths remain pinable.
pub const SESSION_DAEMON_STORE_DISABLE_ENV_NAME = "VERDE_SESSION_DAEMON_STORE_DISABLE";
/// Test-only store fault arm (B9). Parsed only when the store-dir override is
/// also set; maps 1:1 to `daemon_store.StoreFault` tag names.
pub const SESSION_DAEMON_STORE_FAULT_ENV_NAME = "VERDE_SESSION_DAEMON_STORE_FAULT";
/// Hermetic chat stub: when set (non-empty, not 0/false/no), chat workers skip
/// real providers and complete with canned events so IT scenarios stay offline.
pub const SESSION_DAEMON_CHAT_STUB_ENV_NAME = "VERDE_SESSION_DAEMON_CHAT_STUB";
/// Hermetic-only one-shot chat durable-commit fault. Only meaningful with the
/// store-dir override. `fail_once` → first commitTurn attempt returns StoreBusy
/// without touching SQLite; subsequent attempts pass through (MAJOR-3 IT arm).
pub const SESSION_DAEMON_CHAT_COMMIT_FAULT_ENV_NAME = "VERDE_SESSION_DAEMON_CHAT_COMMIT_FAULT";
/// Test-only change-journal entry-cap override so overflow ITs stay small
/// (M5-P2 scenario 3). Missing/empty/invalid keeps the production ring cap.
pub const SESSION_DAEMON_JOURNAL_ENTRY_CAP_ENV_NAME = "VERDE_SESSION_DAEMON_JOURNAL_ENTRY_CAP";
/// Test-only latency injection for the unlocked managed-process phase.
const TEST_SLOW_IO_ENV_NAME = "VERDE_SESSIONIZER_TEST_SLOW_IO_MS";
/// Test-only orphan retention override; registry-internal TTLs remain fixed.
const TEST_RETENTION_ENV_NAME = "VERDE_SESSIONIZER_TEST_RETENTION_MS";

/// Store service spine: SQLite work runs under this mutex, never under lockDaemon.
/// Uses the same spin-lock primitive as the daemon (Zig 0.16 has no std.Thread.Mutex).
const StoreService = struct {
    mutex: std.atomic.Mutex = .unlocked,
    store: daemon_store.Store,
    in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    draining: bool = false, // set by prepare-shutdown in S3
};

fn lockStoreService(service: *StoreService) void {
    while (!service.mutex.tryLock()) std.atomic.spinLoopHint();
}
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
    /// Per-request deadline. Callers that intentionally issue a bounded
    /// long-poll must opt into a matching transport budget.
    timeout_ms: u32 = SESSIONIZER_REQUEST_TIMEOUT_MS,

    pub fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *HeadlessTransport = @ptrCast(@alignCast(ctx));
        return try sendRequestJsonAllocWithTimeout(
            self.allocator,
            self.pref_path,
            request_json,
            self.timeout_ms,
        );
    }
};

/// Send a pre-encoded request envelope to the sessionizer endpoint.
pub fn sendRequestJsonAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    request_json: []const u8,
) ![]u8 {
    return sendRequestJsonAllocWithTimeout(
        allocator,
        pref_path,
        request_json,
        SESSIONIZER_REQUEST_TIMEOUT_MS,
    );
}

/// Send a pre-encoded request with a caller-selected finite transport timeout.
pub fn sendRequestJsonAllocWithTimeout(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    request_json: []const u8,
    timeout_ms: u32,
) ![]u8 {
    std.debug.assert(timeout_ms > 0);
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    return try platform_ipc.requestAlloc(allocator, endpoint, request_json, .{
        .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .timeout_ms = timeout_ms,
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
            if (std.mem.eql(u8, code, headless.registry.ERR_INVALID_STATE)) {
                const data = err_value.object.get("data") orelse .null;
                if (data == .object) {
                    return .{
                        .accepted = false,
                        .safe_to_exit = false,
                        .running_sessions = jsonUsize(data.object.get("running_sessions") orelse .null) orelse 0,
                        .keep_alive_turns = jsonUsize(data.object.get("turns") orelse .null) orelse 0,
                        .shutdown_requested = false,
                    };
                }
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
    owner_client_id: ?[]const u8 = null,
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
        if (self.running) _ = self.signalTermination(std.c.SIG.TERM);
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
        if (!self.signalTermination(std.c.SIG.TERM)) return false;
        _ = self.captureExitStatus();
        return true;
    }

    fn forceTerminate(self: *Self) bool {
        if (!self.running) return false;
        if (!self.signalTermination(std.c.SIG.KILL)) return false;
        _ = self.captureExitStatus();
        return true;
    }

    fn signalTermination(self: *Self, signal: std.c.SIG) bool {
        const foreground_process_group: ?std.posix.pid_t = if (self.foregroundProcessGroup()) |pgrp| @intCast(pgrp) else null;
        var signaled = signalDescendantProcessGroups(
            std.heap.smp_allocator,
            self.child_pid,
            foreground_process_group,
            signal,
        ) > 0;

        // forkpty makes the child a process-group leader. Signal both that
        // group and a distinct foreground group so script runners cannot
        // leave their actual application alive after the launcher exits.
        if (foreground_process_group) |pgrp| {
            if (pgrp != self.child_pid and std.c.kill(-pgrp, signal) == 0) signaled = true;
        }
        if (std.c.kill(-self.child_pid, signal) == 0) signaled = true;
        if (!signaled and std.c.kill(self.child_pid, signal) == 0) signaled = true;
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
    /// Optional registered daemon client that owns this session for retention
    /// and client-scoped stop. The desktop omits this field.
    owner_client_id: ?[]u8 = null,
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
        const owner_client_id = if (options.owner_client_id) |client_id| try allocator.dupe(u8, client_id) else null;
        errdefer if (owner_client_id) |client_id| allocator.free(client_id);
        const owned_cwd = try allocator.dupe(u8, cwd);
        errdefer allocator.free(owned_cwd);
        const label = try allocator.dupe(u8, if (options.label.len > 0) options.label else command_label);
        errdefer allocator.free(label);

        self.* = .{
            .session_id = session_id,
            .project_id = project_id,
            .project_path = project_path,
            .owner_client_id = owner_client_id,
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
        if (self.owner_client_id) |client_id| allocator.free(client_id);
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

    fn forceTerminate(self: *PtySession) bool {
        if (comptime builtin.os.tag == .windows) return self.terminate();
        if (!self.backend.forceTerminate()) return false;
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
    started_at_ms: i64 = 0,
    finished_at_ms: ?i64 = null,
    mutex: std.atomic.Mutex = .unlocked,
    worker_thread: ?std.Thread = null,
    events: std.ArrayList(ChatEvent) = .empty,
    next_seq: u64 = 1,
    status: ChatTurnStatus = .running,
    consumed: bool = false,
    worker_done: bool = false,
    /// True from turn acceptance (when the store is open) until the store
    /// receipt returns, so consume cannot race a pre-commit terminal status.
    durability_pending: bool = false,
    /// Set only after commitTurn returns a WriteResult (including receipt replay).
    committed_store_revision: ?u64 = null,
    cancel_requested: bool = false,
    /// Q5 cancel hint: suppress "Conversation interrupted" when a follow-up is pending.
    followup_pending: bool = false,
    /// Optional client-supplied user message id staged at acceptance (M4-P2/P3).
    user_message_id: ?[]u8 = null,
    /// Hermetic IT stub path (also armed by VERDE_SESSION_DAEMON_CHAT_STUB).
    use_stub: bool = false,
    /// Last durable-commit error name (diagnostic; dual-write-unread only).
    durability_error: ?[]u8 = null,
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
        if (self.user_message_id) |value| allocator.free(value);
        if (self.durability_error) |value| allocator.free(value);
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

const SlowProcessOperation = enum {
    start,
    stop,
    restart,
};

const SlowProcessWork = struct {
    operation: SlowProcessOperation,
    workspace_id: []u8,
    workspace_path: []u8,
    name: []u8,
    process_id: []u8,
    client_id: []u8,
    force: bool = false,
    generation: u64 = 0,
    previous_session_id: ?[]u8 = null,

    fn deinit(self: *SlowProcessWork, allocator: std.mem.Allocator) void {
        if (self.workspace_id.len != 0) allocator.free(self.workspace_id);
        if (self.workspace_path.len != 0) allocator.free(self.workspace_path);
        if (self.name.len != 0) allocator.free(self.name);
        if (self.process_id.len != 0) allocator.free(self.process_id);
        if (self.client_id.len != 0) allocator.free(self.client_id);
        if (self.previous_session_id) |session_id| allocator.free(session_id);
    }
};

const SlowProcessFailure = union(enum) {
    resource_not_found,
    invalid_state,
    invalid_params,
    config_unavailable: []const u8,
    bounds: stack.BoundsViolation,
};

const SlowProcessPhaseResult = struct {
    session: ?*PtySession = null,
    command: []u8 = &.{},
    cwd: []u8 = &.{},
    failure: ?SlowProcessFailure = null,
    stop_completed: bool = false,

    fn deinit(self: *SlowProcessPhaseResult, allocator: std.mem.Allocator) void {
        if (self.command.len != 0) allocator.free(self.command);
        if (self.cwd.len != 0) allocator.free(self.cwd);
        if (self.session) |session| session.deinit(allocator);
    }
};

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    pref_path: []u8,
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
    /// Requesting threads drain their own slow job; this queue only bounds and
    /// deduplicates in-flight registry work, it is not a background worker.
    registry_jobs: process_registry.RegistryJobQueue,
    test_slow_io_delay_ms: u64 = 0,
    /// Test-only orphan retention override. It never changes registry TTLs.
    test_retention_override_ms: ?i64 = null,
    /// Null until post-bind production (or hermetic override) store construction.
    store_service: ?*StoreService = null,
    /// Nonce-scoped change journal (M5-P2). A fresh Daemon IS the instance-start
    /// reset: `instance_nonce` is fixed for this Daemon's lifetime and the
    /// journal starts empty with it, so change_seq restarts at 1 per instance.
    journal: change_journal.ChangeJournal = .{},
    /// Leaf spin lock for the journal. Lock order: lockDaemon → journal_mutex
    /// and store service mutex → journal_mutex; the journal path never takes
    /// another lock, so no cycle is possible.
    journal_mutex: std.atomic.Mutex = .unlocked,
    /// M5-P3 long-poll park state. `changes_signal` is a futex word bumped by
    /// every journal append (after the leaf lock is RELEASED) and by drain;
    /// parked `core.changes` waiters sleep on it holding NO locks. The
    /// missed-wake-free protocol: a waiter loads this BEFORE reading the
    /// journal window, and the appender appends BEFORE bumping — so either
    /// the waiter's read sees the entry or its futex expectation is stale and
    /// the wait returns immediately.
    changes_signal: std.atomic.Value(u32) = .init(0),
    /// Count of currently parked long-pollers, capped at
    /// platform_ipc.MAX_PARKED_LONG_POLL_WAITERS (Q7). Over-cap requests
    /// degrade to an immediate heartbeat — never an error.
    changes_parked: std.atomic.Value(u32) = .init(0),
    /// Sticky drain latch (prepareShutdown accepted, or transport draining).
    /// Parked waiters terminate with the structured drain response; new
    /// positive waits degrade to immediate heartbeats.
    changes_draining: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator) Daemon {
        return initWithPrefPath(allocator, "");
    }

    pub fn initWithPrefPath(allocator: std.mem.Allocator, pref_path: []const u8) Daemon {
        const instance_nonce = randomInstanceNonce(allocator);
        defer allocator.free(instance_nonce);
        var owned_pref_path: []u8 = &.{};
        if (pref_path.len != 0) owned_pref_path = allocator.dupe(u8, pref_path) catch @panic("failed to initialize daemon pref path");
        return .{
            .allocator = allocator,
            .pref_path = owned_pref_path,
            .registry = process_registry.ProcessRegistry.init(allocator, instance_nonce) catch @panic("failed to initialize daemon process registry"),
            .idle_exit_ms = idleExitMsFromEnv(allocator),
            .registry_jobs = process_registry.RegistryJobQueue.init(process_registry.REGISTRY_JOB_QUEUE_MAX) catch @panic("failed to initialize registry job queue"),
            .test_slow_io_delay_ms = slowIoDelayMsFromEnv(allocator),
            .test_retention_override_ms = retentionOverrideMsFromEnv(allocator),
            .journal = .{ .max_entries = journalEntryCapFromEnv(allocator) },
        };
    }

    pub fn deinit(self: *Daemon) void {
        if (self.pref_path.len != 0) self.allocator.free(self.pref_path);
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.chat_turns.items) |turn| turn.deinit(self.allocator);
        self.chat_turns.deinit(self.allocator);
        self.registry_jobs.deinit(self.allocator);
        self.registry.deinit(self.allocator);
        self.journal.deinit(self.allocator);
    }

    fn pollSessions(self: *Daemon) void {
        const now = nowMs();
        for (self.sessions.items) |session| {
            session.poll(self.allocator) catch {};
            if (!session.running) {
                if (isManagedSessionId(session.session_id))
                    self.noteManagedSessionExit(session, now)
                else
                    self.noteSessionExitInRegistry(session, null, now);
            }
            session.cleanupStaleAttaches(self.allocator, now);
        }
    }

    /// Shared daemon state that must not be dropped during idle exit or stop.
    fn hasLiveKeepAliveState(self: *Daemon) bool {
        self.removeFinishedConsumedChatTurns();
        for (self.sessions.items) |session| {
            if (session.running) return true;
        }
        if (self.countLiveManagedProcesses() != 0) return true;
        if (self.registry_jobs.len() != 0) return true;
        // Active leases normally keep the daemon alive. During a store-backed
        // prepare drain they transfer via SQLite, so they must not block exit.
        if (!(self.store_service != null and self.shutdown_requested)) {
            if (self.countActiveLeases(nowMs()) != 0) return true;
        }
        for (self.chat_turns.items) |turn| {
            lockTurn(turn);
            const keep_alive = chatTurnKeepsDaemonAlive(
                turn.status,
                turn.consumed,
                turn.worker_done,
                turn.durability_pending,
            );
            turn.mutex.unlock();
            if (keep_alive) return true;
        }
        return false;
    }

    fn countLiveManagedProcesses(self: *const Daemon) usize {
        var count: usize = 0;
        for (self.registry.workspaces.items) |workspace| {
            for (workspace.managed_processes.items) |process| {
                switch (process.status) {
                    .starting, .running, .stopping => count += 1,
                    .stopped, .crashed, .restarting => {},
                }
            }
        }
        return count;
    }

    fn countActiveLeases(self: *Daemon, now_ms: i64) usize {
        var count: usize = 0;
        // Lease pruning mutates only each workspace's lease list, not the
        // workspace array; the daemon lock protects the borrowed records.
        for (self.registry.workspaces.items) |workspace| {
            count += self.registry.activeLeaseCount(self.allocator, workspace.id, now_ms);
        }
        return count;
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
            const keep_alive = chatTurnKeepsDaemonAlive(
                turn.status,
                turn.consumed,
                turn.worker_done,
                turn.durability_pending,
            );
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
            // Never drop a turn while its store commit is still in flight.
            const remove = turn.consumed and turn.worker_done and !turn.durability_pending;
            turn.mutex.unlock();
            if (remove) {
                self.chat_turns.orderedRemove(index).deinit(self.allocator);
                continue;
            }
            index += 1;
        }
    }

    /// Retire sessions whose registered client has disappeared or gone stale.
    /// This is a pure in-memory O(sessions) scan; all clock-driven registry
    /// retention happens in the drain thread while the daemon lock is held.
    fn reapOrphanedSessions(self: *Daemon, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.sessions.items.len) {
            const session = self.sessions.items[index];
            const client_id = session.owner_client_id orelse {
                index += 1;
                continue;
            };
            const client = self.registry.client(client_id) orelse {
                index += 1;
                continue;
            };
            // Persistent clients are exempt before either closed or stale
            // checks, matching the W1 disconnected-retention contract.
            if (client.persistent) {
                index += 1;
                continue;
            }
            const retention_ms = self.test_retention_override_ms;
            const closed_expired = if (client.closed) if (client.closed_at_ms) |closed_at_ms|
                retentionExpiredForDaemon(closed_at_ms, now_ms, retention_ms orelse process_registry.ORPHAN_GRACE_MS)
            else
                false else false;
            const stale_expired = if (retention_ms) |override_ms|
                retentionExpiredForDaemon(client.last_heartbeat_ms, now_ms, override_ms)
            else
                process_registry.disconnectedRetentionExpired(client.last_heartbeat_ms, now_ms, false);
            if (!closed_expired and !stale_expired) {
                index += 1;
                continue;
            }
            _ = session.terminate();
            self.noteSessionExitInRegistry(session, "orphaned", now_ms);
            if (!session.running) {
                self.removeAt(index);
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
        // Managed sessions are represented by managed-process records, not a
        // second tracked-terminal row; double publication would duplicate one
        // child in process.list.
        if (isManagedSessionId(session.session_id)) return;
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

    fn noteManagedSessionExit(self: *Daemon, session: *PtySession, now_ms: i64) void {
        if (session.registry_finished) return;
        const workspace = self.registry.workspace(session.project_id) orelse return;
        for (workspace.managed_processes.items) |*process| {
            if (process.session_id == null or !std.mem.eql(u8, process.session_id.?, session.session_id)) continue;
            // A queued stop/restart owns this exit and will detach the old
            // session in Phase C; do not race its runtime transition here.
            if (hasRegistryJob(self.registry_jobs.jobs.items, workspace.id, process.id)) return;
            // P2 records crashes as failed and never auto-restart; restart
            // policy belongs to P3+ so an exit cannot create a launch loop.
            const event: process_registry.ManagedProcessRuntimeEvent = if (session.exit_status) |status|
                if (status == 0) .stopped else .failed
            else
                .failed;
            process.transition(event, now_ms) catch |err| {
                log.warn("managed session exit transition failed id_len={d} err={s}", .{ session.session_id.len, @errorName(err) });
                session.registry_finished = true;
                return;
            };
            // Retain the stopped session id so process.logs can still tail
            // the daemon-owned ring until the next explicit start detaches it.
            self.bumpRegistryRevision(.{ .topic = .process, .resource_id = process.id, .workspace_id = workspace.id });
            session.registry_finished = true;
            return;
        }
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
        // Store methods own their drain/capability precedence and unlock
        // lockDaemon for SQLite work; route before the generic mutator drain gate.
        if (isStoreMethod(method)) return try self.handleStoreRequest(id_value, method, params);
        // chat.turn.start owns its drain check under lockDaemon (unlocked serve
        // path); other mutators still gate here under the `.normal` outer lock.
        if (!std.mem.eql(u8, method, "chat.turn.start") and !self.accepting_mutations and methodMutatesState(method)) {
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
        if (std.mem.eql(u8, method, headless.registry.METHOD_DAEMON_STOP)) return try self.daemonStopResponse(id_value, params);
        if (std.mem.eql(u8, method, "status")) return try self.statusResponse(id_value);
        if (std.mem.eql(u8, method, "daemon.prepareShutdown")) return try self.prepareShutdownResponse(id_value);
        // Additive headless core methods; existing methods and error codes unchanged.
        if (std.mem.startsWith(u8, method, "core.")) return try self.coreResponse(id_value, method, params);
        return try errorResponseAlloc(self.allocator, id_value, "method_not_found", method);
    }

    fn methodMutatesState(method: []const u8) bool {
        return headless.isMutatingMethod(method);
    }

    /// Store request pipeline. Caller must NOT hold lockDaemon: this path takes
    /// a short bookkeeping lock, then runs SQLite under the service mutex only.
    fn handleStoreRequest(
        self: *Daemon,
        id_value: std.json.Value,
        method: []const u8,
        params: std.json.Value,
    ) ![]u8 {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const is_status = std.mem.eql(u8, method, store_protocol.METHOD_DAEMON_STORE_STATUS);
        const is_thread_get = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_GET);
        const is_thread_list = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_LIST);
        const is_turn_record = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_TURN_RECORD);
        const is_chat_read = is_thread_get or is_thread_list or is_turn_record;
        const is_core_snapshot = std.mem.eql(u8, method, store_protocol.METHOD_CORE_SNAPSHOT);
        const is_core_changes = std.mem.eql(u8, method, changes_protocol.METHOD_CORE_CHANGES);
        // Reads never join the mutator drain gate or in_flight write counter.
        const is_mutator = !is_status and !is_chat_read and !is_core_snapshot and !is_core_changes;

        // 1. Decode typed params OUTSIDE any lock into the per-request arena.
        // parseFromValueLeaky ignores allocate; string slices borrow params,
        // which outlive this call via the parent handleRequest parse.
        // OutOfMemory is re-raised (never remapped to invalid_params).
        var decode_failed = false;
        var decoded_mutation: ?daemon_store.Mutation = null;
        var decoded_thread_get: ?store_protocol.ThreadGetRequest = null;
        var decoded_thread_list: ?store_protocol.ThreadListRequest = null;
        var decoded_turn_record: ?store_protocol.TurnRecordRequest = null;
        var decoded_core_snapshot: ?store_protocol.CoreSnapshotRequest = null;
        var decoded_core_changes: ?changes_protocol.ChangesRequest = null;
        if (is_status) {
            // No params body required for status.
        } else if (is_core_snapshot) {
            // Absent params keep the M3 store-only default request.
            if (params == .null) {
                decoded_core_snapshot = .{};
            } else {
                const req = std.json.parseFromValueLeaky(
                    store_protocol.CoreSnapshotRequest,
                    arena,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch |err| blk: {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    decode_failed = true;
                    break :blk null;
                };
                if (req) |value| decoded_core_snapshot = value;
            }
        } else if (is_core_changes) {
            // Absent params bootstrap at the journal tail (ChangesRequest{}).
            if (params == .null) {
                decoded_core_changes = .{};
            } else {
                const req = std.json.parseFromValueLeaky(
                    changes_protocol.ChangesRequest,
                    arena,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch |err| blk: {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    decode_failed = true;
                    break :blk null;
                };
                if (req) |value| decoded_core_changes = value;
            }
        } else if (is_thread_get) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.ThreadGetRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_thread_get = value;
        } else if (is_thread_list) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.ThreadListRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_thread_list = value;
        } else if (is_turn_record) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.TurnRecordRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_turn_record = value;
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_STATE_SNAPSHOT_REPLACE)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.SnapshotReplaceRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .snapshot_replace = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_UPSERT)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceUpsertRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .workspace_upsert = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_UPSERT)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.ThreadUpsertRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .thread_upsert = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_CHAT_MESSAGE_APPEND)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.MessageAppendRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .message_append = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_SURFACE_UPSERT)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.SurfaceUpsertRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .surface_upsert = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_SURFACE_CLEAR)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.SurfaceClearRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .surface_clear = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.NotificationChatCompletionUpsertRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .chat_completion_upsert = value };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.NotificationChatCompletionClearRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .chat_completion_clear = value };
        } else {
            decode_failed = true;
        }

        const client_id: ?[]const u8 = if (decoded_mutation) |mutation|
            mutationHeader(mutation).client_id
        else
            null;

        // 2. Short lockDaemon for bookkeeping only (never SQLite).
        lockDaemon(self);
        // (i) mutators only: refuse while draining.
        if (is_mutator and !self.accepting_mutations) {
            self.mutex.unlock();
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_STATE,
                "daemon is preparing shutdown and is not accepting mutations",
            );
        }
        // (ii) store-less daemon → capability_unavailable (status included).
        const service = self.store_service orelse {
            self.mutex.unlock();
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_CAPABILITY_UNAVAILABLE,
                "store capability is unavailable",
            );
        };
        // (iii) held decode failure.
        const decode_missing = if (is_status)
            false
        else if (is_core_snapshot)
            decoded_core_snapshot == null
        else if (is_core_changes)
            decoded_core_changes == null
        else if (is_thread_get)
            decoded_thread_get == null
        else if (is_thread_list)
            decoded_thread_list == null
        else if (is_turn_record)
            decoded_turn_record == null
        else
            decoded_mutation == null;
        if (decode_failed or decode_missing) {
            self.mutex.unlock();
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
        }
        // (iv) mutators: strict client_id validation against M2 client records.
        if (is_mutator) {
            const cid = client_id orelse {
                self.mutex.unlock();
                return try errorResponseAlloc(
                    self.allocator,
                    id_value,
                    headless.protocol.ERR_INVALID_PARAMS,
                    "unknown client_id",
                );
            };
            if (self.registry.client(cid) == null) {
                self.mutex.unlock();
                return try errorResponseAlloc(
                    self.allocator,
                    id_value,
                    headless.protocol.ERR_INVALID_PARAMS,
                    "unknown client_id",
                );
            }
        }
        // Capture draining under the daemon lock (only written by prepareShutdown).
        const service_draining = service.draining;
        // (v) track in-flight WRITES only, capture service pointer, unlock.
        // storeStatus is a read: counting it would make prepare's
        // store_writes_in_flight refusal lie under concurrent transport (M5).
        // queued_mutation_count therefore also excludes concurrent status.
        if (is_mutator) {
            _ = service.in_flight.fetchAdd(1, .monotonic);
        }
        self.mutex.unlock();
        defer if (is_mutator) {
            _ = service.in_flight.fetchSub(1, .monotonic);
        };

        // M5-P2 composite reads own their lock choreography (journal leaf lock,
        // short lockDaemon for the volatile half, store mutex for the durable
        // half) and must never sit under the generic store-mutex window below.
        if (is_core_changes) {
            const req = decoded_core_changes orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            return try self.coreChangesResponse(arena, id_value, service, req);
        }
        if (is_core_snapshot) {
            const req = decoded_core_snapshot orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            return try self.coreSnapshotResponse(arena, id_value, service, req);
        }

        // 3. Store work with NO daemon lock.
        lockStoreService(service);
        defer service.mutex.unlock();

        if (is_status) {
            const store_revision = service.store.storeRevision() catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            // Store.init always opens at MAX_SUPPORTED_VERSION; read the live
            // pragma under the service mutex so the status reflects the file.
            // Range-check before cast: a corrupt/negative user_version maps to
            // store_corrupt rather than panicking in Debug (requiredU32 style).
            const schema_version: u32 = blk: {
                const row_or_null = service.store.conn.row("pragma user_version", .{}) catch {
                    return try storeErrorResponse(self.allocator, id_value, error.StoreUnavailable);
                };
                const row = row_or_null orelse {
                    return try storeErrorResponse(self.allocator, id_value, error.StoreCorrupt);
                };
                defer row.deinit();
                break :blk std.math.cast(u32, row.int(0)) orelse {
                    return try storeErrorResponse(self.allocator, id_value, error.StoreCorrupt);
                };
            };
            const result: store_protocol.StoreStatusResult = .{
                .schema_version = schema_version,
                .store_revision = store_revision,
                .writer_ready = !service_draining,
                .queued_mutation_count = service.in_flight.load(.monotonic),
                .drain_state = if (service_draining) "draining" else "open",
            };
            return try okValueResponse(self.allocator, id_value, result);
        }

        if (is_thread_get) {
            const req = decoded_thread_get orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            const result = loadThreadGetResult(self.allocator, &service.store, req) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            defer freeThreadGetResult(self.allocator, result);
            return try okValueResponse(self.allocator, id_value, result);
        }
        if (is_thread_list) {
            const req = decoded_thread_list orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            const result = loadThreadListResult(self.allocator, &service.store, req) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            defer freeThreadListResult(self.allocator, result);
            return try okValueResponse(self.allocator, id_value, result);
        }
        if (is_turn_record) {
            const req = decoded_turn_record orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            const result = loadTurnRecord(self.allocator, &service.store, req) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            defer freeTurnRecord(self.allocator, result);
            return try okValueResponse(self.allocator, id_value, result);
        }

        const mutation = decoded_mutation orelse return try errorResponseAlloc(
            self.allocator,
            id_value,
            headless.protocol.ERR_INVALID_PARAMS,
            "invalid params",
        );

        const write_result = service.store.applyMutation(mutation) catch |err| {
            return try storeErrorResponse(self.allocator, id_value, err);
        };
        return try okValueResponse(self.allocator, id_value, write_result);
    }

    /// core.changes: cursor poll with a real bounded long-poll (M5-P3).
    /// wait_ms clamps to MAX_CHANGES_WAIT_MS (25s, Q7); an exhausted wait is
    /// a heartbeat, never an error. Parked waiters sleep on `changes_signal`
    /// holding NO locks; drain wakes them into the structured drain error.
    /// Over-cap long-polls (Q7: more than MAX_PARKED_LONG_POLL_WAITERS
    /// already parked) reuse the wait_ms=0 immediate path — heartbeat, never
    /// an error. Bootstrap (absent cursor) never parks: there is no "since"
    /// point for new entries to satisfy.
    ///
    /// Capture order pins the reply invariant "envelope/store_revision >= any
    /// entry's revision": the journal window is copied FIRST, then the
    /// registry envelope, then the store revision. A commit landing between
    /// captures can only make the envelope/store_revision newer than the
    /// entries, never older.
    fn coreChangesResponse(
        self: *Daemon,
        arena: std.mem.Allocator,
        id_value: std.json.Value,
        service: *StoreService,
        request: changes_protocol.ChangesRequest,
    ) ![]u8 {
        // A4: the over-cap degradation and the plain wait_ms=0 request share
        // this one clamp + immediate-check code path.
        const effective_wait_ms: u32 = @min(request.wait_ms, MAX_CHANGES_WAIT_MS);
        const wait_deadline_ms: i64 = nowMs() + effective_wait_ms;
        var wait_exhausted = false;

        // (1) Journal window under the leaf lock; entries copy into the arena.
        // Re-checked after every park wake-up until it is non-empty, the wait
        // budget is spent, or drain terminates the poll.
        var entries: std.ArrayList(changes_protocol.ChangeEntry) = .empty;
        var next_cursor: u64 = 0;
        var floor_seq: u64 = 0;
        park_loop: while (true) {
            // Missed-wake protocol: load the signal word BEFORE the window
            // read. An append bumps it only AFTER releasing the leaf lock, so
            // either this read observes the entry or the park below sees a
            // changed word and returns immediately.
            const observed_signal = self.changes_signal.load(.acquire);
            entries = .empty; // Prior iteration's copies are arena garbage.
            {
                lockJournal(self);
                defer self.journal_mutex.unlock();
                if (request.cursor) |cursor| {
                    switch (self.journal.entriesAfter(cursor)) {
                        .expired => |expired| {
                            // Q6: expiry is an error envelope with a floor_seq datum.
                            var data_map: std.json.ObjectMap = .empty;
                            try data_map.put(arena, "floor_seq", .{ .integer = std.math.cast(i64, expired.floor_seq) orelse std.math.maxInt(i64) });
                            return try errorResponseAllocWithData(
                                self.allocator,
                                id_value,
                                headless.protocol.ERR_REVISION_EXPIRED,
                                "cursor below journal floor",
                                .{ .object = data_map },
                            );
                        },
                        .ok => |window| {
                            next_cursor = window.last_change_seq;
                            floor_seq = window.journal_floor_seq;
                            for (window.entries) |entry| {
                                if (!changeEntryMatchesTopics(entry.topic, request.topics)) continue;
                                try entries.append(arena, .{
                                    .change_seq = entry.change_seq,
                                    .topic = entry.topic.wireName(),
                                    .resource_id = try arena.dupe(u8, entry.resource_id),
                                    .workspace_id = if (entry.workspace_id) |value| try arena.dupe(u8, value) else null,
                                    .store_revision = entry.store_revision,
                                    .registry_revision = entry.registry_revision,
                                });
                            }
                        },
                    }
                } else {
                    // Absent cursor bootstraps at the tail: no historical replay,
                    // and no expiry check because nothing could have been missed.
                    next_cursor = self.journal.last_seq;
                    floor_seq = self.journal.journal_floor_seq;
                }
            }

            if (entries.items.len != 0) break :park_loop;
            if (request.cursor == null) break :park_loop; // Bootstrap never parks.
            if (effective_wait_ms == 0) break :park_loop; // Immediate check (incl. A4 over-cap reuse).
            if (wait_exhausted) break :park_loop; // Budget spent → heartbeat.
            // Draining before park: degrade NEW long-polls to an immediate
            // heartbeat; only already-parked waiters get the drain error.
            if (self.changes_draining.load(.acquire)) break :park_loop;
            switch (self.parkForChanges(observed_signal, wait_deadline_ms)) {
                .woken => continue :park_loop,
                // One final consistent window read, then heartbeat.
                .timed_out => {
                    wait_exhausted = true;
                    continue :park_loop;
                },
                // Q7 pinned: over-cap degrades to the immediate heartbeat
                // shape above, NEVER an error.
                .over_cap => break :park_loop,
                .drained => return try self.changesDrainingResponse(arena, id_value),
            }
        }

        // (2) Volatile envelope under a short lockDaemon, after the journal drain.
        lockDaemon(self);
        const instance_nonce = arena.dupe(u8, self.registry.instance_nonce) catch |err| {
            self.mutex.unlock();
            return err;
        };
        const registry_revision = self.registry.registry_revision;
        self.mutex.unlock();

        // (3) Durable revision under the store mutex, after the journal drain.
        lockStoreService(service);
        const store_revision = service.store.storeRevision() catch |err| {
            service.mutex.unlock();
            return try storeErrorResponse(self.allocator, id_value, err);
        };
        service.mutex.unlock();

        // (4) Assembly off every lock. An empty window (immediate check,
        // exhausted long-poll, over-cap degradation, or drain pre-park) is
        // reported as a heartbeat.
        const result: changes_protocol.ChangesResult = .{
            .entries = entries.items,
            .next_cursor = next_cursor,
            .journal_floor_seq = floor_seq,
            .expired = false,
            .heartbeat = entries.items.len == 0,
            .envelope = .{ .instance_nonce = instance_nonce, .registry_revision = registry_revision },
            .store_revision = store_revision,
        };
        return try okValueResponse(self.allocator, id_value, result);
    }

    /// Structured drain response for a parked long-poll waiter woken by
    /// beginChangesDrain (A2): the client learns the daemon is going away
    /// (invalid_state + data.reason="draining") instead of receiving a
    /// heartbeat that invites an immediate re-poll of a dying endpoint.
    fn changesDrainingResponse(self: *Daemon, arena: std.mem.Allocator, id_value: std.json.Value) ![]u8 {
        var data_map: std.json.ObjectMap = .empty;
        try data_map.put(arena, "reason", .{ .string = "draining" });
        return try errorResponseAllocWithData(
            self.allocator,
            id_value,
            headless.protocol.ERR_INVALID_STATE,
            "daemon is draining; long-poll terminated",
            .{ .object = data_map },
        );
    }

    /// M5-P2 composite snapshot. Capture order: journal cursor FIRST, then the
    /// volatile half under one short lockDaemon window, then the durable half
    /// in ONE read transaction under the store mutex, then assembly OFF all
    /// locks. A cursor captured before both halves can only over-deliver: a
    /// change landing after the cursor but before a half is read appears both
    /// in the snapshot and in the first core.changes poll — never in neither.
    ///
    /// Declared simplifications: `after_store_revision` is accepted but not
    /// used for short-circuiting (a full snapshot is always returned), and a
    /// store-less daemon answers capability_unavailable for every scope.
    fn coreSnapshotResponse(
        self: *Daemon,
        arena: std.mem.Allocator,
        id_value: std.json.Value,
        service: *StoreService,
        request: store_protocol.CoreSnapshotRequest,
    ) ![]u8 {
        // Absent scopes preserve the M3 store-only reply shape exactly:
        // {snapshot, store_revision} with no composite fields at all.
        const composite = request.scopes != null;
        var include_store = true;
        var include_registry = false;
        var include_sessions = false;
        var include_turns = false;
        var incomplete: std.ArrayList([]const u8) = .empty;
        if (request.scopes) |names| {
            include_store = false;
            for (names) |name| {
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_STORE)) include_store = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_REGISTRY)) include_registry = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_SESSIONS)) include_sessions = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_TURNS)) include_turns = true;
                if (scopeIsIncomplete(name, CHAT_AUTHORITY_LANDED)) {
                    try incomplete.append(arena, try arena.dupe(u8, name));
                }
            }
        }

        // (1) Journal cursor first (leaf lock): over-delivery-safe seed for
        // the client's first core.changes poll after this snapshot.
        var change_cursor: u64 = 0;
        if (composite) {
            lockJournal(self);
            change_cursor = self.journal.last_seq;
            self.journal_mutex.unlock();
        }

        // (2) Volatile fragments under one short lockDaemon window, serialized
        // into arena strings via the existing registry serializers so the wire
        // shapes stay identical to process.list / session.list / turn records.
        var envelope_json: []const u8 = "";
        var processes_json: []const u8 = "[]";
        var leases_json: []const u8 = "[]";
        var sessions_json: []const u8 = "[]";
        var turns_json: []const u8 = "[]";
        if (composite) {
            lockDaemon(self);
            defer self.mutex.unlock();
            envelope_json = try serializeEnvelopeFragment(arena, self);
            if (include_registry) {
                processes_json = try serializeProcessesFragment(arena, self, request.workspace_id);
                leases_json = try serializeLeasesFragment(arena, self, request.workspace_id);
            }
            if (include_sessions) sessions_json = try serializeSessionsFragment(arena, self, request.workspace_id);
            if (include_turns) turns_json = try serializeTurnsFragment(arena, self, request.workspace_id);
        }

        // (3) Durable half in ONE read transaction on the store queue: the
        // snapshot contents and its store_revision are the same committed state.
        var loaded: LoadedStoreSnapshot = undefined;
        {
            lockStoreService(service);
            defer service.mutex.unlock();
            loaded = loadStoreSnapshotTxn(arena, &service.store, request.workspace_id, include_store) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
        }

        // (4) Assembly off every lock.
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("snapshot");
        try s.write(loaded.snapshot);
        try s.objectField("store_revision");
        try s.write(loaded.store_revision);
        if (composite) {
            try s.objectField("envelope");
            try writeRawFragment(&s, envelope_json);
            try s.objectField("change_cursor");
            try s.write(change_cursor);
            try s.objectField("processes");
            try writeRawFragment(&s, processes_json);
            try s.objectField("leases");
            try writeRawFragment(&s, leases_json);
            try s.objectField("sessions");
            try writeRawFragment(&s, sessions_json);
            try s.objectField("turns");
            try writeRawFragment(&s, turns_json);
            try s.objectField("incomplete_scopes");
            try s.beginArray();
            for (incomplete.items) |name| try s.write(name);
            try s.endArray();
        }
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
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
    /// replacement). Enters drain only when the full shared state gate is clear
    /// so a refused upgrade does not freeze a healthy daemon.
    /// Gate order: registry safe (leases transfer when the store is active) →
    /// store writes drained → transfer commit + store close in on_closing
    /// (before endpoint release; finishSessionizerServer is the idempotent fallback).
    fn prepareShutdownResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        const now_ms = nowMs();
        // Reap expired registry state before evaluating the handoff gate; a
        // stale lease must not keep an otherwise empty daemon alive.
        _ = self.registry.reap(self.allocator, now_ms);
        self.removeFinishedConsumedChatTurns();
        const running_sessions = self.countRunningSessions();
        const keep_alive_turns = self.countKeepAliveTurns();
        const managed = self.countLiveManagedProcesses();
        const leases = self.countActiveLeases(now_ms);
        const registry_jobs = self.registry_jobs.len();
        // Hermetic store open: leases transfer at drain and stop blocking prepare.
        // Production (store-less) keeps the pre-M3 DaemonReplacementBlocked path.
        const leases_block = if (self.store_service != null) @as(usize, 0) else leases;
        const safe_to_exit = running_sessions == 0 and managed == 0 and keep_alive_turns == 0 and leases_block == 0 and registry_jobs == 0;
        if (!safe_to_exit) {
            return prepareShutdownRefusalResponse(
                self,
                id_value,
                running_sessions,
                managed,
                keep_alive_turns,
                leases,
                registry_jobs,
            );
        }
        // Store gate (after registry is clear): refuse while writes are in flight.
        // in_flight counts mutators only (not daemon.storeStatus), so this field
        // stays truthful under the concurrent transport (M5-P3).
        if (self.store_service) |service| {
            const store_writes_in_flight = service.in_flight.load(.monotonic);
            if (store_writes_in_flight > 0) {
                return prepareShutdownStoreRefusalResponse(self, id_value, store_writes_in_flight);
            }
            // Written only here under the caller's daemon lock; storeStatus reads it there.
            service.draining = true;
        }
        self.accepting_mutations = false;
        self.shutdown_requested = true;
        // Accepted handoff: terminate parked core.changes long-polls with the
        // structured drain response NOW (atomics + futex only — safe under
        // the caller's daemon lock) so no waiter rides out its wait against a
        // daemon that is about to release the endpoint.
        self.beginChangesDrain();
        return try okValueResponse(self.allocator, id_value, .{
            .accepted = true,
            .safe_to_exit = true,
            .running_sessions = running_sessions,
            .managed_processes = managed,
            .keep_alive_turns = keep_alive_turns,
            .active_leases = leases,
            .registry_jobs = registry_jobs,
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
        // Authority signal: store=true only after the production writer owns the DB.
        const store_ready = self.store_service != null;
        return switch (typed.body) {
            .status => |result| blk: {
                var status = result;
                status.capabilities.store = store_ready;
                break :blk try okValueResponse(self.allocator, id_value, status);
            },
            .capabilities => |result| blk: {
                var caps = result;
                caps.capabilities.store = store_ready;
                break :blk try okValueResponse(self.allocator, id_value, caps);
            },
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
        for (self.chat_turns.items) |turn| {
            // Match chat.turn.list: hide consumed turns. A consumed turn whose
            // worker is still draining is therefore invisible here until exit
            // removes it; process.list is not a second chat-turn surface.
            if (turn.consumed) continue;
            if (!std.mem.eql(u8, turn.workspace_id, workspace.id)) continue;
            {
                lockTurn(turn);
                defer turn.mutex.unlock();
                try writeChatTurnProcessSnapshot(&s, turn);
            }
        }
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
        // `turn:` is reserved for derived chat-turn records. On a miss (absent
        // or consumed), return not-found immediately — never fall through to
        // stored managed/tracked/external/outcome ids (matches process.wait).
        if (std.mem.startsWith(u8, process_id, "turn:")) {
            const turn_id = process_id["turn:".len..];
            for (self.chat_turns.items) |turn| {
                if (turn.consumed) continue;
                if (!std.mem.eql(u8, turn.turn_id, turn_id) or !std.mem.eql(u8, turn.workspace_id, workspace.id)) continue;
                lockTurn(turn);
                defer turn.mutex.unlock();
                try s.objectField("process");
                try writeChatTurnProcessSnapshot(&s, turn);
                try s.endObject();
                try s.endObject();
                return try writer.toOwnedSlice();
            }
            const response = try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "process not found");
            writer.deinit();
            return response;
        }
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

        // Same `turn:` precedence as process.inspect: reserved prefix resolves
        // against derived chat turns only and never falls through to stored ids.
        if (std.mem.startsWith(u8, process_id, "turn:")) {
            const turn_id = process_id["turn:".len..];
            var turn_status: ?process_registry.ExternalProcessStatus = null;
            for (self.chat_turns.items) |turn| {
                if (turn.consumed) continue;
                if (!std.mem.eql(u8, turn.turn_id, turn_id) or !std.mem.eql(u8, turn.workspace_id, workspace.id)) continue;
                lockTurn(turn);
                turn_status = chatTurnExternalStatus(chatTurnPublishedStatus(turn));
                turn.mutex.unlock();
                break;
            }
            const status = turn_status orelse
                return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "process not found");

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
            if (status == .running) try s.write(null) else try s.write(@tagName(status));
            try s.objectField("outcome");
            // Chat turns have no TerminalProcessOutcome; the process.wait
            // result deliberately keeps this field null for turn records.
            try s.write(null);
            try s.objectField("changed");
            // Turn state transitions do not bump registry_revision, so while
            // the turn is still running `changed` cannot signal progress — only
            // a concurrent registry mutation would flip it. Terminal turns
            // always report changed=true (poll complete). Live progress waits
            // for a P3 turn-revision or similar signal.
            try s.write(if (status == .running)
                (after_registry_revision != null and self.registry.registry_revision != after_registry_revision.?)
            else
                true);
            try s.objectField("timed_out");
            try s.write(status == .running);
            try s.endObject();
            try s.endObject();
            return try writer.toOwnedSlice();
        }

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

        // Managed proc:{...} IDs point through the managed record to the
        // daemon-owned PTY; tracked terminal IDs keep their existing path.
        var session_id: ?[]const u8 = null;
        for (workspace.tracked_terminal_processes.items) |process| {
            if (std.mem.eql(u8, process.process_id, process_id)) {
                session_id = process.session_id;
                break;
            }
        }
        if (session_id == null) {
            for (workspace.managed_processes.items) |process| {
                if (!std.mem.eql(u8, process.id, process_id) and !std.mem.eql(u8, process.name, process_id)) continue;
                session_id = process.session_id orelse break;
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

    fn handleSlowRegistryRequest(self: *Daemon, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidParams;
        const id_value = parsed.value.object.get("id") orelse .null;
        const method = jsonString(parsed.value.object.get("method") orelse .null) orelse return error.InvalidParams;
        const params = parsed.value.object.get("params") orelse .null;

        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_START)) {
            var decoded = parseDaemonParams(headless.registry.ProcessStartRequest, allocator, params) catch
                return self.registryErrorResponse(id_value, error.InvalidParams);
            defer decoded.deinit();
            return self.handleSlowProcess(
                allocator,
                id_value,
                params,
                .start,
                decoded.value.name,
                decoded.value.process_id,
                decoded.value.client_id,
                false,
            );
        }
        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_STOP)) {
            var decoded = parseDaemonParams(headless.registry.ProcessStopRequest, allocator, params) catch
                return self.registryErrorResponse(id_value, error.InvalidParams);
            defer decoded.deinit();
            return self.handleSlowProcess(
                allocator,
                id_value,
                params,
                .stop,
                "",
                decoded.value.process_id,
                decoded.value.client_id,
                decoded.value.force,
            );
        }
        if (std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_RESTART)) {
            var decoded = parseDaemonParams(headless.registry.ProcessRestartRequest, allocator, params) catch
                return self.registryErrorResponse(id_value, error.InvalidParams);
            defer decoded.deinit();
            return self.handleSlowProcess(
                allocator,
                id_value,
                params,
                .restart,
                decoded.value.name,
                decoded.value.process_id,
                decoded.value.client_id,
                false,
            );
        }
        return try errorResponseAlloc(allocator, id_value, "method_not_found", method);
    }

    fn handleSlowProcess(
        self: *Daemon,
        allocator: std.mem.Allocator,
        id_value: std.json.Value,
        params: std.json.Value,
        operation: SlowProcessOperation,
        requested_name: []const u8,
        requested_process_id: ?[]const u8,
        requested_client_id: ?[]const u8,
        force: bool,
    ) ![]u8 {
        lockDaemon(self);
        var work = self.prepareSlowProcess(
            allocator,
            params,
            operation,
            requested_name,
            requested_process_id,
            requested_client_id,
            force,
        ) catch |err| {
            self.mutex.unlock();
            if (err == error.JobQueueFull) return resourceLimitErrorResponse(self, id_value, "registry_job_queue", process_registry.REGISTRY_JOB_QUEUE_MAX);
            return self.registryErrorResponse(id_value, err);
        };
        self.mutex.unlock();
        defer work.deinit(allocator);

        var phase = self.executeSlowProcessPhase(&work);
        defer phase.deinit(allocator);
        lockDaemon(self);
        defer self.mutex.unlock();
        return self.finishSlowProcess(id_value, &work, &phase);
    }

    fn prepareSlowProcess(
        self: *Daemon,
        allocator: std.mem.Allocator,
        params: std.json.Value,
        operation: SlowProcessOperation,
        requested_name: []const u8,
        requested_process_id: ?[]const u8,
        requested_client_id: ?[]const u8,
        force: bool,
    ) !SlowProcessWork {
        if (!self.accepting_mutations) return error.DaemonDraining;
        const fields = try workspaceRefFields(params);
        if (operation != .stop and fields.workspace_path == null) {
            const workspace_id = fields.workspace_id orelse return error.WorkspacePathRequired;
            const existing_workspace = self.registry.workspace(workspace_id) orelse return error.WorkspacePathRequired;
            if (existing_workspace.canonical_path == null) return error.WorkspacePathRequired;
        }
        const workspace = try self.resolveProcessWorkspace(params, operation);
        const workspace_path = workspace.canonical_path orelse fields.workspace_path orelse "";
        if (operation != .stop and workspace_path.len == 0) return error.WorkspacePathRequired;

        var name: []u8 = &.{};
        var process_id: []u8 = &.{};
        errdefer if (name.len != 0) allocator.free(name);
        errdefer if (process_id.len != 0) allocator.free(process_id);
        if (requested_name.len != 0) {
            name = try allocator.dupe(u8, requested_name);
            process_id = if (requested_process_id) |value| blk: {
                if (value.len == 0) return error.InvalidParams;
                break :blk try allocator.dupe(u8, value);
            } else try std.fmt.allocPrint(allocator, "proc:{s}:{s}", .{ workspace.id, name });
        } else if (requested_process_id) |identifier| {
            if (identifier.len == 0) return error.InvalidParams;
            const process = managedProcessByIdentifier(workspace, identifier) orelse return error.ManagedProcessNotFound;
            name = try allocator.dupe(u8, process.name);
            process_id = try allocator.dupe(u8, process.id);
        } else {
            return error.InvalidParams;
        }

        const process = managedProcessByIdentifier(workspace, process_id);
        if (process) |existing| {
            if (requested_name.len != 0 and !std.mem.eql(u8, existing.name, name)) return error.InvalidParams;
            if (!std.mem.eql(u8, existing.id, process_id)) {
                // Dupe before free: an OOM here must not leave the errdefer
                // above pointing at an already-freed slice.
                const canonical_id = try allocator.dupe(u8, existing.id);
                allocator.free(process_id);
                process_id = canonical_id;
            }
        } else if (operation != .start) {
            return error.ManagedProcessNotFound;
        }

        const now = nowMs();
        const event: process_registry.ManagedProcessRuntimeEvent = switch (operation) {
            .start => .start,
            .stop => .stop,
            .restart => .restart,
        };
        if (hasRegistryJob(self.registry_jobs.jobs.items, workspace.id, process_id)) return error.OperationAlreadyInProgress;
        if (self.registry_jobs.isFull()) return error.JobQueueFull;

        var trial_runtime: process_registry.ManagedProcessRuntime = if (process) |existing| existing.runtime else .{};
        try trial_runtime.transition(event, now);

        var job = try process_registry.RegistryJob.init(
            allocator,
            switch (operation) {
                .start => .start_managed_process,
                .stop => .stop_managed_process,
                .restart => .restart_managed_process,
            },
            workspace.id,
            process_id,
            requested_client_id orelse "",
        );
        var job_owned_by_caller = true;
        errdefer if (job_owned_by_caller) job.deinit(allocator);
        var work: SlowProcessWork = .{
            .operation = operation,
            .workspace_id = &.{},
            .workspace_path = &.{},
            .name = &.{},
            .process_id = &.{},
            .client_id = &.{},
            .force = force,
            .generation = trial_runtime.generation,
        };
        errdefer work.deinit(allocator);
        work.workspace_id = try allocator.dupe(u8, workspace.id);
        work.workspace_path = try allocator.dupe(u8, workspace_path);
        work.name = name;
        name = &.{};
        work.process_id = process_id;
        process_id = &.{};
        work.client_id = try allocator.dupe(u8, requested_client_id orelse "");
        if (process) |existing| {
            if (existing.session_id) |session_id| work.previous_session_id = try allocator.dupe(u8, session_id);
        }

        if (self.registry_jobs.push(allocator, job)) |_| {
            job_owned_by_caller = false;
        } else |err| {
            // RegistryJobQueue deinitializes the job when its append fails
            // after taking ownership; JobQueueFull returns before ownership
            // transfers and the errdefer above cleans up that path.
            if (err == error.OutOfMemory) job_owned_by_caller = false;
            return err;
        }
        if (process) |existing| if (operation != .stop) {
            existing.transition(event, now) catch |err| {
                if (self.registry_jobs.removeMatching(work.workspace_id, work.process_id)) |queued| {
                    var owned_queued = queued;
                    owned_queued.deinit(allocator);
                }
                return err;
            };
        };
        return work;
    }

    fn resolveProcessWorkspace(self: *Daemon, params: std.json.Value, operation: SlowProcessOperation) !*process_registry.WorkspaceRecord {
        const fields = try workspaceRefFields(params);
        if (fields.workspace_id) |workspace_id| {
            if (fields.workspace_path == null) {
                if (operation == .stop) return self.registry.workspace(workspace_id) orelse error.WorkspaceNotFound;
                return self.registry.workspace(workspace_id) orelse error.WorkspacePathRequired;
            }
        }
        return self.resolveWorkspaceFromParams(params);
    }

    fn executeSlowProcessPhase(self: *Daemon, work: *const SlowProcessWork) SlowProcessPhaseResult {
        var result: SlowProcessPhaseResult = .{};
        if (self.test_slow_io_delay_ms != 0) sleepMs(@intCast(self.test_slow_io_delay_ms));

        if (work.previous_session_id) |session_id| {
            if (!self.stopManagedSessionUnlocked(session_id, work.force)) {
                result.failure = .invalid_state;
                return result;
            }
        }
        if (work.operation == .stop) {
            result.stop_completed = true;
            return result;
        }

        const loaded = stack.loadFromProject(self.allocator, work.workspace_path) catch |err| {
            result.failure = .{ .config_unavailable = @errorName(err) };
            return result;
        };
        if (loaded == null) {
            result.failure = .{ .config_unavailable = "config_not_found" };
            return result;
        }
        var config = loaded.?;
        defer config.deinit(self.allocator);
        if (stack.validateDefinitionBounds(&config)) |violation| {
            result.failure = .{ .bounds = violation };
            return result;
        }
        const definition = for (config.processes.items) |*candidate| {
            if (std.mem.eql(u8, candidate.name, work.name)) break candidate;
        } else {
            result.failure = .resource_not_found;
            return result;
        };
        const launch = definition.launchForOs(builtin.os.tag) orelse {
            result.failure = .invalid_state;
            return result;
        };
        const cwd = managedProcessCwd(self.allocator, work.workspace_path, definition.cwd) catch {
            result.failure = .invalid_state;
            return result;
        };
        defer self.allocator.free(cwd);
        result.cwd = self.allocator.dupe(u8, cwd) catch {
            result.failure = .invalid_state;
            return result;
        };
        var launch_args: std.ArrayList([]const u8) = .empty;
        defer launch_args.deinit(self.allocator);
        switch (launch) {
            .command => |command| {
                tryAppendLaunchArg(self.allocator, &launch_args, if (builtin.os.tag == .windows) "powershell.exe" else "/bin/sh") catch {
                    result.failure = .invalid_state;
                    return result;
                };
                tryAppendLaunchArg(self.allocator, &launch_args, if (builtin.os.tag == .windows) "-Command" else "-c") catch {
                    result.failure = .invalid_state;
                    return result;
                };
                tryAppendLaunchArg(self.allocator, &launch_args, command) catch {
                    result.failure = .invalid_state;
                    return result;
                };
                result.command = self.allocator.dupe(u8, command) catch {
                    result.failure = .invalid_state;
                    return result;
                };
            },
            .argv => |argv| {
                for (argv) |arg| {
                    tryAppendLaunchArg(self.allocator, &launch_args, arg) catch {
                        result.failure = .invalid_state;
                        return result;
                    };
                }
                result.command = std.mem.join(self.allocator, " ", launch_args.items) catch {
                    result.failure = .invalid_state;
                    return result;
                };
            },
        }
        const session_id = std.fmt.allocPrint(self.allocator, "managed:{s}:{s}:{d}", .{ work.workspace_id, work.name, work.generation }) catch {
            result.failure = .invalid_state;
            return result;
        };
        defer self.allocator.free(session_id);
        const session = PtySession.create(self.allocator, .{
            .session_id = session_id,
            .project_id = work.workspace_id,
            .project_path = work.workspace_path,
            .cwd = cwd,
            .label = work.name,
            .command = launch_args.items,
            .pref_path = self.pref_path,
        }) catch {
            result.failure = .invalid_state;
            return result;
        };
        result.session = session;
        return result;
    }

    /// Stop a managed PTY without holding the daemon mutex across the wait.
    /// The session list may move between polls, so each 20 ms sample re-finds
    /// the session while briefly holding the lock.
    fn stopManagedSessionUnlocked(self: *Daemon, session_id: []const u8, force: bool) bool {
        lockDaemon(self);
        const terminated = if (self.find(session_id)) |session| session.terminate() else false;
        self.mutex.unlock();
        if (terminated and self.waitForManagedSessionStopped(session_id, 2000)) return true;
        if (!terminated and self.findSessionStopped(session_id)) return true;
        if (!force) return false;

        lockDaemon(self);
        const force_terminated = if (self.find(session_id)) |session| session.forceTerminate() else false;
        self.mutex.unlock();
        if (!force_terminated) return self.findSessionStopped(session_id);
        return self.waitForManagedSessionStopped(session_id, 2000);
    }

    fn waitForManagedSessionStopped(self: *Daemon, session_id: []const u8, timeout_ms: i64) bool {
        var elapsed_ms: i64 = 0;
        while (elapsed_ms < timeout_ms) : (elapsed_ms += 20) {
            if (self.findSessionStopped(session_id)) return true;
            sleepMs(20);
        }
        return self.findSessionStopped(session_id);
    }

    fn findSessionStopped(self: *Daemon, session_id: []const u8) bool {
        lockDaemon(self);
        defer self.mutex.unlock();
        const session = self.find(session_id) orelse return true;
        session.poll(self.allocator) catch {};
        return !session.running;
    }

    fn finishSlowProcess(
        self: *Daemon,
        id_value: std.json.Value,
        work: *const SlowProcessWork,
        phase: *SlowProcessPhaseResult,
    ) ![]u8 {
        var job = self.registry_jobs.removeMatching(work.workspace_id, work.process_id) orelse
            return self.registryErrorResponse(id_value, error.OperationAlreadyInProgress);
        defer job.deinit(self.allocator);

        const workspace = self.registry.workspace(work.workspace_id) orelse {
            return self.registryErrorResponse(id_value, error.WorkspaceNotFound);
        };

        if (phase.failure) |failure| {
            if (phase.session) |session| {
                _ = session.terminate();
                session.deinit(self.allocator);
                phase.session = null;
            }
            if (managedProcessByIdentifier(workspace, work.process_id)) |process| {
                process.transition(.failed, nowMs()) catch {};
                self.bumpRegistryRevision(.{ .topic = .process, .resource_id = process.id, .workspace_id = work.workspace_id });
            }
            return self.slowProcessFailureResponse(id_value, work.operation, failure);
        }

        var process = managedProcessByIdentifier(workspace, work.process_id);
        if (process == null) {
            if (work.operation != .start) return self.registryErrorResponse(id_value, error.ManagedProcessNotFound);
            process = self.registry.ensureManagedProcess(
                self.allocator,
                work.workspace_id,
                work.name,
                phase.command,
                nowMs(),
            ) catch |err| {
                if (err == error.ManagedProcessCapacityExceeded)
                    return resourceLimitErrorResponse(self, id_value, "managed_process", stack.MAX_PROCESS_DEFINITIONS);
                return self.registryErrorResponse(id_value, err);
            };
            process.?.transition(.start, nowMs()) catch |err| return self.registryErrorResponse(id_value, err);
        }
        const managed_process = process.?;

        switch (work.operation) {
            .stop => {
                if (!phase.stop_completed) return self.registryErrorResponse(id_value, error.InvalidManagedProcessTransition);
                try managed_process.transition(.stop, nowMs());
                if (work.previous_session_id) |session_id| {
                    _ = self.removeSessionById(session_id);
                }
                if (managed_process.session_id) |session_id| {
                    self.allocator.free(session_id);
                    managed_process.session_id = null;
                }
                managed_process.pid = null;
                managed_process.process_group = null;
            },
            .start, .restart => {
                const session = phase.session orelse return self.registryErrorResponse(id_value, error.InvalidManagedProcessTransition);
                var owned_command = try self.allocator.dupe(u8, phase.command);
                errdefer self.allocator.free(owned_command);
                var owned_cwd = try self.allocator.dupe(u8, phase.cwd);
                errdefer self.allocator.free(owned_cwd);
                var owned_session_id = try self.allocator.dupe(u8, session.session_id);
                errdefer self.allocator.free(owned_session_id);
                try self.sessions.append(self.allocator, session);
                phase.session = null;

                if (managed_process.command.len != 0) self.allocator.free(managed_process.command);
                managed_process.command = owned_command;
                owned_command = &.{};
                if (managed_process.cwd.len != 0) self.allocator.free(managed_process.cwd);
                managed_process.cwd = owned_cwd;
                owned_cwd = &.{};
                if (managed_process.session_id) |session_id| self.allocator.free(session_id);
                managed_process.session_id = owned_session_id;
                owned_session_id = &.{};
                managed_process.pid = @intCast(session.child_pid);
                managed_process.process_group = if (session.foregroundProcessGroup()) |group| @intCast(group) else null;
                managed_process.transition(.started, nowMs()) catch |err| {
                    _ = self.removeSessionById(session.session_id);
                    return self.registryErrorResponse(id_value, err);
                };
                if (work.previous_session_id) |session_id| {
                    if (!std.mem.eql(u8, session_id, session.session_id)) _ = self.removeSessionById(session_id);
                }
            },
        }
        self.bumpRegistryRevision(.{ .topic = .process, .resource_id = managed_process.id, .workspace_id = work.workspace_id });
        return self.slowProcessSuccessResponse(id_value, work.operation, workspace, managed_process);
    }

    fn slowProcessFailureResponse(
        self: *Daemon,
        id_value: std.json.Value,
        operation: SlowProcessOperation,
        failure: SlowProcessFailure,
    ) ![]u8 {
        return switch (failure) {
            .resource_not_found => errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "process definition not found"),
            .invalid_params => errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_INVALID_PARAMS, "invalid process parameters"),
            .invalid_state => errorResponseAlloc(
                self.allocator,
                id_value,
                headless.registry.ERR_INVALID_STATE,
                if (operation == .stop) "managed process stop failed" else "managed process is not startable",
            ),
            .config_unavailable => |detail| configUnavailableErrorResponse(self, id_value, detail),
            .bounds => |violation| resourceLimitErrorResponse(self, id_value, violation.resource, violation.limit),
        };
    }

    fn slowProcessSuccessResponse(
        self: *Daemon,
        id_value: std.json.Value,
        operation: SlowProcessOperation,
        workspace: *const process_registry.WorkspaceRecord,
        process: *const process_registry.ManagedProcess,
    ) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("workspace");
        try writeWorkspaceInfo(&s, self, workspace);
        try s.objectField(switch (operation) {
            .start => "started",
            .stop => "stopped",
            .restart => "restarted",
        });
        try s.write(true);
        try s.objectField("process");
        try writeManagedProcessSnapshot(&s, workspace, process);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    fn bumpRegistryRevision(self: *Daemon, event: process_registry.RevisionBumpEvent) void {
        self.registry.registry_revision +%= 1;
        if (self.registry.registry_revision == 0) self.registry.registry_revision = 1;
        // Mirror ProcessRegistry.bumpRevision: publish the volatile-topic
        // journal entry at the same point that advances registry_revision and
        // under the same daemon lock, so an observed entry's registry_revision
        // never leads an envelope captured after draining the journal.
        if (self.registry.revision_hook) |hook| hook.notify(hook.context, event, self.registry.registry_revision);
    }

    /// Append one change entry under the journal leaf lock. On append failure
    /// (OOM / oversized entry) the journal advances its floor past a fresh seq
    /// so cursor clients observe an honest `revision_expired` and re-snapshot
    /// instead of silently missing the dropped change.
    fn appendJournalEntry(
        self: *Daemon,
        topic: change_journal.Topic,
        resource_id: []const u8,
        workspace_id: ?[]const u8,
        revision: change_journal.Revision,
    ) void {
        {
            lockJournal(self);
            defer self.journal_mutex.unlock();
            _ = self.journal.append(self.allocator, topic, resource_id, workspace_id, revision, nowMs()) catch {
                // The entry the client should have seen was dropped; force every
                // existing cursor below the new floor so it snapshot-falls-back.
                self.journal.last_seq += 1;
                self.journal.journal_floor_seq = self.journal.last_seq;
            };
        }
        // M5-P3 wake ordering (append → signal, leaf lock released first): a
        // parked core.changes waiter either re-reads the window and sees this
        // entry, or it loaded changes_signal before this bump and its futex
        // wait returns immediately on the changed value — a wake can never be
        // missed, and the waker never holds the lock the woken reader needs.
        self.signalChangesWaiters();
    }

    /// Publish "the journal advanced (or drain began)" to parked long-pollers.
    /// The fetchAdd is unconditional so the signal word always reflects every
    /// append; the futexWake syscall is skipped when nobody is parked.
    fn signalChangesWaiters(self: *Daemon) void {
        _ = self.changes_signal.fetchAdd(1, .release);
        if (self.changes_parked.load(.acquire) == 0) return;
        // The Threaded futex shim is stateless; an ephemeral instance is the
        // sanctioned way to reach futexWake from an arbitrary thread.
        var threaded = std.Io.Threaded.init_single_threaded;
        threaded.io().futexWake(u32, &self.changes_signal.raw, std.math.maxInt(u32));
    }

    /// Begin core.changes drain (sticky): parked waiters wake and answer with
    /// the structured drain response; new positive waits degrade to immediate
    /// heartbeats. Called by prepareShutdown (accepted) and by the transport's
    /// on_draining callback — before transport workers are joined, so a
    /// parked waiter can never stall worker quiesce.
    fn beginChangesDrain(self: *Daemon) void {
        self.changes_draining.store(true, .release);
        self.signalChangesWaiters();
    }

    const ChangesParkOutcome = enum { woken, timed_out, drained, over_cap };

    /// Park the calling transport worker until the journal advances, the
    /// deadline passes, or drain begins. Holds NO locks while parked (Q7).
    /// `observed_signal` must have been loaded BEFORE the caller's journal
    /// window read — that ordering is the missed-wake guarantee.
    fn parkForChanges(self: *Daemon, observed_signal: u32, deadline_ms: i64) ChangesParkOutcome {
        // Q7 parked-waiter cap: reserve a slot first; over-cap callers degrade
        // to an immediate heartbeat (never an error — pinned in the IT).
        const prev_parked = self.changes_parked.fetchAdd(1, .acquire);
        if (prev_parked >= platform_ipc.MAX_PARKED_LONG_POLL_WAITERS) {
            _ = self.changes_parked.fetchSub(1, .release);
            return .over_cap;
        }
        defer _ = self.changes_parked.fetchSub(1, .release);

        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        while (true) {
            if (self.changes_draining.load(.acquire)) return .drained;
            if (self.changes_signal.load(.acquire) != observed_signal) return .woken;
            const remaining = deadline_ms - nowMs();
            if (remaining <= 0) return .timed_out;
            io.futexWaitTimeout(u32, &self.changes_signal.raw, observed_signal, .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(remaining)),
                .clock = .awake,
            } }) catch {};
        }
    }

    fn removeSessionById(self: *Daemon, session_id: []const u8) bool {
        for (self.sessions.items, 0..) |session, index| {
            if (!std.mem.eql(u8, session.session_id, session_id)) continue;
            self.removeAt(index);
            return true;
        }
        return false;
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
        return try clientResponse(self.allocator, id_value, &self.registry, .register, client, 0);
    }

    fn clientHeartbeatResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const client_id = requiredObjectString(params, "client_id") catch |err| return self.registryErrorResponse(id_value, err);
        const accepted = self.registry.heartbeatClient(client_id, nowMs());
        if (!accepted) return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "client not found");
        const client = self.registry.client(client_id).?;
        return try clientResponse(self.allocator, id_value, &self.registry, .heartbeat, client, 0);
    }

    fn clientCloseResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const client_id = requiredObjectString(params, "client_id") catch |err| return self.registryErrorResponse(id_value, err);
        const now_ms = nowMs();
        const released_leases = self.registry.releaseLeasesForClient(self.allocator, client_id, now_ms);
        const closed = self.registry.closeClient(client_id, now_ms);
        if (!closed) return try errorResponseAlloc(self.allocator, id_value, headless.registry.ERR_RESOURCE_NOT_FOUND, "client not found");
        const client = self.registry.client(client_id).?;
        return try clientResponse(self.allocator, id_value, &self.registry, .close, client, released_leases);
    }

    fn daemonStopResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(headless.registry.DaemonStopRequest, self.allocator, params) catch
            return self.registryErrorResponse(id_value, error.InvalidParams);
        defer parsed.deinit();
        const request = parsed.value;
        if (request.client_id.len == 0) return self.registryErrorResponse(id_value, error.ClientNotFound);
        const client = self.registry.client(request.client_id) orelse return self.registryErrorResponse(id_value, error.ClientNotFound);
        if (client.closed) return self.registryErrorResponse(id_value, error.ClientClosed);

        const now_ms = nowMs();
        _ = self.registry.releaseLeasesForClient(self.allocator, request.client_id, now_ms);
        for (self.sessions.items) |session| {
            if (session.owner_client_id == null or !std.mem.eql(u8, session.owner_client_id.?, request.client_id)) continue;
            _ = session.terminate();
            self.noteSessionExitInRegistry(session, "daemon.stop", now_ms);
        }
        if (request.force) self.stopAllManagedProcessesInline(now_ms);
        _ = self.registry.closeClient(request.client_id, now_ms);

        const stopping = !self.hasLiveKeepAliveState();
        if (stopping) {
            // The drain thread owns provider cleanup and endpoint wake-up. Do
            // not duplicate those actions on this locked request path.
            self.shutdown_requested = true;
            self.accepting_mutations = false;
        }
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try writeRegistryEnvelope(&s, self);
        try s.objectField("accepted");
        try s.write(true);
        try s.objectField("stopping");
        try s.write(stopping);
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    /// Force-all stop is deliberately bounded to immediate terminate calls on
    /// the locked path. The drain thread observes actual exits and performs
    /// the normal cleanup/provider handoff afterward.
    fn stopAllManagedProcessesInline(self: *Daemon, now_ms: i64) void {
        var changed = false;
        for (self.registry.workspaces.items) |*workspace| {
            for (workspace.managed_processes.items) |*process| {
                switch (process.status) {
                    .starting, .running, .stopping => {},
                    .stopped, .crashed, .restarting => continue,
                }
                if (process.session_id) |session_id| {
                    if (self.find(session_id)) |session| _ = session.terminate();
                }
                process.transition(.stop, now_ms) catch continue;
                if (process.session_id) |session_id| self.allocator.free(session_id);
                process.session_id = null;
                process.pid = null;
                process.process_group = null;
                changed = true;
            }
        }
        if (changed) self.bumpRegistryRevision(.{ .topic = .process, .resource_id = "*" });
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
            error.ProcessNameRequired,
            => .{ headless.registry.ERR_INVALID_PARAMS, "invalid workspace or client parameters" },
            error.WorkspaceNotFound => .{ headless.registry.ERR_RESOURCE_NOT_FOUND, "workspace not found" },
            error.LeaseNotFound => .{ headless.registry.ERR_RESOURCE_NOT_FOUND, "lease not found" },
            error.ManagedProcessNotFound => .{ headless.registry.ERR_RESOURCE_NOT_FOUND, "managed process not found" },
            error.ClientNotFound => .{ headless.registry.ERR_INVALID_STATE, "client is not registered" },
            error.ClientClosed => .{ headless.registry.ERR_INVALID_STATE, "client is closed" },
            error.DaemonDraining => .{ headless.registry.ERR_INVALID_STATE, "daemon is preparing shutdown and is not accepting mutations" },
            error.OperationAlreadyInProgress => .{ headless.registry.ERR_INVALID_STATE, "operation already in progress" },
            error.InvalidManagedProcessTransition => .{ headless.registry.ERR_INVALID_STATE, "invalid managed process transition" },
            error.ManagedProcessCapacityExceeded => .{ headless.registry.ERR_INVALID_STATE, "managed process capacity exceeded" },
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
        const owner_client_id = if (jsonString(params.object.get("client_id") orelse .null)) |client_id| blk: {
            const client = self.registry.client(client_id) orelse
                return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "client_id is not registered");
            if (client.closed) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "client_id is closed");
            break :blk client_id;
        } else null;
        const session = try PtySession.create(self.allocator, .{
            .session_id = session_id,
            .project_id = jsonString(params.object.get("workspace_id") orelse params.object.get("project_id") orelse .null) orelse "",
            .project_path = jsonString(params.object.get("workspace_path") orelse params.object.get("project_path") orelse .null) orelse "",
            .owner_client_id = owner_client_id,
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

    /// Accept a new turn. Runs unlocked on the serve path (see
    /// `methodRunsUnlocked`) so the MAJOR-R1 ledger identity guard can consult
    /// SQLite under the store service mutex without ever nesting under
    /// lockDaemon. Takes lockDaemon only for the short in-memory critical
    /// sections (find/append + durability_pending arm).
    fn chatTurnStartResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        // Drain gate first (outranks invalid_params) so the mutator drain table
        // test and prepare-shutdown refuse path stay consistent for empty bodies.
        lockDaemon(self);
        if (!self.accepting_mutations) {
            self.mutex.unlock();
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                "invalid_state",
                "daemon is preparing shutdown and is not accepting mutations",
            );
        }
        self.mutex.unlock();

        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn_id = jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id");

        lockDaemon(self);
        if (!self.accepting_mutations) {
            self.mutex.unlock();
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                "invalid_state",
                "daemon is preparing shutdown and is not accepting mutations",
            );
        }
        if (self.findChatTurn(turn_id)) |turn| {
            const response = try okValueResponse(self.allocator, id_value, .{ .turn_id = turn.turn_id, .created = false });
            self.mutex.unlock();
            return response;
        }
        // Pointer grab only — SQLite for the ledger guard is outside lockDaemon.
        // MINOR-1 (pre-M5-P3): bump in_flight under the same lockDaemon as the
        // staging/commit siblings so finalize's drain sees this borrow before
        // requests can run off the accept thread.
        const service = self.store_service;
        if (service) |svc| _ = svc.in_flight.fetchAdd(1, .monotonic);
        self.mutex.unlock();

        // MAJOR-R1: reject replay of terminal committed turn_ids. Without this,
        // a fresh worker re-runs and commitTurn hits receipt Conflict ×3 →
        // durability_pending wedges permanently. Interrupted rows still allow
        // replay (sweep → re-commit upsert). Never SQLite under lockDaemon.
        if (service) |svc| {
            defer _ = svc.in_flight.fetchSub(1, .monotonic);
            if (try ledgerHasTerminalCommittedTurn(svc, turn_id)) {
                return try errorResponseAlloc(
                    self.allocator,
                    id_value,
                    headless.protocol.ERR_INVALID_STATE,
                    "turn already committed",
                );
            }
        }

        const turn = try createChatTurnFromParams(self.allocator, params);
        errdefer turn.deinit(self.allocator);

        lockDaemon(self);
        // Re-check after the unlocked ledger window (concurrent start / race).
        if (self.findChatTurn(turn_id)) |existing| {
            const response = try okValueResponse(self.allocator, id_value, .{ .turn_id = existing.turn_id, .created = false });
            self.mutex.unlock();
            turn.deinit(self.allocator);
            return response;
        }
        if (!self.accepting_mutations) {
            self.mutex.unlock();
            turn.deinit(self.allocator);
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                "invalid_state",
                "daemon is preparing shutdown and is not accepting mutations",
            );
        }
        // MINOR-3: arm durability_pending at acceptance under lockDaemon so
        // consume cannot TOCTOU a terminal status published before finalize.
        if (self.store_service != null) turn.durability_pending = true;
        self.chat_turns.append(self.allocator, turn) catch |err| {
            self.mutex.unlock();
            return err;
        };
        // Staging runs on the worker thread: store I/O never under lockDaemon.
        // On spawn failure, drop the turn and release lockDaemon before return.
        const thread = std.Thread.spawn(.{}, chatTurnThread, .{ self, turn }) catch |err| {
            _ = self.chat_turns.pop();
            turn.deinit(self.allocator);
            self.mutex.unlock();
            return err;
        };
        turn.worker_thread = thread;
        self.mutex.unlock();
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
        const followup_pending = jsonBool(params.object.get("followup_pending") orelse .null) orelse false;
        lockTurn(turn);
        turn.cancel_requested = true;
        turn.followup_pending = followup_pending;
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
            // Durable-before-consume: refuse until the store receipt lands.
            if (turn.durability_pending) {
                turn.mutex.unlock();
                return try errorResponseAlloc(
                    self.allocator,
                    id_value,
                    headless.protocol.ERR_INVALID_STATE,
                    "turn durability is still pending",
                );
            }
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

fn resourceLimitErrorResponse(
    self: *Daemon,
    id_value: std.json.Value,
    resource: []const u8,
    limit: usize,
) ![]u8 {
    var data_writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer data_writer.deinit();
    var data_stringify: std.json.Stringify = .{ .writer = &data_writer.writer, .options = .{} };
    try data_stringify.beginObject();
    try data_stringify.objectField("resource");
    try data_stringify.write(resource);
    try data_stringify.objectField("limit");
    try data_stringify.write(limit);
    try data_stringify.endObject();
    const data_json = try data_writer.toOwnedSlice();
    defer self.allocator.free(data_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return try errorResponseAllocWithData(
        self.allocator,
        id_value,
        headless.registry.ERR_INVALID_STATE,
        "process operation exceeds a configured resource limit",
        parsed.value,
    );
}

fn prepareShutdownRefusalResponse(
    self: *Daemon,
    id_value: std.json.Value,
    running_sessions: usize,
    managed: usize,
    turns: usize,
    leases: usize,
    registry_jobs: usize,
) ![]u8 {
    var data_writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer data_writer.deinit();
    var data_stringify: std.json.Stringify = .{ .writer = &data_writer.writer, .options = .{} };
    try data_stringify.beginObject();
    try data_stringify.objectField("running_sessions");
    try data_stringify.write(running_sessions);
    try data_stringify.objectField("managed");
    try data_stringify.write(managed);
    try data_stringify.objectField("turns");
    try data_stringify.write(turns);
    try data_stringify.objectField("leases");
    try data_stringify.write(leases);
    try data_stringify.objectField("registry_jobs");
    try data_stringify.write(registry_jobs);
    try data_stringify.endObject();
    const data_json = try data_writer.toOwnedSlice();
    defer self.allocator.free(data_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const message = try std.fmt.allocPrint(
        self.allocator,
        "daemon cannot prepare shutdown: running_sessions={d} managed={d} turns={d} leases={d} registry_jobs={d}",
        .{ running_sessions, managed, turns, leases, registry_jobs },
    );
    defer self.allocator.free(message);
    return try errorResponseAllocWithData(
        self.allocator,
        id_value,
        headless.registry.ERR_INVALID_STATE,
        message,
        parsed.value,
    );
}

/// Store-specific prepare refusal (registry gates already clear). Additive
/// Error.data field matches the W6 structured-reason style.
fn prepareShutdownStoreRefusalResponse(
    self: *Daemon,
    id_value: std.json.Value,
    store_writes_in_flight: usize,
) ![]u8 {
    var data_writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer data_writer.deinit();
    var data_stringify: std.json.Stringify = .{ .writer = &data_writer.writer, .options = .{} };
    try data_stringify.beginObject();
    try data_stringify.objectField("store_writes_in_flight");
    try data_stringify.write(store_writes_in_flight);
    try data_stringify.endObject();
    const data_json = try data_writer.toOwnedSlice();
    defer self.allocator.free(data_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const message = try std.fmt.allocPrint(
        self.allocator,
        "daemon cannot prepare shutdown: store_writes_in_flight={d}",
        .{store_writes_in_flight},
    );
    defer self.allocator.free(message);
    return try errorResponseAllocWithData(
        self.allocator,
        id_value,
        headless.registry.ERR_INVALID_STATE,
        message,
        parsed.value,
    );
}

fn configUnavailableErrorResponse(
    self: *Daemon,
    id_value: std.json.Value,
    detail: []const u8,
) ![]u8 {
    var data_writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer data_writer.deinit();
    var data_stringify: std.json.Stringify = .{ .writer = &data_writer.writer, .options = .{} };
    try data_stringify.beginObject();
    try data_stringify.objectField("error");
    try data_stringify.write(detail);
    try data_stringify.endObject();
    const data_json = try data_writer.toOwnedSlice();
    defer self.allocator.free(data_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return try errorResponseAllocWithData(
        self.allocator,
        id_value,
        headless.registry.ERR_INVALID_STATE,
        "workspace config unavailable",
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
    // Managed/tracked snapshots intentionally omit owner_kind/owner_title/
    // client_id/generation; those fields exist on the external+turn shape
    // only. Value-based consumers ignore missing keys; full array shape
    // convergence is a follow-up, not this adapter's job.
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

/// Projects a live chat turn as an external-process snapshot (A1 adapter).
/// Derivation only: no registry storage or RPC surface. Consumers distinguish
/// these external-shaped records from stored records by the `turn:` id prefix.
fn writeChatTurnProcessSnapshot(s: *std.json.Stringify, turn: *const ChatTurn) !void {
    const process_id = try std.fmt.allocPrint(turn.allocator, "turn:{s}", .{turn.turn_id});
    defer turn.allocator.free(process_id);
    const owner_title = if (turn.request.thread_title.len != 0) turn.request.thread_title else turn.turn_id;
    // Durable-first: external process projection matches tail/list publication.
    const status = chatTurnExternalStatus(chatTurnPublishedStatus(turn));

    try s.beginObject();
    try s.objectField("id");
    try s.write(process_id);
    try s.objectField("workspace_id");
    try s.write(turn.workspace_id);
    try s.objectField("workspace_path");
    try s.write(turn.request.project_path);
    try s.objectField("source");
    try s.write("external");
    try s.objectField("kind");
    try s.write("external");
    try s.objectField("name");
    try s.write("");
    try s.objectField("owner");
    try s.write(owner_title);
    try s.objectField("owner_session_id");
    try s.write(null);
    // These fields are part of the external-process shape; ChatTurn does not
    // currently carry a client binding, so that part of the adapter is empty.
    try s.objectField("owner_kind");
    try s.write("gui_agent");
    try s.objectField("owner_title");
    try s.write(owner_title);
    try s.objectField("client_id");
    try s.write("");
    // ExternalProcess storage remains unused by this adapter; P3 owns the
    // future RPC-backed replacement for these derived turn records.
    try s.objectField("generation");
    try s.write(@as(u64, 0));
    // Spec: command = provider/prompt summary if one exists, else "". Request
    // has no summary field; embedding the full prompt would unbounded-grow
    // process.list (see writeChatTurnSummary, which also omits the prompt).
    try s.objectField("command");
    try s.write("");
    try s.objectField("cwd");
    try s.write(turn.request.project_path);
    try s.objectField("status");
    try s.write(@tagName(status));
    try s.objectField("classification");
    try s.write(@tagName(process_registry.classifyWorkspaceCommand("")));
    try s.objectField("resources");
    try s.beginArray();
    try s.endArray();
    try s.objectField("pid");
    try s.write(null);
    try s.objectField("process_group");
    try s.write(null);
    try s.objectField("dock_id");
    try s.write(null);
    try s.objectField("pane_id");
    try s.write(null);
    try s.objectField("created_at_ms");
    try s.write(turn.started_at_ms);
    try s.objectField("started_at_ms");
    try s.write(turn.started_at_ms);
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
    try s.write(status == .failed);
    try s.endObject();
}

fn chatTurnExternalStatus(status: ChatTurnStatus) process_registry.ExternalProcessStatus {
    return switch (status) {
        .running, .waiting_approval => .running,
        .completed => .completed,
        .failed => .failed,
        .aborted => .cancelled,
    };
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
    try s.objectField("owner_kind");
    try s.write(process.owner_kind);
    try s.objectField("owner_title");
    try s.write(process.owner_title);
    try s.objectField("client_id");
    try s.write(process.client_id);
    try s.objectField("generation");
    try s.write(process.generation);
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
    released_leases: usize,
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
            try s.write(@as(u32, @intCast(released_leases)));
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

    var daemon = Daemon.initWithPrefPath(allocator, pref_path);
    defer daemon.deinit();
    // M5-P2 journal hook: volatile revision bumps publish identity entries.
    // `&daemon` is stable for the daemon's whole lifetime (A3: production
    // default, not hermetic-gated; capability flags stay false regardless).
    daemon.registry.revision_hook = .{ .context = &daemon, .notify = registryRevisionHookNotify };
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
        // Transfer commit + store close run here — after accept exits AND
        // after every transport worker is quiesced/joined, before ipc.serve's
        // endpoint teardown defers release the socket/lock.
        .on_closing = sessionizerServerClosing,
        // Runs before workers are joined: wakes parked core.changes waiters
        // so quiesce is bounded by request work, never by a parked long-poll.
        .on_draining = sessionizerServerDraining,
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
    // Open the production (or hermetic-override) store only after bind succeeds
    // so a failed open fails readiness loudly (never a silent dual-writer).
    try maybeInitStoreService(context.daemon);
    context.drain_thread = try std.Thread.spawn(.{}, drainSessionsThread, .{DrainThreadContext{
        .daemon = context.daemon,
        .endpoint = context.endpoint,
        .stop_requested = context.stop_requested,
    }});
}

/// Invoked by platform_ipc.serve after the accept loop exits, BEFORE the
/// transport worker pool is joined (M5-P3). A `core.changes` long-poll parked
/// on a worker thread holds that worker; waking it here (with the structured
/// drain response) is what makes the subsequent worker join bounded.
fn sessionizerServerDraining(raw_context: *anyopaque) void {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    context.daemon.beginChangesDrain();
}

/// Invoked by platform_ipc.serve after the accept loop exits and every
/// transport worker is quiesced/joined (on_draining above ran first), and
/// before its endpoint teardown defers run. Join the drain thread and
/// finalize the store transfer while this process still holds exclusive
/// endpoint ownership.
fn sessionizerServerClosing(raw_context: *anyopaque) void {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    context.stop_requested.store(true, .release);
    joinDrainThread(context);
    finalizeSessionizerStore(context);
}

/// Full store mutation surface plus storeStatus (S3) and M4 durable chat reads.
fn isStoreMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, store_protocol.METHOD_STATE_SNAPSHOT_REPLACE) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_MESSAGE_APPEND) or
        std.mem.eql(u8, method, store_protocol.METHOD_SURFACE_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_SURFACE_CLEAR) or
        std.mem.eql(u8, method, store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR) or
        std.mem.eql(u8, method, store_protocol.METHOD_DAEMON_STORE_STATUS) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_GET) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_LIST) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_TURN_RECORD) or
        // M5-P2: the composite snapshot and cursor route through the same
        // classify → store-queue seam (A1) so they never run under the outer
        // lockDaemon window and own their lock choreography.
        std.mem.eql(u8, method, store_protocol.METHOD_CORE_SNAPSHOT) or
        std.mem.eql(u8, method, changes_protocol.METHOD_CORE_CHANGES);
}

/// Registry bump topics → journal topics. `.client` returns null: client
/// records are registry bookkeeping, not part of the frozen Q10 topic set.
fn journalTopicFromBumpTopic(topic: process_registry.BumpTopic) ?change_journal.Topic {
    return switch (topic) {
        .client => null,
        .workspace => .workspace,
        .process => .process,
        .lease => .lease,
        .notification => .notification,
        .chat_turn => .chat_turn,
    };
}

/// ProcessRegistry revision hook: runs at the bump site under lockDaemon; the
/// journal append itself takes only the journal leaf lock.
fn registryRevisionHookNotify(context: *anyopaque, event: process_registry.RevisionBumpEvent, registry_revision: u64) void {
    const daemon: *Daemon = @ptrCast(@alignCast(context));
    const topic = journalTopicFromBumpTopic(event.topic) orelse return;
    daemon.appendJournalEntry(topic, event.resource_id, event.workspace_id, .{ .registry = registry_revision });
}

/// Store post-commit hook (mutations). Fires only after a durable commit —
/// never for receipt replays, message-key duplicates, or rollbacks — so every
/// journal entry corresponds to exactly one committed store_revision.
fn storeMutationCommittedHook(context: *anyopaque, mutation: *const daemon_store.Mutation, result: store_protocol.WriteResult) void {
    const daemon: *Daemon = @ptrCast(@alignCast(context));
    const revision: change_journal.Revision = .{ .store = result.store_revision };
    switch (mutation.*) {
        .snapshot_replace => |request| {
            // A whole-state replace may touch every durable resource; publish
            // identity entries for each carried workspace/thread/completion.
            for (request.snapshot.workspaces) |workspace| {
                daemon.appendJournalEntry(.workspace, workspace.workspace_id, workspace.workspace_id, revision);
                for (workspace.threads) |thread| {
                    daemon.appendJournalEntry(.chat_thread, thread.local_thread_id, workspace.workspace_id, revision);
                }
            }
            for (request.snapshot.chat_completions) |completion| {
                daemon.appendJournalEntry(.chat_completion, completion.local_thread_id, completion.workspace_id, revision);
            }
            // M5-P4 Amendment 3 (M5-P3 verify MAJOR): carried surfaces must
            // journal like every other carried resource, matching the
            // surface_upsert arm below.
            for (request.snapshot.surface_states) |surface| {
                daemon.appendJournalEntry(
                    .surface,
                    surface.session_id,
                    if (surface.workspace_id.len != 0) surface.workspace_id else null,
                    revision,
                );
            }
            // MAJOR-2 (M5-P3 amendment): a replace DELETES everything it does
            // not carry — including the empty replace, which carries nothing —
            // so per-resource entries alone leave deletions cursor-invisible
            // and clients would keep deleted workspaces forever. Publish one
            // batch entry with the registry "*" convention ("re-read the
            // topic", process_registry.RevisionBumpEvent) so every replace is
            // observable via core.changes — on EVERY store-plane topic a
            // replace can delete from, or topic-filtered cursors (e.g.
            // {surface}, or chat topics without workspace) would go silently
            // stale forever across a snapshot_replace (M5-P4 Amendment 3).
            daemon.appendJournalEntry(.workspace, "*", null, revision);
            daemon.appendJournalEntry(.chat_thread, "*", null, revision);
            // Snapshot tombstoning may remove workspace-owned turn records;
            // the durable replay guard is separate, but chat.turn projection
            // subscribers must still re-read after the committed deletion.
            daemon.appendJournalEntry(.chat_turn, "*", null, revision);
            daemon.appendJournalEntry(.chat_completion, "*", null, revision);
            daemon.appendJournalEntry(.surface, "*", null, revision);
        },
        .workspace_upsert => |request| daemon.appendJournalEntry(.workspace, request.workspace.workspace_id, request.workspace.workspace_id, revision),
        .thread_upsert => |request| daemon.appendJournalEntry(.chat_thread, request.thread.local_thread_id, request.workspace_id, revision),
        .message_append => |request| daemon.appendJournalEntry(.chat_thread, request.thread_id, request.workspace_id, revision),
        // MAJOR-1 (M5-P3 amendment): store commits are the ONLY surface
        // publisher (the registry has no surface records or bump variant), so
        // these must journal or a surface-topic cursor is silently stale
        // forever. revisionPolicy(.surface) is store_only to match.
        .surface_upsert => |request| daemon.appendJournalEntry(
            .surface,
            request.surface.session_id,
            if (request.surface.workspace_id.len != 0) request.surface.workspace_id else null,
            revision,
        ),
        .surface_clear => |request| daemon.appendJournalEntry(.surface, request.session_id, request.workspace_id, revision),
        .chat_completion_upsert => |request| daemon.appendJournalEntry(.chat_completion, request.completion.local_thread_id, request.completion.workspace_id, revision),
        .chat_completion_clear => |request| daemon.appendJournalEntry(.chat_completion, request.local_thread_id, request.workspace_id, revision),
    }
}

/// Store post-commit hook (turn commits, A2). Journals lifecycle + transcript
/// identity only — never streaming deltas (Q10). Replayed duplicate receipts
/// return before the hook, so they cannot append a second entry.
fn storeTurnCommittedHook(context: *anyopaque, request: *const daemon_store.TurnCommitRequest, result: store_protocol.WriteResult) void {
    const daemon: *Daemon = @ptrCast(@alignCast(context));
    const revision: change_journal.Revision = .{ .store = result.store_revision };
    daemon.appendJournalEntry(.chat_thread, request.local_thread_id, request.workspace_id, revision);
    daemon.appendJournalEntry(.chat_turn, request.turn_id, request.workspace_id, revision);
    // commitTurn writes a completion ledger row whenever the turn completed
    // (deriving one if the request omitted it); mirror that exactly.
    if (request.status == .completed) {
        daemon.appendJournalEntry(.chat_completion, request.local_thread_id, request.workspace_id, revision);
    }
}

fn mutationHeader(mutation: daemon_store.Mutation) store_protocol.MutationHeader {
    return switch (mutation) {
        .snapshot_replace => |request| request.mutation,
        .workspace_upsert => |request| request.mutation,
        .thread_upsert => |request| request.mutation,
        .message_append => |request| request.mutation,
        .surface_upsert => |request| request.mutation,
        .surface_clear => |request| request.mutation,
        .chat_completion_upsert => |request| request.mutation,
        .chat_completion_clear => |request| request.mutation,
    };
}

/// Path-valued store-dir override. Caller frees a non-null result.
/// OutOfMemory propagates so a broken/oom test store fails readiness loudly
/// Hermetic store-dir override. Missing/empty → null (use production pref_path).
fn storeDirFromEnv(allocator: std.mem.Allocator) !?[]u8 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_STORE_DIR_ENV_NAME) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return null,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.len == raw.len) return raw;
    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(raw);
        return error.OutOfMemory;
    };
    allocator.free(raw);
    return owned;
}

/// Test-only store disable (keeps store-less IT / unit pins alive after P3).
fn storeDisabledFromEnv(allocator: std.mem.Allocator) !bool {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_STORE_DISABLE_ENV_NAME) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return false,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "0")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    return true;
}

/// Parse B9 store fault arm. Only active with the hermetic store-dir override.
/// Missing/empty → `.none`. Unknown tag name → error (fail readiness loudly).
fn storeFaultFromEnv(allocator: std.mem.Allocator) !daemon_store.StoreFault {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_STORE_FAULT_ENV_NAME) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return .none,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidParams,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .none;
    inline for (std.meta.fields(daemon_store.StoreFault)) |field| {
        if (std.mem.eql(u8, trimmed, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidParams;
}

/// Post-bind store open: production uses `{pref_path}/state.sqlite`; hermetic
/// tests may redirect via VERDE_SESSION_DAEMON_STORE_DIR or disable via
/// VERDE_SESSION_DAEMON_STORE_DISABLE. Runs the shared migration chain and
/// advertises store=true only after the writer is published.
fn maybeInitStoreService(daemon: *Daemon) !void {
    // NIT-2: a stray VERDE_SESSION_DAEMON_STORE_DISABLE in a user session is
    // production-latent (GUI read-only, notify hard-fails). Loud warn so the
    // knob is deliberate at runtime, not only in comments.
    if (try storeDisabledFromEnv(daemon.allocator)) {
        log.warn(
            "store disabled by env — daemon is store-less; GUI read-only, notify will fail",
            .{},
        );
        return;
    }

    const override_dir = try storeDirFromEnv(daemon.allocator);
    defer if (override_dir) |dir| daemon.allocator.free(dir);

    const store_dir = override_dir orelse blk: {
        // NIT-1: never silently store-less. Empty pref_path is unreachable in
        // production (__session-daemon always passes a real path) but a quiet
        // fallback here would contradict the loud-fail readiness rule.
        if (daemon.pref_path.len == 0) {
            log.err("production store open requires non-empty pref_path", .{});
            return error.InvalidParams;
        }
        break :blk daemon.pref_path;
    };
    // B9: fault env is active only alongside the hermetic store-dir override.
    const fault = if (override_dir != null) try storeFaultFromEnv(daemon.allocator) else daemon_store.StoreFault.none;
    const db_path = try std.fs.path.join(daemon.allocator, &.{ store_dir, "state.sqlite" });
    defer daemon.allocator.free(db_path);

    const service = try daemon.allocator.create(StoreService);
    errdefer daemon.allocator.destroy(service);
    service.* = .{
        .store = try daemon_store.Store.initWithFault(daemon.allocator, db_path, fault),
    };
    errdefer service.store.deinit();
    // M5-P2 journal hook: every durable commit (mutations AND turn commits)
    // publishes identity entries post-commit. Installed before the service is
    // published so no committed write can slip past the journal.
    service.store.commit_hook = .{
        .context = daemon,
        .on_mutation_committed = storeMutationCommittedHook,
        .on_turn_committed = storeTurnCommittedHook,
    };

    // Successor path: import+prune after endpoint ownership, seed the registry,
    // then publish the service. Drain has not started yet (ready callback).
    var imported = try service.store.importLeasesAndOutcomes(nowMs());
    defer imported.deinit(daemon.allocator);
    try seedRegistryFromTransfer(daemon, &imported);

    // Crash recovery: any non-terminal ledger rows left by a killed predecessor
    // become `interrupted` before the writer is published.
    try sweepInterruptedChatTurns(&service.store);

    lockDaemon(daemon);
    daemon.store_service = service;
    daemon.mutex.unlock();
}

/// Mark dangling non-terminal ledger rows interrupted. Runs under the store
/// open path before the service is published; no lockDaemon. Propagates so a
/// failed sweep fails readiness loudly (NIT-4).
fn sweepInterruptedChatTurns(store: *daemon_store.Store) !void {
    const finished_at = nowMs();
    store.conn.exec(
        \\update chat_turns
        \\set status = 'interrupted',
        \\    finished_at_ms = coalesce(finished_at_ms, ?1)
        \\where status in ('accepted', 'running', 'waiting_approval')
    ,
        .{finished_at},
    ) catch |err| {
        log.err("interrupted-turn sweep failed err={s}", .{@errorName(err)});
        return mapStageStoreError(err);
    };
}

/// Stage a running ledger row (+ optional user message) at turn acceptance.
/// Store I/O only under the service mutex; never under lockDaemon.
fn stageAcceptedChatTurn(daemon: *Daemon, turn: *ChatTurn) !void {
    // MINOR-5(a): bump in_flight under lockDaemon (match dispatch spine) so
    // finalize cannot destroy the service while this pointer is live.
    lockDaemon(daemon);
    const service = daemon.store_service;
    if (service) |svc| _ = svc.in_flight.fetchAdd(1, .monotonic);
    daemon.mutex.unlock();
    const svc = service orelse return;
    defer _ = svc.in_flight.fetchSub(1, .monotonic);

    var arena_state: std.heap.ArenaAllocator = .init(daemon.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const turn_id = try arena.dupe(u8, turn.turn_id);
    const workspace_id = try arena.dupe(u8, turn.workspace_id);
    const local_thread_id = try arena.dupe(u8, turn.local_thread_id);
    const project_path = try arena.dupe(u8, turn.request.project_path);
    const provider = try arena.dupe(u8, @tagName(turn.request.provider));
    const thread_title = try arena.dupe(u8, turn.request.thread_title);
    const prompt = try arena.dupe(u8, turn.request.prompt);
    const user_message_id = if (turn.user_message_id) |id|
        try arena.dupe(u8, id)
    else
        try std.fmt.allocPrint(arena, "turn:{s}:user", .{turn_id});
    const started_at_ms = turn.started_at_ms;

    lockStoreService(svc);
    defer svc.mutex.unlock();

    const ws_key = try std.fmt.allocPrint(arena, "turn:{s}:stage-ws", .{turn_id});
    _ = svc.store.upsertWorkspace(.{
        .mutation = .{ .request_key = ws_key, .client_id = "daemon" },
        .workspace = .{
            .workspace_id = workspace_id,
            .label = workspace_id,
            .path = project_path,
        },
    }) catch |err| return err;

    const thread_key = try std.fmt.allocPrint(arena, "turn:{s}:stage-thread", .{turn_id});
    _ = svc.store.upsertThread(.{
        .mutation = .{ .request_key = thread_key, .client_id = "daemon" },
        .workspace_id = workspace_id,
        .thread = .{
            .local_thread_id = local_thread_id,
            .title = if (thread_title.len != 0) thread_title else local_thread_id,
            .provider = provider,
            .harness = @tagName(turn.request.harness_kind),
        },
    }) catch |err| return err;

    const msg_key = try std.fmt.allocPrint(arena, "turn:{s}:stage-user", .{turn_id});
    _ = svc.store.appendMessage(.{
        .mutation = .{ .request_key = msg_key, .client_id = "daemon" },
        .workspace_id = workspace_id,
        .thread_id = local_thread_id,
        .message = .{
            .message_id = user_message_id,
            .role = "user",
            .author = "You",
            .body = prompt,
            .created_at_ms = started_at_ms,
            .updated_at_ms = started_at_ms,
        },
    }) catch |err| switch (err) {
        // Legal stable-turn_id replay (interrupted sweep): the originally
        // staged user row keeps its identity; drifted prompt/timestamps must
        // not fail acceptance (first-writer-wins — commitTurn's F1 upsert
        // skips the identity-matched row the same way).
        error.Conflict => {},
        else => return err,
    };

    // Ledger stage is not receipt-backed: the terminal commitTurn path upserts
    // the durable terminal row over any staged / interrupted ledger row.
    svc.store.conn.exec(
        \\insert or ignore into chat_turns (
        \\  turn_id, workspace_id, local_thread_id, status, started_at_ms,
        \\  provider, user_message_id
        \\) values (?1, ?2, ?3, 'running', ?4, ?5, ?6)
    ,
        .{ turn_id, workspace_id, local_thread_id, started_at_ms, provider, user_message_id },
    ) catch |err| return mapStageStoreError(err);

    // Mirror the staged id back onto the in-memory turn when it was generated.
    if (turn.user_message_id == null) {
        lockTurn(turn);
        defer turn.mutex.unlock();
        if (turn.user_message_id == null) {
            turn.user_message_id = daemon.allocator.dupe(u8, user_message_id) catch null;
        }
    }
}

fn mapStageStoreError(err: anyerror) daemon_store.StoreError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.StoreUnavailable,
    };
}

/// Process-global one-shot for VERDE_SESSION_DAEMON_CHAT_COMMIT_FAULT=fail_once.
/// Consumed on first armed check; subsequent calls return false.
var chat_commit_fault_once_consumed = std.atomic.Value(bool).init(false);

/// Hermetic-only: true when store-dir override is set AND commit-fault env is
/// `fail_once` (one-shot) or `fail_always` (every attempt). Does not touch
/// SQLite; caller returns StoreBusy for the bounded-retry path.
fn chatCommitFaultOnceShouldFail(allocator: std.mem.Allocator) bool {
    const override_dir = storeDirFromEnv(allocator) catch return false;
    defer if (override_dir) |dir| allocator.free(dir);
    if (override_dir == null) return false;

    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_CHAT_COMMIT_FAULT_ENV_NAME) catch return false;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "fail_always")) return true;
    if (!std.mem.eql(u8, trimmed, "fail_once")) return false;

    // swap true → already consumed; false → first call, consume and fail.
    return !chat_commit_fault_once_consumed.swap(true, .monotonic);
}

/// MAJOR-R1 ledger identity guard: true when the durable ledger already has a
/// terminal committed row for `turn_id` (completed/failed/aborted). Interrupted
/// / running / accepted rows return false so same-id replay after a crash sweep
/// remains legal. SQLite under the store service mutex only — never lockDaemon.
fn ledgerHasTerminalCommittedTurn(service: *StoreService, turn_id: []const u8) !bool {
    lockStoreService(service);
    defer service.mutex.unlock();
    const row_or_null = service.store.conn.row(
        "select status from terminal_turn_replay_guard where turn_id = ?1",
        .{turn_id},
    ) catch return error.StoreUnavailable;
    const row = row_or_null orelse return false;
    defer row.deinit();
    const status = row.text(0);
    return std.mem.eql(u8, status, "completed") or
        std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "aborted");
}

/// Apply transcript_apply and commitTurn outside lockDaemon. Caller must not
/// hold the turn lock. Sets committed_store_revision and clears durability_pending
/// on success; leaves durability_pending set on failure (caller may retry).
fn commitChatTurnDurable(daemon: *Daemon, turn: *ChatTurn) !void {
    var arena_state: std.heap.ArenaAllocator = .init(daemon.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Snapshot turn state under the turn lock only (no SQLite).
    lockTurn(turn);
    const turn_id = try arena.dupe(u8, turn.turn_id);
    const workspace_id = try arena.dupe(u8, turn.workspace_id);
    const local_thread_id = try arena.dupe(u8, turn.local_thread_id);
    const provider = try arena.dupe(u8, @tagName(turn.request.provider));
    const project_path = try arena.dupe(u8, turn.request.project_path);
    const thread_title = try arena.dupe(u8, turn.request.thread_title);
    const harness_kind = @tagName(turn.request.harness_kind);
    const started_at_ms = turn.started_at_ms;
    const finished_at_ms = turn.finished_at_ms orelse nowMs();
    const followup_pending = turn.followup_pending;
    const status = turn.status;
    const user_message_id = if (turn.user_message_id) |id| try arena.dupe(u8, id) else null;
    const prompt = try arena.dupe(u8, turn.request.prompt);
    const provider_thread_id = if (turn.provider_thread_id) |id| try arena.dupe(u8, id) else null;
    const error_message = if (turn.error_message) |msg| try arena.dupe(u8, msg) else null;
    const reply_text = if (turn.result_reply_text) |text| try arena.dupe(u8, text) else "";
    var events = try arena.alloc(transcript_apply.ChatEvent, turn.events.items.len);
    for (turn.events.items, 0..) |event, index| {
        events[index] = .{
            .kind = try arena.dupe(u8, event.kind),
            .payload_json = try arena.dupe(u8, event.payload_json),
        };
    }
    turn.mutex.unlock();

    const store_status: daemon_store.TurnStatus = switch (status) {
        .completed => .completed,
        .failed => .failed,
        .aborted => .aborted,
        .running, .waiting_approval => .interrupted,
    };
    const outcome: transcript_apply.WorkerOutcome = .{
        .status = switch (store_status) {
            .completed => .completed,
            .failed => .failed,
            .aborted => .aborted,
            .interrupted => .interrupted,
            else => .failed,
        },
        .provider = provider,
        .reply_text = reply_text,
        .failure_message = error_message,
        .error_message = error_message,
        .followup_pending = followup_pending,
    };
    const applied = try transcript_apply.apply(arena, events, outcome);
    // Amendment-2 F1: terminal commit is self-healing for the user row.
    // insertTurnMessages is idempotent by message_id (skip existing non-conflict),
    // so a successful staging leaves this prepend as a no-op; a missed staging
    // still lands the acceptance-keyed user message in the same transaction.
    const messages: []const store_protocol.Message = blk: {
        const uid = user_message_id orelse break :blk applied;
        var all = try arena.alloc(store_protocol.Message, applied.len + 1);
        all[0] = .{
            .message_id = uid,
            .role = "user",
            .author = "You",
            .body = prompt,
            .created_at_ms = started_at_ms,
            .updated_at_ms = started_at_ms,
        };
        @memcpy(all[1..], applied);
        break :blk all;
    };

    // 2. Short lockDaemon for service pointer + in_flight only (MINOR-5(a)).
    lockDaemon(daemon);
    const service = daemon.store_service orelse {
        daemon.mutex.unlock();
        // Store closed between check and commit: clear pending so the turn
        // does not keep the daemon alive forever without a writer, but flag
        // the lost commit (MINOR-4).
        lockTurn(turn);
        turn.durability_pending = false;
        if (turn.durability_error) |old| daemon.allocator.free(old);
        turn.durability_error = daemon.allocator.dupe(u8, "store_closed") catch null;
        turn.mutex.unlock();
        return;
    };
    _ = service.in_flight.fetchAdd(1, .monotonic);
    daemon.mutex.unlock();
    defer _ = service.in_flight.fetchSub(1, .monotonic);

    // Hermetic one-shot fault: fail before any SQLite under the store lock.
    if (chatCommitFaultOnceShouldFail(daemon.allocator)) return error.StoreBusy;

    // 3. SQLite under the store service lock only.
    lockStoreService(service);
    defer service.mutex.unlock();

    const ws_key = try std.fmt.allocPrint(arena, "turn:{s}:commit-ws", .{turn_id});
    _ = try service.store.upsertWorkspace(.{
        .mutation = .{ .request_key = ws_key, .client_id = "daemon" },
        .workspace = .{
            .workspace_id = workspace_id,
            .label = workspace_id,
            .path = project_path,
        },
    });
    const thread_key = try std.fmt.allocPrint(arena, "turn:{s}:commit-thread", .{turn_id});
    _ = try service.store.upsertThread(.{
        .mutation = .{ .request_key = thread_key, .client_id = "daemon" },
        .workspace_id = workspace_id,
        .thread = .{
            .local_thread_id = local_thread_id,
            .title = if (thread_title.len != 0) thread_title else local_thread_id,
            .provider = provider,
            .harness = harness_kind,
            .provider_thread_id = provider_thread_id,
        },
    });

    // commitTurn upserts the ledger row over any staged/interrupted row
    // (insertTurnLedger ON CONFLICT). No external pre-delete (MAJOR-1/2).

    // commitTurn uses conn.commit() (not commitWithFault). Inject the stall
    // only on this path so turn-commit latency ITs exercise the worker-thread
    // store seam without multiplying the upsert stalls already applied above.
    if (service.store.fault == .commit_stall) {
        platform_runtime.sleepMillis(daemon_store.STORE_FAULT_COMMIT_STALL_MS);
    }

    const write_result = try service.store.commitTurn(.{
        .turn_id = turn_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .status = store_status,
        .started_at_ms = started_at_ms,
        .finished_at_ms = finished_at_ms,
        .provider = provider,
        .provider_thread_id = provider_thread_id,
        .error_message = error_message,
        .user_message_id = user_message_id,
        .messages = messages,
        .followup_pending = followup_pending,
        .completion = if (store_status == .completed) .{
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
            .completed_at_ms = finished_at_ms,
        } else null,
        .client_id = "daemon",
    });

    // 4. Publish revision on the turn after the receipt. The store service
    // mutex is still held here (defer releases at fn exit); store→turn nesting
    // is globally consistent (NIT-1).
    lockTurn(turn);
    turn.committed_store_revision = write_result.store_revision;
    turn.durability_pending = false;
    turn.mutex.unlock();
}

fn loadTurnRecord(
    allocator: std.mem.Allocator,
    store: *daemon_store.Store,
    request: store_protocol.TurnRecordRequest,
) daemon_store.StoreError!store_protocol.TurnRecord {
    if (request.turn_id.len == 0) return error.InvalidParams;
    const row_or_null = store.conn.row(
        \\select turn_id, workspace_id, local_thread_id, status, started_at_ms,
        \\       finished_at_ms, provider, provider_thread_id, error_message,
        \\       user_message_id, committed_store_revision
        \\from chat_turns where turn_id = ?1
    ,
        .{request.turn_id},
    ) catch return error.StoreUnavailable;
    const row = row_or_null orelse return error.ResourceNotFound;
    defer row.deinit();

    const turn_id = allocator.dupe(u8, row.text(0)) catch return error.OutOfMemory;
    errdefer allocator.free(turn_id);
    const workspace_id = allocator.dupe(u8, row.text(1)) catch return error.OutOfMemory;
    errdefer allocator.free(workspace_id);
    const local_thread_id = allocator.dupe(u8, row.text(2)) catch return error.OutOfMemory;
    errdefer allocator.free(local_thread_id);
    const status = allocator.dupe(u8, row.text(3)) catch return error.OutOfMemory;
    errdefer allocator.free(status);
    const provider = allocator.dupe(u8, row.text(6)) catch return error.OutOfMemory;
    errdefer allocator.free(provider);
    const provider_thread_id = dupeOptionalText(allocator, row.nullableText(7)) catch return error.OutOfMemory;
    errdefer if (provider_thread_id) |value| allocator.free(value);
    const error_message = dupeOptionalText(allocator, row.nullableText(8)) catch return error.OutOfMemory;
    errdefer if (error_message) |value| allocator.free(value);
    const user_message_id = dupeOptionalText(allocator, row.nullableText(9)) catch return error.OutOfMemory;
    errdefer if (user_message_id) |value| allocator.free(value);
    // MINOR-6: range-check before cast (storeStatus pattern); corrupt/negative
    // committed_store_revision maps to store_corrupt, not a Debug panic.
    const committed: ?u64 = if (row.nullableInt(10)) |value|
        std.math.cast(u64, value) orelse return error.StoreCorrupt
    else
        null;

    return .{
        .turn_id = turn_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .status = status,
        .started_at_ms = row.int(4),
        .finished_at_ms = row.nullableInt(5),
        .provider = provider,
        .provider_thread_id = provider_thread_id,
        .error_message = error_message,
        .user_message_id = user_message_id,
        .committed_store_revision = committed,
    };
}

fn freeTurnRecord(allocator: std.mem.Allocator, record: store_protocol.TurnRecord) void {
    allocator.free(record.turn_id);
    allocator.free(record.workspace_id);
    allocator.free(record.local_thread_id);
    allocator.free(record.status);
    allocator.free(record.provider);
    if (record.provider_thread_id) |value| allocator.free(value);
    if (record.error_message) |value| allocator.free(value);
    if (record.user_message_id) |value| allocator.free(value);
}

fn loadThreadGetResult(
    allocator: std.mem.Allocator,
    store: *daemon_store.Store,
    request: store_protocol.ThreadGetRequest,
) daemon_store.StoreError!store_protocol.ThreadGetResult {
    if (request.workspace_id.len == 0 or request.local_thread_id.len == 0) return error.InvalidParams;
    const meta_or_null = store.conn.row(
        \\select t.local_thread_id, t.title, t.archived, t.committed, t.last_activity_at,
        \\       t.provider_thread_id, t.model_ref, t.provider, t.harness, t.id
        \\from threads t
        \\join workspaces w on w.id = t.workspace_id
        \\where w.workspace_id = ?1 and t.local_thread_id = ?2
    ,
        .{ request.workspace_id, request.local_thread_id },
    ) catch return error.StoreUnavailable;
    const meta = meta_or_null orelse return error.ResourceNotFound;
    defer meta.deinit();

    const thread_row_id = meta.int(9);
    const local_thread_id = allocator.dupe(u8, meta.text(0)) catch return error.OutOfMemory;
    errdefer allocator.free(local_thread_id);
    const title = allocator.dupe(u8, meta.text(1)) catch return error.OutOfMemory;
    errdefer allocator.free(title);
    const provider_thread_id = dupeOptionalText(allocator, meta.nullableText(5)) catch return error.OutOfMemory;
    errdefer if (provider_thread_id) |value| allocator.free(value);
    const model_ref = dupeOptionalText(allocator, meta.nullableText(6)) catch return error.OutOfMemory;
    errdefer if (model_ref) |value| allocator.free(value);
    const provider = allocator.dupe(u8, providerNameFromCode(meta.int(7))) catch return error.OutOfMemory;
    errdefer allocator.free(provider);
    const harness_name = allocator.dupe(u8, harnessNameFromCode(meta.int(8))) catch return error.OutOfMemory;
    errdefer allocator.free(harness_name);
    const archived = meta.int(2) != 0;
    const committed = meta.int(3) != 0;
    const last_activity_at = meta.nullableInt(4);

    var messages_list: std.ArrayListUnmanaged(store_protocol.Message) = .empty;
    errdefer {
        for (messages_list.items) |message| freeOwnedMessage(allocator, message);
        messages_list.deinit(allocator);
    }
    var rows = store.conn.rows(
        \\select message_id, role, author, body, created_at_ms, updated_at_ms,
        \\       tool_call_id, tool_call_kind, tool_call_status
        \\from messages where thread_id = ?1 order by sort_index
    ,
        .{thread_row_id},
    ) catch return error.StoreUnavailable;
    defer rows.deinit();
    while (rows.next()) |row| {
        const message_id = allocator.dupe(u8, row.nullableText(0) orelse "") catch return error.OutOfMemory;
        errdefer allocator.free(message_id);
        const role = allocator.dupe(u8, roleNameFromCode(row.int(1))) catch return error.OutOfMemory;
        errdefer allocator.free(role);
        const author = allocator.dupe(u8, row.text(2)) catch return error.OutOfMemory;
        errdefer allocator.free(author);
        const body = allocator.dupe(u8, row.text(3)) catch return error.OutOfMemory;
        errdefer allocator.free(body);
        const tool_call_id = dupeOptionalText(allocator, row.nullableText(6)) catch return error.OutOfMemory;
        errdefer if (tool_call_id) |value| allocator.free(value);
        const tool_call_kind = if (row.nullableInt(7)) |code|
            (allocator.dupe(u8, toolCallKindNameFromCode(code)) catch return error.OutOfMemory)
        else
            null;
        errdefer if (tool_call_kind) |value| allocator.free(value);
        const tool_call_status = if (row.nullableInt(8)) |code|
            (allocator.dupe(u8, toolCallStatusNameFromCode(code)) catch return error.OutOfMemory)
        else
            null;
        errdefer if (tool_call_status) |value| allocator.free(value);
        messages_list.append(allocator, .{
            .message_id = message_id,
            .role = role,
            .author = author,
            .body = body,
            .created_at_ms = row.nullableInt(4),
            .updated_at_ms = row.nullableInt(5),
            .tool_call_id = tool_call_id,
            .tool_call_kind = tool_call_kind,
            .tool_call_status = tool_call_status,
        }) catch return error.OutOfMemory;
    }
    if (rows.err) |_| return error.StoreUnavailable;

    const store_revision = store.storeRevision() catch return error.StoreUnavailable;
    return .{
        .thread = .{
            .local_thread_id = local_thread_id,
            .title = title,
            .archived = archived,
            .committed = committed,
            .last_activity_at = last_activity_at,
            .provider_thread_id = provider_thread_id,
            .model_ref = model_ref,
            .provider = provider,
            .harness = harness_name,
            .messages = try messages_list.toOwnedSlice(allocator),
        },
        .store_revision = store_revision,
    };
}

fn freeThreadGetResult(allocator: std.mem.Allocator, result: store_protocol.ThreadGetResult) void {
    allocator.free(result.thread.local_thread_id);
    allocator.free(result.thread.title);
    if (result.thread.provider_thread_id) |value| allocator.free(value);
    if (result.thread.model_ref) |value| allocator.free(value);
    allocator.free(result.thread.provider);
    allocator.free(result.thread.harness);
    for (result.thread.messages) |message| freeOwnedMessage(allocator, message);
    allocator.free(result.thread.messages);
}

fn freeOwnedMessage(allocator: std.mem.Allocator, message: store_protocol.Message) void {
    if (message.message_id.len != 0) allocator.free(message.message_id);
    allocator.free(message.role);
    allocator.free(message.author);
    allocator.free(message.body);
    if (message.tool_call_id) |value| allocator.free(value);
    if (message.tool_call_kind) |value| allocator.free(value);
    if (message.tool_call_status) |value| allocator.free(value);
}

fn loadThreadListResult(
    allocator: std.mem.Allocator,
    store: *daemon_store.Store,
    request: store_protocol.ThreadListRequest,
) daemon_store.StoreError!store_protocol.ThreadListResult {
    if (request.workspace_id.len == 0) return error.InvalidParams;
    const limit: u32 = if (request.limit == 0) 100 else request.limit;

    var items: std.ArrayListUnmanaged(store_protocol.ThreadListItem) = .empty;
    errdefer {
        for (items.items) |item| freeThreadListItem(allocator, item);
        items.deinit(allocator);
    }

    var rows = store.conn.rows(
        \\select t.local_thread_id, t.title, t.archived, t.committed, t.last_activity_at,
        \\       t.provider_thread_id, t.model_ref, t.provider, t.harness
        \\from threads t
        \\join workspaces w on w.id = t.workspace_id
        \\where w.workspace_id = ?1
        \\order by coalesce(t.last_activity_at, 0) desc, t.local_thread_id asc
        \\limit ?2
    ,
        .{ request.workspace_id, @as(i64, @intCast(limit)) },
    ) catch return error.StoreUnavailable;
    defer rows.deinit();
    while (rows.next()) |row| {
        const local_thread_id = allocator.dupe(u8, row.text(0)) catch return error.OutOfMemory;
        errdefer allocator.free(local_thread_id);
        const title = allocator.dupe(u8, row.text(1)) catch return error.OutOfMemory;
        errdefer allocator.free(title);
        const provider_thread_id = dupeOptionalText(allocator, row.nullableText(5)) catch return error.OutOfMemory;
        errdefer if (provider_thread_id) |value| allocator.free(value);
        const model_ref = dupeOptionalText(allocator, row.nullableText(6)) catch return error.OutOfMemory;
        errdefer if (model_ref) |value| allocator.free(value);
        const provider = allocator.dupe(u8, providerNameFromCode(row.int(7))) catch return error.OutOfMemory;
        errdefer allocator.free(provider);
        const harness_name = allocator.dupe(u8, harnessNameFromCode(row.int(8))) catch return error.OutOfMemory;
        errdefer allocator.free(harness_name);
        items.append(allocator, .{
            .local_thread_id = local_thread_id,
            .title = title,
            .archived = row.int(2) != 0,
            .committed = row.int(3) != 0,
            .last_activity_at = row.nullableInt(4),
            .provider_thread_id = provider_thread_id,
            .model_ref = model_ref,
            .provider = provider,
            .harness = harness_name,
        }) catch return error.OutOfMemory;
    }
    if (rows.err) |_| return error.StoreUnavailable;

    const store_revision = store.storeRevision() catch return error.StoreUnavailable;
    return .{
        .threads = try items.toOwnedSlice(allocator),
        .next_cursor = null,
        .store_revision = store_revision,
    };
}

fn freeThreadListResult(allocator: std.mem.Allocator, result: store_protocol.ThreadListResult) void {
    for (result.threads) |item| freeThreadListItem(allocator, item);
    allocator.free(result.threads);
    if (result.next_cursor) |value| allocator.free(value);
}

fn freeThreadListItem(allocator: std.mem.Allocator, item: store_protocol.ThreadListItem) void {
    allocator.free(item.local_thread_id);
    allocator.free(item.title);
    if (item.provider_thread_id) |value| allocator.free(value);
    if (item.model_ref) |value| allocator.free(value);
    allocator.free(item.provider);
    allocator.free(item.harness);
}

fn dupeOptionalText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
}

fn providerNameFromCode(code: i64) []const u8 {
    return switch (code) {
        0 => "opencode",
        1 => "codex",
        2 => "cursor",
        3 => "claude",
        else => "opencode",
    };
}

fn harnessNameFromCode(code: i64) []const u8 {
    return switch (code) {
        0 => "local_cli",
        1 => "remote_session",
        else => "local_cli",
    };
}

fn roleNameFromCode(code: i64) []const u8 {
    return switch (code) {
        0 => "system",
        1 => "user",
        2 => "assistant",
        else => "system",
    };
}

fn toolCallKindNameFromCode(code: i64) []const u8 {
    const names = [_][]const u8{ "read", "edit", "delete", "move", "search", "execute", "think", "fetch", "mcp", "other" };
    if (code < 0 or code >= names.len) return "other";
    return names[@intCast(code)];
}

fn toolCallStatusNameFromCode(code: i64) []const u8 {
    const names = [_][]const u8{ "pending", "in_progress", "completed", "failed", "cancelled", "unknown" };
    if (code < 0 or code >= names.len) return "unknown";
    return names[@intCast(code)];
}

fn reasoningEffortNameFromCode(code: i64) []const u8 {
    const names = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };
    if (code < 0 or code >= names.len) return "medium";
    return names[@intCast(code)];
}

fn fastModeNameFromCode(code: i64) []const u8 {
    return switch (code) {
        1 => "on",
        else => "off",
    };
}

fn accessModeNameFromCode(code: i64) []const u8 {
    return switch (code) {
        1 => "supervised",
        else => "full_access",
    };
}

fn surfaceProviderNameFromCode(code: i64) []const u8 {
    const names = [_][]const u8{ "opencode", "codex", "cursor", "claude", "grok", "amp" };
    if (code < 0 or code >= names.len) return "opencode";
    return names[@intCast(code)];
}

fn surfaceStatusNameFromCode(code: i64) []const u8 {
    const names = [_][]const u8{ "idle", "working", "waiting", "done", "error" };
    if (code < 0 or code >= names.len) return "idle";
    return names[@intCast(code)];
}

/// M4-P4/P5 landed: the daemon owns durable chat, so store-scope snapshots
/// are complete. Named constant (CONCURRENT_TRANSPORT_LANDED pattern) so the
/// pre-flip incomplete_scopes arm stays pinned by unit test, not dead code.
const CHAT_AUTHORITY_LANDED = true;

/// Pure incomplete-scope policy (scenario 6). Unknown scope names are always
/// incomplete; pre-authority-flip the durable chat rows exist but the GUI is
/// still the authority, so "store" must be reported incomplete too.
fn scopeIsIncomplete(scope_name: []const u8, chat_authority_landed: bool) bool {
    const known = std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_STORE) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_REGISTRY) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_SESSIONS) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_TURNS);
    if (!known) return true;
    if (!chat_authority_landed and std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_STORE)) return true;
    return false;
}

/// Topic filter for core.changes. Unknown wire spellings match nothing so a
/// newer client's future topic yields an empty (heartbeat) window, not junk.
fn changeEntryMatchesTopics(topic: change_journal.Topic, topics: ?[]const []const u8) bool {
    const filter = topics orelse return true;
    for (filter) |name| {
        const wanted = change_journal.Topic.fromWireName(name) orelse continue;
        if (wanted == topic) return true;
    }
    return false;
}

/// Splice a pre-serialized JSON fragment as the current Stringify value.
fn writeRawFragment(s: *std.json.Stringify, fragment: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(fragment);
    s.endWriteRaw();
}

/// Serialize the registry envelope object into an arena string. Caller holds
/// lockDaemon; the fragment is spliced into the reply off the lock.
fn serializeEnvelopeFragment(arena: std.mem.Allocator, daemon: *const Daemon) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try writeRegistryEnvelope(&s, daemon);
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// Composite `processes` array: same per-record serializers as process.list,
/// spanning all (or one filtered) workspaces plus derived chat-turn records.
/// Caller holds lockDaemon.
fn serializeProcessesFragment(arena: std.mem.Allocator, daemon: *Daemon, workspace_filter: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginArray();
    for (daemon.registry.workspaces.items) |*workspace| {
        if (workspace_filter) |filter| {
            if (!std.mem.eql(u8, workspace.id, filter)) continue;
        }
        for (workspace.managed_processes.items) |process| try writeManagedProcessSnapshot(&s, workspace, &process);
        for (workspace.tracked_terminal_processes.items) |process| try writeTrackedProcessSnapshot(&s, workspace, &process);
        for (workspace.external_processes.items) |process| try writeExternalProcessSnapshot(&s, workspace, &process);
        for (daemon.chat_turns.items) |turn| {
            // Match process.list: consumed turns are invisible.
            if (turn.consumed) continue;
            if (!std.mem.eql(u8, turn.workspace_id, workspace.id)) continue;
            {
                lockTurn(turn);
                defer turn.mutex.unlock();
                try writeChatTurnProcessSnapshot(&s, turn);
            }
        }
    }
    try s.endArray();
    return try writer.toOwnedSlice();
}

/// Composite `leases` array (writeLeaseRecord wire shape). Caller holds lockDaemon.
fn serializeLeasesFragment(arena: std.mem.Allocator, daemon: *Daemon, workspace_filter: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginArray();
    for (daemon.registry.workspaces.items) |*workspace| {
        if (workspace_filter) |filter| {
            if (!std.mem.eql(u8, workspace.id, filter)) continue;
        }
        for (workspace.leases.items) |lease| try writeLeaseRecord(&s, &lease);
    }
    try s.endArray();
    return try writer.toOwnedSlice();
}

/// Composite `sessions` array (writeSessionSummary wire shape — a superset of
/// the SessionSummary DTO; decoders ignore the extra fields). Caller holds
/// lockDaemon.
fn serializeSessionsFragment(arena: std.mem.Allocator, daemon: *Daemon, workspace_filter: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginArray();
    for (daemon.sessions.items) |session| {
        if (workspace_filter) |filter| {
            if (!std.mem.eql(u8, session.project_id, filter)) continue;
        }
        try writeSessionSummary(&s, session);
    }
    try s.endArray();
    return try writer.toOwnedSlice();
}

/// Composite `turns` array in the TurnRecord wire shape, from in-memory turns
/// with durable-first status masking. Caller holds lockDaemon.
fn serializeTurnsFragment(arena: std.mem.Allocator, daemon: *Daemon, workspace_filter: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginArray();
    for (daemon.chat_turns.items) |turn| {
        if (turn.consumed) continue;
        if (workspace_filter) |filter| {
            if (!std.mem.eql(u8, turn.workspace_id, filter)) continue;
        }
        lockTurn(turn);
        defer turn.mutex.unlock();
        try s.beginObject();
        try s.objectField("turn_id");
        try s.write(turn.turn_id);
        try s.objectField("workspace_id");
        try s.write(turn.workspace_id);
        try s.objectField("local_thread_id");
        try s.write(turn.local_thread_id);
        try s.objectField("status");
        try s.write(@tagName(chatTurnPublishedStatus(turn)));
        try s.objectField("started_at_ms");
        try s.write(turn.started_at_ms);
        try s.objectField("finished_at_ms");
        if (turn.finished_at_ms) |value| try s.write(value) else try s.write(null);
        try s.objectField("provider");
        try s.write(@tagName(turn.request.provider));
        try s.objectField("provider_thread_id");
        if (turn.provider_thread_id) |value| try s.write(value) else try s.write(null);
        try s.objectField("error_message");
        if (turn.error_message) |value| try s.write(value) else try s.write(null);
        try s.objectField("user_message_id");
        if (turn.user_message_id) |value| try s.write(value) else try s.write(null);
        try s.objectField("committed_store_revision");
        if (turn.committed_store_revision) |value| try s.write(value) else try s.write(null);
        try s.endObject();
    }
    try s.endArray();
    return try writer.toOwnedSlice();
}

test "incomplete scope policy pins both chat-authority arms" {
    // Landed arm (runtime): every frozen scope name is complete.
    try std.testing.expect(!scopeIsIncomplete("store", true));
    try std.testing.expect(!scopeIsIncomplete("registry", true));
    try std.testing.expect(!scopeIsIncomplete("sessions", true));
    try std.testing.expect(!scopeIsIncomplete("turns", true));
    // Pre-M4 arm (scenario 6): the store scope must be honestly incomplete
    // while chat authority is still GUI-side; volatile scopes are unaffected.
    try std.testing.expect(scopeIsIncomplete("store", false));
    try std.testing.expect(!scopeIsIncomplete("registry", false));
    // Unknown scope names are incomplete in both arms.
    try std.testing.expect(scopeIsIncomplete("chat", true));
    try std.testing.expect(scopeIsIncomplete("chat", false));
    // The runtime constant documents the landed authority flip.
    try std.testing.expect(CHAT_AUTHORITY_LANDED);
}

test "registry bump topics map onto the frozen journal topic set" {
    // .client is registry bookkeeping and never journals.
    try std.testing.expect(journalTopicFromBumpTopic(.client) == null);
    try std.testing.expectEqual(change_journal.Topic.workspace, journalTopicFromBumpTopic(.workspace).?);
    try std.testing.expectEqual(change_journal.Topic.process, journalTopicFromBumpTopic(.process).?);
    try std.testing.expectEqual(change_journal.Topic.lease, journalTopicFromBumpTopic(.lease).?);
    try std.testing.expectEqual(change_journal.Topic.notification, journalTopicFromBumpTopic(.notification).?);
    try std.testing.expectEqual(change_journal.Topic.chat_turn, journalTopicFromBumpTopic(.chat_turn).?);
    // Every mapped topic accepts the registry revision family (Q10).
    inline for (.{ change_journal.Topic.workspace, change_journal.Topic.process, change_journal.Topic.lease, change_journal.Topic.notification, change_journal.Topic.chat_turn }) |topic| {
        try std.testing.expect(change_journal.revisionPolicy(topic) != .store_only);
    }
}

test "changes topic filter matches wire spellings and ignores unknown names" {
    try std.testing.expect(changeEntryMatchesTopics(.chat_thread, null));
    const filter: []const []const u8 = &.{ "chat.thread", "process" };
    try std.testing.expect(changeEntryMatchesTopics(.chat_thread, filter));
    try std.testing.expect(changeEntryMatchesTopics(.process, filter));
    try std.testing.expect(!changeEntryMatchesTopics(.lease, filter));
    const unknown: []const []const u8 = &.{"terminal.bytes"};
    try std.testing.expect(!changeEntryMatchesTopics(.chat_thread, unknown));
}

test "Q7 core.changes long-poll limits are pinned" {
    // 25s wait ceiling and the pool-derived parked cap (m4m5_decisions Q7).
    try std.testing.expectEqual(@as(u32, 25_000), MAX_CHANGES_WAIT_MS);
    try std.testing.expectEqual(@as(usize, 2), platform_ipc.MAX_PARKED_LONG_POLL_WAITERS);
    // The daemon-side cap intentionally exceeds the 5s transport client
    // timeout: wire clients are bounded by their own timeout first, while
    // in-process callers may use the full 25s budget.
    try std.testing.expect(MAX_CHANGES_WAIT_MS >= SESSIONIZER_REQUEST_TIMEOUT_MS);
}

test "core.changes park protocol: over-cap, woken, timeout, drain" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    // Over-cap: with the Q7 cap's worth of parked waiters, the next park
    // degrades immediately and releases its reserved slot.
    const cap: u32 = @intCast(platform_ipc.MAX_PARKED_LONG_POLL_WAITERS);
    daemon.changes_parked.store(cap, .release);
    try std.testing.expectEqual(Daemon.ChangesParkOutcome.over_cap, daemon.parkForChanges(daemon.changes_signal.load(.acquire), nowMs() + 1000));
    try std.testing.expectEqual(cap, daemon.changes_parked.load(.acquire));
    daemon.changes_parked.store(0, .release);

    // Missed-wake protocol: a signal bump AFTER the observed load but BEFORE
    // the park returns .woken without sleeping.
    const observed = daemon.changes_signal.load(.acquire);
    daemon.signalChangesWaiters();
    try std.testing.expectEqual(Daemon.ChangesParkOutcome.woken, daemon.parkForChanges(observed, nowMs() + 60_000));

    // Deadline exhaustion is a timeout (mapped to a heartbeat by the caller).
    try std.testing.expectEqual(Daemon.ChangesParkOutcome.timed_out, daemon.parkForChanges(daemon.changes_signal.load(.acquire), nowMs() + 10));

    // Drain is sticky and terminates parks immediately, even fresh ones.
    daemon.beginChangesDrain();
    try std.testing.expectEqual(Daemon.ChangesParkOutcome.drained, daemon.parkForChanges(daemon.changes_signal.load(.acquire), nowMs() + 60_000));
}

test "journal append wakes a parked changes waiter" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const observed = daemon.changes_signal.load(.acquire);
    const Parker = struct {
        fn run(d: *Daemon, obs: u32, out: *std.atomic.Value(u32)) void {
            // Race-free either way: if the append lands first, the changed
            // signal word makes this return .woken without sleeping.
            if (d.parkForChanges(obs, nowMs() + 10_000) == .woken) out.store(1, .release);
        }
    };
    var woken: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, Parker.run, .{ &daemon, observed, &woken });
    daemon.appendJournalEntry(.process, "p1", null, .{ .registry = 1 });
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), woken.load(.acquire));
}

const LoadedStoreSnapshot = struct {
    snapshot: store_protocol.Snapshot,
    store_revision: u64,
};

/// Read the durable snapshot half in ONE read transaction so its contents and
/// `store_revision` are the same committed state (M5-P2 coherence pin). All
/// result memory lives in the caller's arena. Caller holds the store mutex.
fn loadStoreSnapshotTxn(
    arena: std.mem.Allocator,
    store: *daemon_store.Store,
    workspace_filter: ?[]const u8,
    include_store: bool,
) daemon_store.StoreError!LoadedStoreSnapshot {
    store.conn.execNoArgs("begin") catch return error.StoreUnavailable;
    var transaction_open = true;
    defer if (transaction_open) store.conn.rollback();

    const store_revision = try store.storeRevision();
    var snapshot: store_protocol.Snapshot = .{ .store_revision = store_revision };
    if (include_store) {
        snapshot = try loadSnapshotContents(arena, store, workspace_filter);
        snapshot.store_revision = store_revision;
    }
    store.conn.commit() catch return error.StoreUnavailable;
    transaction_open = false;
    return .{ .snapshot = snapshot, .store_revision = store_revision };
}

/// Materialize the typed store snapshot (workspaces → threads → messages,
/// surfaces, completions) inside the caller's open read transaction.
fn loadSnapshotContents(
    arena: std.mem.Allocator,
    store: *daemon_store.Store,
    workspace_filter: ?[]const u8,
) daemon_store.StoreError!store_protocol.Snapshot {
    var snapshot: store_protocol.Snapshot = .{};
    if (store.conn.row("select selected_workspace_index, sidebar_collapsed from app_state where id = 1", .{}) catch return error.StoreUnavailable) |row| {
        defer row.deinit();
        snapshot.selected_workspace_index = std.math.cast(usize, row.int(0)) orelse 0;
        snapshot.sidebar_collapsed = row.int(1) != 0;
    }

    // Phase 1: workspace rows (collected first so no two statements interleave).
    const WorkspaceRow = struct { row_id: i64, workspace: store_protocol.Workspace };
    var workspace_rows: std.ArrayList(WorkspaceRow) = .empty;
    {
        var rows = store.conn.rows(
            \\select id, workspace_id, label, path, archived, unread_count, collapsed,
            \\       thread_list_expanded, terminal_height, terminal_layout_json,
            \\       terminal_docks_json, workspace_layout_json, selected_thread_index,
            \\       companion_thread_local_id, herdr_remote_alias, herdr_session_name,
            \\       herdr_workspace_id, herdr_local_dir, herdr_remote_cwd,
            \\       herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id,
            \\       herdr_pane_links_json, herdr_updated_at_ms
            \\from workspaces order by sort_index
        , .{}) catch return error.StoreUnavailable;
        defer rows.deinit();
        while (rows.next()) |row| {
            const workspace_id = arena.dupe(u8, row.text(1)) catch return error.OutOfMemory;
            if (workspace_filter) |filter| {
                if (!std.mem.eql(u8, workspace_id, filter)) continue;
            }
            const herdr_session_name = dupeOptionalText(arena, row.nullableText(15)) catch return error.OutOfMemory;
            const herdr_workspace_id = dupeOptionalText(arena, row.nullableText(16)) catch return error.OutOfMemory;
            const herdr_local_dir = dupeOptionalText(arena, row.nullableText(17)) catch return error.OutOfMemory;
            const herdr_link: ?store_protocol.HerdrWorkspaceLink = if (herdr_session_name != null and herdr_workspace_id != null and herdr_local_dir != null) .{
                .remote_alias = (dupeOptionalText(arena, row.nullableText(14)) catch return error.OutOfMemory) orelse "",
                .session_name = herdr_session_name.?,
                .workspace_id = herdr_workspace_id.?,
                .local_dir = herdr_local_dir.?,
                .remote_cwd = dupeOptionalText(arena, row.nullableText(18)) catch return error.OutOfMemory,
                .last_pane_id = dupeOptionalText(arena, row.nullableText(19)) catch return error.OutOfMemory,
                .attach_dock_id = if (row.nullableInt(20)) |value| (std.math.cast(u32, value) orelse null) else null,
                .attach_pane_id = if (row.nullableInt(21)) |value| (std.math.cast(u32, value) orelse null) else null,
                .pane_links_json = dupeOptionalText(arena, row.nullableText(22)) catch return error.OutOfMemory,
                .updated_at_ms = row.nullableInt(23) orelse 0,
            } else null;
            workspace_rows.append(arena, .{
                .row_id = row.int(0),
                .workspace = .{
                    .workspace_id = workspace_id,
                    .label = arena.dupe(u8, row.text(2)) catch return error.OutOfMemory,
                    .path = arena.dupe(u8, row.text(3)) catch return error.OutOfMemory,
                    .archived = row.int(4) != 0,
                    .unread_count = std.math.cast(u32, row.int(5)) orelse 0,
                    .collapsed = row.int(6) != 0,
                    .thread_list_expanded = row.int(7) != 0,
                    .terminal_height = if (row.nullableFloat(8)) |value| @floatCast(value) else null,
                    .terminal_layout_json = dupeOptionalText(arena, row.nullableText(9)) catch return error.OutOfMemory,
                    .terminal_docks_json = dupeOptionalText(arena, row.nullableText(10)) catch return error.OutOfMemory,
                    .workspace_layout_json = dupeOptionalText(arena, row.nullableText(11)) catch return error.OutOfMemory,
                    .selected_thread_index = std.math.cast(usize, row.int(12)) orelse 0,
                    .companion_thread_local_id = dupeOptionalText(arena, row.nullableText(13)) catch return error.OutOfMemory,
                    .herdr_link = herdr_link,
                },
            }) catch return error.OutOfMemory;
        }
        if (rows.err) |_| return error.StoreUnavailable;
    }

    // Phase 2: threads per workspace, then messages per thread (statements
    // never nest: each list is fully collected before the next query runs).
    const ThreadRow = struct { row_id: i64, thread: store_protocol.Thread };
    for (workspace_rows.items) |*workspace_row| {
        var thread_rows: std.ArrayList(ThreadRow) = .empty;
        {
            var rows = store.conn.rows(
                \\select id, local_thread_id, title, archived, committed, last_activity_at,
                \\       provider_thread_id, model_ref, reasoning_effort, reasoning_variant,
                \\       fast_mode, access_mode, provider, harness, tui_dock_id, draft,
                \\       draft_image_path, draft_image_mime, draft_image_byte_size
                \\from threads where workspace_id = ?1 order by sort_index
            , .{workspace_row.row_id}) catch return error.StoreUnavailable;
            defer rows.deinit();
            while (rows.next()) |row| {
                const draft_image: ?store_protocol.Attachment = if (row.nullableText(16)) |path| .{
                    .path = arena.dupe(u8, path) catch return error.OutOfMemory,
                    .mime = arena.dupe(u8, row.nullableText(17) orelse "") catch return error.OutOfMemory,
                    .byte_size = if (row.nullableInt(18)) |value| (std.math.cast(usize, value) orelse 0) else 0,
                } else null;
                thread_rows.append(arena, .{
                    .row_id = row.int(0),
                    .thread = .{
                        .local_thread_id = arena.dupe(u8, row.nullableText(1) orelse "") catch return error.OutOfMemory,
                        .title = arena.dupe(u8, row.text(2)) catch return error.OutOfMemory,
                        .archived = row.int(3) != 0,
                        .committed = row.int(4) != 0,
                        .last_activity_at = row.nullableInt(5),
                        .provider_thread_id = dupeOptionalText(arena, row.nullableText(6)) catch return error.OutOfMemory,
                        .model_ref = dupeOptionalText(arena, row.nullableText(7)) catch return error.OutOfMemory,
                        .reasoning_effort = if (row.nullableInt(8)) |code| reasoningEffortNameFromCode(code) else null,
                        .reasoning_variant = dupeOptionalText(arena, row.nullableText(9)) catch return error.OutOfMemory,
                        .fast_mode = if (row.nullableInt(10)) |code| fastModeNameFromCode(code) else null,
                        .access_mode = if (row.nullableInt(11)) |code| accessModeNameFromCode(code) else null,
                        .provider = providerNameFromCode(row.int(12)),
                        .harness = harnessNameFromCode(row.int(13)),
                        .tui_dock_id = if (row.nullableInt(14)) |value| (std.math.cast(u32, value) orelse null) else null,
                        .draft = arena.dupe(u8, row.nullableText(15) orelse "") catch return error.OutOfMemory,
                        .draft_image = draft_image,
                    },
                }) catch return error.OutOfMemory;
            }
            if (rows.err) |_| return error.StoreUnavailable;
        }

        var threads: std.ArrayList(store_protocol.Thread) = .empty;
        for (thread_rows.items) |*thread_row| {
            var messages: std.ArrayList(store_protocol.Message) = .empty;
            var rows = store.conn.rows(
                \\select message_id, role, author, body, image_path, image_mime,
                \\       image_byte_size, tool_call_id, tool_call_kind, tool_call_status,
                \\       created_at_ms, updated_at_ms
                \\from messages where thread_id = ?1 order by sort_index
            , .{thread_row.row_id}) catch return error.StoreUnavailable;
            defer rows.deinit();
            while (rows.next()) |row| {
                const image: ?store_protocol.Attachment = if (row.nullableText(4)) |path| .{
                    .path = arena.dupe(u8, path) catch return error.OutOfMemory,
                    .mime = arena.dupe(u8, row.nullableText(5) orelse "") catch return error.OutOfMemory,
                    .byte_size = if (row.nullableInt(6)) |value| (std.math.cast(usize, value) orelse 0) else 0,
                } else null;
                const images: []const store_protocol.Attachment = if (image) |value| blk: {
                    const slice = arena.alloc(store_protocol.Attachment, 1) catch return error.OutOfMemory;
                    slice[0] = value;
                    break :blk slice;
                } else &.{};
                messages.append(arena, .{
                    .message_id = arena.dupe(u8, row.nullableText(0) orelse "") catch return error.OutOfMemory,
                    .role = roleNameFromCode(row.int(1)),
                    .author = arena.dupe(u8, row.text(2)) catch return error.OutOfMemory,
                    .body = arena.dupe(u8, row.text(3)) catch return error.OutOfMemory,
                    .images = images,
                    .image = image,
                    .tool_call_id = dupeOptionalText(arena, row.nullableText(7)) catch return error.OutOfMemory,
                    .tool_call_kind = if (row.nullableInt(8)) |code| toolCallKindNameFromCode(code) else null,
                    .tool_call_status = if (row.nullableInt(9)) |code| toolCallStatusNameFromCode(code) else null,
                    .created_at_ms = row.nullableInt(10),
                    .updated_at_ms = row.nullableInt(11),
                }) catch return error.OutOfMemory;
            }
            if (rows.err) |_| return error.StoreUnavailable;
            thread_row.thread.messages = messages.items;
            threads.append(arena, thread_row.thread) catch return error.OutOfMemory;
        }
        workspace_row.workspace.threads = threads.items;
    }

    var workspaces: std.ArrayList(store_protocol.Workspace) = .empty;
    for (workspace_rows.items) |workspace_row| {
        workspaces.append(arena, workspace_row.workspace) catch return error.OutOfMemory;
    }
    snapshot.workspaces = workspaces.items;

    // Surfaces and legacy completion ledger.
    var surfaces: std.ArrayList(store_protocol.SurfaceState) = .empty;
    {
        var rows = store.conn.rows(
            \\select session_id, workspace_id, workspace_path, dock_id, pane_id, provider,
            \\       provider_thread_id, title, status, status_changed_at_ms, completed_at_ms,
            \\       last_event_title, last_event_body
            \\from surface_completions order by session_id
        , .{}) catch return error.StoreUnavailable;
        defer rows.deinit();
        while (rows.next()) |row| {
            const workspace_id = arena.dupe(u8, row.text(1)) catch return error.OutOfMemory;
            if (workspace_filter) |filter| {
                if (!std.mem.eql(u8, workspace_id, filter)) continue;
            }
            surfaces.append(arena, .{
                .session_id = arena.dupe(u8, row.text(0)) catch return error.OutOfMemory,
                .workspace_id = workspace_id,
                .workspace_path = arena.dupe(u8, row.text(2)) catch return error.OutOfMemory,
                .dock_id = std.math.cast(u32, row.int(3)) orelse 0,
                .pane_id = if (row.nullableInt(4)) |value| (std.math.cast(u32, value) orelse null) else null,
                .provider = if (row.nullableInt(5)) |code| surfaceProviderNameFromCode(code) else null,
                .provider_thread_id = dupeOptionalText(arena, row.nullableText(6)) catch return error.OutOfMemory,
                .title = arena.dupe(u8, row.text(7)) catch return error.OutOfMemory,
                .status = surfaceStatusNameFromCode(row.int(8)),
                .status_changed_at_ms = row.int(9),
                .completed_at_ms = row.int(10),
                .last_event_title = dupeOptionalText(arena, row.nullableText(11)) catch return error.OutOfMemory,
                .last_event_body = dupeOptionalText(arena, row.nullableText(12)) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }
        if (rows.err) |_| return error.StoreUnavailable;
    }
    snapshot.surface_states = surfaces.items;

    var completions: std.ArrayList(store_protocol.ChatCompletion) = .empty;
    {
        var rows = store.conn.rows(
            "select workspace_id, local_thread_id, completed_at_ms from chat_completions order by workspace_id, local_thread_id",
            .{},
        ) catch return error.StoreUnavailable;
        defer rows.deinit();
        while (rows.next()) |row| {
            const workspace_id = arena.dupe(u8, row.text(0)) catch return error.OutOfMemory;
            if (workspace_filter) |filter| {
                if (!std.mem.eql(u8, workspace_id, filter)) continue;
            }
            completions.append(arena, .{
                .workspace_id = workspace_id,
                .local_thread_id = arena.dupe(u8, row.text(1)) catch return error.OutOfMemory,
                .completed_at_ms = row.int(2),
            }) catch return error.OutOfMemory;
        }
        if (rows.err) |_| return error.StoreUnavailable;
    }
    snapshot.chat_completions = completions.items;
    return snapshot;
}

fn storeErrorResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    err: daemon_store.StoreError,
) ![]u8 {
    const mapped: struct { code: []const u8, message: []const u8 } = switch (err) {
        error.Conflict => .{ .code = headless.protocol.ERR_CONFLICT, .message = "store revision conflict" },
        error.InvalidParams => .{ .code = headless.protocol.ERR_INVALID_PARAMS, .message = "invalid params" },
        error.ResourceNotFound => .{ .code = headless.protocol.ERR_RESOURCE_NOT_FOUND, .message = "resource not found" },
        error.CapabilityUnavailable => .{ .code = headless.protocol.ERR_CAPABILITY_UNAVAILABLE, .message = "store capability is unavailable" },
        error.StoreBusy => .{ .code = headless.protocol.ERR_STORE_BUSY, .message = "store is busy" },
        error.SchemaTooNew => .{ .code = headless.protocol.ERR_SCHEMA_TOO_NEW, .message = "database schema is newer than this daemon" },
        error.StoreCorrupt => .{ .code = headless.protocol.ERR_STORE_CORRUPT, .message = "store is corrupt" },
        error.StoreUnavailable => .{ .code = headless.protocol.ERR_STORE_UNAVAILABLE, .message = "store is unavailable" },
        error.Internal => .{ .code = headless.protocol.ERR_INTERNAL, .message = "internal store error" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return try errorResponseAllocWithData(allocator, id_value, mapped.code, mapped.message, null);
}

/// Single serve-path classification (one JSON parse). Fold W5 slow-work and
/// S2/S3 store routing so store/normal cannot disagree about lock ownership.
/// `unlocked_method` is for handlers that manage their own short lockDaemon
/// windows (chat.turn.start needs a store-seam ledger read without nesting).
const ServerRequestClass = enum { slow_registry, store, unlocked_method, normal };

fn methodRunsUnlocked(method: []const u8) bool {
    // M4-P4: ledger identity guard on accept must read SQLite under the store
    // mutex only; the `.normal` outer lockDaemon window cannot nest that work.
    return std.mem.eql(u8, method, "chat.turn.start");
}

fn classifyServerRequest(allocator: std.mem.Allocator, request: []const u8) !ServerRequestClass {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const method = jsonString(parsed.value.object.get("method") orelse .null) orelse return error.InvalidRequest;
    if (methodNeedsSlowWork(method)) return .slow_registry;
    if (isStoreMethod(method)) return .store;
    if (methodRunsUnlocked(method)) return .unlocked_method;
    return .normal;
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

fn slowIoDelayMsFromEnv(allocator: std.mem.Allocator) u64 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, TEST_SLOW_IO_ENV_NAME) catch return 0;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = std.fmt.parseInt(u64, trimmed, 10) catch return 0;
    return @min(parsed, 5000);
}

/// Test-only journal entry-cap override (M5-P2 overflow IT). Zero/invalid
/// keeps the production cap so a stray value can only shrink retention.
fn journalEntryCapFromEnv(allocator: std.mem.Allocator) usize {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_JOURNAL_ENTRY_CAP_ENV_NAME) catch return change_journal.CHANGE_JOURNAL_ENTRY_MAX;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return change_journal.CHANGE_JOURNAL_ENTRY_MAX;
    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch return change_journal.CHANGE_JOURNAL_ENTRY_MAX;
    if (parsed == 0) return change_journal.CHANGE_JOURNAL_ENTRY_MAX;
    return parsed;
}

fn retentionOverrideMsFromEnv(allocator: std.mem.Allocator) ?i64 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, TEST_RETENTION_ENV_NAME) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    return @max(parsed, 100);
}

fn retentionExpiredForDaemon(start_ms: i64, now_ms: i64, retention_ms: i64) bool {
    if (now_ms < start_ms) return false;
    return now_ms - start_ms > retention_ms;
}

fn handleSessionizerServerRequest(raw_context: *anyopaque, request: []u8) anyerror![]u8 {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    const daemon = context.daemon;
    defer daemon.allocator.free(request);
    const trimmed = std.mem.trim(u8, request, "\r");

    // One envelope parse outside lockDaemon classifies W5 slow-work vs store vs
    // normal. Store methods run unlocked (handleStoreRequest takes a short
    // bookkeeping lock). Classification failure returns invalid_request without
    // lockDaemon so a later successful re-parse cannot self-deadlock on the
    // non-reentrant daemon spin mutex (NIT-1/NIT-2).
    const class = classifyServerRequest(daemon.allocator, trimmed) catch {
        return errorResponseAlloc(daemon.allocator, .null, "invalid_request", "malformed request");
    };
    switch (class) {
        .slow_registry => return daemon.handleSlowRegistryRequest(daemon.allocator, request) catch |err|
            errorResponseAlloc(daemon.allocator, .null, "internal_error", @errorName(err)),
        .store => return daemon.handleRequest(trimmed) catch |err|
            errorResponseAlloc(daemon.allocator, .null, "internal_error", @errorName(err)),
        // chat.turn.start: handler owns short lockDaemon sections + store seam.
        .unlocked_method => return daemon.handleRequest(trimmed) catch |err|
            errorResponseAlloc(daemon.allocator, .null, "internal_error", @errorName(err)),
        .normal => {
            lockDaemon(daemon);
            const response = daemon.handleRequest(trimmed) catch |err| {
                daemon.mutex.unlock();
                return errorResponseAlloc(daemon.allocator, .null, "internal_error", @errorName(err));
            };
            daemon.mutex.unlock();
            return response;
        },
    }
}

fn methodNeedsSlowWork(method: []const u8) bool {
    return std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_START) or
        std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_STOP) or
        std.mem.eql(u8, method, headless.registry.METHOD_PROCESS_RESTART);
}

fn managedProcessByIdentifier(
    workspace: *process_registry.WorkspaceRecord,
    identifier: []const u8,
) ?*process_registry.ManagedProcess {
    for (workspace.managed_processes.items) |*process| {
        if (std.mem.eql(u8, process.id, identifier) or std.mem.eql(u8, process.name, identifier)) return process;
    }
    return null;
}

fn hasRegistryJob(
    jobs: []const process_registry.RegistryJob,
    workspace_id: []const u8,
    process_id: []const u8,
) bool {
    for (jobs) |job| {
        if (std.mem.eql(u8, job.workspace_id, workspace_id) and std.mem.eql(u8, job.process_id, process_id)) return true;
    }
    return false;
}

fn managedProcessCwd(allocator: std.mem.Allocator, workspace_path: []const u8, definition_cwd: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, definition_cwd, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return allocator.dupe(u8, workspace_path);
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    return std.fs.path.join(allocator, &.{ workspace_path, trimmed });
}

fn tryAppendLaunchArg(
    allocator: std.mem.Allocator,
    launch_args: *std.ArrayList([]const u8),
    arg: []const u8,
) !void {
    try launch_args.append(allocator, arg);
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
        const now_ms = nowMs();
        // Run every bounded registry retention rule once per tick, even when
        // no GUI is attached; the registry is intentionally cheap at these
        // in-memory phase-2 sizes.
        _ = daemon.registry.reap(daemon.allocator, now_ms);
        daemon.pollSessions();
        daemon.reapOrphanedSessions(now_ms);
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

fn joinDrainThread(context: *SessionizerServerContext) void {
    if (context.drain_thread == null) return;
    platform_ipc.wake(context.daemon.allocator, context.endpoint, .{
        .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
    });
    context.drain_thread.?.join();
    context.drain_thread = null;
}

/// Idempotent: safe from both on_closing (primary) and finishSessionizerServer
/// (error-path fallback when serve fails before the accept loop).
fn finishSessionizerServer(context: *SessionizerServerContext) void {
    context.stop_requested.store(true, .release);
    joinDrainThread(context);
    // Store finalization is primarily done in on_closing (before endpoint
    // release). This call is a no-op when that already ran.
    finalizeSessionizerStore(context);
    if (context.pid_published) deletePidFileIfOwned(context.pid_path);
}

/// Commit the lease/outcome transfer and close the writer. Idempotent when
/// store_service is already null. Ordering contract: must run while this
/// process still owns the endpoint (on_closing), so successor bind cannot
/// import a pre-transfer snapshot. Snapshot-copy under lockDaemon only;
/// SQLite runs after unlock (never SQLite under the daemon spin lock).
fn finalizeSessionizerStore(context: *SessionizerServerContext) void {
    const service = context.daemon.store_service orelse return;

    var arena = std.heap.ArenaAllocator.init(context.daemon.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var leases: std.ArrayListUnmanaged(daemon_store.LeaseRecord) = .empty;
    var outcomes: std.ArrayListUnmanaged(daemon_store.TerminalProcessOutcome) = .empty;

    // 1. Snapshot-copy under the daemon lock only (borrowed registry strings
    // are duped into the arena so SQLite does not hold the spin lock).
    lockDaemon(context.daemon);
    _ = context.daemon.registry.reap(context.daemon.allocator, nowMs());
    const collect_ok = collectTransferSnapshotOwned(context.daemon, scratch, &leases, &outcomes);
    // Detach the service pointer under the lock so concurrent status paths see
    // store-less immediately; close happens after unlock.
    context.daemon.store_service = null;
    context.daemon.mutex.unlock();

    // 2. SQLite under the store service lock only — never under lockDaemon.
    if (collect_ok) |_| {
        persistTransferLists(service, leases.items, outcomes.items) catch |err| {
            log.warn("lease/outcome transfer persist failed err={s}; attempting empty snapshot fallback", .{@errorName(err)});
            // Fallback: publish a real empty snapshot so a prior generation
            // cannot resurrect. If this also fails the residual risk is bounded
            // (lease TTL ≤ 1h, outcome TTL 15min) until the next successful drain.
            persistTransferLists(service, &.{}, &.{}) catch |fallback_err| {
                log.warn(
                    "lease/outcome empty-snapshot fallback failed err={s}; successor may import a stale predecessor snapshot until TTLs elapse",
                    .{@errorName(fallback_err)},
                );
            };
        };
    } else |err| {
        log.warn("lease/outcome transfer collect failed err={s}; attempting empty snapshot fallback", .{@errorName(err)});
        persistTransferLists(service, &.{}, &.{}) catch |fallback_err| {
            log.warn(
                "lease/outcome empty-snapshot fallback failed err={s}; successor may import a stale predecessor snapshot until TTLs elapse",
                .{@errorName(fallback_err)},
            );
        };
    }

    // MINOR-5(b) / MINOR-V1: drain in_flight before destroy so a late
    // staging/commit pointer-grab cannot UAF after store.deinit. On timeout,
    // deliberately leak the service (loud warn) rather than deinit under a
    // live in_flight commit — a bounded one-time leak on the serve-error
    // fallback beats use-after-free.
    {
        const drain_deadline = nowMs() + 2000;
        while (service.in_flight.load(.monotonic) != 0) {
            if (nowMs() >= drain_deadline) {
                log.warn(
                    "store finalize in_flight drain timed out count={d}; leaking store service to avoid UAF",
                    .{service.in_flight.load(.monotonic)},
                );
                return;
            }
            platform_runtime.sleepMillis(5);
        }
    }

    service.store.deinit();
    context.daemon.allocator.destroy(service);
}

/// Copy registry transfer state into arena-owned store records. Caller holds
/// the daemon lock for the duration of this call only.
fn collectTransferSnapshotOwned(
    daemon: *Daemon,
    scratch: std.mem.Allocator,
    leases: *std.ArrayListUnmanaged(daemon_store.LeaseRecord),
    outcomes: *std.ArrayListUnmanaged(daemon_store.TerminalProcessOutcome),
) !void {
    for (daemon.registry.workspaces.items) |*workspace| {
        for (workspace.leases.items) |*lease| {
            const resources = try scratch.alloc([]const u8, lease.resources.items.len);
            for (lease.resources.items, 0..) |resource, index| {
                resources[index] = try scratch.dupe(u8, resource);
            }
            try leases.append(scratch, .{
                .workspace_id = try scratch.dupe(u8, lease.workspace_id),
                .lease_id = try scratch.dupe(u8, lease.id),
                .owner = try scratch.dupe(u8, lease.owner),
                .client_id = try scratch.dupe(u8, lease.client_id),
                .command = try scratch.dupe(u8, lease.command),
                .resources = resources,
                .created_at_ms = lease.created_at_ms,
                .expires_at_ms = lease.expires_at_ms,
                .last_renewal_ms = lease.last_renewal_ms,
            });
        }
        for (workspace.terminal_process_outcomes.items) |*outcome| {
            try outcomes.append(scratch, .{
                .workspace_id = try scratch.dupe(u8, outcome.workspace_id),
                .process_id = try scratch.dupe(u8, outcome.process_id),
                .generation = outcome.generation,
                .session_id = try scratch.dupe(u8, outcome.session_id),
                .command = try scratch.dupe(u8, outcome.command),
                .cwd = try scratch.dupe(u8, outcome.cwd),
                .pid = outcome.pid,
                .process_group = outcome.process_group,
                .started_at_ms = outcome.started_at_ms,
                .finished_at_ms = outcome.finished_at_ms,
                .dock_id = outcome.dock_id,
                .pane_id = outcome.pane_id,
                .owner_kind = try scratch.dupe(u8, outcome.owner_kind),
                .owner_title = try scratch.dupe(u8, outcome.owner_title),
                .provider = if (outcome.provider) |value| try scratch.dupe(u8, value) else null,
                .status = mapOutcomeStatusToStore(outcome.status),
                .exit_code = outcome.exit_code,
                .signal = outcome.signal,
                .cancellation_reason = if (outcome.cancellation_reason) |value| try scratch.dupe(u8, value) else null,
            });
        }
    }
}

/// Drain-time transfer: always write one real snapshot (delete-all + set,
/// possibly empty, one revision bump). Takes the store service lock; must NOT
/// be called under lockDaemon.
fn persistTransferLists(
    service: *StoreService,
    leases: []const daemon_store.LeaseRecord,
    outcomes: []const daemon_store.TerminalProcessOutcome,
) !void {
    lockStoreService(service);
    defer service.mutex.unlock();
    _ = try service.store.persistLeasesAndOutcomes(leases, outcomes);
}

/// Test/helper: collect under daemon lock then persist without holding it.
/// Does not reap — callers that need a clock-aligned snapshot (production
/// finalizeSessionizerStore) reap before collect with the intended now_ms.
fn persistTransferSnapshot(daemon: *Daemon, service: *StoreService) !void {
    var arena = std.heap.ArenaAllocator.init(daemon.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var leases: std.ArrayListUnmanaged(daemon_store.LeaseRecord) = .empty;
    var outcomes: std.ArrayListUnmanaged(daemon_store.TerminalProcessOutcome) = .empty;

    lockDaemon(daemon);
    collectTransferSnapshotOwned(daemon, scratch, &leases, &outcomes) catch |err| {
        daemon.mutex.unlock();
        return err;
    };
    daemon.mutex.unlock();

    try persistTransferLists(service, leases.items, outcomes.items);
}

fn mapOutcomeStatusToStore(status: process_registry.TerminalProcessOutcomeStatus) daemon_store.TerminalProcessOutcomeStatus {
    return switch (status) {
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
        .crashed => .crashed,
        .unknown => .unknown,
    };
}

fn mapOutcomeStatusFromStore(status: daemon_store.TerminalProcessOutcomeStatus) process_registry.TerminalProcessOutcomeStatus {
    return switch (status) {
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
        .crashed => .crashed,
        .unknown => .unknown,
    };
}

/// Seed the volatile registry from a committed transfer import. Dupes all
/// strings so the imported container can be freed independently. Raises each
/// workspace's `next_terminal_generation` above any imported outcome generation
/// so `term:{session}:{generation}` IDs cannot collide across a replacement.
fn seedRegistryFromTransfer(daemon: *Daemon, imported: *const daemon_store.ImportedLeasesAndOutcomes) !void {
    var seeded: usize = 0;
    for (imported.leases.items) |src| {
        const workspace = try daemon.registry.ensureWorkspace(daemon.allocator, src.workspace_id);
        var lease = try cloneImportedLease(daemon.allocator, src);
        errdefer lease.deinit(daemon.allocator);
        try workspace.leases.append(daemon.allocator, lease);
        seeded += 1;
    }
    for (imported.outcomes.items) |src| {
        const workspace = try daemon.registry.ensureWorkspace(daemon.allocator, src.workspace_id);
        var outcome = try cloneImportedOutcome(daemon.allocator, src);
        errdefer outcome.deinit(daemon.allocator);
        try workspace.terminal_process_outcomes.append(daemon.allocator, outcome);
        // Keep the successor generation counter above imported outcomes so a
        // re-used session id cannot mint a colliding term:{session}:{gen} id.
        const next_gen = std.math.add(u64, src.generation, 1) catch std.math.maxInt(u64);
        if (next_gen > workspace.next_terminal_generation) {
            workspace.next_terminal_generation = next_gen;
        }
        seeded += 1;
    }
    if (seeded != 0) {
        // Mirror process_registry.bumpRevision without exporting it.
        daemon.registry.registry_revision +%= 1;
        if (daemon.registry.registry_revision == 0) daemon.registry.registry_revision = 1;
    }
}

fn cloneImportedLease(allocator: std.mem.Allocator, src: daemon_store.ImportedLeaseRecord) !process_registry.LeaseRecord {
    const owned_workspace_id = try allocator.dupe(u8, src.workspace_id);
    errdefer allocator.free(owned_workspace_id);
    const owned_id = try allocator.dupe(u8, src.lease_id);
    errdefer allocator.free(owned_id);
    const owned_owner = try allocator.dupe(u8, src.owner);
    errdefer allocator.free(owned_owner);
    const owned_client_id = try allocator.dupe(u8, src.client_id);
    errdefer allocator.free(owned_client_id);
    const owned_command = try allocator.dupe(u8, src.command);
    errdefer allocator.free(owned_command);
    var resources: std.ArrayList([]u8) = .empty;
    errdefer {
        for (resources.items) |resource| allocator.free(resource);
        resources.deinit(allocator);
    }
    for (src.resources.items) |resource| {
        try process_registry.appendOwnedString(allocator, &resources, resource);
    }
    return .{
        .workspace_id = owned_workspace_id,
        .id = owned_id,
        .owner = owned_owner,
        .client_id = owned_client_id,
        .command = owned_command,
        .resources = resources,
        .created_at_ms = src.created_at_ms,
        .expires_at_ms = src.expires_at_ms,
        .last_renewal_ms = src.last_renewal_ms,
    };
}

fn cloneImportedOutcome(allocator: std.mem.Allocator, src: daemon_store.ImportedTerminalProcessOutcome) !process_registry.TerminalProcessOutcome {
    const owned_workspace_id = try allocator.dupe(u8, src.workspace_id);
    errdefer allocator.free(owned_workspace_id);
    const owned_process_id = try allocator.dupe(u8, src.process_id);
    errdefer allocator.free(owned_process_id);
    const owned_session_id = try allocator.dupe(u8, src.session_id);
    errdefer allocator.free(owned_session_id);
    const owned_command = try allocator.dupe(u8, src.command);
    errdefer allocator.free(owned_command);
    const owned_cwd = try allocator.dupe(u8, src.cwd);
    errdefer allocator.free(owned_cwd);
    const owned_owner_kind = try allocator.dupe(u8, src.owner_kind);
    errdefer allocator.free(owned_owner_kind);
    const owned_owner_title = try allocator.dupe(u8, src.owner_title);
    errdefer allocator.free(owned_owner_title);
    const owned_provider: ?[]u8 = if (src.provider) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_provider) |value| allocator.free(value);
    const owned_cancellation: ?[]u8 = if (src.cancellation_reason) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_cancellation) |value| allocator.free(value);
    return .{
        .workspace_id = owned_workspace_id,
        .process_id = owned_process_id,
        .generation = src.generation,
        .session_id = owned_session_id,
        .command = owned_command,
        .cwd = owned_cwd,
        .pid = src.pid,
        .process_group = src.process_group,
        .started_at_ms = src.started_at_ms,
        .finished_at_ms = src.finished_at_ms,
        .dock_id = src.dock_id,
        .pane_id = src.pane_id,
        .owner_kind = owned_owner_kind,
        .owner_title = owned_owner_title,
        .provider = owned_provider,
        .status = mapOutcomeStatusFromStore(src.status),
        .exit_code = src.exit_code,
        .signal = src.signal,
        .cancellation_reason = owned_cancellation,
    };
}

fn lockDaemon(daemon: *Daemon) void {
    while (!daemon.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn lockTurn(turn: *ChatTurn) void {
    while (!turn.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn lockJournal(daemon: *Daemon) void {
    while (!daemon.journal_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn chatTurnKeepsDaemonAlive(
    status: ChatTurnStatus,
    consumed: bool,
    worker_done: bool,
    durability_pending: bool,
) bool {
    // M4-P4 authority flip: committed terminal turns no longer keep the daemon
    // alive. Only in-flight work and durability_pending do. `consumed` is a
    // retention hint for GC, not a keep-alive / prepareShutdown gate.
    _ = consumed;
    _ = worker_done;
    if (durability_pending) return true;
    return status == .running or status == .waiting_approval;
}

/// Durable-first publication: terminal statuses are only visible on tail/list
/// once the store receipt has landed (`committed_store_revision` set and
/// `durability_pending` clear). Until then the wire status stays non-terminal
/// so clients never observe `completed`/`failed`/`aborted` pre-commit.
fn chatTurnPublishedStatus(turn: *const ChatTurn) ChatTurnStatus {
    if (turn.durability_pending) {
        return switch (turn.status) {
            .completed, .failed, .aborted => .running,
            .running, .waiting_approval => turn.status,
        };
    }
    return turn.status;
}

fn sleepMs(milliseconds: i64) void {
    platform_runtime.sleepMillis(@intCast(@max(milliseconds, 0)));
}

fn isManagedSessionId(session_id: []const u8) bool {
    return std.mem.startsWith(u8, session_id, "managed:");
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
    // Durable-first: list never publishes terminal status pre-commit.
    try s.write(@tagName(chatTurnPublishedStatus(turn)));
    try s.objectField("next_seq");
    try s.write(turn.next_seq);
    try s.objectField("provider_thread_id");
    if (turn.provider_thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("pending_approval");
    try writePendingApproval(s, turn.pending_approval);
    try s.objectField("committed_store_revision");
    if (turn.committed_store_revision) |value| try s.write(value) else try s.write(null);
    try s.objectField("durability_pending");
    try s.write(turn.durability_pending);
    try s.endObject();
}

fn writeChatTurnTail(s: *std.json.Stringify, turn: *const ChatTurn, after_seq: u64) !void {
    try s.beginObject();
    try s.objectField("status");
    // Durable-first: tail status=completed/failed/aborted only with the receipt.
    try s.write(@tagName(chatTurnPublishedStatus(turn)));
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
    // M4 durable-commit publication: present only after the store receipt.
    try s.objectField("committed_store_revision");
    if (turn.committed_store_revision) |value| try s.write(value) else try s.write(null);
    // Compaction horizon is owned by the live tail; null until M5 compaction.
    try s.objectField("events_compacted_before_seq");
    try s.write(null);
    try s.objectField("durability_pending");
    try s.write(turn.durability_pending);
    try s.objectField("durability_error");
    if (turn.durability_error) |value| try s.write(value) else try s.write(null);
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
    const user_message_id = try optionalDupe(allocator, params, "message_id");
    errdefer if (user_message_id) |value| allocator.free(value);
    // MINOR-7: wire test_stub is only honored when the hermetic stub env is
    // also set, so a production client cannot force canned durable rows.
    // Env alone still enables the offline worker for hermetic ITs.
    const env_stub = chatStubEnabledFromEnv(allocator);
    const wire_stub = jsonBool(params.object.get("test_stub") orelse .null) orelse false;
    const use_stub = env_stub or (wire_stub and env_stub);
    turn.* = .{
        .allocator = allocator,
        .turn_id = try requiredDupe(allocator, params, "turn_id"),
        .workspace_id = try requiredDupe(allocator, params, "workspace_id"),
        .local_thread_id = try requiredDupe(allocator, params, "local_thread_id"),
        .request = request,
        .owned_image_paths = image_paths,
        .started_at_ms = nowMs(),
        .user_message_id = user_message_id,
        .use_stub = use_stub,
    };
    return turn;
}

fn chatTurnThread(daemon: *Daemon, turn: *ChatTurn) void {
    const allocator = daemon.allocator;
    // Acceptance staging before provider work so a mid-turn kill still leaves
    // the user row + running ledger for the interrupted sweep. Must not run
    // under lockDaemon (the accept path holds it for chat.turn.start).
    // Amendment-2 F1: staging failure is no longer swallowed — surface on the
    // turn and skip provider work. Terminal commit still re-upserts the user
    // row (self-healing) when staging partially succeeded; a total staging
    // failure fails the turn loudly so the GUI does not wait forever.
    var staging_failed = false;
    stageAcceptedChatTurn(daemon, turn) catch |err| {
        log.warn("chat turn acceptance staging failed turn_id={s} err={s}", .{ turn.turn_id, @errorName(err) });
        lockTurn(turn);
        turn.status = .failed;
        if (turn.durability_error) |old| allocator.free(old);
        turn.durability_error = allocator.dupe(u8, @errorName(err)) catch null;
        if (turn.error_message) |old| allocator.free(old);
        turn.error_message = allocator.dupe(u8, "acceptance staging failed") catch null;
        turn.appendStringEvent(allocator, "failed", "message", turn.error_message orelse "acceptance staging failed");
        turn.finished_at_ms = nowMs();
        turn.mutex.unlock();
        staging_failed = true;
    };
    if (staging_failed) {
        finalizeChatTurnWorker(daemon, turn);
        return;
    }
    // NIT-3: use_stub already folded the env at creation; do not re-eval.
    if (turn.use_stub) {
        runStubChatTurn(allocator, turn);
    } else {
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
        if (!(turn.cancel_requested or turn.status == .aborted)) {
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
        } else {
            turn.status = .aborted;
        }
        turn.mutex.unlock();
    }

    finalizeChatTurnWorker(daemon, turn);
}

/// Common post-worker bookkeeping: durability_pending then store commit outside
/// both the turn lock and lockDaemon (store service seam only). Bounded retry
/// with backoff sleeps taken while holding NO locks (MAJOR-3).
fn finalizeChatTurnWorker(daemon: *Daemon, turn: *ChatTurn) void {
    const should_commit = daemonStoreIsOpen(daemon);
    lockTurn(turn);
    turn.finished_at_ms = turn.finished_at_ms orelse nowMs();
    if (should_commit) {
        turn.durability_pending = true;
    } else {
        // MINOR-3 / MINOR-V2: clear pending when there is no writer (accept may
        // have armed it) and surface store_closed so the lost commit is not
        // silent (sibling of the commit-time store_closed branch).
        turn.durability_pending = false;
        if (turn.durability_error) |old| daemon.allocator.free(old);
        turn.durability_error = daemon.allocator.dupe(u8, "store_closed") catch null;
    }
    turn.worker_done = true;
    turn.mutex.unlock();
    if (!should_commit) return;

    // 3 attempts total; up to 2 lock-free backoffs between them (50, 250 ms).
    const backoffs_ms = [_]u64{ 50, 250 };
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        commitChatTurnDurable(daemon, turn) catch |err| {
            log.warn(
                "chat turn durable commit failed turn_id={s} attempt={d} err={s}",
                .{ turn.turn_id, attempt + 1, @errorName(err) },
            );
            lockTurn(turn);
            if (turn.durability_error) |old| daemon.allocator.free(old);
            turn.durability_error = daemon.allocator.dupe(u8, @errorName(err)) catch null;
            // durability_pending stays true (unconsumable; keep-alive holds).
            turn.mutex.unlock();
            if (attempt + 1 >= 3) return; // exhausted: design §2 terminal state
            platform_runtime.sleepMillis(backoffs_ms[attempt]);
            continue;
        };
        // Success: clear any prior attempt's error marker.
        lockTurn(turn);
        if (turn.durability_error) |old| {
            daemon.allocator.free(old);
            turn.durability_error = null;
        }
        turn.mutex.unlock();
        return;
    }
}

fn daemonStoreIsOpen(daemon: *Daemon) bool {
    lockDaemon(daemon);
    defer daemon.mutex.unlock();
    return daemon.store_service != null;
}

/// Hermetic offline provider. Prompt tokens:
/// - contains "fail" → failed
/// - contains "slow" → sleep then complete (cancel may abort)
/// - otherwise complete with a canned assistant delta.
fn runStubChatTurn(allocator: std.mem.Allocator, turn: *ChatTurn) void {
    const prompt = turn.request.prompt;
    const want_fail = std.mem.indexOf(u8, prompt, "fail") != null;
    const want_slow = std.mem.indexOf(u8, prompt, "slow") != null;
    if (want_slow) {
        // Keep the stall short enough for IT budgets but long enough to race a kill.
        platform_runtime.sleepMillis(400);
    }
    lockTurn(turn);
    defer turn.mutex.unlock();
    if (turn.cancel_requested or turn.status == .aborted) {
        // NIT-2: cancel path may already have set aborted + appended the event.
        if (turn.status != .aborted) {
            turn.status = .aborted;
            turn.appendEvent(allocator, "aborted", "{}");
        }
        turn.finished_at_ms = nowMs();
        return;
    }
    if (want_fail) {
        turn.status = .failed;
        turn.error_message = allocator.dupe(u8, "stub failure") catch null;
        turn.appendStringEvent(allocator, "failed", "message", "stub failure");
        turn.finished_at_ms = nowMs();
        return;
    }
    turn.status = .completed;
    if (turn.provider_thread_id) |old| allocator.free(old);
    turn.provider_thread_id = allocator.dupe(u8, "stub-provider-thread") catch null;
    turn.result_reply_text = allocator.dupe(u8, "stub-ok") catch null;
    turn.appendStringEvent(allocator, "assistant_delta", "text", "stub-ok");
    turn.appendEvent(allocator, "completed", "{}");
    turn.finished_at_ms = nowMs();
}

fn chatStubEnabledFromEnv(allocator: std.mem.Allocator) bool {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_CHAT_STUB_ENV_NAME) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        error.OutOfMemory => return false,
        error.InvalidWtf8 => return false,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "0")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    return true;
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

fn appendTestChatTurn(
    daemon: *Daemon,
    allocator: std.mem.Allocator,
    turn_id: []const u8,
    workspace_id: []const u8,
    project_path: []const u8,
    thread_title: []const u8,
    prompt: []const u8,
    status: ChatTurnStatus,
    started_at_ms: i64,
) !*ChatTurn {
    const turn = try allocator.create(ChatTurn);
    var owns_turn = true;
    defer if (owns_turn) allocator.destroy(turn);

    var owned_turn_id: ?[]u8 = null;
    defer if (owned_turn_id) |value| allocator.free(value);
    owned_turn_id = try allocator.dupe(u8, turn_id);
    var owned_workspace_id: ?[]u8 = null;
    defer if (owned_workspace_id) |value| allocator.free(value);
    owned_workspace_id = try allocator.dupe(u8, workspace_id);
    var owned_local_thread_id: ?[]u8 = null;
    defer if (owned_local_thread_id) |value| allocator.free(value);
    owned_local_thread_id = try allocator.dupe(u8, "local-thread");
    var owned_project_path: ?[]u8 = null;
    defer if (owned_project_path) |value| allocator.free(value);
    owned_project_path = try allocator.dupe(u8, project_path);
    var owned_prompt: ?[]u8 = null;
    defer if (owned_prompt) |value| allocator.free(value);
    owned_prompt = try allocator.dupe(u8, prompt);
    var owned_thread_title: ?[]u8 = null;
    defer if (owned_thread_title) |value| allocator.free(value);
    owned_thread_title = try allocator.dupe(u8, thread_title);
    var owned_image_paths: ?[]const []const u8 = null;
    defer if (owned_image_paths) |value| allocator.free(value);
    owned_image_paths = try allocator.alloc([]const u8, 0);

    turn.* = .{
        .allocator = allocator,
        .turn_id = owned_turn_id.?,
        .workspace_id = owned_workspace_id.?,
        .local_thread_id = owned_local_thread_id.?,
        .request = .{
            .provider = .claude,
            .harness_kind = .local_cli,
            .project_path = owned_project_path.?,
            .prompt = owned_prompt.?,
            .thread_title = owned_thread_title.?,
        },
        .owned_image_paths = owned_image_paths.?,
        .started_at_ms = started_at_ms,
        .status = status,
        .worker_done = status == .completed or status == .failed or status == .aborted,
    };
    try daemon.chat_turns.append(allocator, turn);
    owned_turn_id = null;
    owned_workspace_id = null;
    owned_local_thread_id = null;
    owned_project_path = null;
    owned_prompt = null;
    owned_thread_title = null;
    owned_image_paths = null;
    owns_turn = false;
    return turn;
}

test "chat turns project into process.list as turn records" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-project-a");
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-project-empty");
    _ = try appendTestChatTurn(&daemon, allocator, "projected-turn", "turn-project-a", "/tmp/project-a", "Chat title", "streaming prompt", .running, 10);

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.list","params":{"workspace":{"workspace_id":"turn-project-a"}}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const processes = parsed.value.object.get("result").?.object.get("processes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), processes.len);
    try std.testing.expectEqualStrings("turn:projected-turn", processes[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("gui_agent", processes[0].object.get("owner_kind").?.string);
    try std.testing.expectEqualStrings("running", processes[0].object.get("status").?.string);

    const other_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.list","params":{"workspace":{"workspace_id":"turn-project-empty"}}}
    );
    defer allocator.free(other_response);
    var other_parsed = try std.json.parseFromSlice(std.json.Value, allocator, other_response, .{});
    defer other_parsed.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        other_parsed.value.object.get("result").?.object.get("processes").?.array.items.len,
    );
}

test "finished retained turns report terminal status and wait maps them" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-finished");
    _ = try appendTestChatTurn(&daemon, allocator, "finished-turn", "turn-finished", "/tmp/finished", "Finished title", "failed prompt", .failed, 20);

    const list_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.list","params":{"workspace":{"workspace_id":"turn-finished"}}}
    );
    defer allocator.free(list_response);
    var listed = try std.json.parseFromSlice(std.json.Value, allocator, list_response, .{});
    defer listed.deinit();
    const processes = listed.value.object.get("result").?.object.get("processes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), processes.len);
    try std.testing.expectEqualStrings("failed", processes[0].object.get("status").?.string);

    const wait_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.wait","params":{"workspace":{"workspace_id":"turn-finished"},"process_id":"turn:finished-turn"}}
    );
    defer allocator.free(wait_response);
    var waited = try std.json.parseFromSlice(std.json.Value, allocator, wait_response, .{});
    defer waited.deinit();
    const result = waited.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("failed", result.get("terminal_state").?.string);
    try std.testing.expect(!result.get("timed_out").?.bool);
    try std.testing.expect(result.get("outcome").? == .null);
}

test "turn records are derived not stored" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-derived");
    _ = try appendTestChatTurn(&daemon, allocator, "derived-turn", "turn-derived", "/tmp/derived", "", "prompt", .running, 30);

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.list","params":{"workspace":{"workspace_id":"turn-derived"}}}
    );
    defer allocator.free(response);
    try std.testing.expectEqual(@as(usize, 0), daemon.registry.workspace("turn-derived").?.external_processes.items.len);
}

test "process.inspect resolves turn: ids and rejects malformed turn ids" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-inspect");
    _ = try appendTestChatTurn(&daemon, allocator, "inspect-turn", "turn-inspect", "/tmp/inspect", "Inspect title", "inspect prompt", .running, 40);

    const happy = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.inspect","params":{"workspace":{"workspace_id":"turn-inspect"},"process_id":"turn:inspect-turn"}}
    );
    defer allocator.free(happy);
    var happy_parsed = try std.json.parseFromSlice(std.json.Value, allocator, happy, .{});
    defer happy_parsed.deinit();
    const process = happy_parsed.value.object.get("result").?.object.get("process").?.object;
    try std.testing.expectEqualStrings("turn:inspect-turn", process.get("id").?.string);
    try std.testing.expectEqualStrings("gui_agent", process.get("owner_kind").?.string);
    try std.testing.expectEqualStrings("running", process.get("status").?.string);
    try std.testing.expectEqualStrings("", process.get("command").?.string);

    const malformed = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.inspect","params":{"workspace":{"workspace_id":"turn-inspect"},"process_id":"turn:"}}
    );
    defer allocator.free(malformed);
    var malformed_parsed = try std.json.parseFromSlice(std.json.Value, allocator, malformed, .{});
    defer malformed_parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        malformed_parsed.value.object.get("error").?.object.get("code").?.string,
    );

    // Missing turn: same not-found for both inspect and wait (no stored fall-through).
    const missing_inspect = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"process.inspect","params":{"workspace":{"workspace_id":"turn-inspect"},"process_id":"turn:missing-turn"}}
    );
    defer allocator.free(missing_inspect);
    var missing_inspect_parsed = try std.json.parseFromSlice(std.json.Value, allocator, missing_inspect, .{});
    defer missing_inspect_parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        missing_inspect_parsed.value.object.get("error").?.object.get("code").?.string,
    );

    const missing_wait = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"process.wait","params":{"workspace":{"workspace_id":"turn-inspect"},"process_id":"turn:missing-turn"}}
    );
    defer allocator.free(missing_wait);
    var missing_wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, missing_wait, .{});
    defer missing_wait_parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        missing_wait_parsed.value.object.get("error").?.object.get("code").?.string,
    );
}

test "stored external process snapshot preserves owner fields" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "ext-snapshot");

    var process = try process_registry.ExternalProcess.init(
        allocator,
        "ext-snapshot",
        "external-owned-1",
        "cargo build",
        "/tmp/ext",
        "background_task",
        "Nightly build",
        "client-ext-42",
    );
    process.generation = 7;
    process.started_at_ms = 99;
    _ = try daemon.registry.registerExternalProcess(allocator, "ext-snapshot", process);

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.list","params":{"workspace":{"workspace_id":"ext-snapshot"}}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const processes = parsed.value.object.get("result").?.object.get("processes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), processes.len);
    const snapshot = processes[0].object;
    try std.testing.expectEqualStrings("external-owned-1", snapshot.get("id").?.string);
    try std.testing.expectEqualStrings("background_task", snapshot.get("owner_kind").?.string);
    try std.testing.expectEqualStrings("Nightly build", snapshot.get("owner_title").?.string);
    try std.testing.expectEqualStrings("client-ext-42", snapshot.get("client_id").?.string);
    try std.testing.expectEqual(@as(i64, 7), snapshot.get("generation").?.integer);

    const inspect = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.inspect","params":{"workspace":{"workspace_id":"ext-snapshot"},"process_id":"external-owned-1"}}
    );
    defer allocator.free(inspect);
    var inspect_parsed = try std.json.parseFromSlice(std.json.Value, allocator, inspect, .{});
    defer inspect_parsed.deinit();
    const inspected = inspect_parsed.value.object.get("result").?.object.get("process").?.object;
    try std.testing.expectEqualStrings("background_task", inspected.get("owner_kind").?.string);
    try std.testing.expectEqualStrings("client-ext-42", inspected.get("client_id").?.string);
    try std.testing.expectEqual(@as(i64, 7), inspected.get("generation").?.integer);
}

test "turn: prefix takes precedence over stored external ids in inspect and wait" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-precedence");
    _ = try appendTestChatTurn(&daemon, allocator, "collide", "turn-precedence", "/tmp/prec", "Turn title", "turn prompt", .failed, 50);

    // A stored external that reuses the turn: id must not win over the turn.
    const process = try process_registry.ExternalProcess.init(
        allocator,
        "turn-precedence",
        "turn:collide",
        "stored-command",
        "/tmp/prec",
        "stored_kind",
        "Stored title",
        "client-stored",
    );
    _ = try daemon.registry.registerExternalProcess(allocator, "turn-precedence", process);

    const inspect = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.inspect","params":{"workspace":{"workspace_id":"turn-precedence"},"process_id":"turn:collide"}}
    );
    defer allocator.free(inspect);
    var inspect_parsed = try std.json.parseFromSlice(std.json.Value, allocator, inspect, .{});
    defer inspect_parsed.deinit();
    const inspected = inspect_parsed.value.object.get("result").?.object.get("process").?.object;
    try std.testing.expectEqualStrings("gui_agent", inspected.get("owner_kind").?.string);
    try std.testing.expectEqualStrings("failed", inspected.get("status").?.string);

    const wait = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.wait","params":{"workspace":{"workspace_id":"turn-precedence"},"process_id":"turn:collide"}}
    );
    defer allocator.free(wait);
    var wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, wait, .{});
    defer wait_parsed.deinit();
    const wait_result = wait_parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("failed", wait_result.get("terminal_state").?.string);
    try std.testing.expect(!wait_result.get("timed_out").?.bool);
}

test "turn: miss does not fall through to stored external ids in inspect or wait" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "turn-miss");

    // Only a stored external reuses the turn: prefix; no live chat turn exists.
    const process = try process_registry.ExternalProcess.init(
        allocator,
        "turn-miss",
        "turn:only-stored",
        "stored-command",
        "/tmp/miss",
        "stored_kind",
        "Stored title",
        "client-stored",
    );
    _ = try daemon.registry.registerExternalProcess(allocator, "turn-miss", process);

    const inspect = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"process.inspect","params":{"workspace":{"workspace_id":"turn-miss"},"process_id":"turn:only-stored"}}
    );
    defer allocator.free(inspect);
    var inspect_parsed = try std.json.parseFromSlice(std.json.Value, allocator, inspect, .{});
    defer inspect_parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        inspect_parsed.value.object.get("error").?.object.get("code").?.string,
    );

    const wait = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"process.wait","params":{"workspace":{"workspace_id":"turn-miss"},"process_id":"turn:only-stored"}}
    );
    defer allocator.free(wait);
    var wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, wait, .{});
    defer wait_parsed.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        wait_parsed.value.object.get("error").?.object.get("code").?.string,
    );
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

test "process.start rejects unknown definitions and unstartable platforms" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config =
        \\processes:
        \\  windows-only:
        \\    command_windows: "pwsh.exe"
    ;
    var file = try tmp.dir.createFile(std.testing.io, "verde.yml", .{});
    try file.writeStreamingAll(std.testing.io, config);
    file.close(std.testing.io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const workspace_path = path_buf[0..path_len];
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const unknown_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"process.start\",\"params\":{{\"workspace\":{{\"workspace_path\":\"{s}\"}},\"name\":\"missing\"}}}}",
        .{workspace_path},
    );
    defer allocator.free(unknown_request);
    const unknown_response = try daemon.handleSlowRegistryRequest(allocator, unknown_request);
    defer allocator.free(unknown_response);
    var unknown = try std.json.parseFromSlice(std.json.Value, allocator, unknown_response, .{});
    defer unknown.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_RESOURCE_NOT_FOUND,
        jsonString(unknown.value.object.get("error").?.object.get("code").?).?,
    );
    const unknown_workspace = daemon.registry.workspaceByPath(allocator, workspace_path, nowMs()) orelse return error.WorkspaceRecordMissing;
    try std.testing.expectEqual(@as(usize, 0), unknown_workspace.managed_processes.items.len);

    const unstartable_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"process.start\",\"params\":{{\"workspace\":{{\"workspace_path\":\"{s}\"}},\"name\":\"windows-only\"}}}}",
        .{workspace_path},
    );
    defer allocator.free(unstartable_request);
    const unstartable_response = try daemon.handleSlowRegistryRequest(allocator, unstartable_request);
    defer allocator.free(unstartable_response);
    var unstartable = try std.json.parseFromSlice(std.json.Value, allocator, unstartable_response, .{});
    defer unstartable.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_INVALID_STATE,
        jsonString(unstartable.value.object.get("error").?.object.get("code").?).?,
    );
    try std.testing.expectEqual(@as(usize, 0), unknown_workspace.managed_processes.items.len);
}

test "process.start cap returns a structured managed-process limit" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config =
        \\processes:
        \\  overflow-target:
        \\    command: "/bin/true"
    ;
    var file = try tmp.dir.createFile(std.testing.io, "verde.yml", .{});
    try file.writeStreamingAll(std.testing.io, config);
    file.close(std.testing.io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const workspace_path = path_buf[0..path_len];
    var daemon = Daemon.initWithPrefPath(allocator, workspace_path);
    defer daemon.deinit();
    const workspace_id = try workspace_identity.deriveProjectId(allocator, workspace_path);
    defer allocator.free(workspace_id);
    _ = try daemon.registry.registerWorkspacePath(allocator, workspace_id, workspace_path, nowMs());

    var name_buffer: [32]u8 = undefined;
    for (0..stack.MAX_PROCESS_DEFINITIONS) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "existing-{d}", .{index});
        _ = try daemon.registry.ensureManagedProcess(allocator, workspace_id, name, "/bin/true", @intCast(index));
    }

    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"process.start\",\"params\":{{\"workspace\":{{\"workspace_path\":\"{s}\"}},\"name\":\"overflow-target\"}}}}",
        .{workspace_path},
    );
    defer allocator.free(request);
    const response = try daemon.handleSlowRegistryRequest(allocator, request);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const error_value = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_STATE, error_value.get("code").?.string);
    const data = error_value.get("data").?.object;
    try std.testing.expectEqualStrings("managed_process", data.get("resource").?.string);
    try std.testing.expectEqual(@as(i64, stack.MAX_PROCESS_DEFINITIONS), data.get("limit").?.integer);
    try std.testing.expectEqual(stack.MAX_PROCESS_DEFINITIONS, daemon.registry.workspace(workspace_id).?.managed_processes.items.len);
}

test "failed managed stop keeps a consistent failed runtime state" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const process = try daemon.registry.ensureManagedProcess(allocator, "stop-failure", "worker", "/bin/cat", nowMs());
    try process.transition(.start, nowMs());
    try process.transition(.started, nowMs());

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"process.stop","params":{"workspace":{"workspace_id":"stop-failure"},"process_id":"proc:stop-failure:worker"}}
    , .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    var work = try daemon.prepareSlowProcess(allocator, params, .stop, "", "proc:stop-failure:worker", null, false);
    defer work.deinit(allocator);
    try std.testing.expectEqual(process_registry.ManagedProcessRuntimeState.running, process.runtime.state);

    var phase: SlowProcessPhaseResult = .{ .failure = .invalid_state };
    const response = try daemon.finishSlowProcess(parsed.value.object.get("id").?, &work, &phase);
    defer allocator.free(response);
    try std.testing.expectEqual(process_registry.ManagedProcessRuntimeState.failed, process.runtime.state);
    try std.testing.expectEqual(@as(usize, 0), daemon.registry_jobs.len());
}

test "process start/stop transitions and job queue dedupe" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    _ = try daemon.registry.ensureWorkspace(allocator, "process-dedupe");
    _ = try daemon.registry.registerWorkspacePath(allocator, "process-dedupe", "/tmp", nowMs());
    _ = try daemon.registry.ensureManagedProcess(allocator, "process-dedupe", "worker", "", nowMs());

    const queued = try process_registry.RegistryJob.init(
        allocator,
        .start_managed_process,
        "process-dedupe",
        "proc:process-dedupe:worker",
        "client-a",
    );
    try daemon.registry_jobs.push(allocator, queued);
    const dedupe_response = try daemon.handleSlowRegistryRequest(allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"process.start","params":{"workspace":{"workspace_id":"process-dedupe"},"name":"worker"}}
    );
    defer allocator.free(dedupe_response);
    var dedupe = try std.json.parseFromSlice(std.json.Value, allocator, dedupe_response, .{});
    defer dedupe.deinit();
    try std.testing.expectEqualStrings(
        headless.registry.ERR_INVALID_STATE,
        jsonString(dedupe.value.object.get("error").?.object.get("code").?).?,
    );
    var removed = daemon.registry_jobs.take().?;
    removed.deinit(allocator);

    var runtime: process_registry.ManagedProcessRuntime = .{};
    try runtime.transition(.start, 1);
    try std.testing.expectError(error.InvalidManagedProcessTransition, runtime.transition(.start, 2));
    try runtime.transition(.started, 3);
    try runtime.transition(.stop, 4);
    try std.testing.expectEqual(process_registry.ManagedProcessRuntimeState.stopped, runtime.state);

    for (0..process_registry.REGISTRY_JOB_QUEUE_MAX) |index| {
        var process_id_buf: [32]u8 = undefined;
        const process_id = try std.fmt.bufPrint(&process_id_buf, "proc:full:{d}", .{index});
        const job = try process_registry.RegistryJob.init(allocator, .load_config, "full", process_id, "");
        try daemon.registry_jobs.push(allocator, job);
    }
    const full_response = try daemon.handleSlowRegistryRequest(allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"process.start","params":{"workspace":{"workspace_path":"/tmp/process-queue-full"},"name":"worker"}}
    );
    defer allocator.free(full_response);
    var full = try std.json.parseFromSlice(std.json.Value, allocator, full_response, .{});
    defer full.deinit();
    const full_error = full.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_STATE, jsonString(full_error.get("code").?).?);
    const data = full_error.get("data").?;
    try std.testing.expectEqualStrings("registry_job_queue", jsonString(data.object.get("resource").?).?);
    try std.testing.expectEqual(@as(i64, process_registry.REGISTRY_JOB_QUEUE_MAX), data.object.get("limit").?.integer);
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

test "daemon keep-alive is durability_pending and live work only (M4-P4)" {
    // Live work keeps the daemon.
    try std.testing.expect(chatTurnKeepsDaemonAlive(.running, false, false, false));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.waiting_approval, false, false, false));
    // M4-P4: committed terminal turns no longer keep-alive regardless of consume.
    try std.testing.expect(!chatTurnKeepsDaemonAlive(.completed, false, true, false));
    try std.testing.expect(!chatTurnKeepsDaemonAlive(.failed, false, true, false));
    try std.testing.expect(!chatTurnKeepsDaemonAlive(.aborted, false, true, false));
    try std.testing.expect(!chatTurnKeepsDaemonAlive(.completed, true, true, false));
    // Durable commit in flight still keeps the daemon alive (even if consumed).
    try std.testing.expect(chatTurnKeepsDaemonAlive(.completed, true, true, true));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.completed, false, true, true));
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
    const error_value = prepared.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_STATE, jsonString(error_value.get("code").?).?);
    const data = error_value.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), data.get("running_sessions").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
    try std.testing.expect(!daemon.shouldExitForIdle());

    // Existing live session is preserved; replacement must wait, not kill.
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    try std.testing.expect(daemon.sessions.items[0].running);
}

test "prepareShutdown accepts committed unconsumed turns; blocks on durability_pending" {
    // M4-P4 gate flip: item 1 drops "completed-but-unconsumed" and gains
    // "no durability_pending turns". Consume is a retention hint only.
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
        .durability_pending = false,
        .committed_store_revision = 1,
    };
    try daemon.chat_turns.append(allocator, turn);

    // Committed unconsumed: prepare accepts (no keep-alive).
    const prepare_ok = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare_ok);
    var prepared_ok = try std.json.parseFromSlice(std.json.Value, allocator, prepare_ok, .{});
    defer prepared_ok.deinit();
    const ok_result = prepared_ok.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(ok_result.get("accepted") orelse .null).?);
    try std.testing.expect(jsonBool(ok_result.get("safe_to_exit") orelse .null).?);
    try std.testing.expect(daemon.shutdown_requested);
    try std.testing.expect(!daemon.accepting_mutations);
    try std.testing.expectEqual(@as(usize, 1), daemon.chat_turns.items.len);
    try std.testing.expect(!daemon.chat_turns.items[0].consumed);

    // Reset drain so we can pin the durability_pending refusal arm.
    daemon.shutdown_requested = false;
    daemon.accepting_mutations = true;
    turn.durability_pending = true;
    turn.committed_store_revision = null;

    const prepare_pending = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare_pending);
    var prepared_pending = try std.json.parseFromSlice(std.json.Value, allocator, prepare_pending, .{});
    defer prepared_pending.deinit();
    const error_value = prepared_pending.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_STATE, jsonString(error_value.get("code").?).?);
    const data = error_value.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), data.get("turns").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
}

test "prepare shutdown refuses on every shared live-state gate and preserves accepting" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;

    const managed = try daemon.registry.ensureManagedProcess(allocator, "prepare-gates", "worker", "/bin/cat", nowMs());
    try managed.transition(.start, nowMs());
    const managed_response = try daemon.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.prepareShutdown\",\"params\":{}}");
    defer allocator.free(managed_response);
    var managed_parsed = try std.json.parseFromSlice(std.json.Value, allocator, managed_response, .{});
    defer managed_parsed.deinit();
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_STATE, managed_parsed.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 1), managed_parsed.value.object.get("error").?.object.get("data").?.object.get("managed").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    try managed.transition(.stop, nowMs());

    var lease = try daemon.registry.acquireLease(allocator, "prepare-gates", "owner", "client", "build", &[_][]const u8{"build"}, false, 0, nowMs());
    defer lease.deinit(allocator);
    const lease_response = try daemon.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"daemon.prepareShutdown\",\"params\":{}}");
    defer allocator.free(lease_response);
    var lease_parsed = try std.json.parseFromSlice(std.json.Value, allocator, lease_response, .{});
    defer lease_parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), lease_parsed.value.object.get("error").?.object.get("data").?.object.get("leases").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    _ = daemon.registry.releaseLease(allocator, "prepare-gates", "owner", lease.lease.id, nowMs());

    const job = try process_registry.RegistryJob.init(allocator, .start_managed_process, "prepare-gates", "proc:prepare-gates:worker", "client");
    try daemon.registry_jobs.push(allocator, job);
    const job_response = try daemon.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"daemon.prepareShutdown\",\"params\":{}}");
    defer allocator.free(job_response);
    var job_parsed = try std.json.parseFromSlice(std.json.Value, allocator, job_response, .{});
    defer job_parsed.deinit();
    const job_data = job_parsed.value.object.get("error").?.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), job_data.get("registry_jobs").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    var removed_job = daemon.registry_jobs.take().?;
    removed_job.deinit(allocator);

    const register_response = try daemon.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"daemon.client.register\",\"params\":{}}");
    defer allocator.free(register_response);
    try std.testing.expect(std.mem.indexOf(u8, register_response, "client_id") != null);
}

test "idle exit ignores retained outcomes and notifications" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = 0;
    _ = try daemon.registry.observeTerminalProcess(allocator, "retained-state", .{
        .process_identity = 7,
        .session_id = "retained-session",
        .command = "/bin/true",
        .cwd = ".",
        .started_at_ms = 1,
        .observed_at_ms = 1,
        .dock_id = 0,
        .owner_kind = "terminal",
        .owner_title = "retained-session",
    }, .{});
    try std.testing.expect(try daemon.registry.finishTerminalProcess(allocator, "retained-state", "retained-session", .{ .exit_code = 0 }, 2));
    try daemon.registry.queueNotification(allocator, "retained-state", "owner", "build", 2);
    try std.testing.expect(!daemon.shouldExitForIdle());
    daemon.idle_since_ms = nowMs() - 1;
    try std.testing.expect(daemon.shouldExitForIdle());
}

test "orphaned client sessions are reaped after the grace window" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.test_retention_override_ms = 100;

    const register_response = try daemon.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.client.register\",\"params\":{}}");
    defer allocator.free(register_response);
    var registered = try std.json.parseFromSlice(std.json.Value, allocator, register_response, .{});
    defer registered.deinit();
    const client_id = registered.value.object.get("result").?.object.get("client_id").?.string;
    const create_request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.create\",\"params\":{{\"id\":\"orphan-session\",\"workspace_id\":\"orphan-workspace\",\"client_id\":\"{s}\",\"cwd\":\".\",\"command\":[\"/bin/cat\"],\"pref_path\":\"/tmp\"}}}}", .{client_id});
    defer allocator.free(create_request);
    const create_response = try daemon.handleRequest(create_request);
    defer allocator.free(create_response);
    try std.testing.expect(daemon.find("orphan-session") != null);
    const client = daemon.registry.client(client_id).?;
    client.closed = true;
    client.closed_at_ms = nowMs() - 101;
    daemon.reapOrphanedSessions(nowMs());
    try std.testing.expect(daemon.find("orphan-session").?.registry_finished);
}

test "daemon.stop scoped to a client releases leases and kills only its sessions" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const client_a = try daemon.registry.registerClient(allocator, true, nowMs());
    const client_b = try daemon.registry.registerClient(allocator, false, nowMs());
    const client_a_id = try allocator.dupe(u8, client_a.client_id);
    defer allocator.free(client_a_id);
    const client_b_id = try allocator.dupe(u8, client_b.client_id);
    defer allocator.free(client_b_id);
    var lease = try daemon.registry.acquireLease(allocator, "stop-client", "owner-b", client_b_id, "build", &[_][]const u8{"build"}, false, 0, nowMs());
    defer lease.deinit(allocator);

    const session = try PtySession.create(allocator, .{
        .session_id = "stop-client-session",
        .project_id = "stop-client",
        .cwd = ".",
        .command = &[_][]const u8{"/bin/cat"},
        .owner_client_id = client_b_id,
        .pref_path = "/tmp",
    });
    try daemon.sessions.append(allocator, session);
    daemon.observeSessionInRegistry(session, "/bin/cat", nowMs());
    const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.stop\",\"params\":{{\"client_id\":\"{s}\"}}}}", .{client_b_id});
    defer allocator.free(request);
    const response = try daemon.handleRequest(request);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("result") != null);
    try std.testing.expect(daemon.registry.client(client_b_id).?.closed);
    try std.testing.expect(!daemon.registry.client(client_a_id).?.closed);
    try std.testing.expectEqual(@as(usize, 0), daemon.registry.activeLeaseCount(allocator, "stop-client", nowMs()));
    try std.testing.expect(daemon.find("stop-client-session") != null);
    try std.testing.expectEqualStrings("daemon.stop", daemon.registry.workspace("stop-client").?.terminal_process_outcomes.items[0].cancellation_reason.?);
}

test "daemon.stop force stops managed processes but spares persistent client sessions" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const persistent = try daemon.registry.registerClient(allocator, true, nowMs());
    const stopper = try daemon.registry.registerClient(allocator, false, nowMs());
    const persistent_id = try allocator.dupe(u8, persistent.client_id);
    defer allocator.free(persistent_id);
    const stopper_id = try allocator.dupe(u8, stopper.client_id);
    defer allocator.free(stopper_id);
    const managed = try daemon.registry.ensureManagedProcess(allocator, "force-stop", "worker", "/bin/cat", nowMs());
    try managed.transition(.start, nowMs());
    try managed.transition(.started, nowMs());
    const session = try PtySession.create(allocator, .{
        .session_id = "persistent-stop-session",
        .project_id = "force-stop",
        .cwd = ".",
        .command = &[_][]const u8{"/bin/cat"},
        .owner_client_id = persistent_id,
        .pref_path = "/tmp",
    });
    try daemon.sessions.append(allocator, session);

    const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.stop\",\"params\":{{\"client_id\":\"{s}\",\"force\":true}}}}", .{stopper_id});
    defer allocator.free(request);
    const response = try daemon.handleRequest(request);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("result") != null);
    try std.testing.expectEqual(process_registry.ManagedProcessRuntimeState.stopped, managed.runtime_state);
    try std.testing.expect(daemon.find("persistent-stop-session").?.running);
    try std.testing.expect(!daemon.registry.client(persistent_id).?.closed);
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
        // Full store mutation surface participates in the drain gate (S3).
        "state.snapshot.replace",
        "workspace.upsert",
        "chat.thread.upsert",
        "chat.message.append",
        "surface.upsert",
        "surface.clear",
        "notification.chatCompletion.upsert",
        "notification.chatCompletion.clear",
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

    const slow_response = try daemon.handleSlowRegistryRequest(allocator,
        \\{"jsonrpc":"2.0","id":99,"method":"process.start","params":{}}
    );
    defer allocator.free(slow_response);
    var slow_parsed = try std.json.parseFromSlice(std.json.Value, allocator, slow_response, .{});
    defer slow_parsed.deinit();
    try std.testing.expectEqualStrings(
        "invalid_state",
        jsonString(slow_parsed.value.object.get("error").?.object.get("code").?).?,
    );
}

fn attachTestStoreService(daemon: *Daemon, db_path: []const u8) !void {
    try attachTestStoreServiceWithFault(daemon, db_path, .none);
}

fn attachTestStoreServiceWithFault(daemon: *Daemon, db_path: []const u8, fault: daemon_store.StoreFault) !void {
    const service = try daemon.allocator.create(StoreService);
    errdefer daemon.allocator.destroy(service);
    service.* = .{
        .store = try daemon_store.Store.initWithFault(daemon.allocator, db_path, fault),
    };
    daemon.store_service = service;
}

fn detachTestStoreService(daemon: *Daemon) void {
    if (daemon.store_service) |service| {
        service.store.deinit();
        daemon.allocator.destroy(service);
        daemon.store_service = null;
    }
}

fn testStoreDbPath(tmp: *std.testing.TmpDir) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    return std.fs.path.join(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
}

fn registerTestClientId(daemon: *Daemon, allocator: std.mem.Allocator) ![]const u8 {
    const response = try daemon.handleRequest("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.client.register\",\"params\":{}}");
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const client_id = jsonString(parsed.value.object.get("result").?.object.get("client_id").?).?;
    return try allocator.dupe(u8, client_id);
}

fn expectErrorCodeMessage(response: []const u8, allocator: std.mem.Allocator, code: []const u8, message: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const error_value = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(code, jsonString(error_value.get("code").?).?);
    try std.testing.expectEqualStrings(message, jsonString(error_value.get("message").?).?);
}

test "store methods report capability_unavailable on a store-less daemon" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const upsert = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"workspace.upsert","params":{"mutation":{"request_key":"k","client_id":"c"},"workspace":{"workspace_id":"w","label":"L","path":"/w"}}}
    );
    defer allocator.free(upsert);
    try expectErrorCodeMessage(upsert, allocator, headless.protocol.ERR_CAPABILITY_UNAVAILABLE, "store capability is unavailable");

    const status = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.storeStatus","params":{}}
    );
    defer allocator.free(status);
    try expectErrorCodeMessage(status, allocator, headless.protocol.ERR_CAPABILITY_UNAVAILABLE, "store capability is unavailable");
}

test "store dispatch commits mutations and replays duplicates" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    const client_id = try registerTestClientId(&daemon, allocator);
    defer allocator.free(client_id);

    const upsert_request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"workspace.upsert","params":{{"mutation":{{"request_key":"ws-1","client_id":"{s}"}},"workspace":{{"workspace_id":"ws-1","label":"One","path":"/ws-1"}}}}}}
    , .{client_id});
    defer allocator.free(upsert_request);
    const first_response = try daemon.handleRequest(upsert_request);
    defer allocator.free(first_response);
    var first = try std.json.parseFromSlice(std.json.Value, allocator, first_response, .{});
    defer first.deinit();
    const first_result = first.value.object.get("result").?.object;
    try std.testing.expect(first_result.get("applied").?.bool);
    try std.testing.expect(!first_result.get("duplicate").?.bool);
    try std.testing.expectEqual(@as(i64, 1), first_result.get("store_revision").?.integer);

    const replay_response = try daemon.handleRequest(upsert_request);
    defer allocator.free(replay_response);
    var replay = try std.json.parseFromSlice(std.json.Value, allocator, replay_response, .{});
    defer replay.deinit();
    const replay_result = replay.value.object.get("result").?.object;
    try std.testing.expectEqual(first_result.get("store_revision").?.integer, replay_result.get("store_revision").?.integer);
    try std.testing.expectEqual(first_result.get("applied").?.bool, replay_result.get("applied").?.bool);
    try std.testing.expectEqual(first_result.get("duplicate").?.bool, replay_result.get("duplicate").?.bool);

    const status_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"daemon.storeStatus","params":{}}
    );
    defer allocator.free(status_response);
    var status = try std.json.parseFromSlice(std.json.Value, allocator, status_response, .{});
    defer status.deinit();
    const status_result = status.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, 1), status_result.get("store_revision").?.integer);
    try std.testing.expectEqualStrings("open", jsonString(status_result.get("drain_state").?).?);
    try std.testing.expect(status_result.get("writer_ready").?.bool);
}

test "store mutations from unknown clients are invalid_params" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"workspace.upsert","params":{"mutation":{"request_key":"k","client_id":"not-registered"},"workspace":{"workspace_id":"w","label":"L","path":"/w"}}}
    );
    defer allocator.free(response);
    try expectErrorCodeMessage(response, allocator, headless.protocol.ERR_INVALID_PARAMS, "unknown client_id");
}

test "draining daemon rejects store mutators with invalid_state" {
    const allocator = std.testing.allocator;
    // Store-less: drain outranks capability_unavailable for mutators.
    {
        var daemon = Daemon.init(allocator);
        defer daemon.deinit();
        daemon.accepting_mutations = false;
        const response = try daemon.handleRequest(
            \\{"jsonrpc":"2.0","id":1,"method":"workspace.upsert","params":{"mutation":{"request_key":"k","client_id":"c"},"workspace":{"workspace_id":"w","label":"L","path":"/w"}}}
        );
        defer allocator.free(response);
        try expectErrorCodeMessage(
            response,
            allocator,
            headless.protocol.ERR_INVALID_STATE,
            "daemon is preparing shutdown and is not accepting mutations",
        );
    }

    // Store-enabled: storeStatus still answers while draining.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);
    daemon.accepting_mutations = false;

    const status_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.storeStatus","params":{}}
    );
    defer allocator.free(status_response);
    var status = try std.json.parseFromSlice(std.json.Value, allocator, status_response, .{});
    defer status.deinit();
    try std.testing.expect(status.value.object.get("result") != null);
    try std.testing.expectEqualStrings("open", jsonString(status.value.object.get("result").?.object.get("drain_state").?).?);
}

test "store errors map to wire codes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);
    const client_id = try registerTestClientId(&daemon, allocator);
    defer allocator.free(client_id);

    const first = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"workspace.upsert","params":{{"mutation":{{"request_key":"ws-a","client_id":"{s}"}},"workspace":{{"workspace_id":"ws-a","label":"A","path":"/a"}}}}}}
    , .{client_id});
    defer allocator.free(first);
    const first_response = try daemon.handleRequest(first);
    defer allocator.free(first_response);
    try std.testing.expect(std.mem.indexOf(u8, first_response, "\"applied\":true") != null);

    // Stale expected_store_revision → conflict.
    const stale = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"workspace.upsert","params":{{"mutation":{{"request_key":"ws-b","client_id":"{s}","expected_store_revision":0}},"workspace":{{"workspace_id":"ws-b","label":"B","path":"/b"}}}}}}
    , .{client_id});
    defer allocator.free(stale);
    const stale_response = try daemon.handleRequest(stale);
    defer allocator.free(stale_response);
    try expectErrorCodeMessage(stale_response, allocator, headless.protocol.ERR_CONFLICT, "store revision conflict");
}

test "store error precedence capability_unavailable outranks invalid_params" {
    // (ii) > (iii): store-less daemon with malformed params still reports
    // capability_unavailable, not invalid_params.
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"workspace.upsert","params":{"mutation":{"request_key":"k","client_id":"not-registered"},"workspace":123}}
    );
    defer allocator.free(response);
    try expectErrorCodeMessage(
        response,
        allocator,
        headless.protocol.ERR_CAPABILITY_UNAVAILABLE,
        "store capability is unavailable",
    );
}

test "store error precedence invalid_params outranks unknown client_id" {
    // (iii) > (iv): decode failure wins over unknown-client validation even when
    // a client_id string is present in the broken payload.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"workspace.upsert","params":{"mutation":{"request_key":"k","client_id":"not-registered"},"workspace":123}}
    );
    defer allocator.free(response);
    try expectErrorCodeMessage(response, allocator, headless.protocol.ERR_INVALID_PARAMS, "invalid params");
}

fn expectWriteApplied(response: []const u8, allocator: std.mem.Allocator, expected_revision: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("applied").?.bool);
    try std.testing.expect(!result.get("duplicate").?.bool);
    try std.testing.expectEqual(expected_revision, result.get("store_revision").?.integer);
}

test "store dispatch covers the full mutation surface" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);
    const client_id = try registerTestClientId(&daemon, allocator);
    defer allocator.free(client_id);

    // workspace → thread → message → surface → completion → snapshot.replace → surface.clear → completion.clear
    const workspace_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"workspace.upsert","params":{{"mutation":{{"request_key":"full-ws","client_id":"{s}"}},"workspace":{{"workspace_id":"ws-full","label":"Full","path":"/ws-full"}}}}}}
    , .{client_id});
    defer allocator.free(workspace_req);
    const workspace_response = try daemon.handleRequest(workspace_req);
    defer allocator.free(workspace_response);
    try expectWriteApplied(workspace_response, allocator, 1);

    const thread_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":3,"method":"chat.thread.upsert","params":{{"mutation":{{"request_key":"full-thread","client_id":"{s}","expected_store_revision":1}},"workspace_id":"ws-full","thread":{{"local_thread_id":"t1","title":"Thread"}}}}}}
    , .{client_id});
    defer allocator.free(thread_req);
    const thread_response = try daemon.handleRequest(thread_req);
    defer allocator.free(thread_response);
    try expectWriteApplied(thread_response, allocator, 2);

    const message_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":4,"method":"chat.message.append","params":{{"mutation":{{"request_key":"full-msg","client_id":"{s}","expected_store_revision":2}},"workspace_id":"ws-full","thread_id":"t1","message":{{"message_id":"m1","role":"user","author":"You","body":"hello"}}}}}}
    , .{client_id});
    defer allocator.free(message_req);
    const message_response = try daemon.handleRequest(message_req);
    defer allocator.free(message_response);
    try expectWriteApplied(message_response, allocator, 3);

    // Natural-duplicate replay (fresh request_key, same identity + payload).
    const message_dup_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":5,"method":"chat.message.append","params":{{"mutation":{{"request_key":"full-msg-dup","client_id":"{s}","expected_store_revision":3}},"workspace_id":"ws-full","thread_id":"t1","message":{{"message_id":"m1","role":"user","author":"You","body":"hello"}}}}}}
    , .{client_id});
    defer allocator.free(message_dup_req);
    const message_dup_response = try daemon.handleRequest(message_dup_req);
    defer allocator.free(message_dup_response);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, message_dup_response, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try std.testing.expect(!result.get("applied").?.bool);
        try std.testing.expect(result.get("duplicate").?.bool);
        try std.testing.expectEqual(@as(i64, 3), result.get("store_revision").?.integer);
    }

    // Same message key, different payload → conflict.
    const message_conflict_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":6,"method":"chat.message.append","params":{{"mutation":{{"request_key":"full-msg-conflict","client_id":"{s}","expected_store_revision":3}},"workspace_id":"ws-full","thread_id":"t1","message":{{"message_id":"m1","role":"user","author":"You","body":"changed"}}}}}}
    , .{client_id});
    defer allocator.free(message_conflict_req);
    const message_conflict_response = try daemon.handleRequest(message_conflict_req);
    defer allocator.free(message_conflict_response);
    try expectErrorCodeMessage(message_conflict_response, allocator, headless.protocol.ERR_CONFLICT, "store revision conflict");

    // thread.upsert against a missing workspace → resource_not_found.
    const missing_ws_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":7,"method":"chat.thread.upsert","params":{{"mutation":{{"request_key":"full-missing-ws","client_id":"{s}","expected_store_revision":3}},"workspace_id":"does-not-exist","thread":{{"local_thread_id":"t-missing","title":"Missing"}}}}}}
    , .{client_id});
    defer allocator.free(missing_ws_req);
    const missing_ws_response = try daemon.handleRequest(missing_ws_req);
    defer allocator.free(missing_ws_response);
    try expectErrorCodeMessage(missing_ws_response, allocator, headless.protocol.ERR_RESOURCE_NOT_FOUND, "resource not found");

    const surface_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":8,"method":"surface.upsert","params":{{"mutation":{{"request_key":"full-surface","client_id":"{s}","expected_store_revision":3}},"surface":{{"session_id":"s1","status":"done"}}}}}}
    , .{client_id});
    defer allocator.free(surface_req);
    const surface_response = try daemon.handleRequest(surface_req);
    defer allocator.free(surface_response);
    try expectWriteApplied(surface_response, allocator, 4);

    const completion_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":9,"method":"notification.chatCompletion.upsert","params":{{"mutation":{{"request_key":"full-completion","client_id":"{s}","expected_store_revision":4}},"completion":{{"workspace_id":"ws-full","local_thread_id":"t1","completed_at_ms":42}}}}}}
    , .{client_id});
    defer allocator.free(completion_req);
    const completion_response = try daemon.handleRequest(completion_req);
    defer allocator.free(completion_response);
    try expectWriteApplied(completion_response, allocator, 5);

    const snapshot_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":10,"method":"state.snapshot.replace","params":{{"mutation":{{"request_key":"full-snapshot","client_id":"{s}","expected_store_revision":5}},"snapshot":{{"schema_version":1,"store_revision":5,"workspaces":[{{"workspace_id":"ws-snap","label":"Snap","path":"/ws-snap"}}],"surface_states":[{{"session_id":"s-snap","status":"idle"}}],"chat_completions":[{{"workspace_id":"ws-snap","local_thread_id":"t-snap","completed_at_ms":1}}]}}}}}}
    , .{client_id});
    defer allocator.free(snapshot_req);
    const snapshot_response = try daemon.handleRequest(snapshot_req);
    defer allocator.free(snapshot_response);
    try expectWriteApplied(snapshot_response, allocator, 6);

    const surface_clear_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":11,"method":"surface.clear","params":{{"mutation":{{"request_key":"full-surface-clear","client_id":"{s}","expected_store_revision":6}},"session_id":"s-snap"}}}}
    , .{client_id});
    defer allocator.free(surface_clear_req);
    const surface_clear_response = try daemon.handleRequest(surface_clear_req);
    defer allocator.free(surface_clear_response);
    try expectWriteApplied(surface_clear_response, allocator, 7);

    const completion_clear_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":12,"method":"notification.chatCompletion.clear","params":{{"mutation":{{"request_key":"full-completion-clear","client_id":"{s}","expected_store_revision":7}},"workspace_id":"ws-snap","local_thread_id":"t-snap"}}}}
    , .{client_id});
    defer allocator.free(completion_clear_req);
    const completion_clear_response = try daemon.handleRequest(completion_clear_req);
    defer allocator.free(completion_clear_response);
    try expectWriteApplied(completion_clear_response, allocator, 8);
}

test "prepare accepts active leases when store is active for transfer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    var lease = try daemon.registry.acquireLease(
        allocator,
        "transfer-ws",
        "owner",
        "client",
        "build",
        &[_][]const u8{"build"},
        false,
        0,
        nowMs(),
    );
    defer lease.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), daemon.countActiveLeases(nowMs()));

    // Store active: leases transfer and no longer block prepare (M2-DT-b).
    const accepted = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(accepted);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, accepted, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(result.get("accepted") orelse .null).?);
    try std.testing.expect(jsonBool(result.get("safe_to_exit") orelse .null).?);
    try std.testing.expectEqual(@as(i64, 1), result.get("active_leases").?.integer);
    try std.testing.expect(daemon.shutdown_requested);
    try std.testing.expect(!daemon.accepting_mutations);
    // Drain must be allowed to exit despite the live lease.
    try std.testing.expect(daemon.shouldExitForIdle());
}

test "prepare still refuses active leases when store is dormant" {
    // Production path: no hermetic store → existing DaemonReplacementBlocked gate.
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;

    var lease = try daemon.registry.acquireLease(
        allocator,
        "dormant-ws",
        "owner",
        "client",
        "build",
        &[_][]const u8{"build"},
        false,
        0,
        nowMs(),
    );
    defer lease.deinit(allocator);

    const refused = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(refused);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, refused, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("error").?.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), data.get("leases").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
}

test "transfer persist and import seed preserves lease id and prunes expired" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    const now_ms: i64 = 10_000;
    var predecessor = Daemon.init(allocator);
    defer predecessor.deinit();
    try attachTestStoreService(&predecessor, db_path);

    var keep = try predecessor.registry.acquireLease(
        allocator,
        "seed-ws",
        "owner-keep",
        "client-keep",
        "build",
        &[_][]const u8{"build"},
        false,
        60_000,
        now_ms,
    );
    defer keep.deinit(allocator);
    const keep_id = try allocator.dupe(u8, keep.lease.id);
    defer allocator.free(keep_id);

    var expired = try predecessor.registry.acquireLease(
        allocator,
        "seed-ws",
        "owner-exp",
        "client-exp",
        "test",
        &[_][]const u8{"test"},
        false,
        1_000,
        now_ms - 2_000,
    );
    defer expired.deinit(allocator);
    // Force the second lease past its expiry for import pruning.
    predecessor.registry.workspace("seed-ws").?.leases.items[1].expires_at_ms = now_ms - 1;

    _ = try predecessor.registry.observeTerminalProcess(allocator, "seed-ws", .{
        .process_identity = 42,
        .session_id = "seed-session",
        .command = "/bin/true",
        .cwd = ".",
        .started_at_ms = now_ms - 100,
        .observed_at_ms = now_ms - 100,
        .dock_id = 0,
        .owner_kind = "terminal",
        .owner_title = "seed-session",
    }, .{});
    try std.testing.expect(try predecessor.registry.finishTerminalProcess(
        allocator,
        "seed-ws",
        "seed-session",
        .{ .exit_code = 0 },
        now_ms - 50,
    ));

    const before_revision = try predecessor.store_service.?.store.storeRevision();
    try persistTransferSnapshot(&predecessor, predecessor.store_service.?);
    const after_revision = try predecessor.store_service.?.store.storeRevision();
    try std.testing.expectEqual(before_revision + 1, after_revision);

    // Close predecessor store; successor reopens the same path.
    detachTestStoreService(&predecessor);

    var successor = Daemon.init(allocator);
    defer successor.deinit();
    try attachTestStoreService(&successor, db_path);
    defer detachTestStoreService(&successor);

    var imported = try successor.store_service.?.store.importLeasesAndOutcomes(now_ms);
    defer imported.deinit(allocator);
    try seedRegistryFromTransfer(&successor, &imported);

    // Import does not bump store_revision; only the drain commit did.
    try std.testing.expectEqual(after_revision, try successor.store_service.?.store.storeRevision());

    const workspace = successor.registry.workspace("seed-ws") orelse return error.TestExpectedWorkspace;
    try std.testing.expectEqual(@as(usize, 1), workspace.leases.items.len);
    try std.testing.expectEqualStrings(keep_id, workspace.leases.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), workspace.terminal_process_outcomes.items.len);
    try std.testing.expectEqualStrings("seed-session", workspace.terminal_process_outcomes.items[0].session_id);
}

test "finalizeSessionizerStore nulls store before endpoint release seam and is idempotent" {
    // Seam pin for MAJOR-1: on_closing calls finalizeSessionizerStore while the
    // endpoint is still owned; by the time endpoint teardown runs, store_service
    // is already null and the transfer revision has advanced. A second call
    // (finishSessionizerServer fallback) is a no-op.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);

    var lease = try daemon.registry.acquireLease(
        allocator,
        "finalize-ws",
        "owner",
        "client",
        "build",
        &[_][]const u8{"build"},
        false,
        0,
        nowMs(),
    );
    defer lease.deinit(allocator);

    const before = try daemon.store_service.?.store.storeRevision();
    var stop = std.atomic.Value(bool).init(false);
    var context: SessionizerServerContext = .{
        .daemon = &daemon,
        .endpoint = "",
        .pid_path = "",
        .stop_requested = &stop,
    };

    finalizeSessionizerStore(&context);
    try std.testing.expect(daemon.store_service == null);
    // Re-open the same path read-only via a fresh store to assert the bump.
    var reopened = try daemon_store.Store.init(allocator, db_path);
    defer reopened.deinit();
    try std.testing.expectEqual(before + 1, try reopened.storeRevision());

    // Idempotent: second finalize must not panic or re-open.
    finalizeSessionizerStore(&context);
    try std.testing.expect(daemon.store_service == null);
}

test "seed raises next_terminal_generation above imported outcome generations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var predecessor = Daemon.init(allocator);
    defer predecessor.deinit();
    try attachTestStoreService(&predecessor, db_path);

    // Manually plant an outcome with a high generation so the successor must
    // mint ids starting at generation+1.
    const workspace = try predecessor.registry.ensureWorkspace(allocator, "gen-ws");
    // Use a recent wall-clock finish time so import pruning (TTL 15m) retains it.
    const finished_at = nowMs();
    const outcome: process_registry.TerminalProcessOutcome = .{
        .workspace_id = try allocator.dupe(u8, "gen-ws"),
        .process_id = try allocator.dupe(u8, "term:reused-session:7"),
        .generation = 7,
        .session_id = try allocator.dupe(u8, "reused-session"),
        .command = try allocator.dupe(u8, "/bin/true"),
        .cwd = try allocator.dupe(u8, "."),
        .pid = null,
        .process_group = null,
        .started_at_ms = finished_at - 100,
        .finished_at_ms = finished_at,
        .dock_id = 0,
        .pane_id = null,
        .owner_kind = try allocator.dupe(u8, "terminal"),
        .owner_title = try allocator.dupe(u8, "reused-session"),
        .provider = null,
        .status = .completed,
        .exit_code = 0,
        .signal = null,
        .cancellation_reason = null,
    };
    try workspace.terminal_process_outcomes.append(allocator, outcome);

    try persistTransferSnapshot(&predecessor, predecessor.store_service.?);
    detachTestStoreService(&predecessor);

    var successor = Daemon.init(allocator);
    defer successor.deinit();
    try attachTestStoreService(&successor, db_path);
    defer detachTestStoreService(&successor);

    var imported = try successor.store_service.?.store.importLeasesAndOutcomes(finished_at);
    defer imported.deinit(allocator);
    try seedRegistryFromTransfer(&successor, &imported);

    const seeded = successor.registry.workspace("gen-ws") orelse return error.TestExpectedWorkspace;
    try std.testing.expect(seeded.next_terminal_generation >= 8);

    // A new observation on the same session id must mint generation >= 8.
    const tracked = try successor.registry.observeTerminalProcess(allocator, "gen-ws", .{
        .process_identity = 99,
        .session_id = "reused-session",
        .command = "/bin/cat",
        .cwd = ".",
        .started_at_ms = nowMs(),
        .observed_at_ms = nowMs(),
        .dock_id = 0,
        .owner_kind = "terminal",
        .owner_title = "reused-session",
    }, .{});
    try std.testing.expect(tracked.generation >= 8);
    try std.testing.expect(std.mem.indexOf(u8, tracked.process_id, ":8") != null or tracked.generation > 7);
}

test "prepare shutdown refuses while store writes are in flight" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    // Simulate a write in flight without holding the service mutex.
    _ = daemon.store_service.?.in_flight.fetchAdd(1, .monotonic);

    const refused = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(refused);
    var refused_parsed = try std.json.parseFromSlice(std.json.Value, allocator, refused, .{});
    defer refused_parsed.deinit();
    const refused_error = refused_parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(headless.registry.ERR_INVALID_STATE, jsonString(refused_error.get("code").?).?);
    try std.testing.expectEqual(@as(i64, 1), refused_error.get("data").?.object.get("store_writes_in_flight").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
    try std.testing.expect(!daemon.store_service.?.draining);

    _ = daemon.store_service.?.in_flight.fetchSub(1, .monotonic);

    const accepted = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(accepted);
    var accepted_parsed = try std.json.parseFromSlice(std.json.Value, allocator, accepted, .{});
    defer accepted_parsed.deinit();
    const accepted_result = accepted_parsed.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(accepted_result.get("accepted") orelse .null).?);
    try std.testing.expect(daemon.shutdown_requested);
    try std.testing.expect(!daemon.accepting_mutations);
    try std.testing.expect(daemon.store_service.?.draining);

    const status = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"daemon.storeStatus","params":{}}
    );
    defer allocator.free(status);
    var status_parsed = try std.json.parseFromSlice(std.json.Value, allocator, status, .{});
    defer status_parsed.deinit();
    const status_result = status_parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("draining", jsonString(status_result.get("drain_state").?).?);
    try std.testing.expect(!status_result.get("writer_ready").?.bool);
}

test "prepare shutdown accepts while store status is in flight" {
    // storeStatus must not inflate in_flight / store_writes_in_flight. A concurrent
    // status-shaped hold of the service mutex (slow SQLite read) must not refuse prepare.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    // Completed storeStatus leaves in_flight at 0 (reads are not counted).
    const status_before = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.storeStatus","params":{}}
    );
    defer allocator.free(status_before);
    try std.testing.expectEqual(@as(usize, 0), daemon.store_service.?.in_flight.load(.monotonic));

    // Hold the service mutex as a long status SQLite read would, without a write counter bump.
    const service = daemon.store_service.?;
    const holder = try std.Thread.spawn(.{}, struct {
        fn run(svc: *StoreService) void {
            lockStoreService(svc);
            platform_runtime.sleepMillis(150);
            svc.mutex.unlock();
        }
    }.run, .{service});

    platform_runtime.sleepMillis(20);
    // Prepare only consults in_flight (writes), not the service mutex.
    const prepare = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare);
    holder.join();

    var prepare_parsed = try std.json.parseFromSlice(std.json.Value, allocator, prepare, .{});
    defer prepare_parsed.deinit();
    const prepare_result = prepare_parsed.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(prepare_result.get("accepted") orelse .null).?);
    try std.testing.expect(daemon.store_service.?.draining);
    try std.testing.expectEqual(@as(usize, 0), daemon.store_service.?.in_flight.load(.monotonic));
}

test "drained daemon rejects store mutators with invalid_state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);
    const client_id = try registerTestClientId(&daemon, allocator);
    defer allocator.free(client_id);

    const prepare = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare);
    var prepare_parsed = try std.json.parseFromSlice(std.json.Value, allocator, prepare, .{});
    defer prepare_parsed.deinit();
    try std.testing.expect(jsonBool(prepare_parsed.value.object.get("result").?.object.get("accepted") orelse .null).?);

    const append = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"chat.message.append","params":{{"mutation":{{"request_key":"post-drain","client_id":"{s}"}},"workspace_id":"ws","thread_id":"t","message":{{"message_id":"m","role":"user","author":"You","body":"x"}}}}}}
    , .{client_id});
    defer allocator.free(append);
    const append_response = try daemon.handleRequest(append);
    defer allocator.free(append_response);
    try expectErrorCodeMessage(
        append_response,
        allocator,
        headless.protocol.ERR_INVALID_STATE,
        "daemon is preparing shutdown and is not accepting mutations",
    );

    // storeStatus still answers after accepted prepare.
    const status = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"daemon.storeStatus","params":{}}
    );
    defer allocator.free(status);
    var status_parsed = try std.json.parseFromSlice(std.json.Value, allocator, status, .{});
    defer status_parsed.deinit();
    const status_result = status_parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("draining", jsonString(status_result.get("drain_state").?).?);
    try std.testing.expect(!status_result.get("writer_ready").?.bool);
}

/// Worker for the lock-boundary pin: runs a store mutation that stalls at commit.
const SlowStoreCommitContext = struct {
    daemon: *Daemon,
    request: []const u8,
    response: ?[]u8 = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn slowStoreCommitThread(ctx: *SlowStoreCommitContext) void {
    defer ctx.done.store(true, .release);
    ctx.response = ctx.daemon.handleRequest(ctx.request) catch |err| {
        ctx.err = err;
        return;
    };
}

test "daemon lock stays free during a slow store commit" {
    // Normative pin of ground-truth rule #4: SQLite work (including a commit
    // stall) must never hold lockDaemon. Probe with a non-store read that does
    // not take the store service mutex (daemon.storeStatus would block).
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreServiceWithFault(&daemon, db_path, .commit_stall);
    defer detachTestStoreService(&daemon);

    const client_id = try registerTestClientId(&daemon, allocator);
    defer allocator.free(client_id);

    const upsert_request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"workspace.upsert","params":{{"mutation":{{"request_key":"slow-commit","client_id":"{s}"}},"workspace":{{"workspace_id":"ws-slow","label":"Slow","path":"/ws-slow"}}}}}}
    , .{client_id});
    defer allocator.free(upsert_request);

    var ctx: SlowStoreCommitContext = .{
        .daemon = &daemon,
        .request = upsert_request,
    };
    const worker = try std.Thread.spawn(.{}, slowStoreCommitThread, .{&ctx});
    // Join on every path (assertion failure included) so detach/deinit never
    // races a live worker still holding the store connection.
    var worker_joined = false;
    defer if (!worker_joined) worker.join();

    // Give the worker time to enter the commit stall under the store mutex.
    platform_runtime.sleepMillis(100);

    var probes: usize = 0;
    while (!ctx.done.load(.acquire)) : (probes += 1) {
        const started = platform_runtime.monotonicTimestampNs();
        // session.list is a non-store read; must complete well under the stall.
        const list_response = try daemon.handleRequest(
            \\{"jsonrpc":"2.0","id":99,"method":"session.list","params":{}}
        );
        defer allocator.free(list_response);
        const elapsed_ms = (platform_runtime.monotonicTimestampNs() - started) / std.time.ns_per_ms;
        try std.testing.expect(elapsed_ms < 200);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, list_response, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
        if (probes > 40) break; // stall is ~1500ms; do not loop forever
        platform_runtime.sleepMillis(50);
    }
    // The probes>40 escape can leave the loop with the worker still committing;
    // join before reading ctx so its final writes cannot race these loads.
    worker.join();
    worker_joined = true;

    if (ctx.err) |err| return err;
    const mutation_response = ctx.response orelse return error.SlowStoreCommitMissingResponse;
    defer allocator.free(mutation_response);
    var mut_parsed = try std.json.parseFromSlice(std.json.Value, allocator, mutation_response, .{});
    defer mut_parsed.deinit();
    const result = mut_parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("applied").?.bool);
    try std.testing.expect(probes >= 1);
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

test "durable turn commit is exactly once and interrupt sweep marks running rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    // Seed a dangling running row as if a predecessor was killed mid-turn.
    {
        lockStoreService(daemon.store_service.?);
        defer daemon.store_service.?.mutex.unlock();
        _ = try daemon.store_service.?.store.upsertWorkspace(.{
            .mutation = .{ .request_key = "sweep-ws", .client_id = "daemon" },
            .workspace = .{ .workspace_id = "ws-sweep", .label = "Sweep", .path = "/tmp/sweep" },
        });
        _ = try daemon.store_service.?.store.upsertThread(.{
            .mutation = .{ .request_key = "sweep-thread", .client_id = "daemon" },
            .workspace_id = "ws-sweep",
            .thread = .{ .local_thread_id = "t-sweep", .title = "Sweep", .provider = "codex", .harness = "local_cli" },
        });
        try daemon.store_service.?.store.conn.exec(
            "insert into chat_turns (turn_id, workspace_id, local_thread_id, status, started_at_ms, provider) values ('turn-running', 'ws-sweep', 't-sweep', 'running', 1, 'codex')",
            .{},
        );
        try sweepInterruptedChatTurns(&daemon.store_service.?.store);
        var row = (try daemon.store_service.?.store.conn.row(
            "select status from chat_turns where turn_id = 'turn-running'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("interrupted", row.text(0));
    }

    // MAJOR-1/2 pin: pre-stage a 'running' row for the turn that will commit
    // (upsert supersedes it inside commitTurn; no external delete).
    {
        lockStoreService(daemon.store_service.?);
        defer daemon.store_service.?.mutex.unlock();
        try daemon.store_service.?.store.conn.exec(
            "insert into chat_turns (turn_id, workspace_id, local_thread_id, status, started_at_ms, provider, user_message_id) values ('turn-commit-once', 'ws-commit', 't-commit', 'running', 10, 'codex', 'user-1')",
            .{},
        );
    }

    const turn = try allocator.create(ChatTurn);
    const image_paths: []const []const u8 = &.{};
    turn.* = .{
        .allocator = allocator,
        .turn_id = try allocator.dupe(u8, "turn-commit-once"),
        .workspace_id = try allocator.dupe(u8, "ws-commit"),
        .local_thread_id = try allocator.dupe(u8, "t-commit"),
        .request = .{
            .provider = .codex,
            .harness_kind = .local_cli,
            .project_path = try allocator.dupe(u8, "/tmp/commit"),
            .prompt = try allocator.dupe(u8, "hello"),
            .thread_title = try allocator.dupe(u8, "Commit"),
        },
        .owned_image_paths = image_paths,
        .started_at_ms = 10,
        .finished_at_ms = 20,
        .status = .completed,
        .worker_done = true,
        .durability_pending = true,
        .result_reply_text = try allocator.dupe(u8, "reply"),
        .user_message_id = try allocator.dupe(u8, "user-1"),
    };
    turn.appendStringEvent(allocator, "assistant_delta", "text", "reply");
    turn.appendEvent(allocator, "completed", "{}");
    // Owned by daemon.chat_turns (freed in daemon.deinit).
    try daemon.chat_turns.append(allocator, turn);

    try commitChatTurnDurable(&daemon, turn);
    try std.testing.expect(turn.committed_store_revision != null);
    try std.testing.expect(!turn.durability_pending);
    const first_revision = turn.committed_store_revision.?;

    // Receipt replay: same turn commit must not append or bump again.
    turn.durability_pending = true;
    turn.committed_store_revision = null;
    try commitChatTurnDurable(&daemon, turn);
    try std.testing.expectEqual(first_revision, turn.committed_store_revision.?);
    try std.testing.expect(!turn.durability_pending);

    lockStoreService(daemon.store_service.?);
    defer daemon.store_service.?.mutex.unlock();
    var count = (try daemon.store_service.?.store.conn.row(
        "select count(*) from chat_turns where turn_id = 'turn-commit-once'",
        .{},
    )).?;
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 1), count.int(0));

    var ledger_status = (try daemon.store_service.?.store.conn.row(
        "select status from chat_turns where turn_id = 'turn-commit-once'",
        .{},
    )).?;
    defer ledger_status.deinit();
    try std.testing.expectEqualStrings("completed", ledger_status.text(0));

    var receipt = (try daemon.store_service.?.store.conn.row(
        "select count(*) from store_receipts where request_key = 'turn:turn-commit-once:commit'",
        .{},
    )).?;
    defer receipt.deinit();
    try std.testing.expectEqual(@as(i64, 1), receipt.int(0));
}

test "chat.thread.get and chat.turn.record dispatch typed durable reads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    lockStoreService(daemon.store_service.?);
    _ = try daemon.store_service.?.store.upsertWorkspace(.{
        .mutation = .{ .request_key = "dto-ws", .client_id = "daemon" },
        .workspace = .{ .workspace_id = "ws-dto", .label = "DTO", .path = "/tmp/dto" },
    });
    _ = try daemon.store_service.?.store.upsertThread(.{
        .mutation = .{ .request_key = "dto-thread", .client_id = "daemon" },
        .workspace_id = "ws-dto",
        .thread = .{ .local_thread_id = "t-dto", .title = "DTO thread", .provider = "codex", .harness = "local_cli" },
    });
    _ = try daemon.store_service.?.store.commitTurn(.{
        .turn_id = "turn-dto",
        .workspace_id = "ws-dto",
        .local_thread_id = "t-dto",
        .status = .completed,
        .started_at_ms = 1,
        .finished_at_ms = 2,
        .provider = "codex",
        .messages = &.{
            .{ .message_id = "m1", .role = "assistant", .author = "codex", .body = "hi" },
        },
    });
    daemon.store_service.?.mutex.unlock();

    const get_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.thread.get","params":{"workspace_id":"ws-dto","local_thread_id":"t-dto"}}
    );
    defer allocator.free(get_response);
    try std.testing.expect(std.mem.indexOf(u8, get_response, "\"local_thread_id\":\"t-dto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_response, "\"body\":\"hi\"") != null);

    const record_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"chat.turn.record","params":{"turn_id":"turn-dto"}}
    );
    defer allocator.free(record_response);
    try std.testing.expect(std.mem.indexOf(u8, record_response, "\"turn_id\":\"turn-dto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, record_response, "\"status\":\"completed\"") != null);

    const list_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"chat.thread.list","params":{"workspace_id":"ws-dto","limit":10}}
    );
    defer allocator.free(list_response);
    try std.testing.expect(std.mem.indexOf(u8, list_response, "\"local_thread_id\":\"t-dto\"") != null);
}

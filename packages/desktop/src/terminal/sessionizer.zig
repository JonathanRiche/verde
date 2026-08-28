//! Verde-native terminal session identity and daemon protocol helpers.
//!
//! This module is intentionally separate from `terminal.zig`: terminal UI code
//! can import these small types while the long-lived PTY owner and CLI attach
//! behavior grow here instead of being buried in the renderer/pane code.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zqlite = @import("zqlite");
const harness = @import("../providers/harness.zig");
const headless = @import("headless");
const app_config = @import("../app/config.zig");
const chat_threads = @import("../chat/threads.zig");
const db_types = @import("../db/types.zig");
const process_registry = @import("../daemon/process_registry.zig");
const repository_path = @import("../daemon/repository_path.zig");
const daemon_store = @import("../daemon/store.zig");
const daemon_runtime_identity = @import("../daemon/runtime_identity.zig");
const mcp_http = @import("../mcp/http_server.zig");
const mcp_endpoint = @import("../mcp/endpoint.zig");
const platform_ipc = @import("../platform/ipc.zig");
const platform_live_endpoint = @import("../platform/live_endpoint.zig");
const workspace_identity = @import("../platform/workspace_identity.zig");
const stack = @import("../workspace/stack.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");
const provider_models = @import("../state/provider_models.zig");
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
pub const RUNTIME_IDENTITY_FILE_NAME = daemon_runtime_identity.FILE_NAME;
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
// Version 20 repairs durable transcript roles from mixed historical codecs.
// Version 21 makes first-prompt and generated titles part of daemon-owned
// chat turns, including turns created through the MCP/headless API.
// Version 22 adds bounded live-tail replay for large provider event streams.
// Version 23 makes the authenticated MCP HTTP transport daemon-owned.
// Version 24 persists Pi and FX terminal lifecycle provider identities.
// Version 25 rebinds dedicated FX panes to Verde's lifecycle endpoint even
// when the desktop itself inherited a real Herdr session.
// Version 26 gives every Verde-owned terminal its own lifecycle endpoint so
// FX launched from an interactive shell reports to that Verde pane too.
pub const PROTOCOL_VERSION: u32 = 26;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 30;
const MAX_OUTPUT_RING: usize = 1024 * 1024;
const DAEMON_POLL_READ_BUDGET: usize = 64 * 1024;
const SESSIONIZER_MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
/// Maximum response capacity accepted by the sessionizer protocol.
pub const MAX_RESPONSE_BYTES: usize = SESSIONIZER_MAX_MESSAGE_BYTES;
const SESSIONIZER_REQUEST_TIMEOUT_MS: u32 = 5000;
/// Budget for the interactive daemon reachability probe run on the GUI event
/// thread right before staging a send (ensureDaemonInteractive). Small enough
/// that pressing Enter never visibly freezes the UI behind a busy daemon; the
/// follow-up chat.turn.start RPC still gets the full request timeout.
const SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS: u32 = 250;
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
const FX_LIFECYCLE_SOURCE = "custom:fx";
const FX_LIFECYCLE_AGENT = "fx";
const FX_REPORT_AGENT_METHOD = "pane.report_agent";
const FX_REPORT_SESSION_METHOD = "pane.report_agent_session";
const FX_PANE_RENAME_METHOD = "pane.rename";
const FX_AGENT_RENAME_METHOD = "agent.rename";
const FX_CLEAR_AUTHORITY_METHOD = "pane.clear_agent_authority";

/// Futex-parking mutex with Io-free lock()/unlock() signatures. Zig 0.16 has
/// no std.Thread.Mutex; the previous `while (!tryLock()) spinLoopHint()` spin
/// burned a full core for the entire hold time whenever a store request
/// contended with a multi-second state.snapshot.replace apply. This is the
/// exact 3-state algorithm of std.Io.Mutex; the ephemeral Threaded instance
/// is the sanctioned way to reach futexWait/futexWake from an arbitrary
/// thread (see signalChangesWaiters). Lock ordering is unchanged from the
/// spin era: lockDaemon → lockTurn and lockDaemon → journal_mutex; store
/// service mutex → journal_mutex; the journal is a leaf; the store spine is
/// never taken under lockDaemon.
const ParkingMutex = struct {
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.unlocked),

    const State = enum(u32) { unlocked, locked_once, contended };

    fn lock(m: *ParkingMutex) void {
        const initial_state = m.state.cmpxchgStrong(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);
            return;
        };
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        if (initial_state == .contended) {
            io.futexWaitUncancelable(State, &m.state.raw, .contended);
        }
        while (m.state.swap(.contended, .acquire) != .unlocked) {
            io.futexWaitUncancelable(State, &m.state.raw, .contended);
        }
    }

    fn unlock(m: *ParkingMutex) void {
        switch (m.state.swap(.unlocked, .release)) {
            .unlocked => unreachable,
            .locked_once => {},
            .contended => {
                @branchHint(.unlikely);
                var threaded = std.Io.Threaded.init_single_threaded;
                threaded.io().futexWake(State, &m.state.raw, 1);
            },
        }
    }
};

/// Store service spine: SQLite work runs under this mutex, never under lockDaemon.
const StoreService = struct {
    mutex: ParkingMutex = .{},
    store: daemon_store.Store,
    /// Mutators only; prepare-shutdown refuses while nonzero.
    in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Read-side pointer borrows that must outlive service detachment/deinit.
    lifetime_pins: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    draining: bool = false, // set by prepare-shutdown in S3
};

fn lockStoreService(service: *StoreService) void {
    service.mutex.lock();
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

/// Send a legacy-shaped daemon request through the deadline-enforced
/// cross-platform transport. Teardown call sites use this instead of the
/// direct Unix stream path, whose blocking read has no deadline.
pub fn requestAllocWithTimeout(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
    timeout_ms: u32,
) ![]u8 {
    var transport: HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .timeout_ms = timeout_ms,
    };
    var client = headlessClient(allocator, &transport);
    var call = try client.callAllocWithId(request_id, method, params);
    const response = call.takeResponse();
    call.deinit(allocator);
    return response;
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
    /// Per-request deadline. Interactive probes narrow this to the submit
    /// budget; every other request uses the shared 5s client timeout.
    timeout_ms: u32 = SESSIONIZER_REQUEST_TIMEOUT_MS,

    fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *RequestTransport = @ptrCast(@alignCast(ctx));
        const socket_path = try socketPath(self.allocator, self.pref_path);
        defer self.allocator.free(socket_path);

        // Both platforms go through the deadline transport so a busy daemon
        // surfaces error.ConnectionTimedOut after SESSIONIZER_REQUEST_TIMEOUT_MS
        // instead of blocking the caller indefinitely. The POSIX branch used
        // to connect/read with no deadline, which froze the GUI event thread
        // whenever the daemon stalled mid-request. Wire clients are bounded by
        // this timeout first; only in-process callers use the full
        // MAX_CHANGES_WAIT_MS long-poll budget (see the Q7 pinning test).
        // The deadline read path allocates its own scratch, so a caller's
        // `response_buffer` is intentionally unused here.
        const result = try platform_ipc.requestWithPeerAlloc(self.allocator, socket_path, request_json, .{
            .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
            .max_response_bytes = self.max_response_bytes,
            .timeout_ms = self.timeout_ms,
        });
        self.authenticated_server_process_id = result.server_process_id;
        return result.response;
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

/// How a failed budgeted status probe classifies the daemon endpoint.
const DaemonProbeOutcome = enum { busy, absent };

/// A deadline expiry means something holds the endpoint but answered too
/// slowly for the interactive budget (a daemon mid store-commit): alive but
/// busy. Every other transport error (no socket, connect refused, reset)
/// means nothing usable is listening.
fn daemonProbeOutcomeFromError(err: anyerror) DaemonProbeOutcome {
    return switch (err) {
        error.ConnectionTimedOut => .busy,
        else => .absent,
    };
}

/// One status round-trip under an explicit per-request deadline. Interactive
/// callers pass a sub-second budget; everything else keeps the shared client
/// timeout via requestAlloc.
fn statusProbeAlloc(allocator: std.mem.Allocator, pref_path: []const u8, timeout_ms: u32) ![]u8 {
    var transport: RequestTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .response_buffer = null,
        .timeout_ms = timeout_ms,
    };
    var client = headless.Client.init(allocator, &transport, RequestTransport.send);
    var call = try client.callAllocWithId(0, "status", .{});
    const response = call.takeResponse();
    call.deinit(allocator);
    return response;
}

/// Event-thread variant of `ensureDaemon` for the GUI submit path, bounded at
/// roughly SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS so pressing Enter never freezes
/// the UI behind a busy daemon:
/// - Healthy status within budget: done, same as ensureDaemon's happy path.
/// - Probe deadline expiry or an unparseable/over-capacity answer: the daemon
///   is alive but slow. Treat it as reachable — the follow-up chat.turn.start
///   carries its own request deadline plus idempotent lost-reply recovery, so
///   acceptance stays unambiguous and the send is not spuriously failed.
/// - Connect failure: daemon absent. Spawn it and wait only the remaining
///   interactive budget; if it has not bound yet, return an error so the
///   caller surfaces a visible retryable failure instead of blocking.
/// - Protocol mismatch: delegate to ensureDaemon's graceful replacement path.
///   Upgrades are rare and the drain's bounded waits outweigh the UI budget.
pub fn ensureDaemonInteractive(allocator: std.mem.Allocator, pref_path: []const u8, exe_path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const budget_deadline_ms = nowMs() + SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS;

    if (statusProbeAlloc(allocator, pref_path, SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS)) |response| {
        defer allocator.free(response);
        if (parseDaemonStatus(allocator, response)) |status| {
            if (status.protocol_version == PROTOCOL_VERSION) return;
            return ensureDaemon(allocator, pref_path, exe_path);
        }
        // Answered but not a status result (e.g. transport busy heartbeat):
        // something owns the endpoint, so treat it as reachable-but-busy.
        return;
    } else |err| switch (daemonProbeOutcomeFromError(err)) {
        .busy => return,
        .absent => {},
    }

    try spawnDaemon(allocator, exe_path);
    while (nowMs() <= budget_deadline_ms) {
        if (statusProbeAlloc(allocator, pref_path, SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS)) |response| {
            defer allocator.free(response);
            if (parseDaemonStatus(allocator, response)) |status| {
                if (status.protocol_version == PROTOCOL_VERSION) return;
            }
        } else |_| {}
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    return error.SessionDaemonStarting;
}

test "interactive submit probe budget and busy/absent classification are pinned" {
    // ~250ms keeps Enter responsive on the event thread; must stay well under
    // the shared client timeout wire requests are bounded by.
    try std.testing.expectEqual(@as(u32, 250), SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS);
    try std.testing.expect(SESSIONIZER_SUBMIT_PROBE_TIMEOUT_MS < SESSIONIZER_REQUEST_TIMEOUT_MS);
    // Only a deadline expiry proves a live-but-slow endpoint; everything else
    // (missing socket, refused, reset) must take the spawn path.
    try std.testing.expectEqual(DaemonProbeOutcome.busy, daemonProbeOutcomeFromError(error.ConnectionTimedOut));
    try std.testing.expectEqual(DaemonProbeOutcome.absent, daemonProbeOutcomeFromError(error.ConnectionRefused));
    try std.testing.expectEqual(DaemonProbeOutcome.absent, daemonProbeOutcomeFromError(error.FileNotFound));
    try std.testing.expectEqual(DaemonProbeOutcome.absent, daemonProbeOutcomeFromError(error.ConnectionResetByPeer));
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
    if (builtin.os.tag != .windows) {
        return allocator.dupeZ(u8, executablePathWithoutDeletedSuffix(builtin.os.tag, executable));
    }

    const resolved = resolveWindowsCliPathAlloc(allocator, executable) catch
        return allocator.dupeZ(u8, executable);
    defer allocator.free(resolved);
    return allocator.dupeZ(u8, resolved);
}

fn executablePathWithoutDeletedSuffix(comptime os_tag: std.Target.Os.Tag, executable: []const u8) []const u8 {
    const deleted_suffix = " (deleted)";
    if (os_tag == .linux and std.mem.endsWith(u8, executable, deleted_suffix)) {
        return executable[0 .. executable.len - deleted_suffix.len];
    }
    return executable;
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

/// Loads the daemon's raw MCP bearer token for inheritance by Verde-owned
/// terminal children. Provider config stores only the environment name.
pub fn mcpTokenZAlloc(allocator: std.mem.Allocator, pref_path: []const u8) !?[:0]u8 {
    if (pref_path.len == 0) return null;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var endpoint = try mcp_endpoint.load(allocator, threaded.io(), pref_path) orelse return null;
    defer endpoint.deinit(allocator);
    return try allocator.dupeSentinel(u8, endpoint.token, 0);
}

const ChildIdentity = struct {
    session_id: [:0]u8,
    project_id: [:0]u8,
    project_path: [:0]u8,
    dock_id: [:0]u8,
    pane_id: [:0]u8,
    live_endpoint: [:0]u8,
    sessionizer_endpoint: [:0]u8,
    cli_path: [:0]u8,
    mcp_token: ?[:0]u8,

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
        const mcp_token = try mcpTokenZAlloc(allocator, options.pref_path);
        errdefer if (mcp_token) |value| allocator.free(value);

        return .{
            .session_id = session_id,
            .project_id = project_id,
            .project_path = project_path,
            .dock_id = dock_id,
            .pane_id = pane_id,
            .live_endpoint = live_endpoint,
            .sessionizer_endpoint = sessionizer_endpoint,
            .cli_path = cli_path,
            .mcp_token = mcp_token,
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
        if (self.mcp_token) |value| allocator.free(value);
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
        if (identity.mcp_token) |value| _ = setenv("VERDE_MCP_TOKEN", value.ptr, 1);
        exposeTerminalLifecycleSocket(identity.sessionizer_endpoint, identity.session_id);
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
    /// FX exposes authoritative TUI lifecycle over its local socket adapter.
    fx_turn_active: bool = false,
    fx_lifecycle_sequence: u64 = 0,
    fx_provider_thread_id: ?[]u8 = null,
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
        if (self.fx_provider_thread_id) |thread_id| allocator.free(thread_id);
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
const AcceptanceOwnership = enum { owned, conflict_not_owned };

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

const SteerAudit = struct {
    const State = enum { in_flight, provider_accepted, published };

    steer_id: []u8,
    prompt: []u8,
    image_paths: []const []u8,
    state: State = .in_flight,
    event_seq: ?u64 = null,

    fn deinit(self: *SteerAudit, allocator: std.mem.Allocator) void {
        allocator.free(self.steer_id);
        allocator.free(self.prompt);
        for (self.image_paths) |path| allocator.free(path);
        allocator.free(self.image_paths);
    }
};

const SteerInvocationCapture = struct {
    provider: ?harness.Provider = null,
    thread_id: [128]u8 = undefined,
    thread_id_len: usize = 0,
    turn_id: [128]u8 = undefined,
    turn_id_len: usize = 0,

    fn record(self: *SteerInvocationCapture, provider: harness.Provider, thread_id: []const u8, turn_id: []const u8) void {
        self.provider = provider;
        self.thread_id_len = @min(thread_id.len, self.thread_id.len);
        @memcpy(self.thread_id[0..self.thread_id_len], thread_id[0..self.thread_id_len]);
        self.turn_id_len = @min(turn_id.len, self.turn_id.len);
        @memcpy(self.turn_id[0..self.turn_id_len], turn_id[0..self.turn_id_len]);
    }

    fn capturedThreadId(self: *const SteerInvocationCapture) []const u8 {
        return self.thread_id[0..self.thread_id_len];
    }

    fn capturedTurnId(self: *const SteerInvocationCapture) []const u8 {
        return self.turn_id[0..self.turn_id_len];
    }
};

const ChatTurn = struct {
    allocator: std.mem.Allocator,
    /// Owning daemon, for waking parked `chat.turn.tail wait_ms` long-pollers
    /// on event appends. Null in unit-test turns built without a daemon
    /// (nothing parks there, so no wake is needed).
    daemon: ?*Daemon = null,
    turn_id: []u8,
    workspace_id: []u8,
    local_thread_id: []u8,
    /// Runtime-local repository route resolved before provider launch. A null
    /// repository keeps the legacy absolute-path request contract local-only.
    repository_id: ?[]u8 = null,
    repository_cwd: ?[]u8 = null,
    request: send_runner.Request,
    owned_image_paths: []const []const u8,
    /// Full attachment metadata for the turn request (path + any mime /
    /// byte_size the client genuinely knew). Staged onto the durable user row
    /// at acceptance so committed transcripts keep their images.
    owned_images: []const store_protocol.Attachment = &.{},
    started_at_ms: i64 = 0,
    finished_at_ms: ?i64 = null,
    mutex: ParkingMutex = .{},
    worker_thread: ?std.Thread = null,
    events: std.ArrayList(ChatEvent) = .empty,
    /// Request identities retained for the life of the turn so an ambiguous
    /// steering response can be retried without contacting the provider twice.
    steers: std.ArrayList(SteerAudit) = .empty,
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
    /// Unit-test-only Store message override for immutable acceptance fields
    /// the public prompt API does not independently expose.
    acceptance_message_override: ?store_protocol.Message = null,
    /// Unit-test-only proof that a rejected acceptance never enters a provider.
    provider_invocation_count: ?*usize = null,
    /// Unit-test-only capture of the exact provider steering identity.
    steer_invocation_capture: ?*SteerInvocationCapture = null,
    /// Last durable-commit error name (diagnostic; dual-write-unread only).
    durability_error: ?[]u8 = null,
    provider_thread_id: ?[]u8 = null,
    active_turn_id: ?[]u8 = null,
    result_reply_text: ?[]u8 = null,
    generated_title: ?[:0]const u8 = null,
    generated_title_applied: bool = false,
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
        if (self.repository_id) |value| allocator.free(value);
        if (self.repository_cwd) |value| allocator.free(value);
        freeRunnerRequest(allocator, self.request, self.owned_image_paths);
        for (self.owned_images) |attachment| {
            allocator.free(attachment.path);
            allocator.free(attachment.mime);
        }
        if (self.owned_images.len > 0) allocator.free(self.owned_images);
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
        for (self.steers.items) |*steer| steer.deinit(allocator);
        self.steers.deinit(allocator);
        if (self.user_message_id) |value| allocator.free(value);
        if (self.durability_error) |value| allocator.free(value);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.active_turn_id) |value| allocator.free(value);
        if (self.result_reply_text) |value| allocator.free(value);
        if (self.generated_title) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        if (self.pending_approval) |*approval| approval.deinit(allocator);
        if (self.approval_call_id) |value| allocator.free(value);
        allocator.destroy(self);
    }

    fn appendEventFallible(self: *ChatTurn, allocator: std.mem.Allocator, kind: []const u8, payload_json: []const u8) !u64 {
        const owned_kind = try allocator.dupe(u8, kind);
        errdefer allocator.free(owned_kind);
        const owned_payload = try allocator.dupe(u8, payload_json);
        errdefer allocator.free(owned_payload);
        var event: ChatEvent = .{
            .seq = self.next_seq,
            .kind = owned_kind,
            .payload_json = owned_payload,
        };
        errdefer event.deinit(allocator);
        try self.events.append(allocator, event);
        const seq = self.next_seq;
        self.next_seq += 1;
        // Missed-wake protocol twin of appendJournalEntry: the event is
        // visible (under this turn's mutex) before the signal bump, and a
        // tail waiter loads the signal word before reading turn state — so
        // it either sees this event or its futex expectation is stale.
        if (self.daemon) |owner| owner.signalTurnEventWaiters();
        return seq;
    }

    fn appendEvent(self: *ChatTurn, allocator: std.mem.Allocator, kind: []const u8, payload_json: []const u8) void {
        _ = self.appendEventFallible(allocator, kind, payload_json) catch return;
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

fn initSteerAudit(
    allocator: std.mem.Allocator,
    steer_id: []const u8,
    prompt: []const u8,
    image_paths: []const []const u8,
) !SteerAudit {
    var audit: SteerAudit = .{
        .steer_id = try allocator.dupe(u8, steer_id),
        .prompt = undefined,
        .image_paths = undefined,
    };
    errdefer allocator.free(audit.steer_id);
    audit.prompt = try allocator.dupe(u8, prompt);
    errdefer allocator.free(audit.prompt);
    const owned_paths = try allocator.alloc([]u8, image_paths.len);
    var copied: usize = 0;
    errdefer {
        for (owned_paths[0..copied]) |path| allocator.free(path);
        allocator.free(owned_paths);
    }
    for (image_paths, 0..) |path, index| {
        owned_paths[index] = try allocator.dupe(u8, path);
        copied += 1;
    }
    audit.image_paths = owned_paths;
    return audit;
}

fn findSteerAuditIndex(turn: *const ChatTurn, steer_id: []const u8) ?usize {
    for (turn.steers.items, 0..) |steer, index| {
        if (std.mem.eql(u8, steer.steer_id, steer_id)) return index;
    }
    return null;
}

fn findSteerAudit(turn: *ChatTurn, steer_id: []const u8) ?*SteerAudit {
    const index = findSteerAuditIndex(turn, steer_id) orelse return null;
    return &turn.steers.items[index];
}

fn steerAuditMatches(audit: *const SteerAudit, prompt: []const u8, image_paths: []const []const u8) bool {
    if (!std.mem.eql(u8, audit.prompt, prompt) or audit.image_paths.len != image_paths.len) return false;
    for (audit.image_paths, image_paths) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn steerMessageIdAlloc(allocator: std.mem.Allocator, turn_id: []const u8, steer_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "turn:{s}:steer:{s}", .{ turn_id, steer_id });
}

/// `chat.turn.tail` steer event payload. This additive event shape is stable:
/// `{steer_id,message_id,title,body,images:[{path,mime,byte_size}]}`.
fn publishSteerAudit(allocator: std.mem.Allocator, turn: *ChatTurn, audit: *SteerAudit) !u64 {
    std.debug.assert(audit.state == .provider_accepted);
    const message_id = try steerMessageIdAlloc(allocator, turn.turn_id, audit.steer_id);
    defer allocator.free(message_id);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("steer_id");
    try s.write(audit.steer_id);
    try s.objectField("message_id");
    try s.write(message_id);
    try s.objectField("title");
    try s.write("Steering current turn");
    try s.objectField("body");
    try s.write(audit.prompt);
    try s.objectField("images");
    try s.beginArray();
    for (audit.image_paths) |path| {
        try s.write(.{ .path = path, .mime = "", .byte_size = @as(u64, 0) });
    }
    try s.endArray();
    try s.endObject();
    const payload = try writer.toOwnedSlice();
    defer allocator.free(payload);
    const seq = try turn.appendEventFallible(allocator, "steer", payload);
    audit.state = .published;
    audit.event_seq = seq;
    return seq;
}

fn steerAcceptedResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    turn_id: []const u8,
    audit: *const SteerAudit,
    duplicate: bool,
) ![]u8 {
    const message_id = try steerMessageIdAlloc(allocator, turn_id, audit.steer_id);
    defer allocator.free(message_id);
    return okValueResponse(allocator, id_value, .{
        .accepted = true,
        .turn_id = turn_id,
        .steer_id = audit.steer_id,
        .message_id = message_id,
        .event_seq = audit.event_seq.?,
        .duplicate = duplicate,
    });
}

fn freeRunnerRequest(allocator: std.mem.Allocator, request: send_runner.Request, image_paths: []const []const u8) void {
    allocator.free(request.project_path);
    if (request.cwd) |value| allocator.free(value);
    allocator.free(request.prompt);
    for (image_paths) |path| allocator.free(path);
    allocator.free(image_paths);
    if (request.provider_thread_id) |value| allocator.free(value);
    allocator.free(request.thread_title);
    if (request.model_ref) |value| allocator.free(value);
    if (request.opencode_reasoning_variant) |value| allocator.free(value);
    if (request.cursor_model_params_json) |value| allocator.free(value);
}

/// Generate an ephemeral process-local namespace. Durable runtime and store
/// identities use fallible OS entropy during the post-bind readiness phase.
fn randomEphemeralHexId(allocator: std.mem.Allocator) []u8 {
    var random_bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return allocator.dupe(u8, &hex) catch @panic("failed to allocate ephemeral daemon identity");
}

fn randomInstanceNonce(allocator: std.mem.Allocator) []u8 {
    return randomEphemeralHexId(allocator);
}

const PROVIDER_SURFACES_ALL: headless.providers_protocol.ProviderSurfaces = .{
    .native_chat = true,
    .terminal_tui = true,
    .mcp = true,
    .lifecycle = true,
};

fn nativeProviderLabel(provider: provider_models.Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex",
        .claude => "Claude",
        .cursor => "Cursor",
        .opencode => "OpenCode",
        .pi => "Pi",
        .fx => "FX",
        .grok => "Grok",
    };
}

fn nativeProviderLoginCommand(provider: provider_models.Provider) []const []const u8 {
    return switch (provider) {
        .codex => &.{ "codex", "login" },
        .claude => &.{"claude"},
        .cursor => &.{ "agent", "login" },
        .opencode => &.{ "opencode", "auth", "login" },
        .pi => &.{"pi"},
        .fx => &.{ "fx", "login" },
        .grok => &.{ "grok", "login" },
    };
}

fn nativeProviderInstalled(provider: provider_models.Provider) bool {
    return switch (provider) {
        .codex => process_env.commandExists("codex"),
        .claude => process_env.commandExists("node") and process_env.commandExists("claude"),
        .cursor => process_env.commandExists("agent"),
        .opencode => process_env.commandExists("opencode"),
        .pi => process_env.commandExists("pi"),
        .fx => process_env.commandExists("fx"),
        .grok => process_env.commandExists("grok"),
    };
}

fn providerRemediation(
    installed: bool,
    login_command: []const []const u8,
) headless.providers_protocol.Remediation {
    return if (!installed)
        .{
            .kind = "install",
            .label = "Install this provider CLI on the runtime",
        }
    else
        .{
            .kind = "login",
            .label = "Authenticate in a terminal on this runtime",
            .command = login_command,
        };
}

fn nativeProviderStatus(provider: provider_models.Provider) headless.providers_protocol.ProviderStatus {
    const installed = nativeProviderInstalled(provider);
    return .{
        .provider = @tagName(provider),
        .label = nativeProviderLabel(provider),
        .surfaces = PROVIDER_SURFACES_ALL,
        .installed = installed,
        .state = if (installed) "unknown" else "missing",
        // Provider auth protocols are intentionally heterogeneous. Until each
        // adapter has a cancellable deadline, the daemon must not occupy a
        // transport worker with a potentially unbounded login handshake.
        .authentication = "unknown",
        .remediation = providerRemediation(installed, nativeProviderLoginCommand(provider)),
    };
}

fn ampProviderStatus() headless.providers_protocol.ProviderStatus {
    const installed = process_env.commandExists("amp");
    return .{
        .provider = "amp",
        .label = "Amp",
        .surfaces = .{ .terminal_tui = true, .mcp = true, .lifecycle = true },
        .installed = installed,
        .state = if (installed) "unknown" else "missing",
        .authentication = "unknown",
        .remediation = if (installed)
            .{
                .kind = "login",
                .label = "Authenticate in a terminal on this runtime",
                .command = &.{ "amp", "login" },
            }
        else
            .{
                .kind = "install",
                .label = "Install the Amp CLI on the runtime",
            },
    };
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
    /// Stable across daemon restarts while the runtime data directory exists.
    runtime_id: []u8,
    /// Stable generation identity recreated with the runtime data directory.
    instance_id: []u8,
    registry: process_registry.ProcessRegistry,
    sessions: std.ArrayList(*PtySession) = .empty,
    chat_turns: std.ArrayList(*ChatTurn) = .empty,
    mutex: ParkingMutex = .{},
    /// Serializes verde.json snapshots and web-originated favorite updates.
    /// It is independent of lockDaemon so filesystem I/O never delays chat.
    config_mutex: ParkingMutex = .{},
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
    /// Leaf lock for the journal. Lock order: lockDaemon → journal_mutex
    /// and store service mutex → journal_mutex; the journal path never takes
    /// another lock, so no cycle is possible.
    journal_mutex: ParkingMutex = .{},
    /// M5-P3 long-poll park state. `changes_signal` is a futex word bumped by
    /// every journal append (after the leaf lock is RELEASED) and by drain;
    /// parked `core.changes` waiters sleep on it holding NO locks. The
    /// missed-wake-free protocol: a waiter loads this BEFORE reading the
    /// journal window, and the appender appends BEFORE bumping — so either
    /// the waiter's read sees the entry or its futex expectation is stale and
    /// the wait returns immediately.
    changes_signal: std.atomic.Value(u32) = .init(0),
    /// Count of currently parked long-pollers across BOTH park kinds
    /// (`core.changes` and `chat.turn.tail wait_ms`), capped at
    /// platform_ipc.MAX_PARKED_LONG_POLL_WAITERS (Q7). One shared counter
    /// keeps the transport invariant honest — at most half the worker pool
    /// parked in total, so short requests always find a free worker;
    /// per-kind counters let combined parks consume the whole pool (the
    /// saturation that rendered GUI streaming in multi-second chunks).
    /// Over-cap requests degrade to an immediate answer — never an error.
    long_poll_parked: std.atomic.Value(u32) = .init(0),
    /// Sticky drain latch (prepareShutdown accepted, or transport draining).
    /// Parked waiters terminate with the structured drain response; new
    /// positive waits degrade to immediate heartbeats.
    changes_draining: std.atomic.Value(bool) = .init(false),
    /// Turn-event long-poll park state (`chat.turn.tail` with `wait_ms`).
    /// A separate futex word from `changes_signal` so per-delta wakes never
    /// fan out to core.changes pollers: streaming deltas stay off the journal
    /// (Q10) and push through this data-plane signal instead. Bumped on every
    /// turn event append and on durable-commit publication flips.
    turn_events_signal: std.atomic.Value(u32) = .init(0),

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
            // These placeholders exist only for direct unit construction.
            // Production readiness replaces them with the secure durable pair
            // before any client can observe the daemon handshake.
            .runtime_id = randomEphemeralHexId(allocator),
            .instance_id = randomEphemeralHexId(allocator),
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
        self.allocator.free(self.runtime_id);
        self.allocator.free(self.instance_id);
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
        if (try self.requestTargetRejection(id_value, parsed.value.object.get("target"))) |response| {
            return response;
        }
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

    /// Validate an explicitly targeted request before any method-specific
    /// params or state are touched. A missing target remains the legacy local
    /// Unix-socket contract; remote transports enforce target presence.
    fn requestTargetRejection(
        self: *Daemon,
        id_value: std.json.Value,
        target_value: ?std.json.Value,
    ) !?[]u8 {
        const value = target_value orelse return null;
        const target = headless.parseRequestTarget(value) catch {
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_RUNTIME_IDENTITY_MISSING,
                "request target is missing or malformed",
            );
        };
        if (!std.mem.eql(u8, target.runtime_id, self.runtime_id) or
            !std.mem.eql(u8, target.instance_id, self.instance_id))
        {
            return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_RUNTIME_IDENTITY_MISMATCH,
                "request target does not match this daemon",
            );
        }
        return null;
    }

    fn handleMethodRequest(self: *Daemon, id_value: std.json.Value, method: []const u8, params: std.json.Value) ![]u8 {
        // Store methods own their drain/capability precedence and unlock
        // lockDaemon for SQLite work; route before the generic mutator drain gate.
        if (isStoreMethod(method)) return try self.handleStoreRequest(id_value, method, params);
        // chat.turn.start owns its drain check under lockDaemon (unlocked serve
        // path); other mutators still gate here under the `.normal` outer lock.
        if (!std.mem.eql(u8, method, "chat.turn.start") and
            !std.mem.eql(u8, method, "chat.turn.steer") and
            !std.mem.eql(u8, method, "chat.followup") and
            !self.accepting_mutations and methodMutatesState(method))
        {
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
        if (std.mem.eql(u8, method, "chat.turn.steer")) return try self.chatTurnSteerResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.followup")) return try self.chatFollowupResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.cancel")) return try self.chatTurnCancelResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.consume")) return try self.chatTurnConsumeResponse(id_value, params);
        if (std.mem.eql(u8, method, "provider.models.list")) return try self.providerModelsListResponse(id_value, params);
        if (std.mem.eql(u8, method, headless.providers_protocol.METHOD_PROVIDERS_STATUS)) return try self.providerStatusResponse(id_value, params);
        if (isFxLifecycleMethod(method)) return try self.fxLifecycleResponse(id_value, method, params);
        if (std.mem.eql(u8, method, store_protocol.METHOD_CONFIG_FAVORITE_MODEL_SET)) return try self.configFavoriteModelSetResponse(id_value, params);
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
        if (std.mem.eql(u8, method, "daemon.prepareShutdown")) return try self.prepareShutdownResponse(id_value, params);
        // Additive headless core methods; existing methods and error codes unchanged.
        if (std.mem.startsWith(u8, method, "core.")) return try self.coreResponse(id_value, method, params);
        return try errorResponseAlloc(self.allocator, id_value, "method_not_found", method);
    }

    fn methodMutatesState(method: []const u8) bool {
        return headless.isMutatingMethod(method);
    }

    fn fxLifecycleResponse(self: *Daemon, id_value: std.json.Value, method: []const u8, params: std.json.Value) ![]u8 {
        if (params != .object) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "FX lifecycle params must be an object");
        }
        if (std.mem.eql(u8, method, FX_PANE_RENAME_METHOD) or
            std.mem.eql(u8, method, FX_AGENT_RENAME_METHOD))
        {
            // Verde owns pane titles. Accept FX's presentation calls without
            // allowing them to rename the terminal pane.
            return try okValueResponse(self.allocator, id_value, .{ .accepted = true });
        }

        const source = jsonString(params.object.get("source") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing FX lifecycle source");
        if (!std.mem.eql(u8, source, FX_LIFECYCLE_SOURCE)) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "unsupported lifecycle reporter");
        }
        const session_id = jsonString(params.object.get("pane_id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing FX lifecycle pane_id");

        const releasing = std.mem.eql(u8, method, FX_CLEAR_AUTHORITY_METHOD);
        if (!releasing) {
            const agent = jsonString(params.object.get("agent") orelse .null) orelse
                return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing FX lifecycle agent");
            if (!std.mem.eql(u8, agent, FX_LIFECYCLE_AGENT)) {
                return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "unsupported lifecycle reporter");
            }
        }

        if (std.mem.eql(u8, method, FX_REPORT_SESSION_METHOD)) {
            const provider_thread_id = jsonString(params.object.get("agent_session_id") orelse .null) orelse
                return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing FX session id");
            lockDaemon(self);
            defer self.mutex.unlock();
            const session = self.find(session_id) orelse
                return try errorResponseAlloc(self.allocator, id_value, "resource_not_found", "session not found");
            const owned = try self.allocator.dupe(u8, provider_thread_id);
            if (session.fx_provider_thread_id) |old| self.allocator.free(old);
            session.fx_provider_thread_id = owned;
            return try okValueResponse(self.allocator, id_value, .{ .accepted = true });
        }

        const state = if (releasing)
            null
        else state: {
            const raw_state = jsonString(params.object.get("state") orelse .null) orelse
                return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing FX lifecycle state");
            break :state std.meta.stringToEnum(FxLifecycleState, raw_state) orelse
                return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "invalid FX lifecycle state");
        };

        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var daemon_locked = true;
        lockDaemon(self);
        defer if (daemon_locked) self.mutex.unlock();

        if (!self.accepting_mutations) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "daemon is preparing shutdown");
        }
        const session = self.find(session_id) orelse
            return try errorResponseAlloc(self.allocator, id_value, "resource_not_found", "session not found");
        const transition = if (state) |reported|
            fxLifecycleTransition(&session.fx_turn_active, reported)
        else
            fxLifecycleRelease(&session.fx_turn_active);
        session.fx_lifecycle_sequence +%= 1;
        const sequence = session.fx_lifecycle_sequence;
        const created_at_ms = session.created_at_ms;
        const child_pid = session.child_pid;
        const workspace_id = try arena.dupe(u8, session.project_id);
        const workspace_path = try arena.dupe(u8, session.project_path);
        const provider_thread_id = if (session.fx_provider_thread_id) |value| try arena.dupe(u8, value) else null;
        const dock_id = session.dock_id;
        const pane_id = session.pane_id;
        const service = self.store_service orelse
            return try errorResponseAlloc(self.allocator, id_value, "capability_unavailable", "store capability is unavailable");
        if (service.draining) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "daemon store is draining");
        }
        _ = service.in_flight.fetchAdd(1, .monotonic);
        self.mutex.unlock();
        daemon_locked = false;
        defer _ = service.in_flight.fetchSub(1, .monotonic);

        const request_key = try std.fmt.allocPrint(arena, "fx-lifecycle:{s}:{d}:{d}:{d}", .{
            session_id,
            created_at_ms,
            child_pid,
            sequence,
        });
        const changed_at_ms = nowMs();
        const write_result = write: {
            lockStoreService(service);
            defer service.mutex.unlock();
            break :write switch (transition) {
                .clear => service.store.clearSurface(.{
                    .mutation = .{ .request_key = request_key, .client_id = "daemon" },
                    .session_id = session_id,
                    .workspace_id = workspace_id,
                }),
                .working, .waiting, .done => service.store.upsertSurface(.{
                    .mutation = .{ .request_key = request_key, .client_id = "daemon" },
                    .surface = .{
                        .session_id = session_id,
                        .workspace_id = workspace_id,
                        .workspace_path = workspace_path,
                        .dock_id = dock_id,
                        .pane_id = pane_id,
                        .provider = FX_LIFECYCLE_AGENT,
                        .provider_thread_id = provider_thread_id,
                        // FX owns a live OSC title derived from its session name
                        // or workspace. Do not replace it with the generic label.
                        .title = "",
                        .status = @tagName(transition),
                        .status_changed_at_ms = changed_at_ms,
                        .completed_at_ms = if (transition == .done) changed_at_ms else 0,
                        .last_event_title = switch (transition) {
                            .working => "FX working",
                            .waiting => "FX needs attention",
                            .done => "FX finished",
                            .clear => unreachable,
                        },
                    },
                }),
            } catch |err| return try storeErrorResponse(self.allocator, id_value, err);
        };
        // Hook-backed providers deliver this presentation update directly to
        // the GUI after their durable write. Do the same for FX so a focused
        // completion cannot be acknowledged before the notifier observes it.
        if (transition != .clear) self.deliverFxLifecycleToLive(.{
            .session_id = session_id,
            .workspace_id = workspace_id,
            .workspace_path = workspace_path,
            .dock_id = dock_id,
            .pane_id = pane_id,
            .provider_thread_id = provider_thread_id,
            .status = @tagName(transition),
            .request_key = request_key,
            .store_revision = write_result.store_revision,
            .changed_at_ms = changed_at_ms,
        });
        return try okValueResponse(self.allocator, id_value, .{
            .accepted = true,
            .store_revision = write_result.store_revision,
        });
    }

    const FxLiveLifecycle = struct {
        session_id: []const u8,
        workspace_id: []const u8,
        workspace_path: []const u8,
        dock_id: u32,
        pane_id: u32,
        provider_thread_id: ?[]const u8,
        status: []const u8,
        request_key: []const u8,
        store_revision: u64,
        changed_at_ms: i64,
    };

    fn deliverFxLifecycleToLive(self: *Daemon, lifecycle: FxLiveLifecycle) void {
        const endpoint = platform_live_endpoint.alloc(self.allocator, self.pref_path) catch return;
        defer self.allocator.free(endpoint);

        var request_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer request_writer.deinit();
        var json: std.json.Stringify = .{ .writer = &request_writer.writer, .options = .{} };
        json.write(.{
            .id = "fx-lifecycle",
            .method = "notification.update",
            .params = .{
                .session_id = lifecycle.session_id,
                .workspace_id = lifecycle.workspace_id,
                .workspace_path = lifecycle.workspace_path,
                .dock_id = lifecycle.dock_id,
                .pane_id = lifecycle.pane_id,
                .provider = FX_LIFECYCLE_AGENT,
                .provider_thread_id = lifecycle.provider_thread_id,
                .status = lifecycle.status,
                .event_title = if (std.mem.eql(u8, lifecycle.status, "working"))
                    "FX working"
                else if (std.mem.eql(u8, lifecycle.status, "waiting"))
                    "FX needs attention"
                else
                    "FX finished",
                .store_request_key = lifecycle.request_key,
                .store_revision = lifecycle.store_revision,
                .store_status_changed_at_ms = lifecycle.changed_at_ms,
                .store_completed_at_ms = if (std.mem.eql(u8, lifecycle.status, "done")) lifecycle.changed_at_ms else 0,
            },
        }) catch return;
        const request = request_writer.toOwnedSlice() catch return;
        defer self.allocator.free(request);
        const response = platform_ipc.requestAlloc(self.allocator, endpoint, request, .{ .timeout_ms = 500 }) catch return;
        self.allocator.free(response);
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
        const is_workspace_list = std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_LIST);
        const is_repository_manifest = std.mem.eql(
            u8,
            method,
            store_protocol.METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET,
        );
        const is_thread_get = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_GET);
        const is_thread_list = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_LIST);
        const is_message_list = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_MESSAGE_LIST);
        const is_turn_record = std.mem.eql(u8, method, store_protocol.METHOD_CHAT_TURN_RECORD);
        const is_chat_read = is_workspace_list or is_repository_manifest or is_thread_get or
            is_thread_list or is_message_list or is_turn_record;
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
        var decoded_workspace_list: ?store_protocol.WorkspaceListRequest = null;
        var decoded_repository_manifest: ?store_protocol.WorkspaceRepositoryManifestRequest = null;
        var decoded_thread_get: ?store_protocol.ThreadGetRequest = null;
        var decoded_thread_list: ?store_protocol.ThreadListRequest = null;
        var decoded_message_list: ?store_protocol.MessageListRequest = null;
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
        } else if (is_workspace_list) {
            if (params == .null) {
                decoded_workspace_list = .{};
            } else {
                const req = std.json.parseFromValueLeaky(
                    store_protocol.WorkspaceListRequest,
                    arena,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch |err| blk: {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    decode_failed = true;
                    break :blk null;
                };
                if (req) |value| decoded_workspace_list = value;
            }
        } else if (is_repository_manifest) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceRepositoryManifestRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_repository_manifest = value;
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
        } else if (is_message_list) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.MessageListRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_message_list = value;
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
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_UPSERT)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceRepositoryUpsertRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .workspace_repository_upsert = .{
                .mutation = value.mutation,
                .workspace_id = value.workspace_id,
                .repository = .{
                    .repository_id = value.repository.repository_id,
                    .label = value.repository.label,
                    .vcs_identity = value.repository.vcs_identity,
                    .default_branch = value.repository.default_branch,
                },
            } };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_REMOVE)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceRepositoryRemoveRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .workspace_repository_remove = .{
                .mutation = value.mutation,
                .workspace_id = value.workspace_id,
                .repository_id = value.repository_id,
            } };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_DEFAULT_SET)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceDefaultRepositorySetRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .workspace_default_repository_set = .{
                .mutation = value.mutation,
                .workspace_id = value.workspace_id,
                .repository_id = value.repository_id,
            } };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_UPSERT)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceRepositoryBindingUpsertRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .workspace_repository_binding_upsert = .{
                .mutation = value.mutation,
                .workspace_id = value.workspace_id,
                .repository_id = value.repository_id,
                .binding = value.binding,
            } };
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_REMOVE)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.WorkspaceRepositoryBindingRemoveRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .workspace_repository_binding_remove = .{
                .mutation = value.mutation,
                .workspace_id = value.workspace_id,
                .repository_id = value.repository_id,
                .runtime_id = value.runtime_id,
            } };
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
        } else if (std.mem.eql(u8, method, store_protocol.METHOD_CHAT_DRAFT_SET)) {
            const req = std.json.parseFromValueLeaky(
                store_protocol.ChatDraftSetRequest,
                arena,
                params,
                .{ .ignore_unknown_fields = true },
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                decode_failed = true;
                break :blk null;
            };
            if (req) |value| decoded_mutation = .{ .chat_draft_set = value };
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
        else if (is_workspace_list)
            decoded_workspace_list == null
        else if (is_repository_manifest)
            decoded_repository_manifest == null
        else if (is_thread_get)
            decoded_thread_get == null
        else if (is_thread_list)
            decoded_thread_list == null
        else if (is_message_list)
            decoded_message_list == null
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
        var store_locked = true;
        defer if (store_locked) service.mutex.unlock();

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

        if (is_workspace_list) {
            const req = decoded_workspace_list orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            const result = loadWorkspaceListResult(self.allocator, &service.store, self.runtime_id, req) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            defer freeWorkspaceListResult(self.allocator, result);
            return try okValueResponse(self.allocator, id_value, result);
        }
        if (is_repository_manifest) {
            const req = decoded_repository_manifest orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            var manifest = service.store.loadWorkspaceRepositoryManifest(req.workspace_id) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            defer manifest.deinit(self.allocator);
            const store_revision = service.store.storeRevision() catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            const result: store_protocol.WorkspaceRepositoryManifestResult = .{
                .workspace_id = manifest.workspace_id,
                .default_repository_id = manifest.default_repository_id,
                .repositories = manifest.repositories,
                .store_revision = store_revision,
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
        if (is_message_list) {
            const req = decoded_message_list orelse return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid params",
            );
            const result = loadMessageListResult(self.allocator, &service.store, req) catch |err| {
                return try storeErrorResponse(self.allocator, id_value, err);
            };
            defer freeMessageListResult(self.allocator, result);
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
        // Hook CLIs persist first and normally follow with a Live request. A
        // focused pane can acknowledge the projected completion in between,
        // consuming the notification edge. Deliver CLI surface commits while
        // their receipt is still current, before replying to the hook process.
        service.mutex.unlock();
        store_locked = false;
        switch (mutation) {
            .surface_upsert => |request| {
                if (std.mem.startsWith(u8, request.mutation.request_key, "cli:notify:")) {
                    self.deliverHookSurfaceToLive(request, write_result);
                }
            },
            else => {},
        }
        return try okValueResponse(self.allocator, id_value, write_result);
    }

    fn deliverHookSurfaceToLive(
        self: *Daemon,
        request: store_protocol.SurfaceUpsertRequest,
        write_result: store_protocol.WriteResult,
    ) void {
        const endpoint = platform_live_endpoint.alloc(self.allocator, self.pref_path) catch return;
        defer self.allocator.free(endpoint);

        const surface = request.surface;
        var request_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer request_writer.deinit();
        var json: std.json.Stringify = .{ .writer = &request_writer.writer, .options = .{} };
        json.write(.{
            .id = "hook-lifecycle",
            .method = "notification.update",
            .params = .{
                .session_id = surface.session_id,
                .workspace_id = surface.workspace_id,
                .workspace_path = surface.workspace_path,
                .dock_id = surface.dock_id,
                .pane_id = surface.pane_id,
                .provider = surface.provider,
                .provider_thread_id = surface.provider_thread_id,
                .title = if (surface.title.len > 0) surface.title else null,
                .status = surface.status,
                .event_title = surface.last_event_title,
                .event_body = surface.last_event_body,
                .store_request_key = request.mutation.request_key,
                .store_revision = write_result.store_revision,
                .store_status_changed_at_ms = surface.status_changed_at_ms,
                .store_completed_at_ms = surface.completed_at_ms,
            },
        }) catch return;
        const payload = request_writer.toOwnedSlice() catch return;
        defer self.allocator.free(payload);
        const response = platform_ipc.requestAlloc(self.allocator, endpoint, payload, .{ .timeout_ms = 500 }) catch return;
        self.allocator.free(response);
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
        var include_workspaces = false;
        var include_registry = false;
        var include_sessions = false;
        var include_turns = false;
        var include_config = false;
        var incomplete: std.ArrayList([]const u8) = .empty;
        if (request.scopes) |names| {
            include_store = false;
            for (names) |name| {
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_STORE)) include_store = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_WORKSPACES)) include_workspaces = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_REGISTRY)) include_registry = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_SESSIONS)) include_sessions = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_TURNS)) include_turns = true;
                if (std.mem.eql(u8, name, store_protocol.SNAPSHOT_SCOPE_CONFIG)) include_config = true;
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
            loaded = loadStoreSnapshotTxn(arena, &service.store, request.workspace_id, include_store, include_workspaces) catch |err| {
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
            if (include_config) {
                try s.objectField("config");
                try writeConfigSnapshot(&s, self);
            }
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
    fn prepareShutdownResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        // Older typed clients encode an anonymous `.{}` parameter value as
        // the empty JSON tuple `[]`. Preserve that no-argument wire shape;
        // only the object form can carry the optional ownership assertion.
        if (params == .array and params.array.items.len != 0) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        }
        if (params != .object and params != .array) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        }
        if (params == .object) {
            if (params.object.get("expected_pid")) |expected_value| {
                const expected_pid = jsonUsize(expected_value) orelse
                    return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "expected_pid must be an integer");
                const actual_pid = platform_runtime.processId();
                if (expected_pid != actual_pid) {
                    // Ownership assertions keep administrative clients from
                    // draining a replacement endpoint after a reconnect/TOCTOU.
                    return try okValueResponse(self.allocator, id_value, .{
                        .accepted = false,
                        .safe_to_exit = false,
                        .owner_mismatch = true,
                        .pid = actual_pid,
                        .shutdown_requested = self.shutdown_requested,
                        .accepting_mutations = self.accepting_mutations,
                    });
                }
            }
        }
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
        const store_ready = self.store_service != null;
        const ctx: headless.Context = .{
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
            .server_version = build_options.version,
            .pid = platform_runtime.processId(),
            .sessionizer_protocol_version = PROTOCOL_VERSION,
            .session_count = self.sessions.items.len,
            .chat_turn_count = self.chat_turns.items.len,
            .store_ready = store_ready,
        };
        // Request id for the typed dispatcher is informational; wire id stays id_value.
        const typed = headless.dispatchMethod(0, method, params, ctx);
        // Authority signal: store=true only after the production writer owns the DB.
        return switch (typed.body) {
            .status => |result| blk: {
                var status = result;
                status.capabilities.store = store_ready;
                status.capabilities.repository_manifests = store_ready;
                status.runtime_capabilities = if (store_ready)
                    &headless.protocol.RUNTIME_CAPABILITY_NAMES
                else
                    &headless.protocol.RUNTIME_CAPABILITY_NAMES_BASE;
                break :blk try okValueResponse(self.allocator, id_value, status);
            },
            .capabilities => |result| blk: {
                var caps = result;
                caps.capabilities.store = store_ready;
                caps.capabilities.repository_manifests = store_ready;
                caps.runtime_capabilities = if (store_ready)
                    &headless.protocol.RUNTIME_CAPABILITY_NAMES
                else
                    &headless.protocol.RUNTIME_CAPABILITY_NAMES_BASE;
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
        if (try self.requestTargetRejection(id_value, parsed.value.object.get("target"))) |response| {
            return response;
        }
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
        self.appendJournalEntryQuiet(topic, resource_id, workspace_id, revision);
        // M5-P3 wake ordering (append → signal, leaf lock released first): a
        // parked core.changes waiter either re-reads the window and sees this
        // entry, or it loaded changes_signal before this bump and its futex
        // wait returns immediately on the changed value — a wake can never be
        // missed, and the waker never holds the lock the woken reader needs.
        self.signalChangesWaiters();
    }

    /// Append without signaling. Multi-entry commit hooks (snapshot replace,
    /// turn acceptance/commit) append every entry of one committed
    /// store_revision, then signal ONCE: a snapshot replace journals one entry
    /// per carried workspace/thread/completion/surface plus five batch
    /// tombstone entries, and signaling each one woke every parked long-poll
    /// waiter N+5 times per commit — each wake re-reading and re-copying the
    /// whole change window. The M5-P3 ordering still holds for the batch: all
    /// appends complete (leaf lock released) before the single bump, so a
    /// waiter either saw the entries in its pre-park window read or its futex
    /// expectation is stale and it wakes.
    fn appendJournalEntryQuiet(
        self: *Daemon,
        topic: change_journal.Topic,
        resource_id: []const u8,
        workspace_id: ?[]const u8,
        revision: change_journal.Revision,
    ) void {
        lockJournal(self);
        defer self.journal_mutex.unlock();
        _ = self.journal.append(self.allocator, topic, resource_id, workspace_id, revision, nowMs()) catch {
            // The entry the client should have seen was dropped; force every
            // existing cursor below the new floor so it snapshot-falls-back.
            self.journal.last_seq += 1;
            self.journal.journal_floor_seq = self.journal.last_seq;
        };
    }

    /// Publish "the journal advanced (or drain began)" to parked long-pollers.
    /// The fetchAdd is unconditional so the signal word always reflects every
    /// append; the futexWake syscall is skipped when nobody is parked.
    fn signalChangesWaiters(self: *Daemon) void {
        _ = self.changes_signal.fetchAdd(1, .release);
        // Shared parked counter: may report a parked waiter of the OTHER
        // kind, costing one no-op futexWake. Never misses a real waiter.
        if (self.long_poll_parked.load(.acquire) == 0) return;
        // The Threaded futex shim is stateless; an ephemeral instance is the
        // sanctioned way to reach futexWake from an arbitrary thread.
        var threaded = std.Io.Threaded.init_single_threaded;
        threaded.io().futexWake(u32, &self.changes_signal.raw, std.math.maxInt(u32));
    }

    /// Begin core.changes drain (sticky): parked waiters wake and answer with
    /// the structured drain response; new positive waits degrade to immediate
    /// heartbeats. Called by prepareShutdown (accepted) and by the transport's
    /// on_draining callback — before transport workers are joined, so a
    /// parked waiter can never stall worker quiesce. Turn-tail waiters share
    /// the drain latch, so they are woken here too.
    fn beginChangesDrain(self: *Daemon) void {
        self.changes_draining.store(true, .release);
        self.signalChangesWaiters();
        self.signalTurnEventWaiters();
    }

    /// Turn-event twin of `signalChangesWaiters` for `chat.turn.tail wait_ms`
    /// long-pollers. Safe to call while holding a turn mutex: it takes no
    /// locks, and a woken waiter re-resolves the turn and re-locks after the
    /// caller releases.
    fn signalTurnEventWaiters(self: *Daemon) void {
        _ = self.turn_events_signal.fetchAdd(1, .release);
        // Shared parked counter (see signalChangesWaiters).
        if (self.long_poll_parked.load(.acquire) == 0) return;
        var threaded = std.Io.Threaded.init_single_threaded;
        threaded.io().futexWake(u32, &self.turn_events_signal.raw, std.math.maxInt(u32));
    }

    /// Turn-event twin of `parkForChanges`. Holds NO locks while parked; the
    /// caller must have loaded `observed_signal` BEFORE reading turn state
    /// (missed-wake guarantee) and must re-resolve the turn by id after every
    /// wake — a consumed turn frees its memory.
    fn parkForTurnEvents(self: *Daemon, observed_signal: u32, deadline_ms: i64) ChangesParkOutcome {
        const prev_parked = self.long_poll_parked.fetchAdd(1, .acquire);
        if (prev_parked >= platform_ipc.MAX_PARKED_LONG_POLL_WAITERS) {
            _ = self.long_poll_parked.fetchSub(1, .release);
            return .over_cap;
        }
        defer _ = self.long_poll_parked.fetchSub(1, .release);

        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        while (true) {
            if (self.changes_draining.load(.acquire)) return .drained;
            if (self.turn_events_signal.load(.acquire) != observed_signal) return .woken;
            const remaining = deadline_ms - nowMs();
            if (remaining <= 0) return .timed_out;
            io.futexWaitTimeout(u32, &self.turn_events_signal.raw, observed_signal, .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(remaining)),
                .clock = .awake,
            } }) catch {};
        }
    }

    const ChangesParkOutcome = enum { woken, timed_out, drained, over_cap };

    /// Park the calling transport worker until the journal advances, the
    /// deadline passes, or drain begins. Holds NO locks while parked (Q7).
    /// `observed_signal` must have been loaded BEFORE the caller's journal
    /// window read — that ordering is the missed-wake guarantee.
    fn parkForChanges(self: *Daemon, observed_signal: u32, deadline_ms: i64) ChangesParkOutcome {
        // Q7 parked-waiter cap: reserve a slot first; over-cap callers degrade
        // to an immediate heartbeat (never an error — pinned in the IT).
        const prev_parked = self.long_poll_parked.fetchAdd(1, .acquire);
        if (prev_parked >= platform_ipc.MAX_PARKED_LONG_POLL_WAITERS) {
            _ = self.long_poll_parked.fetchSub(1, .release);
            return .over_cap;
        }
        defer _ = self.long_poll_parked.fetchSub(1, .release);

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
            // The PTY's current grid. A client whose local grid disagrees is
            // rendering another client's repaint stream (wrapped/garbled TUI)
            // and uses this to detect the drift.
            .cols = session.cols,
            .rows = session.rows,
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

        var execution_route = resolveChatExecutionRoute(self, params) catch |err| switch (err) {
            error.InvalidParams => return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_INVALID_PARAMS,
                "invalid repository route params",
            ),
            error.RouteAttachmentsUnsupported => return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_CAPABILITY_UNAVAILABLE,
                "remote repository routes do not support path-based attachments",
            ),
            error.CapabilityUnavailable => return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_CAPABILITY_UNAVAILABLE,
                "repository checkout is unavailable on this runtime",
            ),
            error.ResourceNotFound => return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_RESOURCE_NOT_FOUND,
                "repository binding not found on this runtime",
            ),
            error.StoreCorrupt => return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_STORE_CORRUPT,
                "store is corrupt",
            ),
            error.StoreUnavailable => return try errorResponseAlloc(
                self.allocator,
                id_value,
                headless.protocol.ERR_STORE_UNAVAILABLE,
                "store is unavailable",
            ),
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer if (execution_route) |*route| route.deinit(self.allocator);
        const route_ptr: ?*const ChatExecutionRoute = if (execution_route) |*route| route else null;
        const turn = try createChatTurnFromParams(self.allocator, params, route_ptr);
        errdefer turn.deinit(self.allocator);
        // Wire the wake path before the turn is reachable by any worker.
        turn.daemon = self;

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

    /// Live tail with optional long-poll: `wait_ms > 0` parks the transport
    /// worker (twin of core.changes, clamped to MAX_CHANGES_WAIT_MS) until
    /// the turn gains events past `after_seq`, publishes a terminal status,
    /// or the budget/drain ends the wait — then answers with the current
    /// tail, never an error. Over-cap parking degrades to an immediate
    /// response. The turn is re-resolved by id after every wake because a
    /// consumed turn frees its memory. Optional `max_bytes` pages event replay;
    /// terminal status and result fields are withheld until the final page.
    fn chatTurnTailResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn_id = jsonString(params.object.get("turn_id") orelse .null) orelse return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id");
        const after_seq = jsonUsize(params.object.get("after_seq") orelse .null) orelse 0;
        const wait_ms = jsonUsize(params.object.get("wait_ms") orelse .null) orelse 0;
        const max_bytes = jsonUsize(params.object.get("max_bytes") orelse .null);
        const effective_wait_ms: u32 = @intCast(@min(wait_ms, MAX_CHANGES_WAIT_MS));
        const wait_deadline_ms: i64 = nowMs() + effective_wait_ms;
        var wait_exhausted = false;

        park_loop: while (true) {
            // Missed-wake protocol: load the signal word BEFORE reading turn
            // state. appendEvent/commit bump it only after their change is
            // visible, so either this read observes the change or the park
            // below sees a stale expectation and returns immediately.
            const observed_signal = self.turn_events_signal.load(.acquire);
            lockDaemon(self);
            if (self.findChatTurn(turn_id)) |turn| {
                lockTurn(turn);
                self.mutex.unlock();
                const deliver = chatTailHasNews(turn, @intCast(after_seq)) or
                    effective_wait_ms == 0 or wait_exhausted or
                    self.changes_draining.load(.acquire);
                if (!deliver) {
                    turn.mutex.unlock();
                    // Park holding NO locks (Q7 twin).
                    switch (self.parkForTurnEvents(observed_signal, wait_deadline_ms)) {
                        .woken => continue :park_loop,
                        // One final consistent read, then answer as-is.
                        .timed_out, .drained, .over_cap => {
                            wait_exhausted = true;
                            continue :park_loop;
                        },
                    }
                }
                defer turn.mutex.unlock();
                const after: u64 = @intCast(after_seq);
                const through_seq = if (max_bytes) |requested|
                    chatTailPageEndSeq(turn, after, @min(requested, MAX_RESPONSE_BYTES))
                else
                    turn.next_seq - 1;
                const has_more_events = chatTailHasEventsAfter(turn, through_seq);
                if (chatTailUpperBound(turn, after, through_seq, !has_more_events) > MAX_RESPONSE_BYTES) return error.ResponseTooLarge;
                var writer: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer writer.deinit();
                var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
                try beginOk(&s, id_value);
                try s.objectField("result");
                try writeChatTurnTail(&s, turn, after, through_seq, has_more_events);
                try s.endObject();
                return try writer.toOwnedSlice();
            }
            // Not in memory: fall through to the durable-record path with
            // lockDaemon still held (matching the pre-wait_ms structure).
            break :park_loop;
        }
        const service = self.store_service;
        if (service) |svc| _ = svc.lifetime_pins.fetchAdd(1, .monotonic);
        self.mutex.unlock();
        const svc = service orelse return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
        defer _ = svc.lifetime_pins.fetchSub(1, .monotonic);

        lockStoreService(svc);
        const record = loadTurnRecord(self.allocator, &svc.store, .{ .turn_id = turn_id }) catch |err| {
            svc.mutex.unlock();
            return switch (err) {
                error.ResourceNotFound => try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found"),
                else => err,
            };
        };
        svc.mutex.unlock();
        defer freeTurnRecord(self.allocator, record);
        if (!durableTurnRecordIsTerminal(record))
            return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
        return try durableChatTurnTailResponse(self.allocator, id_value, record);
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

    /// Inject a Codex/Claude/Pi follow-up into the exact provider process owned by
    /// this daemon. `steer_id` is the idempotency boundary: after provider
    /// acknowledgement, retries return the original sequenced audit event and
    /// never call the provider again.
    fn chatTurnSteerResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const turn_id = jsonString(params.object.get("turn_id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing turn_id");
        const prompt = jsonString(params.object.get("prompt") orelse .null) orelse "";
        const requested_steer_id = jsonString(params.object.get("steer_id") orelse .null);
        const image_paths = try jsonStringArray(self.allocator, params.object.get("image_paths") orelse .null);
        defer freeStringArray(self.allocator, image_paths);
        if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len == 0 and image_paths.len == 0) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "steer prompt is empty");
        }

        lockDaemon(self);
        if (!self.accepting_mutations) {
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "daemon is preparing shutdown and is not accepting mutations");
        }
        const turn = self.findChatTurn(turn_id) orelse {
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "not_found", "turn not found");
        };
        lockTurn(turn);
        const steer_id = requested_steer_id orelse std.fmt.allocPrint(
            self.allocator,
            "daemon-steer-{d}-{d}",
            .{ nowMs(), turn.steers.items.len },
        ) catch |err| {
            turn.mutex.unlock();
            self.mutex.unlock();
            return err;
        };
        defer if (requested_steer_id == null) self.allocator.free(steer_id);
        if (findSteerAudit(turn, steer_id)) |existing| {
            if (!steerAuditMatches(existing, prompt, image_paths)) {
                turn.mutex.unlock();
                self.mutex.unlock();
                return try errorResponseAlloc(self.allocator, id_value, "conflict", "steer_id was already used with different content");
            }
            switch (existing.state) {
                .published => {
                    const response = steerAcceptedResponse(self.allocator, id_value, turn.turn_id, existing, true) catch |err| {
                        turn.mutex.unlock();
                        self.mutex.unlock();
                        return err;
                    };
                    turn.mutex.unlock();
                    self.mutex.unlock();
                    return response;
                },
                .provider_accepted => {
                    const event_seq = publishSteerAudit(self.allocator, turn, existing) catch |err| {
                        turn.mutex.unlock();
                        self.mutex.unlock();
                        return err;
                    };
                    const response = steerAcceptedResponse(self.allocator, id_value, turn.turn_id, existing, true) catch |err| {
                        turn.mutex.unlock();
                        self.mutex.unlock();
                        return err;
                    };
                    std.debug.assert(existing.event_seq == event_seq);
                    turn.mutex.unlock();
                    self.mutex.unlock();
                    return response;
                },
                .in_flight => {
                    turn.mutex.unlock();
                    self.mutex.unlock();
                    return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "steer request is still in progress");
                },
            }
        }
        const steer_provider = turn.request.provider;
        if ((steer_provider != .codex and steer_provider != .claude and steer_provider != .pi) or turn.request.harness_kind != .local_cli) {
            turn.mutex.unlock();
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "provider does not support daemon steering");
        }
        if (turn.status != .running or turn.cancel_requested or turn.pending_approval != null) {
            turn.mutex.unlock();
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "turn cannot accept steering now");
        }
        const provider_thread_id = turn.provider_thread_id orelse turn.request.provider_thread_id orelse if (turn.use_stub)
            "stub-provider-thread"
        else {
            turn.mutex.unlock();
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "provider thread is not ready");
        };
        const owned_provider_thread_id = self.allocator.dupe(u8, provider_thread_id) catch |err| {
            turn.mutex.unlock();
            self.mutex.unlock();
            return err;
        };
        const provider_turn_id = if (steer_provider == .codex)
            turn.active_turn_id orelse {
                self.allocator.free(owned_provider_thread_id);
                turn.mutex.unlock();
                self.mutex.unlock();
                return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "Codex active turn is not ready");
            }
        else
            "";
        const owned_provider_turn_id = self.allocator.dupe(u8, provider_turn_id) catch |err| {
            self.allocator.free(owned_provider_thread_id);
            turn.mutex.unlock();
            self.mutex.unlock();
            return err;
        };
        const owned_project_path = self.allocator.dupe(u8, turn.request.project_path) catch |err| {
            self.allocator.free(owned_provider_turn_id);
            self.allocator.free(owned_provider_thread_id);
            turn.mutex.unlock();
            self.mutex.unlock();
            return err;
        };
        var steer_audit = initSteerAudit(self.allocator, steer_id, prompt, image_paths) catch |err| {
            self.allocator.free(owned_project_path);
            self.allocator.free(owned_provider_turn_id);
            self.allocator.free(owned_provider_thread_id);
            turn.mutex.unlock();
            self.mutex.unlock();
            return err;
        };
        turn.steers.append(self.allocator, steer_audit) catch |err| {
            steer_audit.deinit(self.allocator);
            self.allocator.free(owned_project_path);
            self.allocator.free(owned_provider_turn_id);
            self.allocator.free(owned_provider_thread_id);
            turn.mutex.unlock();
            self.mutex.unlock();
            return err;
        };
        const use_stub = turn.use_stub;
        const provider_invocation_count = turn.provider_invocation_count;
        const steer_invocation_capture = turn.steer_invocation_capture;
        turn.mutex.unlock();
        self.mutex.unlock();
        defer self.allocator.free(owned_provider_thread_id);
        defer self.allocator.free(owned_provider_turn_id);
        defer self.allocator.free(owned_project_path);

        const steer_config: harness.ProviderConfig = switch (steer_provider) {
            .codex => .{ .codex = .{ .cwd = owned_project_path, .launch_on_connect = false } },
            .pi => .{ .pi = .{ .cwd = owned_project_path } },
            else => .{ .claude = .{ .cwd = owned_project_path } },
        };
        const provider_accepted = if (use_stub) blk: {
            if (provider_invocation_count) |count| count.* += 1;
            if (steer_invocation_capture) |capture| capture.record(steer_provider, owned_provider_thread_id, owned_provider_turn_id);
            break :blk std.mem.indexOf(u8, prompt, "reject steer") == null;
        } else blk: {
            var client = harness.connect(self.allocator, steer_config) catch break :blk false;
            defer client.deinit();
            const images = try self.allocator.alloc(harness.types.ImageAttachment, image_paths.len);
            defer self.allocator.free(images);
            for (image_paths, 0..) |path, index| images[index] = .{ .path = path };
            client.steerThread(.{
                .thread_id = owned_provider_thread_id,
                .turn_id = owned_provider_turn_id,
                .prompt = prompt,
                .images = images,
            }) catch break :blk false;
            break :blk true;
        };

        lockTurn(turn);
        const audit_index = findSteerAuditIndex(turn, steer_id) orelse unreachable;
        if (!provider_accepted) {
            var rejected = turn.steers.orderedRemove(audit_index);
            turn.mutex.unlock();
            rejected.deinit(self.allocator);
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "provider could not accept steering for this turn");
        }
        defer turn.mutex.unlock();
        const audit = &turn.steers.items[audit_index];
        audit.state = .provider_accepted;
        _ = try publishSteerAudit(self.allocator, turn, audit);
        return try steerAcceptedResponse(self.allocator, id_value, turn.turn_id, audit, false);
    }

    /// Resolve the running daemon turn by stable thread identity, then reuse
    /// the provider steering path. Detached clients never need GUI pane state.
    fn chatFollowupResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        lockDaemon(self);
        if (!self.accepting_mutations) {
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "daemon is preparing shutdown and is not accepting mutations");
        }
        self.mutex.unlock();

        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const workspace_id = jsonString(params.object.get("workspace_id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing workspace_id");
        const local_thread_id = jsonString(params.object.get("local_thread_id") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing local_thread_id");
        const prompt = jsonString(params.object.get("prompt") orelse .null) orelse "";
        if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len == 0) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "follow-up prompt is empty");
        }

        lockDaemon(self);
        var selected_turn: ?*ChatTurn = null;
        for (self.chat_turns.items) |turn| {
            if (turn.consumed or
                !std.mem.eql(u8, turn.workspace_id, workspace_id) or
                !std.mem.eql(u8, turn.local_thread_id, local_thread_id)) continue;
            lockTurn(turn);
            const active = turn.status == .running or turn.status == .waiting_approval;
            const newer = selected_turn == null or turn.started_at_ms > selected_turn.?.started_at_ms;
            turn.mutex.unlock();
            if (active and newer) selected_turn = turn;
        }
        const turn = selected_turn orelse {
            self.mutex.unlock();
            return try errorResponseAlloc(self.allocator, id_value, "invalid_state", "thread has no running turn");
        };
        const turn_id = self.allocator.dupe(u8, turn.turn_id) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        defer self.allocator.free(turn_id);

        var steer_params: std.json.ObjectMap = .empty;
        defer steer_params.deinit(self.allocator);
        try steer_params.put(self.allocator, "turn_id", .{ .string = turn_id });
        try steer_params.put(self.allocator, "prompt", .{ .string = prompt });
        if (params.object.get("steer_id")) |steer_id| {
            try steer_params.put(self.allocator, "steer_id", steer_id);
        }
        if (params.object.get("image_paths")) |image_paths| {
            try steer_params.put(self.allocator, "image_paths", image_paths);
        }
        return try self.chatTurnSteerResponse(id_value, .{ .object = steer_params });
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

    /// Read-only dynamic model catalog so detached clients (web/CLI) can
    /// mirror the desktop composer pickers. Runs unlocked (see
    /// methodRunsUnlocked): provider discovery may block on the OpenCode
    /// server, cursor-agent CLI, or Claude bridge. Unreachable providers and
    /// Codex (static catalog only) return provider_unavailable; clients fall
    /// back to their static tables.
    fn providerModelsListResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .object) return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object");
        const provider_name = jsonString(params.object.get("provider") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing provider");
        const provider = parseEnum(harness.Provider, provider_name) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "unknown provider");
        const project_path = jsonString(params.object.get("project_path") orelse .null) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "missing project_path");

        const models = send_runner.listModels(self.allocator, provider, project_path) catch |err| {
            return try errorResponseAlloc(self.allocator, id_value, "provider_unavailable", @errorName(err));
        };
        defer harness.freeModelInfos(self.allocator, models);
        return try okValueResponse(self.allocator, id_value, .{
            .provider = provider_name,
            .models = models,
        });
    }

    /// Runtime-scoped provider inventory. This endpoint performs bounded
    /// executable checks only; authentication remains unknown until provider
    /// adapters expose cancellable, deadline-enforced probes. Login/setup runs
    /// explicitly in a runtime PTY under the daemon user's HOME.
    fn providerStatusResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        if (params != .null and params != .object) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "params must be an object or null");
        }
        const ProviderStatus = headless.providers_protocol.ProviderStatus;
        const statuses = [_]ProviderStatus{
            nativeProviderStatus(.codex),
            nativeProviderStatus(.claude),
            nativeProviderStatus(.cursor),
            nativeProviderStatus(.opencode),
            ampProviderStatus(),
            nativeProviderStatus(.pi),
            nativeProviderStatus(.fx),
            nativeProviderStatus(.grok),
        };
        const result: headless.providers_protocol.StatusResult = .{
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
            .probed_at_ms = nowMs(),
            .providers = &statuses,
        };
        return try okValueResponse(self.allocator, id_value, result);
    }

    /// Persist one web composer favorite into the same verde.json collection
    /// used by the desktop model picker. The requested final state makes the
    /// mutation safe to retry and lets rapid web taps serialize cleanly.
    fn configFavoriteModelSetResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        var parsed = parseDaemonParams(store_protocol.ConfigFavoriteModelSetRequest, self.allocator, params) catch {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "invalid favorite model settings");
        };
        defer parsed.deinit();
        const request = parsed.value;
        const provider = app_config.ChatProvider.parse(request.provider) orelse
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "unknown provider");
        const model = std.mem.trim(u8, request.model, " \t\r\n");
        if (model.len == 0 or model.len > 512) {
            return try errorResponseAlloc(self.allocator, id_value, "invalid_params", "invalid model reference");
        }

        self.config_mutex.lock();
        defer self.config_mutex.unlock();
        var config = app_config.loadAppConfig(self.allocator) catch |err| {
            return try errorResponseAlloc(self.allocator, id_value, "config_unavailable", @errorName(err));
        };
        defer config.deinit(self.allocator);
        const current = config.isFavoriteModel(provider, model);
        if (current != request.favorite) {
            _ = config.toggleFavoriteModel(self.allocator, provider, model) catch |err| {
                return try errorResponseAlloc(self.allocator, id_value, "config_unavailable", @errorName(err));
            };
            app_config.saveAppConfig(self.allocator, &config) catch |err| {
                return try errorResponseAlloc(self.allocator, id_value, "config_unavailable", @errorName(err));
            };
        }
        return try okValueResponse(self.allocator, id_value, store_protocol.ConfigFavoriteModelSetResult{
            .provider = @tagName(provider),
            .model = model,
            .favorite = request.favorite,
        });
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
    return runDaemonOptions(allocator, pref_path, .{});
}

pub const DaemonReadyCallback = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) anyerror!void,
};

/// Run the daemon and invoke `callback` only after this process owns the
/// endpoint and all durable services are ready. Lifetime helpers such as
/// signal watchers must start here rather than before the bind race is won.
pub fn runDaemonWithReadyCallback(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    callback: DaemonReadyCallback,
) !void {
    return runDaemonOptions(allocator, pref_path, .{ .ready_callback = callback });
}

/// Initialize and migrate one daemon data directory through the ordinary
/// endpoint-ownership and readiness path, then exit without staying resident.
pub fn initializeDaemonData(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    return runDaemonOptions(allocator, pref_path, .{ .idle_exit_ms_override = 0 });
}

/// Runs the session daemon with the shared MCP dispatcher exposed over the
/// authenticated loopback Streamable HTTP endpoint.
pub fn runDaemonWithMcp(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    mcp_handler: mcp_http.Handler,
) !void {
    return runDaemonOptions(allocator, pref_path, .{ .mcp_handler = mcp_handler });
}

const RunDaemonOptions = struct {
    mcp_handler: ?mcp_http.Handler = null,
    ready_callback: ?DaemonReadyCallback = null,
    idle_exit_ms_override: ?i64 = null,
};

fn runDaemonOptions(allocator: std.mem.Allocator, pref_path: []const u8, options: RunDaemonOptions) !void {
    try process_env.applyAugmentedPathToCurrentProcess(allocator);
    if (builtin.os.tag == .windows) return runWindowsDaemon(allocator, pref_path, options);
    return runUnixDaemon(allocator, pref_path, options);
}

fn runUnixDaemon(allocator: std.mem.Allocator, pref_path: []const u8, options: RunDaemonOptions) !void {
    return runSessionizerServer(allocator, pref_path, options);
}

fn runWindowsDaemon(allocator: std.mem.Allocator, pref_path: []const u8, options: RunDaemonOptions) !void {
    return runSessionizerServer(allocator, pref_path, options);
}

fn runSessionizerServer(allocator: std.mem.Allocator, pref_path: []const u8, options: RunDaemonOptions) !void {
    var setup_threaded = std.Io.Threaded.init_single_threaded;
    try ensurePrivateDataDirectory(setup_threaded.io(), pref_path);
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    const pid_path = try pidFilePath(allocator, pref_path);
    defer allocator.free(pid_path);

    var daemon = Daemon.initWithPrefPath(allocator, pref_path);
    defer daemon.deinit();
    if (options.idle_exit_ms_override) |idle_exit_ms| daemon.idle_exit_ms = idle_exit_ms;
    // M5-P2 journal hook: volatile revision bumps publish identity entries.
    // `&daemon` is stable for the daemon's whole lifetime (A3: production
    // default, not hermetic-gated; capability flags stay false regardless).
    daemon.registry.revision_hook = .{ .context = &daemon, .notify = registryRevisionHookNotify };
    var stop_requested = std.atomic.Value(bool).init(false);
    var server_context: SessionizerServerContext = .{
        .daemon = &daemon,
        .endpoint = endpoint,
        .pid_path = pid_path,
        .pref_path = pref_path,
        .stop_requested = &stop_requested,
        .mcp_handler = options.mcp_handler,
        .ready_callback = options.ready_callback,
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

fn ensurePrivateDataDirectory(io: std.Io, pref_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, pref_path);
    if (builtin.os.tag == .windows) return;

    var data_dir = try std.Io.Dir.cwd().openDir(io, pref_path, .{ .iterate = true });
    defer data_dir.close(io);
    // Runtime identity, SQLite state, provider metadata, socket, and lock file
    // all live below this directory. Tighten an existing directory too so a
    // permissive umask cannot leave daemon state readable by another user.
    try data_dir.setPermissions(io, @enumFromInt(0o700));
}

const SessionizerServerContext = struct {
    daemon: *Daemon,
    endpoint: []const u8,
    pid_path: []const u8,
    pref_path: []const u8 = "",
    stop_requested: *std.atomic.Value(bool),
    mcp_handler: ?mcp_http.Handler = null,
    ready_callback: ?DaemonReadyCallback = null,
    mcp_server: ?mcp_http.Server = null,
    drain_thread: ?std.Thread = null,
    pid_published: bool = false,
};

fn sessionizerServerReady(raw_context: *anyopaque) !void {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    try writePidFile(context.pid_path);
    context.pid_published = true;
    // Open the production (or hermetic-override) store only after bind succeeds
    // so identity creation and SQLite binding share endpoint ownership and a
    // failed cross-check fails readiness loudly (never a silent dual-writer).
    try maybeInitStoreService(context.daemon);
    if (context.mcp_handler) |handler| {
        context.mcp_server = mcp_http.start(context.daemon.allocator, context.pref_path, handler) catch |err| {
            log.err("daemon MCP HTTP transport failed to start: {s}", .{@errorName(err)});
            return err;
        };
    }
    context.drain_thread = try std.Thread.spawn(.{}, drainSessionsThread, .{DrainThreadContext{
        .daemon = context.daemon,
        .endpoint = context.endpoint,
        .stop_requested = context.stop_requested,
    }});
    if (context.ready_callback) |callback| try callback.notify(callback.context);
}

/// Invoked by platform_ipc.serve after the accept loop exits, BEFORE the
/// transport worker pool is joined (M5-P3). A `core.changes` long-poll parked
/// on a worker thread holds that worker; waking it here (with the structured
/// drain response) is what makes the subsequent worker join bounded.
fn sessionizerServerDraining(raw_context: *anyopaque) void {
    const context: *SessionizerServerContext = @ptrCast(@alignCast(raw_context));
    stopMcpHttpServer(context);
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
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_REMOVE) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_DEFAULT_SET) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_REMOVE) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_DRAFT_SET) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_MESSAGE_APPEND) or
        std.mem.eql(u8, method, store_protocol.METHOD_SURFACE_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_SURFACE_CLEAR) or
        std.mem.eql(u8, method, store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT) or
        std.mem.eql(u8, method, store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR) or
        std.mem.eql(u8, method, store_protocol.METHOD_DAEMON_STORE_STATUS) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_LIST) or
        std.mem.eql(u8, method, store_protocol.METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_GET) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_THREAD_LIST) or
        std.mem.eql(u8, method, store_protocol.METHOD_CHAT_MESSAGE_LIST) or
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
            // Appends are quiet with ONE signal at the end of the arm (see
            // appendJournalEntryQuiet for the wake-ordering argument).
            for (request.snapshot.workspaces) |workspace| {
                daemon.appendJournalEntryQuiet(.workspace, workspace.workspace_id, workspace.workspace_id, revision);
                for (workspace.threads) |thread| {
                    daemon.appendJournalEntryQuiet(.chat_thread, thread.local_thread_id, workspace.workspace_id, revision);
                }
            }
            for (request.snapshot.chat_completions) |completion| {
                daemon.appendJournalEntryQuiet(.chat_completion, completion.local_thread_id, completion.workspace_id, revision);
            }
            // M5-P4 Amendment 3 (M5-P3 verify MAJOR): carried surfaces must
            // journal like every other carried resource, matching the
            // surface_upsert arm below.
            for (request.snapshot.surface_states) |surface| {
                daemon.appendJournalEntryQuiet(
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
            daemon.appendJournalEntryQuiet(.workspace, "*", null, revision);
            daemon.appendJournalEntryQuiet(.chat_thread, "*", null, revision);
            // Snapshot tombstoning may remove workspace-owned turn records;
            // the durable replay guard is separate, but chat.turn projection
            // subscribers must still re-read after the committed deletion.
            daemon.appendJournalEntryQuiet(.chat_turn, "*", null, revision);
            daemon.appendJournalEntryQuiet(.chat_completion, "*", null, revision);
            daemon.appendJournalEntryQuiet(.surface, "*", null, revision);
            daemon.signalChangesWaiters();
        },
        .workspace_upsert => |request| daemon.appendJournalEntry(.workspace, request.workspace.workspace_id, request.workspace.workspace_id, revision),
        .workspace_repository_upsert => |request| daemon.appendJournalEntry(.workspace, request.workspace_id, request.workspace_id, revision),
        .workspace_repository_remove => |request| daemon.appendJournalEntry(.workspace, request.workspace_id, request.workspace_id, revision),
        .workspace_default_repository_set => |request| daemon.appendJournalEntry(.workspace, request.workspace_id, request.workspace_id, revision),
        .workspace_repository_binding_upsert => |request| daemon.appendJournalEntry(.workspace, request.workspace_id, request.workspace_id, revision),
        .workspace_repository_binding_remove => |request| daemon.appendJournalEntry(.workspace, request.workspace_id, request.workspace_id, revision),
        .thread_upsert => |request| daemon.appendJournalEntry(.chat_thread, request.thread.local_thread_id, request.workspace_id, revision),
        .chat_draft_set => |request| daemon.appendJournalEntry(.chat_thread, request.local_thread_id, request.workspace_id, revision),
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
fn storeTurnCommittedHook(
    context: *anyopaque,
    request: *const daemon_store.TurnCommitRequest,
    inserted: daemon_store.TurnOwnerInsertions,
    result: store_protocol.WriteResult,
) void {
    const daemon: *Daemon = @ptrCast(@alignCast(context));
    const revision: change_journal.Revision = .{ .store = result.store_revision };
    // One committed revision → quiet appends + one signal (appendJournalEntryQuiet).
    if (inserted.workspace) daemon.appendJournalEntryQuiet(.workspace, request.workspace_id, request.workspace_id, revision);
    daemon.appendJournalEntryQuiet(.chat_thread, request.local_thread_id, request.workspace_id, revision);
    daemon.appendJournalEntryQuiet(.chat_turn, request.turn_id, request.workspace_id, revision);
    // commitTurn writes a completion ledger row whenever the turn completed
    // (deriving one if the request omitted it); mirror that exactly.
    if (request.status == .completed) {
        daemon.appendJournalEntryQuiet(.chat_completion, request.local_thread_id, request.workspace_id, revision);
    }
    daemon.signalChangesWaiters();
}

/// Acceptance journals the inserted workspace owner (when any), the accepted
/// message's thread identity, and the running turn at one shared revision.
fn storeAcceptanceCommittedHook(
    context: *anyopaque,
    request: *const daemon_store.TurnAcceptanceRequest,
    inserted: daemon_store.TurnOwnerInsertions,
    result: store_protocol.WriteResult,
) void {
    const daemon: *Daemon = @ptrCast(@alignCast(context));
    const workspace_id = request.workspace.workspace_id;
    const revision: change_journal.Revision = .{ .store = result.store_revision };
    // One committed revision → quiet appends + one signal (appendJournalEntryQuiet).
    if (inserted.workspace) daemon.appendJournalEntryQuiet(.workspace, workspace_id, workspace_id, revision);
    daemon.appendJournalEntryQuiet(.chat_thread, request.thread.local_thread_id, workspace_id, revision);
    daemon.appendJournalEntryQuiet(.chat_turn, request.turn_id, workspace_id, revision);
    daemon.signalChangesWaiters();
}

fn mutationHeader(mutation: daemon_store.Mutation) store_protocol.MutationHeader {
    return switch (mutation) {
        .snapshot_replace => |request| request.mutation,
        .workspace_upsert => |request| request.mutation,
        .workspace_repository_upsert => |request| request.mutation,
        .workspace_repository_remove => |request| request.mutation,
        .workspace_default_repository_set => |request| request.mutation,
        .workspace_repository_binding_upsert => |request| request.mutation,
        .workspace_repository_binding_remove => |request| request.mutation,
        .thread_upsert => |request| request.mutation,
        .chat_draft_set => |request| request.mutation,
        .message_append => |request| request.mutation,
        .surface_upsert => |request| request.mutation,
        .surface_clear => |request| request.mutation,
        .chat_completion_upsert => |request| request.mutation,
        .chat_completion_clear => |request| request.mutation,
    };
}

pub const EffectiveStoreDirectory = struct {
    path: []u8,
    overridden: bool,
};

/// Resolve the daemon and desktop projection store directory from an injected
/// raw environment value. The returned path is always owned by the caller.
pub fn effectiveStoreDirectoryFromRaw(allocator: std.mem.Allocator, pref_path: []const u8, raw_override: ?[]const u8) !EffectiveStoreDirectory {
    const raw = raw_override orelse return .{
        .path = try allocator.dupe(u8, pref_path),
        .overridden = false,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{
        .path = try allocator.dupe(u8, pref_path),
        .overridden = false,
    };
    return .{
        .path = try allocator.dupe(u8, trimmed),
        .overridden = true,
    };
}

/// Resolve the effective store directory from the process environment.
/// Missing, empty, or invalid-WTF8 overrides retain the production pref path.
pub fn effectiveStoreDirectory(allocator: std.mem.Allocator, pref_path: []const u8) !EffectiveStoreDirectory {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, SESSION_DAEMON_STORE_DIR_ENV_NAME) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return effectiveStoreDirectoryFromRaw(allocator, pref_path, null),
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return effectiveStoreDirectoryFromRaw(allocator, pref_path, null),
    };
    defer allocator.free(raw);
    return effectiveStoreDirectoryFromRaw(allocator, pref_path, raw);
}

test "effective store directory preserves override parsing semantics" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { raw: ?[]const u8, expected: []const u8, overridden: bool }{
        .{ .raw = null, .expected = "/pref", .overridden = false },
        .{ .raw = "", .expected = "/pref", .overridden = false },
        .{ .raw = " \t\r\n", .expected = "/pref", .overridden = false },
        .{ .raw = " /override \n", .expected = "/override", .overridden = true },
        .{ .raw = "relative/store", .expected = "relative/store", .overridden = true },
    };
    for (cases) |case| {
        const result = try effectiveStoreDirectoryFromRaw(allocator, "/pref", case.raw);
        defer allocator.free(result.path);
        try std.testing.expectEqualStrings(case.expected, result.path);
        try std.testing.expectEqual(case.overridden, result.overridden);
    }
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
    // NIT-1: never silently store-less. Empty pref_path is unreachable in
    // production (__session-daemon always passes a real path).
    if (daemon.pref_path.len == 0) {
        log.err("production store open requires non-empty pref_path", .{});
        return error.InvalidParams;
    }
    // Resolve identity and SQLite from the same effective directory. This is
    // essential for hermetic overrides: a test database must never bind to or
    // rotate the production preference-directory identity.
    const effective_dir = try effectiveStoreDirectory(daemon.allocator, daemon.pref_path);
    defer daemon.allocator.free(effective_dir.path);
    var threaded: std.Io.Threaded = .init(daemon.allocator, .{});
    defer threaded.deinit();

    // NIT-2: a stray VERDE_SESSION_DAEMON_STORE_DISABLE in a user session is
    // production-latent (GUI read-only, notify hard-fails). Loud warn so the
    // knob is deliberate at runtime, not only in comments. This explicit
    // test-only mode has a secure file identity but no SQLite authority; the
    // normal production path below always cross-checks both durable copies.
    if (try storeDisabledFromEnv(daemon.allocator)) {
        var identity = try daemon_runtime_identity.loadOrCreateFileOnly(
            daemon.allocator,
            threaded.io(),
            effective_dir.path,
        );
        replaceDaemonRuntimeIdentity(daemon, identity);
        identity = undefined;
        log.warn(
            "store disabled by env — identity is file-only; GUI read-only, notify will fail",
            .{},
        );
        return;
    }

    // B9: fault env is active only alongside the hermetic store-dir override.
    const fault = if (effective_dir.overridden) try storeFaultFromEnv(daemon.allocator) else daemon_store.StoreFault.none;
    const db_path = try std.fs.path.join(daemon.allocator, &.{ effective_dir.path, daemon_runtime_identity.DATABASE_FILE_NAME });
    defer daemon.allocator.free(db_path);

    const service = try daemon.allocator.create(StoreService);
    errdefer daemon.allocator.destroy(service);
    var initialized = try daemon_runtime_identity.initStore(
        daemon.allocator,
        threaded.io(),
        effective_dir.path,
        db_path,
        fault,
    );
    defer initialized.deinit(daemon.allocator);
    service.* = .{
        .store = initialized.takeStore(),
    };
    errdefer service.store.deinit();
    const identity = initialized.takeIdentity();
    replaceDaemonRuntimeIdentity(daemon, identity);
    // M5-P2 journal hook: every durable commit (mutations AND turn commits)
    // publishes identity entries post-commit. Installed before the service is
    // published so no committed write can slip past the journal.
    service.store.commit_hook = .{
        .context = daemon,
        .on_mutation_committed = storeMutationCommittedHook,
        .on_turn_committed = storeTurnCommittedHook,
        .on_acceptance_committed = storeAcceptanceCommittedHook,
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

fn replaceDaemonRuntimeIdentity(daemon: *Daemon, identity: daemon_runtime_identity.OwnedIdentity) void {
    daemon.allocator.free(daemon.runtime_id);
    daemon.allocator.free(daemon.instance_id);
    daemon.runtime_id = identity.runtime_id;
    daemon.instance_id = identity.instance_id;
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
fn stageAcceptedChatTurn(daemon: *Daemon, turn: *ChatTurn) !AcceptanceOwnership {
    // MINOR-5(a): bump in_flight under lockDaemon (match dispatch spine) so
    // finalize cannot destroy the service while this pointer is live.
    lockDaemon(daemon);
    const service = daemon.store_service;
    if (service) |svc| _ = svc.in_flight.fetchAdd(1, .monotonic);
    daemon.mutex.unlock();
    const svc = service orelse return .owned;
    defer _ = svc.in_flight.fetchSub(1, .monotonic);

    var arena_state: std.heap.ArenaAllocator = .init(daemon.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const turn_id = try arena.dupe(u8, turn.turn_id);
    const workspace_id = try arena.dupe(u8, turn.workspace_id);
    const local_thread_id = try arena.dupe(u8, turn.local_thread_id);
    const project_path = try arena.dupe(u8, turn.request.project_path);
    const repository_id = if (turn.repository_id) |value| try arena.dupe(u8, value) else null;
    const repository_cwd = if (turn.repository_cwd) |value| try arena.dupe(u8, value) else null;
    const runtime_id = if (repository_id != null) try arena.dupe(u8, daemon.runtime_id) else null;
    const provider = try arena.dupe(u8, @tagName(turn.request.provider));
    const harness_kind = @tagName(turn.request.harness_kind);
    const provider_thread_id = if (turn.request.provider_thread_id) |id| try arena.dupe(u8, id) else null;
    const thread_title = try arena.dupe(u8, turn.request.thread_title);
    const prompt = try arena.dupe(u8, turn.request.prompt);
    const user_message_id = if (turn.user_message_id) |id|
        try arena.dupe(u8, id)
    else
        try std.fmt.allocPrint(arena, "turn:{s}:user", .{turn_id});
    const started_at_ms = turn.started_at_ms;

    lockStoreService(svc);
    defer svc.mutex.unlock();

    const acceptance_key = try std.fmt.allocPrint(arena, "turn:{s}:accept", .{turn_id});
    // Durable user-row attachments: full client metadata when the turn
    // carried the additive `images` param, otherwise the bare request paths.
    // Path is the minimum contract — mime/byte_size are stored only when the
    // client genuinely supplied them, never invented here.
    var staged_images: []store_protocol.Attachment = &.{};
    if (turn.owned_images.len != 0) {
        const images = try arena.alloc(store_protocol.Attachment, turn.owned_images.len);
        for (turn.owned_images, 0..) |attachment, index| {
            images[index] = .{
                .path = try arena.dupe(u8, attachment.path),
                .mime = try arena.dupe(u8, attachment.mime),
                .byte_size = attachment.byte_size,
            };
        }
        staged_images = images;
    } else if (turn.request.image_paths.len != 0) {
        const images = try arena.alloc(store_protocol.Attachment, turn.request.image_paths.len);
        for (turn.request.image_paths, 0..) |path, index| {
            images[index] = .{ .path = try arena.dupe(u8, path), .mime = "" };
        }
        staged_images = images;
    }
    const user_message: store_protocol.Message = turn.acceptance_message_override orelse .{
        .message_id = user_message_id,
        .role = "user",
        .author = "You",
        .body = prompt,
        .image = if (staged_images.len != 0) staged_images[0] else null,
        .images = staged_images,
        .created_at_ms = started_at_ms,
        .updated_at_ms = started_at_ms,
    };
    _ = svc.store.acceptTurn(.{
        .mutation = .{ .request_key = acceptance_key, .client_id = "daemon" },
        .turn_id = turn_id,
        .workspace = .{
            .workspace_id = workspace_id,
            .label = workspace_id,
            .path = project_path,
        },
        .thread = .{
            .local_thread_id = local_thread_id,
            .title = if (thread_title.len != 0) thread_title else local_thread_id,
            .provider = provider,
            .harness = harness_kind,
            .provider_thread_id = provider_thread_id,
            .model_ref = turn.request.model_ref,
            .reasoning_effort = if (turn.request.reasoning_effort) |effort| @tagName(effort) else null,
            .reasoning_variant = turn.request.opencode_reasoning_variant,
            .fast_mode = @tagName(turn.request.fast_mode),
            .access_mode = @tagName(turn.request.access_mode),
            .profile_id = if (repository_id != null) "local" else null,
            .runtime_id = runtime_id,
            .repository_id = repository_id,
            .repository_cwd = repository_cwd,
        },
        .started_at_ms = started_at_ms,
        .provider = provider,
        .harness = harness_kind,
        .provider_thread_id = provider_thread_id,
        .user_message = user_message,
    }) catch |err| switch (err) {
        error.Conflict => return .conflict_not_owned,
        else => return err,
    };

    // Mirror the staged id back onto the in-memory turn when it was generated.
    if (turn.user_message_id == null) {
        lockTurn(turn);
        defer turn.mutex.unlock();
        if (turn.user_message_id == null) {
            turn.user_message_id = daemon.allocator.dupe(u8, user_message_id) catch null;
        }
    }
    return .owned;
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
    const effective_dir = effectiveStoreDirectory(allocator, "") catch return false;
    defer allocator.free(effective_dir.path);
    if (!effective_dir.overridden) return false;

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
    const repository_id = if (turn.repository_id) |value| try arena.dupe(u8, value) else null;
    const repository_cwd = if (turn.repository_cwd) |value| try arena.dupe(u8, value) else null;
    const runtime_id = if (repository_id != null) try arena.dupe(u8, daemon.runtime_id) else null;
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
    const generated_title = if (turn.generated_title) |title| try arena.dupe(u8, title) else null;
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
        // The pending flip publishes the terminal status; wake tail waiters.
        daemon.signalTurnEventWaiters();
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
        .harness = harness_kind,
        .provider_thread_id = provider_thread_id,
        .workspace = .{
            .workspace_id = workspace_id,
            .label = workspace_id,
            .path = project_path,
        },
        .thread = .{
            .local_thread_id = local_thread_id,
            .title = if (thread_title.len != 0) thread_title else local_thread_id,
            .provider = provider,
            .harness = harness_kind,
            .provider_thread_id = provider_thread_id,
            .model_ref = turn.request.model_ref,
            .reasoning_effort = if (turn.request.reasoning_effort) |effort| @tagName(effort) else null,
            .reasoning_variant = turn.request.opencode_reasoning_variant,
            .fast_mode = @tagName(turn.request.fast_mode),
            .access_mode = @tagName(turn.request.access_mode),
            .profile_id = if (repository_id != null) "local" else null,
            .runtime_id = runtime_id,
            .repository_id = repository_id,
            .repository_cwd = repository_cwd,
        },
        .expected_thread_title = if (generated_title != null) thread_title else null,
        .generated_title = generated_title,
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
    const generated_title_applied = if (generated_title) |title|
        try service.store.threadTitleEquals(workspace_id, local_thread_id, title)
    else
        false;

    // 4. Publish revision on the turn after the receipt. The store service
    // mutex is still held here (defer releases at fn exit); store→turn nesting
    // is globally consistent (NIT-1).
    lockTurn(turn);
    turn.committed_store_revision = write_result.store_revision;
    turn.generated_title_applied = generated_title_applied;
    turn.durability_pending = false;
    turn.mutex.unlock();
    // Durable-first publication flip: the tail status just became terminal
    // without a new event append, so wake parked wait_ms tail waiters here.
    daemon.signalTurnEventWaiters();
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
        \\       t.provider_thread_id, t.model_ref, t.reasoning_effort, t.reasoning_variant,
        \\       t.fast_mode, t.access_mode, t.provider, t.harness, t.id, t.draft, t.cwd,
        \\       t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd
        \\from threads t
        \\join workspaces w on w.id = t.workspace_id
        \\where w.workspace_id = ?1 and t.local_thread_id = ?2
    ,
        .{ request.workspace_id, request.local_thread_id },
    ) catch return error.StoreUnavailable;
    const meta = meta_or_null orelse return error.ResourceNotFound;
    defer meta.deinit();

    const thread_row_id = meta.int(13);
    const local_thread_id = allocator.dupe(u8, meta.text(0)) catch return error.OutOfMemory;
    errdefer allocator.free(local_thread_id);
    const title = allocator.dupe(u8, meta.text(1)) catch return error.OutOfMemory;
    errdefer allocator.free(title);
    const provider_thread_id = dupeOptionalText(allocator, meta.nullableText(5)) catch return error.OutOfMemory;
    errdefer if (provider_thread_id) |value| allocator.free(value);
    const model_ref = dupeOptionalText(allocator, meta.nullableText(6)) catch return error.OutOfMemory;
    errdefer if (model_ref) |value| allocator.free(value);
    const reasoning_variant = dupeOptionalText(allocator, meta.nullableText(8)) catch return error.OutOfMemory;
    errdefer if (reasoning_variant) |value| allocator.free(value);
    const provider = allocator.dupe(u8, providerNameFromCode(meta.int(11))) catch return error.OutOfMemory;
    errdefer allocator.free(provider);
    const harness_name = allocator.dupe(u8, harnessNameFromCode(meta.int(12))) catch return error.OutOfMemory;
    errdefer allocator.free(harness_name);
    const draft = allocator.dupe(u8, meta.text(14)) catch return error.OutOfMemory;
    errdefer allocator.free(draft);
    const cwd = dupeOptionalText(allocator, meta.nullableText(15)) catch return error.OutOfMemory;
    errdefer if (cwd) |value| allocator.free(value);
    const profile_id = dupeOptionalText(allocator, meta.nullableText(16)) catch return error.OutOfMemory;
    errdefer if (profile_id) |value| allocator.free(value);
    const runtime_id = dupeOptionalText(allocator, meta.nullableText(17)) catch return error.OutOfMemory;
    errdefer if (runtime_id) |value| allocator.free(value);
    const repository_id = dupeOptionalText(allocator, meta.nullableText(18)) catch return error.OutOfMemory;
    errdefer if (repository_id) |value| allocator.free(value);
    const repository_cwd = dupeOptionalText(allocator, meta.nullableText(19)) catch return error.OutOfMemory;
    errdefer if (repository_cwd) |value| allocator.free(value);
    const archived = meta.int(2) != 0;
    const committed = meta.int(3) != 0;
    const last_activity_at = meta.nullableInt(4);

    var messages_list: std.ArrayListUnmanaged(store_protocol.Message) = .empty;
    errdefer {
        for (messages_list.items) |message| freeOwnedMessage(allocator, message);
        messages_list.deinit(allocator);
    }
    var rows = store.conn.rows(
        \\select sort_index, message_id, role, author, body, image_path, image_mime,
        \\       image_byte_size, extra_images_json, created_at_ms, updated_at_ms,
        \\       tool_call_id, tool_call_kind, tool_call_status
        \\from messages where thread_id = ?1 order by sort_index
    ,
        .{thread_row_id},
    ) catch return error.StoreUnavailable;
    defer rows.deinit();
    while (rows.next()) |row| {
        const message = try decodeOwnedMessage(allocator, row);
        errdefer freeOwnedMessage(allocator, message);
        messages_list.append(allocator, message) catch return error.OutOfMemory;
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
            .reasoning_effort = if (meta.nullableInt(7)) |code| reasoningEffortNameFromCode(code) else null,
            .reasoning_variant = reasoning_variant,
            .fast_mode = if (meta.nullableInt(9)) |code| fastModeNameFromCode(code) else null,
            .access_mode = if (meta.nullableInt(10)) |code| accessModeNameFromCode(code) else null,
            .provider = provider,
            .harness = harness_name,
            .draft = draft,
            .cwd = cwd,
            .profile_id = profile_id,
            .runtime_id = runtime_id,
            .repository_id = repository_id,
            .repository_cwd = repository_cwd,
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
    if (result.thread.reasoning_variant) |value| allocator.free(value);
    allocator.free(result.thread.provider);
    allocator.free(result.thread.harness);
    allocator.free(result.thread.draft);
    if (result.thread.cwd) |value| allocator.free(value);
    if (result.thread.profile_id) |value| allocator.free(value);
    if (result.thread.runtime_id) |value| allocator.free(value);
    if (result.thread.repository_id) |value| allocator.free(value);
    if (result.thread.repository_cwd) |value| allocator.free(value);
    for (result.thread.messages) |message| freeOwnedMessage(allocator, message);
    allocator.free(result.thread.messages);
}

fn freeOwnedMessage(allocator: std.mem.Allocator, message: store_protocol.Message) void {
    if (message.message_id.len != 0) allocator.free(message.message_id);
    allocator.free(message.role);
    allocator.free(message.author);
    allocator.free(message.body);
    if (message.images.len > 0) {
        freeAttachmentArray(allocator, message.images);
    } else if (message.image) |image| {
        allocator.free(image.path);
        allocator.free(image.mime);
    }
    if (message.tool_call_id) |value| allocator.free(value);
    if (message.tool_call_kind) |value| allocator.free(value);
    if (message.tool_call_status) |value| allocator.free(value);
}

/// Decode one owned message from the shared transcript-column projection.
fn decodeOwnedMessage(
    allocator: std.mem.Allocator,
    row: zqlite.Row,
) daemon_store.StoreError!store_protocol.Message {
    const message_id = allocator.dupe(u8, row.nullableText(1) orelse "") catch return error.OutOfMemory;
    errdefer allocator.free(message_id);
    const author_raw = row.text(3);
    const role = allocator.dupe(u8, roleNameFromCode(row.int(2), author_raw)) catch return error.OutOfMemory;
    errdefer allocator.free(role);
    const author = allocator.dupe(u8, author_raw) catch return error.OutOfMemory;
    errdefer allocator.free(author);
    const body = allocator.dupe(u8, row.text(4)) catch return error.OutOfMemory;
    errdefer allocator.free(body);
    const images = try decodeOwnedAttachmentList(
        allocator,
        row.nullableText(5),
        row.nullableText(6),
        row.nullableInt(7),
        row.nullableText(8),
    );
    errdefer freeAttachmentArray(allocator, images);
    const tool_call_id = dupeOptionalText(allocator, row.nullableText(11)) catch return error.OutOfMemory;
    errdefer if (tool_call_id) |value| allocator.free(value);
    const tool_call_kind = if (row.nullableInt(12)) |code|
        (allocator.dupe(u8, toolCallKindNameFromCode(code)) catch return error.OutOfMemory)
    else
        null;
    errdefer if (tool_call_kind) |value| allocator.free(value);
    const tool_call_status = if (row.nullableInt(13)) |code|
        (allocator.dupe(u8, toolCallStatusNameFromCode(code)) catch return error.OutOfMemory)
    else
        null;
    errdefer if (tool_call_status) |value| allocator.free(value);
    return .{
        .sort_index = std.math.cast(usize, row.int(0)) orelse return error.StoreCorrupt,
        .message_id = message_id,
        .role = role,
        .author = author,
        .body = body,
        .images = images,
        .image = if (images.len > 0) images[0] else null,
        .created_at_ms = row.nullableInt(9),
        .updated_at_ms = row.nullableInt(10),
        .tool_call_id = tool_call_id,
        .tool_call_kind = tool_call_kind,
        .tool_call_status = tool_call_status,
    };
}

/// Decode one owned chat.thread.get attachment list. Unlike snapshot reads,
/// this result outlives the SQLite row and must be individually freed.
fn decodeOwnedAttachmentList(
    allocator: std.mem.Allocator,
    primary_path: ?[]const u8,
    primary_mime: ?[]const u8,
    primary_byte_size: ?i64,
    encoded_extras: ?[]const u8,
) daemon_store.StoreError![]const store_protocol.Attachment {
    const path = primary_path orelse return &.{};
    var attachments: std.ArrayList(store_protocol.Attachment) = .empty;
    errdefer {
        for (attachments.items) |attachment| {
            allocator.free(attachment.path);
            allocator.free(attachment.mime);
        }
        attachments.deinit(allocator);
    }

    const owned_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
    const owned_mime = allocator.dupe(u8, primary_mime orelse "") catch {
        allocator.free(owned_path);
        return error.OutOfMemory;
    };
    attachments.append(allocator, .{
        .path = owned_path,
        .mime = owned_mime,
        .byte_size = if (primary_byte_size) |value| (std.math.cast(usize, value) orelse 0) else 0,
    }) catch {
        allocator.free(owned_path);
        allocator.free(owned_mime);
        return error.OutOfMemory;
    };

    if (encoded_extras) |encoded| {
        var parsed = std.json.parseFromSlice(
            []daemon_store.StoredExtraImage,
            allocator,
            encoded,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.warn("malformed stored extra-images column dropped err={s}", .{@errorName(err)});
            return attachments.toOwnedSlice(allocator) catch return error.OutOfMemory;
        };
        defer parsed.deinit();
        for (parsed.value) |extra| {
            const extra_path = allocator.dupe(u8, extra.path) catch return error.OutOfMemory;
            const extra_mime = allocator.dupe(u8, extra.mime) catch {
                allocator.free(extra_path);
                return error.OutOfMemory;
            };
            attachments.append(allocator, .{
                .path = extra_path,
                .mime = extra_mime,
                .byte_size = std.math.cast(usize, extra.byte_size) orelse 0,
            }) catch {
                allocator.free(extra_path);
                allocator.free(extra_mime);
                return error.OutOfMemory;
            };
        }
    }
    return attachments.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn boundedPageLimit(requested: u32) daemon_store.StoreError!u32 {
    const limit = if (requested == 0) store_protocol.DEFAULT_PAGE_ITEMS else requested;
    if (limit > store_protocol.MAX_PAGE_ITEMS) return error.InvalidParams;
    return limit;
}

fn decodePageCursor(
    cursor: ?[]const u8,
    kind: headless.pagination.Kind,
    store_revision: u64,
    query_scope: []const u8,
) daemon_store.StoreError!usize {
    return headless.pagination.decode(cursor, kind, store_revision, query_scope) catch |err| switch (err) {
        error.InvalidCursor => error.PageCursorInvalid,
        error.StaleCursor => error.PageCursorStale,
        error.QueryMismatch => error.PageCursorMismatch,
    };
}

fn encodePageCursor(
    allocator: std.mem.Allocator,
    kind: headless.pagination.Kind,
    store_revision: u64,
    query_scope: []const u8,
    offset: usize,
) daemon_store.StoreError![]u8 {
    return headless.pagination.encodeAlloc(
        allocator,
        kind,
        store_revision,
        query_scope,
        offset,
    ) catch return error.OutOfMemory;
}

fn workspacePageScope(include_archived: bool) []const u8 {
    return if (include_archived) "all" else "active";
}

fn decodeMessageIndex(cursor: ?[]const u8, prefix: u8) daemon_store.StoreError!usize {
    const value = cursor orelse return 0;
    if (value.len < 3 or value[0] != prefix or value[1] != ':') return error.InvalidParams;
    for (value[2..]) |char| {
        if (char < '0' or char > '9') return error.InvalidParams;
    }
    return std.fmt.parseInt(usize, value[2..], 10) catch return error.InvalidParams;
}

fn encodeMessageIndex(
    allocator: std.mem.Allocator,
    prefix: u8,
    index: usize,
) daemon_store.StoreError![]u8 {
    return std.fmt.allocPrint(allocator, "{c}:{d}", .{ prefix, index }) catch return error.OutOfMemory;
}

fn makePrimaryRepository(
    allocator: std.mem.Allocator,
    runtime_id: []const u8,
    root_path: []const u8,
) daemon_store.StoreError!store_protocol.Repository {
    const repository_id = allocator.dupe(u8, store_protocol.PRIMARY_REPOSITORY_ID) catch return error.OutOfMemory;
    errdefer allocator.free(repository_id);
    const label = allocator.dupe(u8, "Primary") catch return error.OutOfMemory;
    errdefer allocator.free(label);
    const binding_runtime_id = allocator.dupe(u8, runtime_id) catch return error.OutOfMemory;
    errdefer allocator.free(binding_runtime_id);
    const binding_root_path = allocator.dupe(u8, root_path) catch return error.OutOfMemory;
    errdefer allocator.free(binding_root_path);
    const bindings = allocator.alloc(store_protocol.RepositoryBinding, 1) catch return error.OutOfMemory;
    bindings[0] = .{
        .runtime_id = binding_runtime_id,
        .root_path = binding_root_path,
    };
    return .{
        .repository_id = repository_id,
        .label = label,
        .bindings = bindings,
    };
}

fn freeRepository(allocator: std.mem.Allocator, repository: store_protocol.Repository) void {
    allocator.free(repository.repository_id);
    allocator.free(repository.label);
    if (repository.vcs_identity) |value| allocator.free(value);
    if (repository.default_branch) |value| allocator.free(value);
    for (repository.bindings) |binding| {
        allocator.free(binding.runtime_id);
        allocator.free(binding.root_path);
    }
    if (repository.bindings.len > 0) allocator.free(repository.bindings);
}

fn freeWorkspaceListItem(allocator: std.mem.Allocator, item: store_protocol.WorkspaceListItem) void {
    allocator.free(item.workspace_id);
    allocator.free(item.label);
    allocator.free(item.path);
    for (item.repositories) |repository| freeRepository(allocator, repository);
    if (item.repositories.len > 0) allocator.free(item.repositories);
}

fn loadWorkspaceListResult(
    allocator: std.mem.Allocator,
    store: *daemon_store.Store,
    runtime_id: []const u8,
    request: store_protocol.WorkspaceListRequest,
) daemon_store.StoreError!store_protocol.WorkspaceListResult {
    const limit = try boundedPageLimit(request.limit);
    const store_revision = store.storeRevision() catch return error.StoreUnavailable;
    const query_scope = workspacePageScope(request.include_archived);
    const offset = try decodePageCursor(request.cursor, .workspace, store_revision, query_scope);
    const offset_i64 = std.math.cast(i64, offset) orelse return error.InvalidParams;
    const fetch_limit: i64 = @intCast(limit + 1);

    var items: std.ArrayListUnmanaged(store_protocol.WorkspaceListItem) = .empty;
    errdefer {
        for (items.items) |item| freeWorkspaceListItem(allocator, item);
        items.deinit(allocator);
    }
    var rows = store.conn.rows(
        \\select workspace_id, label, path, sort_index, archived
        \\from workspaces
        \\where (?1 != 0 or archived = 0)
        \\order by sort_index asc, workspace_id asc
        \\limit ?2 offset ?3
    , .{ @as(i64, @intFromBool(request.include_archived)), fetch_limit, offset_i64 }) catch return error.StoreUnavailable;
    defer rows.deinit();
    while (rows.next()) |row| {
        const workspace_id = allocator.dupe(u8, row.text(0)) catch return error.OutOfMemory;
        errdefer allocator.free(workspace_id);
        const label = allocator.dupe(u8, row.text(1)) catch return error.OutOfMemory;
        errdefer allocator.free(label);
        const path = allocator.dupe(u8, row.text(2)) catch return error.OutOfMemory;
        errdefer allocator.free(path);
        const repository = try makePrimaryRepository(allocator, runtime_id, row.text(2));
        errdefer freeRepository(allocator, repository);
        const repositories = allocator.alloc(store_protocol.Repository, 1) catch return error.OutOfMemory;
        repositories[0] = repository;
        errdefer allocator.free(repositories);
        items.append(allocator, .{
            .workspace_id = workspace_id,
            .label = label,
            .path = path,
            .sort_index = std.math.cast(usize, row.int(3)) orelse return error.StoreCorrupt,
            .archived = row.int(4) != 0,
            .repositories = repositories,
        }) catch return error.OutOfMemory;
    }
    if (rows.err) |_| return error.StoreUnavailable;

    const has_more = items.items.len > @as(usize, limit);
    if (has_more) {
        const extra_index = items.items.len - 1;
        freeWorkspaceListItem(allocator, items.items[extra_index]);
        items.items.len = extra_index;
    }
    const next_cursor = if (has_more) blk: {
        const next_offset = std.math.add(usize, offset, items.items.len) catch return error.InvalidParams;
        break :blk try encodePageCursor(
            allocator,
            .workspace,
            store_revision,
            query_scope,
            next_offset,
        );
    } else null;
    errdefer if (next_cursor) |value| allocator.free(value);
    return .{
        .workspaces = items.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .next_cursor = next_cursor,
        .store_revision = store_revision,
    };
}

fn freeWorkspaceListResult(allocator: std.mem.Allocator, result: store_protocol.WorkspaceListResult) void {
    for (result.workspaces) |item| freeWorkspaceListItem(allocator, item);
    allocator.free(result.workspaces);
    if (result.next_cursor) |value| allocator.free(value);
}

fn loadThreadListResult(
    allocator: std.mem.Allocator,
    store: *daemon_store.Store,
    request: store_protocol.ThreadListRequest,
) daemon_store.StoreError!store_protocol.ThreadListResult {
    if (request.workspace_id.len == 0) return error.InvalidParams;
    const limit = try boundedPageLimit(request.limit);
    const store_revision = store.storeRevision() catch return error.StoreUnavailable;
    const offset = try decodePageCursor(request.cursor, .thread, store_revision, request.workspace_id);
    const offset_i64 = std.math.cast(i64, offset) orelse return error.InvalidParams;
    const fetch_limit: i64 = @intCast(limit + 1);

    var items: std.ArrayListUnmanaged(store_protocol.ThreadListItem) = .empty;
    errdefer {
        for (items.items) |item| freeThreadListItem(allocator, item);
        items.deinit(allocator);
    }

    var rows = store.conn.rows(
        \\select t.local_thread_id, t.title, t.archived, t.committed, t.last_activity_at,
        \\       t.provider_thread_id, t.model_ref, t.reasoning_effort, t.reasoning_variant,
        \\       t.fast_mode, t.access_mode, t.provider, t.harness, t.sort_index, t.cwd,
        \\       t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd
        \\from threads t
        \\join workspaces w on w.id = t.workspace_id
        \\where w.workspace_id = ?1
        \\order by t.sort_index asc, t.local_thread_id asc
        \\limit ?2 offset ?3
    ,
        .{ request.workspace_id, fetch_limit, offset_i64 },
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
        const reasoning_variant = dupeOptionalText(allocator, row.nullableText(8)) catch return error.OutOfMemory;
        errdefer if (reasoning_variant) |value| allocator.free(value);
        const provider = allocator.dupe(u8, providerNameFromCode(row.int(11))) catch return error.OutOfMemory;
        errdefer allocator.free(provider);
        const harness_name = allocator.dupe(u8, harnessNameFromCode(row.int(12))) catch return error.OutOfMemory;
        errdefer allocator.free(harness_name);
        const cwd = dupeOptionalText(allocator, row.nullableText(14)) catch return error.OutOfMemory;
        errdefer if (cwd) |value| allocator.free(value);
        const profile_id = dupeOptionalText(allocator, row.nullableText(15)) catch return error.OutOfMemory;
        errdefer if (profile_id) |value| allocator.free(value);
        const runtime_id = dupeOptionalText(allocator, row.nullableText(16)) catch return error.OutOfMemory;
        errdefer if (runtime_id) |value| allocator.free(value);
        const repository_id = dupeOptionalText(allocator, row.nullableText(17)) catch return error.OutOfMemory;
        errdefer if (repository_id) |value| allocator.free(value);
        const repository_cwd = dupeOptionalText(allocator, row.nullableText(18)) catch return error.OutOfMemory;
        errdefer if (repository_cwd) |value| allocator.free(value);
        items.append(allocator, .{
            .local_thread_id = local_thread_id,
            .title = title,
            .sort_index = std.math.cast(usize, row.int(13)) orelse 0,
            .archived = row.int(2) != 0,
            .committed = row.int(3) != 0,
            .last_activity_at = row.nullableInt(4),
            .provider_thread_id = provider_thread_id,
            .model_ref = model_ref,
            .reasoning_effort = if (row.nullableInt(7)) |code| reasoningEffortNameFromCode(code) else null,
            .reasoning_variant = reasoning_variant,
            .fast_mode = if (row.nullableInt(9)) |code| fastModeNameFromCode(code) else null,
            .access_mode = if (row.nullableInt(10)) |code| accessModeNameFromCode(code) else null,
            .provider = provider,
            .harness = harness_name,
            .cwd = cwd,
            .profile_id = profile_id,
            .runtime_id = runtime_id,
            .repository_id = repository_id,
            .repository_cwd = repository_cwd,
        }) catch return error.OutOfMemory;
    }
    if (rows.err) |_| return error.StoreUnavailable;

    const has_more = items.items.len > @as(usize, limit);
    if (has_more) {
        const extra_index = items.items.len - 1;
        freeThreadListItem(allocator, items.items[extra_index]);
        items.items.len = extra_index;
    }
    const next_cursor = if (has_more) blk: {
        const next_offset = std.math.add(usize, offset, items.items.len) catch return error.InvalidParams;
        break :blk try encodePageCursor(
            allocator,
            .thread,
            store_revision,
            request.workspace_id,
            next_offset,
        );
    } else null;
    errdefer if (next_cursor) |value| allocator.free(value);
    return .{
        .threads = try items.toOwnedSlice(allocator),
        .next_cursor = next_cursor,
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
    if (item.reasoning_variant) |value| allocator.free(value);
    allocator.free(item.provider);
    allocator.free(item.harness);
    if (item.cwd) |value| allocator.free(value);
    if (item.profile_id) |value| allocator.free(value);
    if (item.runtime_id) |value| allocator.free(value);
    if (item.repository_id) |value| allocator.free(value);
    if (item.repository_cwd) |value| allocator.free(value);
}

fn loadMessageListResult(
    allocator: std.mem.Allocator,
    store: *daemon_store.Store,
    request: store_protocol.MessageListRequest,
) daemon_store.StoreError!store_protocol.MessageListResult {
    if (request.workspace_id.len == 0 or request.local_thread_id.len == 0) return error.InvalidParams;
    const is_backward = std.mem.eql(u8, request.direction, "backward");
    const is_forward = std.mem.eql(u8, request.direction, "forward");
    if (!is_backward and !is_forward) return error.InvalidParams;
    const limit = try boundedPageLimit(request.limit);
    const cursor_index = try decodeMessageIndex(request.cursor, if (is_backward) 'b' else 'f');
    const boundary: i64 = if (request.cursor) |_|
        (std.math.cast(i64, cursor_index) orelse return error.InvalidParams)
    else if (is_backward)
        std.math.maxInt(i64)
    else
        -1;
    const fetch_limit: i64 = @intCast(limit + 1);

    const thread_row = (store.conn.row(
        \\select t.id
        \\from threads t join workspaces w on w.id = t.workspace_id
        \\where w.workspace_id = ?1 and t.local_thread_id = ?2
    , .{ request.workspace_id, request.local_thread_id }) catch return error.StoreUnavailable) orelse
        return error.ResourceNotFound;
    const thread_row_id = thread_row.int(0);
    thread_row.deinit();

    var messages: std.ArrayListUnmanaged(store_protocol.Message) = .empty;
    errdefer {
        for (messages.items) |message| freeOwnedMessage(allocator, message);
        messages.deinit(allocator);
    }
    var rows = (if (is_backward)
        store.conn.rows(
            \\select sort_index, message_id, role, author, body, image_path, image_mime,
            \\       image_byte_size, extra_images_json, created_at_ms, updated_at_ms,
            \\       tool_call_id, tool_call_kind, tool_call_status
            \\from messages
            \\where thread_id = ?1 and sort_index < ?2
            \\order by sort_index desc
            \\limit ?3
        , .{ thread_row_id, boundary, fetch_limit })
    else
        store.conn.rows(
            \\select sort_index, message_id, role, author, body, image_path, image_mime,
            \\       image_byte_size, extra_images_json, created_at_ms, updated_at_ms,
            \\       tool_call_id, tool_call_kind, tool_call_status
            \\from messages
            \\where thread_id = ?1 and sort_index > ?2
            \\order by sort_index asc
            \\limit ?3
        , .{ thread_row_id, boundary, fetch_limit })) catch return error.StoreUnavailable;
    defer rows.deinit();
    while (rows.next()) |row| {
        const message = try decodeOwnedMessage(allocator, row);
        errdefer freeOwnedMessage(allocator, message);
        messages.append(allocator, message) catch return error.OutOfMemory;
    }
    if (rows.err) |_| return error.StoreUnavailable;

    const has_more = messages.items.len > @as(usize, limit);
    if (has_more) {
        const extra_index = messages.items.len - 1;
        freeOwnedMessage(allocator, messages.items[extra_index]);
        messages.items.len = extra_index;
    }
    if (is_backward) std.mem.reverse(store_protocol.Message, messages.items);
    const next_cursor = if (has_more) blk: {
        const next_index = if (is_backward)
            messages.items[0].sort_index
        else
            messages.items[messages.items.len - 1].sort_index;
        break :blk try encodeMessageIndex(allocator, if (is_backward) 'b' else 'f', next_index);
    } else null;
    errdefer if (next_cursor) |value| allocator.free(value);
    const store_revision = store.storeRevision() catch return error.StoreUnavailable;
    return .{
        .messages = messages.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .next_cursor = next_cursor,
        .store_revision = store_revision,
    };
}

fn freeMessageListResult(allocator: std.mem.Allocator, result: store_protocol.MessageListResult) void {
    for (result.messages) |message| freeOwnedMessage(allocator, message);
    allocator.free(result.messages);
    if (result.next_cursor) |value| allocator.free(value);
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
        4 => "pi",
        5 => "fx",
        6 => "grok",
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

fn roleNameFromCode(code: i64, author: []const u8) []const u8 {
    return @tagName(db_types.decodeStoredChatRole(code, author));
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
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_WORKSPACES) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_REGISTRY) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_SESSIONS) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_TURNS) or
        std.mem.eql(u8, scope_name, store_protocol.SNAPSHOT_SCOPE_CONFIG);
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

fn configSnapshotFromApp(allocator: std.mem.Allocator, config: *const app_config.AppConfig) !store_protocol.ConfigSnapshot {
    const favorites = try allocator.alloc(store_protocol.ConfigFavoriteModel, config.favorite_models.len);
    for (config.favorite_models, favorites) |favorite, *snapshot| {
        snapshot.* = .{
            .provider = @tagName(favorite.provider),
            .model = favorite.model,
        };
    }
    return .{
        .ui = .{
            .workspace_pane_gap = config.workspace_pane_gap,
            .workspace_panes_per_view = config.workspace_panes_per_view,
            .workspace_split_default_pane = @tagName(config.workspace_split_default_pane),
            .workspace_scroll_direction = @tagName(config.workspace_scroll_direction),
            .workspace_scroll_mode = @tagName(config.workspace_scroll_mode),
            .workspace_scroll_threshold = config.workspace_scroll_threshold,
            .unzoom_on_pane_navigation = config.unzoom_on_pane_navigation,
            .reduced_motion = config.reduced_motion,
        },
        .chat = .{ .favorite_models = favorites },
    };
}

/// Load verde.json off the daemon lock and project the client-visible UI
/// slice. Missing or unreadable files fall back to AppConfig defaults so a
/// detached UI still gets a coherent strip instead of omitting the field.
fn writeConfigSnapshot(s: *std.json.Stringify, daemon: *Daemon) !void {
    daemon.config_mutex.lock();
    defer daemon.config_mutex.unlock();
    var config = app_config.loadAppConfig(daemon.allocator) catch {
        try s.write(store_protocol.ConfigSnapshot{});
        return;
    };
    defer config.deinit(daemon.allocator);
    var snapshot = try configSnapshotFromApp(daemon.allocator, &config);
    defer daemon.allocator.free(snapshot.chat.favorite_models);
    var root = app_config.readRootValue(daemon.allocator) catch null;
    defer if (root) |*parsed| parsed.deinit();
    if (root) |parsed| {
        if (parsed.value == .object) snapshot.keybinds = parsed.value.object.get("keybinds") orelse .null;
    }
    try s.write(snapshot);
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
    try std.testing.expect(!scopeIsIncomplete("workspaces", true));
    try std.testing.expect(!scopeIsIncomplete("registry", true));
    try std.testing.expect(!scopeIsIncomplete("sessions", true));
    try std.testing.expect(!scopeIsIncomplete("turns", true));
    try std.testing.expect(!scopeIsIncomplete("config", true));
    // Pre-M4 arm (scenario 6): the store scope must be honestly incomplete
    // while chat authority is still GUI-side; volatile scopes are unaffected.
    try std.testing.expect(scopeIsIncomplete("store", false));
    try std.testing.expect(!scopeIsIncomplete("registry", false));
    try std.testing.expect(!scopeIsIncomplete("config", false));
    // Unknown scope names are incomplete in both arms.
    try std.testing.expect(scopeIsIncomplete("chat", true));
    try std.testing.expect(scopeIsIncomplete("chat", false));
    // The runtime constant documents the landed authority flip.
    try std.testing.expect(CHAT_AUTHORITY_LANDED);
}

test "config snapshot projects workspace strip settings and model favorites" {
    var config: app_config.AppConfig = .{
        .workspace_pane_gap = 8.0,
        .workspace_panes_per_view = 1,
        .workspace_scroll_direction = .vertical,
        .workspace_scroll_mode = .always,
        .workspace_scroll_threshold = 4,
        .unzoom_on_pane_navigation = true,
        .reduced_motion = true,
    };
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(try config.toggleFavoriteModel(std.testing.allocator, .claude, "claude-opus-4-1"));
    const snapshot = try configSnapshotFromApp(std.testing.allocator, &config);
    defer std.testing.allocator.free(snapshot.chat.favorite_models);
    try std.testing.expectEqual(@as(f32, 8.0), snapshot.ui.workspace_pane_gap);
    try std.testing.expectEqual(@as(u8, 1), snapshot.ui.workspace_panes_per_view);
    try std.testing.expectEqualStrings("vertical", snapshot.ui.workspace_scroll_direction);
    try std.testing.expectEqualStrings("always", snapshot.ui.workspace_scroll_mode);
    try std.testing.expectEqual(@as(u8, 4), snapshot.ui.workspace_scroll_threshold);
    try std.testing.expect(snapshot.ui.unzoom_on_pane_navigation);
    try std.testing.expect(snapshot.ui.reduced_motion);
    try std.testing.expectEqual(@as(usize, 1), snapshot.chat.favorite_models.len);
    try std.testing.expectEqualStrings("claude", snapshot.chat.favorite_models[0].provider);
    try std.testing.expectEqualStrings("claude-opus-4-1", snapshot.chat.favorite_models[0].model);
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
    try std.testing.expectEqual(@as(usize, 8), platform_ipc.MAX_PARKED_LONG_POLL_WAITERS);
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
    // degrades immediately and releases its reserved slot. The counter is
    // shared with turn-tail parks, so BOTH park kinds respect it.
    const cap: u32 = @intCast(platform_ipc.MAX_PARKED_LONG_POLL_WAITERS);
    daemon.long_poll_parked.store(cap, .release);
    try std.testing.expectEqual(Daemon.ChangesParkOutcome.over_cap, daemon.parkForChanges(daemon.changes_signal.load(.acquire), nowMs() + 1000));
    try std.testing.expectEqual(Daemon.ChangesParkOutcome.over_cap, daemon.parkForTurnEvents(daemon.turn_events_signal.load(.acquire), nowMs() + 1000));
    try std.testing.expectEqual(cap, daemon.long_poll_parked.load(.acquire));
    daemon.long_poll_parked.store(0, .release);

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

test "batched journal appends signal parked changes waiters exactly once" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const observed = daemon.changes_signal.load(.acquire);
    const Parker = struct {
        fn run(d: *Daemon, obs: u32, out: *std.atomic.Value(u32)) void {
            // Race-free either way: if the batch signal lands first, the
            // changed signal word makes this return .woken without sleeping.
            if (d.parkForChanges(obs, nowMs() + 10_000) == .woken) out.store(1, .release);
        }
    };
    var woken: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, Parker.run, .{ &daemon, observed, &woken });
    // A multi-entry commit batch (the snapshot-replace / turn-commit hook
    // shape): quiet appends never bump the signal word; the one trailing
    // signal both wakes the waiter and is the only bump for the whole batch.
    daemon.appendJournalEntryQuiet(.workspace, "w1", "w1", .{ .store = 1 });
    daemon.appendJournalEntryQuiet(.chat_thread, "t1", "w1", .{ .store = 1 });
    daemon.appendJournalEntryQuiet(.chat_turn, "turn1", "w1", .{ .store = 1 });
    daemon.signalChangesWaiters();
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), woken.load(.acquire));
    try std.testing.expectEqual(observed + 1, daemon.changes_signal.load(.acquire));
    // Every batched entry still landed in the journal.
    try std.testing.expectEqual(@as(u64, 3), daemon.journal.last_seq);
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
    include_workspaces: bool,
) daemon_store.StoreError!LoadedStoreSnapshot {
    store.conn.execNoArgs("begin") catch return error.StoreUnavailable;
    var transaction_open = true;
    defer if (transaction_open) store.conn.rollback();

    const store_revision = try store.storeRevision();
    var snapshot: store_protocol.Snapshot = .{ .store_revision = store_revision };
    if (include_store or include_workspaces) {
        // The workspaces-only scope skips thread/message hydration so the
        // reply stays far below the transport cap the full store scope hits.
        snapshot = try loadSnapshotContents(arena, store, workspace_filter, include_store);
        snapshot.store_revision = store_revision;
    }
    store.conn.commit() catch return error.StoreUnavailable;
    transaction_open = false;
    return .{ .snapshot = snapshot, .store_revision = store_revision };
}

/// Decode a durable `*_images_json` column into the full attachment list
/// ([primary] ++ extras). Returns an empty list when there is no primary; a
/// malformed extras column degrades to primary-only with a warning instead of
/// failing the whole snapshot read.
fn decodeAttachmentList(
    arena: std.mem.Allocator,
    primary: ?store_protocol.Attachment,
    encoded: ?[]const u8,
) daemon_store.StoreError![]const store_protocol.Attachment {
    const first = primary orelse return &.{};
    var list: std.ArrayList(store_protocol.Attachment) = .empty;
    list.append(arena, first) catch return error.OutOfMemory;
    if (encoded) |text| {
        // SQLite row memory dies on the next step: own the JSON before parse
        // so parsed string slices can borrow stable arena bytes.
        const owned = arena.dupe(u8, text) catch return error.OutOfMemory;
        const extras = std.json.parseFromSliceLeaky(
            []daemon_store.StoredExtraImage,
            arena,
            owned,
            .{ .ignore_unknown_fields = true },
        ) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.warn("malformed stored extra-images column dropped err={s}", .{@errorName(err)});
            break :blk &.{};
        };
        for (extras) |extra| {
            list.append(arena, .{
                .path = extra.path,
                .mime = extra.mime,
                .byte_size = std.math.cast(usize, extra.byte_size) orelse 0,
            }) catch return error.OutOfMemory;
        }
    }
    return list.items;
}

/// Materialize the typed store snapshot (workspaces → threads → messages,
/// surfaces, completions) inside the caller's open read transaction.
fn loadSnapshotContents(
    arena: std.mem.Allocator,
    store: *daemon_store.Store,
    workspace_filter: ?[]const u8,
    include_threads: bool,
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
    // Skipped entirely for the lightweight workspaces-only scope.
    const ThreadRow = struct { row_id: i64, thread: store_protocol.Thread };
    for (workspace_rows.items) |*workspace_row| {
        if (!include_threads) break;
        var thread_rows: std.ArrayList(ThreadRow) = .empty;
        {
            var rows = store.conn.rows(
                \\select id, local_thread_id, title, archived, committed, last_activity_at,
                \\       provider_thread_id, model_ref, reasoning_effort, reasoning_variant,
                \\       fast_mode, access_mode, provider, harness, tui_dock_id, draft,
                \\       draft_image_path, draft_image_mime, draft_image_byte_size, draft_images_json, cwd,
                \\       profile_id, runtime_id, repository_id, repository_cwd
                \\from threads where workspace_id = ?1 order by sort_index
            , .{workspace_row.row_id}) catch return error.StoreUnavailable;
            defer rows.deinit();
            while (rows.next()) |row| {
                const draft_image: ?store_protocol.Attachment = if (row.nullableText(16)) |path| .{
                    .path = arena.dupe(u8, path) catch return error.OutOfMemory,
                    .mime = arena.dupe(u8, row.nullableText(17) orelse "") catch return error.OutOfMemory,
                    .byte_size = if (row.nullableInt(18)) |value| (std.math.cast(usize, value) orelse 0) else 0,
                } else null;
                const draft_images = try decodeAttachmentList(arena, draft_image, row.nullableText(19));
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
                        .draft_images = draft_images,
                        .cwd = dupeOptionalText(arena, row.nullableText(20)) catch return error.OutOfMemory,
                        .profile_id = dupeOptionalText(arena, row.nullableText(21)) catch return error.OutOfMemory,
                        .runtime_id = dupeOptionalText(arena, row.nullableText(22)) catch return error.OutOfMemory,
                        .repository_id = dupeOptionalText(arena, row.nullableText(23)) catch return error.OutOfMemory,
                        .repository_cwd = dupeOptionalText(arena, row.nullableText(24)) catch return error.OutOfMemory,
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
                \\       created_at_ms, updated_at_ms, extra_images_json, sort_index
                \\from messages where thread_id = ?1 order by sort_index
            , .{thread_row.row_id}) catch return error.StoreUnavailable;
            defer rows.deinit();
            while (rows.next()) |row| {
                const image: ?store_protocol.Attachment = if (row.nullableText(4)) |path| .{
                    .path = arena.dupe(u8, path) catch return error.OutOfMemory,
                    .mime = arena.dupe(u8, row.nullableText(5) orelse "") catch return error.OutOfMemory,
                    .byte_size = if (row.nullableInt(6)) |value| (std.math.cast(usize, value) orelse 0) else 0,
                } else null;
                const images = try decodeAttachmentList(arena, image, row.nullableText(12));
                messages.append(arena, .{
                    .sort_index = std.math.cast(usize, row.int(13)) orelse return error.StoreCorrupt,
                    .message_id = arena.dupe(u8, row.nullableText(0) orelse "") catch return error.OutOfMemory,
                    .role = roleNameFromCode(row.int(1), row.text(2)),
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
        error.StoreCorrupt,
        error.RuntimeIdentityMismatch,
        error.InvalidRuntimeIdentity,
        => .{ .code = headless.protocol.ERR_STORE_CORRUPT, .message = "store is corrupt" },
        error.StoreUnavailable => .{ .code = headless.protocol.ERR_STORE_UNAVAILABLE, .message = "store is unavailable" },
        error.PageCursorInvalid => .{
            .code = headless.protocol.ERR_INVALID_PARAMS,
            .message = "invalid page cursor; restart pagination without a cursor",
        },
        error.PageCursorStale => .{
            .code = headless.protocol.ERR_REVISION_EXPIRED,
            .message = "page cursor is stale; restart pagination without a cursor",
        },
        error.PageCursorMismatch => .{
            .code = headless.protocol.ERR_INVALID_PARAMS,
            .message = "page cursor does not match this query; restart pagination without a cursor",
        },
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
    return std.mem.eql(u8, method, "chat.turn.start") or
        std.mem.eql(u8, method, "chat.turn.tail") or
        std.mem.eql(u8, method, "chat.turn.steer") or
        std.mem.eql(u8, method, "chat.followup") or
        // Read-only provider discovery performs bounded PATH lookups and
        // touches no daemon state, so never hold lockDaemon around filesystem I/O.
        std.mem.eql(u8, method, "provider.models.list") or
        std.mem.eql(u8, method, headless.providers_protocol.METHOD_PROVIDERS_STATUS) or
        // FX lifecycle persistence uses the store spine and owns its short
        // lockDaemon window, like the other unlocked mutation paths.
        isFxLifecycleMethod(method) or
        // Shared config writes have their own leaf lock and filesystem I/O.
        std.mem.eql(u8, method, store_protocol.METHOD_CONFIG_FAVORITE_MODEL_SET);
}

fn isFxLifecycleMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, FX_REPORT_AGENT_METHOD) or
        std.mem.eql(u8, method, FX_REPORT_SESSION_METHOD) or
        std.mem.eql(u8, method, FX_PANE_RENAME_METHOD) or
        std.mem.eql(u8, method, FX_AGENT_RENAME_METHOD) or
        std.mem.eql(u8, method, FX_CLEAR_AUTHORITY_METHOD);
}

fn classifyServerRequest(allocator: std.mem.Allocator, request: []const u8) !ServerRequestClass {
    // Streaming scan for the top-level "method" key only. Request bodies reach
    // 8 MiB (state.snapshot.replace), and materializing a full std.json.Value
    // DOM here just to read one field doubled the daemon's parse cost for
    // every large request; handleRequest still performs the one authoritative
    // full parse. The tail drain keeps malformed bodies classifying as
    // invalid_request exactly as the DOM parse did.
    var scanner = std.json.Scanner.initCompleteInput(allocator, request);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidRequest;
    const class: ServerRequestClass = while (true) {
        const key_token = try scanner.nextAlloc(allocator, .alloc_if_needed);
        var key_owned: ?[]u8 = null;
        defer if (key_owned) |owned| allocator.free(owned);
        const key: []const u8 = switch (key_token) {
            .string => |value| value,
            .allocated_string => |value| blk: {
                key_owned = value;
                break :blk value;
            },
            else => return error.InvalidRequest, // object_end: no "method" key
        };
        if (!std.mem.eql(u8, key, "method")) {
            try scanner.skipValue();
            continue;
        }
        const value_token = try scanner.nextAlloc(allocator, .alloc_if_needed);
        var method_owned: ?[]u8 = null;
        defer if (method_owned) |owned| allocator.free(owned);
        const method: []const u8 = switch (value_token) {
            .string => |value| value,
            .allocated_string => |value| blk: {
                method_owned = value;
                break :blk value;
            },
            else => return error.InvalidRequest,
        };
        if (methodNeedsSlowWork(method)) break .slow_registry;
        if (isStoreMethod(method)) break .store;
        if (methodRunsUnlocked(method)) break .unlocked_method;
        break .normal;
    };
    // Validate the remainder so a syntax error after "method" still reports
    // invalid_request instead of reaching the handler misclassified.
    while (try scanner.next() != .end_of_document) {}
    return class;
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
    stopMcpHttpServer(context);
    joinDrainThread(context);
    // Store finalization is primarily done in on_closing (before endpoint
    // release). This call is a no-op when that already ran.
    finalizeSessionizerStore(context);
    if (context.pid_published) deletePidFileIfOwned(context.pid_path);
}

fn stopMcpHttpServer(context: *SessionizerServerContext) void {
    if (context.mcp_server) |*server| server.deinit();
    context.mcp_server = null;
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

    // Drain writes and read-side lifetime pins before destroy so no captured
    // service pointer can outlive store.deinit. On timeout, deliberately leak
    // the service rather than risk use-after-free.
    {
        const drain_deadline = nowMs() + 2000;
        while (service.in_flight.load(.monotonic) != 0 or
            service.lifetime_pins.load(.monotonic) != 0)
        {
            if (nowMs() >= drain_deadline) {
                log.warn(
                    "store finalize lifetime drain timed out writes={d} pins={d}; leaking store service to avoid UAF",
                    .{
                        service.in_flight.load(.monotonic),
                        service.lifetime_pins.load(.monotonic),
                    },
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
    daemon.mutex.lock();
}

fn lockTurn(turn: *ChatTurn) void {
    turn.mutex.lock();
}

fn lockJournal(daemon: *Daemon) void {
    daemon.journal_mutex.lock();
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

/// True when a tail response would carry something a `wait_ms` long-poller
/// has not seen: events past its cursor, or a published terminal status
/// (the durable-commit flip arrives without a new event append). Must be
/// called under the turn mutex.
fn chatTailHasNews(turn: *const ChatTurn, after_seq: u64) bool {
    // Events carry seqs 1..next_seq-1, so anything exists past the cursor
    // exactly when next_seq is at least two ahead of it.
    if (turn.next_seq > after_seq + 1) return true;
    return switch (chatTurnPublishedStatus(turn)) {
        .completed, .failed, .aborted => true,
        .running, .waiting_approval => false,
    };
}

fn sleepMs(milliseconds: i64) void {
    platform_runtime.sleepMillis(@intCast(@max(milliseconds, 0)));
}

const FxLifecycleState = enum {
    idle,
    working,
    blocked,
};

const FxLifecycleTransition = enum {
    clear,
    working,
    waiting,
    done,
};

fn fxLifecycleTransition(turn_active: *bool, state: FxLifecycleState) FxLifecycleTransition {
    return switch (state) {
        .working => active: {
            turn_active.* = true;
            break :active .working;
        },
        .blocked => active: {
            turn_active.* = true;
            break :active .waiting;
        },
        .idle => if (turn_active.*) finished: {
            turn_active.* = false;
            break :finished .done;
        } else .clear,
    };
}

fn fxLifecycleRelease(turn_active: *bool) FxLifecycleTransition {
    turn_active.* = false;
    return .clear;
}

fn exposeTerminalLifecycleSocket(socket_path: [:0]const u8, session_id: [:0]const u8) void {
    // A provider launched later from an interactive shell must still report to
    // its owning Verde pane, even when Verde inherited Herdr from its parent.
    _ = setenv("HERDR_SOCKET_PATH", socket_path.ptr, 1);
    _ = setenv("HERDR_PANE_ID", session_id.ptr, 1);
}

test "FX lifecycle transitions clear startup state and finish active turns" {
    var active = false;
    try std.testing.expectEqual(FxLifecycleTransition.clear, fxLifecycleTransition(&active, .idle));
    try std.testing.expect(!active);
    try std.testing.expectEqual(FxLifecycleTransition.working, fxLifecycleTransition(&active, .working));
    try std.testing.expect(active);
    try std.testing.expectEqual(FxLifecycleTransition.waiting, fxLifecycleTransition(&active, .blocked));
    try std.testing.expect(active);
    try std.testing.expectEqual(FxLifecycleTransition.done, fxLifecycleTransition(&active, .idle));
    try std.testing.expect(!active);
    active = true;
    try std.testing.expectEqual(FxLifecycleTransition.clear, fxLifecycleRelease(&active));
    try std.testing.expect(!active);
}

test "FX lifecycle socket methods run outside the daemon lock" {
    inline for (.{
        FX_REPORT_AGENT_METHOD,
        FX_REPORT_SESSION_METHOD,
        FX_PANE_RENAME_METHOD,
        FX_AGENT_RENAME_METHOD,
        FX_CLEAR_AUTHORITY_METHOD,
    }) |method| {
        try std.testing.expect(isFxLifecycleMethod(method));
        try std.testing.expect(methodRunsUnlocked(method));
    }
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
    // Acceptance timestamp so detached clients render the same working timer
    // as the desktop instead of counting from when they first saw the turn.
    try s.objectField("started_at_ms");
    try s.write(turn.started_at_ms);
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

fn writeChatTurnTail(
    s: *std.json.Stringify,
    turn: *const ChatTurn,
    after_seq: u64,
    through_seq: u64,
    has_more_events: bool,
) !void {
    try s.beginObject();
    try s.objectField("status");
    // Durable-first: tail status=completed/failed/aborted only with the receipt.
    const published_status = chatTurnPublishedStatus(turn);
    const page_status: ChatTurnStatus = if (has_more_events and chatTurnStatusIsTerminal(published_status))
        .running
    else
        published_status;
    try s.write(@tagName(page_status));
    // Same clock the desktop's working timer counts from (turn acceptance).
    try s.objectField("started_at_ms");
    try s.write(turn.started_at_ms);
    try s.objectField("events");
    try s.beginArray();
    for (chatTailEventsAfter(turn, after_seq)) |event| {
        if (event.seq > through_seq) break;
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
    try s.objectField("page_last_seq");
    try s.write(through_seq);
    try s.objectField("has_more_events");
    try s.write(has_more_events);
    try s.objectField("provider_thread_id");
    if (turn.provider_thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("active_turn_id");
    if (turn.active_turn_id) |value| try s.write(value) else try s.write(null);
    // Attach hydration: clients that did not start this turn (e.g. desktop
    // viewing a web-started turn) mirror the user row from these two fields.
    try s.objectField("user_message_id");
    if (turn.user_message_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("user_prompt");
    try s.write(turn.request.prompt);
    try s.objectField("result_reply_text");
    if (!has_more_events) {
        if (turn.result_reply_text) |value| try s.write(value) else try s.write(null);
    } else try s.write(null);
    try s.objectField("generated_title");
    if (!has_more_events and turn.generated_title_applied) {
        if (turn.generated_title) |value| try s.write(value) else try s.write(null);
    } else try s.write(null);
    try s.objectField("generated_title_expected");
    if (!has_more_events and turn.generated_title_applied) try s.write(turn.request.thread_title) else try s.write(null);
    try s.objectField("error_message");
    if (!has_more_events) {
        if (turn.error_message) |value| try s.write(value) else try s.write(null);
    } else try s.write(null);
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

fn durableTurnRecordIsTerminal(record: store_protocol.TurnRecord) bool {
    if (record.committed_store_revision == null) return false;
    return std.mem.eql(u8, record.status, "completed") or
        std.mem.eql(u8, record.status, "failed") or
        std.mem.eql(u8, record.status, "aborted");
}

fn durableChatTurnTailResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    record: store_protocol.TurnRecord,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("status");
    try s.write(record.status);
    try s.objectField("started_at_ms");
    try s.write(record.started_at_ms);
    try s.objectField("events");
    try s.beginArray();
    try s.endArray();
    try s.objectField("next_seq");
    try s.write(0);
    try s.objectField("page_last_seq");
    try s.write(0);
    try s.objectField("has_more_events");
    try s.write(false);
    try s.objectField("provider_thread_id");
    if (record.provider_thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("active_turn_id");
    try s.write(null);
    // Durable fallback: the prompt text is not on the ledger row, so attach
    // hydration is unavailable here; terminal transcripts converge via the
    // durable store instead.
    try s.objectField("user_message_id");
    if (record.user_message_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("user_prompt");
    try s.write(null);
    try s.objectField("result_reply_text");
    try s.write(null);
    try s.objectField("generated_title");
    try s.write(null);
    try s.objectField("generated_title_expected");
    try s.write(null);
    try s.objectField("error_message");
    if (record.error_message) |value| try s.write(value) else try s.write(null);
    try s.objectField("pending_approval");
    try s.write(null);
    try s.objectField("committed_store_revision");
    try s.write(record.committed_store_revision.?);
    try s.objectField("events_compacted_before_seq");
    try s.write(null);
    try s.objectField("durability_pending");
    try s.write(false);
    try s.objectField("durability_error");
    try s.write(null);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// Subslice of events with seq > after_seq. Seqs are dense and ascending
/// (append-only from next_seq=1, no compaction until M5), so the start index
/// is arithmetic on the first event's seq — never a scan. Tail polls arrive
/// at streaming cadence, so any O(turn-events) walk here multiplies into
/// O(turn) daemon CPU per appended delta on large threads. Must be called
/// under the turn mutex.
fn chatTailEventsAfter(turn: *const ChatTurn, after_seq: u64) []const ChatEvent {
    const items = turn.events.items;
    if (items.len == 0) return items;
    const first_seq = items[0].seq;
    if (after_seq < first_seq) return items;
    const skip = after_seq - first_seq + 1;
    if (skip >= items.len) return items[items.len..];
    return items[skip..];
}

fn chatTailPageEndSeq(turn: *const ChatTurn, after_seq: u64, max_bytes: usize) u64 {
    var through_seq = after_seq;
    var total = chatTailMetadataUpperBound(turn, true);
    for (chatTailEventsAfter(turn, after_seq)) |event| {
        const with_event = saturatedAdd(total, chatEventUpperBound(event));
        if (through_seq != after_seq and with_event > max_bytes) break;
        total = with_event;
        through_seq = event.seq;
    }
    return through_seq;
}

fn chatTailHasEventsAfter(turn: *const ChatTurn, seq: u64) bool {
    // Ascending seqs: the newest event alone answers "anything past seq?".
    const items = turn.events.items;
    return items.len != 0 and items[items.len - 1].seq > seq;
}

fn chatTailUpperBound(turn: *const ChatTurn, after_seq: u64, through_seq: u64, include_terminal_fields: bool) usize {
    var total = chatTailMetadataUpperBound(turn, include_terminal_fields);
    for (chatTailEventsAfter(turn, after_seq)) |event| {
        if (event.seq > through_seq) break;
        total = saturatedAdd(total, chatEventUpperBound(event));
    }
    return total;
}

fn chatTailMetadataUpperBound(turn: *const ChatTurn, include_terminal_fields: bool) usize {
    var total: usize = 4096;
    if (turn.provider_thread_id) |value| total = saturatedAdd(total, jsonStringUpperBound(value));
    if (turn.active_turn_id) |value| total = saturatedAdd(total, jsonStringUpperBound(value));
    if (turn.user_message_id) |value| total = saturatedAdd(total, jsonStringUpperBound(value));
    total = saturatedAdd(total, jsonStringUpperBound(turn.request.prompt));
    if (include_terminal_fields) {
        if (turn.result_reply_text) |value| total = saturatedAdd(total, jsonStringUpperBound(value));
        if (turn.generated_title_applied) {
            if (turn.generated_title) |value| total = saturatedAdd(total, jsonStringUpperBound(value));
            total = saturatedAdd(total, jsonStringUpperBound(turn.request.thread_title));
        }
        if (turn.error_message) |value| total = saturatedAdd(total, jsonStringUpperBound(value));
    }
    if (turn.pending_approval) |approval| {
        total = saturatedAdd(total, 96);
        total = saturatedAdd(total, jsonStringUpperBound(approval.call_id));
        total = saturatedAdd(total, jsonStringUpperBound(approval.title));
        total = saturatedAdd(total, jsonStringUpperBound(approval.body));
    }
    return total;
}

fn chatEventUpperBound(event: ChatEvent) usize {
    var total: usize = 96;
    total = saturatedAdd(total, jsonStringUpperBound(event.kind));
    return saturatedAdd(total, jsonStringUpperBound(event.payload_json));
}

fn jsonStringUpperBound(value: []const u8) usize {
    var total: usize = 2;
    for (value) |byte| {
        total = saturatedAdd(total, switch (byte) {
            '\\', '"', 0x08, 0x0c, '\n', '\r', '\t' => 2,
            0x00...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        });
    }
    return total;
}

fn chatTurnStatusIsTerminal(status: ChatTurnStatus) bool {
    return status == .completed or status == .failed or status == .aborted;
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

fn freeAttachmentArray(allocator: std.mem.Allocator, attachments: []const store_protocol.Attachment) void {
    for (attachments) |attachment| {
        allocator.free(attachment.path);
        allocator.free(attachment.mime);
    }
    if (attachments.len > 0) allocator.free(attachments);
}

/// Parse the additive `images` turn param ([{path, mime?, byte_size?}]) into
/// owned attachments. Absent/empty yields an empty slice so legacy
/// `image_paths`-only clients keep working; metadata is stored only when the
/// client genuinely sent it.
fn jsonAttachmentArray(allocator: std.mem.Allocator, value: std.json.Value) ![]store_protocol.Attachment {
    const array = switch (value) {
        .array => |entries| entries,
        else => return &.{},
    };
    if (array.items.len == 0) return &.{};
    var list: std.ArrayList(store_protocol.Attachment) = .empty;
    errdefer {
        for (list.items) |attachment| {
            allocator.free(attachment.path);
            allocator.free(attachment.mime);
        }
        list.deinit(allocator);
    }
    for (array.items) |item| {
        const object = switch (item) {
            .object => |fields| fields,
            else => return error.InvalidParams,
        };
        const path = jsonString(object.get("path") orelse .null) orelse return error.InvalidParams;
        if (path.len == 0) return error.InvalidParams;
        const mime = jsonString(object.get("mime") orelse .null) orelse "";
        const byte_size: usize = if (object.get("byte_size")) |raw| switch (raw) {
            .integer => |number| std.math.cast(usize, number) orelse 0,
            else => 0,
        } else 0;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_mime = try allocator.dupe(u8, mime);
        errdefer allocator.free(owned_mime);
        try list.append(allocator, .{ .path = owned_path, .mime = owned_mime, .byte_size = byte_size });
    }
    return try list.toOwnedSlice(allocator);
}

test "turn images param and stored extra-image columns round-trip full lists" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Params → owned attachments: metadata only when the client sent it.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\[{"path":"/tmp/a.png","mime":"image/png","byte_size":11},{"path":"/tmp/b.png"}]
    ,
        .{},
    );
    defer parsed.deinit();
    const attachments = try jsonAttachmentArray(allocator, parsed.value);
    defer freeAttachmentArray(allocator, attachments);
    try std.testing.expectEqual(@as(usize, 2), attachments.len);
    try std.testing.expectEqualStrings("/tmp/a.png", attachments[0].path);
    try std.testing.expectEqualStrings("image/png", attachments[0].mime);
    try std.testing.expectEqual(@as(usize, 11), attachments[0].byte_size);
    try std.testing.expectEqualStrings("/tmp/b.png", attachments[1].path);
    try std.testing.expectEqualStrings("", attachments[1].mime);
    // Absent and empty params stay empty for legacy image_paths-only clients.
    try std.testing.expectEqual(@as(usize, 0), (try jsonAttachmentArray(allocator, .null)).len);
    // A non-object entry is a malformed request, not a silent drop.
    const bad = try std.json.parseFromSlice(std.json.Value, allocator, "[\"/tmp/x.png\"]", .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidParams, jsonAttachmentArray(allocator, bad.value));

    // Stored columns → snapshot list: [primary] ++ extras, and a malformed
    // extras column degrades to primary-only instead of failing the read.
    const primary: store_protocol.Attachment = .{ .path = "/tmp/a.png", .mime = "image/png", .byte_size = 11 };
    const full = try decodeAttachmentList(arena, primary, "[{\"path\":\"/tmp/b.png\",\"mime\":\"\",\"byte_size\":22}]");
    try std.testing.expectEqual(@as(usize, 2), full.len);
    try std.testing.expectEqualStrings("/tmp/b.png", full[1].path);
    try std.testing.expectEqual(@as(usize, 22), full[1].byte_size);
    const degraded = try decodeAttachmentList(arena, primary, "not-json");
    try std.testing.expectEqual(@as(usize, 1), degraded.len);
    try std.testing.expectEqualStrings("/tmp/a.png", degraded[0].path);
    const no_primary = try decodeAttachmentList(arena, null, "[{\"path\":\"/tmp/b.png\"}]");
    try std.testing.expectEqual(@as(usize, 0), no_primary.len);
}

const ChatExecutionRoute = struct {
    project_path: []u8,
    cwd: ?[]u8,
    repository_id: []u8,
    relative_cwd: ?[]u8,

    fn deinit(self: *ChatExecutionRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.project_path);
        if (self.cwd) |value| allocator.free(value);
        allocator.free(self.repository_id);
        if (self.relative_cwd) |value| allocator.free(value);
        self.* = undefined;
    }
};

const ChatExecutionRouteError = error{
    InvalidParams,
    RouteAttachmentsUnsupported,
    CapabilityUnavailable,
    ResourceNotFound,
    StoreCorrupt,
    StoreUnavailable,
    OutOfMemory,
};

/// Resolve a client-controlled stable repository identity to this daemon's
/// exact runtime-local checkout. Route-mode callers cannot supply absolute
/// execution paths; legacy local callers retain their existing contract.
fn resolveChatExecutionRoute(
    daemon: *Daemon,
    params: std.json.Value,
) ChatExecutionRouteError!?ChatExecutionRoute {
    if (params != .object) return error.InvalidParams;
    const repository_value = params.object.get("repository_id") orelse {
        if (params.object.get("relative_cwd") != null) return error.InvalidParams;
        return null;
    };
    const repository_id = jsonString(repository_value) orelse return error.InvalidParams;
    if (params.object.get("project_path") != null or params.object.get("cwd") != null) {
        return error.InvalidParams;
    }
    if (try jsonArrayHasItems(params.object.get("image_paths")) or
        try jsonArrayHasItems(params.object.get("images")) or
        jsonValueIsPresent(params.object.get("image")))
    {
        return error.RouteAttachmentsUnsupported;
    }

    const workspace_id = jsonString(params.object.get("workspace_id") orelse .null) orelse
        return error.InvalidParams;
    const relative_cwd: ?[]const u8 = if (params.object.get("relative_cwd")) |value|
        switch (value) {
            .null => null,
            .string => |text| text,
            else => return error.InvalidParams,
        }
    else
        null;
    daemon_store.validateRepositoryRelativeCwd(relative_cwd) catch return error.InvalidParams;

    lockDaemon(daemon);
    const service = daemon.store_service;
    if (service) |svc| _ = svc.lifetime_pins.fetchAdd(1, .monotonic);
    daemon.mutex.unlock();
    const svc = service orelse return error.CapabilityUnavailable;
    defer _ = svc.lifetime_pins.fetchSub(1, .monotonic);

    var binding = blk: {
        lockStoreService(svc);
        defer svc.mutex.unlock();
        break :blk svc.store.loadWorkspaceRepositoryBinding(
            workspace_id,
            repository_id,
            daemon.runtime_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidParams => error.InvalidParams,
            error.ResourceNotFound => error.ResourceNotFound,
            error.CapabilityUnavailable => error.CapabilityUnavailable,
            error.StoreCorrupt,
            error.RuntimeIdentityMismatch,
            error.InvalidRuntimeIdentity,
            => error.StoreCorrupt,
            else => error.StoreUnavailable,
        };
    };
    defer binding.deinit(daemon.allocator);
    if (!std.mem.eql(u8, binding.availability, "available")) {
        return error.CapabilityUnavailable;
    }

    var threaded = std.Io.Threaded.init_single_threaded;
    const resolved = repository_path.resolveDirectoryAlloc(
        daemon.allocator,
        threaded.io(),
        binding.root_path,
        relative_cwd,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidRepositoryCwd => error.InvalidParams,
        error.InvalidRepositoryRoot => error.StoreCorrupt,
        error.RepositoryPathUnavailable => error.CapabilityUnavailable,
    };
    errdefer daemon.allocator.free(resolved);

    const owned_repository_id = daemon.allocator.dupe(u8, repository_id) catch return error.OutOfMemory;
    errdefer daemon.allocator.free(owned_repository_id);
    const owned_relative_cwd = if (relative_cwd) |value|
        daemon.allocator.dupe(u8, value) catch return error.OutOfMemory
    else
        null;
    errdefer if (owned_relative_cwd) |value| daemon.allocator.free(value);

    if (relative_cwd == null) {
        return .{
            .project_path = resolved,
            .cwd = null,
            .repository_id = owned_repository_id,
            .relative_cwd = null,
        };
    }
    const project_path = daemon.allocator.dupe(u8, binding.root_path) catch return error.OutOfMemory;
    return .{
        .project_path = project_path,
        .cwd = resolved,
        .repository_id = owned_repository_id,
        .relative_cwd = owned_relative_cwd,
    };
}

fn jsonArrayHasItems(value: ?std.json.Value) error{InvalidParams}!bool {
    const present = value orelse return false;
    return switch (present) {
        .null => false,
        .array => |array| array.items.len != 0,
        else => error.InvalidParams,
    };
}

fn jsonValueIsPresent(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return switch (present) {
        .null => false,
        else => true,
    };
}

test "repository-routed chat resolves only the daemon binding and persists the stable route" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/services/api");
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temporary_root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const repository_root = try std.fs.path.join(allocator, &.{ root_buffer[0..temporary_root_len], "repo" });
    defer allocator.free(repository_root);
    const expected_cwd = try std.fs.path.join(allocator, &.{ repository_root, "services/api" });
    defer allocator.free(expected_cwd);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const service = try allocator.create(StoreService);
    const store = daemon_store.Store.initWithRuntimeIdentity(allocator, db_path, .none, .{
        .runtime_id = daemon.runtime_id,
        .instance_id = daemon.instance_id,
    }) catch |err| {
        allocator.destroy(service);
        return err;
    };
    service.* = .{
        .store = store,
    };
    daemon.store_service = service;
    defer detachTestStoreService(&daemon);

    {
        lockStoreService(service);
        defer service.mutex.unlock();
        _ = try service.store.upsertWorkspace(.{
            .mutation = .{ .request_key = "route-workspace", .client_id = "route-test" },
            .workspace = .{
                .workspace_id = "route-workspace",
                .label = "Route workspace",
                .path = repository_root,
            },
        });
    }

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"turn_id":"route-turn","workspace_id":"route-workspace","local_thread_id":"route-thread","repository_id":"primary","relative_cwd":"services/api","provider":"codex","harness":"local_cli","prompt":"hello","image_paths":[],"images":[],"thread_title":"Routed","access_mode":"supervised","message_id":"route-message"}
    ,
        .{},
    );
    defer parsed.deinit();
    var route = (try resolveChatExecutionRoute(&daemon, parsed.value)).?;
    defer route.deinit(allocator);
    try std.testing.expectEqualStrings(repository_root, route.project_path);
    try std.testing.expectEqualStrings(expected_cwd, route.cwd.?);
    try std.testing.expectEqualStrings("primary", route.repository_id);
    try std.testing.expectEqualStrings("services/api", route.relative_cwd.?);

    const turn = try createChatTurnFromParams(allocator, parsed.value, &route);
    defer turn.deinit(allocator);
    try std.testing.expectEqualStrings(repository_root, turn.request.project_path);
    try std.testing.expectEqualStrings(expected_cwd, turn.request.cwd.?);
    try std.testing.expectEqual(AcceptanceOwnership.owned, try stageAcceptedChatTurn(&daemon, turn));

    {
        lockStoreService(service);
        defer service.mutex.unlock();
        var thread_row = (try service.store.conn.row(
            "select profile_id, runtime_id, repository_id, repository_cwd, cwd from threads where local_thread_id = ?1",
            .{"route-thread"},
        )).?;
        defer thread_row.deinit();
        try std.testing.expectEqualStrings("local", thread_row.text(0));
        try std.testing.expectEqualStrings(daemon.runtime_id, thread_row.text(1));
        try std.testing.expectEqualStrings("primary", thread_row.text(2));
        try std.testing.expectEqualStrings("services/api", thread_row.text(3));
        try std.testing.expect(thread_row.nullableText(4) == null);
    }

    const missing = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"workspace_id":"route-workspace","repository_id":"not-configured"}
    ,
        .{},
    );
    defer missing.deinit();
    try std.testing.expectError(error.ResourceNotFound, resolveChatExecutionRoute(&daemon, missing.value));

    {
        lockStoreService(service);
        defer service.mutex.unlock();
        _ = try service.store.upsertWorkspaceRepositoryBinding(.{
            .mutation = .{ .request_key = "route-binding-missing", .client_id = "route-test" },
            .workspace_id = "route-workspace",
            .repository_id = "primary",
            .binding = .{
                .runtime_id = daemon.runtime_id,
                .root_path = repository_root,
                .availability = "missing",
            },
        });
    }
    try std.testing.expectError(error.CapabilityUnavailable, resolveChatExecutionRoute(&daemon, parsed.value));
}

test "repository-routed chat rejects client paths attachments storeless use and orphan cwd" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const smuggled = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"workspace_id":"route-workspace","repository_id":"primary","project_path":"/client/path"}
    ,
        .{},
    );
    defer smuggled.deinit();
    try std.testing.expectError(error.InvalidParams, resolveChatExecutionRoute(&daemon, smuggled.value));

    const attached = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"workspace_id":"route-workspace","repository_id":"primary","image_paths":["/client/secret.png"]}
    ,
        .{},
    );
    defer attached.deinit();
    try std.testing.expectError(error.RouteAttachmentsUnsupported, resolveChatExecutionRoute(&daemon, attached.value));

    const orphan_cwd = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"workspace_id":"route-workspace","relative_cwd":"services/api"}
    ,
        .{},
    );
    defer orphan_cwd.deinit();
    try std.testing.expectError(error.InvalidParams, resolveChatExecutionRoute(&daemon, orphan_cwd.value));

    const no_store = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"workspace_id":"route-workspace","repository_id":"primary"}
    ,
        .{},
    );
    defer no_store.deinit();
    try std.testing.expectError(error.CapabilityUnavailable, resolveChatExecutionRoute(&daemon, no_store.value));
}

fn createChatTurnFromParams(
    allocator: std.mem.Allocator,
    params: std.json.Value,
    execution_route: ?*const ChatExecutionRoute,
) !*ChatTurn {
    const turn = try allocator.create(ChatTurn);
    errdefer allocator.destroy(turn);
    const image_paths = try jsonStringArray(allocator, params.object.get("image_paths") orelse .null);
    errdefer freeStringArray(allocator, image_paths);
    const owned_images = try jsonAttachmentArray(allocator, params.object.get("images") orelse .null);
    errdefer freeAttachmentArray(allocator, owned_images);
    const provider = parseEnum(harness.Provider, jsonString(params.object.get("provider") orelse .null) orelse return error.InvalidParams) orelse return error.InvalidParams;
    const harness_kind = parseEnum(harness.HarnessKind, jsonString(params.object.get("harness") orelse .null) orelse "local_cli") orelse return error.InvalidParams;
    const project_path = if (execution_route) |route|
        try allocator.dupe(u8, route.project_path)
    else
        try requiredDupe(allocator, params, "project_path");
    errdefer allocator.free(project_path);
    const prompt = try requiredDupe(allocator, params, "prompt");
    errdefer allocator.free(prompt);
    const provider_thread_id = try optionalDupe(allocator, params, "provider_thread_id");
    errdefer if (provider_thread_id) |value| allocator.free(value);
    const thread_title = try requiredDupe(allocator, params, "thread_title");
    errdefer allocator.free(thread_title);
    const model_ref = try optionalDupe(allocator, params, "model_ref");
    errdefer if (model_ref) |value| allocator.free(value);
    const opencode_reasoning_variant = try optionalDupe(allocator, params, "opencode_reasoning_variant");
    errdefer if (opencode_reasoning_variant) |value| allocator.free(value);
    const cursor_model_params_json = try optionalDupe(allocator, params, "cursor_model_params_json");
    errdefer if (cursor_model_params_json) |value| allocator.free(value);
    const cwd = if (execution_route) |route|
        if (route.cwd) |value| try allocator.dupe(u8, value) else null
    else
        try optionalDupe(allocator, params, "cwd");
    errdefer if (cwd) |value| allocator.free(value);
    const request: send_runner.Request = .{
        .provider = provider,
        .harness_kind = harness_kind,
        .project_path = project_path,
        .prompt = prompt,
        .image_paths = image_paths,
        .provider_thread_id = provider_thread_id,
        .thread_title = thread_title,
        .model_ref = model_ref,
        .reasoning_effort = if (jsonString(params.object.get("reasoning_effort") orelse .null)) |value| parseEnum(harness.ReasoningEffort, value) else null,
        .opencode_reasoning_variant = opencode_reasoning_variant,
        .cursor_model_params_json = cursor_model_params_json,
        .fast_mode = if (jsonBool(params.object.get("fast_mode") orelse .null) orelse false) .on else .off,
        .access_mode = parseAccessMode(jsonString(params.object.get("access_mode") orelse .null)),
        .cwd = cwd,
    };
    const user_message_id = try optionalDupe(allocator, params, "message_id");
    errdefer if (user_message_id) |value| allocator.free(value);
    const repository_id = if (execution_route) |route| try allocator.dupe(u8, route.repository_id) else null;
    errdefer if (repository_id) |value| allocator.free(value);
    const repository_cwd = if (execution_route) |route|
        if (route.relative_cwd) |value| try allocator.dupe(u8, value) else null
    else
        null;
    errdefer if (repository_cwd) |value| allocator.free(value);
    const owned_turn_id = try requiredDupe(allocator, params, "turn_id");
    errdefer allocator.free(owned_turn_id);
    const workspace_id = try requiredDupe(allocator, params, "workspace_id");
    errdefer allocator.free(workspace_id);
    const local_thread_id = try requiredDupe(allocator, params, "local_thread_id");
    errdefer allocator.free(local_thread_id);
    // MINOR-7: wire test_stub is only honored when the hermetic stub env is
    // also set, so a production client cannot force canned durable rows.
    // Env alone still enables the offline worker for hermetic ITs.
    const env_stub = chatStubEnabledFromEnv(allocator);
    const wire_stub = jsonBool(params.object.get("test_stub") orelse .null) orelse false;
    const use_stub = env_stub or (wire_stub and env_stub);
    turn.* = .{
        .allocator = allocator,
        .turn_id = owned_turn_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .repository_id = repository_id,
        .repository_cwd = repository_cwd,
        .request = request,
        .owned_image_paths = image_paths,
        .owned_images = owned_images,
        .started_at_ms = nowMs(),
        .user_message_id = user_message_id,
        .use_stub = use_stub,
    };
    return turn;
}

fn chatTitleProvider(provider: app_config.ChatTitleProvider) harness.Provider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .opencode => .opencode,
    };
}

fn boundedTitleUtf8Prefix(value: []const u8, max_len: usize) []const u8 {
    var end = @min(value.len, max_len);
    while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
    return value[0..end];
}

fn automaticTitleExpectedTitle(requested_title: []const u8, fallback_title: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, requested_title, fallback_title) or
        chat_threads.isPlaceholderThreadTitle(requested_title))
    {
        return requested_title;
    }
    return null;
}

/// Generate an opening-exchange title under the same durable identity guard
/// for GUI and headless turns. A manual rename changes the stored title away
/// from the accepted fallback/placeholder, so the terminal commit cannot
/// overwrite it.
fn maybeGenerateAutomaticChatTurnTitle(daemon: *Daemon, turn: *ChatTurn) void {
    if (turn.use_stub) return;

    lockTurn(turn);
    const completed = turn.status == .completed and turn.result_reply_text != null;
    const reply_text = turn.result_reply_text orelse "";
    turn.mutex.unlock();
    if (!completed) return;

    var config = app_config.loadAppConfig(daemon.allocator) catch |err| {
        log.warn("automatic chat title config load failed err={s}", .{@errorName(err)});
        return;
    };
    defer config.deinit(daemon.allocator);
    if (!config.automatic_chat_titles_enabled) return;

    const fallback_prompt = if (std.mem.trim(u8, turn.request.prompt, &std.ascii.whitespace).len > 0)
        turn.request.prompt
    else
        "Image";
    const fallback_title = chat_threads.makeThreadTitle(daemon.allocator, fallback_prompt) catch |err| {
        log.warn("automatic chat fallback title failed err={s}", .{@errorName(err)});
        return;
    };
    defer daemon.allocator.free(fallback_title);
    const expected_title = automaticTitleExpectedTitle(turn.request.thread_title, fallback_title) orelse return;

    lockDaemon(daemon);
    const service = daemon.store_service;
    if (service) |svc| _ = svc.in_flight.fetchAdd(1, .monotonic);
    daemon.mutex.unlock();
    const svc = service orelse return;
    defer _ = svc.in_flight.fetchSub(1, .monotonic);

    lockStoreService(svc);
    const eligible = svc.store.canGenerateAutomaticTitle(
        turn.workspace_id,
        turn.local_thread_id,
        expected_title,
    ) catch |err| blk: {
        log.warn("automatic chat title eligibility failed err={s}", .{@errorName(err)});
        break :blk false;
    };
    svc.mutex.unlock();
    if (!eligible) return;

    const user_text = if (std.mem.trim(u8, turn.request.prompt, &std.ascii.whitespace).len > 0)
        boundedTitleUtf8Prefix(turn.request.prompt, 4096)
    else
        "Image attachment";
    const title_prompt = chat_threads.makeTitleGenerationPrompt(
        daemon.allocator,
        user_text,
        boundedTitleUtf8Prefix(reply_text, 4096),
    ) catch |err| {
        log.warn("automatic chat title prompt failed err={s}", .{@errorName(err)});
        return;
    };
    defer daemon.allocator.free(title_prompt);

    const provider = chatTitleProvider(config.chat_title_provider);
    const result = send_runner.run(daemon.allocator, .{
        .provider = provider,
        .harness_kind = .local_cli,
        .project_path = turn.request.project_path,
        .cwd = turn.request.cwd,
        .prompt = title_prompt,
        .model_ref = config.chatTitleModel(),
        .fast_mode = if (provider == .codex) .on else .off,
        .access_mode = .supervised,
    }, .{}) catch |err| {
        log.warn("automatic chat title generation failed err={s}", .{@errorName(err)});
        return;
    };
    defer daemon.allocator.free(result.provider_thread_id);
    defer daemon.allocator.free(result.reply_text);

    const generated_title = chat_threads.makeGeneratedThreadTitle(daemon.allocator, result.reply_text) catch |err| {
        log.warn("automatic chat title normalization failed err={s}", .{@errorName(err)});
        return;
    } orelse {
        log.warn("automatic chat title provider returned an empty title", .{});
        return;
    };

    lockTurn(turn);
    if (turn.generated_title) |old| daemon.allocator.free(old);
    turn.generated_title = generated_title;
    turn.mutex.unlock();
}

test "automatic title eligibility accepts every empty-thread presentation label" {
    try std.testing.expectEqualStrings(
        "Opening prompt",
        automaticTitleExpectedTitle("Opening prompt", "Opening prompt").?,
    );
    try std.testing.expectEqualStrings(
        "New thread",
        automaticTitleExpectedTitle("New thread", "Opening prompt").?,
    );
    try std.testing.expectEqualStrings(
        "New Chat",
        automaticTitleExpectedTitle("New Chat", "Opening prompt").?,
    );
    try std.testing.expectEqualStrings(
        "New chat",
        automaticTitleExpectedTitle("New chat", "Opening prompt").?,
    );
    try std.testing.expect(automaticTitleExpectedTitle("My Manual Title", "Opening prompt") == null);
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
    const acceptance_ownership = stageAcceptedChatTurn(daemon, turn) catch |err| ownership: {
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
        break :ownership AcceptanceOwnership.owned;
    };
    if (staging_failed) {
        finalizeChatTurnWorker(daemon, turn);
        return;
    }
    if (acceptance_ownership == .conflict_not_owned) {
        // This retry never acquired the durable accepted work. Publish the
        // rejection only on its in-memory request; terminal durability belongs
        // to the first writer and must remain available to an exact retry.
        log.warn("chat turn acceptance conflict turn_id={s}", .{turn.turn_id});
        lockTurn(turn);
        turn.status = .failed;
        turn.durability_pending = false;
        if (turn.durability_error) |old| allocator.free(old);
        turn.durability_error = allocator.dupe(u8, "Conflict") catch null;
        if (turn.error_message) |old| allocator.free(old);
        turn.error_message = allocator.dupe(u8, "acceptance conflicts with durable first writer") catch null;
        turn.appendStringEvent(allocator, "failed", "message", turn.error_message orelse "acceptance conflict");
        turn.finished_at_ms = nowMs();
        turn.worker_done = true;
        turn.mutex.unlock();
        return;
    }
    if (turn.provider_invocation_count) |count| count.* += 1;
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

    maybeGenerateAutomaticChatTurnTitle(daemon, turn);
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
    // No-writer path publishes the terminal status via the pending flip;
    // commit path re-arms pending. Either way tail content changed.
    daemon.signalTurnEventWaiters();
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
            // durability_error is published tail content; deliver it.
            daemon.signalTurnEventWaiters();
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
        platform_runtime.sleepMillis(if (std.mem.indexOf(u8, prompt, "steer target") != null) 1_500 else 400);
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

/// Milliseconds from an unspecified monotonic origin. Deadline arithmetic
/// must use this rather than the wall-clock timestamp returned by `nowMs`.
pub fn monotonicNowMs() i64 {
    const milliseconds = platform_runtime.monotonicTimestampNs() / std.time.ns_per_ms;
    return @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
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

test "chat.followup resolves running turns daemon-side and rejects idle or unsupported threads" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const idle_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.followup","params":{"workspace_id":"followup-workspace","local_thread_id":"local-thread","prompt":"continue"}}
    );
    defer allocator.free(idle_response);
    var idle = try std.json.parseFromSlice(std.json.Value, allocator, idle_response, .{});
    defer idle.deinit();
    const idle_error = idle.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_state", idle_error.get("code").?.string);
    try std.testing.expectEqualStrings("thread has no running turn", idle_error.get("message").?.string);

    const turn = try appendTestChatTurn(
        &daemon,
        allocator,
        "followup-turn",
        "followup-workspace",
        "/tmp/followup",
        "Follow-up",
        "original",
        .running,
        1,
    );
    turn.request.provider = .opencode;
    const unsupported_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"chat.followup","params":{"workspace_id":"followup-workspace","local_thread_id":"local-thread","prompt":"continue"}}
    );
    defer allocator.free(unsupported_response);
    var unsupported = try std.json.parseFromSlice(std.json.Value, allocator, unsupported_response, .{});
    defer unsupported.deinit();
    const unsupported_error = unsupported.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_state", unsupported_error.get("code").?.string);
    try std.testing.expectEqualStrings("provider does not support daemon steering", unsupported_error.get("message").?.string);
}

test "Codex daemon steering uses provider identities and deduplicates ambiguous retry" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const turn = try appendTestChatTurn(
        &daemon,
        allocator,
        "steer-turn",
        "steer-workspace",
        "/tmp/steer",
        "Steering",
        "original slow prompt",
        .running,
        1,
    );
    turn.request.provider = .codex;
    turn.use_stub = true;
    var provider_calls: usize = 0;
    turn.provider_invocation_count = &provider_calls;
    turn.provider_thread_id = try allocator.dupe(u8, "provider-thread");
    turn.active_turn_id = try allocator.dupe(u8, "active-turn-42");
    var invocation: SteerInvocationCapture = .{};
    turn.steer_invocation_capture = &invocation;

    const accepted_request =
        \\{"jsonrpc":"2.0","id":1,"method":"chat.followup","params":{"workspace_id":"steer-workspace","local_thread_id":"local-thread","steer_id":"steer-stable-1","prompt":"change direction","image_paths":["/tmp/a.png"]}}
    ;
    const accepted_response = try daemon.handleRequest(accepted_request);
    defer allocator.free(accepted_response);
    var accepted = try std.json.parseFromSlice(std.json.Value, allocator, accepted_response, .{});
    defer accepted.deinit();
    const accepted_result = accepted.value.object.get("result").?.object;
    try std.testing.expect(accepted_result.get("accepted").?.bool);
    try std.testing.expectEqualStrings("steer-stable-1", accepted_result.get("steer_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), accepted_result.get("event_seq").?.integer);
    try std.testing.expect(!accepted_result.get("duplicate").?.bool);
    try std.testing.expectEqual(@as(usize, 1), provider_calls);
    try std.testing.expectEqual(harness.Provider.codex, invocation.provider.?);
    try std.testing.expectEqualStrings("provider-thread", invocation.capturedThreadId());
    try std.testing.expectEqualStrings("active-turn-42", invocation.capturedTurnId());
    try std.testing.expectEqual(@as(usize, 1), turn.events.items.len);
    try std.testing.expectEqualStrings("steer", turn.events.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, turn.events.items[0].payload_json, "Steering current turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn.events.items[0].payload_json, "/tmp/a.png") != null);

    // Simulates a lost first response: the caller repeats the same stable id.
    const retry_response = try daemon.handleRequest(accepted_request);
    defer allocator.free(retry_response);
    var retry = try std.json.parseFromSlice(std.json.Value, allocator, retry_response, .{});
    defer retry.deinit();
    try std.testing.expect(retry.value.object.get("result").?.object.get("duplicate").?.bool);
    try std.testing.expectEqual(@as(usize, 1), provider_calls);
    try std.testing.expectEqual(@as(usize, 1), turn.events.items.len);

    const conflict_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"chat.followup","params":{"workspace_id":"steer-workspace","local_thread_id":"local-thread","steer_id":"steer-stable-1","prompt":"different content"}}
    );
    defer allocator.free(conflict_response);
    var conflict = try std.json.parseFromSlice(std.json.Value, allocator, conflict_response, .{});
    defer conflict.deinit();
    try std.testing.expectEqualStrings("conflict", conflict.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 1), provider_calls);

    const rejected_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"chat.followup","params":{"workspace_id":"steer-workspace","local_thread_id":"local-thread","steer_id":"steer-rejected","prompt":"reject steer"}}
    );
    defer allocator.free(rejected_response);
    var rejected = try std.json.parseFromSlice(std.json.Value, allocator, rejected_response, .{});
    defer rejected.deinit();
    try std.testing.expectEqualStrings("invalid_state", rejected.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 2), provider_calls);
    try std.testing.expectEqual(@as(usize, 1), turn.events.items.len);
}

test "Codex daemon steering rejects a missing active turn identity without audit" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const turn = try appendTestChatTurn(
        &daemon,
        allocator,
        "steer-missing-active-turn",
        "steer-workspace",
        "/tmp/steer",
        "Steering",
        "original slow prompt",
        .running,
        1,
    );
    turn.request.provider = .codex;
    turn.use_stub = true;
    var provider_calls: usize = 0;
    turn.provider_invocation_count = &provider_calls;
    turn.provider_thread_id = try allocator.dupe(u8, "provider-thread");

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.followup","params":{"workspace_id":"steer-workspace","local_thread_id":"local-thread","steer_id":"missing-active","prompt":"change direction"}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_state", err.get("code").?.string);
    try std.testing.expectEqualStrings("Codex active turn is not ready", err.get("message").?.string);
    try std.testing.expectEqual(@as(usize, 0), provider_calls);
    try std.testing.expectEqual(@as(usize, 0), turn.steers.items.len);
    try std.testing.expectEqual(@as(usize, 0), turn.events.items.len);
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

test "provider.models.list validates params and reports unavailable providers" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const missing_provider = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"provider.models.list","params":{"project_path":"/tmp"}}
    );
    defer allocator.free(missing_provider);
    try std.testing.expect(std.mem.indexOf(u8, missing_provider, "invalid_params") != null);

    const unknown_provider = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"provider.models.list","params":{"provider":"nope","project_path":"/tmp"}}
    );
    defer allocator.free(unknown_provider);
    try std.testing.expect(std.mem.indexOf(u8, unknown_provider, "invalid_params") != null);

    // Codex has no discovery RPC: the handler must fail soft without
    // spawning provider processes so static fallbacks stay authoritative.
    const codex = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"provider.models.list","params":{"provider":"codex","project_path":"/tmp"}}
    );
    defer allocator.free(codex);
    try std.testing.expect(std.mem.indexOf(u8, codex, "provider_unavailable") != null);
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

test "prepareShutdown expected pid cannot drain a different endpoint owner" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.prepareShutdown","params":{"expected_pid":0}}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(!jsonBool(result.get("accepted") orelse .null).?);
    try std.testing.expect(!jsonBool(result.get("safe_to_exit") orelse .null).?);
    try std.testing.expect(jsonBool(result.get("owner_mismatch") orelse .null).?);
    try std.testing.expectEqual(@as(i64, @intCast(platform_runtime.processId())), result.get("pid").?.integer);
    try std.testing.expect(daemon.accepting_mutations);
    try std.testing.expect(!daemon.shutdown_requested);
}

test "prepareShutdown accepts the legacy empty tuple parameter shape" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    daemon.idle_exit_ms = null;

    const response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"daemon.prepareShutdown","params":[]}
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(jsonBool(result.get("accepted") orelse .null).?);
    try std.testing.expect(jsonBool(result.get("safe_to_exit") orelse .null).?);
    try std.testing.expect(!daemon.accepting_mutations);
    try std.testing.expect(daemon.shutdown_requested);
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
        "chat.turn.steer",
        "chat.followup",
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
        "workspace.repository.upsert",
        "workspace.repository.remove",
        "workspace.repository.default.set",
        "workspace.repository.binding.upsert",
        "workspace.repository.binding.remove",
        "chat.thread.upsert",
        "chat.draft.set",
        "chat.message.append",
        "surface.upsert",
        "surface.clear",
        "notification.chatCompletion.upsert",
        "notification.chatCompletion.clear",
        "config.favoriteModel.set",
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

test "repository manifest RPCs classify through the unlocked store queue" {
    const methods = [_][]const u8{
        "workspace.repository.manifest.get",
        "workspace.repository.upsert",
        "workspace.repository.remove",
        "workspace.repository.default.set",
        "workspace.repository.binding.upsert",
        "workspace.repository.binding.remove",
    };
    for (methods) |method| {
        const request = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{{}}}}",
            .{method},
        );
        defer std.testing.allocator.free(request);
        try std.testing.expectEqual(
            ServerRequestClass.store,
            try classifyServerRequest(std.testing.allocator, request),
        );
    }
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

fn testStoreWriteResult(
    daemon: *Daemon,
    allocator: std.mem.Allocator,
    request: []const u8,
) !store_protocol.WriteResult {
    const response = try daemon.handleRequest(request);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.TestExpectedStoreWrite;
    const store_revision = std.math.cast(u64, result.object.get("store_revision").?.integer) orelse
        return error.TestExpectedStoreWrite;
    return .{
        .store_revision = store_revision,
        .applied = result.object.get("applied").?.bool,
        .duplicate = result.object.get("duplicate").?.bool,
    };
}

fn expectRepositoryManifestAdvertisement(
    response: []const u8,
    allocator: std.mem.Allocator,
    expected: bool,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(
        expected,
        result.get("capabilities").?.object.get("repository_manifests").?.bool,
    );
    var found_runtime_capability = false;
    var found_route_capability = false;
    for (result.get("runtime_capabilities").?.array.items) |capability| {
        const name = jsonString(capability) orelse continue;
        if (std.mem.eql(u8, name, "repositories.manifest.v1")) {
            found_runtime_capability = true;
        } else if (std.mem.eql(u8, name, "chat.repository_route.v1")) {
            found_route_capability = true;
        }
    }
    try std.testing.expectEqual(expected, found_runtime_capability);
    try std.testing.expectEqual(expected, found_route_capability);
}

fn expectErrorCodeMessage(response: []const u8, allocator: std.mem.Allocator, code: []const u8, message: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const error_value = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(code, jsonString(error_value.get("code").?).?);
    try std.testing.expectEqualStrings(message, jsonString(error_value.get("message").?).?);
}

fn mismatchedTestIdentity(identity: []const u8) [32]u8 {
    std.debug.assert(identity.len == 32);
    var mismatched: [32]u8 = undefined;
    @memcpy(mismatched[0..], identity);
    mismatched[0] = if (mismatched[0] == '0') '1' else '0';
    return mismatched;
}

test "request target validation preserves local calls and accepts the exact daemon generation" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const local = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"core.status","params":{}}
    );
    defer allocator.free(local);
    var local_parsed = try std.json.parseFromSlice(std.json.Value, allocator, local, .{});
    defer local_parsed.deinit();
    try std.testing.expect(local_parsed.value.object.get("result") != null);

    const matching_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"core.status\",\"params\":{{}},\"target\":{{\"runtime_id\":\"{s}\",\"instance_id\":\"{s}\"}}}}",
        .{ daemon.runtime_id, daemon.instance_id },
    );
    defer allocator.free(matching_request);
    const matching = try daemon.handleRequest(matching_request);
    defer allocator.free(matching);
    var matching_parsed = try std.json.parseFromSlice(std.json.Value, allocator, matching, .{});
    defer matching_parsed.deinit();
    try std.testing.expect(matching_parsed.value.object.get("result") != null);

    const malformed_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"core.status\",\"params\":{{}},\"target\":{{\"runtime_id\":\"{s}\"}}}}",
        .{daemon.runtime_id},
    );
    defer allocator.free(malformed_request);
    const malformed = try daemon.handleRequest(malformed_request);
    defer allocator.free(malformed);
    try expectErrorCodeMessage(
        malformed,
        allocator,
        headless.protocol.ERR_RUNTIME_IDENTITY_MISSING,
        "request target is missing or malformed",
    );
}

test "wrong request targets cannot reach store mutation or slow process work" {
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

    const wrong_runtime = mismatchedTestIdentity(daemon.runtime_id);
    const before_revision = try daemon.store_service.?.store.storeRevision();
    const store_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace.upsert\",\"params\":{{\"mutation\":{{\"request_key\":\"target-ws\",\"client_id\":\"{s}\"}},\"workspace\":{{\"workspace_id\":\"target-ws\",\"label\":\"Target\",\"path\":\"/target\"}}}},\"target\":{{\"runtime_id\":\"{s}\",\"instance_id\":\"{s}\"}}}}",
        .{ client_id, &wrong_runtime, daemon.instance_id },
    );
    defer allocator.free(store_request);
    const store_response = try daemon.handleRequest(store_request);
    defer allocator.free(store_response);
    try expectErrorCodeMessage(
        store_response,
        allocator,
        headless.protocol.ERR_RUNTIME_IDENTITY_MISMATCH,
        "request target does not match this daemon",
    );
    try std.testing.expectEqual(before_revision, try daemon.store_service.?.store.storeRevision());
    try std.testing.expect(std.mem.indexOf(u8, store_response, daemon.runtime_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, store_response, daemon.instance_id) == null);

    const wrong_instance = mismatchedTestIdentity(daemon.instance_id);
    try std.testing.expect(daemon.registry.workspace("target-slow") == null);
    const slow_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"process.start\",\"params\":{{\"workspace\":{{\"workspace_id\":\"target-slow\"}},\"name\":\"worker\"}},\"target\":{{\"runtime_id\":\"{s}\",\"instance_id\":\"{s}\"}}}}",
        .{ daemon.runtime_id, &wrong_instance },
    );
    defer allocator.free(slow_request);
    const slow_response = try daemon.handleSlowRegistryRequest(allocator, slow_request);
    defer allocator.free(slow_response);
    try expectErrorCodeMessage(
        slow_response,
        allocator,
        headless.protocol.ERR_RUNTIME_IDENTITY_MISMATCH,
        "request target does not match this daemon",
    );
    try std.testing.expect(daemon.registry.workspace("target-slow") == null);
    try std.testing.expectEqual(@as(usize, 0), daemon.registry_jobs.len());
}

const WorkerDurableSnapshot = struct {
    revision: u64,
    owners: []u8,
    message: []u8,
    message_key: []u8,
    ledger: []u8,
    receipts: []u8,
    replay_guard: []u8,
    completions: i64,
    journal_cursor: u64,

    fn capture(allocator: std.mem.Allocator, daemon: *Daemon) !WorkerDurableSnapshot {
        const store = &daemon.store_service.?.store;
        const row = (try store.conn.row(
            "select (select store_revision from store_state where id = 1), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(w.workspace_id)||char(31)||quote(w.label)||char(31)||quote(w.path)||char(31)||quote(t.local_thread_id)||char(31)||quote(t.title)||char(31)||quote(t.provider_thread_id)||char(31)||t.provider||char(31)||t.harness v from workspaces w left join threads t on t.workspace_id=w.id order by w.workspace_id,t.local_thread_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(message_id)||char(31)||quote(role)||char(31)||quote(author)||char(31)||quote(body)||char(31)||quote(image_path)||char(31)||quote(image_mime)||char(31)||quote(image_byte_size)||char(31)||quote(created_at_ms)||char(31)||quote(updated_at_ms) v from messages order by thread_id,sort_index)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(message_id)||char(31)||quote(message_fingerprint)||char(31)||quote(sort_index)||char(31)||quote(created_at_ms)||char(31)||quote(updated_at_ms)||char(31)||quote(store_revision) v from client_message_keys order by thread_id,message_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(turn_id)||char(31)||quote(workspace_id)||char(31)||quote(local_thread_id)||char(31)||quote(status)||char(31)||quote(started_at_ms)||char(31)||quote(finished_at_ms)||char(31)||quote(provider)||char(31)||quote(provider_thread_id)||char(31)||quote(error_message)||char(31)||quote(user_message_id)||char(31)||quote(committed_store_revision) v from chat_turns order by turn_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(request_key)||char(31)||quote(operation)||char(31)||quote(fingerprint)||char(31)||quote(store_revision)||char(31)||quote(response_status)||char(31)||quote(response_payload) v from store_receipts order by request_key)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(turn_id)||char(31)||quote(status) v from terminal_turn_replay_guard order by turn_id)), ''), " ++
                "(select count(*) from chat_completions)",
            .{},
        )) orelse return error.StoreUnavailable;
        defer row.deinit();
        return .{
            .revision = @intCast(row.int(0)),
            .owners = try allocator.dupe(u8, row.text(1)),
            .message = try allocator.dupe(u8, row.text(2)),
            .message_key = try allocator.dupe(u8, row.text(3)),
            .ledger = try allocator.dupe(u8, row.text(4)),
            .receipts = try allocator.dupe(u8, row.text(5)),
            .replay_guard = try allocator.dupe(u8, row.text(6)),
            .completions = row.int(7),
            .journal_cursor = daemon.journal.last_seq,
        };
    }

    fn deinit(self: WorkerDurableSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.owners);
        allocator.free(self.message);
        allocator.free(self.message_key);
        allocator.free(self.ledger);
        allocator.free(self.receipts);
        allocator.free(self.replay_guard);
    }

    fn expectEqual(expected: WorkerDurableSnapshot, actual: WorkerDurableSnapshot) !void {
        try std.testing.expectEqual(expected.revision, actual.revision);
        try std.testing.expectEqualStrings(expected.owners, actual.owners);
        try std.testing.expectEqualStrings(expected.message, actual.message);
        try std.testing.expectEqualStrings(expected.message_key, actual.message_key);
        try std.testing.expectEqualStrings(expected.ledger, actual.ledger);
        try std.testing.expectEqualStrings(expected.receipts, actual.receipts);
        try std.testing.expectEqualStrings(expected.replay_guard, actual.replay_guard);
        try std.testing.expectEqual(expected.completions, actual.completions);
        try std.testing.expectEqual(expected.journal_cursor, actual.journal_cursor);
    }
};

fn appendAcceptanceWorkerTurn(
    daemon: *Daemon,
    turn_id: []const u8,
    prompt: []const u8,
    started_at_ms: i64,
    provider_thread_id: ?[]const u8,
    message_override: ?store_protocol.Message,
    provider_invocation_count: *usize,
) !*ChatTurn {
    const allocator = daemon.allocator;
    const turn = try allocator.create(ChatTurn);
    errdefer allocator.destroy(turn);
    const image_paths = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(image_paths);
    turn.* = .{
        .allocator = allocator,
        .turn_id = try allocator.dupe(u8, turn_id),
        .workspace_id = try allocator.dupe(u8, "ownership-workspace"),
        .local_thread_id = try allocator.dupe(u8, "ownership-thread"),
        .request = .{
            .provider = .codex,
            .harness_kind = .local_cli,
            .project_path = try allocator.dupe(u8, "/tmp/ownership-workspace"),
            .prompt = try allocator.dupe(u8, prompt),
            .image_paths = image_paths,
            .provider_thread_id = if (provider_thread_id) |value| try allocator.dupe(u8, value) else null,
            .thread_title = try allocator.dupe(u8, "Ownership thread"),
        },
        .owned_image_paths = image_paths,
        .started_at_ms = started_at_ms,
        .user_message_id = try allocator.dupe(u8, "ownership-user"),
        .use_stub = true,
        .acceptance_message_override = message_override,
        .provider_invocation_count = provider_invocation_count,
    };
    try daemon.chat_turns.append(allocator, turn);
    return turn;
}

fn seedLegacyAcceptanceWorker(store: *daemon_store.Store, turn_id: []const u8) !void {
    const workspace_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:stage-ws", .{turn_id});
    defer std.testing.allocator.free(workspace_key);
    const thread_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:stage-thread", .{turn_id});
    defer std.testing.allocator.free(thread_key);
    const user_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:stage-user", .{turn_id});
    defer std.testing.allocator.free(user_key);
    _ = try store.upsertWorkspace(.{
        .mutation = .{ .request_key = workspace_key, .client_id = "daemon" },
        .workspace = .{ .workspace_id = "ownership-workspace", .label = "ownership-workspace", .path = "/tmp/ownership-workspace" },
    });
    _ = try store.upsertThread(.{
        .mutation = .{ .request_key = thread_key, .client_id = "daemon" },
        .workspace_id = "ownership-workspace",
        .thread = .{ .local_thread_id = "ownership-thread", .title = "Ownership thread", .provider = "codex", .harness = "local_cli" },
    });
    _ = try store.appendMessage(.{
        .mutation = .{ .request_key = user_key, .client_id = "daemon" },
        .workspace_id = "ownership-workspace",
        .thread_id = "ownership-thread",
        .message = .{ .message_id = "ownership-user", .role = "user", .author = "You", .body = "original prompt", .created_at_ms = 10, .updated_at_ms = 10 },
    });
    try store.conn.exec(
        "insert into chat_turns (turn_id,workspace_id,local_thread_id,status,started_at_ms,provider,user_message_id) values (?1,'ownership-workspace','ownership-thread','running',10,'codex','ownership-user')",
        .{turn_id},
    );
    try sweepInterruptedChatTurns(store);
}

fn seedNewAcceptanceWorker(store: *daemon_store.Store, turn_id: []const u8) !void {
    const acceptance_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:accept", .{turn_id});
    defer std.testing.allocator.free(acceptance_key);
    _ = try store.acceptTurn(.{
        .mutation = .{ .request_key = acceptance_key, .client_id = "daemon" },
        .turn_id = turn_id,
        .workspace = .{ .workspace_id = "ownership-workspace", .label = "ownership-workspace", .path = "/tmp/ownership-workspace" },
        .thread = .{ .local_thread_id = "ownership-thread", .title = "Ownership thread", .provider = "codex", .harness = "local_cli", .provider_thread_id = "provider-new" },
        .started_at_ms = 10,
        .provider = "codex",
        .harness = "local_cli",
        .provider_thread_id = "provider-new",
        .user_message = .{ .message_id = "ownership-user", .role = "user", .author = "You", .body = "original prompt", .created_at_ms = 10, .updated_at_ms = 10 },
    });
    try sweepInterruptedChatTurns(store);
}

fn runAcceptanceOwnershipWorkerScenario(legacy: bool) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);
    const turn_id = if (legacy) "ownership-legacy-turn" else "ownership-new-turn";
    if (legacy) {
        try seedLegacyAcceptanceWorker(&daemon.store_service.?.store, turn_id);
    } else {
        try seedNewAcceptanceWorker(&daemon.store_service.?.store, turn_id);
    }
    daemon.store_service.?.store.commit_hook = .{
        .context = &daemon,
        .on_mutation_committed = storeMutationCommittedHook,
        .on_turn_committed = storeTurnCommittedHook,
        .on_acceptance_committed = storeAcceptanceCommittedHook,
    };

    const baseline = try WorkerDurableSnapshot.capture(allocator, &daemon);
    defer baseline.deinit(allocator);
    var provider_invocations: usize = 0;
    const attacks = [_]struct { prompt: []const u8, message: store_protocol.Message }{
        .{ .prompt = "original prompt", .message = .{ .message_id = "ownership-user", .role = "assistant", .author = "You", .body = "original prompt" } },
        .{ .prompt = "original prompt", .message = .{ .message_id = "ownership-user", .role = "user", .author = "Someone else", .body = "original prompt" } },
        .{ .prompt = "changed prompt", .message = .{ .message_id = "ownership-user", .role = "user", .author = "You", .body = "changed prompt" } },
        .{ .prompt = "original prompt", .message = .{ .message_id = "ownership-user", .role = "user", .author = "You", .body = "original prompt", .image = .{ .path = "/tmp/changed.png", .mime = "image/png", .byte_size = 17 } } },
    };
    for (attacks, 0..) |attack, index| {
        const turn = try appendAcceptanceWorkerTurn(
            &daemon,
            turn_id,
            attack.prompt,
            100 + @as(i64, @intCast(index)),
            if (legacy) "provider-legacy" else "provider-new",
            attack.message,
            &provider_invocations,
        );
        chatTurnThread(&daemon, turn);
        try std.testing.expectEqual(@as(usize, 0), provider_invocations);
        try std.testing.expectEqual(ChatTurnStatus.failed, turn.status);
        try std.testing.expect(turn.worker_done and !turn.durability_pending);
        try std.testing.expect(turn.committed_store_revision == null);
        const unchanged = try WorkerDurableSnapshot.capture(allocator, &daemon);
        defer unchanged.deinit(allocator);
        try baseline.expectEqual(unchanged);
    }

    const exact = try appendAcceptanceWorkerTurn(
        &daemon,
        turn_id,
        "original prompt",
        777,
        if (legacy) "provider-legacy" else "provider-new",
        null,
        &provider_invocations,
    );
    chatTurnThread(&daemon, exact);
    try std.testing.expectEqual(@as(usize, 1), provider_invocations);
    try std.testing.expectEqual(ChatTurnStatus.completed, exact.status);
    try std.testing.expect(exact.worker_done and !exact.durability_pending);
    try std.testing.expect(exact.committed_store_revision != null);
    const committed = try WorkerDurableSnapshot.capture(allocator, &daemon);
    defer committed.deinit(allocator);
    {
        const row = (try daemon.store_service.?.store.conn.row("select status from chat_turns where turn_id = ?1", .{turn_id})).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("completed", row.text(0));
    }
    try std.testing.expectEqual(if (legacy) @as(u64, 5) else @as(u64, 2), committed.revision);
    {
        const row = (try daemon.store_service.?.store.conn.row("select count(*) from store_receipts", .{})).?;
        defer row.deinit();
        try std.testing.expectEqual(if (legacy) @as(i64, 5) else @as(i64, 2), row.int(0));
    }
    try std.testing.expectEqual(@as(i64, 1), committed.completions);
    try std.testing.expect(committed.journal_cursor > baseline.journal_cursor);
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

    const manifest = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"workspace.repository.manifest.get","params":{"workspace_id":"w"}}
    );
    defer allocator.free(manifest);
    try expectErrorCodeMessage(manifest, allocator, headless.protocol.ERR_CAPABILITY_UNAVAILABLE, "store capability is unavailable");
}

test "store-less core advertisements withhold repository manifest support" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    inline for (.{ "core.status", "core.capabilities" }) |method| {
        const request = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{{}}}}",
            .{method},
        );
        defer allocator.free(request);
        const response = try daemon.handleRequest(request);
        defer allocator.free(response);
        try expectRepositoryManifestAdvertisement(response, allocator, false);
    }
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

test "repository manifest RPCs preserve legacy projection and receipt semantics" {
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

    inline for (.{ "core.status", "core.capabilities" }) |method| {
        const request = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{{}}}}",
            .{method},
        );
        defer allocator.free(request);
        const response = try daemon.handleRequest(request);
        defer allocator.free(response);
        try expectRepositoryManifestAdvertisement(response, allocator, true);
    }

    const workspace_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace.upsert\",\"params\":{{\"mutation\":{{\"request_key\":\"manifest-workspace\",\"client_id\":\"{s}\"}},\"workspace\":{{\"workspace_id\":\"manifest-ws\",\"label\":\"Legacy Workspace\",\"path\":\"/legacy/root\"}}}}}}",
        .{client_id},
    );
    defer allocator.free(workspace_request);
    _ = try testStoreWriteResult(&daemon, allocator, workspace_request);

    const legacy_response = try daemon.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace.repository.manifest.get\",\"params\":{\"workspace_id\":\"manifest-ws\"}}",
    );
    defer allocator.free(legacy_response);
    var legacy = try std.json.parseFromSlice(std.json.Value, allocator, legacy_response, .{});
    defer legacy.deinit();
    const legacy_result = legacy.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        store_protocol.PRIMARY_REPOSITORY_ID,
        jsonString(legacy_result.get("default_repository_id").?).?,
    );
    const legacy_repositories = legacy_result.get("repositories").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), legacy_repositories.len);
    try std.testing.expectEqualStrings(
        store_protocol.PRIMARY_REPOSITORY_ID,
        jsonString(legacy_repositories[0].object.get("repository_id").?).?,
    );
    const legacy_bindings = legacy_repositories[0].object.get("bindings").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), legacy_bindings.len);
    try std.testing.expectEqualStrings(
        "/legacy/root",
        jsonString(legacy_bindings[0].object.get("root_path").?).?,
    );

    const upsert_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace.repository.upsert\",\"params\":{{\"mutation\":{{\"request_key\":\"repo-upsert\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository\":{{\"repository_id\":\"repo-api\",\"label\":\"API\",\"vcs_identity\":\"git@example.com:org/api.git\",\"default_branch\":\"main\"}}}}}}",
        .{client_id},
    );
    defer allocator.free(upsert_request);
    const upserted = try testStoreWriteResult(&daemon, allocator, upsert_request);
    const replayed = try testStoreWriteResult(&daemon, allocator, upsert_request);
    try std.testing.expectEqual(upserted.store_revision, replayed.store_revision);
    try std.testing.expectEqual(upserted.applied, replayed.applied);

    const invalid_binding = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace.repository.binding.upsert\",\"params\":{{\"mutation\":{{\"request_key\":\"binding-invalid\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository_id\":\"repo-api\",\"binding\":{{\"runtime_id\":\"not-canonical\",\"root_path\":\"/srv/api\",\"availability\":\"available\"}}}}}}",
        .{client_id},
    );
    defer allocator.free(invalid_binding);
    const invalid_response = try daemon.handleRequest(invalid_binding);
    defer allocator.free(invalid_response);
    try expectErrorCodeMessage(
        invalid_response,
        allocator,
        headless.protocol.ERR_INVALID_PARAMS,
        "invalid params",
    );

    const binding_upsert = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"workspace.repository.binding.upsert\",\"params\":{{\"mutation\":{{\"request_key\":\"binding-upsert\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository_id\":\"repo-api\",\"binding\":{{\"runtime_id\":\"0123456789abcdef0123456789abcdef\",\"root_path\":\"/srv/api\",\"availability\":\"available\"}}}}}}",
        .{client_id},
    );
    defer allocator.free(binding_upsert);
    _ = try testStoreWriteResult(&daemon, allocator, binding_upsert);

    const default_api = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"workspace.repository.default.set\",\"params\":{{\"mutation\":{{\"request_key\":\"default-api\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository_id\":\"repo-api\"}}}}",
        .{client_id},
    );
    defer allocator.free(default_api);
    _ = try testStoreWriteResult(&daemon, allocator, default_api);

    const manifest_response = try daemon.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace.repository.manifest.get\",\"params\":{\"workspace_id\":\"manifest-ws\"}}",
    );
    defer allocator.free(manifest_response);
    var manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_response, .{});
    defer manifest.deinit();
    const manifest_result = manifest.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        "repo-api",
        jsonString(manifest_result.get("default_repository_id").?).?,
    );
    try std.testing.expectEqual(@as(usize, 2), manifest_result.get("repositories").?.array.items.len);
    var found_api = false;
    for (manifest_result.get("repositories").?.array.items) |repository_value| {
        const repository = repository_value.object;
        if (!std.mem.eql(u8, jsonString(repository.get("repository_id").?).?, "repo-api")) continue;
        found_api = true;
        try std.testing.expectEqualStrings("API", jsonString(repository.get("label").?).?);
        try std.testing.expectEqualStrings("main", jsonString(repository.get("default_branch").?).?);
        const bindings = repository.get("bindings").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), bindings.len);
        try std.testing.expectEqualStrings("/srv/api", jsonString(bindings[0].object.get("root_path").?).?);
    }
    try std.testing.expect(found_api);

    const binding_remove = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"workspace.repository.binding.remove\",\"params\":{{\"mutation\":{{\"request_key\":\"binding-remove\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository_id\":\"repo-api\",\"runtime_id\":\"0123456789abcdef0123456789abcdef\"}}}}",
        .{client_id},
    );
    defer allocator.free(binding_remove);
    _ = try testStoreWriteResult(&daemon, allocator, binding_remove);

    const default_primary = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"workspace.repository.default.set\",\"params\":{{\"mutation\":{{\"request_key\":\"default-primary\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository_id\":\"primary\"}}}}",
        .{client_id},
    );
    defer allocator.free(default_primary);
    _ = try testStoreWriteResult(&daemon, allocator, default_primary);

    const repository_remove = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"workspace.repository.remove\",\"params\":{{\"mutation\":{{\"request_key\":\"repo-remove\",\"client_id\":\"{s}\"}},\"workspace_id\":\"manifest-ws\",\"repository_id\":\"repo-api\"}}}}",
        .{client_id},
    );
    defer allocator.free(repository_remove);
    _ = try testStoreWriteResult(&daemon, allocator, repository_remove);

    const final_response = try daemon.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"workspace.repository.manifest.get\",\"params\":{\"workspace_id\":\"manifest-ws\"}}",
    );
    defer allocator.free(final_response);
    var final_manifest = try std.json.parseFromSlice(std.json.Value, allocator, final_response, .{});
    defer final_manifest.deinit();
    const final_result = final_manifest.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        store_protocol.PRIMARY_REPOSITORY_ID,
        jsonString(final_result.get("default_repository_id").?).?,
    );
    try std.testing.expectEqual(@as(usize, 1), final_result.get("repositories").?.array.items.len);
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

const FinalizeStoreThreadContext = struct {
    server: *SessionizerServerContext,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn finalizeStoreThread(context: *FinalizeStoreThreadContext) void {
    finalizeSessionizerStore(context.server);
    context.done.store(true, .release);
}

test "store finalization drains writes and reader lifetime pins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);

    lockDaemon(&daemon);
    const service = daemon.store_service.?;
    _ = service.in_flight.fetchAdd(1, .monotonic);
    _ = service.lifetime_pins.fetchAdd(1, .monotonic);
    daemon.mutex.unlock();
    var write_held = true;
    var pin_held = true;
    defer if (write_held) {
        _ = service.in_flight.fetchSub(1, .monotonic);
    };
    defer if (pin_held) {
        _ = service.lifetime_pins.fetchSub(1, .monotonic);
    };

    var stop = std.atomic.Value(bool).init(false);
    var server: SessionizerServerContext = .{
        .daemon = &daemon,
        .endpoint = "",
        .pid_path = "",
        .stop_requested = &stop,
    };
    var context: FinalizeStoreThreadContext = .{ .server = &server };
    const worker = try std.Thread.spawn(.{}, finalizeStoreThread, .{&context});
    var joined = false;
    defer if (!joined) {
        if (pin_held) {
            _ = service.lifetime_pins.fetchSub(1, .monotonic);
            pin_held = false;
        }
        if (write_held) {
            _ = service.in_flight.fetchSub(1, .monotonic);
            write_held = false;
        }
        worker.join();
    };

    var detached = false;
    var attempts: usize = 0;
    while (!detached and attempts < 200) : (attempts += 1) {
        lockDaemon(&daemon);
        detached = daemon.store_service == null;
        daemon.mutex.unlock();
        if (!detached) platform_runtime.sleepMillis(5);
    }
    try std.testing.expect(detached);
    try std.testing.expect(!context.done.load(.acquire));

    _ = service.lifetime_pins.fetchSub(1, .monotonic);
    pin_held = false;
    platform_runtime.sleepMillis(20);
    try std.testing.expect(!context.done.load(.acquire));

    _ = service.in_flight.fetchSub(1, .monotonic);
    write_held = false;
    worker.join();
    joined = true;
    try std.testing.expect(context.done.load(.acquire));
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

const DurableTailThreadContext = struct {
    daemon: *Daemon,
    response: ?[]u8 = null,
    err: ?anyerror = null,
};

fn durableTailThread(context: *DurableTailThreadContext) void {
    context.response = context.daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.turn.tail","params":{"turn_id":"missing-durable-turn","after_seq":0}}
    ) catch |err| {
        context.err = err;
        return;
    };
}

test "durable tail lifetime pin does not count as a prepare-shutdown write" {
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
    const service = daemon.store_service.?;

    lockStoreService(service);
    var store_locked = true;
    defer if (store_locked) service.mutex.unlock();
    var context: DurableTailThreadContext = .{ .daemon = &daemon };
    const worker = try std.Thread.spawn(.{}, durableTailThread, .{&context});
    var joined = false;
    defer if (!joined) {
        if (store_locked) {
            service.mutex.unlock();
            store_locked = false;
        }
        worker.join();
    };

    var attempts: usize = 0;
    while (service.lifetime_pins.load(.monotonic) == 0 and attempts < 200) : (attempts += 1) {
        platform_runtime.sleepMillis(5);
    }
    try std.testing.expectEqual(@as(usize, 1), service.lifetime_pins.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), service.in_flight.load(.monotonic));

    const prepare = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"daemon.prepareShutdown","params":{}}
    );
    defer allocator.free(prepare);
    var prepare_parsed = try std.json.parseFromSlice(std.json.Value, allocator, prepare, .{});
    defer prepare_parsed.deinit();
    try std.testing.expect(prepare_parsed.value.object.get("result").?.object.get("accepted").?.bool);

    service.mutex.unlock();
    store_locked = false;
    worker.join();
    joined = true;
    if (context.err) |err| return err;
    const response = context.response orelse return error.TestUnexpectedResult;
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("not_found", parsed.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 0), service.lifetime_pins.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), service.in_flight.load(.monotonic));
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

test "Linux session CLI path drops replaced executable suffix" {
    try std.testing.expectEqualStrings(
        "/opt/verde/bin/verde-daemon",
        executablePathWithoutDeletedSuffix(.linux, "/opt/verde/bin/verde-daemon (deleted)"),
    );
    try std.testing.expectEqualStrings(
        "/opt/verde/bin/verde-daemon",
        executablePathWithoutDeletedSuffix(.linux, "/opt/verde/bin/verde-daemon"),
    );
    try std.testing.expectEqualStrings(
        "/opt/verde/bin/verde-daemon (deleted)",
        executablePathWithoutDeletedSuffix(.macos, "/opt/verde/bin/verde-daemon (deleted)"),
    );
}

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
        .generated_title = try allocator.dupeZ(u8, "Generated Commit Title"),
        .user_message_id = try allocator.dupe(u8, "user-1"),
    };
    turn.appendStringEvent(allocator, "assistant_delta", "text", "reply");
    turn.appendEvent(allocator, "completed", "{}");
    // Owned by daemon.chat_turns (freed in daemon.deinit).
    try daemon.chat_turns.append(allocator, turn);

    try commitChatTurnDurable(&daemon, turn);
    try std.testing.expect(turn.committed_store_revision != null);
    try std.testing.expect(turn.generated_title_applied);
    try std.testing.expect(!turn.durability_pending);
    {
        lockStoreService(daemon.store_service.?);
        defer daemon.store_service.?.mutex.unlock();
        try std.testing.expect(try daemon.store_service.?.store.threadTitleEquals(
            "ws-commit",
            "t-commit",
            "Generated Commit Title",
        ));
    }
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

test "legacy interrupted acceptance conflict never terminalizes unowned work" {
    try runAcceptanceOwnershipWorkerScenario(true);
}

test "new interrupted acceptance conflict never terminalizes unowned work" {
    try runAcceptanceOwnershipWorkerScenario(false);
}

test "durable reads decode canonical and historical daemon chat role codes" {
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
    _ = try daemon.store_service.?.store.upsertWorkspace(.{
        .mutation = .{ .request_key = "dto-ws-2", .client_id = "daemon" },
        .workspace = .{ .workspace_id = "ws-dto-2", .label = "DTO 2", .path = "/tmp/dto-2" },
    });
    _ = try daemon.store_service.?.store.upsertThread(.{
        .mutation = .{ .request_key = "dto-thread", .client_id = "daemon" },
        .workspace_id = "ws-dto",
        .thread = .{
            .local_thread_id = "t-dto",
            .title = "DTO thread",
            .provider = "codex",
            .harness = "local_cli",
            .model_ref = "gpt-5.6-sol",
            .reasoning_effort = "low",
            .reasoning_variant = "none",
            .fast_mode = "on",
            .access_mode = "supervised",
            .draft = "staged DTO draft",
        },
    });
    _ = try daemon.store_service.?.store.upsertThread(.{
        .mutation = .{ .request_key = "dto-thread-2", .client_id = "daemon" },
        .workspace_id = "ws-dto",
        .thread = .{
            .local_thread_id = "t-dto-2",
            .title = "Second DTO thread",
            .provider = "claude",
            .harness = "local_cli",
        },
    });
    const thread_row = (try daemon.store_service.?.store.conn.row(
        "select id from threads where local_thread_id = ?1",
        .{"t-dto"},
    )).?;
    const thread_row_id = thread_row.int(0);
    thread_row.deinit();
    const raw_messages = [_]struct { role: i64, author: []const u8, body: []const u8 }{
        .{ .role = 0, .author = "You", .body = "raw user" },
        .{ .role = 1, .author = "Assistant", .body = "raw assistant" },
        .{ .role = 2, .author = "System", .body = "raw system" },
        .{ .role = 0, .author = "Ran command", .body = "legacy system" },
        .{ .role = 1, .author = "You", .body = "legacy user" },
        .{ .role = 2, .author = "Codex", .body = "legacy assistant" },
        .{ .role = 0, .author = "Codex", .body = "desktop assistant" },
        .{ .role = 1, .author = "Changed files", .body = "desktop system" },
        .{ .role = 2, .author = "You", .body = "desktop user" },
    };
    for (raw_messages, 0..) |message, index| {
        try daemon.store_service.?.store.conn.exec(
            "insert into messages (thread_id, sort_index, role, author, body, message_id) values (?1, ?2, ?3, ?4, ?5, ?6)",
            .{
                thread_row_id,
                @as(i64, @intCast(index)),
                message.role,
                message.author,
                message.body,
                message.body,
            },
        );
    }
    try daemon.store_service.?.store.conn.exec(
        "update messages set image_path = ?1, image_mime = ?2, image_byte_size = ?3, extra_images_json = ?4 where message_id = ?5",
        .{
            "/tmp/primary.png",
            "image/png",
            @as(i64, 101),
            "[{\"path\":\"/tmp/extra.webp\",\"mime\":\"image/webp\",\"byte_size\":202}]",
            "raw user",
        },
    );
    _ = try daemon.store_service.?.store.commitTurn(.{
        .turn_id = "turn-dto",
        .workspace_id = "ws-dto",
        .local_thread_id = "t-dto",
        .status = .completed,
        .started_at_ms = 1,
        .finished_at_ms = 2,
        .provider = "codex",
        .messages = &.{},
    });
    daemon.store_service.?.mutex.unlock();

    const get_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.thread.get","params":{"workspace_id":"ws-dto","local_thread_id":"t-dto"}}
    );
    defer allocator.free(get_response);
    var get_parsed = try std.json.parseFromSlice(std.json.Value, allocator, get_response, .{});
    defer get_parsed.deinit();
    const thread = get_parsed.value.object.get("result").?.object.get("thread").?.object;
    try std.testing.expectEqualStrings("t-dto", thread.get("local_thread_id").?.string);
    try std.testing.expectEqualStrings("staged DTO draft", thread.get("draft").?.string);
    try std.testing.expectEqualStrings("gpt-5.6-sol", thread.get("model_ref").?.string);
    try std.testing.expectEqualStrings("low", thread.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("none", thread.get("reasoning_variant").?.string);
    try std.testing.expectEqualStrings("on", thread.get("fast_mode").?.string);
    try std.testing.expectEqualStrings("supervised", thread.get("access_mode").?.string);
    const messages = thread.get("messages").?.array.items;
    const expected_roles = [_][]const u8{
        "user",      "assistant", "system",
        "system",    "user",      "assistant",
        "assistant", "system",    "user",
    };
    try std.testing.expectEqual(expected_roles.len, messages.len);
    for (messages, expected_roles) |message, expected_role| {
        try std.testing.expectEqualStrings(expected_role, message.object.get("role").?.string);
    }
    const primary_image = messages[0].object.get("image").?.object;
    try std.testing.expectEqualStrings("/tmp/primary.png", primary_image.get("path").?.string);
    try std.testing.expectEqualStrings("image/png", primary_image.get("mime").?.string);
    try std.testing.expectEqual(@as(i64, 101), primary_image.get("byte_size").?.integer);
    const message_images = messages[0].object.get("images").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), message_images.len);
    try std.testing.expectEqualStrings("/tmp/primary.png", message_images[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("/tmp/extra.webp", message_images[1].object.get("path").?.string);
    try std.testing.expectEqualStrings("image/webp", message_images[1].object.get("mime").?.string);
    try std.testing.expectEqual(@as(i64, 202), message_images[1].object.get("byte_size").?.integer);

    var snapshot_arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer snapshot_arena_state.deinit();
    lockStoreService(daemon.store_service.?);
    const durable_snapshot = loadStoreSnapshotTxn(
        snapshot_arena_state.allocator(),
        &daemon.store_service.?.store,
        "ws-dto",
        true,
        false,
    ) catch |err| {
        daemon.store_service.?.mutex.unlock();
        return err;
    };
    daemon.store_service.?.mutex.unlock();
    const snapshot_messages = durable_snapshot.snapshot.workspaces[0].threads[0].messages;
    try std.testing.expectEqual(expected_roles.len, snapshot_messages.len);
    for (snapshot_messages, expected_roles) |message, expected_role| {
        try std.testing.expectEqualStrings(expected_role, message.role);
    }

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
    var list_parsed = try std.json.parseFromSlice(std.json.Value, allocator, list_response, .{});
    defer list_parsed.deinit();
    const listed_thread = list_parsed.value.object.get("result").?.object.get("threads").?.array.items[0].object;
    try std.testing.expectEqualStrings("t-dto", listed_thread.get("local_thread_id").?.string);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed_thread.get("model_ref").?.string);
    try std.testing.expectEqualStrings("low", listed_thread.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("none", listed_thread.get("reasoning_variant").?.string);
    try std.testing.expectEqualStrings("on", listed_thread.get("fast_mode").?.string);
    try std.testing.expectEqualStrings("supervised", listed_thread.get("access_mode").?.string);

    const first_thread_page_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"chat.thread.list","params":{"workspace_id":"ws-dto","limit":1}}
    );
    defer allocator.free(first_thread_page_response);
    var first_thread_page = try std.json.parseFromSlice(std.json.Value, allocator, first_thread_page_response, .{});
    defer first_thread_page.deinit();
    const first_thread_result = first_thread_page.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 1), first_thread_result.get("threads").?.array.items.len);
    const first_thread_cursor = first_thread_result.get("next_cursor").?.string;
    const first_thread_revision = std.math.cast(u64, first_thread_result.get("store_revision").?.integer) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(first_thread_cursor.len <= store_protocol.MAX_PAGE_CURSOR_BYTES);
    try std.testing.expectEqual(
        @as(usize, 1),
        try headless.pagination.decode(first_thread_cursor, .thread, first_thread_revision, "ws-dto"),
    );

    const second_thread_page_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"chat.thread.list\",\"params\":{{\"workspace_id\":\"ws-dto\",\"limit\":1,\"cursor\":\"{s}\"}}}}",
        .{first_thread_cursor},
    );
    defer allocator.free(second_thread_page_request);
    const second_thread_page_response = try daemon.handleRequest(second_thread_page_request);
    defer allocator.free(second_thread_page_response);
    var second_thread_page = try std.json.parseFromSlice(std.json.Value, allocator, second_thread_page_response, .{});
    defer second_thread_page.deinit();
    const second_thread_result = second_thread_page.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        "t-dto-2",
        second_thread_result.get("threads").?.array.items[0].object.get("local_thread_id").?.string,
    );
    try std.testing.expect(second_thread_result.get("next_cursor").? == .null);

    const workspace_page_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":6,"method":"workspace.list","params":{"limit":1}}
    );
    defer allocator.free(workspace_page_response);
    var workspace_page = try std.json.parseFromSlice(std.json.Value, allocator, workspace_page_response, .{});
    defer workspace_page.deinit();
    const workspace_result = workspace_page.value.object.get("result").?.object;
    const workspace_item = workspace_result.get("workspaces").?.array.items[0].object;
    try std.testing.expectEqualStrings("primary", workspace_item.get("default_repository_id").?.string);
    const primary_repository = workspace_item.get("repositories").?.array.items[0].object;
    try std.testing.expectEqualStrings("primary", primary_repository.get("repository_id").?.string);
    const primary_binding = primary_repository.get("bindings").?.array.items[0].object;
    try std.testing.expectEqualStrings(daemon.runtime_id, primary_binding.get("runtime_id").?.string);
    try std.testing.expectEqualStrings("/tmp/dto", primary_binding.get("root_path").?.string);
    const workspace_cursor = workspace_result.get("next_cursor").?.string;
    const workspace_revision = std.math.cast(u64, workspace_result.get("store_revision").?.integer) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        try headless.pagination.decode(workspace_cursor, .workspace, workspace_revision, "active"),
    );

    const mismatched_workspace_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":61,\"method\":\"workspace.list\",\"params\":{{\"limit\":1,\"include_archived\":true,\"cursor\":\"{s}\"}}}}",
        .{workspace_cursor},
    );
    defer allocator.free(mismatched_workspace_request);
    const mismatched_workspace_response = try daemon.handleRequest(mismatched_workspace_request);
    defer allocator.free(mismatched_workspace_response);
    try expectErrorCodeMessage(
        mismatched_workspace_response,
        allocator,
        headless.protocol.ERR_INVALID_PARAMS,
        "page cursor does not match this query; restart pagination without a cursor",
    );

    {
        lockStoreService(daemon.store_service.?);
        defer daemon.store_service.?.mutex.unlock();
        _ = try daemon.store_service.?.store.upsertThread(.{
            .mutation = .{ .request_key = "dto-thread-cursor-stale", .client_id = "daemon" },
            .workspace_id = "ws-dto",
            .thread = .{
                .local_thread_id = "t-dto-cursor-stale",
                .title = "Cursor invalidation",
                .provider = "codex",
                .harness = "local_cli",
            },
        });
    }

    const stale_thread_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":62,\"method\":\"chat.thread.list\",\"params\":{{\"workspace_id\":\"ws-dto\",\"limit\":1,\"cursor\":\"{s}\"}}}}",
        .{first_thread_cursor},
    );
    defer allocator.free(stale_thread_request);
    const stale_thread_response = try daemon.handleRequest(stale_thread_request);
    defer allocator.free(stale_thread_response);
    try expectErrorCodeMessage(
        stale_thread_response,
        allocator,
        headless.protocol.ERR_REVISION_EXPIRED,
        "page cursor is stale; restart pagination without a cursor",
    );

    const stale_workspace_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":63,\"method\":\"workspace.list\",\"params\":{{\"limit\":1,\"cursor\":\"{s}\"}}}}",
        .{workspace_cursor},
    );
    defer allocator.free(stale_workspace_request);
    const stale_workspace_response = try daemon.handleRequest(stale_workspace_request);
    defer allocator.free(stale_workspace_response);
    try expectErrorCodeMessage(
        stale_workspace_response,
        allocator,
        headless.protocol.ERR_REVISION_EXPIRED,
        "page cursor is stale; restart pagination without a cursor",
    );

    const legacy_cursor_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":64,"method":"workspace.list","params":{"limit":1,"cursor":"o:1"}}
    );
    defer allocator.free(legacy_cursor_response);
    try expectErrorCodeMessage(
        legacy_cursor_response,
        allocator,
        headless.protocol.ERR_INVALID_PARAMS,
        "invalid page cursor; restart pagination without a cursor",
    );

    const backward_page_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":7,"method":"chat.message.list","params":{"workspace_id":"ws-dto","local_thread_id":"t-dto","limit":3}}
    );
    defer allocator.free(backward_page_response);
    var backward_page = try std.json.parseFromSlice(std.json.Value, allocator, backward_page_response, .{});
    defer backward_page.deinit();
    const backward_result = backward_page.value.object.get("result").?.object;
    const backward_messages = backward_result.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), backward_messages.len);
    try std.testing.expectEqual(@as(i64, 6), backward_messages[0].object.get("sort_index").?.integer);
    try std.testing.expectEqual(@as(i64, 8), backward_messages[2].object.get("sort_index").?.integer);
    try std.testing.expectEqualStrings("b:6", backward_result.get("next_cursor").?.string);

    const forward_page_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":8,"method":"chat.message.list","params":{"workspace_id":"ws-dto","local_thread_id":"t-dto","direction":"forward","limit":2}}
    );
    defer allocator.free(forward_page_response);
    var forward_page = try std.json.parseFromSlice(std.json.Value, allocator, forward_page_response, .{});
    defer forward_page.deinit();
    const forward_result = forward_page.value.object.get("result").?.object;
    const forward_messages = forward_result.get("messages").?.array.items;
    try std.testing.expectEqual(@as(i64, 0), forward_messages[0].object.get("sort_index").?.integer);
    try std.testing.expectEqual(@as(i64, 1), forward_messages[1].object.get("sort_index").?.integer);
    try std.testing.expectEqualStrings("f:1", forward_result.get("next_cursor").?.string);

    const oversized_page_response = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":9,"method":"chat.message.list","params":{"workspace_id":"ws-dto","local_thread_id":"t-dto","limit":201}}
    );
    defer allocator.free(oversized_page_response);
    try expectErrorCodeMessage(oversized_page_response, allocator, headless.protocol.ERR_INVALID_PARAMS, "invalid params");
}

test "chat turn tail pages large replay before publishing terminal status" {
    const allocator = std.testing.allocator;
    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    const turn = try appendTestChatTurn(&daemon, allocator, "tail-paged", "ws-tail", "/tmp/tail", "Tail", "prompt", .completed, 1);
    turn.committed_store_revision = 7;
    turn.result_reply_text = try allocator.dupe(u8, "done");

    const payload = try allocator.alloc(u8, 9000);
    defer allocator.free(payload);
    @memset(payload, 'x');
    const payload_prefix = "{\"text\":\"";
    @memcpy(payload[0..payload_prefix.len], payload_prefix);
    payload[payload.len - 2] = '"';
    payload[payload.len - 1] = '}';
    turn.appendEvent(allocator, "tool_call", payload);
    turn.appendEvent(allocator, "diff", payload);

    const first = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.turn.tail","params":{"turn_id":"tail-paged","after_seq":0,"max_bytes":16000}}
    );
    defer allocator.free(first);
    try std.testing.expect(first.len <= 16000);
    var first_parsed = try std.json.parseFromSlice(std.json.Value, allocator, first, .{});
    defer first_parsed.deinit();
    const first_result = first_parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("running", first_result.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), first_result.get("events").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), first_result.get("page_last_seq").?.integer);
    try std.testing.expect(first_result.get("has_more_events").?.bool);
    try std.testing.expect(first_result.get("result_reply_text").? == .null);

    const second = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"chat.turn.tail","params":{"turn_id":"tail-paged","after_seq":1,"max_bytes":16000}}
    );
    defer allocator.free(second);
    try std.testing.expect(second.len <= 16000);
    var second_parsed = try std.json.parseFromSlice(std.json.Value, allocator, second, .{});
    defer second_parsed.deinit();
    const second_result = second_parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("completed", second_result.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), second_result.get("events").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), second_result.get("page_last_seq").?.integer);
    try std.testing.expect(!second_result.get("has_more_events").?.bool);
    try std.testing.expectEqualStrings("done", second_result.get("result_reply_text").?.string);
}

test "chat turn tail falls back to durable terminal record after consume" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testStoreDbPath(&tmp);
    defer allocator.free(db_path);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    try attachTestStoreService(&daemon, db_path);
    defer detachTestStoreService(&daemon);

    const turn = try appendTestChatTurn(&daemon, allocator, "tail-durable", "ws-tail", "/tmp/tail", "Tail", "prompt", .completed, 1);
    lockStoreService(daemon.store_service.?);
    _ = try daemon.store_service.?.store.upsertWorkspace(.{
        .mutation = .{ .request_key = "tail-ws", .client_id = "daemon" },
        .workspace = .{ .workspace_id = "ws-tail", .label = "Tail", .path = "/tmp/tail" },
    });
    _ = try daemon.store_service.?.store.upsertThread(.{
        .mutation = .{ .request_key = "tail-thread", .client_id = "daemon" },
        .workspace_id = "ws-tail",
        .thread = .{ .local_thread_id = turn.local_thread_id, .title = "Tail", .provider = "codex", .harness = "local_cli" },
    });
    const committed = try daemon.store_service.?.store.commitTurn(.{
        .turn_id = "tail-durable",
        .workspace_id = "ws-tail",
        .local_thread_id = turn.local_thread_id,
        .status = .completed,
        .started_at_ms = 1,
        .finished_at_ms = 2,
        .provider = "codex",
        .provider_thread_id = "provider-tail",
        .messages = &.{},
    });
    daemon.store_service.?.mutex.unlock();
    turn.committed_store_revision = committed.store_revision;

    const consume = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"chat.turn.consume","params":{"turn_id":"tail-durable"}}
    );
    defer allocator.free(consume);
    try std.testing.expectEqual(@as(usize, 0), daemon.chat_turns.items.len);

    const tail = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"chat.turn.tail","params":{"turn_id":"tail-durable","after_seq":0}}
    );
    defer allocator.free(tail);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tail, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("completed", result.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 0), result.get("events").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), result.get("next_seq").?.integer);
    try std.testing.expectEqualStrings("provider-tail", result.get("provider_thread_id").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(committed.store_revision)), result.get("committed_store_revision").?.integer);
    try std.testing.expect(!result.get("durability_pending").?.bool);

    const unknown = try daemon.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"chat.turn.tail","params":{"turn_id":"tail-unknown"}}
    );
    defer allocator.free(unknown);
    var unknown_parsed = try std.json.parseFromSlice(std.json.Value, allocator, unknown, .{});
    defer unknown_parsed.deinit();
    try std.testing.expectEqualStrings("not_found", unknown_parsed.value.object.get("error").?.object.get("code").?.string);
}

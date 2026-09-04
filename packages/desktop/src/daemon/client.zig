//! Lightweight client transport for the persistent Verde daemon.
//!
//! Keep this module free of daemon stores, provider implementations, and PTY
//! ownership so desktop UI code can issue RPCs without compiling the server.

const std = @import("std");
const builtin = @import("builtin");
const headless = @import("headless");
const mcp_endpoint = @import("../mcp/endpoint.zig");
const platform_ipc = @import("../platform/ipc.zig");
const process_env = @import("../platform/env.zig");
const platform_runtime = @import("platform_runtime");

const log = std.log.scoped(.daemon_client);

pub const SOCKET_NAME = "verde-sessionizer.sock";
pub const LIVE_SOCKET_NAME = "verde.sock";
pub const WINDOWS_PIPE_PREFIX = "\\\\.\\pipe\\verde-sessionizer-";
pub const SESSIONIZER_SOCKET_ENV_NAME = "VERDE_SESSIONIZER_SOCKET";
pub const SESSION_DAEMON_STORE_DIR_ENV_NAME = "VERDE_SESSION_DAEMON_STORE_DIR";
pub const PROTOCOL_VERSION = headless.session_protocol.PROTOCOL_VERSION;
pub const DEFAULT_COLS = headless.session_protocol.DEFAULT_COLS;
pub const DEFAULT_ROWS = headless.session_protocol.DEFAULT_ROWS;
pub const stableSessionId = headless.session_protocol.stableSessionId;

const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_RESPONSE_BYTES: usize = MAX_MESSAGE_BYTES;
const REQUEST_TIMEOUT_MS: u32 = 5_000;
const SUBMIT_PROBE_TIMEOUT_MS: u32 = 250;
const REPLACEMENT_WAIT_MS: i64 = 5 * std.time.ms_per_s;
const REPLACEMENT_GONE_GRACE_MS: i64 = 1 * std.time.ms_per_s;
const REPLACEMENT_POLL_MS: i64 = 50;
const REPLACEMENT_BIND_WAIT_MS: i64 = 1 * std.time.ms_per_s;
const LEGACY_TERMINATION_GRACE_MS: i64 = 500;

pub fn socketPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (try endpointOverrideAlloc(allocator)) |override| return override;
    return defaultSocketPath(allocator, pref_path);
}

pub fn defaultSocketPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return windowsPipeName(allocator, pref_path);
    return std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
}

fn endpointOverrideAlloc(allocator: std.mem.Allocator) !?[]u8 {
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

pub const HeadlessTransport = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    timeout_ms: u32 = REQUEST_TIMEOUT_MS,

    pub fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *HeadlessTransport = @ptrCast(@alignCast(ctx));
        return sendRequestJsonAllocWithTimeout(
            self.allocator,
            self.pref_path,
            request_json,
            self.timeout_ms,
        );
    }
};

pub fn headlessClient(allocator: std.mem.Allocator, transport: *HeadlessTransport) headless.Client {
    return headless.Client.init(allocator, transport, HeadlessTransport.send);
}

pub fn sendRequestJsonAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    request_json: []const u8,
) ![]u8 {
    return sendRequestJsonAllocWithTimeout(allocator, pref_path, request_json, REQUEST_TIMEOUT_MS);
}

pub fn sendRequestJsonAllocWithTimeout(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    request_json: []const u8,
    timeout_ms: u32,
) ![]u8 {
    std.debug.assert(timeout_ms > 0);
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    return platform_ipc.requestAlloc(allocator, endpoint, request_json, .{
        .max_message_bytes = MAX_MESSAGE_BYTES,
        .max_response_bytes = MAX_MESSAGE_BYTES,
        .timeout_ms = timeout_ms,
    });
}

pub fn requestAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
) ![]u8 {
    return requestAllocMaxResponse(allocator, pref_path, method, params, request_id, MAX_MESSAGE_BYTES);
}

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

pub fn requestAllocMaxResponse(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
    max_response_bytes: usize,
) ![]u8 {
    std.debug.assert(max_response_bytes > 0 and max_response_bytes <= MAX_MESSAGE_BYTES);
    const result = try requestWithPeerAlloc(
        allocator,
        pref_path,
        method,
        params,
        request_id,
        max_response_bytes,
    );
    return result.response;
}

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
        std.debug.assert(response_buffer.len > 0 and response_buffer.len <= MAX_MESSAGE_BYTES);
        return requestAllocMaxResponse(allocator, pref_path, method, params, request_id, response_buffer.len);
    }
};

const RequestResult = struct {
    response: []u8,
    authenticated_server_process_id: ?u32 = null,
};

const PeerTransport = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    max_response_bytes: usize,
    timeout_ms: u32 = REQUEST_TIMEOUT_MS,
    authenticated_server_process_id: ?u32 = null,

    fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *PeerTransport = @ptrCast(@alignCast(ctx));
        const endpoint = try socketPath(self.allocator, self.pref_path);
        defer self.allocator.free(endpoint);
        const result = try platform_ipc.requestWithPeerAlloc(self.allocator, endpoint, request_json, .{
            .max_message_bytes = MAX_MESSAGE_BYTES,
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
) !RequestResult {
    var transport: PeerTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .max_response_bytes = max_response_bytes,
    };
    var client = headless.Client.init(allocator, &transport, PeerTransport.send);
    var call = try client.callAllocWithId(request_id, method, params);
    const response = call.takeResponse();
    call.deinit(allocator);
    return .{
        .response = response,
        .authenticated_server_process_id = transport.authenticated_server_process_id,
    };
}

const DaemonStatus = struct {
    protocol_version: u32,
    pid: ?usize = null,
    session_count: ?usize = null,
    chat_turn_count: ?usize = null,
    running_session_count: ?usize = null,
    keep_alive_turn_count: ?usize = null,
};

const PrepareShutdownResult = struct {
    accepted: bool,
    safe_to_exit: bool,
    running_sessions: usize,
    keep_alive_turns: usize,
    method_missing: bool = false,
};

fn parseDaemonStatus(allocator: std.mem.Allocator, response: []const u8) ?DaemonStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    return .{
        .protocol_version = jsonU32(result.object.get("protocol_version") orelse .null) orelse return null,
        .pid = jsonUsize(result.object.get("pid") orelse .null),
        .session_count = jsonUsize(result.object.get("session_count") orelse .null),
        .chat_turn_count = jsonUsize(result.object.get("chat_turn_count") orelse .null),
        .running_session_count = jsonUsize(result.object.get("running_session_count") orelse .null),
        .keep_alive_turn_count = jsonUsize(result.object.get("keep_alive_turn_count") orelse .null),
    };
}

fn parsePrepareShutdownResult(allocator: std.mem.Allocator, response: []const u8) ?PrepareShutdownResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("error")) |err_value| {
        if (err_value != .object) return null;
        const code = jsonString(err_value.object.get("code") orelse .null) orelse return null;
        if (std.mem.eql(u8, code, "method_not_found")) return .{
            .accepted = false,
            .safe_to_exit = false,
            .running_sessions = 0,
            .keep_alive_turns = 0,
            .method_missing = true,
        };
        if (!std.mem.eql(u8, code, headless.registry.ERR_INVALID_STATE)) return null;
        const data = err_value.object.get("data") orelse return null;
        if (data != .object) return null;
        return .{
            .accepted = false,
            .safe_to_exit = false,
            .running_sessions = jsonUsize(data.object.get("running_sessions") orelse .null) orelse 0,
            .keep_alive_turns = jsonUsize(data.object.get("turns") orelse .null) orelse 0,
        };
    }
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    return .{
        .accepted = jsonBool(result.object.get("accepted") orelse .null) orelse false,
        .safe_to_exit = jsonBool(result.object.get("safe_to_exit") orelse .null) orelse false,
        .running_sessions = jsonUsize(result.object.get("running_sessions") orelse .null) orelse 0,
        .keep_alive_turns = jsonUsize(result.object.get("keep_alive_turns") orelse .null) orelse 0,
    };
}

pub fn ensureDaemon(allocator: std.mem.Allocator, pref_path: []const u8, exe_path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var replacement_requested = false;

    if (requestWithPeerAlloc(allocator, pref_path, "status", .{}, 0, MAX_MESSAGE_BYTES)) |result| {
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
    log.warn("session daemon unavailable after {d} status attempts last_probe_error={s}", .{ attempts, @errorName(last_probe_error) });
    return error.SessionDaemonUnavailable;
}

pub fn ensureDaemonInteractive(allocator: std.mem.Allocator, pref_path: []const u8, exe_path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const budget_deadline_ms = nowMs() + SUBMIT_PROBE_TIMEOUT_MS;

    if (statusProbeAlloc(allocator, pref_path, SUBMIT_PROBE_TIMEOUT_MS)) |response| {
        defer allocator.free(response);
        if (parseDaemonStatus(allocator, response)) |status| {
            if (status.protocol_version == PROTOCOL_VERSION) return;
            return ensureDaemon(allocator, pref_path, exe_path);
        }
        return;
    } else |err| switch (err) {
        error.ConnectionTimedOut => return,
        else => {},
    }

    try spawnDaemon(allocator, exe_path);
    while (nowMs() <= budget_deadline_ms) {
        if (statusProbeAlloc(allocator, pref_path, SUBMIT_PROBE_TIMEOUT_MS)) |response| {
            defer allocator.free(response);
            if (parseDaemonStatus(allocator, response)) |status| {
                if (status.protocol_version == PROTOCOL_VERSION) return;
            }
        } else |_| {}
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    return error.SessionDaemonStarting;
}

fn statusProbeAlloc(allocator: std.mem.Allocator, pref_path: []const u8, timeout_ms: u32) ![]u8 {
    var transport: PeerTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .max_response_bytes = MAX_MESSAGE_BYTES,
        .timeout_ms = timeout_ms,
    };
    var client = headless.Client.init(allocator, &transport, PeerTransport.send);
    var call = try client.callAllocWithId(0, "status", .{});
    const response = call.takeResponse();
    call.deinit(allocator);
    return response;
}

fn replaceIncompatibleDaemon(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    io: std.Io,
    status: DaemonStatus,
    authenticated_server_process_id: ?u32,
) !void {
    const deadline_ms = nowMs() + REPLACEMENT_WAIT_MS;
    var saw_method = false;
    var last_running_sessions = status.running_session_count orelse status.session_count orelse 0;
    var last_keep_alive_turns = status.keep_alive_turn_count orelse status.chat_turn_count orelse 0;

    while (nowMs() <= deadline_ms) {
        if (requestAlloc(allocator, pref_path, "daemon.prepareShutdown", .{}, 0)) |response| {
            defer allocator.free(response);
            if (parsePrepareShutdownResult(allocator, response)) |prepared| {
                if (prepared.method_missing) {
                    try terminateLegacyDaemon(allocator, pref_path, status, authenticated_server_process_id, io);
                    return;
                }
                saw_method = true;
                last_running_sessions = prepared.running_sessions;
                last_keep_alive_turns = prepared.keep_alive_turns;
                if (prepared.accepted and prepared.safe_to_exit) {
                    if (waitForDaemonGone(allocator, pref_path, io, nowMs() + REPLACEMENT_GONE_GRACE_MS)) return;
                    return error.DaemonReplacementTimeout;
                }
            }
        } else |err| {
            if (isEndpointGoneError(err)) return;
        }
        std.Io.sleep(io, .fromMilliseconds(REPLACEMENT_POLL_MS), .awake) catch {};
    }
    if (!saw_method) {
        try terminateLegacyDaemon(allocator, pref_path, status, authenticated_server_process_id, io);
        return;
    }
    log.warn(
        "session daemon replacement blocked live_sessions={d} keep_alive_turns={d} protocol={d}",
        .{ last_running_sessions, last_keep_alive_turns, status.protocol_version },
    );
    return error.DaemonReplacementBlocked;
}

fn terminateLegacyDaemon(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    status: DaemonStatus,
    authenticated_server_process_id: ?u32,
    io: std.Io,
) !void {
    if (daemonProcessIdForReplacement(status.pid, authenticated_server_process_id)) |pid| terminateDaemonProcess(pid);
    if (waitForDaemonGone(allocator, pref_path, io, nowMs() + LEGACY_TERMINATION_GRACE_MS)) return;
    if (builtin.os.tag != .windows) {
        if (daemonProcessIdForReplacement(status.pid, authenticated_server_process_id)) |pid| {
            if (legacyPidStillOwnsEndpoint(allocator, pref_path, pid)) {
                forceTerminateDaemonProcess(pid);
                if (waitForDaemonGone(allocator, pref_path, io, nowMs() + REPLACEMENT_GONE_GRACE_MS)) return;
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

fn isEndpointGoneError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.FileNotFound => true,
        else => false,
    };
}

fn waitForDaemonGone(allocator: std.mem.Allocator, pref_path: []const u8, io: std.Io, deadline_ms: i64) bool {
    while (nowMs() <= deadline_ms) {
        if (requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
        } else |err| {
            if (isEndpointGoneError(err)) return true;
        }
        std.Io.sleep(io, .fromMilliseconds(REPLACEMENT_POLL_MS), .awake) catch {};
    }
    return false;
}

fn daemonProcessIdForReplacement(reported_process_id: ?usize, authenticated_server_process_id: ?u32) ?usize {
    if (builtin.os.tag == .windows) {
        return if (authenticated_server_process_id) |process_id| @as(usize, process_id) else null;
    }
    return reported_process_id;
}

pub fn spawnDaemon(allocator: std.mem.Allocator, exe_path: []const u8) !void {
    const daemon_exe = try daemonExecutablePath(allocator, exe_path);
    defer allocator.free(daemon_exe);
    if (builtin.os.tag == .windows) return spawnWindowsDaemon(allocator, daemon_exe);

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
    const command_line = try windowsCreateCommandLine(allocator, &.{ daemon_exe, "__session-daemon" });
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
    windows.CloseHandle(process_info.hThread);
    windows.CloseHandle(process_info.hProcess);
}

fn windowsCreateCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    const writer = &buffer.writer;
    for (argv, 0..) |arg, arg_index| {
        if (arg_index > 0) try writer.writeByte(' ');
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try writer.writeAll(arg);
            continue;
        }
        try writer.writeByte('"');
        var backslashes: usize = 0;
        for (arg) |byte| switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try writer.splatByteAll('\\', backslashes * 2 + 1);
                try writer.writeByte('"');
                backslashes = 0;
            },
            else => {
                try writer.splatByteAll('\\', backslashes);
                try writer.writeByte(byte);
                backslashes = 0;
            },
        };
        try writer.splatByteAll('\\', backslashes * 2);
        try writer.writeByte('"');
    }
    return buffer.toOwnedSliceSentinel(0);
}

pub fn daemonExecutablePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, exe_path, "/\\") != null or (exe_path.len >= 2 and exe_path[1] == ':')) {
        return siblingDaemonPathAlloc(allocator, exe_path);
    }
    return resolveDaemonOnPathAlloc(allocator);
}

fn siblingDaemonPathAlloc(allocator: std.mem.Allocator, executable: []const u8) ![]u8 {
    const executable_dir = if (builtin.os.tag == .windows)
        std.fs.path.dirnameWindows(executable)
    else
        std.fs.path.dirnamePosix(executable) orelse std.fs.path.dirname(executable);
    const directory = executable_dir orelse return resolveDaemonOnPathAlloc(allocator);
    const daemon_name = if (builtin.os.tag == .windows) "verde-daemon.exe" else "verde-daemon";
    const direct = if (builtin.os.tag == .windows)
        try std.fs.path.resolveWindows(allocator, &.{ directory, daemon_name })
    else
        try std.fs.path.join(allocator, &.{ directory, daemon_name });

    if (builtin.os.tag != .windows or executableExists(direct)) return direct;
    defer allocator.free(direct);
    // Assembled Windows archives place app/Verde.exe beside bin/verde-daemon.exe.
    const packaged = try std.fs.path.resolveWindows(allocator, &.{ directory, "..", "bin", daemon_name });
    if (executableExists(packaged)) return packaged;
    allocator.free(packaged);
    return resolveDaemonOnPathAlloc(allocator);
}

fn resolveDaemonOnPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const daemon_name = if (builtin.os.tag == .windows) "verde-daemon.exe" else "verde-daemon";
    if (builtin.os.tag == .windows) {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        defer env_map.deinit();
        return process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, daemon_name) catch
            allocator.dupe(u8, daemon_name);
    }
    const path_ptr = std.c.getenv("PATH") orelse return allocator.dupe(u8, daemon_name);
    var iterator = std.mem.splitScalar(u8, std.mem.span(path_ptr), ':');
    while (iterator.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, daemon_name });
        defer allocator.free(candidate);
        const candidate_z = try allocator.dupeZ(u8, candidate);
        defer allocator.free(candidate_z);
        if (std.c.access(candidate_z.ptr, std.c.X_OK) == 0) return allocator.dupe(u8, candidate);
    }
    return allocator.dupe(u8, daemon_name);
}

fn executableExists(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        var threaded = std.Io.Threaded.init_single_threaded;
        std.Io.Dir.accessAbsolute(threaded.io(), path, .{}) catch return false;
        return true;
    }
    const path_z = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(path_z);
    return std.c.access(path_z.ptr, std.c.X_OK) == 0;
}

fn terminateDaemonProcess(pid: usize) void {
    if (builtin.os.tag == .windows) {
        _ = terminateWindowsProcess(@intCast(pid));
        return;
    }
    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
}

fn forceTerminateDaemonProcess(pid: usize) void {
    if (builtin.os.tag == .windows) {
        _ = terminateWindowsProcess(@intCast(pid));
        return;
    }
    std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
}

fn terminateWindowsProcess(pid: u32) bool {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const windows = std.os.windows;
    const process = OpenProcess(0x00100001, .FALSE, pid) orelse return false;
    defer windows.CloseHandle(process);
    if (TerminateProcess(process, 1) == .FALSE) return false;
    _ = WaitForSingleObject(process, 2_000);
    return true;
}

pub fn mcpTokenZAlloc(allocator: std.mem.Allocator, pref_path: []const u8) !?[:0]u8 {
    if (pref_path.len == 0) return null;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var endpoint = try mcp_endpoint.load(allocator, threaded.io(), pref_path) orelse return null;
    defer endpoint.deinit(allocator);
    return @as(?[:0]u8, try allocator.dupeSentinel(u8, endpoint.token, 0));
}

pub const EffectiveStoreDirectory = struct {
    path: []u8,
    overridden: bool,
};

pub fn effectiveStoreDirectoryFromRaw(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    raw_override: ?[]const u8,
) !EffectiveStoreDirectory {
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

pub fn nowMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub fn monotonicNowMs() i64 {
    const milliseconds = platform_runtime.monotonicTimestampNs() / std.time.ns_per_ms;
    return @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonU32(value: std.json.Value) ?u32 {
    const integer = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (integer < 0 or integer > std.math.maxInt(u32)) return null;
    return @intCast(integer);
}

fn jsonUsize(value: std.json.Value) ?usize {
    const integer = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (integer < 0) return null;
    return std.math.cast(usize, integer);
}

fn jsonBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

const windows_api = if (builtin.os.tag == .windows) std.os.windows else struct {
    pub const HANDLE = *anyopaque;
    pub const BOOL = enum(i32) { FALSE = 0, TRUE = 1 };
    pub const DWORD = u32;
    pub const UINT = u32;
};
extern "kernel32" fn TerminateProcess(process: windows_api.HANDLE, exit_code: windows_api.UINT) callconv(.winapi) windows_api.BOOL;
extern "kernel32" fn OpenProcess(desired_access: windows_api.DWORD, inherit_handle: windows_api.BOOL, process_id: windows_api.DWORD) callconv(.winapi) ?windows_api.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows_api.HANDLE, milliseconds: windows_api.DWORD) callconv(.winapi) windows_api.DWORD;

test "effective store directory preserves override parsing semantics" {
    const result = try effectiveStoreDirectoryFromRaw(std.testing.allocator, "/pref", "  /store  ");
    defer std.testing.allocator.free(result.path);
    try std.testing.expect(result.overridden);
    try std.testing.expectEqualStrings("/store", result.path);
}

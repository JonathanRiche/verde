//! Verde-native terminal session identity and daemon protocol helpers.
//!
//! This module is intentionally separate from `terminal.zig`: terminal UI code
//! can import these small types while the long-lived PTY owner and CLI attach
//! behavior grow here instead of being buried in the renderer/pane code.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("../harness.zig");
const platform_ipc = @import("../platform/ipc.zig");
const platform_live_endpoint = @import("../platform/live_endpoint.zig");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../process_env.zig");
const send_runner = @import("../chat/send_runner.zig");
const windows_conpty = @import("platform/windows_conpty.zig");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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
pub const PROTOCOL_VERSION: u32 = 9;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 30;
const MAX_OUTPUT_RING: usize = 1024 * 1024;
const DAEMON_POLL_READ_BUDGET: usize = 64 * 1024;
const SESSIONIZER_MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
const SESSIONIZER_REQUEST_TIMEOUT_MS: u32 = 5000;
const ATTACH_STALE_MS: i64 = 60 * std.time.ms_per_s;
const IDLE_EXIT_MS: i64 = 30 * std.time.ms_per_s;
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
    "session.screen",
    "session.kill",
    "session.cleanup",
};

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

pub fn socketPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return windowsPipeName(allocator, pref_path);
    return std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
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
    const result = try requestWithPeerAlloc(allocator, pref_path, method, params, request_id);
    return result.response;
}

const RequestResult = struct {
    response: []u8,
    authenticated_server_process_id: ?u32 = null,
};

fn requestWithPeerAlloc(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    method: []const u8,
    params: anytype,
    request_id: u64,
) !RequestResult {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const socket_path = try socketPath(allocator, pref_path);
    defer allocator.free(socket_path);

    var request_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer request_writer.deinit();
    var s: std.json.Stringify = .{ .writer = &request_writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(request_id);
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.write(params);
    try s.endObject();
    const request_json = try request_writer.toOwnedSlice();
    defer allocator.free(request_json);

    if (builtin.os.tag == .windows) {
        const result = try platform_ipc.requestWithPeerAlloc(allocator, socket_path, request_json, .{
            .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
            .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
            .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
        });
        return .{
            .response = result.response,
            .authenticated_server_process_id = result.server_process_id,
        };
    }

    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request_json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    const read_buffer = try allocator.alloc(u8, 8 * 1024 * 1024);
    defer allocator.free(read_buffer);
    var reader = stream.reader(io, read_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.ConnectionAborted;
    return .{ .response = try allocator.dupe(u8, std.mem.trim(u8, line, "\r")) };
}
const DaemonStatus = struct {
    protocol_version: u32,
    pid: ?usize = null,
};

fn parseDaemonStatus(allocator: std.mem.Allocator, response: []const u8) ?DaemonStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const protocol_version = jsonU32(result.object.get("protocol_version") orelse .null) orelse return null;
    const pid = jsonUsize(result.object.get("pid") orelse .null);
    return .{ .protocol_version = protocol_version, .pid = pid };
}

pub fn ensureDaemon(allocator: std.mem.Allocator, pref_path: []const u8, exe_path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    if (requestWithPeerAlloc(allocator, pref_path, "status", .{}, 0)) |result| {
        defer allocator.free(result.response);
        if (parseDaemonStatus(allocator, result.response)) |status| {
            if (status.protocol_version == PROTOCOL_VERSION) return;
            if (daemonProcessIdForReplacement(builtin.os.tag, status.pid, result.authenticated_server_process_id)) |pid| {
                terminateDaemonProcess(pid);
                std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            }
        }
    } else |_| {}

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
        if (self.running) std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
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
        std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch return false;
        self.running = false;
        _ = self.captureExitStatus();
        return true;
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
        self.running = false;
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
        self.running = self.backend.isRunning();
        self.exit_status = self.backend.exitStatus();
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

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(*PtySession) = .empty,
    chat_turns: std.ArrayList(*ChatTurn) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    idle_since_ms: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator) Daemon {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Daemon) void {
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.chat_turns.items) |turn| turn.deinit(self.allocator);
        self.chat_turns.deinit(self.allocator);
    }

    fn pollSessions(self: *Daemon) void {
        const now = nowMs();
        for (self.sessions.items) |session| {
            session.poll(self.allocator) catch {};
            session.cleanupStaleAttaches(self.allocator, now);
        }
    }

    fn shouldExitForIdle(self: *Daemon) bool {
        self.removeFinishedConsumedChatTurns();
        for (self.sessions.items) |session| {
            if (session.running) {
                self.idle_since_ms = null;
                return false;
            }
        }
        for (self.chat_turns.items) |turn| {
            lockTurn(turn);
            const keep_alive = chatTurnKeepsDaemonAlive(turn.status, turn.consumed, turn.worker_done);
            turn.mutex.unlock();
            if (keep_alive) {
                self.idle_since_ms = null;
                return false;
            }
        }
        const now = nowMs();
        if (self.idle_since_ms == null) {
            self.idle_since_ms = now;
            return false;
        }
        return now - self.idle_since_ms.? >= IDLE_EXIT_MS;
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

        if (std.mem.eql(u8, method, "session.list")) return try self.listResponse(id_value);
        if (std.mem.eql(u8, method, "session.inspect")) return try self.inspectResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.create")) return try self.createResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.attach")) return try self.attachResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.detach")) return try self.detachResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.write")) return try self.writeResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.resize")) return try self.resizeResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.tail")) return try self.tailResponse(id_value, params, false);
        if (std.mem.eql(u8, method, "session.screen")) return try self.tailResponse(id_value, params, true);
        if (std.mem.eql(u8, method, "session.kill")) return try self.killResponse(id_value, params);
        if (std.mem.eql(u8, method, "session.cleanup")) return try self.cleanupResponse(id_value);
        if (std.mem.eql(u8, method, "chat.turn.start")) return try self.chatTurnStartResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.list")) return try self.chatTurnListResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.tail")) return try self.chatTurnTailResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.approve")) return try self.chatTurnApproveResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.cancel")) return try self.chatTurnCancelResponse(id_value, params);
        if (std.mem.eql(u8, method, "chat.turn.consume")) return try self.chatTurnConsumeResponse(id_value, params);
        if (std.mem.eql(u8, method, "status")) return try self.statusResponse(id_value);
        return try errorResponseAlloc(self.allocator, id_value, "method_not_found", method);
    }

    fn statusResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        return try okValueResponse(self.allocator, id_value, .{
            .protocol_version = PROTOCOL_VERSION,
            .pid = platform_runtime.processId(),
            .session_count = self.sessions.items.len,
            .idle_exit_ms = IDLE_EXIT_MS,
        });
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
        touchAttachFromParams(session, params);
        try session.poll(self.allocator);
        const lines = jsonU32(params.object.get("lines") orelse .null) orelse if (screen) DEFAULT_ROWS else 80;
        const start_offset = jsonUsize(params.object.get("offset") orelse .null);
        const max_bytes = jsonUsize(params.object.get("max_bytes") orelse .null);
        const text_range = if (start_offset) |offset|
            bytesRangeFromOffset(session.output_ring.items, session.ringIndexForOffset(@intCast(offset)), max_bytes)
        else
            bytesRangeForTailLines(session.output_ring.items, lines, max_bytes);
        const text = try self.allocator.dupe(u8, session.output_ring.items[text_range.start..text_range.end]);
        defer self.allocator.free(text);
        const ring_start = session.ringStart();
        return try okValueResponse(self.allocator, id_value, .{
            .id = session.session_id,
            .running = session.running,
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
        for (self.sessions.items, 0..) |session, index| {
            if (!std.mem.eql(u8, session.session_id, wanted_id)) continue;
            const signaled = session.terminate();
            self.removeAt(index);
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
        thread.detach();
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
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        lockTurn(turn);
        defer turn.mutex.unlock();
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

pub fn runDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    try process_env.applyAugmentedPathToCurrentProcess(allocator);
    if (builtin.os.tag == .windows) return runWindowsDaemon(allocator, pref_path);
    return runUnixDaemon(allocator, pref_path);
}

fn runUnixDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    var setup_threaded = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().createDirPath(setup_threaded.io(), pref_path);
    const socket_path = try socketPath(allocator, pref_path);
    defer allocator.free(socket_path);
    const pid_path = try pidFilePath(allocator, pref_path);
    defer allocator.free(pid_path);
    deleteSocketPath(socket_path);
    try writePidFile(pid_path);
    defer deleteSocketPath(socket_path);
    defer {
        var cleanup_threaded = std.Io.Threaded.init_single_threaded;
        deleteFilePath(cleanup_threaded.io(), pid_path);
    }

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const drain_thread = try std.Thread.spawn(.{}, drainSessionsThread, .{DrainThreadContext{
        .daemon = &daemon,
        .socket_path = socket_path,
        .pid_path = pid_path,
    }});
    drain_thread.detach();

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleClient(&daemon, io, stream);
    }
}

fn runWindowsDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
    var setup_threaded = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().createDirPath(setup_threaded.io(), pref_path);
    const endpoint = try socketPath(allocator, pref_path);
    defer allocator.free(endpoint);
    const pid_path = try pidFilePath(allocator, pref_path);
    defer allocator.free(pid_path);
    try writePidFile(pid_path);
    defer {
        var cleanup_threaded = std.Io.Threaded.init_single_threaded;
        deleteFilePath(cleanup_threaded.io(), pid_path);
    }

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();
    const drain_thread = try std.Thread.spawn(.{}, drainSessionsThread, .{DrainThreadContext{
        .daemon = &daemon,
        .socket_path = endpoint,
        .pid_path = pid_path,
    }});
    drain_thread.detach();

    var server_context: SessionizerServerContext = .{ .daemon = &daemon };
    try platform_ipc.serve(allocator, endpoint, .{
        .context = &server_context,
        .should_stop = sessionizerServerShouldStop,
        .handle_request = handleSessionizerServerRequest,
    }, .{
        .max_message_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .max_response_bytes = SESSIONIZER_MAX_MESSAGE_BYTES,
        .timeout_ms = SESSIONIZER_REQUEST_TIMEOUT_MS,
    });
}

const SessionizerServerContext = struct {
    daemon: *Daemon,
};

fn sessionizerServerShouldStop(_: *anyopaque) bool {
    return false;
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
    socket_path: []const u8,
    pid_path: []const u8,
};

fn drainSessionsThread(context: DrainThreadContext) void {
    while (true) {
        const daemon = context.daemon;
        lockDaemon(daemon);
        daemon.pollSessions();
        const should_exit = daemon.shouldExitForIdle();
        daemon.mutex.unlock();
        if (should_exit) {
            deleteSocketPath(context.socket_path);
            var cleanup_threaded = std.Io.Threaded.init_single_threaded;
            deleteFilePath(cleanup_threaded.io(), context.pid_path);
            harness.shutdownOwnedProviderProcesses();
            std.process.exit(0);
        }
        sleepMs(20);
    }
}

fn handleClient(daemon: *Daemon, io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiter('\n') catch return orelse return;

    var locked = true;
    lockDaemon(daemon);
    const response_json = daemon.handleRequest(std.mem.trim(u8, line, "\r")) catch |err| blk: {
        daemon.mutex.unlock();
        locked = false;
        break :blk errorResponseAlloc(daemon.allocator, .null, "internal_error", @errorName(err)) catch return;
    };
    if (locked) daemon.mutex.unlock();
    defer daemon.allocator.free(response_json);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(response_json) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
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
        .diff => turn.appendEvent(allocator, "diff", "{}"),
    }
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
    try std.testing.expect(!initial.running);

    const replacement_response = try daemon.handleRequest(request);
    defer allocator.free(replacement_response);
    try std.testing.expect(try testSessionCreateResponseWasCreated(allocator, replacement_response));
    try std.testing.expectEqual(@as(usize, 1), daemon.sessions.items.len);
    try std.testing.expect(daemon.sessions.items[0].running);
    try std.testing.expectEqual(@as(usize, 0), daemon.sessions.items[0].attach_clients.items.len);
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
    const allocator = std.testing.allocator;
    const socket = try socketPath(allocator, "/tmp/verde");
    defer allocator.free(socket);
    try std.testing.expect(std.mem.endsWith(u8, socket, "/tmp/verde/" ++ SOCKET_NAME));
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

test "daemon retains chat turns until their result is consumed" {
    try std.testing.expect(chatTurnKeepsDaemonAlive(.running, false, false));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.waiting_approval, false, false));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.completed, false, true));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.failed, false, true));
    try std.testing.expect(chatTurnKeepsDaemonAlive(.aborted, false, true));
    try std.testing.expect(!chatTurnKeepsDaemonAlive(.completed, true, true));
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

//! Verde-native terminal session identity and daemon protocol helpers.
//!
//! This module is intentionally separate from `terminal.zig`: terminal UI code
//! can import these small types while the long-lived PTY owner and CLI attach
//! behavior grow here instead of being buried in the renderer/pane code.

const std = @import("std");
const builtin = @import("builtin");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const SOCKET_NAME = "verde-sessionizer.sock";
pub const PID_FILE_NAME = "verde-sessionizer.pid";
pub const PROTOCOL_VERSION: u32 = 1;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 30;
const MAX_OUTPUT_RING: usize = 1024 * 1024;
const ATTACH_STALE_MS: i64 = 60 * std.time.ms_per_s;
const IDLE_EXIT_MS: i64 = 30 * std.time.ms_per_s;
const TERMINAL_WINSIZE_IOCTL: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
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
    return std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
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
    return try allocator.dupe(u8, std.mem.trim(u8, line, "\r"));
}

pub fn ensureDaemon(allocator: std.mem.Allocator, pref_path: []const u8, exe_path: []const u8) !void {
    if (requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
        allocator.free(response);
        return;
    } else |_| {}

    try spawnDaemon(allocator, exe_path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var attempts: usize = 0;
    while (attempts < 250) : (attempts += 1) {
        if (requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            return;
        } else |_| {
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
    }
    return error.SessionDaemonUnavailable;
}

pub fn spawnDaemon(allocator: std.mem.Allocator, exe_path: []const u8) !void {
    const daemon_exe = try daemonExecutablePath(allocator, exe_path);
    defer allocator.free(daemon_exe);
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

pub fn daemonExecutablePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, exe_path, '/') != null) return allocator.dupe(u8, exe_path);
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

pub const CreateOptions = struct {
    session_id: []const u8,
    project_id: []const u8 = "",
    project_path: []const u8 = "",
    cwd: []const u8 = "",
    label: []const u8 = "",
    command: []const []const u8 = &.{},
    cols: u16 = DEFAULT_COLS,
    rows: u16 = DEFAULT_ROWS,
};

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
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,
    cols: u16,
    rows: u16,
    output_ring: std.ArrayList(u8) = .empty,
    running: bool = true,
    exit_status: ?u32 = null,
    created_at_ms: i64,
    last_attached_at_ms: ?i64 = null,
    attach_clients: std.ArrayList(AttachClient) = .empty,

    const SpawnResult = struct {
        master_fd: std.posix.fd_t,
        child_pid: std.posix.pid_t,
    };

    extern fn forkpty(
        amaster: *c_int,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const std.posix.winsize,
    ) c_int;

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

        const child = try spawnCommand(allocator, cwd, options.cols, options.rows, command);
        errdefer {
            std.posix.kill(child.child_pid, std.posix.SIG.TERM) catch {};
            _ = std.c.close(child.master_fd);
        }

        self.* = .{
            .session_id = try allocator.dupe(u8, options.session_id),
            .project_id = try allocator.dupe(u8, options.project_id),
            .project_path = try allocator.dupe(u8, options.project_path),
            .cwd = try allocator.dupe(u8, cwd),
            .label = try allocator.dupe(u8, if (options.label.len > 0) options.label else command_label),
            .command_label = command_label,
            .master_fd = child.master_fd,
            .child_pid = child.child_pid,
            .cols = options.cols,
            .rows = options.rows,
            .created_at_ms = nowMs(),
        };
        return self;
    }

    pub fn deinit(self: *PtySession, allocator: std.mem.Allocator) void {
        if (self.running) std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
        _ = std.c.close(self.master_fd);
        _ = self.captureExitStatus();
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
        try self.drainOutput(allocator);
        _ = self.captureExitStatus();
    }

    fn writeInput(self: *PtySession, bytes: []const u8) !bool {
        if (!self.running or bytes.len == 0) return false;
        try writeAll(self.master_fd, bytes);
        return true;
    }

    fn resize(self: *PtySession, cols: u16, rows: u16) void {
        if (!self.running) return;
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        var winsize = std.posix.winsize{
            .row = self.rows,
            .col = self.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = std.c.ioctl(self.master_fd, TERMINAL_WINSIZE_IOCTL, &winsize);
    }

    fn terminate(self: *PtySession) bool {
        if (!self.running) return false;
        std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch return false;
        self.running = false;
        _ = self.captureExitStatus();
        return true;
    }

    fn foregroundProcessGroup(self: *const PtySession) ?std.posix.pid_t {
        if (!self.running) return null;
        const ioctl_value = TERMINAL_GET_PGRP_IOCTL orelse return null;
        var pgrp: c_int = 0;
        if (std.c.ioctl(self.master_fd, ioctl_value, &pgrp) != 0 or pgrp <= 0) return null;
        return @intCast(pgrp);
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

    fn drainOutput(self: *PtySession, allocator: std.mem.Allocator) !void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const read_raw = std.c.read(self.master_fd, &buffer, buffer.len);
            if (read_raw > 0) {
                try self.appendOutput(allocator, buffer[0..@intCast(read_raw)]);
                continue;
            }
            if (read_raw == 0) {
                self.running = false;
                _ = self.captureExitStatus();
                return;
            }
            const err = std.c._errno().*;
            if (err == @intFromEnum(std.c.E.AGAIN)) return;
            self.running = false;
            _ = self.captureExitStatus();
            return;
        }
    }

    fn appendOutput(self: *PtySession, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len >= MAX_OUTPUT_RING) {
            self.output_ring.clearRetainingCapacity();
            try self.output_ring.appendSlice(allocator, bytes[bytes.len - MAX_OUTPUT_RING ..]);
            return;
        }
        const overflow = self.output_ring.items.len + bytes.len -| MAX_OUTPUT_RING;
        if (overflow > 0) {
            std.mem.copyForwards(u8, self.output_ring.items[0 .. self.output_ring.items.len - overflow], self.output_ring.items[overflow..]);
            self.output_ring.shrinkRetainingCapacity(self.output_ring.items.len - overflow);
        }
        try self.output_ring.appendSlice(allocator, bytes);
    }

    fn captureExitStatus(self: *PtySession) bool {
        if (self.exit_status != null) return false;
        var status: c_int = 0;
        const wait_result = std.c.waitpid(self.child_pid, &status, std.c.W.NOHANG);
        if (wait_result == 0) return false;
        self.running = false;
        self.exit_status = @intCast(status);
        return true;
    }

    fn spawnCommand(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        cols: u16,
        rows: u16,
        command: []const [:0]u8,
    ) !SpawnResult {
        const cwd_z = try allocator.dupeZ(u8, cwd);
        defer allocator.free(cwd_z);

        var master_fd: c_int = -1;
        const winsize = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const fork_result = forkpty(&master_fd, null, null, &winsize);
        if (fork_result < 0) return error.ForkPtyFailed;
        if (fork_result == 0) childExec(cwd_z, command);

        try setNonBlocking(@intCast(master_fd));
        return .{
            .master_fd = @intCast(master_fd),
            .child_pid = @intCast(fork_result),
        };
    }

    fn childExec(cwd: [:0]const u8, command: []const [:0]u8) noreturn {
        if (std.c.chdir(cwd.ptr) != 0) std.c._exit(127);
        _ = setenv("TERM", "xterm-ghostty", 1);
        _ = setenv("COLORTERM", "truecolor", 1);
        _ = setenv("TERM_PROGRAM", "verde", 1);
        if (std.c.getenv("LANG") == null) _ = setenv("LANG", "C.UTF-8", 1);

        var argv: [64:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 64;
        const count = @min(command.len, argv.len - 1);
        for (command[0..count], 0..) |arg, index| argv[index] = arg.ptr;
        if (count > 0) _ = std.c.execve(command[0].ptr, &argv, std.c.environ);
        std.c._exit(127);
    }
};

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(*PtySession) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    idle_since_ms: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator) Daemon {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Daemon) void {
        for (self.sessions.items) |session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
    }

    fn pollSessions(self: *Daemon) void {
        const now = nowMs();
        for (self.sessions.items) |session| {
            session.poll(self.allocator) catch {};
            session.cleanupStaleAttaches(self.allocator, now);
        }
    }

    fn shouldExitForIdle(self: *Daemon) bool {
        for (self.sessions.items) |session| {
            if (session.running) {
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
        self.pollSessions();
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
        if (std.mem.eql(u8, method, "status")) return try self.statusResponse(id_value);
        return try errorResponseAlloc(self.allocator, id_value, "method_not_found", method);
    }

    fn statusResponse(self: *Daemon, id_value: std.json.Value) ![]u8 {
        return try okValueResponse(self.allocator, id_value, .{
            .protocol_version = PROTOCOL_VERSION,
            .pid = std.c.getpid(),
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
            existing.last_attached_at_ms = nowMs();
            return try okSessionResponse(self.allocator, id_value, existing, false);
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
        return try okValueResponse(self.allocator, id_value, .{ .accepted = wrote, .bytes = text.len });
    }

    fn resizeResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        touchAttachFromParams(session, params);
        session.resize(
            jsonU16(params.object.get("cols") orelse .null) orelse session.cols,
            jsonU16(params.object.get("rows") orelse .null) orelse session.rows,
        );
        return try okValueResponse(self.allocator, id_value, .{ .accepted = true });
    }

    fn tailResponse(self: *Daemon, id_value: std.json.Value, params: std.json.Value, screen: bool) ![]u8 {
        const session = try self.requiredSession(id_value, params);
        if (params != .object) unreachable;
        touchAttachFromParams(session, params);
        const lines = jsonU32(params.object.get("lines") orelse .null) orelse if (screen) DEFAULT_ROWS else 80;
        const start_offset = jsonUsize(params.object.get("offset") orelse .null);
        const max_bytes = jsonUsize(params.object.get("max_bytes") orelse .null);
        const text_range = if (start_offset) |offset|
            bytesRangeFromOffset(session.output_ring.items, offset, max_bytes)
        else
            bytesRangeForTailLines(session.output_ring.items, lines, max_bytes);
        const text = try self.allocator.dupe(u8, session.output_ring.items[text_range.start..text_range.end]);
        defer self.allocator.free(text);
        return try okValueResponse(self.allocator, id_value, .{
            .id = session.session_id,
            .running = session.running,
            .pid = session.child_pid,
            .foreground_process_group = session.foregroundProcessGroup(),
            .text = text,
            .offset = text_range.start,
            .next_offset = session.output_ring.items.len,
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

    fn requiredSession(self: *Daemon, id_value: std.json.Value, params: std.json.Value) !*PtySession {
        _ = id_value;
        if (params != .object) return error.InvalidParams;
        const wanted_id = jsonString(params.object.get("id") orelse .null) orelse return error.MissingSessionId;
        return self.find(wanted_id) orelse return error.SessionNotFound;
    }
};

pub fn runDaemon(allocator: std.mem.Allocator, pref_path: []const u8) !void {
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
            std.c.exit(0);
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

fn sleepMs(milliseconds: i64) void {
    var request = std.c.timespec{
        .sec = @intCast(@divTrunc(milliseconds, std.time.ms_per_s)),
        .nsec = @intCast(@mod(milliseconds, std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&request, null);
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
    if (args.len > 0) return dupeCommand(allocator, args);
    const shell = if (std.c.getenv("SHELL")) |shell_ptr| std.mem.span(shell_ptr) else "/bin/bash";
    return dupeCommand(allocator, &.{ shell, "-i" });
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

fn childProcessCount(pid: std.posix.pid_t) ?usize {
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

pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
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
    const text = try std.fmt.bufPrint(&buffer, "{d}\n", .{std.c.getpid()});
    var write_buffer: [64]u8 = undefined;
    var writer = file.writer(threaded.io(), &write_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn deleteSocketPath(path: []const u8) void {
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

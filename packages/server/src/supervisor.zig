//! Foreground supervision for the daemon and loopback gateway boundaries.

const std = @import("std");
const builtin = @import("builtin");

var daemon_pid: std.atomic.Value(i32) = .init(0);
var gateway_pid: std.atomic.Value(i32) = .init(0);
var shutdown_requested: std.atomic.Value(bool) = .init(false);

pub const Paths = struct {
    daemon: []const u8,
    gateway: []const u8,
    data_dir: []const u8,
    token_file: []const u8,
    static_dir: []const u8,
    gateway_port: u16,
};

pub fn serve(io: std.Io, paths: Paths) !u8 {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    try validatePaths(io, paths);
    shutdown_requested.store(false, .release);
    installSignalHandlers();
    defer clearPids();

    var daemon = try std.process.spawn(io, .{ .argv = &.{ paths.daemon, "serve", "--data-dir", paths.data_dir } });
    const started_daemon_pid = daemon.id.?;
    daemon_pid.store(@intCast(started_daemon_pid), .release);
    var port_buffer: [6]u8 = undefined;
    var socket_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buffer, "{d}", .{paths.gateway_port});
    var gateway = std.process.spawn(io, .{ .argv = &.{
        paths.gateway,                                       "--host",         "127.0.0.1",      "--port",       port,
        "--token-file",                                      paths.token_file, "--pref-path",    paths.data_dir, "--sessionizer",
        try sessionizerPath(paths.data_dir, &socket_buffer), "--static",       paths.static_dir,
    } }) catch |err| {
        terminateChild(&daemon);
        _ = try daemon.wait(io);
        return err;
    };
    const started_gateway_pid = gateway.id.?;
    gateway_pid.store(@intCast(started_gateway_pid), .release);

    var daemon_monitor: Monitor = .{ .child = &daemon, .io = io };
    var gateway_monitor: Monitor = .{ .child = &gateway, .io = io };
    const daemon_thread = std.Thread.spawn(.{}, Monitor.wait, .{&daemon_monitor}) catch |err| {
        terminatePid(started_gateway_pid);
        terminatePid(started_daemon_pid);
        _ = try gateway.wait(io);
        _ = try daemon.wait(io);
        return err;
    };
    const gateway_thread = std.Thread.spawn(.{}, Monitor.wait, .{&gateway_monitor}) catch |err| {
        terminatePid(started_gateway_pid);
        terminatePid(started_daemon_pid);
        daemon_thread.join();
        _ = try gateway.wait(io);
        return err;
    };

    while (!shutdown_requested.load(.acquire) and
        !daemon_monitor.done.load(.acquire) and
        !gateway_monitor.done.load(.acquire))
    {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    const daemon_finished_first = daemon_monitor.done.load(.acquire);
    if (!daemon_finished_first) terminatePid(started_daemon_pid);
    if (!gateway_monitor.done.load(.acquire)) terminatePid(started_gateway_pid);
    daemon_thread.join();
    gateway_thread.join();
    if (shutdown_requested.load(.acquire)) return 0;
    return if (daemon_finished_first) termCode(daemon_monitor.term) else termCode(gateway_monitor.term);
}

pub fn validatePaths(io: std.Io, paths: Paths) !void {
    try requireAbsoluteRegularExecutable(io, paths.daemon);
    try requireAbsoluteRegularExecutable(io, paths.gateway);
    if (!std.fs.path.isAbsolute(paths.data_dir) or !std.fs.path.isAbsolute(paths.token_file) or
        !std.fs.path.isAbsolute(paths.static_dir)) return error.PathMustBeAbsolute;
    const static_stat = try std.Io.Dir.cwd().statFile(io, paths.static_dir, .{});
    if (static_stat.kind != .directory) return error.NotDir;
}

fn requireAbsoluteRegularExecutable(io: std.Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.PathMustBeAbsolute;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.NotAFile;
    if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o111 == 0) return error.NotExecutable;
}

fn sessionizerPath(data_dir: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/verde-sessionizer.sock", .{data_dir});
}

fn terminateChild(child: *std.process.Child) void {
    if (child.id) |id| std.posix.kill(id, .TERM) catch {};
}

fn terminatePid(pid: std.process.Child.Id) void {
    std.posix.kill(pid, .TERM) catch {};
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    const gateway = gateway_pid.load(.acquire);
    const daemon = daemon_pid.load(.acquire);
    if (gateway > 0) std.posix.kill(gateway, .TERM) catch {};
    if (daemon > 0) std.posix.kill(daemon, .TERM) catch {};
}

fn clearPids() void {
    gateway_pid.store(0, .release);
    daemon_pid.store(0, .release);
}

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u16, 128) + @intFromEnum(signal), 255)),
        else => 1,
    };
}

const Monitor = struct {
    child: *std.process.Child,
    io: std.Io,
    done: std.atomic.Value(bool) = .init(false),
    term: std.process.Child.Term = .{ .unknown = 1 },

    fn wait(self: *Monitor) void {
        self.term = self.child.wait(self.io) catch .{ .unknown = 1 };
        self.done.store(true, .release);
    }
};

pub const StartState = enum { idle, daemon_started, both_started, stopping, stopped };

pub fn nextState(state: StartState, event: enum { daemon_started, gateway_started, child_failed, shutdown_complete }) !StartState {
    return switch (event) {
        .daemon_started => if (state == .idle) .daemon_started else error.InvalidTransition,
        .gateway_started => if (state == .daemon_started) .both_started else error.InvalidTransition,
        .child_failed => if (state == .daemon_started or state == .both_started) .stopping else error.InvalidTransition,
        .shutdown_complete => if (state == .stopping) .stopped else error.InvalidTransition,
    };
}

test "supervision state requires partial-start cleanup" {
    var state: StartState = .idle;
    state = try nextState(state, .daemon_started);
    state = try nextState(state, .child_failed);
    state = try nextState(state, .shutdown_complete);
    try std.testing.expectEqual(StartState.stopped, state);
    try std.testing.expectError(error.InvalidTransition, nextState(.idle, .gateway_started));
}

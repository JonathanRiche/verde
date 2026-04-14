const builtin = @import("builtin");
const std = @import("std");

const STDERR_LOG_FILE_NAME = "verde.stderr.log";
const LAST_CRASH_LOG_FILE_NAME = "last-crash.log";

var initialized = false;
var stderr_log_path: ?[]const u8 = null;
var last_crash_log_path: ?[]const u8 = null;

pub fn init(pref_path: []const u8) !void {
    if (initialized) return;

    var pref_dir = try std.fs.openDirAbsolute(pref_path, .{});
    defer pref_dir.close();
    try pref_dir.makePath("logs");

    const allocator = std.heap.page_allocator;
    const logs_dir = try std.fs.path.join(allocator, &.{ pref_path, "logs" });
    defer allocator.free(logs_dir);

    const stderr_path = try std.fs.path.join(allocator, &.{ logs_dir, STDERR_LOG_FILE_NAME });
    errdefer allocator.free(stderr_path);

    const crash_path = try std.fs.path.join(allocator, &.{ logs_dir, LAST_CRASH_LOG_FILE_NAME });
    errdefer allocator.free(crash_path);

    var log_file = try std.fs.createFileAbsolute(stderr_path, .{
        .read = true,
        .truncate = false,
    });
    defer log_file.close();

    try log_file.seekFromEnd(0);
    try writeSessionHeader(log_file);

    switch (builtin.os.tag) {
        .windows => {},
        else => try std.posix.dup2(log_file.handle, std.posix.STDERR_FILENO),
    }

    stderr_log_path = stderr_path;
    last_crash_log_path = crash_path;
    initialized = true;
}

pub fn stderrLogPath() ?[]const u8 {
    return stderr_log_path;
}

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    writePanicMarker(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn writeSessionHeader(file: std.fs.File) !void {
    const pid = processId();
    const timestamp = std.time.timestamp();
    try file.deprecatedWriter().print(
        "\n===== verde session start pid={d} unix={d} mode={s} =====\n",
        .{ pid, timestamp, @tagName(builtin.mode) },
    );
}

fn writePanicMarker(msg: []const u8, first_trace_addr: ?usize) void {
    const crash_path = last_crash_log_path orelse return;

    var crash_file = std.fs.createFileAbsolute(crash_path, .{
        .read = true,
        .truncate = false,
    }) catch return;
    defer crash_file.close();

    crash_file.seekFromEnd(0) catch return;

    const pid = processId();
    const timestamp = std.time.timestamp();
    crash_file.deprecatedWriter().print(
        "[{d}] pid={d} panic: {s} first_trace_addr={?}\n",
        .{ timestamp, pid, msg, first_trace_addr },
    ) catch return;

    if (stderr_log_path) |path| {
        crash_file.deprecatedWriter().print("stderr_log={s}\n", .{path}) catch return;
    }
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => 0,
        else => @intCast(std.c.getpid()),
    };
}

const builtin = @import("builtin");
const std = @import("std");
const platform_runtime = @import("platform_runtime");

const STDERR_LOG_FILE_NAME = "verde.stderr.log";
const LAST_CRASH_LOG_FILE_NAME = "last-crash.log";
/// Rotate the stderr log to `<name>.1` at session start once it exceeds this
/// cap. Per-frame log spam once grew the shared log to 1.3 GB; rotating
/// (instead of truncating) keeps the prior sessions' tail available for
/// post-mortem debugging while bounding disk usage to roughly twice the cap.
const STDERR_LOG_ROTATE_BYTES: u64 = 64 * 1024 * 1024;
const LOG_ENTRY_CAPACITY = 512;
const LOG_MESSAGE_CAPACITY = 640;
const LOG_SCOPE_CAPACITY = 48;

var initialized = false;
var runtime_io: ?std.Io = null;
var stderr_log_path: ?[]const u8 = null;
var last_crash_log_path: ?[]const u8 = null;
var log_mutex: std.atomic.Mutex = .unlocked;
var log_file_mutex: std.atomic.Mutex = .unlocked;
var log_entries: [LOG_ENTRY_CAPACITY]LogEntry = [_]LogEntry{LogEntry.empty()} ** LOG_ENTRY_CAPACITY;
var log_sequence: u64 = 0;
var log_total: usize = 0;

pub const LogEntry = struct {
    sequence: u64,
    timestamp_ms: i64,
    level: std.log.Level,
    scope_len: usize,
    scope: [LOG_SCOPE_CAPACITY]u8,
    message_len: usize,
    message: [LOG_MESSAGE_CAPACITY]u8,
    truncated: bool,

    pub fn empty() LogEntry {
        return .{
            .sequence = 0,
            .timestamp_ms = 0,
            .level = .info,
            .scope_len = 0,
            .scope = std.mem.zeroes([LOG_SCOPE_CAPACITY]u8),
            .message_len = 0,
            .message = std.mem.zeroes([LOG_MESSAGE_CAPACITY]u8),
            .truncated = false,
        };
    }

    pub fn scopeSlice(self: *const LogEntry) []const u8 {
        return self.scope[0..self.scope_len];
    }

    pub fn messageSlice(self: *const LogEntry) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub fn init(io: std.Io, pref_path: []const u8) !void {
    if (initialized) return;
    runtime_io = io;

    var pref_dir = try std.Io.Dir.openDirAbsolute(io, pref_path, .{});
    defer pref_dir.close(io);
    try pref_dir.createDirPath(io, "logs");

    const allocator = std.heap.page_allocator;
    const logs_dir = try std.fs.path.join(allocator, &.{ pref_path, "logs" });
    defer allocator.free(logs_dir);

    const stderr_path = try std.fs.path.join(allocator, &.{ logs_dir, STDERR_LOG_FILE_NAME });
    errdefer allocator.free(stderr_path);

    const crash_path = try std.fs.path.join(allocator, &.{ logs_dir, LAST_CRASH_LOG_FILE_NAME });
    errdefer allocator.free(crash_path);

    rotateStderrLogIfOversized(io, pref_dir, allocator, stderr_path);

    var log_file = try std.Io.Dir.createFileAbsolute(io, stderr_path, .{
        .read = true,
        .truncate = false,
    });
    defer log_file.close(io);

    try writeSessionHeader(io, log_file);

    switch (builtin.os.tag) {
        .windows => {},
        else => if (std.c.dup2(log_file.handle, std.c.STDERR_FILENO) < 0) return error.SystemResources,
    }

    stderr_log_path = stderr_path;
    last_crash_log_path = crash_path;
    initialized = true;
}

pub fn stderrLogPath() ?[]const u8 {
    return stderr_log_path;
}

pub fn diagnostic(comptime format: []const u8, args: anytype) void {
    const path = stderr_log_path orelse return;
    const io = runtime_io orelse return;

    while (!log_file_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_file_mutex.unlock();

    var file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = false,
    }) catch return;
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.pos = file.length(io) catch return;
    writer.interface.print("[diagnostic {d}] ", .{unixTimestampMs()}) catch return;
    writer.interface.print(format, args) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_name = comptime @tagName(scope);
    appendLogEntry(level, scope_name, format, args);

    // A GUI-subsystem Windows process has no usable stderr stream to redirect.
    // Persist the same log line explicitly so diagnostics remain available in
    // the pref-directory log just as they are on Unix hosts.
    if (builtin.os.tag == .windows) appendWindowsLogLine(level, scope_name, format, args);

    const prefix = "[" ++ comptime level.asText() ++ "] (" ++ scope_name ++ "): ";
    std.debug.print(prefix ++ format ++ "\n", args);
}

fn appendWindowsLogLine(
    comptime level: std.log.Level,
    comptime scope_name: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const path = stderr_log_path orelse return;
    const io = runtime_io orelse return;

    while (!log_file_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_file_mutex.unlock();

    var file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = false,
    }) catch return;
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.pos = file.length(io) catch return;
    writer.interface.print("[{s}] ({s}): ", .{ level.asText(), scope_name }) catch return;
    writer.interface.print(format, args) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
}

pub fn logEntryCount() usize {
    while (!log_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_mutex.unlock();
    return @min(log_total, LOG_ENTRY_CAPACITY);
}

pub fn logEntryAt(oldest_index: usize) ?LogEntry {
    while (!log_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_mutex.unlock();

    const count = @min(log_total, LOG_ENTRY_CAPACITY);
    if (oldest_index >= count) return null;

    const first = if (log_total < LOG_ENTRY_CAPACITY) 0 else log_total % LOG_ENTRY_CAPACITY;
    const slot = (first + oldest_index) % LOG_ENTRY_CAPACITY;
    return log_entries[slot];
}

pub fn clearLogEntries() void {
    while (!log_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_mutex.unlock();

    log_entries = [_]LogEntry{LogEntry.empty()} ** LOG_ENTRY_CAPACITY;
    log_total = 0;
}

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    writePanicMarker(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn appendLogEntry(
    comptime level: std.log.Level,
    comptime scope_name: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    var entry = LogEntry.empty();
    entry.timestamp_ms = unixTimestampMs();
    entry.level = level;
    entry.truncated = false;

    entry.scope_len = @min(scope_name.len, entry.scope.len);
    @memcpy(entry.scope[0..entry.scope_len], scope_name[0..entry.scope_len]);

    var writer: std.Io.Writer = .fixed(&entry.message);
    writer.print(format, args) catch {
        entry.truncated = true;
    };
    entry.message_len = writer.end;

    while (!log_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_mutex.unlock();

    entry.sequence = log_sequence;
    log_sequence +%= 1;
    const slot = log_total % LOG_ENTRY_CAPACITY;
    log_entries[slot] = entry;
    log_total +%= 1;
}

fn writeSessionHeader(io: std.Io, file: std.Io.File) !void {
    const pid = processId();
    const timestamp = unixTimestampMs();
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.pos = try file.length(io);
    try writer.interface.print(
        "\n===== verde session start pid={d} unix={d} mode={s} =====\n",
        .{ pid, timestamp, @tagName(builtin.mode) },
    );
    try writer.interface.flush();
}

fn writePanicMarker(msg: []const u8, first_trace_addr: ?usize) void {
    const crash_path = last_crash_log_path orelse return;
    const io = runtime_io orelse return;

    var crash_file = std.Io.Dir.createFileAbsolute(io, crash_path, .{
        .read = true,
        .truncate = false,
    }) catch return;
    defer crash_file.close(io);

    const pid = processId();
    const timestamp = unixTimestampMs();
    var buffer: [512]u8 = undefined;
    var writer = crash_file.writer(io, &buffer);
    writer.pos = crash_file.length(io) catch return;
    writer.interface.print(
        "[{d}] pid={d} panic: {s} first_trace_addr={?}\n",
        .{ timestamp, pid, msg, first_trace_addr },
    ) catch return;

    if (stderr_log_path) |path| {
        writer.interface.print("stderr_log={s}\n", .{path}) catch return;
    }
    writer.interface.flush() catch return;
}

// Best-effort session-start rotation: a rename failure must never block app
// startup, so all errors are swallowed. Another live instance holding the old
// file keeps writing to the renamed inode, which is the standard rotation
// behavior and loses nothing.
fn rotateStderrLogIfOversized(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    stderr_path: []const u8,
) void {
    // `stderr_path` is absolute, so `dir` is ignored by statFile; it only
    // satisfies the method receiver.
    const stat = dir.statFile(io, stderr_path, .{}) catch return;
    if (stat.size <= STDERR_LOG_ROTATE_BYTES) return;

    const rotated_path = std.fmt.allocPrint(allocator, "{s}.1", .{stderr_path}) catch return;
    defer allocator.free(rotated_path);
    std.Io.Dir.renameAbsolute(stderr_path, rotated_path, io) catch return;
}

fn processId() u32 {
    return platform_runtime.processId();
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

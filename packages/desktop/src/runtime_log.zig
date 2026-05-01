const builtin = @import("builtin");
const std = @import("std");

const STDERR_LOG_FILE_NAME = "verde.stderr.log";
const LAST_CRASH_LOG_FILE_NAME = "last-crash.log";
const LOG_ENTRY_CAPACITY = 512;
const LOG_MESSAGE_CAPACITY = 640;
const LOG_SCOPE_CAPACITY = 48;

var initialized = false;
var runtime_io: ?std.Io = null;
var stderr_log_path: ?[]const u8 = null;
var last_crash_log_path: ?[]const u8 = null;
var log_mutex: std.atomic.Mutex = .unlocked;
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

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_name = comptime @tagName(scope);
    appendLogEntry(level, scope_name, format, args);

    const prefix = "[" ++ comptime level.asText() ++ "] (" ++ scope_name ++ "): ";
    std.debug.print(prefix ++ format ++ "\n", args);
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
    entry.timestamp_ms = 0;
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
    const timestamp = 0;
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
    const timestamp = 0;
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

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => 0,
        else => @intCast(std.c.getpid()),
    };
}

//! Portable process identity, executable-path, clock, and sleep helpers.

const std = @import("std");
const builtin = @import("builtin");

/// Returns the current process identifier on every supported desktop OS.
pub fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

/// Returns milliseconds since the Unix epoch using Zig's portable real clock.
pub fn unixTimestampMs() i64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const timestamp = std.Io.Clock.real.now(threaded.io());
    return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
}

/// Returns nanoseconds from an unspecified monotonic origin.
pub fn monotonicTimestampNs() u64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const timestamp = std.Io.Clock.awake.now(threaded.io());
    return @intCast(@max(timestamp.nanoseconds, 0));
}

/// Sleeps on a monotonic clock so wall-clock changes cannot extend the wait.
pub fn sleepMillis(milliseconds: u64) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.sleep(
        threaded.io(),
        .fromMilliseconds(@intCast(milliseconds)),
        .awake,
    ) catch {};
}

/// Allocates the absolute path of the running executable.
pub fn executablePathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    return std.process.executablePathAlloc(threaded.io(), allocator);
}

/// Allocates the absolute directory containing the running executable.
pub fn executableDirPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    return std.process.executableDirPathAlloc(threaded.io(), allocator);
}

test "portable clocks advance and process id is available" {
    const before = monotonicTimestampNs();
    sleepMillis(1);
    const after = monotonicTimestampNs();
    try std.testing.expect(after >= before);
    try std.testing.expect(processId() != 0);
    try std.testing.expect(unixTimestampMs() > 0);
}

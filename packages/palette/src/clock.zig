//! Portable clocks used by Palette profiling and frame accounting.

const std = @import("std");

/// Returns nanoseconds from an unspecified monotonic origin.
pub fn monotonicTimestampNs() u64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const timestamp = std.Io.Clock.awake.now(threaded.io());
    return @intCast(@max(timestamp.nanoseconds, 0));
}

/// Blocks the calling thread for `ns` nanoseconds (portable: nanosleep / Win32 waits).
pub fn sleepNs(ns: u64) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    threaded.io().sleep(.{ .nanoseconds = @intCast(ns) }, .awake) catch {};
}

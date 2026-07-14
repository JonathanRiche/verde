//! Portable clocks used by Palette profiling and frame accounting.

const std = @import("std");

/// Returns nanoseconds from an unspecified monotonic origin.
pub fn monotonicTimestampNs() u64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const timestamp = std.Io.Clock.awake.now(threaded.io());
    return @intCast(@max(timestamp.nanoseconds, 0));
}

test "monotonic clock is nondecreasing" {
    const before = monotonicTimestampNs();
    const after = monotonicTimestampNs();
    try std.testing.expect(after >= before);
}

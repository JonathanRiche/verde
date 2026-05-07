//! Tiny smoke target for the palette package.

const std = @import("std");

pub fn main() !void {
    std.mem.doNotOptimizeAway("palette");
}

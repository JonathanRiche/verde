//! Test root for the font workstream (`zig build test-font`).
const std = @import("std");

pub const font = @import("font/root.zig");

test {
    std.testing.refAllDecls(font);
    _ = @import("font/raster.zig");
    _ = @import("font/tests.zig");
}

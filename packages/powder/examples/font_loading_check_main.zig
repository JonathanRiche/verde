//! Native Zig entry point for the Powder font loading check.

const std = @import("std");
const check = @import("font_loading_check.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    try check.run(gpa.allocator());
}

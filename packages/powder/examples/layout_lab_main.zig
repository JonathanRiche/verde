//! Native Zig entry point for the layout lab on platforms where Zig's linker works.

const lab = @import("layout_lab.zig");

pub fn main() !void {
    try lab.run();
}

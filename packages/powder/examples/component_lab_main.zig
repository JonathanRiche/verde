//! Native Zig entry point for the component lab on platforms where Zig's linker works.

const lab = @import("component_lab.zig");

pub fn main() !void {
    try lab.run();
}

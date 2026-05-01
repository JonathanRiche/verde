//! Native Zig entry point for the text area lab on platforms where Zig's linker works.

const lab = @import("text_area_lab.zig");

pub fn main() !void {
    try lab.run();
}

//! Native Zig entry point for the composer prompt lab.

const lab = @import("composer_prompt_lab.zig");

pub fn main() !void {
    try lab.run();
}

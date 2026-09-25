//! Host-only codegen driver; reflection itself executes entirely at comptime.
const std = @import("std");
const generator = @import("model_codegen.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedLanguage;
    const output = if (std.mem.eql(u8, args[1], "kotlin"))
        comptime generator.generate(.kotlin)
    else if (std.mem.eql(u8, args[1], "swift"))
        comptime generator.generate(.swift)
    else
        return error.UnknownLanguage;
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

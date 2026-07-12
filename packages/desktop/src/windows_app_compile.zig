const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal/terminal.zig");
const cli = @import("cli.zig");

pub fn main() !void {
    var dock = try terminal.Dock.init(std.heap.smp_allocator);
    defer dock.deinit(std.heap.smp_allocator);
    dock.ensureSessionPersistent(std.heap.smp_allocator, ".", "C:\\verde-test", 0) catch {};
    _ = dock.poll(std.heap.smp_allocator) catch false;

    if (builtin.os.tag == .windows) {
        const command_line = [_]u16{ 'v', 'e', 'r', 'd', 'e', ' ', 'h', 'e', 'l', 'p', 0 };
        const process_args: std.process.Args = .{ .vector = &command_line };
        _ = cli.dispatch(std.heap.smp_allocator, undefined, process_args) catch .handled;
    } else {
        const argv = [_][*:0]const u8{ "verde", "help" };
        const process_args: std.process.Args = .{ .vector = &argv };
        _ = cli.dispatch(std.heap.smp_allocator, undefined, process_args) catch .handled;
    }
}

const std = @import("std");

pub const Output = struct {
    io: std.Io,

    pub fn stdout(self: Output, comptime fmt: []const u8, args: anytype) !void {
        const stdout_file = std.Io.File.stdout();
        var buffer: [16 * 1024]u8 = undefined;
        var writer = stdout_file.writerStreaming(self.io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.print(fmt, args);
    }

    pub fn stderr(self: Output, comptime fmt: []const u8, args: anytype) !void {
        const stderr_file = std.Io.File.stderr();
        var buffer: [4 * 1024]u8 = undefined;
        var writer = stderr_file.writerStreaming(self.io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.print(fmt, args);
    }

    pub fn jsonValue(self: Output, allocator: std.mem.Allocator, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(encoded);
        try self.stdout("{s}\n", .{encoded});
    }
};

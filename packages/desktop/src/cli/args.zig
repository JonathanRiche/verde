const std = @import("std");

pub const Parsed = struct {
    command: []const u8 = "",
    rest: []const []const u8 = &.{},
    json: bool = false,
};

pub fn parse(args: []const []const u8) Parsed {
    if (args.len <= 1) return .{};
    var parsed: Parsed = .{ .command = args[1], .rest = args[2..] };
    parsed.json = hasFlag(parsed.rest, "--json");
    return parsed;
}

pub fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

pub fn positional(args: []const []const u8, index: usize) ?[]const u8 {
    var seen: usize = 0;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) continue;
        if (seen == index) return arg;
        seen += 1;
    }
    return null;
}

pub fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, name)) continue;
        if (index + 1 >= args.len) return null;
        return args[index + 1];
    }
    return null;
}

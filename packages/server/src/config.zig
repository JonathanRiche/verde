//! Command-line parsing and non-secret operator defaults.

const std = @import("std");

pub const Command = enum {
    init,
    serve,
    status,
    version,
    help,
    pair_create,
    pair_list,
    pair_revoke,
    device_list,
    device_revoke,
    service_install,
    service_status,
    service_update,
    service_uninstall,
};

pub const Options = struct {
    command: Command,
    data_dir: ?[]const u8 = null,
    token_file: ?[]const u8 = null,
    gateway_port: u16 = 6783,
    json: bool = false,
    no_start: bool = false,
    delegate_args: []const []const u8 = &.{},
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Options {
    if (argv.len < 2) return .{ .command = .help };
    const command, const consumed = try parseCommand(argv);
    var options: Options = .{ .command = command };
    var delegated: std.ArrayList([]const u8) = .empty;
    errdefer delegated.deinit(allocator);

    var index: usize = consumed;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (isRawSecretArgument(arg)) {
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--no-start") and command == .service_install) {
            options.no_start = true;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            index += 1;
            if (index >= argv.len or options.data_dir != null) return error.InvalidArguments;
            options.data_dir = argv[index];
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            index += 1;
            if (index >= argv.len or options.token_file != null) return error.InvalidArguments;
            options.token_file = argv[index];
        } else if (std.mem.eql(u8, arg, "--gateway-port")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            options.gateway_port = std.fmt.parseInt(u16, argv[index], 10) catch return error.InvalidArguments;
            if (options.gateway_port == 0) return error.InvalidArguments;
        } else if (isDelegate(command)) {
            try delegated.append(allocator, arg);
        } else {
            return error.InvalidArguments;
        }
    }
    options.delegate_args = try delegated.toOwnedSlice(allocator);
    return options;
}

pub fn deinit(options: *Options, allocator: std.mem.Allocator) void {
    if (options.delegate_args.len > 0) allocator.free(options.delegate_args);
}

fn parseCommand(argv: []const []const u8) !struct { Command, usize } {
    const first = argv[1];
    if (std.mem.eql(u8, first, "init")) return .{ .init, 2 };
    if (std.mem.eql(u8, first, "serve")) return .{ .serve, 2 };
    if (std.mem.eql(u8, first, "status")) return .{ .status, 2 };
    if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version")) return .{ .version, 2 };
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) return .{ .help, 2 };
    if (std.mem.eql(u8, first, "pair")) return parseNested(argv, 2, .{
        .{ "create", .pair_create }, .{ "list", .pair_list }, .{ "revoke", .pair_revoke },
    });
    if (std.mem.eql(u8, first, "device")) return parseNested(argv, 2, .{
        .{ "list", .device_list }, .{ "revoke", .device_revoke },
    });
    if (std.mem.eql(u8, first, "service")) return parseNested(argv, 2, .{
        .{ "install", .service_install }, .{ "status", .service_status },
        .{ "update", .service_update },   .{ "uninstall", .service_uninstall },
    });
    return error.UnknownCommand;
}

fn parseNested(argv: []const []const u8, index: usize, comptime choices: anytype) !struct { Command, usize } {
    if (argv.len <= index) return error.InvalidArguments;
    inline for (choices) |choice| {
        if (std.mem.eql(u8, argv[index], choice[0])) return .{ choice[1], index + 1 };
    }
    return error.UnknownCommand;
}

fn isDelegate(command: Command) bool {
    return switch (command) {
        .pair_create, .pair_list, .pair_revoke, .device_list, .device_revoke => true,
        else => false,
    };
}

fn isRawSecretArgument(arg: []const u8) bool {
    const names = [_][]const u8{ "--token", "--authorization", "--secret", "--credential" };
    for (names) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
        if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') return true;
    }
    return false;
}

test "parses operator and delegated commands without accepting raw tokens" {
    var parsed = try parse(std.testing.allocator, &.{
        "verde-server", "pair", "create", "--expires", "10m", "--scope", "runtime:read", "--json",
    });
    defer deinit(&parsed, std.testing.allocator);
    try std.testing.expectEqual(Command.pair_create, parsed.command);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqualSlices([]const u8, &.{ "--expires", "10m", "--scope", "runtime:read" }, parsed.delegate_args);
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "verde-server", "serve", "--token", "secret" }));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "verde-server", "pair", "list", "--token=secret" }));
}

test "service and gateway options validate bounds" {
    var parsed = try parse(std.testing.allocator, &.{ "verde-server", "service", "install", "--gateway-port", "18473", "--no-start" });
    defer deinit(&parsed, std.testing.allocator);
    try std.testing.expectEqual(Command.service_install, parsed.command);
    try std.testing.expectEqual(@as(u16, 18473), parsed.gateway_port);
    try std.testing.expect(parsed.no_start);
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "verde-server", "serve", "--gateway-port", "0" }));
}

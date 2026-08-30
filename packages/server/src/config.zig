//! Command-line parsing and non-secret operator defaults.

const std = @import("std");

const DEFAULT_GATEWAY_PORT: u16 = 7420;
const DEFAULT_TAILSCALE_HTTPS_PORT: u16 = 443;

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
    tailscale_doctor,
    connect,
    connect_status,
    connect_unlink,
    connect_logout,
    service_install,
    service_status,
    service_update,
    service_uninstall,
};

pub const Options = struct {
    command: Command,
    data_dir: ?[]const u8 = null,
    token_file: ?[]const u8 = null,
    gateway_port: u16 = DEFAULT_GATEWAY_PORT,
    tailscale_https_port: u16 = DEFAULT_TAILSCALE_HTTPS_PORT,
    tailscale: bool = false,
    json: bool = false,
    no_start: bool = false,
    headless: bool = false,
    install_service: bool = false,
    control_plane_url: ?[]const u8 = null,
    credential_file: ?[]const u8 = null,
    descriptor_file: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, arg, "--tailscale") and
            (command == .serve or command == .service_install))
        {
            options.tailscale = true;
        } else if (std.mem.eql(u8, arg, "--headless") and isConnectAuth(command)) {
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--install-service") and command == .connect) {
            options.install_service = true;
        } else if (std.mem.eql(u8, arg, "--control-plane") and isConnectAuth(command)) {
            index += 1;
            if (index >= argv.len or options.control_plane_url != null) return error.InvalidArguments;
            options.control_plane_url = argv[index];
        } else if (std.mem.eql(u8, arg, "--credential-file") and isConnectAuth(command)) {
            index += 1;
            if (index >= argv.len or options.credential_file != null) return error.InvalidArguments;
            options.credential_file = argv[index];
        } else if (std.mem.eql(u8, arg, "--descriptor-file") and command == .connect) {
            index += 1;
            if (index >= argv.len or options.descriptor_file != null) return error.InvalidArguments;
            options.descriptor_file = argv[index];
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
        } else if (std.mem.eql(u8, arg, "--tailscale-https-port") and
            (command == .serve or command == .service_install or command == .tailscale_doctor))
        {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            options.tailscale_https_port = std.fmt.parseInt(u16, argv[index], 10) catch return error.InvalidArguments;
            if (options.tailscale_https_port == 0) return error.InvalidArguments;
        } else if (isDelegate(command)) {
            try delegated.append(allocator, arg);
        } else {
            return error.InvalidArguments;
        }
    }
    if (options.tailscale_https_port != DEFAULT_TAILSCALE_HTTPS_PORT and
        (command == .serve or command == .service_install) and !options.tailscale)
    {
        return error.InvalidArguments;
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
    if (std.mem.eql(u8, first, "tailscale")) return parseNested(argv, 2, .{
        .{ "doctor", .tailscale_doctor }, .{ "status", .tailscale_doctor },
    });
    if (std.mem.eql(u8, first, "connect")) {
        if (argv.len > 2 and std.mem.eql(u8, argv[2], "status")) return .{ .connect_status, 3 };
        if (argv.len > 2 and std.mem.eql(u8, argv[2], "unlink")) return .{ .connect_unlink, 3 };
        if (argv.len > 2 and std.mem.eql(u8, argv[2], "logout")) return .{ .connect_logout, 3 };
        return .{ .connect, 2 };
    }
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

fn isConnectAuth(command: Command) bool {
    return command == .connect or command == .connect_unlink or command == .connect_logout;
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
    var defaults = try parse(std.testing.allocator, &.{ "verde-server", "serve" });
    defer deinit(&defaults, std.testing.allocator);
    try std.testing.expectEqual(DEFAULT_GATEWAY_PORT, defaults.gateway_port);

    var tailscale = try parse(std.testing.allocator, &.{ "verde-server", "serve", "--tailscale" });
    defer deinit(&tailscale, std.testing.allocator);
    try std.testing.expect(tailscale.tailscale);
    try std.testing.expectEqual(DEFAULT_TAILSCALE_HTTPS_PORT, tailscale.tailscale_https_port);

    var dedicated = try parse(std.testing.allocator, &.{
        "verde-server", "serve", "--tailscale", "--tailscale-https-port", "8443",
    });
    defer deinit(&dedicated, std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 8443), dedicated.tailscale_https_port);

    var parsed = try parse(std.testing.allocator, &.{ "verde-server", "service", "install", "--gateway-port", "18473", "--no-start" });
    defer deinit(&parsed, std.testing.allocator);
    try std.testing.expectEqual(Command.service_install, parsed.command);
    try std.testing.expectEqual(@as(u16, 18473), parsed.gateway_port);
    try std.testing.expect(parsed.no_start);
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "verde-server", "serve", "--gateway-port", "0" }));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "verde-server", "serve", "--tailscale-https-port", "0" }));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{
        "verde-server", "serve", "--tailscale-https-port", "8443",
    }));
}

test "Tailscale doctor and status aliases are read-only commands" {
    var doctor = try parse(std.testing.allocator, &.{
        "verde-server", "tailscale", "doctor", "--tailscale-https-port", "8443", "--json",
    });
    defer deinit(&doctor, std.testing.allocator);
    try std.testing.expectEqual(Command.tailscale_doctor, doctor.command);
    try std.testing.expectEqual(@as(u16, 8443), doctor.tailscale_https_port);
    try std.testing.expect(doctor.json);

    var status = try parse(std.testing.allocator, &.{ "verde-server", "tailscale", "status" });
    defer deinit(&status, std.testing.allocator);
    try std.testing.expectEqual(Command.tailscale_doctor, status.command);
}

test "Connect onboarding and lifecycle commands are explicit" {
    var bare = try parse(std.testing.allocator, &.{ "verde-server", "connect" });
    defer deinit(&bare, std.testing.allocator);
    try std.testing.expectEqual(Command.connect, bare.command);
    var onboarding = try parse(std.testing.allocator, &.{
        "verde-server",      "connect",           "--control-plane", "https://connect.example.test",
        "--descriptor-file", "/tmp/runtime.json", "--headless",      "--install-service",
    });
    defer deinit(&onboarding, std.testing.allocator);
    try std.testing.expectEqual(Command.connect, onboarding.command);
    try std.testing.expect(onboarding.headless);
    try std.testing.expect(onboarding.install_service);
    var status = try parse(std.testing.allocator, &.{ "verde-server", "connect", "status", "--json" });
    defer deinit(&status, std.testing.allocator);
    try std.testing.expectEqual(Command.connect_status, status.command);
}

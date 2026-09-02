//! Direct SSH argv construction for one desktop-owned runtime relay channel.
//!
//! The user's SSH configuration remains active so host aliases, ProxyJump,
//! IdentityFile, and equivalent user-controlled policy continue to work.
//! Each accepted desktop loopback stream gets a fresh `-W` stdio channel;
//! configured forwards are cleared and OpenSSH connection sharing is disabled
//! so no separate local listener or unowned master can receive gateway bytes.

const std = @import("std");
const profile = @import("profile.zig");

pub const SERVER_ALIVE_INTERVAL_SECONDS: u16 = 15;
pub const SERVER_ALIVE_COUNT_MAX: u8 = 3;
pub const CONNECT_TIMEOUT_SECONDS: u16 = 15;

const SSH_EXECUTABLE = "ssh";
const LOOPBACK_HOST = "127.0.0.1";
const MAX_HOST_BYTES: usize = 255;
const MAX_USER_BYTES: usize = 64;

pub const OwnedArgv = struct {
    argv: []const []const u8,

    pub fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        self.* = undefined;
    }
};

/// Builds a shell-free SSH invocation for one loopback-only stdio forward.
/// Every argv entry is independently allocator-owned.
pub fn buildArgvAlloc(
    allocator: std.mem.Allocator,
    ssh: profile.SshTunnel,
) !OwnedArgv {
    try validate(ssh);

    var ssh_port_buffer: [5]u8 = undefined;
    const ssh_port = try std.fmt.bufPrint(&ssh_port_buffer, "{d}", .{ssh.port});
    var forward_buffer: [32]u8 = undefined;
    const forward = try std.fmt.bufPrint(
        &forward_buffer,
        LOOPBACK_HOST ++ ":{d}",
        .{ssh.remote_gateway_port},
    );
    var interval_buffer: [32]u8 = undefined;
    const server_alive_interval = try std.fmt.bufPrint(
        &interval_buffer,
        "ServerAliveInterval={d}",
        .{SERVER_ALIVE_INTERVAL_SECONDS},
    );
    var count_buffer: [32]u8 = undefined;
    const server_alive_count = try std.fmt.bufPrint(
        &count_buffer,
        "ServerAliveCountMax={d}",
        .{SERVER_ALIVE_COUNT_MAX},
    );

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer deinitArgvList(allocator, &argv);
    try appendOwned(allocator, &argv, SSH_EXECUTABLE);
    try appendOwned(allocator, &argv, "-T");
    try appendOption(allocator, &argv, "BatchMode=yes");
    try appendOption(allocator, &argv, "ExitOnForwardFailure=yes");
    try appendOption(allocator, &argv, "ClearAllForwardings=yes");
    try appendOption(allocator, &argv, "ConnectTimeout=15");
    try appendOption(allocator, &argv, server_alive_interval);
    try appendOption(allocator, &argv, server_alive_count);
    try appendOption(allocator, &argv, "ControlMaster=no");
    try appendOption(allocator, &argv, "ControlPath=none");
    try appendOption(allocator, &argv, "ControlPersist=no");
    try appendOwned(allocator, &argv, "-p");
    try appendOwned(allocator, &argv, ssh_port);
    try appendOwned(allocator, &argv, "-W");
    try appendOwned(allocator, &argv, forward);
    if (ssh.user) |user| {
        try appendOwned(allocator, &argv, "-l");
        try appendOwned(allocator, &argv, user);
    }
    try appendOwned(allocator, &argv, ssh.host);
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

fn validate(ssh: profile.SshTunnel) !void {
    if (ssh.port == 0) return error.InvalidSshPort;
    if (ssh.remote_gateway_port == 0) return error.InvalidRemoteGatewayPort;
    try validateHost(ssh.host);
    if (ssh.user) |user| try validateUser(user);
}

fn validateHost(host: []const u8) !void {
    if (host.len == 0 or host.len > MAX_HOST_BYTES or host[0] == '-' or
        std.mem.trim(u8, host, &std.ascii.whitespace).len != host.len)
    {
        return error.InvalidSshHost;
    }
    for (host) |byte| {
        // Defense in depth for %h expansion by user-configured ProxyCommand
        // and LocalCommand, both of which may be evaluated by a shell.
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "._-:[]", byte) == null)
        {
            return error.InvalidSshHost;
        }
    }
}

fn validateUser(user: []const u8) !void {
    if (user.len == 0 or user.len > MAX_USER_BYTES or user[0] == '-' or
        std.mem.trim(u8, user, &std.ascii.whitespace).len != user.len)
    {
        return error.InvalidSshUser;
    }
    for (user) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') {
            return error.InvalidSshUser;
        }
    }
}

fn appendOption(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    option: []const u8,
) !void {
    try appendOwned(allocator, argv, "-o");
    try appendOwned(allocator, argv, option);
}

fn appendOwned(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    arg: []const u8,
) !void {
    const owned = try allocator.dupe(u8, arg);
    errdefer allocator.free(owned);
    try argv.append(allocator, owned);
}

fn deinitArgvList(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8)) void {
    for (argv.items) |arg| allocator.free(arg);
    argv.deinit(allocator);
}

fn expectArgvEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn containsArg(argv: []const []const u8, expected: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, expected)) return true;
    return false;
}

test "SSH stdio relay argv is exact shell-free and loopback-only" {
    var host = "devbox.example".*;
    var user = "verde".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = user[0..],
        .port = 2202,
        .remote_gateway_port = 7420,
    };
    var owned = try buildArgvAlloc(std.testing.allocator, ssh);
    defer owned.deinit(std.testing.allocator);

    const expected = [_][]const u8{
        "ssh",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "ConnectTimeout=15",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        "-o",
        "ControlPersist=no",
        "-p",
        "2202",
        "-W",
        "127.0.0.1:7420",
        "-l",
        "verde",
        "devbox.example",
    };
    try expectArgvEqual(&expected, owned.argv);

    // Ownership is independent of the borrowed profile and no shell text is
    // constructed around either user-controlled field.
    host[0] = 'X';
    user[0] = 'X';
    try std.testing.expectEqualStrings("devbox.example", owned.argv[owned.argv.len - 1]);
    try std.testing.expectEqualStrings("verde", owned.argv[owned.argv.len - 2]);
}

test "SSH argv preserves user config while clearing unrelated forwards" {
    var host = "configured-alias".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = null,
        .port = 22,
        .remote_gateway_port = 7420,
    };
    var owned = try buildArgvAlloc(std.testing.allocator, ssh);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("configured-alias", owned.argv[owned.argv.len - 1]);
    try std.testing.expect(!containsArg(owned.argv, "-F"));
    try std.testing.expect(!containsArg(owned.argv, "StrictHostKeyChecking=yes"));
    try std.testing.expect(containsArg(owned.argv, "ClearAllForwardings=yes"));
    try std.testing.expect(containsArg(owned.argv, "-W"));
    try std.testing.expect(!containsArg(owned.argv, "-L"));
    try std.testing.expect(containsArg(owned.argv, "ControlMaster=no"));
    try std.testing.expect(containsArg(owned.argv, "ControlPath=none"));
    try std.testing.expect(containsArg(owned.argv, "ControlPersist=no"));
}

test "SSH argv rejects invalid ports and option-shaped destinations" {
    var host = "devbox".*;
    var user = "verde".*;
    var ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = user[0..],
        .port = 22,
        .remote_gateway_port = 7420,
    };
    ssh.port = 0;
    try std.testing.expectError(error.InvalidSshPort, buildArgvAlloc(std.testing.allocator, ssh));
    ssh.port = 22;
    ssh.remote_gateway_port = 0;
    try std.testing.expectError(error.InvalidRemoteGatewayPort, buildArgvAlloc(std.testing.allocator, ssh));
    ssh.remote_gateway_port = 7420;

    var option_host = "-oProxyCommand".*;
    ssh.host = option_host[0..];
    try std.testing.expectError(error.InvalidSshHost, buildArgvAlloc(std.testing.allocator, ssh));
    const unsafe_hosts = [_][]const u8{
        "vm;touch-pwn",
        "vm$(touch-pwn)",
        "vm`touch-pwn`",
        "vm|touch-pwn",
        "%h",
        "vm%r",
        "vm%p",
        "%",
    };
    for (unsafe_hosts) |unsafe_host| {
        ssh.host = @constCast(unsafe_host);
        try std.testing.expectError(
            error.InvalidSshHost,
            buildArgvAlloc(std.testing.allocator, ssh),
        );
    }
    ssh.host = host[0..];
    var option_user = "-root".*;
    ssh.user = option_user[0..];
    try std.testing.expectError(error.InvalidSshUser, buildArgvAlloc(std.testing.allocator, ssh));
}

fn checkAllocationFailures(allocator: std.mem.Allocator) !void {
    var host = "devbox.example".*;
    var user = "verde".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = user[0..],
        .port = 2202,
        .remote_gateway_port = 7420,
    };
    var owned = try buildArgvAlloc(allocator, ssh);
    owned.deinit(allocator);
}

test "SSH argv cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailures, .{});
}

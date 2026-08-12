//! Gateway bind, auth, and daemon-endpoint settings.

const std = @import("std");

const Self = @This();

pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 7420;
pub const SESSIONIZER_SOCKET_NAME = "verde-sessionizer.sock";
pub const LIVE_SOCKET_NAME = "verde.sock";
pub const SESSIONIZER_SOCKET_ENV = "VERDE_SESSIONIZER_SOCKET";
pub const LIVE_ENDPOINT_ENV = "VERDE_LIVE_ENDPOINT";
pub const LIVE_SOCKET_LEGACY_ENV = "VERDE_LIVE_SOCKET";

host: []const u8 = DEFAULT_HOST,
port: u16 = DEFAULT_PORT,
token: []const u8 = "",
pref_path: []const u8 = "",
sessionizer_endpoint: []const u8 = "",
live_endpoint: []const u8 = "",
static_dir: []const u8 = "",
allow_mock: bool = true,

pub fn parse(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !Self {
    var config: Self = .{};

    if (env.get("VERDE_WEB_HOST")) |value| config.host = value;
    if (try parsePort(env.get("VERDE_WEB_PORT"))) |value| config.port = value;
    if (env.get("VERDE_WEB_TOKEN")) |value| config.token = value;
    if (env.get("VERDE_PREF_PATH")) |value| config.pref_path = value;
    if (env.get("VERDE_WEB_STATIC")) |value| config.static_dir = value;
    if (env.get(SESSIONIZER_SOCKET_ENV)) |value| config.sessionizer_endpoint = value;
    if (env.get(LIVE_ENDPOINT_ENV)) |value| config.live_endpoint = value;
    if (config.live_endpoint.len == 0) {
        if (env.get(LIVE_SOCKET_LEGACY_ENV)) |value| config.live_endpoint = value;
    }
    if (env.get("VERDE_WEB_NO_MOCK")) |_| config.allow_mock = false;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eqlAny(arg, &.{ "--help", "-h" })) {
            return error.HelpRequested;
        } else if (takeValue(args, &index, arg, "--host")) |value| {
            config.host = value;
        } else if (takeValue(args, &index, arg, "--port")) |value| {
            config.port = try parsePortRequired(value);
        } else if (takeValue(args, &index, arg, "--token")) |value| {
            config.token = value;
        } else if (takeValue(args, &index, arg, "--pref-path")) |value| {
            config.pref_path = value;
        } else if (takeValue(args, &index, arg, "--sessionizer")) |value| {
            config.sessionizer_endpoint = value;
        } else if (takeValue(args, &index, arg, "--live")) |value| {
            config.live_endpoint = value;
        } else if (takeValue(args, &index, arg, "--static")) |value| {
            config.static_dir = value;
        } else if (std.mem.eql(u8, arg, "--no-mock")) {
            config.allow_mock = false;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    if (config.pref_path.len == 0) {
        config.pref_path = try defaultPrefPath(allocator, env);
    }
    if (config.sessionizer_endpoint.len == 0) {
        config.sessionizer_endpoint = try std.fs.path.join(allocator, &.{ config.pref_path, SESSIONIZER_SOCKET_NAME });
    }
    if (config.live_endpoint.len == 0) {
        config.live_endpoint = try std.fs.path.join(allocator, &.{ config.pref_path, LIVE_SOCKET_NAME });
    }
    if (config.static_dir.len == 0) {
        config.static_dir = try resolveStaticDir(allocator);
    }
    return config;
}

pub fn printUsage() void {
    std.debug.print(
        \\verde-web — local HTTP/WebSocket gateway for the Verde headless daemon
        \\
        \\Usage: verde-web [options]
        \\
        \\Options:
        \\  --host <addr>         Bind address (default 127.0.0.1)
        \\  --port <n>            Bind port (default 7420)
        \\  --token <secret>      Optional shared token for /api and /ws
        \\  --pref-path <dir>     Verde data dir (default ~/.local/share/verde/Native)
        \\  --sessionizer <path>  Session-daemon unix socket
        \\  --live <path>         Desktop live-control socket
        \\  --static <dir>        Built Solid SPA directory
        \\  --no-mock             Fail instead of serving a review snapshot
        \\
        \\Environment: VERDE_WEB_HOST, VERDE_WEB_PORT, VERDE_WEB_TOKEN,
        \\VERDE_PREF_PATH, VERDE_WEB_STATIC, VERDE_SESSIONIZER_SOCKET,
        \\VERDE_LIVE_ENDPOINT, VERDE_WEB_NO_MOCK
        \\
    , .{});
}

pub fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "::1");
}

fn defaultPrefPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        const trimmed = std.mem.trim(u8, xdg, &std.ascii.whitespace);
        if (trimmed.len > 0) return std.fs.path.join(allocator, &.{ trimmed, "verde", "Native" });
    }
    const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "verde", "Native" });
}

fn resolveStaticDir(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "dist");
}

fn takeValue(args: []const []const u8, index: *usize, arg: []const u8, flag: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, arg, flag)) return null;
    if (index.* + 1 >= args.len) return null;
    index.* += 1;
    return args[index.*];
}

fn eqlAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
}

fn parsePort(raw: ?[]const u8) !?u16 {
    const value = raw orelse return null;
    return try parsePortRequired(value);
}

fn parsePortRequired(raw: []const u8) !u16 {
    const parsed = std.fmt.parseInt(u16, raw, 10) catch return error.InvalidPort;
    if (parsed == 0) return error.InvalidPort;
    return parsed;
}

test "loopback detection" {
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("localhost"));
    try std.testing.expect(!isLoopback("0.0.0.0"));
}

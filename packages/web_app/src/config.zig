//! Gateway bind, authentication-file, and daemon-endpoint settings.

const std = @import("std");

const Self = @This();

pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 7420;
pub const SESSIONIZER_SOCKET_NAME = "verde-sessionizer.sock";
pub const SESSIONIZER_SOCKET_ENV = "VERDE_SESSIONIZER_SOCKET";
pub const TOKEN_FILE_ENV = "VERDE_WEB_TOKEN_FILE";
pub const TRUSTED_PROXY_ORIGIN_ENV = "VERDE_WEB_TRUSTED_PROXY_ORIGIN";

host: []const u8 = DEFAULT_HOST,
port: u16 = DEFAULT_PORT,
token_file: []const u8 = "",
pref_path: []const u8 = "",
sessionizer_endpoint: []const u8 = "",
static_dir: []const u8 = "",
/// Exact public HTTPS origin supplied by the only trusted loopback proxy.
/// Empty keeps the original SSH/loopback request-envelope policy.
trusted_proxy_origin: []const u8 = "",

/// Parses the loopback gateway and optional trusted HTTPS proxy profile.
///
/// Authentication is deliberately file-based so secrets never appear in
/// process arguments, URLs, or the inherited environment. The listener stays
/// on loopback for both SSH forwards and an explicitly named local proxy.
pub fn parse(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !Self {
    try rejectLegacyEnvironment(env);

    var config: Self = .{};
    if (env.get("VERDE_WEB_HOST")) |value| config.host = value;
    if (try parsePort(env.get("VERDE_WEB_PORT"))) |value| config.port = value;
    if (env.get(TOKEN_FILE_ENV)) |value| config.token_file = value;
    if (env.get("VERDE_PREF_PATH")) |value| config.pref_path = value;
    if (env.get("VERDE_WEB_STATIC")) |value| config.static_dir = value;
    if (env.get(TRUSTED_PROXY_ORIGIN_ENV)) |value| config.trusted_proxy_origin = value;
    if (env.get(SESSIONIZER_SOCKET_ENV)) |value| config.sessionizer_endpoint = value;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eqlAny(arg, &.{ "--help", "-h" })) {
            return error.HelpRequested;
        } else if (rawTokenArgument(arg)) {
            return error.RawTokenForbidden;
        } else if (legacyBackendArgument(arg)) {
            return error.LegacyBackendForbidden;
        } else if (try takeValue(args, &index, arg, "--host")) |value| {
            config.host = value;
        } else if (try takeValue(args, &index, arg, "--port")) |value| {
            config.port = try parsePortRequired(value);
        } else if (try takeValue(args, &index, arg, "--token-file")) |value| {
            config.token_file = value;
        } else if (try takeValue(args, &index, arg, "--pref-path")) |value| {
            config.pref_path = value;
        } else if (try takeValue(args, &index, arg, "--sessionizer")) |value| {
            config.sessionizer_endpoint = value;
        } else if (try takeValue(args, &index, arg, "--static")) |value| {
            config.static_dir = value;
        } else if (try takeValue(args, &index, arg, "--trusted-proxy-origin")) |value| {
            config.trusted_proxy_origin = value;
        } else {
            // Do not echo an unknown argument: it may contain a secret from a
            // caller using an obsolete `--token=<secret>` spelling.
            return error.InvalidArgument;
        }
    }

    config.host = std.mem.trim(u8, config.host, &std.ascii.whitespace);
    config.token_file = std.mem.trim(u8, config.token_file, &std.ascii.whitespace);
    config.trusted_proxy_origin = std.mem.trim(u8, config.trusted_proxy_origin, &std.ascii.whitespace);
    if (!isLoopback(config.host)) return error.NonLoopbackHost;
    if (std.ascii.eqlIgnoreCase(config.host, "localhost")) config.host = DEFAULT_HOST;
    if (config.token_file.len == 0) return error.TokenFileRequired;
    if (config.trusted_proxy_origin.len > 0) try validateTrustedProxyOrigin(config.trusted_proxy_origin);

    if (config.pref_path.len == 0) {
        config.pref_path = try defaultPrefPath(allocator, env);
    }
    if (config.sessionizer_endpoint.len == 0) {
        config.sessionizer_endpoint = try std.fs.path.join(allocator, &.{ config.pref_path, SESSIONIZER_SOCKET_NAME });
    }
    if (config.static_dir.len == 0) {
        config.static_dir = try resolveStaticDir(allocator);
    }
    return config;
}

pub fn printUsage() void {
    std.debug.print(
        \\verde-web — loopback HTTP/WebSocket gateway for the Verde headless daemon
        \\
        \\Usage: verde-web --token-file <path> [options]
        \\
        \\Options:
        \\  --host <addr>         Loopback bind address (default 127.0.0.1)
        \\  --port <n>            Bind port (default 7420)
        \\  --token-file <path>   Required owner-only file containing the login token
        \\  --pref-path <dir>     Verde data dir (default ~/.local/share/verde/Native)
        \\  --sessionizer <path>  Session-daemon unix socket
        \\  --static <dir>        Built Solid SPA directory
        \\  --trusted-proxy-origin <https-origin>
        \\                        Trust exact forwarded HTTPS host/origin from a loopback proxy
        \\
        \\Environment: VERDE_WEB_HOST, VERDE_WEB_PORT, VERDE_WEB_TOKEN_FILE,
        \\VERDE_PREF_PATH, VERDE_WEB_STATIC, VERDE_SESSIONIZER_SOCKET,
        \\VERDE_WEB_TRUSTED_PROXY_ORIGIN
        \\
        \\The listener always remains loopback-only. Use an SSH local-forward,
        \\or explicitly name the HTTPS origin of one trusted loopback proxy.
        \\
    , .{});
}

/// Return the exact public authority configured for trusted proxy headers.
pub fn trustedProxyAuthority(self: Self) ?[]const u8 {
    if (self.trusted_proxy_origin.len == 0) return null;
    return self.trusted_proxy_origin["https://".len..];
}

fn validateTrustedProxyOrigin(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "https://") or value.len <= "https://".len) {
        return error.InvalidTrustedProxyOrigin;
    }
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidTrustedProxyOrigin;
    const uri = std.Uri.parse(value) catch return error.InvalidTrustedProxyOrigin;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null)
    {
        return error.InvalidTrustedProxyOrigin;
    }
}

pub fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "::1");
}

fn rejectLegacyEnvironment(env: *const std.process.Environ.Map) !void {
    if (env.contains("VERDE_WEB_TOKEN")) return error.RawTokenForbidden;
    if (env.contains("VERDE_LIVE_ENDPOINT") or
        env.contains("VERDE_LIVE_SOCKET") or
        env.contains("VERDE_WEB_NO_MOCK"))
    {
        return error.LegacyBackendForbidden;
    }
}

fn rawTokenArgument(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--token") or
        std.mem.startsWith(u8, arg, "--token=");
}

fn legacyBackendArgument(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--live") or
        std.mem.startsWith(u8, arg, "--live=") or
        std.mem.eql(u8, arg, "--no-mock");
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

fn takeValue(
    args: []const []const u8,
    index: *usize,
    arg: []const u8,
    flag: []const u8,
) !?[]const u8 {
    if (!std.mem.eql(u8, arg, flag)) return null;
    if (index.* + 1 >= args.len) return error.MissingArgumentValue;
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

test "loopback detection is intentionally strict" {
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("localhost"));
    try std.testing.expect(isLoopback("::1"));
    try std.testing.expect(!isLoopback("0.0.0.0"));
    try std.testing.expect(!isLoopback("192.0.2.1"));
}

test "token file is mandatory" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/verde-config-test");

    try std.testing.expectError(
        error.TokenFileRequired,
        parse(std.testing.allocator, &env, &.{"verde-web"}),
    );
}

test "raw token and legacy backend configuration are rejected" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/verde-config-test");
    try env.put("VERDE_WEB_TOKEN", "do-not-accept-this");
    try std.testing.expectError(
        error.RawTokenForbidden,
        parse(std.testing.allocator, &env, &.{ "verde-web", "--token-file", "/token" }),
    );
    _ = env.swapRemove("VERDE_WEB_TOKEN");

    try std.testing.expectError(
        error.RawTokenForbidden,
        parse(std.testing.allocator, &env, &.{ "verde-web", "--token=do-not-log-this" }),
    );
    try std.testing.expectError(
        error.LegacyBackendForbidden,
        parse(std.testing.allocator, &env, &.{ "verde-web", "--live", "/tmp/verde.sock" }),
    );
}

test "non-loopback host is rejected" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/verde-config-test");

    try std.testing.expectError(
        error.NonLoopbackHost,
        parse(std.testing.allocator, &env, &.{
            "verde-web",
            "--host",
            "0.0.0.0",
            "--token-file",
            "/token",
        }),
    );
}

test "environment token file configures a loopback gateway" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/verde-config-test");
    try env.put(TOKEN_FILE_ENV, "/tmp/verde-token");

    const parsed = try parse(std.testing.allocator, &env, &.{"verde-web"});
    defer std.testing.allocator.free(parsed.pref_path);
    defer std.testing.allocator.free(parsed.sessionizer_endpoint);
    defer std.testing.allocator.free(parsed.static_dir);
    try std.testing.expectEqualStrings(DEFAULT_HOST, parsed.host);
    try std.testing.expectEqualStrings("/tmp/verde-token", parsed.token_file);
}

test "localhost bind normalizes to a numeric loopback address" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/verde-config-test");

    const parsed = try parse(std.testing.allocator, &env, &.{
        "verde-web",
        "--host",
        "localhost",
        "--token-file",
        "/tmp/verde-token",
    });
    defer std.testing.allocator.free(parsed.pref_path);
    defer std.testing.allocator.free(parsed.sessionizer_endpoint);
    defer std.testing.allocator.free(parsed.static_dir);
    try std.testing.expectEqualStrings(DEFAULT_HOST, parsed.host);
}

test "trusted proxy mode requires one exact pathless HTTPS origin" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/verde-config-test");

    const parsed = try parse(std.testing.allocator, &env, &.{
        "verde-web",
        "--token-file",
        "/tmp/verde-token",
        "--trusted-proxy-origin",
        "https://runtime.example.test:8443",
    });
    defer std.testing.allocator.free(parsed.pref_path);
    defer std.testing.allocator.free(parsed.sessionizer_endpoint);
    defer std.testing.allocator.free(parsed.static_dir);
    try std.testing.expectEqualStrings("runtime.example.test:8443", parsed.trustedProxyAuthority().?);

    try std.testing.expectError(error.InvalidTrustedProxyOrigin, parse(std.testing.allocator, &env, &.{
        "verde-web", "--token-file", "/tmp/verde-token", "--trusted-proxy-origin", "http://runtime.example.test",
    }));
    try std.testing.expectError(error.InvalidTrustedProxyOrigin, parse(std.testing.allocator, &env, &.{
        "verde-web", "--token-file", "/tmp/verde-token", "--trusted-proxy-origin", "https://runtime.example.test/path",
    }));
}

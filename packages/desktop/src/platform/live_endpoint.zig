//! Shared live-control endpoint discovery for the desktop app and CLI.

const std = @import("std");
const builtin = @import("builtin");

pub const SOCKET_NAME = "verde.sock";
pub const WINDOWS_PIPE_PREFIX = "\\\\.\\pipe\\verde-live-";
pub const ENDPOINT_ENV = "VERDE_LIVE_ENDPOINT";
pub const LEGACY_UNIX_SOCKET_ENV = "VERDE_LIVE_SOCKET";

pub fn transportName() []const u8 {
    return transportNameForOs(builtin.os.tag);
}

pub fn transportNameForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "windows_named_pipe" else "unix_socket";
}

/// Resolves an explicit endpoint override, then the platform default.
pub fn alloc(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    return allocForOsAndEnv(allocator, builtin.os.tag, pref_path, &env_map);
}

pub fn allocForOs(allocator: std.mem.Allocator, comptime os_tag: std.Target.Os.Tag, pref_path: []const u8) ![]u8 {
    return allocForOsAndEnv(allocator, os_tag, pref_path, EmptyEnv{});
}

fn allocForOsAndEnv(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    pref_path: []const u8,
    env: anytype,
) ![]u8 {
    if (nonEmptyEnv(env, ENDPOINT_ENV)) |endpoint| return allocator.dupe(u8, endpoint);
    if (os_tag != .windows) {
        if (nonEmptyEnv(env, LEGACY_UNIX_SOCKET_ENV)) |socket| return allocator.dupe(u8, socket);
        return std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
    }

    // The SDL pref path is current-user-specific. Hashing it avoids invalid
    // pipe-name characters while keeping GUI and CLI endpoint discovery stable.
    const hash_input = normalizePrefPathForEndpoint(.windows, pref_path);
    const hash = std.hash.Wyhash.hash(0, hash_input);
    return std.fmt.allocPrint(allocator, "{s}{x:0>16}", .{ WINDOWS_PIPE_PREFIX, hash });
}

fn currentEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

fn nonEmptyEnv(env: anytype, name: []const u8) ?[]const u8 {
    const raw = env.get(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

fn normalizePrefPathForEndpoint(comptime os_tag: std.Target.Os.Tag, pref_path: []const u8) []const u8 {
    const is_sep = switch (os_tag) {
        .windows => struct {
            fn call(byte: u8) bool {
                return byte == '\\' or byte == '/';
            }
        }.call,
        else => struct {
            fn call(byte: u8) bool {
                return byte == '/';
            }
        }.call,
    };

    var end = pref_path.len;
    while (end > 0 and is_sep(pref_path[end - 1])) : (end -= 1) {}
    return if (end == 0) pref_path else pref_path[0..end];
}

const EmptyEnv = struct {
    fn get(_: EmptyEnv, _: []const u8) ?[]const u8 {
        return null;
    }
};

const FakeEnv = struct {
    endpoint: ?[]const u8 = null,
    legacy_socket: ?[]const u8 = null,

    fn get(self: FakeEnv, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, ENDPOINT_ENV)) return self.endpoint;
        if (std.mem.eql(u8, name, LEGACY_UNIX_SOCKET_ENV)) return self.legacy_socket;
        return null;
    }
};

test "windows endpoint is stable and accepts a transport-neutral override" {
    const allocator = std.testing.allocator;
    const pref = "C:\\Users\\Test User\\AppData\\Roaming\\verde\\Native";
    const endpoint = try allocForOs(allocator, .windows, pref);
    defer allocator.free(endpoint);
    try std.testing.expect(std.mem.startsWith(u8, endpoint, WINDOWS_PIPE_PREFIX));

    const trailing = try allocForOs(allocator, .windows, pref ++ "\\");
    defer allocator.free(trailing);
    try std.testing.expectEqualStrings(endpoint, trailing);

    const override = try allocForOsAndEnv(allocator, .windows, pref, FakeEnv{ .endpoint = "\\\\.\\pipe\\verde-test" });
    defer allocator.free(override);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\verde-test", override);
}

test "Unix endpoint preserves the legacy socket override" {
    const allocator = std.testing.allocator;
    const endpoint = try allocForOsAndEnv(allocator, .linux, "/tmp/verde", FakeEnv{ .legacy_socket = "/tmp/custom.sock" });
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("/tmp/custom.sock", endpoint);
    try std.testing.expectEqualStrings("unix_socket", transportNameForOs(.linux));
    try std.testing.expectEqualStrings("windows_named_pipe", transportNameForOs(.windows));
}

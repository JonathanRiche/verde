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

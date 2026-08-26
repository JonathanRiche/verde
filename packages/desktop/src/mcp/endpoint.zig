//! Persistent loopback endpoint metadata shared by the daemon and providers.

const std = @import("std");
const builtin = @import("builtin");

pub const FILE_NAME = "mcp-endpoint.json";
pub const DEFAULT_PORT: u16 = 47_371;
pub const PORT_SCAN_COUNT: u16 = 32;
const MAX_FILE_BYTES = 16 * 1024;
const TOKEN_BYTE_LEN = 32;
pub const TOKEN_HEX_LEN = TOKEN_BYTE_LEN * 2;

pub const Endpoint = struct {
    port: u16,
    token: []u8,

    pub fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        self.* = undefined;
    }

    pub fn urlAlloc(self: Endpoint, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{self.port});
    }

    pub fn authorizationAlloc(self: Endpoint, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "Bearer {s}", .{self.token});
    }
};

pub fn pathAlloc(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ pref_path, FILE_NAME });
}

/// Loads the stable endpoint identity when it exists and is well formed.
pub fn load(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8) !?Endpoint {
    const path = try pathAlloc(allocator, pref_path);
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_FILE_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const port = jsonPort(parsed.value.object.get("port") orelse .null) orelse return null;
    const token_value = parsed.value.object.get("token") orelse return null;
    if (token_value != .string or !validToken(token_value.string)) return null;
    return .{ .port = port, .token = try allocator.dupe(u8, token_value.string) };
}

/// Creates a new cryptographic identity or updates only the bound port while
/// retaining the existing token so provider reconnects survive daemon restarts.
pub fn loadOrCreateForPort(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    port: u16,
) !Endpoint {
    var endpoint = if (try load(allocator, io, pref_path)) |existing|
        existing
    else blk: {
        var token_bytes: [TOKEN_BYTE_LEN]u8 = undefined;
        try io.randomSecure(&token_bytes);
        const token_hex = std.fmt.bytesToHex(token_bytes, .lower);
        break :blk Endpoint{
            .port = port,
            .token = try allocator.dupe(u8, &token_hex),
        };
    };
    errdefer endpoint.deinit(allocator);
    endpoint.port = port;
    try save(allocator, io, pref_path, endpoint);
    return endpoint;
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    endpoint: Endpoint,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, pref_path);
    const path = try pathAlloc(allocator, pref_path);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{
        .version = @as(u8, 1),
        .host = "127.0.0.1",
        .port = endpoint.port,
        .token = endpoint.token,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);

    const private_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = private_permissions });
        defer file.close(io);
        try file.writeStreamingAll(io, encoded);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

fn jsonPort(value: std.json.Value) ?u16 {
    return switch (value) {
        .integer => |number| if (number > 0 and number <= std.math.maxInt(u16)) @intCast(number) else null,
        .number_string => |text| std.fmt.parseInt(u16, text, 10) catch null,
        else => null,
    };
}

fn validToken(token: []const u8) bool {
    if (token.len != TOKEN_HEX_LEN) return false;
    for (token) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

test "endpoint metadata round trips with a private stable token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(pref_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var first = try loadOrCreateForPort(std.testing.allocator, threaded.io(), pref_path, 47_371);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, TOKEN_HEX_LEN), first.token.len);

    var second = try loadOrCreateForPort(std.testing.allocator, threaded.io(), pref_path, 47_372);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 47_372), second.port);
    try std.testing.expectEqualStrings(first.token, second.token);
}

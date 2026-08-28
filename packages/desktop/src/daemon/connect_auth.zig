//! Owner-only Connect credential handoff and durable token storage.

const std = @import("std");
const builtin = @import("builtin");

pub const FILE_NAME = "connect-control-plane.token";
const MIN_TOKEN_BYTES: usize = 32;
const MAX_TOKEN_BYTES: usize = 4096;
const PRIVATE_PERMISSIONS: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    @enumFromInt(0o600);

pub const Token = struct {
    bytes: []u8,

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.bytes);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Import from a no-follow owner-only file, persist atomically, and return a
/// mutable copy for the immediate bounded login validation request.
pub fn importCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    source_path: []const u8,
) !Token {
    if (!std.fs.path.isAbsolute(source_path)) return error.InvalidCredentialFile;
    var source = try std.Io.Dir.cwd().openFile(io, source_path, .{ .follow_symlinks = false });
    defer source.close(io);
    try validatePrivateFile(try source.stat(io));
    var source_buffer: [MAX_TOKEN_BYTES + 2]u8 = undefined;
    var source_reader = source.reader(io, &source_buffer);
    const raw = try source_reader.interface.allocRemaining(allocator, .limited(MAX_TOKEN_BYTES + 2));
    defer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
    try validateToken(trimmed);
    const token = try allocator.dupe(u8, trimmed);
    errdefer {
        std.crypto.secureZero(u8, token);
        allocator.free(token);
    }
    try store(io, data_dir, token);
    return .{ .bytes = token };
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Token {
    const path = try std.fs.path.join(allocator, &.{ data_dir, FILE_NAME });
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    try validatePrivateFile(try file.stat(io));
    var file_buffer: [MAX_TOKEN_BYTES + 1]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const raw = try file_reader.interface.allocRemaining(allocator, .limited(MAX_TOKEN_BYTES + 1));
    errdefer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    const trimmed = std.mem.trimEnd(u8, raw, "\n");
    try validateToken(trimmed);
    if (trimmed.len == raw.len) return .{ .bytes = raw };
    const token = try allocator.dupe(u8, trimmed);
    std.crypto.secureZero(u8, raw);
    allocator.free(raw);
    return .{ .bytes = token };
}

pub fn remove(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ data_dir, FILE_NAME });
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn store(io: std.Io, data_dir: []const u8, token: []const u8) !void {
    try validateToken(token);
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = builtin.os.tag != .windows });
    defer dir.close(io);
    var random: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &random);
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, ".connect-auth-{s}.tmp", .{@as([]const u8, &suffix)});
    var staged = false;
    errdefer if (staged) dir.deleteFile(io, name) catch {};
    var file = try dir.createFile(io, name, .{
        .exclusive = true,
        .permissions = PRIVATE_PERMISSIONS,
        .resolve_beneath = true,
    });
    staged = true;
    var open = true;
    defer if (open) file.close(io);
    if (builtin.os.tag != .windows) try file.setPermissions(io, PRIVATE_PERMISSIONS);
    try file.writeStreamingAll(io, token);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    file.close(io);
    open = false;
    try dir.rename(name, dir, FILE_NAME, io);
    staged = false;
}

fn validatePrivateFile(stat: std.Io.File.Stat) !void {
    if (stat.kind != .file or stat.size > MAX_TOKEN_BYTES + 2) return error.InvalidCredentialFile;
    if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o077 != 0) {
        return error.InsecureCredentialPermissions;
    }
}

fn validateToken(token: []const u8) !void {
    if (token.len < MIN_TOKEN_BYTES or token.len > MAX_TOKEN_BYTES) return error.InvalidConnectCredential;
    for (token) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidConnectCredential;
}

test "credential handoff requires owner-only file and never retains source buffer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const dir_path = path_buffer[0..path_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "handoff" });
    defer std.testing.allocator.free(source_path);
    var source = try std.Io.Dir.cwd().createFile(std.testing.io, source_path, .{ .permissions = @enumFromInt(0o600) });
    try source.writeStreamingAll(std.testing.io, "0123456789abcdef0123456789abcdef\n");
    source.close(std.testing.io);
    var imported = try importCredential(std.testing.allocator, std.testing.io, dir_path, source_path);
    defer imported.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", imported.bytes);
    var loaded = try load(std.testing.allocator, std.testing.io, dir_path);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(imported.bytes, loaded.bytes);
    try remove(std.testing.allocator, std.testing.io, dir_path);
    try std.testing.expectError(error.FileNotFound, load(std.testing.allocator, std.testing.io, dir_path));
}

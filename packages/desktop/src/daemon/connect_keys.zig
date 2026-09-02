//! Owner-only atomic storage for runtime Connect signing and encryption keys.

const std = @import("std");
const builtin = @import("builtin");

const crypto = @import("connect_crypto.zig");

pub const FILE_NAME = "connect-runtime-keys.json";
const MAX_FILE_BYTES: usize = 4096;
const PRIVATE_PERMISSIONS: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    @enumFromInt(0o600);

const Wire = struct {
    version: u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    signing_seed: []const u8,
    encryption_secret: []const u8,
};

pub fn loadOrCreate(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
) !crypto.RuntimeKeys {
    if (try load(allocator, io, data_dir, runtime_id, instance_id)) |keys| return keys;
    var keys = crypto.RuntimeKeys.generate(io);
    errdefer keys.clear();
    try store(allocator, io, data_dir, runtime_id, instance_id, &keys);
    return keys;
}

pub fn rotate(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
) !crypto.RuntimeKeys {
    var keys = crypto.RuntimeKeys.generate(io);
    errdefer keys.clear();
    try store(allocator, io, data_dir, runtime_id, instance_id, &keys);
    return keys;
}

fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
) !?crypto.RuntimeKeys {
    const path = try std.fs.path.join(allocator, &.{ data_dir, FILE_NAME });
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > MAX_FILE_BYTES) return error.InvalidConnectKeyFile;
    if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o077 != 0) {
        return error.InsecureConnectKeyPermissions;
    }
    var file_buffer: [MAX_FILE_BYTES]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const bytes = try file_reader.interface.allocRemaining(allocator, .limited(MAX_FILE_BYTES));
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    var parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always }) catch
        return error.InvalidConnectKeyFile;
    defer parsed.deinit();
    if (parsed.value.version != 1 or
        !std.mem.eql(u8, parsed.value.runtime_id, runtime_id) or
        !std.mem.eql(u8, parsed.value.instance_id, instance_id)) return error.ConnectKeyIdentityMismatch;
    var signing_seed = decodeFixed(32, parsed.value.signing_seed) catch return error.InvalidConnectKeyFile;
    defer std.crypto.secureZero(u8, &signing_seed);
    var encryption_secret = decodeFixed(32, parsed.value.encryption_secret) catch return error.InvalidConnectKeyFile;
    errdefer std.crypto.secureZero(u8, &encryption_secret);
    const signing = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(signing_seed) catch
        return error.InvalidConnectKeyFile;
    const encryption_public = std.crypto.dh.X25519.recoverPublicKey(encryption_secret) catch
        return error.InvalidConnectKeyFile;
    return .{
        .signing = signing,
        .encryption = .{ .secret_key = encryption_secret, .public_key = encryption_public },
    };
}

fn store(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    keys: *const crypto.RuntimeKeys,
) !void {
    var signing_seed = keys.signing.secret_key.seed();
    defer std.crypto.secureZero(u8, &signing_seed);
    const signing_encoded = try crypto.base64UrlEncodeAlloc(allocator, &signing_seed);
    defer {
        std.crypto.secureZero(u8, signing_encoded);
        allocator.free(signing_encoded);
    }
    const encryption_encoded = try crypto.base64UrlEncodeAlloc(allocator, &keys.encryption.secret_key);
    defer {
        std.crypto.secureZero(u8, encryption_encoded);
        allocator.free(encryption_encoded);
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, Wire{
        .version = 1,
        .runtime_id = runtime_id,
        .instance_id = instance_id,
        .signing_seed = signing_encoded,
        .encryption_secret = encryption_encoded,
    }, .{});
    defer {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = builtin.os.tag != .windows });
    defer dir.close(io);
    var random: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &random);
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    var temp_buffer: [64]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&temp_buffer, ".connect-keys-{s}.tmp", .{@as([]const u8, &suffix)});
    var staged = false;
    errdefer if (staged) dir.deleteFile(io, temp_name) catch {};
    var file = try dir.createFile(io, temp_name, .{
        .exclusive = true,
        .permissions = PRIVATE_PERMISSIONS,
        .resolve_beneath = true,
    });
    staged = true;
    var open = true;
    defer if (open) file.close(io);
    if (builtin.os.tag != .windows) try file.setPermissions(io, PRIVATE_PERMISSIONS);
    try file.writeStreamingAll(io, encoded);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    file.close(io);
    open = false;
    try dir.rename(temp_name, dir, FILE_NAME, io);
    staged = false;
    if (builtin.os.tag != .windows) {
        const dir_file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
        try dir_file.sync(io);
    }
}

fn decodeFixed(comptime size: usize, encoded: []const u8) ![size]u8 {
    var bytes: [size]u8 = undefined;
    if (try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) != size) return error.InvalidLength;
    try std.base64.url_safe_no_pad.Decoder.decode(&bytes, encoded);
    return bytes;
}

test "Connect keys survive restart, reject identity mismatch, and rotate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    const runtime_id = "0123456789abcdef0123456789abcdef";
    const instance_id = "abcdef0123456789abcdef0123456789";
    var first = try loadOrCreate(std.testing.allocator, std.testing.io, path, runtime_id, instance_id);
    const first_public = first.signing.public_key.toBytes();
    first.clear();
    var loaded = try loadOrCreate(std.testing.allocator, std.testing.io, path, runtime_id, instance_id);
    defer loaded.clear();
    try std.testing.expectEqualSlices(u8, &first_public, &loaded.signing.public_key.toBytes());
    try std.testing.expectError(
        error.ConnectKeyIdentityMismatch,
        loadOrCreate(std.testing.allocator, std.testing.io, path, runtime_id, "00000000000000000000000000000000"),
    );
    var rotated = try rotate(std.testing.allocator, std.testing.io, path, runtime_id, instance_id);
    defer rotated.clear();
    try std.testing.expect(!std.mem.eql(u8, &first_public, &rotated.signing.public_key.toBytes()));
}

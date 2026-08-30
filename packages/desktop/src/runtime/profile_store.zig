//! Durable storage for non-secret desktop runtime connection profiles.

const std = @import("std");
const builtin = @import("builtin");
const platform_paths = @import("platform_paths");
const profile = @import("profile.zig");

pub const FILE_NAME = "runtime-profiles.json";

const MAX_DOCUMENT_BYTES: usize = 256 * 1024;
const LOCK_SUFFIX = ".lock";
const TEMP_RANDOM_BYTES: usize = 16;
const TEMP_PREFIX = ".runtime-profiles.";
const TEMP_SUFFIX = ".tmp";
const PRIVATE_FILE_PERMISSIONS: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    @enumFromInt(0o600);

/// Cross-process ownership for one profile load-modify-save transaction.
/// Readers do not need this lock because saves replace the document atomically.
pub const ExclusiveLock = struct {
    io: std.Io,
    file: std.Io.File,

    pub fn deinit(self: *ExclusiveLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

/// Resolves the profile document beside Verde's existing user config file.
pub fn pathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const config_path = try platform_paths.configPath(allocator);
    defer allocator.free(config_path);
    return pathBesideConfigAlloc(allocator, config_path);
}

/// Loads the user's runtime profiles. A missing document represents an empty
/// profile list; malformed and secret-bearing documents fail explicitly.
pub fn load(allocator: std.mem.Allocator) !profile.OwnedProfiles {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    return loadAtPath(allocator, threaded.io(), path);
}

/// Atomically saves the user's non-secret runtime profiles.
pub fn save(allocator: std.mem.Allocator, profiles: []const profile.Profile) !void {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    try saveAtPath(allocator, threaded.io(), path, profiles);
}

/// Blocks until this process exclusively owns profile mutation. Hold the
/// result across both `loadAtPath` and `saveAtPath` so concurrent writers
/// cannot lose one another's changes.
pub fn acquireExclusiveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !ExclusiveLock {
    return (try openExclusiveAtPath(allocator, io, path, false)) orelse unreachable;
}

/// Non-blocking counterpart used by event-loop workers and tests.
pub fn tryAcquireExclusiveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?ExclusiveLock {
    return openExclusiveAtPath(allocator, io, path, true);
}

/// Path-explicit load used by migration, tooling, and hermetic tests.
pub fn loadAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !profile.OwnedProfiles {
    try validateStorePath(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(MAX_DOCUMENT_BYTES + 1),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = try allocator.alloc(profile.Profile, 0) },
        error.StreamTooLong => return error.InvalidProfileDocument,
        else => return err,
    };
    defer allocator.free(bytes);
    return profile.decodeAlloc(allocator, bytes);
}

/// Path-explicit atomic save. Validation and encoding finish before a staging
/// file is created, so those failures cannot disturb the durable document.
pub fn saveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    profiles: []const profile.Profile,
) !void {
    try validateStorePath(path);
    const encoded = try profile.encodeAlloc(allocator, profiles);
    defer allocator.free(encoded);

    const parent_path = std.fs.path.dirname(path) orelse ".";
    var dir = try openOrCreateParentDir(io, parent_path, .{
        // Directory fsync requires a real readable descriptor on POSIX.
        .iterate = builtin.os.tag != .windows,
    });
    defer dir.close(io);

    var random_bytes: [TEMP_RANDOM_BYTES]u8 = undefined;
    try io.randomSecure(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    var temp_name_buffer: [TEMP_PREFIX.len + TEMP_RANDOM_BYTES * 2 + TEMP_SUFFIX.len]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(
        &temp_name_buffer,
        TEMP_PREFIX ++ "{s}" ++ TEMP_SUFFIX,
        .{@as([]const u8, &random_hex)},
    );
    try stageAndReplace(io, dir, std.fs.path.basename(path), temp_name, encoded);
}

fn pathBesideConfigAlloc(allocator: std.mem.Allocator, config_path: []const u8) ![]u8 {
    try validateStorePath(config_path);
    const parent_path = std.fs.path.dirname(config_path) orelse return allocator.dupe(u8, FILE_NAME);
    return std.fs.path.join(allocator, &.{ parent_path, FILE_NAME });
}

fn validateStorePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidRuntimeProfilePath;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return error.InvalidRuntimeProfilePath;
    }
}

fn openExclusiveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    nonblocking: bool,
) !?ExclusiveLock {
    try validateStorePath(path);
    const parent_path = std.fs.path.dirname(path) orelse ".";
    var dir = try openOrCreateParentDir(io, parent_path, .{});
    defer dir.close(io);

    const lock_name = try std.fmt.allocPrint(
        allocator,
        "{s}" ++ LOCK_SUFFIX,
        .{std.fs.path.basename(path)},
    );
    defer allocator.free(lock_name);
    var file = dir.createFile(io, lock_name, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = nonblocking,
        .permissions = PRIVATE_FILE_PERMISSIONS,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    errdefer {
        file.unlock(io);
        file.close(io);
    }
    if (builtin.os.tag != .windows) {
        try file.setPermissions(io, PRIVATE_FILE_PERMISSIONS);
    }
    return .{ .io = io, .file = file };
}

fn openOrCreateParentDir(
    io: std.Io,
    parent_path: []const u8,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    // Config directories commonly point into dotfiles via a symlink, which
    // openDir follows but createDirPath rejects as a final path component.
    return std.Io.Dir.cwd().openDir(io, parent_path, options) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().createDirPath(io, parent_path);
            return std.Io.Dir.cwd().openDir(io, parent_path, options);
        },
        else => return err,
    };
}

fn stageAndReplace(
    io: std.Io,
    dir: std.Io.Dir,
    destination_name: []const u8,
    temp_name: []const u8,
    encoded: []const u8,
) !void {
    var staged = false;
    errdefer if (staged) dir.deleteFile(io, temp_name) catch {};

    var file = try dir.createFile(io, temp_name, .{
        .exclusive = true,
        .permissions = PRIVATE_FILE_PERMISSIONS,
        .resolve_beneath = true,
    });
    staged = true;
    var file_open = true;
    defer if (file_open) file.close(io);

    // An explicit chmod makes the result owner-only even under an unusual
    // process umask; the exclusive create prevents following an old symlink.
    if (builtin.os.tag != .windows) {
        try file.setPermissions(io, PRIVATE_FILE_PERMISSIONS);
    }
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();
    try file.sync(io);
    file.close(io);
    file_open = false;

    try dir.rename(temp_name, dir, destination_name, io);
    staged = false;

    // POSIX rename durability also requires the containing directory metadata
    // to reach disk. std.Io does not expose directory sync on Windows.
    if (builtin.os.tag != .windows) {
        const dir_file: std.Io.File = .{
            .handle = dir.handle,
            .flags = .{ .nonblocking = false },
        };
        try dir_file.sync(io);
    }
}

fn testPathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_len = try dir.realPath(std.testing.io, &absolute_buffer);
    return std.fs.path.join(allocator, &.{ absolute_buffer[0..absolute_len], FILE_NAME });
}

fn writeTestFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

test "profile store path is beside the existing config" {
    const allocator = std.testing.allocator;
    const absolute = try pathBesideConfigAlloc(allocator, "/tmp/verde/verde.json");
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/verde/runtime-profiles.json", absolute);

    const relative = try pathBesideConfigAlloc(allocator, "verde.json");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings(FILE_NAME, relative);
}

test "profile store saves through a symlinked config directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "config-real", .default_dir);
    try tmp.dir.symLink(std.testing.io, "config-real", "config-link", .{});

    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_len = try tmp.dir.realPath(std.testing.io, &absolute_buffer);
    const path = try std.fs.path.join(allocator, &.{
        absolute_buffer[0..absolute_len],
        "config-link",
        FILE_NAME,
    });
    defer allocator.free(path);

    var lock = try acquireExclusiveAtPath(allocator, std.testing.io, path);
    defer lock.deinit();
    try saveAtPath(allocator, std.testing.io, path, &.{});
    var loaded = try loadAtPath(allocator, std.testing.io, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "profile store round trips local and SSH profiles privately" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var local = try profile.Profile.createLocal(allocator, std.testing.io, "Local", null);
    defer local.deinit(allocator);
    var remote = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        "0123456789abcdef0123456789abcdef",
        .{
            .host = "devbox.example",
            .user = "verde",
            .port = 2202,
            .remote_gateway_port = 7421,
        },
    );
    defer remote.deinit(allocator);
    try remote.setExpectedIdentity(
        allocator,
        "0123456789abcdef0123456789abcdef",
        "00112233445566778899aabbccddeeff",
    );

    try saveAtPath(allocator, std.testing.io, path, &.{ local, remote });
    var loaded = try loadAtPath(allocator, std.testing.io, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings(local.id, loaded.items[0].id);
    try std.testing.expectEqualStrings(remote.id, loaded.items[1].id);
    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        loaded.items[1].expected_instance_id.?,
    );
    try std.testing.expectEqualStrings("devbox.example", loaded.items[1].transport.ssh_tunnel.host);

    const raw = try tmp.dir.readFileAlloc(
        std.testing.io,
        FILE_NAME,
        allocator,
        .limited(MAX_DOCUMENT_BYTES + 1),
    );
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "token") == null);
    if (builtin.os.tag != .windows) {
        const stat = try tmp.dir.statFile(std.testing.io, FILE_NAME, .{});
        try std.testing.expectEqual(
            @as(std.posix.mode_t, 0o600),
            stat.permissions.toMode() & @as(std.posix.mode_t, 0o777),
        );
    }
}

test "missing profile store loads an owned empty list" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var loaded = try loadAtPath(allocator, std.testing.io, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "exclusive profile mutation lock rejects a concurrent writer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var first = try acquireExclusiveAtPath(allocator, std.testing.io, path);
    defer first.deinit();
    try std.testing.expect((try tryAcquireExclusiveAtPath(
        allocator,
        std.testing.io,
        path,
    )) == null);

    if (builtin.os.tag != .windows) {
        const stat = try tmp.dir.statFile(std.testing.io, FILE_NAME ++ LOCK_SUFFIX, .{});
        try std.testing.expectEqual(
            @as(std.posix.mode_t, 0o600),
            stat.permissions.toMode() & @as(std.posix.mode_t, 0o777),
        );
    }
}

test "malformed and secret-bearing profile stores fail explicitly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    try writeTestFile(tmp.dir, FILE_NAME, "not-json");
    try std.testing.expectError(
        error.InvalidProfileDocument,
        loadAtPath(allocator, std.testing.io, path),
    );

    try writeTestFile(tmp.dir, FILE_NAME,
        \\{"version":1,"profiles":[],"gateway_token":"sentinel-secret"}
    );
    try std.testing.expectError(
        error.SecretFieldForbidden,
        loadAtPath(allocator, std.testing.io, path),
    );
}

test "staging failure preserves the previous profile document" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original =
        \\{"version":1,"profiles":[]}
    ;
    try writeTestFile(tmp.dir, FILE_NAME, original);
    try tmp.dir.createDir(std.testing.io, "collision.tmp", .default_dir);

    try std.testing.expectError(
        error.PathAlreadyExists,
        stageAndReplace(std.testing.io, tmp.dir, FILE_NAME, "collision.tmp", "replacement"),
    );
    const after = try tmp.dir.readFileAlloc(
        std.testing.io,
        FILE_NAME,
        allocator,
        .limited(MAX_DOCUMENT_BYTES + 1),
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(original, after);
}

fn checkSaveAllocationFailure(allocator: std.mem.Allocator, path: []const u8) !void {
    const local: profile.Profile = .{
        .id = @constCast("profile-0123456789abcdef0123456789abcdef"),
        .label = @constCast("Local"),
        .expected_runtime_id = null,
        .transport = .local_socket,
    };
    saveAtPath(allocator, std.testing.io, path, &.{local}) catch |err| switch (err) {
        // The allocating JSON writer exposes allocation exhaustion through its
        // writer error; normalize it for checkAllAllocationFailures.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}

test "profile store save cleans up allocation failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);
    try std.testing.checkAllAllocationFailures(allocator, checkSaveAllocationFailure, .{path});
}

fn checkLoadAllocationFailure(allocator: std.mem.Allocator, path: []const u8) !void {
    var loaded = try loadAtPath(allocator, std.testing.io, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
}

test "profile store load cleans up allocation failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);
    const document =
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"Local","transport":{"kind":"local_socket"}}]}
    ;
    try writeTestFile(tmp.dir, FILE_NAME, document);
    try std.testing.checkAllAllocationFailures(allocator, checkLoadAllocationFailure, .{path});
}

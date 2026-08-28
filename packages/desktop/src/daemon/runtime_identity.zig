//! Durable daemon runtime and store-incarnation identity.

const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");

const daemon_store = @import("store.zig");
const schema = @import("../db/schema.zig");

pub const FILE_NAME = "runtime-identity.json";
pub const DATABASE_FILE_NAME = "state.sqlite";
const MAX_IDENTITY_FILE_BYTES = 4096;
const TEMP_RANDOM_BYTES = 16;
const TEMP_PREFIX = ".runtime-identity.";
const TEMP_SUFFIX = ".tmp";
const PRIVATE_FILE_PERMISSIONS: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    @enumFromInt(0o600);

const DatabaseState = enum {
    fresh,
    legacy,
    current,
};

pub const OwnedIdentity = struct {
    runtime_id: []u8,
    instance_id: []u8,

    pub fn deinit(self: *OwnedIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_id);
        allocator.free(self.instance_id);
        self.* = undefined;
    }

    pub fn borrowed(self: *const OwnedIdentity) daemon_store.RuntimeIdentity {
        return .{
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
        };
    }
};

/// A store whose schema and identity metadata have committed together.
pub const InitializedStore = struct {
    identity: OwnedIdentity,
    store: daemon_store.Store,
    identity_owned: bool = true,
    store_owned: bool = true,

    pub fn deinit(self: *InitializedStore, allocator: std.mem.Allocator) void {
        if (self.store_owned) self.store.deinit();
        if (self.identity_owned) self.identity.deinit(allocator);
        self.* = undefined;
    }

    pub fn takeIdentity(self: *InitializedStore) OwnedIdentity {
        std.debug.assert(self.identity_owned);
        self.identity_owned = false;
        return self.identity;
    }

    pub fn takeStore(self: *InitializedStore) daemon_store.Store {
        std.debug.assert(self.store_owned);
        self.store_owned = false;
        return self.store;
    }
};

/// Prepare the sidecar, then create/migrate and cross-check the SQLite store.
///
/// The sidecar is replaced first only for an absent/uninitialized database.
/// If a crash happens before SQLite commits, the next start can safely rotate
/// the uncommitted instance again. Once SQLite is v8, neither half is adopted:
/// missing, malformed, partial, or mismatched state fails startup.
pub fn initStore(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    db_path: []const u8,
    fault: daemon_store.StoreFault,
) !InitializedStore {
    try ensurePrivateDirectory(io, data_dir);
    var identity = try prepareStoreIdentity(allocator, io, data_dir, db_path);
    errdefer identity.deinit(allocator);
    const store = try daemon_store.Store.initWithRuntimeIdentity(
        allocator,
        db_path,
        fault,
        identity.borrowed(),
    );
    return .{ .identity = identity, .store = store };
}

/// Secure file-only identity for the explicit store-disabled test mode.
///
/// This mode has no SQLite authority to cross-check or detect store recreation;
/// production startup always uses `initStore`. Missing files mint a fresh pair,
/// while malformed existing files still fail instead of silently rotating.
pub fn loadOrCreateFileOnly(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
) !OwnedIdentity {
    try ensurePrivateDirectory(io, data_dir);
    if (try readIdentityFile(allocator, io, data_dir)) |identity| return identity;

    var identity = try generateIdentity(allocator, io, null);
    errdefer identity.deinit(allocator);
    try writeIdentityFile(allocator, io, data_dir, identity.borrowed());
    return identity;
}

fn prepareStoreIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    db_path: []const u8,
) !OwnedIdentity {
    const database_state = try classifyDatabase(allocator, io, db_path);
    var existing = try readIdentityFile(allocator, io, data_dir);
    switch (database_state) {
        .current => return existing orelse error.RuntimeIdentityFileMissing,
        .legacy => {
            if (existing) |identity| return identity;
            var identity = try generateIdentity(allocator, io, null);
            errdefer identity.deinit(allocator);
            try writeIdentityFile(allocator, io, data_dir, identity.borrowed());
            return identity;
        },
        .fresh => {},
    }
    defer if (existing) |*prior| prior.deinit(allocator);

    var identity = if (existing) |*prior|
        try generateIdentity(allocator, io, prior.runtime_id)
    else
        try generateIdentity(allocator, io, null);
    errdefer identity.deinit(allocator);
    try writeIdentityFile(allocator, io, data_dir, identity.borrowed());
    return identity;
}

fn classifyDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
) !DatabaseState {
    const stat = std.Io.Dir.cwd().statFile(io, db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .fresh,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidRuntimeDatabase;
    if (stat.size == 0) return .fresh;

    const path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path_z);
    const conn = zqlite.open(path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode) catch
        return error.InvalidRuntimeDatabase;
    defer conn.close();
    var row = (conn.row("pragma user_version", .{}) catch return error.InvalidRuntimeDatabase) orelse
        return error.InvalidRuntimeDatabase;
    const version = row.int(0);
    row.deinit();
    if (version < 0) return error.InvalidRuntimeDatabase;
    if (version > schema.MAX_SUPPORTED_VERSION) return error.SchemaTooNew;
    if (version > 0) return if (version < schema.MAX_SUPPORTED_VERSION) .legacy else .current;

    var object_count_row = (conn.row(
        "select count(*) from sqlite_schema where name not like 'sqlite_%'",
        .{},
    ) catch return error.InvalidRuntimeDatabase) orelse return error.InvalidRuntimeDatabase;
    const object_count = object_count_row.int(0);
    object_count_row.deinit();
    if (object_count == 0) return .fresh;

    // Historical Verde databases could predate `pragma user_version` while
    // already carrying the v0 application tables consumed by migrateV0ToV1.
    // Recognize that exact core, but never rotate/adopt an arbitrary nonempty
    // SQLite schema as if it were a freshly created store.
    var legacy_core_row = (conn.row(
        \\select count(*) from sqlite_schema
        \\where type = 'table' and name in ('app_state', 'workspaces', 'threads', 'messages')
    , .{}) catch return error.InvalidRuntimeDatabase) orelse return error.InvalidRuntimeDatabase;
    const legacy_core_count = legacy_core_row.int(0);
    legacy_core_row.deinit();
    if (legacy_core_count == 4) return .legacy;
    return error.InvalidRuntimeDatabase;
}

fn readIdentityFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
) !?OwnedIdentity {
    const path = try std.fs.path.join(allocator, &.{ data_dir, FILE_NAME });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(MAX_IDENTITY_FILE_BYTES),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const WireIdentity = struct {
        version: u8,
        runtime_id: []const u8,
        instance_id: []const u8,
    };
    var parsed = std.json.parseFromSlice(WireIdentity, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRuntimeIdentity;
    defer parsed.deinit();
    if (parsed.value.version != 1 or
        !validIdentityPart(parsed.value.runtime_id) or
        !validIdentityPart(parsed.value.instance_id))
    {
        return error.InvalidRuntimeIdentity;
    }

    const runtime_id = try allocator.dupe(u8, parsed.value.runtime_id);
    errdefer allocator.free(runtime_id);
    return .{
        .runtime_id = runtime_id,
        .instance_id = try allocator.dupe(u8, parsed.value.instance_id),
    };
}

fn generateIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_id: ?[]const u8,
) !OwnedIdentity {
    const owned_runtime_id = if (runtime_id) |existing|
        try allocator.dupe(u8, existing)
    else
        try secureHexId(allocator, io);
    errdefer allocator.free(owned_runtime_id);
    return .{
        .runtime_id = owned_runtime_id,
        .instance_id = try secureHexId(allocator, io),
    };
}

fn secureHexId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    try io.randomSecure(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return allocator.dupe(u8, &hex);
}

fn writeIdentityFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    identity: daemon_store.RuntimeIdentity,
) !void {
    if (!validIdentityPart(identity.runtime_id) or !validIdentityPart(identity.instance_id)) {
        return error.InvalidRuntimeIdentity;
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{
        .version = @as(u8, 1),
        .runtime_id = identity.runtime_id,
        .instance_id = identity.instance_id,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);

    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{
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
    try stageAndReplace(io, dir, temp_name, encoded);
}

fn stageAndReplace(
    io: std.Io,
    dir: std.Io.Dir,
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
    if (builtin.os.tag != .windows) {
        try file.setPermissions(io, PRIVATE_FILE_PERMISSIONS);
    }
    try file.writeStreamingAll(io, encoded);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    file.close(io);
    file_open = false;

    try dir.rename(temp_name, dir, FILE_NAME, io);
    staged = false;
    // The payload is synced before replacement on every platform. POSIX also
    // exposes a syncable directory descriptor; std.Io has no Windows
    // directory-sync operation, so do not claim stronger rename durability
    // there than the platform's atomic replace provides.
    if (builtin.os.tag != .windows) {
        const dir_file: std.Io.File = .{
            .handle = dir.handle,
            .flags = .{ .nonblocking = false },
        };
        try dir_file.sync(io);
    }
}

fn ensurePrivateDirectory(io: std.Io, path: []const u8) !void {
    if (path.len == 0) return error.InvalidRuntimeIdentityDirectory;
    try std.Io.Dir.cwd().createDirPath(io, path);
    if (builtin.os.tag == .windows) return;
    try std.Io.Dir.cwd().setFilePermissions(io, path, @enumFromInt(0o700), .{
        .follow_symlinks = true,
    });
}

fn validIdentityPart(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

const TestPaths = struct {
    dir: []u8,
    db: []u8,
};

fn testPaths(tmp: *std.testing.TmpDir) !TestPaths {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir = try std.testing.allocator.dupe(u8, path_buf[0..path_len]);
    errdefer std.testing.allocator.free(dir);
    return .{
        .dir = dir,
        .db = try std.fs.path.join(std.testing.allocator, &.{ dir, DATABASE_FILE_NAME }),
    };
}

fn freeTestPaths(paths: TestPaths) void {
    std.testing.allocator.free(paths.db);
    std.testing.allocator.free(paths.dir);
}

test "durable store identity is stable across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var first = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    const runtime_id = try std.testing.allocator.dupe(u8, first.identity.runtime_id);
    defer std.testing.allocator.free(runtime_id);
    const instance_id = try std.testing.allocator.dupe(u8, first.identity.instance_id);
    defer std.testing.allocator.free(instance_id);
    first.deinit(std.testing.allocator);

    var second = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(runtime_id, second.identity.runtime_id);
    try std.testing.expectEqualStrings(instance_id, second.identity.instance_id);
}

test "separate new stores receive separate secure identities" {
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    const first_paths = try testPaths(&first_tmp);
    defer freeTestPaths(first_paths);
    const second_paths = try testPaths(&second_tmp);
    defer freeTestPaths(second_paths);

    var first = try initStore(std.testing.allocator, std.testing.io, first_paths.dir, first_paths.db, .none);
    defer first.deinit(std.testing.allocator);
    var second = try initStore(std.testing.allocator, std.testing.io, second_paths.dir, second_paths.db, .none);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.identity.runtime_id, second.identity.runtime_id));
    try std.testing.expect(!std.mem.eql(u8, first.identity.instance_id, second.identity.instance_id));
}

test "deleting state database preserves runtime and rotates instance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var first = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    const runtime_id = try std.testing.allocator.dupe(u8, first.identity.runtime_id);
    defer std.testing.allocator.free(runtime_id);
    const instance_id = try std.testing.allocator.dupe(u8, first.identity.instance_id);
    defer std.testing.allocator.free(instance_id);
    first.deinit(std.testing.allocator);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, paths.db);

    var recreated = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    defer recreated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(runtime_id, recreated.identity.runtime_id);
    try std.testing.expect(!std.mem.eql(u8, instance_id, recreated.identity.instance_id));
}

test "mismatched database and identity file fail without adoption" {
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    const first_paths = try testPaths(&first_tmp);
    defer freeTestPaths(first_paths);
    const second_paths = try testPaths(&second_tmp);
    defer freeTestPaths(second_paths);

    var first = try initStore(std.testing.allocator, std.testing.io, first_paths.dir, first_paths.db, .none);
    const first_runtime_id = try std.testing.allocator.dupe(u8, first.identity.runtime_id);
    defer std.testing.allocator.free(first_runtime_id);
    const first_instance_id = try std.testing.allocator.dupe(u8, first.identity.instance_id);
    defer std.testing.allocator.free(first_instance_id);
    first.deinit(std.testing.allocator);
    var second = try initStore(std.testing.allocator, std.testing.io, second_paths.dir, second_paths.db, .none);
    defer second.deinit(std.testing.allocator);

    try writeIdentityFile(std.testing.allocator, std.testing.io, first_paths.dir, second.identity.borrowed());
    try std.testing.expectError(
        error.RuntimeIdentityMismatch,
        initStore(std.testing.allocator, std.testing.io, first_paths.dir, first_paths.db, .none),
    );

    // Restoring the matching pair succeeds; the failed open changed neither DB.
    try writeIdentityFile(std.testing.allocator, std.testing.io, first_paths.dir, .{
        .runtime_id = first_runtime_id,
        .instance_id = first_instance_id,
    });
    var restored = try initStore(std.testing.allocator, std.testing.io, first_paths.dir, first_paths.db, .none);
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first_runtime_id, restored.identity.runtime_id);
    try std.testing.expectEqualStrings(first_instance_id, restored.identity.instance_id);
}

test "missing or malformed identity beside initialized database fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var initialized = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    initialized.deinit(std.testing.allocator);
    const identity_path = try std.fs.path.join(std.testing.allocator, &.{ paths.dir, FILE_NAME });
    defer std.testing.allocator.free(identity_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, identity_path);
    try std.testing.expectError(
        error.RuntimeIdentityFileMissing,
        initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none),
    );

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, identity_path, .{});
    try file.writeStreamingAll(std.testing.io, "{\"version\":1,\"runtime_id\":\"bad\",\"instance_id\":\"bad\"}\n");
    file.close(std.testing.io);
    try std.testing.expectError(
        error.InvalidRuntimeIdentity,
        initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none),
    );
}

test "valid v1 identity seeds a legacy database exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var identity = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, paths.dir);
    defer identity.deinit(std.testing.allocator);
    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try schema.initializeToVersion(conn, 7);
    }

    var migrated = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(identity.runtime_id, migrated.identity.runtime_id);
    try std.testing.expectEqualStrings(identity.instance_id, migrated.identity.instance_id);
}

test "pre-v8 database without sidecar upgrades and crash retry reuses pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try schema.initializeToVersion(conn, 7);
    }

    // Model a crash after the new sidecar reached disk but before the legacy
    // SQLite migration began. The retry must reuse the exact pair, not rotate.
    var staged = try prepareStoreIdentity(std.testing.allocator, std.testing.io, paths.dir, paths.db);
    const runtime_id = try std.testing.allocator.dupe(u8, staged.runtime_id);
    defer std.testing.allocator.free(runtime_id);
    const instance_id = try std.testing.allocator.dupe(u8, staged.instance_id);
    defer std.testing.allocator.free(instance_id);
    staged.deinit(std.testing.allocator);

    var upgraded = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    defer upgraded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(runtime_id, upgraded.identity.runtime_id);
    try std.testing.expectEqualStrings(instance_id, upgraded.identity.instance_id);
}

test "unknown nonempty version-zero database fails without rotating sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var staged = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, paths.dir);
    const runtime_id = try std.testing.allocator.dupe(u8, staged.runtime_id);
    defer std.testing.allocator.free(runtime_id);
    const instance_id = try std.testing.allocator.dupe(u8, staged.instance_id);
    defer std.testing.allocator.free(instance_id);
    staged.deinit(std.testing.allocator);
    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.execNoArgs("create table foreign_restore_marker (id integer primary key)");
    }

    try std.testing.expectError(
        error.InvalidRuntimeDatabase,
        initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none),
    );
    var unchanged = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, paths.dir);
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(runtime_id, unchanged.runtime_id);
    try std.testing.expectEqualStrings(instance_id, unchanged.instance_id);
}

test "future schema fails before requiring or reading sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.execNoArgs("pragma user_version = 10");
    }
    try std.testing.expectError(
        error.SchemaTooNew,
        initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none),
    );
    const identity_path = try std.fs.path.join(std.testing.allocator, &.{ paths.dir, FILE_NAME });
    defer std.testing.allocator.free(identity_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, identity_path, .{}),
    );
}

test "recognized pre-version Verde schema follows legacy migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.execNoArgs(schema.INIT_SQL);
    }
    var migrated = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    defer migrated.deinit(std.testing.allocator);
    try std.testing.expect(validIdentityPart(migrated.identity.runtime_id));
    try std.testing.expect(validIdentityPart(migrated.identity.instance_id));
}

test "current schema with missing identity metadata is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var identity = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, paths.dir);
    defer identity.deinit(std.testing.allocator);
    var generic_store = try daemon_store.Store.init(std.testing.allocator, paths.db);
    generic_store.deinit();
    try std.testing.expectError(
        error.StoreCorrupt,
        initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none),
    );
}

test "current schema with deleted identity metadata row is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    var initialized = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    initialized.deinit(std.testing.allocator);
    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.execNoArgs("delete from store_state where id = 1");
    }
    try std.testing.expectError(
        error.StoreCorrupt,
        initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none),
    );
}

test "sidecar-first crash seam remains recoverable before SQLite commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(&tmp);
    defer freeTestPaths(paths);

    // A valid sidecar with no DB models a crash after atomic file replacement.
    var staged = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, paths.dir);
    const runtime_id = try std.testing.allocator.dupe(u8, staged.runtime_id);
    defer std.testing.allocator.free(runtime_id);
    const staged_instance_id = try std.testing.allocator.dupe(u8, staged.instance_id);
    defer std.testing.allocator.free(staged_instance_id);
    staged.deinit(std.testing.allocator);

    // SQLite may have created a zero-version header before the migration
    // transaction committed. It still has no authoritative identity pair.
    const db_path_z = try std.testing.allocator.dupeZ(u8, paths.db);
    defer std.testing.allocator.free(db_path_z);
    {
        const conn = try zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        conn.close();
    }
    var recovered = try initStore(std.testing.allocator, std.testing.io, paths.dir, paths.db, .none);
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(runtime_id, recovered.identity.runtime_id);
    try std.testing.expect(!std.mem.eql(u8, staged_instance_id, recovered.identity.instance_id));
}

test "store-disabled file-only identity remains stable and isolated" {
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    const first_paths = try testPaths(&first_tmp);
    defer freeTestPaths(first_paths);
    const second_paths = try testPaths(&second_tmp);
    defer freeTestPaths(second_paths);

    var first = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, first_paths.dir);
    defer first.deinit(std.testing.allocator);
    var restarted = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, first_paths.dir);
    defer restarted.deinit(std.testing.allocator);
    var overridden = try loadOrCreateFileOnly(std.testing.allocator, std.testing.io, second_paths.dir);
    defer overridden.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.runtime_id, restarted.runtime_id);
    try std.testing.expectEqualStrings(first.instance_id, restarted.instance_id);
    try std.testing.expect(!std.mem.eql(u8, first.runtime_id, overridden.runtime_id));
}

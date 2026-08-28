//! Durable desktop-owned defaults for routing workspaces to runtime profiles.

const std = @import("std");
const builtin = @import("builtin");
const platform_paths = @import("platform_paths");

pub const CURRENT_VERSION: u8 = 1;
pub const FILE_NAME = "workspace-runtime-defaults.json";
pub const LOCAL_PROFILE_ID = "local";

const MAX_DOCUMENT_BYTES: usize = 256 * 1024;
const MAX_ENTRIES: usize = 512;
const MAX_WORKSPACE_ID_BYTES: usize = 128;
const PROFILE_ID_PREFIX = "profile-";
const PROFILE_ID_HEX_BYTES: usize = 32;
const LOCK_SUFFIX = ".lock";
const TEMP_RANDOM_BYTES: usize = 16;
const TEMP_PREFIX = ".workspace-runtime-defaults.";
const TEMP_SUFFIX = ".tmp";
const DOCUMENT_FIELDS = [_][]const u8{ "version", "defaults" };
const ENTRY_FIELDS = [_][]const u8{ "workspace_id", "profile_id" };
const PRIVATE_FILE_PERMISSIONS: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    @enumFromInt(0o600);

pub const WorkspaceRuntimeDefault = struct {
    workspace_id: []u8,
    profile_id: []u8,

    pub fn deinit(self: *WorkspaceRuntimeDefault, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.profile_id);
        self.* = undefined;
    }
};

pub const OwnedWorkspaceRuntimeDefaults = struct {
    items: []WorkspaceRuntimeDefault,

    pub fn deinit(self: *OwnedWorkspaceRuntimeDefaults, allocator: std.mem.Allocator) void {
        for (self.items) |*entry| entry.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const UpsertResult = enum {
    inserted,
    updated,
    unchanged,
};

const ExclusiveLock = struct {
    io: std.Io,
    file: std.Io.File,

    fn deinit(self: *ExclusiveLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

/// Resolves the defaults document beside Verde's existing user config file.
pub fn pathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const config_path = try platform_paths.configPath(allocator);
    defer allocator.free(config_path);
    return pathBesideConfigAlloc(allocator, config_path);
}

/// Loads all desktop-owned workspace runtime defaults.
pub fn load(allocator: std.mem.Allocator) !OwnedWorkspaceRuntimeDefaults {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    return loadAtPath(allocator, threaded.io(), path);
}

/// Returns an owned profile ID for a workspace, or null when it has no default.
pub fn lookup(allocator: std.mem.Allocator, workspace_id: []const u8) !?[]u8 {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    return lookupAtPath(allocator, threaded.io(), path, workspace_id);
}

/// Inserts or replaces one mapping while preserving every other workspace.
pub fn upsert(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    profile_id: []const u8,
) !UpsertResult {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    return upsertAtPath(allocator, threaded.io(), path, workspace_id, profile_id);
}

/// Removes one mapping without affecting its workspace or runtime profile.
pub fn remove(allocator: std.mem.Allocator, workspace_id: []const u8) !bool {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    return removeAtPath(allocator, threaded.io(), path, workspace_id);
}

/// Path-explicit load for hermetic callers and tests. A missing file is empty.
pub fn loadAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !OwnedWorkspaceRuntimeDefaults {
    try validateStorePath(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(MAX_DOCUMENT_BYTES + 1),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .items = try allocator.alloc(WorkspaceRuntimeDefault, 0),
        },
        error.StreamTooLong => return error.InvalidWorkspaceRuntimeDefaultsDocument,
        else => return err,
    };
    defer allocator.free(bytes);
    return decodeAlloc(allocator, bytes);
}

/// Path-explicit owned lookup for hermetic callers and tests.
pub fn lookupAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    workspace_id: []const u8,
) !?[]u8 {
    if (!validWorkspaceId(workspace_id)) return error.InvalidWorkspaceId;
    var defaults = try loadAtPath(allocator, io, path);
    defer defaults.deinit(allocator);
    for (defaults.items) |entry| {
        if (std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            return try allocator.dupe(u8, entry.profile_id);
        }
    }
    return null;
}

/// Path-explicit locked load-modify-save upsert for hermetic callers and tests.
pub fn upsertAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    workspace_id: []const u8,
    profile_id: []const u8,
) !UpsertResult {
    if (!validWorkspaceId(workspace_id)) return error.InvalidWorkspaceId;
    if (!validProfileId(profile_id)) return error.InvalidRuntimeProfileId;

    var lock = try acquireExclusiveAtPath(allocator, io, path);
    defer lock.deinit();

    var owned = try loadAtPath(allocator, io, path);
    var defaults = std.ArrayList(WorkspaceRuntimeDefault).fromOwnedSlice(owned.items);
    owned = undefined;
    defer deinitList(allocator, &defaults);

    for (defaults.items) |*entry| {
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
        if (std.mem.eql(u8, entry.profile_id, profile_id)) return .unchanged;

        const next_profile_id = try allocator.dupe(u8, profile_id);
        const previous_profile_id = entry.profile_id;
        entry.profile_id = next_profile_id;
        saveAtPath(allocator, io, path, defaults.items) catch |err| {
            entry.profile_id = previous_profile_id;
            allocator.free(next_profile_id);
            return err;
        };
        allocator.free(previous_profile_id);
        return .updated;
    }

    if (defaults.items.len >= MAX_ENTRIES) return error.TooManyWorkspaceRuntimeDefaults;
    var new_entry = try entryAlloc(allocator, workspace_id, profile_id);
    errdefer new_entry.deinit(allocator);
    try defaults.append(allocator, new_entry);
    errdefer _ = defaults.pop();
    try saveAtPath(allocator, io, path, defaults.items);
    return .inserted;
}

/// Path-explicit locked removal. Only the mapping is deleted.
pub fn removeAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    workspace_id: []const u8,
) !bool {
    if (!validWorkspaceId(workspace_id)) return error.InvalidWorkspaceId;

    var lock = try acquireExclusiveAtPath(allocator, io, path);
    defer lock.deinit();

    var owned = try loadAtPath(allocator, io, path);
    var defaults = std.ArrayList(WorkspaceRuntimeDefault).fromOwnedSlice(owned.items);
    owned = undefined;
    defer deinitList(allocator, &defaults);

    for (defaults.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
        var removed_entry = defaults.orderedRemove(index);
        errdefer defaults.insert(allocator, index, removed_entry) catch unreachable;
        try saveAtPath(allocator, io, path, defaults.items);
        removed_entry.deinit(allocator);
        return true;
    }
    return false;
}

fn saveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    defaults: []const WorkspaceRuntimeDefault,
) !void {
    try validateStorePath(path);
    const encoded = try encodeAlloc(allocator, defaults);
    defer allocator.free(encoded);

    const parent_path = std.fs.path.dirname(path) orelse ".";
    if (!std.mem.eql(u8, parent_path, ".")) {
        try std.Io.Dir.cwd().createDirPath(io, parent_path);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{
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

fn encodeAlloc(
    allocator: std.mem.Allocator,
    defaults: []const WorkspaceRuntimeDefault,
) ![]u8 {
    try validateEntries(defaults);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.beginObject();
    try stringify.objectField("version");
    try stringify.write(CURRENT_VERSION);
    try stringify.objectField("defaults");
    try stringify.beginArray();
    for (defaults) |entry| {
        try stringify.beginObject();
        try stringify.objectField("workspace_id");
        try stringify.write(entry.workspace_id);
        try stringify.objectField("profile_id");
        try stringify.write(entry.profile_id);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    const encoded = try writer.toOwnedSlice();
    if (encoded.len == 0 or encoded.len > MAX_DOCUMENT_BYTES) {
        allocator.free(encoded);
        return error.InvalidWorkspaceRuntimeDefaultsDocument;
    }
    return encoded;
}

fn decodeAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !OwnedWorkspaceRuntimeDefaults {
    if (bytes.len == 0 or bytes.len > MAX_DOCUMENT_BYTES) {
        return error.InvalidWorkspaceRuntimeDefaultsDocument;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWorkspaceRuntimeDefaultsDocument,
    };
    defer parsed.deinit();

    if (containsForbiddenField(parsed.value)) return error.SecretFieldForbidden;
    if (parsed.value != .object) return error.InvalidWorkspaceRuntimeDefaultsDocument;
    try validateAllowedFields(&parsed.value.object, &DOCUMENT_FIELDS);
    const version_value = parsed.value.object.get("version") orelse
        return error.InvalidWorkspaceRuntimeDefaultsDocument;
    if (version_value != .integer or version_value.integer < 0 or
        version_value.integer > std.math.maxInt(u8))
    {
        return error.InvalidWorkspaceRuntimeDefaultsDocument;
    }
    const version: u8 = @intCast(version_value.integer);
    if (version != CURRENT_VERSION) return error.UnsupportedWorkspaceRuntimeDefaultsVersion;
    const defaults_value = parsed.value.object.get("defaults") orelse
        return error.InvalidWorkspaceRuntimeDefaultsDocument;
    if (defaults_value != .array) return error.InvalidWorkspaceRuntimeDefaultsDocument;
    if (defaults_value.array.items.len > MAX_ENTRIES) {
        return error.TooManyWorkspaceRuntimeDefaults;
    }

    var defaults: std.ArrayList(WorkspaceRuntimeDefault) = .empty;
    errdefer deinitList(allocator, &defaults);
    try defaults.ensureTotalCapacity(allocator, defaults_value.array.items.len);
    for (defaults_value.array.items) |value| {
        if (value != .object) return error.InvalidWorkspaceRuntimeDefault;
        try validateAllowedFields(&value.object, &ENTRY_FIELDS);
        const workspace_id = try requiredString(&value.object, "workspace_id");
        const profile_id = try requiredString(&value.object, "profile_id");
        if (!validWorkspaceId(workspace_id)) return error.InvalidWorkspaceId;
        if (!validProfileId(profile_id)) return error.InvalidRuntimeProfileId;
        for (defaults.items) |previous| {
            if (std.mem.eql(u8, previous.workspace_id, workspace_id)) {
                return error.DuplicateWorkspaceRuntimeDefault;
            }
        }
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_profile_id = try allocator.dupe(u8, profile_id);
        defaults.appendAssumeCapacity(.{
            .workspace_id = owned_workspace_id,
            .profile_id = owned_profile_id,
        });
    }
    return .{ .items = try defaults.toOwnedSlice(allocator) };
}

fn validateEntries(defaults: []const WorkspaceRuntimeDefault) !void {
    if (defaults.len > MAX_ENTRIES) return error.TooManyWorkspaceRuntimeDefaults;
    for (defaults, 0..) |entry, index| {
        if (!validWorkspaceId(entry.workspace_id)) return error.InvalidWorkspaceId;
        if (!validProfileId(entry.profile_id)) return error.InvalidRuntimeProfileId;
        for (defaults[0..index]) |previous| {
            if (std.mem.eql(u8, previous.workspace_id, entry.workspace_id)) {
                return error.DuplicateWorkspaceRuntimeDefault;
            }
        }
    }
}

fn requiredString(object: *const std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidWorkspaceRuntimeDefault;
    if (value != .string) return error.InvalidWorkspaceRuntimeDefault;
    return value.string;
}

fn entryAlloc(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    profile_id: []const u8,
) !WorkspaceRuntimeDefault {
    const owned_workspace_id = try allocator.dupe(u8, workspace_id);
    errdefer allocator.free(owned_workspace_id);
    return .{
        .workspace_id = owned_workspace_id,
        .profile_id = try allocator.dupe(u8, profile_id),
    };
}

fn validateAllowedFields(
    object: *const std.json.ObjectMap,
    allowed_fields: []const []const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        for (allowed_fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else return error.UnknownWorkspaceRuntimeDefaultField;
    }
}

fn validWorkspaceId(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_WORKSPACE_ID_BYTES) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn validProfileId(value: []const u8) bool {
    if (std.mem.eql(u8, value, LOCAL_PROFILE_ID)) return true;
    if (value.len != PROFILE_ID_PREFIX.len + PROFILE_ID_HEX_BYTES or
        !std.mem.startsWith(u8, value, PROFILE_ID_PREFIX))
    {
        return false;
    }
    for (value[PROFILE_ID_PREFIX.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn containsForbiddenField(value: std.json.Value) bool {
    switch (value) {
        .array => |array| for (array.items) |item| {
            if (containsForbiddenField(item)) return true;
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (forbiddenFieldName(entry.key_ptr.*) or containsForbiddenField(entry.value_ptr.*)) {
                    return true;
                }
            }
        },
        else => {},
    }
    return false;
}

fn forbiddenFieldName(key: []const u8) bool {
    const forbidden = [_][]const u8{
        "token",
        "gatewaytoken",
        "providertoken",
        "accesstoken",
        "refreshtoken",
        "bearer",
        "bearertoken",
        "password",
        "passphrase",
        "privatekey",
        "privatekeycontents",
        "secret",
        "apikey",
        "authorization",
        "cookie",
        "sessioncookie",
    };
    for (forbidden) |candidate| {
        if (normalizedKeyEquals(key, candidate)) return true;
    }
    return false;
}

fn normalizedKeyEquals(key: []const u8, normalized: []const u8) bool {
    var index: usize = 0;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (index >= normalized.len or std.ascii.toLower(byte) != normalized[index]) return false;
        index += 1;
    }
    return index == normalized.len;
}

fn deinitList(
    allocator: std.mem.Allocator,
    defaults: *std.ArrayList(WorkspaceRuntimeDefault),
) void {
    for (defaults.items) |*entry| entry.deinit(allocator);
    defaults.deinit(allocator);
}

fn pathBesideConfigAlloc(allocator: std.mem.Allocator, config_path: []const u8) ![]u8 {
    try validateStorePath(config_path);
    const parent_path = std.fs.path.dirname(config_path) orelse return allocator.dupe(u8, FILE_NAME);
    return std.fs.path.join(allocator, &.{ parent_path, FILE_NAME });
}

fn validateStorePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidWorkspaceRuntimeDefaultsPath;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return error.InvalidWorkspaceRuntimeDefaultsPath;
    }
}

fn acquireExclusiveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !ExclusiveLock {
    return (try openExclusiveAtPath(allocator, io, path, false)) orelse unreachable;
}

fn tryAcquireExclusiveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?ExclusiveLock {
    return openExclusiveAtPath(allocator, io, path, true);
}

fn openExclusiveAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    nonblocking: bool,
) !?ExclusiveLock {
    try validateStorePath(path);
    const parent_path = std.fs.path.dirname(path) orelse ".";
    if (!std.mem.eql(u8, parent_path, ".")) {
        try std.Io.Dir.cwd().createDirPath(io, parent_path);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
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

test "workspace runtime defaults path is beside the existing config" {
    const allocator = std.testing.allocator;
    const absolute = try pathBesideConfigAlloc(allocator, "/tmp/verde/verde.json");
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/verde/" ++ FILE_NAME, absolute);

    const relative = try pathBesideConfigAlloc(allocator, "verde.json");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings(FILE_NAME, relative);
}

test "workspace runtime defaults round trip and preserve unrelated mappings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);
    const remote_id = "profile-0123456789abcdef0123456789abcdef";

    try std.testing.expectEqual(.inserted, try upsertAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
        LOCAL_PROFILE_ID,
    ));
    try std.testing.expectEqual(.inserted, try upsertAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-two",
        remote_id,
    ));
    try std.testing.expectEqual(.unchanged, try upsertAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-two",
        remote_id,
    ));
    try std.testing.expectEqual(.updated, try upsertAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
        remote_id,
    ));

    const first = (try lookupAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
    )).?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings(remote_id, first);
    const second = (try lookupAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-two",
    )).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings(remote_id, second);

    try std.testing.expect(try removeAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
    ));
    try std.testing.expect(!(try removeAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
    )));
    try std.testing.expect((try lookupAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
    )) == null);
    const preserved = (try lookupAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-two",
    )).?;
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(remote_id, preserved);

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

const ConcurrentUpsertContext = struct {
    path: []const u8,
    workspace_id: []const u8,
    profile_id: []const u8,
    ready: *std.atomic.Value(u8),
    start: *std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn run(self: *ConcurrentUpsertContext) void {
        _ = self.ready.fetchAdd(1, .release);
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        var threaded = std.Io.Threaded.init_single_threaded;
        _ = upsertAtPath(
            std.testing.allocator,
            threaded.io(),
            self.path,
            self.workspace_id,
            self.profile_id,
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "workspace runtime defaults serialize concurrent mutations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var ready: std.atomic.Value(u8) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var first: ConcurrentUpsertContext = .{
        .path = path,
        .workspace_id = "workspace-one",
        .profile_id = LOCAL_PROFILE_ID,
        .ready = &ready,
        .start = &start,
    };
    var second: ConcurrentUpsertContext = .{
        .path = path,
        .workspace_id = "workspace-two",
        .profile_id = "profile-fedcba9876543210fedcba9876543210",
        .ready = &ready,
        .start = &start,
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentUpsertContext.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentUpsertContext.run, .{&second});
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    start.store(true, .release);
    first_thread.join();
    second_thread.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;

    var loaded = try loadAtPath(allocator, std.testing.io, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    const first_profile = (try lookupAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-one",
    )).?;
    defer allocator.free(first_profile);
    try std.testing.expectEqualStrings(first.profile_id, first_profile);
    const second_profile = (try lookupAtPath(
        allocator,
        std.testing.io,
        path,
        "workspace-two",
    )).?;
    defer allocator.free(second_profile);
    try std.testing.expectEqualStrings(second.profile_id, second_profile);
}

test "workspace runtime defaults lock is exclusive and private" {
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

test "workspace runtime defaults reject malformed duplicate and secret fields" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    try writeTestFile(tmp.dir, FILE_NAME, "not-json");
    try std.testing.expectError(
        error.InvalidWorkspaceRuntimeDefaultsDocument,
        loadAtPath(allocator, std.testing.io, path),
    );
    try writeTestFile(tmp.dir, FILE_NAME,
        \\{"version":2,"defaults":[]}
    );
    try std.testing.expectError(
        error.UnsupportedWorkspaceRuntimeDefaultsVersion,
        loadAtPath(allocator, std.testing.io, path),
    );
    try writeTestFile(tmp.dir, FILE_NAME,
        \\{"version":1,"defaults":[],"gateway_token":"sentinel-secret"}
    );
    try std.testing.expectError(
        error.SecretFieldForbidden,
        loadAtPath(allocator, std.testing.io, path),
    );
    try writeTestFile(tmp.dir, FILE_NAME,
        \\{"version":1,"defaults":[],"metadata":{"private-key":"sentinel-secret"}}
    );
    try std.testing.expectError(
        error.SecretFieldForbidden,
        loadAtPath(allocator, std.testing.io, path),
    );
    try writeTestFile(tmp.dir, FILE_NAME,
        \\{"version":1,"defaults":[{"workspace_id":"same","profile_id":"local"},{"workspace_id":"same","profile_id":"local"}]}
    );
    try std.testing.expectError(
        error.DuplicateWorkspaceRuntimeDefault,
        loadAtPath(allocator, std.testing.io, path),
    );
    try writeTestFile(tmp.dir, FILE_NAME,
        \\{"version":1,"version":1,"defaults":[]}
    );
    try std.testing.expectError(
        error.InvalidWorkspaceRuntimeDefaultsDocument,
        loadAtPath(allocator, std.testing.io, path),
    );
}

test "workspace runtime defaults enforce field and document bounds transactionally" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);
    try std.testing.expectEqual(.inserted, try upsertAtPath(
        allocator,
        std.testing.io,
        path,
        "preserved",
        LOCAL_PROFILE_ID,
    ));
    const before = try tmp.dir.readFileAlloc(
        std.testing.io,
        FILE_NAME,
        allocator,
        .limited(MAX_DOCUMENT_BYTES + 1),
    );
    defer allocator.free(before);

    const oversized_id = try allocator.alloc(u8, MAX_WORKSPACE_ID_BYTES + 1);
    defer allocator.free(oversized_id);
    @memset(oversized_id, 'a');
    try std.testing.expectError(
        error.InvalidWorkspaceId,
        upsertAtPath(allocator, std.testing.io, path, oversized_id, LOCAL_PROFILE_ID),
    );
    try std.testing.expectError(
        error.InvalidRuntimeProfileId,
        upsertAtPath(allocator, std.testing.io, path, "new-workspace", "profile-token"),
    );
    const after = try tmp.dir.readFileAlloc(
        std.testing.io,
        FILE_NAME,
        allocator,
        .limited(MAX_DOCUMENT_BYTES + 1),
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    const oversized_document = try allocator.alloc(u8, MAX_DOCUMENT_BYTES + 1);
    defer allocator.free(oversized_document);
    @memset(oversized_document, 'x');
    try writeTestFile(tmp.dir, FILE_NAME, oversized_document);
    try std.testing.expectError(
        error.InvalidWorkspaceRuntimeDefaultsDocument,
        loadAtPath(allocator, std.testing.io, path),
    );
}

test "workspace runtime defaults staging failure preserves prior document" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original =
        \\{"version":1,"defaults":[]}
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

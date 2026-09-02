//! Shared local Herdr integration helpers used by the CLI and desktop app.

const std = @import("std");
const builtin = @import("builtin");

const platform_paths = @import("platform_paths");
const process_env = @import("../platform/env.zig");

pub const PENDING_DIR_NAME = "herdr";
pub const PENDING_OPEN_FILE_NAME = "pending-open.json";
pub const SHADOW_WORKSPACES_DIR_NAME = "herdr-workspaces";

pub const OpenRequest = struct {
    session: []const u8 = "",
    herdr_workspace: []const u8 = "",
    cwd: ?[]const u8 = null,
    local_dir: ?[]const u8 = null,
    pane: ?[]const u8 = null,
};

pub const HandoffRequest = struct {
    session: []const u8 = "default",
    workspace: ?[]const u8 = null,
    all: bool = false,
    dry_run: bool = false,
};

pub const UnlinkRequest = struct {
    workspace: ?[]const u8 = null,
    all: bool = false,
};

pub const CliTarget = struct {
    session: []const u8 = "default",
};

pub const LoadedOpenRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: OpenRequest = .{},

    pub fn init(backing_allocator: std.mem.Allocator) LoadedOpenRequest {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn allocator(self: *LoadedOpenRequest) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *LoadedOpenRequest) void {
        self.arena.deinit();
    }
};

pub fn validateOpenRequest(request: OpenRequest) !void {
    try validateSessionName(request.session);
    if (std.mem.trim(u8, request.herdr_workspace, &std.ascii.whitespace).len == 0) return error.MissingHerdrWorkspace;
}

pub fn validateHandoffRequest(request: HandoffRequest) !void {
    try validateSessionName(request.session);
    if (request.workspace) |workspace| {
        if (std.mem.trim(u8, workspace, &std.ascii.whitespace).len == 0) return error.EmptyHerdrWorkspaceSelector;
    }
}

pub fn validateUnlinkRequest(request: UnlinkRequest) !void {
    if (request.all and request.workspace != null) return error.AmbiguousHerdrWorkspaceSelector;
    if (request.workspace) |workspace| {
        if (std.mem.trim(u8, workspace, &std.ascii.whitespace).len == 0) return error.EmptyHerdrWorkspaceSelector;
    }
}

fn validateSessionName(session: []const u8) !void {
    if (std.mem.trim(u8, session, &std.ascii.whitespace).len == 0) return error.MissingHerdrSession;
}

pub fn pendingOpenPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ pref_path, PENDING_DIR_NAME, PENDING_OPEN_FILE_NAME });
}

pub fn defaultLocalDir(allocator: std.mem.Allocator, pref_path: []const u8, request: OpenRequest) ![]u8 {
    const name = try safeWorkspaceDirName(allocator, request);
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ pref_path, SHADOW_WORKSPACES_DIR_NAME, name });
}

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: CliTarget,
    args: []const []const u8,
    max_output_bytes: usize,
) !std.process.RunResult {
    try validateSessionName(target.session);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const local_executable = try localHerdrExecutableAlloc(allocator, io);
    defer if (local_executable) |path| allocator.free(path);
    try argv.appendSlice(allocator, &.{ local_executable orelse "herdr", "--session", target.session });
    try argv.appendSlice(allocator, args);

    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    return std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .environ_map = &env_map,
    });
}

fn localHerdrExecutableAlloc(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    _ = io;
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    if (env_map.get("HERDR_BIN")) |value| {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const expanded = try platform_paths.expandUserPath(allocator, trimmed);
            defer allocator.free(expanded);
            // Resolve overrides through the same PATH/PATHEXT rules as defaults;
            // this keeps `HERDR_BIN=herdr` and `.cmd` shims working on Windows.
            return try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, expanded);
        }
    }
    const executable_name = if (builtin.os.tag == .windows) "herdr.exe" else "herdr";
    return process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, executable_name) catch null;
}

pub fn findJsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |field| {
                if (field == .string) return field.string;
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (findJsonString(entry.value_ptr.*, key)) |found| return found;
            }
            return null;
        },
        .array => |array| {
            for (array.items) |item| {
                if (findJsonString(item, key)) |found| return found;
            }
            return null;
        },
        else => return null,
    }
}

pub fn writePendingOpen(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8, request: OpenRequest) !void {
    try validateOpenRequest(request);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const fs_io = threaded.io();

    try std.Io.Dir.cwd().createDirPath(fs_io, pref_path);
    const pending_dir = try std.fs.path.join(allocator, &.{ pref_path, PENDING_DIR_NAME });
    defer allocator.free(pending_dir);
    try std.Io.Dir.cwd().createDirPath(fs_io, pending_dir);

    const path = try pendingOpenPath(allocator, pref_path);
    defer allocator.free(path);

    const encoded = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(encoded);
    var file = try std.Io.Dir.createFileAbsolute(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    try file.writeStreamingAll(fs_io, encoded);
    try file.writeStreamingAll(fs_io, "\n");
    _ = io;
}

pub fn readPendingOpen(backing_allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8) !?LoadedOpenRequest {
    var threaded: std.Io.Threaded = .init(backing_allocator, .{});
    defer threaded.deinit();
    const fs_io = threaded.io();

    const pending_dir = try std.fs.path.join(backing_allocator, &.{ pref_path, PENDING_DIR_NAME });
    defer backing_allocator.free(pending_dir);
    var dir = std.Io.Dir.openDirAbsolute(fs_io, pending_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(fs_io);

    const bytes = dir.readFileAlloc(fs_io, PENDING_OPEN_FILE_NAME, backing_allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer backing_allocator.free(bytes);

    var loaded = LoadedOpenRequest.init(backing_allocator);
    errdefer loaded.deinit();
    // Ignore remote fields in a queued request written by an older build.
    loaded.value = try std.json.parseFromSliceLeaky(OpenRequest, loaded.allocator(), bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    try validateOpenRequest(loaded.value);
    _ = io;
    return loaded;
}

pub fn deletePendingOpen(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8) void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const path = pendingOpenPath(allocator, pref_path) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
    _ = io;
}

fn safeWorkspaceDirName(allocator: std.mem.Allocator, request: OpenRequest) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("local-");
    try appendSafePart(&writer.writer, request.session);
    try writer.writer.writeByte('-');
    try appendSafePart(&writer.writer, request.herdr_workspace);
    return try writer.toOwnedSlice();
}

fn appendSafePart(writer: *std.Io.Writer, value: []const u8) !void {
    var wrote = false;
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        try writer.writeByte(if (safe) byte else '_');
        wrote = true;
    }
    if (!wrote) try writer.writeAll("default");
}

test "default local dir encodes Herdr identity safely" {
    const request: OpenRequest = .{
        .session = "default",
        .herdr_workspace = "w1:p1",
    };
    const path = try defaultLocalDir(std.testing.allocator, "/tmp/verde", request);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/verde/herdr-workspaces/local-default-w1_p1", path);
}

test "unlink request rejects ambiguous workspace selector" {
    try std.testing.expectError(error.AmbiguousHerdrWorkspaceSelector, validateUnlinkRequest(.{
        .workspace = "current",
        .all = true,
    }));
}

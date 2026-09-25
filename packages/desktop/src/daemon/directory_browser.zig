//! Directory-only browsing beneath host-authorized roots. No pathname reopen
//! after confinement: listing uses the descriptor opened beneath the root.
const std = @import("std");
const builtin = @import("builtin");

pub const METHOD = "workspace.directory.list";
pub const ROOTS_ENV = "VERDE_DIRECTORY_ROOTS";
pub const Entry = struct { name: []const u8, path: []const u8 };
pub const Result = struct { path: []const u8, parent: ?[]const u8, directories: []const Entry };

// These helpers use a request arena; all returned strings belong to it.
pub fn appendRoot(allocator: std.mem.Allocator, io: std.Io, roots: *std.ArrayList([]const u8), path: []const u8) !void {
    if (!validPath(path)) return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.realPathFileAbsolute(io, path, &buffer) catch return;
    const resolved = buffer[0..len];
    for (roots.items) |existing| if (std.mem.eql(u8, existing, resolved)) return;
    try roots.append(allocator, try allocator.dupe(u8, resolved));
}

pub fn validPath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn contains(root: []const u8, path: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and
        (root.len == 1 or path.len == root.len or path[root.len] == '/');
}

fn openRoot(io: std.Io, path: []const u8) !std.Io.Dir {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    errdefer dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

// Same confinement strategy as web served_files: openat2 on Linux, a
// conservative no-follow component walk on other hosts/older kernels.
fn openBeneath(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, relative: []const u8) !std.Io.Dir {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const path_z = try allocator.dupeZ(u8, relative);
        defer allocator.free(path_z);
        const How = extern struct { flags: u64, mode: u64 = 0, resolve: u64 = 0x08 | 0x02 };
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true, .DIRECTORY = true };
        const how: How = .{ .flags = @as(u32, @bitCast(flags)) };
        while (true) {
            const rc = linux.syscall4(.openat2, @bitCast(@as(isize, root.handle)), @intFromPtr(path_z.ptr), @intFromPtr(&how), @sizeOf(How));
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .handle = @intCast(rc) },
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .NOSYS => break,
                else => return error.PathOutsideRoots,
            }
        }
    }
    var dir = root;
    defer if (dir.handle != root.handle) dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PathOutsideRoots;
        const next = dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false }) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.PathOutsideRoots,
        };
        if (dir.handle != root.handle) dir.close(io);
        dir = next;
    }
    const result = dir;
    dir = root;
    return result;
}

pub fn list(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, requested: []const u8) !Result {
    if (!validPath(requested)) return error.PathOutsideRoots;
    // Resolve only lexical separators/dots, never symlinks, before matching.
    const path = try std.fs.path.resolve(allocator, &.{requested});
    for (roots) |root| {
        if (!contains(root, path)) continue;
        const base = openRoot(io, root) catch return error.PathOutsideRoots;
        defer base.close(io);
        const remainder = std.mem.trimStart(u8, path[root.len..], "/");
        const relative = if (remainder.len == 0) "." else remainder;
        const dir = try openBeneath(allocator, io, base, relative);
        defer dir.close(io);
        var entries: std.ArrayList(Entry) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
            const child_relative = try std.fs.path.join(allocator, &.{ relative, entry.name });
            // Verify every child, including symlinks, as a directory beneath
            // the same root; escaping/dangling links and special files vanish.
            const child = openBeneath(allocator, io, base, child_relative) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            child.close(io);
            if (entries.items.len == 4096) return error.ResponseTooLarge;
            try entries.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .path = try std.fs.path.join(allocator, &.{ path, entry.name }) });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);
        const parent = std.fs.path.dirname(path);
        var allowed_parent: ?[]const u8 = null;
        if (parent) |p| for (roots) |r| {
            if (contains(r, p)) {
                allowed_parent = p;
                break;
            }
        };
        return .{ .path = path, .parent = allowed_parent, .directories = entries.items };
    }
    return error.PathOutsideRoots;
}

test "directory listing confines symlinks and traversal and returns directories only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(io, "root/Alpha/nested");
    try tmp.dir.createDirPath(io, "root/zebra");
    try tmp.dir.createDirPath(io, "outside/secret");
    try tmp.dir.createDirPath(io, "root-sibling/secret");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/file", .data = "never returned" });
    try tmp.dir.symLink(io, "file", "root/file-link", .{});
    try tmp.dir.symLink(io, "Alpha", "root/local-link", .{});
    try tmp.dir.symLink(io, "../outside", "root/escape", .{});
    try tmp.dir.symLink(io, "../missing", "root/dangling-escape", .{});
    if (builtin.os.tag == .linux) try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknodat(tmp.dir.handle, "root/fifo", 0o010600, 0)));
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const base = buffer[0..len];
    const root = try std.fs.path.join(a, &.{ base, "root" });
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 1000;
    const result = try list(a, io, &.{root}, root);
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() < deadline);
    try std.testing.expectEqual(@as(usize, if (builtin.os.tag == .linux) 3 else 2), result.directories.len);
    try std.testing.expectEqualStrings("Alpha", result.directories[0].name);
    try std.testing.expectEqualStrings("zebra", result.directories[result.directories.len - 1].name);
    try std.testing.expect(result.parent == null);
    const nested = try list(a, io, &.{root}, try std.fs.path.join(a, &.{ root, "Alpha" }));
    try std.testing.expectEqualStrings(root, nested.parent.?);
    for ([_][]const u8{ "outside", "root-sibling", "root/../outside", "root/escape", "root/dangling-escape", "root/escape/secret" }) |suffix| {
        const path = try std.fs.path.join(a, &.{ base, suffix });
        try std.testing.expectError(error.PathOutsideRoots, list(a, io, &.{root}, path));
    }
    for ([_][]const u8{ "file", "file-link", "fifo" }) |suffix| {
        if (std.mem.eql(u8, suffix, "fifo") and builtin.os.tag != .linux) continue;
        const path = try std.fs.path.join(a, &.{ root, suffix });
        try std.testing.expectError(if (builtin.os.tag == .linux) error.NotDir else error.PathOutsideRoots, list(a, io, &.{root}, path));
    }
    try std.testing.expectError(error.PathOutsideRoots, list(a, io, &.{}, root));
    try std.testing.expectError(error.PathOutsideRoots, list(a, io, &.{root}, "relative"));

    // A previously approved name is never reopened unconstrained after a swap.
    try tmp.dir.deleteTree(io, "root/Alpha");
    try tmp.dir.symLink(io, "../outside", "root/Alpha", .{});
    try std.testing.expectError(error.PathOutsideRoots, list(a, io, &.{root}, nested.path));
    try tmp.dir.deleteTree(io, "root");
    try tmp.dir.symLink(io, "outside", "root", .{});
    try std.testing.expectError(error.PathOutsideRoots, list(a, io, &.{root}, root));
}

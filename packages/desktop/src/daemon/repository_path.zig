//! Runtime-local repository path resolution with symlink-safe cwd descent.

const std = @import("std");

const daemon_store = @import("store.zig");

pub const ResolveError = error{
    InvalidRepositoryRoot,
    InvalidRepositoryCwd,
    RepositoryPathUnavailable,
    OutOfMemory,
};

/// Resolve a repository-relative working directory on the daemon that owns
/// the binding. Every client-controlled segment is opened relative to the
/// preceding directory handle without following symlinks before a path is
/// returned to the provider launcher.
pub fn resolveDirectoryAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    relative_cwd: ?[]const u8,
) ResolveError![]u8 {
    if (root_path.len == 0 or !std.fs.path.isAbsolute(root_path)) {
        return error.InvalidRepositoryRoot;
    }
    daemon_store.validateRepositoryRelativeCwd(relative_cwd) catch {
        return error.InvalidRepositoryCwd;
    };

    var current = std.Io.Dir.openDirAbsolute(io, root_path, .{
        .access_sub_paths = true,
        .follow_symlinks = false,
    }) catch return error.RepositoryPathUnavailable;
    defer current.close(io);

    const relative = relative_cwd orelse return allocator.dupe(u8, root_path);
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| {
        const next = current.openDir(io, segment, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        }) catch return error.RepositoryPathUnavailable;
        current.close(io);
        current = next;
    }
    return std.fs.path.join(allocator, &.{ root_path, relative });
}

fn testAbsolutePathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(std.testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

test "repository cwd resolution opens every relative segment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/services/api");

    const temporary_root = try testAbsolutePathAlloc(allocator, tmp.dir);
    defer allocator.free(temporary_root);
    const repository_root = try std.fs.path.join(allocator, &.{ temporary_root, "repo" });
    defer allocator.free(repository_root);
    const expected = try std.fs.path.join(allocator, &.{ repository_root, "services/api" });
    defer allocator.free(expected);

    const resolved = try resolveDirectoryAlloc(
        allocator,
        std.testing.io,
        repository_root,
        "services/api",
    );
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(expected, resolved);

    const root = try resolveDirectoryAlloc(allocator, std.testing.io, repository_root, null);
    defer allocator.free(root);
    try std.testing.expectEqualStrings(repository_root, root);
}

test "repository cwd resolution rejects traversal and symlink segments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/inside");
    try tmp.dir.createDir(std.testing.io, "outside", .default_dir);
    try tmp.dir.symLink(std.testing.io, "../outside", "repo/link", .{ .is_directory = true });

    const temporary_root = try testAbsolutePathAlloc(allocator, tmp.dir);
    defer allocator.free(temporary_root);
    const repository_root = try std.fs.path.join(allocator, &.{ temporary_root, "repo" });
    defer allocator.free(repository_root);

    try std.testing.expectError(
        error.InvalidRepositoryCwd,
        resolveDirectoryAlloc(allocator, std.testing.io, repository_root, "../outside"),
    );
    try std.testing.expectError(
        error.RepositoryPathUnavailable,
        resolveDirectoryAlloc(allocator, std.testing.io, repository_root, "link"),
    );
    try std.testing.expectError(
        error.InvalidRepositoryRoot,
        resolveDirectoryAlloc(allocator, std.testing.io, "relative/repo", null),
    );
}

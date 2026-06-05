//! Shared subprocess environment helpers for packaged desktop launches.

const std = @import("std");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const PATH_SEPARATOR: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
const SYSTEM_PATH_DIRS = [_][]const u8{
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
};
const HOME_PATH_SUFFIXES = [_][]const u8{
    ".local/bin",
    ".bun/bin",
    ".cargo/bin",
    ".local/share/mise/shims",
};

/// Builds an environment map with a PATH that works for packaged GUI launches.
pub fn buildAugmentedEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    errdefer env_map.deinit();

    const current_path = env_map.get("PATH") orelse "";
    var path_builder: std.ArrayList(u8) = .empty;
    defer path_builder.deinit(allocator);

    if (current_path.len > 0) {
        try path_builder.appendSlice(allocator, current_path);
    }

    if (std.c.getenv("HOME")) |home_z| {
        const home = std.mem.sliceTo(home_z, 0);
        for (HOME_PATH_SUFFIXES) |suffix| {
            const dir = try std.fs.path.join(allocator, &.{ home, suffix });
            defer allocator.free(dir);
            try appendUniquePathDir(allocator, &path_builder, dir);
        }
    }

    for (SYSTEM_PATH_DIRS) |dir| {
        try appendUniquePathDir(allocator, &path_builder, dir);
    }

    if (path_builder.items.len > 0) {
        try env_map.put("PATH", path_builder.items);
    }

    return env_map;
}

fn currentEnviron() std.process.Environ {
    if (@import("builtin").os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

/// Resolves an executable against the provided environment map.
pub fn resolveExecutableInEnvMapAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    executable: []const u8,
) ![]u8 {
    if (isQualifiedExecutablePath(executable)) {
        try checkExecutableAccess(allocator, executable);
        return allocator.dupe(u8, executable);
    }

    const path_env = env_map.get("PATH") orelse return error.FileNotFound;
    var parts = std.mem.splitScalar(u8, path_env, PATH_SEPARATOR);
    while (parts.next()) |part| {
        if (part.len == 0) continue;

        const candidate = try std.fs.path.join(allocator, &.{ part, executable });
        errdefer allocator.free(candidate);

        checkExecutableAccess(allocator, candidate) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };

        return candidate;
    }

    return error.FileNotFound;
}

fn checkExecutableAccess(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.access(path_z.ptr, std.c.X_OK) == 0) return;
    return switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// Returns true when the executable can be found in the augmented PATH.
pub fn commandExists(executable: []const u8) bool {
    var env_map = buildAugmentedEnvMap(std.heap.page_allocator) catch return false;
    defer env_map.deinit();

    const resolved = resolveExecutableInEnvMapAlloc(std.heap.page_allocator, &env_map, executable) catch return false;
    defer std.heap.page_allocator.free(resolved);
    return true;
}

/// Applies Verde's packaged-launch PATH repair to the current process.
/// Useful before PTY exec from a Finder-launched macOS app, where PATH is often
/// too small for Homebrew-backed shell startup files.
pub fn applyAugmentedPathToCurrentProcess(allocator: std.mem.Allocator) !void {
    var env_map = try buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    const path = env_map.get("PATH") orelse return;
    const path_z = try allocator.dupeZ(u8, path);
    // Do not free path_z after setenv: POSIX permits implementations to retain
    // the supplied pointer, and PTY child processes exec immediately after this.
    _ = setenv("PATH", path_z.ptr, 1);
}

fn appendUniquePathDir(
    allocator: std.mem.Allocator,
    path_builder: *std.ArrayList(u8),
    dir: []const u8,
) !void {
    if (pathContainsDir(path_builder.items, dir)) return;
    if (path_builder.items.len > 0) try path_builder.append(allocator, PATH_SEPARATOR);
    try path_builder.appendSlice(allocator, dir);
}

fn pathContainsDir(path_env: []const u8, dir: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path_env, PATH_SEPARATOR);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, dir)) return true;
    }
    return false;
}

fn isQualifiedExecutablePath(executable: []const u8) bool {
    return std.mem.indexOfScalar(u8, executable, '/') != null or
        std.mem.indexOfScalar(u8, executable, '\\') != null;
}

//! Shared subprocess environment helpers for packaged desktop launches.

const std = @import("std");
const builtin = @import("builtin");

const PATH_SEPARATOR: u8 = if (builtin.os.tag == .windows) ';' else ':';
// Phase 3 will populate these with the full Windows search list
// (%SystemRoot%\System32, %ProgramFiles%\nodejs, %LOCALAPPDATA%\Programs\…, etc.).
const SYSTEM_PATH_DIRS: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{},
    else => &.{
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    },
};
const HOME_PATH_SUFFIXES: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{},
    else => &.{
        ".local/bin",
        ".bun/bin",
        ".cargo/bin",
        ".local/share/mise/shims",
    },
};

const HOME_ENV_VAR = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

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

    if (env_map.get(HOME_ENV_VAR)) |home| {
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
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.span(std.c.environ) } },
    };
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
    switch (builtin.os.tag) {
        .windows => {
            // Phase 3 will distinguish FileNotFound vs AccessDenied so callers can
            // skip vs fail-fast; Phase 1 just needs "exists or doesn't" for the
            // PATH walk loop, which already maps both to "skip this candidate".
            var threaded = std.Io.Threaded.init_single_threaded;
            std.Io.Dir.cwd().access(threaded.io(), path, .{}) catch return error.FileNotFound;
        },
        else => {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            if (std.c.access(path_z.ptr, std.c.X_OK) == 0) return;
            return switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
                .NOENT, .NOTDIR => error.FileNotFound,
                .ACCES => error.AccessDenied,
                else => error.Unexpected,
            };
        },
    }
}

/// Returns true when the executable can be found in the augmented PATH.
pub fn commandExists(executable: []const u8) bool {
    var env_map = buildAugmentedEnvMap(std.heap.page_allocator) catch return false;
    defer env_map.deinit();

    const resolved = resolveExecutableInEnvMapAlloc(std.heap.page_allocator, &env_map, executable) catch return false;
    defer std.heap.page_allocator.free(resolved);
    return true;
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
    if (std.mem.indexOfScalar(u8, executable, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, executable, '\\') != null) return true;
    if (builtin.os.tag == .windows and executable.len >= 2 and
        std.ascii.isAlphabetic(executable[0]) and executable[1] == ':')
    {
        return true;
    }
    return false;
}

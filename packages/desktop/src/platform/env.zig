//! Shared subprocess environment helpers for packaged desktop launches.

const std = @import("std");
const builtin = @import("builtin");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const PATH_SEPARATOR: u8 = if (builtin.os.tag == .windows) ';' else ':';
const WINDOWS_DEFAULT_PATHEXT = ".COM;.EXE;.BAT;.CMD";
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

    if (builtin.os.tag == .windows) {
        try appendWindowsUserPathDirs(allocator, &path_builder, &env_map);
    } else {
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
    }

    if (path_builder.items.len > 0) {
        try env_map.put("PATH", path_builder.items);
    }

    return env_map;
}

fn currentEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

/// Resolves an executable against the provided environment map.
pub fn resolveExecutableInEnvMapAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    executable: []const u8,
) ![]u8 {
    if (isQualifiedExecutablePath(executable)) {
        if (try resolveExecutableCandidateAlloc(allocator, env_map, executable)) |resolved| return resolved;
        return error.FileNotFound;
    }

    const path_env = env_map.get("PATH") orelse return error.FileNotFound;
    var parts = std.mem.splitScalar(u8, path_env, PATH_SEPARATOR);
    while (parts.next()) |part| {
        if (part.len == 0) continue;

        const candidate = try joinPathForOs(allocator, builtin.os.tag, &.{ part, executable });
        defer allocator.free(candidate);
        if (try resolveExecutableCandidateAlloc(allocator, env_map, candidate)) |resolved| return resolved;
    }

    return error.FileNotFound;
}

fn resolveExecutableCandidateAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    candidate: []const u8,
) !?[]u8 {
    if (checkExecutableAccess(allocator, candidate)) {
        return try allocator.dupe(u8, candidate);
    } else |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {},
        else => return err,
    }

    if (builtin.os.tag != .windows or hasWindowsExecutableExtension(candidate)) return null;

    const pathext = env_map.get("PATHEXT") orelse WINDOWS_DEFAULT_PATHEXT;
    var extensions = std.mem.splitScalar(u8, pathext, ';');
    while (extensions.next()) |raw_extension| {
        const extension = std.mem.trim(u8, raw_extension, &std.ascii.whitespace);
        if (extension.len == 0) continue;
        const candidate_with_extension = if (extension[0] == '.')
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ candidate, extension })
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ candidate, extension });
        errdefer allocator.free(candidate_with_extension);
        if (checkExecutableAccess(allocator, candidate_with_extension)) {
            return candidate_with_extension;
        } else |err| switch (err) {
            error.FileNotFound, error.AccessDenied => allocator.free(candidate_with_extension),
            else => return err,
        }
    }

    return null;
}

fn checkExecutableAccess(allocator: std.mem.Allocator, path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        std.Io.Dir.cwd().access(threaded.io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.AccessDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };
        return;
    }

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
    if (builtin.os.tag == .windows) return;
    var env_map = try buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    const path = env_map.get("PATH") orelse return;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    // POSIX setenv copies both strings (unlike putenv), so the temporary
    // allocation remains caller-owned and must not leak on daemon shutdown.
    if (setenv("PATH", path_z.ptr, 1) != 0) return error.Unexpected;
}

fn appendUniquePathDir(
    allocator: std.mem.Allocator,
    path_builder: *std.ArrayList(u8),
    dir: []const u8,
) !void {
    return appendUniquePathDirForOs(allocator, path_builder, builtin.os.tag, dir);
}

fn appendUniquePathDirForOs(
    allocator: std.mem.Allocator,
    path_builder: *std.ArrayList(u8),
    comptime os_tag: std.Target.Os.Tag,
    dir: []const u8,
) !void {
    if (pathContainsDirForOs(path_builder.items, os_tag, dir)) return;
    if (path_builder.items.len > 0) try path_builder.append(allocator, pathSeparatorForOs(os_tag));
    try path_builder.appendSlice(allocator, dir);
}

fn pathContainsDir(path_env: []const u8, dir: []const u8) bool {
    return pathContainsDirForOs(path_env, builtin.os.tag, dir);
}

fn pathContainsDirForOs(path_env: []const u8, comptime os_tag: std.Target.Os.Tag, dir: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path_env, pathSeparatorForOs(os_tag));
    while (parts.next()) |part| {
        if (os_tag == .windows and std.ascii.eqlIgnoreCase(part, dir)) return true;
        if (std.mem.eql(u8, part, dir)) return true;
    }
    return false;
}

fn appendWindowsUserPathDirs(
    allocator: std.mem.Allocator,
    path_builder: *std.ArrayList(u8),
    env_map: *const std.process.Environ.Map,
) !void {
    try appendWindowsUserPathDirsForOs(allocator, path_builder, env_map, .windows);
}

fn appendWindowsUserPathDirsForOs(
    allocator: std.mem.Allocator,
    path_builder: *std.ArrayList(u8),
    env_map: *const std.process.Environ.Map,
    comptime os_tag: std.Target.Os.Tag,
) !void {
    if (env_map.get("APPDATA")) |appdata| {
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ appdata, "npm" });
    }
    if (env_map.get("LOCALAPPDATA")) |local_appdata| {
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ local_appdata, "Microsoft", "WindowsApps" });
    }
    if (env_map.get("USERPROFILE")) |user_profile| {
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ user_profile, ".bun", "bin" });
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ user_profile, ".cargo", "bin" });
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ user_profile, "scoop", "shims" });
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ user_profile, ".local", "bin" });
        try appendJoinedPathDirForOs(allocator, path_builder, os_tag, &.{ user_profile, ".local", "share", "mise", "shims" });
    }
}

fn appendJoinedPathDirForOs(
    allocator: std.mem.Allocator,
    path_builder: *std.ArrayList(u8),
    comptime os_tag: std.Target.Os.Tag,
    components: []const []const u8,
) !void {
    const dir = try joinPathForOs(allocator, os_tag, components);
    defer allocator.free(dir);
    try appendUniquePathDirForOs(allocator, path_builder, os_tag, dir);
}

fn joinPathForOs(allocator: std.mem.Allocator, comptime os_tag: std.Target.Os.Tag, components: []const []const u8) ![]u8 {
    return switch (os_tag) {
        .windows => joinPathSep(allocator, '\\', isWindowsPathSep, components),
        else => std.fs.path.join(allocator, components),
    };
}

fn pathSeparatorForOs(comptime os_tag: std.Target.Os.Tag) u8 {
    return if (os_tag == .windows) ';' else ':';
}

fn joinPathSep(
    allocator: std.mem.Allocator,
    separator: u8,
    comptime isSep: fn (u8) bool,
    components: []const []const u8,
) ![]u8 {
    if (components.len == 0) return allocator.dupe(u8, "");

    const first_index = for (components, 0..) |component, index| {
        if (component.len > 0) break index;
    } else return allocator.dupe(u8, "");

    var total_len = components[first_index].len;
    var previous = components[first_index];
    for (components[first_index + 1 ..]) |component| {
        if (component.len == 0) continue;
        const previous_sep = isSep(previous[previous.len - 1]);
        const next_sep = isSep(component[0]);
        total_len += @intFromBool(!previous_sep and !next_sep);
        total_len += if (previous_sep and next_sep) component.len - 1 else component.len;
        previous = component;
    }

    const result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);
    @memcpy(result[0..components[first_index].len], components[first_index]);
    var index = components[first_index].len;
    previous = components[first_index];
    for (components[first_index + 1 ..]) |component| {
        if (component.len == 0) continue;
        const previous_sep = isSep(previous[previous.len - 1]);
        const next_sep = isSep(component[0]);
        if (!previous_sep and !next_sep) {
            result[index] = separator;
            index += 1;
        }
        const adjusted = if (previous_sep and next_sep) component[1..] else component;
        @memcpy(result[index..][0..adjusted.len], adjusted);
        index += adjusted.len;
        previous = component;
    }
    return result;
}

fn isWindowsPathSep(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn isQualifiedExecutablePath(executable: []const u8) bool {
    return std.mem.indexOfScalar(u8, executable, '/') != null or
        std.mem.indexOfScalar(u8, executable, '\\') != null;
}

fn hasWindowsExecutableExtension(path: []const u8) bool {
    const slash_index = std.mem.lastIndexOfAny(u8, path, "/\\");
    const file_name = if (slash_index) |index| path[index + 1 ..] else path;
    const dot_index = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return false;
    return dot_index + 1 < file_name.len;
}

/// Classifies Windows command shims that require a command interpreter.
pub fn isWindowsCommandScript(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".cmd") or std.ascii.eqlIgnoreCase(extension, ".bat");
}

test "windows PATH augmentation includes common user CLI dirs without duplicates" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("PATH", "C:\\Existing;C:\\Users\\Test\\AppData\\Roaming\\npm");
    try env_map.put("APPDATA", "C:\\Users\\Test\\AppData\\Roaming\\");
    try env_map.put("LOCALAPPDATA", "C:\\Users\\Test\\AppData\\Local");
    try env_map.put("USERPROFILE", "C:\\Users\\Test User");

    var path_builder: std.ArrayList(u8) = .empty;
    defer path_builder.deinit(allocator);
    try path_builder.appendSlice(allocator, env_map.get("PATH").?);
    try appendWindowsUserPathDirsForOs(allocator, &path_builder, &env_map, .windows);

    const path = path_builder.items;
    try std.testing.expect(std.mem.indexOf(u8, path, "C:\\Users\\Test\\AppData\\Local\\Microsoft\\WindowsApps") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "C:\\Users\\Test User\\.bun\\bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "C:\\Users\\Test User\\scoop\\shims") != null);
    try std.testing.expect(pathContainsDirForOs(path, .windows, "c:\\users\\test\\appdata\\roaming\\NPM"));
    try std.testing.expect(!pathContainsDirForOs(path, .windows, "C:\\Users\\Test\\AppData\\Roaming\\npm-extra"));
}

test "windows executable helpers recognize PATHEXT scripts and qualified paths" {
    try std.testing.expect(hasWindowsExecutableExtension("codex.exe"));
    try std.testing.expect(hasWindowsExecutableExtension("C:\\Tools\\claude.CMD"));
    try std.testing.expect(!hasWindowsExecutableExtension("C:\\Tools\\agent"));
    try std.testing.expect(isQualifiedExecutablePath("\\\\server\\share\\tools\\codex.cmd"));
    try std.testing.expect(!isQualifiedExecutablePath("codex"));
    try std.testing.expect(isWindowsCommandScript("C:\\Tools\\CLAUDE.CMD"));
    try std.testing.expect(isWindowsCommandScript("agent.bat"));
    try std.testing.expect(!isWindowsCommandScript("codex.exe"));
}

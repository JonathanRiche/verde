//! Cross-platform user path discovery for app config and project defaults.

const std = @import("std");
const builtin = @import("builtin");
const windows_known_folders = @import("platform_windows_known_folders");

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    if (builtin.os.tag == .windows and envValue(&env_map, "VERDE_CONFIG") == null) {
        if (windows_known_folders.pathAlloc(allocator, .roaming_app_data)) |base| {
            defer allocator.free(base);
            return joinPathForOs(allocator, .windows, &.{ base, "Verde", "verde.json" });
        } else |_| {}
    }
    return configPathForOs(allocator, builtin.os.tag, &env_map);
}

pub fn userHome(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    if (builtin.os.tag == .windows) {
        if (windows_known_folders.pathAlloc(allocator, .profile)) |path| return path else |_| {}
    }
    return userHomeForOs(allocator, builtin.os.tag, &env_map);
}

/// Expands only the portable home aliases Verde documents. Arbitrary `%VAR%`
/// expansion is intentionally excluded so a project path cannot unexpectedly
/// change meaning between shells.
pub fn expandUserPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const home = try userHome(allocator);
    defer allocator.free(home);
    return expandUserPathForOs(allocator, builtin.os.tag, path, home);
}

pub fn expandUserPathForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    path: []const u8,
    home: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, home);
    if (path.len >= 2 and path[0] == '~' and isPathSeparatorForOs(os_tag, path[1])) {
        return joinPathForOs(allocator, os_tag, &.{ home, path[2..] });
    }
    if (os_tag == .windows) {
        const token = "%USERPROFILE%";
        if (path.len >= token.len and std.ascii.eqlIgnoreCase(path[0..token.len], token)) {
            if (path.len == token.len) return allocator.dupe(u8, home);
            if (isWindowsPathSep(path[token.len])) {
                return joinPathForOs(allocator, .windows, &.{ home, path[token.len + 1 ..] });
            }
        }
    }
    return allocator.dupe(u8, path);
}

/// Compares project paths using Windows filesystem identity rules while
/// retaining the original path bytes for display and persistence.
pub fn projectPathsEqual(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    return projectPathsEqualForOs(allocator, builtin.os.tag, left, right);
}

pub fn projectPathsEqualForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    left: []const u8,
    right: []const u8,
) !bool {
    if (os_tag != .windows) return std.mem.eql(u8, left, right);
    const left_key = try projectComparisonKeyAllocForOs(allocator, .windows, left);
    defer allocator.free(left_key);
    const right_key = try projectComparisonKeyAllocForOs(allocator, .windows, right);
    defer allocator.free(right_key);
    if (builtin.os.tag == .windows) return windowsOrdinalEqualIgnoreCase(allocator, left_key, right_key);
    return std.mem.eql(u8, left_key, right_key);
}

/// Allocates a stable comparison/hash key without modifying display spelling.
pub fn projectComparisonKeyAllocForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    path: []const u8,
) ![]u8 {
    if (os_tag != .windows) return allocator.dupe(u8, path);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var input = path;
    var written_count: usize = 0;
    var previous_was_separator = false;
    if (startsWithWindowsPathIgnoreCase(input, "\\\\?\\UNC\\")) {
        try writer.writer.writeAll("\\\\");
        written_count = 2;
        previous_was_separator = true;
        input = input[8..];
    } else if (startsWithWindowsPathIgnoreCase(input, "\\\\?\\")) {
        input = input[4..];
    }

    for (input) |byte| {
        const normalized = if (isWindowsPathSep(byte)) '\\' else std.ascii.toLower(byte);
        if (normalized == '\\' and previous_was_separator and written_count > 1) continue;
        try writer.writer.writeByte(normalized);
        written_count += 1;
        previous_was_separator = normalized == '\\';
    }
    var result = try writer.toOwnedSlice();
    if (result.len > 3 and result[result.len - 1] == '\\') {
        result = try allocator.realloc(result, result.len - 1);
    }
    return result;
}

fn windowsOrdinalEqualIgnoreCase(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    if (builtin.os.tag != .windows) return std.mem.eql(u8, left, right);
    const left_wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, left);
    defer allocator.free(left_wide);
    const right_wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, right);
    defer allocator.free(right_wide);
    return win32.CompareStringOrdinal(
        left_wide.ptr,
        @intCast(left_wide.len),
        right_wide.ptr,
        @intCast(right_wide.len),
        .TRUE,
    ) == 2;
}

fn startsWithWindowsPathIgnoreCase(path: []const u8, prefix: []const u8) bool {
    return path.len >= prefix.len and std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn isPathSeparatorForOs(comptime os_tag: std.Target.Os.Tag, byte: u8) bool {
    return if (os_tag == .windows) isWindowsPathSep(byte) else byte == '/';
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CompareStringOrdinal(
        string1: [*]const u16,
        count1: c_int,
        string2: [*]const u16,
        count2: c_int,
        ignore_case: std.os.windows.BOOL,
    ) callconv(.winapi) c_int;
} else struct {};

/// Returns a per-user local-data directory suitable for caches and web runtimes.
pub fn localDataDir(allocator: std.mem.Allocator, org: []const u8, app: []const u8) ![]u8 {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    if (builtin.os.tag == .windows) {
        if (windows_known_folders.pathAlloc(allocator, .local_app_data)) |base| {
            defer allocator.free(base);
            return joinPathForOs(allocator, .windows, &.{ base, org, app });
        } else |_| {}
        if (envValue(&env_map, "LOCALAPPDATA")) |base| {
            return joinPathForOs(allocator, .windows, &.{ base, org, app });
        }
    }
    return sdlPrefPathFallbackForOs(allocator, builtin.os.tag, &env_map, org, app);
}

/// Returns the platform temp directory without assuming `/tmp` on Windows.
pub fn tempDir(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    if (builtin.os.tag == .windows) {
        if (envValue(&env_map, "TEMP") orelse envValue(&env_map, "TMP")) |path| {
            return allocator.dupe(u8, path);
        }
        if (windows_known_folders.pathAlloc(allocator, .local_app_data)) |base| {
            defer allocator.free(base);
            return joinPathForOs(allocator, .windows, &.{ base, "Temp" });
        } else |_| {}
    }
    if (envValue(&env_map, "TMPDIR")) |path| return allocator.dupe(u8, path);
    return allocator.dupe(u8, "/tmp");
}

pub fn sdlPrefPathFallback(allocator: std.mem.Allocator, org: []const u8, app: []const u8) ![]u8 {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    return sdlPrefPathFallbackForOs(allocator, builtin.os.tag, &env_map, org, app);
}

fn currentEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

fn configPathForOs(allocator: std.mem.Allocator, comptime os_tag: std.Target.Os.Tag, env: anytype) ![]u8 {
    if (envValue(env, "VERDE_CONFIG")) |override_path| {
        return allocator.dupe(u8, override_path);
    }

    return switch (os_tag) {
        .windows => windowsConfigPath(allocator, env),
        else => posixConfigPath(allocator, env),
    };
}

fn userHomeForOs(allocator: std.mem.Allocator, comptime os_tag: std.Target.Os.Tag, env: anytype) ![]u8 {
    return switch (os_tag) {
        .windows => windowsUserHome(allocator, env),
        else => posixUserHome(allocator, env),
    };
}

fn sdlPrefPathFallbackForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    env: anytype,
    org: []const u8,
    app: []const u8,
) ![]u8 {
    return switch (os_tag) {
        .windows => windowsSdlPrefPathFallback(allocator, env, org, app),
        .linux, .freebsd, .openbsd, .netbsd => posixSdlPrefPathFallback(allocator, env, org, app),
        .macos => macosSdlPrefPathFallback(allocator, env, org, app),
        else => joinPathForOs(allocator, os_tag, &.{ ".", org, app }),
    };
}

fn windowsConfigPath(allocator: std.mem.Allocator, env: anytype) ![]u8 {
    if (envValue(env, "APPDATA")) |appdata| {
        return joinPathForOs(allocator, .windows, &.{ appdata, "verde", "verde.json" });
    }
    if (envValue(env, "LOCALAPPDATA")) |local_appdata| {
        return joinPathForOs(allocator, .windows, &.{ local_appdata, "verde", "verde.json" });
    }
    if (envValue(env, "USERPROFILE")) |user_profile| {
        return joinPathForOs(allocator, .windows, &.{ user_profile, "AppData", "Roaming", "verde", "verde.json" });
    }
    return error.EnvironmentVariableNotFound;
}

fn posixConfigPath(allocator: std.mem.Allocator, env: anytype) ![]u8 {
    if (envValue(env, "XDG_CONFIG_HOME")) |xdg_config_home| {
        return std.fs.path.join(allocator, &.{ xdg_config_home, "verde", "verde.json" });
    }

    const home = envValue(env, "HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".config", "verde", "verde.json" });
}

fn windowsUserHome(allocator: std.mem.Allocator, env: anytype) ![]u8 {
    if (envValue(env, "USERPROFILE")) |user_profile| {
        return allocator.dupe(u8, user_profile);
    }

    if (envValue(env, "HOMEDRIVE")) |home_drive| {
        if (envValue(env, "HOMEPATH")) |home_path| {
            return std.mem.concat(allocator, u8, &.{ home_drive, home_path });
        }
    }

    if (envValue(env, "HOME")) |home| {
        return allocator.dupe(u8, home);
    }

    return error.EnvironmentVariableNotFound;
}

fn posixUserHome(allocator: std.mem.Allocator, env: anytype) ![]u8 {
    const home = envValue(env, "HOME") orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, home);
}

fn windowsSdlPrefPathFallback(allocator: std.mem.Allocator, env: anytype, org: []const u8, app: []const u8) ![]u8 {
    if (envValue(env, "APPDATA")) |appdata| {
        return joinPathForOs(allocator, .windows, &.{ appdata, org, app });
    }
    if (envValue(env, "LOCALAPPDATA")) |local_appdata| {
        return joinPathForOs(allocator, .windows, &.{ local_appdata, org, app });
    }
    if (envValue(env, "USERPROFILE")) |user_profile| {
        return joinPathForOs(allocator, .windows, &.{ user_profile, "AppData", "Roaming", org, app });
    }
    return error.EnvironmentVariableNotFound;
}

fn posixSdlPrefPathFallback(allocator: std.mem.Allocator, env: anytype, org: []const u8, app: []const u8) ![]u8 {
    if (envValue(env, "XDG_DATA_HOME")) |xdg_data_home| {
        return joinPathForOs(allocator, .linux, &.{ xdg_data_home, org, app });
    }
    const home = envValue(env, "HOME") orelse return error.EnvironmentVariableNotFound;
    return joinPathForOs(allocator, .linux, &.{ home, ".local", "share", org, app });
}

fn macosSdlPrefPathFallback(allocator: std.mem.Allocator, env: anytype, org: []const u8, app: []const u8) ![]u8 {
    const home = envValue(env, "HOME") orelse return error.EnvironmentVariableNotFound;
    return joinPathForOs(allocator, .macos, &.{ home, "Library", "Application Support", org, app });
}

fn envValue(env: anytype, comptime name: [:0]const u8) ?[]const u8 {
    const raw = env.get(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn joinPathForOs(allocator: std.mem.Allocator, comptime os_tag: std.Target.Os.Tag, paths: []const []const u8) ![]u8 {
    return switch (os_tag) {
        .windows => joinPathSep(allocator, '\\', isWindowsPathSep, paths),
        else => std.fs.path.join(allocator, paths),
    };
}

fn joinPathSep(
    allocator: std.mem.Allocator,
    separator: u8,
    comptime isSep: fn (u8) bool,
    paths: []const []const u8,
) ![]u8 {
    if (paths.len == 0) return allocator.dupe(u8, "");

    const first_index = for (paths, 0..) |path, index| {
        if (path.len > 0) break index;
    } else return allocator.dupe(u8, "");

    var total_len = paths[first_index].len;
    var previous = paths[first_index];
    for (paths[first_index + 1 ..]) |path| {
        if (path.len == 0) continue;
        const previous_sep = isSep(previous[previous.len - 1]);
        const next_sep = isSep(path[0]);
        total_len += @intFromBool(!previous_sep and !next_sep);
        total_len += if (previous_sep and next_sep) path.len - 1 else path.len;
        previous = path;
    }

    const result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);

    @memcpy(result[0..paths[first_index].len], paths[first_index]);
    var index = paths[first_index].len;
    previous = paths[first_index];
    for (paths[first_index + 1 ..]) |path| {
        if (path.len == 0) continue;
        const previous_sep = isSep(previous[previous.len - 1]);
        const next_sep = isSep(path[0]);
        if (!previous_sep and !next_sep) {
            result[index] = separator;
            index += 1;
        }
        const adjusted = if (previous_sep and next_sep) path[1..] else path;
        @memcpy(result[index..][0..adjusted.len], adjusted);
        index += adjusted.len;
        previous = path;
    }
    return result;
}

fn isWindowsPathSep(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

const FakeEnv = struct {
    const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    entries: []const Entry,

    fn get(self: FakeEnv, comptime name: [:0]const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};

test "windows config path honors override and app data precedence" {
    const allocator = std.testing.allocator;

    const override_path = try configPathForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "VERDE_CONFIG", .value = " C:\\Verde\\custom.json " },
        .{ .name = "APPDATA", .value = "C:\\Users\\Test\\AppData\\Roaming" },
    } });
    defer allocator.free(override_path);
    try std.testing.expectEqualStrings("C:\\Verde\\custom.json", override_path);

    const roaming_path = try configPathForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "APPDATA", .value = "C:\\Users\\Test\\AppData\\Roaming" },
        .{ .name = "LOCALAPPDATA", .value = "C:\\Users\\Test\\AppData\\Local" },
    } });
    defer allocator.free(roaming_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test\\AppData\\Roaming\\verde\\verde.json", roaming_path);

    const local_path = try configPathForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "APPDATA", .value = " " },
        .{ .name = "LOCALAPPDATA", .value = "C:\\Users\\Test\\AppData\\Local\\" },
    } });
    defer allocator.free(local_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test\\AppData\\Local\\verde\\verde.json", local_path);

    const profile_path = try configPathForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "USERPROFILE", .value = "C:\\Users\\Test User" },
    } });
    defer allocator.free(profile_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test User\\AppData\\Roaming\\verde\\verde.json", profile_path);

    try std.testing.expectError(error.EnvironmentVariableNotFound, configPathForOs(allocator, .windows, FakeEnv{ .entries = &.{} }));
}

test "windows user home falls back through profile drive path and home" {
    const allocator = std.testing.allocator;

    const profile_home = try userHomeForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "USERPROFILE", .value = " C:\\Users\\Test User " },
        .{ .name = "HOMEDRIVE", .value = "D:" },
        .{ .name = "HOMEPATH", .value = "\\Ignored" },
    } });
    defer allocator.free(profile_home);
    try std.testing.expectEqualStrings("C:\\Users\\Test User", profile_home);

    const drive_home = try userHomeForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "HOMEDRIVE", .value = "D:" },
        .{ .name = "HOMEPATH", .value = "\\Profiles\\Tester" },
        .{ .name = "HOME", .value = "C:\\msys64\\home\\tester" },
    } });
    defer allocator.free(drive_home);
    try std.testing.expectEqualStrings("D:\\Profiles\\Tester", drive_home);

    const fallback_home = try userHomeForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "HOME", .value = "C:\\msys64\\home\\tester" },
    } });
    defer allocator.free(fallback_home);
    try std.testing.expectEqualStrings("C:\\msys64\\home\\tester", fallback_home);

    try std.testing.expectError(error.EnvironmentVariableNotFound, userHomeForOs(allocator, .windows, FakeEnv{ .entries = &.{} }));
}

test "windows SDL pref path fallback matches Verde app storage path" {
    const allocator = std.testing.allocator;

    const roaming_path = try sdlPrefPathFallbackForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "APPDATA", .value = "C:\\Users\\Test\\AppData\\Roaming" },
        .{ .name = "LOCALAPPDATA", .value = "C:\\Users\\Test\\AppData\\Local" },
    } }, "verde", "Native");
    defer allocator.free(roaming_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test\\AppData\\Roaming\\verde\\Native", roaming_path);

    const local_path = try sdlPrefPathFallbackForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "APPDATA", .value = " " },
        .{ .name = "LOCALAPPDATA", .value = "C:\\Users\\Test\\AppData\\Local" },
    } }, "verde", "Native");
    defer allocator.free(local_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test\\AppData\\Local\\verde\\Native", local_path);

    const profile_path = try sdlPrefPathFallbackForOs(allocator, .windows, FakeEnv{ .entries = &.{
        .{ .name = "USERPROFILE", .value = "C:\\Users\\Test User" },
    } }, "verde", "Native");
    defer allocator.free(profile_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test User\\AppData\\Roaming\\verde\\Native", profile_path);

    try std.testing.expectError(
        error.EnvironmentVariableNotFound,
        sdlPrefPathFallbackForOs(allocator, .windows, FakeEnv{ .entries = &.{} }, "verde", "Native"),
    );
}

test "Windows user path expansion is deliberate and preserves roots" {
    const allocator = std.testing.allocator;
    const home = "C:\\Users\\Zoë Tester";

    const tilde = try expandUserPathForOs(allocator, .windows, "~\\Projects\\Verde", home);
    defer allocator.free(tilde);
    try std.testing.expectEqualStrings("C:\\Users\\Zoë Tester\\Projects\\Verde", tilde);

    const profile = try expandUserPathForOs(allocator, .windows, "%userprofile%/Projects/Verde", home);
    defer allocator.free(profile);
    try std.testing.expectEqualStrings("C:\\Users\\Zoë Tester\\Projects/Verde", profile);

    const drive_root = try expandUserPathForOs(allocator, .windows, "D:\\", home);
    defer allocator.free(drive_root);
    try std.testing.expectEqualStrings("D:\\", drive_root);

    const unc = try expandUserPathForOs(allocator, .windows, "\\\\server\\share\\项目", home);
    defer allocator.free(unc);
    try std.testing.expectEqualStrings("\\\\server\\share\\项目", unc);
}

test "Windows project comparison keys normalize drive UNC case and long prefixes" {
    const allocator = std.testing.allocator;

    const drive_a = try projectComparisonKeyAllocForOs(allocator, .windows, "C:\\Users\\Zoë\\Client Repo\\");
    defer allocator.free(drive_a);
    const drive_b = try projectComparisonKeyAllocForOs(allocator, .windows, "c:/users/Zoë/client repo");
    defer allocator.free(drive_b);
    try std.testing.expectEqualStrings(drive_a, drive_b);
    try std.testing.expect(try projectPathsEqualForOs(allocator, .windows, "C:\\Users\\Zoë\\Client Repo", "c:/users/Zoë/client repo/"));
    try std.testing.expect(!(try projectPathsEqualForOs(allocator, .linux, "/repo/Verde", "/repo/verde")));
    try std.testing.expect(std.mem.indexOf(u8, drive_a, "ë") != null);

    const unc_a = try projectComparisonKeyAllocForOs(allocator, .windows, "\\\\Server\\Share\\项目\\Verde");
    defer allocator.free(unc_a);
    const unc_b = try projectComparisonKeyAllocForOs(allocator, .windows, "//server/share/项目/verde/");
    defer allocator.free(unc_b);
    try std.testing.expectEqualStrings(unc_a, unc_b);

    const long_a = try projectComparisonKeyAllocForOs(allocator, .windows, "\\\\?\\C:\\very\\long\\path");
    defer allocator.free(long_a);
    const long_b = try projectComparisonKeyAllocForOs(allocator, .windows, "c:\\very\\long\\path");
    defer allocator.free(long_b);
    try std.testing.expectEqualStrings(long_a, long_b);

    const long_unc = try projectComparisonKeyAllocForOs(allocator, .windows, "\\\\?\\UNC\\Server\\Share\\项目");
    defer allocator.free(long_unc);
    try std.testing.expectEqualStrings("\\\\server\\share\\项目", long_unc);
}

test "windows path join preserves UNC drive long path prefixes and spaces" {
    const allocator = std.testing.allocator;

    const drive_path = try joinPathForOs(allocator, .windows, &.{ "C:\\Users\\Test User\\", "\\Project One", "src" });
    defer allocator.free(drive_path);
    try std.testing.expectEqualStrings("C:\\Users\\Test User\\Project One\\src", drive_path);

    const unc_path = try joinPathForOs(allocator, .windows, &.{ "\\\\server\\shared folder", "Project One", "src" });
    defer allocator.free(unc_path);
    try std.testing.expectEqualStrings("\\\\server\\shared folder\\Project One\\src", unc_path);

    const long_path = try joinPathForOs(allocator, .windows, &.{ "\\\\?\\C:\\Very Long Root", "nested folder", "verde.json" });
    defer allocator.free(long_path);
    try std.testing.expectEqualStrings("\\\\?\\C:\\Very Long Root\\nested folder\\verde.json", long_path);
}

test "SDL pref path fallback keeps existing Linux and macOS CLI layout" {
    const allocator = std.testing.allocator;

    const xdg_path = try sdlPrefPathFallbackForOs(allocator, .linux, FakeEnv{ .entries = &.{
        .{ .name = "XDG_DATA_HOME", .value = "/home/test/.local/state" },
        .{ .name = "HOME", .value = "/ignored" },
    } }, "verde", "Native");
    defer allocator.free(xdg_path);
    try std.testing.expectEqualStrings("/home/test/.local/state/verde/Native", xdg_path);

    const home_path = try sdlPrefPathFallbackForOs(allocator, .linux, FakeEnv{ .entries = &.{
        .{ .name = "HOME", .value = "/home/test" },
    } }, "verde", "Native");
    defer allocator.free(home_path);
    try std.testing.expectEqualStrings("/home/test/.local/share/verde/Native", home_path);

    const macos_path = try sdlPrefPathFallbackForOs(allocator, .macos, FakeEnv{ .entries = &.{
        .{ .name = "HOME", .value = "/Users/test" },
    } }, "verde", "Native");
    defer allocator.free(macos_path);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/verde/Native", macos_path);
}

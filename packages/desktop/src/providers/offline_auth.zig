//! Offline sign-in checks for providers whose live auth probe needs a running
//! server. Readiness probes never launch Codex's app-server or OpenCode's
//! server, so with neither running the live check reports "unknown". These
//! fall back to each CLI's own local record of the login.

const std = @import("std");
const process_env = @import("../platform/env.zig");

const PROBE_DEADLINE_MS: i64 = 3_000;
const OUTPUT_LIMIT: usize = 4096;
const MAX_AUTH_FILE_BYTES: usize = 1024 * 1024;

pub const State = enum { signed_in, signed_out, unknown };

/// `codex login status` exits 0 when signed in and prints "Not logged in"
/// otherwise; it reads local credentials without starting a server.
pub fn codex(allocator: std.mem.Allocator) State {
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return .unknown;
    defer env_map.deinit();
    const executable = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "codex") catch return .unknown;
    defer allocator.free(executable);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const result = std.process.run(allocator, threaded.io(), .{
        .argv = &.{ executable, "login", "status" },
        .environ_map = &env_map,
        .stdout_limit = .limited(OUTPUT_LIMIT),
        .stderr_limit = .limited(OUTPUT_LIMIT),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(PROBE_DEADLINE_MS),
            .clock = .awake,
        } },
    }) catch return .unknown;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| codexStatusFromOutput(code, result.stdout, result.stderr),
        else => .unknown,
    };
}

fn codexStatusFromOutput(code: u8, stdout: []const u8, stderr: []const u8) State {
    if (code == 0) return .signed_in;
    const not_logged_in = "Not logged in";
    if (std.ascii.indexOfIgnoreCase(stdout, not_logged_in) != null or
        std.ascii.indexOfIgnoreCase(stderr, not_logged_in) != null) return .signed_out;
    return .unknown;
}

/// OpenCode stores provider logins in `$XDG_DATA_HOME/opencode/auth.json`
/// (default `~/.local/share`); an empty or missing file means no login.
pub fn opencode(allocator: std.mem.Allocator) State {
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return .unknown;
    defer env_map.deinit();
    const path = opencodeAuthPathAlloc(allocator, &env_map) catch return .unknown;
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(MAX_AUTH_FILE_BYTES)) catch |err| return switch (err) {
        error.FileNotFound => .signed_out,
        else => .unknown,
    };
    defer allocator.free(content);
    return opencodeStatusFromAuthJson(allocator, content);
}

fn opencodeAuthPathAlloc(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len > 0) return std.fs.path.join(allocator, &.{ data_home, "opencode", "auth.json" });
    }
    const home = env_map.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "opencode", "auth.json" });
}

fn opencodeStatusFromAuthJson(allocator: std.mem.Allocator, content: []const u8) State {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .unknown;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |object| if (object.count() > 0) .signed_in else .signed_out,
        else => .unknown,
    };
}

//! Offline sign-in checks for providers whose live auth probe needs a running
//! server. Readiness probes never launch Codex's app-server or OpenCode's
//! server, so with neither running the live check reports "unknown". These
//! fall back to each CLI's own local record of the login.

const std = @import("std");
const zqlite = @import("zqlite");
const process_env = @import("../platform/env.zig");

const PROBE_DEADLINE_MS: i64 = 3_000;
const OUTPUT_LIMIT: usize = 4096;
const MAX_AUTH_FILE_BYTES: usize = 1024 * 1024;
const OPENCODE_DB_BUSY_TIMEOUT_MS: c_int = 500;

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

/// OpenCode 1.x stores provider logins in `$XDG_DATA_HOME/opencode/auth.json`
/// (default `~/.local/share`); 2.x keeps them in the `credential` table of
/// `opencode.db` beside it and ignores `auth.json`. Either holding a login
/// counts. Like the live check, OpenCode's keyless free tier does not.
pub fn opencode(allocator: std.mem.Allocator) State {
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return .unknown;
    defer env_map.deinit();
    const data_dir = opencodeDataDirAlloc(allocator, &env_map) catch return .unknown;
    defer allocator.free(data_dir);

    const auth_path = std.fs.path.join(allocator, &.{ data_dir, "auth.json" }) catch return .unknown;
    defer allocator.free(auth_path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const legacy: State = if (std.Io.Dir.cwd().readFileAlloc(threaded.io(), auth_path, allocator, .limited(MAX_AUTH_FILE_BYTES))) |content| blk: {
        defer allocator.free(content);
        break :blk opencodeStatusFromAuthJson(allocator, content);
    } else |err| switch (err) {
        error.FileNotFound => .signed_out,
        else => .unknown,
    };
    if (legacy == .signed_in) return .signed_in;

    const db_path = std.fs.path.joinZ(allocator, &.{ data_dir, "opencode.db" }) catch return .unknown;
    defer allocator.free(db_path);
    std.Io.Dir.cwd().access(threaded.io(), db_path, .{}) catch |err| return switch (err) {
        error.FileNotFound => legacy,
        else => .unknown,
    };
    return switch (opencodeCredentialCount(db_path) orelse return .unknown) {
        0 => legacy,
        else => .signed_in,
    };
}

fn opencodeDataDirAlloc(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len > 0) return std.fs.path.join(allocator, &.{ data_home, "opencode" });
    }
    const home = env_map.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "opencode" });
}

/// Rows in OpenCode 2.x's credential store, read-only; null when the
/// database cannot be read or predates the table.
fn opencodeCredentialCount(db_path: [:0]const u8) ?i64 {
    const conn = zqlite.open(db_path, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode) catch return null;
    defer conn.close();
    conn.busyTimeout(OPENCODE_DB_BUSY_TIMEOUT_MS) catch return null;
    const row = (conn.row("select count(*) from credential", .{}) catch return null) orelse return null;
    defer row.deinit();
    return row.int(0);
}

fn opencodeStatusFromAuthJson(allocator: std.mem.Allocator, content: []const u8) State {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .unknown;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |object| if (object.count() > 0) .signed_in else .signed_out,
        else => .unknown,
    };
}

test "OpenCode 2.x credential store decides offline sign-in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const db_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/opencode.db", .{tmp.sub_path}, 0);
    defer allocator.free(db_path);
    {
        const conn = try zqlite.open(db_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.exec("create table credential (id text primary key, integration_id text, label text not null, value text not null)", .{});
    }
    try std.testing.expectEqual(@as(?i64, 0), opencodeCredentialCount(db_path));
    {
        const conn = try zqlite.open(db_path, zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.exec("insert into credential values ('cred_1', 'anthropic', 'Anthropic', 'secret')", .{});
    }
    try std.testing.expectEqual(@as(?i64, 1), opencodeCredentialCount(db_path));
    try std.testing.expect(opencodeStatusFromAuthJson(allocator, "{}") == .signed_out);
    try std.testing.expect(opencodeStatusFromAuthJson(allocator, "{\"anthropic\":{\"type\":\"api\"}}") == .signed_in);
}

//! `verde lease run`: runs one shared-resource command (build, deps, db, ...)
//! under a workspace lease that lives exactly as long as the command does.
//!
//! Agents used to call `acquire_lease` with a long TTL, keep it while editing,
//! and wait for each other with `sleep`/`pgrep` loops. This wrapper replaces
//! that: it queues in arrival order, takes the lease the moment it is free,
//! renews it only while the command runs, and releases it when the command
//! exits. Before running it looks for an identical command (same text, same
//! directory) that is already running, queued, or just finished. When the
//! checkout is unchanged since that run started, the wrapper follows its log
//! and reuses its exit status instead of running it again. When the checkout
//! changed, it names the files and runs again after the other run ends.
//!
//! Run state lives in `<pref>/lease-runs/<run_id>.{json,log}`; the session
//! daemon remains the authority for the lease itself.

const std = @import("std");
const builtin = @import("builtin");
const output = @import("output.zig");
const platform_ipc = @import("../platform/ipc.zig");
const live_endpoint = @import("../platform/live_endpoint.zig");
const daemon_client = @import("../daemon/client.zig");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");

const LEASE_TTL_MS: i64 = 90_000;
const RENEW_INTERVAL_MS: i64 = 30_000;
const HEARTBEAT_INTERVAL_MS: i64 = 5_000;
/// A record whose owner stopped heartbeating is abandoned (killed wrapper).
const HEARTBEAT_STALE_MS: i64 = 30_000;
const WAIT_TICK_MS: u64 = 1_000;
const TAIL_TICK_MS: u64 = 250;
const INPUTS_REFRESH_MS: i64 = 2_000;
/// Successful finished runs younger than this can be reused without rerunning.
const REUSE_WINDOW_MS: i64 = 30 * std.time.ms_per_min;
const RECORD_RETENTION_MS: i64 = 24 * std.time.ms_per_hour;
const LIVE_TIMEOUT_MS: u32 = 5_000;
const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;
const MAX_LISTED_CHANGES: usize = 12;
const RUNS_DIR = "lease-runs";

pub const usage =
    \\Usage: verde lease run [options] -- <command> [args...]
    \\
    \\Runs a command that needs an exclusive workspace resource (build, deps,
    \\db, browser, port:<n>). It waits in line for the resource, holds the lease
    \\only while the command runs, and releases it when the command exits.
    \\If an identical command is already running (or just succeeded) and no
    \\source file changed since it started, it shows that run's output and
    \\exit status instead of running again. If files changed, it lists them
    \\and runs again once the other run is done.
    \\
    \\Options:
    \\  --resource <name>     Resource to lease (repeatable). Default: inferred
    \\                        from the command (build/test -> build, installs -> deps).
    \\  --workspace <id|path> Verde workspace. Default: $VERDE_WORKSPACE_ID or cwd.
    \\  --owner <id>          Who is asking (use your Verde thread id); shown to
    \\                        others. Default: $VERDE_MCP_OWNER or $VERDE_SESSION_ID.
    \\  --no-reuse            Always run, even when an identical run can be reused.
    \\  --wait-timeout <sec>  Give up (exit 124) if the resource stays busy this long.
    \\
    \\A single quoted argument runs through /bin/sh -c.
    \\Waiting can take minutes: run it as a background task when your shell
    \\tool has a short timeout; it prints progress and exits with the command's
    \\status.
    \\
;

pub const Options = struct {
    resources: std.ArrayList([]const u8) = .empty,
    workspace: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    reuse: bool = true,
    wait_timeout_ms: ?i64 = null,
    argv: []const []const u8 = &.{},

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.resources.deinit(allocator);
    }
};

pub const ParseError = error{ MissingCommand, MissingValue, UnknownOption, InvalidTimeout, OutOfMemory };

/// `rest` starts after `lease run`.
pub fn parseArgs(allocator: std.mem.Allocator, rest: []const []const u8) ParseError!Options {
    var options: Options = .{};
    errdefer options.deinit(allocator);
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        const arg = rest[index];
        if (std.mem.eql(u8, arg, "--")) {
            options.argv = rest[index + 1 ..];
            break;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            // Without `--`, the first positional starts the command.
            options.argv = rest[index..];
            break;
        }
        if (std.mem.eql(u8, arg, "--no-reuse")) {
            options.reuse = false;
            continue;
        }
        const value = if (index + 1 < rest.len) rest[index + 1] else return error.MissingValue;
        if (std.mem.eql(u8, arg, "--resource")) {
            try options.resources.append(allocator, value);
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            options.workspace = value;
        } else if (std.mem.eql(u8, arg, "--owner")) {
            options.owner = value;
        } else if (std.mem.eql(u8, arg, "--wait-timeout")) {
            const seconds = std.fmt.parseInt(i64, value, 10) catch return error.InvalidTimeout;
            if (seconds <= 0) return error.InvalidTimeout;
            options.wait_timeout_ms = seconds * std.time.ms_per_s;
        } else return error.UnknownOption;
        index += 1;
    }
    if (options.argv.len == 0) return error.MissingCommand;
    return options;
}

/// Display/identity text for the command. Whitespace is collapsed so that
/// `zig build  test` and `zig build test` are the same command.
pub fn commandTextAlloc(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    for (argv) |arg| {
        var tokens = std.mem.tokenizeAny(u8, arg, " \t\r\n");
        while (tokens.next()) |token| {
            if (buffer.items.len > 0) try buffer.append(allocator, ' ');
            try buffer.appendSlice(allocator, token);
        }
    }
    return buffer.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Checkout inputs: HEAD plus a size/mtime stamp per dirty or untracked file.

pub const Inputs = struct {
    /// False outside a git checkout: changes cannot be detected, so no reuse.
    known: bool = false,
    head: []const u8 = "",
    /// Sorted `path\tsize\tmtime_ns` (or `path\tdeleted`) entries.
    files: []const []const u8 = &.{},
};

pub fn inputsEqual(left: Inputs, right: Inputs) bool {
    if (!left.known or !right.known) return false;
    if (!std.mem.eql(u8, left.head, right.head)) return false;
    if (left.files.len != right.files.len) return false;
    for (left.files, right.files) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

/// Paths whose stamp differs between `before` and `after` (added, removed,
/// or touched), sorted. Borrowed from the inputs.
pub fn changedPathsAlloc(allocator: std.mem.Allocator, before: Inputs, after: Inputs) ![]const []const u8 {
    var changed: std.ArrayList([]const u8) = .empty;
    errdefer changed.deinit(allocator);
    var i: usize = 0;
    var j: usize = 0;
    while (i < before.files.len or j < after.files.len) {
        if (j >= after.files.len) {
            try changed.append(allocator, stampPath(before.files[i]));
            i += 1;
            continue;
        }
        if (i >= before.files.len) {
            try changed.append(allocator, stampPath(after.files[j]));
            j += 1;
            continue;
        }
        const a = stampPath(before.files[i]);
        const b = stampPath(after.files[j]);
        switch (std.mem.order(u8, a, b)) {
            .lt => {
                try changed.append(allocator, a);
                i += 1;
            },
            .gt => {
                try changed.append(allocator, b);
                j += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, before.files[i], after.files[j])) try changed.append(allocator, a);
                i += 1;
                j += 1;
            },
        }
    }
    return changed.toOwnedSlice(allocator);
}

fn stampPath(stamp: []const u8) []const u8 {
    const tab = std.mem.indexOfScalar(u8, stamp, '\t') orelse return stamp;
    return stamp[0..tab];
}

/// Paths from `git status --porcelain=v1 -z --no-renames` output.
pub fn statusPathsAlloc(allocator: std.mem.Allocator, porcelain: []const u8) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(allocator);
    var entries = std.mem.splitScalar(u8, porcelain, 0);
    while (entries.next()) |entry| {
        if (entry.len < 4 or entry[2] != ' ') continue;
        try paths.append(allocator, entry[3..]);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanString);
    return paths.toOwnedSlice(allocator);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Snapshot of the git checkout containing `cwd`. `arena` owns the result.
fn readInputs(arena: std.mem.Allocator, io: std.Io, cwd: []const u8) Inputs {
    const top_head = gitOutput(arena, io, cwd, &.{ "rev-parse", "--show-toplevel", "HEAD" }) orelse return .{};
    var lines = std.mem.tokenizeScalar(u8, top_head, '\n');
    const top = lines.next() orelse return .{};
    const head = lines.next() orelse "";
    const porcelain = gitOutput(arena, io, top, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames" }) orelse return .{};
    const paths = statusPathsAlloc(arena, porcelain) catch return .{};
    var root = std.Io.Dir.openDirAbsolute(io, top, .{}) catch return .{};
    defer root.close(io);
    const files = arena.alloc([]const u8, paths.len) catch return .{};
    for (paths, files) |path, *stamp| {
        stamp.* = if (root.statFile(io, path, .{ .follow_symlinks = false })) |stat|
            std.fmt.allocPrint(arena, "{s}\t{d}\t{d}", .{ path, stat.size, stat.mtime.toNanoseconds() }) catch return .{}
        else |_|
            std.fmt.allocPrint(arena, "{s}\tdeleted", .{path}) catch return .{};
    }
    return .{ .known = true, .head = std.mem.trim(u8, head, " \r\n"), .files = files };
}

fn gitOutput(arena: std.mem.Allocator, io: std.Io, cwd: []const u8, git_args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "git", "-C", cwd }) catch return null;
    argv.appendSlice(arena, git_args) catch return null;
    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(MAX_RECORD_BYTES),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Run records shared between wrappers on this machine.

pub const State = enum { waiting, running, done };

pub const Record = struct {
    version: u32 = 1,
    run_id: []const u8 = "",
    pid: u32 = 0,
    owner: []const u8 = "",
    workspace_id: []const u8 = "",
    command: []const u8 = "",
    cwd: []const u8 = "",
    resources: []const []const u8 = &.{},
    state: State = .waiting,
    queued_ms: i64 = 0,
    started_ms: i64 = 0,
    finished_ms: i64 = 0,
    heartbeat_ms: i64 = 0,
    exit_code: ?i64 = null,
    lease_id: ?[]const u8 = null,
    /// Checkout when the command started (or when the wrapper queued).
    inputs: Inputs = .{},
    /// True when the checkout changed while the command ran, so its result
    /// may not include those edits.
    changed_during_run: bool = false,

    fn sameCommand(self: Record, other: Record) bool {
        return std.mem.eql(u8, self.workspace_id, other.workspace_id) and
            std.mem.eql(u8, self.command, other.command) and
            std.mem.eql(u8, self.cwd, other.cwd);
    }

    fn sharesResource(self: Record, other: Record) bool {
        if (!std.mem.eql(u8, self.workspace_id, other.workspace_id)) return false;
        for (self.resources) |left| {
            for (other.resources) |right| {
                if (std.mem.eql(u8, left, right)) return true;
            }
        }
        return false;
    }

    /// Queued before `other` (ties broken by run id).
    fn ahead(self: Record, other: Record) bool {
        if (self.queued_ms != other.queued_ms) return self.queued_ms < other.queued_ms;
        return std.mem.order(u8, self.run_id, other.run_id) == .lt;
    }
};

/// Whether a waiting/running record still has a live wrapper behind it.
pub fn recordLive(record: Record, now_ms: i64) bool {
    if (record.state == .done) return false;
    if (now_ms - record.heartbeat_ms > HEARTBEAT_STALE_MS) return false;
    return pidAlive(record.pid);
}

fn pidAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) return true; // heartbeat decides
    if (pid == 0) return false;
    const rc = std.c.kill(@intCast(pid), @enumFromInt(0));
    if (rc == 0) return true;
    return std.c.errno(rc) == .PERM;
}

pub const Decision = union(enum) {
    /// Follow this identical in-flight run and reuse its outcome.
    join: usize,
    /// An identical run already succeeded on this exact checkout.
    reuse: usize,
    /// Another wrapper is ahead in line for a shared resource.
    queued_behind: usize,
    /// Nothing to reuse or wait for locally: try to take the lease.
    acquire,
};

/// Picks what to do next from the live view of other runs. `stale_identical`
/// receives an identical in-flight run whose checkout differs from ours, so
/// the caller can explain why it runs again.
pub fn decide(me: Record, others: []const Record, now_ms: i64, reuse: bool, stale_identical: *?usize) Decision {
    stale_identical.* = null;
    if (reuse) {
        // An identical run that is running, or queued ahead of us, covers our
        // checkout exactly: follow it instead of running twice.
        for (others, 0..) |other, index| {
            if (!recordLive(other, now_ms) or !other.sameCommand(me)) continue;
            if (other.state == .waiting and !other.ahead(me)) continue;
            if (inputsEqual(other.inputs, me.inputs)) return .{ .join = index };
            if (stale_identical.* == null) stale_identical.* = index;
        }
        if (latestReusable(me, others, now_ms)) |index| return .{ .reuse = index };
    }
    for (others, 0..) |other, index| {
        if (other.state != .waiting or !recordLive(other, now_ms)) continue;
        if (!other.sharesResource(me) or !other.ahead(me)) continue;
        return .{ .queued_behind = index };
    }
    return .acquire;
}

/// Newest successful identical run on this checkout, provided no other run
/// touched the same resource after it started (its outputs are still current).
fn latestReusable(me: Record, others: []const Record, now_ms: i64) ?usize {
    var best: ?usize = null;
    for (others, 0..) |other, index| {
        if (other.state != .done or !other.sameCommand(me)) continue;
        if (other.exit_code == null or other.exit_code.? != 0 or other.changed_during_run) continue;
        if (now_ms - other.finished_ms > REUSE_WINDOW_MS) continue;
        if (!inputsEqual(other.inputs, me.inputs)) continue;
        if (best == null or other.started_ms > others[best.?].started_ms) best = index;
    }
    const chosen = best orelse return null;
    for (others, 0..) |other, index| {
        if (index == chosen or other.state == .waiting) continue;
        if (other.state == .running and !recordLive(other, now_ms)) continue;
        if (other.sharesResource(me) and other.started_ms > others[chosen].started_ms) return null;
    }
    return chosen;
}

const RunDir = struct {
    path: []const u8,

    fn recordPathAlloc(self: RunDir, allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.path, run_id });
    }

    fn logPathAlloc(self: RunDir, allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ self.path, run_id });
    }

    /// Atomic replace so readers never see a torn record.
    fn write(self: RunDir, allocator: std.mem.Allocator, io: std.Io, record: Record) !void {
        const encoded = try std.json.Stringify.valueAlloc(allocator, record, .{});
        defer allocator.free(encoded);
        const final_path = try self.recordPathAlloc(allocator, record.run_id);
        defer allocator.free(final_path);
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{final_path});
        defer allocator.free(tmp_path);
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = encoded });
        try cwd.rename(tmp_path, cwd, final_path, io);
    }

    /// Loads every other record; deletes abandoned and expired ones.
    fn loadOthers(self: RunDir, arena: std.mem.Allocator, io: std.Io, my_run_id: []const u8, now_ms: i64) ![]Record {
        var records: std.ArrayList(Record) = .empty;
        var dir = std.Io.Dir.openDirAbsolute(io, self.path, .{ .iterate = true }) catch return records.toOwnedSlice(arena);
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const run_id = entry.name[0 .. entry.name.len - ".json".len];
            if (std.mem.eql(u8, run_id, my_run_id)) continue;
            const bytes = dir.readFileAlloc(io, entry.name, arena, .limited(MAX_RECORD_BYTES)) catch continue;
            const parsed = std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
            const abandoned = parsed.state != .done and !recordLive(parsed, now_ms);
            const expired = parsed.state == .done and now_ms - parsed.finished_ms > RECORD_RETENTION_MS;
            if (abandoned or expired) {
                const name_copy = arena.dupe(u8, run_id) catch continue;
                self.remove(arena, io, name_copy);
                continue;
            }
            try records.append(arena, parsed);
        }
        return records.toOwnedSlice(arena);
    }

    fn remove(self: RunDir, allocator: std.mem.Allocator, io: std.Io, run_id: []const u8) void {
        const record_path = self.recordPathAlloc(allocator, run_id) catch return;
        defer allocator.free(record_path);
        const log_path = self.logPathAlloc(allocator, run_id) catch return;
        defer allocator.free(log_path);
        std.Io.Dir.deleteFileAbsolute(io, record_path) catch {};
        std.Io.Dir.deleteFileAbsolute(io, log_path) catch {};
    }

    fn reload(self: RunDir, arena: std.mem.Allocator, io: std.Io, run_id: []const u8) ?Record {
        const path = self.recordPathAlloc(arena, run_id) catch return null;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_RECORD_BYTES)) catch return null;
        return std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    }
};

// ---------------------------------------------------------------------------
// Live app and daemon calls.

const Live = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    next_id: u64 = 1,

    /// Returns the parsed response, or null when the app is unreachable.
    fn call(self: *Live, arena: std.mem.Allocator, method: []const u8, params: anytype) ?std.json.Value {
        const endpoint = live_endpoint.alloc(arena, self.pref_path) catch return null;
        const request = std.json.Stringify.valueAlloc(arena, .{ .id = self.next_id, .method = method, .params = params }, .{}) catch return null;
        self.next_id += 1;
        const response = platform_ipc.requestAlloc(arena, endpoint, request, .{ .timeout_ms = LIVE_TIMEOUT_MS }) catch return null;
        return std.json.parseFromSliceLeaky(std.json.Value, arena, response, .{ .allocate = .alloc_always }) catch null;
    }

    fn renew(self: *Live, arena: std.mem.Allocator, workspace_id: []const u8, owner: []const u8, lease_id: []const u8) bool {
        const response = daemon_client.requestAlloc(arena, self.pref_path, "lease.renew", .{
            .workspace = .{ .workspace_id = workspace_id },
            .owner = owner,
            .lease_id = lease_id,
            .ttl_ms = LEASE_TTL_MS,
        }, self.next_id) catch return false;
        self.next_id += 1;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response, .{ .allocate = .alloc_always }) catch return false;
        return parsed == .object and parsed.object.get("result") != null and parsed.object.get("error") == null;
    }
};

fn resultObject(response: std.json.Value) ?std.json.Value {
    if (response != .object) return null;
    const ok = response.object.get("ok") orelse return null;
    if (ok != .bool or !ok.bool) return null;
    const result = response.object.get("result") orelse return null;
    return if (result == .object) result else null;
}

fn errorMessage(response: std.json.Value) []const u8 {
    if (response != .object) return "invalid response";
    const err = response.object.get("error") orelse return "request failed";
    if (err != .object) return "request failed";
    const message = err.object.get("message") orelse return "request failed";
    return if (message == .string) message.string else "request failed";
}

fn stringField(object: std.json.Value, name: []const u8) ?[]const u8 {
    const value = object.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn intField(object: std.json.Value, name: []const u8) ?i64 {
    const value = object.object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

/// One-line description of what currently holds the resource, for progress
/// output. Empty when the response lists no conflicts.
fn holderSummaryAlloc(arena: std.mem.Allocator, result: std.json.Value, now_ms: i64) []const u8 {
    const conflicts = result.object.get("conflicts") orelse return "";
    if (conflicts != .array or conflicts.array.items.len == 0) return "";
    var text: std.ArrayList(u8) = .empty;
    for (conflicts.array.items, 0..) |conflict, index| {
        if (conflict != .object) continue;
        if (index > 0) text.appendSlice(arena, "; ") catch break;
        const owner = stringField(conflict, "owner") orelse "?";
        const command = stringField(conflict, "command") orelse "?";
        const resource = stringField(conflict, "resource") orelse "?";
        const kind = stringField(conflict, "kind") orelse "lease";
        text.print(arena, "{s} `{s}` held by {s} ({s})", .{ resource, command, owner, kind }) catch break;
        // Whole minutes only: the line is reprinted only when it changes.
        const started = intField(conflict, "started_at_ms") orelse 0;
        if (started > 0 and now_ms - started >= std.time.ms_per_min) {
            text.print(arena, ", running {d}+ min", .{@divTrunc(now_ms - started, std.time.ms_per_min)}) catch break;
        }
    }
    return text.items;
}

// ---------------------------------------------------------------------------
// Entry point.

/// Runs the wrapper and returns the process exit status.
pub fn run(allocator: std.mem.Allocator, io: std.Io, out: output.Output, rest: []const []const u8) !u8 {
    if (rest.len == 0 or std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h")) {
        try out.stdout("{s}", .{usage});
        return if (rest.len == 0) 2 else 0;
    }
    var options = parseArgs(allocator, rest) catch |err| {
        try out.stderr("verde lease run: {s}\n\n{s}", .{ @errorName(err), usage });
        return 2;
    };
    defer options.deinit(allocator);

    var session_arena: std.heap.ArenaAllocator = .init(allocator);
    defer session_arena.deinit();
    const arena = session_arena.allocator();

    const command = try commandTextAlloc(arena, options.argv);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const pref_path = try platform_paths.sdlPrefPathFallback(arena, "verde", "Native");
    const runs_path = try std.fs.path.join(arena, &.{ pref_path, RUNS_DIR });
    try std.Io.Dir.cwd().createDirPath(io, runs_path);
    const runs: RunDir = .{ .path = runs_path };
    var live: Live = .{ .allocator = allocator, .pref_path = pref_path };

    const pid = platform_runtime.processId();
    const queued_ms = platform_runtime.unixTimestampMs();
    const run_id = try std.fmt.allocPrint(arena, "{d}-{d}", .{ queued_ms, pid });
    // Unique per run: a shared owner would let a second wrapper "renew" the
    // first one's lease and run alongside it.
    const owner_label = options.owner orelse getenv("VERDE_MCP_OWNER") orelse getenv("VERDE_SESSION_ID");
    const owner = if (owner_label) |label|
        try std.fmt.allocPrint(arena, "{s}#lease-run:{s}", .{ label, run_id })
    else
        try std.fmt.allocPrint(arena, "lease-run:{s}", .{run_id});
    const explicit_workspace = options.workspace orelse getenv("VERDE_WORKSPACE_ID");
    var workspace: []const u8 = explicit_workspace orelse cwd;

    // Resolve the workspace id and the full resource set (explicit plus the
    // one the app infers from the command) without taking anything yet. A
    // checkout usually sits inside the workspace folder, so walk up from cwd.
    const check_result = while (true) {
        const check = live.call(arena, "workspace.checkCommand", .{
            .workspace = workspace,
            .command = command,
            .resources = options.resources.items,
            .owner = owner,
        }) orelse {
            try out.stderr("verde lease: Verde is not reachable, so no lease is taken; running `{s}` directly.\n", .{command});
            return runUnleased(io, options.argv);
        };
        if (resultObject(check)) |result| break result;
        const parent = if (explicit_workspace == null) std.fs.path.dirname(workspace) else null;
        if (parent == null or parent.?.len == workspace.len) {
            try out.stderr("verde lease: {s} (no Verde workspace contains {s}; pass --workspace)\n", .{ errorMessage(check), cwd });
            return 2;
        }
        workspace = parent.?;
    };
    const workspace_id = try arena.dupe(u8, stringField(check_result, "workspace_id") orelse workspace);
    const resources = blk: {
        var list: std.ArrayList([]const u8) = .empty;
        const value = check_result.object.get("resources") orelse break :blk list.items;
        if (value != .array) break :blk list.items;
        for (value.array.items) |item| {
            if (item == .string) try list.append(arena, try arena.dupe(u8, item.string));
        }
        break :blk list.items;
    };
    if (resources.len == 0) {
        try out.stderr("verde lease: `{s}` needs no shared resource (pass --resource to lease one); running it directly.\n", .{command});
        return runUnleased(io, options.argv);
    }

    var me: Record = .{
        .run_id = run_id,
        .pid = pid,
        .owner = owner,
        .workspace_id = workspace_id,
        .command = command,
        .cwd = cwd,
        .resources = resources,
        .state = .waiting,
        .queued_ms = queued_ms,
        .heartbeat_ms = queued_ms,
    };
    var inputs_arena: std.heap.ArenaAllocator = .init(allocator);
    defer inputs_arena.deinit();
    me.inputs = readInputs(inputs_arena.allocator(), io, cwd);
    var inputs_read_ms = platform_runtime.unixTimestampMs();
    try runs.write(allocator, io, me);
    var keep_record = false;
    defer if (!keep_record) runs.remove(allocator, io, run_id);

    var reporter: Reporter = .{ .out = out };
    var last_heartbeat_ms = queued_ms;

    while (true) {
        var tick_arena: std.heap.ArenaAllocator = .init(allocator);
        defer tick_arena.deinit();
        const tick = tick_arena.allocator();
        const now_ms = platform_runtime.unixTimestampMs();

        if (options.wait_timeout_ms) |limit| {
            if (now_ms - queued_ms > limit) {
                try out.stderr("verde lease: gave up after {d}s waiting for {s}.\n", .{ @divTrunc(limit, 1000), resources[0] });
                return 124;
            }
        }
        if (now_ms - inputs_read_ms >= INPUTS_REFRESH_MS) {
            _ = inputs_arena.reset(.retain_capacity);
            me.inputs = readInputs(inputs_arena.allocator(), io, cwd);
            inputs_read_ms = now_ms;
        }
        if (now_ms - last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS) {
            me.heartbeat_ms = now_ms;
            runs.write(allocator, io, me) catch {};
            last_heartbeat_ms = now_ms;
        }

        const others = try runs.loadOthers(tick, io, run_id, now_ms);
        var stale_identical: ?usize = null;
        const decision = decide(me, others, now_ms, options.reuse, &stale_identical);
        if (stale_identical) |index| try reporter.staleIdentical(tick, others[index], me, now_ms);
        switch (decision) {
            .join => |index| {
                switch (try followRun(allocator, io, out, runs, others[index], &me, cwd)) {
                    .reused => |code| return code,
                    .rerun => {},
                }
                continue;
            },
            .reuse => |index| {
                const other = others[index];
                try out.stderr(
                    "verde lease: `{s}` already succeeded {d}s ago ({s}) and no source file changed since it started; reusing that result instead of running again. Pass --no-reuse to force a run.\n",
                    .{ command, @divTrunc(now_ms - other.finished_ms, 1000), other.owner },
                );
                try printLogTail(tick, io, out, runs, other.run_id, 40);
                return 0;
            },
            .queued_behind => |index| {
                try reporter.queued(tick, others[index], now_ms);
                platform_runtime.sleepMillis(WAIT_TICK_MS);
                continue;
            },
            .acquire => {},
        }

        const response = live.call(tick, "workspace.acquireLease", .{
            .workspace = workspace_id,
            .command = command,
            .resources = resources,
            .owner = owner,
            .ttl_ms = LEASE_TTL_MS,
        }) orelse {
            try reporter.unreachable_app();
            platform_runtime.sleepMillis(WAIT_TICK_MS);
            continue;
        };
        const result = resultObject(response) orelse {
            try out.stderr("verde lease: {s}\n", .{errorMessage(response)});
            return 2;
        };
        const acquired = if (result.object.get("acquired")) |value| value == .bool and value.bool else false;
        if (!acquired) {
            try reporter.busy(holderSummaryAlloc(tick, result, now_ms));
            platform_runtime.sleepMillis(WAIT_TICK_MS);
            continue;
        }
        const lease_id = try arena.dupe(u8, stringField(result, "lease_id") orelse "");
        keep_record = true;
        return runLeased(allocator, io, out, runs, &live, &me, lease_id, cwd, options.argv, now_ms - queued_ms);
    }
}

const FollowOutcome = union(enum) { reused: u8, rerun };

/// Streams an identical run's log until it finishes, then reuses its exit
/// status when our checkout still matches the one it ran on.
fn followRun(allocator: std.mem.Allocator, io: std.Io, out: output.Output, runs: RunDir, target: Record, me: *Record, cwd: []const u8) !FollowOutcome {
    const target_id = try allocator.dupe(u8, target.run_id);
    defer allocator.free(target_id);
    const target_owner = try allocator.dupe(u8, target.owner);
    defer allocator.free(target_owner);
    if (target.state == .running) {
        try out.stderr(
            "verde lease: identical `{s}` is already running ({s}, started {d}s ago) on the same sources; following its output instead of running it again.\n",
            .{ me.command, target_owner, @divTrunc(platform_runtime.unixTimestampMs() - target.started_ms, 1000) },
        );
    } else {
        try out.stderr("verde lease: identical `{s}` is queued ahead ({s}) on the same sources; will follow its output.\n", .{ me.command, target_owner });
    }
    const log_path = try runs.logPathAlloc(allocator, target_id);
    defer allocator.free(log_path);
    var offset: u64 = 0;
    while (true) {
        var tick_arena: std.heap.ArenaAllocator = .init(allocator);
        defer tick_arena.deinit();
        const tick = tick_arena.allocator();
        offset = streamLog(io, out, log_path, offset);
        const now_ms = platform_runtime.unixTimestampMs();
        me.heartbeat_ms = now_ms;
        runs.write(allocator, io, me.*) catch {};
        const current = runs.reload(tick, io, target_id) orelse {
            try out.stderr("\nverde lease: the run being followed disappeared; queueing to run it here.\n", .{});
            return .rerun;
        };
        if (current.state != .done) {
            if (!recordLive(current, now_ms)) {
                try out.stderr("\nverde lease: the run being followed was killed; queueing to run it here.\n", .{});
                return .rerun;
            }
            platform_runtime.sleepMillis(TAIL_TICK_MS);
            continue;
        }
        offset = streamLog(io, out, log_path, offset);
        const now_inputs = readInputs(tick, io, cwd);
        const code: u8 = @intCast(std.math.clamp(current.exit_code orelse 1, 0, 255));
        if (inputsEqual(current.inputs, now_inputs) and !current.changed_during_run) {
            try out.stderr("\nverde lease: reused {s}'s run of `{s}`: exit {d}. No source file changed since it started.\n", .{ target_owner, me.command, code });
            return .{ .reused = code };
        }
        const changed = try changedPathsAlloc(tick, current.inputs, now_inputs);
        try out.stderr("\nverde lease: {s}'s run of `{s}` finished (exit {d}), but sources changed after it started, so its result may not include them:\n", .{ target_owner, me.command, code });
        try printChanged(out, current.inputs, now_inputs, changed);
        try out.stderr("verde lease: running it again with the current sources.\n", .{});
        return .rerun;
    }
}

fn runLeased(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: output.Output,
    runs: RunDir,
    live: *Live,
    me: *Record,
    lease_id: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
    waited_ms: i64,
) !u8 {
    var inputs_arena: std.heap.ArenaAllocator = .init(allocator);
    defer inputs_arena.deinit();
    const started_ms = platform_runtime.unixTimestampMs();
    me.inputs = readInputs(inputs_arena.allocator(), io, cwd);
    me.state = .running;
    me.started_ms = started_ms;
    me.heartbeat_ms = started_ms;
    me.lease_id = lease_id;
    try runs.write(allocator, io, me.*);
    if (waited_ms >= 2_000) {
        try out.stderr("verde lease: got {s} after waiting {d}s; running `{s}`.\n", .{ me.resources[0], @divTrunc(waited_ms, 1000), me.command });
    }

    const log_path = try runs.logPathAlloc(allocator, me.run_id);
    defer allocator.free(log_path);
    var log_file = try std.Io.Dir.createFileAbsolute(io, log_path, .{ .truncate = true });
    defer log_file.close(io);

    const shell_argv = [_][]const u8{ "/bin/sh", "-c", if (argv.len == 1) argv[0] else "" };
    const child_argv: []const []const u8 = if (argv.len == 1 and builtin.os.tag != .windows) &shell_argv else argv;
    var waiter: ChildWaiter = .{ .io = io };
    const exit_code: u8 = spawn: {
        waiter.child = std.process.spawn(io, .{
            .argv = child_argv,
            .stdin = .inherit,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        }) catch |err| {
            try out.stderr("verde lease: could not start `{s}`: {s}\n", .{ me.command, @errorName(err) });
            break :spawn 127;
        };
        const thread = try std.Thread.spawn(.{}, ChildWaiter.wait, .{&waiter});
        var offset: u64 = 0;
        var last_renew_ms = started_ms;
        var last_heartbeat_ms = started_ms;
        while (!waiter.done.load(.acquire)) {
            offset = streamLog(io, out, log_path, offset);
            const now_ms = platform_runtime.unixTimestampMs();
            if (now_ms - last_renew_ms >= RENEW_INTERVAL_MS) {
                var renew_arena: std.heap.ArenaAllocator = .init(allocator);
                defer renew_arena.deinit();
                if (!live.renew(renew_arena.allocator(), me.workspace_id, me.owner, lease_id)) {
                    out.stderr("verde lease: could not renew the {s} lease; it may lapse before the command ends.\n", .{me.resources[0]}) catch {};
                }
                last_renew_ms = now_ms;
            }
            if (now_ms - last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS) {
                me.heartbeat_ms = now_ms;
                runs.write(allocator, io, me.*) catch {};
                last_heartbeat_ms = now_ms;
            }
            platform_runtime.sleepMillis(TAIL_TICK_MS);
        }
        thread.join();
        _ = streamLog(io, out, log_path, offset);
        break :spawn waiter.exitCode();
    };

    var release_arena: std.heap.ArenaAllocator = .init(allocator);
    defer release_arena.deinit();
    _ = live.call(release_arena.allocator(), "workspace.releaseLease", .{
        .workspace = me.workspace_id,
        .owner = me.owner,
        .lease_id = lease_id,
    });

    const end_inputs = readInputs(release_arena.allocator(), io, cwd);
    const changed = try changedPathsAlloc(release_arena.allocator(), me.inputs, end_inputs);
    const head_moved = me.inputs.known and end_inputs.known and !std.mem.eql(u8, me.inputs.head, end_inputs.head);
    me.changed_during_run = changed.len > 0 or head_moved;
    me.state = .done;
    me.finished_ms = platform_runtime.unixTimestampMs();
    me.heartbeat_ms = me.finished_ms;
    me.exit_code = exit_code;
    runs.write(allocator, io, me.*) catch {};

    if (me.changed_during_run) {
        try out.stderr("verde lease: sources changed while `{s}` ran, so this result may not include them:\n", .{me.command});
        try printChanged(out, me.inputs, end_inputs, changed);
        try out.stderr("verde lease: rerun it if those changes matter.\n", .{});
    }
    return exit_code;
}

const ChildWaiter = struct {
    io: std.Io,
    child: std.process.Child = undefined,
    term: ?std.process.Child.Term = null,
    done: std.atomic.Value(bool) = .init(false),

    fn wait(self: *ChildWaiter) void {
        self.term = self.child.wait(self.io) catch null;
        self.done.store(true, .release);
    }

    fn exitCode(self: *const ChildWaiter) u8 {
        const term = self.term orelse return 1;
        return switch (term) {
            .exited => |code| code,
            .signal => |signal| @truncate(128 +% @as(u32, @intFromEnum(signal))),
            else => 1,
        };
    }
};

fn runUnleased(io: std.Io, argv: []const []const u8) !u8 {
    const shell_argv = [_][]const u8{ "/bin/sh", "-c", if (argv.len == 1) argv[0] else "" };
    const child_argv: []const []const u8 = if (argv.len == 1 and builtin.os.tag != .windows) &shell_argv else argv;
    var child = std.process.spawn(io, .{ .argv = child_argv }) catch return 127;
    const term = child.wait(io) catch return 1;
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 +% @as(u32, @intFromEnum(signal))),
        else => 1,
    };
}

/// Copies new bytes of `path` from `offset` to stdout; returns the new offset.
fn streamLog(io: std.Io, out: output.Output, path: []const u8, offset: u64) u64 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return offset;
    defer file.close(io);
    var position = offset;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const read = file.readPositionalAll(io, &buffer, position) catch return position;
        if (read == 0) return position;
        out.stdout("{s}", .{buffer[0..read]}) catch return position;
        position += read;
        if (read < buffer.len) return position;
    }
}

fn printLogTail(arena: std.mem.Allocator, io: std.Io, out: output.Output, runs: RunDir, run_id: []const u8, max_lines: usize) !void {
    const path = try runs.logPathAlloc(arena, run_id);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_RECORD_BYTES)) catch return;
    const trimmed = std.mem.trimEnd(u8, bytes, "\n");
    var start: usize = trimmed.len;
    var lines: usize = 0;
    while (start > 0 and lines < max_lines) {
        start -= 1;
        if (trimmed[start] == '\n') lines += 1;
    }
    if (start > 0) start += 1;
    if (trimmed.len == 0) return;
    try out.stdout("{s}\n", .{trimmed[start..]});
}

fn printChanged(out: output.Output, before: Inputs, after: Inputs, changed: []const []const u8) !void {
    if (before.known and after.known and !std.mem.eql(u8, before.head, after.head)) {
        try out.stderr("  HEAD moved {s} -> {s}\n", .{ shortSha(before.head), shortSha(after.head) });
    }
    for (changed[0..@min(changed.len, MAX_LISTED_CHANGES)]) |path| try out.stderr("  {s}\n", .{path});
    if (changed.len > MAX_LISTED_CHANGES) try out.stderr("  ...and {d} more\n", .{changed.len - MAX_LISTED_CHANGES});
}

fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, 10)];
}

/// Prints each kind of waiting status once per change, not every tick.
const Reporter = struct {
    out: output.Output,
    last: [512]u8 = undefined,
    last_len: usize = 0,
    stale_reported: [64]u8 = undefined,
    stale_len: usize = 0,

    fn report(self: *Reporter, line: []const u8) !void {
        if (std.mem.eql(u8, line, self.last[0..self.last_len])) return;
        const len = @min(line.len, self.last.len);
        @memcpy(self.last[0..len], line[0..len]);
        self.last_len = len;
        try self.out.stderr("verde lease: {s}\n", .{line});
    }

    fn busy(self: *Reporter, holders: []const u8) !void {
        if (holders.len == 0) return self.report("resource busy; waiting.");
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "waiting: {s}. Starts as soon as it is released.", .{holders}) catch holders;
        try self.report(line);
    }

    fn queued(self: *Reporter, arena: std.mem.Allocator, ahead: Record, now_ms: i64) !void {
        _ = now_ms;
        const line = try std.fmt.allocPrint(arena, "queued behind {s} (`{s}`), which asked first.", .{ ahead.owner, ahead.command });
        try self.report(line);
    }

    fn unreachable_app(self: *Reporter) !void {
        try self.report("Verde is not answering; retrying.");
    }

    /// Explains, once per run, why an identical in-flight run is not reused.
    fn staleIdentical(self: *Reporter, arena: std.mem.Allocator, other: Record, me: Record, now_ms: i64) !void {
        if (std.mem.eql(u8, other.run_id, self.stale_reported[0..self.stale_len])) return;
        const len = @min(other.run_id.len, self.stale_reported.len);
        @memcpy(self.stale_reported[0..len], other.run_id[0..len]);
        self.stale_len = len;
        const age_ms = now_ms - (if (other.started_ms > 0) other.started_ms else other.queued_ms);
        if (!other.inputs.known or !me.inputs.known) {
            try self.out.stderr("verde lease: identical `{s}` is in progress ({s}), but this is not a git checkout, so changes cannot be compared; will run again after it.\n", .{ me.command, other.owner });
            return;
        }
        try self.out.stderr(
            "verde lease: identical `{s}` is in progress ({s}, {d}s), but these sources changed since it started, so it would not include them:\n",
            .{ me.command, other.owner, @divTrunc(age_ms, 1000) },
        );
        const changed = try changedPathsAlloc(arena, other.inputs, me.inputs);
        try printChanged(self.out, other.inputs, me.inputs, changed);
        try self.out.stderr("verde lease: will run again with these changes once it finishes.\n", .{});
    }
};

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const slice = std.mem.span(value);
    return if (slice.len == 0) null else slice;
}

test "lease run follows an identical run only when sources are unchanged" {
    const clean: Inputs = .{ .known = true, .head = "abc", .files = &.{} };
    const edited: Inputs = .{ .known = true, .head = "abc", .files = &.{"src/x.zig\t1\t1"} };
    const pid = platform_runtime.processId();
    var running: Record = .{ .run_id = "a", .pid = pid, .workspace_id = "ws", .command = "mise run dev-build", .cwd = "/r", .resources = &.{"build"}, .state = .running, .queued_ms = 1, .heartbeat_ms = 10_000, .inputs = clean };
    var me = running;
    me.run_id = "b";
    me.state = .waiting;
    me.queued_ms = 2;
    var stale: ?usize = null;
    try std.testing.expectEqual(Decision{ .join = 0 }, decide(me, &.{running}, 10_000, true, &stale));
    me.inputs = edited;
    try std.testing.expectEqual(Decision.acquire, decide(me, &.{running}, 10_000, true, &stale));
    try std.testing.expectEqual(@as(?usize, 0), stale);
    running.state = .done;
    running.exit_code = 0;
    running.finished_ms = 9_000;
    me.inputs = clean;
    try std.testing.expectEqual(Decision{ .reuse = 0 }, decide(me, &.{running}, 10_000, true, &stale));
}

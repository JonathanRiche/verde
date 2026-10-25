//! Sidebar view of `verde lease run` wrappers: which chat is waiting for a
//! shared resource (build, deps, ...) or running a leased command. The CLI
//! wrapper writes one small record per run in `<pref>/lease-runs/`; a record
//! belongs to a chat when its owner is `<thread id>#lease-run:<run id>`
//! (agents pass `--owner <thread id>`). Read on the UI thread, at most once
//! per second, and only while some chat asks.

const std = @import("std");
const builtin = @import("builtin");
const platform_runtime = @import("platform_runtime");

pub const RUNS_DIR = "lease-runs";
const REFRESH_MS: i64 = 1_000;
/// Matches the wrapper's heartbeat staleness: a killed wrapper stops counting.
const HEARTBEAT_STALE_MS: i64 = 30_000;
const MAX_RECORD_BYTES: usize = 256 * 1024;
const MAX_ENTRIES = 32;

pub const Phase = enum { waiting, running };

pub const Status = struct {
    phase: Phase,
    /// First leased resource, e.g. "build".
    resource: []const u8,
};

const Entry = struct {
    owner_buf: [128]u8 = undefined,
    owner_len: usize = 0,
    resource_buf: [32]u8 = undefined,
    resource_len: usize = 0,
    phase: Phase = .waiting,
};

var entries: [MAX_ENTRIES]Entry = undefined;
var entry_count: usize = 0;
var refreshed_ms: i64 = 0;

/// Live wrapper status for `thread_id`, if one of its commands is waiting for
/// or holding a lease. Running wins over waiting.
pub fn forThread(pref_path: []const u8, thread_id: []const u8) ?Status {
    if (thread_id.len == 0) return null;
    refresh(pref_path);
    var found: ?Status = null;
    for (entries[0..entry_count]) |*entry| {
        const owner = entry.owner_buf[0..entry.owner_len];
        if (owner.len <= thread_id.len or !std.mem.startsWith(u8, owner, thread_id) or owner[thread_id.len] != '#') continue;
        const status: Status = .{ .phase = entry.phase, .resource = entry.resource_buf[0..entry.resource_len] };
        if (status.phase == .running) return status;
        found = status;
    }
    return found;
}

/// Sidebar label: "Waiting · build" while queued, "Building" (or
/// "Running deps") while the leased command runs.
pub fn label(buf: []u8, status: Status) []const u8 {
    return switch (status.phase) {
        .waiting => std.fmt.bufPrint(buf, "Waiting · {s}", .{status.resource}) catch "Waiting",
        .running => if (std.mem.eql(u8, status.resource, "build"))
            "Building"
        else
            std.fmt.bufPrint(buf, "Running {s}", .{status.resource}) catch "Running",
    };
}

const Record = struct {
    owner: []const u8 = "",
    resources: []const []const u8 = &.{},
    state: []const u8 = "",
    pid: u32 = 0,
    heartbeat_ms: i64 = 0,
};

fn refresh(pref_path: []const u8) void {
    const now_ms = platform_runtime.unixTimestampMs();
    if (now_ms - refreshed_ms < REFRESH_MS) return;
    refreshed_ms = now_ms;
    entry_count = 0;

    var buffer: [4096]u8 = undefined;
    const runs_path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ pref_path, RUNS_DIR }) catch return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, runs_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |item| {
        if (entry_count >= MAX_ENTRIES) break;
        if (item.kind != .file or !std.mem.endsWith(u8, item.name, ".json")) continue;
        const bytes = dir.readFileAlloc(io, item.name, arena.allocator(), .limited(MAX_RECORD_BYTES)) catch continue;
        const record = std.json.parseFromSliceLeaky(Record, arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch continue;
        const phase: Phase = if (std.mem.eql(u8, record.state, "waiting"))
            .waiting
        else if (std.mem.eql(u8, record.state, "running"))
            .running
        else
            continue;
        if (now_ms - record.heartbeat_ms > HEARTBEAT_STALE_MS or !pidAlive(record.pid)) continue;
        const resource = if (record.resources.len > 0) record.resources[0] else "build";
        if (record.owner.len > entries[0].owner_buf.len or resource.len > entries[0].resource_buf.len) continue;
        const entry = &entries[entry_count];
        @memcpy(entry.owner_buf[0..record.owner.len], record.owner);
        entry.owner_len = record.owner.len;
        @memcpy(entry.resource_buf[0..resource.len], resource);
        entry.resource_len = resource.len;
        entry.phase = phase;
        entry_count += 1;
    }
}

fn pidAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) return true; // heartbeat decides
    if (pid == 0) return false;
    const rc = std.c.kill(@intCast(pid), @enumFromInt(0));
    if (rc == 0) return true;
    return std.c.errno(rc) == .PERM;
}

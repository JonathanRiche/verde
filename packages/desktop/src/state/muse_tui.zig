//! Muse TUI lifecycle projection from Muse's durable local session event log.

const std = @import("std");
const process_env = @import("../platform/env.zig");

const POLL_INTERVAL_MS: i64 = 500;
const DISCOVERY_PREFIX_BYTES: usize = 1024 * 1024;
const READ_CHUNK_BYTES: usize = 4 * 1024 * 1024;
const DISCOVERY_CLOCK_SLOP_MS: i64 = 60_000;

pub const Event = enum {
    title_changed,
    working,
    done,
    cancelled,
    failed,
};

pub const Batch = struct {
    events: [32]Event = undefined,
    len: usize = 0,

    fn append(self: *Batch, event: Event) void {
        if (self.len == self.events.len) return;
        self.events[self.len] = event;
        self.len += 1;
    }

    pub fn slice(self: *const Batch) []const Event {
        return self.events[0..self.len];
    }
};

pub const Tracker = struct {
    session_log_path: ?[]u8 = null,
    session_id: ?[]u8 = null,
    title: ?[]u8 = null,
    byte_offset: u64 = 0,
    last_poll_ms: i64 = 0,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        if (self.session_log_path) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn reset(self: *Tracker, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    fn replaceOwned(self: *Tracker, allocator: std.mem.Allocator, field: enum { session_id, title }, value: []const u8) !bool {
        if (value.len == 0) return false;
        const target = switch (field) {
            .session_id => &self.session_id,
            .title => &self.title,
        };
        if (target.*) |old| {
            if (std.mem.eql(u8, old, value)) return false;
        }
        const owned = try allocator.dupe(u8, value);
        if (target.*) |old| allocator.free(old);
        target.* = owned;
        return true;
    }
};

/// Reads newly committed Muse events for the TUI process identified by PID.
pub fn poll(
    allocator: std.mem.Allocator,
    tracker: *Tracker,
    expected_pid: u32,
    workspace_path: []const u8,
    process_started_at_ms: i64,
    now_ms: i64,
) !Batch {
    if (tracker.last_poll_ms != 0 and now_ms - tracker.last_poll_ms < POLL_INTERVAL_MS) return .{};
    tracker.last_poll_ms = now_ms;

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    if (tracker.session_log_path == null) {
        tracker.session_log_path = try discoverSessionLogAlloc(
            allocator,
            io,
            expected_pid,
            workspace_path,
            process_started_at_ms,
        );
    }
    const session_log_path = tracker.session_log_path orelse return .{};

    var file = try std.Io.Dir.cwd().openFile(io, session_log_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (tracker.byte_offset > stat.size) tracker.byte_offset = 0;
    const available = stat.size - tracker.byte_offset;
    if (available == 0) return .{};

    const read_len: usize = @intCast(@min(available, READ_CHUNK_BYTES));
    const bytes = try allocator.alloc(u8, read_len);
    defer allocator.free(bytes);
    const bytes_read = try file.readPositionalAll(io, bytes, tracker.byte_offset);
    const complete_len = if (std.mem.lastIndexOfScalar(u8, bytes[0..bytes_read], '\n')) |newline| newline + 1 else 0;
    if (complete_len == 0) return .{};

    var batch: Batch = .{};
    try parseCompleteLines(allocator, tracker, bytes[0..complete_len], &batch);
    tracker.byte_offset += complete_len;
    return batch;
}

fn discoverSessionLogAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    expected_pid: u32,
    workspace_path: []const u8,
    process_started_at_ms: i64,
) !?[]u8 {
    const sessions_root = try museSessionsRootAlloc(allocator);
    defer allocator.free(sessions_root);
    var sessions_dir = std.Io.Dir.openDirAbsolute(io, sessions_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer sessions_dir.close(io);
    var walker = try sessions_dir.walk(allocator);
    defer walker.deinit();

    var best_path: ?[]u8 = null;
    errdefer if (best_path) |value| allocator.free(value);
    var best_mtime_ms: i64 = std.math.minInt(i64);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "session.jsonl")) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        const mtime_ms = stat.mtime.toMilliseconds();
        if (mtime_ms + DISCOVERY_CLOCK_SLOP_MS < process_started_at_ms or mtime_ms <= best_mtime_ms) continue;
        const prefix_len: usize = @intCast(@min(stat.size, DISCOVERY_PREFIX_BYTES));
        const prefix = allocator.alloc(u8, prefix_len) catch continue;
        defer allocator.free(prefix);
        var file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
        defer file.close(io);
        const bytes_read = file.readPositionalAll(io, prefix, 0) catch continue;
        if (!routeFactsMatch(prefix[0..bytes_read], expected_pid, workspace_path)) continue;

        const path = try std.fs.path.join(allocator, &.{ sessions_root, entry.path });
        if (best_path) |old| allocator.free(old);
        best_path = path;
        best_mtime_ms = mtime_ms;
    }
    return best_path;
}

fn museSessionsRootAlloc(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    if (env_map.get("XDG_DATA_HOME")) |root| return std.fs.path.join(allocator, &.{ root, "muse", "sessions" });
    const home = env_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "muse", "sessions" });
}

fn routeFactsMatch(bytes: []const u8, expected_pid: u32, workspace_path: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const payload_type = getOptionalObjectString(parsed.value, "payload_type") orelse continue;
        if (!std.mem.eql(u8, payload_type, "runtime.session.route_facts")) continue;
        const payload = getObjectField(parsed.value, "payload") orelse continue;
        const record = getObjectField(payload, "record") orelse continue;
        const pid = getOptionalObjectInteger(record, "pid") orelse continue;
        const cwd = getOptionalObjectString(record, "cwd") orelse continue;
        return pid == expected_pid and std.mem.eql(u8, cwd, workspace_path);
    }
    return false;
}

fn parseCompleteLines(allocator: std.mem.Allocator, tracker: *Tracker, bytes: []const u8, batch: *Batch) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const stream = getObjectField(parsed.value, "stream");
        if (stream) |value| {
            if (getOptionalObjectString(value, "id")) |session_id| {
                _ = try tracker.replaceOwned(allocator, .session_id, session_id);
            }
        }
        const payload_type = getOptionalObjectString(parsed.value, "payload_type") orelse continue;
        const payload = getObjectField(parsed.value, "payload") orelse continue;
        if (std.mem.eql(u8, payload_type, "session.name.changed")) {
            const title = getOptionalObjectString(payload, "new_name") orelse continue;
            if (try tracker.replaceOwned(allocator, .title, title)) batch.append(.title_changed);
            continue;
        }
        if (!std.mem.eql(u8, payload_type, "runtime.session")) continue;
        const kind = getOptionalObjectString(payload, "kind") orelse continue;
        if (!std.mem.eql(u8, kind, "run")) continue;
        const event = getObjectField(payload, "event") orelse continue;
        const event_kind = getOptionalObjectString(event, "kind") orelse continue;
        if (std.mem.eql(u8, event_kind, "started")) {
            batch.append(.working);
        } else if (std.mem.eql(u8, event_kind, "terminal")) {
            const terminal = getOptionalObjectString(event, "terminal") orelse "failed";
            if (std.mem.eql(u8, terminal, "completed"))
                batch.append(.done)
            else if (std.mem.eql(u8, terminal, "cancelled"))
                batch.append(.cancelled)
            else
                batch.append(.failed);
        }
    }
}

fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getOptionalObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn getOptionalObjectInteger(value: std.json.Value, key: []const u8) ?i64 {
    const field = getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |number| number,
        else => null,
    };
}

test "Muse TUI log parser preserves ordered title and lifecycle events" {
    const payload =
        \\{"stream":{"kind":"session","id":"session-1"},"payload_type":"session.name.changed","payload":{"new_name":"foggy-betelgeuse"}}
        \\{"stream":{"kind":"session","id":"session-1"},"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"started","prompt":"hi"}}}
        \\{"stream":{"kind":"session","id":"session-1"},"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"terminal","terminal":"completed"}}}
    ;
    var tracker: Tracker = .{};
    defer tracker.deinit(std.testing.allocator);
    var batch: Batch = .{};
    try parseCompleteLines(std.testing.allocator, &tracker, payload, &batch);
    try std.testing.expectEqualStrings("session-1", tracker.session_id.?);
    try std.testing.expectEqualStrings("foggy-betelgeuse", tracker.title.?);
    try std.testing.expectEqualSlices(Event, &.{ .title_changed, .working, .done }, batch.slice());
}

test "Muse TUI route facts bind logs to the launched process and workspace" {
    const payload =
        \\{"payload_type":"runtime.session.route_facts","payload":{"record":{"cwd":"/work/verde","pid":4242}}}
    ;
    try std.testing.expect(routeFactsMatch(payload, 4242, "/work/verde"));
    try std.testing.expect(!routeFactsMatch(payload, 4243, "/work/verde"));
    try std.testing.expect(!routeFactsMatch(payload, 4242, "/work/other"));
}

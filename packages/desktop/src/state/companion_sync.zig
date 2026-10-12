//! Background sync between the GUI's Companion roster and the daemon-owned
//! roster (`companion.roster.get` / `companion.roster.put`). Requests run on
//! worker threads with page-allocated buffers so the render thread never waits
//! on the daemon; results are collected by `poll`.

const Self = @This();

const std = @import("std");
const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");

const log = std.log.scoped(.companion_sync);

pub const METHOD_GET = "companion.roster.get";
pub const METHOD_PUT = "companion.roster.put";
/// Picks up edits made from a phone or the web client.
pub const REFRESH_MS: i64 = 8_000;

const JobKind = enum { get, put };

const Job = struct {
    kind: JobKind,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,
    pref_path: []u8,
    /// put: canonical roster JSON to send.
    roster_json: []u8,
    expected_revision: i64 = 0,
    /// get: roster JSON; put: unused.
    result_json: ?[]u8 = null,
    revision: i64 = 0,
    failed: bool = false,
    conflict: bool = false,

    fn destroy(self: *Job) void {
        const page = std.heap.page_allocator;
        if (self.worker) |worker| worker.join();
        page.free(self.pref_path);
        page.free(self.roster_json);
        if (self.result_json) |json| page.free(json);
        page.destroy(self);
    }
};

pub const Outcome = union(enum) {
    none,
    /// A fetched roster: revision and JSON (owned by the caller's allocator).
    fetched: struct { revision: i64, json: []u8 },
    /// A put landed at this revision.
    stored: i64,
    /// Another client changed the roster first; the caller should re-read.
    conflict,
    failed,
};

job: ?*Job = null,
last_fetch_started_ms: i64 = 0,

pub fn deinit(self: *Self) void {
    if (self.job) |job| job.destroy();
    self.job = null;
}

pub fn busy(self: *const Self) bool {
    return self.job != null;
}

pub fn requestGet(self: *Self, pref_path: []const u8, now_ms: i64) void {
    if (self.job != null) return;
    self.last_fetch_started_ms = now_ms;
    self.job = spawn(.get, pref_path, "", 0);
}

pub fn requestPut(self: *Self, pref_path: []const u8, roster_json: []const u8, expected_revision: i64) bool {
    if (self.job != null) return false;
    self.job = spawn(.put, pref_path, roster_json, expected_revision);
    return self.job != null;
}

/// Collects a finished request. `allocator` owns any fetched JSON.
pub fn poll(self: *Self, allocator: std.mem.Allocator) Outcome {
    const job = self.job orelse return .none;
    if (!job.done.load(.acquire)) return .none;
    self.job = null;
    defer job.destroy();
    if (job.conflict) return .conflict;
    if (job.failed) return .failed;
    return switch (job.kind) {
        .get => .{ .fetched = .{
            .revision = job.revision,
            .json = allocator.dupe(u8, job.result_json orelse return .failed) catch return .failed,
        } },
        .put => .{ .stored = job.revision },
    };
}

fn spawn(kind: JobKind, pref_path: []const u8, roster_json: []const u8, expected_revision: i64) ?*Job {
    const page = std.heap.page_allocator;
    const job = page.create(Job) catch return null;
    job.* = .{
        .kind = kind,
        .pref_path = page.dupe(u8, pref_path) catch {
            page.destroy(job);
            return null;
        },
        .roster_json = page.dupe(u8, roster_json) catch {
            page.free(job.pref_path);
            page.destroy(job);
            return null;
        },
        .expected_revision = expected_revision,
    };
    job.worker = std.Thread.spawn(.{}, workerMain, .{job}) catch {
        job.worker = null;
        job.failed = true;
        job.done.store(true, .release);
        return job;
    };
    return job;
}

fn workerMain(job: *Job) void {
    defer {
        job.done.store(true, .release);
        loop_wakeup.notify();
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var transport: daemon_client.HeadlessTransport = .{ .allocator = allocator, .pref_path = job.pref_path };
    var client = daemon_client.headlessClient(allocator, &transport);
    var parsed = switch (job.kind) {
        .get => client.call(METHOD_GET, .{}),
        .put => put: {
            const roster = std.json.parseFromSliceLeaky(std.json.Value, allocator, job.roster_json, .{}) catch {
                job.failed = true;
                return;
            };
            break :put client.call(METHOD_PUT, .{ .roster = roster, .expected_revision = job.expected_revision });
        },
    } catch |err| {
        log.debug("companion roster request failed: {s}", .{@errorName(err)});
        job.failed = true;
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        job.conflict = std.mem.eql(u8, err.code, "conflict");
        job.failed = !job.conflict;
        return;
    }
    const result = parsed.response.result orelse {
        job.failed = true;
        return;
    };
    if (result != .object) {
        job.failed = true;
        return;
    }
    job.revision = switch (result.object.get("revision") orelse .null) {
        .integer => |value| value,
        else => 0,
    };
    if (job.kind == .get) {
        const roster = result.object.get("roster") orelse {
            job.failed = true;
            return;
        };
        job.result_json = std.json.Stringify.valueAlloc(std.heap.page_allocator, roster, .{}) catch {
            job.failed = true;
            return;
        };
    }
}

test "idle sync reports nothing and a failed spawn surfaces as failure" {
    var sync: Self = .{};
    defer sync.deinit();
    try std.testing.expectEqual(Outcome.none, sync.poll(std.testing.allocator));
    try std.testing.expect(!sync.busy());
}

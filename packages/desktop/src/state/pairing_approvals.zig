//! Owner side of pairing by approval: "lightning (j.riche64@) wants to
//! connect · Allow / Deny" on the machine being reached.
//!
//! The local daemon queues requests that arrive through Tailscale Serve and
//! publishes a `notification` change (`access.pairing.requests`) whenever the
//! set changes. The change-cursor thread raises `signalChanged`; this state
//! re-reads `daemon.access.pairing.request.list` on a worker thread and shows
//! the oldest unexpired request. The list is also read once at startup, so a
//! request that arrived while the app was closed still shows until it expires.

const std = @import("std");
const headless = @import("headless");
const access = headless.access_protocol;
const daemon = @import("../daemon/client.zig");
const clock = @import("platform_runtime");
const loop_wakeup = @import("loop_wakeup");

const log = std.log.scoped(.native_pairing_approvals);
const allocator = std.heap.page_allocator;

pub const PRESETS = access.PAIRING_PRESETS;

/// Set from the change-cursor thread; consumed by the frame thread.
var change_signal: std.atomic.Value(bool) = .init(true);

/// True for the journal entry the daemon publishes on queue changes.
pub fn isChangeEntry(topic: []const u8, resource_id: []const u8) bool {
    return std.mem.eql(u8, topic, "notification") and std.mem.eql(u8, resource_id, access.PAIRING_REQUEST_CHANGE_RESOURCE);
}

pub fn signalChanged() void {
    change_signal.store(true, .release);
}

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), value: []const u8) void {
            const len = @min(value.len, capacity);
            @memcpy(self.bytes[0..len], value[0..len]);
            self.len = len;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Request = struct {
    request_id: [access.GRANT_ID_HEX_BYTES]u8 = undefined,
    device_label: Text(access.MAX_DEVICE_LABEL_BYTES) = .{},
    requester_login: Text(access.MAX_REQUESTER_LOGIN_BYTES) = .{},
    match_code: [access.PAIR_MATCH_CODE_LEN]u8 = undefined,
    expires_at_ms: i64 = 0,

    /// "lightning (j.riche64@) wants to connect"
    pub fn headline(self: *const Request, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s} ({s}) wants to connect", .{
            self.device_label.slice(),
            access.requesterLoginShort(self.requester_login.slice()),
        }) catch self.device_label.slice();
    }
};

pub const MAX_REQUESTS = access.MAX_PENDING_PAIR_REQUESTS;
const LIST_RETRY_MS: i64 = 5_000;

/// Keyboard focus inside the prompt, by identity.
pub const Focus = enum { none, presets, deny, allow };

pub const State = struct {
    requests: [MAX_REQUESTS]Request = undefined,
    count: usize = 0,
    job: ?*Job = null,
    preset: access.PairingPreset = .full,
    focus: Focus = .none,
    focus_visible: bool = false,
    notice: []const u8 = "",
    /// Request id the last decision was sent for; hidden until the list
    /// refresh confirms it left the queue.
    deciding: ?[access.GRANT_ID_HEX_BYTES]u8 = null,
    /// A failed list read (daemon not up yet) is retried once this passes.
    retry_at_ms: ?i64 = null,
    /// Redraw once per second while a prompt shows its countdown.
    last_second: i64 = 0,

    pub fn deinit(self: *State) void {
        if (self.job) |job| job.abandon();
        self.job = null;
    }

    /// The prompt shown now: the oldest unexpired request not being decided.
    pub fn current(self: *const State, now_ms: i64) ?*const Request {
        for (self.requests[0..self.count]) |*request| {
            if (request.expires_at_ms <= now_ms) continue;
            if (self.deciding) |id| if (std.mem.eql(u8, &id, &request.request_id)) continue;
            return request;
        }
        return null;
    }

    pub fn open(self: *const State) bool {
        return self.current(clock.unixTimestampMs()) != null;
    }

    pub fn pendingCount(self: *const State, now_ms: i64) usize {
        var count: usize = 0;
        for (self.requests[0..self.count]) |*request| {
            if (request.expires_at_ms > now_ms) count += 1;
        }
        return count;
    }

    /// Frame-thread poll: start a refresh when signaled, apply finished jobs,
    /// and drop requests whose two minutes ran out. Returns true on change.
    pub fn poll(self: *State, pref_path: []const u8, now_ms: i64) bool {
        var changed = false;
        if (self.job) |job| if (job.finished()) {
            job.join();
            changed = true;
            self.job = null;
            if (job.failed) {
                if (job.operation == .decide) self.notice = "Couldn't reach Verde on this machine. Try again.";
                if (job.operation == .list) self.retry_at_ms = now_ms + LIST_RETRY_MS;
                self.deciding = null;
            } else if (job.operation == .list) {
                self.apply(job.requests[0..job.count], job.now_ms, now_ms);
            } else {
                self.notice = "";
                // Re-read so the queue reflects the decision.
                signalChanged();
            }
            job.destroy();
        };
        if (self.retry_at_ms) |retry_at| if (now_ms >= retry_at) {
            self.retry_at_ms = null;
            signalChanged();
        };
        if (self.job == null and change_signal.swap(false, .acq_rel)) {
            self.job = Job.startList(pref_path) catch |err| blk: {
                log.warn("pairing request list failed to start: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
        // Expiry is local: no daemon round trip is needed to hide a prompt.
        var kept: usize = 0;
        for (self.requests[0..self.count]) |request| {
            if (request.expires_at_ms <= now_ms) continue;
            self.requests[kept] = request;
            kept += 1;
        }
        if (kept != self.count) {
            self.count = kept;
            changed = true;
        }
        if (self.count == 0 and self.focus != .none) self.focus = .none;
        if (self.count > 0) {
            const second = @divFloor(now_ms, 1000);
            if (second != self.last_second) {
                self.last_second = second;
                changed = true;
            }
        }
        return changed;
    }

    /// Replace the list with a daemon snapshot. Expiry times are rebased from
    /// the daemon clock onto ours (same machine, but do not assume it).
    pub fn apply(self: *State, records: []const Request, daemon_now_ms: i64, now_ms: i64) void {
        const skew = now_ms - daemon_now_ms;
        const previous_first = if (self.count > 0) self.requests[0].request_id else null;
        self.count = @min(records.len, MAX_REQUESTS);
        for (records[0..self.count], 0..) |record, index| {
            self.requests[index] = record;
            self.requests[index].expires_at_ms = record.expires_at_ms + skew;
        }
        if (self.deciding) |id| {
            var still_listed = false;
            for (self.requests[0..self.count]) |request| {
                if (std.mem.eql(u8, &request.request_id, &id)) still_listed = true;
            }
            if (!still_listed) self.deciding = null;
        }
        // A new request at the front gets the default preset again.
        const first_changed = if (self.count == 0) true else if (previous_first) |id| !std.mem.eql(u8, &id, &self.requests[0].request_id) else true;
        if (first_changed) {
            self.preset = .full;
            self.focus = .none;
            self.notice = "";
        }
    }

    /// Allow (with the chosen preset) or Deny the visible request.
    pub fn decide(self: *State, pref_path: []const u8, allow: bool) void {
        const request = self.current(clock.unixTimestampMs()) orelse return;
        if (self.job) |job| {
            // A list refresh is in flight; the decision supersedes its result.
            job.abandon();
            self.job = null;
        }
        self.job = Job.startDecide(pref_path, request.request_id, allow, self.preset) catch {
            self.notice = "Couldn't reach Verde on this machine. Try again.";
            return;
        };
        self.deciding = request.request_id;
        self.focus = .none;
    }

    pub fn selectPreset(self: *State, preset: access.PairingPreset) void {
        self.preset = preset;
    }

    /// Arrow keys inside the preset tab list.
    pub fn stepPreset(self: *State, forward: bool) void {
        const index = std.mem.indexOfScalar(access.PairingPreset, &PRESETS, self.preset) orelse 0;
        const next = if (forward) (index + 1) % PRESETS.len else (index + PRESETS.len - 1) % PRESETS.len;
        self.preset = PRESETS[next];
    }

    /// Tab order: presets (one stop), Deny, Allow.
    pub fn cycleFocus(self: *State, backwards: bool) void {
        const order = [_]Focus{ .presets, .deny, .allow };
        const index: usize = switch (self.focus) {
            .none => if (backwards) 0 else order.len - 1,
            .presets => 0,
            .deny => 1,
            .allow => 2,
        };
        const next = if (backwards) (index + order.len - 1) % order.len else (index + 1) % order.len;
        self.focus = order[next];
        self.focus_visible = true;
    }
};

pub fn presetLabel(preset: access.PairingPreset) []const u8 {
    return switch (preset) {
        .full => "Full",
        .chat => "Chat",
        .monitor => "Monitor",
    };
}

pub fn presetDescription(preset: access.PairingPreset) []const u8 {
    return switch (preset) {
        .full => "Everything: chats, terminals, repositories and processes.",
        .chat => "Chat with supervised access; read terminals and repositories.",
        .monitor => "Read-only: watch chats, terminals, repositories and processes.",
    };
}

const Operation = enum { list, decide };
const Lifecycle = enum(u8) { running, finished, abandoned };

const Job = struct {
    operation: Operation,
    pref_path: []u8,
    request_id: [access.GRANT_ID_HEX_BYTES]u8 = undefined,
    allow: bool = false,
    preset: access.PairingPreset = .full,
    thread: ?std.Thread = null,
    lifecycle: std.atomic.Value(Lifecycle) = .init(.running),
    failed: bool = false,
    requests: [MAX_REQUESTS]Request = undefined,
    count: usize = 0,
    now_ms: i64 = 0,

    fn startList(pref_path: []const u8) !*Job {
        return start(.{ .operation = .list, .pref_path = undefined }, pref_path);
    }

    fn startDecide(pref_path: []const u8, request_id: [access.GRANT_ID_HEX_BYTES]u8, allow: bool, preset: access.PairingPreset) !*Job {
        return start(.{ .operation = .decide, .pref_path = undefined, .request_id = request_id, .allow = allow, .preset = preset }, pref_path);
    }

    fn start(template: Job, pref_path: []const u8) !*Job {
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        job.* = template;
        job.pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(job.pref_path);
        job.thread = try std.Thread.spawn(.{}, worker, .{job});
        return job;
    }

    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn destroy(self: *Job) void {
        allocator.free(self.pref_path);
        allocator.destroy(self);
    }

    fn finished(self: *Job) bool {
        return self.lifecycle.load(.acquire) == .finished;
    }

    /// Detach a running job; the worker frees it when the daemon call returns.
    /// Exactly one side wins the swap, so the job is freed exactly once.
    fn abandon(self: *Job) void {
        if (self.lifecycle.swap(.abandoned, .acq_rel) == .finished) {
            self.join();
            self.destroy();
        } else if (self.thread) |thread| thread.detach();
    }

    fn worker(self: *Job) void {
        self.run() catch |err| {
            log.warn("pairing request {s} failed: {s}", .{ @tagName(self.operation), @errorName(err) });
            self.failed = true;
        };
        if (self.lifecycle.swap(.finished, .acq_rel) == .abandoned) {
            self.destroy();
            return;
        }
        _ = loop_wakeup.notify();
    }

    fn run(self: *Job) !void {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var transport: daemon.HeadlessTransport = .{ .allocator = a, .pref_path = self.pref_path };
        var client = daemon.headlessClient(a, &transport);
        switch (self.operation) {
            .list => {
                var response = try client.call(access.METHOD_DAEMON_PAIRING_REQUEST_LIST, access.PairingRequestListRequest{
                    .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
                });
                defer response.deinit();
                const value = response.response.result orelse return error.DaemonRequestFailed;
                const result = try std.json.parseFromValueLeaky(access.PairingRequestListResult, a, value, .{ .ignore_unknown_fields = true });
                self.now_ms = result.now_ms;
                self.count = recordsToRequests(result.requests, &self.requests);
            },
            .decide => {
                var response = try client.call(access.METHOD_DAEMON_PAIRING_REQUEST_DECIDE, access.PairingRequestDecideRequest{
                    .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
                    .request_id = &self.request_id,
                    .allow = self.allow,
                    .preset = self.preset,
                });
                defer response.deinit();
                if (response.response.result == null) {
                    // Already decided or expired elsewhere: refresh shows the truth.
                    const code = if (response.response.err) |err| err.code else "";
                    if (!std.mem.eql(u8, code, "pairing_request_not_pending") and !std.mem.eql(u8, code, "unknown_pairing_request")) return error.DaemonRequestFailed;
                }
            },
        }
    }
};

/// Validate and copy daemon records; malformed entries are skipped.
pub fn recordsToRequests(records: []const access.PairingRequestRecord, out: []Request) usize {
    var count: usize = 0;
    for (records) |record| {
        if (count == out.len) break;
        if (record.status != .pending) continue;
        access.validatePairRequestId(record.request_id) catch continue;
        access.validateDeviceLabel(record.device_label) catch continue;
        access.validateRequesterLogin(record.requester_login) catch continue;
        access.validateMatchCode(record.match_code) catch continue;
        var request: Request = .{ .expires_at_ms = record.expires_at_ms };
        @memcpy(&request.request_id, record.request_id);
        request.device_label.set(record.device_label);
        request.requester_login.set(record.requester_login);
        @memcpy(&request.match_code, record.match_code);
        out[count] = request;
        count += 1;
    }
    return count;
}

test "prompt shows the oldest unexpired request and hides it locally on expiry" {
    const records = [_]access.PairingRequestRecord{
        .{ .request_id = "0123456789abcdef0123456789abcdef", .device_label = "lightning", .requester_login = "j.riche64@example.com", .match_code = "4F2K", .created_at_ms = 0, .expires_at_ms = 120_000, .status = .pending },
        .{ .request_id = "fedcba9876543210fedcba9876543210", .device_label = "mini", .requester_login = "j.riche64@example.com", .match_code = "7XYZ", .created_at_ms = 10, .expires_at_ms = 130_000, .status = .pending },
        .{ .request_id = "not-hex", .device_label = "bad", .requester_login = "x@y", .match_code = "4F2K", .created_at_ms = 0, .expires_at_ms = 1, .status = .pending },
    };
    var requests: [MAX_REQUESTS]Request = undefined;
    const count = recordsToRequests(&records, &requests);
    try std.testing.expectEqual(@as(usize, 2), count);

    var state: State = .{};
    defer state.deinit();
    state.preset = .monitor;
    // Daemon clock 1s behind ours: expiry is rebased.
    state.apply(requests[0..count], 1_000, 2_000);
    try std.testing.expectEqual(access.PairingPreset.full, state.preset);
    const first = state.current(2_000).?;
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("lightning (j.riche64@) wants to connect", first.headline(&buffer));
    try std.testing.expectEqualStrings("4F2K", &first.match_code);
    try std.testing.expectEqual(@as(i64, 121_000), first.expires_at_ms);
    try std.testing.expectEqualStrings("mini", state.current(121_000).?.device_label.slice());
    try std.testing.expect(state.current(131_000) == null);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount(125_000));
}

test "a decision hides its request until the refreshed list drops it" {
    const records = [_]access.PairingRequestRecord{
        .{ .request_id = "0123456789abcdef0123456789abcdef", .device_label = "lightning", .requester_login = "j@example.com", .match_code = "4F2K", .created_at_ms = 0, .expires_at_ms = 120_000, .status = .pending },
    };
    var requests: [MAX_REQUESTS]Request = undefined;
    const count = recordsToRequests(&records, &requests);
    var state: State = .{};
    defer state.deinit();
    state.apply(requests[0..count], 0, 0);
    state.deciding = requests[0].request_id;
    try std.testing.expect(state.current(1) == null);
    state.apply(requests[0..count], 0, 0);
    try std.testing.expect(state.deciding != null);
    state.apply(&.{}, 0, 0);
    try std.testing.expect(state.deciding == null);
}

test "prompt keyboard order and preset arrows" {
    var state: State = .{};
    state.cycleFocus(false);
    try std.testing.expectEqual(Focus.presets, state.focus);
    state.cycleFocus(false);
    try std.testing.expectEqual(Focus.deny, state.focus);
    state.cycleFocus(false);
    try std.testing.expectEqual(Focus.allow, state.focus);
    state.cycleFocus(false);
    try std.testing.expectEqual(Focus.presets, state.focus);
    state.cycleFocus(true);
    try std.testing.expectEqual(Focus.allow, state.focus);
    try std.testing.expect(state.focus_visible);
    state.stepPreset(true);
    try std.testing.expectEqual(access.PairingPreset.chat, state.preset);
    state.stepPreset(false);
    state.stepPreset(false);
    try std.testing.expectEqual(access.PairingPreset.monitor, state.preset);
    try std.testing.expect(isChangeEntry("notification", access.PAIRING_REQUEST_CHANGE_RESOURCE));
    try std.testing.expect(!isChangeEntry("process", access.PAIRING_REQUEST_CHANGE_RESOURCE));
}

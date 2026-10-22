//! Bounded, in-memory queue of "pair by approval" requests.
//!
//! A tailnet peer submits a request through the gateway; the owner allows or
//! denies it on this machine; the requester polls and receives the one-time
//! pairing grant minted at approval exactly once. Pure and std-only (plus the
//! access DTOs) with an injected clock, like `change_journal.zig`; the daemon
//! guards it with its own leaf lock. Nothing here is durable: a daemon restart
//! drops pending requests, which simply expire on the requesting side.

const std = @import("std");
const access = @import("headless").access_protocol;

/// Pending requests plus recently finished ones kept as short tombstones so
/// the requester can read a clear denied/expired result.
pub const CAPACITY: usize = 16;
/// How long a finished (denied/expired/delivered) request answers polls.
pub const TOMBSTONE_MS: i64 = 60 * 1000;

const LABEL_CAP = access.MAX_DEVICE_LABEL_BYTES;
const LOGIN_CAP = access.MAX_REQUESTER_LOGIN_BYTES;
const ADDRESS_CAP = access.MAX_REQUESTER_ADDRESS_BYTES;

pub const Error = error{
    InvalidPairRequest,
    /// The same request id is already queued for a different requester.
    DuplicatePairRequest,
    /// The bounded queue has no free slot for another pending request.
    PairRequestQueueFull,
    /// This requester already has the maximum number of pending requests.
    TooManyPairRequests,
    UnknownPairRequest,
    /// The request was already decided or has expired.
    PairRequestNotPending,
};

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

pub const State = enum {
    pending,
    approved,
    denied,
    expired,
    /// Approved grant already handed to the requester. Reported as expired.
    delivered,

    pub fn wire(self: State) access.PairingRequestStatus {
        return switch (self) {
            .pending => .pending,
            .approved => .approved,
            .denied => .denied,
            .expired, .delivered => .expired,
        };
    }
};

pub const Entry = struct {
    active: bool = false,
    request_id: [access.GRANT_ID_HEX_BYTES]u8 = undefined,
    device_label: Text(LABEL_CAP) = .{},
    requester_login: Text(LOGIN_CAP) = .{},
    requester_name: Text(LABEL_CAP) = .{},
    has_requester_name: bool = false,
    requester_address: Text(ADDRESS_CAP) = .{},
    match_code: [access.PAIR_MATCH_CODE_LEN]u8 = undefined,
    created_at_ms: i64 = 0,
    /// Pending: decision deadline. Approved: grant expiry.
    expires_at_ms: i64 = 0,
    finished_at_ms: i64 = 0,
    state: State = .pending,
    preset: access.PairingPreset = .full,
    grant_id: [access.GRANT_ID_HEX_BYTES]u8 = undefined,
    /// One-time grant secret; zeroed as soon as it is delivered or expires.
    pairing_token: [access.SECRET_HEX_BYTES]u8 = undefined,

    fn clear(self: *Entry) void {
        std.crypto.secureZero(u8, self.pairing_token[0..]);
        self.* = .{};
    }

    fn finish(self: *Entry, state: State, now_ms: i64) void {
        std.crypto.secureZero(u8, self.pairing_token[0..]);
        self.state = state;
        self.finished_at_ms = now_ms;
    }

    pub fn record(self: *const Entry) access.PairingRequestRecord {
        return .{
            .request_id = self.request_id[0..],
            .device_label = self.device_label.slice(),
            .requester_login = self.requester_login.slice(),
            .requester_name = if (self.has_requester_name) self.requester_name.slice() else null,
            .match_code = self.match_code[0..],
            .created_at_ms = self.created_at_ms,
            .expires_at_ms = self.expires_at_ms,
            .status = self.state.wire(),
        };
    }
};

/// Approved poll outcome. The caller must `clear` it after writing the reply.
pub const Delivered = struct {
    grant_id: [access.GRANT_ID_HEX_BYTES]u8,
    pairing_token: [access.SECRET_HEX_BYTES]u8,
    preset: access.PairingPreset,
    match_code: [access.PAIR_MATCH_CODE_LEN]u8,
    expires_at_ms: i64,

    pub fn clear(self: *Delivered) void {
        std.crypto.secureZero(u8, self.pairing_token[0..]);
    }
};

pub const Submitted = struct {
    entry: *const Entry,
    /// False when an identical retry returned the existing request.
    created: bool,
};

pub const PollOutcome = union(enum) {
    /// Unknown id, or a poll from a different identity/address.
    unknown,
    waiting: struct { state: State, match_code: [access.PAIR_MATCH_CODE_LEN]u8, expires_at_ms: i64 },
    approved: Delivered,
};

pub const Queue = struct {
    entries: [CAPACITY]Entry = [_]Entry{.{}} ** CAPACITY,

    pub fn deinit(self: *Queue) void {
        for (&self.entries) |*entry| entry.clear();
    }

    /// Queue one request. Resubmitting the same id from the same requester
    /// returns the existing entry (a lost-response retry), never a second one.
    pub fn submit(
        self: *Queue,
        request: access.PairingRequestSubmitRequest,
        match_code: [access.PAIR_MATCH_CODE_LEN]u8,
        now_ms: i64,
    ) Error!Submitted {
        access.validatePairRequestId(request.request_id) catch return error.InvalidPairRequest;
        access.validateDeviceLabel(request.device_label) catch return error.InvalidPairRequest;
        access.validateRequesterLogin(request.requester_login) catch return error.InvalidPairRequest;
        access.validateMatchCode(&match_code) catch return error.InvalidPairRequest;
        if (request.requester_name) |name| access.validateDeviceLabel(name) catch return error.InvalidPairRequest;
        if (request.requester_address.len == 0 or request.requester_address.len > ADDRESS_CAP) return error.InvalidPairRequest;
        _ = self.sweep(now_ms);

        var pending_total: usize = 0;
        var pending_requester: usize = 0;
        for (&self.entries) |*entry| {
            if (!entry.active) continue;
            if (std.mem.eql(u8, entry.request_id[0..], request.request_id)) {
                if (!sameRequester(entry, request.requester_login, request.requester_address)) return error.DuplicatePairRequest;
                return .{ .entry = entry, .created = false };
            }
            if (entry.state != .pending) continue;
            pending_total += 1;
            if (std.mem.eql(u8, entry.requester_login.slice(), request.requester_login)) pending_requester += 1;
        }
        if (pending_requester >= access.MAX_PENDING_PAIR_REQUESTS_PER_REQUESTER) return error.TooManyPairRequests;
        if (pending_total >= access.MAX_PENDING_PAIR_REQUESTS) return error.PairRequestQueueFull;
        const slot = self.freeSlot() orelse return error.PairRequestQueueFull;
        slot.* = .{
            .active = true,
            .match_code = match_code,
            .created_at_ms = now_ms,
            .expires_at_ms = now_ms + access.PAIR_REQUEST_TTL_MS,
        };
        @memcpy(slot.request_id[0..], request.request_id);
        slot.device_label.set(request.device_label);
        slot.requester_login.set(request.requester_login);
        if (request.requester_name) |name| {
            slot.requester_name.set(name);
            slot.has_requester_name = true;
        }
        slot.requester_address.set(request.requester_address);
        return .{ .entry = slot, .created = true };
    }

    /// Return the pending entry the owner is about to approve. The caller mints
    /// the grant, then calls `completeApproval`.
    pub fn pendingEntry(self: *Queue, request_id: []const u8, now_ms: i64) Error!*Entry {
        _ = self.sweep(now_ms);
        const entry = self.find(request_id) orelse return error.UnknownPairRequest;
        if (entry.state != .pending) return error.PairRequestNotPending;
        return entry;
    }

    pub fn completeApproval(
        entry: *Entry,
        grant_id: []const u8,
        pairing_token: []const u8,
        preset: access.PairingPreset,
        grant_expires_at_ms: i64,
    ) void {
        std.debug.assert(entry.active and entry.state == .pending);
        @memcpy(entry.grant_id[0..], grant_id);
        @memcpy(entry.pairing_token[0..], pairing_token);
        entry.preset = preset;
        entry.expires_at_ms = grant_expires_at_ms;
        entry.state = .approved;
    }

    pub fn deny(self: *Queue, request_id: []const u8, now_ms: i64) Error!void {
        const entry = try self.pendingEntry(request_id, now_ms);
        entry.finish(.denied, now_ms);
    }

    /// Read the decision for the requester that submitted `request_id`.
    /// An approved grant is returned once and wiped from the queue.
    pub fn poll(
        self: *Queue,
        request_id: []const u8,
        requester_login: []const u8,
        requester_address: []const u8,
        now_ms: i64,
    ) PollOutcome {
        _ = self.sweep(now_ms);
        const entry = self.find(request_id) orelse return .unknown;
        if (!sameRequester(entry, requester_login, requester_address)) return .unknown;
        if (entry.state == .approved) {
            const delivered: Delivered = .{
                .grant_id = entry.grant_id,
                .pairing_token = entry.pairing_token,
                .preset = entry.preset,
                .match_code = entry.match_code,
                .expires_at_ms = entry.expires_at_ms,
            };
            entry.finish(.delivered, now_ms);
            return .{ .approved = delivered };
        }
        return .{ .waiting = .{ .state = entry.state, .match_code = entry.match_code, .expires_at_ms = entry.expires_at_ms } };
    }

    /// Expire overdue requests and drop old tombstones. Returns true when the
    /// set of pending requests the owner sees changed.
    pub fn sweep(self: *Queue, now_ms: i64) bool {
        var changed = false;
        for (&self.entries) |*entry| {
            if (!entry.active) continue;
            switch (entry.state) {
                .pending, .approved => if (now_ms >= entry.expires_at_ms) {
                    if (entry.state == .pending) changed = true;
                    entry.finish(.expired, now_ms);
                },
                .denied, .expired, .delivered => if (now_ms - entry.finished_at_ms >= TOMBSTONE_MS) entry.clear(),
            }
        }
        return changed;
    }

    /// Pending requests, oldest first, copied into `out`. Returns the count.
    pub fn pending(self: *Queue, now_ms: i64, out: []access.PairingRequestRecord) usize {
        _ = self.sweep(now_ms);
        var count: usize = 0;
        for (&self.entries) |*entry| {
            if (!entry.active or entry.state != .pending) continue;
            if (count == out.len) break;
            out[count] = entry.record();
            count += 1;
        }
        std.mem.sort(access.PairingRequestRecord, out[0..count], {}, struct {
            fn lessThan(_: void, a: access.PairingRequestRecord, b: access.PairingRequestRecord) bool {
                return a.created_at_ms < b.created_at_ms;
            }
        }.lessThan);
        return count;
    }

    fn find(self: *Queue, request_id: []const u8) ?*Entry {
        if (request_id.len != access.GRANT_ID_HEX_BYTES) return null;
        for (&self.entries) |*entry| {
            if (entry.active and std.crypto.timing_safe.eql([access.GRANT_ID_HEX_BYTES]u8, entry.request_id, request_id[0..access.GRANT_ID_HEX_BYTES].*)) return entry;
        }
        return null;
    }

    fn freeSlot(self: *Queue) ?*Entry {
        for (&self.entries) |*entry| if (!entry.active) return entry;
        // Reuse the oldest tombstone rather than refuse a live request.
        var oldest: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (entry.state == .pending or entry.state == .approved) continue;
            if (oldest == null or entry.finished_at_ms < oldest.?.finished_at_ms) oldest = entry;
        }
        if (oldest) |entry| entry.clear();
        return oldest;
    }
};

fn sameRequester(entry: *const Entry, login: []const u8, address: []const u8) bool {
    return std.mem.eql(u8, entry.requester_login.slice(), login) and
        std.mem.eql(u8, entry.requester_address.slice(), address);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TEST_ID_A = "0123456789abcdef0123456789abcdef";
const TEST_ID_B = "fedcba9876543210fedcba9876543210";
const TEST_GRANT = "00112233445566778899aabbccddeeff";
const TEST_TOKEN = "a" ** access.SECRET_HEX_BYTES;

fn testRequest(id: []const u8, login: []const u8) access.PairingRequestSubmitRequest {
    return .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .request_id = id,
        .device_label = "lightning",
        .requester_login = login,
        .requester_name = "Jonathan",
        .requester_address = "100.64.0.7",
    };
}

test "approval delivers the grant exactly once to the submitting requester" {
    var queue: Queue = .{};
    defer queue.deinit();
    const submitted = try queue.submit(testRequest(TEST_ID_A, "j@example.com"), "4F2K".*, 1_000);
    try std.testing.expect(submitted.created);
    const entry = submitted.entry;
    try std.testing.expectEqualStrings("4F2K", &entry.match_code);
    try std.testing.expectEqual(@as(i64, 1_000 + access.PAIR_REQUEST_TTL_MS), entry.expires_at_ms);

    var records: [4]access.PairingRequestRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), queue.pending(2_000, &records));
    try std.testing.expectEqualStrings("lightning", records[0].device_label);
    try std.testing.expectEqualStrings("Jonathan", records[0].requester_name.?);

    try std.testing.expect(queue.poll(TEST_ID_A, "j@example.com", "100.64.0.7", 2_000).waiting.state == .pending);
    const approving = try queue.pendingEntry(TEST_ID_A, 3_000);
    Queue.completeApproval(approving, TEST_GRANT, TEST_TOKEN, .chat, 3_000 + 120_000);
    try std.testing.expectEqual(@as(usize, 0), queue.pending(3_000, &records));

    // A different tailnet address or identity cannot collect the grant.
    try std.testing.expect(queue.poll(TEST_ID_A, "j@example.com", "100.64.0.8", 4_000) == .unknown);
    try std.testing.expect(queue.poll(TEST_ID_A, "other@example.com", "100.64.0.7", 4_000) == .unknown);

    var delivered = queue.poll(TEST_ID_A, "j@example.com", "100.64.0.7", 4_000).approved;
    defer delivered.clear();
    try std.testing.expectEqualStrings(TEST_GRANT, &delivered.grant_id);
    try std.testing.expectEqualStrings(TEST_TOKEN, &delivered.pairing_token);
    try std.testing.expectEqual(access.PairingPreset.chat, delivered.preset);
    // Replay: the second poll never sees the secret again.
    const again = queue.poll(TEST_ID_A, "j@example.com", "100.64.0.7", 5_000);
    try std.testing.expect(again.waiting.state == .delivered);
    try std.testing.expectEqual(access.PairingRequestStatus.expired, again.waiting.state.wire());
    for (queue.entries) |slot| {
        if (slot.active) try std.testing.expect(std.mem.indexOf(u8, &slot.pairing_token, TEST_TOKEN) == null);
    }
}

test "deny and expiry fail the request clearly and then clean up" {
    var queue: Queue = .{};
    defer queue.deinit();
    _ = try queue.submit(testRequest(TEST_ID_A, "j@example.com"), "4F2K".*, 0);
    _ = try queue.submit(testRequest(TEST_ID_B, "k@example.com"), "7XYZ".*, 0);
    try queue.deny(TEST_ID_A, 10);
    try std.testing.expectError(error.PairRequestNotPending, queue.deny(TEST_ID_A, 11));
    try std.testing.expect(queue.poll(TEST_ID_A, "j@example.com", "100.64.0.7", 20).waiting.state == .denied);

    // Two minutes later the other request expires; approval is refused.
    try std.testing.expect(queue.sweep(access.PAIR_REQUEST_TTL_MS));
    try std.testing.expectError(error.PairRequestNotPending, queue.pendingEntry(TEST_ID_B, access.PAIR_REQUEST_TTL_MS + 1));
    try std.testing.expect(queue.poll(TEST_ID_B, "k@example.com", "100.64.0.7", access.PAIR_REQUEST_TTL_MS + 1).waiting.state == .expired);

    // Tombstones disappear after their retention window.
    _ = queue.sweep(access.PAIR_REQUEST_TTL_MS + TOMBSTONE_MS + 1);
    try std.testing.expect(queue.poll(TEST_ID_B, "k@example.com", "100.64.0.7", access.PAIR_REQUEST_TTL_MS + TOMBSTONE_MS + 2) == .unknown);
    for (queue.entries) |slot| try std.testing.expect(!slot.active);
}

test "an approved grant nobody collects expires and is wiped" {
    var queue: Queue = .{};
    defer queue.deinit();
    _ = try queue.submit(testRequest(TEST_ID_A, "j@example.com"), "4F2K".*, 0);
    Queue.completeApproval(try queue.pendingEntry(TEST_ID_A, 1), TEST_GRANT, TEST_TOKEN, .full, 100);
    _ = queue.sweep(100);
    try std.testing.expect(queue.poll(TEST_ID_A, "j@example.com", "100.64.0.7", 101).waiting.state == .expired);
    for (queue.entries) |slot| {
        if (slot.active) try std.testing.expect(std.mem.indexOf(u8, &slot.pairing_token, TEST_TOKEN) == null);
    }
}

test "queue bounds pending requests per requester and in total" {
    var queue: Queue = .{};
    defer queue.deinit();
    var id_buffer: [32]u8 = undefined;
    var login_buffer: [32]u8 = undefined;
    // Per requester.
    _ = try queue.submit(testRequest(TEST_ID_A, "j@example.com"), "4F2K".*, 0);
    _ = try queue.submit(testRequest(TEST_ID_B, "j@example.com"), "4F2K".*, 0);
    try std.testing.expectError(error.TooManyPairRequests, queue.submit(testRequest("11111111111111111111111111111111", "j@example.com"), "4F2K".*, 0));
    // Same id, same requester: idempotent. Same id, other requester: refused.
    const retry = try queue.submit(testRequest(TEST_ID_A, "j@example.com"), "9999".*, 1);
    try std.testing.expect(!retry.created);
    try std.testing.expectEqualStrings("4F2K", &retry.entry.match_code);
    try std.testing.expectError(error.DuplicatePairRequest, queue.submit(testRequest(TEST_ID_A, "x@example.com"), "4F2K".*, 1));
    // Total.
    var accepted: usize = 2;
    var index: usize = 0;
    while (accepted < access.MAX_PENDING_PAIR_REQUESTS) : (index += 1) {
        const id = std.fmt.bufPrint(&id_buffer, "{x:0>32}", .{index + 0x1000}) catch unreachable;
        const login = std.fmt.bufPrint(&login_buffer, "u{d}@example.com", .{index}) catch unreachable;
        _ = try queue.submit(testRequest(id, login), "4F2K".*, 2);
        accepted += 1;
    }
    try std.testing.expectError(error.PairRequestQueueFull, queue.submit(testRequest("22222222222222222222222222222222", "late@example.com"), "4F2K".*, 3));
    // Bad input never enters the queue.
    var bad = testRequest("33333333333333333333333333333333", "has space@example.com");
    try std.testing.expectError(error.InvalidPairRequest, queue.submit(bad, "4F2K".*, 3));
    bad = testRequest("33333333333333333333333333333333", "ok@example.com");
    try std.testing.expectError(error.InvalidPairRequest, queue.submit(bad, "4F0K".*, 3));
}

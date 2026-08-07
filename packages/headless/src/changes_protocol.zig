//! Wire DTOs for the daemon change journal (`core.changes`).
//!
//! This module deliberately contains only JSON-safe protocol data.  Journal
//! entries carry identity + revision only, never payloads: a cursor answers
//! "changed since", and the client re-reads changed resources through the
//! existing snapshot/read methods.  Topic spellings are the frozen 9-topic
//! set owned by the daemon's change journal (m4m5_decisions Q10).

const std = @import("std");
const protocol = @import("protocol.zig");
const registry_protocol = @import("registry_protocol.zig");

// Stable change-journal method names.  These are wire identifiers and must
// not be changed after publication.
pub const METHOD_CORE_CHANGES: []const u8 = "core.changes";

// Reserved push-streaming method names (m4m5_decisions Q8): the spellings are
// frozen now so the later milestone is purely additive, but they have no
// DTOs and are never dispatched in M5.  The `subscriptions` capability stays
// false for as long as these are undispatched.
pub const METHOD_CORE_SUBSCRIBE: []const u8 = "core.subscribe";
pub const METHOD_CORE_UNSUBSCRIBE: []const u8 = "core.unsubscribe";

pub const CORE_CHANGES_METHOD = METHOD_CORE_CHANGES;
pub const CORE_SUBSCRIBE_METHOD = METHOD_CORE_SUBSCRIBE;
pub const CORE_UNSUBSCRIBE_METHOD = METHOD_CORE_UNSUBSCRIBE;

// Re-export the journal-expiry error code from the one protocol error owner
// (m4m5_decisions Q6).  Error.data carries {floor_seq} for journal expiry.
pub const ERR_REVISION_EXPIRED = protocol.ERR_REVISION_EXPIRED;
pub const ERR_INVALID_PARAMS = protocol.ERR_INVALID_PARAMS;
pub const ERR_INVALID_STATE = protocol.ERR_INVALID_STATE;
pub const ERR_CAPABILITY_UNAVAILABLE = protocol.ERR_CAPABILITY_UNAVAILABLE;

/// One coalesced journal entry.  Exactly one of the two revision fields is
/// set, per topic family: durable topics carry `store_revision`, volatile
/// topics carry `registry_revision`.
pub const ChangeEntry = struct {
    change_seq: u64,
    /// Frozen topic wire spelling (workspace, chat.thread, chat.turn,
    /// chat.completion, surface, process, lease, session, notification).
    topic: []const u8,
    resource_id: []const u8,
    workspace_id: ?[]const u8 = null,
    store_revision: ?u64 = null,
    registry_revision: ?u64 = null,
};

/// Cursor poll over the daemon change journal.
pub const ChangesRequest = struct {
    /// Last change_seq the client has integrated.  Absent bootstraps at the
    /// current journal tail (no historical replay).
    cursor: ?u64 = null,
    /// 0 requests an immediate check.  Positive values ask for a bounded
    /// long-poll; the daemon may clamp (including to 0) per its own limits.
    wait_ms: u32 = 0,
    /// Optional topic filter using the frozen wire spellings; absent means
    /// all topics.
    topics: ?[]const []const u8 = null,
};

/// Reply to `core.changes`.  One reply carries enough revision context to
/// decide any resync (m5_design invariant): the volatile envelope detects
/// daemon replacement and `store_revision` anchors the durable half.
pub const ChangesResult = struct {
    entries: []const ChangeEntry = &.{},
    /// Cursor to supply on the next `core.changes` call.
    next_cursor: u64 = 0,
    /// Oldest change_seq still retained by the bounded journal ring.
    journal_floor_seq: u64 = 0,
    /// True when the supplied cursor fell below the journal floor.  The
    /// entries are unusable for delta catch-up; the client must fall back to
    /// `core.snapshot` and reseed its cursor.
    expired: bool = false,
    /// True for an empty reply produced by a long-poll timeout or the
    /// over-cap wait_ms=0 degradation (m4m5_decisions Q7).
    heartbeat: bool = false,
    /// Volatile revision namespace.  A changed instance_nonce invalidates
    /// the cursor regardless of numeric values.
    envelope: registry_protocol.RegistryRevisionEnvelope = .{},
    /// Durable store revision at reply time.
    store_revision: u64 = 0,
};

/// Encode any changes DTO using the standard JSON object representation.
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(value);
    return try writer.toOwnedSlice();
}

/// Decode a changes DTO while ignoring fields introduced by a newer peer.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// Decode a changes DTO into allocations owned by the caller's arena.
pub fn decodeLeaky(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "changes DTOs round trip every wire shape" {
    const allocator = std.testing.allocator;
    const durable_entry: ChangeEntry = .{
        .change_seq = 11,
        .topic = "chat.thread",
        .resource_id = "thread-1",
        .workspace_id = "workspace-1",
        .store_revision = 9,
    };
    const volatile_entry: ChangeEntry = .{
        .change_seq = 12,
        .topic = "process",
        .resource_id = "process-1",
        .registry_revision = 21,
    };
    const request: ChangesRequest = .{
        .cursor = 10,
        .wait_ms = 2_000,
        .topics = &.{ "chat.thread", "process" },
    };
    const result: ChangesResult = .{
        .entries = &.{ durable_entry, volatile_entry },
        .next_cursor = 12,
        .journal_floor_seq = 3,
        .expired = false,
        .heartbeat = false,
        .envelope = .{ .instance_nonce = "nonce-1", .registry_revision = 21 },
        .store_revision = 9,
    };

    const values = .{
        durable_entry,
        volatile_entry,
        request,
        ChangesRequest{},
        result,
        ChangesResult{ .heartbeat = true, .next_cursor = 10, .journal_floor_seq = 3 },
        ChangesResult{ .expired = true, .journal_floor_seq = 40, .next_cursor = 44 },
    };
    inline for (values) |value| {
        const T = @TypeOf(value);
        const bytes = try encode(allocator, value);
        defer allocator.free(bytes);
        var parsed = try decode(T, allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqualDeep(value, parsed.value);
    }
}

test "unknown fields and absent optionals are tolerated" {
    const allocator = std.testing.allocator;

    var request = try decode(ChangesRequest, allocator, "{\"future_flag\":true}");
    defer request.deinit();
    try std.testing.expect(request.value.cursor == null);
    try std.testing.expectEqual(@as(u32, 0), request.value.wait_ms);
    try std.testing.expect(request.value.topics == null);

    var result = try decode(
        ChangesResult,
        allocator,
        "{\"entries\":[{\"change_seq\":5,\"topic\":\"workspace\",\"resource_id\":\"w1\",\"future\":1}]," ++
            "\"next_cursor\":5,\"future_section\":{}}",
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.value.entries.len);
    try std.testing.expectEqualStrings("workspace", result.value.entries[0].topic);
    try std.testing.expect(result.value.entries[0].store_revision == null);
    try std.testing.expect(result.value.entries[0].registry_revision == null);
    try std.testing.expectEqual(@as(u64, 5), result.value.next_cursor);
    try std.testing.expectEqual(@as(u64, 0), result.value.journal_floor_seq);
    try std.testing.expect(!result.value.expired);
    try std.testing.expect(!result.value.heartbeat);
    try std.testing.expectEqualStrings("", result.value.envelope.instance_nonce);
}

test "changes method names and error codes are pinned" {
    try std.testing.expectEqualStrings("core.changes", METHOD_CORE_CHANGES);
    // Reserved-undispatched spellings (Q8): frozen now, dispatched in a later
    // milestone.  Renaming either is a wire break.
    try std.testing.expectEqualStrings("core.subscribe", METHOD_CORE_SUBSCRIBE);
    try std.testing.expectEqualStrings("core.unsubscribe", METHOD_CORE_UNSUBSCRIBE);
    try std.testing.expectEqualStrings("revision_expired", ERR_REVISION_EXPIRED);
}

test "decode owns strings after the input buffer is released" {
    const allocator = std.testing.allocator;
    const json =
        "{\"entries\":[{\"change_seq\":7,\"topic\":\"chat.turn\",\"resource_id\":\"turn-1\"," ++
        "\"workspace_id\":\"workspace-1\",\"store_revision\":4}],\"next_cursor\":7," ++
        "\"journal_floor_seq\":2,\"envelope\":{\"instance_nonce\":\"nonce-9\",\"registry_revision\":3}}";
    const input = try allocator.dupe(u8, json);
    var input_owned = true;
    defer if (input_owned) allocator.free(input);

    var parsed = try decode(ChangesResult, allocator, input);
    defer parsed.deinit();

    @memset(input, 0xa5);
    allocator.free(input);
    input_owned = false;

    try std.testing.expectEqualStrings("chat.turn", parsed.value.entries[0].topic);
    try std.testing.expectEqualStrings("turn-1", parsed.value.entries[0].resource_id);
    try std.testing.expectEqualStrings("workspace-1", parsed.value.entries[0].workspace_id.?);
    try std.testing.expectEqualStrings("nonce-9", parsed.value.envelope.instance_nonce);
}

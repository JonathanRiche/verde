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

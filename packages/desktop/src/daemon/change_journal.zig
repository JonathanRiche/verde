//! Pure, bounded change journal for the unified `core.changes` cursor.
//!
//! Mirrors the `process_registry.zig` discipline: std-only, injected `now_ms`
//! clock, no sessionizer or protocol imports. The daemon appends
//! identity+revision entries at its existing revision-bump points; clients use
//! a `change_seq` cursor to learn *that* a resource changed and then re-read
//! it — entries never carry payloads, so the journal cannot become a second
//! source of truth.
//!
//! Two data-plane streams are PERMANENT exceptions and never become journal
//! topics (m4m5_decisions Q10): terminal byte cursors and per-turn provider
//! event sequences (`chat.turn.tail` `after_seq`). Both need payloads, strict
//! ordering, and no coalescing at streaming cadence — exactly the properties
//! this journal intentionally lacks. Consequently `chat.turn` entries mark
//! turn lifecycle transitions only (started / status change / durable
//! commit), never streaming deltas.
//!
//! `change_seq` is nonce-scoped like `registry_revision`: it starts at 1 per
//! daemon instance and the caller invokes `reset` on instance start. It is a
//! cursor, not a consistency token; clients never compare it across
//! instances.

const std = @import("std");

/// Real memory bounds for a slow client's worth of pending entries. The count
/// cap bounds the ring for typical short resource ids; the byte cap is the
/// hard guard when ids/workspace ids are long. Overflow evicts the oldest
/// entries and advances `journal_floor_seq`, converting into exactly one
/// client snapshot fallback (never a daemon error state).
pub const CHANGE_JOURNAL_ENTRY_MAX: usize = 4096;
pub const CHANGE_JOURNAL_BYTE_MAX: usize = 1024 * 1024;

/// Closed topic set, frozen by m4m5_decisions Q10. Internal enum with string
/// wire names for forward compatibility; the wire strings are pinned by test.
pub const Topic = enum {
    workspace,
    chat_thread,
    chat_turn,
    chat_completion,
    surface,
    process,
    lease,
    session,
    notification,

    pub fn wireName(self: Topic) []const u8 {
        return switch (self) {
            .workspace => "workspace",
            .chat_thread => "chat.thread",
            .chat_turn => "chat.turn",
            .chat_completion => "chat.completion",
            .surface => "surface",
            .process => "process",
            .lease => "lease",
            .session => "session",
            .notification => "notification",
        };
    }

    pub fn fromWireName(name: []const u8) ?Topic {
        for (std.enums.values(Topic)) |topic| {
            if (std.mem.eql(u8, topic.wireName(), name)) return topic;
        }
        return null;
    }
};

/// Exactly one revision family per entry, made unrepresentable-by-construction
/// at the append boundary: durable changes reference the committing
/// `store_revision`, volatile changes the bumping `registry_revision`.
pub const Revision = union(enum) {
    store: u64,
    registry: u64,
};

pub const RevisionPolicy = enum {
    store_only,
    registry_only,
    either,
};

/// Which revision family a topic may reference. `chat.turn` spans both planes
/// because lifecycle transitions happen registry-side (started / status
/// change) while the durable commit carries the store revision; `workspace`
/// identity likewise lives in both the durable workspaces table and the
/// volatile registry records. All other topics are single-plane and appends
/// with the wrong family are rejected.
pub fn revisionPolicy(topic: Topic) RevisionPolicy {
    return switch (topic) {
        .chat_thread, .chat_completion => .store_only,
        .surface, .process, .lease, .session, .notification => .registry_only,
        .workspace, .chat_turn => .either,
    };
}

/// One journal entry: identity + revision reference only, never a payload.
/// Exactly one of `store_revision`/`registry_revision` is set (enforced by
/// `ChangeJournal.append` taking a `Revision` union).
pub const ChangeEntry = struct {
    change_seq: u64,
    topic: Topic,
    resource_id: []u8,
    workspace_id: ?[]u8 = null,
    store_revision: ?u64 = null,
    registry_revision: ?u64 = null,
    appended_at_ms: i64,

    pub fn deinit(self: *ChangeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_id);
        if (self.workspace_id) |workspace_id| allocator.free(workspace_id);
    }
};

/// Typed answer for "entries after cursor". The caller maps `expired` to the
/// wire-level `revision_expired` + `floor_seq` datum; this module stays free
/// of protocol imports.
pub const EntriesAfterResult = union(enum) {
    ok: Window,
    expired: Expired,

    pub const Window = struct {
        /// Borrowed, seq-ascending; invalidated by the next journal mutation.
        entries: []const ChangeEntry,
        /// Highest seq assigned so far; a client persisting it as its cursor
        /// and seeing no entries later is a valid "nothing changed" heartbeat.
        last_change_seq: u64,
        journal_floor_seq: u64,
    };

    pub const Expired = struct {
        floor_seq: u64,
    };
};

/// Bounded ring of change entries with adjacent-duplicate coalescing.
pub const ChangeJournal = struct {
    entries: std.ArrayList(ChangeEntry) = .empty,
    /// Highest assigned change_seq; 0 means none assigned yet (next is 1).
    last_seq: u64 = 0,
    /// Highest evicted change_seq; a cursor below it has provably missed
    /// entries and must snapshot-fallback.
    journal_floor_seq: u64 = 0,
    byte_count: usize = 0,
    // Caps are fields (defaulted to the real limits) so tests exercise
    // overflow without appending thousands of entries, mirroring the
    // NotificationMailbox cap pattern.
    max_entries: usize = CHANGE_JOURNAL_ENTRY_MAX,
    max_bytes: usize = CHANGE_JOURNAL_BYTE_MAX,

    pub fn deinit(self: *ChangeJournal, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    /// Append one change. Adjacent entries for the same `(topic,
    /// resource_id)` coalesce in place — the surviving entry takes the new
    /// seq (gaps are legal), because a cursor answers "changed since", not
    /// "every intermediate value". Returns the assigned change_seq.
    pub fn append(
        self: *ChangeJournal,
        allocator: std.mem.Allocator,
        topic: Topic,
        resource_id: []const u8,
        workspace_id: ?[]const u8,
        revision: Revision,
        now_ms: i64,
    ) !u64 {
        if (resource_id.len == 0) return error.ResourceIdRequired;
        switch (revisionPolicy(topic)) {
            .store_only => if (revision != .store) return error.RevisionKindMismatch,
            .registry_only => if (revision != .registry) return error.RevisionKindMismatch,
            .either => {},
        }
        if (self.coalescibleLast(topic, resource_id)) {
            return self.coalesceIntoLast(allocator, workspace_id, revision, now_ms);
        }

        const owned_resource_id = try allocator.dupe(u8, resource_id);
        errdefer allocator.free(owned_resource_id);
        const owned_workspace_id: ?[]u8 = if (workspace_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_workspace_id) |value| allocator.free(value);

        const cost = entryByteCost(owned_resource_id.len, optionalLen(owned_workspace_id));
        // A single oversized entry could never fit even in an empty ring;
        // rejecting keeps the byte cap a real invariant instead of advisory.
        if (cost > self.max_bytes) return error.ChangeEntryTooLarge;
        while (self.entries.items.len != 0 and
            (self.entries.items.len >= self.max_entries or self.byte_count + cost > self.max_bytes))
        {
            self.evictOldest(allocator);
        }

        const seq = self.last_seq + 1;
        var entry: ChangeEntry = .{
            .change_seq = seq,
            .topic = topic,
            .resource_id = owned_resource_id,
            .workspace_id = owned_workspace_id,
            .appended_at_ms = now_ms,
        };
        setRevision(&entry, revision);
        try self.entries.append(allocator, entry);
        self.byte_count += cost;
        self.last_seq = seq;
        return seq;
    }

    /// Everything after `after_seq`, or a typed expiry when the cursor lies
    /// below the floor (entries it never saw were evicted).
    pub fn entriesAfter(self: *const ChangeJournal, after_seq: u64) EntriesAfterResult {
        if (after_seq < self.journal_floor_seq) {
            return .{ .expired = .{ .floor_seq = self.journal_floor_seq } };
        }
        var start: usize = self.entries.items.len;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.change_seq > after_seq) {
                start = index;
                break;
            }
        }
        return .{ .ok = .{
            .entries = self.entries.items[start..],
            .last_change_seq = self.last_seq,
            .journal_floor_seq = self.journal_floor_seq,
        } };
    }

    /// Instance-start reset: the caller owns nonce scoping and calls this
    /// whenever `instance_nonce` changes so change_seq restarts at 1.
    pub fn reset(self: *ChangeJournal, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.clearAndFree(allocator);
        self.byte_count = 0;
        self.last_seq = 0;
        self.journal_floor_seq = 0;
    }

    pub fn len(self: *const ChangeJournal) usize {
        return self.entries.items.len;
    }

    fn coalescibleLast(self: *const ChangeJournal, topic: Topic, resource_id: []const u8) bool {
        if (self.entries.items.len == 0) return false;
        const last = self.entries.items[self.entries.items.len - 1];
        return last.topic == topic and std.mem.eql(u8, last.resource_id, resource_id);
    }

    fn coalesceIntoLast(
        self: *ChangeJournal,
        allocator: std.mem.Allocator,
        workspace_id: ?[]const u8,
        revision: Revision,
        now_ms: i64,
    ) !u64 {
        // Dupe the new workspace id before mutating so a failed allocation
        // leaves the journal untouched.
        const new_workspace_id: ?[]u8 = if (workspace_id) |value| try allocator.dupe(u8, value) else null;
        const last = &self.entries.items[self.entries.items.len - 1];
        const old_len = optionalLen(last.workspace_id);
        if (last.workspace_id) |value| allocator.free(value);
        last.workspace_id = new_workspace_id;
        self.byte_count -= old_len;
        self.byte_count += optionalLen(new_workspace_id);
        // The surviving entry references the latest revision only; clients
        // re-read the resource, so replacing (even across families for
        // dual-plane topics) loses nothing.
        setRevision(last, revision);
        const seq = self.last_seq + 1;
        last.change_seq = seq;
        last.appended_at_ms = now_ms;
        self.last_seq = seq;
        // A longer workspace id can push the ring over the byte cap; evict
        // older entries (never the one just coalesced) to restore it.
        while (self.byte_count > self.max_bytes and self.entries.items.len > 1) {
            self.evictOldest(allocator);
        }
        return seq;
    }

    fn evictOldest(self: *ChangeJournal, allocator: std.mem.Allocator) void {
        var removed = self.entries.orderedRemove(0);
        // Entries are seq-ascending, so the removed seq is the new floor.
        if (removed.change_seq > self.journal_floor_seq) self.journal_floor_seq = removed.change_seq;
        self.byte_count -= entryByteCost(removed.resource_id.len, optionalLen(removed.workspace_id));
        removed.deinit(allocator);
    }
};

fn setRevision(entry: *ChangeEntry, revision: Revision) void {
    switch (revision) {
        .store => |value| {
            entry.store_revision = value;
            entry.registry_revision = null;
        },
        .registry => |value| {
            entry.registry_revision = value;
            entry.store_revision = null;
        },
    }
}

// The per-entry struct size is part of the cost so the byte cap bounds real
// daemon memory, not just string bytes.
fn entryByteCost(resource_id_len: usize, workspace_id_len: usize) usize {
    return @sizeOf(ChangeEntry) + resource_id_len + workspace_id_len;
}

fn optionalLen(value: ?[]u8) usize {
    return if (value) |slice| slice.len else 0;
}

test "topic set and wire names are frozen" {
    // Q10 freeze: any change to this list is a design decision, not a patch.
    const expected = [_]struct { topic: Topic, wire: []const u8 }{
        .{ .topic = .workspace, .wire = "workspace" },
        .{ .topic = .chat_thread, .wire = "chat.thread" },
        .{ .topic = .chat_turn, .wire = "chat.turn" },
        .{ .topic = .chat_completion, .wire = "chat.completion" },
        .{ .topic = .surface, .wire = "surface" },
        .{ .topic = .process, .wire = "process" },
        .{ .topic = .lease, .wire = "lease" },
        .{ .topic = .session, .wire = "session" },
        .{ .topic = .notification, .wire = "notification" },
    };
    try std.testing.expectEqual(expected.len, std.enums.values(Topic).len);
    for (expected, std.enums.values(Topic)) |pin, topic| {
        try std.testing.expectEqual(pin.topic, topic);
        try std.testing.expectEqualStrings(pin.wire, topic.wireName());
        try std.testing.expectEqual(topic, Topic.fromWireName(pin.wire).?);
    }
    try std.testing.expectEqual(@as(?Topic, null), Topic.fromWireName("chat.turn.tail"));
    try std.testing.expectEqual(@as(usize, 4096), CHANGE_JOURNAL_ENTRY_MAX);
    try std.testing.expect(CHANGE_JOURNAL_BYTE_MAX > 0);
}

test "change_seq starts at 1 and is monotonic" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{};
    defer journal.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), try journal.append(allocator, .process, "p1", "ws", .{ .registry = 7 }, 100));
    try std.testing.expectEqual(@as(u64, 2), try journal.append(allocator, .lease, "l1", "ws", .{ .registry = 8 }, 101));
    try std.testing.expectEqual(@as(u64, 3), try journal.append(allocator, .chat_thread, "t1", "ws", .{ .store = 4 }, 102));
    try std.testing.expectEqual(@as(u64, 3), journal.last_seq);
    try std.testing.expectEqual(@as(usize, 3), journal.len());
    try std.testing.expectEqual(@as(i64, 102), journal.entries.items[2].appended_at_ms);
}

test "exactly one revision field is set and topic families are enforced" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{};
    defer journal.deinit(allocator);

    // Wrong family is rejected for single-plane topics.
    try std.testing.expectError(error.RevisionKindMismatch, journal.append(allocator, .lease, "l1", null, .{ .store = 1 }, 0));
    try std.testing.expectError(error.RevisionKindMismatch, journal.append(allocator, .chat_thread, "t1", null, .{ .registry = 1 }, 0));
    try std.testing.expectError(error.ResourceIdRequired, journal.append(allocator, .process, "", null, .{ .registry = 1 }, 0));
    try std.testing.expectEqual(@as(usize, 0), journal.len());

    // Dual-plane topics accept either family; every entry carries exactly one.
    _ = try journal.append(allocator, .chat_turn, "turn1", "ws", .{ .registry = 5 }, 0);
    _ = try journal.append(allocator, .workspace, "ws", null, .{ .store = 9 }, 0);
    _ = try journal.append(allocator, .chat_completion, "turn1", "ws", .{ .store = 10 }, 0);
    for (journal.entries.items) |entry| {
        const store_set = entry.store_revision != null;
        const registry_set = entry.registry_revision != null;
        try std.testing.expect(store_set != registry_set);
    }
    try std.testing.expectEqual(@as(u64, 5), journal.entries.items[0].registry_revision.?);
    try std.testing.expectEqual(@as(u64, 9), journal.entries.items[1].store_revision.?);
}

test "adjacent same-topic same-resource entries coalesce with a bumped seq" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{};
    defer journal.deinit(allocator);

    _ = try journal.append(allocator, .process, "p1", "ws-a", .{ .registry = 1 }, 10);
    const coalesced_seq = try journal.append(allocator, .process, "p1", "ws-b", .{ .registry = 2 }, 11);
    try std.testing.expectEqual(@as(usize, 1), journal.len());
    try std.testing.expectEqual(@as(u64, 2), coalesced_seq);
    try std.testing.expectEqual(@as(u64, 2), journal.entries.items[0].change_seq);
    try std.testing.expectEqual(@as(u64, 2), journal.entries.items[0].registry_revision.?);
    try std.testing.expectEqualStrings("ws-b", journal.entries.items[0].workspace_id.?);
    try std.testing.expectEqual(@as(i64, 11), journal.entries.items[0].appended_at_ms);

    // Different resource never coalesces; a later same-resource append is no
    // longer adjacent and must produce its own entry (seq gaps stay legal).
    _ = try journal.append(allocator, .process, "p2", "ws-a", .{ .registry = 3 }, 12);
    _ = try journal.append(allocator, .process, "p1", "ws-a", .{ .registry = 4 }, 13);
    try std.testing.expectEqual(@as(usize, 3), journal.len());
    try std.testing.expectEqual(@as(u64, 4), journal.last_seq);

    // Same resource id under a different topic is a different identity.
    _ = try journal.append(allocator, .session, "p1", "ws-a", .{ .registry = 5 }, 14);
    try std.testing.expectEqual(@as(usize, 4), journal.len());
}

test "dual-plane coalescing keeps only the newest revision reference" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{};
    defer journal.deinit(allocator);

    _ = try journal.append(allocator, .chat_turn, "turn1", "ws", .{ .registry = 3 }, 0);
    _ = try journal.append(allocator, .chat_turn, "turn1", "ws", .{ .store = 12 }, 1);
    try std.testing.expectEqual(@as(usize, 1), journal.len());
    try std.testing.expectEqual(@as(u64, 12), journal.entries.items[0].store_revision.?);
    try std.testing.expectEqual(@as(?u64, null), journal.entries.items[0].registry_revision);
}

test "count cap evicts oldest and advances the floor" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{ .max_entries = 2 };
    defer journal.deinit(allocator);

    _ = try journal.append(allocator, .process, "p1", null, .{ .registry = 1 }, 0);
    _ = try journal.append(allocator, .process, "p2", null, .{ .registry = 2 }, 0);
    try std.testing.expectEqual(@as(u64, 0), journal.journal_floor_seq);
    _ = try journal.append(allocator, .process, "p3", null, .{ .registry = 3 }, 0);
    try std.testing.expectEqual(@as(usize, 2), journal.len());
    try std.testing.expectEqual(@as(u64, 1), journal.journal_floor_seq);
    try std.testing.expectEqual(@as(u64, 2), journal.entries.items[0].change_seq);

    // Coalescing must not consume ring capacity or move the floor.
    _ = try journal.append(allocator, .process, "p3", null, .{ .registry = 4 }, 0);
    try std.testing.expectEqual(@as(usize, 2), journal.len());
    try std.testing.expectEqual(@as(u64, 1), journal.journal_floor_seq);
}

test "byte cap accounting evicts by size and frees owned strings exactly once" {
    const allocator = std.testing.allocator;
    const base_cost = entryByteCost(2, 2);
    // Room for exactly two small entries; the third forces a byte eviction.
    var journal: ChangeJournal = .{ .max_bytes = base_cost * 2 };
    defer journal.deinit(allocator);

    _ = try journal.append(allocator, .process, "p1", "w1", .{ .registry = 1 }, 0);
    _ = try journal.append(allocator, .lease, "l1", "w1", .{ .registry = 2 }, 0);
    try std.testing.expectEqual(base_cost * 2, journal.byte_count);
    _ = try journal.append(allocator, .session, "s1", "w1", .{ .registry = 3 }, 0);
    try std.testing.expectEqual(@as(usize, 2), journal.len());
    try std.testing.expectEqual(base_cost * 2, journal.byte_count);
    try std.testing.expectEqual(@as(u64, 1), journal.journal_floor_seq);

    // Coalescing adjusts accounting when the workspace id length changes and
    // evicts older entries if the growth crosses the cap.
    _ = try journal.append(allocator, .session, "s1", "w1-longer", .{ .registry = 4 }, 0);
    try std.testing.expectEqual(@as(usize, 1), journal.len());
    try std.testing.expectEqual(entryByteCost(2, 9), journal.byte_count);
    try std.testing.expectEqual(@as(u64, 2), journal.journal_floor_seq);
    // std.testing.allocator fails the test on any leak or double free of the
    // owned resource/workspace strings across eviction, coalesce, and deinit.
}

test "oversized single entry is rejected without mutating the journal" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{ .max_bytes = 1 };
    defer journal.deinit(allocator);

    try std.testing.expectError(error.ChangeEntryTooLarge, journal.append(allocator, .process, "p1", null, .{ .registry = 1 }, 0));
    try std.testing.expectEqual(@as(usize, 0), journal.len());
    try std.testing.expectEqual(@as(u64, 0), journal.last_seq);
    try std.testing.expectEqual(@as(usize, 0), journal.byte_count);
}

test "entriesAfter returns the suffix, a heartbeat, or a typed expiry" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{ .max_entries = 2 };
    defer journal.deinit(allocator);

    // Empty journal: cursor 0 is valid and simply has nothing yet.
    switch (journal.entriesAfter(0)) {
        .ok => |window| {
            try std.testing.expectEqual(@as(usize, 0), window.entries.len);
            try std.testing.expectEqual(@as(u64, 0), window.last_change_seq);
        },
        .expired => return error.TestUnexpectedResult,
    }

    _ = try journal.append(allocator, .process, "p1", null, .{ .registry = 1 }, 0);
    _ = try journal.append(allocator, .process, "p2", null, .{ .registry = 2 }, 0);
    _ = try journal.append(allocator, .process, "p3", null, .{ .registry = 3 }, 0); // evicts seq 1

    // Cursor below the floor: typed expiry the caller maps to revision_expired.
    switch (journal.entriesAfter(0)) {
        .ok => return error.TestUnexpectedResult,
        .expired => |expired| try std.testing.expectEqual(@as(u64, 1), expired.floor_seq),
    }

    // Cursor exactly at the floor proves nothing was missed.
    switch (journal.entriesAfter(1)) {
        .ok => |window| {
            try std.testing.expectEqual(@as(usize, 2), window.entries.len);
            try std.testing.expectEqual(@as(u64, 2), window.entries[0].change_seq);
            try std.testing.expectEqual(@as(u64, 3), window.last_change_seq);
            try std.testing.expectEqual(@as(u64, 1), window.journal_floor_seq);
        },
        .expired => return error.TestUnexpectedResult,
    }

    // Snapshot fallback then resume: a fresh cursor at last_change_seq is a
    // clean heartbeat and later appends flow from it.
    switch (journal.entriesAfter(3)) {
        .ok => |window| try std.testing.expectEqual(@as(usize, 0), window.entries.len),
        .expired => return error.TestUnexpectedResult,
    }
    _ = try journal.append(allocator, .lease, "l1", null, .{ .registry = 4 }, 0);
    switch (journal.entriesAfter(3)) {
        .ok => |window| {
            try std.testing.expectEqual(@as(usize, 1), window.entries.len);
            try std.testing.expectEqual(@as(u64, 4), window.entries[0].change_seq);
        },
        .expired => return error.TestUnexpectedResult,
    }
}

test "reset restarts the instance-scoped sequence" {
    const allocator = std.testing.allocator;
    var journal: ChangeJournal = .{ .max_entries = 2 };
    defer journal.deinit(allocator);

    _ = try journal.append(allocator, .process, "p1", "ws", .{ .registry = 1 }, 0);
    _ = try journal.append(allocator, .process, "p2", "ws", .{ .registry = 2 }, 0);
    _ = try journal.append(allocator, .process, "p3", "ws", .{ .registry = 3 }, 0);
    try std.testing.expect(journal.journal_floor_seq != 0);

    journal.reset(allocator);
    try std.testing.expectEqual(@as(usize, 0), journal.len());
    try std.testing.expectEqual(@as(u64, 0), journal.last_seq);
    try std.testing.expectEqual(@as(u64, 0), journal.journal_floor_seq);
    try std.testing.expectEqual(@as(usize, 0), journal.byte_count);

    // Fresh instance scope: seq restarts at 1 and cursor 0 is valid again.
    try std.testing.expectEqual(@as(u64, 1), try journal.append(allocator, .process, "p1", "ws", .{ .registry = 1 }, 0));
    switch (journal.entriesAfter(0)) {
        .ok => |window| try std.testing.expectEqual(@as(usize, 1), window.entries.len),
        .expired => return error.TestUnexpectedResult,
    }
}

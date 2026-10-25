//! Back/forward history of visited workspaces and chats, browser style.
//!
//! Locations are identity hashes (project id, chat local id), not indices, so
//! entries survive reordering. Entries that no longer resolve are skipped when
//! stepping rather than eagerly pruned.

const std = @import("std");

const Self = @This();

pub const CAPACITY: usize = 64;

pub const Direction = enum { back, forward };

/// One visited place. `thread` is 0 when the workspace had no chat selected.
pub const Location = struct {
    project: u64,
    thread: u64,

    pub fn eql(a: Location, b: Location) bool {
        return a.project == b.project and a.thread == b.thread;
    }
};

entries: [CAPACITY]Location = undefined,
len: usize = 0,
cursor: usize = 0,

pub fn hashId(id: []const u8) u64 {
    if (id.len == 0) return 0;
    // Reserve 0 for "no chat".
    return std.hash.Wyhash.hash(0x6e61765f68697374, id) | 1;
}

/// Records a visit. A repeat of the current entry is ignored; a new place
/// drops the forward branch, as in a browser.
pub fn record(self: *Self, location: Location) void {
    if (self.len > 0 and self.entries[self.cursor].eql(location)) return;
    if (self.len > 0) self.len = self.cursor + 1;
    if (self.len == CAPACITY) {
        std.mem.copyForwards(Location, self.entries[0 .. CAPACITY - 1], self.entries[1..CAPACITY]);
        self.len -= 1;
    }
    self.entries[self.len] = location;
    self.cursor = self.len;
    self.len += 1;
}

/// Index of the next entry in `direction` from `from`, or null at the end.
pub fn neighbor(self: *const Self, from: usize, direction: Direction) ?usize {
    return switch (direction) {
        .back => if (from == 0 or self.len == 0) null else from - 1,
        .forward => if (from + 1 >= self.len) null else from + 1,
    };
}

pub fn canStep(self: *const Self, direction: Direction) bool {
    return self.neighbor(self.cursor, direction) != null;
}

/// Moves the cursor onto an entry the caller has already restored.
pub fn moveTo(self: *Self, index: usize) void {
    std.debug.assert(index < self.len);
    self.cursor = index;
}

/// Overwrites the current entry with where a restore actually landed, so the
/// next `record` does not treat it as a fresh visit.
pub fn replaceCurrent(self: *Self, location: Location) void {
    if (self.len == 0) {
        self.record(location);
        return;
    }
    self.entries[self.cursor] = location;
}

test "record dedupes and truncates the forward branch" {
    var history: Self = .{};
    const a: Location = .{ .project = 1, .thread = 1 };
    const b: Location = .{ .project = 1, .thread = 2 };
    const c: Location = .{ .project = 2, .thread = 3 };
    history.record(a);
    history.record(a);
    history.record(b);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expect(history.canStep(.back));
    try std.testing.expect(!history.canStep(.forward));

    history.moveTo(history.neighbor(history.cursor, .back).?);
    try std.testing.expect(history.entries[history.cursor].eql(a));
    try std.testing.expect(history.canStep(.forward));

    // Revisiting the current entry keeps the forward branch.
    history.record(a);
    try std.testing.expect(history.canStep(.forward));

    history.record(c);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expect(!history.canStep(.forward));
    try std.testing.expect(history.entries[1].eql(c));
}

test "record drops the oldest entry at capacity" {
    var history: Self = .{};
    for (0..CAPACITY + 3) |index| {
        history.record(.{ .project = 1, .thread = index + 1 });
    }
    try std.testing.expectEqual(CAPACITY, history.len);
    try std.testing.expectEqual(CAPACITY - 1, history.cursor);
    try std.testing.expectEqual(@as(u64, 4), history.entries[0].thread);
    try std.testing.expectEqual(@as(u64, CAPACITY + 3), history.entries[CAPACITY - 1].thread);
}

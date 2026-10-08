//! Bounded cache for parsed diff views (transcript diff cards and the side
//! panel's Changes view), keyed by patch text and context collapse.

const std = @import("std");
const zig_dif = @import("zig_dif");

const MAX_ENTRIES: usize = 32;
const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;
/// Unchanged lines kept around each change before a run collapses into a
/// context-gap row.
pub const DEFAULT_CONTEXT_LINES: usize = 4;

const Entry = struct {
    patch: []u8,
    context_lines: usize,
    stacked_attempted: bool = false,
    stacked: ?zig_dif.PatchView = null,
    split_attempted: bool = false,
    split: ?zig_dif.SideBySidePatchView = null,
    emphasis_attempted: bool = false,
    /// Word-level ranges per stacked line (empty for unchanged lines),
    /// borrowed from `split`.
    emphasis: ?[]const []const zig_dif.view.InlineRange = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.emphasis) |ranges| allocator.free(ranges);
        if (self.stacked) |*view| view.deinit();
        if (self.split) |*view| view.deinit();
        allocator.free(self.patch);
        self.* = undefined;
    }
};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    patch_bytes: usize = 0,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.entries.deinit(allocator);
    }

    pub fn stacked(self: *Cache, allocator: std.mem.Allocator, patch: []const u8) ?*const zig_dif.PatchView {
        return self.stackedWithContext(allocator, patch, DEFAULT_CONTEXT_LINES);
    }

    pub fn split(self: *Cache, allocator: std.mem.Allocator, patch: []const u8) ?*const zig_dif.SideBySidePatchView {
        return self.splitWithContext(allocator, patch, DEFAULT_CONTEXT_LINES);
    }

    pub fn stackedWithContext(self: *Cache, allocator: std.mem.Allocator, patch: []const u8, context_lines: usize) ?*const zig_dif.PatchView {
        const entry = self.entryForPatch(allocator, patch, context_lines) catch return null;
        if (!entry.stacked_attempted) {
            entry.stacked_attempted = true;
            entry.stacked = zig_dif.buildPatchViewWithOptions(allocator, patch, .{ .context_lines = context_lines }) catch return null;
        }
        return if (entry.stacked) |*view| view else null;
    }

    pub fn splitWithContext(self: *Cache, allocator: std.mem.Allocator, patch: []const u8, context_lines: usize) ?*const zig_dif.SideBySidePatchView {
        const entry = self.entryForPatch(allocator, patch, context_lines) catch return null;
        if (!entry.split_attempted) {
            entry.split_attempted = true;
            entry.split = zig_dif.buildSideBySidePatchViewWithOptions(allocator, patch, .{ .context_lines = context_lines }) catch return null;
        }
        return if (entry.split) |*view| view else null;
    }

    /// Word-level change ranges for each line of the stacked view, taken from
    /// the aligned split model (zig_dif pairs deletions with additions only
    /// there). Index matches `stackedWithContext(...).lines`.
    pub fn stackedEmphasis(self: *Cache, allocator: std.mem.Allocator, patch: []const u8, context_lines: usize) ?[]const []const zig_dif.view.InlineRange {
        const stacked_view = self.stackedWithContext(allocator, patch, context_lines) orelse return null;
        const split_view = self.splitWithContext(allocator, patch, context_lines) orelse return null;
        const entry = self.entryForPatch(allocator, patch, context_lines) catch return null;
        if (!entry.emphasis_attempted) {
            entry.emphasis_attempted = true;
            entry.emphasis = mapStackedEmphasis(allocator, stacked_view, split_view) catch null;
        }
        return entry.emphasis;
    }

    fn entryForPatch(self: *Cache, allocator: std.mem.Allocator, patch: []const u8, context_lines: usize) !*Entry {
        for (self.entries.items) |*entry| {
            if (entry.context_lines == context_lines and std.mem.eql(u8, entry.patch, patch)) return entry;
        }

        if (patch.len > MAX_PATCH_BYTES) return error.PatchTooLarge;
        if (self.entries.items.len >= MAX_ENTRIES or self.patch_bytes + patch.len > MAX_PATCH_BYTES) {
            self.clear(allocator);
        }

        const owned_patch = try allocator.dupe(u8, patch);
        errdefer allocator.free(owned_patch);
        try self.entries.append(allocator, .{ .patch = owned_patch, .context_lines = context_lines });
        self.patch_bytes += patch.len;
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn clear(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.clearRetainingCapacity();
        self.patch_bytes = 0;
    }
};

/// Both views list a file's deletions (left cells) and additions (right
/// cells) in patch order, so the n-th stacked deletion is the n-th left
/// deletion cell, and likewise for additions.
fn mapStackedEmphasis(
    allocator: std.mem.Allocator,
    stacked_view: *const zig_dif.PatchView,
    split_view: *const zig_dif.SideBySidePatchView,
) ![]const []const zig_dif.view.InlineRange {
    const out = try allocator.alloc([]const zig_dif.view.InlineRange, stacked_view.lines.len);
    @memset(out, &.{});
    var row_left: usize = 0;
    var row_right: usize = 0;
    for (stacked_view.lines, out) |line, *ranges| {
        switch (line.kind) {
            .deletion => {
                while (row_left < split_view.rows.len) : (row_left += 1) {
                    const cell = split_view.rows[row_left].left orelse continue;
                    if (cell.kind != .deletion) continue;
                    ranges.* = cell.emphasis_ranges;
                    row_left += 1;
                    break;
                }
            },
            .addition => {
                while (row_right < split_view.rows.len) : (row_right += 1) {
                    const cell = split_view.rows[row_right].right orelse continue;
                    if (cell.kind != .addition) continue;
                    ranges.* = cell.emphasis_ranges;
                    row_right += 1;
                    break;
                }
            },
            else => {},
        }
    }
    return out;
}

test "stacked emphasis follows the split pairing" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    const patch =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-const value = 1;
        \\+const value = 2;
    ;
    const view = cache.stackedWithContext(allocator, patch, 3) orelse return error.TestExpectedEqual;
    const emphasis = cache.stackedEmphasis(allocator, patch, 3) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(view.lines.len, emphasis.len);
    var changed: usize = 0;
    for (view.lines, emphasis) |line, ranges| {
        if (line.kind == .context) try std.testing.expectEqual(@as(usize, 0), ranges.len);
        if (line.kind == .addition or line.kind == .deletion) {
            try std.testing.expect(ranges.len > 0);
            changed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), changed);
    // A different collapse is its own entry.
    _ = cache.stackedWithContext(allocator, patch, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
}

test "diff view cache reuses parsed layouts for the same patch" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    const patch =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-const before = 1;
        \\+const after = 2;
    ;

    const first_stacked = cache.stacked(allocator, patch) orelse return error.TestExpectedEqual;
    const second_stacked = cache.stacked(allocator, patch) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(first_stacked, second_stacked);

    const first_split = cache.split(allocator, patch) orelse return error.TestExpectedEqual;
    const second_split = cache.split(allocator, patch) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(first_split, second_split);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
}

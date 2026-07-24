//! Bounded cache for parsed transcript diff views.

const std = @import("std");
const zig_dif = @import("zig_dif");

const MAX_ENTRIES: usize = 32;
const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;

const Entry = struct {
    patch: []u8,
    stacked_attempted: bool = false,
    stacked: ?zig_dif.PatchView = null,
    split_attempted: bool = false,
    split: ?zig_dif.SideBySidePatchView = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
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
        const entry = self.entryForPatch(allocator, patch) catch return null;
        if (!entry.stacked_attempted) {
            entry.stacked_attempted = true;
            entry.stacked = zig_dif.buildPatchViewWithOptions(allocator, patch, .{ .context_lines = 4 }) catch return null;
        }
        return if (entry.stacked) |*view| view else null;
    }

    pub fn split(self: *Cache, allocator: std.mem.Allocator, patch: []const u8) ?*const zig_dif.SideBySidePatchView {
        const entry = self.entryForPatch(allocator, patch) catch return null;
        if (!entry.split_attempted) {
            entry.split_attempted = true;
            entry.split = zig_dif.buildSideBySidePatchViewWithOptions(allocator, patch, .{ .context_lines = 4 }) catch return null;
        }
        return if (entry.split) |*view| view else null;
    }

    fn entryForPatch(self: *Cache, allocator: std.mem.Allocator, patch: []const u8) !*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.patch, patch)) return entry;
        }

        if (patch.len > MAX_PATCH_BYTES) return error.PatchTooLarge;
        if (self.entries.items.len >= MAX_ENTRIES or self.patch_bytes + patch.len > MAX_PATCH_BYTES) {
            self.clear(allocator);
        }

        const owned_patch = try allocator.dupe(u8, patch);
        errdefer allocator.free(owned_patch);
        try self.entries.append(allocator, .{ .patch = owned_patch });
        self.patch_bytes += patch.len;
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn clear(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.clearRetainingCapacity();
        self.patch_bytes = 0;
    }
};

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

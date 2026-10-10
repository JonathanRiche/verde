//! Shelf packer for glyph atlases. Pure CPU logic (no Vulkan) so it is unit-tested directly.
//!
//! Shelves are horizontal strips whose heights are rounded up to a small bucket so glyphs of
//! similar size share strips. The atlas grows by doubling (both axes; existing shelves simply
//! become wider), and when it cannot grow any more the least recently used shelf that was not
//! touched in the current frame is evicted wholesale.

const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const Shelf = struct {
    y: u32,
    height: u32,
    /// Next free x.
    cursor: u32 = 0,
    /// Frame generation that last placed or used a glyph in this shelf.
    last_used: u64 = 0,
    /// Glyphs currently allocated in this shelf (so eviction knows whether it is worth it).
    live: u32 = 0,
};

pub const Packer = struct {
    size: u32,
    max_size: u32,
    /// Gap between glyphs so bilinear sampling (if ever enabled) never bleeds.
    padding: u32 = 1,
    shelves: std.ArrayList(Shelf) = .empty,
    /// Bottom of the last shelf.
    used_height: u32 = 0,
    used_area: u64 = 0,

    pub fn init(size: u32, max_size: u32) Packer {
        return .{ .size = size, .max_size = @max(size, max_size) };
    }

    pub fn deinit(self: *Packer, gpa: std.mem.Allocator) void {
        self.shelves.deinit(gpa);
    }

    pub fn reset(self: *Packer) void {
        self.shelves.clearRetainingCapacity();
        self.used_height = 0;
        self.used_area = 0;
    }

    fn bucket(h: u32) u32 {
        // 4 px buckets up to 32 px, 8 px above: small waste, few shelves.
        return if (h <= 32) std.mem.alignForward(u32, h, 4) else std.mem.alignForward(u32, h, 8);
    }

    pub const Alloc = struct {
        rect: Rect,
        shelf: u16,
    };

    /// Tries to place a `w`×`h` rect without growing. Returns null when full.
    pub fn alloc(self: *Packer, gpa: std.mem.Allocator, w: u32, h: u32, frame: u64) !?Alloc {
        const pw = w + self.padding;
        const ph = bucket(h + self.padding);
        if (pw > self.size or ph > self.size) return null;

        // Best fit: the shortest shelf that is tall enough (and not wastefully tall).
        var best: ?usize = null;
        for (self.shelves.items, 0..) |shelf, i| {
            if (shelf.height < ph or shelf.height > ph + ph / 2 + 4) continue;
            if (shelf.cursor + pw > self.size) continue;
            if (best == null or shelf.height < self.shelves.items[best.?].height) best = i;
        }
        if (best == null and self.used_height + ph <= self.size) {
            try self.shelves.append(gpa, .{ .y = self.used_height, .height = ph });
            self.used_height += ph;
            best = self.shelves.items.len - 1;
        }
        const index = best orelse return null;
        const shelf = &self.shelves.items[index];
        const rect: Rect = .{ .x = @intCast(shelf.cursor), .y = @intCast(shelf.y), .w = @intCast(w), .h = @intCast(h) };
        shelf.cursor += pw;
        shelf.last_used = frame;
        shelf.live += 1;
        self.used_area += @as(u64, pw) * ph;
        return .{ .rect = rect, .shelf = @intCast(index) };
    }

    /// Doubles the atlas if allowed. Existing allocations keep their texel coordinates.
    pub fn grow(self: *Packer) bool {
        if (self.size >= self.max_size) return false;
        self.size = @min(self.size * 2, self.max_size);
        return true;
    }

    /// Picks the least recently used shelf not used in `frame` and empties it. Returns its
    /// index so the caller can drop cache entries pointing into it.
    pub fn evictLru(self: *Packer, frame: u64, min_height: u32) ?u16 {
        const ph = bucket(min_height + self.padding);
        var victim: ?usize = null;
        for (self.shelves.items, 0..) |shelf, i| {
            if (shelf.last_used >= frame) continue;
            if (shelf.height < ph) continue;
            if (victim == null or shelf.last_used < self.shelves.items[victim.?].last_used) victim = i;
        }
        const index = victim orelse return null;
        const shelf = &self.shelves.items[index];
        self.used_area -|= @as(u64, shelf.cursor) * shelf.height;
        shelf.cursor = 0;
        shelf.live = 0;
        return @intCast(index);
    }

    pub fn touch(self: *Packer, shelf: u16, frame: u64) void {
        self.shelves.items[shelf].last_used = frame;
    }

    /// Fraction of the atlas area covered by allocations (incl. padding), 0..1.
    pub fn usage(self: *const Packer) f32 {
        const total: f64 = @floatFromInt(@as(u64, self.size) * self.size);
        return @floatCast(@as(f64, @floatFromInt(self.used_area)) / total);
    }
};

test "packer places glyphs on shared shelves" {
    const gpa = std.testing.allocator;
    var p = Packer.init(64, 64);
    defer p.deinit(gpa);
    const a = (try p.alloc(gpa, 10, 12, 1)).?;
    const b = (try p.alloc(gpa, 10, 11, 1)).?;
    try std.testing.expectEqual(a.shelf, b.shelf);
    try std.testing.expectEqual(@as(u16, 11), b.rect.x);
    const c = (try p.alloc(gpa, 10, 30, 1)).?;
    try std.testing.expect(c.shelf != a.shelf);
}

test "packer grows then evicts least recently used shelf" {
    const gpa = std.testing.allocator;
    var p = Packer.init(32, 64);
    defer p.deinit(gpa);
    var n: usize = 0;
    while (try p.alloc(gpa, 15, 15, 1)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(p.grow());
    try std.testing.expect(!p.grow());
    // Tall glyphs in frame 2 open new shelves; the 16 px shelves stay at frame 1.
    while (try p.alloc(gpa, 15, 28, 2)) |_| {}
    const victim = p.evictLru(3, 15).?;
    try std.testing.expectEqual(@as(u64, 1), p.shelves.items[victim].last_used);
    try std.testing.expectEqual(@as(u32, 0), p.shelves.items[victim].cursor);
    try std.testing.expect((try p.alloc(gpa, 15, 15, 3)) != null);
    // Shelves used this frame are never evicted.
    for (p.shelves.items) |*s| s.last_used = 3;
    try std.testing.expect(p.evictLru(3, 15) == null);
}

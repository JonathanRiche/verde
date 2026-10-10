//! Frame-to-frame damage tracking on a tile grid.
//!
//! Every command contributes `(bbox, hash)`. Each tile accumulates an *ordered* hash of the
//! commands touching it, so reordering (z-order), moving, recolouring, adding or removing a
//! command changes exactly the tiles it covered before or covers now. Changed tiles are kept
//! per frame in a short history so a target whose buffer age is known can repaint just the
//! union of what changed since it was last drawn.

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const history_len = 4;
pub const max_rects = 8;

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    tile: u32 = 32,
    width: u32 = 0,
    height: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    current: []u64 = &.{},
    previous: []u64 = &.{},
    has_previous: bool = false,
    /// history[0] = tiles changed by the latest `finish`, history[1] the frame before, ...
    history: [history_len][]u64 = @splat(&.{}),
    history_count: u32 = 0,
    /// Scratch for `damageFor`.
    merged: []u64 = &.{},
    rects: std.ArrayList(Rect) = .empty,
    run_starts: std.ArrayList(Rect) = .empty,

    pub fn init(gpa: std.mem.Allocator) Tracker {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tracker) void {
        self.freeGrid();
        self.rects.deinit(self.gpa);
        self.run_starts.deinit(self.gpa);
    }

    fn freeGrid(self: *Tracker) void {
        self.gpa.free(self.current);
        self.gpa.free(self.previous);
        for (&self.history) |h| self.gpa.free(h);
        self.gpa.free(self.merged);
        self.current = &.{};
        self.previous = &.{};
        self.history = @splat(&.{});
        self.merged = &.{};
    }

    fn wordCount(self: *const Tracker) usize {
        return (@as(usize, self.cols) * self.rows + 63) / 64;
    }

    /// Starts a frame. A size change invalidates the history (full damage).
    pub fn begin(self: *Tracker, width: u32, height: u32, seed: u64) !void {
        if (width != self.width or height != self.height or self.current.len == 0) {
            self.freeGrid();
            self.width = width;
            self.height = height;
            self.tile = if (@as(u64, width) * height > 2560 * 1600) 64 else 32;
            self.cols = @max((width + self.tile - 1) / self.tile, 1);
            self.rows = @max((height + self.tile - 1) / self.tile, 1);
            const n = @as(usize, self.cols) * self.rows;
            self.current = try self.gpa.alloc(u64, n);
            self.previous = try self.gpa.alloc(u64, n);
            const words = self.wordCount();
            for (&self.history) |*h| {
                h.* = try self.gpa.alloc(u64, words);
                @memset(h.*, 0);
            }
            self.merged = try self.gpa.alloc(u64, words);
            self.has_previous = false;
            self.history_count = 0;
        }
        @memset(self.current, seed);
    }

    inline fn mix(h: u64, v: u64) u64 {
        return std.math.rotl(u64, (h ^ v) *% 0x9e3779b97f4a7c15, 29);
    }

    /// Adds one command's device-pixel bounds (x0, y0, x1, y1; exclusive max).
    pub fn add(self: *Tracker, x0: f32, y0: f32, x1: f32, y1: f32, hash: u64) void {
        if (!(x1 > x0 and y1 > y0)) return;
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        const cx0 = std.math.clamp(@floor(x0), 0, fw);
        const cy0 = std.math.clamp(@floor(y0), 0, fh);
        const cx1 = std.math.clamp(@ceil(x1), 0, fw);
        const cy1 = std.math.clamp(@ceil(y1), 0, fh);
        if (cx1 <= cx0 or cy1 <= cy0) return;
        const t: u32 = self.tile;
        const tx0 = @as(u32, @intFromFloat(cx0)) / t;
        const ty0 = @as(u32, @intFromFloat(cy0)) / t;
        const tx1 = (@as(u32, @intFromFloat(cx1)) - 1) / t;
        const ty1 = (@as(u32, @intFromFloat(cy1)) - 1) / t;
        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            const row = self.current[ty * self.cols ..][0..self.cols];
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) row[tx] = mix(row[tx], hash);
        }
    }

    /// Ends a frame: records which tiles changed. Returns the number of changed tiles
    /// (all tiles when there is no previous frame).
    pub fn finish(self: *Tracker) usize {
        // Rotate history; reuse the oldest bitset for this frame.
        const oldest = self.history[history_len - 1];
        var i: usize = history_len - 1;
        while (i > 0) : (i -= 1) self.history[i] = self.history[i - 1];
        self.history[0] = oldest;
        const bits = self.history[0];
        @memset(bits, 0);
        var changed: usize = 0;
        for (self.current, 0..) |h, t| {
            if (!self.has_previous or h != self.previous[t]) {
                bits[t / 64] |= @as(u64, 1) << @intCast(t % 64);
                changed += 1;
            }
        }
        std.mem.swap([]u64, &self.current, &self.previous);
        self.has_previous = true;
        self.history_count = @min(self.history_count + 1, history_len);
        return changed;
    }

    /// Damage rects (device px) a buffer of `age` needs repainted: age 1 = it holds the
    /// previous frame. Returns null for "repaint everything" (age unknown or too old).
    pub fn damageFor(self: *Tracker, age: u32) !?[]const Rect {
        if (age == 0 or age > self.history_count) return null;
        @memset(self.merged, 0);
        for (self.history[0..age]) |h| {
            for (self.merged, h) |*m, v| m.* |= v;
        }
        return try self.rectsFromBits(self.merged);
    }

    fn rectsFromBits(self: *Tracker, bits: []const u64) !?[]const Rect {
        self.rects.clearRetainingCapacity();
        // Row runs, merged vertically with the run directly above when the span is identical.
        self.run_starts.clearRetainingCapacity(); // open rects from the previous row
        const t: i32 = @intCast(self.tile);
        var ty: u32 = 0;
        var all: usize = 0;
        while (ty < self.rows) : (ty += 1) {
            var tx: u32 = 0;
            const prev_open = self.run_starts.items.len;
            while (tx < self.cols) {
                const idx = ty * self.cols + tx;
                if (bits[idx / 64] >> @intCast(idx % 64) & 1 == 0) {
                    tx += 1;
                    continue;
                }
                const start = tx;
                while (tx < self.cols) : (tx += 1) {
                    const j = ty * self.cols + tx;
                    if (bits[j / 64] >> @intCast(j % 64) & 1 == 0) break;
                }
                all += tx - start;
                const run: Rect = .{ .x = @as(i32, @intCast(start)) * t, .y = @as(i32, @intCast(ty)) * t, .w = @as(i32, @intCast(tx - start)) * t, .h = t };
                // Extend an open rect from the previous row with the same span.
                var extended = false;
                for (self.run_starts.items[0..prev_open]) |*open| {
                    if (open.x == run.x and open.w == run.w and open.y + open.h == run.y) {
                        open.h += t;
                        extended = true;
                        break;
                    }
                }
                if (!extended) try self.run_starts.append(self.gpa, run);
            }
            // Close rects that did not continue into this row.
            var k: usize = 0;
            while (k < self.run_starts.items.len) {
                const r = self.run_starts.items[k];
                if (r.y + r.h <= @as(i32, @intCast(ty)) * t) {
                    try self.rects.append(self.gpa, r);
                    _ = self.run_starts.swapRemove(k);
                } else k += 1;
            }
        }
        try self.rects.appendSlice(self.gpa, self.run_starts.items);
        if (all == @as(usize, self.cols) * self.rows) return null;
        // Clamp to the surface and collapse when fragmented.
        const fw: i32 = @intCast(self.width);
        const fh: i32 = @intCast(self.height);
        for (self.rects.items) |*r| {
            r.w = @min(r.x + r.w, fw) - r.x;
            r.h = @min(r.y + r.h, fh) - r.y;
        }
        if (self.rects.items.len > max_rects) {
            var b = self.rects.items[0];
            for (self.rects.items[1..]) |r| b = unionRect(b, r);
            self.rects.clearRetainingCapacity();
            try self.rects.append(self.gpa, b);
        }
        return self.rects.items;
    }
};

pub fn unionRect(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "damage tracks moved commands and buffer age" {
    const gpa = std.testing.allocator;
    var t = Tracker.init(gpa);
    defer t.deinit();

    try t.begin(256, 128, 1);
    t.add(0, 0, 256, 128, 0xbac);
    t.add(10, 10, 20, 20, 0x1);
    try std.testing.expectEqual(@as(usize, 8 * 4), t.finish());
    try std.testing.expect((try t.damageFor(1)) == null); // first frame: everything

    // Same frame again: nothing changes.
    try t.begin(256, 128, 1);
    t.add(0, 0, 256, 128, 0xbac);
    t.add(10, 10, 20, 20, 0x1);
    try std.testing.expectEqual(@as(usize, 0), t.finish());
    try std.testing.expectEqual(@as(usize, 0), (try t.damageFor(1)).?.len);

    // Move the small command into tile (3, 2).
    try t.begin(256, 128, 1);
    t.add(0, 0, 256, 128, 0xbac);
    t.add(100, 70, 110, 80, 0x1);
    try std.testing.expectEqual(@as(usize, 2), t.finish());
    const rects = (try t.damageFor(1)).?;
    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 32, .h = 32 }, rects[0]);
    try std.testing.expectEqual(Rect{ .x = 96, .y = 64, .w = 32, .h = 32 }, rects[1]);
    // Age 2 includes the (empty) previous frame; age 3 includes the first full frame.
    try std.testing.expectEqual(@as(usize, 2), (try t.damageFor(2)).?.len);
    try std.testing.expect((try t.damageFor(3)) == null);
    try std.testing.expect((try t.damageFor(0)) == null);

    // Resize: full damage.
    try t.begin(300, 128, 1);
    _ = t.finish();
    try std.testing.expect((try t.damageFor(1)) == null);
}

test "damage merges vertical runs" {
    const gpa = std.testing.allocator;
    var t = Tracker.init(gpa);
    defer t.deinit();
    try t.begin(256, 256, 7);
    _ = t.finish();
    try t.begin(256, 256, 7);
    t.add(40, 40, 90, 150, 0x55); // tiles x 1..2, y 1..4
    _ = t.finish();
    const rects = (try t.damageFor(1)).?;
    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(Rect{ .x = 32, .y = 32, .w = 64, .h = 128 }, rects[0]);
}

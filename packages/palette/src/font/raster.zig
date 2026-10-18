//! Anti-aliased glyph rasterizer: exact signed-area coverage accumulation (font-rs / stb_truetype
//! v2 style). Curves are flattened to lines with a tolerance in *pixel* space (so the segment
//! count adapts to the rendered size); each line deposits signed area/coverage deltas into an
//! f32 accumulation buffer; a per-row prefix sum (vectorized) yields coverage. Winding: the
//! accumulated signed coverage is clamped as min(1, |sum|), i.e. non-zero fill for the usual
//! non-self-overlapping font contours (overlapping same-direction contours saturate correctly).
//!
//! Coordinates: input path is in font units, y up. Output bitmap is y down with `left`/`top`
//! following FreeType's bitmap_left/bitmap_top convention (see api.Bitmap).

const std = @import("std");
const api = @import("api.zig");

pub const Line = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// Max allowed distance (px) between a curve and its flattened polyline.
pub const flatten_tolerance: f32 = 0.08;
/// Hard cap on glyph bitmap dimension; protects against absurd sizes / malformed outlines.
pub const max_dim: u32 = 2048;

/// Path sink that transforms font units -> pixels and flattens curves into `lines`.
pub const Flattener = struct {
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
    min_x: f32 = std.math.floatMax(f32),
    min_y: f32 = std.math.floatMax(f32),
    max_x: f32 = -std.math.floatMax(f32),
    max_y: f32 = -std.math.floatMax(f32),
    start_x: f32 = 0,
    start_y: f32 = 0,
    cur_x: f32 = 0,
    cur_y: f32 = 0,
    failed: bool = false,

    inline fn tx(self: *const Flattener, x: f32) f32 {
        return x * self.scale_x + self.shift_x;
    }
    inline fn ty(self: *const Flattener, y: f32) f32 {
        return -y * self.scale_y + self.shift_y;
    }

    inline fn extend(self: *Flattener, x: f32, y: f32) void {
        self.min_x = @min(self.min_x, x);
        self.max_x = @max(self.max_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_y = @max(self.max_y, y);
    }

    inline fn emit(self: *Flattener, x: f32, y: f32) void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) {
            self.failed = true;
            return;
        }
        if (y != self.cur_y) {
            self.lines.append(self.gpa, .{ .x0 = self.cur_x, .y0 = self.cur_y, .x1 = x, .y1 = y }) catch {
                self.failed = true;
            };
        }
        self.extend(x, y);
        self.cur_x = x;
        self.cur_y = y;
    }

    pub fn moveTo(self: *Flattener, x: f32, y: f32) void {
        self.cur_x = self.tx(x);
        self.cur_y = self.ty(y);
        self.start_x = self.cur_x;
        self.start_y = self.cur_y;
        self.extend(self.cur_x, self.cur_y);
    }

    pub fn lineTo(self: *Flattener, x: f32, y: f32) void {
        self.emit(self.tx(x), self.ty(y));
    }

    pub fn quadTo(self: *Flattener, cx: f32, cy: f32, x: f32, y: f32) void {
        const x0 = self.cur_x;
        const y0 = self.cur_y;
        const x1 = self.tx(cx);
        const y1 = self.ty(cy);
        const x2 = self.tx(x);
        const y2 = self.ty(y);
        // Max deviation of uniform subdivision into n segments is |p0 - 2p1 + p2| / (4 n^2).
        const ddx = x0 - 2 * x1 + x2;
        const ddy = y0 - 2 * y1 + y2;
        const dd = @sqrt(ddx * ddx + ddy * ddy);
        const n_f = @ceil(@sqrt(dd / (4 * flatten_tolerance)));
        const n: u32 = if (n_f >= 1 and n_f < 64) @intFromFloat(n_f) else if (n_f >= 64) 64 else 1;
        if (n == 1) return self.emit(x2, y2);
        const dt = 1.0 / @as(f32, @floatFromInt(n));
        var t: f32 = dt;
        var i: u32 = 1;
        while (i < n) : (i += 1) {
            const mt = 1 - t;
            const a = mt * mt;
            const b = 2 * mt * t;
            const c = t * t;
            self.emit(a * x0 + b * x1 + c * x2, a * y0 + b * y1 + c * y2);
            t += dt;
        }
        self.emit(x2, y2);
    }

    pub fn cubicTo(self: *Flattener, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        const x0 = self.cur_x;
        const y0 = self.cur_y;
        const x1 = self.tx(c1x);
        const y1 = self.ty(c1y);
        const x2 = self.tx(c2x);
        const y2 = self.ty(c2y);
        const x3 = self.tx(x);
        const y3 = self.ty(y);
        // Error bound for uniform subdivision: 3/4 * max(|p0-2p1+p2|, |p1-2p2+p3|) / n^2.
        const ax = x0 - 2 * x1 + x2;
        const ay = y0 - 2 * y1 + y2;
        const bx = x1 - 2 * x2 + x3;
        const by = y1 - 2 * y2 + y3;
        const dd = @sqrt(@max(ax * ax + ay * ay, bx * bx + by * by));
        const n_f = @ceil(@sqrt(0.75 * dd / flatten_tolerance));
        const n: u32 = if (n_f >= 1 and n_f < 96) @intFromFloat(n_f) else if (n_f >= 96) 96 else 1;
        if (n == 1) return self.emit(x3, y3);
        const dt = 1.0 / @as(f32, @floatFromInt(n));
        var t: f32 = dt;
        var i: u32 = 1;
        while (i < n) : (i += 1) {
            const mt = 1 - t;
            const a = mt * mt * mt;
            const b = 3 * mt * mt * t;
            const c = 3 * mt * t * t;
            const d = t * t * t;
            self.emit(a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3);
            t += dt;
        }
        self.emit(x3, y3);
    }

    pub fn close(self: *Flattener) void {
        if (self.cur_x != self.start_x or self.cur_y != self.start_y) self.emit(self.start_x, self.start_y);
    }
};

/// Retained buffers; reuse one per thread to keep rasterization allocation-free in steady state.
pub const Workspace = struct {
    lines: std.ArrayList(Line) = .empty,
    accum: std.ArrayList(f32) = .empty,
    /// Optional coverage remap (gamma/contrast). Identity when null.
    lut: ?*const [256]u8 = null,

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.lines.deinit(gpa);
        self.accum.deinit(gpa);
    }

    pub fn memoryUsed(self: *const Workspace) usize {
        return self.lines.capacity * @sizeOf(Line) + self.accum.capacity * @sizeOf(f32);
    }

    /// Starts a new glyph: returns a sink scaled by `scale` (px per font unit) with a horizontal
    /// shift of `shift_x` px (sub-pixel positioning).
    pub fn begin(self: *Workspace, gpa: std.mem.Allocator, scale: f32, shift_x: f32) Flattener {
        self.lines.clearRetainingCapacity();
        return .{ .gpa = gpa, .lines = &self.lines, .scale_x = scale, .scale_y = scale, .shift_x = shift_x, .shift_y = 0 };
    }

    /// Rasterizes the collected lines; bitmap pixels are allocated from `out`.
    pub fn finish(self: *Workspace, gpa: std.mem.Allocator, fl: *const Flattener, out: std.mem.Allocator) !api.Bitmap {
        if (fl.failed) return error.OutOfMemory;
        if (self.lines.items.len == 0 or !(fl.max_x > fl.min_x) or !(fl.max_y > fl.min_y)) return .{};
        const ox = @floor(fl.min_x);
        const oy = @floor(fl.min_y);
        const wf = @ceil(fl.max_x) - ox;
        const hf = @ceil(fl.max_y) - oy;
        if (!(wf >= 1 and hf >= 1 and wf <= max_dim and hf <= max_dim)) {
            if (wf > max_dim or hf > max_dim) return error.GlyphTooLarge;
            return .{};
        }
        const w: u32 = @intFromFloat(wf);
        const h: u32 = @intFromFloat(hf);
        const stride: usize = @as(usize, w) + 2;
        try self.accum.resize(gpa, stride * h + 1);
        @memset(self.accum.items, 0);
        const acc = self.accum.items;
        for (self.lines.items) |ln| drawLine(acc, stride, w, h, ln.x0 - ox, ln.y0 - oy, ln.x1 - ox, ln.y1 - oy);

        const pixels = try out.alloc(u8, @as(usize, w) * h);
        for (0..h) |row| accumulateRow(acc[row * stride ..][0 .. w + 1], pixels[row * w ..][0..w], self.lut);
        const ix: i32 = @intFromFloat(ox);
        const iy: i32 = @intFromFloat(oy);
        return .{
            .width = w,
            .height = h,
            .left = ix,
            .top = -iy,
            .format = .coverage8,
            .stride = w,
            .pixels = pixels,
        };
    }
};

/// Deposits the signed coverage of one line segment (pixel coords relative to the bitmap) into
/// the accumulation buffer. Port of font-rs `draw_line` with clamping for robustness.
fn drawLine(acc: []f32, stride: usize, w: u32, h: u32, ax: f32, ay: f32, bx: f32, by: f32) void {
    if (ay == by) return;
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    var dir: f32 = 1;
    var x0 = ax;
    var y0 = ay;
    var x1 = bx;
    var y1 = by;
    if (y0 > y1) {
        dir = -1;
        std.mem.swap(f32, &x0, &x1);
        std.mem.swap(f32, &y0, &y1);
    }
    // Clamp to the bitmap (geometry is already inside up to float noise).
    y0 = std.math.clamp(y0, 0, hf);
    y1 = std.math.clamp(y1, 0, hf);
    if (y0 >= y1) return;
    const dxdy = (bx - ax) / (by - ay);
    var x = if (dir > 0) ax + (y0 - ay) * dxdy else bx + (y0 - by) * dxdy;
    const y_start: usize = @intFromFloat(y0);
    const y_end: usize = @min(h, @as(usize, @intFromFloat(@ceil(y1))));
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const row = acc[y * stride ..][0..stride];
        const yf: f32 = @floatFromInt(y);
        const dy = @min(yf + 1, y1) - @max(yf, y0);
        const xnext = x + dxdy * dy;
        const d = dy * dir;
        var xa = std.math.clamp(@min(x, xnext), 0, wf);
        var xb = std.math.clamp(@max(x, xnext), 0, wf);
        if (xb < xa) std.mem.swap(f32, &xa, &xb);
        const xa_floor = @floor(xa);
        const xa_i: usize = @intFromFloat(xa_floor);
        const xb_ceil = @ceil(xb);
        const xb_i: usize = @intFromFloat(xb_ceil);
        if (xb_i <= xa_i + 1) {
            // Segment within one pixel column: split by the mean x.
            const xmf = 0.5 * (xa + xb) - xa_floor;
            row[xa_i] += d - d * xmf;
            row[xa_i + 1] += d * xmf;
        } else {
            const s = 1.0 / (xb - xa);
            const x0f = xa - xa_floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = xb - xb_ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            row[xa_i] += d * a0;
            if (xb_i == xa_i + 2) {
                row[xa_i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                row[xa_i + 1] += d * (a1 - a0);
                var xi = xa_i + 2;
                while (xi < xb_i - 1) : (xi += 1) row[xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(xb_i - xa_i - 3)) * s;
                row[xb_i - 1] += d * (1 - a2 - am);
            }
            row[xb_i] += d * am;
        }
        x = xnext;
    }
}

const V = 8;
const Vf = @Vector(V, f32);

/// Prefix-sums one accumulation row into 8-bit coverage. Vectorized in blocks of 8.
fn accumulateRow(src: []const f32, dst: []u8, lut: ?*const [256]u8) void {
    var carry: f32 = 0;
    var i: usize = 0;
    const n = dst.len;
    while (i + V <= n) : (i += V) {
        var v: Vf = src[i..][0..V].*;
        // Inclusive prefix sum within the vector (log-step shifts).
        v += @shuffle(f32, v, @as(Vf, @splat(0)), [V]i32{ -1, 0, 1, 2, 3, 4, 5, 6 });
        v += @shuffle(f32, v, @as(Vf, @splat(0)), [V]i32{ -1, -1, 0, 1, 2, 3, 4, 5 });
        v += @shuffle(f32, v, @as(Vf, @splat(0)), [V]i32{ -1, -1, -1, -1, 0, 1, 2, 3 });
        v += @as(Vf, @splat(carry));
        carry = v[V - 1];
        const cov = @min(@abs(v), @as(Vf, @splat(1.0))) * @as(Vf, @splat(255.0)) + @as(Vf, @splat(0.5));
        const bytes: @Vector(V, u8) = @intFromFloat(cov);
        dst[i..][0..V].* = bytes;
    }
    while (i < n) : (i += 1) {
        carry += src[i];
        const c = @min(@abs(carry), 1.0) * 255.0 + 0.5;
        dst[i] = @intFromFloat(c);
    }
    if (lut) |table| {
        for (dst) |*p| p.* = table[p.*];
    }
}

/// Builds a coverage remap: `gamma` < 1 darkens/thickens light strokes (FreeType-like "light"
/// look at small sizes), `contrast` > 0 steepens the curve around 50%.
pub fn buildLut(gamma: f32, contrast: f32) [256]u8 {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, i| {
        var v: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        v = std.math.pow(f32, v, gamma);
        if (contrast != 0) {
            const k = 1.0 + contrast;
            v = std.math.clamp((v - 0.5) * k + 0.5, 0, 1);
            if (i == 0) v = 0;
        }
        e.* = @intFromFloat(std.math.clamp(v * 255.0 + 0.5, 0, 255));
    }
    return t;
}

test "square coverage" {
    const gpa = std.testing.allocator;
    var ws: Workspace = .{};
    defer ws.deinit(gpa);
    var fl = ws.begin(gpa, 1.0, 0.25);
    // 4x4 square in font units, y up from 0..4 -> pixels y -4..0, x 0.25..4.25
    fl.moveTo(0, 0);
    fl.lineTo(0, 4);
    fl.lineTo(4, 4);
    fl.lineTo(4, 0);
    fl.close();
    const bm = try ws.finish(gpa, &fl, gpa);
    defer gpa.free(bm.pixels);
    try std.testing.expectEqual(@as(u32, 5), bm.width);
    try std.testing.expectEqual(@as(u32, 4), bm.height);
    try std.testing.expectEqual(@as(i32, 4), bm.top);
    try std.testing.expectEqual(@as(i32, 0), bm.left);
    try std.testing.expectEqualSlices(u8, &.{ 191, 255, 255, 255, 64 }, bm.pixels[0..5]);
}

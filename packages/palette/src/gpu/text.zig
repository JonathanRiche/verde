//! Text for the Vulkan renderer: the `GlyphSource` interface (shaping + rasterization supplied
//! by the font engine), the glyph cache that owns the CPU side of both glyph atlases, and the
//! layout rules that reproduce the old SDL_ttf-based renderer's placement.
//!
//! Layout parity with the old renderer (palette/src/renderer.zig):
//! - font pixel size = command font_size * 0.86 (`GPU_TEXT_FONT_SCALE`)
//! - the text origin snaps to whole pixels (`@round(x)`, `@round(y)`); `y` is the line *top*
//!   and the first baseline is `top + ascent` (SDL_ttf-style ceil'd ascent from the font engine)
//! - lines advance by the font line skip; `\n` always breaks; optional word wrap at rect.w
//! - mono text with glyph_width/line_height uses fixed cells: tab = 4 cells, spaces skipped
//! - `text_runs` draw each run at (run.x - scroll.x, run.y - scroll.y) with their own style
//! - text without a font role uses the old default font (prose_bold; `Layouter.default_role`)
//! Glyph pens snap to `font.api.subpixel_steps` horizontal buckets and whole-pixel baselines.

const std = @import("std");
const draw = @import("../draw.zig");
const api = @import("../font/api.zig");
const atlas = @import("atlas.zig");

pub const Role = api.Role;
pub const GlyphKey = api.GlyphKey;
pub const Bitmap = api.Bitmap;
pub const LineMetrics = api.LineMetrics;
pub const ShapedGlyph = api.ShapedGlyph;

/// GPU_TEXT_FONT_SCALE of the old renderer.
pub const default_text_scale: f32 = 0.86;

/// Shaping + rasterization provider. `font.Collection` satisfies this through `adapt`.
pub const GlyphSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Appends positioned glyphs for `text` (a single line, no '\n') to `out`.
        shape: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, role: Role, size_px: f32, text: []const u8, out: *std.ArrayList(ShapedGlyph)) anyerror!void,
        /// Rasterizes one glyph; pixels come from `scratch`.
        rasterize: *const fn (ptr: *anyopaque, key: GlyphKey, scratch: std.mem.Allocator) anyerror!Bitmap,
        lineMetrics: *const fn (ptr: *anyopaque, role: Role, size_px: f32) LineMetrics,
    };

    pub fn shape(self: GlyphSource, gpa: std.mem.Allocator, role: Role, size_px: f32, text: []const u8, out: *std.ArrayList(ShapedGlyph)) !void {
        return self.vtable.shape(self.ptr, gpa, role, size_px, text, out);
    }
    pub fn rasterize(self: GlyphSource, key: GlyphKey, scratch: std.mem.Allocator) !Bitmap {
        return self.vtable.rasterize(self.ptr, key, scratch);
    }
    pub fn lineMetrics(self: GlyphSource, role: Role, size_px: f32) LineMetrics {
        return self.vtable.lineMetrics(self.ptr, role, size_px);
    }

    /// Wraps any type with `shape(gpa, role, size_px, text, *ArrayList)`, `rasterize(key,
    /// scratch)` and `lineMetrics(role, size_px)` methods — e.g. `*font.Collection`:
    /// `const source = gpu.GlyphSource.adapt(font.Collection, collection);`
    pub fn adapt(comptime T: type, impl: *T) GlyphSource {
        const Gen = struct {
            fn shapeFn(ptr: *anyopaque, gpa: std.mem.Allocator, role: Role, size_px: f32, text: []const u8, out: *std.ArrayList(ShapedGlyph)) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.shape(gpa, role, size_px, text, out);
            }
            fn rasterizeFn(ptr: *anyopaque, key: GlyphKey, scratch: std.mem.Allocator) anyerror!Bitmap {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.rasterize(key, scratch);
            }
            fn lineMetricsFn(ptr: *anyopaque, role: Role, size_px: f32) LineMetrics {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.lineMetrics(role, size_px);
            }
            const vtable: VTable = .{ .shape = shapeFn, .rasterize = rasterizeFn, .lineMetrics = lineMetricsFn };
        };
        return .{ .ptr = impl, .vtable = &Gen.vtable };
    }
};

/// Deterministic fake font for tests and examples: every codepoint is a box glyph whose
/// interior pattern encodes the codepoint, advances are whole pixels, metrics are
/// SDL_ttf-like integers. Codepoints >= U+1F000 rasterize as colour (RGBA) glyphs.
pub const StubGlyphSource = struct {
    pub fn source(self: *StubGlyphSource) GlyphSource {
        return GlyphSource.adapt(StubGlyphSource, self);
    }

    pub fn advanceFor(size_px: f32) f32 {
        return @round(size_px * 0.6);
    }

    pub fn shape(_: *StubGlyphSource, gpa: std.mem.Allocator, role: Role, size_px: f32, text: []const u8, out: *std.ArrayList(ShapedGlyph)) !void {
        const advance = advanceFor(size_px) + if (role == .ui_bold) @as(f32, 1) else 0;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        var offset: u32 = 0;
        while (it.nextCodepointSlice()) |slice| {
            const cp = std.unicode.utf8Decode(slice) catch '?';
            const adv = if (cp == '\t') advance * 4 else advance;
            try out.append(gpa, .{
                .face = @enumFromInt(@as(u16, if (role == .ui_bold) 1 else 0)),
                .glyph = cp,
                .x_advance = adv,
                .cluster = offset,
            });
            offset += @intCast(slice.len);
        }
    }

    pub fn rasterize(_: *StubGlyphSource, key: GlyphKey, scratch: std.mem.Allocator) !Bitmap {
        const cp = key.glyph;
        if (cp == ' ' or cp == '\t' or cp == 0xa0) return .{};
        const size = key.sizePx();
        const w: u32 = @intFromFloat(@max(@round(size * 0.5), 3));
        const h: u32 = @intFromFloat(@max(@round(size * 0.7), 4));
        const color = cp >= 0x1f000;
        const bpp: u32 = if (color) 4 else 1;
        const pixels = try scratch.alloc(u8, w * h * bpp);
        for (0..h) |y| for (0..w) |x| {
            const edge = x == 0 or y == 0 or x == w - 1 or y == h - 1;
            const cell = ((x * 4 / w) + (y * 4 / h) * 4) & 15;
            const bit = (cp >> @intCast(cell)) & 1 == 1;
            const v: u8 = if (edge) 255 else if (bit) 160 else 0;
            const i = (y * w + x) * bpp;
            if (color) {
                // Premultiplied orange.
                pixels[i + 0] = v;
                pixels[i + 1] = v / 2;
                pixels[i + 2] = 0;
                pixels[i + 3] = v;
            } else pixels[i] = v;
        };
        return .{
            .width = w,
            .height = h,
            .left = 1,
            .top = @intCast(h),
            .format = if (color) .rgba8_premul else .coverage8,
            .stride = w * bpp,
            .pixels = pixels,
        };
    }

    pub fn lineMetrics(_: *StubGlyphSource, _: Role, size_px: f32) LineMetrics {
        const ascent = @ceil(size_px * 0.8);
        const height = @ceil(size_px * 1.05);
        const skip = @ceil(size_px * 1.2);
        return .{ .ascent = ascent, .descent = height - ascent, .line_gap = skip - height, .average_advance = advanceFor(size_px) };
    }
};

// ---- Glyph cache --------------------------------------------------------------------------

pub const AtlasKind = enum(u1) { coverage, color };

pub const Entry = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    shelf: u16 = 0,
    kind: AtlasKind = .coverage,

    pub fn isEmpty(self: Entry) bool {
        return self.w == 0 or self.h == 0;
    }
};

pub const Upload = struct {
    kind: AtlasKind,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Byte offset into `GlyphCache.upload_bytes` (tightly packed rows).
    offset: usize,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: GlyphKey) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyContext, a: GlyphKey, b: GlyphKey) bool {
        return a.face == b.face and a.glyph == b.glyph and a.size_26_6 == b.size_26_6 and a.subpixel_x == b.subpixel_x;
    }
};

pub const CacheOptions = struct {
    coverage_initial: u32 = 1024,
    coverage_max: u32 = 4096,
    color_initial: u32 = 256,
    color_max: u32 = 2048,
};

pub const GlyphCache = struct {
    gpa: std.mem.Allocator,
    packers: [2]atlas.Packer,
    map: std.HashMapUnmanaged(GlyphKey, Entry, KeyContext, 80) = .empty,
    uploads: std.ArrayList(Upload) = .empty,
    upload_bytes: std.ArrayList(u8) = .empty,
    scratch: std.heap.ArenaAllocator,
    frame: u64 = 1,
    stats: Stats = .{},

    pub const Stats = struct {
        rasterized: u64 = 0,
        evicted_shelves: u64 = 0,
        dropped: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, options: CacheOptions) GlyphCache {
        return .{
            .gpa = gpa,
            .packers = .{
                .init(options.coverage_initial, options.coverage_max),
                .init(options.color_initial, options.color_max),
            },
            .scratch = .init(gpa),
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        for (&self.packers) |*p| p.deinit(self.gpa);
        self.map.deinit(self.gpa);
        self.uploads.deinit(self.gpa);
        self.upload_bytes.deinit(self.gpa);
        self.scratch.deinit();
    }

    pub fn beginFrame(self: *GlyphCache) void {
        self.frame += 1;
        _ = self.scratch.reset(.retain_capacity);
    }

    /// Called by the renderer once pending uploads were copied to the GPU.
    pub fn clearUploads(self: *GlyphCache) void {
        self.uploads.clearRetainingCapacity();
        self.upload_bytes.clearRetainingCapacity();
    }

    pub fn atlasSize(self: *const GlyphCache, kind: AtlasKind) u32 {
        return self.packers[@intFromEnum(kind)].size;
    }

    pub fn glyphCount(self: *const GlyphCache) usize {
        return self.map.count();
    }

    /// Returns the atlas entry for `key`, rasterizing and packing it on a miss. Null when the
    /// glyph cannot be placed this frame (atlas at max size and full of glyphs used this frame).
    pub fn get(self: *GlyphCache, source: GlyphSource, key: GlyphKey) !?Entry {
        if (self.map.get(key)) |entry| {
            if (!entry.isEmpty()) self.packers[@intFromEnum(entry.kind)].touch(entry.shelf, self.frame);
            return entry;
        }
        const bitmap = try source.rasterize(key, self.scratch.allocator());
        self.stats.rasterized += 1;
        if (bitmap.isEmpty()) {
            try self.map.put(self.gpa, key, .{});
            return .{};
        }
        const kind: AtlasKind = if (bitmap.format == .rgba8_premul) .color else .coverage;
        const packer = &self.packers[@intFromEnum(kind)];
        const placed = (try packer.alloc(self.gpa, bitmap.width, bitmap.height, self.frame)) orelse blk: {
            while (packer.grow()) {
                if (try packer.alloc(self.gpa, bitmap.width, bitmap.height, self.frame)) |a| break :blk a;
            }
            while (packer.evictLru(self.frame, bitmap.height)) |shelf| {
                self.dropShelf(kind, shelf);
                if (try packer.alloc(self.gpa, bitmap.width, bitmap.height, self.frame)) |a| break :blk a;
            }
            self.stats.dropped += 1;
            return null;
        };
        const entry: Entry = .{
            .x = placed.rect.x,
            .y = placed.rect.y,
            .w = placed.rect.w,
            .h = placed.rect.h,
            .left = @intCast(std.math.clamp(bitmap.left, -32768, 32767)),
            .top = @intCast(std.math.clamp(bitmap.top, -32768, 32767)),
            .shelf = placed.shelf,
            .kind = kind,
        };
        // Queue the upload (rows tightly packed).
        const bpp: usize = if (kind == .color) 4 else 1;
        const row_bytes = bitmap.width * bpp;
        // 4-byte aligned offsets: buffer->image copies need texel-size alignment (RGBA = 4).
        const offset = std.mem.alignForward(usize, self.upload_bytes.items.len, 4);
        try self.upload_bytes.ensureUnusedCapacity(self.gpa, offset - self.upload_bytes.items.len + row_bytes * bitmap.height);
        self.upload_bytes.appendNTimesAssumeCapacity(0, offset - self.upload_bytes.items.len);
        for (0..bitmap.height) |y| {
            self.upload_bytes.appendSliceAssumeCapacity(bitmap.pixels[y * bitmap.stride ..][0..row_bytes]);
        }
        try self.uploads.append(self.gpa, .{ .kind = kind, .x = entry.x, .y = entry.y, .w = entry.w, .h = entry.h, .offset = offset });
        try self.map.put(self.gpa, key, entry);
        return entry;
    }

    fn dropShelf(self: *GlyphCache, kind: AtlasKind, shelf: u16) void {
        self.stats.evicted_shelves += 1;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (!e.isEmpty() and e.kind == kind and e.shelf == shelf) {
                self.map.removeByPtr(kv.key_ptr);
                // removeByPtr leaves the iterator valid for open addressing with tombstones.
            }
        }
    }

    /// Atlas usage 0..1 (allocated area / current atlas area).
    pub fn usage(self: *const GlyphCache, kind: AtlasKind) f32 {
        return self.packers[@intFromEnum(kind)].usage();
    }
};

// ---- Layout -------------------------------------------------------------------------------

/// One glyph quad in device pixels; `u`, `v` are atlas texel coordinates.
pub const GlyphQuad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u: f32,
    v: f32,
    kind: AtlasKind,
    color: draw.Color,
    clip: ?draw.Rect,
};

pub const Layouter = struct {
    gpa: std.mem.Allocator,
    source: GlyphSource,
    cache: *GlyphCache,
    scale: f32 = default_text_scale,
    /// Role for commands/runs without `font_role`. The old renderer drew those with its
    /// default font, which Verde sets to the prose-bold face (`RoleFonts.prose_bold`).
    default_role: Role = .prose_bold,
    shaped: std.ArrayList(ShapedGlyph) = .empty,
    pens: std.ArrayList(f32) = .empty,

    pub fn deinit(self: *Layouter) void {
        self.shaped.deinit(self.gpa);
        self.pens.deinit(self.gpa);
    }

    /// Draws a `.text` command; `sink.glyph(GlyphQuad) !void` receives every visible glyph.
    pub fn drawCommand(self: *Layouter, sink: anytype, command: *const draw.Command) !void {
        if (command.text_runs.len > 0) {
            for (command.text_runs) |run| {
                try self.drawNatural(sink, run.text, run.x - command.scroll.x, run.y - command.scroll.y, run.color, run.font_size, run.clip, null, run.font_role orelse self.default_role);
            }
            return;
        }
        if (command.text.len == 0 or command.color.a <= 0) return;
        const x = command.rect.x - command.scroll.x;
        const y = command.rect.y - command.scroll.y;
        const wrap: ?f32 = if (command.wrap) command.rect.w else null;
        if (command.font_role == .mono and command.glyph_width > 0 and command.line_height > 0) {
            return self.drawFixed(sink, command.text, x, y, command.color, command.font_size, command.glyph_width, command.line_height, command.clip, wrap, .mono);
        }
        try self.drawNatural(sink, command.text, x, y, command.color, command.font_size, command.clip, wrap, command.font_role orelse self.default_role);
    }

    pub fn drawNatural(self: *Layouter, sink: anytype, value: []const u8, x: f32, y: f32, color: draw.Color, font_size: f32, clip: ?draw.Rect, wrap_width: ?f32, role: Role) !void {
        if (value.len == 0 or color.a <= 0) return;
        const size_px = font_size * self.scale;
        if (size_px <= 0) return;
        const origin_x = @round(x);
        const top = @round(y);
        const metrics = self.source.lineMetrics(role, size_px);
        const line_skip = @round(metrics.lineHeight());
        var baseline = top + @round(metrics.ascent);
        const pixel_clip = snapClip(clip);

        var paragraphs = std.mem.splitScalar(u8, value, '\n');
        while (paragraphs.next()) |paragraph_raw| {
            const paragraph = std.mem.trimEnd(u8, paragraph_raw, "\r");
            self.shaped.clearRetainingCapacity();
            self.pens.clearRetainingCapacity();
            if (paragraph.len > 0) try self.source.shape(self.gpa, role, size_px, paragraph, &self.shaped);
            const glyphs = self.shaped.items;
            try self.pens.ensureTotalCapacity(self.gpa, glyphs.len + 1);
            var pen: f32 = 0;
            for (glyphs) |g| {
                self.pens.appendAssumeCapacity(pen);
                pen += g.x_advance;
            }
            self.pens.appendAssumeCapacity(pen);
            const pens = self.pens.items;

            var line_start: usize = 0;
            if (wrap_width) |width_raw| if (width_raw > 0) {
                const width = @ceil(width_raw);
                var last_break: ?usize = null;
                var i: usize = 0;
                while (i < glyphs.len) : (i += 1) {
                    if (isSpaceAt(paragraph, glyphs[i].cluster)) {
                        last_break = i + 1;
                        continue;
                    }
                    const right = pens[i] + glyphs[i].x_advance - pens[line_start];
                    if (right > width and i > line_start) {
                        const brk = if (last_break) |b| (if (b > line_start) b else i) else i;
                        try self.emitLine(sink, paragraph, glyphs, pens, line_start, trimSpaces(paragraph, glyphs, line_start, brk), origin_x, baseline, size_px, color, pixel_clip);
                        baseline += line_skip;
                        line_start = brk;
                        last_break = null;
                    }
                }
            };
            try self.emitLine(sink, paragraph, glyphs, pens, line_start, glyphs.len, origin_x, baseline, size_px, color, pixel_clip);
            baseline += line_skip;
        }
    }

    fn emitLine(self: *Layouter, sink: anytype, paragraph: []const u8, glyphs: []const ShapedGlyph, pens: []const f32, start: usize, end: usize, origin_x: f32, baseline: f32, size_px: f32, color: draw.Color, clip: ?draw.Rect) !void {
        _ = paragraph;
        if (start >= end) return;
        const base = pens[start];
        for (glyphs[start..end], pens[start..end]) |g, pen| {
            if (g.glyph == api.invisible_glyph) continue;
            try self.emitGlyph(sink, g.face, g.glyph, size_px, origin_x + (pen - base) + g.x_offset, baseline - g.y_offset, color, clip);
        }
    }

    fn emitGlyph(self: *Layouter, sink: anytype, face: api.FaceId, glyph: api.GlyphId, size_px: f32, pen_x: f32, baseline: f32, color: draw.Color, clip: ?draw.Rect) !void {
        const steps: f32 = @floatFromInt(api.subpixel_steps);
        var ix = @floor(pen_x);
        var bucket = @round((pen_x - ix) * steps);
        if (bucket >= steps) {
            ix += 1;
            bucket = 0;
        }
        const key = GlyphKey.init(face, glyph, size_px, @intFromFloat(bucket));
        const entry = (try self.cache.get(self.source, key)) orelse return;
        if (entry.isEmpty()) return;
        try sink.glyph(.{
            .x = ix + @as(f32, @floatFromInt(entry.left)),
            .y = @round(baseline) - @as(f32, @floatFromInt(entry.top)),
            .w = @floatFromInt(entry.w),
            .h = @floatFromInt(entry.h),
            .u = @floatFromInt(entry.x),
            .v = @floatFromInt(entry.y),
            .kind = entry.kind,
            .color = color,
            .clip = clip,
        });
    }

    pub fn drawFixed(self: *Layouter, sink: anytype, value: []const u8, x: f32, y: f32, color: draw.Color, font_size: f32, glyph_width: f32, line_height: f32, clip: ?draw.Rect, wrap_width: ?f32, role: Role) !void {
        if (value.len == 0 or color.a <= 0) return;
        var cursor_x = x;
        var cursor_y = y;
        const max_x = if (wrap_width) |width| x + @max(width, glyph_width) else std.math.floatMax(f32);
        var index: usize = 0;
        while (index < value.len) {
            const byte = value[index];
            if (byte == '\n') {
                cursor_x = x;
                cursor_y += line_height;
                index += 1;
                continue;
            }
            const len = utf8ByteLen(byte, value.len - index);
            const slice = value[index .. index + len];
            const advance = if (byte == '\t') glyph_width * 4.0 else glyph_width;
            if (wrap_width != null and cursor_x > x and cursor_x + advance > max_x) {
                cursor_x = x;
                cursor_y += line_height;
            }
            if (!isTextSpace(slice)) {
                const glyph = if (std.unicode.utf8ValidateSlice(slice)) slice else "?";
                try self.drawNatural(sink, glyph, cursor_x, cursor_y, color, font_size, clip, null, role);
            }
            cursor_x += advance;
            index += len;
        }
    }

    /// Natural advance width of a single line (no wrapping), in device px.
    pub fn measure(self: *Layouter, value: []const u8, font_size: f32, role: Role) !f32 {
        self.shaped.clearRetainingCapacity();
        try self.source.shape(self.gpa, role, font_size * self.scale, value, &self.shaped);
        var w: f32 = 0;
        for (self.shaped.items) |g| w += g.x_advance;
        return w;
    }
};

/// Old renderer scissor rule for text/image clips: x = floor(x), w = ceil(w).
pub fn snapClip(clip: ?draw.Rect) ?draw.Rect {
    const c = clip orelse return null;
    return .{ .x = @floor(c.x), .y = @floor(c.y), .w = @ceil(c.w), .h = @ceil(c.h) };
}

fn isSpaceAt(text: []const u8, cluster: u32) bool {
    if (cluster >= text.len) return false;
    const b = text[cluster];
    return b == ' ' or b == '\t';
}

fn trimSpaces(text: []const u8, glyphs: []const ShapedGlyph, start: usize, end: usize) usize {
    var e = end;
    while (e > start and isSpaceAt(text, glyphs[e - 1].cluster)) e -= 1;
    return e;
}

fn utf8ByteLen(first: u8, remaining: usize) usize {
    const requested: usize = if ((first & 0x80) == 0)
        1
    else if ((first & 0xe0) == 0xc0)
        2
    else if ((first & 0xf0) == 0xe0)
        3
    else if ((first & 0xf8) == 0xf0)
        4
    else
        1;
    return @min(requested, @max(remaining, 1));
}

fn isTextSpace(value: []const u8) bool {
    if (value.len == 1) return value[0] == ' ' or value[0] == '\t' or value[0] == '\r';
    return std.mem.eql(u8, value, "\xc2\xa0");
}

// ---- Tests --------------------------------------------------------------------------------

const TestSink = struct {
    quads: std.ArrayList(GlyphQuad) = .empty,
    gpa: std.mem.Allocator,
    pub fn glyph(self: *TestSink, q: GlyphQuad) !void {
        try self.quads.append(self.gpa, q);
    }
};

test "natural text: baseline, snapping, newline and wrap" {
    const gpa = std.testing.allocator;
    var stub: StubGlyphSource = .{};
    var cache = GlyphCache.init(gpa, .{ .coverage_initial = 256 });
    defer cache.deinit();
    var lay: Layouter = .{ .gpa = gpa, .source = stub.source(), .cache = &cache, .scale = 1.0 };
    defer lay.deinit();
    var sink: TestSink = .{ .gpa = gpa };
    defer sink.quads.deinit(gpa);

    // size 10: advance 6, ascent 8, line skip 12, glyph 5x7, left 1, top 7.
    try lay.drawNatural(&sink, "ab c\nd", 10.4, 20.6, .{}, 10, null, null, .ui);
    try std.testing.expectEqual(@as(usize, 4), sink.quads.items.len);
    const a = sink.quads.items[0];
    try std.testing.expectEqual(@as(f32, 10 + 1), a.x);
    try std.testing.expectEqual(@as(f32, 21 + 8 - 7), a.y);
    try std.testing.expectEqual(@as(f32, 10 + 6 * 3 + 1), sink.quads.items[2].x); // 'c' after space
    const d = sink.quads.items[3];
    try std.testing.expectEqual(@as(f32, 11), d.x);
    try std.testing.expectEqual(a.y + 12, d.y);

    sink.quads.clearRetainingCapacity();
    // Wrap at 20 px: "aa bb" -> "aa" / "bb".
    try lay.drawNatural(&sink, "aa bb", 0, 0, .{}, 10, null, 20, .ui);
    try std.testing.expectEqual(@as(usize, 4), sink.quads.items.len);
    try std.testing.expectEqual(@as(f32, 1), sink.quads.items[2].x);
    try std.testing.expectEqual(sink.quads.items[0].y + 12, sink.quads.items[2].y);
    // Cache hits do not re-rasterize.
    const before = cache.stats.rasterized;
    try lay.drawNatural(&sink, "ab", 0, 0, .{}, 10, null, null, .ui);
    try std.testing.expectEqual(before, cache.stats.rasterized);
}

test "fixed-cell mono text" {
    const gpa = std.testing.allocator;
    var stub: StubGlyphSource = .{};
    var cache = GlyphCache.init(gpa, .{ .coverage_initial = 256 });
    defer cache.deinit();
    var lay: Layouter = .{ .gpa = gpa, .source = stub.source(), .cache = &cache, .scale = 1.0 };
    defer lay.deinit();
    var sink: TestSink = .{ .gpa = gpa };
    defer sink.quads.deinit(gpa);
    try lay.drawFixed(&sink, "a\tb c\nd", 0, 0, .{}, 10, 8.5, 15, null, null, .mono);
    try std.testing.expectEqual(@as(usize, 4), sink.quads.items.len);
    try std.testing.expectEqual(@as(f32, 1), sink.quads.items[0].x);
    try std.testing.expectEqual(@as(f32, @round(8.5 * 5) + 1), sink.quads.items[1].x);
    try std.testing.expectEqual(sink.quads.items[0].y + 15, sink.quads.items[3].y);
}

test "glyph cache evicts when the atlas is full" {
    const gpa = std.testing.allocator;
    var stub: StubGlyphSource = .{};
    const src = stub.source();
    var cache = GlyphCache.init(gpa, .{ .coverage_initial = 32, .coverage_max = 32 });
    defer cache.deinit();
    // 20 px glyphs: 10x14 -> shelves of 16 px, 2 shelves x 2 glyphs.
    var cp: u32 = 'A';
    while (cp < 'A' + 4) : (cp += 1) try std.testing.expect((try cache.get(src, GlyphKey.init(@enumFromInt(0), cp, 20, 0))) != null);
    // Same frame: full, cannot evict.
    try std.testing.expect((try cache.get(src, GlyphKey.init(@enumFromInt(0), 'Z', 20, 0))) == null);
    cache.beginFrame();
    try std.testing.expect((try cache.get(src, GlyphKey.init(@enumFromInt(0), 'Z', 20, 0))) != null);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.evicted_shelves);
    try std.testing.expectEqual(@as(usize, 3), cache.glyphCount());
}

//! Font engine tests against the fonts Verde ships (assets/fonts).
const std = @import("std");
const options = @import("font_options");
const api = @import("api.zig");
const sfnt = @import("sfnt.zig");
const raster = @import("raster.zig");
const SfntFace = @import("sfnt_face.zig").SfntFace;

const testing = std.testing;

pub fn assetPath(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ options.assets_dir, name }) catch unreachable;
}

pub fn loadAsset(name: []const u8) !*SfntFace {
    var buf: [1024]u8 = undefined;
    return SfntFace.initPath(testing.allocator, testing.io, assetPath(&buf, name), 0);
}

test "parse NotoSans basics" {
    const f = try loadAsset("NotoSans-Regular.ttf");
    defer f.deinit(testing.allocator);
    const font = &f.font;
    try testing.expectEqual(@as(u16, 1000), font.units_per_em);
    try testing.expect(font.num_glyphs > 100);
    try testing.expect(font.cmap.format == .f4 or font.cmap.format == .f12);
    const a = font.glyphIndex('A');
    try testing.expect(a != 0);
    try testing.expect(font.advance(a) > 0);
    try testing.expectEqual(@as(u32, 0), font.glyphIndex(0x10FFFD));
    const v = font.vMetrics();
    try testing.expectEqual(@as(i32, 1069), v.ascent);
    try testing.expectEqual(@as(i32, 293), v.descent);
    try testing.expect(!font.isFixedPitch());
    var nb: [128]u8 = undefined;
    try testing.expectEqualStrings("Noto Sans", sfnt.nameString(font.name, .family, &nb).?);
}

test "JetBrains Mono is fixed pitch" {
    const f = try loadAsset("JetBrainsMonoNerdFont-Regular.ttf");
    defer f.deinit(testing.allocator);
    try testing.expect(f.font.isFixedPitch());
    const adv = f.font.advance(f.font.glyphIndex('M'));
    try testing.expectEqual(adv, f.font.advance(f.font.glyphIndex('i')));
}

test "GPOS kerning pairs in NotoSans" {
    const f = try loadAsset("NotoSans-Regular.ttf");
    defer f.deinit(testing.allocator);
    const font = &f.font;
    try testing.expect(font.hasKerning());
    const av = font.kerning(font.glyphIndex('A'), font.glyphIndex('V'));
    const to = font.kerning(font.glyphIndex('T'), font.glyphIndex('o'));
    const hh = font.kerning(font.glyphIndex('H'), font.glyphIndex('H'));
    try testing.expect(av < 0);
    try testing.expect(to < 0);
    try testing.expectEqual(@as(i32, 0), hh);
}

test "composite glyph eacute" {
    const f = try loadAsset("NotoSans-Regular.ttf");
    defer f.deinit(testing.allocator);
    const font = &f.font;
    const g = font.glyphIndex(0xE9);
    try testing.expect(g != 0);
    var ob: sfnt.OutlineBuffer = .{};
    defer ob.deinit(testing.allocator);
    try font.decodeGlyf(testing.allocator, g, &ob);
    // e (2 contours) + acute (1 contour)
    try testing.expect(ob.ends.items.len >= 3);
    var max_y: f32 = -1e9;
    for (ob.points.items) |p| max_y = @max(max_y, p.y);
    // The acute sits above the x-height of 'e' (~536 units).
    try testing.expect(max_y > 600);
    const box = font.glyphBox(g).?;
    try testing.expect(@abs(max_y - @as(f32, @floatFromInt(box.y_max))) < 2);
}

test "rasterize A" {
    const f = try loadAsset("NotoSans-Regular.ttf");
    defer f.deinit(testing.allocator);
    var ws: raster.Workspace = .{};
    defer ws.deinit(testing.allocator);
    var ob: sfnt.OutlineBuffer = .{};
    defer ob.deinit(testing.allocator);
    const bm = try f.rasterizeInto(testing.allocator, &ws, &ob, f.font.glyphIndex('A'), 16, 0, testing.allocator);
    defer testing.allocator.free(bm.pixels);
    try testing.expect(bm.width >= 9 and bm.width <= 12);
    try testing.expect(bm.top >= 11 and bm.top <= 13);
    try testing.expect(bm.height >= 11 and bm.height <= 13);
    var sum: u64 = 0;
    for (bm.pixels) |p| sum += p;
    try testing.expect(sum > 20 * 255);
}

// -- Collection ---------------------------------------------------------------------------------

const collection = @import("collection.zig");
const Collection = collection.Collection;
const discovery = @import("discovery.zig");

const TestSet = struct {
    coll: *Collection,
    sans: api.FaceId,
    mono: api.FaceId,
    nerd: api.FaceId,
    sym: api.FaceId,
    sym2: api.FaceId,

    fn init() !TestSet {
        const c = try Collection.create(testing.allocator, .{ .io = testing.io });
        errdefer c.destroy();
        var buf: [1024]u8 = undefined;
        const sans = try c.addFace(.{ .path = assetPath(&buf, "NotoSans-Regular.ttf") });
        const mono = try c.addFace(.{ .path = assetPath(&buf, "JetBrainsMonoNerdFont-Regular.ttf") });
        const nerd = try c.addFace(.{ .path = assetPath(&buf, "SymbolsNerdFontMono-Regular.ttf") });
        const sym = try c.addFace(.{ .path = assetPath(&buf, "NotoSansSymbols-Regular.ttf") });
        const sym2 = try c.addFace(.{ .path = assetPath(&buf, "NotoSansSymbols2-Regular.ttf") });
        try c.setRoleChain(.ui, &.{ sans, sym, sym2 });
        try c.setRoleChain(.mono, &.{ mono, nerd, sym, sym2 });
        return .{ .coll = c, .sans = sans, .mono = mono, .nerd = nerd, .sym = sym, .sym2 = sym2 };
    }
    fn deinit(self: TestSet) void {
        self.coll.destroy();
    }
};

test "collection: faceCount, kerning reduces AV/To width" {
    const t = try TestSet.init();
    defer t.deinit();
    try testing.expectEqual(@as(usize, 5), t.coll.faceCount());
    const av = try t.coll.measureText(.ui, 16, "AV");
    const a = try t.coll.measureText(.ui, 16, "A");
    const v = try t.coll.measureText(.ui, 16, "V");
    try testing.expect(av < a + v - 0.3);
    const to = try t.coll.measureText(.ui, 16, "To");
    const t1 = try t.coll.measureText(.ui, 16, "T");
    const o = try t.coll.measureText(.ui, 16, "o");
    // NotoSans To = -70 units -> -1.12 px at 16 px.
    try testing.expectApproxEqAbs(t1 + o - 1.125, to, 0.02);
    // Kerning off -> plain sum.
    var cfg = t.coll.roleConfig(.ui);
    cfg.kerning = false;
    t.coll.setRoleConfig(.ui, cfg);
    try testing.expectApproxEqAbs(t1 + o, try t.coll.measureText(.ui, 16, "To"), 0.001);
}

test "collection: advanceAt ASCII pair cache equals the uncached path (ligatures on)" {
    const t = try TestSet.init();
    defer t.deinit();
    try testing.expect(t.coll.roleConfig(.ui).ligatures);
    // "fi"/"ffi" start ligatures in NotoSans: 'f' must not be served from the pair table.
    const texts = [_][]const u8{ "office fit ffl AVATAR To.", "the quick brown fox\njumps", "f", "fi", "ffi x" };
    for ([_]f32{ 13.76, 16 }) |size| {
        for (0..2) |_| { // second pass hits the cache
            for (texts) |text| for (0..text.len) |i| {
                const want = t.coll.advanceAtUncached(.ui, size, text, i);
                const got = t.coll.advanceAt(.ui, size, text, i);
                try testing.expectEqual(want.byte_len, got.byte_len);
                try testing.expectEqual(want.width, got.width);
            };
            var pair: [3]u8 = undefined;
            for (0x20..0x7F) |a| for (0x20..0x7F) |b| {
                pair = .{ @intCast(a), @intCast(b), 'i' };
                const want = t.coll.advanceAtUncached(.ui, size, &pair, 0);
                const got = t.coll.advanceAt(.ui, size, &pair, 0);
                try testing.expectEqual(want.byte_len, got.byte_len);
                try testing.expectEqual(want.width, got.width);
            };
        }
    }
    // 'f' is ligature-dependent, 'o' is not.
    try testing.expectEqual(@as(usize, 2), t.coll.advanceAt(.ui, 16, "fi", 0).byte_len);
}

test "collection: advances are rounded per glyph (SDL_ttf parity)" {
    const t = try TestSet.init();
    defer t.deinit();
    // Values from the SDL3_ttf reference dump (tools/font_reference), NotoSans 16 px and
    // 11.18 px: 'O' is 12.496 px unrounded but FreeType's 26.6 math gives 13.
    const cases = [_]struct { size: f32, text: []const u8, want: []const f32 }{
        .{ .size = 16, .text = "OQ`Hi", .want = &.{ 13, 13, 5, 12, 4 } },
        .{ .size = 11.18, .text = "NAa", .want = &.{ 9, 7, 6 } },
    };
    for (cases) |c| for (c.text, c.want) |ch, w| {
        try testing.expectEqual(w, try t.coll.measureText(.ui, c.size, &.{ch}));
    };
    // head.flags bit 3 fonts are measured at the integer ppem (CalSans 13.76 px -> 14 ppem).
    try testing.expectEqual(@as(f32, 9), collection.hintedAdvance(616, 13.76, 1000, true));
    try testing.expectEqual(@as(f32, 8), collection.hintedAdvance(616, 13.76, 1000, false));
}

test "collection: line metrics match SDL_ttf (NotoSans 16 px)" {
    const t = try TestSet.init();
    defer t.deinit();
    const m = t.coll.lineMetrics(.ui, 16);
    // SDL_ttf: ascent=18 descent=-4 height=22 lineskip=22.
    try testing.expectEqual(@as(f32, 18), m.ascent);
    try testing.expectEqual(@as(f32, 4), m.descent);
    try testing.expectEqual(@as(f32, 22), m.lineHeight());
    // 11.18 px: ascent=12 descent=-3 lineskip=16 (height 16 != 12 + 3: FreeType ceils each).
    const s = t.coll.lineMetrics(.ui, 11.18);
    try testing.expectEqual(@as(f32, 12), s.ascent);
    try testing.expectEqual(@as(f32, 3), s.descent);
    try testing.expectEqual(@as(f32, 16), s.lineHeight());
}

test "collection: fallback chain for U+273B" {
    const t = try TestSet.init();
    defer t.deinit();
    try testing.expectEqual(@as(u32, 0), t.coll.sfntFace(t.mono).?.font.glyphIndex(0x273B));
    const r = t.coll.resolve(.mono, 0x273B).?;
    try testing.expect(r.face != t.mono);
    try testing.expect(r.face == t.nerd or r.face == t.sym or r.face == t.sym2);
    try testing.expect(r.glyph != 0);
    var out: std.ArrayList(api.ShapedGlyph) = .empty;
    defer out.deinit(testing.allocator);
    try t.coll.shape(testing.allocator, .mono, 13, "a\u{273B}b", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(t.mono, out.items[0].face);
    try testing.expectEqual(r.face, out.items[1].face);
    try testing.expectEqual(t.mono, out.items[2].face);
    // Unknown roles fall back to the ui chain.
    try testing.expect(t.coll.resolve(.prose, 'a').?.face == t.sans);
}

test "collection: clusters on multibyte text, invalid UTF-8" {
    const t = try TestSet.init();
    defer t.deinit();
    var out: std.ArrayList(api.ShapedGlyph) = .empty;
    defer out.deinit(testing.allocator);
    const text = "a\u{e9}\u{20AC}\u{1F600}z"; // 1 + 2 + 3 + 4 + 1 bytes
    try t.coll.shape(testing.allocator, .ui, 16, text, &out);
    try testing.expectEqual(@as(usize, 5), out.items.len);
    const want = [_]u32{ 0, 1, 3, 6, 10 };
    for (want, out.items) |w, g| try testing.expectEqual(w, g.cluster);
    // Invalid bytes -> one U+FFFD each, clusters still advance.
    out.clearRetainingCapacity();
    try t.coll.shape(testing.allocator, .ui, 16, "a\xff\xc3b", &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[1].cluster);
    try testing.expectEqual(@as(u32, 2), out.items[2].cluster);
    try testing.expectEqual(@as(u32, 3), out.items[3].cluster);
    // glyphAdvances: one slot per byte; continuation bytes get 0.
    var adv: [text.len]f32 = undefined;
    try t.coll.glyphAdvances(.ui, 16, text, &adv);
    try testing.expect(adv[1] > 0);
    try testing.expectEqual(@as(f32, 0), adv[2]);
    var sum: f32 = 0;
    for (adv) |x| sum += x;
    try testing.expectApproxEqAbs(try t.coll.measureText(.ui, 16, text), sum, 0.001);
}

test "collection: fi ligature on ui, off on mono, clusters" {
    const t = try TestSet.init();
    defer t.deinit();
    var out: std.ArrayList(api.ShapedGlyph) = .empty;
    defer out.deinit(testing.allocator);
    try t.coll.shape(testing.allocator, .ui, 16, "fix", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].cluster);
    try testing.expectEqual(@as(u32, 2), out.items[1].cluster);
    // Offsets inside a ligature snap to the cluster start.
    try testing.expectEqual(@as(f32, 0), try t.coll.measureTextOffset(.ui, 16, "fix", 1));
    try testing.expectEqual(out.items[0].x_advance, try t.coll.measureTextOffset(.ui, 16, "fix", 2));
    out.clearRetainingCapacity();
    try t.coll.shape(testing.allocator, .mono, 16, "fix", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}

test "collection: shape cache hits and text_layout adapter" {
    const t = try TestSet.init();
    defer t.deinit();
    const a = try t.coll.shapeCached(.ui, 16, "Hello, world");
    const n = a.len;
    const misses = t.coll.stats.shape_misses;
    const b = try t.coll.shapeCached(.ui, 16, "Hello, world");
    try testing.expectEqual(n, b.len);
    try testing.expectEqual(misses, t.coll.stats.shape_misses);
    try testing.expect(t.coll.stats.shape_hits >= 1);
    const fm = t.coll.fontMetrics(.mono, 13);
    const adv = fm.advance.?(fm.context, "abc", 1, 13);
    try testing.expectEqual(@as(usize, 1), adv.byte_len);
    try testing.expect(adv.width > 0);
    try testing.expect(fm.line_height > 0);
}

test "collection: shape cache rotation never stores empty glyph runs" {
    const c = try Collection.create(testing.allocator, .{ .io = testing.io, .shape_cache_bytes = 4096 });
    defer c.destroy();
    var buf: [1024]u8 = undefined;
    const sans = try c.addFace(.{ .path = assetPath(&buf, "NotoSans-Regular.ttf") });
    try c.setRoleChain(.ui, &.{sans});
    var text_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const text = try std.fmt.bufPrint(&text_buf, "can you fix some of the file icnos {d}", .{i});
        const first = try c.shapeCached(.ui, 16, text);
        try testing.expect(first.len > 0);
        // A second lookup is served from the cache (possibly the other generation).
        const again = try c.shapeCached(.ui, 16, text);
        try testing.expectEqual(first.len, again.len);
    }
}

test "collection: rasterize via GlyphKey" {
    const t = try TestSet.init();
    defer t.deinit();
    const r = t.coll.resolve(.ui, 'g').?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bm = try t.coll.rasterize(api.GlyphKey.init(r.face, r.glyph, 16, 2), arena.allocator());
    try testing.expect(!bm.isEmpty());
    try testing.expectEqual(bm.width, bm.stride);
    // 'g' has a descender: bottom below baseline.
    try testing.expect(@as(i32, @intCast(bm.height)) - bm.top > 2);
}

// -- Malformed input ----------------------------------------------------------------------------

test "malformed: truncations and random corruption never crash" {
    const f = try loadAsset("NotoSans-Regular.ttf");
    defer f.deinit(testing.allocator);
    const orig = f.font.data;
    const buf = try testing.allocator.alloc(u8, orig.len);
    defer testing.allocator.free(buf);
    var ws: raster.Workspace = .{};
    defer ws.deinit(testing.allocator);
    var ob: sfnt.OutlineBuffer = .{};
    defer ob.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const sample = "AVTo\u{e9}fi";
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        @memcpy(buf, orig);
        var len = orig.len;
        if (round % 3 == 0) {
            len = rnd.uintLessThan(usize, orig.len);
        } else {
            // Corrupt bytes, biased towards the table directory and headers.
            const hits = 1 + rnd.uintLessThan(usize, 64);
            for (0..hits) |_| {
                const pos = if (rnd.boolean()) rnd.uintLessThan(usize, @min(orig.len, 4096)) else rnd.uintLessThan(usize, orig.len);
                buf[pos] = rnd.int(u8);
            }
        }
        var font = sfnt.Font.init(buf[0..len], 0) catch continue;
        var it = std.unicode.Utf8View.initUnchecked(sample).iterator();
        var prev: u32 = 0;
        while (it.nextCodepoint()) |cp| {
            const g = font.glyphIndex(cp);
            _ = font.advance(g);
            _ = font.kerning(prev, g);
            prev = g;
            var fl = ws.begin(testing.allocator, 16.0 / @as(f32, @floatFromInt(@max(font.units_per_em, 1))), 0);
            font.outline(testing.allocator, g, &ob, &fl) catch continue;
            const bm = ws.finish(testing.allocator, &fl, testing.allocator) catch continue;
            testing.allocator.free(bm.pixels);
        }
        if (font.gsub) |*gs| {
            var gl = [_]u32{ font.glyphIndex('f'), font.glyphIndex('i'), 7, 99999 };
            var cl = [_]u32{ 0, 1, 2, 3 };
            _ = gs.substitute(&gl, &cl);
        }
    }
    // Pure garbage and tiny inputs.
    const tiny = [_][]const u8{ "", "\x00\x01\x00\x00", "ttcf\x00\x01\x00\x00\xff\xff\xff\xff", "OTTO\x00\xff" ++ "\x00" ** 10 };
    for (tiny) |d| try testing.expect(std.meta.isError(sfnt.Font.init(d, 0)));
    for (0..200) |_| {
        const n = rnd.uintLessThan(usize, 2048);
        rnd.bytes(buf[0..n]);
        if (n >= 4) @memcpy(buf[0..4], if (rnd.boolean()) "\x00\x01\x00\x00" else "OTTO");
        _ = sfnt.Font.init(buf[0..n], 0) catch continue;
    }
}

test "discovery: index of the asset dir, match and codepoint fallback" {
    const idx = try discovery.Index.create(testing.allocator, testing.io, null, .{
        .extra_dirs = &.{options.assets_dir},
        .use_standard_dirs = false,
        .use_cache = false,
    });
    defer idx.destroy();
    try testing.expect(idx.count() >= 11);
    const m = idx.match(.{ .family = "Noto Sans", .weight = 700, .italic = true }).?;
    try testing.expect(std.mem.endsWith(u8, m.path, "NotoSans-BoldItalic.ttf"));
    const r = idx.match(.{ .family = "noto-sans" }).?;
    try testing.expect(std.mem.endsWith(u8, r.path, "NotoSans-Regular.ttf"));
    const mono = idx.match(.{ .family = "monospace", .monospace = true }).?;
    try testing.expect(mono.entry.monospace);
    const fb = idx.fallbackForCodepoint(0x273B).?;
    try testing.expect(std.mem.indexOf(u8, fb.path, "Symbols") != null);
    try testing.expect(idx.fallbackForCodepoint(0x10FFFD) == null);
    try testing.expect(idx.fallbackForCodepoint(0x10FFFD) == null);
}

test "discovery: cache round trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realPathFile(testing.io, ".", &pbuf);
    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&cbuf, "{s}/sub/fonts.bin", .{pbuf[0..tmp_path]});
    const o: discovery.Options = .{ .extra_dirs = &.{options.assets_dir}, .use_standard_dirs = false, .cache_path = cache };
    const a = try discovery.Index.create(testing.allocator, testing.io, null, o);
    defer a.destroy();
    try testing.expect(!a.from_cache);
    const b = try discovery.Index.create(testing.allocator, testing.io, null, o);
    defer b.destroy();
    try testing.expect(b.from_cache);
    try testing.expectEqual(a.count(), b.count());
    for (a.entries.items, b.entries.items) |x, y| {
        try testing.expectEqualStrings(x.family, y.family);
        try testing.expectEqual(x.weight, y.weight);
        try testing.expectEqualStrings(a.pathOf(&x), b.pathOf(&y));
    }
}

// -- System fonts (skipped when not installed) ------------------------------------------------

fn loadSystem(path: []const u8, index: u32) !*SfntFace {
    return SfntFace.initPath(testing.allocator, testing.io, path, index) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
}

test "CFF outlines (URW C059 .otf)" {
    const f = try loadSystem("/usr/share/fonts/gsfonts/C059-Roman.otf", 0);
    defer f.deinit(testing.allocator);
    try testing.expect(f.font.outline_kind == .cff);
    var ws: raster.Workspace = .{};
    defer ws.deinit(testing.allocator);
    var ob: sfnt.OutlineBuffer = .{};
    defer ob.deinit(testing.allocator);
    for ("AQg&@") |ch| {
        const bm = try f.rasterizeInto(testing.allocator, &ws, &ob, f.font.glyphIndex(ch), 24, 0, testing.allocator);
        defer testing.allocator.free(bm.pixels);
        try testing.expect(bm.width > 4 and bm.height > 4);
        var sum: u64 = 0;
        for (bm.pixels) |p| sum += p;
        try testing.expect(sum > 30 * 255);
    }
}

test "TTC collection faces (Noto Sans CJK)" {
    const path = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
    const n = blk: {
        const f = try loadSystem(path, 0);
        defer f.deinit(testing.allocator);
        break :blk try sfnt.faceCount(f.font.data);
    };
    try testing.expect(n > 1);
    const f = try loadSystem(path, n - 1);
    defer f.deinit(testing.allocator);
    try testing.expect(f.font.glyphIndex(0x4E2D) != 0);
    try testing.expectError(error.FaceIndexOutOfRange, SfntFace.initPath(testing.allocator, testing.io, path, n));
}

// -- Synthetic cmap subtables -------------------------------------------------------------------

const Bytes = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    fn u16_(self: *Bytes, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], v, .big);
        self.len += 2;
    }
    fn u32_(self: *Bytes, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .big);
        self.len += 4;
    }
    fn slice(self: *const Bytes) []const u8 {
        return self.buf[0..self.len];
    }
};

/// cmap with (1,0) format 0 at index 0, (3,1) format 6, (3,10) format 12; `with12` toggles the
/// last record so preference can be checked.
fn buildCmap(b: *Bytes, with12: bool) void {
    const n: u16 = if (with12) 3 else 2;
    b.u16_(0);
    b.u16_(n);
    const hdr = 4 + 8 * @as(u32, n);
    const off0 = hdr;
    const off6 = off0 + 262;
    const off12 = off6 + 10 + 2 * 3;
    b.u16_(1);
    b.u16_(0);
    b.u32_(off0);
    b.u16_(3);
    b.u16_(1);
    b.u32_(off6);
    if (with12) {
        b.u16_(3);
        b.u16_(10);
        b.u32_(off12);
    }
    // format 0: 'A' -> 5
    b.u16_(0);
    b.u16_(262);
    b.u16_(0);
    for (0..256) |i| {
        b.buf[b.len + i] = if (i == 'A') 5 else 0;
    }
    b.len += 256;
    // format 6: first 0x41, 3 entries -> 10, 11, 12
    b.u16_(6);
    b.u16_(16);
    b.u16_(0);
    b.u16_(0x41);
    b.u16_(3);
    b.u16_(10);
    b.u16_(11);
    b.u16_(12);
    // format 12: groups [0x41..0x43] -> 20.., [0x1F600..0x1F601] -> 100..
    b.u16_(12);
    b.u16_(0);
    b.u32_(16 + 24);
    b.u32_(0);
    b.u32_(2);
    b.u32_(0x41);
    b.u32_(0x43);
    b.u32_(20);
    b.u32_(0x1F600);
    b.u32_(0x1F601);
    b.u32_(100);
}

test "cmap formats 0/6/12 and subtable preference" {
    var b: Bytes = .{};
    buildCmap(&b, true);
    const c = sfnt.Cmap.init(b.slice());
    try testing.expectEqual(sfnt.Cmap.Format.f12, c.format);
    try testing.expectEqual(@as(u32, 21), c.lookup('B'));
    try testing.expectEqual(@as(u32, 101), c.lookup(0x1F601));
    try testing.expectEqual(@as(u32, 0), c.lookup(0x1F602));
    try testing.expectEqual(@as(u32, 0), c.lookup('D'));

    var b2: Bytes = .{};
    buildCmap(&b2, false);
    const c6 = sfnt.Cmap.init(b2.slice());
    try testing.expectEqual(sfnt.Cmap.Format.f6, c6.format);
    try testing.expectEqual(@as(u32, 12), c6.lookup('C'));
    try testing.expectEqual(@as(u32, 0), c6.lookup('@'));
    try testing.expectEqual(@as(u32, 0), c6.lookup(0x1F600));

    // Only the (1,0) record left: format 0.
    std.mem.writeInt(u16, b2.buf[2..4], 1, .big);
    const c0 = sfnt.Cmap.init(b2.slice());
    try testing.expectEqual(sfnt.Cmap.Format.f0, c0.format);
    try testing.expectEqual(@as(u32, 5), c0.lookup('A'));
    try testing.expectEqual(@as(u32, 0), c0.lookup(0x141));
    // Truncated tables never crash and map nothing.
    var cut: usize = 0;
    while (cut < b.len) : (cut += 7) {
        const t = sfnt.Cmap.init(b.slice()[0..cut]);
        _ = t.lookup('A');
        _ = t.lookup(0x1F600);
    }
}

test "malformed: corrupted CFF charstrings never crash" {
    const f = try loadSystem("/usr/share/fonts/gsfonts/C059-Roman.otf", 0);
    defer f.deinit(testing.allocator);
    const orig = f.font.data;
    const buf = try testing.allocator.dupe(u8, orig);
    defer testing.allocator.free(buf);
    const cff_off = @intFromPtr(f.font.cff.?.data.ptr) - @intFromPtr(orig.ptr);
    const cff_len = f.font.cff.?.data.len;
    var ws: raster.Workspace = .{};
    defer ws.deinit(testing.allocator);
    var ob: sfnt.OutlineBuffer = .{};
    defer ob.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0xcff);
    const rnd = prng.random();
    for (0..300) |_| {
        @memcpy(buf, orig);
        for (0..1 + rnd.uintLessThan(usize, 32)) |_| buf[cff_off + rnd.uintLessThan(usize, cff_len)] = rnd.int(u8);
        var font = sfnt.Font.init(buf, 0) catch continue;
        for ("Ag@") |ch| {
            var fl = ws.begin(testing.allocator, 0.016, 0.5);
            font.outline(testing.allocator, font.glyphIndex(ch), &ob, &fl) catch continue;
            const bm = ws.finish(testing.allocator, &fl, testing.allocator) catch continue;
            testing.allocator.free(bm.pixels);
        }
    }
}

test "collection: system fallback adds faces lazily" {
    // macOS: point HOME at a scratch dir so the scan stays out of the user's ~/Library.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var hbuf: [std.fs.max_path_bytes]u8 = undefined;
    const hlen = try tmp.dir.realPathFile(testing.io, ".", &hbuf);
    try env.put("HOME", hbuf[0..hlen]);
    const environ: ?*const std.process.Environ.Map = if (@import("builtin").os.tag == .macos) &env else null;
    const c = try Collection.create(testing.allocator, .{ .io = testing.io, .environ = environ, .system_fallback = true, .discovery = .{ .use_cache = false } });
    defer c.destroy();
    var buf: [1024]u8 = undefined;
    const sans = try c.addFace(.{ .path = assetPath(&buf, "NotoSans-Regular.ttf") });
    try c.setRoleChain(.ui, &.{sans});
    const r = c.resolve(.ui, 0x4E2D) orelse return error.SkipZigTest;
    if (r.glyph == 0) return error.SkipZigTest; // no CJK font installed
    try testing.expect(r.face != sans);
    try testing.expectEqual(@as(usize, 2), c.faceCount());
    _ = c.resolve(.ui, 0x6587); // same face, no new entry
    try testing.expectEqual(@as(usize, 2), c.faceCount());
}

const BoxFace = struct {
    deinit_called: *bool,
    fn cast(p: *anyopaque) *BoxFace {
        return @ptrCast(@alignCast(p));
    }
    fn glyphIndex(_: *anyopaque, cp: u21) api.GlyphId {
        return if (cp == 0x25A0) 1 else 0;
    }
    fn advance(_: *anyopaque, _: api.GlyphId) i32 {
        return 500;
    }
    fn kerning(_: *anyopaque, _: api.GlyphId, _: api.GlyphId) i32 {
        return 0;
    }
    fn unitsPerEm(_: *anyopaque) u16 {
        return 1000;
    }
    fn unitMetrics(_: *anyopaque) api.UnitMetrics {
        return .{ .ascent = 800, .descent = 200 };
    }
    fn rasterize(_: *anyopaque, _: api.GlyphId, px: f32, _: u8, scratch: std.mem.Allocator) anyerror!api.Bitmap {
        const n: u32 = @intFromFloat(@round(px / 2));
        const pixels = try scratch.alloc(u8, n * n);
        @memset(pixels, 255);
        return .{ .width = n, .height = n, .stride = n, .top = @intCast(n), .pixels = pixels };
    }
    fn deinit(p: *anyopaque, _: std.mem.Allocator) void {
        cast(p).deinit_called.* = true;
    }
    const vtable: api.Face.VTable = .{ .glyphIndex = glyphIndex, .advance = advance, .kerning = kerning, .unitsPerEm = unitsPerEm, .unitMetrics = unitMetrics, .rasterize = rasterize, .deinit = deinit };
};

test "collection: custom Face in a role chain" {
    var called = false;
    var box: BoxFace = .{ .deinit_called = &called };
    {
        const t = try TestSet.init();
        defer t.deinit();
        const id = try t.coll.addFace(.{ .custom = .{ .ptr = &box, .vtable = &BoxFace.vtable } });
        try t.coll.setRoleChain(.icon, &.{ id, t.sans });
        var out: std.ArrayList(api.ShapedGlyph) = .empty;
        defer out.deinit(testing.allocator);
        try t.coll.shape(testing.allocator, .icon, 20, "\u{25A0}a", &out);
        try testing.expectEqual(id, out.items[0].face);
        try testing.expectEqual(@as(f32, 10), out.items[0].x_advance);
        try testing.expectEqual(t.sans, out.items[1].face);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const bm = try t.coll.rasterize(api.GlyphKey.init(id, 1, 20, 0), arena.allocator());
        try testing.expectEqual(@as(u32, 10), bm.width);
    }
    try testing.expect(called);
}

test "collection: glyphInk is the rasterized ink box, within 1 px of SDL_ttf" {
    const t = try TestSet.init();
    defer t.deinit();
    // SDL_ttf 3.2 TTF_GetGlyphMetrics (hinted FreeType bitmaps) for NotoSans:
    // { size, cp, minx, maxx, miny, maxy }.
    const ref = [_]struct { f32, u21, [4]f32 }{
        .{ 16, 'A', .{ 0, 11, 0, 12 } },
        .{ 16, 'g', .{ 0, 9, -4, 9 } },
        .{ 16, 'o', .{ 0, 9, 0, 9 } },
        .{ 16, '|', .{ 3, 5, -4, 12 } },
        .{ 13.76, 'A', .{ 0, 9, 0, 10 } },
        .{ 13.76, 'g', .{ 0, 8, -3, 8 } },
        .{ 20, 'o', .{ 1, 12, 0, 11 } },
        .{ 20, '|', .{ 4, 7, -5, 15 } },
    };
    for (ref) |r| {
        const ink = t.coll.glyphInk(.ui, r[0], r[1]).?;
        for (0..4) |k| try testing.expect(@abs(ink[k] - r[2][k]) <= 1);
        try testing.expect(ink[1] > ink[0] and ink[3] > ink[2]);
    }
    // Unhinted outline box: 'A' at 16 px spans x 0..10.21, y 0..11.47.
    try testing.expectEqual([4]f32{ 0, 11, 0, 12 }, t.coll.glyphInk(.ui, 16, 'A').?);
    // No outline -> null; fallback faces are used (Nerd icon through the mono chain).
    try testing.expectEqual(@as(?[4]f32, null), t.coll.glyphInk(.ui, 16, ' '));
    const icon = t.coll.glyphInk(.mono, 16, 0xf07b).?;
    try testing.expectEqual([4]f32{ 0, 16, -2, 13 }, icon);
}

test "macOS system fonts: .ttc faces index, every face loads or fails cleanly" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    // System domain only (never the user's ~/Library/Fonts from a test).
    const idx = try discovery.Index.create(testing.allocator, testing.io, null, .{
        .extra_dirs = &.{ "/System/Library/Fonts", "/Library/Fonts" },
        .use_standard_dirs = false,
        .use_cache = false,
    });
    defer idx.destroy();
    var ttc_faces: usize = 0;
    var loaded: usize = 0;
    var failed: usize = 0;
    var bitmap_only: usize = 0;
    var variable: usize = 0;
    var ws: raster.Workspace = .{};
    defer ws.deinit(testing.allocator);
    var ob: sfnt.OutlineBuffer = .{};
    defer ob.deinit(testing.allocator);
    for (idx.entries.items) |*e| {
        const path = idx.pathOf(e);
        if (std.ascii.endsWithIgnoreCase(path, ".ttc") and e.face_index > 0) ttc_faces += 1;
        if (!e.outlines) bitmap_only += 1; // sbix (Apple Color Emoji): not rendered, skipped by fallback
        const f = SfntFace.initPath(testing.allocator, testing.io, path, e.face_index) catch |err| {
            std.debug.print("rejected {s}#{d}: {s}\n", .{ path, e.face_index, @errorName(err) });
            failed += 1;
            continue;
        };
        defer f.deinit(testing.allocator);
        loaded += 1;
        if (sfnt.Directory.init(f.font.data, e.face_index)) |d| {
            if (d.find(sfnt.tag("fvar")) != null) variable += 1;
        } else |_| {}
        if (f.font.outline_kind == .none) continue;
        const g = f.font.glyphIndex('A');
        if (g == 0) continue;
        const bm = f.rasterizeInto(testing.allocator, &ws, &ob, g, 16, 0, testing.allocator) catch continue;
        testing.allocator.free(bm.pixels);
    }
    std.debug.print("macOS fonts: {d} faces indexed ({d} non-first .ttc faces), {d} loaded, {d} rejected, {d} bitmap-only (sbix), {d} variable (default instance)\n", .{ idx.count(), ttc_faces, loaded, failed, bitmap_only, variable });
    try testing.expect(idx.count() > 50);
    try testing.expect(ttc_faces > 0);
    try testing.expect(idx.match(.{ .family = "Helvetica" }) != null);
    const mono = idx.match(.{ .family = "monospace", .monospace = true }) orelse return error.NoMonospace;
    try testing.expect(mono.entry.monospace);
    // Emoji fallback must not pick the sbix font (its glyf outlines are empty).
    if (idx.fallbackForCodepoint(0x1F600)) |m| try testing.expect(std.mem.indexOf(u8, m.path, "Apple Color Emoji") == null);
}

test "discovery (Windows): %WINDIR%\\Fonts + per-user fonts, cache under %LOCALAPPDATA%\\palette" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, ".", &pbuf);
    const base = pbuf[0..n];
    try tmp.dir.createDirPath(testing.io, "win/Fonts");
    try tmp.dir.createDirPath(testing.io, "local/Microsoft/Windows/Fonts");
    var abuf: [1024]u8 = undefined;
    // Upper-case extension, as many Windows system fonts have.
    try std.Io.Dir.cwd().copyFile(assetPath(&abuf, "NotoSans-Regular.ttf"), tmp.dir, "win/Fonts/NOTOSANS.TTF", testing.io, .{});
    try std.Io.Dir.cwd().copyFile(assetPath(&abuf, "NotoSans-Bold.ttf"), tmp.dir, "local/Microsoft/Windows/Fonts/NotoSans-Bold.ttf", testing.io, .{});

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var wbuf: [std.fs.max_path_bytes]u8 = undefined;
    var lbuf: [std.fs.max_path_bytes]u8 = undefined;
    try env.put("WINDIR", try std.fmt.bufPrint(&wbuf, "{s}\\win", .{base}));
    try env.put("LOCALAPPDATA", try std.fmt.bufPrint(&lbuf, "{s}\\local", .{base}));

    const a = try discovery.Index.create(testing.allocator, testing.io, &env, .{});
    defer a.destroy();
    try testing.expect(!a.from_cache);
    try testing.expectEqual(@as(usize, 2), a.count());
    const bold = a.match(.{ .family = "Noto Sans", .weight = 700 }).?;
    try testing.expect(std.mem.endsWith(u8, bold.path, "NotoSans-Bold.ttf"));
    // Second index loads the cache written to %LOCALAPPDATA%\palette\fonts-v1.bin.
    const b = try discovery.Index.create(testing.allocator, testing.io, &env, .{});
    defer b.destroy();
    try testing.expect(b.from_cache);
    try testing.expectEqual(a.count(), b.count());
    var cdir = try tmp.dir.openDir(testing.io, "local/palette", .{});
    defer cdir.close(testing.io);
    _ = try cdir.statFile(testing.io, "fonts-v1.bin", .{});
}

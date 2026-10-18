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

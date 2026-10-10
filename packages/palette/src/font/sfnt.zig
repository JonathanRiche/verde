//! Pure-Zig sfnt (TrueType / OpenType) parser.
//!
//! `Font` is a *view* over the font bytes: nothing is copied, every table is a slice into the
//! original buffer (usually an mmapped file). All offsets read from the file are validated; a
//! malformed font yields `error.InvalidFont` (at load) or an empty/notdef result (at query time),
//! never a crash.
//!
//! Supported: table directory + TTC collections, head, hhea, maxp, hmtx, loca (short/long),
//! glyf (simple + composite, all transform variants, point matching), cmap formats 0/4/6/12/13
//! (+ symbol (3,0) remap), OS/2, post, name, kern (format 0), GPOS pair adjustment and GSUB
//! single/ligature (see otl.zig), CFF1 Type2 charstrings (see cff.zig).

const std = @import("std");
const otl = @import("otl.zig");
const cff = @import("cff.zig");

pub const Error = error{ InvalidFont, UnsupportedFont, FaceIndexOutOfRange };

pub const Tag = u32;
pub fn tag(comptime s: *const [4]u8) Tag {
    return std.mem.readInt(u32, s, .big);
}

// ---------------------------------------------------------------------------------------------
// Bounds-checked big-endian readers. Every read from font data goes through these (or through a
// range that was validated against the table length beforehand).

pub inline fn u8At(d: []const u8, off: usize) Error!u8 {
    if (off >= d.len) return error.InvalidFont;
    return d[off];
}
pub inline fn u16At(d: []const u8, off: usize) Error!u16 {
    if (off > d.len or d.len - off < 2) return error.InvalidFont;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}
pub inline fn i16At(d: []const u8, off: usize) Error!i16 {
    return @bitCast(try u16At(d, off));
}
pub inline fn u32At(d: []const u8, off: usize) Error!u32 {
    if (off > d.len or d.len - off < 4) return error.InvalidFont;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}
pub inline fn i32At(d: []const u8, off: usize) Error!i32 {
    return @bitCast(try u32At(d, off));
}
/// Unchecked reads; only for ranges validated up-front.
pub inline fn rd16(d: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, d[off..][0..2], .big);
}
pub inline fn rd32(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .big);
}
/// Returns `d[off..off+len]` or InvalidFont.
pub inline fn sub(d: []const u8, off: usize, len: usize) Error![]const u8 {
    if (off > d.len or d.len - off < len) return error.InvalidFont;
    return d[off..][0..len];
}
/// Returns `d[off..]` or InvalidFont.
pub inline fn tail(d: []const u8, off: usize) Error![]const u8 {
    if (off > d.len) return error.InvalidFont;
    return d[off..];
}

// ---------------------------------------------------------------------------------------------

pub const TableRecord = struct { tag: Tag, data: []const u8 };

/// Number of faces in a font file (1 for plain sfnt, N for a TTC).
pub fn faceCount(data: []const u8) Error!u32 {
    const version = try u32At(data, 0);
    if (version == tag("ttcf")) {
        const n = try u32At(data, 8);
        if (n == 0 or n > 4096) return error.InvalidFont;
        return n;
    }
    return 1;
}

/// Iterates the table directory of face `index`.
pub const Directory = struct {
    data: []const u8,
    dir: []const u8,
    count: u16,

    pub fn init(data: []const u8, index: u32) Error!Directory {
        var base: usize = 0;
        const version = try u32At(data, 0);
        if (version == tag("ttcf")) {
            const n = try faceCount(data);
            if (index >= n) return error.FaceIndexOutOfRange;
            base = try u32At(data, 12 + 4 * @as(usize, index));
        } else if (index != 0) return error.FaceIndexOutOfRange;
        const sfnt_version = try u32At(data, base);
        switch (sfnt_version) {
            0x00010000, 0x74727565, 0x4F54544F => {}, // 1.0, 'true', 'OTTO'
            0x74797031 => return error.UnsupportedFont, // 'typ1'
            else => return error.InvalidFont,
        }
        const count = try u16At(data, base + 4);
        const dir = try sub(data, base + 12, @as(usize, count) * 16);
        return .{ .data = data, .dir = dir, .count = count };
    }

    pub fn find(self: Directory, t: Tag) ?[]const u8 {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const rec = self.dir[i * 16 ..][0..16];
            if (std.mem.readInt(u32, rec[0..4], .big) != t) continue;
            const off = std.mem.readInt(u32, rec[8..12], .big);
            const len = std.mem.readInt(u32, rec[12..16], .big);
            return sub(self.data, off, len) catch null;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------------------------
// cmap

pub const Cmap = struct {
    pub const Format = enum(u8) { none, f0, f4, f6, f12, f13 };
    format: Format = .none,
    data: []const u8 = &.{},
    /// (3,0) symbol subtable: Windows symbol fonts map U+F000..U+F0FF.
    symbol: bool = false,

    fn rank(platform: u16, encoding: u16) ?u8 {
        return switch (platform) {
            3 => switch (encoding) {
                10 => 0,
                1 => 2,
                0 => 6,
                else => null,
            },
            0 => switch (encoding) {
                4, 6 => 1,
                3 => 3,
                0, 1, 2 => 4,
                else => null,
            },
            1 => if (encoding == 0) 7 else null,
            else => null,
        };
    }

    /// Preference: (3,10) > (0,4|6) > (3,1) > (0,3) > (0,0..2) > (3,0) > (1,0).
    pub fn init(table: []const u8) Cmap {
        const n = u16At(table, 2) catch return .{};
        var best: Cmap = .{};
        var best_rank: u8 = 255;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 4 + i * 8;
            const platform = u16At(table, rec) catch break;
            const encoding = u16At(table, rec + 2) catch break;
            const off = u32At(table, rec + 4) catch break;
            const r = rank(platform, encoding) orelse continue;
            if (r >= best_rank) continue;
            const st = tail(table, off) catch continue;
            const candidate = initSubtable(st) orelse continue;
            best = candidate;
            best.symbol = platform == 3 and encoding == 0;
            best_rank = r;
        }
        return best;
    }

    fn initSubtable(st: []const u8) ?Cmap {
        const fmt = u16At(st, 0) catch return null;
        switch (fmt) {
            0 => {
                const d = sub(st, 0, 6 + 256) catch return null;
                return .{ .format = .f0, .data = d };
            },
            4 => {
                const len = u16At(st, 2) catch return null;
                const seg_x2 = u16At(st, 6) catch return null;
                if (seg_x2 == 0 or seg_x2 & 1 != 0) return null;
                // Some fonts have a wrong `length`; use the larger of declared and minimum.
                const min_len = 16 + 4 * @as(usize, seg_x2);
                const d = sub(st, 0, @max(@min(len, st.len), min_len)) catch return null;
                return .{ .format = .f4, .data = d };
            },
            6 => {
                const count = u16At(st, 8) catch return null;
                const d = sub(st, 0, 10 + 2 * @as(usize, count)) catch return null;
                return .{ .format = .f6, .data = d };
            },
            12, 13 => {
                const n_groups = u32At(st, 12) catch return null;
                if (n_groups > (st.len -| 16) / 12) return null;
                const d = sub(st, 0, 16 + 12 * @as(usize, n_groups)) catch return null;
                return .{ .format = if (fmt == 12) .f12 else .f13, .data = d };
            },
            else => return null,
        }
    }

    pub fn lookup(self: Cmap, cp: u21) u32 {
        const g = self.lookupRaw(cp);
        if (g == 0 and self.symbol and cp <= 0xFF) return self.lookupRaw(0xF000 + @as(u21, cp));
        return g;
    }

    fn lookupRaw(self: Cmap, cp: u21) u32 {
        const d = self.data;
        switch (self.format) {
            .none => return 0,
            .f0 => return if (cp < 256) d[6 + cp] else 0,
            .f6 => {
                const first = rd16(d, 6);
                const count = rd16(d, 8);
                if (cp < first or cp - first >= count) return 0;
                return rd16(d, 10 + 2 * @as(usize, cp - first));
            },
            .f4 => {
                if (cp > 0xFFFF) return 0;
                const c: u16 = @intCast(cp);
                const seg_x2: usize = rd16(d, 6);
                const segs = seg_x2 / 2;
                const end_codes = 14;
                const start_codes = 16 + seg_x2;
                const deltas = 16 + 2 * seg_x2;
                const range_offs = 16 + 3 * seg_x2;
                // Binary search for the first segment with endCode >= c.
                var lo: usize = 0;
                var hi: usize = segs;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (rd16(d, end_codes + mid * 2) < c) lo = mid + 1 else hi = mid;
                }
                if (lo >= segs) return 0;
                const start = rd16(d, start_codes + lo * 2);
                if (c < start) return 0;
                const delta = rd16(d, deltas + lo * 2);
                const ro = rd16(d, range_offs + lo * 2);
                if (ro == 0) return c +% delta;
                const at = range_offs + lo * 2 + @as(usize, ro) + 2 * @as(usize, c - start);
                const g = u16At(d, at) catch return 0;
                if (g == 0) return 0;
                return g +% delta;
            },
            .f12, .f13 => {
                const n: usize = rd32(d, 12);
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const rec = 16 + mid * 12;
                    const start = rd32(d, rec);
                    const end = rd32(d, rec + 4);
                    if (cp < start) {
                        hi = mid;
                    } else if (cp > end) {
                        lo = mid + 1;
                    } else {
                        const sg = rd32(d, rec + 8);
                        return if (self.format == .f12) sg +% (cp - start) else sg;
                    }
                }
                return 0;
            },
        }
    }
};

// ---------------------------------------------------------------------------------------------
// name

pub const NameId = enum(u16) {
    family = 1,
    subfamily = 2,
    full_name = 4,
    postscript = 6,
    typographic_family = 16,
    typographic_subfamily = 17,
    _,
};

/// Decodes the best record for `id` into `buf` as UTF-8. Prefers Windows English (0x409), then
/// any Windows/Unicode record, then Mac Roman. Returns null when absent.
pub fn nameString(table: []const u8, id: NameId, buf: []u8) ?[]const u8 {
    const count = u16At(table, 2) catch return null;
    const storage = u16At(table, 4) catch return null;
    var best_score: u8 = 0;
    var best_rec: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = 6 + i * 12;
        const platform = u16At(table, rec) catch return null;
        const encoding = u16At(table, rec + 2) catch return null;
        const lang = u16At(table, rec + 4) catch return null;
        const nid = u16At(table, rec + 6) catch return null;
        if (nid != @intFromEnum(id)) continue;
        const score: u8 = switch (platform) {
            3 => if (encoding == 1 or encoding == 10) (if (lang == 0x409) 5 else 3) else 0,
            0 => 4,
            1 => if (encoding == 0) (if (lang == 0) 2 else 1) else 0,
            else => 0,
        };
        if (score > best_score) {
            best_score = score;
            best_rec = rec;
        }
    }
    if (best_score == 0) return null;
    const platform = u16At(table, best_rec) catch return null;
    const len = u16At(table, best_rec + 8) catch return null;
    const off = u16At(table, best_rec + 10) catch return null;
    const raw = sub(table, @as(usize, storage) + off, len) catch return null;
    var n: usize = 0;
    if (platform == 1) {
        for (raw) |b| {
            const ch: u8 = if (b < 0x80) b else '?';
            if (n >= buf.len) break;
            buf[n] = ch;
            n += 1;
        }
        return buf[0..n];
    }
    var j: usize = 0;
    while (j + 1 < raw.len) : (j += 2) {
        var cp: u21 = rd16(raw, j);
        if (cp >= 0xD800 and cp <= 0xDBFF and j + 3 < raw.len) {
            const lo = rd16(raw, j + 2);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                j += 2;
            }
        }
        if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD;
        var tmp: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (n + l > buf.len) break;
        @memcpy(buf[n..][0..l], tmp[0..l]);
        n += l;
    }
    return buf[0..n];
}

// ---------------------------------------------------------------------------------------------
// OS/2, post

pub const Os2 = struct {
    version: u16 = 0,
    avg_char_width: i16 = 0,
    weight_class: u16 = 400,
    width_class: u16 = 5,
    fs_selection: u16 = 0,
    panose_proportion: u8 = 0,
    typo_ascender: i16 = 0,
    typo_descender: i16 = 0,
    typo_line_gap: i16 = 0,
    win_ascent: u16 = 0,
    win_descent: u16 = 0,
    x_height: i16 = 0,
    cap_height: i16 = 0,
    present: bool = false,

    pub const fs_italic: u16 = 1 << 0;
    pub const fs_bold: u16 = 1 << 5;
    pub const fs_regular: u16 = 1 << 6;
    pub const fs_use_typo_metrics: u16 = 1 << 7;
    pub const fs_oblique: u16 = 1 << 9;

    pub fn parse(t: []const u8) Os2 {
        if (t.len < 78) return .{};
        var o: Os2 = .{
            .version = rd16(t, 0),
            .avg_char_width = @bitCast(rd16(t, 2)),
            .weight_class = rd16(t, 4),
            .width_class = rd16(t, 6),
            .panose_proportion = t[32 + 3],
            .fs_selection = rd16(t, 62),
            .typo_ascender = @bitCast(rd16(t, 68)),
            .typo_descender = @bitCast(rd16(t, 70)),
            .typo_line_gap = @bitCast(rd16(t, 72)),
            .win_ascent = rd16(t, 74),
            .win_descent = rd16(t, 76),
            .present = true,
        };
        if (o.version >= 2 and t.len >= 90) {
            o.x_height = @bitCast(rd16(t, 86));
            o.cap_height = @bitCast(rd16(t, 88));
        }
        return o;
    }
};

pub const Post = struct {
    underline_position: i16 = 0,
    underline_thickness: i16 = 0,
    is_fixed_pitch: bool = false,
    italic_angle: i32 = 0,

    pub fn parse(t: []const u8) Post {
        if (t.len < 16) return .{};
        return .{
            .italic_angle = @bitCast(rd32(t, 4)),
            .underline_position = @bitCast(rd16(t, 8)),
            .underline_thickness = @bitCast(rd16(t, 10)),
            .is_fixed_pitch = rd32(t, 12) != 0,
        };
    }
};

// ---------------------------------------------------------------------------------------------
// Outline points (TrueType) and path emission.

pub const Point = struct { x: f32, y: f32, on: bool };

/// Retained scratch for decoding glyf outlines (composites append into it). Reuse across calls.
pub const OutlineBuffer = struct {
    points: std.ArrayList(Point) = .empty,
    /// Exclusive end index (into `points`) of each contour.
    ends: std.ArrayList(u32) = .empty,

    pub fn clear(self: *OutlineBuffer) void {
        self.points.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
    }
    pub fn deinit(self: *OutlineBuffer, gpa: std.mem.Allocator) void {
        self.points.deinit(gpa);
        self.ends.deinit(gpa);
    }
};

pub const OutlineKind = enum { none, glyf, cff };

pub const BBox = struct { x_min: i16 = 0, y_min: i16 = 0, x_max: i16 = 0, y_max: i16 = 0 };

/// Metrics resolved the way FreeType 2.14 does (and therefore what SDL_ttf reported):
/// OS/2 typo metrics when fsSelection.USE_TYPO_METRICS (bit 7) is set, else hhea, else (both
/// hhea values zero) OS/2 typo, else OS/2 win. Verified against SDL3_ttf: Codicon (typo line
/// gap 27, hhea gap 0, bit 7 set) gets the typo line skip.
pub const VMetrics = struct { ascent: i32, descent: i32, line_gap: i32 };

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u32,
    head_flags: u16,
    mac_style: u16,
    bbox: BBox,
    index_to_loc_long: bool,
    num_hmetrics: u32,
    hhea_ascender: i16,
    hhea_descender: i16,
    hhea_line_gap: i16,
    hmtx: []const u8,
    loca: []const u8,
    glyf: []const u8,
    outline_kind: OutlineKind,
    cff: ?cff.Cff,
    cmap: Cmap,
    os2: Os2,
    post: Post,
    name: []const u8,
    kern: []const u8,
    gpos: ?otl.Gpos,
    gsub: ?otl.Gsub,
    gdef: []const u8,

    pub fn init(data: []const u8, face_index: u32) Error!Font {
        const dir = try Directory.init(data, face_index);
        const head = dir.find(tag("head")) orelse return error.InvalidFont;
        const hhea = dir.find(tag("hhea")) orelse return error.InvalidFont;
        const maxp = dir.find(tag("maxp")) orelse return error.InvalidFont;
        if (head.len < 54 or hhea.len < 36 or maxp.len < 6) return error.InvalidFont;
        if (rd32(head, 12) != 0x5F0F3CF5) return error.InvalidFont; // magic
        const upem = rd16(head, 18);
        if (upem < 16 or upem > 16384) return error.InvalidFont;
        const num_glyphs: u32 = rd16(maxp, 4);
        if (num_glyphs == 0) return error.InvalidFont;
        const loc_fmt: i16 = @bitCast(rd16(head, 50));
        const num_h: u32 = rd16(hhea, 34);
        const hmtx = dir.find(tag("hmtx")) orelse &.{};
        // Lenient: clamp numberOfHMetrics to what the table holds (FreeType does the same).
        const usable_h = @min(num_h, @as(u32, @intCast(hmtx.len / 4)));

        var f: Font = .{
            .data = data,
            .units_per_em = upem,
            .num_glyphs = num_glyphs,
            .head_flags = rd16(head, 16),
            .mac_style = rd16(head, 44),
            .bbox = .{
                .x_min = @bitCast(rd16(head, 36)),
                .y_min = @bitCast(rd16(head, 38)),
                .x_max = @bitCast(rd16(head, 40)),
                .y_max = @bitCast(rd16(head, 42)),
            },
            .index_to_loc_long = loc_fmt != 0,
            .num_hmetrics = usable_h,
            .hhea_ascender = @bitCast(rd16(hhea, 4)),
            .hhea_descender = @bitCast(rd16(hhea, 6)),
            .hhea_line_gap = @bitCast(rd16(hhea, 8)),
            .hmtx = hmtx,
            .loca = &.{},
            .glyf = &.{},
            .outline_kind = .none,
            .cff = null,
            .cmap = if (dir.find(tag("cmap"))) |t| Cmap.init(t) else .{},
            .os2 = if (dir.find(tag("OS/2"))) |t| Os2.parse(t) else .{},
            .post = if (dir.find(tag("post"))) |t| Post.parse(t) else .{},
            .name = dir.find(tag("name")) orelse &.{},
            .kern = dir.find(tag("kern")) orelse &.{},
            .gpos = null,
            .gsub = null,
            .gdef = dir.find(tag("GDEF")) orelse &.{},
        };
        if (dir.find(tag("glyf"))) |glyf| {
            if (dir.find(tag("loca"))) |loca| {
                const entry: usize = if (f.index_to_loc_long) 4 else 2;
                // Clamp glyph count to the loca entries actually present.
                const entries = loca.len / entry;
                if (entries >= 2) {
                    f.loca = loca[0 .. entries * entry];
                    f.glyf = glyf;
                    f.outline_kind = .glyf;
                }
            }
        } else if (dir.find(tag("CFF "))) |t| {
            if (cff.Cff.init(t)) |c| {
                f.cff = c;
                f.outline_kind = .cff;
            } else |_| {}
        }
        if (dir.find(tag("GPOS"))) |t| f.gpos = otl.Gpos.init(t) catch null;
        if (dir.find(tag("GSUB"))) |t| f.gsub = otl.Gsub.init(t) catch null;
        return f;
    }

    pub fn glyphIndex(self: *const Font, cp: u21) u32 {
        const g = self.cmap.lookup(cp);
        return if (g < self.num_glyphs) g else 0;
    }

    /// Advance width in font units.
    pub fn advance(self: *const Font, glyph: u32) u16 {
        if (self.num_hmetrics == 0) return 0;
        const i = @min(glyph, self.num_hmetrics - 1);
        return rd16(self.hmtx, i * 4);
    }

    pub fn leftSideBearing(self: *const Font, glyph: u32) i16 {
        if (self.num_hmetrics == 0) return 0;
        if (glyph < self.num_hmetrics) return @bitCast(rd16(self.hmtx, glyph * 4 + 2));
        const off = self.num_hmetrics * 4 + (glyph - self.num_hmetrics) * 2;
        return i16At(self.hmtx, off) catch 0;
    }

    /// FreeType-compatible vertical metrics (see `VMetrics`).
    pub fn vMetrics(self: *const Font) VMetrics {
        if (self.os2.present and self.os2.fs_selection & Os2.fs_use_typo_metrics != 0 and
            (self.os2.typo_ascender != 0 or self.os2.typo_descender != 0))
        {
            return .{ .ascent = self.os2.typo_ascender, .descent = -@as(i32, self.os2.typo_descender), .line_gap = self.os2.typo_line_gap };
        }
        if (self.hhea_ascender != 0 or self.hhea_descender != 0) {
            return .{ .ascent = self.hhea_ascender, .descent = -@as(i32, self.hhea_descender), .line_gap = self.hhea_line_gap };
        }
        return self.typoOrWinMetrics();
    }

    /// Spec-preferred metrics: OS/2 typo when USE_TYPO_METRICS is set, else hhea.
    pub fn vMetricsTypoPreferred(self: *const Font) VMetrics {
        if (self.os2.present and self.os2.fs_selection & Os2.fs_use_typo_metrics != 0) {
            return .{ .ascent = self.os2.typo_ascender, .descent = -@as(i32, self.os2.typo_descender), .line_gap = self.os2.typo_line_gap };
        }
        return self.vMetrics();
    }

    fn typoOrWinMetrics(self: *const Font) VMetrics {
        if (self.os2.present and (self.os2.typo_ascender != 0 or self.os2.typo_descender != 0)) {
            return .{ .ascent = self.os2.typo_ascender, .descent = -@as(i32, self.os2.typo_descender), .line_gap = self.os2.typo_line_gap };
        }
        if (self.os2.present) return .{ .ascent = self.os2.win_ascent, .descent = self.os2.win_descent, .line_gap = 0 };
        return .{ .ascent = self.bbox.y_max, .descent = -@as(i32, self.bbox.y_min), .line_gap = 0 };
    }

    pub fn isFixedPitch(self: *const Font) bool {
        return self.post.is_fixed_pitch or self.os2.panose_proportion == 9;
    }

    pub fn isItalic(self: *const Font) bool {
        if (self.os2.present) return self.os2.fs_selection & (Os2.fs_italic | Os2.fs_oblique) != 0;
        return self.mac_style & 2 != 0;
    }

    pub fn weight(self: *const Font) u16 {
        if (self.os2.present and self.os2.weight_class >= 1 and self.os2.weight_class <= 1000) return self.os2.weight_class;
        return if (self.mac_style & 1 != 0) 700 else 400;
    }

    /// Pair kerning in font units: GPOS `kern` feature when present, else the legacy kern table.
    pub fn kerning(self: *const Font, left: u32, right: u32) i32 {
        if (self.gpos) |*g| {
            if (g.hasKerning()) return g.pairAdjustment(left, right);
        }
        return otl.kernTableLookup(self.kern, left, right);
    }

    pub fn hasKerning(self: *const Font) bool {
        if (self.gpos) |*g| if (g.hasKerning()) return true;
        return self.kern.len > 0;
    }

    // -- glyf ----------------------------------------------------------------------------------

    fn glyfRange(self: *const Font, glyph: u32) ?[]const u8 {
        const entry: usize = if (self.index_to_loc_long) 4 else 2;
        const n_entries = self.loca.len / entry;
        if (glyph + 1 >= n_entries) return null;
        var start: usize = undefined;
        var end: usize = undefined;
        if (self.index_to_loc_long) {
            start = rd32(self.loca, glyph * 4);
            end = rd32(self.loca, glyph * 4 + 4);
        } else {
            start = @as(usize, rd16(self.loca, glyph * 2)) * 2;
            end = @as(usize, rd16(self.loca, glyph * 2 + 2)) * 2;
        }
        if (end <= start or end > self.glyf.len) return null;
        return self.glyf[start..end];
    }

    /// Glyph bounding box from the glyf header (font units). Null for empty glyphs.
    pub fn glyphBox(self: *const Font, glyph: u32) ?BBox {
        switch (self.outline_kind) {
            .glyf => {
                const g = self.glyfRange(glyph) orelse return null;
                if (g.len < 10) return null;
                return .{
                    .x_min = @bitCast(rd16(g, 2)),
                    .y_min = @bitCast(rd16(g, 4)),
                    .x_max = @bitCast(rd16(g, 6)),
                    .y_max = @bitCast(rd16(g, 8)),
                };
            },
            else => return null,
        }
    }

    /// Decodes the glyf outline of `glyph` into `buf` (cleared first). Coordinates in font units.
    pub fn decodeGlyf(self: *const Font, gpa: std.mem.Allocator, glyph: u32, buf: *OutlineBuffer) (Error || error{OutOfMemory})!void {
        buf.clear();
        try self.decodeGlyfRec(gpa, glyph, buf, 0);
    }

    const max_composite_depth = 8;
    const max_points = 1 << 16;

    fn decodeGlyfRec(self: *const Font, gpa: std.mem.Allocator, glyph: u32, buf: *OutlineBuffer, depth: u8) (Error || error{OutOfMemory})!void {
        if (depth > max_composite_depth) return error.InvalidFont;
        const g = self.glyfRange(glyph) orelse return; // empty glyph
        if (g.len < 10) return error.InvalidFont;
        const n_contours: i16 = @bitCast(rd16(g, 0));
        if (n_contours >= 0) return decodeSimple(gpa, g, @intCast(n_contours), buf);
        return self.decodeComposite(gpa, g, buf, depth);
    }

    fn decodeSimple(gpa: std.mem.Allocator, g: []const u8, n_contours: usize, buf: *OutlineBuffer) (Error || error{OutOfMemory})!void {
        if (n_contours == 0) return;
        const ends_off = 10;
        const ends = try sub(g, ends_off, n_contours * 2);
        const n_points: usize = @as(usize, rd16(ends, (n_contours - 1) * 2)) + 1;
        if (buf.points.items.len + n_points > max_points) return error.InvalidFont;
        const ins_len = try u16At(g, ends_off + n_contours * 2);
        var p: usize = ends_off + n_contours * 2 + 2 + ins_len;
        if (p > g.len) return error.InvalidFont;

        const base: u32 = @intCast(buf.points.items.len);
        try buf.ends.ensureUnusedCapacity(gpa, n_contours);
        var prev_end: usize = 0;
        for (0..n_contours) |c| {
            const e = @as(usize, rd16(ends, c * 2)) + 1;
            if (e < prev_end or e > n_points) return error.InvalidFont;
            prev_end = e;
            buf.ends.appendAssumeCapacity(base + @as(u32, @intCast(e)));
        }
        const pts = try buf.points.addManyAsSlice(gpa, n_points);

        // Flags (with repeat). Store raw flags temporarily in `on`/x as bytes? Keep a small pass:
        // first pass decodes flags into pts[i].on and a packed flag byte in pts[i].x.
        var i: usize = 0;
        while (i < n_points) {
            const flag = try u8At(g, p);
            p += 1;
            var repeat: usize = 1;
            if (flag & 8 != 0) {
                repeat += try u8At(g, p);
                p += 1;
            }
            if (repeat > n_points - i) return error.InvalidFont;
            for (0..repeat) |_| {
                pts[i] = .{ .x = @floatFromInt(flag), .y = 0, .on = flag & 1 != 0 };
                i += 1;
            }
        }
        // X coordinates.
        var acc: i32 = 0;
        for (pts) |*pt| {
            const flag: u8 = @intFromFloat(pt.x);
            if (flag & 2 != 0) {
                const dx: i32 = try u8At(g, p);
                p += 1;
                acc += if (flag & 16 != 0) dx else -dx;
            } else if (flag & 16 == 0) {
                acc += try i16At(g, p);
                p += 2;
            }
            pt.x = @floatFromInt(acc);
            // Stash flag in y temporarily (y is decoded next).
            pt.y = @floatFromInt(flag);
        }
        acc = 0;
        for (pts) |*pt| {
            const flag: u8 = @intFromFloat(pt.y);
            if (flag & 4 != 0) {
                const dy: i32 = try u8At(g, p);
                p += 1;
                acc += if (flag & 32 != 0) dy else -dy;
            } else if (flag & 32 == 0) {
                acc += try i16At(g, p);
                p += 2;
            }
            pt.y = @floatFromInt(acc);
        }
    }

    fn decodeComposite(self: *const Font, gpa: std.mem.Allocator, g: []const u8, buf: *OutlineBuffer, depth: u8) (Error || error{OutOfMemory})!void {
        const ARG_WORDS = 0x1;
        const ARGS_XY = 0x2;
        const HAVE_SCALE = 0x8;
        const MORE = 0x20;
        const XY_SCALE = 0x40;
        const TWO_BY_TWO = 0x80;
        const SCALED_OFFSET = 0x800;
        const UNSCALED_OFFSET = 0x1000;

        const start: usize = buf.points.items.len;
        var p: usize = 10;
        var components: usize = 0;
        while (true) {
            components += 1;
            if (components > 256) return error.InvalidFont;
            const flags = try u16At(g, p);
            const child = try u16At(g, p + 2);
            p += 4;
            var a1: i32 = undefined;
            var a2: i32 = undefined;
            if (flags & ARG_WORDS != 0) {
                if (flags & ARGS_XY != 0) {
                    a1 = try i16At(g, p);
                    a2 = try i16At(g, p + 2);
                } else {
                    a1 = try u16At(g, p);
                    a2 = try u16At(g, p + 2);
                }
                p += 4;
            } else {
                if (flags & ARGS_XY != 0) {
                    a1 = @as(i8, @bitCast(try u8At(g, p)));
                    a2 = @as(i8, @bitCast(try u8At(g, p + 1)));
                } else {
                    a1 = try u8At(g, p);
                    a2 = try u8At(g, p + 1);
                }
                p += 2;
            }
            var a: f32 = 1;
            var b: f32 = 0;
            var c: f32 = 0;
            var d: f32 = 1;
            const f2d14 = struct {
                fn v(x: i16) f32 {
                    return @as(f32, @floatFromInt(x)) / 16384.0;
                }
            }.v;
            if (flags & HAVE_SCALE != 0) {
                a = f2d14(try i16At(g, p));
                d = a;
                p += 2;
            } else if (flags & XY_SCALE != 0) {
                a = f2d14(try i16At(g, p));
                d = f2d14(try i16At(g, p + 2));
                p += 4;
            } else if (flags & TWO_BY_TWO != 0) {
                a = f2d14(try i16At(g, p));
                b = f2d14(try i16At(g, p + 2));
                c = f2d14(try i16At(g, p + 4));
                d = f2d14(try i16At(g, p + 6));
                p += 8;
            }

            const comp_start = buf.points.items.len;
            const ends_start = buf.ends.items.len;
            try self.decodeGlyfRec(gpa, child, buf, depth + 1);
            const pts = buf.points.items[comp_start..];
            const has_transform = a != 1 or b != 0 or c != 0 or d != 1;
            if (has_transform) {
                for (pts) |*pt| {
                    const x = pt.x;
                    const y = pt.y;
                    pt.x = a * x + c * y;
                    pt.y = b * x + d * y;
                }
            }
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & ARGS_XY != 0) {
                dx = @floatFromInt(a1);
                dy = @floatFromInt(a2);
                // FreeType: offsets are unscaled unless SCALED_COMPONENT_OFFSET is set.
                if (has_transform and flags & SCALED_OFFSET != 0 and flags & UNSCALED_OFFSET == 0) {
                    const ox = dx;
                    const oy = dy;
                    dx = a * ox + c * oy;
                    dy = b * ox + d * oy;
                }
            } else {
                // Point matching: parent point a1 (in the composite so far) aligns with child a2.
                const parent_idx = start + @as(usize, @intCast(a1));
                const child_idx = comp_start + @as(usize, @intCast(a2));
                if (parent_idx >= comp_start or child_idx >= buf.points.items.len) return error.InvalidFont;
                dx = buf.points.items[parent_idx].x - buf.points.items[child_idx].x;
                dy = buf.points.items[parent_idx].y - buf.points.items[child_idx].y;
            }
            if (dx != 0 or dy != 0) {
                for (buf.points.items[comp_start..]) |*pt| {
                    pt.x += dx;
                    pt.y += dy;
                }
            }
            _ = ends_start;
            if (flags & MORE == 0) break;
        }
    }

    /// Emits the outline of `glyph` (font units, y up) to `sink`, which must provide
    /// `moveTo(x, y)`, `lineTo(x, y)`, `quadTo(cx, cy, x, y)`, `cubicTo(c1x, c1y, c2x, c2y, x, y)`
    /// and `close()`. `buf` is retained scratch for glyf decoding.
    pub fn outline(self: *const Font, gpa: std.mem.Allocator, glyph: u32, buf: *OutlineBuffer, sink: anytype) (Error || error{OutOfMemory})!void {
        if (glyph >= self.num_glyphs) return;
        switch (self.outline_kind) {
            .none => return,
            .glyf => {
                try self.decodeGlyf(gpa, glyph, buf);
                emitQuadContours(buf, sink);
            },
            .cff => try self.cff.?.outline(glyph, sink),
        }
    }
};

/// Converts TrueType on/off-curve contours to path commands (implied on-curve midpoints).
pub fn emitQuadContours(buf: *const OutlineBuffer, sink: anytype) void {
    var start: usize = 0;
    for (buf.ends.items) |end_u| {
        const end: usize = end_u;
        if (end <= start) {
            start = end;
            continue;
        }
        const pts = buf.points.items[start..end];
        start = end;
        if (pts.len < 2) continue;
        // Find a start point: first on-curve, or midpoint of first two off-curve points.
        var first: Point = undefined;
        var first_idx: usize = 0;
        if (pts[0].on) {
            first = pts[0];
            first_idx = 1;
        } else if (pts[pts.len - 1].on) {
            first = pts[pts.len - 1];
            first_idx = 0;
        } else {
            first = .{ .x = (pts[0].x + pts[pts.len - 1].x) * 0.5, .y = (pts[0].y + pts[pts.len - 1].y) * 0.5, .on = true };
            first_idx = 0;
        }
        sink.moveTo(first.x, first.y);
        var ctrl: ?Point = null;
        const count = pts.len;
        var k: usize = 0;
        // Walk all points after `first` around the ring, ending back at `first`.
        const total = if (pts[0].on) count - 1 else if (pts[pts.len - 1].on) count - 1 else count;
        while (k < total) : (k += 1) {
            const pt = pts[(first_idx + k) % count];
            if (pt.on) {
                if (ctrl) |cp| {
                    sink.quadTo(cp.x, cp.y, pt.x, pt.y);
                    ctrl = null;
                } else sink.lineTo(pt.x, pt.y);
            } else {
                if (ctrl) |cp| {
                    const mx = (cp.x + pt.x) * 0.5;
                    const my = (cp.y + pt.y) * 0.5;
                    sink.quadTo(cp.x, cp.y, mx, my);
                }
                ctrl = pt;
            }
        }
        if (ctrl) |cp| sink.quadTo(cp.x, cp.y, first.x, first.y) else sink.lineTo(first.x, first.y);
        sink.close();
    }
}

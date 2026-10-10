//! OpenType layout subset: legacy `kern` format 0, GPOS pair adjustment (lookup type 2, formats 1
//! and 2, through extension lookups type 9) selected via the `kern` feature, and GSUB single (1)
//! and ligature (4) substitution (through extension type 7) selected via `liga`/`clig`/`rlig`.
//!
//! Lookups are resolved once at load (script DFLT -> latn -> first, default LangSys). Every
//! query re-validates offsets with checked reads, so malformed tables degrade to "no adjustment".

const std = @import("std");
const sfnt = @import("sfnt.zig");
const u16At = sfnt.u16At;
const i16At = sfnt.i16At;
const u32At = sfnt.u32At;
const Error = sfnt.Error;

pub const max_lookups = 32;

// ---------------------------------------------------------------------------------------------
// legacy kern

pub fn kernTableLookup(t: []const u8, left: u32, right: u32) i32 {
    if (t.len < 4 or left > 0xFFFF or right > 0xFFFF) return 0;
    const version = u16At(t, 0) catch return 0;
    var n_tables: u32 = undefined;
    var off: usize = undefined;
    var apple = false;
    if (version == 0) {
        n_tables = u16At(t, 2) catch return 0;
        off = 4;
    } else if (version == 1) {
        // Apple 'kern' (version as Fixed 1.0).
        n_tables = u32At(t, 4) catch return 0;
        off = 8;
        apple = true;
    } else return 0;
    const key = (left << 16) | right;
    var total: i32 = 0;
    var i: u32 = 0;
    while (i < n_tables and i < 64) : (i += 1) {
        var length: usize = undefined;
        var format: u8 = undefined;
        var horizontal: bool = undefined;
        var header: usize = undefined;
        if (apple) {
            length = u32At(t, off) catch return total;
            const cov = u16At(t, off + 4) catch return total;
            format = @truncate(cov);
            horizontal = cov & 0x8000 == 0 and cov & 0x2000 == 0; // not vertical, not variation
            header = 8;
        } else {
            length = u16At(t, off + 2) catch return total;
            const cov = u16At(t, off + 4) catch return total;
            format = @truncate(cov >> 8);
            // horizontal, not minimum, not cross-stream
            horizontal = cov & 0x1 != 0 and cov & 0x2 == 0 and cov & 0x4 == 0;
            header = 6;
        }
        if (format == 0 and horizontal) {
            const st = off + header;
            const n_pairs = u16At(t, st) catch return total;
            var lo: usize = 0;
            var hi: usize = n_pairs;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = st + 8 + mid * 6;
                const k = u32At(t, rec) catch return total;
                if (k < key) lo = mid + 1 else if (k > key) hi = mid else {
                    total += i16At(t, rec + 4) catch 0;
                    break;
                }
            }
        }
        // Some fonts have a bogus 16-bit length for a single large subtable; stop then.
        if (length < header or (!apple and n_tables == 1)) break;
        off += length;
    }
    return total;
}

// ---------------------------------------------------------------------------------------------
// Common tables

/// Coverage index of `glyph`, or null.
pub fn coverageIndex(t: []const u8, off: usize, glyph: u32) ?u32 {
    if (glyph > 0xFFFF) return null;
    const g: u16 = @intCast(glyph);
    const fmt = u16At(t, off) catch return null;
    const count = u16At(t, off + 2) catch return null;
    switch (fmt) {
        1 => {
            _ = sfnt.sub(t, off + 4, @as(usize, count) * 2) catch return null;
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const v = sfnt.rd16(t, off + 4 + mid * 2);
                if (v < g) lo = mid + 1 else if (v > g) hi = mid else return @intCast(mid);
            }
            return null;
        },
        2 => {
            _ = sfnt.sub(t, off + 4, @as(usize, count) * 6) catch return null;
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = off + 4 + mid * 6;
                const start = sfnt.rd16(t, rec);
                const end = sfnt.rd16(t, rec + 2);
                if (g < start) hi = mid else if (g > end) lo = mid + 1 else {
                    return @as(u32, sfnt.rd16(t, rec + 4)) + (g - start);
                }
            }
            return null;
        },
        else => return null,
    }
}

pub fn classOf(t: []const u8, off: usize, glyph: u32) u16 {
    if (glyph > 0xFFFF) return 0;
    const g: u16 = @intCast(glyph);
    const fmt = u16At(t, off) catch return 0;
    switch (fmt) {
        1 => {
            const start = u16At(t, off + 2) catch return 0;
            const count = u16At(t, off + 4) catch return 0;
            if (g < start or g - start >= count) return 0;
            return u16At(t, off + 6 + @as(usize, g - start) * 2) catch 0;
        },
        2 => {
            const count = u16At(t, off + 2) catch return 0;
            _ = sfnt.sub(t, off + 4, @as(usize, count) * 6) catch return 0;
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = off + 4 + mid * 6;
                const start = sfnt.rd16(t, rec);
                const end = sfnt.rd16(t, rec + 2);
                if (g < start) hi = mid else if (g > end) lo = mid + 1 else return sfnt.rd16(t, rec + 4);
            }
            return 0;
        },
        else => return 0,
    }
}

const LookupSet = struct {
    indices: [max_lookups]u16 = undefined,
    len: u8 = 0,

    fn add(self: *LookupSet, idx: u16) void {
        for (self.indices[0..self.len]) |v| if (v == idx) return;
        if (self.len == max_lookups) return;
        self.indices[self.len] = idx;
        self.len += 1;
    }
    fn sort(self: *LookupSet) void {
        std.mem.sort(u16, self.indices[0..self.len], {}, std.sort.asc(u16));
    }
    pub fn slice(self: *const LookupSet) []const u16 {
        return self.indices[0..self.len];
    }
};

/// Collects lookup indices for features whose tag is in `tags`, using the DFLT/latn/first
/// script's default LangSys (falls back to scanning the whole FeatureList).
fn collectLookups(t: []const u8, tags: []const sfnt.Tag) Error!LookupSet {
    const script_list: usize = try u16At(t, 4);
    const feature_list: usize = try u16At(t, 6);
    var set: LookupSet = .{};
    if (script_list == 0 or feature_list == 0) return set;
    const n_features = try u16At(t, feature_list);

    // Pick a script.
    var langsys: ?usize = null;
    if (u16At(t, script_list)) |n_scripts| {
        var chosen: ?usize = null;
        var fallback: ?usize = null;
        var i: usize = 0;
        while (i < n_scripts) : (i += 1) {
            const rec = script_list + 2 + i * 6;
            const stag = u32At(t, rec) catch break;
            const soff = u16At(t, rec + 4) catch break;
            if (fallback == null) fallback = script_list + soff;
            if (stag == sfnt.tag("DFLT")) {
                chosen = script_list + soff;
                break;
            }
            if (stag == sfnt.tag("latn")) chosen = script_list + soff;
        }
        if (chosen orelse fallback) |script| {
            const def = u16At(t, script) catch 0;
            if (def != 0) langsys = script + def;
        }
    } else |_| {}

    const Helper = struct {
        fn addFeature(tt: []const u8, fl: usize, fi: usize, tgs: []const sfnt.Tag, s: *LookupSet) void {
            const rec = fl + 2 + fi * 6;
            const ftag = u32At(tt, rec) catch return;
            var match = false;
            for (tgs) |x| match = match or x == ftag;
            if (!match) return;
            const foff = u16At(tt, rec + 4) catch return;
            const feat = fl + foff;
            const n = u16At(tt, feat + 2) catch return;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const li = u16At(tt, feat + 4 + k * 2) catch return;
                s.add(li);
            }
        }
    };

    if (langsys) |ls| {
        const required = try u16At(t, ls + 2);
        if (required != 0xFFFF and required < n_features) Helper.addFeature(t, feature_list, required, tags, &set);
        const n = try u16At(t, ls + 4);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const fi = try u16At(t, ls + 6 + k * 2);
            if (fi < n_features) Helper.addFeature(t, feature_list, fi, tags, &set);
        }
    } else {
        var fi: usize = 0;
        while (fi < n_features) : (fi += 1) Helper.addFeature(t, feature_list, fi, tags, &set);
    }
    set.sort();
    return set;
}

/// Resolved subtable offsets (absolute, within the table) for a lookup, following extensions.
const Subtables = struct {
    t: []const u8,
    lookup: usize,
    count: u16,
    flag: u16,
    kind: u16,
    ext_kind: u16,

    fn init(t: []const u8, lookup_list: usize, index: u16, ext_type: u16) ?Subtables {
        const n = u16At(t, lookup_list) catch return null;
        if (index >= n) return null;
        const loff = u16At(t, lookup_list + 2 + @as(usize, index) * 2) catch return null;
        const lookup = lookup_list + loff;
        const kind = u16At(t, lookup) catch return null;
        const flag = u16At(t, lookup + 2) catch return null;
        const count = u16At(t, lookup + 4) catch return null;
        return .{ .t = t, .lookup = lookup, .count = count, .flag = flag, .kind = kind, .ext_kind = ext_type };
    }

    /// Returns (absolute offset, effective lookup type) of subtable `i`.
    fn get(self: Subtables, i: usize) ?struct { off: usize, kind: u16 } {
        const soff = u16At(self.t, self.lookup + 6 + i * 2) catch return null;
        const st = self.lookup + soff;
        if (self.kind == self.ext_kind) {
            const fmt = u16At(self.t, st) catch return null;
            if (fmt != 1) return null;
            const kind = u16At(self.t, st + 2) catch return null;
            const ext = u32At(self.t, st + 4) catch return null;
            return .{ .off = st + ext, .kind = kind };
        }
        return .{ .off = st, .kind = self.kind };
    }
};

// ---------------------------------------------------------------------------------------------
// GPOS

pub const Gpos = struct {
    t: []const u8,
    lookup_list: usize,
    kern: LookupSet,

    pub fn init(t: []const u8) Error!Gpos {
        if (t.len < 10) return error.InvalidFont;
        const major = try u16At(t, 0);
        if (major != 1) return error.UnsupportedFont;
        return .{
            .t = t,
            .lookup_list = try u16At(t, 8),
            .kern = try collectLookups(t, &.{sfnt.tag("kern")}),
        };
    }

    pub fn hasKerning(self: *const Gpos) bool {
        return self.kern.len > 0;
    }

    /// Sum of horizontal pair adjustments (value1.XAdvance + value2.XPlacement) for the pair
    /// across all `kern` lookups, font units. Within a lookup the first matching subtable wins
    /// (HarfBuzz semantics).
    pub fn pairAdjustment(self: *const Gpos, left: u32, right: u32) i32 {
        var total: i32 = 0;
        for (self.kern.slice()) |li| {
            const subs = Subtables.init(self.t, self.lookup_list, li, 9) orelse continue;
            var i: usize = 0;
            while (i < subs.count) : (i += 1) {
                const st = subs.get(i) orelse continue;
                if (st.kind != 2) continue;
                if (pairPos(self.t, st.off, left, right)) |v| {
                    total += v;
                    break;
                }
            }
        }
        return total;
    }
};

fn valueSize(fmt: u16) usize {
    return 2 * @as(usize, @popCount(fmt));
}

/// Horizontal advance adjustment of a ValueRecord; XAdvance for the first glyph, XPlacement for
/// the second glyph (which shifts it relative to the pen; we fold it into the pen advance).
fn valueXAdvance(t: []const u8, rec: usize, fmt: u16) i32 {
    if (fmt & 0x4 == 0) return 0;
    const off = 2 * @as(usize, @popCount(fmt & 0x3));
    return i16At(t, rec + off) catch 0;
}
fn valueXPlacement(t: []const u8, rec: usize, fmt: u16) i32 {
    if (fmt & 0x1 == 0) return 0;
    return i16At(t, rec) catch 0;
}

fn pairPos(t: []const u8, st: usize, left: u32, right: u32) ?i32 {
    const fmt = u16At(t, st) catch return null;
    const cov = u16At(t, st + 2) catch return null;
    const vf1 = u16At(t, st + 4) catch return null;
    const vf2 = u16At(t, st + 6) catch return null;
    const cov_index = coverageIndex(t, st + cov, left) orelse return null;
    const s1 = valueSize(vf1);
    const s2 = valueSize(vf2);
    switch (fmt) {
        1 => {
            const n_sets = u16At(t, st + 8) catch return null;
            if (cov_index >= n_sets) return null;
            const ps_off = u16At(t, st + 10 + @as(usize, cov_index) * 2) catch return null;
            const ps = st + ps_off;
            const n = u16At(t, ps) catch return null;
            const rec_size = 2 + s1 + s2;
            _ = sfnt.sub(t, ps + 2, @as(usize, n) * rec_size) catch return null;
            if (right > 0xFFFF) return null;
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = ps + 2 + mid * rec_size;
                const second = sfnt.rd16(t, rec);
                if (second < right) lo = mid + 1 else if (second > right) hi = mid else {
                    return valueXAdvance(t, rec + 2, vf1) + valueXPlacement(t, rec + 2 + s1, vf2);
                }
            }
            return null;
        },
        2 => {
            const cd1 = u16At(t, st + 8) catch return null;
            const cd2 = u16At(t, st + 10) catch return null;
            const c1_count = u16At(t, st + 12) catch return null;
            const c2_count = u16At(t, st + 14) catch return null;
            const c1 = classOf(t, st + cd1, left);
            const c2 = classOf(t, st + cd2, right);
            if (c1 >= c1_count or c2 >= c2_count) return null;
            const rec = st + 16 + (@as(usize, c1) * c2_count + c2) * (s1 + s2);
            return valueXAdvance(t, rec, vf1) + valueXPlacement(t, rec + s1, vf2);
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------------------------
// GSUB

pub const Gsub = struct {
    t: []const u8,
    lookup_list: usize,
    liga: LookupSet,

    pub fn init(t: []const u8) Error!Gsub {
        if (t.len < 10) return error.InvalidFont;
        const major = try u16At(t, 0);
        if (major != 1) return error.UnsupportedFont;
        return .{
            .t = t,
            .lookup_list = try u16At(t, 8),
            .liga = try collectLookups(t, &.{ sfnt.tag("liga"), sfnt.tag("clig"), sfnt.tag("rlig") }),
        };
    }

    pub fn hasLigatures(self: *const Gsub) bool {
        return self.liga.len > 0;
    }

    /// True when no ligature-feature lookup (single or ligature substitution) covers `glyph`:
    /// substitution then never replaces it or starts a ligature at it, whatever follows.
    pub fn contextFree(self: *const Gsub, glyph: u32) bool {
        for (self.liga.slice()) |li| {
            const subs = Subtables.init(self.t, self.lookup_list, li, 7) orelse continue;
            var i: usize = 0;
            while (i < subs.count) : (i += 1) {
                const st = subs.get(i) orelse continue;
                if (st.kind != 1 and st.kind != 4) continue;
                const cov = u16At(self.t, st.off + 2) catch return false;
                if (coverageIndex(self.t, st.off + cov, glyph) != null) return false;
            }
        }
        return true;
    }

    /// Applies ligature-feature lookups (types 1 and 4) in lookup order over `glyphs` in place.
    /// `clusters` is kept parallel: a ligature keeps the cluster of its first component. Returns
    /// the new length.
    pub fn substitute(self: *const Gsub, glyphs: []u32, clusters: []u32) usize {
        std.debug.assert(glyphs.len == clusters.len);
        var len = glyphs.len;
        for (self.liga.slice()) |li| {
            const subs = Subtables.init(self.t, self.lookup_list, li, 7) orelse continue;
            var pos: usize = 0;
            while (pos < len) {
                var applied = false;
                var i: usize = 0;
                while (i < subs.count) : (i += 1) {
                    const st = subs.get(i) orelse continue;
                    switch (st.kind) {
                        1 => if (singleSubst(self.t, st.off, glyphs[pos])) |g| {
                            glyphs[pos] = g;
                            applied = true;
                        },
                        4 => if (ligatureSubst(self.t, st.off, glyphs[pos..len])) |m| {
                            glyphs[pos] = m.glyph;
                            const consumed = m.components;
                            // Remove components 1..consumed-1.
                            std.mem.copyForwards(u32, glyphs[pos + 1 ..], glyphs[pos + consumed .. len]);
                            std.mem.copyForwards(u32, clusters[pos + 1 ..], clusters[pos + consumed .. len]);
                            len -= consumed - 1;
                            applied = true;
                        },
                        else => {},
                    }
                    if (applied) break;
                }
                pos += 1;
            }
        }
        return len;
    }
};

fn singleSubst(t: []const u8, st: usize, glyph: u32) ?u32 {
    const fmt = u16At(t, st) catch return null;
    const cov = u16At(t, st + 2) catch return null;
    const ci = coverageIndex(t, st + cov, glyph) orelse return null;
    switch (fmt) {
        1 => {
            const delta = u16At(t, st + 4) catch return null;
            return @as(u16, @truncate(glyph)) +% delta;
        },
        2 => {
            const n = u16At(t, st + 4) catch return null;
            if (ci >= n) return null;
            return u16At(t, st + 6 + @as(usize, ci) * 2) catch null;
        },
        else => return null,
    }
}

const LigMatch = struct { glyph: u32, components: usize };

fn ligatureSubst(t: []const u8, st: usize, run: []const u32) ?LigMatch {
    const fmt = u16At(t, st) catch return null;
    if (fmt != 1) return null;
    const cov = u16At(t, st + 2) catch return null;
    const ci = coverageIndex(t, st + cov, run[0]) orelse return null;
    const n_sets = u16At(t, st + 4) catch return null;
    if (ci >= n_sets) return null;
    const set = st + (u16At(t, st + 6 + @as(usize, ci) * 2) catch return null);
    const n_ligs = u16At(t, set) catch return null;
    var k: usize = 0;
    while (k < n_ligs) : (k += 1) {
        const lig = set + (u16At(t, set + 2 + k * 2) catch return null);
        const lig_glyph = u16At(t, lig) catch return null;
        const comp_count = u16At(t, lig + 2) catch return null;
        if (comp_count == 0 or comp_count > run.len) continue;
        var ok = true;
        var c: usize = 1;
        while (c < comp_count) : (c += 1) {
            const want = u16At(t, lig + 4 + (c - 1) * 2) catch return null;
            if (run[c] != want) {
                ok = false;
                break;
            }
        }
        if (ok) return .{ .glyph = lig_glyph, .components = comp_count };
    }
    return null;
}

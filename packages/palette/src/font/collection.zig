//! Collection: owns faces, per-role fallback chains, shaping (UTF-8 -> positioned glyphs with
//! fallback, kerning, optional ligatures), a bounded shaping cache, glyph rasterization with
//! retained scratch, line metrics, and the measurement helpers components need.
//!
//! Threading: a Collection is single-threaded (it owns retained scratch buffers and caches).
//! Pointer stability: create with `create` and do not move it; `fontMetrics` hands out contexts
//! pointing into the collection.

const std = @import("std");
const api = @import("api.zig");
const sfnt = @import("sfnt.zig");
const raster = @import("raster.zig");
const SfntFace = @import("sfnt_face.zig").SfntFace;
const discovery = @import("discovery.zig");
const text_layout = @import("../text_layout.zig");

const FaceId = api.FaceId;
const GlyphId = api.GlyphId;
const Role = api.Role;
const ShapedGlyph = api.ShapedGlyph;

pub const max_chain = 16;
const n_roles = std.meta.fields(Role).len;

pub const AdvanceMode = enum {
    /// Each glyph advance is rounded to whole pixels; kerning stays fractional. Reproduces the
    /// positions the old FreeType-hinted (SDL_ttf + HarfBuzz) stack produced.
    round_glyph,
    /// Unrounded advances (true sub-pixel layout).
    fractional,
};

pub const MetricsMode = enum {
    /// Ascent/height/line skip rounded like SDL_ttf (ceil of the FreeType metrics) so line
    /// heights match the old renderer exactly.
    sdl_ttf_compat,
    /// Unrounded values.
    exact,
};

pub const RoleConfig = struct {
    kerning: bool = true,
    /// GSUB liga/clig/rlig (types 1 and 4). Off for code/mono roles: code fonts implement their
    /// ligatures with contextual `calt` tricks that we deliberately do not run.
    ligatures: bool = false,
    advance_mode: AdvanceMode = .round_glyph,
};

pub fn defaultRoleConfig(role: Role) RoleConfig {
    return switch (role) {
        .ui, .ui_bold, .prose, .prose_bold, .prose_italic, .prose_bold_italic => .{ .ligatures = true },
        else => .{},
    };
}

pub const Options = struct {
    /// Required for `Source.path` / `Source.system` and system fallback.
    io: ?std.Io = null,
    /// Environment for discovery ($XDG_*). Falls back to libc getenv when null and libc is linked.
    environ: ?*const std.process.Environ.Map = null,
    metrics_mode: MetricsMode = .sdl_ttf_compat,
    /// Byte budget of the shaping cache (two generations of half this size each).
    shape_cache_bytes: usize = 1 << 20,
    /// When a codepoint is missing from the whole role chain, look for an installed system face
    /// covering it (lazy, cached). Requires `io`.
    system_fallback: bool = false,
    /// Coverage remap applied to rasterized glyphs. 1.0 = linear coverage.
    coverage_gamma: f32 = 1.0,
    coverage_contrast: f32 = 0.0,
    discovery: discovery.Options = .{},
};

const FaceEntry = struct {
    face: api.Face,
    sfnt: ?*SfntFace,
    inv_upem: f32,
    upem: u16,
    /// head.flags bit 3: FreeType hints (and so SDL_ttf reports advances) at an integer ppem.
    int_ppem: bool,
    metrics: api.UnitMetrics,
    space_glyph: GlyphId,
    has_subst: bool,
    has_kern: bool,
};

const CpEntry = struct { face: FaceId, glyph: GlyphId };

const RoleState = struct {
    chain: [max_chain]FaceId = undefined,
    chain_len: u8 = 0,
    config: RoleConfig = .{},
    cp_cache: std.AutoHashMapUnmanaged(u21, CpEntry) = .empty,
    metrics_ctx: MetricsContext = undefined,
    /// ASCII advance fast path for `advanceAt` (see `PairTable`), a few sizes per role.
    pairs: [pair_tables]PairTable = @splat(.{}),
    pairs_next: u8 = 0,
    /// Per ASCII codepoint: 0 unknown, 1 context-free (see `api.Face.VTable.contextFree`), 2 not.
    ascii_free: [128]u8 = @splat(0),

    fn slice(self: *const RoleState) []const FaceId {
        return self.chain[0..self.chain_len];
    }
};

const cp_cache_limit = 8192;

/// `advanceAt` results for an ASCII codepoint `a` followed by ASCII `b` (column 128: no partner,
/// i.e. end of text or newline) at one size. Only pairs whose result cannot depend on later text
/// are stored: both codepoints context-free (no ligature/substitution starts at them), so the
/// value is exactly the hinted advance of `a` plus its kerning with `b`. Rows are allocated
/// lazily (516 bytes each); NaN marks a miss.
const pair_tables = 6;
const PairRow = [129]f32;
const PairTable = struct {
    size_bits: u32 = 0,
    used: bool = false,
    rows: [128]?*PairRow = @splat(null),

    fn clear(t: *PairTable, gpa: std.mem.Allocator) void {
        for (&t.rows) |*r| if (r.*) |row| {
            gpa.destroy(row);
            r.* = null;
        };
        t.used = false;
    }
};

const MetricsContext = struct { coll: *Collection, role: Role };

// ---------------------------------------------------------------------------------------------
// Shaping cache: two generations; lookups in the old generation are promoted. When the current
// generation exceeds half the budget it becomes the old one and the old one is recycled.

const ShapeKey = struct { role: u8, size_26_6: u32, hash: u64, len: u32 };
const ShapeSpan = struct { glyph_start: u32, glyph_len: u32, text_start: u32 };

const ShapeGen = struct {
    map: std.AutoHashMapUnmanaged(ShapeKey, ShapeSpan) = .empty,
    glyphs: std.ArrayList(ShapedGlyph) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn bytes(self: *const ShapeGen) usize {
        return self.glyphs.items.len * @sizeOf(ShapedGlyph) + self.text.items.len +
            self.map.count() * (@sizeOf(ShapeKey) + @sizeOf(ShapeSpan) + 1);
    }
    fn capacityBytes(self: *const ShapeGen) usize {
        return self.glyphs.capacity * @sizeOf(ShapedGlyph) + self.text.capacity +
            self.map.capacity() * (@sizeOf(ShapeKey) + @sizeOf(ShapeSpan) + 1);
    }
    fn reset(self: *ShapeGen) void {
        self.map.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.text.clearRetainingCapacity();
    }
    fn deinit(self: *ShapeGen, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
        self.glyphs.deinit(gpa);
        self.text.deinit(gpa);
    }
    fn get(self: *const ShapeGen, key: ShapeKey, text: []const u8) ?[]const ShapedGlyph {
        const span = self.map.get(key) orelse return null;
        if (!std.mem.eql(u8, self.text.items[span.text_start..][0..key.len], text)) return null;
        return self.glyphs.items[span.glyph_start..][0..span.glyph_len];
    }
};

const max_cached_text = 16 * 1024;

pub const MemoryStats = struct {
    faces: usize,
    /// Heap bytes held by faces (owned font copies + face structs).
    face_heap_bytes: usize,
    /// Bytes of font files mapped read-only (file-backed, only touched pages are resident).
    mapped_bytes: usize,
    shape_cache_bytes: usize,
    scratch_bytes: usize,
    codepoint_cache_entries: usize,

    pub fn heapTotal(self: MemoryStats) usize {
        return self.face_heap_bytes + self.shape_cache_bytes + self.scratch_bytes + self.codepoint_cache_entries * 16;
    }
};

pub const Collection = struct {
    gpa: std.mem.Allocator,
    options: Options,
    faces: std.ArrayList(FaceEntry) = .empty,
    roles: [n_roles]RoleState = undefined,
    gens: [2]ShapeGen = .{ .{}, .{} },
    cur_gen: u1 = 0,
    // Retained scratch.
    ws: raster.Workspace = .{},
    outline_buf: sfnt.OutlineBuffer = .{},
    tmp_glyphs: std.ArrayList(GlyphId) = .empty,
    tmp_clusters: std.ArrayList(u32) = .empty,
    tmp_faces: std.ArrayList(FaceId) = .empty,
    tmp_kind: std.ArrayList(GlyphKind) = .empty,
    tmp_out: std.ArrayList(ShapedGlyph) = .empty,
    lut: [256]u8 = undefined,
    sys: ?*discovery.Index = null,
    sys_faces: std.AutoHashMapUnmanaged(u64, FaceId) = .empty,
    stats: Stats = .{},

    pub const Stats = struct {
        shape_hits: u64 = 0,
        shape_misses: u64 = 0,
        rasterized: u64 = 0,
    };

    pub fn create(gpa: std.mem.Allocator, options: Options) !*Collection {
        const self = try gpa.create(Collection);
        self.* = .{ .gpa = gpa, .options = options };
        for (&self.roles, 0..) |*r, i| {
            const role: Role = @enumFromInt(i);
            r.* = .{ .config = defaultRoleConfig(role) };
            r.metrics_ctx = .{ .coll = self, .role = role };
        }
        if (options.coverage_gamma != 1.0 or options.coverage_contrast != 0) {
            self.lut = raster.buildLut(options.coverage_gamma, options.coverage_contrast);
            self.ws.lut = &self.lut;
        }
        return self;
    }

    pub fn destroy(self: *Collection) void {
        const gpa = self.gpa;
        for (self.faces.items) |e| e.face.vtable.deinit(e.face.ptr, gpa);
        self.faces.deinit(gpa);
        for (&self.roles) |*r| {
            r.cp_cache.deinit(gpa);
            for (&r.pairs) |*t| t.clear(gpa);
        }
        for (&self.gens) |*g| g.deinit(gpa);
        self.ws.deinit(gpa);
        self.outline_buf.deinit(gpa);
        self.tmp_glyphs.deinit(gpa);
        self.tmp_clusters.deinit(gpa);
        self.tmp_faces.deinit(gpa);
        self.tmp_kind.deinit(gpa);
        self.tmp_out.deinit(gpa);
        if (self.sys) |s| s.destroy();
        self.sys_faces.deinit(gpa);
        gpa.destroy(self);
    }

    // -- faces ---------------------------------------------------------------------------------

    pub fn faceCount(self: *const Collection) usize {
        return self.faces.items.len;
    }

    pub fn face(self: *const Collection, id: FaceId) api.Face {
        return self.faces.items[@intFromEnum(id)].face;
    }

    /// Direct access to the built-in sfnt face (null for custom faces).
    pub fn sfntFace(self: *const Collection, id: FaceId) ?*SfntFace {
        return self.faces.items[@intFromEnum(id)].sfnt;
    }

    pub fn addFace(self: *Collection, source: api.Source) !FaceId {
        return self.addFaceIndexed(source, 0);
    }

    /// `face_index` selects the face inside a TTC collection.
    pub fn addFaceIndexed(self: *Collection, source: api.Source, face_index: u32) !FaceId {
        if (self.faces.items.len >= std.math.maxInt(u16) - 1) return error.TooManyFaces;
        const gpa = self.gpa;
        switch (source) {
            .memory => |bytes| return self.adopt(try SfntFace.initMemory(gpa, bytes, face_index)),
            .owned_memory => |bytes| {
                const f = SfntFace.initOwned(gpa, bytes, face_index) catch |e| {
                    gpa.free(bytes);
                    return e;
                };
                return self.adopt(f);
            },
            .path => |p| {
                const io = self.options.io orelse return error.IoRequired;
                return self.adopt(try SfntFace.initPath(gpa, io, p, face_index));
            },
            .system => |q| {
                const idx = try self.systemIndex();
                const m = idx.match(q) orelse return error.FontNotFound;
                return self.adopt(try SfntFace.initPath(gpa, self.options.io.?, m.path, m.face_index));
            },
            .custom => |f| return self.adoptFace(f, null),
        }
    }

    fn adopt(self: *Collection, f: *SfntFace) !FaceId {
        errdefer f.deinit(self.gpa);
        return self.adoptFace(f.face(), f);
    }

    fn adoptFace(self: *Collection, f: api.Face, sf: ?*SfntFace) !FaceId {
        const upem = f.unitsPerEm();
        const id: FaceId = @enumFromInt(self.faces.items.len);
        const space = f.glyphIndex(' ');
        try self.faces.append(self.gpa, .{
            .face = f,
            .sfnt = sf,
            .inv_upem = 1.0 / @as(f32, @floatFromInt(@max(upem, 1))),
            .upem = @max(upem, 1),
            .int_ppem = if (sf) |s| s.font.head_flags & 8 != 0 else false,
            .metrics = f.unitMetrics(),
            .space_glyph = space,
            .has_subst = if (sf) |s| (if (s.font.gsub) |g| g.hasLigatures() else false) else f.vtable.substitute != null,
            .has_kern = if (sf) |s| s.font.hasKerning() else true,
        });
        return id;
    }

    fn systemIndex(self: *Collection) !*discovery.Index {
        if (self.sys) |s| return s;
        const io = self.options.io orelse return error.IoRequired;
        self.sys = try discovery.Index.create(self.gpa, io, self.options.environ, self.options.discovery);
        return self.sys.?;
    }

    // -- roles ---------------------------------------------------------------------------------

    pub fn setRoleChain(self: *Collection, role: Role, chain: []const FaceId) !void {
        if (chain.len > max_chain) return error.ChainTooLong;
        for (chain) |id| if (@intFromEnum(id) >= self.faces.items.len) return error.InvalidFace;
        const r = &self.roles[@intFromEnum(role)];
        @memcpy(r.chain[0..chain.len], chain);
        r.chain_len = @intCast(chain.len);
        r.cp_cache.clearRetainingCapacity();
        self.invalidateShapes();
    }

    pub fn roleChain(self: *const Collection, role: Role) []const FaceId {
        return self.roles[@intFromEnum(role)].slice();
    }

    pub fn setRoleConfig(self: *Collection, role: Role, config: RoleConfig) void {
        self.roles[@intFromEnum(role)].config = config;
        self.invalidateShapes();
    }

    pub fn roleConfig(self: *const Collection, role: Role) RoleConfig {
        return self.roles[@intFromEnum(role)].config;
    }

    fn invalidateShapes(self: *Collection) void {
        for (&self.gens) |*g| g.reset();
        // Chains/configs changed: cached advances and context-freedom may be stale (roles
        // without their own chain borrow `ui`'s, so clear every role).
        for (&self.roles) |*r| {
            for (&r.pairs) |*t| t.clear(self.gpa);
            r.ascii_free = @splat(0);
        }
    }

    /// Effective chain: the role's own, else `ui`'s, else every face in load order.
    fn chainFor(self: *const Collection, role: Role) []const FaceId {
        const own = self.roles[@intFromEnum(role)].slice();
        if (own.len > 0) return own;
        const ui = self.roles[@intFromEnum(Role.ui)].slice();
        if (ui.len > 0) return ui;
        return &.{};
    }

    fn primaryFace(self: *const Collection, role: Role) ?FaceId {
        const chain = self.chainFor(role);
        if (chain.len > 0) return chain[0];
        if (self.faces.items.len > 0) return @enumFromInt(0);
        return null;
    }

    /// Face + glyph for `cp` in `role` (fallback through the chain, cached per role).
    pub fn resolve(self: *Collection, role: Role, cp: u21) ?CpEntry {
        const rs = &self.roles[@intFromEnum(role)];
        if (rs.cp_cache.get(cp)) |e| return e;
        const e = self.resolveUncached(role, cp) orelse return null;
        if (rs.cp_cache.count() >= cp_cache_limit) rs.cp_cache.clearRetainingCapacity();
        rs.cp_cache.put(self.gpa, cp, e) catch {};
        return e;
    }

    fn resolveUncached(self: *Collection, role: Role, cp: u21) ?CpEntry {
        const chain = self.chainFor(role);
        for (chain) |id| {
            const g = self.faces.items[@intFromEnum(id)].face.glyphIndex(cp);
            if (g != 0) return .{ .face = id, .glyph = g };
        }
        if (chain.len == 0) {
            for (self.faces.items, 0..) |e, i| {
                const g = e.face.glyphIndex(cp);
                if (g != 0) return .{ .face = @enumFromInt(i), .glyph = g };
            }
        }
        if (self.options.system_fallback and cp > 0x7F) {
            if (self.systemFallback(cp)) |e| return e;
        }
        const primary = self.primaryFace(role) orelse return null;
        return .{ .face = primary, .glyph = 0 };
    }

    fn systemFallback(self: *Collection, cp: u21) ?CpEntry {
        const idx = self.systemIndex() catch return null;
        const m = idx.fallbackForCodepoint(cp) orelse return null;
        const key = std.hash.Wyhash.hash(m.face_index, m.path);
        const id = self.sys_faces.get(key) orelse blk: {
            const new_id = self.adopt(SfntFace.initPath(self.gpa, self.options.io.?, m.path, m.face_index) catch return null) catch return null;
            self.sys_faces.put(self.gpa, key, new_id) catch {};
            break :blk new_id;
        };
        const g = self.faces.items[@intFromEnum(id)].face.glyphIndex(cp);
        if (g == 0) return null;
        return .{ .face = id, .glyph = g };
    }

    // -- shaping -------------------------------------------------------------------------------

    /// Shapes `text` and appends glyphs to `out` (allocated with `gpa`). Uses the shaping cache.
    pub fn shape(self: *Collection, gpa: std.mem.Allocator, role: Role, size_px: f32, text: []const u8, out: *std.ArrayList(ShapedGlyph)) !void {
        const glyphs = try self.shapeCached(role, size_px, text);
        try out.appendSlice(gpa, glyphs);
    }

    /// Shapes `text`; the returned slice is owned by the collection and valid until the next
    /// call that shapes or mutates the collection.
    pub fn shapeCached(self: *Collection, role: Role, size_px: f32, text: []const u8) ![]const ShapedGlyph {
        if (text.len == 0) return &.{};
        const size_26_6 = api.GlyphKey.init(.invalid, 0, size_px, 0).size_26_6;
        if (text.len > max_cached_text) {
            self.tmp_out.clearRetainingCapacity();
            try self.shapeUncached(role, size_px, text, &self.tmp_out);
            return self.tmp_out.items;
        }
        const key: ShapeKey = .{
            .role = @intFromEnum(role),
            .size_26_6 = size_26_6,
            .hash = std.hash.Wyhash.hash(0x5a4e, text),
            .len = @intCast(text.len),
        };
        const cur = &self.gens[self.cur_gen];
        if (cur.get(key, text)) |g| {
            self.stats.shape_hits += 1;
            return g;
        }
        const old = &self.gens[1 - self.cur_gen];
        if (old.get(key, text)) |g| {
            self.stats.shape_hits += 1;
            return self.insertShape(key, text, g);
        }
        self.stats.shape_misses += 1;
        self.tmp_out.clearRetainingCapacity();
        try self.shapeUncached(role, size_px, text, &self.tmp_out);
        return self.insertShape(key, text, self.tmp_out.items);
    }

    fn insertShape(self: *Collection, key: ShapeKey, text: []const u8, glyphs: []const ShapedGlyph) ![]const ShapedGlyph {
        const gpa = self.gpa;
        var cur = &self.gens[self.cur_gen];
        if (cur.bytes() > self.options.shape_cache_bytes / 2) {
            self.cur_gen = 1 - self.cur_gen;
            cur = &self.gens[self.cur_gen];
            // `glyphs` may point into the generation we are about to recycle: copy first.
            self.tmp_out.clearRetainingCapacity();
            if (glyphs.ptr != self.tmp_out.items.ptr) try self.tmp_out.appendSlice(gpa, glyphs);
            cur.reset();
            return self.insertInto(cur, key, text, self.tmp_out.items);
        }
        return self.insertInto(cur, key, text, glyphs);
    }

    fn insertInto(self: *Collection, gen: *ShapeGen, key: ShapeKey, text: []const u8, glyphs: []const ShapedGlyph) ![]const ShapedGlyph {
        const gpa = self.gpa;
        const span: ShapeSpan = .{
            .glyph_start = @intCast(gen.glyphs.items.len),
            .glyph_len = @intCast(glyphs.len),
            .text_start = @intCast(gen.text.items.len),
        };
        try gen.glyphs.ensureUnusedCapacity(gpa, glyphs.len);
        try gen.text.ensureUnusedCapacity(gpa, text.len);
        try gen.map.put(gpa, key, span);
        gen.glyphs.appendSliceAssumeCapacity(glyphs);
        gen.text.appendSliceAssumeCapacity(text);
        return gen.glyphs.items[span.glyph_start..][0..span.glyph_len];
    }

    /// Shapes without consulting the cache.
    pub fn shapeUncached(self: *Collection, role: Role, size_px: f32, text: []const u8, out: *std.ArrayList(ShapedGlyph)) !void {
        const n = try self.itemize(role, text, 0, text.len);
        const len = self.substituteRuns(role, n);
        try out.ensureUnusedCapacity(self.gpa, len);
        self.position(role, size_px, len, out);
    }

    /// Decodes text[start..end] into tmp arrays (glyph, cluster, face, kind). Returns count.
    fn itemize(self: *Collection, role: Role, text: []const u8, start: usize, end: usize) !usize {
        const gpa = self.gpa;
        self.tmp_glyphs.clearRetainingCapacity();
        self.tmp_clusters.clearRetainingCapacity();
        self.tmp_faces.clearRetainingCapacity();
        self.tmp_kind.clearRetainingCapacity();
        const est = end - start;
        try self.tmp_glyphs.ensureTotalCapacity(gpa, est);
        try self.tmp_clusters.ensureTotalCapacity(gpa, est);
        try self.tmp_faces.ensureTotalCapacity(gpa, est);
        try self.tmp_kind.ensureTotalCapacity(gpa, est);
        var i = start;
        while (i < end) {
            const d = decodeUtf8(text[i..end]);
            self.appendCodepoint(role, d.cp, @intCast(i));
            i += d.len;
        }
        return self.tmp_glyphs.items.len;
    }

    fn appendCodepoint(self: *Collection, role: Role, cp_in: u21, cluster: u32) void {
        var cp = cp_in;
        var kind: GlyphKind = .normal;
        if (cp == '\t') {
            kind = .tab;
            cp = ' ';
        } else if (cp == '\r') {
            cp = ' ';
        } else if (cp < 0x20 or cp == 0x7F or isDefaultIgnorable(cp)) {
            kind = .invisible;
        }
        var e: CpEntry = .{ .face = .invalid, .glyph = api.invisible_glyph };
        if (kind != .invisible) {
            if (self.resolve(role, cp)) |r| e = r else kind = .invisible;
        }
        if (kind == .invisible) {
            // Attach to the previous face so kerning/ligature runs are not broken needlessly.
            e.face = if (self.tmp_faces.items.len > 0) self.tmp_faces.items[self.tmp_faces.items.len - 1] else (self.primaryFace(role) orelse .invalid);
            e.glyph = api.invisible_glyph;
        }
        self.tmp_glyphs.appendAssumeCapacity(e.glyph);
        self.tmp_clusters.appendAssumeCapacity(cluster);
        self.tmp_faces.appendAssumeCapacity(e.face);
        self.tmp_kind.appendAssumeCapacity(kind);
    }

    /// Runs GSUB per same-face run when the role enables ligatures; compacts tmp arrays.
    fn substituteRuns(self: *Collection, role: Role, n: usize) usize {
        if (!self.roles[@intFromEnum(role)].config.ligatures) return n;
        const glyphs = self.tmp_glyphs.items;
        const clusters = self.tmp_clusters.items;
        const faces = self.tmp_faces.items;
        const kinds = self.tmp_kind.items;
        var w: usize = 0; // write cursor
        var r: usize = 0; // read cursor
        while (r < n) {
            // Run of normal glyphs from the same face.
            var e = r + 1;
            if (kinds[r] == .normal) {
                while (e < n and kinds[e] == .normal and faces[e] == faces[r]) e += 1;
            }
            var run_len = e - r;
            if (run_len > 1 and kinds[r] == .normal and faces[r] != .invalid) {
                const fe = &self.faces.items[@intFromEnum(faces[r])];
                if (fe.has_subst) {
                    if (fe.face.vtable.substitute) |subst| {
                        run_len = subst(fe.face.ptr, glyphs[r..e], clusters[r..e]);
                    }
                }
            }
            if (w != r) {
                std.mem.copyForwards(GlyphId, glyphs[w..], glyphs[r..][0..run_len]);
                std.mem.copyForwards(u32, clusters[w..], clusters[r..][0..run_len]);
                std.mem.copyForwards(FaceId, faces[w..], faces[r..][0..run_len]);
                std.mem.copyForwards(GlyphKind, kinds[w..], kinds[r..][0..run_len]);
            }
            w += run_len;
            r = e;
        }
        return w;
    }

    /// Computes advances for tmp[0..n] and appends ShapedGlyphs to `out` (capacity reserved).
    fn position(self: *Collection, role: Role, size_px: f32, n: usize, out: *std.ArrayList(ShapedGlyph)) void {
        const cfg = self.roles[@intFromEnum(role)].config;
        const glyphs = self.tmp_glyphs.items;
        const faces = self.tmp_faces.items;
        const kinds = self.tmp_kind.items;
        for (0..n) |k| {
            var adv: f32 = 0;
            const fid = faces[k];
            if (kinds[k] != .invisible and fid != .invalid) {
                const fe = &self.faces.items[@intFromEnum(fid)];
                const scale = size_px * fe.inv_upem;
                const units = fe.face.advance(glyphs[k]);
                if (cfg.advance_mode == .round_glyph) {
                    adv = hintedAdvance(units, size_px, fe.upem, fe.int_ppem);
                } else {
                    adv = @as(f32, @floatFromInt(units)) * scale;
                }
                if (kinds[k] == .tab) adv *= 4;
                if (cfg.kerning and fe.has_kern and k + 1 < n and faces[k + 1] == fid and kinds[k + 1] == .normal and kinds[k] == .normal) {
                    const kern = fe.face.kerning(glyphs[k], glyphs[k + 1]);
                    if (kern != 0) adv += quantize26_6(@as(f32, @floatFromInt(kern)) * scale);
                }
            }
            out.appendAssumeCapacity(.{
                .face = fid,
                .glyph = glyphs[k],
                .x_advance = adv,
                .cluster = self.tmp_clusters.items[k],
            });
        }
    }

    // -- rasterization -------------------------------------------------------------------------

    /// Rasterizes a glyph. Bitmap pixels come from `scratch`; temporaries use retained buffers.
    pub fn rasterize(self: *Collection, key: api.GlyphKey, scratch: std.mem.Allocator) !api.Bitmap {
        if (@intFromEnum(key.face) >= self.faces.items.len or key.glyph == api.invisible_glyph) return .{};
        const fe = &self.faces.items[@intFromEnum(key.face)];
        self.stats.rasterized += 1;
        if (fe.sfnt) |sf| {
            return sf.rasterizeInto(self.gpa, &self.ws, &self.outline_buf, key.glyph, key.sizePx(), key.subpixel_x, scratch);
        }
        return fe.face.rasterize(key.glyph, key.sizePx(), key.subpixel_x, scratch);
    }

    // -- metrics -------------------------------------------------------------------------------

    pub fn lineMetrics(self: *const Collection, role: Role, size_px: f32) api.LineMetrics {
        const id = self.primaryFace(role) orelse return .{ .ascent = size_px * 0.8, .descent = size_px * 0.2 };
        const fe = &self.faces.items[@intFromEnum(id)];
        const s = size_px * fe.inv_upem;
        const m = fe.metrics;
        const asc = @as(f32, @floatFromInt(m.ascent)) * s;
        const desc = @as(f32, @floatFromInt(m.descent)) * s;
        const gap = @as(f32, @floatFromInt(m.line_gap)) * s;
        var lm: api.LineMetrics = .{
            .ascent = asc,
            .descent = desc,
            .line_gap = gap,
            .underline_position = -@as(f32, @floatFromInt(m.underline_position)) * s,
            .underline_thickness = @max(@as(f32, @floatFromInt(m.underline_thickness)) * s, 1),
            .average_advance = @as(f32, @floatFromInt(m.average_advance)) * s,
        };
        if (self.options.metrics_mode == .sdl_ttf_compat) {
            // SDL_ttf: ascent = FT_CEIL(FT_MulFix(asc, scale)), descent = FT_CEIL(-desc),
            // height = FT_CEIL(asc + desc), lineskip = FT_CEIL(asc + desc + gap), all in 26.6
            // with the requested (unrounded) size. ascent/descent match SDL exactly; line_gap
            // absorbs the remainder so lineHeight() == lineskip.
            const a = ftCeil(ftScale(m.ascent, size_px, fe.upem));
            const d = -ftCeil(-ftScale(m.descent, size_px, fe.upem));
            const skip = ftCeil(ftScale(m.ascent + m.descent + m.line_gap, size_px, fe.upem));
            lm.ascent = a;
            lm.descent = d;
            lm.line_gap = skip - a - d;
            lm.underline_position = @round(lm.underline_position);
            lm.underline_thickness = @max(@round(lm.underline_thickness), 1);
            if (self.roles[@intFromEnum(role)].config.advance_mode == .round_glyph) lm.average_advance = @round(lm.average_advance);
        }
        return lm;
    }

    /// Ink box of the glyph `cp` resolves to in `role` at `size_px`, as
    /// `{ min_x, max_x, min_y, max_y }` in whole device px relative to the pen origin on the
    /// baseline, y up (SDL_ttf `TTF_GetGlyphMetrics` order and convention: mins floored, maxes
    /// ceiled from the 26.6-scaled outline box). Null when the glyph has no outline (space)
    /// or the face cannot report bounds.
    pub fn glyphInk(self: *Collection, role: Role, size_px: f32, cp: u21) ?[4]f32 {
        const e = self.resolve(role, cp) orelse return null;
        const fe = &self.faces.items[@intFromEnum(e.face)];
        const f = fe.face.vtable.glyphBounds orelse return null;
        const b = f(fe.face.ptr, e.glyph) orelse return null;
        if (b.x_max <= b.x_min or b.y_max <= b.y_min) return null;
        return .{
            ftFloor(ftScale(b.x_min, size_px, fe.upem)),
            ftCeil(ftScale(b.x_max, size_px, fe.upem)),
            ftFloor(ftScale(b.y_min, size_px, fe.upem)),
            ftCeil(ftScale(b.y_max, size_px, fe.upem)),
        };
    }

    /// Pen advance sum of `text` (no ink/whitespace special cases).
    pub fn advanceWidth(self: *Collection, role: Role, size_px: f32, text: []const u8) !f32 {
        const glyphs = try self.shapeCached(role, size_px, text);
        var w: f32 = 0;
        for (glyphs) |g| w += g.x_advance;
        return w;
    }

    /// Width of `text` (the pen position after the last glyph). The old SDL renderer returned
    /// the ink right edge for text that does not end in whitespace; we return the advance-based
    /// pen position, which differs by the last glyph's right side bearing (< ~1 px at UI sizes)
    /// and is what caret placement needs.
    pub fn measureText(self: *Collection, role: Role, size_px: f32, text: []const u8) !f32 {
        return self.advanceWidth(role, size_px, text);
    }

    /// Pen x at the start of the cluster containing `byte_offset` (== measureText for offsets at
    /// or past the end). Offsets inside a ligature or multi-byte sequence snap to its start.
    pub fn measureTextOffset(self: *Collection, role: Role, size_px: f32, text: []const u8, byte_offset: usize) !f32 {
        const end = @min(byte_offset, text.len);
        if (end == 0) return 0;
        const glyphs = try self.shapeCached(role, size_px, text);
        var pen: f32 = 0;
        for (glyphs, 0..) |g, i| {
            const next: usize = if (i + 1 < glyphs.len) glyphs[i + 1].cluster else text.len;
            if (next > end) break;
            pen += g.x_advance;
        }
        return pen;
    }

    /// One advance per byte: `out[i]` is the advance of the cluster starting at byte i, 0 for
    /// continuation bytes and for components folded into a ligature. `out.len == text.len`.
    pub fn glyphAdvances(self: *Collection, role: Role, size_px: f32, text: []const u8, out: []f32) !void {
        std.debug.assert(out.len == text.len);
        @memset(out, 0);
        if (text.len == 0) return;
        const glyphs = try self.shapeCached(role, size_px, text);
        for (glyphs) |g| out[g.cluster] += g.x_advance;
    }

    /// `text_layout.FontMetrics` backed by this collection for `role`. The context pointer is
    /// stable for the collection's lifetime. Advances honour fallback, kerning and ligatures
    /// identically to `shape`, evaluated locally (O(1) per call).
    pub fn fontMetrics(self: *Collection, role: Role, size_px: f32) text_layout.FontMetrics {
        const lm = self.lineMetrics(role, size_px);
        const rs = &self.roles[@intFromEnum(role)];
        var fixed: ?f32 = null;
        if (self.primaryFace(role)) |id| {
            const fe = &self.faces.items[@intFromEnum(id)];
            if (fe.metrics.is_fixed_pitch) fixed = lm.average_advance;
        }
        return .{
            .font_size = size_px,
            .line_height = lm.lineHeight(),
            .fixed_advance = fixed,
            .ascent = lm.ascent,
            .descent = lm.descent,
            .baseline = lm.ascent,
            .context = &rs.metrics_ctx,
            .advance = advanceCallback,
        };
    }

    fn advanceCallback(context: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) text_layout.Advance {
        const ctx: *MetricsContext = @ptrCast(@alignCast(context.?));
        return ctx.coll.advanceAt(ctx.role, font_size, text, byte_offset);
    }

    /// Advance of the cluster starting at `byte_offset` in the context of `text` (kerning with
    /// the following glyph; a ligature starting here is consumed whole).
    pub fn advanceAt(self: *Collection, role: Role, size_px: f32, text: []const u8, byte_offset: usize) text_layout.Advance {
        if (byte_offset >= text.len) return .{ .byte_len = 0, .width = 0 };
        // ASCII fast path: O(1) table lookup, exact (see PairTable).
        const a = text[byte_offset];
        var pair_row: ?*PairRow = null;
        var pair_col: usize = 0;
        if (a < 0x80) {
            const nb = byte_offset + 1;
            pair_col = if (nb >= text.len or text[nb] == '\n') 128 else text[nb];
            if (pair_col <= 128) {
                if (self.pairRow(role, size_px, a)) |row| {
                    const w = row[pair_col];
                    if (!std.math.isNan(w)) return .{ .byte_len = 1, .width = w };
                    if (self.asciiContextFree(role, a) and (pair_col == 128 or self.asciiContextFree(role, @intCast(pair_col)))) pair_row = row;
                }
            }
        }
        const r = self.advanceAtUncached(role, size_px, text, byte_offset);
        if (pair_row) |row| {
            if (r.byte_len == 1) row[pair_col] = r.width;
        }
        return r;
    }

    /// Row of the pair table for (`role`, `size_px`, first codepoint `a`), allocating it (and
    /// recycling the oldest size's table) on demand. Null on allocation failure.
    fn pairRow(self: *Collection, role: Role, size_px: f32, a: u8) ?*PairRow {
        const rs = &self.roles[@intFromEnum(role)];
        const bits: u32 = @bitCast(size_px);
        const t: *PairTable = for (&rs.pairs) |*t| {
            if (t.used and t.size_bits == bits) break t;
        } else blk: {
            const victim = &rs.pairs[rs.pairs_next];
            rs.pairs_next = @intCast((rs.pairs_next + 1) % pair_tables);
            victim.clear(self.gpa);
            victim.used = true;
            victim.size_bits = bits;
            break :blk victim;
        };
        if (t.rows[a]) |row| return row;
        const row = self.gpa.create(PairRow) catch return null;
        row.* = @splat(std.math.nan(f32));
        t.rows[a] = row;
        return row;
    }

    fn asciiContextFree(self: *Collection, role: Role, cp: u8) bool {
        const rs = &self.roles[@intFromEnum(role)];
        if (rs.ascii_free[cp] == 0) {
            rs.ascii_free[cp] = if (self.computeContextFree(role, cp)) 1 else 2;
        }
        return rs.ascii_free[cp] == 1;
    }

    fn computeContextFree(self: *Collection, role: Role, cp: u8) bool {
        if (!self.roles[@intFromEnum(role)].config.ligatures) return true;
        if (cp < 0x20 and cp != '\t' and cp != '\r') return true; // invisible
        if (cp == 0x7F) return true;
        const mapped: u21 = if (cp == '\t' or cp == '\r') ' ' else cp;
        const e = self.resolve(role, mapped) orelse return true;
        if (e.face == .invalid) return true;
        const fe = &self.faces.items[@intFromEnum(e.face)];
        if (!fe.has_subst) return true;
        if (fe.face.vtable.substitute == null) return true;
        const f = fe.face.vtable.contextFree orelse return false;
        return f(fe.face.ptr, e.glyph);
    }

    pub fn advanceAtUncached(self: *Collection, role: Role, size_px: f32, text: []const u8, byte_offset: usize) text_layout.Advance {
        // Window: the codepoint + its kerning partner, or (ligatures on) enough codepoints for
        // the longest common ligature (ffl/ffi) + a kerning partner.
        const window_cps: usize = if (self.roles[@intFromEnum(role)].config.ligatures) 4 else 2;
        var end = byte_offset;
        var cps: usize = 0;
        while (end < text.len and cps < window_cps) : (cps += 1) {
            if (text[end] == '\n' and end > byte_offset) break;
            end += decodeUtf8(text[end..]).len;
        }
        const n = self.itemize(role, text, byte_offset, end) catch {
            const l = decodeUtf8(text[byte_offset..]).len;
            return .{ .byte_len = l, .width = 0 };
        };
        const len = self.substituteRuns(role, n);
        const adv = self.positionFirst(role, size_px, len);
        const next: usize = if (len > 1) self.tmp_clusters.items[1] else end;
        return .{ .byte_len = @max(next - byte_offset, 1), .width = adv };
    }

    fn positionFirst(self: *Collection, role: Role, size_px: f32, n: usize) f32 {
        if (n == 0) return 0;
        var buf: [2]ShapedGlyph = undefined;
        var list: std.ArrayList(ShapedGlyph) = .initBuffer(&buf);
        self.position(role, size_px, @min(n, 2), &list);
        return buf[0].x_advance;
    }

    pub fn memoryStats(self: *const Collection) MemoryStats {
        var heap: usize = self.faces.capacity * @sizeOf(FaceEntry);
        var mapped: usize = 0;
        for (self.faces.items) |e| {
            if (e.sfnt) |s| {
                heap += s.heapBytes();
                mapped += s.mappedBytes();
            }
        }
        var cp_entries: usize = 0;
        for (&self.roles) |*r| cp_entries += r.cp_cache.capacity();
        return .{
            .faces = self.faces.items.len,
            .face_heap_bytes = heap,
            .mapped_bytes = mapped,
            .shape_cache_bytes = self.gens[0].capacityBytes() + self.gens[1].capacityBytes(),
            .scratch_bytes = self.ws.memoryUsed() + self.outline_buf.points.capacity * @sizeOf(sfnt.Point) +
                self.outline_buf.ends.capacity * 4 + self.tmp_glyphs.capacity * 4 + self.tmp_clusters.capacity * 4 +
                self.tmp_faces.capacity * 2 + self.tmp_kind.capacity + self.tmp_out.capacity * @sizeOf(ShapedGlyph),
            .codepoint_cache_entries = cp_entries,
        };
    }
};

const GlyphKind = enum(u8) { normal, tab, invisible };

inline fn quantize26_6(v: f32) f32 {
    return @round(v * 64.0) / 64.0;
}

/// FT_MulFix(units, scale) with scale derived from the 26.6 char size SDL_ttf requests
/// (round(size * 64)); result in 26.6.
fn ftScale(units: i32, size_px: f32, upem: u16) i64 {
    const size26: i64 = @intFromFloat(@round(@max(size_px, 0) * 64.0));
    const num = @as(i64, units) * size26;
    const half: i64 = @divTrunc(upem, 2);
    return if (num >= 0) @divFloor(num + half, upem) else -@divFloor(-num + half, upem);
}

fn ftFloor(v26: i64) f32 {
    return @floatFromInt(@divFloor(v26, 64));
}

fn ftCeil(v26: i64) f32 {
    return @floatFromInt(@divFloor(v26 + 63, 64));
}

/// The advance FreeType reports with hinting enabled: the 26.6-scaled advance rounded to whole
/// pixels; fonts with head.flags bit 3 are scaled at the rounded integer ppem.
pub fn hintedAdvance(units: i32, size_px: f32, upem: u16, int_ppem: bool) f32 {
    const size = if (int_ppem) @max(@round(size_px), 1) else size_px;
    const v = ftScale(units, size, upem);
    return @floatFromInt(@divFloor(v + 32, 64));
}

pub const Decoded = struct { cp: u21, len: u3 };

/// Decodes one UTF-8 sequence; invalid/truncated/overlong/surrogate sequences decode as U+FFFD
/// consuming one byte. `s` must be non-empty.
pub fn decodeUtf8(s: []const u8) Decoded {
    const b0 = s[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const bad: Decoded = .{ .cp = 0xFFFD, .len = 1 };
    if (b0 < 0xC2) return bad;
    if (b0 < 0xE0) {
        if (s.len < 2 or s[1] & 0xC0 != 0x80) return bad;
        return .{ .cp = (@as(u21, b0 & 0x1F) << 6) | (s[1] & 0x3F), .len = 2 };
    }
    if (b0 < 0xF0) {
        if (s.len < 3 or s[1] & 0xC0 != 0x80 or s[2] & 0xC0 != 0x80) return bad;
        const cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, s[1] & 0x3F) << 6) | (s[2] & 0x3F);
        if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF)) return bad;
        return .{ .cp = cp, .len = 3 };
    }
    if (b0 < 0xF5) {
        if (s.len < 4 or s[1] & 0xC0 != 0x80 or s[2] & 0xC0 != 0x80 or s[3] & 0xC0 != 0x80) return bad;
        const cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, s[1] & 0x3F) << 12) | (@as(u21, s[2] & 0x3F) << 6) | (s[3] & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) return bad;
        return .{ .cp = cp, .len = 4 };
    }
    return bad;
}

/// Unicode Default_Ignorable_Code_Point (rendered as nothing, zero advance).
pub fn isDefaultIgnorable(cp: u21) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFEFF, 0xFFA0 => true,
        0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F => true,
        0xFE00...0xFE0F, 0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF => true,
        else => false,
    };
}

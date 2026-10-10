//! The built-in `api.Face` implementation backed by the pure-Zig sfnt parser + rasterizer.
//! Owns (or borrows) the font bytes: borrowed memory, owned heap memory, or a read-only
//! MAP_PRIVATE file mapping.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const sfnt = @import("sfnt.zig");
const raster = @import("raster.zig");

pub const Storage = union(enum) {
    borrowed,
    owned: []u8,
    mapped: []align(std.heap.page_size_min) const u8,
};

pub const LoadError = sfnt.Error || std.mem.Allocator.Error || error{ FileTooLarge, FileTooSmall } ||
    std.Io.File.OpenError || std.Io.File.LengthError || std.Io.File.ReadPositionalError || std.posix.MMapError;

pub const SfntFace = struct {
    font: sfnt.Font,
    storage: Storage,
    /// Bytes of the font file (mapped bytes are mostly not resident; see `memory`).
    data_len: usize,

    pub fn initMemory(gpa: std.mem.Allocator, data: []const u8, face_index: u32) LoadError!*SfntFace {
        const self = try gpa.create(SfntFace);
        errdefer gpa.destroy(self);
        self.* = .{ .font = try sfnt.Font.init(data, face_index), .storage = .borrowed, .data_len = data.len };
        return self;
    }

    /// Takes ownership of `data` (freed with `gpa`) only on success.
    pub fn initOwned(gpa: std.mem.Allocator, data: []u8, face_index: u32) LoadError!*SfntFace {
        const self = try gpa.create(SfntFace);
        errdefer gpa.destroy(self);
        self.* = .{ .font = try sfnt.Font.init(data, face_index), .storage = .{ .owned = data }, .data_len = data.len };
        return self;
    }

    /// Maps `path` read-only (MAP_PRIVATE) on POSIX; reads it into memory elsewhere.
    pub fn initPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8, face_index: u32) LoadError!*SfntFace {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const len64 = try file.length(io);
        if (len64 < 12) return error.FileTooSmall;
        if (len64 > 1 << 31) return error.FileTooLarge;
        const len: usize = @intCast(len64);
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            const mem = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
            errdefer std.posix.munmap(mem);
            const self = try gpa.create(SfntFace);
            errdefer gpa.destroy(self);
            self.* = .{ .font = try sfnt.Font.init(mem, face_index), .storage = .{ .mapped = mem }, .data_len = len };
            return self;
        } else {
            const buf = try gpa.alloc(u8, len);
            errdefer gpa.free(buf);
            const n = try file.readPositionalAll(io, buf, 0);
            if (n != len) return error.FileTooSmall;
            return initOwned(gpa, buf, face_index);
        }
    }

    pub fn deinit(self: *SfntFace, gpa: std.mem.Allocator) void {
        switch (self.storage) {
            .borrowed => {},
            .owned => |b| gpa.free(b),
            .mapped => |m| if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) std.posix.munmap(m) else unreachable,
        }
        gpa.destroy(self);
    }

    /// Heap bytes attributable to this face (owned copies count fully; mappings count 0 heap,
    /// their resident size is reported separately by the OS as file-backed, reclaimable pages).
    pub fn heapBytes(self: *const SfntFace) usize {
        return @sizeOf(SfntFace) + switch (self.storage) {
            .owned => |b| b.len,
            else => 0,
        };
    }

    pub fn mappedBytes(self: *const SfntFace) usize {
        return switch (self.storage) {
            .mapped => |m| m.len,
            else => 0,
        };
    }

    pub fn unitMetrics(self: *const SfntFace) api.UnitMetrics {
        const f = &self.font;
        const v = f.vMetrics();
        var avg: i32 = f.os2.avg_char_width;
        const zero = f.glyphIndex('0');
        if (zero != 0) avg = f.advance(zero);
        return .{
            .ascent = v.ascent,
            .descent = v.descent,
            .line_gap = v.line_gap,
            .underline_position = f.post.underline_position,
            .underline_thickness = f.post.underline_thickness,
            .average_advance = avg,
            .is_fixed_pitch = f.isFixedPitch(),
        };
    }

    /// Rasterizes with caller-retained buffers (no allocation in steady state except `out`).
    pub fn rasterizeInto(
        self: *const SfntFace,
        gpa: std.mem.Allocator,
        ws: *raster.Workspace,
        outline_buf: *sfnt.OutlineBuffer,
        glyph: api.GlyphId,
        size_px: f32,
        subpixel_x: u8,
        out: std.mem.Allocator,
    ) !api.Bitmap {
        if (!(size_px > 0) or size_px > 4096) return .{};
        const scale = size_px / @as(f32, @floatFromInt(self.font.units_per_em));
        const shift = @as(f32, @floatFromInt(subpixel_x % api.subpixel_steps)) / @as(f32, @floatFromInt(api.subpixel_steps));
        var fl = ws.begin(gpa, scale, shift);
        try self.font.outline(gpa, glyph, outline_buf, &fl);
        return ws.finish(gpa, &fl, out);
    }

    // -- vtable --------------------------------------------------------------------------------

    pub fn face(self: *SfntFace) api.Face {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub const vtable: api.Face.VTable = .{
        .glyphIndex = vGlyphIndex,
        .advance = vAdvance,
        .kerning = vKerning,
        .unitsPerEm = vUnitsPerEm,
        .unitMetrics = vUnitMetrics,
        .rasterize = vRasterize,
        .substitute = vSubstitute,
        .contextFree = vContextFree,
        .glyphBounds = vGlyphBounds,
        .deinit = vDeinit,
    };

    fn cast(ptr: *anyopaque) *SfntFace {
        return @ptrCast(@alignCast(ptr));
    }
    fn vGlyphIndex(ptr: *anyopaque, cp: u21) api.GlyphId {
        return cast(ptr).font.glyphIndex(cp);
    }
    fn vAdvance(ptr: *anyopaque, g: api.GlyphId) i32 {
        return cast(ptr).font.advance(g);
    }
    fn vKerning(ptr: *anyopaque, l: api.GlyphId, r: api.GlyphId) i32 {
        return cast(ptr).font.kerning(l, r);
    }
    fn vUnitsPerEm(ptr: *anyopaque) u16 {
        return cast(ptr).font.units_per_em;
    }
    fn vUnitMetrics(ptr: *anyopaque) api.UnitMetrics {
        return cast(ptr).unitMetrics();
    }
    fn vGlyphBounds(ptr: *anyopaque, g: api.GlyphId) ?api.GlyphBounds {
        const b = cast(ptr).font.glyphBox(g) orelse return null;
        return .{ .x_min = b.x_min, .y_min = b.y_min, .x_max = b.x_max, .y_max = b.y_max };
    }
    fn vRasterize(ptr: *anyopaque, g: api.GlyphId, size_px: f32, subpixel_x: u8, scratch: std.mem.Allocator) anyerror!api.Bitmap {
        // Generic path: temporary buffers from `scratch`, released before returning (only the
        // bitmap stays). Collection uses `rasterizeInto` with retained buffers instead.
        var ws: raster.Workspace = .{};
        defer ws.deinit(scratch);
        var ob: sfnt.OutlineBuffer = .{};
        defer ob.deinit(scratch);
        return cast(ptr).rasterizeInto(scratch, &ws, &ob, g, size_px, subpixel_x, scratch);
    }
    fn vSubstitute(ptr: *anyopaque, glyphs: []api.GlyphId, clusters: []u32) usize {
        const f = &cast(ptr).font;
        if (f.gsub) |*g| if (g.hasLigatures()) return g.substitute(glyphs, clusters);
        return glyphs.len;
    }
    fn vContextFree(ptr: *anyopaque, g: api.GlyphId) bool {
        const f = &cast(ptr).font;
        if (f.gsub) |*gs| if (gs.hasLigatures()) return gs.contextFree(g);
        return true;
    }
    fn vDeinit(ptr: *anyopaque, gpa: std.mem.Allocator) void {
        cast(ptr).deinit(gpa);
    }
};

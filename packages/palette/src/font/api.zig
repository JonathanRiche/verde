//! Font system contract shared by the text engine (src/font) and the GPU renderer (src/gpu).
//!
//! Palette ships a pure-Zig sfnt (TrueType/OpenType) backend, but the `Face` vtable lets other
//! apps plug in their own implementation (FreeType, CoreText, a bitmap font, ...). Everything
//! here is in *device pixels* unless stated otherwise.
//!
//! STATUS: contract. Implementations live in src/font/*.zig. Changing these types requires
//! updating both the font engine and the GPU glyph cache.
//!
//! Compatible extensions made by the font workstream (no existing field/type changed):
//! - `invisible_glyph`: sentinel glyph id for zero-width, non-rendering clusters (controls,
//!   default-ignorables like ZWJ / variation selectors). Renderers must skip it.
//! - `GlyphBounds` + optional `VTable.glyphBounds` (ink box in font units) used to reproduce the
//!   old renderer's "ink right edge" measurement semantics. Defaults to null.

const std = @import("std");
const draw = @import("../draw.zig");

/// Index of a face inside a `Collection` (see collection.zig).
pub const FaceId = enum(u16) { invalid = std.math.maxInt(u16), _ };

pub const GlyphId = u32;

/// Glyph id used in `ShapedGlyph` for zero-width clusters that must not be drawn.
pub const invisible_glyph: GlyphId = std.math.maxInt(u32);

/// Ink bounding box in font units (y up).
pub const GlyphBounds = struct { x_min: i32, y_min: i32, x_max: i32, y_max: i32 };

/// Number of horizontal sub-pixel positions glyphs are rasterized at. 4 matches Zed/GPUI and
/// keeps text crisp at fractional scales without exploding the atlas.
pub const subpixel_steps: u8 = 4;

/// Cache key for one rasterized glyph image.
pub const GlyphKey = struct {
    face: FaceId,
    glyph: GlyphId,
    /// Pixel size in 1/64 px (26.6 fixed point) so 13.5 px and 13.25 px are distinct.
    size_26_6: u32,
    /// Horizontal sub-pixel bucket in [0, subpixel_steps).
    subpixel_x: u8 = 0,

    pub fn init(face: FaceId, glyph: GlyphId, size_px: f32, subpixel_x: u8) GlyphKey {
        return .{
            .face = face,
            .glyph = glyph,
            .size_26_6 = @intFromFloat(@round(@max(size_px, 0) * 64.0)),
            .subpixel_x = subpixel_x,
        };
    }

    pub fn sizePx(self: GlyphKey) f32 {
        return @as(f32, @floatFromInt(self.size_26_6)) / 64.0;
    }

    pub fn hash(self: GlyphKey) u64 {
        var h = std.hash.Wyhash.init(0x9a1e77e);
        h.update(std.mem.asBytes(&self.face));
        h.update(std.mem.asBytes(&self.glyph));
        h.update(std.mem.asBytes(&self.size_26_6));
        h.update(std.mem.asBytes(&self.subpixel_x));
        return h.final();
    }
};

pub const BitmapFormat = enum(u8) {
    /// 8-bit coverage, one byte per pixel.
    coverage8,
    /// Premultiplied RGBA8 (color emoji / COLR / bitmap fonts).
    rgba8_premul,
};

/// A rasterized glyph. `pixels` is owned by the caller-provided allocator/scratch passed to
/// `rasterize` and is only valid until the next rasterize call on that scratch.
pub const Bitmap = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Offset from the pen position (on the baseline) to the bitmap's left edge, in px.
    left: i32 = 0,
    /// Offset from the baseline UP to the bitmap's top edge, in px (FreeType convention).
    top: i32 = 0,
    format: BitmapFormat = .coverage8,
    /// Row stride in bytes.
    stride: u32 = 0,
    pixels: []u8 = &.{},

    pub fn isEmpty(self: Bitmap) bool {
        return self.width == 0 or self.height == 0;
    }
};

pub const LineMetrics = struct {
    /// Distance from baseline to top of the line box (positive), px.
    ascent: f32,
    /// Distance from baseline to bottom of the line box (positive), px.
    descent: f32,
    line_gap: f32 = 0,
    underline_position: f32 = 0,
    underline_thickness: f32 = 1,
    /// Advance of '0' or the average char width; used for fixed-pitch fallbacks.
    average_advance: f32 = 0,

    pub fn lineHeight(self: LineMetrics) f32 {
        return self.ascent + self.descent + self.line_gap;
    }
};

/// One positioned glyph produced by shaping.
pub const ShapedGlyph = struct {
    face: FaceId,
    glyph: GlyphId,
    /// Pen advance in px (already includes kerning against the next glyph).
    x_advance: f32,
    x_offset: f32 = 0,
    y_offset: f32 = 0,
    /// Byte offset in the source UTF-8 text of the first codepoint of this cluster.
    cluster: u32,
};

/// The low-level face interface. The built-in sfnt backend implements this; hosts can provide
/// their own. All methods must be safe to call from the render thread (no global state).
pub const Face = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns 0 (notdef) when the face has no glyph for `codepoint`.
        glyphIndex: *const fn (ptr: *anyopaque, codepoint: u21) GlyphId,
        /// Horizontal advance in font units.
        advance: *const fn (ptr: *anyopaque, glyph: GlyphId) i32,
        /// Pair kerning adjustment in font units (0 when none).
        kerning: *const fn (ptr: *anyopaque, left: GlyphId, right: GlyphId) i32,
        unitsPerEm: *const fn (ptr: *anyopaque) u16,
        /// Metrics in font units; caller scales.
        unitMetrics: *const fn (ptr: *anyopaque) UnitMetrics,
        /// Rasterizes `glyph` at `size_px` with a horizontal sub-pixel shift of
        /// `subpixel_x / subpixel_steps` px into memory from `scratch`.
        rasterize: *const fn (ptr: *anyopaque, glyph: GlyphId, size_px: f32, subpixel_x: u8, scratch: std.mem.Allocator) anyerror!Bitmap,
        /// Optional: substitute a run of glyphs in place (ligatures etc.). May shrink `glyphs`.
        /// Returns the new length. `null` means "no substitution support".
        substitute: ?*const fn (ptr: *anyopaque, glyphs: []GlyphId, clusters: []u32) usize = null,
        /// Optional: true when `substitute` never replaces `glyph` or starts a ligature at it
        /// (its shaping does not depend on the following text). `null` with a non-null
        /// `substitute` means "unknown" (treated as context-dependent).
        contextFree: ?*const fn (ptr: *anyopaque, glyph: GlyphId) bool = null,
        /// Optional: ink bounds in font units (null = empty glyph or unsupported).
        glyphBounds: ?*const fn (ptr: *anyopaque, glyph: GlyphId) ?GlyphBounds = null,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn glyphIndex(self: Face, cp: u21) GlyphId {
        return self.vtable.glyphIndex(self.ptr, cp);
    }
    pub fn advance(self: Face, glyph: GlyphId) i32 {
        return self.vtable.advance(self.ptr, glyph);
    }
    pub fn kerning(self: Face, left: GlyphId, right: GlyphId) i32 {
        return self.vtable.kerning(self.ptr, left, right);
    }
    pub fn unitsPerEm(self: Face) u16 {
        return self.vtable.unitsPerEm(self.ptr);
    }
    pub fn unitMetrics(self: Face) UnitMetrics {
        return self.vtable.unitMetrics(self.ptr);
    }
    pub fn rasterize(self: Face, glyph: GlyphId, size_px: f32, subpixel_x: u8, scratch: std.mem.Allocator) !Bitmap {
        return self.vtable.rasterize(self.ptr, glyph, size_px, subpixel_x, scratch);
    }
};

pub const UnitMetrics = struct {
    ascent: i32,
    descent: i32, // positive
    line_gap: i32 = 0,
    underline_position: i32 = 0,
    underline_thickness: i32 = 0,
    average_advance: i32 = 0,
    is_fixed_pitch: bool = false,
};

/// Where a face comes from. Palette never requires fonts to be installed system-wide.
pub const Source = union(enum) {
    /// Borrowed bytes that outlive the collection (e.g. @embedFile).
    memory: []const u8,
    /// Bytes the collection takes ownership of (freed with the collection allocator).
    owned_memory: []u8,
    /// Path to a .ttf/.otf/.ttc file; read (or mmapped) at load time.
    path: []const u8,
    /// Resolve via system font discovery (fontconfig-free directory scan on Linux).
    system: SystemQuery,
    /// A host-implemented face.
    custom: Face,
};

pub const SystemQuery = struct {
    family: []const u8,
    weight: u16 = 400,
    italic: bool = false,
    monospace: bool = false,
};

/// Role -> ordered fallback chain. Palette's draw.FontRole is the key so components keep
/// emitting the same commands they always have.
pub const Role = draw.FontRole;

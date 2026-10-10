//! Palette font engine: pure-Zig sfnt parsing, rasterization, shaping-lite, fallback and system
//! discovery. See README.md in this directory.

pub const api = @import("api.zig");
pub const sfnt = @import("sfnt.zig");
pub const otl = @import("otl.zig");
pub const cff = @import("cff.zig");
pub const raster = @import("raster.zig");
pub const SfntFace = @import("sfnt_face.zig").SfntFace;

pub const FaceId = api.FaceId;
pub const GlyphId = api.GlyphId;
pub const GlyphKey = api.GlyphKey;
pub const Bitmap = api.Bitmap;
pub const LineMetrics = api.LineMetrics;
pub const ShapedGlyph = api.ShapedGlyph;
pub const Face = api.Face;
pub const Source = api.Source;
pub const SystemQuery = api.SystemQuery;
pub const Role = api.Role;
pub const collection = @import("collection.zig");
pub const discovery = @import("discovery.zig");
pub const Collection = collection.Collection;

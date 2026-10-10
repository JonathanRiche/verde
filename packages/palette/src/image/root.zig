//! Palette image loading (dependency-free). Wire into `src/root.zig` as
//! `pub const image = @import("image/root.zig");`.
pub const png = @import("png.zig");

pub const LoadedImage = png.LoadedImage;
pub const DecodeOptions = png.DecodeOptions;
pub const EncodeOptions = png.EncodeOptions;

/// Decode an image file to RGBA8 (PNG only). Replaces `image_loader.load(path)`.
pub const load = png.load;
/// Decode in-memory image bytes to RGBA8 with default limits. Replaces `image_loader.loadFromMemory`.
pub const loadFromMemory = png.loadFromMemory;
pub const decodeInfo = png.decodeInfo;
pub const encodeRgba = png.encodeRgba;
pub const saveRgba = png.saveRgba;

test {
    _ = @import("png_test.zig");
    _ = @import("inflate.zig");
}

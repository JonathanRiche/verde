//! Screenshot crops of CPU-side browser frames for inspector design-mode
//! prompts: maps CSS selection rects onto frame pixels and encodes the crop
//! as a PNG the chat attachment pipeline can store on disk.

const std = @import("std");
const browser_texture = @import("texture.zig");

const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Pixel-space crop region, guaranteed to lie inside the source frame.
pub const CropRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Maps a CSS-space selection rect (viewport coordinates) onto frame pixels.
/// `padding_css` adds visual context around the selection before scaling.
/// Returns null when the selection is degenerate or entirely off-frame.
pub fn cropRectFromCss(
    css_x: f32,
    css_y: f32,
    css_width: f32,
    css_height: f32,
    viewport_width: f32,
    viewport_height: f32,
    frame_width: u32,
    frame_height: u32,
    padding_css: f32,
) ?CropRect {
    if (frame_width == 0 or frame_height == 0) return null;
    if (viewport_width <= 0.0 or viewport_height <= 0.0) return null;
    if (css_width <= 0.0 or css_height <= 0.0) return null;

    // The frame is the rendered viewport, so the CSS→pixel factor is simply
    // frame size over viewport size (this folds in the device pixel ratio).
    const scale_x = @as(f32, @floatFromInt(frame_width)) / viewport_width;
    const scale_y = @as(f32, @floatFromInt(frame_height)) / viewport_height;

    const left = (css_x - padding_css) * scale_x;
    const top = (css_y - padding_css) * scale_y;
    const right = (css_x + css_width + padding_css) * scale_x;
    const bottom = (css_y + css_height + padding_css) * scale_y;

    const frame_w_f = @as(f32, @floatFromInt(frame_width));
    const frame_h_f = @as(f32, @floatFromInt(frame_height));
    const clamped_left = std.math.clamp(left, 0.0, frame_w_f);
    const clamped_top = std.math.clamp(top, 0.0, frame_h_f);
    const clamped_right = std.math.clamp(right, 0.0, frame_w_f);
    const clamped_bottom = std.math.clamp(bottom, 0.0, frame_h_f);

    const x: u32 = @intFromFloat(@floor(clamped_left));
    const y: u32 = @intFromFloat(@floor(clamped_top));
    const max_x: u32 = @intFromFloat(@ceil(clamped_right));
    const max_y: u32 = @intFromFloat(@ceil(clamped_bottom));
    const width = @min(max_x, frame_width) -| x;
    const height = @min(max_y, frame_height) -| y;
    if (width == 0 or height == 0) return null;

    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// Encodes a crop of a tightly packed 4-byte-per-pixel frame as an RGB PNG.
/// The alpha channel is dropped: browser frames are composited opaque.
pub fn encodeFrameCropPng(
    allocator: std.mem.Allocator,
    frame: browser_texture.CopiedFrame,
    crop: CropRect,
) ![]u8 {
    std.debug.assert(crop.x + crop.width <= frame.width);
    std.debug.assert(crop.y + crop.height <= frame.height);
    std.debug.assert(frame.pixels.len >= @as(usize, frame.width) * frame.height * 4);

    const idat = try compressCropScanlines(allocator, frame, crop);
    defer allocator.free(idat);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll(&PNG_SIGNATURE);

    // IHDR: 8-bit truecolor RGB, no interlace.
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], crop.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], crop.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: truecolor
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writePngChunk(&out.writer, "IHDR", &ihdr);
    try writePngChunk(&out.writer, "IDAT", idat);
    try writePngChunk(&out.writer, "IEND", &.{});

    return out.toOwnedSlice();
}

// Produces the zlib-wrapped deflate stream of filter-0 scanlines for the crop.
fn compressCropScanlines(
    allocator: std.mem.Allocator,
    frame: browser_texture.CopiedFrame,
    crop: CropRect,
) ![]u8 {
    var compressed: std.Io.Writer.Allocating = .init(allocator);
    defer compressed.deinit();
    // Compress.init asserts the output writer has buffered capacity.
    try compressed.ensureUnusedCapacity(4096);

    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    // The Compress state is ~224K; keep it off the stack.
    const compress = try allocator.create(std.compress.flate.Compress);
    defer allocator.destroy(compress);
    compress.* = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default);

    // Each PNG scanline is one filter byte followed by RGB samples.
    const row_bytes = try allocator.alloc(u8, 1 + @as(usize, crop.width) * 3);
    defer allocator.free(row_bytes);
    row_bytes[0] = 0; // filter: none

    var row: u32 = 0;
    while (row < crop.height) : (row += 1) {
        const src_row_start = (@as(usize, crop.y + row) * frame.width + crop.x) * 4;
        var col: usize = 0;
        while (col < crop.width) : (col += 1) {
            const src = frame.pixels[src_row_start + col * 4 ..][0..4];
            const dst = row_bytes[1 + col * 3 ..][0..3];
            switch (frame.format) {
                .bgra => {
                    dst[0] = src[2];
                    dst[1] = src[1];
                    dst[2] = src[0];
                },
                .rgba => {
                    dst[0] = src[0];
                    dst[1] = src[1];
                    dst[2] = src[2];
                },
            }
        }
        try compress.writer.writeAll(row_bytes);
    }
    try compress.finish();

    return compressed.toOwnedSlice();
}

// Emits one PNG chunk: length, type, payload, CRC32 over type + payload.
fn writePngChunk(writer: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) !void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(data.len), .big);
    try writer.writeAll(&length_bytes);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);

    var crc: std.hash.Crc32 = .init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);
}

test "cropRectFromCss maps and clamps css rects onto frame pixels" {
    // 2x device pixel ratio: 800x600 CSS viewport rendered at 1600x1200.
    const crop = cropRectFromCss(100.0, 50.0, 200.0, 100.0, 800.0, 600.0, 1600, 1200, 0.0).?;
    try std.testing.expectEqual(@as(u32, 200), crop.x);
    try std.testing.expectEqual(@as(u32, 100), crop.y);
    try std.testing.expectEqual(@as(u32, 400), crop.width);
    try std.testing.expectEqual(@as(u32, 200), crop.height);

    // Padding expands the crop but clamps at the frame edges.
    const padded = cropRectFromCss(0.0, 0.0, 800.0, 600.0, 800.0, 600.0, 1600, 1200, 16.0).?;
    try std.testing.expectEqual(@as(u32, 0), padded.x);
    try std.testing.expectEqual(@as(u32, 0), padded.y);
    try std.testing.expectEqual(@as(u32, 1600), padded.width);
    try std.testing.expectEqual(@as(u32, 1200), padded.height);

    // Fully offscreen or degenerate selections produce no crop.
    try std.testing.expectEqual(@as(?CropRect, null), cropRectFromCss(900.0, 0.0, 50.0, 50.0, 800.0, 600.0, 1600, 1200, 0.0));
    try std.testing.expectEqual(@as(?CropRect, null), cropRectFromCss(10.0, 10.0, 0.0, 5.0, 800.0, 600.0, 1600, 1200, 0.0));
}

test "encodeFrameCropPng round-trips through the stb decoder" {
    const allocator = std.testing.allocator;

    // 4x2 BGRA frame with distinct pixel values.
    const width: u32 = 4;
    const height: u32 = 2;
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast(10 + x); // B
            pixels[base + 1] = @intCast(100 + y); // G
            pixels[base + 2] = @intCast(200 - x); // R
            pixels[base + 3] = 255;
        }
    }

    const frame: browser_texture.CopiedFrame = .{
        .width = width,
        .height = height,
        .format = .bgra,
        .pixels = &pixels,
    };
    const png = try encodeFrameCropPng(allocator, frame, .{ .x = 1, .y = 0, .width = 2, .height = 2 });
    defer allocator.free(png);

    try std.testing.expect(std.mem.eql(u8, png[0..8], &PNG_SIGNATURE));

    const stb = @import("../media/stb_image.zig");
    const decoded = try stb.loadFromMemory(png);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(c_int, 2), decoded.width);
    try std.testing.expectEqual(@as(c_int, 2), decoded.height);
    // Crop origin (1,0): B=11 G=100 R=199 → decoded RGBA R=199 G=100 B=11.
    try std.testing.expectEqual(@as(u8, 199), decoded.pixels[0]);
    try std.testing.expectEqual(@as(u8, 100), decoded.pixels[1]);
    try std.testing.expectEqual(@as(u8, 11), decoded.pixels[2]);
}

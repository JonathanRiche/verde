//! Minimal PNG encode/decode for renderer screenshots and golden-image tests.
//! Encodes RGBA8; decodes 8-bit RGB/RGBA non-interlaced images (what we write and what common
//! tools produce for references). Uses std.compress.flate, so no dependencies.

const std = @import("std");
const flate = std.compress.flate;

const signature = "\x89PNG\r\n\x1a\n";

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA8, tightly packed rows.
    pixels: []u8,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

fn writeChunk(out: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try out.writeInt(u32, @intCast(data.len), .big);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try out.writeAll(kind);
    try out.writeAll(data);
    try out.writeInt(u32, crc.final(), .big);
}

/// Encodes `rgba` (width*height*4 bytes) as a PNG. Caller owns the returned bytes.
pub fn encode(gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    // Filter type 1 (Sub) per row: UI screenshots are dominated by flat runs, which Sub turns
    // into zeros.
    const row_len = @as(usize, width) * 4 + 1;
    const filtered = try gpa.alloc(u8, row_len * height);
    defer gpa.free(filtered);
    for (0..height) |y| {
        const src = rgba[y * width * 4 ..][0 .. width * 4];
        const dst = filtered[y * row_len ..][0..row_len];
        dst[0] = 1;
        for (src, 0..) |byte, i| {
            const left: u8 = if (i >= 4) src[i - 4] else 0;
            dst[1 + i] = byte -% left;
        }
    }

    var zbuf: std.Io.Writer.Allocating = try .initCapacity(gpa, filtered.len / 4 + 64);
    defer zbuf.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var compress = try flate.Compress.init(&zbuf.writer, window, .zlib, .level_4);
        try compress.writer.writeAll(filtered);
        try compress.finish();
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(&out.writer, "IHDR", &ihdr);
    try writeChunk(&out.writer, "IDAT", zbuf.written());
    try writeChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub const DecodeError = error{ InvalidPng, UnsupportedPng, OutOfMemory };

/// Decodes an 8-bit RGB or RGBA, non-interlaced PNG into RGBA8.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], signature)) return error.InvalidPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return error.InvalidPng;
        const data = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[12] != 0) return error.UnsupportedPng;
            channels = switch (data[9]) {
                2 => 3,
                6 => 4,
                else => return error.UnsupportedPng,
            };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (width == 0 or height == 0 or channels == 0) return error.InvalidPng;

    const stride = @as(usize, width) * channels;
    const raw_len = (stride + 1) * height;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        var reader: std.Io.Reader = .fixed(idat.items);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var decompress: flate.Decompress = .init(&reader, .zlib, window);
        decompress.reader.readSliceAll(raw) catch return error.InvalidPng;
    }

    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(pixels);
    const prev_row = try gpa.alloc(u8, stride);
    defer gpa.free(prev_row);
    @memset(prev_row, 0);
    const bpp = channels;
    for (0..height) |y| {
        const filter = raw[y * (stride + 1)];
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (row, 0..) |*byte, i| {
            const a: u8 = if (i >= bpp) row[i - bpp] else 0;
            const b = prev_row[i];
            const c: u8 = if (i >= bpp) prev_row[i - bpp] else 0;
            byte.* = switch (filter) {
                0 => byte.*,
                1 => byte.* +% a,
                2 => byte.* +% b,
                3 => byte.* +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => byte.* +% paeth(a, b, c),
                else => return error.InvalidPng,
            };
        }
        @memcpy(prev_row, row);
        const out = pixels[y * width * 4 ..][0 .. width * 4];
        if (channels == 4) {
            @memcpy(out, row);
        } else {
            for (0..width) |x| {
                out[x * 4 + 0] = row[x * 3 + 0];
                out[x * 4 + 1] = row[x * 3 + 1];
                out[x * 4 + 2] = row[x * 3 + 2];
                out[x * 4 + 3] = 255;
            }
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

pub const Diff = struct {
    /// Pixels whose largest channel difference exceeds the tolerance.
    mismatched: usize,
    max_channel_delta: u8,
};

/// Compares two RGBA8 buffers of equal size channel-wise.
pub fn compare(a: []const u8, b: []const u8, tolerance: u8) Diff {
    std.debug.assert(a.len == b.len);
    var diff: Diff = .{ .mismatched = 0, .max_channel_delta = 0 };
    var i: usize = 0;
    while (i < a.len) : (i += 4) {
        var worst: u8 = 0;
        inline for (0..4) |c| {
            const d = if (a[i + c] > b[i + c]) a[i + c] - b[i + c] else b[i + c] - a[i + c];
            worst = @max(worst, d);
        }
        diff.max_channel_delta = @max(diff.max_channel_delta, worst);
        if (worst > tolerance) diff.mismatched += 1;
    }
    return diff;
}

test "png round trip" {
    const gpa = std.testing.allocator;
    var px: [7 * 5 * 4]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @truncate(i * 37 + i / 3);
    const png = try encode(gpa, 7, 5, &px);
    defer gpa.free(png);
    const img = try decode(gpa, png);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 7), img.width);
    try std.testing.expectEqualSlices(u8, &px, img.pixels);
    try std.testing.expectEqual(@as(usize, 0), compare(&px, img.pixels, 0).mismatched);
}

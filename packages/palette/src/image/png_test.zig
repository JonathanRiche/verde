//! PNG codec tests: round trips at every color type / bit depth / interlace / filter,
//! externally encoded fixtures, and truncation / corruption fuzzing.
const std = @import("std");
const png = @import("png.zig");
const testing = std.testing;

/// Reference conversion (deliberately naive and independent of the decoder's fast paths).
fn refSample(data: []const u8, stride: usize, x: usize, y: usize, ch: usize, channels: usize, depth: u8) u16 {
    const bit = (x * channels + ch) * depth;
    const row = data[y * stride ..];
    if (depth == 16) return (@as(u16, row[bit / 8]) << 8) | row[bit / 8 + 1];
    if (depth == 8) return row[bit / 8];
    const byte = row[bit / 8];
    const shift: u3 = @intCast(8 - depth - (bit % 8));
    return (byte >> shift) & ((@as(u8, 1) << @intCast(depth)) - 1);
}

fn to8(v: u16, depth: u8) u8 {
    return switch (depth) {
        1 => @intCast(v * 255),
        2 => @intCast(v * 85),
        4 => @intCast(v * 17),
        8 => @intCast(v),
        16 => @intCast(v >> 8),
        else => unreachable,
    };
}

fn reference(gpa: std.mem.Allocator, img: png.RawImage) ![]u8 {
    const h: png.Header = .{ .width = img.width, .height = img.height, .bit_depth = img.bit_depth, .color_type = img.color_type, .interlaced = false };
    const stride = h.rowBytes(img.width);
    const ch = img.color_type.channels();
    const d = img.bit_depth;
    const out = try gpa.alloc(u8, img.width * img.height * 4);
    for (0..img.height) |y| for (0..img.width) |x| {
        const o = out[(y * img.width + x) * 4 ..][0..4];
        switch (img.color_type) {
            .gray => {
                const v = refSample(img.data, stride, x, y, 0, ch, d);
                var a: u8 = 255;
                if (img.transparency) |t| if (((@as(u16, t[0]) << 8) | t[1]) == v) {
                    a = 0;
                };
                o.* = .{ to8(v, d), to8(v, d), to8(v, d), a };
            },
            .gray_alpha => {
                const v = to8(refSample(img.data, stride, x, y, 0, ch, d), d);
                o.* = .{ v, v, v, to8(refSample(img.data, stride, x, y, 1, ch, d), d) };
            },
            .rgb => {
                var s: [3]u16 = undefined;
                for (0..3) |c| s[c] = refSample(img.data, stride, x, y, c, ch, d);
                var a: u8 = 255;
                if (img.transparency) |t| {
                    var eq = true;
                    for (0..3) |c| eq = eq and ((@as(u16, t[2 * c]) << 8) | t[2 * c + 1]) == s[c];
                    if (eq) a = 0;
                }
                o.* = .{ to8(s[0], d), to8(s[1], d), to8(s[2], d), a };
            },
            .rgba => {
                for (0..4) |c| o[c] = to8(refSample(img.data, stride, x, y, c, ch, d), d);
            },
            .indexed => {
                const idx = refSample(img.data, stride, x, y, 0, ch, d);
                const p = img.palette[idx];
                var a: u8 = 255;
                if (img.transparency) |t| if (idx < t.len) {
                    a = t[idx];
                };
                o.* = .{ p[0], p[1], p[2], a };
            },
        }
    };
    return out;
}

const Format = struct { ct: png.ColorType, depth: u8 };
const formats = [_]Format{
    .{ .ct = .gray, .depth = 1 },        .{ .ct = .gray, .depth = 2 },    .{ .ct = .gray, .depth = 4 },
    .{ .ct = .gray, .depth = 8 },        .{ .ct = .gray, .depth = 16 },   .{ .ct = .rgb, .depth = 8 },
    .{ .ct = .rgb, .depth = 16 },        .{ .ct = .indexed, .depth = 1 }, .{ .ct = .indexed, .depth = 2 },
    .{ .ct = .indexed, .depth = 4 },     .{ .ct = .indexed, .depth = 8 }, .{ .ct = .gray_alpha, .depth = 8 },
    .{ .ct = .gray_alpha, .depth = 16 }, .{ .ct = .rgba, .depth = 8 },    .{ .ct = .rgba, .depth = 16 },
};

const Fixture = struct {
    data: []u8,
    palette: [][3]u8,
    trns: ?[]u8,

    fn deinit(f: Fixture, gpa: std.mem.Allocator) void {
        gpa.free(f.data);
        gpa.free(f.palette);
        if (f.trns) |t| gpa.free(t);
    }

    fn raw(f: Fixture, fmt: Format, w: u32, h: u32) png.RawImage {
        return .{ .width = w, .height = h, .color_type = fmt.ct, .bit_depth = fmt.depth, .data = f.data, .palette = f.palette, .transparency = f.trns };
    }
};

/// Smooth-ish random content so filters other than None get chosen.
fn makeFixture(gpa: std.mem.Allocator, rand: std.Random, fmt: Format, w: u32, h: u32, with_trns: bool) !Fixture {
    const hdr: png.Header = .{ .width = w, .height = h, .bit_depth = fmt.depth, .color_type = fmt.ct, .interlaced = false };
    const stride = hdr.rowBytes(w);
    const data = try gpa.alloc(u8, stride * h);
    for (data, 0..) |*b, i| {
        b.* = if (rand.boolean()) rand.int(u8) else @truncate(i *% 7 +% (i / stride) *% 3);
    }
    var palette: [][3]u8 = &.{};
    var trns: ?[]u8 = null;
    switch (fmt.ct) {
        .indexed => {
            const n = @as(usize, 1) << @intCast(fmt.depth);
            palette = try gpa.alloc([3]u8, n);
            for (palette) |*p| p.* = .{ rand.int(u8), rand.int(u8), rand.int(u8) };
            if (with_trns) {
                const t = try gpa.alloc(u8, rand.intRangeAtMost(usize, 1, n));
                for (t) |*a| a.* = rand.int(u8);
                trns = t;
            }
        },
        .gray => if (with_trns) {
            // Key = the first pixel so it definitely occurs.
            const k = refSample(data, stride, 0, 0, 0, 1, fmt.depth);
            const t = try gpa.alloc(u8, 2);
            std.mem.writeInt(u16, t[0..2], k, .big);
            trns = t;
        },
        .rgb => if (with_trns) {
            const t = try gpa.alloc(u8, 6);
            for (0..3) |c| std.mem.writeInt(u16, t[2 * c ..][0..2], refSample(data, stride, 0, 0, c, 3, fmt.depth), .big);
            trns = t;
        },
        else => {},
    }
    return .{ .data = data, .palette = palette, .trns = trns };
}

test "round trip every color type, bit depth, interlace, filter and compression" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    const rand = prng.random();
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 1, 9 }, .{ 9, 1 }, .{ 3, 3 }, .{ 7, 9 }, .{ 33, 17 }, .{ 64, 40 } };
    const filters = [_]png.FilterMode{ .none, .sub, .up, .average, .paeth, .adaptive };
    var cases: usize = 0;
    for (formats) |fmt| for (sizes) |sz| for ([_]bool{ false, true }) |with_trns| {
        if (with_trns and (fmt.ct == .gray_alpha or fmt.ct == .rgba)) continue;
        const fx = try makeFixture(gpa, rand, fmt, sz[0], sz[1], with_trns);
        defer fx.deinit(gpa);
        const raw = fx.raw(fmt, sz[0], sz[1]);
        const expect = try reference(gpa, raw);
        defer gpa.free(expect);
        for ([_]bool{ false, true }) |interlace| for (filters, 0..) |filter, fi| {
            const compression: png.Compression = switch (fi % 3) {
                0 => .store,
                1 => .fastest,
                else => .default,
            };
            const encoded = try png.encodeRaw(gpa, raw, .{ .interlace = interlace, .filter = filter, .compression = compression, .idat_chunk_size = 61 });
            defer gpa.free(encoded);
            const info = try png.decodeInfo(encoded);
            try testing.expectEqual(sz[0], info.width);
            try testing.expectEqual(interlace, info.interlaced);
            const img = png.decode(gpa, encoded, .{}) catch |err| {
                std.debug.print("decode failed {s} d={d} {d}x{d} il={} f={s}: {s}\n", .{ @tagName(fmt.ct), fmt.depth, sz[0], sz[1], interlace, @tagName(filter), @errorName(err) });
                return err;
            };
            defer img.deinit(gpa);
            testing.expectEqualSlices(u8, expect, img.pixels) catch |err| {
                std.debug.print("mismatch {s} d={d} {d}x{d} il={} f={s}\n", .{ @tagName(fmt.ct), fmt.depth, sz[0], sz[1], interlace, @tagName(filter) });
                return err;
            };
            cases += 1;
        };
    };
    try testing.expect(cases > 1000);
}

test "rgba8 helpers and large image with best compression" {
    const gpa = testing.allocator;
    const w = 300;
    const h = 200;
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);
    for (0..h) |y| for (0..w) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ @truncate(x), @truncate(y), @truncate(x ^ y), 200 };
    };
    for ([_]png.Compression{ .fastest, .default, .best }) |c| {
        const enc = try png.encodeRgba(gpa, px, w, h, .{ .compression = c });
        defer gpa.free(enc);
        try testing.expect(enc.len < px.len / 4); // gradients compress well
        const img = try png.loadFromMemory(gpa, enc);
        defer img.deinit(gpa);
        try testing.expectEqual(@as(u32, w * 4), img.pitch());
        try testing.expectEqualSlices(u8, px, img.pixels);
    }
}

// 1x1 RGBA (255,0,0,128) produced by Python's zlib + hand-assembled chunks (externally encoded).
const tiny_external = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xd0,
    0x00, 0x00, 0x04, 0x81, 0x01, 0x80, 0x2c, 0x55, 0xce, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "externally encoded fixture" {
    const img = try png.decode(testing.allocator, &tiny_external, .{});
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), img.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, img.pixels);
}

test "header validation and limits" {
    const gpa = testing.allocator;
    const px = [_]u8{0} ** (4 * 4 * 4);
    const enc = try png.encodeRgba(gpa, &px, 4, 4, .{});
    defer gpa.free(enc);
    try testing.expectError(error.ImageTooLarge, png.decode(gpa, enc, .{ .max_width = 3 }));
    try testing.expectError(error.ImageTooLarge, png.decode(gpa, enc, .{ .max_pixels = 15 }));
    try testing.expectError(error.InvalidSignature, png.decode(gpa, enc[1..], .{}));
    try testing.expectError(error.InvalidSignature, png.decodeInfo("short"));

    const bad = try gpa.dupe(u8, enc);
    defer gpa.free(bad);
    bad[20] ^= 1; // inside IHDR width -> CRC mismatch
    try testing.expectError(error.BadCrc, png.decode(gpa, bad, .{}));
    // Huge declared size (CRC fixed up) -> rejected by limits, not allocated.
    bad[20] ^= 1;
    bad[16] = 0x7f;
    std.mem.writeInt(u32, bad[29..33], std.hash.Crc32.hash(bad[12..29]), .big);
    try testing.expectError(error.ImageTooLarge, png.decode(gpa, bad, .{}));
    // decodeInfo has no limits; it reports the declared header.
    try testing.expectEqual(@as(u32, 0x7f000004), (try png.decodeInfo(bad)).width);
    // IDAT corruption that inflate cannot notice is caught by verify_checksums.
    const stored = try png.encodeRgba(gpa, &px, 4, 4, .{ .compression = .store, .filter = .none });
    defer gpa.free(stored);
    const sb = try gpa.dupe(u8, stored);
    defer gpa.free(sb);
    sb[sb.len - 12 - 4 - 4 - 5] ^= 0x10; // a pixel byte inside the stored block
    const loose = try png.decode(gpa, sb, .{});
    loose.deinit(gpa);
    try testing.expectError(error.BadCrc, png.decode(gpa, sb, .{ .verify_checksums = true }));
}

fn fuzzOne(gpa: std.mem.Allocator, bytes: []const u8, verify: bool) void {
    if (png.decode(gpa, bytes, .{ .verify_checksums = verify, .max_pixels = 1 << 20 })) |img| {
        img.deinit(gpa);
    } else |_| {}
    _ = png.decodeInfo(bytes) catch {};
}

test "truncated and corrupted inputs never crash" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(1234);
    const rand = prng.random();
    const seeds = [_]Format{ .{ .ct = .rgba, .depth = 8 }, .{ .ct = .indexed, .depth = 4 }, .{ .ct = .gray, .depth = 16 }, .{ .ct = .rgb, .depth = 8 } };
    for (seeds) |fmt| for ([_]bool{ false, true }) |interlace| {
        const fx = try makeFixture(gpa, rand, fmt, 23, 19, fmt.ct == .indexed);
        defer fx.deinit(gpa);
        const enc = try png.encodeRaw(gpa, fx.raw(fmt, 23, 19), .{ .interlace = interlace, .idat_chunk_size = 97 });
        defer gpa.free(enc);
        // Every truncation must fail.
        for (0..enc.len) |n| {
            if (png.decode(gpa, enc[0..n], .{})) |img| {
                img.deinit(gpa);
                return error.TruncatedInputDecoded;
            } else |_| {}
        }
        const buf = try gpa.dupe(u8, enc);
        defer gpa.free(buf);
        for (0..3000) |_| {
            @memcpy(buf, enc);
            const flips = rand.intRangeAtMost(usize, 1, 8);
            for (0..flips) |_| {
                const i = rand.intRangeLessThan(usize, 8, buf.len);
                switch (rand.int(u2)) {
                    0 => buf[i] ^= @as(u8, 1) << rand.int(u3),
                    1 => buf[i] = rand.int(u8),
                    2 => buf[i] = 0xff,
                    3 => buf[i] = 0,
                }
            }
            fuzzOne(gpa, buf, true);
            fuzzOne(gpa, buf, false);
            fuzzOne(gpa, buf[0..rand.intRangeAtMost(usize, 0, buf.len)], false);
        }
    };
    // Pure noise behind a valid signature.
    var noise: [512]u8 = undefined;
    for (0..2000) |_| {
        rand.bytes(&noise);
        @memcpy(noise[0..8], &png.signature);
        fuzzOne(gpa, &noise, false);
    }
}

test "fuzz entry (zig build test-image --fuzz)" {
    try testing.fuzz({}, struct {
        fn f(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const n = smith.slice(&buf);
            fuzzOne(testing.allocator, buf[0..n], false);
        }
    }.f, .{});
}

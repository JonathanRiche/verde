//! Dependency-free PNG codec (replaces stb_image for Palette).
//!
//! Decode: every standard color type and bit depth (1/2/4/8/16), PLTE + tRNS, Adam7
//! interlacing and all five scanline filters. Output is always RGBA8 (16-bit samples are
//! reduced with `>> 8`, matching stb_image). Inflate is our own bounds-checked `inflate.zig`
//! (std's Decompress can assert on corrupt input in Zig 0.16, see inflate.zig).
//! Ancillary chunks other than tRNS are ignored (no gamma / color management, like stb).
//!
//! Encode: any color type / bit depth from packed scanlines (`encodeRaw`) or straight RGBA8
//! (`encodeRgba`), optional Adam7, per-row adaptive filter heuristic, deflate via
//! `std.compress.flate.Compress` (or stored blocks).
//!
//! Every length / offset read from the file is bounds checked; corrupt or truncated input
//! returns an error, never traps.
const std = @import("std");
const inflate_mod = @import("inflate.zig");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    indexed = 3,
    gray_alpha = 4,
    rgba = 6,

    pub fn channels(c: ColorType) u8 {
        return switch (c) {
            .gray, .indexed => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    pub fn validDepth(c: ColorType, depth: u8) bool {
        return switch (c) {
            .gray => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
            .indexed => depth == 1 or depth == 2 or depth == 4 or depth == 8,
            .rgb, .gray_alpha, .rgba => depth == 8 or depth == 16,
        };
    }
};

/// IHDR contents. Returned by `decodeInfo`.
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    interlaced: bool,

    pub fn bitsPerPixel(h: Header) u32 {
        return @as(u32, h.color_type.channels()) * h.bit_depth;
    }

    /// Filter unit in bytes (>= 1).
    pub fn bytesPerPixel(h: Header) usize {
        return @max(1, h.bitsPerPixel() / 8);
    }

    /// Packed bytes for a row of `w` pixels (excluding the filter byte).
    pub fn rowBytes(h: Header, w: u32) usize {
        return @intCast((@as(u64, w) * h.bitsPerPixel() + 7) / 8);
    }

    /// True if the image carries an alpha channel (tRNS is not considered).
    pub fn hasAlphaChannel(h: Header) bool {
        return h.color_type == .gray_alpha or h.color_type == .rgba;
    }
};

pub const Error = error{
    InvalidSignature,
    Truncated,
    InvalidChunk,
    BadCrc,
    InvalidHeader,
    MissingHeader,
    UnsupportedCriticalChunk,
    InvalidPalette,
    MissingPalette,
    InvalidTransparency,
    MissingImageData,
    ImageTooLarge,
    CorruptImageData,
    InvalidFilter,
    InvalidPaletteIndex,
    OutOfMemory,
};

pub const DecodeOptions = struct {
    max_width: u32 = 16384,
    max_height: u32 = 16384,
    /// Upper bound on width*height (64 Mpx = 256 MiB of RGBA8 by default).
    max_pixels: u64 = 1 << 26,
    /// Also verify IDAT CRC-32s and the zlib Adler-32 (costs ~25% decode time; stb_image
    /// checks neither). CRCs of all other chunks (IHDR, PLTE, tRNS, ...) are always verified.
    /// Corrupt image data is caught structurally by inflate either way; this only adds
    /// detection of bit flips that still decode.
    verify_checksums: bool = false,
};

/// Decoded RGBA8 image (4 bytes per pixel, rows top-down, stride = width*4).
pub const LoadedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    /// Always 4 (RGBA8); kept for compatibility with the old stb-based loader.
    channels: u32 = 4,

    pub fn deinit(self: LoadedImage, gpa: Allocator) void {
        gpa.free(self.pixels);
    }

    pub fn pitch(self: LoadedImage) u32 {
        return self.width * 4;
    }
};

// ---------------------------------------------------------------------------------------
// Chunk parsing

const Chunk = struct {
    type: [4]u8,
    data: []const u8,
};

const ChunkIter = struct {
    bytes: []const u8,
    pos: usize = signature.len,
    verify_crc: bool,
    /// When false, IDAT CRCs are skipped (other chunks are still verified).
    verify_idat_crc: bool = true,

    fn next(it: *ChunkIter) Error!Chunk {
        if (it.bytes.len - it.pos < 12) return error.Truncated;
        const len = std.mem.readInt(u32, it.bytes[it.pos..][0..4], .big);
        if (len > 0x7fff_ffff) return error.InvalidChunk;
        if (it.bytes.len - it.pos - 12 < len) return error.Truncated;
        const type_and_data = it.bytes[it.pos + 4 ..][0 .. 4 + len];
        const crc = std.mem.readInt(u32, it.bytes[it.pos + 8 + len ..][0..4], .big);
        const is_idat = std.mem.eql(u8, type_and_data[0..4], "IDAT");
        if (it.verify_crc and (it.verify_idat_crc or !is_idat) and std.hash.Crc32.hash(type_and_data) != crc) return error.BadCrc;
        for (type_and_data[0..4]) |c| {
            if (!std.ascii.isAlphabetic(c)) return error.InvalidChunk;
        }
        it.pos += 12 + len;
        return .{ .type = type_and_data[0..4].*, .data = type_and_data[4..] };
    }
};

fn isType(c: Chunk, comptime name: []const u8) bool {
    return std.mem.eql(u8, &c.type, name);
}

fn parseHeader(data: []const u8, opts: DecodeOptions) Error!Header {
    if (data.len != 13) return error.InvalidHeader;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    const depth = data[8];
    const ct = std.enums.fromInt(ColorType, data[9]) orelse return error.InvalidHeader;
    if (width == 0 or height == 0 or width > 0x7fff_ffff or height > 0x7fff_ffff) return error.InvalidHeader;
    if (!ct.validDepth(depth)) return error.InvalidHeader;
    if (data[10] != 0 or data[11] != 0 or data[12] > 1) return error.InvalidHeader;
    if (width > opts.max_width or height > opts.max_height) return error.ImageTooLarge;
    if (@as(u64, width) * height > opts.max_pixels) return error.ImageTooLarge;
    return .{ .width = width, .height = height, .bit_depth = depth, .color_type = ct, .interlaced = data[12] == 1 };
}

/// Parse the signature and IHDR only (cheap; does not touch image data).
pub fn decodeInfo(bytes: []const u8) Error!Header {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..8], &signature)) return error.InvalidSignature;
    var it: ChunkIter = .{ .bytes = bytes, .verify_crc = true };
    const first = try it.next();
    if (!isType(first, "IHDR")) return error.MissingHeader;
    return parseHeader(first.data, .{ .max_width = 0x7fff_ffff, .max_height = 0x7fff_ffff, .max_pixels = std.math.maxInt(u64) });
}

const Transparency = union(enum) {
    none,
    /// Gray key (raw sample value at bit depth).
    gray: u16,
    rgb: [3]u16,
};

const Parsed = struct {
    header: Header,
    /// RGBA palette; entries past palette_len are unused.
    palette: [256][4]u8,
    palette_len: u16,
    trns: Transparency,
    idat_first: []const u8,
    idat_total: usize,
    idat_count: usize,
};

fn parse(bytes: []const u8, opts: DecodeOptions) Error!Parsed {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..8], &signature)) return error.InvalidSignature;
    var it: ChunkIter = .{ .bytes = bytes, .verify_crc = true, .verify_idat_crc = opts.verify_checksums };
    const first = try it.next();
    if (!isType(first, "IHDR")) return error.MissingHeader;
    var p: Parsed = .{
        .header = try parseHeader(first.data, opts),
        .palette = undefined,
        .palette_len = 0,
        .trns = .none,
        .idat_first = &.{},
        .idat_total = 0,
        .idat_count = 0,
    };
    const ct = p.header.color_type;
    var seen_trns = false;
    var idat_done = false; // a non-IDAT chunk followed the IDAT run
    while (true) {
        const c = try it.next();
        if (isType(c, "IEND")) break;
        if (isType(c, "IDAT")) {
            if (idat_done) return error.InvalidChunk;
            if (ct == .indexed and p.palette_len == 0) return error.MissingPalette;
            if (p.idat_count == 0) p.idat_first = c.data;
            p.idat_count += 1;
            p.idat_total += c.data.len;
            continue;
        }
        if (p.idat_count > 0) idat_done = true;
        if (isType(c, "IHDR")) return error.InvalidChunk;
        if (isType(c, "PLTE")) {
            if (p.palette_len != 0 or p.idat_count > 0 or seen_trns) return error.InvalidPalette;
            if (c.data.len == 0 or c.data.len % 3 != 0 or c.data.len / 3 > 256) return error.InvalidPalette;
            if (ct == .gray or ct == .gray_alpha) return error.InvalidPalette;
            const n = c.data.len / 3;
            if (ct == .indexed and n > (@as(usize, 1) << @intCast(p.header.bit_depth))) return error.InvalidPalette;
            for (0..n) |i| p.palette[i] = .{ c.data[i * 3], c.data[i * 3 + 1], c.data[i * 3 + 2], 255 };
            p.palette_len = @intCast(n);
            continue;
        }
        if (isType(c, "tRNS")) {
            if (seen_trns or p.idat_count > 0) return error.InvalidTransparency;
            seen_trns = true;
            switch (ct) {
                .indexed => {
                    if (p.palette_len == 0) return error.MissingPalette;
                    if (c.data.len > p.palette_len) return error.InvalidTransparency;
                    for (c.data, 0..) |a, i| p.palette[i][3] = a;
                },
                .gray => {
                    if (c.data.len != 2) return error.InvalidTransparency;
                    p.trns = .{ .gray = std.mem.readInt(u16, c.data[0..2], .big) };
                },
                .rgb => {
                    if (c.data.len != 6) return error.InvalidTransparency;
                    p.trns = .{ .rgb = .{
                        std.mem.readInt(u16, c.data[0..2], .big),
                        std.mem.readInt(u16, c.data[2..4], .big),
                        std.mem.readInt(u16, c.data[4..6], .big),
                    } };
                },
                .gray_alpha, .rgba => return error.InvalidTransparency,
            }
            continue;
        }
        // Unknown chunk: bit 5 of the first byte clear = critical.
        if (c.type[0] & 0x20 == 0) return error.UnsupportedCriticalChunk;
    }
    if (p.idat_count == 0) return error.MissingImageData;
    if (ct == .indexed and p.palette_len == 0) return error.MissingPalette;
    return p;
}

// ---------------------------------------------------------------------------------------
// Adam7

pub const Pass = struct { x0: u8, y0: u8, dx: u8, dy: u8 };

pub const adam7 = [7]Pass{
    .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
    .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 },
    .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 },
    .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
    .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
};
const no_interlace = [1]Pass{.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 }};

fn passes(h: Header) []const Pass {
    return if (h.interlaced) &adam7 else &no_interlace;
}

fn passDim(full: u32, start: u8, step: u8) u32 {
    if (full <= start) return 0;
    return (full - start + step - 1) / step;
}

/// Total size of the filtered (inflated) stream for this header.
fn rawSize(h: Header) u64 {
    var total: u64 = 0;
    for (passes(h)) |p| {
        const pw = passDim(h.width, p.x0, p.dx);
        const ph = passDim(h.height, p.y0, p.dy);
        if (pw == 0 or ph == 0) continue;
        total += @as(u64, ph) * (1 + h.rowBytes(pw));
    }
    return total;
}

// ---------------------------------------------------------------------------------------
// Decode

/// Decode a PNG held in memory to RGBA8. `gpa` owns the returned pixels.
pub fn decode(gpa: Allocator, bytes: []const u8, opts: DecodeOptions) Error!LoadedImage {
    const p = try parse(bytes, opts);
    const h = p.header;

    // Gather the zlib stream (zero-copy when there is a single IDAT).
    var owned_idat: ?[]u8 = null;
    defer if (owned_idat) |b| gpa.free(b);
    const zdata: []const u8 = if (p.idat_count == 1) p.idat_first else blk: {
        const buf = try gpa.alloc(u8, p.idat_total);
        owned_idat = buf;
        var it: ChunkIter = .{ .bytes = bytes, .verify_crc = false };
        var off: usize = 0;
        while (off < buf.len) {
            const c = it.next() catch unreachable; // already validated by parse()
            if (!isType(c, "IDAT")) continue;
            @memcpy(buf[off..][0..c.data.len], c.data);
            off += c.data.len;
        }
        break :blk buf;
    };

    const raw_len = rawSize(h);
    if (raw_len > std.math.maxInt(usize)) return error.ImageTooLarge;
    const raw = try gpa.alloc(u8, @intCast(raw_len));
    defer gpa.free(raw);
    _ = inflate_mod.zlibDecompress(zdata, raw, opts.verify_checksums) catch return error.CorruptImageData;

    const out_len = @as(u64, h.width) * h.height * 4;
    if (out_len > std.math.maxInt(usize)) return error.ImageTooLarge;
    const out = try gpa.alloc(u8, @intCast(out_len));
    errdefer gpa.free(out);

    const bpp = h.bytesPerPixel();
    var off: usize = 0;
    for (passes(h)) |pass| {
        const pw = passDim(h.width, pass.x0, pass.dx);
        const ph = passDim(h.height, pass.y0, pass.dy);
        if (pw == 0 or ph == 0) continue;
        const rb = h.rowBytes(pw);
        const len = ph * (1 + rb);
        const region = raw[off..][0..len];
        off += len;
        try unfilter(region, rb, ph, bpp);
        for (0..ph) |py| {
            const row = region[py * (1 + rb) + 1 ..][0..rb];
            const y = pass.y0 + py * pass.dy;
            const dst = out[(y * h.width) * 4 ..][0 .. h.width * 4];
            try convertRow(&p, row, dst, pass.x0, pass.dx, pw);
        }
    }
    return .{ .pixels = out, .width = h.width, .height = h.height };
}

/// Read a PNG file and decode it. Compatible-ish with the old `image_loader.load(path)`.
pub fn load(gpa: Allocator, io: std.Io, path: []const u8, opts: DecodeOptions) !LoadedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 << 20));
    defer gpa.free(bytes);
    return decode(gpa, bytes, opts);
}

/// Decode from memory with default limits. Compatible-ish with `image_loader.loadFromMemory`.
pub fn loadFromMemory(gpa: Allocator, bytes: []const u8) Error!LoadedImage {
    return decode(gpa, bytes, .{});
}

inline fn paeth(a: u8, b: u8, c: u8) u8 {
    const ia: i16 = a;
    const ib: i16 = b;
    const ic: i16 = c;
    const pa = @abs(ib - ic);
    const pb = @abs(ia - ic);
    const pc = @abs(ia + ib - 2 * ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Reverse scanline filters in place. `region` is `rows * (1 + row_bytes)`.
fn unfilter(region: []u8, row_bytes: usize, rows: usize, bpp: usize) Error!void {
    switch (bpp) {
        inline 1, 2, 3, 4, 6, 8 => |b| return unfilterImpl(b, region, row_bytes, rows),
        else => unreachable,
    }
}

fn unfilterImpl(comptime bpp: usize, region: []u8, row_bytes: usize, rows: usize) Error!void {
    const stride = 1 + row_bytes;
    for (0..rows) |y| {
        const ft = region[y * stride];
        const row = region[y * stride + 1 ..][0..row_bytes];
        // The first row behaves as if the prior row were all zero:
        // Up -> None, Paeth -> Sub, Average keeps its own form.
        const prev: ?[]const u8 = if (y == 0) null else region[(y - 1) * stride + 1 ..][0..row_bytes];
        switch (ft) {
            0 => {},
            1 => unfilterSub(bpp, row),
            2 => if (prev) |up| {
                for (row, up) |*r, u| r.* +%= u;
            },
            3 => if (prev) |up| unfilterAvg(bpp, row, up) else {
                var i: usize = bpp;
                while (i < row.len) : (i += 1) row[i] +%= row[i - bpp] >> 1;
            },
            4 => if (prev) |up| unfilterPaeth(bpp, row, up) else unfilterSub(bpp, row),
            else => return error.InvalidFilter,
        }
    }
}

/// Pixel-at-a-time SIMD lanes for 3/4-byte pixels; bytewise otherwise.
const V = @Vector(4, i16);

inline fn loadPx(comptime bpp: usize, s: []const u8, i: usize) V {
    var v: [4]i16 = .{ 0, 0, 0, 0 };
    inline for (0..bpp) |k| v[k] = s[i + k];
    return v;
}

inline fn storePx(comptime bpp: usize, d: []u8, i: usize, v: V) void {
    const a: [4]i16 = v;
    inline for (0..bpp) |k| d[i + k] = @truncate(@as(u16, @bitCast(a[k])));
}

fn unfilterSub(comptime bpp: usize, row: []u8) void {
    var i: usize = bpp;
    while (i < row.len) : (i += 1) row[i] +%= row[i - bpp];
}

fn unfilterAvg(comptime bpp: usize, row: []u8, up: []const u8) void {
    const n = @min(bpp, row.len);
    for (0..n) |i| row[i] +%= up[i] >> 1;
    if (bpp == 3 or bpp == 4) {
        var a = loadPx(bpp, row, 0);
        var i: usize = bpp;
        while (i + bpp <= row.len) : (i += bpp) {
            const b = loadPx(bpp, up, i);
            const x = loadPx(bpp, row, i);
            a = (x + ((a + b) >> @splat(1))) & @as(V, @splat(0xff));
            storePx(bpp, row, i, a);
        }
        return;
    }
    var i: usize = bpp;
    while (i < row.len) : (i += 1) {
        row[i] +%= @intCast((@as(u16, row[i - bpp]) + up[i]) >> 1);
    }
}

fn unfilterPaeth(comptime bpp: usize, row: []u8, up: []const u8) void {
    const n = @min(bpp, row.len);
    for (0..n) |i| row[i] +%= up[i];
    if (bpp == 3 or bpp == 4) {
        var a = loadPx(bpp, row, 0);
        var c = loadPx(bpp, up, 0);
        var i: usize = bpp;
        while (i + bpp <= row.len) : (i += bpp) {
            const b = loadPx(bpp, up, i);
            const x = loadPx(bpp, row, i);
            const pa = @abs(b - c);
            const pb = @abs(a - c);
            const pc = @abs(a + b - c - c);
            const pick_a = (pa <= pb) & (pa <= pc);
            const pick_b = pb <= pc;
            const pred = @select(i16, pick_a, a, @select(i16, pick_b, b, c));
            a = (x + pred) & @as(V, @splat(0xff));
            storePx(bpp, row, i, a);
            c = b;
        }
        return;
    }
    var i: usize = bpp;
    while (i < row.len) : (i += 1) {
        row[i] +%= paeth(row[i - bpp], up[i], up[i - bpp]);
    }
}

inline fn subSample(row: []const u8, i: usize, comptime depth: u8) u8 {
    const bit = i * depth;
    const shift: u3 = @intCast(8 - depth - (bit & 7));
    return (row[bit >> 3] >> shift) & ((1 << depth) - 1);
}

inline fn be16(row: []const u8, i: usize) u16 {
    return (@as(u16, row[2 * i]) << 8) | row[2 * i + 1];
}

/// Convert one unfiltered row of `pw` pixels into RGBA8 at dst[x0 + i*dx].
fn convertRow(p: *const Parsed, row: []const u8, dst: []u8, x0: usize, dx: usize, pw: usize) Error!void {
    const h = p.header;
    switch (h.color_type) {
        .gray => switch (h.bit_depth) {
            inline 1, 2, 4 => |d| {
                const scale: u8 = 255 / ((1 << d) - 1);
                for (0..pw) |i| {
                    const v = subSample(row, i, d);
                    const a: u8 = if (p.trns == .gray and p.trns.gray == v) 0 else 255;
                    const o = (x0 + i * dx) * 4;
                    dst[o..][0..4].* = .{ v * scale, v * scale, v * scale, a };
                }
            },
            8 => for (0..pw) |i| {
                const v = row[i];
                const a: u8 = if (p.trns == .gray and p.trns.gray == v) 0 else 255;
                dst[(x0 + i * dx) * 4 ..][0..4].* = .{ v, v, v, a };
            },
            16 => for (0..pw) |i| {
                const v = be16(row, i);
                const a: u8 = if (p.trns == .gray and p.trns.gray == v) 0 else 255;
                const g: u8 = @intCast(v >> 8);
                dst[(x0 + i * dx) * 4 ..][0..4].* = .{ g, g, g, a };
            },
            else => unreachable,
        },
        .rgb => if (h.bit_depth == 8) {
            if (p.trns == .rgb) {
                const k = p.trns.rgb;
                for (0..pw) |i| {
                    const s = row[i * 3 ..][0..3];
                    const a: u8 = if (s[0] == k[0] and s[1] == k[1] and s[2] == k[2]) 0 else 255;
                    dst[(x0 + i * dx) * 4 ..][0..4].* = .{ s[0], s[1], s[2], a };
                }
            } else {
                for (0..pw) |i| {
                    const s = row[i * 3 ..][0..3];
                    dst[(x0 + i * dx) * 4 ..][0..4].* = .{ s[0], s[1], s[2], 255 };
                }
            }
        } else {
            for (0..pw) |i| {
                const r = be16(row, i * 3);
                const g = be16(row, i * 3 + 1);
                const b = be16(row, i * 3 + 2);
                const a: u8 = if (p.trns == .rgb and p.trns.rgb[0] == r and p.trns.rgb[1] == g and p.trns.rgb[2] == b) 0 else 255;
                dst[(x0 + i * dx) * 4 ..][0..4].* = .{ @intCast(r >> 8), @intCast(g >> 8), @intCast(b >> 8), a };
            }
        },
        .indexed => switch (h.bit_depth) {
            inline 1, 2, 4, 8 => |d| for (0..pw) |i| {
                const idx = if (d == 8) row[i] else subSample(row, i, d);
                if (idx >= p.palette_len) return error.InvalidPaletteIndex;
                dst[(x0 + i * dx) * 4 ..][0..4].* = p.palette[idx];
            },
            else => unreachable,
        },
        .gray_alpha => if (h.bit_depth == 8) {
            for (0..pw) |i| {
                const v = row[i * 2];
                dst[(x0 + i * dx) * 4 ..][0..4].* = .{ v, v, v, row[i * 2 + 1] };
            }
        } else {
            for (0..pw) |i| {
                const v = row[i * 4];
                dst[(x0 + i * dx) * 4 ..][0..4].* = .{ v, v, v, row[i * 4 + 2] };
            }
        },
        .rgba => if (h.bit_depth == 8) {
            if (dx == 1) {
                @memcpy(dst[x0 * 4 ..][0 .. pw * 4], row[0 .. pw * 4]);
            } else for (0..pw) |i| {
                dst[(x0 + i * dx) * 4 ..][0..4].* = row[i * 4 ..][0..4].*;
            }
        } else {
            for (0..pw) |i| {
                const s = row[i * 8 ..][0..8];
                dst[(x0 + i * dx) * 4 ..][0..4].* = .{ s[0], s[2], s[4], s[6] };
            }
        },
    }
}

// ---------------------------------------------------------------------------------------
// Encode

pub const FilterMode = enum {
    none,
    sub,
    up,
    average,
    paeth,
    /// Per row, pick the filter with minimal sum of absolute signed residuals (libpng heuristic).
    adaptive,
};

pub const Compression = enum {
    /// Stored (uncompressed) deflate blocks.
    store,
    fastest,
    default,
    best,
};

pub const EncodeOptions = struct {
    interlace: bool = false,
    filter: FilterMode = .adaptive,
    compression: Compression = .default,
    /// Maximum IDAT chunk payload.
    idat_chunk_size: u32 = 1 << 18,
};

/// Raw image description for `encodeRaw`.
pub const RawImage = struct {
    width: u32,
    height: u32,
    color_type: ColorType,
    bit_depth: u8,
    /// Packed scanlines without filter bytes; each row is `Header.rowBytes(width)` bytes,
    /// sub-byte samples MSB-first, 16-bit samples big-endian (exactly the PNG layout).
    data: []const u8,
    /// Required for `.indexed`, optional (suggested palette) for rgb/rgba.
    palette: []const [3]u8 = &.{},
    /// Raw tRNS payload (palette alphas, 2-byte gray key or 6-byte RGB key).
    transparency: ?[]const u8 = null,
};

pub const EncodeError = error{ InvalidImage, OutOfMemory };

/// Encode straight (non-premultiplied) RGBA8 pixels, stride = width*4.
pub fn encodeRgba(gpa: Allocator, pixels: []const u8, width: u32, height: u32, opts: EncodeOptions) EncodeError![]u8 {
    return encodeRaw(gpa, .{ .width = width, .height = height, .color_type = .rgba, .bit_depth = 8, .data = pixels }, opts);
}

/// Encode RGBA8 pixels to a file.
pub fn saveRgba(gpa: Allocator, io: std.Io, path: []const u8, pixels: []const u8, width: u32, height: u32, opts: EncodeOptions) !void {
    const bytes = try encodeRgba(gpa, pixels, width, height, opts);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn copyPixelBits(src: []const u8, src_index: usize, dst: []u8, dst_index: usize, bpp_bits: u32) void {
    if (bpp_bits >= 8) {
        const n = bpp_bits / 8;
        @memcpy(dst[dst_index * n ..][0..n], src[src_index * n ..][0..n]);
        return;
    }
    const sbit = src_index * bpp_bits;
    const dbit = dst_index * bpp_bits;
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bpp_bits)) - 1);
    const sshift: u3 = @intCast(8 - bpp_bits - (sbit & 7));
    const dshift: u3 = @intCast(8 - bpp_bits - (dbit & 7));
    const v = (src[sbit >> 3] >> sshift) & mask;
    dst[dbit >> 3] = (dst[dbit >> 3] & ~(mask << dshift)) | (v << dshift);
}

pub fn encodeRaw(gpa: Allocator, img: RawImage, opts: EncodeOptions) EncodeError![]u8 {
    const h: Header = .{
        .width = img.width,
        .height = img.height,
        .bit_depth = img.bit_depth,
        .color_type = img.color_type,
        .interlaced = opts.interlace,
    };
    if (img.width == 0 or img.height == 0 or img.width > 0x7fff_ffff or img.height > 0x7fff_ffff) return error.InvalidImage;
    if (!img.color_type.validDepth(img.bit_depth)) return error.InvalidImage;
    const src_stride = h.rowBytes(img.width);
    if (img.data.len < src_stride * img.height) return error.InvalidImage;
    if (img.color_type == .indexed and (img.palette.len == 0 or img.palette.len > (@as(usize, 1) << @intCast(img.bit_depth)))) return error.InvalidImage;
    if (img.palette.len > 256) return error.InvalidImage;

    // 1. Filtered stream.
    const raw_len: usize = @intCast(rawSize(h));
    const filtered = try gpa.alloc(u8, raw_len);
    defer gpa.free(filtered);
    const bpp = h.bytesPerPixel();
    const bits = h.bitsPerPixel();
    const max_rb = src_stride;
    const scratch = try gpa.alloc(u8, max_rb * 3);
    defer gpa.free(scratch);
    const zero_row = scratch[0..max_rb];
    @memset(zero_row, 0);
    const pass_row = scratch[max_rb .. 2 * max_rb];
    const prev_store = scratch[2 * max_rb .. 3 * max_rb];

    var off: usize = 0;
    for (passes(h)) |pass| {
        const pw = passDim(h.width, pass.x0, pass.dx);
        const ph = passDim(h.height, pass.y0, pass.dy);
        if (pw == 0 or ph == 0) continue;
        const rb = h.rowBytes(pw);
        for (0..ph) |py| {
            const y = pass.y0 + py * pass.dy;
            const src_row = img.data[y * src_stride ..][0..src_stride];
            const cur: []const u8 = if (!h.interlaced) src_row[0..rb] else blk: {
                @memset(pass_row[0..rb], 0);
                for (0..pw) |i| copyPixelBits(src_row, pass.x0 + i * pass.dx, pass_row, i, bits);
                break :blk pass_row[0..rb];
            };
            const prev: []const u8 = if (py == 0) zero_row[0..rb] else prev_store[0..rb];
            const out = filtered[off..][0 .. 1 + rb];
            off += 1 + rb;
            filterRow(opts.filter, cur, prev, out, bpp);
            @memcpy(prev_store[0..rb], cur);
        }
    }
    std.debug.assert(off == filtered.len);

    // 2. zlib stream.
    const zdata = try zlibCompress(gpa, filtered, opts.compression);
    defer gpa.free(zdata);

    // 3. Chunks.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, zdata.len + 128 + img.palette.len * 3);
    try out.appendSlice(gpa, &signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = img.bit_depth;
    ihdr[9] = @intFromEnum(img.color_type);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = @intFromBool(opts.interlace);
    try writeChunk(gpa, &out, "IHDR", &ihdr);
    if (img.palette.len > 0 and img.color_type != .gray and img.color_type != .gray_alpha) {
        try writeChunk(gpa, &out, "PLTE", std.mem.sliceAsBytes(img.palette));
    }
    if (img.transparency) |t| try writeChunk(gpa, &out, "tRNS", t);
    var zoff: usize = 0;
    while (zoff < zdata.len) {
        const n = @min(zdata.len - zoff, opts.idat_chunk_size);
        try writeChunk(gpa, &out, "IDAT", zdata[zoff..][0..n]);
        zoff += n;
    }
    try writeChunk(gpa, &out, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn writeChunk(gpa: Allocator, out: *std.ArrayList(u8), comptime name: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len_buf);
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(name);
    crc.update(data);
    std.mem.writeInt(u32, &len_buf, crc.final(), .big);
    try out.appendSlice(gpa, &len_buf);
}

fn residualCost(row: []const u8) u64 {
    var sum: u64 = 0;
    for (row) |b| sum += @abs(@as(i8, @bitCast(b)));
    return sum;
}

fn applyFilter(ft: u8, cur: []const u8, prev: []const u8, out: []u8, bpp: usize) void {
    out[0] = ft;
    const o = out[1..];
    for (cur, 0..) |x, i| {
        const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const b = prev[i];
        const c: u8 = if (i >= bpp) prev[i - bpp] else 0;
        o[i] = switch (ft) {
            0 => x,
            1 => x -% a,
            2 => x -% b,
            3 => x -% @as(u8, @intCast((@as(u16, a) + b) >> 1)),
            4 => x -% paeth(a, b, c),
            else => unreachable,
        };
    }
}

fn filterRow(mode: FilterMode, cur: []const u8, prev: []const u8, out: []u8, bpp: usize) void {
    switch (mode) {
        .none => applyFilter(0, cur, prev, out, bpp),
        .sub => applyFilter(1, cur, prev, out, bpp),
        .up => applyFilter(2, cur, prev, out, bpp),
        .average => applyFilter(3, cur, prev, out, bpp),
        .paeth => applyFilter(4, cur, prev, out, bpp),
        .adaptive => {
            var best_ft: u8 = 0;
            var best_cost: u64 = std.math.maxInt(u64);
            for (0..5) |ft| {
                applyFilter(@intCast(ft), cur, prev, out, bpp);
                // Filter 0 is scored on raw bytes like libpng (unsigned sum is fine too).
                const cost = residualCost(out[1..]);
                if (cost < best_cost) {
                    best_cost = cost;
                    best_ft = @intCast(ft);
                }
            }
            if (best_ft != 4) applyFilter(best_ft, cur, prev, out, bpp);
        },
    }
}

fn zlibCompress(gpa: Allocator, data: []const u8, mode: Compression) EncodeError![]u8 {
    if (mode == .store) return zlibStore(gpa, data);
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, @max(64, data.len / 4));
    errdefer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    const level: flate.Compress.Options = switch (mode) {
        .fastest => .fastest,
        .default => .default,
        .best => .best,
        .store => unreachable,
    };
    c.* = flate.Compress.init(&aw.writer, window, .zlib, level) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn zlibStore(gpa: Allocator, data: []const u8) EncodeError![]u8 {
    const blocks = @max(1, (data.len + 65534) / 65535);
    const out = try gpa.alloc(u8, 2 + blocks * 5 + data.len + 4);
    out[0] = 0x78;
    out[1] = 0x01;
    var o: usize = 2;
    var i: usize = 0;
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        const n: u16 = @intCast(@min(65535, data.len - i));
        out[o] = @intFromBool(b == blocks - 1);
        std.mem.writeInt(u16, out[o + 1 ..][0..2], n, .little);
        std.mem.writeInt(u16, out[o + 3 ..][0..2], ~n, .little);
        @memcpy(out[o + 5 ..][0..n], data[i..][0..n]);
        o += 5 + n;
        i += n;
    }
    std.mem.writeInt(u32, out[o..][0..4], std.hash.Adler32.hash(data), .big);
    return out;
}

//! Compact zlib/deflate decoder (RFC 1950/1951) for whole-buffer decoding.
//!
//! Why not `std.compress.flate.Decompress`: in Zig 0.16 it trips a std assertion
//! (`Reader.toss`, via `tossBitsShort` whose bounds check adds instead of subtracts
//! `consumed_bits`) on some truncated / corrupt streams — a panic in safe builds and UB in
//! ReleaseFast. Image data is untrusted, so we decode with this small, bounds-checked
//! inflater instead. Because the full output size is known up front (PNG), we decode
//! straight into the destination buffer: no window copies, no streaming state.
const std = @import("std");

pub const Error = error{
    BadZlibHeader,
    InvalidBlockType,
    InvalidStoredLength,
    InvalidHuffmanTable,
    InvalidCode,
    InvalidDistance,
    Truncated,
    OutputOverflow,
    BadChecksum,
};

pub const Result = enum {
    /// Final block decoded (and Adler-32 checked when present and requested).
    complete,
    /// Output buffer filled before the stream ended (extra data ignored).
    output_full,
};

const fast_bits = 10;
const fast_mask = (1 << fast_bits) - 1;

const Huffman = struct {
    /// (len << 9) | symbol; 0 = needs slow path.
    fast: [1 << fast_bits]u16,
    firstcode: [16]u16,
    maxcode: [17]u32,
    firstsymbol: [16]u16,
    size: [288]u8,
    value: [288]u16,

    fn build(h: *Huffman, lens: []const u8) Error!void {
        var counts = [_]u16{0} ** 17;
        var next_code: [16]u32 = undefined;
        @memset(&h.fast, 0);
        for (lens) |l| counts[l] += 1;
        counts[0] = 0;
        for (1..16) |i| {
            if (counts[i] > (@as(u32, 1) << @intCast(i))) return error.InvalidHuffmanTable;
        }
        var code: u32 = 0;
        var k: u32 = 0;
        for (1..16) |i| {
            next_code[i] = code;
            h.firstcode[i] = @intCast(code);
            h.firstsymbol[i] = @intCast(k);
            code += counts[i];
            if (counts[i] != 0 and code - 1 >= (@as(u32, 1) << @intCast(i))) return error.InvalidHuffmanTable;
            h.maxcode[i] = code << @intCast(16 - i);
            code <<= 1;
            k += counts[i];
        }
        h.maxcode[16] = 0x10000;
        for (lens, 0..) |s, sym| {
            if (s == 0) continue;
            const c = next_code[s] - h.firstcode[s] + h.firstsymbol[s];
            h.size[c] = s;
            h.value[c] = @intCast(sym);
            if (s <= fast_bits) {
                var j: u32 = bitReverse(next_code[s], s);
                const entry: u16 = @intCast((@as(u32, s) << 9) | sym);
                while (j < (1 << fast_bits)) : (j += @as(u32, 1) << @intCast(s)) h.fast[j] = entry;
            }
            next_code[s] += 1;
        }
    }
};

fn bitReverse(v: u32, bits: u8) u32 {
    const r: u32 = @bitReverse(@as(u16, @intCast(v & 0xffff)));
    return r >> @intCast(16 - bits);
}

const BitReader = struct {
    src: []const u8,
    pos: usize = 0,
    buf: u64 = 0,
    cnt: u32 = 0,
    /// Zero bytes fed past the end of `src` (lookahead only; consuming them is an error).
    overrun: u32 = 0,

    inline fn refill(br: *BitReader) Error!void {
        if (br.src.len - br.pos >= 8) {
            const w = std.mem.readInt(u64, br.src[br.pos..][0..8], .little);
            br.buf |= w << @intCast(br.cnt);
            br.pos += (63 - br.cnt) >> 3;
            br.cnt |= 56;
            return;
        }
        return br.refillSlow();
    }

    fn refillSlow(br: *BitReader) Error!void {
        @branchHint(.unlikely);
        while (br.cnt < 56) {
            var byte: u64 = 0;
            if (br.pos < br.src.len) {
                byte = br.src[br.pos];
                br.pos += 1;
            } else {
                br.overrun += 1;
                if (br.overrun > 16) return error.Truncated;
            }
            br.buf |= byte << @intCast(br.cnt);
            br.cnt += 8;
        }
    }

    /// Error if any padding bit was consumed.
    fn checkOverrun(br: *const BitReader) Error!void {
        if (br.overrun * 8 > br.cnt) return error.Truncated;
    }

    inline fn bits(br: *BitReader, n: u5) u32 {
        const v: u32 = @intCast(br.buf & ((@as(u64, 1) << n) - 1));
        br.buf >>= n;
        br.cnt -= n;
        return v;
    }

    /// Requires cnt >= n; call refill first.
    inline fn take(br: *BitReader, n: u5) Error!u32 {
        if (br.cnt < n) try br.refill();
        return br.bits(n);
    }

    inline fn decode(br: *BitReader, h: *const Huffman) Error!u32 {
        if (br.cnt < 16) try br.refill();
        const e = h.fast[@intCast(br.buf & fast_mask)];
        if (e != 0) {
            const l: u5 = @intCast(e >> 9);
            br.buf >>= l;
            br.cnt -= l;
            return e & 511;
        }
        return br.decodeSlow(h);
    }

    fn decodeSlow(br: *BitReader, h: *const Huffman) Error!u32 {
        const k: u32 = @bitReverse(@as(u16, @intCast(br.buf & 0xffff)));
        var s: usize = fast_bits + 1;
        while (k >= h.maxcode[s]) s += 1;
        if (s >= 16) return error.InvalidCode;
        const b = (k >> @intCast(16 - s)) -% h.firstcode[s] +% h.firstsymbol[s];
        if (b >= 288 or h.size[b] != s) return error.InvalidCode;
        br.buf >>= @intCast(s);
        br.cnt -= @intCast(s);
        return h.value[b];
    }

    /// Byte position of the next unread byte in `src` after discarding partial bits.
    fn alignedPos(br: *BitReader) Error!usize {
        const drop = br.cnt & 7;
        br.buf >>= @intCast(drop);
        br.cnt -= drop;
        const buffered = br.cnt / 8;
        const p = br.pos + br.overrun - buffered;
        if (p > br.src.len) return error.Truncated;
        return p;
    }

    fn reset(br: *BitReader, p: usize) void {
        br.pos = p;
        br.buf = 0;
        br.cnt = 0;
        br.overrun = 0;
    }
};

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const fixed_tables = blk: {
    @setEvalBranchQuota(100_000);
    var lens: [288]u8 = undefined;
    for (0..144) |i| lens[i] = 8;
    for (144..256) |i| lens[i] = 9;
    for (256..280) |i| lens[i] = 7;
    for (280..288) |i| lens[i] = 8;
    var lit: Huffman = undefined;
    lit.build(&lens) catch unreachable;
    var dist: Huffman = undefined;
    dist.build(&([_]u8{5} ** 30)) catch unreachable;
    const final = [2]Huffman{ lit, dist };
    break :blk final;
};

/// Decode a zlib stream into `out`. Returns `.complete` only if exactly `out.len` bytes
/// were produced; fewer bytes is `error.Truncated`.
pub fn zlibDecompress(src: []const u8, out: []u8, verify_checksum: bool) Error!Result {
    if (src.len < 2) return error.Truncated;
    const cmf = src[0];
    const flg = src[1];
    if (cmf & 0x0f != 8 or cmf >> 4 > 7 or flg & 0x20 != 0 or ((@as(u16, cmf) << 8) | flg) % 31 != 0) return error.BadZlibHeader;
    var br: BitReader = .{ .src = src, .pos = 2 };
    const n = rawInflate(&br, out) catch |err| switch (err) {
        error.OutputOverflow => {
            try br.checkOverrun();
            return .output_full;
        },
        else => return err,
    };
    if (n != out.len) return error.Truncated;
    // Adler-32 trailer: tolerate absence (like stb/libpng in lenient mode), reject mismatch.
    const p = try br.alignedPos();
    if (verify_checksum and src.len - p >= 4) {
        const want = std.mem.readInt(u32, src[p..][0..4], .big);
        if (std.hash.Adler32.hash(out) != want) return error.BadChecksum;
    }
    return .complete;
}

/// Raw deflate into `out`; returns bytes written. `error.OutputOverflow` when the stream
/// would write past `out` (everything up to `out.len` is valid then).
pub fn rawInflate(br: *BitReader, out: []u8) Error!usize {
    var o: usize = 0;
    var lit_dyn: Huffman = undefined;
    var dist_dyn: Huffman = undefined;
    while (true) {
        try br.refill();
        const final = br.bits(1);
        const btype = br.bits(2);
        switch (btype) {
            0 => {
                const p = try br.alignedPos();
                if (br.src.len - p < 4) return error.Truncated;
                const len = std.mem.readInt(u16, br.src[p..][0..2], .little);
                const nlen = std.mem.readInt(u16, br.src[p + 2 ..][0..2], .little);
                if (len != ~nlen) return error.InvalidStoredLength;
                if (br.src.len - p - 4 < len) return error.Truncated;
                const avail = out.len - o;
                const copy = @min(avail, len);
                @memcpy(out[o..][0..copy], br.src[p + 4 ..][0..copy]);
                o += copy;
                if (copy < len) return error.OutputOverflow;
                br.reset(p + 4 + len);
            },
            1 => o = try decodeBlock(br, out, o, &fixed_tables[0], &fixed_tables[1]),
            2 => {
                try readDynamic(br, &lit_dyn, &dist_dyn);
                o = try decodeBlock(br, out, o, &lit_dyn, &dist_dyn);
            },
            else => return error.InvalidBlockType,
        }
        try br.checkOverrun();
        if (final == 1) return o;
    }
}

fn readDynamic(br: *BitReader, lit: *Huffman, dist: *Huffman) Error!void {
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    try br.refill();
    const hlit = br.bits(5) + 257;
    const hdist = br.bits(5) + 1;
    const hclen = br.bits(4) + 4;
    if (hlit > 286 or hdist > 30) return error.InvalidHuffmanTable;
    var cl_lens = [_]u8{0} ** 19;
    for (0..hclen) |i| cl_lens[order[i]] = @intCast(try br.take(3));
    var cl: Huffman = undefined;
    try cl.build(&cl_lens);
    var lens: [286 + 30]u8 = undefined;
    const total = hlit + hdist;
    var n: usize = 0;
    while (n < total) {
        const sym = try br.decode(&cl);
        switch (sym) {
            0...15 => {
                lens[n] = @intCast(sym);
                n += 1;
            },
            16 => {
                if (n == 0) return error.InvalidHuffmanTable;
                const r = 3 + try br.take(2);
                if (n + r > total) return error.InvalidHuffmanTable;
                @memset(lens[n..][0..r], lens[n - 1]);
                n += r;
            },
            17, 18 => {
                const r = if (sym == 17) 3 + try br.take(3) else 11 + try br.take(7);
                if (n + r > total) return error.InvalidHuffmanTable;
                @memset(lens[n..][0..r], 0);
                n += r;
            },
            else => return error.InvalidHuffmanTable,
        }
        try br.checkOverrun();
    }
    if (lens[256] == 0) return error.InvalidHuffmanTable;
    try lit.build(lens[0..hlit]);
    try dist.build(lens[hlit..total]);
}

fn decodeBlock(br: *BitReader, out: []u8, start: usize, lit: *const Huffman, dist: *const Huffman) Error!usize {
    var o = start;
    while (true) {
        try br.refill(); // >= 56 bits: enough for lit(15) + len extra(5) + dist(15) + dist extra(13)
        const sym = try br.decode(lit);
        if (sym < 256) {
            if (o >= out.len) return error.OutputOverflow;
            out[o] = @intCast(sym);
            o += 1;
            continue;
        }
        if (sym == 256) {
            try br.checkOverrun();
            return o;
        }
        const li = sym - 257;
        if (li >= 29) return error.InvalidCode;
        const len: usize = length_base[li] + br.bits(length_extra[li]);
        const ds = try br.decode(dist);
        if (ds >= 30) return error.InvalidCode;
        const d: usize = dist_base[ds] + br.bits(dist_extra[ds]);
        if (d > o) return error.InvalidDistance;
        if (out.len - o < len) {
            // Fill what fits, then report overflow.
            copyMatch(out, o, d, out.len - o);
            return error.OutputOverflow;
        }
        copyMatch(out, o, d, len);
        o += len;
    }
}

inline fn copyMatch(out: []u8, o: usize, d: usize, len: usize) void {
    if (d == 1) {
        @memset(out[o..][0..len], out[o - 1]);
    } else if (d >= len) {
        @memcpy(out[o..][0..len], out[o - d ..][0..len]);
    } else if (d >= 8) {
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            out[o + i ..][0..8].* = out[o + i - d ..][0..8].*;
        }
        while (i < len) : (i += 1) out[o + i] = out[o + i - d];
    } else {
        for (0..len) |i| out[o + i] = out[o + i - d];
    }
}

test "inflate matches std compressor output" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const rand = prng.random();
    for ([_]usize{ 0, 1, 100, 70_000, 300_000 }) |size| {
        const data = try gpa.alloc(u8, size);
        defer gpa.free(data);
        for (data, 0..) |*b, i| b.* = if (rand.intRangeLessThan(u8, 0, 4) == 0) rand.int(u8) else @truncate(i / 37);
        inline for (.{ std.compress.flate.Compress.Options.fastest, std.compress.flate.Compress.Options.best }) |lvl| {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(window);
            const c = try gpa.create(std.compress.flate.Compress);
            defer gpa.destroy(c);
            try aw.ensureUnusedCapacity(64);
            c.* = try .init(&aw.writer, window, .zlib, lvl);
            try c.writer.writeAll(data);
            try c.finish();
            const out = try gpa.alloc(u8, size);
            defer gpa.free(out);
            try std.testing.expectEqual(Result.complete, try zlibDecompress(aw.written(), out, true));
            try std.testing.expectEqualSlices(u8, data, out);
            // Truncations never succeed and never crash.
            const z = aw.written();
            var cut: usize = 0;
            while (cut + 4 < z.len) : (cut += @max(1, z.len / 50)) {
                if (zlibDecompress(z[0..cut], out, true)) |r| {
                    if (size != 0 or r != .output_full) return error.TestUnexpectedResult;
                } else |_| {}
            }
        }
    }
}

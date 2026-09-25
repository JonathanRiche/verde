//! QR Code Model 2 encoder (ISO/IEC 18004) for byte-mode payloads.
//!
//! Allocation-free: the encoded symbol is a fixed-size value, and every
//! intermediate buffer lives on the stack and is zeroed before returning
//! because callers encode one-time pairing secrets. Only byte mode is
//! implemented; it covers every Verde pair link. Mask selection evaluates all
//! eight masks with the standard's four penalty rules and keeps the lowest
//! score, preferring the lower mask number on ties.

// Byte-mode Zig adaptation of Project Nayuki QR Code generator v1.8.0.
// Copyright (c) Project Nayuki. (MIT License)
// https://www.nayuki.io/page/qr-code-generator-library
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
// - The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software.
// - The Software is provided "as is", without warranty of any kind, express or
//   implied, including but not limited to the warranties of merchantability,
//   fitness for a particular purpose and noninfringement. In no event shall the
//   authors or copyright holders be liable for any claim, damages or other
//   liability, whether in an action of contract, tort or otherwise, arising from,
//   out of or in connection with the Software or the use or other dealings in the
//   Software.
//

const std = @import("std");

pub const MIN_VERSION: u8 = 1;
pub const MAX_VERSION: u8 = 40;
/// Side length of a version-40 symbol, the largest QR Code.
pub const MAX_SIZE: usize = 177;

const MAX_MODULES: usize = MAX_SIZE * MAX_SIZE;
/// Total codewords of a version-40 symbol (data plus error correction).
const MAX_CODEWORDS: usize = 3706;
const MAX_ECC_PER_BLOCK: usize = 30;
const MAX_BLOCKS: usize = 81;

const PENALTY_N1: u32 = 3;
const PENALTY_N2: u32 = 3;
const PENALTY_N3: u32 = 40;
const PENALTY_N4: u32 = 10;

/// Error-correction level, weakest to strongest.
pub const Ecc = enum(u2) {
    low,
    medium,
    quartile,
    high,

    /// Two-bit indicator placed in the format information.
    fn formatBits(self: Ecc) u5 {
        return switch (self) {
            .low => 1,
            .medium => 0,
            .quartile => 3,
            .high => 2,
        };
    }
};

pub const EncodeOptions = struct {
    ecc: Ecc = .medium,
    min_version: u8 = MIN_VERSION,
    max_version: u8 = MAX_VERSION,
    /// Forces one mask pattern; null selects the lowest-penalty mask.
    mask: ?u3 = null,
};

pub const EncodeError = error{ InvalidVersionRange, DataTooLong };

const ModuleBits = std.bit_set.StaticBitSet(MAX_MODULES);

/// An encoded symbol. `isDark` is the only reader API renderers need.
pub const QrCode = struct {
    version: u8,
    size: u8,
    ecc: Ecc,
    mask: u3,
    modules: ModuleBits,

    /// Returns whether the module at column `x`, row `y` is dark. Coordinates
    /// outside the symbol (the quiet zone) are light.
    pub fn isDark(self: *const QrCode, x: isize, y: isize) bool {
        if (x < 0 or y < 0 or x >= self.size or y >= self.size) return false;
        return self.modules.isSet(@as(usize, @intCast(y)) * self.size + @as(usize, @intCast(x)));
    }

    /// Clears the modules; call when the payload was secret.
    pub fn wipe(self: *QrCode) void {
        std.crypto.secureZero(usize, &self.modules.masks);
    }
};

pub const HalfBlockOptions = struct {
    /// Light border in modules; the standard asks for four.
    quiet_zone: u8 = 4,
    /// Paints explicit black/white SGR colors so the symbol scans under both
    /// light and dark terminal themes. Without it, the terminal foreground is
    /// assumed to be light (a dark theme).
    ansi_colors: bool = true,
};

/// Encodes `data` in byte mode using the smallest version in the requested
/// range that holds it at the requested error-correction level.
pub fn encodeBytes(data: []const u8, options: EncodeOptions) EncodeError!QrCode {
    if (options.min_version < MIN_VERSION or options.max_version > MAX_VERSION or
        options.min_version > options.max_version)
    {
        return error.InvalidVersionRange;
    }
    const version = version: {
        var candidate = options.min_version;
        while (candidate <= options.max_version) : (candidate += 1) {
            const capacity_bits = @as(usize, numDataCodewords(candidate, options.ecc)) * 8;
            if (data.len <= maxByteCount(candidate) and
                4 + charCountBits(candidate) + data.len * 8 <= capacity_bits)
            {
                break :version candidate;
            }
        }
        return error.DataTooLong;
    };

    var data_codewords: [MAX_CODEWORDS]u8 = undefined;
    defer std.crypto.secureZero(u8, &data_codewords);
    const data_len = numDataCodewords(version, options.ecc);
    buildDataCodewords(data, version, data_codewords[0..data_len]);

    var codewords: [MAX_CODEWORDS]u8 = undefined;
    defer std.crypto.secureZero(u8, &codewords);
    const total_len = addEccAndInterleave(version, options.ecc, data_codewords[0..data_len], &codewords);

    var symbol: Symbol = .init(version);
    defer symbol.wipe();
    symbol.drawFunctionPatterns();
    symbol.drawCodewords(codewords[0..total_len]);

    const mask = options.mask orelse symbol.selectMask(options.ecc);
    symbol.applyMask(mask);
    symbol.drawFormatBits(options.ecc, mask);
    return .{
        .version = version,
        .size = symbol.size,
        .ecc = options.ecc,
        .mask = mask,
        .modules = symbol.modules,
    };
}

/// Writes the symbol as UTF-8 half blocks: one text row per two module rows.
/// Every line ends with `\n`.
pub fn writeHalfBlocks(code: *const QrCode, writer: *std.Io.Writer, options: HalfBlockOptions) std.Io.Writer.Error!void {
    const border: isize = options.quiet_zone;
    const first: isize = -border;
    const end: isize = @as(isize, code.size) + border;
    var y: isize = first;
    while (y < end) : (y += 2) {
        // Foreground is light, background dark: a glyph paints light modules.
        if (options.ansi_colors) try writer.writeAll("\x1b[97;40m");
        var x: isize = first;
        while (x < end) : (x += 1) {
            const top_light = !code.isDark(x, y);
            const bottom_light = y + 1 >= end or !code.isDark(x, y + 1);
            try writer.writeAll(if (top_light and bottom_light)
                "\u{2588}"
            else if (top_light)
                "\u{2580}"
            else if (bottom_light)
                "\u{2584}"
            else
                " ");
        }
        if (options.ansi_colors) try writer.writeAll("\x1b[0m");
        try writer.writeByte('\n');
    }
}

const Symbol = struct {
    size: u8,
    version: u8,
    modules: ModuleBits,
    function: ModuleBits,

    fn init(version: u8) Symbol {
        return .{
            .size = @intCast(@as(u16, version) * 4 + 17),
            .version = version,
            .modules = .initEmpty(),
            .function = .initEmpty(),
        };
    }

    fn wipe(self: *Symbol) void {
        std.crypto.secureZero(usize, &self.modules.masks);
    }

    fn index(self: *const Symbol, x: usize, y: usize) usize {
        return y * self.size + x;
    }

    fn get(self: *const Symbol, x: usize, y: usize) bool {
        return self.modules.isSet(self.index(x, y));
    }

    fn setFunction(self: *Symbol, x: usize, y: usize, dark: bool) void {
        const i = self.index(x, y);
        self.modules.setValue(i, dark);
        self.function.set(i);
    }

    fn drawFunctionPatterns(self: *Symbol) void {
        const size: usize = self.size;
        for (0..size) |i| {
            self.setFunction(6, i, i % 2 == 0);
            self.setFunction(i, 6, i % 2 == 0);
        }
        self.drawFinder(3, 3);
        self.drawFinder(size - 4, 3);
        self.drawFinder(3, size - 4);

        var positions_buffer: [7]u8 = undefined;
        const positions = alignmentPositions(self.version, &positions_buffer);
        for (positions, 0..) |ay, row| {
            for (positions, 0..) |ax, col| {
                const last = positions.len - 1;
                const overlaps_finder = (row == 0 and col == 0) or (row == 0 and col == last) or
                    (row == last and col == 0);
                if (!overlaps_finder) self.drawAlignment(ax, ay);
            }
        }
        // Reserve the format areas now; the real bits are drawn after masking.
        self.drawFormatBits(.medium, 0);
        self.drawVersionBits();
    }

    fn drawFinder(self: *Symbol, center_x: usize, center_y: usize) void {
        const size: isize = self.size;
        var dy: isize = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: isize = -4;
            while (dx <= 4) : (dx += 1) {
                const x = @as(isize, @intCast(center_x)) + dx;
                const y = @as(isize, @intCast(center_y)) + dy;
                if (x < 0 or y < 0 or x >= size or y >= size) continue;
                const distance = @max(@abs(dx), @abs(dy));
                self.setFunction(@intCast(x), @intCast(y), distance != 2 and distance != 4);
            }
        }
    }

    fn drawAlignment(self: *Symbol, center_x: usize, center_y: usize) void {
        var dy: isize = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: isize = -2;
            while (dx <= 2) : (dx += 1) {
                const x: usize = @intCast(@as(isize, @intCast(center_x)) + dx);
                const y: usize = @intCast(@as(isize, @intCast(center_y)) + dy);
                self.setFunction(x, y, @max(@abs(dx), @abs(dy)) != 1);
            }
        }
    }

    fn drawFormatBits(self: *Symbol, ecc: Ecc, mask: u3) void {
        const data: u15 = (@as(u15, ecc.formatBits()) << 3) | mask;
        var remainder: u15 = data;
        for (0..10) |_| remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537);
        const bits: u15 = ((data << 10) | remainder) ^ 0x5412;
        const size: usize = self.size;

        // Copy around the top-left finder.
        for (0..6) |i| self.setFunction(8, i, bitAt(bits, i));
        self.setFunction(8, 7, bitAt(bits, 6));
        self.setFunction(8, 8, bitAt(bits, 7));
        self.setFunction(7, 8, bitAt(bits, 8));
        for (9..15) |i| self.setFunction(14 - i, 8, bitAt(bits, i));

        // Copy split between the other two finders.
        for (0..8) |i| self.setFunction(size - 1 - i, 8, bitAt(bits, i));
        for (8..15) |i| self.setFunction(8, size - 15 + i, bitAt(bits, i));
        self.setFunction(8, size - 8, true); // Always-dark module.
    }

    fn drawVersionBits(self: *Symbol) void {
        if (self.version < 7) return;
        var remainder: u18 = self.version;
        for (0..12) |_| remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25);
        const bits: u18 = (@as(u18, self.version) << 12) | remainder;
        for (0..18) |i| {
            const a: usize = self.size - 11 + i % 3;
            const b: usize = i / 3;
            self.setFunction(a, b, bitAt(bits, i));
            self.setFunction(b, a, bitAt(bits, i));
        }
    }

    /// Places codeword bits in the standard two-column zigzag, skipping
    /// function modules and the vertical timing column. Leftover remainder
    /// modules stay light.
    fn drawCodewords(self: *Symbol, codewords: []const u8) void {
        const size: usize = self.size;
        const total_bits = codewords.len * 8;
        var bit_index: usize = 0;
        var right: usize = size - 1;
        while (right >= 1) {
            if (right == 6) right = 5;
            const upward = ((right + 1) & 2) == 0;
            for (0..size) |vertical| {
                for (0..2) |j| {
                    const x = right - j;
                    const y = if (upward) size - 1 - vertical else vertical;
                    const i = self.index(x, y);
                    if (self.function.isSet(i) or bit_index >= total_bits) continue;
                    const byte = codewords[bit_index >> 3];
                    const shift: u3 = @intCast(7 - (bit_index & 7));
                    self.modules.setValue(i, (byte >> shift) & 1 != 0);
                    bit_index += 1;
                }
            }
            if (right < 2) break;
            right -= 2;
        }
        std.debug.assert(bit_index == total_bits);
    }

    /// XORs the mask onto every non-function module; applying twice undoes it.
    fn applyMask(self: *Symbol, mask: u3) void {
        const size: usize = self.size;
        for (0..size) |y| {
            for (0..size) |x| {
                const i = self.index(x, y);
                if (!self.function.isSet(i) and maskBit(mask, x, y)) self.modules.toggle(i);
            }
        }
    }

    fn selectMask(self: *Symbol, ecc: Ecc) u3 {
        var best_mask: u3 = 0;
        var best_penalty: u32 = std.math.maxInt(u32);
        for (0..8) |candidate| {
            const mask: u3 = @intCast(candidate);
            self.applyMask(mask);
            self.drawFormatBits(ecc, mask);
            const penalty = self.penaltyScore();
            if (penalty < best_penalty) {
                best_penalty = penalty;
                best_mask = mask;
            }
            self.applyMask(mask);
        }
        return best_mask;
    }

    fn penaltyScore(self: *const Symbol) u32 {
        const size: usize = self.size;
        var result: u32 = 0;

        // Rule 1 (runs of five or more) and rule 3 (finder-like 1:1:3:1:1
        // with four light modules on either side), for rows then columns.
        for (0..2) |axis| {
            for (0..size) |line| {
                var run_dark = false;
                var run_length: u32 = 0;
                var history: RunHistory = .{ .size = self.size };
                for (0..size) |along| {
                    const dark = if (axis == 0) self.get(along, line) else self.get(line, along);
                    if (dark == run_dark) {
                        run_length += 1;
                        if (run_length == 5) {
                            result += PENALTY_N1;
                        } else if (run_length > 5) {
                            result += 1;
                        }
                    } else {
                        history.add(run_length);
                        if (!run_dark) result += history.countPatterns() * PENALTY_N3;
                        run_dark = dark;
                        run_length = 1;
                    }
                }
                result += history.terminateAndCount(run_dark, run_length) * PENALTY_N3;
            }
        }

        // Rule 2: 2x2 blocks of one color.
        for (0..size - 1) |y| {
            for (0..size - 1) |x| {
                const color = self.get(x, y);
                if (color == self.get(x + 1, y) and color == self.get(x, y + 1) and
                    color == self.get(x + 1, y + 1))
                {
                    result += PENALTY_N2;
                }
            }
        }

        // Rule 4: dark proportion, 10 points per 5% step away from 50%.
        const total: u32 = @as(u32, self.size) * self.size;
        var dark: u32 = 0;
        for (0..size) |y| {
            for (0..size) |x| {
                if (self.get(x, y)) dark += 1;
            }
        }
        const deviation: u32 = @intCast(@abs(@as(i64, dark) * 20 - @as(i64, total) * 10));
        const steps = (deviation + total - 1) / total - 1;
        result += steps * PENALTY_N4;
        return result;
    }
};

/// The last seven run lengths along a line, newest first, with the symbol's
/// light surround counted as part of the first and final light runs.
const RunHistory = struct {
    size: u8,
    runs: [7]u32 = @splat(0),

    fn add(self: *RunHistory, length: u32) void {
        var run = length;
        if (self.runs[0] == 0) run += self.size;
        std.mem.copyBackwards(u32, self.runs[1..], self.runs[0..6]);
        self.runs[0] = run;
    }

    fn countPatterns(self: *const RunHistory) u32 {
        const r = self.runs;
        const n = r[1];
        const core = n > 0 and r[2] == n and r[3] == n * 3 and r[4] == n and r[5] == n;
        var count: u32 = 0;
        if (core and r[0] >= n * 4 and r[6] >= n) count += 1;
        if (core and r[6] >= n * 4 and r[0] >= n) count += 1;
        return count;
    }

    fn terminateAndCount(self: *RunHistory, run_dark: bool, run_length: u32) u32 {
        var length = run_length;
        if (run_dark) {
            self.add(length);
            length = 0;
        }
        self.add(length + self.size);
        return self.countPatterns();
    }
};

fn buildDataCodewords(data: []const u8, version: u8, out: []u8) void {
    @memset(out, 0);
    var bits: BitWriter = .{ .out = out };
    bits.append(0b0100, 4); // Byte mode.
    bits.append(@intCast(data.len), charCountBits(version));
    for (data) |byte| bits.append(byte, 8);
    const capacity = out.len * 8;
    bits.append(0, @intCast(@min(4, capacity - bits.len)));
    bits.len = std.mem.alignForward(usize, bits.len, 8);
    var pad: u8 = 0xEC;
    var i = bits.len / 8;
    while (i < out.len) : (i += 1) {
        out[i] = pad;
        pad ^= 0xEC ^ 0x11;
    }
}

const BitWriter = struct {
    out: []u8,
    len: usize = 0,

    fn append(self: *BitWriter, value: u16, count: u5) void {
        var remaining = count;
        while (remaining > 0) {
            remaining -= 1;
            if ((value >> @intCast(remaining)) & 1 != 0) {
                self.out[self.len >> 3] |= @as(u8, 0x80) >> @intCast(self.len & 7);
            }
            self.len += 1;
        }
    }
};

/// Splits data into the version's blocks, appends Reed-Solomon codewords to
/// each, and interleaves them column-wise. Returns the codeword count.
fn addEccAndInterleave(version: u8, ecc: Ecc, data: []const u8, out: *[MAX_CODEWORDS]u8) usize {
    const num_blocks: usize = NUM_ERROR_CORRECTION_BLOCKS[@intFromEnum(ecc)][version];
    const ecc_len: usize = ECC_CODEWORDS_PER_BLOCK[@intFromEnum(ecc)][version];
    const raw_codewords: usize = numRawDataModules(version) / 8;
    const num_short_blocks = num_blocks - raw_codewords % num_blocks;
    const short_data_len = raw_codewords / num_blocks - ecc_len;

    var divisor_buffer: [MAX_ECC_PER_BLOCK]u8 = undefined;
    const divisor = reedSolomonDivisor(divisor_buffer[0..ecc_len]);

    var ecc_codewords: [MAX_BLOCKS * MAX_ECC_PER_BLOCK]u8 = undefined;
    defer std.crypto.secureZero(u8, &ecc_codewords);
    var block_starts: [MAX_BLOCKS + 1]usize = undefined;
    var start: usize = 0;
    for (0..num_blocks) |block| {
        block_starts[block] = start;
        const len = short_data_len + @intFromBool(block >= num_short_blocks);
        reedSolomonRemainder(data[start..][0..len], divisor, ecc_codewords[block * ecc_len ..][0..ecc_len]);
        start += len;
    }
    block_starts[num_blocks] = start;
    std.debug.assert(start == data.len);

    var n: usize = 0;
    for (0..short_data_len + 1) |i| {
        for (0..num_blocks) |block| {
            if (block_starts[block] + i >= block_starts[block + 1]) continue;
            out[n] = data[block_starts[block] + i];
            n += 1;
        }
    }
    for (0..ecc_len) |i| {
        for (0..num_blocks) |block| {
            out[n] = ecc_codewords[block * ecc_len + i];
            n += 1;
        }
    }
    std.debug.assert(n == raw_codewords);
    return n;
}

/// Generator polynomial coefficients for `result.len` ECC codewords, highest
/// power first with the implicit leading 1 omitted.
fn reedSolomonDivisor(result: []u8) []const u8 {
    @memset(result, 0);
    result[result.len - 1] = 1;
    var root: u8 = 1;
    for (0..result.len) |_| {
        for (0..result.len) |j| {
            result[j] = gfMultiply(result[j], root);
            if (j + 1 < result.len) result[j] ^= result[j + 1];
        }
        root = gfMultiply(root, 0x02);
    }
    return result;
}

fn reedSolomonRemainder(data: []const u8, divisor: []const u8, result: []u8) void {
    @memset(result, 0);
    for (data) |byte| {
        const factor = byte ^ result[0];
        std.mem.copyForwards(u8, result[0 .. result.len - 1], result[1..]);
        result[result.len - 1] = 0;
        for (result, divisor) |*r, d| r.* ^= gfMultiply(d, factor);
    }
}

/// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
fn gfMultiply(x: u8, y: u8) u8 {
    var z: u16 = 0;
    var i: u4 = 8;
    while (i > 0) {
        i -= 1;
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((y >> @intCast(i)) & 1) * @as(u16, x);
    }
    return @intCast(z);
}

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}

fn bitAt(value: anytype, i: usize) bool {
    return (value >> @intCast(i)) & 1 != 0;
}

fn charCountBits(version: u8) u5 {
    return if (version <= 9) 8 else 16;
}

fn maxByteCount(version: u8) usize {
    return if (version <= 9) 0xFF else 0xFFFF;
}

/// Row/column centers of the alignment patterns, ascending.
fn alignmentPositions(version: u8, buffer: *[7]u8) []const u8 {
    if (version == 1) return buffer[0..0];
    const count: usize = version / 7 + 2;
    const size: usize = @as(usize, version) * 4 + 17;
    const step: usize = (@as(usize, version) * 8 + count * 3 + 5) / (count * 4 - 4) * 2;
    buffer[0] = 6;
    for (1..count) |i| buffer[i] = @intCast(size - 7 - (count - 1 - i) * step);
    return buffer[0..count];
}

/// Modules available for data and ECC codewords (including remainder bits).
fn numRawDataModules(version: u8) usize {
    const v: usize = version;
    var result = (16 * v + 128) * v + 64;
    if (v >= 2) {
        const alignment = v / 7 + 2;
        result -= (25 * alignment - 10) * alignment - 55;
        if (v >= 7) result -= 36;
    }
    return result;
}

fn numDataCodewords(version: u8, ecc: Ecc) usize {
    const e = @intFromEnum(ecc);
    return numRawDataModules(version) / 8 -
        @as(usize, ECC_CODEWORDS_PER_BLOCK[e][version]) * NUM_ERROR_CORRECTION_BLOCKS[e][version];
}

// ISO/IEC 18004 Table 9, indexed [ecc][version]; index 0 is unused.
const ECC_CODEWORDS_PER_BLOCK = [4][41]u8{
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

const NUM_ERROR_CORRECTION_BLOCKS = [4][41]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

// Test fixtures below were generated with Nayuki's qrcodegen 1.8.0 (Python,
// MIT) via QrCode.encode_segments([QrSegment.make_bytes(data)], ecc, 1, 40,
// mask, boost_ecl=False). Matrices are rows of '#' (dark) and '.' (light)
// joined by '\n'; digests are SHA-256 of that text. The sweep payloads come
// from `testPayload`, reproduced in the generator as
// ALPHA[(i * 7 + n) % len(ALPHA)].

const TEST_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789%-_.:/?#&=";

fn testPayload(buffer: []u8, len: usize) []const u8 {
    for (buffer[0..len], 0..) |*byte, i| byte.* = TEST_ALPHABET[(i * 7 + len) % TEST_ALPHABET.len];
    return buffer[0..len];
}

fn testMatrixText(code: *const QrCode, buffer: []u8) []const u8 {
    var n: usize = 0;
    for (0..code.size) |y| {
        if (y > 0) {
            buffer[n] = '\n';
            n += 1;
        }
        for (0..code.size) |x| {
            buffer[n] = if (code.isDark(@intCast(x), @intCast(y))) '#' else '.';
            n += 1;
        }
    }
    return buffer[0..n];
}

fn testDigestHex(code: *const QrCode) [64]u8 {
    var text_buffer: [MAX_SIZE * (MAX_SIZE + 1)]u8 = undefined;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(testMatrixText(code, &text_buffer), &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "byte-mode symbols match qrcodegen reference matrices" {
    const cases = [_]struct { data: []const u8, version: u8, mask: u3, matrix: []const u8 }{
        .{
            .data = "hello",
            .version = 1,
            .mask = 0,
            .matrix =
            \\#######..##...#######
            \\#.....#.##....#.....#
            \\#.###.#..#.##.#.###.#
            \\#.###.#...##..#.###.#
            \\#.###.#.##..#.#.###.#
            \\#.....#.....#.#.....#
            \\#######.#.#.#.#######
            \\..........###........
            \\#.#.#.#..#.#....#..#.
            \\..#.##....#...#....##
            \\.#.#..#.###.#...#####
            \\##..#.........#....#.
            \\.##.#.##..#.#.#.#....
            \\........####.#.#..###
            \\#######...##.###..###
            \\#.....#...####.##....
            \\#.###.#.#.##.###...##
            \\#.###.#..#....##..##.
            \\#.###.#.###.#...#.#.#
            \\#.....#..#....#.#..#.
            \\#######.###.#.##...##
            ,
        },
        .{
            // Pair App Link shape with placeholder host, grant, and code.
            .data = "https://verdeai.dev/pair?host=https%3A%2F%2Fruntime.example.ts.net&grant_id=0123456789abcdef0123456789abcdef#code=" ++ "ab" ** 32,
            .version = 9,
            .mask = 2,
            .matrix =
            \\#######..##...##..##.####..####.##...#.##.#...#######
            \\#.....#....#####..#.#..###...#.######.##.###..#.....#
            \\#.###.#.#..##.#...##.#..##.##.####.....##..#..#.###.#
            \\#.###.#.##.####.#...#.....##.#.....###...##.#.#.###.#
            \\#.###.#.###.#.##...#..#######.#.#..###...##...#.###.#
            \\#.....#.#.......#.#.##..#...##...##.#.##..#...#.....#
            \\#######.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#######
            \\........######.#..#####.#...#.#.#....##.###..........
            \\#.#####....##.#.##.#...######..#...###.#....#.#####..
            \\..####.....#.#..##...##.##..###.#....#.#.###.#.#....#
            \\.#.#..##....##.#.#.#.#.....#.....##.#.###...#.#.###..
            \\..#.#....###.########.###...#.#.##....###.#......#.#.
            \\..#.###.....##.##........##..###...###.....######..##
            \\##.##..##.##.##..######.##.#####....##...##..#.######
            \\##.#..##...##.#.#..#.#.#.#.......####.####.####.###..
            \\##..##......#.#.#...#..###.###.###.....####..#...#...
            \\#..####...##...###.#...#.##.##...####.#...####.##.##.
            \\...##...#.####.###.#.####.#.###.#...##....##.#..#..##
            \\##....####..##.##.##.#.#.........##...#..#..#.######.
            \\...#...#......#.####.####...###.#.##...##.##...#.#.##
            \\##.#..#.###..##.#.#..#..####..#...####...####...#.#..
            \\####......###..#..####.##..#####...###...###.#.##....
            \\.##...####.###......##...#...#.#..###.##...##.##..#..
            \\##...#..#.#...#..#...#.###.######.#...###.####..##.#.
            \\.########.####.#.#......#####.##...###......#####.#..
            \\....#...###.###..###..###...#.##.......######...##..#
            \\....#.#.#....##.###..#..#.#.##..#.#.#.##...##.#.#..#.
            \\..#.#...#.####.#.####...#...#.#.#....#..###.#...##...
            \\..##########..##.#.#....########.#####.#.##.#######..
            \\####.#..#....#...#.#.###..##.###.#.##...####.####..##
            \\...#..###.##.###.####......##.....#.#.#..#.......#...
            \\.##..#.###.##..#.#..##..#.#...#.##.....########.#..##
            \\.##.###.##.###...#......##.....#.#####...##.####..##.
            \\..#.#..#.####......#.###..##.##.#..#.#.#.##..####.###
            \\###..###.#..##..#.#..#...##.#....##.#.#.....##..##...
            \\..##.#..#####.....#..##.##.#...###.#...#####.##.##.##
            \\#....###.##.##..#.#.....##.##.#....###...##.......##.
            \\#....#...#...###.#.#####..#..###...###.#..##...##..##
            \\#..#..#.#..##..##.###.#.##.##....####.#..#...#...##..
            \\.###...#.#...#.##.#.####......#.##.....##.#.#.#.##...
            \\##.##.##.###....###...#....###.#.#.##.#......#....#..
            \\..#.##.#.#.#..##.##..#.#..#.#.#.....##.#####...##...#
            \\##.#####.#....##.##..#..#.#.#..######.##.....#.#.#...
            \\.##......#.####.#.#.#...##...##.##...####.##..##.#.##
            \\...#..##.#.###..#.###..#########.#.##.#..##.#####.#.#
            \\........#..###.####.###.#...#.##...###...####...##.##
            \\#######....#####.##..#.##.#.##...##.#.##...##.#.#..#.
            \\#.....#.#...#.##.###...##...#.#.##...##.#.###...##..#
            \\#.###.#.#.#......#####..#####..#.#.##.##...#########.
            \\#.###.#.##......##.##..###..###.##...#.####.#.##.#..#
            \\#.###.#.###.##.##..###..#.#.#.....#.#.#....#....##.##
            \\#.....#...###..###..###....##.#.##......##.#....#..#.
            \\#######.#.#........#.#.##.#..###...##.#......######..
            ,
        },
    };
    var text_buffer: [MAX_SIZE * (MAX_SIZE + 1)]u8 = undefined;
    for (cases) |case| {
        const code = try encodeBytes(case.data, .{ .ecc = .medium });
        try std.testing.expectEqual(case.version, code.version);
        try std.testing.expectEqual(case.mask, code.mask);
        try std.testing.expectEqualStrings(case.matrix, testMatrixText(&code, &text_buffer));
    }
}

test "version and mask selection match the reference across versions and ECC levels" {
    const cases = [_]struct { ecc: Ecc, len: usize, version: u8, mask: u3, sha256: *const [64]u8 }{
        .{ .ecc = .low, .len = 1, .version = 1, .mask = 7, .sha256 = "945861e321ae7b8d6612b6adbfc9741b18b7e9840b84f9e2f2d0b3622947e920" },
        .{ .ecc = .low, .len = 17, .version = 1, .mask = 2, .sha256 = "39bd177238c989d17b9a7e6e2c2d8d784e4bd3fdbf22229f5dbfec6b18159cf7" },
        .{ .ecc = .low, .len = 40, .version = 3, .mask = 3, .sha256 = "b3417d888d2d0309def3b8384a092b98eec9bc9c7f60639d8c06b7d1c99f7f8b" },
        .{ .ecc = .low, .len = 100, .version = 5, .mask = 2, .sha256 = "2730a3db812f71f7bfcef77b4e55465104643ad85f67c8497fe2e1400b891f0e" },
        .{ .ecc = .low, .len = 180, .version = 8, .mask = 6, .sha256 = "673d315c422531610ac281814002bc5547cb2ae6cacc8bde200f071c04e16189" },
        .{ .ecc = .low, .len = 213, .version = 9, .mask = 2, .sha256 = "6a34af22abb2fb07caa46b4b73b5931ea8280457ed7dfcf0a4ec893d3cc8aad0" },
        .{ .ecc = .low, .len = 300, .version = 11, .mask = 2, .sha256 = "dbe5b95978cb822744763c3dca33cb5ab56d62544d6cafbd38cd493ade228da6" },
        .{ .ecc = .low, .len = 500, .version = 15, .mask = 2, .sha256 = "ce44103a5227007095a0f54af6e7ec448737ca3c45d09dc5901bee39acfc2e01" },
        .{ .ecc = .low, .len = 800, .version = 20, .mask = 2, .sha256 = "97cd4deb3be10c9bbeb3488d1a9e6313163d5a162368ee0d6647533cfd1045ff" },
        .{ .ecc = .low, .len = 1100, .version = 24, .mask = 4, .sha256 = "f0f6cd7f8786d508d5c8a1f364d4c1ccf5609e76d982b315128cd409eb06d144" },
        .{ .ecc = .low, .len = 1500, .version = 28, .mask = 2, .sha256 = "1525838b2ad8633c6d2f0e1cf353a3c3f7dd9f4b4b6857c8154f1e8ffd91aa7f" },
        .{ .ecc = .low, .len = 1800, .version = 31, .mask = 2, .sha256 = "14608a2849e021cbcd96c705248433ebafe030fa2796d64386551613c7855976" },
        .{ .ecc = .low, .len = 2300, .version = 35, .mask = 2, .sha256 = "43335a86d55485d77e07f797f19b8775667a4d5b071cf1422b35357972b92d1b" },
        .{ .ecc = .low, .len = 2900, .version = 40, .mask = 2, .sha256 = "bba2c66c12f992382a813f43bf58c62d23a23ba51860e8d88a5c405b34f7dea1" },
        .{ .ecc = .medium, .len = 1, .version = 1, .mask = 2, .sha256 = "0bff69a51b47a463e3651e29433acb7c5cbab53876e7c5a7003e57117ad56c8d" },
        .{ .ecc = .medium, .len = 17, .version = 2, .mask = 1, .sha256 = "b98adbef8ea7cbc6d2fa74ba525be9826c89acb3775b149d4bd9211909b60472" },
        .{ .ecc = .medium, .len = 40, .version = 3, .mask = 2, .sha256 = "3aeecc12656cfcbacf033b2fff9937567638771b65f1d2cefe2c6d9df86abd17" },
        .{ .ecc = .medium, .len = 100, .version = 6, .mask = 2, .sha256 = "328be0eb9b6c6f31d7fcecfe4f4e090968ef3cb80e96ff4625a1162ec3cfc7bd" },
        .{ .ecc = .medium, .len = 180, .version = 9, .mask = 2, .sha256 = "9ee1691dcc70c4d50821212cae77be62ca042f6a1a47f204c24b0fab63f9f80e" },
        .{ .ecc = .medium, .len = 213, .version = 10, .mask = 2, .sha256 = "2bd4c04997037db720cc91ec2f551f0e5823668510a85ad5435d3cc84c6baa3a" },
        .{ .ecc = .medium, .len = 300, .version = 13, .mask = 2, .sha256 = "49767bb19bf1306bdd8d3b513b17383321c48938a3029bd32acc126e9709581e" },
        .{ .ecc = .medium, .len = 500, .version = 17, .mask = 2, .sha256 = "04e654e54b4c969419b0e22ef2bbb87a1466f98231037c9c29ef0d023bfe6f07" },
        .{ .ecc = .medium, .len = 800, .version = 23, .mask = 2, .sha256 = "309067701726cf94874cce9d9d8c0d4f877dab135d52e52f10ff9b3e0cc29190" },
        .{ .ecc = .medium, .len = 1100, .version = 27, .mask = 2, .sha256 = "0c7ba9e9241dec42aa4633c45625f62bc5f1c452e06e561311118d124de71f84" },
        .{ .ecc = .medium, .len = 1500, .version = 32, .mask = 2, .sha256 = "3c9b264f4c774fd29893bfb1fd38f9fe5b5fa821a8bb06a276191cb10884410b" },
        .{ .ecc = .medium, .len = 1800, .version = 35, .mask = 2, .sha256 = "3fdbcf4214047005f75fd53745797bbb696e51b575fff75399cb670518d92ac2" },
        .{ .ecc = .medium, .len = 2300, .version = 40, .mask = 2, .sha256 = "3839d9248cdcb1d29c99ba89701acf6b4714b3c53fc0beca47e68d7b1a94c78c" },
        .{ .ecc = .quartile, .len = 1, .version = 1, .mask = 4, .sha256 = "8f38163993cb9a739093e27561f3dea4c061f8d44f9259e26c24d7bfff42f581" },
        .{ .ecc = .quartile, .len = 17, .version = 2, .mask = 6, .sha256 = "b0341cdb605d5697013630143b363e1f17043e2e5956625fb4c6d3585c9df18c" },
        .{ .ecc = .quartile, .len = 40, .version = 4, .mask = 6, .sha256 = "0cf3451c92ac1a7ac57b9ae1f899b8e4402f8e1bff8b213625adae51bcad217c" },
        .{ .ecc = .quartile, .len = 100, .version = 8, .mask = 6, .sha256 = "cca47a8a721c8dcc02fa20a7fe46b2d916e65e0933f0d82915f47085add8c522" },
        .{ .ecc = .quartile, .len = 180, .version = 12, .mask = 2, .sha256 = "d0a7a52f4d42b63fe73a6ce29903c58f7b1b4b1068ff18e9263c9e3fa9db96a4" },
        .{ .ecc = .quartile, .len = 213, .version = 13, .mask = 2, .sha256 = "55299e677f234cfa9ad3593a5d029e988ced5acefb81007dce6ea72524dd1b33" },
        .{ .ecc = .quartile, .len = 300, .version = 16, .mask = 2, .sha256 = "f3395862ecf5427ab7f3e99ffc85265ffed5d7c06518d9bee09b8450e7d9115c" },
        .{ .ecc = .quartile, .len = 500, .version = 21, .mask = 4, .sha256 = "c0cdaba2a09d40379d552bfc583a4fa6a257cd2077a31bf3d47b4a42acd9ebb6" },
        .{ .ecc = .quartile, .len = 800, .version = 27, .mask = 2, .sha256 = "93681e71ce3eccc5e104e22283466889c0ef7c1e3ee18c1b534b8dfda910ff16" },
        .{ .ecc = .quartile, .len = 1100, .version = 32, .mask = 2, .sha256 = "8c94ced9f969c4c1ea5d2b26e6249658b8b4d5ffcb486814f727f84061509b7d" },
        .{ .ecc = .quartile, .len = 1500, .version = 39, .mask = 2, .sha256 = "695fa6b4fd53d7759bfeb48d890ef1c5bd1477ce50dac551d4a4012d46fac61d" },
        .{ .ecc = .high, .len = 1, .version = 1, .mask = 5, .sha256 = "711c6114e8abf21d08002b6d2ff6f7838d178428222749aec5400d20cb2dc2ab" },
        .{ .ecc = .high, .len = 17, .version = 3, .mask = 1, .sha256 = "380aecabe317ce25e9978e44f64585d2b76f636f78cda03afddc643b172759f1" },
        .{ .ecc = .high, .len = 40, .version = 5, .mask = 5, .sha256 = "ef992652c0d10e34e658911fae93319434ea87ffdfcef0321b300df885cb0ccf" },
        .{ .ecc = .high, .len = 100, .version = 10, .mask = 7, .sha256 = "f60d2724c9fc883c5f2261cba02f45d8fa4abe613441430ad4f03501b0ab4d8c" },
        .{ .ecc = .high, .len = 180, .version = 14, .mask = 2, .sha256 = "c585c7249a41186b516e2d34ee535815714cff956d827fbb78ee57196c275ccf" },
        .{ .ecc = .high, .len = 213, .version = 15, .mask = 3, .sha256 = "647734960ab780d578ac3430db9c3ce0d3e8154d62c2d3c4f4f4f21a28038c4b" },
        .{ .ecc = .high, .len = 300, .version = 18, .mask = 2, .sha256 = "70ee7dd95f0eaebacb7d64cf29a59e80b81bcd0cd2a458d93b516d0ff619af12" },
        .{ .ecc = .high, .len = 500, .version = 24, .mask = 4, .sha256 = "f71bb72f0713d267458d98b7ffabf5a964ad84e8a9733557534050d31604fe82" },
        .{ .ecc = .high, .len = 800, .version = 32, .mask = 2, .sha256 = "6bfaa2ba7eab3d83a66115cf7b5661f8b447278070e76283e8d8263dcc9bfd75" },
        .{ .ecc = .high, .len = 1100, .version = 38, .mask = 2, .sha256 = "965f0c90592fb4926e16615f9eddf61c14a9919a4020c75a0bfcbc42f1d6a397" },
    };
    var payload_buffer: [2953]u8 = undefined;
    for (cases) |case| {
        const code = try encodeBytes(testPayload(&payload_buffer, case.len), .{ .ecc = case.ecc });
        try std.testing.expectEqual(case.version, code.version);
        try std.testing.expectEqual(case.mask, code.mask);
        try std.testing.expectEqualStrings(case.sha256, &testDigestHex(&code));
    }
}

test "every forced mask matches the reference" {
    const digests = [8]*const [64]u8{
        "0b5f192c6bca0192703b29bc8492cce7fddde881294d3f97e409fbedc13ff646",
        "c89ac272dbf38ec89b209ef829d30c452a98337dce93fea4e958f85043191531",
        "49767bb19bf1306bdd8d3b513b17383321c48938a3029bd32acc126e9709581e",
        "ca198fda21a09756fd64cf8d7d6b1ae849966745aae970f01230daf6f59bdceb",
        "86ce0c7c2655a34bc7c5523c6801a6d39dabf59a84f4aa1dc36dd16af04056b7",
        "368ebf175a3dd041ed58d0741b0705ba9efbc166453f6ffcb1df04e6862b4055",
        "ca5e586b038b3723eaf3ffac9d0da5c12c4bb6f49eca4e52badae21bdea34705",
        "a831b5e8561c88a3497d9c7c00652d90643371677bff4240179520a154ccc1ae",
    };
    var payload_buffer: [300]u8 = undefined;
    const data = testPayload(&payload_buffer, 300);
    for (digests, 0..) |digest, mask| {
        const code = try encodeBytes(data, .{ .ecc = .medium, .mask = @intCast(mask) });
        try std.testing.expectEqual(@as(u8, 13), code.version);
        try std.testing.expectEqualStrings(digest, &testDigestHex(&code));
    }
}

test "rejects payloads beyond the requested versions" {
    var payload_buffer: [2954]u8 = undefined;
    // 2953 bytes is the version-40-L byte-mode capacity.
    _ = try encodeBytes(testPayload(&payload_buffer, 2953), .{ .ecc = .low });
    try std.testing.expectError(error.DataTooLong, encodeBytes(testPayload(&payload_buffer, 2954), .{ .ecc = .low }));
    // 180 bytes is the version-9-M capacity; one more needs version 10.
    const fits = try encodeBytes(testPayload(&payload_buffer, 180), .{ .max_version = 9 });
    try std.testing.expectEqual(@as(u8, 9), fits.version);
    try std.testing.expectError(error.DataTooLong, encodeBytes(testPayload(&payload_buffer, 181), .{ .max_version = 9 }));
    try std.testing.expectError(error.InvalidVersionRange, encodeBytes("x", .{ .min_version = 0 }));
    try std.testing.expectError(error.InvalidVersionRange, encodeBytes("x", .{ .min_version = 5, .max_version = 4 }));
    try std.testing.expectError(error.InvalidVersionRange, encodeBytes("x", .{ .max_version = 41 }));
}

test "half-block rendering round-trips every module and the quiet zone" {
    var code = try encodeBytes("https://verdeai.dev/pair", .{});
    defer code.wipe();
    var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rendered.deinit();
    const quiet_zone: u8 = 4;
    try writeHalfBlocks(&code, &rendered.writer, .{ .quiet_zone = quiet_zone, .ansi_colors = false });

    const width: usize = @as(usize, code.size) + 2 * quiet_zone;
    var lines = std.mem.splitScalar(u8, rendered.written(), '\n');
    var row: isize = -@as(isize, quiet_zone);
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        line_count += 1;
        var cells = (try std.unicode.Utf8View.init(line)).iterator();
        var column: isize = -@as(isize, quiet_zone);
        var cell_count: usize = 0;
        while (cells.nextCodepoint()) |glyph| : (column += 1) {
            cell_count += 1;
            const top_light, const bottom_light = switch (glyph) {
                0x2588 => .{ true, true },
                0x2580 => .{ true, false },
                0x2584 => .{ false, true },
                ' ' => .{ false, false },
                else => return error.UnexpectedGlyph,
            };
            try std.testing.expectEqual(!code.isDark(column, row), top_light);
            if (row + 1 < @as(isize, code.size) + quiet_zone) {
                try std.testing.expectEqual(!code.isDark(column, row + 1), bottom_light);
            }
        }
        try std.testing.expectEqual(width, cell_count);
        row += 2;
    }
    try std.testing.expectEqual((width + 1) / 2, line_count);

    var colored: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer colored.deinit();
    try writeHalfBlocks(&code, &colored.writer, .{});
    try std.testing.expect(std.mem.startsWith(u8, colored.written(), "\x1b[97;40m"));
    try std.testing.expect(std.mem.endsWith(u8, colored.written(), "\x1b[0m\n"));
}

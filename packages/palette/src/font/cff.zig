//! CFF (version 1) outlines: Type 2 charstring interpreter with local/global subroutines and
//! CID-keyed fonts (FDArray/FDSelect). Hints are parsed and ignored (we rasterize unhinted).
//! Not supported: `seac`-style accented endchar, deprecated arithmetic operators, CFF2 (blend /
//! variation data). Unsupported constructs end the glyph early rather than failing hard.

const std = @import("std");
const sfnt = @import("sfnt.zig");
const Error = sfnt.Error;

const Index = struct {
    data: []const u8 = &.{},
    count: u32 = 0,
    off_size: u8 = 0,
    offsets: usize = 0,
    base: usize = 0, // index of byte preceding object data
    /// Total byte length of the INDEX structure.
    len: usize = 2,

    fn parse(d: []const u8, at: usize) Error!Index {
        const count = try sfnt.u16At(d, at);
        if (count == 0) return .{ .data = d, .len = 2 };
        const off_size = try sfnt.u8At(d, at + 2);
        if (off_size < 1 or off_size > 4) return error.InvalidFont;
        const offsets = at + 3;
        const base = offsets + (@as(usize, count) + 1) * off_size - 1;
        var idx: Index = .{ .data = d, .count = count, .off_size = off_size, .offsets = offsets, .base = base };
        const last = try idx.offsetAt(count);
        idx.len = base + last - at;
        if (base + last > d.len) return error.InvalidFont;
        return idx;
    }

    fn offsetAt(self: Index, i: usize) Error!usize {
        const p = self.offsets + i * self.off_size;
        _ = try sfnt.sub(self.data, p, self.off_size);
        var v: usize = 0;
        for (self.data[p..][0..self.off_size]) |b| v = (v << 8) | b;
        return v;
    }

    fn get(self: Index, i: usize) Error![]const u8 {
        if (i >= self.count) return error.InvalidFont;
        const a = try self.offsetAt(i);
        const b = try self.offsetAt(i + 1);
        if (a == 0 or b < a) return error.InvalidFont;
        return sfnt.sub(self.data, self.base + a, b - a);
    }
};

const Dict = struct {
    /// Finds `op` (two-byte ops encoded as 1200+second) and returns up to 4 operands.
    fn find(d: []const u8, op: u16) ?[4]f64 {
        var stack: [48]f64 = undefined;
        var n: usize = 0;
        var p: usize = 0;
        while (p < d.len) {
            const b = d[p];
            if (b <= 21) {
                var code: u16 = b;
                p += 1;
                if (b == 12) {
                    if (p >= d.len) return null;
                    code = 1200 + @as(u16, d[p]);
                    p += 1;
                }
                if (code == op) {
                    var out: [4]f64 = .{ 0, 0, 0, 0 };
                    for (0..@min(n, 4)) |i| out[i] = stack[i];
                    return out;
                }
                n = 0;
                continue;
            }
            var v: f64 = 0;
            if (b == 28) {
                const x = sfnt.i16At(d, p + 1) catch return null;
                v = @floatFromInt(x);
                p += 3;
            } else if (b == 29) {
                const x = sfnt.i32At(d, p + 1) catch return null;
                v = @floatFromInt(x);
                p += 5;
            } else if (b == 30) {
                // Real: skip nibbles (values we need are integers).
                p += 1;
                while (p < d.len) : (p += 1) {
                    if (d[p] & 0x0F == 0x0F or d[p] >> 4 == 0x0F) break;
                }
                p += 1;
                v = 0;
            } else if (b >= 32 and b <= 246) {
                v = @floatFromInt(@as(i32, b) - 139);
                p += 1;
            } else if (b >= 247 and b <= 250) {
                const b1 = sfnt.u8At(d, p + 1) catch return null;
                v = @floatFromInt((@as(i32, b) - 247) * 256 + b1 + 108);
                p += 2;
            } else if (b >= 251 and b <= 254) {
                const b1 = sfnt.u8At(d, p + 1) catch return null;
                v = @floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, b1) - 108);
                p += 2;
            } else return null;
            if (n < stack.len) {
                stack[n] = v;
                n += 1;
            }
        }
        return null;
    }
};

fn subrBias(count: u32) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

pub const Cff = struct {
    data: []const u8,
    char_strings: Index,
    global_subrs: Index,
    local_subrs: Index,
    /// CID-keyed fonts.
    fd_array: ?Index = null,
    fd_select: usize = 0,

    pub fn init(d: []const u8) Error!Cff {
        const major = try sfnt.u8At(d, 0);
        if (major != 1) return error.UnsupportedFont;
        const hdr = try sfnt.u8At(d, 2);
        const names = try Index.parse(d, hdr);
        const top_dicts = try Index.parse(d, hdr + names.len);
        const strings = try Index.parse(d, hdr + names.len + top_dicts.len);
        const gsubrs = try Index.parse(d, hdr + names.len + top_dicts.len + strings.len);
        const top = try top_dicts.get(0);
        if (Dict.find(top, 1206)) |cs_type| if (cs_type[0] != 2) return error.UnsupportedFont;
        const cs_off = Dict.find(top, 17) orelse return error.InvalidFont;
        const char_strings = try Index.parse(d, try toOff(cs_off[0]));
        var self: Cff = .{ .data = d, .char_strings = char_strings, .global_subrs = gsubrs, .local_subrs = .{ .data = d } };
        if (Dict.find(top, 1230) != null) {
            // CID-keyed.
            const fda = Dict.find(top, 1236) orelse return error.InvalidFont;
            const fds = Dict.find(top, 1237) orelse return error.InvalidFont;
            self.fd_array = try Index.parse(d, try toOff(fda[0]));
            self.fd_select = try toOff(fds[0]);
        } else if (Dict.find(top, 18)) |priv| {
            self.local_subrs = try privateSubrs(d, priv);
        }
        return self;
    }

    fn toOff(v: f64) Error!usize {
        if (!(v >= 0 and v < 1 << 31)) return error.InvalidFont;
        return @intFromFloat(v);
    }

    fn privateSubrs(d: []const u8, priv: [4]f64) Error!Index {
        const size = try toOff(priv[0]);
        const off = try toOff(priv[1]);
        const pd = try sfnt.sub(d, off, size);
        if (Dict.find(pd, 19)) |subrs| {
            return Index.parse(d, off + try toOff(subrs[0]));
        }
        return .{ .data = d };
    }

    fn localSubrsFor(self: *const Cff, glyph: u32) Error!Index {
        const fda = self.fd_array orelse return self.local_subrs;
        const d = self.data;
        const fmt = try sfnt.u8At(d, self.fd_select);
        var fd: usize = 0;
        switch (fmt) {
            0 => fd = try sfnt.u8At(d, self.fd_select + 1 + glyph),
            3 => {
                const n = try sfnt.u16At(d, self.fd_select + 1);
                var found = false;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const rec = self.fd_select + 3 + i * 3;
                    const first = try sfnt.u16At(d, rec);
                    const next = try sfnt.u16At(d, rec + 3);
                    if (glyph >= first and glyph < next) {
                        fd = try sfnt.u8At(d, rec + 2);
                        found = true;
                        break;
                    }
                }
                if (!found) return error.InvalidFont;
            },
            else => return error.InvalidFont,
        }
        const font_dict = try fda.get(fd);
        const priv = Dict.find(font_dict, 18) orelse return .{ .data = d };
        return privateSubrs(d, priv);
    }

    pub fn outline(self: *const Cff, glyph: u32, sink: anytype) Error!void {
        const cs = try self.char_strings.get(glyph);
        var interp: Interp(@TypeOf(sink)) = .{
            .sink = sink,
            .gsubrs = self.global_subrs,
            .lsubrs = try self.localSubrsFor(glyph),
        };
        interp.run(cs, 0) catch |e| switch (e) {
            error.EndChar => {},
            error.InvalidFont, error.UnsupportedFont, error.FaceIndexOutOfRange => |err| {
                interp.closeIfOpen();
                return err;
            },
        };
        interp.closeIfOpen();
    }
};

fn Interp(comptime Sink: type) type {
    return struct {
        const Self = @This();
        sink: Sink,
        gsubrs: Index,
        lsubrs: Index,
        stack: [48]f32 = undefined,
        sp: usize = 0,
        x: f32 = 0,
        y: f32 = 0,
        n_stems: usize = 0,
        have_width: bool = false,
        open: bool = false,

        const RunError = Error || error{EndChar};

        fn push(self: *Self, v: f32) RunError!void {
            if (self.sp >= self.stack.len) return error.InvalidFont;
            self.stack[self.sp] = v;
            self.sp += 1;
        }

        fn closeIfOpen(self: *Self) void {
            if (self.open) {
                self.sink.close();
                self.open = false;
            }
        }

        fn moveTo(self: *Self, dx: f32, dy: f32) void {
            self.closeIfOpen();
            self.x += dx;
            self.y += dy;
            self.sink.moveTo(self.x, self.y);
            self.open = true;
        }
        fn lineTo(self: *Self, dx: f32, dy: f32) void {
            if (!self.open) self.moveTo(0, 0);
            self.x += dx;
            self.y += dy;
            self.sink.lineTo(self.x, self.y);
        }
        fn curveTo(self: *Self, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) void {
            if (!self.open) self.moveTo(0, 0);
            const x1 = self.x + dx1;
            const y1 = self.y + dy1;
            const x2 = x1 + dx2;
            const y2 = y1 + dy2;
            self.x = x2 + dx3;
            self.y = y2 + dy3;
            self.sink.cubicTo(x1, y1, x2, y2, self.x, self.y);
        }

        /// Strips an optional leading width argument for ops whose arg count parity reveals it.
        fn takeWidth(self: *Self, odd_means_width: bool) usize {
            var base: usize = 0;
            if (!self.have_width) {
                self.have_width = true;
                if (odd_means_width and self.sp % 2 == 1) base = 1;
            }
            return base;
        }

        fn run(self: *Self, cs: []const u8, depth: u8) RunError!void {
            if (depth > 10) return error.InvalidFont;
            var p: usize = 0;
            while (p < cs.len) {
                const b = cs[p];
                p += 1;
                if (b >= 32 or b == 28) {
                    if (b == 28) {
                        const v = try sfnt.i16At(cs, p);
                        p += 2;
                        try self.push(@floatFromInt(v));
                    } else if (b <= 246) {
                        try self.push(@floatFromInt(@as(i32, b) - 139));
                    } else if (b <= 250) {
                        const b1 = try sfnt.u8At(cs, p);
                        p += 1;
                        try self.push(@floatFromInt((@as(i32, b) - 247) * 256 + b1 + 108));
                    } else if (b <= 254) {
                        const b1 = try sfnt.u8At(cs, p);
                        p += 1;
                        try self.push(@floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, b1) - 108));
                    } else {
                        const v = try sfnt.i32At(cs, p);
                        p += 4;
                        try self.push(@as(f32, @floatFromInt(v)) / 65536.0);
                    }
                    continue;
                }
                const s = self.stack[0..self.sp];
                switch (b) {
                    1, 3, 18, 23 => { // hstem vstem hstemhm vstemhm
                        const base = self.takeWidth(true);
                        self.n_stems += (self.sp - base) / 2;
                        self.sp = 0;
                    },
                    19, 20 => { // hintmask cntrmask
                        const base = self.takeWidth(true);
                        self.n_stems += (self.sp - base) / 2;
                        self.sp = 0;
                        p += (self.n_stems + 7) / 8;
                    },
                    21 => { // rmoveto
                        const base = if (!self.have_width and self.sp > 2) blk: {
                            self.have_width = true;
                            break :blk @as(usize, 1);
                        } else blk: {
                            self.have_width = true;
                            break :blk @as(usize, 0);
                        };
                        if (self.sp < base + 2) return error.InvalidFont;
                        self.moveTo(s[base], s[base + 1]);
                        self.sp = 0;
                    },
                    22, 4 => { // hmoveto vmoveto
                        const base = if (!self.have_width and self.sp > 1) blk: {
                            self.have_width = true;
                            break :blk @as(usize, 1);
                        } else blk: {
                            self.have_width = true;
                            break :blk @as(usize, 0);
                        };
                        if (self.sp < base + 1) return error.InvalidFont;
                        if (b == 22) self.moveTo(s[base], 0) else self.moveTo(0, s[base]);
                        self.sp = 0;
                    },
                    5 => { // rlineto
                        var i: usize = 0;
                        while (i + 1 < s.len) : (i += 2) self.lineTo(s[i], s[i + 1]);
                        self.sp = 0;
                    },
                    6, 7 => { // hlineto vlineto
                        var horizontal = b == 6;
                        for (s) |v| {
                            if (horizontal) self.lineTo(v, 0) else self.lineTo(0, v);
                            horizontal = !horizontal;
                        }
                        self.sp = 0;
                    },
                    8 => { // rrcurveto
                        var i: usize = 0;
                        while (i + 5 < s.len) : (i += 6) self.curveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                        self.sp = 0;
                    },
                    24 => { // rcurveline
                        if (s.len < 8) return error.InvalidFont;
                        var i: usize = 0;
                        while (i + 6 <= s.len - 2) : (i += 6) self.curveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                        self.lineTo(s[i], s[i + 1]);
                        self.sp = 0;
                    },
                    25 => { // rlinecurve
                        if (s.len < 8) return error.InvalidFont;
                        var i: usize = 0;
                        while (i + 2 <= s.len - 6) : (i += 2) self.lineTo(s[i], s[i + 1]);
                        self.curveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                        self.sp = 0;
                    },
                    26 => { // vvcurveto: dx1? {dya dxb dyb dyc}+
                        var i: usize = 0;
                        var dx1: f32 = 0;
                        if (s.len % 2 == 1) {
                            dx1 = s[0];
                            i = 1;
                        }
                        while (i + 3 < s.len) : (i += 4) {
                            self.curveTo(dx1, s[i], s[i + 1], s[i + 2], 0, s[i + 3]);
                            dx1 = 0;
                        }
                        self.sp = 0;
                    },
                    27 => { // hhcurveto: dy1? {dxa dxb dyb dxc}+
                        var i: usize = 0;
                        var dy1: f32 = 0;
                        if (s.len % 2 == 1) {
                            dy1 = s[0];
                            i = 1;
                        }
                        while (i + 3 < s.len) : (i += 4) {
                            self.curveTo(s[i], dy1, s[i + 1], s[i + 2], s[i + 3], 0);
                            dy1 = 0;
                        }
                        self.sp = 0;
                    },
                    30, 31 => { // vhcurveto hvcurveto
                        var horizontal = b == 31;
                        var i: usize = 0;
                        while (i + 3 < s.len) : (i += 4) {
                            const last = s.len - i == 5;
                            const extra: f32 = if (last) s[i + 4] else 0;
                            if (horizontal) {
                                self.curveTo(s[i], 0, s[i + 1], s[i + 2], extra, s[i + 3]);
                            } else {
                                self.curveTo(0, s[i], s[i + 1], s[i + 2], s[i + 3], extra);
                            }
                            horizontal = !horizontal;
                        }
                        self.sp = 0;
                    },
                    10, 29 => { // callsubr callgsubr
                        if (self.sp == 0) return error.InvalidFont;
                        self.sp -= 1;
                        const subrs = if (b == 10) self.lsubrs else self.gsubrs;
                        const idx_f = self.stack[self.sp] + @as(f32, @floatFromInt(subrBias(subrs.count)));
                        if (!(idx_f >= 0 and idx_f < @as(f32, @floatFromInt(subrs.count)))) return error.InvalidFont;
                        const sub_cs = try subrs.get(@intFromFloat(idx_f));
                        try self.run(sub_cs, depth + 1);
                    },
                    11 => return, // return
                    14 => { // endchar
                        if (!self.have_width and (self.sp == 1 or self.sp == 5)) self.have_width = true;
                        self.closeIfOpen();
                        return error.EndChar;
                    },
                    12 => {
                        const b2 = try sfnt.u8At(cs, p);
                        p += 1;
                        switch (b2) {
                            35 => { // flex
                                if (s.len < 13) return error.InvalidFont;
                                self.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
                                self.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
                            },
                            34 => { // hflex
                                if (s.len < 7) return error.InvalidFont;
                                const y0 = self.y;
                                self.curveTo(s[0], 0, s[1], s[2], s[3], 0);
                                self.curveTo(s[4], 0, s[5], y0 - self.y, s[6], 0);
                            },
                            36 => { // hflex1
                                if (s.len < 9) return error.InvalidFont;
                                self.curveTo(s[0], s[1], s[2], s[3], s[4], 0);
                                self.curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
                            },
                            37 => { // flex1
                                if (s.len < 11) return error.InvalidFont;
                                const x0 = self.x;
                                const y0 = self.y;
                                var dx: f32 = 0;
                                var dy: f32 = 0;
                                var k: usize = 0;
                                while (k < 10) : (k += 2) {
                                    dx += s[k];
                                    dy += s[k + 1];
                                }
                                self.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
                                if (@abs(dx) > @abs(dy)) {
                                    self.curveTo(s[6], s[7], s[8], s[9], s[10], (y0 - self.y) - s[7] - s[9]);
                                } else {
                                    self.curveTo(s[6], s[7], s[8], s[9], (x0 - self.x) - s[6] - s[8], s[10]);
                                }
                            },
                            else => {},
                        }
                        self.sp = 0;
                    },
                    else => self.sp = 0,
                }
            }
        }
    };
}

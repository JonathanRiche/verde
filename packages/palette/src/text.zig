//! Palette-owned text metrics, UTF-8 decoding, and run placement.
//!
//! This module intentionally does not do complex shaping. It decodes UTF-8 to
//! Unicode scalar values, maps invalid byte sequences to U+FFFD, and uses one
//! advance per scalar value. Hosts that need GPU drawing should consume the
//! positioned runs or glyph placements emitted here instead of measuring text
//! independently.

const std = @import("std");

const draw = @import("draw.zig");
const text_layout = @import("text_layout.zig");

pub const replacement_codepoint: u21 = 0xfffd;

pub const DecodePolicy = enum {
    replacement,
    skip,
};

pub const FontFace = struct {
    bytes: []const u8 = "",
    metrics: Metrics = .{},
    decode_policy: DecodePolicy = .replacement,

    pub fn init(bytes: []const u8, metrics: Metrics) FontFace {
        return .{ .bytes = bytes, .metrics = metrics };
    }

    pub fn defaultUi(bytes: []const u8, font_size: f32) FontFace {
        return .{ .bytes = bytes, .metrics = Metrics.defaultUi(font_size) };
    }

    pub fn fontMetrics(self: *const FontFace) text_layout.FontMetrics {
        return .{
            .font_size = self.metrics.font_size,
            .line_height = self.metrics.line_height,
            .fixed_advance = null,
            .ascent = self.metrics.ascent,
            .descent = self.metrics.descent,
            .baseline = self.metrics.ascent,
            .context = @constCast(self),
            .advance = advanceCallback,
        };
    }

    pub fn measureRun(self: *const FontFace, text: []const u8) f32 {
        return self.fontMetrics().measureSlice(text);
    }

    pub fn lineHeight(self: *const FontFace) f32 {
        return self.metrics.line_height;
    }

    pub fn advance(self: *const FontFace, codepoint: u21) f32 {
        return self.metrics.advance(codepoint);
    }
};

pub const Metrics = struct {
    font_size: f32 = 16.0,
    line_height: f32 = 20.0,
    ascent: f32 = 15.0,
    descent: f32 = 5.0,
    ascii_advance: f32 = 8.8,
    space_advance: f32 = 4.4,
    cjk_advance: f32 = 16.0,
    emoji_advance: f32 = 16.0,
    missing_advance: f32 = 8.8,

    pub fn defaultUi(font_size: f32) Metrics {
        return .{
            .font_size = font_size,
            .line_height = font_size * 1.25,
            .ascent = font_size * 0.82,
            .descent = font_size * 0.25,
            .ascii_advance = font_size * 0.55,
            .space_advance = font_size * 0.32,
            .cjk_advance = font_size,
            .emoji_advance = font_size,
            .missing_advance = font_size * 0.55,
        };
    }

    pub fn advance(self: Metrics, codepoint: u21) f32 {
        if (codepoint == '\t') return self.space_advance * 4.0;
        if (codepoint == ' ' or codepoint == 0x00a0) return self.space_advance;
        if (isCjk(codepoint)) return self.cjk_advance;
        if (isEmoji(codepoint)) return self.emoji_advance;
        if (codepoint >= 0x20 and codepoint < 0x7f) return self.ascii_advance;
        if (codepoint == replacement_codepoint) return self.missing_advance;
        return self.missing_advance;
    }
};

pub const GlyphPlacement = struct {
    codepoint: u21,
    byte_start: usize,
    byte_len: usize,
    x: f32,
    y: f32,
    advance: f32,
    font_size: f32,
    color: draw.Color,
    clip: ?draw.Rect = null,
};

pub const PlaceOptions = struct {
    rect: draw.Rect,
    text: []const u8,
    color: draw.Color,
    font: *const FontFace,
    font_role: ?draw.FontRole = null,
    font_id: ?u32 = null,
    wrap: bool = true,
    scroll: draw.Vec2 = .{},
    clip: ?draw.Rect = null,
};

pub fn measureRun(font: *const FontFace, text: []const u8) f32 {
    return font.measureRun(text);
}

pub fn appendRuns(allocator: std.mem.Allocator, options: PlaceOptions, out: *std.ArrayList(draw.TextRun)) !void {
    try text_layout.appendRuns(allocator, .{
        .rect = options.rect,
        .text = options.text,
        .color = options.color,
        .metrics = options.font.fontMetrics(),
        .font_role = options.font_role,
        .font_id = options.font_id,
        .wrap = options.wrap,
        .scroll = options.scroll,
        .clip = options.clip,
    }, out);
}

pub fn appendTextToBatch(allocator: std.mem.Allocator, batch: *draw.RenderBatch, options: PlaceOptions) !void {
    var runs: std.ArrayList(draw.TextRun) = .empty;
    defer runs.deinit(allocator);
    try appendRuns(allocator, options, &runs);
    try batch.textRuns(
        allocator,
        options.rect,
        options.text,
        runs.items,
        options.color,
        options.font.metrics.font_size,
        options.clip,
        options.font.metrics.line_height,
        options.font.metrics.ascii_advance,
    );
}

pub fn appendGlyphs(allocator: std.mem.Allocator, options: PlaceOptions, out: *std.ArrayList(GlyphPlacement)) !void {
    var iter = Iterator.init(options.text, options.font.decode_policy);
    var x = options.rect.x - options.scroll.x;
    var y = options.rect.y - options.scroll.y;
    const max_x = options.rect.x + @max(options.rect.w, 1.0);
    while (iter.next()) |decoded| {
        if (decoded.codepoint == '\n') {
            x = options.rect.x - options.scroll.x;
            y += options.font.metrics.line_height;
            continue;
        }
        const advance_width = options.font.advance(decoded.codepoint);
        if (options.wrap and x > options.rect.x and x + advance_width > max_x) {
            x = options.rect.x - options.scroll.x;
            y += options.font.metrics.line_height;
        }
        if (options.clip == null or rectIntersectsY(options.clip.?, y, options.font.metrics.line_height)) {
            try out.append(allocator, .{
                .codepoint = decoded.codepoint,
                .byte_start = decoded.byte_start,
                .byte_len = decoded.byte_len,
                .x = x,
                .y = y,
                .advance = advance_width,
                .font_size = options.font.metrics.font_size,
                .color = options.color,
                .clip = options.clip,
            });
        }
        x += advance_width;
    }
}

pub const Decoded = struct {
    codepoint: u21,
    byte_start: usize,
    byte_len: usize,
};

pub const Iterator = struct {
    text: []const u8,
    index: usize = 0,
    policy: DecodePolicy = .replacement,

    pub fn init(text: []const u8, policy: DecodePolicy) Iterator {
        return .{ .text = text, .policy = policy };
    }

    pub fn next(self: *Iterator) ?Decoded {
        while (self.index < self.text.len) {
            const start = self.index;
            const len = std.unicode.utf8ByteSequenceLength(self.text[start]) catch {
                self.index += 1;
                if (self.policy == .skip) continue;
                return .{ .codepoint = replacement_codepoint, .byte_start = start, .byte_len = 1 };
            };
            if (start + len > self.text.len) {
                self.index += 1;
                if (self.policy == .skip) continue;
                return .{ .codepoint = replacement_codepoint, .byte_start = start, .byte_len = 1 };
            }
            const cp = std.unicode.utf8Decode(self.text[start .. start + len]) catch {
                self.index += 1;
                if (self.policy == .skip) continue;
                return .{ .codepoint = replacement_codepoint, .byte_start = start, .byte_len = 1 };
            };
            self.index += len;
            return .{ .codepoint = cp, .byte_start = start, .byte_len = len };
        }
        return null;
    }
};

fn advanceCallback(context: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) text_layout.Advance {
    _ = font_size;
    const font: *const FontFace = @ptrCast(@alignCast(context orelse return .{ .byte_len = 0, .width = 0.0 }));
    var iter = Iterator{ .text = text[byte_offset..], .policy = font.decode_policy };
    const decoded = iter.next() orelse return .{ .byte_len = 0, .width = 0.0 };
    return .{ .byte_len = decoded.byte_len, .width = font.advance(decoded.codepoint) };
}

fn rectIntersectsY(rect: draw.Rect, y: f32, h: f32) bool {
    return y + h > rect.y and y < rect.y + rect.h;
}

fn isCjk(codepoint: u21) bool {
    return (codepoint >= 0x2e80 and codepoint <= 0x9fff) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0x20000 and codepoint <= 0x2ffff);
}

fn isEmoji(codepoint: u21) bool {
    return (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x2600 and codepoint <= 0x27bf);
}

test "utf-8 iterator replaces invalid bytes" {
    const bytes = [_]u8{ 'a', 0xff, 'b' };
    var iter = Iterator.init(&bytes, .replacement);
    try std.testing.expectEqual(@as(u21, 'a'), iter.next().?.codepoint);
    try std.testing.expectEqual(replacement_codepoint, iter.next().?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), iter.next().?.codepoint);
    try std.testing.expect(iter.next() == null);
}

test "measure handles utf-8 nbspace cjk and emoji fallback" {
    const font = FontFace.defaultUi("", 10);
    try std.testing.expectEqual(@as(f32, 5.5), font.measureRun("A"));
    try std.testing.expectApproxEqAbs(@as(f32, 3.2), font.measureRun("\xc2\xa0"), 0.001);
    try std.testing.expectEqual(@as(f32, 10.0), font.measureRun("界"));
    try std.testing.expectEqual(@as(f32, 10.0), font.measureRun("🙂"));
}

test "measured width equals glyph placement advances" {
    const font = FontFace.defaultUi("", 12);
    const sample = "A\xc2\xa0界🙂Z";
    var glyphs: std.ArrayList(GlyphPlacement) = .empty;
    defer glyphs.deinit(std.testing.allocator);
    try appendGlyphs(std.testing.allocator, .{
        .rect = .{ .w = 1000, .h = 100 },
        .text = sample,
        .color = draw.Color.white,
        .font = &font,
        .wrap = false,
    }, &glyphs);
    var sum: f32 = 0.0;
    for (glyphs.items) |glyph| sum += glyph.advance;
    try std.testing.expectApproxEqAbs(font.measureRun(sample), sum, 0.001);
}

test "append text to batch emits positioned utf-8 runs" {
    const font = FontFace.defaultUi("", 10);
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try appendTextToBatch(std.testing.allocator, &batch, .{
        .rect = .{ .x = 2, .y = 3, .w = 14, .h = 40 },
        .text = "AB界",
        .color = draw.Color.white,
        .font = &font,
        .wrap = true,
    });
    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);
    try std.testing.expect(batch.commands.items[0].text_run_count >= 2);
}

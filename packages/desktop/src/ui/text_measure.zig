//! Text measurement for Verde's layout code, backed by the same palette-native
//! font collection the GPU renderer draws with.
//!
//! Sizes are nominal: like the renderer, measurement evaluates every face at
//! `font_size * text_scale` (0.86, `palette.fonts.default_text_scale`) so
//! markdown chunk positions match the glyphs that are actually drawn. Role
//! chains include the symbol/emoji fallbacks, so arrows and dingbats measure
//! with the face that draws them. Before `configure` (tests, headless roots)
//! widths come from a per-character estimate.

const std = @import("std");
const palette = @import("palette");

var fonts: ?*palette.fonts.Fonts = null;
var prefix_cache: ?PrefixWidthCache = null;
// Bumped whenever the measuring backend changes so width memos keyed on it
// (chat_panel chrome labels) drop stale entries instead of serving widths
// measured against replaced fonts.
var font_generation: u32 = 0;

const DEFAULT_TEXT_SCALE: f32 = palette.fonts.default_text_scale;

pub fn configure(configured: *palette.fonts.Fonts) void {
    fonts = configured;
    prefix_cache = null;
    font_generation +%= 1;
}

pub fn clear() void {
    fonts = null;
    prefix_cache = null;
    font_generation +%= 1;
}

/// Identity of the current measuring backend for external width memos.
pub fn fontGeneration() u32 {
    return font_generation;
}

fn textScale() f32 {
    return if (fonts) |f| f.text_scale else DEFAULT_TEXT_SCALE;
}

pub fn textWidth(role: palette.FontRole, font_size: f32, text: []const u8) f32 {
    if (text.len == 0) return 0.0;
    const render_size = font_size * textScale();
    if (fonts) |f| {
        return f.collection.measureText(measureRole(role), render_size, text) catch estimatedTextWidth(render_size, text);
    }
    return estimatedTextWidth(render_size, text);
}

pub fn fontAscent(role: palette.FontRole, font_size: f32) f32 {
    const render_size = font_size * textScale();
    if (fonts) |f| {
        const ascent = f.collection.lineMetrics(measureRole(role), render_size).ascent;
        if (ascent > 0) return ascent;
    }
    return fallbackAscent(render_size);
}

/// Top-left origin that centers one glyph's *ink* on (`cx`, `cy`). Text is
/// drawn from its line-box top-left, and icon glyphs (Nerd Font / Font
/// Awesome) neither fill their advance nor sit centered in the line box, so
/// boxing an icon at `font_size` square lands it up-left of center. Falls
/// back to the font-size box when metrics are unavailable.
pub const GlyphOrigin = struct { x: f32, y: f32 };

pub fn centeredGlyphOrigin(role: palette.FontRole, glyph: []const u8, font_size: f32, cx: f32, cy: f32) GlyphOrigin {
    const fallback: GlyphOrigin = .{ .x = cx - font_size * 0.5, .y = cy - font_size * 0.5 };
    const f = fonts orelse return fallback;
    const view = std.unicode.Utf8View.init(glyph) catch return fallback;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return fallback;
    // Ink box in whole pixels at the drawn size, SDL_ttf `TTF_GetGlyphMetrics` order.
    const ink = f.glyphInk(role, font_size, cp) orelse return fallback;
    if (ink[1] <= ink[0] or ink[3] <= ink[2]) return fallback;
    const ascent = f.collection.lineMetrics(role, font_size * f.text_scale).ascent;
    if (ascent <= 0) return fallback;
    return .{
        .x = cx - (ink[0] + ink[1]) * 0.5,
        .y = cy - ascent + (ink[2] + ink[3]) * 0.5,
    };
}

pub fn baselineOffset(reference_role: palette.FontRole, reference_size: f32, role: palette.FontRole, font_size: f32) f32 {
    return fontAscent(reference_role, reference_size) - fontAscent(role, font_size);
}

pub fn textPrefixWidth(role: palette.FontRole, text: []const u8, font_size: f32, end: usize) f32 {
    const e = @min(end, text.len);
    if (e == 0) return 0.0;
    if (prefix_cache) |cache| {
        if (cache.matches(role, text, font_size, e)) return cache.width;
    }
    const width = measureTextPrefixWidth(role, text, font_size, e);
    prefix_cache = PrefixWidthCache.capture(role, text, font_size, e, width);
    return width;
}

fn measureTextPrefixWidth(role: palette.FontRole, text: []const u8, font_size: f32, end: usize) f32 {
    const render_size = font_size * textScale();
    if (fonts) |f| {
        return f.collection.measureTextOffset(measureRole(role), render_size, text, end) catch fallbackTextPrefixWidth(role, font_size, text, end);
    }
    return estimatedTextWidth(render_size, text[0..end]);
}

fn fallbackTextPrefixWidth(role: palette.FontRole, font_size: f32, text: []const u8, end: usize) f32 {
    return textWidth(role, font_size, text[0..@min(end, text.len)]);
}

/// Fills `advances` (len == text.len) with the advance width of each glyph,
/// indexed by the glyph's starting byte, in a single shaping pass. `text`
/// must be a single line (no newlines). Use this for text-input layout where
/// every glyph is needed; per-glyph textPrefixWidth calls re-shape the whole
/// prefix each time and are O(line²).
pub fn textGlyphAdvances(role: palette.FontRole, text: []const u8, font_size: f32, advances: []f32) void {
    std.debug.assert(advances.len == text.len);
    if (text.len == 0) return;
    const render_size = font_size * textScale();
    if (fonts) |f| {
        if (f.collection.glyphAdvances(measureRole(role), render_size, text, advances)) |_| {
            return;
        } else |_| {}
    }
    estimatedGlyphAdvances(render_size, text, advances);
}

fn estimatedGlyphAdvances(font_size: f32, text: []const u8, advances: []f32) void {
    @memset(advances, 0.0);
    var index: usize = 0;
    while (index < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + seq_len, text.len);
        advances[index] = estimatedTextWidth(font_size, text[index..end]);
        index = end;
    }
}

pub fn codepointWidth(role: palette.FontRole, cp: u21, font_size: f32) f32 {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return @max(font_size * 0.55, 1.0);
    return textWidth(role, font_size, buf[0..len]);
}

fn measureRole(role: palette.FontRole) palette.FontRole {
    return switch (role) {
        // mono_symbols / symbols / symbols_alt / math / emoji are coverage
        // fallbacks inside the mono chain; measurement reports the mono chain
        // because terminal layout advances by mono cells regardless of which
        // face ends up drawing each glyph.
        .mono_symbols, .symbols, .symbols_alt, .math, .emoji => .mono,
        else => role,
    };
}

const SPACE_EM: f32 = 0.30;

const PrefixWidthCache = struct {
    ptr: [*]const u8,
    len: usize,
    end: usize,
    font_size: f32,
    role: palette.FontRole,
    width: f32,

    fn capture(role: palette.FontRole, text: []const u8, font_size: f32, end: usize, width: f32) PrefixWidthCache {
        return .{
            .ptr = text.ptr,
            .len = text.len,
            .end = end,
            .font_size = font_size,
            .role = role,
            .width = width,
        };
    }

    fn matches(self: PrefixWidthCache, role: palette.FontRole, text: []const u8, font_size: f32, end: usize) bool {
        return self.ptr == text.ptr and
            self.len == text.len and
            self.end == end and
            self.font_size == font_size and
            self.role == role;
    }
};

fn estimatedTextWidth(font_size: f32, text: []const u8) f32 {
    var width: f32 = 0.0;
    for (text) |byte| {
        width += switch (byte) {
            'i', 'l', 'I', '.', ',', ':', ';', '!' => font_size * 0.28,
            'm', 'w', 'M', 'W' => font_size * 0.78,
            ' ' => font_size * SPACE_EM,
            '\t' => font_size * SPACE_EM * 4.0,
            else => font_size * 0.55,
        };
    }
    return width;
}

fn fallbackAscent(font_size: f32) f32 {
    return font_size * 0.82;
}

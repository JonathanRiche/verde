const std = @import("std");
const palette = @import("palette");

const RoleFonts = struct {
    ui: *palette.sdl.Font,
    ui_bold: *palette.sdl.Font,
    prose: *palette.sdl.Font,
    prose_bold: *palette.sdl.Font,
    prose_italic: *palette.sdl.Font,
    prose_bold_italic: *palette.sdl.Font,
    mono: *palette.sdl.Font,
    icon: *palette.sdl.Font,
};

var fonts: ?RoleFonts = null;
var gpu_renderer: ?*palette.renderer.Renderer = null;
var prefix_cache: ?PrefixWidthCache = null;
// Bumped whenever the measuring backend changes so width memos keyed on it
// (chat_panel chrome labels) drop stale entries instead of serving widths
// measured against replaced fonts.
var font_generation: u32 = 0;

// Palette's SDL_GPU text path renders TTF text through the atlas engine at this
// scale. Keep layout measurement on the same scale so markdown chunk positions
// match the glyphs that are actually drawn.
const GPU_TEXT_FONT_SCALE: f32 = 0.86;

pub fn configure(role_fonts: RoleFonts) void {
    fonts = role_fonts;
    font_generation +%= 1;
}

pub fn configureRenderer(renderer: ?*palette.renderer.Renderer) void {
    gpu_renderer = renderer;
    prefix_cache = null;
    font_generation +%= 1;
}

pub fn clear() void {
    fonts = null;
    gpu_renderer = null;
    prefix_cache = null;
    font_generation +%= 1;
}

/// Identity of the current measuring backend for external width memos.
pub fn fontGeneration() u32 {
    return font_generation;
}

pub fn textWidth(role: palette.FontRole, font_size: f32, text: []const u8) f32 {
    if (text.len == 0) return 0.0;
    // Non-ASCII may need symbol fallbacks (→ etc. live outside Noto Sans).
    // The GPU path's sized fonts register those faces, so advances match
    // the glyphs that are actually drawn. Raw-base-face measurement alone
    // substitutes .notdef / wrong widths and makes arrows look gappy or
    // tofu-like next to surrounding prose. ASCII stays on the cheap path
    // because chat markdown wrap calls this per word.
    if (textNeedsCoverageMeasure(text)) {
        if (gpu_renderer) |renderer| {
            if (renderer.measureTextOffset(text, font_size, text.len, role)) |width| {
                return width;
            } else |_| {}
        }
    }
    const render_size = font_size * GPU_TEXT_FONT_SCALE;
    if (fonts) |configured| {
        return palette.sdl.ttfMeasureText(fontForRole(configured, role), text, render_size) catch estimatedTextWidth(render_size, text);
    }
    return estimatedTextWidth(render_size, text);
}

/// True when `text` may contain codepoints outside the primary UI/prose
/// faces (arrows, dingbats, emoji, CJK, …) that need SDL_ttf symbol
/// fallbacks for correct advance widths.
fn textNeedsCoverageMeasure(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return true;
    }
    return false;
}

pub fn fontAscent(role: palette.FontRole, font_size: f32) f32 {
    const render_size = font_size * GPU_TEXT_FONT_SCALE;
    if (fonts) |configured| {
        return palette.sdl.ttfFontAscent(fontForRole(configured, role), render_size) catch fallbackAscent(render_size);
    }
    return fallbackAscent(render_size);
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
    if (gpu_renderer) |renderer| {
        return renderer.measureTextOffset(text, font_size, end, role) catch fallbackTextPrefixWidth(role, font_size, text, end);
    }
    const render_size = font_size * GPU_TEXT_FONT_SCALE;
    if (fonts) |configured| {
        return palette.sdl.ttfMeasureTextOffset(fontForRole(configured, role), text, render_size, end) catch fallbackTextPrefixWidth(role, font_size, text, end);
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
    if (gpu_renderer) |renderer| {
        if (renderer.measureTextGlyphAdvances(text, font_size, role, advances)) |_| {
            return;
        } else |_| {}
    }
    estimatedGlyphAdvances(font_size * GPU_TEXT_FONT_SCALE, text, advances);
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

fn fontForRole(role_fonts: RoleFonts, role: palette.FontRole) *palette.sdl.Font {
    return switch (role) {
        .ui => role_fonts.ui,
        .ui_bold => role_fonts.ui_bold,
        .prose => role_fonts.prose,
        .prose_bold => role_fonts.prose_bold,
        .prose_italic => role_fonts.prose_italic,
        .prose_bold_italic => role_fonts.prose_bold_italic,
        .mono => role_fonts.mono,
        .icon => role_fonts.icon,
        // mono_symbols / symbols / symbols_alt / emoji are coverage fallbacks
        // the renderer picks per-glyph; measurement always reports the primary
        // mono cell width because terminal layout advances by mono cells
        // regardless of which face ends up drawing each glyph.
        .mono_symbols, .symbols, .symbols_alt, .emoji => role_fonts.mono,
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

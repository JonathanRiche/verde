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

// Palette's SDL_GPU text path renders TTF text through the atlas engine at this
// scale. Keep layout measurement on the same scale so markdown chunk positions
// match the glyphs that are actually drawn.
const GPU_TEXT_FONT_SCALE: f32 = 0.86;

pub fn configure(role_fonts: RoleFonts) void {
    fonts = role_fonts;
}

pub fn configureRenderer(renderer: ?*palette.renderer.Renderer) void {
    gpu_renderer = renderer;
    prefix_cache = null;
}

pub fn clear() void {
    fonts = null;
    gpu_renderer = null;
    prefix_cache = null;
}

pub fn textWidth(role: palette.FontRole, font_size: f32, text: []const u8) f32 {
    if (text.len == 0) return 0.0;
    const render_size = font_size * GPU_TEXT_FONT_SCALE;
    if (fonts) |configured| {
        return palette.sdl.ttfMeasureText(fontForRole(configured, role), text, render_size) catch estimatedTextWidth(render_size, text);
    }
    return estimatedTextWidth(render_size, text);
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

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

pub fn configure(role_fonts: RoleFonts) void {
    fonts = role_fonts;
}

pub fn clear() void {
    fonts = null;
}

pub fn textWidth(role: palette.FontRole, font_size: f32, text: []const u8) f32 {
    if (text.len == 0) return 0.0;
    if (fonts) |configured| {
        return palette.sdl.ttfMeasureText(fontForRole(configured, role), text, font_size) catch estimatedTextWidth(font_size, text);
    }
    return estimatedTextWidth(font_size, text);
}

pub fn textPrefixWidth(role: palette.FontRole, text: []const u8, font_size: f32, end: usize) f32 {
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

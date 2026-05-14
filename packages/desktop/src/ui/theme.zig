//! Shared native UI theme tokens and helpers.

const std = @import("std");
const colors = @import("colors.zig");
const rgba = colors.rgba;
const rgb = colors.rgb;

pub const DEFAULT_FONT_SIZE: f32 = 24.0;
pub const RESPONSIVE_BASE_FONT_SIZE: f32 = 22.0;

pub const COLOR_GREEN = rgb(0x50, 0xc8, 0x78);
pub const COLOR_SECONDARY_GREEN = rgb(0x37, 0x58, 0x46);
pub const COLOR_YELLOW = rgb(0xfb, 0xbf, 0x24);
pub const COLOR_NAV_CHAT_BG = colors.BLACK_SECONDARY;
pub const COLOR_BLACK = COLOR_NAV_CHAT_BG;
pub const COLOR_WHITE = rgba(240, 240, 245, 255);
pub const COLOR_PANEL = COLOR_NAV_CHAT_BG;
pub const COLOR_PANEL_ALT = rgba(40, 41, 46, 255);
pub const COLOR_PANEL_MUTED = rgba(56, 57, 62, 255);
pub const COLOR_TEXT_MUTED = rgba(185, 187, 195, 255);
pub const COLOR_TEXT_SUBTLE = rgba(120, 122, 135, 255);
pub const COLOR_DIFF_ADD = rgba(52, 224, 148, 255);
pub const COLOR_DIFF_REMOVE = rgba(255, 100, 100, 255);
pub const COLOR_ACCENT_DIM = rgba(124, 221, 94, 48);

pub const TRANSCRIPT_BUBBLE_PADDING_X: f32 = 18.0;
pub const TRANSCRIPT_BUBBLE_PADDING_Y: f32 = 14.0;
pub const TRANSCRIPT_BUBBLE_ROUNDING: f32 = 14.0;

/// Markdown rendering palette. Grouped here so a future light theme can swap
/// the whole table in one place. All values are RGBA [4]f32 in 0..1 space.
pub const md = struct {
    // Prose body and headings.
    pub const text_body = rgb(0xE2, 0xE4, 0xE9);
    pub const text_h1 = rgb(0xFF, 0xF2, 0xA8);
    pub const text_h2 = rgb(0xF2, 0xE6, 0x8D);
    pub const text_h3 = rgb(0xDE, 0xE8, 0xFF);
    pub const text_h4_h6 = rgb(0xCF, 0xD7, 0xE5);
    pub const text_quote = rgb(0xB3, 0xBE, 0xD4);

    // Inline-style overrides.
    pub const inline_code = rgb(0xF5, 0xD0, 0x7A);
    pub const link = rgb(0x7A, 0xCA, 0xFF);

    // Selection / chrome.
    pub const selection_fill = rgba(88, 166, 255, 255);

    // Blockquote chrome.
    pub const quote_bg = rgba(38, 41, 48, 140);
    pub const quote_accent = link;

    // Fenced code block frame.
    pub const code_bg = rgba(24, 24, 28, 255);
    pub const code_border = rgba(52, 54, 62, 255);
    pub const inline_code_pill = rgba(38, 41, 48, 235);

    // Thematic rule (`---`).
    pub const rule = rgba(68, 72, 82, 255);

    // GFM tables.
    pub const table_border = rgba(68, 72, 82, 255);
    pub const table_header_bg = rgba(38, 41, 48, 200);

    // Syntax tokens.
    pub const tok_plain = text_body;
    pub const tok_comment = rgb(0x8A, 0x91, 0xA0);
    pub const tok_string = rgb(0x66, 0xDC, 0xAA);
    pub const tok_number = rgb(0xF5, 0xB4, 0x78);
    pub const tok_keyword = rgb(0xFF, 0xD6, 0x66);
    pub const tok_type = rgb(0x7A, 0xCA, 0xFF);
    pub const tok_function = rgb(0x60, 0xDB, 0xDB);
    pub const tok_property = rgb(0x6B, 0xA8, 0xFF);
    pub const tok_variable = text_body;
    pub const tok_constant = rgb(0xF1, 0xC4, 0x6B);
    pub const tok_punct = rgb(0xB6, 0xBB, 0xC5);

    // Copy-button states (idle / hover / recently-clicked).
    pub const copy_bg_idle = rgba(38, 41, 48, 200);
    pub const copy_bg_hover = rgba(64, 70, 82, 235);
    pub const copy_bg_recent = rgba(46, 110, 70, 230);
    pub const copy_glyph_idle = rgba(190, 195, 205, 255);
    pub const copy_glyph_hover = rgba(245, 245, 250, 255);
    pub const copy_glyph_recent = rgba(220, 246, 200, 255);
};

pub var heading_font_size: f32 = DEFAULT_FONT_SIZE * 1.28;
pub var terminal_font_size: f32 = DEFAULT_FONT_SIZE * 0.86;
var current_ui_scale: f32 = 1.0;
var current_font_size: f32 = DEFAULT_FONT_SIZE;

pub fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

pub fn uiScaleFactor() f32 {
    return current_ui_scale;
}

pub fn scaledUi(value: f32) f32 {
    return value * uiScaleFactor();
}

pub fn installFonts(
    font_bytes: []const u8,
    bold_font_bytes: []const u8,
    italic_font_bytes: []const u8,
    bold_italic_font_bytes: []const u8,
    codicon_font_bytes: []const u8,
    nerd_font_bytes: []const u8,
    font_size: f32,
) void {
    _ = font_bytes;
    _ = bold_font_bytes;
    _ = italic_font_bytes;
    _ = bold_italic_font_bytes;
    _ = codicon_font_bytes;
    _ = nerd_font_bytes;
    current_font_size = if (std.math.isFinite(font_size) and font_size > 0.0) font_size else DEFAULT_FONT_SIZE;
    heading_font_size = current_font_size * 1.28;
    terminal_font_size = current_font_size * 0.86;
}

pub fn applyTheme(ui_scale: f32) void {
    current_ui_scale = if (std.math.isFinite(ui_scale) and ui_scale > 0.0) ui_scale else 1.0;
}

pub fn lighten(color: [4]f32, amount: f32) [4]f32 {
    return .{
        clampf(color[0] + amount, 0.0, 1.0),
        clampf(color[1] + amount, 0.0, 1.0),
        clampf(color[2] + amount, 0.0, 1.0),
        color[3],
    };
}

pub fn darken(color: [4]f32, amount: f32) [4]f32 {
    return .{
        clampf(color[0] - amount, 0.0, 1.0),
        clampf(color[1] - amount, 0.0, 1.0),
        clampf(color[2] - amount, 0.0, 1.0),
        color[3],
    };
}

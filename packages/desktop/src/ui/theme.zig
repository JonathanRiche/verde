//! Shared native UI theme tokens and helpers.

const std = @import("std");
const builtin = @import("builtin");
const zgui = @import("zgui");
const colors = @import("colors.zig");
const app_state = @import("../state.zig");
const rgba = colors.rgba;
const rgb = colors.rgb;

const codicon_glyph_ranges = [_:0]zgui.Wchar{
    0xea60,
    0xecff,
    0,
};

const nerd_font_glyph_ranges = [_:0]zgui.Wchar{
    0xe0a0,
    0xe0d7,
    0xe5fa,
    0xe7ff,
    0xf000,
    0xf8ff,
    0xf0000,
    0xf20ff,
    0,
};

const terminal_font_glyph_ranges = [_:0]zgui.Wchar{
    0x0020,
    0x00ff,
    0x0100,
    0x024f,
    0x2500,
    0x259f,
    0xe0a0,
    0xe0d7,
    0xe5fa,
    0xe7ff,
    0xf000,
    0xf8ff,
    0xf0000,
    0xf20ff,
    0,
};

pub const DEFAULT_FONT_SIZE: f32 = 24.0;
pub const RESPONSIVE_BASE_FONT_SIZE: f32 = 22.0;

pub const COLOR_GREEN = rgb(0x50, 0xc8, 0x78);
pub const COLOR_SECONDARY_GREEN = rgb(0x37, 0x58, 0x46);
pub const COLOR_YELLOW = rgb(0xfb, 0xbf, 0x24);
pub const COLOR_NAV_CHAT_BG = colors.BLACK_SECONDARY;
pub const COLOR_BLACK = COLOR_NAV_CHAT_BG;
pub const COLOR_WHITE = rgba(240, 240, 245, 255);
pub const COLOR_PANEL = COLOR_NAV_CHAT_BG;
//0D1213
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

pub var heading_font: ?zgui.Font = null;
pub var terminal_font: ?zgui.Font = null;
pub var bold_font: ?zgui.Font = null;
pub var italic_font: ?zgui.Font = null;
pub var bold_italic_font: ?zgui.Font = null;
// pub var heading_font_size: f32 = DEFAULT_FONT_SIZE * 1.28;

pub var heading_font_size: f32 = DEFAULT_FONT_SIZE * 2.22;
pub var terminal_font_size: f32 = DEFAULT_FONT_SIZE * 0.92;

/// Clamps a float into a safe UI range.
pub fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

/// Derives the active UI scale from the current font size.
pub fn uiScaleFactor() f32 {
    const font_size = zgui.getFontSize();
    if (!std.math.isFinite(font_size) or font_size <= 0.0) return 1.0;

    const clamped = clampf(font_size / RESPONSIVE_BASE_FONT_SIZE, 0.9, 2.4);

    // app_state.log.info("font_size made it here : {d}", .{clamped});
    return clamped;
}

/// Scales a design token into the current UI size.
pub fn scaledUi(value: f32) f32 {
    return value * uiScaleFactor();
}

fn mergeIconFont(font_bytes: []const u8, font_size: f32, ranges: []const zgui.Wchar) void {
    var config = zgui.FontConfig.init();
    config.merge_mode = true;
    config.pixel_snap_h = true;
    config.glyph_min_advance_x = font_size;
    _ = zgui.io.addFontFromMemoryWithConfig(font_bytes, font_size, config, ranges.ptr);
}

fn installTerminalFont(nerd_font_bytes: []const u8, font_size: f32) ?zgui.Font {
    for (terminalFontCandidates()) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        var config = zgui.FontConfig.init();
        config.pixel_snap_h = true;
        const font = zgui.io.addFontFromFileWithConfig(
            path,
            font_size,
            config,
            terminal_font_glyph_ranges[0..].ptr,
        );
        mergeIconFont(nerd_font_bytes, font_size, nerd_font_glyph_ranges[0..]);
        return font;
    }

    // Fallback: keep using the UI atlas but at least merge the symbol font.
    const fallback = zgui.io.addFontDefault(null);
    mergeIconFont(nerd_font_bytes, font_size, nerd_font_glyph_ranges[0..]);
    return fallback;
}

fn terminalFontCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .linux => &.{
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/CaskaydiaMonoNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/FiraCodeNerdFontMono-Regular.ttf",
            "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
            "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
        },
        .macos => &.{
            "/Library/Fonts/JetBrainsMonoNerdFontMono-Regular.ttf",
            "/System/Library/Fonts/Menlo.ttc",
            "/System/Library/Fonts/SFNSMono.ttf",
        },
        .windows => &.{
            "C:\\Windows\\Fonts\\JetBrainsMonoNerdFontMono-Regular.ttf",
            "C:\\Windows\\Fonts\\CascadiaMono.ttf",
            "C:\\Windows\\Fonts\\consola.ttf",
        },
        else => &.{},
    };
}

/// Installs the default, icon, and heading fonts for the native UI.
pub fn installFonts(
    font_bytes: []const u8,
    bold_font_bytes: []const u8,
    italic_font_bytes: []const u8,
    bold_italic_font_bytes: []const u8,
    codicon_font_bytes: []const u8,
    nerd_font_bytes: []const u8,
    font_size: f32,
) void {
    const font = zgui.io.addFontFromMemory(font_bytes, font_size);
    mergeIconFont(codicon_font_bytes, font_size, codicon_glyph_ranges[0..]);
    mergeIconFont(nerd_font_bytes, font_size, nerd_font_glyph_ranges[0..]);
    zgui.io.setDefaultFont(font);
    bold_font = zgui.io.addFontFromMemory(bold_font_bytes, font_size);
    mergeIconFont(codicon_font_bytes, font_size, codicon_glyph_ranges[0..]);
    mergeIconFont(nerd_font_bytes, font_size, nerd_font_glyph_ranges[0..]);
    italic_font = zgui.io.addFontFromMemory(italic_font_bytes, font_size);
    mergeIconFont(codicon_font_bytes, font_size, codicon_glyph_ranges[0..]);
    mergeIconFont(nerd_font_bytes, font_size, nerd_font_glyph_ranges[0..]);
    bold_italic_font = zgui.io.addFontFromMemory(bold_italic_font_bytes, font_size);
    mergeIconFont(codicon_font_bytes, font_size, codicon_glyph_ranges[0..]);
    mergeIconFont(nerd_font_bytes, font_size, nerd_font_glyph_ranges[0..]);
    heading_font_size = font_size * 1.28;
    heading_font = zgui.io.addFontFromMemory(font_bytes, heading_font_size);
    mergeIconFont(codicon_font_bytes, heading_font_size, codicon_glyph_ranges[0..]);
    mergeIconFont(nerd_font_bytes, heading_font_size, nerd_font_glyph_ranges[0..]);
    terminal_font_size = font_size * 0.86;
    terminal_font = installTerminalFont(nerd_font_bytes, terminal_font_size);
}

/// Applies the shared ImGui theme colors and spacing.
pub fn applyTheme(ui_scale: f32) void {
    const scale = if (std.math.isFinite(ui_scale) and ui_scale > 0.0) ui_scale else 1.0;
    const style = zgui.getStyle();
    style.window_padding = .{ 0.0, 0.0 };
    zgui.styleColorsDark(style);

    style.font_scale_main = scale;
    style.window_rounding = 12.0 * scale;
    style.child_rounding = 12.0 * scale;
    style.frame_rounding = 10.0 * scale;
    style.grab_rounding = 10.0 * scale;
    style.window_padding = .{ 14.0 * scale, 12.0 * scale };
    style.item_spacing = .{ 10.0 * scale, 8.0 * scale };

    style.setColor(.window_bg, COLOR_BLACK);
    style.setColor(.child_bg, COLOR_PANEL);
    style.setColor(.frame_bg, COLOR_PANEL_ALT);
    style.setColor(.frame_bg_hovered, lighten(COLOR_PANEL_ALT, 0.10));
    style.setColor(.frame_bg_active, lighten(COLOR_PANEL_ALT, 0.16));
    style.setColor(.button, COLOR_SECONDARY_GREEN);
    style.setColor(.button_hovered, lighten(COLOR_SECONDARY_GREEN, 0.12));
    style.setColor(.button_active, darken(COLOR_SECONDARY_GREEN, 0.08));
    style.setColor(.border, colors.DARK_BLUE);
    style.setColor(.separator, rgba(48, 50, 56, 255));
    style.setColor(.check_mark, COLOR_WHITE);
    style.setColor(.text, COLOR_WHITE);
    style.setColor(.text_selected_bg, rgba(124, 221, 94, 80));
    style.setColor(.title_bg, COLOR_PANEL);
    style.setColor(.title_bg_active, COLOR_PANEL_ALT);
    style.setColor(.header, COLOR_PANEL_ALT);
    style.setColor(.header_hovered, lighten(COLOR_PANEL_ALT, 0.08));
    style.setColor(.header_active, COLOR_GREEN);
    style.setColor(.scrollbar_bg, rgba(22, 22, 26, 64));
    style.setColor(.scrollbar_grab, rgba(60, 62, 68, 200));
    style.setColor(.scrollbar_grab_hovered, rgba(80, 82, 90, 255));
    style.setColor(.scrollbar_grab_active, COLOR_GREEN);
}

/// Nudges a color toward a lighter variant.
pub fn lighten(color: [4]f32, amount: f32) [4]f32 {
    return .{
        clampf(color[0] + amount, 0.0, 1.0),
        clampf(color[1] + amount, 0.0, 1.0),
        clampf(color[2] + amount, 0.0, 1.0),
        color[3],
    };
}

/// Nudges a color toward a darker variant.
pub fn darken(color: [4]f32, amount: f32) [4]f32 {
    return .{
        clampf(color[0] - amount, 0.0, 1.0),
        clampf(color[1] - amount, 0.0, 1.0),
        clampf(color[2] - amount, 0.0, 1.0),
        color[3],
    };
}

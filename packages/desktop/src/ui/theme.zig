//! Shared native UI theme tokens and helpers.

const std = @import("std");
const builtin = @import("builtin");
const colors = @import("colors.zig");
const rgba = colors.rgba;
const rgb = colors.rgb;

const log = std.log.scoped(.ui_theme);

pub const DEFAULT_FONT_SIZE: f32 = 24.0;
pub const RESPONSIVE_BASE_FONT_SIZE: f32 = 22.0;
pub const MOTION_FAST_MS: i64 = 120;
pub const MOTION_BASE_MS: i64 = 180;
pub const MOTION_REDUCED_MS: i64 = 80;
/// Slow, low-distraction cadence shared by live-work indicators.
pub const ACTIVITY_PULSE_PERIOD_NS: i128 = 1_600_000_000;

pub const ThemeColors = struct {
    background: [4]f32 = colors.CHAT_BLACK,
    panel: [4]f32 = colors.BLACK_SECONDARY,
    panel_alt: [4]f32 = rgba(40, 41, 46, 255),
    panel_muted: [4]f32 = rgba(56, 57, 62, 255),
    text: [4]f32 = rgba(240, 240, 245, 255),
    text_muted: [4]f32 = rgba(185, 187, 195, 255),
    text_subtle: [4]f32 = rgba(120, 122, 135, 255),
    accent: [4]f32 = rgb(0x50, 0xc8, 0x78),
    accent_dim: [4]f32 = rgba(124, 221, 94, 48),
    border: [4]f32 = rgb(0x37, 0x58, 0x46),
    border_muted: [4]f32 = colors.DARK_BLUE,
    warning: [4]f32 = rgb(0xfb, 0xbf, 0x24),
    diff_add: [4]f32 = rgba(52, 224, 148, 255),
    diff_remove: [4]f32 = rgba(255, 100, 100, 255),
    selection: [4]f32 = rgba(88, 166, 255, 255),
};

/// Where the base palette comes from. `auto` follows the OS light/dark
/// appearance; `omarchy` reads the active Omarchy colors.toml and falls back
/// to `auto` when no Omarchy install is present.
pub const ThemeSource = enum {
    auto,
    verde_dark,
    verde_light,
    verde_legacy,
    omarchy,

    /// Built-in dropdown entries in display order. `omarchy` is last so it can
    /// be omitted on systems without an Omarchy install.
    pub const builtin_choices = [_]ThemeSource{ .auto, .verde_dark, .verde_light, .verde_legacy, .omarchy };

    /// Stable spelling persisted in `verde.json` and theme packages.
    pub fn configName(self: ThemeSource) []const u8 {
        return switch (self) {
            .auto => "auto",
            .verde_dark => "verde-dark",
            .verde_light => "verde-light",
            .verde_legacy => "verde-legacy",
            .omarchy => "omarchy",
        };
    }

    pub fn label(self: ThemeSource) []const u8 {
        return switch (self) {
            .auto => "Auto",
            .verde_dark => "Verde Dark",
            .verde_light => "Verde Light",
            .verde_legacy => "Verde Legacy",
            .omarchy => "Omarchy",
        };
    }

    /// Parses persisted names case-insensitively, accepting `-` or `_`.
    /// `default` and `verde` predate the named palettes and always meant the
    /// original palette, so they map to `verde_legacy`.
    pub fn parse(raw: []const u8) ?ThemeSource {
        const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (value.len == 0 or value.len > 32) return null;
        var buffer: [32]u8 = undefined;
        for (value, 0..) |char, index| {
            buffer[index] = if (char == '_') '-' else std.ascii.toLower(char);
        }
        const name = buffer[0..value.len];
        const aliases = [_]struct { name: []const u8, source: ThemeSource }{
            .{ .name = "auto", .source = .auto },
            .{ .name = "system", .source = .auto },
            .{ .name = "verde-dark", .source = .verde_dark },
            .{ .name = "dark", .source = .verde_dark },
            .{ .name = "verde-light", .source = .verde_light },
            .{ .name = "light", .source = .verde_light },
            .{ .name = "verde-legacy", .source = .verde_legacy },
            .{ .name = "legacy", .source = .verde_legacy },
            .{ .name = "default", .source = .verde_legacy },
            .{ .name = "verde", .source = .verde_legacy },
            .{ .name = "omarchy", .source = .omarchy },
        };
        for (aliases) |alias| {
            if (std.mem.eql(u8, name, alias.name)) return alias.source;
        }
        return null;
    }
};

/// Source used when the config does not name one: Omarchy installs keep
/// following Omarchy, everything else follows the OS appearance.
pub fn defaultThemeSource(omarchy_detected: bool) ThemeSource {
    return if (omarchy_detected) .omarchy else .auto;
}

/// Source the dropdown should show as selected. A saved `omarchy` on a system
/// without Omarchy renders the Auto palette, so it is presented as Auto.
pub fn effectiveThemeSource(source: ThemeSource, omarchy_detected: bool) ThemeSource {
    return if (source == .omarchy and !omarchy_detected) .auto else source;
}

pub const ThemeColorOverrides = struct {
    background: ?[4]f32 = null,
    panel: ?[4]f32 = null,
    panel_alt: ?[4]f32 = null,
    panel_muted: ?[4]f32 = null,
    text: ?[4]f32 = null,
    text_muted: ?[4]f32 = null,
    text_subtle: ?[4]f32 = null,
    accent: ?[4]f32 = null,
    accent_dim: ?[4]f32 = null,
    border: ?[4]f32 = null,
    border_muted: ?[4]f32 = null,
    warning: ?[4]f32 = null,
    diff_add: ?[4]f32 = null,
    diff_remove: ?[4]f32 = null,
    selection: ?[4]f32 = null,
};

pub const ThemeConfig = struct {
    source: ThemeSource = .omarchy,
    colors: ThemeColorOverrides = .{},
};

pub const default_colors: ThemeColors = .{};

/// The original Verde palette, kept selectable as "Verde Legacy".
pub const verde_legacy_colors: ThemeColors = default_colors;

/// Verde Dark `[verde]` roles, baked in from the approved colors.toml.
pub const verde_dark_colors: ThemeColors = .{
    .background = hexColor("#0B0F0E"),
    .panel = hexColor("#121917"),
    .panel_alt = hexColor("#17201D"),
    .panel_muted = hexColor("#222C29"),
    .text = hexColor("#E8EEEB"),
    .text_muted = hexColor("#C2CCC8"),
    .text_subtle = hexColor("#97A39E"),
    .accent = hexColor("#4FD18B"),
    .accent_dim = hexColor("#4FD18B29"),
    .border = hexColor("#2B5A40"),
    .border_muted = hexColor("#2A3431"),
    .warning = hexColor("#F0B450"),
    .diff_add = hexColor("#5ED49A"),
    .diff_remove = hexColor("#F07A70"),
    .selection = hexColor("#245A40"),
};

/// Verde Light `[verde]` roles, baked in from the approved colors.toml.
pub const verde_light_colors: ThemeColors = .{
    .background = hexColor("#F7F9F8"),
    .panel = hexColor("#FFFFFF"),
    .panel_alt = hexColor("#F3F6F4"),
    .panel_muted = hexColor("#E3E8E6"),
    .text = hexColor("#0F1715"),
    .text_muted = hexColor("#3B4743"),
    .text_subtle = hexColor("#5C6964"),
    .accent = hexColor("#15803D"),
    .accent_dim = hexColor("#15803D1F"),
    .border = hexColor("#A6D4B8"),
    .border_muted = hexColor("#D5DCD9"),
    .warning = hexColor("#B45309"),
    .diff_add = hexColor("#1A7F43"),
    .diff_remove = hexColor("#C4302B"),
    .selection = hexColor("#BFE3CD"),
};

fn hexColor(comptime value: []const u8) [4]f32 {
    comptime {
        @setEvalBranchQuota(10_000);
        return parseHexColor(value) orelse @compileError("invalid theme color " ++ value);
    }
}

pub const Appearance = enum { dark, light };

/// OS light/dark preference used by the `auto` source. Dark until the host
/// reports otherwise, which matches Verde's historical look.
var system_appearance: Appearance = .dark;

pub fn systemAppearance() Appearance {
    return system_appearance;
}

/// Records the OS appearance. Returns true when it changed so callers can
/// re-apply the theme only when `auto` would render differently.
pub fn setSystemAppearance(appearance: Appearance) bool {
    if (system_appearance == appearance) return false;
    system_appearance = appearance;
    return true;
}

pub fn autoColors(appearance: Appearance) ThemeColors {
    return switch (appearance) {
        .dark => verde_dark_colors,
        .light => verde_light_colors,
    };
}

/// Built-in palette for a source. `omarchy` resolves to Auto here; callers
/// layer the Omarchy file on top when one is available.
pub fn builtinColors(source: ThemeSource, appearance: Appearance) ThemeColors {
    return switch (source) {
        .auto, .omarchy => autoColors(appearance),
        .verde_dark => verde_dark_colors,
        .verde_light => verde_light_colors,
        .verde_legacy => verde_legacy_colors,
    };
}

/// Stateless Companion chrome derived from the active theme. Character paint
/// has its own derivation; this type owns only panel and control presentation.
pub const CompanionChrome = struct {
    surface: [4]f32,
    surface_deep: [4]f32,
    hairline: [4]f32,
    text: [4]f32,
    text_muted: [4]f32,
    text_subtle: [4]f32,
    border: [4]f32,
    menu_border: [4]f32,
    controls: [4]f32,
    accent: [4]f32,
    accent_hi: [4]f32,
    accent_fg: [4]f32,
    identity_fg: [4]f32,
    ready_fill: [4]f32,
    warning: [4]f32,
    warning_fg: [4]f32,
    danger: [4]f32,
    approval_card: [4]f32,
    approval_border: [4]f32,
    approval_title: [4]f32,
    approval_body: [4]f32,
    failure_card: [4]f32,
    failure_border: [4]f32,
    failure_fg: [4]f32,
    selection: [4]f32,
    menu_selected: [4]f32,
    menu_hover: [4]f32,
};

pub fn companionChrome() CompanionChrome {
    return companionChromeFor(current_colors);
}

pub fn companionChromeFor(active: ThemeColors) CompanionChrome {
    const surface = mix(active.background, active.text, 0.045);
    const surface_deep = mix(active.background, active.text, 0.025);
    const hairline = mix(active.background, active.text, 0.12);
    const pole_light = if (relativeLuma(active.text) >= relativeLuma(active.background)) active.text else active.background;
    const accent_hi = mix(active.accent, pole_light, 0.28);

    const guarded_border = guardedRole(active.border, active.border_muted, active.text_subtle, surface, active.text, active.background, 0.10);
    const menu_border = guardedRole(active.border_muted, active.text_subtle, active.border, surface_deep, active.text, active.background, 0.10);

    const ready_fill = withAlpha(active.accent, 26);
    const ready_composite = compositeOver(ready_fill, surface_deep);
    var identity_fg = accent_hi;
    if (lumaDistance(identity_fg, ready_composite) < 0.22) {
        identity_fg = mix(active.text, active.accent, 0.35);
        if (lumaDistance(identity_fg, ready_composite) < 0.22) identity_fg = active.text;
        if (lumaDistance(identity_fg, ready_composite) < 0.22) identity_fg = betterPole(ready_composite, active.text, active.background);
    }

    const approval_card = withAlpha(active.warning, 26);
    const approval_composite = compositeOver(approval_card, surface);
    var approval_title = active.warning;
    if (lumaDistance(approval_title, approval_composite) < 0.30) {
        approval_title = mix(active.warning, active.text, 0.40);
        if (lumaDistance(approval_title, approval_composite) < 0.30) approval_title = betterPole(approval_composite, active.text, active.background);
    }
    var approval_body = mix(active.text, active.warning, 0.35);
    if (lumaDistance(approval_body, approval_composite) < 0.30) {
        approval_body = foregroundOnFor(approval_composite, active.text, active.background);
        if (lumaDistance(approval_body, approval_composite) < 0.30) approval_body = betterPole(approval_composite, active.text, active.background);
    }

    const failure_card = withAlpha(active.diff_remove, 18);
    const failure_composite = compositeOver(failure_card, surface);
    var failure_fg = active.diff_remove;
    if (lumaDistance(failure_fg, failure_composite) < 0.30) {
        failure_fg = mix(active.diff_remove, active.text, 0.30);
        if (lumaDistance(failure_fg, failure_composite) < 0.30) failure_fg = betterPole(failure_composite, active.text, active.background);
    }

    var selection_color = withAlpha(active.accent, 140);
    if (lumaDistance(active.text, compositeOver(selection_color, surface)) < 0.30) selection_color = withAlpha(active.accent, 90);

    return .{
        .surface = surface,
        .surface_deep = surface_deep,
        .hairline = hairline,
        .text = active.text,
        .text_muted = active.text_muted,
        .text_subtle = active.text_subtle,
        .border = guarded_border,
        .menu_border = menu_border,
        .controls = active.border_muted,
        .accent = active.accent,
        .accent_hi = accent_hi,
        .accent_fg = foregroundOnFor(active.accent, active.text, active.background),
        .identity_fg = identity_fg,
        .ready_fill = ready_fill,
        .warning = active.warning,
        .warning_fg = foregroundOnFor(active.warning, active.text, active.background),
        .danger = active.diff_remove,
        .approval_card = approval_card,
        .approval_border = withAlpha(active.warning, 115),
        .approval_title = approval_title,
        .approval_body = approval_body,
        .failure_card = failure_card,
        .failure_border = withAlpha(active.diff_remove, 90),
        .failure_fg = failure_fg,
        .selection = selection_color,
        .menu_selected = withAlpha(active.border, 218),
        .menu_hover = mix(surface_deep, active.text, 0.06),
    };
}

fn lumaDistance(left: [4]f32, right: [4]f32) f32 {
    return @abs(relativeLuma(left) - relativeLuma(right));
}

fn compositeOver(foreground: [4]f32, backing: [4]f32) [4]f32 {
    return mix(backing, .{ foreground[0], foreground[1], foreground[2], 1.0 }, foreground[3]);
}

fn foregroundOnFor(fill: [4]f32, text: [4]f32, backing: [4]f32) [4]f32 {
    return betterPole(fill, text, backing);
}

fn betterPole(fill: [4]f32, text: [4]f32, backing: [4]f32) [4]f32 {
    return if (lumaDistance(fill, text) >= lumaDistance(fill, backing)) text else backing;
}

fn guardedRole(first: [4]f32, second: [4]f32, third: [4]f32, backing: [4]f32, text: [4]f32, background_color: [4]f32, threshold: f32) [4]f32 {
    var result = first;
    if (lumaDistance(result, backing) < threshold) result = second;
    if (lumaDistance(result, backing) < threshold) result = third;
    if (lumaDistance(result, backing) < threshold) result = betterPole(backing, text, background_color);
    return result;
}

pub var current_colors: ThemeColors = default_colors;

pub var COLOR_GREEN = default_colors.accent;
pub var COLOR_SECONDARY_GREEN = default_colors.border;
pub var COLOR_YELLOW = default_colors.warning;
pub var COLOR_NAV_CHAT_BG = default_colors.panel;
pub var COLOR_BLACK = default_colors.panel;
pub var COLOR_WHITE = default_colors.text;
pub var COLOR_PANEL = default_colors.panel;
pub var COLOR_PANEL_ALT = default_colors.panel_alt;
pub var COLOR_PANEL_MUTED = default_colors.panel_muted;
pub var COLOR_TEXT_MUTED = default_colors.text_muted;
pub var COLOR_TEXT_SUBTLE = default_colors.text_subtle;
pub var COLOR_DIFF_ADD = default_colors.diff_add;
pub var COLOR_DIFF_REMOVE = default_colors.diff_remove;
pub var COLOR_ACCENT_DIM = default_colors.accent_dim;

pub fn background() [4]f32 {
    return current_colors.background;
}

pub fn accent() [4]f32 {
    return current_colors.accent;
}

pub fn border() [4]f32 {
    return current_colors.border;
}

pub fn borderMuted() [4]f32 {
    return current_colors.border_muted;
}

pub fn warning() [4]f32 {
    return current_colors.warning;
}

pub fn success() [4]f32 {
    return current_colors.diff_add;
}

pub fn danger() [4]f32 {
    return current_colors.diff_remove;
}

pub fn selection() [4]f32 {
    return current_colors.selection;
}

/// Chooses the active theme foreground or background token with the clearest
/// luminance separation from a filled control. This keeps accent buttons
/// readable for both light and dark custom themes.
pub fn foregroundOn(fill: [4]f32) [4]f32 {
    const fill_luma = relativeLuma(fill);
    const text_distance = @abs(relativeLuma(current_colors.text) - fill_luma);
    const background_distance = @abs(relativeLuma(current_colors.background) - fill_luma);
    return if (text_distance >= background_distance) current_colors.text else current_colors.background;
}

/// Modal overlay color. Kept as a semantic token so modal surfaces do not
/// embed independent palette values throughout the UI.
pub fn scrim(alpha: f32) [4]f32 {
    return .{ 0.0, 0.0, 0.0, clampf(alpha, 0.0, 1.0) };
}

fn relativeLuma(color: [4]f32) f32 {
    return color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
}

/// Returns a smooth 0..1 breathing pulse for in-progress UI chrome.
pub fn activityPulse(now_ns: i128) f32 {
    const phase = @as(f32, @floatFromInt(@mod(now_ns, ACTIVITY_PULSE_PERIOD_NS))) /
        @as(f32, @floatFromInt(ACTIVITY_PULSE_PERIOD_NS));
    return 0.5 + 0.5 * @sin(phase * std.math.tau);
}

pub fn easeOutCubic(t: f32) f32 {
    const clamped = clampf(t, 0.0, 1.0);
    const inv = 1.0 - clamped;
    return 1.0 - inv * inv * inv;
}

pub fn motionDurationMs(reduced_motion: bool, standard_ms: i64) i64 {
    return if (reduced_motion) MOTION_REDUCED_MS else standard_ms;
}

test "reduced motion collapses standard transition durations" {
    try std.testing.expectEqual(MOTION_FAST_MS, motionDurationMs(false, MOTION_FAST_MS));
    try std.testing.expectEqual(MOTION_BASE_MS, motionDurationMs(false, MOTION_BASE_MS));
    try std.testing.expectEqual(MOTION_REDUCED_MS, motionDurationMs(true, MOTION_FAST_MS));
    try std.testing.expectEqual(MOTION_REDUCED_MS, motionDurationMs(true, MOTION_BASE_MS));
}

pub fn withAlpha(color: [4]f32, alpha: u8) [4]f32 {
    return .{ color[0], color[1], color[2], @as(f32, @floatFromInt(alpha)) / 255.0 };
}

pub fn syncLegacyColors() void {
    COLOR_GREEN = current_colors.accent;
    COLOR_SECONDARY_GREEN = current_colors.border;
    COLOR_YELLOW = current_colors.warning;
    COLOR_NAV_CHAT_BG = current_colors.panel;
    COLOR_BLACK = current_colors.panel;
    COLOR_WHITE = current_colors.text;
    COLOR_PANEL = current_colors.panel;
    COLOR_PANEL_ALT = current_colors.panel_alt;
    COLOR_PANEL_MUTED = current_colors.panel_muted;
    COLOR_TEXT_MUTED = current_colors.text_muted;
    COLOR_TEXT_SUBTLE = current_colors.text_subtle;
    COLOR_DIFF_ADD = current_colors.diff_add;
    COLOR_DIFF_REMOVE = current_colors.diff_remove;
    COLOR_ACCENT_DIM = current_colors.accent_dim;
    syncMarkdownColors();
}

fn syncMarkdownColors() void {
    md.text_body = current_colors.text;
    md.text_h1 = mix(current_colors.warning, current_colors.text, 0.18);
    md.text_h2 = mix(current_colors.warning, current_colors.text, 0.32);
    md.text_h3 = mix(current_colors.accent, current_colors.text, 0.45);
    md.text_h4_h6 = mix(current_colors.text, current_colors.background, 0.14);
    md.text_quote = current_colors.text_muted;

    md.inline_code = mix(current_colors.warning, current_colors.text, 0.18);
    md.link = mix(current_colors.accent, current_colors.text, 0.18);
    md.selection_fill = withAlpha(current_colors.selection, 210);

    md.quote_bg = withAlpha(current_colors.panel_alt, 180);
    md.quote_accent = md.link;
    md.code_bg = darken(current_colors.panel, 0.035);
    md.code_border = current_colors.panel_muted;
    md.inline_code_pill = withAlpha(current_colors.panel_alt, 235);
    md.rule = current_colors.panel_muted;
    md.table_border = current_colors.panel_muted;
    md.table_header_bg = withAlpha(current_colors.panel_alt, 210);

    md.tok_plain = md.text_body;
    md.tok_comment = current_colors.text_subtle;
    md.tok_string = mix(current_colors.diff_add, current_colors.text, 0.12);
    md.tok_number = mix(current_colors.warning, current_colors.text, 0.18);
    md.tok_keyword = mix(current_colors.warning, current_colors.text, 0.05);
    md.tok_type = md.link;
    md.tok_function = mix(current_colors.accent, current_colors.text, 0.10);
    md.tok_property = mix(current_colors.selection, current_colors.text, 0.22);
    md.tok_variable = md.text_body;
    md.tok_constant = mix(current_colors.warning, current_colors.text, 0.24);
    md.tok_punct = current_colors.text_muted;

    md.copy_bg_idle = withAlpha(current_colors.panel_alt, 210);
    md.copy_bg_hover = withAlpha(lighten(current_colors.panel_alt, 0.10), 240);
    md.copy_bg_recent = withAlpha(mix(current_colors.accent, current_colors.background, 0.34), 235);
    md.copy_glyph_idle = current_colors.text_muted;
    md.copy_glyph_hover = current_colors.text;
    md.copy_glyph_recent = mix(current_colors.accent, current_colors.text, 0.22);
}

pub const TRANSCRIPT_BUBBLE_PADDING_X: f32 = 18.0;
pub const TRANSCRIPT_BUBBLE_PADDING_Y: f32 = 14.0;
pub const TRANSCRIPT_BUBBLE_ROUNDING: f32 = 14.0;

/// Markdown rendering palette. Grouped here so a future light theme can swap
/// the whole table in one place. All values are RGBA [4]f32 in 0..1 space.
pub const md = struct {
    // Prose body and headings.
    pub var text_body = rgb(0xE2, 0xE4, 0xE9);
    pub var text_h1 = rgb(0xFF, 0xF2, 0xA8);
    pub var text_h2 = rgb(0xF2, 0xE6, 0x8D);
    pub var text_h3 = rgb(0xDE, 0xE8, 0xFF);
    pub var text_h4_h6 = rgb(0xCF, 0xD7, 0xE5);
    pub var text_quote = rgb(0xB3, 0xBE, 0xD4);

    // Inline-style overrides.
    pub var inline_code = rgb(0xF5, 0xD0, 0x7A);
    pub var link = rgb(0x7A, 0xCA, 0xFF);

    // Selection / chrome.
    pub var selection_fill = rgba(88, 166, 255, 255);

    // Blockquote chrome.
    pub var quote_bg = rgba(38, 41, 48, 140);
    pub var quote_accent = rgb(0x7A, 0xCA, 0xFF);

    // Fenced code block frame.
    pub var code_bg = rgba(24, 24, 28, 255);
    pub var code_border = rgba(52, 54, 62, 255);
    pub var inline_code_pill = rgba(38, 41, 48, 235);

    // Thematic rule (`---`).
    pub var rule = rgba(68, 72, 82, 255);

    // GFM tables.
    pub var table_border = rgba(68, 72, 82, 255);
    pub var table_header_bg = rgba(38, 41, 48, 200);

    // Syntax tokens.
    pub var tok_plain = rgb(0xE2, 0xE4, 0xE9);
    pub var tok_comment = rgb(0x8A, 0x91, 0xA0);
    pub var tok_string = rgb(0x66, 0xDC, 0xAA);
    pub var tok_number = rgb(0xF5, 0xB4, 0x78);
    pub var tok_keyword = rgb(0xFF, 0xD6, 0x66);
    pub var tok_type = rgb(0x7A, 0xCA, 0xFF);
    pub var tok_function = rgb(0x60, 0xDB, 0xDB);
    pub var tok_property = rgb(0x6B, 0xA8, 0xFF);
    pub var tok_variable = rgb(0xE2, 0xE4, 0xE9);
    pub var tok_constant = rgb(0xF1, 0xC4, 0x6B);
    pub var tok_punct = rgb(0xB6, 0xBB, 0xC5);

    // Copy-button states (idle / hover / recently-clicked).
    pub var copy_bg_idle = rgba(38, 41, 48, 200);
    pub var copy_bg_hover = rgba(64, 70, 82, 235);
    pub var copy_bg_recent = rgba(46, 110, 70, 230);
    pub var copy_glyph_idle = rgba(190, 195, 205, 255);
    pub var copy_glyph_hover = rgba(245, 245, 250, 255);
    pub var copy_glyph_recent = rgba(220, 246, 200, 255);
};

pub var heading_font_size: f32 = DEFAULT_FONT_SIZE * 1.28;
pub var terminal_font_size: f32 = DEFAULT_FONT_SIZE * 0.86;
var current_ui_scale: f32 = 1.0;
var current_font_size: f32 = DEFAULT_FONT_SIZE;

pub fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

pub fn uiScaleFactor() f32 {
    // Configured UI font size acts as whole-UI zoom on top of the display
    // scale; DEFAULT_FONT_SIZE keeps the factor at 1.0 for the default config.
    return current_ui_scale * (current_font_size / DEFAULT_FONT_SIZE);
}

/// Physical pixels per logical UI unit before configured font zoom. Companion
/// uses prototype-fixed logical geometry while the rest of Verde may opt into
/// the combined font-size-aware `uiScaleFactor`.
pub fn displayScaleFactor() f32 {
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

/// Loads the active Omarchy colors.toml over the current palette. Returns
/// false when no Omarchy theme could be read.
pub fn loadOmarchyThemeFromDefaultLocations(allocator: std.mem.Allocator) bool {
    const path = resolveOmarchyThemePath(allocator) catch |err| {
        log.debug("omarchy theme path unavailable: {s}", .{@errorName(err)});
        return false;
    };
    defer allocator.free(path);

    loadOmarchyThemeFile(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => log.debug("omarchy colors.toml not found at {s}", .{path}),
            else => log.warn("failed to load omarchy colors.toml from {s}: {s}", .{ path, @errorName(err) }),
        }
        return false;
    };
    return true;
}

/// True when an Omarchy theme file resolves on this machine. Touches the
/// filesystem; callers cache the result rather than asking per frame.
pub fn omarchyThemeAvailable(allocator: std.mem.Allocator) bool {
    if (builtin.os.tag != .linux) return false;
    const path = resolveOmarchyThemePath(allocator) catch return false;
    defer allocator.free(path);
    return fileExists(path);
}

pub fn applyConfigTheme(allocator: std.mem.Allocator, config: ThemeConfig) void {
    switch (config.source) {
        .omarchy => {
            // Omarchy files layer over the original palette, as they always
            // have; without an install the source behaves like Auto.
            current_colors = verde_legacy_colors;
            if (!loadOmarchyThemeFromDefaultLocations(allocator)) current_colors = autoColors(system_appearance);
        },
        else => current_colors = builtinColors(config.source, system_appearance),
    }
    syncLegacyColors();
    applyThemeColorOverrides(config.colors);
}

pub fn loadOmarchyThemeFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;

    const raw = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(1024 * 64));
    defer allocator.free(raw);

    var next = current_colors;
    applyOmarchyColorsToml(raw, &next);
    current_colors = next;
    syncLegacyColors();
}

fn applyThemeColorOverrides(overrides: ThemeColorOverrides) void {
    applyRoleOverrides(overrides, &current_colors);
    syncLegacyColors();
}

/// Applies an Omarchy colors.toml onto `target`. Top-level palette keys
/// (Quattro names or legacy colorN) are mapped onto Verde roles; a `[verde]`
/// section, when present, supplies exact roles that win over the mapping.
/// Other sections (for example `[web]`) are ignored.
pub fn applyOmarchyColorsToml(raw: []const u8, target: *ThemeColors) void {
    var parsed: OmarchyPalette = .{};
    var roles: ThemeColorOverrides = .{};
    var section: TomlSection = .top_level;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        parseOmarchyLine(line, &section, &parsed, &roles);
    }
    // Light Omarchy themes start from Verde Light so any role the file leaves
    // out stays legible; dark themes keep the original fallback palette.
    if (parsed.light_mode) target.* = verde_light_colors;
    applyOmarchyPalette(parsed, target);
    applyRoleOverrides(roles, target);
}

pub fn resolveOmarchyThemePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("VERDE_OMARCHY_COLORS")) |override_ptr| {
        const value = std.mem.trim(u8, std.mem.sliceTo(override_ptr, 0), &std.ascii.whitespace);
        if (value.len > 0) return allocator.dupe(u8, value);
    }

    if (try currentOmarchyThemeColorsPath(allocator)) |path| return path;

    if (std.c.getenv("OMARCHY_CURRENT_THEME")) |theme_ptr| {
        const theme_name = std.mem.trim(u8, std.mem.sliceTo(theme_ptr, 0), &std.ascii.whitespace);
        if (theme_name.len > 0) {
            if (try resolveNamedOmarchyThemePath(allocator, theme_name)) |path| return path;
        }
    }

    if (try readOmarchyCurrentThemeName(allocator)) |theme_name| {
        defer allocator.free(theme_name);
        if (try resolveNamedOmarchyThemePath(allocator, theme_name)) |path| return path;
    }

    if (try firstExistingThemePath(allocator, &.{ "verde", "current" })) |path| return path;
    return error.FileNotFound;
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

const TomlSection = enum { top_level, verde, other };

/// Top-level palette keys from both the Quattro format (named colors) and the
/// older terminal-style format (color0..color15, selection_background).
const OmarchyPalette = struct {
    light_mode: bool = false,
    accent: ?[4]f32 = null,
    foreground: ?[4]f32 = null,
    light_foreground: ?[4]f32 = null,
    dark_foreground: ?[4]f32 = null,
    background: ?[4]f32 = null,
    lighter_background: ?[4]f32 = null,
    selection: ?[4]f32 = null,
    selection_background: ?[4]f32 = null,
    muted: ?[4]f32 = null,
    red: ?[4]f32 = null,
    green: ?[4]f32 = null,
    yellow: ?[4]f32 = null,
    color0: ?[4]f32 = null,
    color1: ?[4]f32 = null,
    color2: ?[4]f32 = null,
    color3: ?[4]f32 = null,
    color4: ?[4]f32 = null,
    color7: ?[4]f32 = null,
    color8: ?[4]f32 = null,
};

fn parseOmarchyLine(line: []const u8, section: *TomlSection, parsed: *OmarchyPalette, roles: *ThemeColorOverrides) void {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    if (trimmed[0] == '[') {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return;
        const name = std.mem.trim(u8, trimmed[1..close], &std.ascii.whitespace);
        section.* = if (std.mem.eql(u8, name, "verde")) .verde else .other;
        return;
    }
    if (section.* == .other) return;

    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
    const value = tomlStringValue(trimmed[eq + 1 ..]) orelse return;

    if (section.* == .top_level and std.mem.eql(u8, key, "mode")) {
        parsed.light_mode = std.ascii.eqlIgnoreCase(value, "light");
        return;
    }

    const color = parseHexColor(value) orelse return;
    switch (section.*) {
        .verde => {
            inline for (std.meta.fields(ThemeColorOverrides)) |field| {
                if (std.mem.eql(u8, key, field.name)) @field(roles, field.name) = color;
            }
        },
        .top_level => {
            inline for (std.meta.fields(OmarchyPalette)) |field| {
                if (field.type != ?[4]f32) continue;
                if (std.mem.eql(u8, key, field.name)) @field(parsed, field.name) = color;
            }
        },
        .other => {},
    }
}

/// Returns the value of a `key = value` right-hand side: the contents of a
/// quoted string, or a bare value with any trailing comment removed. Hex
/// colors contain '#', so comments are only stripped outside quotes.
fn tomlStringValue(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (value.len == 0) return null;
    if (value[0] == '"' or value[0] == '\'') {
        const rest = value[1..];
        const end = std.mem.indexOfScalar(u8, rest, value[0]) orelse return null;
        return rest[0..end];
    }
    const comment = std.mem.indexOfScalarPos(u8, value, 1, '#') orelse value.len;
    return std.mem.trim(u8, value[0..comment], &std.ascii.whitespace);
}

fn applyOmarchyPalette(parsed: OmarchyPalette, target: *ThemeColors) void {
    if (parsed.background) |value| {
        target.background = value;
        target.panel = value;
        target.panel_alt = lighten(value, 0.035);
        target.panel_muted = lighten(value, 0.12);
    }
    if (parsed.foreground) |value| {
        target.text = value;
        target.text_muted = mix(value, target.background, 0.28);
        target.text_subtle = mix(value, target.background, 0.52);
    }
    if (parsed.accent orelse parsed.color4) |value| {
        target.accent = value;
        target.border = mix(value, target.background, 0.44);
        target.accent_dim = withAlpha(value, 54);
    }
    if (parsed.selection_background orelse parsed.selection) |value| target.selection = value;
    if (parsed.lighter_background orelse parsed.color0) |value| target.panel_alt = value;
    // `muted` is the Quattro name for the bright-black slot (color8).
    if (parsed.muted orelse parsed.color8) |value| {
        target.panel_muted = value;
        target.border_muted = value;
    }
    if (parsed.green orelse parsed.color2) |value| target.diff_add = value;
    if (parsed.red orelse parsed.color1) |value| target.diff_remove = value;
    if (parsed.yellow orelse parsed.color3) |value| target.warning = value;
    if (parsed.light_foreground) |value| {
        target.text_muted = value;
    } else if (parsed.color7) |value| {
        target.text_muted = mix(value, target.background, 0.18);
    }
    if (parsed.dark_foreground) |value| target.text_subtle = value;
}

fn applyRoleOverrides(roles: ThemeColorOverrides, target: *ThemeColors) void {
    inline for (std.meta.fields(ThemeColorOverrides)) |field| {
        if (@field(roles, field.name)) |value| @field(target, field.name) = value;
    }
}

/// Parses `#RRGGBB` or `#RRGGBBAA`.
fn parseHexColor(value: []const u8) ?[4]f32 {
    if ((value.len != 7 and value.len != 9) or value[0] != '#') return null;
    const r = std.fmt.parseInt(u8, value[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, value[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, value[5..7], 16) catch return null;
    const a: u8 = if (value.len == 9) std.fmt.parseInt(u8, value[7..9], 16) catch return null else 255;
    return rgba(r, g, b, a);
}

pub fn mix(from: [4]f32, to: [4]f32, amount: f32) [4]f32 {
    const t = clampf(amount, 0.0, 1.0);
    return .{
        from[0] + (to[0] - from[0]) * t,
        from[1] + (to[1] - from[1]) * t,
        from[2] + (to[2] - from[2]) * t,
        from[3] + (to[3] - from[3]) * t,
    };
}

fn readOmarchyCurrentThemeName(allocator: std.mem.Allocator) !?[]u8 {
    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    const home_path = std.mem.sliceTo(home, 0);
    const state_path = try std.fs.path.join(allocator, &.{ home_path, ".local", "state", "omarchy", "current", "theme.name" });
    defer allocator.free(state_path);
    var threaded = std.Io.Threaded.init_single_threaded;
    if (std.Io.Dir.cwd().readFileAlloc(threaded.io(), state_path, allocator, .limited(4096))) |raw| {
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const config_home = try configHome(allocator);
    defer allocator.free(config_home);

    const candidates = [_][]const u8{
        "omarchy/current/theme",
        "omarchy/current/theme.txt",
        "omarchy/current/theme.name",
        "omarchy/theme",
        "omarchy/theme.txt",
        "omarchy/current-theme",
    };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ config_home, candidate });
        defer allocator.free(path);
        const raw = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    return null;
}

fn resolveNamedOmarchyThemePath(allocator: std.mem.Allocator, theme_name: []const u8) !?[]u8 {
    return firstExistingThemePath(allocator, &.{theme_name});
}

fn currentOmarchyThemeColorsPath(allocator: std.mem.Allocator) !?[]u8 {
    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    const home_path = std.mem.sliceTo(home, 0);
    const config_home = try configHome(allocator);
    defer allocator.free(config_home);

    return currentOmarchyThemeColorsPathAt(allocator, home_path, config_home);
}

fn currentOmarchyThemeColorsPathAt(allocator: std.mem.Allocator, home_path: []const u8, config_home: []const u8) !?[]u8 {
    const state_path = try std.fs.path.join(allocator, &.{ home_path, ".local", "state", "omarchy", "current", "theme", "colors.toml" });
    if (fileExists(state_path)) return state_path;
    allocator.free(state_path);

    // Omarchy before Quattro kept the assembled active theme under config.
    const legacy_path = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "current", "theme", "colors.toml" });
    if (fileExists(legacy_path)) return legacy_path;
    allocator.free(legacy_path);
    return null;
}

fn firstExistingThemePath(allocator: std.mem.Allocator, names: []const []const u8) !?[]u8 {
    const config_home = try configHome(allocator);
    defer allocator.free(config_home);

    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    const home_path = std.mem.sliceTo(home, 0);
    for (names) |name| {
        const user_path = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "themes", name, "colors.toml" });
        if (fileExists(user_path)) return user_path;
        allocator.free(user_path);

        const stock_path = try std.fs.path.join(allocator, &.{ home_path, ".local", "share", "omarchy", "themes", name, "colors.toml" });
        if (fileExists(stock_path)) return stock_path;
        allocator.free(stock_path);
    }
    return null;
}

fn configHome(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(xdg_config_home, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".config" });
}

fn fileExists(path: []const u8) bool {
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.Dir.cwd().access(threaded.io(), path, .{}) catch return false;
    return true;
}

test "parse Omarchy colors.toml maps palette into semantic colors" {
    var parsed: ThemeColors = .{};
    applyOmarchyColorsToml(
        \\accent = "#7aa2f7"
        \\foreground = "#a9b1d6"
        \\background = "#1a1b26"
        \\selection_background = "#7aa2f7"
        \\color1 = "#f7768e"
        \\color2 = "#9ece6a"
        \\color3 = "#e0af68"
        \\color8 = "#444b6a"
        \\
    , &parsed);

    try std.testing.expectEqual(rgb(0x1a, 0x1b, 0x26), parsed.background);
    try std.testing.expectEqual(rgb(0x7a, 0xa2, 0xf7), parsed.accent);
    try std.testing.expectEqual(rgb(0x9e, 0xce, 0x6a), parsed.diff_add);
    try std.testing.expectEqual(rgb(0xf7, 0x76, 0x8e), parsed.diff_remove);
    try std.testing.expectEqual(rgb(0xe0, 0xaf, 0x68), parsed.warning);
    try std.testing.expectEqual(rgb(0x44, 0x4b, 0x6a), parsed.border_muted);
}

test "parse Omarchy colors.toml keeps fallback values for missing keys" {
    var parsed: ThemeColors = .{};
    applyOmarchyColorsToml(
        \\foreground = "#eeeeee"
        \\
    , &parsed);

    try std.testing.expectEqual(colors.CHAT_BLACK, parsed.background);
    try std.testing.expectEqual(rgba(255, 100, 100, 255), parsed.diff_remove);
    try std.testing.expectEqual(rgb(0x50, 0xc8, 0x78), parsed.accent);
}

test "active Omarchy theme prefers the Quattro state path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;

    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const home_path = try std.fs.path.join(std.testing.allocator, &.{ root, "home" });
    defer std.testing.allocator.free(home_path);
    const config_home = try std.fs.path.join(std.testing.allocator, &.{ root, "config" });
    defer std.testing.allocator.free(config_home);
    const state_dir = try std.fs.path.join(std.testing.allocator, &.{ home_path, ".local", "state", "omarchy", "current", "theme" });
    defer std.testing.allocator.free(state_dir);
    const legacy_dir = try std.fs.path.join(std.testing.allocator, &.{ config_home, "omarchy", "current", "theme" });
    defer std.testing.allocator.free(legacy_dir);
    try std.Io.Dir.cwd().createDirPath(threaded.io(), state_dir);
    try std.Io.Dir.cwd().createDirPath(threaded.io(), legacy_dir);

    const state_path = try std.fs.path.join(std.testing.allocator, &.{ state_dir, "colors.toml" });
    defer std.testing.allocator.free(state_path);
    const legacy_path = try std.fs.path.join(std.testing.allocator, &.{ legacy_dir, "colors.toml" });
    defer std.testing.allocator.free(legacy_path);
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = state_path, .data = "accent = \"#111111\"\n" });
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = legacy_path, .data = "accent = \"#222222\"\n" });

    const resolved = (try currentOmarchyThemeColorsPathAt(std.testing.allocator, home_path, config_home)).?;
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(state_path, resolved);
}

test "Quattro colors.toml keys map onto Verde roles" {
    var parsed: ThemeColors = .{};
    applyOmarchyColorsToml(
        \\mode = "dark"
        \\accent = "#509475"
        \\selection = "#32473B"
        \\muted = "#53685B"
        \\background = "#111c18"
        \\lighter_background = "#23372B"
        \\foreground = "#C1C497"
        \\dark_foreground = "#81B8A8"
        \\light_foreground = "#D6D5BC"
        \\red = "#FF5345"
        \\yellow = "#E5C736"
        \\green = "#549e6a"
        \\
    , &parsed);

    try std.testing.expectEqual(rgb(0x11, 0x1c, 0x18), parsed.background);
    try std.testing.expectEqual(rgb(0x11, 0x1c, 0x18), parsed.panel);
    try std.testing.expectEqual(rgb(0x23, 0x37, 0x2B), parsed.panel_alt);
    try std.testing.expectEqual(rgb(0x53, 0x68, 0x5B), parsed.panel_muted);
    try std.testing.expectEqual(rgb(0x53, 0x68, 0x5B), parsed.border_muted);
    try std.testing.expectEqual(rgb(0xC1, 0xC4, 0x97), parsed.text);
    try std.testing.expectEqual(rgb(0xD6, 0xD5, 0xBC), parsed.text_muted);
    try std.testing.expectEqual(rgb(0x81, 0xB8, 0xA8), parsed.text_subtle);
    try std.testing.expectEqual(rgb(0x50, 0x94, 0x75), parsed.accent);
    try std.testing.expectEqual(rgb(0x32, 0x47, 0x3B), parsed.selection);
    try std.testing.expectEqual(rgb(0xFF, 0x53, 0x45), parsed.diff_remove);
    try std.testing.expectEqual(rgb(0x54, 0x9e, 0x6a), parsed.diff_add);
    try std.testing.expectEqual(rgb(0xE5, 0xC7, 0x36), parsed.warning);
}

test "Omarchy colors.toml prefers [verde] roles and ignores other sections" {
    var parsed: ThemeColors = .{};
    applyOmarchyColorsToml(
        \\# Verde Dark
        \\mode = "dark"
        \\accent = "#4FD18B"
        \\red = "#F07A70"
        \\yellow = "#E8C15A"
        \\background = "#0B0F0E"
        \\
        \\[verde]
        \\panel = "#121917"
        \\accent_dim = "#4FD18B29"
        \\warning = "#F0B450" # inline comment
        \\
        \\[web]
        \\background = "#FF00FF"
        \\warning = "#FF00FF"
        \\
    , &parsed);

    try std.testing.expectEqual(rgb(0x0B, 0x0F, 0x0E), parsed.background);
    try std.testing.expectEqual(rgb(0x12, 0x19, 0x17), parsed.panel);
    try std.testing.expectEqual(rgba(0x4F, 0xD1, 0x8B, 0x29), parsed.accent_dim);
    try std.testing.expectEqual(rgb(0xF0, 0xB4, 0x50), parsed.warning);
    try std.testing.expectEqual(rgb(0xF0, 0x7A, 0x70), parsed.diff_remove);
}

test "light Omarchy themes fall back to the Verde Light palette" {
    var parsed: ThemeColors = .{};
    applyOmarchyColorsToml(
        \\mode = "light"
        \\accent = "#205ea6"
        \\
    , &parsed);
    try std.testing.expectEqual(rgb(0x20, 0x5e, 0xa6), parsed.accent);
    try std.testing.expectEqual(verde_light_colors.background, parsed.background);
    try std.testing.expectEqual(verde_light_colors.diff_remove, parsed.diff_remove);
}

test "theme source names parse with legacy aliases" {
    try std.testing.expectEqual(ThemeSource.auto, ThemeSource.parse("auto").?);
    try std.testing.expectEqual(ThemeSource.verde_dark, ThemeSource.parse("verde-dark").?);
    try std.testing.expectEqual(ThemeSource.verde_light, ThemeSource.parse(" Verde_Light ").?);
    try std.testing.expectEqual(ThemeSource.verde_legacy, ThemeSource.parse("verde-legacy").?);
    try std.testing.expectEqual(ThemeSource.verde_legacy, ThemeSource.parse("default").?);
    try std.testing.expectEqual(ThemeSource.verde_legacy, ThemeSource.parse("verde").?);
    try std.testing.expectEqual(ThemeSource.omarchy, ThemeSource.parse("OMARCHY").?);
    try std.testing.expect(ThemeSource.parse("solarized") == null);
    for (ThemeSource.builtin_choices) |source| {
        try std.testing.expectEqual(source, ThemeSource.parse(source.configName()).?);
    }
}

test "default theme source depends on Omarchy detection" {
    try std.testing.expectEqual(ThemeSource.omarchy, defaultThemeSource(true));
    try std.testing.expectEqual(ThemeSource.auto, defaultThemeSource(false));
    try std.testing.expectEqual(ThemeSource.auto, effectiveThemeSource(.omarchy, false));
    try std.testing.expectEqual(ThemeSource.omarchy, effectiveThemeSource(.omarchy, true));
    try std.testing.expectEqual(ThemeSource.verde_light, effectiveThemeSource(.verde_light, false));
}

test "built-in palettes resolve per source and appearance" {
    try std.testing.expectEqual(default_colors, builtinColors(.verde_legacy, .light));
    try std.testing.expectEqual(verde_dark_colors, builtinColors(.auto, .dark));
    try std.testing.expectEqual(verde_light_colors, builtinColors(.auto, .light));
    try std.testing.expectEqual(verde_dark_colors, builtinColors(.verde_dark, .light));
    try std.testing.expectEqual(rgba(0x15, 0x80, 0x3D, 0x1F), verde_light_colors.accent_dim);
}

test "Verde Legacy [verde] roles reproduce the original palette exactly" {
    var parsed: ThemeColors = verde_dark_colors;
    applyOmarchyColorsToml(
        \\[verde]
        \\background = "#0D1213"
        \\panel = "#20272A"
        \\panel_alt = "#28292E"
        \\panel_muted = "#38393E"
        \\text = "#F0F0F5"
        \\text_muted = "#B9BBC3"
        \\text_subtle = "#787A87"
        \\accent = "#50C878"
        \\accent_dim = "#7CDD5E30"
        \\border = "#375846"
        \\border_muted = "#3C474C"
        \\warning = "#FBBF24"
        \\diff_add = "#34E094"
        \\diff_remove = "#FF6464"
        \\selection = "#58A6FF"
        \\
    , &parsed);
    try std.testing.expectEqual(default_colors, parsed);
}

//! Shared native UI theme tokens and helpers.

const std = @import("std");
const colors = @import("colors.zig");
const rgba = colors.rgba;
const rgb = colors.rgb;

const log = std.log.scoped(.ui_theme);

pub const DEFAULT_FONT_SIZE: f32 = 24.0;
pub const RESPONSIVE_BASE_FONT_SIZE: f32 = 22.0;

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

pub const ThemeSource = enum {
    omarchy,
    default,
};

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

pub fn borderMuted() [4]f32 {
    return current_colors.border_muted;
}

pub fn selection() [4]f32 {
    return current_colors.selection;
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
}

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

pub fn loadOmarchyThemeFromDefaultLocations(allocator: std.mem.Allocator) void {
    const path = resolveOmarchyThemePath(allocator) catch |err| {
        log.debug("omarchy theme path unavailable: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(path);

    loadOmarchyThemeFile(allocator, path) catch |err| switch (err) {
        error.FileNotFound => log.debug("omarchy colors.toml not found at {s}", .{path}),
        else => log.warn("failed to load omarchy colors.toml from {s}: {s}", .{ path, @errorName(err) }),
    };
}

pub fn applyConfigTheme(allocator: std.mem.Allocator, config: ThemeConfig) void {
    current_colors = default_colors;
    syncLegacyColors();
    switch (config.source) {
        .omarchy => loadOmarchyThemeFromDefaultLocations(allocator),
        .default => {},
    }
    applyThemeColorOverrides(config.colors);
}

pub fn loadOmarchyThemeFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const raw = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(1024 * 64));
    defer allocator.free(raw);

    var next = current_colors;
    applyOmarchyColorsToml(raw, &next);
    current_colors = next;
    syncLegacyColors();
}

fn applyThemeColorOverrides(overrides: ThemeColorOverrides) void {
    if (overrides.background) |value| current_colors.background = value;
    if (overrides.panel) |value| current_colors.panel = value;
    if (overrides.panel_alt) |value| current_colors.panel_alt = value;
    if (overrides.panel_muted) |value| current_colors.panel_muted = value;
    if (overrides.text) |value| current_colors.text = value;
    if (overrides.text_muted) |value| current_colors.text_muted = value;
    if (overrides.text_subtle) |value| current_colors.text_subtle = value;
    if (overrides.accent) |value| current_colors.accent = value;
    if (overrides.accent_dim) |value| current_colors.accent_dim = value;
    if (overrides.border) |value| current_colors.border = value;
    if (overrides.border_muted) |value| current_colors.border_muted = value;
    if (overrides.warning) |value| current_colors.warning = value;
    if (overrides.diff_add) |value| current_colors.diff_add = value;
    if (overrides.diff_remove) |value| current_colors.diff_remove = value;
    if (overrides.selection) |value| current_colors.selection = value;
    syncLegacyColors();
}

pub fn applyOmarchyColorsToml(raw: []const u8, target: *ThemeColors) void {
    var parsed: OmarchyPalette = .{};
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        parseOmarchyLine(line, &parsed);
    }
    applyOmarchyPalette(parsed, target);
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

const OmarchyPalette = struct {
    accent: ?[4]f32 = null,
    foreground: ?[4]f32 = null,
    background: ?[4]f32 = null,
    selection_background: ?[4]f32 = null,
    color0: ?[4]f32 = null,
    color1: ?[4]f32 = null,
    color2: ?[4]f32 = null,
    color3: ?[4]f32 = null,
    color4: ?[4]f32 = null,
    color7: ?[4]f32 = null,
    color8: ?[4]f32 = null,
};

fn parseOmarchyLine(line: []const u8, parsed: *OmarchyPalette) void {
    const without_comment = std.mem.sliceTo(line, '#');
    if (std.mem.indexOfScalar(u8, without_comment, '=') == null and std.mem.indexOfScalar(u8, line, '=') != null) {
        // Hex colors contain '#', so only strip comments from lines without quoted values below.
    }
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
    var value = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);
    if (value.len == 0) return;
    if (value[0] == '"' or value[0] == '\'') {
        const quote = value[0];
        value = value[1..];
        const end = std.mem.indexOfScalar(u8, value, quote) orelse return;
        value = value[0..end];
    } else if (std.mem.indexOfScalar(u8, value, '#')) |comment| {
        value = std.mem.trim(u8, value[0..comment], &std.ascii.whitespace);
    }

    const color = parseHexColor(value) orelse return;
    if (std.mem.eql(u8, key, "accent")) parsed.accent = color else if (std.mem.eql(u8, key, "foreground")) parsed.foreground = color else if (std.mem.eql(u8, key, "background")) parsed.background = color else if (std.mem.eql(u8, key, "selection_background")) parsed.selection_background = color else if (std.mem.eql(u8, key, "color0")) parsed.color0 = color else if (std.mem.eql(u8, key, "color1")) parsed.color1 = color else if (std.mem.eql(u8, key, "color2")) parsed.color2 = color else if (std.mem.eql(u8, key, "color3")) parsed.color3 = color else if (std.mem.eql(u8, key, "color4")) parsed.color4 = color else if (std.mem.eql(u8, key, "color7")) parsed.color7 = color else if (std.mem.eql(u8, key, "color8")) parsed.color8 = color;
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
    if (parsed.selection_background) |value| target.selection = value;
    if (parsed.color0) |value| target.panel_alt = value;
    if (parsed.color8) |value| {
        target.panel_muted = value;
        target.border_muted = value;
    }
    if (parsed.color2) |value| target.diff_add = value;
    if (parsed.color1) |value| target.diff_remove = value;
    if (parsed.color3) |value| target.warning = value;
    if (parsed.color7) |value| target.text_muted = mix(value, target.background, 0.18);
}

fn parseHexColor(value: []const u8) ?[4]f32 {
    if (value.len != 7 or value[0] != '#') return null;
    const r = std.fmt.parseInt(u8, value[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, value[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, value[5..7], 16) catch return null;
    return rgb(r, g, b);
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
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
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
    const config_home = try configHome(allocator);
    defer allocator.free(config_home);

    const path = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "current", "theme", "colors.toml" });
    if (fileExists(path)) return path;
    allocator.free(path);
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
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
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

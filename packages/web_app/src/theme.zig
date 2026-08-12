//! Resolve UI colors the same way the desktop app does:
//! default Verde tokens → optional Omarchy colors.toml → verde.json overrides.
//!
//! Duplicated here (not imported from packages/desktop) so the gateway stays
//! free of SDL/Palette. Keep the search order and mix ratios in lockstep with
//! packages/desktop/src/ui/theme.zig.

const std = @import("std");

const log = std.log.scoped(.web_theme);

pub const Colors = struct {
    background: [4]f32 = rgb(0x0d, 0x12, 0x13),
    panel: [4]f32 = rgb(0x20, 0x27, 0x2a),
    panel_alt: [4]f32 = rgb(40, 41, 46),
    panel_muted: [4]f32 = rgb(56, 57, 62),
    text: [4]f32 = rgb(240, 240, 245),
    text_muted: [4]f32 = rgb(185, 187, 195),
    text_subtle: [4]f32 = rgb(120, 122, 135),
    accent: [4]f32 = rgb(0x50, 0xc8, 0x78),
    accent_dim: [4]f32 = rgba(124, 221, 94, 48),
    border: [4]f32 = rgb(0x37, 0x58, 0x46),
    border_muted: [4]f32 = rgb(0x3c, 0x47, 0x4c),
    warning: [4]f32 = rgb(0xfb, 0xbf, 0x24),
    diff_add: [4]f32 = rgb(52, 224, 148),
    diff_remove: [4]f32 = rgb(255, 100, 100),
    selection: [4]f32 = rgb(88, 166, 255),
};

pub const TerminalTheme = struct {
    background: [4]f32 = rgb(0x0d, 0x12, 0x13),
    foreground: [4]f32 = rgb(240, 240, 245),
    cursor: [4]f32 = rgb(185, 187, 195),
    palette: [16][4]f32 = [_][4]f32{rgb(0, 0, 0)} ** 16,
};

pub const Resolved = struct {
    colors: Colors,
    terminal: TerminalTheme,
    source: []const u8,
    active: []const u8,
    config_path: []const u8,
    omarchy_path: []const u8,
};

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) !Resolved {
    var colors: Colors = .{};
    var ansi: [16]?[4]f32 = [_]?[4]f32{null} ** 16;
    var source: []const u8 = "default";
    var active: []const u8 = "Verde";
    var config_path: []const u8 = "";
    var omarchy_path: []const u8 = "";

    const cfg_path = try verdeConfigPath(allocator, env_map);
    config_path = cfg_path;

    var use_omarchy = true;
    if (readFileLimited(allocator, io, cfg_path, 128 * 1024)) |raw| {
        defer allocator.free(raw);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch null;
        if (parsed) |*tree| {
            defer tree.deinit();
            if (tree.value == .object) {
                if (tree.value.object.get("theme")) |theme_value| {
                    if (theme_value == .object) {
                        if (jsonString(theme_value.object.get("theme"))) |name| {
                            if (eqlIgnore(name, "default") or eqlIgnore(name, "verde")) use_omarchy = false;
                            if (eqlIgnore(name, "omarchy") or eqlIgnore(name, "auto")) use_omarchy = true;
                        }
                        if (jsonString(theme_value.object.get("active"))) |name| {
                            if (name.len > 0) active = try allocator.dupe(u8, name);
                        }
                    }
                }
                if (use_omarchy) {
                    if (try loadOmarchy(allocator, io, env_map, &colors, &ansi)) |path| {
                        omarchy_path = path;
                        source = "omarchy";
                    }
                }
                if (tree.value.object.get("theme")) |theme_value| {
                    if (theme_value == .object) {
                        if (theme_value.object.get("colors")) |overrides| {
                            applyJsonOverrides(&colors, overrides);
                        }
                    }
                }
            }
        }
    } else |_| {
        if (try loadOmarchy(allocator, io, env_map, &colors, &ansi)) |path| {
            omarchy_path = path;
            source = "omarchy";
        }
    }

    // Amp/Codex/Claude/Cursor read the Ghostty/Omarchy ANSI palette even
    // when the Verde UI theme is pinned to default tokens.
    if (ansi[0] == null) {
        _ = loadOmarchy(allocator, io, env_map, &colors, &ansi) catch null;
    }

    var terminal = terminalFromColors(colors);
    applyAnsiOverrides(&terminal, ansi);
    loadGhosttyTheme(allocator, io, env_map, &terminal) catch {};
    loadOmarchyGhosttyTheme(allocator, io, env_map, &terminal) catch {};

    return .{
        .colors = colors,
        .terminal = terminal,
        .source = source,
        .active = active,
        .config_path = config_path,
        .omarchy_path = omarchy_path,
    };
}

pub fn encodeJson(allocator: std.mem.Allocator, resolved: Resolved) ![]u8 {
    var background: [9]u8 = undefined;
    var panel: [9]u8 = undefined;
    var panel_alt: [9]u8 = undefined;
    var panel_muted: [9]u8 = undefined;
    var text: [9]u8 = undefined;
    var text_muted: [9]u8 = undefined;
    var text_subtle: [9]u8 = undefined;
    var accent: [9]u8 = undefined;
    var accent_dim: [9]u8 = undefined;
    var border: [9]u8 = undefined;
    var border_muted: [9]u8 = undefined;
    var warning: [9]u8 = undefined;
    var diff_add: [9]u8 = undefined;
    var diff_remove: [9]u8 = undefined;
    var selection: [9]u8 = undefined;
    var term_bg: [9]u8 = undefined;
    var term_fg: [9]u8 = undefined;
    var term_cursor: [9]u8 = undefined;
    var term_palette: [16][9]u8 = undefined;
    var palette_hex: [16][]const u8 = undefined;
    for (resolved.terminal.palette, 0..) |color, index| {
        palette_hex[index] = fillHex(&term_palette[index], color);
    }
    const payload = .{
        .ok = true,
        .source = resolved.source,
        .active = resolved.active,
        .config_path = resolved.config_path,
        .omarchy_path = resolved.omarchy_path,
        .terminal = .{
            .background = fillHex(&term_bg, resolved.terminal.background),
            .foreground = fillHex(&term_fg, resolved.terminal.foreground),
            .cursor = fillHex(&term_cursor, resolved.terminal.cursor),
            .palette = palette_hex,
        },
        .colors = .{
            .background = fillHex(&background, resolved.colors.background),
            .panel = fillHex(&panel, resolved.colors.panel),
            .panel_alt = fillHex(&panel_alt, resolved.colors.panel_alt),
            .panel_muted = fillHex(&panel_muted, resolved.colors.panel_muted),
            .text = fillHex(&text, resolved.colors.text),
            .text_muted = fillHex(&text_muted, resolved.colors.text_muted),
            .text_subtle = fillHex(&text_subtle, resolved.colors.text_subtle),
            .accent = fillHex(&accent, resolved.colors.accent),
            .accent_dim = fillHex(&accent_dim, resolved.colors.accent_dim),
            .border = fillHex(&border, resolved.colors.border),
            .border_muted = fillHex(&border_muted, resolved.colors.border_muted),
            .warning = fillHex(&warning, resolved.colors.warning),
            .diff_add = fillHex(&diff_add, resolved.colors.diff_add),
            .diff_remove = fillHex(&diff_remove, resolved.colors.diff_remove),
            .selection = fillHex(&selection, resolved.colors.selection),
        },
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(payload);
    return try writer.toOwnedSlice();
}

fn loadOmarchy(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, colors: *Colors, ansi: *[16]?[4]f32) !?[]u8 {
    const path = resolveOmarchyPath(allocator, env_map) catch return null;
    const raw = readFileLimited(allocator, io, path, 64 * 1024) catch {
        allocator.free(path);
        return null;
    };
    defer allocator.free(raw);
    applyOmarchyToml(raw, colors, ansi);
    return path;
}

fn resolveOmarchyPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("VERDE_OMARCHY_COLORS")) |override| {
        const value = std.mem.trim(u8, override, &std.ascii.whitespace);
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    const current = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "current", "theme", "colors.toml" });
    if (pathExists(current)) return current;
    allocator.free(current);
    return error.FileNotFound;
}

fn applyOmarchyToml(raw: []const u8, target: *Colors, ansi: *[16]?[4]f32) void {
    var accent: ?[4]f32 = null;
    var foreground: ?[4]f32 = null;
    var background: ?[4]f32 = null;
    var selection_background: ?[4]f32 = null;
    var color0: ?[4]f32 = null;
    var color1: ?[4]f32 = null;
    var color2: ?[4]f32 = null;
    var color3: ?[4]f32 = null;
    var color4: ?[4]f32 = null;
    var color7: ?[4]f32 = null;
    var color8: ?[4]f32 = null;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        var value = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);
        if (value.len == 0) continue;
        if (value[0] == '"' or value[0] == '\'') {
            const quote = value[0];
            value = value[1..];
            const end = std.mem.indexOfScalar(u8, value, quote) orelse continue;
            value = value[0..end];
        }
        const color = parseHex(value) orelse continue;
        if (std.mem.eql(u8, key, "accent")) accent = color;
        if (std.mem.eql(u8, key, "foreground")) foreground = color;
        if (std.mem.eql(u8, key, "background")) background = color;
        if (std.mem.eql(u8, key, "selection_background")) selection_background = color;
        if (std.mem.eql(u8, key, "cursor")) color7 = color7 orelse color;
        if (std.mem.eql(u8, key, "color0")) color0 = color;
        if (std.mem.eql(u8, key, "color1")) color1 = color;
        if (std.mem.eql(u8, key, "color2")) color2 = color;
        if (std.mem.eql(u8, key, "color3")) color3 = color;
        if (std.mem.eql(u8, key, "color4")) color4 = color;
        if (std.mem.eql(u8, key, "color7")) color7 = color;
        if (std.mem.eql(u8, key, "color8")) color8 = color;
        if (key.len >= 6 and std.mem.startsWith(u8, key, "color")) {
            if (std.fmt.parseInt(usize, key[5..], 10)) |index| {
                if (index < ansi.len) ansi.*[index] = color;
            } else |_| {}
        }
    }

    if (background) |value| {
        target.background = value;
        target.panel = value;
        target.panel_alt = lighten(value, 0.035);
        target.panel_muted = lighten(value, 0.12);
    }
    if (foreground) |value| {
        target.text = value;
        target.text_muted = mix(value, target.background, 0.28);
        target.text_subtle = mix(value, target.background, 0.52);
    }
    if (accent orelse color4) |value| {
        target.accent = value;
        target.border = mix(value, target.background, 0.44);
        target.accent_dim = withAlpha(value, 54);
    }
    if (selection_background) |value| target.selection = value;
    if (color0) |value| target.panel_alt = value;
    if (color8) |value| {
        target.panel_muted = value;
        target.border_muted = value;
    }
    if (color2) |value| target.diff_add = value;
    if (color1) |value| target.diff_remove = value;
    if (color3) |value| target.warning = value;
    if (color7) |value| target.text_muted = mix(value, target.background, 0.18);
}

fn applyJsonOverrides(colors: *Colors, value: std.json.Value) void {
    if (value != .object) return;
    inline for (.{
        "background", "panel", "panel_alt", "panel_muted", "text", "text_muted",
        "text_subtle", "accent", "accent_dim", "border", "border_muted", "warning",
        "diff_add", "diff_remove", "selection",
    }) |name| {
        if (jsonString(value.object.get(name))) |hex| {
            if (parseHex(hex)) |parsed| {
                @field(colors, name) = parsed;
            }
        }
    }
}

fn verdeConfigPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("VERDE_CONFIG")) |override| {
        const value = std.mem.trim(u8, override, &std.ascii.whitespace);
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    return std.fs.path.join(allocator, &.{ config_home, "verde", "verde.json" });
}

fn configHome(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("XDG_CONFIG_HOME")) |xdg| {
        const trimmed = std.mem.trim(u8, xdg, &std.ascii.whitespace);
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    const home = env_map.get("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".config" });
}

fn readFileLimited(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn pathExists(path: []const u8) bool {
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.Dir.cwd().access(threaded.io(), path, .{}) catch return false;
    return true;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |s| s,
        else => null,
    };
}

fn eqlIgnore(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseHex(value: []const u8) ?[4]f32 {
    if (value.len < 7 or value[0] != '#') return null;
    const r = std.fmt.parseInt(u8, value[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, value[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, value[5..7], 16) catch return null;
    const a: u8 = if (value.len >= 9) (std.fmt.parseInt(u8, value[7..9], 16) catch 255) else 255;
    return rgba(r, g, b, a);
}

fn fillHex(buf: *[9]u8, color: [4]f32) []const u8 {
    const r: u8 = @intFromFloat(@round(clampf(color[0]) * 255.0));
    const g: u8 = @intFromFloat(@round(clampf(color[1]) * 255.0));
    const b: u8 = @intFromFloat(@round(clampf(color[2]) * 255.0));
    const a: u8 = @intFromFloat(@round(clampf(color[3]) * 255.0));
    if (a == 255) {
        return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch "#000000";
    }
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a }) catch "#000000";
}

fn rgb(r: u8, g: u8, b: u8) [4]f32 {
    return rgba(r, g, b, 255);
}

fn rgba(r: u8, g: u8, b: u8, a: u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn mix(from: [4]f32, to: [4]f32, amount: f32) [4]f32 {
    const t = clampf(amount);
    return .{
        from[0] + (to[0] - from[0]) * t,
        from[1] + (to[1] - from[1]) * t,
        from[2] + (to[2] - from[2]) * t,
        from[3] + (to[3] - from[3]) * t,
    };
}

fn lighten(color: [4]f32, amount: f32) [4]f32 {
    return .{
        clampf(color[0] + amount),
        clampf(color[1] + amount),
        clampf(color[2] + amount),
        color[3],
    };
}

fn withAlpha(color: [4]f32, alpha_u8: u8) [4]f32 {
    return .{ color[0], color[1], color[2], @as(f32, @floatFromInt(alpha_u8)) / 255.0 };
}

fn clampf(value: f32) f32 {
    return @min(@max(value, 0.0), 1.0);
}

fn terminalFromColors(colors: Colors) TerminalTheme {
    const subtle = colors.text_subtle;
    const danger = colors.diff_remove;
    const green = colors.diff_add;
    const yellow = colors.warning;
    const selection = colors.selection;
    const accent_dim = colors.accent;
    const muted = colors.text_muted;
    const white = colors.text;
    return .{
        .background = colors.background,
        .foreground = white,
        .cursor = muted,
        .palette = .{
            subtle,
            danger,
            green,
            yellow,
            selection,
            accent_dim,
            muted,
            white,
            muted,
            lighten(danger, 0.12),
            lighten(green, 0.12),
            lighten(yellow, 0.12),
            lighten(selection, 0.12),
            lighten(accent_dim, 0.2),
            lighten(muted, 0.14),
            lighten(white, 0.04),
        },
    };
}

fn applyAnsiOverrides(terminal: *TerminalTheme, ansi: [16]?[4]f32) void {
    for (ansi, 0..) |maybe, index| {
        if (maybe) |color| terminal.palette[index] = color;
    }
    if (ansi[7]) |color| terminal.cursor = color;
    if (ansi[15]) |color| terminal.foreground = color;
}

fn loadOmarchyGhosttyTheme(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, terminal: *TerminalTheme) !void {
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    const path = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "current", "theme", "ghostty.conf" });
    defer allocator.free(path);
    try parseGhosttyThemeFile(allocator, io, env_map, path, terminal, false);
}

fn loadGhosttyTheme(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, terminal: *TerminalTheme) !void {
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    const config_path = try std.fs.path.join(allocator, &.{ config_home, "ghostty", "config" });
    defer allocator.free(config_path);
    try parseGhosttyThemeFile(allocator, io, env_map, config_path, terminal, true);
}

fn parseGhosttyThemeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    path: []const u8,
    terminal: *TerminalTheme,
    follow_includes: bool,
) !void {
    const content = readFileLimited(allocator, io, path, 64 * 1024) catch return;
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t\r");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "background")) {
            if (parseHex(value)) |color| terminal.background = color;
        } else if (std.mem.eql(u8, key, "foreground")) {
            if (parseHex(value)) |color| terminal.foreground = color;
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            if (parseHex(value)) |color| terminal.cursor = color;
        } else if (std.mem.eql(u8, key, "palette")) {
            parseGhosttyPalette(value, terminal);
        } else if (follow_includes and std.mem.eql(u8, key, "config-file")) {
            const include_path = resolveGhosttyPath(allocator, env_map, path, value) catch continue;
            defer allocator.free(include_path);
            parseGhosttyThemeFile(allocator, io, env_map, include_path, terminal, false) catch {};
        }
    }
}

fn parseGhosttyPalette(value: []const u8, terminal: *TerminalTheme) void {
    const equals = std.mem.indexOfScalar(u8, value, '=') orelse return;
    const index_text = std.mem.trim(u8, value[0..equals], " \t\r");
    const color_text = std.mem.trim(u8, value[equals + 1 ..], " \t\r");
    const index = std.fmt.parseInt(usize, index_text, 10) catch return;
    if (index >= terminal.palette.len) return;
    terminal.palette[index] = parseHex(color_text) orelse return;
}

fn resolveGhosttyPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, base_path: []const u8, raw_value: []const u8) ![]u8 {
    var value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len > 0 and value[0] == '?') value = std.mem.trim(u8, value[1..], " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (std.mem.startsWith(u8, value, "~/")) {
        const home = env_map.get("HOME") orelse return error.HomeUnset;
        return std.fs.path.join(allocator, &.{ home, value[2..] });
    }
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    const base_dir = std.fs.path.dirname(base_path) orelse ".";
    return std.fs.path.join(allocator, &.{ base_dir, value });
}

test "omarchy toml maps the same way as desktop" {
    var parsed: Colors = .{};
    var ansi: [16]?[4]f32 = [_]?[4]f32{null} ** 16;
    applyOmarchyToml(
        \\accent = "#7aa2f7"
        \\foreground = "#a9b1d6"
        \\background = "#1a1b26"
        \\selection_background = "#7aa2f7"
        \\color1 = "#f7768e"
        \\color2 = "#9ece6a"
        \\color3 = "#e0af68"
        \\color8 = "#444b6a"
        \\
    , &parsed, &ansi);
    try std.testing.expectEqual(rgb(0x1a, 0x1b, 0x26), parsed.background);
    try std.testing.expectEqual(rgb(0x7a, 0xa2, 0xf7), parsed.accent);
    try std.testing.expectEqual(rgb(0xe0, 0xaf, 0x68), parsed.warning);
}

test {
    _ = applyJsonOverrides;
}

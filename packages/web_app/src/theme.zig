//! Resolve UI colors the same way the desktop app does:
//! theme source (built-in palette or Omarchy colors.toml) → verde.json overrides.
//!
//! Duplicated here (not imported from packages/desktop) so the gateway stays
//! free of SDL/Palette. Keep palettes, key mapping, search order, and mix
//! ratios in lockstep with packages/desktop/src/ui/theme.zig and the terminal
//! palette in packages/desktop/src/terminal/terminal.zig.

const std = @import("std");

const log = std.log.scoped(.web_theme);

/// Original Verde palette ("Verde Legacy"); desktop `ThemeColors` defaults.
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

const ColorOverrides = struct {
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

const verde_legacy_colors: Colors = .{};

const verde_dark_colors: Colors = .{
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

const verde_light_colors: Colors = .{
    .background = hexColor("#F7F9F8"),
    .panel = hexColor("#FFFFFF"),
    .panel_alt = hexColor("#F3F6F4"),
    .panel_muted = hexColor("#DCE2DF"),
    .text = hexColor("#0F1715"),
    .text_muted = hexColor("#3B4743"),
    .text_subtle = hexColor("#5C6964"),
    .accent = hexColor("#15803D"),
    .accent_dim = hexColor("#15803D1F"),
    .border = hexColor("#A6D4B8"),
    .border_muted = hexColor("#C5CECA"),
    .warning = hexColor("#B45309"),
    .diff_add = hexColor("#1A7F43"),
    .diff_remove = hexColor("#C4302B"),
    .selection = hexColor("#BFE3CD"),
};

/// Mirrors desktop `ThemeSource`. The gateway cannot see the desktop's OS
/// appearance, so `auto` resolves to Verde Dark (the desktop default).
const Source = enum {
    auto,
    verde_dark,
    verde_light,
    verde_legacy,
    omarchy,

    fn parse(raw: []const u8) ?Source {
        const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (value.len == 0 or value.len > 32) return null;
        var buffer: [32]u8 = undefined;
        for (value, 0..) |char, index| {
            buffer[index] = if (char == '_') '-' else std.ascii.toLower(char);
        }
        const name = buffer[0..value.len];
        const aliases = [_]struct { name: []const u8, source: Source }{
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

    fn builtinColors(self: Source) Colors {
        return switch (self) {
            .auto, .omarchy, .verde_dark => verde_dark_colors,
            .verde_light => verde_light_colors,
            .verde_legacy => verde_legacy_colors,
        };
    }
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
    var source: Source = .omarchy;
    var overrides: ColorOverrides = .{};
    var active: []const u8 = "Verde";
    var omarchy_path: []const u8 = "";

    const config_path = try verdeConfigPath(allocator, env_map);

    if (readFileLimited(allocator, io, config_path, 128 * 1024)) |raw| {
        defer allocator.free(raw);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch null;
        if (parsed) |tree| {
            defer tree.deinit();
            const theme_value = if (tree.value == .object) tree.value.object.get("theme") else null;
            if (theme_value) |value| {
                if (value == .object) {
                    if (jsonString(value.object.get("theme"))) |name| {
                        if (Source.parse(name)) |parsed_source| source = parsed_source;
                    }
                    if (jsonString(value.object.get("active"))) |name| {
                        if (name.len > 0) active = try allocator.dupe(u8, name);
                    }
                    if (value.object.get("colors")) |colors_value| applyJsonOverrides(&overrides, colors_value);
                }
            }
        }
    } else |_| {}

    var colors: Colors = source.builtinColors();
    var omarchy_active = false;
    if (source == .omarchy) {
        // Omarchy files layer over the original palette, as on desktop;
        // without an install the source behaves like Auto.
        colors = verde_legacy_colors;
        if (try loadOmarchy(allocator, io, env_map, &colors)) |path| {
            omarchy_path = path;
            omarchy_active = true;
        } else {
            colors = Source.auto.builtinColors();
        }
    }
    applyRoleOverrides(overrides, &colors);

    var terminal = terminalFromColors(colors);
    // Ghostty's config is themed by Omarchy, so terminals only follow it while
    // the UI does too; built-in palettes keep Verde's own terminal colours.
    if (omarchy_active) loadGhosttyTheme(allocator, io, env_map, &terminal) catch {};

    return .{
        .colors = colors,
        .terminal = terminal,
        .source = if (omarchy_active) "omarchy" else @tagName(source),
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

fn loadOmarchy(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, colors: *Colors) !?[]u8 {
    const path = resolveOmarchyPath(allocator, io, env_map) catch return null;
    const raw = readFileLimited(allocator, io, path, 64 * 1024) catch {
        allocator.free(path);
        return null;
    };
    defer allocator.free(raw);
    applyOmarchyToml(raw, colors);
    return path;
}

fn resolveOmarchyPath(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("VERDE_OMARCHY_COLORS")) |override| {
        const value = std.mem.trim(u8, override, &std.ascii.whitespace);
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    if (try currentOmarchyThemeFilePath(allocator, env_map, "colors.toml")) |path| return path;

    if (env_map.get("OMARCHY_CURRENT_THEME")) |raw_name| {
        const name = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
        if (name.len > 0) {
            if (try firstExistingThemePath(allocator, env_map, &.{name})) |path| return path;
        }
    }
    if (try readOmarchyCurrentThemeName(allocator, io, env_map)) |name| {
        defer allocator.free(name);
        if (try firstExistingThemePath(allocator, env_map, &.{name})) |path| return path;
    }
    if (try firstExistingThemePath(allocator, env_map, &.{ "verde", "current" })) |path| return path;
    return error.FileNotFound;
}

fn readOmarchyCurrentThemeName(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) !?[]u8 {
    const home = env_map.get("HOME") orelse return error.EnvironmentVariableNotFound;
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    const state_path = try std.fs.path.join(allocator, &.{ home, ".local", "state", "omarchy", "current", "theme.name" });
    defer allocator.free(state_path);
    const candidates = [_][]const u8{
        "omarchy/current/theme",
        "omarchy/current/theme.txt",
        "omarchy/current/theme.name",
        "omarchy/theme",
        "omarchy/theme.txt",
        "omarchy/current-theme",
    };
    var paths: [candidates.len + 1][]const u8 = undefined;
    paths[0] = state_path;
    var owned: [candidates.len][]u8 = undefined;
    for (candidates, 0..) |candidate, index| {
        owned[index] = try std.fs.path.join(allocator, &.{ config_home, candidate });
        paths[index + 1] = owned[index];
    }
    defer for (owned) |path| allocator.free(path);
    for (paths) |path| {
        const raw = readFileLimited(allocator, io, path, 4096) catch continue;
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    return null;
}

fn firstExistingThemePath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, names: []const []const u8) !?[]u8 {
    const home = env_map.get("HOME") orelse return error.EnvironmentVariableNotFound;
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    for (names) |name| {
        const user_path = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "themes", name, "colors.toml" });
        if (pathExists(user_path)) return user_path;
        allocator.free(user_path);
        const stock_path = try std.fs.path.join(allocator, &.{ home, ".local", "share", "omarchy", "themes", name, "colors.toml" });
        if (pathExists(stock_path)) return stock_path;
        allocator.free(stock_path);
    }
    return null;
}

fn currentOmarchyThemeFilePath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, file_name: []const u8) !?[]u8 {
    const home = env_map.get("HOME") orelse return error.EnvironmentVariableNotFound;
    const config_home = try configHome(allocator, env_map);
    defer allocator.free(config_home);
    return currentOmarchyThemeFilePathAt(allocator, home, config_home, file_name);
}

fn currentOmarchyThemeFilePathAt(allocator: std.mem.Allocator, home: []const u8, config_home: []const u8, file_name: []const u8) !?[]u8 {
    const state_path = try std.fs.path.join(allocator, &.{ home, ".local", "state", "omarchy", "current", "theme", file_name });
    if (pathExists(state_path)) return state_path;
    allocator.free(state_path);

    // Omarchy before Quattro kept the assembled active theme under config.
    const legacy_path = try std.fs.path.join(allocator, &.{ config_home, "omarchy", "current", "theme", file_name });
    if (pathExists(legacy_path)) return legacy_path;
    allocator.free(legacy_path);
    return null;
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

/// Applies an Omarchy colors.toml onto `target`: top-level palette keys map
/// onto Verde roles, and a `[verde]` section supplies exact roles that win.
fn applyOmarchyToml(raw: []const u8, target: *Colors) void {
    var parsed: OmarchyPalette = .{};
    var roles: ColorOverrides = .{};
    var section: TomlSection = .top_level;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| parseOmarchyLine(line, &section, &parsed, &roles);
    // Light Omarchy themes start from Verde Light so omitted roles stay legible.
    if (parsed.light_mode) target.* = verde_light_colors;
    applyOmarchyPalette(parsed, target);
    applyRoleOverrides(roles, target);
}

fn parseOmarchyLine(line: []const u8, section: *TomlSection, parsed: *OmarchyPalette, roles: *ColorOverrides) void {
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

    const color = parseHex(value) orelse return;
    switch (section.*) {
        .verde => {
            inline for (std.meta.fields(ColorOverrides)) |field| {
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

/// Contents of a quoted TOML string, or a bare value minus trailing comment.
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

fn applyOmarchyPalette(parsed: OmarchyPalette, target: *Colors) void {
    if (parsed.background) |value| {
        target.background = value;
        target.panel = value;
        const text = parsed.foreground orelse target.text;
        target.panel_alt = raiseAgainst(value, 0.035, value, text);
        target.panel_muted = raiseAgainst(value, 0.12, value, text);
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

fn applyRoleOverrides(roles: ColorOverrides, target: *Colors) void {
    inline for (std.meta.fields(ColorOverrides)) |field| {
        if (@field(roles, field.name)) |value| @field(target, field.name) = value;
    }
}

fn applyJsonOverrides(overrides: *ColorOverrides, value: std.json.Value) void {
    if (value != .object) return;
    inline for (std.meta.fields(ColorOverrides)) |field| {
        if (value.object.get(field.name)) |entry| {
            if (jsonColor(entry)) |parsed| @field(overrides, field.name) = parsed;
        }
    }
}

/// Hex string or RGB/RGBA 0..255 number array, as desktop config accepts.
fn jsonColor(value: std.json.Value) ?[4]f32 {
    switch (value) {
        .string => |raw| {
            var text = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text = text[1 .. text.len - 1];
            return parseHex(text);
        },
        .array => |array| {
            if (array.items.len != 3 and array.items.len != 4) return null;
            var out: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
            for (array.items, 0..) |item, index| {
                const number: f32 = switch (item) {
                    .integer => |integer| @floatFromInt(integer),
                    .float => |float| @floatCast(float),
                    else => return null,
                };
                if (!std.math.isFinite(number) or number < 0.0 or number > 255.0) return null;
                out[index] = number / 255.0;
            }
            return out;
        },
        else => return null,
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

fn relativeLuma(color: [4]f32) f32 {
    return color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
}

fn darken(color: [4]f32, amount: f32) [4]f32 {
    return .{ clampf(color[0] - amount), clampf(color[1] - amount), clampf(color[2] - amount), color[3] };
}

fn raiseAgainst(color: [4]f32, amount: f32, backing: [4]f32, foreground: [4]f32) [4]f32 {
    return if (relativeLuma(backing) > relativeLuma(foreground)) darken(color, amount) else lighten(color, amount);
}

/// Desktop `withHue`: replace hue, keep HSL saturation and lightness.
fn withHue(color: [4]f32, hue_degrees: f32) [4]f32 {
    const max_c = @max(color[0], @max(color[1], color[2]));
    const min_c = @min(color[0], @min(color[1], color[2]));
    const lightness = (max_c + min_c) * 0.5;
    const delta = max_c - min_c;
    const saturation = if (delta <= 0.0001) 0.0 else delta / (1.0 - @abs(2.0 * lightness - 1.0));
    const chroma = (1.0 - @abs(2.0 * lightness - 1.0)) * saturation;
    const h = @mod(hue_degrees, 360.0) / 60.0;
    const x = chroma * (1.0 - @abs(@mod(h, 2.0) - 1.0));
    const rgb_prime: [3]f32 = if (h < 1.0) .{ chroma, x, 0.0 } else if (h < 2.0) .{ x, chroma, 0.0 } else if (h < 3.0) .{ 0.0, chroma, x } else if (h < 4.0) .{ 0.0, x, chroma } else if (h < 5.0) .{ x, 0.0, chroma } else .{ chroma, 0.0, x };
    const m = lightness - chroma * 0.5;
    return .{ clampf(rgb_prime[0] + m), clampf(rgb_prime[1] + m), clampf(rgb_prime[2] + m), color[3] };
}

/// Desktop `defaultTerminalPalette` (terminal.zig): blue/magenta/cyan borrow
/// the accent's contrast via hue rotation; brights `raise` toward the text pole.
fn terminalFromColors(colors: Colors) TerminalTheme {
    const raise = struct {
        fn f(c: Colors, color: [4]f32, amount: f32) [4]f32 {
            return raiseAgainst(color, amount, c.background, c.text);
        }
    }.f;
    const blue = withHue(colors.accent, 212.0);
    const magenta = withHue(colors.accent, 300.0);
    const cyan = withHue(colors.accent, 186.0);
    return .{
        .background = colors.background,
        .foreground = colors.text,
        .cursor = colors.text_muted,
        .palette = .{
            colors.text_subtle,
            colors.diff_remove,
            colors.accent,
            colors.warning,
            blue,
            magenta,
            cyan,
            colors.text,
            colors.text_muted,
            raise(colors, colors.diff_remove, 0.12),
            raise(colors, colors.accent, 0.12),
            raise(colors, colors.warning, 0.12),
            raise(colors, blue, 0.12),
            raise(colors, magenta, 0.12),
            raise(colors, cyan, 0.12),
            raise(colors, colors.text, 0.04),
        },
    };
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
    , &parsed);
    try std.testing.expectEqual(rgb(0x1a, 0x1b, 0x26), parsed.background);
    try std.testing.expectEqual(rgb(0x7a, 0xa2, 0xf7), parsed.accent);
    try std.testing.expectEqual(rgb(0xe0, 0xaf, 0x68), parsed.warning);
}

test "omarchy [verde] roles win and other sections are ignored" {
    var parsed: Colors = .{};
    applyOmarchyToml(
        \\mode = "dark"
        \\background = "#0B0F0E"
        \\yellow = "#E8C15A"
        \\selection = "#111111"
        \\[web]
        \\panel = "#ff0000"
        \\[verde]
        \\panel = "#121917"
        \\warning = "#F0B450"
        \\selection = "#245A40"
        \\
    , &parsed);
    try std.testing.expectEqual(hexColor("#121917"), parsed.panel);
    try std.testing.expectEqual(hexColor("#F0B450"), parsed.warning);
    try std.testing.expectEqual(hexColor("#245A40"), parsed.selection);
}

test "light omarchy themes start from Verde Light" {
    var parsed: Colors = .{};
    applyOmarchyToml("mode = \"light\"\n", &parsed);
    try std.testing.expectEqual(verde_light_colors.panel, parsed.panel);
}

test "theme source aliases match desktop" {
    try std.testing.expectEqual(Source.verde_legacy, Source.parse("default").?);
    try std.testing.expectEqual(Source.verde_dark, Source.parse("Verde_Dark").?);
    try std.testing.expectEqual(Source.omarchy, Source.parse("omarchy").?);
    try std.testing.expect(Source.parse("bogus") == null);
}

fn hexColor(comptime value: []const u8) [4]f32 {
    @setEvalBranchQuota(10_000);
    return comptime parseHex(value) orelse @compileError("invalid theme color " ++ value);
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

    const resolved = (try currentOmarchyThemeFilePathAt(std.testing.allocator, home_path, config_home, "colors.toml")).?;
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(state_path, resolved);
}

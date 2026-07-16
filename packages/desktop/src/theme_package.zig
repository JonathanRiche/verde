//! Portable JSON theme packages used by the CLI import/export workflow.

const std = @import("std");

const app_config = @import("config.zig");
const theme = @import("ui/theme.zig");

pub const SCHEMA_VERSION: u32 = 1;
pub const MAX_THEME_BYTES: usize = 256 * 1024;
const FETCH_TIMEOUT_SECONDS: u64 = 15;

pub const Package = struct {
    name: ?[]u8 = null,
    theme_config: theme.ThemeConfig = .{ .source = .default },
    font_size: ?f32 = null,
    terminal_font_size: ?f32 = null,
    ignored_font_settings: bool = false,

    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.* = undefined;
    }

    pub fn apply(self: Package, config: *app_config.AppConfig) void {
        config.theme_config = self.theme_config;
        if (self.font_size) |value| config.font_size = value;
        if (self.terminal_font_size) |value| config.terminal_font_size = value;
    }
};

/// Parses the versioned package format, a `verde.json` theme section, or a
/// bare theme object. Only allowlisted visual settings are ever applied.
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Package {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ThemeRootMustBeObject;

    const root = parsed.value.object;
    try validateSchemaVersion(root);

    var result: Package = .{};
    errdefer result.deinit(allocator);
    if (root.get("name")) |name_value| {
        if (name_value != .string or name_value.string.len == 0 or name_value.string.len > 128) {
            return error.InvalidThemeName;
        }
        result.name = try allocator.dupe(u8, name_value.string);
    }

    const theme_object = try selectThemeObject(root);
    result.theme_config.source = try parseThemeSource(theme_object);
    result.theme_config.colors = try parseThemeColors(theme_object);
    result.font_size = try parseOptionalFontSize(root, "ui", app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE);
    result.terminal_font_size = try parseOptionalFontSize(
        root,
        "terminal",
        app_config.MIN_TERMINAL_FONT_SIZE,
        app_config.MAX_TERMINAL_FONT_SIZE,
    );
    result.ignored_font_settings = hasUnsupportedFontSetting(root, "ui") or
        hasUnsupportedFontSetting(root, "terminal");
    return result;
}

fn validateSchemaVersion(root: std.json.ObjectMap) !void {
    const value = root.get("schema_version") orelse root.get("version") orelse return;
    if (value != .integer or value.integer != SCHEMA_VERSION) return error.UnsupportedThemeVersion;
}

fn selectThemeObject(root: std.json.ObjectMap) !std.json.ObjectMap {
    if (root.get("theme")) |theme_value| {
        if (theme_value == .object) return theme_value.object;
        if (theme_value == .string) return root;
        return error.InvalidThemeSection;
    }
    if (root.get("source") != null or root.get("colors") != null) return root;
    return error.MissingThemeSection;
}

fn parseThemeSource(object: std.json.ObjectMap) !theme.ThemeSource {
    const value = object.get("source") orelse object.get("theme") orelse return .default;
    if (value != .string) return error.InvalidThemeSource;
    const source = std.mem.trim(u8, value.string, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(source, "default") or std.ascii.eqlIgnoreCase(source, "verde")) return .default;
    if (std.ascii.eqlIgnoreCase(source, "omarchy") or std.ascii.eqlIgnoreCase(source, "auto")) return .omarchy;
    return error.UnsupportedThemeSource;
}

fn parseThemeColors(object: std.json.ObjectMap) !theme.ThemeColorOverrides {
    const value = object.get("colors") orelse return .{};
    if (value != .object) return error.InvalidThemeColors;

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (!isKnownColor(entry.key_ptr.*)) return error.UnknownThemeColor;
    }

    var colors: theme.ThemeColorOverrides = .{};
    inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
        if (value.object.get(field.name)) |color_value| {
            @field(colors, field.name) = parseColor(color_value) orelse return error.InvalidThemeColor;
        }
    }
    return colors;
}

fn isKnownColor(name: []const u8) bool {
    inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
        if (std.mem.eql(u8, name, field.name)) return true;
    }
    return false;
}

fn parseColor(value: std.json.Value) ?[4]f32 {
    return switch (value) {
        .string => |raw| parseHexColor(raw),
        .array => |array| parseArrayColor(array),
        else => null,
    };
}

fn parseHexColor(raw: []const u8) ?[4]f32 {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if ((value.len != 7 and value.len != 9) or value[0] != '#') return null;
    const alpha: u8 = if (value.len == 9)
        std.fmt.parseInt(u8, value[7..9], 16) catch return null
    else
        255;
    return .{
        channelFromByte(std.fmt.parseInt(u8, value[1..3], 16) catch return null),
        channelFromByte(std.fmt.parseInt(u8, value[3..5], 16) catch return null),
        channelFromByte(std.fmt.parseInt(u8, value[5..7], 16) catch return null),
        channelFromByte(alpha),
    };
}

fn parseArrayColor(array: std.json.Array) ?[4]f32 {
    if (array.items.len != 3 and array.items.len != 4) return null;
    var result = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    for (array.items, 0..) |item, index| {
        const number: f32 = switch (item) {
            .integer => |value| @floatFromInt(value),
            .float => |value| @floatCast(value),
            else => return null,
        };
        if (!std.math.isFinite(number)) return null;
        result[index] = if (number >= 0.0 and number <= 1.0)
            number
        else if (number >= 0.0 and number <= 255.0)
            number / 255.0
        else
            return null;
    }
    return result;
}

fn channelFromByte(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

fn parseOptionalFontSize(
    root: std.json.ObjectMap,
    section_name: []const u8,
    min: f32,
    max: f32,
) !?f32 {
    const section = root.get(section_name) orelse return null;
    if (section != .object) return error.InvalidThemeFontSection;
    const value = section.object.get("font_size") orelse return null;
    const number: f32 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| @floatCast(float),
        else => return error.InvalidThemeFontSize,
    };
    if (!std.math.isFinite(number) or number < min or number > max) return error.InvalidThemeFontSize;
    return number;
}

fn hasUnsupportedFontSetting(root: std.json.ObjectMap, section_name: []const u8) bool {
    const section = root.get(section_name) orelse return false;
    if (section != .object) return false;
    return section.object.get("font") != null or section.object.get("font_family") != null;
}

/// Exports resolved colors instead of source-dependent overrides, which makes
/// an Omarchy-derived theme portable to macOS, Windows, and other Linux setups.
pub fn exportAlloc(
    allocator: std.mem.Allocator,
    config: app_config.AppConfig,
    name: []const u8,
) ![]u8 {
    theme.applyConfigTheme(allocator, config.theme_config);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(SCHEMA_VERSION);
    try json.objectField("name");
    try json.write(name);
    try json.objectField("theme");
    try json.beginObject();
    try json.objectField("source");
    try json.write("default");
    try json.objectField("colors");
    try json.beginObject();
    inline for (std.meta.fields(theme.ThemeColors)) |field| {
        try json.objectField(field.name);
        try writeColor(&json, @field(theme.current_colors, field.name));
    }
    try json.endObject();
    try json.endObject();
    try json.objectField("ui");
    try json.beginObject();
    try json.objectField("font_size");
    try json.write(config.font_size);
    try json.endObject();
    try json.objectField("terminal");
    try json.beginObject();
    try json.objectField("font_size");
    try json.write(config.terminal_font_size);
    try json.endObject();
    try json.endObject();
    try writer.writer.writeByte('\n');
    return writer.toOwnedSlice();
}

fn writeColor(json: *std.json.Stringify, color: [4]f32) !void {
    try json.beginArray();
    for (color) |channel| {
        const value: u8 = @intFromFloat(@round(theme.clampf(channel, 0.0, 1.0) * 255.0));
        try json.write(value);
    }
    try json.endArray();
}

pub fn readSourceAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (isHttpUrl(source)) return fetchUrlAlloc(allocator, source);

    var threaded = std.Io.Threaded.init_single_threaded;
    return std.Io.Dir.cwd().readFileAlloc(
        threaded.io(),
        source,
        allocator,
        .limited(MAX_THEME_BYTES),
    );
}

fn isHttpUrl(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://");
}

fn fetchUrlAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const url = try normalizeGithubUrlAlloc(allocator, source);
    defer allocator.free(url);

    const response_buffer = try allocator.alloc(u8, MAX_THEME_BYTES);
    defer allocator.free(response_buffer);
    var response_writer = std.Io.Writer.fixed(response_buffer);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    const fetch_options: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .response_writer = &response_writer,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json, text/plain;q=0.9" },
            .{ .name = "user-agent", .value = "verde-theme-importer" },
        },
    };
    const SelectResult = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: std.Io.Cancelable!void,
    };
    var select_buffer: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(threaded.io(), &select_buffer);
    select.async(.fetch, std.http.Client.fetch, .{ &client, fetch_options });
    select.async(.timeout, std.Io.sleep, .{
        threaded.io(),
        std.Io.Duration.fromSeconds(FETCH_TIMEOUT_SECONDS),
        .awake,
    });
    defer select.cancelDiscard();

    const selected = try select.await();
    const fetch_result = switch (selected) {
        .fetch => |result| result catch |err| switch (err) {
            error.WriteFailed => if (response_writer.end == response_buffer.len)
                return error.ThemeFileTooLarge
            else
                return err,
            else => return err,
        },
        .timeout => |result| {
            try result;
            return error.ThemeFetchTimedOut;
        },
    };
    if (fetch_result.status != .ok) return error.ThemeFetchFailed;
    return allocator.dupe(u8, response_writer.buffered());
}

/// Standard GitHub `blob` links serve HTML. Convert them to the equivalent raw
/// URL so users can paste the link copied from the GitHub file page directly.
pub fn normalizeGithubUrlAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, source, prefix)) return allocator.dupe(u8, source);

    const path = source[prefix.len..];
    var parts = std.mem.splitScalar(u8, path, '/');
    const owner = parts.next() orelse return allocator.dupe(u8, source);
    const repository = parts.next() orelse return allocator.dupe(u8, source);
    const kind = parts.next() orelse return allocator.dupe(u8, source);
    const ref = parts.next() orelse return allocator.dupe(u8, source);
    if (!std.mem.eql(u8, kind, "blob") and !std.mem.eql(u8, kind, "raw")) {
        return allocator.dupe(u8, source);
    }
    const file_path = parts.rest();
    if (owner.len == 0 or repository.len == 0 or ref.len == 0 or file_path.len == 0) {
        return allocator.dupe(u8, source);
    }
    return std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}",
        .{ owner, repository, ref, file_path },
    );
}

test "parse canonical portable theme package" {
    const raw =
        \\{
        \\  "schema_version": 1,
        \\  "name": "Forest",
        \\  "theme": {
        \\    "source": "default",
        \\    "colors": {
        \\      "background": "#101820",
        \\      "accent_dim": "#50c87830"
        \\    }
        \\  },
        \\  "ui": { "font_size": 22 },
        \\  "terminal": { "font_size": 19, "font_family": "Unavailable Mono" }
        \\}
    ;
    var package = try parse(std.testing.allocator, raw);
    defer package.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Forest", package.name.?);
    try std.testing.expectEqual(theme.ThemeSource.default, package.theme_config.source);
    try std.testing.expectApproxEqAbs(@as(f32, 0x10) / 255.0, package.theme_config.colors.background.?[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0x30) / 255.0, package.theme_config.colors.accent_dim.?[3], 0.0001);
    try std.testing.expectEqual(@as(?f32, 22.0), package.font_size);
    try std.testing.expectEqual(@as(?f32, 19.0), package.terminal_font_size);
    try std.testing.expect(package.ignored_font_settings);
}

test "parse existing Verde config theme section and bare theme" {
    var config_package = try parse(std.testing.allocator,
        \\{"theme":{"theme":"omarchy","colors":{"accent":[80,200,120]}}}
    );
    defer config_package.deinit(std.testing.allocator);
    try std.testing.expectEqual(theme.ThemeSource.omarchy, config_package.theme_config.source);

    var bare_package = try parse(std.testing.allocator,
        \\{"theme":"default","colors":{"text":"#f0f0f0"}}
    );
    defer bare_package.deinit(std.testing.allocator);
    try std.testing.expectEqual(theme.ThemeSource.default, bare_package.theme_config.source);
}

test "theme validation rejects unknown colors and versions" {
    try std.testing.expectError(error.UnknownThemeColor, parse(std.testing.allocator,
        \\{"theme":{"colors":{"command":"rm -rf"}}}
    ));
    try std.testing.expectError(error.UnsupportedThemeVersion, parse(std.testing.allocator,
        \\{"schema_version":2,"theme":{"source":"default"}}
    ));
}

test "GitHub file page URLs normalize to raw content URLs" {
    const normalized = try normalizeGithubUrlAlloc(
        std.testing.allocator,
        "https://github.com/example/themes/blob/main/verde/forest.json",
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "https://raw.githubusercontent.com/example/themes/main/verde/forest.json",
        normalized,
    );
}

test "exported theme is versioned, portable, and parseable" {
    var config: app_config.AppConfig = .{};
    config.theme_config.source = .default;
    config.theme_config.colors.accent = .{ 0.25, 0.5, 0.75, 0.5 };
    const encoded = try exportAlloc(std.testing.allocator, config, "Portable");
    defer std.testing.allocator.free(encoded);

    var package = try parse(std.testing.allocator, encoded);
    defer package.deinit(std.testing.allocator);
    try std.testing.expectEqual(theme.ThemeSource.default, package.theme_config.source);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), package.theme_config.colors.accent.?[3], 0.01);
}

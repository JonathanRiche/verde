//! Shared user config loading for the native Verde shell.

const std = @import("std");
const platform_paths = @import("platform_paths");
const theme = @import("./ui/theme.zig");

const log = std.log.scoped(.native_config);
pub const MIN_FONT_SIZE: f32 = 10.0;
pub const MAX_FONT_SIZE: f32 = 32.0;
pub const DEFAULT_TERMINAL_FONT_SIZE: f32 = 18.0;
pub const MIN_TERMINAL_FONT_SIZE: f32 = 13.5;
pub const MAX_TERMINAL_FONT_SIZE: f32 = 60.0;

pub const CustomOpenAction = struct {
    label: []u8,
    action: []u8,

    pub fn clone(self: CustomOpenAction, allocator: std.mem.Allocator) !CustomOpenAction {
        return .{
            .label = try allocator.dupe(u8, self.label),
            .action = try allocator.dupe(u8, self.action),
        };
    }

    pub fn deinit(self: *CustomOpenAction, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.action);
    }
};

pub const DefaultOpenAction = union(enum) {
    folder,
    editor,
    cursor,
    vscode,
    zed,
    custom: CustomOpenAction,

    pub fn clone(self: DefaultOpenAction, allocator: std.mem.Allocator) !DefaultOpenAction {
        return switch (self) {
            .folder => .folder,
            .editor => .editor,
            .cursor => .cursor,
            .vscode => .vscode,
            .zed => .zed,
            .custom => |custom| .{ .custom = try custom.clone(allocator) },
        };
    }

    pub fn deinit(self: *DefaultOpenAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |*custom| custom.deinit(allocator),
            else => {},
        }
    }
};

pub const LinkOpenTarget = enum {
    verde_browser,
    system_browser,
};

pub const TerminalLaunchProfileConfig = struct {
    label: []u8,
    command: []const []u8,

    pub fn deinit(self: *TerminalLaunchProfileConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        for (self.command) |arg| allocator.free(arg);
        allocator.free(self.command);
    }
};

pub const InstalledTheme = struct {
    name: []u8,
    theme_config: theme.ThemeConfig,
    font_size: ?f32 = null,
    terminal_font_size: ?f32 = null,

    pub fn deinit(self: *InstalledTheme, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }

    pub fn apply(self: InstalledTheme, config: *AppConfig) void {
        config.theme_config = self.theme_config;
        if (self.font_size) |value| config.font_size = value;
        if (self.terminal_font_size) |value| config.terminal_font_size = value;
    }
};

pub const AppConfig = struct {
    font_size: f32 = theme.DEFAULT_FONT_SIZE,
    terminal_font_size: f32 = DEFAULT_TERMINAL_FONT_SIZE,
    theme_config: theme.ThemeConfig = .{},
    active_theme: ?[]u8 = null,
    installed_themes: []InstalledTheme = &.{},
    default_open_action: DefaultOpenAction = .folder,
    link_open_target: LinkOpenTarget = .verde_browser,
    terminal_launch_profiles: []TerminalLaunchProfileConfig = &.{},
    check_for_updates_automatically: bool = true,
    // Fire a desktop notification when an agent surface finishes (transitions
    // to `.done`). Defaults on so the feature works without first opening
    // Settings; users can disable it from the Settings cog / verde.json.
    notifications_enabled: bool = true,

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        if (self.active_theme) |name| allocator.free(name);
        for (self.installed_themes) |*installed| installed.deinit(allocator);
        allocator.free(self.installed_themes);
        self.default_open_action.deinit(allocator);
        for (self.terminal_launch_profiles) |*profile| profile.deinit(allocator);
        allocator.free(self.terminal_launch_profiles);
    }

    pub fn activeThemeIndex(self: AppConfig) ?usize {
        const active_name = self.active_theme orelse return null;
        for (self.installed_themes, 0..) |installed, index| {
            if (std.ascii.eqlIgnoreCase(active_name, installed.name)) return index;
        }
        return null;
    }

    pub fn themeChoiceIndex(self: AppConfig) usize {
        if (self.activeThemeIndex()) |index| return index + 2;
        return if (self.theme_config.source == .omarchy) 1 else 0;
    }

    pub fn installTheme(
        self: *AppConfig,
        allocator: std.mem.Allocator,
        name: []const u8,
        theme_config: theme.ThemeConfig,
        font_size: ?f32,
        terminal_font_size: ?f32,
    ) !usize {
        for (self.installed_themes, 0..) |*installed, index| {
            if (!std.ascii.eqlIgnoreCase(name, installed.name)) continue;
            const owned_name = try allocator.dupe(u8, name);
            installed.deinit(allocator);
            installed.* = .{
                .name = owned_name,
                .theme_config = theme_config,
                .font_size = font_size,
                .terminal_font_size = terminal_font_size,
            };
            return index;
        }

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const next = try allocator.alloc(InstalledTheme, self.installed_themes.len + 1);
        @memcpy(next[0..self.installed_themes.len], self.installed_themes);
        next[self.installed_themes.len] = .{
            .name = owned_name,
            .theme_config = theme_config,
            .font_size = font_size,
            .terminal_font_size = terminal_font_size,
        };
        const index = self.installed_themes.len;
        allocator.free(self.installed_themes);
        self.installed_themes = next;
        return index;
    }

    pub fn selectThemeChoice(self: *AppConfig, allocator: std.mem.Allocator, choice_index: usize) !void {
        if (choice_index >= self.installed_themes.len + 2) return error.InvalidThemeChoice;
        if (self.active_theme) |name| allocator.free(name);
        self.active_theme = null;

        if (choice_index == 0) {
            self.theme_config = .{ .source = .default };
            return;
        }
        if (choice_index == 1) {
            self.theme_config = .{ .source = .omarchy };
            return;
        }

        const installed = self.installed_themes[choice_index - 2];
        const active_name = try allocator.dupe(u8, installed.name);
        installed.apply(self);
        self.active_theme = active_name;
    }
};

pub fn loadAppConfig(allocator: std.mem.Allocator) !AppConfig {
    var config: AppConfig = .{};

    const parsed = readRootValue(allocator) catch |err| switch (err) {
        error.FileNotFound => return config,
        else => return err,
    };
    if (parsed == null) return config;

    var root = parsed.?;
    defer root.deinit();
    applyAppOverrides(allocator, &config, root.value);
    return config;
}

pub fn readRootValue(allocator: std.mem.Allocator) !?std.json.Parsed(std.json.Value) {
    const config_path = try resolveConfigPath(allocator);
    defer allocator.free(config_path);

    const raw_bytes = readConfigFile(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw_bytes);

    return try std.json.parseFromSlice(std.json.Value, allocator, raw_bytes, .{
        .allocate = .alloc_always,
    });
}

pub fn configFileMtime(allocator: std.mem.Allocator) !i128 {
    const config_path = try resolveConfigPath(allocator);
    defer allocator.free(config_path);

    var threaded = std.Io.Threaded.init_single_threaded;

    const stat = blk: {
        var file = std.Io.Dir.cwd().openFile(threaded.io(), config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return -1,
            else => return err,
        };
        defer file.close(threaded.io());
        break :blk try file.stat(threaded.io());
    };
    return @intCast(stat.mtime.toNanoseconds());
}

pub fn saveAppConfig(allocator: std.mem.Allocator, config: *const AppConfig) !void {
    const config_path = try resolveConfigPath(allocator);
    defer allocator.free(config_path);

    var fallback_arena = std.heap.ArenaAllocator.init(allocator);
    defer fallback_arena.deinit();

    var parsed = try readRootValue(allocator);
    defer if (parsed) |*value| value.deinit();

    const tree_allocator = if (parsed) |*value| value.arena.allocator() else fallback_arena.allocator();
    var root: std.json.Value = if (parsed) |*value| value.value else .{ .object = .empty };

    if (root != .object) {
        root = .{ .object = .empty };
    }

    try writeUiSection(tree_allocator, &root.object, config);
    try writeThemeSection(tree_allocator, &root.object, config);
    try writeInstalledThemesSection(tree_allocator, &root.object, config);
    try writeOpenSection(tree_allocator, &root.object, config);
    try writeTerminalSection(tree_allocator, &root.object, config);
    try writeUpdatesSection(tree_allocator, &root.object, config);
    try writeNotificationsSection(tree_allocator, &root.object, config);

    const encoded = try std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    if (std.fs.path.dirname(config_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{config_path});
    defer allocator.free(tmp_path);

    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.rename(tmp_path, cwd, config_path, io);
}

fn objectSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    const entry = try object.getOrPut(allocator, key);
    if (!entry.found_existing or entry.value_ptr.* != .object) {
        entry.value_ptr.* = .{ .object = .empty };
    }
    return &entry.value_ptr.object;
}

fn writeUiSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const ui_object = try objectSection(allocator, object, "ui");
    try ui_object.put(allocator, "font_size", .{ .float = config.font_size });
}

fn writeThemeSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const theme_object = try objectSection(allocator, object, "theme");

    const source_name = switch (config.theme_config.source) {
        .omarchy => "omarchy",
        .default => "default",
    };
    try theme_object.put(allocator, "theme", .{ .string = source_name });
    if (config.active_theme) |active_name| {
        try theme_object.put(allocator, "active", .{ .string = active_name });
    } else {
        _ = theme_object.orderedRemove("active");
    }

    var has_color_override = false;
    inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
        if (@field(config.theme_config.colors, field.name) != null) has_color_override = true;
    }

    if (has_color_override) {
        var colors_object: std.json.ObjectMap = .empty;
        inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
            if (@field(config.theme_config.colors, field.name)) |value| {
                const hex = try colorToHex(allocator, value);
                try colors_object.put(allocator, field.name, .{ .string = hex });
            }
        }
        try theme_object.put(allocator, "colors", .{ .object = colors_object });
    } else {
        // Import/reset replaces the complete theme. Remove persisted overrides
        // so stale colors cannot survive a package that intentionally has none.
        _ = theme_object.orderedRemove("colors");
    }
}

fn writeInstalledThemesSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    var installed_values = std.json.Array.init(allocator);
    for (config.installed_themes) |installed| {
        var installed_object: std.json.ObjectMap = .empty;
        try installed_object.put(allocator, "name", .{ .string = installed.name });

        var package_theme: std.json.ObjectMap = .empty;
        const source_name = if (installed.theme_config.source == .omarchy) "omarchy" else "default";
        try package_theme.put(allocator, "theme", .{ .string = source_name });
        var colors_object: std.json.ObjectMap = .empty;
        var has_colors = false;
        inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
            if (@field(installed.theme_config.colors, field.name)) |value| {
                const hex = try colorToHex(allocator, value);
                try colors_object.put(allocator, field.name, .{ .string = hex });
                has_colors = true;
            }
        }
        if (has_colors) try package_theme.put(allocator, "colors", .{ .object = colors_object });
        try installed_object.put(allocator, "theme", .{ .object = package_theme });
        if (installed.font_size) |value| try installed_object.put(allocator, "ui_font_size", .{ .float = value });
        if (installed.terminal_font_size) |value| try installed_object.put(allocator, "terminal_font_size", .{ .float = value });
        try installed_values.append(.{ .object = installed_object });
    }
    try object.put(allocator, "installed_themes", .{ .array = installed_values });
}

fn writeOpenSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const open_object = try objectSection(allocator, object, "open");

    const default_value: std.json.Value = switch (config.default_open_action) {
        .folder => .{ .string = "folder" },
        .editor => .{ .string = "editor" },
        .cursor => .{ .string = "cursor" },
        .vscode => .{ .string = "vscode" },
        .zed => .{ .string = "zed" },
        .custom => |custom| blk: {
            var custom_object: std.json.ObjectMap = .empty;
            try custom_object.put(allocator, "label", .{ .string = custom.label });
            try custom_object.put(allocator, "action", .{ .string = custom.action });
            break :blk .{ .object = custom_object };
        },
    };

    try open_object.put(allocator, "default", default_value);
    const links_value: std.json.Value = .{ .string = switch (config.link_open_target) {
        .verde_browser => "verde_browser",
        .system_browser => "system_browser",
    } };
    try open_object.put(allocator, "links", links_value);
}

fn writeTerminalSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const terminal_object = try objectSection(allocator, object, "terminal");

    try terminal_object.put(allocator, "font_size", .{ .float = config.terminal_font_size });

    var profiles = std.json.Array.init(allocator);
    for (config.terminal_launch_profiles) |profile| {
        var command = std.json.Array.init(allocator);
        for (profile.command) |arg| {
            try command.append(.{ .string = arg });
        }
        var profile_object: std.json.ObjectMap = .empty;
        try profile_object.put(allocator, "label", .{ .string = profile.label });
        try profile_object.put(allocator, "command", .{ .array = command });
        try profiles.append(.{ .object = profile_object });
    }

    try terminal_object.put(allocator, "profiles", .{ .array = profiles });
}

fn writeUpdatesSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const updates_object = try objectSection(allocator, object, "updates");
    try updates_object.put(allocator, "check_automatically", .{ .bool = config.check_for_updates_automatically });
}

fn writeNotificationsSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const notifications_object = try objectSection(allocator, object, "notifications");
    try notifications_object.put(allocator, "enabled", .{ .bool = config.notifications_enabled });
}

fn colorToHex(allocator: std.mem.Allocator, color: [4]f32) ![]u8 {
    const r: u8 = @intFromFloat(@round(theme.clampf(color[0], 0.0, 1.0) * 255.0));
    const g: u8 = @intFromFloat(@round(theme.clampf(color[1], 0.0, 1.0) * 255.0));
    const b: u8 = @intFromFloat(@round(theme.clampf(color[2], 0.0, 1.0) * 255.0));
    const a: u8 = @intFromFloat(@round(theme.clampf(color[3], 0.0, 1.0) * 255.0));
    if (a == 255) return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
    return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a });
}

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]u8 {
    return platform_paths.configPath(allocator);
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;

    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(1024 * 128)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
}

fn applyAppOverrides(allocator: std.mem.Allocator, config: *AppConfig, root: std.json.Value) void {
    if (root != .object) {
        log.warn("verde config must be a JSON object when present", .{});
        return;
    }

    if (root.object.get("ui")) |ui_value| {
        applyUiOverrides(config, ui_value);
    }
    if (root.object.get("theme")) |theme_value| {
        applyThemeOverrides(allocator, config, theme_value);
    }
    if (root.object.get("open")) |open_value| {
        applyOpenOverrides(allocator, config, open_value);
    }
    if (root.object.get("terminal")) |terminal_value| {
        applyTerminalOverrides(allocator, config, terminal_value);
    }
    if (root.object.get("installed_themes")) |installed_value| {
        applyInstalledThemeOverrides(allocator, config, installed_value);
    }
    validateActiveTheme(allocator, config);
    if (root.object.get("updates")) |updates_value| {
        applyUpdatesOverrides(config, updates_value);
    }
    if (root.object.get("notifications")) |notifications_value| {
        applyNotificationsOverrides(config, notifications_value);
    }
}

fn applyUpdatesOverrides(config: *AppConfig, updates_value: std.json.Value) void {
    if (updates_value != .object) {
        log.warn("updates must be an object when provided", .{});
        return;
    }
    if (updates_value.object.get("check_automatically")) |enabled_value| {
        if (enabled_value == .bool) {
            config.check_for_updates_automatically = enabled_value.bool;
        } else {
            log.warn("updates.check_automatically must be a boolean when provided", .{});
        }
    }
}

fn applyNotificationsOverrides(config: *AppConfig, notifications_value: std.json.Value) void {
    if (notifications_value != .object) {
        log.warn("notifications must be an object when provided", .{});
        return;
    }
    if (notifications_value.object.get("enabled")) |enabled_value| {
        if (enabled_value == .bool) {
            config.notifications_enabled = enabled_value.bool;
        } else {
            log.warn("notifications.enabled must be a boolean when provided", .{});
        }
    }
}

fn applyThemeOverrides(allocator: std.mem.Allocator, config: *AppConfig, theme_value: std.json.Value) void {
    if (theme_value != .object) {
        log.warn("theme must be an object when provided", .{});
        return;
    }

    if (theme_value.object.get("active")) |active_value| {
        if (active_value != .string) {
            log.warn("theme.active must be a string when provided", .{});
        } else {
            const active_name = std.mem.trim(u8, active_value.string, &std.ascii.whitespace);
            if (active_name.len > 0) {
                config.active_theme = allocator.dupe(u8, active_name) catch null;
            }
        }
    }

    applyThemeConfigOverrides(&config.theme_config, theme_value);
}

fn applyThemeConfigOverrides(theme_config: *theme.ThemeConfig, theme_value: std.json.Value) void {
    if (theme_value.object.get("theme")) |source_value| {
        if (source_value != .string) {
            log.warn("theme.theme must be a string when provided", .{});
        } else if (parseThemeSource(source_value.string)) |source| {
            theme_config.source = source;
        }
    }

    const colors_value = theme_value.object.get("colors") orelse return;
    if (colors_value != .object) {
        log.warn("theme.colors must be an object when provided", .{});
        return;
    }
    applyThemeColorOverrides(theme_config, colors_value.object);
}

fn parseThemeSource(raw: []const u8) ?theme.ThemeSource {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(value, "omarchy") or std.ascii.eqlIgnoreCase(value, "auto")) return .omarchy;
    if (std.ascii.eqlIgnoreCase(value, "default") or std.ascii.eqlIgnoreCase(value, "verde")) return .default;
    log.warn("ignoring unsupported theme.theme value_len={d}", .{value.len});
    return null;
}

fn applyThemeColorOverrides(theme_config: *theme.ThemeConfig, object: std.json.ObjectMap) void {
    inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
        if (object.get(field.name)) |value| {
            if (parseConfigColor(value)) |parsed| {
                @field(theme_config.colors, field.name) = parsed;
            } else {
                log.warn("theme.colors.{s} must be a hex string or RGB/RGBA number array", .{field.name});
            }
        }
    }
}

fn applyInstalledThemeOverrides(allocator: std.mem.Allocator, config: *AppConfig, value: std.json.Value) void {
    if (value != .array) {
        log.warn("installed_themes must be an array when provided", .{});
        return;
    }
    for (value.array.items) |item| {
        if (item != .object) {
            log.warn("installed theme entries must be objects", .{});
            continue;
        }
        const name_value = item.object.get("name") orelse continue;
        const theme_value = item.object.get("theme") orelse continue;
        if (name_value != .string or theme_value != .object) {
            log.warn("installed theme name/theme fields are invalid", .{});
            continue;
        }
        const name = std.mem.trim(u8, name_value.string, &std.ascii.whitespace);
        if (name.len == 0 or name.len > 128) {
            log.warn("installed theme name is empty or too long", .{});
            continue;
        }

        var theme_config: theme.ThemeConfig = .{ .source = .default };
        applyThemeConfigOverrides(&theme_config, theme_value);
        const font_size = parseInstalledFontSize(item.object.get("ui_font_size"), MIN_FONT_SIZE, MAX_FONT_SIZE);
        const terminal_font_size = parseInstalledFontSize(item.object.get("terminal_font_size"), MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE);
        _ = config.installTheme(allocator, name, theme_config, font_size, terminal_font_size) catch |err| {
            log.warn("failed to load installed theme: {s}", .{@errorName(err)});
            continue;
        };
    }
}

fn parseInstalledFontSize(value: ?std.json.Value, min: f32, max: f32) ?f32 {
    const present = value orelse return null;
    const number: f32 = switch (present) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| @floatCast(float),
        else => return null,
    };
    if (!std.math.isFinite(number) or number < min or number > max) return null;
    return number;
}

fn validateActiveTheme(allocator: std.mem.Allocator, config: *AppConfig) void {
    if (config.active_theme == null or config.activeThemeIndex() != null) return;
    allocator.free(config.active_theme.?);
    config.active_theme = null;
}

fn parseConfigColor(value: std.json.Value) ?[4]f32 {
    return switch (value) {
        .string => |raw| parseHexConfigColor(raw),
        .array => |array| parseArrayConfigColor(array),
        else => null,
    };
}

fn parseHexConfigColor(raw: []const u8) ?[4]f32 {
    var value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if ((value.len != 7 and value.len != 9) or value[0] != '#') return null;
    const alpha: u8 = if (value.len == 9)
        std.fmt.parseInt(u8, value[7..9], 16) catch return null
    else
        255;
    return .{
        @as(f32, @floatFromInt(std.fmt.parseInt(u8, value[1..3], 16) catch return null)) / 255.0,
        @as(f32, @floatFromInt(std.fmt.parseInt(u8, value[3..5], 16) catch return null)) / 255.0,
        @as(f32, @floatFromInt(std.fmt.parseInt(u8, value[5..7], 16) catch return null)) / 255.0,
        @as(f32, @floatFromInt(alpha)) / 255.0,
    };
}

fn parseArrayConfigColor(array: std.json.Array) ?[4]f32 {
    if (array.items.len != 3 and array.items.len != 4) return null;
    var result = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    for (array.items, 0..) |item, index| {
        result[index] = switch (item) {
            .integer => |value| colorChannelFromNumber(@floatFromInt(value)),
            .float => |value| colorChannelFromNumber(@floatCast(value)),
            else => return null,
        } orelse return null;
    }
    return result;
}

fn colorChannelFromNumber(value: f32) ?f32 {
    if (!std.math.isFinite(value)) return null;
    if (value >= 0.0 and value <= 1.0) return value;
    if (value >= 0.0 and value <= 255.0) return value / 255.0;
    return null;
}

fn applyUiOverrides(config: *AppConfig, ui_value: std.json.Value) void {
    if (ui_value != .object) {
        log.warn("ui must be an object when provided", .{});
        return;
    }

    const font_size_value = ui_value.object.get("font_size") orelse return;
    switch (font_size_value) {
        .integer => |value| applyFontSize(config, @floatFromInt(value)),
        .float => |value| applyFontSize(config, @floatCast(value)),
        else => log.warn("ui.font_size must be a number when provided", .{}),
    }
}

fn applyOpenOverrides(allocator: std.mem.Allocator, config: *AppConfig, open_value: std.json.Value) void {
    if (open_value != .object) {
        log.warn("open must be an object when provided", .{});
        return;
    }

    if (open_value.object.get("default")) |default_value| {
        const parsed = parseDefaultOpenAction(allocator, default_value) orelse return;
        config.default_open_action.deinit(allocator);
        config.default_open_action = parsed;
    }

    if (open_value.object.get("links")) |links_value| {
        if (parseLinkOpenTarget(links_value)) |target| {
            config.link_open_target = target;
        }
    }
}

fn parseLinkOpenTarget(value: std.json.Value) ?LinkOpenTarget {
    if (value != .string) {
        log.warn("open.links must be a string when provided", .{});
        return null;
    }
    const trimmed = std.mem.trim(u8, value.string, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "verde_browser") or
        std.ascii.eqlIgnoreCase(trimmed, "verde") or
        std.ascii.eqlIgnoreCase(trimmed, "browser")) return .verde_browser;
    if (std.ascii.eqlIgnoreCase(trimmed, "system_browser") or
        std.ascii.eqlIgnoreCase(trimmed, "system") or
        std.ascii.eqlIgnoreCase(trimmed, "default_browser") or
        std.ascii.eqlIgnoreCase(trimmed, "default")) return .system_browser;

    log.warn("ignoring unsupported open.links value_len={d}", .{trimmed.len});
    return null;
}

fn parseDefaultOpenAction(allocator: std.mem.Allocator, value: std.json.Value) ?DefaultOpenAction {
    return switch (value) {
        .string => |name| parseNamedOpenAction(name),
        .object => parseCustomOpenAction(allocator, value.object),
        else => blk: {
            log.warn("open.default must be a string or object when provided", .{});
            break :blk null;
        },
    };
}

fn parseNamedOpenAction(name: []const u8) ?DefaultOpenAction {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        log.warn("open.default cannot be an empty string", .{});
        return null;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "folder") or std.ascii.eqlIgnoreCase(trimmed, "files")) return .folder;
    if (std.ascii.eqlIgnoreCase(trimmed, "editor") or std.ascii.eqlIgnoreCase(trimmed, "configured")) return .editor;
    if (std.ascii.eqlIgnoreCase(trimmed, "cursor")) return .cursor;
    if (std.ascii.eqlIgnoreCase(trimmed, "vscode") or std.ascii.eqlIgnoreCase(trimmed, "code")) return .vscode;
    if (std.ascii.eqlIgnoreCase(trimmed, "zed")) return .zed;

    log.warn("ignoring unsupported open.default value_len={d}", .{trimmed.len});
    return null;
}

fn parseCustomOpenAction(allocator: std.mem.Allocator, object: std.json.ObjectMap) ?DefaultOpenAction {
    const label_value = object.get("label") orelse {
        log.warn("open.default.label is required for custom actions", .{});
        return null;
    };
    const action_value = object.get("action") orelse {
        log.warn("open.default.action is required for custom actions", .{});
        return null;
    };
    if (label_value != .string or action_value != .string) {
        log.warn("open.default.label and open.default.action must be strings", .{});
        return null;
    }

    const label = std.mem.trim(u8, label_value.string, &std.ascii.whitespace);
    const action = std.mem.trim(u8, action_value.string, &std.ascii.whitespace);
    if (label.len == 0 or action.len == 0) {
        log.warn("open.default custom action requires non-empty label and action", .{});
        return null;
    }

    const owned_label = allocator.dupe(u8, label) catch return null;
    errdefer allocator.free(owned_label);
    const owned_action = allocator.dupe(u8, action) catch return null;

    return .{
        .custom = .{
            .label = owned_label,
            .action = owned_action,
        },
    };
}

fn applyTerminalOverrides(allocator: std.mem.Allocator, config: *AppConfig, terminal_value: std.json.Value) void {
    if (terminal_value != .object) {
        log.warn("terminal must be an object when provided", .{});
        return;
    }

    if (terminal_value.object.get("font_size")) |font_size_value| {
        switch (font_size_value) {
            .integer => |value| applyTerminalFontSize(config, @floatFromInt(value)),
            .float => |value| applyTerminalFontSize(config, @floatCast(value)),
            else => log.warn("terminal.font_size must be a number when provided", .{}),
        }
    }

    const profiles_value = terminal_value.object.get("profiles") orelse return;
    if (profiles_value != .array) {
        log.warn("terminal.profiles must be an array when provided", .{});
        return;
    }

    var profiles: std.ArrayList(TerminalLaunchProfileConfig) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(allocator);
        profiles.deinit(allocator);
    }
    for (profiles_value.array.items) |profile_value| {
        if (parseTerminalLaunchProfile(allocator, profile_value)) |profile| {
            profiles.append(allocator, profile) catch |err| {
                var owned = profile;
                owned.deinit(allocator);
                log.warn("failed to append terminal profile: {s}", .{@errorName(err)});
            };
        }
    }

    for (config.terminal_launch_profiles) |*profile| profile.deinit(allocator);
    allocator.free(config.terminal_launch_profiles);
    config.terminal_launch_profiles = profiles.toOwnedSlice(allocator) catch &.{};
}

fn applyTerminalFontSize(config: *AppConfig, value: f32) void {
    config.terminal_font_size = theme.clampf(value, MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE);
}

fn parseTerminalLaunchProfile(allocator: std.mem.Allocator, value: std.json.Value) ?TerminalLaunchProfileConfig {
    if (value != .object) {
        log.warn("terminal profile entries must be objects", .{});
        return null;
    }
    const label_value = value.object.get("label") orelse {
        log.warn("terminal profile label is required", .{});
        return null;
    };
    const command_value = value.object.get("command") orelse {
        log.warn("terminal profile command is required", .{});
        return null;
    };
    if (label_value != .string or command_value != .array) {
        log.warn("terminal profile label must be a string and command must be a string array", .{});
        return null;
    }
    const label = std.mem.trim(u8, label_value.string, &std.ascii.whitespace);
    if (label.len == 0 or command_value.array.items.len == 0) {
        log.warn("terminal profile requires non-empty label and command", .{});
        return null;
    }

    const owned_label = allocator.dupe(u8, label) catch return null;
    errdefer allocator.free(owned_label);
    var command = allocator.alloc([]u8, command_value.array.items.len) catch return null;
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    for (command_value.array.items, 0..) |arg_value, index| {
        if (arg_value != .string) {
            log.warn("terminal profile command entries must be strings", .{});
            return null;
        }
        const arg = std.mem.trim(u8, arg_value.string, &std.ascii.whitespace);
        if (arg.len == 0) {
            log.warn("terminal profile command entries cannot be empty", .{});
            return null;
        }
        command[index] = allocator.dupe(u8, arg) catch return null;
        initialized += 1;
    }

    return .{ .label = owned_label, .command = command };
}

fn applyFontSize(config: *AppConfig, value: f32) void {
    if (!std.math.isFinite(value)) {
        log.warn("ignoring non-finite ui.font_size override", .{});
        return;
    }
    if (value < MIN_FONT_SIZE or value > MAX_FONT_SIZE) {
        log.warn("ignoring ui.font_size outside supported range {d:.1}-{d:.1}", .{ MIN_FONT_SIZE, MAX_FONT_SIZE });
        return;
    }

    config.font_size = value;
}

test "app config accepts ui.font_size override" {
    var root = try parseTestRoot("{\"ui\":{\"font_size\":22}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(f32, 22.0), config.font_size);
}

test "app config ignores out-of-range ui.font_size" {
    var root = try parseTestRoot("{\"ui\":{\"font_size\":64}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(theme.DEFAULT_FONT_SIZE, config.font_size);
}

test "app config accepts theme source and color overrides" {
    var root = try parseTestRoot(
        \\{
        \\  "theme": {
        \\    "theme": "default",
        \\    "colors": {
        \\      "background": "#101820",
        \\      "accent": [80, 200, 120]
        \\    }
        \\  }
        \\}
    );
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(theme.ThemeSource.default, config.theme_config.source);
    try std.testing.expectEqual(@as(f32, 0x10) / 255.0, config.theme_config.colors.background.?[0]);
    try std.testing.expectEqual(@as(f32, 80) / 255.0, config.theme_config.colors.accent.?[0]);
}

test "app config loads and selects installed themes" {
    var root = try parseTestRoot(
        \\{
        \\  "theme": { "theme": "default", "active": "Forest" },
        \\  "installed_themes": [{
        \\    "name": "Forest",
        \\    "theme": { "theme": "default", "colors": { "background": "#101820" } },
        \\    "ui_font_size": 22,
        \\    "terminal_font_size": 19
        \\  }]
        \\}
    );
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(usize, 1), config.installed_themes.len);
    try std.testing.expectEqualStrings("Forest", config.installed_themes[0].name);
    try std.testing.expectEqual(@as(usize, 2), config.themeChoiceIndex());
    try std.testing.expectEqual(@as(?f32, 22), config.installed_themes[0].font_size);

    try config.selectThemeChoice(std.testing.allocator, 2);
    try std.testing.expectEqualStrings("Forest", config.active_theme.?);
    try std.testing.expectEqual(@as(f32, 0x10) / 255.0, config.theme_config.colors.background.?[0]);
    try std.testing.expectEqual(@as(f32, 19), config.terminal_font_size);

    try config.selectThemeChoice(std.testing.allocator, 1);
    try std.testing.expect(config.active_theme == null);
    try std.testing.expectEqual(theme.ThemeSource.omarchy, config.theme_config.source);
    try std.testing.expect(config.theme_config.colors.background == null);
}

test "app config accepts named open default" {
    var root = try parseTestRoot("{\"open\":{\"default\":\"cursor\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(config.default_open_action == .cursor);
}

test "app config accepts link open target" {
    var root = try parseTestRoot("{\"open\":{\"links\":\"system_browser\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(LinkOpenTarget.system_browser, config.link_open_target);
}

test "app config accepts automatic update check preference" {
    var root = try parseTestRoot("{\"updates\":{\"check_automatically\":false}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(!config.check_for_updates_automatically);
}

test "app config accepts custom open default" {
    var root = try parseTestRoot("{\"open\":{\"default\":{\"label\":\"Workbench\",\"action\":\"cursor .\"}}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(config.default_open_action == .custom);
    try std.testing.expectEqualStrings("Workbench", config.default_open_action.custom.label);
    try std.testing.expectEqualStrings("cursor .", config.default_open_action.custom.action);
}

fn parseTestRoot(raw: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{
        .allocate = .alloc_always,
    });
}

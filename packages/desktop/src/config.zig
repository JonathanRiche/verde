//! Shared user config loading for the native Verde shell.

const std = @import("std");
const theme = @import("./ui/theme.zig");

const log = std.log.scoped(.native_config);
const VERDE_CONFIG_RELATIVE_PATH = ".config/verde/verde.json";
const MIN_FONT_SIZE: f32 = 10.0;
const MAX_FONT_SIZE: f32 = 32.0;
pub const DEFAULT_TERMINAL_FONT_SIZE: f32 = 18.0;
const MIN_TERMINAL_FONT_SIZE: f32 = 13.5;
const MAX_TERMINAL_FONT_SIZE: f32 = 36.0;

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

pub const TerminalLaunchProfileConfig = struct {
    label: []u8,
    command: []const []u8,

    pub fn deinit(self: *TerminalLaunchProfileConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        for (self.command) |arg| allocator.free(arg);
        allocator.free(self.command);
    }
};

pub const AppConfig = struct {
    font_size: f32 = theme.DEFAULT_FONT_SIZE,
    terminal_font_size: f32 = DEFAULT_TERMINAL_FONT_SIZE,
    default_open_action: DefaultOpenAction = .folder,
    terminal_launch_profiles: []TerminalLaunchProfileConfig = &.{},

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        self.default_open_action.deinit(allocator);
        for (self.terminal_launch_profiles) |*profile| profile.deinit(allocator);
        allocator.free(self.terminal_launch_profiles);
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

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(xdg_config_home, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) {
            return std.fs.path.join(allocator, &.{ trimmed, "verde", "verde.json" });
        }
    }

    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), VERDE_CONFIG_RELATIVE_PATH });
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

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
    if (root.object.get("open")) |open_value| {
        applyOpenOverrides(allocator, config, open_value);
    }
    if (root.object.get("terminal")) |terminal_value| {
        applyTerminalOverrides(allocator, config, terminal_value);
    }
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

    const default_value = open_value.object.get("default") orelse return;
    const parsed = parseDefaultOpenAction(allocator, default_value) orelse return;

    config.default_open_action.deinit(allocator);
    config.default_open_action = parsed;
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

    log.warn("ignoring unsupported open.default value: {s}", .{trimmed});
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
    var root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var ui = std.json.ObjectMap.init(std.testing.allocator);
            errdefer ui.deinit();
            try ui.put("font_size", .{ .integer = 22 });

            try object.put("ui", .{ .object = ui });
            break :blk object;
        },
    };
    defer root.object.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root);

    try std.testing.expectEqual(@as(f32, 22.0), config.font_size);
}

test "app config ignores out-of-range ui.font_size" {
    var root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var ui = std.json.ObjectMap.init(std.testing.allocator);
            errdefer ui.deinit();
            try ui.put("font_size", .{ .integer = 64 });

            try object.put("ui", .{ .object = ui });
            break :blk object;
        },
    };
    defer root.object.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root);

    try std.testing.expectEqual(theme.DEFAULT_FONT_SIZE, config.font_size);
}

test "app config accepts named open default" {
    var root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var open = std.json.ObjectMap.init(std.testing.allocator);
            errdefer open.deinit();
            try open.put("default", .{ .string = "cursor" });

            try object.put("open", .{ .object = open });
            break :blk object;
        },
    };
    defer root.object.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root);

    try std.testing.expect(config.default_open_action == .cursor);
}

test "app config accepts custom open default" {
    var root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var open = std.json.ObjectMap.init(std.testing.allocator);
            errdefer open.deinit();

            var custom = std.json.ObjectMap.init(std.testing.allocator);
            errdefer custom.deinit();
            try custom.put("label", .{ .string = "Workbench" });
            try custom.put("action", .{ .string = "cursor ." });

            try open.put("default", .{ .object = custom });
            try object.put("open", .{ .object = open });
            break :blk object;
        },
    };
    defer root.object.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root);

    try std.testing.expect(config.default_open_action == .custom);
    try std.testing.expectEqualStrings("Workbench", config.default_open_action.custom.label);
    try std.testing.expectEqualStrings("cursor .", config.default_open_action.custom.action);
}

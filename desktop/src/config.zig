//! Shared user config loading for the native Verde shell.

const std = @import("std");

const log = std.log.scoped(.native_config);
const VERDE_CONFIG_RELATIVE_PATH = ".config/verde/verde.json";
const DEFAULT_FONT_SIZE: f32 = 18.0;
const MIN_FONT_SIZE: f32 = 10.0;
const MAX_FONT_SIZE: f32 = 32.0;

pub const AppConfig = struct {
    font_size: f32 = DEFAULT_FONT_SIZE,
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
    applyAppOverrides(&config, root.value);
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
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(xdg_config_home, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) {
            return std.fs.path.join(allocator, &.{ trimmed, "verde", "verde.json" });
        }
    }

    const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), VERDE_CONFIG_RELATIVE_PATH });
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 128);
}

fn applyAppOverrides(config: *AppConfig, root: std.json.Value) void {
    if (root != .object) {
        log.warn("verde config must be a JSON object when present", .{});
        return;
    }

    const ui_value = root.object.get("ui") orelse return;
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
    applyAppOverrides(&config, root);

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
    applyAppOverrides(&config, root);

    try std.testing.expectEqual(DEFAULT_FONT_SIZE, config.font_size);
}

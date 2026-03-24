//! Keyboard shortcut loading and matching for the native Verde shell.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const shared_config = @import("config.zig");

const log = std.log.scoped(.native_keybinds);

pub const NativeKeyboardAction = enum {
    refresh,
};

pub const Keybind = struct {
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
    primary: bool = false,
    shift: bool = false,
    key: sdl.Keycode,

    fn eql(self: Keybind, other: Keybind) bool {
        return self.alt == other.alt and
            self.ctrl == other.ctrl and
            self.meta == other.meta and
            self.primary == other.primary and
            self.shift == other.shift and
            self.key == other.key;
    }

    fn matches(self: Keybind, event: *const sdl.KeyboardEvent) bool {
        if (!event.down or event.repeat or event.key != self.key) {
            return false;
        }

        const primary_uses_meta = builtin.os.tag == .macos;
        const expected_ctrl = self.ctrl or (self.primary and !primary_uses_meta);
        const expected_meta = self.meta or (self.primary and primary_uses_meta);

        return expected_ctrl == hasModifier(event.mod, sdl.Keymod.ctrl) and
            expected_meta == hasModifier(event.mod, sdl.Keymod.gui) and
            self.alt == hasModifier(event.mod, sdl.Keymod.alt) and
            self.shift == hasModifier(event.mod, sdl.Keymod.shift);
    }
};

pub const NativeKeyboardConfig = struct {
    allocator: std.mem.Allocator,
    refresh: []Keybind,

    pub fn load(allocator: std.mem.Allocator) !NativeKeyboardConfig {
        var config: NativeKeyboardConfig = .{
            .allocator = allocator,
            .refresh = try cloneDefaultKeybinds(allocator),
        };

        var parsed = shared_config.readRootValue(allocator) catch |err| {
            log.warn("failed to read verde config: {s}", .{@errorName(err)});
            return config;
        };
        if (parsed == null) return config;
        defer parsed.?.deinit();

        config.applyOverrides(parsed.?.value);
        log.info("loaded keybinds from verde config", .{});
        return config;
    }

    pub fn deinit(self: *NativeKeyboardConfig) void {
        self.allocator.free(self.refresh);
    }

    pub fn actionForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?NativeKeyboardAction {
        if (matchesAny(self.refresh, event)) {
            return .refresh;
        }

        return null;
    }

    fn applyOverrides(self: *NativeKeyboardConfig, root: std.json.Value) void {
        if (root != .object) {
            log.warn("verde config must be a JSON object when present", .{});
            return;
        }

        const keybinds_value = root.object.get("keybinds") orelse return;
        if (keybinds_value != .object) {
            log.warn("keybinds must be an object when provided", .{});
            return;
        }

        if (keybinds_value.object.get("refresh")) |refresh_value| {
            if (self.parseOverrideValue(refresh_value, "refresh")) |bindings| {
                self.allocator.free(self.refresh);
                self.refresh = bindings;
            }
        }
    }

    fn parseOverrideValue(self: *const NativeKeyboardConfig, value: std.json.Value, comptime field_name: []const u8) ?[]Keybind {
        return switch (value) {
            .null => self.allocator.alloc(Keybind, 0) catch null,
            .string => |binding| self.parseSingleBinding(binding, field_name),
            .array => |items| self.parseBindingArray(items.items, field_name),
            else => blk: {
                log.warn("keybinds.{s} must be a string, string array, null, or omitted", .{field_name});
                break :blk null;
            },
        };
    }

    fn parseSingleBinding(self: *const NativeKeyboardConfig, binding: []const u8, comptime field_name: []const u8) ?[]Keybind {
        const trimmed = std.mem.trim(u8, binding, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            return self.allocator.alloc(Keybind, 0) catch null;
        }

        const parsed = parseAccelerator(trimmed) orelse {
            log.warn("ignoring invalid keybind for {s}: {s}", .{ field_name, trimmed });
            return self.allocator.alloc(Keybind, 0) catch null;
        };

        const bindings = self.allocator.alloc(Keybind, 1) catch return null;
        bindings[0] = parsed;
        return bindings;
    }

    fn parseBindingArray(self: *const NativeKeyboardConfig, values: []const std.json.Value, comptime field_name: []const u8) ?[]Keybind {
        if (values.len == 0) {
            return self.allocator.alloc(Keybind, 0) catch null;
        }

        var parsed: std.ArrayList(Keybind) = .empty;
        defer parsed.deinit(self.allocator);

        for (values) |value| {
            if (value != .string) {
                log.warn("ignoring non-string keybind entry for {s}", .{field_name});
                continue;
            }

            const trimmed = std.mem.trim(u8, value.string, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                continue;
            }

            const binding = parseAccelerator(trimmed) orelse {
                log.warn("ignoring invalid keybind for {s}: {s}", .{ field_name, trimmed });
                continue;
            };

            if (containsKeybind(parsed.items, binding)) {
                continue;
            }

            parsed.append(self.allocator, binding) catch return null;
        }

        if (parsed.items.len == 0) {
            log.warn("keybinds.{s} did not contain any valid accelerators", .{field_name});
        }

        return parsed.toOwnedSlice(self.allocator) catch null;
    }
};

fn cloneDefaultKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+R"),
        try parseDefaultAccelerator("CommandOrControl+Shift+R"),
        try parseDefaultAccelerator("F5"),
    });
}

fn parseDefaultAccelerator(binding: []const u8) !Keybind {
    return parseAccelerator(binding) orelse error.InvalidDefaultKeybind;
}

fn matchesAny(bindings: []const Keybind, event: *const sdl.KeyboardEvent) bool {
    for (bindings) |binding| {
        if (binding.matches(event)) {
            return true;
        }
    }

    return false;
}

fn containsKeybind(bindings: []const Keybind, needle: Keybind) bool {
    for (bindings) |binding| {
        if (binding.eql(needle)) {
            return true;
        }
    }

    return false;
}

fn hasModifier(modifier_state: sdl.Keymod, modifier_mask: u16) bool {
    const state_bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (state_bits & modifier_mask) != 0;
}

fn parseAccelerator(binding: []const u8) ?Keybind {
    var parsed: Keybind = .{ .key = .unknown };
    var tokens = std.mem.tokenizeScalar(u8, binding, '+');

    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            return null;
        }

        if (parseModifier(trimmed, &parsed)) {
            continue;
        }

        if (parsed.key != .unknown) {
            return null;
        }

        parsed.key = parseKeycode(trimmed) orelse return null;
    }

    if (parsed.key == .unknown) {
        return null;
    }

    return parsed;
}

fn parseModifier(token: []const u8, binding: *Keybind) bool {
    if (std.ascii.eqlIgnoreCase(token, "CommandOrControl") or std.ascii.eqlIgnoreCase(token, "CmdOrCtrl")) {
        binding.primary = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Control") or std.ascii.eqlIgnoreCase(token, "Ctrl")) {
        binding.ctrl = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Command") or std.ascii.eqlIgnoreCase(token, "Cmd")) {
        binding.meta = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Super") or std.ascii.eqlIgnoreCase(token, "Meta") or std.ascii.eqlIgnoreCase(token, "Win")) {
        binding.meta = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Alt") or std.ascii.eqlIgnoreCase(token, "Option")) {
        binding.alt = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Shift")) {
        binding.shift = true;
        return true;
    }

    return false;
}

fn parseKeycode(token: []const u8) ?sdl.Keycode {
    if (token.len == 1) {
        return switch (std.ascii.toLower(token[0])) {
            'a' => .a,
            'b' => .b,
            'c' => .c,
            'd' => .d,
            'e' => .e,
            'f' => .f,
            'g' => .g,
            'h' => .h,
            'i' => .i,
            'j' => .j,
            'k' => .k,
            'l' => .l,
            'm' => .m,
            'n' => .n,
            'o' => .o,
            'p' => .p,
            'q' => .q,
            'r' => .r,
            's' => .s,
            't' => .t,
            'u' => .u,
            'v' => .v,
            'w' => .w,
            'x' => .x,
            'y' => .y,
            'z' => .z,
            '0' => .@"0",
            '1' => .@"1",
            '2' => .@"2",
            '3' => .@"3",
            '4' => .@"4",
            '5' => .@"5",
            '6' => .@"6",
            '7' => .@"7",
            '8' => .@"8",
            '9' => .@"9",
            '-' => .minus,
            '=' => .equals,
            else => null,
        };
    }

    if (token.len >= 2 and (token[0] == 'F' or token[0] == 'f')) {
        const number = std.fmt.parseUnsigned(u8, token[1..], 10) catch return null;
        return switch (number) {
            1 => .f1,
            2 => .f2,
            3 => .f3,
            4 => .f4,
            5 => .f5,
            6 => .f6,
            7 => .f7,
            8 => .f8,
            9 => .f9,
            10 => .f10,
            11 => .f11,
            12 => .f12,
            13 => .f13,
            14 => .f14,
            15 => .f15,
            16 => .f16,
            17 => .f17,
            18 => .f18,
            19 => .f19,
            20 => .f20,
            21 => .f21,
            22 => .f22,
            23 => .f23,
            24 => .f24,
            else => null,
        };
    }

    if (std.ascii.eqlIgnoreCase(token, "Minus")) return .minus;
    if (std.ascii.eqlIgnoreCase(token, "Plus")) return .equals;
    if (std.ascii.eqlIgnoreCase(token, "Equal")) return .equals;
    if (std.ascii.eqlIgnoreCase(token, "Equals")) return .equals;
    if (std.ascii.eqlIgnoreCase(token, "Enter")) return .@"return";
    if (std.ascii.eqlIgnoreCase(token, "Return")) return .@"return";
    if (std.ascii.eqlIgnoreCase(token, "Escape")) return .escape;
    if (std.ascii.eqlIgnoreCase(token, "Esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(token, "Space")) return .space;
    if (std.ascii.eqlIgnoreCase(token, "Spacebar")) return .space;
    if (std.ascii.eqlIgnoreCase(token, "Tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(token, "Backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(token, "Delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(token, "Insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(token, "Home")) return .home;
    if (std.ascii.eqlIgnoreCase(token, "End")) return .end;
    if (std.ascii.eqlIgnoreCase(token, "PageUp")) return .pageup;
    if (std.ascii.eqlIgnoreCase(token, "PgUp")) return .pageup;
    if (std.ascii.eqlIgnoreCase(token, "PageDown")) return .pagedown;
    if (std.ascii.eqlIgnoreCase(token, "PgDn")) return .pagedown;
    if (std.ascii.eqlIgnoreCase(token, "Up")) return .up;
    if (std.ascii.eqlIgnoreCase(token, "Down")) return .down;
    if (std.ascii.eqlIgnoreCase(token, "Left")) return .left;
    if (std.ascii.eqlIgnoreCase(token, "Right")) return .right;

    return null;
}

test "parse accelerator matches desktop-style refresh binding" {
    const binding = parseAccelerator("CommandOrControl+R") orelse return error.TestUnexpectedResult;

    try std.testing.expect(binding.primary);
    try std.testing.expectEqual(false, binding.shift);
    try std.testing.expectEqual(sdl.Keycode.r, binding.key);
}

test "array parsing deduplicates repeated bindings" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            var bindings = std.json.Array.init(std.testing.allocator);
            errdefer bindings.deinit();
            try bindings.append(.{ .string = "F5" });
            try bindings.append(.{ .string = "f5" });

            try keybinds.put("refresh", .{ .array = bindings });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.refresh.len);
    try std.testing.expectEqual(sdl.Keycode.f5, config.refresh[0].key);
}

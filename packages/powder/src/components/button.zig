//! Retained action button components.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const sdl = @import("../sdl.zig");

pub const ButtonConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 96.0,
    height: f32 = 32.0,
    padding_x: f32 = 10.0,
    padding_y: f32 = 6.0,
    label: []const u8 = "",
    font_size: f32 = 14.0,
    background_color: draw.Color = .{ .r = 0.15, .g = 0.18, .b = 0.21, .a = 1.0 },
    hover_color: draw.Color = .{ .r = 0.20, .g = 0.24, .b = 0.28, .a = 1.0 },
    pressed_color: draw.Color = .{ .r = 0.11, .g = 0.14, .b = 0.17, .a = 1.0 },
    disabled_color: draw.Color = .{ .r = 0.11, .g = 0.12, .b = 0.14, .a = 0.70 },
    border_color: draw.Color = .{ .r = 0.30, .g = 0.34, .b = 0.39, .a = 1.0 },
    focus_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    disabled_text_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled: bool = false,
};

pub const IconButtonConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 32.0,
    height: f32 = 32.0,
    icon_inset: f32 = 8.0,
    icon_uv: draw.Rect = .{},
    background_color: draw.Color = .{ .r = 0.15, .g = 0.18, .b = 0.21, .a = 1.0 },
    hover_color: draw.Color = .{ .r = 0.20, .g = 0.24, .b = 0.28, .a = 1.0 },
    pressed_color: draw.Color = .{ .r = 0.11, .g = 0.14, .b = 0.17, .a = 1.0 },
    disabled_color: draw.Color = .{ .r = 0.11, .g = 0.12, .b = 0.14, .a = 0.70 },
    border_color: draw.Color = .{ .r = 0.30, .g = 0.34, .b = 0.39, .a = 1.0 },
    focus_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    icon_color: draw.Color = draw.Color.white,
    disabled_icon_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled: bool = false,
};

pub const ActivationKey = enum {
    enter,
    space,
};

pub const Key = key_input;

pub const Input = union(enum) {
    mouse_move: draw.Vec2,
    mouse_down: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_leave,
    key: Key,
    activation_key: ActivationKey,
    focus: bool,
};

pub const ButtonEvent = union(enum) {
    clicked,
    activated,
    focus_changed: bool,
};

pub const ButtonCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: ButtonEvent) void = null,
};

pub fn Button(comptime config: ButtonConfig) type {
    return struct {
        const Component = @This();

        hovered: bool = false,
        pressed: bool = false,
        focused: bool = false,
        disabled: bool = config.disabled,
        callbacks: ButtonCallbacks = .{},

        pub fn init() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: ButtonCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setDisabled(self: *Component, disabled: bool) void {
            self.disabled = disabled;
            if (disabled) self.pressed = false;
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            return self.handleInput(inputFromSdl(event) orelse return false);
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .mouse_move => |point| {
                    const inside = Component.bounds().contains(point);
                    const changed = self.hovered != inside;
                    self.hovered = inside;
                    return inside or changed or self.pressed;
                },
                .mouse_down => |point| {
                    const inside = Component.bounds().contains(point);
                    self.setFocused(inside);
                    if (!inside or self.disabled) {
                        self.pressed = false;
                        return inside;
                    }
                    self.hovered = true;
                    self.pressed = true;
                    return true;
                },
                .mouse_up => |point| {
                    const inside = Component.bounds().contains(point);
                    const was_pressed = self.pressed;
                    self.hovered = inside;
                    self.pressed = false;
                    if (was_pressed and inside and !self.disabled) {
                        self.emit(.clicked);
                        return true;
                    }
                    return was_pressed or inside;
                },
                .mouse_leave => {
                    const changed = self.hovered;
                    self.hovered = false;
                    return changed or self.pressed;
                },
                .key => |key| {
                    if (key.code != .enter) return false;
                    return self.activateFromKeyboard(.enter);
                },
                .activation_key => |key| return self.activateFromKeyboard(key),
                .focus => |focused| {
                    const changed = self.focused != focused;
                    self.setFocused(focused);
                    return changed;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try renderButtonShell(
                allocator,
                batch,
                Component.bounds(),
                self.backgroundColor(),
                if (self.focused and !self.disabled) config.focus_color else config.border_color,
            );
            if (config.label.len > 0) {
                try batch.glyph(allocator, Component.labelRect(), .{}, if (self.disabled) config.disabled_text_color else config.text_color);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn activateFromKeyboard(self: *Component, key: ActivationKey) bool {
            _ = key;
            if (!self.focused or self.disabled) return false;
            self.emit(.activated);
            return true;
        }

        fn setFocused(self: *Component, focused: bool) void {
            if (self.focused == focused) return;
            self.focused = focused;
            self.emit(.{ .focus_changed = focused });
        }

        fn emit(self: *Component, event: ButtonEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
        }

        fn backgroundColor(self: *const Component) draw.Color {
            if (self.disabled) return config.disabled_color;
            if (self.pressed) return config.pressed_color;
            if (self.hovered) return config.hover_color;
            return config.background_color;
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn labelRect() draw.Rect {
            const available_w = @max(config.width - config.padding_x * 2.0, 0.0);
            const text_w = @min(approximateWidth(config.label.len, config.font_size), available_w);
            const text_h = @max(config.height - config.padding_y * 2.0, 1.0);
            return .{
                .x = config.x + config.padding_x,
                .y = config.y + (config.height - text_h) * 0.5,
                .w = text_w,
                .h = text_h,
            };
        }
    };
}

pub fn IconButton(comptime config: IconButtonConfig) type {
    return struct {
        const Component = @This();

        hovered: bool = false,
        pressed: bool = false,
        focused: bool = false,
        disabled: bool = config.disabled,
        callbacks: ButtonCallbacks = .{},

        pub fn init() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: ButtonCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setDisabled(self: *Component, disabled: bool) void {
            self.disabled = disabled;
            if (disabled) self.pressed = false;
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            return self.handleInput(inputFromSdl(event) orelse return false);
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .mouse_move => |point| {
                    const inside = Component.bounds().contains(point);
                    const changed = self.hovered != inside;
                    self.hovered = inside;
                    return inside or changed or self.pressed;
                },
                .mouse_down => |point| {
                    const inside = Component.bounds().contains(point);
                    self.setFocused(inside);
                    if (!inside or self.disabled) {
                        self.pressed = false;
                        return inside;
                    }
                    self.hovered = true;
                    self.pressed = true;
                    return true;
                },
                .mouse_up => |point| {
                    const inside = Component.bounds().contains(point);
                    const was_pressed = self.pressed;
                    self.hovered = inside;
                    self.pressed = false;
                    if (was_pressed and inside and !self.disabled) {
                        self.emit(.clicked);
                        return true;
                    }
                    return was_pressed or inside;
                },
                .mouse_leave => {
                    const changed = self.hovered;
                    self.hovered = false;
                    return changed or self.pressed;
                },
                .key => |key| {
                    if (key.code != .enter) return false;
                    return self.activateFromKeyboard(.enter);
                },
                .activation_key => |key| return self.activateFromKeyboard(key),
                .focus => |focused| {
                    const changed = self.focused != focused;
                    self.setFocused(focused);
                    return changed;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try renderButtonShell(
                allocator,
                batch,
                Component.bounds(),
                self.backgroundColor(),
                if (self.focused and !self.disabled) config.focus_color else config.border_color,
            );
            try batch.glyph(allocator, Component.iconRect(), config.icon_uv, if (self.disabled) config.disabled_icon_color else config.icon_color);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn activateFromKeyboard(self: *Component, key: ActivationKey) bool {
            _ = key;
            if (!self.focused or self.disabled) return false;
            self.emit(.activated);
            return true;
        }

        fn setFocused(self: *Component, focused: bool) void {
            if (self.focused == focused) return;
            self.focused = focused;
            self.emit(.{ .focus_changed = focused });
        }

        fn emit(self: *Component, event: ButtonEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
        }

        fn backgroundColor(self: *const Component) draw.Color {
            if (self.disabled) return config.disabled_color;
            if (self.pressed) return config.pressed_color;
            if (self.hovered) return config.hover_color;
            return config.background_color;
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn iconRect() draw.Rect {
            const inset = @min(config.icon_inset, @min(config.width, config.height) * 0.5);
            return .{
                .x = config.x + inset,
                .y = config.y + inset,
                .w = @max(config.width - inset * 2.0, 0.0),
                .h = @max(config.height - inset * 2.0, 0.0),
            };
        }
    };
}

fn inputFromSdl(event: *const sdl.Event) ?Input {
    switch (event.type) {
        .mouse_motion => return .{ .mouse_move = .{ .x = event.motion.x, .y = event.motion.y } },
        .mouse_button_down => {
            if (event.button.button != 1) return null;
            return .{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } };
        },
        .mouse_button_up => {
            if (event.button.button != 1) return null;
            return .{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } };
        },
        .key_down => {
            if (event.key.repeat) return null;
            return switch (event.key.key) {
                .@"return", .kp_enter => .{ .activation_key = .enter },
                .space => .{ .activation_key = .space },
                else => if (Key.fromSdl(event.key)) |key| .{ .key = key } else null,
            };
        },
        else => return null,
    }
}

fn renderButtonShell(allocator: std.mem.Allocator, batch: *draw.RenderBatch, bounds: draw.Rect, background: draw.Color, border: draw.Color) !void {
    try batch.rect(allocator, bounds, background);
    try rectOutline(allocator, batch, bounds, border);
}

fn rectOutline(allocator: std.mem.Allocator, batch: *draw.RenderBatch, r: draw.Rect, color: draw.Color) !void {
    if (r.w <= 0.0 or r.h <= 0.0) return;
    try batch.rect(allocator, .{ .x = r.x, .y = r.y, .w = r.w, .h = 1.0 }, color);
    try batch.rect(allocator, .{ .x = r.x, .y = r.y + r.h - 1.0, .w = r.w, .h = 1.0 }, color);
    try batch.rect(allocator, .{ .x = r.x, .y = r.y, .w = 1.0, .h = r.h }, color);
    try batch.rect(allocator, .{ .x = r.x + r.w - 1.0, .y = r.y, .w = 1.0, .h = r.h }, color);
}

fn approximateWidth(len: usize, font_size: f32) f32 {
    return @as(f32, @floatFromInt(len)) * font_size * 0.55;
}

const ButtonProbe = struct {
    clicked: usize = 0,
    activated: usize = 0,
    focus_changed: usize = 0,
};

fn probeButtonEvent(context: ?*anyopaque, event: ButtonEvent) void {
    const probe: *ButtonProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .clicked => probe.clicked += 1,
        .activated => probe.activated += 1,
        .focus_changed => probe.focus_changed += 1,
    }
}

test "button emits clicked on mouse release inside bounds" {
    const Action = Button(.{ .x = 10, .y = 10, .width = 80, .height = 24, .label = "Run" });
    var button = Action.init();
    var probe: ButtonProbe = .{};
    button.setCallbacks(.{ .context = &probe, .on_event = probeButtonEvent });

    try std.testing.expect(button.handleInput(.{ .mouse_down = .{ .x = 12, .y = 12 } }));
    try std.testing.expect(button.pressed);
    try std.testing.expect(button.focused);
    try std.testing.expect(button.handleInput(.{ .mouse_up = .{ .x = 20, .y = 18 } }));
    try std.testing.expect(!button.pressed);
    try std.testing.expectEqual(@as(usize, 1), probe.clicked);
}

test "button emits activated for focused keyboard input" {
    const Action = Button(.{});
    var button = Action.init();
    var probe: ButtonProbe = .{};
    button.setCallbacks(.{ .context = &probe, .on_event = probeButtonEvent });

    try std.testing.expect(button.handleInput(.{ .focus = true }));
    try std.testing.expect(button.handleInput(.{ .key = .{ .code = .enter } }));
    try std.testing.expect(button.handleInput(.{ .activation_key = .space }));
    try std.testing.expectEqual(@as(usize, 2), probe.activated);
}

test "disabled button consumes pointer without activation" {
    const Action = Button(.{ .disabled = true });
    var button = Action.init();
    var probe: ButtonProbe = .{};
    button.setCallbacks(.{ .context = &probe, .on_event = probeButtonEvent });

    try std.testing.expect(button.handleInput(.{ .mouse_down = .{ .x = 4, .y = 4 } }));
    try std.testing.expect(button.handleInput(.{ .mouse_up = .{ .x = 4, .y = 4 } }));
    try std.testing.expect(!button.pressed);
    try std.testing.expectEqual(@as(usize, 0), probe.clicked);
    try std.testing.expect(!button.handleInput(.{ .activation_key = .enter }));
}

test "icon button renders shell and icon" {
    const Action = IconButton(.{ .x = 2, .y = 3, .width = 20, .height = 20, .icon_inset = 5 });
    var button = Action.init();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try button.render(std.testing.allocator, &batch);

    try std.testing.expectEqual(@as(usize, 6), batch.commands.items.len);
    try std.testing.expectEqual(draw.CommandKind.text, batch.commands.items[5].kind);
    try std.testing.expectEqual(@as(f32, 7.0), batch.commands.items[5].rect.x);
    try std.testing.expectEqual(@as(f32, 10.0), batch.commands.items[5].rect.w);
}

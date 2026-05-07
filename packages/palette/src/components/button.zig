//! Retained action button components.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const sdl = @import("../sdl.zig");
const text_layout = @import("../text_layout.zig");

pub const ButtonContentAlign = enum {
    start,
    center,
    end,
};

pub const ButtonConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 96.0,
    height: f32 = 32.0,
    padding_x: f32 = 10.0,
    padding_y: f32 = 6.0,
    label: []const u8 = "",
    leading_icon: []const u8 = "",
    trailing_icon: []const u8 = "",
    icon_text: []const u8 = "",
    content_align: ButtonContentAlign = .center,
    font_size: f32 = 14.0,
    icon_font_size: ?f32 = null,
    icon_gap: f32 = 6.0,
    font_role: ?draw.FontRole = .ui,
    icon_font_role: ?draw.FontRole = .icon,
    font_id: ?u32 = null,
    icon_font_id: ?u32 = null,
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    circular: bool = false,
    background_color: draw.Color = .{ .r = 0.15, .g = 0.18, .b = 0.21, .a = 1.0 },
    hover_color: draw.Color = .{ .r = 0.20, .g = 0.24, .b = 0.28, .a = 1.0 },
    pressed_color: draw.Color = .{ .r = 0.11, .g = 0.14, .b = 0.17, .a = 1.0 },
    disabled_color: draw.Color = .{ .r = 0.11, .g = 0.12, .b = 0.14, .a = 0.70 },
    border_color: draw.Color = .{ .r = 0.30, .g = 0.34, .b = 0.39, .a = 1.0 },
    focus_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    icon_color: draw.Color = draw.Color.white,
    disabled_text_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled_icon_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled: bool = false,
    z_index: i32 = 0,
};

pub const IconButtonConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 32.0,
    height: f32 = 32.0,
    icon_inset: f32 = 8.0,
    icon_uv: draw.Rect = .{},
    icon_text: []const u8 = "",
    font_size: f32 = 16.0,
    icon_font_role: ?draw.FontRole = .icon,
    icon_font_id: ?u32 = null,
    corner_radius: f32 = 4.0,
    border_width: f32 = 1.0,
    circular: bool = false,
    background_color: draw.Color = .{ .r = 0.15, .g = 0.18, .b = 0.21, .a = 1.0 },
    hover_color: draw.Color = .{ .r = 0.20, .g = 0.24, .b = 0.28, .a = 1.0 },
    pressed_color: draw.Color = .{ .r = 0.11, .g = 0.14, .b = 0.17, .a = 1.0 },
    disabled_color: draw.Color = .{ .r = 0.11, .g = 0.12, .b = 0.14, .a = 0.70 },
    border_color: draw.Color = .{ .r = 0.30, .g = 0.34, .b = 0.39, .a = 1.0 },
    focus_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    icon_color: draw.Color = draw.Color.white,
    disabled_icon_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled: bool = false,
    z_index: i32 = 0,
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
        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        font_metrics: ?text_layout.FontMetrics = null,
        z_index: i32 = config.z_index,
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

        pub fn setFontMetrics(self: *Component, metrics_value: text_layout.FontMetrics) void {
            self.font_metrics = metrics_value;
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn labelRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            const group = self.contentMetrics();
            const text_w = @min(group.width, @max(bounds_rect.w - config.padding_x * 2.0, 0.0));
            const text_h = @max(@min(group.height, bounds_rect.h - config.padding_y * 2.0), 1.0);
            const x = switch (config.content_align) {
                .start => bounds_rect.x + config.padding_x,
                .center => bounds_rect.x + (bounds_rect.w - text_w) * 0.5,
                .end => bounds_rect.x + bounds_rect.w - config.padding_x - text_w,
            };
            return .{
                .x = x,
                .y = bounds_rect.y + (bounds_rect.h - text_h) * 0.5,
                .w = text_w,
                .h = text_h,
            };
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            return self.handleInput(inputFromSdl(event) orelse return false);
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .mouse_move => |point| {
                    const inside = self.bounds().contains(point);
                    const changed = self.hovered != inside;
                    self.hovered = inside;
                    return inside or changed or self.pressed;
                },
                .mouse_down => |point| {
                    const inside = self.bounds().contains(point);
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
                    const inside = self.bounds().contains(point);
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
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            try renderButtonShell(
                allocator,
                batch,
                self.bounds(),
                self.backgroundColor(),
                if (self.focused and !self.disabled) config.focus_color else config.border_color,
                self.cornerRadius(),
                config.border_width,
            );
            try self.renderContent(allocator, batch);
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

        fn metrics(self: *const Component) text_layout.FontMetrics {
            if (self.font_metrics) |metrics_value| return metrics_value;
            return text_layout.FontMetrics.fallback(config.font_size);
        }

        fn displayText(_: *const Component) []const u8 {
            return if (config.icon_text.len > 0) config.icon_text else config.label;
        }

        fn cornerRadius(self: *const Component) f32 {
            return if (config.circular) @min(self.bounds().w, self.bounds().h) * 0.5 else config.corner_radius;
        }

        fn contentMetrics(self: *const Component) struct { width: f32, height: f32 } {
            var width: f32 = 0.0;
            var height: f32 = 0.0;
            var count: usize = 0;
            self.visitContentRuns(&width, &height, &count, null);
            if (count > 1) width += config.icon_gap * @as(f32, @floatFromInt(count - 1));
            return .{ .width = width, .height = height };
        }

        fn renderContent(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (self.contentMetrics().width <= 0.0) return;
            var runs: [3]draw.TextRun = undefined;
            var count: usize = 0;
            var unused_width: f32 = 0.0;
            var unused_height: f32 = 0.0;
            self.visitContentRuns(&unused_width, &unused_height, &count, &runs);
            const rect = self.labelRect();
            var x = rect.x;
            for (runs[0..count], 0..) |*run, index| {
                run.x = x;
                run.y = self.bounds().y + @max((self.bounds().h - run.line_height) * 0.5, 0.0);
                x += self.measureRun(run.text, run.font_size);
                if (index + 1 < count) x += config.icon_gap;
            }
            try batch.textRuns(allocator, rect, self.displayText(), runs[0..count], if (self.disabled) config.disabled_text_color else config.text_color, config.font_size, self.bounds(), @max(rect.h, 1.0), self.metrics().fixedAdvance());
        }

        fn visitContentRuns(self: *const Component, width: *f32, height: *f32, count: *usize, out: ?*[3]draw.TextRun) void {
            if (config.icon_text.len > 0) {
                self.addContentRun(config.icon_text, true, width, height, count, out);
                return;
            }
            self.addContentRun(config.leading_icon, true, width, height, count, out);
            self.addContentRun(config.label, false, width, height, count, out);
            self.addContentRun(config.trailing_icon, true, width, height, count, out);
        }

        fn addContentRun(self: *const Component, value: []const u8, icon: bool, width: *f32, height: *f32, count: *usize, out: ?*[3]draw.TextRun) void {
            if (value.len == 0) return;
            const font_size = if (icon) (config.icon_font_size orelse config.font_size) else config.font_size;
            const line_height = if (self.font_metrics) |metrics_value| metrics_value.line_height else font_size * 1.25;
            const color = if (self.disabled)
                if (icon) config.disabled_icon_color else config.disabled_text_color
            else if (icon) config.icon_color else config.text_color;
            if (out) |runs| {
                runs[count.*] = .{
                    .text = value,
                    .byte_start = 0,
                    .byte_end = value.len,
                    .font_size = font_size,
                    .line_height = line_height,
                    .color = color,
                    .clip = self.bounds(),
                    .font_role = if (icon) config.icon_font_role else config.font_role,
                    .font_id = if (icon) config.icon_font_id else config.font_id,
                };
            }
            count.* += 1;
            width.* += self.measureRun(value, font_size);
            height.* = @max(height.*, line_height);
        }

        fn measureRun(self: *const Component, value: []const u8, font_size: f32) f32 {
            if (self.font_metrics) |metrics_value| {
                if (font_size == metrics_value.font_size) return metrics_value.measureSlice(value);
            }
            return text_layout.FontMetrics.fallback(font_size).measureSlice(value);
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
        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        z_index: i32 = config.z_index,
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

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn iconRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            const inset = @min(config.icon_inset, @min(bounds_rect.w, bounds_rect.h) * 0.5);
            return .{
                .x = bounds_rect.x + inset,
                .y = bounds_rect.y + inset,
                .w = @max(bounds_rect.w - inset * 2.0, 0.0),
                .h = @max(bounds_rect.h - inset * 2.0, 0.0),
            };
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            return self.handleInput(inputFromSdl(event) orelse return false);
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .mouse_move => |point| {
                    const inside = self.bounds().contains(point);
                    const changed = self.hovered != inside;
                    self.hovered = inside;
                    return inside or changed or self.pressed;
                },
                .mouse_down => |point| {
                    const inside = self.bounds().contains(point);
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
                    const inside = self.bounds().contains(point);
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
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            try renderButtonShell(
                allocator,
                batch,
                self.bounds(),
                self.backgroundColor(),
                if (self.focused and !self.disabled) config.focus_color else config.border_color,
                self.cornerRadius(),
                config.border_width,
            );
            if (config.icon_text.len > 0) {
                const rect = self.iconTextRect();
                const color = if (self.disabled) config.disabled_icon_color else config.icon_color;
                const runs = [_]draw.TextRun{.{
                    .text = config.icon_text,
                    .byte_start = 0,
                    .byte_end = config.icon_text.len,
                    .x = rect.x,
                    .y = rect.y,
                    .font_size = config.font_size,
                    .line_height = config.font_size * 1.25,
                    .color = color,
                    .clip = self.bounds(),
                    .font_role = config.icon_font_role,
                    .font_id = config.icon_font_id,
                }};
                try batch.textRuns(allocator, rect, config.icon_text, &runs, color, config.font_size, self.bounds(), config.font_size * 1.25, config.font_size * 0.55);
            } else {
                try batch.image(allocator, self.iconRect(), .invalid, config.icon_uv, if (self.disabled) config.disabled_icon_color else config.icon_color, self.bounds());
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

        fn cornerRadius(self: *const Component) f32 {
            return if (config.circular) @min(self.bounds().w, self.bounds().h) * 0.5 else config.corner_radius;
        }

        fn iconTextRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            const width = text_layout.FontMetrics.fallback(config.font_size).measureSlice(config.icon_text);
            const height = config.font_size * 1.25;
            return .{
                .x = bounds_rect.x + (bounds_rect.w - width) * 0.5,
                .y = bounds_rect.y + (bounds_rect.h - height) * 0.5,
                .w = width,
                .h = height,
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

fn renderButtonShell(allocator: std.mem.Allocator, batch: *draw.RenderBatch, bounds: draw.Rect, background: draw.Color, border: draw.Color, radius: f32, border_width: f32) !void {
    try batch.panel(allocator, bounds, background, border, radius, border_width);
}

fn rectOutline(allocator: std.mem.Allocator, batch: *draw.RenderBatch, r: draw.Rect, color: draw.Color) !void {
    if (r.w <= 0.0 or r.h <= 0.0) return;
    try batch.rect(allocator, .{ .x = r.x, .y = r.y, .w = r.w, .h = 1.0 }, color);
    try batch.rect(allocator, .{ .x = r.x, .y = r.y + r.h - 1.0, .w = r.w, .h = 1.0 }, color);
    try batch.rect(allocator, .{ .x = r.x, .y = r.y, .w = 1.0, .h = r.h }, color);
    try batch.rect(allocator, .{ .x = r.x + r.w - 1.0, .y = r.y, .w = 1.0, .h = r.h }, color);
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

    try std.testing.expectEqual(@as(usize, 2), batch.commands.items.len);
    try std.testing.expectEqual(draw.CommandKind.image, batch.commands.items[1].kind);
    try std.testing.expectEqual(@as(f32, 7.0), batch.commands.items[1].rect.x);
    try std.testing.expectEqual(@as(f32, 10.0), batch.commands.items[1].rect.w);
}

test "button supports runtime bounds for hit testing and text rendering" {
    const Action = Button(.{ .label = "Send" });
    var button = Action.init();
    button.setBounds(.{ .x = 120, .y = 48, .w = 88, .h = 30 });
    var probe: ButtonProbe = .{};
    button.setCallbacks(.{ .context = &probe, .on_event = probeButtonEvent });

    try std.testing.expect(!button.handleInput(.{ .mouse_down = .{ .x = 4, .y = 4 } }));
    try std.testing.expect(button.handleInput(.{ .mouse_down = .{ .x = 126, .y = 52 } }));
    try std.testing.expect(button.handleInput(.{ .mouse_up = .{ .x = 126, .y = 52 } }));
    try std.testing.expectEqual(@as(usize, 1), probe.clicked);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try button.render(std.testing.allocator, &batch);
    var text_command: ?draw.Command = null;
    for (batch.commands.items) |command| {
        if (command.kind == .text) text_command = command;
    }
    try std.testing.expect(text_command != null);
    try std.testing.expectEqualStrings("Send", text_command.?.text);
    try std.testing.expect(text_command.?.rect.x > 120);
}

test "button emits icon and label text runs with roles" {
    const Action = Button(.{ .label = "Send", .leading_icon = ">", .trailing_icon = "v", .font_size = 14 });
    var button = Action.init();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try button.render(std.testing.allocator, &batch);

    var text_command: ?draw.Command = null;
    for (batch.commands.items) |command| {
        if (command.kind == .text) text_command = command;
    }
    try std.testing.expect(text_command != null);
    try std.testing.expectEqual(@as(usize, 3), text_command.?.text_runs.len);
    try std.testing.expectEqual(@as(?draw.FontRole, .icon), text_command.?.text_runs[0].font_role);
    try std.testing.expectEqual(@as(?draw.FontRole, .ui), text_command.?.text_runs[1].font_role);
    try std.testing.expectEqual(@as(?draw.FontRole, .icon), text_command.?.text_runs[2].font_role);
}

test "icon button supports runtime bounds for hit testing and icon geometry" {
    const Action = IconButton(.{ .icon_inset = 4 });
    var button = Action.init();
    button.setBounds(.{ .x = 50, .y = 70, .w = 28, .h = 28 });
    var probe: ButtonProbe = .{};
    button.setCallbacks(.{ .context = &probe, .on_event = probeButtonEvent });

    try std.testing.expect(button.handleInput(.{ .mouse_down = .{ .x = 52, .y = 72 } }));
    try std.testing.expect(button.handleInput(.{ .mouse_up = .{ .x = 52, .y = 72 } }));
    try std.testing.expectEqual(@as(usize, 1), probe.clicked);
    try std.testing.expectEqual(@as(f32, 54), button.iconRect().x);
    try std.testing.expectEqual(@as(f32, 20), button.iconRect().w);
}

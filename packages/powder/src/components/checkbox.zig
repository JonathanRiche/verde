//! Retained checkbox and toggle components.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const sdl = @import("../sdl.zig");

pub const CheckboxConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    size: f32 = 18.0,
    label_gap: f32 = 8.0,
    label: []const u8 = "",
    font_size: f32 = 14.0,
    background_color: draw.Color = .{ .r = 0.10, .g = 0.12, .b = 0.14, .a = 1.0 },
    hover_color: draw.Color = .{ .r = 0.15, .g = 0.18, .b = 0.21, .a = 1.0 },
    pressed_color: draw.Color = .{ .r = 0.08, .g = 0.10, .b = 0.12, .a = 1.0 },
    checked_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.31, .g = 0.35, .b = 0.40, .a = 1.0 },
    focus_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    label_color: draw.Color = draw.Color.white,
    disabled_color: draw.Color = .{ .r = 0.11, .g = 0.12, .b = 0.14, .a = 0.70 },
    disabled_label_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled: bool = false,
    checked: bool = false,
    z_index: i32 = 0,
};

pub const ToggleConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 38.0,
    height: f32 = 22.0,
    label_gap: f32 = 8.0,
    label: []const u8 = "",
    font_size: f32 = 14.0,
    track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 1.0 },
    hover_color: draw.Color = .{ .r = 0.23, .g = 0.26, .b = 0.30, .a = 1.0 },
    pressed_color: draw.Color = .{ .r = 0.13, .g = 0.15, .b = 0.18, .a = 1.0 },
    checked_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    thumb_color: draw.Color = draw.Color.white,
    border_color: draw.Color = .{ .r = 0.31, .g = 0.35, .b = 0.40, .a = 1.0 },
    focus_color: draw.Color = .{ .r = 0.32, .g = 0.58, .b = 0.88, .a = 1.0 },
    label_color: draw.Color = draw.Color.white,
    disabled_color: draw.Color = .{ .r = 0.11, .g = 0.12, .b = 0.14, .a = 0.70 },
    disabled_label_color: draw.Color = .{ .r = 0.58, .g = 0.63, .b = 0.68, .a = 0.80 },
    disabled: bool = false,
    checked: bool = false,
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

pub const CheckboxEvent = union(enum) {
    changed: bool,
    focus_changed: bool,
};

pub const CheckboxCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: CheckboxEvent) void = null,
};

pub fn Checkbox(comptime config: CheckboxConfig) type {
    return struct {
        const Component = @This();

        checked: bool = config.checked,
        hovered: bool = false,
        pressed: bool = false,
        focused: bool = false,
        disabled: bool = config.disabled,
        rect: draw.Rect = defaultCheckboxBounds(config),
        z_index: i32 = config.z_index,
        callbacks: CheckboxCallbacks = .{},

        pub fn init(checked: bool) Component {
            return .{ .checked = checked };
        }

        pub fn initDefault() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: CheckboxCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setDisabled(self: *Component, disabled: bool) void {
            self.disabled = disabled;
            if (disabled) self.pressed = false;
        }

        pub fn setChecked(self: *Component, checked: bool) void {
            if (self.checked == checked) return;
            self.checked = checked;
            self.emit(.{ .changed = checked });
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

        pub fn boxRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            const size = @min(config.size, @min(bounds_rect.w, bounds_rect.h));
            return .{ .x = bounds_rect.x, .y = bounds_rect.y, .w = size, .h = size };
        }

        pub fn labelRect(self: *const Component) draw.Rect {
            const box = self.boxRect();
            return .{
                .x = box.x + box.w + config.label_gap,
                .y = self.bounds().y,
                .w = @max(self.bounds().w - box.w - config.label_gap, 0.0),
                .h = self.bounds().h,
            };
        }

        pub fn toggle(self: *Component) bool {
            if (self.disabled) return false;
            self.setChecked(!self.checked);
            return true;
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
                        return self.toggle();
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
                    return self.toggleFromKeyboard(.enter);
                },
                .activation_key => |key| return self.toggleFromKeyboard(key),
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

            try renderCheckboxBox(
                allocator,
                batch,
                self.boxRect(),
                self.backgroundColor(),
                if (self.focused and !self.disabled) config.focus_color else config.border_color,
            );
            if (self.checked) {
                try batch.rect(allocator, self.checkRect(), if (self.disabled) config.disabled_label_color else config.checked_color);
            }
            if (config.label.len > 0) {
                const label_rect = self.labelRect();
                try batch.text(allocator, label_rect, config.label, if (self.disabled) config.disabled_label_color else config.label_color, config.font_size, label_rect);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn toggleFromKeyboard(self: *Component, key: ActivationKey) bool {
            _ = key;
            if (!self.focused or self.disabled) return false;
            return self.toggle();
        }

        fn setFocused(self: *Component, focused: bool) void {
            if (self.focused == focused) return;
            self.focused = focused;
            self.emit(.{ .focus_changed = focused });
        }

        fn emit(self: *Component, event: CheckboxEvent) void {
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

        fn checkRect(self: *const Component) draw.Rect {
            const box = self.boxRect();
            const inset = @max(box.w * 0.28, 2.0);
            return .{ .x = box.x + inset, .y = box.y + inset, .w = @max(box.w - inset * 2.0, 1.0), .h = @max(box.h - inset * 2.0, 1.0) };
        }
    };
}

pub fn Toggle(comptime config: ToggleConfig) type {
    return struct {
        const Component = @This();

        checked: bool = config.checked,
        hovered: bool = false,
        pressed: bool = false,
        focused: bool = false,
        disabled: bool = config.disabled,
        rect: draw.Rect = defaultToggleBounds(config),
        z_index: i32 = config.z_index,
        callbacks: CheckboxCallbacks = .{},

        pub fn init(checked: bool) Component {
            return .{ .checked = checked };
        }

        pub fn initDefault() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: CheckboxCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setDisabled(self: *Component, disabled: bool) void {
            self.disabled = disabled;
            if (disabled) self.pressed = false;
        }

        pub fn setChecked(self: *Component, checked: bool) void {
            if (self.checked == checked) return;
            self.checked = checked;
            self.emit(.{ .changed = checked });
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

        pub fn trackRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            return .{ .x = bounds_rect.x, .y = bounds_rect.y, .w = @min(config.width, bounds_rect.w), .h = @min(config.height, bounds_rect.h) };
        }

        pub fn labelRect(self: *const Component) draw.Rect {
            const track = self.trackRect();
            return .{
                .x = track.x + track.w + config.label_gap,
                .y = self.bounds().y,
                .w = @max(self.bounds().w - track.w - config.label_gap, 0.0),
                .h = self.bounds().h,
            };
        }

        pub fn toggle(self: *Component) bool {
            if (self.disabled) return false;
            self.setChecked(!self.checked);
            return true;
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
                        return self.toggle();
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
                    return self.toggleFromKeyboard(.enter);
                },
                .activation_key => |key| return self.toggleFromKeyboard(key),
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

            try renderCheckboxBox(
                allocator,
                batch,
                self.trackRect(),
                self.trackColor(),
                if (self.focused and !self.disabled) config.focus_color else config.border_color,
            );
            try batch.rect(allocator, self.thumbRect(), config.thumb_color);
            if (config.label.len > 0) {
                const label_rect = self.labelRect();
                try batch.text(allocator, label_rect, config.label, if (self.disabled) config.disabled_label_color else config.label_color, config.font_size, label_rect);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn toggleFromKeyboard(self: *Component, key: ActivationKey) bool {
            _ = key;
            if (!self.focused or self.disabled) return false;
            return self.toggle();
        }

        fn setFocused(self: *Component, focused: bool) void {
            if (self.focused == focused) return;
            self.focused = focused;
            self.emit(.{ .focus_changed = focused });
        }

        fn emit(self: *Component, event: CheckboxEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
        }

        fn trackColor(self: *const Component) draw.Color {
            if (self.disabled) return config.disabled_color;
            if (self.pressed) return config.pressed_color;
            if (self.checked) return config.checked_color;
            if (self.hovered) return config.hover_color;
            return config.track_color;
        }

        fn thumbRect(self: *const Component) draw.Rect {
            const track = self.trackRect();
            const inset = @max(track.h * 0.18, 2.0);
            const size = @max(track.h - inset * 2.0, 1.0);
            return .{
                .x = track.x + if (self.checked) @max(track.w - size - inset, inset) else inset,
                .y = track.y + inset,
                .w = size,
                .h = size,
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

fn renderCheckboxBox(allocator: std.mem.Allocator, batch: *draw.RenderBatch, bounds: draw.Rect, background: draw.Color, border: draw.Color) !void {
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

fn defaultCheckboxBounds(comptime config: CheckboxConfig) draw.Rect {
    const label_w = if (config.label.len > 0) config.label_gap + approximateWidth(config.label.len, config.font_size) else 0.0;
    return .{ .x = config.x, .y = config.y, .w = config.size + label_w, .h = config.size };
}

fn defaultToggleBounds(comptime config: ToggleConfig) draw.Rect {
    const label_w = if (config.label.len > 0) config.label_gap + approximateWidth(config.label.len, config.font_size) else 0.0;
    return .{ .x = config.x, .y = config.y, .w = config.width + label_w, .h = config.height };
}

const CheckboxProbe = struct {
    changed: usize = 0,
    last_checked: bool = false,
    focus_changed: usize = 0,
};

fn probeCheckboxEvent(context: ?*anyopaque, event: CheckboxEvent) void {
    const probe: *CheckboxProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => |checked| {
            probe.changed += 1;
            probe.last_checked = checked;
        },
        .focus_changed => probe.focus_changed += 1,
    }
}

test "checkbox toggles and emits changed on mouse release" {
    const Field = Checkbox(.{ .x = 10, .y = 10, .size = 20, .label = "Ready" });
    var checkbox = Field.init(false);
    var probe: CheckboxProbe = .{};
    checkbox.setCallbacks(.{ .context = &probe, .on_event = probeCheckboxEvent });

    try std.testing.expect(checkbox.handleInput(.{ .mouse_down = .{ .x = 12, .y = 12 } }));
    try std.testing.expect(checkbox.handleInput(.{ .mouse_up = .{ .x = 12, .y = 12 } }));

    try std.testing.expect(checkbox.checked);
    try std.testing.expect(probe.last_checked);
    try std.testing.expectEqual(@as(usize, 1), probe.changed);
}

test "checkbox keyboard enter toggles only when focused" {
    const Field = Checkbox(.{});
    var checkbox = Field.init(false);

    try std.testing.expect(!checkbox.handleInput(.{ .key = .{ .code = .enter } }));
    try std.testing.expect(checkbox.handleInput(.{ .focus = true }));
    try std.testing.expect(checkbox.handleInput(.{ .key = .{ .code = .enter } }));
    try std.testing.expect(checkbox.checked);
}

test "disabled checkbox suppresses changes" {
    const Field = Checkbox(.{ .disabled = true });
    var checkbox = Field.init(false);
    var probe: CheckboxProbe = .{};
    checkbox.setCallbacks(.{ .context = &probe, .on_event = probeCheckboxEvent });

    try std.testing.expect(checkbox.handleInput(.{ .mouse_down = .{ .x = 4, .y = 4 } }));
    try std.testing.expect(checkbox.handleInput(.{ .mouse_up = .{ .x = 4, .y = 4 } }));
    try std.testing.expect(!checkbox.checked);
    try std.testing.expectEqual(@as(usize, 0), probe.changed);
}

test "checked checkbox renders mark" {
    const Field = Checkbox(.{ .x = 0, .y = 0, .size = 20, .checked = true });
    var checkbox = Field.initDefault();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try checkbox.render(std.testing.allocator, &batch);

    try std.testing.expectEqual(@as(usize, 6), batch.commands.items.len);
    try std.testing.expectEqual(draw.CommandKind.rect, batch.commands.items[5].kind);
    try std.testing.expect(batch.commands.items[5].rect.w < 20.0);
}

test "toggle moves thumb when checked and supports space activation" {
    const Switch = Toggle(.{ .x = 0, .y = 0, .width = 40, .height = 20 });
    var toggle = Switch.init(false);
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try std.testing.expect(toggle.handleInput(.{ .focus = true }));
    try std.testing.expect(toggle.handleInput(.{ .activation_key = .space }));
    try std.testing.expect(toggle.checked);
    try toggle.render(std.testing.allocator, &batch);

    try std.testing.expectEqual(@as(usize, 6), batch.commands.items.len);
    try std.testing.expect(batch.commands.items[5].rect.x > 20.0);
}

test "checkbox and toggle support runtime bounds" {
    const Field = Checkbox(.{ .label = "Ready" });
    var checkbox = Field.init(false);
    checkbox.setBounds(.{ .x = 90, .y = 20, .w = 120, .h = 22 });
    try std.testing.expect(!checkbox.handleInput(.{ .mouse_down = .{ .x = 4, .y = 4 } }));
    try std.testing.expect(checkbox.handleInput(.{ .mouse_down = .{ .x = 94, .y = 24 } }));
    try std.testing.expect(checkbox.handleInput(.{ .mouse_up = .{ .x = 94, .y = 24 } }));
    try std.testing.expect(checkbox.checked);

    var checkbox_batch: draw.RenderBatch = .{};
    defer checkbox_batch.deinit(std.testing.allocator);
    try checkbox.render(std.testing.allocator, &checkbox_batch);
    try std.testing.expectEqual(draw.CommandKind.text, checkbox_batch.commands.items[6].kind);
    try std.testing.expectEqualStrings("Ready", checkbox_batch.commands.items[6].text);

    const Switch = Toggle(.{ .label = "Fast" });
    var toggle = Switch.init(false);
    toggle.setBounds(.{ .x = 220, .y = 20, .w = 110, .h = 24 });
    try std.testing.expect(toggle.handleInput(.{ .mouse_down = .{ .x = 224, .y = 24 } }));
    try std.testing.expect(toggle.handleInput(.{ .mouse_up = .{ .x = 224, .y = 24 } }));
    try std.testing.expect(toggle.checked);
    try std.testing.expectEqual(@as(f32, 220), toggle.trackRect().x);
}

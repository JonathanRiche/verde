//! Retained tab strip component.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const sdl = @import("../sdl.zig");

pub const TabsConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 320.0,
    height: f32 = 32.0,
    tab_width: f32 = 96.0,
    padding_x: f32 = 10.0,
    font_size: f32 = 14.0,
    background_color: draw.Color = .{ .r = 0.07, .g = 0.08, .b = 0.09, .a = 1.0 },
    tab_color: draw.Color = .{ .r = 0.12, .g = 0.14, .b = 0.17, .a = 1.0 },
    active_color: draw.Color = .{ .r = 0.18, .g = 0.22, .b = 0.27, .a = 1.0 },
    hovered_color: draw.Color = .{ .r = 0.16, .g = 0.19, .b = 0.23, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.28, .g = 0.32, .b = 0.38, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    tab_count: ?usize = null,
    tab_label: ?*const fn (context: ?*anyopaque, index: usize) []const u8 = null,
};

pub const Key = key_input;

pub const Input = union(enum) {
    key: Key,
    mouse_move: draw.Vec2,
    mouse_down: draw.Vec2,
    mouse_leave,
    tab_count: usize,
};

pub const TabsEvent = union(enum) {
    changed: usize,
    highlighted: ?usize,
};

pub const TabsCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: TabsEvent) void = null,
};

pub fn Tabs(comptime config: TabsConfig) type {
    return struct {
        const Component = @This();

        tab_count: usize = config.tab_count orelse 0,
        active_index: usize = 0,
        highlighted_index: ?usize = null,
        focused: bool = false,
        callbacks: TabsCallbacks = .{},

        pub fn init(tab_count: usize) Component {
            var self: Component = .{ .tab_count = tab_count };
            self.normalizeState();
            return self;
        }

        pub fn initFromConfig() Component {
            var self: Component = .{};
            self.normalizeState();
            return self;
        }

        pub fn setCallbacks(self: *Component, callbacks: TabsCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .key_down => return self.handleInput(.{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_motion => return self.handleInput(.{ .mouse_move = .{ .x = event.motion.x, .y = event.motion.y } }),
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            self.normalizeState();
            switch (input) {
                .key => |key| return self.handleKey(key),
                .mouse_move => |point| {
                    const index = Component.indexAtPoint(point, self.tab_count);
                    if (self.highlighted_index == index) return index != null;
                    self.highlighted_index = index;
                    self.emit(.{ .highlighted = index });
                    return index != null;
                },
                .mouse_down => |point| {
                    const index = Component.indexAtPoint(point, self.tab_count) orelse {
                        self.focused = false;
                        return false;
                    };
                    self.focused = true;
                    self.setActive(index);
                    return true;
                },
                .mouse_leave => {
                    const changed = self.highlighted_index != null;
                    self.highlighted_index = null;
                    if (changed) self.emit(.{ .highlighted = null });
                    return changed;
                },
                .tab_count => |count| {
                    self.tab_count = count;
                    self.normalizeState();
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.rect(allocator, Component.bounds(), config.background_color);
            var index: usize = 0;
            while (index < self.tab_count) : (index += 1) {
                const tab = Component.tabRect(index);
                const color = if (index == self.active_index)
                    config.active_color
                else if (self.highlighted_index == index)
                    config.hovered_color
                else
                    config.tab_color;
                try batch.rect(allocator, tab, color);
                try batch.rect(allocator, .{ .x = tab.x, .y = tab.y + tab.h - 1.0, .w = tab.w, .h = 1.0 }, config.border_color);
                try batch.glyph(allocator, Component.labelRect(index, self.callbacks.context), .{}, config.text_color);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (self.tab_count == 0) return false;
            switch (key.code) {
                .left, .up => self.setActive(if (self.active_index == 0) self.tab_count - 1 else self.active_index - 1),
                .right, .down => self.setActive((self.active_index + 1) % self.tab_count),
                .home => self.setActive(0),
                .end => self.setActive(self.tab_count - 1),
                else => return false,
            }
            self.focused = true;
            return true;
        }

        fn setActive(self: *Component, index: usize) void {
            if (index >= self.tab_count or self.active_index == index) return;
            self.active_index = index;
            self.emit(.{ .changed = index });
        }

        fn normalizeState(self: *Component) void {
            if (self.tab_count == 0) {
                self.active_index = 0;
                self.highlighted_index = null;
                return;
            }
            if (self.active_index >= self.tab_count) self.active_index = self.tab_count - 1;
            if (self.highlighted_index) |index| {
                if (index >= self.tab_count) self.highlighted_index = null;
            }
        }

        fn emit(self: *Component, event: TabsEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn tabRect(index: usize) draw.Rect {
            return .{
                .x = config.x + @as(f32, @floatFromInt(index)) * config.tab_width,
                .y = config.y,
                .w = @min(config.tab_width, @max(config.width - @as(f32, @floatFromInt(index)) * config.tab_width, 0.0)),
                .h = config.height,
            };
        }

        fn labelRect(index: usize, context: ?*anyopaque) draw.Rect {
            const label_len = if (config.tab_label) |label| label(context, index).len else digitCount(index + 1);
            const tab = Component.tabRect(index);
            return .{
                .x = tab.x + config.padding_x,
                .y = tab.y,
                .w = @min(@as(f32, @floatFromInt(label_len)) * config.font_size * 0.55, @max(tab.w - config.padding_x * 2.0, 0.0)),
                .h = tab.h,
            };
        }

        fn indexAtPoint(point: draw.Vec2, tab_count: usize) ?usize {
            if (!Component.bounds().contains(point) or tab_count == 0) return null;
            const index: usize = @intFromFloat(@floor((point.x - config.x) / config.tab_width));
            if (index >= tab_count) return null;
            if (Component.tabRect(index).w <= 0.0) return null;
            return index;
        }
    };
}

fn digitCount(value: usize) usize {
    var remaining = value;
    var count: usize = 1;
    while (remaining >= 10) : (remaining /= 10) count += 1;
    return count;
}

const TabsProbe = struct {
    changed: usize = 0,
    highlighted: usize = 0,
};

fn probeTabsEvent(context: ?*anyopaque, event: TabsEvent) void {
    const probe: *TabsProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => probe.changed += 1,
        .highlighted => probe.highlighted += 1,
    }
}

test "tabs activate with mouse and keyboard" {
    const Strip = Tabs(.{ .x = 0, .y = 0, .width = 300, .height = 30, .tab_width = 100 });
    var tabs = Strip.init(3);
    var probe: TabsProbe = .{};
    tabs.setCallbacks(.{ .context = &probe, .on_event = probeTabsEvent });

    try std.testing.expect(tabs.handleInput(.{ .mouse_down = .{ .x = 120, .y = 10 } }));
    try std.testing.expectEqual(@as(usize, 1), tabs.active_index);
    try std.testing.expectEqual(@as(usize, 1), probe.changed);

    try std.testing.expect(tabs.handleInput(.{ .key = .{ .code = .right } }));
    try std.testing.expectEqual(@as(usize, 2), tabs.active_index);
}

test "tabs keyboard navigation works without prior focus" {
    const Strip = Tabs(.{ .x = 0, .y = 0, .width = 300, .height = 30, .tab_width = 100 });
    var tabs = Strip.init(3);

    try std.testing.expect(tabs.handleInput(.{ .key = .{ .code = .left } }));
    try std.testing.expectEqual(@as(usize, 2), tabs.active_index);

    try std.testing.expect(tabs.handleInput(.{ .key = .{ .code = .home } }));
    try std.testing.expectEqual(@as(usize, 0), tabs.active_index);
}

test "tabs render one label placeholder per tab" {
    const Strip = Tabs(.{ .x = 0, .y = 0, .width = 200, .height = 30, .tab_width = 100 });
    var tabs = Strip.init(2);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try tabs.render(std.testing.allocator, &batch);

    var labels: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .image) labels += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), labels);
}

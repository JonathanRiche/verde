//! Retained clipped scroll area with optional scrollbar commands.

const Self = @This();
const std = @import("std");

const draw = @import("../draw.zig");
const scroll = @import("../scroll.zig");
const sdl = @import("../sdl.zig");

pub const ScrollAreaConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 320.0,
    height: f32 = 240.0,
    content_height: f32 = 240.0,
    background_color: draw.Color = draw.Color.transparent,
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    wheel_rows: f32 = 3.0,
    line_height: f32 = 20.0,
    scroll_enabled: bool = true,
};

pub const Input = union(enum) {
    mouse_down: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
};

pub const MouseWheel = struct {
    point: draw.Vec2,
    y: f32,
};

pub const ScrollAreaEvent = union(enum) {
    scrolled: f32,
};

pub const ScrollAreaCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: ScrollAreaEvent) void = null,
};

pub fn ScrollArea(comptime config: ScrollAreaConfig) type {
    return struct {
        const Component = @This();

        state: scroll = .{},
        content_height: f32 = config.content_height,
        callbacks: ScrollAreaCallbacks = .{},

        pub fn init() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: ScrollAreaCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn bounds(_: *const Component) draw.Rect {
            return Component.boundsRect();
        }

        pub fn viewport(_: *const Component) draw.Rect {
            return Component.boundsRect();
        }

        pub fn scrollY(self: *const Component) f32 {
            return self.state.offset_y;
        }

        pub fn setScrollY(self: *Component, value: f32) void {
            const before = self.state.offset_y;
            self.state.setOffsetY(value, self.metrics());
            if (self.state.offset_y != before) self.emit(.{ .scrolled = self.state.offset_y });
        }

        pub fn scrollBy(self: *Component, delta_y: f32) void {
            self.setScrollY(self.state.offset_y + delta_y);
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_button_up => return self.handleInput(.{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_motion => {
                    if (!self.state.dragging_scrollbar or !event.motion.state.left) return false;
                    return self.handleInput(.{ .mouse_drag = .{ .x = event.motion.x, .y = event.motion.y } });
                },
                .mouse_wheel => return self.handleInput(.{ .mouse_wheel = .{ .point = .{ .x = event.wheel.mouse_x, .y = event.wheel.mouse_y }, .y = event.wheel.y } }),
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .mouse_down => |point| {
                    if (!Component.boundsRect().contains(point)) return false;
                    if (self.scrollbarThumbRect()) |thumb| {
                        if (thumb.contains(point)) {
                            self.state.dragging_scrollbar = true;
                            self.state.scrollbar_drag_offset_y = point.y - thumb.y;
                            return true;
                        }
                    }
                    return false;
                },
                .mouse_drag => |point| {
                    if (!self.state.dragging_scrollbar) return false;
                    const track = Component.scrollbarTrackRect();
                    const thumb = self.scrollbarThumbRect() orelse return false;
                    self.setScrollY(scroll.offsetForThumbY(point.y, self.state.scrollbar_drag_offset_y, track, thumb, self.metrics()));
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.state.dragging_scrollbar;
                    self.state.dragging_scrollbar = false;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!Component.boundsRect().contains(wheel.point)) return false;
                    self.scrollBy(-wheel.y * config.line_height * config.wheel_rows);
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (config.background_color.a > 0.0) {
                try batch.rect(allocator, Component.boundsRect(), config.background_color);
            }
            try self.renderScrollbar(allocator, batch);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (self.maxScrollY() <= 0.0 or config.scrollbar_width <= 0.0) return;
            const track = Component.scrollbarTrackRect();
            try batch.scrollbar(allocator, track, config.scrollbar_track_color);
            const thumb = self.scrollbarThumbRect() orelse return;
            try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            return scroll.thumbRect(Component.scrollbarTrackRect(), self.metrics(), self.state.offset_y);
        }

        fn maxScrollY(self: *const Component) f32 {
            return scroll.maxOffsetY(self.metrics());
        }

        fn metrics(self: *const Component) scroll.Metrics {
            return .{
                .enabled = config.scroll_enabled,
                .content_height = self.content_height,
                .visible_height = config.height,
                .line_height = config.line_height,
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn emit(self: *Component, event: ScrollAreaEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn boundsRect() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn scrollbarTrackRect() draw.Rect {
            const track_w = @min(config.scrollbar_width, config.width);
            return .{ .x = config.x + config.width - track_w, .y = config.y, .w = track_w, .h = config.height };
        }
    };
}

test "scroll area clamps and emits scroll state" {
    const Area = ScrollArea(.{ .height = 100, .content_height = 250 });
    var area = Area.init();

    area.setScrollY(999);
    try std.testing.expectEqual(@as(f32, 150), area.scrollY());
    area.setScrollY(-20);
    try std.testing.expectEqual(@as(f32, 0), area.scrollY());
}

test "scroll area handles wheel and renders scrollbar on overflow" {
    const Area = ScrollArea(.{ .x = 0, .y = 0, .width = 100, .height = 50, .content_height = 150, .line_height = 10, .scrollbar_width = 5 });
    var area = Area.init();

    try std.testing.expect(area.handleInput(.{ .mouse_wheel = .{ .point = .{ .x = 10, .y = 10 }, .y = -1 } }));
    try std.testing.expect(area.scrollY() > 0);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try area.render(std.testing.allocator, &batch);

    var scrollbar_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .scrollbar) scrollbar_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), scrollbar_count);
}

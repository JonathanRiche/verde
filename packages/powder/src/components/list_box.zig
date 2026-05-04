//! Retained list box selection component.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const scroll = @import("../scroll.zig");
const sdl = @import("../sdl.zig");

pub const ListBoxConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 240.0,
    height: f32 = 160.0,
    padding_x: f32 = 8.0,
    padding_y: f32 = 6.0,
    row_height: f32 = 24.0,
    glyph_width: f32 = 8.0,
    background_color: draw.Color = .{ .r = 0.07, .g = 0.08, .b = 0.09, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.20, .g = 0.23, .b = 0.27, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    selected_color: draw.Color = .{ .r = 0.16, .g = 0.36, .b = 0.58, .a = 0.88 },
    highlighted_color: draw.Color = .{ .r = 0.32, .g = 0.36, .b = 0.42, .a = 0.62 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    scroll_enabled: bool = true,
    item_count: ?usize = null,
    item_label: ?*const fn (context: ?*anyopaque, index: usize) []const u8 = null,
};

pub const Key = key_input;

pub const MouseButton = struct {
    point: draw.Vec2,
};

pub const MouseWheel = struct {
    point: draw.Vec2,
    y: f32,
};

pub const Input = union(enum) {
    key: Key,
    mouse_down: MouseButton,
    mouse_move: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
    item_count: usize,
};

pub const ListBoxEvent = union(enum) {
    changed: ?usize,
    highlighted: ?usize,
};

pub const ListBoxCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: ListBoxEvent) void = null,
};

pub fn ListBox(comptime config: ListBoxConfig) type {
    return struct {
        const Component = @This();

        item_count: usize = config.item_count orelse 0,
        highlighted_index: ?usize = null,
        selected_index: ?usize = null,
        scroll_y: f32 = 0.0,
        focused: bool = false,
        dragging_scrollbar: bool = false,
        scrollbar_drag_offset_y: f32 = 0.0,
        callbacks: ListBoxCallbacks = .{},

        pub fn init(item_count: usize) Component {
            var self: Component = .{ .item_count = item_count };
            self.normalizeState();
            return self;
        }

        pub fn initFromConfig() Component {
            var self: Component = .{};
            self.normalizeState();
            return self;
        }

        pub fn setCallbacks(self: *Component, callbacks: ListBoxCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn scrollY(self: *const Component) f32 {
            return self.scroll_y;
        }

        pub fn setScrollY(self: *Component, value: f32) void {
            self.scroll_y = scroll.clampOffsetY(value, self.scrollMetrics());
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .key_down => return self.handleInput(.{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .point = .{ .x = event.button.x, .y = event.button.y } } }),
                .mouse_button_up => return self.handleInput(.{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_motion => {
                    if (self.dragging_scrollbar or event.motion.state.left) {
                        return self.handleInput(.{ .mouse_drag = .{ .x = event.motion.x, .y = event.motion.y } });
                    }
                    return self.handleInput(.{ .mouse_move = .{ .x = event.motion.x, .y = event.motion.y } });
                },
                .mouse_wheel => return self.handleInput(.{ .mouse_wheel = .{ .point = .{ .x = event.wheel.mouse_x, .y = event.wheel.mouse_y }, .y = event.wheel.y } }),
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            self.normalizeState();
            switch (input) {
                .key => |key| return self.handleKey(key),
                .mouse_down => |mouse| {
                    self.focused = Component.bounds().contains(mouse.point);
                    if (!self.focused) return false;

                    if (self.scrollbarThumbRect()) |thumb| {
                        if (thumb.contains(mouse.point)) {
                            self.dragging_scrollbar = true;
                            self.scrollbar_drag_offset_y = mouse.point.y - thumb.y;
                            return true;
                        }
                    }

                    const index = self.indexAtPoint(mouse.point) orelse return true;
                    self.setHighlighted(index);
                    self.select(index);
                    return true;
                },
                .mouse_move => |point| {
                    if (!Component.bounds().contains(point)) return false;
                    if (self.indexAtPoint(point)) |index| self.setHighlighted(index);
                    return true;
                },
                .mouse_drag => |point| {
                    if (self.dragging_scrollbar) {
                        self.dragScrollbarTo(point.y);
                        return true;
                    }
                    if (!self.focused) return false;
                    if (self.indexAtPoint(point)) |index| self.setHighlighted(index);
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_scrollbar;
                    self.dragging_scrollbar = false;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!Component.bounds().contains(wheel.point)) return false;
                    self.scrollBy(-wheel.y * config.row_height * 3.0);
                    return true;
                },
                .item_count => |count| {
                    self.item_count = count;
                    self.normalizeState();
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.rect(allocator, Component.bounds(), config.background_color);
            try batch.rect(allocator, .{ .x = config.x, .y = config.y, .w = config.width, .h = 1.0 }, config.border_color);

            const visible = self.visibleRange();
            var index = visible.start;
            while (index < visible.end) : (index += 1) {
                const row = self.rowRect(index);
                if (self.selected_index == index) {
                    try batch.selection(allocator, row, config.selected_color);
                } else if (self.highlighted_index == index) {
                    try batch.rect(allocator, row, config.highlighted_color);
                }

                const text_rect = self.itemGlyphRect(index, row);
                if (clippedRect(text_rect, Component.contentRect())) |clipped| {
                    try batch.glyph(allocator, clipped, .{}, config.text_color);
                }
            }

            try self.renderScrollbar(allocator, batch);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (self.item_count == 0) return false;
            switch (key.code) {
                .up => self.moveHighlight(-1),
                .down => self.moveHighlight(1),
                .home => self.setHighlighted(0),
                .end => self.setHighlighted(self.item_count - 1),
                .enter => {
                    const index = self.highlighted_index orelse self.selected_index orelse 0;
                    self.setHighlighted(index);
                    self.select(index);
                },
                else => return false,
            }
            return true;
        }

        fn moveHighlight(self: *Component, delta: i32) void {
            const current = self.highlighted_index orelse self.selected_index orelse if (delta < 0) self.item_count - 1 else 0;
            const next = if (delta < 0)
                if (current == 0) 0 else current - 1
            else
                @min(current + 1, self.item_count - 1);
            self.setHighlighted(next);
        }

        fn select(self: *Component, index: usize) void {
            if (index >= self.item_count) return;
            if (self.selected_index == index) return;
            self.selected_index = index;
            self.ensureIndexVisible(index);
            self.emit(.{ .changed = index });
        }

        fn setHighlighted(self: *Component, index: usize) void {
            if (index >= self.item_count) return;
            if (self.highlighted_index == index) return;
            self.highlighted_index = index;
            self.ensureIndexVisible(index);
            self.emit(.{ .highlighted = index });
        }

        fn normalizeState(self: *Component) void {
            if (self.selected_index) |index| {
                if (index >= self.item_count) self.selected_index = null;
            }
            if (self.highlighted_index) |index| {
                if (index >= self.item_count) self.highlighted_index = null;
            }
            self.setScrollY(self.scroll_y);
        }

        fn scrollBy(self: *Component, delta_y: f32) void {
            self.setScrollY(self.scroll_y + delta_y);
        }

        fn dragScrollbarTo(self: *Component, y: f32) void {
            const track = Component.scrollbarTrackRect();
            const thumb = self.scrollbarThumbRect() orelse return;
            self.setScrollY(scroll.offsetForThumbY(y, self.scrollbar_drag_offset_y, track, thumb, self.scrollMetrics()));
        }

        fn ensureIndexVisible(self: *Component, index: usize) void {
            if (!config.scroll_enabled) {
                self.scroll_y = 0.0;
                return;
            }
            const row_top = @as(f32, @floatFromInt(index)) * config.row_height;
            const row_bottom = row_top + config.row_height;
            const visible_height = Component.visibleHeight();
            if (row_top < self.scroll_y) {
                self.scroll_y = row_top;
            } else if (row_bottom > self.scroll_y + visible_height) {
                self.scroll_y = row_bottom - visible_height;
            }
            self.setScrollY(self.scroll_y);
        }

        fn indexAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            if (!Component.contentRect().contains(point)) return null;
            const row_offset = @max(point.y - config.y - config.padding_y + self.scroll_y, 0.0) / config.row_height;
            const index: usize = @intFromFloat(@floor(row_offset));
            if (index >= self.item_count) return null;
            return index;
        }

        fn visibleRange(self: *const Component) struct { start: usize, end: usize } {
            const start: usize = @min(@as(usize, @intFromFloat(@floor(self.scroll_y / config.row_height))), self.item_count);
            const visible_count = @as(usize, @intFromFloat(@ceil(Component.visibleHeight() / config.row_height))) + 1;
            return .{ .start = start, .end = @min(start + visible_count, self.item_count) };
        }

        fn rowRect(self: *const Component, index: usize) draw.Rect {
            return .{
                .x = config.x + config.padding_x,
                .y = config.y + config.padding_y + @as(f32, @floatFromInt(index)) * config.row_height - self.scroll_y,
                .w = @max(config.width - config.padding_x * 2.0 - Component.scrollbarGutter(), 0.0),
                .h = config.row_height,
            };
        }

        fn itemGlyphRect(self: *const Component, index: usize, row: draw.Rect) draw.Rect {
            const label_len = if (config.item_label) |label| label(self.callbacks.context, index).len else digitCount(index + 1);
            return .{
                .x = row.x,
                .y = row.y + @max((row.h - config.glyph_width * 1.4) * 0.5, 0.0),
                .w = @min(row.w, @as(f32, @floatFromInt(label_len)) * config.glyph_width),
                .h = @min(row.h, config.glyph_width * 1.4),
            };
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!config.scroll_enabled or scroll.maxOffsetY(self.scrollMetrics()) <= 0.0 or config.scrollbar_width <= 0.0) return;
            const track = Component.scrollbarTrackRect();
            try batch.scrollbar(allocator, track, config.scrollbar_track_color);
            if (self.scrollbarThumbRect()) |thumb| {
                try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
            }
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            return scroll.thumbRect(Component.scrollbarTrackRect(), self.scrollMetrics(), self.scroll_y);
        }

        fn scrollMetrics(self: *const Component) scroll.Metrics {
            return .{
                .enabled = config.scroll_enabled,
                .content_height = @as(f32, @floatFromInt(self.item_count)) * config.row_height,
                .visible_height = Component.visibleHeight(),
                .line_height = config.row_height,
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn contentRect() draw.Rect {
            return .{ .x = config.x + config.padding_x, .y = config.y + config.padding_y, .w = @max(config.width - config.padding_x * 2.0, 0.0), .h = Component.visibleHeight() };
        }

        fn visibleHeight() f32 {
            return @max(config.height - config.padding_y * 2.0, config.row_height);
        }

        fn scrollbarGutter() f32 {
            return if (config.scroll_enabled) @max(config.scrollbar_width, 0.0) else 0.0;
        }

        fn scrollbarTrackRect() draw.Rect {
            const content = Component.contentRect();
            const track_w = @min(config.scrollbar_width, content.w);
            return .{ .x = content.x + content.w - track_w, .y = content.y, .w = track_w, .h = content.h };
        }

        fn emit(self: *Component, event: ListBoxEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
        }
    };
}

fn digitCount(value: usize) usize {
    var remaining = value;
    var count: usize = 1;
    while (remaining >= 10) : (remaining /= 10) count += 1;
    return count;
}

fn clippedRect(rect: draw.Rect, clip: draw.Rect) ?draw.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

const ListProbe = struct {
    changed: usize = 0,
    highlighted: usize = 0,
    last_selected: ?usize = null,
    last_highlighted: ?usize = null,
};

fn probeListBoxEvent(context: ?*anyopaque, event: ListBoxEvent) void {
    const probe: *ListProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => |index| {
            probe.changed += 1;
            probe.last_selected = index;
        },
        .highlighted => |index| {
            probe.highlighted += 1;
            probe.last_highlighted = index;
        },
    }
}

test "list box selects rows and emits callbacks" {
    const Box = ListBox(.{ .x = 0, .y = 0, .width = 120, .height = 80, .padding_x = 0, .padding_y = 0, .row_height = 20 });
    var box = Box.init(4);
    var probe: ListProbe = .{};
    box.setCallbacks(.{ .context = &probe, .on_event = probeListBoxEvent });

    try std.testing.expect(box.handleInput(.{ .mouse_down = .{ .point = .{ .x = 5, .y = 45 } } }));
    try std.testing.expectEqual(@as(?usize, 2), box.highlighted_index);
    try std.testing.expectEqual(@as(?usize, 2), box.selected_index);
    try std.testing.expectEqual(@as(usize, 1), probe.changed);
    try std.testing.expectEqual(@as(usize, 1), probe.highlighted);
}

test "list box keyboard navigation keeps highlight visible" {
    const Box = ListBox(.{ .x = 0, .y = 0, .width = 120, .height = 40, .padding_x = 0, .padding_y = 0, .row_height = 20 });
    var box = Box.init(6);

    try std.testing.expect(box.handleInput(.{ .key = .{ .code = .end } }));
    try std.testing.expectEqual(@as(?usize, 5), box.highlighted_index);
    try std.testing.expect(box.scrollY() > 0.0);

    try std.testing.expect(box.handleInput(.{ .key = .{ .code = .enter } }));
    try std.testing.expectEqual(@as(?usize, 5), box.selected_index);
}

test "list box renders scrollbar for overflowing rows" {
    const Box = ListBox(.{ .x = 0, .y = 0, .width = 100, .height = 40, .padding_x = 0, .padding_y = 0, .row_height = 20, .scrollbar_width = 5 });
    var box = Box.init(5);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try box.render(std.testing.allocator, &batch);

    var scrollbar_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .scrollbar) scrollbar_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), scrollbar_count);
}

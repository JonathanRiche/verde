//! Retained virtualized scroll list with runtime bounds and variable row heights.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const scroll = @import("../scroll.zig");
const sdl = @import("../sdl.zig");
const text_layout = @import("../text_layout.zig");

pub const RowHeightFn = *const fn (context: ?*anyopaque, index: usize) f32;
pub const ItemLabelFn = *const fn (context: ?*anyopaque, index: usize) []const u8;

pub const VirtualListConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 320.0,
    height: f32 = 240.0,
    padding_x: f32 = 8.0,
    padding_y: f32 = 6.0,
    row_height: f32 = 28.0,
    row_gap: f32 = 0.0,
    font_size: f32 = 14.0,
    glyph_width: ?f32 = null,
    background_color: draw.Color = draw.Color.transparent,
    border_color: ?draw.Color = null,
    corner_radius: f32 = 0.0,
    border_width: f32 = 0.0,
    text_color: draw.Color = draw.Color.white,
    selected_color: draw.Color = .{ .r = 0.16, .g = 0.36, .b = 0.58, .a = 0.88 },
    highlighted_color: draw.Color = .{ .r = 0.32, .g = 0.36, .b = 0.42, .a = 0.62 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    scroll_enabled: bool = true,
    item_count: ?usize = null,
    item_label: ?ItemLabelFn = null,
    row_height_fn: ?RowHeightFn = null,
    z_index: i32 = 0,
};

pub const Key = key_input;

pub const MouseWheel = struct {
    point: draw.Vec2,
    y: f32,
};

pub const Input = union(enum) {
    key: Key,
    mouse_down: draw.Vec2,
    mouse_move: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
    item_count: usize,
};

pub const VirtualListEvent = union(enum) {
    selected: ?usize,
    highlighted: ?usize,
    scrolled: f32,
};

pub const VirtualListCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: VirtualListEvent) void = null,
};

pub fn VirtualList(comptime config: VirtualListConfig) type {
    return struct {
        const Component = @This();

        item_count: usize = config.item_count orelse 0,
        selected_index: ?usize = null,
        highlighted_index: ?usize = null,
        scroll_y: f32 = 0.0,
        dragging_scrollbar: bool = false,
        scrollbar_drag_offset_y: f32 = 0.0,
        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        z_index: i32 = config.z_index,
        callbacks: VirtualListCallbacks = .{},

        pub fn init(item_count: usize) Component {
            var self: Component = .{ .item_count = item_count };
            self.setScrollY(0);
            return self;
        }

        pub fn initFromConfig() Component {
            var self: Component = .{};
            self.setScrollY(0);
            return self;
        }

        pub fn setCallbacks(self: *Component, callbacks: VirtualListCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
            self.setScrollY(self.scroll_y);
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn viewport(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            return .{
                .x = bounds_rect.x + config.padding_x,
                .y = bounds_rect.y + config.padding_y,
                .w = @max(bounds_rect.w - config.padding_x * 2.0 - self.scrollbarGutter(), 0.0),
                .h = @max(bounds_rect.h - config.padding_y * 2.0, config.row_height),
            };
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        pub fn setItemCount(self: *Component, count: usize) void {
            self.item_count = count;
            if (self.selected_index) |index| {
                if (index >= count) self.selected_index = null;
            }
            if (self.highlighted_index) |index| {
                if (index >= count) self.highlighted_index = null;
            }
            self.setScrollY(self.scroll_y);
        }

        pub fn scrollY(self: *const Component) f32 {
            return self.scroll_y;
        }

        pub fn setScrollY(self: *Component, value: f32) void {
            const next = scroll.clampOffsetY(value, self.scrollMetrics());
            if (next == self.scroll_y) return;
            self.scroll_y = next;
            self.emit(.{ .scrolled = self.scroll_y });
        }

        pub fn contentHeight(self: *const Component) f32 {
            var total: f32 = 0.0;
            var index: usize = 0;
            while (index < self.item_count) : (index += 1) {
                total += self.rowHeight(index);
                if (index + 1 < self.item_count) total += config.row_gap;
            }
            return total;
        }

        pub fn rowRect(self: *const Component, index: usize) draw.Rect {
            const viewport_rect = self.viewport();
            return .{
                .x = viewport_rect.x,
                .y = viewport_rect.y + self.offsetForIndex(index) - self.scroll_y,
                .w = viewport_rect.w,
                .h = self.rowHeight(index),
            };
        }

        pub fn visibleRange(self: *const Component) struct { start: usize, end: usize } {
            var start: usize = 0;
            var y: f32 = 0.0;
            while (start < self.item_count and y + self.rowHeight(start) < self.scroll_y) : (start += 1) {
                y += self.rowHeight(start) + config.row_gap;
            }
            var end = start;
            while (end < self.item_count and y < self.scroll_y + self.viewport().h) : (end += 1) {
                y += self.rowHeight(end) + config.row_gap;
            }
            return .{ .start = start, .end = end };
        }

        pub fn indexAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            if (!self.viewport().contains(point)) return null;
            const target = point.y - self.viewport().y + self.scroll_y;
            var y: f32 = 0.0;
            var index: usize = 0;
            while (index < self.item_count) : (index += 1) {
                const h = self.rowHeight(index);
                if (target >= y and target < y + h) return index;
                y += h + config.row_gap;
            }
            return null;
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .key_down => return self.handleInput(.{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
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
            switch (input) {
                .key => |key| return self.handleKey(key),
                .mouse_down => |point| {
                    if (!self.bounds().contains(point)) return false;
                    if (self.scrollbarThumbRect()) |thumb| {
                        if (thumb.contains(point)) {
                            self.dragging_scrollbar = true;
                            self.scrollbar_drag_offset_y = point.y - thumb.y;
                            return true;
                        }
                    }
                    const index = self.indexAtPoint(point) orelse return true;
                    self.highlight(index);
                    self.select(index);
                    return true;
                },
                .mouse_move => |point| {
                    if (self.indexAtPoint(point)) |index| {
                        self.highlight(index);
                        return true;
                    }
                    return false;
                },
                .mouse_drag => |point| {
                    if (!self.dragging_scrollbar) return false;
                    const track = self.scrollbarTrackRect();
                    const thumb = self.scrollbarThumbRect() orelse return false;
                    self.setScrollY(scroll.offsetForThumbY(point.y, self.scrollbar_drag_offset_y, track, thumb, self.scrollMetrics()));
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_scrollbar;
                    self.dragging_scrollbar = false;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!self.bounds().contains(wheel.point)) return false;
                    self.setScrollY(self.scroll_y - wheel.y * config.row_height * 3.0);
                    return true;
                },
                .item_count => |count| {
                    self.setItemCount(count);
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            if (config.background_color.a > 0.0 or config.border_color != null) {
                try batch.panel(allocator, self.bounds(), config.background_color, config.border_color, config.corner_radius, config.border_width);
            }

            const visible = self.visibleRange();
            var index = visible.start;
            while (index < visible.end) : (index += 1) {
                const row = self.rowRect(index);
                if (clippedRect(row, self.viewport())) |clipped| {
                    if (self.selected_index == index) {
                        try batch.selection(allocator, clipped, config.selected_color);
                    } else if (self.highlighted_index == index) {
                        try batch.roundedRect(allocator, clipped, config.highlighted_color, @min(config.corner_radius, clipped.h * 0.5));
                    }
                    if (self.itemLabel(index)) |label| {
                        try self.renderLabel(allocator, batch, clipped, label);
                    }
                }
            }
            try self.renderScrollbar(allocator, batch);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (self.item_count == 0) return false;
            const current = self.highlighted_index orelse self.selected_index orelse 0;
            switch (key.code) {
                .up => self.highlight(if (current == 0) 0 else current - 1),
                .down => self.highlight(@min(current + 1, self.item_count - 1)),
                .home => self.highlight(0),
                .end => self.highlight(self.item_count - 1),
                .enter => if (self.highlighted_index) |index| self.select(index) else return false,
                else => return false,
            }
            if (self.highlighted_index) |index| self.ensureIndexVisible(index);
            return true;
        }

        fn highlight(self: *Component, index: usize) void {
            if (index >= self.item_count or self.highlighted_index == index) return;
            self.highlighted_index = index;
            self.emit(.{ .highlighted = index });
        }

        fn select(self: *Component, index: usize) void {
            if (index >= self.item_count or self.selected_index == index) return;
            self.selected_index = index;
            self.ensureIndexVisible(index);
            self.emit(.{ .selected = index });
        }

        fn ensureIndexVisible(self: *Component, index: usize) void {
            const top = self.offsetForIndex(index);
            const bottom = top + self.rowHeight(index);
            const viewport_h = self.viewport().h;
            if (top < self.scroll_y) {
                self.setScrollY(top);
            } else if (bottom > self.scroll_y + viewport_h) {
                self.setScrollY(bottom - viewport_h);
            }
        }

        fn rowHeight(self: *const Component, index: usize) f32 {
            if (config.row_height_fn) |callback| return @max(callback(self.callbacks.context, index), 1.0);
            return config.row_height;
        }

        fn offsetForIndex(self: *const Component, target: usize) f32 {
            var y: f32 = 0.0;
            var index: usize = 0;
            while (index < @min(target, self.item_count)) : (index += 1) {
                y += self.rowHeight(index) + config.row_gap;
            }
            return y;
        }

        fn itemLabel(self: *const Component, index: usize) ?[]const u8 {
            if (config.item_label) |callback| return callback(self.callbacks.context, index);
            return null;
        }

        fn renderLabel(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, row: draw.Rect, label: []const u8) !void {
            const metrics_value = self.metrics();
            const y = row.y + @max((row.h - metrics_value.line_height) * 0.5, 0.0);
            const text_rect: draw.Rect = .{ .x = row.x + config.padding_x, .y = y, .w = @max(row.w - config.padding_x * 2.0, 0.0), .h = metrics_value.line_height };
            const runs = [_]draw.TextRun{.{
                .text = label,
                .byte_start = 0,
                .byte_end = label.len,
                .x = text_rect.x,
                .y = text_rect.y,
                .font_size = metrics_value.font_size,
                .line_height = metrics_value.line_height,
                .color = config.text_color,
                .clip = self.viewport(),
            }};
            try batch.textRuns(allocator, text_rect, label, &runs, config.text_color, metrics_value.font_size, self.viewport(), metrics_value.line_height, metrics_value.fixedAdvance());
        }

        fn metrics(_: *const Component) text_layout.FontMetrics {
            return text_layout.FontMetrics.fixed(config.font_size, config.glyph_width orelse config.font_size * 0.55, config.row_height);
        }

        fn scrollMetrics(self: *const Component) scroll.Metrics {
            return .{
                .enabled = config.scroll_enabled,
                .content_height = self.contentHeight(),
                .visible_height = self.viewport().h,
                .line_height = config.row_height,
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn scrollbarGutter(_: *const Component) f32 {
            return if (config.scroll_enabled) @max(config.scrollbar_width, 0.0) else 0.0;
        }

        fn scrollbarTrackRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            const track_w = @min(config.scrollbar_width, bounds_rect.w);
            return .{ .x = bounds_rect.x + bounds_rect.w - track_w, .y = bounds_rect.y + config.padding_y, .w = track_w, .h = @max(bounds_rect.h - config.padding_y * 2.0, 0.0) };
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            return scroll.thumbRect(self.scrollbarTrackRect(), self.scrollMetrics(), self.scroll_y);
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!config.scroll_enabled or scroll.maxOffsetY(self.scrollMetrics()) <= 0.0 or config.scrollbar_width <= 0.0) return;
            try batch.scrollbar(allocator, self.scrollbarTrackRect(), config.scrollbar_track_color);
            if (self.scrollbarThumbRect()) |thumb| try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
        }

        fn emit(self: *Component, event: VirtualListEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }
    };
}

fn clippedRect(rect: draw.Rect, clip: draw.Rect) ?draw.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn testLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Alpha",
        1 => "Bravo",
        2 => "Charlie",
        3 => "Delta",
        else => "Echo",
    };
}

fn testHeight(_: ?*anyopaque, index: usize) f32 {
    return if (index == 1) 40 else 20;
}

test "virtual list computes visible variable-height rows and emits labels" {
    const List = VirtualList(.{ .width = 160, .height = 64, .padding_x = 0, .padding_y = 0, .row_height = 20, .row_height_fn = testHeight, .item_count = 5, .item_label = testLabel });
    var list = List.initFromConfig();

    try std.testing.expectEqual(@as(f32, 120), list.contentHeight());
    try std.testing.expectEqual(@as(?usize, 1), list.indexAtPoint(.{ .x = 4, .y = 25 }));
    list.setScrollY(30);
    const visible = list.visibleRange();
    try std.testing.expectEqual(@as(usize, 1), visible.start);
    try std.testing.expect(visible.end > visible.start);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try list.render(std.testing.allocator, &batch);
    var text_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .text) text_count += 1;
    }
    try std.testing.expect(text_count > 0);
}

test "virtual list handles wheel selection and scrollbar" {
    const List = VirtualList(.{ .width = 100, .height = 40, .padding_x = 0, .padding_y = 0, .row_height = 20, .item_count = 8 });
    var list = List.initFromConfig();

    try std.testing.expect(list.handleInput(.{ .mouse_wheel = .{ .point = .{ .x = 10, .y = 10 }, .y = -1 } }));
    try std.testing.expect(list.scrollY() > 0);
    try std.testing.expect(list.handleInput(.{ .mouse_down = .{ .x = 10, .y = 10 } }));
    try std.testing.expect(list.selected_index != null);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try list.render(std.testing.allocator, &batch);
    var scrollbar_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .scrollbar) scrollbar_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), scrollbar_count);
}

//! Retained select/dropdown component.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const scroll = @import("../scroll.zig");
const sdl = @import("../sdl.zig");
const text_layout = @import("../text_layout.zig");

pub const SelectConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 240.0,
    height: f32 = 32.0,
    menu_height: f32 = 160.0,
    padding_x: f32 = 8.0,
    padding_y: f32 = 6.0,
    row_height: f32 = 28.0,
    glyph_width: f32 = 8.0,
    background_color: draw.Color = .{ .r = 0.08, .g = 0.09, .b = 0.11, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.22, .g = 0.25, .b = 0.30, .a = 1.0 },
    menu_color: draw.Color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1.0 },
    corner_radius: f32 = 5.0,
    menu_corner_radius: f32 = 6.0,
    border_width: f32 = 1.0,
    text_color: draw.Color = draw.Color.white,
    selected_color: draw.Color = .{ .r = 0.16, .g = 0.36, .b = 0.58, .a = 0.88 },
    highlighted_color: draw.Color = .{ .r = 0.32, .g = 0.36, .b = 0.42, .a = 0.62 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    scroll_enabled: bool = true,
    z_index: i32 = 0,
    menu_z_offset: i32 = 1000,
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

pub const SelectEvent = union(enum) {
    changed: ?usize,
    highlighted: ?usize,
    open_changed: bool,
};

pub const SelectCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: SelectEvent) void = null,
};

pub fn Select(comptime config: SelectConfig) type {
    return struct {
        const Component = @This();

        item_count: usize = config.item_count orelse 0,
        selected_index: ?usize = null,
        highlighted_index: ?usize = null,
        open: bool = false,
        focused: bool = false,
        scroll_y: f32 = 0.0,
        dragging_scrollbar: bool = false,
        scrollbar_drag_offset_y: f32 = 0.0,
        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        menu_rect: draw.Rect = .{ .x = config.x, .y = config.y + config.height, .w = config.width, .h = config.menu_height },
        font_metrics: ?text_layout.FontMetrics = null,
        z_index: i32 = config.z_index,
        menu_z_offset: i32 = config.menu_z_offset,
        callbacks: SelectCallbacks = .{},

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

        pub fn setCallbacks(self: *Component, callbacks: SelectCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setFontMetrics(self: *Component, metrics_value: text_layout.FontMetrics) void {
            self.font_metrics = metrics_value;
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        pub fn setMenuZOffset(self: *Component, offset: i32) void {
            self.menu_z_offset = offset;
        }

        pub fn scrollY(self: *const Component) f32 {
            return self.scroll_y;
        }

        pub fn setScrollY(self: *Component, value: f32) void {
            self.scroll_y = scroll.clampOffsetY(value, self.scrollMetrics());
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            const old = self.rect;
            self.rect = rect;
            self.menu_rect = .{ .x = rect.x, .y = rect.y + rect.h, .w = rect.w, .h = self.menu_rect.h };
            if (old.w != rect.w or old.h != rect.h) self.setScrollY(self.scroll_y);
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn setMenuBounds(self: *Component, rect: draw.Rect) void {
            self.menu_rect = rect;
            self.setScrollY(self.scroll_y);
        }

        pub fn setItemCount(self: *Component, count: usize) void {
            self.item_count = count;
            self.normalizeState();
        }

        pub fn controlRect(self: *const Component) draw.Rect {
            return self.bounds();
        }

        pub fn menuRect(self: *const Component) draw.Rect {
            return self.menu_rect;
        }

        pub fn menuContentRect(self: *const Component) draw.Rect {
            const menu = self.menuRect();
            return .{
                .x = menu.x + config.padding_x,
                .y = menu.y + config.padding_y,
                .w = @max(menu.w - config.padding_x * 2.0, 0.0),
                .h = @max(menu.h - config.padding_y * 2.0, config.row_height),
            };
        }

        pub fn rowRect(self: *const Component, index: usize) draw.Rect {
            const content = self.menuContentRect();
            return .{
                .x = content.x,
                .y = content.y + @as(f32, @floatFromInt(index)) * config.row_height - self.scroll_y,
                .w = @max(content.w - self.scrollbarGutter(), 0.0),
                .h = config.row_height,
            };
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
                    if (self.controlRect().contains(mouse.point)) {
                        self.focused = true;
                        if (self.open) {
                            self.close();
                        } else {
                            self.openMenu();
                        }
                        return true;
                    }
                    if (!self.open) {
                        self.focused = false;
                        return false;
                    }

                    if (self.scrollbarThumbRect()) |thumb| {
                        if (thumb.contains(mouse.point)) {
                            self.dragging_scrollbar = true;
                            self.scrollbar_drag_offset_y = mouse.point.y - thumb.y;
                            return true;
                        }
                    }

                    if (self.indexAtPoint(mouse.point)) |index| {
                        self.setHighlighted(index);
                        self.select(index);
                        self.close();
                        return true;
                    }

                    if (!self.menuRect().contains(mouse.point)) {
                        self.close();
                        self.focused = false;
                        return true;
                    }
                    return true;
                },
                .mouse_move => |point| {
                    if (!self.open or !self.menuRect().contains(point)) return false;
                    if (self.indexAtPoint(point)) |index| self.setHighlighted(index);
                    return true;
                },
                .mouse_drag => |point| {
                    if (self.dragging_scrollbar) {
                        self.dragScrollbarTo(point.y);
                        return true;
                    }
                    if (!self.open or !self.menuRect().contains(point)) return false;
                    if (self.indexAtPoint(point)) |index| self.setHighlighted(index);
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_scrollbar;
                    self.dragging_scrollbar = false;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!self.open or !self.menuRect().contains(wheel.point)) return false;
                    self.scrollBy(-wheel.y * config.row_height * 3.0);
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

            const control = self.controlRect();
            try batch.panel(allocator, control, config.background_color, config.border_color, config.corner_radius, config.border_width);
            if (self.selected_index) |index| {
                if (self.itemLabel(index)) |label| {
                    const text_rect = self.controlTextRect(label);
                    try self.renderLabel(allocator, batch, text_rect, label, config.text_color, text_rect);
                }
            }

            if (!self.open) return;

            _ = batch.setZIndex(self.z_index + self.menu_z_offset);
            try batch.panel(allocator, self.menuRect(), config.menu_color, config.border_color, config.menu_corner_radius, config.border_width);
            const visible = self.visibleRange();
            var index = visible.start;
            while (index < visible.end) : (index += 1) {
                const row = self.rowRect(index);
                if (self.selected_index == index) {
                    try batch.selection(allocator, row, config.selected_color);
                } else if (self.highlighted_index == index) {
                    try batch.rect(allocator, row, config.highlighted_color);
                }
                if (self.itemLabel(index)) |label| {
                    const text_rect = self.itemTextRect(label, row);
                    if (clippedRect(text_rect, self.menuContentRect())) |clipped| {
                        try self.renderLabel(allocator, batch, clipped, label, config.text_color, self.menuContentRect());
                    }
                }
            }
            try self.renderScrollbar(allocator, batch);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (self.item_count == 0) return false;
            switch (key.code) {
                .down => {
                    if (!self.open) self.openMenu();
                    self.moveHighlight(1);
                },
                .up => {
                    if (!self.open) self.openMenu();
                    self.moveHighlight(-1);
                },
                .home => {
                    if (!self.open) self.openMenu();
                    self.setHighlighted(0);
                },
                .end => {
                    if (!self.open) self.openMenu();
                    self.setHighlighted(self.item_count - 1);
                },
                .enter => {
                    if (!self.open) {
                        self.openMenu();
                    } else {
                        const index = self.highlighted_index orelse self.selected_index orelse 0;
                        self.setHighlighted(index);
                        self.select(index);
                        self.close();
                    }
                },
                else => return false,
            }
            self.focused = true;
            return true;
        }

        fn openMenu(self: *Component) void {
            if (!self.open) {
                self.open = true;
                self.emit(.{ .open_changed = true });
            }
            const index = self.selected_index orelse self.highlighted_index orelse 0;
            self.setHighlighted(index);
        }

        fn close(self: *Component) void {
            if (!self.open) return;
            self.open = false;
            self.dragging_scrollbar = false;
            self.emit(.{ .open_changed = false });
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
            if (self.item_count == 0) self.open = false;
            self.setScrollY(self.scroll_y);
        }

        fn scrollBy(self: *Component, delta_y: f32) void {
            self.setScrollY(self.scroll_y + delta_y);
        }

        fn dragScrollbarTo(self: *Component, y: f32) void {
            const track = self.scrollbarTrackRect();
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
            const visible_height = self.menuContentRect().h;
            if (row_top < self.scroll_y) {
                self.scroll_y = row_top;
            } else if (row_bottom > self.scroll_y + visible_height) {
                self.scroll_y = row_bottom - visible_height;
            }
            self.setScrollY(self.scroll_y);
        }

        fn indexAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            if (!self.menuContentRect().contains(point)) return null;
            const row_offset = @max(point.y - self.menuContentRect().y + self.scroll_y, 0.0) / config.row_height;
            const index: usize = @intFromFloat(@floor(row_offset));
            if (index >= self.item_count) return null;
            return index;
        }

        fn visibleRange(self: *const Component) struct { start: usize, end: usize } {
            const start: usize = @min(@as(usize, @intFromFloat(@floor(self.scroll_y / config.row_height))), self.item_count);
            const visible_count = @as(usize, @intFromFloat(@ceil(self.menuContentRect().h / config.row_height))) + 1;
            return .{ .start = start, .end = @min(start + visible_count, self.item_count) };
        }

        fn controlTextRect(self: *const Component, label: []const u8) draw.Rect {
            const control = self.controlRect();
            const metrics_value = self.metrics();
            const text_h = @min(control.h, metrics_value.line_height);
            return .{
                .x = control.x + config.padding_x,
                .y = control.y + @max((control.h - text_h) * 0.5, 0.0),
                .w = @min(control.w - config.padding_x * 2.0, metrics_value.measureSlice(label)),
                .h = text_h,
            };
        }

        fn itemTextRect(self: *const Component, label: []const u8, row: draw.Rect) draw.Rect {
            const metrics_value = self.metrics();
            const text_h = @min(row.h, metrics_value.line_height);
            return .{
                .x = row.x,
                .y = row.y + @max((row.h - text_h) * 0.5, 0.0),
                .w = @min(row.w, metrics_value.measureSlice(label)),
                .h = text_h,
            };
        }

        fn itemLabel(self: *const Component, index: usize) ?[]const u8 {
            if (config.item_label) |label| return label(self.callbacks.context, index);
            return null;
        }

        fn renderLabel(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, rect: draw.Rect, label: []const u8, color: draw.Color, clip: draw.Rect) !void {
            const metrics_value = self.metrics();
            const runs = [_]draw.TextRun{.{
                .text = label,
                .byte_start = 0,
                .byte_end = label.len,
                .x = rect.x,
                .y = rect.y,
                .font_size = metrics_value.font_size,
                .line_height = metrics_value.line_height,
                .color = color,
                .clip = clip,
            }};
            try batch.textRuns(allocator, rect, label, &runs, color, metrics_value.font_size, clip, metrics_value.line_height, metrics_value.fixedAdvance());
        }

        fn metrics(self: *const Component) text_layout.FontMetrics {
            if (self.font_metrics) |metrics_value| return metrics_value;
            return text_layout.FontMetrics.fixed(config.glyph_width / 0.55, config.glyph_width, config.row_height);
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!config.scroll_enabled or scroll.maxOffsetY(self.scrollMetrics()) <= 0.0 or config.scrollbar_width <= 0.0) return;
            const track = self.scrollbarTrackRect();
            try batch.scrollbar(allocator, track, config.scrollbar_track_color);
            if (self.scrollbarThumbRect()) |thumb| {
                try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
            }
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            return scroll.thumbRect(self.scrollbarTrackRect(), self.scrollMetrics(), self.scroll_y);
        }

        fn scrollMetrics(self: *const Component) scroll.Metrics {
            return .{
                .enabled = config.scroll_enabled,
                .content_height = @as(f32, @floatFromInt(self.item_count)) * config.row_height,
                .visible_height = self.menuContentRect().h,
                .line_height = config.row_height,
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn scrollbarGutter(_: *const Component) f32 {
            return if (config.scroll_enabled) @max(config.scrollbar_width, 0.0) else 0.0;
        }

        fn scrollbarTrackRect(self: *const Component) draw.Rect {
            const content = self.menuContentRect();
            const track_w = @min(config.scrollbar_width, content.w);
            return .{ .x = content.x + content.w - track_w, .y = content.y, .w = track_w, .h = content.h };
        }

        fn emit(self: *Component, event: SelectEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
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

const SelectProbe = struct {
    changed: usize = 0,
    highlighted: usize = 0,
    open_changes: usize = 0,
    last_selected: ?usize = null,
};

fn probeSelectEvent(context: ?*anyopaque, event: SelectEvent) void {
    const probe: *SelectProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => |index| {
            probe.changed += 1;
            probe.last_selected = index;
        },
        .highlighted => probe.highlighted += 1,
        .open_changed => probe.open_changes += 1,
    }
}

fn testItemLabel(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Alpha",
        1 => "Bravo",
        2 => "Charlie",
        else => "Delta",
    };
}

test "select opens and chooses an item with mouse" {
    const Dropdown = Select(.{ .x = 0, .y = 0, .width = 140, .height = 30, .menu_height = 90, .padding_x = 0, .padding_y = 0, .row_height = 30 });
    var select = Dropdown.init(3);
    var probe: SelectProbe = .{};
    select.setCallbacks(.{ .context = &probe, .on_event = probeSelectEvent });

    try std.testing.expect(select.handleInput(.{ .mouse_down = .{ .point = .{ .x = 10, .y = 10 } } }));
    try std.testing.expect(select.open);

    try std.testing.expect(select.handleInput(.{ .mouse_down = .{ .point = .{ .x = 10, .y = 75 } } }));
    try std.testing.expect(!select.open);
    try std.testing.expectEqual(@as(?usize, 1), select.selected_index);
    try std.testing.expectEqual(@as(usize, 1), probe.changed);
    try std.testing.expectEqual(@as(usize, 2), probe.open_changes);
}

test "select keyboard navigation opens highlights and commits" {
    const Dropdown = Select(.{ .x = 0, .y = 0, .width = 140, .height = 30, .menu_height = 60, .padding_x = 0, .padding_y = 0, .row_height = 30 });
    var select = Dropdown.init(4);

    try std.testing.expect(select.handleInput(.{ .key = .{ .code = .down } }));
    try std.testing.expect(select.open);
    try std.testing.expectEqual(@as(?usize, 1), select.highlighted_index);

    try std.testing.expect(select.handleInput(.{ .key = .{ .code = .enter } }));
    try std.testing.expect(!select.open);
    try std.testing.expectEqual(@as(?usize, 1), select.selected_index);
}

test "select renders menu scrollbar when open and overflowing" {
    const Dropdown = Select(.{ .x = 0, .y = 0, .width = 100, .height = 30, .menu_height = 50, .padding_x = 0, .padding_y = 0, .row_height = 20, .scrollbar_width = 5 });
    var select = Dropdown.init(5);
    _ = select.handleInput(.{ .key = .{ .code = .enter } });

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try select.render(std.testing.allocator, &batch);

    var scrollbar_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .scrollbar) scrollbar_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), scrollbar_count);
}

test "select menu renders above later normal z commands" {
    const Dropdown = Select(.{ .x = 0, .y = 0, .width = 100, .height = 30, .menu_height = 50, .padding_x = 0, .padding_y = 0, .row_height = 20 });
    var select = Dropdown.init(2);
    _ = select.handleInput(.{ .key = .{ .code = .enter } });

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try select.render(std.testing.allocator, &batch);
    try batch.rect(std.testing.allocator, .{ .x = 999, .w = 10, .h = 10 }, draw.Color.white);

    try std.testing.expect(batch.commands.items[batch.commands.items.len - 1].z_index > 0);
    try std.testing.expect(batch.commands.items[batch.commands.items.len - 1].rect.x != 999);
    for (batch.commands.items) |command| {
        if (command.rect.x == 999) try std.testing.expectEqual(@as(i32, 0), command.z_index);
    }
}

test "select supports runtime bounds menu bounds item count and text labels" {
    const Dropdown = Select(.{ .item_label = testItemLabel, .padding_x = 4, .padding_y = 2, .row_height = 20, .glyph_width = 8 });
    var select = Dropdown.initFromConfig();
    select.setBounds(.{ .x = 40, .y = 30, .w = 120, .h = 28 });
    select.setMenuBounds(.{ .x = 44, .y = 62, .w = 140, .h = 70 });
    select.setItemCount(3);

    try std.testing.expect(select.handleInput(.{ .mouse_down = .{ .point = .{ .x = 50, .y = 40 } } }));
    try std.testing.expect(select.open);
    try std.testing.expectEqual(@as(f32, 44), select.menuRect().x);
    try std.testing.expectEqual(@as(f32, 48), select.rowRect(0).x);

    try std.testing.expect(select.handleInput(.{ .mouse_down = .{ .point = .{ .x = 52, .y = 88 } } }));
    try std.testing.expectEqual(@as(?usize, 1), select.selected_index);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try select.render(std.testing.allocator, &batch);
    var found_label = false;
    for (batch.commands.items) |command| {
        if (command.kind == .text and std.mem.eql(u8, command.text, "Bravo")) {
            found_label = true;
            try std.testing.expectEqual(@as(f32, 44), command.clip.?.x);
        }
    }
    try std.testing.expect(found_label);
}

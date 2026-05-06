//! Retained nested popup menu component.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const scroll = @import("../scroll.zig");
const sdl = @import("../sdl.zig");
const text_layout = @import("../text_layout.zig");

pub const ItemLabelFn = *const fn (context: ?*anyopaque, path: []const usize, index: usize) []const u8;
pub const ChildCountFn = *const fn (context: ?*anyopaque, path: []const usize, index: usize) usize;

pub const CascadeMenuConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 220.0,
    row_height: f32 = 28.0,
    max_visible_rows: usize = 8,
    max_depth: usize = 4,
    padding_x: f32 = 8.0,
    padding_y: f32 = 6.0,
    submenu_gap: f32 = 4.0,
    glyph_width: f32 = 8.8,
    font_size: f32 = 16.0,
    chevron_icon: []const u8 = ">",
    icon_gap: f32 = 8.0,
    font_role: ?draw.FontRole = .ui,
    icon_font_role: ?draw.FontRole = .icon,
    font_id: ?u32 = null,
    icon_font_id: ?u32 = null,
    background_color: draw.Color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.22, .g = 0.25, .b = 0.30, .a = 1.0 },
    highlighted_color: draw.Color = .{ .r = 0.20, .g = 0.24, .b = 0.29, .a = 0.86 },
    text_color: draw.Color = draw.Color.white,
    icon_color: draw.Color = .{ .r = 0.72, .g = 0.78, .b = 0.88, .a = 1.0 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    corner_radius: f32 = 6.0,
    border_width: f32 = 1.0,
    z_index: i32 = 0,
    submenu_z_offset: i32 = 100,
    scroll_enabled: bool = true,
    item_count: ?usize = null,
    item_label: ?ItemLabelFn = null,
    child_count: ?ChildCountFn = null,
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
    open,
    close,
    item_count: usize,
    key: Key,
    mouse_down: MouseButton,
    mouse_move: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
};

pub const CascadeMenuEvent = union(enum) {
    selected: Selection,
    highlighted: Highlight,
    open_changed: bool,

    pub const Selection = struct {
        path: []const usize,
        index: usize,
    };

    pub const Highlight = struct {
        path: []const usize,
        index: usize,
    };
};

pub const CascadeMenuCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: CascadeMenuEvent) void = null,
};

pub fn CascadeMenu(comptime config: CascadeMenuConfig) type {
    if (config.max_depth == 0) @compileError("CascadeMenuConfig.max_depth must be greater than zero");

    return struct {
        const Component = @This();
        const DepthArray = [config.max_depth]?usize;
        const ScrollArray = [config.max_depth]f32;

        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = defaultMenuHeight() },
        item_count: usize = config.item_count orelse 0,
        open: bool = false,
        active_depth: usize = 1,
        highlighted: DepthArray = [_]?usize{null} ** config.max_depth,
        scroll_y: ScrollArray = [_]f32{0.0} ** config.max_depth,
        dragging_scrollbar_depth: ?usize = null,
        scrollbar_drag_offset_y: f32 = 0.0,
        font_metrics: ?text_layout.FontMetrics = null,
        z_index: i32 = config.z_index,
        callbacks: CascadeMenuCallbacks = .{},

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

        pub fn setCallbacks(self: *Component, callbacks: CascadeMenuCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setFontMetrics(self: *Component, metrics_value: text_layout.FontMetrics) void {
            self.font_metrics = metrics_value;
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
            self.normalizeScroll();
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn setItemCount(self: *Component, count: usize) void {
            self.item_count = count;
            self.normalizeState();
        }

        pub fn isOpen(self: *const Component) bool {
            return self.open;
        }

        pub fn menuRect(self: *const Component, depth: usize) draw.Rect {
            const clamped_depth = @min(depth, config.max_depth - 1);
            var rect_value = self.rect;
            rect_value.w = if (self.rect.w > 0.0) self.rect.w else config.width;
            rect_value.h = if (self.rect.h > 0.0) self.rect.h else self.menuHeight(self.itemCountAtDepth(0));
            var current: usize = 0;
            while (current < clamped_depth) : (current += 1) {
                const parent = rect_value;
                rect_value.x = parent.x + parent.w + config.submenu_gap;
                if (self.highlighted[current]) |index| {
                    const y = parent.y + config.padding_y + @as(f32, @floatFromInt(index)) * config.row_height - self.scroll_y[current];
                    rect_value.y = y;
                }
                rect_value.h = self.menuHeight(self.itemCountAtDepth(current + 1));
            }
            return rect_value;
        }

        pub fn menuContentRect(self: *const Component, depth: usize) draw.Rect {
            const menu = self.menuRect(depth);
            return .{
                .x = menu.x + config.padding_x,
                .y = menu.y + config.padding_y,
                .w = @max(menu.w - config.padding_x * 2.0, 0.0),
                .h = @max(menu.h - config.padding_y * 2.0, config.row_height),
            };
        }

        pub fn rowRect(self: *const Component, depth: usize, index: usize) draw.Rect {
            const content = self.menuContentRect(depth);
            return .{
                .x = content.x,
                .y = content.y + @as(f32, @floatFromInt(index)) * config.row_height - self.scroll_y[depth],
                .w = @max(content.w - self.scrollbarGutter(depth), 0.0),
                .h = config.row_height,
            };
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .key_down => return self.handleInput(.{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .point = .{ .x = event.button.x, .y = event.button.y } } }),
                .mouse_button_up => return self.handleInput(.{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_motion => {
                    if (self.dragging_scrollbar_depth != null or event.motion.state.left) {
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
                .open => {
                    self.openMenu();
                    return true;
                },
                .close => {
                    self.close();
                    return true;
                },
                .item_count => |count| {
                    self.setItemCount(count);
                    return true;
                },
                .key => |key| return self.handleKey(key),
                .mouse_down => |mouse| {
                    if (!self.open) return false;
                    if (self.scrollbarDepthAtPoint(mouse.point)) |depth| {
                        if (self.scrollbarThumbRect(depth)) |thumb| {
                            self.dragging_scrollbar_depth = depth;
                            self.scrollbar_drag_offset_y = mouse.point.y - thumb.y;
                            return true;
                        }
                    }
                    if (self.rowAtPoint(mouse.point)) |hit| {
                        self.highlightRow(hit.depth, hit.index);
                        if (self.childCountAt(hit.depth, hit.index) > 0) return true;
                        self.selectRow(hit.depth, hit.index);
                        self.close();
                        return true;
                    }
                    if (!self.containsOpenMenus(mouse.point)) {
                        self.close();
                        return true;
                    }
                    return false;
                },
                .mouse_move => |point| {
                    if (!self.open) return false;
                    if (self.rowAtPoint(point)) |hit| {
                        self.highlightRow(hit.depth, hit.index);
                        return true;
                    }
                    return self.containsOpenMenus(point);
                },
                .mouse_drag => |point| {
                    if (self.dragging_scrollbar_depth) |depth| {
                        self.dragScrollbarTo(depth, point.y);
                        return true;
                    }
                    if (!self.open) return false;
                    if (self.rowAtPoint(point)) |hit| {
                        self.highlightRow(hit.depth, hit.index);
                        return true;
                    }
                    return false;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_scrollbar_depth != null;
                    self.dragging_scrollbar_depth = null;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!self.open) return false;
                    if (self.depthAtPoint(wheel.point)) |depth| {
                        self.scrollBy(depth, -wheel.y * config.row_height * 3.0);
                        return true;
                    }
                    return false;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!self.open) return;
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            var depth: usize = 0;
            while (depth < self.visibleDepthCount()) : (depth += 1) {
                _ = batch.setZIndex(self.z_index + @as(i32, @intCast(depth)) * config.submenu_z_offset);
                const menu = self.menuRect(depth);
                try batch.panel(allocator, menu, config.background_color, config.border_color, config.corner_radius, config.border_width);

                const range = self.visibleRange(depth);
                var index = range.start;
                while (index < range.end) : (index += 1) {
                    const row = self.rowRect(depth, index);
                    if (self.highlighted[depth] == index) try batch.rect(allocator, row, config.highlighted_color);
                    try self.renderRowLabel(allocator, batch, depth, index, row);
                }
                try self.renderScrollbar(allocator, batch, depth);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (!self.open) {
                if (key.code == .enter or key.code == .down or key.code == .right) {
                    self.openMenu();
                    return true;
                }
                return false;
            }
            switch (key.code) {
                .escape => self.close(),
                .down => self.moveHighlight(1),
                .up => self.moveHighlight(-1),
                .home => self.setHighlightedAtActive(0),
                .end => {
                    const depth = self.keyboardDepth();
                    const count = self.itemCountAtDepth(depth);
                    if (count > 0) self.setHighlightedAtActive(count - 1);
                },
                .right => self.openHighlightedChild(),
                .left => self.closeOneDepth(),
                .enter => self.activateHighlighted(),
                else => return false,
            }
            return true;
        }

        fn openMenu(self: *Component) void {
            if (!self.open) {
                self.open = true;
                self.emit(.{ .open_changed = true });
            }
            self.active_depth = 1;
            if (self.highlighted[0] == null and self.item_count > 0) self.highlightRow(0, 0);
        }

        fn close(self: *Component) void {
            if (!self.open) return;
            self.open = false;
            self.dragging_scrollbar_depth = null;
            self.active_depth = 1;
            self.emit(.{ .open_changed = false });
        }

        fn closeOneDepth(self: *Component) void {
            if (self.active_depth <= 1) return;
            self.clearFromDepth(self.active_depth - 1);
            self.active_depth -= 1;
        }

        fn moveHighlight(self: *Component, delta: i32) void {
            const depth = self.keyboardDepth();
            const count = self.itemCountAtDepth(depth);
            if (count == 0) return;
            const current = self.highlighted[depth] orelse if (delta < 0) count - 1 else 0;
            const next = if (delta < 0)
                if (current == 0) 0 else current - 1
            else
                @min(current + 1, count - 1);
            self.highlightRow(depth, next);
        }

        fn setHighlightedAtActive(self: *Component, index: usize) void {
            const depth = self.keyboardDepth();
            if (index < self.itemCountAtDepth(depth)) self.highlightRow(depth, index);
        }

        fn openHighlightedChild(self: *Component) void {
            const depth = self.keyboardDepth();
            const index = self.highlighted[depth] orelse return;
            if (self.childCountAt(depth, index) == 0 or depth + 1 >= config.max_depth) return;
            self.active_depth = @max(self.active_depth, depth + 2);
            if (self.highlighted[depth + 1] == null and self.itemCountAtDepth(depth + 1) > 0) {
                self.highlightRow(depth + 1, 0);
            }
        }

        fn activateHighlighted(self: *Component) void {
            const depth = self.keyboardDepth();
            const index = self.highlighted[depth] orelse return;
            if (self.childCountAt(depth, index) > 0) {
                self.openHighlightedChild();
                return;
            }
            self.selectRow(depth, index);
            self.close();
        }

        fn highlightRow(self: *Component, depth: usize, index: usize) void {
            if (depth >= config.max_depth or index >= self.itemCountAtDepth(depth)) return;
            self.highlighted[depth] = index;
            self.ensureIndexVisible(depth, index);
            const child_count = self.childCountAt(depth, index);
            if (child_count > 0 and depth + 1 < config.max_depth) {
                self.active_depth = @max(self.active_depth, depth + 2);
                self.clearFromDepth(depth + 1);
            } else {
                self.active_depth = @max(@min(depth + 1, config.max_depth), 1);
                self.clearFromDepth(depth + 1);
            }
            self.emitHighlight(depth, index);
        }

        fn selectRow(self: *Component, depth: usize, index: usize) void {
            var path_buffer: [config.max_depth]usize = undefined;
            const path = self.pathForDepth(depth, &path_buffer);
            self.emit(.{ .selected = .{ .path = path, .index = index } });
        }

        fn clearFromDepth(self: *Component, depth: usize) void {
            var i = depth;
            while (i < config.max_depth) : (i += 1) {
                self.highlighted[i] = null;
                self.scroll_y[i] = 0.0;
            }
        }

        fn normalizeState(self: *Component) void {
            if (self.item_count == 0) {
                self.highlighted[0] = null;
                self.open = false;
            } else if (self.highlighted[0]) |index| {
                if (index >= self.item_count) self.highlighted[0] = null;
            }
            var depth: usize = 1;
            while (depth < config.max_depth) : (depth += 1) {
                if (self.highlighted[depth]) |index| {
                    if (index >= self.itemCountAtDepth(depth)) self.highlighted[depth] = null;
                }
            }
            self.active_depth = @min(@max(self.active_depth, 1), config.max_depth);
            self.normalizeScroll();
        }

        fn normalizeScroll(self: *Component) void {
            var depth: usize = 0;
            while (depth < config.max_depth) : (depth += 1) {
                self.scroll_y[depth] = scroll.clampOffsetY(self.scroll_y[depth], self.scrollMetrics(depth));
            }
        }

        fn containsOpenMenus(self: *const Component, point: draw.Vec2) bool {
            var depth: usize = 0;
            while (depth < self.visibleDepthCount()) : (depth += 1) {
                if (self.menuRect(depth).contains(point)) return true;
            }
            return false;
        }

        fn rowAtPoint(self: *const Component, point: draw.Vec2) ?struct { depth: usize, index: usize } {
            var depth = self.visibleDepthCount();
            while (depth > 0) {
                depth -= 1;
                if (!self.menuContentRect(depth).contains(point)) continue;
                const row_offset = @max(point.y - self.menuContentRect(depth).y + self.scroll_y[depth], 0.0) / config.row_height;
                const index: usize = @intFromFloat(@floor(row_offset));
                if (index < self.itemCountAtDepth(depth)) return .{ .depth = depth, .index = index };
            }
            return null;
        }

        fn depthAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            var depth = self.visibleDepthCount();
            while (depth > 0) {
                depth -= 1;
                if (self.menuRect(depth).contains(point)) return depth;
            }
            return null;
        }

        fn scrollbarDepthAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            var depth = self.visibleDepthCount();
            while (depth > 0) {
                depth -= 1;
                if (self.scrollbarThumbRect(depth)) |thumb| {
                    if (thumb.contains(point)) return depth;
                }
            }
            return null;
        }

        fn visibleDepthCount(self: *const Component) usize {
            if (!self.open) return 0;
            return @min(self.active_depth, config.max_depth);
        }

        fn keyboardDepth(self: *const Component) usize {
            if (self.active_depth == 0) return 0;
            return @min(self.active_depth - 1, config.max_depth - 1);
        }

        fn itemCountAtDepth(self: *const Component, depth: usize) usize {
            if (depth == 0) return self.item_count;
            var path_buffer: [config.max_depth]usize = undefined;
            const parent_path = self.pathForDepth(depth - 1, &path_buffer);
            const parent_index = self.highlighted[depth - 1] orelse return 0;
            return self.childCountWithPath(parent_path, parent_index);
        }

        fn childCountAt(self: *const Component, depth: usize, index: usize) usize {
            var path_buffer: [config.max_depth]usize = undefined;
            const path = self.pathForDepth(depth, &path_buffer);
            return self.childCountWithPath(path, index);
        }

        fn childCountWithPath(self: *const Component, path: []const usize, index: usize) usize {
            if (config.child_count) |callback| return callback(self.callbacks.context, path, index);
            return 0;
        }

        fn itemLabel(self: *const Component, depth: usize, index: usize) []const u8 {
            var path_buffer: [config.max_depth]usize = undefined;
            const path = self.pathForDepth(depth, &path_buffer);
            if (config.item_label) |callback| return callback(self.callbacks.context, path, index);
            return "";
        }

        fn pathForDepth(self: *const Component, depth: usize, out: *[config.max_depth]usize) []const usize {
            var i: usize = 0;
            while (i < depth and i < config.max_depth) : (i += 1) {
                out[i] = self.highlighted[i] orelse 0;
            }
            return out[0..@min(depth, config.max_depth)];
        }

        fn visibleRange(self: *const Component, depth: usize) struct { start: usize, end: usize } {
            const count = self.itemCountAtDepth(depth);
            const content = self.menuContentRect(depth);
            const start: usize = @min(@as(usize, @intFromFloat(@floor(self.scroll_y[depth] / config.row_height))), count);
            const visible_count = @as(usize, @intFromFloat(@ceil(content.h / config.row_height))) + 1;
            return .{ .start = start, .end = @min(start + visible_count, count) };
        }

        fn ensureIndexVisible(self: *Component, depth: usize, index: usize) void {
            if (!config.scroll_enabled) {
                self.scroll_y[depth] = 0.0;
                return;
            }
            const row_top = @as(f32, @floatFromInt(index)) * config.row_height;
            const row_bottom = row_top + config.row_height;
            const visible_height = self.menuContentRect(depth).h;
            if (row_top < self.scroll_y[depth]) {
                self.scroll_y[depth] = row_top;
            } else if (row_bottom > self.scroll_y[depth] + visible_height) {
                self.scroll_y[depth] = row_bottom - visible_height;
            }
            self.scroll_y[depth] = scroll.clampOffsetY(self.scroll_y[depth], self.scrollMetrics(depth));
        }

        fn scrollBy(self: *Component, depth: usize, delta_y: f32) void {
            self.scroll_y[depth] = scroll.clampOffsetY(self.scroll_y[depth] + delta_y, self.scrollMetrics(depth));
        }

        fn dragScrollbarTo(self: *Component, depth: usize, y: f32) void {
            const track = self.scrollbarTrackRect(depth);
            const thumb = self.scrollbarThumbRect(depth) orelse return;
            self.scroll_y[depth] = scroll.offsetForThumbY(y, self.scrollbar_drag_offset_y, track, thumb, self.scrollMetrics(depth));
        }

        fn renderRowLabel(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, depth: usize, index: usize, row: draw.Rect) !void {
            const label = self.itemLabel(depth, index);
            const metrics_value = self.metrics();
            const icon_metrics = self.iconMetrics();
            const has_children = self.childCountAt(depth, index) > 0;
            var runs: [2]draw.TextRun = undefined;
            var count: usize = 0;
            const text_y = row.y + @max((row.h - metrics_value.line_height) * 0.5, 0.0);
            const label_clip = self.menuContentRect(depth);
            const chevron_w = if (has_children and config.chevron_icon.len > 0) icon_metrics.measureSlice(config.chevron_icon) else 0.0;
            const label_w = @max(row.w - chevron_w - config.icon_gap, 0.0);
            runs[count] = .{
                .text = label,
                .byte_start = 0,
                .byte_end = label.len,
                .x = row.x,
                .y = text_y,
                .font_size = metrics_value.font_size,
                .line_height = metrics_value.line_height,
                .color = config.text_color,
                .clip = label_clip,
                .font_role = config.font_role,
                .font_id = config.font_id,
            };
            count += 1;
            if (has_children and config.chevron_icon.len > 0) {
                runs[count] = .{
                    .text = config.chevron_icon,
                    .byte_start = 0,
                    .byte_end = config.chevron_icon.len,
                    .x = row.x + label_w + config.icon_gap,
                    .y = row.y + @max((row.h - icon_metrics.line_height) * 0.5, 0.0),
                    .font_size = icon_metrics.font_size,
                    .line_height = icon_metrics.line_height,
                    .color = config.icon_color,
                    .clip = label_clip,
                    .font_role = config.icon_font_role,
                    .font_id = config.icon_font_id,
                };
                count += 1;
            }
            try batch.textRuns(allocator, row, label, runs[0..count], config.text_color, metrics_value.font_size, label_clip, metrics_value.line_height, metrics_value.fixedAdvance());
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, depth: usize) !void {
            if (!config.scroll_enabled or scroll.maxOffsetY(self.scrollMetrics(depth)) <= 0.0 or config.scrollbar_width <= 0.0) return;
            const track = self.scrollbarTrackRect(depth);
            try batch.scrollbar(allocator, track, config.scrollbar_track_color);
            if (self.scrollbarThumbRect(depth)) |thumb| try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
        }

        fn scrollbarTrackRect(self: *const Component, depth: usize) draw.Rect {
            const content = self.menuContentRect(depth);
            return .{
                .x = content.x + content.w - config.scrollbar_width,
                .y = content.y,
                .w = config.scrollbar_width,
                .h = content.h,
            };
        }

        fn scrollbarThumbRect(self: *const Component, depth: usize) ?draw.Rect {
            return scroll.thumbRect(self.scrollbarTrackRect(depth), self.scrollMetrics(depth), self.scroll_y[depth]);
        }

        fn scrollbarGutter(self: *const Component, depth: usize) f32 {
            if (scroll.maxOffsetY(self.scrollMetrics(depth)) <= 0.0) return 0.0;
            return config.scrollbar_width + config.icon_gap;
        }

        fn scrollMetrics(self: *const Component, depth: usize) scroll.Metrics {
            return .{
                .enabled = config.scroll_enabled,
                .content_height = @as(f32, @floatFromInt(self.itemCountAtDepth(depth))) * config.row_height,
                .visible_height = self.menuContentRect(depth).h,
                .line_height = config.row_height,
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn menuHeight(self: *const Component, item_count: usize) f32 {
            _ = self;
            const visible_rows = @min(item_count, config.max_visible_rows);
            return config.padding_y * 2.0 + @as(f32, @floatFromInt(@max(visible_rows, 1))) * config.row_height;
        }

        fn metrics(self: *const Component) text_layout.FontMetrics {
            if (self.font_metrics) |metrics_value| return metrics_value;
            return text_layout.FontMetrics.fixed(config.font_size, config.glyph_width, config.row_height);
        }

        fn iconMetrics(_: *const Component) text_layout.FontMetrics {
            return text_layout.FontMetrics.fixed(config.font_size, config.glyph_width, config.row_height);
        }

        fn emitHighlight(self: *Component, depth: usize, index: usize) void {
            var path_buffer: [config.max_depth]usize = undefined;
            const path = self.pathForDepth(depth, &path_buffer);
            self.emit(.{ .highlighted = .{ .path = path, .index = index } });
        }

        fn emit(self: *Component, event: CascadeMenuEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn defaultMenuHeight() f32 {
            return config.padding_y * 2.0 + @as(f32, @floatFromInt(@max(config.max_visible_rows, 1))) * config.row_height;
        }
    };
}

test "cascade menu opens child menu and selects leaf with path" {
    const Context = struct {
        selected_path: [4]usize = [_]usize{99} ** 4,
        selected_path_len: usize = 0,
        selected_index: usize = 99,

        fn label(_: ?*anyopaque, path: []const usize, index: usize) []const u8 {
            if (path.len == 0) return switch (index) {
                0 => "File",
                1 => "Edit",
                else => "",
            };
            if (path[0] == 0) return switch (index) {
                0 => "New",
                1 => "Open",
                else => "",
            };
            return "";
        }

        fn childCount(_: ?*anyopaque, path: []const usize, index: usize) usize {
            if (path.len == 0 and index == 0) return 2;
            return 0;
        }

        fn onEvent(context: ?*anyopaque, event: CascadeMenuEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .selected => |selected| {
                    self.selected_path_len = selected.path.len;
                    for (selected.path, 0..) |part, i| self.selected_path[i] = part;
                    self.selected_index = selected.index;
                },
                else => {},
            }
        }
    };

    const Menu = CascadeMenu(.{
        .x = 10,
        .y = 20,
        .width = 100,
        .row_height = 20,
        .max_depth = 4,
        .max_visible_rows = 4,
        .item_count = 2,
        .item_label = Context.label,
        .child_count = Context.childCount,
    });
    var context = Context{};
    var menu = Menu.initFromConfig();
    menu.setCallbacks(.{ .context = &context, .on_event = Context.onEvent });

    try std.testing.expect(menu.handleInput(.open));
    try std.testing.expect(menu.handleInput(.{ .mouse_move = .{ .x = 20, .y = 30 } }));
    try std.testing.expectEqual(@as(usize, 2), menu.visibleDepthCount());
    try std.testing.expect(menu.handleInput(.{ .mouse_down = .{ .point = .{ .x = 130, .y = 55 } } }));

    try std.testing.expectEqual(@as(usize, 1), context.selected_path_len);
    try std.testing.expectEqual(@as(usize, 0), context.selected_path[0]);
    try std.testing.expectEqual(@as(usize, 1), context.selected_index);
    try std.testing.expect(!menu.isOpen());
}

test "cascade menu renders text and icon runs with increasing z-index" {
    const Context = struct {
        fn label(_: ?*anyopaque, path: []const usize, index: usize) []const u8 {
            if (path.len == 0 and index == 0) return "Parent";
            if (path.len == 1 and path[0] == 0 and index == 0) return "Child";
            return "";
        }

        fn childCount(_: ?*anyopaque, path: []const usize, index: usize) usize {
            if (path.len == 0 and index == 0) return 1;
            return 0;
        }
    };

    const Menu = CascadeMenu(.{
        .width = 120,
        .row_height = 24,
        .max_depth = 3,
        .item_count = 1,
        .item_label = Context.label,
        .child_count = Context.childCount,
        .chevron_icon = ">",
        .z_index = 20,
        .submenu_z_offset = 10,
    });
    var menu = Menu.initFromConfig();
    try std.testing.expect(menu.handleInput(.open));
    try std.testing.expect(menu.handleInput(.{ .mouse_move = .{ .x = 4, .y = 10 } }));

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try menu.render(std.testing.allocator, &batch);

    try std.testing.expect(batch.commands.items.len >= 4);
    try std.testing.expectEqual(draw.CommandKind.text, batch.commands.items[2].kind);
    try std.testing.expectEqual(@as(usize, 2), batch.commands.items[2].text_run_count);
    try std.testing.expectEqual(draw.FontRole.icon, batch.commands.items[2].text_runs[1].font_role.?);
    try std.testing.expect(batch.commands.items[batch.commands.items.len - 1].z_index > batch.commands.items[0].z_index);
}

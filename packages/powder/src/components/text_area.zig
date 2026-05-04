//! Retained multiline text editing component.

const Self = @This();
const std = @import("std");

const draw = @import("../draw.zig");
const sdl = @import("../sdl.zig");

pub const TextAreaConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 480.0,
    height: f32 = 160.0,
    padding_x: f32 = 8.0,
    padding_y: f32 = 8.0,
    background_color: draw.Color = .{ .r = 0.07, .g = 0.08, .b = 0.09, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.18, .g = 0.21, .b = 0.24, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    cursor_color: draw.Color = draw.Color.white,
    selection_color: draw.Color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    placeholder_text: []const u8 = "",
    placeholder_color: draw.Color = .{ .r = 0.50, .g = 0.56, .b = 0.65, .a = 0.76 },
    read_only: bool = false,
    max_bytes: ?usize = null,
    cursor_blink_ms: u32 = 530,
    font_size: f32 = 16.0,
    glyph_width: ?f32 = null,
    line_height: ?f32 = null,
    wrap: bool = true,
    scroll_enabled: bool = true,
    submit_on_enter: bool = false,
};

pub const Input = union(enum) {
    text: []const u8,
    key: Key,
    mouse_down: MouseButton,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
    composition: []const u8,
};

pub const MouseButton = struct {
    point: draw.Vec2,
    clicks: u8 = 1,
};

pub const MouseWheel = struct {
    point: draw.Vec2,
    y: f32,
};

pub const Key = struct {
    code: Code,
    shift: bool = false,
    primary: bool = false,
    alt: bool = false,

    pub const Code = enum {
        left,
        right,
        up,
        down,
        home,
        end,
        backspace,
        delete,
        enter,
        page_up,
        page_down,
        a,
        c,
        v,
        x,
    };
};

pub const TextAreaAction = enum {
    default,
    handled,
    insert_newline,
    submit,
};

pub const TextAreaEvent = union(enum) {
    changed: []const u8,
    submitted: []const u8,
    key: Key,
    focus_changed: bool,
    composition: []const u8,
};

pub const TextAreaCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: TextAreaEvent) void = null,
    on_key: ?*const fn (context: ?*anyopaque, key: Key) TextAreaAction = null,
    validate_edit: ?*const fn (context: ?*anyopaque, current: []const u8, replacement: []const u8, start: usize, end: usize) bool = null,
    set_clipboard: ?*const fn (context: ?*anyopaque, text: []const u8) bool = null,
    get_clipboard: ?*const fn (context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,
};

pub fn TextArea(comptime config: TextAreaConfig) type {
    return struct {
        const Component = @This();

        buffer: std.ArrayList(u8) = .empty,
        cursor: usize = 0,
        selection_anchor: ?usize = null,
        selection_focus: ?usize = null,
        focused: bool = false,
        submitted: bool = false,
        scroll_y: f32 = 0.0,
        bounds_rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        cursor_visible: bool = true,
        cursor_elapsed_ms: u32 = 0,
        dragging_scrollbar: bool = false,
        scrollbar_drag_offset_y: f32 = 0.0,
        callbacks: TextAreaCallbacks = .{},

        pub fn init(allocator: std.mem.Allocator, initial: []const u8) !Component {
            var self: Component = .{};
            try self.buffer.appendSlice(allocator, initial);
            self.cursor = self.buffer.items.len;
            return self;
        }

        pub fn deinit(self: *Component, allocator: std.mem.Allocator) void {
            self.buffer.deinit(allocator);
            self.* = undefined;
        }

        pub fn text(self: *const Component) []const u8 {
            return self.buffer.items;
        }

        pub fn setText(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(allocator, value);
            self.cursor = @min(self.cursor, self.buffer.items.len);
            self.clearSelection();
            self.ensureCursorVisible();
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.bounds_rect = rect;
            self.setScrollY(self.scroll_y);
            self.ensureCursorVisible();
        }

        pub fn placeholder(self: *const Component) []const u8 {
            _ = self;
            return config.placeholder_text;
        }

        pub fn placeholderVisible(self: *const Component) bool {
            return self.buffer.items.len == 0 and config.placeholder_text.len > 0;
        }

        pub fn selection(self: *const Component) ?struct { start: usize, end: usize } {
            const anchor = @min(self.selection_anchor orelse return null, self.buffer.items.len);
            const focus = @min(self.selection_focus orelse return null, self.buffer.items.len);
            if (anchor == focus) return null;
            return if (anchor < focus)
                .{ .start = anchor, .end = focus }
            else
                .{ .start = focus, .end = anchor };
        }

        pub fn clearSelection(self: *Component) void {
            self.selection_anchor = null;
            self.selection_focus = null;
        }

        pub fn scrollY(self: *const Component) f32 {
            return self.scroll_y;
        }

        pub fn setScrollY(self: *Component, value: f32) void {
            if (!config.scroll_enabled) {
                self.scroll_y = 0.0;
                return;
            }
            self.scroll_y = @min(@max(value, 0.0), self.maxScrollY());
        }

        pub fn setCallbacks(self: *Component, callbacks: TextAreaCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn update(self: *Component, allocator: std.mem.Allocator, event: *const sdl.Event) !bool {
            switch (event.type) {
                .text_input => return try self.handleInput(allocator, .{ .text = std.mem.span(event.text.text) }),
                .text_editing => return try self.handleInput(allocator, .{ .composition = std.mem.span(event.edit.text) }),
                .key_down => return try self.handleInput(allocator, .{ .key = keyFromSdl(event.key) orelse return false }),
                .mouse_button_down => return try self.handleInput(allocator, .{ .mouse_down = .{ .point = .{ .x = event.button.x, .y = event.button.y }, .clicks = event.button.clicks } }),
                .mouse_button_up => return try self.handleInput(allocator, .{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_wheel => return try self.handleInput(allocator, .{ .mouse_wheel = .{ .point = .{ .x = event.wheel.mouse_x, .y = event.wheel.mouse_y }, .y = event.wheel.y } }),
                .mouse_motion => {
                    if (!self.focused or (!self.dragging_scrollbar and !event.motion.state.left)) return false;
                    return try self.handleInput(allocator, .{ .mouse_drag = .{ .x = event.motion.x, .y = event.motion.y } });
                },
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, allocator: std.mem.Allocator, input: Input) !bool {
            self.submitted = false;
            switch (input) {
                .text => |value| {
                    if (!self.focused or config.read_only) return false;
                    try self.replaceSelectionOrInsert(allocator, value);
                    return true;
                },
                .key => |key| return try self.handleKey(allocator, key),
                .composition => |value| {
                    if (!self.focused) return false;
                    self.emit(.{ .composition = value });
                    return true;
                },
                .mouse_down => |mouse| {
                    const point = mouse.point;
                    const was_focused = self.focused;
                    self.focused = self.bounds().contains(point);
                    if (self.focused != was_focused) self.emit(.{ .focus_changed = self.focused });
                    if (!self.focused) return false;

                    if (self.scrollbarThumbRect()) |thumb| {
                        if (thumb.contains(point)) {
                            self.dragging_scrollbar = true;
                            self.scrollbar_drag_offset_y = point.y - thumb.y;
                            return true;
                        }
                    }

                    self.cursor = self.byteOffsetForPoint(point);
                    if (mouse.clicks >= 3) {
                        self.selectLineAt(self.cursor);
                    } else if (mouse.clicks >= 2) {
                        self.selectWordAt(self.cursor);
                    } else {
                        self.clearSelection();
                    }
                    self.ensureCursorVisible();
                    return true;
                },
                .mouse_drag => |point| {
                    if (!self.focused) return false;
                    if (self.dragging_scrollbar) {
                        self.dragScrollbarTo(point.y);
                        return true;
                    }
                    if (self.selection_anchor == null) self.selection_anchor = self.cursor;
                    self.cursor = self.byteOffsetForPoint(point);
                    self.selection_focus = self.cursor;
                    self.autoScrollForDrag(point);
                    self.ensureCursorVisible();
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_scrollbar;
                    self.dragging_scrollbar = false;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!self.bounds().contains(wheel.point)) return false;
                    self.scrollBy(-wheel.y * self.lineHeight() * 3.0);
                    return true;
                },
            }
        }

        pub fn tick(self: *Component, elapsed_ms: u32) void {
            if (!self.focused or config.cursor_blink_ms == 0) {
                self.cursor_visible = true;
                self.cursor_elapsed_ms = 0;
                return;
            }
            self.cursor_elapsed_ms += elapsed_ms;
            while (self.cursor_elapsed_ms >= config.cursor_blink_ms) {
                self.cursor_elapsed_ms -= config.cursor_blink_ms;
                self.cursor_visible = !self.cursor_visible;
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const bounds_rect = self.bounds();
            try batch.rect(allocator, bounds_rect, config.background_color);
            try batch.rect(allocator, .{ .x = bounds_rect.x, .y = bounds_rect.y, .w = bounds_rect.w, .h = 1.0 }, config.border_color);
            if (self.selection()) |range| {
                try self.renderSelection(allocator, batch, range.start, range.end);
            }
            try batch.glyph(allocator, self.textRect(), .{}, if (self.placeholderVisible()) config.placeholder_color else config.text_color);
            if (self.focused and self.cursor_visible) {
                const pos = self.cursorPosition();
                try self.addClippedCommand(allocator, batch, .cursor, .{ .x = pos.x, .y = pos.y, .w = 1.5, .h = self.lineHeight() }, config.cursor_color);
            }
            try self.renderScrollbar(allocator, batch);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, allocator: std.mem.Allocator, key: Key) !bool {
            self.normalizeState();
            if (!self.focused and key.code != .a) return false;
            self.emit(.{ .key = key });
            if (self.callbacks.on_key) |callback| {
                switch (callback(self.callbacks.context, key)) {
                    .default => {},
                    .handled => return true,
                    .insert_newline => {
                        try self.replaceSelectionOrInsert(allocator, "\n");
                        return true;
                    },
                    .submit => {
                        self.submit();
                        return true;
                    },
                }
            }
            if (key.primary and key.code == .a) {
                self.selection_anchor = 0;
                self.selection_focus = self.buffer.items.len;
                self.cursor = self.buffer.items.len;
                self.ensureCursorVisible();
                return true;
            }
            if (key.primary and key.code == .c) return self.copySelection(allocator);
            if (key.primary and key.code == .x) return if (config.read_only) false else try self.cutSelection(allocator);
            if (key.primary and key.code == .v) return if (config.read_only) false else try self.pasteClipboard(allocator);
            switch (key.code) {
                .left => self.moveCursor(if (key.primary or key.alt) previousWordOffset(self.buffer.items, self.cursor) else previousOffset(self.buffer.items, self.cursor), key.shift),
                .right => self.moveCursor(if (key.primary or key.alt) nextWordOffset(self.buffer.items, self.cursor) else nextOffset(self.buffer.items, self.cursor), key.shift),
                .home => self.moveCursor(if (key.primary) @as(usize, 0) else lineStart(self.buffer.items, self.cursor), key.shift),
                .end => self.moveCursor(if (key.primary) self.buffer.items.len else lineEnd(self.buffer.items, self.cursor), key.shift),
                .up => self.moveCursor(self.verticalMove(-1), key.shift),
                .down => self.moveCursor(self.verticalMove(1), key.shift),
                .page_up => self.moveCursor(self.pageMove(-1), key.shift),
                .page_down => self.moveCursor(self.pageMove(1), key.shift),
                .backspace => if (!config.read_only) try self.deleteBack(allocator),
                .delete => if (!config.read_only) try self.deleteForward(allocator),
                .enter => {
                    if (config.read_only) return false;
                    if (config.submit_on_enter and !key.shift) {
                        self.submit();
                    } else {
                        try self.replaceSelectionOrInsert(allocator, "\n");
                    }
                },
                else => return false,
            }
            return true;
        }

        fn replaceSelectionOrInsert(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            self.normalizeState();
            const selection_range = self.selection();
            const start = if (selection_range) |range| range.start else self.cursor;
            const end = if (selection_range) |range| range.end else self.cursor;
            if (!self.canApplyEdit(value, start, end)) return;
            if (start != end) {
                self.buffer.replaceRange(allocator, start, end - start, value) catch |err| return err;
                self.cursor = start + value.len;
            } else {
                try self.buffer.insertSlice(allocator, self.cursor, value);
                self.cursor += value.len;
            }
            self.clearSelection();
            self.ensureCursorVisible();
            self.emit(.{ .changed = self.buffer.items });
        }

        fn canApplyEdit(self: *const Component, replacement: []const u8, start: usize, end: usize) bool {
            if (config.read_only) return false;
            if (config.max_bytes) |max_bytes| {
                const next_len = self.buffer.items.len - (end - start) + replacement.len;
                if (next_len > max_bytes) return false;
            }
            if (self.callbacks.validate_edit) |callback| {
                if (!callback(self.callbacks.context, self.buffer.items, replacement, start, end)) return false;
            }
            return true;
        }

        fn deleteBack(self: *Component, allocator: std.mem.Allocator) !void {
            self.normalizeState();
            if (self.selection()) |_| return self.replaceSelectionOrInsert(allocator, "");
            if (self.cursor == 0) return;
            const start = previousOffset(self.buffer.items, self.cursor);
            self.buffer.replaceRange(allocator, start, self.cursor - start, "") catch |err| return err;
            self.cursor = start;
            self.ensureCursorVisible();
            self.emit(.{ .changed = self.buffer.items });
        }

        fn deleteForward(self: *Component, allocator: std.mem.Allocator) !void {
            self.normalizeState();
            if (self.selection()) |_| return self.replaceSelectionOrInsert(allocator, "");
            if (self.cursor >= self.buffer.items.len) return;
            const end = nextOffset(self.buffer.items, self.cursor);
            self.buffer.replaceRange(allocator, self.cursor, end - self.cursor, "") catch |err| return err;
            self.ensureCursorVisible();
            self.emit(.{ .changed = self.buffer.items });
        }

        fn submit(self: *Component) void {
            self.submitted = true;
            self.emit(.{ .submitted = self.buffer.items });
        }

        fn emit(self: *Component, event: TextAreaEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
        }

        fn copySelection(self: *Component, allocator: std.mem.Allocator) bool {
            _ = allocator;
            const range = self.selection() orelse return false;
            const callback = self.callbacks.set_clipboard orelse return false;
            return callback(self.callbacks.context, self.buffer.items[range.start..range.end]);
        }

        fn cutSelection(self: *Component, allocator: std.mem.Allocator) !bool {
            if (!self.copySelection(allocator)) return false;
            try self.replaceSelectionOrInsert(allocator, "");
            return true;
        }

        fn pasteClipboard(self: *Component, allocator: std.mem.Allocator) !bool {
            const callback = self.callbacks.get_clipboard orelse return false;
            const clipboard_text = callback(self.callbacks.context, allocator) orelse return false;
            defer allocator.free(clipboard_text);
            if (clipboard_text.len == 0) return false;
            try self.replaceSelectionOrInsert(allocator, clipboard_text);
            return true;
        }

        fn moveCursor(self: *Component, next: usize, selecting: bool) void {
            self.normalizeState();
            if (selecting) {
                if (self.selection_anchor == null) self.selection_anchor = self.cursor;
                self.selection_focus = next;
            } else {
                self.clearSelection();
            }
            self.cursor = @min(next, self.buffer.items.len);
            self.cursor_visible = true;
            self.cursor_elapsed_ms = 0;
            self.ensureCursorVisible();
        }

        fn normalizeState(self: *Component) void {
            self.cursor = @min(self.cursor, self.buffer.items.len);
            if (self.selection_anchor) |anchor| {
                self.selection_anchor = @min(anchor, self.buffer.items.len);
            }
            if (self.selection_focus) |focus| {
                self.selection_focus = @min(focus, self.buffer.items.len);
            }
            self.setScrollY(self.scroll_y);
        }

        fn scrollBy(self: *Component, delta_y: f32) void {
            self.setScrollY(self.scroll_y + delta_y);
        }

        fn dragScrollbarTo(self: *Component, y: f32) void {
            const max_scroll = self.maxScrollY();
            if (max_scroll <= 0.0) return;
            const track = self.scrollbarTrackRect();
            const thumb = self.scrollbarThumbRect() orelse return;
            const travel = @max(track.h - thumb.h, 1.0);
            const thumb_y = @min(@max(y - self.scrollbar_drag_offset_y, track.y), track.y + travel);
            self.setScrollY(((thumb_y - track.y) / travel) * max_scroll);
        }

        fn autoScrollForDrag(self: *Component, point: draw.Vec2) void {
            const text_rect = self.textRect();
            if (point.y < text_rect.y) {
                self.scrollBy(-self.lineHeight());
            } else if (point.y > text_rect.y + text_rect.h) {
                self.scrollBy(self.lineHeight());
            }
        }

        fn selectWordAt(self: *Component, offset: usize) void {
            const range = wordRangeAt(self.buffer.items, offset);
            self.selection_anchor = range.start;
            self.selection_focus = range.end;
            self.cursor = range.end;
        }

        fn selectLineAt(self: *Component, offset: usize) void {
            const start = lineStart(self.buffer.items, offset);
            var end = lineEnd(self.buffer.items, offset);
            if (end < self.buffer.items.len) end += 1;
            self.selection_anchor = start;
            self.selection_focus = end;
            self.cursor = end;
        }

        fn renderSelection(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, start: usize, end: usize) !void {
            const start_pos = self.positionForOffset(start);
            const end_pos = self.positionForOffset(end);
            if (start_pos.y == end_pos.y) {
                try self.addClippedCommand(allocator, batch, .selection, .{ .x = start_pos.x, .y = start_pos.y, .w = @max(end_pos.x - start_pos.x, 2.0), .h = self.lineHeight() }, config.selection_color);
                return;
            }
            const text_rect = self.textRect();
            try self.addClippedCommand(allocator, batch, .selection, .{ .x = start_pos.x, .y = start_pos.y, .w = text_rect.x + text_rect.w - start_pos.x, .h = self.lineHeight() }, config.selection_color);
            var y = start_pos.y + self.lineHeight();
            while (y < end_pos.y) : (y += self.lineHeight()) {
                try self.addClippedCommand(allocator, batch, .selection, .{ .x = text_rect.x, .y = y, .w = text_rect.w, .h = self.lineHeight() }, config.selection_color);
            }
            try self.addClippedCommand(allocator, batch, .selection, .{ .x = text_rect.x, .y = end_pos.y, .w = @max(end_pos.x - text_rect.x, 2.0), .h = self.lineHeight() }, config.selection_color);
        }

        fn addClippedCommand(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, kind: draw.CommandKind, rect: draw.Rect, color: draw.Color) !void {
            const clipped = clippedRect(rect, self.textRect()) orelse return;
            switch (kind) {
                .cursor => try batch.cursor(allocator, clipped, color),
                .selection => try batch.selection(allocator, clipped, color),
                .scrollbar => try batch.scrollbar(allocator, clipped, color),
                else => try batch.rect(allocator, clipped, color),
            }
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const max_scroll = self.maxScrollY();
            if (!config.scroll_enabled or max_scroll <= 0.0 or config.scrollbar_width <= 0.0) return;

            const track = self.scrollbarTrackRect();
            try batch.scrollbar(allocator, track, config.scrollbar_track_color);

            const thumb = self.scrollbarThumbRect() orelse return;
            try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
        }

        fn scrollbarTrackRect(self: *const Component) draw.Rect {
            const text_rect = self.textRect();
            const track_w = @min(config.scrollbar_width, text_rect.w);
            return .{
                .x = text_rect.x + text_rect.w - track_w,
                .y = text_rect.y,
                .w = track_w,
                .h = text_rect.h,
            };
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            const max_scroll = self.maxScrollY();
            if (!config.scroll_enabled or max_scroll <= 0.0 or config.scrollbar_width <= 0.0) return null;
            const track = self.scrollbarTrackRect();
            const content_height = self.contentHeight();
            const visible_height = self.visibleTextHeight();
            const thumb_h = @max((visible_height / content_height) * track.h, @min(track.h, self.lineHeight()));
            const travel = @max(track.h - thumb_h, 0.0);
            const thumb_y = track.y + if (max_scroll > 0.0) (self.scroll_y / max_scroll) * travel else 0.0;
            return .{
                .x = track.x,
                .y = thumb_y,
                .w = track.w,
                .h = thumb_h,
            };
        }

        fn byteOffsetForPoint(self: *const Component, point: draw.Vec2) usize {
            const text_rect = self.textRect();
            const col_float = @max(point.x - text_rect.x, 0.0) / self.glyphWidth();
            const row_float = @max(point.y - text_rect.y + self.scroll_y, 0.0) / self.lineHeight();
            return self.offsetAtVisualCell(
                @intFromFloat(@max(row_float, 0.0)),
                @intFromFloat(@max(col_float, 0.0)),
            );
        }

        fn cursorPosition(self: *const Component) draw.Vec2 {
            return self.positionForOffset(self.cursor);
        }

        fn positionForOffset(self: *const Component, offset: usize) draw.Vec2 {
            var row: usize = 0;
            var col: usize = 0;
            var index: usize = 0;
            while (index < @min(offset, self.buffer.items.len)) {
                if (self.buffer.items[index] == '\n') {
                    row += 1;
                    col = 0;
                } else {
                    if (self.shouldWrapColumn(col)) {
                        row += 1;
                        col = 0;
                    }
                    col += 1;
                }
                index = nextOffset(self.buffer.items, index);
            }
            return self.positionForVisualCell(row, col);
        }

        fn verticalMove(self: *const Component, delta: i32) usize {
            if (delta < 0) {
                const cell = self.visualCellForOffset(self.cursor);
                if (cell.row == 0) return 0;
                return self.offsetAtVisualCell(cell.row - 1, cell.col);
            }
            const cell = self.visualCellForOffset(self.cursor);
            return self.offsetAtVisualCell(cell.row + 1, cell.col);
        }

        fn pageMove(self: *const Component, delta: i32) usize {
            const rows = @max(@as(usize, @intFromFloat(@floor(self.visibleTextHeight() / self.lineHeight()))), 1);
            const cell = self.visualCellForOffset(self.cursor);
            if (delta < 0) return self.offsetAtVisualCell(if (cell.row > rows) cell.row - rows else 0, cell.col);
            return self.offsetAtVisualCell(cell.row + rows, cell.col);
        }

        fn visualCellForOffset(self: *const Component, offset: usize) struct { row: usize, col: usize } {
            var row: usize = 0;
            var col: usize = 0;
            var index: usize = 0;
            while (index < @min(offset, self.buffer.items.len)) {
                if (self.buffer.items[index] == '\n') {
                    row += 1;
                    col = 0;
                } else {
                    if (self.shouldWrapColumn(col)) {
                        row += 1;
                        col = 0;
                    }
                    col += 1;
                }
                index = nextOffset(self.buffer.items, index);
            }
            return .{ .row = row, .col = col };
        }

        fn offsetAtVisualCell(self: *const Component, target_row: usize, target_col: usize) usize {
            var row: usize = 0;
            var col: usize = 0;
            var index: usize = 0;
            while (index < self.buffer.items.len) {
                if (row == target_row and col >= target_col) return index;
                if (self.buffer.items[index] == '\n') {
                    if (row == target_row) return index;
                    row += 1;
                    col = 0;
                    index = nextOffset(self.buffer.items, index);
                    continue;
                }
                if (self.shouldWrapColumn(col)) {
                    row += 1;
                    col = 0;
                    if (row > target_row) return index;
                    if (row == target_row and col >= target_col) return index;
                }
                col += 1;
                index = nextOffset(self.buffer.items, index);
            }
            return self.buffer.items.len;
        }

        fn positionForVisualCell(self: *const Component, row: usize, col: usize) draw.Vec2 {
            return .{
                .x = self.textRect().x + @as(f32, @floatFromInt(col)) * self.glyphWidth(),
                .y = self.textRect().y + @as(f32, @floatFromInt(row)) * self.lineHeight() - self.scroll_y,
            };
        }

        fn ensureCursorVisible(self: *Component) void {
            if (!config.scroll_enabled) {
                self.scroll_y = 0.0;
                return;
            }
            const cell = self.visualCellForOffset(self.cursor);
            const cursor_top = @as(f32, @floatFromInt(cell.row)) * self.lineHeight();
            const cursor_bottom = cursor_top + self.lineHeight();
            const visible_height = self.visibleTextHeight();

            if (cursor_top < self.scroll_y) {
                self.scroll_y = cursor_top;
            } else if (cursor_bottom > self.scroll_y + visible_height) {
                self.scroll_y = cursor_bottom - visible_height;
            }
            self.setScrollY(self.scroll_y);
        }

        fn maxScrollY(self: *const Component) f32 {
            if (!config.scroll_enabled) return 0.0;
            return @max(self.contentHeight() - self.visibleTextHeight(), 0.0);
        }

        fn contentHeight(self: *const Component) f32 {
            const rows = self.visualCellForOffset(self.buffer.items.len).row + 1;
            return @as(f32, @floatFromInt(rows)) * self.lineHeight();
        }

        fn shouldWrapColumn(self: *const Component, col: usize) bool {
            return config.wrap and col >= self.wrapColumnLimit();
        }

        fn wrapColumnLimit(self: *const Component) usize {
            if (!config.wrap) return std.math.maxInt(usize);
            const inner_width = @max(self.textRect().w, self.glyphWidth());
            return @max(@as(usize, @intFromFloat(@floor(inner_width / self.glyphWidth()))), 1);
        }

        fn bounds(self: *const Component) draw.Rect {
            return self.bounds_rect;
        }

        fn textRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            return .{
                .x = bounds_rect.x + config.padding_x,
                .y = bounds_rect.y + config.padding_y,
                .w = @max(bounds_rect.w - config.padding_x * 2.0, 0.0),
                .h = @max(bounds_rect.h - config.padding_y * 2.0, 0.0),
            };
        }

        fn visibleTextHeight(self: *const Component) f32 {
            return @max(self.textRect().h, self.lineHeight());
        }

        fn lineHeight(_: *const Component) f32 {
            return config.line_height orelse config.font_size * 1.25;
        }

        fn glyphWidth(_: *const Component) f32 {
            return config.glyph_width orelse config.font_size * 0.55;
        }
    };
}

fn keyFromSdl(event: sdl.KeyboardEvent) ?Key {
    const mod_bits = event.mod;
    const primary = (mod_bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    const shift = (mod_bits & sdl.Keymod.shift) != 0;
    const alt = (mod_bits & sdl.Keymod.alt) != 0;
    const code: Key.Code = switch (event.key) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .pageup => .page_up,
        .pagedown => .page_down,
        .backspace => .backspace,
        .delete => .delete,
        .@"return", .kp_enter => .enter,
        .a => .a,
        .c => .c,
        .v => .v,
        .x => .x,
        else => return null,
    };
    return .{ .code = code, .shift = shift, .primary = primary, .alt = alt };
}

fn previousOffset(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var cursor = offset - 1;
    while (cursor > 0 and (text[cursor] & 0b1100_0000) == 0b1000_0000) {
        cursor -= 1;
    }
    return cursor;
}

fn nextOffset(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return @min(offset + len, text.len);
}

fn clippedRect(rect: draw.Rect, clip: draw.Rect) ?draw.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn lineStart(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and text[cursor - 1] != '\n') cursor -= 1;
    return cursor;
}

fn lineEnd(text: []const u8, offset: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, @min(offset, text.len), '\n') orelse text.len;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn previousWordOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and !isWordByte(text[cursor - 1])) cursor -= 1;
    while (cursor > 0 and isWordByte(text[cursor - 1])) cursor -= 1;
    return cursor;
}

fn nextWordOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor < text.len and isWordByte(text[cursor])) cursor += 1;
    while (cursor < text.len and !isWordByte(text[cursor])) cursor += 1;
    return cursor;
}

fn wordRangeAt(text: []const u8, offset: usize) struct { start: usize, end: usize } {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    var cursor = @min(offset, text.len - 1);
    if (!isWordByte(text[cursor]) and cursor > 0 and isWordByte(text[cursor - 1])) cursor -= 1;
    if (!isWordByte(text[cursor])) return .{ .start = cursor, .end = @min(cursor + 1, text.len) };
    var start = cursor;
    while (start > 0 and isWordByte(text[start - 1])) start -= 1;
    var end = cursor;
    while (end < text.len and isWordByte(text[end])) end += 1;
    return .{ .start = start, .end = end };
}

fn visualColumn(line_prefix: []const u8) usize {
    var index: usize = 0;
    var column: usize = 0;
    while (index < line_prefix.len) : (column += 1) {
        index = nextOffset(line_prefix, index);
    }
    return column;
}

fn offsetAtColumn(text: []const u8, start: usize, end: usize, target_column: usize) usize {
    var offset = start;
    var column: usize = 0;
    while (offset < end and column < target_column) : (column += 1) {
        offset = nextOffset(text, offset);
    }
    return offset;
}

test "text area edits retained buffer" {
    const Area = TextArea(.{});
    var area = try Area.init(std.testing.allocator, "hello");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .text = "!" }));
    try std.testing.expectEqualStrings("hello!", area.text());
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqualStrings("hello", area.text());
}

test "text area clamps stale selection before backspace" {
    const Area = TextArea(.{});
    var area = try Area.init(std.testing.allocator, "abc");
    defer area.deinit(std.testing.allocator);
    area.focused = true;
    area.cursor = 999;
    area.selection_anchor = 1;
    area.selection_focus = 999;

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqualStrings("a", area.text());
    try std.testing.expectEqual(@as(usize, 1), area.cursor);
    try std.testing.expect(area.selection() == null);
}

test "text area click type backspace keeps cursor and buffer in range" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 200, .height = 80 });
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = 10, .y = 10 } } }));
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .text = "z" }));
    try std.testing.expectEqualStrings("z", area.text());
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqualStrings("", area.text());
    try std.testing.expectEqual(@as(usize, 0), area.cursor);
}

test "text area wraps cursor position by default" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 22, .height = 80, .padding_x = 0, .padding_y = 0, .font_size = 10 });
    var area = try Area.init(std.testing.allocator, "abcdef");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try area.render(std.testing.allocator, &batch);

    const cursor = batch.commands.items[batch.commands.items.len - 1];
    try std.testing.expectEqual(draw.CommandKind.cursor, cursor.kind);
    try std.testing.expect(cursor.rect.y > 0);
}

test "text area maps clicks onto wrapped rows" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 22, .height = 80, .padding_x = 0, .padding_y = 0, .font_size = 10 });
    var area = try Area.init(std.testing.allocator, "abcdef");
    defer area.deinit(std.testing.allocator);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = 6, .y = 13 } } }));
    try std.testing.expectEqual(@as(usize, 5), area.cursor);
}

test "text area double and triple click select word and line" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 400, .height = 120, .padding_x = 0, .padding_y = 0, .glyph_width = 10, .line_height = 10 });
    var area = try Area.init(std.testing.allocator, "hello world\nsecond line");
    defer area.deinit(std.testing.allocator);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = 70, .y = 0 }, .clicks = 2 } }));
    try std.testing.expectEqualStrings("world", area.text()[area.selection().?.start..area.selection().?.end]);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = 10, .y = 10 }, .clicks = 3 } }));
    try std.testing.expectEqualStrings("second line", area.text()[area.selection().?.start..area.selection().?.end]);
}

test "text area ignores hover motion without pressed button" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 400, .height = 120, .padding_x = 0, .padding_y = 0, .glyph_width = 10, .line_height = 10 });
    var area = try Area.init(std.testing.allocator, "hello world");
    defer area.deinit(std.testing.allocator);
    area.focused = true;
    area.cursor = 0;

    var event: sdl.Event = undefined;
    event.motion = .{
        .type = .mouse_motion,
        .reserved = 0,
        .timestamp = 0,
        .window_id = .invalid,
        .which = @enumFromInt(0),
        .state = .{},
        .x = 70,
        .y = 0,
        .xrel = 0,
        .yrel = 0,
    };

    try std.testing.expect(!try area.update(std.testing.allocator, &event));
    try std.testing.expectEqual(@as(usize, 0), area.cursor);
    try std.testing.expect(area.selection() == null);
}

test "text area supports word and page navigation" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 400, .height = 20, .padding_x = 0, .padding_y = 0, .glyph_width = 10, .line_height = 10 });
    var area = try Area.init(std.testing.allocator, "alpha beta\nsecond\nthird\nfourth");
    defer area.deinit(std.testing.allocator);
    area.focused = true;
    area.cursor = area.text().len;

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .left, .primary = true } }));
    try std.testing.expectEqualStrings("fourth", area.text()[area.cursor..]);

    area.cursor = 0;
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .right, .primary = true } }));
    try std.testing.expectEqual(@as(usize, 6), area.cursor);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .page_down } }));
    try std.testing.expect(area.cursor > 5);
}

test "text area can disable wrapping" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 22, .height = 80, .padding_x = 0, .padding_y = 0, .font_size = 10, .wrap = false });
    var area = try Area.init(std.testing.allocator, "abcdef");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try area.render(std.testing.allocator, &batch);

    const cursor = batch.commands.items[batch.commands.items.len - 1];
    try std.testing.expectEqual(@as(f32, 0), cursor.rect.y);
}

test "text area scrolls cursor into visible bounds" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 100, .height = 24, .padding_x = 0, .padding_y = 0, .font_size = 10, .line_height = 10 });
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .text = "one\ntwo\nthree\nfour" }));
    try std.testing.expect(area.scrollY() > 0);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try area.render(std.testing.allocator, &batch);

    const cursor = batch.commands.items[batch.commands.items.len - 3];
    try std.testing.expectEqual(draw.CommandKind.cursor, cursor.kind);
    try std.testing.expect(cursor.rect.y >= 0);
    try std.testing.expect(cursor.rect.y + cursor.rect.h <= 24);
}

test "text area renders scrollbar only when content overflows" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 100, .height = 24, .padding_x = 0, .padding_y = 0, .font_size = 10, .line_height = 10, .scrollbar_width = 5 });
    var short = try Area.init(std.testing.allocator, "one");
    defer short.deinit(std.testing.allocator);
    var long = try Area.init(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer long.deinit(std.testing.allocator);
    long.focused = true;
    _ = try long.handleInput(std.testing.allocator, .{ .key = .{ .code = .end } });

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try short.render(std.testing.allocator, &batch);
    for (batch.commands.items) |command| {
        try std.testing.expect(command.kind != .scrollbar);
    }

    batch.clear();
    try long.render(std.testing.allocator, &batch);
    var scrollbar_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .scrollbar) {
            scrollbar_count += 1;
            try std.testing.expect(command.rect.x >= 95);
            try std.testing.expect(command.rect.x + command.rect.w <= 100);
            try std.testing.expect(command.rect.y >= 0);
            try std.testing.expect(command.rect.y + command.rect.h <= 24);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), scrollbar_count);
}

test "text area scrolls with mouse wheel inside bounds" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 100, .height = 24, .padding_x = 0, .padding_y = 0, .font_size = 10, .line_height = 10 });
    var area = try Area.init(std.testing.allocator, "one\ntwo\nthree\nfour\nfive");
    defer area.deinit(std.testing.allocator);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_wheel = .{ .point = .{ .x = 10, .y = 10 }, .y = -1 } }));
    try std.testing.expect(area.scrollY() > 0);
    const after_inside_scroll = area.scrollY();

    try std.testing.expect(!try area.handleInput(std.testing.allocator, .{ .mouse_wheel = .{ .point = .{ .x = 200, .y = 10 }, .y = -1 } }));
    try std.testing.expectEqual(after_inside_scroll, area.scrollY());
}

test "text area drags scrollbar thumb" {
    const Area = TextArea(.{ .x = 0, .y = 0, .width = 100, .height = 24, .padding_x = 0, .padding_y = 0, .font_size = 10, .line_height = 10, .scrollbar_width = 5 });
    var area = try Area.init(std.testing.allocator, "one\ntwo\nthree\nfour\nfive\nsix");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = 97, .y = 2 } } }));
    try std.testing.expect(area.dragging_scrollbar);
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_drag = .{ .x = 97, .y = 22 } }));
    try std.testing.expect(area.scrollY() > 0);
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .mouse_up = .{ .x = 97, .y = 22 } }));
    try std.testing.expect(!area.dragging_scrollbar);
}

test "text area exposes placeholder state" {
    const Area = TextArea(.{ .placeholder_text = "Write a prompt" });
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);

    try std.testing.expect(area.placeholderVisible());
    try std.testing.expectEqualStrings("Write a prompt", area.placeholder());

    area.focused = true;
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .text = "x" }));
    try std.testing.expect(!area.placeholderVisible());
}

test "text area read only and max bytes block edits" {
    const ReadOnly = TextArea(.{ .read_only = true });
    var read_only = try ReadOnly.init(std.testing.allocator, "abc");
    defer read_only.deinit(std.testing.allocator);
    read_only.focused = true;
    try std.testing.expect(!try read_only.handleInput(std.testing.allocator, .{ .text = "d" }));
    try std.testing.expectEqualStrings("abc", read_only.text());

    const Limited = TextArea(.{ .max_bytes = 3 });
    var limited = try Limited.init(std.testing.allocator, "abc");
    defer limited.deinit(std.testing.allocator);
    limited.focused = true;
    try std.testing.expect(try limited.handleInput(std.testing.allocator, .{ .text = "d" }));
    try std.testing.expectEqualStrings("abc", limited.text());
}

fn rejectBang(_: ?*anyopaque, _: []const u8, replacement: []const u8, _: usize, _: usize) bool {
    return std.mem.indexOfScalar(u8, replacement, '!') == null;
}

test "text area validation callback can reject edits" {
    const Area = TextArea(.{});
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);
    area.focused = true;
    area.setCallbacks(.{ .validate_edit = rejectBang });

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .text = "ok" }));
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .text = "!" }));
    try std.testing.expectEqualStrings("ok", area.text());
}

test "text area cursor blink can be ticked" {
    const Area = TextArea(.{ .cursor_blink_ms = 10 });
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    try std.testing.expect(area.cursor_visible);
    area.tick(10);
    try std.testing.expect(!area.cursor_visible);
    area.tick(10);
    try std.testing.expect(area.cursor_visible);
}

test "text area emits composition events without editing buffer" {
    const Area = TextArea(.{});
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    var probe: CallbackProbe = .{};
    defer probe.clipboard.deinit(std.testing.allocator);
    area.setCallbacks(.{ .context = &probe, .on_event = probeTextAreaEvent });

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .composition = "compose" }));
    try std.testing.expectEqual(@as(usize, 1), probe.compositions);
    try std.testing.expectEqualStrings("", area.text());
}

test "text area clips selection to text bounds" {
    const Area = TextArea(.{ .x = 5, .y = 7, .width = 35, .height = 24, .padding_x = 2, .padding_y = 3, .font_size = 10, .line_height = 10 });
    var area = try Area.init(std.testing.allocator, "abc\ndef\nghi\njkl");
    defer area.deinit(std.testing.allocator);
    area.focused = true;
    area.selection_anchor = 0;
    area.selection_focus = area.text().len;

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try area.render(std.testing.allocator, &batch);

    const clip: draw.Rect = .{ .x = 7, .y = 10, .w = 31, .h = 18 };
    for (batch.commands.items) |command| {
        if (command.kind != .selection) continue;
        try std.testing.expect(command.rect.x >= clip.x);
        try std.testing.expect(command.rect.y >= clip.y);
        try std.testing.expect(command.rect.x + command.rect.w <= clip.x + clip.w);
        try std.testing.expect(command.rect.y + command.rect.h <= clip.y + clip.h);
    }
}

const CallbackProbe = struct {
    changed: usize = 0,
    submitted: usize = 0,
    compositions: usize = 0,
    clipboard: std.ArrayList(u8) = .empty,
};

fn probeTextAreaEvent(context: ?*anyopaque, event: TextAreaEvent) void {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => probe.changed += 1,
        .submitted => probe.submitted += 1,
        .composition => probe.compositions += 1,
        else => {},
    }
}

fn probeTextAreaKey(context: ?*anyopaque, key: Key) TextAreaAction {
    _ = context;
    if (key.code == .enter and key.shift) return .insert_newline;
    if (key.code == .enter) return .submit;
    return .default;
}

fn probeSetClipboard(context: ?*anyopaque, text: []const u8) bool {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return false));
    probe.clipboard.clearRetainingCapacity();
    probe.clipboard.appendSlice(std.testing.allocator, text) catch return false;
    return true;
}

fn probeGetClipboard(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return null));
    return allocator.dupe(u8, probe.clipboard.items) catch null;
}

test "text area callbacks can bind enter and shift enter" {
    const Area = TextArea(.{});
    var area = try Area.init(std.testing.allocator, "");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    var probe: CallbackProbe = .{};
    area.setCallbacks(.{
        .context = &probe,
        .on_event = probeTextAreaEvent,
        .on_key = probeTextAreaKey,
    });

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .enter, .shift = true } }));
    try std.testing.expectEqualStrings("\n", area.text());
    try std.testing.expectEqual(@as(usize, 1), probe.changed);

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .enter } }));
    try std.testing.expect(area.submitted);
    try std.testing.expectEqual(@as(usize, 1), probe.submitted);
}

test "text area clipboard callbacks handle copy cut and paste" {
    const Area = TextArea(.{});
    var area = try Area.init(std.testing.allocator, "hello world");
    defer area.deinit(std.testing.allocator);
    area.focused = true;

    var probe: CallbackProbe = .{};
    defer probe.clipboard.deinit(std.testing.allocator);
    area.setCallbacks(.{
        .context = &probe,
        .set_clipboard = probeSetClipboard,
        .get_clipboard = probeGetClipboard,
    });

    area.selection_anchor = 0;
    area.selection_focus = 5;
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .c, .primary = true } }));
    try std.testing.expectEqualStrings("hello", probe.clipboard.items);
    try std.testing.expectEqualStrings("hello world", area.text());

    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .x, .primary = true } }));
    try std.testing.expectEqualStrings(" world", area.text());

    area.cursor = area.text().len;
    try std.testing.expect(try area.handleInput(std.testing.allocator, .{ .key = .{ .code = .v, .primary = true } }));
    try std.testing.expectEqualStrings(" worldhello", area.text());
}

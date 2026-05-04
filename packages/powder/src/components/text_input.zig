//! Retained single-line text input component.

const std = @import("std");

const draw = @import("../draw.zig");
const clipboard = @import("../input/clipboard.zig");
const Key = @import("../input/key.zig");
const selection_input = @import("../input/selection.zig");
const sdl = @import("../sdl.zig");

pub const TextInputConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 240.0,
    height: f32 = 32.0,
    padding_x: f32 = 8.0,
    padding_y: f32 = 6.0,
    background_color: draw.Color = .{ .r = 0.07, .g = 0.08, .b = 0.09, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.18, .g = 0.21, .b = 0.24, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    cursor_color: draw.Color = draw.Color.white,
    selection_color: draw.Color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    placeholder_text: []const u8 = "",
    placeholder_color: draw.Color = .{ .r = 0.50, .g = 0.56, .b = 0.65, .a = 0.76 },
    read_only: bool = false,
    max_bytes: ?usize = null,
    cursor_blink_ms: u32 = 530,
    font_size: f32 = 16.0,
    glyph_width: ?f32 = null,
    submit_on_enter: bool = true,
};

pub const Input = union(enum) {
    text: []const u8,
    key: Key,
    mouse_down: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    composition: []const u8,
};

pub const TextInputAction = enum {
    default,
    handled,
    submit,
};

pub const TextInputEvent = union(enum) {
    changed: []const u8,
    submitted: []const u8,
    key: Key,
    focus_changed: bool,
    composition: []const u8,
};

pub const TextInputCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: TextInputEvent) void = null,
    on_key: ?*const fn (context: ?*anyopaque, key: Key) TextInputAction = null,
    validate_edit: ?*const fn (context: ?*anyopaque, current: []const u8, replacement: []const u8, start: usize, end: usize) bool = null,
    set_clipboard: ?*const fn (context: ?*anyopaque, text: []const u8) bool = null,
    get_clipboard: ?*const fn (context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,

    fn clipboardProvider(self: TextInputCallbacks) clipboard {
        return .{ .context = self.context, .set = self.set_clipboard, .get = self.get_clipboard };
    }
};

pub fn TextInput(comptime config: TextInputConfig) type {
    return struct {
        const Component = @This();

        buffer: std.ArrayList(u8) = .empty,
        cursor: usize = 0,
        selection_anchor: ?usize = null,
        selection_focus: ?usize = null,
        focused: bool = false,
        submitted: bool = false,
        scroll_x: f32 = 0.0,
        cursor_visible: bool = true,
        cursor_elapsed_ms: u32 = 0,
        dragging_selection: bool = false,
        callbacks: TextInputCallbacks = .{},

        pub fn init(allocator: std.mem.Allocator, initial: []const u8) !Component {
            var self: Component = .{};
            try self.buffer.appendSlice(allocator, sanitize(initial));
            self.cursor = self.buffer.items.len;
            self.ensureCursorVisible();
            return self;
        }

        pub fn deinit(self: *Component, allocator: std.mem.Allocator) void {
            self.buffer.deinit(allocator);
            self.* = undefined;
        }

        pub fn text(self: *const Component) []const u8 {
            return self.buffer.items;
        }

        pub fn placeholderVisible(self: *const Component) bool {
            return self.buffer.items.len == 0 and config.placeholder_text.len > 0;
        }

        pub fn selection(self: *const Component) ?selection_input.Range {
            const state: selection_input = .{ .anchor = self.selection_anchor, .focus = self.selection_focus };
            return state.normalized(self.buffer.items.len);
        }

        pub fn clearSelection(self: *Component) void {
            self.selection_anchor = null;
            self.selection_focus = null;
        }

        pub fn setCallbacks(self: *Component, callbacks: TextInputCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn update(self: *Component, allocator: std.mem.Allocator, event: *const sdl.Event) !bool {
            switch (event.type) {
                .text_input => return try self.handleInput(allocator, .{ .text = std.mem.span(event.text.text) }),
                .text_editing => return try self.handleInput(allocator, .{ .composition = std.mem.span(event.edit.text) }),
                .key_down => return try self.handleInput(allocator, .{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_button_down => return try self.handleInput(allocator, .{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_button_up => return try self.handleInput(allocator, .{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_motion => {
                    if (!self.dragging_selection or !event.motion.state.left) return false;
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
                    try self.replaceSelectionOrInsert(allocator, sanitize(value));
                    return true;
                },
                .key => |key| return try self.handleKey(allocator, key),
                .composition => |value| {
                    if (!self.focused) return false;
                    self.emit(.{ .composition = value });
                    return true;
                },
                .mouse_down => |point| {
                    const was_focused = self.focused;
                    self.focused = Component.bounds().contains(point);
                    if (self.focused != was_focused) self.emit(.{ .focus_changed = self.focused });
                    if (!self.focused) return false;
                    self.cursor = self.byteOffsetForPoint(point);
                    self.selection_anchor = self.cursor;
                    self.selection_focus = self.cursor;
                    self.dragging_selection = true;
                    self.ensureCursorVisible();
                    return true;
                },
                .mouse_drag => |point| {
                    if (!self.dragging_selection) return false;
                    if (self.selection_anchor == null) self.selection_anchor = self.cursor;
                    self.cursor = self.byteOffsetForPoint(point);
                    self.selection_focus = self.cursor;
                    self.ensureCursorVisible();
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_selection;
                    self.dragging_selection = false;
                    if (self.selection() == null) self.clearSelection();
                    return was_dragging;
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
            try batch.rect(allocator, Component.bounds(), config.background_color);
            try batch.rect(allocator, .{ .x = config.x, .y = config.y, .w = config.width, .h = 1.0 }, config.border_color);
            if (self.selection()) |range| try self.renderSelection(allocator, batch, range);
            const glyph_w = if (self.placeholderVisible()) approximateWidth(config.placeholder_text.len) else approximateWidth(self.buffer.items.len);
            try batch.glyph(allocator, .{
                .x = config.x + config.padding_x - self.scroll_x,
                .y = config.y + config.padding_y,
                .w = @min(glyph_w, Component.textRect().w),
                .h = Component.textRect().h,
            }, .{}, if (self.placeholderVisible()) config.placeholder_color else config.text_color);
            if (self.focused and self.cursor_visible) {
                const x = self.cursorX();
                if (x >= Component.textRect().x and x <= Component.textRect().x + Component.textRect().w) {
                    try batch.cursor(allocator, .{ .x = x, .y = Component.textRect().y, .w = 1.5, .h = Component.textRect().h }, config.cursor_color);
                }
            }
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
            if (key.primary and key.code == .c) return self.copySelection();
            if (key.primary and key.code == .x) return if (config.read_only) false else try self.cutSelection(allocator);
            if (key.primary and key.code == .v) return if (config.read_only) false else try self.pasteClipboard(allocator);
            switch (key.code) {
                .left => self.moveCursor(if (key.primary or key.alt) selection_input.previousWordOffset(self.buffer.items, self.cursor) else selection_input.previousOffset(self.buffer.items, self.cursor), key.shift),
                .right => self.moveCursor(if (key.primary or key.alt) selection_input.nextWordOffset(self.buffer.items, self.cursor) else selection_input.nextOffset(self.buffer.items, self.cursor), key.shift),
                .home => self.moveCursor(if (key.primary) @as(usize, 0) else 0, key.shift),
                .end => self.moveCursor(self.buffer.items.len, key.shift),
                .backspace => if (!config.read_only) try self.deleteBack(allocator),
                .delete => if (!config.read_only) try self.deleteForward(allocator),
                .enter => if (config.submit_on_enter) self.submit() else return false,
                else => return false,
            }
            return true;
        }

        fn replaceSelectionOrInsert(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            self.normalizeState();
            const range = self.selection();
            const start = if (range) |selected| selected.start else self.cursor;
            const end = if (range) |selected| selected.end else self.cursor;
            if (!self.canApplyEdit(value, start, end)) return;
            try self.buffer.replaceRange(allocator, start, end - start, value);
            self.cursor = start + value.len;
            self.clearSelection();
            self.ensureCursorVisible();
            self.emit(.{ .changed = self.buffer.items });
        }

        fn canApplyEdit(self: *const Component, replacement: []const u8, start: usize, end: usize) bool {
            if (config.read_only) return false;
            if (config.max_bytes) |max_bytes| {
                if (self.buffer.items.len - (end - start) + replacement.len > max_bytes) return false;
            }
            if (self.callbacks.validate_edit) |callback| {
                if (!callback(self.callbacks.context, self.buffer.items, replacement, start, end)) return false;
            }
            return true;
        }

        fn deleteBack(self: *Component, allocator: std.mem.Allocator) !void {
            if (self.selection()) |_| return self.replaceSelectionOrInsert(allocator, "");
            if (self.cursor == 0) return;
            const start = selection_input.previousOffset(self.buffer.items, self.cursor);
            try self.buffer.replaceRange(allocator, start, self.cursor - start, "");
            self.cursor = start;
            self.ensureCursorVisible();
            self.emit(.{ .changed = self.buffer.items });
        }

        fn deleteForward(self: *Component, allocator: std.mem.Allocator) !void {
            if (self.selection()) |_| return self.replaceSelectionOrInsert(allocator, "");
            if (self.cursor >= self.buffer.items.len) return;
            const end = selection_input.nextOffset(self.buffer.items, self.cursor);
            try self.buffer.replaceRange(allocator, self.cursor, end - self.cursor, "");
            self.ensureCursorVisible();
            self.emit(.{ .changed = self.buffer.items });
        }

        fn copySelection(self: *Component) bool {
            const range = self.selection() orelse return false;
            return self.callbacks.clipboardProvider().write(self.buffer.items[range.start..range.end]);
        }

        fn cutSelection(self: *Component, allocator: std.mem.Allocator) !bool {
            if (!self.copySelection()) return false;
            try self.replaceSelectionOrInsert(allocator, "");
            return true;
        }

        fn pasteClipboard(self: *Component, allocator: std.mem.Allocator) !bool {
            const value = self.callbacks.clipboardProvider().read(allocator) orelse return false;
            defer allocator.free(value);
            try self.replaceSelectionOrInsert(allocator, sanitize(value));
            return true;
        }

        fn submit(self: *Component) void {
            self.submitted = true;
            self.emit(.{ .submitted = self.buffer.items });
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
            var state: selection_input = .{ .anchor = self.selection_anchor, .focus = self.selection_focus };
            state.clamp(self.buffer.items.len);
            self.selection_anchor = state.anchor;
            self.selection_focus = state.focus;
            self.ensureScrollBounds();
        }

        fn byteOffsetForPoint(self: *const Component, point: draw.Vec2) usize {
            const col_float = @max(point.x - config.x - config.padding_x + self.scroll_x, 0.0) / Component.glyphWidth();
            var offset: usize = 0;
            var col: usize = 0;
            while (offset < self.buffer.items.len and col < @as(usize, @intFromFloat(@floor(col_float)))) : (col += 1) {
                offset = selection_input.nextOffset(self.buffer.items, offset);
            }
            return offset;
        }

        fn renderSelection(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, range: selection_input.Range) !void {
            const start_x = self.xForOffset(range.start);
            const end_x = self.xForOffset(range.end);
            const x0 = @max(start_x, Component.textRect().x);
            const x1 = @min(end_x, Component.textRect().x + Component.textRect().w);
            if (x1 <= x0) return;
            try batch.selection(allocator, .{ .x = x0, .y = Component.textRect().y, .w = @max(x1 - x0, 2.0), .h = Component.textRect().h }, config.selection_color);
        }

        fn cursorX(self: *const Component) f32 {
            return self.xForOffset(self.cursor);
        }

        fn xForOffset(self: *const Component, offset: usize) f32 {
            return config.x + config.padding_x + @as(f32, @floatFromInt(self.visualColumnForOffset(offset))) * Component.glyphWidth() - self.scroll_x;
        }

        fn visualColumnForOffset(self: *const Component, offset: usize) usize {
            var index: usize = 0;
            var column: usize = 0;
            while (index < @min(offset, self.buffer.items.len)) : (column += 1) {
                index = selection_input.nextOffset(self.buffer.items, index);
            }
            return column;
        }

        fn ensureCursorVisible(self: *Component) void {
            const cursor_left = @as(f32, @floatFromInt(self.visualColumnForOffset(self.cursor))) * Component.glyphWidth();
            const visible_w = Component.textRect().w;
            if (cursor_left < self.scroll_x) {
                self.scroll_x = cursor_left;
            } else if (cursor_left + Component.glyphWidth() > self.scroll_x + visible_w) {
                self.scroll_x = cursor_left + Component.glyphWidth() - visible_w;
            }
            self.ensureScrollBounds();
        }

        fn ensureScrollBounds(self: *Component) void {
            self.scroll_x = @min(@max(self.scroll_x, 0.0), @max(approximateWidth(self.buffer.items.len) - Component.textRect().w, 0.0));
        }

        fn emit(self: *Component, event: TextInputEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn textRect() draw.Rect {
            return .{ .x = config.x + config.padding_x, .y = config.y + config.padding_y, .w = @max(config.width - config.padding_x * 2.0, Component.glyphWidth()), .h = @max(config.height - config.padding_y * 2.0, config.font_size) };
        }

        fn glyphWidth() f32 {
            return config.glyph_width orelse config.font_size * 0.55;
        }

        fn approximateWidth(len: usize) f32 {
            return @as(f32, @floatFromInt(len)) * Component.glyphWidth();
        }
    };
}

fn sanitize(value: []const u8) []const u8 {
    return value[0 .. std.mem.indexOfScalar(u8, value, '\n') orelse value.len];
}

const Probe = struct {
    changed: usize = 0,
    submitted: usize = 0,
    clipboard: std.ArrayList(u8) = .empty,
};

fn probeEvent(context: ?*anyopaque, event: TextInputEvent) void {
    const probe: *Probe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => probe.changed += 1,
        .submitted => probe.submitted += 1,
        else => {},
    }
}

fn setClipboard(context: ?*anyopaque, text: []const u8) bool {
    const probe: *Probe = @ptrCast(@alignCast(context orelse return false));
    probe.clipboard.clearRetainingCapacity();
    probe.clipboard.appendSlice(std.testing.allocator, text) catch return false;
    return true;
}

fn getClipboard(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    const probe: *Probe = @ptrCast(@alignCast(context orelse return null));
    return allocator.dupe(u8, probe.clipboard.items) catch null;
}

test "text input edits single line buffer" {
    const InputBox = TextInput(.{});
    var input = try InputBox.init(std.testing.allocator, "hi");
    defer input.deinit(std.testing.allocator);
    input.focused = true;

    try std.testing.expect(try input.handleInput(std.testing.allocator, .{ .text = "!\nignored" }));
    try std.testing.expectEqualStrings("hi!", input.text());
    try std.testing.expect(try input.handleInput(std.testing.allocator, .{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqualStrings("hi", input.text());
}

test "text input selects copies cuts and pastes" {
    const InputBox = TextInput(.{});
    var input = try InputBox.init(std.testing.allocator, "hello world");
    defer input.deinit(std.testing.allocator);
    input.focused = true;
    var probe: Probe = .{};
    defer probe.clipboard.deinit(std.testing.allocator);
    input.setCallbacks(.{ .context = &probe, .set_clipboard = setClipboard, .get_clipboard = getClipboard });

    input.selection_anchor = 0;
    input.selection_focus = 5;
    try std.testing.expect(try input.handleInput(std.testing.allocator, .{ .key = .{ .code = .c, .primary = true } }));
    try std.testing.expectEqualStrings("hello", probe.clipboard.items);
    try std.testing.expect(try input.handleInput(std.testing.allocator, .{ .key = .{ .code = .x, .primary = true } }));
    try std.testing.expectEqualStrings(" world", input.text());
    try std.testing.expect(try input.handleInput(std.testing.allocator, .{ .key = .{ .code = .v, .primary = true } }));
    try std.testing.expectEqualStrings("hello world", input.text());
}

test "text input submits on enter" {
    const InputBox = TextInput(.{});
    var input = try InputBox.init(std.testing.allocator, "go");
    defer input.deinit(std.testing.allocator);
    input.focused = true;
    var probe: Probe = .{};
    input.setCallbacks(.{ .context = &probe, .on_event = probeEvent });

    try std.testing.expect(try input.handleInput(std.testing.allocator, .{ .key = .{ .code = .enter } }));
    try std.testing.expect(input.submitted);
    try std.testing.expectEqual(@as(usize, 1), probe.submitted);
}

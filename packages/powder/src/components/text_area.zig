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
    font_size: f32 = 16.0,
    submit_on_enter: bool = false,
};

pub const Input = union(enum) {
    text: []const u8,
    key: Key,
    mouse_down: draw.Vec2,
    mouse_drag: draw.Vec2,
};

pub const Key = struct {
    code: Code,
    shift: bool = false,
    primary: bool = false,

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
        a,
    };
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

        pub fn selection(self: *const Component) ?struct { start: usize, end: usize } {
            const anchor = self.selection_anchor orelse return null;
            const focus = self.selection_focus orelse return null;
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

        pub fn update(self: *Component, allocator: std.mem.Allocator, event: *const sdl.Event) !bool {
            switch (event.type) {
                .text_input => return try self.handleInput(allocator, .{ .text = std.mem.span(event.text.text) }),
                .key_down => return try self.handleInput(allocator, .{ .key = keyFromSdl(event.key) orelse return false }),
                .mouse_button_down => return try self.handleInput(allocator, .{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_motion => {
                    if (!self.focused) return false;
                    return try self.handleInput(allocator, .{ .mouse_drag = .{ .x = event.motion.x, .y = event.motion.y } });
                },
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, allocator: std.mem.Allocator, input: Input) !bool {
            self.submitted = false;
            switch (input) {
                .text => |value| {
                    if (!self.focused) return false;
                    try self.replaceSelectionOrInsert(allocator, value);
                    return true;
                },
                .key => |key| return try self.handleKey(allocator, key),
                .mouse_down => |point| {
                    self.focused = Component.bounds().contains(point);
                    if (!self.focused) return false;
                    self.cursor = self.byteOffsetForPoint(point);
                    self.selection_anchor = self.cursor;
                    self.selection_focus = self.cursor;
                    return true;
                },
                .mouse_drag => |point| {
                    if (!self.focused) return false;
                    if (self.selection_anchor == null) self.selection_anchor = self.cursor;
                    self.cursor = self.byteOffsetForPoint(point);
                    self.selection_focus = self.cursor;
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.rect(allocator, Component.bounds(), config.background_color);
            try batch.rect(allocator, .{ .x = config.x, .y = config.y, .w = config.width, .h = 1.0 }, config.border_color);
            if (self.selection()) |range| {
                try self.renderSelection(allocator, batch, range.start, range.end);
            }
            try batch.glyph(allocator, Component.textRect(), .{}, config.text_color);
            if (self.focused) {
                const pos = self.cursorPosition();
                try batch.rect(allocator, .{ .x = pos.x, .y = pos.y, .w = 1.5, .h = lineHeight() }, config.cursor_color);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, allocator: std.mem.Allocator, key: Key) !bool {
            if (!self.focused and key.code != .a) return false;
            if (key.primary and key.code == .a) {
                self.selection_anchor = 0;
                self.selection_focus = self.buffer.items.len;
                self.cursor = self.buffer.items.len;
                return true;
            }
            switch (key.code) {
                .left => self.moveCursor(previousOffset(self.buffer.items, self.cursor), key.shift),
                .right => self.moveCursor(nextOffset(self.buffer.items, self.cursor), key.shift),
                .home => self.moveCursor(lineStart(self.buffer.items, self.cursor), key.shift),
                .end => self.moveCursor(lineEnd(self.buffer.items, self.cursor), key.shift),
                .up => self.moveCursor(self.verticalMove(-1), key.shift),
                .down => self.moveCursor(self.verticalMove(1), key.shift),
                .backspace => try self.deleteBack(allocator),
                .delete => try self.deleteForward(allocator),
                .enter => {
                    if (config.submit_on_enter and !key.shift) {
                        self.submitted = true;
                    } else {
                        try self.replaceSelectionOrInsert(allocator, "\n");
                    }
                },
                else => return false,
            }
            return true;
        }

        fn replaceSelectionOrInsert(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            if (self.selection()) |range| {
                self.buffer.replaceRange(allocator, range.start, range.end - range.start, value) catch |err| return err;
                self.cursor = range.start + value.len;
            } else {
                try self.buffer.insertSlice(allocator, self.cursor, value);
                self.cursor += value.len;
            }
            self.clearSelection();
        }

        fn deleteBack(self: *Component, allocator: std.mem.Allocator) !void {
            if (self.selection()) |_| return self.replaceSelectionOrInsert(allocator, "");
            if (self.cursor == 0) return;
            const start = previousOffset(self.buffer.items, self.cursor);
            self.buffer.replaceRange(allocator, start, self.cursor - start, "") catch |err| return err;
            self.cursor = start;
        }

        fn deleteForward(self: *Component, allocator: std.mem.Allocator) !void {
            if (self.selection()) |_| return self.replaceSelectionOrInsert(allocator, "");
            if (self.cursor >= self.buffer.items.len) return;
            const end = nextOffset(self.buffer.items, self.cursor);
            self.buffer.replaceRange(allocator, self.cursor, end - self.cursor, "") catch |err| return err;
        }

        fn moveCursor(self: *Component, next: usize, selecting: bool) void {
            if (selecting) {
                if (self.selection_anchor == null) self.selection_anchor = self.cursor;
                self.selection_focus = next;
            } else {
                self.clearSelection();
            }
            self.cursor = @min(next, self.buffer.items.len);
        }

        fn renderSelection(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, start: usize, end: usize) !void {
            const start_pos = self.positionForOffset(start);
            const end_pos = self.positionForOffset(end);
            if (start_pos.y == end_pos.y) {
                try batch.rect(allocator, .{ .x = start_pos.x, .y = start_pos.y, .w = @max(end_pos.x - start_pos.x, 2.0), .h = lineHeight() }, config.selection_color);
                return;
            }
            try batch.rect(allocator, .{ .x = start_pos.x, .y = start_pos.y, .w = config.x + config.width - config.padding_x - start_pos.x, .h = lineHeight() }, config.selection_color);
            var y = start_pos.y + lineHeight();
            while (y < end_pos.y) : (y += lineHeight()) {
                try batch.rect(allocator, .{ .x = config.x + config.padding_x, .y = y, .w = config.width - config.padding_x * 2.0, .h = lineHeight() }, config.selection_color);
            }
            try batch.rect(allocator, .{ .x = config.x + config.padding_x, .y = end_pos.y, .w = @max(end_pos.x - (config.x + config.padding_x), 2.0), .h = lineHeight() }, config.selection_color);
        }

        fn byteOffsetForPoint(self: *const Component, point: draw.Vec2) usize {
            const col = @max(point.x - config.x - config.padding_x, 0.0) / Component.glyphWidth();
            const target_col: usize = @intFromFloat(@max(col, 0.0));
            const row = @max(point.y - config.y - config.padding_y, 0.0) / Component.lineHeight();
            const target_row: usize = @intFromFloat(@max(row, 0.0));
            var row_index: usize = 0;
            var line_start_index: usize = 0;
            while (row_index < target_row) : (row_index += 1) {
                const next_line = std.mem.indexOfScalarPos(u8, self.buffer.items, line_start_index, '\n') orelse return self.buffer.items.len;
                line_start_index = next_line + 1;
            }
            var offset = line_start_index;
            var col_index: usize = 0;
            while (offset < self.buffer.items.len and self.buffer.items[offset] != '\n' and col_index < target_col) : (col_index += 1) {
                offset = nextOffset(self.buffer.items, offset);
            }
            return offset;
        }

        fn cursorPosition(self: *const Component) draw.Vec2 {
            return self.positionForOffset(self.cursor);
        }

        fn positionForOffset(self: *const Component, offset: usize) draw.Vec2 {
            var x = config.x + config.padding_x;
            var y = config.y + config.padding_y;
            var index: usize = 0;
            while (index < @min(offset, self.buffer.items.len)) {
                if (self.buffer.items[index] == '\n') {
                    x = config.x + config.padding_x;
                    y += Component.lineHeight();
                } else {
                    x += Component.glyphWidth();
                }
                index = nextOffset(self.buffer.items, index);
            }
            return .{ .x = x, .y = y };
        }

        fn verticalMove(self: *const Component, delta: i32) usize {
            const current_start = lineStart(self.buffer.items, self.cursor);
            const column = visualColumn(self.buffer.items[current_start..self.cursor]);
            if (delta < 0) {
                if (current_start == 0) return 0;
                const prev_end = current_start - 1;
                const prev_start = lineStart(self.buffer.items, prev_end);
                return offsetAtColumn(self.buffer.items, prev_start, prev_end, column);
            }
            const current_end = lineEnd(self.buffer.items, self.cursor);
            if (current_end >= self.buffer.items.len) return self.buffer.items.len;
            const next_start = current_end + 1;
            return offsetAtColumn(self.buffer.items, next_start, lineEnd(self.buffer.items, next_start), column);
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn textRect() draw.Rect {
            return .{ .x = config.x + config.padding_x, .y = config.y + config.padding_y, .w = config.width - config.padding_x * 2.0, .h = config.height - config.padding_y * 2.0 };
        }

        fn lineHeight() f32 {
            return config.font_size * 1.25;
        }

        fn glyphWidth() f32 {
            return config.font_size * 0.55;
        }
    };
}

fn keyFromSdl(event: sdl.KeyboardEvent) ?Key {
    const mod_bits = event.mod;
    const primary = (mod_bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    const shift = (mod_bits & sdl.Keymod.shift) != 0;
    const code: Key.Code = switch (event.key) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .backspace => .backspace,
        .delete => .delete,
        .@"return", .kp_enter => .enter,
        .a => .a,
        else => return null,
    };
    return .{ .code = code, .shift = shift, .primary = primary };
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

fn lineStart(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and text[cursor - 1] != '\n') cursor -= 1;
    return cursor;
}

fn lineEnd(text: []const u8, offset: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, @min(offset, text.len), '\n') orelse text.len;
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

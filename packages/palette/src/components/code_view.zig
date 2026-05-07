//! Retained monospace code/diff text viewer.

const std = @import("std");

const draw = @import("../draw.zig");
const selection_input = @import("../input/selection.zig");
const scroll = @import("../scroll.zig");

pub const CodeViewConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 520.0,
    height: f32 = 260.0,
    padding_x: f32 = 8.0,
    padding_y: f32 = 8.0,
    glyph_width: f32 = 8.0,
    line_height: f32 = 18.0,
    line_number_width: f32 = 48.0,
    background_color: draw.Color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    line_number_color: draw.Color = .{ .r = 0.44, .g = 0.49, .b = 0.56, .a = 1.0 },
    selection_color: draw.Color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    deletion_color: draw.Color = .{ .r = 0.44, .g = 0.13, .b = 0.15, .a = 0.55 },
    addition_color: draw.Color = .{ .r = 0.13, .g = 0.36, .b = 0.18, .a = 0.55 },
    show_line_numbers: bool = true,
};

pub const Input = union(enum) {
    mouse_down: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: f32,
};

pub fn CodeView(comptime config: CodeViewConfig) type {
    return struct {
        const Component = @This();

        buffer: std.ArrayList(u8) = .empty,
        selection_anchor: ?usize = null,
        selection_focus: ?usize = null,
        dragging_selection: bool = false,
        scroll_y: f32 = 0.0,

        pub fn init(allocator: std.mem.Allocator, initial: []const u8) !Component {
            var self: Component = .{};
            try self.buffer.appendSlice(allocator, initial);
            return self;
        }

        pub fn deinit(self: *Component, allocator: std.mem.Allocator) void {
            self.buffer.deinit(allocator);
            self.* = undefined;
        }

        pub fn text(self: *const Component) []const u8 {
            return self.buffer.items;
        }

        pub fn selection(self: *const Component) ?selection_input.Range {
            const state: selection_input = .{ .anchor = self.selection_anchor, .focus = self.selection_focus };
            return state.normalized(self.buffer.items.len);
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .mouse_down => |point| {
                    if (!Component.bounds().contains(point)) return false;
                    const offset = self.offsetAtPoint(point);
                    self.selection_anchor = offset;
                    self.selection_focus = offset;
                    self.dragging_selection = true;
                    return true;
                },
                .mouse_drag => |point| {
                    if (!self.dragging_selection) return false;
                    self.selection_focus = self.offsetAtPoint(point);
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_selection;
                    self.dragging_selection = false;
                    return was_dragging;
                },
                .mouse_wheel => |y| {
                    self.scroll_y = scroll.clampOffsetY(self.scroll_y - y * config.line_height * 3.0, self.metrics());
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.rect(allocator, Component.bounds(), config.background_color);
            if (self.selection()) |range| try self.renderSelection(allocator, batch, range);

            var line_index: usize = 0;
            var start: usize = 0;
            while (start <= self.buffer.items.len) : (line_index += 1) {
                const end = std.mem.indexOfScalarPos(u8, self.buffer.items, start, '\n') orelse self.buffer.items.len;
                const y = config.y + config.padding_y + @as(f32, @floatFromInt(line_index)) * config.line_height - self.scroll_y;
                if (y + config.line_height >= config.y and y <= config.y + config.height) {
                    try self.renderLine(allocator, batch, line_index, y, self.buffer.items[start..end]);
                }
                if (end == self.buffer.items.len) break;
                start = end + 1;
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn renderLine(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, line_index: usize, y: f32, line: []const u8) !void {
            _ = self;
            _ = line_index;
            if (line.len > 0 and (line[0] == '+' or line[0] == '-')) {
                try batch.selection(allocator, .{ .x = config.x, .y = y, .w = config.width, .h = config.line_height }, if (line[0] == '+') config.addition_color else config.deletion_color);
            }
            if (config.show_line_numbers) {
                try batch.glyph(allocator, .{ .x = config.x + config.padding_x, .y = y, .w = config.line_number_width - config.padding_x, .h = config.line_height }, .{}, config.line_number_color);
            }
            const text_x = config.x + config.padding_x + if (config.show_line_numbers) config.line_number_width else 0.0;
            try batch.glyph(allocator, .{ .x = text_x, .y = y, .w = @min(@as(f32, @floatFromInt(line.len)) * config.glyph_width, @max(config.x + config.width - text_x, 0.0)), .h = config.line_height }, .{}, config.text_color);
        }

        fn renderSelection(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, range: selection_input.Range) !void {
            const start_cell = self.cellForOffset(range.start);
            const end_cell = self.cellForOffset(range.end);
            var row = start_cell.row;
            while (row <= end_cell.row) : (row += 1) {
                const y = config.y + config.padding_y + @as(f32, @floatFromInt(row)) * config.line_height - self.scroll_y;
                const start_col = if (row == start_cell.row) start_cell.col else 0;
                const end_col = if (row == end_cell.row) end_cell.col else self.lineLength(row);
                const x = Component.textX() + @as(f32, @floatFromInt(start_col)) * config.glyph_width;
                const w = @max(@as(f32, @floatFromInt(end_col - start_col)) * config.glyph_width, 2.0);
                try batch.selection(allocator, .{ .x = x, .y = y, .w = w, .h = config.line_height }, config.selection_color);
            }
        }

        fn offsetAtPoint(self: *const Component, point: draw.Vec2) usize {
            const row: usize = @intFromFloat(@max(@floor((point.y - config.y - config.padding_y + self.scroll_y) / config.line_height), 0.0));
            const col: usize = @intFromFloat(@max(@floor((point.x - Component.textX()) / config.glyph_width), 0.0));
            return self.offsetAtCell(row, col);
        }

        fn offsetAtCell(self: *const Component, target_row: usize, target_col: usize) usize {
            var row: usize = 0;
            var col: usize = 0;
            var offset: usize = 0;
            while (offset < self.buffer.items.len) {
                if (row == target_row and col >= target_col) return offset;
                if (self.buffer.items[offset] == '\n') {
                    if (row == target_row) return offset;
                    row += 1;
                    col = 0;
                    offset += 1;
                    continue;
                }
                col += 1;
                offset = selection_input.nextOffset(self.buffer.items, offset);
            }
            return self.buffer.items.len;
        }

        fn cellForOffset(self: *const Component, target: usize) struct { row: usize, col: usize } {
            var row: usize = 0;
            var col: usize = 0;
            var offset: usize = 0;
            while (offset < @min(target, self.buffer.items.len)) {
                if (self.buffer.items[offset] == '\n') {
                    row += 1;
                    col = 0;
                    offset += 1;
                    continue;
                }
                col += 1;
                offset = selection_input.nextOffset(self.buffer.items, offset);
            }
            return .{ .row = row, .col = col };
        }

        fn lineLength(self: *const Component, target_row: usize) usize {
            var row: usize = 0;
            var len: usize = 0;
            for (self.buffer.items) |byte| {
                if (row == target_row and byte != '\n') len += 1;
                if (byte == '\n') {
                    if (row == target_row) return len;
                    row += 1;
                    len = 0;
                }
            }
            return len;
        }

        fn metrics(self: *const Component) scroll.Metrics {
            return .{ .content_height = @as(f32, @floatFromInt(self.lineCount())) * config.line_height, .visible_height = config.height, .line_height = config.line_height, .scrollbar_width = 0 };
        }

        fn lineCount(self: *const Component) usize {
            var count: usize = 1;
            for (self.buffer.items) |byte| {
                if (byte == '\n') count += 1;
            }
            return count;
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn textX() f32 {
            return config.x + config.padding_x + if (config.show_line_numbers) config.line_number_width else 0.0;
        }
    };
}

pub const DiffView = CodeView;

test "code view selects text and renders diff lines" {
    const View = CodeView(.{ .x = 0, .y = 0, .width = 200, .height = 80, .glyph_width = 10, .line_height = 20 });
    var view = try View.init(std.testing.allocator, "one\n+two\n-three");
    defer view.deinit(std.testing.allocator);

    try std.testing.expect(view.handleInput(.{ .mouse_down = .{ .x = 60, .y = 5 } }));
    try std.testing.expect(view.handleInput(.{ .mouse_drag = .{ .x = 90, .y = 25 } }));
    try std.testing.expect(view.selection() != null);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try view.render(std.testing.allocator, &batch);
    try std.testing.expect(batch.commands.items.len > 0);
}

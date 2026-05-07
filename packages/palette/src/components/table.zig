//! Retained dense table component.

const std = @import("std");

const draw = @import("../draw.zig");
const Key = @import("../input/key.zig");
const scroll = @import("../scroll.zig");

pub const TableConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 480.0,
    height: f32 = 240.0,
    row_height: f32 = 24.0,
    header_height: f32 = 28.0,
    column_width: f32 = 120.0,
    row_count: ?usize = null,
    column_count: ?usize = null,
    background_color: draw.Color = .{ .r = 0.07, .g = 0.08, .b = 0.09, .a = 1.0 },
    header_color: draw.Color = .{ .r = 0.12, .g = 0.14, .b = 0.17, .a = 1.0 },
    selected_color: draw.Color = .{ .r = 0.16, .g = 0.36, .b = 0.58, .a = 0.88 },
    grid_color: draw.Color = .{ .r = 0.20, .g = 0.23, .b = 0.27, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
};

pub const Input = union(enum) {
    key: Key,
    mouse_down: draw.Vec2,
    mouse_wheel: f32,
    shape: struct { rows: usize, columns: usize },
};

pub const TableEvent = union(enum) {
    selected: ?usize,
    sort_requested: usize,
};

pub const TableCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: TableEvent) void = null,
};

pub fn Table(comptime config: TableConfig) type {
    return struct {
        const Component = @This();

        row_count: usize = config.row_count orelse 0,
        column_count: usize = config.column_count orelse 0,
        selected_row: ?usize = null,
        scroll_y: f32 = 0.0,
        callbacks: TableCallbacks = .{},

        pub fn init(rows: usize, columns: usize) Component {
            return .{ .row_count = rows, .column_count = columns };
        }

        pub fn initFromConfig() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: TableCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            self.normalizeState();
            switch (input) {
                .key => |key| return self.handleKey(key),
                .mouse_down => |point| {
                    if (!Component.bounds().contains(point)) return false;
                    if (point.y < config.y + config.header_height) {
                        const column = self.columnAtX(point.x) orelse return true;
                        self.emit(.{ .sort_requested = column });
                        return true;
                    }
                    const row = self.rowAtPoint(point) orelse return true;
                    self.selected_row = row;
                    self.emit(.{ .selected = row });
                    return true;
                },
                .mouse_wheel => |y| {
                    self.scrollBy(-y * config.row_height * 3.0);
                    return true;
                },
                .shape => |shape| {
                    self.row_count = shape.rows;
                    self.column_count = shape.columns;
                    self.normalizeState();
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.rect(allocator, Component.bounds(), config.background_color);
            try batch.rect(allocator, Component.headerRect(), config.header_color);
            var column: usize = 0;
            while (column < self.column_count) : (column += 1) {
                const header = Component.cellRect(0, column);
                try batch.glyph(allocator, .{ .x = header.x + 6, .y = config.y, .w = @max(header.w - 12, 0.0), .h = config.header_height }, .{}, config.text_color);
            }

            const visible = self.visibleRange();
            var row = visible.start;
            while (row < visible.end) : (row += 1) {
                const row_rect = Component.rowRect(row, self.scroll_y);
                if (self.selected_row == row) try batch.selection(allocator, row_rect, config.selected_color);
                column = 0;
                while (column < self.column_count) : (column += 1) {
                    const cell = Component.cellRect(row + 1, column);
                    const y = config.y + config.header_height + @as(f32, @floatFromInt(row)) * config.row_height - self.scroll_y;
                    try batch.rect(allocator, .{ .x = cell.x, .y = y, .w = 1.0, .h = config.row_height }, config.grid_color);
                    try batch.glyph(allocator, .{ .x = cell.x + 6, .y = y, .w = @max(cell.w - 12, 0.0), .h = config.row_height }, .{}, config.text_color);
                }
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (self.row_count == 0) return false;
            const current = self.selected_row orelse 0;
            switch (key.code) {
                .up => self.selected_row = if (current == 0) 0 else current - 1,
                .down => self.selected_row = @min(current + 1, self.row_count - 1),
                .home => self.selected_row = 0,
                .end => self.selected_row = self.row_count - 1,
                else => return false,
            }
            self.ensureRowVisible(self.selected_row.?);
            self.emit(.{ .selected = self.selected_row });
            return true;
        }

        fn rowAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            const body_y = point.y - config.y - config.header_height + self.scroll_y;
            if (body_y < 0.0) return null;
            const row: usize = @intFromFloat(@floor(body_y / config.row_height));
            return if (row < self.row_count) row else null;
        }

        fn columnAtX(self: *const Component, x: f32) ?usize {
            if (x < config.x or x >= config.x + config.width) return null;
            const column: usize = @intFromFloat(@floor((x - config.x) / config.column_width));
            return if (column < self.column_count) column else null;
        }

        fn visibleRange(self: *const Component) struct { start: usize, end: usize } {
            const start: usize = @min(@as(usize, @intFromFloat(@floor(self.scroll_y / config.row_height))), self.row_count);
            const count = @as(usize, @intFromFloat(@ceil(Component.bodyHeight() / config.row_height))) + 1;
            return .{ .start = start, .end = @min(start + count, self.row_count) };
        }

        fn scrollBy(self: *Component, delta_y: f32) void {
            self.scroll_y = scroll.clampOffsetY(self.scroll_y + delta_y, self.metrics());
        }

        fn ensureRowVisible(self: *Component, row: usize) void {
            const top = @as(f32, @floatFromInt(row)) * config.row_height;
            const bottom = top + config.row_height;
            if (top < self.scroll_y) self.scroll_y = top;
            if (bottom > self.scroll_y + Component.bodyHeight()) self.scroll_y = bottom - Component.bodyHeight();
            self.scroll_y = scroll.clampOffsetY(self.scroll_y, self.metrics());
        }

        fn normalizeState(self: *Component) void {
            if (self.selected_row) |row| {
                if (row >= self.row_count) self.selected_row = null;
            }
            self.scroll_y = scroll.clampOffsetY(self.scroll_y, self.metrics());
        }

        fn metrics(self: *const Component) scroll.Metrics {
            return .{ .content_height = @as(f32, @floatFromInt(self.row_count)) * config.row_height, .visible_height = Component.bodyHeight(), .line_height = config.row_height, .scrollbar_width = 0 };
        }

        fn emit(self: *Component, event: TableEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn headerRect() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.header_height };
        }

        fn bodyHeight() f32 {
            return @max(config.height - config.header_height, config.row_height);
        }

        fn rowRect(row: usize, scroll_y: f32) draw.Rect {
            return .{ .x = config.x, .y = config.y + config.header_height + @as(f32, @floatFromInt(row)) * config.row_height - scroll_y, .w = config.width, .h = config.row_height };
        }

        fn cellRect(row: usize, column: usize) draw.Rect {
            _ = row;
            return .{ .x = config.x + @as(f32, @floatFromInt(column)) * config.column_width, .y = config.y, .w = config.column_width, .h = config.row_height };
        }
    };
}

test "table selects rows and requests sort" {
    const Grid = Table(.{ .x = 0, .y = 0, .width = 240, .height = 80, .header_height = 20, .row_height = 20, .column_width = 80 });
    var table = Grid.init(5, 3);
    try std.testing.expect(table.handleInput(.{ .mouse_down = .{ .x = 10, .y = 45 } }));
    try std.testing.expectEqual(@as(?usize, 1), table.selected_row);
    try std.testing.expect(table.handleInput(.{ .key = .{ .code = .end } }));
    try std.testing.expectEqual(@as(?usize, 4), table.selected_row);
}

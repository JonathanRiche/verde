//! Retained popup menu built on list-style selection.

const std = @import("std");

const draw = @import("../draw.zig");
const Key = @import("../input/key.zig");
const sdl = @import("../sdl.zig");

pub const MenuConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 180.0,
    row_height: f32 = 28.0,
    item_count: ?usize = null,
    background_color: draw.Color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1.0 },
    highlighted_color: draw.Color = .{ .r = 0.22, .g = 0.28, .b = 0.34, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
};

pub const Input = union(enum) {
    key: Key,
    mouse_move: draw.Vec2,
    mouse_down: draw.Vec2,
    open,
    close,
};

pub const MenuEvent = union(enum) {
    selected: usize,
    highlighted: ?usize,
    open_changed: bool,
};

pub const MenuCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: MenuEvent) void = null,
};

pub fn Menu(comptime config: MenuConfig) type {
    return struct {
        const Component = @This();

        item_count: usize = config.item_count orelse 0,
        open: bool = false,
        highlighted_index: ?usize = null,
        callbacks: MenuCallbacks = .{},

        pub fn init(item_count: usize) Component {
            return .{ .item_count = item_count };
        }

        pub fn initFromConfig() Component {
            return .{};
        }

        pub fn setCallbacks(self: *Component, callbacks: MenuCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .key_down => return self.handleInput(.{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_motion => return self.handleInput(.{ .mouse_move = .{ .x = event.motion.x, .y = event.motion.y } }),
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .open => {
                    self.setOpen(true);
                    return true;
                },
                .close => {
                    self.setOpen(false);
                    return true;
                },
                .key => |key| return self.handleKey(key),
                .mouse_move => |point| {
                    if (!self.open) return false;
                    self.setHighlighted(Component.indexAtPoint(point, self.item_count));
                    return Component.bounds(self.item_count).contains(point);
                },
                .mouse_down => |point| {
                    if (!self.open) return false;
                    const index = Component.indexAtPoint(point, self.item_count) orelse {
                        self.setOpen(false);
                        return true;
                    };
                    self.emit(.{ .selected = index });
                    self.setOpen(false);
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!self.open) return;
            try batch.rect(allocator, Component.bounds(self.item_count), config.background_color);
            var index: usize = 0;
            while (index < self.item_count) : (index += 1) {
                const row = Component.rowRect(index);
                if (self.highlighted_index == index) try batch.selection(allocator, row, config.highlighted_color);
                try batch.glyph(allocator, .{ .x = row.x + 8, .y = row.y, .w = @max(row.w - 16, 0.0), .h = row.h }, .{}, config.text_color);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (!self.open or self.item_count == 0) return false;
            switch (key.code) {
                .escape => self.setOpen(false),
                .down => self.setHighlighted(@min((self.highlighted_index orelse 0) + 1, self.item_count - 1)),
                .up => self.setHighlighted(if ((self.highlighted_index orelse 0) == 0) 0 else (self.highlighted_index orelse 0) - 1),
                .enter => {
                    const index = self.highlighted_index orelse 0;
                    self.emit(.{ .selected = index });
                    self.setOpen(false);
                },
                else => return false,
            }
            return true;
        }

        fn setOpen(self: *Component, open: bool) void {
            if (self.open == open) return;
            self.open = open;
            if (!open) self.highlighted_index = null;
            self.emit(.{ .open_changed = open });
        }

        fn setHighlighted(self: *Component, index: ?usize) void {
            if (self.highlighted_index == index) return;
            self.highlighted_index = index;
            self.emit(.{ .highlighted = index });
        }

        fn emit(self: *Component, event: MenuEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn bounds(item_count: usize) draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = @as(f32, @floatFromInt(item_count)) * config.row_height };
        }

        fn rowRect(index: usize) draw.Rect {
            return .{ .x = config.x, .y = config.y + @as(f32, @floatFromInt(index)) * config.row_height, .w = config.width, .h = config.row_height };
        }

        fn indexAtPoint(point: draw.Vec2, item_count: usize) ?usize {
            if (!Component.bounds(item_count).contains(point)) return null;
            const index: usize = @intFromFloat(@floor((point.y - config.y) / config.row_height));
            return if (index < item_count) index else null;
        }
    };
}

test "menu opens highlights and selects" {
    const Popup = Menu(.{ .x = 0, .y = 0, .width = 100, .row_height = 20 });
    var menu = Popup.init(3);
    try std.testing.expect(menu.handleInput(.open));
    try std.testing.expect(menu.handleInput(.{ .mouse_move = .{ .x = 5, .y = 25 } }));
    try std.testing.expectEqual(@as(?usize, 1), menu.highlighted_index);
    try std.testing.expect(menu.handleInput(.{ .key = .{ .code = .enter } }));
    try std.testing.expect(!menu.open);
}

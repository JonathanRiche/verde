//! Retained text label component.

const Self = @This();
const std = @import("std");

const draw = @import("../draw.zig");
const clipboard = @import("../input/clipboard.zig");
const selection_input = @import("../input/selection.zig");
const sdl = @import("../sdl.zig");

pub const TextConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 320.0,
    height: f32 = 24.0,
    color: draw.Color = draw.Color.white,
    selection_color: draw.Color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    font_size: f32 = 16.0,
    glyph_width: ?f32 = null,
    selectable: bool = false,
};

pub const TextEvent = union(enum) {
    changed: []const u8,
    selection_changed: ?selection_input.Range,
};

pub const TextCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: TextEvent) void = null,
    set_clipboard: ?*const fn (context: ?*anyopaque, text: []const u8) bool = null,

    fn clipboardProvider(self: TextCallbacks) clipboard {
        return .{
            .context = self.context,
            .set = self.set_clipboard,
        };
    }
};

pub const Input = union(enum) {
    mouse_down: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    copy_selection,
};

pub fn Text(comptime config: TextConfig) type {
    return struct {
        const Component = @This();

        buffer: std.ArrayList(u8) = .empty,
        selection_anchor: ?usize = null,
        selection_focus: ?usize = null,
        dragging_selection: bool = false,
        callbacks: TextCallbacks = .{},

        pub fn init(allocator: std.mem.Allocator, value: []const u8) !Component {
            var self: Component = .{};
            try self.buffer.appendSlice(allocator, value);
            return self;
        }

        pub fn deinit(self: *Component, allocator: std.mem.Allocator) void {
            self.buffer.deinit(allocator);
            self.* = undefined;
        }

        pub fn setText(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(allocator, value);
            self.emit(.{ .changed = self.buffer.items });
        }

        pub fn text(self: *const Component) []const u8 {
            return self.buffer.items;
        }

        pub fn selection(self: *const Component) ?selection_input.Range {
            const state: selection_input = .{ .anchor = self.selection_anchor, .focus = self.selection_focus };
            return state.normalized(self.buffer.items.len);
        }

        pub fn clearSelection(self: *Component) void {
            self.selection_anchor = null;
            self.selection_focus = null;
            self.emit(.{ .selection_changed = null });
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_button_up => return self.handleInput(.{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_motion => {
                    if (!self.dragging_selection or !event.motion.state.left) return false;
                    return self.handleInput(.{ .mouse_drag = .{ .x = event.motion.x, .y = event.motion.y } });
                },
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            if (!config.selectable) return false;
            switch (input) {
                .mouse_down => |point| {
                    if (!Component.bounds().contains(point)) {
                        if (self.selection() != null) self.clearSelection();
                        return false;
                    }
                    const offset = self.byteOffsetForPoint(point);
                    self.selection_anchor = offset;
                    self.selection_focus = offset;
                    self.dragging_selection = true;
                    return true;
                },
                .mouse_drag => |point| {
                    if (!self.dragging_selection) return false;
                    self.selection_focus = self.byteOffsetForPoint(point);
                    self.emit(.{ .selection_changed = self.selection() });
                    return true;
                },
                .mouse_up => {
                    const was_dragging = self.dragging_selection;
                    self.dragging_selection = false;
                    self.emit(.{ .selection_changed = self.selection() });
                    return was_dragging;
                },
                .copy_selection => return self.copySelection(),
            }
        }

        pub fn setCallbacks(self: *Component, callbacks: TextCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (self.selection()) |range| {
                const start_x = config.x + @as(f32, @floatFromInt(self.visualColumnForOffset(range.start))) * Component.glyphWidth();
                const end_x = config.x + @as(f32, @floatFromInt(self.visualColumnForOffset(range.end))) * Component.glyphWidth();
                try batch.selection(allocator, .{ .x = start_x, .y = config.y, .w = @max(end_x - start_x, 2.0), .h = config.height }, config.selection_color);
            }
            try batch.glyph(allocator, .{
                .x = config.x,
                .y = config.y,
                .w = @min(config.width, approximateWidth(self.buffer.items.len, config.font_size)),
                .h = config.height,
            }, .{}, config.color);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn copySelection(self: *Component) bool {
            const range = self.selection() orelse return false;
            return self.callbacks.clipboardProvider().write(self.buffer.items[range.start..range.end]);
        }

        fn byteOffsetForPoint(self: *const Component, point: draw.Vec2) usize {
            const col_float = @max(point.x - config.x, 0.0) / Component.glyphWidth();
            const target_col: usize = @intFromFloat(@max(col_float, 0.0));
            var offset: usize = 0;
            var col: usize = 0;
            while (offset < self.buffer.items.len and col < target_col) : (col += 1) {
                offset = selection_input.nextOffset(self.buffer.items, offset);
            }
            return offset;
        }

        fn visualColumnForOffset(self: *const Component, offset: usize) usize {
            var index: usize = 0;
            var column: usize = 0;
            while (index < @min(offset, self.buffer.items.len)) : (column += 1) {
                index = selection_input.nextOffset(self.buffer.items, index);
            }
            return column;
        }

        fn approximateWidth(len: usize, font_size: f32) f32 {
            return @as(f32, @floatFromInt(len)) * font_size * 0.55;
        }

        fn glyphWidth() f32 {
            return config.glyph_width orelse config.font_size * 0.55;
        }

        fn bounds() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }

        fn emit(self: *Component, event: TextEvent) void {
            if (self.callbacks.on_event) |callback| {
                callback(self.callbacks.context, event);
            }
        }
    };
}

const TextProbe = struct {
    changed: usize = 0,
};

fn probeTextEvent(context: ?*anyopaque, event: TextEvent) void {
    const probe: *TextProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .changed => probe.changed += 1,
        .selection_changed => {},
    }
}

test "text component emits change callbacks" {
    const Label = Text(.{});
    var label = try Label.init(std.testing.allocator, "before");
    defer label.deinit(std.testing.allocator);

    var probe: TextProbe = .{};
    label.setCallbacks(.{ .context = &probe, .on_event = probeTextEvent });
    try label.setText(std.testing.allocator, "after");

    try std.testing.expectEqualStrings("after", label.text());
    try std.testing.expectEqual(@as(usize, 1), probe.changed);
}

test "selectable text can drag selection and copy" {
    const Label = Text(.{ .x = 0, .y = 0, .width = 200, .height = 24, .glyph_width = 10, .selectable = true });
    var label = try Label.init(std.testing.allocator, "hello");
    defer label.deinit(std.testing.allocator);

    var copied: std.ArrayList(u8) = .empty;
    defer copied.deinit(std.testing.allocator);
    label.setCallbacks(.{ .context = &copied, .set_clipboard = setProbeClipboard });

    try std.testing.expect(label.handleInput(.{ .mouse_down = .{ .x = 0, .y = 4 } }));
    try std.testing.expect(label.handleInput(.{ .mouse_drag = .{ .x = 30, .y = 4 } }));
    try std.testing.expect(label.handleInput(.{ .mouse_up = .{ .x = 30, .y = 4 } }));
    try std.testing.expectEqualStrings("hel", label.text()[label.selection().?.start..label.selection().?.end]);
    try std.testing.expect(label.handleInput(.copy_selection));
    try std.testing.expectEqualStrings("hel", copied.items);
}

fn setProbeClipboard(context: ?*anyopaque, text: []const u8) bool {
    const copied: *std.ArrayList(u8) = @ptrCast(@alignCast(context orelse return false));
    copied.clearRetainingCapacity();
    copied.appendSlice(std.testing.allocator, text) catch return false;
    return true;
}

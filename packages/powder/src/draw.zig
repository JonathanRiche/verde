//! CPU-side render commands shared by components and the SDL_GPU renderer.

const Self = @This();
const std = @import("std");

pub const GpuRenderPass = anyopaque;

pub const Color = extern struct {
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    a: f32 = 1.0,

    pub const white: Color = .{};
    pub const transparent: Color = .{ .a = 0.0 };
    pub const black: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0 };
};

pub const Vec2 = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub const Rect = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    pub fn contains(self: Rect, point: Vec2) bool {
        return point.x >= self.x and point.x < self.x + self.w and
            point.y >= self.y and point.y < self.y + self.h;
    }
};

pub const Vertex = extern struct {
    pos: Vec2,
    uv: Vec2,
    color: Color,
};

pub const CommandKind = enum {
    rect,
    text,
    cursor,
    selection,
    scrollbar,
};

pub const Command = struct {
    kind: CommandKind,
    rect: Rect,
    uv: Rect = .{},
    color: Color,
    /// Frame-lifetime text slice. Callers must keep it alive until the batch is consumed.
    text: []const u8 = "",
    font_size: f32 = 16.0,
    clip: ?Rect = null,
    scroll: Vec2 = .{},
    glyph_width: f32 = 8.8,
    line_height: f32 = 20.0,
    wrap: bool = false,
};

pub const RenderBatch = struct {
    commands: std.ArrayList(Command) = .empty,

    pub fn deinit(self: *RenderBatch, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
    }

    pub fn clear(self: *RenderBatch) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn rect(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .kind = .rect, .rect = r, .color = color });
    }

    pub fn glyph(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, uv: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .kind = .text, .rect = r, .uv = uv, .color = color });
    }

    /// Appends a text command. The `value` slice is frame-lifetime and must remain
    /// valid until the batch is consumed by a renderer.
    pub fn text(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, value: []const u8, color: Color, font_size: f32, clip: ?Rect) !void {
        try self.commands.append(allocator, .{
            .kind = .text,
            .rect = r,
            .color = color,
            .text = value,
            .font_size = font_size,
            .clip = clip,
            .glyph_width = font_size * 0.55,
            .line_height = font_size * 1.25,
        });
    }

    /// Appends fixed-cell wrapped text. TextArea uses this so rendering, hit
    /// testing, cursor placement, selection, and scrolling share one layout model.
    pub fn fixedText(
        self: *RenderBatch,
        allocator: std.mem.Allocator,
        r: Rect,
        value: []const u8,
        color: Color,
        font_size: f32,
        clip: ?Rect,
        scroll_value: Vec2,
        glyph_width: f32,
        line_height: f32,
        wrap: bool,
    ) !void {
        try self.commands.append(allocator, .{
            .kind = .text,
            .rect = r,
            .color = color,
            .text = value,
            .font_size = font_size,
            .clip = clip,
            .scroll = scroll_value,
            .glyph_width = glyph_width,
            .line_height = line_height,
            .wrap = wrap,
        });
    }

    pub fn cursor(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .kind = .cursor, .rect = r, .color = color });
    }

    pub fn selection(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .kind = .selection, .rect = r, .color = color });
    }

    pub fn scrollbar(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .kind = .scrollbar, .rect = r, .color = color });
    }
};

test "rect contains points inside bounds" {
    const rect_value: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(rect_value.contains(.{ .x = 10, .y = 20 }));
    try std.testing.expect(!rect_value.contains(.{ .x = 40, .y = 20 }));
}

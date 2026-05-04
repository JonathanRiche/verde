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
    glyph,
    cursor,
    selection,
    scrollbar,
};

pub const Command = struct {
    kind: CommandKind,
    rect: Rect,
    uv: Rect = .{},
    color: Color,
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
        try self.commands.append(allocator, .{ .kind = .glyph, .rect = r, .uv = uv, .color = color });
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

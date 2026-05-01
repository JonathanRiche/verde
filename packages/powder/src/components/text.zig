//! Retained text label component.

const Self = @This();
const std = @import("std");

const draw = @import("../draw.zig");
const sdl = @import("../sdl.zig");

pub const TextConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 320.0,
    height: f32 = 24.0,
    color: draw.Color = draw.Color.white,
    font_size: f32 = 16.0,
};

pub fn Text(comptime config: TextConfig) type {
    return struct {
        const Component = @This();

        buffer: std.ArrayList(u8) = .empty,

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
        }

        pub fn text(self: *const Component) []const u8 {
            return self.buffer.items;
        }

        pub fn update(_: *Component, _: *const sdl.Event) !bool {
            return false;
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.glyph(allocator, .{
                .x = config.x,
                .y = config.y,
                .w = @min(config.width, approximateWidth(self.buffer.items.len, config.font_size)),
                .h = config.height,
            }, .{}, config.color);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn approximateWidth(len: usize, font_size: f32) f32 {
            return @as(f32, @floatFromInt(len)) * font_size * 0.55;
        }
    };
}

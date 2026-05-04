//! Retained image component.

const std = @import("std");

const draw = @import("../draw.zig");

pub const ImageFit = enum {
    stretch,
    contain,
    cover,
    none,
};

pub const ImageConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 96.0,
    height: f32 = 96.0,
    source_width: f32 = 1.0,
    source_height: f32 = 1.0,
    fit: ImageFit = .contain,
    uv: draw.Rect = .{ .w = 1.0, .h = 1.0 },
    tint: draw.Color = draw.Color.white,
    clip: bool = true,
};

pub fn Image(comptime config: ImageConfig) type {
    return struct {
        const Component = @This();

        texture: draw.TextureId = .invalid,
        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        source_size: draw.Vec2 = .{ .x = config.source_width, .y = config.source_height },
        uv: draw.Rect = config.uv,
        tint: draw.Color = config.tint,

        pub fn init(texture: draw.TextureId) Component {
            return .{ .texture = texture };
        }

        pub fn initWithSize(texture: draw.TextureId, source_width: f32, source_height: f32) Component {
            return .{
                .texture = texture,
                .source_size = .{ .x = source_width, .y = source_height },
            };
        }

        pub fn setTexture(self: *Component, texture: draw.TextureId) void {
            self.texture = texture;
        }

        pub fn setSourceSize(self: *Component, width: f32, height: f32) void {
            self.source_size = .{ .x = @max(width, 1.0), .y = @max(height, 1.0) };
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn imageRect(self: *const Component) draw.Rect {
            return fitRect(self.bounds(), self.source_size.x, self.source_size.y, config.fit);
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            try batch.image(
                allocator,
                self.imageRect(),
                self.texture,
                self.uv,
                self.tint,
                if (config.clip) self.bounds() else null,
            );
        }
    };
}

pub fn fitRect(bounds: draw.Rect, source_width: f32, source_height: f32, fit: ImageFit) draw.Rect {
    const src_w = @max(source_width, 1.0);
    const src_h = @max(source_height, 1.0);
    return switch (fit) {
        .stretch => bounds,
        .none => .{ .x = bounds.x, .y = bounds.y, .w = @min(src_w, bounds.w), .h = @min(src_h, bounds.h) },
        .contain, .cover => blk: {
            const sx = bounds.w / src_w;
            const sy = bounds.h / src_h;
            const scale = if (fit == .contain) @min(sx, sy) else @max(sx, sy);
            const w = src_w * scale;
            const h = src_h * scale;
            break :blk .{
                .x = bounds.x + (bounds.w - w) * 0.5,
                .y = bounds.y + (bounds.h - h) * 0.5,
                .w = w,
                .h = h,
            };
        },
    };
}

test "image contain fit preserves aspect ratio" {
    const rect = fitRect(.{ .x = 10, .y = 20, .w = 200, .h = 100 }, 100, 100, .contain);
    try std.testing.expectEqual(draw.Rect{ .x = 60, .y = 20, .w = 100, .h = 100 }, rect);
}

test "image component emits image command" {
    const Logo = Image(.{ .width = 120, .height = 60, .source_width = 100, .source_height = 100, .fit = .contain });
    var logo = Logo.init(draw.TextureId.init(3));
    logo.setBounds(.{ .x = 0, .y = 0, .w = 120, .h = 60 });

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try logo.render(std.testing.allocator, &batch);

    try std.testing.expectEqual(draw.CommandKind.image, batch.commands.items[0].kind);
    try std.testing.expectEqual(@as(u32, 3), batch.commands.items[0].texture.value);
    try std.testing.expectApproxEqAbs(@as(f32, 30), batch.commands.items[0].rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), batch.commands.items[0].rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), batch.commands.items[0].rect.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), batch.commands.items[0].rect.h, 0.001);
}

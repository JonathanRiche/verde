//! Retained horizontal toolbar layout and separator presenter.

const std = @import("std");

const draw = @import("../draw.zig");
const layout = @import("../layout.zig");

pub const ToolbarConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 480.0,
    height: f32 = 40.0,
    padding: layout.Edges = .{},
    gap: f32 = 8.0,
    separator_width: f32 = 1.0,
    separator_inset: f32 = 8.0,
    separator_color: draw.Color = .{ .r = 0.42, .g = 0.46, .b = 0.52, .a = 0.35 },
    z_index: i32 = 0,
};

pub const ToolbarItem = struct {
    width: f32 = 0.0,
    min_width: f32 = 0.0,
    height: f32 = 0.0,
    grow: f32 = 0.0,
    separator_after: bool = false,
    right_aligned: bool = false,

    pub fn fixed(width: f32, height: f32) ToolbarItem {
        return .{ .width = width, .height = height };
    }

    pub fn flexible(min_width: f32, height: f32, weight: f32) ToolbarItem {
        return .{ .min_width = min_width, .height = height, .grow = weight };
    }
};

pub fn Toolbar(comptime config: ToolbarConfig) type {
    return struct {
        const Component = @This();

        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        z_index: i32 = config.z_index,

        pub fn init() Component {
            return .{};
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn contentRect(self: *const Component) draw.Rect {
            const rect_value = self.bounds();
            return .{
                .x = rect_value.x + config.padding.left,
                .y = rect_value.y + config.padding.top,
                .w = @max(rect_value.w - config.padding.left - config.padding.right, 0.0),
                .h = @max(rect_value.h - config.padding.top - config.padding.bottom, 0.0),
            };
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        pub fn layout(self: *const Component, items: []const ToolbarItem, out: []draw.Rect) void {
            std.debug.assert(out.len >= items.len);
            if (items.len == 0) return;

            const content = self.contentRect();
            const total_gap = config.gap * @as(f32, @floatFromInt(items.len - 1));
            var fixed: f32 = total_gap;
            var grow_total: f32 = 0.0;
            for (items) |item| {
                if (item.grow > 0.0) {
                    fixed += item.min_width;
                    grow_total += item.grow;
                } else {
                    fixed += item.width;
                }
            }
            const grow_space = @max(content.w - fixed, 0.0);

            var widths: [64]f32 = undefined;
            std.debug.assert(items.len <= widths.len);
            for (items, 0..) |item, index| {
                widths[index] = if (item.grow > 0.0)
                    item.min_width + grow_space * (item.grow / @max(grow_total, 1.0))
                else
                    item.width;
            }

            var x = content.x;
            var right_x = content.x + content.w;
            for (items, 0..) |item, index| {
                const h = if (item.height > 0.0) @min(item.height, content.h) else content.h;
                if (item.right_aligned) {
                    right_x -= widths[index];
                    out[index] = .{
                        .x = right_x,
                        .y = content.y + @max((content.h - h) * 0.5, 0.0),
                        .w = widths[index],
                        .h = h,
                    };
                    right_x -= config.gap;
                } else {
                    out[index] = .{
                        .x = x,
                        .y = content.y + @max((content.h - h) * 0.5, 0.0),
                        .w = widths[index],
                        .h = h,
                    };
                    x += widths[index] + config.gap;
                }
            }
        }

        pub fn apply(self: *const Component, comptime items: []const ToolbarItem, children: anytype) void {
            comptime std.debug.assert(items.len == children.len);
            var rects: [items.len]draw.Rect = undefined;
            self.layout(items, &rects);
            inline for (children, 0..) |child, index| {
                child.setBounds(rects[index]);
            }
        }

        pub fn renderSeparators(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, items: []const ToolbarItem, rects: []const draw.Rect) !void {
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);
            const content = self.contentRect();
            for (items, 0..) |item, index| {
                if (!item.separator_after or index + 1 >= rects.len) continue;
                const x = (rects[index].x + rects[index].w + rects[index + 1].x) * 0.5 - config.separator_width * 0.5;
                try batch.rect(allocator, .{
                    .x = x,
                    .y = content.y + config.separator_inset,
                    .w = config.separator_width,
                    .h = @max(content.h - config.separator_inset * 2.0, 0.0),
                }, config.separator_color);
            }
        }
    };
}

test "toolbar assigns grow and right aligned rects" {
    const Bar = Toolbar(.{ .width = 300, .height = 40, .gap = 10 });
    var bar = Bar.init();
    var rects: [3]draw.Rect = undefined;
    const items = [_]ToolbarItem{
        ToolbarItem.fixed(60, 28),
        ToolbarItem.flexible(80, 28, 1),
        .{ .width = 32, .height = 32, .right_aligned = true },
    };
    bar.layout(&items, &rects);
    try std.testing.expectEqual(@as(f32, 0), rects[0].x);
    try std.testing.expect(rects[1].w > 80);
    try std.testing.expectEqual(@as(f32, 268), rects[2].x);
}

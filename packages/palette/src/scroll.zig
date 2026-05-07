//! Shared vertical scroll state and scrollbar geometry.

const Self = @This();

const draw = @import("draw.zig");

offset_y: f32 = 0.0,
dragging_scrollbar: bool = false,
scrollbar_drag_offset_y: f32 = 0.0,

pub const Metrics = struct {
    enabled: bool = true,
    content_height: f32,
    visible_height: f32,
    line_height: f32,
    scrollbar_width: f32,
};

pub fn maxOffsetY(metrics: Metrics) f32 {
    if (!metrics.enabled) return 0.0;
    return @max(metrics.content_height - metrics.visible_height, 0.0);
}

pub fn clampOffsetY(value: f32, metrics: Metrics) f32 {
    if (!metrics.enabled) return 0.0;
    return @min(@max(value, 0.0), maxOffsetY(metrics));
}

pub fn setOffsetY(self: *Self, value: f32, metrics: Metrics) void {
    self.offset_y = clampOffsetY(value, metrics);
}

pub fn scrollBy(self: *Self, delta_y: f32, metrics: Metrics) void {
    self.setOffsetY(self.offset_y + delta_y, metrics);
}

pub fn thumbRect(track: draw.Rect, metrics: Metrics, offset_y: f32) ?draw.Rect {
    const max_scroll = maxOffsetY(metrics);
    if (!metrics.enabled or max_scroll <= 0.0 or metrics.scrollbar_width <= 0.0) return null;
    const thumb_h = @max((metrics.visible_height / metrics.content_height) * track.h, @min(track.h, metrics.line_height));
    const travel = @max(track.h - thumb_h, 0.0);
    const thumb_y = track.y + if (max_scroll > 0.0) (offset_y / max_scroll) * travel else 0.0;
    return .{
        .x = track.x,
        .y = thumb_y,
        .w = track.w,
        .h = thumb_h,
    };
}

pub fn offsetForThumbY(y: f32, drag_offset_y: f32, track: draw.Rect, thumb: draw.Rect, metrics: Metrics) f32 {
    const max_scroll = maxOffsetY(metrics);
    if (max_scroll <= 0.0) return 0.0;
    const travel = @max(track.h - thumb.h, 1.0);
    const thumb_y = @min(@max(y - drag_offset_y, track.y), track.y + travel);
    return ((thumb_y - track.y) / travel) * max_scroll;
}

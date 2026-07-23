//! Shared Palette globe glyph rendering.

const palette = @import("palette");

const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

/// Renders the browser globe used by workspace controls and pane rows.
pub fn queue(state: *runtime.AppState, cx: f32, cy: f32, size: f32, color: palette.Color) void {
    const r = size * 0.5;
    const bounds: palette.Rect = .{ .x = cx - r, .y = cy - r, .w = size, .h = size };
    const stroke = @max(theme.scaledUi(1.05), size * 0.078);
    state.palette_overlay_batch.rectBorder(state.allocator, bounds, color, r, stroke) catch {};

    const equator_w = size - stroke * 1.8;
    queueRect(state, .{
        .x = cx - equator_w * 0.5,
        .y = cy - stroke * 0.5,
        .w = equator_w,
        .h = stroke,
    }, color);

    queueMeridianArc(state, cx, cy, r, stroke, color, -1.0);
    queueMeridianArc(state, cx, cy, r, stroke, color, 1.0);
}

fn queueMeridianArc(
    state: *runtime.AppState,
    cx: f32,
    cy: f32,
    r: f32,
    stroke: f32,
    color: palette.Color,
    sign: f32,
) void {
    const bulge = 0.47;
    const segment_count: usize = 17;
    var i: usize = 0;
    while (i + 1 < segment_count) : (i += 1) {
        const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segment_count - 1));
        const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segment_count - 1));
        const y0 = cy - r + t0 * (2 * r);
        const y1 = cy - r + t1 * (2 * r);
        const dy = (y0 + y1) * 0.5 - cy;
        const chord_sq = r * r - dy * dy;
        if (chord_sq <= 0) continue;
        const segment_h = y1 - y0;
        if (segment_h <= 0) continue;
        const x = cx + sign * @sqrt(chord_sq) * bulge;
        queueRect(state, .{
            .x = x - stroke * 0.5,
            .y = y0,
            .w = stroke,
            .h = segment_h,
        }, color);
    }
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

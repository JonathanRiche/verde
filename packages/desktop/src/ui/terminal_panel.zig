//! Palette-only terminal dock shell.

const palette = @import("palette");

const app_state = @import("../state.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    renderDockAt(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height });
}

pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    if (state.projects.items.len == 0) return;
    queueRounded(state, rect, paletteColor(colors.rgba(9, 12, 13, 255)), 0.0);
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, 1.0);

    const header = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = theme.scaledUi(34.0) };
    queueRect(state, header, paletteColor(theme.COLOR_PANEL));
    queueText(state, .{
        .x = header.x + theme.scaledUi(14.0),
        .y = header.y + theme.scaledUi(8.0),
        .w = header.w - theme.scaledUi(28.0),
        .h = theme.scaledUi(20.0),
    }, "Terminal", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), header);

    const body = palette.Rect{ .x = rect.x, .y = header.y + header.h, .w = rect.w, .h = @max(rect.h - header.h, 1.0) };
    const dock = state.currentProjectTerminal();
    const label = if (dock.visible) "Terminal session active. Palette VT viewport migration is the next terminal slice." else "Terminal hidden.";
    queueText(state, .{
        .x = body.x + theme.scaledUi(16.0),
        .y = body.y + theme.scaledUi(18.0),
        .w = body.w - theme.scaledUi(32.0),
        .h = theme.scaledUi(24.0),
    }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), body);
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    const start = state.palette_frame_text.items.len;
    state.palette_frame_text.appendSlice(state.allocator, value) catch return "";
    return state.palette_frame_text.items[start .. start + value.len];
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

fn queueRounded(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch {};
}

fn queueBorder(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch {};
}

fn queueText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.text(state.allocator, rect, stableText(state, value), color, font_size, clip) catch {};
}

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

//! Shared Palette chrome for right-click context menus.
//!
//! Pane, terminal and browser menus lay out their own rows but draw them
//! through these helpers so every menu shares one look: a pixel-snapped panel
//! (a 1px border straddling two pixels reads as a soft, jagged outline), a
//! soft drop shadow, `.ui`-role labels (untyped text falls back to the bold
//! prose face, which does not match `.ui` measurement), and icon-font
//! chevrons/checks instead of ASCII `>` and `*`.

const palette = @import("palette");

const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

pub const ROW_HEIGHT_UI: f32 = 30.0;
pub const PAD_UI: f32 = 6.0;
pub const SEPARATOR_HEIGHT_UI: f32 = 9.0;
pub const FONT_SIZE_UI: f32 = 13.0;
pub const RADIUS_UI: f32 = 9.0;
pub const ROW_RADIUS_UI: f32 = 6.0;
pub const LABEL_INSET_UI: f32 = 10.0;
/// Room reserved at a row's leading edge for a check mark.
pub const CHECK_SLOT_UI: f32 = 18.0;
/// Room reserved at a row's trailing edge for a submenu chevron.
pub const CHEVRON_SLOT_UI: f32 = 22.0;

const ICON_SIZE_UI: f32 = 12.0;
const NF_COD_CHEVRON_RIGHT = "\u{EAB6}";
const NF_COD_CHECK = "\u{EAB2}";

/// Rounds a rect onto the framebuffer pixel grid.
pub fn snap(rect: palette.Rect) palette.Rect {
    const x = @round(rect.x);
    const y = @round(rect.y);
    return .{ .x = x, .y = y, .w = @round(rect.x + rect.w) - x, .h = @round(rect.y + rect.h) - y };
}

/// Draws the panel shadow, fill and hairline border. Returns the snapped
/// rect so callers lay rows out on the same pixel grid.
pub fn queuePanel(state: *runtime.AppState, rect: palette.Rect) palette.Rect {
    const panel = snap(rect);
    const radius = theme.scaledUi(RADIUS_UI);
    // Two stacked, offset scrims read as a soft ambient shadow without a blur pass.
    const shadow_layers = [_]struct { spread: f32, drop: f32, alpha: f32 }{
        .{ .spread = 6.0, .drop = 6.0, .alpha = 0.10 },
        .{ .spread = 2.0, .drop = 2.0, .alpha = 0.16 },
    };
    for (shadow_layers) |layer| {
        const spread = theme.scaledUi(layer.spread);
        queueRounded(state, snap(.{
            .x = panel.x - spread,
            .y = panel.y - spread + theme.scaledUi(layer.drop),
            .w = panel.w + spread * 2.0,
            .h = panel.h + spread * 2.0,
        }), color(theme.scrim(layer.alpha)), radius + spread);
    }
    queueRounded(state, panel, color(theme.COLOR_PANEL_ALT), radius);
    state.palette_overlay_batch.rectBorder(state.allocator, panel, color(theme.borderMuted()), radius, @max(@round(theme.scaledUi(1.0)), 1.0)) catch {};
    return panel;
}

/// Hover/keyboard-selection fill for one row.
pub fn queueRowHighlight(state: *runtime.AppState, row: palette.Rect) void {
    queueRounded(state, snap(row), color(theme.raise(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(ROW_RADIUS_UI));
}

/// Label colour for a row in the given state.
pub fn labelColor(enabled: bool, highlighted: bool) [4]f32 {
    if (!enabled) return theme.COLOR_TEXT_SUBTLE;
    return if (highlighted) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
}

/// Row label, vertically centred. `leading`/`trailing` reserve room for a
/// check mark or chevron.
pub fn queueLabel(state: *runtime.AppState, row: palette.Rect, label: []const u8, text_color: [4]f32, leading: f32, trailing: f32, clip: palette.Rect) void {
    const font_size = theme.scaledUi(FONT_SIZE_UI);
    const line_h = font_size * 1.25;
    const inset = theme.scaledUi(LABEL_INSET_UI);
    queueRoleText(state, .{
        .x = row.x + inset + leading,
        .y = row.y + (row.h - line_h) * 0.5,
        .w = @max(row.w - inset * 2.0 - leading - trailing, 1.0),
        .h = line_h,
    }, label, text_color, font_size, .ui, clip);
}

/// Submenu chevron at the row's trailing edge.
pub fn queueChevron(state: *runtime.AppState, row: palette.Rect, icon_color: [4]f32, clip: palette.Rect) void {
    const size = theme.scaledUi(ICON_SIZE_UI);
    queueRoleText(state, .{
        .x = row.x + row.w - theme.scaledUi(LABEL_INSET_UI) - size,
        .y = row.y + (row.h - size) * 0.5,
        .w = size,
        .h = size,
    }, NF_COD_CHEVRON_RIGHT, icon_color, size, .icon, clip);
}

/// Selection check mark inside the row's leading `CHECK_SLOT_UI`.
pub fn queueCheck(state: *runtime.AppState, row: palette.Rect, icon_color: [4]f32, clip: palette.Rect) void {
    const size = theme.scaledUi(ICON_SIZE_UI);
    queueRoleText(state, .{
        .x = row.x + theme.scaledUi(LABEL_INSET_UI) - theme.scaledUi(2.0),
        .y = row.y + (row.h - size) * 0.5,
        .w = size,
        .h = size,
    }, NF_COD_CHECK, icon_color, size, .icon, clip);
}

/// Hairline rule centred in a `SEPARATOR_HEIGHT_UI` band starting at `y`.
pub fn queueSeparator(state: *runtime.AppState, x: f32, y: f32, w: f32) void {
    const band = theme.scaledUi(SEPARATOR_HEIGHT_UI);
    const thickness = @max(@round(theme.scaledUi(1.0)), 1.0);
    state.palette_overlay_batch.rect(state.allocator, snap(.{
        .x = x,
        .y = y + (band - thickness) * 0.5,
        .w = w,
        .h = thickness,
    }), color(theme.withAlpha(theme.borderMuted(), 180))) catch {};
}

fn queueRounded(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, fill, radius) catch {};
}

fn queueRoleText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, text_color: [4]f32, font_size: f32, role: palette.FontRole, clip: palette.Rect) void {
    const stable = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.roleText(state.allocator, snap(rect), stable, color(text_color), font_size, role, null, clip) catch {};
}

fn color(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

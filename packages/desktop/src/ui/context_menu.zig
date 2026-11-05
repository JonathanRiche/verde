//! Shared Palette chrome for right-click context menus.
//!
//! Pane, terminal and browser menus lay out their own rows but draw them
//! through these helpers so every menu shares one look: a pixel-snapped panel
//! (a 1px border straddling two pixels reads as a soft, jagged outline), a
//! soft drop shadow, `.ui`-role labels (untyped text falls back to the bold
//! prose face, which does not match `.ui` measurement), and icon-font
//! chevrons/checks instead of ASCII `>` and `*`.

const std = @import("std");
const palette = @import("palette");
const text_measure = @import("text_measure.zig");

const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

pub const ROW_HEIGHT_UI: f32 = 32.0;
pub const PAD_UI: f32 = 6.0;
pub const SEPARATOR_HEIGHT_UI: f32 = 9.0;
pub const FONT_SIZE_UI: f32 = 13.0;
pub const RADIUS_UI: f32 = 9.0;
pub const ROW_RADIUS_UI: f32 = 6.0;
pub const LABEL_INSET_UI: f32 = 10.0;
/// Room reserved at a row's leading edge for a check mark.
pub const CHECK_SLOT_UI: f32 = 22.0;
/// Room reserved at a row's trailing edge for a submenu chevron.
pub const CHEVRON_SLOT_UI: f32 = 22.0;

const ICON_SIZE_UI: f32 = 14.0;
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
    // Light surfaces need only a small offset shadow: broad overlapping
    // scrims form a heavy grey rim against their pale backing.
    const Shadow = struct { spread: f32, drop: f32, alpha: f32 };
    const shadow_layers = [_]Shadow{
        .{ .spread = 6.0, .drop = 6.0, .alpha = 0.10 },
        .{ .spread = 2.0, .drop = 2.0, .alpha = 0.16 },
    };
    const light_shadow = [_]Shadow{
        .{ .spread = 0.0, .drop = 2.0, .alpha = 0.06 },
    };
    const layers: []const Shadow = if (theme.isLightPalette()) &light_shadow else &shadow_layers;
    for (layers) |layer| {
        const spread = theme.scaledUi(layer.spread);
        queueRounded(state, snap(.{
            .x = panel.x - spread,
            .y = panel.y - spread + theme.scaledUi(layer.drop),
            .w = panel.w + spread * 2.0,
            .h = panel.h + spread * 2.0,
        }), color(theme.scrim(layer.alpha)), radius + spread);
    }
    // Fill + hairline border as one panel command so the two anti-aliased
    // edges never stack at the corners.
    state.palette_overlay_batch.panel(state.allocator, panel, color(theme.COLOR_PANEL_ALT), color(theme.borderMuted()), radius, @max(@round(theme.scaledUi(1.0)), 1.0)) catch {};
    return panel;
}

/// Hover/keyboard-selection fill for one row.
pub fn queueRowHighlight(state: *runtime.AppState, row: palette.Rect) void {
    queueRounded(state, snap(row), color(theme.raise(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(ROW_RADIUS_UI));
}

/// Keyboard selection uses a stronger neutral fill and border; hover is quiet.
/// One panel command keeps the rounded fill and focus border on the same edges.
pub fn queueRowState(state: *runtime.AppState, row: palette.Rect, hovered: bool, keyboard_focused: bool) void {
    if (keyboard_focused) {
        state.palette_overlay_batch.panel(state.allocator, snap(row), color(theme.raise(theme.COLOR_PANEL_ALT, 0.14)), color(theme.withAlpha(theme.COLOR_TEXT_MUTED, 160)), theme.scaledUi(ROW_RADIUS_UI), @max(@round(theme.scaledUi(1.0)), 1.0)) catch {};
    } else if (hovered) queueRowHighlight(state, row);
}

/// Enabled labels always use primary text; only unavailable actions look disabled.
pub fn labelColor(enabled: bool, highlighted: bool) [4]f32 {
    _ = highlighted;
    return if (enabled) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
}

/// Close/remove actions retain their danger role without tinting the whole row.
pub fn actionColor(enabled: bool, destructive: bool) [4]f32 {
    return if (!enabled) theme.COLOR_TEXT_SUBTLE else if (destructive) theme.legibleOn(theme.danger(), theme.COLOR_PANEL_ALT) else theme.COLOR_WHITE;
}

/// Leading icon in the same reserved column as selection checks.
/// Reserve CHECK_SLOT_UI on every label in a menu that contains any icons.
pub fn queueIcon(state: *runtime.AppState, row: palette.Rect, glyph: []const u8, icon_color: [4]f32, clip: palette.Rect) void {
    const size = theme.scaledUi(ICON_SIZE_UI);
    queueRoleText(state, .{
        .x = row.x + theme.scaledUi(LABEL_INSET_UI),
        .y = row.y + (row.h - size) * 0.5,
        .w = size,
        .h = size,
    }, glyph, icon_color, size, .icon, clip);
}

/// Row label, vertically centred. `leading`/`trailing` reserve room for a
/// check mark or chevron.
pub fn queueLabel(state: *runtime.AppState, row: palette.Rect, label: []const u8, text_color: [4]f32, leading: f32, trailing: f32, clip: palette.Rect) void {
    const font_size = theme.scaledUi(FONT_SIZE_UI);
    const line_h = font_size * 1.25;
    const inset = theme.scaledUi(LABEL_INSET_UI);
    // Native menu labels can carry a tab-separated accelerator. Protect its
    // trailing column, and never let it inherit the action's danger colour.
    const shortcut_at = std.mem.indexOfScalar(u8, label, '\t');
    const title = if (shortcut_at) |index| label[0..index] else label;
    const shortcut = if (shortcut_at) |index| label[index + 1 ..] else "";
    const shortcut_w = text_measure.textWidth(.ui, font_size, shortcut);
    const shortcut_slot = if (shortcut.len > 0) shortcut_w + theme.scaledUi(16) else 0;
    if (shortcut.len > 0) queueRoleText(state, .{
        .x = row.x + row.w - inset - trailing - shortcut_w,
        .y = row.y + (row.h - line_h) * 0.5,
        .w = shortcut_w,
        .h = line_h,
    }, shortcut, theme.COLOR_TEXT_MUTED, font_size, .ui, clip);
    const title_rect: palette.Rect = .{
        .x = row.x + inset + leading,
        .y = row.y + (row.h - line_h) * 0.5,
        .w = @max(row.w - inset * 2.0 - leading - trailing - shortcut_slot, 1.0),
        .h = line_h,
    };
    var shown = title;
    var end = title.len;
    while (text_measure.textWidth(.ui, font_size, shown) > title_rect.w and end > 0) {
        end -= 1;
        while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
        shown = std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}…", .{title[0..end]}) catch "";
    }
    const text_clip: palette.Rect = .{
        .x = @max(clip.x, title_rect.x),
        .y = clip.y,
        .w = @max(@min(clip.x + clip.w, title_rect.x + title_rect.w) - @max(clip.x, title_rect.x), 0),
        .h = clip.h,
    };
    queueRoleText(state, title_rect, shown, text_color, font_size, .ui, text_clip);
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

/// Pair releases only with presses actually consumed by a menu or modal.
/// A modifier held before an overlay opens must still release in the webview.
pub const KeyReleaseCapture = struct {
    const Key = struct {
        code: palette.event.Keycode,
        scancode: u32,

        fn matches(self: Key, event: *const palette.event.KeyEvent) bool {
            return if (self.scancode != 0 and event.scancode != 0)
                self.scancode == event.scancode
            else
                self.code == event.key;
        }
    };
    keys: [16]?Key = .{null} ** 16,

    pub fn capture(self: *KeyReleaseCapture, event: *const palette.event.KeyEvent) void {
        // A repeat may belong to a key pressed in the webview before the
        // overlay opened; it does not transfer ownership of that release.
        if (!event.down or event.repeat) return;
        for (self.keys) |key| if (key) |held| {
            if (held.matches(event)) return; // Auto-repeat is one held key.
        };
        for (&self.keys) |*key| if (key.* == null) {
            key.* = .{ .code = event.key, .scancode = event.scancode };
            return;
        };
    }

    pub fn release(self: *KeyReleaseCapture, event: *const palette.event.KeyEvent) bool {
        for (&self.keys) |*key| if (key.*) |held| {
            if (held.matches(event)) {
                key.* = null;
                return true;
            }
        };
        return false;
    }
};

test "menu key releases preserve modifiers pressed before an overlay opens" {
    var captured: KeyReleaseCapture = .{};
    const ctrl_up: palette.event.KeyEvent = .{ .key = .unknown, .scancode = 29, .down = false };
    try std.testing.expect(!captured.release(&ctrl_up));
    captured.capture(&.{ .key = .character, .scancode = 37, .codepoint = 'k', .repeat = true });
    try std.testing.expect(!captured.release(&.{ .key = .character, .scancode = 37, .down = false }));
    captured.capture(&.{ .key = .character, .scancode = 37, .codepoint = 'k' });
    captured.capture(&.{ .key = .escape, .scancode = 1 });
    // Opening the palette while Ctrl is already held cannot capture its release.
    try std.testing.expect(!captured.release(&ctrl_up));
    try std.testing.expect(captured.release(&.{ .key = .character, .scancode = 37, .down = false }));
    try std.testing.expect(!captured.release(&.{ .key = .character, .scancode = 37, .down = false }));
    try std.testing.expect(captured.release(&.{ .key = .escape, .scancode = 1, .down = false }));
    // Multiple printable keys use physical identity, not the shared .character tag.
    captured.capture(&.{ .key = .character, .scancode = 30, .codepoint = 'a' });
    captured.capture(&.{ .key = .character, .scancode = 48, .codepoint = 'b' });
    try std.testing.expect(captured.release(&.{ .key = .character, .scancode = 48, .down = false }));
    try std.testing.expect(captured.release(&.{ .key = .character, .scancode = 30, .down = false }));
}

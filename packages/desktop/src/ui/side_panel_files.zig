//! Files view of the right side panel: an explorer over the workspace's
//! folders. Opening a file shows it in its own workspace tab.
//!
//! Hook contract with `side_panel.zig`, which owns the panel chrome, routes
//! input here only while this view is selected, and passes body-local rects:
//! - `render` draws into `rect` (the panel body) each frame. `focused` is
//!   true while the panel body owns the keyboard.
//! - `handleMouseButton` / `handleMouseMotion` / `handleWheel` get window
//!   coordinates already known to lie in the body (button-up and motion also
//!   arrive while a drag that started here is in progress). Return true when
//!   consumed; the panel swallows body clicks either way.
//! - `handleKey` / `handleTextInput` run only while the body is focused.
//!   Return false to let the panel and app shortcuts see the key.
//! - `wantsTextInput` keeps SDL text input on while a field here is focused.
//! - `systemCursorAt` picks the pointer shape over the body.
//! - `resetHitCache` runs at the start of every panel render.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

pub fn resetHitCache() void {}

pub fn render(state: *runtime.AppState, rect: palette.Rect, focused: bool) void {
    // Region: placeholder until the view lands.
    _ = focused;
    const font = theme.scaledUi(12.0);
    const pad = theme.scaledUi(16.0);
    const hint = "The workspace file tree will appear here.";
    const line_h = font * 1.4;
    const text_rect: palette.Rect = .{ .x = rect.x + pad, .y = rect.y + pad, .w = @max(rect.w - pad * 2.0, 0.0), .h = line_h };
    const text = state.palette_frame_text_arena.allocator().dupe(u8, hint) catch return;
    const color = theme.COLOR_TEXT_MUTED;
    state.palette_overlay_batch.roleText(state.allocator, text_rect, text, .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, font, .ui, null, rect) catch {};
}

pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    _ = state;
    _ = x;
    _ = y;
    _ = down;
    _ = clicks;
    return false;
}

pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    _ = state;
    _ = x;
    _ = y;
    return false;
}

pub fn handleWheel(state: *runtime.AppState, x: f32, y: f32, wheel_y: f32) bool {
    _ = state;
    _ = x;
    _ = y;
    _ = wheel_y;
    return false;
}

pub fn handleKey(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    _ = state;
    _ = event;
    return false;
}

pub fn handleTextInput(state: *runtime.AppState, text: []const u8) bool {
    _ = state;
    _ = text;
    return false;
}

pub fn wantsTextInput(state: *runtime.AppState) bool {
    _ = state;
    return false;
}

pub fn systemCursorAt(state: *runtime.AppState, x: f32, y: f32) ?sdl.SystemCursor {
    _ = state;
    _ = x;
    _ = y;
    return null;
}

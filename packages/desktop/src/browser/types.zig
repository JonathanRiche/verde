//! Shared browser runtime types.

const std = @import("std");

/// Identifies the browser runtime family backing the desktop pane.
pub const RuntimeKind = enum {
    native_webview,
    stub,
};

/// Selects the concrete browser backend built into the desktop app.
pub const BackendKind = enum {
    native_webview,
    stub,
};

/// Controls whether the browser runtime stays resident after the pane is closed.
pub const RuntimeMode = enum {
    keep_warm,
    shutdown_on_close,
};

/// Describes how browser pixels/input are presented inside the Palette-owned pane.
pub const PresentationKind = enum {
    native_child_view,
    native_wayland_surface,
    helper_window,
    snapshot_texture,
    offscreen_texture,
    stub,
};

/// Identifies one browser pane session within the desktop app.
pub const SessionId = u32;

/// Screen-space rectangle reserved by Palette for a native browser surface.
pub const PaneBounds = struct {
    screen_x: i32 = 0,
    screen_y: i32 = 0,
    width: u32 = 1,
    height: u32 = 1,
    scale: f32 = 1.0,
};

/// Native Wayland handles exported by SDL for app-owned child surfaces.
pub const LinuxWaylandHost = extern struct {
    display: ?*anyopaque = null,
    surface: ?*anyopaque = null,
};

/// Tracks the host-side lifecycle of the native browser runtime.
pub const Status = enum {
    hidden,
    opening,
    ready,
    failed,
};

/// Browser-requested pointer shapes normalized across rendering backends.
pub const CursorShape = enum {
    default,
    pointer,
    text,
    vertical_text,
    crosshair,
    wait,
    progress,
    help,
    context_menu,
    cell,
    alias,
    copy,
    move,
    grab,
    grabbing,
    no_drop,
    not_allowed,
    col_resize,
    row_resize,
    ew_resize,
    ns_resize,
    nwse_resize,
    nesw_resize,
    n_resize,
    ne_resize,
    e_resize,
    se_resize,
    s_resize,
    sw_resize,
    w_resize,
    nw_resize,
    all_scroll,
    zoom_in,
    zoom_out,
    hidden,
    custom,

    /// Parses a helper-protocol cursor name, safely falling back for newer runtime values.
    pub fn parse(value: []const u8) CursorShape {
        return std.meta.stringToEnum(CursorShape, value) orelse .default;
    }
};

/// Carries notifications from the platform backend back into app state.
pub const Event = union(enum) {
    opened,
    closed,
    navigated: []u8,
    title_changed: []u8,
    document_loaded,
    cursor_changed: CursorShape,
    js_message: []u8,
    eval_result: []u8,
    context_menu: []u8,
    context_menu_dismissed,
    failed: []u8,

    /// Releases any heap-allocated payloads carried by the event.
    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .navigated => |value| allocator.free(value),
            .title_changed => |value| allocator.free(value),
            .js_message => |value| allocator.free(value),
            .eval_result => |value| allocator.free(value),
            .context_menu => |value| allocator.free(value),
            .failed => |value| allocator.free(value),
            else => {},
        }
    }
};

test "cursor shape protocol names parse with a safe fallback" {
    try std.testing.expectEqual(CursorShape.pointer, CursorShape.parse("pointer"));
    try std.testing.expectEqual(CursorShape.vertical_text, CursorShape.parse("vertical_text"));
    try std.testing.expectEqual(CursorShape.grabbing, CursorShape.parse("grabbing"));
    try std.testing.expectEqual(CursorShape.default, CursorShape.parse("future_cursor_shape"));
}

//! Process-wide access to the desktop's palette-native app and main window.
//!
//! Verde has one native window. Clipboard, live modifier state, held keys and
//! the pointer cursor are services of that app rather than of a particular UI
//! component, so components reach them here instead of threading `*App`
//! through every call. `main.zig` installs the app after creating the window
//! and uninstalls it before teardown; tests run without one, in which case
//! clipboard calls fail with `error.NoPlatform` and modifier queries report
//! nothing held.

const std = @import("std");
const palette = @import("palette");

const platform = palette.platform;
const keyboard = palette.keyboard;
const Mods = palette.event.Mods;

pub const App = platform.App;
pub const Window = platform.Window;
pub const CursorShape = platform.CursorShape;

pub const Error = error{NoPlatform};

var installed_app: ?*App = null;
var installed_window: ?*Window = null;
var held_keys: keyboard.State = .{};
var cursor_shape: CursorShape = .default;
/// False when the platform cursor may differ from `cursor_shape` (a native
/// child view set its own), so the next `setCursor` is always sent.
var cursor_known: bool = true;

/// Makes `app` and its main `window` the process-wide UI host.
pub fn install(platform_app: *App, main_window: *Window) void {
    installed_app = platform_app;
    installed_window = main_window;
    held_keys = .{};
    cursor_shape = .default;
    cursor_known = true;
}

/// Clears the host before the window and app are destroyed.
pub fn uninstall() void {
    installed_app = null;
    installed_window = null;
    held_keys = .{};
}

pub fn app() ?*App {
    return installed_app;
}

pub fn window() ?*Window {
    return installed_window;
}

/// Feeds every platform event so held-key queries stay current. Keys are
/// released on focus loss; modifiers pressed elsewhere are picked up on focus
/// gain, as SDL's keyboard state did.
pub fn noteEvent(event: palette.Event) void {
    _ = held_keys.handle(event);
    if (event == .focus_gained) {
        if (installed_app) |a| held_keys.syncModifiers(a.modKeys());
    }
}

/// Whether the physical key is currently held (HID scancode).
pub fn isKeyDown(scancode: keyboard.Scancode) bool {
    return held_keys.isDown(scancode);
}

/// Effective modifier state right now (latched and locked modifiers included).
pub fn modState() Mods {
    const a = installed_app orelse return .{};
    return a.modState();
}

/// Copies UTF-8 `text` to the system clipboard.
pub fn setClipboardText(text: []const u8) !void {
    const a = installed_app orelse return error.NoPlatform;
    try a.setClipboardText(text);
}

/// Reads the clipboard as UTF-8, or null when it holds no text. The caller
/// frees the result with `allocator`.
pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
    const a = installed_app orelse return error.NoPlatform;
    return a.getClipboardText(allocator);
}

/// Shows `shape` over the main window, skipping redundant protocol requests.
pub fn setCursor(shape: CursorShape) void {
    if (cursor_known and shape == cursor_shape) return;
    cursor_shape = shape;
    cursor_known = true;
    if (installed_window) |w| w.setCursor(shape);
}

/// Forces the next `setCursor` through even if the shape is unchanged.
pub fn invalidateCursor() void {
    cursor_known = false;
}

/// The shape most recently requested through `setCursor`.
pub fn currentCursor() CursorShape {
    return cursor_shape;
}

test "held keys follow key events and clear on focus loss" {
    const previous = held_keys;
    defer held_keys = previous;
    held_keys = .{};

    noteEvent(.{ .key_down = .{ .key = .lctrl, .scancode = 29 } });
    try std.testing.expect(isKeyDown(.lctrl));
    noteEvent(.{ .focus_lost = .{} });
    try std.testing.expect(!isKeyDown(.lctrl));
}

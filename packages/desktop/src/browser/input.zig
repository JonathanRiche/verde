//! Browser-pane input events translated from SDL before they cross the backend boundary.

const std = @import("std");

/// Enumerates pointer buttons the browser pane cares about.
pub const MouseButton = enum {
    left,
    middle,
    right,
    back,
    forward,
};

pub fn parseMouseButton(value: []const u8) ?MouseButton {
    if (std.mem.eql(u8, value, "left")) return .left;
    if (std.mem.eql(u8, value, "middle")) return .middle;
    if (std.mem.eql(u8, value, "right")) return .right;
    if (std.mem.eql(u8, value, "back")) return .back;
    if (std.mem.eql(u8, value, "forward")) return .forward;
    return null;
}

/// Carries normalized pointer input into the browser runtime.
pub const MouseEvent = struct {
    x: f32,
    y: f32,
    button: ?MouseButton = null,
    pressed: bool = false,
    wheel_x: f32 = 0.0,
    wheel_y: f32 = 0.0,
    wheel_multiplier: f32 = 1.0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

/// Carries normalized keyboard input into the browser runtime.
pub const KeyEvent = struct {
    key_code: u32,
    text: ?[]const u8 = null,
    pressed: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    super: bool = false,
};

test "automation mouse buttons parse explicitly" {
    const testing = std.testing;
    try testing.expectEqual(MouseButton.left, parseMouseButton("left").?);
    try testing.expectEqual(MouseButton.middle, parseMouseButton("middle").?);
    try testing.expectEqual(MouseButton.right, parseMouseButton("right").?);
    try testing.expectEqual(MouseButton.back, parseMouseButton("back").?);
    try testing.expectEqual(MouseButton.forward, parseMouseButton("forward").?);
    try testing.expect(parseMouseButton("primary") == null);
}

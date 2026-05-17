//! Browser-pane input events translated from SDL before they cross the backend boundary.

/// Enumerates pointer buttons the browser pane cares about.
pub const MouseButton = enum {
    left,
    middle,
    right,
    back,
    forward,
};

/// Carries normalized pointer input into the browser runtime.
pub const MouseEvent = struct {
    x: f32,
    y: f32,
    button: ?MouseButton = null,
    pressed: bool = false,
    wheel_x: f32 = 0.0,
    wheel_y: f32 = 0.0,
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

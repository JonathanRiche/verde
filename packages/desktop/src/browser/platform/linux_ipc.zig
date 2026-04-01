//! Shared JSON-line protocol between the desktop app and Linux browser helper.

/// Enumerates the commands the desktop app can send to the Linux browser helper.
pub const CommandKind = enum {
    show,
    hide,
    resize_pane,
    navigate,
    eval,
    post_json,
    mouse_move,
    mouse_button,
    mouse_wheel,
    key_input,
    text_input,
    quit,
};

/// Encodes one browser helper command.
pub const Command = struct {
    kind: CommandKind,
    width: u32 = 0,
    height: u32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    wheel_x: f32 = 0.0,
    wheel_y: f32 = 0.0,
    button: u8 = 0,
    pressed: bool = false,
    key_code: u32 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    payload: ?[]const u8 = null,
};

/// Enumerates the events the Linux browser helper can emit back to the desktop app.
pub const EventKind = enum {
    opened,
    closed,
    navigated,
    js_message,
    eval_result,
    frame_ready,
    failed,
};

/// Encodes one browser helper event.
pub const Event = struct {
    kind: EventKind,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    payload: ?[]const u8 = null,
    frame_path: ?[]const u8 = null,
};

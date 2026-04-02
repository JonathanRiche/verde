//! Shared protocol types for the Linux CEF helper process.

/// Enumerates the commands the desktop app can send into the Linux CEF helper.
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

/// Encodes one helper command payload.
pub const Command = struct {
    kind: CommandKind,
    session_id: u32 = 0,
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

/// Enumerates the events the Linux CEF helper can emit back into app state.
pub const EventKind = enum {
    opened,
    closed,
    navigated,
    title_changed,
    js_message,
    eval_result,
    frame_ready,
    failed,
};

/// Encodes one helper event payload.
pub const Event = struct {
    kind: EventKind,
    session_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    frame_slot: u8 = 0,
    payload: ?[]const u8 = null,
};

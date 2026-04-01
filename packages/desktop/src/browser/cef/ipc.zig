//! Shared protocol types for the Linux CEF helper process.

/// Enumerates the commands the desktop app can send into the Linux CEF helper.
pub const CommandKind = enum {
    show,
    hide,
    resize_pane,
    navigate,
    eval,
    post_json,
    quit,
};

/// Encodes one helper command payload.
pub const Command = struct {
    kind: CommandKind,
    session_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
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
    payload: ?[]const u8 = null,
    frame_path: ?[]const u8 = null,
};

//! Palette-owned platform event model.
//!
//! Platform backends (Wayland today; AppKit/Win32 later) translate native input into these
//! events. Tag and field names intentionally mirror the SDL3 events Palette used to consume
//! so hosts migrating from SDL can map their dispatch code one-to-one.
//!
//! Coordinates are in logical (surface) units, matching what components lay out in, unless a
//! field says otherwise. Text slices are only valid for the duration of the dispatch call.

const std = @import("std");
const keyboard = @import("keyboard.zig");

pub const WindowId = enum(u32) { invalid = 0, _ };

pub const Mods = packed struct(u16) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _pad: u10 = 0,

    pub const none: Mods = .{};

    /// "Primary" shortcut modifier: Ctrl on Linux/Windows, Cmd (super) on macOS. Palette
    /// components treat either as primary, matching the previous SDL behaviour.
    pub fn primary(self: Mods) bool {
        return self.ctrl or self.super;
    }
};

/// Physical modifier keys held down, by side (SDL's L/R `SDL_Keymod` bits). `Mods` is the
/// effective XKB state; this tracks the keys themselves.
pub const ModKeys = packed struct(u8) {
    lshift: bool = false,
    rshift: bool = false,
    lctrl: bool = false,
    rctrl: bool = false,
    lalt: bool = false,
    ralt: bool = false,
    lgui: bool = false,
    rgui: bool = false,

    /// Updates the bit for a Linux evdev key code; other codes are ignored.
    pub fn set(self: *ModKeys, evdev: u32, down: bool) void {
        switch (evdev) {
            42 => self.lshift = down,
            54 => self.rshift = down,
            29 => self.lctrl = down,
            97 => self.rctrl = down,
            56 => self.lalt = down,
            100 => self.ralt = down,
            125 => self.lgui = down,
            126 => self.rgui = down,
            else => {},
        }
    }

    /// Reconciles held sides with the effective modifier state `mods` (what SDL reports as
    /// `SDL_Keymod` L/R bits): an active modifier reports the side(s) actually held, or the
    /// left side if none is tracked (latched/locked, or pressed before focus); a held key
    /// whose modifier is not active (e.g. Shift during a Shift+Shift lock toggle) is dropped.
    pub fn effective(self: ModKeys, mods: Mods) ModKeys {
        return .{
            .lshift = mods.shift and (self.lshift or !self.rshift),
            .rshift = mods.shift and self.rshift,
            .lctrl = mods.ctrl and (self.lctrl or !self.rctrl),
            .rctrl = mods.ctrl and self.rctrl,
            .lalt = mods.alt and (self.lalt or !self.ralt),
            .ralt = mods.alt and self.ralt,
            .lgui = mods.super and (self.lgui or !self.rgui),
            .rgui = mods.super and self.rgui,
        };
    }
};

/// Named, layout-resolved key identities. Values are not stable ABI; compare by tag.
/// Names follow SDL3 `SDL_Keycode` spelling so host keybind tables port unchanged.
pub const Keycode = enum(u16) {
    unknown = 0,
    @"return",
    escape,
    backspace,
    tab,
    space,
    delete,
    insert,
    home,
    end,
    pageup,
    pagedown,
    left,
    right,
    up,
    down,
    kp_enter,
    caps_lock,
    num_lock,
    scroll_lock,
    print_screen,
    pause,
    menu,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    lshift,
    rshift,
    lctrl,
    rctrl,
    lalt,
    ralt,
    lgui,
    rgui,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    minus,
    equals,
    leftbracket,
    rightbracket,
    backslash,
    semicolon,
    apostrophe,
    grave,
    comma,
    period,
    slash,
    /// A printable key without a dedicated tag; see `KeyEvent.codepoint`.
    character,
    // Keypad (distinct from the main block regardless of NumLock, like SDL).
    kp_divide,
    kp_multiply,
    kp_minus,
    kp_plus,
    kp_period,
    kp_equals,
    kp_comma,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    help,
    undo,
    cut,
    copy,
    paste,
    find,
    mute,
    volumeup,
    volumedown,
    sysreq,
    cancel,
    again,
    select,
    execute,
    mode,
    sleep,
    media_play_pause,
    media_next_track,
    media_previous_track,
    media_stop,
    media_pause,
    ac_back,
    ac_forward,
    ac_refresh,
    ac_stop,
    ac_home,
    ac_search,
    ac_bookmarks,

    /// Maps a lowercase ASCII letter/digit to its keycode.
    pub fn fromAscii(ch: u8) Keycode {
        return switch (ch) {
            'a'...'z' => @enumFromInt(@intFromEnum(Keycode.a) + (ch - 'a')),
            'A'...'Z' => @enumFromInt(@intFromEnum(Keycode.a) + (ch - 'A')),
            '0'...'9' => @enumFromInt(@intFromEnum(Keycode.@"0") + (ch - '0')),
            ' ' => .space,
            '-' => .minus,
            '=' => .equals,
            '[' => .leftbracket,
            ']' => .rightbracket,
            '\\' => .backslash,
            ';' => .semicolon,
            '\'' => .apostrophe,
            '`' => .grave,
            ',' => .comma,
            '.' => .period,
            '/' => .slash,
            else => .character,
        };
    }
};

pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    back = 4,
    forward = 5,
    _,
};

pub const ButtonState = packed struct(u8) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
    back: bool = false,
    forward: bool = false,
    _pad: u3 = 0,
};

pub const KeyEvent = struct {
    window: WindowId = .invalid,
    /// Layout-resolved key (what the user's keymap produces at shift level 0).
    key: Keycode,
    /// Raw XKB keysym / platform virtual key for hosts that need full fidelity.
    keysym: u32 = 0,
    /// Platform-independent scancode (evdev code on Linux).
    scancode: u32 = 0,
    /// Unicode scalar the key produces with the current modifiers, or 0.
    codepoint: u21 = 0,
    /// Unicode scalar of the key's unshifted (level 0) symbol, or 0. Equals SDL's printable
    /// `SDL_Keycode` for keys without a dedicated tag (`.character`).
    base_codepoint: u21 = 0,
    mod: Mods = .{},
    /// Physical modifier keys held when the event was generated (left/right).
    mod_keys: ModKeys = .{},
    down: bool = true,
    repeat: bool = false,

    /// USB HID usage of the physical key (equal to `SDL_Scancode`).
    pub fn hidScancode(k: KeyEvent) keyboard.Scancode {
        return keyboard.scancodeFromEvdev(k.scancode);
    }

    /// Layout-aware shortcut character for `.character` keys, matching SDL's printable
    /// `SDL_Keycode`: number-row keys report their digit even on layouts whose unshifted
    /// symbol is not a digit (AZERTY), letters are lowercased, and keys without a symbol
    /// report 0. Use for keybind matching; use `codepoint` / text events for text.
    pub fn shortcutCodepoint(k: KeyEvent) u21 {
        if (k.key != .character) return 0;
        if (k.scancode >= 2 and k.scancode <= 11) {
            return if (k.scancode == 11) '0' else @intCast('0' + k.scancode - 1);
        }
        return keyboard.lowerLatin(k.base_codepoint);
    }
};

pub const MotionEvent = struct {
    window: WindowId = .invalid,
    x: f32,
    y: f32,
    xrel: f32 = 0,
    yrel: f32 = 0,
    state: ButtonState = .{},
};

pub const ButtonEvent = struct {
    window: WindowId = .invalid,
    x: f32,
    y: f32,
    button: u8 = @intFromEnum(MouseButton.left),
    clicks: u8 = 1,
    down: bool = true,
};

pub const WheelEvent = struct {
    window: WindowId = .invalid,
    /// Scroll amount in lines. Positive `y` scrolls content up (wheel away from user),
    /// matching SDL's convention.
    x: f32 = 0,
    y: f32 = 0,
    /// True when the source is a touchpad/continuous device (values are fractional).
    precise: bool = false,
    mouse_x: f32,
    mouse_y: f32,
};

pub const TextEvent = struct {
    window: WindowId = .invalid,
    text: []const u8,
};

/// IME pre-edit (composition) text. Empty `text` ends composition.
pub const EditEvent = struct {
    window: WindowId = .invalid,
    text: []const u8,
    /// Cursor range within `text`, in bytes. `-1` means hidden.
    cursor_begin: i32 = -1,
    cursor_end: i32 = -1,
};

pub const ResizeEvent = struct {
    window: WindowId = .invalid,
    /// Logical size.
    width: i32,
    height: i32,
    /// Drawable size in device pixels.
    pixel_width: i32,
    pixel_height: i32,
    scale: f32,
};

pub const WindowEvent = struct {
    window: WindowId = .invalid,
};

pub const VisibilityEvent = struct {
    window: WindowId = .invalid,
    reason: Reason = .unmapped,

    pub const Reason = enum {
        /// `Window.hide()` / `Window.show()`.
        unmapped,
        /// xdg_toplevel `suspended` state toggled (minimized, other workspace, locked).
        suspended,
    };
};

pub const Event = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    text_input: TextEvent,
    text_editing: EditEvent,
    mouse_motion: MotionEvent,
    mouse_button_down: ButtonEvent,
    mouse_button_up: ButtonEvent,
    mouse_wheel: WheelEvent,
    mouse_enter: MotionEvent,
    mouse_leave: WindowEvent,
    focus_gained: WindowEvent,
    focus_lost: WindowEvent,
    resized: ResizeEvent,
    close_requested: WindowEvent,
    /// The window stopped being shown (`hide()`, or the compositor suspended it).
    window_hidden: VisibilityEvent,
    /// The window is shown again. Redraw it.
    window_shown: VisibilityEvent,
    /// The compositor is ready for a new frame (frame callback fired). Hosts that track
    /// dirty state should redraw now if anything changed.
    frame: WindowEvent,
    /// Clipboard / selection contents changed on the system.
    clipboard_update: WindowEvent,
    /// The system light/dark appearance changed; query `App.systemTheme()` (macOS; backends
    /// without a theme source never send it).
    system_theme_changed: void,
    /// Posted by `App.wakeup()` from any thread.
    user: u64,
    quit: void,
};

test "ModKeys.effective and KeyEvent shortcut helpers" {
    const k: ModKeys = .{ .rshift = true, .lctrl = true };
    const e = k.effective(.{ .shift = true, .alt = true });
    try std.testing.expect(e.rshift and !e.lshift); // held side
    try std.testing.expect(e.lalt and !e.ralt); // active but untracked -> left
    try std.testing.expect(!e.lctrl); // held but inactive -> dropped
    const azerty_1: KeyEvent = .{ .key = .character, .scancode = 2, .base_codepoint = '&' };
    try std.testing.expectEqual(@as(u21, '1'), azerty_1.shortcutCodepoint());
    const upper: KeyEvent = .{ .key = .character, .scancode = 30, .base_codepoint = 'A' };
    try std.testing.expectEqual(@as(u21, 'a'), upper.shortcutCodepoint());
    try std.testing.expectEqual(keyboard.Scancode.a, upper.hidScancode());
    const latin1: KeyEvent = .{ .key = .character, .scancode = 39, .base_codepoint = 0xc9 };
    try std.testing.expectEqual(@as(u21, 0xe9), latin1.shortcutCodepoint());
    try std.testing.expectEqual(@as(u21, 0), (KeyEvent{ .key = .escape, .scancode = 1 }).shortcutCodepoint());
}

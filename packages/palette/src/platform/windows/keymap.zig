//! Pure Win32 keyboard tables (no OS calls; unit-tested on every host).
//!
//! * `evdevFromScancode`: PC/AT set-1 scancode as Windows reports it (lParam bits 16-23 plus
//!   the extended bit 24) → Linux evdev code. `KeyEvent.scancode` carries evdev codes on every
//!   platform, so the SDL adapter's evdev → USB HID table (and `ModKeys.set`) work unchanged.
//!   The Windows quirks SDL handles are applied: non-extended 0x45 is Pause (the E1 prefix is
//!   dropped by Windows), extended 0x45 is NumLock, and a zero scancode (synthetic/multimedia
//!   keys) is recovered from the virtual key with `MapVirtualKey(MAPVK_VK_TO_VSC_EX)` by the
//!   caller.
//! * `keycodeFromVk`: virtual key → palette `Keycode` (layout-resolved: Windows already maps
//!   letter/digit VKs through the active layout; OEM keys need their unshifted character,
//!   passed in by the caller from `ToUnicode` with an empty key state).
//! * `rawScancode`: the inverse of `evdevFromScancode` (set-1 code | 0xE000 when extended),
//!   which is what SDL3 puts into `SDL_KeyboardEvent.raw` on Windows.
const std = @import("std");
const w = @import("win32.zig");
const ev = @import("../../event.zig");

/// set-1 scancode (low byte) → evdev, for keys without the E0 prefix.
const plain = blk: {
    var t = [_]u16{0} ** 128;
    // 0x01..0x58 coincide with evdev KEY_ESC..KEY_F12 (both derive from the AT set-1 order).
    for (0x01..0x59) |i| t[i] = i;
    t[0x45] = 119; // Pause (Windows drops the E1 1D prefix) → KEY_PAUSE
    t[0x54] = 99; // Alt+PrintScreen (SysRq) → KEY_SYSRQ
    t[0x55] = 0;
    t[0x59] = 117; // KEY_KPEQUAL
    t[0x5A] = 0;
    t[0x5C] = 95; // KEY_KPJPCOMMA
    // F13..F23 = 0x64..0x6E, F24 = 0x76 (Microsoft keyboard scan code specification)
    for (0x64..0x6F, 0..) |i, k| t[i] = 183 + k;
    t[0x70] = 93; // KEY_KATAKANAHIRAGANA
    t[0x71] = 123; // KEY_HANJA (lang2)
    t[0x72] = 122; // KEY_HANGEUL (lang1)
    t[0x73] = 89; // KEY_RO (international1)
    t[0x76] = 194; // KEY_F24
    t[0x77] = 91; // KEY_HIRAGANA (lang4)
    t[0x78] = 90; // KEY_KATAKANA (lang3)
    t[0x79] = 92; // KEY_HENKAN (international4)
    t[0x7B] = 94; // KEY_MUHENKAN (international5)
    t[0x7D] = 124; // KEY_YEN (international3)
    t[0x7E] = 121; // KEY_KPCOMMA (Brazilian keypad .)
    break :blk t;
};

/// set-1 scancode (low byte) → evdev, for E0-prefixed (extended) keys.
const extended = blk: {
    var t = [_]u16{0} ** 128;
    const pairs = [_][2]u16{
        .{ 0x10, 165 }, // previous track
        .{ 0x19, 163 }, // next track
        .{ 0x1C, 96 }, // keypad enter
        .{ 0x1D, 97 }, // right ctrl
        .{ 0x20, 113 }, // mute
        .{ 0x21, 140 }, // calculator
        .{ 0x22, 164 }, // play/pause
        .{ 0x24, 166 }, // stop
        .{ 0x2E, 114 }, // volume down
        .{ 0x30, 115 }, // volume up
        .{ 0x32, 172 }, // browser home
        .{ 0x35, 98 }, // keypad /
        .{ 0x37, 99 }, // print screen (KEY_SYSRQ)
        .{ 0x38, 100 }, // right alt
        .{ 0x45, 69 }, // NumLock (Windows sets the extended bit)
        .{ 0x46, 119 }, // Ctrl+Break → pause
        .{ 0x47, 102 }, // home
        .{ 0x48, 103 }, // up
        .{ 0x49, 104 }, // page up
        .{ 0x4B, 105 }, // left
        .{ 0x4D, 106 }, // right
        .{ 0x4F, 107 }, // end
        .{ 0x50, 108 }, // down
        .{ 0x51, 109 }, // page down
        .{ 0x52, 110 }, // insert
        .{ 0x53, 111 }, // delete
        .{ 0x5B, 125 }, // left gui
        .{ 0x5C, 126 }, // right gui
        .{ 0x5D, 127 }, // application (KEY_COMPOSE)
        .{ 0x5E, 116 }, // power
        .{ 0x5F, 142 }, // sleep
        .{ 0x63, 143 }, // wake
        .{ 0x65, 217 }, // browser search
        .{ 0x66, 156 }, // favorites (bookmarks)
        .{ 0x67, 173 }, // refresh
        .{ 0x68, 128 }, // browser stop (KEY_STOP)
        .{ 0x69, 159 }, // browser forward
        .{ 0x6A, 158 }, // browser back
        .{ 0x6B, 157 }, // my computer
        .{ 0x6C, 155 }, // mail
        .{ 0x6D, 226 }, // media select
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

/// Windows keystroke scancode → evdev code (0 = unknown). `sc` is lParam bits 16-23 (the
/// high bit, set by some on-screen keyboards, is stripped); `ext` is lParam bit 24. A scancode
/// of the form 0xE0xx (from MAPVK_VK_TO_VSC_EX) is accepted too.
pub fn evdevFromScancode(sc_in: u16, ext_in: bool) u16 {
    var sc = sc_in;
    var ext = ext_in;
    if (sc == 0xE11D) return 119; // MAPVK_VK_TO_VSC_EX for VK_PAUSE
    if (sc >> 8 == 0xE0 or sc >> 8 == 0xE1) {
        ext = true;
        sc &= 0xFF;
    }
    sc &= 0x7F;
    return if (ext) extended[sc] else plain[sc];
}

/// Inverse of `evdevFromScancode`: the Windows scancode with 0xE000 for extended keys (what
/// SDL3 stores in `SDL_KeyboardEvent.raw` on Windows). 0 when the code has no set-1 key.
pub fn rawScancode(evdev: u32) u16 {
    if (evdev == 119) return 0xE046; // SDL reports Pause as 0xE046
    if (evdev == 69) return 0x45;
    for (extended, 0..) |e, i| if (e == evdev and e != 0) return 0xE000 | @as(u16, @intCast(i));
    for (plain, 0..) |e, i| if (e == evdev and e != 0) return @intCast(i);
    return 0;
}

/// Splits a WM_KEY* lParam: scancode, extended, previous-state (repeat) and release bits.
pub const KeyFlags = struct {
    scancode: u16,
    extended: bool,
    repeat: bool,
    up: bool,
    alt_down: bool,
    count: u16,

    pub fn fromLparam(lp: w.LPARAM) KeyFlags {
        const v: u32 = @truncate(@as(usize, @bitCast(lp)));
        const hi: u16 = @truncate(v >> 16);
        return .{
            .count = @truncate(v),
            .scancode = hi & 0xFF,
            .extended = hi & w.KF_EXTENDED != 0,
            .alt_down = hi & 0x2000 != 0,
            .repeat = hi & w.KF_REPEAT != 0,
            .up = hi & w.KF_UP != 0,
        };
    }
};

/// Builds a WM_KEY* lParam (for synthetic messages in tests and live checks).
pub fn makeKeyLparam(scancode: u8, ext: bool, repeat: bool, up: bool) w.LPARAM {
    var hi: u32 = scancode;
    if (ext) hi |= w.KF_EXTENDED;
    if (repeat) hi |= w.KF_REPEAT;
    if (up) hi |= w.KF_UP;
    const v: u32 = 1 | (hi << 16);
    return @as(i32, @bitCast(v));
}

/// Virtual key → palette keycode. `base_char` is the key's unshifted character for the
/// active layout (0 when none); it resolves OEM keys and anything without a dedicated VK.
/// `evdev` disambiguates keypad Enter and keys whose VK depends on NumLock (the keypad
/// reports VK_HOME etc. with NumLock off, but SDL keeps KP_ keycodes only with NumLock on;
/// with NumLock off SDL reports the navigation keycode, which is what the VK says).
pub fn keycodeFromVk(vk: u32, evdev: u16, base_char: u21) ev.Keycode {
    switch (vk) {
        'A'...'Z' => return ev.Keycode.fromAscii(@intCast(vk)),
        '0'...'9' => return ev.Keycode.fromAscii(@intCast(vk)),
        w.VK_NUMPAD0...w.VK_NUMPAD9 => return @enumFromInt(@intFromEnum(ev.Keycode.kp_0) + (vk - w.VK_NUMPAD0)),
        w.VK_F1...w.VK_F12 => return @enumFromInt(@intFromEnum(ev.Keycode.f1) + (vk - w.VK_F1)),
        w.VK_F13...w.VK_F24 => return @enumFromInt(@intFromEnum(ev.Keycode.f13) + (vk - w.VK_F13)),
        else => {},
    }
    const k: ev.Keycode = switch (vk) {
        w.VK_RETURN => if (evdev == 96) .kp_enter else .@"return",
        w.VK_ESCAPE => .escape,
        w.VK_BACK => .backspace,
        w.VK_TAB => .tab,
        w.VK_SPACE => .space,
        w.VK_DELETE => .delete,
        w.VK_INSERT => .insert,
        w.VK_HOME => .home,
        w.VK_END => .end,
        w.VK_PRIOR => .pageup,
        w.VK_NEXT => .pagedown,
        w.VK_LEFT => .left,
        w.VK_RIGHT => .right,
        w.VK_UP => .up,
        w.VK_DOWN => .down,
        w.VK_CAPITAL => .caps_lock,
        w.VK_NUMLOCK => .num_lock,
        w.VK_SCROLL => .scroll_lock,
        w.VK_SNAPSHOT => .print_screen,
        w.VK_PAUSE => .pause,
        w.VK_CANCEL => if (evdev == 119) .pause else .cancel,
        w.VK_APPS => .menu,
        w.VK_SHIFT => if (evdev == 54) .rshift else .lshift,
        w.VK_LSHIFT => .lshift,
        w.VK_RSHIFT => .rshift,
        w.VK_CONTROL => if (evdev == 97) .rctrl else .lctrl,
        w.VK_LCONTROL => .lctrl,
        w.VK_RCONTROL => .rctrl,
        w.VK_MENU => if (evdev == 100) .ralt else .lalt,
        w.VK_LMENU => .lalt,
        w.VK_RMENU => .ralt,
        w.VK_LWIN => .lgui,
        w.VK_RWIN => .rgui,
        w.VK_MULTIPLY => .kp_multiply,
        w.VK_ADD => .kp_plus,
        w.VK_SUBTRACT => .kp_minus,
        w.VK_DECIMAL => .kp_period,
        w.VK_DIVIDE => .kp_divide,
        w.VK_SEPARATOR => .kp_comma,
        w.VK_OEM_NEC_EQUAL => .kp_equals,
        w.VK_CLEAR => if (evdev == 76) .kp_5 else .unknown,
        w.VK_HELP => .help,
        w.VK_SELECT => .select,
        w.VK_EXECUTE => .execute,
        w.VK_SLEEP => .sleep,
        w.VK_MODECHANGE => .mode,
        w.VK_VOLUME_MUTE => .mute,
        w.VK_VOLUME_UP => .volumeup,
        w.VK_VOLUME_DOWN => .volumedown,
        w.VK_MEDIA_PLAY_PAUSE => .media_play_pause,
        w.VK_MEDIA_NEXT_TRACK => .media_next_track,
        w.VK_MEDIA_PREV_TRACK => .media_previous_track,
        w.VK_MEDIA_STOP => .media_stop,
        w.VK_BROWSER_BACK => .ac_back,
        w.VK_BROWSER_FORWARD => .ac_forward,
        w.VK_BROWSER_REFRESH => .ac_refresh,
        w.VK_BROWSER_STOP => .ac_stop,
        w.VK_BROWSER_HOME => .ac_home,
        w.VK_BROWSER_SEARCH => .ac_search,
        w.VK_BROWSER_FAVORITES => .ac_bookmarks,
        else => .unknown,
    };
    if (k != .unknown) return k;
    // OEM keys and anything else: the layout's unshifted character.
    if (base_char != 0) {
        if (base_char < 0x80) return ev.Keycode.fromAscii(@intCast(base_char));
        return .character;
    }
    return .unknown;
}

/// True for VKs whose unshifted character (from the layout) is worth looking up.
pub fn needsBaseChar(vk: u32) bool {
    return switch (vk) {
        'A'...'Z', '0'...'9', w.VK_SPACE => true,
        0xBA...0xC0, 0xDB...0xDF, 0xE1, 0xE2 => true,
        else => false,
    };
}

/// Updates the per-side modifier bits for an evdev code (same as `ModKeys.set`).
pub fn setModKey(keys: *ev.ModKeys, evdev: u16, down: bool) void {
    keys.set(evdev, down);
}

/// True when the evdev code is a modifier key (Shift/Ctrl/Alt/GUI, either side).
pub fn isModifier(evdev: u16) bool {
    return switch (evdev) {
        42, 54, 29, 97, 56, 100, 125, 126 => true,
        else => false,
    };
}

const testing = std.testing;

test "set-1 scancodes map to evdev with Windows quirks" {
    try testing.expectEqual(@as(u16, 1), evdevFromScancode(0x01, false)); // esc
    try testing.expectEqual(@as(u16, 30), evdevFromScancode(0x1E, false)); // a
    try testing.expectEqual(@as(u16, 29), evdevFromScancode(0x1D, false)); // lctrl
    try testing.expectEqual(@as(u16, 97), evdevFromScancode(0x1D, true)); // rctrl
    try testing.expectEqual(@as(u16, 56), evdevFromScancode(0x38, false)); // lalt
    try testing.expectEqual(@as(u16, 100), evdevFromScancode(0x38, true)); // ralt
    try testing.expectEqual(@as(u16, 96), evdevFromScancode(0x1C, true)); // kp enter
    try testing.expectEqual(@as(u16, 28), evdevFromScancode(0x1C, false)); // enter
    try testing.expectEqual(@as(u16, 119), evdevFromScancode(0x45, false)); // pause
    try testing.expectEqual(@as(u16, 69), evdevFromScancode(0x45, true)); // numlock
    try testing.expectEqual(@as(u16, 119), evdevFromScancode(0xE11D, false)); // VSC_EX pause
    try testing.expectEqual(@as(u16, 99), evdevFromScancode(0x37, true)); // print screen
    try testing.expectEqual(@as(u16, 55), evdevFromScancode(0x37, false)); // kp *
    try testing.expectEqual(@as(u16, 103), evdevFromScancode(0x48, true)); // up
    try testing.expectEqual(@as(u16, 72), evdevFromScancode(0x48, false)); // kp 8
    try testing.expectEqual(@as(u16, 125), evdevFromScancode(0x5B, true)); // lgui
    try testing.expectEqual(@as(u16, 127), evdevFromScancode(0x5D, true)); // application
    try testing.expectEqual(@as(u16, 183), evdevFromScancode(0x64, false)); // f13
    try testing.expectEqual(@as(u16, 193), evdevFromScancode(0x6E, false)); // f23
    try testing.expectEqual(@as(u16, 194), evdevFromScancode(0x76, false)); // f24
    try testing.expectEqual(@as(u16, 87), evdevFromScancode(0x57, false)); // f11
    try testing.expectEqual(@as(u16, 86), evdevFromScancode(0x56, false)); // 102nd
    try testing.expectEqual(@as(u16, 111), evdevFromScancode(0xE053, false)); // VSC_EX delete
    try testing.expectEqual(@as(u16, 30), evdevFromScancode(0x9E, false)); // break-code bit stripped
}

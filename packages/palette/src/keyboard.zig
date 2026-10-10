//! Keyboard helpers that are independent of SDL and of the platform backend.
//!
//! Every backend reports `KeyEvent.scancode` as a Linux evdev code (Wayland natively, AppKit
//! and Win32 through their keymaps), so the tables here work on all three OSes:
//!
//! * `Scancode`: USB HID keyboard usages (page 0x07), extended above 0xE7 for media / AC
//!   keys with SDL3's numbering, so values equal `SDL_Scancode` for hosts that persist or
//!   forward them (terminal key encoders, keybind files). `scancodeFromEvdev` is the same
//!   evdev -> HID mapping SDL uses on Linux (the inverse of the kernel's hid-input table).
//! * `KeyEvent.hidScancode()` / `KeyEvent.shortcutCodepoint()` (in `event.zig`) use them.
//! * `ModKeys.effective(mods)` (in `event.zig`): left/right modifier bits reconciled with the
//!   effective modifier state.
//! * `State`: which keys are held (by HID scancode), reset on focus loss the way
//!   `SDL_ResetKeyboard` does; replaces `SDL_GetKeyboardState`.
//!
//! The `Scancode` tag names and values follow the `Scancode` declaration in zsdl
//! (`packages/zsdl/src/sdl3.zig`, zig-gamedev), itself mirroring SDL3's `SDL_Scancode`.
//! zsdl's license:
//!
//! MIT License
//!
//! Copyright (c) 2023 Michal Ziulek
//! Copyright (c) 2024 zig-gamedev contributors
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
const std = @import("std");
const event = @import("event.zig");

/// USB HID keyboard usage (SDL3 numbering above 0xE7). Non-exhaustive.
pub const Scancode = enum(u16) {
    unknown = 0,
    a = 4,
    b = 5,
    c = 6,
    d = 7,
    e = 8,
    f = 9,
    g = 10,
    h = 11,
    i = 12,
    j = 13,
    k = 14,
    l = 15,
    m = 16,
    n = 17,
    o = 18,
    p = 19,
    q = 20,
    r = 21,
    s = 22,
    t = 23,
    u = 24,
    v = 25,
    w = 26,
    x = 27,
    y = 28,
    z = 29,
    @"1" = 30,
    @"2" = 31,
    @"3" = 32,
    @"4" = 33,
    @"5" = 34,
    @"6" = 35,
    @"7" = 36,
    @"8" = 37,
    @"9" = 38,
    @"0" = 39,
    @"return" = 40,
    escape = 41,
    backspace = 42,
    tab = 43,
    space = 44,
    minus = 45,
    equals = 46,
    leftbracket = 47,
    rightbracket = 48,
    backslash = 49,
    nonushash = 50,
    semicolon = 51,
    apostrophe = 52,
    grave = 53,
    comma = 54,
    period = 55,
    slash = 56,
    capslock = 57,
    f1 = 58,
    f2 = 59,
    f3 = 60,
    f4 = 61,
    f5 = 62,
    f6 = 63,
    f7 = 64,
    f8 = 65,
    f9 = 66,
    f10 = 67,
    f11 = 68,
    f12 = 69,
    printscreen = 70,
    scrolllock = 71,
    pause = 72,
    insert = 73,
    home = 74,
    pageup = 75,
    delete = 76,
    end = 77,
    pagedown = 78,
    right = 79,
    left = 80,
    down = 81,
    up = 82,
    numlockclear = 83,
    kp_divide = 84,
    kp_multiply = 85,
    kp_minus = 86,
    kp_plus = 87,
    kp_enter = 88,
    kp_1 = 89,
    kp_2 = 90,
    kp_3 = 91,
    kp_4 = 92,
    kp_5 = 93,
    kp_6 = 94,
    kp_7 = 95,
    kp_8 = 96,
    kp_9 = 97,
    kp_0 = 98,
    kp_period = 99,
    nonusbackslash = 100,
    application = 101,
    power = 102,
    kp_equals = 103,
    f13 = 104,
    f14 = 105,
    f15 = 106,
    f16 = 107,
    f17 = 108,
    f18 = 109,
    f19 = 110,
    f20 = 111,
    f21 = 112,
    f22 = 113,
    f23 = 114,
    f24 = 115,
    execute = 116,
    help = 117,
    menu = 118,
    select = 119,
    stop = 120,
    again = 121,
    undo = 122,
    cut = 123,
    copy = 124,
    paste = 125,
    find = 126,
    mute = 127,
    volumeup = 128,
    volumedown = 129,
    kp_comma = 133,
    kp_equalsas400 = 134,
    international1 = 135,
    international2 = 136,
    international3 = 137,
    international4 = 138,
    international5 = 139,
    international6 = 140,
    international7 = 141,
    international8 = 142,
    international9 = 143,
    lang1 = 144,
    lang2 = 145,
    lang3 = 146,
    lang4 = 147,
    lang5 = 148,
    lang6 = 149,
    lang7 = 150,
    lang8 = 151,
    lang9 = 152,
    alterase = 153,
    sysreq = 154,
    cancel = 155,
    clear = 156,
    prior = 157,
    return2 = 158,
    separator = 159,
    out = 160,
    oper = 161,
    clearagain = 162,
    crsel = 163,
    exsel = 164,
    kp_00 = 176,
    kp_000 = 177,
    thousandsseparator = 178,
    decimalseparator = 179,
    currencyunit = 180,
    currencysubunit = 181,
    kp_leftparen = 182,
    kp_rightparen = 183,
    kp_leftbrace = 184,
    kp_rightbrace = 185,
    kp_tab = 186,
    kp_backspace = 187,
    kp_a = 188,
    kp_b = 189,
    kp_c = 190,
    kp_d = 191,
    kp_e = 192,
    kp_f = 193,
    kp_xor = 194,
    kp_power = 195,
    kp_percent = 196,
    kp_less = 197,
    kp_greater = 198,
    kp_ampersand = 199,
    kp_dblampersand = 200,
    kp_verticalbar = 201,
    kp_dblverticalbar = 202,
    kp_colon = 203,
    kp_hash = 204,
    kp_space = 205,
    kp_at = 206,
    kp_exclam = 207,
    kp_memstore = 208,
    kp_memrecall = 209,
    kp_memclear = 210,
    kp_memadd = 211,
    kp_memsubtract = 212,
    kp_memmultiply = 213,
    kp_memdivide = 214,
    kp_plusminus = 215,
    kp_clear = 216,
    kp_clearentry = 217,
    kp_binary = 218,
    kp_octal = 219,
    kp_decimal = 220,
    kp_hexadecimal = 221,
    lctrl = 224,
    lshift = 225,
    lalt = 226,
    lgui = 227,
    rctrl = 228,
    rshift = 229,
    ralt = 230,
    rgui = 231,
    mode = 257,
    sleep = 258,
    wake = 259,
    channel_increment = 260,
    channel_decrement = 261,
    media_play = 262,
    media_pause = 263,
    media_record = 264,
    media_fast_forward = 265,
    media_rewind = 266,
    media_next_track = 267,
    media_previous_track = 268,
    media_stop = 269,
    media_eject = 270,
    media_play_pause = 271,
    media_select = 272,
    ac_new = 273,
    ac_open = 274,
    ac_close = 275,
    ac_exit = 276,
    ac_save = 277,
    ac_print = 278,
    ac_properties = 279,
    ac_search = 280,
    ac_home = 281,
    ac_back = 282,
    ac_forward = 283,
    ac_stop = 284,
    ac_refresh = 285,
    ac_bookmarks = 286,
    softleft = 287,
    softright = 288,
    call = 289,
    endcall = 290,
    _,

    pub const count = 512;
};

const evdev_table = blk: {
    var table = [_]Scancode{.unknown} ** 256;
    const pairs = [_]struct { u8, Scancode }{
        .{ 1, .escape },          .{ 2, .@"1" },                 .{ 3, .@"2" },            .{ 4, .@"3" },               .{ 5, .@"4" },               .{ 6, .@"5" },
        .{ 7, .@"6" },            .{ 8, .@"7" },                 .{ 9, .@"8" },            .{ 10, .@"9" },              .{ 11, .@"0" },              .{ 12, .minus },
        .{ 13, .equals },         .{ 14, .backspace },           .{ 15, .tab },            .{ 16, .q },                 .{ 17, .w },                 .{ 18, .e },
        .{ 19, .r },              .{ 20, .t },                   .{ 21, .y },              .{ 22, .u },                 .{ 23, .i },                 .{ 24, .o },
        .{ 25, .p },              .{ 26, .leftbracket },         .{ 27, .rightbracket },   .{ 28, .@"return" },         .{ 29, .lctrl },             .{ 30, .a },
        .{ 31, .s },              .{ 32, .d },                   .{ 33, .f },              .{ 34, .g },                 .{ 35, .h },                 .{ 36, .j },
        .{ 37, .k },              .{ 38, .l },                   .{ 39, .semicolon },      .{ 40, .apostrophe },        .{ 41, .grave },             .{ 42, .lshift },
        .{ 43, .backslash },      .{ 44, .z },                   .{ 45, .x },              .{ 46, .c },                 .{ 47, .v },                 .{ 48, .b },
        .{ 49, .n },              .{ 50, .m },                   .{ 51, .comma },          .{ 52, .period },            .{ 53, .slash },             .{ 54, .rshift },
        .{ 55, .kp_multiply },    .{ 56, .lalt },                .{ 57, .space },          .{ 58, .capslock },          .{ 59, .f1 },                .{ 60, .f2 },
        .{ 61, .f3 },             .{ 62, .f4 },                  .{ 63, .f5 },             .{ 64, .f6 },                .{ 65, .f7 },                .{ 66, .f8 },
        .{ 67, .f9 },             .{ 68, .f10 },                 .{ 69, .numlockclear },   .{ 70, .scrolllock },        .{ 71, .kp_7 },              .{ 72, .kp_8 },
        .{ 73, .kp_9 },           .{ 74, .kp_minus },            .{ 75, .kp_4 },           .{ 76, .kp_5 },              .{ 77, .kp_6 },              .{ 78, .kp_plus },
        .{ 79, .kp_1 },           .{ 80, .kp_2 },                .{ 81, .kp_3 },           .{ 82, .kp_0 },              .{ 83, .kp_period },         .{ 85, .lang5 },
        .{ 86, .nonusbackslash }, .{ 87, .f11 },                 .{ 88, .f12 },            .{ 89, .international1 },    .{ 90, .lang3 },             .{ 91, .lang4 },
        .{ 92, .international4 }, .{ 93, .international2 },      .{ 94, .international5 }, .{ 95, .international5 },    .{ 96, .kp_enter },          .{ 97, .rctrl },
        .{ 98, .kp_divide },      .{ 99, .printscreen },         .{ 100, .ralt },          .{ 102, .home },             .{ 103, .up },               .{ 104, .pageup },
        .{ 105, .left },          .{ 106, .right },              .{ 107, .end },           .{ 108, .down },             .{ 109, .pagedown },         .{ 110, .insert },
        .{ 111, .delete },        .{ 113, .mute },               .{ 114, .volumedown },    .{ 115, .volumeup },         .{ 116, .power },            .{ 117, .kp_equals },
        .{ 118, .kp_plusminus },  .{ 119, .pause },              .{ 121, .kp_comma },      .{ 122, .lang1 },            .{ 123, .lang2 },            .{ 124, .international3 },
        .{ 125, .lgui },          .{ 126, .rgui },               .{ 127, .application },   .{ 128, .stop },             .{ 129, .again },            .{ 130, .ac_properties },
        .{ 131, .undo },          .{ 133, .copy },               .{ 134, .ac_open },       .{ 135, .paste },            .{ 136, .find },             .{ 137, .cut },
        .{ 138, .help },          .{ 139, .menu },               .{ 142, .sleep },         .{ 143, .wake },             .{ 156, .ac_bookmarks },     .{ 158, .ac_back },
        .{ 159, .ac_forward },    .{ 161, .media_eject },        .{ 162, .media_eject },   .{ 163, .media_next_track }, .{ 164, .media_play_pause }, .{ 165, .media_previous_track },
        .{ 166, .media_stop },    .{ 167, .media_record },       .{ 168, .media_rewind },  .{ 172, .ac_home },          .{ 173, .ac_refresh },       .{ 174, .ac_exit },
        .{ 179, .kp_leftparen },  .{ 180, .kp_rightparen },      .{ 181, .ac_new },        .{ 183, .f13 },              .{ 184, .f14 },              .{ 185, .f15 },
        .{ 186, .f16 },           .{ 187, .f17 },                .{ 188, .f18 },           .{ 189, .f19 },              .{ 190, .f20 },              .{ 191, .f21 },
        .{ 192, .f22 },           .{ 193, .f23 },                .{ 194, .f24 },           .{ 200, .media_play },       .{ 201, .media_pause },      .{ 206, .ac_close },
        .{ 207, .media_play },    .{ 208, .media_fast_forward }, .{ 210, .ac_print },      .{ 217, .ac_search },        .{ 222, .alterase },         .{ 223, .cancel },
        .{ 226, .media_select },  .{ 234, .ac_save },
    };
    for (pairs) |p| table[p[0]] = p[1];
    break :blk table;
};

/// Linux evdev key code (`KEY_*`, i.e. XKB keycode - 8; `KeyEvent.scancode` on every
/// backend) -> USB HID scancode. `.unknown` for codes without a HID usage.
pub fn scancodeFromEvdev(evdev: u32) Scancode {
    if (evdev < evdev_table.len) return evdev_table[evdev];
    return switch (evdev) {
        0x161 => .select, // KEY_SELECT
        0x163 => .clear, // KEY_CLEAR
        0x192 => .channel_increment, // KEY_CHANNELUP
        0x193 => .channel_decrement, // KEY_CHANNELDOWN
        else => .unknown,
    };
}

/// Lowercases Latin letters (ASCII and Latin-1), as SDL does for printable keycodes.
pub fn lowerLatin(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xc0...0xd6, 0xd8...0xde => cp + 32,
        else => cp,
    };
}

/// Held keys by HID scancode. Feed every event to `handle`; on `focus_lost` all keys are
/// released (`releaseAll` returns them, so a host can synthesise key-ups as SDL does), and
/// on `focus_gained` call `syncModifiers(app.modKeys())` to pick up modifiers pressed while
/// another window had focus.
pub const State = struct {
    down: std.StaticBitSet(Scancode.count) = .initEmpty(),

    pub fn isDown(s: *const State, sc: Scancode) bool {
        const i: usize = @intFromEnum(sc);
        return i < Scancode.count and s.down.isSet(i);
    }

    /// Updates from a key event; returns true when the event changed the state.
    pub fn handle(s: *State, ev: event.Event) bool {
        switch (ev) {
            .key_down, .key_up => |k| {
                const i: usize = @intFromEnum(scancodeFromEvdev(k.scancode));
                if (i == 0 or i >= Scancode.count or s.down.isSet(i) == k.down) return false;
                s.down.setValue(i, k.down);
                return true;
            },
            .focus_lost => {
                const any = s.down.count() > 0;
                s.down = .initEmpty();
                return any;
            },
            else => return false,
        }
    }

    /// Clears every held key, writing the released scancodes to `out` (up to its length).
    pub fn releaseAll(s: *State, out: []Scancode) []Scancode {
        var n: usize = 0;
        var it = s.down.iterator(.{});
        while (it.next()) |i| {
            if (n < out.len) {
                out[n] = @enumFromInt(i);
                n += 1;
            }
        }
        s.down = .initEmpty();
        return out[0..n];
    }

    /// Sets the eight modifier keys from the backend's physical state (`App.modKeys()`).
    pub fn syncModifiers(s: *State, keys: event.ModKeys) void {
        inline for (.{ "lshift", "rshift", "lctrl", "rctrl", "lalt", "ralt", "lgui", "rgui" }) |name| {
            s.down.setValue(@intFromEnum(@field(Scancode, name)), @field(keys, name));
        }
    }
};

// -- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "evdev to HID scancode table" {
    const cases = [_]struct { u32, Scancode }{
        .{ 0, .unknown },         .{ 1, .escape },           .{ 2, .@"1" },               .{ 10, .@"9" },
        .{ 11, .@"0" },           .{ 14, .backspace },       .{ 16, .q },                 .{ 28, .@"return" },
        .{ 30, .a },              .{ 44, .z },               .{ 50, .m },                 .{ 57, .space },
        .{ 29, .lctrl },          .{ 97, .rctrl },           .{ 42, .lshift },            .{ 54, .rshift },
        .{ 56, .lalt },           .{ 100, .ralt },           .{ 125, .lgui },             .{ 126, .rgui },
        .{ 59, .f1 },             .{ 68, .f10 },             .{ 87, .f11 },               .{ 88, .f12 },
        .{ 183, .f13 },           .{ 194, .f24 },            .{ 58, .capslock },          .{ 69, .numlockclear },
        .{ 70, .scrolllock },     .{ 99, .printscreen },     .{ 119, .pause },            .{ 110, .insert },
        .{ 111, .delete },        .{ 102, .home },           .{ 107, .end },              .{ 104, .pageup },
        .{ 109, .pagedown },      .{ 103, .up },             .{ 108, .down },             .{ 105, .left },
        .{ 106, .right },         .{ 96, .kp_enter },        .{ 98, .kp_divide },         .{ 55, .kp_multiply },
        .{ 74, .kp_minus },       .{ 78, .kp_plus },         .{ 83, .kp_period },         .{ 82, .kp_0 },
        .{ 79, .kp_1 },           .{ 73, .kp_9 },            .{ 117, .kp_equals },        .{ 121, .kp_comma },
        .{ 86, .nonusbackslash }, .{ 43, .backslash },       .{ 41, .grave },             .{ 127, .application },
        .{ 139, .menu },          .{ 113, .mute },           .{ 114, .volumedown },       .{ 115, .volumeup },
        .{ 133, .copy },          .{ 135, .paste },          .{ 137, .cut },              .{ 136, .find },
        .{ 131, .undo },          .{ 138, .help },           .{ 164, .media_play_pause }, .{ 163, .media_next_track },
        .{ 158, .ac_back },       .{ 159, .ac_forward },     .{ 173, .ac_refresh },       .{ 217, .ac_search },
        .{ 89, .international1 }, .{ 124, .international3 }, .{ 122, .lang1 },            .{ 123, .lang2 },
        .{ 84, .unknown },        .{ 255, .unknown },        .{ 0x161, .select },         .{ 9999, .unknown },
    };
    for (cases) |c| try testing.expectEqual(c[1], scancodeFromEvdev(c[0]));
    // HID usage values (page 0x07).
    try testing.expectEqual(@as(u16, 4), @intFromEnum(Scancode.a));
    try testing.expectEqual(@as(u16, 0x28), @intFromEnum(Scancode.@"return"));
    try testing.expectEqual(@as(u16, 0xE0), @intFromEnum(Scancode.lctrl));
    try testing.expectEqual(@as(u16, 0xE7), @intFromEnum(Scancode.rgui));
    // Every mapped evdev code yields a distinct scancode except the documented aliases.
    var seen = [_]u8{0} ** Scancode.count;
    for (evdev_table) |s| if (s != .unknown) {
        seen[@intFromEnum(s)] += 1;
    };
    for (seen, 0..) |n, sc| {
        const alias = sc == @intFromEnum(Scancode.international5) or sc == @intFromEnum(Scancode.media_eject) or sc == @intFromEnum(Scancode.media_play);
        try testing.expect(n <= 1 or alias);
    }
}

test "keyboard state: press, release, focus loss, modifier sync" {
    var s: State = .{};
    try testing.expect(s.handle(.{ .key_down = .{ .key = .a, .scancode = 30 } }));
    try testing.expect(!s.handle(.{ .key_down = .{ .key = .a, .scancode = 30, .repeat = true } }));
    try testing.expect(s.handle(.{ .key_down = .{ .key = .rctrl, .scancode = 97 } }));
    try testing.expect(s.isDown(.a) and s.isDown(.rctrl) and !s.isDown(.lctrl));
    try testing.expect(s.handle(.{ .key_up = .{ .key = .a, .scancode = 30, .down = false } }));
    try testing.expect(!s.isDown(.a));
    var buf: [8]Scancode = undefined;
    try testing.expectEqualSlices(Scancode, &.{.rctrl}, s.releaseAll(&buf));
    try testing.expect(!s.isDown(.rctrl));
    _ = s.handle(.{ .key_down = .{ .key = .b, .scancode = 48 } });
    try testing.expect(s.handle(.{ .focus_lost = .{} }));
    try testing.expect(!s.isDown(.b));
    s.syncModifiers(.{ .lshift = true, .rgui = true });
    try testing.expect(s.isDown(.lshift) and s.isDown(.rgui) and !s.isDown(.rshift));
}

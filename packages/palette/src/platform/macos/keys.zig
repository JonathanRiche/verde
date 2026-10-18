//! macOS keyboard tables (pure logic; unit-tested on every OS).
//!
//! `KeyEvent.scancode` is the Linux evdev code on every backend, so hosts and `palette.keyboard`
//! (HID scancodes) keep one table. Mac virtual key codes (`kVK_*`, `-[NSEvent keyCode]`) are mapped to
//! the evdev code of the key SDL3 reports for them (SDL's `scancodes_darwin.h` followed by the
//! inverse of `scancodes_linux.h`), e.g. kVK 105 (F13 on Apple keyboards) -> KEY_SYSRQ because
//! SDL reports SDL_SCANCODE_PRINTSCREEN there. The raw Mac key code goes to `KeyEvent.keysym`.
//!
//! Left/right modifiers come from the device-dependent bits of `-[NSEvent modifierFlags]`
//! (NX_DEVICE*KEYMASK), resolved like SDL's `IsModifierKeyPressed`.
const std = @import("std");
const ev = @import("../../event.zig");
const Keycode = ev.Keycode;

// NSEventModifierFlags (device-independent).
pub const flag_caps_lock: u64 = 1 << 16;
pub const flag_shift: u64 = 1 << 17;
pub const flag_control: u64 = 1 << 18;
pub const flag_option: u64 = 1 << 19;
pub const flag_command: u64 = 1 << 20;
pub const flag_numeric_pad: u64 = 1 << 21;
pub const flag_function: u64 = 1 << 23;

// NX_DEVICE*KEYMASK (IOKit/hidsystem/IOLLEvent.h).
pub const dev_lctl: u64 = 0x0001;
pub const dev_lshift: u64 = 0x0002;
pub const dev_rshift: u64 = 0x0004;
pub const dev_lcmd: u64 = 0x0008;
pub const dev_rcmd: u64 = 0x0010;
pub const dev_lalt: u64 = 0x0020;
pub const dev_ralt: u64 = 0x0040;
pub const dev_rctl: u64 = 0x2000;

const Entry = struct {
    /// Linux evdev code (0 = no key).
    evdev: u16,
    /// Position-based identity. Printable keys are re-resolved from the layout; this tag is
    /// the US-layout fallback for non-Latin layouts.
    key: Keycode,
    /// The key's identity never depends on the layout (function, navigation, keypad keys).
    fixed: bool,
};

fn e(evdev: u16, key: Keycode) Entry {
    return .{ .evdev = evdev, .key = key, .fixed = false };
}

fn f(evdev: u16, key: Keycode) Entry {
    return .{ .evdev = evdev, .key = key, .fixed = true };
}

const none: Entry = .{ .evdev = 0, .key = .unknown, .fixed = true };

/// Indexed by Mac virtual key code (0..127).
pub const table: [128]Entry = blk: {
    var t = [_]Entry{none} ** 128;
    t[0x00] = e(30, .a);
    t[0x01] = e(31, .s);
    t[0x02] = e(32, .d);
    t[0x03] = e(33, .f);
    t[0x04] = e(35, .h);
    t[0x05] = e(34, .g);
    t[0x06] = e(44, .z);
    t[0x07] = e(45, .x);
    t[0x08] = e(46, .c);
    t[0x09] = e(47, .v);
    t[0x0A] = e(86, .character); // ISO section key (SDL: NONUSBACKSLASH; swapped with grave on ISO)
    t[0x0B] = e(48, .b);
    t[0x0C] = e(16, .q);
    t[0x0D] = e(17, .w);
    t[0x0E] = e(18, .e);
    t[0x0F] = e(19, .r);
    t[0x10] = e(21, .y);
    t[0x11] = e(20, .t);
    t[0x12] = e(2, .@"1");
    t[0x13] = e(3, .@"2");
    t[0x14] = e(4, .@"3");
    t[0x15] = e(5, .@"4");
    t[0x16] = e(7, .@"6");
    t[0x17] = e(6, .@"5");
    t[0x18] = e(13, .equals);
    t[0x19] = e(10, .@"9");
    t[0x1A] = e(8, .@"7");
    t[0x1B] = e(12, .minus);
    t[0x1C] = e(9, .@"8");
    t[0x1D] = e(11, .@"0");
    t[0x1E] = e(27, .rightbracket);
    t[0x1F] = e(24, .o);
    t[0x20] = e(22, .u);
    t[0x21] = e(26, .leftbracket);
    t[0x22] = e(23, .i);
    t[0x23] = e(25, .p);
    t[0x24] = f(28, .@"return");
    t[0x25] = e(38, .l);
    t[0x26] = e(36, .j);
    t[0x27] = e(40, .apostrophe);
    t[0x28] = e(37, .k);
    t[0x29] = e(39, .semicolon);
    t[0x2A] = e(43, .backslash);
    t[0x2B] = e(51, .comma);
    t[0x2C] = e(53, .slash);
    t[0x2D] = e(49, .n);
    t[0x2E] = e(50, .m);
    t[0x2F] = e(52, .period);
    t[0x30] = f(15, .tab);
    t[0x31] = f(57, .space);
    t[0x32] = e(41, .grave);
    t[0x33] = f(14, .backspace);
    t[0x34] = f(96, .kp_enter); // Enter on old portables
    t[0x35] = f(1, .escape);
    t[0x36] = f(126, .rgui);
    t[0x37] = f(125, .lgui);
    t[0x38] = f(42, .lshift);
    t[0x39] = f(58, .caps_lock);
    t[0x3A] = f(56, .lalt);
    t[0x3B] = f(29, .lctrl);
    t[0x3C] = f(54, .rshift);
    t[0x3D] = f(100, .ralt);
    t[0x3E] = f(97, .rctrl);
    // 0x3F fn: a hardware-level modifier; no key events (like SDL).
    t[0x40] = f(187, .f17);
    t[0x41] = f(83, .kp_period);
    t[0x43] = f(55, .kp_multiply);
    t[0x45] = f(78, .kp_plus);
    t[0x47] = f(69, .num_lock); // keypad Clear (SDL: NUMLOCKCLEAR)
    t[0x48] = f(115, .volumeup);
    t[0x49] = f(114, .volumedown);
    t[0x4A] = f(113, .mute);
    t[0x4B] = f(98, .kp_divide);
    t[0x4C] = f(96, .kp_enter);
    t[0x4E] = f(74, .kp_minus);
    t[0x4F] = f(188, .f18);
    t[0x50] = f(189, .f19);
    t[0x51] = f(117, .kp_equals);
    t[0x52] = f(82, .kp_0);
    t[0x53] = f(79, .kp_1);
    t[0x54] = f(80, .kp_2);
    t[0x55] = f(81, .kp_3);
    t[0x56] = f(75, .kp_4);
    t[0x57] = f(76, .kp_5);
    t[0x58] = f(77, .kp_6);
    t[0x59] = f(71, .kp_7);
    t[0x5A] = f(190, .f20);
    t[0x5B] = f(72, .kp_8);
    t[0x5C] = f(73, .kp_9);
    t[0x5D] = e(124, .character); // JIS Yen (SDL: INTERNATIONAL3)
    t[0x5E] = e(89, .character); // JIS Ro / underscore (SDL: INTERNATIONAL1)
    t[0x5F] = f(121, .kp_comma); // JIS keypad comma
    t[0x60] = f(63, .f5);
    t[0x61] = f(64, .f6);
    t[0x62] = f(65, .f7);
    t[0x63] = f(61, .f3);
    t[0x64] = f(66, .f8);
    t[0x65] = f(67, .f9);
    t[0x66] = f(123, .unknown); // JIS Eisu (SDL: LANG2)
    t[0x67] = f(87, .f11);
    t[0x68] = f(122, .unknown); // JIS Kana (SDL: LANG1)
    // Apple USB keyboards label 0x69/0x6B/0x71 F13/F14/F15; SDL reports them as
    // PRINTSCREEN/SCROLLLOCK/PAUSE (ADB heritage), and so do we.
    t[0x69] = f(99, .print_screen);
    t[0x6A] = f(186, .f16);
    t[0x6B] = f(70, .scroll_lock);
    t[0x6D] = f(68, .f10);
    t[0x6E] = f(127, .menu); // PC context-menu key (SDL: APPLICATION)
    t[0x6F] = f(88, .f12);
    t[0x71] = f(119, .pause);
    t[0x72] = f(110, .insert); // labelled Help; sends the Insert usage (SDL: INSERT)
    t[0x73] = f(102, .home);
    t[0x74] = f(104, .pageup);
    t[0x75] = f(111, .delete);
    t[0x76] = f(62, .f4);
    t[0x77] = f(107, .end);
    t[0x78] = f(60, .f2);
    t[0x79] = f(109, .pagedown);
    t[0x7A] = f(59, .f1);
    t[0x7B] = f(105, .left);
    t[0x7C] = f(106, .right);
    t[0x7D] = f(108, .down);
    t[0x7E] = f(103, .up);
    t[0x7F] = f(116, .unknown); // power
    break :blk t;
};

/// ISO keyboards swap kVK 10 and 50 relative to the HID usage (SDL does the same swap).
pub fn normalizeIso(code: u16, iso: bool) u16 {
    if (iso and (code == 10 or code == 50)) return 60 - code;
    return code;
}

pub fn entry(mac_code: u16) Entry {
    return if (mac_code < table.len) table[mac_code] else none;
}

/// Evdev code SDL's F13..F24 positions map to (Palette `Keycode.f13`..`.f24`). macOS has key
/// codes only for F16..F20 beyond the ones SDL remaps; F21..F24 have no Mac virtual key code
/// and can only arrive as NSFunctionKey characters (handled by `keycodeFromFunctionChar`).
pub fn evdevForFunctionKey(n: u8) u16 {
    return switch (n) {
        1...10 => 58 + @as(u16, n),
        11 => 87,
        12 => 88,
        13...24 => 183 + @as(u16, n - 13),
        else => 0,
    };
}

/// NSF1FunctionKey (0xF704) .. NSF35FunctionKey: the private-use characters AppKit puts in
/// `-[NSEvent characters]` for function keys. Returns the F-number or 0.
pub fn functionKeyNumber(cp: u21) u8 {
    if (cp >= 0xF704 and cp <= 0xF704 + 23) return @intCast(cp - 0xF704 + 1);
    return 0;
}

pub fn keycodeForFunctionNumber(n: u8) Keycode {
    return switch (n) {
        1...12 => @enumFromInt(@intFromEnum(Keycode.f1) + (n - 1)),
        13...24 => @enumFromInt(@intFromEnum(Keycode.f13) + (n - 13)),
        else => .unknown,
    };
}

/// Resolves the key identity of a printable key from the layout's unmodified character
/// (`-[NSEvent charactersByApplyingModifiers:0]`). Latin/ASCII characters give their tag;
/// non-Latin layouts keep the US-position tag so shortcuts such as Cmd+C keep working.
pub fn resolve(mac_code: u16, base_cp: u21) Keycode {
    const en = entry(mac_code);
    if (en.fixed) return en.key;
    if (base_cp != 0 and base_cp < 0x80) {
        const k = Keycode.fromAscii(@intCast(base_cp));
        if (k != .character) return k;
        return .character;
    }
    if (base_cp >= 0x370 and en.key != .character) return en.key;
    if (base_cp != 0) return .character;
    return en.key;
}

/// Lowercase of a Latin-1 letter (SDL reports unshifted symbols lowercase).
pub fn lowerLatin(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xc0...0xd6, 0xd8...0xde => cp + 32,
        else => cp,
    };
}

/// Printable codepoint for `KeyEvent.codepoint`: control characters, DEL and AppKit's
/// function-key private-use range (U+F700..U+F8FF) are not text.
pub fn printable(cp: u21) u21 {
    if (cp < 0x20 or cp == 0x7f) return 0;
    if (cp >= 0xF700 and cp <= 0xF8FF) return 0;
    return cp;
}

/// SDL's `IsModifierKeyPressed`: the device bit decides, unless it disagrees with the
/// device-independent bit (some keyboards/remappers report no device bits).
pub fn modifierPressed(flags: u64, target: u64, other: u64, either: u64) bool {
    const t = flags & target != 0;
    const o = flags & other != 0;
    const any = flags & either != 0;
    if (any != (t or o)) return any;
    return t;
}

pub fn modKeysFromFlags(flags: u64) ev.ModKeys {
    return .{
        .lshift = modifierPressed(flags, dev_lshift, dev_rshift, flag_shift),
        .rshift = modifierPressed(flags, dev_rshift, dev_lshift, flag_shift),
        .lctrl = modifierPressed(flags, dev_lctl, dev_rctl, flag_control),
        .rctrl = modifierPressed(flags, dev_rctl, dev_lctl, flag_control),
        .lalt = modifierPressed(flags, dev_lalt, dev_ralt, flag_option),
        .ralt = modifierPressed(flags, dev_ralt, dev_lalt, flag_option),
        .lgui = modifierPressed(flags, dev_lcmd, dev_rcmd, flag_command),
        .rgui = modifierPressed(flags, dev_rcmd, dev_lcmd, flag_command),
    };
}

pub fn modsFromFlags(flags: u64) ev.Mods {
    return .{
        .shift = flags & flag_shift != 0,
        .ctrl = flags & flag_control != 0,
        .alt = flags & flag_option != 0,
        .super = flags & flag_command != 0,
        .caps_lock = flags & flag_caps_lock != 0,
    };
}

/// The modifier keys whose state differs between `old` and `new`, in a fixed order, as
/// (mac key code, down) pairs: what a `flagsChanged` event turns into.
pub const ModChange = struct { mac_code: u16, down: bool };

pub fn modifierChanges(old: ev.ModKeys, new: ev.ModKeys, out: *[8]ModChange) []ModChange {
    const order = .{
        .{ "lshift", 0x38 }, .{ "lctrl", 0x3B }, .{ "lalt", 0x3A }, .{ "lgui", 0x37 },
        .{ "rshift", 0x3C }, .{ "rctrl", 0x3E }, .{ "ralt", 0x3D }, .{ "rgui", 0x36 },
    };
    var n: usize = 0;
    inline for (order) |o| {
        const a = @field(old, o[0]);
        const b = @field(new, o[0]);
        if (a != b) {
            out[n] = .{ .mac_code = o[1], .down = b };
            n += 1;
        }
    }
    return out[0..n];
}

/// First Unicode scalar of a UTF-8 string, or 0.
pub fn firstScalar(s: []const u8) u21 {
    if (s.len == 0) return 0;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (n > s.len) return 0;
    return std.unicode.utf8Decode(s[0..n]) catch 0;
}

/// Builds the Palette key event for a Mac key code. `chars`: `-[NSEvent characters]`,
/// `base`: `charactersByApplyingModifiers:0` (both UTF-8, may be empty).
pub fn keyEvent(mac_code: u16, chars: []const u8, base: []const u8, flags: u64, down: bool, repeat: bool) ev.KeyEvent {
    const en = entry(mac_code);
    const base_cp_raw = firstScalar(base);
    var key = resolve(mac_code, printable(base_cp_raw));
    var evdev: u32 = en.evdev;
    if (key == .unknown and en.evdev == 0) {
        // Function keys without a table entry (F21..F24 via NSFunctionKey characters).
        const fnum = functionKeyNumber(firstScalar(chars));
        if (fnum != 0) {
            key = keycodeForFunctionNumber(fnum);
            evdev = evdevForFunctionKey(fnum);
        }
    }
    const base_cp: u21 = if (en.fixed) 0 else lowerLatin(printable(base_cp_raw));
    return .{
        .key = key,
        .keysym = mac_code,
        .scancode = evdev,
        .codepoint = if (en.fixed and key != .space) 0 else printable(firstScalar(chars)),
        .base_codepoint = base_cp,
        .mod = modsFromFlags(flags),
        .mod_keys = modKeysFromFlags(flags),
        .down = down,
        .repeat = repeat,
    };
}

test "layout resolution: AZERTY, Cyrillic, punctuation" {
    // US: kVK_ANSI_Q gives 'q'.
    try std.testing.expectEqual(Keycode.q, resolve(0x0C, 'q'));
    // AZERTY: the Q position produces 'a'.
    try std.testing.expectEqual(Keycode.a, resolve(0x0C, 'a'));
    // Cyrillic: falls back to the US position so Cmd+C still reads as `c`.
    try std.testing.expectEqual(Keycode.c, resolve(0x08, 0x0441));
    // Latin-1 letter: a printable key without a tag.
    try std.testing.expectEqual(Keycode.character, resolve(0x29, 0xF6)); // ö on German layouts
    // Fixed keys ignore the layout.
    try std.testing.expectEqual(Keycode.left, resolve(0x7B, 0xF702));
    const k = keyEvent(0x00, "A", "a", flag_shift | dev_lshift, true, true);
    try std.testing.expectEqual(Keycode.a, k.key);
    try std.testing.expectEqual(@as(u21, 'A'), k.codepoint);
    try std.testing.expectEqual(@as(u21, 'a'), k.base_codepoint);
    try std.testing.expect(k.repeat and k.down and k.mod.shift and k.mod_keys.lshift and !k.mod_keys.rshift);
    try std.testing.expectEqual(@as(u32, 0x00), k.keysym);
    // Return: control character, no codepoint; space keeps its codepoint.
    try std.testing.expectEqual(@as(u21, 0), keyEvent(0x24, "\r", "\r", 0, true, false).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), keyEvent(0x31, " ", " ", 0, true, false).codepoint);
    // Arrow keys: AppKit's private-use function characters are not text.
    try std.testing.expectEqual(@as(u21, 0), keyEvent(0x7B, "\u{F702}", "\u{F702}", 0, true, false).codepoint);
}

test "left/right modifiers from device bits" {
    const both_shift = flag_shift | dev_lshift | dev_rshift;
    var mk = modKeysFromFlags(both_shift);
    try std.testing.expect(mk.lshift and mk.rshift);
    mk = modKeysFromFlags(flag_command | dev_rcmd);
    try std.testing.expect(mk.rgui and !mk.lgui);
    mk = modKeysFromFlags(flag_control | dev_rctl);
    try std.testing.expect(mk.rctrl and !mk.lctrl);
    mk = modKeysFromFlags(flag_option | dev_ralt);
    try std.testing.expect(mk.ralt and !mk.lalt);
    // No device bits but the generic flag set (remapped keyboards): both sides read as held.
    mk = modKeysFromFlags(flag_option);
    try std.testing.expect(mk.lalt and mk.ralt);
    // Generic flag clear but a stale device bit: released.
    mk = modKeysFromFlags(dev_lshift);
    try std.testing.expect(!mk.lshift);

    var buf: [8]ModChange = undefined;
    const ch = modifierChanges(.{ .lshift = true }, .{ .lshift = true, .rgui = true }, &buf);
    try std.testing.expectEqual(@as(usize, 1), ch.len);
    try std.testing.expectEqual(@as(u16, 0x36), ch[0].mac_code);
    try std.testing.expect(ch[0].down);
    const m = modsFromFlags(flag_caps_lock | flag_command);
    try std.testing.expect(m.caps_lock and m.super and !m.ctrl and m.primary());
}

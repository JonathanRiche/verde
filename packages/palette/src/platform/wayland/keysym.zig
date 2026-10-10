//! XKB keysym utilities: name lookup, keysym -> Unicode, simple case mapping, and mapping to
//! Palette's `event.Keycode`. Tables come from keysym_data.zig (generated, checked in).

const std = @import("std");
const data = @import("keysym_data.zig");
const Keycode = @import("../../event.zig").Keycode;

pub const no_symbol: u32 = 0;

// A few keysyms referenced by name in code.
pub const BackSpace: u32 = 0xff08;
pub const Tab: u32 = 0xff09;
pub const Return: u32 = 0xff0d;
pub const Escape: u32 = 0xff1b;
pub const Delete: u32 = 0xffff;
pub const ISO_Left_Tab: u32 = 0xfe20;
pub const KP_Space: u32 = 0xff80;
pub const KP_Equal: u32 = 0xffbd;

fn nameAt(i: usize) [:0]const u8 {
    const start = data.name_offsets[i];
    const end = std.mem.indexOfScalarPos(u8, data.names, start, 0).?;
    return data.names[start..end :0];
}

/// Resolves a keysym name as written in an xkb_symbols section. Accepts table names
/// (case-sensitive), `Uxxxx` Unicode forms and `0x...` raw values. Returns null if unknown.
pub fn fromName(name: []const u8) ?u32 {
    var lo: usize = 0;
    var hi: usize = data.name_offsets.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, nameAt(mid), name)) {
            .eq => return data.name_values[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    if (name.len >= 2 and name[0] == 'U' and std.ascii.isHex(name[1])) {
        // As xkb_keysym_from_name: Latin-1 stays direct, everything else is 0x01000000 + cp.
        const cp = std.fmt.parseInt(u32, name[1..], 16) catch return null;
        if (cp < 0x20 or (cp > 0x7e and cp < 0xa0) or cp > 0x10ffff) return null;
        return if (cp < 0x100) cp else 0x01000000 + cp;
    }
    if (name.len > 2 and name[0] == '0' and (name[1] == 'x' or name[1] == 'X')) {
        return std.fmt.parseInt(u32, name[2..], 16) catch null;
    }
    // xkbcommon falls back to a case-insensitive match; do the same (linear, cold path).
    for (0..data.name_offsets.len) |i| {
        if (std.ascii.eqlIgnoreCase(nameAt(i), name)) return data.name_values[i];
    }
    return null;
}

/// Unicode scalar produced by a keysym, or 0 if it produces no text.
pub fn toUnicode(ks: u32) u21 {
    if ((ks >= 0x20 and ks <= 0x7e) or (ks >= 0xa0 and ks <= 0xff)) return @intCast(ks);
    if (ks >= 0x01000000 and ks <= 0x0110ffff) {
        const cp = ks - 0x01000000;
        if (cp >= 0xd800 and cp <= 0xdfff) return 0;
        return @intCast(cp);
    }
    if (ks > 0xffff) return 0;
    const k: u16 = @intCast(ks);
    const i = std.sort.binarySearch(u16, &data.ucs_keysyms, k, struct {
        fn cmp(key: u16, item: u16) std.math.Order {
            return std.math.order(key, item);
        }
    }.cmp) orelse return 0;
    return data.ucs_values[i];
}

/// Keysym for a Unicode scalar: Latin-1 direct, a legacy keysym if one maps to it, else the
/// 0x01000000 + cp form (as xkbcommon's xkb_utf32_to_keysym).
pub fn fromUnicode(cp: u32) u32 {
    if ((cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff)) return cp;
    if (cp <= 0xffff) {
        for (data.ucs_values, 0..) |v, i| if (v == cp and data.ucs_keysyms[i] < 0xff00) return data.ucs_keysyms[i];
    }
    if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return no_symbol;
    return 0x01000000 + cp;
}

/// Simple uppercase mapping for the scripts found on keyboards (Latin, Greek, Cyrillic,
/// Armenian). Unmapped characters return themselves.
pub fn upper(cp: u21) u21 {
    return switch (cp) {
        'a'...'z' => cp - 0x20,
        0xe0...0xf6, 0xf8...0xfe => cp - 0x20,
        0xff => 0x178,
        0x100...0x137, 0x14a...0x177 => cp & ~@as(u21, 1),
        0x139...0x148, 0x179...0x17e => if (cp & 1 == 0) cp - 1 else cp,
        0x1cd...0x1dc => if (cp & 1 == 0) cp - 1 else cp,
        0x1de...0x1ef, 0x1f8...0x21f, 0x222...0x233 => cp & ~@as(u21, 1),
        0x3ac => 0x386,
        0x3ad...0x3af => cp - 0x25,
        0x3b1...0x3c1, 0x3c3...0x3c9 => cp - 0x20,
        0x3c2 => 0x3a3,
        0x3cc => 0x38c,
        0x3cd, 0x3ce => cp - 0x3f,
        0x430...0x44f => cp - 0x20,
        0x450...0x45f => cp - 0x50,
        0x460...0x481, 0x48a...0x4bf, 0x4d0...0x52f => cp & ~@as(u21, 1),
        0x4c1...0x4ce => if (cp & 1 == 0) cp - 1 else cp,
        0x561...0x586 => cp - 0x30,
        0x1e00...0x1e95, 0x1ea0...0x1eff => cp & ~@as(u21, 1),
        else => cp,
    };
}

pub fn lower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 0x20,
        0xc0...0xd6, 0xd8...0xde => cp + 0x20,
        0x178 => 0xff,
        0x100...0x137, 0x14a...0x177 => cp | 1,
        0x139...0x148, 0x179...0x17e => if (cp & 1 == 1) cp + 1 else cp,
        0x1cd...0x1dc => if (cp & 1 == 1) cp + 1 else cp,
        0x1de...0x1ef, 0x1f8...0x21f, 0x222...0x233 => cp | 1,
        0x386 => 0x3ac,
        0x388...0x38a => cp + 0x25,
        0x38c => 0x3cc,
        0x38e, 0x38f => cp + 0x3f,
        0x391...0x3a1, 0x3a3...0x3a9 => cp + 0x20,
        0x410...0x42f => cp + 0x20,
        0x400...0x40f => cp + 0x50,
        0x460...0x481, 0x48a...0x4bf, 0x4d0...0x52f => cp | 1,
        0x4c1...0x4ce => if (cp & 1 == 1) cp + 1 else cp,
        0x531...0x556 => cp + 0x30,
        0x1e00...0x1e95, 0x1ea0...0x1eff => cp | 1,
        else => cp,
    };
}

pub fn isLower(ks: u32) bool {
    const cp = toUnicode(ks);
    return cp != 0 and upper(cp) != cp;
}

pub fn isUpper(ks: u32) bool {
    const cp = toUnicode(ks);
    return cp != 0 and lower(cp) != cp;
}

pub fn isKeypad(ks: u32) bool {
    return ks >= KP_Space and ks <= KP_Equal;
}

/// Uppercase form of a keysym (Caps Lock transformation).
pub fn toUpperKeysym(ks: u32) u32 {
    const cp = toUnicode(ks);
    if (cp == 0) return ks;
    const up = upper(cp);
    if (up == cp) return ks;
    return fromUnicode(up);
}

/// Modifier and lock keysyms (never auto-repeat, even without compat info).
pub fn isModifier(ks: u32) bool {
    return (ks >= 0xffe1 and ks <= 0xffee) or (ks >= 0xfe01 and ks <= 0xfe13) or ks == 0xff7e or ks == 0xff7f;
}

/// Maps a keysym to Palette's layout-resolved key identity.
pub fn toKeycode(ks: u32) Keycode {
    return switch (ks) {
        Return => .@"return",
        Escape => .escape,
        BackSpace => .backspace,
        Tab, ISO_Left_Tab, 0xff89 => .tab,
        Delete, 0xff9f => .delete, // Delete, KP_Delete
        0xff63, 0xff9e => .insert,
        0xff50, 0xff95 => .home,
        0xff57, 0xff9c => .end,
        0xff55, 0xff9a => .pageup,
        0xff56, 0xff9b => .pagedown,
        0xff51, 0xff96 => .left,
        0xff52, 0xff97 => .up,
        0xff53, 0xff98 => .right,
        0xff54, 0xff99 => .down,
        0xff8d => .kp_enter,
        0xffe5 => .caps_lock,
        0xff7f => .num_lock,
        0xff14 => .scroll_lock,
        0xff61 => .print_screen,
        0xff13 => .pause,
        0xff67 => .menu,
        0xffbe...0xffc9 => @enumFromInt(@intFromEnum(Keycode.f1) + (ks - 0xffbe)),
        0xffca...0xffd5 => @enumFromInt(@intFromEnum(Keycode.f13) + (ks - 0xffca)),
        0xffe1 => .lshift,
        0xffe2 => .rshift,
        0xffe3 => .lctrl,
        0xffe4 => .rctrl,
        0xffe9, 0xffe7 => .lalt, // Alt_L, Meta_L
        0xffea, 0xffe8, 0xfe03 => .ralt, // Alt_R, Meta_R, ISO_Level3_Shift (AltGr)
        0xffeb => .lgui,
        0xffec => .rgui,
        0xff80 => .space,
        0xffb0...0xffb9 => @enumFromInt(@intFromEnum(Keycode.kp_0) + (ks - 0xffb0)),
        0xffaa => .kp_multiply,
        0xffab => .kp_plus,
        0xffac => .kp_comma, // KP_Separator
        0xffad => .kp_minus,
        0xffae => .kp_period, // KP_Decimal
        0xffaf => .kp_divide,
        0xffbd => .kp_equals,
        0xff15 => .sysreq,
        0xff60 => .select,
        0xff62 => .execute,
        0xff65 => .undo,
        0xff66 => .again, // Redo
        0xff68 => .find,
        0xff69 => .cancel,
        0xff6a => .help,
        0xff7e => .mode, // Mode_switch
        0x1008ff11 => .volumedown,
        0x1008ff12 => .mute,
        0x1008ff13 => .volumeup,
        0x1008ff14 => .media_play_pause, // XF86AudioPlay (the play/pause key)
        0x1008ff15 => .media_stop,
        0x1008ff16 => .media_previous_track,
        0x1008ff17 => .media_next_track,
        0x1008ff18 => .ac_home,
        0x1008ff1b => .ac_search,
        0x1008ff26 => .ac_back,
        0x1008ff27 => .ac_forward,
        0x1008ff28 => .ac_stop,
        0x1008ff29 => .ac_refresh,
        0x1008ff2f => .sleep,
        0x1008ff30 => .ac_bookmarks, // XF86Favorites
        0x1008ff31 => .media_pause,
        0x1008ff57 => .copy,
        0x1008ff58 => .cut,
        0x1008ff6d => .paste,
        else => {
            const cp = toUnicode(ks);
            if (cp == 0) return .unknown;
            if (cp < 0x80) return Keycode.fromAscii(@intCast(lower(cp)));
            return .character;
        },
    };
}

/// US-layout fallback by evdev scancode, for non-Latin layouts (so Ctrl+C on a Cyrillic layout
/// still reports `.c`). Covers the alphanumeric block.
pub fn keycodeFromScancode(sc: u32) Keycode {
    const row = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./";
    if (sc < row.len and row[sc] != 0) return Keycode.fromAscii(row[sc]);
    return switch (sc) {
        57 => .space,
        // Keys whose keysym is a vendor (XF86) symbol in common keymaps, e.g. <FK13> is
        // XF86Tools in xkeyboard-config: report the physical key like SDL does.
        183...194 => @enumFromInt(@intFromEnum(Keycode.f13) + (sc - 183)),
        59...68 => @enumFromInt(@intFromEnum(Keycode.f1) + (sc - 59)),
        87 => .f11,
        88 => .f12,
        113 => .mute,
        114 => .volumedown,
        115 => .volumeup,
        127, 139 => .menu, // KEY_COMPOSE, KEY_MENU
        138 => .help,
        131 => .undo,
        133 => .copy,
        135 => .paste,
        136 => .find,
        137 => .cut,
        else => .unknown,
    };
}

test "keysym names" {
    try std.testing.expectEqual(@as(?u32, 0x61), fromName("a"));
    try std.testing.expectEqual(@as(?u32, 0x31), fromName("1"));
    try std.testing.expectEqual(@as(?u32, 0xff0d), fromName("Return"));
    try std.testing.expectEqual(@as(?u32, 0x6c1), fromName("Cyrillic_a"));
    try std.testing.expectEqual(@as(?u32, 0x1008ff14), fromName("XF86AudioPlay"));
    try std.testing.expectEqual(@as(?u32, 0x1000444), fromName("U0444"));
    try std.testing.expectEqual(@as(?u32, 0x41), fromName("U0041"));
    try std.testing.expectEqual(@as(?u32, 0xfe50), fromName("0xfe50"));
    try std.testing.expectEqual(@as(?u32, null), fromName("NotAKeysym"));
}

test "keysym to unicode" {
    try std.testing.expectEqual(@as(u21, 'a'), toUnicode(0x61));
    try std.testing.expectEqual(@as(u21, 0xe9), toUnicode(0xe9));
    try std.testing.expectEqual(@as(u21, 0x430), toUnicode(0x6c1)); // Cyrillic_a
    try std.testing.expectEqual(@as(u21, 0x20ac), toUnicode(0x20ac)); // EuroSign
    try std.testing.expectEqual(@as(u21, 0x444), toUnicode(0x1000444));
    try std.testing.expectEqual(@as(u21, '\r'), toUnicode(Return));
    try std.testing.expectEqual(@as(u21, '7'), toUnicode(0xffb7)); // KP_7
    try std.testing.expectEqual(@as(u21, 0), toUnicode(0xffbe)); // F1
    try std.testing.expectEqual(@as(u32, 0x6e1), toUpperKeysym(0x6c1)); // Cyrillic_A
    try std.testing.expectEqual(@as(u32, 'A'), toUpperKeysym('a'));
    try std.testing.expect(isLower('q') and isUpper('Q') and !isLower('1'));
}

test "keysym to keycode" {
    try std.testing.expectEqual(Keycode.c, toKeycode('c'));
    try std.testing.expectEqual(Keycode.c, toKeycode('C'));
    try std.testing.expectEqual(Keycode.f5, toKeycode(0xffc2));
    try std.testing.expectEqual(Keycode.@"return", toKeycode(Return));
    try std.testing.expectEqual(Keycode.character, toKeycode(0x6c1));
    try std.testing.expectEqual(Keycode.kp_7, toKeycode(0xffb7));
    try std.testing.expectEqual(Keycode.home, toKeycode(0xff95)); // KP_Home (NumLock off)
    try std.testing.expectEqual(Keycode.kp_enter, toKeycode(0xff8d));
    try std.testing.expectEqual(Keycode.kp_divide, toKeycode(0xffaf));
    try std.testing.expectEqual(Keycode.kp_plus, toKeycode(0xffab));
    try std.testing.expectEqual(Keycode.f13, toKeycode(0xffca));
    try std.testing.expectEqual(Keycode.f24, toKeycode(0xffd5));
    try std.testing.expectEqual(Keycode.find, toKeycode(0xff68));
    try std.testing.expectEqual(Keycode.copy, toKeycode(0x1008ff57));
    try std.testing.expect(isKeypad(0xffb7) and !isKeypad('7'));
    try std.testing.expectEqual(Keycode.f13, keycodeFromScancode(183));
    try std.testing.expectEqual(Keycode.f24, keycodeFromScancode(194));
    try std.testing.expectEqual(Keycode.c, keycodeFromScancode(46));
    try std.testing.expectEqual(Keycode.@"1", keycodeFromScancode(2));
}

//! Win32 input message → palette `Event` translation, independent of the OS.
//!
//! `Translator(Host)` keeps the keyboard/pointer/IME state of one App and turns window
//! messages into events. Every OS query it needs (key state, ToUnicode, the next queued
//! message, IME strings, capture) goes through `Host`, so the Linux unit tests drive it with
//! synthetic messages and a fake host; the Windows backend passes a host backed by user32 and
//! imm32. Window management messages (size, DPI, close, cursor) stay in `backend.zig`; the
//! DPI arithmetic they use is here (`dpi`).
//!
//! Host interface (all methods take `*Host`):
//!   push(Event) void, storeText([]const u8) ?[]const u8,
//!   keyState(vk: i32) i16, keyboardState(*[256]u8) void,
//!   toUnicode(vk: u32, sc: u32, state: *const [256]u8, out: []u16) i32,
//!   vkToScancodeEx(vk: u32) u16, messageTime() u32,
//!   peekKey() ?w.MSG (next queued WM_KEYFIRST..WM_KEYLAST message, not removed),
//!   screenToClient(w.POINT) w.POINT, setCapture() void, releaseCapture() void,
//!   trackLeave() void, doubleClickMs() u32, doubleClickPx() [2]i32,
//!   imeString(kind: u32, out: []u16) ?[]const u16, imeCursor() i32.
const std = @import("std");
const w = @import("win32.zig");
const keymap = @import("keymap.zig");
const ev = @import("../../event.zig");
const ClickCounter = @import("../wayland/input.zig").ClickCounter;

const Event = ev.Event;

/// What the window procedure should do with a message.
pub const Result = union(enum) {
    /// Not ours (or ours but default processing is wanted): call DefWindowProcW.
    default,
    /// Call DefWindowProcW with a modified lParam (WM_IME_SETCONTEXT).
    default_lparam: w.LPARAM,
    /// Handled; return this value.
    handled: w.LRESULT,
};

/// Per-window facts the translator needs.
pub const WindowInfo = struct {
    id: ev.WindowId,
    /// Device pixels per logical unit (dpi / 96).
    scale: f32,
    /// Text input enabled (`startTextInput`): gates `text_input` / IME events like SDL.
    text_input: bool,
};

pub fn Translator(comptime Host: type) type {
    return struct {
        const Self = @This();

        mod_keys: ev.ModKeys = .{},
        /// Keys currently held (evdev code), to tell auto-repeat from a new press and to
        /// suppress repeats of modifier keys (the Wayland backend does not repeat them).
        held: std.StaticBitSet(256) = .initEmpty(),
        /// The fake Left Ctrl that Windows sends before AltGr was swallowed.
        fake_lctrl: bool = false,
        print_screen_down: bool = false,
        high_surrogate: u16 = 0,

        ptr_inside: bool = false,
        ptr_x: f32 = 0,
        ptr_y: f32 = 0,
        buttons: ev.ButtonState = .{},
        captured: bool = false,
        clicks: ClickCounter = .{},

        preedit_active: bool = false,

        // -- keyboard -------------------------------------------------------------------------

        pub fn mods(t: *const Self, host: *Host) ev.Mods {
            const k = t.mod_keys;
            return .{
                .shift = k.lshift or k.rshift,
                .ctrl = k.lctrl or k.rctrl,
                .alt = k.lalt or k.ralt,
                .super = k.lgui or k.rgui,
                .caps_lock = host.keyState(w.VK_CAPITAL) & 1 != 0,
                .num_lock = host.keyState(w.VK_NUMLOCK) & 1 != 0,
            };
        }

        /// Re-reads the physical modifier keys (focus gain: keys may have changed while
        /// another window had focus).
        pub fn syncModifiers(t: *Self, host: *Host) void {
            const down = struct {
                fn f(h: *Host, vk: i32) bool {
                    return h.keyState(vk) < 0;
                }
            }.f;
            t.mod_keys = .{
                .lshift = down(host, w.VK_LSHIFT),
                .rshift = down(host, w.VK_RSHIFT),
                .lctrl = down(host, w.VK_LCONTROL),
                .rctrl = down(host, w.VK_RCONTROL),
                .lalt = down(host, w.VK_LMENU),
                .ralt = down(host, w.VK_RMENU),
                .lgui = down(host, w.VK_LWIN),
                .rgui = down(host, w.VK_RWIN),
            };
            // AltGr reports LCtrl+RAlt; the Ctrl is Windows' fake one.
            if (t.mod_keys.ralt and t.mod_keys.lctrl) t.mod_keys.lctrl = false;
        }

        /// Forgets held keys and buttons (focus lost).
        pub fn resetKeyboard(t: *Self) void {
            t.mod_keys = .{};
            t.held = .initEmpty();
            t.fake_lctrl = false;
            t.high_surrogate = 0;
        }

        fn isAltGrCtrl(host: *Host, time: u32) bool {
            const next = host.peekKey() orelse return false;
            if (next.message != w.WM_KEYDOWN and next.message != w.WM_SYSKEYDOWN and
                next.message != w.WM_KEYUP and next.message != w.WM_SYSKEYUP) return false;
            if (next.wParam != w.VK_MENU) return false;
            if (!keymap.KeyFlags.fromLparam(next.lParam).extended) return false;
            return next.time == time;
        }

        fn keyMessage(t: *Self, host: *Host, win: WindowInfo, msg: u32, wp: w.WPARAM, lp: w.LPARAM) Result {
            const down = msg == w.WM_KEYDOWN or msg == w.WM_SYSKEYDOWN;
            const sys = msg == w.WM_SYSKEYDOWN or msg == w.WM_SYSKEYUP;
            const vk: u32 = @truncate(wp);
            if (vk == w.VK_PROCESSKEY or vk == w.VK_PACKET) return .default;
            const f = keymap.KeyFlags.fromLparam(lp);
            var sc_full: u16 = f.scancode;
            var evdev: u16 = undefined;
            if (f.scancode == 0) {
                sc_full = host.vkToScancodeEx(vk);
                evdev = keymap.evdevFromScancode(sc_full, false);
            } else {
                evdev = keymap.evdevFromScancode(f.scancode, f.extended);
                if (f.extended) sc_full |= 0xE000;
            }
            // Some keyboards report a generic VK_SHIFT etc.; the scancode decides the side.
            if (evdev == 29 and !f.extended) {
                if (down) {
                    if (isAltGrCtrl(host, host.messageTime())) {
                        t.fake_lctrl = true;
                        return .{ .handled = 0 };
                    }
                } else if (t.fake_lctrl) {
                    t.fake_lctrl = false;
                    return .{ .handled = 0 };
                }
            }
            // Alt+F4 and the window menu (Alt+Space) need DefWindowProc; everything else on
            // the sys path is handled so F10 / Alt do not enter menu mode (like SDL).
            const pass_to_default = sys and down and (vk == w.VK_F4 or vk == w.VK_SPACE);

            var events: [2]bool = .{ false, false }; // synthesize down before up
            if (vk == w.VK_SNAPSHOT and !down and !t.print_screen_down) events[0] = true;
            if (vk == w.VK_SNAPSHOT) t.print_screen_down = down;

            const was_held = t.held.isSet(evdev);
            const repeat = down and was_held;
            if (repeat and keymap.isModifier(evdev)) return if (pass_to_default) .default else .{ .handled = 0 };
            t.held.setValue(evdev, down);
            if (keymap.isModifier(evdev)) t.mod_keys.set(evdev, down);

            // Characters: level 0 (empty key state) and with current modifiers (Ctrl only
            // counts as part of AltGr, so Ctrl+C reports 'c').
            var base: u21 = 0;
            var cp: u21 = 0;
            var zero: [256]u8 = @splat(0);
            if (keymap.needsBaseChar(vk) or vk >= 0xBA) base = charOf(host, vk, sc_full, &zero);
            var state: [256]u8 = undefined;
            host.keyboardState(&state);
            const altgr = t.mod_keys.ralt and (state[w.VK_CONTROL] & 0x80 != 0);
            if (!altgr) {
                state[w.VK_CONTROL] = 0;
                state[w.VK_LCONTROL] = 0;
                state[w.VK_RCONTROL] = 0;
                state[w.VK_MENU] = 0;
                state[w.VK_LMENU] = 0;
                state[w.VK_RMENU] = 0;
            }
            cp = charOf(host, vk, sc_full, &state);

            const key = keymap.keycodeFromVk(vk, evdev, base);
            var ke: ev.KeyEvent = .{
                .window = win.id,
                .key = key,
                .keysym = vk,
                .scancode = evdev,
                .codepoint = cp,
                .base_codepoint = base,
                .mod = t.mods(host),
                .mod_keys = t.mod_keys,
                .down = down,
                .repeat = repeat,
            };
            if (events[0]) {
                var d = ke;
                d.down = true;
                host.push(.{ .key_down = d });
            }
            if (down) host.push(.{ .key_down = ke }) else {
                ke.repeat = false;
                host.push(.{ .key_up = ke });
            }
            return if (pass_to_default) .default else .{ .handled = 0 };
        }

        fn charOf(host: *Host, vk: u32, sc: u16, state: *const [256]u8) u21 {
            var buf: [4]u16 = undefined;
            const n = host.toUnicode(vk, sc, state, &buf);
            // -1: dead key; buf[0] holds its spacing form.
            const len: usize = if (n < 0) 1 else @intCast(n);
            if (len == 0) return 0;
            const c = decodeUtf16(buf[0..@min(len, 2)]) orelse return 0;
            if (c < 0x20 or c == 0x7F) return 0;
            return c;
        }

        fn charMessage(t: *Self, host: *Host, win: WindowInfo, wp: w.WPARAM) Result {
            const unit: u16 = @truncate(wp);
            var cp: u21 = undefined;
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                t.high_surrogate = unit;
                return .{ .handled = 0 };
            } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
                if (t.high_surrogate == 0) return .{ .handled = 0 };
                cp = @intCast(0x10000 + ((@as(u32, t.high_surrogate) - 0xD800) << 10) + (unit - 0xDC00));
                t.high_surrogate = 0;
            } else {
                t.high_surrogate = 0;
                cp = unit;
            }
            t.emitText(host, win, cp);
            return .{ .handled = 0 };
        }

        fn emitText(t: *Self, host: *Host, win: WindowInfo, cp: u21) void {
            _ = t;
            if (!win.text_input) return;
            if (cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp < 0xA0)) return;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return;
            const s = host.storeText(buf[0..n]) orelse return;
            host.push(.{ .text_input = .{ .window = win.id, .text = s } });
        }

        // -- IME ------------------------------------------------------------------------------

        fn endPreedit(t: *Self, host: *Host, win: WindowInfo) void {
            if (!t.preedit_active) return;
            t.preedit_active = false;
            host.push(.{ .text_editing = .{ .window = win.id, .text = "" } });
        }

        fn imeComposition(t: *Self, host: *Host, win: WindowInfo, lp: w.LPARAM) Result {
            const flags: u32 = @truncate(@as(usize, @bitCast(lp)));
            var buf: [512]u16 = undefined;
            var u8buf: [1536]u8 = undefined;
            if (flags & w.GCS_RESULTSTR != 0) {
                if (host.imeString(w.GCS_RESULTSTR, &buf)) |r| {
                    t.endPreedit(host, win);
                    const conv = utf16ToUtf8(&u8buf, r, -1);
                    if (conv.text.len > 0) if (host.storeText(conv.text)) |s|
                        host.push(.{ .text_input = .{ .window = win.id, .text = s } });
                }
            }
            if (flags & w.GCS_COMPSTR != 0) {
                const comp = host.imeString(w.GCS_COMPSTR, &buf) orelse &[_]u16{};
                if (comp.len == 0) {
                    t.endPreedit(host, win);
                } else {
                    const cursor = if (flags & w.GCS_CURSORPOS != 0) host.imeCursor() else @as(i32, @intCast(comp.len));
                    const conv = utf16ToUtf8(&u8buf, comp, cursor);
                    if (host.storeText(conv.text)) |s| {
                        t.preedit_active = true;
                        host.push(.{ .text_editing = .{ .window = win.id, .text = s, .cursor_begin = conv.cursor, .cursor_end = conv.cursor } });
                    }
                }
            }
            return .{ .handled = 0 };
        }

        // -- pointer --------------------------------------------------------------------------

        fn logical(v: i32, scale: f32) f32 {
            return @as(f32, @floatFromInt(v)) / scale;
        }

        fn buttonFromMessage(msg: u32, wp: w.WPARAM) u8 {
            return switch (msg) {
                w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_LBUTTONDBLCLK => @intFromEnum(ev.MouseButton.left),
                w.WM_RBUTTONDOWN, w.WM_RBUTTONUP, w.WM_RBUTTONDBLCLK => @intFromEnum(ev.MouseButton.right),
                w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_MBUTTONDBLCLK => @intFromEnum(ev.MouseButton.middle),
                else => if (w.hiword(wp) == w.XBUTTON1) @intFromEnum(ev.MouseButton.back) else @intFromEnum(ev.MouseButton.forward),
            };
        }

        fn setButton(s: *ev.ButtonState, b: u8, down: bool) void {
            switch (b) {
                1 => s.left = down,
                2 => s.middle = down,
                3 => s.right = down,
                4 => s.back = down,
                5 => s.forward = down,
                else => {},
            }
        }

        fn anyButton(s: ev.ButtonState) bool {
            return s.left or s.middle or s.right or s.back or s.forward;
        }

        fn enter(t: *Self, host: *Host, win: WindowInfo) void {
            if (t.ptr_inside) return;
            t.ptr_inside = true;
            host.trackLeave();
            host.push(.{ .mouse_enter = .{ .window = win.id, .x = t.ptr_x, .y = t.ptr_y, .state = t.buttons } });
        }

        fn motion(t: *Self, host: *Host, win: WindowInfo, lp: w.LPARAM) Result {
            const x = logical(w.xParam(lp), win.scale);
            const y = logical(w.yParam(lp), win.scale);
            const first = !t.ptr_inside;
            const dx = if (first) 0 else x - t.ptr_x;
            const dy = if (first) 0 else y - t.ptr_y;
            if (!first and dx == 0 and dy == 0) return .{ .handled = 0 };
            t.ptr_x = x;
            t.ptr_y = y;
            t.enter(host, win);
            host.push(.{ .mouse_motion = .{ .window = win.id, .x = x, .y = y, .xrel = dx, .yrel = dy, .state = t.buttons } });
            return .{ .handled = 0 };
        }

        fn button(t: *Self, host: *Host, win: WindowInfo, msg: u32, wp: w.WPARAM, lp: w.LPARAM) Result {
            const b = buttonFromMessage(msg, wp);
            const down = switch (msg) {
                w.WM_LBUTTONUP, w.WM_RBUTTONUP, w.WM_MBUTTONUP, w.WM_XBUTTONUP => false,
                else => true,
            };
            const x = logical(w.xParam(lp), win.scale);
            const y = logical(w.yParam(lp), win.scale);
            if (x != t.ptr_x or y != t.ptr_y or !t.ptr_inside) {
                const first = !t.ptr_inside;
                const dx = if (first) 0 else x - t.ptr_x;
                const dy = if (first) 0 else y - t.ptr_y;
                t.ptr_x = x;
                t.ptr_y = y;
                t.enter(host, win);
                host.push(.{ .mouse_motion = .{ .window = win.id, .x = x, .y = y, .xrel = dx, .yrel = dy, .state = t.buttons } });
            }
            const xb = msg == w.WM_XBUTTONDOWN or msg == w.WM_XBUTTONUP or msg == w.WM_XBUTTONDBLCLK;
            const ret: Result = .{ .handled = if (xb) w.TRUE else 0 };
            if (down) {
                const was_down = switch (b) {
                    1 => t.buttons.left,
                    2 => t.buttons.middle,
                    3 => t.buttons.right,
                    4 => t.buttons.back,
                    5 => t.buttons.forward,
                    else => false,
                };
                if (was_down) return ret;
                if (!anyButton(t.buttons) and !t.captured) {
                    host.setCapture();
                    t.captured = true;
                }
                setButton(&t.buttons, b, true);
                t.clicks.interval_ms = host.doubleClickMs();
                const px = host.doubleClickPx();
                t.clicks.radius = @as(f32, @floatFromInt(@max(px[0], px[1]))) / 2 / win.scale;
                const n = t.clicks.press(b, host.messageTime(), x, y);
                host.push(.{ .mouse_button_down = .{ .window = win.id, .x = x, .y = y, .button = b, .clicks = n, .down = true } });
            } else {
                const was_down = switch (b) {
                    1 => t.buttons.left,
                    2 => t.buttons.middle,
                    3 => t.buttons.right,
                    4 => t.buttons.back,
                    5 => t.buttons.forward,
                    else => false,
                };
                if (!was_down) return ret;
                setButton(&t.buttons, b, false);
                host.push(.{ .mouse_button_up = .{ .window = win.id, .x = x, .y = y, .button = b, .clicks = t.clicks.current(), .down = false } });
                if (!anyButton(t.buttons) and t.captured) {
                    t.captured = false;
                    host.releaseCapture();
                }
            }
            return ret;
        }

        fn wheel(t: *Self, host: *Host, win: WindowInfo, horizontal: bool, wp: w.WPARAM, lp: w.LPARAM) Result {
            _ = t;
            const delta = w.wheelDelta(wp);
            const pt = host.screenToClient(.{ .x = w.xParam(lp), .y = w.yParam(lp) });
            const amount = @as(f32, @floatFromInt(delta)) / w.WHEEL_DELTA;
            const precise = @rem(delta, w.WHEEL_DELTA) != 0;
            host.push(.{ .mouse_wheel = .{
                .window = win.id,
                .x = if (horizontal) amount else 0,
                .y = if (horizontal) 0 else amount,
                .precise = precise,
                .mouse_x = logical(pt.x, win.scale),
                .mouse_y = logical(pt.y, win.scale),
            } });
            return .{ .handled = 0 };
        }

        /// Translates one message. Window-management messages return `.default`.
        pub fn handle(t: *Self, host: *Host, win: WindowInfo, msg: u32, wp: w.WPARAM, lp: w.LPARAM) Result {
            switch (msg) {
                w.WM_KEYDOWN, w.WM_KEYUP, w.WM_SYSKEYDOWN, w.WM_SYSKEYUP => return t.keyMessage(host, win, msg, wp, lp),
                w.WM_CHAR => return t.charMessage(host, win, wp),
                w.WM_SYSCHAR => return .{ .handled = 0 }, // no beep for unhandled Alt+key
                w.WM_UNICHAR => {
                    if (wp == w.UNICODE_NOCHAR) return .{ .handled = w.TRUE };
                    if (wp <= 0x10FFFF and !(wp >= 0xD800 and wp <= 0xDFFF)) t.emitText(host, win, @intCast(wp));
                    return .{ .handled = w.FALSE };
                },
                w.WM_SETFOCUS => {
                    t.syncModifiers(host);
                    host.push(.{ .focus_gained = .{ .window = win.id } });
                    return .{ .handled = 0 };
                },
                w.WM_KILLFOCUS => {
                    t.resetKeyboard();
                    t.endPreedit(host, win);
                    host.push(.{ .focus_lost = .{ .window = win.id } });
                    return .{ .handled = 0 };
                },
                w.WM_MOUSEMOVE => return t.motion(host, win, lp),
                w.WM_MOUSELEAVE => {
                    if (!t.ptr_inside) return .{ .handled = 0 };
                    t.ptr_inside = false;
                    host.push(.{ .mouse_leave = .{ .window = win.id } });
                    return .{ .handled = 0 };
                },
                w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_RBUTTONDOWN, w.WM_RBUTTONUP, w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_XBUTTONDOWN, w.WM_XBUTTONUP, w.WM_LBUTTONDBLCLK, w.WM_RBUTTONDBLCLK, w.WM_MBUTTONDBLCLK, w.WM_XBUTTONDBLCLK => return t.button(host, win, msg, wp, lp),
                w.WM_CAPTURECHANGED => {
                    // Capture taken away (e.g. a modal loop): release what we think is held.
                    t.captured = false;
                    if (anyButton(t.buttons)) {
                        inline for (.{ 1, 2, 3, 4, 5 }) |b| {
                            const held = switch (b) {
                                1 => t.buttons.left,
                                2 => t.buttons.middle,
                                3 => t.buttons.right,
                                4 => t.buttons.back,
                                else => t.buttons.forward,
                            };
                            if (held) {
                                setButton(&t.buttons, b, false);
                                host.push(.{ .mouse_button_up = .{ .window = win.id, .x = t.ptr_x, .y = t.ptr_y, .button = b, .clicks = t.clicks.current(), .down = false } });
                            }
                        }
                    }
                    return .{ .handled = 0 };
                },
                w.WM_MOUSEWHEEL => return t.wheel(host, win, false, wp, lp),
                w.WM_MOUSEHWHEEL => return t.wheel(host, win, true, wp, lp),
                w.WM_IME_SETCONTEXT => {
                    if (!win.text_input) return .default;
                    // We draw the composition ourselves; keep the candidate list.
                    return .{ .default_lparam = lp & ~w.ISC_SHOWUICOMPOSITIONWINDOW };
                },
                w.WM_IME_STARTCOMPOSITION => return if (win.text_input) .{ .handled = 0 } else .default,
                w.WM_IME_COMPOSITION => return if (win.text_input) t.imeComposition(host, win, lp) else .default,
                w.WM_IME_ENDCOMPOSITION => {
                    if (!win.text_input) return .default;
                    t.endPreedit(host, win);
                    return .{ .handled = 0 };
                },
                w.WM_IME_CHAR => return if (win.text_input) .{ .handled = 0 } else .default,
                else => return .default,
            }
        }
    };
}

// -- UTF-16 helpers -----------------------------------------------------------------------------

/// Decodes one scalar from UTF-16 (a lone surrogate is null).
pub fn decodeUtf16(units: []const u16) ?u21 {
    if (units.len == 0) return null;
    const a = units[0];
    if (a >= 0xD800 and a <= 0xDBFF) {
        if (units.len < 2 or units[1] < 0xDC00 or units[1] > 0xDFFF) return null;
        return @intCast(0x10000 + ((@as(u32, a) - 0xD800) << 10) + (units[1] - 0xDC00));
    }
    if (a >= 0xDC00 and a <= 0xDFFF) return null;
    return a;
}

pub const Converted = struct { text: []const u8, cursor: i32 };

/// UTF-16 → UTF-8 into `out` (lone surrogates become U+FFFD, truncates at a scalar boundary).
/// `cursor16` (UTF-16 index, -1 = none) is converted to a byte offset in the result.
pub fn utf16ToUtf8(out: []u8, units: []const u16, cursor16: i32) Converted {
    var n: usize = 0;
    var i: usize = 0;
    var cursor: i32 = if (cursor16 < 0) -1 else 0;
    var cursor_set = cursor16 < 0;
    while (i < units.len) {
        if (!cursor_set and i >= @as(usize, @intCast(cursor16))) {
            cursor = @intCast(n);
            cursor_set = true;
        }
        var cp: u21 = 0xFFFD;
        var adv: usize = 1;
        if (decodeUtf16(units[i..@min(i + 2, units.len)])) |c| {
            cp = c;
            if (c >= 0x10000) adv = 2;
        }
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch 3;
        if (n + len > out.len) break;
        _ = std.unicode.utf8Encode(cp, out[n..]) catch unreachable;
        n += len;
        i += adv;
    }
    if (!cursor_set) cursor = @intCast(n);
    return .{ .text = out[0..n], .cursor = cursor };
}

/// UTF-8 → UTF-16 length (for clipboard sizing).
pub fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    const view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
    return n;
}

/// Clipboard text normalisation: CRLF → LF (SDL does the same on Windows when reading).
pub fn crlfToLf(s: []u8) []u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') continue;
        s[o] = s[i];
        o += 1;
    }
    return s[0..o];
}

// -- DPI arithmetic --------------------------------------------------------------------------------

pub const dpi = struct {
    pub fn scale(d: u32) f32 {
        return @as(f32, @floatFromInt(@max(d, 1))) / w.USER_DEFAULT_SCREEN_DPI;
    }

    /// Logical units → device pixels (MulDiv rounding, at least 1 for positive input).
    pub fn toPixels(v: i32, d: u32) i32 {
        const p: i64 = @divFloor(@as(i64, v) * d * 2 + w.USER_DEFAULT_SCREEN_DPI, 2 * w.USER_DEFAULT_SCREEN_DPI);
        return @intCast(if (v > 0) @max(p, 1) else p);
    }

    /// Device pixels → logical units (rounded, at least 1 for positive input).
    pub fn toLogical(px: i32, d: u32) i32 {
        const dd: i64 = @max(d, 1);
        const v: i64 = @divFloor(@as(i64, px) * w.USER_DEFAULT_SCREEN_DPI * 2 + dd, 2 * dd);
        return @intCast(if (px > 0) @max(v, 1) else v);
    }

    /// Client size in pixels after a DPI change that keeps the logical size.
    pub fn rescaleClient(logical_w: i32, logical_h: i32, new_dpi: u32) [2]i32 {
        return .{ toPixels(logical_w, new_dpi), toPixels(logical_h, new_dpi) };
    }
};

// ---------------------------------------------------------------------------------------------
// Tests: a fake host and synthetic messages.

const testing = std.testing;

const FakeHost = struct {
    events: [64]Event = undefined,
    n: usize = 0,
    text: [1024]u8 = undefined,
    text_len: usize = 0,
    keys: [256]u8 = @splat(0),
    time: u32 = 1000,
    next: ?w.MSG = null,
    captured: bool = false,
    leave_tracked: u32 = 0,
    ime_comp: []const u16 = &.{},
    ime_result: []const u16 = &.{},
    ime_cursor: i32 = 0,
    /// US layout for ToUnicode: letters, digits, a few OEM keys, AltGr+E = €.
    pub fn push(h: *FakeHost, e: Event) void {
        h.events[h.n] = e;
        h.n += 1;
    }
    pub fn storeText(h: *FakeHost, s: []const u8) ?[]const u8 {
        const out = h.text[h.text_len..][0..s.len];
        @memcpy(out, s);
        h.text_len += s.len;
        return out;
    }
    pub fn keyState(h: *FakeHost, vk: i32) i16 {
        const v = h.keys[@intCast(vk)];
        var r: i16 = 0;
        if (v & 0x80 != 0) r |= @as(i16, @bitCast(@as(u16, 0x8000)));
        if (v & 1 != 0) r |= 1;
        return r;
    }
    pub fn keyboardState(h: *FakeHost, out: *[256]u8) void {
        out.* = h.keys;
    }
    pub fn toUnicode(h: *FakeHost, vk: u32, sc: u32, state: *const [256]u8, out: []u16) i32 {
        _ = h;
        _ = sc;
        const shift = state[w.VK_SHIFT] & 0x80 != 0;
        const ctrl = state[w.VK_CONTROL] & 0x80 != 0;
        const alt = state[w.VK_MENU] & 0x80 != 0;
        if (ctrl and alt) {
            if (vk == 'E') {
                out[0] = 0x20AC;
                return 1;
            }
            return 0;
        }
        if (ctrl) {
            if (vk >= 'A' and vk <= 'Z') {
                out[0] = @intCast(vk - 'A' + 1);
                return 1;
            }
            return 0;
        }
        switch (vk) {
            'A'...'Z' => out[0] = @intCast(if (shift) vk else vk + 32),
            '0'...'9' => out[0] = @intCast(if (shift and vk == '1') '!' else vk),
            w.VK_SPACE => out[0] = ' ',
            w.VK_OEM_1 => out[0] = if (shift) ':' else ';',
            w.VK_OEM_7 => {
                out[0] = '\'';
                return -1; // dead key on US-International
            },
            else => return 0,
        }
        return 1;
    }
    pub fn vkToScancodeEx(h: *FakeHost, vk: u32) u16 {
        _ = h;
        return switch (vk) {
            w.VK_VOLUME_UP => 0xE030,
            w.VK_PAUSE => 0xE11D,
            else => 0,
        };
    }
    pub fn messageTime(h: *FakeHost) u32 {
        return h.time;
    }
    pub fn peekKey(h: *FakeHost) ?w.MSG {
        return h.next;
    }
    pub fn screenToClient(h: *FakeHost, p: w.POINT) w.POINT {
        _ = h;
        return .{ .x = p.x - 100, .y = p.y - 50 };
    }
    pub fn setCapture(h: *FakeHost) void {
        h.captured = true;
    }
    pub fn releaseCapture(h: *FakeHost) void {
        h.captured = false;
    }
    pub fn trackLeave(h: *FakeHost) void {
        h.leave_tracked += 1;
    }
    pub fn doubleClickMs(h: *FakeHost) u32 {
        _ = h;
        return 500;
    }
    pub fn doubleClickPx(h: *FakeHost) [2]i32 {
        _ = h;
        return .{ 4, 4 };
    }
    pub fn imeString(h: *FakeHost, kind: u32, out: []u16) ?[]const u16 {
        const s = if (kind == w.GCS_RESULTSTR) h.ime_result else h.ime_comp;
        @memcpy(out[0..s.len], s);
        return out[0..s.len];
    }
    pub fn imeCursor(h: *FakeHost) i32 {
        return h.ime_cursor;
    }

    fn take(h: *FakeHost) []const Event {
        defer h.n = 0;
        return h.events[0..h.n];
    }
};

const T = Translator(FakeHost);
const win1: WindowInfo = .{ .id = @enumFromInt(1), .scale = 1.5, .text_input = true };

fn keyDown(t: *T, h: *FakeHost, vk: u32, sc: u8, ext: bool) Result {
    return t.handle(h, win1, w.WM_KEYDOWN, vk, keymap.makeKeyLparam(sc, ext, false, false));
}

test "AltGr: the fake Left Ctrl is dropped, text comes through" {
    var h: FakeHost = .{};
    var t: T = .{};
    h.next = .{ .message = w.WM_KEYDOWN, .wParam = w.VK_MENU, .lParam = keymap.makeKeyLparam(0x38, true, false, false), .time = h.time };
    try testing.expectEqual(Result{ .handled = 0 }, keyDown(&t, &h, w.VK_CONTROL, 0x1D, false));
    try testing.expectEqual(@as(usize, 0), h.take().len);
    h.next = null;
    h.keys[w.VK_CONTROL] = 0x80;
    h.keys[w.VK_MENU] = 0x80;
    _ = t.handle(&h, win1, w.WM_SYSKEYDOWN, w.VK_MENU, keymap.makeKeyLparam(0x38, true, false, false));
    var es = h.take();
    try testing.expectEqual(ev.Keycode.ralt, es[0].key_down.key);
    try testing.expect(es[0].key_down.mod_keys.ralt and !es[0].key_down.mod_keys.lctrl and !es[0].key_down.mod.ctrl);
    _ = keyDown(&t, &h, 'E', 0x12, false);
    es = h.take();
    try testing.expectEqual(@as(u21, 0x20AC), es[0].key_down.codepoint);
    try testing.expectEqual(@as(u21, 'e'), es[0].key_down.base_codepoint);
    _ = t.handle(&h, win1, w.WM_CHAR, 0x20AC, 0);
    es = h.take();
    try testing.expectEqualStrings("\u{20AC}", es[0].text_input.text);
    // Release: fake Ctrl up swallowed too.
    _ = t.handle(&h, win1, w.WM_KEYUP, w.VK_CONTROL, keymap.makeKeyLparam(0x1D, false, true, true));
    try testing.expectEqual(@as(usize, 0), h.take().len);
}

test "keys without scancode, pause, numlock, print screen" {
    var h: FakeHost = .{};
    var t: T = .{};
    _ = t.handle(&h, win1, w.WM_KEYDOWN, w.VK_VOLUME_UP, keymap.makeKeyLparam(0, false, false, false));
    var es = h.take();
    try testing.expectEqual(ev.Keycode.volumeup, es[0].key_down.key);
    try testing.expectEqual(@as(u32, 115), es[0].key_down.scancode);
    _ = keyDown(&t, &h, w.VK_PAUSE, 0x45, false);
    es = h.take();
    try testing.expectEqual(ev.Keycode.pause, es[0].key_down.key);
    try testing.expectEqual(@as(u32, 119), es[0].key_down.scancode);
    _ = keyDown(&t, &h, w.VK_NUMLOCK, 0x45, true);
    es = h.take();
    try testing.expectEqual(ev.Keycode.num_lock, es[0].key_down.key);
    try testing.expectEqual(@as(u32, 69), es[0].key_down.scancode);
    // Windows delivers only the release of Print Screen.
    _ = t.handle(&h, win1, w.WM_KEYUP, w.VK_SNAPSHOT, keymap.makeKeyLparam(0x37, true, true, true));
    es = h.take();
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqual(ev.Keycode.print_screen, es[0].key_down.key);
    try testing.expectEqual(ev.Keycode.print_screen, es[1].key_up.key);
}

test "WM_CHAR: surrogate pairs, gating, control characters" {
    var h: FakeHost = .{};
    var t: T = .{};
    _ = t.handle(&h, win1, w.WM_CHAR, 0xD83D, 0);
    try testing.expectEqual(@as(usize, 0), h.n);
    _ = t.handle(&h, win1, w.WM_CHAR, 0xDE00, 0);
    var es = h.take();
    try testing.expectEqualStrings("\u{1F600}", es[0].text_input.text);
    _ = t.handle(&h, win1, w.WM_CHAR, 3, 0); // Ctrl+C
    _ = t.handle(&h, win1, w.WM_CHAR, 0x7F, 0);
    _ = t.handle(&h, win1, w.WM_CHAR, 0xDE00, 0); // lone low surrogate
    try testing.expectEqual(@as(usize, 0), h.take().len);
    var off = win1;
    off.text_input = false;
    _ = t.handle(&h, off, w.WM_CHAR, 'a', 0);
    try testing.expectEqual(@as(usize, 0), h.take().len);
    try testing.expectEqual(Result{ .handled = w.TRUE }, t.handle(&h, win1, w.WM_UNICHAR, w.UNICODE_NOCHAR, 0));
    _ = t.handle(&h, win1, w.WM_UNICHAR, 0x1F642, 0);
    es = h.take();
    try testing.expectEqualStrings("\u{1F642}", es[0].text_input.text);
}

test "IME: composition with cursor, commit, end" {
    var h: FakeHost = .{};
    var t: T = .{};
    const comp = [_]u16{ 0x306B, 0x307B, 0xD83D, 0xDE00 }; // にほ😀
    h.ime_comp = &comp;
    h.ime_cursor = 2;
    _ = t.handle(&h, win1, w.WM_IME_STARTCOMPOSITION, 0, 0);
    _ = t.handle(&h, win1, w.WM_IME_COMPOSITION, 0, w.GCS_COMPSTR | w.GCS_CURSORPOS);
    var es = h.take();
    try testing.expectEqualStrings("にほ😀", es[0].text_editing.text);
    try testing.expectEqual(@as(i32, 6), es[0].text_editing.cursor_begin);
    h.ime_result = &[_]u16{ 0x65E5, 0x672C };
    h.ime_comp = &.{};
    _ = t.handle(&h, win1, w.WM_IME_COMPOSITION, 0, w.GCS_RESULTSTR | w.GCS_COMPSTR);
    es = h.take();
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqualStrings("", es[0].text_editing.text);
    try testing.expectEqualStrings("日本", es[1].text_input.text);
    _ = t.handle(&h, win1, w.WM_IME_ENDCOMPOSITION, 0, 0);
    try testing.expectEqual(@as(usize, 0), h.take().len);
    try testing.expectEqual(Result{ .default_lparam = 0x1 }, t.handle(&h, win1, w.WM_IME_SETCONTEXT, 1, w.ISC_SHOWUICOMPOSITIONWINDOW | 0x1));
    var off = win1;
    off.text_input = false;
    try testing.expectEqual(Result.default, t.handle(&h, off, w.WM_IME_COMPOSITION, 0, w.GCS_COMPSTR));
}

test "utf16 to utf8 with cursor" {
    var out: [32]u8 = undefined;
    const r = utf16ToUtf8(&out, &[_]u16{ 'a', 0xE9, 0xD83D, 0xDE00, 'b' }, 4);
    try testing.expectEqualStrings("a\u{E9}\u{1F600}b", r.text);
    try testing.expectEqual(@as(i32, 7), r.cursor);
    const end = utf16ToUtf8(&out, &[_]u16{ 'a', 'b' }, 2);
    try testing.expectEqual(@as(i32, 2), end.cursor);
    const lone = utf16ToUtf8(&out, &[_]u16{0xD800}, -1);
    try testing.expectEqualStrings("\u{FFFD}", lone.text);
    try testing.expectEqual(@as(i32, -1), lone.cursor);
    try testing.expectEqual(@as(usize, 4), utf16Len("a\u{1F600}b"));
    var crlf = "a\r\nb\r".*;
    try testing.expectEqualStrings("a\nb\r", crlfToLf(&crlf));
}

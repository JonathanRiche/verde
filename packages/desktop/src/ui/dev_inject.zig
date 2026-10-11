//! Dev hook for headless trials: with `VERDE_PALETTE_INJECT=/path`, a script
//! file written to `/path` is consumed on the next loop iteration and its lines
//! become synthetic platform events dispatched exactly like real ones. Nothing
//! reaches the compositor or other clients, so a trial instance can be driven
//! on a hidden output without focusing it. Write the script to a temp name and
//! rename it into place; poke the loop (any `verde live` call) to wake it.
//!
//! Coordinates are framebuffer pixels (as in offscreen snapshots). Lines:
//!   key [ctrl+][shift+][alt+][super+]<keycode>   press and release
//!   down|up <keycode>                            single key edge (mods from held keys)
//!   text <utf8...>                               committed text only
//!   type <utf8...>                               per character: key down, text, key up
//!   edit <cursor> <utf8...>                      pre-edit (empty text clears)
//!   move <x> <y>
//!   press|release <x> <y> [button] [clicks]
//!   click <x> <y> [button] [clicks]
//!   drag <x0> <y0> <x1> <y1> [steps]
//!   wheel <x> <y> <dx> <dy> [precise]
//!   focus in|out    leave    theme    close
//!   # comment

const std = @import("std");
const builtin = @import("builtin");
const palette = @import("palette");

const Event = palette.Event;
const Keycode = palette.event.Keycode;
const Mods = palette.event.Mods;

var path_state: enum { unknown, unset, set } = .unknown;
var path_value: [:0]const u8 = "";
var mods_held: Mods = .{};

fn scriptPath() ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    if (path_state == .unknown) {
        path_state = .unset;
        if (std.c.getenv("VERDE_PALETTE_INJECT")) |value| {
            path_value = std.mem.span(value);
            if (path_value.len > 0) path_state = .set;
        }
    }
    return if (path_state == .set) path_value else null;
}

pub fn enabled() bool {
    return scriptPath() != null;
}

/// Reads and removes the pending script, returning its bytes (caller frees).
pub fn take(allocator: std.mem.Allocator) ?[]u8 {
    // The hook is POSIX-only (scriptPath is null on Windows); keep libc file
    // calls out of the Windows build, where std.c.open does not exist.
    if (comptime builtin.os.tag == .windows) return null;
    const path = scriptPath() orelse return null;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    _ = std.c.unlink(path.ptr);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        out.appendSlice(allocator, chunk[0..@intCast(n)]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Writes `name` to `<script path>.cursor` so a driver can read the shape.
fn writeCursorReport(name: []const u8) void {
    if (comptime builtin.os.tag == .windows) return;
    const path = scriptPath() orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const report = std.fmt.bufPrintZ(&buf, "{s}.cursor", .{path}) catch return;
    const fd = std.c.open(report.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, name.ptr, name.len);
}

pub const Sink = struct {
    context: *anyopaque,
    dispatch: *const fn (context: *anyopaque, event: *Event) bool,
    window: palette.event.WindowId,
    /// Framebuffer pixels per logical point.
    scale: f32,
    /// Name of the pointer shape last requested, reported by the `cursor` verb.
    cursor: []const u8 = "",

    fn send(self: Sink, event: Event) bool {
        var copy = event;
        return self.dispatch(self.context, &copy);
    }
};

/// Dispatches every line of `script`. Returns false when an event asked the
/// app to quit.
pub fn run(script: []const u8, sink: Sink) bool {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!runLine(line, sink)) return false;
    }
    return true;
}

fn runLine(line: []const u8, sink: Sink) bool {
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const verb = line[0..space];
    const rest = if (space < line.len) line[space + 1 ..] else "";
    var args = std.mem.tokenizeScalar(u8, rest, ' ');
    const w = sink.window;
    if (eql(verb, "text")) {
        return sink.send(.{ .text_input = .{ .window = w, .text = rest } });
    } else if (eql(verb, "type")) {
        var it = (std.unicode.Utf8View.init(rest) catch return true).iterator();
        while (it.nextCodepointSlice()) |slice| {
            const typed = typedKey(slice);
            if (typed.key != .unknown) {
                if (!sink.send(.{ .key_down = keyEvent(w, typed.key, .{ .shift = typed.shift }) })) return false;
            }
            if (!sink.send(.{ .text_input = .{ .window = w, .text = slice } })) return false;
            if (typed.key != .unknown) {
                var up = keyEvent(w, typed.key, .{ .shift = typed.shift });
                up.down = false;
                if (!sink.send(.{ .key_up = up })) return false;
            }
        }
        return true;
    } else if (eql(verb, "edit")) {
        const cursor_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const cursor = std.fmt.parseInt(i32, rest[0..cursor_end], 10) catch -1;
        const text = if (cursor_end < rest.len) rest[cursor_end + 1 ..] else "";
        return sink.send(.{ .text_editing = .{ .window = w, .text = text, .cursor_begin = cursor, .cursor_end = cursor } });
    } else if (eql(verb, "key")) {
        const chord = args.next() orelse return true;
        var mods: Mods = .{};
        var parts = std.mem.splitScalar(u8, chord, '+');
        var key_name: []const u8 = chord;
        while (parts.next()) |part| {
            if (parts.peek() == null) {
                key_name = part;
            } else if (eql(part, "ctrl")) mods.ctrl = true else if (eql(part, "shift")) mods.shift = true else if (eql(part, "alt")) mods.alt = true else if (eql(part, "super")) mods.super = true;
        }
        const key = keycode(key_name);
        var down = keyEvent(w, key, mods);
        if (!sink.send(.{ .key_down = down })) return false;
        down.down = false;
        return sink.send(.{ .key_up = down });
    } else if (eql(verb, "down") or eql(verb, "up")) {
        const key = keycode(args.next() orelse return true);
        const is_down = eql(verb, "down");
        switch (key) {
            .lctrl, .rctrl => mods_held.ctrl = is_down,
            .lshift, .rshift => mods_held.shift = is_down,
            .lalt, .ralt => mods_held.alt = is_down,
            .lgui, .rgui => mods_held.super = is_down,
            else => {},
        }
        var event = keyEvent(w, key, mods_held);
        event.down = is_down;
        return sink.send(if (is_down) .{ .key_down = event } else .{ .key_up = event });
    } else if (eql(verb, "move")) {
        const x = num(&args, sink.scale);
        const y = num(&args, sink.scale);
        return sink.send(.{ .mouse_motion = .{ .window = w, .x = x, .y = y } });
    } else if (eql(verb, "press") or eql(verb, "release") or eql(verb, "click")) {
        const x = num(&args, sink.scale);
        const y = num(&args, sink.scale);
        const button = int(&args, 1);
        const clicks = int(&args, 1);
        const b: palette.event.ButtonEvent = .{ .window = w, .x = x, .y = y, .button = button, .clicks = clicks, .down = true };
        if (!eql(verb, "release")) {
            if (!sink.send(.{ .mouse_motion = .{ .window = w, .x = x, .y = y } })) return false;
            if (!sink.send(.{ .mouse_button_down = b })) return false;
        }
        if (eql(verb, "press")) return true;
        var up = b;
        up.down = false;
        return sink.send(.{ .mouse_button_up = up });
    } else if (eql(verb, "drag")) {
        const x0 = num(&args, sink.scale);
        const y0 = num(&args, sink.scale);
        const x1 = num(&args, sink.scale);
        const y1 = num(&args, sink.scale);
        const steps: u32 = @max(1, int(&args, 12));
        if (!sink.send(.{ .mouse_motion = .{ .window = w, .x = x0, .y = y0 } })) return false;
        if (!sink.send(.{ .mouse_button_down = .{ .window = w, .x = x0, .y = y0 } })) return false;
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const x = x0 + (x1 - x0) * t;
            const y = y0 + (y1 - y0) * t;
            if (!sink.send(.{ .mouse_motion = .{ .window = w, .x = x, .y = y, .state = .{ .left = true } } })) return false;
        }
        return sink.send(.{ .mouse_button_up = .{ .window = w, .x = x1, .y = y1, .down = false } });
    } else if (eql(verb, "wheel")) {
        const x = num(&args, sink.scale);
        const y = num(&args, sink.scale);
        const dx = num(&args, 1);
        const dy = num(&args, 1);
        const precise = if (args.next()) |p| eql(p, "precise") else false;
        return sink.send(.{ .mouse_wheel = .{ .window = w, .x = dx, .y = dy, .precise = precise, .mouse_x = x, .mouse_y = y } });
    } else if (eql(verb, "focus")) {
        const gained = if (args.next()) |a| eql(a, "in") else true;
        return sink.send(if (gained) .{ .focus_gained = .{ .window = w } } else .{ .focus_lost = .{ .window = w } });
    } else if (eql(verb, "leave")) {
        return sink.send(.{ .mouse_leave = .{ .window = w } });
    } else if (eql(verb, "theme")) {
        return sink.send(.system_theme_changed);
    } else if (eql(verb, "close")) {
        return sink.send(.{ .close_requested = .{ .window = w } });
    } else if (eql(verb, "hidden")) {
        return sink.send(.{ .window_hidden = .{ .window = w } });
    } else if (eql(verb, "shown")) {
        return sink.send(.{ .window_shown = .{ .window = w } });
    } else if (eql(verb, "cursor")) {
        writeCursorReport(sink.cursor);
    }
    return true;
}

fn keyEvent(w: palette.event.WindowId, key: Keycode, mods: Mods) palette.event.KeyEvent {
    const cp = codepointFor(key, mods.shift);
    return .{
        .window = w,
        .key = key,
        .scancode = evdevFor(key),
        .codepoint = cp,
        .base_codepoint = codepointFor(key, false),
        .mod = mods,
        .mod_keys = .{ .lctrl = mods.ctrl, .lshift = mods.shift, .lalt = mods.alt, .lgui = mods.super },
        .down = true,
    };
}

const shifted_symbols = "~!@#$%^&*()_+{}|:\"<>?";
const unshifted_symbols = "`1234567890-=[]\\;',./";

/// US-layout key for a typed character (unknown for non-ASCII).
fn typedKey(slice: []const u8) struct { key: Keycode, shift: bool } {
    if (slice.len != 1) return .{ .key = .unknown, .shift = false };
    const ch = slice[0];
    if (ch >= 'A' and ch <= 'Z') return .{ .key = Keycode.fromAscii(ch), .shift = true };
    if (std.mem.indexOfScalar(u8, shifted_symbols, ch)) |i| return .{ .key = Keycode.fromAscii(unshifted_symbols[i]), .shift = true };
    const key = Keycode.fromAscii(ch);
    return .{ .key = if (key == .character) .unknown else key, .shift = false };
}

fn keycode(name: []const u8) Keycode {
    if (eql(name, "enter")) return .@"return";
    if (eql(name, "esc")) return .escape;
    if (eql(name, "ctrl")) return .lctrl;
    if (eql(name, "shift")) return .lshift;
    if (eql(name, "alt")) return .lalt;
    if (eql(name, "super")) return .lgui;
    if (name.len == 1) return Keycode.fromAscii(name[0]);
    return std.meta.stringToEnum(Keycode, name) orelse .unknown;
}

fn codepointFor(key: Keycode, shift: bool) u21 {
    const k = @intFromEnum(key);
    if (k >= @intFromEnum(Keycode.a) and k <= @intFromEnum(Keycode.z)) {
        const base: u21 = 'a' + @as(u21, @intCast(k - @intFromEnum(Keycode.a)));
        return if (shift) base - 32 else base;
    }
    if (k >= @intFromEnum(Keycode.@"0") and k <= @intFromEnum(Keycode.@"9")) return '0' + @as(u21, @intCast(k - @intFromEnum(Keycode.@"0")));
    return switch (key) {
        .space => ' ',
        .minus => '-',
        .equals => '=',
        .leftbracket => '[',
        .rightbracket => ']',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .grave => '`',
        .comma => ',',
        .period => '.',
        .slash => '/',
        else => 0,
    };
}

fn evdevFor(key: Keycode) u32 {
    const letters = "qwertyuiopasdfghjklzxcvbnm";
    const letter_codes = [_]u32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 38, 44, 45, 46, 47, 48, 49, 50 };
    const cp = codepointFor(key, false);
    if (cp >= 'a' and cp <= 'z') {
        const index = std.mem.indexOfScalar(u8, letters, @intCast(cp)).?;
        return letter_codes[index];
    }
    if (cp >= '1' and cp <= '9') return 2 + (cp - '1');
    return switch (key) {
        .@"0" => 11,
        .escape => 1,
        .minus => 12,
        .equals => 13,
        .backspace => 14,
        .tab => 15,
        .leftbracket => 26,
        .rightbracket => 27,
        .@"return" => 28,
        .lctrl => 29,
        .semicolon => 39,
        .apostrophe => 40,
        .grave => 41,
        .lshift => 42,
        .backslash => 43,
        .comma => 51,
        .period => 52,
        .slash => 53,
        .rshift => 54,
        .lalt => 56,
        .space => 57,
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10 => 59 + @as(u32, @intFromEnum(key) - @intFromEnum(Keycode.f1)),
        .f11 => 87,
        .f12 => 88,
        .rctrl => 97,
        .ralt => 100,
        .home => 102,
        .up => 103,
        .pageup => 104,
        .left => 105,
        .right => 106,
        .end => 107,
        .down => 108,
        .pagedown => 109,
        .insert => 110,
        .delete => 111,
        .lgui => 125,
        .rgui => 126,
        else => 0,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn num(args: *std.mem.TokenIterator(u8, .scalar), scale: f32) f32 {
    const value = std.fmt.parseFloat(f32, args.next() orelse "0") catch 0;
    return value / scale;
}

fn int(args: *std.mem.TokenIterator(u8, .scalar), default: u8) u8 {
    const token = args.next() orelse return default;
    return std.fmt.parseInt(u8, token, 10) catch default;
}

test "inject script maps chords and pixel coordinates" {
    const Capture = struct {
        events: [8]Event = undefined,
        count: usize = 0,
        fn dispatch(context: *anyopaque, event: *Event) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events[self.count] = event.*;
            self.count += 1;
            return true;
        }
    };
    var capture: Capture = .{};
    const sink: Sink = .{ .context = &capture, .dispatch = Capture.dispatch, .window = .invalid, .scale = 2 };
    try std.testing.expect(run("key ctrl+shift+p\n# c\nwheel 100 50 0 -3 precise\n", sink));
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    const down = capture.events[0].key_down;
    try std.testing.expectEqual(Keycode.p, down.key);
    try std.testing.expect(down.mod.ctrl and down.mod.shift);
    try std.testing.expectEqual(@as(u32, 25), down.scancode);
    const wheel = capture.events[2].mouse_wheel;
    try std.testing.expectEqual(@as(f32, 50), wheel.mouse_x);
    try std.testing.expect(wheel.precise);
}

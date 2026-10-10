//! NSTextInputClient state machine (pure logic; unit-tested on every OS).
//!
//! Mirrors SDL3's `SDL3TranslatorResponder` + `Cocoa_HandleKeyEvent`:
//!
//! * While text input is active, a keyDown is not reported immediately. It becomes the
//!   *pending key*, the event goes through `-[NSView interpretKeyEvents:]`, and AppKit calls
//!   back into the NSTextInputClient methods. `insertText:` flushes the pending key first
//!   (key_down, then text_input); `setMarkedText:` / `unmarkText` mean the IME consumed the
//!   key, so it is dropped. Whatever is still pending after `interpretKeyEvents:` returns
//!   (keys that produce no text, e.g. arrows) is reported then.
//! * `insertText:replacementRange:` with a real replacement range (the press-and-hold accent
//!   menu replacing the last character) is reported as Backspace down/up before the text.
//! * Marked (pre-edit) text becomes `text_editing`; its selection range, which AppKit gives in
//!   UTF-16 code units, is converted to byte offsets into the UTF-8 text.
//! * While text input is inactive no text events are produced (SDL's gating) and keys are
//!   reported directly.
const std = @import("std");
const ev = @import("../../event.zig");

/// Byte offset in UTF-8 `s` of UTF-16 code unit index `u16_index` (clamped to `s.len`).
/// An index pointing into the middle of a surrogate pair rounds up to the next scalar.
pub fn utf16ToUtf8Offset(s: []const u8, u16_index: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len and units < u16_index) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const len = @min(n, s.len - i);
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return i;
}

/// UTF-16 length of UTF-8 `s` (what `-[NSString length]` would report).
pub fn utf16Length(s: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const len = @min(n, s.len - i);
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return units;
}

pub const backspace_key: ev.KeyEvent = .{ .key = .backspace, .keysym = 0x33, .scancode = 14 };

/// `Sink` provides `key(ev.KeyEvent)`, `text([]const u8)` and
/// `edit(text, cursor_begin, cursor_end)`; slices are only valid during the call.
pub fn Ime(comptime Sink: type) type {
    return struct {
        const Self = @This();

        pending: ?ev.KeyEvent = null,
        /// Marked text is showing (`hasMarkedText`).
        marked: bool = false,
        /// UTF-16 lengths reported back to AppKit (`markedRange`, `selectedRange`).
        marked_len16: usize = 0,
        sel_location16: usize = 0,
        sel_length16: usize = 0,

        /// keyDown while text input is active: hold the key until AppKit tells us whether the
        /// IME consumed it.
        pub fn beginKeyDown(self: *Self, k: ev.KeyEvent) void {
            self.pending = k;
        }

        /// After `interpretKeyEvents:` returned.
        pub fn endKeyDown(self: *Self, sink: Sink) void {
            self.sendPending(sink);
        }

        fn sendPending(self: *Self, sink: Sink) void {
            if (self.pending) |k| {
                self.pending = null;
                sink.key(k);
            }
        }

        /// `insertText:replacementRange:`. `replacing`: the replacement range's location is
        /// not NSNotFound.
        pub fn insertText(self: *Self, sink: Sink, text: []const u8, replacing: bool) void {
            if (self.marked) self.unmark(sink);
            self.sendPending(sink);
            if (replacing) {
                var down = backspace_key;
                sink.key(down);
                down.down = false;
                sink.key(down);
            }
            if (text.len > 0) sink.text(text);
        }

        /// `setMarkedText:selectedRange:replacementRange:` with the UTF-16 selection.
        pub fn setMarkedText(self: *Self, sink: Sink, text: []const u8, sel_location16: usize, sel_length16: usize) void {
            if (text.len == 0) return self.unmark(sink);
            self.marked = true;
            self.marked_len16 = utf16Length(text);
            self.sel_location16 = sel_location16;
            self.sel_length16 = sel_length16;
            self.pending = null; // consumed by the IME
            const b = utf16ToUtf8Offset(text, sel_location16);
            const e = utf16ToUtf8Offset(text, sel_location16 + sel_length16);
            sink.edit(text, @intCast(b), @intCast(e));
        }

        /// `unmarkText` (also used when composition is cancelled or text input stops).
        pub fn unmark(self: *Self, sink: Sink) void {
            self.marked = false;
            self.marked_len16 = 0;
            self.sel_location16 = 0;
            self.sel_length16 = 0;
            self.pending = null;
            sink.edit("", 0, 0);
        }

        /// Text input stopped / focus lost: end a composition without committing it.
        pub fn reset(self: *Self, sink: Sink) void {
            if (self.marked) self.unmark(sink);
            self.pending = null;
        }
    };
}

const TestSink = struct {
    log: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn w(self: TestSink, comptime fmt: []const u8, args: anytype) void {
        self.log.print(self.gpa, fmt, args) catch unreachable;
    }
    pub fn key(self: TestSink, k: ev.KeyEvent) void {
        self.w("K{s}{s};", .{ @tagName(k.key), if (k.down) "+" else "-" });
    }
    pub fn text(self: TestSink, t: []const u8) void {
        self.w("T{s};", .{t});
    }
    pub fn edit(self: TestSink, t: []const u8, b: i32, e: i32) void {
        self.w("E{s}[{d},{d}];", .{ t, b, e });
    }
};

test "utf16 offsets to utf8 bytes" {
    try std.testing.expectEqual(@as(usize, 0), utf16ToUtf8Offset("abc", 0));
    try std.testing.expectEqual(@as(usize, 2), utf16ToUtf8Offset("abc", 2));
    try std.testing.expectEqual(@as(usize, 3), utf16ToUtf8Offset("abc", 9));
    // "にほん": 3 BMP scalars of 3 bytes.
    try std.testing.expectEqual(@as(usize, 6), utf16ToUtf8Offset("にほん", 2));
    // U+1F600 is a surrogate pair (2 units, 4 bytes).
    try std.testing.expectEqual(@as(usize, 5), utf16ToUtf8Offset("a\u{1F600}b", 3));
    try std.testing.expectEqual(@as(usize, 5), utf16ToUtf8Offset("a\u{1F600}b", 2)); // mid-pair rounds up
    try std.testing.expectEqual(@as(usize, 4), utf16Length("a\u{1F600}b"));
    try std.testing.expectEqual(@as(usize, 3), utf16Length("にほん"));
}

test "IME: plain key, composition, commit, accent replacement" {
    const gpa = std.testing.allocator;
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    const sink: TestSink = .{ .log = &log, .gpa = gpa };
    var ime: Ime(TestSink) = .{};

    // 'a' typed: key then text.
    ime.beginKeyDown(.{ .key = .a });
    ime.insertText(sink, "a", false);
    ime.endKeyDown(sink);
    try std.testing.expectEqualStrings("Ka+;Ta;", log.items);
    log.clearRetainingCapacity();

    // Arrow key: no text, reported after interpretKeyEvents.
    ime.beginKeyDown(.{ .key = .left });
    ime.endKeyDown(sink);
    try std.testing.expectEqualStrings("Kleft+;", log.items);
    log.clearRetainingCapacity();

    // Japanese IME: "n" -> marked "ん" (key consumed), then Return commits.
    ime.beginKeyDown(.{ .key = .n });
    ime.setMarkedText(sink, "ん", 1, 0);
    ime.endKeyDown(sink);
    try std.testing.expect(ime.marked);
    ime.beginKeyDown(.{ .key = .@"return" });
    ime.insertText(sink, "ん", false);
    ime.endKeyDown(sink);
    try std.testing.expectEqualStrings("Eん[3,3];E[0,0];Tん;", log.items);
    try std.testing.expect(!ime.marked);
    log.clearRetainingCapacity();

    // Press-and-hold accent menu replaces the previous 'e' with 'é'.
    ime.insertText(sink, "é", true);
    try std.testing.expectEqualStrings("Kbackspace+;Kbackspace-;Té;", log.items);
    log.clearRetainingCapacity();

    // Selection inside the marked text (clause conversion) in UTF-16 units.
    ime.setMarkedText(sink, "日本語", 1, 2);
    try std.testing.expectEqualStrings("E日本語[3,9];", log.items);
    log.clearRetainingCapacity();
    ime.setMarkedText(sink, "", 0, 0);
    try std.testing.expectEqualStrings("E[0,0];", log.items);
    log.clearRetainingCapacity();
    ime.reset(sink);
    try std.testing.expectEqualStrings("", log.items);
}

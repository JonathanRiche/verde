//! Editing model shared by small native text fields (the Files explorer
//! filter, the agent prompt popover): owned UTF-8 text, a caret and an
//! optional selection anchor, with the keyboard behaviour `ui/AGENTS.md`
//! requires — Left/Right (Ctrl: by word), Home/End, Shift extends,
//! select-all/copy/cut/paste, selection-aware insert/Backspace/Delete.
//! Single-line fields strip control characters; multi-line fields keep
//! newlines (Shift+Enter inserts one, Enter submits).
//!
//! Offsets are byte offsets that always sit on codepoint boundaries.
//! Drawing and hit-testing (caret x from measured prefixes) stay with the
//! owning view; `offsetAtX` / `lineSpans` help with that.

const std = @import("std");
const sdl = @import("zsdl3");

pub const Range = struct { start: usize, end: usize };

pub const KeyResult = enum {
    /// Not an editing key; let the caller route it.
    unhandled,
    /// Caret/selection moved.
    moved,
    /// Text changed.
    changed,
    submit,
    cancel,
};

pub const Field = struct {
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: ?usize = null,
    multiline: bool = false,
    max_bytes: usize = 4096,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = .{ .multiline = self.multiline, .max_bytes = self.max_bytes };
    }

    pub fn value(self: *const Field) []const u8 {
        return self.text.items;
    }

    pub fn clear(self: *Field) void {
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.anchor = null;
    }

    pub fn selection(self: *const Field) ?Range {
        const anchor = self.anchor orelse return null;
        if (anchor == self.cursor) return null;
        return .{ .start = @min(anchor, self.cursor), .end = @max(anchor, self.cursor) };
    }

    pub fn selectedText(self: *const Field) []const u8 {
        const range = self.selection() orelse return "";
        return self.text.items[range.start..range.end];
    }

    pub fn selectAll(self: *Field) void {
        self.anchor = 0;
        self.cursor = self.text.items.len;
    }

    /// Removes the selection; true when there was one.
    pub fn deleteSelection(self: *Field) bool {
        const range = self.selection() orelse {
            self.anchor = null;
            return false;
        };
        self.text.replaceRangeAssumeCapacity(range.start, range.end - range.start, &.{});
        self.cursor = range.start;
        self.anchor = null;
        return true;
    }

    /// Inserts `bytes` over the selection after sanitizing (control
    /// characters dropped; newlines kept only when multi-line; tabs become
    /// spaces), truncated at a codepoint boundary to `max_bytes`.
    pub fn insert(self: *Field, allocator: std.mem.Allocator, bytes: []const u8) !bool {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(allocator);
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            if (byte == '\r') {
                if (self.multiline and !(index + 1 < bytes.len and bytes[index + 1] == '\n')) try clean.append(allocator, '\n');
                continue;
            }
            if (byte == '\n') {
                try clean.append(allocator, if (self.multiline) '\n' else ' ');
                continue;
            }
            if (byte == '\t') {
                try clean.append(allocator, ' ');
                continue;
            }
            if (byte < 0x20 or byte == 0x7f) continue;
            try clean.append(allocator, byte);
        }
        const valid = utf8ValidPrefix(clean.items);
        const had_selection = self.deleteSelection();
        const room = self.max_bytes -| self.text.items.len;
        const fitted = utf8ValidPrefix(valid[0..@min(valid.len, room)]);
        if (fitted.len == 0) return had_selection;
        try self.text.insertSlice(allocator, self.cursor, fitted);
        self.cursor += fitted.len;
        self.anchor = null;
        return true;
    }

    pub fn setText(self: *Field, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.clear();
        _ = try self.insert(allocator, bytes);
    }

    /// Moves the caret to `offset`, extending the selection when `extend`.
    pub fn moveTo(self: *Field, offset: usize, extend: bool) void {
        const target = @min(offset, self.text.items.len);
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else self.anchor = null;
        self.cursor = target;
    }

    /// Selects the word around `offset` (double-click).
    pub fn selectWordAt(self: *Field, offset: usize) void {
        const text = self.text.items;
        var start = @min(offset, text.len);
        var end = start;
        while (start > 0 and isWordByte(text[start - 1])) start -= 1;
        while (end < text.len and isWordByte(text[end])) end += 1;
        self.anchor = start;
        self.cursor = end;
    }

    /// Selects the logical line around `offset` (triple-click); the whole
    /// text in single-line fields.
    pub fn selectLineAt(self: *Field, offset: usize) void {
        const text = self.text.items;
        if (!self.multiline) return self.selectAll();
        const at = @min(offset, text.len);
        self.anchor = lineStart(text, at);
        self.cursor = lineEnd(text, at);
    }

    /// Editing keys. Clipboard keys need the app: see `handleKeyWithClipboard`.
    pub fn handleKey(self: *Field, allocator: std.mem.Allocator, key: sdl.Keycode, mod: sdl.Keymod) !KeyResult {
        return self.handleKeyBits(allocator, key, modBits(mod));
    }

    /// `handleKey` with the modifier bits (`sdl.Keymod.*` masks).
    pub fn handleKeyBits(self: *Field, allocator: std.mem.Allocator, key: sdl.Keycode, mod: u16) !KeyResult {
        const primary = (mod & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
        const shift = (mod & sdl.Keymod.shift) != 0;
        const text = self.text.items;
        switch (key) {
            .left => {
                if (!shift and self.selection() != null) {
                    self.moveTo(self.selection().?.start, false);
                } else self.moveTo(if (primary) wordLeft(text, self.cursor) else prevBoundary(text, self.cursor), shift);
                return .moved;
            },
            .right => {
                if (!shift and self.selection() != null) {
                    self.moveTo(self.selection().?.end, false);
                } else self.moveTo(if (primary) wordRight(text, self.cursor) else nextBoundary(text, self.cursor), shift);
                return .moved;
            },
            .home => {
                self.moveTo(if (primary or !self.multiline) 0 else lineStart(text, self.cursor), shift);
                return .moved;
            },
            .end => {
                self.moveTo(if (primary or !self.multiline) text.len else lineEnd(text, self.cursor), shift);
                return .moved;
            },
            .up, .down => {
                if (!self.multiline) return .unhandled;
                // Logical-line movement; wrapped views may override.
                const target = verticalLogical(text, self.cursor, key == .down) orelse return .unhandled;
                self.moveTo(target, shift);
                return .moved;
            },
            .backspace => {
                if (self.deleteSelection()) return .changed;
                if (self.cursor == 0) return .moved;
                const start = if (primary) wordLeft(text, self.cursor) else prevBoundary(text, self.cursor);
                self.text.replaceRangeAssumeCapacity(start, self.cursor - start, &.{});
                self.cursor = start;
                return .changed;
            },
            .delete => {
                if (self.deleteSelection()) return .changed;
                if (self.cursor >= text.len) return .moved;
                const end = if (primary) wordRight(text, self.cursor) else nextBoundary(text, self.cursor);
                self.text.replaceRangeAssumeCapacity(self.cursor, end - self.cursor, &.{});
                return .changed;
            },
            .a => {
                if (!primary) return .unhandled;
                self.selectAll();
                return .moved;
            },
            .@"return", .kp_enter => {
                if (self.multiline and shift) {
                    _ = try self.insert(allocator, "\n");
                    return .changed;
                }
                return .submit;
            },
            .escape => return .cancel,
            else => return .unhandled,
        }
    }

    /// `handleKey` plus Ctrl/Cmd+C/X/V through the app clipboard. `state`
    /// provides `readClipboardTextForPaste() ?[]u8` (freed with
    /// `state.allocator`).
    pub fn handleKeyWithClipboard(self: *Field, state: anytype, key: sdl.Keycode, mod: sdl.Keymod) !KeyResult {
        if (isPrimary(mod)) switch (key) {
            .c, .x => {
                const selected = self.selectedText();
                if (selected.len == 0) return .moved;
                copyText(state.allocator, selected);
                if (key == .x) {
                    _ = self.deleteSelection();
                    return .changed;
                }
                return .moved;
            },
            .v => {
                const pasted = state.readClipboardTextForPaste() orelse return .moved;
                defer state.allocator.free(pasted);
                return if (try self.insert(state.allocator, pasted)) .changed else .moved;
            },
            else => {},
        };
        return self.handleKey(state.allocator, key, mod);
    }
};

pub fn copyText(allocator: std.mem.Allocator, text: []const u8) void {
    const terminated = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(terminated);
    sdl.setClipboardText(terminated) catch {};
}

/// Modifier bits of an SDL event (`sdl.Keymod` is a field-less enum whose
/// masks are declarations, so the raw value is read through a pointer).
pub fn modBits(mod: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&mod)).*;
}

pub fn isPrimary(mod: sdl.Keymod) bool {
    return (modBits(mod) & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
}

pub fn isShift(mod: sdl.Keymod) bool {
    return (modBits(mod) & sdl.Keymod.shift) != 0;
}

/// Byte offset in `text` closest to `x`, given a prefix-width measure
/// (`measure(text, end)` returns the width of `text[0..end]`).
pub fn offsetAtX(text: []const u8, x: f32, context: anytype, comptime measure: fn (@TypeOf(context), []const u8, usize) f32) usize {
    if (x <= 0) return 0;
    var previous: usize = 0;
    var previous_w: f32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const next = nextBoundary(text, index);
        const width = measure(context, text, next);
        if (width >= x) {
            return if (x - previous_w <= width - x) previous else next;
        }
        previous = next;
        previous_w = width;
        index = next;
    }
    return text.len;
}

pub fn prevBoundary(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var index = @min(offset, text.len) - 1;
    while (index > 0 and (text[index] & 0xC0) == 0x80) index -= 1;
    return index;
}

pub fn nextBoundary(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return @min(offset + length, text.len);
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

fn wordLeft(text: []const u8, offset: usize) usize {
    var index = @min(offset, text.len);
    while (index > 0 and !isWordByte(text[index - 1])) index -= 1;
    while (index > 0 and isWordByte(text[index - 1])) index -= 1;
    return index;
}

fn wordRight(text: []const u8, offset: usize) usize {
    var index = @min(offset, text.len);
    while (index < text.len and !isWordByte(text[index])) index += 1;
    while (index < text.len and isWordByte(text[index])) index += 1;
    return index;
}

pub fn lineStart(text: []const u8, offset: usize) usize {
    var index = @min(offset, text.len);
    while (index > 0 and text[index - 1] != '\n') index -= 1;
    return index;
}

pub fn lineEnd(text: []const u8, offset: usize) usize {
    var index = @min(offset, text.len);
    while (index < text.len and text[index] != '\n') index += 1;
    return index;
}

/// Same column (in bytes, clamped to a boundary) on the previous/next
/// logical line; null at the first/last line.
fn verticalLogical(text: []const u8, offset: usize, down: bool) ?usize {
    const start = lineStart(text, offset);
    const column = offset - start;
    if (down) {
        const end = lineEnd(text, offset);
        if (end >= text.len) return null;
        const next_start = end + 1;
        const next_end = lineEnd(text, next_start);
        return clampToBoundary(text, @min(next_start + column, next_end));
    }
    if (start == 0) return null;
    const previous_start = lineStart(text, start - 1);
    return clampToBoundary(text, @min(previous_start + column, start - 1));
}

fn clampToBoundary(text: []const u8, offset: usize) usize {
    var index = @min(offset, text.len);
    while (index > 0 and index < text.len and (text[index] & 0xC0) == 0x80) index -= 1;
    return index;
}

fn utf8ValidPrefix(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return bytes[0..index];
        if (index + length > bytes.len) return bytes[0..index];
        _ = std.unicode.utf8Decode(bytes[index .. index + length]) catch return bytes[0..index];
        index += length;
    }
    return bytes;
}

const testing = std.testing;
const no_mod: u16 = 0;
const shift_mod: u16 = sdl.Keymod.lshift;
const ctrl_mod: u16 = sdl.Keymod.lctrl;

test "single-line insert strips control characters and replaces the selection" {
    var field: Field = .{};
    defer field.deinit(testing.allocator);
    _ = try field.insert(testing.allocator, "ab\x01c\nd\te");
    try testing.expectEqualStrings("abc d e", field.value());
    field.anchor = 0;
    field.cursor = 3;
    _ = try field.insert(testing.allocator, "X");
    try testing.expectEqualStrings("X d e", field.value());
    try testing.expectEqual(@as(usize, 1), field.cursor);
}

test "caret moves by codepoint and word, and shift extends" {
    var field: Field = .{};
    defer field.deinit(testing.allocator);
    _ = try field.insert(testing.allocator, "héllo wörld");
    _ = try field.handleKeyBits(testing.allocator, .left, no_mod);
    try testing.expectEqual(field.value().len - 1, field.cursor);
    _ = try field.handleKeyBits(testing.allocator, .left, ctrl_mod);
    try testing.expectEqual(@as(usize, 7), field.cursor);
    _ = try field.handleKeyBits(testing.allocator, .home, shift_mod);
    try testing.expectEqualStrings("héllo ", field.selectedText());
    _ = try field.handleKeyBits(testing.allocator, .backspace, no_mod);
    try testing.expectEqualStrings("wörld", field.value());
    _ = try field.handleKeyBits(testing.allocator, .delete, ctrl_mod);
    try testing.expectEqualStrings("", field.value());
}

test "multi-line fields keep newlines and Shift+Enter inserts one" {
    var field: Field = .{ .multiline = true };
    defer field.deinit(testing.allocator);
    _ = try field.insert(testing.allocator, "one\r\ntwo");
    try testing.expectEqualStrings("one\ntwo", field.value());
    try testing.expectEqual(KeyResult.changed, try field.handleKeyBits(testing.allocator, .@"return", shift_mod));
    try testing.expectEqual(KeyResult.submit, try field.handleKeyBits(testing.allocator, .@"return", no_mod));
    // Caret at column 0 of the empty third line; Up keeps column 0.
    _ = try field.handleKeyBits(testing.allocator, .up, no_mod);
    try testing.expectEqual(@as(usize, 4), field.cursor);
    field.moveTo(7, false);
    _ = try field.handleKeyBits(testing.allocator, .up, no_mod);
    try testing.expectEqual(@as(usize, 3), field.cursor);
    field.selectLineAt(1);
    try testing.expectEqualStrings("one", field.selectedText());
}

test "insert respects the byte cap at a codepoint boundary" {
    var field: Field = .{ .max_bytes = 4 };
    defer field.deinit(testing.allocator);
    _ = try field.insert(testing.allocator, "abé€");
    try testing.expectEqualStrings("abé", field.value());
}

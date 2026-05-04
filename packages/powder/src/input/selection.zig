//! Shared text selection and byte-offset helpers.

const Self = @This();
const std = @import("std");

anchor: ?usize = null,
focus: ?usize = null,

pub const Range = struct {
    start: usize,
    end: usize,
};

pub fn normalized(self: Self, text_len: usize) ?Range {
    const anchor = @min(self.anchor orelse return null, text_len);
    const focus = @min(self.focus orelse return null, text_len);
    if (anchor == focus) return null;
    return if (anchor < focus)
        .{ .start = anchor, .end = focus }
    else
        .{ .start = focus, .end = anchor };
}

pub fn clear(self: *Self) void {
    self.anchor = null;
    self.focus = null;
}

pub fn clamp(self: *Self, text_len: usize) void {
    if (self.anchor) |anchor| self.anchor = @min(anchor, text_len);
    if (self.focus) |focus| self.focus = @min(focus, text_len);
}

pub fn selectAll(self: *Self, text_len: usize) void {
    self.anchor = 0;
    self.focus = text_len;
}

pub fn extendFrom(self: *Self, anchor: usize, focus: usize) void {
    if (self.anchor == null) self.anchor = anchor;
    self.focus = focus;
}

pub fn selectRange(self: *Self, range: Range) void {
    self.anchor = range.start;
    self.focus = range.end;
}

pub fn previousOffset(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var cursor = offset - 1;
    while (cursor > 0 and (text[cursor] & 0b1100_0000) == 0b1000_0000) {
        cursor -= 1;
    }
    return cursor;
}

pub fn nextOffset(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return @min(offset + len, text.len);
}

pub fn lineStart(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and text[cursor - 1] != '\n') cursor -= 1;
    return cursor;
}

pub fn lineEnd(text: []const u8, offset: usize) usize {
    return std.mem.findScalarPos(u8, text, @min(offset, text.len), '\n') orelse text.len;
}

pub fn previousWordOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and !isWordByte(text[cursor - 1])) cursor -= 1;
    while (cursor > 0 and isWordByte(text[cursor - 1])) cursor -= 1;
    return cursor;
}

pub fn nextWordOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor < text.len and isWordByte(text[cursor])) cursor += 1;
    while (cursor < text.len and !isWordByte(text[cursor])) cursor += 1;
    return cursor;
}

pub fn wordRangeAt(text: []const u8, offset: usize) Range {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    var cursor = @min(offset, text.len - 1);
    if (!isWordByte(text[cursor]) and cursor > 0 and isWordByte(text[cursor - 1])) cursor -= 1;
    if (!isWordByte(text[cursor])) return .{ .start = cursor, .end = @min(cursor + 1, text.len) };
    var start = cursor;
    while (start > 0 and isWordByte(text[start - 1])) start -= 1;
    var end = cursor;
    while (end < text.len and isWordByte(text[end])) end += 1;
    return .{ .start = start, .end = end };
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "selection normalizes and clamps ranges" {
    var state: Self = .{ .anchor = 8, .focus = 2 };
    try std.testing.expectEqual(Range{ .start = 2, .end = 8 }, state.normalized(20).?);
    try std.testing.expectEqual(Range{ .start = 2, .end = 5 }, state.normalized(5).?);
    state.clamp(4);
    try std.testing.expectEqual(Range{ .start = 2, .end = 4 }, state.normalized(20).?);
}

test "word range selects adjacent word at boundary" {
    try std.testing.expectEqualStrings("world", "hello world"[wordRangeAt("hello world", 11).start..wordRangeAt("hello world", 11).end]);
}

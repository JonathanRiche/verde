//! Public markdown parsing API for reusable thread rendering.

const std = @import("std");
const model = @import("model.zig");
const parser = @import("parser.zig");

pub const Allocator = std.mem.Allocator;
pub const Block = model.Block;
pub const BlockKind = model.BlockKind;
pub const Document = model.Document;
pub const FencedCodeBlock = model.FencedCodeBlock;
pub const Fence = model.Fence;
pub const Paragraph = model.Paragraph;
pub const Parser = parser.Parser;
pub const Span = model.Span;

pub fn parse(allocator: Allocator, source: []const u8) !Document {
    return parser.parseDocument(allocator, source);
}

pub fn fenceLanguage(info: []const u8) ?[]const u8 {
    return parser.fenceLanguage(info);
}

test "parses paragraphs, blank lines, and fenced code blocks" {
    const allocator = std.testing.allocator;
    const source =
        \\first paragraph line one
        \\first paragraph line two
        \\
        \\```zig
        \\const answer = 42;
        \\```
        \\
        \\second paragraph
    ;

    var document = try parse(allocator, source);
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), document.blockCount());

    const first = document.blockAt(0);
    try std.testing.expectEqual(BlockKind.paragraph, first.kind());
    switch (first) {
        .paragraph => |paragraph| {
            try std.testing.expectEqualStrings("first paragraph line one\nfirst paragraph line two", paragraph.text);
            try std.testing.expectEqual(@as(usize, 1), paragraph.span.start_line);
            try std.testing.expectEqual(@as(usize, 2), paragraph.span.end_line);
        },
        else => unreachable,
    }

    const blank = document.blockAt(1);
    try std.testing.expectEqual(BlockKind.blank, blank.kind());
    switch (blank) {
        .blank => |span| try std.testing.expectEqual(@as(usize, 3), span.start_line),
        else => unreachable,
    }

    const code = document.blockAt(2);
    try std.testing.expectEqual(BlockKind.fenced_code, code.kind());
    switch (code) {
        .fenced_code => |fenced_code| {
            try std.testing.expectEqualStrings("zig", fenced_code.language.?);
            try std.testing.expectEqualStrings("const answer = 42;\n", fenced_code.code);
            try std.testing.expectEqual(@as(u8, '`'), fenced_code.fence.marker);
            try std.testing.expectEqual(@as(usize, 3), fenced_code.fence.length);
        },
        else => unreachable,
    }
}

test "extracts the fenced code language from info text" {
    const allocator = std.testing.allocator;
    const source =
        \\~~~tsx custom-info
        \\<Button />
        \\~~~
    ;

    var document = try parse(allocator, source);
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), document.blockCount());

    const code = document.blockAt(0);
    try std.testing.expectEqual(BlockKind.fenced_code, code.kind());
    switch (code) {
        .fenced_code => |fenced_code| {
            try std.testing.expectEqualStrings("tsx custom-info", fenced_code.info);
            try std.testing.expectEqualStrings("tsx", fenced_code.language.?);
            try std.testing.expectEqualStrings("<Button />\n", fenced_code.code);
            try std.testing.expectEqual(@as(u8, '~'), fenced_code.fence.marker);
        },
        else => unreachable,
    }
}

test "extracts the first fenced code language token" {
    try std.testing.expectEqualStrings("zig", fenceLanguage("zig  async preview").?);
    try std.testing.expect(fenceLanguage("   ") == null);
}

test "keeps soft wrapped paragraph lines together" {
    const allocator = std.testing.allocator;
    const source =
        \\one line
        \\two line
        \\
        \\tail
    ;

    var document = try parse(allocator, source);
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), document.blockCount());

    const paragraph = document.blockAt(0);
    try std.testing.expectEqual(BlockKind.paragraph, paragraph.kind());
    switch (paragraph) {
        .paragraph => |value| try std.testing.expectEqualStrings("one line\ntwo line", value.text),
        else => unreachable,
    }

    const tail = document.blockAt(2);
    try std.testing.expectEqual(BlockKind.paragraph, tail.kind());
    switch (tail) {
        .paragraph => |value| try std.testing.expectEqualStrings("tail", value.text),
        else => unreachable,
    }
}

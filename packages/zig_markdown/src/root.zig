//! Public markdown parsing API for reusable thread rendering.

const std = @import("std");
const model = @import("model.zig");
const parser = @import("parser.zig");

pub const Allocator = std.mem.Allocator;
pub const Block = model.Block;
pub const BlockKind = model.BlockKind;
pub const BlockQuote = model.BlockQuote;
pub const CodeInline = model.CodeInline;
pub const ContainerInline = model.ContainerInline;
pub const Document = model.Document;
pub const FencedCodeBlock = model.FencedCodeBlock;
pub const Fence = model.Fence;
pub const Heading = model.Heading;
pub const Inline = model.Inline;
pub const InlineKind = model.InlineKind;
pub const LineBreakKind = model.LineBreakKind;
pub const LinkInline = model.LinkInline;
pub const ListBlock = model.ListBlock;
pub const ListItem = model.ListItem;
pub const ListKind = model.ListKind;
pub const Paragraph = model.Paragraph;
pub const Parser = parser.Parser;
pub const Span = model.Span;
pub const TableAlignment = model.TableAlignment;
pub const TableBlock = model.TableBlock;
pub const TableCell = model.TableCell;
pub const TableRow = model.TableRow;
pub const TextInline = model.TextInline;

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
            try std.testing.expectEqual(@as(usize, 3), paragraph.inlines.len);
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

test "parses headings, thematic breaks, block quotes, and lists" {
    const allocator = std.testing.allocator;
    const source =
        \\## Title
        \\
        \\---
        \\
        \\> quoted
        \\> still quoted
        \\
        \\- alpha
        \\- beta
        \\1. one
        \\2. two
    ;

    var document = try parse(allocator, source);
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8), document.blockCount());

    switch (document.blockAt(0)) {
        .heading => |heading| {
            try std.testing.expectEqual(@as(u8, 2), heading.level);
            try std.testing.expectEqualStrings("Title", heading.text);
        },
        else => unreachable,
    }

    try std.testing.expectEqual(BlockKind.thematic_break, document.blockAt(2).kind());

    switch (document.blockAt(4)) {
        .block_quote => |quote| {
            try std.testing.expectEqual(@as(usize, 1), quote.blocks.len);
            try std.testing.expectEqual(BlockKind.paragraph, quote.blocks[0].kind());
        },
        else => unreachable,
    }

    switch (document.blockAt(6)) {
        .list => |list| {
            try std.testing.expectEqual(ListKind.unordered, list.kind);
            try std.testing.expectEqual(@as(usize, 2), list.items.len);
        },
        else => unreachable,
    }

    switch (document.blockAt(7)) {
        .list => |list| {
            try std.testing.expectEqual(ListKind.ordered, list.kind);
            try std.testing.expectEqual(@as(usize, 1), list.start_number);
            try std.testing.expectEqual(@as(usize, 2), list.items.len);
        },
        else => unreachable,
    }
}

test "parses inline emphasis, strong, code, links, and line breaks" {
    const allocator = std.testing.allocator;
    const source = "plain *em* **strong** `code` [label](dest)\nnext";

    var document = try parse(allocator, source);
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), document.blockCount());

    switch (document.blockAt(0)) {
        .paragraph => |paragraph| {
            try std.testing.expectEqual(@as(usize, 10), paragraph.inlines.len);
            try std.testing.expectEqual(InlineKind.emphasis, paragraph.inlines[1].kind());
            try std.testing.expectEqual(InlineKind.strong, paragraph.inlines[3].kind());
            try std.testing.expectEqual(InlineKind.code, paragraph.inlines[5].kind());
            try std.testing.expectEqual(InlineKind.link, paragraph.inlines[7].kind());
            try std.testing.expectEqual(InlineKind.line_break, paragraph.inlines[8].kind());
        },
        else => unreachable,
    }
}

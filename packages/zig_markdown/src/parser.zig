//! Markdown parsing for thread bodies and reusable renderers.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const Parser = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn parse(self: Self, allocator: Allocator, source: []const u8) !model.Document {
        _ = self;
        return parseDocument(allocator, source);
    }
};

const Line = struct {
    start: usize,
    end: usize,
    number: usize,
    text: []const u8,
};

const FenceOpen = struct {
    fence: model.Fence,
    info: []const u8,
};

const ParseResult = struct {
    block: model.Block,
    next_index: usize,
};

const ListMarker = struct {
    kind: model.ListKind,
    delimiter: u8,
    bullet: u8,
    start_number: usize,
    content: []const u8,
};

pub fn parseDocument(allocator: Allocator, source: []const u8) Allocator.Error!model.Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    const lines = try collectLines(arena_allocator, source);
    var index: usize = 0;
    const blocks = try parseBlocks(arena_allocator, source, lines, &index);

    return .{
        .source = source,
        .arena = arena,
        .blocks = blocks,
    };
}

fn parseBlocks(
    allocator: Allocator,
    source: []const u8,
    lines: []const Line,
    index: *usize,
) Allocator.Error![]model.Block {
    var blocks: std.ArrayListUnmanaged(model.Block) = .empty;

    while (index.* < lines.len) {
        const line = lines[index.*];

        if (isBlank(line.text)) {
            try blocks.append(allocator, .{
                .blank = makeSpan(line.number, line.number, line.start, line.end),
            });
            index.* += 1;
            continue;
        }

        if (parseFencedCodeBlock(source, lines, index)) |result| {
            try blocks.append(allocator, result.block);
            continue;
        }

        if (try parseHeadingBlock(allocator, lines, index)) |result| {
            try blocks.append(allocator, result.block);
            continue;
        }

        if (parseThematicBreakBlock(lines, index)) |result| {
            try blocks.append(allocator, result.block);
            continue;
        }

        if (try parseBlockQuoteBlock(allocator, lines, index)) |result| {
            try blocks.append(allocator, result.block);
            continue;
        }

        if (try parseListBlock(allocator, lines, index)) |result| {
            try blocks.append(allocator, result.block);
            continue;
        }

        const result = try parseParagraphBlock(allocator, source, lines, index);
        try blocks.append(allocator, result.block);
    }

    return try blocks.toOwnedSlice(allocator);
}

fn parseFencedCodeBlock(source: []const u8, lines: []const Line, index: *usize) ?ParseResult {
    const opening_line = lines[index.*];
    const open = parseOpeningFence(opening_line.text) orelse return null;

    var scan = index.* + 1;
    var closing_line: ?Line = null;
    while (scan < lines.len) : (scan += 1) {
        if (isClosingFence(lines[scan].text, open.fence)) {
            closing_line = lines[scan];
            break;
        }
    }

    const last_line = closing_line orelse lines[lines.len - 1];
    const content_start = if (index.* + 1 < lines.len) lines[index.* + 1].start else source.len;
    const content_end = if (closing_line) |line| line.start else source.len;
    const next_index = if (closing_line != null) scan + 1 else lines.len;

    index.* = next_index;
    return .{
        .block = .{
            .fenced_code = .{
                .span = makeSpan(opening_line.number, last_line.number, opening_line.start, last_line.end),
                .fence = open.fence,
                .info = open.info,
                .language = fenceLanguage(open.info),
                .code = source[content_start..content_end],
            },
        },
        .next_index = next_index,
    };
}

fn parseHeadingBlock(
    allocator: Allocator,
    lines: []const Line,
    index: *usize,
) Allocator.Error!?ParseResult {
    const line = lines[index.*];
    const trimmed = trimMarkdownIndent(line.text) orelse return null;

    var level: u8 = 0;
    while (level < trimmed.len and level < 6 and trimmed[level] == '#') : (level += 1) {}
    if (level == 0) return null;
    if (level >= trimmed.len) {
        const inlines = try parseInlines(allocator, "");
        index.* += 1;
        return .{
            .block = .{
                .heading = .{
                    .span = makeSpan(line.number, line.number, line.start, line.end),
                    .level = level,
                    .text = "",
                    .inlines = inlines,
                },
            },
            .next_index = index.*,
        };
    }
    if (trimmed[level] != ' ' and trimmed[level] != '\t') return null;

    const content = trimHeadingContent(trimmed[level..]);
    const inlines = try parseInlines(allocator, content);
    index.* += 1;
    return .{
        .block = .{
            .heading = .{
                .span = makeSpan(line.number, line.number, line.start, line.end),
                .level = level,
                .text = content,
                .inlines = inlines,
            },
        },
        .next_index = index.*,
    };
}

fn parseThematicBreakBlock(lines: []const Line, index: *usize) ?ParseResult {
    const line = lines[index.*];
    if (!isThematicBreak(line.text)) return null;

    index.* += 1;
    return .{
        .block = .{
            .thematic_break = makeSpan(line.number, line.number, line.start, line.end),
        },
        .next_index = index.*,
    };
}

fn parseBlockQuoteBlock(
    allocator: Allocator,
    lines: []const Line,
    index: *usize,
) Allocator.Error!?ParseResult {
    const first_content = stripBlockQuoteMarker(lines[index.*].text) orelse return null;

    var content: std.ArrayListUnmanaged(u8) = .empty;
    var scan = index.*;
    var last_line = lines[index.*];

    while (scan < lines.len) : (scan += 1) {
        const line = lines[scan];
        const quote_content = stripBlockQuoteMarker(line.text) orelse break;
        if (content.items.len > 0) try content.append(allocator, '\n');
        try content.appendSlice(allocator, quote_content);
        last_line = line;
    }

    _ = first_content;
    const inner_source = try content.toOwnedSlice(allocator);
    var nested_index: usize = 0;
    const nested_lines = try collectLines(allocator, inner_source);
    const blocks = try parseBlocks(allocator, inner_source, nested_lines, &nested_index);

    const start_line = lines[index.*].number;
    const start_byte = lines[index.*].start;
    index.* = scan;
    return .{
        .block = .{
            .block_quote = .{
                .span = makeSpan(start_line, last_line.number, start_byte, last_line.end),
                .blocks = blocks,
            },
        },
        .next_index = scan,
    };
}

fn parseListBlock(
    allocator: Allocator,
    lines: []const Line,
    index: *usize,
) Allocator.Error!?ParseResult {
    const first_marker = parseListMarker(lines[index.*].text) orelse return null;

    var items: std.ArrayListUnmanaged(model.ListItem) = .empty;
    var scan = index.*;
    var loose = false;
    var last_line = lines[index.*];

    while (scan < lines.len) {
        if (isBlank(lines[scan].text)) {
            if (scan + 1 < lines.len and parseListMarker(lines[scan + 1].text) != null) {
                loose = true;
                scan += 1;
                continue;
            }
            break;
        }

        const marker = parseListMarker(lines[scan].text) orelse break;
        if (!sameListFamily(first_marker, marker)) break;

        const item_start = lines[scan];
        var item_source: std.ArrayListUnmanaged(u8) = .empty;
        if (marker.content.len > 0) try item_source.appendSlice(allocator, marker.content);

        var item_end = scan + 1;
        var item_last_line = item_start;

        while (item_end < lines.len) : (item_end += 1) {
            const continuation = lines[item_end];
            if (isBlank(continuation.text)) {
                if (item_end + 1 < lines.len) {
                    if (parseListMarker(lines[item_end + 1].text)) |next_marker| {
                        if (sameListFamily(first_marker, next_marker)) {
                            loose = true;
                            break;
                        }
                    }
                }
                break;
            }

            if (parseListMarker(continuation.text)) |_| {
                break;
            }

            if (item_source.items.len > 0) try item_source.append(allocator, '\n');
            try item_source.appendSlice(allocator, std.mem.trimStart(u8, continuation.text, " \t"));
            item_last_line = continuation;
        }

        const normalized = try item_source.toOwnedSlice(allocator);
        const nested_lines = try collectLines(allocator, normalized);
        var nested_index: usize = 0;
        const nested_blocks = try parseBlocks(allocator, normalized, nested_lines, &nested_index);

        try items.append(allocator, .{
            .span = makeSpan(item_start.number, item_last_line.number, item_start.start, item_last_line.end),
            .blocks = nested_blocks,
        });

        last_line = item_last_line;
        scan = item_end;
        if (scan < lines.len and isBlank(lines[scan].text) and scan + 1 < lines.len and parseListMarker(lines[scan + 1].text) != null) {
            continue;
        }
    }

    if (items.items.len == 0) return null;

    const first_line = lines[index.*];
    index.* = scan;
    return .{
        .block = .{
            .list = .{
                .span = makeSpan(first_line.number, last_line.number, first_line.start, last_line.end),
                .kind = first_marker.kind,
                .start_number = first_marker.start_number,
                .items = try items.toOwnedSlice(allocator),
                .loose = loose,
            },
        },
        .next_index = scan,
    };
}

fn parseParagraphBlock(
    allocator: Allocator,
    source: []const u8,
    lines: []const Line,
    index: *usize,
) Allocator.Error!ParseResult {
    const start = lines[index.*];
    var end_index = index.* + 1;
    var last_line = start;

    while (end_index < lines.len) : (end_index += 1) {
        const line = lines[end_index];
        if (isBlank(line.text)) break;
        if (isParagraphTerminator(line.text)) break;
        last_line = line;
    }

    const text = source[start.start..last_line.end];
    const inlines = try parseInlines(allocator, text);
    index.* = end_index;
    return .{
        .block = .{
            .paragraph = .{
                .span = makeSpan(start.number, last_line.number, start.start, last_line.end),
                .text = text,
                .inlines = inlines,
            },
        },
        .next_index = end_index,
    };
}

pub fn fenceLanguage(info: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, info, " \t");
    return tokens.next();
}

fn parseOpeningFence(line: []const u8) ?FenceOpen {
    const stripped = trimMarkdownIndent(line) orelse return null;
    if (stripped.len < 3) return null;

    const marker = stripped[0];
    if (marker != '`' and marker != '~') return null;

    var length: usize = 0;
    while (length < stripped.len and stripped[length] == marker) : (length += 1) {}
    if (length < 3) return null;

    const info = std.mem.trimStart(u8, stripped[length..], " \t");
    return .{
        .fence = .{
            .marker = marker,
            .length = length,
        },
        .info = info,
    };
}

fn isClosingFence(line: []const u8, fence: model.Fence) bool {
    const stripped = trimMarkdownIndent(line) orelse return false;
    if (stripped.len < fence.length) return false;
    if (stripped[0] != fence.marker) return false;

    var length: usize = 0;
    while (length < stripped.len and stripped[length] == fence.marker) : (length += 1) {}
    if (length < fence.length) return false;

    return std.mem.trimStart(u8, stripped[length..], " \t").len == 0;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn collectLines(allocator: Allocator, source: []const u8) Allocator.Error![]const Line {
    var lines: std.ArrayListUnmanaged(Line) = .empty;

    var start: usize = 0;
    var line_number: usize = 1;
    while (start < source.len) {
        var end = start;
        while (end < source.len and source[end] != '\n') : (end += 1) {}

        var text_end = end;
        if (text_end > start and source[text_end - 1] == '\r') {
            text_end -= 1;
        }

        try lines.append(allocator, .{
            .start = start,
            .end = text_end,
            .number = line_number,
            .text = source[start..text_end],
        });

        start = if (end < source.len) end + 1 else end;
        line_number += 1;
    }

    if (source.len == 0) {
        return try allocator.dupe(Line, &[_]Line{});
    }

    return try lines.toOwnedSlice(allocator);
}

fn makeSpan(start_line: usize, end_line: usize, start_byte: usize, end_byte: usize) model.Span {
    return .{
        .start_line = start_line,
        .end_line = end_line,
        .start_byte = start_byte,
        .end_byte = end_byte,
    };
}

fn trimMarkdownIndent(line: []const u8) ?[]const u8 {
    var spaces: usize = 0;
    while (spaces < line.len and spaces < 4 and line[spaces] == ' ') : (spaces += 1) {}
    if (spaces > 3) return null;
    if (spaces < line.len and line[spaces] == '\t') return null;
    return line[spaces..];
}

fn trimHeadingContent(content: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, content, " \t");
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '#') {
        trimmed = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }
    return trimmed;
}

fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;

    var marker: ?u8 = null;
    var count: usize = 0;
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (marker == null) {
            marker = byte;
        } else if (marker.? != byte) {
            return false;
        }
        count += 1;
    }
    return count >= 3;
}

fn stripBlockQuoteMarker(line: []const u8) ?[]const u8 {
    const trimmed = trimMarkdownIndent(line) orelse return null;
    if (trimmed.len == 0 or trimmed[0] != '>') return null;
    return std.mem.trimStart(u8, trimmed[1..], " \t");
}

fn parseListMarker(line: []const u8) ?ListMarker {
    const trimmed = trimMarkdownIndent(line) orelse return null;
    if (trimmed.len < 2) return null;

    if (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') {
        if (trimmed[1] != ' ' and trimmed[1] != '\t') return null;
        return .{
            .kind = .unordered,
            .delimiter = 0,
            .bullet = trimmed[0],
            .start_number = 1,
            .content = std.mem.trimStart(u8, trimmed[1..], " \t"),
        };
    }

    var digits_end: usize = 0;
    while (digits_end < trimmed.len and std.ascii.isDigit(trimmed[digits_end])) : (digits_end += 1) {}
    if (digits_end == 0 or digits_end + 1 >= trimmed.len) return null;

    const delimiter = trimmed[digits_end];
    if (delimiter != '.' and delimiter != ')') return null;
    if (trimmed[digits_end + 1] != ' ' and trimmed[digits_end + 1] != '\t') return null;

    return .{
        .kind = .ordered,
        .delimiter = delimiter,
        .bullet = 0,
        .start_number = std.fmt.parseUnsigned(usize, trimmed[0..digits_end], 10) catch return null,
        .content = std.mem.trimStart(u8, trimmed[digits_end + 1 ..], " \t"),
    };
}

fn sameListFamily(left: ListMarker, right: ListMarker) bool {
    if (left.kind != right.kind) return false;
    if (left.kind == .ordered) return true;
    return true;
}

fn isParagraphTerminator(line: []const u8) bool {
    if (parseOpeningFence(line) != null) return true;
    if (trimMarkdownIndent(line)) |trimmed| {
        if (trimmed.len > 0 and trimmed[0] == '>') return true;
        if (isThematicBreak(line)) return true;
        if (parseListMarker(line) != null) return true;

        var hashes: usize = 0;
        while (hashes < trimmed.len and hashes < 6 and trimmed[hashes] == '#') : (hashes += 1) {}
        if (hashes > 0 and (hashes == trimmed.len or trimmed[hashes] == ' ' or trimmed[hashes] == '\t')) {
            return true;
        }
    }
    return false;
}

fn parseNestedBlocks(allocator: Allocator, source: []const u8) ![]model.Block {
    const lines = try collectLines(allocator, source);
    var index: usize = 0;
    return parseBlocks(allocator, source, lines, &index);
}

fn parseInlines(allocator: Allocator, source: []const u8) Allocator.Error![]model.Inline {
    var inlines: std.ArrayListUnmanaged(model.Inline) = .empty;
    var text_start: usize = 0;
    var index: usize = 0;

    while (index < source.len) {
        switch (source[index]) {
            '\n' => {
                var text = source[text_start..index];
                var kind: model.LineBreakKind = .soft;
                if (text.len >= 2 and text[text.len - 1] == ' ' and text[text.len - 2] == ' ') {
                    text = text[0 .. text.len - 2];
                    kind = .hard;
                }
                try appendTextInline(allocator, &inlines, text);
                try inlines.append(allocator, .{ .line_break = kind });
                index += 1;
                text_start = index;
                continue;
            },
            '`' => {
                if (findCodeSpanEnd(source, index)) |end| {
                    try appendTextInline(allocator, &inlines, source[text_start..index]);
                    const ticks = countRun(source, index);
                    try inlines.append(allocator, .{
                        .code = .{
                            .text = source[index + ticks .. end],
                        },
                    });
                    index = end + ticks;
                    text_start = index;
                    continue;
                }
            },
            '[' => {
                if (try parseInlineLink(allocator, source, index)) |result| {
                    try appendTextInline(allocator, &inlines, source[text_start..index]);
                    try inlines.append(allocator, .{
                        .link = .{
                            .label = source[result.label_start..result.label_end],
                            .destination = source[result.destination_start..result.destination_end],
                            .children = result.children,
                        },
                    });
                    index = result.next_index;
                    text_start = index;
                    continue;
                }
            },
            '*', '_' => {
                if (try parseDelimitedInline(allocator, source, index)) |result| {
                    try appendTextInline(allocator, &inlines, source[text_start..index]);
                    try inlines.append(allocator, result.value);
                    index = result.next_index;
                    text_start = index;
                    continue;
                }
            },
            else => {},
        }

        index += 1;
    }

    try appendTextInline(allocator, &inlines, source[text_start..]);
    return try inlines.toOwnedSlice(allocator);
}

const InlineParseResult = struct {
    value: model.Inline,
    next_index: usize,
};

const InlineLinkResult = struct {
    label_start: usize,
    label_end: usize,
    destination_start: usize,
    destination_end: usize,
    children: []model.Inline,
    next_index: usize,
};

fn appendTextInline(
    allocator: Allocator,
    inlines: *std.ArrayListUnmanaged(model.Inline),
    text: []const u8,
) Allocator.Error!void {
    if (text.len == 0) return;
    try inlines.append(allocator, .{
        .text = .{
            .text = text,
        },
    });
}

fn countRun(source: []const u8, start: usize) usize {
    const marker = source[start];
    var count: usize = 0;
    while (start + count < source.len and source[start + count] == marker) : (count += 1) {}
    return count;
}

fn findCodeSpanEnd(source: []const u8, start: usize) ?usize {
    const ticks = countRun(source, start);
    var index = start + ticks;
    while (index < source.len) : (index += 1) {
        if (source[index] != '`') continue;
        const length = countRun(source, index);
        if (length == ticks) return index;
    }
    return null;
}

fn parseInlineLink(
    allocator: Allocator,
    source: []const u8,
    start: usize,
) Allocator.Error!?InlineLinkResult {
    const close_bracket = std.mem.indexOfScalarPos(u8, source, start + 1, ']') orelse return null;
    if (close_bracket + 1 >= source.len or source[close_bracket + 1] != '(') return null;

    const close_paren = std.mem.indexOfScalarPos(u8, source, close_bracket + 2, ')') orelse return null;
    const label_start = start + 1;
    const label_end = close_bracket;
    const destination_start = close_bracket + 2;
    const destination_end = close_paren;
    const children = try parseInlines(allocator, source[label_start..label_end]);

    return .{
        .label_start = label_start,
        .label_end = label_end,
        .destination_start = destination_start,
        .destination_end = destination_end,
        .children = children,
        .next_index = close_paren + 1,
    };
}

fn parseDelimitedInline(
    allocator: Allocator,
    source: []const u8,
    start: usize,
) Allocator.Error!?InlineParseResult {
    const marker = source[start];
    const run = countRun(source, start);
    const delimiter_length: usize = if (run >= 2) 2 else 1;
    const end = findClosingDelimiter(source, start + delimiter_length, marker, delimiter_length) orelse return null;
    if (end == start + delimiter_length) return null;

    const children = try parseInlines(allocator, source[start + delimiter_length .. end]);
    return .{
        .value = if (delimiter_length == 2)
            .{ .strong = .{ .children = children } }
        else
            .{ .emphasis = .{ .children = children } },
        .next_index = end + delimiter_length,
    };
}

fn findClosingDelimiter(source: []const u8, start: usize, marker: u8, length: usize) ?usize {
    var index = start;
    while (index + length <= source.len) : (index += 1) {
        var matches = true;
        var offset: usize = 0;
        while (offset < length) : (offset += 1) {
            if (source[index + offset] != marker) {
                matches = false;
                break;
            }
        }
        if (matches) return index;
    }
    return null;
}

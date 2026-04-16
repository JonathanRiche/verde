//! Line-oriented markdown parsing focused on thread bodies and fenced code.

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
    next: usize,
    number: usize,
    text: []const u8,
};

const FenceOpen = struct {
    fence: model.Fence,
    info: []const u8,
};

pub fn parseDocument(allocator: Allocator, source: []const u8) !model.Document {
    var blocks: std.ArrayList(model.Block) = .empty;
    errdefer blocks.deinit(allocator);

    var index: usize = 0;
    var line_number: usize = 1;
    var paragraph_start: ?Line = null;
    var paragraph_end: usize = 0;
    var paragraph_end_line: usize = 0;

    while (readLine(source, index, line_number)) |line| {
        index = line.next;
        line_number += 1;

        if (isBlank(line.text)) {
            try flushParagraph(allocator, source, &blocks, &paragraph_start, paragraph_end, paragraph_end_line);
            try blocks.append(allocator, .{
                .blank = .{
                    .start_line = line.number,
                    .end_line = line.number,
                    .start_byte = line.start,
                    .end_byte = line.end,
                },
            });
            continue;
        }

        if (parseOpeningFence(line.text)) |open| {
            try flushParagraph(allocator, source, &blocks, &paragraph_start, paragraph_end, paragraph_end_line);
            try parseFencedCode(allocator, source, &blocks, &index, &line_number, line, open);
            continue;
        }

        if (paragraph_start == null) {
            paragraph_start = line;
        }
        paragraph_end = line.end;
        paragraph_end_line = line.number;
    }

    try flushParagraph(allocator, source, &blocks, &paragraph_start, paragraph_end, paragraph_end_line);

    return .{
        .source = source,
        .blocks = try blocks.toOwnedSlice(allocator),
    };
}

fn flushParagraph(
    allocator: Allocator,
    source: []const u8,
    blocks: *std.ArrayList(model.Block),
    paragraph_start: *?Line,
    paragraph_end: usize,
    paragraph_end_line: usize,
) !void {
    const start = paragraph_start.* orelse return;
    paragraph_start.* = null;

    try blocks.append(allocator, .{
        .paragraph = .{
            .span = .{
                .start_line = start.number,
                .end_line = paragraph_end_line,
                .start_byte = start.start,
                .end_byte = paragraph_end,
            },
            .text = source[start.start..paragraph_end],
        },
    });
}

fn parseFencedCode(
    allocator: Allocator,
    source: []const u8,
    blocks: *std.ArrayList(model.Block),
    index: *usize,
    line_number: *usize,
    opening_line: Line,
    open: FenceOpen,
) !void {
    var scan_index = index.*;
    var scan_line_number = line_number.*;
    const content_start = scan_index;
    var content_end = source.len;
    var end_line = opening_line.number;

    while (readLine(source, scan_index, scan_line_number)) |line| {
        if (isClosingFence(line.text, open.fence)) {
            content_end = line.start;
            end_line = line.number;
            index.* = line.next;
            line_number.* = line.number + 1;
            try blocks.append(allocator, .{
                .fenced_code = .{
                    .span = .{
                        .start_line = opening_line.number,
                        .end_line = end_line,
                        .start_byte = opening_line.start,
                        .end_byte = line.end,
                    },
                    .fence = open.fence,
                    .info = open.info,
                    .language = fencedCodeLanguage(open.info),
                    .code = source[content_start..content_end],
                },
            });
            return;
        }

        scan_index = line.next;
        scan_line_number = line.number + 1;
        end_line = line.number;
    }

    index.* = source.len;
    line_number.* = scan_line_number;
    try blocks.append(allocator, .{
        .fenced_code = .{
            .span = .{
                .start_line = opening_line.number,
                .end_line = end_line,
                .start_byte = opening_line.start,
                .end_byte = source.len,
            },
            .fence = open.fence,
            .info = open.info,
            .language = fencedCodeLanguage(open.info),
            .code = source[content_start..content_end],
        },
    });
}

fn fencedCodeLanguage(info: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, info, " \t");
    return tokens.next();
}

fn parseOpeningFence(line: []const u8) ?FenceOpen {
    const stripped = std.mem.trimLeft(u8, line, " ");
    if (line.len - stripped.len > 3) return null;
    if (stripped.len < 3) return null;

    const marker = stripped[0];
    if (marker != '`' and marker != '~') return null;

    var length: usize = 0;
    while (length < stripped.len and stripped[length] == marker) : (length += 1) {}
    if (length < 3) return null;

    const info = std.mem.trimLeft(u8, stripped[length..], " \t");
    return .{
        .fence = .{
            .marker = marker,
            .length = length,
        },
        .info = info,
    };
}

fn isClosingFence(line: []const u8, fence: model.Fence) bool {
    const stripped = std.mem.trimLeft(u8, line, " ");
    if (line.len - stripped.len > 3) return false;
    if (stripped.len < fence.length) return false;
    if (stripped[0] != fence.marker) return false;

    var length: usize = 0;
    while (length < stripped.len and stripped[length] == fence.marker) : (length += 1) {}
    if (length < fence.length) return false;

    return std.mem.trimLeft(u8, stripped[length..], " \t").len == 0;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn readLine(source: []const u8, start: usize, number: usize) ?Line {
    if (start >= source.len) return null;

    var end = start;
    while (end < source.len and source[end] != '\n') : (end += 1) {}

    var text = source[start..end];
    if (text.len > 0 and text[text.len - 1] == '\r') {
        text = text[0 .. text.len - 1];
    }

    return .{
        .start = start,
        .end = end,
        .next = if (end < source.len) end + 1 else end,
        .number = number,
        .text = text,
    };
}

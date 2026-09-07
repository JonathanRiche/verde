//! Hold-back for mid-stream rendering. A reply arrives a few characters at a
//! time; some constructs flip appearance once more text lands (a table header
//! is a paragraph until its delimiter row exists, a partial row breaks the
//! table, a half-typed link shows its brackets, a bare `-` or `##` is a
//! paragraph until its content arrives). `streamingHoldLength` reports how
//! many trailing bytes to keep hidden so those flips never reach the screen;
//! the held text is released as soon as the construct resolves.
const std = @import("std");
const model = @import("model.zig");
const parser = @import("parser.zig");

/// Number of trailing bytes of `source` to hold back while streaming. Zero
/// when the tail renders stably as-is, and always zero inside an open fence
/// (code shows line by line without reinterpretation).
pub fn streamingHoldLength(source: []const u8) usize {
    if (source.len == 0) return 0;

    var open_fence: ?model.Fence = null;
    var line_start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, line_start, '\n')) |newline| {
        updateFence(&open_fence, source[line_start..newline]);
        line_start = newline + 1;
    }
    if (open_fence != null) return 0;

    const last_line = source[line_start..];
    var hold_start = source.len;
    if (last_line.len > 0) {
        if (holdsWholeLine(last_line)) {
            hold_start = line_start;
        } else if (unfinishedLinkOffset(last_line)) |offset| {
            hold_start = line_start + offset;
        }
    }
    // The last line is complete or fully held: a lone table header just
    // above it still waits for its delimiter row.
    if (hold_start == line_start) {
        hold_start = @min(hold_start, tableHeaderHoldStart(source, line_start));
    }
    return source.len - hold_start;
}

fn updateFence(open_fence: *?model.Fence, line: []const u8) void {
    if (open_fence.*) |fence| {
        if (parser.isClosingFence(line, fence)) open_fence.* = null;
    } else if (parser.parseOpeningFence(line)) |open| {
        open_fence.* = open.fence;
    }
}

fn stripQuotePrefix(line: []const u8) []const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    while (rest.len > 0 and rest[0] == '>') rest = std.mem.trimStart(u8, rest[1..], " \t");
    return rest;
}

/// A partial line whose whole content should wait: a table row in progress
/// (any pipe), or nothing but block markers so far (`##`, `-`, `1.`, ` ``` `).
fn holdsWholeLine(line: []const u8) bool {
    const raw = std.mem.trim(u8, line, " \t\r");
    if (raw.len == 0) return false;
    if (std.mem.indexOfScalar(u8, raw, '|') != null) return true;
    var only_markers = true;
    for (raw) |c| {
        if (std.mem.indexOfScalar(u8, "#-*+>`~=_ \t", c) == null) {
            only_markers = false;
            break;
        }
    }
    if (only_markers) return true;
    // Ordered-list marker with no item text yet: digits then optional `.`/`)`.
    const content = stripQuotePrefix(raw);
    var index: usize = 0;
    while (index < content.len and std.ascii.isDigit(content[index])) index += 1;
    if (index == 0 or index > 9) return false;
    if (index < content.len and (content[index] == '.' or content[index] == ')')) index += 1;
    return index == content.len;
}

/// Byte offset of an unfinished `[text](url` or `[text` at the tail of the
/// line, including a leading `!` for images. Null once it closes or when the
/// bracket turns out not to be a link.
fn unfinishedLinkOffset(line: []const u8) ?usize {
    const open = std.mem.lastIndexOfScalar(u8, line, '[') orelse return null;
    const start = if (open > 0 and line[open - 1] == '!') open - 1 else open;
    const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse return start;
    if (close + 1 >= line.len or line[close + 1] != '(') return null;
    if (std.mem.indexOfScalarPos(u8, line, close + 1, ')') != null) return null;
    return start;
}

fn isTableDelimiterRow(line: []const u8) bool {
    var trimmed = std.mem.trim(u8, stripQuotePrefix(line), " \t\r");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null) return false;
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];
    var cells = std.mem.splitScalar(u8, trimmed, '|');
    var count: usize = 0;
    while (cells.next()) |cell| {
        const inner = std.mem.trim(u8, cell, " \t");
        if (inner.len == 0) return false;
        const dash_start: usize = if (inner[0] == ':') 1 else 0;
        const dash_end: usize = if (inner[inner.len - 1] == ':') inner.len - 1 else inner.len;
        if (dash_end <= dash_start) return false;
        for (inner[dash_start..dash_end]) |c| if (c != '-') return false;
        count += 1;
    }
    return count > 0;
}

fn lineHasPipe(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

/// Start of a trailing complete line that is a table header still waiting
/// for its delimiter row; `end` otherwise. Complete lines occupy
/// `source[0..end]` and each ends with a newline.
fn tableHeaderHoldStart(source: []const u8, end: usize) usize {
    if (end == 0) return end;
    // Collect the run of trailing complete lines that contain a pipe.
    var run_starts: [2]usize = undefined;
    var run_len: usize = 0;
    var cursor = end;
    while (cursor > 0 and run_len < 2) {
        const line_end = cursor - 1; // index of the newline
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..line_end], '\n')) |nl| nl + 1 else 0;
        if (!lineHasPipe(source[line_start..line_end])) break;
        run_starts[run_len] = line_start;
        run_len += 1;
        cursor = line_start;
    }
    if (run_len != 1) return end;
    // One pipe line with nothing pipe-shaped above it. It is a header in
    // waiting unless it is itself a delimiter row (header already shown).
    const line = source[run_starts[0] .. end - 1];
    if (isTableDelimiterRow(line)) return end;
    return run_starts[0];
}

fn heldTail(source: []const u8) []const u8 {
    return source[source.len - streamingHoldLength(source) ..];
}

test "plain prose and complete blocks hold nothing" {
    try std.testing.expectEqual(@as(usize, 0), streamingHoldLength(""));
    try std.testing.expectEqual(@as(usize, 0), streamingHoldLength("Hello there, this is prose"));
    try std.testing.expectEqual(@as(usize, 0), streamingHoldLength("# Heading\n\nA paragraph.\n"));
    try std.testing.expectEqual(@as(usize, 0), streamingHoldLength("- item one\n- item two"));
    try std.testing.expectEqual(@as(usize, 0), streamingHoldLength("1. first\n2. second item"));
}

test "table header waits for its delimiter row, then rows stream by line" {
    try std.testing.expectEqualStrings("| a | b |", heldTail("intro\n| a | b |"));
    try std.testing.expectEqualStrings("| a | b |\n", heldTail("intro\n| a | b |\n"));
    try std.testing.expectEqualStrings("| a | b |\n|--", heldTail("intro\n| a | b |\n|--"));
    try std.testing.expectEqualStrings("", heldTail("intro\n| a | b |\n|---|---|\n"));
    try std.testing.expectEqualStrings("| 1 | ", heldTail("| a | b |\n|---|---|\n| 1 | "));
    try std.testing.expectEqualStrings("", heldTail("| a | b |\n|---|---|\n| 1 | 2 |\n"));
    try std.testing.expectEqualStrings("| 3", heldTail("| a | b |\n|---|---|\n| 1 | 2 |\n| 3"));
    // Prose with a pipe is released once the next line proves it is not a header.
    try std.testing.expectEqualStrings("", heldTail("run a | b\nthen more\n"));
    try std.testing.expectEqualStrings("", heldTail("run a | b\nthen more"));
}

test "bare block markers wait for their content" {
    try std.testing.expectEqualStrings("#", heldTail("text\n#"));
    try std.testing.expectEqualStrings("## ", heldTail("text\n## "));
    try std.testing.expectEqualStrings("", heldTail("text\n## T"));
    try std.testing.expectEqualStrings("-", heldTail("text\n-"));
    try std.testing.expectEqualStrings("", heldTail("text\n- x"));
    try std.testing.expectEqualStrings("12.", heldTail("text\n12."));
    try std.testing.expectEqualStrings("``", heldTail("text\n``"));
    try std.testing.expectEqualStrings("> ", heldTail("text\n> "));
    try std.testing.expectEqualStrings("---", heldTail("Title\n---"));
    try std.testing.expectEqualStrings("", heldTail("Title\n---\n"));
    try std.testing.expectEqualStrings("", heldTail("2024 was"));
}

test "unfinished links hold from the bracket" {
    try std.testing.expectEqualStrings("[docs", heldTail("see [docs"));
    try std.testing.expectEqualStrings("[docs](https://x", heldTail("see [docs](https://x"));
    try std.testing.expectEqualStrings("", heldTail("see [docs](https://x/y) now"));
    try std.testing.expectEqualStrings("![shot](a.pn", heldTail("look ![shot](a.pn"));
    try std.testing.expectEqualStrings("", heldTail("arr[0] is"));
    try std.testing.expectEqualStrings("", heldTail("- [ ] todo item"));
    try std.testing.expectEqualStrings("[", heldTail("- ["));
}

test "open fences never hold" {
    try std.testing.expectEqualStrings("", heldTail("```zig\nconst a = [1"));
    try std.testing.expectEqualStrings("", heldTail("```\n| not | a | table |\n"));
    try std.testing.expectEqualStrings("", heldTail("```\n| a |\n```\ndone"));
    try std.testing.expectEqualStrings("| a |", heldTail("```\ncode\n```\n| a |"));
}

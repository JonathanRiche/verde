//! Unified diff parser used by the zig_dif package.

const std = @import("std");

const ast = @import("ast.zig");

pub const ParseError = error{
    InvalidHunkHeader,
    InvalidRange,
    OutOfMemory,
};

const FileBuilder = struct {
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    header_lines: std.ArrayListUnmanaged([]const u8) = .empty,
    hunks: std.ArrayListUnmanaged(ast.Hunk) = .empty,
};

const HunkBuilder = struct {
    header: []const u8,
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: std.ArrayListUnmanaged(ast.Line) = .empty,
};

/// Parses unified diff text into an owned document AST.
pub fn parseUnifiedDiff(allocator: std.mem.Allocator, input: []const u8) ParseError!ast.Document {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();

    const arena = arena_state.allocator();
    const source = try arena.dupe(u8, input);

    var parser: Parser = .{
        .arena = arena,
        .lines = std.mem.splitScalar(u8, source, '\n'),
    };
    try parser.parse();

    return .{
        .arena = arena_state,
        .prelude_lines = try parser.prelude_lines.toOwnedSlice(arena),
        .files = try parser.files.toOwnedSlice(arena),
    };
}

const Parser = struct {
    arena: std.mem.Allocator,
    lines: std.mem.SplitIterator(u8, .scalar),
    prelude_lines: std.ArrayListUnmanaged([]const u8) = .empty,
    files: std.ArrayListUnmanaged(ast.File) = .empty,
    current_file: ?FileBuilder = null,
    current_hunk: ?HunkBuilder = null,

    fn parse(self: *Parser) ParseError!void {
        while (self.lines.next()) |raw_line| {
            const line = trimCarriageReturn(raw_line);

            if (startsNewFile(line)) {
                try self.beginFile(line);
                continue;
            }
            if (std.mem.startsWith(u8, line, "--- ")) {
                try self.recordOldPath(line);
                continue;
            }
            if (std.mem.startsWith(u8, line, "+++ ")) {
                try self.recordNewPath(line);
                continue;
            }
            if (std.mem.startsWith(u8, line, "@@ ")) {
                try self.beginHunk(line);
                continue;
            }
            if (std.mem.eql(u8, line, "\\ No newline at end of file")) {
                self.markMissingNewline();
                continue;
            }
            if (isHunkLine(line)) {
                try self.appendHunkLine(line);
                continue;
            }

            try self.appendMetadataLine(line);
        }

        try self.finishHunk();
        try self.finishFile();
    }

    fn beginFile(self: *Parser, line: []const u8) ParseError!void {
        try self.finishHunk();
        try self.finishFile();

        var file: FileBuilder = .{};
        try file.header_lines.append(self.arena, line);
        parseDiffGitPaths(line, &file);
        self.current_file = file;
    }

    fn recordOldPath(self: *Parser, line: []const u8) ParseError!void {
        try self.ensureFileStarted();
        self.current_file.?.old_path = parseFileMarkerPath(line["--- ".len..]);
        try self.current_file.?.header_lines.append(self.arena, line);
    }

    fn recordNewPath(self: *Parser, line: []const u8) ParseError!void {
        try self.ensureFileStarted();
        self.current_file.?.new_path = parseFileMarkerPath(line["+++ ".len..]);
        try self.current_file.?.header_lines.append(self.arena, line);
    }

    fn beginHunk(self: *Parser, line: []const u8) ParseError!void {
        try self.ensureFileStarted();
        try self.finishHunk();

        const ranges = try parseHunkHeader(line);
        self.current_hunk = .{
            .header = line,
            .old_start = ranges.old_start,
            .old_count = ranges.old_count,
            .new_start = ranges.new_start,
            .new_count = ranges.new_count,
        };
    }

    fn appendHunkLine(self: *Parser, line: []const u8) ParseError!void {
        if (self.current_hunk == null) {
            try self.appendMetadataLine(line);
            return;
        }

        const line_kind: ast.LineKind = switch (line[0]) {
            ' ' => .context,
            '+' => .addition,
            '-' => .deletion,
            else => unreachable,
        };
        try self.current_hunk.?.lines.append(self.arena, .{
            .kind = line_kind,
            .text = if (line.len > 1) line[1..] else "",
        });
    }

    fn appendMetadataLine(self: *Parser, line: []const u8) ParseError!void {
        if (line.len == 0) return;

        if (self.current_file) |*file| {
            try file.header_lines.append(self.arena, line);
            return;
        }
        try self.prelude_lines.append(self.arena, line);
    }

    fn markMissingNewline(self: *Parser) void {
        if (self.current_hunk == null) return;
        if (self.current_hunk.?.lines.items.len == 0) return;
        self.current_hunk.?.lines.items[self.current_hunk.?.lines.items.len - 1].missing_newline = true;
    }

    fn ensureFileStarted(self: *Parser) ParseError!void {
        if (self.current_file != null) return;
        self.current_file = .{};
    }

    fn finishHunk(self: *Parser) ParseError!void {
        var hunk = self.current_hunk orelse return;
        self.current_hunk = null;

        try self.ensureFileStarted();
        try self.current_file.?.hunks.append(self.arena, .{
            .header = hunk.header,
            .old_start = hunk.old_start,
            .old_count = hunk.old_count,
            .new_start = hunk.new_start,
            .new_count = hunk.new_count,
            .lines = try hunk.lines.toOwnedSlice(self.arena),
        });
    }

    fn finishFile(self: *Parser) ParseError!void {
        var file = self.current_file orelse return;
        self.current_file = null;

        try self.files.append(self.arena, .{
            .old_path = file.old_path,
            .new_path = file.new_path,
            .header_lines = try file.header_lines.toOwnedSlice(self.arena),
            .hunks = try file.hunks.toOwnedSlice(self.arena),
        });
    }
};

const HunkRanges = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

fn startsNewFile(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "diff --git ");
}

fn isHunkLine(line: []const u8) bool {
    if (line.len == 0) return false;
    return switch (line[0]) {
        ' ', '+', '-' => !std.mem.startsWith(u8, line, "+++ ") and !std.mem.startsWith(u8, line, "--- "),
        else => false,
    };
}

fn trimCarriageReturn(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn parseDiffGitPaths(line: []const u8, file: *FileBuilder) void {
    if (!std.mem.startsWith(u8, line, "diff --git ")) return;
    const payload = line["diff --git ".len..];
    var parts = std.mem.tokenizeScalar(u8, payload, ' ');
    file.old_path = parts.next() orelse return;
    file.new_path = parts.next() orelse return;
}

fn parseFileMarkerPath(raw: []const u8) []const u8 {
    const tab_index = std.mem.indexOfScalar(u8, raw, '\t') orelse raw.len;
    return raw[0..tab_index];
}

fn parseHunkHeader(line: []const u8) ParseError!HunkRanges {
    if (!std.mem.startsWith(u8, line, "@@ ")) return error.InvalidHunkHeader;

    const closing = std.mem.indexOfPos(u8, line, 3, " @@") orelse return error.InvalidHunkHeader;
    const body = line[3..closing];

    var parts = std.mem.tokenizeScalar(u8, body, ' ');
    const old_part = parts.next() orelse return error.InvalidHunkHeader;
    const new_part = parts.next() orelse return error.InvalidHunkHeader;

    return .{
        .old_start = try parseRangeStart(old_part, '-'),
        .old_count = try parseRangeCount(old_part, '-'),
        .new_start = try parseRangeStart(new_part, '+'),
        .new_count = try parseRangeCount(new_part, '+'),
    };
}

fn parseRangeStart(range: []const u8, prefix: u8) ParseError!usize {
    const body = try stripRangePrefix(range, prefix);
    const comma_index = std.mem.indexOfScalar(u8, body, ',') orelse body.len;
    return std.fmt.parseInt(usize, body[0..comma_index], 10) catch error.InvalidRange;
}

fn parseRangeCount(range: []const u8, prefix: u8) ParseError!usize {
    const body = try stripRangePrefix(range, prefix);
    const comma_index = std.mem.indexOfScalar(u8, body, ',') orelse return 1;
    return std.fmt.parseInt(usize, body[comma_index + 1 ..], 10) catch error.InvalidRange;
}

fn stripRangePrefix(range: []const u8, prefix: u8) ParseError![]const u8 {
    if (range.len < 2 or range[0] != prefix) return error.InvalidRange;
    return range[1..];
}

test "parse unified diff with metadata and missing newline markers" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/src/main.zig b/src/main.zig
        \\index 1111111..2222222 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,2 +1,3 @@
        \\ const std = @import("std");
        \\-pub fn old() void {}
        \\+pub fn new() void {}
        \\+pub fn newer() void {}
        \\\ No newline at end of file
        \\
    ;

    var document = try parseUnifiedDiff(allocator, input);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.files.len);
    try std.testing.expectEqualStrings("a/src/main.zig", document.files[0].old_path.?);
    try std.testing.expectEqualStrings("b/src/main.zig", document.files[0].new_path.?);
    try std.testing.expectEqual(@as(usize, 4), document.files[0].header_lines.len);
    try std.testing.expectEqual(@as(usize, 1), document.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 4), document.files[0].hunks[0].lines.len);
    try std.testing.expect(document.files[0].hunks[0].lines[3].missing_newline);
}

test "parse patch without diff git preamble" {
    const allocator = std.testing.allocator;
    const input =
        \\--- /dev/null
        \\+++ b/src/new_file.zig
        \\@@ -0,0 +1,2 @@
        \\+const std = @import("std");
        \\+pub fn main() void {}
    ;

    var document = try parseUnifiedDiff(allocator, input);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.files.len);
    try std.testing.expectEqualStrings("/dev/null", document.files[0].old_path.?);
    try std.testing.expectEqualStrings("b/src/new_file.zig", document.files[0].new_path.?);
    try std.testing.expectEqual(@as(usize, 1), document.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 0), document.files[0].hunks[0].old_start);
    try std.testing.expectEqual(@as(usize, 2), document.files[0].hunks[0].new_count);
}

test "parse unified diff preserves prelude lines and multiple files" {
    const allocator = std.testing.allocator;
    const input =
        \\Generated by Verde
        \\Review summary follows
        \\diff --git a/src/one.ts b/src/one.ts
        \\index 1111111..2222222 100644
        \\--- a/src/one.ts
        \\+++ b/src/one.ts
        \\@@ -1 +1 @@
        \\-const value = 1;
        \\+const value = 2;
        \\diff --git a/src/two.ts b/src/two.ts
        \\--- a/src/two.ts
        \\+++ b/src/two.ts
        \\@@ -4 +4 @@ heading
        \\-export const oldValue = 1;
        \\+export const newValue = 2;
    ;

    var document = try parseUnifiedDiff(allocator, input);
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 2), document.prelude_lines.len);
    try std.testing.expectEqualStrings("Generated by Verde", document.prelude_lines[0]);
    try std.testing.expectEqual(@as(usize, 2), document.files.len);
    try std.testing.expectEqualStrings("a/src/one.ts", document.files[0].old_path.?);
    try std.testing.expectEqualStrings("b/src/two.ts", document.files[1].new_path.?);
    try std.testing.expectEqualStrings("@@ -4 +4 @@ heading", document.files[1].hunks[0].header);
    try std.testing.expectEqual(@as(usize, 1), document.files[1].hunks[0].old_count);
    try std.testing.expectEqual(@as(usize, 1), document.files[1].hunks[0].new_count);
}

test "parse unified diff trims carriage returns from crlf input" {
    const allocator = std.testing.allocator;
    const input =
        "diff --git a/src/main.ts b/src/main.ts\r\n" ++
        "--- a/src/main.ts\r\n" ++
        "+++ b/src/main.ts\r\n" ++
        "@@ -1 +1 @@\r\n" ++
        "-const value = 1;\r\n" ++
        "+const value = 2;\r\n";

    var document = try parseUnifiedDiff(allocator, input);
    defer document.deinit();

    try std.testing.expectEqualStrings("diff --git a/src/main.ts b/src/main.ts", document.files[0].header_lines[0]);
    try std.testing.expectEqualStrings("const value = 2;", document.files[0].hunks[0].lines[1].text);
}

test "parse hunk header rejects malformed headers" {
    try std.testing.expectError(error.InvalidHunkHeader, parseHunkHeader("@@ -1,2 +1,2"));
    try std.testing.expectError(error.InvalidRange, parseHunkHeader("@@ 1,2 +1,2 @@"));
}

test "parse hunk header rejects malformed ranges" {
    try std.testing.expectError(error.InvalidRange, parseHunkHeader("@@ -x,2 +1,2 @@"));
    try std.testing.expectError(error.InvalidRange, parseHunkHeader("@@ -1,2 +y,2 @@"));
}

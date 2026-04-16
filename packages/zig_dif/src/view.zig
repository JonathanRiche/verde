//! Flattened render-oriented patch view built from the diff AST.

const std = @import("std");

const ast = @import("ast.zig");
const parser = @import("parser.zig");
const syntax = @import("syntax.zig");

pub const DisplayLineKind = enum {
    prelude,
    file_header,
    hunk_header,
    context,
    addition,
    deletion,
    note,
};

pub const DisplayLine = struct {
    kind: DisplayLineKind,
    old_line: ?usize = null,
    new_line: ?usize = null,
    tokens: []const syntax.Token,

    pub fn prefix(self: DisplayLine) ?u8 {
        return switch (self.kind) {
            .context => ' ',
            .addition => '+',
            .deletion => '-',
            else => null,
        };
    }
};

pub const PatchView = struct {
    document: ast.Document,
    lines: []const DisplayLine,
    max_old_line: usize,
    max_new_line: usize,

    pub fn deinit(self: *PatchView) void {
        self.document.deinit();
        self.* = undefined;
    }
};

pub const SideBySideCell = struct {
    kind: DisplayLineKind,
    line_number: ?usize = null,
    tokens: []const syntax.Token,
};

pub const SideBySideRowKind = enum {
    prelude,
    file_header,
    hunk_header,
    code,
    note,
};

pub const SideBySideRow = struct {
    kind: SideBySideRowKind,
    tokens: []const syntax.Token = &.{},
    left: ?SideBySideCell = null,
    right: ?SideBySideCell = null,
};

pub const SideBySidePatchView = struct {
    document: ast.Document,
    rows: []const SideBySideRow,
    max_old_line: usize,
    max_new_line: usize,

    pub fn deinit(self: *SideBySidePatchView) void {
        self.document.deinit();
        self.* = undefined;
    }
};

pub const Token = syntax.Token;
pub const TokenKind = syntax.TokenKind;

/// Parses a unified diff and builds a flattened display model.
pub fn buildPatchView(allocator: std.mem.Allocator, input: []const u8) parser.ParseError!PatchView {
    var document = try parser.parseUnifiedDiff(allocator, input);
    errdefer document.deinit();

    const arena = document.arena.allocator();
    var lines: std.ArrayListUnmanaged(DisplayLine) = .empty;
    errdefer lines.deinit(arena);

    var max_old_line: usize = 0;
    var max_new_line: usize = 0;

    for (document.prelude_lines) |line| {
        try lines.append(arena, .{
            .kind = .prelude,
            .tokens = try singleTokenLine(arena, .plain, line),
        });
    }

    for (document.files) |file| {
        const language = syntax.inferLanguage(file.new_path orelse file.old_path orelse "");
        for (file.header_lines) |line| {
            try lines.append(arena, .{
                .kind = .file_header,
                .tokens = try singleTokenLine(arena, .plain, line),
            });
        }

        for (file.hunks) |hunk| {
            try lines.append(arena, .{
                .kind = .hunk_header,
                .tokens = try singleTokenLine(arena, .plain, hunk.header),
            });

            var old_line = hunk.old_start;
            var new_line = hunk.new_start;
            for (hunk.lines) |diff_line| {
                const display_line = try buildCodeDisplayLine(arena, language, diff_line, old_line, new_line);
                if (display_line.old_line) |value| max_old_line = @max(max_old_line, value);
                if (display_line.new_line) |value| max_new_line = @max(max_new_line, value);
                try lines.append(arena, display_line);

                switch (diff_line.kind) {
                    .context => {
                        old_line += 1;
                        new_line += 1;
                    },
                    .deletion => old_line += 1,
                    .addition => new_line += 1,
                }

                if (diff_line.missing_newline) {
                    try lines.append(arena, .{
                        .kind = .note,
                        .tokens = try singleTokenLine(arena, .plain, "\\ No newline at end of file"),
                    });
                }
            }
        }
    }

    return .{
        .document = document,
        .lines = try lines.toOwnedSlice(arena),
        .max_old_line = max_old_line,
        .max_new_line = max_new_line,
    };
}

/// Parses a unified diff and builds an aligned side-by-side view.
pub fn buildSideBySidePatchView(allocator: std.mem.Allocator, input: []const u8) parser.ParseError!SideBySidePatchView {
    var document = try parser.parseUnifiedDiff(allocator, input);
    errdefer document.deinit();

    const arena = document.arena.allocator();
    var rows: std.ArrayListUnmanaged(SideBySideRow) = .empty;
    errdefer rows.deinit(arena);

    var max_old_line: usize = 0;
    var max_new_line: usize = 0;

    for (document.prelude_lines) |line| {
        try rows.append(arena, .{
            .kind = .prelude,
            .tokens = try singleTokenLine(arena, .plain, line),
        });
    }

    for (document.files) |file| {
        try rows.append(arena, .{
            .kind = .file_header,
            .tokens = try singleTokenLine(arena, .plain, fileDisplayLabel(file)),
        });

        const language = syntax.inferLanguage(file.new_path orelse file.old_path orelse "");
        for (file.hunks) |hunk| {
            try rows.append(arena, .{
                .kind = .hunk_header,
                .tokens = try singleTokenLine(arena, .plain, hunk.header),
            });

            var old_line = hunk.old_start;
            var new_line = hunk.new_start;
            var index: usize = 0;
            while (index < hunk.lines.len) {
                const diff_line = hunk.lines[index];
                switch (diff_line.kind) {
                    .context => {
                        const cell = try buildCodeCell(arena, language, .context, diff_line, old_line);
                        try rows.append(arena, .{
                            .kind = .code,
                            .left = cell,
                            .right = .{
                                .kind = .context,
                                .line_number = new_line,
                                .tokens = cell.tokens,
                            },
                        });
                        max_old_line = @max(max_old_line, old_line);
                        max_new_line = @max(max_new_line, new_line);
                        old_line += 1;
                        new_line += 1;
                        if (diff_line.missing_newline) {
                            try rows.append(arena, .{
                                .kind = .note,
                                .tokens = try singleTokenLine(arena, .plain, "\\ No newline at end of file"),
                            });
                        }
                        index += 1;
                    },
                    .deletion, .addition => {
                        const deletion_start = index;
                        var deletion_count: usize = 0;
                        while (index < hunk.lines.len and hunk.lines[index].kind == .deletion) : (index += 1) {
                            deletion_count += 1;
                        }

                        const addition_start = index;
                        var addition_count: usize = 0;
                        while (index < hunk.lines.len and hunk.lines[index].kind == .addition) : (index += 1) {
                            addition_count += 1;
                        }

                        const row_count = @max(deletion_count, addition_count);
                        var pair_index: usize = 0;
                        while (pair_index < row_count) : (pair_index += 1) {
                            const left = if (pair_index < deletion_count)
                                try buildCodeCell(arena, language, .deletion, hunk.lines[deletion_start + pair_index], old_line + pair_index)
                            else
                                null;
                            const right = if (pair_index < addition_count)
                                try buildCodeCell(arena, language, .addition, hunk.lines[addition_start + pair_index], new_line + pair_index)
                            else
                                null;

                            try rows.append(arena, .{
                                .kind = .code,
                                .left = left,
                                .right = right,
                            });

                            if (left) |cell| max_old_line = @max(max_old_line, cell.line_number orelse 0);
                            if (right) |cell| max_new_line = @max(max_new_line, cell.line_number orelse 0);

                            const left_missing = if (pair_index < deletion_count) hunk.lines[deletion_start + pair_index].missing_newline else false;
                            const right_missing = if (pair_index < addition_count) hunk.lines[addition_start + pair_index].missing_newline else false;
                            if (left_missing or right_missing) {
                                try rows.append(arena, .{
                                    .kind = .note,
                                    .tokens = try singleTokenLine(arena, .plain, "\\ No newline at end of file"),
                                });
                            }
                        }

                        old_line += deletion_count;
                        new_line += addition_count;
                    },
                }
            }
        }
    }

    return .{
        .document = document,
        .rows = try rows.toOwnedSlice(arena),
        .max_old_line = max_old_line,
        .max_new_line = max_new_line,
    };
}

fn buildCodeDisplayLine(
    allocator: std.mem.Allocator,
    language: syntax.Language,
    diff_line: ast.Line,
    old_line: usize,
    new_line: usize,
) std.mem.Allocator.Error!DisplayLine {
    return .{
        .kind = switch (diff_line.kind) {
            .context => .context,
            .addition => .addition,
            .deletion => .deletion,
        },
        .old_line = switch (diff_line.kind) {
            .context, .deletion => old_line,
            .addition => null,
        },
        .new_line = switch (diff_line.kind) {
            .context, .addition => new_line,
            .deletion => null,
        },
        .tokens = try syntax.tokenizeLine(allocator, language, diff_line.text),
    };
}

fn buildCodeCell(
    allocator: std.mem.Allocator,
    language: syntax.Language,
    kind: DisplayLineKind,
    diff_line: ast.Line,
    line_number: usize,
) std.mem.Allocator.Error!SideBySideCell {
    return .{
        .kind = kind,
        .line_number = line_number,
        .tokens = try syntax.tokenizeLine(allocator, language, diff_line.text),
    };
}

fn fileDisplayLabel(file: ast.File) []const u8 {
    return file.new_path orelse file.old_path orelse if (file.header_lines.len > 0) file.header_lines[0] else "(patch)";
}

fn testCellTextEquals(cell: SideBySideCell, expected: []const u8) bool {
    var cursor: usize = 0;
    for (cell.tokens) |token| {
        if (cursor + token.text.len > expected.len) return false;
        if (!std.mem.eql(u8, token.text, expected[cursor .. cursor + token.text.len])) return false;
        cursor += token.text.len;
    }
    return cursor == expected.len;
}

fn singleTokenLine(
    allocator: std.mem.Allocator,
    kind: syntax.TokenKind,
    text: []const u8,
) std.mem.Allocator.Error![]const syntax.Token {
    const tokens = try allocator.alloc(syntax.Token, 1);
    tokens[0] = .{
        .kind = kind,
        .text = text,
    };
    return tokens;
}

test "build patch view exposes line numbers and note lines" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/example.ts b/example.ts
        \\--- a/example.ts
        \\+++ b/example.ts
        \\@@ -2,2 +2,3 @@
        \\-const value = 1;
        \\+const value = 2;
        \\+export const name = "verde";
        \\ context();
        \\\ No newline at end of file
    ;

    var view = try buildPatchView(allocator, input);
    defer view.deinit();

    try std.testing.expect(view.lines.len >= 7);
    try std.testing.expectEqual(@as(usize, 3), view.max_old_line);
    try std.testing.expectEqual(@as(usize, 4), view.max_new_line);
    try std.testing.expectEqual(@as(DisplayLineKind, .deletion), view.lines[4].kind);
    try std.testing.expectEqual(@as(?usize, 2), view.lines[4].old_line);
    try std.testing.expectEqual(@as(?usize, null), view.lines[4].new_line);
    try std.testing.expectEqual(@as(DisplayLineKind, .note), view.lines[view.lines.len - 1].kind);
}

test "build patch view preserves prelude and file header ordering" {
    const allocator = std.testing.allocator;
    const input =
        \\Generated by Verde
        \\diff --git a/example.ts b/example.ts
        \\index 1111111..2222222 100644
        \\--- a/example.ts
        \\+++ b/example.ts
        \\@@ -1 +1 @@
        \\-const value = 1;
        \\+const value = 2;
    ;

    var view = try buildPatchView(allocator, input);
    defer view.deinit();

    try std.testing.expectEqual(@as(DisplayLineKind, .prelude), view.lines[0].kind);
    try std.testing.expectEqualStrings("Generated by Verde", view.lines[0].tokens[0].text);
    try std.testing.expectEqual(@as(DisplayLineKind, .file_header), view.lines[1].kind);
    try std.testing.expectEqualStrings("diff --git a/example.ts b/example.ts", view.lines[1].tokens[0].text);
    try std.testing.expectEqual(@as(DisplayLineKind, .hunk_header), view.lines[5].kind);
}

test "build patch view tokenizes typescript lines with structured token kinds" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/example.ts b/example.ts
        \\--- a/example.ts
        \\+++ b/example.ts
        \\@@ -1 +1 @@
        \\-const oldValue = 1;
        \\+const result = Object.keys(CONSTANT_VALUE);
    ;

    var view = try buildPatchView(allocator, input);
    defer view.deinit();

    const addition = view.lines[5];
    try std.testing.expectEqual(DisplayLineKind.addition, addition.kind);

    var found_keyword = false;
    var found_variable = false;
    var found_type = false;
    var found_function = false;
    var found_constant = false;
    for (addition.tokens) |token| {
        if (token.kind == .keyword and std.mem.eql(u8, token.text, "const")) found_keyword = true;
        if (token.kind == .variable_name and std.mem.eql(u8, token.text, "result")) found_variable = true;
        if (token.kind == .type_name and std.mem.eql(u8, token.text, "Object")) found_type = true;
        if (token.kind == .function_name and std.mem.eql(u8, token.text, "keys")) found_function = true;
        if (token.kind == .constant_name and std.mem.eql(u8, token.text, "CONSTANT_VALUE")) found_constant = true;
    }

    try std.testing.expect(found_keyword);
    try std.testing.expect(found_variable);
    try std.testing.expect(found_type);
    try std.testing.expect(found_function);
    try std.testing.expect(found_constant);
}

test "build patch view keeps line numbers independent across files" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/one.ts b/one.ts
        \\--- a/one.ts
        \\+++ b/one.ts
        \\@@ -10 +10 @@
        \\-const one = 1;
        \\+const one = 2;
        \\diff --git a/two.ts b/two.ts
        \\--- a/two.ts
        \\+++ b/two.ts
        \\@@ -3 +4 @@
        \\-const two = 1;
        \\+const two = 2;
    ;

    var view = try buildPatchView(allocator, input);
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 10), view.max_old_line);
    try std.testing.expectEqual(@as(usize, 10), view.max_new_line);
    try std.testing.expectEqual(@as(?usize, 10), view.lines[4].old_line);
    try std.testing.expectEqual(@as(?usize, 10), view.lines[5].new_line);
    try std.testing.expectEqual(@as(?usize, 3), view.lines[10].old_line);
    try std.testing.expectEqual(@as(?usize, 4), view.lines[11].new_line);
}

test "build side by side patch view aligns change blocks" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/main.rs b/main.rs
        \\--- a/main.rs
        \\+++ b/main.rs
        \\@@ -4,4 +4,4 @@
        \\-    println!("What is your name?");
        \\-    io::stdin().read_line(&mut name).unwrap();
        \\+    println!("Enter your name");
        \\+    io::stdin().read_line(&mut name).expect("read error");
        \\     println!("Hello, {}", name.trim());
    ;

    var view = try buildSideBySidePatchView(allocator, input);
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 5), view.rows.len);
    try std.testing.expectEqual(@as(SideBySideRowKind, .file_header), view.rows[0].kind);
    try std.testing.expectEqual(@as(SideBySideRowKind, .hunk_header), view.rows[1].kind);
    try std.testing.expectEqual(@as(SideBySideRowKind, .code), view.rows[2].kind);
    try std.testing.expectEqual(@as(DisplayLineKind, .deletion), view.rows[2].left.?.kind);
    try std.testing.expectEqual(@as(DisplayLineKind, .addition), view.rows[2].right.?.kind);
    try std.testing.expect(testCellTextEquals(view.rows[2].left.?, "    println!(\"What is your name?\");"));
    try std.testing.expect(testCellTextEquals(view.rows[2].right.?, "    println!(\"Enter your name\");"));
    try std.testing.expectEqual(@as(?usize, 6), view.rows[4].left.?.line_number);
    try std.testing.expectEqual(@as(?usize, 6), view.rows[4].right.?.line_number);
}

test "build side by side patch view leaves blank cells for pure insertions" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/example.ts b/example.ts
        \\--- a/example.ts
        \\+++ b/example.ts
        \\@@ -1,1 +1,3 @@
        \\ const value = 1;
        \\+const nextValue = 2;
        \\+const finalValue = 3;
    ;

    var view = try buildSideBySidePatchView(allocator, input);
    defer view.deinit();

    try std.testing.expectEqual(@as(SideBySideRowKind, .code), view.rows[3].kind);
    try std.testing.expectEqual(@as(?SideBySideCell, null), view.rows[3].left);
    try std.testing.expectEqual(@as(DisplayLineKind, .addition), view.rows[3].right.?.kind);
    try std.testing.expect(testCellTextEquals(view.rows[3].right.?, "const nextValue = 2;"));
}

test "build side by side patch view carries typed tokens into cells" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/example.ts b/example.ts
        \\--- a/example.ts
        \\+++ b/example.ts
        \\@@ -1 +1 @@
        \\-const oldValue = 1;
        \\+const result = Object.keys(CONSTANT_VALUE);
    ;

    var view = try buildSideBySidePatchView(allocator, input);
    defer view.deinit();

    const right = view.rows[2].right.?;
    var found_keyword = false;
    var found_type = false;
    var found_function = false;
    var found_constant = false;
    for (right.tokens) |token| {
        if (token.kind == .keyword and std.mem.eql(u8, token.text, "const")) found_keyword = true;
        if (token.kind == .type_name and std.mem.eql(u8, token.text, "Object")) found_type = true;
        if (token.kind == .function_name and std.mem.eql(u8, token.text, "keys")) found_function = true;
        if (token.kind == .constant_name and std.mem.eql(u8, token.text, "CONSTANT_VALUE")) found_constant = true;
    }
    try std.testing.expect(found_keyword);
    try std.testing.expect(found_type);
    try std.testing.expect(found_function);
    try std.testing.expect(found_constant);
}

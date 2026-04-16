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

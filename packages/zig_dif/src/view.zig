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
    context_gap,
    addition,
    deletion,
    note,
};

pub const BuildOptions = struct {
    context_lines: usize = 3,
};

pub const CollapsedContext = struct {
    skipped_lines: usize,
};

pub const DisplayLine = struct {
    kind: DisplayLineKind,
    old_line: ?usize = null,
    new_line: ?usize = null,
    tokens: []const syntax.Token,
    collapsed_context: ?CollapsedContext = null,

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
    text: []const u8,
    tokens: []const syntax.Token,
    emphasis_ranges: []const InlineRange = &.{},
};

pub const InlineRange = struct {
    start: usize,
    end: usize,
};

pub const SideBySideRowKind = enum {
    prelude,
    file_header,
    hunk_header,
    code,
    context_gap,
    note,
};

pub const SideBySideRow = struct {
    kind: SideBySideRowKind,
    tokens: []const syntax.Token = &.{},
    left: ?SideBySideCell = null,
    right: ?SideBySideCell = null,
    collapsed_context: ?CollapsedContext = null,
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

const PendingCodeCell = struct {
    cell: SideBySideCell,
    missing_newline: bool,
};

const ChangeAlignmentOp = enum(u8) {
    pair,
    left_gap,
    right_gap,
};

const ChangeAlignmentRow = struct {
    left_index: ?usize,
    right_index: ?usize,
};

pub const Token = syntax.Token;
pub const TokenKind = syntax.TokenKind;

/// Parses a unified diff and builds a flattened display model.
pub fn buildPatchView(allocator: std.mem.Allocator, input: []const u8) parser.ParseError!PatchView {
    return buildPatchViewWithOptions(allocator, input, .{});
}

/// Parses a unified diff and builds a flattened display model.
pub fn buildPatchViewWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: BuildOptions,
) parser.ParseError!PatchView {
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
            var saw_change = false;
            var index: usize = 0;
            while (index < hunk.lines.len) {
                const diff_line = hunk.lines[index];
                if (diff_line.kind == .context) {
                    const run_start = index;
                    while (index < hunk.lines.len and hunk.lines[index].kind == .context) : (index += 1) {}
                    try appendCollapsedFlatContextRun(
                        arena,
                        &lines,
                        language,
                        hunk.lines[run_start..index],
                        old_line,
                        new_line,
                        saw_change,
                        index < hunk.lines.len,
                        options.context_lines,
                        &max_old_line,
                        &max_new_line,
                    );
                    old_line += index - run_start;
                    new_line += index - run_start;
                    continue;
                }

                const display_line = try buildCodeDisplayLine(arena, language, diff_line, old_line, new_line);
                if (display_line.old_line) |value| max_old_line = @max(max_old_line, value);
                if (display_line.new_line) |value| max_new_line = @max(max_new_line, value);
                try lines.append(arena, display_line);

                saw_change = true;
                switch (diff_line.kind) {
                    .deletion => old_line += 1,
                    .addition => new_line += 1,
                    .context => unreachable,
                }

                if (diff_line.missing_newline) {
                    try lines.append(arena, .{
                        .kind = .note,
                        .tokens = try singleTokenLine(arena, .plain, "\\ No newline at end of file"),
                    });
                }

                index += 1;
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
    return buildSideBySidePatchViewWithOptions(allocator, input, .{});
}

/// Parses a unified diff and builds an aligned side-by-side view.
pub fn buildSideBySidePatchViewWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: BuildOptions,
) parser.ParseError!SideBySidePatchView {
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
        if (fileDisplayLabel(file)) |label| {
            try rows.append(arena, .{
                .kind = .file_header,
                .tokens = try singleTokenLine(arena, .plain, label),
            });
        }

        const language = syntax.inferLanguage(file.new_path orelse file.old_path orelse "");
        for (file.hunks) |hunk| {
            try rows.append(arena, .{
                .kind = .hunk_header,
                .tokens = try singleTokenLine(arena, .plain, hunk.header),
            });

            var old_line = hunk.old_start;
            var new_line = hunk.new_start;
            var saw_change = false;
            var index: usize = 0;
            while (index < hunk.lines.len) {
                const diff_line = hunk.lines[index];
                if (diff_line.kind == .context) {
                    const run_start = index;
                    while (index < hunk.lines.len and hunk.lines[index].kind == .context) : (index += 1) {}
                    try appendCollapsedSideBySideContextRun(
                        arena,
                        &rows,
                        language,
                        hunk.lines[run_start..index],
                        old_line,
                        new_line,
                        saw_change,
                        index < hunk.lines.len,
                        options.context_lines,
                        &max_old_line,
                        &max_new_line,
                    );
                    old_line += index - run_start;
                    new_line += index - run_start;
                    continue;
                }

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

                const deletions = try buildPendingCodeCells(
                    arena,
                    language,
                    .deletion,
                    hunk.lines[deletion_start .. deletion_start + deletion_count],
                    old_line,
                );
                const additions = try buildPendingCodeCells(
                    arena,
                    language,
                    .addition,
                    hunk.lines[addition_start .. addition_start + addition_count],
                    new_line,
                );
                const alignment = try alignChangeBlock(arena, deletions, additions);

                for (alignment) |pair| {
                    var left = if (pair.left_index) |left_index| deletions[left_index].cell else null;
                    var right = if (pair.right_index) |right_index| additions[right_index].cell else null;
                    try assignInlineEmphasis(arena, if (left != null) &left.? else null, if (right != null) &right.? else null);

                    try rows.append(arena, .{
                        .kind = .code,
                        .left = left,
                        .right = right,
                    });

                    if (left) |cell| max_old_line = @max(max_old_line, cell.line_number orelse 0);
                    if (right) |cell| max_new_line = @max(max_new_line, cell.line_number orelse 0);

                    const left_missing = if (pair.left_index) |left_index| deletions[left_index].missing_newline else false;
                    const right_missing = if (pair.right_index) |right_index| additions[right_index].missing_newline else false;
                    if (left_missing or right_missing) {
                        try rows.append(arena, .{
                            .kind = .note,
                            .tokens = try singleTokenLine(arena, .plain, "\\ No newline at end of file"),
                        });
                    }
                }

                saw_change = true;
                old_line += deletion_count;
                new_line += addition_count;
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

const ContextRunPlan = struct {
    prefix_count: usize,
    suffix_count: usize,
    skipped_count: usize,
};

fn planContextRun(
    run_len: usize,
    context_lines: usize,
    has_left_change: bool,
    has_right_change: bool,
) ContextRunPlan {
    if (run_len == 0) return .{ .prefix_count = 0, .suffix_count = 0, .skipped_count = 0 };
    if (!has_left_change and !has_right_change) {
        return .{
            .prefix_count = run_len,
            .suffix_count = 0,
            .skipped_count = 0,
        };
    }
    if (!has_left_change) {
        const visible = @min(run_len, context_lines);
        return .{
            .prefix_count = 0,
            .suffix_count = visible,
            .skipped_count = run_len - visible,
        };
    }
    if (!has_right_change) {
        const visible = @min(run_len, context_lines);
        return .{
            .prefix_count = visible,
            .suffix_count = 0,
            .skipped_count = run_len - visible,
        };
    }
    if (run_len <= context_lines * 2) {
        return .{
            .prefix_count = run_len,
            .suffix_count = 0,
            .skipped_count = 0,
        };
    }
    return .{
        .prefix_count = context_lines,
        .suffix_count = context_lines,
        .skipped_count = run_len - (context_lines * 2),
    };
}

fn appendFlatContextGap(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged(DisplayLine),
    skipped_count: usize,
) std.mem.Allocator.Error!void {
    if (skipped_count == 0) return;
    try lines.append(allocator, .{
        .kind = .context_gap,
        .tokens = try singleTokenLine(allocator, .plain, try contextGapLabel(allocator, skipped_count)),
        .collapsed_context = .{ .skipped_lines = skipped_count },
    });
}

fn appendSideBySideContextGap(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(SideBySideRow),
    skipped_count: usize,
) std.mem.Allocator.Error!void {
    if (skipped_count == 0) return;
    try rows.append(allocator, .{
        .kind = .context_gap,
        .tokens = try singleTokenLine(allocator, .plain, try contextGapLabel(allocator, skipped_count)),
        .collapsed_context = .{ .skipped_lines = skipped_count },
    });
}

fn contextGapLabel(allocator: std.mem.Allocator, skipped_count: usize) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "... {d} unchanged line{s} ...", .{
        skipped_count,
        if (skipped_count == 1) "" else "s",
    });
}

fn appendCollapsedFlatContextRun(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged(DisplayLine),
    language: syntax.Language,
    run: []const ast.Line,
    old_line_start: usize,
    new_line_start: usize,
    has_left_change: bool,
    has_right_change: bool,
    context_lines: usize,
    max_old_line: *usize,
    max_new_line: *usize,
) std.mem.Allocator.Error!void {
    const plan = planContextRun(run.len, context_lines, has_left_change, has_right_change);
    if (!has_left_change and has_right_change) {
        try appendFlatContextGap(allocator, lines, plan.skipped_count);
    }

    const prefix_end = plan.prefix_count;
    var index: usize = 0;
    while (index < prefix_end) : (index += 1) {
        try appendFlatContextLine(
            allocator,
            lines,
            language,
            run[index],
            old_line_start + index,
            new_line_start + index,
            max_old_line,
            max_new_line,
        );
    }

    if (plan.skipped_count > 0 and has_left_change and has_right_change) {
        try appendFlatContextGap(allocator, lines, plan.skipped_count);
    }

    if (plan.suffix_count > 0) {
        const suffix_start = run.len - plan.suffix_count;
        index = suffix_start;
        while (index < run.len) : (index += 1) {
            try appendFlatContextLine(
                allocator,
                lines,
                language,
                run[index],
                old_line_start + index,
                new_line_start + index,
                max_old_line,
                max_new_line,
            );
        }
    }

    if (has_left_change and !has_right_change and plan.skipped_count > 0) {
        try appendFlatContextGap(allocator, lines, plan.skipped_count);
    }
}

fn appendFlatContextLine(
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged(DisplayLine),
    language: syntax.Language,
    diff_line: ast.Line,
    old_line: usize,
    new_line: usize,
    max_old_line: *usize,
    max_new_line: *usize,
) std.mem.Allocator.Error!void {
    const display_line = try buildCodeDisplayLine(allocator, language, diff_line, old_line, new_line);
    if (display_line.old_line) |value| max_old_line.* = @max(max_old_line.*, value);
    if (display_line.new_line) |value| max_new_line.* = @max(max_new_line.*, value);
    try lines.append(allocator, display_line);
    if (diff_line.missing_newline) {
        try lines.append(allocator, .{
            .kind = .note,
            .tokens = try singleTokenLine(allocator, .plain, "\\ No newline at end of file"),
        });
    }
}

fn appendCollapsedSideBySideContextRun(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(SideBySideRow),
    language: syntax.Language,
    run: []const ast.Line,
    old_line_start: usize,
    new_line_start: usize,
    has_left_change: bool,
    has_right_change: bool,
    context_lines: usize,
    max_old_line: *usize,
    max_new_line: *usize,
) std.mem.Allocator.Error!void {
    const plan = planContextRun(run.len, context_lines, has_left_change, has_right_change);
    if (!has_left_change and has_right_change) {
        try appendSideBySideContextGap(allocator, rows, plan.skipped_count);
    }

    const prefix_end = plan.prefix_count;
    var index: usize = 0;
    while (index < prefix_end) : (index += 1) {
        try appendSideBySideContextLine(
            allocator,
            rows,
            language,
            run[index],
            old_line_start + index,
            new_line_start + index,
            max_old_line,
            max_new_line,
        );
    }

    if (plan.skipped_count > 0 and has_left_change and has_right_change) {
        try appendSideBySideContextGap(allocator, rows, plan.skipped_count);
    }

    if (plan.suffix_count > 0) {
        const suffix_start = run.len - plan.suffix_count;
        index = suffix_start;
        while (index < run.len) : (index += 1) {
            try appendSideBySideContextLine(
                allocator,
                rows,
                language,
                run[index],
                old_line_start + index,
                new_line_start + index,
                max_old_line,
                max_new_line,
            );
        }
    }

    if (has_left_change and !has_right_change and plan.skipped_count > 0) {
        try appendSideBySideContextGap(allocator, rows, plan.skipped_count);
    }
}

fn appendSideBySideContextLine(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(SideBySideRow),
    language: syntax.Language,
    diff_line: ast.Line,
    old_line: usize,
    new_line: usize,
    max_old_line: *usize,
    max_new_line: *usize,
) std.mem.Allocator.Error!void {
    const cell = try buildCodeCell(allocator, language, .context, diff_line, old_line);
    const right_cell: SideBySideCell = .{
        .kind = .context,
        .line_number = new_line,
        .text = diff_line.text,
        .tokens = cell.tokens,
    };
    try rows.append(allocator, .{
        .kind = .code,
        .left = cell,
        .right = right_cell,
    });
    max_old_line.* = @max(max_old_line.*, old_line);
    max_new_line.* = @max(max_new_line.*, new_line);
    if (diff_line.missing_newline) {
        try rows.append(allocator, .{
            .kind = .note,
            .tokens = try singleTokenLine(allocator, .plain, "\\ No newline at end of file"),
        });
    }
}

fn buildPendingCodeCells(
    allocator: std.mem.Allocator,
    language: syntax.Language,
    kind: DisplayLineKind,
    lines: []const ast.Line,
    start_line_number: usize,
) std.mem.Allocator.Error![]const PendingCodeCell {
    const cells = try allocator.alloc(PendingCodeCell, lines.len);
    for (lines, 0..) |line, index| {
        cells[index] = .{
            .cell = try buildCodeCell(allocator, language, kind, line, start_line_number + index),
            .missing_newline = line.missing_newline,
        };
    }
    return cells;
}

fn alignChangeBlock(
    arena: std.mem.Allocator,
    left_cells: []const PendingCodeCell,
    right_cells: []const PendingCodeCell,
) std.mem.Allocator.Error![]const ChangeAlignmentRow {
    const row_stride = right_cells.len + 1;
    const matrix_len = (left_cells.len + 1) * row_stride;

    const scores = try arena.alloc(i32, matrix_len);
    const ops = try arena.alloc(ChangeAlignmentOp, matrix_len);

    scores[0] = 0;
    ops[0] = .pair;

    var left_index: usize = 1;
    while (left_index <= left_cells.len) : (left_index += 1) {
        const matrix_index = left_index * row_stride;
        scores[matrix_index] = scores[matrix_index - row_stride] + changeGapPenalty;
        ops[matrix_index] = .left_gap;
    }

    var right_index: usize = 1;
    while (right_index <= right_cells.len) : (right_index += 1) {
        scores[right_index] = scores[right_index - 1] + changeGapPenalty;
        ops[right_index] = .right_gap;
    }

    left_index = 1;
    while (left_index <= left_cells.len) : (left_index += 1) {
        right_index = 1;
        while (right_index <= right_cells.len) : (right_index += 1) {
            const matrix_index = left_index * row_stride + right_index;
            const pair_score = scores[(left_index - 1) * row_stride + (right_index - 1)] +
                lineSimilarityScore(left_cells[left_index - 1].cell, right_cells[right_index - 1].cell);
            const left_gap_score = scores[(left_index - 1) * row_stride + right_index] + changeGapPenalty;
            const right_gap_score = scores[left_index * row_stride + (right_index - 1)] + changeGapPenalty;

            var best_score = pair_score;
            var best_op: ChangeAlignmentOp = .pair;
            if (left_gap_score > best_score) {
                best_score = left_gap_score;
                best_op = .left_gap;
            }
            if (right_gap_score > best_score) {
                best_score = right_gap_score;
                best_op = .right_gap;
            }

            scores[matrix_index] = best_score;
            ops[matrix_index] = best_op;
        }
    }

    var reversed: std.ArrayListUnmanaged(ChangeAlignmentRow) = .empty;
    var cursor_left = left_cells.len;
    var cursor_right = right_cells.len;
    while (cursor_left > 0 or cursor_right > 0) {
        const matrix_index = cursor_left * row_stride + cursor_right;
        const op = ops[matrix_index];
        switch (op) {
            .pair => {
                try reversed.append(arena, .{
                    .left_index = cursor_left - 1,
                    .right_index = cursor_right - 1,
                });
                cursor_left -= 1;
                cursor_right -= 1;
            },
            .left_gap => {
                try reversed.append(arena, .{
                    .left_index = cursor_left - 1,
                    .right_index = null,
                });
                cursor_left -= 1;
            },
            .right_gap => {
                try reversed.append(arena, .{
                    .left_index = null,
                    .right_index = cursor_right - 1,
                });
                cursor_right -= 1;
            },
        }
    }

    const rows = try arena.alloc(ChangeAlignmentRow, reversed.items.len);
    var index: usize = 0;
    while (index < reversed.items.len) : (index += 1) {
        rows[index] = reversed.items[reversed.items.len - 1 - index];
    }
    return rows;
}

const changeGapPenalty = -6;

fn lineSimilarityScore(left: SideBySideCell, right: SideBySideCell) i32 {
    if (std.mem.eql(u8, left.text, right.text)) return 32;

    const exact_score = weightedTokenLcs(left.tokens, right.tokens, true);
    const structural_score = weightedTokenLcs(left.tokens, right.tokens, false);
    const left_weight = tokenSequenceWeight(left.tokens);
    const right_weight = tokenSequenceWeight(right.tokens);

    return exact_score * 2 + structural_score - left_weight - right_weight;
}

fn weightedTokenLcs(left_tokens: []const syntax.Token, right_tokens: []const syntax.Token, comptime exact_only: bool) i32 {
    var left_count: usize = 0;
    for (left_tokens) |token| {
        if (token.kind != .plain) left_count += 1;
    }

    var right_count: usize = 0;
    for (right_tokens) |token| {
        if (token.kind != .plain) right_count += 1;
    }

    if (left_count == 0 or right_count == 0) return 0;

    var left_filtered: [64]syntax.Token = undefined;
    var right_filtered: [64]syntax.Token = undefined;
    if (left_count > left_filtered.len or right_count > right_filtered.len) return 0;

    left_count = 0;
    for (left_tokens) |token| {
        if (token.kind == .plain) continue;
        left_filtered[left_count] = token;
        left_count += 1;
    }

    right_count = 0;
    for (right_tokens) |token| {
        if (token.kind == .plain) continue;
        right_filtered[right_count] = token;
        right_count += 1;
    }

    var previous = std.mem.zeroes([65]i32);
    var current = std.mem.zeroes([65]i32);

    var left_index: usize = 0;
    while (left_index < left_count) : (left_index += 1) {
        current[0] = 0;
        var right_index: usize = 0;
        while (right_index < right_count) : (right_index += 1) {
            const match_score = tokenMatchScore(left_filtered[left_index], right_filtered[right_index], exact_only);
            const pair_score = if (match_score > 0) previous[right_index] + match_score else std.math.minInt(i32);
            const skip_left = previous[right_index + 1];
            const skip_right = current[right_index];
            current[right_index + 1] = @max(@max(skip_left, skip_right), pair_score);
        }
        previous = current;
    }

    return previous[right_count];
}

fn tokenSequenceWeight(tokens: []const syntax.Token) i32 {
    var total: i32 = 0;
    for (tokens) |token| {
        if (token.kind == .plain) continue;
        total += tokenWeight(token.kind);
    }
    return total;
}

fn tokenMatchScore(left: syntax.Token, right: syntax.Token, comptime exact_only: bool) i32 {
    if (left.kind == .plain or right.kind == .plain) return 0;

    if (std.mem.eql(u8, left.text, right.text) and left.kind == right.kind) {
        return tokenWeight(left.kind) + 2;
    }

    if (exact_only) return 0;
    if (left.kind != right.kind) return 0;

    return switch (left.kind) {
        .variable_name,
        .function_name,
        .property_name,
        .type_name,
        .constant_name,
        .string,
        .number,
        => tokenWeight(left.kind),
        .keyword => 1,
        .operator, .punctuation => if (std.mem.eql(u8, left.text, right.text)) tokenWeight(left.kind) else 0,
        .comment, .plain => 0,
    };
}

fn tokenWeight(kind: syntax.TokenKind) i32 {
    return switch (kind) {
        .keyword => 4,
        .type_name, .function_name, .property_name, .variable_name, .constant_name => 3,
        .string, .number => 2,
        .operator, .punctuation => 1,
        .comment, .plain => 0,
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
        .text = diff_line.text,
        .tokens = try syntax.tokenizeLine(allocator, language, diff_line.text),
    };
}

fn fileDisplayLabel(file: ast.File) ?[]const u8 {
    if (file.new_path) |value| return value;
    if (file.old_path) |value| return value;
    return null;
}

fn testCellTextEquals(cell: SideBySideCell, expected: []const u8) bool {
    return std.mem.eql(u8, cell.text, expected);
}

const ChunkKind = enum {
    whitespace,
    word,
    punctuation,
};

const Chunk = struct {
    start: usize,
    end: usize,
    kind: ChunkKind,
};

const InlineEmphasisPair = struct {
    left: []const InlineRange = &.{},
    right: []const InlineRange = &.{},
};

const ChunkMatch = struct {
    left_index: usize,
    right_index: usize,
};

fn assignInlineEmphasis(
    arena: std.mem.Allocator,
    left: ?*SideBySideCell,
    right: ?*SideBySideCell,
) std.mem.Allocator.Error!void {
    if (left == null and right == null) return;
    if (left != null and right != null) {
        const pair = try buildInlineEmphasisPair(arena, left.?.text, right.?.text);
        left.?.emphasis_ranges = pair.left;
        right.?.emphasis_ranges = pair.right;
        return;
    }
    if (left) |cell| {
        cell.emphasis_ranges = try fullLineEmphasis(arena, cell.text);
    }
    if (right) |cell| {
        cell.emphasis_ranges = try fullLineEmphasis(arena, cell.text);
    }
}

fn fullLineEmphasis(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const InlineRange {
    if (text.len == 0) return &.{};
    const ranges = try arena.alloc(InlineRange, 1);
    ranges[0] = .{ .start = 0, .end = text.len };
    return ranges;
}

fn buildInlineEmphasisPair(
    arena: std.mem.Allocator,
    left_text: []const u8,
    right_text: []const u8,
) std.mem.Allocator.Error!InlineEmphasisPair {
    if (std.mem.eql(u8, left_text, right_text)) return .{};

    const left_chunks = try chunkLine(arena, left_text);
    const right_chunks = try chunkLine(arena, right_text);

    if (left_chunks.len <= chunkLcsLimit and right_chunks.len <= chunkLcsLimit) {
        const matches = try chunkLcsMatches(arena, left_text, left_chunks, right_text, right_chunks);
        if (matches.len > 0) {
            const left_ranges = try buildInlineRangesFromMatches(arena, left_text, left_chunks, matches, true);
            const right_ranges = try buildInlineRangesFromMatches(arena, right_text, right_chunks, matches, false);
            if (left_ranges.len > 0 or right_ranges.len > 0) {
                return .{
                    .left = left_ranges,
                    .right = right_ranges,
                };
            }
        }
    }

    return buildTrimmedInlineEmphasisPair(arena, left_text, right_text, left_chunks, right_chunks);
}

fn buildTrimmedInlineEmphasisPair(
    arena: std.mem.Allocator,
    left_text: []const u8,
    right_text: []const u8,
    left_chunks: []const Chunk,
    right_chunks: []const Chunk,
) std.mem.Allocator.Error!InlineEmphasisPair {
    var prefix_count: usize = 0;
    while (prefix_count < left_chunks.len and prefix_count < right_chunks.len) : (prefix_count += 1) {
        const left_chunk = left_chunks[prefix_count];
        const right_chunk = right_chunks[prefix_count];
        if (left_chunk.kind != right_chunk.kind) break;
        if (!std.mem.eql(u8, left_text[left_chunk.start..left_chunk.end], right_text[right_chunk.start..right_chunk.end])) break;
    }

    var left_suffix_limit = left_chunks.len;
    var right_suffix_limit = right_chunks.len;
    while (left_suffix_limit > prefix_count and right_suffix_limit > prefix_count) {
        const left_chunk = left_chunks[left_suffix_limit - 1];
        const right_chunk = right_chunks[right_suffix_limit - 1];
        if (left_chunk.kind != right_chunk.kind) break;
        if (!std.mem.eql(u8, left_text[left_chunk.start..left_chunk.end], right_text[right_chunk.start..right_chunk.end])) break;
        left_suffix_limit -= 1;
        right_suffix_limit -= 1;
    }

    return .{
        .left = try buildInlineRangesFromChunks(arena, left_text, left_chunks, prefix_count, left_suffix_limit),
        .right = try buildInlineRangesFromChunks(arena, right_text, right_chunks, prefix_count, right_suffix_limit),
    };
}

fn chunkLcsMatches(
    arena: std.mem.Allocator,
    left_text: []const u8,
    left_chunks: []const Chunk,
    right_text: []const u8,
    right_chunks: []const Chunk,
) std.mem.Allocator.Error![]const ChunkMatch {
    const row_stride = right_chunks.len + 1;
    const table_len = (left_chunks.len + 1) * row_stride;
    const table = try arena.alloc(usize, table_len);
    @memset(table, 0);

    var left_index: usize = 0;
    while (left_index < left_chunks.len) : (left_index += 1) {
        var right_index: usize = 0;
        while (right_index < right_chunks.len) : (right_index += 1) {
            const table_index = (left_index + 1) * row_stride + (right_index + 1);
            if (chunkTextEquals(left_text, left_chunks[left_index], right_text, right_chunks[right_index])) {
                table[table_index] = table[left_index * row_stride + right_index] + 1;
            } else {
                table[table_index] = @max(
                    table[left_index * row_stride + (right_index + 1)],
                    table[(left_index + 1) * row_stride + right_index],
                );
            }
        }
    }

    var reversed: std.ArrayListUnmanaged(ChunkMatch) = .empty;
    var cursor_left = left_chunks.len;
    var cursor_right = right_chunks.len;
    while (cursor_left > 0 and cursor_right > 0) {
        if (chunkTextEquals(left_text, left_chunks[cursor_left - 1], right_text, right_chunks[cursor_right - 1]) and
            table[cursor_left * row_stride + cursor_right] == table[(cursor_left - 1) * row_stride + (cursor_right - 1)] + 1)
        {
            try reversed.append(arena, .{
                .left_index = cursor_left - 1,
                .right_index = cursor_right - 1,
            });
            cursor_left -= 1;
            cursor_right -= 1;
            continue;
        }

        if (table[(cursor_left - 1) * row_stride + cursor_right] >= table[cursor_left * row_stride + (cursor_right - 1)]) {
            cursor_left -= 1;
        } else {
            cursor_right -= 1;
        }
    }

    const matches = try arena.alloc(ChunkMatch, reversed.items.len);
    var index: usize = 0;
    while (index < reversed.items.len) : (index += 1) {
        matches[index] = reversed.items[reversed.items.len - 1 - index];
    }
    return matches;
}

fn buildInlineRangesFromMatches(
    arena: std.mem.Allocator,
    text: []const u8,
    chunks: []const Chunk,
    matches: []const ChunkMatch,
    comptime left_side: bool,
) std.mem.Allocator.Error![]const InlineRange {
    var ranges: std.ArrayListUnmanaged(InlineRange) = .empty;
    var chunk_cursor: usize = 0;

    for (matches) |match| {
        const matched_index = if (left_side) match.left_index else match.right_index;
        if (matched_index > chunk_cursor) {
            try appendInlineRangeFromChunks(arena, &ranges, text, chunks, chunk_cursor, matched_index);
        }
        chunk_cursor = matched_index + 1;
    }

    if (chunk_cursor < chunks.len) {
        try appendInlineRangeFromChunks(arena, &ranges, text, chunks, chunk_cursor, chunks.len);
    }

    return ranges.toOwnedSlice(arena);
}

fn appendInlineRangeFromChunks(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayListUnmanaged(InlineRange),
    text: []const u8,
    chunks: []const Chunk,
    start_chunk: usize,
    end_chunk: usize,
) std.mem.Allocator.Error!void {
    if (start_chunk >= end_chunk) return;

    const start = chunks[start_chunk].start;
    const end = chunks[end_chunk - 1].end;
    const trimmed_start = trimInlineRangeStart(text, start, end);
    const trimmed_end = trimInlineRangeEnd(text, trimmed_start, end);
    const final_start = if (trimmed_start == trimmed_end) start else trimmed_start;
    const final_end = if (trimmed_start == trimmed_end) end else trimmed_end;
    if (final_end <= final_start) return;

    try ranges.append(allocator, .{
        .start = final_start,
        .end = final_end,
    });
}

fn trimInlineRangeStart(text: []const u8, start: usize, end: usize) usize {
    var index = start;
    while (index < end and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    return index;
}

fn trimInlineRangeEnd(text: []const u8, start: usize, end: usize) usize {
    var index = end;
    while (index > start and std.ascii.isWhitespace(text[index - 1])) : (index -= 1) {}
    return index;
}

fn chunkTextEquals(
    left_text: []const u8,
    left_chunk: Chunk,
    right_text: []const u8,
    right_chunk: Chunk,
) bool {
    if (left_chunk.kind != right_chunk.kind) return false;
    return std.mem.eql(u8, left_text[left_chunk.start..left_chunk.end], right_text[right_chunk.start..right_chunk.end]);
}

const chunkLcsLimit = 64;

fn chunkLine(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const Chunk {
    var chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const kind = classifyChunkByte(text[cursor]);
        const start = cursor;
        cursor += 1;
        while (cursor < text.len and classifyChunkByte(text[cursor]) == kind) : (cursor += 1) {}
        try chunks.append(arena, .{ .start = start, .end = cursor, .kind = kind });
    }
    return chunks.toOwnedSlice(arena);
}

fn classifyChunkByte(char: u8) ChunkKind {
    if (std.ascii.isWhitespace(char)) return .whitespace;
    if (std.ascii.isAlphanumeric(char) or char == '_') return .word;
    return .punctuation;
}

fn buildInlineRangesFromChunks(
    arena: std.mem.Allocator,
    text: []const u8,
    chunks: []const Chunk,
    prefix_count: usize,
    suffix_limit: usize,
) std.mem.Allocator.Error![]const InlineRange {
    if (chunks.len == 0 or prefix_count >= suffix_limit) return &.{};

    var start = chunks[prefix_count].start;
    var end = chunks[suffix_limit - 1].end;
    while (start < end and std.ascii.isWhitespace(text[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    if (end <= start) return &.{};

    const ranges = try arena.alloc(InlineRange, 1);
    ranges[0] = .{ .start = start, .end = end };
    return ranges;
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

test "build side by side patch view marks inline emphasis ranges" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/main.rs b/main.rs
        \\--- a/main.rs
        \\+++ b/main.rs
        \\@@ -4 +4 @@
        \\-    io::stdin().read_line(&mut name).unwrap();
        \\+    io::stdin().read_line(&mut name).expect("read error");
    ;

    var view = try buildSideBySidePatchView(allocator, input);
    defer view.deinit();

    const left = view.rows[2].left.?;
    const right = view.rows[2].right.?;
    try std.testing.expect(left.emphasis_ranges.len > 0);
    try std.testing.expect(right.emphasis_ranges.len > 0);
    try std.testing.expect(left.emphasis_ranges[0].start > 0);
    try std.testing.expect(right.emphasis_ranges[0].end <= right.text.len);
}

test "build side by side patch view inserts gaps for structurally added lines" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/review-campaigns.ts b/review-campaigns.ts
        \\--- a/review-campaigns.ts
        \\+++ b/review-campaigns.ts
        \\@@ -1,4 +1,6 @@
        \\-if (!geoFenceTargetFile) {
        \\-    addIssue(issues, seenKeys, {});
        \\-if (!geoTargetData.exists) {
        \\-    addIssue(issues, seenKeys, {});
        \\+if (!geoFenceTargetFile) {
        \\+    rowHasIssues = true;
        \\+    addIssue(issues, seenKeys, {});
        \\+if (!geoTargetData.exists) {
        \\+    rowHasIssues = true;
        \\+    addIssue(issues, seenKeys, {});
    ;

    var view = try buildSideBySidePatchView(allocator, input);
    defer view.deinit();

    try std.testing.expectEqual(@as(SideBySideRowKind, .code), view.rows[2].kind);
    try std.testing.expect(testCellTextEquals(view.rows[2].left.?, "if (!geoFenceTargetFile) {"));
    try std.testing.expect(testCellTextEquals(view.rows[2].right.?, "if (!geoFenceTargetFile) {"));

    try std.testing.expectEqual(@as(?SideBySideCell, null), view.rows[3].left);
    try std.testing.expect(testCellTextEquals(view.rows[3].right.?, "    rowHasIssues = true;"));

    try std.testing.expect(testCellTextEquals(view.rows[4].left.?, "    addIssue(issues, seenKeys, {});"));
    try std.testing.expect(testCellTextEquals(view.rows[4].right.?, "    addIssue(issues, seenKeys, {});"));
}

test "build side by side patch view collapses large unchanged context runs" {
    const allocator = std.testing.allocator;
    const input =
        \\diff --git a/example.ts b/example.ts
        \\--- a/example.ts
        \\+++ b/example.ts
        \\@@ -1,10 +1,10 @@
        \\ context_1();
        \\ context_2();
        \\ context_3();
        \\ context_4();
        \\-const value = 1;
        \\+const value = 2;
        \\ context_5();
        \\ context_6();
        \\ context_7();
        \\ context_8();
    ;

    var view = try buildSideBySidePatchViewWithOptions(allocator, input, .{ .context_lines = 2 });
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 9), view.rows.len);
    try std.testing.expectEqual(SideBySideRowKind.context_gap, view.rows[2].kind);
    try std.testing.expectEqual(@as(usize, 2), view.rows[2].collapsed_context.?.skipped_lines);
    try std.testing.expectEqualStrings("... 2 unchanged lines ...", view.rows[2].tokens[0].text);

    try std.testing.expectEqual(SideBySideRowKind.code, view.rows[3].kind);
    try std.testing.expectEqual(@as(?usize, 3), view.rows[3].left.?.line_number);
    try std.testing.expectEqual(@as(?usize, 3), view.rows[3].right.?.line_number);

    try std.testing.expectEqual(SideBySideRowKind.code, view.rows[6].kind);
    try std.testing.expectEqual(SideBySideRowKind.context_gap, view.rows[8].kind);
    try std.testing.expectEqual(@as(usize, 2), view.rows[8].collapsed_context.?.skipped_lines);
}
